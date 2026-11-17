// 修框编辑器（B4 从 collect_page.dart 纯拆分移出，未改行为）。
//
// 含 [BoxEditorMode]、[BoxEditorResult]、[showBoxEditorDialog] 与修框编辑器
// 对话框（`_BoxEditorDialog`）。收集页与题目详情页共用入口；
// `collect_page.dart` 会 re-export 本文件，现有调用方 import 一字不用改。

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../data/database.dart';
import '../../models/models.dart';
import '../../services/page_image_pipeline.dart';
import '../../services/yolo_onnx_service.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/uikit.dart';

/// 修框编辑器模式（§1.5）：
/// - draft：收集任务的草稿修框（关闭/取消/切页时保存草稿）；
/// - rework：详情页“重新框选”（只改目标题的框，取消丢弃本次修改；
///   整页旋转禁用，同页其他题的框只读展示）。
enum BoxEditorMode { draft, rework }

/// 修框编辑器的确认结果：各页题级框 + 各页旋转角度
///（确认时按角度烘焙页图，见 §1.6）。画框直接就是题级框。
class BoxEditorResult {
  const BoxEditorResult({
    required this.boxesByPage,
    required this.rotationsByPage,
  });

  final Map<int, List<QuestionBox>> boxesByPage;
  final Map<int, int> rotationsByPage;
}

/// 打开修框编辑器（收集页与详情页共用入口）。
/// - draft 模式：`onSaveDraft` 在取消/切页时被调（草稿保存）；
/// - rework 模式：`onSaveDraft` 为空（取消丢弃），`readOnlyBoxes`
///   是同页其他题的 1 层框（只读展示，重叠校验对它们也生效）。
Future<BoxEditorResult?> showBoxEditorDialog({
  required BuildContext context,
  required String fileName,
  required String pageImagePath,
  Map<int, String> pageImagePaths = const {},
  required int page,
  required int pageCount,
  required String subjectName,
  required String taskId,
  required BoxEditorMode mode,
  Map<int, List<QuestionBox>> initialBoxesByPage = const {},
  List<QuestionBox> initialDetected = const [],
  Map<int, int> initialRotations = const {},
  String? reworkQuestionId,
  List<QuestionBox> readOnlyBoxes = const [],
  String? detectError,
  YoloOnnxService? yoloService,
  Future<void> Function(BoxEditorResult draft)? onSaveDraft,
}) {
  return showDialog<BoxEditorResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _BoxEditorDialog(
      fileName: fileName,
      pageImagePath: pageImagePath,
      pageImagePaths: pageImagePaths,
      page: page,
      pageCount: pageCount,
      subjectName: subjectName,
      taskId: taskId,
      mode: mode,
      initialBoxesByPage: initialBoxesByPage,
      initialDetected: initialDetected,
      initialRotations: initialRotations,
      reworkQuestionId: reworkQuestionId,
      readOnlyBoxes: readOnlyBoxes,
      detectError: detectError,
      yoloService: yoloService ?? YoloOnnxService(),
      onSaveDraft: onSaveDraft,
    ),
  );
}

/// 修框编辑器（覆盖式浮层）：页缩略图条 + 画布；只有题级框。
///
/// HTML 来源：`frameEditorHTML` / `frameHandlesHTML`（交互原型实读）。
/// - 空白处拖动直接画新框，松开即生成题级框；
/// - 框只能拖动/缩放，**不旋转**（单框旋转已禁用，
///   见 §6 第 10 条：圆柄已去掉，`QuestionBox` 无 rotation 字段）；
/// - 「旋转整页」每次 90°（框的百分比坐标跟着转；旋转按页保存，
///   确认时烘焙进页图）；重框模式下禁用整页旋转；
/// - 框按页面百分比存、只能在图内（画 / 拖 / 缩放都钳制）；
/// - 没有框偏提示：自己看图拖边改；两道题的框重叠时确认被拦下；
/// - 草稿模式取消中途退出 → 保存草稿，任务留“修框中”
///   （由调用方保持状态，本对话框只返回 null）；重框模式取消 → 丢弃；
/// - 确认按框数拆分（返回各页的题级框，调用方替换原任务）。
/// - 切页不丢框：每页的框都留着，切回来还在，确认后才一起提交；
///   切页时保存当前页草稿。
///
/// 底图是真实页图（`pageImagePath`），不再是占位纸面；页图缺失时
/// 调用方不打开编辑器（§6 第 6 条）。
class _BoxEditorDialog extends StatefulWidget {
  const _BoxEditorDialog({
    required this.fileName,
    required this.pageImagePath,
    this.pageImagePaths = const {},
    required this.page,
    required this.pageCount,
    required this.subjectName,
    required this.taskId,
    required this.mode,
    this.initialBoxesByPage = const {},
    this.initialDetected = const [],
    this.initialRotations = const {},
    this.reworkQuestionId,
    this.readOnlyBoxes = const [],
    this.detectError,
    required this.yoloService,
    this.onSaveDraft,
  });

  final String fileName;

  /// 修框底图（库内页图绝对路径，P2 实施注意 4：首次检测 /
  /// 恢复自动框 / 旋转后检测统一传页图路径，fileName 只做显示）。
  final String pageImagePath;

  /// 多页任务的按页底图（页 → 库内页图绝对路径；PDF 任务由调用方
  /// 传入全部页，单页任务 / 重框模式不传，用 [pageImagePath]）。
  /// 切页时底图、检测、尺寸都跟着当前页走。
  final Map<int, String> pageImagePaths;
  final int page;
  final int pageCount;
  final String subjectName;

  /// 框 id 的 scope：草稿是任务 id，重框是 `rework-<questionId>`；
  /// 持久 id 规则 `box-<scope>-p<page>-<uuid8>`（§1.2(c)）。
  final String taskId;
  final BoxEditorMode mode;

  /// 各页已保存的草稿框（草稿模式）/ 目标题的框（重框模式）。
  final Map<int, List<QuestionBox>> initialBoxesByPage;

  /// 本页刚检测出的框（草稿模式、无草稿时才传）。
  final List<QuestionBox> initialDetected;

  /// 草稿已存的按页旋转角度（页 → 角度，§1.6.1）。
  final Map<int, int> initialRotations;

  /// 重框模式的目标题 id。
  final String? reworkQuestionId;

  /// 同页其他题的 1 层框（重框模式只读展示，重叠校验对它们也生效）。
  final List<QuestionBox> readOnlyBoxes;

  /// 打开时检测失败的原因（模型缺失等）：显示“手动框选”提示，
  /// 不落占位框（§1.3）。
  final String? detectError;
  final YoloOnnxService yoloService;

  /// 草稿保存回调（草稿模式：取消/切页时调；重框模式为空）。
  final Future<void> Function(BoxEditorResult draft)? onSaveDraft;

  @override
  State<_BoxEditorDialog> createState() => _BoxEditorDialogState();
}

class _BoxEditorDialogState extends State<_BoxEditorDialog> {
  late Map<int, List<QuestionBox>> _boxesByPage;

  /// 按页旋转角度（页 → 角度，§1.6/§1.6.1：不用一个全局值，
  /// 多页/重框不会串页）。
  late Map<int, int> _rotationsByPage;
  late int _currentPage;
  final _donePages = <int>{};
  double _scale = 1.0;
  // B8-345（第 4 项）：滚轮缩放以指针为准，需要在缩放后按新尺寸
  // 调滚动偏移——画布的两个滚动视图各挂一个 controller 供缩放时读/写偏移。
  final _hScrollController = ScrollController();
  final _vScrollController = ScrollController();
  bool _scrollLocked = false;
  bool _suppressDraw = false;

  /// B2-6b(2)：右键画框的单击/拖动区分——按下时只记坐标，不画框也不取消；
  /// 拖出 4px 以上才算拖动（开始画框），抬起时没拖过就是单击（取消）。
  Offset? _rightDownLocal;
  bool _rightDragging = false;

  /// 右键拖动的单击/拖动分界（画布逻辑像素）。
  static const double _rightDragSlop = 4.0;

  /// 真实页图的像素尺寸（异步解码后才知道；未知时按 560×700
  /// 的默认比例排版，解出后按真实比例）。
  ui.Size? _pageImageSize;
  bool _pageImageFailed = false;

  String? _selectedId;
  QuestionBox? _pendingBox;
  Offset? _pendingStart;
  bool _helpOpen = false;
  final _canvasKey = GlobalKey();

  List<QuestionBox> get _boxes =>
      _boxesByPage[_currentPage] ?? const <QuestionBox>[];

  int get _pageRotation => _rotationsByPage[_currentPage] ?? 0;

  /// 当前页底图：多页任务按页取（`pageImagePaths`），没传就用
  /// 单张底图（图片任务 / 重框模式）；画布、检测、尺寸都走它。
  String get _currentPageImagePath =>
      widget.pageImagePaths[_currentPage] ?? widget.pageImagePath;

  int get _totalBoxes {
    var n = 0;
    for (final list in _boxesByPage.values) {
      n += list.length;
    }
    return n;
  }

  bool get _anyOverlap {
    for (final entry in _boxesByPage.entries) {
      final boxes = List.of(entry.value);
      // §1.5.1：重框模式下重叠校验对同页其他题的框也生效。
      if (entry.key == _currentPage) {
        boxes.addAll(widget.readOnlyBoxes);
      }
      if (_hasOverlap(boxes)) return true;
    }
    return false;
  }

  static bool _overlaps(QuestionBox a, QuestionBox b) {
    final overlapX = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x);
    final overlapY = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y);
    return overlapX > 0.001 && overlapY > 0.001;
  }

  static bool _hasOverlap(List<QuestionBox> boxes) {
    for (var i = 0; i < boxes.length; i++) {
      for (var j = i + 1; j < boxes.length; j++) {
        if (_overlaps(boxes[i], boxes[j])) return true;
      }
    }
    return false;
  }

  /// FR-03：当前页重叠的框 id 集（可编辑框 + 只读框 + 正在画的框），
  /// 重叠的框标红用；只算当前页（画布上只画当前页的框）。
  Set<String> get _overlappingBoxIds {
    final boxes = <QuestionBox>[..._boxes, ...widget.readOnlyBoxes];
    final pending = _pendingBox;
    if (pending != null) boxes.add(pending);
    final ids = <String>{};
    for (var i = 0; i < boxes.length; i++) {
      for (var j = i + 1; j < boxes.length; j++) {
        if (_overlaps(boxes[i], boxes[j])) {
          ids.add(boxes[i].id);
          ids.add(boxes[j].id);
        }
      }
    }
    return ids;
  }

  /// FR-03：重叠横幅点名是哪几道框重叠（按画布上的“题级框 N”编号；
  /// 只读框记“同页其他题”）。当前页无重叠但别的页有重叠时，横幅
  /// 指去另一页（旧文案一律写“本页有两道题”是不准的）。
  /// 文案不含“有框重叠了，”前缀（FR-35 到时只剩核对）。
  String _overlapBannerMessage() {
    final ids = _overlappingBoxIds;
    final numbers = <int>[];
    var readOnly = false;
    for (final id in ids) {
      final idx = _boxes.indexWhere((b) => b.id == id);
      if (idx >= 0) {
        numbers.add(idx + 1);
      } else if (widget.readOnlyBoxes.any((b) => b.id == id)) {
        readOnly = true;
      }
    }
    numbers.sort();
    if (numbers.isEmpty && !readOnly) {
      return '另一页的框叠在一起，请切到那一页调开再确认。';
    }
    if (readOnly && numbers.isEmpty) {
      return '同页其他题的框叠在一起，在这里调不开，请取消后去那几道题的详情页重新框选。';
    }
    final nums = numbers.map((n) => '$n').join('、');
    if (readOnly) {
      return '第 $nums 道题的框与同页其他题的框叠在一起，请调开再确认。';
    }
    return '第 $nums 道题的框叠在一起，请调开再确认。';
  }

  @override
  void initState() {
    super.initState();
    _currentPage = widget.page;
    // 只有题级框：旧草稿里混进来的非题级框行直接丢弃，
    // 不进内存态、不随草稿保存写回。
    _boxesByPage = {
      for (final e in widget.initialBoxesByPage.entries)
        e.key: e.value.where((b) => b.layer == 1).toList(),
    };
    _rotationsByPage = Map.of(widget.initialRotations);
    // 草稿模式：本页无任何草稿框才用检测结果；有草稿以草稿为准。
    final hasDraftOnPage =
        (_boxesByPage[widget.page] ?? const <QuestionBox>[]).isNotEmpty;
    if (widget.initialDetected.isNotEmpty && !hasDraftOnPage) {
      _ingestDetected(widget.page, widget.initialDetected);
    }
    _loadPageImageSize();
  }

  /// 异步解码页图拿像素尺寸（只为排版比例；失败时按默认比例，
  /// 画布上出“页图损坏”提示）。切页时重调（各页尺寸可能不同）。
  Future<void> _loadPageImageSize() async {
    final path = _currentPageImagePath;
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      // SR2-37：Codec 用完即 dispose（与 page_image_pipeline._decode /
      // yolo_onnx_service.detectPage 同款 try/finally），否则每次切页
      // 漏一份 native 资源；getNextFrame 抛错时 finally 同样释放。
      try {
        final frame = await codec.getNextFrame();
        final image = frame.image;
        if (!mounted || path != _currentPageImagePath) {
          image.dispose();
          return;
        }
        setState(() {
          _pageImageSize = ui.Size(
            image.width.toDouble(),
            image.height.toDouble(),
          );
          _pageImageFailed = false;
        });
        image.dispose();
      } finally {
        codec.dispose();
      }
    } catch (_) {
      if (mounted && path == _currentPageImagePath) {
        setState(() => _pageImageFailed = true);
      }
    }
  }

  /// 新框的持久 id（§1.2(c)：`box-<scope>-p<page>-<uuid8>`，
  /// uuid8 用 Random.secure() 8 位十六进制，不引入 uuid 包）。
  String _newBoxId() => AppDatabase.newBoxId(widget.taskId, _currentPage);

  /// 检测框的 id 持久化：检测服务给的 `box-q1` 这种 id 会跨页/
  /// 跨任务撞主键，进库前换成持久 id；已是持久格式的
  /// （含 `-p<页>-`，如草稿/重框加载的框）原样保留。
  String _persistedId(QuestionBox b, int page) {
    if (b.id.contains('-p$page-')) return b.id;
    return AppDatabase.newBoxId(widget.taskId, page);
  }

  /// 当前内存态快照（确认 / 草稿保存共用）。
  BoxEditorResult _currentDraft() => BoxEditorResult(
    boxesByPage: {
      for (final e in _boxesByPage.entries) e.key: List.of(e.value),
    },
    rotationsByPage: Map.of(_rotationsByPage),
  );

  Future<void> _saveDraftIfNeeded() async {
    final save = widget.onSaveDraft;
    if (save == null) return;
    await save(_currentDraft());
  }

  /// 检测结果进本页题级框（只接第 1 层；检测服务不再返回别的层）。
  void _ingestDetected(int page, List<QuestionBox> boxes) {
    // 检测输出是量出来的尺寸，只做越界钳制，不补最小尺寸
    // （见 YoloOnnxService.clampToPage 的 minSize 说明）；
    // 进库前先把检测 id（box-q1…）换成持久 id，跨页/跨任务不撞主键。
    final persisted = boxes
        .map((b) => b.copyWith(id: _persistedId(b, page), page: page))
        .toList();
    final clamped = persisted
        .map((b) => YoloOnnxService.clampToPage(b, minSize: false))
        .toList();
    _boxesByPage[page] = clamped.where((b) => b.layer == 1).toList();
  }

  @override
  void dispose() {
    _hScrollController.dispose();
    _vScrollController.dispose();
    super.dispose();
  }

  Future<void> _switchPage(int page) async {
    if (page == _currentPage) return;
    // §1.5：切页时保存当前页草稿（草稿模式；重框模式无保存回调）。
    // SR-P2-31：保存抛错时旧代码直接抛到 onTap，对话框无任何提示；
    // 框还在内存态里，切页不丢框，下次保存再试——只提示，不拦切页。
    try {
      await _saveDraftIfNeeded();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('草稿保存失败：$e，框还在，切回来再试一次')));
      }
    }
    if (!mounted) return;
    setState(() {
      _currentPage = page;
      _selectedId = null;
      _pendingBox = null;
      _pendingStart = null;
      _pageImageSize = null;
      _pageImageFailed = false;
    });
    // 多页任务：切到新页先换底图尺寸，再看这页有没有框——
    // 空页自动检测一次（与首页面打开时的检测同一条路），
    // 失败不弹、不落占位，用户仍可手动框选或点“恢复自动框”。
    _loadPageImageSize();
    await _autoDetectIfEmpty(page);
  }

  /// 草稿模式切页时：目标页一个框都没有，就对这页跑一次检测。
  /// 有草稿框 / 已有框 / 重框模式都不跑；检测失败静默（不落占位框）。
  Future<void> _autoDetectIfEmpty(int page) async {
    if (widget.mode != BoxEditorMode.draft) return;
    if ((_boxesByPage[page] ?? const <QuestionBox>[]).isNotEmpty) return;
    final result = await widget.yoloService.detectPage(
      imagePath: _currentPageImagePath,
      page: page,
    );
    if (!mounted || page != _currentPage) return;
    if (result.usedFallback) return;
    setState(() {
      final rotated = result.boxes
          .map((b) => rotateBoxToRotatedPage(b, _rotationsByPage[page] ?? 0))
          .toList();
      _ingestDetected(page, rotated);
    });
  }

  /// 恢复自动框（§1.5）：按作用域替换，不要追加。
  /// - 草稿模式：替换本页框；本页已有手改过的框时先弹确认；
  /// - 重框模式：只替换目标题的框（与当前框重叠度最大的检测框，
  ///   找不到时提示手动框选）。
  /// 检测在原页上跑、结果是原页坐标：本页已旋转时先做坐标变换
  /// 再进框列表（P2 实施注意 1）。模型失败时不替换、不写占位框，
  /// 只提示手动框选，原有框保持不动。
  Future<void> _restoreAutoBoxes() async {
    if (widget.mode == BoxEditorMode.rework) {
      await _restoreAutoBoxForRework();
      return;
    }
    // 只认手画/手改过的框（origin == 'manual'）：YOLO 框不算手动，
    // 恢复自动框时不弹确认，直接重检替换。只查当前页——_boxes
    // 只是当前页；别页的手画框不该让当前页弹确认（确认后
    // _ingestDetected 也只替换当前页，文案与行为会对不上）。
    final hasManual = _boxes.any((b) => b.origin == 'manual');
    if (hasManual && mounted) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('用自动框替换当前页的手动框？'),
          content: const Text('当前页的框会被 YOLO 重新检测出的框替换，手动改过的框就没了。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('替换'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    final result = await widget.yoloService.detectPage(
      imagePath: _currentPageImagePath,
      page: _currentPage,
    );
    if (!mounted) return;
    if (result.usedFallback) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result.error ?? '自动检测不可用，请手动框选')));
      return;
    }
    setState(() {
      final rotated = result.boxes
          .map((b) => rotateBoxToRotatedPage(b, _pageRotation))
          .toList();
      _ingestDetected(_currentPage, rotated);
      _selectedId = null;
      _pendingBox = null;
    });
  }

  Future<void> _restoreAutoBoxForRework() async {
    final layer1 = List.of(_boxes);
    if (layer1.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('这道题还没有框，请手动框选')));
      return;
    }
    // SR2-20：reworkQuestionId 是题 id（详情页传 q.id），永不等于框 id，
    // 不能拿它跟框 id 比——旧代码只认第一道框，多框题会误报“没找到对应
    // 的题”或把第一道框挪到第二道题的位置上。目标框 = questionId 等
    // 于该题的 1 层框；框上没填 questionId（旧草稿/测试桩）时回退到
    // 全部 1 层框（重框模式下当前页本就只有目标题的框）。
    final targetId = widget.reworkQuestionId;
    final byQuestion = targetId == null
        ? layer1
        : layer1.where((b) => b.questionId == targetId).toList();
    final targets = byQuestion.isEmpty ? layer1 : byQuestion;
    final result = await widget.yoloService.detectPage(
      imagePath: _currentPageImagePath,
      page: _currentPage,
    );
    if (!mounted) return;
    if (result.usedFallback) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result.error ?? '自动检测不可用，请手动框选')));
      return;
    }
    // 逐个目标框做 IoU 匹配：与当前框重叠度最大的检测框才是这道题。
    // 全部候选按 IoU 从大到小贪心认领，每个检测框只用一次，避免两道
    // 题抢到同一个检测框；IoU ≤ 0.3 的不认领（找不到就手动框选）。
    // SR3-13：阈值从 0.05 提到 0.3——0.05 时角上轻微搭边的邻题检测
    // 框就能把目标框拽到邻题位置上；另把候选池里中心落在同页其他题
    // 只读框内的检测框排除（那是邻题的框，重框模式下邻题不是 target，
    // 不参与认领，池子也不应对它开放）。
    final readOnlyLayer1 = List.of(widget.readOnlyBoxes);
    bool centerInReadOnly(QuestionBox b) {
      final cx = b.x + b.w / 2;
      final cy = b.y + b.h / 2;
      return readOnlyLayer1.any(
        (r) => cx >= r.x && cx <= r.x + r.w && cy >= r.y && cy <= r.y + r.h,
      );
    }

    final detected = result.boxes.where((b) => !centerInReadOnly(b)).toList();
    final scored = <({QuestionBox target, QuestionBox picked, double iou})>[];
    for (final target in targets) {
      for (final b in detected) {
        final iou = _iou(target, b);
        if (iou > 0.3) scored.add((target: target, picked: b, iou: iou));
      }
    }
    scored.sort((a, b) => b.iou.compareTo(a.iou));
    final matches = <({QuestionBox target, QuestionBox picked})>[];
    final claimed = <QuestionBox>{};
    for (final s in scored) {
      if (matches.any((m) => m.target.id == s.target.id)) continue;
      if (claimed.contains(s.picked)) continue;
      claimed.add(s.picked);
      matches.add((target: s.target, picked: s.picked));
    }
    if (matches.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没找到对应的检测框（重叠度需超过 0.3），请手动框选')),
      );
      return;
    }
    setState(() {
      final list = _boxesByPage[_currentPage]!;
      for (final m in matches) {
        final target = m.target;
        final picked = m.picked;
        final i = list.indexWhere((b) => b.id == target.id);
        if (i < 0) continue;
        // 只换题级框坐标。
        final newBox = YoloOnnxService.clampToPage(
          picked.copyWith(id: target.id, page: _currentPage),
          minSize: false,
        );
        list[i] = newBox;
      }
      _selectedId = null;
      _pendingBox = null;
    });
    // 有的目标框没找到对应的检测框：已恢复的照常生效，没恢复的留在原位，
    // 提示用户手动框选（而不是整单报“没找到”让用户以为全没恢复）。
    final missed = targets.length - matches.length;
    if (missed > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('有 $missed 道框没找到对应的检测框（重叠度需超过 0.3），已恢复其余框，请手动框选'),
        ),
      );
    }
  }

  static double _iou(QuestionBox a, QuestionBox b) {
    final interX = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x);
    final interY = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y);
    if (interX <= 0 || interY <= 0) return 0.0;
    final inter = interX * interY;
    final union = a.w * a.h + b.w * b.h - inter;
    return union <= 0 ? 0.0 : inter / union;
  }

  void _rotatePage() {
    // 重框模式禁用整页旋转（§1.6）：一题旋转会让同页其他题错位。
    if (widget.mode == BoxEditorMode.rework) return;
    setState(() {
      _rotationsByPage[_currentPage] = (_pageRotation + 90) % 360;
      QuestionBox turn(QuestionBox b) => rotateBoxToRotatedPage(b, 90);
      _boxesByPage[_currentPage] = _boxes.map(turn).toList();
      if (_pendingBox != null) _pendingBox = turn(_pendingBox!);
    });
  }

  void _deleteSelected() {
    setState(() {
      if (_selectedId != null) {
        final id = _selectedId!;
        _boxesByPage[_currentPage] = _boxes.where((b) => b.id != id).toList();
        _selectedId = null;
      }
      _pendingBox = null;
    });
  }

  void _replaceBox(QuestionBox updated) {
    setState(() {
      final list = _boxesByPage[_currentPage]!;
      final i = list.indexWhere((b) => b.id == updated.id);
      // B8-345（第 5 项）：框大小不设限制——只钳制在页内，不补最小尺寸
      //（clampToPage 默认的 0.08 下限不要了，见 minSize: false）。
      if (i >= 0) {
        list[i] = YoloOnnxService.clampToPage(updated, minSize: false);
      }
    });
  }

  /// 按 id 取当前内存态里的框（B8-345，第 3 项）：
  /// 拖动回调闭包里的 box 是上次 build 时的快照——连续两次 move 事件
  /// 可能在同一帧里共用它，增量会被丢一次，拖动就时灵时不灵；
  /// 每次按 id 读最新态，增量不丢。
  QuestionBox? _boxById(String id) {
    for (final b in _boxes) {
      if (b.id == id) return b;
    }
    return null;
  }

  QuestionBox? get _selectedBox =>
      _selectedId == null ? null : _boxById(_selectedId!);

  void _moveBox(String boxId, double dx, double dy, double pw, double ph) {
    final box = _boxById(boxId);
    if (box == null) return;
    _replaceBox(box.movedBy(dx / pw, dy / ph));
  }

  void _resizeBox(
    String boxId,
    double dx,
    double dy,
    String corner,
    double pw,
    double ph,
  ) {
    final box = _boxById(boxId);
    if (box == null) return;
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
    // B8-345（第 5 项）：拖过对边时翻转归一（w/h 恒 ≥ 0），
    // 不靠最小尺寸兜底；只改坐标，其余字段原样保留
    //（以前重建框会丢 confidence/origin/page）。
    if (w < 0) {
      x += w;
      w = -w;
    }
    if (h < 0) {
      y += h;
      h = -h;
    }
    _replaceBox(box.copyWith(x: x, y: y, w: w, h: h));
  }

  bool _pointInBox(Offset p, QuestionBox b, double pw, double ph) =>
      p.dx >= b.x * pw &&
      p.dx <= (b.x + b.w) * pw &&
      p.dy >= b.y * ph &&
      p.dy <= (b.y + b.h) * ph;

  /// B2-6b(2)：该点是否落在可交互的框上（含缩放柄）——左键按下时落在框上
  /// 要锁住滚动（拖框/缩放优先于平移），落在空白处才放行平移。
  /// B8-345：余量取柄命中区的一半（24px 命中目标 → 12px 伸出框外），
  /// 免得点柄时滚动抢走拖动。
  bool _pointHitsInteractive(Offset p, double pw, double ph, double scale) {
    final m = math.max(8 * scale, _handleHitSize / 2);
    bool hit(QuestionBox b) =>
        p.dx >= b.x * pw - m &&
        p.dx <= (b.x + b.w) * pw + m &&
        p.dy >= b.y * ph - m &&
        p.dy <= (b.y + b.h) * ph + m;
    if (_boxes.any(hit)) return true;
    return widget.readOnlyBoxes.any(hit);
  }

  Offset? _canvasLocal(Offset global) {
    final renderBox =
        _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return null;
    return renderBox.globalToLocal(global);
  }

  /// B8-345（第 4 项）：图上滚轮只缩放——把滚轮事件消费掉，
  /// 不让它继续传给滚动视图；图外滚轮仍滚动页面。
  ///
  /// 消费机制：Flutter 的滚轮事件由 PointerSignalResolver 裁决，
  /// 先注册的处理者独占该事件；命中测试按从深到浅分发，这个
  /// Listener 在滚动视图内容里（比两个 SingleChildScrollView 的
  /// Listener 都深），所以先注册、滚动视图收不到该事件。
  /// 指针在图外、或纯横向滚轮（dy == 0）时不注册，事件照常交给
  /// 滚动视图滚动页面。
  void _onWheel(
    PointerSignalEvent event,
    double pw,
    double ph,
    double viewW,
    double viewH,
  ) {
    if (event is! PointerScrollEvent) return;
    // 纯横向滚轮不缩放，让它横向滚动页面。
    if (event.scrollDelta.dy == 0) return;
    final local = _canvasLocal(event.position);
    if (local == null ||
        local.dx < 0 ||
        local.dx > pw ||
        local.dy < 0 ||
        local.dy > ph) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      if (e is PointerScrollEvent) _zoomAtCursor(e, pw, ph, viewW, viewH);
    });
  }

  /// 以鼠标指针为准缩放：缩放前后指针下的页面点
  /// （local/pw 的比例坐标）保持在屏幕同一位置——用滚动偏移补偿
  /// 缩放带来的位移；内容比视口小、无滚动余量的方向补偿不到
  /// （画布在内容里居中），该方向只能近似。
  void _zoomAtCursor(
    PointerScrollEvent event,
    double pw,
    double ph,
    double viewW,
    double viewH,
  ) {
    final local = _canvasLocal(event.position);
    if (local == null) return;
    final fx = (local.dx / pw).clamp(0.0, 1.0);
    final fy = (local.dy / ph).clamp(0.0, 1.0);
    final newScale = (_scale - event.scrollDelta.dy / 1200).clamp(0.5, 3.0);
    if (newScale == _scale) return;
    // 指针在视口中的位置（缩放前）：画布在内容里居中，ox/oy 是画布
    // 在内容里的偏移，滚动偏移是内容相对视口的位移。
    final sx = _hScrollController.hasClients ? _hScrollController.offset : 0.0;
    final sy = _vScrollController.hasClients ? _vScrollController.offset : 0.0;
    final ox = (math.max(pw, viewW) - pw) / 2;
    final oy = (math.max(ph, viewH) - ph) / 2;
    final cursorViewX = ox - sx + local.dx;
    final cursorViewY = oy - sy + local.dy;
    final newPw = pw * newScale / _scale;
    final newPh = ph * newScale / _scale;
    final newCw = math.max(newPw, viewW);
    final newCh = math.max(newPh, viewH);
    final newOx = (newCw - newPw) / 2;
    final newOy = (newCh - newPh) / 2;
    final targetSx = (newOx + fx * newPw - cursorViewX)
        .clamp(0.0, math.max(0.0, newCw - viewW))
        .toDouble();
    final targetSy = (newOy + fy * newPh - cursorViewY)
        .clamp(0.0, math.max(0.0, newCh - viewH))
        .toDouble();
    // 告诉引擎本事件已处理（与 Scrollable 处理滚轮时同款）。
    event.respond(allowPlatformDefault: false);
    setState(() => _scale = newScale);
    // 新尺寸要等下一帧布局完才有，滚动偏移在布局后跳过去。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_hScrollController.hasClients) {
        _hScrollController.jumpTo(targetSx);
      }
      if (_vScrollController.hasClients) {
        _vScrollController.jumpTo(targetSy);
      }
    });
  }

  /// B3：右键拖动画框时起点可以落在已有框上（[fromRightDrag] 为真时
  /// 跳过“起点在框内就不画”的拦下）；框的移动只走左键拖动，右键拖动
  /// 永远是画新框。触摸 / 主按键画框仍走原来的拦下（起点在框内不画）。
  /// FR-04(a)：重框模式禁画新框——只允许移动/缩放既有框，画框入口
  /// 在这里统一拦下（右键拖动与触摸/主按键画框都走这里）。
  void _onDrawStart(
    Offset pos,
    double pw,
    double ph, {
    bool fromRightDrag = false,
  }) {
    if (widget.mode == BoxEditorMode.rework) return;
    // 正在拖旋转/缩放柄时不画框（柄在框外，按下会同时命中画布层）。
    if (_suppressDraw) return;
    if (!fromRightDrag) {
      if (_boxes.any((b) => _pointInBox(pos, b, pw, ph))) return;
    }
    setState(() {
      _pendingStart = Offset(
        (pos.dx / pw).clamp(0.0, 1.0),
        (pos.dy / ph).clamp(0.0, 1.0),
      );
      _pendingBox = QuestionBox(
        id: _newBoxId(),
        layer: 1,
        type: 'question',
        x: _pendingStart!.dx,
        y: _pendingStart!.dy,
        w: 0.01,
        h: 0.01,
        page: _currentPage,
      );
      _selectedId = null;
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
    setState(() {
      _pendingBox = pending.copyWith(
        x: math.min(start.dx, end.dx),
        y: math.min(start.dy, end.dy),
        // B8-345（第 5 项）：画框不设最小尺寸，下限 0（<0.02 的丢弃
        // 在 _onDrawEnd，那是“点一下 vs 拖出框”的手势区分，不是尺寸限制）。
        w: (start.dx - end.dx).abs().clamp(0.0, 1.0),
        h: (start.dy - end.dy).abs().clamp(0.0, 1.0),
      );
    });
  }

  void _onDrawEnd(double pw, double ph) {
    final pending = _pendingBox;
    if (pending == null) return;
    // 只点了一下、没拖出框：当作空白点击，丢弃这次画框。
    if (pending.w < 0.02 || pending.h < 0.02) {
      setState(() {
        _pendingBox = null;
        _pendingStart = null;
      });
      return;
    }
    // 画框直接生成题级框，不再选类型。
    // B8-345（第 5 项）：新画的框也不补最小尺寸，只钳制在页内。
    setState(() {
      final box = YoloOnnxService.clampToPage(pending, minSize: false);
      _boxesByPage[_currentPage] = [..._boxes, box];
      _selectedId = box.id;
      _pendingBox = null;
      _pendingStart = null;
    });
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
    // B2-6b(1)：高度拉到最高——接近视口高（只留 insetPadding 的 24px
    // 上下边距）；画布是 Expanded，随对话框一起变大，不再留大片灰色空位。
    // 以前是 648*scale 封顶，在 1080p 上画布只剩约 480px 高。
    final dialogHeight = size.height - 48;
    final total = _totalBoxes;
    final overlap = _anyOverlap;
    final confirmEnabled = total > 0 && !overlap && _pendingBox == null;
    // FR-34：重框模式确认后回详情页，不去整理、也不拆任务，按钮
    // 按 mode 分支（草稿模式保持原两档文案）。
    final confirmLabel = widget.mode == BoxEditorMode.rework
        ? '确认重新框选'
        : total > 1
        ? '确认修框，拆成 $total 个待整理任务'
        : '确认修框，去整理';
    return Dialog(
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
                  // FR-04(a)：重框模式的操作说明不写画新框（禁画新框）。
                  widget.mode == BoxEditorMode.rework
                      ? '点一下选这道题的框 · 拖框移动 · 拖边/角缩放 · 框只能拖动/缩放，不旋转，也不能再画新框 · 改乱了点「恢复自动框」回到 YOLO 原框 · 两道题的框重叠时确认会被拦下，先调开再确认 · 滚轮在图上以指针为中心缩放（不滚动）、在图外滚动 · 左键拖动平移图片 · 确认只点下方「确认重新框选」按钮'
                      : '点一下选题级框 · 拖框移动 · 拖边/角缩放 · 框只能拖动/缩放，不旋转 · 改乱了点「恢复自动框」回到 YOLO 原框 · 「旋转整页」把整页图片转 90°（框跟着转） · 框的边界按本页图片的实际大小算：图片有多大，画框就多大，拖动 / 缩放 / 新画框都不能超出这张图，框大小不限 · 切页不丢框：每页的框都留着，切回来还在，点「确认修框」才一起提交 · 两道题的框重叠时确认会被拦下，先调开再确认 · 滚轮在图上以指针为中心缩放（不滚动）、在图外滚动 · 左键拖动平移图片 · 右键拖出新框（起点落在框上也能画，不拖框），松开即生成题级框、右键单击取消 · 确认只点下方「确认修框」按钮',
                  style: TextStyle(
                    fontSize: DesignTokens.bodySmallFontSize,
                    color: palette.ink2,
                    height: DesignTokens.bodyLineHeight,
                  ),
                ),
              ),
              if (widget.mode == BoxEditorMode.rework)
                const QmBanner(
                  tone: QmBannerTone.info,
                  title: '重新框选',
                  message:
                      '只改这道题的框：同页其他题的框是只读的，不会动；整页旋转已禁用；取消会丢弃本次修改，不会覆盖原来的框。',
                ),
              if (widget.detectError != null)
                QmBanner(
                  tone: QmBannerTone.warning,
                  title: '自动检测不可用',
                  message: '${widget.detectError}，请手动框选：在画布空白处按住拖出一个框，松开就能继续。',
                ),
              if (_pageImageFailed)
                const QmBanner(
                  tone: QmBannerTone.error,
                  title: '页图损坏',
                  message: '这页的图片解不出来，只能看框的位置对不对；请重新导入这份文件。',
                ),
              if (_boxes.isEmpty)
                QmBanner(
                  tone: QmBannerTone.warning,
                  title: '没框到题',
                  // FR-04(a)：重框模式禁画新框，空框时指去「恢复自动框」
                  // 而不是右键画框（草稿模式保持原提示）。
                  message: widget.mode == BoxEditorMode.rework
                      ? '没框到题，请点「恢复自动框」找回检测框，或取消放弃本次修改'
                      : '没框到题，请用鼠标右键拖一个框：在画布空白处按住拖出一个框，松开就能继续，不用重新导入',
                ),
              if (overlap)
                QmBanner(
                  tone: QmBannerTone.error,
                  title: '框重叠',
                  message: _overlapBannerMessage(),
                ),
              SizedBox(height: 8 * scale),
              _toolbar(scale, palette),
              SizedBox(height: 8 * scale),
              // 画布按页完整显示（HTML 原型：画布完整显示一页题）：
              // 页按 560×700 的比例 fit 进可用区，滚轮在图上缩放再乘 _scale；
              // 框按页面百分比存，fit 不改任何框坐标。
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // 画布按页图真实比例 fit 进可用区（未知尺寸时按
                    // 560×700 默认比例）；本页已旋转 90°/270° 时
                    // 显示宽高互换，框坐标已是旋转后的坐标系。
                    final baseSize =
                        _pageImageSize ??
                        const ui.Size(
                          DesignTokens.collectEditorCanvasWidth,
                          DesignTokens.collectEditorCanvasHeight,
                        );
                    final swapped = _pageRotation == 90 || _pageRotation == 270;
                    final effW = swapped ? baseSize.height : baseSize.width;
                    final effH = swapped ? baseSize.width : baseSize.height;
                    final fit = math.min(
                      constraints.maxWidth / effW,
                      constraints.maxHeight / effH,
                    );
                    final fpw = effW * fit * _scale;
                    final fph = effH * fit * _scale;
                    return _canvas(
                      fpw,
                      fph,
                      scale,
                      palette,
                      constraints.maxWidth,
                      constraints.maxHeight,
                      _overlappingBoxIds,
                    );
                  },
                ),
              ),
              SizedBox(height: 8 * scale),
              _foot(scale, palette, confirmEnabled, confirmLabel),
              SizedBox(height: 8 * scale),
              // SR-P1-8：重框模式只有一页底图（pageCount 恒为 1），
              // 缩略图条按 1..pageCount 只画出“第 1 页”；源页 ≥2 的题
              // 点它会 _switchPage(1)，切到不存在的空页，框消失、
              // 新画的框进 boxesByPage[1]、确认时被详情页丢弃。
              // 重框没有切页意义，直接隐藏整条缩略图条。
              if (widget.mode != BoxEditorMode.rework)
                _thumbStrip(scale, palette),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbar(double scale, AppPalette palette) {
    final hasSelection = _selectedId != null;
    return Row(
      children: [
        Expanded(
          child: Text(
            // FR-04(a)：重框模式禁画新框，工具条不再写“右键拖出新框”。
            widget.mode == BoxEditorMode.rework
                ? '重框模式：只能拖动 / 缩放这道题的框，不能再画新框；左键拖动平移图片'
                : '新增框：右键在图片内空白处拖出框，拖出图片也会夹回图内，松开即生成题级框；左键拖动平移图片',
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
        // §1.6：重框模式禁用整页旋转（一题旋转会让同页其他题错位）。
        if (widget.mode == BoxEditorMode.draft)
          QmButton(
            label: '旋转整页',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: _rotatePage,
          ),
        if (widget.mode == BoxEditorMode.draft) SizedBox(width: 6 * scale),
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
    Set<String> overlappingIds,
  ) {
    // B2-6b(2)：指针按下画布时按情况锁住滚动——画框 / 拖框的手势不再与
    // 滚动视图竞争，抬起后恢复滚动。锁在 pointer-down 时（手势竞技场
    // 裁决前）生效，所以框的 GestureDetector 能正常拿到拖动事件。
    // - 触摸：按下即锁（画框优先），与原来一致；
    // - 鼠标右键：画框，锁；
    // - 鼠标左键：点在框/缩放柄上才锁（拖框/缩放优先）；点在空白处不锁，
    //   交给滚动视图平移图片；点在图外（灰色边距）也不锁，可滚动。
    //
    // B3：右键画框/取消放这里（祖先级 Listener）：画框层在 Stack 里
    // 压在框下面，落在框上的指针到不了它（Stack 的 hit-test 在第一个
    // 命中的子节点就停）；这个 Listener 是画布的祖先，命中路径里一定
    // 有它，起点落在框上、缩放柄上也能收到右键按下/拖动。左键拖框仍
    // 走框自己的 GestureDetector，这里只处理右键，不碰左键。
    return Listener(
      key: const Key('box-editor-canvas'),
      onPointerDown: (event) {
        final renderBox =
            _canvasKey.currentContext?.findRenderObject() as RenderBox?;
        if (renderBox == null) return;
        final local = renderBox.globalToLocal(event.position);
        if (local.dx < 0 || local.dx > pw || local.dy < 0 || local.dy > ph) {
          return;
        }
        final isMouse = event.kind == PointerDeviceKind.mouse;
        if (!isMouse ||
            event.buttons == kSecondaryMouseButton ||
            _pointHitsInteractive(local, pw, ph, scale)) {
          setState(() => _scrollLocked = true);
        }
        if (isMouse && event.buttons == kSecondaryMouseButton) {
          // FR-04(a)：重框模式禁画新框，右键按下不记坐标（_onDrawStart
          // 里还有一道拦下，这里是不让右键拖动进画框状态）。
          if (widget.mode == BoxEditorMode.rework) return;
          // 右键：先只记按下坐标，拖出距离才算画框，
          // 抬起时没拖过就是单击（取消），见 onPointerUp。
          _rightDownLocal = local;
          _rightDragging = false;
        }
      },
      onPointerMove: (event) {
        final down = _rightDownLocal;
        if (down == null) return;
        final local = _canvasLocal(event.position);
        if (local == null) return;
        if (!_rightDragging) {
          if ((local - down).distance < _rightDragSlop) return;
          _rightDragging = true;
          _onDrawStart(down, pw, ph, fromRightDrag: true);
        }
        _onDrawUpdate(local, pw, ph);
      },
      onPointerUp: (_) {
        if (_scrollLocked) setState(() => _scrollLocked = false);
        final down = _rightDownLocal;
        if (down != null) {
          _rightDownLocal = null;
          if (!_rightDragging) {
            // 右键单击 = 取消：原来就没有动作，保持不动。
            _rightDragging = false;
            return;
          }
          _rightDragging = false;
          _onDrawEnd(pw, ph);
        }
      },
      onPointerCancel: (_) {
        if (_scrollLocked) setState(() => _scrollLocked = false);
        _rightDownLocal = null;
        _rightDragging = false;
        _onDrawEnd(pw, ph);
      },
      // B2-6b(2)：左键拖动要能平移图片——Flutter 默认的拖动滚动只认
      // 触摸类设备，鼠标拖动默认不滚动；这里给画布滚动视图显式加上
      // 鼠标（只改修框画布，不动全应用的滚动行为）。
      // B8-345（第 4 项）：滚轮处理从这里搬到滚动视图内容里的
      // Listener（见 _onWheel），外层 Listener 收到时滚动视图已经
      // 先注册了，拦不住滚动。
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: {
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.stylus,
            PointerDeviceKind.invertedStylus,
            PointerDeviceKind.trackpad,
            PointerDeviceKind.unknown,
          },
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          controller: _hScrollController,
          physics: _scrollLocked ? const NeverScrollableScrollPhysics() : null,
          child: SingleChildScrollView(
            controller: _vScrollController,
            physics: _scrollLocked
                ? const NeverScrollableScrollPhysics()
                : null,
            // B8-345（第 4 项）：滚轮 Listener 放在滚动视图内容里
            // （比两个 SingleChildScrollView 的 Listener 都深），
            // 见 _onWheel；图外不注册，滚轮照常滚动页面。
            child: Listener(
              onPointerSignal: (event) => _onWheel(event, pw, ph, viewW, viewH),
              // 页比视口小时居中显示（HTML 原型：画布居中放整页）；
              // 放大超过视口时按页尺寸滚动。角柄浮层与画布平级盖在
              // 最上（Positioned.fill 盖满整个滚动内容，见下）。
              child: SizedBox(
                width: math.max(pw, viewW),
                height: math.max(ph, viewH),
                child: Stack(
                  children: [
                    Align(
                      alignment: Alignment.center,
                      child: SizedBox(
                        width: pw,
                        height: ph,
                        child: Stack(
                          key: _canvasKey,
                          children: [
                            // 真实页图（§1.4/§1.5）：底图是库内页图，不再是占位纸面。
                            // 本页已旋转时图片跟着转（框坐标已是旋转后的坐标系，
                            // 两者对齐）；图片按未旋转的宽高放，旋转后正好占满画布。
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
                              child: _pageImageFailed
                                  ? Align(
                                      alignment: Alignment.bottomCenter,
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 6,
                                        ),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              '页面预览（页图损坏，只看框）',
                                              style: TextStyle(
                                                fontFamily: DesignTokens
                                                    .serifFontFamily,
                                                fontFamilyFallback: DesignTokens
                                                    .serifFontFamilyFallback,
                                                fontSize: DesignTokens
                                                    .bodySmallFontSize,
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
                                    )
                                  : Stack(
                                      children: [
                                        Align(
                                          alignment: Alignment.center,
                                          child: SizedBox(
                                            width:
                                                _pageRotation == 90 ||
                                                    _pageRotation == 270
                                                ? ph
                                                : pw,
                                            height:
                                                _pageRotation == 90 ||
                                                    _pageRotation == 270
                                                ? pw
                                                : ph,
                                            child: Transform.rotate(
                                              angle:
                                                  _pageRotation * math.pi / 180,
                                              child: Image.file(
                                                File(_currentPageImagePath),
                                                fit: BoxFit.fill,
                                              ),
                                            ),
                                          ),
                                        ),
                                        if (_pageRotation != 0)
                                          Align(
                                            alignment: Alignment.bottomCenter,
                                            child: Padding(
                                              padding: const EdgeInsets.only(
                                                bottom: 6,
                                              ),
                                              child: Text(
                                                '整页已旋转 $_pageRotation°（图片和框一起转的）',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w700,
                                                  color: palette.paperInk,
                                                  backgroundColor:
                                                      palette.paper,
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                            ),
                            // 画框层在最下：原始指针事件画框（不走手势竞技场，
                            // 不会被滚动视图抢走）。它只管触摸/手写笔的主按
                            // 键画框——鼠标画框走祖先级画布 Listener（B3：
                            // 落在框上的右键到不了这一层，见 _canvas 开头）。
                            // B2-6b(2)：鼠标左键只拖动（平移图片 / 拖框），
                            // 不画框；画框改右键拖动，右键单击是取消。
                            // 触摸/手写笔没有左右键区分，仍用主按键画框（保持原有行为）。
                            Positioned.fill(
                              child: Listener(
                                behavior: HitTestBehavior.opaque,
                                // B3：右键画框/取消已移到祖先级画布 Listener，
                                // 这里只留触摸/手写笔的主按键画框（落在框上的
                                // 触摸仍到不了这一层，框的点按/拖动不受影响）。
                                onPointerDown: (event) {
                                  if (event.kind == PointerDeviceKind.mouse) {
                                    return;
                                  }
                                  if (event.buttons != kPrimaryMouseButton) {
                                    return;
                                  }
                                  final local = _canvasLocal(event.position);
                                  if (local != null) {
                                    _onDrawStart(local, pw, ph);
                                  }
                                },
                                onPointerMove: (event) {
                                  final local = _canvasLocal(event.position);
                                  if (local == null) return;
                                  _onDrawUpdate(local, pw, ph);
                                },
                                onPointerUp: (_) {
                                  _onDrawEnd(pw, ph);
                                },
                                onPointerCancel: (_) {
                                  _onDrawEnd(pw, ph);
                                },
                                child: const SizedBox.expand(),
                              ),
                            ),
                            for (final box in _boxes)
                              _boxView(
                                box,
                                pw,
                                ph,
                                scale,
                                palette,
                                overlapping: overlappingIds.contains(box.id),
                              ),
                            // §1.5.1：同页其他题的框只读展示（重框模式）。
                            for (final box in widget.readOnlyBoxes)
                              _frozenBoxView(
                                box,
                                pw,
                                ph,
                                scale,
                                palette,
                                label: '其他题 · 只读',
                                overlapping: overlappingIds.contains(box.id),
                              ),
                            if (_pendingBox != null)
                              _pendingBoxView(
                                _pendingBox!,
                                pw,
                                ph,
                                scale,
                                palette,
                                overlapping: overlappingIds.contains(
                                  _pendingBox!.id,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    // B8-345（第 3 项）：选中框的四角缩放柄浮层（画布级，
                    // 与框体平级、画在最上），见 _resizeHandleOverlay。
                    if (_selectedBox != null)
                      Positioned.fill(
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            for (final corner in ['nw', 'ne', 'sw', 'se'])
                              _resizeHandleOverlay(
                                _selectedBox!,
                                corner,
                                pw,
                                ph,
                                (math.max(pw, viewW) - pw) / 2,
                                (math.max(ph, viewH) - ph) / 2,
                                scale,
                                palette,
                              ),
                          ],
                        ),
                      ),
                  ],
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
    final isRework = widget.mode == BoxEditorMode.rework;
    final hint = _pendingBox != null
        ? '正在画框：松开鼠标生成题级框'
        : _selectedId != null
        // FR-04(a)：重框模式底部提示不再写“右键拖动可再画新框”。
        ? isRework
              ? '当前选中：题级框 ${_boxes.indexWhere((b) => b.id == _selectedId) + 1} · 只能拖动 / 缩放，不能再画新框'
              : '当前选中：题级框 ${_boxes.indexWhere((b) => b.id == _selectedId) + 1} · 右键拖动可直接再画一个新框'
        : _boxes.isEmpty
        ? isRework
              ? '没框到题，请点「恢复自动框」找回检测框，或取消'
              : '没框到题，请用鼠标右键拖一个框：在图上拖出框，松开鼠标就能继续'
        : isRework
        ? '本页已框 ${_boxes.length} 道题 · 点框可选中拖动 / 缩放 · 不能再画新框'
        : '本页已框 ${_boxes.length} 道题 · 点框可选中拖动 / 缩放 · 右键拖动可再画新框';
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
          onPressed: () async {
            // §1.5：草稿模式取消先保存草稿（下次“继续修框”恢复）；
            // 重框模式取消直接丢弃本次修改。
            // SR-P2-31：保存抛错时旧代码对话框关不掉、无任何提示；
            // 提示后仍退出（barrierDismissible 为 false，留在这里会
            // 把用户困住；内存态的框随对话框丢弃，下次按上次落盘的
            // 草稿恢复）。
            try {
              await _saveDraftIfNeeded();
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('草稿保存失败：$e，本次修改未保存')));
              }
            }
            if (mounted) Navigator.of(context).pop();
          },
        ),
        SizedBox(width: 8 * scale),
        QmButton(
          label: confirmLabel,
          size: QmButtonSize.small,
          onPressed: confirmEnabled
              ? () => Navigator.of(context).pop(_currentDraft())
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
                // SR-P2-30：_donePages 只是本页装饰态——不校验（0 框也
                // 能打勾）、不进草稿、不随取消保存、确认也不看它；
                // 旧文案「本页修完 ✓」会让用户误以为打勾 = 已保存 /
                // 已确认。只改文案说明它只是本次打开的标记，不改行为。
                label: _donePages.contains(_currentPage)
                    ? '已标记修完（点击取消）'
                    : '标记本页修完',
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
          '每张缩略图下面是页码，点哪页修哪页，打勾只是本次打开的标记：不保存草稿、也不参与确认，切页或取消后标记消失 · 切页不丢框：每页没确认的框都留着，切回来还在，确认后才一起提交',
          style: TextStyle(fontSize: 11.5, color: palette.muted, height: 1.4),
        ),
      ],
    );
  }

  Widget _boxView(
    QuestionBox box,
    double pw,
    double ph,
    double scale,
    AppPalette palette, {
    bool overlapping = false,
  }) {
    final selected = _selectedId == box.id;
    // FR-03：重叠的框标红（优先于选中态的 accent 边，一眼可见）。
    final borderColor = overlapping
        ? palette.errInk
        : selected
        ? palette.accent
        : palette.lineStrong;
    final label =
        '题级框 ${_boxes.indexWhere((b) => b.id == box.id) + 1}'
        '${selected ? ' · 已选中' : ''}';
    return Positioned(
      left: box.x * pw,
      top: box.y * ph,
      width: box.w * pw,
      height: box.h * ph,
      // §6 第 10 条：单框旋转已禁用——框上不再有旋转变换与旋转圆柄，
      // 框只能拖动/缩放；整页旋转走「旋转整页」。
      // B8-345（第 3 项）：四角缩放柄不在这里了，移到画布级浮层
      //（_resizeHandleOverlay），不再嵌在框的 GestureDetector 里。
      child: GestureDetector(
        key: Key('editor-box-${box.id}'),
        onTap: () => setState(() {
          _selectedId = box.id;
        }),
        onPanUpdate: (details) =>
            _moveBox(box.id, details.delta.dx, details.delta.dy, pw, ph),
        child: _boxBody(
          box,
          palette,
          selected,
          borderColor,
          label,
          overlapping: overlapping,
        ),
      ),
    );
  }

  /// 框体：题级框实线边。
  Widget _boxBody(
    QuestionBox box,
    AppPalette palette,
    bool selected,
    Color borderColor,
    String label, {
    bool overlapping = false,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: overlapping
            ? palette.errInk.withValues(alpha: 0.06)
            : selected
            ? palette.accent.withValues(alpha: 0.07)
            : palette.accent.withValues(alpha: 0.02),
        border: Border.all(color: borderColor, width: 2.5),
        borderRadius: BorderRadius.circular(8),
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
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: overlapping
                      ? palette.errInk
                      : selected
                      ? palette.accentText
                      : palette.muted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// B8-345（第 3 项）：角柄命中区边长（视觉仍是 13×scale 居中）。
  /// 柄只有一半在框内时，框外那半以前在命中测试里到不了柄
  /// （RenderBox 命中测试先看框体 bounds）；现在柄移到画布级浮层，
  /// 24px 整个都能点到。
  static const double _handleHitSize = 24.0;

  /// 选中框的四角缩放柄（画布级浮层，单框旋转已禁用，无旋转圆柄，
  /// 见 §6 第 10 条）：
  /// - 与框体平级、画在最上，不嵌在框的 GestureDetector 里——
  ///   拖柄不再与拖框进同一个手势竞技场，也不再被画框层/滚动抢走；
  /// - 命中区 24×24（视觉 13×scale 居中），以角点为中心；
  /// - (ox, oy) 是画布在滚动内容里的偏移（画布居中放，见 _canvas）。
  Widget _resizeHandleOverlay(
    QuestionBox box,
    String corner,
    double pw,
    double ph,
    double ox,
    double oy,
    double scale,
    AppPalette palette,
  ) {
    final hit = _handleHitSize;
    final visual = 13 * scale;
    final cx = ox + (corner.contains('w') ? box.x * pw : (box.x + box.w) * pw);
    final cy = oy + (corner.contains('n') ? box.y * ph : (box.y + box.h) * ph);
    return Positioned(
      left: cx - hit / 2,
      top: cy - hit / 2,
      child: GestureDetector(
        key: Key('editor-resize-$corner-${box.id}'),
        behavior: HitTestBehavior.opaque,
        onPanDown: (_) => _suppressDraw = true,
        onPanEnd: (_) => _suppressDraw = false,
        onPanCancel: () => _suppressDraw = false,
        onPanUpdate: (details) => _resizeBox(
          box.id,
          details.delta.dx,
          details.delta.dy,
          corner,
          pw,
          ph,
        ),
        child: SizedBox(
          width: hit,
          height: hit,
          child: Center(
            child: Container(
              width: visual,
              height: visual,
              decoration: BoxDecoration(
                color: palette.surface,
                border: Border.all(color: palette.accent, width: 2),
                borderRadius: BorderRadius.circular(3 * scale),
              ),
            ),
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
    AppPalette palette, {
    String? label,
    bool overlapping = false,
  }) {
    return Positioned(
      left: box.x * pw,
      top: box.y * ph,
      width: box.w * pw,
      height: box.h * ph,
      child: Opacity(
        opacity: 0.45,
        child: Container(
          decoration: BoxDecoration(
            // FR-03：只读框重叠时同样标红（用户调自己的框错开它）。
            border: Border.all(
              color: overlapping ? palette.errInk : palette.lineStrong,
              width: 2.5,
            ),
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
                    label ?? '只读框',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: overlapping ? palette.errInk : palette.muted,
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
    AppPalette palette, {
    bool overlapping = false,
  }) {
    return Positioned(
      left: box.x * pw,
      top: box.y * ph,
      width: box.w * pw,
      height: box.h * ph,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            // FR-03：正在画的框与已有框重叠时同样标红。
            color: overlapping ? palette.errInk : palette.accent,
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
              '新框',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: overlapping ? palette.errInk : palette.accentText,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

extension _BoxEdit on QuestionBox {
  QuestionBox movedBy(double dx, double dy) => copyWith(x: x + dx, y: y + dy);
}
