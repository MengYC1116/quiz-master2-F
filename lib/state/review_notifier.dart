// ARCH-PLAN-A 第 3 阶段：复习页的状态层。
//
// 状态是 [ReviewState]（列表数据 + 会话状态），唯一真源仍是 SQLite；
// 本 Provider 只做“响应式读取 + 会话状态持有 + 写回”，不另存一份。
// 读：`ref.watch(reviewProvider)`（列表）/ `ref.watch(reviewProvider
// .select(...))`（会话各步只订阅自己要的字段）；
// 写：`ref.read(reviewProvider.notifier).startSession(...)` 等。
//
// 会话状态归属（方案 §四第 3 阶段第 1 条）：断点续治与跳过队列的
// 实时会话状态由本 Provider 持有；自查结果、补救、治愈等持久化
// 写回 SQLite；详情页的复习记录不持有会话状态（详情页是下一页
// 的事，本次不动）。复习会话每次提交后本 Provider 的会话状态
// 直接更新，不等待事件回绕——DataChangeBus 是第 4 阶段才建，
// 本次不建（提交后也不发事件）。
//
// Provider 是 autoDispose（D-36 结论）：页面独占、随页生死，
// 离开中途再回来按旧版重挂载行为处理，断点续治靠 SQLite 里的
// 持久化状态恢复，不把未提交的会话状态当成必须跨导航保留的东西。
//
// 初始入参用 `reviewInitialProvider`（`ReviewInitial`：`subjectId`）：
// 页面外壳经 `ProviderScope` 注入，Notifier 的 `build()` 里读它
// 定初始学科筛选，不在页面 `initState` 里同步改 Provider
// （D-35 已记的 Riverpod 生命周期违规）。
//
// 构造器接进来的 `repo` 怎么进依赖图：`ReviewPage` 在 build 里包
// 一层 `ProviderScope(overrides: [repositoryProvider
// .overrideWithValue(widget.repo)])`——`app.dart` 仍按老样子传，
// 不用改；测试里构造器传 FakeRepo 同样经这一层注入，不用再包
// 一层 ProviderScope。本文件不认识任何 widget，不碰 `BuildContext`、
// 不弹 Dialog、不调导航；补救输入框的控制器是页面本地 UI 状态，
// 留在页面里（见 `review_page.dart` 的 causeKey 清空机制）。
// 角标走 `badgeCountsProvider`（第 4 阶段：订阅 `DataChangeBus`，
// 见 `badge_counts_provider.dart`）。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repository.dart';
import '../models/models.dart';
import 'repository_provider.dart';

/// 复习页业务状态的 Provider：页面出现即读库（见 [ReviewNotifier.build]）。
final reviewProvider =
    NotifierProvider.autoDispose<ReviewNotifier, ReviewState>(
      ReviewNotifier.new,
    );

/// 复习页的构造参数（初始落点）：带学科进来 → 该学科筛选；
/// 不带 → 全部。页面外壳经 `ProviderScope` 注入；Notifier 的
/// `build()` 里读它，不在 `initState` 里改 Provider（Riverpod
/// 禁止在 build / initState 等生命周期里同步改 Provider）。
class ReviewInitial {
  const ReviewInitial({this.subjectId});

  final String? subjectId;

  @override
  bool operator ==(Object other) =>
      other is ReviewInitial && other.subjectId == subjectId;

  @override
  int get hashCode => subjectId.hashCode;
}

/// 初始落点 Provider：默认空（全部学科）；页面外壳按构造参数 override。
final reviewInitialProvider = Provider<ReviewInitial>(
  (ref) => const ReviewInitial(),
);

/// 会话四步（HTML `REV2` 的 ①②③④）。
enum ReviewPhase { recall, remedy, redo, check }

const stepLabels = ['① 看错因', '② 写补救', '③ 重做', '④ 自查'];

/// 一条“题 × 错因”解决记录（列表分组里的一项）。
class CauseItem {
  CauseItem({required this.question, required this.record});

  final Question question;
  final CauseRecord record;
}

/// 列表分组：学科 × 错因（HTML `causeGroups()` / `curedGroups()`）。
class CauseGroup {
  CauseGroup({
    required this.subjectId,
    required this.cause,
    required this.firstJoined,
  });

  final String subjectId;
  final String cause;
  final List<CauseItem> items = [];
  DateTime firstJoined;

  /// 组状态（HTML `revListHTML` 的 stTxt 口径）：全已解决 → 已解决；
  /// 有待解决 → 待解决；其余 → 解决中。
  CauseStatus get status {
    if (items.every((it) => it.record.status == CauseStatus.solved)) {
      return CauseStatus.solved;
    }
    if (items.any((it) => it.record.status == CauseStatus.pending)) {
      return CauseStatus.pending;
    }
    return CauseStatus.inProgress;
  }

  bool get hasRecheck => items.any((it) => it.record.isRecheckDue);
}

/// 会话块：一道题 + 它本轮要治的错因（HTML `REV2.blocks`）。
/// 跳过时会产生新实例（不原地改 causes 列表），保证 `select`
/// 按实例变化能识别出当前块变了。
class CauseBlock {
  CauseBlock({required this.questionId, required this.causes});

  final String questionId;
  final List<String> causes;

  CauseBlock copyWith({String? questionId, List<String>? causes}) {
    return CauseBlock(
      questionId: questionId ?? this.questionId,
      causes: causes ?? this.causes,
    );
  }
}

/// 本轮一条状态变化（总结页每行）。
class SessionChange {
  SessionChange({
    required this.questionTitle,
    required this.subjectName,
    required this.cause,
    required this.before,
    required this.after,
    this.recheckDate,
    required this.note,
  });

  final String questionTitle;
  final String subjectName;
  final String cause;
  final String before;
  final String after;
  final DateTime? recheckDate;
  final String note;
}

/// 已保存的断点（解析后的“上次解决到一半”）。
class ResumeInfo {
  ResumeInfo({
    required this.blocks,
    required this.blockIndex,
    required this.causeIndex,
  });

  final List<CauseBlock> blocks;
  final int blockIndex;
  final int causeIndex;
}

/// 复习页日期格式（`_finishQuestion` 的总结文案与已解决区详情共用）。
String formatReviewDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String formatReviewMd(DateTime d) => '${d.month}-${d.day}';

/// `copyWith` 里“显式置 null”与“不改”的区分标记。
const _unset = Object();

/// 复习页的全部业务数据 + 列表 / 会话状态。
class ReviewState {
  const ReviewState({
    this.settings = AppSettings.defaults,
    this.subjects = const [],
    this.groups = const [],
    this.curedGroups = const [],
    this.notJoined = const [],
    this.pendingByQ = const {},
    this.loading = true,
    this.loadError = false,
    this.errorDismissed = false,
    this.hasLoaded = false,
    this.subjectFilter,
    this.causeFilter = '全部',
    this.page = 1,
    this.pageSize = 10,
    this.pageSizeInitialized = false,
    this.openCuredKey,
    this.curedPage = 0,
    this.notJoinedExpanded = false,
    this.resume,
    this.inSession = false,
    this.showSummary = false,
    this.blocks = const [],
    this.bi = 0,
    this.ci = 0,
    this.phase = ReviewPhase.recall,
    this.checks = const {},
    this.skips = const {},
    this.curedNow = 0,
    this.changes = const [],
    this.summaryRemaining = 0,
    this.scopeLabel = '全部待解决错因',
    this.saveError = false,
    this.historyByQ = const {},
    this.answerShown = true,
  });

  final AppSettings settings;

  /// 学科顺序表：读库 subjects（B2 补充；以前写死 Subject.all，
  /// 新学科在排序里无索引位、筛选下拉里也没有）。B8-1 扫尾：空表是
  /// 删光学科后的合法状态，不再回退预设三科；首帧与读库后都以真实
  /// 列表为准，空就是空。
  final List<Subject> subjects;
  final List<CauseGroup> groups;
  final List<CauseGroup> curedGroups;

  /// 还没加入复习、但真能加入的题（已整理、未归档、有错因）。
  final List<Question> notJoined;

  /// 每题待治的错因记录（按题内错因顺序），会话建块用。
  final Map<String, List<CauseRecord>> pendingByQ;

  /// 首查进行中（原 `_loading`；初始 true，首帧先出加载圈）。
  final bool loading;

  /// _load() 读库失败态（SR-P2-48）：报告 / 学科页同款——失败不一直
  /// 转圈，出错误横幅 + 重试；已加载过内容时留住旧内容。
  final bool loadError;
  final bool errorDismissed;
  final bool hasLoaded;

  final String? subjectFilter;
  final String causeFilter;
  final int page;

  /// P0B2：每页条数是本页本地状态（与错题本一致），只在打开时从设置
  /// 默认值读一次初值；下拉改动不写库、不改设置默认值。load() 在会话
  /// 结束、暂停回列表时也会跑，用标志守住初值，只首次取默认
  ///（SR-P1-12：否则页内改好的页数会被弹回默认值）。
  final int pageSize;
  final bool pageSizeInitialized;

  /// 已解决区展开的那一组 key（`subjectId|cause`），null 表示全收起。
  final String? openCuredKey;

  /// 已解决区独立分页（SR-P2-47，与待解决列表同一每页条数），0-based。
  final int curedPage;

  /// 未加入盒默认只列前 10 道（SR-P2-47），点开看全部。
  final bool notJoinedExpanded;

  /// 已保存的断点（“上次解决到一半”恢复条用）。
  final ResumeInfo? resume;

  // ---- 会话状态 ----

  final bool inSession;
  final bool showSummary;
  final List<CauseBlock> blocks;
  final int bi;
  final int ci;
  final ReviewPhase phase;

  /// 自查选择（错因 → “已解决”/“未解决”/“不确定”），按块清。
  final Map<String, String> checks;

  /// 跳过计数（`questionId|cause` → 次数）：第 1 次追加到队尾，
  /// 第 2 次留到下次。
  final Map<String, int> skips;
  final int curedNow;
  final List<SessionChange> changes;
  final int summaryRemaining;
  final String scopeLabel;
  final bool saveError;

  /// 会话内各题的自查历史（`reviewHistory`，按 reviewed_at DESC）。
  final Map<String, List<({String result, DateTime reviewedAt})>> historyByQ;

  /// 重做步答案是否显示（初值取设置 `redoAnswerHidden` 的反义）。
  final bool answerShown;

  ReviewState copyWith({
    AppSettings? settings,
    List<Subject>? subjects,
    List<CauseGroup>? groups,
    List<CauseGroup>? curedGroups,
    List<Question>? notJoined,
    Map<String, List<CauseRecord>>? pendingByQ,
    bool? loading,
    bool? loadError,
    bool? errorDismissed,
    bool? hasLoaded,
    Object? subjectFilter = _unset,
    String? causeFilter,
    int? page,
    int? pageSize,
    bool? pageSizeInitialized,
    Object? openCuredKey = _unset,
    int? curedPage,
    bool? notJoinedExpanded,
    Object? resume = _unset,
    bool? inSession,
    bool? showSummary,
    List<CauseBlock>? blocks,
    int? bi,
    int? ci,
    ReviewPhase? phase,
    Map<String, String>? checks,
    Map<String, int>? skips,
    int? curedNow,
    List<SessionChange>? changes,
    int? summaryRemaining,
    String? scopeLabel,
    bool? saveError,
    Map<String, List<({String result, DateTime reviewedAt})>>? historyByQ,
    bool? answerShown,
  }) {
    return ReviewState(
      settings: settings ?? this.settings,
      subjects: subjects ?? this.subjects,
      groups: groups ?? this.groups,
      curedGroups: curedGroups ?? this.curedGroups,
      notJoined: notJoined ?? this.notJoined,
      pendingByQ: pendingByQ ?? this.pendingByQ,
      loading: loading ?? this.loading,
      loadError: loadError ?? this.loadError,
      errorDismissed: errorDismissed ?? this.errorDismissed,
      hasLoaded: hasLoaded ?? this.hasLoaded,
      subjectFilter: subjectFilter == _unset
          ? this.subjectFilter
          : subjectFilter as String?,
      causeFilter: causeFilter ?? this.causeFilter,
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
      pageSizeInitialized: pageSizeInitialized ?? this.pageSizeInitialized,
      openCuredKey: openCuredKey == _unset
          ? this.openCuredKey
          : openCuredKey as String?,
      curedPage: curedPage ?? this.curedPage,
      notJoinedExpanded: notJoinedExpanded ?? this.notJoinedExpanded,
      resume: resume == _unset ? this.resume : resume as ResumeInfo?,
      inSession: inSession ?? this.inSession,
      showSummary: showSummary ?? this.showSummary,
      blocks: blocks ?? this.blocks,
      bi: bi ?? this.bi,
      ci: ci ?? this.ci,
      phase: phase ?? this.phase,
      checks: checks ?? this.checks,
      skips: skips ?? this.skips,
      curedNow: curedNow ?? this.curedNow,
      changes: changes ?? this.changes,
      summaryRemaining: summaryRemaining ?? this.summaryRemaining,
      scopeLabel: scopeLabel ?? this.scopeLabel,
      saveError: saveError ?? this.saveError,
      historyByQ: historyByQ ?? this.historyByQ,
      answerShown: answerShown ?? this.answerShown,
    );
  }

  // ---------- 派生数据（纯函数，原页面同名方法原样迁移） ----------

  /// 库里找学科：新学科用库里的名与色；找不到才回退 Subject.byId
  ///（数学兜底，只发生在数据不一致时）。
  Subject subjectOf(String id) => subjects.firstWhere(
        (s) => s.id == id,
        orElse: () => Subject.byId(id),
      );

  Question? questionOf(String questionId) {
    for (final g in [...groups, ...curedGroups]) {
      for (final it in g.items) {
        if (it.question.id == questionId) return it.question;
      }
    }
    return null;
  }

  /// 当前块是否有效（会话结束 / 块被跳空后 bi 可能越界，此时会话
  /// 应切到总结页，不再取当前题）。
  bool get hasCurrentBlock =>
      blocks.isNotEmpty && bi >= 0 && bi < blocks.length;

  CauseBlock get currentBlock => blocks[bi];

  Question? get currentQuestion =>
      hasCurrentBlock ? questionOf(currentBlock.questionId) : null;

  String get currentCause => currentBlock.causes[ci];

  /// 当前题的自查历史（会话内看错因步“上次自查”用）。
  List<({String result, DateTime reviewedAt})>? get currentHistory =>
      currentQuestion == null ? null : historyByQ[currentQuestion!.id];

  CauseRecord? recordOf(String questionId, String cause) {
    final rs = pendingByQ[questionId];
    if (rs != null) {
      for (final r in rs) {
        if (r.cause == cause) return r;
      }
    }
    for (final g in curedGroups) {
      for (final it in g.items) {
        if (it.question.id == questionId && it.record.cause == cause) {
          return it.record;
        }
      }
    }
    return null;
  }

  List<CauseGroup> filterGroups(List<CauseGroup> groups) {
    var list = groups;
    if (subjectFilter != null) {
      list = list.where((g) => g.subjectId == subjectFilter).toList();
    }
    if (causeFilter != '全部') {
      list = list.where((g) => g.cause == causeFilter).toList();
    }
    return list;
  }

  List<CauseGroup> get filtered => filterGroups(groups);
  List<CauseGroup> get filteredCured => filterGroups(curedGroups);

  int get totalPages {
    final n = (filtered.length / pageSize).ceil();
    return n < 1 ? 1 : n;
  }

  List<CauseGroup> get pageGroups {
    final list = filtered;
    final page = this.page.clamp(1, totalPages);
    final start = (page - 1) * pageSize;
    final end = (start + pageSize).clamp(0, list.length);
    if (start >= list.length) return const [];
    return list.sublist(start, end);
  }

  List<String> get allCauses {
    final set = <String>{};
    for (final g in [...groups, ...curedGroups]) {
      set.add(g.cause);
    }
    final fixed = ErrorTypes.fixed.where(set.contains).toList();
    final rest = set.where((c) => !ErrorTypes.fixed.contains(c)).toList()
      ..sort();
    return [...fixed, ...rest];
  }

  /// 元信息行计数（不过滤，HTML `revListHTML` 口径）。
  /// B9-4（Meng 2026-11-15 ~19:43 裁决：与角标 / 首页统一，按题数）：
  /// 三数按题互斥拆分，复用 `QuestionRepository.reviewBucketOf`
  /// 的共享口径——一道题按其全部错因记录只落一个桶。
  /// 不会双计 / 漏计：`load` 里一条记录只进 `groups` 或
  /// `curedGroups` 其中一边（isPending 分流），两边按题汇总后
  /// 才是该题的全部记录；多错因一题只计 1 道。已归档题不进两边，
  /// 与角标 / 首页口径一致（取消归档后重新计入）。
  (int pend, int check, int cured) get metaCounts {
    final byQ = <String, List<CauseRecord>>{};
    for (final g in [...groups, ...curedGroups]) {
      for (final it in g.items) {
        (byQ[it.question.id] ??= []).add(it.record);
      }
    }
    var pend = 0;
    var check = 0;
    var cured = 0;
    for (final records in byQ.values) {
      switch (QuestionRepository.reviewBucketOf(records)) {
        case ReviewBucket.pending:
          pend++;
        case ReviewBucket.recheck:
          check++;
        case ReviewBucket.solved:
          cured++;
        case ReviewBucket.none:
          break;
      }
    }
    return (pend, check, cured);
  }

  /// 新开会话的范围文案：按当前学科 / 错因筛选写（SR-P2-57）。
  String scopeLabelForFilters() {
    final subject =
        subjectFilter == null ? null : subjectOf(subjectFilter!).name;
    if (subject != null && causeFilter != '全部') {
      return '$subject · $causeFilter';
    }
    if (causeFilter != '全部') return '错因「$causeFilter」';
    if (subject != null) return '$subject这一科';
    return '全部待解决错因';
  }

  /// 断点队列的范围文案（SR-P2-57）：按队列里实际的学科 / 错因写。
  String scopeLabelForBlocks(List<CauseBlock> blocks) {
    final subjects = <String>{};
    final causes = <String>{};
    for (final b in blocks) {
      final q = questionOf(b.questionId);
      if (q != null) subjects.add(subjectOf(q.subjectId).name);
      causes.addAll(b.causes);
    }
    if (subjects.length == 1 && causes.length == 1) {
      return '${subjects.single} · ${causes.single}';
    }
    if (subjects.length == 1) return '${subjects.single}这一科';
    if (causes.length == 1) return '错因「${causes.single}」';
    return '全部待解决错因';
  }

  /// 补救输入框的清空信号：页面按它变化清一次控制器（原 `_beginCause` /
  /// `_skipCurrent` 里的 `_remedyController.clear()`）。不在会话里、
  /// 或块为空时为空串；跳过改动块内错因表时也变，保证跳步后输入框是空的。
  String get sessionCauseKey {
    if (!inSession || !hasCurrentBlock) return '';
    return '$bi|$ci|${currentBlock.questionId}|'
        '${currentBlock.causes.join(',')}';
  }
}

/// 扁平队列（ReviewQueueItem 顺序）→ 按题分块（连续同题合并）。
List<CauseBlock> _blocksFromFlat(List<ReviewQueueItem> flat) {
  final blocks = <CauseBlock>[];
  for (final entry in flat) {
    if (blocks.isNotEmpty && blocks.last.questionId == entry.questionId) {
      blocks.last.causes.add(entry.cause);
    } else {
      blocks.add(
          CauseBlock(questionId: entry.questionId, causes: [entry.cause]));
    }
  }
  return blocks;
}

/// 复习页业务逻辑 + 业务数据（ARCH-PLAN-A 第 3 阶段：原
/// `review_page.dart` 的 `_ReviewPageState` 里调 `repo` 的部分
/// 原样迁入；页面只留 widget 与本地交互状态——补救输入框控制器
/// 与会话内“查看题目详情”后的重读编排）。
///
/// 拿库的方式与 `HomeNotifier` 一致：经
/// `ref.read(repositoryProvider)` 拿——测试注入见
/// `docs/ui-replication/A-READING-GUIDE.md`（`ProviderContainer.test`
/// + `repositoryProvider.overrideWithValue`）。
class ReviewNotifier extends Notifier<ReviewState> {
  QuestionRepository get _repo => ref.read(repositoryProvider);

  bool _disposed = false;

  @override
  ReviewState build() {
    ref.onDispose(() => _disposed = true);
    // 页面出现即读库（原 `initState` 的 `_load`）：不 await，
    // 读完后 state 一次性赋值，首帧先出加载圈。
    Future.microtask(load);
    // 初始落点（原 `initState` 的一部分）：带学科进来 → 该学科筛选。
    // `load()` 只写数据字段，不动筛选字段，所以先读后读不影响最终状态。
    final initial = ref.read(reviewInitialProvider);
    return ReviewState(subjectFilter: initial.subjectId);
  }

  /// 首读与每次写库后重读（与原来页面的 `_load` 同口径）：
  /// 读库失败不一直转圈（SR-P2-48），出错误横幅 + 重试入口，
  /// 已加载过内容时留住旧内容。`load()` 只写列表数据字段，
  /// 不动会话字段（会话结束 / 暂停回列表时复用同一路重读，
  /// 不会把正在展示的总结 / 会话顶掉）。
  Future<void> load() async {
    // D-42：build() 的 microtask 首查可能在页面已离开、Provider 已销毁后
    // 才跑——先判 _disposed 再碰 ref；repo 入口处捕获一次，之后不再 ref.read。
    if (_disposed) return;
    final repo = _repo;
    try {
      final settings = await repo.settings();
      final subjects = await repo.subjects();
      final subjectList = subjects;
      final questions = await repo.all(includeArchived: true);
      final records = await repo.causeRecords();
      final byQ = <String, List<CauseRecord>>{};
      for (final r in records) {
        (byQ[r.questionId] ??= []).add(r);
      }
      final pendingByQ = <String, List<CauseRecord>>{};
      final pendingGroups = <String, CauseGroup>{};
      final curedGroups = <String, CauseGroup>{};
      final notJoined = <Question>[];
      for (final q in questions) {
        // “还没加入复习的题”只列真能加进复习的题（SR-P2-39）：
        // 未整理的题没有加入入口、无错因的题加不进（setReviewJoined
        // 错因为空返回 false），列出来只会让人白跑一趟详情页。
        if (!q.reviewJoined &&
            q.isOrganized &&
            !q.isArchived &&
            q.allCauses.isNotEmpty) {
          notJoined.add(q);
        }
        // B6：复习主列表排除已归档题（与 HTML `qInReview` 口径一致；
        // 未加入列表上面一行已排除了归档）。归档题的解决记录保留在
        // 库里（不删），取消归档后重新出现。
        if (!q.reviewJoined || !q.isOrganized || q.isArchived) continue;
        final rs = byQ[q.id];
        if (rs == null || rs.isEmpty) continue;
        // 题内错因按题目本身的错因顺序排。
        final order = q.allCauses;
        final sorted = [...rs]
          ..sort((a, b) =>
              order.indexOf(a.cause).compareTo(order.indexOf(b.cause)));
        final pending = sorted
            .where((r) => r.status != CauseStatus.solved || r.isRecheckDue)
            .toList();
        if (pending.isNotEmpty) pendingByQ[q.id] = pending;
        for (final r in sorted) {
          final key = '${q.subjectId}|${r.cause}';
          final isPending =
              r.status != CauseStatus.solved || r.isRecheckDue;
          final target = isPending ? pendingGroups : curedGroups;
          final g = target.putIfAbsent(
            key,
            () => CauseGroup(
              subjectId: q.subjectId,
              cause: r.cause,
              firstJoined: r.joinedAt,
            ),
          );
          g.items.add(CauseItem(question: q, record: r));
          if (r.joinedAt.isBefore(g.firstJoined)) {
            g.firstJoined = r.joinedAt;
          }
        }
      }
      int groupCompare(CauseGroup a, CauseGroup b) {
        if (settings.reviewSort == 'subject') {
          final order = {
            for (var i = 0; i < subjectList.length; i++)
              subjectList[i].id: i,
          };
          final c = (order[a.subjectId] ?? 99)
              .compareTo(order[b.subjectId] ?? 99);
          if (c != 0) return c;
        }
        return a.firstJoined.compareTo(b.firstJoined);
      }

      final sortedPending = pendingGroups.values.toList()..sort(groupCompare);
      final sortedCured = curedGroups.values.toList()..sort(groupCompare);

      // 断点：校验保存的队列是否还有待治项，无效则清掉（陈旧断点回收）。
      ResumeInfo? resume;
      final savedState = await repo.reviewState();
      if (savedState != null) {
        final pendingKeys = <ReviewQueueItem>{
          for (final rs in pendingByQ.values)
            for (final r in rs)
              ReviewQueueItem(questionId: r.questionId, cause: r.cause),
        };
        final valid = savedState.queue.where(pendingKeys.contains).toList();
        if (valid.isEmpty) {
          await repo.clearReviewState();
        } else {
          final blocks = _blocksFromFlat(valid);
          final pos = savedState.position.clamp(0, valid.length - 1);
          var seen = 0;
          var bi = 0;
          var ci = 0;
          for (var i = 0; i < blocks.length; i++) {
            if (pos < seen + blocks[i].causes.length) {
              bi = i;
              ci = pos - seen;
              break;
            }
            seen += blocks[i].causes.length;
          }
          resume = ResumeInfo(blocks: blocks, blockIndex: bi, causeIndex: ci);
        }
      }
      if (_disposed) return;
      // SR2-34：错因筛选的当前值可能在详情页删题 / 归档后失效——选项
      // 来自现存分组的 `allCauses`；唯一带该错因的题没了之后，旧值
      // 不在选项里，直接喂给 DropdownButton 会断言。无效时回落到
      // “全部”；下拉处另有就地 effectiveValue 兜底。
      final allCauses = <String>{};
      for (final g in [...sortedPending, ...sortedCured]) {
        allCauses.add(g.cause);
      }
      final causeFilter =
          state.causeFilter != '全部' && !allCauses.contains(state.causeFilter)
              ? '全部'
              : state.causeFilter;
      state = state.copyWith(
        settings: settings,
        pageSize: state.pageSizeInitialized
            ? state.pageSize
            : settings.pageSize,
        pageSizeInitialized: true,
        subjects: subjectList,
        groups: sortedPending,
        curedGroups: sortedCured,
        causeFilter: causeFilter,
        notJoined: notJoined,
        pendingByQ: pendingByQ,
        resume: resume,
        loading: false,
        loadError: false,
        hasLoaded: true,
      );
    } catch (_) {
      // 读库失败：不一直转圈（SR-P2-48），出错误横幅 + 重试入口。
      if (_disposed) return;
      state = state.copyWith(
        loading: false,
        loadError: true,
        errorDismissed: false,
      );
    }
  }

  /// 读库失败后点“重试”（原 `_retryLoad`）：先回到加载态、清掉错误横幅，
  /// 再重读一次；重读失败时 `load()` 的 catch 重新翻起 `loadError`。
  Future<void> retryLoad() async {
    state = state.copyWith(loading: true, loadError: false);
    await load();
  }

  void dismissLoadError() {
    state = state.copyWith(errorDismissed: true);
  }

  // ---------- 列表：筛选 / 分页 / 展开（改筛选后回第 1 页） ----------

  void setSubjectFilter(String? v) {
    state = state.copyWith(subjectFilter: v, page: 1, curedPage: 0);
  }

  void setCauseFilter(String v) {
    state = state.copyWith(causeFilter: v, page: 1, curedPage: 0);
  }

  void setPage(int p) {
    state = state.copyWith(page: p);
  }

  void setPageSize(int v) {
    state = state.copyWith(pageSize: v, page: 1, curedPage: 0);
  }

  void setCuredPage(int p) {
    state = state.copyWith(curedPage: p);
  }

  void toggleCured(String key) {
    state = state.copyWith(
      openCuredKey: state.openCuredKey == key ? null : key,
    );
  }

  void toggleNotJoinedExpanded() {
    state = state.copyWith(notJoinedExpanded: !state.notJoinedExpanded);
  }

  void dismissSaveError() {
    state = state.copyWith(saveError: false);
  }

  // ---------- 会话 ----------

  /// 从筛选后的分组建会话块：分组选中的题（按分组顺序首次出现），
  /// 每题只带筛选命中的错因（SR-P2-49 决定 (b)）——错因是出现在
  /// 传入分组里的那些；从某组点“开始解决”时只带该组的错因
  /// （`onlyCause`），该题的其他待治错因留待下次，不再一并治愈。
  List<CauseBlock> _buildBlocks(List<CauseGroup> groups,
      {String? onlyCause}) {
    final allowed = <String, Set<String>>{};
    for (final g in groups) {
      for (final it in g.items) {
        (allowed[it.question.id] ??= {}).add(g.cause);
      }
    }
    final seen = <String>{};
    final blocks = <CauseBlock>[];
    for (final g in groups) {
      for (final it in g.items) {
        final qid = it.question.id;
        if (seen.contains(qid)) continue;
        seen.add(qid);
        final causes = state.pendingByQ[qid];
        if (causes == null || causes.isEmpty) continue;
        final picked = causes
            .map((r) => r.cause)
            .where((c) => (allowed[qid] ?? const {}).contains(c))
            .where((c) => onlyCause == null || c == onlyCause)
            .toList();
        if (picked.isEmpty) continue;
        blocks.add(CauseBlock(questionId: qid, causes: picked));
      }
    }
    // 每会话错因数（设置 5/10/不限）：按列表顺序只取前 N 个错因。
    final limit = state.settings.causesPerSession;
    if (limit > 0) {
      var left = limit;
      final limited = <CauseBlock>[];
      for (final b in blocks) {
        if (left <= 0) break;
        final take = b.causes.take(left).toList();
        if (take.isNotEmpty) {
          limited.add(CauseBlock(questionId: b.questionId, causes: take));
          left -= take.length;
        }
      }
      return limited;
    }
    return blocks;
  }

  Future<void> _loadHistoryForSession() async {
    // D-42：repo 入口处捕获一次（逐题读历史跨多次 await）。
    final repo = _repo;
    final map = <String, List<({String result, DateTime reviewedAt})>>{};
    for (final b in state.blocks) {
      map[b.questionId] ??= await repo.reviewHistory(b.questionId);
    }
    if (_disposed) return;
    state = state.copyWith(historyByQ: map);
  }

  Future<void> startSession({CauseGroup? fromGroup, bool resume = false}) async {
    List<CauseBlock> blocks;
    var bi = 0;
    var ci = 0;
    String scopeLabel;
    if (resume && state.resume != null) {
      blocks = state.resume!.blocks;
      bi = state.resume!.blockIndex;
      ci = state.resume!.causeIndex;
      // 断点恢复条的范围文案（SR-P2-57）：按保存队列的实际范围写，
      // 不再一律写“全部待解决错因”。
      scopeLabel = state.scopeLabelForBlocks(blocks);
    } else {
      blocks = _buildBlocks(state.filtered, onlyCause: fromGroup?.cause);
      if (blocks.isEmpty) return;
      if (fromGroup != null) {
        // 跳到首个含该组错因的块（HTML `data-r2-start-group` 口径）。
        for (var i = 0; i < blocks.length; i++) {
          final qid = blocks[i].questionId;
          final q = state.questionOf(qid);
          if (q != null &&
              q.subjectId == fromGroup.subjectId &&
              blocks[i].causes.contains(fromGroup.cause)) {
            bi = i;
            break;
          }
        }
        // SR3-17：按组进会话的文案按实际块集算（`scopeLabelForBlocks`），
        // 不再一律按该组写。块集是（当前筛选 × 该错因）：跨学科同错因
        // 时自动退为“错因「…」”；单科单错因时仍是“学科名 · 错因”。
        // causesPerSession 截断后的块集也被如实描述（截断后可能不含
        // 该组任何题，旧文案仍写该组是同一类失真）。
        scopeLabel = state.scopeLabelForBlocks(blocks);
      } else {
        scopeLabel = state.scopeLabelForFilters();
      }
    }
    if (blocks.isEmpty) return;
    state = state.copyWith(
      blocks: blocks,
      bi: bi,
      ci: ci,
      phase: ReviewPhase.recall,
      checks: const {},
      skips: const {},
      curedNow: 0,
      changes: const [],
      answerShown: !state.settings.redoAnswerHidden,
      scopeLabel: scopeLabel,
      saveError: false,
      inSession: true,
      showSummary: false,
    );
    await _loadHistoryForSession();
  }

  /// 恢复条“从头开始”：清掉保存的断点，丢掉恢复信息，从头开新会话。
  Future<void> startOver() async {
    await _repo.clearReviewState();
    if (_disposed) return;
    state = state.copyWith(resume: null);
    await startSession();
  }

  /// 扁平队列 + 当前位置（暂停保存用，与基线 `review_state` 同格式）。
  (List<ReviewQueueItem>, int) _flatQueue() {
    final flat = <ReviewQueueItem>[];
    var pos = 0;
    for (var i = 0; i < state.blocks.length; i++) {
      for (var j = 0; j < state.blocks[i].causes.length; j++) {
        if (i == state.bi && j == state.ci) pos = flat.length;
        flat.add(ReviewQueueItem(
            questionId: state.blocks[i].questionId,
            cause: state.blocks[i].causes[j]));
      }
    }
    return (flat, pos);
  }

  Future<void> pauseSession() async {
    final (queue, position) = _flatQueue();
    await _repo.saveReviewState(queue: queue, position: position);
    if (_disposed) return;
    state = state.copyWith(inSession: false);
    await load();
  }

  Future<void> backToList() async {
    await _repo.clearReviewState();
    if (_disposed) return;
    state = state.copyWith(
      inSession: false,
      showSummary: false,
    );
    await load();
  }

  void _advanceBlock() {
    final bi = state.bi + 1;
    if (bi >= state.blocks.length) {
      unawaited(_finishSession());
      return;
    }
    // 原 `_beginCause`：新错因开始，回到 ① 步、答案按设置默认显隐。
    state = state.copyWith(
      bi: bi,
      ci: 0,
      checks: const {},
      phase: ReviewPhase.recall,
      answerShown: !state.settings.redoAnswerHidden,
    );
  }

  Future<void> _finishSession() async {
    // D-42：repo 入口处捕获一次（清断点 + 读记录 + 读题跨多次 await）。
    final repo = _repo;
    await repo.clearReviewState();
    final records = await repo.causeRecords();
    final questions = await repo.all(includeArchived: true);
    final joinedIds = {
      for (final q in questions)
        // B6：与主列表同口径，已归档题不计入剩余（记录保留，取消归档回来）。
        if (q.reviewJoined && q.isOrganized && !q.isArchived) q.id,
    };
    final remaining = records
        .where((r) =>
            joinedIds.contains(r.questionId) &&
            (r.status != CauseStatus.solved || r.isRecheckDue))
        .length;
    if (_disposed) return;
    state = state.copyWith(
      summaryRemaining: remaining,
      showSummary: true,
    );
    await load();
  }

  void skipCurrent() {
    final block = state.currentBlock;
    final qid = block.questionId;
    final cause = state.currentCause;
    final key = '$qid|$cause';
    final count = (state.skips[key] ?? 0) + 1;
    final skips = {...state.skips, key: count};
    // 跳过的错因从当前块里拿掉（新列表，不原地改旧块）。
    final remaining = [...block.causes]..removeAt(state.ci);
    final blocks = [...state.blocks];
    var bi = state.bi;
    var ci = state.ci;
    var phase = state.phase;
    // 原 setState 末尾：跳步后补救输入框清空、答案按设置默认显隐。
    // 输入框清空由页面按 `sessionCauseKey` 变化执行；
    // 这里只负责 `answerShown` 的复位（总结收尾分支除外，与原代码一致）。
    final answerShown = !state.settings.redoAnswerHidden;
    if (count < state.settings.skipLimit) {
      // 第 1 次跳过：追加单错因块到队尾。
      blocks.add(CauseBlock(questionId: qid, causes: [cause]));
    }
    // 第 2 次跳过：留到下次（本轮不再出现）。
    if (remaining.isEmpty) {
      blocks.removeAt(bi);
      ci = 0;
      phase = ReviewPhase.recall;
      state = state.copyWith(
        blocks: blocks,
        skips: skips,
        bi: bi,
        ci: ci,
        phase: phase,
        answerShown: answerShown,
      );
      if (bi >= blocks.length) {
        unawaited(_finishSession());
      }
      return;
    }
    blocks[bi] = block.copyWith(causes: remaining);
    if (ci >= remaining.length) {
      // 跳过的是本块最后一个错因：块里剩下的错因都已走完
      // ①② 步，直接进第 ③ 步重做。ci 仍钳回块内末位
      //（取当前错因查记录，越界会抛 RangeError），但不再回到
      // recall 重新呈现该错因（SR-P1-13：补救已写完，不应倒退）。
      ci = remaining.length - 1;
      phase = ReviewPhase.redo;
    } else {
      phase = ReviewPhase.recall;
    }
    state = state.copyWith(
      blocks: blocks,
      skips: skips,
      bi: bi,
      ci: ci,
      phase: phase,
      answerShown: answerShown,
    );
  }

  Future<void> nextFromRemedy(String remedyText) async {
    // D-42：repo 入口处捕获一次（写补救在 await 之后才碰 ref 的同款守门，
    // 本方法只有一次写库、仍按同一模式写死，避免后人加第二处时漏掉）。
    final repo = _repo;
    final record =
        state.recordOf(state.currentBlock.questionId, state.currentCause);
    if (record != null && remedyText.trim().isNotEmpty) {
      await repo.saveRemedy(record, remedyText);
    }
    if (_disposed) return;
    if (state.ci < state.currentBlock.causes.length - 1) {
      // 下个错因：原 `_beginCause`（回到 ① 步、答案按设置默认显隐；
      // 输入框清空由页面按 `sessionCauseKey` 变化执行）。
      state = state.copyWith(
        ci: state.ci + 1,
        phase: ReviewPhase.recall,
        answerShown: !state.settings.redoAnswerHidden,
      );
    } else {
      state = state.copyWith(
        phase: ReviewPhase.redo,
        answerShown: !state.settings.redoAnswerHidden,
      );
    }
  }

  Future<void> finishQuestion() async {
    // D-42：repo 入口处捕获一次（逐错因自查跨多次 await）。
    final repo = _repo;
    final block = state.currentBlock;
    final q = state.currentQuestion;
    if (q == null) {
      _advanceBlock();
      return;
    }
    var curedNow = state.curedNow;
    final changes = [...state.changes];
    for (final cause in block.causes) {
      final choiceLabel = state.checks[cause];
      if (choiceLabel == null) continue;
      // 自查按钮存的是中文文案，仓库要 solved / unsolved / unsure 编码。
      final choice = switch (choiceLabel) {
        '已解决' => 'solved',
        '未解决' => 'unsolved',
        _ => 'unsure',
      };
      final record = state.recordOf(block.questionId, cause);
      if (record == null) continue;
      final before = record.status.label;
      final wasRecheck = record.isRecheckDue;
      if (choice == 'unsure') {
        // 不确定不算，不改记录；总结里留一行说明。
        changes.add(SessionChange(
          questionTitle: q.title,
          subjectName: state.subjectOf(q.subjectId).name,
          cause: cause,
          before: before,
          after: before,
          note: '选了不确定，不算，下次重新练这道题再自查一次',
        ));
        continue;
      }
      late CauseRecord updated;
      try {
        updated = await repo.recordSelfCheck(
          record,
          choice,
          cureChecks: state.settings.cureChecks,
          recheckIntervalDays: state.settings.recheckIntervalDays,
          // 待定1：复查通过不加计数（HTML 口径）。
          isRecheck: wasRecheck,
        );
      } catch (_) {
        if (_disposed) return;
        state = state.copyWith(saveError: true);
        return;
      }
      final after = updated.status.label;
      String note;
      if (wasRecheck) {
        note = choice == 'solved'
            ? '复查通过，下次复查 ${formatReviewDate(updated.recheckDate!)}'
            : '复查没过，打回解决中';
      } else if (choice == 'solved') {
        note = updated.status == CauseStatus.solved
            ? '已解决，下次复查 ${formatReviewDate(updated.recheckDate!)}'
            : '还差 ${state.settings.cureChecks - updated.solvedCount} 次「已解决」解决';
      } else {
        note = '错因未解决，继续解决（答对了题也不算掌握）';
      }
      if (before != '已解决' && after == '已解决') curedNow++;
      changes.add(SessionChange(
        questionTitle: q.title,
        subjectName: state.subjectOf(q.subjectId).name,
        cause: cause,
        before: before,
        after: after,
        recheckDate:
            updated.status == CauseStatus.solved ? updated.recheckDate : null,
        note: note,
      ));
    }
    if (_disposed) return;
    state = state.copyWith(curedNow: curedNow, changes: changes);
    _advanceBlock();
  }

  // ---------- 会话内单步动作（页面按钮直调） ----------

  void setPhase(ReviewPhase phase) {
    state = state.copyWith(phase: phase);
  }

  void setAnswerShown(bool v) {
    state = state.copyWith(answerShown: v);
  }

  void setCheck(String cause, String label) {
    state = state.copyWith(checks: {...state.checks, cause: label});
  }

  /// 重做步“下一步：自查”：进 ④ 步并清空本块的自查选择。
  void enterCheck() {
    state = state.copyWith(phase: ReviewPhase.check, checks: const {});
  }
}
