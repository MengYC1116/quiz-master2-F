// B4：database.dart 拆分——收集任务 / question_boxes（草稿、重框、确认拆题）/ 文件级联删除。
// 与 database.dart 同一库（part of），共享库私有成员；纯重构，行为不变。
// ARCH-PLAN-B 第 1 阶段：sqflite 结构化调用 → Drift custom* API，SQL 语义保留。

part of 'database.dart';

/// §4.3：按 created_at 稳定排序（同毫秒建的批量任务用 rowid 兜底）。
Future<List<CollectTask>> allCollectTasksFromImpl(QuizDatabase db) async {
  final rows =
      (await db
              .customSelect(
                'SELECT * FROM collect_tasks ORDER BY created_at DESC, rowid DESC',
              )
              .get())
          .map((r) => r.data)
          .toList();
  return rows.map(_collectTaskFromRow).toList();
}

/// §4.3：UPDATE-first（照 upsertSubject 的正面先例）：REPLACE 是
/// 先删后插，会改 rowid、把行顶到最上面，进度高频更新时任务列表
/// 自己跳序。已存在的行只 UPDATE（不碰 created_at，rowid 不变，
/// 顺序就不动）；不存在时才 INSERT，并写 created_at（调用方没给
/// 就写当前时间）。
Future<void> upsertCollectTaskIntoImpl(QuizDatabase db, CollectTask t) async {
  final values = _collectTaskToRow(t);
  final updated = await db.customUpdate(
    'UPDATE collect_tasks SET id = ?, name = ?, file_name = ?, '
    'subject_id = ?, status = ?, progress = ?, page_count = ?, page = ?, '
    'error = ?, question_id = ?, source_path = ?, page_rotations = ? '
    'WHERE id = ?',
    variables: [
      Variable(values['id']),
      Variable(values['name']),
      Variable(values['file_name']),
      Variable(values['subject_id']),
      Variable(values['status']),
      Variable(values['progress']),
      Variable(values['page_count']),
      Variable(values['page']),
      Variable(values['error']),
      Variable(values['question_id']),
      Variable(values['source_path']),
      Variable(values['page_rotations']),
      Variable.withString(t.id),
    ],
  );
  if (updated == 0) {
    await db.customInsert(
      'INSERT INTO collect_tasks (id, name, file_name, subject_id, status, '
      'progress, page_count, page, error, question_id, source_path, '
      'page_rotations, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '
      '?, ?, ?)',
      variables: [
        Variable(values['id']),
        Variable(values['name']),
        Variable(values['file_name']),
        Variable(values['subject_id']),
        Variable(values['status']),
        Variable(values['progress']),
        Variable(values['page_count']),
        Variable(values['page']),
        Variable(values['error']),
        Variable(values['question_id']),
        Variable(values['source_path']),
        Variable(values['page_rotations']),
        Variable.withInt(
          t.createdAt?.millisecondsSinceEpoch ??
              DateTime.now().millisecondsSinceEpoch,
        ),
      ],
    );
  }
}

/// B9-1 回填（可单测版）：把题已整理、任务仍 pendingOrganize 的
/// 卡住行持久化置 done，返回治好的行数。只改同时满足三条的行：
/// 任务仍是 pendingOrganize、question_id 非空、指向的题已整理
/// （is_organized = 1）。其它状态（needBox / boxing / importing /
/// queued / failed / 已是 done）与无题可指的行一律不动；题未整
/// 理的行不动。单条 UPDATE，幂等、无新字段、不改 Schema。
/// 调用点：[AppDatabase.openAtImpl] 的 onOpen（每次开库扫一遍，
/// Meng 库里卡住的 13 行下次启动即变过来）与单测直接调用。
/// 恢复（importBackupJsonInto）整表重插、绕过 upsertQuestion，
/// 恢复当次不扫——备份里带来的卡住行在下次启动开库时治好，见
/// B9-1 报告“残留口子”。
Future<int> backfillCollectDoneIntoImpl(QuizDatabase db) async {
  return db.customUpdate('''
    UPDATE collect_tasks SET status = 'done'
    WHERE status = 'pendingOrganize'
      AND question_id IS NOT NULL
      AND question_id IN (SELECT id FROM questions WHERE is_organized = 1)
  ''');
}

/// §1.2(c) + B2-6a：删任务（可单测版）：一次事务，不 bump。
/// 事务内：待整理的拆出题（经 _deleteQuestionTxn，含其框、解决记录、
/// 自查历史、复习队列项）→ 未确认的草稿框 → 任务行。事务提交后，
/// 若没有任何题的 source_path / page_image_path 还指向该任务
/// 目录（`imports/<taskId>/`），删整个任务目录；已确认拆题的
/// 任务页图还被题引用，目录保留（§4.5）。被删的待整理题若有独占
/// 切片，事务提交后删无引用的切片文件（与 deleteQuestionFrom 同款）。
Future<void> deleteCollectTaskFromImpl(QuizDatabase db, String id) async {
  String? sliceToClean;
  await db.transaction(() async {
    // 先读任务指向的题：is_organized 在事务内读，避免读到删之间
    // 被整理工作台改掉状态。
    final taskRows =
        (await db
                .customSelect(
                  'SELECT question_id FROM collect_tasks WHERE id = ? LIMIT 1',
                  variables: [Variable.withString(id)],
                )
                .get())
            .map((r) => r.data)
            .toList();
    final questionId = taskRows.isEmpty
        ? null
        : taskRows.first['question_id'] as String?;
    if (questionId != null) {
      final qRows =
          (await db
                  .customSelect(
                    'SELECT is_organized, slice_path FROM questions '
                    'WHERE id = ? LIMIT 1',
                    variables: [Variable.withString(questionId)],
                  )
                  .get())
              .map((r) => r.data)
              .toList();
      if (qRows.isNotEmpty && (qRows.first['is_organized'] as int?) != 1) {
        sliceToClean = qRows.first['slice_path'] as String?;
        await _deleteQuestionTxn(db, questionId);
      }
    }
    await db.customUpdate(
      'DELETE FROM question_boxes '
      'WHERE collect_task_id = ? AND question_id IS NULL',
      variables: [Variable.withString(id)],
    );
    await db.customUpdate(
      'DELETE FROM collect_tasks WHERE id = ?',
      variables: [Variable.withString(id)],
    );
  });
  await _deleteDataFileIfUnreferenced(db, sliceToClean);
  await _deleteTaskDirIfUnreferenced(db, id);
}

/// §4.5 文件级联：删库内文件（只删无引用文件）。
/// - [rel] 必须是 `slices/` 下的相对路径（本函数唯一接受的
///   前缀；调用方只传题的 `slice_path`）；绝对路径、`..` 越界、
///   `imports/` 或其它前缀一律拒绝删除——误删是丢数据，宁留孤儿；
/// - 解析失败或仍被任何题/任务引用 → 不删；
/// - 文件删失败静默跳过（由孤儿清理兜底），不抛错、不回滚数据库。
/// 解析统一走 [AppDatabase._resolveInsideDir]，不再经 [AppDatabase.resolveDataPath]。
Future<void> _deleteDataFileIfUnreferenced(QuizDatabase db, String? rel) async {
  if (rel == null || rel.isEmpty) return;
  final normalized = rel.replaceAll('\\', '/');
  if (!normalized.startsWith('slices/')) return;
  final abs = _resolveInsideDir(AppDatabase.dataDirectoryPath(), normalized);
  if (abs == null) return;
  if (await _isFileReferenced(db, rel)) return;
  try {
    final f = File(abs);
    if (f.existsSync()) await f.delete();
  } catch (_) {}
}

Future<bool> _isFileReferenced(QuizDatabase db, String rel) async {
  for (final col in ['source_path', 'page_image_path', 'slice_path']) {
    final rows =
        (await db
                .customSelect(
                  'SELECT id FROM questions WHERE $col = ? LIMIT 1',
                  variables: [Variable.withString(rel)],
                )
                .get())
            .map((r) => r.data)
            .toList();
    if (rows.isNotEmpty) return true;
  }
  final tasks =
      (await db
              .customSelect(
                'SELECT id FROM collect_tasks WHERE source_path = ? LIMIT 1',
                variables: [Variable.withString(rel)],
              )
              .get())
          .map((r) => r.data)
          .toList();
  return tasks.isNotEmpty;
}

/// §4.5：删任务目录（`imports/<taskId>/`）——仅当没有任何题的
/// source_path / page_image_path 还指向该目录下时才删。
/// SR-P2-15：同时查 `collect_tasks.source_path`——拆分任务的
/// source_path 指向原任务目录（`imports/<原任务id>/original.pdf`），
/// 只查题会漏掉这条引用。拆分任务目前不直接读该文件，实际影响≈0，
/// 但检查口径与函数注释“没有任何题还指向该目录”之外的任务引用
/// 存在缺口。LIKE 里的 `_`/`%` 先转义（见 [_likeEscape]），
/// 含 `_` 的任务 id 不会误匹配其它目录。
/// B3-P01：先校验 taskId 只含安全字符（字母/数字/`_`/`-`）；
/// `../slices` 这类 id 直接拒绝——不能靠“前缀检查”蒙混，
/// `imports/../slices` 规范化后就是数据目录下的 `slices/`，
/// 旧写法会把整个切片目录递归删掉。
Future<void> _deleteTaskDirIfUnreferenced(
  QuizDatabase db,
  String taskId,
) async {
  if (!_safeTaskIdPattern.hasMatch(taskId)) return;
  final prefix = 'imports/$taskId/';
  final escaped = _likeEscape(prefix);
  for (final col in ['source_path', 'page_image_path']) {
    final rows =
        (await db
                .customSelect(
                  'SELECT id FROM questions WHERE $col LIKE ? ESCAPE ? LIMIT 1',
                  variables: [
                    Variable.withString('$escaped%'),
                    Variable.withString('\\'),
                  ],
                )
                .get())
            .map((r) => r.data)
            .toList();
    if (rows.isNotEmpty) return;
  }
  // SR-P2-15：拆分任务行的 source_path 也可能指向该目录。
  final taskRefs =
      (await db
              .customSelect(
                'SELECT id FROM collect_tasks WHERE source_path LIKE ? '
                'ESCAPE ? LIMIT 1',
                variables: [
                  Variable.withString('$escaped%'),
                  Variable.withString('\\'),
                ],
              )
              .get())
          .map((r) => r.data)
          .toList();
  if (taskRefs.isNotEmpty) return;
  final abs = _resolveInsideDir(
    AppDatabase.dataDirectoryPath(),
    'imports/$taskId',
  );
  if (abs == null) return;
  try {
    final dir = Directory(abs);
    if (dir.existsSync()) await dir.delete(recursive: true);
  } catch (_) {}
}

/// §8.1：写框（可单测版）：直接对传入的库句柄写，不碰单例、不 bump。
/// id 规则见 §1.2(c)：`box-<taskId>-p<page>-<uuid8>`（调用方生成）。
Future<void> insertQuestionBoxIntoImpl(QuizDatabase db, QuestionBox b) async {
  final row = _questionBoxToRow(b);
  await db.customInsert(
    'INSERT INTO question_boxes (id, collect_task_id, question_id, '
    'parent_box_id, page, layer, type, x, y, w, h, confidence, origin, '
    'updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    variables: [
      Variable(row['id']),
      Variable(row['collect_task_id']),
      Variable(row['question_id']),
      Variable(row['parent_box_id']),
      Variable(row['page']),
      Variable(row['layer']),
      Variable(row['type']),
      Variable(row['x']),
      Variable(row['y']),
      Variable(row['w']),
      Variable(row['h']),
      Variable(row['confidence']),
      Variable(row['origin']),
      Variable(row['updated_at']),
    ],
  );
}

/// §8.1：读某题的全部框（可单测版）。
Future<List<QuestionBox>> boxesForQuestionFromImpl(
  QuizDatabase db,
  String questionId,
) async {
  final rows =
      (await db
              .customSelect(
                'SELECT * FROM question_boxes WHERE question_id = ? '
                'ORDER BY page ASC, id ASC',
                variables: [Variable.withString(questionId)],
              )
              .get())
          .map((r) => r.data)
          .toList();
  return rows.map(_questionBoxFromRow).toList();
}

/// §1.5：读某任务的全部草稿框（各页，用于“继续修框”恢复）。
Future<List<QuestionBox>> boxesForTaskFromImpl(
  QuizDatabase db,
  String taskId,
) async {
  final rows =
      (await db
              .customSelect(
                'SELECT * FROM question_boxes '
                'WHERE collect_task_id = ? AND question_id IS NULL '
                'ORDER BY page ASC, id ASC',
                variables: [Variable.withString(taskId)],
              )
              .get())
          .map((r) => r.data)
          .toList();
  return rows.map(_questionBoxFromRow).toList();
}

/// §1.5：读某任务某页的草稿框。
Future<List<QuestionBox>> boxesForTaskPageFromImpl(
  QuizDatabase db,
  String taskId,
  int page,
) async {
  final rows =
      (await db
              .customSelect(
                'SELECT * FROM question_boxes '
                'WHERE collect_task_id = ? AND page = ? AND question_id IS NULL '
                'ORDER BY page ASC, id ASC',
                variables: [
                  Variable.withString(taskId),
                  Variable.withInt(page),
                ],
              )
              .get())
          .map((r) => r.data)
          .toList();
  return rows.map(_questionBoxFromRow).toList();
}

/// §1.5.1：读同一页图上全部已确认题的框（重框同页上下文）：
/// 分组键是 `questions.page_image_path`（确认后 collect_task_id
/// 已是 NULL，不能靠任务分组）。返回该页各题的全部框。
Future<List<QuestionBox>> boxesForPageImageFromImpl(
  QuizDatabase db,
  String pageImagePath,
) async {
  final qs =
      (await db
              .customSelect(
                'SELECT id FROM questions WHERE page_image_path = ? '
                'ORDER BY id ASC',
                variables: [Variable.withString(pageImagePath)],
              )
              .get())
          .map((r) => r.data)
          .toList();
  if (qs.isEmpty) return const [];
  final ids = qs.map((r) => r['id'] as String).toList();
  final where = 'question_id IN (${List.filled(ids.length, '?').join(',')})';
  // SR2-27：与 boxesForTask 对齐，按页、id 排序——无 ORDER BY 时
  // SQLite 不保证行序（通常是 rowid 序，但不保证）。
  final rows =
      (await db
              .customSelect(
                'SELECT * FROM question_boxes WHERE $where '
                'ORDER BY page ASC, id ASC',
                variables: [for (final id in ids) Variable.withString(id)],
              )
              .get())
          .map((r) => r.data)
          .toList();
  return rows.map(_questionBoxFromRow).toList();
}

/// §1.5：草稿保存（可单测版）：一次事务。
/// - 按页替换：删该任务该页的草稿框，再插入当前页内存里的框；
/// - `rotations` 是草稿的全部按页旋转角度，一起写进
///   `collect_tasks.page_rotations`（§1.6.1）。
/// 只动该任务该页的草稿框，已确认的题框一律不动。
/// SR-P2-14：两条调用方契约——(a) 旋转角写回时任务行必须存在：
/// `update` 影响 0 行（任务已被删）时抛错回滚，不再让框照常写进
/// 去（成孤儿草稿）而旋转角静默丢失；(b) 被清空的页必须以空列表
/// 键传进来（`boxesByPage: {p: []}`）：只有 `boxesByPage`
/// 里出现的页才会被删旧框重插，缺页键的旧草稿会被原样保留——
/// 调用方不要用“缺键”表示“该页已清空”。
Future<void> saveDraftBoxesIntoImpl(
  QuizDatabase db, {
  required String taskId,
  required Map<int, List<QuestionBox>> boxesByPage,
  required Map<int, int> rotations,
}) async {
  final pages = <int>{...boxesByPage.keys};
  await db.transaction(() async {
    for (final page in pages) {
      await db.customUpdate(
        'DELETE FROM question_boxes '
        'WHERE collect_task_id = ? AND page = ? AND question_id IS NULL',
        variables: [Variable.withString(taskId), Variable.withInt(page)],
      );
      final flat = <QuestionBox>[...?boxesByPage[page]];
      for (final b in flat) {
        await _collectInsertBoxOrReplace(
          db,
          b.copyWith(
            collectTaskId: taskId,
            page: page,
            clearQuestionId: true,
            updatedAt: DateTime.now(),
          ),
        );
      }
    }
    // SR-P2-14：任务行不存在时 update 影响 0 行 → 抛错回滚，
    // 不让框写进去、旋转角丢了，调用方还以为保存成功。
    final updated = await db.customUpdate(
      'UPDATE collect_tasks SET page_rotations = ? WHERE id = ?',
      variables: [
        Variable.withString(
          jsonEncode({for (final e in rotations.entries) '${e.key}': e.value}),
        ),
        Variable.withString(taskId),
      ],
    );
    if (updated != 1) {
      throw StateError('收集任务不存在，草稿保存失败：$taskId');
    }
  });
}

/// §1.5.1：详情页重框（可单测版）：一次事务，只动这一题——
/// 删该题的旧框（先删子框再删本体）后插入新框（question_id 回填、
/// collect_task_id 置空）。同页其他题的框与切片一律不动。
Future<void> replaceQuestionBoxesIntoImpl(
  QuizDatabase db,
  String questionId,
  List<QuestionBox> boxes,
) async {
  await db.transaction(() async {
    await _replaceBoxesTxn(db, questionId, boxes);
  });
}

/// B3-P01：详情页重框 + 保存切片（可单测版）：一次事务——
/// 换框与写回题的 slice_path / slice_width / slice_height
/// 一起成功或一起回滚。旧写法是两步（先 replaceQuestionBoxes
/// 再 save），中途失败会留下“框换了、切片还是旧的”的不一致。
/// 切片文件由调用方先写临时文件（SR2-3：临时文件 + 事务成功后
/// rename 到正式路径；旧写法“事务前原地写盘”会让事务失败时删掉
/// 刚覆盖掉旧图的唯一一份切片）、事务失败只删临时文件；
/// 题行不存在（update 影响 0 行）时抛错，整个事务回滚。
Future<void> replaceQuestionBoxesAndSliceIntoImpl(
  QuizDatabase db, {
  required String questionId,
  required List<QuestionBox> boxes,
  required String slicePath,
  required int sliceWidth,
  required int sliceHeight,
}) async {
  await db.transaction(() async {
    await _replaceBoxesTxn(db, questionId, boxes);
    final updated = await db.customUpdate(
      'UPDATE questions SET slice_path = ?, slice_width = ?, '
      'slice_height = ? WHERE id = ?',
      variables: [
        Variable.withString(slicePath),
        Variable.withInt(sliceWidth),
        Variable.withInt(sliceHeight),
        Variable.withString(questionId),
      ],
    );
    if (updated != 1) {
      throw StateError('题目不存在，无法保存重框切片：$questionId');
    }
  });
}

/// 换框的事务内步骤（不单独开事务）：删旧框 → 插新框。
/// [AppDatabase.replaceQuestionBoxesInto] 与
/// [AppDatabase.replaceQuestionBoxesAndSliceInto] 共用。
/// [txn] 是事务内复用的数据库连接（Drift 里事务回调不带 txn 参数，
/// 直接传外层 [QuizDatabase]，其调用走事务专属执行器）。
Future<void> _replaceBoxesTxn(
  DatabaseConnectionUser txn,
  String questionId,
  List<QuestionBox> boxes,
) async {
  await _deleteBoxesForQuestionTxn(txn, questionId);
  for (final b in boxes) {
    final row = _questionBoxToRow(
      b.copyWith(
        questionId: questionId,
        clearCollectTaskId: true,
        updatedAt: DateTime.now(),
      ),
    );
    await txn.customInsert(
      'INSERT OR REPLACE INTO question_boxes (id, collect_task_id, '
      'question_id, parent_box_id, page, layer, type, x, y, w, h, '
      'confidence, origin, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, '
      '?, ?, ?, ?, ?, ?)',
      variables: [
        Variable(row['id']),
        Variable(row['collect_task_id']),
        Variable(row['question_id']),
        Variable(row['parent_box_id']),
        Variable(row['page']),
        Variable(row['layer']),
        Variable(row['type']),
        Variable(row['x']),
        Variable(row['y']),
        Variable(row['w']),
        Variable(row['h']),
        Variable(row['confidence']),
        Variable(row['origin']),
        Variable(row['updated_at']),
      ],
    );
  }
}

/// 删某题的全部框（事务内）：先删 parent_box_id 指向该题框的
/// 旧行，再删该题的框。
Future<void> _deleteBoxesForQuestionTxn(
  DatabaseConnectionUser txn,
  String questionId,
) async {
  final ownBoxes =
      (await txn
              .customSelect(
                'SELECT id FROM question_boxes WHERE question_id = ?',
                variables: [Variable.withString(questionId)],
              )
              .get())
          .map((r) => r.data)
          .toList();
  for (final row in ownBoxes) {
    await txn.customUpdate(
      'DELETE FROM question_boxes WHERE parent_box_id = ?',
      variables: [Variable.withString(row['id'] as String)],
    );
  }
  await txn.customUpdate(
    'DELETE FROM question_boxes WHERE question_id = ?',
    variables: [Variable.withString(questionId)],
  );
}

/// §1.5：确认拆题四步同事务（可单测版；切片写盘在事务**前**，
/// 由调用方先写好，失败不写库）：
/// 建题 + 回填 `question_boxes.question_id` + 建拆分任务 + 删原任务。
/// 框的回填：先删该题已有的旧框（防重复确认/重检测产生两个
/// layer = 1 框，partial unique 的防呆），再把传入的框逐行
/// upsert（question_id 回填、collect_task_id 置空）；同一事务内
/// 重复 id 的框只保留第一个（SR2-18 同题内 + SR3-9 跨题/跨页：
/// 一个去重集合覆盖全部题与保留分支）。
/// 拆分任务行同样写 source_path / created_at / page_count
/// （§1.2(b)，调用方在 splitTasks 里给好）。
///
/// SR-P1-2：有未框页时，保留任务的重建也在**同一事务**里——
/// [retainedTask]（与原任务同 id）+ 它的未框页草稿
/// （[retainedBoxesByPage]）随原任务的删除一起提交，
/// 不再由调用方在事务外两步重建。事务外重建有崩溃窗口：
/// confirmSplit 提交成功、重建还没发生时进程被杀，原任务行已删、
/// 草稿框已删，保留任务不存在——未框页连同页图引用一起丢。
/// 保留任务在原任务删除之后才插入（同 id），未框页草稿的
/// `collect_task_id` 指向保留任务、`question_id` 为空；
/// `retainedTask` 为空时行为与原来完全一致（无未框页）。
Future<void> confirmSplitIntoImpl(
  QuizDatabase db, {
  required CollectTask originalTask,
  required List<Question> questions,
  required List<CollectTask> splitTasks,
  required Map<String, List<QuestionBox>> boxesByQuestionId,
  CollectTask? retainedTask,
  Map<int, List<QuestionBox>> retainedBoxesByPage = const {},
}) async {
  await db.transaction(() async {
    // SR-P2-10：重复确认防呆——同 id 的题 / 拆分任务已存在时显式
    // 失败，不再用 REPLACE 静默覆盖。旧写法里一道已整理（已有解决
    // 记录）的题会被覆盖回未整理的全新题，而旧 cause_records /
    // review_history 还挂在这个 id 上——已治愈的记录贴到了一道
    // “新题”上。UI 层有 _splitPagesFor 防重复拆，正常流程走不到
    // 这里；数据层仍要防呆。保留任务与原任务同 id 是刻意设计
    // （先删原任务、后插保留任务），不在此列。
    for (final q in questions) {
      final exists =
          (await db
                  .customSelect(
                    'SELECT id FROM questions WHERE id = ? LIMIT 1',
                    variables: [Variable.withString(q.id)],
                  )
                  .get())
              .map((r) => r.data)
              .toList();
      if (exists.isNotEmpty) {
        throw StateError('拆题失败：题目已存在，请勿重复确认：${q.id}');
      }
    }
    for (final t in splitTasks) {
      final exists =
          (await db
                  .customSelect(
                    'SELECT id FROM collect_tasks WHERE id = ? LIMIT 1',
                    variables: [Variable.withString(t.id)],
                  )
                  .get())
              .map((r) => r.data)
              .toList();
      if (exists.isNotEmpty) {
        throw StateError('拆题失败：拆分任务已存在，请勿重复确认：${t.id}');
      }
    }
    // SR3-9：去重集合提到事务级——一个集合覆盖全部题 + 保留分支
    // （见下）。旧写法每题 / 每页各建一个集合，同一框 id 出现在
    // 两道题（或保留任务的两页）时，第二处插入会 REPLACE 掉第一行
    // （改写 question_id / page），第一题静默丢框；这里跨题/跨页
    // 重复也跳过，保留第一个。
    final seenBoxIds = <String>{};
    for (final q in questions) {
      await _collectInsertQuestion(db, q);
      await _deleteBoxesForQuestionTxn(db, q.id);
      // SR2-18：框回填也去重——与保留任务草稿的 seenBoxIds 同口径
      // （同一个事务级集合，见上）：同一题的入参里若有两个同 id 框，
      // 旧写法用 REPLACE 让后者静默覆盖前者，与 SR-P2-10“重复确认
      // 显式失败而不是静默覆盖”的防呆口径不一致；这里直接跳过重复
      // id（保留第一个），与保留任务分支一致。
      for (final b in boxesByQuestionId[q.id] ?? const <QuestionBox>[]) {
        if (!seenBoxIds.add(b.id)) continue;
        await _collectInsertBoxOrReplace(
          db,
          b.copyWith(
            questionId: q.id,
            clearCollectTaskId: true,
            updatedAt: DateTime.now(),
          ),
        );
      }
    }
    for (final t in splitTasks) {
      final values = _collectTaskToRow(t);
      await db.customInsert(
        'INSERT INTO collect_tasks (id, name, file_name, subject_id, '
        'status, progress, page_count, page, error, question_id, '
        'source_path, page_rotations, created_at) VALUES (?, ?, ?, ?, ?, '
        '?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable(values['id']),
          Variable(values['name']),
          Variable(values['file_name']),
          Variable(values['subject_id']),
          Variable(values['status']),
          Variable(values['progress']),
          Variable(values['page_count']),
          Variable(values['page']),
          Variable(values['error']),
          Variable(values['question_id']),
          Variable(values['source_path']),
          Variable(values['page_rotations']),
          Variable.withInt(
            t.createdAt?.millisecondsSinceEpoch ??
                DateTime.now().millisecondsSinceEpoch,
          ),
        ],
      );
    }
    // 删原任务：残留的草稿框（本次没确认的页/删掉的框）随任务删，
    // 已回填 question_id 的框不受影响（见 deleteCollectTaskFrom）。
    await db.customUpdate(
      'DELETE FROM question_boxes '
      'WHERE collect_task_id = ? AND question_id IS NULL',
      variables: [Variable.withString(originalTask.id)],
    );
    await db.customUpdate(
      'DELETE FROM collect_tasks WHERE id = ?',
      variables: [Variable.withString(originalTask.id)],
    );
    // SR-P1-2：同一事务内重建保留任务 + 写回未框页草稿。
    // 保留任务与原任务同 id（先删后插）。
    if (retainedTask != null) {
      final retainedValues = _collectTaskToRow(retainedTask);
      await db.customInsert(
        'INSERT OR REPLACE INTO collect_tasks (id, name, file_name, '
        'subject_id, status, progress, page_count, page, error, '
        'question_id, source_path, page_rotations, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable(retainedValues['id']),
          Variable(retainedValues['name']),
          Variable(retainedValues['file_name']),
          Variable(retainedValues['subject_id']),
          Variable(retainedValues['status']),
          Variable(retainedValues['progress']),
          Variable(retainedValues['page_count']),
          Variable(retainedValues['page']),
          Variable(retainedValues['error']),
          Variable(retainedValues['question_id']),
          Variable(retainedValues['source_path']),
          Variable(retainedValues['page_rotations']),
          Variable.withInt(
            retainedTask.createdAt?.millisecondsSinceEpoch ??
                DateTime.now().millisecondsSinceEpoch,
          ),
        ],
      );
      final retainedPages = <int>{...retainedBoxesByPage.keys};
      for (final page in retainedPages) {
        final flat = <QuestionBox>[...?retainedBoxesByPage[page]];
        // SR3-9：与题回填共用同一个事务级 seenBoxIds（见上）：跨页
        // 重复 id 也跳过（保留第一个），且不与已回填的题框撞 id。
        for (final b in flat) {
          if (!seenBoxIds.add(b.id)) continue;
          await _collectInsertBoxOrReplace(
            db,
            b.copyWith(
              collectTaskId: retainedTask.id,
              page: page,
              clearQuestionId: true,
              updatedAt: DateTime.now(),
            ),
          );
        }
      }
    }
  });
}

/// 确认拆题里建题那一步：普通 INSERT（冲突即抛，与旧
/// `ConflictAlgorithm.fail` 同口径——不存在时才插，重复确认在
/// 前面已显式拦截）。列顺序与 [_toRow] 的键顺序一致。
Future<void> _collectInsertQuestion(
  DatabaseConnectionUser db,
  Question q,
) async {
  final row = _toRow(q);
  await db.customInsert(
    'INSERT INTO questions (id, title, subject_id, folder_ids, exam_id, '
    'knowledge_ids, error_types, custom_error_types, tags, answer, '
    'explanation, notes, review_count, is_organized, is_demo, '
    'is_favorite, is_archived, review_joined, created_at, slice_kind, '
    'slice_text, source_path, source_kind, source_page, page_image_path, '
    'slice_path, slice_width, slice_height) VALUES (?, ?, ?, ?, ?, ?, ?, '
    '?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    variables: [
      Variable(row['id']),
      Variable(row['title']),
      Variable(row['subject_id']),
      Variable(row['folder_ids']),
      Variable(row['exam_id']),
      Variable(row['knowledge_ids']),
      Variable(row['error_types']),
      Variable(row['custom_error_types']),
      Variable(row['tags']),
      Variable(row['answer']),
      Variable(row['explanation']),
      Variable(row['notes']),
      Variable(row['review_count']),
      Variable(row['is_organized']),
      Variable(row['is_demo']),
      Variable(row['is_favorite']),
      Variable(row['is_archived']),
      Variable(row['review_joined']),
      Variable(row['created_at']),
      Variable(row['slice_kind']),
      Variable(row['slice_text']),
      Variable(row['source_path']),
      Variable(row['source_kind']),
      Variable(row['source_page']),
      Variable(row['page_image_path']),
      Variable(row['slice_path']),
      Variable(row['slice_width']),
      Variable(row['slice_height']),
    ],
  );
}

/// 插一个框（INSERT OR REPLACE，与旧 `ConflictAlgorithm.replace`
/// 同口径）。本文件三处插框共用（草稿保存、换框、确认拆题回填）。
Future<void> _collectInsertBoxOrReplace(
  DatabaseConnectionUser db,
  QuestionBox b,
) async {
  final row = _questionBoxToRow(b);
  await db.customInsert(
    'INSERT OR REPLACE INTO question_boxes (id, collect_task_id, '
    'question_id, parent_box_id, page, layer, type, x, y, w, h, '
    'confidence, origin, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, '
    '?, ?, ?, ?, ?, ?)',
    variables: [
      Variable(row['id']),
      Variable(row['collect_task_id']),
      Variable(row['question_id']),
      Variable(row['parent_box_id']),
      Variable(row['page']),
      Variable(row['layer']),
      Variable(row['type']),
      Variable(row['x']),
      Variable(row['y']),
      Variable(row['w']),
      Variable(row['h']),
      Variable(row['confidence']),
      Variable(row['origin']),
      Variable(row['updated_at']),
    ],
  );
}

extension AppDatabaseCollect on AppDatabase {
  Future<List<CollectTask>> allCollectTasks() async =>
      AppDatabase.allCollectTasksFrom(await db);

  /// §4.3：角标刷新节流（只在状态变化时发事件）：进度百分比高频更新
  /// （真实导入按字节回调）不触发角标重读；
  /// 新任务、状态变化（导入中 → 待框选等）时才发含 `badges` 的事件。
  Future<void> upsertCollectTask(CollectTask t) async {
    final d = await db;
    final old =
        (await d
                .customSelect(
                  'SELECT status FROM collect_tasks WHERE id = ? LIMIT 1',
                  variables: [Variable.withString(t.id)],
                )
                .get())
            .map((r) => r.data)
            .toList();
    await AppDatabase.upsertCollectTaskInto(d, t);
    if (old.isEmpty || old.first['status'] != t.status.name) {
      // 新任务或状态变化才发事件：进度百分比高频更新不触发角标重读。
      DataChangeBus.instance.emit(
        const DataChangeEvent(kinds: {DataChangeKind.badges}),
      );
    }
  }

  /// §1.2(c)：删任务时同事务删该任务未确认的草稿框
  /// （collect_task_id = ? AND question_id IS NULL）；已确认的框
  /// （question_id 已回填）随题保留，不删。页图目录的处理见 §4.5
  /// （P2 落盘后：页图可能还被已建的题引用，不能随任务删）。
  /// B2 Win11 bug 批 6a：该任务拆出来的题（collect_tasks.question_id
  /// 一对一指向）也随任务删——但只删还没整理的（is_organized = 0）；
  /// 已整理进错题本的题保留（只断开任务指向，题本身、框、切片不动）。
  /// questions 表没有 collect_task_id 列，任务→题的唯一纽带就是
  /// collect_tasks.question_id；是否“待整理”看 is_organized。
  Future<void> deleteCollectTask(String id) async {
    final d = await db;
    await AppDatabase.deleteCollectTaskFrom(d, id);
    // 删任务时该任务拆出来的未整理题随任务删（其解决记录同事务清掉，
    // 见 deleteCollectTaskFromImpl）——按条件影响的全集发。
    DataChangeBus.instance.emit(
      const DataChangeEvent(
        kinds: {
          DataChangeKind.badges,
          DataChangeKind.questions,
          DataChangeKind.reviewRecords,
        },
      ),
    );
  }

  /// §1.5：草稿保存（实例版）：直接调可单测版，不 bump
  /// （草稿保存不改变任务状态，角标不用刷新）。
  Future<void> saveDraftBoxes({
    required String taskId,
    required Map<int, List<QuestionBox>> boxesByPage,
    required Map<int, int> rotations,
  }) async {
    final d = await db;
    await AppDatabase.saveDraftBoxesInto(
      d,
      taskId: taskId,
      boxesByPage: boxesByPage,
      rotations: rotations,
    );
  }

  /// §1.5：读某任务的全部草稿框（实例版）。
  Future<List<QuestionBox>> boxesForTask(String taskId) async =>
      AppDatabase.boxesForTaskFrom(await db, taskId);

  /// §1.5.1：读同一页图上全部已确认题的框（实例版）。
  Future<List<QuestionBox>> boxesForPageImage(String pageImagePath) async =>
      AppDatabase.boxesForPageImageFrom(await db, pageImagePath);

  /// §1.5.1：详情页重框（实例版）。
  Future<void> replaceQuestionBoxes(
    String questionId,
    List<QuestionBox> boxes,
  ) async {
    final d = await db;
    await AppDatabase.replaceQuestionBoxesInto(d, questionId, boxes);
    // 只换框，不进角标查询——旧 bump 是防御性的，本阶段按实际影响只发 questions。
    DataChangeBus.instance.emit(
      DataChangeEvent(
        kinds: const {DataChangeKind.questions},
        questionId: questionId,
      ),
    );
  }

  /// B3-P01：详情页重框 + 保存切片（实例版）。
  Future<void> replaceQuestionBoxesAndSlice(
    String questionId,
    List<QuestionBox> boxes, {
    required String slicePath,
    required int sliceWidth,
    required int sliceHeight,
  }) async {
    final d = await db;
    await AppDatabase.replaceQuestionBoxesAndSliceInto(
      d,
      questionId: questionId,
      boxes: boxes,
      slicePath: slicePath,
      sliceWidth: sliceWidth,
      sliceHeight: sliceHeight,
    );
    // 只换框与切片尺寸，不进角标查询——旧 bump 是防御性的，
    // 本阶段按实际影响只发 questions。
    DataChangeBus.instance.emit(
      DataChangeEvent(
        kinds: const {DataChangeKind.questions},
        questionId: questionId,
      ),
    );
  }

  /// §1.5：确认拆题（实例版）：事务提交后 bump 一次。
  /// SR-P1-2：有未框页时把保留任务 + 未框页草稿一起传进去，
  /// 与拆题同事务提交，不再由调用方在事务外重建。
  Future<void> confirmSplit({
    required CollectTask originalTask,
    required List<Question> questions,
    required List<CollectTask> splitTasks,
    required Map<String, List<QuestionBox>> boxesByQuestionId,
    CollectTask? retainedTask,
    Map<int, List<QuestionBox>> retainedBoxesByPage = const {},
  }) async {
    final d = await db;
    await AppDatabase.confirmSplitInto(
      d,
      originalTask: originalTask,
      questions: questions,
      splitTasks: splitTasks,
      boxesByQuestionId: boxesByQuestionId,
      retainedTask: retainedTask,
      retainedBoxesByPage: retainedBoxesByPage,
    );
    // 确认拆题新建题目与拆分任务、原任务状态变化——待整理角标与收集角标都变。
    DataChangeBus.instance.emit(
      const DataChangeEvent(
        kinds: {DataChangeKind.badges, DataChangeKind.questions},
      ),
    );
  }
}
