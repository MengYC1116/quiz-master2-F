// 十三批 M5：公式原图裁图（纯函数，无 UI、无网络、无数据库依赖）。
//
// GPT 评审 §3.4：公式恢复为原图时，按 GLM `layout_details` 的 bbox
// 坐标从题切片里裁公式小图；裁不到用整张切片。
//
// 实测说明（2026-11-18，`~/workspace/batch13-work/glm-compare/` 全量
// 样本）：GLM 单题返回的 layout_details 只有 `text` / `image` 两种
// label，没有 `formula` 块（公式 inline 在 text 块里）。所以本函数
// 按“label 含 formula 的块”找 bbox，找不到就返回 null——调用方
// （StemEditor）用整张切片当公式原图。以后 GLM 返回 formula 块时，
// 本函数无需改接口就能裁出小图。
//
// 坐标系：bbox_2d 是 GLM 坐标空间里的 [x1, y1, x2, y2]；同一块的
// width / height 是该坐标空间的尺寸（实测如 1975×232）。十四批 M2
// 附带修复：换算用平移公式（x_src = x_api − padX，y_src = y_api − padY，
// padX/padY 取本次 OCR 请求保存的真实转换元数据，不再假定 0.30；
// 未加白边时 padX=padY=0），再 clip 到图内；元数据缺失或块尺寸与
// 请求尺寸对不上（允差 ±2px）时安全返回 null，不猜。旧实现只用缩放
// （x · W / W′）不用平移，对加白边图是错的（仅中心点巧合正确，
// 边缘偏差可达 0.1875W）——该函数目前因 GLM 单题不返回 formula 块
// 而恒返回 null、从未实际裁过图，是潜伏问题不是现行 bug；本次按
// M2 坐标契约改用平移公式并加单测锁定。

import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../services/glm_ocr_client.dart';
import 'ocr_figures.dart';

/// layout_details 里一个带公式 bbox 的块（内部结构，不外露）。
class _FormulaBox {
  const _FormulaBox({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    this.spaceWidth,
    this.spaceHeight,
  });

  final double x1;
  final double y1;
  final double x2;
  final double y2;
  final double? spaceWidth;
  final double? spaceHeight;
}

/// 从 ocr_raw（[GlmOcrRawData] JSON 包）里取出全部公式块的 bbox
///（按 layout_details 出现顺序；label 含 `formula` 才算）。
/// 无 raw、解析失败、无公式块时返回空列表。
List<_FormulaBox> _formulaBoxesFromRaw(String? ocrRaw) {
  final raw = GlmOcrRawData.tryParse(ocrRaw);
  if (raw == null) return const [];
  final out = <_FormulaBox>[];
  for (final page in raw.layoutDetails) {
    if (page is! List) continue;
    for (final block in page) {
      if (block is! Map) continue;
      final label = block['label'];
      if (label is! String ||
          !label.toLowerCase().contains('formula')) {
        continue;
      }
      final bbox = block['bbox_2d'];
      if (bbox is! List || bbox.length != 4) continue;
      final nums = bbox.map((e) => e is num ? e.toDouble() : null).toList();
      if (nums.any((e) => e == null)) continue;
      final width = block['width'];
      final height = block['height'];
      out.add(
        _FormulaBox(
          x1: nums[0]!,
          y1: nums[1]!,
          x2: nums[2]!,
          y2: nums[3]!,
          spaceWidth: width is num ? width.toDouble() : null,
          spaceHeight: height is num ? height.toDouble() : null,
        ),
      );
    }
  }
  return out;
}

/// 裁出第 [formulaIndex] 个公式的原图小图（PNG 字节）。
///
/// - [sliceBytes]：题切片的 PNG/JPG 字节（磁盘切片原样，不含白边）。
/// - [ocrRaw]：题的 ocr_raw 包（含 layout_details）。
/// - [formulaIndex]：题干里第几个公式块（按 parse 出的 FormulaBlock
///   顺序，从 0 计），与公式 bbox 列表按出现顺序一一对应。
///
/// 返回 null 的情形（调用方一律用整张切片当公式原图）：无公式 bbox、
/// 下标越界、图片解不出、坐标换算后裁不出有效区域。绝不抛异常。
Uint8List? cropFormulaImageBytes({
  required Uint8List sliceBytes,
  required String? ocrRaw,
  required int formulaIndex,
}) {
  final boxes = _formulaBoxesFromRaw(ocrRaw);
  if (formulaIndex < 0 || formulaIndex >= boxes.length) return null;
  final box = boxes[formulaIndex];
  final src = img.decodeImage(sliceBytes);
  if (src == null) return null;
  // 十四批 M2：平移公式 + 本次请求的真实转换元数据（raw 包的
  // transform 键）。旧包没有 transform 时：只有块空间尺寸与切片
  // 尺寸一致才按“未加白边”（padX=padY=0）处理；尺寸不一致说明
  // 请求很可能加过白边但元数据缺失——安全返回 null，不猜。
  final raw = GlmOcrRawData.tryParse(ocrRaw);
  final transform = raw?.transform;
  final effectiveTransform = transform ??
      ((box.spaceWidth?.toInt() == src.width &&
              box.spaceHeight?.toInt() == src.height)
          ? OcrRequestTransform(
              srcW: src.width,
              srcH: src.height,
              reqW: src.width,
              reqH: src.height,
              padX: 0,
              padY: 0,
            )
          : null);
  if (effectiveTransform == null) return null;
  final rect = convertApiBboxToSrc(
    bbox: [
      box.x1.toInt(),
      box.y1.toInt(),
      box.x2.toInt(),
      box.y2.toInt(),
    ],
    spaceWidth: box.spaceWidth?.toInt(),
    spaceHeight: box.spaceHeight?.toInt(),
    transform: effectiveTransform,
  );
  if (rect == null) return null;
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
