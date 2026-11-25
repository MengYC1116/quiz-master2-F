import '../data/database.dart';
import '../data/data_change_events.dart';
import '../data/review_engine.dart';
import '../data/review_scheduler.dart';
import '../models/exam_event.dart';
import '../models/models.dart';
import '../services/import_service.dart';
import '../services/ocr_key_store.dart';

/// 一道题的复习归属（互斥拆分）：首页焦点卡“待解决 / 复查”与错题本
/// 封面三数共用此口径，同一道题只落一个桶。
///
/// - [ReviewBucket.pending]：至少一个错因未解决（待解决 / 解决中）
///   → 计入“要复习”。
/// - [ReviewBucket.recheck]：全部错因已解决、且至少一条到了复查时间
///   → 只计入“待复查”，不计入“要复习”。
/// - [ReviewBucket.solved]：全部错因已解决、且无一条到复查时间
///   → 计入三元组第三项“已解决”（已掌握且不在复查期，不在要复习总数内）。
/// - [ReviewBucket.none]：无错因记录 → 三处都不计。
///
/// 互斥保证：`pending` 题数 + `recheck` 题数 = 要复习总数
/// （[QuestionRepository.dueToday] 的题数、首页焦点卡总数）。
enum ReviewBucket { pending, recheck, solved, none }

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

  /// 一道题的复习归属：按它的全部错因记录互斥分类（见 [ReviewBucket]）。
  /// 首页焦点卡的待解决 / 复查拆分与错题本封面三数都走这里，
  /// 不再各自定义（SR-P1-1）。
  static ReviewBucket reviewBucketOf(List<CauseRecord> records) {
    if (records.isEmpty) return ReviewBucket.none;
    if (records.any((r) => r.status != CauseStatus.solved)) {
      return ReviewBucket.pending;
    }
    if (records.any((r) => r.isRecheckDue)) return ReviewBucket.recheck;
    return ReviewBucket.solved;
  }

  /// 这道题要不要复习：有未解决错因，或全部已解决但到了复查时间。
  /// 等价于 `reviewBucketOf` 落在 `pending` 或 `recheck`。
  static bool isReviewDue(List<CauseRecord> records) {
    final bucket = reviewBucketOf(records);
    return bucket == ReviewBucket.pending || bucket == ReviewBucket.recheck;
  }

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
  /// 时 `status` / `solvedCount` / `recheckDate` / `lastCheck`
  /// 的改动按设计丢弃、不写入——改状态走 [recordSelfCheck]；
  /// 行不存在时整行 INSERT，全列按传入值写。
  Future<void> saveCauseRecord(CauseRecord r) => _db.updateCauseRemedy(r);

  /// 手动加入 / 取消加入复习：加入时给这道题建解决记录（每个错因一条）；
  /// 取消后记录保留，再加入时接着治。错因是空的题加不进复习，返回 false。
  /// SR-P2-8：题行 + 错因记录同事务（见 [AppDatabase.setReviewJoined]），
  /// 不再两步写——中间失败不留“已标加入、却无记录”的题。
  Future<bool> setReviewJoined(Question q, bool joined) =>
      _db.setReviewJoined(q, joined);

  /// 批量加入复习时这道题还有没有可加的错因（B11-6 判定口径）：
  /// - 错因是空的 → 没有（[setReviewJoined] 也会返回 false）；
  /// - 某个错因还没有解决记录 → 它还没治过，可加；
  /// - 某条记录未解决（待解决 / 解决中）→ 可加；
  /// - 某条记录已解决但到了复查时间 → 仍要复查，可加；
  /// - 全部错因已解决且未到复查时间 → 已无未解决错因，不可加（跳过）。
  /// 只看传入的 `records`（该题的错因记录），不读库，便于单测覆盖。
  static bool hasJoinableCause(Question q, List<CauseRecord> records) {
    if (q.allCauses.isEmpty) return false;
    final byCause = {for (final r in records) r.cause: r};
    for (final cause in q.allCauses) {
      final r = byCause[cause];
      if (r == null) return true;
      if (r.status != CauseStatus.solved) return true;
      if (r.isRecheckDue) return true;
    }
    return false;
  }

  /// 批量加入复习（B11-6）：逐题按 [hasJoinableCause] 判定，只加
  /// 未解决的错因——已治愈错因的记录已在库里，[setReviewJoined] 的
  /// 播种用 ConflictAlgorithm.ignore，不动它（状态 / 计数 / 复查日
  /// 都保留）；一道题没有任何未解决错因时跳过，计入 `skipped`。
  /// 作用域由调用方定（错题本里是勾选题或当前筛选结果），本方法
  /// 不做筛选；单题保存失败计入 `failed`，不中断整批。
  Future<({int joined, int skipped, int failed})> joinReviewBatch(
    List<Question> questions,
  ) async {
    final records = await causeRecords();
    final byQ = <String, List<CauseRecord>>{};
    for (final r in records) {
      (byQ[r.questionId] ??= []).add(r);
    }
    // Stage 4：批量提交只发一个事件（方案 §四）——逐题 setReviewJoined
    // 各发一个事件时由 scope 合并成一个发出去；全跳过时一个事件都不发。
    // 仍调虚方法 setReviewJoined（单测 FakeRepo 靠覆写它，见
    // test/b11_6_batch_review_test.dart），不直接调 db 静态方法。
    return DataChangeBus.instance.scope(() async {
      var joined = 0;
      var skipped = 0;
      var failed = 0;
      for (final q in questions) {
        if (!hasJoinableCause(q, byQ[q.id] ?? const [])) {
          skipped++;
          continue;
        }
        try {
          final ok = await setReviewJoined(q, true);
          if (ok) {
            joined++;
          } else {
            skipped++;
          }
        } catch (_) {
          failed++;
        }
      }
      return (joined: joined, skipped: skipped, failed: failed);
    });
  }

  /// 批量取消加入复习（B11-6）：与详情页单个取消同语义——只把
  /// review_joined 置回 false，错因记录保留，重加入可恢复
  /// （[setReviewJoined] 取消时不删记录）。本来就没加入的题计入
  /// `skipped`；单题保存失败计入 `failed`，不中断整批。
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
          await setReviewJoined(q, false);
          cancelled++;
        } catch (_) {
          failed++;
        }
      }
      return (cancelled: cancelled, skipped: skipped, failed: failed);
    });
  }

  /// 同步某题的解决记录与它当前的错因：删掉已不在错因里的记录，
  /// 给新加的错因补一条待解决记录（仅已加入复习的题）。
  /// SR-P2-8：删旧 + 补新同事务（见 [AppDatabase.syncCauseRecords]）。
  Future<void> syncCauseRecords(Question q) => _db.syncCauseRecords(q);

  /// 要复习的题：手动加入复习、已整理、至少一个错因还没解决
  /// （待解决 / 解决中）或到了复查时间。数题不数错因。
  /// 口径即 [reviewBucketOf] 落在 `pending` 或 `recheck`，
  /// 与首页焦点卡、错题本封面三数互斥拆分同源（SR-P1-1）。
  /// 已归档的题不算（与复习页 B6 主列表同口径；记录保留在库里，
  /// 取消归档后重新计入）。`includeArchived: true` 仅供显式
  /// 需要时用，默认排除。
  Future<List<Question>> dueToday({bool includeArchived = false}) async {
    final questions = await all(includeArchived: includeArchived);
    // 记录走仓库方法 causeRecords()（与 _db.allCauseRecords() 同义，
    // 便于单测覆盖；subjectCounts 同款做法）。
    final records = await causeRecords();
    final byQ = <String, List<CauseRecord>>{};
    for (final r in records) {
      (byQ[r.questionId] ??= []).add(r);
    }
    return questions.where((q) {
      if (!q.reviewJoined || !q.isOrganized) return false;
      final rs = byQ[q.id] ?? const <CauseRecord>[];
      return isReviewDue(rs);
    }).toList();
  }

  /// 首页焦点卡与导航速览同一口径（homeRevCounts）：每科要复习的题数
  /// （手动加入、未解决，含到复查时间的题；数题不数错因）。
  ///
  /// 键按库里的 subjects 表取（B2：新增学科也要有计数键；以前按
  /// `Subject.all` 初始化，新学科的键缺失，首页 `?? 0` 会把有题
  /// 的新学科显示成 0）。口径本身不变，只改键的来源。
  Future<Map<String, int>> homeRevCounts() async {
    final due = await dueToday();
    final subjects = await this.subjects();
    final map = <String, int>{};
    for (final s in subjects) {
      map[s.id] = due.where((q) => q.subjectId == s.id).length;
    }
    return map;
  }

  /// 各科三数：要复习 / 待复查 / 已解决（不显示总题数）。
  /// 与首页焦点卡同一互斥拆分（见 [ReviewBucket]、[reviewBucketOf]）：
  /// 有未解决错因的题只计“要复习”；全部已解决且到了复查时间的题
  /// 只计“待复查”；全部已解决且未到复查时间的题只计第三项“已解决”。
  /// 同一道题只落一个桶，不双计；要复习 + 待复查 = 该科要复习总数
  /// （[homeRevCounts] 该科数、[dueToday] 该科题数）。
  /// 第三项 `solved` 的语义：已加入复习、已整理、全部错因已解决
  /// 且无一条到复查时间的题数——即已掌握且不在复查期的题；已掌握
  /// 但到了复查时间的题计入“待复查”而不计入这一项。
  /// 已归档的题不算（与 dueToday / 复习页同口径；取消归档后
  /// 重新计入）。
  ///
  /// 键按库里的 subjects 表取（B2 补充：新增学科也要有计数键；以前按
  /// `Subject.all` 初始化，新学科的键缺失，错题本封面三数会显示 0）。
  /// 口径本身不变，只改键的来源。记录走仓库方法 `causeRecords()`
  ///（与 `_db.allCauseRecords()` 同义），便于单测覆盖。
  Future<Map<String, (int toReview, int toRecheck, int solved)>> subjectCounts({
    bool includeArchived = false,
  }) async {
    final questions = await all(includeArchived: includeArchived);
    final records = await causeRecords();
    final byQ = <String, List<CauseRecord>>{};
    for (final r in records) {
      (byQ[r.questionId] ??= []).add(r);
    }
    final subjects = await this.subjects();
    final map = <String, (int, int, int)>{};
    for (final s in subjects) {
      var toReview = 0;
      var toRecheck = 0;
      var solved = 0;
      for (final q in questions) {
        if (q.subjectId != s.id || !q.reviewJoined || !q.isOrganized) {
          continue;
        }
        final rs = byQ[q.id] ?? const <CauseRecord>[];
        switch (reviewBucketOf(rs)) {
          case ReviewBucket.pending:
            toReview++;
          case ReviewBucket.recheck:
            toRecheck++;
          case ReviewBucket.solved:
            solved++;
          case ReviewBucket.none:
            break;
        }
      }
      map[s.id] = (toReview, toRecheck, solved);
    }
    return map;
  }

  /// 自查一个错因：result 是 'solved' / 'unsolved' / 'unsure'。
  /// - 已解决：solvedCount + 1；满 cureChecks 次 → 已解决，复查日 =
  ///   今天 + recheckIntervalDays 天；不满 → 解决中（复查日清掉）。
  /// - 未解决：solvedCount 清 0 → 解决中，复查日清掉（复查不过，
  ///   回到解决中重新治，旧复查日作废）。
  /// - 不确定：不算，不改记录。
  /// - 复查（[isRecheck] 为 true，即这条记录已是已解决且到了复查
  ///   时间）：复查通过不加计数（HTML 口径）——solvedCount 已满
  ///   治愈次数，只顺延复查日；否则一次复查通过会把它加到
  ///   cureChecks + 1。复查不过仍按“未解决”走（清 0 打回解决中）。
  /// 报告的复查通过率另外按 review_history 算，不读 solvedCount，
  ///   不受影响。
  Future<CauseRecord> recordSelfCheck(
    CauseRecord r,
    String result, {
    int cureChecks = 2,
    int recheckIntervalDays = 7,
    bool isRecheck = false,
  }) async {
    if (result == 'unsure') return r;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    late CauseRecord updated;
    if (result == 'solved') {
      final count = isRecheck ? r.solvedCount : r.solvedCount + 1;
      if (isRecheck || count >= cureChecks) {
        updated = r.copyWith(
          status: CauseStatus.solved,
          solvedCount: count,
          lastCheck: now,
          recheckDate: today.add(Duration(days: recheckIntervalDays)),
        );
      } else {
        updated = r.copyWith(
          status: CauseStatus.inProgress,
          solvedCount: count,
          lastCheck: now,
          clearRecheckDate: true,
        );
      }
    } else {
      updated = r.copyWith(
        status: CauseStatus.inProgress,
        solvedCount: 0,
        lastCheck: now,
        clearRecheckDate: true,
      );
    }
    // §4.2：三步同事务（改错因记录 → 记自查历史 → 题目自查次数 +1），
    // 中间失败整体回滚，不留半截记录。
    // SR-P2-16：`updated` 是按传入快照算的 provisional 值——事务内
    // 按库内当前行重算后才写库（见 [AppDatabase.recordSelfCheckInto]），
    // 返回实际写库的记录；两次基于同一旧快照的自查不再互相覆盖计数。
    return _db.recordSelfCheckTxn(
      updated: updated,
      questionId: r.questionId,
      result: result,
      cureChecks: cureChecks,
      recheckIntervalDays: recheckIntervalDays,
      isRecheck: isRecheck,
    );
  }

  /// 写补救：内容保存进该错因的补救历史（带日期），下次复习可见。
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

  /// 十四批 M3：单条错因 verdict 提交（M3-7 治愈规则 + M3-8 核验字段 +
  /// M3-10 幂等）。每错因一次独立事务；调用方按题循环，跨错因部分
  /// 失败时已写错因保留、只补未写成的。
  ///
  /// P2（2026-11-25）：产品流程不再调用本方法——新流程不写
  /// review_history 的 verdict / verification_* 字段（停止写入，
  /// 不物理删除，历史查询能力保留）。本方法仅供旧写入层测试
  /// （b14_m3_verdict_test）保留；P5 决定保留（理由见
  /// db_questions.dart 的 recordSelfCheckIntoImpl 注释；移除归
  /// P3/P4 队列替换时一并做）。
  Future<VerdictSubmitResult> submitCauseVerdict({
    required String questionId,
    required CauseRecord record,
    required String verdict,
    required String verificationStatus,
    required String verificationSource,
    String? attemptId,
    required String sessionId,
    required String submissionId,
    int cureChecks = 2,
    int recheckIntervalDays = 7,
    bool isRecheck = false,
    DateTime? now,
  }) => _db.submitCauseVerdictTxn(
    questionId: questionId,
    record: record,
    verdict: verdict,
    verificationStatus: verificationStatus,
    verificationSource: verificationSource,
    attemptId: attemptId,
    sessionId: sessionId,
    submissionId: submissionId,
    cureChecks: cureChecks,
    recheckIntervalDays: recheckIntervalDays,
    isRecheck: isRecheck,
    now: now,
  );

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
  /// attempts 行（见 _validateSavedSession）。仅供旧写入层保留，
  /// P5 决定保留（理由见 db_questions.dart 的 recordSelfCheckIntoImpl
  /// 注释；移除归 P3/P4 队列替换时一并做）。
  Future<bool> hasSessionVerdict({
    required String causeStableId,
    required String sessionId,
  }) => _db.hasSessionVerdict(
    causeStableId: causeStableId,
    sessionId: sessionId,
  );

  /// 十四批 M3：专项练习“将此错因重新加入复习”（用户主动操作）。
  Future<void> rejoinCause({
    required String questionId,
    required String cause,
    required String subjectId,
  }) => _db.rejoinCauseTxn(
    questionId: questionId,
    cause: cause,
    subjectId: subjectId,
  );

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

  /// 待整理题数（按学科）。键按库里的 subjects 表取（B2：与
  /// [homeRevCounts] 同理，新学科也要有计数键；口径本身不变）。
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
  Future<void> deleteExamEvent(String id) async =>
      _db.deleteExamEvent(id);

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

  /// B4.1：到了复查时间的错因数（已解决且复查日 ≤ 今天，数错因
  /// 不数题）。口径与 dueToday 一致：只算已加入复习、已整理的题，
  /// 已归档的题不算（取消归档后重新计入）。
  Future<int> recheckDueCauseCount({bool includeArchived = false}) async {
    final questions = await all(includeArchived: includeArchived);
    final joined = {
      for (final q in questions)
        if (q.reviewJoined && q.isOrganized) q.id,
    };
    final records = await causeRecords();
    return records
        .where((r) => joined.contains(r.questionId) && r.isRecheckDue)
        .length;
  }

  /// B4.1：今天是否已弹过复查提醒（settings 表 key，见 database.dart）。
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
