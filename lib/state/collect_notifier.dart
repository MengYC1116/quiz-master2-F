// ARCH-PLAN-A 第 3 阶段：收集页的状态层。
//
// 状态是 [CollectState]（任务列表 + 学科表 + 导入/去重/批量导入的
// 业务状态），唯一真源仍是 SQLite；本 Provider 只做“响应式读取 +
// 写回”，不另存一份。
// 读：`ref.watch(collectProvider)`；
// 写：`ref.read(collectProvider.notifier).load()` 等。
//
// 收集页没有初始入参（构造器只有 repo 与回调），所以没有
// `collectInitialProvider`（D-40 同款：需要初始参数时才按 D-35 的
// `wrongbookInitialProvider` 模式加，本次不需要）。
//
// 修框状态（框选、缩放、旋转）是纯 UI 临时状态，留在页面本地
// setState，不进 Provider（方案 §四第 3 阶段第 4 条）；只有已确认的
// 框、任务进度、导入/去重结果等业务状态进这里。本页用
// `ConsumerStatefulWidget`（业务数据走 Provider、局部交互状态留本地）。
// 修框编辑器本身（`box_editor.dart`）不动：它的 21 处 setState 全是
// 编辑器内纯 UI 状态；编辑器弹窗要 `BuildContext`，留在页面里开，
// 确认后的业务经 [CollectNotifier.confirmSplit] 交回来，取消时
// 的草稿保存经 [CollectNotifier.saveDraftBoxes] 交回来。
//
// SnackBar 提示的时机：`handleIncomingPaths` / `startStagedImport`
// 里“只收 PDF / JPG / PNG”与“同批内容重复只导一份”两条提示必须在
// 漫长的导入开始前就出现，不能等导入跑完才随返回值带回页面——
// 所以这两个方法接一个纯函数回调 `onNotice`，由页面在调用时传
// `_snack`；Notifier 本身不碰 `BuildContext`、不弹 Dialog、
// 不调导航。其余提示（页图缺失、拆题结果）都是方法返回后才出的，
// 走返回值（[BoxEditorPrep] 的 error、[ConfirmSplitOutcome]）。
//
// Provider 是 autoDispose（D-36 结论）：页面独占、随页生死，
// 回页重建并重读库。`build()` 里 `Future.microtask(load)` 首查
// + `_disposed` 守门（沿用 Stage 2/3 模式）。
//
// 构造器接进来的 `repo` 怎么进依赖图：`CollectPage` 在 build 里包
// 一层 `ProviderScope(overrides: [repositoryProvider
// .overrideWithValue(widget.repo)])`——`app.dart` 仍按老样子传，
// 不用改；测试里构造器传 FakeRepo 同样经这一层注入，不用再包
// 一层 ProviderScope。注入的检测 / PDF 渲染服务（`yoloService` /
// `pdfRenderService`）仍由页面构造器持有，需要时作为方法参数传进来。
// 角标走 `badgeCountsProvider`（第 4 阶段：订阅 `DataChangeBus`，
// 见 `badge_counts_provider.dart`）。
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/file_lifecycle_guard.dart';
import '../data/repository.dart';
import '../models/models.dart';
import '../modules/collect/batch_import.dart';
import '../services/import_guess.dart';
import '../services/import_service.dart';
import '../services/ocr_queue.dart';
import '../services/page_image_pipeline.dart';
import '../services/pdf_render_service.dart';
import '../services/yolo_onnx_service.dart';
import 'repository_provider.dart';

/// 收集页业务状态的 Provider：页面出现即读库（见 [CollectNotifier.build]）。
/// FR-19：声明 `dependencies: [repositoryProvider]`（D-49 同款，见
/// homeProvider 注释）。
final collectProvider =
    NotifierProvider.autoDispose<CollectNotifier, CollectState>(
      CollectNotifier.new,
      dependencies: [repositoryProvider],
    );

/// 待确认的一批导入：已选文件，但重复 / 超限警告还没被用户处理
///（原 `_PendingImport`，改公开——状态字段的类型不能是私有类）。
class PendingImport {
  const PendingImport({
    required this.paths,
    required this.subjectId,
    required this.duplicateNames,
    required this.oversizeHints,
  });

  final List<String> paths;
  final String subjectId;
  final List<String> duplicateNames;
  final List<String> oversizeHints;
}

/// 打开修框编辑器前的准备结果：页图缺失时由调用方 [CollectNotifier.prepareBoxEditor]
/// 返回 error（见该方法的返回值），[BoxEditorPrep] 只在准备成功时出现。
class BoxEditorPrep {
  const BoxEditorPrep({
    required this.pageImageAbs,
    required this.pageImagePaths,
    required this.draftsByPage,
    required this.detected,
    this.detectError,
  });

  /// 当前页的页图绝对路径（编辑器底图）。
  final String pageImageAbs;

  /// PDF 多页任务：每页的页图绝对路径（切页就换底图）；单页图片
  /// 任务为空（只用当前页那一张）。
  final Map<int, String> pageImagePaths;

  /// 各页的草稿框（有草稿的页不再检测）。
  final Map<int, List<QuestionBox>> draftsByPage;

  /// 当前页的检测结果（已按草稿已存的旋转角度做坐标变换；有草稿时为空）。
  final List<QuestionBox> detected;

  /// 自动框不可用时的提示（模型失败不落占位框，只提示手动框选）。
  final String? detectError;
}

/// 确认拆题的结果种类（原 `_confirmSplit` 里各分支的提示一一对应，
/// 页面按返回值弹提示；成功 / 失败时 Notifier 已重读）。
enum ConfirmSplitKind {
  /// 成功：题已建、拆分任务已建、原任务已处理、已重读。
  done,

  /// 没有可拆的框：有框的页都已拆过（`hadSkippedBoxes` 时页面弹
  /// “这些页已经拆成题了，不用再拆”），其余情况静默。
  nothingToSplit,

  /// 还有未框页：页面先弹“还有 N 页没有框”确认框，用户确认后再调
  /// 一次 `confirmSplit(confirmedUnboxed: true)`。
  needsUnboxedConfirm,

  /// 切片写不进去：本次新写的文件已按清单删干净，库不动。
  sliceFailed,

  /// 保存失败：事务已回滚，本次新写的文件已按清单删干净，任务不动。
  saveFailed,
}

/// 确认拆题的结果（[ConfirmSplitKind] + 各分支要用的数据）。
class ConfirmSplitOutcome {
  const ConfirmSplitOutcome._(
    this.kind, {
    this.message,
    this.unboxedPages = const [],
    this.boxedPages = 0,
    this.total = 0,
  });

  /// 成功：`message` 是成功提示（“已生成 N 道题，去整理吧”或
  /// “已生成 N 道题去整理，还有 M 页没框留在任务里”）。
  const ConfirmSplitOutcome.done(String message)
    : this._(ConfirmSplitKind.done, message: message);

  /// 没有可拆的框：`message` 非空时页面弹它（已拆过的页），为空时静默。
  const ConfirmSplitOutcome.nothingToSplit({String? message})
    : this._(ConfirmSplitKind.nothingToSplit, message: message);

  /// 还有未框页：页面按 `unboxedPages` / `boxedPages` / `total`
  /// 弹确认框（文案见 `pageListText`）。
  const ConfirmSplitOutcome.needsUnboxedConfirm({
    required List<int> unboxedPages,
    required int boxedPages,
    required int total,
  }) : this._(
         ConfirmSplitKind.needsUnboxedConfirm,
         unboxedPages: unboxedPages,
         boxedPages: boxedPages,
         total: total,
       );

  /// 切片失败 / 保存失败：`message` 是失败提示。
  const ConfirmSplitOutcome.sliceFailed(String message)
    : this._(ConfirmSplitKind.sliceFailed, message: message);
  const ConfirmSplitOutcome.saveFailed(String message)
    : this._(ConfirmSplitKind.saveFailed, message: message);

  final ConfirmSplitKind kind;

  /// 页面要弹的提示（`needsUnboxedConfirm` 时为空，页面自己拼确认框文案）。
  final String? message;

  /// 未框页（`needsUnboxedConfirm` 时用）。
  final List<int> unboxedPages;

  /// 有框的页数（`needsUnboxedConfirm` 时用）。
  final int boxedPages;

  /// 本次要拆出的题数（`needsUnboxedConfirm` 时用）。
  final int total;
}

/// `copyWith` 里“显式置 null”与“不改”的区分标记。
const _unset = Object();

/// 收集页的全部业务数据（原 `_CollectPageState` 里调 `repo` 的字段与
/// 导入/去重/批量导入的业务状态原样搬移；`_picking` / `_noSubjectWarning` /
/// `_hideErrorBanner` / `_filter` / `_dragOver` 是纯界面状态，留页面本地，
/// 不在这里）。
class CollectState {
  const CollectState({
    this.tasks = const [],
    this.subjects = const [],
    this.unboxedPagesByTask = const {},
    this.hasAnyDraftBox = const {},
    this.hasSplitSibling = const {},
    this.selectedSubjectId,
    this.pendingImport,
    this.batch,
    this.stagedPaths,
    this.subjectGuessHint,
    this.retryingTaskIds = const {},
    this.questionsById = const {},
  });

  /// 任务列表（只按导入时间排，新的在上，来自 `collect_tasks` 的 rowid DESC）。
  final List<CollectTask> tasks;

  /// 已产出题目的任务的题（questionId → Question；只有修框确认后
  /// 的待整理 / 已整理任务才有，供行主行显示题干；读不到时该行
  /// 回退显示文件标题）。
  final Map<String, Question> questionsById;

  /// 学科表：读库 subjects（B2 补充；B8-1：空表是删光学科后的合法状态，
  /// 不再回退预设三科；首帧与读库后都以真实列表为准，空就是空）。
  final List<Subject> subjects;

  /// 待框选 / 修框中任务每页有没有 1 层草稿框（行上无框警告用，
  /// 只查这两个状态，其余状态不查）。
  final Map<String, List<int>> unboxedPagesByTask;

  /// 有任意草稿框（任意层、任意页）的任务 id（SR-P2-25：行上无框警告
  /// 的“打开过”信号的一半；另一半是任务状态本身）。
  final Set<String> hasAnyDraftBox;

  /// 有同 sourcePath 拆分任务（待整理/已整理）的任务 id（SR-P2-25
  /// 补信号；SR2-22：派生信号，每次 load 由当前任务表重算，没有字段落盘）。
  final Set<String> hasSplitSibling;

  /// 导入学科下拉框：每次导入都自己选，默认“请选择学科”；选完一批后清空。
  final String? selectedSubjectId;

  /// 待确认的一批导入（重复 / 超限警告还没被用户处理）。
  final PendingImport? pendingImport;

  /// B11-2：批量导入队列（>1 个文件时建，单文件不建；重试失败项时复用）。
  /// `BatchImportState` 本身可变（行状态原地改），每次改完 Notifier
  /// 都重新赋值一份 `CollectState` 触发重建（见 `_emitBatch`）。
  final BatchImportState? batch;

  /// B11-2：没选学科时选好的文件先暂存，等用户选好学科点“开始导入”再走同一套检查。
  final List<String>? stagedPaths;

  /// B11-2：按文件名猜学科后的提示（用户手动改下拉后清除；猜不出时为 null）。
  final String? subjectGuessHint;

  /// 十二批 D-91 功能 7：正在原地重试的任务 id（单任务重试中标志，
  /// 收集页据此禁用对应行的“重试”按钮；service 层另有 in-flight
  /// 幂等，按钮禁用只是第一层防护）。
  final Set<String> retryingTaskIds;

  /// 库里找学科：新学科用库里的名与色；找不到才回退 Subject.byId
  ///（数学兜底，只发生在数据不一致时）。
  Subject subjectOf(String id) =>
      subjects.firstWhere((s) => s.id == id, orElse: () => Subject.byId(id));

  /// 某状态的任务数（筛选 chips 用；副标题不再放计数）。
  int count(CollectStatus status) =>
      tasks.where((t) => t.status == status).length;

  /// 筛选后的任务列表：未完成在前、已整理在后；组内按导入时间
  /// 新的在上（tasks 本身已按 rowid DESC，分组用稳定划分保持
  /// 组内原顺序）。未完成 = 除 done 外的一切状态（导入失败也
  /// 算未完成——还没整理进错题本）；筛选只过滤，不改变组内顺序。
  List<CollectTask> shownTasks(CollectStatus? filter) {
    final list = filter == null
        ? tasks
        : tasks.where((t) => t.status == filter).toList();
    return [
      for (final t in list)
        if (t.status != CollectStatus.done) t,
      for (final t in list)
        if (t.status == CollectStatus.done) t,
    ];
  }

  CollectState copyWith({
    List<CollectTask>? tasks,
    List<Subject>? subjects,
    Map<String, List<int>>? unboxedPagesByTask,
    Set<String>? hasAnyDraftBox,
    Set<String>? hasSplitSibling,
    Object? selectedSubjectId = _unset,
    Object? pendingImport = _unset,
    Object? batch = _unset,
    Object? stagedPaths = _unset,
    Object? subjectGuessHint = _unset,
    Set<String>? retryingTaskIds,
    Map<String, Question>? questionsById,
  }) {
    return CollectState(
      tasks: tasks ?? this.tasks,
      subjects: subjects ?? this.subjects,
      unboxedPagesByTask: unboxedPagesByTask ?? this.unboxedPagesByTask,
      hasAnyDraftBox: hasAnyDraftBox ?? this.hasAnyDraftBox,
      hasSplitSibling: hasSplitSibling ?? this.hasSplitSibling,
      selectedSubjectId: selectedSubjectId == _unset
          ? this.selectedSubjectId
          : selectedSubjectId as String?,
      pendingImport: pendingImport == _unset
          ? this.pendingImport
          : pendingImport as PendingImport?,
      batch: batch == _unset ? this.batch : batch as BatchImportState?,
      stagedPaths: stagedPaths == _unset
          ? this.stagedPaths
          : stagedPaths as List<String>?,
      subjectGuessHint: subjectGuessHint == _unset
          ? this.subjectGuessHint
          : subjectGuessHint as String?,
      retryingTaskIds: retryingTaskIds ?? this.retryingTaskIds,
      questionsById: questionsById ?? this.questionsById,
    );
  }
}

/// 十三批 P1-2 任务 c：批量入队后没排上的题数。
/// [OcrWorker.enqueueForQuestions] 只返回成功建/已存在的任务行，
/// 逐道失败都被它内部吞掉；调用方按 questionId 比对——返回列表里
/// 没有该题 id 的即没排上（无切片返回 null 也算没排上，调用方按此数
/// 提示“其中 X 道题 OCR 未入队”）。纯函数，单测直接覆盖。
@visibleForTesting
int ocrEnqueueMissedCount(List<Question> questions, List<OcrJob> jobs) {
  final enqueued = {for (final job in jobs) job.questionId};
  return questions.where((q) => !enqueued.contains(q.id)).length;
}

/// 同 sourcePath 的拆分任务（待整理/已整理）所在页就是已拆页。
/// sourcePath 是 `imports/<原任务 id>/...`，原任务 id 唯一，
/// 重导入同一份文件不串（见 [CollectNotifier.load] 的 splitPagesBySource）。
Set<int> splitPagesFor(List<CollectTask> all, CollectTask task) {
  if (task.sourcePath.isEmpty) return {};
  return {
    for (final t in all)
      if (t.id != task.id &&
          t.sourcePath == task.sourcePath &&
          (t.status == CollectStatus.pendingOrganize ||
              t.status == CollectStatus.done))
        t.page,
  };
}

/// 页码清单：超过 5 页只列前 5 页加“等”，文案不刷屏。
String pageListText(List<int> pages) {
  if (pages.length <= 5) return pages.join('、');
  return '${pages.take(5).join('、')} 等';
}

/// 行上的无框警告文案：单张图直接说“这张图还没有框”，
/// 多页只报没框的页数与页码。
String noBoxWarningText(CollectTask task, List<int> unboxed) {
  if (task.pageCount <= 1) return '这张图还没有框';
  if (unboxed.length == task.pageCount) {
    return '这份文件还有 ${unboxed.length} 页没有框';
  }
  return '还有 ${unboxed.length} 页没有框：第 ${pageListText(unboxed)} 页';
}

/// 任务行第二行文案（状态 + 学科 + 页码）。主行已是题干（或回退的
/// 文件标题），副行不再重复文件名，只留真正补充的信息。
String taskNote(CollectTask task, String subjectName) {
  final pagePart = task.pageCount > 1
      ? '第${task.page}页 / 共${task.pageCount}页'
      : '第${task.page}页';
  return switch (task.status) {
    CollectStatus.importing => '整题检测中… · $subjectName · $pagePart',
    CollectStatus.queued => '排队中 · 轮到会自动开始，一个一个检测 · $subjectName · $pagePart',
    CollectStatus.needBox => '检测完成，等你修框确认 · $subjectName · $pagePart',
    CollectStatus.boxing =>
      '修框中 · 上次修到一半，点「继续修框」接着修 · $subjectName · $pagePart',
    CollectStatus.pendingOrganize => '已确认修框，等整理 · $subjectName · $pagePart',
    CollectStatus.failed => '导入失败 · $subjectName · $pagePart',
    CollectStatus.done => '已整理 · $subjectName · $pagePart',
  };
}

/// 收集页业务逻辑（ARCH-PLAN-A 第 3 阶段：原 `collect_page.dart` 的
/// `_CollectPageState` 里调 `repo` / `ImportService` 的部分原样迁入；
/// 页面只留 widget 与本地交互状态——`_picking` / `_noSubjectWarning` /
/// `_hideErrorBanner` / `_filter` / `_dragOver`、修框编辑器弹窗本身）。
///
/// 拿库的方式与 `ReviewNotifier` / `OrganizeNotifier` / `DetailNotifier`
/// 一致：经 `ref.read(repositoryProvider)` 拿——测试注入见
/// `docs/ui-replication/A-READING-GUIDE.md`（`ProviderContainer.test`
/// + `repositoryProvider.overrideWithValue`）。
class CollectNotifier extends Notifier<CollectState> {
  QuestionRepository get _repo => ref.read(repositoryProvider);

  bool _disposed = false;

  /// SR2-62：上一次确认的 `ts-rnd` 戳（只记这一个值，不作他用）。
  /// 两次确认落在同一毫秒且随机段恰好撞上时，题 id 与拆分任务 id
  /// 会全撞（SR-P2-60 的 6 位随机段只把概率压到 1e-6，不是保证）；
  /// 撞上就重抽，直到与上一次不同，保证两次确认的 id 不同。
  static String _lastSplitStamp = '';

  @override
  CollectState build() {
    ref.onDispose(() => _disposed = true);
    // 页面出现即读库（原 `initState` 的 `_load`）：不 await，
    // 读完后 state 一次性赋值，首帧先出空态（与原来一致）。
    Future.microtask(load);
    return const CollectState();
  }

  /// 首读与每次写库后重读（与原来页面的 `_load` 同口径）：
  /// 读任务列表 → 学科表 → 逐个待框选/修框中任务读草稿框，
  /// 算出未框页（只认 1 层框）与两个“打开过”派生信号。
  Future<void> load() async {
    // build() 的 microtask 首查可能在页面已离开、Provider 已销毁后才跑
    //（b8_1_subject_refresh_flow 切页快时稳定复现 UnmountedRefException）：
    // 先判 _disposed 再碰 ref；repo 入口处捕获一次，之后不再 ref.read，
    // 中途销毁也不抛错（D-41② 异步尾部守门）。
    if (_disposed) return;
    final repo = _repo;
    final tasks = await repo.collectTasks();
    final subjects = await repo.subjects();
    final unboxed = <String, List<int>>{};
    final hasAnyDraftBox = <String>{};
    final hasSplitSibling = <String>{};
    // P1-2：同 sourcePath 的拆分任务（待整理/已整理）所在页就是已拆页，
    // 不算未框（保留任务重进列表时，第 1 页已拆成题，不能再报没框）。
    // B9-1：SR-P2-33 在此结案——done 现在有生产入口，不再是死分支。
    final splitPagesBySource = <String, Set<int>>{};
    for (final t in tasks) {
      if (t.status != CollectStatus.pendingOrganize &&
          t.status != CollectStatus.done) {
        continue;
      }
      if (t.sourcePath.isEmpty) continue;
      (splitPagesBySource[t.sourcePath] ??= {}).add(t.page);
    }
    for (final task in tasks) {
      if (task.status != CollectStatus.needBox &&
          task.status != CollectStatus.boxing) {
        continue;
      }
      try {
        final boxes = await repo.boxesForTask(task.id);
        // SR-P2-25：任意页的草稿框都算“已有草稿”。
        if (boxes.isNotEmpty) hasAnyDraftBox.add(task.id);
        // SR-P2-25 补信号：同源已有拆分任务 = 打开过并确认过（见字段注释）。
        final split = splitPagesBySource[task.sourcePath] ?? const <int>{};
        if (split.isNotEmpty) hasSplitSibling.add(task.id);
        final boxedPages = <int>{
          // 只认 1 层框：旧的 layer-2 行编辑器读到就丢，不算“已框”
          //（B8-2；否则只有旧内框的页会被误判为已框，警告出不来）。
          for (final b in boxes)
            if (b.layer == 1) b.page,
        };
        final missing = <int>[
          for (var p = 1; p <= task.pageCount; p++)
            if (!boxedPages.contains(p) && !split.contains(p)) p,
        ];
        if (missing.isNotEmpty) unboxed[task.id] = missing;
      } catch (_) {
        // 草稿读不到就不出警告，列表本身不受影响。
      }
    }
    // 2026-11-26：行主行显示题干——有 questionId 的任务（待整理 /
    // 已整理）读出对应的题；读不到（题已删）就不进 map，行回退
    // 显示文件标题，列表本身不受影响。
    final questionsById = <String, Question>{};
    for (final task in tasks) {
      final qid = task.questionId;
      if (qid == null) continue;
      try {
        final q = await repo.questionById(qid);
        if (q != null) questionsById[qid] = q;
      } catch (_) {
        // 读不到就不进 map，行回退文件标题。
      }
    }
    if (_disposed) return;
    state = state.copyWith(
      tasks: tasks,
      subjects: subjects,
      unboxedPagesByTask: unboxed,
      hasAnyDraftBox: hasAnyDraftBox,
      hasSplitSibling: hasSplitSibling,
      questionsById: questionsById,
    );
  }

  // ---------- 导入学科下拉 ----------

  /// 下拉改选：用户手动改了学科，猜测提示清除。
  void selectSubject(String? id) {
    state = state.copyWith(selectedSubjectId: id, subjectGuessHint: null);
  }

  // ---------- 文件选择与拖放的统一入口 ----------

  /// 系统文件选择器，多选。返回选中的文件路径；打不开选择器时返回
  /// null（页面弹“打不开文件选择器，请重试”）；用户取消返回空列表。
  Future<List<String>?> pickFiles({
    PdfRenderService? pdfRenderService,
  }) async {
    final service = ImportService(
      _repo.db,
      pdfRenderService: pdfRenderService,
    );
    try {
      return await service.pickFiles();
    } catch (_) {
      return null;
    }
  }

  /// B11-1 + B11-2：文件选择与拖放的统一入口。
  /// 只收 PDF / JPG / PNG；同批内容重复只留第一份；文件名重复与
  /// 内容重复（SHA-256）都走既有“已经导入过”横幅；超限走既有超限
  /// 横幅；没选学科时按文件名猜一个建议预填，仍没学科就暂存文件。
  /// 两条导入前提示（跳过的文件、同批内容重复）经 `onNotice` 在导入
  /// 开始前就交给页面弹出，不等导入跑完（见文件头注释）。
  Future<void> handleIncomingPaths(
    List<String> paths, {
    PdfRenderService? pdfRenderService,
    void Function(String notice)? onNotice,
  }) async {
    final kept = <String>[];
    var skippedDirs = 0;
    var skippedTypes = 0;
    for (final path in paths) {
      // Win11 上拖文件夹进来也是一条路径，先按目录拦掉。
      if (Directory(path).existsSync()) {
        skippedDirs++;
        continue;
      }
      final ext = path.split('.').last.toLowerCase();
      if (!ImportService.allowedExtensions.contains(ext)) {
        skippedTypes++;
        continue;
      }
      kept.add(path);
    }
    if (skippedDirs > 0 || skippedTypes > 0) {
      onNotice?.call(
        '只收 PDF / JPG / PNG：跳过了 $skippedDirs 个文件夹、$skippedTypes 个不支持的文件',
      );
    }
    if (kept.isEmpty) return;
    final service = ImportService(
      _repo.db,
      pdfRenderService: pdfRenderService,
    );
    // 同批内容重复：只留第一份导入（第二份起直接丢掉，不建任务）。
    final dedup = await service.checkContentDuplicates(kept, state.tasks);
    var effective = kept;
    if (dedup.withinBatchDropped.isNotEmpty) {
      effective = kept
          .where((p) => !dedup.withinBatchDropped.contains(p))
          .toList();
      onNotice?.call(
        '其中 ${dedup.withinBatchDropped.length} 个文件与本批另一文件内容相同，只导入了一份',
      );
    }
    if (effective.isEmpty) return;
    // 重复文件：文件名命中（既有口径）或内容哈希命中（B11-2），
    // 都进同一条“已经导入过”横幅，等用户点“仍然再导一份”才继续。
    final duplicateNames = <String>[];
    for (final path in effective) {
      final name = File(path).uri.pathSegments.last;
      if (state.tasks.any((t) => t.fileName == name) &&
          !duplicateNames.contains(name)) {
        duplicateNames.add(name);
      }
    }
    for (final name in dedup.libraryDuplicates) {
      if (!duplicateNames.contains(name)) duplicateNames.add(name);
    }
    final oversizeHints = <String>[];
    for (final path in effective) {
      final file = File(path);
      try {
        final hint = ImportService.oversizeHint(file);
        if (hint != null) oversizeHints.add(hint);
      } catch (_) {}
    }
    // 没选学科时按文件名猜一个建议预填（B11-2）：猜不出、或本批
    // 猜得不一致时留空，等用户自己选；绝不静默自动指定。
    if (state.selectedSubjectId == null) {
      final guessed = guessCommonSubjectId(
        effective.map((p) => File(p).uri.pathSegments.last).toList(),
        state.subjects,
      );
      if (guessed != null) {
        if (_disposed) return;
        state = state.copyWith(
          selectedSubjectId: guessed,
          subjectGuessHint: '按文件名猜是「${state.subjectOf(guessed).name}」，不对可以改',
        );
      }
    }
    if (state.selectedSubjectId == null) {
      // 仍没学科：文件暂存，等用户选好学科点“开始导入”再走同一套
      // 重复 / 超限检查；不直接导入（没选学科不能导入）。
      if (_disposed) return;
      state = state.copyWith(
        stagedPaths: [...?state.stagedPaths, ...effective],
      );
      return;
    }
    if (duplicateNames.isNotEmpty || oversizeHints.isNotEmpty) {
      if (_disposed) return;
      state = state.copyWith(
        pendingImport: PendingImport(
          paths: effective,
          subjectId: state.selectedSubjectId!,
          duplicateNames: duplicateNames,
          oversizeHints: oversizeHints,
        ),
      );
      return;
    }
    await importFiles(
      effective,
      state.selectedSubjectId!,
      pdfRenderService: pdfRenderService,
    );
  }

  /// B11-2：暂存文件的“开始导入”——学科仍没选时返回 `needsSubject`
  ///（页面出“先选学科”提示）；选好了就把暂存文件重走
  /// [handleIncomingPaths]（重复 / 超限 / 内容去重同一套检查再算一遍）。
  Future<({bool needsSubject})> startStagedImport({
    PdfRenderService? pdfRenderService,
    void Function(String notice)? onNotice,
  }) async {
    final staged = state.stagedPaths;
    if (staged == null || staged.isEmpty) {
      return (needsSubject: false);
    }
    if (state.selectedSubjectId == null) {
      return (needsSubject: true);
    }
    state = state.copyWith(stagedPaths: null);
    await handleIncomingPaths(
      staged,
      pdfRenderService: pdfRenderService,
      onNotice: onNotice,
    );
    return (needsSubject: false);
  }

  /// 丢掉暂存的文件（“取消”）。
  void discardStagedImport() {
    state = state.copyWith(stagedPaths: null);
  }

  /// B11-2：重试本批全部失败项（只重导失败的，成功的、已在队列里
  /// 的不动；沿用本批的学科，不重新猜）。
  Future<void> retryBatchFailures({PdfRenderService? pdfRenderService}) async {
    final batch = state.batch;
    if (batch == null || !batch.hasFailures) return;
    await importFiles(
      batch.failedPaths,
      batch.subjectId,
      resumeBatch: batch,
      pdfRenderService: pdfRenderService,
    );
  }

  /// B11-2：重试队列里失败的一行。
  Future<void> retryBatchPath(
    String path, {
    PdfRenderService? pdfRenderService,
  }) async {
    final batch = state.batch;
    if (batch == null) return;
    await importFiles(
      [path],
      batch.subjectId,
      resumeBatch: batch,
      pdfRenderService: pdfRenderService,
    );
  }

  /// 十二批 D-91 功能 7：重试单个失败任务（原地重试，同一任务 id，
  /// 复用 [ImportService.retryFromStoredOriginal]）。
  /// 返回 `(task, error)`：成功时 task 为 needBox 行、error 为空；
  /// 重试后仍失败时 task 为新的 failed 行、error 为新原因（页面弹
  /// snack，行上也显示新原因，仍可再重试）；非法重试（非 failed
  /// 任务）与其它异常时 task 为空、error 为提示文案，任务本身不动。
  /// 重试期间该任务 id 进 [CollectState.retryingTaskIds]，页面据此
  /// 禁用行上的“重试”按钮；结束后（成功/失败/异常）摘掉并重读。
  Future<({CollectTask? task, String? error})> retryFailedTask(
    CollectTask task, {
    PdfRenderService? pdfRenderService,
  }) async {
    if (_disposed) return (task: null, error: '页面已离开，请重新打开收集页再试');
    state = state.copyWith(
      retryingTaskIds: {...state.retryingTaskIds, task.id},
    );
    try {
      final service = ImportService(
        _repo.db,
        pdfRenderService: pdfRenderService,
      );
      final result = await service.retryFromStoredOriginal(task);
      await load();
      if (result.status == CollectStatus.failed) {
        return (task: result, error: result.error ?? '重试失败，请稍后再试');
      }
      return (task: result, error: null);
    } on StateError catch (e) {
      // 非 failed 任务（成功后重复点重试等）：走现有 snack 模式，
      // 由页面弹 error 文案；任务本身不动。
      return (task: null, error: e.message);
    } catch (e) {
      debugPrint('重试失败任务异常（已转为提示）：$e');
      return (task: null, error: '重试失败，请稍后再试');
    } finally {
      if (!_disposed) {
        state = state.copyWith(
          retryingTaskIds: state.retryingTaskIds
              .where((id) => id != task.id)
              .toSet(),
        );
      }
    }
  }

  /// 待确认导入的“仍然再导一份”。
  Future<void> confirmPendingImport({
    PdfRenderService? pdfRenderService,
  }) async {
    final pending = state.pendingImport;
    if (pending == null) return;
    state = state.copyWith(pendingImport: null);
    await importFiles(
      pending.paths,
      pending.subjectId,
      pdfRenderService: pdfRenderService,
    );
  }

  /// 待确认导入的“不导了”。
  void discardPendingImport() {
    state = state.copyWith(pendingImport: null);
  }

  /// 关掉批量导入卡片（队列本身不动，下次导入重建）。
  void dismissBatch() {
    state = state.copyWith(batch: null);
  }

  // ---------- 导入执行 ----------

  /// 逐个导入（原 `_importFiles`）：B11-2 逐个处理，单张失败只记
  /// 本行失败，不中断整批。`resumeBatch` 非空时复用原队列（重试失败项），
  /// 否则 >1 个文件建批量队列、单文件不建（行为不变）。
  Future<void> importFiles(
    List<String> paths,
    String subjectId, {
    BatchImportState? resumeBatch,
    PdfRenderService? pdfRenderService,
  }) async {
    final service = ImportService(
      _repo.db,
      pdfRenderService: pdfRenderService,
    );
    // repo 入口处捕获一次：导入是长流程，中途切页销毁 Provider 后
    // 尾部的 saveRecentTask 再 ref.read 会抛 UnmountedRefException
    //（load() 同款，见该方法注释）。
    final repo = _repo;
    // B11-2：>1 个文件建批量队列（单文件不建，行为不变）；重试失败项
    // 时复用原队列，只把失败行打回排队中。
    BatchImportState? batch;
    if (resumeBatch != null) {
      batch = resumeBatch;
      for (final path in paths) {
        final i = batch.indexOfPath(path);
        if (i >= 0) batch.resetForRetry(i);
      }
    } else if (paths.length > 1) {
      batch = BatchImportState(
        subjectId: subjectId,
        files: [
          for (final p in paths)
            BatchImportFile(
              path: p,
              name: File(p).uri.pathSegments.last,
              guessedExam: guessExamName(File(p).uri.pathSegments.last),
            ),
        ],
      );
    }
    _emitBatch(batch);
    for (final path in paths) {
      final file = File(path);
      final name = file.uri.pathSegments.last;
      final batchIndex = batch?.indexOfPath(path) ?? -1;
      if (batchIndex >= 0) batch!.markImporting(batchIndex);
      _emitBatch(batch);
      if (!file.existsSync()) {
        if (batchIndex >= 0) {
          batch!.markFailed(batchIndex, '找不到这个文件');
        }
        await _failTask(repo, name, subjectId, '找不到这个文件');
        _emitBatch(batch);
        continue;
      }
      String? failure;
      try {
        if (file.lengthSync() == 0) {
          failure = '文件损坏：文件为空，无法导入';
        } else if (path.toLowerCase().endsWith('.pdf') &&
            _isEncryptedPdf(file)) {
          failure = '这个 PDF 带密码，解开密码再导';
        }
      } catch (_) {
        failure = '文件损坏：无法读取';
      }
      if (failure != null) {
        if (batchIndex >= 0) batch!.markFailed(batchIndex, failure);
        await _failTask(repo, name, subjectId, failure);
        _emitBatch(batch);
        continue;
      }
      // §1.4：真实导入（复制进库 + PDF 整本渲染 / 图片 EXIF 归一化
      // + 真实进度）。PDF 加密 / 损坏 / 超 50MB / 超 20 页 /
      // 渲染失败都进失败任务（enqueue 内判），不建无页图任务；
      // 复制失败 / 镜像方向同样进失败任务，不建空任务。
      // B11-2：逐个处理，单张失败只记本行失败，不中断整批。
      final created = await service.enqueue(
        [path],
        subjectId: subjectId,
        onProgress: (taskId, progress) {
          if (_disposed) return;
          if (batchIndex >= 0) {
            // 任务行要等 enqueue 返回才进 state，批量进度不能等它：
            // 进度变了就直接刷新（与任务行同一“只在变化时刷新”口径）。
            final file = batch!.files[batchIndex];
            if (file.progress != progress) {
              batch.markProgress(batchIndex, progress);
              _emitBatch(batch);
            }
          }
          final i = state.tasks.indexWhere((t) => t.id == taskId);
          if (i < 0) return;
          final t = state.tasks[i];
          if (t.progress == progress) return;
          final updated = List.of(state.tasks);
          updated[i] = CollectTask(
            id: t.id,
            name: t.name,
            fileName: t.fileName,
            subjectId: t.subjectId,
            status: t.status,
            progress: progress,
            pageCount: t.pageCount,
            page: t.page,
            error: t.error,
            questionId: t.questionId,
            createdAt: t.createdAt,
            sourcePath: t.sourcePath,
            pageRotations: t.pageRotations,
            // 十二批 D-91：内存行重建也带上 sourceHash，别让进度
            // 回调把哈希丢了（写库走全列写回，丢了就抹掉）。
            sourceHash: t.sourceHash,
          );
          state = state.copyWith(tasks: updated);
        },
      );
      final merged = List.of(state.tasks);
      for (final task in created) {
        if (!merged.any((t) => t.id == task.id)) merged.add(task);
      }
      if (batchIndex >= 0) {
        final failed = created
            .where((t) => t.status == CollectStatus.failed)
            .toList();
        if (failed.isNotEmpty) {
          batch!.markFailed(batchIndex, failed.first.error ?? '导入失败');
        } else {
          batch!.markDone(batchIndex);
        }
      }
      _emitTasks(merged);
      _emitBatch(batch);
    }
    await repo.saveRecentTask(
      kind: '收集',
      subjectId: subjectId,
      title: paths.map((p) => File(p).uri.pathSegments.last).join('、'),
    );
    // 选完一批后清空已选学科，下次导入重新选。
    if (!_disposed) {
      state = state.copyWith(selectedSubjectId: null);
    }
    await load();
  }

  /// `BatchImportState` 本身可变（行状态原地改）：每次改完都重新
  /// 赋值一份 `CollectState` 触发重建；页面已离开时静默放弃
  ///（D-41②：异步尾部 `_disposed` 守门）。
  void _emitBatch(BatchImportState? batch) {
    if (_disposed) return;
    state = state.copyWith(batch: batch);
  }

  /// 任务列表有变时重新赋值（同上：页面已离开时静默放弃）。
  void _emitTasks(List<CollectTask> tasks) {
    if (_disposed) return;
    state = state.copyWith(tasks: tasks);
  }

  /// 加密 PDF 启发式检查：文件里出现 /Encrypt 标记即视为带密码。
  bool _isEncryptedPdf(File file) {
    try {
      final bytes = file.readAsBytesSync().take(4096).toList();
      final head = String.fromCharCodes(bytes);
      return head.contains('/Encrypt');
    } catch (_) {
      return false;
    }
  }

  Future<void> _failTask(
    QuestionRepository repo,
    String fileName,
    String subjectId,
    String error,
  ) async {
    final task = CollectTask(
      // SR-P2-28：id 用 newEntityId（毫秒 + 随机后缀）；旧写法只拼
      // 毫秒 + 文件名 hash，同名文件同毫秒两次失败会互相覆盖。
      id: newEntityId('task'),
      name: '$fileName · 第1页 · 第1题',
      fileName: fileName,
      subjectId: subjectId,
      status: CollectStatus.failed,
      error: error,
    );
    await repo.saveCollectTask(task);
  }

  // ---------- 修框 ----------

  /// 打开修框编辑器前的准备（原 `_openBoxEditor` 里开弹窗之前的部分）：
  /// 校验页图（§6 第 6 条：页图缺失明确报错、不开编辑器）、把任务置为
  /// boxing 并落盘、读草稿、没草稿才跑检测。返回 `(prep, error)`：
  /// 页图缺失时 `prep` 为空、`error` 是提示文案；成功时 `error` 为空。
  /// 编辑器弹窗本身留在页面里开。
  Future<({BoxEditorPrep? prep, String? error})> prepareBoxEditor(
    CollectTask task, {
    YoloOnnxService? yoloService,
  }) async {
    // repo 入口处捕获一次：打开编辑器前要落盘 + 重读，中途切页销毁
    // Provider 后再 ref.read 会抛 UnmountedRefException（load() 同款）。
    final repo = _repo;
    // §6 第 6 条：页图缺失明确报错、不开编辑器。
    // PDF 多页任务：每页的页图都要在（切页就换底图），缺任何一页
    // 都不开编辑器；单页图片任务只校验当前页。
    final pageImageRel = ImportService.pageImageRelativeForTask(task);
    final pageImageAbs = pageImageRel.isEmpty
        ? null
        : AppDatabase.resolveDataPath(pageImageRel);
    if (pageImageAbs == null || !File(pageImageAbs).existsSync()) {
      return (prep: null, error: '页图缺失：找不到这份文件的页图，无法修框，请重新导入');
    }
    final pageImagePaths = <int, String>{};
    if (ImportService.isPdfTask(task)) {
      for (var p = 1; p <= task.pageCount; p++) {
        final rel = ImportService.pageImageRelativeForTask(task, page: p);
        final abs = AppDatabase.resolveDataPath(rel);
        if (abs == null || !File(abs).existsSync()) {
          return (prep: null, error: '页图缺失：找不到第 $p 页的页图，无法修框，请重新导入');
        }
        pageImagePaths[p] = abs;
      }
    }
    task.status = CollectStatus.boxing;
    await repo.saveCollectTask(task);
    await load();
    // 草稿优先：该页有草稿框就用草稿，不再检测（§1.5）；
    // 没有草稿才跑检测，检测结果是原页坐标，先按草稿已存的旋转角度
    // 做坐标变换再进框列表（P2 实施注意 1，见 rotateBoxToRotatedPage）。
    final drafts = await repo.boxesForTask(task.id);
    final draftsByPage = <int, List<QuestionBox>>{};
    for (final b in drafts) {
      (draftsByPage[b.page] ??= []).add(b);
    }
    final pageRotation = task.pageRotations[task.page] ?? 0;
    var detected = const <QuestionBox>[];
    String? detectError;
    if ((draftsByPage[task.page] ?? const <QuestionBox>[]).isEmpty) {
      final yolo = yoloService ?? YoloOnnxService();
      final result = await yolo.detectPage(
        imagePath: pageImageAbs,
        page: task.page,
      );
      if (result.usedFallback) {
        // §1.3：模型失败不落占位框，只提示手动框选，原有框保持不动。
        detectError = result.error ?? '自动框不可用，请手动框选';
      } else {
        detected = result.boxes
            .map((b) => rotateBoxToRotatedPage(b, pageRotation))
            .toList();
      }
    }
    return (
      prep: BoxEditorPrep(
        pageImageAbs: pageImageAbs,
        pageImagePaths: pageImagePaths,
        draftsByPage: draftsByPage,
        detected: detected,
        detectError: detectError,
      ),
      error: null,
    );
  }

  /// 编辑器取消 / 切页时的草稿保存（`showBoxEditorDialog` 的 `onSaveDraft`）。
  Future<void> saveDraftBoxes(
    String taskId,
    Map<int, List<QuestionBox>> boxesByPage,
    Map<int, int> rotationsByPage,
  ) async {
    await _repo.saveDraftBoxes(
      taskId: taskId,
      boxesByPage: boxesByPage,
      rotations: rotationsByPage,
    );
  }

  /// SR-P2-22：按相对路径清单删文件（本次确认新写的切片/烘焙图）。
  /// 单个删失败不影响其余——清理本身走在失败处理里，静默跳过即可。
  /// 十四批 M2（P2-2）：经统一文件操作锁（本次新写的文件尚未入库，
  /// 无数据库引用；取锁防与备份导出/孤儿清理竞态）。
  Future<void> _deleteWrittenFiles(List<String> rels) async {
    final guard = FileLifecycleGuard.instance;
    for (final rel in rels) {
      final abs = AppDatabase.resolveDataPath(rel);
      final file = abs == null ? null : File(abs);
      if (file != null) await guard.deleteFile(file);
    }
  }

  /// §1.5/§1.6：确认拆题——先写切片文件（失败不写库），再四步同事务。
  /// 每页：旋转角度 != 0 时把旋转烘焙进页图（生成
  /// `pages/page-<p>-r<角度>.png`，框坐标已是旋转后的坐标系，
  /// 直接按框裁剪）；0° 时不生成新文件。
  /// 页图按页取（PDF 多页任务每页一张页图，图片任务每页同一张）；
  /// 某页页图缺失时整单失败、库不动。
  /// P1-2：没框的页不丢——确认前先报未框页数让用户知情；确认后
  /// 只拆有框的页，没框的页留在原任务里（同 id 重建、带上原任务的
  /// 修框中状态，从首个未框页继续修，见方法尾部与 SR2-22）。
  /// SR-P2-22：按相对路径清单删文件（本次确认新写的切片/烘焙图）。
  /// 单个删失败不影响其余——清理本身走在失败处理里，静默跳过即可。
  ///
  /// 还有未框页且 `confirmedUnboxed` 为假时，不写任何东西，只返回
  /// [ConfirmSplitKind.needsUnboxedConfirm]——页面弹“还有 N 页没有框”
  /// 确认框，用户确认后再调一次本方法（`confirmedUnboxed: true`）。
  Future<ConfirmSplitOutcome> confirmSplit(
    CollectTask task,
    Map<int, List<QuestionBox>> boxesByPage,
    Map<int, int> rotationsByPage, {
    bool confirmedUnboxed = false,
  }) async {
    // repo 入口处捕获一次：确认是长流程（写切片 + 事务），中途切页销毁
    // Provider 后尾部的 confirmSplit / saveRecentTask 再 ref.read 会抛
    // UnmountedRefException（load() 同款，见该方法注释）。
    final repo = _repo;
    final pages = boxesByPage.keys.toList()..sort();
    // P1-2：保留任务重进再确认时，已拆过的页不再重复拆（同 sourcePath
    // 的拆分任务就是已拆页；sourcePath 含原任务 id，重导入不串）。
    final alreadySplit = splitPagesFor(state.tasks, task);
    final boxedPages = <int>{
      for (final p in pages)
        if (!alreadySplit.contains(p) && boxesByPage[p]!.isNotEmpty) p,
    };
    var total = 0;
    for (final p in boxedPages) {
      total += boxesByPage[p]!.length;
    }
    if (total == 0) {
      final hadSkippedBoxes = pages.any(
        (p) => alreadySplit.contains(p) && boxesByPage[p]!.isNotEmpty,
      );
      await load();
      return ConfirmSplitOutcome.nothingToSplit(
        message: hadSkippedBoxes ? '这些页已经拆成题了，不用再拆' : null,
      );
    }
    final unboxedPages = <int>[
      for (var p = 1; p <= task.pageCount; p++)
        if (!boxedPages.contains(p) && !alreadySplit.contains(p)) p,
    ];
    if (unboxedPages.isNotEmpty && !confirmedUnboxed) {
      return ConfirmSplitOutcome.needsUnboxedConfirm(
        unboxedPages: unboxedPages,
        boxedPages: boxedPages.length,
        total: total,
      );
    }
    final ts = DateTime.now().millisecondsSinceEpoch;
    // SR-P2-60 同款：同一毫秒内两次确认会撞 id，补 6 位随机段（本次确认内共用）。
    // SR2-62：与上一次确认的戳撞上时重抽，保证两次确认的 id 不同。
    var rnd = math.Random().nextInt(1000000).toString().padLeft(6, '0');
    while ('$ts-$rnd' == _lastSplitStamp) {
      rnd = math.Random().nextInt(1000000).toString().padLeft(6, '0');
    }
    _lastSplitStamp = '$ts-$rnd';
    final questions = <Question>[];
    final splitTasks = <CollectTask>[];
    final boxesByQuestionId = <String, List<QuestionBox>>{};
    final isPdf = ImportService.isPdfTask(task);
    // SR-P2-22：本次确认新写的文件（切片 + 旋转烘焙页图）清单。
    // 切片写盘在事务前：某页裁剪失败或 confirmSplit 事务失败时，
    // 前面已写的文件会成孤儿留在 slices/、imports/<id>/pages/ 里，
    // 失败即按清单删（只删本次新建的，不碰原任务页图——rotation == 0
    // 时 bakedRel 就是原页图，不记）。先记后写：写一半失败的残文件
    // 也一并清掉（delete 时文件不存在也无妨）。
    // WP-C #8 U3-1：以下烘焙页图与切片写盘都持守门（与备份复制串行化，
    // 不读半写文件）；裁剪/解码等耗时计算在锁外，只包住写盘调用。
    // Win11 后续 Round 3 Stream C（Q4 §1.8 真实竞态）：写盘与事务提交
    // 之间，新切片在盘上存在、库里无任何行引用它——孤儿清理若恰在该
    // 窗口内确认删除，会把切片移入回收站，之后提交的题行 slice_path
    // 便指向回收站文件。故每条新文件在写盘前先登记 pending（与
    // figure_files.dart / detail_notifier.dart 同款协议），事务提交
    // 成功后解除；失败路径先按清单删文件、再解除登记，不留泄漏。
    // rotation == 0 时不写新文件，bakedRel 即原页图（已有父任务行
    // 保护），不登记。
    final guard = FileLifecycleGuard.instance;
    final writtenRels = <String>[];
    try {
      for (final p in pages) {
        // 已拆过的页不再切（见方法头的 alreadySplit）。
        if (alreadySplit.contains(p)) continue;
        final pageBoxes = boxesByPage[p]!;
        if (pageBoxes.isEmpty) continue;
        // 本页页图：PDF 每页一张，图片各页同一张；缺失则整单失败。
        final pageRel = ImportService.pageImageRelativeForTask(task, page: p);
        final pageAbs = pageRel.isEmpty
            ? null
            : AppDatabase.resolveDataPath(pageRel);
        if (pageAbs == null || !File(pageAbs).existsSync()) {
          throw StateError('第 $p 页的页图缺失');
        }
        final pageBytes = await File(pageAbs).readAsBytes();
        final rotation = rotationsByPage[p] ?? 0;
        late final Uint8List bakedBytes;
        late final String bakedRel;
        if (rotation != 0) {
          bakedBytes = await rotateImageBytes(pageBytes, rotation);
          bakedRel = ImportService.bakedPageRelative(task.id, p, rotation);
          final bakedAbs = AppDatabase.resolveDataPath(bakedRel)!;
          writtenRels.add(bakedRel);
          // 写盘前登记：烘焙图落盘后、事务提交前，孤儿清理须跳过它。
          guard.registerPending(bakedRel);
          await File(bakedAbs).parent.create(recursive: true);
          await guard.withLock(() => File(bakedAbs).writeAsBytes(bakedBytes));
        } else {
          bakedBytes = pageBytes;
          bakedRel = pageRel;
        }
        for (var i = 0; i < pageBoxes.length; i++) {
          final box = pageBoxes[i];
          final qid = 'import-$ts-$rnd-$p-$i';
          // 切片写盘在事务前：失败直接抛，库一律不动。
          final slice = await cropBoxPng(bakedBytes, box);
          final sliceRel = ImportService.sliceRelative(qid);
          final sliceAbs = AppDatabase.resolveDataPath(sliceRel)!;
          writtenRels.add(sliceRel);
          // 写盘前登记：切片落盘后、事务提交前，孤儿清理须跳过它。
          guard.registerPending(sliceRel);
          await File(sliceAbs).parent.create(recursive: true);
          await guard.withLock(() => File(sliceAbs).writeAsBytes(slice.png));
          questions.add(
            Question(
              id: qid,
              title: '${task.fileName} · 第$p页 · 第${i + 1}题',
              subjectId: task.subjectId,
              isDemo: false,
              isOrganized: false,
              createdAt: DateTime.now(),
              sourcePath: task.sourcePath,
              sourceKind: isPdf ? 'pdf' : 'image',
              sourcePage: p,
              pageImagePath: bakedRel,
              slicePath: sliceRel,
              sliceWidth: slice.width,
              sliceHeight: slice.height,
            ),
          );
          // 该题的框：题级框。
          boxesByQuestionId[qid] = [box];
          splitTasks.add(
            CollectTask(
              id: 'task-$ts-$rnd-$p-$i',
              name: '${task.fileName} · 第$p页 · 第${i + 1}题',
              fileName: task.fileName,
              subjectId: task.subjectId,
              status: CollectStatus.pendingOrganize,
              progress: 100,
              pageCount: task.pageCount,
              page: p,
              questionId: qid,
              createdAt: DateTime.now(),
              sourcePath: task.sourcePath,
            ),
          );
        }
      }
    } catch (e) {
      // SR-P2-22：裁剪/写盘失败——前面已写的新文件按清单删掉再提示，
      // 不留孤儿切片与烘焙图；原任务页图不在清单里，不会误删。
      // 先删文件、再解除登记（figure_files 回滚同款顺序）：删完才解，
      // 登记不泄漏；删失败的残文件此时已无库引用，留给孤儿清理收尾。
      await _deleteWrittenFiles(writtenRels);
      for (final rel in writtenRels) {
        guard.unregisterPending(rel);
      }
      await load();
      return ConfirmSplitOutcome.sliceFailed('拆题失败：切片写不进去（$e），请重试');
    }
    // 四步同事务：建题 + 回填 question_id + 建拆分任务 + 删原任务。
    // SR-P1-2：有未框页时，保留任务的重建也在同一事务里——保留任务
    // 与未框页草稿在确认前就构造好，随 confirmSplit 一起传进去；
    // 事务外重建有崩溃窗口（原任务已删、保留任务还没建出来，未框页
    // 连同页图引用一起丢）。无未框页时 retained 为空，行为不变。
    CollectTask? retained;
    Map<int, List<QuestionBox>> retainedBoxesByPage = const {};
    if (unboxedPages.isNotEmpty) {
      // 保留任务：按同 id 重建，页图目录 imports/<id>/ 不变，从首个
      // 未框页继续修；未框页的草稿与旋转角一并写回。
      // SR2-22：状态写 boxing，不重置回 needBox——boxing 就是“已打开过
      // 修框”的持久化标志（_openBoxEditor 打开时置为 boxing 并落盘）；
      // 保留任务只可能由编辑器确认产生，必定打开过，直接写 boxing，
      // 不依赖调用方传进来的状态值。行上按“修框中”显示（文案“上次修
      // 到一半，点「继续修框」接着修”正合此态），无框警告不再只靠派生
      // 的 _hasSplitSibling；删掉全部同源拆分任务行后警告仍在。
      retained = CollectTask(
        id: task.id,
        name: task.name,
        fileName: task.fileName,
        subjectId: task.subjectId,
        status: CollectStatus.boxing,
        progress: 100,
        pageCount: task.pageCount,
        page: unboxedPages.first,
        createdAt: task.createdAt,
        sourcePath: task.sourcePath,
        pageRotations: {
          for (final p in unboxedPages)
            if (rotationsByPage.containsKey(p)) p: rotationsByPage[p]!,
        },
        // 十二批 D-91：同 id 重建必须带上 sourceHash，否则写回抹掉哈希。
        sourceHash: task.sourceHash,
      );
      retainedBoxesByPage = {
        for (final p in unboxedPages)
          p: List.of(boxesByPage[p] ?? const <QuestionBox>[]),
      };
    }
    try {
      await repo.confirmSplit(
        originalTask: task,
        questions: questions,
        splitTasks: splitTasks,
        boxesByQuestionId: boxesByQuestionId,
        retainedTask: retained,
        retainedBoxesByPage: retainedBoxesByPage,
      );
    } catch (e) {
      // SR-P2-22：事务失败——库已回滚，本次新写的文件同样按清单删，
      // 不留孤儿切片与烘焙图；任务本身不动，用户可重试。
      // 先删文件、再解除登记（与写盘失败路径同款顺序），登记不泄漏。
      await _deleteWrittenFiles(writtenRels);
      for (final rel in writtenRels) {
        guard.unregisterPending(rel);
      }
      await load();
      return ConfirmSplitOutcome.saveFailed('拆题失败：保存失败（$e），请重试');
    }
    // 事务已提交：题行已引用本次新写的文件，解除待提交登记。
    // 放在 saveRecentTask / load / OCR 入队之前——后续步骤失败
    // 也不影响成功提示，登记绝不能因它们抛错而泄漏。
    for (final rel in writtenRels) {
      guard.unregisterPending(rel);
    }
    // SR2-25：收尾写最近任务失败也不影响成功提示与列表刷新——
    // 拆题已提交，记日志后继续。
    try {
      await repo.saveRecentTask(
        kind: '收集',
        subjectId: task.subjectId,
        title: task.fileName,
      );
    } catch (e) {
      debugPrint('SR2-25：saveRecentTask 失败，已忽略：$e');
    }
    await load();
    // 十三批 P1-2 任务 c：确认分框后批量入队——OcrWorker.enqueueForQuestions
    // 仍逐道吞错、只返回成功列表（见 ocr_queue.dart，P1-1 遗留 2）。
    // 调用点按 questionId 比对，没排上的题数必须告诉用户（非阻塞提示，
    // 附在成功提示后面），绝不能让批量入队失败静默。整理主流程绝不被
    // OCR 卡住：入队失败只改提示文案，outcome.kind 仍是 done，
    // 题已生成、列表已刷新；没排上的题可在详情页重新识别补救。
    // worker 未启动时（单测里 instanceOrNull 为 null）同样没排上，
    // 计全部未入队——生产上 worker 随应用启动拉起，null 只在启动
    // 失败/单测时出现，此时题确实没进队，提示是诚实的。
    var ocrMissed = 0;
    try {
      final worker = OcrWorker.instanceOrNull;
      if (worker == null) {
        ocrMissed = questions.length;
      } else {
        final jobs = await worker.enqueueForQuestions(questions);
        ocrMissed = ocrEnqueueMissedCount(questions, jobs);
      }
    } catch (_) {
      // 整批入队调用本身抛错（enqueueForQuestions 内部已逐道吞错，
      // 这里只是兜底）：按全部未入队报，宁可多报不可静默丢题。
      ocrMissed = questions.length;
    }
    final base = unboxedPages.isNotEmpty
        ? '已生成 $total 道题去整理，还有 ${unboxedPages.length} 页没框留在任务里'
        : '已生成 $total 道题，去整理吧';
    final message = ocrMissed > 0
        ? '$base。其中 $ocrMissed 道题还没识别，可在详情页重新识别。'
        : base;
    return ConfirmSplitOutcome.done(message);
  }

  // ---------- 删除 ----------

  /// 取消导入 / 取消排队：直接删，无二次确认。
  /// B3：失败任务的删除不再走这里，改走页面弹模态确认框后调本方法。
  Future<void> deleteTask(CollectTask task) async {
    await _repo.deleteCollectTask(task.id);
    await load();
  }

  /// 清理已整理（2026-11-26）：只删已整理任务的记录，走同一条
  /// deleteCollectTask——已整理进错题本的题不动（见
  /// deleteCollectTaskFrom）；未完成的任务一个不动。
  Future<void> clearDoneTasks() async {
    final doneIds = [
      for (final t in state.tasks)
        if (t.status == CollectStatus.done) t.id,
    ];
    for (final id in doneIds) {
      await _repo.deleteCollectTask(id);
    }
    await load();
  }
}
