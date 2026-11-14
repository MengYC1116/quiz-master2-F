// P0.5 图片链路小样：§1.4–§1.6 假设验证（不写迁移、不动 Schema）。
//
// 真实检测部分需要 onnxruntime 原生库：跑之前设
//   LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux
// 否则相关测试按既有惯例跳过（见 yolo_onnx_service_test 的冒烟测试）。
// 真实页图：~/workspace/yolo-test-images/ 三张 1653×2200 PNG。
// （任务书写的 gs_p046/047/048 即这三张文件。）
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/page_image_pipeline.dart';
import 'package:quiz_master2/services/yolo_onnx_service.dart';

const _pagesDir = '/home/hatch/workspace/yolo-test-images';
const _page1 = '$_pagesDir/16676QPFVu1ck984AfWQHruoHWRfTz99b.png';

QuestionBox _box(double x, double y, double w, double h) => QuestionBox(
    id: 'b', layer: 1, type: 'question', x: x, y: y, w: w, h: h);

/// PNG 字节 → 原始 RGBA + 尺寸。
Future<({Uint8List rgba, int width, int height})> _decodeRgba(
    Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final img = frame.image;
  try {
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    return (
      rgba: data!.buffer.asUint8List(),
      width: img.width,
      height: img.height,
    );
  } finally {
    img.dispose();
  }
}

/// 两张同尺寸图的平均绝对像素差（0–255）；尺寸不同返回 double.infinity。
Future<double> _meanAbsDiff(Uint8List a, Uint8List b) async {
  final da = await _decodeRgba(a);
  final db = await _decodeRgba(b);
  if (da.width != db.width || da.height != db.height) return double.infinity;
  var sum = 0;
  for (var i = 0; i < da.rgba.length; i++) {
    sum += (da.rgba[i] - db.rgba[i]).abs();
  }
  return sum / da.rgba.length;
}

/// 取图中某像素的 RGB。
Future<(int, int, int)> _pixelAt(Uint8List png, int x, int y) async {
  final d = await _decodeRgba(png);
  final o = (y * d.width + x) * 4;
  return (d.rgba[o], d.rgba[o + 1], d.rgba[o + 2]);
}

/// 合成“试卷页”：800×1000 白底 + 黑色文字行 + 红块左上 + 蓝块右下。
/// 几何全部取整像素，旋转后像素比较应为精确相等。
Future<Uint8List> _syntheticPage() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 800, 1000),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF));
  final black = ui.Paint()..color = const ui.Color(0xFF000000);
  for (var i = 0; i < 10; i++) {
    canvas.drawRect(ui.Rect.fromLTWH(80, 200.0 + i * 70, 640, 12), black);
  }
  canvas.drawRect(const ui.Rect.fromLTWH(40, 40, 80, 80),
      ui.Paint()..color = const ui.Color(0xFFFF0000));
  canvas.drawRect(const ui.Rect.fromLTWH(680, 880, 80, 80),
      ui.Paint()..color = const ui.Color(0xFF0000FF));
  final img = await recorder.endRecording().toImage(800, 1000);
  try {
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    img.dispose();
  }
}

/// 通过 FileImage 读文件当前内容的第一帧（走 imageCache）。
/// 只在普通 test()（真异步）里用：testWidgets 的 FakeAsync 下
/// ImageStream 完成不了，会一直挂住（已实测）。
Future<ui.Image> _loadViaFileImage(File file) async {
  final completer = Completer<ui.Image>();
  final stream =
      FileImage(file).resolve(const ImageConfiguration());
  late ImageStreamListener listener;
  listener = ImageStreamListener((info, _) {
    if (!completer.isCompleted) completer.complete(info.image);
    stream.removeListener(listener);
  });
  stream.addListener(listener);
  return completer.future.timeout(const Duration(seconds: 15));
}

/// 取 ui.Image 中心像素的 RGB。
Future<(int, int, int)> _centerPixel(ui.Image img) async {
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final rgba = data!.buffer.asUint8List();
  final o = ((img.height ~/ 2) * img.width + (img.width ~/ 2)) * 4;
  return (rgba[o], rgba[o + 1], rgba[o + 2]);
}

/// 生成纯色 PNG（evict 测试用）。
Future<Uint8List> _solidPng(int color, int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()..color = ui.Color(color));
  final img = await recorder.endRecording().toImage(w, h);
  try {
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    img.dispose();
  }
}

void main() {
  group('P0.5-1 页图分辨率与检测（1653×2200 真实页）', () {
    test('检测：letterbox 1280 输入，框在页内；切片够宽、文字可读尺寸', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      if (!File(_page1).existsSync()) {
        markTestSkipped('本机无真实页图 $_page1');
        return;
      }
      final service = YoloOnnxService();
      final bytes = File(_page1).readAsBytesSync();
      final sw = Stopwatch()..start();
      final boxes = (await service.detectPage(imagePath: _page1, page: 1)).boxes;
      sw.stop();
      if (!service.hasRealModel) {
        markTestSkipped('本机无 onnxruntime 原生库，跳过真实推理');
        return;
      }
      // ignore: avoid_print
      print('P0.5-1 检测：页 1653×2200，检出 ${boxes.length} 框，'
          'detectPage 耗时 ${sw.elapsedMilliseconds}ms，'
          '纯推理 ${service.lastDetectStats?.totalMs}ms');
      expect(boxes.length, greaterThanOrEqualTo(5));
      for (final b in boxes) {
        expect(b.x, inInclusiveRange(0.0, 1.0));
        expect(b.y, inInclusiveRange(0.0, 1.0));
        expect(b.x + b.w, lessThanOrEqualTo(1.0 + 1e-9));
        expect(b.y + b.h, lessThanOrEqualTo(1.0 + 1e-9));
      }
      // 切片清晰度：取第 1 个框（整行题，约 0.79 页宽），切片应 ≥1000px 宽。
      final first = boxes.first;
      final slice = await cropBoxPng(bytes, first);
      // ignore: avoid_print
      print('P0.5-1 切片：box-q1 ${first.x.toStringAsFixed(3)},'
          '${first.y.toStringAsFixed(3)} ${first.w.toStringAsFixed(3)}x'
          '${first.h.toStringAsFixed(3)} → 切片 ${slice.width}×${slice.height}');
      expect(slice.width, greaterThanOrEqualTo(1000));
      expect(slice.height, greaterThanOrEqualTo(50));
      // 留一张切片供人工看文字清晰度（/tmp，不进仓库与数据目录）。
      final outDir = Directory('/tmp/p05-slices')..createSync(recursive: true);
      await File('${outDir.path}/page1-q1.png').writeAsBytes(slice.png);
    });
  });

  group('P0.5-2 旋转烘焙 90/180/270', () {
    test('方向约定：红块左上 → 90°右上 / 180°右下 / 270°左下', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final page = await _syntheticPage();
      // 红块在 (40,40)-(120,120)，左上；蓝块在右下。
      final r90 = await rotateImageBytes(page, 90); // 1000×800
      final r180 = await rotateImageBytes(page, 180); // 800×1000
      final r270 = await rotateImageBytes(page, 270); // 1000×800
      // 红块原在左上 (40..120, 40..120)：90°→右上，180°→右下，270°→左下。
      expect(await _pixelAt(r90, 920, 80), (255, 0, 0));
      expect(await _pixelAt(r180, 720, 920), (255, 0, 0));
      expect(await _pixelAt(r270, 80, 720), (255, 0, 0));
      // 蓝块原在右下 (680..760, 880..960)：90°→左下，180°→左上，270°→右上。
      expect(await _pixelAt(r90, 80, 720), (0, 0, 255));
      expect(await _pixelAt(r180, 80, 80), (0, 0, 255));
      expect(await _pixelAt(r270, 920, 80), (0, 0, 255));
    });

    test('烘焙确认路径：歪页 + 歪框 → 烘焙 θ → 切片与正向页直接裁剪一致',
        () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final upright = await _syntheticPage();
      // 正向页上的框（整像素对齐）：x 80..480, y 100..400。
      final boxU = _box(0.1, 0.1, 0.5, 0.3);
      final direct = await cropBoxPng(upright, boxU);
      expect(direct.width, 400);
      expect(direct.height, 300);
      for (final bake in [90, 180, 270]) {
        // 模拟：原页是歪的（正向页反向转了 360-θ），框也在歪页坐标系；
        // 用户转 θ 回正、确认烘焙。
        final skew = (360 - bake) % 360;
        final skewedPage = await rotateImageBytes(upright, skew);
        final skewedBox = rotateBoxToRotatedPage(boxU, skew);
        final result = await cropRotatedSlice(skewedPage, skewedBox, bake);
        final diff = await _meanAbsDiff(direct.png, result.slicePng);
        // ignore: avoid_print
        print('P0.5-2 烘焙 $bake°：切片 ${result.sliceWidth}×'
            '${result.sliceHeight}，与正向直接裁剪平均像素差 $diff');
        expect(result.sliceWidth, 400);
        expect(result.sliceHeight, 300);
        expect(diff, lessThan(0.5));
      }
    });
  });

  group('P0.5-2b 多页旋转：第 1 页转 90°、第 2 页不转', () {
    test('每页按自己的角度烘焙，互不干扰', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final pageA = await _syntheticPage();
      final pageB = await _syntheticPage();
      final rotations = <int, int>{1: 90, 2: 0}; // 页 → 角度，禁止全局共用
      final boxA = _box(0.1, 0.1, 0.5, 0.3);
      final boxB = _box(0.2, 0.2, 0.4, 0.2);
      // 第 1 页：歪页（反向转 270°）+ 歪框，烘焙 90° 回正。
      final skewedA = await rotateImageBytes(pageA, 270);
      final skewedBoxA = rotateBoxToRotatedPage(boxA, 270);
      final sliceA = await cropRotatedSlice(
          skewedA, skewedBoxA, rotations[1]!);
      final directA = await cropBoxPng(pageA, boxA);
      // 第 2 页：不转，直接裁剪。
      final sliceB = await cropRotatedSlice(pageB, boxB, rotations[2]!);
      final directB = await cropBoxPng(pageB, boxB);
      final diffA = await _meanAbsDiff(directA.png, sliceA.slicePng);
      final diffB = await _meanAbsDiff(directB.png, sliceB.slicePng);
      // ignore: avoid_print
      print('P0.5-2b 多页旋转：页1(90°)像素差 $diffA，页2(0°)像素差 $diffB');
      expect(diffA, lessThan(0.5));
      expect(diffB, lessThan(0.5));
      expect(sliceA.sliceWidth, 400);
      expect(sliceB.sliceWidth, 320);
    });
  });

  group('P0.5-5 旋转 → 恢复自动框：检测结果须先做坐标变换', () {
    test('纯数学：三个角度的框变换值', () {
      // 框 (0.1, 0.2, 0.3, 0.4)：90° → (0.4, 0.1, 0.4, 0.3)。
      final r90 = rotateBoxToRotatedPage(_box(0.1, 0.2, 0.3, 0.4), 90);
      expect(r90.x, closeTo(0.4, 1e-9));
      expect(r90.y, closeTo(0.1, 1e-9));
      expect(r90.w, closeTo(0.4, 1e-9));
      expect(r90.h, closeTo(0.3, 1e-9));
      final r180 = rotateBoxToRotatedPage(_box(0.1, 0.2, 0.3, 0.4), 180);
      expect(r180.x, closeTo(0.6, 1e-9));
      expect(r180.y, closeTo(0.4, 1e-9));
      expect(r180.w, closeTo(0.3, 1e-9));
      expect(r180.h, closeTo(0.4, 1e-9));
      final r270 = rotateBoxToRotatedPage(_box(0.1, 0.2, 0.3, 0.4), 270);
      expect(r270.x, closeTo(0.2, 1e-9));
      expect(r270.y, closeTo(0.6, 1e-9));
      expect(r270.w, closeTo(0.4, 1e-9));
      expect(r270.h, closeTo(0.3, 1e-9));
      // 往返：转过去再转回来等于原框。
      for (final deg in [90, 180, 270]) {
        final back = unrotateBoxFromRotatedPage(
            rotateBoxToRotatedPage(_box(0.1, 0.2, 0.3, 0.4), deg), deg);
        expect(back.x, closeTo(0.1, 1e-9));
        expect(back.y, closeTo(0.2, 1e-9));
        expect(back.w, closeTo(0.3, 1e-9));
        expect(back.h, closeTo(0.4, 1e-9));
      }
    });

    test('像素：变换后的框在旋转页上框住同一道题；不变换则错位', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final page = await _syntheticPage();
      final box = _box(0.1, 0.1, 0.5, 0.3); // 含红块上沿与文字行
      final direct = await cropBoxPng(page, box);
      for (final deg in [90, 180, 270]) {
        final rotatedPage = await rotateImageBytes(page, deg);
        final moved = rotateBoxToRotatedPage(box, deg);
        // 变换后的框在旋转页上裁出的内容 = 原切片整体旋转 deg。
        final movedSlice = await cropBoxPng(rotatedPage, moved);
        final expected = await rotateImageBytes(direct.png, deg);
        final diff = await _meanAbsDiff(expected, movedSlice.png);
        // 反例：不变换、拿原坐标直接去旋转页上裁，一定错位。
        final wrongSlice = await cropBoxPng(rotatedPage, box);
        final wrongDiff = await _meanAbsDiff(expected, wrongSlice.png);
        // ignore: avoid_print
        print('P0.5-5 恢复自动框 $deg°：变换后像素差 $diff，'
            '不变换像素差 $wrongDiff');
        expect(diff, lessThan(0.5));
        expect(wrongDiff, greaterThan(10));
      }
    });

    test('像素（真实页）：检测框经变换后在旋转页上框住同一道题', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      if (!File(_page1).existsSync()) {
        markTestSkipped('本机无真实页图 $_page1');
        return;
      }
      final bytes = File(_page1).readAsBytesSync();
      // 用探针实测的 box-q1（0.140, 0.085, 0.788, 0.054）作固定框。
      final box = _box(0.140, 0.085, 0.788, 0.054);
      final direct = await cropBoxPng(bytes, box);
      for (final deg in [90, 180, 270]) {
        final rotatedPage = await rotateImageBytes(bytes, deg);
        final moved = rotateBoxToRotatedPage(box, deg);
        final movedSlice = await cropBoxPng(rotatedPage, moved);
        final expected = await rotateImageBytes(direct.png, deg);
        final diff = await _meanAbsDiff(expected, movedSlice.png);
        // ignore: avoid_print
        print('P0.5-5 真实页 $deg°：变换后像素差 $diff，'
            '切片 ${movedSlice.width}×${movedSlice.height}');
        // 90°/270° 时切片宽高互换，180° 时不变（允许 1px 舍入差）。
        if (deg == 180) {
          expect(movedSlice.width, closeTo(direct.width, 1));
          expect(movedSlice.height, closeTo(direct.height, 1));
        } else {
          expect(movedSlice.width, closeTo(direct.height, 1));
          expect(movedSlice.height, closeTo(direct.width, 1));
        }
        expect(diff, lessThan(3.0));
      }
    });
  });

  group('P0.5-3 FileImage 缓存：重切图后 evict 再读到新图', () {
    test('不 evict 读到旧图；evict 后读到新图', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final dir = await Directory.systemTemp.createTemp('p05-evict');
      try {
        final file = File('${dir.path}/slice.png');
        await file.writeAsBytes(await _solidPng(0xFFFF0000, 64, 48));
        final red = await _loadViaFileImage(file);
        final redPx = await _centerPixel(red);
        red.dispose();
        expect(redPx, (255, 0, 0));

        // 覆盖写蓝图：不 evict 再读，仍是缓存里的红图。
        await file.writeAsBytes(await _solidPng(0xFF0000FF, 64, 48));
        final cached = await _loadViaFileImage(file);
        final cachedPx = await _centerPixel(cached);
        cached.dispose();
        expect(cachedPx, (255, 0, 0));

        // evict 后再读，是新写的蓝图。
        expect(await evictCachedFileImage(file.path), isTrue);
        final fresh = await _loadViaFileImage(file);
        final freshPx = await _centerPixel(fresh);
        fresh.dispose();
        expect(freshPx, (0, 0, 255));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('P0.5-4 页图格式：照片保留原图，不转 PNG', () {
    test('JPG 原样复制：字节相同、扩展名不变、不产生 PNG', () async {
      final fixture = File('test/fixtures/photo.jpg');
      expect(fixture.existsSync(), isTrue);
      final dir = await Directory.systemTemp.createTemp('p05-format');
      try {
        // 模拟导入复制：原文件 → imports/<task-id>/original.jpg。
        Directory('${dir.path}/imports/task-1').createSync(recursive: true);
        final copied =
            await fixture.copy('${dir.path}/imports/task-1/original.jpg');
        final origBytes = await fixture.readAsBytes();
        final copiedBytes = await copied.readAsBytes();
        expect(copiedBytes, origBytes);
        expect(copied.path.endsWith('.jpg'), isTrue);
        expect(File('${dir.path}/imports/task-1/original.png').existsSync(),
            isFalse);
        // 页图即原图本身：page_image_path 与 source_path 同一文件。
        // ignore: avoid_print
        print('P0.5-4 照片保留原图：photo.jpg ${origBytes.length} 字节，'
            '复制后字节一致，无 PNG 副本');
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('P0.5-6 EXIF 方向', () {
    test('手写解析：读出 1/3/6/8；PNG 与无 EXIF 的 JPG 返回 null', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      for (final ori in [1, 3, 6, 8]) {
        final bytes = await File('test/fixtures/exif-orientation-$ori.jpg')
            .readAsBytes();
        expect(readJpegExifOrientation(bytes), ori);
      }
      final png = await File(_page1).readAsBytes();
      expect(readJpegExifOrientation(png), isNull);
      final noExif =
          await File('test/fixtures/photo.jpg').readAsBytes();
      expect(readJpegExifOrientation(noExif), isNull);
      expect(readJpegExifOrientation(Uint8List.fromList([0xFF, 0xD8])),
          isNull);
      expect(readJpegExifOrientation(Uint8List(0)), isNull);
      // 角度映射：6 → 顺时针 90°；3 → 180°；8 → 270°；1 → 0。
      expect(exifOrientationToClockwiseDegrees(1), 0);
      expect(exifOrientationToClockwiseDegrees(3), 180);
      expect(exifOrientationToClockwiseDegrees(6), 90);
      expect(exifOrientationToClockwiseDegrees(8), 270);
      // 镜像方向暂不支持：返回 null，调用方应提示而非静默错向。
      expect(exifOrientationToClockwiseDegrees(2), isNull);
      expect(exifOrientationToClockwiseDegrees(5), isNull);
    });

    test('归一化：方向 6 的图转正后红块从左上移到右上，尺寸互换', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final stored =
          await File('test/fixtures/exif-orientation-6.jpg').readAsBytes();
      final norm = await normalizeExifImageBytes(stored);
      expect(norm.orientation, 6);
      expect(norm.wasNormalized, isTrue);
      // 归一化产物是 PNG（dart:ui 只方便输出 PNG）。
      expect(norm.bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      final dims = await _decodeRgba(norm.bytes);
      expect((dims.width, dims.height), (300, 400));
      // 存储时红块在左上 (0..100, 0..100)；顺时针 90° 后应在右上。
      // JPEG 有损，颜色用区间判断（红 R≈254 而非 255）。
      final topRight = await _pixelAt(norm.bytes, 250, 50);
      expect(topRight.$1, greaterThan(200));
      expect(topRight.$2, lessThan(80));
      expect(topRight.$3, lessThan(80));
      // 存储时绿块在右下 (300..400, 200..300)；转正后应在左下。
      final bottomLeft = await _pixelAt(norm.bytes, 50, 350);
      expect(bottomLeft.$1, lessThan(80));
      expect(bottomLeft.$2, greaterThan(120));
      expect(bottomLeft.$3, lessThan(80));
      // 方向 1 不动：字节原样、wasNormalized=false。
      final one =
          await File('test/fixtures/exif-orientation-1.jpg').readAsBytes();
      final norm1 = await normalizeExifImageBytes(one);
      expect((norm1.orientation, norm1.wasNormalized), (1, false));
      expect(norm1.bytes, one);
      // 方向 3：红块左上 → 右下；方向 8：红块左上 → 左下。
      final three = await File('test/fixtures/exif-orientation-3.jpg')
          .readAsBytes();
      final norm3 = await normalizeExifImageBytes(three);
      final br = await _pixelAt(norm3.bytes, 350, 250);
      expect(br.$1, greaterThan(200));
      expect(br.$2, lessThan(80));
      final eight = await File('test/fixtures/exif-orientation-8.jpg')
          .readAsBytes();
      final norm8 = await normalizeExifImageBytes(eight);
      // 方向 8：红块左上 → 左下 (0..100, 300..400)。
      final bl = await _pixelAt(norm8.bytes, 50, 350);
      expect(bl.$1, greaterThan(200));
      expect(bl.$2, lessThan(80));
    });

    test('框/页图/切片方向一致：归一化页上的框与存储页解码后的正向像素一致',
        () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final stored =
          await File('test/fixtures/exif-orientation-6.jpg').readAsBytes();
      final norm = await normalizeExifImageBytes(stored);
      // dart:ui 解码 JPEG 时已按 EXIF 转正，所以“存储页解码后”
      // 与归一化页是同一套正向像素；框一律用正向坐标系：
      // 红块在正向页 (300×400) 的右上，框为 (2/3, 0, 1/3, 0.25)。
      final normBox = rotateBoxToRotatedPage(_box(0, 0, 0.25, 100 / 300), 90);
      expect(normBox.x, closeTo(2 / 3, 1e-9));
      final sliceStored = await cropBoxPng(stored, normBox);
      final sliceNorm = await cropBoxPng(norm.bytes, normBox);
      final diff = await _meanAbsDiff(sliceStored.png, sliceNorm.png);
      // ignore: avoid_print
      print('P0.5-6 EXIF 一致性：存储页解码裁剪 vs 归一化页裁剪像素差 $diff');
      expect(diff, lessThan(3.0));
      final red = await _pixelAt(sliceNorm.png, 10, 10);
      expect(red.$1, greaterThan(200));
      expect(red.$2, lessThan(80));
    });
  });

  group('P0.5-7 大图打开耗时（§1.6：readAsBytesSync 在 UI 线程）', () {
    test('实测：同步读 + 解码 + 整页检测耗时', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      if (!File(_page1).existsSync()) {
        markTestSkipped('本机无真实页图 $_page1');
        return;
      }
      // 同步读：20 次取平均（页图 1653×2200 PNG，约 290KB）。
      final file = File(_page1);
      final swRead = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        file.readAsBytesSync();
      }
      swRead.stop();
      final readAvgUs = swRead.elapsedMicroseconds / 20;
      // 解码一次。
      final bytes = file.readAsBytesSync();
      final swDecode = Stopwatch()..start();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      swDecode.stop();
      final decoded = frame.image;
      // ignore: avoid_print
      print('P0.5-7 大图打开：readAsBytesSync 平均 '
          '${(readAvgUs / 1000).toStringAsFixed(3)}ms，'
          '解码 ${swDecode.elapsedMilliseconds}ms '
          '(${decoded.width}×${decoded.height})');
      decoded.dispose();
      expect(readAvgUs, lessThan(50 * 1000)); // 同步读本身 <50ms
      // 整页检测（含读 + 解码 + 推理）：第二次调用，模型已加载。
      final service = YoloOnnxService();
      (await service.detectPage(imagePath: _page1, page: 1)).boxes;
      if (!service.hasRealModel) {
        markTestSkipped('本机无 onnxruntime 原生库，跳过真实推理耗时');
        return;
      }
      final swDetect = Stopwatch()..start();
      final boxes = (await service.detectPage(imagePath: _page1, page: 1)).boxes;
      swDetect.stop();
      // ignore: avoid_print
      print('P0.5-7 大图打开：detectPage 稳态 ${swDetect.elapsedMilliseconds}ms'
          '（纯推理 ${service.lastDetectStats?.totalMs}ms，'
          '${boxes.length} 框）');
    });
  });
}

