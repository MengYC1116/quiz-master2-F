import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/database.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../services/import_service.dart';
import '../../services/page_image_pipeline.dart';
import '../../services/pdf_render_service.dart';
import '../../services/yolo_onnx_service.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/uikit.dart';
import '../../widgets/widgets.dart';

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
  // 导入学科下拉框：读库 subjects（B2 补充；以前写死 Subject.all，
  // 新学科选不到、无法导入）。B8-1：空表是删光学科后的合法状态，
  // 不再回退预设三科（回退就是截图里下拉仍有数学/英语/政治的原因）；
  // 首帧与读库后都以真实列表为准，空就是空。
  List<Subject> _subjects = const [];
  // 库里找学科：新学科用库里的名与色；找不到才回退 Subject.byId
  //（数学兜底，只发生在数据不一致时）。
  Subject _subjectOf(String id) =>
      _subjects.firstWhere((s) => s.id == id, orElse: () => Subject.byId(id));
  String? _selectedSubjectId; // 每次导入都选，默认“请选择学科”
  bool _picking = false;
  bool _noSubjectWarning = false;
  bool _hideErrorBanner = false;
  CollectStatus? _filter; // null = 全部；筛选不改变时间顺序
  _PendingImport? _pendingImport;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 待框选/修框中任务每页有没有 1 层草稿框（行上无框警告用，
  /// 见 _taskRow；只查这两个状态，其余状态不查）。
  Map<String, List<int>> _unboxedPagesByTask = {};

  /// 有任意草稿框（任意层、任意页）的任务 id（SR-P2-25：行上无框警告
  /// 的“打开过”信号的一半；另一半是任务状态本身——任务一旦打开过
  /// 修框，_openBoxEditor 会把它置为 boxing 并落盘，无需新字段）。
  Set<String> _hasAnyDraftBox = {};

  /// 有同 sourcePath 拆分任务（待整理/已整理）的任务 id（SR-P2-25
  /// 补信号：P1-2 保留任务按同 id 重建、未框页又没有草稿框——光看状
  /// 态与草稿会误判为“从未打开”。但拆分任务只可能由编辑器确认产生，
  /// 有拆分任务的同源任务一定打开过、应继续警告。sourcePath 含原任
  /// 务 id、重导入不串，与 _load 的 splitPagesBySource 同口径）。
  /// SR2-22：这是派生信号，不是持久化信号——每次 _load 由当前任务
  /// 表重算，没有字段落盘；删掉全部同源拆分任务行后它就消失。新修
  /// 的保留任务不再靠它（重建时直接写 boxing 状态，见 _confirmSplit），
  /// 它只为修前已重建回 needBox 的旧保留任务兜底。
  Set<String> _hasSplitSibling = {};

  Future<void> _load() async {
    final tasks = await widget.repo.collectTasks();
    final subjects = await widget.repo.subjects();
    final unboxed = <String, List<int>>{};
    final hasAnyDraftBox = <String>{};
    final hasSplitSibling = <String>{};
    // P1-2：同 sourcePath 的拆分任务（待整理/已整理）所在页就是已拆页，
    // 不算未框（保留任务重进列表时，第 1 页已拆成题，不能再报没框）。
    // SR-P2-33：CollectStatus.done 全仓无赋值处——没有任何生产代码
    // 会把任务置为 done（已整理任务仍以 pendingOrganize 呈现）；
    // 这里的 done 分支是防御性保留：万一旧库行读回 done 状态，仍按
    // 已拆页算，不会把它误报成未框；_taskNote / _statusPill /
    // _taskActions 里的 done 分支同理（switch 穷举也要求保留）。
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
        final boxes = await widget.repo.boxesForTask(task.id);
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
    if (!mounted) return;
    setState(() {
      _tasks = tasks;
      _subjects = subjects;
      _unboxedPagesByTask = unboxed;
      _hasAnyDraftBox = hasAnyDraftBox;
      _hasSplitSibling = hasSplitSibling;
    });
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
      final service = ImportService(
        widget.repo.db,
        pdfRenderService: widget.pdfRenderService,
      );
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
      // 重复文件 / 超限均为黄色横幅：用户选“仍然再导一份”才继续，
      // 选“不导了”则整批取消。重复只是警告；超限文件导入时会记为
      // 失败任务（SR-P1-14：PDF 50MB / 图片 20MB 均为硬判）。
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
    final service = ImportService(
      widget.repo.db,
      pdfRenderService: widget.pdfRenderService,
    );
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
      // §1.4：真实导入（复制进库 + PDF 整本渲染 / 图片 EXIF 归一化
      // + 真实进度）。PDF 加密 / 损坏 / 超 50MB / 超 20 页 /
      // 渲染失败都进失败任务（enqueue 内判），不建无页图任务；
      // 复制失败 / 镜像方向同样进失败任务，不建空任务。
      final created = await service.enqueue(
        [path],
        subjectId: subjectId,
        onProgress: (taskId, progress) {
          final i = _tasks.indexWhere((t) => t.id == taskId);
          if (i < 0 || !mounted) return;
          final t = _tasks[i];
          if (t.progress == progress) return;
          setState(() {
            _tasks[i] = CollectTask(
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
            );
          });
        },
      );
      for (final task in created) {
        if (!_tasks.any((t) => t.id == task.id)) _tasks.add(task);
      }
      if (mounted) setState(() {});
    }
    await widget.repo.saveRecentTask(
      kind: '收集',
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
      // SR-P2-28：id 用 newEntityId（毫秒 + 随机后缀）；旧写法只拼
      // 毫秒 + 文件名 hash，同名文件同毫秒两次失败会互相覆盖。
      id: newEntityId('task'),
      name: '$fileName · 第1页 · 第1题',
      fileName: fileName,
      subjectId: subjectId,
      status: CollectStatus.failed,
      error: error,
    );
    await widget.repo.saveCollectTask(task);
  }

  Future<void> _openBoxEditor(CollectTask task) async {
    // §6 第 6 条：页图缺失明确报错、不开编辑器。
    // PDF 多页任务：每页的页图都要在（切页就换底图），缺任何一页
    // 都不开编辑器；单页图片任务只校验当前页。
    final pageImageRel = ImportService.pageImageRelativeForTask(task);
    final pageImageAbs = pageImageRel.isEmpty
        ? null
        : AppDatabase.resolveDataPath(pageImageRel);
    if (pageImageAbs == null || !File(pageImageAbs).existsSync()) {
      _snack('页图缺失：找不到这份文件的页图，无法修框，请重新导入');
      return;
    }
    final pageImagePaths = <int, String>{};
    if (ImportService.isPdfTask(task)) {
      for (var p = 1; p <= task.pageCount; p++) {
        final rel = ImportService.pageImageRelativeForTask(task, page: p);
        final abs = AppDatabase.resolveDataPath(rel);
        if (abs == null || !File(abs).existsSync()) {
          _snack('页图缺失：找不到第 $p 页的页图，无法修框，请重新导入');
          return;
        }
        pageImagePaths[p] = abs;
      }
    }
    task.status = CollectStatus.boxing;
    await widget.repo.saveCollectTask(task);
    await _load();
    // 草稿优先：该页有草稿框就用草稿，不再检测（§1.5）；
    // 没有草稿才跑检测，检测结果是原页坐标，先按草稿已存的旋转角度
    // 做坐标变换再进框列表（P2 实施注意 1，见 rotateBoxToRotatedPage）。
    final drafts = await widget.repo.boxesForTask(task.id);
    final draftsByPage = <int, List<QuestionBox>>{};
    for (final b in drafts) {
      (draftsByPage[b.page] ??= []).add(b);
    }
    final pageRotation = task.pageRotations[task.page] ?? 0;
    var detected = const <QuestionBox>[];
    String? detectError;
    if ((draftsByPage[task.page] ?? const <QuestionBox>[]).isEmpty) {
      final yolo = widget.yoloService ?? YoloOnnxService();
      final result = await yolo.detectPage(
        imagePath: pageImageAbs,
        page: task.page,
      );
      if (result.usedFallback) {
        // §1.3：模型失败不落占位框，只提示手动框选，原有框保持不动。
        detectError = result.error ?? '自动检测不可用，请手动框选';
      } else {
        detected = result.boxes
            .map((b) => rotateBoxToRotatedPage(b, pageRotation))
            .toList();
      }
    }
    if (!mounted) return;
    final result = await showBoxEditorDialog(
      context: context,
      fileName: task.fileName,
      pageImagePath: pageImageAbs,
      pageImagePaths: pageImagePaths,
      page: task.page,
      pageCount: task.pageCount,
      subjectName: _subjectOf(task.subjectId).name,
      taskId: task.id,
      mode: BoxEditorMode.draft,
      initialBoxesByPage: draftsByPage,
      initialDetected: detected,
      initialRotations: task.pageRotations,
      detectError: detectError,
      yoloService: widget.yoloService ?? YoloOnnxService(),
      onSaveDraft: (draft) async {
        await widget.repo.saveDraftBoxes(
          taskId: task.id,
          boxesByPage: draft.boxesByPage,
          rotations: draft.rotationsByPage,
        );
      },
    );
    if (result == null) {
      // 取消中途退出：草稿已由编辑器保存，任务留“修框中”，
      // 下次点“继续修框”接着修。
      await _load();
      return;
    }
    await _confirmSplit(task, result);
  }

  /// SR2-62：上一次确认的 `ts-rnd` 戳（只记这一个值，不作他用）。
  /// 两次确认落在同一毫秒且随机段恰好撞上时，题 id 与拆分任务 id
  /// 会全撞（SR-P2-60 的 6 位随机段只把概率压到 1e-6，不是保证）；
  /// 撞上就重抽，直到与上一次不同，保证两次确认的 id 不同。
  static String _lastSplitStamp = '';

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
  Future<void> _deleteWrittenFiles(List<String> rels) async {
    for (final rel in rels) {
      try {
        final abs = AppDatabase.resolveDataPath(rel);
        final file = abs == null ? null : File(abs);
        if (file != null && file.existsSync()) await file.delete();
      } catch (_) {}
    }
  }

  Future<void> _confirmSplit(CollectTask task, BoxEditorResult result) async {
    final pages = result.boxesByPage.keys.toList()..sort();
    // P1-2：保留任务重进再确认时，已拆过的页不再重复拆（同 sourcePath
    // 的拆分任务就是已拆页；sourcePath 含原任务 id，重导入不串）。
    final alreadySplit = _splitPagesFor(_tasks, task);
    final boxedPages = <int>{
      for (final p in pages)
        if (!alreadySplit.contains(p) &&
            result.boxesByPage[p]!.isNotEmpty)
          p,
    };
    var total = 0;
    for (final p in boxedPages) {
      total += result.boxesByPage[p]!.length;
    }
    if (total == 0) {
      final hadSkippedBoxes = pages.any(
        (p) =>
            alreadySplit.contains(p) &&
            result.boxesByPage[p]!.isNotEmpty,
      );
      await _load();
      if (hadSkippedBoxes && mounted) _snack('这些页已经拆成题了，不用再拆');
      return;
    }
    final unboxedPages = <int>[
      for (var p = 1; p <= task.pageCount; p++)
        if (!boxedPages.contains(p) && !alreadySplit.contains(p)) p,
    ];
    if (unboxedPages.isNotEmpty && mounted) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('还有 ${unboxedPages.length} 页没有框'),
          content: Text(
            '第 ${_pageListText(unboxedPages)} 页还没有框。确认后，有框的 ${boxedPages.length} 页先拆成 $total 道题去整理，没框的 ${unboxedPages.length} 页会留在这个任务里，之后点「修框」继续框。',
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
        await _load();
        return;
      }
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
    final writtenRels = <String>[];
    try {
      for (final p in pages) {
        // 已拆过的页不再切（见方法头的 alreadySplit）。
        if (alreadySplit.contains(p)) continue;
        final pageBoxes = result.boxesByPage[p]!;
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
        final rotation = result.rotationsByPage[p] ?? 0;
        late final Uint8List bakedBytes;
        late final String bakedRel;
        if (rotation != 0) {
          bakedBytes = await rotateImageBytes(pageBytes, rotation);
          bakedRel = ImportService.bakedPageRelative(task.id, p, rotation);
          final bakedAbs = AppDatabase.resolveDataPath(bakedRel)!;
          writtenRels.add(bakedRel);
          await File(bakedAbs).parent.create(recursive: true);
          await File(bakedAbs).writeAsBytes(bakedBytes);
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
          await File(sliceAbs).parent.create(recursive: true);
          await File(sliceAbs).writeAsBytes(slice.png);
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
      await _deleteWrittenFiles(writtenRels);
      if (mounted) _snack('拆题失败：切片写不进去（$e），请重试');
      await _load();
      return;
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
      // _hasSplitSibling 仍保留：它是修前已重建回 needBox 的旧保留
      // 任务的唯一信号（见 _load）。
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
            if (result.rotationsByPage.containsKey(p))
              p: result.rotationsByPage[p]!,
        },
      );
      retainedBoxesByPage = {
        for (final p in unboxedPages)
          p: List.of(result.boxesByPage[p] ?? const <QuestionBox>[]),
      };
    }
    try {
      await widget.repo.confirmSplit(
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
      await _deleteWrittenFiles(writtenRels);
      if (mounted) _snack('拆题失败：保存失败（$e），请重试');
      await _load();
      return;
    }
    // SR2-25：收尾写最近任务失败也不影响成功提示与列表刷新——
    // 拆题已提交，记日志后继续。
    try {
      await widget.repo.saveRecentTask(
        kind: '收集',
        subjectId: task.subjectId,
        title: task.fileName,
      );
    } catch (e) {
      debugPrint('SR2-25：saveRecentTask 失败，已忽略：$e');
    }
    await _load();
    if (mounted) {
      final base = unboxedPages.isNotEmpty
          ? '已生成 $total 道题去整理，还有 ${unboxedPages.length} 页没框留在任务里'
          : '已生成 $total 道题，去整理吧';
      _snack(base);
    }
  }

  /// 同 sourcePath 的拆分任务（待整理/已整理）所在页就是已拆页。
  /// sourcePath 是 `imports/<原任务 id>/...`，原任务 id 唯一，
  /// 重导入同一份文件不串（见 _load 的 splitPagesBySource）。
  static Set<int> _splitPagesFor(List<CollectTask> all, CollectTask task) {
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
  static String _pageListText(List<int> pages) {
    if (pages.length <= 5) return pages.join('、');
    return '${pages.take(5).join('、')} 等';
  }

  /// 行上的无框警告文案：单张图直接说“这张图还没有框”，
  /// 多页只报没框的页数与页码。
  static String _noBoxWarningText(CollectTask task, List<int> unboxed) {
    if (task.pageCount <= 1) return '这张图还没有框';
    if (unboxed.length == task.pageCount) {
      return '这份文件还有 ${unboxed.length} 页没有框';
    }
    return '还有 ${unboxed.length} 页没有框：第 ${_pageListText(unboxed)} 页';
  }

  /// 取消导入 / 取消排队：直接删，无二次确认。
  /// B3：失败任务的删除不再走这里，改走 [_deleteTask] 弹模态确认框。
  Future<void> _removeTask(CollectTask task) async {
    await widget.repo.deleteCollectTask(task.id);
    await _load();
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
                  title: '文件超过大小上限，导入会失败。',
                  message:
                      '${_pendingImport!.oversizeHints.join(' ')}可以先压缩再重新选；如果仍要导入，超限的文件会记为失败任务，其他文件正常导入。',
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
                  value: _selectedSubjectId,
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
                    _subjects.isEmpty ? '还没有学科' : '请选择学科',
                    style: TextStyle(color: palette.muted),
                  ),
                  items: _subjects
                      .map(
                        (s) =>
                            DropdownMenuItem(value: s.id, child: Text(s.name)),
                      )
                      .toList(),
                  onChanged: _subjects.isEmpty
                      ? null
                      : (v) => setState(() => _selectedSubjectId = v),
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: 4 * scale),
        Text(
          // B8-1：学科删空时说明去处，不留一个打不开的空下拉。
          _subjects.isEmpty
              ? '还没有学科：先去「学科管理」添加一个，再回来导入。'
              : '每次导入都自己选：不默认上次选的，也不默认数学，没选学科不能导入',
          style: TextStyle(
            fontSize: DesignTokens.captionFontSize,
            color: palette.muted,
            height: 1.4,
          ),
        ),
        if (_subjects.isEmpty && widget.onGoSubjects != null) ...[
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
    return GestureDetector(
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
                '单个 PDF 不超过 50MB、20 页，超了进失败任务并提示分批导入 · 图片不超过 20MB · 一份卷子会按页逐页框题 · 一次拖进来多个文件会生成多个任务排队导入，一个一个检测',
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
    final subject = _subjectOf(task.subjectId);
    final isLast = _shownTasks.last == task;
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
        _hasAnyDraftBox.contains(task.id) ||
        _hasSplitSibling.contains(task.id);
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
          // P1-2 补充：待框选/修框中任务里还有没框的页，行上出红色警告
          //（单张图：“这张图还没有框”；多页：报页数与页码）。
          // SR-P2-25：只对打开过修框或已有任意草稿框的任务显示，
          // 新导入的任务不警告（见 _taskRow 头的 warnUnboxed）。
          // 行与页的对应：一个任务一行，一行管 pageCount 张图，
          // 未框页是 _load 按草稿框逐页算出来的（见 _unboxedPagesByTask）。
          if (warnUnboxed &&
              (_unboxedPagesByTask[task.id] ?? const <int>[]).isNotEmpty) ...[
            SizedBox(height: 6 * scale),
            Text(
              _noBoxWarningText(task, _unboxedPagesByTask[task.id]!),
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
