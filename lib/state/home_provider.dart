// 首页业务状态（ARCH-PLAN-A 第 2 阶段 A 路：首页）。
//
// 状态是 [HomeState]（继续上次、每学科待复习/待复查数、最近考试倒计时
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
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repository.dart';
import '../models/exam_event.dart';
import '../models/models.dart';
import 'repository_provider.dart';

/// 首页业务状态的 Provider：页面出现即读库（见 [HomeNotifier.build]）。
final homeProvider = NotifierProvider.autoDispose<HomeNotifier, HomeState>(
  HomeNotifier.new,
);

/// 首页业务数据（原 `_HomePageState` 里的读库字段，原样搬移，行为零变）。
class HomeState {
  const HomeState({
    this.loading = true,
    this.loadError = false,
    this.hasLoaded = false,
    this.revCounts = const {},
    this.pendingCounts = const {},
    this.subjects = const [],
    this.duePending = 0,
    this.dueRecheck = 0,
    this.recent,
    this.nearestExam,
  });

  /// 首查进行中（原 `_loading`；初始 true，首帧先出加载卡）。
  final bool loading;

  /// 读库失败（原 `_loadError`；SR-P2-48：失败不一直转圈，出错误横幅
  /// + 重试；已加载过内容时留住旧内容）。
  final bool loadError;

  /// 至少成功加载过一次（原 `_hasLoaded`；首次加载即失败时不显示全 0
  /// 的学科格，只留问候 + 错误横幅 + 重试）。
  final bool hasLoaded;

  /// 每学科要复习数（`homeRevCounts`；原 `_revCounts`）。
  final Map<String, int> revCounts;

  /// 每学科待整理数（`pendingOrganizeBySubject`；原 `_pendingCounts`）。
  final Map<String, int> pendingCounts;

  /// 库里的全部学科（入库顺序；原 `_subjects`）。
  final List<Subject> subjects;

  /// 要复习拆分：待解决道数（原 `_duePending`）。
  final int duePending;

  /// 要复习拆分：复查道数（原 `_dueRecheck`）。
  final int dueRecheck;

  /// 最近任务（`recentTask()`；原 `_recent`）。
  final ({String kind, String subjectId, String title})? recent;

  /// 最近一场考试（B11-9；原 `_nearestExam`，无考试时为 null）。
  final ExamEvent? nearestExam;

  /// 要复习总数 = 待解决 + 复查（原 `_totalDue`）。
  int get totalDue => duePending + dueRecheck;

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
    int? duePending,
    int? dueRecheck,
    ({String kind, String subjectId, String title})? recent,
    ExamEvent? nearestExam,
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
      duePending: duePending ?? this.duePending,
      dueRecheck: dueRecheck ?? this.dueRecheck,
      recent: clearRecent ? null : (recent ?? this.recent),
      nearestExam:
          clearNearestExam ? null : (nearestExam ?? this.nearestExam),
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
    ref.onDispose(() => _disposed = true);
    // 页面出现即读库（原 `initState` 的 `_load`）：不 await，
    // 读完后 state 一次性赋值，首帧先出加载卡。
    Future.microtask(load);
    return const HomeState();
  }

  /// 读库（原 `_load` 的 `Future.wait` 7 路 + 待解决/复查拆分，原样搬移）：
  /// - 要复习数与导航速览同一口径（`homeRevCounts` / `dueToday`：手动加入
  ///   复习且已整理且至少一个错因未解决或已到复查时间，数题不数错因）；
  /// - 待解决 / 复查拆分按 `QuestionRepository.reviewBucketOf`，
  ///   与错题本封面三数同一口径（SR-P1-1），本页不再各自定义；
  /// - 学科格按库里的 subjects 表显示全部学科（入库顺序），不再写死
  ///   Subject.all 三科（B2；空表是删光学科后的合法状态，不回退预设三科）。
  /// 成功时整份 state 一次性替换；失败时只翻 `loadError`，旧内容留住。
  Future<void> load() async {
    // D-42：build() 的 microtask 首查可能在页面已离开、Provider 已销毁后
    // 才跑——先判 _disposed 再碰 ref；repo 入口处捕获一次，之后不再 ref.read，
    // 中途销毁也不抛错（收集页同款，见 D-42）。
    if (_disposed) return;
    final repo = _repo;
    try {
      final results = await Future.wait([
        repo.homeRevCounts(),
        repo.pendingOrganizeBySubject(),
        repo.recentTask(),
        repo.dueToday(),
        repo.causeRecords(),
        repo.subjects(),
        // B11-9：考试事件列表（首页只取最近一场做倒计时）。
        repo.examEvents(),
      ]);
      if (_disposed) return;
      final due = results[3] as List<Question>;
      final records = results[4] as List<CauseRecord>;
      final byQ = <String, List<CauseRecord>>{};
      for (final r in records) {
        (byQ[r.questionId] ??= []).add(r);
      }
      // 待解决 / 复查拆分：有未解决错因的题计待解决；只有复查到期的题计
      // 复查；两者之和 = 要复习总数。dueToday 只返回 pending / recheck
      // 两类；防御性分支，万一混入也不计入总数。
      var pending = 0;
      var recheck = 0;
      for (final q in due) {
        final rs = byQ[q.id] ?? const <CauseRecord>[];
        switch (QuestionRepository.reviewBucketOf(rs)) {
          case ReviewBucket.pending:
            pending++;
          case ReviewBucket.recheck:
            recheck++;
          case ReviewBucket.solved:
          case ReviewBucket.none:
            break;
        }
      }
      state = HomeState(
        loading: false,
        loadError: false,
        hasLoaded: true,
        revCounts: results[0] as Map<String, int>,
        pendingCounts: results[1] as Map<String, int>,
        recent: results[2] as ({String kind, String subjectId, String title})?,
        duePending: pending,
        dueRecheck: recheck,
        subjects: results[5] as List<Subject>,
        nearestExam: nearestExamEvent(results[6] as List<ExamEvent>),
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
