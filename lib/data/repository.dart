import '../data/database.dart';
import '../data/data_change_events.dart';
import '../data/p3_review_entries.dart';
import '../data/p4_new_release.dart';
import '../data/review_engine.dart';
import '../data/review_scheduler.dart';
import '../models/exam_event.dart';
import '../models/models.dart';
import '../services/import_service.dart';
import '../services/ocr_key_store.dart';

/// 2026-11-26 口径迁移第二批清理：旧口径互斥拆分
/// `ReviewBucket` / `reviewBucketOf` / `isReviewDue` 已删除——lib 内
/// 调用方已全部迁走（复习列表分组迁 FSRS 四组、元信息行已取消、
/// `dueToday`/`homeRevCounts`/`subjectCounts` 已删）；仅剩的
/// b5 纯函数断言组随之删除。FSRS 全量迁移包 7：`CauseStatus` /
/// `CauseRecord.isRecheckDue` 已删除（旧治愈状态机退役，
/// `CauseRecord` 只剩冻结历史载体）。

/// 仓库：各页面模块共用的查询口径（首页计数、错题本筛选、整理队列、复习）。
/// 不直接读其他模块的状态，只读数据层。
/// v2：旧翻卡 + 1/3/7/14 天间隔已废弃；复习是治错因模型。
class QuestionRepository {
  QuestionRepository(this._db, {OcrKeyStore? keyStore})
    : _keyStore = keyStore ?? OcrKeyStore();
  final AppDatabase _db;

  /// BigModel key 的安全存储（十三批 M3 契约：键名 bigmodel_api_key 冻结；
  /// 本仓库只问“有没有 key”，不读出 key 值、不记日志）。
  final OcrKeyStore _keyStore;

  AppDatabase get db => _db;

  Future<List<Question>> all({bool includeArchived = false}) async {
    final list = await _db.allQuestions();
    return list.where((q) => includeArchived || !q.isArchived).toList();
  }

  Future<Question?> questionById(String id) => _db.questionById(id);

  /// 十三批 M5：读一道题的 OCR 任务行（最新在前，供识别题干状态推导用）。
  /// 读库失败时返回空列表——OCR 状态是锦上添花，绝不能拖垮页面。
  /// 注意：这里不能加 `.timeout()`——widget 测试的 fake async 里
  /// 未完成的 Timer 会在测试结束时按“仍有待处理 Timer”判失败
  /// （实测：detail_page_test 41 项全灭于此）；调用方（Notifier）
  /// 用不 await 的方式调它（见 _refreshOcrStatus），读不到就保持旧值。
  Future<List<OcrJob>> ocrJobsForQuestion(String questionId) async {
    try {
      return await _db.ocrJobsForQuestion(questionId);
    } catch (_) {
      return const [];
    }
  }

  /// 十三批 M5：设置里是否已存 BigModel key（只问有无，不读出 key 值）。
  /// 安全存储不可用（测试环境无平台实现等）时返回 false——
  /// 没 key 时状态只显示“等待设置 API Key”，不影响题目本身。
  Future<bool> hasOcrApiKey() async {
    try {
      return await _keyStore.hasApiKey();
    } catch (_) {
      return false;
    }
  }

  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
    String questionId,
  ) => _db.reviewHistory(questionId);

  // ---------- 错因复习模型 ----------

  Future<List<CauseRecord>> causeRecords() => _db.allCauseRecords();

  Future<List<CauseRecord>> causeRecordsFor(String questionId) =>
      _db.causeRecordsForQuestion(questionId);

  /// SR3-4：只写补救历史（见 [_db.updateCauseRemedy]）。行已存在
  /// 时只 UPDATE `remedy_history` 列，状态列已冻结、无改状态入口
  /// （旧 recordSelfCheck 已随 FSRS 全量迁移包1退役）；
  /// 行不存在时 INSERT 只允许冻结默认值（`status='pending'`、
  /// `solvedCount=0`、复查日与锚点为空），不信任传入记录的状态
  /// （FSRS 全量迁移包 7，R1；`CauseRecord` 已无状态字段）。
  Future<void> saveCauseRecord(CauseRecord r) => _db.updateCauseRemedy(r);

  /// 只翻某题的 `review_joined` 标志位（FSRS 全量迁移包2）：
  /// 不再播种 cause_records；空错因的题也可翻标志（FSRS 按题，
  /// 不按错因）。入池建卡走 [joinFsrsPool]，不要只翻标志就当入池。
  Future<bool> setReviewJoinedFlag(Question q, bool joined) =>
      _db.setReviewJoinedFlag(q, joined);

  /// 批量加入复习（B11-6，FSRS 全量迁移包2 新规则）：
  /// 题不在 FSRS 池 → 入池（建卡 + 翻 `review_joined` 标志）；
  /// 题已在池 → 跳过（不重复建卡、不重置现有 FSRS 状态）；
  /// 无错因的题也可加（FSRS 按题，不按错因）。
  /// 实现即 [joinFsrsPool]（一题一卡幂等）；返回 (joined, skipped, failed)，
  /// 字段含义与旧版同名返回一致（joined = 新增入池数）。
  /// 作用域由调用方定（错题本里是勾选题或当前筛选结果），本方法
  /// 不做筛选；单题失败计入 `failed`，不中断整批。
  /// Stage 4：批量提交只发一个事件——逐题翻标志各发一个事件时
  /// 由 scope 合并成一个发出去；全跳过时一个事件都不发。
  Future<({int joined, int skipped, int failed})> joinReviewBatch(
    List<Question> questions, {
    required ReviewScheduler scheduler,
  }) async {
    return DataChangeBus.instance.scope(() async {
      final r = await joinFsrsPool(questions: questions, scheduler: scheduler);
      return (joined: r.added, skipped: r.skipped, failed: r.failed);
    });
  }

  /// P3 入口 1–3 共用：当前已在复习池里的题 id（fsrs_cards 行）。
  /// 只读；读不到（旧库/无表/Fake 未覆盖）时返回空集，不抛错——
  /// 调用方把“未知”当成“都不在池里”，行内标记宁缺勿错。
  Future<Set<String>> fsrsPoolQuestionIds() async {
    try {
      return (await _db.fsrsCardQuestionIds()).toSet();
    } catch (_) {
      return const {};
    }
  }

  /// 错题本 pill / 筛选 / 排序用：池里已开始正式复习的题 → 下次到期
  /// 时间（调度器 `nextDueAt` 同口径：未开始的卡 firstReviewedAt
  /// 为空，不算有下次到期日，不进 map）。只读；读不到时返回空
  /// map，不抛错——调用方把“未知”当成“都没有下次到期日”，
  /// 不拖垮列表加载。
  Future<Map<String, DateTime>> fsrsNextDueByQuestion({
    required ReviewScheduler scheduler,
  }) async {
    try {
      final cards = await scheduler.loadAllCards();
      return {
        for (final c in cards)
          if (c.firstReviewedAt != null) c.questionId: c.card.due,
      };
    } catch (_) {
      return const {};
    }
  }

  /// P3 入口 3 样本量统计用：全部 attempts（正式 + 专项）。
  /// 读不到时返回空列表，不抛错（统计口径里样本量为 0 即“数据较少”）。
  Future<List<AttemptData>> loadAllAttempts() async {
    try {
      return await _db.allAttempts();
    } catch (_) {
      return const [];
    }
  }

  /// P3：三个加题入口 + 详情页“加入复习”共用的 FSRS 入池批量方法。
  ///
  /// 逐题走同一 [ReviewScheduler.initializeQuestion]：已在池的题
  /// 直接返回现有卡片，不建第二张（去重，一题一卡）；不在池的建新卡。
  /// 入池同时把 `review_joined` 标志翻成 true（FSRS 全量迁移包2：
  /// 只翻标志，不再播种 cause_records；旧注释“FSRS 卡片与旧队列
  /// 必须同进同出”已随 buildDueQueue 删除失效）。标志翻失败
  /// 不影响入池计数，卡片已建即算新增。
  /// 单题 initialize 失败计入 `failed`，不中断整批；输入重复 id 只
  /// 算一次（按首次出现顺序去重）。
  /// 返回 (added 新增，skipped 已在池跳过，failed 失败）。
  /// 取消加入不走这里（见 [cancelReviewBatch]：只翻 review_joined，
  /// FSRS 卡片保留，历史状态不删，重加时本方法直接返回原卡）。
  Future<({int added, int skipped, int failed})> joinFsrsPool({
    required List<Question> questions,
    required ReviewScheduler scheduler,
  }) async {
    final pooled = await scheduler.pooledQuestionIds();
    final seen = <String>{};
    var added = 0;
    var skipped = 0;
    var failed = 0;
    for (final q in questions) {
      if (!seen.add(q.id)) continue;
      if (pooled.contains(q.id)) {
        skipped++;
        continue;
      }
      try {
        await scheduler.initializeQuestion(q.id);
        pooled.add(q.id);
        try {
          await setReviewJoinedFlag(q, true);
        } catch (_) {
          // 标志翻失败不影响入池：卡片已建，题已在池。
        }
        added++;
      } catch (_) {
        failed++;
      }
    }
    return (added: added, skipped: skipped, failed: failed);
  }

  /// 批量取消加入复习（B11-6）：与详情页单个取消同语义——只把
  /// review_joined 置回 false，FSRS 卡片保留（重加入时直接返回原卡，
  /// 不重置状态）。本来就没加入的题计入 `skipped`；单题保存失败计入
  /// `failed`，不中断整批。
  Future<({int cancelled, int skipped, int failed})> cancelReviewBatch(
    List<Question> questions,
  ) async {
    // Stage 4：批量提交只发一个事件（方案 §四，见 joinReviewBatch）。
    return DataChangeBus.instance.scope(() async {
      var cancelled = 0;
      var skipped = 0;
      var failed = 0;
      for (final q in questions) {
        if (!q.reviewJoined) {
          skipped++;
          continue;
        }
        try {
          await setReviewJoinedFlag(q, false);
          cancelled++;
        } catch (_) {
          failed++;
        }
      }
      return (cancelled: cancelled, skipped: skipped, failed: failed);
    });
  }

  /// 2026-11-26 口径迁移面 C：`dueToday()` / `homeRevCounts()` /
  /// `subjectCounts()` 已删除——全仓 grep 确认 lib 内只剩
  /// `organize_notifier.dart` 一处调用方，已迁到 FSRS 口径
  /// `fsrsDueQuestionIds().length`；首页 / 角标 / 错题本封面此前已
  /// 分别迁到 `fsrsDueCountsBySubject` / `fsrsDueTotal`。
  /// 2026-11-26 第二批清理：旧口径互斥拆分 `reviewBucketOf` /
  /// `isReviewDue` 也已删除（调用方随复习列表分组与元信息行迁移
  /// 而归零）；`buildDueQueue` 已随 FSRS 全量迁移包2删除（到期复习只走 FSRS）。

  /// 空内容不保存。
  Future<CauseRecord> saveRemedy(CauseRecord r, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return r;
    final now = DateTime.now();
    final entry = '${now.year}-${now.month}-${now.day}：$trimmed';
    final updated = r.copyWith(remedyHistory: [entry, ...r.remedyHistory]);
    await _db.updateCauseRemedy(updated);
    return updated;
  }

  /// 十四批 M3：attempt 写入（一次会话每题一条；跳过后重遇更新同一条）。
  Future<String> recordAttempt(AttemptData attempt) =>
      _db.recordAttemptTxn(attempt: attempt);

  /// P5：核对提交事务双写（attempts 行 + fsrs_cards 行 + 事件账本
  /// 同一事务，见 AppDatabase.submitReviewCheckTxn）。
  /// [result] 为 null = 专项练习或无法判分：只写 attempts，不推进
  /// FSRS、不改到期时间。[scheduler] 须是与本库同源的调度器
  ///（生产是 reviewSchedulerProvider 的 SQLite 调度器）。
  Future<({String attemptId, DateTime? nextDue})> submitReviewCheck({
    required AttemptData attempt,
    required ReviewResult? result,
    required DateTime reviewedAt,
    required String eventId,
    required ReviewScheduler scheduler,
  }) => _db.submitReviewCheckTxn(
    attempt: attempt,
    result: result,
    reviewedAt: reviewedAt,
    eventId: eventId,
    scheduler: scheduler,
  );

  /// P5：首次呈现记录（第六轮补充第 1 项，见
  /// AppDatabase.recordFirstPresentedTxn）。返回本次是否写下了
  ///（同一内容版本已有记录时返回 false，不重计）。
  Future<bool> recordFirstPresented({
    required String questionId,
    required DateTime presentedAtUtc,
    required String localDate,
    required int contentVersion,
  }) => _db.recordFirstPresentedTxn(
    questionId: questionId,
    presentedAtUtc: presentedAtUtc,
    localDate: localDate,
    contentVersion: contentVersion,
  );

  /// P4：今日新题释放预览（纯计算，不写库）。
  ///
  /// 读调度器的全部卡片 + 本地全部题目（归档过滤走 activePoolIds
  /// 同款口径）；[dailyNewLimit] 是设置值（默认 10、上限 50，
  /// planNewRelease 内归一）；[now] 默认当前时间——本地日期按
  /// [now] 的本地日历日算，时间戳一律 UTC。调用方（复习页 load）
  /// 用它只做展示；真正释放发生在题目首次显示时（见
  /// [recordQuestionPresented]），未显示的题不提前耗额度。
  Future<FsrsReleasePlan> previewNewRelease({
    required ReviewScheduler scheduler,
    required int dailyNewLimit,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final cards = await scheduler.loadAllCards();
    final questions = await all(includeArchived: true);
    final archivedIds = {
      for (final q in questions)
        if (q.isArchived) q.id,
    };
    return planNewRelease(
      cards: cards,
      archivedIds: archivedIds,
      dailyNewLimit: dailyNewLimit,
      todayLocalDate: localDateString(at),
    );
  }

  /// P4：FSRS 真正到期的题（getDueQuestions 已隔离未释放新卡，
  /// 这里只再滤掉归档题——归档题保留卡片，但不进到期队列）。
  /// 读不到时返回空列表，不抛错（到期标记是锦上添花，不拖垮列表）。
  Future<List<String>> fsrsDueQuestionIds({
    required ReviewScheduler scheduler,
    DateTime? now,
  }) async {
    try {
      final due = await scheduler.getDueQuestions(now ?? DateTime.now());
      final questions = await all(includeArchived: true);
      final archivedIds = {
        for (final q in questions)
          if (q.isArchived) q.id,
      };
      return activePoolIds(
        poolIds: due.toSet(),
        archivedIds: archivedIds,
      ).toList()..sort((a, b) => due.indexOf(a).compareTo(due.indexOf(b)));
    } catch (_) {
      return const [];
    }
  }

  /// FSRS 口径：到期题按学科分组计数（首页学科行与左导航角标共用）。
  ///
  /// 实现 = [fsrsDueQuestionIds] 的 id 集合按 `questions.subjectId`
  /// 分组（归档已在 [fsrsDueQuestionIds] 内滤掉）。键按库里的
  /// `subjects` 表取（B2 约定：新学科也要有计数键；到期题的学科若不在
  /// subjects 表里，仍单独立键，不静默丢数）。求和 = [fsrsDueTotal] =
  /// `fsrsDueQuestionIds().length`（对照测试断言）。读不到时返回全 0 的
  /// map，不抛错。
  Future<Map<String, int>> fsrsDueCountsBySubject({
    required ReviewScheduler scheduler,
    DateTime? now,
  }) async {
    try {
      final dueIds = await fsrsDueQuestionIds(scheduler: scheduler, now: now);
      final questions = await all(includeArchived: true);
      final subjectByQuestionId = {
        for (final q in questions) q.id: q.subjectId,
      };
      final subjectsList = await subjects();
      return fsrsDueCountsBySubjectPure(
        dueIds: dueIds,
        subjectByQuestionId: subjectByQuestionId,
        subjectIds: [for (final s in subjectsList) s.id],
      );
    } catch (_) {
      try {
        final subjectsList = await subjects();
        return {for (final s in subjectsList) s.id: 0};
      } catch (_) {
        return const {};
      }
    }
  }

  /// FSRS 口径：到期总数 = [fsrsDueCountsBySubject] 各科之和，与
  /// `fsrsDueQuestionIds().length` 相等（首页焦点卡大数字与角标
  /// 总数共用；对照测试断言）。
  Future<int> fsrsDueTotal({
    required ReviewScheduler scheduler,
    DateTime? now,
  }) async {
    final counts = await fsrsDueCountsBySubject(scheduler: scheduler, now: now);
    return counts.values.fold<int>(0, (a, b) => a + b);
  }

  /// [fsrsDueCountsBySubject] 的纯函数核：输入到期 id、题→学科映射、
  /// 学科 id 列表，输出每科到期数。不读库，便于单测（仿
  /// `planNewRelease` 的纯函数模式，夹具数据即可覆盖）。
  static Map<String, int> fsrsDueCountsBySubjectPure({
    required Iterable<String> dueIds,
    required Map<String, String> subjectByQuestionId,
    required Iterable<String> subjectIds,
  }) {
    final map = <String, int>{for (final id in subjectIds) id: 0};
    for (final qid in dueIds) {
      final sid = subjectByQuestionId[qid];
      if (sid == null) continue;
      map[sid] = (map[sid] ?? 0) + 1;
    }
    return map;
  }

  ///
  /// 只在到期复习会话里、题目第一次进入“看题”步时调（专项练习不调，
  /// 不耗新题额度）；同一内容版本已有记录时 recordFirstPresented
  /// 返回 false（退出恢复、第二天重看都不重计）；内容重置后新版本
  /// 重新计。题还没卡时 recordFirstPresentedInto 会先建一张新卡。
  /// 写入失败时返回 false，不抛错——呈现记录失败绝不能拖垮会话。
  Future<bool> recordQuestionPresented({
    required Question question,
    DateTime? now,
  }) async {
    try {
      final at = now ?? DateTime.now();
      return await recordFirstPresented(
        questionId: question.id,
        presentedAtUtc: at.toUtc(),
        localDate: localDateString(at),
        contentVersion: question.contentVersion,
      );
    } catch (_) {
      return false;
    }
  }

  /// 十四批 M3：读一条 attempt / 某会话全部 attempts。
  Future<AttemptData?> loadAttempt({
    required String sessionId,
    required String questionId,
  }) => _db.loadAttempt(sessionId: sessionId, questionId: questionId);

  Future<List<AttemptData>> loadAttemptsForSession(String sessionId) =>
      _db.loadAttemptsForSession(sessionId: sessionId);

  /// 十四批 M3（M3-10 断点恢复重建用）：本会话里该错因是否已有 verdict 事件。
  ///
  /// P2（2026-11-25）：产品流程不再调用本方法——会话恢复只认
  /// attempts 行（见 _validateSavedSession）。旧写入层已随 FSRS
  /// 全量迁移（包1）退役；本读方法保留，供断点恢复重建时查
  /// review_history 的实际写入。
  Future<bool> hasSessionVerdict({
    required String causeStableId,
    required String sessionId,
  }) =>
      _db.hasSessionVerdict(causeStableId: causeStableId, sessionId: sessionId);

  Future<ReviewSessionState?> reviewState() => _db.loadReviewState();

  /// 十四批 M3（M3-10）：保存完整会话快照（队列 + 位置 + session_id +
  /// 模式 + 跳过次数 + 每题状态）。旧调用方只传 queue/position 时
  /// 其余列写 NULL。
  Future<void> saveReviewState({
    required List<ReviewQueueItem> queue,
    required int position,
    String? sessionId,
    String? mode,
    Map<String, int>? skips,
    Map<String, Map<String, Object?>>? perQuestionState,
  }) => _db.saveReviewState(
    queue: queue,
    position: position,
    sessionId: sessionId,
    mode: mode,
    skips: skips,
    perQuestionState: perQuestionState,
  );

  Future<void> clearReviewState() => _db.clearReviewState();

  Future<void> toggleFavorite(Question q) async =>
      _db.upsertQuestion(q.copyWith(isFavorite: !q.isFavorite));

  /// 待整理题数（左导航整理角标）：未确认整理且未归档。
  Future<int> pendingOrganizeCount() async {
    final list = await all();
    return list.where((q) => !q.isOrganized && !q.isArchived).length;
  }

  /// 待整理题数（按学科）。键按库里的 subjects 表取（B2：新学科也要
  /// 有计数键；口径本身不变）。
  Future<Map<String, int>> pendingOrganizeBySubject() async {
    final list = await all();
    final subjects = await this.subjects();
    final map = <String, int>{};
    for (final s in subjects) {
      map[s.id] = list
          .where((q) => q.subjectId == s.id && !q.isOrganized && !q.isArchived)
          .length;
    }
    return map;
  }

  Future<({String kind, String subjectId, String title})?> recentTask() =>
      _db.recentTask();

  Future<void> saveRecentTask({
    required String kind,
    required String subjectId,
    required String title,
  }) => _db.saveRecentTask(kind: kind, subjectId: subjectId, title: title);

  Future<void> archive(Question q, {bool archived = true}) async =>
      _db.upsertQuestion(q.copyWith(isArchived: archived));

  /// U1-1：版本令牌（可选具名参数）。不传令牌时保持原有行为；
  /// 传令牌时写入前在事务内比对行版本，不符抛 [SaveTokenMismatch]、
  /// 零写入（见 [upsertQuestionIntoImpl]）。令牌取自表单加载时的
  /// 模型（`q.contentVersion` 必须是加载时看到的版本，绝不能取
  /// 保存时刚读到的行版本——刚读到的行若已被 OCR worker 等改过，
  /// 用它的版本当令牌会把表单的旧题干整行覆盖回去）。
  Future<void> save(Question q, {SaveToken? token}) async =>
      _db.upsertQuestion(q, token: token);

  Future<void> delete(Question q) async => _db.deleteQuestion(q.id);

  /// FR-37：批量删题：整批一个事务（数据层 `deleteQuestionsBatch`），
  /// 中途失败整批回滚；调用方（错题本批量删除）按整体成功 / 失败报数。
  Future<void> deleteQuestions(List<Question> questions) async =>
      _db.deleteQuestionsBatch(questions.map((q) => q.id).toList());

  // ---------- 学科 / 文件夹 / 标签 / 试卷 / 知识点 / 设置 ----------

  Future<List<Subject>> subjects() => _db.allSubjects();

  Future<void> saveSubject(Subject s) => _db.upsertSubject(s);

  Future<void> deleteSubject(String id) => _db.deleteSubject(id);

  Future<List<Folder>> folders({String? subjectId}) =>
      _db.allFolders(subjectId: subjectId);

  Future<void> saveFolder(Folder f) => _db.upsertFolder(f);

  /// SR-P2-36：整科同名预检：同一学科下是否存在与 [name] 同名、
  /// 且 id 不是 [excludeId] 的文件夹（新建/改名/移入前调）。
  Future<bool> folderNameExistsInSubject(
    String subjectId,
    String name, {
    String? excludeId,
  }) => _db.folderNameExistsInSubject(subjectId, name, excludeId: excludeId);

  Future<int> deleteFolder(Folder f) => _db.deleteFolder(f);

  Future<List<String>> tags() => _db.allTags();

  Future<void> addTag(String name) => _db.insertTag(name);

  Future<void> renameTag(String oldName, String newName) =>
      _db.renameTag(oldName, newName);

  Future<void> deleteTag(String name) => _db.deleteTag(name);

  Future<List<Exam>> exams() => _db.allExams();

  Future<void> addExam(Exam e) => _db.insertExam(e);

  Future<void> renameExam(String id, String newName) =>
      _db.renameExam(id, newName);

  Future<void> deleteExam(String id) => _db.deleteExam(id);

  /// B11-9 考试倒计时：考试事件（独立数据，与试卷实体无任何关联，
  /// 存 settings 表 `examEvents` 键，见 database.dart）。
  /// 列表很小（用户手管几场考试），增删改走读-改-整表写回；
  /// 读出来按日期升序（最近的在前，设置页与首页都直接用这个顺序）。
  Future<List<ExamEvent>> examEvents() async {
    final list = await _db.loadExamEvents();
    list.sort((a, b) => a.date.compareTo(b.date));
    return list;
  }

  /// 新增或改名/改日期：同 id 覆盖（原地更新，顺序由 [examEvents] 的
  /// 日期排序定），新 id 追加。FR-38/FR-39：走原始 JSON 行改动 +
  /// 同一事务（见 `db_settings.dart`），并发写不丢改动、坏行不丢失。
  Future<void> saveExamEvent(ExamEvent e) async => _db.saveExamEvent(e);

  /// 删除一场考试（只删事件本身，不动任何题目/试卷）。FR-38/FR-39：
  /// 与 [saveExamEvent] 同款原子入口，原始 JSON 里的其余行原样保留。
  Future<void> deleteExamEvent(String id) async => _db.deleteExamEvent(id);

  Future<List<KnowledgePoint>> knowledgePoints() => _db.allKnowledgePoints();

  Future<void> addKnowledgePoint(KnowledgePoint kp) =>
      _db.insertKnowledgePoint(kp);

  Future<void> renameKnowledgePoint(String id, String newName) =>
      _db.renameKnowledgePoint(id, newName);

  Future<void> deleteKnowledgePoint(String id) => _db.deleteKnowledgePoint(id);

  /// 章节改名 / 删除章节（R10 学科管理知识点树：章节行也有改名/删除，
  /// 与 HTML `viewSubjects` 一致）。章节只随知识点存在，加章节须同时
  /// 给第一个知识点——空章节没有可存的行（不改 Schema）。
  Future<void> renameChapter(
    String subjectId,
    String oldChapter,
    String newChapter,
  ) => _db.renameChapter(subjectId, oldChapter, newChapter);

  Future<void> deleteChapter(String subjectId, String chapter) =>
      _db.deleteChapter(subjectId, chapter);

  Future<AppSettings> settings() => _db.loadSettings();

  Future<void> saveSettings(AppSettings s) => _db.saveSettings(s);

  /// 十九批 A3：「我的查找」——存下来的查找（saved_searches 表）。
  /// 读失败返回空列表（查找是锦上添花，绝不能拖垮列表加载；
  /// 与 ocrJobsForQuestion 同款兜底）。
  Future<List<SavedSearch>> savedSearches() async {
    try {
      return await _db.savedSearches();
    } catch (_) {
      return const [];
    }
  }

  /// 十九批 A3：存一条查找（同 id 覆盖）。
  Future<void> saveSavedSearch(SavedSearch search) =>
      _db.saveSavedSearch(search);

  /// 十九批 A3：删一条查找（id 不存在时空操作）。
  Future<void> deleteSavedSearch(String id) => _db.deleteSavedSearch(id);

  /// B3：上次停留的路由（复用 settings 表 key `lastRoute`，见 database.dart）。
  Future<String?> lastRoute() => _db.loadLastRoute();

  Future<void> saveLastRoute(String route) => _db.saveLastRoute(route);

  Future<List<CollectTask>> collectTasks() => _db.allCollectTasks();

  Future<void> saveCollectTask(CollectTask t) => _db.upsertCollectTask(t);

  Future<void> deleteCollectTask(String id) => _db.deleteCollectTask(id);

  // ---------- 框（question_boxes，§1.5；P2） ----------

  /// 读某任务的全部草稿框（“继续修框”恢复用）。
  Future<List<QuestionBox>> boxesForTask(String taskId) =>
      _db.boxesForTask(taskId);

  /// 读同一页图上全部已确认题的框（重框同页上下文）。
  Future<List<QuestionBox>> boxesForPageImage(String pageImagePath) =>
      _db.boxesForPageImage(pageImagePath);

  /// 草稿保存：修框关闭 / 取消 / 切页时批量保存（拖拽只改内存）。
  Future<void> saveDraftBoxes({
    required String taskId,
    required Map<int, List<QuestionBox>> boxesByPage,
    required Map<int, int> rotations,
  }) => _db.saveDraftBoxes(
    taskId: taskId,
    boxesByPage: boxesByPage,
    rotations: rotations,
  );

  /// 详情页重框：只替换这一题的框（同页其他题不动）。
  Future<void> replaceQuestionBoxes(
    String questionId,
    List<QuestionBox> boxes,
  ) => _db.replaceQuestionBoxes(questionId, boxes);

  /// B3-P01 详情页重框：换框 + 保存切片一个事务（框换了、切片
  /// 一起换；任一步失败一起回滚）。切片文件由调用方在调用前写盘。
  Future<void> replaceQuestionBoxesAndSlice(
    String questionId,
    List<QuestionBox> boxes, {
    required String slicePath,
    required int sliceWidth,
    required int sliceHeight,
  }) => _db.replaceQuestionBoxesAndSlice(
    questionId,
    boxes,
    slicePath: slicePath,
    sliceWidth: sliceWidth,
    sliceHeight: sliceHeight,
  );

  /// 确认拆题四步同事务（切片须由调用方先写盘）。
  /// SR-P1-2：有未框页时把保留任务 + 未框页草稿一起传进去，
  /// 与拆题同事务提交，不再由调用方在事务外重建。
  Future<void> confirmSplit({
    required CollectTask originalTask,
    required List<Question> questions,
    required List<CollectTask> splitTasks,
    required Map<String, List<QuestionBox>> boxesByQuestionId,
    CollectTask? retainedTask,
    Map<int, List<QuestionBox>> retainedBoxesByPage = const {},
  }) => _db.confirmSplit(
    originalTask: originalTask,
    questions: questions,
    splitTasks: splitTasks,
    boxesByQuestionId: boxesByQuestionId,
    retainedTask: retainedTask,
    retainedBoxesByPage: retainedBoxesByPage,
  );

  Future<String> exportBackupJson() => _db.exportBackupJson();

  /// B4.2：恢复备份（整体覆盖，见 database.dart）。
  Future<void> importBackupJson(Map<String, dynamic> data) =>
      _db.importBackupJson(data);

  /// §2.3/P3：zip 文件级备份（JSON + imports/ + slices/）。
  Future<List<int>> exportBackupZip() => _db.exportBackupZip();

  /// 十四批 M2：带警告的 zip 备份（字节 + 可见警告列表）。
  /// WP-C #8 U3-2：另含 `brokenFiles`（未进包的文件清单）与 `status`
  ///（complete 仅当零警告且零 BROKEN 文件）。
  Future<
    ({
      List<int> bytes,
      List<String> warnings,
      List<String> brokenFiles,
      BackupExportStatus status,
    })
  >
  exportBackupZipWithReport() => _db.exportBackupZipWithReport();

  /// §2.3/P3：zip 备份恢复（JSON + 文件一起恢复）。
  /// GPT-P1：恢复只接受已读到的字节，不再提供按路径重读的入口——
  /// 校验过的字节与导入的字节必须是同一份。
  /// 十四批 M2：返回恢复警告列表（缺失/不可读的图块已从引用里去掉）。
  Future<List<String>> importBackupZip(List<int> bytes) =>
      _db.importBackupZip(bytes);

  /// §4.5/P3：孤儿扫描（imports/ + slices/ 里无引用的文件）。
  Future<OrphanScan> scanOrphanFiles() => _db.scanOrphans();

  /// §4.5/P3：孤儿清理（只删传入的无引用文件；删除前重算引用，
  /// 仍被引用的跳过并计入返回，FR-06(a)）。
  Future<({int deletedCount, int freedBytes, int skippedReferencedCount})>
  deleteOrphanFiles(List<String> relativePaths) =>
      _db.cleanOrphans(relativePaths);

  /// §4.5/P3：空间占用分项（设置页“空间占用”显示用）。
  Future<({int importsBytes, int slicesBytes})> storageUsageBreakdown() =>
      ImportService.storageUsageBreakdown();

  /// B4.1：今天是否已弹过到期复习提醒（settings 表 key，见 database.dart）。
  Future<String?> lastRecheckReminderDate() =>
      _db.loadLastRecheckReminderDate();

  Future<void> saveLastRecheckReminderDate(String date) =>
      _db.saveLastRecheckReminderDate(date);

  /// 待定3：首页备份失败横幅的标志（settings 表 key，见 database.dart）。
  Future<bool> backupFailed() => _db.loadBackupFailed();

  Future<void> setBackupFailed(bool failed) => _db.saveBackupFailed(failed);

  /// B11-10：今天已整理的题数（整理工作台空状态“今日小结”用；口径见
  /// db_settings.dart 的 organizedToday*：当天内经整理确认由未整理
  /// 变为已整理的题数，本地日期）。
  Future<int> organizedTodayCount({DateTime? now}) =>
      _db.organizedTodayCount(now: now);

  /// 十二批功能 4：首页历史——打开题目详情记一次查看（同一题只留一条，
  /// 时间更新为最后一次；超过 30 条剪掉最旧的）。调用方
  /// `DetailNotifier.load` 成功后调，且包 try/catch（D-88：记录失败
  /// 绝不能拖垮详情加载）。
  Future<void> recordQuestionViewed(String questionId) =>
      _db.recordQuestionViewed(questionId);

  /// 十二批功能 4：首页历史——最近查看的题（最新在前，最多 30 条；
  /// 已删题跳过；已归档 / 已掌握的题照常返回）。
  Future<List<({Question question, DateTime viewedAt})>>
  recentlyViewedQuestions() => _db.recentlyViewedQuestions();

  /// B4.3：切换数据库位置并迁移旧库与文件目录（见 database.dart）。
  /// 目标已有库时先问用户，`overwrite` 按用户选择传（覆盖 / 保留 /
  /// 取消；文件目录沿用同一选择）。`onProgress` / `isCancelled`
  /// 见 [AppDatabase.migrateDataFiles]（大目录复制进度 / 取消）。
  Future<DbMigrationOutcome> migrateToDirectory(
    String dir, {
    bool overwrite = false,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) => _db.migrateToDirectory(
    dir,
    overwrite: overwrite,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );

  Future<void> setCustomDataDirectory(String dir) =>
      _db.setCustomDataDirectory(dir);
}
