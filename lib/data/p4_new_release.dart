// P4：新题释放 + 积压控制（实施方案 v2 §6，GPT 第六轮补充第 1、2 项）。
//
// 本文件只放不碰数据库、不碰 UI 的纯函数与小记录类，逐条可单测：
// - 三个状态分开：已加入复习池 / 已释放新题 / 已完成首次正式作答；
// - 每日新增按“每天首次呈现的新题数量”计（不按点加入按钮的次数计），
//   默认每天释放 10 道，上限 50（设置项 dailyNewQuestions）；
// - 未完成新题积压上限：待完成新题达到上限暂停释放额外新题；上限默认
//   10 道（= 默认每日上限），每日上限调高时跟调高（见
//   kPendingNewBacklogLimit 注释，否则 50 档永远放不出来）；
// - 新卡不算到期：到期队列只认 firstReviewedAt 非空的卡（P1 已在
//   getDueQuestions 里隔离），这里只做列表层的区分显示与释放计划。
//
// ── 旧写入层评估（P4 结论：保留，不移除；2026-11-26 口径迁移第二批复核：仍不删） ──
// submitCauseVerdictIntoImpl / recordSelfCheckIntoImpl /
// hasSessionVerdictIntoImpl / CureEvaluation / evaluateCure /
// settings.cureChecks / recheckIntervalDays /
// cause_records.solvedCount / recheckDate 的 live 口径已全部迁到 FSRS
// （首页/角标/报告/封面/复习列表分组/详情页，2026-11-25～26 两批）；
// 旧 writer 的产品调用方仍是零（P2 起流程不再调用），只剩旧写入层
// 测试（b14_m3_verdict_test 等）在覆盖它们。删 writer 会把旧记录
// 永远冻在 pending，而迁移审计要靠这套语义解读旧历史；删字段须
// schema v9 + 备份恢复同步改。settings 的 cureChecks /
// recheckIntervalDays 已在设置页隐藏（第一批 8(a)）。
// ────────────────────────────────────────────────────────────────
//
// 口径（与 planNewRelease 的字段一一对应）：
// - 待释放新题（pending）：在池里、firstReviewedAt 为空、未归档；
// - 已呈现（presented）：待释放新题里 firstPresentedAt 非空的，
//   即已释放未完成；“待完成新题”= 已呈现的题数（积压口径）；
// - 今日已呈现（presentedToday）：已呈现且 firstPresentedLocalDate
//   == 今天本地日期；
// - 昨日遗留续接（carryover）：已呈现且首次呈现日期不是今天；
//   续接不重耗今日额度，但占积压位（昨日遗留 8 道，今日最多再呈现 2 道）；
// - 新释放（newlyReleasable）：尚未呈现过的题，按加入顺序（cardId）
//   取，数量 = min(今日剩余额度，每日上限 − 今日已呈现，积压空位)；
// - 待开始（waiting）：尚未呈现、今天没轮到的题，列表上标“待开始”，
//   不混入到期题。
// - 已开始正式复习的题（firstReviewedAt 非空）永远不再算新题。
// - 日期口径：每日按本地日历日期切（调用方传今天的本地日期字符串），
//   时间戳统一存 UTC（recordFirstPresented 的 presentedAtUtc）。
import 'review_scheduler.dart';

/// 默认每天释放的新题数（D5：50 是上限，默认每天释放 10 道）。
const int kDailyNewDefault = 10;

/// 每日新增上限（D5：最高 50 道）。
const int kDailyNewMax = 50;

/// 待完成新题积压上限的默认值（第六轮补充第 2 项）：达到 10 道暂停释放。
///
/// 注意它不是固定 10：积压上限跟随每日上限走——上限 = max(10, 每日上限)。
/// 若固定 10，设置里的 50 档永远放不出来（空积压时一天也只能放 10 道），
/// 与验收 §10-4“设置改上限 50 后每天最多放 50 道”直接矛盾。
/// 默认每日上限 10 时上限就是 10（昨日遗留 8 道 → 今日最多再呈现 2 道）；
/// 每日上限调到 50 时上限跟到 50；每日上限调到 5 时上限仍守 10 的底线
///（当日呈现仍受 5 道的每日上限管）。
const int kPendingNewBacklogLimit = 10;

/// 每日新增数归一：非法/越界值夹到 1..50（设置里只有 5/10/20/50 四档，
/// 旧库或手写值越界时不炸、只夹住；0 表示“今天不放新题”时也按 1 计——
/// 0 道会让新题永远进不来，与“默认每天释放”冲突，调用方真想停放
/// 应走归档/取消加入，而不是把上限写 0）。
int clampDailyNewLimit(int value) {
  if (value < 1) return 1;
  if (value > kDailyNewMax) return kDailyNewMax;
  return value;
}

/// 本地日期字符串 `yyyy-MM-dd`（按设备本地日历日算；每日额度按它切）。
String localDateString(DateTime local) =>
    '${local.year.toString().padLeft(4, '0')}-'
    '${local.month.toString().padLeft(2, '0')}-'
    '${local.day.toString().padLeft(2, '0')}';

/// 一次新题释放计划（纯计算，不写库；写首次呈现由调用方按
/// [newlyReleasableIds] 逐题调 recordFirstPresented）。
class FsrsReleasePlan {
  const FsrsReleasePlan({
    required this.todaysNewIds,
    required this.newlyReleasableIds,
    required this.carryoverIds,
    required this.presentedTodayIds,
    required this.waitingIds,
    required this.presentedTodayCount,
    required this.pendingBacklogCount,
    required this.dailyLimit,
    required this.releaseAllowance,
  });

  /// 今天可练的新题：昨日遗留续接 + 今日已呈现 + 今天新释放，
  /// 续接在前（优先续接），其余按加入顺序。
  final List<String> todaysNewIds;

  /// 今天还可新释放的题（尚未呈现过，本次计划内轮到的）；
  /// 调用方在题目首次显示时逐题记首次呈现，记完即进 todaysNewIds。
  /// 未显示的题不记，下次计划仍在可释放范围内（不提前耗额度）。
  final List<String> newlyReleasableIds;

  /// 昨日遗留续接：已呈现、未完成、首次呈现日期不是今天。
  final List<String> carryoverIds;

  /// 今日已呈现：已呈现、首次呈现日期就是今天（已耗今日额度）。
  final List<String> presentedTodayIds;

  /// 待开始：尚未呈现、今天没轮到的题（排队，不进到期队列）。
  final List<String> waitingIds;

  /// 今日已呈现的新题数（今日额度已用）。
  final int presentedTodayCount;

  /// 待完成新题数（已呈现未完成 = 积压）；满 10 道暂停释放。
  final int pendingBacklogCount;

  /// 本次计划用的每日上限（已归一到 1..50）。
  final int dailyLimit;

  /// 本次可新释放的道数（今日剩余额度与积压空位取小）。
  final int releaseAllowance;

  /// 今天还有没有可释放的新题位。
  bool get canReleaseMore => releaseAllowance > 0;
}

/// 新题释放计划（纯函数，见文件头口径）。
///
/// - [cards]：池里全部卡片（调用方已按 [ReviewScheduler.loadAllCards]
///   取到；含已开始正式复习的卡——它们直接排除，不参与释放）；
/// - [archivedIds]：已归档题 id（归档题保留卡片，但不进新题/到期队列，
///   见 activePoolIds 同款过滤）；
/// - [dailyNewLimit]：当日上限（设置值，归一到 1..50）；
/// - [todayLocalDate]：今天本地日期 `yyyy-MM-dd`。
FsrsReleasePlan planNewRelease({
  required List<StoredCard> cards,
  required Set<String> archivedIds,
  required int dailyNewLimit,
  required String todayLocalDate,
}) {
  final limit = clampDailyNewLimit(dailyNewLimit);
  // 待释放新题：未开始正式复习 + 未归档，按加入顺序（cardId）。
  final pending = cards
      .where(
        (c) => c.firstReviewedAt == null && !archivedIds.contains(c.questionId),
      )
      .toList()
    ..sort((a, b) => a.cardId.compareTo(b.cardId));
  final presented = <StoredCard>[];
  final unpresented = <StoredCard>[];
  for (final c in pending) {
    if (c.firstPresentedAt != null) {
      presented.add(c);
    } else {
      unpresented.add(c);
    }
  }
  final presentedToday = presented
      .where((c) => c.firstPresentedLocalDate == todayLocalDate)
      .toList();
  final carryover = presented
      .where((c) => c.firstPresentedLocalDate != todayLocalDate)
      .toList();
  final backlog = presented.length;
  // 今日还可新释放 = 今日剩余额度与积压空位取小（两者任一耗尽即停）。
  // 积压上限跟随每日上限（见 kPendingNewBacklogLimit 注释）：默认
  // 每日上限 10 时上限就是 10；上限调高时跟调高，否则 50 档放不出来。
  final backlogCeiling = limit < kPendingNewBacklogLimit
      ? kPendingNewBacklogLimit
      : limit;
  final allowance = [
    limit - presentedToday.length,
    backlogCeiling - backlog,
  ].reduce((a, b) => a < b ? a : b).clamp(0, limit);
  final newlyReleasable = unpresented
      .take(allowance)
      .map((c) => c.questionId)
      .toList();
  final waiting = unpresented
      .skip(allowance)
      .map((c) => c.questionId)
      .toList();
  return FsrsReleasePlan(
    todaysNewIds: [
      for (final c in carryover) c.questionId,
      for (final c in presentedToday) c.questionId,
      ...newlyReleasable,
    ],
    newlyReleasableIds: newlyReleasable,
    carryoverIds: [for (final c in carryover) c.questionId],
    presentedTodayIds: [for (final c in presentedToday) c.questionId],
    waitingIds: waiting,
    presentedTodayCount: presentedToday.length,
    pendingBacklogCount: backlog,
    dailyLimit: limit,
    releaseAllowance: allowance,
  );
}

/// 列表行上的 FSRS 状态标（到期题与新题区分显示，P4 §6）：
/// - 在到期队列里 → '到期'；在今日新题里 → '今日新题'；
/// - 在待开始里 → '待开始'；都不在 → null（不在 FSRS 池里，
///   或已掌握未到期，按旧列表分组显示，不另标）。
/// 到期优先于新题（同一题不可能同时在两个队列里，防御性排序）。
String? fsrsListLabel({
  required String questionId,
  required Set<String> dueIds,
  required Set<String> todaysNewIds,
  required Set<String> waitingIds,
}) {
  if (dueIds.contains(questionId)) return '到期';
  if (todaysNewIds.contains(questionId)) return '今日新题';
  if (waitingIds.contains(questionId)) return '待开始';
  return null;
}
