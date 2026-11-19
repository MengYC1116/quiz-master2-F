// 十四批 M3：刷题 / 复习 / 软件内答题的纯逻辑层。
//
// 本文件不碰数据库、不碰 UI、不读当前时间以外的任何状态：
// 判定表（M3-6）、证据关联（M3-6A）、治愈规则 (d)+⑥（M3-7）、
// 选题（M3-2）、跳过（M3-9）、版本检查（M3-10）、小结汇总（M3-15）
// 全部是纯函数，逐条可单测。数据库事务见 db_questions.dart 的
// submitCauseVerdictIntoImpl / recordAttemptIntoImpl；会话状态机
// 见 state/review_notifier.dart。
//
// 三条不可妥协的边界（PLAN M3 设计基线）：
// 1. 题目是会话单位，错因是治疗单位，答题结果是证据，不是治疗命令。
// 2. 答对不等于掌握——客观正确率是证据，不能替代错因级治疗判断。
// 3. 专项练习不能污染正式复习；题目级客观结果绝不能直接复制到全部错因上。

import 'dart:convert';
import 'dart:math';

import '../models/models.dart';

/// 会话模式（review_state.mode / attempts.mode / review_history.review_mode
/// 只允许 '到期复习'——专项练习不写 review_history）。
class ReviewMode {
  static const String due = '到期复习';
  static const String practice = '专项练习';
}

/// 自查 verdict（review_history.verdict / result）。
class ReviewVerdict {
  static const String solved = '已解决';
  static const String unsolved = '未解决';
  static const String unsure = '不确定';
}

/// 核验状态 / 来源（M3-8）。
class Verification {
  static const String verified = '已核验';
  static const String unverified = '未核验';
  static const String softwareAnswer = '软件标准答案';
  static const String objectiveGrading = '客观判分';
  static const String external = '外部资料核对';
}

/// 置信度（M3-5，仅选择/判断，提交前必选）。
class Confidence {
  static const String sure = '确定';
  static const String unsure = '不太确定';
  static const String guessed = '猜的';
  static const Set<String> values = {sure, unsure, guessed};
}

/// 主观题核对确认四态（M3-4，P1-6；默认无选中，用 null 表示未选）。
class CheckConfirm {
  static const String matches = '已对照，关键答案/步骤符合';
  static const String wrong = '已对照，有错误或明显遗漏';
  static const String cannotJudge = '无法判断';
  static const String notChecked = '尚未核对';
}

/// 证据关联判断三态（M3-6A；默认无选中，用 null 表示未选）。
class EvidenceLink {
  static const String yes = '是';
  static const String no = '否';
  static const String unsure = '不确定';
}

/// 两次治愈成功之间的最小间隔（M3-7 ⑥）：24 小时。
const int cureMinIntervalMs = 24 * 60 * 60 * 1000;

/// 错因的稳定身份（review_history.cause_id）：优先用 cause_records.id；
/// 内存里未入库的记录回退为 '$questionId|$cause'。写库与查重必须用
/// 同一口径，否则同会话重复检查会漏判。
String causeStableId(CauseRecord r) =>
    r.id == null ? '${r.questionId}|${r.cause}' : '${r.id}';

/// 新会话 id / 提交 id：毫秒时间戳 + 16 位随机十六进制（与
/// models.newEntityId 同款思路；submission_id 只要求会话内唯一且
/// 跨崩溃稳定——一旦生成即存进 review_state.per_question_state，
/// 恢复重放沿用，不重新生成）。
String newReviewUuid(String prefix) {
  final r = Random.secure();
  final suffix = List.generate(4, (_) => r.nextInt(0x10000))
      .map((v) => v.toRadixString(16).padLeft(4, '0'))
      .join();
  return '$prefix-${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}-$suffix';
}

/// 子级 submission_id：由父级 question_submission_id 与错因稳定身份
/// 确定性派生（M3-10 两层提交身份）。一次按题提交三错因时三条
/// history 各用自己的子级 ID；父级 ID 只标识这次按题提交，
/// 不填入任何一条 review_history。
String childSubmissionId(String parentId, String causeStableIdValue) =>
    '$parentId::$causeStableIdValue';

// ---------------------------------------------------------------------------
// 客观判分（M3-4）
// ---------------------------------------------------------------------------

/// 本题是否具备客观判分资格：单选须标签已确认且 correct_option 属于
/// 当前标签集；判断题须 correctOption 属于固定的“正确/错误”两项，
/// 不依赖 option_labels_confirmed；待重新核对（P1-A）时一律无资格；
/// 多选/不定项永远不判分。
bool objectiveGradingAvailable(Question q) {
  if (q.answerPendingRecheck) return false;
  switch (q.questionType) {
    case 'choice_single':
      if (!q.optionLabelsConfirmed) return false;
      final labels = q.optionLabels;
      final correct = q.correctOption;
      if (labels == null || labels.isEmpty) return false;
      if (correct == null || correct.isEmpty) return false;
      return labels.contains(correct);
    case 'true_false':
      return q.correctOption == '正确' || q.correctOption == '错误';
    default:
      return false;
  }
}

/// 客观判分：返回 1 答对 / 0 答错 / null 不判分（无资格、所选标签
/// 不属于当前标签集、或未填正确答案时）。提交时校验所选标签属于
/// 当前标签集，否则拒绝判分（correct=NULL，核对区提示“选项标签异常，
/// 本次作答不判分”），不因库里存在旧 correct_option 就继续错误判分。
int? gradeObjective(Question q, String selected) {
  if (!objectiveGradingAvailable(q)) return null;
  if (q.questionType == 'choice_single') {
    if (!(q.optionLabels ?? const []).contains(selected)) return null;
  } else if (q.questionType == 'true_false') {
    if (selected != '正确' && selected != '错误') return null;
  } else {
    return null;
  }
  return selected == q.correctOption ? 1 : 0;
}

// ---------------------------------------------------------------------------
// 核验判定（M3-6 表 A/B/C + M3-6A + M3-8）
// ---------------------------------------------------------------------------

/// 一次错因自查的核验判定结果。
class VerificationOutcome {
  const VerificationOutcome({
    required this.status,
    required this.source,
    this.attemptId,
  });

  /// 已核验 / 未核验。
  final String status;

  /// 软件标准答案 / 客观判分 / 外部资料核对 / 未核验。
  final String source;

  /// 本次核验依据的 attempt id（客观判分时必填；其他来源为 null）。
  final String? attemptId;

  bool get isVerified => status == Verification.verified;
}

/// 判定一次“已解决”自查的核验来源。只在 verdict == 已解决 时调用；
/// 其他 verdict 一律返回未核验（写库时仍记一行：未解决记未核验行，
/// 不确定记中性事件行）。
///
/// 判定顺序（M3-6）：
/// 1. 客观判分可用（已确认标签且已填正确答案的单选/判断）→ 证据关联路径：
///    答对 + 信心=确定 + 关联=是 → 客观判分（attempt_id 记入）；
///    其余一律未核验（答错、猜对、低信心、关联否/不确定/未选）。
/// 2. 有软件内标准答案文本（多选/不定项/填空/计算/证明等非客观判分题，
///    或客观题未达判分条件但答案文本有效）→ 主观核对确认路径：
///    核对确认选“符合” → 软件标准答案；其余三态 → 未核验。
/// 3. 无软件内标准答案 → 外部核对路径：勾选“我已对照可靠外部资料核对”
///    → 外部资料核对；不勾选 → 未核验的自我判断。
/// 专项练习不走本函数（不写 review_history）。
VerificationOutcome resolveVerification({
  required Question question,
  required String verdict,
  int? objectiveCorrect,
  String? confidence,
  String? evidenceLink,
  String? checkConfirm,
  bool externalChecked = false,
  String? attemptId,
}) {
  const unverified = VerificationOutcome(
    status: Verification.unverified,
    source: Verification.unverified,
  );
  if (verdict != ReviewVerdict.solved) return unverified;
  if (objectiveGradingAvailable(question)) {
    // 表 A 客观题：只有答对 + 确定 + 关联=是才有客观证据可用。
    if (objectiveCorrect == 1 &&
        confidence == Confidence.sure &&
        evidenceLink == EvidenceLink.yes &&
        attemptId != null) {
      return VerificationOutcome(
        status: Verification.verified,
        source: Verification.objectiveGrading,
        attemptId: attemptId,
      );
    }
    return unverified;
  }
  if (question.hasValidStandardAnswer) {
    // 有软件答案的非客观判分题：核对确认“符合”才具备核验资格。
    if (checkConfirm == CheckConfirm.matches) {
      return const VerificationOutcome(
        status: Verification.verified,
        source: Verification.softwareAnswer,
      );
    }
    return unverified;
  }
  // 表 B 无软件内标准答案：只有勾选外部核对才计入。
  if (externalChecked) {
    return const VerificationOutcome(
      status: Verification.verified,
      source: Verification.external,
    );
  }
  return unverified;
}

// ---------------------------------------------------------------------------
// 治愈规则（M3-7：(d) 同会话重复检查 + ⑥ 24 小时锚点链）
// ---------------------------------------------------------------------------

/// 一次已核验“已解决”能否计入治愈的判定结果。
class CureEvaluation {
  const CureEvaluation({
    required this.counted,
    required this.newSolvedCount,
    required this.newStatus,
    this.newRecheckDate,
    this.newLastCountedSuccessAt,
    this.newLastCountedSessionId,
  });

  /// 本次是否计入治愈次数。
  final bool counted;

  /// 计入后的 solvedCount（不计入时保持原值）。
  final int newSolvedCount;

  /// 计入/复查后的状态。
  final CauseStatus newStatus;

  /// 治愈或复查通过后的下次复查日（未治愈时为 null）。
  final DateTime? newRecheckDate;

  /// 计入后要保存的锚点（不计入时为 null，调用方不刷新锚点）。
  final int? newLastCountedSuccessAt;
  final String? newLastCountedSessionId;
}

/// 判定一次已核验“已解决”是否计入治愈（纯函数；调用方须先完成
/// 同会话重复检查，把 [alreadySolvedInSession] 传进来——事务内按
/// cause_id + session_id 查 review_history，含第一次未核验的
/// “已解决”，不能只查已计入成功的事件）。
///
/// 规则：
/// - isRecheck（已治愈错因的复查通过）：不增加初次治愈次数，锚点不动，
///   状态保持已解决、复查日顺延。
/// - cureChecks == 1：一次有效成功直接治愈，不等待 24 小时。
/// - 首次计入（锚点为空）：计数并保存锚点。
/// - 后续：须同时满足 session 与上次计入会话不同、且距上次计入成功
///   ≥ 24 小时；计入后更新两个锚点；不足 24 小时不计数、不刷新锚点。
/// - alreadySolvedInSession（(d)）：本次只记 history，不计数、不刷新锚点。
CureEvaluation evaluateCure({
  required CauseRecord record,
  required String sessionId,
  required int nowMs,
  required int cureChecks,
  required int recheckIntervalDays,
  bool isRecheck = false,
  bool alreadySolvedInSession = false,
}) {
  final today = DateTime.fromMillisecondsSinceEpoch(nowMs);
  final todayDate = DateTime(today.year, today.month, today.day);
  final nextRecheck = todayDate.add(Duration(days: recheckIntervalDays));
  if (isRecheck) {
    // 复查通过：不增加初次治愈次数（HTML 口径），只顺延复查日。
    return CureEvaluation(
      counted: false,
      newSolvedCount: record.solvedCount,
      newStatus: CauseStatus.solved,
      newRecheckDate: nextRecheck,
    );
  }
  if (alreadySolvedInSession) {
    // (d)：同一会话内同一错因第二次“已解决”只记 history，不推进治愈。
    return CureEvaluation(
      counted: false,
      newSolvedCount: record.solvedCount,
      newStatus: record.status,
    );
  }
  bool counts;
  if (cureChecks <= 1) {
    counts = true;
  } else if (record.lastCountedSuccessAt == null ||
      record.lastCountedSessionId == null) {
    counts = true;
  } else {
    counts =
        record.lastCountedSessionId != sessionId &&
        nowMs - record.lastCountedSuccessAt! >= cureMinIntervalMs;
  }
  if (!counts) {
    return CureEvaluation(
      counted: false,
      newSolvedCount: record.solvedCount,
      newStatus: record.status,
    );
  }
  final newCount = record.solvedCount + 1;
  if (newCount >= cureChecks) {
    return CureEvaluation(
      counted: true,
      newSolvedCount: newCount,
      newStatus: CauseStatus.solved,
      newRecheckDate: nextRecheck,
      newLastCountedSuccessAt: nowMs,
      newLastCountedSessionId: sessionId,
    );
  }
  return CureEvaluation(
    counted: true,
    newSolvedCount: newCount,
    newStatus: CauseStatus.inProgress,
    newLastCountedSuccessAt: nowMs,
    newLastCountedSessionId: sessionId,
  );
}

/// “未解决”的重置（M3-7 ⑥.4）：solvedCount 清零，两个锚点清空，
/// 状态回解决中，复查日清掉。
CauseRecord unsolvedReset(CauseRecord record, DateTime now) =>
    record.copyWith(
      status: CauseStatus.inProgress,
      solvedCount: 0,
      lastCheck: now,
      clearRecheckDate: true,
      clearCountedAnchors: true,
    );

// ---------------------------------------------------------------------------
// 选题（M3-2）
// ---------------------------------------------------------------------------

/// 队列里的一道题：题 id + 本轮要处理的错因名列表。
class QueueQuestion {
  const QueueQuestion({required this.questionId, required this.causes});

  final String questionId;
  final List<String> causes;
}

DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

/// 到期复习默认池：纳入复习且未治愈的错因（pending/inProgress）全部可练；
/// 已治愈错因仅当 isRecheckDue（status=solved 且 recheckDate ≤ 今天）才可练。
/// 排序：逾期复查 → 今日到期复查 → 未解决错因按加入时间；同组内按加入时间。
/// 数量按错因数截断（limit <= 0 为不限）；同一题的本轮错因必须完整处理，
/// 会话可少量超出设置数，不为卡数字拆散同一道题。
/// 非本轮错因（未到期、已治愈未到期）不进队列，由调用方在题卡上折叠显示。
List<QueueQuestion> buildDueQueue({
  required List<CauseRecord> records,
  required Set<String> joinedQuestionIds,
  String? subjectFilter,
  String? typeFilter,
  String? causeFilter,
  required Map<String, Question> questionsById,
  int limit = 0,
  DateTime? now,
}) {
  final today = _dayOf(now ?? DateTime.now());
  final overdue = <CauseRecord>[];
  final dueToday = <CauseRecord>[];
  final unsolved = <CauseRecord>[];
  for (final r in records) {
    if (!joinedQuestionIds.contains(r.questionId)) continue;
    final q = questionsById[r.questionId];
    if (q == null || q.isArchived) continue;
    if (subjectFilter != null && q.subjectId != subjectFilter) continue;
    if (typeFilter != null && q.questionType != typeFilter) continue;
    if (causeFilter != null && r.cause != causeFilter) continue;
    if (r.status == CauseStatus.solved) {
      // 到期判定用传入的 now（不用 r.isRecheckDue——后者读系统时间，
      // 与调用方传入的 now 不一致时排序会错；生产调用传默认 now 即系统时间）。
      final d = r.recheckDate == null ? null : _dayOf(r.recheckDate!);
      if (d == null || d.isAfter(today)) continue;
      if (d.isBefore(today)) {
        overdue.add(r);
      } else {
        dueToday.add(r);
      }
    } else {
      unsolved.add(r);
    }
  }
  int byJoined(CauseRecord a, CauseRecord b) =>
      a.joinedAt.compareTo(b.joinedAt);
  int byRecheck(CauseRecord a, CauseRecord b) =>
      _dayOf(a.recheckDate!).compareTo(_dayOf(b.recheckDate!)) == 0
      ? byJoined(a, b)
      : _dayOf(a.recheckDate!).compareTo(_dayOf(b.recheckDate!));
  overdue.sort(byRecheck);
  dueToday.sort(byJoined);
  unsolved.sort(byJoined);
  final ordered = [...overdue, ...dueToday, ...unsolved];
  // 先筛错因、再按题去重成队列（一题只出现一次，携带本轮错因 id 列表）。
  final byQ = <String, List<String>>{};
  final qOrder = <String>[];
  for (final r in ordered) {
    if (!byQ.containsKey(r.questionId)) {
      byQ[r.questionId] = [];
      qOrder.add(r.questionId);
    }
    byQ[r.questionId]!.add(r.cause);
  }
  final result = <QueueQuestion>[];
  var used = 0;
  for (final qid in qOrder) {
    final causes = byQ[qid]!;
    if (limit > 0 && used >= limit) break;
    // 同一题的本轮错因必须完整处理：即使会少量超出设置数也不拆散。
    result.add(QueueQuestion(questionId: qid, causes: causes));
    used += causes.length;
  }
  return result;
}

/// 专项练习选题：范围自选（学科、题型、错因，默认全部）；可含未到期、
/// 已掌握、正在解决的题；可选取“未加入复习”的错题——只要属于错题本
/// （已整理、未归档）即可练。数量按去重后题数（count <= 0 为全部），
/// 默认 10 道；顺序默认随机（交错练习），可选加入时间。
List<QueueQuestion> buildPracticeQueue({
  required List<Question> questions,
  required Map<String, List<CauseRecord>> recordsByQ,
  String? subjectFilter,
  String? typeFilter,
  String? causeFilter,
  int count = 10,
  bool randomOrder = true,
  Random? random,
}) {
  final pool = <Question>[];
  for (final q in questions) {
    if (!q.isOrganized || q.isArchived) continue;
    if (subjectFilter != null && q.subjectId != subjectFilter) continue;
    if (typeFilter != null && q.questionType != typeFilter) continue;
    if (causeFilter != null && !q.allCauses.contains(causeFilter)) continue;
    pool.add(q);
  }
  if (randomOrder) {
    pool.shuffle(random ?? Random());
  } else {
    pool.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }
  final picked = count > 0 ? pool.take(count).toList() : pool;
  return picked
      .map(
        (q) => QueueQuestion(
          questionId: q.id,
          causes: (recordsByQ[q.id] ?? const [])
              .map((r) => r.cause)
              .toList(),
        ),
      )
      .toList();
}

// ---------------------------------------------------------------------------
// 跳过（M3-9）与版本检查（M3-10）
// ---------------------------------------------------------------------------

/// 跳过判定：按题计。队列只有一道题时第一次跳过不能马上再次出现——
/// 直接留到下一次会话；否则第一次跳过移到队尾，第二次移出本次会话。
enum SkipAction { toTail, defer }

SkipAction skipDecision({required int queueLength, required int skips}) {
  if (queueLength <= 1) return SkipAction.defer;
  return skips == 0 ? SkipAction.toTail : SkipAction.defer;
}

/// 版本变化处理（M3-10）：恢复/重遇时同时比较 answer_version 与
/// content_version。尚未实际作答 → 刷新快照从看题重新开始；
/// 已经提交作答或核对 → 保留原 attempt，移出当前会话（本版不再允许
/// 在当前会话内为已提交的 attempt 重新核对，也不覆盖历史 attempt）。
enum VersionAction { ok, refresh, remove }

VersionAction versionCheck({
  required int snapshotAnswerVersion,
  required int snapshotContentVersion,
  required int currentAnswerVersion,
  required int currentContentVersion,
  required bool hasSubmitted,
}) {
  if (snapshotAnswerVersion == currentAnswerVersion &&
      snapshotContentVersion == currentContentVersion) {
    return VersionAction.ok;
  }
  return hasSubmitted ? VersionAction.remove : VersionAction.refresh;
}

// ---------------------------------------------------------------------------
// 会话快照编解码（M3-10：review_state.skips / per_question_state）
// ---------------------------------------------------------------------------

String encodeSkips(Map<String, int> skips) => jsonEncode(skips);

Map<String, int> decodeSkips(String? raw) {
  if (raw == null || raw.isEmpty) return {};
  final decoded = jsonDecode(raw);
  if (decoded is! Map) return {};
  return decoded.map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
}

String encodePerQuestionState(
  Map<String, Map<String, Object?>> state,
) => jsonEncode(state);

Map<String, Map<String, Object?>> decodePerQuestionState(String? raw) {
  if (raw == null || raw.isEmpty) return {};
  final decoded = jsonDecode(raw);
  if (decoded is! Map) return {};
  return decoded.map(
    (k, v) => MapEntry(
      k.toString(),
      (v as Map).map((k2, v2) => MapEntry(k2.toString(), v2)),
    ),
  );
}

// ---------------------------------------------------------------------------
// 作答记录（M3-14 attempts：一题一卡，一次会话每题一条）
// ---------------------------------------------------------------------------

/// 一次实际作答（attempts 行的内存形态）。只在用户真正作答时创建；
/// 只跳过、从未作答的题不建 attempt。status 只取 已提交/已完成作答/
/// 跳过（“未作答”不在枚举内）；correct 为 null 表示无标准答案或不判分。
class AttemptData {
  const AttemptData({
    required this.id,
    required this.questionId,
    required this.sessionId,
    required this.mode,
    this.selected,
    this.correct,
    this.confidence,
    required this.answerVersion,
    required this.contentVersion,
    required this.status,
    this.causeIds = const [],
    this.durationMs,
    required this.submissionId,
    required this.createdAt,
  });

  final String id;
  final String questionId;
  final String sessionId;
  final String mode;
  final List<String>? selected;
  final int? correct;
  final String? confidence;
  final int answerVersion;
  final int contentVersion;
  final String status;
  final List<String> causeIds;
  final int? durationMs;
  final String submissionId;
  final int createdAt;

  AttemptData copyWith({
    List<String>? selected,
    bool clearSelected = false,
    int? correct,
    bool clearCorrect = false,
    String? confidence,
    bool clearConfidence = false,
    int? answerVersion,
    int? contentVersion,
    String? status,
    List<String>? causeIds,
    int? durationMs,
    bool clearDuration = false,
  }) {
    return AttemptData(
      id: id,
      questionId: questionId,
      sessionId: sessionId,
      mode: mode,
      selected: clearSelected ? null : (selected ?? this.selected),
      correct: clearCorrect ? null : (correct ?? this.correct),
      confidence: clearConfidence ? null : (confidence ?? this.confidence),
      answerVersion: answerVersion ?? this.answerVersion,
      contentVersion: contentVersion ?? this.contentVersion,
      status: status ?? this.status,
      causeIds: causeIds ?? this.causeIds,
      durationMs: clearDuration ? null : (durationMs ?? this.durationMs),
      submissionId: submissionId,
      createdAt: createdAt,
    );
  }
}

// ---------------------------------------------------------------------------
// 小结汇总（M3-15）
// ---------------------------------------------------------------------------

/// 到期复习小结的数字口径：未判分/无标准答案数量不混入答对、答错统计。
class DueSummary {
  const DueSummary({
    required this.completedQuestions,
    required this.handledCauses,
    required this.newlyCured,
    required this.recheckPassed,
    required this.recheckFailed,
    required this.unverifiedSelfCount,
    required this.ungradedCount,
    required this.skippedCount,
    required this.deferredCount,
    required this.objectiveCorrect,
    required this.objectiveWrong,
    this.nextRecheckDate,
  });

  final int completedQuestions;
  final int handledCauses;
  final int newlyCured;
  final int recheckPassed;
  final int recheckFailed;
  final int unverifiedSelfCount;
  final int ungradedCount;
  final int skippedCount;
  final int deferredCount;
  final int objectiveCorrect;
  final int objectiveWrong;
  final DateTime? nextRecheckDate;
}
