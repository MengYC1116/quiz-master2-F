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
Future<void> deleteSubjectFromImpl(QuizDatabase db, String id) async {
  // §4.5：删前快照该科题的切片与任务 id，事务提交后删文件：
  // 切片是题独占的，任务目录只在无人引用时删（页图可能还被题引用，
  // 但该科题已全删，引用已不存在；仍走引用检查，不误删）。
  final slices = _rows(
    await db
        .customSelect(
          'SELECT slice_path FROM questions WHERE subject_id = ?',
          variables: [Variable.withString(id)],
        )
        .get(),
  );
  final taskRows = _rows(
    await db
        .customSelect(
          'SELECT id FROM collect_tasks WHERE subject_id = ?',
          variables: [Variable.withString(id)],
        )
        .get(),
  );
  final taskIds = taskRows.map((r) => r['id'] as String).toList();
  await db.transaction(() async {
    final qs = _rows(
      await db
          .customSelect(
            'SELECT id FROM questions WHERE subject_id = ?',
            variables: [Variable.withString(id)],
          )
          .get(),
    );
    for (final row in qs) {
      await _deleteQuestionTxn(db, row['id'] as String);
    }
    // SR-P2-1：先清该科任务的草稿框，再删任务行。
    if (taskIds.isNotEmpty) {
      final placeholders = List.filled(taskIds.length, '?').join(',');
      await db.customUpdate(
        'DELETE FROM question_boxes WHERE collect_task_id IN ($placeholders)',
        variables: taskIds.map(Variable.withString).toList(),
      );
    }
    await db.customUpdate(
      'DELETE FROM collect_tasks WHERE subject_id = ?',
      variables: [Variable.withString(id)],
    );
    await db.customUpdate(
      'DELETE FROM recent_tasks WHERE subject_id = ?',
      variables: [Variable.withString(id)],
    );
    await db.customUpdate(
      'DELETE FROM folders WHERE subject_id = ?',
      variables: [Variable.withString(id)],
    );
    await db.customUpdate(
      'DELETE FROM knowledge_points WHERE subject_id = ?',
      variables: [Variable.withString(id)],
    );
    await db.customUpdate(
      'DELETE FROM subjects WHERE id = ?',
      variables: [Variable.withString(id)],
    );
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
Future<int> deleteFolderFromImpl(QuizDatabase db, Folder f) async {
  final before = _rows(
    await db.customSelect('SELECT id, slice_path FROM questions').get(),
  );
  var deleted = 0;
  await db.transaction(() async {
    deleted = await _deleteFolderTxn(db, f);
  });
  final remaining = _rows(
    await db.customSelect('SELECT id FROM questions').get(),
  );
  final remainingIds = {for (final r in remaining) r['id'] as String};
  for (final row in before) {
    if (!remainingIds.contains(row['id'] as String)) {
      await _deleteDataFileIfUnreferenced(db, row['slice_path'] as String?);
    }
  }
  return deleted;
}

/// §4.2：递归删文件夹（事务内传同一数据库连接，不开嵌套事务——
/// 递归里再 transaction 会走 Drift savepoint 语义，不需要也不用）。
/// SR-P2-17：每层只读挂了本文件夹的题——`folder_ids` 是 JSON
/// 数组文本，用 `LIKE '%"id"%'` 在 SQL 层粗筛（`"` 定界，不会把
/// `f1` 误筛成 `f10` 的子串；`%`/`_`/`\` 先转义再拼 LIKE，
/// 见 [_likeEscape]），再内存按 [Question.folderIds] 精筛；
/// 旧写法每层 `txn.query('questions')` 全表 + 逐行 `_fromRow`
/// 解码，题库上千时删文件夹是 O(层数 × 题数)。
Future<int> _deleteFolderTxn(QuizDatabase db, Folder f) async {
  final rows = _rows(
    await db
        .customSelect(
          'SELECT id, folder_ids FROM questions WHERE folder_ids LIKE ? ESCAPE ?',
          variables: [
            Variable.withString('%"${_likeEscape(f.id)}"%'),
            Variable.withString('\\'),
          ],
        )
        .get(),
  );
  var deleted = 0;
  for (final row in rows) {
    final folderIds = AppDatabase.decodeStringList(row['folder_ids']);
    if (!folderIds.contains(f.id)) continue;
    final qid = row['id'] as String;
    if (folderIds.length == 1) {
      await _deleteQuestionTxn(db, qid);
      deleted++;
    } else {
      final rest = folderIds.where((e) => e != f.id).toList();
      await db.customUpdate(
        'UPDATE questions SET folder_ids = ? WHERE id = ?',
        variables: [
          Variable.withString(AppDatabase.encodeStringList(rest)),
          Variable.withString(qid),
        ],
      );
    }
  }
  // 子文件夹随父文件夹一起删（同规则递归到子文件夹里的题）。
  final subs = _rows(
    await db
        .customSelect(
          'SELECT * FROM folders WHERE parent_id = ?',
          variables: [Variable.withString(f.id)],
        )
        .get(),
  );
  for (final s in subs) {
    final sub = Folder(
      id: s['id'] as String,
      name: s['name'] as String,
      subjectId: s['subject_id'] as String,
      parentId: s['parent_id'] as String?,
    );
    deleted += await _deleteFolderTxn(db, sub);
  }
  await db.customUpdate(
    'DELETE FROM folders WHERE id = ?',
    variables: [Variable.withString(f.id)],
  );
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
/// 参数是 [DatabaseConnectionUser]（SR2-15：[upsertFolder] 在同一事务内
/// 先判重后插入，须把事务句柄传进来；与 [_seedCauseRecordsFor]
/// 同一放宽口径）。
Future<bool> folderNameExistsInSubjectFromImpl(
  DatabaseConnectionUser db,
  String subjectId,
  String name, {
  String? excludeId,
}) async {
  final row = await db
      .customSelect(
        excludeId == null
            ? 'SELECT id FROM folders WHERE subject_id = ? AND name = ? LIMIT 1'
            : 'SELECT id FROM folders WHERE subject_id = ? AND name = ? AND id != ? LIMIT 1',
        variables: excludeId == null
            ? [Variable.withString(subjectId), Variable.withString(name)]
            : [
                Variable.withString(subjectId),
                Variable.withString(name),
                Variable.withString(excludeId),
              ],
      )
      .getSingleOrNull();
  return row != null;
}

/// B2-4：按插入顺序读（rowid）；不写 orderBy 时 SQLite 不保证顺序，
/// 曾因此出现学科乱序（见 [AppDatabase.upsertSubject] 的修法说明）。
Future<List<String>> allTagsFromImpl(QuizDatabase db) async {
  final rows = _rows(
    await db.customSelect('SELECT * FROM tags ORDER BY rowid').get(),
  );
  return rows.map((r) => r['name'] as String).toList();
}

/// §4.2：改标签名同事务：标签行改名 + 所有挂了旧标签的题改标签。
/// 可单测版（直接对传入的库句柄做，不碰单例）。
Future<void> renameTagFromImpl(
  QuizDatabase db,
  String oldName,
  String newName,
) async {
  await db.transaction(() async {
    await db.customUpdate(
      'UPDATE tags SET id = ?, name = ? WHERE name = ?',
      variables: [
        Variable.withString('tag-$newName'),
        Variable.withString(newName),
        Variable.withString(oldName),
      ],
    );
    final rows = _rows(
      await db.customSelect('SELECT * FROM questions').get(),
    );
    for (final row in rows) {
      final q = _fromRow(row);
      if (!q.tags.contains(oldName)) continue;
      final tags = q.tags.map((t) => t == oldName ? newName : t).toList();
      await db.customUpdate(
        'UPDATE questions SET tags = ? WHERE id = ?',
        variables: [
          Variable.withString(AppDatabase.encodeStringList(tags)),
          Variable.withString(q.id),
        ],
      );
    }
  });
}

/// §4.2：删标签同事务：标签行 + 所有题上的该标签。可单测版。
Future<void> deleteTagFromImpl(QuizDatabase db, String name) async {
  await db.transaction(() async {
    await db.customUpdate(
      'DELETE FROM tags WHERE name = ?',
      variables: [Variable.withString(name)],
    );
    final rows = _rows(
      await db.customSelect('SELECT * FROM questions').get(),
    );
    for (final row in rows) {
      final q = _fromRow(row);
      if (!q.tags.contains(name)) continue;
      final tags = q.tags.where((t) => t != name).toList();
      await db.customUpdate(
        'UPDATE questions SET tags = ? WHERE id = ?',
        variables: [
          Variable.withString(AppDatabase.encodeStringList(tags)),
          Variable.withString(q.id),
        ],
      );
    }
  });
}

/// B2-4：按插入顺序读（rowid），见 [AppDatabase.allTagsFrom]。
Future<List<Exam>> allExamsFromImpl(QuizDatabase db) async {
  final rows = _rows(
    await db.customSelect('SELECT * FROM exams ORDER BY rowid').get(),
  );
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
Future<void> insertExamIntoImpl(QuizDatabase db, Exam e) async {
  final values = {
    'id': e.id,
    'name': e.name,
    'date': e.date?.millisecondsSinceEpoch,
  };
  final updated = await db.customUpdate(
    // SET 里含 id（原 map 写法同）：id 赋自身值，无实际改动。
    'UPDATE exams SET id = ?, name = ?, date = ? WHERE id = ?',
    variables: [..._variables(values), Variable.withString(e.id)],
  );
  if (updated == 0) {
    await db.customInsert(
      'INSERT INTO exams (id, name, date) VALUES (?, ?, ?)',
      variables: _variables(values),
    );
  }
}

/// SR-P1-3：删试卷同事务：试卷行 + 所有题上的该试卷引用置空。
/// 旧版三步顺序写、无事务，第一步 `update exams set name=''` 是
/// 死步骤（下一秒行就被删掉），中间失败会留下“试卷已删、题还指着
/// 不存在的 exam_id”的悬空引用，或“试卷还在、名字被清空成 ''”。
/// 可单测版（直接对传入的库句柄做，不碰单例）。
Future<void> deleteExamFromImpl(QuizDatabase db, String id) async {
  await db.transaction(() async {
    await db.customUpdate(
      'DELETE FROM exams WHERE id = ?',
      variables: [Variable.withString(id)],
    );
    await db.customUpdate(
      'UPDATE questions SET exam_id = NULL WHERE exam_id = ?',
      variables: [Variable.withString(id)],
    );
  });
}

/// B2-4：按插入顺序读（rowid），见 [AppDatabase.allTagsFrom]。
Future<List<KnowledgePoint>> allKnowledgePointsFromImpl(QuizDatabase db) async {
  final rows = _rows(
    await db
        .customSelect('SELECT * FROM knowledge_points ORDER BY rowid')
        .get(),
  );
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
  QuizDatabase db,
  KnowledgePoint kp,
) async {
  final values = {
    'id': kp.id,
    'subject_id': kp.subjectId,
    'chapter': kp.chapter,
    'name': kp.name,
  };
  final updated = await db.customUpdate(
    // SET 里含 id（原 map 写法同）：id 赋自身值，无实际改动。
    'UPDATE knowledge_points SET id = ?, subject_id = ?, chapter = ?, name = ? WHERE id = ?',
    variables: [..._variables(values), Variable.withString(kp.id)],
  );
  if (updated == 0) {
    await db.customInsert(
      'INSERT INTO knowledge_points (id, subject_id, chapter, name) VALUES (?, ?, ?, ?)',
      variables: _variables(values),
    );
  }
}

/// §4.2：删知识点同事务：知识点行 + 所有题上的该知识点。可单测版。
Future<void> deleteKnowledgePointFromImpl(QuizDatabase db, String id) async {
  await db.transaction(() async {
    await db.customUpdate(
      'DELETE FROM knowledge_points WHERE id = ?',
      variables: [Variable.withString(id)],
    );
    final rows = _rows(
      await db.customSelect('SELECT * FROM questions').get(),
    );
    for (final row in rows) {
      final q = _fromRow(row);
      if (!q.knowledgePointIds.contains(id)) continue;
      final kps = q.knowledgePointIds.where((e) => e != id).toList();
      await db.customUpdate(
        'UPDATE questions SET knowledge_ids = ? WHERE id = ?',
        variables: [
          Variable.withString(AppDatabase.encodeStringList(kps)),
          Variable.withString(q.id),
        ],
      );
    }
  });
}

/// §4.2：删除章节同事务：该章节全部知识点行 + 所有题上的这些
/// 知识点。可单测版。
Future<void> deleteChapterFromImpl(
  QuizDatabase db,
  String subjectId,
  String chapter,
) async {
  await db.transaction(() async {
    final rows = _rows(
      await db
          .customSelect(
            'SELECT id FROM knowledge_points WHERE subject_id = ? AND chapter = ?',
            variables: [
              Variable.withString(subjectId),
              Variable.withString(chapter),
            ],
          )
          .get(),
    );
    final ids = rows.map((r) => r['id'] as String).toList();
    await db.customUpdate(
      'DELETE FROM knowledge_points WHERE subject_id = ? AND chapter = ?',
      variables: [
        Variable.withString(subjectId),
        Variable.withString(chapter),
      ],
    );
    if (ids.isEmpty) return;
    final qrows = _rows(
      await db.customSelect('SELECT * FROM questions').get(),
    );
    for (final row in qrows) {
      final q = _fromRow(row);
      final kept = q.knowledgePointIds.where((e) => !ids.contains(e)).toList();
      if (kept.length == q.knowledgePointIds.length) continue;
      await db.customUpdate(
        'UPDATE questions SET knowledge_ids = ? WHERE id = ?',
        variables: [
          Variable.withString(AppDatabase.encodeStringList(kept)),
          Variable.withString(q.id),
        ],
      );
    }
  });
}

extension AppDatabaseCatalog on AppDatabase {
  Future<List<Subject>> allSubjects() async {
    final d = await db;
    // 显式按插入顺序读：subjects 表没有 sort_order 列，顺序就是 rowid 顺序；
    // 不写 orderBy 时 SQLite 不保证返回顺序，曾经因此出现过学科乱序。
    final rows = _rows(
      await d.customSelect('SELECT * FROM subjects ORDER BY rowid').get(),
    );
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
    final updated = await d.customUpdate(
      // SET 里含 id（原 map 写法同）：id 赋自身值，无实际改动。
      'UPDATE subjects SET id = ?, name = ?, color = ?, cover_style = ?, cover_color = ? WHERE id = ?',
      variables: [..._variables(values), Variable.withString(s.id)],
    );
    if (updated == 0) {
      await d.customInsert(
        'INSERT INTO subjects (id, name, color, cover_style, cover_color) VALUES (?, ?, ?, ?, ?)',
        variables: _variables(values),
      );
    }
    DataChangeBus.instance.emit(
      const DataChangeEvent(
        kinds: {DataChangeKind.badges, DataChangeKind.subjects},
      ),
    );
  }

  Future<void> deleteSubject(String id) async {
    final d = await db;
    await AppDatabase.deleteSubjectFrom(d, id);
    // 删学科同事务删掉该科全部题（含其解决记录）、任务、文件夹与知识点
    //（见 deleteSubjectFromImpl），四类都变了。
    DataChangeBus.instance.emit(
      const DataChangeEvent(
        kinds: {
          DataChangeKind.badges,
          DataChangeKind.subjects,
          DataChangeKind.questions,
          DataChangeKind.reviewRecords,
        },
      ),
    );
  }

  Future<List<Folder>> allFolders({String? subjectId}) async {
    final d = await db;
    final rows = subjectId == null
        ? _rows(
            await d
                .customSelect(
                  'SELECT * FROM folders ORDER BY subject_id ASC, sort_order ASC',
                )
                .get(),
          )
        : _rows(
            await d
                .customSelect(
                  'SELECT * FROM folders WHERE subject_id = ? ORDER BY sort_order ASC',
                  variables: [Variable.withString(subjectId)],
                )
                .get(),
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
  /// SR2-15：判重 + 插入在同一事务里。旧写法两步都在事务外，
  /// 中间有 await 间隙，两路并发同名写入可同时通过判重、先后插
  /// 入成功，库里出现两个同名文件夹（单用户串行 UI 下难触发，
  /// 但“防线”本身防不住它声称要防的情况）。
  Future<void> upsertFolder(Folder f) async {
    final d = await db;
    await d.transaction(() async {
      if (await folderNameExistsInSubjectFromImpl(
        d,
        f.subjectId,
        f.name,
        excludeId: f.id,
      )) {
        throw StateError('已经有了：同一学科下已有同名文件夹“${f.name}”');
      }
      await d.customInsert(
        'INSERT OR REPLACE INTO folders '
        '(id, name, subject_id, parent_id, sort_order) VALUES (?, ?, ?, ?, ?)',
        variables: _variables({
          'id': f.id,
          'name': f.name,
          'subject_id': f.subjectId,
          'parent_id': f.parentId,
          'sort_order': f.sortOrder,
        }),
      );
    });
    // 文件夹本身只影响学科/目录显示，不进角标查询——旧 bump 是防御性的，
    // 本阶段按实际影响只发 subjects。
    DataChangeBus.instance.emit(
      const DataChangeEvent(kinds: {DataChangeKind.subjects}),
    );
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
    // 只在该文件夹里的题随文件夹删（其解决记录同事务清掉，见
    // _deleteFolderTxn），其余题只移走关联——按条件影响的全集发。
    DataChangeBus.instance.emit(
      const DataChangeEvent(
        kinds: {
          DataChangeKind.badges,
          DataChangeKind.subjects,
          DataChangeKind.questions,
          DataChangeKind.reviewRecords,
        },
      ),
    );
    return deleted;
  }

  Future<List<String>> allTags() async => AppDatabase.allTagsFrom(await db);

  Future<void> insertTag(String name) async {
    final d = await db;
    await d.customInsert(
      'INSERT OR IGNORE INTO tags (id, name) VALUES (?, ?)',
      variables: [
        Variable.withString('tag-$name'),
        Variable.withString(name),
      ],
    );
    DataChangeBus.instance.emit(
      const DataChangeEvent(kinds: {DataChangeKind.subjects}),
    );
  }

  Future<void> renameTag(String oldName, String newName) async {
    final d = await db;
    await AppDatabase.renameTagFrom(d, oldName, newName);
    // 改标签名同事务改掉所有挂了旧标签的题（见 renameTagFromImpl）。
    DataChangeBus.instance.emit(
      const DataChangeEvent(
        kinds: {DataChangeKind.subjects, DataChangeKind.questions},
      ),
    );
  }

  Future<void> deleteTag(String name) async {
    final d = await db;
    await AppDatabase.deleteTagFrom(d, name);
    // 删标签同事务去掉所有题上的该标签（见 deleteTagFromImpl）。
    DataChangeBus.instance.emit(
      const DataChangeEvent(
        kinds: {DataChangeKind.subjects, DataChangeKind.questions},
      ),
    );
  }

  Future<List<Exam>> allExams() async => AppDatabase.allExamsFrom(await db);

  Future<void> insertExam(Exam e) async {
    final d = await db;
    await AppDatabase.insertExamInto(d, e);
    DataChangeBus.instance.emit(
      const DataChangeEvent(kinds: {DataChangeKind.subjects}),
    );
  }

  Future<void> renameExam(String id, String newName) async {
    final d = await db;
    await d.customUpdate(
      'UPDATE exams SET name = ? WHERE id = ?',
      variables: [Variable.withString(newName), Variable.withString(id)],
    );
    DataChangeBus.instance.emit(
      const DataChangeEvent(kinds: {DataChangeKind.subjects}),
    );
  }

  Future<void> deleteExam(String id) async {
    final d = await db;
    await AppDatabase.deleteExamFrom(d, id);
    // 删试卷同事务把所有题上的该试卷引用置空（见 deleteExamFromImpl）。
    DataChangeBus.instance.emit(
      const DataChangeEvent(
        kinds: {DataChangeKind.subjects, DataChangeKind.questions},
      ),
    );
  }

  Future<List<KnowledgePoint>> allKnowledgePoints() async =>
      AppDatabase.allKnowledgePointsFrom(await db);

  Future<void> insertKnowledgePoint(KnowledgePoint kp) async {
    final d = await db;
    await AppDatabase.insertKnowledgePointInto(d, kp);
    DataChangeBus.instance.emit(
      const DataChangeEvent(kinds: {DataChangeKind.subjects}),
    );
  }

  Future<void> renameKnowledgePoint(String id, String newName) async {
    final d = await db;
    await d.customUpdate(
      'UPDATE knowledge_points SET name = ? WHERE id = ?',
      variables: [Variable.withString(newName), Variable.withString(id)],
    );
    DataChangeBus.instance.emit(
      const DataChangeEvent(kinds: {DataChangeKind.subjects}),
    );
  }

  Future<void> deleteKnowledgePoint(String id) async {
    final d = await db;
    await AppDatabase.deleteKnowledgePointFrom(d, id);
    // 删知识点同事务去掉所有题上的该知识点（见 deleteKnowledgePointFromImpl）。
    DataChangeBus.instance.emit(
      const DataChangeEvent(
        kinds: {DataChangeKind.subjects, DataChangeKind.questions},
      ),
    );
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
    await d.customUpdate(
      'UPDATE knowledge_points SET chapter = ? WHERE subject_id = ? AND chapter = ?',
      variables: [
        Variable.withString(newChapter),
        Variable.withString(subjectId),
        Variable.withString(oldChapter),
      ],
    );
    DataChangeBus.instance.emit(
      const DataChangeEvent(kinds: {DataChangeKind.subjects}),
    );
  }

  /// 删除章节：删掉该章节下全部知识点；题还在，只是这些知识点变空、
  /// 成为待补充（与删知识点同一口径）。
  Future<void> deleteChapter(String subjectId, String chapter) async {
    final d = await db;
    await AppDatabase.deleteChapterFrom(d, subjectId, chapter);
    // 删章节同事务去掉所有题上的这些知识点（见 deleteChapterFromImpl）。
    DataChangeBus.instance.emit(
      const DataChangeEvent(
        kinds: {DataChangeKind.subjects, DataChangeKind.questions},
      ),
    );
  }
}
