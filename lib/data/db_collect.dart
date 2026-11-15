// B4：database.dart 拆分——收集任务 / question_boxes（草稿、重框、确认拆题）/ 文件级联删除。
// 与 database.dart 同一库（part of），共享库私有成员；纯重构，行为不变。

part of 'database.dart';

/// §4.3：按 created_at 稳定排序（同毫秒建的批量任务用 rowid 兜底）。
Future<List<CollectTask>> allCollectTasksFromImpl(Database db) async {
  final rows = await db.query(
    'collect_tasks',
    orderBy: 'created_at DESC, rowid DESC',
  );
  return rows.map(_collectTaskFromRow).toList();
}

/// §4.3：UPDATE-first（照 upsertSubject 的正面先例）：REPLACE 是
/// 先删后插，会改 rowid、把行顶到最上面，进度高频更新时任务列表
/// 自己跳序。已存在的行只 UPDATE（不碰 created_at，rowid 不变，
/// 顺序就不动）；不存在时才 INSERT，并写 created_at（调用方没给
/// 就写当前时间）。
Future<void> upsertCollectTaskIntoImpl(Database db, CollectTask t) async {
  final values = _collectTaskToRow(t);
  final updated = await db.update(
    'collect_tasks',
    values,
    where: 'id = ?',
    whereArgs: [t.id],
  );
  if (updated == 0) {
    await db.insert('collect_tasks', {
      ...values,
      'created_at':
          t.createdAt?.millisecondsSinceEpoch ??
          DateTime.now().millisecondsSinceEpoch,
    });
  }
}

/// §1.2(c) + B2-6a：删任务（可单测版）：一次事务，不 bump。
/// 事务内：待整理的拆出题（经 _deleteQuestionTxn，含其框、解决记录、
/// 自查历史、复习队列项）→ 未确认的草稿框 → 任务行。事务提交后，
/// 若没有任何题的 source_path / page_image_path 还指向该任务
/// 目录（`imports/<taskId>/`），删整个任务目录；已确认拆题的
/// 任务页图还被题引用，目录保留（§4.5）。被删的待整理题若有独占
/// 切片，事务提交后删无引用的切片文件（与 deleteQuestionFrom 同款）。
Future<void> deleteCollectTaskFromImpl(Database db, String id) async {
  String? sliceToClean;
  await db.transaction((txn) async {
    // 先读任务指向的题：is_organized 在事务内读，避免读到删之间
    // 被整理工作台改掉状态。
    final taskRows = await txn.query(
      'collect_tasks',
      columns: ['question_id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    final questionId = taskRows.isEmpty
        ? null
        : taskRows.first['question_id'] as String?;
    if (questionId != null) {
      final qRows = await txn.query(
        'questions',
        columns: ['is_organized', 'slice_path'],
        where: 'id = ?',
        whereArgs: [questionId],
        limit: 1,
      );
      if (qRows.isNotEmpty && (qRows.first['is_organized'] as int?) != 1) {
        sliceToClean = qRows.first['slice_path'] as String?;
        await _deleteQuestionTxn(txn, questionId);
      }
    }
    await txn.delete(
      'question_boxes',
      where: 'collect_task_id = ? AND question_id IS NULL',
      whereArgs: [id],
    );
    await txn.delete('collect_tasks', where: 'id = ?', whereArgs: [id]);
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
Future<void> _deleteDataFileIfUnreferenced(Database db, String? rel) async {
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

Future<bool> _isFileReferenced(Database db, String rel) async {
  for (final col in ['source_path', 'page_image_path', 'slice_path']) {
    final rows = await db.query(
      'questions',
      columns: ['id'],
      where: '$col = ?',
      whereArgs: [rel],
      limit: 1,
    );
    if (rows.isNotEmpty) return true;
  }
  final tasks = await db.query(
    'collect_tasks',
    columns: ['id'],
    where: 'source_path = ?',
    whereArgs: [rel],
    limit: 1,
  );
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
Future<void> _deleteTaskDirIfUnreferenced(Database db, String taskId) async {
  if (!_safeTaskIdPattern.hasMatch(taskId)) return;
  final prefix = 'imports/$taskId/';
  final escaped = _likeEscape(prefix);
  for (final col in ['source_path', 'page_image_path']) {
    final rows = await db.query(
      'questions',
      columns: ['id'],
      where: '$col LIKE ? ESCAPE ?',
      whereArgs: ['$escaped%', '\\'],
      limit: 1,
    );
    if (rows.isNotEmpty) return;
  }
  // SR-P2-15：拆分任务行的 source_path 也可能指向该目录。
  final taskRefs = await db.query(
    'collect_tasks',
    columns: ['id'],
    where: 'source_path LIKE ? ESCAPE ?',
    whereArgs: ['$escaped%', '\\'],
    limit: 1,
  );
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
Future<void> insertQuestionBoxIntoImpl(Database db, QuestionBox b) async {
  await db.insert('question_boxes', _questionBoxToRow(b));
}

/// §8.1：读某题的全部框（可单测版）。
Future<List<QuestionBox>> boxesForQuestionFromImpl(
  Database db,
  String questionId,
) async {
  final rows = await db.query(
    'question_boxes',
    where: 'question_id = ?',
    whereArgs: [questionId],
  );
  return rows.map(_questionBoxFromRow).toList();
}

/// §1.5：读某任务的全部草稿框（各页，用于“继续修框”恢复）。
Future<List<QuestionBox>> boxesForTaskFromImpl(
  Database db,
  String taskId,
) async {
  final rows = await db.query(
    'question_boxes',
    where: 'collect_task_id = ? AND question_id IS NULL',
    whereArgs: [taskId],
    orderBy: 'page ASC, id ASC',
  );
  return rows.map(_questionBoxFromRow).toList();
}

/// §1.5：读某任务某页的草稿框。
Future<List<QuestionBox>> boxesForTaskPageFromImpl(
  Database db,
  String taskId,
  int page,
) async {
  final rows = await db.query(
    'question_boxes',
    where: 'collect_task_id = ? AND page = ? AND question_id IS NULL',
    whereArgs: [taskId, page],
  );
  return rows.map(_questionBoxFromRow).toList();
}

/// §1.5.1：读同一页图上全部已确认题的框（重框同页上下文）：
/// 分组键是 `questions.page_image_path`（确认后 collect_task_id
/// 已是 NULL，不能靠任务分组）。返回该页各题的全部框（1 层 + 2 层）。
Future<List<QuestionBox>> boxesForPageImageFromImpl(
  Database db,
  String pageImagePath,
) async {
  final qs = await db.query(
    'questions',
    columns: ['id'],
    where: 'page_image_path = ?',
    whereArgs: [pageImagePath],
    // SR2-27：题 id 列表也要确定顺序（questions 表没有 page 列，
    // 这里按 id 排；框行的顺序由下面的 ORDER BY 定）。
    orderBy: 'id ASC',
  );
  if (qs.isEmpty) return const [];
  final ids = qs.map((r) => r['id'] as String).toList();
  final where = 'question_id IN (${List.filled(ids.length, '?').join(',')})';
  // SR2-27：与 boxesForTask 对齐，按页、id 排序——realRegionRects
  // 的“同面积取第一个”依赖输入顺序，无 ORDER BY 时 SQLite 不保证
  // 行序（通常是 rowid 序，但不保证）。
  final rows = await db.query(
    'question_boxes',
    where: where,
    whereArgs: ids,
    orderBy: 'page ASC, id ASC',
  );
  return rows.map(_questionBoxFromRow).toList();
}

/// §1.5：草稿保存（可单测版）：一次事务。
/// - 按页替换：删该任务该页的草稿框，再插入当前页内存里的框
///   （1 层 + 2 层，2 层框的 parent_box_id 指向所属 1 层框）；
/// - `rotations` 是草稿的全部按页旋转角度，一起写进
///   `collect_tasks.page_rotations`（§1.6.1）。
/// 只动该任务该页的草稿框，已确认的题框一律不动。
/// SR-P2-14：两条调用方契约——(a) 旋转角写回时任务行必须存在：
/// `update` 影响 0 行（任务已被删）时抛错回滚，不再让框照常写进
/// 去（成孤儿草稿）而旋转角静默丢失；(b) 被清空的页必须以空列表
/// 键传进来（`boxesByPage: {p: []}`）：只有 `boxesByPage` /
/// `standaloneInner` 里出现的页才会被删旧框重插，缺页键的旧草稿
/// 会被原样保留——调用方不要用“缺键”表示“该页已清空”。
Future<void> saveDraftBoxesIntoImpl(
  Database db, {
  required String taskId,
  required Map<int, List<QuestionBox>> boxesByPage,
  required Map<String, List<QuestionBox>> inners,
  required Map<int, List<QuestionBox>> standaloneInner,
  required Map<int, int> rotations,
}) async {
  final pages = <int>{...boxesByPage.keys, ...standaloneInner.keys};
  await db.transaction((txn) async {
    for (final page in pages) {
      await txn.delete(
        'question_boxes',
        where: 'collect_task_id = ? AND page = ? AND question_id IS NULL',
        whereArgs: [taskId, page],
      );
      final flat = <QuestionBox>[
        ...?boxesByPage[page],
        for (final b in (boxesByPage[page] ?? const <QuestionBox>[]))
          ...?inners['$page:${b.id}'],
        ...?standaloneInner[page],
      ];
      for (final b in flat) {
        final row = _questionBoxToRow(
          b.copyWith(
            collectTaskId: taskId,
            page: page,
            clearQuestionId: true,
            updatedAt: DateTime.now(),
          ),
        );
        await txn.insert(
          'question_boxes',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    }
    // SR-P2-14：任务行不存在时 update 影响 0 行 → 抛错回滚，
    // 不让框写进去、旋转角丢了，调用方还以为保存成功。
    final updated = await txn.update(
      'collect_tasks',
      {
        'page_rotations': jsonEncode({
          for (final e in rotations.entries) '${e.key}': e.value,
        }),
      },
      where: 'id = ?',
      whereArgs: [taskId],
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
  Database db,
  String questionId,
  List<QuestionBox> boxes,
) async {
  await db.transaction((txn) async {
    await _replaceBoxesTxn(txn, questionId, boxes);
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
  Database db, {
  required String questionId,
  required List<QuestionBox> boxes,
  required String slicePath,
  required int sliceWidth,
  required int sliceHeight,
}) async {
  await db.transaction((txn) async {
    await _replaceBoxesTxn(txn, questionId, boxes);
    final updated = await txn.update(
      'questions',
      {
        'slice_path': slicePath,
        'slice_width': sliceWidth,
        'slice_height': sliceHeight,
      },
      where: 'id = ?',
      whereArgs: [questionId],
    );
    if (updated != 1) {
      throw StateError('题目不存在，无法保存重框切片：$questionId');
    }
  });
}

/// 换框的事务内步骤（不单独开事务）：删旧框 → 插新框。
/// [AppDatabase.replaceQuestionBoxesInto] 与
/// [AppDatabase.replaceQuestionBoxesAndSliceInto] 共用。
Future<void> _replaceBoxesTxn(
  Transaction txn,
  String questionId,
  List<QuestionBox> boxes,
) async {
  await _deleteBoxesForQuestionTxn(txn, questionId);
  for (final b in boxes) {
    await txn.insert(
      'question_boxes',
      _questionBoxToRow(
        b.copyWith(
          questionId: questionId,
          clearCollectTaskId: true,
          updatedAt: DateTime.now(),
        ),
      ),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}

/// 删某题的全部框（事务内）：先删子框（parent_box_id 指向该题
/// 1 层框的行），再删该题的框。
Future<void> _deleteBoxesForQuestionTxn(
  Transaction txn,
  String questionId,
) async {
  final ownBoxes = await txn.query(
    'question_boxes',
    columns: ['id'],
    where: 'question_id = ?',
    whereArgs: [questionId],
  );
  for (final row in ownBoxes) {
    await txn.delete(
      'question_boxes',
      where: 'parent_box_id = ?',
      whereArgs: [row['id'] as String],
    );
  }
  await txn.delete(
    'question_boxes',
    where: 'question_id = ?',
    whereArgs: [questionId],
  );
}

/// §1.5：确认拆题四步同事务（可单测版；切片写盘在事务**前**，
/// 由调用方先写好，失败不写库）：
/// 建题 + 回填 `question_boxes.question_id` + 建拆分任务 + 删原任务。
/// 框的回填：先删该题已有的旧框（防重复确认/重检测产生两个
/// layer = 1 框，partial unique 的防呆），再把传入的框逐行
/// upsert（question_id 回填、collect_task_id 置空）；同一题内
/// 重复 id 的框只保留第一个（SR2-18，与保留任务草稿同口径）。
/// 拆分任务行同样写 source_path / created_at / page_count
/// （§1.2(b)，调用方在 splitTasks 里给好）。
///
/// SR-P1-2：有未框页时，保留任务的重建也在**同一事务**里——
/// [retainedTask]（与原任务同 id）+ 它的未框页草稿
/// （[retainedBoxesByPage] / [retainedInners] / [retainedStandaloneInner]，
/// 与 [BoxEditorResult] 的三处口径一致）随原任务的删除一起提交，
/// 不再由调用方在事务外两步重建。事务外重建有崩溃窗口：
/// confirmSplit 提交成功、重建还没发生时进程被杀，原任务行已删、
/// 草稿框已删，保留任务不存在——未框页连同页图引用一起丢。
/// 保留任务在原任务删除之后才插入（同 id），未框页草稿的
/// `collect_task_id` 指向保留任务、`question_id` 为空；
/// `retainedTask` 为空时行为与原来完全一致（无未框页）。
Future<void> confirmSplitIntoImpl(
  Database db, {
  required CollectTask originalTask,
  required List<Question> questions,
  required List<CollectTask> splitTasks,
  required Map<String, List<QuestionBox>> boxesByQuestionId,
  CollectTask? retainedTask,
  Map<int, List<QuestionBox>> retainedBoxesByPage = const {},
  Map<String, List<QuestionBox>> retainedInners = const {},
  Map<int, List<QuestionBox>> retainedStandaloneInner = const {},
}) async {
  await db.transaction((txn) async {
    // SR-P2-10：重复确认防呆——同 id 的题 / 拆分任务已存在时显式
    // 失败，不再用 REPLACE 静默覆盖。旧写法里一道已整理（已有解决
    // 记录）的题会被覆盖回未整理的全新题，而旧 cause_records /
    // review_history 还挂在这个 id 上——已治愈的记录贴到了一道
    // “新题”上。UI 层有 _splitPagesFor 防重复拆，正常流程走不到
    // 这里；数据层仍要防呆。保留任务与原任务同 id 是刻意设计
    // （先删原任务、后插保留任务），不在此列。
    for (final q in questions) {
      final exists = await txn.query(
        'questions',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [q.id],
        limit: 1,
      );
      if (exists.isNotEmpty) {
        throw StateError('拆题失败：题目已存在，请勿重复确认：${q.id}');
      }
    }
    for (final t in splitTasks) {
      final exists = await txn.query(
        'collect_tasks',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [t.id],
        limit: 1,
      );
      if (exists.isNotEmpty) {
        throw StateError('拆题失败：拆分任务已存在，请勿重复确认：${t.id}');
      }
    }
    for (final q in questions) {
      await txn.insert(
        'questions',
        _toRow(q),
        conflictAlgorithm: ConflictAlgorithm.fail,
      );
      await _deleteBoxesForQuestionTxn(txn, q.id);
      // SR2-18：框回填也去重——与保留任务草稿的 seenIds 同口径
      // （见下）：同一题的入参里若有两个同 id 框，旧写法用 REPLACE
      // 让后者静默覆盖前者，与 SR-P2-10“重复确认显式失败而不是
      // 静默覆盖”的防呆口径不一致；这里直接跳过重复 id（保留第一
      // 个），与保留任务分支一致。
      final seenBoxIds = <String>{};
      for (final b in boxesByQuestionId[q.id] ?? const <QuestionBox>[]) {
        if (!seenBoxIds.add(b.id)) continue;
        await txn.insert(
          'question_boxes',
          _questionBoxToRow(
            b.copyWith(
              questionId: q.id,
              clearCollectTaskId: true,
              updatedAt: DateTime.now(),
            ),
          ),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    }
    for (final t in splitTasks) {
      final values = _collectTaskToRow(t);
      await txn.insert('collect_tasks', {
        ...values,
        'created_at':
            t.createdAt?.millisecondsSinceEpoch ??
            DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.fail);
    }
    // 删原任务：残留的草稿框（本次没确认的页/删掉的框）随任务删，
    // 已回填 question_id 的框不受影响（见 deleteCollectTaskFrom）。
    await txn.delete(
      'question_boxes',
      where: 'collect_task_id = ? AND question_id IS NULL',
      whereArgs: [originalTask.id],
    );
    await txn.delete(
      'collect_tasks',
      where: 'id = ?',
      whereArgs: [originalTask.id],
    );
    // SR-P1-2：同一事务内重建保留任务 + 写回未框页草稿。
    // 保留任务与原任务同 id（先删后插）；草稿按页展平——
    // 未框页本就没有 1 层框，inners 不能只按 boxesByPage 里的
    // 1 层父框取（见 saveDraftBoxesIntoImpl 的取法），这里按
    // inners 键里的页码全量取，未框页的 2 层草稿也不丢。
    if (retainedTask != null) {
      final retainedValues = _collectTaskToRow(retainedTask);
      await txn.insert('collect_tasks', {
        ...retainedValues,
        'created_at':
            retainedTask.createdAt?.millisecondsSinceEpoch ??
            DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      final retainedPages = <int>{
        ...retainedBoxesByPage.keys,
        ...retainedStandaloneInner.keys,
        for (final k in retainedInners.keys) _innerKeyPage(k),
      };
      for (final page in retainedPages) {
        final flat = <QuestionBox>[
          ...?retainedBoxesByPage[page],
          for (final e in retainedInners.entries)
            if (_innerKeyPage(e.key) == page) ...e.value,
          ...?retainedStandaloneInner[page],
        ];
        final seenIds = <String>{};
        for (final b in flat) {
          if (!seenIds.add(b.id)) continue;
          await txn.insert(
            'question_boxes',
            _questionBoxToRow(
              b.copyWith(
                collectTaskId: retainedTask.id,
                page: page,
                clearQuestionId: true,
                updatedAt: DateTime.now(),
              ),
            ),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
    }
  });
}

/// 题内框键 `'<页>:<题级框id>'` 里的页码；解析不出按 -1 算
/// （不匹配任何页，见 collect_page.dart 的同款 `_innerPage`）。
int _innerKeyPage(String key) => int.tryParse(key.split(':').first) ?? -1;

extension AppDatabaseCollect on AppDatabase {
  Future<List<CollectTask>> allCollectTasks() async =>
      AppDatabase.allCollectTasksFrom(await db);

  /// §4.3：角标刷新节流（只在状态变化时 bump）：进度百分比高频更新
  /// （真实导入按字节回调）不触发 `_refreshBadges` 的 5 个查询；
  /// 新任务、状态变化（导入中 → 待框选等）时才 bump。
  Future<void> upsertCollectTask(CollectTask t) async {
    final d = await db;
    final old = await d.query(
      'collect_tasks',
      columns: ['status'],
      where: 'id = ?',
      whereArgs: [t.id],
      limit: 1,
    );
    await AppDatabase.upsertCollectTaskInto(d, t);
    if (old.isEmpty || old.first['status'] != t.status.name) {
      bumpBadgeVersion();
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
    bumpBadgeVersion();
  }

  /// §1.5：草稿保存（实例版）：直接调可单测版，不 bump
  /// （草稿保存不改变任务状态，角标不用刷新）。
  Future<void> saveDraftBoxes({
    required String taskId,
    required Map<int, List<QuestionBox>> boxesByPage,
    required Map<String, List<QuestionBox>> inners,
    required Map<int, List<QuestionBox>> standaloneInner,
    required Map<int, int> rotations,
  }) async {
    final d = await db;
    await AppDatabase.saveDraftBoxesInto(
      d,
      taskId: taskId,
      boxesByPage: boxesByPage,
      inners: inners,
      standaloneInner: standaloneInner,
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
    bumpBadgeVersion();
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
    bumpBadgeVersion();
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
    Map<String, List<QuestionBox>> retainedInners = const {},
    Map<int, List<QuestionBox>> retainedStandaloneInner = const {},
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
      retainedInners: retainedInners,
      retainedStandaloneInner: retainedStandaloneInner,
    );
    bumpBadgeVersion();
  }
}
