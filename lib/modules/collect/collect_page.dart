import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/repository.dart';
import '../../models/models.dart';
import '../../services/import_service.dart';
import '../../services/yolo_onnx_service.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/uikit.dart';
import '../../widgets/widgets.dart';

/// 收集中心：选学科 → 选文件 → 任务列表 → 修框（覆盖式浮层）→ 待整理。
///
/// HTML 来源：`viewCollect` / `taskRow` / `frameEditorHTML`（交互原型实读）。
/// - 导入学科下拉默认“请选择学科”，每次导入都自己选，没选不能导入，
///   选完一批后清空；只收 PDF / JPG / PNG，PDF 50MB / 图片 20MB，
///   超限只提示不判失败；手机传文件说明行（微信 / QQ / 局域网，
///   无单独拍照入口）。
/// - 任务列表只按导入时间排（新的在上，`collect_tasks` 表 `rowid DESC`），
///   永不按状态重排；>3 个任务时列表变内部滚动区（高 408px）。
/// - 系统拖拽导入未实现，拖放区只写占位文案，不谎称已接通。
/// - 左导航收集角标沿用现有口径（`CollectPage.countPendingBox` +
///   未整理题数），不改 repository。
/// - 页内无边距：外壳已给内容区 padding 26/30，本页不再叠加。
/// - 全部取 DesignTokens 与 UI Kit，不用图标字体（`Icon` 为零）。
class CollectPage extends StatefulWidget {
  const CollectPage({
    super.key,
    required this.repo,
    required this.onOpenOrganize,
  });

  final QuestionRepository repo;
  final VoidCallback onOpenOrganize;

  /// 待框选 + 修框中任务数（左导航角标用；沿用基线口径，未改）。
  static int countPendingBox(List<CollectTask> tasks) => tasks
      .where(
        (t) =>
            t.status == CollectStatus.needBox ||
            t.status == CollectStatus.boxing,
      )
      .length;

  @override
  State<CollectPage> createState() => _CollectPageState();
}

/// 待确认的一批导入：已选文件，但重复 / 超限警告还没被用户处理。
class _PendingImport {
  const _PendingImport({
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

class _CollectPageState extends State<CollectPage> {
  List<CollectTask> _tasks = [];
  String? _selectedSubjectId; // 每次导入都选，默认“请选择学科”
  bool _picking = false;
  bool _noSubjectWarning = false;
  bool _hideErrorBanner = false;
  CollectStatus? _filter; // null = 全部；筛选不改变时间顺序
  _PendingImport? _pendingImport;
  final _timers = <String, Timer>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final tasks = await widget.repo.collectTasks();
    if (!mounted) return;
    setState(() => _tasks = tasks);
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickFiles() async {
    if (_selectedSubjectId == null) {
      setState(() => _noSubjectWarning = true);
      return;
    }
    if (_picking) return;
    setState(() {
      _picking = true;
      _noSubjectWarning = false;
    });
    try {
      final service = ImportService(widget.repo.db);
      final paths = await service.pickFiles();
      if (paths.isEmpty) return;
      final duplicateNames = <String>[];
      final oversizeHints = <String>[];
      for (final path in paths) {
        final file = File(path);
        final name = file.uri.pathSegments.last;
        if (_tasks.any((t) => t.fileName == name) &&
            !duplicateNames.contains(name)) {
          duplicateNames.add(name);
        }
        try {
          final hint = ImportService.oversizeHint(file);
          if (hint != null) oversizeHints.add(hint);
        } catch (_) {}
      }
      // 重复文件 / 超限均为黄色横幅：用户选“仍要导入”才继续，
      // 选“不导了”则整批取消；两种警告都不是失败。
      if (duplicateNames.isNotEmpty || oversizeHints.isNotEmpty) {
        if (!mounted) return;
        setState(
          () => _pendingImport = _PendingImport(
            paths: paths,
            subjectId: _selectedSubjectId!,
            duplicateNames: duplicateNames,
            oversizeHints: oversizeHints,
          ),
        );
        return;
      }
      await _importFiles(paths, _selectedSubjectId!);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _confirmPendingImport() async {
    final pending = _pendingImport;
    if (pending == null || _picking) return;
    setState(() {
      _pendingImport = null;
      _picking = true;
    });
    try {
      await _importFiles(pending.paths, pending.subjectId);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _discardPendingImport() {
    setState(() => _pendingImport = null);
  }

  Future<void> _importFiles(List<String> paths, String subjectId) async {
    final service = ImportService(widget.repo.db);
    for (final path in paths) {
      final file = File(path);
      final name = file.uri.pathSegments.last;
      if (!file.existsSync()) {
        await _failTask(name, subjectId, '文件损坏：找不到这个文件');
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
        await _failTask(name, subjectId, failure);
        continue;
      }
      final created = await service.enqueue([path], subjectId: subjectId);
      for (final task in created) {
        _simulateImport(task);
      }
    }
    await widget.repo.saveRecentTask(
      kind: 'collect',
      subjectId: subjectId,
      title: paths.map((p) => File(p).uri.pathSegments.last).join('、'),
    );
    // 选完一批后清空已选学科，下次导入重新选。
    if (mounted) setState(() => _selectedSubjectId = null);
    await _load();
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
    String fileName,
    String subjectId,
    String error,
  ) async {
    final task = CollectTask(
      id: 'task-${DateTime.now().millisecondsSinceEpoch}-${fileName.hashCode}',
      name: '$fileName · 第1页 · 第1题',
      fileName: fileName,
      subjectId: subjectId,
      status: CollectStatus.failed,
      error: error,
    );
    await widget.repo.saveCollectTask(task);
  }

  /// 导入进度模拟：排队中 → 导入中（百分比）→ 待框选。
  /// 真实解析与 YOLO 检测接好后在此替换为真实进度。
  void _simulateImport(CollectTask task) {
    _timers[task.id]?.cancel();
    _timers[task.id] = Timer.periodic(const Duration(milliseconds: 160), (
      timer,
    ) async {
      final current = _tasks.firstWhere(
        (t) => t.id == task.id,
        orElse: () => task,
      );
      if (current.status == CollectStatus.failed) {
        timer.cancel();
        return;
      }
      final next = current.progress + 14;
      if (next >= 100) {
        timer.cancel();
        current.status = CollectStatus.needBox;
        current.progress = 100;
      } else {
        current.status = CollectStatus.importing;
        current.progress = next;
      }
      await widget.repo.saveCollectTask(current);
      if (mounted) _load();
    });
  }

  Future<void> _openBoxEditor(CollectTask task) async {
    task.status = CollectStatus.boxing;
    await widget.repo.saveCollectTask(task);
    await _load();
    final boxes = await YoloOnnxService().detectPage(
      imagePath: task.fileName,
      page: task.page,
    );
    if (!mounted) return;
    final confirmed = await showDialog<Map<int, List<QuestionBox>>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BoxEditorDialog(
        fileName: task.fileName,
        page: task.page,
        pageCount: task.pageCount,
        subjectName: Subject.byId(task.subjectId).name,
        initialBoxes: boxes,
      ),
    );
    if (confirmed == null) {
      // 取消中途退出：任务留“修框中”，不回待框选，下次点“继续修框”接着修。
      await _load();
      return;
    }
    final pages = confirmed.keys.toList()..sort();
    var total = 0;
    for (final p in pages) {
      total += confirmed[p]!.where((b) => b.layer == 1).length;
    }
    if (total == 0) {
      await _load();
      return;
    }
    // 确认按框数拆分：原任务被拆出的新任务替换，不留原任务。
    final ts = DateTime.now().millisecondsSinceEpoch;
    for (final p in pages) {
      final layer1 = confirmed[p]!.where((b) => b.layer == 1).toList();
      for (var i = 0; i < layer1.length; i++) {
        final qid = 'import-$ts-$p-$i';
        await widget.repo.save(
          Question(
            id: qid,
            title: '${task.fileName} · 第$p页 · 第${i + 1}题',
            subjectId: task.subjectId,
            isDemo: false,
            isOrganized: false,
            createdAt: DateTime.now(),
          ),
        );
        await widget.repo.saveCollectTask(
          CollectTask(
            id: 'task-$ts-$p-$i',
            name: '${task.fileName} · 第$p页 · 第${i + 1}题',
            fileName: task.fileName,
            subjectId: task.subjectId,
            status: CollectStatus.pendingOrganize,
            progress: 100,
            pageCount: task.pageCount,
            page: p,
            questionId: qid,
          ),
        );
      }
    }
    await widget.repo.deleteCollectTask(task.id);
    await widget.repo.saveRecentTask(
      kind: 'collect',
      subjectId: task.subjectId,
      title: task.fileName,
    );
    await _load();
    if (mounted) _snack('已生成 $total 道题，去整理吧');
  }

  /// 取消导入 / 取消排队 / 删除失败任务：直接删，无二次确认。
  Future<void> _removeTask(CollectTask task) async {
    _timers[task.id]?.cancel();
    await widget.repo.deleteCollectTask(task.id);
    await _load();
  }

  int _count(CollectStatus status) =>
      _tasks.where((t) => t.status == status).length;

  List<CollectTask> get _shownTasks {
    // 只按导入时间排（新的在上，来自 collect_tasks 的 rowid DESC），
    // 筛选只过滤，不改变顺序；永不按状态重排。
    if (_filter == null) return _tasks;
    return _tasks.where((t) => t.status == _filter).toList();
  }

  @override
  Widget build(BuildContext context) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    final failed = _tasks.where((t) => t.status == CollectStatus.failed);
    final shown = _shownTasks;
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
            if (_pendingImport != null) ...[
              if (_pendingImport!.duplicateNames.isNotEmpty)
                QmBanner(
                  tone: QmBannerTone.warning,
                  title: '这个文件已经导入过。',
                  message:
                      '列表里已有「${_pendingImport!.duplicateNames.join('、')}」的任务，再导一份会多出一组重复任务。要再导一份吗？',
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
              if (_pendingImport!.oversizeHints.isNotEmpty)
                QmBanner(
                  tone: QmBannerTone.warning,
                  title: '文件超过大小上限，只是提示，不直接判失败。',
                  message:
                      '${_pendingImport!.oversizeHints.join(' ')}可以先压缩再重新选，也可以仍要导入，大文件检测会慢一些。',
                  actions: [
                    QmBannerAction(
                      label: '仍要导入',
                      onPressed: _confirmPendingImport,
                    ),
                    QmBannerAction(
                      label: '先不导',
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
            _importRow(scale, palette),
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
              '按导入时间排，新的在上面，不按状态排 · 导入中 ${_count(CollectStatus.importing)} · 排队中 ${_count(CollectStatus.queued)} · 待框选 ${_count(CollectStatus.needBox)} · 修框中 ${_count(CollectStatus.boxing)} · 待整理 ${_count(CollectStatus.pendingOrganize)}${failed.isNotEmpty ? ' · 失败 ${failed.length}' : ''}',
              style: TextStyle(
                fontSize: DesignTokens.bodySmallFontSize,
                color: palette.muted,
                height: DesignTokens.bodyLineHeight,
              ),
            ),
            SizedBox(height: 2 * scale),
            _filterChips(scale),
            SizedBox(height: 6 * scale),
            if (_tasks.isEmpty)
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
                  itemBuilder: (ctx, i) => _taskRow(shown[i], scale, palette),
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
                      .map((t) => _taskRow(t, scale, palette))
                      .toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _importRow(double scale, AppPalette palette) {
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
                decoration: BoxDecoration(
                  border: Border.all(color: palette.lineStrong),
                  borderRadius: BorderRadius.circular(
                    DesignTokens.scaled(scale).radius,
                  ),
                ),
                padding: EdgeInsets.symmetric(horizontal: 12 * scale),
                child: DropdownButton<String>(
                  key: const Key('collect-subject-select'),
                  value: _selectedSubjectId,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  borderRadius: BorderRadius.circular(
                    DesignTokens.scaled(scale).radius,
                  ),
                  dropdownColor: palette.surface,
                  style: TextStyle(
                    fontSize: DesignTokens.bodyFontSize,
                    color: palette.ink,
                  ),
                  icon: QmGlyph(QmGlyphs.chevronDown, color: palette.muted),
                  hint: Text('请选择学科', style: TextStyle(color: palette.muted)),
                  items: Subject.all
                      .map(
                        (s) =>
                            DropdownMenuItem(value: s.id, child: Text(s.name)),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => _selectedSubjectId = v),
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: 4 * scale),
        Text(
          '每次导入都自己选：不默认上次选的，也不默认数学，没选学科不能导入',
          style: TextStyle(
            fontSize: DesignTokens.captionFontSize,
            color: palette.muted,
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _dropZone(double scale, AppPalette palette) {
    return GestureDetector(
      key: const Key('collect-drop'),
      onTap: _pickFiles,
      child: CustomPaint(
        painter: _DashedDropPainter(
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
          ),
          child: Column(
            children: [
              Text(
                '把文件拖到这里，或点击选择',
                style: TextStyle(
                  fontSize: DesignTokens.collectDropTitleFontSize,
                  fontWeight: FontWeight.w800,
                  color: palette.ink,
                  height: 1.2,
                ),
              ),
              SizedBox(height: 4 * scale),
              Text(
                '只收 PDF / JPG / PNG，不收 Word / TXT（Word 先导出成 PDF 再导入）',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: DesignTokens.bodySmallFontSize,
                  color: palette.muted,
                  height: 1.4,
                ),
              ),
              SizedBox(height: 4 * scale),
              Text(
                '单个 PDF 不超过 50MB、图片不超过 20MB，超了只提示不直接判失败 · 一份卷子会按页逐页框题 · 一次拖进来多个文件会生成多个任务排队导入，一个一个检测',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: DesignTokens.bodySmallFontSize,
                  color: palette.muted,
                  height: 1.4,
                ),
              ),
              SizedBox(height: 4 * scale),
              Text(
                '拖放导入还没接好，先点「选择文件」导入',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: DesignTokens.captionFontSize,
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
    );
  }

  Widget _filterChips(double scale) {
    final filters = <(String, CollectStatus?)>[
      ('全部 ${_tasks.length}', null),
      ('导入中 ${_count(CollectStatus.importing)}', CollectStatus.importing),
      ('排队中 ${_count(CollectStatus.queued)}', CollectStatus.queued),
      ('待框选 ${_count(CollectStatus.needBox)}', CollectStatus.needBox),
      ('修框中 ${_count(CollectStatus.boxing)}', CollectStatus.boxing),
      (
        '待整理 ${_count(CollectStatus.pendingOrganize)}',
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

  Widget _taskRow(CollectTask task, double scale, AppPalette palette) {
    final subject = Subject.byId(task.subjectId);
    final isLast = _shownTasks.last == task;
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
                        SubjectLabel(subjectId: task.subjectId),
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
                      _taskNote(task, subject.name),
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

  String _taskNote(CollectTask task, String subjectName) {
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
      CollectStatus.failed => '${task.fileName} · $subjectName · $pagePart',
      CollectStatus.done => '${task.fileName} · $subjectName · $pagePart',
    };
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
      ],
      CollectStatus.boxing => [
        QmButton(
          label: '继续修框',
          variant: QmButtonVariant.plain,
          size: small,
          onPressed: () => _openBoxEditor(task),
        ),
        QmButton(label: '去整理', size: small, onPressed: widget.onOpenOrganize),
      ],
      CollectStatus.pendingOrganize => [
        QmButton(label: '去整理', size: small, onPressed: widget.onOpenOrganize),
      ],
      CollectStatus.failed => [
        QmButton(
          label: '删除任务',
          variant: QmButtonVariant.plain,
          size: small,
          onPressed: () => _removeTask(task),
        ),
      ],
      CollectStatus.done => const [],
    };
  }
}

/// 拖放区虚线框（HTML `.drop`：2px dashed accent 边；题内框同款画法）。
class _DashedDropPainter extends CustomPainter {
  _DashedDropPainter({
    required this.color,
    required this.radius,
    this.strokeWidth = 2,
  });

  final Color color;
  final double radius;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;
    final rect = Rect.fromLTWH(1, 1, size.width - 2, size.height - 2);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    // 沿路径画虚线：8px 实线 + 6px 间隔。
    final metrics = path.computeMetrics().first;
    var distance = 0.0;
    while (distance < metrics.length) {
      final segment = metrics.extractPath(distance, distance + 8);
      canvas.drawPath(segment, paint);
      distance += 14;
    }
  }

  @override
  bool shouldRepaint(_DashedDropPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.radius != radius ||
      oldDelegate.strokeWidth != strokeWidth;
}

/// 修框编辑器（覆盖式浮层）：页缩略图条 + 画布；两级框（题级框 +
/// stem / option / figure 内框）。
///
/// HTML 来源：`frameEditorHTML` / `frameHandlesHTML`（交互原型实读）。
/// - 空白处拖动直接画新框，画完在框旁菜单选类型（默认题级框）；
/// - 双击题级框进内框模式（题级框冻结，只改题内框；点画布空白处或
///   按 Esc 退出）；题级框右上角圆柄拖动旋转；
/// - 「旋转整页」每次 90°（框的百分比坐标跟着转）；
/// - 框按页面百分比存、只能在图内（画 / 拖 / 缩放都钳制）；
/// - 没有框偏提示：自己看图拖边改；两道题的框重叠时确认被拦下；
/// - 取消中途退出 → 任务留“修框中”（由调用方保持状态，本对话框
///   只返回 null）；确认按框数拆分（返回各页的题级框，调用方替换原任务）。
/// - 切页不丢框：每页的框都留着，切回来还在，确认后才一起提交。
///
/// 已知取舍：题级框圆柄旋转是编辑器内的视觉旋转（`Transform.rotate`，
/// 不是 `Transform.scale`）；`QuestionBox` 模型没有旋转字段、框也不
/// 落库（当前架构里框只决定拆分题数与标题），所以圆柄旋转不改变
/// 返回的百分比坐标；「旋转整页」则真实变换百分比坐标。
class _BoxEditorDialog extends StatefulWidget {
  const _BoxEditorDialog({
    required this.fileName,
    required this.page,
    required this.pageCount,
    required this.subjectName,
    required this.initialBoxes,
  });

  final String fileName;
  final int page;
  final int pageCount;
  final String subjectName;
  final List<QuestionBox> initialBoxes;

  @override
  State<_BoxEditorDialog> createState() => _BoxEditorDialogState();
}

class _BoxEditorDialogState extends State<_BoxEditorDialog> {
  late Map<int, List<QuestionBox>> _boxesByPage;
  final Map<String, List<QuestionBox>> _inners = {};
  final Map<int, List<QuestionBox>> _standaloneInner = {};
  final Map<String, double> _rotations = {};
  late int _currentPage;
  final _donePages = <int>{};
  int _pageRotation = 0;
  double _scale = 1.0;
  bool _scrollLocked = false;
  bool _suppressDraw = false;

  /// 安全钳制：`YoloOnnxService.clampToPage` 要求宽/高至少 0.08，
  /// 框贴到右/下边时（`1.0 - x < 0.08`）它会抛 ArgumentError；
  /// 这里先把左上角收到 0.92 以内再钳制（YOLO 服务本身不动）。
  static QuestionBox _clampBoxSafe(QuestionBox box) {
    final safe = QuestionBox(
      id: box.id,
      layer: box.layer,
      type: box.type,
      // 0.90 而不是 0.92：1.0 - 0.92 的浮点值是 0.07999… < 0.08，
      // 仍会在 clampToPage 里抛 ArgumentError。
      x: box.x.clamp(0.0, 0.90),
      y: box.y.clamp(0.0, 0.90),
      w: box.w,
      h: box.h,
    );
    return YoloOnnxService.clampToPage(safe);
  }

  String? _selectedId;
  String? _selectedInnerId;
  String? _innerModeBoxId;
  QuestionBox? _pendingBox;
  Offset? _pendingStart;
  bool _pendingInner = false;
  bool _helpOpen = false;
  final _focusNode = FocusNode();
  final _canvasKey = GlobalKey();

  List<QuestionBox> get _boxes =>
      _boxesByPage[_currentPage] ?? const <QuestionBox>[];

  List<QuestionBox> _innersOf(String boxId) =>
      _inners['$_currentPage:$boxId'] ?? const <QuestionBox>[];

  List<QuestionBox> get _standalone =>
      _standaloneInner[_currentPage] ?? const <QuestionBox>[];

  int get _totalLayer1 {
    var n = 0;
    for (final list in _boxesByPage.values) {
      n += list.where((b) => b.layer == 1).length;
    }
    return n;
  }

  bool get _anyOverlap {
    for (final list in _boxesByPage.values) {
      if (_hasOverlap(list.where((b) => b.layer == 1).toList())) return true;
    }
    return false;
  }

  static bool _hasOverlap(List<QuestionBox> boxes) {
    for (var i = 0; i < boxes.length; i++) {
      for (var j = i + 1; j < boxes.length; j++) {
        final a = boxes[i];
        final b = boxes[j];
        final overlapX = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x);
        final overlapY = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y);
        if (overlapX > 0.001 && overlapY > 0.001) return true;
      }
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _currentPage = widget.page;
    _boxesByPage = {
      widget.page: widget.initialBoxes.map((b) => _clampBoxSafe(b)).toList(),
    };
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _exitInnerMode() {
    if (_innerModeBoxId != null) {
      setState(() {
        _innerModeBoxId = null;
        _selectedInnerId = null;
      });
    }
  }

  void _enterInnerMode(String boxId) {
    _inners.putIfAbsent('$_currentPage:$boxId', () {
      final outer = _boxes.firstWhere((b) => b.id == boxId);
      return [
        QuestionBox(
          id: '$boxId-stem',
          layer: 2,
          type: 'stem',
          x: outer.x + 0.02,
          y: outer.y + 0.02,
          w: outer.w - 0.04,
          h: (outer.h - 0.06) * 0.5,
        ),
        QuestionBox(
          id: '$boxId-option',
          layer: 2,
          type: 'option',
          x: outer.x + 0.02,
          y: outer.y + 0.02 + (outer.h - 0.06) * 0.52,
          w: outer.w - 0.04,
          h: (outer.h - 0.06) * 0.22,
        ),
        QuestionBox(
          id: '$boxId-figure',
          layer: 2,
          type: 'figure',
          x: outer.x + 0.02,
          y: outer.y + 0.02 + (outer.h - 0.06) * 0.76,
          w: outer.w - 0.04,
          h: (outer.h - 0.06) * 0.22,
        ),
      ];
    });
    setState(() {
      _innerModeBoxId = boxId;
      _selectedId = boxId;
      _selectedInnerId = null;
      _pendingBox = null;
    });
  }

  void _switchPage(int page) {
    if (page == _currentPage) return;
    setState(() {
      _currentPage = page;
      _selectedId = null;
      _selectedInnerId = null;
      _innerModeBoxId = null;
      _pendingBox = null;
      _pendingStart = null;
    });
  }

  Future<void> _restoreAutoBoxes() async {
    final boxes = await YoloOnnxService().detectPage(
      imagePath: widget.fileName,
      page: _currentPage,
    );
    if (!mounted) return;
    setState(() {
      final oldIds = _boxes.map((b) => b.id).toSet();
      for (final id in oldIds) {
        _inners.remove('$_currentPage:$id');
        _rotations.remove(id);
      }
      _boxesByPage[_currentPage] = boxes.map((b) => _clampBoxSafe(b)).toList();
      _standaloneInner.remove(_currentPage);
      _selectedId = null;
      _selectedInnerId = null;
      _innerModeBoxId = null;
      _pendingBox = null;
    });
  }

  void _rotatePage() {
    setState(() {
      _pageRotation = (_pageRotation + 90) % 360;
      QuestionBox turn(QuestionBox b) => QuestionBox(
        id: b.id,
        layer: b.layer,
        type: b.type,
        x: 1 - b.y - b.h,
        y: b.x,
        w: b.h,
        h: b.w,
      );
      _boxesByPage[_currentPage] = _boxes.map(turn).toList();
      for (final key
          in _inners.keys
              .where((k) => k.startsWith('$_currentPage:'))
              .toList()) {
        _inners[key] = _inners[key]!.map(turn).toList();
      }
      if (_standaloneInner.containsKey(_currentPage)) {
        _standaloneInner[_currentPage] = _standaloneInner[_currentPage]!
            .map(turn)
            .toList();
      }
      if (_pendingBox != null) _pendingBox = turn(_pendingBox!);
      for (final id in _rotations.keys.toList()) {
        _rotations[id] = (_rotations[id]! + 90) % 360;
      }
    });
  }

  void _deleteSelected() {
    setState(() {
      if (_selectedInnerId != null && _innerModeBoxId != null) {
        final key = '$_currentPage:$_innerModeBoxId';
        _inners[key] = (_inners[key] ?? const <QuestionBox>[])
            .where((b) => b.id != _selectedInnerId)
            .toList();
        _selectedInnerId = null;
      } else if (_selectedInnerId != null) {
        _standaloneInner[_currentPage] = _standalone
            .where((b) => b.id != _selectedInnerId)
            .toList();
        _selectedInnerId = null;
      } else if (_selectedId != null) {
        final id = _selectedId!;
        _boxesByPage[_currentPage] = _boxes.where((b) => b.id != id).toList();
        _inners.remove('$_currentPage:$id');
        _rotations.remove(id);
        if (_innerModeBoxId == id) _innerModeBoxId = null;
        _selectedId = null;
      }
      _pendingBox = null;
    });
  }

  QuestionBox _clampInner(QuestionBox box, QuestionBox outer) {
    final x = box.x.clamp(outer.x, outer.x + outer.w - 0.02);
    final y = box.y.clamp(outer.y, outer.y + outer.h - 0.02);
    final w = box.w.clamp(0.02, outer.x + outer.w - x);
    final h = box.h.clamp(0.02, outer.y + outer.h - y);
    return QuestionBox(
      id: box.id,
      layer: box.layer,
      type: box.type,
      x: x,
      y: y,
      w: w,
      h: h,
    );
  }

  void _replaceBox(QuestionBox updated) {
    setState(() {
      if (updated.layer == 1) {
        final list = _boxesByPage[_currentPage]!;
        final i = list.indexWhere((b) => b.id == updated.id);
        if (i >= 0) list[i] = _clampBoxSafe(updated);
      } else if (_innerModeBoxId != null) {
        final key = '$_currentPage:$_innerModeBoxId';
        final list = _inners[key]!;
        final i = list.indexWhere((b) => b.id == updated.id);
        if (i >= 0) {
          final outer = _boxes.firstWhere((b) => b.id == _innerModeBoxId);
          list[i] = _clampInner(updated, outer);
        }
      } else {
        final list = _standaloneInner[_currentPage] ?? const <QuestionBox>[];
        final i = list.indexWhere((b) => b.id == updated.id);
        if (i >= 0) {
          _standaloneInner[_currentPage] = List.of(list)
            ..[i] = _clampBoxSafe(updated);
        }
      }
    });
  }

  void _moveBox(QuestionBox box, double dx, double dy, double pw, double ph) {
    _replaceBox(box.movedBy(dx / pw, dy / ph));
  }

  void _resizeBox(
    QuestionBox box,
    double dx,
    double dy,
    String corner,
    double pw,
    double ph,
  ) {
    final fx = dx / pw;
    final fy = dy / ph;
    var x = box.x;
    var y = box.y;
    var w = box.w;
    var h = box.h;
    switch (corner) {
      case 'se':
        w += fx;
        h += fy;
      case 'sw':
        x += fx;
        w -= fx;
        h += fy;
      case 'ne':
        w += fx;
        y += fy;
        h -= fy;
      case 'nw':
        x += fx;
        y += fy;
        w -= fx;
        h -= fy;
    }
    _replaceBox(
      QuestionBox(
        id: box.id,
        layer: box.layer,
        type: box.type,
        x: x,
        y: y,
        w: w,
        h: h,
      ),
    );
  }

  void _rotateBoxFromGlobal(
    QuestionBox box,
    Offset global,
    double pw,
    double ph,
  ) {
    final renderBox =
        _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final local = renderBox.globalToLocal(global);
    final center = Offset((box.x + box.w / 2) * pw, (box.y + box.h / 2) * ph);
    final angle =
        math.atan2(local.dy - center.dy, local.dx - center.dx) * 180 / math.pi;
    setState(() => _rotations[box.id] = (angle + 45) % 360);
  }

  void _confirmPendingType(String type) {
    final pending = _pendingBox;
    if (pending == null) return;
    setState(() {
      if (type == 'question') {
        final box = QuestionBox(
          id: pending.id,
          layer: 1,
          type: 'question',
          x: pending.x,
          y: pending.y,
          w: pending.w,
          h: pending.h,
        );
        _boxesByPage[_currentPage] = [..._boxes, _clampBoxSafe(box)];
        _selectedId = box.id;
        _selectedInnerId = null;
      } else {
        final box = QuestionBox(
          id: pending.id,
          layer: 2,
          type: type,
          x: pending.x,
          y: pending.y,
          w: pending.w,
          h: pending.h,
        );
        if (_innerModeBoxId != null) {
          final key = '$_currentPage:$_innerModeBoxId';
          final outer = _boxes.firstWhere((b) => b.id == _innerModeBoxId);
          _inners[key] = [
            ...(_inners[key] ?? const <QuestionBox>[]),
            _clampInner(box, outer),
          ];
          _selectedInnerId = box.id;
        } else {
          // 落在某个题级框内：挂到该题的题内框；否则先作为独立题内框
          // 画在页上（确认拆分时只按题级框计数）。
          QuestionBox? parent;
          for (final b in _boxes) {
            final cx = pending.x + pending.w / 2;
            final cy = pending.y + pending.h / 2;
            if (cx >= b.x && cx <= b.x + b.w && cy >= b.y && cy <= b.y + b.h) {
              parent = b;
            }
          }
          if (parent != null) {
            final key = '$_currentPage:${parent.id}';
            _inners[key] = [
              ...(_inners[key] ?? const <QuestionBox>[]),
              _clampInner(box, parent),
            ];
          } else {
            _standaloneInner[_currentPage] = [
              ..._standalone,
              _clampBoxSafe(box),
            ];
          }
          _selectedInnerId = box.id;
        }
      }
      _pendingBox = null;
      _pendingStart = null;
    });
  }

  bool _pointInBox(Offset p, QuestionBox b, double pw, double ph) =>
      p.dx >= b.x * pw &&
      p.dx <= (b.x + b.w) * pw &&
      p.dy >= b.y * ph &&
      p.dy <= (b.y + b.h) * ph;

  Offset? _canvasLocal(Offset global) {
    final renderBox =
        _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return null;
    return renderBox.globalToLocal(global);
  }

  void _onDrawStart(Offset pos, double pw, double ph) {
    // 正在拖旋转/缩放柄时不画框（柄在框外，按下会同时命中画布层）。
    if (_suppressDraw) return;
    if (_innerModeBoxId != null) {
      final outer = _boxes.firstWhere((b) => b.id == _innerModeBoxId);
      if (!_pointInBox(pos, outer, pw, ph)) {
        // 内框模式下点题级框外的空白：退出内框模式，不画框。
        _exitInnerMode();
        return;
      }
      if (_innersOf(_innerModeBoxId!).any((b) => _pointInBox(pos, b, pw, ph))) {
        return;
      }
      _pendingInner = true;
    } else {
      if (_boxes.any((b) => _pointInBox(pos, b, pw, ph))) return;
      if (_standalone.any((b) => _pointInBox(pos, b, pw, ph))) return;
      _pendingInner = false;
    }
    setState(() {
      _pendingStart = Offset(
        (pos.dx / pw).clamp(0.0, 1.0),
        (pos.dy / ph).clamp(0.0, 1.0),
      );
      _pendingBox = QuestionBox(
        id: 'box-${DateTime.now().millisecondsSinceEpoch}',
        layer: _pendingInner ? 2 : 1,
        type: 'question',
        x: _pendingStart!.dx,
        y: _pendingStart!.dy,
        w: 0.01,
        h: 0.01,
      );
      _selectedId = null;
      _selectedInnerId = null;
    });
  }

  void _onDrawUpdate(Offset local, double pw, double ph) {
    final start = _pendingStart;
    final pending = _pendingBox;
    if (start == null || pending == null) return;
    var end = Offset(
      (local.dx / pw).clamp(0.0, 1.0),
      (local.dy / ph).clamp(0.0, 1.0),
    );
    if (_innerModeBoxId != null) {
      final outer = _boxes.firstWhere((b) => b.id == _innerModeBoxId);
      end = Offset(
        end.dx.clamp(outer.x, outer.x + outer.w),
        end.dy.clamp(outer.y, outer.y + outer.h),
      );
    }
    setState(() {
      _pendingBox = QuestionBox(
        id: pending.id,
        layer: pending.layer,
        type: pending.type,
        x: math.min(start.dx, end.dx),
        y: math.min(start.dy, end.dy),
        w: (start.dx - end.dx).abs().clamp(0.01, 1.0),
        h: (start.dy - end.dy).abs().clamp(0.01, 1.0),
      );
    });
  }

  void _onDrawEnd(double pw, double ph) {
    final pending = _pendingBox;
    if (pending == null) return;
    // 只点了 一下、没拖出框：当作空白点击（内框模式下退出内框模式）。
    if (pending.w < 0.02 || pending.h < 0.02) {
      setState(() {
        _pendingBox = null;
        _pendingStart = null;
      });
      if (_innerModeBoxId != null) _exitInnerMode();
      return;
    }
    if (_innerModeBoxId != null) {
      final outer = _boxes.firstWhere((b) => b.id == _innerModeBoxId);
      setState(() => _pendingBox = _clampInner(pending, outer));
    } else {
      setState(() => _pendingBox = _clampBoxSafe(pending));
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    final size = MediaQuery.of(context).size;
    final dialogWidth = math.min(
      DesignTokens.collectEditorDialogWidth * scale,
      size.width - 48,
    );
    final dialogHeight = math.min(
      DesignTokens.collectEditorDialogHeight * scale,
      size.height - 48,
    );
    final total = _totalLayer1;
    final overlap = _anyOverlap;
    final confirmEnabled = total > 0 && !overlap && _pendingBox == null;
    final confirmLabel = total > 1 ? '确认修框，拆成 $total 个待整理任务' : '确认修框，去整理';
    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _exitInnerMode();
        }
      },
      child: Dialog(
        insetPadding: const EdgeInsets.all(24),
        backgroundColor: palette.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            DesignTokens.scaled(scale).radiusLg,
          ),
        ),
        child: SizedBox(
          width: dialogWidth,
          height: dialogHeight,
          child: Padding(
            padding: EdgeInsets.all(16 * scale),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '修框 · ${widget.fileName} 第$_currentPage页 · 本页 ${_boxes.length} 道题',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: palette.ink,
                          height: 1.2,
                        ),
                      ),
                    ),
                    Flexible(
                      child: Text(
                        '学科：${widget.subjectName}（导入时已选定，这里不能改）',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: DesignTokens.captionFontSize,
                          color: palette.muted,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 6 * scale),
                QmFoldSection(
                  title: '操作说明',
                  variant: QmFoldVariant.detail,
                  expanded: _helpOpen,
                  onToggle: () => setState(() => _helpOpen = !_helpOpen),
                  child: Text(
                    '点一下选题级框 · 双击题级框进入内框模式改题内框 · 拖框移动 · 拖边/角缩放 · 拖右上角圆柄旋转 · 改乱了点「恢复自动框」回到 YOLO 原框 · 「旋转整页」把整页图片转 90°（框跟着转） · 框的边界按本页图片的实际大小算：图片有多大，画框就多大，拖动 / 缩放 / 新画框都不能超出这张图；题内框只在它所属的题级框内部 · 切页不丢框：每页的框都留着，切回来还在，点「确认修框」才一起提交 · 两道题的框重叠时确认会被拦下，先调开再确认 · 滚轮缩放 · 确认只点下方「确认修框」按钮',
                    style: TextStyle(
                      fontSize: DesignTokens.bodySmallFontSize,
                      color: palette.ink2,
                      height: DesignTokens.bodyLineHeight,
                    ),
                  ),
                ),
                if (_innerModeBoxId != null)
                  QmBanner(
                    tone: QmBannerTone.info,
                    title: '内框模式',
                    message:
                        '已进入题级框 ${_boxes.indexWhere((b) => b.id == _innerModeBoxId) + 1}：鼠标只选它里面的题干 / 选项 / 配图框，拖动、缩放都只改题内框，题级框已冻结不动 · 点画布空白处或按 Esc 退出内框模式',
                    actions: [
                      QmBannerAction(
                        label: '退出内框模式',
                        onPressed: _exitInnerMode,
                      ),
                    ],
                  ),
                if (_boxes.isEmpty)
                  const QmBanner(
                    tone: QmBannerTone.warning,
                    title: '没框到题',
                    message:
                        '没框到题，请用鼠标拖一个框：在画布空白处按住拖出一个框，画完在框旁选「题级框」就能继续，不用重新导入',
                  ),
                if (overlap)
                  const QmBanner(
                    tone: QmBannerTone.error,
                    title: '框重叠',
                    message: '有框重叠了，请调开再确认：本页有两道题的框叠在一起，把它们拖开（或缩放错开）后才能确认修框。',
                  ),
                SizedBox(height: 8 * scale),
                _toolbar(scale, palette),
                SizedBox(height: 8 * scale),
                // 画布按页完整显示（HTML 原型：画布完整显示一页题）：
                // 页按 560×700 的比例 fit 进可用区，滚轮缩放再乘 _scale；
                // 框按页面百分比存，fit 不改任何框坐标。
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final fit = math.min(
                        constraints.maxWidth /
                            DesignTokens.collectEditorCanvasWidth,
                        constraints.maxHeight /
                            DesignTokens.collectEditorCanvasHeight,
                      );
                      final fpw =
                          DesignTokens.collectEditorCanvasWidth * fit * _scale;
                      final fph =
                          DesignTokens.collectEditorCanvasHeight * fit * _scale;
                      return _canvas(
                        fpw,
                        fph,
                        scale,
                        palette,
                        constraints.maxWidth,
                        constraints.maxHeight,
                      );
                    },
                  ),
                ),
                SizedBox(height: 8 * scale),
                _foot(scale, palette, confirmEnabled, confirmLabel),
                SizedBox(height: 8 * scale),
                _thumbStrip(scale, palette),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar(double scale, AppPalette palette) {
    final hasSelection = _selectedId != null || _selectedInnerId != null;
    return Row(
      children: [
        Expanded(
          child: Text(
            _innerModeBoxId != null
                ? '内框模式：点题内框拖动 / 缩放；题内空白处拖动可画新框（只在这道题的框内），画完选类型'
                : '新增框（先画后选）：在图片内空白处拖出框，拖出图片也会夹回图内，画完选类型，默认题级框',
            style: TextStyle(
              fontSize: DesignTokens.bodySmallFontSize,
              color: palette.ink2,
              height: 1.4,
            ),
          ),
        ),
        SizedBox(width: 8 * scale),
        QmButton(
          label: '删除选中框',
          variant: QmButtonVariant.plain,
          size: QmButtonSize.small,
          onPressed: hasSelection && _pendingBox == null
              ? _deleteSelected
              : null,
        ),
        SizedBox(width: 6 * scale),
        QmButton(
          label: '旋转整页',
          variant: QmButtonVariant.plain,
          size: QmButtonSize.small,
          onPressed: _rotatePage,
        ),
        SizedBox(width: 6 * scale),
        QmButton(
          label: '恢复自动框',
          variant: QmButtonVariant.plain,
          size: QmButtonSize.small,
          onPressed: _restoreAutoBoxes,
        ),
        SizedBox(width: 8 * scale),
        Text(
          '${(_scale * 100).round()}%',
          style: TextStyle(
            fontSize: DesignTokens.captionFontSize,
            color: palette.muted,
          ),
        ),
        SizedBox(width: 6 * scale),
        QmButton(
          label: '重置视图',
          variant: QmButtonVariant.plain,
          size: QmButtonSize.small,
          onPressed: () => setState(() => _scale = 1.0),
        ),
      ],
    );
  }

  Widget _canvas(
    double pw,
    double ph,
    double scale,
    AppPalette palette,
    double viewW,
    double viewH,
  ) {
    // 指针按下画布即锁住滚动：画框 / 拖框的手势不再与滚动视图竞争；
    // 抬起后恢复滚动。锁在 pointer-down 时（手势竞技场裁决前）生效，
    // 所以框的 GestureDetector 能正常拿到拖动事件。
    return Listener(
      key: const Key('box-editor-canvas'),
      onPointerDown: (event) {
        final renderBox =
            _canvasKey.currentContext?.findRenderObject() as RenderBox?;
        if (renderBox == null) return;
        final local = renderBox.globalToLocal(event.position);
        if (local.dx >= 0 &&
            local.dx <= pw &&
            local.dy >= 0 &&
            local.dy <= ph) {
          setState(() => _scrollLocked = true);
        }
      },
      onPointerUp: (_) {
        if (_scrollLocked) setState(() => _scrollLocked = false);
      },
      onPointerCancel: (_) {
        if (_scrollLocked) setState(() => _scrollLocked = false);
      },
      child: Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            setState(() {
              _scale = (_scale - event.scrollDelta.dy / 1200).clamp(0.5, 3.0);
            });
          }
        },
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: _scrollLocked ? const NeverScrollableScrollPhysics() : null,
          child: SingleChildScrollView(
            physics: _scrollLocked
                ? const NeverScrollableScrollPhysics()
                : null,
            // 页比视口小时居中显示（HTML 原型：画布居中放整页）；
            // 放大超过视口时按页尺寸滚动。
            child: SizedBox(
              width: math.max(pw, viewW),
              height: math.max(ph, viewH),
              child: Align(
                alignment: Alignment.center,
                child: SizedBox(
                  width: pw,
                  height: ph,
                  child: Stack(
                    key: _canvasKey,
                    children: [
                      Container(
                        width: pw,
                        height: ph,
                        decoration: BoxDecoration(
                          color: palette.paper,
                          border: Border.all(color: palette.paperLine),
                          borderRadius: BorderRadius.circular(
                            DesignTokens.scaled(scale).radius,
                          ),
                        ),
                        // 占位页图说明放页底留白处：题级框一般只到页高 0.90，
                        // 放中央会被框盖住、文字和框边重叠。
                        // 内框模式下不显示：冻结标签贴在题级框底边，
                        // 会和页底这两行说明重叠；横幅已说明内框模式上下文。
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_innerModeBoxId == null)
                                  Text(
                                    '页面预览',
                                    style: TextStyle(
                                      fontFamily: DesignTokens.serifFontFamily,
                                      fontFamilyFallback:
                                          DesignTokens.serifFontFamilyFallback,
                                      fontSize: DesignTokens.bodySmallFontSize,
                                      color: palette.paperInk,
                                    ),
                                  ),
                                if (_pageRotation != 0)
                                  Text(
                                    '整页已旋转 $_pageRotation°（图片和框一起转的）',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: palette.paperInk,
                                    ),
                                  ),
                                if (_innerModeBoxId == null)
                                  Text(
                                    '框按页面百分比存，框只能在这张图里面',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: palette.paperInk,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // 画框层在最下：原始指针事件画框（不走手势竞技场，
                      // 不会被滚动视图抢走；点在框上由框自己的手势处理，
                      // _onDrawStart 里按坐标判断是否在框内）。
                      // 内框模式下点空白处（或右键）退出内框模式。
                      Positioned.fill(
                        child: Listener(
                          behavior: HitTestBehavior.opaque,
                          onPointerDown: (event) {
                            if (_innerModeBoxId != null &&
                                event.buttons == kSecondaryMouseButton) {
                              _exitInnerMode();
                              return;
                            }
                            if (event.buttons != kPrimaryMouseButton) return;
                            final local = _canvasLocal(event.position);
                            if (local != null) _onDrawStart(local, pw, ph);
                          },
                          onPointerMove: (event) {
                            final local = _canvasLocal(event.position);
                            if (local != null) _onDrawUpdate(local, pw, ph);
                          },
                          onPointerUp: (_) => _onDrawEnd(pw, ph),
                          onPointerCancel: (_) => _onDrawEnd(pw, ph),
                          child: const SizedBox.expand(),
                        ),
                      ),
                      if (_innerModeBoxId == null) ...[
                        for (final box in _boxes)
                          _boxView(box, pw, ph, scale, palette),
                        for (final box in _standalone)
                          _boxView(box, pw, ph, scale, palette),
                      ] else ...[
                        for (final box in _boxes)
                          _frozenBoxView(box, pw, ph, scale, palette),
                        for (final box in _innersOf(_innerModeBoxId!))
                          _boxView(box, pw, ph, scale, palette),
                      ],
                      if (_pendingBox != null)
                        _pendingBoxView(_pendingBox!, pw, ph, scale, palette),
                      if (_pendingBox != null)
                        _typeMenu(_pendingBox!, pw, ph, scale, palette),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _foot(
    double scale,
    AppPalette palette,
    bool confirmEnabled,
    String confirmLabel,
  ) {
    final hint = _pendingBox != null
        ? '已画好一个新框：在框旁菜单点一下选类型（默认题级框），点中即生成；点 × 放弃这个框'
        : _innerModeBoxId != null
        ? '内框模式：正在改题级框 ${_boxes.indexWhere((b) => b.id == _innerModeBoxId) + 1} 内的题内框 · 题级框不动 · 点画布空白处或按 Esc 退出内框模式'
        : _selectedId != null
        ? '当前选中：题级框 ${_boxes.indexWhere((b) => b.id == _selectedId) + 1} · 双击它进入内框模式改题内框 · 拖右上角圆柄可旋转 · 在空白处拖动可直接再画一个新框，画完再选类型'
        : _boxes.isEmpty
        ? '没框到题，请用鼠标拖一个框：在空白处拖出框，画完在框旁选「题级框」就能继续'
        : '本页已框 ${_boxes.length} 道题 · 点框可选中拖动 / 缩放 · 双击题级框进内框模式改题内框 · 空白处拖动可再画新框';
    return Row(
      children: [
        Expanded(
          child: Text(
            hint,
            style: TextStyle(
              fontSize: DesignTokens.captionFontSize,
              color: palette.muted,
              height: 1.4,
            ),
          ),
        ),
        SizedBox(width: 8 * scale),
        QmButton(
          label: '取消',
          variant: QmButtonVariant.plain,
          size: QmButtonSize.small,
          onPressed: () => Navigator.of(context).pop(),
        ),
        SizedBox(width: 8 * scale),
        QmButton(
          label: confirmLabel,
          size: QmButtonSize.small,
          onPressed: confirmEnabled
              ? () => Navigator.of(context).pop(_boxesByPage)
              : null,
        ),
      ],
    );
  }

  Widget _thumbStrip(double scale, AppPalette palette) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(top: 10 * scale),
                child: Text(
                  '页面',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: palette.muted,
                  ),
                ),
              ),
              SizedBox(width: 8 * scale),
              for (var p = 1; p <= widget.pageCount; p++)
                Padding(
                  padding: EdgeInsets.only(right: 8 * scale),
                  child: GestureDetector(
                    key: Key('editor-thumb-$p'),
                    onTap: () => _switchPage(p),
                    child: Column(
                      children: [
                        Container(
                          width: DesignTokens.collectEditorThumbWidth * scale,
                          height: DesignTokens.collectEditorThumbHeight * scale,
                          decoration: BoxDecoration(
                            color: palette.paper,
                            border: Border.all(
                              color: p == _currentPage
                                  ? palette.accent
                                  : palette.lineStrong,
                              width: p == _currentPage ? 2 : 1.5,
                            ),
                            borderRadius: BorderRadius.circular(6 * scale),
                          ),
                          child: Stack(
                            children: [
                              Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  for (var i = 0; i < 3; i++)
                                    Container(
                                      margin: EdgeInsets.symmetric(
                                        vertical: 1.5 * scale,
                                      ),
                                      height: 1.5 * scale,
                                      width: 44 * scale,
                                      color: palette.paperLine,
                                    ),
                                ],
                              ),
                              if (_donePages.contains(p))
                                Positioned(
                                  right: 2 * scale,
                                  top: 0,
                                  child: Text(
                                    '✓',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: palette.accentText,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        SizedBox(height: 3 * scale),
                        Text(
                          '第 $p 页${_donePages.contains(p) ? ' ✓' : ''}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: p == _currentPage
                                ? palette.accentText
                                : palette.ink2,
                            height: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              QmButton(
                label: _donePages.contains(_currentPage)
                    ? '本页已修完 ✓（点击取消）'
                    : '本页修完 ✓',
                variant: QmButtonVariant.plain,
                size: QmButtonSize.small,
                onPressed: () => setState(() {
                  if (_donePages.contains(_currentPage)) {
                    _donePages.remove(_currentPage);
                  } else {
                    _donePages.add(_currentPage);
                  }
                }),
              ),
            ],
          ),
        ),
        SizedBox(height: 2 * scale),
        Text(
          '每张缩略图下面是页码，点哪页修哪页，修完那页打勾 · 切页不丢框：每页没确认的框都留着，切回来还在，确认后才一起提交',
          style: TextStyle(fontSize: 11.5, color: palette.muted, height: 1.4),
        ),
      ],
    );
  }

  Color _regionColor(String type, AppPalette palette) => switch (type) {
    'stem' => palette.stem,
    'option' => palette.option,
    'figure' => palette.figure,
    _ => palette.accent,
  };

  String _regionLabel(String type) => switch (type) {
    'stem' => 'stem 题干',
    'option' => 'option 选项',
    'figure' => 'figure 配图',
    _ => type,
  };

  Widget _boxView(
    QuestionBox box,
    double pw,
    double ph,
    double scale,
    AppPalette palette,
  ) {
    final isInner = box.layer == 2;
    final selected = isInner
        ? _selectedInnerId == box.id
        : _selectedId == box.id;
    final borderColor = selected
        ? palette.accent
        : isInner
        ? _regionColor(box.type, palette)
        : palette.lineStrong;
    final label = isInner
        ? _regionLabel(box.type)
        : '题级框 ${_boxes.indexWhere((b) => b.id == box.id) + 1}'
              '${selected && _innerModeBoxId == null ? ' · 已选中' : ''}';
    return Positioned(
      left: box.x * pw,
      top: box.y * ph,
      width: box.w * pw,
      height: box.h * ph,
      child: Transform.rotate(
        angle: ((_rotations[box.id] ?? 0) * math.pi / 180),
        child: GestureDetector(
          key: Key('editor-box-${box.id}'),
          onTap: () => setState(() {
            if (isInner) {
              _selectedInnerId = box.id;
            } else {
              _selectedId = box.id;
              _selectedInnerId = null;
            }
          }),
          onDoubleTap: !isInner && _innerModeBoxId == null
              ? () => _enterInnerMode(box.id)
              : null,
          onPanUpdate: (details) =>
              _moveBox(box, details.delta.dx, details.delta.dy, pw, ph),
          child: _boxBody(
            box,
            pw,
            ph,
            scale,
            palette,
            selected,
            borderColor,
            label,
          ),
        ),
      ),
    );
  }

  /// 框体：题级框实线边；题内框虚线边（HTML `.inner-region`：
  /// `1.5px dashed` 区域色），用虚线画笔实现。
  Widget _boxBody(
    QuestionBox box,
    double pw,
    double ph,
    double scale,
    AppPalette palette,
    bool selected,
    Color borderColor,
    String label,
  ) {
    final isInner = box.layer == 2;
    final body = Container(
      decoration: BoxDecoration(
        color: selected
            ? palette.accent.withValues(alpha: 0.07)
            : palette.accent.withValues(alpha: 0.02),
        border: isInner
            ? null
            : Border.all(color: borderColor, width: selected ? 2.5 : 2.5),
        borderRadius: BorderRadius.circular(isInner ? 4 : 8),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: 2,
            left: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
              decoration: BoxDecoration(
                color: palette.paper,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: isInner ? 9.5 : 10.5,
                  fontWeight: FontWeight.w700,
                  color: selected ? palette.accentText : palette.muted,
                ),
              ),
            ),
          ),
          // 题级框内的题内框（非内框模式下只作展示，不可单独拖动）。
          if (!isInner && _innerModeBoxId == null)
            for (final region in _innersOf(box.id))
              Positioned(
                left: (region.x - box.x) * pw,
                top: (region.y - box.y) * ph,
                width: region.w * pw,
                height: region.h * ph,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _regionColor(region.type, palette),
                      width: 1.5,
                      style: BorderStyle.solid,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4, top: 1),
                      child: Text(
                        _regionLabel(region.type),
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          color: _regionColor(region.type, palette),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          // 选中框的四角缩放柄 +（题级框）右上角旋转圆柄。
          if (selected) ...[
            for (final corner in ['nw', 'ne', 'sw', 'se'])
              _resizeHandle(box, corner, pw, ph, scale, palette),
            if (!isInner && _innerModeBoxId == null)
              Positioned(
                top: -28 * scale,
                right: -11 * scale,
                child: GestureDetector(
                  key: Key('editor-rotate-${box.id}'),
                  onPanDown: (_) => _suppressDraw = true,
                  onPanEnd: (_) => _suppressDraw = false,
                  onPanCancel: () => _suppressDraw = false,
                  onPanUpdate: (details) =>
                      _rotateBoxFromGlobal(box, details.globalPosition, pw, ph),
                  child: Container(
                    width: 22 * scale,
                    height: 22 * scale,
                    decoration: BoxDecoration(
                      color: palette.accent,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '↻',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: palette.accentInk,
                        height: 1,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
    if (isInner) {
      return CustomPaint(
        foregroundPainter: _DashedDropPainter(
          color: borderColor,
          radius: 4,
          strokeWidth: 1.5,
        ),
        child: body,
      );
    }
    return body;
  }

  Widget _resizeHandle(
    QuestionBox box,
    String corner,
    double pw,
    double ph,
    double scale,
    AppPalette palette,
  ) {
    final size = 13 * scale;
    final offset = -6.5 * scale;
    final (
      double? left,
      double? top,
      double? right,
      double? bottom,
    ) = switch (corner) {
      'nw' => (offset, offset, null, null),
      'ne' => (null, offset, offset, null),
      'sw' => (offset, null, null, offset),
      'se' => (null, null, offset, offset),
      _ => (null, null, null, null),
    };
    return Positioned(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      child: GestureDetector(
        key: Key('editor-resize-$corner-${box.id}'),
        onPanDown: (_) => _suppressDraw = true,
        onPanEnd: (_) => _suppressDraw = false,
        onPanCancel: () => _suppressDraw = false,
        onPanUpdate: (details) =>
            _resizeBox(box, details.delta.dx, details.delta.dy, corner, pw, ph),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: palette.surface,
            border: Border.all(color: palette.accent, width: 2),
            borderRadius: BorderRadius.circular(3 * scale),
          ),
        ),
      ),
    );
  }

  Widget _frozenBoxView(
    QuestionBox box,
    double pw,
    double ph,
    double scale,
    AppPalette palette,
  ) {
    return Positioned(
      left: box.x * pw,
      top: box.y * ph,
      width: box.w * pw,
      height: box.h * ph,
      child: Opacity(
        opacity: 0.45,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: palette.lineStrong, width: 2.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Stack(
            children: [
              Positioned(
                bottom: 2,
                left: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 0,
                  ),
                  decoration: BoxDecoration(
                    color: palette.paper,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    '题级框 ${_boxes.indexWhere((b) => b.id == box.id) + 1} · 内框模式 · 已冻结',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: palette.muted,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pendingBoxView(
    QuestionBox box,
    double pw,
    double ph,
    double scale,
    AppPalette palette,
  ) {
    return Positioned(
      left: box.x * pw,
      top: box.y * ph,
      width: box.w * pw,
      height: box.h * ph,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: palette.accent,
            width: 2,
            style: BorderStyle.solid,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
            decoration: BoxDecoration(
              color: palette.paper,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              '新框 · 待选类型',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: palette.accentText,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _typeMenu(
    QuestionBox box,
    double pw,
    double ph,
    double scale,
    AppPalette palette,
  ) {
    final below = (box.y + box.h) * ph + 52 < ph;
    final top = below
        ? (box.y + box.h) * ph + 6
        : math.min(math.max(box.y * ph - 48, 0.0), math.max(ph - 48, 0.0));
    final left = math.min(box.x * pw, math.max(0.0, pw - 320));
    return Positioned(
      left: left,
      top: top,
      child: Container(
        key: const Key('pending-type-menu'),
        constraints: const BoxConstraints(maxWidth: 320),
        padding: EdgeInsets.symmetric(
          horizontal: 8 * scale,
          vertical: 6 * scale,
        ),
        decoration: BoxDecoration(
          color: palette.surface,
          border: Border.all(color: palette.lineStrong),
          borderRadius: BorderRadius.circular(
            DesignTokens.scaled(scale).radius,
          ),
          boxShadow: palette.shadow,
        ),
        child: Wrap(
          spacing: 5 * scale,
          runSpacing: 5 * scale,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '这个框是？',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: palette.muted,
              ),
            ),
            if (!_pendingInner)
              QmChip(
                key: const Key('pending-type-question'),
                label: '题级框 · 默认',
                selected: true,
                onTap: () => _confirmPendingType('question'),
              ),
            QmChip(
              key: const Key('pending-type-stem'),
              label: 'stem 题干',
              onTap: () => _confirmPendingType('stem'),
            ),
            QmChip(
              key: const Key('pending-type-option'),
              label: 'option 选项',
              onTap: () => _confirmPendingType('option'),
            ),
            QmChip(
              key: const Key('pending-type-figure'),
              label: 'figure 配图',
              onTap: () => _confirmPendingType('figure'),
            ),
            GestureDetector(
              key: const Key('pending-discard'),
              onTap: () => setState(() {
                _pendingBox = null;
                _pendingStart = null;
              }),
              child: QmGlyph(QmGlyphs.close, color: palette.muted),
            ),
          ],
        ),
      ),
    );
  }
}

extension _BoxEdit on QuestionBox {
  QuestionBox movedBy(double dx, double dy) => QuestionBox(
    id: id,
    layer: layer,
    type: type,
    x: x + dx,
    y: y + dy,
    w: w,
    h: h,
  );
}
