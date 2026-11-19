// 十四批 M2：配图独立图块——坐标换算、筛选、阅读顺序、裁图、编解码。
//
// 图块是统一内容序列的一种 Block（[FigureBlock]，见
// question_content.dart），带排序位置/锚点，不是追加到题干最后的
// 独立数组。存储仍用 `questions.ocr_figures` TEXT 一列（JSON），
// 每项含：图块 ID、来源切片身份（slice_path + input_hash）、排序信息
// （sequence_index + anchor）、坐标来源（bbox_2d 原值 +
// space_width/space_height + 本次请求的真实转换元数据 +
// 换算后坐标）、裁图相对路径。无图块时 `'[]'`。
//
// 坐标契约（P1-4）：bbox 单位是送入 API 的图像的像素坐标，原点
// 左上角。换算用平移（x_src = x_api − padX，y_src = y_api − padY，
// padX/padY 取**本次 OCR 请求保存的真实值**，不再假定 0.30），再
// clip 到 [0, W]×[0, H]；宽高 < 2px 或零面积弃用；块 width/height
// 应等于本次请求的 req_w/req_h（允差 ±2px），不符 → 视为接口侧
// 缩放/尺寸不一致，不裁图、不猜；元数据与返回块尺寸无法对应时
// 安全弃用图块。
//
// 图块筛选（P1-3）：准入白名单 label=='image' 且 native_label ∈
// {image, figure, illustration, chart, diagram}（以 GLM 实际返回值为
// 准）；排除集 native_label ∈ {header_image, doc_title, logo,
// watermark, page_number, decoration, cover} 一律排除；政治卷 p01
// 的 header_image 块 [57, 50, 177, 170] 是页眉装饰图，不是题目插图。
// 去重：md 图引用与 layout_details image 块 bbox 相同（允差 ±2px）
// 时只生成一个图块，以 layout_details 为准，md 引用只作阅读顺序锚点。
//
// 阅读顺序（P1-3，不只按 y1 猜）：首选 GLM Markdown 图引用位置；
// 备用文本块坐标映射；双栏先分区（横向中线、无块跨中线时才分栏）、
// 栏内 y1、栏间左→右，不做全局 y1 排序；单栏栏内 y1。锚定失败 →
// 图块按 bbox y1 排在内容序列末尾之前、界面明确标为“位置未确认”
// （anchor_source='fallback'），用户可在纠错编辑器里删除该图块
// （删除后回退整题原图）；绝不把位置未确认的图块静默当成已确认顺序展示。
//
// 渲染插入口径（M2 D-120）：`sequence_index` 是图块在阅读顺序中的
// 序号（图块之间）；渲染时按它插入内容序列——md 锚定的图块按 md 引用
// 在全文中的字符位置插入到相邻题干段之间；text 锚定的图块按其在页内
// 的纵向相对位置插入；fallback 图块排在内容序列末尾之前并标
// “位置未确认”。本文件只给排序与锚点，插入实现见 [buildContentBlocks]。

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../services/glm_ocr_client.dart';
import 'question_content.dart';

/// 准入白名单（native_label）：只有这些值才可能是题目配图。
const Set<String> figureAllowedNativeLabels = {
  'image',
  'figure',
  'illustration',
  'chart',
  'diagram',
};

/// 排除集（native_label）：一律排除，不成块、不展示。
const Set<String> figureExcludedNativeLabels = {
  'header_image',
  'doc_title',
  'logo',
  'watermark',
  'page_number',
  'decoration',
  'cover',
};

/// bbox 匹配允差（像素）：md 引用与 layout 块同一图块的判定、
// 块尺寸与请求尺寸的比对都用它。
const double figureBboxTolerancePx = 2.0;

/// 换算后裁图区域（源切片像素坐标，原点左上角）。
class SrcRect {
  const SrcRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;

  Map<String, Object?> toJson() => {
    'x': x,
    'y': y,
    'w': width,
    'h': height,
  };

  static SrcRect? tryParse(Object? value) {
    if (value is! Map) return null;
    final x = value['x'];
    final y = value['y'];
    final w = value['w'];
    final h = value['h'];
    if (x is! num || y is! num || w is! num || h is! num) return null;
    return SrcRect(
      x: x.toInt(),
      y: y.toInt(),
      width: w.toInt(),
      height: h.toInt(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SrcRect &&
      x == other.x &&
      y == other.y &&
      width == other.width &&
      height == other.height;

  @override
  int get hashCode => Object.hash(x, y, width, height);
}

/// 把 API 坐标空间的 bbox 换算到源切片坐标（平移 + clip）。
///
/// - [bbox]：layout_details 块的 bbox_2d 原值 [x1, y1, x2, y2]；
/// - [spaceWidth]/[spaceHeight]：该块所在坐标空间的尺寸（块的
///   width/height）；应等于本次请求的 req_w/req_h（允差 ±2px），
///   不符 → 返回 null（接口侧缩放/尺寸不一致，不裁图、不猜）；
/// - [transform]：本次 OCR 请求保存的真实转换元数据；为 null 或
///   src/req 尺寸非法 → 返回 null（元数据缺失时安全弃用图块）。
///
/// 换算后宽高 < 2px 或零面积 → 返回 null。
SrcRect? convertApiBboxToSrc({
  required List<int> bbox,
  required int? spaceWidth,
  required int? spaceHeight,
  required OcrRequestTransform? transform,
}) {
  if (bbox.length != 4) return null;
  if (transform == null) return null;
  if (transform.srcW <= 0 ||
      transform.srcH <= 0 ||
      transform.reqW <= 0 ||
      transform.reqH <= 0) {
    return null;
  }
  if (spaceWidth == null ||
      spaceHeight == null ||
      (spaceWidth - transform.reqW).abs() > figureBboxTolerancePx ||
      (spaceHeight - transform.reqH).abs() > figureBboxTolerancePx) {
    return null;
  }
  var x1 = bbox[0] - transform.padX;
  var y1 = bbox[1] - transform.padY;
  var x2 = bbox[2] - transform.padX;
  var y2 = bbox[3] - transform.padY;
  // clip 到 [0, W]×[0, H]。
  x1 = x1.clamp(0, transform.srcW);
  y1 = y1.clamp(0, transform.srcH);
  x2 = x2.clamp(0, transform.srcW);
  y2 = y2.clamp(0, transform.srcH);
  final w = x2 - x1;
  final h = y2 - y1;
  if (w < 2 || h < 2) return null;
  return SrcRect(x: x1, y: y1, width: w, height: h);
}

/// 一个配图图块（`questions.ocr_figures` JSON 数组里的一项）。
class OcrFigure {
  const OcrFigure({
    required this.id,
    required this.slicePath,
    required this.inputHash,
    required this.sequenceIndex,
    required this.anchorSource,
    required this.anchorRef,
    required this.bbox2d,
    required this.spaceWidth,
    required this.spaceHeight,
    required this.transform,
    required this.srcRect,
    required this.cropPath,
  });

  /// 图块 ID：`figure-<qid>-<index>`（index 为阅读顺序号）。
  final String id;

  /// 来源切片身份：裁图时的 slice_path + 产出该 OCR 包的切片 SHA-256。
  final String slicePath;
  final String? inputHash;

  /// 排序信息：阅读顺序号 + 锚点（锚定来源 md 引用序号或最近文本块
  /// id + 锚定方式 md/text/fallback）。
  final int sequenceIndex;

  /// 锚定方式：'md' | 'text' | 'fallback'。
  final String anchorSource;

  /// 锚点引用：md 锚定时为 md 引用序号（字符串化的整数）；
  /// text 锚定时为最近文本块 id（`text-<layout index>`）；
  /// fallback 时为 ''。
  final String anchorRef;

  /// 坐标来源：bbox_2d 原值 + 该块所在坐标空间尺寸。
  final List<int> bbox2d;
  final int? spaceWidth;
  final int? spaceHeight;

  /// 本次请求的真实转换元数据（src_w/src_h、req_w/req_h、padX、padY；
  /// 未加白边时 padX=padY=0）。不再保存固定的 padding_fraction 0.30。
  final OcrRequestTransform transform;

  /// 换算后坐标（源切片像素坐标）。
  final SrcRect srcRect;

  /// 裁图相对路径（`slices/<qid>-fig-v<ts>-<rand>.png`）。
  final String cropPath;

  /// 是否位置未确认（锚定失败的图块，界面必须明确标注）。
  bool get unconfirmed => anchorSource == 'fallback';

  /// 该图块是否属于当前切片（展示层按 input_hash 与当前切片 hash
  /// 比对，不一致不展示；inputHash 为空的遗留图块只比 slice_path）。
  bool isCurrentFor({required String? slicePath, required String? inputHash}) {
    if (this.slicePath != slicePath) return false;
    if (this.inputHash == null || inputHash == null) return true;
    return this.inputHash == inputHash;
  }

  OcrFigure copyWith({int? sequenceIndex, String? cropPath}) => OcrFigure(
    id: id,
    slicePath: slicePath,
    inputHash: inputHash,
    sequenceIndex: sequenceIndex ?? this.sequenceIndex,
    anchorSource: anchorSource,
    anchorRef: anchorRef,
    bbox2d: bbox2d,
    spaceWidth: spaceWidth,
    spaceHeight: spaceHeight,
    transform: transform,
    srcRect: srcRect,
    cropPath: cropPath ?? this.cropPath,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'slice_path': slicePath,
    if (inputHash != null) 'input_hash': inputHash,
    'sequence_index': sequenceIndex,
    'anchor_source': anchorSource,
    'anchor_ref': anchorRef,
    'bbox_2d': bbox2d,
    if (spaceWidth != null) 'space_width': spaceWidth,
    if (spaceHeight != null) 'space_height': spaceHeight,
    'transform': transform.toJson(),
    'src_rect': srcRect.toJson(),
    'crop_path': cropPath,
  };

  static OcrFigure? tryParse(Object? value) {
    if (value is! Map) return null;
    try {
      final id = value['id'];
      final slicePath = value['slice_path'];
      final sequenceIndex = value['sequence_index'];
      final anchorSource = value['anchor_source'];
      final anchorRef = value['anchor_ref'];
      final bbox = value['bbox_2d'];
      final transform = OcrRequestTransform.tryParse(value['transform']);
      final srcRect = SrcRect.tryParse(value['src_rect']);
      final cropPath = value['crop_path'];
      if (id is! String ||
          slicePath is! String ||
          sequenceIndex is! num ||
          anchorSource is! String ||
          anchorRef is! String ||
          bbox is! List ||
          transform == null ||
          srcRect == null ||
          cropPath is! String) {
        return null;
      }
      final bboxInts = <int>[];
      for (final e in bbox) {
        if (e is! num) return null;
        bboxInts.add(e.toInt());
      }
      if (bboxInts.length != 4) return null;
      final spaceWidth = value['space_width'];
      final spaceHeight = value['space_height'];
      final inputHash = value['input_hash'];
      return OcrFigure(
        id: id,
        slicePath: slicePath,
        inputHash: inputHash is String ? inputHash : null,
        sequenceIndex: sequenceIndex.toInt(),
        anchorSource: anchorSource,
        anchorRef: anchorRef,
        bbox2d: bboxInts,
        spaceWidth: spaceWidth is num ? spaceWidth.toInt() : null,
        spaceHeight: spaceHeight is num ? spaceHeight.toInt() : null,
        transform: transform,
        srcRect: srcRect,
        cropPath: cropPath,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 解析 `questions.ocr_figures` JSON（非法/空 → []，不抛）。
List<OcrFigure> parseOcrFigures(String? json) {
  if (json == null || json.isEmpty) return const [];
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return const [];
    final out = <OcrFigure>[];
    for (final item in decoded) {
      final fig = OcrFigure.tryParse(item);
      if (fig != null) out.add(fig);
    }
    out.sort((a, b) => a.sequenceIndex.compareTo(b.sequenceIndex));
    return out;
  } catch (_) {
    return const [];
  }
}

/// 编码图块列表（无图块时 `'[]'`）。
String encodeOcrFigures(List<OcrFigure> figures) =>
    jsonEncode([for (final f in figures) f.toJson()]);

/// 图块列表里的全部裁图相对路径（孤儿清理引用集合与备份清单用）。
Set<String> figureCropPaths(List<OcrFigure> figures) =>
    {for (final f in figures) f.cropPath};

/// 两组图块是否相同（比较内容身份，不比较 crop_path——每次写图块
/// 文件名都带新时间戳，路径必然不同；只比较 bbox/换算坐标/顺序/锚点）。
/// worker 自动应用与候选接受共用：内容没变时不重写图块文件、不递增版本。
bool sameFiguresIgnoringCrop(List<OcrFigure> a, List<OcrFigure> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i];
    final y = b[i];
    if (x.sequenceIndex != y.sequenceIndex ||
        x.anchorSource != y.anchorSource ||
        x.anchorRef != y.anchorRef ||
        x.srcRect != y.srcRect ||
        x.bbox2d.length != y.bbox2d.length) {
      return false;
    }
    for (var j = 0; j < x.bbox2d.length; j++) {
      if (x.bbox2d[j] != y.bbox2d[j]) return false;
    }
  }
  return true;
}

/// 图块裁图文件名：`slices/<qid>-fig-<figureId>-v<ts>-<rand>.png`
/// （与切片同目录，JSON 里只存相对路径，不存绝对路径）。
///
/// - [figureId]：图块 ID（如 `figure-<qid>-<index>`），进文件名是
///   为了让同一题的每张图块路径必然不同、且替换写新文件时不撞旧记录
///   正在引用的路径（M5 修复轮 2，GPT fix1 窄审 §3.1 问题 A：只含
///   时间戳+随机数时，同一毫秒 + 随机数巧合撞上会使后一次 rename
///   静默覆盖前一次）；不传时保持旧形状 `slices/<qid>-fig-v<ts>-<rand>.png`。
/// - 时间戳+随机数仍保留：同一图块多次重写也各得新路径，旧文件在
///   数据库事务提交前不被覆盖；writeFigureFiles() 在 rename 前另有
///   “目标已存在则重算”兜底。
String figureCropFileName(
  String questionId, {
  String? figureId,
  int? timestampMs,
  int? random,
}) {
  final ts = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
  final rand = random ?? math.Random().nextInt(1 << 32);
  final tag = figureId == null || figureId.isEmpty
      ? 'fig'
      : 'fig-$figureId';
  return 'slices/$questionId-$tag-v$ts-$rand.png';
}

/// layout_details 里的一个块（内部结构，不外露）。
class _LayoutBlock {
  const _LayoutBlock({
    required this.page,
    required this.index,
    required this.label,
    required this.nativeLabel,
    required this.bbox,
    required this.spaceWidth,
    required this.spaceHeight,
    required this.content,
  });

  final int page;
  final int index;
  final String label;
  final String nativeLabel;
  final List<int> bbox;
  final int? spaceWidth;
  final int? spaceHeight;
  final String content;

  int get x1 => bbox[0];
  int get y1 => bbox[1];
  int get x2 => bbox[2];
  int get y2 => bbox[3];
  int get centerX => (bbox[0] + bbox[2]) ~/ 2;
  int get centerY => (bbox[1] + bbox[3]) ~/ 2;
}

List<_LayoutBlock> _layoutBlocks(List<Object?> layoutDetails) {
  final out = <_LayoutBlock>[];
  for (var p = 0; p < layoutDetails.length; p++) {
    final page = layoutDetails[p];
    if (page is! List) continue;
    for (var i = 0; i < page.length; i++) {
      final block = page[i];
      if (block is! Map) continue;
      final bbox = block['bbox_2d'];
      if (bbox is! List || bbox.length != 4) continue;
      final nums = <int>[];
      var ok = true;
      for (final e in bbox) {
        if (e is num) {
          nums.add(e.toInt());
        } else {
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      final label = block['label'];
      final nativeLabel = block['native_label'];
      final width = block['width'];
      final height = block['height'];
      final content = block['content'];
      out.add(
        _LayoutBlock(
          page: p,
          index: block['index'] is num
              ? (block['index'] as num).toInt()
              : i,
          label: label is String ? label : '',
          nativeLabel: nativeLabel is String ? nativeLabel : '',
          bbox: nums,
          spaceWidth: width is num ? width.toInt() : null,
          spaceHeight: height is num ? height.toInt() : null,
          content: content is String ? content : '',
        ),
      );
    }
  }
  return out;
}

/// md 全文里的图引用（按出现顺序）：`![](page=<n>,bbox=[x1, y1, x2, y2])`。
class _MdFigureRef {
  const _MdFigureRef({
    required this.order,
    required this.page,
    required this.bbox,
    required this.offset,
  });

  final int order;
  final int page;
  final List<int> bbox;

  /// 该引用在 md 全文中的字符偏移（阅读顺序锚点用）。
  final int offset;
}

List<_MdFigureRef> _mdFigureRefs(String md) {
  final pattern = RegExp(
    r'!\[.*?\]\(page=(\d+),bbox=\[(\d+),\s*(\d+),\s*(\d+),\s*(\d+)\]\)',
  );
  final out = <_MdFigureRef>[];
  var order = 0;
  for (final m in pattern.allMatches(md)) {
    out.add(
      _MdFigureRef(
        order: order++,
        page: int.parse(m.group(1)!),
        bbox: [
          int.parse(m.group(2)!),
          int.parse(m.group(3)!),
          int.parse(m.group(4)!),
          int.parse(m.group(5)!),
        ],
        offset: m.start,
      ),
    );
  }
  return out;
}

bool _bboxMatches(List<int> a, List<int> b) {
  for (var i = 0; i < 4; i++) {
    if ((a[i] - b[i]).abs() > figureBboxTolerancePx) return false;
  }
  return true;
}

/// 文本块阅读顺序：先按版面区域分区——以页面横向中线分栏，但只有
/// 没有任何文本块跨中线时才真正分栏（否则当单栏）；栏内按 y1 排序，
/// 栏间按左栏 → 右栏拼接；不做全局 y1 排序。
List<_LayoutBlock> _readingOrderTextBlocks(
  List<_LayoutBlock> textBlocks,
  int pageWidth,
) {
  if (textBlocks.isEmpty) return const [];
  final midX = pageWidth ~/ 2;
  final crossesMidline = textBlocks.any(
    (b) => b.x1 < midX && b.x2 > midX,
  );
  final sorted = [...textBlocks]..sort((a, b) {
    if (a.page != b.page) return a.page.compareTo(b.page);
    return a.y1.compareTo(b.y1);
  });
  if (crossesMidline) return sorted;
  final left = sorted.where((b) => b.centerX < midX).toList();
  final right = sorted.where((b) => b.centerX >= midX).toList();
  return [...left, ...right];
}

class _FigureCandidate {
  _FigureCandidate({
    required this.block,
    required this.srcRect,
    this.mdOrder,
    this.mdOffset,
    this.textAnchorId,
    this.textAnchorOrder,
  });

  final _LayoutBlock block;
  final SrcRect srcRect;

  /// md 锚定：md 引用序号与字符偏移（无 md 引用时为 null）。
  final int? mdOrder;
  final int? mdOffset;

  /// 文本块锚定：最近文本块 id 与它在阅读顺序中的位置。
  final String? textAnchorId;
  final int? textAnchorOrder;
}

/// 从一次 OCR 结果包派生图块列表（不含裁图文件写入；裁图见
/// figure_files.dart）。
///
/// - [questionId]：图块 ID 用（`figure-<qid>-<index>`）；
/// - [raw]：OCR 结果包（md_results + layout_details）；
/// - [transform]：本次 OCR 请求的真实转换元数据（来自 raw 包的
///   `transform` 键；调用方须先从 raw 里取，取不到时传 null，
///   此时全部图块安全弃用——元数据缺失不猜坐标）；
/// - [slicePath]/[inputHash]：来源切片身份。
///
/// 无准入 image 块时返回空列表，不生成占位块。
List<OcrFigure> buildOcrFigures({
  required String questionId,
  required GlmOcrRawData raw,
  required OcrRequestTransform? transform,
  required String slicePath,
  required String? inputHash,
}) {
  if (transform == null) return const [];
  final blocks = _layoutBlocks(raw.layoutDetails);
  final images = blocks.where((b) {
    if (b.label != 'image') return false;
    if (figureExcludedNativeLabels.contains(b.nativeLabel)) return false;
    return figureAllowedNativeLabels.contains(b.nativeLabel);
  }).toList();
  if (images.isEmpty) return const [];
  final mdRefs = _mdFigureRefs(raw.mdResults);
  final textBlocks = blocks.where((b) => b.label == 'text').toList();
  // 文本块阅读顺序（分栏判定用页宽：取文本块所在空间的最大 width，
  // 取不到时用最大 x2）。
  var pageWidth = 0;
  for (final b in textBlocks) {
    if (b.spaceWidth != null && b.spaceWidth! > pageWidth) {
      pageWidth = b.spaceWidth!;
    }
  }
  if (pageWidth <= 0) {
    for (final b in textBlocks) {
      if (b.x2 > pageWidth) pageWidth = b.x2;
    }
  }
  final orderedTexts = _readingOrderTextBlocks(textBlocks, pageWidth);
  final textOrderById = <String, int>{
    for (var i = 0; i < orderedTexts.length; i++)
      'text-${orderedTexts[i].index}': i,
  };

  final candidates = <_FigureCandidate>[];
  for (final block in images) {
    final srcRect = convertApiBboxToSrc(
      bbox: block.bbox,
      spaceWidth: block.spaceWidth,
      spaceHeight: block.spaceHeight,
      transform: transform,
    );
    if (srcRect == null) continue;
    // 去重：md 图引用与 layout 块 bbox 相同（±2px）时只生成一个
    // 图块，以 layout 块为准，md 引用只作阅读顺序锚点。
    _MdFigureRef? mdRef;
    for (final ref in mdRefs) {
      if (ref.page == block.page && _bboxMatches(ref.bbox, block.bbox)) {
        mdRef = ref;
        break;
      }
    }
    String? textAnchorId;
    int? textAnchorOrder;
    if (mdRef == null && orderedTexts.isNotEmpty) {
      // 备用锚定：文本块坐标映射——找同一栏内、图块上方最近的文本块；
      // 上方没有时找下方最近的。栏用中心 x 与页中线判定（与阅读顺序
      // 同款分栏口径：有块跨中线时当单栏，不分栏比较）。
      final midX = pageWidth ~/ 2;
      final crossesMidline = textBlocks.any(
        (b) => b.x1 < midX && b.x2 > midX,
      );
      _LayoutBlock? best;
      var bestGap = 1 << 30;
      for (final text in orderedTexts) {
        if (text.page != block.page) continue;
        if (!crossesMidline) {
          final sameSide =
              (text.centerX < midX) == (block.centerX < midX);
          if (!sameSide) continue;
        }
        // 上方块：gap = 图块 y1 − 文本 y2（≥0）；下方块：gap = 文本 y1 − 图块 y2。
        final gapAbove = block.y1 - text.y2;
        final gapBelow = text.y1 - block.y2;
        final gap = gapAbove >= 0
            ? gapAbove
            : (gapBelow >= 0 ? gapBelow + 1000000 : 1 << 29);
        if (gap < bestGap) {
          bestGap = gap;
          best = text;
        }
      }
      if (best != null) {
        textAnchorId = 'text-${best.index}';
        textAnchorOrder = textOrderById[textAnchorId];
      }
    }
    candidates.add(
      _FigureCandidate(
        block: block,
        srcRect: srcRect,
        mdOrder: mdRef?.order,
        mdOffset: mdRef?.offset,
        textAnchorId: textAnchorId,
        textAnchorOrder: textAnchorOrder,
      ),
    );
  }
  // 排序：md 锚定的按 md 引用顺序；text 锚定的按最近文本块的阅读顺序；
  // fallback 的按 bbox y1 排在末尾之前（本函数返回的列表里 fallback
  // 在最后；渲染时它们排在内容序列末尾之前并标“位置未确认”）。
  candidates.sort((a, b) {
    int rank(_FigureCandidate c) =>
        c.mdOrder != null ? 0 : (c.textAnchorId != null ? 1 : 2);
    final ra = rank(a);
    final rb = rank(b);
    if (ra != rb) return ra.compareTo(rb);
    if (ra == 0) return a.mdOrder!.compareTo(b.mdOrder!);
    if (ra == 1) {
      final cmp = a.textAnchorOrder!.compareTo(b.textAnchorOrder!);
      if (cmp != 0) return cmp;
    }
    return a.block.y1.compareTo(b.block.y1);
  });
  final figures = <OcrFigure>[];
  for (var i = 0; i < candidates.length; i++) {
    final c = candidates[i];
    final anchorSource = c.mdOrder != null
        ? 'md'
        : (c.textAnchorId != null ? 'text' : 'fallback');
    final anchorRef = c.mdOrder != null
        ? '${c.mdOrder}'
        : (c.textAnchorId ?? '');
    figures.add(
      OcrFigure(
        id: 'figure-$questionId-$i',
        slicePath: slicePath,
        inputHash: inputHash,
        sequenceIndex: i,
        anchorSource: anchorSource,
        anchorRef: anchorRef,
        bbox2d: c.block.bbox,
        spaceWidth: c.block.spaceWidth,
        spaceHeight: c.block.spaceHeight,
        transform: transform,
        srcRect: c.srcRect,
        cropPath: '',
      ),
    );
  }
  return figures;
}

/// 按 [SrcRect] 从切片字节里裁出图块 PNG（解不出图或区域非法时
/// 返回 null，不抛异常）。
Uint8List? cropFigurePng({
  required Uint8List sliceBytes,
  required SrcRect rect,
}) {
  final src = img.decodeImage(sliceBytes);
  if (src == null) return null;
  if (rect.x < 0 ||
      rect.y < 0 ||
      rect.width < 2 ||
      rect.height < 2 ||
      rect.x + rect.width > src.width ||
      rect.y + rect.height > src.height) {
    return null;
  }
  try {
    final cropped = img.copyCrop(
      src,
      x: rect.x,
      y: rect.y,
      width: rect.width,
      height: rect.height,
    );
    return img.encodePng(cropped);
  } catch (_) {
    return null;
  }
}

/// 展示层取当前切片的图块：只返回与当前 slice_path + input_hash
/// 一致的图块；旧图块不展示。返回 `(figures, hasStale)`——
/// `hasStale` 为 true 表示库里有图块但没有一张属于当前切片
/// （重框后新 OCR 完成前，图块区显示“已重新框选，等待识别”）。
({List<OcrFigure> figures, bool hasStale}) currentFiguresForDisplay(
  List<OcrFigure> stored, {
  required String? slicePath,
  required String? inputHash,
}) {
  if (stored.isEmpty) return (figures: const [], hasStale: false);
  final current = stored
      .where((f) => f.isCurrentFor(slicePath: slicePath, inputHash: inputHash))
      .toList();
  return (figures: current, hasStale: current.isEmpty);
}

/// 把图块按阅读顺序插入题干内容段（渲染用；见文件头“渲染插入口径”）。
///
/// - md 锚定的图块：按 md 引用在全文中的字符位置，插入到相邻题干段
///   之间（题干文本在 md 全文中的起始位置由题干首段定位）；
/// - text 锚定的图块：按其在页内的纵向相对位置插入（图块中心 y /
///   页高 × 段数，钳制在段范围内）；
/// - fallback 图块：排在内容序列末尾之前（即最后一段之前没有时排
///   最后），[FigureBlock.unconfirmed] 为 true，界面标“位置未确认”。
List<QuestionContentBlock> buildContentBlocks({
  required String stemMarkdown,
  required List<OcrFigure> figures,
  required String? mdResults,
}) {
  final blocks = parseQuestionContent(stemMarkdown);
  if (figures.isEmpty) return blocks;
  // 题干段的字符累计长度（按拼回文本计，用于 md 偏移映射）。
  final blockTextLengths = <int>[];
  for (final b in blocks) {
    blockTextLengths.add(switch (b) {
      TextBlock(:final text) => text.length,
      FormulaBlock(:final latex, :final displayMode) =>
        latex.length + (displayMode ? 4 : 2),
      CodeBlock(:final code) => code.length + 6,
      ImageFallbackBlock() => 0,
      FigureBlock() => 0,
    });
  }
  int stemStartInMd = -1;
  if (mdResults != null && mdResults.isNotEmpty) {
    // 题干首段（去空白后前 40 字）在 md 全文中的位置。
    final firstText = blocks
        .whereType<TextBlock>()
        .map((b) => b.text.trim())
        .firstWhere((t) => t.isNotEmpty, orElse: () => '');
    if (firstText.length >= 8) {
      stemStartInMd = mdResults.indexOf(
        firstText.substring(0, math.min(40, firstText.length)),
      );
    } else if (firstText.isNotEmpty) {
      stemStartInMd = mdResults.indexOf(firstText);
    }
  }
  // 每个图块的插入下标（插入到该下标的段之前；== blocks.length 表示末尾）。
  final insertions = <({int at, OcrFigure figure})>[];
  for (final fig in figures) {
    var at = blocks.length;
    if (fig.anchorSource == 'md' && mdResults != null && stemStartInMd >= 0) {
      final refOffset = _mdOffsetForFigure(mdResults, fig);
      if (refOffset != null) {
        final rel = refOffset - stemStartInMd;
        var acc = 0;
        at = blocks.length;
        for (var i = 0; i < blocks.length; i++) {
          acc += blockTextLengths[i];
          if (rel <= acc) {
            at = i + 1;
            break;
          }
        }
      }
    } else if (fig.anchorSource == 'text') {
      final pageH = fig.spaceHeight ?? 0;
      if (pageH > 0 && blocks.isNotEmpty) {
        final ratio =
            (fig.srcRect.y + fig.srcRect.height / 2) / pageH;
        at = (ratio * blocks.length).floor().clamp(0, blocks.length);
      }
    }
    // fallback：at 保持末尾。
    insertions.add((at: at, figure: fig));
  }
  // 同一位置的多个图块保持 sequence_index 顺序。
  insertions.sort((a, b) {
    final cmp = a.at.compareTo(b.at);
    if (cmp != 0) return cmp;
    return a.figure.sequenceIndex.compareTo(b.figure.sequenceIndex);
  });
  final out = <QuestionContentBlock>[];
  var nextInsert = 0;
  for (var i = 0; i <= blocks.length; i++) {
    while (nextInsert < insertions.length &&
        insertions[nextInsert].at == i) {
      final fig = insertions[nextInsert].figure;
      out.add(
        FigureBlock(
          figureId: fig.id,
          cropPath: fig.cropPath,
          unconfirmed: fig.unconfirmed,
        ),
      );
      nextInsert++;
    }
    if (i < blocks.length) out.add(blocks[i]);
  }
  return out;
}

/// md 全文里第 [figure.anchorRef] 号图引用的字符偏移（md 锚定用）。
int? _mdOffsetForFigure(String mdResults, OcrFigure figure) {
  final order = int.tryParse(figure.anchorRef);
  if (order == null) return null;
  final refs = _mdFigureRefs(mdResults);
  if (order < 0 || order >= refs.length) return null;
  return refs[order].offset;
}
