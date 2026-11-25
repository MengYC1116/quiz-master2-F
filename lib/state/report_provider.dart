// 学习报告业务状态（ARCH-PLAN-A 第 2 阶段 A 路：学习报告）。
//
// 状态是 [ReportState]（时间范围、三个核心数、弱点 Top 5、按学科分布、
// “接下来练什么”一句的全部读库数据 + 派生计算），唯一真源仍是 SQLite；
// 本 Provider 只做“响应式读取 + 范围选择”，不另存一份、不改库。
//
// - 读：`ref.watch(reportProvider)`（学习报告页）；
// - 切范围：`ref.read(reportProvider.notifier).setRange(v)`
//   （本周/本月/全部；数据已全量读进 state，切范围只重算派生值，不重读库）。
// - 拿库：经 `ref.read(repositoryProvider)`（见 D-34：与根组件的 repo
//   字段共用同一 `AppDatabase.instance` 单例库，Repository 无状态可分叉）。
//
// 页面只留 widget 与纯界面临时状态（读库失败横幅的“已关闭”标志、
// 两组弱点“看更多”的展开/收起）；点弱点行进错题本、去复习等导航仍是
// 页面的回调。角标走 `badgeCountsProvider`（第 4 阶段：订阅
// `DataChangeBus`，见 `badge_counts_provider.dart`）。
//
// 构造器接进来的 `repo` 怎么进依赖图：`ReportPage` 在 build 里包一层
// `ProviderScope(overrides: [repositoryProvider.overrideWithValue(
// widget.repo)])`——`app.dart` 仍按老样子传 `repo`，不用改；测试
// 里构造器传 FakeRepo 同样经这一层注入，不用再包一层 ProviderScope。
// 本文件不认识任何 widget，不碰 `BuildContext`、不弹 Dialog、不调导航。
//
// 口径（原页内注释，原样搬移，本文件不改口径）：
// - 三个核心数按同一时间范围（本周/本月/全部）过滤：已解决按 `lastCheck`
//   在范围内计；待解决同样按 `lastCheck` 在范围内计（S8 B1，Meng
//   2026-11-13 裁决）；复查通过率按范围内已判定的自查记录计（`review_history`
//   无复查备注字段，以全部已判定记录为近似）。
// - `lastCheck` 是近似代理：从未自查的错因 `lastCheck` 为空，与已解决数
//   同一分支，视为在范围内、计入所有范围。
// - 弱点与学科分布按所选范围内收集的题目算（以题目 `createdAt` 为收集日期），
//   只收已整理未归档且未掌握的题，与错题本列表默认收录口径一致
//   （SR-P1-11：未整理题、已归档题不算进来；SR2-29：已掌握题不算进来，
//   分布数 = 该科封面总数）：错因行只含未解决的错因，无记录的错因默认待解决；
//   知识点行排除全部错因已解决的题。弱点计数按题 id，不按题名去重
//   （SR-P1-10：题名不唯一，同名不同题各算 1 道）。
// - 已掌握的定义与错题本 / 首页同一口径：按该题现存的全部错因记录算
//   `QuestionRepository.reviewBucketOf(records) == ReviewBucket.solved`
//   （SR3-2），不按当前错因逐因查记录。
// - 本周 = 本周一到今天（基线口径）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repository.dart';
import '../data/review_engine.dart';
import '../models/models.dart';
import 'repository_provider.dart';

/// 学习报告业务状态的 Provider：页面出现即读库（见 [ReportNotifier.build]）。
/// FR-19：声明 `dependencies: [repositoryProvider]`（D-49 同款，见
/// homeProvider 注释）。
final reportProvider =
    NotifierProvider.autoDispose<ReportNotifier, ReportState>(
  ReportNotifier.new,
  dependencies: [repositoryProvider],
);

/// 一组弱点（学科 × 错因，或学科 × 知识点；原页内 `_WeakGroup`，改公开
/// 是因为页面渲染仍需这个类型）。
class WeakGroup {
  WeakGroup({
    required this.subjectId,
    required this.key,
    required this.titles,
  });

  final String subjectId;

  /// 错因文本，或知识点 id。
  final String key;
  final List<String> titles;

  /// 计数的题 id 集合：题名不唯一，同名不同题各算 1 道（SR-P1-10）；
  /// `titles` 只作展示行拼接。
  final Set<String> questionIds = {};

  int get count => questionIds.length;
}

/// P3 入口 3：薄弱点一行的样本量统计（报告统计口径，写死在代码里，
/// 行内同时展示，不只给题数）。
///
/// 口径：
/// - 时间范围 = 当前报告范围（本周/本月/全部），按 attempts 的作答时间
///   （created_at）截取；题目数不受时间范围影响（是该薄弱点现有的题）；
/// - 正式复习与专项练习的记录都参与，来源分别计数（formalCount /
///   practiceCount），行内标来源；
/// - 样本量同时给作答次数（attemptCount）与涉及题目数（questionCount）；
/// - 近期错误率 = 答错次数 / 已判分次数（未判分不计入分母），无已判分
///   记录时为 null（显示 —）；
/// - 样本少（题数 < 3 或作答次数 < 5）标“数据较少”。
class WeakSampleStats {
  const WeakSampleStats({
    required this.questionCount,
    required this.attemptCount,
    required this.wrongCount,
    required this.errorRate,
    required this.formalCount,
    required this.practiceCount,
    required this.rangeLabel,
  });

  /// 涉及题目数（该薄弱点现有的题，按 question_id 去重）。
  final int questionCount;

  /// 作答次数（范围内 attempts 行数，正式 + 专项）。
  final int attemptCount;

  /// 答错次数（correct == false 的 attempts 行数）。
  final int wrongCount;

  /// 近期错误率（答错 / 已判分），无已判分记录时为 null。
  final double? errorRate;

  /// 正式复习作答次数 / 专项练习作答次数（来源分别计数）。
  final int formalCount;
  final int practiceCount;

  /// 时间范围文案（本周 / 本月 / 全部）。
  final String rangeLabel;

  /// 样本少：题数 < 3 或作答次数 < 5。
  bool get sparse => questionCount < 3 || attemptCount < 5;

  String get label {
    final rate = errorRate == null
        ? '—'
        : '${(errorRate! * 100).round()}%';
    return '共 $questionCount 道 · 作答 $attemptCount 次 · 答错 $wrongCount 次 · 近期错误率 $rate · $rangeLabel';
  }

  String get sourceLabel => '正式 $formalCount 次 / 专项 $practiceCount 次';
}

/// 学习报告业务数据（原 `_ReportPageState` 里的读库字段，原样搬移）+
// 派生计算（原页内 getters，原样搬移；切范围只重算这些值，不重读库）。
class ReportState {
  const ReportState({
    this.range = 'week',
    this.loading = true,
    this.loadError = false,
    this.records = const [],
    this.questions = const [],
    this.knowledgePoints = const [],
    this.subjects = const [],
    this.history = const [],
    this.settings = AppSettings.defaults,
    // P3 入口 3：全部 attempts（样本量统计用）与已在池的题 id。
    this.attempts = const [],
    this.fsrsPoolIds = const {},
  });

  /// 时间范围：week / month / all（原 `_range`，默认本周）。
  final String range;

  /// 首查进行中（原 `_loading`；初始 true，首帧先出加载圈）。
  final bool loading;

  /// 读库失败（原 `_loadError`；失败留住上次成功加载的内容，只出横幅）。
  final bool loadError;

  /// 全部错因记录（原 `_records`）。
  final List<CauseRecord> records;

  /// 全部题目（含已归档；原 `_questions`）。
  final List<Question> questions;

  /// 全部知识点（原 `_knowledgePoints`）。
  final List<KnowledgePoint> knowledgePoints;

  /// 库里的全部学科（原 `_subjects`；空表是删光学科后的合法状态，不回退）。
  final List<Subject> subjects;

  /// 全部自查记录（原 `_history`）。
  final List<({String result, DateTime reviewedAt})> history;

  /// 设置（原 `_settings`；核心数小字里的复查间隔 / 治愈次数用）。
  final AppSettings settings;

  /// P3 入口 3：全部 attempts（正式 + 专项，见 [weakStats]）。
  final List<AttemptData> attempts;

  /// P3 入口 3：已在 FSRS 复习池里的题 id（列表行内标“已在复习”用）。
  final Set<String> fsrsPoolIds;

  // ---------- 范围 ----------

  DateTime? get rangeStart {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return switch (range) {
      'month' => DateTime(now.year, now.month, 1),
      'week' => today.subtract(Duration(days: today.weekday - 1)),
      _ => null,
    };
  }

  bool inRange(DateTime d) {
    final start = rangeStart;
    return start == null || !d.isBefore(start);
  }

  static String _md(DateTime d) => '${d.month}-${d.day}';

  /// 范围说明（原 `_rangeNote`）。
  String get rangeNote {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final label = switch (range) {
      'month' => '本月 · ${_md(rangeStart!)} ~ ${_md(today)}',
      'week' => '本周 · ${_md(rangeStart!)} ~ ${_md(today)}',
      _ => '全部时间',
    };
    return '$label · 数字按这个时间段算';
  }

  // ---------- 查找 ----------

  /// 库里找学科：新学科用库里的名与色；找不到才回退 `Subject.byId`
  ///（数学兜底，只发生在数据不一致时；原 `_subjectOf`）。
  Subject subjectOf(String id) => subjects.firstWhere(
        (s) => s.id == id,
        orElse: () => Subject.byId(id),
      );

  KnowledgePoint? kpOf(String id) {
    for (final kp in knowledgePoints) {
      if (kp.id == id) return kp;
    }
    return null;
  }

  String kpName(String id) => kpOf(id)?.name ?? '待补充';

  int subjectOrder(String subjectId) {
    final i = subjects.indexWhere((s) => s.id == subjectId);
    return i < 0 ? 99 : i;
  }

  // ---------- 派生：核心数 ----------

  /// 已解决错因数：按 `lastCheck` 在范围内计（为空视为在范围内）。
  int get solvedCount => records
      .where(
        (r) =>
            r.status == CauseStatus.solved &&
            (r.lastCheck == null || inRange(r.lastCheck!)),
      )
      .length;

  /// 待解决错因数：同上口径。
  int get pendingCount => records
      .where(
        (r) =>
            r.status != CauseStatus.solved &&
            (r.lastCheck == null || inRange(r.lastCheck!)),
      )
      .length;

  /// 范围内已判定的自查记录（去掉 `unsure`）。
  List<({String result, DateTime reviewedAt})> get judgedHistory =>
      history
          .where((h) => inRange(h.reviewedAt))
          .where((h) => h.result != 'unsure')
          .toList();

  /// 范围内复查通过数。
  int get judgedPassed =>
      judgedHistory.where((h) => h.result == 'solved').length;

  /// 复查通过率（无已判定记录时为 null，页面显示 —）。
  int? get passRate => judgedHistory.isEmpty
      ? null
      : (judgedPassed * 100 / judgedHistory.length).round();

  // ---------- 派生：弱点与分布 ----------

  /// （题 id|错因）→ 解决记录；无记录的错因默认待解决。
  Map<String, CauseRecord> get recordByKey => {
    for (final r in records) '${r.questionId}|${r.cause}': r,
  };

  /// 与错题本 / 首页同一口径（SR3-2）：按该题现存的全部错因记录算
  /// `reviewBucketOf == solved`；无记录的题不是已掌握。
  bool isMastered(Question q) {
    final rs = records.where((r) => r.questionId == q.id).toList();
    return QuestionRepository.reviewBucketOf(rs) == ReviewBucket.solved;
  }

  /// 所选范围内收集的题目（原 `_questionsInRange`）：只收已整理未归档
  /// 且未掌握的题；`all` 不按日期过滤。
  List<Question> get questionsInRange {
    final inScope = questions.where(
      (q) => q.isOrganized && !q.isArchived && !isMastered(q),
    );
    if (range == 'all') return inScope.toList();
    return inScope.where((q) => inRange(q.createdAt)).toList();
  }

  /// 最常错的原因 Top（全量，按题数倒序，学科顺序、错因文本兜底；原
  /// `_causeGroups`）。
  List<WeakGroup> get causeGroups {
    final byKey = recordByKey;
    final groups = <String, WeakGroup>{};
    final order = <String>[];
    for (final q in questionsInRange) {
      for (final cause in q.allCauses) {
        final record = byKey['${q.id}|$cause'];
        if (record?.status == CauseStatus.solved) continue;
        final key = '${q.subjectId}|$cause';
        var g = groups[key];
        if (g == null) {
          g = WeakGroup(subjectId: q.subjectId, key: cause, titles: []);
          groups[key] = g;
          order.add(key);
        }
        if (g.questionIds.add(q.id)) g.titles.add(q.title);
      }
    }
    final list = order.map((k) => groups[k]!).toList();
    list.sort((a, b) {
      final c = b.count.compareTo(a.count);
      if (c != 0) return c;
      final s = subjectOrder(a.subjectId) - subjectOrder(b.subjectId);
      return s != 0 ? s : a.key.compareTo(b.key);
    });
    return list;
  }

  /// 最常错的知识点 Top（全量；原 `_kpGroups`）。
  List<WeakGroup> get kpGroups {
    final byKey = recordByKey;
    final groups = <String, WeakGroup>{};
    final order = <String>[];
    for (final q in questionsInRange) {
      if (q.allCauses.isEmpty) continue;
      final allSolved = q.allCauses.every(
        (c) => byKey['${q.id}|$c']?.status == CauseStatus.solved,
      );
      if (allSolved) continue;
      for (final kpId in q.knowledgePointIds) {
        if (kpOf(kpId) == null) continue;
        final key = '${q.subjectId}|$kpId';
        var g = groups[key];
        if (g == null) {
          g = WeakGroup(subjectId: q.subjectId, key: kpId, titles: []);
          groups[key] = g;
          order.add(key);
        }
        if (g.questionIds.add(q.id)) g.titles.add(q.title);
      }
    }
    final list = order.map((k) => groups[k]!).toList();
    list.sort((a, b) {
      final c = b.count.compareTo(a.count);
      if (c != 0) return c;
      final s = subjectOrder(a.subjectId) - subjectOrder(b.subjectId);
      if (s != 0) return s;
      return kpName(a.key).compareTo(kpName(b.key));
    });
    return list;
  }

  /// “接下来练什么”一句话（原页内 `nextSentence`，无按钮）。
  String get nextSentence {
    final top = causeGroups;
    return top.isEmpty
        ? '这段时间没有待解决的错因，先去复习页把到期的复查做完。'
        : '先解决${subjectOf(top.first.subjectId).name}的${top.first.key}。';
  }

  /// P3 入口 3：薄弱点一行的样本量统计（见 [WeakSampleStats] 的口径）。
  WeakSampleStats weakStats(WeakGroup group) {
    final rangeLabel = switch (range) {
      'month' => '本月',
      'week' => '本周',
      _ => '全部',
    };
    final start = rangeStart;
    var attemptCount = 0;
    var wrongCount = 0;
    var gradedCount = 0;
    var formalCount = 0;
    var practiceCount = 0;
    for (final a in attempts) {
      if (!group.questionIds.contains(a.questionId)) continue;
      if (start != null &&
          DateTime.fromMillisecondsSinceEpoch(
            a.createdAt,
          ).isBefore(start)) {
        continue;
      }
      attemptCount++;
      if (a.mode == ReviewMode.due) {
        formalCount++;
      } else if (a.mode == ReviewMode.practice) {
        practiceCount++;
      }
      if (a.correct == null) continue;
      gradedCount++;
      if (a.correct == 0) wrongCount++;
    }
    return WeakSampleStats(
      questionCount: group.count,
      attemptCount: attemptCount,
      wrongCount: wrongCount,
      errorRate: gradedCount == 0 ? null : wrongCount / gradedCount,
      formalCount: formalCount,
      practiceCount: practiceCount,
      rangeLabel: rangeLabel,
    );
  }

  ReportState copyWith({
    String? range,
    bool? loading,
    bool? loadError,
    List<CauseRecord>? records,
    List<Question>? questions,
    List<KnowledgePoint>? knowledgePoints,
    List<Subject>? subjects,
    List<({String result, DateTime reviewedAt})>? history,
    AppSettings? settings,
    List<AttemptData>? attempts,
    Set<String>? fsrsPoolIds,
  }) {
    return ReportState(
      range: range ?? this.range,
      loading: loading ?? this.loading,
      loadError: loadError ?? this.loadError,
      records: records ?? this.records,
      questions: questions ?? this.questions,
      knowledgePoints: knowledgePoints ?? this.knowledgePoints,
      subjects: subjects ?? this.subjects,
      history: history ?? this.history,
      settings: settings ?? this.settings,
      attempts: attempts ?? this.attempts,
      fsrsPoolIds: fsrsPoolIds ?? this.fsrsPoolIds,
    );
  }
}

/// 学习报告业务逻辑（ARCH-PLAN-A 第 2 阶段：原 `_ReportPageState._load`
/// 原样搬入，只返回状态、不碰 UI）。
class ReportNotifier extends Notifier<ReportState> {
  /// 每次用都经 ref 拿：方法在 `build()` 跑完之前也能调（单测里只调
  /// 方法、不读 state 时尤其如此），且不缓存一份可能过期的 repo。
  QuestionRepository get _repo => ref.read(repositoryProvider);

  /// Provider 销毁后不再写 state（页面已卸载时读库回包不触 state）。
  bool _disposed = false;

  @override
  ReportState build() {
    ref.onDispose(() => _disposed = true);
    // 页面出现即读库（原 `initState` 的 `_load`）：不 await，
    // 读完后 state 一次性赋值，首帧先出加载圈。
    Future.microtask(load);
    return const ReportState();
  }

  /// 读库（原 `_load` 原样搬移：读错因记录、题目（含已归档）、知识点、
  /// 学科、设置，再逐题读自查记录）。成功时整份 state 一次性替换
  ///（范围保持当前值，不重置）；失败时只翻 `loadError`，旧内容留住。
  Future<void> load() async {
    // D-42：build() 的 microtask 首查可能在页面已离开、Provider 已销毁后
    // 才跑——先判 _disposed 再碰 ref；repo 入口处捕获一次，之后不再 ref.read。
    if (_disposed) return;
    final repo = _repo;
    try {
      final records = await repo.causeRecords();
      final questions = await repo.all(includeArchived: true);
      final kps = await repo.knowledgePoints();
      final subjects = await repo.subjects();
      final settings = await repo.settings();
      final history = <({String result, DateTime reviewedAt})>[];
      for (final q in questions) {
        history.addAll(await repo.reviewHistory(q.id));
      }
      // P3 入口 3：样本量统计用的全部 attempts 与池内标记；读不到
      // 时按空处理（统计口径里样本量为 0 即“数据较少”），不拖垮报告加载。
      List<AttemptData> attempts;
      try {
        attempts = await repo.loadAllAttempts();
      } catch (_) {
        attempts = const [];
      }
      Set<String> poolIds;
      try {
        poolIds = await repo.fsrsPoolQuestionIds();
      } catch (_) {
        poolIds = const {};
      }
      if (_disposed) return;
      state = ReportState(
        range: state.range,
        loading: false,
        loadError: false,
        records: records,
        questions: questions,
        knowledgePoints: kps,
        subjects: subjects,
        settings: settings,
        history: history,
        attempts: attempts,
        fsrsPoolIds: poolIds,
      );
    } catch (_) {
      // 加载失败：留住上次成功加载的内容（HTML 错误横幅口径），只出横幅。
      if (_disposed) return;
      state = state.copyWith(loading: false, loadError: true);
    }
  }

  /// 切时间范围（原分段器的 `onChanged`）：只改 `range`，派生值
  /// （核心数 / 弱点 / 分布 / 下一句）随 state 重算，不重读库。
  /// 两组弱点“看更多”的展开收起是页面本地状态，由页面在调本方法时
  /// 一并重置（原 `onChanged` 里的 `_expandCauses = false` 等）。
  void setRange(String range) {
    state = state.copyWith(range: range);
  }
}
