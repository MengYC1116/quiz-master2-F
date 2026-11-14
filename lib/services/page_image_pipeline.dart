/// P0.5 图片链路小样落成的共享小工具（见
/// `docs/ui-replication/P0B2-P05-SPIKE-REPORT.md`).
///
/// 覆盖 P2 主链要复用的三件小事，全部是纯函数 / 无状态操作，
/// 不接任何应用界面、不动 Schema、不改 pubspec：
/// 1. 整页旋转烘焙时的框坐标变换（原页坐标 ↔ 旋转后页坐标）；
/// 2. 按框裁剪页图写 PNG 切片；
/// 3. JPEG EXIF 方向的手写轻量解析与归一化（不引入新依赖）。
///
/// 角度约定：顺时针（与修框编辑器 `_rotatePage` 的 +90° 一致），
/// 只取 0 / 90 / 180 / 270 四个值。框坐标一律是页面 0..1 相对坐标。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show FileImage;

import '../models/models.dart';

/// 框坐标变换：原页坐标 → 顺时针旋转 [degreesClockwise] 后的页坐标。
///
/// 顺时针 90°：(x, y) → (1 - y, x)，框变为 (1 - y - h, x, h, w)；
/// 180°：(x, y) → (1 - x, 1 - y)；270°：(x, y) → (y, 1 - x)。
/// 用途：页已旋转 θ 后点“恢复自动框”——检测在原页上跑、
/// 结果是原页坐标，进框列表前必须先做这个变换，否则错位。
QuestionBox rotateBoxToRotatedPage(
  QuestionBox box,
  int degreesClockwise,
) {
  final deg = ((degreesClockwise % 360) + 360) % 360;
  final x = box.x, y = box.y, w = box.w, h = box.h;
  late final double nx, ny, nw, nh;
  switch (deg) {
    case 0:
      nx = x;
      ny = y;
      nw = w;
      nh = h;
    case 90:
      nx = 1 - y - h;
      ny = x;
      nw = h;
      nh = w;
    case 180:
      nx = 1 - x - w;
      ny = 1 - y - h;
      nw = w;
      nh = h;
    case 270:
      nx = y;
      ny = 1 - x - w;
      nw = h;
      nh = w;
    default:
      throw ArgumentError('只支持 0/90/180/270，得到 $degreesClockwise');
  }
  return QuestionBox(
    id: box.id,
    layer: box.layer,
    type: box.type,
    x: nx.clamp(0.0, 1.0),
    y: ny.clamp(0.0, 1.0),
    w: nw.clamp(0.0, 1.0 - nx.clamp(0.0, 1.0)),
    h: nh.clamp(0.0, 1.0 - ny.clamp(0.0, 1.0)),
    // 变换只改坐标，其余字段（置信度 / 来源 / 归属 / 页码）原样保留。
    confidence: box.confidence,
    origin: box.origin,
    parentBoxId: box.parentBoxId,
    page: box.page,
    collectTaskId: box.collectTaskId,
    questionId: box.questionId,
    updatedAt: box.updatedAt,
  );
}

/// [rotateBoxToRotatedPage] 的逆变换：旋转后页坐标 → 原页坐标。
QuestionBox unrotateBoxFromRotatedPage(
  QuestionBox box,
  int degreesClockwise,
) =>
    rotateBoxToRotatedPage(box, (360 - degreesClockwise) % 360);

/// 把图片字节顺时针旋转 [degreesClockwise] 后编码为 PNG 返回。
/// 0° 时原样返回输入字节（不重新编码）。
///
/// 注意：输入必须是无 EXIF 的图片（PNG 或已归一化的副本）。
/// dart:ui 解码 JPEG 时已按 EXIF 方向自动转正，再把带 EXIF 的 JPEG
/// 传进来会转两次（小样 P0.5-6 实测）；带 EXIF 的 JPEG 先走
/// [normalizeExifImageBytes]，不要直接调本函数。
Future<Uint8List> rotateImageBytes(
  Uint8List bytes,
  int degreesClockwise,
) async {
  final deg = ((degreesClockwise % 360) + 360) % 360;
  if (deg == 0) return bytes;
  if (deg != 90 && deg != 180 && deg != 270) {
    throw ArgumentError('只支持 0/90/180/270，得到 $degreesClockwise');
  }
  final src = await _decode(bytes);
  try {
    final newW = (deg == 180) ? src.width : src.height;
    final newH = (deg == 180) ? src.height : src.width;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    switch (deg) {
      case 90:
        canvas.translate(newW.toDouble(), 0);
        canvas.rotate(math.pi / 2);
      case 180:
        canvas.translate(src.width.toDouble(), src.height.toDouble());
        canvas.rotate(math.pi);
      case 270:
        canvas.translate(0, newH.toDouble());
        canvas.rotate(3 * math.pi / 2);
    }
    canvas.drawImage(src, ui.Offset.zero, ui.Paint());
    final out =
        await recorder.endRecording().toImage(newW, newH);
    try {
      final data = await out.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      out.dispose();
    }
  } finally {
    src.dispose();
  }
}

/// 按 0..1 相对框 [box] 从页图字节裁剪，返回 PNG 与像素尺寸。
/// 矩形按像素四舍五入后钳制进图内；框落在图外时抛 [ArgumentError]。
Future<({Uint8List png, int width, int height})> cropBoxPng(
  Uint8List pageBytes,
  QuestionBox box,
) async {
  final src = await _decode(pageBytes);
  try {
    final left = (box.x * src.width).round().clamp(0, src.width);
    final top = (box.y * src.height).round().clamp(0, src.height);
    final right =
        ((box.x + box.w) * src.width).round().clamp(0, src.width);
    final bottom =
        ((box.y + box.h) * src.height).round().clamp(0, src.height);
    final w = right - left, h = bottom - top;
    if (w <= 0 || h <= 0) {
      throw ArgumentError('框 $box 落在页图外，裁不出切片');
    }
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      src,
      ui.Rect.fromLTWH(
          left.toDouble(), top.toDouble(), w.toDouble(), h.toDouble()),
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint(),
    );
    final out = await recorder.endRecording().toImage(w, h);
    try {
      final data = await out.toByteData(format: ui.ImageByteFormat.png);
      return (
        png: data!.buffer.asUint8List(),
        width: w,
        height: h,
      );
    } finally {
      out.dispose();
    }
  } finally {
    src.dispose();
  }
}

/// P2 确认时的组合操作：页图先按 [degreesClockwise] 烘焙旋转，
/// 再把原页坐标的 [boxInOriginalCoords] 换算到旋转后坐标系裁剪。
/// 返回烘焙后页图与切片（切片内容应与原页直接裁剪一致）。
Future<({
  Uint8List bakedPagePng,
  Uint8List slicePng,
  int sliceWidth,
  int sliceHeight,
})> cropRotatedSlice(
  Uint8List pageBytes,
  QuestionBox boxInOriginalCoords,
  int degreesClockwise,
) async {
  final baked = await rotateImageBytes(pageBytes, degreesClockwise);
  final rotatedBox =
      rotateBoxToRotatedPage(boxInOriginalCoords, degreesClockwise);
  final slice = await cropBoxPng(baked, rotatedBox);
  return (
    bakedPagePng: baked,
    slicePng: slice.png,
    sliceWidth: slice.width,
    sliceHeight: slice.height,
  );
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}

/// 手写轻量 JPEG EXIF Orientation 解析（不引入 image 包）。
///
/// 只读 APP1（Exif）段的 IFD0 里 tag 0x0112，返回 1..8，
/// 无 EXIF / 非 JPEG / 解析失败时返回 null（不抛错）。
/// dart:ui 不暴露 EXIF，所以这里直接按 JPEG/TIFF 结构解析：
/// SOI → 逐段跳过（段长含长度字段本身 2 字节）→ APP1 "Exif\0\0"
/// → TIFF 头（II/MM + 0x002A + IFD0 偏移）→ 12 字节/条目找 tag。
int? readJpegExifOrientation(Uint8List bytes) {
  try {
    if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
      return null; // 非 JPEG
    }
    var pos = 2;
    while (pos + 4 <= bytes.length) {
      if (bytes[pos] != 0xFF) return null;
      final marker = bytes[pos + 1];
      if (marker == 0xDA || marker == 0xD9) return null; // SOS / EOI 前无 APP1
      if (pos + 4 > bytes.length) return null;
      final len = (bytes[pos + 2] << 8) | bytes[pos + 3];
      if (len < 2 || pos + 2 + len > bytes.length) return null;
      if (marker == 0xE1 && len >= 8) {
        final segStart = pos + 4;
        if (bytes[segStart] == 0x45 && // "Exif\0\0"
            bytes[segStart + 1] == 0x78 &&
            bytes[segStart + 2] == 0x69 &&
            bytes[segStart + 3] == 0x66 &&
            bytes[segStart + 4] == 0 &&
            bytes[segStart + 5] == 0) {
          return _readTiffOrientation(bytes, segStart + 6, len - 8);
        }
      }
      pos += 2 + len;
    }
    return null;
  } catch (_) {
    return null;
  }
}

int? _readTiffOrientation(
    Uint8List bytes, int tiffStart, int tiffLen) {
  if (tiffLen < 8 || tiffStart + 8 > bytes.length) return null;
  final littleEndian =
      bytes[tiffStart] == 0x49 && bytes[tiffStart + 1] == 0x49;
  final bigEndian =
      bytes[tiffStart] == 0x4D && bytes[tiffStart + 1] == 0x4D;
  if (!littleEndian && !bigEndian) return null;

  int u16(int off) {
    final a = bytes[tiffStart + off], b = bytes[tiffStart + off + 1];
    return littleEndian ? (a | (b << 8)) : ((a << 8) | b);
  }

  int u32(int off) {
    final a = bytes[tiffStart + off],
        b = bytes[tiffStart + off + 1],
        c = bytes[tiffStart + off + 2],
        d = bytes[tiffStart + off + 3];
    return littleEndian
        ? (a | (b << 8) | (c << 16) | (d << 24))
        : ((a << 24) | (b << 16) | (c << 8) | d);
  }

  if (u16(2) != 0x002A) return null;
  final ifdOff = u32(4);
  if (ifdOff + 2 > tiffLen) return null;
  final count = u16(ifdOff);
  for (var i = 0; i < count; i++) {
    final entry = ifdOff + 2 + i * 12;
    if (entry + 12 > tiffLen) return null;
    if (u16(entry) != 0x0112) continue; // Orientation
    final type = u16(entry + 2);
    final n = u32(entry + 4);
    if (n != 1) return null;
    if (type == 3) return u16(entry + 8); // SHORT：值在前 2 字节
    if (type == 4) return u32(entry + 8); // LONG：值在 4 字节
    return null;
  }
  return null;
}

/// EXIF Orientation → 为显示正向需顺时针旋转的角度。
/// 1（正向）→ 0；3 → 180；6 → 90；8 → 270。
/// 2 / 4 / 5 / 7 是镜像方向（需翻转，旋转不够），返回 null——
/// 手机照片几乎只用 1/3/6/8，镜像方向暂不支持，见小样报告。
///
/// 本函数只做“方向 → 角度”的说明映射：实际归一化并不按这个角度
/// 再转一次——dart:ui 解码 JPEG 时已按 EXIF 自动转正（小样 P0.5-6
/// 实测：方向 6 的 400×300 JPEG 解码后即为 300×400 正向像素），
/// [normalizeExifImageBytes] 只需把解码后的正向像素编码为 PNG 副本。
int? exifOrientationToClockwiseDegrees(int orientation) {
  switch (orientation) {
    case 1:
      return 0;
    case 3:
      return 180;
    case 6:
      return 90;
    case 8:
      return 270;
    default:
      return null;
  }
}

/// EXIF 归一化：读方向，!= 1 且可旋转时生成一张已旋转的页图副本
/// （PNG 编码——dart:ui 只方便输出 PNG；见方案 §1.4，
/// 仅 EXIF != 1 时生成副本，== 1 时两路径可为同一文件）。
/// 返回归一化后的字节、检出的方向（无 EXIF 记为 1）、是否生成了副本。
/// 镜像方向（2/4/5/7）返回原字节、wasNormalized=false，调用方应提示。
///
/// 实现关键（小样 P0.5-6 实测）：dart:ui 解码 JPEG 时已按 EXIF
/// 自动转正，所以这里**只解码再编码**，绝不按角度再转一次——
/// 多转一次会把正向图又转歪（小样初版即因此失败）。
Future<({Uint8List bytes, int orientation, bool wasNormalized})>
    normalizeExifImageBytes(Uint8List bytes) async {
  final orientation = readJpegExifOrientation(bytes) ?? 1;
  final degrees = exifOrientationToClockwiseDegrees(orientation);
  if (degrees == null || degrees == 0) {
    return (bytes: bytes, orientation: orientation, wasNormalized: false);
  }
  final img = await _decode(bytes); // 解码即转正（见上）
  try {
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return (
      bytes: data!.buffer.asUint8List(),
      orientation: orientation,
      wasNormalized: true,
    );
  } finally {
    img.dispose();
  }
}

/// 重切图 / 页图替换后清掉 [FileImage] 缓存，再读到的是新图。
/// P2 重切图覆盖同名文件、旋转烘焙换页图后都要先调这个再读。
Future<bool> evictCachedFileImage(String path) =>
    FileImage(File(path)).evict();
