// B4：database.dart 拆分——目录：学科 / 文件夹 / 标签 / 试卷 / 知识点与章节。
// 与 database.dart 同一库（part of），共享库私有成员；纯重构，行为不变。

part of 'database.dart';

String _iconFor(String id) => switch (id) {
  'math' => '数',
  'english' => '英',
  'politics' => '政',
  _ => id.isEmpty ? '学' : id[0],
};

/// §4.2/§4.5：删学科同事务：该科各题（经 _deleteQuestionTxn，含
/// review_history、自查历史、review_state 队列、collect_tasks 指向）
/// → 该科收集任务 → recent_tasks 里该科行 → 文件夹 / 知识点 / 学科行。
/// 中途失败整体回滚，不留“题删了、学科还在”的半截状态。
/// SR-P2-1：事务内先删该科任务的草稿框（`question_boxes` 里
/// `collect_task_id` 属于这些任务、`question_id IS NULL` 的行，含
/// 其 layer-2 子框——子框同样带 collect_task_id）：只清题框
/// （_deleteQuestionTxn）不够，草稿框不指题，删学科后会永久残留
/// 指向已删任务的孤儿框行。
Future<void> deleteSubjectFromImpl(Database db, String id) async {
  // §4.5：删前快照该科题的切片与任务 id，事务提交后删文件：
  // 切片是题独占的，任务目录只在无人引用时删（页图可能还被题引用，
  // 但该科题已全删，引用已不存在；仍走引用检查，不误删）。
  final slices = await db.query(
    'questions',
    columns: ['slice_path'],
    where: 'subject_id = ?',
    whereArgs: [id],
  );
  final taskRows = await db.query(
    'collect_tasks',
    columns: ['id'],
    where: 'subject_id = ?',
    whereArgs: [id],
  );
  final taskIds = taskRows.map((r) => r['id'] as String).toList();
  await db.transaction((txn) async {
    final qs = await txn.query(
      'questions',
      columns: ['id'],
      where: 'subject_id = ?',
      whereArgs: [id],
    );
    for (final row in qs) {
      await _deleteQuestionTxn(txn, row['id'] as String);
    }
    // SR-P2-1：先清该科任务的草稿框，再删任务行。
    if (taskIds.isNotEmpty) {
      final placeholders = List.filled(taskIds.length, '?').join(',');
      await txn.delete(
        'question_boxes',
        where: 'collect_task_id IN ($placeholders)',
        whereArgs: taskIds,
      );
    }
    await txn.delete('collect_tasks', where: 'subject_id = ?', whereArgs: [id]);
    await txn.delete('recent_tasks', where: 'subject_id = ?', whereArgs: [id]);
    await txn.delete('folders', where: 'subject_id = ?', whereArgs: [id]);
    await txn.delete(
      'knowledge_points',
      where: 'subject_id = ?',
      whereArgs: [id],
    );
    await txn.delete('subjects', where: 'id = ?', whereArgs: [id]);
  });
  for (final row in slices) {
    await _deleteDataFileIfUnreferenced(db, row['slice_path'] as String?);
  }
  for (final row in taskRows) {
    await _deleteTaskDirIfUnreferenced(db, row['id'] as String);
  }
}

/// §4.2：删文件夹（可单测版）：整棵子树一次事务，不 bump。
/// 事务提交后删被删掉的题的切片（只删库里已不存在的题的切片，
/// 且只删无引用文件；只移走关联的题不动文件）。
Future<int> deleteFolderFromImpl(Database db, Folder f) async {
  final before = await db.query('questions', columns: ['id', 'slice_path']);
  var deleted = 0;
  await db.transaction((txn) async {
    deleted = await _deleteFolderTxn(txn, f);
  });
  final remaining = await db.query('questions', columns: ['id']);
  final remainingIds = {for (final r in remaining) r['id'] as String};
  for (final row in before) {
    if (!remainingIds.contains(row['id'] as String)) {
      await _deleteDataFileIfUnreferenced(db, row['slice_path'] as String?);
    }
  }
  return deleted;
}

/// §4.2：递归删文件夹（事务内传 Transaction，不开嵌套事务——
/// sqflite 不支持嵌套事务，递归里再 transaction 会抛错）。
/// SR-P2-17：每层只读挂了本文件夹的题——`folder_ids` 是 JSON
/// 数组文本，用 `LIKE '%"id"%'` 在 SQL 层粗筛（`"` 定界，不会把
/// `f1` 误筛成 `f10` 的子串；`%`/`_`/`\` 先转义再拼 LIKE，
/// 见 [_likeEscape]），再内存按 [Question.folderIds] 精筛；
/// 旧写法每层 `txn.query('questions')` 全表 + 逐行 `_fromRow`
/// 解码，题库上千时删文件夹是 O(层数 × 题数)。
Future<int> _deleteFolderTxn(Transaction txn, Folder f) async {
  final rows = await txn.query(
    'questions',
    columns: ['id', 'folder_ids'],
    where: 'folder_ids LIKE ? ESCAPE ?',
    whereArgs: ['%"${_likeEscape(f.id)}"%', '\\'],
  );
  var deleted = 0;
  for (final row in rows) {
    final folderIds = AppDatabase.decodeStringList(row['folder_ids']);
    if (!folderIds.contains(f.id)) continue;
    final qid = row['id'] as String;
    if (folderIds.length == 1) {
      await _deleteQuestionTxn(txn, qid);
      deleted++;
    } else {
      final rest = folderIds.where((e) => e != f.id).toList();
      await txn.update(
        'questions',
        {'folder_ids': AppDatabase.encodeStringList(rest)},
        where: 'id = ?',
        whereArgs: [qid],
      );
    }
  }
  // 子文件夹随父文件夹一起删（同规则递归到子文件夹里的题）。
  final subs = await txn.query(
    'folders',
    where: 'parent_id = ?',
    whereArgs: [f.id],
  );
  for (final s in subs) {
    final sub = Folder(
      id: s['id'] as String,
      name: s['name'] as String,
      subjectId: s['subject_id'] as String,
      parentId: s['parent_id'] as String?,
    );
    deleted += await _deleteFolderTxn(txn, sub);
  }
  await txn.delete('folders', where: 'id = ?', whereArgs: [f.id]);
  return deleted;
}

/// LIKE 模式转义（与 `ESCAPE '\'` 配对用）：`%` / `_` 是 LIKE
/// 通配符，`\` 是转义符本身；不转义时含 `_` 的 id（如 `f_1`）
/// 会误匹配 `fX1`。供 [_deleteFolderTxn] 与
/// [_deleteTaskDirIfUnreferenced] 共用（同一库，跨 part 可见）。
String _likeEscape(String value) => value
    .replaceAll('\\', '\\\\')
    .replaceAll('%', '\\%')
    .replaceAll('_', '\\_');

/// SR-P2-36：整科同名判重（可单测版）：同一学科下是否存在与
/// [name] 同名、且 id 不是 [excludeId] 的文件夹。已定决定
/// （Meng 2026-11-14“全部同意”第 12 条）：同一学科不能有两个
/// 同名文件夹，判重范围是整科、不是同层兄弟。新建 / 改名 / 移入
/// 三处调用方先调它预检（提示“已经有了”），[upsertFolder] 再做
/// 最终把关（见 [AppDatabaseCatalog.upsertFolder]）。
Future<bool> folderNameExistsInSubjectFromImpl(
  Database db,
  String subjectId,
  String name, {
  String? excludeId,
}) async {
  final rows = await db.query(
    'folders',
    columns: ['id'],
    where: excludeId == null
        ? 'subject_id = ? AND name = ?'
        : 'subject_id = ? AND name = ? AND id != ?',
    whereArgs: excludeId == null
        ? [subjectId, name]
        : [subjectId, name, excludeId],
    limit: 1,
  );
  return rows.isNotEmpty;
}

/// B2-4：按插入顺序读（rowid）；不写 orderBy 时 SQLite 不保证顺序，
/// 曾因此出现学科乱序（见 [AppDatabase.upsertSubject] 的修法说明）。
Future<List<String>> allTagsFromImpl(Database db) async {
  final rows = await db.query('tags', orderBy: 'rowid');
  return rows.map((r) => r['name'] as String).toList();
}

/// §4.2：改标签名同事务：标签行改名 + 所有挂了旧标签的题改标签。
/// 可单测版（直接对传入的库句柄做，不碰单例）。
Future<void> renameTagFromImpl(
  Database db,
  String oldName,
  String newName,
) async {
  await db.transaction((txn) async {
    await txn.update(
      'tags',
      {'id': 'tag-$newName', 'name': newName},
      where: 'name = ?',
      whereArgs: [oldName],
    );
    final rows = await txn.query('questions');
    for (final row in rows) {
      final q = _fromRow(row);
      if (!q.tags.contains(oldName)) continue;
      final tags = q.tags.map((t) => t == oldName ? newName : t).toList();
      await txn.update(
        'questions',
        {'tags': AppDatabase.encodeStringList(tags)},
        where: 'id = ?',
        whereArgs: [q.id],
      );
    }
  });
}

/// §4.2：删标签同事务：标签行 + 所有题上的该标签。可单测版。
Future<void> deleteTagFromImpl(Database db, String name) async {
  await db.transaction((txn) async {
    await txn.delete('tags', where: 'name = ?', whereArgs: [name]);
    final rows = await txn.query('questions');
    for (final row in rows) {
      final q = _fromRow(row);
      if (!q.tags.contains(name)) continue;
      final tags = q.tags.where((t) => t != name).toList();
      await txn.update(
        'questions',
        {'tags': AppDatabase.encodeStringList(tags)},
        where: 'id = ?',
        whereArgs: [q.id],
      );
    }
  });
}

/// B2-4：按插入顺序读（rowid），见 [AppDatabase.allTagsFrom]。
Future<List<Exam>> allExamsFromImpl(Database db) async {
  final rows = await db.query('exams', orderBy: 'rowid');
  return rows
      .map(
        (r) => Exam(
          id: r['id'] as String,
          name: r['name'] as String,
          date: r['date'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(r['date'] as int),
        ),
      )
      .toList();
}

/// B2-4：原地更新（与 [AppDatabase.upsertSubject] 同一口径）：已存在的行只
/// UPDATE，rowid 不变、顺序不动；不存在时才 INSERT。REPLACE 是
/// 先删后插，会把这行顶到表尾（改试卷名，试卷就跑到最下面）。
Future<void> insertExamIntoImpl(Database db, Exam e) async {
  final values = {
    'id': e.id,
    'name': e.name,
    'date': e.date?.millisecondsSinceEpoch,
  };
  final updated = await db.update(
    'exams',
    values,
    where: 'id = ?',
    whereArgs: [e.id],
  );
  if (updated == 0) {
    await db.insert('exams', values);
  }
}

/// SR-P1-3：删试卷同事务：试卷行 + 所有题上的该试卷引用置空。
/// 旧版三步顺序写、无事务，第一步 `update exams set name=''` 是
/// 死步骤（下一秒行就被删掉），中间失败会留下“试卷已删、题还指着
/// 不存在的 exam_id”的悬空引用，或“试卷还在、名字被清空成 ''”。
/// 可单测版（直接对传入的库句柄做，不碰单例）。
Future<void> deleteExamFromImpl(Database db, String id) async {
  await db.transaction((txn) async {
    await txn.delete('exams', where: 'id = ?', whereArgs: [id]);
    await txn.update(
      'questions',
      {'exam_id': null},
      where: 'exam_id = ?',
      whereArgs: [id],
    );
  });
}

/// B2-4：按插入顺序读（rowid），见 [AppDatabase.allTagsFrom]。
Future<List<KnowledgePoint>> allKnowledgePointsFromImpl(Database db) async {
  final rows = await db.query('knowledge_points', orderBy: 'rowid');
  return rows
      .map(
        (r) => KnowledgePoint(
          id: r['id'] as String,
          subjectId: r['subject_id'] as String,
          chapter: r['chapter'] as String,
          name: r['name'] as String,
        ),
      )
      .toList();
}

/// B2-4：原地更新（与 [AppDatabase.upsertSubject] 同一口径）：已存在的行只
/// UPDATE，rowid 不变、顺序不动；不存在时才 INSERT。
/// REPLACE 是先删后插，会把这行顶到表尾。
Future<void> insertKnowledgePointIntoImpl(
  Database db,
  KnowledgePoint kp,
) async {
  final values = {
    'id': kp.id,
    'subject_id': kp.subjectId,
    'chapter': kp.chapter,
    'name': kp.name,
  };
  final updated = await db.update(
    'knowledge_points',
    values,
    where: 'id = ?',
    whereArgs: [kp.id],
  );
  if (updated == 0) {
    await db.insert('knowledge_points', values);
  }
}

/// §4.2：删知识点同事务：知识点行 + 所有题上的该知识点。可单测版。
Future<void> deleteKnowledgePointFromImpl(Database db, String id) async {
  await db.transaction((txn) async {
    await txn.delete('knowledge_points', where: 'id = ?', whereArgs: [id]);
    final rows = await txn.query('questions');
    for (final row in rows) {
      final q = _fromRow(row);
      if (!q.knowledgePointIds.contains(id)) continue;
      final kps = q.knowledgePointIds.where((e) => e != id).toList();
      await txn.update(
        'questions',
        {'knowledge_ids': AppDatabase.encodeStringList(kps)},
        where: 'id = ?',
        whereArgs: [q.id],
      );
    }
  });
}

/// §4.2：删除章节同事务：该章节全部知识点行 + 所有题上的这些
/// 知识点。可单测版。
Future<void> deleteChapterFromImpl(
  Database db,
  String subjectId,
  String chapter,
) async {
  await db.transaction((txn) async {
    final rows = await txn.query(
      'knowledge_points',
      columns: ['id'],
      where: 'subject_id = ? AND chapter = ?',
      whereArgs: [subjectId, chapter],
    );
    final ids = rows.map((r) => r['id'] as String).toList();
    await txn.delete(
      'knowledge_points',
      where: 'subject_id = ? AND chapter = ?',
      whereArgs: [subjectId, chapter],
    );
    if (ids.isEmpty) return;
    final qrows = await txn.query('questions');
    for (final row in qrows) {
      final q = _fromRow(row);
      final kept = q.knowledgePointIds.where((e) => !ids.contains(e)).toList();
      if (kept.length == q.knowledgePointIds.length) continue;
      await txn.update(
        'questions',
        {'knowledge_ids': AppDatabase.encodeStringList(kept)},
        where: 'id = ?',
        whereArgs: [q.id],
      );
    }
  });
}

extension AppDatabaseCatalog on AppDatabase {
  Future<List<Subject>> allSubjects() async {
    final d = await db;
    // 显式按插入顺序读：subjects 表没有 sort_order 列，顺序就是 rowid 顺序；
    // 不写 orderBy 时 SQLite 不保证返回顺序，曾经因此出现过学科乱序。
    final rows = await d.query('subjects', orderBy: 'rowid');
    return rows
        .map(
          (r) => Subject(
            id: r['id'] as String,
            name: r['name'] as String,
            color: Color((r['color'] as int?) ?? 0xFF2F7CF6),
            icon: _iconFor(r['id'] as String),
            coverStyle: (r['cover_style'] as String?) ?? 'plain',
            coverColor: (r['cover_color'] as String?) ?? 'blue',
          ),
        )
        .toList();
  }

  Future<void> upsertSubject(Subject s) async {
    final d = await db;
    final values = {
      'id': s.id,
      'name': s.name,
      'color': s.color.toARGB32(),
      'cover_style': s.coverStyle,
      'cover_color': s.coverColor,
    };
    // 原地更新：ConflictAlgorithm.replace 是先删后插，会把这行顶到表尾，
    // 导致学科顺序乱掉（点数学的封面，数学就跑到最下面）。已存在的行只
    // UPDATE，rowid 不变，顺序就不会动；不存在时才 INSERT。
    final updated = await d.update(
      'subjects',
      values,
      where: 'id = ?',
      whereArgs: [s.id],
    );
    if (updated == 0) {
      await d.insert('subjects', values);
    }
    bumpBadgeVersion();
  }

  Future<void> deleteSubject(String id) async {
    final d = await db;
    await AppDatabase.deleteSubjectFrom(d, id);
    bumpBadgeVersion();
  }

  Future<List<Folder>> allFolders({String? subjectId}) async {
    final d = await db;
    final rows = subjectId == null
        ? await d.query('folders', orderBy: 'subject_id ASC, sort_order ASC')
        : await d.query(
            'folders',
            where: 'subject_id = ?',
            whereArgs: [subjectId],
            orderBy: 'sort_order ASC',
          );
    return rows
        .map(
          (r) => Folder(
            id: r['id'] as String,
            name: r['name'] as String,
            subjectId: r['subject_id'] as String,
            parentId: r['parent_id'] as String?,
            sortOrder: (r['sort_order'] as int?) ?? 0,
          ),
        )
        .toList();
  }

  /// SR-P2-36：整科同名把关——同一学科下已存在同名文件夹
  /// （不论层级）时拒绝写入，抛 StateError（文案含“已经有了”，
  /// 调用方捕获后按“已经有了”提示用户，不要当未知错误报）。
  /// 新建 / 改名 / 移入三处调用方应在保存前先调
  /// [AppDatabase.folderNameExistsInSubject] 预检、给即时提示；
  /// 这里是最后一道防线：绕过页内预检的写入也进不来。
  /// 同 id 原地更新（改排序、移回原父级等）不触发——查的是
  /// “别人家有没有同名”，自己不算。
  Future<void> upsertFolder(Folder f) async {
    final d = await db;
    if (await AppDatabase.folderNameExistsInSubjectFrom(
      d,
      f.subjectId,
      f.name,
      excludeId: f.id,
    )) {
      throw StateError('已经有了：同一学科下已有同名文件夹“${f.name}”');
    }
    await d.insert('folders', {
      'id': f.id,
      'name': f.name,
      'subject_id': f.subjectId,
      'parent_id': f.parentId,
      'sort_order': f.sortOrder,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    bumpBadgeVersion();
  }

  /// SR-P2-36：整科同名预检（实例版）：同一学科下是否存在与
  /// [name] 同名、且 id 不是 [excludeId] 的文件夹。
  Future<bool> folderNameExistsInSubject(
    String subjectId,
    String name, {
    String? excludeId,
  }) async =>
      AppDatabase.folderNameExistsInSubjectFrom(
        await db,
        subjectId,
        name,
        excludeId: excludeId,
      );

  /// 删文件夹：只在这个文件夹里的题跟着删；在多个文件夹里的题只移走
  /// 这个文件夹的关联。返回删掉的题数。
  Future<int> deleteFolder(Folder f) async {
    final d = await db;
    final deleted = await AppDatabase.deleteFolderFrom(d, f);
    bumpBadgeVersion();
    return deleted;
  }

  Future<List<String>> allTags() async => AppDatabase.allTagsFrom(await db);

  Future<void> insertTag(String name) async {
    final d = await db;
    await d.insert('tags', {
      'id': 'tag-$name',
      'name': name,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> renameTag(String oldName, String newName) async {
    final d = await db;
    await AppDatabase.renameTagFrom(d, oldName, newName);
  }

  Future<void> deleteTag(String name) async {
    final d = await db;
    await AppDatabase.deleteTagFrom(d, name);
  }

  Future<List<Exam>> allExams() async => AppDatabase.allExamsFrom(await db);

  Future<void> insertExam(Exam e) async {
    final d = await db;
    await AppDatabase.insertExamInto(d, e);
  }

  Future<void> renameExam(String id, String newName) async {
    final d = await db;
    await d.update(
      'exams',
      {'name': newName},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteExam(String id) async {
    final d = await db;
    await AppDatabase.deleteExamFrom(d, id);
  }

  Future<List<KnowledgePoint>> allKnowledgePoints() async =>
      AppDatabase.allKnowledgePointsFrom(await db);

  Future<void> insertKnowledgePoint(KnowledgePoint kp) async {
    final d = await db;
    await AppDatabase.insertKnowledgePointInto(d, kp);
  }

  Future<void> renameKnowledgePoint(String id, String newName) async {
    final d = await db;
    await d.update(
      'knowledge_points',
      {'name': newName},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteKnowledgePoint(String id) async {
    final d = await db;
    await AppDatabase.deleteKnowledgePointFrom(d, id);
  }

  /// 章节改名：只改 `knowledge_points.chapter` 的名字，题上挂的知识点
  /// id 不变，题跟着改名。空章节存不下来（章节只随知识点存在），
  /// 所以加章节仍须同时给第一个知识点（见 repository.addChapter）。
  Future<void> renameChapter(
    String subjectId,
    String oldChapter,
    String newChapter,
  ) async {
    final d = await db;
    await d.update(
      'knowledge_points',
      {'chapter': newChapter},
      where: 'subject_id = ? AND chapter = ?',
      whereArgs: [subjectId, oldChapter],
    );
  }

  /// 删除章节：删掉该章节下全部知识点；题还在，只是这些知识点变空、
  /// 成为待补充（与删知识点同一口径）。
  Future<void> deleteChapter(String subjectId, String chapter) async {
    final d = await db;
    await AppDatabase.deleteChapterFrom(d, subjectId, chapter);
  }
}
