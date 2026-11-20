// ARCH-PLAN-A 第 3 阶段：详情页的状态层。
//
// 状态是 [DetailState]（当前题 + 元数据 + 编辑表单值），唯一真源仍是
// SQLite；本 Provider 只做“响应式读取 + 写回”，不另存一份。
// 读：`ref.watch(detailProvider)`；
// 写：`ref.read(detailProvider.notifier).saveEdit(...)` 等。
//
// 详情页有初始入参（题目 id 与来源列表），按 D-35 的
// `wrongbookInitialProvider` 模式用 [detailInitialProvider]
// （[DetailInitial]：`questionId` / `orderIds`）注入，
// Notifier 的 `build()` 里读它定初始题与顺序，不在页面 `initState`
// 里同步改 Provider（Riverpod 禁止在 build / initState 等生命周期
// 里同步改 Provider）。
//
// 文本控制器是页面本地 UI 状态，留在页面里；进编辑时 Notifier 把
// 编辑表单值按当前题重建并把 `formResetKey` 加一，页面按它变化、
// 下一帧把控制器文本按当前题重建（D-40①，见 `question_detail_page.dart`
// 的 `_syncFormFromState`）。折叠区开合、答案可见、编辑/脏态、
// 取消确认框是纯界面状态，留页面本地 setState，不进 Provider。
//
// 重新框选（§1.5.1）的业务在 [DetailNotifier.applyReworkBoxes] 里：
// 裁切片 → 写临时文件 → 单事务换框 + 保存切片 → rename → 清缓存，
// 事务失败只删临时文件、旧切片字节完好（SR2-3）；页图读不出来 /
// 裁不出来、临时文件写不进去、rename 失败各有自己的返回值，
// 页面按返回值弹对应提示。编辑器弹窗本身（`showBoxEditorDialog`）
// 要 `BuildContext`，留在页面里开，结果交进来。
// 切片自愈（SR3-10）也在本 Notifier 里：打开页时校验磁盘切片尺寸与
// 库里是否一致，不一致按当前第一个 1 层框重裁、原子替换，
// 尺寸变了再把库里尺寸改成重裁尺寸；失败静默，下次打开再试。
//
// Provider 是 autoDispose（D-36 结论）：页面独占、随页生死，
// 回页重建并重读库。`build()` 里 `Future.microtask(load)` 首查
// + `_disposed` 守门（沿用 Stage 2/3 模式）。
//
// 构造器接进来的 `repo` 怎么进依赖图：`QuestionDetailPage` 在 build
// 里包一层 `ProviderScope(overrides: [repositoryProvider
// .overrideWithValue(widget.repo), detailInitialProvider
// .overrideWithValue(...)])`——`app.dart` 仍按老样子传，
// 不用改；测试里构造器传 FakeRepo 同样经这一层注入，不用再包
// 一层 ProviderScope。本文件不认识任何 widget，不碰 `BuildContext`、
// 不弹 Dialog、不调导航。角标走 `badgeCountsProvider`（第 4 阶段：
// 订阅 `DataChangeBus`，见 `badge_counts_provider.dart`）。
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/data_change_events.dart';
import '../data/file_lifecycle_guard.dart';
import '../data/repository.dart';
import '../models/models.dart';
import '../modules/ocr/question_classifier.dart';
import '../modules/ocr/stem_correction.dart';
import '../services/glm_ocr_client.dart';
import '../services/import_guess.dart';
import '../services/import_service.dart';
import '../services/ocr_queue.dart';
import '../services/page_image_pipeline.dart';
import 'repository_provider.dart';

/// 详情页业务状态的 Provider：页面出现即读库（见 [DetailNotifier.build]）。
///
/// D-49：必须声明 `dependencies`——Riverpod 3.x 只把 Provider 挂载到
/// 覆写了它已声明传递依赖的最深容器；不声明时挂到根容器，`build()` 里
/// `ref.read(detailInitialProvider)` 读到的是根容器的默认值
/// `questionId: ''`，详情页嵌套 ProviderScope 的 override 不生效，
/// 详情页显示“这道题不存在了”（2026-11-17 诊断）。
final detailProvider =
    NotifierProvider.autoDispose<DetailNotifier, DetailState>(
      DetailNotifier.new,
      dependencies: [detailInitialProvider, repositoryProvider],
    );

/// 详情页的构造参数（初始落点）：题目 id 与来源列表（上一题 / 下一题
/// 按它走）。页面外壳经 `ProviderScope` 注入；Notifier 的 `build()`
/// 里读它，不在 `initState` 里改 Provider（D-35 的
/// `wrongbookInitialProvider` 模式）。
class DetailInitial {
  const DetailInitial({required this.questionId, required this.orderIds});

  final String questionId;
  final List<String> orderIds;

  @override
  bool operator ==(Object other) =>
      other is DetailInitial &&
      other.questionId == questionId &&
      other.orderIds.length == orderIds.length &&
      other.orderIds.asMap().entries.every((e) => e.value == orderIds[e.key]);

  @override
  int get hashCode => Object.hash(questionId, Object.hashAll(orderIds));
}

/// 初始落点 Provider：默认空（无题）；页面外壳按构造参数 override。
final detailInitialProvider = Provider<DetailInitial>(
  (ref) => const DetailInitial(questionId: '', orderIds: []),
);

/// 重新框选确认的结果（原 `_reworkBoxes` 里各失败分支的提示一一对应，
/// 页面按返回值弹提示；成功时 Notifier 已重读，写库已发变更事件）。
enum ReworkOutcome {
  /// 成功：框已换、切片已重裁并落盘、已重读。
  success,

  /// 页图读不出来 / 切片裁不出来。
  cropFailed,

  /// 切片写不进去：数据目录不可用。
  sliceUnavailable,

  /// 重新框选失败：切片写不进去（临时文件写盘失败）。
  tmpWriteFailed,

  /// 重新框选失败：保存失败，请重试（事务失败，只删临时文件）。
  saveFailed,

  /// 重新框选失败：切片保存失败，框已更新，请重试（rename 失败）。
  renameFailed,
}

/// Win11 反馈尾巴 2：保存编辑的结果（底稿过期时不直接保存）。
enum SaveEditOutcome {
  /// 已保存。
  saved,

  /// 底稿过期：进编辑后底下内容变了（自动重算 / 取消识别等），
  /// 本次没写库，由页面弹框让用户选保留编辑还是用新内容。
  stale,

  /// 无进编辑的快照。
  noBase,

  /// 题目已不存在。
  noQuestion,

  /// 写库失败。
  failed,
}

/// `copyWith` 里“显式置 null”与“不改”的区分标记。
const _unset = Object();

/// 详情页的全部业务数据 + 编辑表单值（原 `_QuestionDetailPageState`
/// 里调 `repo` 的字段与编辑表单值原样搬移；文本控制器、折叠区开合、
/// 答案可见、编辑/脏态、取消确认框仍在页面本地，不在这里）。
class DetailState {
  const DetailState({
    this.loading = true,
    this.question,
    this.orderIds = const [],
    this.currentId = '',
    this.records = const [],
    this.history = const [],
    this.exams = const [],
    this.folders = const [],
    this.allTags = const [],
    this.kps = const [],
    this.subjects = const [],
    this.editErrorTypes = const {},
    this.editCustomTypes = const {},
    this.editFolders = const {},
    this.editTags = const {},
    this.editKps = const {},
    this.editExamId,
    this.editBase,
    // 十四批 M1：编辑表单里的题型值（NULL = 待确认；enterEdit 时从当前题读）。
    this.editQuestionType,
    // 十四批 M3：编辑表单里的选项标签值（enterEdit 时从当前题读）。
    this.editOptionLabels,
    this.editOptionLabelsConfirmed = false,
    this.editCorrectOption,
    this.editAnswerReconfirmed = false,
    this.editOptionLabelsJustConfirmed = false,
    // Win11 反馈包 5：编辑表单里的选项文字（enterEdit 时从当前题读）。
    this.editOptionContents,
    this.formResetKey = 0,
    // FR-09：复查间隔（设置 3 / 7 / 14 天，默认 7，D-05）；详情页
    // “满 N 天自动回来复查”文案用它拼，不再写死 7 天。`load()` 读库。
    this.recheckIntervalDays = 7,
    // 十三批 M5：当前题的 OCR 任务行与 key 有无（识别题干状态推导用）。
    this.ocrJobs = const [],
    this.hasOcrApiKey = false,
    // 十三批 P1-2：重框成功但 OCR 入队失败时置真（页面显
    // “题目已更新，OCR 未入队”横幅 + “重新入队”重试入口）；
    // 入队成功 / 无切片可入队 / 切到别的题时为假。
    this.ocrEnqueueFailed = false,
  });

  /// 首查进行中（原 `_loading`；初始 true，首帧先出加载圈）。
  final bool loading;

  /// 当前题（原 `_q`；null 表示题不存在了）。
  final Question? question;

  /// 来源列表（原 `_orderIds`；上一题 / 下一题按它走，删题时去掉已删题）。
  final List<String> orderIds;

  /// 当前题 id（原 `_currentId`）。
  final String currentId;

  /// 当前题的错因记录与全部解决记录。
  final List<CauseRecord> records;
  final List<({String result, DateTime reviewedAt})> history;

  /// 元数据：试卷 / 文件夹（全部学科，原 `_load` 读 `folders()` 不带
  /// 学科过滤——D-40③：不要顺手改成按学科读）/ 标签 / 知识点 / 学科表。
  final List<Exam> exams;
  final List<Folder> folders;
  final List<String> allTags;
  final List<KnowledgePoint> kps;

  /// 学科表：读库 subjects（P0B1 扫尾；以前直接 Subject.byId，
  /// 新学科显示成“数学”）。B8-1 扫尾：空表是删光学科后的合法状态，
  /// 不再回退预设三科；首帧与读库后都以真实列表为准，空就是空。
  final List<Subject> subjects;

  /// 复查间隔天数（设置项，见构造函数注释；默认 7 天）。
  final int recheckIntervalDays;

  /// 十三批 M5：当前题的 OCR 任务行（最新在前）与设置里是否已存
  /// BigModel key。只供识别题干状态推导（[OcrStemSection]）用。
  final List<OcrJob> ocrJobs;
  final bool hasOcrApiKey;

  /// 十三批 P1-2：重框成功但 OCR 入队失败（见 [DetailNotifier.applyReworkBoxes]）。
  /// 只属于置真时的那道题：[DetailNotifier.load] 只在同题重读时保留它，
  /// 切到别的题 / 题不存在时清掉；重试入队成功后也清掉。
  final bool ocrEnqueueFailed;

  // ---- 编辑表单值（当前题；文本框内容在页面控制器里，不在这里） ----

  final Set<String> editErrorTypes;
  final Set<String> editCustomTypes;
  final Set<String> editFolders;
  final Set<String> editTags;
  final Set<String> editKps;
  final String? editExamId;

  /// 十四批 M1：编辑表单里的题型值（NULL = 待确认）。
  final String? editQuestionType;

  // 十四批 M3：编辑表单里的选项标签值（enterEdit 时从当前题读）。
  // editOptionLabelsConfirmed：编辑态确认态；editCorrectOption：
  // 编辑态正确选项（仅单选/判断用）；editAnswerReconfirmed：本次编辑
  // 是否已重确认答案（P1-A 信号）；editOptionLabelsJustConfirmed：
  // 本次编辑点过「确认选项」（保存时带 justConfirmed 信号）。
  final List<String>? editOptionLabels;
  final bool editOptionLabelsConfirmed;
  final String? editCorrectOption;
  final bool editAnswerReconfirmed;
  final bool editOptionLabelsJustConfirmed;

  /// Win11 反馈包 5：编辑表单里的选项文字（标签 → 文字；
  /// enterEdit 时从当前题读；null = 未解析/不显示）。
  final Map<String, String>? editOptionContents;

  /// 进编辑时的题快照（原 `_editBase`；保存时以它为底构造新题，
  /// 学科与图片字段都从它带上，编辑一次不抹图）。
  final Question? editBase;

  /// 表单重置代次：每次进编辑（`enterEdit`）加一，页面按它变化、
  /// 下一帧把控制器文本按当前题重建（原 `_enterEdit` 里设控制器
  /// 文本的部分）。
  final int formResetKey;

  /// 库里找学科：新学科用库里的名与色；找不到才回退 Subject.byId
  ///（数学兜底，只发生在数据不一致时）。
  Subject subjectOf(String id) =>
      subjects.firstWhere((s) => s.id == id, orElse: () => Subject.byId(id));

  DetailState copyWith({
    bool? loading,
    Object? question = _unset,
    List<String>? orderIds,
    String? currentId,
    List<CauseRecord>? records,
    List<({String result, DateTime reviewedAt})>? history,
    List<Exam>? exams,
    List<Folder>? folders,
    List<String>? allTags,
    List<KnowledgePoint>? kps,
    List<Subject>? subjects,
    Set<String>? editErrorTypes,
    Set<String>? editCustomTypes,
    Set<String>? editFolders,
    Set<String>? editTags,
    Set<String>? editKps,
    Object? editExamId = _unset,
    Object? editBase = _unset,
    Object? editQuestionType = _unset,
    Object? editOptionLabels = _unset,
    bool? editOptionLabelsConfirmed,
    Object? editCorrectOption = _unset,
    bool? editAnswerReconfirmed,
    bool? editOptionLabelsJustConfirmed,
    Object? editOptionContents = _unset,
    int? formResetKey,
    int? recheckIntervalDays,
    List<OcrJob>? ocrJobs,
    bool? hasOcrApiKey,
    bool? ocrEnqueueFailed,
  }) {
    return DetailState(
      loading: loading ?? this.loading,
      question: question == _unset ? this.question : question as Question?,
      orderIds: orderIds ?? this.orderIds,
      currentId: currentId ?? this.currentId,
      records: records ?? this.records,
      history: history ?? this.history,
      exams: exams ?? this.exams,
      folders: folders ?? this.folders,
      allTags: allTags ?? this.allTags,
      kps: kps ?? this.kps,
      subjects: subjects ?? this.subjects,
      editErrorTypes: editErrorTypes ?? this.editErrorTypes,
      editCustomTypes: editCustomTypes ?? this.editCustomTypes,
      editFolders: editFolders ?? this.editFolders,
      editTags: editTags ?? this.editTags,
      editKps: editKps ?? this.editKps,
      editExamId: editExamId == _unset
          ? this.editExamId
          : editExamId as String?,
      editBase: editBase == _unset ? this.editBase : editBase as Question?,
      editQuestionType: editQuestionType == _unset
          ? this.editQuestionType
          : editQuestionType as String?,
      editOptionLabels: editOptionLabels == _unset
          ? this.editOptionLabels
          : editOptionLabels as List<String>?,
      editOptionLabelsConfirmed:
          editOptionLabelsConfirmed ?? this.editOptionLabelsConfirmed,
      editCorrectOption: editCorrectOption == _unset
          ? this.editCorrectOption
          : editCorrectOption as String?,
      editAnswerReconfirmed:
          editAnswerReconfirmed ?? this.editAnswerReconfirmed,
      editOptionLabelsJustConfirmed:
          editOptionLabelsJustConfirmed ?? this.editOptionLabelsJustConfirmed,
      editOptionContents: editOptionContents == _unset
          ? this.editOptionContents
          : editOptionContents as Map<String, String>?,
      formResetKey: formResetKey ?? this.formResetKey,
      recheckIntervalDays: recheckIntervalDays ?? this.recheckIntervalDays,
      ocrJobs: ocrJobs ?? this.ocrJobs,
      hasOcrApiKey: hasOcrApiKey ?? this.hasOcrApiKey,
      ocrEnqueueFailed: ocrEnqueueFailed ?? this.ocrEnqueueFailed,
    );
  }
}

/// 详情页业务逻辑（ARCH-PLAN-A 第 3 阶段：原 `question_detail_page.dart`
/// 的 `_QuestionDetailPageState` 里调 `repo` 的部分原样迁入；
/// 页面只留 widget 与本地交互状态——文本控制器、折叠区开合、
/// 答案可见、编辑/脏态、取消确认框、弹窗与 SnackBar）。
///
/// 拿库的方式与 `ReviewNotifier` / `OrganizeNotifier` 一致：经
/// `ref.read(repositoryProvider)` 拿——测试注入见
/// `docs/ui-replication/A-READING-GUIDE.md`（`ProviderContainer.test`
/// + `repositoryProvider.overrideWithValue`）。
class DetailNotifier extends Notifier<DetailState> {
  QuestionRepository get _repo => ref.read(repositoryProvider);

  bool _disposed = false;

  /// SR3-10：切片自愈的去重键（题 id + 切片路径 + 库里记的尺寸）与
  /// 进行中标志。只对同一组合校验一次：尺寸相符或自愈成功后不再
  /// 重复读盘；自愈失败时不记键，下次 load 再试（用户仍可手动重框）。
  String? _sliceHealCheckedKey;
  bool _sliceHealRunning = false;

  /// 十二批功能 4：最近一次已记录查看的题 id。load() 会在收藏 /
  /// 编辑保存等写操作后重读——那不是一次新的“打开”，同题不重复记；
  /// 切到另一题（goTo）或重新打开本页（新 Notifier 实例）时才再记。
  String? _lastViewRecordedId;

  /// 十三批 P1-2：重框入队失败的那道题 id（与 [DetailState.ocrEnqueueFailed]
  /// 配对）。load() 只在重读的还是这道题时保留标志，切到别的题时清掉；
  /// 失败标志本身存在 state 里，load() 的 copyWith 必须显式按它算，
  /// 不能靠“不传参就保留”——load() 之后标志仍须可见（见 load 内注释）。
  String? _ocrEnqueueFailedQuestionId;

  /// Win11 包 4：自动重算已尝试过的输入版本（`classification_input_hash`
  /// 概念的落地：复用现有 `contentVersion` 作输入版本键，与
  /// OrganizeNotifier 同款；同一版本只自动算一次，强制重算不受此门限）。
  final Set<(String, int)> _reclassifiedKeys = {};

  /// 十三批 P1-2（任务 b）：重框入队的可 fake 缝。生产恒为 null——
  /// 此时走冻结契约 [enqueueOcrForQuestion]，await 确认任务已持久化，
  /// 绝不改回 fire-and-forget。真实 Drift 在 widget 测试的 fake async
  /// 下永不完成（M5 §七第二条），详情页重框的 widget 测试不能直接
  /// await 它：测试里把这里设为假实现（返回假任务 / 抛错模拟入队失败），
  /// 用完必须复位（detail_page_test 的 tearDown）。
  /// 真实入队路径由 b13_stem_correction_test 的真实库测试覆盖。
  @visibleForTesting
  static Future<OcrJob?> Function(AppDatabase db, Question question)?
  enqueueOcrForTest;

  /// 缝后统一的入队调用：测试假实现优先，生产走冻结契约。
  static Future<OcrJob?> _enqueueForRework(
    AppDatabase db,
    Question question,
  ) => (enqueueOcrForTest ?? enqueueOcrForQuestion)(db, question);

  @override
  DetailState build() {
    ref.onDispose(() => _disposed = true);
    // 页面出现即读库（原 `initState` 的 `_load`）：不 await，
    // 读完后 state 一次性赋值，首帧先出加载圈。
    Future.microtask(load);
    final initial = ref.read(detailInitialProvider);
    return DetailState(
      orderIds: List.of(initial.orderIds),
      currentId: initial.questionId,
    );
  }

  /// 首读与每次写库后重读（与原来页面的 `_load` 同口径）：
  /// 读当前题 → 错因记录 → 解决记录 → 试卷 / 文件夹（全部学科，
  /// 不带学科过滤，见 `DetailState` 注释）/ 标签 / 知识点 / 学科表。
  /// 读完把当前题交给切片自愈（后台修复，不挡页面渲染，见
  /// `_healSliceIfNeeded`）。
  Future<void> load() async {
    // D-42：build() 的 microtask 首查可能在页面已离开、Provider 已销毁后
    // 才跑——先判 _disposed 再碰 ref；repo 入口处捕获一次，之后不再 ref.read。
    if (_disposed) return;
    final repo = _repo;
    final q = await repo.questionById(state.currentId);
    final records = q == null
        ? <CauseRecord>[]
        : await repo.causeRecordsFor(q.id);
    final history = q == null
        ? <({String result, DateTime reviewedAt})>[]
        : await repo.reviewHistory(q.id);
    final exams = await repo.exams();
    final folders = await repo.folders();
    final tags = await repo.tags();
    final kps = await repo.knowledgePoints();
    final subjects = await repo.subjects();
    // FR-09：复查间隔随详情页一起读库（与复习页 / 报告页同款读法）。
    final settings = await repo.settings();
    if (_disposed) return;
    // 十三批 P1-2：load() 会重建 state——入队失败标志必须按题 id
    // 显式算出来再写进 copyWith，否则 load() 一跑标志就被刷掉，
    // “题目已更新，OCR 未入队”横幅在重框成功提示之后立刻消失。
    // 同题重读（收藏/编辑保存/重框后的重读）保留；切题/题不存在清掉。
    final keepEnqueueFailed =
        _ocrEnqueueFailedQuestionId != null &&
        q?.id == _ocrEnqueueFailedQuestionId;
    state = state.copyWith(
      question: q,
      records: records,
      history: history,
      exams: exams,
      folders: folders,
      allTags: tags,
      kps: kps,
      subjects: subjects,
      recheckIntervalDays: settings.recheckIntervalDays,
      loading: false,
      ocrEnqueueFailed: keepEnqueueFailed,
    );
    // 十三批 M5：读当前题的 OCR 任务行与 key 有无（状态推导用）。
    // 不 await：它是装饰性 best-effort 加载，失败/挂起都不能挡
    // 详情加载的后续流程（记查看、自愈）；读到了再更新 state。
    unawaited(_refreshOcrStatus(q));
    // 十二批功能 4（D-91）：题目加载成功后记一次查看（同一题只留一条，
    // 时间更新为最后一次）。D-88：load() 本来就没有 try/catch，任一
    // repo 抛错都会停在 loading——记录失败必须自己吞掉，绝不能拖垮
    // 详情加载；题不存在（q == null）时不记；同题重复 load（收藏 /
    // 编辑保存后的重读、build 微任务首查与显式 load 的重合）不重复记，
    // 只在切到另一题或重新打开本页时再记。标志位在 await 之前先置——
    // 两路 load 并发时检查-await 之间会交错，都通过检查就记了两次；
    // 失败时清掉标志，下次 load 再试一次。
    if (q != null && q.id != _lastViewRecordedId) {
      _lastViewRecordedId = q.id;
      try {
        await repo.recordQuestionViewed(q.id);
      } catch (_) {
        // 记录失败静默：首页历史少一条，不影响本题的详情展示。
        _lastViewRecordedId = null;
      }
    }
    // SR3-10：打开详情页时自愈“库新图旧”的崩溃窗口（事务提交后、
    // rename 前被杀）。不 await：自愈是后台修复，不挡页面渲染；
    // 失败静默（见方法内注释），下次打开再试。
    if (q != null) unawaited(_healSliceIfNeeded(q));
    // Win11 包 4：题型待确认且非人工指定时，自动重算一次（best-effort，
    // 不挡详情加载；同一输入版本只算一次，见 reclassifyCurrent）。
    unawaited(reclassifyCurrent());
  }

  /// Win11 包 4：自动 / 强制重算当前题的题型（见 [reclassifiedQuestion]；
  /// 与 OrganizeNotifier 同款，另加编辑态规则）。
  ///
  /// 自动（`force` 为 false）：用户正在编辑时拒绝（返回 'editing'，
  /// 不动编辑表单）；仅当题型待确认且来源非 manual 时重算；同一输入
  /// 版本只算一次（`_reclassifiedKeys` 守门，计算前先记键）。
  /// 强制（`force` 为 true）：忽略“编辑中 / 已定型 / 已算过”守门
  /// （“重新分类”按钮用，查看态与编辑态共用），manual 与无原文仍拒绝；
  /// 编辑态强制重算成功后同步 `editQuestionType`（编辑表单的题型值），
  /// 但不动 `editBase`——保存时 [saveEdit] 会检测底稿过期（Win11 反馈
  /// 尾巴 2）：进编辑后重算已落库时返回 stale，由页面弹框让用户选
  /// 保留编辑还是用新内容，不再静默写回旧值。
  /// 返回码：'updated' / 'unchanged' / 'already_typed' /
  /// 'already_attempted' / 'manual' / 'no_raw' / 'no_question' /
  /// 'editing' / 'save_failed'。写库用 SaveToken（期望版本取自重算
  /// 前模型），版本冲突即失败不覆盖。
  Future<String> reclassifyCurrent({bool force = false}) async {
    final q = state.question;
    if (q == null) return 'no_question';
    if (!force && state.editBase != null) return 'editing';
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
    state = state.copyWith(question: updated);
    if (force && state.editBase != null) {
      state = state.copyWith(editQuestionType: updated.questionType);
    }
    return 'updated';
  }

  /// SR3-10（a）：校验磁盘切片的实际尺寸与库里 [sliceWidth] /
  /// [sliceHeight] 是否一致。不一致时按当前第一个 1 层框重裁一次、
  /// 写新切片文件；重裁尺寸与库里记的不一样时再把库里尺寸改成
  /// 重裁尺寸（框可能在崩溃后又被改过）。
  /// 十三批 P1-1：切片不可变——
  /// - 库里路径的文件不存在（重框事务已提交、rename 前被杀）：按当前
  ///   框重裁，直接写到库里记的路径（该路径尚无文件，是首写不是覆盖）；
  /// - 文件存在但尺寸不符（旧崩溃窗口的残留）：写新的版本化路径
  ///   （[ImportService.nextSliceRelative]），旧文件字节不动，
  ///   库里 slice_path 指到新文件；旧候选如来自旧切片则标 stale。
  /// 页图缺失/损坏、框缺失时同样静默放弃——用户仍可手动“重新框选”，
  /// 打开页时不弹提示打扰。
  Future<void> _healSliceIfNeeded(Question q) async {
    if (q.slicePath == null || q.sliceWidth == null || q.sliceHeight == null) {
      return;
    }
    // D-42：repo 入口处捕获一次（读框与改尺寸跨多次 await）。
    final repo = _repo;
    final key = '${q.id}|${q.slicePath}|${q.sliceWidth}x${q.sliceHeight}';
    if (key == _sliceHealCheckedKey || _sliceHealRunning) return;
    _sliceHealRunning = true;
    try {
      final sliceAbs = AppDatabase.resolveDataPath(q.slicePath!);
      if (sliceAbs == null) return;
      final sliceFile = File(sliceAbs);
      // 文件不存在：重框事务已提交、rename 前被杀的残留——按当前框
      // 重裁后直接写到库里记的路径（首写）；文件存在且尺寸相符时
      // 不用自愈；存在但尺寸不符时写版本化新路径（见下）。
      var missingFile = false;
      if (!sliceFile.existsSync()) {
        missingFile = true;
      } else {
        final dims = pngDimensions(await sliceFile.readAsBytes());
        if (dims != null &&
            dims.width == q.sliceWidth &&
            dims.height == q.sliceHeight) {
          _sliceHealCheckedKey = key;
          return;
        }
      }
      // 尺寸不符（或切片已不是合法 PNG / 文件缺失）：按当前框重裁。
      if (q.pageImagePath == null) return;
      final pageAbs = AppDatabase.resolveDataPath(q.pageImagePath!);
      if (pageAbs == null || !File(pageAbs).existsSync()) return;
      final pageBytes = await File(pageAbs).readAsBytes();
      final boxes = await repo.boxesForPageImage(q.pageImagePath!);
      final first = boxes
          .where((b) => b.questionId == q.id && b.layer == 1)
          .firstOrNull;
      if (first == null) return;
      final crop = await cropBoxPng(pageBytes, first);
      final tmpRel =
          'slices/${q.id}.tmp-heal-${DateTime.now().millisecondsSinceEpoch}-${math.Random().nextInt(1 << 32)}.png';
      final tmpAbs = AppDatabase.resolveDataPath(tmpRel);
      if (tmpAbs == null) return;
      // 缺失时写回库里记的路径（首写）；存在但尺寸不符时写版本化
      // 新路径，旧文件字节永不动（十三批 P1-1 不可变切片）。
      final targetRel = missingFile
          ? q.slicePath!
          : ImportService.nextSliceRelative(q.id);
      final targetAbs = AppDatabase.resolveDataPath(targetRel);
      // 十四批 M2（P1-B 写文件协议）：临时文件创建前登记临时路径；
      // rename 前登记正式目标路径；成功后解除临时登记，正式登记保留
      // 到 repo.save 提交后——save 前库里还不指向新路径，孤儿清理按
      // 数据库引用会误判，登记是这段窗口的唯一保护。finally 解除
      // 两条登记（save 失败时正式文件成孤儿，由孤儿清理接住）。
      final guard = FileLifecycleGuard.instance;
      guard.registerPending(tmpRel);
      try {
        if (targetAbs == null) {
          await guard.deleteFile(File(tmpAbs));
          return;
        }
        await File(tmpAbs).parent.create(recursive: true);
        // WP-C #8 U3-1：写盘持守门——备份复制与写盘串行化，不读半写文件。
        await guard.withLock(() => File(tmpAbs).writeAsBytes(crop.png));
        guard.registerPending(targetRel);
        try {
          // WP-C #8 U3-1：改名持守门（与备份复制串行化）。
          await guard.withLock(() => File(tmpAbs).rename(targetAbs));
        } catch (_) {
          await guard.deleteFile(File(tmpAbs));
          return;
        }
        guard.unregisterPending(tmpRel);
        await evictCachedFileImage(targetAbs);
        var updated = q.copyWith(
          slicePath: targetRel,
          sliceWidth: crop.width,
          sliceHeight: crop.height,
        );
        // 新切片内容变了：旧候选如来自旧切片，标 stale（纯函数，
        // 无候选或 hash 一致时原样返回，不动版本）。
        try {
          final newHash = await sha256HexOfFile(File(targetAbs));
          updated = markCandidateStale(updated, newHash);
        } catch (_) {}
        await repo.save(updated);
      } finally {
        guard.unregisterPending(tmpRel);
        guard.unregisterPending(targetRel);
      }
      _sliceHealCheckedKey =
          '${q.id}|$targetRel|${crop.width}x${crop.height}';
      if (!_disposed) await load();
    } catch (e) {
      // 自愈是后台兜底：任何一步失败都不打扰用户、不抛到界面，
      // 只记日志；下次打开详情页（load）会再试一次。
      // 页面已离开（Provider 已销毁）时尾部的重读会因 ref 已销毁而抛错，
      // 那不是自愈本身失败，不记日志。
      if (_disposed) return;
      debugPrint('SR3-10：切片自愈失败（${q.id}）：$e');
    } finally {
      _sliceHealRunning = false;
    }
  }

  /// 十三批 M5：只刷新当前题的 OCR 状态（任务行 + key 有无）。
  /// 不碰编辑表单值与 formResetKey。读库失败时保持旧值，不抛。
  Future<void> _refreshOcrStatus([Question? question]) async {
    final q = question ?? state.question;
    if (q == null || _disposed) return;
    final repo = _repo;
    try {
      final jobs = await repo.ocrJobsForQuestion(q.id);
      final hasKey = await repo.hasOcrApiKey();
      if (_disposed || state.question?.id != q.id) return;
      state = state.copyWith(ocrJobs: jobs, hasOcrApiKey: hasKey);
    } catch (_) {
      // OCR 状态读不到：界面按题本身的 OCR 字段推导，不挡详情。
    }
  }

  /// 十三批 M5：活页内刷新守门后的单题刷新（页面订阅 DataChangeBus
  /// 的 questions 事件后调，见 question_detail_page.dart 的 _onDataChange）。
  /// 只重读当前题 + 它的 OCR 任务行与 key 有无；编辑表单值
  /// （editBase / edit*）与 formResetKey 都原样保留——
  /// 主编辑表单的控制器不会被重建；题干纠错编辑器的草稿是
  /// StemEditor 的本地状态，换题才重建，同题只显“有新的识别结果”
  /// 横幅。调用方（页面）须先守门：纠错编辑器正开着时不调本方法，
  /// 改走 [candidateStemFor] 只取候选。
  Future<void> refreshStemStatus() async {
    if (_disposed) return;
    final repo = _repo;
    try {
      final q = await repo.questionById(state.currentId);
      if (q == null || _disposed) return;
      final jobs = await repo.ocrJobsForQuestion(q.id);
      final hasKey = await repo.hasOcrApiKey();
      if (_disposed) return;
      state = state.copyWith(
        question: q,
        ocrJobs: jobs,
        hasOcrApiKey: hasKey,
      );
    } catch (_) {
      // OCR 状态读不到：保持旧行，不挡详情。
    }
  }

  /// 十三批 M5：读一道题的候选题干（守门分支用，不改任何状态）。
  Future<String?> candidateStemFor(String questionId) =>
      candidateStemForQuestion(_repo, questionId);

  // ---------- 十三批 M5：纠错保存（见 stem_correction.dart 的规则） ----------

  /// 保存手动编辑的题干：版本 +1、人工标记、切分状态“人工调整”、
  /// 候选标志清掉；成功后更新 state.question（编辑表单值不动）。
  /// 返回 false 时页面提示“保存失败，请重试”，编辑器不收起。
  Future<bool> saveStemEdit(String newStem) async {
    final q = state.question;
    if (q == null) return false;
    final repo = _repo;
    try {
      final updated = applyManualStemEdit(q, newStem);
      await repo.save(updated);
      if (!_disposed) state = state.copyWith(question: updated);
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

  /// 接受候选并返回结果（十三批 P1-2 任务 e；Win11 反馈尾巴 1：
  /// 成功时 [AcceptCandidateOutcome.reason] 为 null，
  /// [AcceptCandidateOutcome.unmatchedManualIds] 是接受时没匹配上
  /// 的手动图块 ID——已保留在末尾，页面据此提示用户一次）：失败时
  /// reason 是 [CandidateRejection.reason]（question_deleted /
  /// no_candidate / not_pending / hash_mismatch / slice_missing），
  /// 其余失败（写库等）返回 'save_failed'，无当前题返回 'no_question'，
  /// 此时 unmatchedManualIds 为空。页面按 reason 给明确文案（见
  /// ocr_stem_section.dart 的 [candidateRejectionMessage]），不要
  /// 只显示通用“保存失败，请重试”。
  Future<AcceptCandidateOutcome> acceptOcrCandidateOutcome() async {
    final q = state.question;
    if (q == null) return const AcceptCandidateOutcome(reason: 'no_question');
    final repo = _repo;
    try {
      // 十三批 P1 第二轮：acceptCandidateStem 在事务内原子校验并落库，
      // 返回的就是已保存的题，不再另行 repo.save。
      final accepted = await acceptCandidateStem(repo, q);
      if (!_disposed) state = state.copyWith(question: accepted.question);
      return AcceptCandidateOutcome(
        reason: null,
        unmatchedManualIds: accepted.unmatchedManualIds,
      );
    } on CandidateRejection catch (e) {
      return AcceptCandidateOutcome(reason: e.reason);
    } catch (_) {
      return const AcceptCandidateOutcome(reason: 'save_failed');
    }
  }

  /// 忽略候选：只清 raw 里的候选标志（版本 +1）。无候选时直接返回 true。
  Future<bool> dismissOcrCandidate() async {
    final q = state.question;
    if (q == null) return true;
    if (!hasPendingOcrCandidate(q)) return true;
    final repo = _repo;
    try {
      final updated = dismissOcrCandidateFlag(q);
      await repo.save(updated);
      if (!_disposed) state = state.copyWith(question: updated);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 删除单个图块（十四批 M2）：只更新数据库引用（ocr_figures 去掉
  /// 该项），content_version +1（图块变化；版本由 upsert 的版本权威
  /// 按实际内容变化统一计算，只 +1 一次）；旧文件不立即删，进孤儿清理。
  /// 无该图块时直接返回 true。返回 false 时页面提示，编辑器里该段保持原样。
  Future<bool> deleteFigure(String figureId) async {
    final q = state.question;
    if (q == null) return false;
    final repo = _repo;
    try {
      final updated = deleteFigureFromQuestion(q, figureId);
      if (identical(updated, q)) return true;
      await repo.save(updated);
      if (!_disposed) state = state.copyWith(question: updated);
      return true;
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
  /// 其余与 [deleteFigure] 同款（落库后更新 state，失败返回 false）。
  Future<bool> reorderFigure(
    List<String> orderedFigureIds,
    String movedFigureId,
    String movedTextAt,
  ) async {
    final q = state.question;
    if (q == null) return false;
    final repo = _repo;
    try {
      final updated = reorderFiguresInQuestion(
        q,
        orderedFigureIds,
        movedFigureId,
        movedTextAt,
      );
      await repo.save(updated);
      if (!_disposed) state = state.copyWith(question: updated);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 手动“重新识别”：为当前题建 OCR 任务（调 M3 入队接口），
  /// 入队后刷新任务行。入队失败（无切片等）返回 false，页面提示。
  /// 十三批 P1-1：入队失败抛错时这里接住返回 false（P1-2 改为向
  /// 用户展示“OCR 未入队”+重试入口）。
  Future<bool> rerecognizeCurrent() async {
    final q = state.question;
    if (q == null) return false;
    OcrJob? job;
    try {
      job = await enqueueOcrForQuestion(_repo.db, q);
    } catch (_) {
      return false;
    }
    if (job == null) return false;
    // 任务行刷新不 await（best-effort：读到了再更新 state，见上）。
    unawaited(_refreshOcrStatus(q));
    return true;
  }

  /// Win11 反馈包 2：取消当前题的识别（任务标 cancelled + OCR 字段
  /// 清空，只留切片；见 [OcrWorker.cancelOcrForQuestion]）。
  /// 返回码与 OrganizeNotifier.cancelOcrCurrent 同款。成功后重读题行
  /// + 任务行（[refreshStemStatus]）。editBase 不动——编辑中取消后
  /// 保存时 [saveEdit] 会检测到底稿过期（Win11 反馈尾巴 2），返回
  /// stale 由页面弹框让用户选，不再把已清的 OCR 静默写回。
  Future<String> cancelOcrCurrent() async {
    final q = state.question;
    if (q == null) return 'no_question';
    String code;
    try {
      code = await cancelOcrForQuestion(_repo.db, q.id);
    } catch (_) {
      return 'failed';
    }
    if (code == 'cancelled') {
      await refreshStemStatus();
    }
    return code;
  }

  // ---------- 编辑 ----------

  /// 进编辑模式（原 `_enterEdit` 里表单值的部分）：按当前题重建
  /// 编辑表单值，`formResetKey` 加一，页面按它变化、下一帧把控制器
  /// 文本按当前题重建。无当前题时直接返回。折叠区展开、焦点字段
  /// 由页面本地处理，不进这里。
  void enterEdit() {
    final q = state.question;
    if (q == null) return;
    state = state.copyWith(
      editBase: q,
      // SR-P2-27：旧数据里与固定枚举同名的自定义错因，读入编辑表单时
      // 就合并进固定项（不丢错因、不重复显示）；保存时写回即完成迁移。
      editErrorTypes: {
        ...q.errorTypes,
        ...q.customErrorTypes.where((t) => ErrorTypes.fixed.contains(t)),
      },
      editCustomTypes: q.customErrorTypes
          .where((t) => !ErrorTypes.fixed.contains(t))
          .toSet(),
      editFolders: q.folderIds.toSet(),
      editTags: q.tags.toSet(),
      editKps: q.knowledgePointIds.toSet(),
      editExamId: q.examId,
      editQuestionType: q.questionType,
      // 十四批 M3：选项标签编辑值从当前题读；重确认信号是单次编辑信号，
      // 进编辑即清零（不跨编辑带）。
      editOptionLabels:
          q.optionLabels == null ? null : List.of(q.optionLabels!),
      editOptionLabelsConfirmed: q.optionLabelsConfirmed,
      editCorrectOption: q.correctOption,
      editAnswerReconfirmed: false,
      editOptionLabelsJustConfirmed: false,
      // Win11 反馈包 5：编辑表单里的选项文字从当前题读。
      editOptionContents: q.optionContents == null
          ? null
          : Map<String, String>.of(q.optionContents!),
      formResetKey: state.formResetKey + 1,
    );
  }

  // ---------- 编辑表单值：具名改动口（D-35：优先用命名方法，少用泛型 update） ----------

  void toggleEditFolder(String id) {
    final ids = {...state.editFolders};
    if (ids.contains(id)) {
      ids.remove(id);
    } else {
      ids.add(id);
    }
    state = state.copyWith(editFolders: ids);
  }

  void toggleEditKp(String id) {
    final ids = {...state.editKps};
    if (ids.contains(id)) {
      ids.remove(id);
    } else {
      ids.add(id);
    }
    state = state.copyWith(editKps: ids);
  }

  /// 十四批 M1：编辑表单里的题型改动（只改表单值，保存时落盘）。
  void setEditQuestionType(String? type) {
    state = state.copyWith(editQuestionType: type);
  }

  /// 十四批 M3：编辑表单里的选项标签改动（只改表单值，保存时落盘；
  /// 数据层 _applyOptionLabelChangeRules 再按改标签规则处理确认清零
  /// 与 P1-A）。标签清空时确认态一并清零。
  void setEditOptionLabels(List<String>? labels) {
    state = state.copyWith(
      editOptionLabels: labels,
      editOptionLabelsConfirmed:
          labels == null ? false : state.editOptionLabelsConfirmed,
    );
  }

  /// Win11 反馈包 5：编辑表单里的选项文字改动（只改表单值，保存时
  /// 落盘）。删标签的键由编辑器与数据层剪枝，这里只接编辑器上报的
  /// 完整映射。
  void setEditOptionContents(Map<String, String>? contents) {
    state = state.copyWith(editOptionContents: contents);
  }

  /// 十四批 M3：编辑表单里的正确选项改动（只改表单值，保存时落盘）。
  /// 点选正确选项即重确认（D-133）。
  void setEditCorrectOption(String? value) {
    state = state.copyWith(
      editCorrectOption: value,
      editAnswerReconfirmed: true,
    );
  }

  /// 十四批 M3：P1-A 重确认复选框（编辑态）。
  void setEditAnswerReconfirmed(bool value) {
    state = state.copyWith(editAnswerReconfirmed: value);
  }

  /// 十四批 M3：编辑态点「确认选项」——把编辑态确认态置 1 并记
  /// justConfirmed 信号（点「保存」落盘时带上）；只改表单值，不写库。
  void confirmEditOptionLabels({
    required List<String>? labels,
    required String? correctOption,
    required bool answerReconfirmed,
  }) {
    state = state.copyWith(
      editOptionLabels: labels,
      editCorrectOption: correctOption,
      editAnswerReconfirmed: answerReconfirmed,
      editOptionLabelsConfirmed: true,
      editOptionLabelsJustConfirmed: true,
    );
  }

  /// 十四批 M3：查看态直接改选项标签块（点「确认选项」或正确选项
  /// 即时保存时调；与题型 chip 的即时保存口径一致）。[confirmLabels]
  /// 为 true 时把标签置为已确认并带 justConfirmed 信号；为 false 时
  /// 保持库里原确认状态（正确选项即时保存时用）。保存后重读。
  /// Win11 反馈包 5：[optionContents] 是本次要保存的选项文字
  ///（缺省 = 不改；显式传 null = 清空）。删标签的键剪枝由数据层做。
  Future<void> saveOptionBlock({
    required List<String>? labels,
    required String? correctOption,
    required bool confirmLabels,
    required bool answerReconfirmed,
    Object? optionContents = _unset,
  }) async {
    final q = state.question;
    if (q == null) return;
    // Win11 反馈包 5：判断题不走选项解析——本题型时选项文字强制
    // 清空，不把旧内容带过去。
    final contents = q.questionType == 'true_false'
        ? null
        : (optionContents == _unset
            ? q.optionContents
            : optionContents as Map<String, String>?);
    final updated = q.copyWith(
      optionLabels: labels,
      clearOptionLabels: labels == null && q.optionLabels != null,
      optionLabelsConfirmed:
          confirmLabels ? true : q.optionLabelsConfirmed,
      correctOption: correctOption,
      clearCorrectOption:
          correctOption == null && q.correctOption != null,
      optionContents: contents,
      clearOptionContents: contents == null && q.optionContents != null,
      answerReconfirmed: answerReconfirmed,
      optionLabelsJustConfirmed: confirmLabels,
    );
    await _repo.save(updated);
    await load();
  }

  /// 十四批 M1：查看态直接改题型（点 chip → 选择器 → 立即保存）。
  /// 值不变不写库（不把自动分类静默锁成人工）；值变了走
  /// [withManualQuestionType]（source=manual，题型值变才 +1）。
  Future<void> setQuestionType(String? newType) async {
    final q = state.question;
    if (q == null || newType == q.questionType) return;
    await _repo.save(withManualQuestionType(q, newType));
    await load();
  }

  void toggleEditErrorType(String t) {
    final list = {...state.editErrorTypes};
    if (list.contains(t)) {
      list.remove(t);
    } else {
      list.add(t);
    }
    state = state.copyWith(editErrorTypes: list);
  }

  void toggleEditTag(String t) {
    final list = {...state.editTags};
    if (list.contains(t)) {
      list.remove(t);
    } else {
      list.add(t);
    }
    state = state.copyWith(editTags: list);
  }

  void removeEditCustomType(String t) {
    state = state.copyWith(
      editCustomTypes: state.editCustomTypes.where((x) => x != t).toSet(),
    );
  }

  void setEditExamId(String? id) {
    state = state.copyWith(editExamId: id);
  }

  /// 保存编辑（原 `_saveEdit`）：文本框内容由页面从控制器读了传进来。
  /// SR-P2-27：与固定枚举同名的自定义错因合并进固定项再保存（旧代码
  /// 在这里直接滤掉，错因静默消失；新建入口已拦同名，这里是兜底，
  /// 覆盖旧数据里已有的同名自定义项）。保存后重读（原 `_saveEdit`
  /// 末尾的 `_load`）。无进编辑的快照时返回 [SaveEditOutcome.noBase]。
  ///
  /// Win11 反馈尾巴 2：底稿过期检测——保存前重读库里行比
  /// [Question.contentVersion]，进编辑后底下内容变了（自动重算改了
  /// 题型、取消识别清了 OCR）时返回 [SaveEditOutcome.stale]、零写入，
  /// 由页面弹框让用户选；[force] 为 true 时是用户明确选了“保留我的
  /// 编辑”，不预检、不带令牌，按旧底稿覆盖写回。非强制保存带
  /// [SaveToken]（期望版本取自进编辑时的底稿）：预检与落库之间底下
  /// 又变了时令牌在事务内拦下，同样返回 stale。题型归属沿用旧口径：
  /// 表单题型与底稿一致时不动来源，改过才走 manual——保留编辑时按
  /// 表单原有的走；用新内容时页面直接丢弃表单、重读新行，新行归属
  /// 原样保留。
  Future<SaveEditOutcome> saveEdit({
    required String title,
    required String answer,
    required String explanation,
    required String notes,
    bool force = false,
  }) async {
    final base = state.editBase;
    if (base == null) return SaveEditOutcome.noBase;
    // D-42：repo 入口处捕获一次（保存 + 同步错因记录跨两次 await）。
    final repo = _repo;
    if (!force) {
      final fresh = await repo.questionById(base.id);
      if (fresh == null) return SaveEditOutcome.noQuestion;
      if (fresh.contentVersion != base.contentVersion) {
        return SaveEditOutcome.stale;
      }
    }
    final fixedFromCustom = state.editCustomTypes
        .where((t) => ErrorTypes.fixed.contains(t))
        .toList();
    final customNew = state.editCustomTypes
        .where((t) => !ErrorTypes.fixed.contains(t))
        .toList();
    final errorTypes = {...state.editErrorTypes, ...fixedFromCustom}.toList();
    // 十四批 M3：correct_option 只用于单选/判断（M3-4）——编辑后题型
    // 不是这两者时强制为空，不把旧单选题的 correct_option 带过去。
    final effectiveCorrect =
        (state.editQuestionType == 'choice_single' ||
            state.editQuestionType == 'true_false')
        ? state.editCorrectOption
        : null;
    final updated = Question(
      id: base.id,
      title: title.trim().isEmpty ? base.title : title.trim(),
      subjectId: base.subjectId,
      folderIds: state.editFolders.toList(),
      examId: state.editExamId,
      knowledgePointIds: state.editKps.toList(),
      errorTypes: errorTypes,
      customErrorTypes: customNew,
      tags: state.editTags.toList(),
      answer: answer.trim().isEmpty ? null : answer.trim(),
      explanation: explanation.trim().isEmpty ? null : explanation.trim(),
      notes: notes.trim().isEmpty ? null : notes.trim(),
      reviewCount: base.reviewCount,
      isOrganized: base.isOrganized,
      isDemo: base.isDemo,
      isFavorite: base.isFavorite,
      isArchived: base.isArchived,
      reviewJoined: base.reviewJoined,
      createdAt: base.createdAt,
      sliceKind: base.sliceKind,
      sliceText: base.sliceText,
      // P2 §1.2：图片字段是本题的身份，编辑表单不改它们——
      // 全新构造时必须从 base 带上，否则编辑一次就把
      // sourcePath/slicePath 等抹掉，题变成“无图题”。
      sourcePath: base.sourcePath,
      sourceKind: base.sourceKind,
      sourcePage: base.sourcePage,
      pageImagePath: base.pageImagePath,
      slicePath: base.slicePath,
      sliceWidth: base.sliceWidth,
      sliceHeight: base.sliceHeight,
      // 十三批 M5：编辑表单不改 OCR 内容——全新构造时必须从 base 带上，
      // 否则编辑一次就把 ocr_stem / ocr_raw / 人工标记 / 内容版本
      // 全抹掉（旧代码漏了这 5 个字段，题干纠错成果会被一次普通编辑清零）。
      ocrRaw: base.ocrRaw,
      ocrStem: base.ocrStem,
      ocrSplitStatus: base.ocrSplitStatus,
      ocrManualEdited: base.ocrManualEdited,
      contentVersion: base.contentVersion,
      // 十四批 M1：编辑表单不改以下字段——全新构造时必须从 base 带上，
      // 否则编辑一次就把题型/背景标签/图块/答案版本全抹掉。
      questionType: base.questionType,
      questionTypeSource: base.questionTypeSource,
      questionBackgroundTags: base.questionBackgroundTags,
      questionBackgroundTagsSource: base.questionBackgroundTagsSource,
      ocrFigures: base.ocrFigures,
      // 十四批 M3：选项标签块走编辑表单值（enterEdit 时从题读入）；
      // answerPendingRecheck 从 base 带上（D-141：不带它时编辑一次
      // 无关字段就会静默清掉待核对标记；清除时机只由数据层
      // _applyOptionLabelChangeRules 决定）；重确认信号随保存带上。
      correctOption: effectiveCorrect,
      optionLabels: state.editOptionLabels,
      optionLabelsConfirmed: state.editOptionLabelsConfirmed,
      answerVersion: base.answerVersion,
      answerPendingRecheck: base.answerPendingRecheck,
      answerReconfirmed: state.editAnswerReconfirmed,
      optionLabelsJustConfirmed: state.editOptionLabelsJustConfirmed,
      // Win11 反馈包 5：选项文字走编辑表单值（enterEdit 时已从题读入；
      // 未解析时为 null，构造即 null，不误删）。解析器版本从 base 带上
      //（版本只说明最初解析用的规则，内容以库里值为准）。题型改成判断题
      // 时选项文字与版本一并清空（判断题不走选项解析）。
      optionContents: state.editQuestionType == 'true_false'
          ? null
          : state.editOptionContents,
      optionContentsParserVersion: state.editQuestionType == 'true_false'
          ? null
          : base.optionContentsParserVersion,
    );
    // 十四批 M1：题型值变了才走 manual 口径（source=manual、+1）；
    // 值不变不碰来源保护位。
    final typed = state.editQuestionType == base.questionType
        ? updated
        : withManualQuestionType(updated, state.editQuestionType);
    // FR-02：save 先发角标事件、syncCauseRecords 后写库时，角标重读
    // 可能抢在同步提交前；与 joinReviewBatch 同款用 scope 包起来，
    // 事件在同步提交后才合并发出一次。
    try {
      await DataChangeBus.instance.scope(() async {
        await repo.save(
          typed,
          token: force
              ? null
              : SaveToken(
                  questionId: base.id,
                  expectedContentVersion: base.contentVersion,
                ),
        );
        await repo.syncCauseRecords(typed);
      });
    } on SaveTokenMismatch {
      // 预检与落库之间底下又变了：令牌在事务内拦下、零写入。
      return SaveEditOutcome.stale;
    } catch (_) {
      return SaveEditOutcome.failed;
    }
    await load();
    return SaveEditOutcome.saved;
  }

  // ---------- 上一题 / 下一题 / 删除 ----------

  /// 切到 [id] 对应的题（原 `_goTo` 里改下标 + `_load` 的部分）：
  /// 改当前题 id 并重读。编辑态等纯界面状态由页面先复位，不进这里。
  Future<void> goTo(String id) async {
    state = state.copyWith(currentId: id);
    await load();
  }

  /// 删除当前题（原 `_doDelete` 里删库 + 定下一题的部分）：
  /// 返回下一题 id；没有下一题时返回 null（页面离开本页）。
  /// 删后把已删题从来源列表里去掉；有下一题时切过去并重读。
  Future<String?> deleteCurrent() async {
    final q = state.question;
    if (q == null) return null;
    final idx = state.orderIds.indexOf(q.id);
    final nextId = idx >= 0 && idx + 1 < state.orderIds.length
        ? state.orderIds[idx + 1]
        : null;
    await _repo.delete(q);
    final orderIds = [...state.orderIds]..remove(q.id);
    state = state.copyWith(orderIds: orderIds);
    if (nextId != null && nextId != q.id) {
      state = state.copyWith(currentId: nextId);
      await load();
      return nextId;
    }
    return null;
  }

  // ---------- 收藏 / 归档 / 加入复习 ----------

  /// 收藏切换（原 `_toggleFavorite`）：写库后重读。
  Future<void> toggleFavorite() async {
    final q = state.question;
    if (q == null) return;
    await _repo.toggleFavorite(q);
    await load();
  }

  /// 归档切换（原 `_toggleArchive`）：写库后重读。
  Future<void> toggleArchive() async {
    final q = state.question;
    if (q == null) return;
    await _repo.archive(q, archived: !q.isArchived);
    await load();
  }

  /// 加入 / 取消加入复习（原 `_toggleReviewJoined`）：
  /// 返回 false 时页面弹“先补错误类型”（未加入且无错因，或写库
  /// 返回 false）。成功后重读；写库已发变更事件。
  Future<bool> toggleReviewJoined() async {
    final q = state.question;
    if (q == null) return false;
    if (!q.reviewJoined) {
      if (q.allCauses.isEmpty) return false;
      final ok = await _repo.setReviewJoined(q, true);
      if (!ok) return false;
    } else {
      await _repo.setReviewJoined(q, false);
    }
    await load();
    return true;
  }

  // ---------- 重新框选 §1.5.1 ----------

  /// 读同页全部 1 层框（原 `_reworkBoxes` 开头的读框；页面按题 id
  /// 分目标题 / 只读他题，再开编辑器弹窗）。
  Future<List<QuestionBox>> boxesForPageImage(String pageImagePath) =>
      _repo.boxesForPageImage(pageImagePath);

  /// 重新框选确认后的业务（原 `_reworkBoxes` 里编辑器返回之后的部分）：
  /// 重裁切片 → 先写临时文件再落库（SR2-3：旧写法先原地覆盖正式
  /// 切片，事务失败时 catch 删掉的是刚覆盖掉旧图的唯一一份切片，
  /// 题从此无图。改成临时文件 + 事务成功后 rename，失败只删临时
  /// 文件，旧切片字节完好、框与题不动）。
  /// SR3-11：读页图 + 裁切片同样可能失败（页图损坏截断、框落在图外），
  /// 与写临时文件/事务/rename 三处同款包 try/catch，失败给返回值、
  /// 不抛到按钮回调。
  /// 成功时清 FileImage 缓存并重读（原 `_reworkBoxes` 末尾的
  /// `_load`）；页面弹“已重新框选，切片已更新”。写库已发变更事件。
  /// [pageAbs] 是页图的绝对路径（页面已校验文件存在才调进来）；
  /// [newLayer1] 非空（页面已校验“至少保留一个题级框”才调进来）。
  Future<ReworkOutcome> applyReworkBoxes(
    List<QuestionBox> newLayer1,
    String pageAbs,
  ) async {
    final q = state.question;
    if (q == null) return ReworkOutcome.cropFailed;
    // D-42：repo 入口处捕获一次（裁切片与写库之间有多次 await）。
    final repo = _repo;
    final ({Uint8List png, int width, int height}) crop;
    try {
      final pageBytes = await File(pageAbs).readAsBytes();
      final first = newLayer1.first;
      crop = await cropBoxPng(pageBytes, first);
    } catch (_) {
      return ReworkOutcome.cropFailed;
    }
    // 十三批 P1-1：重框写新切片必须用版本化文件名，绝不原地覆盖已有
    // 切片文件（一个切片路径的字节在入队后永不变化；旧文件留盘，
    // 孤儿扫描清理）。库里 slice_path 随事务一起指到新文件。
    final sliceRel = ImportService.nextSliceRelative(q.id);
    final sliceAbs = AppDatabase.resolveDataPath(sliceRel);
    if (sliceAbs == null) return ReworkOutcome.sliceUnavailable;
    // 临时切片与正式切片同目录，rename 是同文件系统内的原子替换；
    // 随机后缀防两次重框撞名，也防失败残留被误删成他人的文件。
    // 十四批 M2：进程在写临时文件与 rename 之间被杀会留一个孤儿
    // 临时文件——`.tmp` 永不由孤儿清理删除（写一半的临时文件只由
    // 写路径自己在失败/回滚时清理；崩溃残留占小量磁盘，不影响下次
    // 重框/自愈）。
    // SR3-10：进程在事务提交后、rename 前被杀是另一个崩溃窗口——
    // 库里已是新切片尺寸、磁盘仍是旧图；孤儿扫描扫不到它（旧图仍被
    // slice_path 引用）。自愈在打开详情页时做（见 `_healSliceIfNeeded`）：
    // 切片实际尺寸与库里 sliceWidth/sliceHeight 不符就按当前框重裁。
    final tmpRel =
        'slices/${q.id}.tmp-${DateTime.now().millisecondsSinceEpoch}-${math.Random().nextInt(1 << 32)}.png';
    final tmpAbs = AppDatabase.resolveDataPath(tmpRel);
    if (tmpAbs == null) return ReworkOutcome.sliceUnavailable;
    // 十四批 M2（P1-B 写文件协议）：临时文件创建前登记临时路径；
    // 事务提交后、rename 前登记正式目标路径；rename 成功后解除
    // 两条登记（库里已指向新路径，删除路径按数据库引用保护）。
    final guard = FileLifecycleGuard.instance;
    guard.registerPending(tmpRel);
    try {
      await File(tmpAbs).parent.create(recursive: true);
      // WP-C #8 U3-1：写盘持守门——备份复制与写盘串行化，不读半写文件。
      await guard.withLock(() => File(tmpAbs).writeAsBytes(crop.png));
    } catch (_) {
      await guard.deleteFile(File(tmpAbs));
      guard.unregisterPending(tmpRel);
      return ReworkOutcome.tmpWriteFailed;
    }
    // B3-P01：换框 + 保存切片一个事务（任一步失败一起回滚，
    // 不留“框换了、切片还是旧的”的不一致）。
    // SR2-3：事务失败时只删临时文件——正式路径上的旧切片从未被
    // 动过；B5 的旧写法此时删的是刚覆盖掉旧图的正式文件。
    try {
      await repo.replaceQuestionBoxesAndSlice(
        q.id,
        newLayer1,
        slicePath: sliceRel,
        sliceWidth: crop.width,
        sliceHeight: crop.height,
      );
    } catch (_) {
      await guard.deleteFile(File(tmpAbs));
      guard.unregisterPending(tmpRel);
      return ReworkOutcome.saveFailed;
    }
    // 事务成功后再把临时切片 rename 到正式路径（同目录原子替换），
    // 然后清 FileImage 缓存——缓存失效点随 rename 后移到此处
    // （旧写法在事务前清缓存，事务失败后详情页会把仍是旧图的正式
    // 文件当成新图重新解码，虽无数据丢失但缓存语义是错的）。
    guard.registerPending(sliceRel);
    try {
      // WP-C #8 U3-1：改名持守门（与备份复制串行化）。
      await guard.withLock(() => File(tmpAbs).rename(sliceAbs));
    } catch (_) {
      await guard.deleteFile(File(tmpAbs));
      guard.unregisterPending(tmpRel);
      guard.unregisterPending(sliceRel);
      // 框与切片字段已提交，正式文件仍是旧切片：只报切片保存失败，
      // 不谎称全失败；重试重框即可恢复一致。
      return ReworkOutcome.renameFailed;
    }
    guard.unregisterPending(tmpRel);
    guard.unregisterPending(sliceRel);
    await evictCachedFileImage(sliceAbs);
    // 十三批 P1-2（GPT §5.2）：重框成功后 await 入队，确认任务已持久化；
    // 只有 worker.kick() 可以 fire-and-forget（它在 enqueueOcrForQuestion
    // 内部调，见 stem_correction.dart）。入队失败时框选结果照常保留
    // （框与切片已落库，ReworkOutcome 仍是 success——不要让页面把
    // “框选成功”等同于“OCR 已排队”），但记失败标志：末尾的 load()
    // 按 _ocrEnqueueFailedQuestionId 保留它，页面显“题目已更新，
    // OCR 未入队”横幅 + “重新入队”重试入口（见 retryOcrEnqueue）。
    // 入队失败绝不能把重框本身拖垮：失败只记标志，不改返回值。
    //
    // M5 §七第二条的坑：本行 await 在 widget 测试的 fake async 里
    // 曾挂住，所以当时改成 fire-and-forget。现在生产保持 await，
    // 测试侧用可 fake 的缝 [enqueueOcrForTest]（见本文件顶部注释），
    // 绝不为过测试把生产改回 unawaited。
    var enqueueFailed = false;
    try {
      final updated = await repo.questionById(q.id);
      if (updated != null) {
        var toEnqueue = updated;
        try {
          final newHash = await sha256HexOfFile(File(sliceAbs));
          final marked = markCandidateStale(updated, newHash);
          if (!identical(marked, updated)) {
            await repo.save(marked);
            toEnqueue = marked;
          }
        } catch (_) {}
        try {
          await _enqueueForRework(repo.db, toEnqueue);
        } catch (_) {
          enqueueFailed = true;
        }
      }
    } catch (_) {
      // 重读题目失败：没法入队，同样记失败（框选结果已落库，不受影响）。
      enqueueFailed = true;
    }
    if (enqueueFailed) {
      _ocrEnqueueFailedQuestionId = q.id;
    } else if (_ocrEnqueueFailedQuestionId == q.id) {
      // 本次入队成功：清掉这道题之前留下的失败标志（如下次重框前
      // 曾重试失败过）；别题的标志不动（它属于别的题，load 时自会清）。
      _ocrEnqueueFailedQuestionId = null;
    }
    await load();
    return ReworkOutcome.success;
  }

  /// 十三批 P1-2：重框入队失败后的重试入口（页面“题目已更新，OCR 未入队”
  /// 横幅上的“重新入队”调它，走同一入队路径 [enqueueOcrForQuestion]，
  /// 不是另写一条入队逻辑）。
  /// 成功（入队成功，或无切片可入队——按入队契约 null 不是失败）
  /// 返回 true 并清掉失败标志（横幅消失）；入队抛错返回 false，
  /// 标志保留、横幅不消失，可再点重试。
  Future<bool> retryOcrEnqueue() async {
    final q = state.question;
    if (q == null) return false;
    final repo = _repo;
    try {
      final fresh = await repo.questionById(q.id) ?? q;
      await _enqueueForRework(repo.db, fresh);
    } catch (_) {
      return false;
    }
    if (_ocrEnqueueFailedQuestionId == q.id) {
      _ocrEnqueueFailedQuestionId = null;
    }
    if (!_disposed) {
      state = state.copyWith(ocrEnqueueFailed: false);
      unawaited(_refreshOcrStatus(q));
    }
    return true;
  }

  // ---------- 内联新建（原 `_newTag` / `_newFolder` /
  // `_newKnowledgePoint` / `_newExam` / `_newCustomErrorType`
  // 里调 `repo` 的部分；弹窗与文案校验留在页面） ----------

  /// 新建标签（原 `_newTag`）：写库后重读（原 `_load`），再把新建的
  /// 选进编辑表单（原 `_load` 前后两次 `setState` 都是加同一个名，
  /// 合并为重读后加一次）。标签名禁逗号与竖线由页面先校验，不进这里。
  Future<void> submitNewTag(String name) async {
    await _repo.addTag(name);
    await load();
    if (_disposed) return;
    state = state.copyWith(
      editTags: state.editTags.contains(name)
          ? state.editTags
          : {...state.editTags, name},
    );
  }

  /// 新建文件夹（原 `_newFolder` 里写库的部分）：返回新建的文件夹 id；
  /// 整科同名（预检命中，或写入时 StateError 兜底）返回 null，
  /// 页面弹“已经有了”。成功后重读并把新建的选进编辑表单。
  /// 父文件夹由页面先在对话框里定好传进来（SR-P2-26 的返回值区分
  /// 仍在页面）。
  Future<String?> submitNewFolder(String name, String? parentId) async {
    final q = state.question;
    if (q == null) return null;
    // D-42：repo 入口处捕获一次（预检与保存跨多次 await，`on StateError`
    // 接不住 UnmountedRefException）。
    final repo = _repo;
    // SR-P2-36：整科同名预检（新建不传 excludeId），命中返回 null；
    // 仍留 StateError 捕获作兜底（预检与写入之间的竞态）。
    if (await repo.folderNameExistsInSubject(q.subjectId, name)) {
      return null;
    }
    final id = newEntityId('folder-${q.subjectId}');
    try {
      await repo.saveFolder(
        Folder(
          id: id,
          name: name,
          subjectId: q.subjectId,
          parentId: parentId,
          sortOrder: 0,
        ),
      );
    } on StateError {
      return null;
    }
    await load();
    if (_disposed) return id;
    state = state.copyWith(
      editFolders: state.editFolders.contains(id)
          ? state.editFolders
          : {...state.editFolders, id},
    );
    return id;
  }

  /// 新建知识点（原 `_newKnowledgePoint`）：返回新建的知识点 id；
  /// 成功后重读并把新建的选进编辑表单。章节由页面先在对话框里定好。
  Future<String> submitNewKnowledgePoint(String chapter, String name) async {
    final q = state.question;
    // 无当前题时仍按原代码走不到这里；防御性返回空串，页面不依赖它。
    if (q == null) return '';
    final id = newEntityId('kp-${q.subjectId}');
    await _repo.addKnowledgePoint(
      KnowledgePoint(
        id: id,
        subjectId: q.subjectId,
        chapter: chapter,
        name: name,
      ),
    );
    await load();
    if (_disposed) return id;
    state = state.copyWith(
      editKps: state.editKps.contains(id)
          ? state.editKps
          : {...state.editKps, id},
    );
    return id;
  }

  /// 新建试卷（原 `_newExam`）：返回新建的试卷 id；成功后重读并把
  /// 新建的归属到这道题。
  Future<String> submitNewExam(String name) async {
    final id = newEntityId('exam');
    await _repo.addExam(Exam(id: id, name: name));
    await load();
    if (_disposed) return id;
    state = state.copyWith(editExamId: id);
    return id;
  }

  /// 自定义错误类型（原 `_newCustomErrorType` 里改编辑表单的部分，
  /// 与整理页 `addCustomType` 同款）：
  /// 与固定枚举同名时不进自定义集合，直接选中对应固定项，
  /// 返回 true（页面提示“是固定错误类型，已帮你选中”）；
  /// 否则进自定义集合，返回 false。
  /// 空名与禁逗号竖线由页面先校验，不进这里。
  bool addCustomType(String name) {
    // SR-P2-27：与固定枚举同名时不进自定义集合，直接选中对应固定项
    //（否则 allCauses 里出现两次“其他”，详情页副标题与复习记录的
    // 错因行都会重复；详情页保存还会把它静默滤掉、错因直接消失）。
    if (ErrorTypes.fixed.contains(name)) {
      state = state.copyWith(
        editErrorTypes: state.editErrorTypes.contains(name)
            ? state.editErrorTypes
            : {...state.editErrorTypes, name},
      );
      return true;
    }
    state = state.copyWith(
      editCustomTypes: state.editCustomTypes.contains(name)
          ? state.editCustomTypes
          : {...state.editCustomTypes, name},
    );
    return false;
  }
}
