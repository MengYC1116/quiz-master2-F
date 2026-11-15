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
import 'package:flutter/services.dart';

import '../../data/database.dart';
import '../../models/models.dart';
import '../../services/page_image_pipeline.dart';
import '../../services/yolo_onnx_service.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/uikit.dart';
import 'collect_widgets.dart';

/// 修框编辑器模式（§1.5）：
/// - draft：收集任务的草稿修框（关闭/取消/切页时保存草稿）；
/// - rework：详情页“重新框选”（只改目标题的框，取消丢弃本次修改；
///   整页旋转禁用，同页其他题的框只读展示）。
enum BoxEditorMode { draft, rework }

/// 修框编辑器的确认结果：各页题级框 + 题内框 + 独立题内框 +
/// 各页旋转角度（确认时按角度烘焙页图，见 §1.6）。
class BoxEditorResult {
  const BoxEditorResult({
    required this.boxesByPage,
    required this.inners,
    required this.standaloneInner,
    required this.rotationsByPage,
  });

  final Map<int, List<QuestionBox>> boxesByPage;
  final Map<String, List<QuestionBox>> inners;
  final Map<int, List<QuestionBox>> standaloneInner;
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
  Map<String, List<QuestionBox>> initialInners = const {},
  Map<int, List<QuestionBox>> initialStandalone = const {},
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
      initialInners: initialInners,
      initialStandalone: initialStandalone,
      initialRotations: initialRotations,
      reworkQuestionId: reworkQuestionId,
      readOnlyBoxes: readOnlyBoxes,
      detectError: detectError,
      yoloService: yoloService ?? YoloOnnxService(),
      onSaveDraft: onSaveDraft,
    ),
  );
}

/// SR-P1-5 / SR-P1-6：修框编辑器入口归一化——两处调用方传进来的
/// 2 层框口径不统一，在这里一次收敛成编辑器内部口径，两处调用方
/// 都不用改：
///
/// - 编辑器内部约定：`_inners` 的键一律是 `'<页>:<题级框id>'`
///   （见 `_innersOf` / `_enterInnerMode` / `_ingestDetected`），
///   1 层框一律在 `boxesByPage`；
/// - 详情页重框（SR-P1-5）按裸 `parentBoxId` 分组传 `initialInners`：
///   裸键按父框所在页补成 `'<页>:<父框id>'`，父框找不到时回退当前页；
///   已带页前缀的键原样保留；
/// - 收集页“继续修框”（SR-P1-6）把 1 层 + 2 层草稿扁平混进
///   `initialBoxesByPage`：2 层框按 `parentBoxId` 拆出——有同页
///   1 层父框的进 `inners`，无主的进 `standaloneInner`；
/// - 同一框 id 在两处出现时只留一份（先到为准），不凭空多框；
/// - 归入 `inners` 的框，其 `parentBoxId` 与键里的父框 id 对齐
///   （入库后 `parent_box_id` 才与键一致，下次读回不再漂移）。
///
/// 返回的三个 map 均为可变副本，调用方传入的 map 不动。
({
  Map<int, List<QuestionBox>> boxesByPage,
  Map<String, List<QuestionBox>> inners,
  Map<int, List<QuestionBox>> standaloneInner,
})
normalizeBoxEditorInputs({
  required Map<int, List<QuestionBox>> boxesByPage,
  required Map<String, List<QuestionBox>> inners,
  required Map<int, List<QuestionBox>> standaloneInner,
  required int currentPage,
}) {
  final normalizedBoxes = <int, List<QuestionBox>>{};
  final normalizedInners = <String, List<QuestionBox>>{};
  final normalizedStandalone = <int, List<QuestionBox>>{};
  // 已收过的 2 层框 id（inners 与 standalone 之间也不重复出现）。
  final seenInnerIds = <String>{};

  void addInner(String key, QuestionBox box) {
    if (!seenInnerIds.add(box.id)) return;
    final parentId = key.split(':').last;
    final aligned = box.parentBoxId == parentId
        ? box
        : box.copyWith(parentBoxId: parentId);
    (normalizedInners[key] ??= []).add(aligned);
  }

  void addStandalone(int page, QuestionBox box) {
    if (!seenInnerIds.add(box.id)) return;
    (normalizedStandalone[page] ??= []).add(box);
  }

  // 1. 1 层框原样保留；混进来的 2 层框按 parentBoxId 归属拆出。
  for (final e in boxesByPage.entries) {
    final page = e.key;
    final layer1Ids = e.value
        .where((b) => b.layer == 1)
        .map((b) => b.id)
        .toSet();
    normalizedBoxes[page] = e.value.where((b) => b.layer == 1).toList();
    for (final b in e.value.where((b) => b.layer != 1)) {
      final parent = b.parentBoxId;
      if (parent != null && layer1Ids.contains(parent)) {
        addInner('$page:$parent', b);
      } else {
        addStandalone(page, b);
      }
    }
  }

  // 2. initialInners 的键归一化：裸键按父框所在页补前缀。
  for (final e in inners.entries) {
    final key = e.key;
    final pagePart = key.split(':').first;
    String normalizedKey;
    if (key.contains(':') && int.tryParse(pagePart) != null) {
      normalizedKey = key;
    } else {
      int? ownerPage;
      for (final pe in normalizedBoxes.entries) {
        if (pe.value.any((b) => b.id == key)) {
          ownerPage = pe.key;
          break;
        }
      }
      normalizedKey = '${ownerPage ?? currentPage}:$key';
    }
    for (final b in e.value) {
      addInner(normalizedKey, b);
    }
  }

  // 3. 独立题内框原样保留（与第 1 步拆出的无主框去重合并）。
  for (final e in standaloneInner.entries) {
    for (final b in e.value) {
      addStandalone(e.key, b);
    }
  }

  return (
    boxesByPage: normalizedBoxes,
    inners: normalizedInners,
    standaloneInner: normalizedStandalone,
  );
}

/// 修框编辑器（覆盖式浮层）：页缩略图条 + 画布；两级框（题级框 +
/// stem / option / figure 内框）。
///
/// HTML 来源：`frameEditorHTML` / `frameHandlesHTML`（交互原型实读）。
/// - 空白处拖动直接画新框，画完在框旁菜单选类型（默认题级框）；
/// - 双击题级框进内框模式（题级框冻结，只改题内框；点画布空白处或
///   按 Esc 退出）；框只能拖动/缩放，**不旋转**（单框旋转已禁用，
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
    this.initialInners = const {},
    this.initialStandalone = const {},
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

  /// 题内框（键 `'<页>:<题级框id>'`）与独立题内框（重框模式传目标题的）。
  final Map<String, List<QuestionBox>> initialInners;
  final Map<int, List<QuestionBox>> initialStandalone;

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
  late Map<String, List<QuestionBox>> _inners;
  late Map<int, List<QuestionBox>> _standaloneInner;

  /// 按页旋转角度（页 → 角度，§1.6/§1.6.1：不用一个全局值，
  /// 多页/重框不会串页）。
  late Map<int, int> _rotationsByPage;
  late int _currentPage;
  final _donePages = <int>{};
  double _scale = 1.0;
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

  /// 按 id 找当前页的 1 层框；找不到返回 null（SR-P2-32：旧代码多处
  /// `firstWhere` 无 `orElse`，外框已被删、内框模式却未退出时抛
  /// StateError 崩溃；正常路径删框时会清内框模式，到不了这里，
  /// 兜底只为不崩）。
  QuestionBox? _layer1ById(String id) {
    for (final b in _boxes) {
      if (b.id == id) return b;
    }
    return null;
  }

  List<QuestionBox> get _standalone =>
      _standaloneInner[_currentPage] ?? const <QuestionBox>[];

  int get _pageRotation => _rotationsByPage[_currentPage] ?? 0;

  /// 当前页底图：多页任务按页取（`pageImagePaths`），没传就用
  /// 单张底图（图片任务 / 重框模式）；画布、检测、尺寸都走它。
  String get _currentPageImagePath =>
      widget.pageImagePaths[_currentPage] ?? widget.pageImagePath;

  int get _totalLayer1 {
    var n = 0;
    for (final list in _boxesByPage.values) {
      n += list.where((b) => b.layer == 1).length;
    }
    return n;
  }

  bool get _anyOverlap {
    for (final entry in _boxesByPage.entries) {
      final layer1 = entry.value.where((b) => b.layer == 1).toList();
      // §1.5.1：重框模式下重叠校验对同页其他题的框也生效。
      if (entry.key == _currentPage) {
        layer1.addAll(widget.readOnlyBoxes.where((b) => b.layer == 1));
      }
      if (_hasOverlap(layer1)) return true;
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
    // SR-P1-5 / SR-P1-6：入口归一化（见 normalizeBoxEditorInputs）——
    // 详情页的裸键 inners 与收集页混进 boxesByPage 的 2 层框都在这里
    // 一次收敛成编辑器内部口径。
    final normalized = normalizeBoxEditorInputs(
      boxesByPage: widget.initialBoxesByPage,
      inners: widget.initialInners,
      standaloneInner: widget.initialStandalone,
      currentPage: widget.page,
    );
    _boxesByPage = normalized.boxesByPage;
    _inners = normalized.inners;
    _standaloneInner = normalized.standaloneInner;
    _rotationsByPage = Map.of(widget.initialRotations);
    // 草稿模式：本页无任何草稿框（1 层、2 层、独立题内框都算）才用
    // 检测结果；有草稿以草稿为准。只看 1 层框会把“只有 2 层框的页”
    // 当成空页，检测结果会把独立题内框覆盖掉。
    final hasDraftOnPage =
        (_boxesByPage[widget.page] ?? const <QuestionBox>[]).isNotEmpty ||
        _inners.keys.any((k) => k.startsWith('${widget.page}:')) ||
        (_standaloneInner[widget.page] ?? const <QuestionBox>[]).isNotEmpty;
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
  /// SR-P1-5 / SR-P1-6：`inners` 的框出编辑器时把 `parentBoxId`
  /// 与键里的父框 id 对齐（编辑器内新建的默认内框没填该字段），
  /// 入库后下次读回仍能按父框归属，不漂移成独立题内框。
  BoxEditorResult _currentDraft() => BoxEditorResult(
    boxesByPage: {
      for (final e in _boxesByPage.entries) e.key: List.of(e.value),
    },
    inners: {
      for (final e in _inners.entries)
        e.key: [
          for (final b in e.value)
            b.parentBoxId == e.key.split(':').last
                ? b
                : b.copyWith(parentBoxId: e.key.split(':').last),
        ],
    },
    standaloneInner: {
      for (final e in _standaloneInner.entries) e.key: List.of(e.value),
    },
    rotationsByPage: Map.of(_rotationsByPage),
  );

  Future<void> _saveDraftIfNeeded() async {
    final save = widget.onSaveDraft;
    if (save == null) return;
    await save(_currentDraft());
  }

  /// 把检测返回的混合框按层拆开：第 1 层进本页题级框，第 2 层按中心点
  /// 归属到所属题级框名下（见 [YoloOnnxService.groupInners]），
  /// 无主的题内框作独立题内框展示。双击进内框模式时已有的题内框
  /// 直接沿用，不再按固定比例凭空造三个框。
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
    final grouped = YoloOnnxService.groupInners(clamped);
    _boxesByPage[page] = clamped.where((b) => b.layer == 1).toList();
    for (final entry in grouped.inners.entries) {
      _inners['$page:${entry.key}'] = entry.value;
    }
    if (grouped.orphans.isNotEmpty) {
      _standaloneInner[page] = grouped.orphans;
    } else {
      _standaloneInner.remove(page);
    }
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
    // SR-P2-32：外框已被删时不进内框模式（旧代码在这里 firstWhere
    // 无 orElse，命中即 StateError）。
    final outer = _layer1ById(boxId);
    if (outer == null) return;
    _inners.putIfAbsent('$_currentPage:$boxId', () {
      return [
        QuestionBox(
          id: _newBoxId(),
          layer: 2,
          type: 'stem',
          x: outer.x + 0.02,
          y: outer.y + 0.02,
          w: outer.w - 0.04,
          h: (outer.h - 0.06) * 0.5,
          page: _currentPage,
        ),
        QuestionBox(
          id: _newBoxId(),
          layer: 2,
          type: 'option',
          x: outer.x + 0.02,
          y: outer.y + 0.02 + (outer.h - 0.06) * 0.52,
          w: outer.w - 0.04,
          h: (outer.h - 0.06) * 0.22,
          page: _currentPage,
        ),
        QuestionBox(
          id: _newBoxId(),
          layer: 2,
          type: 'figure',
          x: outer.x + 0.02,
          y: outer.y + 0.02 + (outer.h - 0.06) * 0.76,
          w: outer.w - 0.04,
          h: (outer.h - 0.06) * 0.22,
          page: _currentPage,
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
      _selectedInnerId = null;
      _innerModeBoxId = null;
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
  /// “有框”按归一化后的三处算（1 层、2 层、独立题内框都算），
  /// 否则只有 2 层框的页会被当成空页，检测结果会把草稿覆盖掉
  /// （与 initState 的首页面判断同款，见 SR-P1-5 / SR-P1-6）。
  Future<void> _autoDetectIfEmpty(int page) async {
    if (widget.mode != BoxEditorMode.draft) return;
    if ((_boxesByPage[page] ?? const <QuestionBox>[]).isNotEmpty) return;
    if (_inners.keys.any((k) => k.startsWith('$page:'))) return;
    if ((_standaloneInner[page] ?? const <QuestionBox>[]).isNotEmpty) {
      return;
    }
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
    // 恢复自动框时不弹确认，直接重检替换。
    // SR-P2-19：只查 1 层框会漏掉手画的题内框——手画的 stem /
    // option / figure 独立内框（同样 origin == 'manual'）不弹确认
    // 就被 _ingestDetected 覆盖掉；_inners 与 _standaloneInner 也要查。
    // SR2-21：但只查当前页——_inners / _standaloneInner 是跨页的 map，
    // _boxes 只是当前页；别页的手画框不该让当前页弹确认（确认后
    // _ingestDetected 也只替换当前页，文案与行为会对不上）。
    bool hasManualIn(List<QuestionBox> boxes) =>
        boxes.any((b) => b.origin == 'manual');
    final hasManual =
        hasManualIn(_boxes) ||
        _inners.entries
            .where((e) => e.key.startsWith('$_currentPage:'))
            .any((e) => hasManualIn(e.value)) ||
        hasManualIn(_standaloneInner[_currentPage] ?? const <QuestionBox>[]);
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
      final oldIds = _boxes.map((b) => b.id).toSet();
      for (final id in oldIds) {
        _inners.remove('$_currentPage:$id');
      }
      _ingestDetected(_currentPage, rotated);
      _selectedId = null;
      _selectedInnerId = null;
      _innerModeBoxId = null;
      _pendingBox = null;
    });
  }

  Future<void> _restoreAutoBoxForRework() async {
    final layer1 = _boxes.where((b) => b.layer == 1).toList();
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
    // 题抢到同一个检测框；IoU ≤ 0.05 的不认领（找不到就手动框选）。
    final detected = result.boxes.where((b) => b.layer == 1).toList();
    final scored = <({QuestionBox target, QuestionBox picked, double iou})>[];
    for (final target in targets) {
      for (final b in detected) {
        final iou = _iou(target, b);
        if (iou > 0.05) scored.add((target: target, picked: b, iou: iou));
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
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('没找到对应的题，请手动框选')));
      return;
    }
    setState(() {
      final list = _boxesByPage[_currentPage]!;
      for (final m in matches) {
        final target = m.target;
        final picked = m.picked;
        final i = list.indexWhere((b) => b.id == target.id);
        if (i < 0) continue;
        // SR-P2-20：只换 1 层框坐标，挂在它下面的旧内框原样保留——新框
        // 移动/缩放后旧内框可能落在新框外，确认后照此入库。按新旧框的
        // 相对位置换算内框（框内相对坐标不变），再用 _clampInner 钳进
        // 新框；旧框无面积时无法换算，直接钳进新框。
        final newBox = YoloOnnxService.clampToPage(
          picked.copyWith(id: target.id, page: _currentPage),
          minSize: false,
        );
        list[i] = newBox;
        final key = '$_currentPage:${target.id}';
        final inners = _inners[key];
        if (inners != null) {
          _inners[key] = inners.map((b) {
            final moved = target.w > 0 && target.h > 0
                ? b.copyWith(
                    x:
                        newBox.x +
                        ((b.x - target.x) / target.w) * newBox.w,
                    y:
                        newBox.y +
                        ((b.y - target.y) / target.h) * newBox.h,
                    w: (b.w / target.w) * newBox.w,
                    h: (b.h / target.h) * newBox.h,
                  )
                : b;
            return _clampInner(moved, newBox);
          }).toList();
        }
      }
      _selectedId = null;
      _selectedInnerId = null;
      _pendingBox = null;
    });
    // 有的目标框没找到对应的检测框：已恢复的照常生效，没恢复的留在原位，
    // 提示用户手动框选（而不是整单报“没找到”让用户以为全没恢复）。
    final missed = targets.length - matches.length;
    if (missed > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('有 $missed 道框没找到对应的检测框，已恢复其余框，请手动框选')),
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
    // 只改坐标，其余字段（来源 / 页码 / 归属）原样保留。
    return box.copyWith(x: x, y: y, w: w, h: h);
  }

  void _replaceBox(QuestionBox updated) {
    setState(() {
      if (updated.layer == 1) {
        final list = _boxesByPage[_currentPage]!;
        final i = list.indexWhere((b) => b.id == updated.id);
        if (i >= 0) list[i] = YoloOnnxService.clampToPage(updated);
      } else if (_innerModeBoxId != null) {
        final key = '$_currentPage:$_innerModeBoxId';
        final list = _inners[key];
        if (list != null) {
          final i = list.indexWhere((b) => b.id == updated.id);
          if (i >= 0) {
            // SR-P2-32：外框已不在时退回页级钳制，不丢这次拖动/缩放。
            final outer = _layer1ById(_innerModeBoxId!);
            list[i] = outer == null
                ? YoloOnnxService.clampToPage(updated)
                : _clampInner(updated, outer);
          }
        }
      } else {
        final list = _standaloneInner[_currentPage] ?? const <QuestionBox>[];
        final i = list.indexWhere((b) => b.id == updated.id);
        if (i >= 0) {
          _standaloneInner[_currentPage] = List.of(list)
            ..[i] = YoloOnnxService.clampToPage(updated);
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
    // 只改坐标，其余字段原样保留（以前重建框会丢 confidence/origin/page）。
    _replaceBox(box.copyWith(x: x, y: y, w: w, h: h));
  }

  void _confirmPendingType(String type) {
    final pending = _pendingBox;
    if (pending == null) return;
    setState(() {
      if (type == 'question') {
        final box = pending.copyWith(
          layer: 1,
          type: 'question',
          page: _currentPage,
        );
        _boxesByPage[_currentPage] = [
          ..._boxes,
          YoloOnnxService.clampToPage(box),
        ];
        _selectedId = box.id;
        _selectedInnerId = null;
      } else {
        final box = pending.copyWith(layer: 2, type: type, page: _currentPage);
        if (_innerModeBoxId != null) {
          final key = '$_currentPage:$_innerModeBoxId';
          // SR-P2-32：外框已不在时当独立题内框收下，不丢这次画框。
          final outer = _layer1ById(_innerModeBoxId!);
          if (outer == null) {
            _standaloneInner[_currentPage] = [
              ..._standalone,
              YoloOnnxService.clampToPage(box),
            ];
          } else {
            _inners[key] = [
              ...(_inners[key] ?? const <QuestionBox>[]),
              _clampInner(box.copyWith(parentBoxId: _innerModeBoxId), outer),
            ];
          }
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
              _clampInner(box.copyWith(parentBoxId: parent.id), parent),
            ];
          } else {
            _standaloneInner[_currentPage] = [
              ..._standalone,
              YoloOnnxService.clampToPage(box),
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

  /// B2-6b(2)：该点是否落在可交互的框上（含缩放柄）——左键按下时落在框上
  /// 要锁住滚动（拖框/缩放优先于平移），落在空白处才放行平移。
  /// 缩放柄伸出框外约 6.5*scale，留 8*scale 余量，免得点柄时滚动抢走拖动。
  bool _pointHitsInteractive(Offset p, double pw, double ph, double scale) {
    final m = 8 * scale;
    bool hit(QuestionBox b) =>
        p.dx >= b.x * pw - m &&
        p.dx <= (b.x + b.w) * pw + m &&
        p.dy >= b.y * ph - m &&
        p.dy <= (b.y + b.h) * ph + m;
    if (_boxes.any(hit)) return true;
    if (_standalone.any(hit)) return true;
    if (_innerModeBoxId != null && _innersOf(_innerModeBoxId!).any(hit)) {
      return true;
    }
    return widget.readOnlyBoxes.any(hit);
  }

  Offset? _canvasLocal(Offset global) {
    final renderBox =
        _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return null;
    return renderBox.globalToLocal(global);
  }

  /// B3：右键拖动画框时起点可以落在已有框上（[fromRightDrag] 为真时
  /// 跳过“起点在框内就不画”的拦下）；框的移动只走左键拖动，右键拖动
  /// 永远是画新框。触摸 / 主按键画框仍走原来的拦下（起点在框内不画）。
  void _onDrawStart(
    Offset pos,
    double pw,
    double ph, {
    bool fromRightDrag = false,
  }) {
    // 正在拖旋转/缩放柄时不画框（柄在框外，按下会同时命中画布层）。
    if (_suppressDraw) return;
    if (_innerModeBoxId != null) {
      // SR-P2-32：外框已不在，退出残留的内框模式，不画框。
      final outer = _layer1ById(_innerModeBoxId!);
      if (outer == null) {
        _exitInnerMode();
        return;
      }
      if (!_pointInBox(pos, outer, pw, ph)) {
        // 内框模式下点题级框外的空白：退出内框模式，不画框。
        _exitInnerMode();
        return;
      }
      if (!fromRightDrag &&
          _innersOf(_innerModeBoxId!).any((b) => _pointInBox(pos, b, pw, ph))) {
        return;
      }
      _pendingInner = true;
    } else {
      if (!fromRightDrag) {
        if (_boxes.any((b) => _pointInBox(pos, b, pw, ph))) return;
        if (_standalone.any((b) => _pointInBox(pos, b, pw, ph))) return;
      }
      _pendingInner = false;
    }
    setState(() {
      _pendingStart = Offset(
        (pos.dx / pw).clamp(0.0, 1.0),
        (pos.dy / ph).clamp(0.0, 1.0),
      );
      _pendingBox = QuestionBox(
        id: _newBoxId(),
        layer: _pendingInner ? 2 : 1,
        type: 'question',
        x: _pendingStart!.dx,
        y: _pendingStart!.dy,
        w: 0.01,
        h: 0.01,
        page: _currentPage,
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
      // SR-P2-32：外框已不在，退出残留的内框模式，不钳制。
      final outer = _layer1ById(_innerModeBoxId!);
      if (outer == null) {
        _exitInnerMode();
        return;
      }
      end = Offset(
        end.dx.clamp(outer.x, outer.x + outer.w),
        end.dy.clamp(outer.y, outer.y + outer.h),
      );
    }
    setState(() {
      _pendingBox = pending.copyWith(
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
      // SR-P2-32：外框已不在，退出残留的内框模式，不钳制。
      final outer = _layer1ById(_innerModeBoxId!);
      if (outer == null) {
        _exitInnerMode();
      } else {
        setState(() => _pendingBox = _clampInner(pending, outer));
      }
    } else {
      setState(() => _pendingBox = YoloOnnxService.clampToPage(pending));
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
    // B2-6b(1)：高度拉到最高——接近视口高（只留 insetPadding 的 24px
    // 上下边距）；画布是 Expanded，随对话框一起变大，不再留大片灰色空位。
    // 以前是 648*scale 封顶，在 1080p 上画布只剩约 480px 高。
    final dialogHeight = size.height - 48;
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
                    '点一下选题级框 · 双击题级框进入内框模式改题内框 · 拖框移动 · 拖边/角缩放 · 框只能拖动/缩放，不旋转 · 改乱了点「恢复自动框」回到 YOLO 原框 · 「旋转整页」把整页图片转 90°（框跟着转） · 框的边界按本页图片的实际大小算：图片有多大，画框就多大，拖动 / 缩放 / 新画框都不能超出这张图；题内框只在它所属的题级框内部 · 切页不丢框：每页的框都留着，切回来还在，点「确认修框」才一起提交 · 两道题的框重叠时确认会被拦下，先调开再确认 · 滚轮在图上缩放、在图外滚动 · 左键拖动平移图片 · 右键拖出新框（起点落在框上也能画，不拖框）、右键单击取消 · 确认只点下方「确认修框」按钮',
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
                    message:
                        '${widget.detectError}，请手动框选：在画布空白处按住拖出一个框，画完选「题级框」就能继续。',
                  ),
                if (_pageImageFailed)
                  const QmBanner(
                    tone: QmBannerTone.error,
                    title: '页图损坏',
                    message: '这页的图片解不出来，只能看框的位置对不对；请重新导入这份文件。',
                  ),
                if (_innerModeBoxId != null)
                  QmBanner(
                    tone: QmBannerTone.info,
                    title: '内框模式',
                    message:
                        '已进入题级框 ${_boxes.indexWhere((b) => b.id == _innerModeBoxId) + 1}：鼠标只选它里面的题干 / 选项 / 配图框，拖动、缩放都只改题内框，题级框已冻结不动 · 点画布空白处、右键单击或按 Esc 退出内框模式',
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
                        '没框到题，请用鼠标右键拖一个框：在画布空白处按住拖出一个框，画完在框旁选「题级框」就能继续，不用重新导入',
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
                      final swapped =
                          _pageRotation == 90 || _pageRotation == 270;
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
                ? '内框模式：点题内框拖动 / 缩放；题内右键拖动可画新框（只在这道题的框内），画完选类型；右键单击退出内框模式'
                : '新增框（先画后选）：右键在图片内空白处拖出框，拖出图片也会夹回图内，画完选类型，默认题级框；左键拖动平移图片',
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
        // SR-P2-21：内框模式下鼠标左键点画布空白处退出内框模式（帮助与
        // 底部提示一直这么承诺，但祖先 Listener 只接右键、画框层又
        // 忽略鼠标，左键点空白没有任何处理）。只在未命中任何可交互
        // 框时退出（复用 _pointHitsInteractive），点框/缩放柄仍是拖动。
        if (isMouse &&
            event.buttons == kPrimaryMouseButton &&
            _innerModeBoxId != null &&
            !_pointHitsInteractive(local, pw, ph, scale)) {
          _exitInnerMode();
        }
        if (isMouse && event.buttons == kSecondaryMouseButton) {
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
            // 右键单击 = 取消：内框模式退出内框模式；
            // 非内框模式下右键单击原来就没有动作，保持不动。
            _rightDragging = false;
            if (_innerModeBoxId != null) {
              _exitInnerMode();
            }
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
      child: Listener(
        onPointerSignal: (event) {
          // B2-6b(2)：滚轮只在指针落在图片上时缩放；落在图外灰色边距时
          // 不处理，事件交给滚动视图，页面上下滚动。
          if (event is PointerScrollEvent) {
            final local = _canvasLocal(event.position);
            if (local == null ||
                local.dx < 0 ||
                local.dx > pw ||
                local.dy < 0 ||
                local.dy > ph) {
              return;
            }
            setState(() {
              _scale = (_scale - event.scrollDelta.dy / 1200).clamp(0.5, 3.0);
            });
          }
        },
        // B2-6b(2)：左键拖动要能平移图片——Flutter 默认的拖动滚动只认
        // 触摸类设备，鼠标拖动默认不滚动；这里给画布滚动视图显式加上
        // 鼠标（只改修框画布，不动全应用的滚动行为）。
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
            physics: _scrollLocked
                ? const NeverScrollableScrollPhysics()
                : null,
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
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_innerModeBoxId == null)
                                          Text(
                                            '页面预览（页图损坏，只看框）',
                                            style: TextStyle(
                                              fontFamily:
                                                  DesignTokens.serifFontFamily,
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
                                          angle: _pageRotation * math.pi / 180,
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
                                              backgroundColor: palette.paper,
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
                              if (event.buttons != kPrimaryMouseButton) return;
                              final local = _canvasLocal(event.position);
                              if (local != null) _onDrawStart(local, pw, ph);
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
                        if (_innerModeBoxId == null) ...[
                          for (final box in _boxes)
                            _boxView(box, pw, ph, scale, palette),
                          for (final box in _standalone)
                            _boxView(box, pw, ph, scale, palette),
                          // §1.5.1：同页其他题的框只读展示（重框模式）。
                          for (final box in widget.readOnlyBoxes)
                            _frozenBoxView(
                              box,
                              pw,
                              ph,
                              scale,
                              palette,
                              label: '其他题 · 只读',
                            ),
                        ] else ...[
                          for (final box in _boxes)
                            _frozenBoxView(box, pw, ph, scale, palette),
                          for (final box in _innersOf(_innerModeBoxId!))
                            _boxView(box, pw, ph, scale, palette),
                          for (final box in widget.readOnlyBoxes)
                            _frozenBoxView(
                              box,
                              pw,
                              ph,
                              scale,
                              palette,
                              label: '其他题 · 只读',
                            ),
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
        ? '内框模式：正在改题级框 ${_boxes.indexWhere((b) => b.id == _innerModeBoxId) + 1} 内的题内框 · 题级框不动 · 点画布空白处、右键单击或按 Esc 退出内框模式'
        : _selectedId != null
        ? '当前选中：题级框 ${_boxes.indexWhere((b) => b.id == _selectedId) + 1} · 双击它进入内框模式改题内框 · 右键拖动可直接再画一个新框，画完再选类型'
        : _boxes.isEmpty
        ? '没框到题，请用鼠标右键拖一个框：在图上拖出框，画完在框旁选「题级框」就能继续'
        : '本页已框 ${_boxes.length} 道题 · 点框可选中拖动 / 缩放 · 双击题级框进内框模式改题内框 · 右键拖动可再画新框';
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
      // §6 第 10 条：单框旋转已禁用——框上不再有旋转变换与旋转圆柄，
      // 框只能拖动/缩放；整页旋转走「旋转整页」。
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
          // 选中框的四角缩放柄（单框旋转已禁用，无旋转圆柄，见 §6 第 10 条）。
          if (selected) ...[
            for (final corner in ['nw', 'ne', 'sw', 'se'])
              _resizeHandle(box, corner, pw, ph, scale, palette),
          ],
        ],
      ),
    );
    if (isInner) {
      return CustomPaint(
        foregroundPainter: DashedDropPainter(
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
    AppPalette palette, {
    String? label,
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
                    label ??
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
  QuestionBox movedBy(double dx, double dy) => copyWith(x: x + dx, y: y + dy);
}
