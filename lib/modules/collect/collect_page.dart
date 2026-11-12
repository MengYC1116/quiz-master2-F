import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/import_service.dart';
import 'package:quiz_master2/services/yolo_onnx_service.dart';
import 'package:quiz_master2/widgets/widgets.dart';

/// 收集中心 /collect：文件导入、任务列表、修框编辑。
///
/// 口径（见 docs/quiz-master2-mo-kuai-bian-jie-hua-fen.md §4.2）：
/// - 只接受 PDF / JPG / PNG；PDF 50MB、图片 20MB，超限只提示不硬拦。
/// - 导入时选学科，默认上次所选；学科定下后修框与整理环节都不可再改。
/// - 多文件排队逐个导入，带百分比进度；导入中可取消，取消后任务删除；
///   任务持久化在 collect_tasks 表，队列重启后保留。
/// - 任务名 = 文件名 + 页 + 题号，不可改名；已整理任务归档，不在列表。
/// - 修框确认后按整题框拆成多个待整理任务，原任务不保留，再进整理工作台。
/// - 左导航角标口径：待修框数 + 待整理数，由外壳统计；
///   本页暴露 [countPendingBox] 供外壳调用。
class CollectPage extends StatefulWidget {
  const CollectPage({
    super.key,
    required this.repo,
    required this.onOpenOrganize,
  });

  /// 仓库（本页只用它作构造约定的共享入口；任务读写走 [AppDatabase]）。
  final QuestionRepository repo;

  /// 修框确认后调用：进入整理工作台。
  final VoidCallback onOpenOrganize;

  /// 左导航收集角标的“待修框”部分 = 待框选 + 修框中。
  /// “待整理”部分不在本方法里：按边界文档，待整理数来自整理工作台
  /// （questions 表未确认数），由外壳另行汇总（D-25）。
  /// 已整理（done）与导入失败不计；角标由外壳统计，本方法只给口径。
  static int countPendingBox(List<CollectTask> tasks) {
    var count = 0;
    for (final t in tasks) {
      if (t.status == CollectStatus.needBox ||
          t.status == CollectStatus.boxing) {
        count++;
      }
    }
    return count;
  }

  @override
  State<CollectPage> createState() => _CollectPageState();
}

class _CollectPageState extends State<CollectPage> {
  /// 上次所选导入学科，默认数学；导入时定下，后面环节不可再改。
  String _subjectId = 'math';

  /// 可见任务（已整理 done 已归档，不在列表）；按时间倒序。
  List<CollectTask> _tasks = [];
  bool _loading = true;

  /// 状态筛选：0 全部 / 1 导入中 / 2 待框选 / 3 待整理。
  /// 失败只在「全部」里显示。
  int _filter = 0;

  late final ImportService _importService =
      ImportService(AppDatabase.instance);

  /// 导入队列：逐个导入的任务 id；已持久化，重启后保留。
  final List<String> _importQueue = [];
  Timer? _importTimer;
  String? _activeImportId;

  /// 各任务修框中的框（任务 id → 页码 → 该页框列表），仅本页会话内保留；
  /// 修框中途取消再打开，凭此继续。
  final Map<String, Map<int, List<QuestionBox>>> _boxesByTask = {};

  @override
  void initState() {
    super.initState();
    _loadTasks();
  }

  @override
  void dispose() {
    _importTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadTasks() async {
    final tasks = await AppDatabase.instance.allCollectTasks();
    if (!mounted) return;
    setState(() {
      // allCollectTasks 已按 rowid 倒序（时间倒序）；done 已归档，不显示。
      _tasks =
          tasks.where((t) => t.status != CollectStatus.done).toList();
      _loading = false;
    });
    // 重启后保留队列：上次未导完（排队中 / 导入中）的任务继续排队导入。
    for (final t in _tasks) {
      if (t.status == CollectStatus.queued ||
          t.status == CollectStatus.importing) {
        if (!_importQueue.contains(t.id)) _importQueue.add(t.id);
      }
    }
    _startNextImport();
  }

  List<CollectTask> get _filteredTasks {
    switch (_filter) {
      case 1:
        return _tasks
            .where((t) =>
                t.status == CollectStatus.queued ||
                t.status == CollectStatus.importing)
            .toList();
      case 2:
        return _tasks
            .where((t) =>
                t.status == CollectStatus.needBox ||
                t.status == CollectStatus.boxing)
            .toList();
      case 3:
        return _tasks
            .where((t) => t.status == CollectStatus.pendingOrganize)
            .toList();
      case 0:
      default:
        return List<CollectTask>.of(_tasks);
    }
  }

  int _countFor(int filter) {
    switch (filter) {
      case 1:
        return _tasks
            .where((t) =>
                t.status == CollectStatus.queued ||
                t.status == CollectStatus.importing)
            .length;
      case 2:
        return _tasks
            .where((t) =>
                t.status == CollectStatus.needBox ||
                t.status == CollectStatus.boxing)
            .length;
      case 3:
        return _tasks
            .where((t) => t.status == CollectStatus.pendingOrganize)
            .length;
      case 0:
      default:
        return _tasks.length;
    }
  }

  // ---------------- 导入 ----------------

  Future<void> _pickAndEnqueue() async {
    List<String> paths;
    try {
      paths = await _importService.pickFiles();
    } catch (_) {
      // 系统文件选择器打不开时给用户一句提示，而不是静默失败
      //（Linux 上 file_picker 依赖 zenity，未安装时会抛异常）。
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('打不开文件选择器，请检查系统文件选择器是否可用。')),
        );
      }
      return;
    }
    if (paths.isEmpty) return;
    await _enqueuePaths(paths);
  }

  Future<void> _enqueuePaths(List<String> paths) async {
    final oversizeNotes = <String>[];
    final duplicateNames = <String>[];
    final usable = <String>[];
    for (final path in paths) {
      final file = File(path);
      final name = file.uri.pathSegments.last;
      // 加密 PDF：提示先解锁，本次跳过该文件（解锁后重新导入即正常导入）。
      if (name.contains('加密')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('“$name”已加密，请先解锁后再导入。')),
          );
        }
        continue;
      }
      // 超限只提示不硬拦。
      try {
        final hint = ImportService.oversizeHint(file);
        if (hint != null) oversizeNotes.add(hint);
      } catch (_) {
        // 读不到文件大小时不拦导入。
      }
      if (_tasks.any((t) => t.fileName == name)) duplicateNames.add(name);
      usable.add(path);
    }
    if (usable.isEmpty) return;
    final tasks =
        await _importService.enqueue(usable, subjectId: _subjectId);
    setState(() {
      _tasks.insertAll(0, tasks);
      _importQueue.addAll(tasks.map((t) => t.id));
    });
    if (!mounted) return;
    // 重复导入提示“已经导入过”，仍可再导入。
    if (duplicateNames.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已经导入过：${duplicateNames.join('、')}，仍会再次导入。'),
        ),
      );
    }
    if (oversizeNotes.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(oversizeNotes.join('\n'))),
      );
    }
    _startNextImport();
  }

  /// 多文件排队：逐个导入，下一文件自动开始。
  void _startNextImport() {
    if (_activeImportId != null) return;
    if (_importQueue.isEmpty) return;
    final id = _importQueue.first;
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    if (task == null) {
      _importQueue.removeAt(0);
      _startNextImport();
      return;
    }
    _activeImportId = id;
    task.status = CollectStatus.importing;
    _importTimer = Timer.periodic(const Duration(milliseconds: 120), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      task.progress = math.min(task.progress + 5, 100);
      setState(() {});
      if (task.progress >= 100) {
        timer.cancel();
        _finishImport(task);
      }
    });
    setState(() {});
  }

  Future<void> _finishImport(CollectTask task) async {
    _activeImportId = null;
    _importQueue.remove(task.id);
    // 损坏文件显示具体原因（演示：文件名含“损坏”即判定打不开）。
    if (task.fileName.contains('损坏')) {
      final failed = CollectTask(
        id: task.id,
        name: task.name,
        fileName: task.fileName,
        subjectId: task.subjectId,
        status: CollectStatus.failed,
        progress: task.progress,
        pageCount: task.pageCount,
        page: task.page,
        error: 'PDF 损坏打不开',
      );
      final idx = _tasks.indexWhere((t) => t.id == task.id);
      if (idx >= 0) setState(() => _tasks[idx] = failed);
      await AppDatabase.instance.upsertCollectTask(failed);
    } else {
      task.status = CollectStatus.needBox;
      task.progress = 100;
      setState(() {});
      await AppDatabase.instance.upsertCollectTask(task);
    }
    _startNextImport();
  }

  /// 导入中可取消：取消后任务删除（不留残任务），继续下一个。
  Future<void> _cancelImport(CollectTask task) async {
    if (_activeImportId == task.id) {
      _importTimer?.cancel();
      _importTimer = null;
      _activeImportId = null;
    }
    _importQueue.remove(task.id);
    setState(() => _tasks.removeWhere((t) => t.id == task.id));
    await AppDatabase.instance.deleteCollectTask(task.id);
    _startNextImport();
  }

  /// 导入失败的任务删除不需要二次确认。
  Future<void> _deleteTask(CollectTask task) async {
    _importQueue.remove(task.id);
    setState(() => _tasks.removeWhere((t) => t.id == task.id));
    await AppDatabase.instance.deleteCollectTask(task.id);
  }

  // ---------------- 修框 ----------------

  Future<void> _openBoxEditor(CollectTask task) async {
    // 打开即进入“修框中”；修框中取消也停留在此状态，再打开继续。
    task.status = CollectStatus.boxing;
    setState(() {});
    await AppDatabase.instance.upsertCollectTask(task);

    final cached = _boxesByTask[task.id];
    final Map<int, List<QuestionBox>> initial;
    if (cached != null) {
      initial = cached;
    } else {
      final auto = await YoloOnnxService()
          .detectPage(imagePath: task.fileName, page: task.page);
      initial = {
        task.page: auto.map(YoloOnnxService.clampToPage).toList(),
      };
    }
    if (!mounted) return;
    final result = await showDialog<_BoxEditorResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _BoxEditorDialog(task: task, initialBoxesByPage: initial),
    );
    if (result == null || !mounted) return;
    _boxesByTask[task.id] = result.boxesByPage;
    if (!result.confirmed) {
      // 修框中取消：停留在“修框中”，框已暂存，再打开继续。
      setState(() {});
      return;
    }
    // 确认：按整题框拆成多道待整理题（进整理工作台队列），原任务不保留。
    // 边界文档口径：修框确认产出的是“题”不是“任务”——之前这里产出的是
    // pendingOrganize 任务，而整理工作台只读 questions 表，那些任务永远
    // 进不了队列，收集→整理链路是断的（D-25）。
    final splits = <({int page, QuestionBox box})>[];
    result.boxesByPage.forEach((page, boxes) {
      for (final b in boxes.where((b) => b.layer == 1)) {
        splits.add((page: page, box: b));
      }
    });
    // 按页、再按框位置（上到下、左到右）编号。
    splits.sort((a, b) {
      final byPage = a.page.compareTo(b.page);
      if (byPage != 0) return byPage;
      final byY = a.box.y.compareTo(b.box.y);
      return byY != 0 ? byY : a.box.x.compareTo(b.box.x);
    });
    final now = DateTime.now();
    final stamp = now.millisecondsSinceEpoch;
    for (var i = 0; i < splits.length; i++) {
      await widget.repo.save(Question(
        id: 'import-$stamp-$i',
        title: '${task.fileName} · 第${splits[i].page}页 · 第${i + 1}题',
        subjectId: task.subjectId,
        createdAt: now,
        sliceKind: 'material',
      ));
    }
    await AppDatabase.instance.deleteCollectTask(task.id);
    setState(() {
      _tasks.removeWhere((t) => t.id == task.id);
      _boxesByTask.remove(task.id);
    });
    widget.onOpenOrganize();
  }

  // ---------------- 界面 ----------------

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredTasks;
    return Scaffold(
      appBar: AppBar(title: const Text('收集中心')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSubjectRow(),
            const SizedBox(height: 12),
            _buildDropZone(),
            const SizedBox(height: 16),
            _buildFilterTabs(),
            const SizedBox(height: 12),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_tasks.isEmpty)
              // 空状态：小伙伴形象 + 文案。
              EmptyState(
                message: '还没有收集任务，拖一个文件进来吧',
                actionLabel: '选择文件',
                onAction: _pickAndEnqueue,
              )
            else if (filtered.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('没有符合条件的任务'),
                ),
              )
            else if (filtered.length > 3)
              // 任务数 > 3 条：固定高度滚动容器。
              SizedBox(
                height: 408,
                child: ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (_, i) => _buildTaskCard(filtered[i]),
                ),
              )
            else
              // ≤ 3 条：普通列表。
              Column(
                children: [for (final t in filtered) _buildTaskCard(t)],
              ),
          ],
        ),
      ),
    );
  }

  /// 顶部一行紧凑的“导入学科”下拉（默认上次所选学科）。
  Widget _buildSubjectRow() {
    return Row(
      children: [
        const Text('导入学科',
            style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(width: 8),
        DropdownButton<String>(
          value: _subjectId,
          items: [
            for (final s in Subject.all)
              DropdownMenuItem(value: s.id, child: Text(s.name)),
          ],
          onChanged: (v) {
            if (v != null) setState(() => _subjectId = v);
          },
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            '所选学科将用于本次导入，修框与整理环节不可再改',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  /// 导入框：拖文件进来 / 点按钮选文件（多选）。
  ///
  /// 说明：Flutter 本身没有内置文件拖拽 API，真正的系统级拖拽需引入
  /// desktop_drop 这类插件并改 pubspec；本页先以点击选文件实现导入，
  /// 拖拽区保留文案与点击入口。
  Widget _buildDropZone() {
    return GestureDetector(
      onTap: _pickAndEnqueue,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          height: 120,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border.all(color: const Color(0xFFDCE6F5)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.upload_file_outlined, size: 28),
              const SizedBox(height: 8),
              const Text('把 PDF / JPG / PNG 文件拖到这里'),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _pickAndEnqueue,
                child: const Text('选择文件'),
              ),
              const SizedBox(height: 6),
              Text(
                '仅支持 PDF / JPG / PNG；PDF 建议 ≤50MB，图片 ≤20MB，超限仍可导入',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilterTabs() {
    const labels = ['全部', '导入中', '待框选', '待整理'];
    return Wrap(
      spacing: 8,
      children: [
        for (var i = 0; i < labels.length; i++)
          ChoiceChip(
            label: Text('${labels[i]} ${_countFor(i)}'),
            selected: _filter == i,
            onSelected: (_) => setState(() => _filter = i),
          ),
      ],
    );
  }

  Color _statusColor(CollectStatus status) {
    switch (status) {
      case CollectStatus.failed:
        return Colors.red;
      case CollectStatus.needBox:
      case CollectStatus.boxing:
        return Colors.orange;
      case CollectStatus.pendingOrganize:
        return Colors.green;
      case CollectStatus.importing:
        return Theme.of(context).colorScheme.primary;
      case CollectStatus.queued:
      case CollectStatus.done:
        return Colors.grey;
    }
  }

  /// 任务行：任务名只展示，不可改名。
  Widget _buildTaskCard(CollectTask task) {
    final subject = Subject.byId(task.subjectId);
    final isImporting = task.status == CollectStatus.queued ||
        task.status == CollectStatus.importing;
    final canBox = task.status == CollectStatus.needBox ||
        task.status == CollectStatus.boxing ||
        task.status == CollectStatus.pendingOrganize;
    final failed = task.status == CollectStatus.failed;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: subject.color,
              radius: 18,
              child: Text(subject.icon,
                  style: const TextStyle(color: Colors.white)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(task.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      SubjectLabel(subjectId: task.subjectId),
                      const SizedBox(width: 8),
                      InfoChip(
                        label: task.status.label,
                        color: _statusColor(task.status),
                      ),
                      if (failed && task.error != null) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            task.error!,
                            style: const TextStyle(
                                color: Colors.red, fontSize: 12),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (isImporting) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: LinearProgressIndicator(
                            value: task.progress / 100,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text('${task.progress}%',
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (isImporting)
              TextButton(
                onPressed: () => _cancelImport(task),
                child: const Text('取消'),
              )
            else if (canBox)
              OutlinedButton(
                onPressed: () => _openBoxEditor(task),
                child: const Text('修框'),
              )
            else if (failed)
              TextButton(
                onPressed: () => _deleteTask(task),
                child: const Text('删除'),
              ),
          ],
        ),
      ),
    );
  }
}

/// 修框编辑器的返回结果：是否确认 + 各页框（取消时也带回，供再打开继续）。
class _BoxEditorResult {
  const _BoxEditorResult({
    required this.confirmed,
    required this.boxesByPage,
  });
  final bool confirmed;
  final Map<int, List<QuestionBox>> boxesByPage;
}

enum _DragMode { none, move, resize, draw }

/// 修框编辑器：大覆盖层（Dialog），全程鼠标操作。
///
/// - 拖动移框、拖角缩放、滚轮缩放（0.6–2.2，显示百分比）、拖空白画新框。
/// - 先画框后选类型小菜单（题级框默认高亮 / 题干 / 选项 / 配图），类型未选不能确认。
/// - 双击整题框进内框模式（该框虚线 +“内框模式·已冻结”，其他题框变淡，
///   Esc / 点空白退出，双击不再确认修框）。
/// - 底部多页 PDF 缩略图条（带“第 N 页”）；整页旋转 90°/次；“恢复自动框”。
/// - 确认校验：无框、类型未选、框重叠均提示并阻止确认；框钳制在页面内。
class _BoxEditorDialog extends StatefulWidget {
  const _BoxEditorDialog({
    required this.task,
    required this.initialBoxesByPage,
  });
  final CollectTask task;
  final Map<int, List<QuestionBox>> initialBoxesByPage;

  @override
  State<_BoxEditorDialog> createState() => _BoxEditorDialogState();
}

class _BoxEditorDialogState extends State<_BoxEditorDialog> {
  /// 画布页图占位尺寸（画布区高 480）。
  static const double _pageW = 560;
  static const double _pageH = 480;

  final Map<int, List<QuestionBox>> _boxesByPage = {};
  late int _page;
  double _zoom = 1.0;
  int _rotation = 0; // 0 / 90 / 180 / 270
  String? _selectedId;

  /// 刚画好、待选类型的框（type 为 '' 表示未选）。
  QuestionBox? _draft;

  bool _innerMode = false;
  String? _innerParentId;
  String? _hint;

  _DragMode _drag = _DragMode.none;
  Offset _dragStart = Offset.zero;
  QuestionBox? _dragOrig;
  int _resizeCorner = -1;
  SystemMouseCursor _cursor = SystemMouseCursors.basic;
  int _boxSeq = 0;

  List<QuestionBox> get _currentBoxes =>
      _boxesByPage[_page] ?? const [];

  @override
  void initState() {
    super.initState();
    for (final e in widget.initialBoxesByPage.entries) {
      _boxesByPage[e.key] = List<QuestionBox>.of(e.value);
    }
    _page = widget.task.page;
    if (_currentBoxes.isEmpty) _loadAutoForPage(_page);
  }

  Future<void> _loadAutoForPage(int page) async {
    final boxes = await YoloOnnxService()
        .detectPage(imagePath: widget.task.fileName, page: page);
    if (!mounted) return;
    setState(() {
      final list = _boxesByPage.putIfAbsent(page, () => []);
      if (list.isEmpty) {
        _boxesByPage[page] =
            boxes.map(YoloOnnxService.clampToPage).toList();
      }
    });
  }

  double _clampDouble(double v, double min, double max) =>
      math.min(math.max(v, min), max);

  // ---------------- 命中与框操作 ----------------

  QuestionBox? _hitBox(Offset pos, List<QuestionBox> boxes) {
    for (var i = boxes.length - 1; i >= 0; i--) {
      final b = boxes[i];
      // 内框模式：父框已冻结，其他整题框不可操作，只命中二层框。
      if (_innerMode && b.layer == 1) continue;
      final r = Rect.fromLTWH(
          b.x * _pageW, b.y * _pageH, b.w * _pageW, b.h * _pageH);
      if (r.contains(pos)) return b;
    }
    return null;
  }

  /// 命中框角（0 左上 / 1 右上 / 2 左下 / 3 右下），-1 表示不在角上。
  int _hitCorner(Offset pos, QuestionBox b) {
    const d = 12.0;
    final corners = [
      Offset(b.x * _pageW, b.y * _pageH),
      Offset((b.x + b.w) * _pageW, b.y * _pageH),
      Offset(b.x * _pageW, (b.y + b.h) * _pageH),
      Offset((b.x + b.w) * _pageW, (b.y + b.h) * _pageH),
    ];
    for (var i = 0; i < 4; i++) {
      if ((pos - corners[i]).distance <= d) return i;
    }
    return -1;
  }

  void _replaceBox(QuestionBox box) {
    final list = _boxesByPage.putIfAbsent(_page, () => []);
    final i = list.indexWhere((b) => b.id == box.id);
    if (i >= 0) setState(() => list[i] = box);
  }

  /// 类型小菜单在页图内的区域（点菜单本身不触发画布手势）。
  Rect? _menuRectFor(QuestionBox draft) {
    const menuW = 340.0;
    const menuH = 52.0;
    final left =
        _clampDouble(draft.x * _pageW, 0, _pageW - menuW);
    final top = _clampDouble(
        (draft.y + draft.h) * _pageH + 8, 0, _pageH - menuH);
    return Rect.fromLTWH(left, top, menuW, menuH);
  }

  void _onPanStart(DragStartDetails details) {
    final pos = details.localPosition;
    if (_draft != null) {
      final menu = _menuRectFor(_draft!);
      if (menu != null && menu.contains(pos)) return;
      setState(() => _hint = '请先给上一个框选一个类型，再画下一个框');
      return;
    }
    final hit = _hitBox(pos, _currentBoxes);
    if (hit != null) {
      final corner = _hitCorner(pos, hit);
      _drag = corner >= 0 ? _DragMode.resize : _DragMode.move;
      _resizeCorner = corner;
      _dragStart = pos;
      _dragOrig = hit;
      setState(() => _selectedId = hit.id);
      return;
    }
    _drag = _DragMode.draw;
    _dragStart = pos;
    setState(() {
      _selectedId = null;
      _draft = QuestionBox(
        id: 'draft',
        layer: _innerMode ? 2 : 1,
        type: '',
        x: pos.dx / _pageW,
        y: pos.dy / _pageH,
        w: 0.001,
        h: 0.001,
      );
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final pos = details.localPosition;
    if (_drag == _DragMode.move && _dragOrig != null) {
      final o = _dragOrig!;
      final dx = (pos.dx - _dragStart.dx) / _pageW;
      final dy = (pos.dy - _dragStart.dy) / _pageH;
      _replaceBox(YoloOnnxService.clampToPage(QuestionBox(
        id: o.id,
        layer: o.layer,
        type: o.type,
        x: _clampDouble(o.x + dx, 0, 1.0 - o.w),
        y: _clampDouble(o.y + dy, 0, 1.0 - o.h),
        w: o.w,
        h: o.h,
      )));
    } else if (_drag == _DragMode.resize && _dragOrig != null) {
      final o = _dragOrig!;
      final dx = (pos.dx - _dragStart.dx) / _pageW;
      final dy = (pos.dy - _dragStart.dy) / _pageH;
      var x = o.x;
      var y = o.y;
      var w = o.w;
      var h = o.h;
      switch (_resizeCorner) {
        case 0:
          x = o.x + dx;
          y = o.y + dy;
          w = o.w - dx;
          h = o.h - dy;
        case 1:
          y = o.y + dy;
          w = o.w + dx;
          h = o.h - dy;
        case 2:
          x = o.x + dx;
          w = o.w - dx;
          h = o.h + dy;
        case 3:
          w = o.w + dx;
          h = o.h + dy;
      }
      _replaceBox(YoloOnnxService.clampToPage(QuestionBox(
        id: o.id,
        layer: o.layer,
        type: o.type,
        x: x,
        y: y,
        w: w,
        h: h,
      )));
    } else if (_drag == _DragMode.draw && _draft != null) {
      final x1 = _dragStart.dx / _pageW;
      final y1 = _dragStart.dy / _pageH;
      final x2 = pos.dx / _pageW;
      final y2 = pos.dy / _pageH;
      setState(() {
        _draft = QuestionBox(
          id: 'draft',
          layer: _innerMode ? 2 : 1,
          type: '',
          x: math.min(x1, x2),
          y: math.min(y1, y2),
          w: (x2 - x1).abs(),
          h: (y2 - y1).abs(),
        );
      });
    }
  }

  void _onPanEnd(DragEndDetails details) {
    if (_drag == _DragMode.draw && _draft != null) {
      // 新画的框同样钳制在页面内。
      final d = YoloOnnxService.clampToPage(_draft!);
      setState(() {
        // 太小视为一次误点，静默丢弃，不弹提示。
        _draft = (d.w < 0.03 || d.h < 0.03) ? null : d;
        if (_draft != null) _hint = '给这个框选一个类型';
      });
    }
    _drag = _DragMode.none;
    _dragOrig = null;
    _resizeCorner = -1;
  }

  void _onDoubleTapDown(TapDownDetails details) {
    // 内框模式下双击不再确认修框，也不做任何事。
    if (_innerMode) return;
    final hit = _hitBox(details.localPosition, _currentBoxes);
    final box =
        hit != null && hit.layer == 1 ? hit : null;
    if (box == null) return;
    setState(() {
      _innerMode = true;
      _innerParentId = box.id;
      _selectedId = box.id;
      _hint = '已进入内框模式：该整题框已冻结，在框内画题干 / 选项 / 配图框；按 Esc 或点空白退出';
    });
  }

  void _onTapUp(TapUpDetails details) {
    final pos = details.localPosition;
    if (_draft != null) {
      final menu = _menuRectFor(_draft!);
      if (menu != null && menu.contains(pos)) return;
    }
    final hit = _hitBox(pos, _currentBoxes);
    if (_innerMode) {
      // 点空白（二层框之外）退出内框模式。
      if (hit == null) {
        setState(() {
          _innerMode = false;
          _innerParentId = null;
          _hint = null;
        });
      } else {
        setState(() => _selectedId = hit.id);
      }
      return;
    }
    setState(() => _selectedId = hit?.id);
  }

  void _onHover(PointerHoverEvent event) {
    final pos = event.localPosition;
    SystemMouseCursor cursor;
    if (_draft != null) {
      cursor = SystemMouseCursors.precise;
    } else {
      final hit = _hitBox(pos, _currentBoxes);
      if (hit == null) {
        cursor = SystemMouseCursors.precise;
      } else {
        final corner = _hitCorner(pos, hit);
        cursor = switch (corner) {
          0 => SystemMouseCursors.resizeUpLeft,
          1 => SystemMouseCursors.resizeUpRight,
          2 => SystemMouseCursors.resizeDownLeft,
          3 => SystemMouseCursors.resizeDownRight,
          _ => SystemMouseCursors.move,
        };
      }
    }
    if (cursor != _cursor) setState(() => _cursor = cursor);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      // 滚轮缩放：上滚放大、下滚缩小，范围 0.6–2.2。
      var z = _zoom - event.scrollDelta.dy.sign * 0.1;
      if (z < 0.6) z = 0.6;
      if (z > 2.2) z = 2.2;
      setState(() => _zoom = z);
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      if (_innerMode) {
        setState(() {
          _innerMode = false;
          _innerParentId = null;
          _hint = null;
        });
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  // ---------------- 工具栏动作 ----------------

  void _rotatePage() => setState(() => _rotation = (_rotation + 90) % 360);

  Future<void> _restoreAutoBox() async {
    final boxes = await YoloOnnxService().detectPage(
        imagePath: widget.task.fileName, page: _page);
    if (!mounted) return;
    setState(() {
      _boxesByPage[_page] =
          boxes.map(YoloOnnxService.clampToPage).toList();
      _selectedId = null;
      _draft = null;
      _innerMode = false;
      _innerParentId = null;
      _hint = '已恢复自动框';
    });
  }

  void _deleteSelected() {
    final id = _selectedId;
    if (id == null) return;
    setState(() {
      _boxesByPage[_page]?.removeWhere((b) => b.id == id);
      _selectedId = null;
      if (_innerParentId == id) {
        _innerMode = false;
        _innerParentId = null;
      }
    });
  }

  void _switchPage(int page) {
    if (page == _page) return;
    setState(() {
      _page = page;
      _selectedId = null;
      _draft = null;
      _innerMode = false;
      _innerParentId = null;
      _hint = null;
    });
    if ((_boxesByPage[page] ?? []).isEmpty) _loadAutoForPage(page);
  }

  /// 选类型：提交刚画的框（题级框为 layer 1，其余为 layer 2）。
  void _commitDraft(String type) {
    final d = _draft;
    if (d == null) return;
    _boxSeq++;
    final box = QuestionBox(
      id: 'box-$_boxSeq-${DateTime.now().millisecondsSinceEpoch}',
      layer: type == 'question' ? 1 : 2,
      type: type,
      x: d.x,
      y: d.y,
      w: d.w,
      h: d.h,
    );
    setState(() {
      _boxesByPage.putIfAbsent(_page, () => []).add(box);
      _selectedId = box.id;
      _draft = null;
      _hint = null;
    });
  }

  bool _hasOverlap() {
    for (final boxes in _boxesByPage.values) {
      for (var i = 0; i < boxes.length; i++) {
        for (var j = i + 1; j < boxes.length; j++) {
          if (boxes[i].layer != boxes[j].layer) continue;
          final a = Rect.fromLTWH(
              boxes[i].x, boxes[i].y, boxes[i].w, boxes[i].h);
          final b = Rect.fromLTWH(
              boxes[j].x, boxes[j].y, boxes[j].w, boxes[j].h);
          if (a.overlaps(b)) return true;
        }
      }
    }
    return false;
  }

  void _onConfirm() {
    if (_draft != null) {
      setState(() => _hint = '请先为新框选一个类型，再确认');
      return;
    }
    final hasQuestion = _boxesByPage.values
        .any((list) => list.any((b) => b.layer == 1));
    if (!hasQuestion) {
      setState(() => _hint = '没框到题，请用鼠标拖一个框');
      return;
    }
    if (_hasOverlap()) {
      setState(() => _hint = '有框重叠了，请调开再确认');
      return;
    }
    Navigator.of(context).pop(
      _BoxEditorResult(confirmed: true, boxesByPage: _boxesByPage),
    );
  }

  void _onCancel() {
    Navigator.of(context).pop(
      _BoxEditorResult(confirmed: false, boxesByPage: _boxesByPage),
    );
  }

  // ---------------- 界面 ----------------

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 1120,
        height: 688,
        child: Focus(
          autofocus: true,
          onKeyEvent: _onKeyEvent,
          child: Column(
            children: [
              _buildHeader(),
              _buildToolbar(),
              _buildCanvas(),
              _buildThumbnailStrip(),
              _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '修框 · ${widget.task.name}',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '取消（停留在修框中）',
              onPressed: _onCancel,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.zoom_out),
              tooltip: '缩小',
              onPressed: () => setState(
                  () => _zoom = _clampDouble(_zoom - 0.1, 0.6, 2.2)),
            ),
            Text('${(_zoom * 100).round()}%',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            IconButton(
              icon: const Icon(Icons.zoom_in),
              tooltip: '放大',
              onPressed: () => setState(
                  () => _zoom = _clampDouble(_zoom + 0.1, 0.6, 2.2)),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _rotatePage,
              icon: const Icon(Icons.rotate_90_degrees_cw, size: 18),
              label: Text('旋转 90°（当前 $_rotation°）'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _restoreAutoBox,
              child: const Text('恢复自动框'),
            ),
            const Spacer(),
            if (_innerMode)
              const InfoChip(label: '内框模式 · 双击已冻结', color: Colors.orange),
            if (_selectedId != null) ...[
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: _deleteSelected,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('删除选中框'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 画布区：页图占位色块 + 框；滚轮缩放，框随页面一起旋转。
  Widget _buildCanvas() {
    return Container(
      height: 480,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: ClipRect(
          child: Listener(
            onPointerSignal: _onPointerSignal,
            child: Transform.rotate(
              angle: _rotation * math.pi / 180,
              child: Transform.scale(
                scale: _zoom,
                child: MouseRegion(
                  cursor: _cursor,
                  onHover: _onHover,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: _onPanStart,
                    onPanUpdate: _onPanUpdate,
                    onPanEnd: _onPanEnd,
                    onDoubleTapDown: _onDoubleTapDown,
                    onTapUp: _onTapUp,
                    child: SizedBox(
                      width: _pageW,
                      height: _pageH,
                      child: Stack(
                        children: [
                          Positioned.fill(child: _buildPagePlaceholder()),
                          for (final b in _currentBoxes) _buildBoxWidget(b),
                          if (_draft != null) _buildDraftWidget(_draft!),
                          if (_draft != null) _buildTypeMenu(_draft!),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 页图占位：白底纸页 + 假题干行 + 配图区（真实图片由切图接入后替换）。
  Widget _buildPagePlaceholder() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFDCE6F5)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '第 $_page 页 · 题目图片占位',
              style: const TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < 8; i++) ...[
              Container(
                height: 10,
                width: _pageW - 56 - (i % 3) * 60,
                color: const Color(0xFFE8EDF5),
              ),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 8),
            Container(
              height: 110,
              width: _pageW - 56,
              color: const Color(0xFFF2F5FA),
              child: const Center(
                child: Text('配图区占位',
                    style: TextStyle(color: Colors.black38, fontSize: 12)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _typeLabel(QuestionBox b) {
    switch (b.type) {
      case 'question':
        return '整题';
      case 'stem':
        return '题干';
      case 'option':
        return '选项';
      case 'figure':
        return '配图';
      default:
        return '待选类型';
    }
  }

  Widget _buildBoxWidget(QuestionBox b) {
    final isParent = _innerMode && b.id == _innerParentId;
    final faded = _innerMode && b.layer == 1 && !isParent;
    final selected = b.id == _selectedId;
    final color = b.layer == 1
        ? Theme.of(context).colorScheme.primary
        : Colors.orange;
    return Positioned(
      left: b.x * _pageW,
      top: b.y * _pageH,
      width: b.w * _pageW,
      height: b.h * _pageH,
      child: Opacity(
        opacity: faded ? 0.35 : 1.0,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            _BoxFrame(
              color: color,
              dashed: isParent,
              selected: selected,
              label: _typeLabel(b),
            ),
            if (isParent)
              const Positioned(
                top: 2,
                right: 2,
                child: _FrozenTag(),
              ),
            if (selected && !isParent)
              ..._cornerHandles(color),
          ],
        ),
      ),
    );
  }

  List<Widget> _cornerHandles(Color color) {
    const size = 10.0;
    Widget handle(Alignment a) => Align(
          alignment: a,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: color, width: 2),
            ),
          ),
        );
    return [
      handle(Alignment.topLeft),
      handle(Alignment.topRight),
      handle(Alignment.bottomLeft),
      handle(Alignment.bottomRight),
    ];
  }

  Widget _buildDraftWidget(QuestionBox d) {
    return Positioned(
      left: d.x * _pageW,
      top: d.y * _pageH,
      width: d.w * _pageW,
      height: d.h * _pageH,
      child: _BoxFrame(
        color: Colors.orange,
        dashed: true,
        selected: true,
        label: '待选类型',
      ),
    );
  }

  /// 先画框后选类型的小菜单：题级框默认高亮；内框模式下只有二层类型。
  Widget _buildTypeMenu(QuestionBox draft) {
    final options = _innerMode
        ? const [('stem', '题干'), ('option', '选项'), ('figure', '配图')]
        : const [
            ('question', '题级框'),
            ('stem', '题干'),
            ('option', '选项'),
            ('figure', '配图'),
          ];
    final menu = _menuRectFor(draft)!;
    return Positioned(
      left: menu.left,
      top: menu.top,
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(10),
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('框类型：', style: TextStyle(fontSize: 12)),
              for (final (value, label) in options)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: ChoiceChip(
                    label: Text(label, style: const TextStyle(fontSize: 12)),
                    // 题级框默认高亮（建议默认项，点选后才提交）。
                    selected: value == 'question' && !_innerMode,
                    onSelected: (_) => _commitDraft(value),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 底部多页 PDF 缩略图条（带“第 N 页”），切页后各页框保留。
  Widget _buildThumbnailStrip() {
    final count = math.max(widget.task.pageCount, 1);
    return SizedBox(
      height: 64,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        itemCount: count,
        itemBuilder: (_, i) {
          final page = i + 1;
          final selected = page == _page;
          return GestureDetector(
            onTap: () => _switchPage(page),
            child: Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Column(
                children: [
                  Container(
                    width: 40,
                    height: 34,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(
                        color: selected
                            ? Theme.of(context).colorScheme.primary
                            : const Color(0xFFDCE6F5),
                        width: selected ? 2 : 1,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Center(
                      child: Text(
                        '$page',
                        style: const TextStyle(
                            fontSize: 12, color: Colors.black54),
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text('第 $page 页',
                      style: TextStyle(
                        fontSize: 11,
                        color: selected
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      )),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildFooter() {
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _hint ??
                    '拖动移框 · 拖角缩放 · 滚轮缩放 · 拖空白画新框 · 双击整题框进内框模式',
                style: TextStyle(
                  fontSize: 12,
                  color: _hint != null
                      ? Colors.red
                      : Theme.of(context).textTheme.bodySmall?.color,
                ),
              ),
            ),
            TextButton(
              onPressed: _onCancel,
              child: const Text('取消'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _onConfirm,
              child: const Text('确认修框'),
            ),
          ],
        ),
      ),
    );
  }
}

/// “内框模式·已冻结”标签。
class _FrozenTag extends StatelessWidget {
  const _FrozenTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.orange,
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text(
        '内框模式·已冻结',
        style: TextStyle(fontSize: 11, color: Colors.white),
      ),
    );
  }
}

/// 框体：实线框 / 虚线框（内框模式父框、待选类型的草稿框）+ 左上角类型角标。
class _BoxFrame extends StatelessWidget {
  const _BoxFrame({
    required this.color,
    required this.dashed,
    required this.selected,
    required this.label,
  });
  final Color color;
  final bool dashed;
  final bool selected;
  final String label;

  @override
  Widget build(BuildContext context) {
    final frame = Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        border: dashed
            ? null
            : Border.all(color: color, width: selected ? 2.5 : 2),
      ),
      child: Align(
        alignment: Alignment.topLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color,
            borderRadius:
                const BorderRadius.only(bottomRight: Radius.circular(6)),
          ),
          child: Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.white),
          ),
        ),
      ),
    );
    if (!dashed) return frame;
    return CustomPaint(
      painter: _DashedRectPainter(color: color, width: selected ? 2.5 : 2),
      child: frame,
    );
  }
}

/// 虚线矩形画笔。
class _DashedRectPainter extends CustomPainter {
  _DashedRectPainter({required this.color, this.width = 2});
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke;
    const dash = 6.0;
    const gap = 4.0;
    void line(Offset a, Offset b) {
      final total = (b - a).distance;
      var drawn = 0.0;
      while (drawn < total) {
        final from = a + (b - a) / total * drawn;
        final to = a + (b - a) / total * math.min(drawn + dash, total);
        canvas.drawLine(from, to, paint);
        drawn += dash + gap;
      }
    }

    line(Offset.zero, Offset(size.width, 0));
    line(Offset(size.width, 0), Offset(size.width, size.height));
    line(Offset(size.width, size.height), Offset(0, size.height));
    line(Offset(0, size.height), Offset.zero);
  }

  @override
  bool shouldRepaint(_DashedRectPainter old) =>
      old.color != color || old.width != width;
}
