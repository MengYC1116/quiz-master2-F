// ARCH-PLAN-A 第 3 阶段：复习页的状态层。
//
// P2 简化基线（D2，2026-11-25）：三步统一流程（看题 → 作答 → 核对
// → 下一题 → 小结），一道题内部的状态变化，不是每段翻一页。
// 无置信度、无错因自查、无治愈判定、无软件判定掌握；掌握与否由用户
// 自己判断。题目是会话单位，答题结果是客观对错事实。
//
// 状态是 [ReviewState]（列表数据 + 会话状态），唯一真源仍是 SQLite；
// 本 Provider 只做“响应式读取 + 会话状态持有 + 写回”，不另存一份。
// 读：`ref.watch(reviewProvider)`（列表）/ `ref.watch(reviewProvider
// .select(...))`（会话各步只订阅自己要的字段）；
// 写：`ref.read(reviewProvider.notifier).startSession(...)` 等。
//
// 会话状态归属：断点续治与跳过队列的实时会话状态由本 Provider 持有；
// 核对提交（attempts 正式记录 + FSRS 调度）持久化写回 SQLite（见
// submitCheck / repository.recordAttempt）；详情页的复习记录
// 不持有会话状态。复习会话每次提交后本 Provider 的会话状态直接更新，
// 不等待事件回绕。
//
// Provider 是 autoDispose：页面独占、随页生死，离开中途再回来按旧版
// 重挂载行为处理，断点续治靠 SQLite 里的持久化状态恢复，不把未提交
// 的会话状态当成必须跨导航保留的东西。
//
// 初始入参用 `reviewInitialProvider`（`ReviewInitial`：`subjectId`）：
// 页面外壳经 `ProviderScope` 注入，Notifier 的 `build()` 里读它
// 定初始学科筛选，不在页面 `initState` 里同步改 Provider。
//
// 构造器接进来的 `repo` 怎么进依赖图：`ReviewPage` 在 build 里包
// 一层 `ProviderScope(overrides: [repositoryProvider
// .overrideWithValue(widget.repo)])`——`app.dart` 仍按老样子传，
// 不用改；测试里构造器传 FakeRepo 同样经这一层注入，不用再包
// 一层 ProviderScope。本文件不认识任何 widget，不碰 `BuildContext`、
// 不弹 Dialog、不调导航。
// 角标走 `badgeCountsProvider`（第 4 阶段：订阅 `DataChangeBus`，
// 见 `badge_counts_provider.dart`）。
import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/p3_review_entries.dart';
import '../data/repository.dart';
import '../data/review_engine.dart';
import '../data/review_scheduler.dart';
import '../models/models.dart';
import 'repository_provider.dart';

/// 复习页业务状态的 Provider：页面出现即读库（见 [ReviewNotifier.build]）。
///
/// D-49：声明 `dependencies`（与 detailProvider 同一缺陷：不声明时
/// Riverpod 3.x 把 Provider 挂到根容器，`build()` 里读到的
/// `reviewInitialProvider` 是默认值而非页面嵌套 Scope 的 override）。
final reviewProvider =
    NotifierProvider.autoDispose<ReviewNotifier, ReviewState>(
      ReviewNotifier.new,
      dependencies: [
        reviewInitialProvider,
        repositoryProvider,
        reviewSchedulerProvider,
      ],
    );

/// 复习页的构造参数（初始落点）：带学科进来 → 该学科筛选；
/// 不带 → 全部。页面外壳经 `ProviderScope` 注入；Notifier 的
/// `build()` 里读它，不在 `initState` 里改 Provider（Riverpod
/// 禁止在 build / initState 等生命周期里同步改 Provider）。
/// P3 入口 1/3：[practiceQuestionIds] 非空时，页面加载完成后直接用
/// 这批题开专项练习（只练不排；已有未完成会话时先挂起，等用户在恢复条
/// 上二选一）；[practiceCount] <= 0 或空表示全部。
class ReviewInitial {
  const ReviewInitial({
    this.subjectId,
    this.practiceQuestionIds,
    this.practiceCount,
  });

  final String? subjectId;
  final List<String>? practiceQuestionIds;
  final int? practiceCount;

  @override
  bool operator ==(Object other) {
    if (other is! ReviewInitial) return false;
    if (other.subjectId != subjectId ||
        other.practiceCount != practiceCount) {
      return false;
    }
    final a = practiceQuestionIds;
    final b = other.practiceQuestionIds;
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    subjectId,
    practiceQuestionIds == null
        ? null
        : Object.hashAll(practiceQuestionIds!),
    practiceCount,
  );
}

/// 初始落点 Provider：默认空（全部学科）；页面外壳按构造参数 override。
final reviewInitialProvider = Provider<ReviewInitial>(
  (ref) => const ReviewInitial(),
);

/// FSRS 调度器 Provider（P5）：默认 SQLite CardStore（fsrs_cards 表）。
///
/// P5 接入 SQLite：store 换成 [SqliteCardStore]（绑单例库，生产配置
/// fuzzing 开）；调度器与业务代码都不改。测试用 override 注入确定性
/// 调度器（fuzzing 关）与独立的 InMemoryCardStore。
final reviewSchedulerProvider = Provider<ReviewScheduler>(
  (ref) => FsrsReviewScheduler(
    config: const SchedulerConfig(),
    store: SqliteCardStore(),
  ),
);

/// 会话内一道题的阶段（P2 三步：看题 → 作答 → 核对；done 是核对
/// 已提交后的过渡态，只在恢复后遇到已提交的题时出现）。
enum SessionStage { view, answer, check, done }

const stageLabels = ['① 看题', '② 作答', '③ 核对'];

/// 会话内一道题的状态（M3-10 持久化单位）。immutable + copyWith；
/// 每题的状态变化都产生新实例，`select` 能识别。
class SessionQuestionState {
  const SessionQuestionState({
    required this.questionId,
    required this.causes,
    this.nonRoundCauses = const [],
    required this.answerVersionAtStart,
    required this.contentVersionAtStart,
    required this.questionSubmissionId,
    required this.attemptSubmissionId,
    this.stage = SessionStage.view,
    this.attemptId,
    this.selected,
    this.correct,
    this.checkSubmitted = false,
    this.notesShown = false,
    this.skips = 0,
    this.deferred = false,
  });

  /// 题 id。
  final String questionId;

  /// 本轮要处理的错因名（到期复习：符合范围且到期的错因；专项练习：
  /// 该题的全部错因，仅作上下文）。
  final List<String> causes;

  /// 非本轮错因名（折叠显示，标“未到期，下次复查 <日期>”或
  /// “不在本次范围”；不接受 verdict、不推进进度）。
  final List<String> nonRoundCauses;

  /// 会话开始时的答案 / 内容版本快照（M3-10）。
  final int answerVersionAtStart;
  final int contentVersionAtStart;

  /// 父级 question_submission_id（一次按题“下一步”一个 uuid）。
  final String questionSubmissionId;

  /// 本题 attempt 的稳定 submission_id（一次会话每题一条 attempt；
  /// 跳过后重遇、恢复重放沿用，不新建）。
  final String attemptSubmissionId;

  /// 当前阶段。
  final SessionStage stage;

  /// 已创建的 attempt id（null = 尚未实际作答；只跳过、从未作答的题
  /// 不建 attempt）。
  final String? attemptId;

  /// 选择/判断/多选的点选（单选/判断为单元素列表；多选为多元素）。
  final List<String>? selected;

  /// 客观判分结果（1 答对 / 0 答错 / null 不判分）。
  final int? correct;

  /// 核对提交是否已完成（attempt 已写 + FSRS 已调，如适用）。
  /// 恢复重放与重复点击靠它短路，不重写、不重计分。
  final bool checkSubmitted;

  /// 批注笔记是否已显示（M3-16：默认隐藏；显示后题卡给视觉提示）。
  final bool notesShown;

  /// 本题在本次会话内的跳过次数（按题计）。
  final int skips;

  /// 第二次跳过后移出本次会话（留到下次）。
  final bool deferred;

  bool get hasAttempt => attemptId != null;
  bool get isObjectiveSubmitted => hasAttempt && selected != null;

  SessionQuestionState copyWith({
    List<String>? causes,
    List<String>? nonRoundCauses,
    int? answerVersionAtStart,
    int? contentVersionAtStart,
    SessionStage? stage,
    String? attemptId,
    // 十四批 M5 修复轮 3（D-156）：显式清 attemptId 用。直接传
    // attemptId: null 清不掉（`?? this.attemptId` 会保留旧值）——
    // 旧恢复代码 `copyWith(attemptId: null)` 实际是空操作。
    bool clearAttemptId = false,
    // 哨兵用 identical 判等（不用 `is` 类型判断）：调用方传的
    // List 可能是 List<dynamic>（如 [...(selected ?? const [])]
    // 的推断类型），`is! List<String>?` 会把它误判为“未传”而丢掉
    // 本次点选——多选点选曾因此失效（M3 自验抓到）。
    Object? selected = _unset,
    Object? correct = _unset,
    bool? checkSubmitted,
    bool? notesShown,
    int? skips,
    bool? deferred,
  }) {
    return SessionQuestionState(
      questionId: questionId,
      causes: causes ?? this.causes,
      nonRoundCauses: nonRoundCauses ?? this.nonRoundCauses,
      answerVersionAtStart: answerVersionAtStart ?? this.answerVersionAtStart,
      contentVersionAtStart:
          contentVersionAtStart ?? this.contentVersionAtStart,
      questionSubmissionId: questionSubmissionId,
      attemptSubmissionId: attemptSubmissionId,
      stage: stage ?? this.stage,
      attemptId: clearAttemptId ? null : (attemptId ?? this.attemptId),
      selected: identical(selected, _unset)
          ? this.selected
          : selected as List<String>?,
      correct: identical(correct, _unset)
          ? this.correct
          : correct as int?,
      checkSubmitted: checkSubmitted ?? this.checkSubmitted,
      notesShown: notesShown ?? this.notesShown,
      skips: skips ?? this.skips,
      deferred: deferred ?? this.deferred,
    );
  }

  /// 持久化编码（review_state.per_question_state 的一题）。
  Map<String, Object?> toJson() => {
    'question_submission_id': questionSubmissionId,
    'attempt_submission_id': attemptSubmissionId,
    'answer_version_at_start': answerVersionAtStart,
    'content_version_at_start': contentVersionAtStart,
    'stage': stage.name,
    'attempt_id': attemptId,
    'selected': selected,
    'correct': correct,
    'check_submitted': checkSubmitted,
    'notes_shown': notesShown,
    'skips': skips,
    'deferred': deferred,
  };

  static SessionQuestionState fromJson(
    String questionId,
    List<String> causes,
    List<String> nonRoundCauses,
    Map<String, Object?> json,
  ) {
    SessionStage stage = SessionStage.view;
    final rawStage = json['stage'];
    if (rawStage is String) {
      stage = SessionStage.values.firstWhere(
        (s) => s.name == rawStage,
        orElse: () => SessionStage.view,
      );
    }
    // P2 旧会话兼容：旧 selfCheck 阶段不再自查，先回到核对步；
    // _validateSavedSession 再按库里有无 attempts 行决定完成或重做。
    if (rawStage == 'selfCheck') stage = SessionStage.check;
    List<String>? selected;
    final rawSelected = json['selected'];
    if (rawSelected is List) {
      selected = rawSelected.map((e) => e.toString()).toList();
    }
    return SessionQuestionState(
      questionId: questionId,
      causes: causes,
      nonRoundCauses: nonRoundCauses,
      answerVersionAtStart:
          (json['answer_version_at_start'] as num?)?.toInt() ?? 0,
      contentVersionAtStart:
          (json['content_version_at_start'] as num?)?.toInt() ?? 0,
      questionSubmissionId:
          json['question_submission_id']?.toString() ??
          newReviewUuid('qs'),
      attemptSubmissionId:
          json['attempt_submission_id']?.toString() ??
          newReviewUuid('attsub'),
      stage: stage,
      attemptId: json['attempt_id']?.toString(),
      selected: selected,
      correct: (json['correct'] as num?)?.toInt(),
      checkSubmitted: json['check_submitted'] == true,
      notesShown: json['notes_shown'] == true,
      skips: (json['skips'] as num?)?.toInt() ?? 0,
      deferred: json['deferred'] == true,
    );
  }
}

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

/// 会话块：一道题 + 它本轮要治的错因（M3 之前叫 CauseBlock；新会话
/// 用 [SessionQuestionState]，本类只保留给列表“按组开始”与恢复条
/// 的范围文案复用）。
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

/// 已保存的断点（M3-10 轻量会话持久化恢复后的会话）。
class ResumeInfo {
  ResumeInfo({
    required this.sessionQuestions,
    required this.sessionIndex,
    required this.sessionId,
    required this.mode,
  });

  final List<SessionQuestionState> sessionQuestions;
  final int sessionIndex;
  final String sessionId;
  final String mode;
}

/// 复习页日期格式（总结文案与已解决区详情共用）。
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
    this.allQuestions = const [],
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
    this.typeFilter,
    this.page = 1,
    this.pageSize = 10,
    this.pageSizeInitialized = false,
    this.openCuredKey,
    this.curedPage = 0,
    this.notJoinedExpanded = false,
    this.resume,
    this.resumeExpired = false,
    this.futureRecheckCount = 0,
    this.inSession = false,
    this.showSummary = false,
    this.sessionId,
    this.sessionMode,
    this.sessionQuestions = const [],
    this.sessionIndex = 0,
    this.showPracticePicker = false,
    this.practiceEmpty = false,
    this.practiceSubjectFilter,
    this.practiceTypeFilter,
    this.practiceCauseFilter = '全部',
    this.practiceCount = 10,
    this.practiceRandom = true,
    this.submitting = false,
    this.scopeLabel = '全部待解决错因',
    this.saveError = false,
    this.sumCompleted = 0,
    this.sumHandled = 0,
    this.sumUngraded = 0,
    this.sumSkipped = 0,
    this.sumDeferred = 0,
    this.sumObjCorrect = 0,
    this.sumObjWrong = 0,
    this.sumWeakKp = const {},
    this.sumNextDueDate,
    this.sumElapsedSeconds = 0,
    this.sessionStartedAt,
    this.kpNames = const {},
    this.rejoinNotice,
    // P3 入口 1–3：已在 FSRS 池里的题 id（小结收题默认勾选判定用）。
    this.fsrsPoolIds = const {},
    // P3 入口 1/3：已有未完成会话时挂起的待开专项练习题单
    //（等用户在恢复条上二选一；放弃旧会话后按此开练）。
    this.pendingPracticeIds = const [],
    this.pendingPracticeCount,
    // P3：ReviewInitial 带进来的题单是否已处理过（只处理一次）。
    this.initialPracticeStarted = false,
    // P3 入口 2：小结收题的选择状态（按 sessionId 隔离，一轮一清）。
    this.sumCollectSelected = const {},
    this.sumCollectApplied = const {},
    this.sumCollectSessionId,
    this.sumCollectMessage,
  });

  final AppSettings settings;

  /// 学科顺序表：读库 subjects（B2 补充；以前写死 Subject.all，
  /// 新学科在排序里无索引位、筛选下拉里也没有）。B8-1 扫尾：空表是
  /// 删光学科后的合法状态，不再回退预设三科；首帧与读库后都以真实
  /// 列表为准，空就是空。
  final List<Subject> subjects;

  /// 全部已整理、未归档的题（专项练习选题池用）。
  final List<Question> allQuestions;
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

  /// 题型筛选（M3-11：学科/题型/错因三维度；null = 全部）。
  final String? typeFilter;
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

  /// 已保存的断点（“继续上次会话”恢复条用）。
  final ResumeInfo? resume;

  /// 快照整体失效（队列全部无效）：已按最新状态重筛并提示，不自动开新会话。
  final bool resumeExpired;

  /// 正在等待未来复查的错因数（空状态用：只统计已纳入复习且未来有
  /// 复查日期的错因）。
  final int futureRecheckCount;

  // ---- 会话状态（P2 三步流程） ----

  final bool inSession;
  final bool showSummary;
  final String? sessionId;
  final String? sessionMode;
  final List<SessionQuestionState> sessionQuestions;
  final int sessionIndex;
  final bool showPracticePicker;
  final bool practiceEmpty;
  final String? practiceSubjectFilter;
  final String? practiceTypeFilter;
  final String practiceCauseFilter;
  final int practiceCount;
  final bool practiceRandom;

  /// 提交进行中锁（P2 防重复提交：提交中禁用提交按钮）。
  final bool submitting;
  final String scopeLabel;
  final bool saveError;

  // ---- 小结汇总（P2：只报对错数、用时、按知识点排的弱点、下次时间） ----
  final int sumCompleted;
  final int sumHandled;
  final int sumUngraded;
  final int sumSkipped;
  final int sumDeferred;
  final int sumObjCorrect;
  final int sumObjWrong;

  /// 本轮答错的客观题按知识点汇总（知识点 id → 答错题数），
  /// 小结按答错数从多到少展示弱点。
  final Map<String, int> sumWeakKp;

  /// 本轮已核对题的下次到期时间里最早的一个（FSRS 算出；
  /// 无已核对的到期复习题时为 null）。
  final DateTime? sumNextDueDate;

  /// 本轮会话用时（秒，从进入会话到出小结）。
  final int sumElapsedSeconds;

  /// 进入本轮会话的时间（用时起点；暂停续接后重新计时）。
  final DateTime? sessionStartedAt;

  /// 知识点 id → 名称（小结弱点展示用；load() 时读库）。
  final Map<String, String> kpNames;

  /// 专项练习“已重新加入复习”的反馈文案（用后即清）。
  final String? rejoinNotice;

  /// P3：已在 FSRS 复习池里的题 id。
  final Set<String> fsrsPoolIds;

  /// P3 入口 1/3：挂起的待开专项练习题单（见上）。
  final List<String> pendingPracticeIds;
  final int? pendingPracticeCount;

  /// P3：ReviewInitial 题单已处理过。
  final bool initialPracticeStarted;

  /// P3 入口 2：小结收题——当前勾选、本轮已加入、本轮小结的 sessionId、
  /// 最近一次收题结果文案。
  final Set<String> sumCollectSelected;
  final Set<String> sumCollectApplied;
  final String? sumCollectSessionId;
  final String? sumCollectMessage;

  /// P3 入口 2：本轮小结里答错的题 id（系统确认答错，correct == 0）。
  List<String> get sumWrongQuestionIds => [
    for (final sq in sessionQuestions)
      if (sq.correct == 0) sq.questionId,
  ];

  /// P3 入口 2：本轮小结里未判分的题 id（correct == null）。
  List<String> get sumUngradedQuestionIds => [
    for (final sq in sessionQuestions)
      if (sq.correct == null) sq.questionId,
  ];

  ReviewState copyWith({
    AppSettings? settings,
    List<Subject>? subjects,
    List<Question>? allQuestions,
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
    Object? typeFilter = _unset,
    int? page,
    int? pageSize,
    bool? pageSizeInitialized,
    Object? openCuredKey = _unset,
    int? curedPage,
    bool? notJoinedExpanded,
    Object? resume = _unset,
    bool? resumeExpired,
    int? futureRecheckCount,
    bool? inSession,
    bool? showSummary,
    Object? sessionId = _unset,
    Object? sessionMode = _unset,
    List<SessionQuestionState>? sessionQuestions,
    int? sessionIndex,
    bool? showPracticePicker,
    bool? practiceEmpty,
    Object? practiceSubjectFilter = _unset,
    Object? practiceTypeFilter = _unset,
    String? practiceCauseFilter,
    int? practiceCount,
    bool? practiceRandom,
    bool? submitting,
    String? scopeLabel,
    bool? saveError,
    int? sumCompleted,
    int? sumHandled,
    int? sumUngraded,
    int? sumSkipped,
    int? sumDeferred,
    int? sumObjCorrect,
    int? sumObjWrong,
    Map<String, int>? sumWeakKp,
    Object? sumNextDueDate = _unset,
    int? sumElapsedSeconds,
    Object? sessionStartedAt = _unset,
    Map<String, String>? kpNames,
    Object? rejoinNotice = _unset,
    Set<String>? fsrsPoolIds,
    List<String>? pendingPracticeIds,
    Object? pendingPracticeCount = _unset,
    bool? initialPracticeStarted,
    Set<String>? sumCollectSelected,
    Set<String>? sumCollectApplied,
    Object? sumCollectSessionId = _unset,
    Object? sumCollectMessage = _unset,
  }) {
    return ReviewState(
      settings: settings ?? this.settings,
      subjects: subjects ?? this.subjects,
      allQuestions: allQuestions ?? this.allQuestions,
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
      typeFilter: typeFilter == _unset
          ? this.typeFilter
          : typeFilter as String?,
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
      pageSizeInitialized: pageSizeInitialized ?? this.pageSizeInitialized,
      openCuredKey: openCuredKey == _unset
          ? this.openCuredKey
          : openCuredKey as String?,
      curedPage: curedPage ?? this.curedPage,
      notJoinedExpanded: notJoinedExpanded ?? this.notJoinedExpanded,
      resume: resume == _unset ? this.resume : resume as ResumeInfo?,
      resumeExpired: resumeExpired ?? this.resumeExpired,
      futureRecheckCount: futureRecheckCount ?? this.futureRecheckCount,
      inSession: inSession ?? this.inSession,
      showSummary: showSummary ?? this.showSummary,
      sessionId: sessionId == _unset
          ? this.sessionId
          : sessionId as String?,
      sessionMode: sessionMode == _unset
          ? this.sessionMode
          : sessionMode as String?,
      sessionQuestions: sessionQuestions ?? this.sessionQuestions,
      sessionIndex: sessionIndex ?? this.sessionIndex,
      showPracticePicker: showPracticePicker ?? this.showPracticePicker,
      practiceEmpty: practiceEmpty ?? this.practiceEmpty,
      practiceSubjectFilter: practiceSubjectFilter == _unset
          ? this.practiceSubjectFilter
          : practiceSubjectFilter as String?,
      practiceTypeFilter: practiceTypeFilter == _unset
          ? this.practiceTypeFilter
          : practiceTypeFilter as String?,
      practiceCauseFilter: practiceCauseFilter ?? this.practiceCauseFilter,
      practiceCount: practiceCount ?? this.practiceCount,
      practiceRandom: practiceRandom ?? this.practiceRandom,
      submitting: submitting ?? this.submitting,
      scopeLabel: scopeLabel ?? this.scopeLabel,
      saveError: saveError ?? this.saveError,
      sumCompleted: sumCompleted ?? this.sumCompleted,
      sumHandled: sumHandled ?? this.sumHandled,
      sumUngraded: sumUngraded ?? this.sumUngraded,
      sumSkipped: sumSkipped ?? this.sumSkipped,
      sumDeferred: sumDeferred ?? this.sumDeferred,
      sumObjCorrect: sumObjCorrect ?? this.sumObjCorrect,
      sumObjWrong: sumObjWrong ?? this.sumObjWrong,
      sumWeakKp: sumWeakKp ?? this.sumWeakKp,
      sumNextDueDate: sumNextDueDate == _unset
          ? this.sumNextDueDate
          : sumNextDueDate as DateTime?,
      sumElapsedSeconds: sumElapsedSeconds ?? this.sumElapsedSeconds,
      sessionStartedAt: sessionStartedAt == _unset
          ? this.sessionStartedAt
          : sessionStartedAt as DateTime?,
      kpNames: kpNames ?? this.kpNames,
      rejoinNotice: rejoinNotice == _unset
          ? this.rejoinNotice
          : rejoinNotice as String?,
      fsrsPoolIds: fsrsPoolIds ?? this.fsrsPoolIds,
      pendingPracticeIds: pendingPracticeIds ?? this.pendingPracticeIds,
      pendingPracticeCount: pendingPracticeCount == _unset
          ? this.pendingPracticeCount
          : pendingPracticeCount as int?,
      initialPracticeStarted:
          initialPracticeStarted ?? this.initialPracticeStarted,
      sumCollectSelected: sumCollectSelected ?? this.sumCollectSelected,
      sumCollectApplied: sumCollectApplied ?? this.sumCollectApplied,
      sumCollectSessionId: sumCollectSessionId == _unset
          ? this.sumCollectSessionId
          : sumCollectSessionId as String?,
      sumCollectMessage: sumCollectMessage == _unset
          ? this.sumCollectMessage
          : sumCollectMessage as String?,
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
    for (final q in allQuestions) {
      if (q.id == questionId) return q;
    }
    for (final g in [...groups, ...curedGroups]) {
      for (final it in g.items) {
        if (it.question.id == questionId) return it.question;
      }
    }
    return null;
  }

  /// 当前会话题是否有效（会话结束 / 题被跳空后 index 可能越界，
  /// 此时会话应切到总结页，不再取当前题）。
  bool get hasCurrentQuestion =>
      sessionQuestions.isNotEmpty &&
      sessionIndex >= 0 &&
      sessionIndex < sessionQuestions.length;

  SessionQuestionState get currentSessionQuestion =>
      sessionQuestions[sessionIndex];

  Question? get currentQuestion =>
      hasCurrentQuestion
          ? questionOf(currentSessionQuestion.questionId)
          : null;

  /// 全部错因记录（分组两边之和：待治 + 已治愈；会话选题与恢复校验用）。
  List<CauseRecord> get allCauseRecords {
    final list = <CauseRecord>[];
    for (final g in [...groups, ...curedGroups]) {
      for (final it in g.items) {
        list.add(it.record);
      }
    }
    return list;
  }

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
    if (typeFilter != null) {
      list = list
          .where(
            (g) => g.items.any((it) => it.question.questionType == typeFilter),
          )
          .toList();
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

  /// 库里出现过的题型（题型筛选下拉用；null 题型不列入）。
  List<String> get allQuestionTypes {
    final set = <String>{};
    for (final q in allQuestions) {
      if (q.questionType != null) set.add(q.questionType!);
    }
    return set.toList()..sort();
  }

  /// 今日待复习（M3-11 页顶）：X 道题 / Y 个错因（X 为去重后题数）。
  /// 口径 = 到期复习默认池（buildDueQueue，无筛选、不限量）。
  (int questions, int causes) get dueTodayCounts {
    final queue = buildDueQueue(
      records: allCauseRecords,
      joinedQuestionIds: {
        for (final q in allQuestions)
          if (q.reviewJoined && q.isOrganized && !q.isArchived) q.id,
      },
      questionsById: {for (final q in allQuestions) q.id: q},
    );
    var causes = 0;
    for (final item in queue) {
      causes += item.causes.length;
    }
    return (queue.length, causes);
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
  String scopeLabelForSession(List<SessionQuestionState> questions) {
    final subjects = <String>{};
    final causes = <String>{};
    for (final sq in questions) {
      final q = questionOf(sq.questionId);
      if (q != null) subjects.add(subjectOf(q.subjectId).name);
      causes.addAll(sq.causes);
    }
    if (subjects.length == 1 && causes.length == 1) {
      return '${subjects.single} · ${causes.single}';
    }
    if (subjects.length == 1) return '${subjects.single}这一科';
    if (causes.length == 1) return '错因「${causes.single}」';
    return '全部待解决错因';
  }

  /// 本轮题数与错因数（会话开场与小结用）。
  (int questions, int causes) get sessionTotals {
    var causes = 0;
    for (final sq in sessionQuestions) {
      causes += sq.causes.length;
    }
    return (sessionQuestions.length, causes);
  }

  bool get isPracticeSession => sessionMode == ReviewMode.practice;
}

/// 复习页业务逻辑 + 业务数据（ARCH-PLAN-A 第 3 阶段：原
/// `review_page.dart` 的 `_ReviewPageState` 里调 `repo` 的部分
/// 原样迁入；页面只留 widget 与本地交互状态）。
///
/// 拿库的方式与 `HomeNotifier` 一致：经
/// `ref.read(repositoryProvider)` 拿——测试注入见
/// `docs/ui-replication/A-READING-GUIDE.md`（`ProviderContainer.test`
/// + `repositoryProvider.overrideWithValue`）。
/// P3 入口 1/3：用一批指定题开专项练习的结果。
enum PracticeStartOutcome {
  /// 已开练。
  started,

  /// 已有未完成会话（正式复习或专项练习）：新练习已挂起
  ///（[ReviewState.pendingPracticeIds]），等用户在恢复条上二选一；
  /// 旧会话不断点、不覆盖。
  blockedByResume,

  /// 题单解析后无可练的题（全被删/归档/未整理）。
  empty,
}

class ReviewNotifier extends Notifier<ReviewState> {
  QuestionRepository get _repo => ref.read(repositoryProvider);

  bool _disposed = false;

  /// P3：build() 里读到的初始题单（load() 完成后只处理一次）。
  List<String>? _initialPracticeIds;
  int? _initialPracticeCount;

  @override
  ReviewState build() {
    ref.onDispose(() => _disposed = true);
    // 页面出现即读库（原 `initState` 的 `_load`）：不 await，
    // 读完后 state 一次性赋值，首帧先出加载圈。
    Future.microtask(load);
    // 初始落点（原 `initState` 的一部分）：带学科进来 → 该学科筛选。
    // `load()` 只写数据字段，不动筛选字段，所以先读后读不影响最终状态。
    final initial = ref.read(reviewInitialProvider);
    _initialPracticeIds = initial.practiceQuestionIds;
    _initialPracticeCount = initial.practiceCount;
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
      final kps = await repo.knowledgePoints();
      final byQ = <String, List<CauseRecord>>{};
      for (final r in records) {
        (byQ[r.questionId] ??= []).add(r);
      }
      final pendingByQ = <String, List<CauseRecord>>{};
      final pendingGroups = <String, CauseGroup>{};
      final curedGroups = <String, CauseGroup>{};
      final notJoined = <Question>[];
      var futureRecheckCount = 0;
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
          // 空状态用：已纳入复习且未来有复查日期的错因数。
          if (r.status == CauseStatus.solved &&
              r.recheckDate != null &&
              !r.isRecheckDue) {
            futureRecheckCount++;
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

      // 断点：校验保存的会话是否还有效（M3-10 恢复校验）。
      final resume = await _validateSavedSession(
        repo: repo,
        questions: questions,
        recordsByQ: byQ,
      );
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
        allQuestions: questions,
        groups: sortedPending,
        curedGroups: sortedCured,
        causeFilter: causeFilter,
        notJoined: notJoined,
        pendingByQ: pendingByQ,
        kpNames: {for (final kp in kps) kp.id: kp.name},
        resume: resume,
        resumeExpired: resume == null && _expiredSessionInThisLoad,
        futureRecheckCount: futureRecheckCount,
        loading: false,
        loadError: false,
        hasLoaded: true,
      );
      // P3：读已在池里的题 id（小结收题默认勾选判定用）；读不到按空集，
      // 不拖垮列表加载。
      try {
        final poolIds = await ref
            .read(reviewSchedulerProvider)
            .pooledQuestionIds();
        if (!_disposed) state = state.copyWith(fsrsPoolIds: poolIds);
      } catch (_) {
        // 池内标记是锦上添花，读不到不拖垮列表。
      }
      // P3 入口 1/3：初始题单只处理一次（load 成功后）。
      if (_initialPracticeIds != null &&
          !state.initialPracticeStarted &&
          !_disposed) {
        final ids = _initialPracticeIds!;
        final count = _initialPracticeCount;
        state = state.copyWith(initialPracticeStarted: true);
        await startPracticeWithIds(ids, count: count);
      }
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

  /// 快照整体失效时 `_validateSavedSession` 已清掉 review_state；
  /// 这里只为 load() 区分“本来就没有断点”和“断点刚失效”——
  /// 用一个内存标记（本次 load 内有效），不另存库。
  bool _expiredSessionInThisLoad = false;

  /// 校验保存的会话快照（M3-10）：题目已删除、错因已删除/已治愈/
  /// 已不在范围 → 该项安全移除；答案/内容版本变化按
  /// versionCheck 处理（未作答刷新快照、已提交移出会话）；
  /// 恢复以 attempts 的实际写入为准重建提交状态（P2：只认 attempts 行）。
  /// 返回有效的 ResumeInfo；快照整体失效时清掉 review_state 并返回 null。
  Future<ResumeInfo?> _validateSavedSession({
    required QuestionRepository repo,
    required List<Question> questions,
    required Map<String, List<CauseRecord>> recordsByQ,
  }) async {
    _expiredSessionInThisLoad = false;
    final saved = await repo.reviewState();
    if (saved == null || saved.queue.isEmpty) return null;
    final questionsById = {for (final q in questions) q.id: q};
    final sessionId = saved.sessionId ?? newReviewUuid('sess');
    final mode = saved.mode ?? ReviewMode.due;
    // 按题重建会话状态（队列是扁平的题×错因，先按题去重）。
    final byQ = <String, List<String>>{};
    final qOrder = <String>[];
    for (final item in saved.queue) {
      if (!byQ.containsKey(item.questionId)) {
        byQ[item.questionId] = [];
        qOrder.add(item.questionId);
      }
      if (!byQ[item.questionId]!.contains(item.cause)) {
        byQ[item.questionId]!.add(item.cause);
      }
    }
    final sessionQuestions = <SessionQuestionState>[];
    var removedAny = false;
    for (final qid in qOrder) {
      final q = questionsById[qid];
      if (q == null || q.isArchived) {
        removedAny = true;
        continue;
      }
      final records = recordsByQ[qid] ?? const [];
      final recordByCause = {for (final r in records) r.cause: r};
      // 本轮错因：仍在库里的才保留；到期复习里已治愈且未到复查日的
      // 错因已不在范围，移除。
      final causes = <String>[];
      for (final cause in byQ[qid]!) {
        final r = recordByCause[cause];
        if (r == null) {
          removedAny = true;
          continue;
        }
        if (mode == ReviewMode.due &&
            r.status == CauseStatus.solved &&
            !r.isRecheckDue) {
          removedAny = true;
          continue;
        }
        causes.add(cause);
      }
      if (causes.isEmpty) {
        removedAny = true;
        continue;
      }
      final nonRound = records
          .map((r) => r.cause)
          .where((c) => !causes.contains(c))
          .toList();
      final savedState = saved.perQuestionState[qid];
      var sq = SessionQuestionState.fromJson(
        qid,
        causes,
        nonRound,
        savedState ?? const {},
      );
      // 先从数据库重建真实提交状态，再做版本判定（十四批 M5 修复轮 3，
      // D-156，GPT fix2 P1-3）：崩溃窗口（核对提交已写库、
      // review_state 未更新）下，per_question_state 仍显示未提交；
      // 若先按缓存判版本，已提交题目会在版本变化时被刷新成新版本
      // 继续留在同一会话，而不是按既定规则移出。提交状态以数据库
      // 实际写入为准（P2：只认 attempts 行，不认 review_history
      // verdict——P2 起产品流程不再写 verdict）：库里有本会话的
      // attempt 行就采用它的 id（覆盖缓存缺失的 attemptId），库里
      // 没有就清掉缓存里的旧 id；attempt 状态为“跳过”时不算已提交
      // （跳过后重遇仍可核对提交）。
      final dbAttempt = await repo.loadAttempt(
        sessionId: sessionId,
        questionId: qid,
      );
      final rebuiltAttemptId = dbAttempt?.id;
      // P2 旧会话兼容（实施方案 v2 §7，不动迁移）：
      // - 看题/作答阶段 → 保留当前题恢复原阶段；
      // - 核对未提交 → 回到核对步，提交时只写一次（attempt 不存在，
      //   checkSubmitted 为 false，submitCheck 按同一 eventId 写）；
      // - 已写客观记录（attempt 存在且非“跳过”）→ 视为已完成，
      //   不重计分（stage 置 done、checkSubmitted 置 true）；
      // - 旧 selfCheck 阶段 → fromJson 已映射回核对步，再按有无
      //   客观记录决定完成（done）或重做（check）。
      final committed = dbAttempt != null && dbAttempt.status != '跳过';
      final rebuiltHasSubmitted = committed;
      // 版本检查：快照版本与当前版本同时比较（用重建后的提交态判）。
      final versionAction = versionCheck(
        snapshotAnswerVersion: sq.answerVersionAtStart,
        snapshotContentVersion: sq.contentVersionAtStart,
        currentAnswerVersion: q.answerVersion,
        currentContentVersion: q.contentVersion,
        hasSubmitted: rebuiltHasSubmitted,
      );
      if (versionAction == VersionAction.remove) {
        // 已提交作答或核对的题：保留原 attempt，移出本次会话。
        removedAny = true;
        continue;
      }
      if (versionAction == VersionAction.refresh) {
        // 尚未实际作答：刷新题目内容和版本快照，从看题重新开始。
        sq = sq.copyWith(
          answerVersionAtStart: q.answerVersion,
          contentVersionAtStart: q.contentVersion,
          stage: SessionStage.view,
          selected: null,
          correct: null,
        );
        removedAny = true;
      }
      // 应用重建的提交状态：stale 的 checkSubmitted / attemptId
      // （库里没有当前 session 的 attempt 行）随之丢掉，不让恢复
      // 后误以为已提交。
      sq = sq.copyWith(
        attemptId: rebuiltAttemptId,
        clearAttemptId: rebuiltAttemptId == null,
        stage: committed ? SessionStage.done : sq.stage,
        checkSubmitted: committed,
      );
      sessionQuestions.add(sq);
    }
    if (sessionQuestions.isEmpty) {
      await repo.clearReviewState();
      _expiredSessionInThisLoad = removedAny;
      return null;
    }
    // 位置：保存的扁平位置映射到题下标（钳在有效范围）。
    final flatPosition = saved.position.clamp(0, saved.queue.length - 1);
    var seen = 0;
    var sessionIndex = 0;
    for (var i = 0; i < sessionQuestions.length; i++) {
      final count = byQ[sessionQuestions[i].questionId]?.length ?? 0;
      if (flatPosition < seen + count) {
        sessionIndex = i;
        break;
      }
      seen += count;
      sessionIndex = i;
    }
    // 校验后如有项被移除，把修正后的快照写回（不丢剩余断点）。
    if (removedAny) {
      await _persistSession(sessionQuestions, sessionIndex, sessionId, mode);
    }
    return ResumeInfo(
      sessionQuestions: sessionQuestions,
      sessionIndex: sessionIndex,
      sessionId: sessionId,
      mode: mode,
    );
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

  void dismissResumeExpired() {
    state = state.copyWith(resumeExpired: false);
  }

  void dismissRejoinNotice() {
    state = state.copyWith(rejoinNotice: null);
  }

  // ---------- 列表：筛选 / 分页 / 展开（改筛选后回第 1 页） ----------

  void setSubjectFilter(String? v) {
    state = state.copyWith(subjectFilter: v, page: 1, curedPage: 0);
  }

  void setCauseFilter(String v) {
    state = state.copyWith(causeFilter: v, page: 1, curedPage: 0);
  }

  void setTypeFilter(String? v) {
    state = state.copyWith(typeFilter: v, page: 1, curedPage: 0);
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

  // ---------- 会话：建队 ----------

  /// 到期复习建队（M3-2）：先筛错因、再按题去重；排序逾期/到期优先；
  /// 数量按设置项“每会话错因数”截断（同一题的本轮错因完整处理）。
  List<SessionQuestionState> _buildDueSessionQuestions({
    String? onlyCause,
    String? onlySubjectId,
  }) {
    final questionsById = {for (final q in state.allQuestions) q.id: q};
    final queue = buildDueQueue(
      records: state.allCauseRecords,
      joinedQuestionIds: {
        for (final q in state.allQuestions)
          if (q.reviewJoined && q.isOrganized && !q.isArchived) q.id,
      },
      subjectFilter: onlySubjectId ?? state.subjectFilter,
      typeFilter: state.typeFilter,
      causeFilter: onlyCause ?? (state.causeFilter == '全部'
          ? null
          : state.causeFilter),
      questionsById: questionsById,
      limit: state.settings.causesPerSession,
    );
    return queue.map((item) {
      final q = questionsById[item.questionId]!;
      final nonRound = state.allCauseRecords
          .where((r) => r.questionId == item.questionId)
          .map((r) => r.cause)
          .where((c) => !item.causes.contains(c))
          .toList();
      return SessionQuestionState(
        questionId: item.questionId,
        causes: item.causes,
        nonRoundCauses: nonRound,
        answerVersionAtStart: q.answerVersion,
        contentVersionAtStart: q.contentVersion,
        questionSubmissionId: newReviewUuid('qs'),
        attemptSubmissionId: newReviewUuid('attsub'),
      );
    }).toList();
  }

  /// 专项练习建队（M3-2）：范围自选；可含未到期、已掌握、未加入复习题。
  List<SessionQuestionState> _buildPracticeSessionQuestions() {
    final recordsByQ = <String, List<CauseRecord>>{};
    for (final r in state.allCauseRecords) {
      (recordsByQ[r.questionId] ??= []).add(r);
    }
    final queue = buildPracticeQueue(
      questions: state.allQuestions,
      recordsByQ: recordsByQ,
      subjectFilter: state.practiceSubjectFilter,
      typeFilter: state.practiceTypeFilter,
      causeFilter: state.practiceCauseFilter == '全部'
          ? null
          : state.practiceCauseFilter,
      count: state.practiceCount,
      randomOrder: state.practiceRandom,
    );
    return queue.map((item) {
      final q = state.questionOf(item.questionId)!;
      return SessionQuestionState(
        questionId: item.questionId,
        causes: item.causes,
        nonRoundCauses: const [],
        answerVersionAtStart: q.answerVersion,
        contentVersionAtStart: q.contentVersion,
        questionSubmissionId: newReviewUuid('qs'),
        attemptSubmissionId: newReviewUuid('attsub'),
      );
    }).toList();
  }

  /// 把当前会话快照写进 review_state（M3-10 轻量持久化）。
  Future<void> _persistSession(
    List<SessionQuestionState> questions,
    int index,
    String sessionId,
    String mode,
  ) async {
    final repo = _repo;
    final queue = <ReviewQueueItem>[];
    var position = 0;
    var flat = 0;
    for (var i = 0; i < questions.length; i++) {
      for (final cause in questions[i].causes) {
        if (i == index) position = flat;
        queue.add(
          ReviewQueueItem(questionId: questions[i].questionId, cause: cause),
        );
        flat++;
      }
    }
    final perQuestion = {
      for (final sq in questions) sq.questionId: sq.toJson(),
    };
    final skips = {
      for (final sq in questions)
        if (sq.skips > 0) sq.questionId: sq.skips,
    };
    await repo.saveReviewState(
      queue: queue,
      position: position,
      sessionId: sessionId,
      mode: mode,
      skips: skips,
      perQuestionState: perQuestion,
    );
  }

  Future<void> _persistCurrentSession() async {
    if (state.sessionId == null || state.sessionMode == null) return;
    await _persistSession(
      state.sessionQuestions,
      state.sessionIndex,
      state.sessionId!,
      state.sessionMode!,
    );
  }

  void _enterSession({
    required List<SessionQuestionState> questions,
    required String sessionId,
    required String mode,
    required int startIndex,
    required String scopeLabel,
  }) {
    state = state.copyWith(
      sessionQuestions: questions,
      sessionIndex: startIndex,
      sessionId: sessionId,
      sessionMode: mode,
      scopeLabel: scopeLabel,
      submitting: false,
      saveError: false,
      sumCompleted: 0,
      sumHandled: 0,
      sumUngraded: 0,
      sumSkipped: 0,
      sumDeferred: 0,
      sumObjCorrect: 0,
      sumObjWrong: 0,
      sumWeakKp: const {},
      sumNextDueDate: null,
      sumElapsedSeconds: 0,
      sessionStartedAt: DateTime.now(),
      // P3 入口 2：新一轮开始，小结收题状态清掉（按 sessionId 隔离）。
      sumCollectSelected: const {},
      sumCollectApplied: const {},
      sumCollectSessionId: null,
      sumCollectMessage: null,
      inSession: true,
      showSummary: false,
      showPracticePicker: false,
      practiceEmpty: false,
    );
  }

  /// 开始到期复习（默认自动生成队列：全部到期错因）。
  /// 队列为空时不进入空白会话（页面显示空状态）。
  Future<void> startSession({CauseGroup? fromGroup, bool resume = false}) async {
    if (resume && state.resume != null) {
      final r = state.resume!;
      _enterSession(
        questions: r.sessionQuestions,
        sessionId: r.sessionId,
        mode: r.mode,
        startIndex: r.sessionIndex,
        scopeLabel: state.scopeLabelForSession(r.sessionQuestions),
      );
      // P3 入口 2：恢复后小结须完整——_enterSession 把小结计数清零，
      // 已核对过的题（checkSubmitted，correct/stage 已随断点持久化）
      // 要按原值重建计数，否则恢复后做完只剩后半段的数，小结不完整。
      final done = r.sessionQuestions
          .where((sq) => sq.checkSubmitted)
          .toList();
      final weakKp = <String, int>{};
      for (final sq in done) {
        if (sq.correct != 0) continue;
        final q = state.questionOf(sq.questionId);
        for (final kp in q?.knowledgePointIds ?? const <String>[]) {
          weakKp[kp] = (weakKp[kp] ?? 0) + 1;
        }
      }
      DateTime? earliestNextDue;
      if (r.mode == ReviewMode.due) {
        final scheduler = ref.read(reviewSchedulerProvider);
        for (final sq in done) {
          if (sq.correct == null) continue;
          final due = await scheduler.nextDueAt(sq.questionId);
          if (due != null &&
              (earliestNextDue == null || due.isBefore(earliestNextDue))) {
            earliestNextDue = due;
          }
        }
      }
      state = state.copyWith(
        sumCompleted: done.length,
        sumHandled: r.mode == ReviewMode.practice
            ? 0
            : done.fold<int>(0, (n, sq) => n + sq.causes.length),
        sumObjCorrect: done.where((sq) => sq.correct == 1).length,
        sumObjWrong: done.where((sq) => sq.correct == 0).length,
        sumUngraded: done.where((sq) => sq.correct == null).length,
        sumWeakKp: weakKp,
        sumNextDueDate: earliestNextDue,
      );
      return;
    }
    if (state.resume != null) {
      // 单行表 review_state 只能存一个会话：已有未完成会话时不直接
      // 覆盖（页面 _startDue 已先二选一；这里是兜底，防直接调用丢断点）。
      return;
    }
    final questions = _buildDueSessionQuestions(
      onlyCause: fromGroup?.cause,
      onlySubjectId: fromGroup?.subjectId,
    );
    if (questions.isEmpty) return;
    // P3：用户明确新开到期复习，挂起的待开专项练习题单作废。
    state = state.copyWith(
      pendingPracticeIds: const [],
      pendingPracticeCount: null,
    );
    var startIndex = 0;
    if (fromGroup != null) {
      for (var i = 0; i < questions.length; i++) {
        final q = state.questionOf(questions[i].questionId);
        if (q != null &&
            q.subjectId == fromGroup.subjectId &&
            questions[i].causes.contains(fromGroup.cause)) {
          startIndex = i;
          break;
        }
      }
    }
    final sessionId = newReviewUuid('sess');
    _enterSession(
      questions: questions,
      sessionId: sessionId,
      mode: ReviewMode.due,
      startIndex: startIndex,
      scopeLabel: fromGroup != null
          ? state.scopeLabelForSession(questions)
          : state.scopeLabelForFilters(),
    );
    await _persistCurrentSession();
  }

  /// 恢复条“从头开始”：清掉保存的断点，丢掉恢复信息，从头开新会话。
  Future<void> startOver() async {
    await _repo.clearReviewState();
    if (_disposed) return;
    state = state.copyWith(resume: null);
    await startSession();
  }

  /// 放弃暂停会话，再开始新会话（单活动会话二选一的“放弃”分支）。
  Future<void> abandonResumeAndStartDue() async {
    await _repo.clearReviewState();
    if (_disposed) return;
    state = state.copyWith(resume: null);
    await startSession();
  }

  /// 放弃暂停会话，再开始专项练习（单活动会话二选一的“放弃”分支）。
  /// 与无断点时点“专项练习”同款：先开选题页（让用户选范围/数量/
  /// 顺序），不直接按默认范围开会话——此前版本直接调
  // startPracticeSession()，跳过了选题页（M3 自验新测试抓到）。
  /// P3：若有挂起的待开题单（入口 1/3 带题进来时被旧会话挡住），
  /// 放弃旧会话后直接按挂起的题单开练，不再回选题页。
  Future<void> abandonResumeAndStartPractice() async {
    await _repo.clearReviewState();
    if (_disposed) return;
    final pending = state.pendingPracticeIds;
    final pendingCount = state.pendingPracticeCount;
    state = state.copyWith(
      resume: null,
      pendingPracticeIds: const [],
      pendingPracticeCount: null,
    );
    if (pending.isNotEmpty) {
      await startPracticeWithIds(pending, count: pendingCount);
      return;
    }
    openPracticePicker();
  }

  // ---------- 专项练习选题 ----------

  void openPracticePicker() {
    state = state.copyWith(
      showPracticePicker: true,
      practiceEmpty: false,
      practiceSubjectFilter: null,
      practiceTypeFilter: null,
      practiceCauseFilter: '全部',
      practiceCount: 10,
      practiceRandom: true,
    );
  }

  void closePracticePicker() {
    state = state.copyWith(showPracticePicker: false, practiceEmpty: false);
  }

  /// 专项练习空状态“返回选题页”：只清掉空状态，留在选题页改范围，
  /// 不关掉选题页回列表。
  void dismissPracticeEmpty() {
    state = state.copyWith(practiceEmpty: false);
  }

  void setPracticeSubjectFilter(String? v) {
    state = state.copyWith(practiceSubjectFilter: v);
  }

  void setPracticeTypeFilter(String? v) {
    state = state.copyWith(practiceTypeFilter: v);
  }

  void setPracticeCauseFilter(String v) {
    state = state.copyWith(practiceCauseFilter: v);
  }

  void setPracticeCount(int v) {
    state = state.copyWith(practiceCount: v);
  }

  void setPracticeRandom(bool v) {
    state = state.copyWith(practiceRandom: v);
  }

  /// 开始专项练习：所选范围无题时显示专项练习空状态，不进入空白会话。
  Future<void> startPracticeSession() async {
    if (state.resume != null) {
      // 已有未完成会话（到期复习或专项练习）时不直接覆盖单行表
      // review_state：页面 _startPractice 已先二选一；这里是兜底，
      // 防从错题本批量开专项练习时丢掉正式复习的断点。
      return;
    }
    // P3：用户在选题页明确新开练习，挂起的待开题单作废。
    state = state.copyWith(
      pendingPracticeIds: const [],
      pendingPracticeCount: null,
    );
    final questions = _buildPracticeSessionQuestions();
    if (questions.isEmpty) {
      state = state.copyWith(practiceEmpty: true);
      return;
    }
    final sessionId = newReviewUuid('sess');
    _enterSession(
      questions: questions,
      sessionId: sessionId,
      mode: ReviewMode.practice,
      startIndex: 0,
      scopeLabel: '专项练习',
    );
    await _persistCurrentSession();
  }

  /// P3 入口 1/3：用一批指定题 id 开专项练习（只练不排，不碰 FSRS）。
  ///
  /// - 去重 + 只留已整理未归档的题；数量 [count] <= 0 或空表示全部，
  ///   否则按 [pickPracticeQuestions] 随机抽取（同一知识点尽量不连续集中）；
  /// - 已有未完成会话（[ReviewState.resume] 非空，或正处会话中）时
  ///   不覆盖单行表 review_state：把题单挂起（pendingPracticeIds），
  ///   返回 [PracticeStartOutcome.blockedByResume]，旧会话断点保留，
  ///   用户在恢复条上选“放弃上次会话”后按挂起的题单开练；
  /// - 无可练的题时返回 [PracticeStartOutcome.empty]，不开空白会话。
  Future<PracticeStartOutcome> startPracticeWithIds(
    List<String> questionIds, {
    int? count,
    Random? random,
  }) async {
    final seen = <String>{};
    final candidates = <Question>[];
    for (final id in questionIds) {
      if (!seen.add(id)) continue;
      final q = state.questionOf(id);
      if (q == null || !q.isOrganized || q.isArchived) continue;
      candidates.add(q);
    }
    if (candidates.isEmpty) return PracticeStartOutcome.empty;
    if (state.resume != null || state.inSession) {
      state = state.copyWith(
        pendingPracticeIds: candidates.map((q) => q.id).toList(),
        pendingPracticeCount: count,
      );
      return PracticeStartOutcome.blockedByResume;
    }
    final picked = pickPracticeQuestions(
      candidates: candidates,
      count: count ?? 0,
      random: random,
    );
    if (picked.isEmpty) return PracticeStartOutcome.empty;
    final questions = _sessionQuestionsForIds(
      picked.map((q) => q.id).toList(),
    );
    if (questions.isEmpty) return PracticeStartOutcome.empty;
    final sessionId = newReviewUuid('sess');
    _enterSession(
      questions: questions,
      sessionId: sessionId,
      mode: ReviewMode.practice,
      startIndex: 0,
      scopeLabel: '专项练习（${questions.length} 道）',
    );
    await _persistCurrentSession();
    return PracticeStartOutcome.started;
  }

  /// 指定题单建队：错因取该题待治记录（无记录时取题面错因），
  /// 顺序按调用方给定的题单（抽题/去重由 [pickPracticeQuestions] 定）。
  List<SessionQuestionState> _sessionQuestionsForIds(List<String> ids) {
    final recordsByQ = <String, List<CauseRecord>>{};
    for (final r in state.allCauseRecords) {
      (recordsByQ[r.questionId] ??= []).add(r);
    }
    final out = <SessionQuestionState>[];
    for (final id in ids) {
      final q = state.questionOf(id);
      if (q == null) continue;
      final causes = recordsByQ[id]?.map((r) => r.cause).toList();
      out.add(
        SessionQuestionState(
          questionId: id,
          causes: (causes == null || causes.isEmpty)
              ? q.allCauses
              : causes,
          nonRoundCauses: const [],
          answerVersionAtStart: q.answerVersion,
          contentVersionAtStart: q.contentVersion,
          questionSubmissionId: newReviewUuid('qs'),
          attemptSubmissionId: newReviewUuid('attsub'),
        ),
      );
    }
    return out;
  }

  // ---------- P3 入口 2：练习小结收错题 ----------

  /// 小结收题默认勾选（本轮小结首次展示时调一次，按 sessionId 隔离）：
  /// 系统确认答错的题默认全勾（已在池的除外，默认不勾）；未判分的题
  /// 另列、可勾，默认不勾。已在池的题在界面上标“已在复习”。
  void initSummaryCollect() {
    if (state.sessionId == null ||
        state.sumCollectSessionId == state.sessionId) {
      return;
    }
    final wrong = state.sumWrongQuestionIds
        .where((id) => !state.fsrsPoolIds.contains(id))
        .toSet();
    state = state.copyWith(
      sumCollectSessionId: state.sessionId,
      sumCollectSelected: wrong,
      sumCollectApplied: const {},
      sumCollectMessage: null,
    );
  }

  /// 小结收题里勾选 / 取消勾选一道题（已在池的题界面上禁用，不进这里）。
  void toggleSummaryCollect(String questionId, bool selected) {
    final next = {...state.sumCollectSelected};
    if (selected) {
      next.add(questionId);
    } else {
      next.remove(questionId);
    }
    state = state.copyWith(sumCollectSelected: next);
  }

  /// 小结收题“加入复习”：只对当前勾选的题批量入池（共用
  /// [QuestionRepository.joinFsrsPool]，只建新卡，不把本次专项练习的
  /// 错当作正式 FSRS 历史事件——下次正式复习才产生第一次 Again/Good）。
  /// 同一轮重复进小结不重复建卡：已在池的题本次跳过（计数里报跳过数）。
  /// 返回结果文案；做完刷新池内标记。
  Future<String> collectSummaryWrong() async {
    final ids = state.sumCollectSelected
        .where(
          (id) =>
              state.sumWrongQuestionIds.contains(id) ||
              state.sumUngradedQuestionIds.contains(id),
        )
        .toList();
    final qs = <Question>[];
    var missing = 0;
    for (final id in ids) {
      final q = state.questionOf(id);
      if (q == null) {
        missing++;
      } else {
        qs.add(q);
      }
    }
    final repo = _repo;
    final scheduler = ref.read(reviewSchedulerProvider);
    final result = await repo.joinFsrsPool(
      questions: qs,
      scheduler: scheduler,
    );
    Set<String> poolIds = state.fsrsPoolIds;
    try {
      poolIds = await scheduler.pooledQuestionIds();
    } catch (_) {
      // 读不到就沿用旧标记，不影响已写入的卡片。
    }
    if (!_disposed) {
      state = state.copyWith(
        fsrsPoolIds: poolIds,
        sumCollectApplied: {
          ...state.sumCollectApplied,
          ...ids.where(poolIds.contains),
        },
      );
    }
    final message = fsrsBatchMessage(
      FsrsBatchOutcome(
        added: result.added,
        skipped: result.skipped,
        failed: result.failed,
        missing: missing,
      ),
    );
    if (!_disposed) state = state.copyWith(sumCollectMessage: message);
    return message;
  }

  // ---------- 会话：暂停 / 返回 ----------

  Future<void> pauseSession() async {
    await _persistCurrentSession();
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

  // ---------- 会话内单题操作 ----------

  void _updateCurrent(SessionQuestionState updated) {
    final questions = [...state.sessionQuestions];
    questions[state.sessionIndex] = updated;
    state = state.copyWith(sessionQuestions: questions);
  }

  /// 点选选项（提交前可改选；提交后锁定，不可改选）。
  void selectOption(String label) {
    if (!state.hasCurrentQuestion) return;
    final sq = state.currentSessionQuestion;
    // 提交进核对步后锁定，不可改选（P2：attempt 只在核对提交时才写，
    // 锁的依据是阶段，不再是 attemptId）。
    if (sq.stage == SessionStage.check || sq.stage == SessionStage.done) {
      return;
    }
    final q = state.currentQuestion;
    if (q == null) return;
    if (q.questionType == 'choice_multi' ||
        q.questionType == 'choice_variable') {
      // 显式 <String>：不写时 [...(selected ?? const [])] 推断成
      // List<dynamic>，copyWith 里 `as List<String>?` 会抛。
      final current = <String>[...(sq.selected ?? const [])];
      if (current.contains(label)) {
        current.remove(label);
      } else {
        current.add(label);
      }
      _updateCurrent(sq.copyWith(selected: current));
    } else {
      _updateCurrent(sq.copyWith(selected: [label]));
    }
  }

  void toggleNotesShown() {
    if (!state.hasCurrentQuestion) return;
    final sq = state.currentSessionQuestion;
    _updateCurrent(sq.copyWith(notesShown: !sq.notesShown));
  }

  /// 提交客观答案（选择/判断）：点选 → 提交 → 锁定并进核对步。
  /// P2：这里只在内存里记下选择与判分结果，不写库、不计小结；
  /// 正式记录 + FSRS 调度统一由核对页的 [submitCheck] 一次提交。
  /// 返回 false 表示本次未提交（未选选项/已进核对步）。
  Future<bool> submitObjectiveAnswer() async {
    if (!state.hasCurrentQuestion || state.sessionId == null) return false;
    final sq = state.currentSessionQuestion;
    if (sq.stage == SessionStage.check || sq.stage == SessionStage.done) {
      return false;
    }
    final q = state.currentQuestion;
    if (q == null) return false;
    final selected = sq.selected;
    if (selected == null || selected.isEmpty) return false;
    if (selected.length != 1) return false;
    final correct = gradeObjective(q, selected.single);
    _updateCurrent(
      sq.copyWith(correct: correct, stage: SessionStage.check),
    );
    await _persistCurrentSession();
    return true;
  }

  /// 多选/不定项只记录选择（不自动判分，correct=NULL），进核对步。
  /// P2：只在内存里记下选择，不写库；正式记录由 [submitCheck] 提交。
  Future<bool> submitMultiAnswer() async {
    if (!state.hasCurrentQuestion || state.sessionId == null) return false;
    final sq = state.currentSessionQuestion;
    if (sq.stage == SessionStage.check || sq.stage == SessionStage.done) {
      return false;
    }
    final q = state.currentQuestion;
    if (q == null) return false;
    final selected = sq.selected;
    if (selected == null || selected.isEmpty) return false;
    _updateCurrent(
      sq.copyWith(correct: null, stage: SessionStage.check),
    );
    await _persistCurrentSession();
    return true;
  }

  /// 纸上作答完成（标签未确认的选择题、填空/计算/证明等）：点
  /// “我已完成作答” → 显示标准答案/解析 → 核对。P2：只切段，
  /// 不写 attempts；正式记录由 [submitCheck] 提交（correct=NULL）。
  Future<bool> completePaperAnswer() async {
    if (!state.hasCurrentQuestion || state.sessionId == null) return false;
    final sq = state.currentSessionQuestion;
    if (sq.stage == SessionStage.check || sq.stage == SessionStage.done) {
      return false;
    }
    final q = state.currentQuestion;
    if (q == null) return false;
    _updateCurrent(sq.copyWith(stage: SessionStage.check));
    await _persistCurrentSession();
    return true;
  }


  /// P2 核对提交：本轮唯一正式提交入口。
  ///
  /// 四步收拢在一处（实施方案 v2 §4）：
  /// ① 写一条正式复习客观对错记录（attempts；correct 为 null =
  ///    无法判分，绝不把未判分写成 false；专项练习同样写 attempts，
  ///    但不参与 FSRS）；② 到期复习且可判分时调
  ///    [ReviewScheduler.recordAnswer]（Again/Good）；③ 卡状态保
  ///    存（recordAnswer 内完成）；④ 下次到期时间由卡的 due 导出，
  ///    记入小结（取本轮最早的一道）。
  ///
  /// 幂等：eventId 就是本题稳定的 attemptSubmissionId（建队时生成
  /// 一次、存进 review_state，恢复重放沿用，重复点击不重生成）；
  /// P1 的 recordAnswer 按 eventId 去重；attempts 写库按
  /// UNIQUE(session_id, question_id) 更新同一行。重复调用
  /// （重复点击 / 崩溃恢复重放）靠 checkSubmitted 短路：不重写、
  /// 不重计分，直接进下一题。
  ///
  /// P5 事务双写（GPT P0-4）：①②③④在同一 SQLite 事务内完成
  /// （[QuestionRepository.submitReviewCheck]）：attempts 行、
  /// fsrs_cards 行、事件账本（eventId 已处理标记）同生同灭；
  /// 任一步失败整笔回滚，调用方重试仍用同一 eventId。P2 报告的窗口
  /// （recordAttempt 成功后、recordAnswer 成功前崩溃，重试重复推进）
  /// 由此消除：崩溃时事务没提交，attempts 与卡片都没有新状态，
  /// 重试是第一次提交，不是第二次推进。
  Future<bool> submitCheck() async {
    if (!state.hasCurrentQuestion ||
        state.sessionId == null ||
        state.submitting) {
      return false;
    }
    final sq = state.currentSessionQuestion;
    if (sq.stage != SessionStage.check) return false;
    if (sq.checkSubmitted) {
      // 已提交（重复点击 / 恢复重放）：不重写、不重计分，直接下一题。
      await _advanceQuestion();
      return true;
    }
    final q = state.currentQuestion;
    if (q == null) return false;
    final sessionId = state.sessionId!;
    final mode = state.sessionMode ?? ReviewMode.due;
    final isPractice = state.isPracticeSession;
    final now = DateTime.now();
    state = state.copyWith(submitting: true, saveError: false);
    try {
      final repo = _repo;
      // P5：attempts + FSRS + 事件账本同一事务提交（见 submitReviewCheck）。
      // 专项练习或无法判分时 result 为 null：只写 attempts，不推进 FSRS。
      final attempt = AttemptData(
        id: newReviewUuid('att'),
        questionId: q.id,
        sessionId: sessionId,
        mode: mode,
        selected: sq.selected,
        correct: sq.correct,
        confidence: null,
        answerVersion: q.answerVersion,
        contentVersion: q.contentVersion,
        status: sq.selected != null ? '已提交' : '已完成作答',
        causeIds: sq.causes,
        submissionId: sq.attemptSubmissionId,
        createdAt: now.millisecondsSinceEpoch,
      );
      final submitted = await repo.submitReviewCheck(
        attempt: attempt,
        result: !isPractice && sq.correct != null
            ? (sq.correct == 1 ? ReviewResult.good : ReviewResult.again)
            : null,
        reviewedAt: now,
        eventId: sq.attemptSubmissionId,
        scheduler: ref.read(reviewSchedulerProvider),
      );
      final attemptId = submitted.attemptId;
      final nextDue = submitted.nextDue;
      if (_disposed) return false;
      // 小结计数只在这里计一次（重复提交走上面的短路）。
      final weakKp = Map<String, int>.from(state.sumWeakKp);
      if (sq.correct == 0) {
        for (final kp in q.knowledgePointIds) {
          weakKp[kp] = (weakKp[kp] ?? 0) + 1;
        }
      }
      final earliestNextDue = nextDue == null
          ? state.sumNextDueDate
          : (state.sumNextDueDate == null ||
                  nextDue.isBefore(state.sumNextDueDate!))
              ? nextDue
              : state.sumNextDueDate;
      _updateCurrent(
        sq.copyWith(
          attemptId: attemptId,
          stage: SessionStage.done,
          checkSubmitted: true,
        ),
      );
      state = state.copyWith(
        submitting: false,
        sumCompleted: state.sumCompleted + 1,
        sumHandled: state.sumHandled + (isPractice ? 0 : sq.causes.length),
        sumObjCorrect: state.sumObjCorrect + (sq.correct == 1 ? 1 : 0),
        sumObjWrong: state.sumObjWrong + (sq.correct == 0 ? 1 : 0),
        sumUngraded: state.sumUngraded + (sq.correct == null ? 1 : 0),
        sumWeakKp: weakKp,
        sumNextDueDate: earliestNextDue,
      );
      await _persistCurrentSession();
      await _advanceQuestion();
      return true;
    } catch (_) {
      if (_disposed) return false;
      state = state.copyWith(submitting: false, saveError: true);
      return false;
    }
  }

  /// 看题 → 作答（只切段，不创建 attempt；作答提交时才建）。
  void beginAnswer() {
    if (!state.hasCurrentQuestion) return;
    final sq = state.currentSessionQuestion;
    if (sq.stage != SessionStage.view) return;
    _updateCurrent(sq.copyWith(stage: SessionStage.answer));
    unawaited(_persistCurrentSession());
  }

  /// 已核对提交后的过渡态（恢复后遇到已提交的题时出现）：
  /// 直接进下一题（或小结）。
  Future<void> advanceToNextQuestion() async {
    if (!state.hasCurrentQuestion) return;
    await _advanceQuestion();
  }

  /// 从详情页返回会话（M3-4 补全标签跳转，P2-3）：沿用当前 session_id；
  /// 保留当前题目位置、队列顺序、跳过次数和已有会话状态；不创建新会话；
  /// 当前题目尚未作答 → 更新 answer_version_at_start 为新版本
  /// （只适用于当前尚未作答的题目本身的快照，不覆盖历史 attempts，
  /// 不改动其他已作答题目的快照）；不生成 attempt，不写
  /// review_history，不计入跳过次数；不让用户再经历一次
  /// “继续上次会话/放弃重开”的选择。
  Future<void> refreshAfterDetailVisit() async {
    if (!state.hasCurrentQuestion) return;
    final sq = state.currentSessionQuestion;
    if (sq.stage == SessionStage.check || sq.stage == SessionStage.done) {
      return;
    }
    final repo = _repo;
    final questions = await repo.all(includeArchived: true);
    Question? fresh;
    for (final q in questions) {
      if (q.id == sq.questionId) {
        fresh = q;
        break;
      }
    }
    if (fresh == null || _disposed) return;
    _updateCurrent(
      sq.copyWith(
        answerVersionAtStart: fresh.answerVersion,
        contentVersionAtStart: fresh.contentVersion,
        stage: SessionStage.view,
        selected: null,
        correct: null,
      ),
    );
    await _persistCurrentSession();
    await load();
  }

  /// 专项练习“将此错因重新加入复习”（用户主动操作，只影响后续会话，
  /// 不改变本次练习记录，不自动触发治疗状态变化）。
  Future<void> rejoinCauseFromPractice(String cause) async {
    if (!state.hasCurrentQuestion) return;
    final q = state.currentQuestion;
    if (q == null) return;
    await _repo.rejoinCause(
      questionId: q.id,
      cause: cause,
      subjectId: q.subjectId,
    );
    if (_disposed) return;
    state = state.copyWith(
      rejoinNotice: '「$cause」已重新加入复习，下次到期复习时会练到它',
    );
    await load();
  }

  Future<void> _advanceQuestion() async {
    final next = state.sessionIndex + 1;
    if (next >= state.sessionQuestions.length) {
      await _finishSession();
      return;
    }
    state = state.copyWith(sessionIndex: next);
    await _restoreAttemptStatusForCurrent();
    await _persistCurrentSession();
  }

  /// 跳过后重遇：已有 attempt 的题，attempt 状态恢复为作答前状态
  /// （已提交/已完成作答），不改变已提交的作答结果。
  Future<void> _restoreAttemptStatusForCurrent() async {
    if (!state.hasCurrentQuestion) return;
    final sq = state.currentSessionQuestion;
    if (sq.attemptId == null) return;
    final repo = _repo;
    final attempt = await repo.loadAttempt(
      sessionId: state.sessionId ?? '',
      questionId: sq.questionId,
    );
    if (attempt == null || attempt.status != '跳过') return;
    final isObjective =
        sq.selected != null && state.currentQuestion != null;
    await repo.recordAttempt(
      attempt.copyWith(
        status: isObjective ? '已提交' : '已完成作答',
      ),
    );
  }

  /// 跳过（M3-9）：各阶段均可点；第一次移到队尾，第二次留到下次；
  /// 单题队列直接留到下次；不写 verdict、不改进度、不改复查日；
  /// 跳过不回滚已经提交的 attempts 与已显示的结果。
  Future<void> skipCurrent() async {
    if (!state.hasCurrentQuestion || state.sessionId == null) return;
    final repo = _repo;
    final sq = state.currentSessionQuestion;
    final newSkips = sq.skips + 1;
    final remaining = state.sessionQuestions
        .where((e) => !e.deferred)
        .length;
    final action = skipDecision(
      queueLength: remaining,
      skips: sq.skips,
    );
    // 已有 attempt 的题：attempt 标记为曾被跳过（重遇时恢复）。
    if (sq.attemptId != null) {
      final attempt = await repo.loadAttempt(
        sessionId: state.sessionId!,
        questionId: sq.questionId,
      );
      if (attempt != null && attempt.status != '跳过') {
        await repo.recordAttempt(attempt.copyWith(status: '跳过'));
      }
    }
    if (_disposed) return;
    final questions = [...state.sessionQuestions];
    if (action == SkipAction.defer) {
      // 第二次跳过（或单题队列）：移出本次会话，留到下次。
      questions.removeAt(state.sessionIndex);
      state = state.copyWith(
        sessionQuestions: questions,
        sumSkipped: state.sumSkipped + 1,
        sumDeferred: state.sumDeferred + 1,
      );
      await _persistCurrentSession();
      if (state.sessionIndex >= questions.length) {
        await _finishSession();
      } else {
        await _restoreAttemptStatusForCurrent();
        await _persistCurrentSession();
      }
      return;
    }
    // 第一次跳过：移到当前队列末尾（保留原题状态，不重新给答题机会）。
    final moved = sq.copyWith(skips: newSkips);
    questions.removeAt(state.sessionIndex);
    questions.add(moved);
    state = state.copyWith(
      sessionQuestions: questions,
      sumSkipped: state.sumSkipped + 1,
    );
    await _restoreAttemptStatusForCurrent();
    await _persistCurrentSession();
  }

  Future<void> _finishSession() async {
    final repo = _repo;
    await repo.clearReviewState();
    if (_disposed) return;
    final elapsed = state.sessionStartedAt == null
        ? 0
        : DateTime.now().difference(state.sessionStartedAt!).inSeconds;
    state = state.copyWith(
      sumElapsedSeconds: elapsed,
      showSummary: true,
    );
    await load();
  }
}
