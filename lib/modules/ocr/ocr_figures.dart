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
// 图块默认放序列末尾（Win11 反馈包 3：不再设独立「未关联图片」区、
// 不再标“位置未确认”，用户自己拖到正确位置；人工拖过的图块记
// anchorSource='manual'，位置由用户定，见 [reorderFigures]）。
//
// 选项归属（WP-D #7，定稿 §7 + 附录 R5/S4/U2）：每个图块带
// [OcrFigure.optionLabel]（A–E 或 null），按 P1（md 结构明确关联）
// > P2（页面坐标 + 选项区域，同一 API 像素空间、空间尺寸一致才比）
// > P3（md 引用顺序 + 选项标号，仅 R5-3 四条件全满足）> P4（null）
// 确定；一张图片最多归属一个选项，一个选项可归属多张图片（S4-1）。
// 坐标约定（U2）：不做 PDF 仿射变换，GLM bbox 即送入 API 的图像的
// 像素坐标，换算只有减白边再 clip；PDF 点坐标/MediaBox/CropBox/
// Rotate/UserUnit 从不进入 OCR 流水线；页面旋转只在渲染时由 pdfrx
// 应用一次，逐图不做旋转处理（显式假设）。
//
// 已知边界（不是静默行为）：纯文本选项在解析时合并成一段、段内含
// 多个标号时无逐选项锚点，归属已知但无处可插的图块进未关联区；
// autoSplit 已把选项切出题干时题干块里同样没有标号块，图块同样进
// 未关联区；表格选项（#2 §2.3）无逐行插入锚点，不参与本包的标号块
// 定位。
//
// 渲染插入口径（M2 D-120 + WP-D #7）：`sequence_index` 是图块在阅读
// 顺序中的序号（图块之间）；渲染时按它插入内容序列——md 锚定的题干图
// 按 md 引用在全文中的字符位置插入到相邻题干段之间；text 锚定的题干图
// 按其在页内的纵向相对位置插入；有 optionLabel 的图块插在其选项标号
// 所在段内（R5-4：md 锚点可靠时保留原始锚点顺序，否则插标号块紧后方）；
// 人工拖过的图块（anchorSource='manual'）按 anchorRef（落点前的文字
// 段数）直接插到指定位置；无法可靠放置的图块默认放序列末尾。本文件只
// 给排序、锚点与归属，插入实现见 [buildContentBlocks]；逐图诊断记录
// 见 [diagnoseFigures]。

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
    this.optionLabel,
  });

  /// 图块 ID：`figure-<qid>-<index>`（index 为阅读顺序号）。
  final String id;

  /// 来源切片身份：裁图时的 slice_path + 产出该 OCR 包的切片 SHA-256。
  final String slicePath;
  final String? inputHash;

  /// 排序信息：阅读顺序号 + 锚点（锚定来源 md 引用序号或最近文本块
  /// id + 锚定方式 md/text/fallback）。
  final int sequenceIndex;

  /// 锚定方式：'md' | 'text' | 'fallback' | 'manual'（manual 是用户
  /// 在编辑器里拖出来的，位置由用户定，见 [reorderFigures]）。
  final String anchorSource;

  /// 锚点引用：md 锚定时为 md 引用序号（字符串化的整数）；
  /// text 锚定时为最近文本块 id（`text-<layout index>`）；
  /// fallback 时为 ''；manual 时为落点（Q2 REV2 §5.1：`"h"` = 原块
  /// `h` 之前，`"h:s"` = 原块 `h` 的第 `s` 段之前；旧的纯整数值
  /// 全兼容，含义不变）。
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

  /// 选项归属（WP-D #7，定稿 §7.2 优先级 1–4）：图块所属选项的标号
  /// （A–E），无法可靠匹配时为 null，不归入任何选项。只解决归属，
  /// 不独自决定选项内精确位置（R5-4：位置优先保留可靠的原始锚点顺序）。
  /// 旧数据（JSON 里无此键）解析为 null；本字段是 `ocr_figures`
  /// JSON 列里的一个键，不动数据库 schema（v5 不变）。
  final String? optionLabel;

  /// 是否位置未确认（锚定失败的图块）。数据层诊断用；界面不再作任何
  /// “位置未确认”标注（Win11 反馈包 3：全部关闭，未锚定图块默认放
  /// 序列末尾，用户自己拖到正确位置）。
  bool get unconfirmed => anchorSource == 'fallback';

  /// 该图块是否属于当前切片（展示层按 input_hash 与当前切片 hash
  /// 比对，不一致不展示；inputHash 为空的遗留图块只比 slice_path）。
  bool isCurrentFor({required String? slicePath, required String? inputHash}) {
    if (this.slicePath != slicePath) return false;
    if (this.inputHash == null || inputHash == null) return true;
    return this.inputHash == inputHash;
  }

  OcrFigure copyWith({
    int? sequenceIndex,
    String? anchorSource,
    String? anchorRef,
    String? cropPath,
    String? optionLabel,
  }) => OcrFigure(
    id: id,
    slicePath: slicePath,
    inputHash: inputHash,
    sequenceIndex: sequenceIndex ?? this.sequenceIndex,
    anchorSource: anchorSource ?? this.anchorSource,
    anchorRef: anchorRef ?? this.anchorRef,
    bbox2d: bbox2d,
    spaceWidth: spaceWidth,
    spaceHeight: spaceHeight,
    transform: transform,
    srcRect: srcRect,
    cropPath: cropPath ?? this.cropPath,
    optionLabel: optionLabel ?? this.optionLabel,
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
    if (optionLabel != null) 'option_label': optionLabel,
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
      final rawLabel = value['option_label'];
      final optionLabel = rawLabel is String &&
              rawLabel.length == 1 &&
              _isOptionLetter(rawLabel)
          ? _normalizeOptionLetter(rawLabel)
          : null;
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
        optionLabel: optionLabel,
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

/// Win11 反馈包 3：按用户拖出的新顺序重排图块（纯函数，不原地改）。
///
/// - [orderedIds] 必须是原集合的一个排列（不多不少、不丢图块），
///   否则抛 [ArgumentError]；
/// - 按新顺序重编 `sequence_index`（0..n-1）；
/// - 被拖的图块（[movedFigureId]）记 `anchorSource='manual'`，落点
///   [manualTextAt]（manual 落点字符串：`"h"` = 原块 `h` 之前，
///   `"h:s"` = 原块 `h` 的第 `s` 段之前，见 Q2 REV2 §5.1）写进
///   `anchor_ref`；没动的图块锚定来源不动；
/// - 只改顺序与锚定，不改裁图文件本身（`crop_path` 原样保留）。
List<OcrFigure> reorderFigures(
  List<OcrFigure> figures, {
  required List<String> orderedIds,
  required String movedFigureId,
  String? manualTextAt,
}) {
  if (orderedIds.length != figures.length ||
      orderedIds.toSet().length != figures.length) {
    throw ArgumentError('orderedIds 必须是图块集合的一个排列（不多不少）');
  }
  final byId = {for (final f in figures) f.id: f};
  if (!byId.containsKey(movedFigureId) ||
      orderedIds.any((id) => !byId.containsKey(id))) {
    throw ArgumentError('orderedIds / movedFigureId 含未知图块 ID');
  }
  return [
    for (var i = 0; i < orderedIds.length; i++)
      byId[orderedIds[i]]!.copyWith(
        sequenceIndex: i,
        anchorSource: orderedIds[i] == movedFigureId
            ? 'manual'
            : null,
        anchorRef: orderedIds[i] == movedFigureId && manualTextAt != null
            ? manualTextAt
            : null,
      ),
  ];
}

/// Win11 反馈包 3：重识别产生新图块 ID 时，尽量保留已有的 manual 图块
/// （纯函数，不原地改）。
///
/// 匹配口径是裁图区域（`slice_path` + `srcRect` 相同即同一张图，
/// 不比 ID——新派生的 ID 是按派生顺序编的 index，同一张图重识别后
/// ID 会变；也不比 bbox 原值，白边变化时 bbox 会动而裁图区域不变）。
///
/// - 匹配上的 manual 图块：取新派生图块的 ID（防 ID 撞车）与位置，
///   保留旧裁图文件（`crop_path` 不变，不重裁）与 manual 落点
///  （`anchorSource='manual'` + 旧 `anchor_ref`），以后重识别也不动它；
/// - 匹配不上的 manual 图块：保留在序列末尾（不静默丢弃），ID 加
///   `-manual` 后缀防与新派生 ID 撞车，并在 [unmatchedManualIds]
///   里上报——调用方据此提示用户（而不是静默丢图）；
/// - 非 manual 的旧图块一律由新派生结果替换；没有 manual 图块时原样
///   返回新派生结果。
/// 返回 `(figures, unmatchedManualIds)`；`sequence_index` 按合并后
/// 顺序重编。
///
/// 注意（调用方责任）：合并后只有 `crop_path` 为空的图块才需要走
/// [writeFigureFiles] 写新裁图；保留下来的 manual 图块已有旧裁图
/// 文件，直接复用，不重裁（`writeFigureFiles` 会给每个传入图块重
/// 新裁图并分配新路径）。
({List<OcrFigure> figures, List<String> unmatchedManualIds})
mergeManualFigures({
  required List<OcrFigure> oldFigures,
  required List<OcrFigure> newFigures,
}) {
  final manualOld = oldFigures
      .where((f) => f.anchorSource == 'manual')
      .toList();
  if (manualOld.isEmpty) {
    return (
      figures: [
        for (var i = 0; i < newFigures.length; i++)
          newFigures[i].copyWith(sequenceIndex: i),
      ],
      unmatchedManualIds: const [],
    );
  }
  final usedManualIds = <String>{};
  final merged = <OcrFigure>[];
  for (final nf in newFigures) {
    OcrFigure? match;
    for (final mf in manualOld) {
      if (usedManualIds.contains(mf.id)) continue;
      if (mf.slicePath == nf.slicePath && mf.srcRect == nf.srcRect) {
        match = mf;
        break;
      }
    }
    if (match != null) {
      usedManualIds.add(match.id);
      merged.add(
        nf.copyWith(
          anchorSource: 'manual',
          anchorRef: match.anchorRef,
          cropPath: match.cropPath,
        ),
      );
    } else {
      merged.add(nf);
    }
  }
  final unmatchedIds = <String>[];
  final usedIds = {for (final f in merged) f.id};
  for (final mf in manualOld) {
    if (usedManualIds.contains(mf.id)) continue;
    // 旧 ID 可能已被新派生图块占用：加后缀保证唯一（多次合并时
    // 循环加，直到不撞车为止）。
    var newId = '${mf.id}-manual';
    while (usedIds.contains(newId)) {
      newId = '$newId-manual';
    }
    usedIds.add(newId);
    // 保留旧图块的裁图文件、落点与归属，只换一个不撞车的 ID。
    merged.add(
      OcrFigure(
        id: newId,
        slicePath: mf.slicePath,
        inputHash: mf.inputHash,
        sequenceIndex: merged.length,
        anchorSource: 'manual',
        anchorRef: mf.anchorRef,
        bbox2d: mf.bbox2d,
        spaceWidth: mf.spaceWidth,
        spaceHeight: mf.spaceHeight,
        transform: mf.transform,
        srcRect: mf.srcRect,
        cropPath: mf.cropPath,
        optionLabel: mf.optionLabel,
      ),
    );
    unmatchedIds.add(newId);
  }
  final out = [
    for (var i = 0; i < merged.length; i++)
      merged[i].copyWith(sequenceIndex: i),
  ];
  return (figures: out, unmatchedManualIds: unmatchedIds);
}

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
        x.optionLabel != y.optionLabel ||
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

// ---------------------------------------------------------------------------
// WP-D #7 选项图片锚定（定稿 §7.2 + 附录 R5/S4/U2）。
//
// 选项标号识别与 #2 共用（§7.2.4）：标记形式与
// `lib/services/stem_splitter.dart:195-201` 的 _markerPattern /
// _barePattern 原样一致（括号式 `(A)`/`（A）`、字母+标点
// `A.`/`A．`/`A、`/`A)`/`A）`/`A:`/`A：`、裸字母 `A `；全角 Ａ-Ｅ
// 归一化为 A-E）。两处正则字面量须保持一致，#2 改动此处须同步。
// 与 #2 不同的一点（实现注释，非设计改动）：#2 的块级候选要求 div 内
// “标记外有内容”才算选项——那是为自动切分守门；此处图片本身就是
// 选项的内容（纯图片选项的标号 div 如 `<div>A.</div>` 除标记外无文字），
// 因此标号 div 为空时仍认标号，图片即其内容。
// ---------------------------------------------------------------------------

bool _isOptionLetter(String ch) {
  if (ch.length != 1) return false;
  final c = ch.codeUnitAt(0);
  return (c >= 0x41 && c <= 0x45) || (c >= 0xFF21 && c <= 0xFF25);
}

String _normalizeOptionLetter(String ch) {
  final c = ch.codeUnitAt(0);
  if (c >= 0xFF21 && c <= 0xFF25) {
    return String.fromCharCode(0x41 + (c - 0xFF21));
  }
  return ch;
}

final _optionMarkerPattern = RegExp(
  r'[（(]\s*[A-EＡ-Ｅ]\s*[)）]|[A-EＡ-Ｅ][.．、)）:：]',
);
final _bareOptionMarkerPattern = RegExp(r'[A-EＡ-Ｅ] (?=\S)');

/// 文本去空白后是否以选项标记开头（#2 步骤 1 块级候选同款开头判定）。
/// 返回标号字母（A–E），不是则返回 null。
String? _leadingOptionLabel(String text) {
  final s = text.trimLeft();
  if (s.isEmpty) return null;
  final m = _optionMarkerPattern.matchAsPrefix(s) ??
      _bareOptionMarkerPattern.matchAsPrefix(s);
  if (m == null) return null;
  for (var i = 0; i < m.group(0)!.length; i++) {
    final ch = m.group(0)![i];
    if (_isOptionLetter(ch)) return _normalizeOptionLetter(ch);
  }
  return null;
}

/// md 全文里的一个选项标号出现位置。
class _OptionLabelOccurrence {
  const _OptionLabelOccurrence({
    required this.letter,
    required this.offset,
    required this.markerEnd,
    this.divStart,
    this.divEnd,
  });

  /// 标号字母（A–E）。
  final String letter;

  /// 标记首字符在 md 全文中的字符偏移。
  final int offset;

  /// 标记结束偏移（标记文本末尾，不含后续内容）。
  final int markerEnd;

  /// 标号所在 div/p 元素的起止偏移（含标签本身；纯文本行标号时为 null）。
  /// divEnd 为 `</div>`/`</p>` 之后的位置。
  final int? divStart;
  final int? divEnd;
}

/// 在 md 全文（原始文本，不剥标签）中找出全部选项标号出现位置，按偏移排序。
/// 顺序：先扫 `<div>`/`<p>` 块（块内去标签后以标记开头），再扫纯文本行首
/// （行首标记）；行首扫描跳过已落在 div/p 块内的行，不重复计数。
List<_OptionLabelOccurrence> _optionLabelOccurrences(String md) {
  final out = <_OptionLabelOccurrence>[];
  final divSpans = <({int start, int end})>[];
  final openTag = RegExp(r'<(div|p)\b[^>]*>', caseSensitive: false);
  final closeTag = RegExp(r'</(div|p)\s*>', caseSensitive: false);
  for (final open in openTag.allMatches(md)) {
    final close = closeTag.firstMatch(md.substring(open.end));
    if (close == null) continue;
    final contentStart = open.end;
    final contentEnd = open.end + close.start;
    final divEnd = open.end + close.end;
    divSpans.add((start: open.start, end: divEnd));
    // 块内文本：去标签后 trimLeft，以标记开头即为标号。
    final inner = md
        .substring(contentStart, contentEnd)
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .trimLeft();
    if (inner.isEmpty) continue;
    final marker = _optionMarkerPattern.matchAsPrefix(inner) ??
        _bareOptionMarkerPattern.matchAsPrefix(inner);
    if (marker == null) continue;
    // 标记在 md 中的真实偏移：从块内容起点向后找第一个不在标签内的标记。
    var markerOffset = -1;
    var markerEnd = -1;
    for (final m in _optionMarkerPattern
        .allMatches(md.substring(contentStart, contentEnd))) {
      final at = contentStart + m.start;
      if (_insideTag(md, at)) continue;
      markerOffset = at;
      markerEnd = contentStart + m.end;
      break;
    }
    if (markerOffset < 0) {
      for (final m in _bareOptionMarkerPattern
          .allMatches(md.substring(contentStart, contentEnd))) {
        final at = contentStart + m.start;
        if (_insideTag(md, at)) continue;
        markerOffset = at;
        markerEnd = contentStart + m.end;
        break;
      }
    }
    if (markerOffset < 0) continue;
    var letter = '';
    for (var i = 0; i < marker.group(0)!.length; i++) {
      final ch = marker.group(0)![i];
      if (_isOptionLetter(ch)) {
        letter = _normalizeOptionLetter(ch);
        break;
      }
    }
    if (letter.isEmpty) continue;
    out.add(
      _OptionLabelOccurrence(
        letter: letter,
        offset: markerOffset,
        markerEnd: markerEnd,
        divStart: open.start,
        divEnd: divEnd,
      ),
    );
  }
  // 纯文本行首标号（跳过 div/p 块内的行）。
  var lineStart = 0;
  while (lineStart <= md.length) {
    final lineEnd = md.indexOf('\n', lineStart);
    final end = lineEnd < 0 ? md.length : lineEnd;
    final insideDiv = divSpans.any(
      (s) => lineStart >= s.start && lineStart < s.end,
    );
    if (!insideDiv) {
      final line = md.substring(lineStart, end);
      final trimmed = line.trimLeft();
      if (trimmed.isNotEmpty) {
        final marker = _optionMarkerPattern.matchAsPrefix(trimmed) ??
            _bareOptionMarkerPattern.matchAsPrefix(trimmed);
        if (marker != null) {
          var letter = '';
          for (var i = 0; i < marker.group(0)!.length; i++) {
            final ch = marker.group(0)![i];
            if (_isOptionLetter(ch)) {
              letter = _normalizeOptionLetter(ch);
              break;
            }
          }
          if (letter.isNotEmpty) {
            out.add(
              _OptionLabelOccurrence(
                letter: letter,
                offset: lineStart + (line.length - trimmed.length),
                markerEnd:
                    lineStart + (line.length - trimmed.length) + marker.end,
              ),
            );
          }
        }
      }
    }
    if (lineEnd < 0) break;
    lineStart = lineEnd + 1;
  }
  out.sort((a, b) => a.offset.compareTo(b.offset));
  return out;
}

/// [offset] 是否落在 md 的某个 `<…>` 标签内。
bool _insideTag(String md, int offset) {
  final lt = md.lastIndexOf('<', offset);
  if (lt < 0) return false;
  final gt = md.indexOf('>', lt);
  return gt < 0 || gt > offset;
}

/// 选项在页面中的区域（P2 用）：标号文本块所在行带。
class _OptionRegion {
  const _OptionRegion({
    required this.letter,
    required this.page,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.spaceWidth,
    required this.spaceHeight,
  });

  final String letter;
  final int page;

  /// 行带矩形（API 像素空间，与图块 bbox 同一坐标系）：
  /// x 为标号块横向范围，y 为标号块 y1 至下一标号 y1（末个标号封顶
  /// 为自身 y2 + 页内标号中位间距，见 [_optionRegions]）。
  final int x1;
  final int y1;
  final int x2;
  final int y2;

  /// 该标号块所在坐标空间尺寸（P2 比对要求与图块一致，见 U2）。
  final int? spaceWidth;
  final int? spaceHeight;
}

/// 从 layout 文本块里提取选项区域：内容去空白后以选项标记开头的文本块。
List<_OptionRegion> _optionRegions(List<_LayoutBlock> textBlocks) {
  final labels = <_LayoutBlock, String>{};
  for (final b in textBlocks) {
    final letter = _leadingOptionLabel(b.content.trim());
    if (letter != null) labels[b] = letter;
  }
  if (labels.isEmpty) return const [];
  final byPage = <int, List<_LayoutBlock>>{};
  for (final b in labels.keys) {
    (byPage[b.page] ??= []).add(b);
  }
  final out = <_OptionRegion>[];
  for (final entry in byPage.entries) {
    final pageBlocks = [...entry.value]..sort((a, b) => a.y1.compareTo(b.y1));
    // 页内标号 y1 的正向间距中位数（末个标号行带的封顶用）。
    final distinctY1 = <int>{for (final b in pageBlocks) b.y1}.toList()
      ..sort();
    final gaps = <int>[];
    for (var i = 1; i < distinctY1.length; i++) {
      final g = distinctY1[i] - distinctY1[i - 1];
      if (g > 0) gaps.add(g);
    }
    gaps.sort();
    // 下中位数（保守封顶：不让末标号行带伸得比典型间距更远；缺号造成
    // 的大间距不得把末行带撑进下一区域）。
    final medianGap = gaps.isEmpty ? 0 : gaps[(gaps.length - 1) ~/ 2];
    for (final b in pageBlocks) {
      var bandEnd = -1;
      for (final other in pageBlocks) {
        if (other.y1 > b.y1 && (bandEnd < 0 || other.y1 < bandEnd)) {
          bandEnd = other.y1;
        }
      }
      if (bandEnd < 0) {
        final fallback = medianGap > 0 ? medianGap : (b.y2 - b.y1);
        bandEnd = b.y2 + fallback;
      }
      out.add(
        _OptionRegion(
          letter: labels[b]!,
          page: b.page,
          x1: b.x1,
          y1: b.y1,
          x2: b.x2,
          y2: bandEnd,
          spaceWidth: b.spaceWidth,
          spaceHeight: b.spaceHeight,
        ),
      );
    }
  }
  return out;
}

/// 优先级 1——明确关联：md 引用在标号 div 内，或紧跟标号块后。
///
/// - 引用落在标号 div/p 元素内（含 `<div>A. ![](…)</div>`）→ 该标号；
/// - 引用是标号块结束后的第一个引用、且位于下一标号之前（末标号则
///   无此限）、中间除标签与空白外无其他文字（含 `<div>A. 甲</div>`
///   后紧跟引用、以及居中图 `<div align="center">![](…)</div>`
///   紧跟标号块）→ 该标号；
/// - 末标号之后的多个引用成簇时（引用之间还隔着其他引用），只有第一个
///   满足“中间无其他文字”，其余不走 P1（顺序证据归 P3 管）。
String? _p1LabelForRef(
  String md,
  List<_OptionLabelOccurrence> labels,
  int refOffset,
) {
  _OptionLabelOccurrence? prev;
  for (final l in labels) {
    if (l.offset <= refOffset) {
      prev = l;
    } else {
      break;
    }
  }
  if (prev == null) return null;
  if (prev.divStart != null &&
      prev.divEnd != null &&
      refOffset >= prev.divStart! &&
      refOffset < prev.divEnd!) {
    return prev.letter;
  }
  final from = prev.divEnd ?? prev.markerEnd;
  if (refOffset < from) return null;
  final between = md
      .substring(from, refOffset)
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .trim();
  if (between.isEmpty) return prev.letter;
  return null;
}

/// 优先级 2——页面坐标 + 选项区域：图块中心点落在某选项行带内。
///
/// 坐标校验（U2/S4-2）：图块与标号块须在同一 API 像素空间——同一页、
/// 且双方 spaceWidth/spaceHeight 均非空且相等；任一不符 → 该对不匹配，
/// 不放宽阈值硬匹配。多个行带都含中心点时（并排选项），取横向离标号块
/// 最近者（中心点在标号块横向范围内记 0 分）。
String? _p2LabelForFigure(_LayoutBlock image, List<_OptionRegion> regions) {
  if (regions.isEmpty) return null;
  final cx = image.centerX;
  final cy = image.centerY;
  _OptionRegion? best;
  var bestScore = 1 << 30;
  var bestDy = 1 << 30;
  for (final r in regions) {
    if (image.page != r.page) continue;
    if (image.spaceWidth == null ||
        image.spaceHeight == null ||
        r.spaceWidth == null ||
        r.spaceHeight == null ||
        image.spaceWidth != r.spaceWidth ||
        image.spaceHeight != r.spaceHeight) {
      continue;
    }
    if (cy < r.y1 || cy >= r.y2) continue;
    if (cx < r.x1) continue;
    final score = cx <= r.x2 ? 0 : cx - r.x2;
    final dy = (cy - (r.y1 + r.y2) ~/ 2).abs();
    if (score < bestScore || (score == bestScore && dy < bestDy)) {
      best = r;
      bestScore = score;
      bestDy = dy;
    }
  }
  return best?.letter;
}

/// 优先级 3——md 引用顺序 + 选项标号（R5-3 四条件全满足才启用）。
///
/// 返回 md 引用序号 → 标号字母的映射；条件任一不满足 → 空映射。
/// - 条件 1：选项序列完整（自 A 起严格连续、无重复、无缺号，至少 A–D）；
/// - 条件 2：引用顺序无歧义（每图恰一个 md 引用、引用位置各不相同）；
/// - 条件 3：无冲突（选项引用在全部引用中连续成段，中间无题干图夹杂；
///   同一标号多图时引用顺序与选项内位置一致——分组内引用连续）；
/// - 映射：引用数 == 标号数时按顺序一一对应；引用数 ≠ 标号数时按引用
///   落在哪个标号区间（本标号偏移至下一标号偏移）映射——一张图片最多
///   归属一个选项，一个选项可归属多张图片（S4-1）。
Map<int, String> _p3Mapping({
  required List<_OptionLabelOccurrence> labels,
  required List<_MdFigureRef> optionRefs,
  required List<_MdFigureRef> allRefs,
  required bool refsUnambiguous,
}) {
  if (!refsUnambiguous) return const {};
  if (labels.length < 4 || optionRefs.isEmpty) return const {};
  // 条件 1：自 A 起严格连续。
  if (labels.first.letter != 'A') return const {};
  for (var i = 0; i < labels.length; i++) {
    if (labels[i].letter.codeUnitAt(0) != 0x41 + i) return const {};
  }
  // 条件 2：调用方已核每图恰一个引用；此处核引用位置各不相同。
  final offsets = {for (final r in optionRefs) r.offset};
  if (offsets.length != optionRefs.length) return const {};
  // 条件 3：选项引用在全部引用中连续成段。
  final sortedAll = [...allRefs]..sort((a, b) => a.offset.compareTo(b.offset));
  final firstIdx = sortedAll.indexWhere((r) => r.order == optionRefs.first.order);
  final lastIdx = sortedAll.indexWhere((r) => r.order == optionRefs.last.order);
  if (firstIdx < 0 || lastIdx < 0) return const {};
  if (lastIdx - firstIdx + 1 != optionRefs.length) return const {};
  final sortedOption = [...optionRefs]..sort((a, b) => a.offset.compareTo(b.offset));
  final out = <int, String>{};
  if (sortedOption.length == labels.length) {
    for (var i = 0; i < sortedOption.length; i++) {
      out[sortedOption[i].order] = labels[i].letter;
    }
    return out;
  }
  // 引用数 ≠ 标号数：按区间映射；同标号分组须在引用顺序中连续。
  final byLabel = <String, List<_MdFigureRef>>{};
  for (final ref in sortedOption) {
    String? letter;
    for (var i = 0; i < labels.length; i++) {
      final start = labels[i].offset;
      final end = i + 1 < labels.length ? labels[i + 1].offset : 1 << 30;
      if (ref.offset >= start && ref.offset < end) {
        letter = labels[i].letter;
        break;
      }
    }
    if (letter == null) return const {};
    (byLabel[letter] ??= []).add(ref);
  }
  var seen = 0;
  for (final group in byLabel.values) {
    // 分组内引用须连续：组内首尾之间不得夹其他标号的引用。
    final first = sortedOption.indexWhere((r) => r.order == group.first.order);
    final last = sortedOption.indexWhere((r) => r.order == group.last.order);
    if (last - first + 1 != group.length) return const {};
    seen += group.length;
  }
  if (seen != sortedOption.length) return const {};
  for (final entry in byLabel.entries) {
    for (final ref in entry.value) {
      out[ref.order] = entry.key;
    }
  }
  return out;
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

  /// 选项归属（WP-D #7）：P1/P2/P3 逐级确定，无法可靠匹配时为 null。
  String? optionLabel;
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
  // WP-D #7 选项归属（定稿 §7.2，优先级 P1 > P2 > P3 > P4）：
  // - 标号出现位置（md 全文）与选项区域（layout 文本块）；
  // - 坐标校验（U2）：md 引用 bbox 与任何 layout 块都对不上时，说明
  //   md 与 layout 的坐标系已存疑，P2（坐标路径）整题停用，只走
  //   md 结构路径（P1/P3），绝不放宽阈值硬匹配。
  final labelOccurrences = _optionLabelOccurrences(raw.mdResults);
  final firstLabelOffset =
      labelOccurrences.isEmpty ? null : labelOccurrences.first.offset;
  final optionRegions = _optionRegions(textBlocks);
  final unmatchedMdRefs = mdRefs.where((ref) {
    return !blocks.any(
      (b) => b.page == ref.page && _bboxMatches(b.bbox, ref.bbox),
    );
  }).toList();
  final p2Enabled = unmatchedMdRefs.isEmpty;
  // 每图匹配到的 md 引用数（P3 条件 2：有引用的图须恰一个引用）。
  final mdRefMatchCounts = <_LayoutBlock, int>{};
  for (final block in images) {
    mdRefMatchCounts[block] = mdRefs
        .where((ref) => ref.page == block.page && _bboxMatches(ref.bbox, block.bbox))
        .length;
  }
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
  // WP-D #7：逐图确定 optionLabel（P1 > P2 > P3 > P4=null）。
  // 选项候选图 = md 引用在首个选项标号之后（含）的图，或无 md 引用的图
  // （无引用时由 P2 坐标决定，题干图由行带位置自然排除）；md 引用在
  // 首个标号之前的图是题干图，永不归属选项。
  final optionRefs = <_MdFigureRef>[];
  var refsUnambiguous = true;
  for (final c in candidates) {
    if (c.mdOffset == null) continue;
    if (firstLabelOffset == null || c.mdOffset! < firstLabelOffset) continue;
    if ((mdRefMatchCounts[c.block] ?? 0) != 1) refsUnambiguous = false;
    optionRefs.add(
      _MdFigureRef(
        order: c.mdOrder!,
        page: c.block.page,
        bbox: c.block.bbox,
        offset: c.mdOffset!,
      ),
    );
  }
  optionRefs.sort((a, b) => a.offset.compareTo(b.offset));
  final p3 = _p3Mapping(
    labels: labelOccurrences,
    optionRefs: optionRefs,
    allRefs: mdRefs,
    refsUnambiguous: refsUnambiguous,
  );
  for (final c in candidates) {
    final isOptionCandidate = c.mdOffset == null ||
        (firstLabelOffset != null && c.mdOffset! >= firstLabelOffset);
    if (!isOptionCandidate) continue;
    // P1：md 结构明确关联。
    if (c.mdOffset != null) {
      c.optionLabel = _p1LabelForRef(raw.mdResults, labelOccurrences, c.mdOffset!);
    }
    // P2：页面坐标 + 选项区域（坐标系存疑时整题停用）。
    // 有 md 引用时，P2 不得与 md 区间证据冲突：引用所在标号区间
    // （最近的前置标号）即 md 认定的归属，坐标匹配须与之一致，
    // 否则以 md 为准、P2 不判（视觉顺序颠倒/旋转时坐标本就不可信）。
    if (c.optionLabel == null && p2Enabled) {
      final p2 = _p2LabelForFigure(c.block, optionRegions);
      if (p2 != null) {
        if (c.mdOffset == null) {
          c.optionLabel = p2;
        } else {
          String? spanLabel;
          for (final l in labelOccurrences) {
            if (l.offset <= c.mdOffset!) spanLabel = l.letter;
          }
          if (spanLabel != null && p2 == spanLabel) c.optionLabel = p2;
        }
      }
    }
    // P3：md 引用顺序 + 选项标号（四条件全满足才启用，见 _p3Mapping）。
    if (c.optionLabel == null && c.mdOrder != null) {
      c.optionLabel = p3[c.mdOrder!];
    }
    // P4：仍无结果 → null，不归入任何选项。
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
        optionLabel: c.optionLabel,
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

/// 一个图块的放置结果（[buildContentBlocks] 与 [diagnoseFigures] 共用）。
class _FigurePlacement {
  const _FigurePlacement({
    required this.figure,
    required this.at,
    required this.zone,
    this.slotPart = 0,
    this.rule = 'zone',
    this.splitBlock,
    this.splitOffset,
    this.epsilon = 0,
  });

  final OcrFigure figure;

  /// 插入下标（插入到该下标的原块之前；进未关联区时为 null）。
  /// 块内切分时为切分块下标，分槽由 [splitOffset] 定；
  /// manual `"h:s"` 时为 `h`，段序号见 [slotPart]。
  final int? at;

  /// 是否进未关联区。
  final bool zone;

  /// manual `"h:s"` 的段序号（块内落点）；其余分支为 0。
  /// 在 [buildContentBlocks] 里按该块实际切分段数再钳制一次。
  final int slotPart;

  /// 放置规则（诊断用，见 §9.4）：'segment' | 'fallback_no_boundary' |
  /// 'zone' | 'manual' | 'text' | 'option'。
  final String rule;

  /// 块内切分点（仅 md 题干图的段解析切分时有值）：原块下标与
  /// 块内切分字符偏移；其余为 null。
  final int? splitBlock;
  final int? splitOffset;

  /// 本图所用的 ε（§3.2；非 md 题干图为 0）。
  final int epsilon;
}

/// 题干首段在 md 全文中的位置（-1 表示未找到）。
///
/// 定位键取首个非空 TextBlock 的首个非空行（去空白后前 40 字）。
/// §7.1 的起点定位失败即源于旧实现取整块前 40 字：纯文本题干在解析时
/// 合并成一段，块内后段文字在 md 里被图引用隔开，整块 40 字在 md 中
/// 根本不存在，导致 stemStartInMd == -1、md 锚点全失效。
/// 取首行后，键只含引用之前的文字，定位恢复。
int _stemStartInMd(List<QuestionContentBlock> blocks, String? mdResults) {
  if (mdResults == null || mdResults.isEmpty) return -1;
  final firstText = blocks
      .whereType<TextBlock>()
      .map((b) => b.text.trim())
      .firstWhere((t) => t.isNotEmpty, orElse: () => '');
  if (firstText.isEmpty) return -1;
  final firstLine = firstText
      .split('\n')
      .map((l) => l.trim())
      .firstWhere((l) => l.isNotEmpty, orElse: () => '');
  if (firstLine.isEmpty) return -1;
  if (firstLine.length >= 8) {
    return mdResults.indexOf(
      firstLine.substring(0, math.min(40, firstLine.length)),
    );
  }
  return mdResults.indexOf(firstLine);
}

/// 各内容段的字符累计长度（按拼回文本计，用于 md 偏移映射）。
List<int> _blockTextLengths(List<QuestionContentBlock> blocks) {
  final lengths = <int>[];
  for (final b in blocks) {
    lengths.add(switch (b) {
      TextBlock(:final text) => text.length,
      FormulaBlock(:final latex, :final displayMode) =>
        latex.length + (displayMode ? 4 : 2),
      CodeBlock(:final code) => code.length + 6,
      ImageFallbackBlock() => 0,
      FigureBlock() => 0,
      // WP-C #6：表格按拼回的 HTML 长度估算（图块 md 偏移映射用），
      // 标题按 `## ` + 文字长度估算。
      TableBlock() => blocksToMarkdown([b]).length,
      HeadingBlock(:final text, :final level) => text.length + level + 1,
    });
  }
  return lengths;
}

/// 选项标号块在内容段里的位置：标号字母 → 段下标。同一标号在多个段首
/// 出现时视为歧义（R5-5），该标号不建锚点、其图块进未关联区。
/// 只认段首标号（TextBlock 去空白后以标记开头，#2 块级候选同款形式）；
/// 纯文本选项在解析时合并成一段、段内含多个标号时无逐选项锚点——
/// 归属已知但无处可插的图块进未关联区（已知边界，见文件头注释）。
Map<String, int> _optionLabelBlockIndex(List<QuestionContentBlock> blocks) {
  final out = <String, int>{};
  final ambiguous = <String>{};
  for (var i = 0; i < blocks.length; i++) {
    final b = blocks[i];
    if (b is! TextBlock) continue;
    final letter = _leadingOptionLabel(b.text);
    if (letter == null) continue;
    if (ambiguous.contains(letter)) continue;
    if (out.containsKey(letter)) {
      ambiguous.add(letter);
      out.remove(letter);
    } else {
      out[letter] = i;
    }
  }
  return out;
}

/// R5-4：有归属的图块在选项内的精确位置——优先保留可靠的原始锚点顺序。
/// 在 md 里数该选项段内、引用之前已闭合的块边界（div/p 闭合数；无 div 时
/// 数段落分隔 `\n\n`），即为引用之前已有几段选项文字，图就插在第几段后；
/// 无可靠 md 锚点时返回标号块紧后方。返回值钳制在选项段内
/// （[labelAt]+1 .. [spanEnd]，spanEnd 为下一标号块下标或段总数）。
int _optionPositionFromMd({
  required String mdResults,
  required List<_OptionLabelOccurrence> labels,
  required String optionLabel,
  required int refOffset,
  required int labelAt,
  required int spanEnd,
}) {
  _OptionLabelOccurrence? own;
  for (final l in labels) {
    if (l.letter == optionLabel && l.offset <= refOffset) own = l;
  }
  if (own == null) return labelAt + 1;
  final span = mdResults.substring(own.offset, refOffset);
  final int boundaries;
  if (span.contains('<div') || span.contains('<p')) {
    boundaries =
        '</div>'.allMatches(span).length + '</p>'.allMatches(span).length;
  } else {
    boundaries = '\n\n'.allMatches(span).length;
  }
  final at = labelAt + (boundaries < 1 ? 1 : boundaries);
  return at.clamp(labelAt + 1, spanEnd);
}

// ---------------------------------------------------------------------------
// Q2 REV2：段落段尾放置（Win11 反馈后续修复）。
//
// 题干图的 md 引用偏移 rel 所属的段落段，图插到该段的段尾。段落段 =
// 一段连续的行内内容（TextBlock + 行内 FormulaBlock），以段落分隔符
// （\n\n+）或块级边界（独立公式 / 代码 / 表格 / 标题 / 原图回退块）
// 为界。只在放置层实现：不动 parseQuestionContent / 块模型 / schema /
// ocr_figures JSON 格式（只新增 anchorRef 的 "h:s" 取值，旧值全兼容）。
// 全部偏移都是 Dart String 字符下标（UTF-16 码元），不是字节偏移。
// ---------------------------------------------------------------------------

/// 段落分隔符：两个及以上换行（`\r\n` 按一个换行计，只在扫描时识别，
/// 绝不改动原文；OQ1：2026-11-20 备份 28 份 md_results 与题干里均无
/// `\r`，正则保留 `\r?` 作防御，不简化）。
final _paragraphSeparatorPattern = RegExp(r'(?:\r?\n){2,}');

/// 一个 TextBlock 内的段落分隔符行程（块内偏移 + 全局块坐标偏移）。
class _SeparatorRun {
  const _SeparatorRun({
    required this.blockIndex,
    required this.startInBlock,
    required this.endInBlock,
    required this.globalStart,
    required this.globalEnd,
  });

  final int blockIndex;
  final int startInBlock;
  final int endInBlock;
  final int globalStart;
  final int globalEnd;
}

/// 是否块级边界（段划分里结束当前段，自身不属于任何段）。
bool _isBlockLevelBoundary(QuestionContentBlock b) => switch (b) {
  TextBlock() => false,
  FormulaBlock(:final displayMode) => displayMode,
  _ => true,
};

/// 各 TextBlock 内的段落分隔符行程（按块顺序、块内偏移升序）。
/// 纯分隔符块（整块只有一个分隔符行程）：解析器一般已丢弃纯空白段落，
/// 此处防御性跳过，不把它当作段边界。
List<_SeparatorRun> _separatorRuns(
  List<QuestionContentBlock> blocks,
  List<int> starts,
) {
  final runs = <_SeparatorRun>[];
  for (var i = 0; i < blocks.length; i++) {
    final b = blocks[i];
    if (b is! TextBlock) continue;
    for (final m in _paragraphSeparatorPattern.allMatches(b.text)) {
      if (m.start == 0 && m.end == b.text.length) continue;
      runs.add(
        _SeparatorRun(
          blockIndex: i,
          startInBlock: m.start,
          endInBlock: m.end,
          globalStart: starts[i] + m.start,
          globalEnd: starts[i] + m.end,
        ),
      );
    }
  }
  return runs;
}

/// md 题干图解析到的一处落点：块内切分，或原块边界。
class _SegmentPlacement {
  const _SegmentPlacement.boundary({
    required this.at,
    required this.rule,
    required this.epsilon,
  }) : blockIndex = null,
       offset = null;

  const _SegmentPlacement.cut({
    required this.blockIndex,
    required this.offset,
    required this.rule,
    required this.epsilon,
  }) : at = null;

  /// 边界落点：插到原块 [at] 之前（0..n）。
  final int? at;

  /// 切分落点：切分原块 [blockIndex]，分隔符归属前一段，
  /// 切分偏移 [offset] = 分隔符行程末尾（块内字符偏移）。
  final int? blockIndex;
  final int? offset;

  /// 'segment'（落在某段落段尾）或 'fallback_no_boundary'（段内无
  /// 分隔符，退到段尾的块尾放置）。
  final String rule;

  /// 本图所用的 ε（§3.2）。
  final int epsilon;

  bool get isCut => blockIndex != null;
}

/// 分隔符行程定义的边界：行程在块首 → 块首边界；行程在块尾 → 块尾
/// 边界；其余 → 块内切分（分隔符归属前一段）。三者是同一边界、同一
/// 分槽，不产生两个切分点（§3.1）。
_SegmentPlacement _boundaryForRun(
  _SeparatorRun run,
  List<QuestionContentBlock> blocks,
  int epsilon,
) {
  final textLen = (blocks[run.blockIndex] as TextBlock).text.length;
  if (run.startInBlock == 0) {
    return _SegmentPlacement.boundary(
      at: run.blockIndex,
      rule: 'segment',
      epsilon: epsilon,
    );
  }
  if (run.endInBlock == textLen) {
    return _SegmentPlacement.boundary(
      at: run.blockIndex + 1,
      rule: 'segment',
      epsilon: epsilon,
    );
  }
  return _SegmentPlacement.cut(
    blockIndex: run.blockIndex,
    offset: run.endInBlock,
    rule: 'segment',
    epsilon: epsilon,
  );
}

/// ε（§3.2）：`2 × rel 之前已完整出现的 FormulaBlock 数`。
/// 公式长度只会低估（每公式 0–2 字），误差单向偏右。
int _epsilonForRel(
  List<QuestionContentBlock> blocks,
  List<int> starts,
  int rel,
) {
  var n = 0;
  for (var i = 0; i < blocks.length; i++) {
    if (blocks[i] is FormulaBlock && starts[i + 1] <= rel) n++;
  }
  return 2 * n;
}

/// 文本是否以段落分隔符行程结尾（§6.4 的 rule 判定用）。
bool _endsWithSeparator(String text) {
  var found = false;
  for (final m in _paragraphSeparatorPattern.allMatches(text)) {
    if (m.end == text.length) found = true;
  }
  return found;
}

/// 把 md 题干图的相对偏移 [rel] 解析到一段的段尾（§1–§4、§6）。
///
/// - [starts]：各块在块坐标轴上的起点（长度 n+1，starts[n] 为总长）；
/// - [host]：`rel <= acc` 的首次命中块（§6 立约，调用方算好传入）；
/// - 顺序：rel<0（§6.1）→ 块级宿主（§4.1）→ ε 吸附（§3.2）→
///   宿主块尾 tie（§6.4）→ 沿本段向前找段尾（§2.1/§4.1）→ 兜底（§7）。
/// 吸附（§6.9）优先于块尾 tie（§6.4）：rel 恰在块边界、且其前 ε 内
/// 有分隔符时，真实位置极可能就是该分隔符本身。
_SegmentPlacement _resolveMdStemPlacement({
  required List<QuestionContentBlock> blocks,
  required List<int> starts,
  required int host,
  required int rel,
  required int epsilon,
}) {
  final n = blocks.length;
  // §6.1：引用在题干起点之前（模型外），按今天行为放第一块之后。
  if (rel < 0) {
    return _SegmentPlacement.boundary(
      at: 1.clamp(0, n),
      rule: 'fallback_no_boundary',
      epsilon: epsilon,
    );
  }
  final hostBlock = blocks[host];
  // §4.1：块级宿主（独立公式 / 代码 / 表格 / 标题 / 原图回退块）
  // 保持今天的行为 at = h+1，不为其发明段语义。
  if (_isBlockLevelBoundary(hostBlock)) {
    return _SegmentPlacement.boundary(
      at: host + 1,
      rule: 'fallback_no_boundary',
      epsilon: epsilon,
    );
  }
  final runs = _separatorRuns(blocks, starts);
  // §3.2 ε 吸附：窗口 [rel−ε, rel] 内最晚相交的分隔符行程。
  // 只向后看（误差单向偏右，真实位置不可能在 rel 之后）。
  // 相交判定：行程的起点、终点（行程末尾偏移，即末字符之后的位置）
  // 或中间落在窗口内均算（§3.1：rel 恰在行程起点 / 行程内 / 行程
  // 终点三者同一边界）——行程末尾偏移落在窗口内即相交。
  _SeparatorRun? adsorbed;
  for (final r in runs) {
    if (r.globalStart <= rel && r.globalEnd >= rel - epsilon) {
      if (adsorbed == null || r.globalStart > adsorbed.globalStart) {
        adsorbed = r;
      }
    }
  }
  if (adsorbed != null) return _boundaryForRun(adsorbed, blocks, epsilon);
  // §6.4：rel 恰在宿主 TextBlock 末尾 → 块尾，不切分、不向前找段。
  // 行内公式宿主不走这条（§6.10：span 末尾仍归入包含该公式的段）。
  if (hostBlock is TextBlock && rel == starts[host + 1]) {
    return _SegmentPlacement.boundary(
      at: host + 1,
      rule: _endsWithSeparator(hostBlock.text)
          ? 'segment'
          : 'fallback_no_boundary',
      epsilon: epsilon,
    );
  }
  // 宿主 TextBlock 内 rel 之后的第一个分隔符。
  if (hostBlock is TextBlock) {
    final inBlockPos = rel - starts[host];
    for (final r in runs) {
      if (r.blockIndex != host) continue;
      if (r.startInBlock >= inBlockPos) {
        return _boundaryForRun(r, blocks, epsilon);
      }
    }
  }
  // 沿本段向后找：行内公式与后续 TextBlock 同属一段，直到分隔符
  // 或块级边界 / 题干末尾为止（§4.1 的段延伸）。
  for (var j = host + 1; j < n; j++) {
    final b = blocks[j];
    if (b is TextBlock) {
      for (final r in runs) {
        if (r.blockIndex == j) return _boundaryForRun(r, blocks, epsilon);
      }
      continue;
    }
    if (b is FormulaBlock && !b.displayMode) continue;
    // 块级边界：段在此结束，图插到该段最后一个块之后（§7 兜底）。
    return _SegmentPlacement.boundary(
      at: j,
      rule: 'fallback_no_boundary',
      epsilon: epsilon,
    );
  }
  return _SegmentPlacement.boundary(
    at: n,
    rule: 'fallback_no_boundary',
    epsilon: epsilon,
  );
}

/// 按切分点切分一个 TextBlock（§2.4）：runs 沿累计字符长度切分，
/// 横跨切分点的 run 一分为二；切分点恰在 run 边界时不切 run。
/// [cuts] 须去重升序、均在 (0, text.length) 内（调用方保证，
// 此处防御性过滤）。两半拼接逐字等于原文（§3.3）。
List<TextBlock> _splitTextBlockAt(TextBlock block, List<int> cuts) {
  final valid = cuts
      .where((c) => c > 0 && c < block.text.length)
      .toList();
  if (valid.isEmpty) return [block];
  final parts = <TextBlock>[];
  var start = 0;
  for (final cut in [...valid, block.text.length]) {
    final text = block.text.substring(start, cut);
    if (text.isEmpty) {
      start = cut;
      continue;
    }
    parts.add(
      TextBlock(
        text,
        runs: block.runs == null
            ? null
            : _sliceRuns(block.runs!, start, cut),
      ),
    );
    start = cut;
  }
  return parts.isEmpty ? [block] : parts;
}

/// 取 runs 在 [start, end) 区间内的切片（横跨的 run 一分为二）。
/// 切片内无样式 run 时返回 null（与解析器建 TextBlock 的口径一致：
/// 无样式则 runs 为 null）。
List<TextRun>? _sliceRuns(List<TextRun> runs, int start, int end) {
  final out = <TextRun>[];
  var pos = 0;
  for (final r in runs) {
    final rs = pos;
    final re = pos + r.text.length;
    if (re > start && rs < end) {
      final s = start > rs ? start - rs : 0;
      final e = end < re ? end - rs : r.text.length;
      out.add(
        TextRun(
          r.text.substring(s, e),
          bold: r.bold,
          italic: r.italic,
          script: r.script,
        ),
      );
    }
    pos = re;
  }
  if (out.isEmpty) return null;
  final hasStyle = out.any((r) => r.bold || r.italic || r.script != 0);
  return hasStyle ? out : null;
}

/// manual anchorRef 解析（Q2 REV2 §5.1）：`"h"` = 原块 `h` 之前，
/// `"h:s"` = 原块 `h` 的第 `s` 段之前（`s = 0` 等价于 `"h"`）。
/// 非法值钳制到最近的合法落点，不丢图、不抛错（与今天
/// `int.tryParse(...) ?? blocks.length` 的容错口径一致）。
/// `s` 的上限是该块切分后的段数，在 buildContentBlocks 里按实际
/// 切分结果再钳制一次（此处只钳 `s >= 0`）。
({int at, int part}) _parseManualAnchor(String ref, int blockCount) {
  final colon = ref.indexOf(':');
  if (colon < 0) {
    final at = int.tryParse(ref)?.clamp(0, blockCount) ?? blockCount;
    return (at: at, part: 0);
  }
  final h = int.tryParse(ref.substring(0, colon));
  final s = int.tryParse(ref.substring(colon + 1));
  if (h == null || s == null) return (at: blockCount, part: 0);
  if (h < 0) return (at: 0, part: 0);
  if (h >= blockCount) return (at: blockCount, part: 0);
  return (at: h, part: s < 0 ? 0 : s);
}

/// md 引用偏移 → 题干坐标（Q2 REV2 §1 的坐标换算补遗）。
///
/// 题干里没有图引用：md 坐标减去该引用之前、题干起点之后全部 md 图
/// 引用的字符长度，才是题干坐标。不减则第 2 个起的 md 图整体右偏
/// 约 31 字/个（一个 `![](page=…,bbox=[…])` 的长度），段归属全错、
/// 甚至进未关联区——§9.1 案例 5（同一块内两图）不用它过不了。
/// 只修正引用长度，不做逐公式源码跨度映射（§13 仍不做）；公式两侧
/// 空格的 ±2 误差仍由 ε 吸附兜底。首个引用不受影响（twin2 fig-0
/// 的 rel=101 不变）。
int _relInStemCoords(String mdResults, int refOffset, int stemStartInMd) {
  var preceding = 0;
  for (final r in _mdFigureRefs(mdResults)) {
    if (r.offset < stemStartInMd || r.offset >= refOffset) continue;
    preceding += _mdRefEnd(mdResults, r.offset) - r.offset;
  }
  return refOffset - stemStartInMd - preceding;
}

/// 计算每个图块的放置位置（WP-D #7 §7.2.2 + R5-4 + Q2 REV2 §5）。
///
/// - 有 optionLabel 且题干块里有唯一标号块 → 插在该选项段内
///   （md 锚点可靠时按 R5-4 保留原始锚点顺序，否则插标号块紧后方）；
/// - 有 optionLabel 但题干块里无标号块（如 autoSplit 已把选项切出题干）
///   → 未关联区（归属已知但无处可插，不冒充位置）；
/// - 无 optionLabel 且是选项区图（md 引用在首个选项标号之后）→ 未关联区；
/// - 无 optionLabel 的题干图 → md 偏移按段落段尾放置（Q2 REV2 §1–§4）
///   或文本纵向比例；
/// - 无 optionLabel 且锚点不可靠（fallback，或 md/text 锚点算不出位置）
///   → 未关联区。
/// 注意：此处已无 `at = blocks.length` 的默认 fallback——算不出位置的
/// 图块一律进未关联区，不再默认堆到末尾冒充正常内容。
List<_FigurePlacement> _computePlacements({
  required List<QuestionContentBlock> blocks,
  required List<int> blockTextLengths,
  required List<OcrFigure> figures,
  required String? mdResults,
  required int stemStartInMd,
}) {
  final labelBlockIndex = _optionLabelBlockIndex(blocks);
  // 标号块按段下标排序，供选项段边界（下一标号块）用。
  final labelBlocksSorted = labelBlockIndex.entries.toList()
    ..sort((a, b) => a.value.compareTo(b.value));
  final mdLabels = mdResults == null
      ? const <_OptionLabelOccurrence>[]
      : _optionLabelOccurrences(mdResults);
  final firstLabelOffset = mdLabels.isEmpty ? null : mdLabels.first.offset;
  // 块坐标轴起点：starts[i] 为块 i 的起点，starts[n] 为题干总长。
  final starts = <int>[0];
  for (final len in blockTextLengths) {
    starts.add(starts.last + len);
  }
  final placements = <_FigurePlacement>[];
  for (final fig in figures) {
    // Win11 反馈包 3 + Q2 REV2 §5.1：人工拖过的图块（anchorSource='manual'）
    // 位置由用户定：anchorRef 是原块坐标（`"h"` = 原块 `h` 之前，
    // `"h:s"` = 原块 `h` 的第 `s` 段之前），直接按分槽插到指定位置，
    // 不走 md/text/选项锚定；解析不出或越界时钳制到最近合法落点，不丢图。
    if (fig.anchorSource == 'manual') {
      final parsed = _parseManualAnchor(fig.anchorRef, blocks.length);
      placements.add(
        _FigurePlacement(
          figure: fig,
          at: parsed.at,
          zone: false,
          slotPart: parsed.part,
          rule: 'manual',
        ),
      );
      continue;
    }
    // 有归属：找标号块。
    if (fig.optionLabel != null) {
      final labelAt = labelBlockIndex[fig.optionLabel!];
      if (labelAt != null) {
        var spanEnd = blocks.length;
        for (final e in labelBlocksSorted) {
          if (e.value > labelAt) {
            spanEnd = e.value;
            break;
          }
        }
        var at = labelAt + 1;
        final refOffset = mdResults == null
            ? null
            : _mdOffsetForFigure(mdResults, fig);
        if (fig.anchorSource == 'md' &&
            refOffset != null &&
            stemStartInMd >= 0) {
          at = _optionPositionFromMd(
            mdResults: mdResults!,
            labels: mdLabels,
            optionLabel: fig.optionLabel!,
            refOffset: refOffset,
            labelAt: labelAt,
            spanEnd: spanEnd,
          );
        }
        placements.add(
          _FigurePlacement(
            figure: fig,
            at: at,
            zone: false,
            rule: 'option',
          ),
        );
      } else {
        placements.add(_FigurePlacement(figure: fig, at: null, zone: true));
      }
      continue;
    }
    // 无归属：选项区图（引用在首个标号之后）→ 未关联区。
    final refOffset = mdResults == null
        ? null
        : _mdOffsetForFigure(mdResults, fig);
    if (firstLabelOffset != null &&
        refOffset != null &&
        refOffset >= firstLabelOffset) {
      placements.add(_FigurePlacement(figure: fig, at: null, zone: true));
      continue;
    }
    // 题干图：md 偏移按段落段尾放置（Q2 REV2 §1–§4、§6）。
    if (fig.anchorSource == 'md' && refOffset != null && stemStartInMd >= 0) {
      final rel = _relInStemCoords(mdResults!, refOffset, stemStartInMd);
      final epsilon = _epsilonForRel(blocks, starts, rel);
      // §6 立约：宿主 h = min{ i | rel <= acc[i] }；不存在则无宿主。
      int? host;
      for (var i = 0; i < blocks.length; i++) {
        if (rel <= starts[i + 1]) {
          host = i;
          break;
        }
      }
      if (host == null) {
        // 引用超出题干范围 → 位置不可靠，进未关联区。
        placements.add(
          _FigurePlacement(
            figure: fig,
            at: null,
            zone: true,
            epsilon: epsilon,
          ),
        );
        continue;
      }
      final resolved = _resolveMdStemPlacement(
        blocks: blocks,
        starts: starts,
        host: host,
        rel: rel,
        epsilon: epsilon,
      );
      if (resolved.isCut) {
        placements.add(
          _FigurePlacement(
            figure: fig,
            at: resolved.blockIndex,
            zone: false,
            rule: resolved.rule,
            splitBlock: resolved.blockIndex,
            splitOffset: resolved.offset,
            epsilon: epsilon,
          ),
        );
      } else {
        placements.add(
          _FigurePlacement(
            figure: fig,
            at: resolved.at,
            zone: false,
            rule: resolved.rule,
            epsilon: epsilon,
          ),
        );
      }
      continue;
    }
    // 题干图原逻辑：文本纵向比例。
    if (fig.anchorSource == 'text') {
      final pageH = fig.spaceHeight ?? 0;
      if (pageH > 0 && blocks.isNotEmpty) {
        final ratio = (fig.srcRect.y + fig.srcRect.height / 2) / pageH;
        final at = (ratio * blocks.length).floor().clamp(0, blocks.length);
        placements.add(
          _FigurePlacement(
            figure: fig,
            at: at,
            zone: false,
            rule: 'text',
          ),
        );
        continue;
      }
    }
    // fallback / 锚点不可用 → 未关联区。
    placements.add(_FigurePlacement(figure: fig, at: null, zone: true));
  }
  return placements;
}

/// 放置层展开：解析 → 放置（含段切分）→ 展开序列 + 起源表。
/// [origins] 与返回块一一对应：内容段为（原块下标，段序号），
/// 图块为 null。分槽模型（Q2 REV2 §2.3）：每个已放置的图获得分槽
/// (i, j)——原块 i 内的第 j 段之前；排序键为（展开序号，sequenceIndex）。
/// 切分只发生在渲染时构造的序列里，保存拼回时两半按原文接回。
({List<QuestionContentBlock> blocks, List<({int orig, int part})?> origins})
_expandContentBlocks({
  required String stemMarkdown,
  required List<OcrFigure> figures,
  required String? mdResults,
}) {
  final blocks = parseQuestionContent(stemMarkdown);
  if (figures.isEmpty) {
    return (
      blocks: blocks,
      origins: [for (var i = 0; i < blocks.length; i++) (orig: i, part: 0)],
    );
  }
  final blockTextLengths = _blockTextLengths(blocks);
  final stemStart = _stemStartInMd(blocks, mdResults);
  final placements = _computePlacements(
    blocks: blocks,
    blockTextLengths: blockTextLengths,
    figures: figures,
    mdResults: mdResults,
    stemStartInMd: stemStart,
  );
  // 同一原块的切分点（去重、升序）：只由 md 题干图的段解析产生；
  // 同一源块只切一次，产出全部切分点（§2.2）。
  final cutsByBlock = <int, List<int>>{};
  for (final p in placements) {
    if (!p.zone && p.splitBlock != null && p.splitOffset != null) {
      (cutsByBlock[p.splitBlock!] ??= []).add(p.splitOffset!);
    }
  }
  for (final entry in cutsByBlock.entries) {
    entry.value.sort();
    var w = 0;
    for (var r = 0; r < entry.value.length; r++) {
      if (r == 0 || entry.value[r] != entry.value[r - 1]) {
        entry.value[w++] = entry.value[r];
      }
    }
    entry.value.length = w;
  }
  // 按切分点切分原块（只切 TextBlock；其余块型不切分）。
  final splitParts = <List<QuestionContentBlock>>[];
  for (var i = 0; i < blocks.length; i++) {
    final cuts = cutsByBlock[i];
    final b = blocks[i];
    if (cuts == null || cuts.isEmpty || b is! TextBlock) {
      splitParts.add([b]);
    } else {
      splitParts.add(_splitTextBlockAt(b, cuts));
    }
  }
  final numParts = [for (final p in splitParts) p.length];
  final prefix = <int>[0];
  for (final c in numParts) {
    prefix.add(prefix.last + c);
  }
  final totalParts = prefix.last;
  // 每个已放置图块的展开序号（切分块内按切分点排位；其余按分槽）。
  // 分槽 (i, numParts[i]) 与 (i+1, 0) 是同一展开位置（§2.3）。
  int expandedIndexOf(_FigurePlacement p) {
    if (p.splitBlock != null && p.splitOffset != null) {
      final cuts = cutsByBlock[p.splitBlock!]!;
      final rank = cuts.indexOf(p.splitOffset!) + 1;
      return prefix[p.splitBlock!] + rank;
    }
    final at = p.at!;
    if (at >= blocks.length) return totalParts;
    final part = p.slotPart.clamp(0, numParts[at]);
    return prefix[at] + part;
  }

  FigureBlock figureBlockFor(OcrFigure fig, bool zone) => FigureBlock(
    figureId: fig.id,
    cropPath: fig.cropPath,
    unconfirmed: zone ? true : fig.unconfirmed,
  );
  // 同一展开位置的多个图块保持 sequence_index 顺序。
  final placed = placements.where((p) => !p.zone).toList()
    ..sort((a, b) {
      final cmp = expandedIndexOf(a).compareTo(expandedIndexOf(b));
      if (cmp != 0) return cmp;
      return a.figure.sequenceIndex.compareTo(b.figure.sequenceIndex);
    });
  final zoned = placements.where((p) => p.zone).toList()
    ..sort((a, b) => a.figure.sequenceIndex.compareTo(b.figure.sequenceIndex));
  final out = <QuestionContentBlock>[];
  final origins = <({int orig, int part})?>[];
  var nextInsert = 0;
  var partCursor = 0;
  for (var i = 0; i < blocks.length; i++) {
    for (var j = 0; j < splitParts[i].length; j++) {
      while (nextInsert < placed.length &&
          expandedIndexOf(placed[nextInsert]) == partCursor) {
        final fig = placed[nextInsert].figure;
        out.add(figureBlockFor(fig, false));
        origins.add(null);
        nextInsert++;
      }
      out.add(splitParts[i][j]);
      origins.add((orig: i, part: j));
      partCursor++;
    }
  }
  while (nextInsert < placed.length) {
    final fig = placed[nextInsert].figure;
    out.add(figureBlockFor(fig, false));
    origins.add(null);
    nextInsert++;
  }
  if (zoned.isNotEmpty) {
    // Win11 反馈包 3：未关联图块默认放序列末尾，不再插区标题、不再标
    // “位置未确认”；顺序按 sequence_index，用户自己拖到正确位置。
    for (final z in zoned) {
      // 进未关联区本身即位置未确认：强制标未确认，不论原 anchorSource。
      out.add(figureBlockFor(z.figure, true));
      origins.add(null);
    }
  }
  return (blocks: out, origins: origins);
}

/// 把图块按阅读顺序插入题干内容段（渲染用；见文件头“渲染插入口径”）。
///
/// - md 锚定的题干图：按 md 引用在全文中的字符位置，插入到所属段落段
///   的段尾（Q2 REV2 §1：多段块在段落边界处切分后插入，单段块与今天
///   一致落在块尾）；
/// - text 锚定的题干图：按其在页内的纵向相对位置插入（图块中心 y /
///   页高 × 段数，钳制在段范围内）；
/// - 有 optionLabel 的图块：插在其选项标号所在段内（R5-4：md 锚点可靠
///   时保留原始锚点顺序，否则插标号块紧后方；标号块不在题干里时进
///   未关联区）；
/// - 人工拖过的图块（anchorSource='manual'）：按 anchorRef（原块坐标
///   `"h"` 或 `"h:s"`，见 §5.1）直接插到指定位置，不走任何自动锚定；
/// - 无法可靠放置的图块：默认放序列末尾（Win11 反馈包 3：不再设独立
///   「未关联图片」区、不再标“位置未确认”，用户自己拖到正确位置）。
/// 只读渲染与纠错编辑器读同一份持久化顺序（ocr_figures 的 JSON 顺序
/// 即 sequence_index 顺序）。
List<QuestionContentBlock> buildContentBlocks({
  required String stemMarkdown,
  required List<OcrFigure> figures,
  required String? mdResults,
}) {
  return _expandContentBlocks(
    stemMarkdown: stemMarkdown,
    figures: figures,
    mdResults: mdResults,
  ).blocks;
}

/// [buildContentBlocks] 的配套纯函数（Q2 REV2 §5.1(a)）：返回展开后
/// 每块对应的（原块下标，段序号）；图块对应 null。编辑器拖动计数用：
/// 切分出的两段共享同一原块下标，只计 1；落点在两段之间时记 `"h:s"`。
/// 与 [buildContentBlocks] 同输入，起源表与展开块一一对应。
List<({int orig, int part})?> expandedBlockOrigins({
  required String stemMarkdown,
  required List<OcrFigure> figures,
  required String? mdResults,
}) {
  return _expandContentBlocks(
    stemMarkdown: stemMarkdown,
    figures: figures,
    mdResults: mdResults,
  ).origins;
}

/// R5-1 逐图诊断记录（结构化字段，供 Win11 真机补做 live 诊断复用）。
///
/// 不读库、不读文件、不改代码：只根据传入的图块 + 题干 + md 全文计算。
/// 每条记录含：figure ID；原始 bbox（4 个数 + 单位）；bbox 所属坐标系
/// （PDF 页面空间还是 PNG 像素空间——本流水线只用 PNG 像素空间，见 U2）；
/// 切片像素尺寸；本次请求实际使用的 padX/padY；md 引用原文；对应文本
/// 锚点；anchorSource；mdOrder；当前最终插入位置（块序号）；是否在
/// 未关联区；坐标系问题（有则报，无则 null）。
/// 人工真值表（R5-2：Figure / 人工确认归属 / 当前系统归属 / 差异）须由
/// 人工看原始页面图像填写，不在本函数内预设。
/// 另注意：原始 PDF 页面尺寸（pt）、页面 PNG 实际像素尺寸、裁切区域及
/// 裁切偏移、缩放比例不在 OCR 图块数据里——GLM 只见切片像素，PDF 层
/// 参数从不进入本流水线（U2）；live 诊断时由导出方另行提供。
List<Map<String, Object?>> diagnoseFigures({
  required List<OcrFigure> figures,
  required String stemMarkdown,
  required String? mdResults,
}) {
  final blocks = parseQuestionContent(stemMarkdown);
  final stemStart = _stemStartInMd(blocks, mdResults);
  final rendered = buildContentBlocks(
    stemMarkdown: stemMarkdown,
    figures: figures,
    mdResults: mdResults,
  );
  // 未关联区判定改走 placements（Win11 反馈包 3：渲染里已不再插区标题块，
  // 再按标题块扫描永远判不出在区内）。
  final placements = _computePlacements(
    blocks: blocks,
    blockTextLengths: _blockTextLengths(blocks),
    figures: figures,
    mdResults: mdResults,
    stemStartInMd: stemStart,
  );
  final zoneIds = {for (final p in placements) if (p.zone) p.figure.id};
  final placementById = {for (final p in placements) p.figure.id: p};
  // md 引用 bbox 在图块列表中无对应者（疑似裁切偏移/缩放错误）。
  final refs = mdResults == null ? const <_MdFigureRef>[] : _mdFigureRefs(mdResults);
  final unmatchedRefCount = refs
      .where(
        (ref) => !figures.any(
          (f) => f.bbox2d.length == 4 && _bboxMatches(f.bbox2d, ref.bbox),
        ),
      )
      .length;
  final out = <Map<String, Object?>>[];
  for (final fig in figures) {
    int? insertionIndex;
    var inZone = false;
    for (var i = 0; i < rendered.length; i++) {
      final b = rendered[i];
      if (b is FigureBlock && b.figureId == fig.id) {
        insertionIndex = i;
      }
    }
    // 未关联区判定：placements 里 zone 为 true 的图块。
    final insertionIdx = insertionIndex;
    if (insertionIdx != null) {
      inZone = zoneIds.contains(fig.id);
    }
    String? mdRefRaw;
    int? mdRefOffset;
    int? mdOrder;
    if (fig.anchorSource == 'md') {
      mdOrder = int.tryParse(fig.anchorRef);
      if (mdOrder != null && mdOrder >= 0 && mdOrder < refs.length) {
        mdRefOffset = refs[mdOrder].offset;
        mdRefRaw = mdResults!.substring(
          refs[mdOrder].offset,
          _mdRefEnd(mdResults, refs[mdOrder].offset),
        );
      }
    }
    String? coordinateIssue;
    final spaceMismatch =
        fig.spaceWidth != null &&
        fig.spaceHeight != null &&
        ((fig.spaceWidth! - fig.transform.reqW).abs() > figureBboxTolerancePx ||
            (fig.spaceHeight! - fig.transform.reqH).abs() > figureBboxTolerancePx);
    if (spaceMismatch) {
      coordinateIssue = '图块空间尺寸与本次请求尺寸不一致'
          '（space ${fig.spaceWidth}×${fig.spaceHeight}，'
          '请求 ${fig.transform.reqW}×${fig.transform.reqH}），不猜坐标';
    } else if (unmatchedRefCount > 0) {
      coordinateIssue = 'md 引用 bbox 在图块列表中无对应 layout 块'
          '（$unmatchedRefCount 个引用未匹配），疑似裁切偏移/缩放错误，'
          '不放宽阈值硬匹配，需人工核对原始页面图像';
    }
    out.add({
      'figure_id': fig.id,
      'bbox_2d': [...fig.bbox2d],
      'bbox_unit': 'px（送入 GLM 的图像像素坐标，原点左上角）',
      'coordinate_system':
          'PNG 像素空间（送入 GLM 的图像）；PDF 点坐标 / MediaBox / '
          'CropBox / Rotate / UserUnit 不进入本流水线（U2）',
      'slice_path': fig.slicePath,
      'input_hash': fig.inputHash,
      'slice_pixel_size': '${fig.transform.srcW}×${fig.transform.srcH}',
      'req_pixel_size': '${fig.transform.reqW}×${fig.transform.reqH}',
      'pad_x': fig.transform.padX,
      'pad_y': fig.transform.padY,
      'md_ref_raw': mdRefRaw,
      'md_ref_offset': mdRefOffset,
      'text_anchor': fig.anchorSource == 'text' ? fig.anchorRef : null,
      'anchor_source': fig.anchorSource,
      'md_order': mdOrder,
      'option_label': fig.optionLabel,
      'stem_start_in_md': stemStart,
      'insertion_index': insertionIndex,
      'in_unassociated_zone': inZone,
      // Q2 REV2 §9.4（OQ5 已确认，只增键）：放置详情，供下一次 Win11
      // 诊断验证新规则是否触发、语料度量统计兜底率。
      // rule：'segment' | 'fallback_no_boundary' | 'zone' | 'manual' |
      // 'text' | 'option'；split_block / split_offset 仅块内切分时有值。
      'placement_detail': {
        'rule': placementById[fig.id]?.rule ?? 'zone',
        'split_block': placementById[fig.id]?.splitBlock,
        'split_offset': placementById[fig.id]?.splitOffset,
        'epsilon': placementById[fig.id]?.epsilon ?? 0,
      },
      'coordinate_issue': coordinateIssue,
      'rotation_note': '页面旋转只在渲染时由 pdfrx 应用一次；逐图不做旋转处理（U2 显式假设）',
    });
  }
  return out;
}

/// md 图引用原文的结束位置（供 [diagnoseFigures] 截取引用原文）。
int _mdRefEnd(String md, int start) {
  final close = md.indexOf(')', start);
  return close < 0 ? md.length : close + 1;
}

/// md 全文里第 [figure.anchorRef] 号图引用的字符偏移（md 锚定用）。
int? _mdOffsetForFigure(String mdResults, OcrFigure figure) {
  final order = int.tryParse(figure.anchorRef);
  if (order == null) return null;
  final refs = _mdFigureRefs(mdResults);
  if (order < 0 || order >= refs.length) return null;
  return refs[order].offset;
}
