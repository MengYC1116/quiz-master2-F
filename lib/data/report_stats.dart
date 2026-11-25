// 学习报告聚合（FSRS 口径迁移，方案 §2.4）：纯函数。
//
// 只读 attempts 对错事实 + 题目集合，不碰数据库、不碰 UI、不读当前时间
// 以外任何状态（范围起点由调用方按本周/本月/全部算好传进来），逐条可单测。
//
// 口径（Meng 2026-11-25 定，§5 全部按建议）：
// - 核心数 1「正式复习答对」：范围内正式复习（mode = 到期复习）答对的
//   作答次数（correct == 1），单位是“次”；专项练习不计。
// - 核心数 2「正式复习答错」：范围内正式答错的题数，按 questionId 去重，
//   单位是“题”；同一题多次答错只算 1 道。
// - 核心数 3「正式复习答对率」：范围内正式复习已判分作答里答对的占比，
//   correct == null（未判分）不计入分母；无已判分记录时为 null。
//   这是客观答对率，与旧的自查通过率（review_history）不是同一回事。
// - 弱点 Top 5 按错因：范围内正式答错的 attempts 按 questionId 去重后，
//   按该题 attempt 的 cause_ids（错因文本，新流程核对时写入）展开计数，
//   单位是“题数”；同一题多个错因时一题多计（与旧口径一致）。
//   同一题多次答错时只取最早一次答错的 attempt 的 cause_ids 展开
//   （去重后每题只归因一次，原因文本以首次答错为准）。
// - 弱点 Top 5 按知识点：题目集合口径——questionsInRange 的题按
//   knowledgePointIds 分组、按题数排；D-259：软件不判定掌握，
//   不再以 isMastered / reviewBucketOf == solved 排除任何题，
//   也不再按 cause_records 的已解决状态排除题。
// - 按学科分布：各科在范围内有正式作答的题数（attempts 按 questionId
//   去重后 JOIN 学科）；未判分作答也算作答。
// - 范围过滤一律按 attempts.created_at（转 DateTime 后与 rangeStart
//   比较）；questionsInRange 按题目 createdAt 过滤；rangeStart 为 null
//   即“全部”，不按日期过滤。
// - 题目查不到的 attempt（如题已删）：核心数照常计入（它是对错事实），
//   但无法归属学科/错因组/分布，那三处跳过。
import 'review_engine.dart';
import '../models/models.dart';

/// 一组弱点（学科 × 错因，或学科 × 知识点）的纯数据形态。
class ReportWeakGroupData {
  ReportWeakGroupData({
    required this.subjectId,
    required this.key,
    Set<String>? questionIds,
    List<String>? titles,
  })  : questionIds = questionIds ?? <String>{},
        titles = titles ?? <String>[];

  /// 学科 id。
  final String subjectId;

  /// 错因文本，或知识点 id。
  final String key;

  /// 计数的题 id 集合：题名不唯一，同名不同题各算 1 道。
  final Set<String> questionIds;

  /// 组内题名（展示行拼接用，与 questionIds 一一对应）。
  final List<String> titles;

  int get count => questionIds.length;
}

/// 报告聚合的全部输出（三个核心数 + 两组 Top 5 + 分布）。
class ReportStats {
  const ReportStats({
    required this.formalCorrectCount,
    required this.formalWrongQuestionCount,
    required this.gradedFormalCount,
    required this.gradedFormalCorrectCount,
    required this.passRate,
    required this.causeGroups,
    required this.kpGroups,
    required this.answeredBySubject,
  });

  /// 核心数 1：范围内正式复习答对的作答次数（单位“次”）。
  final int formalCorrectCount;

  /// 核心数 2：范围内正式答错的题数（按 questionId 去重，单位“题”）。
  final int formalWrongQuestionCount;

  /// 范围内正式复习已判分作答次数（分母）。
  final int gradedFormalCount;

  /// 其中答对次数（分子）。
  final int gradedFormalCorrectCount;

  /// 核心数 3：正式复习答对率（百分比取整；无已判分记录时为 null）。
  final int? passRate;

  /// 弱点 Top 5 按错因（全量，已按题数倒序、学科顺序、错因文本排好）。
  final List<ReportWeakGroupData> causeGroups;

  /// 弱点 Top 5 按知识点（全量，已按题数倒序、学科顺序、知识点名排好）。
  final List<ReportWeakGroupData> kpGroups;

  /// 按学科分布：学科 id → 范围内有正式作答的题数（按题去重）。
  final Map<String, int> answeredBySubject;
}

/// 所选范围内收集的题目（新口径）：只收已整理、未归档的题；`all`
///（rangeStart 为 null）不按日期过滤，否则按题目 createdAt 在范围内。
/// D-259：不再以“已掌握”排除任何题。
List<Question> reportQuestionsInRange({
  required List<Question> questions,
  required DateTime? rangeStart,
}) {
  final inScope =
      questions.where((q) => q.isOrganized && !q.isArchived).toList();
  if (rangeStart == null) return inScope;
  return inScope.where((q) => !q.createdAt.isBefore(rangeStart)).toList();
}

/// 报告聚合（纯函数）：输入 attempts + 题目 + 知识点，输出 [ReportStats]。
ReportStats computeReportStats({
  required List<AttemptData> attempts,
  required List<Question> questions,
  required List<KnowledgePoint> knowledgePoints,
  required List<String> subjectIdsInOrder,
  required DateTime? rangeStart,
}) {
  bool inRangeMs(int createdAtMs) {
    if (rangeStart == null) return true;
    return !DateTime.fromMillisecondsSinceEpoch(
      createdAtMs,
    ).isBefore(rangeStart);
  }

  int subjectOrder(String subjectId) {
    final i = subjectIdsInOrder.indexOf(subjectId);
    return i < 0 ? 99 : i;
  }

  final questionsById = {for (final q in questions) q.id: q};
  final kpNames = {for (final kp in knowledgePoints) kp.id: kp.name};
  final knownKpIds = kpNames.keys.toSet();

  // 范围内正式复习作答（mode = 到期复习）。
  final formal = attempts
      .where((a) => a.mode == ReviewMode.due && inRangeMs(a.createdAt))
      .toList();

  final graded = formal.where((a) => a.correct != null).toList();
  final gradedCorrect = graded.where((a) => a.correct == 1).length;
  final wrongQuestionIds = {
    for (final a in formal)
      if (a.correct == 0) a.questionId,
  };

  // 弱点按错因：正式答错的 attempts 按题去重（同一题只取最早一次答错），
  // 再按该 attempt 的 cause_ids（错因文本）展开计数。
  final wrongAttempts = formal.where((a) => a.correct == 0).toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  final seenWrong = <String>{};
  final causeGroupsMap = <String, ReportWeakGroupData>{};
  final causeOrder = <String>[];
  for (final a in wrongAttempts) {
    if (!seenWrong.add(a.questionId)) continue;
    final q = questionsById[a.questionId];
    if (q == null) continue;
    for (final cause in {...a.causeIds}) {
      final key = '${q.subjectId}|$cause';
      var g = causeGroupsMap[key];
      if (g == null) {
        g = ReportWeakGroupData(subjectId: q.subjectId, key: cause);
        causeGroupsMap[key] = g;
        causeOrder.add(key);
      }
      if (g.questionIds.add(q.id)) g.titles.add(q.title);
    }
  }
  final causeGroups = causeOrder.map((k) => causeGroupsMap[k]!).toList()
    ..sort((a, b) {
      final c = b.count.compareTo(a.count);
      if (c != 0) return c;
      final s = subjectOrder(a.subjectId) - subjectOrder(b.subjectId);
      return s != 0 ? s : a.key.compareTo(b.key);
    });

  // 弱点按知识点：题目集合口径（questionsInRange），按知识点分组、按题数排。
  // 无错因的题不进组（与旧逻辑一致）；未知知识点跳过。
  final qsIn = reportQuestionsInRange(
    questions: questions,
    rangeStart: rangeStart,
  );
  final kpGroupsMap = <String, ReportWeakGroupData>{};
  final kpOrder = <String>[];
  for (final q in qsIn) {
    if (q.allCauses.isEmpty) continue;
    for (final kpId in q.knowledgePointIds) {
      if (!knownKpIds.contains(kpId)) continue;
      final key = '${q.subjectId}|$kpId';
      var g = kpGroupsMap[key];
      if (g == null) {
        g = ReportWeakGroupData(subjectId: q.subjectId, key: kpId);
        kpGroupsMap[key] = g;
        kpOrder.add(key);
      }
      if (g.questionIds.add(q.id)) g.titles.add(q.title);
    }
  }
  final kpGroups = kpOrder.map((k) => kpGroupsMap[k]!).toList()
    ..sort((a, b) {
      final c = b.count.compareTo(a.count);
      if (c != 0) return c;
      final s = subjectOrder(a.subjectId) - subjectOrder(b.subjectId);
      if (s != 0) return s;
      return (kpNames[a.key] ?? a.key).compareTo(kpNames[b.key] ?? b.key);
    });

  // 按学科分布：范围内有正式作答的题数（按题去重；未判分也算作答）。
  final answeredBySubject = <String, int>{};
  final answeredIds = {for (final a in formal) a.questionId};
  for (final qid in answeredIds) {
    final q = questionsById[qid];
    if (q == null) continue;
    answeredBySubject[q.subjectId] =
        (answeredBySubject[q.subjectId] ?? 0) + 1;
  }

  return ReportStats(
    formalCorrectCount: formal.where((a) => a.correct == 1).length,
    formalWrongQuestionCount: wrongQuestionIds.length,
    gradedFormalCount: graded.length,
    gradedFormalCorrectCount: gradedCorrect,
    passRate: graded.isEmpty
        ? null
        : (gradedCorrect * 100 / graded.length).round(),
    causeGroups: causeGroups,
    kpGroups: kpGroups,
    answeredBySubject: answeredBySubject,
  );
}
