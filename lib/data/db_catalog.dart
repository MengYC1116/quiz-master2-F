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
  final sliceRows = await (db.select(
    db.questions,
  )..where((t) => t.subjectId.equals(id))).get();
  final slices = sliceRows.map((r) => r.slicePath).toList();
  final taskRows = await (db.select(
    db.collectTasks,
  )..where((t) => t.subjectId.equals(id))).get();
  final taskIds = taskRows.map((r) => r.id).toList();
  await db.transaction(() async {
    final qs = await (db.select(
      db.questions,
    )..where((t) => t.subjectId.equals(id))).get();
    for (final row in qs) {
      await _deleteQuestionTxn(db, row.id);
    }
    // SR-P2-1：先清该科任务的草稿框，再删任务行。
    if (taskIds.isNotEmpty) {
      await (db.delete(
        db.questionBoxes,
      )..where((b) => b.collectTaskId.isIn(taskIds))).go();
    }
    await (db.delete(
      db.collectTasks,
    )..where((t) => t.subjectId.equals(id))).go();
    // B2 补充（W-settings 验收发现）：删学科流程里的 recent_tasks
    // 删除也改走 Drift 类型化删除（recent_tasks 表本身仍属
    // W-settings 的迁移范围，本处只是删学科事务内的一条语句）。
    await (db.delete(
      db.recentTasks,
    )..where((t) => t.subjectId.equals(id))).go();
    // B2 集成：本事务内的 questions / collect_tasks /
    // question_boxes 读删也已走 Drift 类型化（见本函数头部的
    // 类型化查询与删除），不再有 custom SQL。
    await (db.delete(db.folders)..where((t) => t.subjectId.equals(id))).go();
    await (db.delete(
      db.knowledgePoints,
    )..where((t) => t.subjectId.equals(id))).go();
    await (db.delete(db.subjects)..where((t) => t.id.equals(id))).go();
  });
  for (final slice in slices) {
    await _deleteDataFileIfUnreferenced(db, slice);
  }
  for (final taskId in taskIds) {
    await _deleteTaskDirIfUnreferenced(db, taskId);
  }
}

/// §4.2：删文件夹（可单测版）：整棵子树一次事务，不 bump。
/// 事务提交后删被删掉的题的切片（只删库里已不存在的题的切片，
/// 且只删无引用文件；只移走关联的题不动文件）。
Future<int> deleteFolderFromImpl(QuizDatabase db, Folder f) async {
  // B2 集成：前后两次 questions 全表读走 Drift 类型化（原 SELECT
  // id, slice_path / SELECT id FROM questions）。
  final before = await db.select(db.questions).get();
  var deleted = 0;
  await db.transaction(() async {
    deleted = await _deleteFolderTxn(db, f);
  });
  final remaining = await db.select(db.questions).get();
  final remainingIds = {for (final r in remaining) r.id};
  for (final row in before) {
    if (!remainingIds.contains(row.id)) {
      await _deleteDataFileIfUnreferenced(db, row.slicePath);
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
  // B2 集成：folder_ids LIKE 粗筛走类型化 select；folderIds 列是
  // StringListConverter 映射的 List<String>，Drift 没有原生 `like`
  //（`like` 只在非空 Expression<String> 上），故列本身用
  // CustomExpression<String> 按引用名取（与全仓已有的
  // CustomExpression('rowid') 同一先例），pattern 与 ESCAPE 仍走
  // `like` 的绑定变量；内存精筛口径不变。
  final rows =
      await (db.select(db.questions)..where(
            (_) =>
                CustomExpression<String>('"folder_ids"')
                    .like('%"${_likeEscape(f.id)}"%', escapeChar: '\\'),
          ))
          .get();
  var deleted = 0;
  for (final row in rows) {
    final q = _questionFromDb(row);
    final folderIds = q.folderIds;
    if (!folderIds.contains(f.id)) continue;
    final qid = q.id;
    if (folderIds.length == 1) {
      await _deleteQuestionTxn(db, qid);
      deleted++;
    } else {
      final rest = folderIds.where((e) => e != f.id).toList();
      await (db.update(db.questions)..where((t) => t.id.equals(qid))).write(
        QuestionsCompanion(folderIds: Value(rest)),
      );
    }
  }
  // 子文件夹随父文件夹一起删（同规则递归到子文件夹里的题）。
  // B2：第 2 阶段类型化——folders 表改走 Drift 类型化查询；
  // 上面的 questions LIKE 粗筛也已走类型化 select（见本函数头部）。
  final subs = await (db.select(
    db.folders,
  )..where((t) => t.parentId.equals(f.id))).get();
  for (final s in subs) {
    final sub = Folder(
      id: s.id,
      name: s.name,
      subjectId: s.subjectId,
      parentId: s.parentId,
    );
    deleted += await _deleteFolderTxn(db, sub);
  }
  await (db.delete(db.folders)..where((t) => t.id.equals(f.id))).go();
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
/// 参数是 [QuizDatabase]（SR2-15：[upsertFolder] 在同一事务内
/// 先判重后插入，须把事务句柄传进来；与已删的 `_seedCauseRecordsFor`
/// 同一放宽口径）。B2：第 2 阶段类型化——Drift 里事务回调不带
/// txn 参数，在 `db.transaction` 回调内直接用外层数据库对象
/// 操作即走该事务，因此这里用 [QuizDatabase] 而不用
/// [DatabaseConnectionUser]（后者没有表访问器，做不了类型化
/// 查询）；原签名只在库内经 [AppDatabase.folderNameExistsInSubjectFrom]
/// 转发，公开 API 不变。
Future<bool> folderNameExistsInSubjectFromImpl(
  QuizDatabase db,
  String subjectId,
  String name, {
  String? excludeId,
}) async {
  final query = db.select(db.folders)
    ..where((t) => t.subjectId.equals(subjectId) & t.name.equals(name))
    ..limit(1);
  if (excludeId != null) {
    query.where((t) => t.id.isNotValue(excludeId));
  }
  // 原 SQL 带 LIMIT 1：getSingleOrNull 遇多行会抛，limit 不可省。
  final row = await query.getSingleOrNull();
  return row != null;
}

/// B2-4：按插入顺序读（rowid）；不写 orderBy 时 SQLite 不保证顺序，
/// 曾因此出现学科乱序（见 [AppDatabase.upsertSubject] 的修法说明）。
/// B2：第 2 阶段类型化——生成表类没有 rowid 列访问器，排序用
/// `CustomExpression<int>('rowid')` 显式引用隐式 rowid 列，
/// 语义与原 `ORDER BY rowid` 完全一致。
Future<List<String>> allTagsFromImpl(QuizDatabase db) async {
  final rows =
      await (db.select(db.tags)..orderBy([
            (t) =>
                OrderingTerm(expression: const CustomExpression<int>('rowid')),
          ]))
          .get();
  return rows.map((r) => r.name).toList();
}

/// §4.2：改标签名同事务：标签行改名 + 所有挂了旧标签的题改标签。
/// 可单测版（直接对传入的库句柄做，不碰单例）。
Future<void> renameTagFromImpl(
  QuizDatabase db,
  String oldName,
  String newName,
) async {
  await db.transaction(() async {
    // B2 集成：questions 全表循环走 Drift 类型化读 + 类型化
    // update（原 SELECT * FROM questions + _fromRow + 逐行
    // customUpdate）。行映射复用 db_questions.dart 的同库私有
    // [_questionFromDb]（part of 同一库，无需改公开或另复制一份）。
    await (db.update(db.tags)..where((t) => t.name.equals(oldName))).write(
      TagsCompanion(id: Value('tag-$newName'), name: Value(newName)),
    );
    final rows = await db.select(db.questions).get();
    for (final row in rows) {
      final q = _questionFromDb(row);
      if (!q.tags.contains(oldName)) continue;
      final tags = q.tags.map((t) => t == oldName ? newName : t).toList();
      await (db.update(db.questions)..where((t) => t.id.equals(q.id))).write(
        QuestionsCompanion(tags: Value(tags)),
      );
    }
  });
}

/// §4.2：删标签同事务：标签行 + 所有题上的该标签。可单测版。
Future<void> deleteTagFromImpl(QuizDatabase db, String name) async {
  await db.transaction(() async {
    // B2 集成：同 renameTagFromImpl——questions 全表循环走 Drift
    // 类型化读 + 类型化 update。
    await (db.delete(db.tags)..where((t) => t.name.equals(name))).go();
    final rows = await db.select(db.questions).get();
    for (final row in rows) {
      final q = _questionFromDb(row);
      if (!q.tags.contains(name)) continue;
      final tags = q.tags.where((t) => t != name).toList();
      await (db.update(db.questions)..where((t) => t.id.equals(q.id))).write(
        QuestionsCompanion(tags: Value(tags)),
      );
    }
  });
}

/// B2-4：按插入顺序读（rowid），见 [AppDatabase.allTagsFrom]。
/// B2：第 2 阶段类型化——rowid 排序见 [allTagsFromImpl] 的说明。
Future<List<Exam>> allExamsFromImpl(QuizDatabase db) async {
  final rows =
      await (db.select(db.exams)..orderBy([
            (t) =>
                OrderingTerm(expression: const CustomExpression<int>('rowid')),
          ]))
          .get();
  return rows
      .map(
        (r) => Exam(
          id: r.id,
          name: r.name,
          date: r.date == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(r.date!),
        ),
      )
      .toList();
}

/// B2-4：原地更新（与 [AppDatabase.upsertSubject] 同一口径）：已存在的行只
/// UPDATE，rowid 不变、顺序不动；不存在时才 INSERT。REPLACE 是
/// 先删后插，会把这行顶到表尾（改试卷名，试卷就跑到最下面）。
/// B2：第 2 阶段类型化——update 返回受影响行数，0 行时再 insert；
/// SET 含 id 自赋值（原 map 写法同），类型化 write 里 id 照写。
Future<void> insertExamIntoImpl(QuizDatabase db, Exam e) async {
  final updated = await (db.update(db.exams)..where((t) => t.id.equals(e.id)))
      .write(
        ExamsCompanion(
          id: Value(e.id),
          name: Value(e.name),
          date: Value(e.date?.millisecondsSinceEpoch),
        ),
      );
  if (updated == 0) {
    await db
        .into(db.exams)
        .insert(
          ExamsCompanion.insert(
            id: e.id,
            name: e.name,
            date: Value(e.date?.millisecondsSinceEpoch),
          ),
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
    // B2 集成：questions 置空走 Drift 类型化 update（原 UPDATE
    // questions SET exam_id = NULL WHERE exam_id = ?）。
    await (db.delete(db.exams)..where((t) => t.id.equals(id))).go();
    await (db.update(db.questions)..where((t) => t.examId.equals(id))).write(
      const QuestionsCompanion(examId: Value(null)),
    );
  });
}

/// B2-4：按插入顺序读（rowid），见 [AppDatabase.allTagsFrom]。
/// B2：第 2 阶段类型化——rowid 排序见 [allTagsFromImpl] 的说明。
/// 知识点的“树”是学科 → 章节 → 知识点（chapter 分组），表上
/// 没有 parent_id 列，不存在父子 id 关系。
Future<List<KnowledgePoint>> allKnowledgePointsFromImpl(QuizDatabase db) async {
  final rows =
      await (db.select(db.knowledgePoints)..orderBy([
            (t) =>
                OrderingTerm(expression: const CustomExpression<int>('rowid')),
          ]))
          .get();
  return rows
      .map(
        (r) => KnowledgePoint(
          id: r.id,
          subjectId: r.subjectId,
          chapter: r.chapter,
          name: r.name,
        ),
      )
      .toList();
}

/// B2-4：原地更新（与 [AppDatabase.upsertSubject] 同一口径）：已存在的行只
/// UPDATE，rowid 不变、顺序不动；不存在时才 INSERT。
/// REPLACE 是先删后插，会把这行顶到表尾。
/// B2：第 2 阶段类型化——与 [insertExamIntoImpl] 同一口径。
Future<void> insertKnowledgePointIntoImpl(
  QuizDatabase db,
  KnowledgePoint kp,
) async {
  final updated =
      await (db.update(
        db.knowledgePoints,
      )..where((t) => t.id.equals(kp.id))).write(
        KnowledgePointsCompanion(
          id: Value(kp.id),
          subjectId: Value(kp.subjectId),
          chapter: Value(kp.chapter),
          name: Value(kp.name),
        ),
      );
  if (updated == 0) {
    await db
        .into(db.knowledgePoints)
        .insert(
          KnowledgePointsCompanion.insert(
            id: kp.id,
            subjectId: kp.subjectId,
            chapter: kp.chapter,
            name: kp.name,
          ),
        );
  }
}

/// §4.2：删知识点同事务：知识点行 + 所有题上的该知识点。可单测版。
Future<void> deleteKnowledgePointFromImpl(QuizDatabase db, String id) async {
  await db.transaction(() async {
    // B2 集成：同 renameTagFromImpl——questions 全表循环走 Drift
    // 类型化读 + 类型化 update。
    await (db.delete(db.knowledgePoints)..where((t) => t.id.equals(id))).go();
    final rows = await db.select(db.questions).get();
    for (final row in rows) {
      final q = _questionFromDb(row);
      if (!q.knowledgePointIds.contains(id)) continue;
      final kps = q.knowledgePointIds.where((e) => e != id).toList();
      await (db.update(db.questions)..where((t) => t.id.equals(q.id))).write(
        QuestionsCompanion(knowledgeIds: Value(kps)),
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
    // B2 集成：knowledge_points 的章节查 id 与删行走类型化查询；
    // 下面的 questions 全表循环也已走 Drift 类型化（见下）。
    final rows =
        await (db.select(db.knowledgePoints)..where(
              (t) => t.subjectId.equals(subjectId) & t.chapter.equals(chapter),
            ))
            .get();
    final ids = rows.map((r) => r.id).toList();
    await (db.delete(db.knowledgePoints)..where(
          (t) => t.subjectId.equals(subjectId) & t.chapter.equals(chapter),
        ))
        .go();
    if (ids.isEmpty) return;
    // B2 集成：同 deleteKnowledgePointFromImpl——questions 全表循环
    // 走 Drift 类型化读 + 类型化 update。
    final qrows = await db.select(db.questions).get();
    for (final row in qrows) {
      final q = _questionFromDb(row);
      final kept = q.knowledgePointIds.where((e) => !ids.contains(e)).toList();
      if (kept.length == q.knowledgePointIds.length) continue;
      await (db.update(db.questions)..where((t) => t.id.equals(q.id))).write(
        QuestionsCompanion(knowledgeIds: Value(kept)),
      );
    }
  });
}

extension AppDatabaseCatalog on AppDatabase {
  Future<List<Subject>> allSubjects() async {
    final d = await db;
    // 显式按插入顺序读：subjects 表没有 sort_order 列，顺序就是 rowid 顺序；
    // 不写 orderBy 时 SQLite 不保证返回顺序，曾经因此出现过学科乱序。
    // B2：第 2 阶段类型化——rowid 排序见 [allTagsFromImpl] 的说明。
    // cover_style / cover_color / color 在 Drift 行类里是非空类型
    //（列有默认值，seed 与 upsert 始终写值），原 `??` 兜底不再需要。
    final rows =
        await (d.select(d.subjects)..orderBy([
              (t) => OrderingTerm(
                expression: const CustomExpression<int>('rowid'),
              ),
            ]))
            .get();
    return rows
        .map(
          (r) => Subject(
            id: r.id,
            name: r.name,
            color: Color(r.color),
            icon: _iconFor(r.id),
            coverStyle: r.coverStyle,
            coverColor: r.coverColor,
          ),
        )
        .toList();
  }

  Future<void> upsertSubject(Subject s) async {
    final d = await db;
    // 原地更新：ConflictAlgorithm.replace 是先删后插，会把这行顶到表尾，
    // 导致学科顺序乱掉（点数学的封面，数学就跑到最下面）。已存在的行只
    // UPDATE，rowid 不变，顺序就不会动；不存在时才 INSERT。
    // B2：第 2 阶段类型化——与 [insertExamIntoImpl] 同一口径。
    // 注意：种子写入路径不在本文件（_seed 在 db_schema.dart，仍走
    // 原 custom SQL，本次不动）；这里是运行期 upsert 路径。
    final updated =
        await (d.update(d.subjects)..where((t) => t.id.equals(s.id))).write(
          SubjectsCompanion(
            id: Value(s.id),
            name: Value(s.name),
            color: Value(s.color.toARGB32()),
            coverStyle: Value(s.coverStyle),
            coverColor: Value(s.coverColor),
          ),
        );
    if (updated == 0) {
      await d
          .into(d.subjects)
          .insert(
            SubjectsCompanion.insert(
              id: s.id,
              name: s.name,
              color: s.color.toARGB32(),
              coverStyle: Value(s.coverStyle),
              coverColor: Value(s.coverColor),
            ),
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
    // B2：第 2 阶段类型化——原两条 SQL 的 WHERE 与 ORDER BY 语义
    // 不变：无 subjectId 时按 subject_id ASC, sort_order ASC；
    // 有 subjectId 时只取该科、按 sort_order ASC。
    final query = d.select(d.folders);
    if (subjectId == null) {
      query.orderBy([
        (t) => OrderingTerm(expression: t.subjectId),
        (t) => OrderingTerm(expression: t.sortOrder),
      ]);
    } else {
      query.where((t) => t.subjectId.equals(subjectId));
      query.orderBy([(t) => OrderingTerm(expression: t.sortOrder)]);
    }
    final rows = await query.get();
    return rows
        .map(
          (r) => Folder(
            id: r.id,
            name: r.name,
            subjectId: r.subjectId,
            parentId: r.parentId,
            sortOrder: r.sortOrder,
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
      await d
          .into(d.folders)
          .insert(
            FoldersCompanion.insert(
              id: f.id,
              name: f.name,
              subjectId: f.subjectId,
              parentId: Value(f.parentId),
              sortOrder: Value(f.sortOrder),
            ),
            // 原 `INSERT OR REPLACE`：先删后插，rowid 会变——
            // 文件夹没有“原地更新保顺序”的要求（见 upsertSubject
            // 的修法说明），此处原样保留 REPLACE 语义，不改成
            // update-or-insert。
            mode: InsertMode.insertOrReplace,
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
  }) async => AppDatabase.folderNameExistsInSubjectFrom(
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
    // B2：第 2 阶段类型化——原 `INSERT OR IGNORE`（同名标签去重，
    // id 为 'tag-$name'），语义不变。
    await d
        .into(d.tags)
        .insert(
          TagsCompanion.insert(id: 'tag-$name', name: name),
          mode: InsertMode.insertOrIgnore,
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
    // B2：第 2 阶段类型化。
    await (d.update(d.exams)..where((t) => t.id.equals(id))).write(
      ExamsCompanion(name: Value(newName)),
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
    // B2：第 2 阶段类型化。
    await (d.update(d.knowledgePoints)..where((t) => t.id.equals(id))).write(
      KnowledgePointsCompanion(name: Value(newName)),
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
    // B2：第 2 阶段类型化——只改 chapter 列，题上挂的知识点 id 不变。
    await (d.update(d.knowledgePoints)..where(
          (t) => t.subjectId.equals(subjectId) & t.chapter.equals(oldChapter),
        ))
        .write(KnowledgePointsCompanion(chapter: Value(newChapter)));
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
