// 首页业务状态（ARCH-PLAN-A 第 2 阶段 A 路：首页）。
//
// 状态是 [HomeState]（继续上次、每学科到期数、最近考试倒计时
// 等首页业务数据），唯一真源仍是 SQLite；本 Provider 只做“响应式读取”，
// 不另存一份、不改库。
//
// - 读：`ref.watch(homeProvider)`（首页）；
// - 刷新：`ref.read(homeProvider.notifier).retry()`（读库失败后点“重试”）。
// - 拿库：经 `ref.read(repositoryProvider)`（见 D-34：与根组件的 repo
//   字段共用同一 `AppDatabase.instance` 单例库，Repository 无状态可分叉）。
//
// 页面只留 widget 与纯界面临时状态（备份失败横幅 / 读库失败横幅的
// “已关闭”标志）；问候语仍由应用层经构造器传 `settings` 进来（见
// `HomePage` 注释），不进本 Provider。角标走 `badgeCountsProvider`
//（第 4 阶段：订阅 `DataChangeBus`，见 `badge_counts_provider.dart`）。
//
// 构造器接进来的 `repo` 怎么进依赖图：`HomePage` 在 build 里包一层
// `ProviderScope(overrides: [repositoryProvider.overrideWithValue(
// widget.repo)])`——`app.dart` 仍按老样子传 `repo`，不用改；测试
// 里构造器传 FakeRepo 同样经这一层注入，不用再包一层 ProviderScope。
// 本文件不认识任何 widget，不碰 `BuildContext`、不弹 Dialog、不调导航。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/data_change_events.dart';
import '../data/repository.dart';
import '../models/exam_event.dart';
import '../models/models.dart';
import 'repository_provider.dart';
import 'review_notifier.dart';

/// 首页业务状态的 Provider：页面出现即读库（见 [HomeNotifier.build]）。
/// FR-19：声明 `dependencies: [repositoryProvider]`（D-49 同款）——
/// 未声明时 Notifier 挂到根容器，嵌套 ProviderScope 的 repo override
/// 会被静默无视；生产上默认值与根组件是同一单例库、行为零变化，
/// 补声明只锁住挂载语义 + 根 Scope + push 测试覆盖。
final homeProvider = NotifierProvider.autoDispose<HomeNotifier, HomeState>(
  HomeNotifier.new,
  dependencies: [repositoryProvider, reviewSchedulerProvider],
);

/// 十二批功能 4：最近查看时间的显示格式（纯函数，便于单测；
// 口径与 D-91 一致——同一天“今天 HH:mm”，昨天“昨天 HH:mm”，
// 其余同年“MM-dd HH:mm”、跨年“yyyy-MM-dd HH:mm”。
// 月 / 日 / 时 / 分零补齐，与库里 `yyyy-MM-dd` 的补零写法同款，
// 不引 intl）。[now] 仅供测试定“今天”，生产调用不传。
String formatRecentlyViewedTime(DateTime viewedAt, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final day = DateTime(today.year, today.month, today.day);
  final viewedDay = DateTime(viewedAt.year, viewedAt.month, viewedAt.day);
  final diffDays = day.difference(viewedDay).inDays;
  final hhmm =
      '${viewedAt.hour.toString().padLeft(2, '0')}:'
      '${viewedAt.minute.toString().padLeft(2, '0')}';
  if (diffDays == 0) return '今天 $hhmm';
  if (diffDays == 1) return '昨天 $hhmm';
  final mmdd =
      '${viewedAt.month.toString().padLeft(2, '0')}-'
      '${viewedAt.day.toString().padLeft(2, '0')}';
  if (viewedAt.year == today.year) return '$mmdd $hhmm';
  return '${viewedAt.year}-$mmdd $hhmm';
}

/// 首页业务数据（原 `_HomePageState` 里的读库字段，原样搬移，行为零变）。
class HomeState {
  const HomeState({
    this.loading = true,
    this.loadError = false,
    this.hasLoaded = false,
    this.revCounts = const {},
    this.pendingCounts = const {},
    this.subjects = const [],
    this.dueCount = 0,
    this.todayNewCount = 0,
    this.recent,
    this.nearestExam,
    this.history = const [],
  });

  /// 首查进行中（原 `_loading`；初始 true，首帧先出加载卡）。
  final bool loading;

  /// 读库失败（原 `_loadError`；SR-P2-48：失败不一直转圈，出错误横幅
  /// + 重试；已加载过内容时留住旧内容）。
  final bool loadError;

  /// 至少成功加载过一次（原 `_hasLoaded`；首次加载即失败时不显示全 0
  /// 的学科格，只留问候 + 错误横幅 + 重试）。
  final bool hasLoaded;

  /// 每学科到期数（`fsrsDueCountsBySubject`；原 `_revCounts`）。
  final Map<String, int> revCounts;

  /// 每学科待整理数（`pendingOrganizeBySubject`；原 `_pendingCounts`）。
  final Map<String, int> pendingCounts;

  /// 库里的全部学科（入库顺序；原 `_subjects`）。
  final List<Subject> subjects;

  /// FSRS 到期道数（`fsrsDueQuestionIds().length`，与复习页到期
  /// 队列、左导航复习角标同一集合；原 `_duePending` 位置）。
  final int dueCount;

  /// 今日新题道数（`previewNewRelease().todaysNewIds.length`；
  /// 原 `_dueRecheck` 位置）。
  final int todayNewCount;

  /// 最近任务（`recentTask()`；原 `_recent`）。
  final ({String kind, String subjectId, String title})? recent;

  /// 最近一场考试（B11-9；原 `_nearestExam`，无考试时为 null）。
  final ExamEvent? nearestExam;

  /// 十二批功能 4：最近查看的题（最新在前，最多 30 条；空时首页整区隐藏）。
  final List<({Question question, DateTime viewedAt})> history;

  /// 到期总数 = FSRS 到期道数（原 `_totalDue`）。
  int get totalDue => dueCount;

  /// 库里找学科：新学科用库里的名；找不到才回退 `Subject.byId`
  ///（数学兜底，只发生在数据不一致时；原 `_subjectOf`）。
  Subject subjectOf(String id) => subjects.firstWhere(
        (s) => s.id == id,
        orElse: () => Subject.byId(id),
      );

  HomeState copyWith({
    bool? loading,
    bool? loadError,
    bool? hasLoaded,
    Map<String, int>? revCounts,
    Map<String, int>? pendingCounts,
    List<Subject>? subjects,
    int? dueCount,
    int? todayNewCount,
    ({String kind, String subjectId, String title})? recent,
    ExamEvent? nearestExam,
    List<({Question question, DateTime viewedAt})>? history,
    bool clearRecent = false,
    bool clearNearestExam = false,
  }) {
    return HomeState(
      loading: loading ?? this.loading,
      loadError: loadError ?? this.loadError,
      hasLoaded: hasLoaded ?? this.hasLoaded,
      revCounts: revCounts ?? this.revCounts,
      pendingCounts: pendingCounts ?? this.pendingCounts,
      subjects: subjects ?? this.subjects,
      dueCount: dueCount ?? this.dueCount,
      todayNewCount: todayNewCount ?? this.todayNewCount,
      recent: clearRecent ? null : (recent ?? this.recent),
      nearestExam:
          clearNearestExam ? null : (nearestExam ?? this.nearestExam),
      history: history ?? this.history,
    );
  }
}

/// 首页业务逻辑（ARCH-PLAN-A 第 2 阶段：原 `_HomePageState._load` 原样
/// 搬入，只返回状态、不碰 UI）。
class HomeNotifier extends Notifier<HomeState> {
  /// 每次用都经 ref 拿：方法在 `build()` 跑完之前也能调（单测里只调
  /// 方法、不读 state 时尤其如此），且不缓存一份可能过期的 repo。
  QuestionRepository get _repo => ref.read(repositoryProvider);

  /// Provider 销毁后不再写 state（页面已卸载时读库回包不触 state）。
  bool _disposed = false;

  @override
  HomeState build() {
    // D-94：先订阅、后首查（badge_counts_provider.dart 同款）——
    // 详情页是 Navigator 压栈，首页仍挂载、autoDispose 不重建；
    // 详情打开记一次查看后发 `recentlyViewed` 事件，收到后直接调
    // `load()` 重读历史（不用 `ref.invalidateSelf`，那会把 state
    // 重置回 loading、首页闪一下加载卡）。只响应与历史相关的 kind，
    // 其余事件忽略。订阅在 Provider 销毁时取消，销毁后不再接收事件。
    final subscription = DataChangeBus.instance.stream.listen((event) {
      if (event.kinds.contains(DataChangeKind.recentlyViewed)) {
        // load() 自己有 try/catch：订阅回调异常不反噬到事件发布方
        //（记录查看的写库侧），重读失败只翻 loadError、旧内容留住。
        unawaited(load());
      }
    });
    ref.onDispose(subscription.cancel);
    ref.onDispose(() => _disposed = true);
    // 页面出现即读库（原 `initState` 的 `_load`）：不 await，
    // 读完后 state 一次性赋值，首帧先出加载卡。
    Future.microtask(load);
    return const HomeState();
  }

  /// 读库（FSRS 口径，2026-11-25 口径迁移 §2.1）：
  /// - 到期数与导航速览同一口径（`fsrsDueCountsBySubject` /
  ///   `fsrsDueQuestionIds`：池里已开始正式复习且 `next_due_at <= now`
  ///   的题；未开始的新卡不算到期，算今日新题 / 待开始）；
  /// - 今日新题数复用 `previewNewRelease()`（要 `dailyNewLimit`
  ///   设置值，故 `load()` 多读一次 `settings()`；释放计划只做展示）；
  /// - 学科格按库里的 subjects 表显示全部学科（入库顺序），不再写死
  ///   Subject.all 三科（B2；空表是删光学科后的合法状态，不回退预设三科）。
  /// 成功时整份 state 一次性替换；失败时只翻 `loadError`，旧内容留住。
  Future<void> load() async {
    // D-42：build() 的 microtask 首查可能在页面已离开、Provider 已销毁后
    // 才跑——先判 _disposed 再碰 ref；repo / scheduler 入口处捕获一次，
    // 之后不再 ref.read，中途销毁也不抛错（收集页同款，见 D-42）。
    if (_disposed) return;
    final repo = _repo;
    final scheduler = ref.read(reviewSchedulerProvider);
    try {
      final results = await Future.wait([
        repo.fsrsDueCountsBySubject(scheduler: scheduler),
        repo.pendingOrganizeBySubject(),
        repo.recentTask(),
        repo.subjects(),
        // B11-9：考试事件列表（首页只取最近一场做倒计时）。
        repo.examEvents(),
        // 十二批功能 4：最近查看的题（最新在前，最多 30 条）。
        repo.recentlyViewedQuestions(),
        // FSRS 今日新题要每日上限设置值（previewNewRelease 用）。
        repo.settings(),
      ]);
      if (_disposed) return;
      final settings = results[6] as AppSettings;
      final plan = await repo.previewNewRelease(
        scheduler: scheduler,
        dailyNewLimit: settings.dailyNewQuestions,
      );
      if (_disposed) return;
      final revCounts = results[0] as Map<String, int>;
      state = HomeState(
        loading: false,
        loadError: false,
        hasLoaded: true,
        revCounts: revCounts,
        pendingCounts: results[1] as Map<String, int>,
        recent: results[2] as ({String kind, String subjectId, String title})?,
        dueCount: revCounts.values.fold<int>(0, (a, b) => a + b),
        todayNewCount: plan.todaysNewIds.length,
        subjects: results[3] as List<Subject>,
        nearestExam: nearestExamEvent(results[4] as List<ExamEvent>),
        history:
            results[5] as List<({Question question, DateTime viewedAt})>,
      );
    } catch (_) {
      // 读库失败：不一直转圈（SR-P2-48），出错误横幅 + 重试入口。
      if (_disposed) return;
      state = state.copyWith(loading: false, loadError: true);
    }
  }

  /// 读库失败后点“重试”（原 `_retryLoad`）：先回到加载态、清掉错误横幅，
  /// 再重读一次；重读失败时 `load()` 的 catch 重新翻起 `loadError`。
  Future<void> retry() async {
    if (_disposed) return;
    state = state.copyWith(loading: true, loadError: false);
    await load();
  }
}
