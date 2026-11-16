import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repository.dart';
import '../../models/models.dart';
import '../../services/pdf_render_service.dart';
import '../../services/yolo_onnx_service.dart';
import '../../state/collect_notifier.dart';
import '../../state/repository_provider.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/uikit.dart';
import '../../widgets/widgets.dart';

import 'batch_import_card.dart';
import 'box_editor.dart';
import 'collect_widgets.dart';

/// 修框编辑器公开符号仍从本文件 re-export（B4 纯拆分）：`question_detail_page.dart`
/// 等现有调用方 import 本文件一字不用改。
export 'box_editor.dart';

/// 收集中心：选学科 → 选文件 → 任务列表 → 修框（覆盖式浮层）→ 待整理。
///
/// HTML 来源：`viewCollect` / `taskRow` / `frameEditorHTML`（交互原型实读）。
/// - 导入学科下拉默认“请选择学科”，每次导入都自己选，没选不能导入，
///   选完一批后清空；只收 PDF / JPG / PNG，PDF 50MB / 20 页（超了进
///   失败任务并提示分批导入），图片 20MB；手机传文件说明行（微信 / QQ /
///   局域网，无单独拍照入口）。
/// - 任务列表只按导入时间排（新的在上，`collect_tasks` 表 `rowid DESC`），
///   永不按状态重排；>3 个任务时列表变内部滚动区（高 408px）。
/// - 拖放导入（B11-1）：只接收集中心落点（`desktop_drop` 的
///   `DropTarget`），拖进来走与文件选择导入相同的流程（先选学科、
///   大小限制、重复提示“已经导入过”）；不接全窗口落点、不接微信 /
///   QQ 窗口拖入；拖放手感只在 Win11 真机上验。
/// - 左导航收集角标沿用现有口径（`BadgeCounts.countPendingBox` +
///   未整理题数），不改 repository。
/// - 页内无边距：外壳已给内容区 padding 26/30，本页不再叠加。
/// - 全部取 DesignTokens 与 UI Kit，不用图标字体（`Icon` 为零）。
///
/// ARCH-PLAN-A 第 3 阶段：业务逻辑在 `lib/state/collect_notifier.dart`
///（`CollectNotifier` + `collectProvider`）；本文件只留 widget 与纯 UI
/// 状态（`_picking` / `_noSubjectWarning` / `_hideErrorBanner` / `_filter` /
/// `_dragOver`）。修框状态（框选、缩放、旋转）是纯 UI 临时状态，留在
/// 编辑器本地 `setState`，不进 Provider。
class CollectPage extends StatefulWidget {
  const CollectPage({
    super.key,
    required this.repo,
    required this.onOpenOrganize,
    this.onGoSubjects,
    this.yoloService,
    this.pdfRenderService,
  });

  final QuestionRepository repo;
  final VoidCallback onOpenOrganize;

  /// B8-1：学科删空时导入行给出去学科管理的入口（可空；测试里不传
  /// 时只显示提示文字，不画按钮）。
  final VoidCallback? onGoSubjects;

  /// 检测服务（可注入；测试用桩服务可返回固定检测结果，避免
  /// 真实推理的耗时与不确定性；不传则用真实服务）。
  final YoloOnnxService? yoloService;

  /// PDF 渲染服务（可注入；测试用假引擎可返回固定页图，避免
  /// 真实渲染的耗时与不确定性；不传则用真实引擎）。
  final PdfRenderService? pdfRenderService;

  /// 待框选 + 修框中任务数（左导航角标用；沿用基线口径，未改）。
  /// 口径现由 `BadgeCounts.countPendingBox`（`lib/state/`）持有，
  /// 本页不再另存一份（Stage 4 角标收进 Provider 时移走）。

  @override
  State<CollectPage> createState() => _CollectPageState();
}

/// 外壳：只包一层 `ProviderScope`，把构造器接进来的库交进依赖图
///（D-35 外壳模式：内层 `Consumer` 的 ref 才属于这层 scope）。
/// 本阶段不碰 `lib/app.dart`，`repo` 构造参数保留。
class _CollectPageState extends State<CollectPage> {
  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(widget.repo)],
      child: _CollectView(
        onOpenOrganize: widget.onOpenOrganize,
        onGoSubjects: widget.onGoSubjects,
        yoloService: widget.yoloService,
        pdfRenderService: widget.pdfRenderService,
      ),
    );
  }
}

class _CollectView extends ConsumerStatefulWidget {
  const _CollectView({
    required this.onOpenOrganize,
    this.onGoSubjects,
    this.yoloService,
    this.pdfRenderService,
  });

  final VoidCallback onOpenOrganize;
  final VoidCallback? onGoSubjects;
  final YoloOnnxService? yoloService;
  final PdfRenderService? pdfRenderService;

  @override
  ConsumerState<_CollectView> createState() => _CollectViewState();
}

class _CollectViewState extends ConsumerState<_CollectView> {
  CollectNotifier get _notifier => ref.read(collectProvider.notifier);

  bool _picking = false;
  bool _noSubjectWarning = false;
  bool _hideErrorBanner = false;
  CollectStatus? _filter; // null = 全部；筛选不改变时间顺序
  // B11-1：有文件正悬在拖放区上（只改落点文案与边框，不改布局）。
  bool _dragOver = false;

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickFiles() async {
    // B11-2：没选学科也能先选文件——选完按文件名猜一个学科建议预填
    // 下拉框（只建议、不静默指定），仍没学科时文件暂存，等用户选好
    // 学科点“开始导入”再导；没选学科不能导入的口径不变。
    if (_picking) return;
    setState(() {
      _picking = true;
      _noSubjectWarning = false;
    });
    try {
      final paths = await _notifier.pickFiles(
        pdfRenderService: widget.pdfRenderService,
      );
      if (paths == null) {
        if (mounted) _snack('打不开文件选择器，请重试');
        return;
      }
      if (paths.isEmpty) return;
      await _handleIncomingPaths(paths);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// B11-1：拖放落点（`DropTarget.onDragDone`）。文件夹与空路径跳过
  /// 并提示，其余与文件选择导入走同一条 [_handleIncomingPaths]。
  Future<void> _onFilesDropped(DropDoneDetails details) async {
    if (_picking) return;
    final paths = <String>[];
    var skippedDirs = 0;
    for (final item in details.files) {
      if (item is DropItemDirectory) {
        skippedDirs++;
        continue;
      }
      if (item.path.isEmpty) continue;
      paths.add(item.path);
    }
    if (skippedDirs > 0) {
      _snack('文件夹不能直接拖：打开文件夹，把里面的文件拖进来');
    }
    if (paths.isEmpty) return;
    setState(() {
      _picking = true;
      _noSubjectWarning = false;
    });
    try {
      await _handleIncomingPaths(paths);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// B11-1 + B11-2：文件选择与拖放的统一入口（业务在 Notifier，
  /// 导入前提示经 `onNotice` 在导入开始前就弹出）。
  Future<void> _handleIncomingPaths(List<String> paths) async {
    await _notifier.handleIncomingPaths(
      paths,
      pdfRenderService: widget.pdfRenderService,
      onNotice: _snack,
    );
  }

  /// B11-2：暂存文件的“开始导入”。
  Future<void> _startStagedImport() async {
    final outcome = await _notifier.startStagedImport(
      pdfRenderService: widget.pdfRenderService,
      onNotice: _snack,
    );
    if (!mounted) return;
    if (outcome.needsSubject) {
      setState(() => _noSubjectWarning = true);
    }
  }

  void _discardStagedImport() {
    _notifier.discardStagedImport();
  }

  /// B11-2：重试本批全部失败项（只重导失败的，成功的、已在队列里
  /// 的不动；沿用本批的学科，不重新猜）。
  Future<void> _retryBatchFailures() async {
    final batch = ref.read(collectProvider).batch;
    if (batch == null || !batch.hasFailures || _picking) return;
    setState(() => _picking = true);
    try {
      await _notifier.retryBatchFailures(
        pdfRenderService: widget.pdfRenderService,
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// B11-2：重试队列里失败的一行。
  Future<void> _retryBatchPath(String path) async {
    final batch = ref.read(collectProvider).batch;
    if (batch == null || _picking) return;
    setState(() => _picking = true);
    try {
      await _notifier.retryBatchPath(
        path,
        pdfRenderService: widget.pdfRenderService,
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _confirmPendingImport() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      await _notifier.confirmPendingImport(
        pdfRenderService: widget.pdfRenderService,
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _discardPendingImport() {
    _notifier.discardPendingImport();
  }

  Future<void> _openBoxEditor(CollectTask task) async {
    final (prep: prep, error: error) = await _notifier.prepareBoxEditor(
      task,
      yoloService: widget.yoloService,
    );
    if (error != null) {
      _snack(error);
      return;
    }
    if (!mounted) return;
    final result = await showBoxEditorDialog(
      context: context,
      fileName: task.fileName,
      pageImagePath: prep!.pageImageAbs,
      pageImagePaths: prep.pageImagePaths,
      page: task.page,
      pageCount: task.pageCount,
      subjectName: ref.read(collectProvider).subjectOf(task.subjectId).name,
      taskId: task.id,
      mode: BoxEditorMode.draft,
      initialBoxesByPage: prep.draftsByPage,
      initialDetected: prep.detected,
      initialRotations: task.pageRotations,
      detectError: prep.detectError,
      yoloService: widget.yoloService ?? YoloOnnxService(),
      onSaveDraft: (draft) async {
        await _notifier.saveDraftBoxes(
          task.id,
          draft.boxesByPage,
          draft.rotationsByPage,
        );
      },
    );
    if (result == null) {
      // 取消中途退出：草稿已由编辑器保存，任务留“修框中”，
      // 下次点“继续修框”接着修。
      await _notifier.load();
      return;
    }
    await _confirmSplit(task, result);
  }

  /// §1.5/§1.6：确认拆题——未框页的确认框在页面里弹（要 `BuildContext`），
  /// 其余业务在 Notifier。
  Future<void> _confirmSplit(CollectTask task, BoxEditorResult result) async {
    final outcome = await _notifier.confirmSplit(
      task,
      result.boxesByPage,
      result.rotationsByPage,
    );
    if (!mounted) return;
    switch (outcome.kind) {
      case ConfirmSplitKind.needsUnboxedConfirm:
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('还有 ${outcome.unboxedPages.length} 页没有框'),
            content: Text(
              '第 ${pageListText(outcome.unboxedPages)} 页还没有框。确认后，有框的 ${outcome.boxedPages} 页先拆成 ${outcome.total} 道题去整理，没框的 ${outcome.unboxedPages.length} 页会留在这个任务里，之后点「修框」继续框。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('确认拆题'),
              ),
            ],
          ),
        );
        if (ok != true) {
          // 取消：什么都没拆，任务留修框中，下次接着修。
          return;
        }
        final confirmed = await _notifier.confirmSplit(
          task,
          result.boxesByPage,
          result.rotationsByPage,
          confirmedUnboxed: true,
        );
        if (!mounted) return;
        if (confirmed.message != null) _snack(confirmed.message!);
      case ConfirmSplitKind.done:
      case ConfirmSplitKind.nothingToSplit:
      case ConfirmSplitKind.sliceFailed:
      case ConfirmSplitKind.saveFailed:
        if (outcome.message != null) _snack(outcome.message!);
    }
  }

  /// 取消导入 / 取消排队：直接删，无二次确认。
  /// B3：失败任务的删除不再走这里，改走 [_deleteTask] 弹模态确认框。
  Future<void> _removeTask(CollectTask task) async {
    await _notifier.deleteTask(task);
  }

  /// B2-6a：删除任务（待框选 / 修框中 / 待整理 / 已整理行上的「删除」）：
  /// 先弹确认框（项目统一文案），确认后删任务 + 修框草稿 + 它拆出来的、
  /// 还没整理的题；已整理进错题本的题不动（见 deleteCollectTaskFrom）。
  Future<void> _deleteTask(CollectTask task) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删了就没了，确定吗？'),
        content: Text(
          '「${task.name}」这个任务、它的修框草稿和拆出来的、还没整理的题都会一起删掉；已经整理进错题本的题还在。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _notifier.deleteTask(task);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(collectProvider);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    final failed = s.tasks.where((t) => t.status == CollectStatus.failed);
    final shown = s.shownTasks(_filter);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SingleChildScrollView(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '收集中心',
              style: TextStyle(
                fontSize: DesignTokens.pageTitleFontSize,
                fontWeight: DesignTokens.pageTitleFontWeight,
                color: palette.ink,
                height: 1.2,
              ),
            ),
            SizedBox(height: 3 * scale),
            Text(
              '把纸变成题：导入 → 自动框题 → 修框 → 去整理 · 新流程不使用 OCR，文字内容在整理时人工补充',
              style: TextStyle(
                fontSize: DesignTokens.bodySmallFontSize,
                color: palette.muted,
                height: DesignTokens.bodyLineHeight,
              ),
            ),
            SizedBox(height: DesignTokens.homeSubtitleMarginBottom * scale),
            if (failed.isNotEmpty && !_hideErrorBanner)
              QmBanner(
                tone: QmBannerTone.error,
                message:
                    '有 ${failed.length} 个任务导入失败：${failed.map((t) => '文件「${t.fileName}」是${t.error ?? '导入失败'}').join('；')}。请自行检查自己的文件，其余任务不受影响。',
                onDismiss: () => setState(() => _hideErrorBanner = true),
              ),
            if (s.pendingImport != null) ...[
              if (s.pendingImport!.duplicateNames.isNotEmpty)
                QmBanner(
                  tone: QmBannerTone.warning,
                  title: '这个文件已经导入过。',
                  message:
                      '列表里已有「${s.pendingImport!.duplicateNames.join('、')}」的任务，再导一份会多出一组重复任务。要再导一份吗？',
                  actions: [
                    QmBannerAction(
                      label: '仍然再导一份',
                      onPressed: _confirmPendingImport,
                    ),
                    QmBannerAction(
                      label: '不导了',
                      onPressed: _discardPendingImport,
                    ),
                  ],
                ),
              if (s.pendingImport!.oversizeHints.isNotEmpty)
                QmBanner(
                  tone: QmBannerTone.warning,
                  title: '文件超过大小上限，导入会失败。',
                  message:
                      '${s.pendingImport!.oversizeHints.join(' ')}可以先压缩再重新选；如果仍要导入，超限的文件会记为失败任务，其他文件正常导入。',
                  actions: [
                    QmBannerAction(
                      label: '仍然再导一份',
                      onPressed: _confirmPendingImport,
                    ),
                    QmBannerAction(
                      label: '不导了',
                      onPressed: _discardPendingImport,
                    ),
                  ],
                ),
            ],
            if (_noSubjectWarning)
              QmBanner(
                tone: QmBannerTone.warning,
                title: '先选学科。',
                message: '每次导入都自己选：不默认上次选的，也不默认数学，没选学科不能导入。',
                onDismiss: () => setState(() => _noSubjectWarning = false),
              ),
            _importRow(scale, palette, s),
            SizedBox(height: 10 * scale),
            _dropZone(scale, palette),
            SizedBox(height: 10 * scale),
            Text(
              '手机拍完用微信 / QQ / 局域网传到电脑，再选文件导入即可——传过来的就是文件，不用单独的拍照入口。',
              style: TextStyle(
                fontSize: DesignTokens.captionFontSize,
                color: palette.muted,
                height: 1.55,
              ),
            ),
            if (s.stagedPaths != null) ...[
              SizedBox(height: 10 * scale),
              _stagedCard(scale, palette, s),
            ],
            if (s.batch != null) ...[
              SizedBox(height: 10 * scale),
              BatchImportCard(
                batch: s.batch!,
                onRetryFailed: _retryBatchFailures,
                onRetryPath: _retryBatchPath,
                onDismiss: () => _notifier.dismissBatch(),
              ),
            ],
            SizedBox(height: 22 * scale),
            Text(
              '收集任务',
              style: TextStyle(
                fontSize: DesignTokens.homeSectionTitleFontSize,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.08,
                color: palette.muted,
                height: 1.2,
              ),
            ),
            SizedBox(height: 4 * scale),
            Text(
              '按导入时间排，新的在上面，不按状态排 · 导入中 ${s.count(CollectStatus.importing)} · 排队中 ${s.count(CollectStatus.queued)} · 待框选 ${s.count(CollectStatus.needBox)} · 修框中 ${s.count(CollectStatus.boxing)} · 待整理 ${s.count(CollectStatus.pendingOrganize)}${failed.isNotEmpty ? ' · 失败 ${failed.length}' : ''}',
              style: TextStyle(
                fontSize: DesignTokens.bodySmallFontSize,
                color: palette.muted,
                height: DesignTokens.bodyLineHeight,
              ),
            ),
            SizedBox(height: 2 * scale),
            _filterChips(scale, s),
            SizedBox(height: 6 * scale),
            if (s.tasks.isEmpty)
              QmEmptyState(
                title: '还没有收集任务，拖一个文件进来吧',
                description:
                    '把一份卷子（PDF）或错题照片（JPG / PNG）放进来，系统会先框出每一道完整的题，再请你确认框得对不对。',
                actionLabel: '选择文件导入',
                onAction: _pickFiles,
              )
            else if (shown.isEmpty)
              Text(
                '当前筛选下没有任务，换个状态看看。',
                style: TextStyle(
                  fontSize: DesignTokens.bodySmallFontSize,
                  color: palette.muted,
                ),
              )
            else if (shown.length > 3)
              // 超过 3 个任务：固定高度内部滚动区。
              Container(
                key: const Key('collect-task-list'),
                height: DesignTokens.collectTaskScrollHeight * scale,
                decoration: BoxDecoration(
                  color: palette.surface,
                  border: Border.all(color: palette.line),
                  borderRadius: BorderRadius.circular(
                    DesignTokens.scaled(scale).radiusLg,
                  ),
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: 14 * scale,
                  vertical: 2 * scale,
                ),
                child: ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (ctx, i) => _taskRow(shown[i], scale, palette, s),
                ),
              )
            else
              Container(
                key: const Key('collect-task-list'),
                decoration: BoxDecoration(
                  color: palette.surface,
                  border: Border.all(color: palette.line),
                  borderRadius: BorderRadius.circular(
                    DesignTokens.scaled(scale).radiusLg,
                  ),
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: 14 * scale,
                  vertical: 2 * scale,
                ),
                child: Column(
                  children: shown
                      .map((t) => _taskRow(t, scale, palette, s))
                      .toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _importRow(double scale, AppPalette palette, CollectState s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '导入学科',
              style: TextStyle(
                fontSize: DesignTokens.buttonFontSize,
                fontWeight: FontWeight.w700,
                color: palette.ink,
                height: DesignTokens.controlLineHeight,
              ),
            ),
            SizedBox(width: 8 * scale),
            Expanded(
              child: Container(
                key: const Key('collect-subject-select-field'),
                // B2-1：底色必须显式给 palette.surface——外层不给底色时，
                // DropdownButton 的 InkWell 在 Win11 桌面默认 traditional
                // 高亮模式下，获焦会叠加系统 focusColor（12% 黑），
                // 在 surface 上就是截图里那块禁用灰（悬停时再叠 4% 黑的
                // hoverColor，合起来正好是 #D7D6D2）；focusColor 置透明
                // 后，选中态恢复正常底色。悬停那层 4% 是标准 Material
                // 反馈、鼠标移开即消失，不动它（DropdownButton 也没有
                // hoverColor 参数；包一层改主题的 hoverColor 会连下拉
                // 菜单项的高亮一起去掉，得不偿失）。
                decoration: BoxDecoration(
                  color: palette.surface,
                  border: Border.all(color: palette.lineStrong),
                  borderRadius: BorderRadius.circular(
                    DesignTokens.scaled(scale).radius,
                  ),
                ),
                padding: EdgeInsets.symmetric(horizontal: 12 * scale),
                child: DropdownButton<String>(
                  key: const Key('collect-subject-select'),
                  value: s.selectedSubjectId,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  borderRadius: BorderRadius.circular(
                    DesignTokens.scaled(scale).radius,
                  ),
                  dropdownColor: palette.surface,
                  focusColor: Colors.transparent,
                  style: TextStyle(
                    fontSize: DesignTokens.bodyFontSize,
                    color: palette.ink,
                  ),
                  icon: QmGlyph(QmGlyphs.chevronDown, color: palette.muted),
                  hint: Text(
                    // B8-1：学科删空时下拉无选项——改提示、禁用下拉，
                    // 不再靠回退的预设三科充数。
                    s.subjects.isEmpty ? '还没有学科' : '请选择学科',
                    style: TextStyle(color: palette.muted),
                  ),
                  items: s.subjects
                      .map(
                        (s) =>
                            DropdownMenuItem(value: s.id, child: Text(s.name)),
                      )
                      .toList(),
                  onChanged: s.subjects.isEmpty
                      ? null
                      : (v) => _notifier.selectSubject(v),
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: 4 * scale),
        Text(
          // B8-1：学科删空时说明去处，不留一个打不开的空下拉。
          s.subjects.isEmpty
              ? '还没有学科：先去「学科管理」添加一个，再回来导入。'
              : '每次导入都自己选：不默认上次选的，也不默认数学，没选学科不能导入',
          style: TextStyle(
            fontSize: DesignTokens.captionFontSize,
            color: palette.muted,
            height: 1.4,
          ),
        ),
        // B11-2：按文件名猜学科的建议提示（只建议，用户随时可改下拉）。
        if (s.subjectGuessHint != null) ...[
          SizedBox(height: 4 * scale),
          Text(
            s.subjectGuessHint!,
            style: TextStyle(
              fontSize: DesignTokens.captionFontSize,
              color: palette.accentText,
              height: 1.4,
            ),
          ),
        ],
        if (s.subjects.isEmpty && widget.onGoSubjects != null) ...[
          SizedBox(height: 8 * scale),
          QmButton(
            label: '去学科管理',
            variant: QmButtonVariant.primary,
            size: QmButtonSize.small,
            onPressed: widget.onGoSubjects,
          ),
        ],
      ],
    );
  }

  Widget _dropZone(double scale, AppPalette palette) {
    // B11-1：只接收集中心落点（不接全窗口、不接微信 / QQ 窗口拖入）。
    // 拖进来走与文件选择导入相同的流程（先选学科、大小限制、重复
    // 提示“已经导入过”）；悬停时标题变“松开就导入”并加粗边框。
    return DropTarget(
      onDragEntered: (_) {
        if (mounted) setState(() => _dragOver = true);
      },
      onDragExited: (_) {
        if (mounted) setState(() => _dragOver = false);
      },
      onDragDone: _onFilesDropped,
      child: GestureDetector(
        key: const Key('collect-drop'),
        onTap: _pickFiles,
        child: CustomPaint(
          painter: DashedDropPainter(
            color: palette.accent,
            radius: DesignTokens.scaled(scale).radiusLg,
          ),
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.all(DesignTokens.collectDropPadding * scale),
            decoration: BoxDecoration(
              color: palette.accentSoft,
              borderRadius: BorderRadius.circular(
                DesignTokens.scaled(scale).radiusLg,
              ),
              border: _dragOver
                  ? Border.all(color: palette.accent, width: 2 * scale)
                  : null,
            ),
            child: Column(
              children: [
                Text(
                  _dragOver ? '松开就导入' : '把文件拖到这里，或点击选择',
                  style: TextStyle(
                    fontSize: DesignTokens.collectDropTitleFontSize,
                    fontWeight: FontWeight.w800,
                    color: palette.ink,
                    height: 1.2,
                  ),
                ),
                SizedBox(height: 4 * scale),
                Text(
                  'PDF 与 JPG / PNG 照片都能导（Word 先导出成 PDF 再导入）',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: DesignTokens.bodySmallFontSize,
                    color: palette.muted,
                    height: 1.4,
                  ),
                ),
                SizedBox(height: 4 * scale),
                Text(
                  '单个 PDF 不超过 50MB、20 页，超了进失败任务并提示分批导入 · 图片不超过 20MB · 一份卷子会按页逐页框题 · 一次拖进来多个文件会排队逐个导入，进度在下面可见，失败的可以重试',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: DesignTokens.bodySmallFontSize,
                    color: palette.muted,
                    height: 1.4,
                  ),
                ),
                SizedBox(height: 16 * scale),
                QmButton(
                  label: _picking ? '选择中…' : '选择文件',
                  onPressed: _picking ? null : _pickFiles,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// B11-2：没选学科时暂存的文件卡片——列出文件名，等用户在上方选
  /// 好学科后点“开始导入”；也可以“取消”丢掉这批暂存。
  Widget _stagedCard(double scale, AppPalette palette, CollectState s) {
    final staged = s.stagedPaths ?? const <String>[];
    return Container(
      key: const Key('staged-import-card'),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(color: palette.line),
        borderRadius: BorderRadius.circular(
          DesignTokens.scaled(scale).radiusLg,
        ),
      ),
      padding: EdgeInsets.all(14 * scale),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '已选 ${staged.length} 个文件，等选学科',
            style: TextStyle(
              fontSize: DesignTokens.bodyFontSize,
              fontWeight: FontWeight.w700,
              color: palette.ink,
              height: 1.3,
            ),
          ),
          SizedBox(height: 4 * scale),
          Text(
            staged.map((p) => File(p).uri.pathSegments.last).join('、'),
            style: TextStyle(
              fontSize: DesignTokens.bodySmallFontSize,
              color: palette.muted,
              height: 1.4,
            ),
          ),
          SizedBox(height: 4 * scale),
          Text(
            '先在上面选好学科，再点“开始导入”。',
            style: TextStyle(
              fontSize: DesignTokens.bodySmallFontSize,
              color: palette.muted,
              height: 1.4,
            ),
          ),
          SizedBox(height: 10 * scale),
          Row(
            children: [
              QmButton(
                key: const Key('staged-import-start'),
                label: '开始导入',
                variant: QmButtonVariant.primary,
                size: QmButtonSize.small,
                onPressed: _picking ? null : _startStagedImport,
              ),
              SizedBox(width: 8 * scale),
              QmButton(
                label: '取消',
                variant: QmButtonVariant.plain,
                size: QmButtonSize.small,
                onPressed: _picking ? null : _discardStagedImport,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _filterChips(double scale, CollectState s) {
    final filters = <(String, CollectStatus?)>[
      ('全部 ${s.tasks.length}', null),
      ('导入中 ${s.count(CollectStatus.importing)}', CollectStatus.importing),
      ('排队中 ${s.count(CollectStatus.queued)}', CollectStatus.queued),
      ('待框选 ${s.count(CollectStatus.needBox)}', CollectStatus.needBox),
      ('修框中 ${s.count(CollectStatus.boxing)}', CollectStatus.boxing),
      (
        '待整理 ${s.count(CollectStatus.pendingOrganize)}',
        CollectStatus.pendingOrganize,
      ),
    ];
    return Wrap(
      spacing: 6 * scale,
      runSpacing: 6 * scale,
      children: filters.map((f) {
        final key = f.$2 == null
            ? 'collect-filter-all'
            : 'collect-filter-${f.$2!.name}';
        return QmChip(
          key: Key(key),
          label: f.$1,
          selected: _filter == f.$2,
          onTap: () => setState(() => _filter = f.$2),
        );
      }).toList(),
    );
  }

  Widget _taskRow(
    CollectTask task,
    double scale,
    AppPalette palette,
    CollectState s,
  ) {
    final subject = s.subjectOf(task.subjectId);
    final isLast = s.shownTasks(_filter).last == task;
    // SR-P2-25：红色无框警告只对“打开过修框或已有任意草稿框”的任务
    // 显示（Meng 已定，收窄范围）。新导入、从未打开过的任务不警告。
    // “打开过”不用新字段：_openBoxEditor 打开时就把任务置为 boxing
    // 并落盘；needBox 任务有任意草稿框也一定打开过（草稿只由编辑器
    // 写；P1-2 保留任务的未框页草稿同样来自编辑器）。P1-2 保留任务
    // 自 SR2-22 起重建时直接写 boxing，警告走状态本身，不再依赖拆分
    // 任务行；_hasSplitSibling 只为修前已重建回 needBox 的旧保留任务
    // 兜底（有同源拆分任务即一定打开并确认过）。
    final warnUnboxed =
        task.status == CollectStatus.boxing ||
        s.hasAnyDraftBox.contains(task.id) ||
        s.hasSplitSibling.contains(task.id);
    final row = Padding(
      padding: EdgeInsets.symmetric(
        vertical: DesignTokens.collectTaskRowPaddingV * scale,
        horizontal: DesignTokens.collectTaskRowPaddingH * scale,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        SubjectLabel(
                          subjectId: task.subjectId,
                          subject: subject,
                        ),
                        SizedBox(width: 6 * scale),
                        Expanded(
                          child: Text(
                            task.name,
                            style: TextStyle(
                              fontSize: DesignTokens.bodyFontSize,
                              fontWeight: FontWeight.w700,
                              color: palette.ink,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 2 * scale),
                    Text(
                      taskNote(task, subject.name),
                      style: TextStyle(
                        fontSize: DesignTokens.bodySmallFontSize,
                        color: palette.muted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 14 * scale),
              _statusPill(task, palette),
              SizedBox(width: 8 * scale),
              Flexible(
                child: Wrap(
                  spacing: 8 * scale,
                  runSpacing: 6 * scale,
                  children: _taskActions(task),
                ),
              ),
            ],
          ),
          // P1-2 补充：待框选/修框中任务里还有没框的页，行上出红色警告
          //（单张图：“这张图还没有框”；多页：报页数与页码）。
          // SR-P2-25：只对打开过修框或已有任意草稿框的任务显示，
          // 新导入的任务不警告（见 _taskRow 头的 warnUnboxed）。
          // 行与页的对应：一个任务一行，一行管 pageCount 张图，
          // 未框页是 load 按草稿框逐页算出来的（见 unboxedPagesByTask）。
          if (warnUnboxed &&
              (s.unboxedPagesByTask[task.id] ?? const <int>[]).isNotEmpty) ...[
            SizedBox(height: 6 * scale),
            Text(
              noBoxWarningText(task, s.unboxedPagesByTask[task.id]!),
              style: TextStyle(
                fontSize: DesignTokens.bodySmallFontSize,
                color: palette.errInk,
                height: 1.4,
              ),
            ),
          ],
          if (task.status == CollectStatus.importing) ...[
            SizedBox(height: 8 * scale),
            ClipRRect(
              borderRadius: BorderRadius.circular(99 * scale),
              child: LinearProgressIndicator(
                value: task.progress / 100,
                minHeight: 8 * scale,
                backgroundColor: palette.surface3,
                valueColor: AlwaysStoppedAnimation<Color>(palette.accent),
              ),
            ),
            SizedBox(height: 4 * scale),
            Text(
              '导入中 ${task.progress}%',
              style: TextStyle(
                fontSize: DesignTokens.bodySmallFontSize,
                color: palette.muted,
              ),
            ),
          ],
          if (task.status == CollectStatus.failed && task.error != null) ...[
            SizedBox(height: 6 * scale),
            Text(
              task.error!,
              style: TextStyle(
                fontSize: DesignTokens.bodySmallFontSize,
                color: palette.errInk,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
    if (isLast) return row;
    return Column(
      children: [
        row,
        QmRowLine(kind: QmRowLineKind.line),
      ],
    );
  }

  Widget _statusPill(CollectTask task, AppPalette palette) {
    return switch (task.status) {
      CollectStatus.importing => QmStatusPill.tone(
        label: '导入中 · 检测 ${task.progress}%',
        tone: QmTone.info,
      ),
      CollectStatus.queued => QmStatusPill.tone(
        label: '排队中',
        tone: QmTone.warn,
      ),
      CollectStatus.needBox => QmStatusPill.tone(
        label: '待框选',
        tone: QmTone.warn,
      ),
      CollectStatus.boxing => QmStatusPill.tone(
        label: '修框中',
        tone: QmTone.info,
      ),
      CollectStatus.pendingOrganize => QmStatusPill(
        label: '待整理',
        background: palette.accentSoft,
        foreground: palette.accentText,
      ),
      CollectStatus.failed => QmStatusPill.tone(
        label: '导入失败',
        tone: QmTone.error,
      ),
      CollectStatus.done => QmStatusPill(
        label: '已整理',
        background: palette.accentSoft,
        foreground: palette.accentText,
      ),
    };
  }

  List<Widget> _taskActions(CollectTask task) {
    const small = QmButtonSize.small;
    return switch (task.status) {
      CollectStatus.importing => [
        QmButton(
          label: '取消导入',
          variant: QmButtonVariant.plain,
          size: small,
          onPressed: () => _removeTask(task),
        ),
      ],
      CollectStatus.queued => [
        QmButton(
          label: '取消排队',
          variant: QmButtonVariant.plain,
          size: small,
          onPressed: () => _removeTask(task),
        ),
      ],
      CollectStatus.needBox => [
        QmButton(
          label: '修框',
          variant: QmButtonVariant.plain,
          size: small,
          onPressed: () => _openBoxEditor(task),
        ),
        QmButton(label: '去整理', size: small, onPressed: widget.onOpenOrganize),
        QmButton(
          label: '删除',
          variant: QmButtonVariant.plain,
          size: small,
          onPressed: () => _deleteTask(task),
        ),
      ],
      CollectStatus.boxing => [
        QmButton(
          label: '继续修框',
          variant: QmButtonVariant.plain,
          size: small,
          onPressed: () => _openBoxEditor(task),
        ),
        QmButton(label: '去整理', size: small, onPressed: widget.onOpenOrganize),
        QmButton(
          label: '删除',
          variant: QmButtonVariant.plain,
          size: small,
          onPressed: () => _deleteTask(task),
        ),
      ],
      CollectStatus.pendingOrganize => [
        QmButton(label: '去整理', size: small, onPressed: widget.onOpenOrganize),
        QmButton(
          label: '删除',
          variant: QmButtonVariant.plain,
          size: small,
          onPressed: () => _deleteTask(task),
        ),
      ],
      CollectStatus.failed => [
        QmButton(
          label: '删除任务',
          variant: QmButtonVariant.plain,
          size: small,
          // B3：失败任务的删除也要弹模态确认框，与其他状态的删除一致。
          onPressed: () => _deleteTask(task),
        ),
      ],
      CollectStatus.done => [
        QmButton(
          label: '删除',
          variant: QmButtonVariant.plain,
          size: small,
          onPressed: () => _deleteTask(task),
        ),
      ],
    };
  }
}
