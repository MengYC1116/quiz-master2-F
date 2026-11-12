import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/repository.dart';
import '../../models/models.dart';
import '../../services/import_service.dart';
import '../../services/yolo_onnx_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';

/// 收集中心：选学科 → 选文件 → 任务列表 → 修框（覆盖式浮层）→ 待整理。
/// 只收 PDF / JPG / PNG；PDF 50MB、图片 20MB，超限只提示不硬拦。
/// 系统拖拽导入未实现，拖放区只写占位文案。
class CollectPage extends StatefulWidget {
  const CollectPage({
    super.key,
    required this.repo,
    required this.onOpenOrganize,
  });

  final QuestionRepository repo;
  final VoidCallback onOpenOrganize;

  /// 待框选 + 修框中任务数（左导航角标用）。
  static int countPendingBox(List<CollectTask> tasks) => tasks
      .where((t) =>
          t.status == CollectStatus.needBox ||
          t.status == CollectStatus.boxing)
      .length;

  @override
  State<CollectPage> createState() => _CollectPageState();
}

class _CollectPageState extends State<CollectPage> {
  List<CollectTask> _tasks = [];
  String? _selectedSubjectId; // 每次导入都选，默认“请选择学科”
  bool _picking = false;
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
      _snack('先选学科');
      return;
    }
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final service = ImportService(widget.repo.db);
      final paths = await service.pickFiles();
      if (paths.isEmpty) return;
      final subjectId = _selectedSubjectId!;
      final oversizeHints = <String>[];
      var duplicateFound = false;
      for (final path in paths) {
        final file = File(path);
        final name = file.uri.pathSegments.last;
        if (duplicateFound == false &&
            _tasks.any((t) => t.fileName == name)) {
          duplicateFound = true;
        }
        // 损坏文件：给出具体原因。
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
        // 超限只提示，不硬拦。
        try {
          final hint = ImportService.oversizeHint(file);
          if (hint != null) oversizeHints.add(hint);
        } catch (_) {}
        final created = await service.enqueue([path], subjectId: subjectId);
        for (final task in created) {
          _simulateImport(task);
        }
      }
      if (duplicateFound) _snack('已经导入过，仍可继续导入');
      for (final hint in oversizeHints) {
        _snack(hint);
      }
      await widget.repo.saveRecentTask(
        kind: 'collect',
        subjectId: subjectId,
        title: paths.map((p) => File(p).uri.pathSegments.last).join('、'),
      );
      await _load();
    } finally {
      if (mounted) setState(() => _picking = false);
    }
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
      String fileName, String subjectId, String error) async {
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
    _timers[task.id] = Timer.periodic(
      const Duration(milliseconds: 160),
      (timer) async {
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
      },
    );
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
    final confirmed = await showDialog<List<QuestionBox>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BoxEditorDialog(
        fileName: task.fileName,
        page: task.page,
        initialBoxes: boxes,
      ),
    );
    if (confirmed == null) {
      // 取消：回待框选。
      task.status = CollectStatus.needBox;
      await widget.repo.saveCollectTask(task);
      await _load();
      return;
    }
    // 确认修框：按框生成题目，任务变待整理。
    final ts = DateTime.now().millisecondsSinceEpoch;
    String? firstQuestionId;
    for (var i = 0; i < confirmed.length; i++) {
      final qid = 'import-$ts-$i';
      if (i == 0) firstQuestionId = qid;
      await widget.repo.save(Question(
        id: qid,
        title: '${task.fileName} · 第${task.page}页 · 第${i + 1}题',
        subjectId: task.subjectId,
        isDemo: false,
        isOrganized: false,
        createdAt: DateTime.now(),
      ));
    }
    final updated = CollectTask(
      id: task.id,
      name: task.name,
      fileName: task.fileName,
      subjectId: task.subjectId,
      status: CollectStatus.pendingOrganize,
      progress: 100,
      pageCount: task.pageCount,
      page: task.page,
      questionId: firstQuestionId ?? task.questionId,
    );
    await widget.repo.saveCollectTask(updated);
    await widget.repo.saveRecentTask(
      kind: 'collect',
      subjectId: task.subjectId,
      title: task.fileName,
    );
    await _load();
    _snack('已生成 ${confirmed.length} 道题，去整理吧');
  }

  Future<void> _deleteTask(CollectTask task) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除任务'),
        content: const Text('删了就没了，确定吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      _timers[task.id]?.cancel();
      await widget.repo.deleteCollectTask(task.id);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('收集中心',
                style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 20),
            // 导入区：学科下拉 + 选文件。
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: _selectedSubjectId,
                            decoration: const InputDecoration(
                              labelText: '学科',
                              border: OutlineInputBorder(),
                            ),
                            hint: const Text('请选择学科'),
                            items: Subject.all
                                .map((s) => DropdownMenuItem(
                                      value: s.id,
                                      child: Text(s.name),
                                    ))
                                .toList(),
                            onChanged: (v) =>
                                setState(() => _selectedSubjectId = v),
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton.icon(
                          onPressed: _picking ? null : _pickFiles,
                          icon: const Icon(Icons.upload_file_outlined),
                          label: Text(_picking ? '选择中…' : '选择文件'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '只收 PDF、JPG、PNG；PDF 50MB，图片 20MB。超限仍可导入。',
                      style: TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    // 拖放占位：系统拖拽导入未实现，不假装已实现。
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: AppTheme.lightLineStrong,
                          style: BorderStyle.solid,
                        ),
                        borderRadius:
                            BorderRadius.circular(AppTheme.radius),
                      ),
                      child: const Column(
                        children: [
                          Icon(Icons.file_upload_outlined, size: 32),
                          SizedBox(height: 8),
                          Text('把文件拖到这里'),
                          SizedBox(height: 4),
                          Text('拖放导入还没接好，先用上方按钮选文件',
                              style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                const Text('任务',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(width: 8),
                Text('${_tasks.length} 个',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 8),
            if (_tasks.isEmpty)
              const EmptyState(message: '还没有导入任务，选个文件开始吧')
            else if (_tasks.length > 3)
              // 超过 3 个任务：固定高度滚动容器。
              SizedBox(
                height: 360,
                child: ListView.builder(
                  itemCount: _tasks.length,
                  itemBuilder: (ctx, i) => _taskRow(_tasks[i]),
                ),
              )
            else
              Column(
                children: _tasks.map(_taskRow).toList(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _taskRow(CollectTask task) {
    final subject = Subject.byId(task.subjectId);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor:
                      subjectLabelColor(context, task.subjectId),
                  radius: 16,
                  child: Text(subject.icon,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 13)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(task.name,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(
                        '${task.fileName} · ${subject.name}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                InfoChip(label: task.status.label),
                if (task.status == CollectStatus.needBox ||
                    task.status == CollectStatus.boxing) ...[
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => _openBoxEditor(task),
                    child: const Text('修框'),
                  ),
                ],
                if (task.status == CollectStatus.pendingOrganize) ...[
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: widget.onOpenOrganize,
                    child: const Text('去整理'),
                  ),
                ],
                if (task.status == CollectStatus.failed) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: '删除任务',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _deleteTask(task),
                  ),
                ],
              ],
            ),
            if (task.status == CollectStatus.importing ||
                task.status == CollectStatus.queued) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: task.progress / 100),
              const SizedBox(height: 4),
              Text('导入中 ${task.progress}%',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            if (task.status == CollectStatus.failed &&
                task.error != null) ...[
              const SizedBox(height: 6),
              Text(task.error!,
                  style: const TextStyle(color: Colors.red, fontSize: 13)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 修框编辑器（覆盖式浮层）：框可拖动移 / 改大小 / 空白处重画，
/// 滚轮缩放；双击题框进内框模式（虚线框 + “内框模式”横条，
/// 只能改该题的 stem / option / figure，Esc / 空白点击 / 右键退出）。
class _BoxEditorDialog extends StatefulWidget {
  const _BoxEditorDialog({
    required this.fileName,
    required this.page,
    required this.initialBoxes,
  });

  final String fileName;
  final int page;
  final List<QuestionBox> initialBoxes;

  @override
  State<_BoxEditorDialog> createState() => _BoxEditorDialogState();
}

class _BoxEditorDialogState extends State<_BoxEditorDialog> {
  late List<QuestionBox> _boxes;
  final _innerBoxes = <String, List<QuestionBox>>{};
  double _scale = 1.0;
  String? _innerModeBoxId;
  String? _selectedId;
  QuestionBox? _drawing;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _boxes = widget.initialBoxes
        .map((b) => YoloOnnxService.clampToPage(b))
        .toList();
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
        _selectedId = null;
      });
    }
  }

  void _enterInnerMode(String boxId) {
    _innerBoxes.putIfAbsent(boxId, () {
      final outer = _boxes.firstWhere((b) => b.id == boxId);
      return [
        QuestionBox(
            id: '$boxId-stem',
            layer: 2,
            type: 'stem',
            x: outer.x + 0.02,
            y: outer.y + 0.02,
            w: outer.w - 0.04,
            h: (outer.h - 0.06) * 0.5),
        QuestionBox(
            id: '$boxId-option',
            layer: 2,
            type: 'option',
            x: outer.x + 0.02,
            y: outer.y + 0.02 + (outer.h - 0.06) * 0.52,
            w: outer.w - 0.04,
            h: (outer.h - 0.06) * 0.22),
        QuestionBox(
            id: '$boxId-figure',
            layer: 2,
            type: 'figure',
            x: outer.x + 0.02,
            y: outer.y + 0.02 + (outer.h - 0.06) * 0.76,
            w: outer.w - 0.04,
            h: (outer.h - 0.06) * 0.22),
      ];
    });
    setState(() {
      _innerModeBoxId = boxId;
      _selectedId = null;
    });
  }

  void _updateBox(QuestionBox box, double dx, double dy, double pw, double ph,
      {bool resize = false}) {
    setState(() {
      final updated = resize
          ? box.copyWithSize(
              w: (box.w + dx / pw), h: (box.h + dy / ph))
          : box.movedBy(dx / pw, dy / ph);
      final clamped = YoloOnnxService.clampToPage(updated);
      if (box.layer == 1) {
        final i = _boxes.indexWhere((b) => b.id == box.id);
        if (i >= 0) _boxes[i] = clamped;
      } else if (_innerModeBoxId != null) {
        final list = _innerBoxes[_innerModeBoxId]!;
        final i = list.indexWhere((b) => b.id == box.id);
        if (i >= 0) list[i] = clamped;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    const baseW = 560.0;
    const baseH = 740.0;
    final width = baseW * _scale;
    final height = baseH * _scale;
    final visibleBoxes =
        _innerModeBoxId == null ? _boxes : _innerBoxes[_innerModeBoxId]!;
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
        child: Container(
          width: 860,
          height: 640,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '修框 · ${widget.fileName} 第${widget.page}页',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _boxes.isEmpty
                        ? null
                        : () => Navigator.of(context).pop(_boxes),
                    child: const Text('确认修框'),
                  ),
                ],
              ),
              if (_innerModeBoxId != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppTheme.lightFocusCard,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('内框模式：只改该题的题干 / 选项 / 配图',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                      TextButton(
                        onPressed: _exitInnerMode,
                        child: const Text('退出内框模式'),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              const Text('拖动框移动，拖右下角改大小，空白处拖动重画，滚轮缩放，双击题框进内框模式。',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              Expanded(
                child: Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      setState(() {
                        _scale = (_scale - event.scrollDelta.dy / 1200)
                            .clamp(0.5, 3.0);
                      });
                    }
                  },
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SingleChildScrollView(
                      child: GestureDetector(
                        onPanStart: (details) {
                          if (_innerModeBoxId != null) return;
                          final pos = details.localPosition;
                          setState(() {
                            _drawing = QuestionBox(
                              id: 'box-${DateTime.now().millisecondsSinceEpoch}',
                              layer: 1,
                              type: 'question',
                              x: (pos.dx / width).clamp(0.0, 1.0),
                              y: (pos.dy / height).clamp(0.0, 1.0),
                              w: 0.01,
                              h: 0.01,
                            );
                          });
                        },
                        onPanUpdate: (details) {
                          if (_drawing == null) return;
                          final pos = details.localPosition;
                          setState(() {
                            final start = _drawing!;
                            _drawing = QuestionBox(
                              id: start.id,
                              layer: 1,
                              type: 'question',
                              x: start.x,
                              y: start.y,
                              w: ((pos.dx / width) - start.x)
                                  .clamp(0.01, 1.0 - start.x),
                              h: ((pos.dy / height) - start.y)
                                  .clamp(0.01, 1.0 - start.y),
                            );
                          });
                        },
                        onPanEnd: (_) {
                          if (_drawing == null) return;
                          setState(() {
                            _boxes.add(
                                YoloOnnxService.clampToPage(_drawing!));
                            _drawing = null;
                          });
                        },
                        child: Listener(
                          // 空白点击 / 右键退出内框模式：按画布内坐标判断
                          // 是否点在框内，不与题框自身的手势竞争。
                          onPointerDown: (event) {
                            if (_innerModeBoxId == null) return;
                            if (event.buttons == kSecondaryMouseButton) {
                              _exitInnerMode();
                              return;
                            }
                            final boxes = _innerBoxes[_innerModeBoxId]!;
                            final inBox = boxes.any((b) =>
                                event.localPosition.dx >= b.x * width &&
                                event.localPosition.dx <=
                                    (b.x + b.w) * width &&
                                event.localPosition.dy >= b.y * height &&
                                event.localPosition.dy <=
                                    (b.y + b.h) * height);
                            if (!inBox) _exitInnerMode();
                          },
                          child: Container(
                            width: width,
                            height: height,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border:
                                  Border.all(color: AppTheme.lightLineStrong),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Stack(
                              children: [
                                const Center(
                                  child: Text('页面预览',
                                      style: TextStyle(color: Colors.grey)),
                                ),
                                if (_drawing != null)
                                  _boxView(_drawing!, width, height,
                                      dashed: true),
                                for (final box in visibleBoxes)
                                  _boxView(box, width, height),
                              ],
                            ),
                          ),
                        ),
                      ),
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

  Widget _boxView(QuestionBox box, double pw, double ph,
      {bool dashed = false}) {
    final isInner = box.layer == 2;
    final selected = _selectedId == box.id;
    return Positioned(
      left: box.x * pw,
      top: box.y * ph,
      width: box.w * pw,
      height: box.h * ph,
      child: GestureDetector(
        onTap: () => setState(() => _selectedId = box.id),
        onDoubleTap: box.layer == 1 ? () => _enterInnerMode(box.id) : null,
        onPanUpdate: (details) => _updateBox(
            box, details.delta.dx, details.delta.dy, pw, ph),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: selected
                  ? AppTheme.accent
                  : isInner || dashed
                      ? AppTheme.accent
                      : AppTheme.accent,
              width: selected ? 2.5 : 2,
              style: isInner || dashed
                  ? BorderStyle.solid
                  : BorderStyle.solid,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                top: -20,
                left: 0,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.accent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    isInner
                        ? switch (box.type) {
                            'stem' => '题干',
                            'option' => '选项',
                            'figure' => '配图',
                            _ => box.type,
                          }
                        : '题 ${_boxes.indexWhere((b) => b.id == box.id) + 1}',
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
              // 右下角改大小手柄。
              Positioned(
                right: -6,
                bottom: -6,
                child: GestureDetector(
                  onPanUpdate: (details) => _updateBox(
                      box, details.delta.dx, details.delta.dy, pw, ph,
                      resize: true),
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: AppTheme.accent,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
              // 删除框。
              if (selected)
                Positioned(
                  top: -20,
                  right: 0,
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        if (box.layer == 1) {
                          _boxes.removeWhere((b) => b.id == box.id);
                          _innerBoxes.remove(box.id);
                        } else if (_innerModeBoxId != null) {
                          _innerBoxes[_innerModeBoxId]!
                              .removeWhere((b) => b.id == box.id);
                        }
                        _selectedId = null;
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('删除',
                          style:
                              TextStyle(color: Colors.white, fontSize: 11)),
                    ),
                  ),
                ),
            ],
          ),
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

  QuestionBox copyWithSize({required double w, required double h}) =>
      QuestionBox(
        id: id,
        layer: layer,
        type: type,
        x: x,
        y: y,
        w: w,
        h: h,
      );
}
