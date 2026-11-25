// 刷题 / 复习 / 软件内答题的纯逻辑层（P2 简化基线，D2）。
//
// 本文件不碰数据库、不碰 UI、不读当前时间以外的任何状态：
// 判定表（M3-6）、选题（M3-2）、跳过（M3-9）、版本检查（M3-10）
// 全部是纯函数，逐条可单测。数据库事务见 db_questions.dart 的
// recordAttemptIntoImpl；会话状态机见 state/review_notifier.dart。
//
// P2（2026-11-25）：三步流程（看题/作答/核对），无置信度、无错因
// 自查、无治愈判定、无核验。掌握与否由用户自己判断；软件只做
// 安排间隔（FSRS，见 review_scheduler.dart）、记录对错事实、
// 展示薄弱点。已删除：Confidence / CheckConfirm / EvidenceLink /
// resolveVerification / DueSummary。CureEvaluation / evaluateCure
// 移入 db_questions.dart，仅供旧 review_history 写入层保留。
// ReviewVerdict / Verification / unsolvedReset / childSubmissionId
// 仅供旧 review_history 写入层（db_questions.dart）与历史测试保留，
// P2 起产品流程不再调用，P5 决定是否移除。
//
// 两条不可妥协的边界（PLAN M3 设计基线）：
// 1. 题目是会话单位，答题结果是客观对错事实，不是治疗命令。
// 2. 专项练习不能污染正式复习；正式复习的对错事实只记一次。

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

/// 本题是否具备客观判分资格（WP-A #1，REV5 R1-3）：单选/判断须
/// [Question.answerConfigValid]（结构完整、内部一致）且未待重新核对；
/// 多选/不定项永远不判分。不再读 `optionLabelsConfirmed` 列——该列
/// 保留（v5 不动），旧值不再产生任何效果。
bool objectiveGradingAvailable(Question q) {
  if (q.answerPendingRecheck) return false;
  switch (q.questionType) {
    case 'choice_single':
    case 'true_false':
      return q.answerConfigValid;
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

/// “未解决”的重置（旧写入层用，P2 起产品流程不再调用）：
/// solvedCount 清零，两个锚点清空，状态回解决中，复查日清掉。
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
/// 跳过（“未作答”不在枚举内）；correct 为 null 表示无标准答案或不判分
/// （P2：未判分绝不写成 false）。confidence 列保留读旧值，P2 起新
/// 流程不再采集，写库时一律为 null。
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
