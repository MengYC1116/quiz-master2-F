// ARCH-PLAN-A 第 3 阶段：整理页的状态层。
//
// 状态是 [OrganizeState]（队列 + 表单 + 元数据），唯一真源仍是 SQLite；
// 本 Provider 只做“响应式读取 + 写回”，不另存一份。
// 读：`ref.watch(organizeProvider)`；
// 写：`ref.read(organizeProvider.notifier).confirmCurrent(...)` 等。
//
// 队列 + 批量条的操作（批量确认 / 打标签 / 加文件夹 / 删除）也收进
// 本 Notifier——队列弹出层是 OverlayEntry，它的 build 上下文不在页面
// 嵌套 ProviderScope 之内，拿不到 ref；弹出层经构造器接 Notifier 实例
// 与打开时的元数据快照（folders / exams / subjects / allTags），
// 只留纯界面状态在本地（勾选、搜索、排序、内联菜单、确认框）。
// 弹出层自己的 `_questions` 快照同步（SR2-5 / SR3-15）仍在弹出层里，
// Notifier 的批量方法只返回“哪些保存成功 / 拦下几道”，不同步快照。
//
// 表单文本框（答案 / 解析 / 笔记）的控制器是页面本地 UI 状态，
// 留在页面里；切题 / 刷新时 Notifier 把 `formResetKey` 加一，
// 页面按它变化、下一帧把控制器文本按当前题重建
// （原 `_loadForm` 里设控制器文本 + 收起内联新建框的部分，
// 见 `organize_page.dart` 的 `_syncFormFromState`）。
// 手风琴开合、知识点章节展开、内联新建框的展开态是纯界面状态，
// 留页面本地 setState，不进 Provider。
//
// Provider 是 autoDispose（D-36 结论）：页面独占、随页生死，
// 回页重建并重读库。`build()` 里 `Future.microtask(refresh)` 首查
// + `_disposed` 守门（沿用 Stage 2/3 模式）。
//
// 整理页没有初始入参（构造器只有 repo 与四个回调），所以没有
// `organizeInitialProvider`——需要初始参数时才按
// `wrongbookInitialProvider` 模式加（D-35），本次不需要。
//
// 构造器接进来的 `repo` 怎么进依赖图：`OrganizePage` 在 build 里包
// 一层 `ProviderScope(overrides: [repositoryProvider
// .overrideWithValue(widget.repo)])`——`app.dart` 仍按老样子传，
// 不用改；测试里构造器传 FakeRepo 同样经这一层注入，不用再包
// 一层 ProviderScope。本文件不认识任何 widget，不碰 `BuildContext`、
// 不弹 Dialog、不调导航。角标走 `badgeCountsProvider`（第 4 阶段：
// 订阅 `DataChangeBus`，见 `badge_counts_provider.dart`）。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/data_change_events.dart';
import '../data/database.dart';
import '../data/repository.dart';
import '../models/models.dart';
import '../modules/ocr/question_classifier.dart';
import '../modules/ocr/stem_correction.dart';
import '../services/glm_ocr_client.dart';
import '../services/ocr_queue.dart';
import 'repository_provider.dart';
import 'review_notifier.dart';
import 'subject_sort.dart';

/// 整理页业务状态的 Provider：页面出现即读库（见 [OrganizeNotifier.build]）。
/// FR-19：声明 `dependencies: [repositoryProvider]`（D-49 同款，见
/// homeProvider 注释）。
final organizeProvider =
    NotifierProvider.autoDispose<OrganizeNotifier, OrganizeState>(
      OrganizeNotifier.new,
      dependencies: [repositoryProvider, reviewSchedulerProvider],
    );

/// 整理页学科排序的学科名来源见 `_sorted`（FR-08：与错题本共用
/// `subject_sort.dart` 的拼音表版实现，不再按 id 写死三科）。

/// `copyWith` 里“显式置 null”与“不改”的区分标记。
const _unset = Object();

/// 整理页的全部业务数据 + 队列 / 表单状态（原 `_OrganizePageState`
/// 里调 `repo` 的字段与表单值原样搬移；手风琴开合、知识点章节展开、
/// 内联新建展开态、文本控制器仍在页面本地，不在这里）。
class OrganizeState {
  const OrganizeState({
    this.queue = const [],
    this.index = 0,
    this.sort = 'timeDesc',
    this.loading = true,
    this.hasAnyQuestion = false,
    this.organizedToday = 0,
    this.toReviewCount = 0,
    this.folders = const [],
    this.exams = const [],
    this.kps = const [],
    this.allTags = const [],
    this.customTypesAll = const [],
    this.subjects = const [],
    this.folderIds = const [],
    this.examId,
    this.kpIds = const [],
    this.errorTypes = const [],
    this.customTypes = const [],
    this.tags = const [],
    // 十四批 M1：表单里的题型值（NULL = 待确认；loadForm 时从当前题读）。
    this.questionType,
    // 十四批 M3：表单里的选项标签值（loadForm 时从当前题读）。
    this.optionLabels,
    this.optionLabelsConfirmed = false,
    this.correctOption,
    this.answerReconfirmed = false,
    this.optionLabelsJustConfirmed = false,
    // Win11 反馈包 5：表单里的选项文字（标签映射；loadForm 时从当前题读）。
    this.optionContents,
    this.formResetKey = 0,
    // 十三批 M5：当前题的 OCR 任务行与 key 有无（识别题干状态推导用）。
    this.ocrJobs = const [],
    this.hasOcrApiKey = false,
    // WP-B #3/#4/#5（REV5）：全局刷新代次与表单绑定题 id。
    this.generation = 0,
    this.loadedQuestionId,
  });

  /// 待整理队列（未整理、未归档）。
  final List<Question> queue;

  /// 当前题下标。
  final int index;

  /// 队列排序：timeDesc / timeAsc / subjectAsc / subjectDesc。
  final String sort;

  /// 首查进行中（原 `_loading`；初始 true，首帧先出加载圈）。
  final bool loading;

  /// 库里是否已有题（空状态分两种用：从未有题 / 队列已空）。
  final bool hasAnyQuestion;

  // B11-10 今日小结：队列已空时空状态显示的两个数。
  final int organizedToday;
  final int toReviewCount;

  /// 当前题所属学科的文件夹（`_loadFolders` 读的）。
  final List<Folder> folders;
  final List<Exam> exams;
  final List<KnowledgePoint> kps;
  final List<String> allTags;

  /// 全库自定义错因（去重后，供分类区芯片用）。
  final List<String> customTypesAll;

  /// 学科表：读库 subjects（P0B1 扫尾；以前直接 Subject.byId，
  /// 新学科显示成“数学”）。B8-1 扫尾：空表是删光学科后的合法状态，
  /// 不再回退预设三科；首帧与读库后都以真实列表为准，空就是空。
  final List<Subject> subjects;

  // ---- 表单值（当前题；文本框内容在页面控制器里，不在这里） ----

  final List<String> folderIds;
  final String? examId;
  final List<String> kpIds;
  final List<String> errorTypes;
  final List<String> customTypes;
  final List<String> tags;

  /// 十四批 M1：表单里的题型值（NULL = 待确认）。
  final String? questionType;

  // 十四批 M3：表单里的选项标签值（loadForm 时从当前题读；null = 未确认）。
  // optionLabelsConfirmed：表单里的确认态；correctOption：表单里的
  // 正确选项（仅单选/判断用）；answerReconfirmed：本次编辑是否已重确认
  // 答案（P1-A 信号，保存后清零）；optionLabelsJustConfirmed：本次保存
  // 就是确认保存（「确认选项」按的，保存后清零）。
  final List<String>? optionLabels;
  final bool optionLabelsConfirmed;
  final String? correctOption;
  final bool answerReconfirmed;
  final bool optionLabelsJustConfirmed;

  /// Win11 反馈包 5：表单里的选项文字（标签 → 文字；null = 未解析/
  /// 不显示）。loadForm 时从当前题读（仅切分成功时显示，见页面）。
  final Map<String, String>? optionContents;

  /// 表单重置代次：每次 `_loadForm` 加一，页面按它变化、下一帧把
  /// 控制器文本按当前题重建并收起内联新建框（原 `_loadForm` 里
  /// 设控制器文本 + 收框的部分）。
  final int formResetKey;

  /// 十三批 M5：当前题的 OCR 任务行（最新在前）与设置里是否已存
  /// BigModel key。只供识别题干状态推导（[OcrStemSection]）用；
  /// 刷新它们绝不碰表单值与 formResetKey（见 [_refreshOcrStatus]）。
  final List<OcrJob> ocrJobs;
  final bool hasOcrApiKey;

  /// WP-B #3/#4/#5：全局刷新代次。任何替换队列或改变 current 的
  /// 操作开头 +1（见 R3-3）；某代次开始的异步任务在代次变化后完成
  /// 时一律作废（以代次校验为准）。`refreshOcrForQuestion` 不碰它
  ///（只用每题 `_ocrRefreshVersions`）。
  final int generation;

  /// WP-B #3/#4/#5：表单当前载入的是哪道题。`loadForm()` 结束时置
  /// 为 `current.id`；队列为空 / `current == null` / 切题尚未加载
  /// 新表单时强制 null。不变量：任何时刻 current.id 必须属于当前
  /// 有效队列，表单必须绑定 current.id。
  final String? loadedQuestionId;

  Question? get current =>
      queue.isEmpty ? null : queue[index.clamp(0, queue.length - 1)];

  List<String> get orderIds => queue.map((q) => q.id).toList();

  /// 库里找学科：新学科用库里的名与色；找不到才回退 Subject.byId
  ///（数学兜底，只发生在数据不一致时）。
  Subject subjectOf(String id) =>
      subjects.firstWhere((s) => s.id == id, orElse: () => Subject.byId(id));

  /// 文件夹显示名：子文件夹显示“父名 / 子名”。
  String folderDisplayName(Folder folder) {
    if (folder.parentId == null) return folder.name;
    final parent = folders.firstWhere(
      (f) => f.id == folder.parentId,
      orElse: () => folder,
    );
    return parent.id == folder.id
        ? folder.name
        : '${parent.name} / ${folder.name}';
  }

  /// 按当前表单值 + 文本框内容拼出要保存的题（原 `_formQuestion`）。
  Question formQuestion(
    Question q, {
    required String answer,
    required String explanation,
    required String notes,
    bool organized = false,
  }) {
    final a = answer.trim();
    final e = explanation.trim();
    final n = notes.trim();
    // 十四批 M3：correct_option 只用于单选/判断（M3-4）——表单题型
    // 不是这两者时（多选/不定项/填空/待确认…），正确选项强制为空，
    // 不把旧单选题的 correct_option 带到新题型下。
    final effectiveCorrect =
        (questionType == 'choice_single' ||
            questionType == 'true_false')
        ? correctOption
        : null;
    // Win11 反馈包 5：题型改成判断题时选项文字清空（判断题固定
    // “正确/错误”，不走选项解析）。
    final effectiveContents =
        questionType == 'true_false' ? null : optionContents;
    // SR-P2-27：保存兜底——表单里万一还有与固定枚举同名的自定义项
    //（如别处入口带进来的旧数据），合并进固定项再写库，不丢、不重复。
    final fixedTypes = {
      ...errorTypes,
      ...customTypes.where((t) => ErrorTypes.fixed.contains(t)),
    }.toList();
    final customOnly = customTypes
        .where((t) => !ErrorTypes.fixed.contains(t))
        .toList();
    return q.copyWith(
      folderIds: folderIds,
      examId: examId,
      knowledgePointIds: kpIds,
      errorTypes: fixedTypes,
      customErrorTypes: customOnly,
      tags: tags,
      answer: a.isEmpty ? null : a,
      explanation: e.isEmpty ? null : e,
      notes: n.isEmpty ? null : n,
      // 选了「未归属试卷」且原题有试卷时才真正清空（基线 copyWith
      // 里 examId 传 null 表示“保持原值”，不处理就清不掉）。
      clearExamId: examId == null && q.examId != null,
      clearAnswer: a.isEmpty,
      clearExplanation: e.isEmpty,
      clearNotes: n.isEmpty,
      isOrganized: organized ? true : q.isOrganized,
      // 十四批 M3：选项标签表单值（copyWith 里传 null 表示“保持原值”，
      // 清空要走 clear 标志；多选/不定项的 correctOption 恒为 NULL，
      // 由页面只在单选/判断时给值——这里只按表单值写，不另做题型校验，
      // 校验在数据层 _applyOptionLabelChangeRules 与判分入口做）。
      optionLabels: optionLabels,
      clearOptionLabels: optionLabels == null && q.optionLabels != null,
      optionLabelsConfirmed: optionLabelsConfirmed,
      correctOption: effectiveCorrect,
      clearCorrectOption:
          effectiveCorrect == null && q.correctOption != null,
      // Win11 反馈包 5：选项文字表单值（copyWith 里传 null 表示
      // “保持原值”，清空要走 clear 标志；删标签的键剪枝由数据层
      // _applyOptionLabelChangeRules 再做一遍）。题型改成判断题时
      // 选项文字清空（判断题固定“正确/错误”，不走选项解析）。
      optionContents: effectiveContents,
      clearOptionContents:
          effectiveContents == null && q.optionContents != null,
      answerReconfirmed: answerReconfirmed,
      optionLabelsJustConfirmed: optionLabelsJustConfirmed,
    );
  }

  /// 十四批 M1：表单里的题型改动（改后写 source=manual；值不变时
  /// 不碰来源保护位——切题自动保存不得把自动分类静默锁成人工）。
  Question formQuestionWithType(Question base) {
    if (questionType == base.questionType) return base;
    return withManualQuestionType(base, questionType);
  }

  OrganizeState copyWith({
    List<Question>? queue,
    int? index,
    String? sort,
    bool? loading,
    bool? hasAnyQuestion,
    int? organizedToday,
    int? toReviewCount,
    List<Folder>? folders,
    List<Exam>? exams,
    List<KnowledgePoint>? kps,
    List<String>? allTags,
    List<String>? customTypesAll,
    List<Subject>? subjects,
    List<String>? folderIds,
    Object? examId = _unset,
    List<String>? kpIds,
    List<String>? errorTypes,
    List<String>? customTypes,
    List<String>? tags,
    Object? questionType = _unset,
    Object? optionLabels = _unset,
    bool? optionLabelsConfirmed,
    Object? correctOption = _unset,
    bool? answerReconfirmed,
    bool? optionLabelsJustConfirmed,
    Object? optionContents = _unset,
    int? formResetKey,
    List<OcrJob>? ocrJobs,
    bool? hasOcrApiKey,
    int? generation,
    Object? loadedQuestionId = _unset,
  }) {
    // R3-4：队列为空 → loadedQuestionId 强制 null（current 为 null
    // 时同理；current 仅在队列为空时为 null）。哨兵区分“设 null”与“不改”。
    final newQueue = queue ?? this.queue;
    final newLoadedQuestionId = loadedQuestionId == _unset
        ? this.loadedQuestionId
        : loadedQuestionId as String?;
    return OrganizeState(
      queue: queue ?? this.queue,
      index: index ?? this.index,
      sort: sort ?? this.sort,
      loading: loading ?? this.loading,
      hasAnyQuestion: hasAnyQuestion ?? this.hasAnyQuestion,
      organizedToday: organizedToday ?? this.organizedToday,
      toReviewCount: toReviewCount ?? this.toReviewCount,
      folders: folders ?? this.folders,
      exams: exams ?? this.exams,
      kps: kps ?? this.kps,
      allTags: allTags ?? this.allTags,
      customTypesAll: customTypesAll ?? this.customTypesAll,
      subjects: subjects ?? this.subjects,
      folderIds: folderIds ?? this.folderIds,
      examId: examId == _unset ? this.examId : examId as String?,
      kpIds: kpIds ?? this.kpIds,
      errorTypes: errorTypes ?? this.errorTypes,
      customTypes: customTypes ?? this.customTypes,
      tags: tags ?? this.tags,
      questionType: questionType == _unset
          ? this.questionType
          : questionType as String?,
      optionLabels: optionLabels == _unset
          ? this.optionLabels
          : optionLabels as List<String>?,
      optionLabelsConfirmed:
          optionLabelsConfirmed ?? this.optionLabelsConfirmed,
      correctOption: correctOption == _unset
          ? this.correctOption
          : correctOption as String?,
      answerReconfirmed: answerReconfirmed ?? this.answerReconfirmed,
      optionLabelsJustConfirmed:
          optionLabelsJustConfirmed ?? this.optionLabelsJustConfirmed,
      optionContents: optionContents == _unset
          ? this.optionContents
          : optionContents as Map<String, String>?,
      formResetKey: formResetKey ?? this.formResetKey,
      ocrJobs: ocrJobs ?? this.ocrJobs,
      hasOcrApiKey: hasOcrApiKey ?? this.hasOcrApiKey,
      generation: generation ?? this.generation,
      loadedQuestionId: newQueue.isEmpty ? null : newLoadedQuestionId,
    );
  }
}

/// 按排序键排队列（原 `_sortQueue` 的比较器原样搬移）。
/// FR-08：学科排序与错题本共用 `subject_sort.dart` 的拼音表版比较
///（`compareSubjectNames`：首字母 → 拼音串 → 原名）；新学科不再
/// 一律落到 'S' 档。`subjects` 是读库的学科表（找不到的 id 回退
/// `Subject.byId`，只发生在数据不一致时）。
List<Question> _sorted(
  List<Question> list,
  String sort,
  List<Subject> subjects,
) {
  final names = {for (final s in subjects) s.id: s.name};
  String nameOf(String id) => names[id] ?? Subject.byId(id).name;
  final sorted = [...list];
  switch (sort) {
    case 'timeAsc':
      sorted.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    case 'subjectAsc':
      sorted.sort((a, b) {
        final c = compareSubjectNames(nameOf(a.subjectId), nameOf(b.subjectId));
        return c != 0 ? c : b.createdAt.compareTo(a.createdAt);
      });
    case 'subjectDesc':
      sorted.sort((a, b) {
        final c = compareSubjectNames(nameOf(b.subjectId), nameOf(a.subjectId));
        return c != 0 ? c : b.createdAt.compareTo(a.createdAt);
      });
    case 'timeDesc':
    default:
      sorted.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }
  return sorted;
}

/// 整理页业务逻辑（ARCH-PLAN-A 第 3 阶段：原 `organize_page.dart`
/// 的 `_OrganizePageState` 里调 `repo` 的部分原样迁入；
/// 页面只留 widget 与本地交互状态——文本控制器、手风琴开合、
/// 知识点章节展开、内联新建展开态、队列弹出层）。
///
/// 拿库的方式与 `ReviewNotifier` 一致：经
/// `ref.read(repositoryProvider)` 拿——测试注入见
/// `docs/ui-replication/A-READING-GUIDE.md`（`ProviderContainer.test`
/// + `repositoryProvider.overrideWithValue`）。
class OrganizeNotifier extends Notifier<OrganizeState> {
  QuestionRepository get _repo => ref.read(repositoryProvider);

  bool _disposed = false;

  /// WP-B #3/#4/#5：每题的单题刷新请求版本号（不进 State、不参与
  /// UI 重建）。同一题两次刷新逆序完成时，旧版本号的任务作废。
  final Map<String, int> _ocrRefreshVersions = {};

  /// Win11 包 4：自动重算已尝试过的输入版本（`classification_input_hash`
  /// 概念的落地：复用现有 `contentVersion` 作输入版本键，`(questionId,
  /// contentVersion)` 一对即一版输入）。同一版本只自动算一次，算过
  /// 就记键——不管结果是 updated 还是 unchanged；强制重算不受此门限。
  final Set<(String, int)> _reclassifiedKeys = {};

  /// S1-1 通用守门：方法入口、第一个 await 之前捕获的三样
  /// （`gen` / `q` / `formId`）在每次 await 返回之后、任何一次
  /// 状态写回或 `repo.save` 之前必须全满足，否则旧任务立即返回，
  /// 什么都不写。只比 id 不够：A 保存启动 → 切 B → 回 A，旧 A
  /// 任务的 id 检查会再次通过，只有 generation 能识别它是旧任务。
  bool _gateOk(int gen, Question? q, String? formId) =>
      !_disposed &&
      gen == state.generation &&
      state.current?.id == q?.id &&
      state.loadedQuestionId == q?.id;

  void _logStale(String where, int gen, Question? q) {
    debugPrint(
      '[OrganizeNotifier] $where 旧任务作废：gen=$gen '
      'currentGen=${state.generation} q=${q?.id} '
      'current=${state.current?.id} loaded=${state.loadedQuestionId}',
    );
  }

  @override
  OrganizeState build() {
    ref.onDispose(() => _disposed = true);
    // 页面出现即读库（原 `initState` 的 `_refresh`）：不 await，
    // 读完后 state 一次性赋值，首帧先出加载圈。
    Future.microtask(refresh);
    return const OrganizeState();
  }

  /// 首读与每次写库后重读（与原来页面的 `_refresh` 同口径）：
  /// 读全部题 → 待整理队列（未整理、未归档）→ 试卷 / 知识点 /
  /// 标签 / 学科表 → 全库自定义错因；队列已空且库里有题时才读
  /// 今日小结两个数（B11-10）。读完先写队列与元数据，再读当前题
  /// 的文件夹、再按当前题重建表单（原 `_refresh` 末尾的
  /// `_loadFolders()` + `_loadForm()`，顺序不变）。
  /// 最近一次 refresh 的 Future 与代次。旧 refresh 因代次旧而中止时，
  /// 等赢的那个 refresh 落完再返回（见 [_awaitNewerRefresh]）。
  Future<void>? _latestRefreshFuture;
  int _latestRefreshGen = -1;

  Future<void> refresh() async {
    // D-42：build() 的 microtask 首查可能在页面已离开、Provider 已销毁后
    // 才跑——先判 _disposed 再碰 ref；repo 入口处捕获一次，之后不再 ref.read。
    if (_disposed) return;
    // R3-3：代次先加（后面的 await 都属于新一代），使此前开始的
    // 单题刷新、保存等旧任务失效；队列重建期间表单失效，先置 null，
    // 结尾 loadForm 再置新 id（R3-4）。此段在第一个 await 之前，
    // 同步执行，不会被交错。
    state = state.copyWith(
      generation: state.generation + 1,
      loadedQuestionId: null,
    );
    final gen = state.generation;
    final future = _refreshBody(gen);
    _latestRefreshFuture = future;
    _latestRefreshGen = gen;
    await future;
  }

  /// 等更新的 refresh 完成再返回。`await refresh()` 的调用方看到的
  /// 一定是已加载完的状态：旧 refresh 因代次旧而中止时不能直接返回
  ///（否则调用方读到空队列/旧表单——build 首查与显式 refresh 并发时
  /// 旧测试就是这样空着失败的）；要等赢的那个 refresh 落完。链式
  /// 等待不会死锁：等待链严格按代次递增，最终停在最新的 refresh 上，
  /// 它从不等待别人；新 refresh 抛错时旧的也只当等待结束（try/catch），
  /// 不把别人的错抛给自己的调用方。
  Future<void> _awaitNewerRefresh(int gen) async {
    final newer = _latestRefreshGen > gen ? _latestRefreshFuture : null;
    if (newer == null) return;
    try {
      await newer;
    } catch (_) {
      // 新 refresh 失败：旧的等待到此为止，直接返回。
    }
  }

  Future<void> _refreshBody(int gen) async {
    final repo = _repo;
    // D-42 同款：调度器入口处一次读出，之后不再 ref.read，中途销毁
    // 也不抛错（首页 / 错题本同款做法）。
    final scheduler = ref.read(reviewSchedulerProvider);
    final all = await repo.all();
    final pending = all.where((q) => !q.isOrganized && !q.isArchived).toList();
    final exams = await repo.exams();
    final kps = await repo.knowledgePoints();
    final tags = await repo.tags();
    final subjects = await repo.subjects();
    final customs = <String>{};
    for (final q in all) {
      customs.addAll(q.customErrorTypes);
    }
    // B11-10 今日小结：队列已空且库里有题时（空状态要显示小结行）才读
    // 两个数；队列非空时空状态不显示，不读。N1 = 今天已整理的题数
    // （settings 键 organizedToday，当天内整理确认的跃迁计数）；
    // N2 = 待复习题数，与首页焦点卡 / 复习角标同一口径
    // （2026-11-26 面 C：旧 `repo.dueToday()` 已删，改读 FSRS 到期题
    // `repo.fsrsDueQuestionIds(scheduler: scheduler).length`；调度器
    // 与首页 / 错题本同源，见 `reviewSchedulerProvider`）。
    var organizedToday = 0;
    var toReview = 0;
    if (pending.isEmpty && all.isNotEmpty) {
      organizedToday = await repo.organizedTodayCount();
      toReview =
          (await repo.fsrsDueQuestionIds(scheduler: scheduler)).length;
    }
    // S1-2 / R3-6：读库期间若有更新的 refresh 开始（代次又加了），
    // 本次旧刷新不把旧队列写回；等赢的 refresh 落完再返回（见上）。
    if (_disposed) return;
    if (gen != state.generation) {
      await _awaitNewerRefresh(gen);
      return;
    }
    var index = state.index;
    if (index >= pending.length) {
      index = pending.isEmpty ? 0 : pending.length - 1;
    }
    state = state.copyWith(
      hasAnyQuestion: all.isNotEmpty,
      queue: _sorted(pending, state.sort, subjects),
      index: index,
      exams: exams,
      kps: kps,
      allTags: tags,
      subjects: subjects,
      customTypesAll: customs.toList(),
      organizedToday: organizedToday,
      toReviewCount: toReview,
      loading: false,
    );
    await loadFolders();
    // F1 + S1-2：await 期间页面可能已离开、或有更新的 refresh 开始——
    // 先判 _disposed 与代次再碰 state（loadForm 里写 state 会抛错；
    // 旧 refresh 的 loadForm 不得覆盖新表单）。代次旧时等赢的落完再返回。
    if (_disposed) return;
    if (gen != state.generation) {
      await _awaitNewerRefresh(gen);
      return;
    }
    loadForm();
    // 十三批 M5：读当前题的 OCR 任务行与 key 有无（状态推导用）。
    // 不 await：它是装饰性 best-effort 加载，失败/挂起都不能挡
    // loadForm() 之后的流程；读到了再更新 state（见 _refreshOcrStatus）。
    unawaited(_refreshOcrStatus());
    // Win11 包 4：题型待确认且非人工指定时，自动重算一次（best-effort，
    // 不挡导航；同一输入版本只算一次，见 reclassifyCurrent）。
    unawaited(reclassifyCurrent());
  }

  /// 十三批 M5：只刷新当前题的 OCR 状态（任务行 + key 有无）。
  /// 绝不碰表单值与 formResetKey——活页内 OCR 到达时调它不会重置
  /// 正在编辑的表单（M3 警告：不要直接调 refresh()/loadForm()）。
  /// 读库失败时保持旧值，不抛。
  Future<void> _refreshOcrStatus() async {
    final current = state.current;
    if (current == null || _disposed) return;
    final gen = state.generation;
    final repo = _repo;
    try {
      final jobs = await repo.ocrJobsForQuestion(current.id);
      final hasKey = await repo.hasOcrApiKey();
      if (_disposed ||
          gen != state.generation ||
          state.current?.id != current.id) {
        return;
      }
      state = state.copyWith(ocrJobs: jobs, hasOcrApiKey: hasKey);
    } catch (_) {
      // OCR 状态读不到：界面按题本身的 OCR 字段推导（无任务时），不挡整理。
    }
  }

  /// 十三批 M5：活页内刷新守门后的单题刷新（页面订阅 DataChangeBus
  /// 的 questions 事件后调，见 organize_page.dart 的 _onDataChange）。
  ///
  /// 只做两件事，不碰表单：
  /// 1. 把 [questionId] 对应的题按库里最新行换进队列（OCR 字段更新了，
  ///    文件夹/错因等表单值在 state 里另存，不受影响）；
  /// 2. 是当前题时同时刷新它的 OCR 任务行与 key 有无。
  /// formResetKey 不动，页面不会重建表单控制器。
  /// 调用方（页面）须先守门：该题正在被纠错编辑器编辑时不调本方法，
  /// 改走 [candidateStemFor] 只取候选（见页面 _onDataChange）。
  Future<void> refreshOcrForQuestion(String questionId) async {
    if (_disposed) return;
    // WP-B §3.2 第 4 条：入口捕获代次与每题版本号；每次 await 后重校验。
    // 快照只在 await 之后取；题不在队列就不换行；不调 loadForm()，
    // 不动表单；不碰 generation（只用每题版本号）。
    final gen = state.generation;
    final version = (_ocrRefreshVersions[questionId] ?? 0) + 1;
    _ocrRefreshVersions[questionId] = version;
    final repo = _repo;
    bool stale() =>
        _disposed ||
        gen != state.generation ||
        _ocrRefreshVersions[questionId] != version;
    try {
      final fresh = await repo.questionById(questionId);
      if (stale()) return; // 旧任务作废。
      if (fresh == null) return;
      // await 之后重读最新队列，只换本行，绝不整体写回旧快照。
      final queue = [...state.queue];
      final i = queue.indexWhere((x) => x.id == questionId);
      if (i < 0) return; // 题已不在队列（已确认离开），不重新插入。
      final oldRow = queue[i];
      queue[i] = fresh;
      if (stale()) return;
      state = state.copyWith(queue: queue);
      // Win11 包 4 任务 5：当前题 OCR 完成时，若表单题型仍等于旧行
      // 的题型（用户没改过表单），把表单同步到新行题型——否则下次
      // 保存时 formQuestionWithType 会把旧表单题型当人工改动写回，
      // 覆盖自动分类。用户改过表单题型时不动（他们的选择胜出）。
      if (state.current?.id == questionId &&
          state.questionType == oldRow.questionType) {
        state = state.copyWith(questionType: fresh.questionType);
      }
      // 当前题才刷新 OCR 任务信息；不调 loadForm()，不动表单。
      if (state.current?.id == questionId) {
        final jobs = await repo.ocrJobsForQuestion(questionId);
        if (stale()) return;
        final hasKey = await repo.hasOcrApiKey();
        if (stale()) return;
        state = state.copyWith(ocrJobs: jobs, hasOcrApiKey: hasKey);
      }
    } catch (_) {
      // OCR 状态读不到：保持旧行，不挡整理。
    }
  }

  /// 十三批 M5：读一道题的候选题干（守门分支用，不改任何状态）。
  Future<String?> candidateStemFor(String questionId) =>
      candidateStemForQuestion(_repo, questionId);

  /// Win11 包 4：自动 / 强制重算当前题的题型（见 [reclassifiedQuestion]）。
  ///
  /// 自动（`force` 为 false）：仅当题型待确认（`questionType == null`）
  /// 且来源非 manual 时重算；同一输入版本只算一次（`_reclassifiedKeys`
  /// 以 `(questionId, contentVersion)` 守门，计算前先记键——结果是
  /// unchanged 也记，下次同版本不再算）。
  /// 强制（`force` 为 true）：忽略“已定型 / 已算过”守门（“重新分类”
  /// 按钮用），manual 与无原文仍拒绝。
  /// 返回码：'updated' / 'unchanged' / 'already_typed' /
  /// 'already_attempted' / 'manual' / 'no_raw' / 'no_question' /
  /// 'save_failed'。写库用 SaveToken（期望版本取自重算前模型），
  /// 版本冲突即失败不覆盖；成功后换队列行、同步表单题型。
  Future<String> reclassifyCurrent({bool force = false}) async {
    final q = state.current;
    if (q == null) return 'no_question';
    if (q.questionTypeSource == 'manual') return 'manual';
    if (q.ocrRaw == null || GlmOcrRawData.tryParse(q.ocrRaw) == null) {
      return 'no_raw';
    }
    if (!force && q.questionType != null) return 'already_typed';
    final key = (q.id, q.contentVersion);
    if (!force && _reclassifiedKeys.contains(key)) {
      return 'already_attempted';
    }
    _reclassifiedKeys.add(key);
    final updated = reclassifiedQuestion(q);
    if (updated == null) return 'unchanged';
    try {
      if (!state.queue.any((x) => x.id == q.id)) return 'save_failed';
      await _repo.save(
        updated,
        token: SaveToken(
          questionId: q.id,
          expectedContentVersion: q.contentVersion,
        ),
      );
    } catch (_) {
      return 'save_failed';
    }
    if (_disposed) return 'updated';
    _replaceQueueRow(updated);
    // 表单同步：表单题型仍等于重算前的库里题型（用户没改过表单）
    // 或强制重算时，同步到新题型；用户改过表单题型时不动——他们的
    // 选择在保存时胜出（见 refreshOcrForQuestion 任务 5 同款规则）。
    if (state.current?.id == q.id &&
        (state.questionType == q.questionType || force)) {
      state = state.copyWith(questionType: updated.questionType);
    }
    return 'updated';
  }

  // ---------- 十三批 M5：纠错保存（见 stem_correction.dart 的规则） ----------

  /// 保存手动编辑的题干：版本 +1、人工标记、切分状态“人工调整”、
  /// 候选标志清掉；成功后把新行写回内存队列（与 saveCurrent 同款
  /// SR2-6：只写库不同步内存时，下次表单保存会拿旧行整行覆盖）。
  /// 返回 false 时页面提示“保存失败，请重试”，编辑器不收起。
  Future<bool> saveStemEdit(String newStem) async {
    final q = state.current;
    if (q == null) return false;
    final repo = _repo;
    try {
      final updated = applyManualStemEdit(q, newStem);
      // S1-3：紧贴写操作之前重查该题仍在队列中（与调用之间零 await）；
      // 写操作带版本令牌（期望版本取自当前模型），行已消失或版本不符
      // 时 repo.save 抛 SaveTokenMismatch → 返回 false（不复活已删行，
      // 不覆盖更新的保存）。
      if (!state.queue.any((x) => x.id == q.id)) return false;
      await repo.save(
        updated,
        token: SaveToken(
          questionId: q.id,
          expectedContentVersion: q.contentVersion,
        ),
      );
      if (_disposed) return true; // 写库已成功；队列写回跳过。
      _replaceQueueRow(updated);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 接受候选（十三批 P1-1）：接受的题干一律从库里 ocr_raw 包取，
  /// 接受时重验证（题目仍存在、input_hash 与当前切片一致、候选仍
  /// pending）；任一不符返回 false（编辑器不收起，P1-2/M5 后续按
  /// [CandidateRejection.reason] 给明确原因）。切分状态写回、
  /// 人工标记保持 1、版本 +1、raw 候选状态写 accepted。
  /// 失败返回 false，编辑器不收起。
  Future<bool> acceptOcrCandidate() async =>
      (await acceptOcrCandidateOutcome()).accepted;

  /// 接受候选并返回结果（十三批 P1-2 任务 e，与 DetailNotifier
  /// 同款；Win11 反馈尾巴 1：成功时 [AcceptCandidateOutcome.reason]
  /// 为 null，[AcceptCandidateOutcome.unmatchedManualIds] 是接受时
  /// 没匹配上的手动图块 ID——已保留在末尾，页面据此提示用户一次）：
  /// 失败时 reason 是 [CandidateRejection.reason]
  ///（question_deleted / no_candidate / not_pending / hash_mismatch /
  /// slice_missing），其余失败返回 'save_failed'，无当前题返回
  /// 'no_question'，此时 unmatchedManualIds 为空。页面按 reason 给
  /// 明确文案（见 ocr_stem_section.dart 的 [candidateRejectionMessage]）。
  // U1-3 界限（明确写出，不假装全原子）：队列成员关系是 Notifier
  // 内存状态，不在库里，事务无法校验它。成员检查在调用前同步完成
  //（与调用之间零 await，T1-1）；事务内的版本校验是防止写错题的
  // 底线。残余窗口（检查后、事务前成员关系变化）下，最坏结果是对
  // 一个已离队的题目执行一次带版本校验的写入——写入内容仍是用户对
  // 该题的真实编辑，且版本校验保证不覆盖更新的保存。这是有意接受
  // 的界限，不是未发现的漏洞。
  Future<AcceptCandidateOutcome> acceptOcrCandidateOutcome() async {
    final q = state.current;
    if (q == null) return const AcceptCandidateOutcome(reason: 'no_question');
    final repo = _repo;
    // S1-3：紧贴写操作之前重查该题仍在队列中（与调用之间零 await）。
    // 行已不在队列 → 返回失败并触发队列刷新。
    if (!state.queue.any((x) => x.id == q.id)) {
      await refresh();
      return const AcceptCandidateOutcome(reason: 'question_deleted');
    }
    try {
      // 十三批 P1 第二轮：acceptCandidateStem 在事务内原子校验并落库，
      // 返回的就是已保存的题，不再另行 repo.save。版本条件由它内部
      // 的事务校验负责（stem_correction.dart，不在本次范围）。
      final accepted = await acceptCandidateStem(repo, q);
      // 已落库；队列写回跳过。未匹配信息仍带回（页面按 mounted 判断，
      // 不会给已销毁的页面弹提示）。
      if (_disposed) {
        return AcceptCandidateOutcome(
          reason: null,
          unmatchedManualIds: accepted.unmatchedManualIds,
        );
      }
      _replaceQueueRow(accepted.question);
      return AcceptCandidateOutcome(
        reason: null,
        unmatchedManualIds: accepted.unmatchedManualIds,
      );
    } on CandidateRejection catch (e) {
      // 行已消失或版本不符 → 触发队列刷新（S1-3），再把原因交回页面。
      await refresh();
      return AcceptCandidateOutcome(reason: e.reason);
    } catch (_) {
      return const AcceptCandidateOutcome(reason: 'save_failed');
    }
  }

  /// 忽略候选：只清 raw 里的候选标志（版本 +1）。无候选时直接返回 true。
  Future<bool> dismissOcrCandidate() async {
    final q = state.current;
    if (q == null) return true;
    if (!hasPendingOcrCandidate(q)) return true;
    final repo = _repo;
    try {
      final updated = dismissOcrCandidateFlag(q);
      // S1-3：紧贴写操作之前重查仍在队列中；写操作带版本令牌，
      // 行已消失或版本不符时抛 SaveTokenMismatch → 返回 false 并刷新队列。
      if (!state.queue.any((x) => x.id == q.id)) {
        await refresh();
        return false;
      }
      await repo.save(
        updated,
        token: SaveToken(
          questionId: q.id,
          expectedContentVersion: q.contentVersion,
        ),
      );
      if (_disposed) return true;
      _replaceQueueRow(updated);
      return true;
    } on SaveTokenMismatch {
      await refresh();
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 删除单个图块（十四批 M2）：只更新数据库引用（ocr_figures 去掉
  /// 该项），content_version +1（图块变化；版本由 upsert 的版本权威
  /// 按实际内容变化统一计算，只 +1 一次）；旧文件不立即删，进孤儿清理。
  /// 无该图块时直接返回 true。返回 false 时页面提示，编辑器里该段保持原样。
  Future<bool> deleteFigure(String figureId) async {
    final q = state.current;
    if (q == null) return false;
    final repo = _repo;
    try {
      final updated = deleteFigureFromQuestion(q, figureId);
      if (identical(updated, q)) return true;
      // S1-3：同 dismissOcrCandidate（成员重查 + 版本令牌 + 失败刷新）。
      if (!state.queue.any((x) => x.id == q.id)) {
        await refresh();
        return false;
      }
      await repo.save(
        updated,
        token: SaveToken(
          questionId: q.id,
          expectedContentVersion: q.contentVersion,
        ),
      );
      if (_disposed) return true;
      _replaceQueueRow(updated);
      return true;
    } on SaveTokenMismatch {
      await refresh();
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 图块换位（Win11 反馈包 3）：只更新数据库引用（ocr_figures 按新
  /// 顺序重排，被拖图块记 anchorSource='manual' + 落点），
  /// content_version +1（图块变化；版本由 upsert 的版本权威
  /// 按实际内容变化统一计算，只 +1 一次）；裁图文件不动。
  /// 顺序非法（不是原集合的排列）时 [reorderFiguresInQuestion] 抛错 →
  /// 返回 false，编辑器回滚到原顺序。无当前题时返回 false。
  /// 其余与 [deleteFigure] 同款（成员重查 + 版本令牌 + 失败刷新）。
  Future<bool> reorderFigure(
    List<String> orderedFigureIds,
    String movedFigureId,
    String movedTextAt,
  ) async {
    final q = state.current;
    if (q == null) return false;
    final repo = _repo;
    try {
      final updated = reorderFiguresInQuestion(
        q,
        orderedFigureIds,
        movedFigureId,
        movedTextAt,
      );
      // S1-3：同 deleteFigure（成员重查 + 版本令牌 + 失败刷新）。
      if (!state.queue.any((x) => x.id == q.id)) {
        await refresh();
        return false;
      }
      await repo.save(
        updated,
        token: SaveToken(
          questionId: q.id,
          expectedContentVersion: q.contentVersion,
        ),
      );
      if (_disposed) return true;
      _replaceQueueRow(updated);
      return true;
    } on SaveTokenMismatch {
      await refresh();
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 手动“重新识别”：为当前题建 OCR 任务（调 M3 入队接口），
  /// 入队后刷新任务行。入队失败（无切片等）返回 false，页面提示；
  /// 入队本身绝不拦整理流程。
  /// 十三批 P1-1：入队失败抛错时这里接住返回 false（P1-2 改为向
  /// 用户展示“OCR 未入队”+重试入口）。
  Future<bool> rerecognizeCurrent() async {
    final q = state.current;
    if (q == null) return false;
    OcrJob? job;
    try {
      job = await enqueueOcrForQuestion(_repo.db, q);
    } catch (_) {
      return false;
    }
    if (job == null) return false;
    // 任务行刷新不 await（best-effort：读到了再更新 state，见上）。
    unawaited(_refreshOcrStatus());
    return true;
  }

  /// Win11 反馈包 2：取消当前题的识别（任务标 cancelled + OCR 字段
  /// 清空，只留切片；见 [OcrWorker.cancelOcrForQuestion]）。
  /// 返回码：'cancelled' / 'nothing_to_cancel' / 'no_question' /
  /// 'failed'。成功后换行 + 刷新任务行（同 refreshOcrForQuestion 的
  /// 收尾：表单题型随新行同步——取消清掉了 auto 题型，用户没改过
  /// 表单时表单跟到 null；用户改过表单题型时不动，见任务 5 规则）。
  Future<String> cancelOcrCurrent() async {
    final q = state.current;
    if (q == null) return 'no_question';
    String code;
    try {
      code = await cancelOcrForQuestion(_repo.db, q.id);
    } catch (_) {
      return 'failed';
    }
    if (code == 'cancelled') {
      await refreshOcrForQuestion(q.id);
    }
    return code;
  }

  void _replaceQueueRow(Question updated) {
    if (_disposed) return;
    final i = state.queue.indexWhere((x) => x.id == updated.id);
    if (i < 0) return;
    final queue = [...state.queue];
    queue[i] = updated;
    state = state.copyWith(queue: queue);
  }

  /// 读当前题所属学科的文件夹（原 `_loadFolders`）：无当前题时直接返回。
  Future<void> loadFolders() async {
    final current = state.current;
    if (current == null) return;
    // S1-2：读到一半若代次变了（有更新的刷新/切题开始），本次文件夹
    // 写回直接跳过，不覆盖新一代的状态。
    final gen = state.generation;
    final folders = await _repo.folders(subjectId: current.subjectId);
    if (_disposed || gen != state.generation) return;
    state = state.copyWith(folders: folders);
  }

  /// 按当前题重建表单值（原 `_loadForm` 里表单值的部分）：
  /// SR-P2-27：旧数据里与固定枚举同名的自定义错因，在读表单时就
  /// 合并进固定项（不丢错因、不在界面上重复出现）；下次保存即写回。
  /// 无当前题时直接返回。`formResetKey` 加一，页面按它变化、
  /// 下一帧把控制器文本按当前题重建并收起内联新建框
  /// （原 `_loadForm` 里设控制器文本 + 收框的部分）。
  void loadForm() {
    final q = state.current;
    if (q == null) {
      // R3-4：无当前题时表单失效，loadedQuestionId 强制 null。
      if (state.loadedQuestionId != null) {
        state = state.copyWith(loadedQuestionId: null);
      }
      return;
    }
    state = state.copyWith(
      folderIds: List.of(q.folderIds),
      examId: q.examId,
      kpIds: List.of(q.knowledgePointIds),
      errorTypes: {
        ...q.errorTypes,
        ...q.customErrorTypes.where((t) => ErrorTypes.fixed.contains(t)),
      }.toList(),
      customTypes: q.customErrorTypes
          .where((t) => !ErrorTypes.fixed.contains(t))
          .toList(),
      tags: List.of(q.tags),
      questionType: q.questionType,
      // 十四批 M3：选项标签表单值从当前题读；重确认信号是单次保存信号，
      // 切题即清零（不跨题带）。
      optionLabels: q.optionLabels == null
          ? null
          : List.of(q.optionLabels!),
      optionLabelsConfirmed: q.optionLabelsConfirmed,
      correctOption: q.correctOption,
      answerReconfirmed: false,
      optionLabelsJustConfirmed: false,
      // Win11 反馈包 5：选项文字表单值从当前题读（仅切分成功时显示，
      // 见页面 _optionContentsForDisplay 的守门）。
      optionContents: q.optionContents == null
          ? null
          : Map<String, String>.of(q.optionContents!),
      formResetKey: state.formResetKey + 1,
      // WP-B：表单绑定到当前题（R3-4）；copyWith 遇空队列会强制 null。
      loadedQuestionId: q.id,
    );
  }

  // ---------- 表单值：具名改动口（D-35：优先用命名方法，少用泛型 update） ----------

  void toggleFolder(String id) {
    final ids = [...state.folderIds];
    if (ids.contains(id)) {
      ids.remove(id);
    } else {
      ids.add(id);
    }
    state = state.copyWith(folderIds: ids);
  }

  void setExamId(String? id) {
    state = state.copyWith(examId: id);
  }

  void toggleKp(String id) {
    final ids = [...state.kpIds];
    if (ids.contains(id)) {
      ids.remove(id);
    } else {
      ids.add(id);
    }
    state = state.copyWith(kpIds: ids);
  }

  void toggleErrorType(String t) {
    final list = [...state.errorTypes];
    if (list.contains(t)) {
      list.remove(t);
    } else {
      list.add(t);
    }
    state = state.copyWith(errorTypes: list);
  }

  void removeErrorType(String t) {
    state = state.copyWith(
      errorTypes: state.errorTypes.where((x) => x != t).toList(),
    );
  }

  void toggleCustomType(String t) {
    final list = [...state.customTypes];
    if (list.contains(t)) {
      list.remove(t);
    } else {
      list.add(t);
    }
    state = state.copyWith(customTypes: list);
  }

  void removeCustomType(String t) {
    state = state.copyWith(
      customTypes: state.customTypes.where((x) => x != t).toList(),
    );
  }

  void toggleTag(String t) {
    final list = [...state.tags];
    if (list.contains(t)) {
      list.remove(t);
    } else {
      list.add(t);
    }
    state = state.copyWith(tags: list);
  }

  /// 十四批 M1：表单里的题型改动（只改表单值，不写库；保存时
  /// formQuestionWithType 再按“值变了才写 manual”落盘）。
  void setQuestionType(String? type) {
    state = state.copyWith(questionType: type);
  }

  /// 十四批 M3：表单里的选项标签改动（只改表单值，不写库；保存时
  /// formQuestion 落盘，数据层 _applyOptionLabelChangeRules 再按改标签
  /// 规则处理确认清零与 P1-A）。标签清空时确认态一并清零。
  void setOptionLabels(List<String>? labels) {
    state = state.copyWith(
      optionLabels: labels,
      optionLabelsConfirmed:
          labels == null ? false : state.optionLabelsConfirmed,
    );
  }

  /// Win11 反馈包 5：表单里的选项文字改动（只改表单值，不写库；
  /// 保存时 formQuestion 落盘）。删标签的键由编辑器与数据层剪枝，
  /// 这里只接编辑器上报的完整映射。
  void setOptionContents(Map<String, String>? contents) {
    state = state.copyWith(optionContents: contents);
  }

  /// 十四批 M3：表单里的正确选项改动（只改表单值，不写库）。
  /// 点选正确选项即重确认（D-133）：单选只改标签顺序后，重新选定
  /// 同一标签也须带 answerReconfirmed 信号才恢复判分。
  void setCorrectOption(String? value) {
    state = state.copyWith(
      correctOption: value,
      answerReconfirmed: true,
    );
  }

  /// 十四批 M3：P1-A 重确认复选框（多选/不定项改标签后，确认旧答案
  /// 和解析仍有效；同次保存不确认则数据层置 NULL）。
  void setAnswerReconfirmed(bool value) {
    state = state.copyWith(answerReconfirmed: value);
  }

  /// 十四批 M3：「确认选项」：把表单确认态置 1 并带 justConfirmed
  /// 信号立即保存（保存成功后信号清零，见 [saveCurrent]）。
  /// 页面传当前答案/解析/笔记文本框内容（与 _trySaveCurrent 同款）。
  Future<bool> confirmOptionLabels({
    required String answer,
    required String explanation,
    required String notes,
  }) async {
    state = state.copyWith(
      optionLabelsConfirmed: true,
      optionLabelsJustConfirmed: true,
    );
    return saveCurrent(
      answer: answer,
      explanation: explanation,
      notes: notes,
    );
  }

  // ---------- 保存 / 切题 / 确认（原 `_saveCurrent` / `_goTo` /
  // `_confirmCurrent` / `_jumpToQuestion` / `_applyQueueSort`） ----------

  /// 切题自动保存（原 `_saveCurrent` + `_trySaveCurrent` 的落盘部分）：
  /// 文本框内容由页面从控制器读了传进来。保存失败返回 false
  /// （页面弹“保存失败，请重试”并拦下本次动作）；无当前题时
  /// 返回 true（原 `_saveCurrent` 无题直接返回，视为成功）。
  /// SR2-6 根治：保存成功后把新行写回内存队列——只写库不同步
  /// 内存时，切题往返后仍读旧对象，再保存会把已落盘的改动整行
  /// 覆盖回旧值。只在保存成功后写回；失败时队列保持旧行。
  Future<bool> saveCurrent({
    required String answer,
    required String explanation,
    required String notes,
  }) async {
    // R3-3：本次保存要写回队列行——先加代次（后面的 await 都属于
    // 新一代），使此前开始的单题刷新等旧任务失效。表单本身未换题，
    // loadedQuestionId 不动（仍是 q.id，守门要比它）。
    state = state.copyWith(generation: state.generation + 1);
    final gen = state.generation;
    final q = state.current;
    final formId = state.loadedQuestionId;
    if (q == null) return true;
    // D-42：repo 入口处捕获一次（保存 + 同步错因记录跨两次 await）。
    final repo = _repo;
    try {
      // S1-1 / S1-4 卡点：保存前重读全表取本行——这是 repo.save 调用前
      // 最后一个 await，可供测试挂住旧保存任务（切 B 回 A 后代次
      // 检查拦截，repo.save 一次也不调用）。
      // 用 all() 而不用 questionById：部分旧 fake 未覆盖 questionById，
      // 基类实现读真实 Drift 库，在 widget 测试里永不完成（b5 注释
      // FR-09 同款 hazard），会把保存永远挂住；all() 是整理页 fake
      // 必然覆盖的方法（队列加载就靠它），不存在这个 hazard。
      // 注意令牌仍取自表单加载时的模型 q.contentVersion，不取刚读到
      // 的行版本：刚读到的行若已被 OCR worker 等改过，用它的版本当
      // 令牌会把表单的旧题干整行覆盖回去（U1-1 令牌语义）。
      // 行已消失 → 直接中止并刷新队列，不写库；读失败 → 不拦保存，
      // 令牌在事务内做最终校验（行存在性以令牌为准）。
      List<Question>? rows;
      try {
        rows = await repo.all();
      } catch (_) {
        rows = null;
      }
      if (rows != null && rows.every((x) => x.id != q.id)) {
        unawaited(refresh());
        return false;
      }
      // T1-1：四条件检查与 repo.save 调用处于同一个同步块内、中间零 await。
      if (!_gateOk(gen, q, formId)) {
        _logStale('saveCurrent', gen, q);
        return false;
      }
      final updated = state.formQuestionWithType(
        state.formQuestion(
          q,
          answer: answer,
          explanation: explanation,
          notes: notes,
        ),
      );
      final token = SaveToken(
        questionId: q.id,
        expectedContentVersion: q.contentVersion,
      );
      // FR-02：save 先发角标事件、syncCauseRecords 后写库时，角标重读
      // 可能抢在同步提交前（错因同步改变复习归属时角标滞后一次）；
      // 与 joinReviewBatch 同款用 scope 包起来，事件在同步提交后
      // 才合并发出一次。
      await DataChangeBus.instance.scope(() async {
        await repo.save(updated, token: token);
        await repo.syncCauseRecords(updated);
      });
      // 保存已落库。队列行必须用刚读到的行刷新（U1 连续保存陷阱：
      // updated 仍带旧 contentVersion，直接写回会让下一次保存的令牌
      // 仍是旧版本而被误杀）。此次写回是按 id 的库内真值，不写表单值，
      // 因此只判 _disposed，不再套四条件守门（守门防的是旧值覆盖新值，
      // 刚读到的行不可能是旧值）。
      // 用 all() 重读而不用 questionById（同上：旧 fake 未覆盖
      // questionById 会永挂；all() 必然覆盖）。读失败/行缺失时
      // 不拦：队列行保持旧值，下次 refresh 纠正。
      Question? savedRow;
      try {
        final savedRows = await repo.all();
        for (final r in savedRows) {
          if (r.id == q.id) {
            savedRow = r;
            break;
          }
        }
      } catch (_) {
        savedRow = null;
      }
      if (_disposed) return true;
      if (savedRow != null) _replaceQueueRow(savedRow);
      // 十四批 M3：重确认信号是单次保存信号，成功落盘后清零，不跨保存带。
      // 只在仍是同一代、同一题、同一表单时清零（表单值，守门）。
      if (_gateOk(gen, q, formId)) {
        if (state.answerReconfirmed || state.optionLabelsJustConfirmed) {
          state = state.copyWith(
            answerReconfirmed: false,
            optionLabelsJustConfirmed: false,
          );
        }
      } else {
        _logStale('saveCurrent:signals', gen, q);
      }
      return true;
    } on SaveTokenMismatch {
      // 令牌不符：已有更新的保存先落库，本次表单是旧的——不写库、
      // 不清信号，刷新队列与表单（最新值），由用户重新保存。
      _logStale('saveCurrent:token', gen, q);
      await refresh();
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 切到第 [next] 道（原 `_goTo` 里保存之后的部分）：
  /// 越界或原地不动时直接返回；否则改下标、重读文件夹、重建表单。
  /// 保存由页面先做（失败时拦下、不进这里）。
  Future<void> goTo(int next) async {
    if (next < 0 || next >= state.queue.length || next == state.index) {
      return;
    }
    // R3-3：改下标前先加代次；表单随之下线（loadedQuestionId 置 null），
    // loadForm 成功后再置新 id（R3-4）。
    final gen = state.generation + 1;
    state = state.copyWith(
      generation: gen,
      index: next,
      loadedQuestionId: null,
    );
    await loadFolders();
    // F1 + S1-2：await 期间页面可能已离开、或有更新的操作开始——
    // 先判 _disposed 与代次，旧切题的 loadForm 不得落地。
    if (_disposed || gen != state.generation) return;
    loadForm();
    // Win11 包 4：切到新题后，题型待确认且非人工指定时自动重算一次
    //（best-effort，不挡切题；见 reclassifyCurrent）。
    unawaited(reclassifyCurrent());
  }

  /// 确认整理当前题（原 `_confirmCurrent`）：文件夹必填由页面先校验
  /// （缺了弹“先选文件夹”并只开文件夹区，不进这里）。保存 + 同步
  /// 错因记录 + 记最近任务（kind '整理'），再整页重读——队列推进
  /// 到下一道（确认后这道题已不在待整理队列里）。
  Future<void> confirmCurrent({
    required String answer,
    required String explanation,
    required String notes,
  }) async {
    // R3-3：与 saveCurrent 同款，保存前先加代次。
    state = state.copyWith(generation: state.generation + 1);
    final gen = state.generation;
    final q = state.current;
    final formId = state.loadedQuestionId;
    if (q == null) return;
    // D-42：repo 入口处捕获一次（保存 + 同步错因记录 + 记最近任务跨多次 await）。
    // FR-02：与 saveCurrent 同款，save + 同步 + 记最近任务包进一个
    // scope，角标事件只在全部提交后发一次。
    final repo = _repo;
    // S1-1：保存前重读全表取本行（S1-4 卡点，同 saveCurrent，
    // 用 all() 而不用 questionById，原因同 saveCurrent）；行已消失
    // 直接中止并刷新，不写库；读失败不拦，令牌在事务内做最终校验。
    // 再四条件检查，与 repo.save 调用同一同步块、中间零 await。
    List<Question>? rows;
    try {
      rows = await repo.all();
    } catch (_) {
      rows = null;
    }
    if (rows != null && rows.every((x) => x.id != q.id)) {
      await refresh();
      return;
    }
    if (!_gateOk(gen, q, formId)) {
      _logStale('confirmCurrent', gen, q);
      return;
    }
    final updated = state.formQuestionWithType(
      state.formQuestion(
        q,
        answer: answer,
        explanation: explanation,
        notes: notes,
        organized: true,
      ),
    );
    final token = SaveToken(
      questionId: q.id,
      expectedContentVersion: q.contentVersion,
    );
    try {
      await DataChangeBus.instance.scope(() async {
        await repo.save(updated, token: token);
        await repo.syncCauseRecords(updated);
        await repo.saveRecentTask(
          kind: '整理',
          subjectId: q.subjectId,
          title: q.title,
        );
      });
    } on SaveTokenMismatch {
      // 令牌不符：已有更新的保存先落库，本次表单是旧的——不记最近任务、
      // 不推进队列，刷新队列与表单（最新值），由用户重新确认。
      // 这里必须接住：页面 _confirmCurrent 不接异常，直接外抛会变成
      // 未处理异步错误；而令牌不符是正常的竞态结果，不是程序错误。
      _logStale('confirmCurrent:token', gen, q);
      await refresh();
      return;
    }
    await refresh();
  }

  /// 队列里点中一道题（原 `_jumpToQuestion` 里关层 + 保存之后的部分）：
  /// 找不到时重读一遍（与原代码一致）；否则改下标、重读文件夹、重建表单。
  Future<void> jumpTo(String id) async {
    final idx = state.queue.indexWhere((q) => q.id == id);
    if (idx < 0) {
      await refresh();
      return;
    }
    // R3-3：改下标前先加代次；表单随之下线（R3-4），loadForm 再置新 id。
    final gen = state.generation + 1;
    state = state.copyWith(
      generation: gen,
      index: idx,
      loadedQuestionId: null,
    );
    await loadFolders();
    // F1 + S1-2：同 goTo，旧跳转的 loadForm 不得落地。
    if (_disposed || gen != state.generation) return;
    loadForm();
    // Win11 包 4：跳到新题后，题型待确认且非人工指定时自动重算一次
    //（best-effort，不挡跳转；见 reclassifyCurrent）。
    unawaited(reclassifyCurrent());
  }

  /// 队列里改排序（原 `_applyQueueSort` 里保存之后的部分）：
  /// 按新排序重排并回到第 1 道（与顶栏排序下拉的行为一致），
  /// 再重建表单；不重读文件夹（原代码同款——与 `_goTo` 不同，
  /// 这里不调 `_loadFolders`）。弹出层重绘由页面 `markNeedsBuild`。
  void applyQueueSort(String sort) {
    // R3-3：队列排序替换队列、回到第 1 道——先加代次，表单随之下线，
    // loadForm 再置新 id（R3-4）。同步方法，无 await 交错。
    state = state.copyWith(
      sort: sort,
      queue: _sorted(state.queue, sort, state.subjects),
      index: 0,
      generation: state.generation + 1,
      loadedQuestionId: null,
    );
    loadForm();
  }

  // ---------- 内联新建（原 `_submitNewFolder` / `_submitNewExam` /
  // `_submitNewTag` / `_addCustomType`） ----------

  /// 新建文件夹（原 `_submitNewFolder`）：返回新建的文件夹；
  /// 整科同名（预检命中，或写入时 StateError 兜底）返回 null，
  /// 页面弹“已经有了”。成功后重读文件夹并把新建的选上这道题。
  Future<Folder?> submitNewFolder(String name, String subjectId) async {
    // D-42：repo 入口处捕获一次（预检与保存跨多次 await，`on StateError`
    // 接不住 UnmountedRefException）。
    // S1-1：新建文件夹后“把新建的选上这道题”是表单值写回——入口捕获
    // 代次/当前题/表单 id，await 后守门不通过时只返回文件夹，不选上。
    final gen = state.generation;
    final q = state.current;
    final formId = state.loadedQuestionId;
    final repo = _repo;
    // SR-P2-36：整科同名预检（新建不传 excludeId）——旧代码只查顶层
    // 同名，跨层同名会一路写到 upsertFolder 才被 StateError 拦下。
    // 预检命中即返回 null；仍留 StateError 捕获作兜底
    //（竞态：预检与写入之间别人建了同名）。
    if (await repo.folderNameExistsInSubject(subjectId, name)) {
      return null;
    }
    final folder = Folder(
      // SR-P2-28：id 用 newEntityId（毫秒 + 随机后缀）；纯毫秒在同一
      // 毫秒内连点两次会撞主键、后一次覆盖前一次。
      id: newEntityId('folder'),
      name: name,
      subjectId: subjectId,
      sortOrder: state.folders.length,
    );
    try {
      await repo.saveFolder(folder);
    } on StateError {
      return null;
    }
    await loadFolders();
    if (_disposed) return folder;
    // S1-1：守门不通过（切题/刷新已开始）时不把新建文件夹选上新题的表单。
    if (!_gateOk(gen, q, formId)) {
      _logStale('submitNewFolder', gen, q);
      return folder;
    }
    state = state.copyWith(
      folderIds: state.folderIds.contains(folder.id)
          ? state.folderIds
          : [...state.folderIds, folder.id],
    );
    return folder;
  }

  /// 新建试卷（原 `_submitNewExam`）：写库后追加进试卷表、
  /// 并把新建的归属到这道题。
  Future<void> submitNewExam(String name, DateTime? date) async {
    // S1-1：examId 是表单值，写回前守门；exams 列表是元数据（追加式），
    // 读当前 state 追加，不会丢改动，始终写回。
    final gen = state.generation;
    final q = state.current;
    final formId = state.loadedQuestionId;
    final exam = Exam(
      // SR-P2-28：id 用 newEntityId（毫秒 + 随机后缀），防同毫秒连点撞主键。
      id: newEntityId('exam'),
      name: name,
      date: date,
    );
    await _repo.addExam(exam);
    if (_disposed) return;
    state = state.copyWith(
      exams: [...state.exams, exam],
      examId: _gateOk(gen, q, formId) ? exam.id : state.examId,
    );
    if (!_gateOk(gen, q, formId)) _logStale('submitNewExam', gen, q);
  }

  /// 新建标签（原 `_submitNewTag`）：写库后追加进标签表并选上这道题。
  /// 标签名禁逗号与竖线（§6 第 4 条）由页面先校验，不进这里。
  Future<void> submitNewTag(String name) async {
    // S1-1：同 submitNewExam——tags 是表单值（守门），allTags 是元数据。
    final gen = state.generation;
    final q = state.current;
    final formId = state.loadedQuestionId;
    await _repo.addTag(name);
    if (_disposed) return;
    final gateOk = _gateOk(gen, q, formId);
    if (!gateOk) _logStale('submitNewTag', gen, q);
    state = state.copyWith(
      tags: gateOk
          ? (state.tags.contains(name)
                ? state.tags
                : [...state.tags, name])
          : state.tags,
      allTags: state.allTags.contains(name)
          ? state.allTags
          : [...state.allTags, name],
    );
  }

  /// 自定义错误类型（原 `_addCustomType` 里写库之外的部分）：
  /// 与固定枚举同名时不进自定义集合，直接选中对应固定项，
  /// 返回 true（页面提示“是固定错误类型，已帮你选中”）；
  /// 否则进自定义集合（本题 + 全库），返回 false。
  /// 空名与禁逗号竖线由页面先校验，不进这里。
  bool addCustomType(String name) {
    // SR-P2-27：与固定枚举同名时不进自定义集合，直接选中对应固定项
    //（否则 allCauses 里出现两次“其他”，详情页副标题与复习记录的
    // 错因行都会重复；详情页保存还会把它静默滤掉、错因直接消失）。
    if (ErrorTypes.fixed.contains(name)) {
      state = state.copyWith(
        errorTypes: state.errorTypes.contains(name)
            ? state.errorTypes
            : [...state.errorTypes, name],
      );
      return true;
    }
    state = state.copyWith(
      customTypes: state.customTypes.contains(name)
          ? state.customTypes
          : [...state.customTypes, name],
      customTypesAll: state.customTypesAll.contains(name)
          ? state.customTypesAll
          : [...state.customTypesAll, name],
    );
    return false;
  }

  // ---------- 队列弹出层的批量操作（原 `_QueuePopupState` 里调 `repo`
  // 的部分；弹出层只留纯界面状态在本地，操作结果由返回值交回去，
  // 弹出层自己的 `_questions` 快照同步仍在弹出层里） ----------

  /// 单删一道题（原 `_deleteOne`）：写库；弹出层随后把该题
  /// 从自己的 `_questions` 快照与勾选里去掉。
  /// R3-3：删题改变队列成员，先加代次，使进行中的旧任务失效。
  Future<void> deleteQuestion(Question q) async {
    state = state.copyWith(generation: state.generation + 1);
    await _repo.delete(q);
  }

  /// 批量打标签（原 `_applyBatchTag` 里写库的部分）：
  /// 返回已保存的题 id 与选中总数。循环中途某题写库失败时停下，
  /// 已保存的仍返回（SR3-15：弹出层按返回的 id 同步快照，
  /// 否则后续批量操作拿旧行覆盖，会把刚落盘的标签抹掉）；
  /// 失败不抛到按钮回调，由弹出层按“部分保存失败”提示。
  Future<({Set<String> savedIds, int total})> batchTagQuestions(
    List<Question> selected,
    String tag,
  ) async {
    // R3-5：批量打标签按显式 id 列表操作，不碰 current 表单值；
    // 只改标签，不替换队列、不改变 current，不加代次。
    // D-42 + Stage 4：repo 入口处捕获一次；批量提交只发一个事件
    //（scope 把逐题保存的事件合并成一个）。
    final repo = _repo;
    final savedIds = <String>{};
    await DataChangeBus.instance.scope(() async {
      try {
        for (final q in selected) {
          final tags = {...q.tags, tag}.toList();
          await repo.save(q.copyWith(tags: tags));
          savedIds.add(q.id);
        }
      } catch (_) {
        // 落到返回：已保存子集照常同步，调用方按 savedIds 与 total
        // 的差值报“部分保存失败”。
      }
    });
    return (savedIds: savedIds, total: selected.length);
  }

  /// 批量加入文件夹（原 `_batchAddFolder`）：返回已加入数与
  /// “不是本科”跳过数。已在文件夹里的题不重复写库，但仍计入
  /// 已加入（原代码同款）。
  Future<({int applied, int skipped})> batchAddFolders(
    List<Question> selected,
    Folder folder,
  ) async {
    // R3-3/R3-5：批量移文件夹改变队列成员归属，先加代次；按显式 id
    // 列表操作，不碰 current 表单值，不带版本令牌（快照行版本可能已旧）。
    state = state.copyWith(generation: state.generation + 1);
    // D-42 + Stage 4：repo 入口处捕获一次；批量提交只发一个事件。
    final repo = _repo;
    var applied = 0;
    var skipped = 0;
    await DataChangeBus.instance.scope(() async {
      for (final q in selected) {
        if (q.subjectId != folder.subjectId) {
          skipped++;
          continue;
        }
        if (!q.folderIds.contains(folder.id)) {
          await repo.save(q.copyWith(folderIds: [...q.folderIds, folder.id]));
        }
        applied++;
      }
    });
    return (applied: applied, skipped: skipped);
  }

  /// 批量条里新建文件夹（原 `_submitBatchFolder`）：
  /// 返回新建的文件夹；整科同名返回 null（弹出层提示“已经有了”）。
  Future<Folder?> submitBatchFolder(
    String name,
    String subjectId,
    int sortOrder,
  ) async {
    // D-42：repo 入口处捕获一次（见 submitNewFolder）。
    final repo = _repo;
    // SR-P2-36：整科同名预检 + StateError 兜底（见 `submitNewFolder`）。
    if (await repo.folderNameExistsInSubject(subjectId, name)) {
      return null;
    }
    final folder = Folder(
      // SR-P2-28：id 用 newEntityId（毫秒 + 随机后缀），防同毫秒连点撞主键。
      id: newEntityId('folder'),
      name: name,
      subjectId: subjectId,
      sortOrder: sortOrder,
    );
    try {
      await repo.saveFolder(folder);
    } on StateError {
      return null;
    }
    return folder;
  }

  /// 批量确认（原 `_batchConfirm`）：只确认已选文件夹的题，
  /// 缺文件夹的题拦下；返回拦下的题数，弹出层提示后关层，
  /// 父页重读并按当前排序进下一道。注意：批量确认只 save
  /// `isOrganized: true`，不同步错因记录、不记最近任务
  ///（原代码同款，与单题 `_confirmCurrent` 不同）。
  Future<int> batchConfirmQuestions(List<Question> selected) async {
    final blocked = selected.where((q) => q.folderIds.isEmpty).toList();
    final ok = selected.where((q) => q.folderIds.isNotEmpty).toList();
    // R3-3/R3-5：批量确认改变队列成员，先加代次；按显式 id 列表操作，
    // 不碰 current 表单值，不带版本令牌（同 batchAddFolders）。
    state = state.copyWith(generation: state.generation + 1);
    // D-42 + Stage 4：repo 入口处捕获一次；批量提交只发一个事件。
    final repo = _repo;
    await DataChangeBus.instance.scope(() async {
      for (final q in ok) {
        await repo.save(q.copyWith(isOrganized: true));
      }
    });
    return blocked.length;
  }

  /// 批量删除（原 `_batchDelete`）：与错题本同款逐题 try/catch 计数
  /// （FR-36）：每题先按 id 查库——已不在库里的计 missing；删除成功
  /// 计 ok、抛错计 failed，继续下一题；返回 (ok, missing, failed,
  /// 已删 id 集)，页面按实际结果同步本地列表并提示，不再无条件
  /// 全删（旧写法：循环 `await repo.delete(q)` 无 try/catch、无计数
  /// 返回，中途抛错后页面仍把已删的题留在列表里、用户收不到反馈）。
  /// 注意：本方法是逐题删除（每题各自一个事务），与错题本 FR-37
  /// 的整批事务不同——整理页批量删除仍保留逐题容错语义。
  Future<({int ok, int missing, int failed, Set<String> deletedIds})>
  batchDeleteQuestions(List<Question> selected) async {
    // R3-3：批量删除改变队列成员，先加代次，使进行中的旧任务失效。
    state = state.copyWith(generation: state.generation + 1);
    // D-42 + Stage 4：repo 入口处捕获一次；批量提交只发一个事件。
    final repo = _repo;
    var ok = 0;
    var missing = 0;
    var failed = 0;
    final deletedIds = <String>{};
    await DataChangeBus.instance.scope(() async {
      for (final q in selected) {
        if (await repo.questionById(q.id) == null) {
          missing++;
          continue;
        }
        try {
          await repo.delete(q);
          ok++;
          deletedIds.add(q.id);
        } catch (_) {
          failed++;
        }
      }
    });
    return (ok: ok, missing: missing, failed: failed, deletedIds: deletedIds);
  }
}
