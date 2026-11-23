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

import 'package:flutter/painting.dart' show FileImage, PaintingBinding;

import '../models/models.dart';

/// 框坐标变换：原页坐标 → 顺时针旋转 [degreesClockwise] 后的页坐标。
///
/// 顺时针 90°：(x, y) → (1 - y, x)，框变为 (1 - y - h, x, h, w)；
/// 180°：(x, y) → (1 - x, 1 - y)；270°：(x, y) → (y, 1 - x)。
/// 用途：页已旋转 θ 后点“恢复自动框”——检测在原页上跑、
/// 结果是原页坐标，进框列表前必须先做这个变换，否则错位。
QuestionBox rotateBoxToRotatedPage(QuestionBox box, int degreesClockwise) {
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
  // SR-P2-70：钳制要按“区间与 [0,1] 求交”算——先钳左上角，再把宽高
  // 收到剩余空间。旧写法只钳左上角、不缩宽高：x=-0.1、w=0.5 的框会
  // 变成 x=0、w=0.5（应为 0.4），框整体右移且变宽；右端越界同理。
  // 与 YoloOnnxService.clampToPage（minSize: false）同一语义，
  // 这里不补最小尺寸，旋转变换不改变框的原始大小意图。
  final cx = nx.clamp(0.0, 1.0);
  final cy = ny.clamp(0.0, 1.0);
  // 宽/高为负的脏输入也收到 0，不把负尺寸漏出去。
  final cw = ((nx + nw).clamp(0.0, 1.0) - cx).clamp(0.0, 1.0);
  final ch = ((ny + nh).clamp(0.0, 1.0) - cy).clamp(0.0, 1.0);
  return QuestionBox(
    id: box.id,
    layer: box.layer,
    type: box.type,
    x: cx,
    y: cy,
    w: cw,
    h: ch,
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
QuestionBox unrotateBoxFromRotatedPage(QuestionBox box, int degreesClockwise) =>
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
    final out = await recorder.endRecording().toImage(newW, newH);
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

/// SR3-10：只读 PNG 的像素尺寸（解析 IHDR，不解码整图）。
/// 切片文件损坏/截断/不是 PNG 时返回 null——调用方按“尺寸不符”
/// 处理（重裁一次），不把解析失败当成正常尺寸。
/// PNG 文件头：8 字节签名 + 4 字节长度 + 'IHDR' + 宽/高（各 4 字节大端）。
({int width, int height})? pngDimensions(Uint8List bytes) {
  if (bytes.length < 24) return null;
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return null;
  }
  // IHDR 块：长度在 [8..12)，类型在 [12..16) 应为 'IHDR'。
  if (bytes[12] != 0x49 ||
      bytes[13] != 0x48 ||
      bytes[14] != 0x44 ||
      bytes[15] != 0x52) {
    return null;
  }
  int be32(int at) =>
      (bytes[at] << 24) |
      (bytes[at + 1] << 16) |
      (bytes[at + 2] << 8) |
      bytes[at + 3];
  final width = be32(16);
  final height = be32(20);
  if (width <= 0 || height <= 0) return null;
  return (width: width, height: height);
}

/// B 包 P1-05：图片像素上限 60MP（宽×高）。在完整解码前先读文件头拒绝，
/// 避免 20MB 以内的高压缩比图片解出数百 MB–GB 的 RGBA。
const int maxImagePixels = 60 * 1000 * 1000;

/// EXIF 归一化副本的页图长边目标；解码时直接按该尺寸缩放，避免把
/// 整张 60MP 图完整解码后再缩。
const int normalizedPageMaxLongEdge = 3000;

/// 读图片头得到宽高，不解码整图。支持导入允许的 PNG/JPEG；其它格式
/// 或损坏文件返回 null，由调用方按“图片打不开”处理。
({int width, int height})? readImageDimensions(Uint8List bytes) {
  final png = pngDimensions(bytes);
  if (png != null) return png;
  return _jpegDimensions(bytes);
}

/// 轻量 JPEG 尺寸解析：SOI 后逐段找 SOFn（C0–CF，排除 C4/C8/CC），
/// 读 height/width。只解析头部，不做熵解码。
({int width, int height})? _jpegDimensions(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
    return null;
  }
  var pos = 2;
  while (pos + 4 <= bytes.length) {
    if (bytes[pos] != 0xFF) return null;
    // 跳过填充的 0xFF 字节。
    while (pos < bytes.length && bytes[pos] == 0xFF) {
      pos++;
    }
    if (pos >= bytes.length) return null;
    final marker = bytes[pos];
    pos++;
    if (marker == 0xD8 || marker == 0xD9) return null;
    if (marker >= 0xD0 && marker <= 0xD7) continue; // RSTn 无长度
    if (marker == 0xDA) return null; // SOS 之前应已命中 SOFn
    if (pos + 2 > bytes.length) return null;
    final len = (bytes[pos] << 8) | bytes[pos + 1];
    if (len < 2 || pos + len > bytes.length) return null;
    final isSof = marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isSof) {
      if (len < 7) return null;
      final height = (bytes[pos + 3] << 8) | bytes[pos + 4];
      final width = (bytes[pos + 5] << 8) | bytes[pos + 6];
      if (width <= 0 || height <= 0) return null;
      return (width: width, height: height);
    }
    pos += len;
  }
  return null;
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
    final right = ((box.x + box.w) * src.width).round().clamp(0, src.width);
    final bottom = ((box.y + box.h) * src.height).round().clamp(0, src.height);
    final w = right - left, h = bottom - top;
    if (w <= 0 || h <= 0) {
      throw ArgumentError('框 $box 落在页图外，裁不出切片');
    }
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      src,
      ui.Rect.fromLTWH(
        left.toDouble(),
        top.toDouble(),
        w.toDouble(),
        h.toDouble(),
      ),
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint(),
    );
    final out = await recorder.endRecording().toImage(w, h);
    try {
      final data = await out.toByteData(format: ui.ImageByteFormat.png);
      return (png: data!.buffer.asUint8List(), width: w, height: h);
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
Future<
  ({
    Uint8List bakedPagePng,
    Uint8List slicePng,
    int sliceWidth,
    int sliceHeight,
  })
>
cropRotatedSlice(
  Uint8List pageBytes,
  QuestionBox boxInOriginalCoords,
  int degreesClockwise,
) async {
  final baked = await rotateImageBytes(pageBytes, degreesClockwise);
  final rotatedBox = rotateBoxToRotatedPage(
    boxInOriginalCoords,
    degreesClockwise,
  );
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
  try {
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    // SR-P2-69：Codec 用完即 dispose，否则每次解码漏一份 native 资源。
    codec.dispose();
  }
}

/// B 包 P1-05：按目标长边解码。仅用于导入时的 EXIF 归一化副本，
/// 避免 60MP 图完整解出后再缩放；切片/裁剪仍走 [_decode] 保留原分辨率。
Future<ui.Image> _decodeScaled(
  Uint8List bytes, {
  required int maxLongEdge,
}) async {
  final dims = readImageDimensions(bytes);
  int? targetWidth;
  int? targetHeight;
  if (dims != null) {
    final longEdge = math.max(dims.width, dims.height);
    if (longEdge > maxLongEdge) {
      final scale = maxLongEdge / longEdge;
      targetWidth = math.max(1, (dims.width * scale).round());
      targetHeight = math.max(1, (dims.height * scale).round());
    }
  }
  final codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: targetWidth,
    targetHeight: targetHeight,
  );
  try {
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    codec.dispose();
  }
}

/// 图片能否解码（SR-P2-61 导入校验用）：能解出首帧即 true，解码失败
/// 返回 false，不抛错。只校验、不保留像素；图片与 Codec 用完即释放。
Future<bool> canDecodeImageBytes(Uint8List bytes) async {
  ui.Codec? codec;
  try {
    // B 包 P1-05：校验格式只需要首帧，按 1×1 解码，避免为了“能不能
    // 打开”把整张大图解成 RGBA。像素上限由 readImageDimensions 先判。
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 1,
      targetHeight: 1,
    );
    final frame = await codec.getNextFrame();
    frame.image.dispose();
    return true;
  } catch (_) {
    return false;
  } finally {
    codec?.dispose();
  }
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

int? _readTiffOrientation(Uint8List bytes, int tiffStart, int tiffLen) {
  if (tiffLen < 8 || tiffStart + 8 > bytes.length) return null;
  final littleEndian = bytes[tiffStart] == 0x49 && bytes[tiffStart + 1] == 0x49;
  final bigEndian = bytes[tiffStart] == 0x4D && bytes[tiffStart + 1] == 0x4D;
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
  // B 包 P1-05：归一化副本按目标长边解码，不把整张原图完整展开。
  final img = await _decodeScaled(
    bytes,
    maxLongEdge: normalizedPageMaxLongEdge,
  ); // 解码即转正（见上）
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
///
/// FR-05：只清裸 FileImage 键不够——带 cacheWidth 的渲染（QuestionSlice /
/// CompactSliceThumb）走 ResizeImage 缓存键；ResizeImageKey 是私有的、
/// 构造不出来，且各渲染点的 cacheWidth 随 maxHeight × dpr 变化、无法
/// 逐个枚举。所以这里在清裸键之后再清整个图片缓存：重框确认 / 切片自愈
/// 是偶发操作，本地图片重解码成本可忽略；正在显示的旧图由切片 Image 的
/// ValueKey（写盘时间 + 大小）强制重建，见 widgets.dart 的 _sliceImageKey。
/// 返回值仍是裸键是否命中（与旧口径一致；清全缓存不计入返回值）。
///
/// FR-05（续）：只调 `clear()` 还不够——`clear()` 不清 live 图片：
/// 旧切片正显示在某处时，旧图仍以 live 条目留在缓存里；重建后旧态
/// 卸载，旧图回落 keepAlive，新解析又命中它。所以再调
/// `clearLiveImages()`：它只摘掉缓存加在 completer 上的追踪回调，
/// 不动正在显示的图片本身（widget 自己的监听还在，旧图照常显示到
/// 卸载）；此后新解析查不到旧条目，才会重新读盘。副作用是全应用
/// 正在显示的图片都失去 live 追踪，之后切页回来会重新读盘——偶发
/// 操作，可接受。
Future<bool> evictCachedFileImage(String path) async {
  final evicted = await FileImage(File(path)).evict();
  final cache = PaintingBinding.instance.imageCache;
  cache.clear();
  cache.clearLiveImages();
  return evicted;
}
