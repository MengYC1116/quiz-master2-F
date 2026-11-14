// P0.5 端到端小样：真实图片最小闭环
//   复制 → 检测 → 修框（旋转烘焙）→ 裁剪 → 存 PNG → 重启后读回。
//
// 两阶段跑（两次独立的 flutter test 进程，中间即“重启”）：
//   flutter test test/p05_image_pipeline_e2e_test.dart --dart-define P05_PHASE=write
//   flutter test test/p05_image_pipeline_e2e_test.dart --dart-define P05_PHASE=read
// 真实检测需要 onnxruntime 原生库，两次都要设：
//   LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux
// 工作目录固定 /tmp/p05-spike（临时，不进仓库、不进数据目录、不碰演示库）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/page_image_pipeline.dart';
import 'package:quiz_master2/services/yolo_onnx_service.dart';

const _phase = String.fromEnvironment('P05_PHASE', defaultValue: 'write');
const _workdir = '/tmp/p05-spike';
const _page1 = '/home/hatch/workspace/yolo-test-images/'
    '16676QPFVu1ck984AfWQHruoHWRfTz99b.png';

/// FNV-1a 64 位（小样完整性校验用，无新依赖）。
String _fnv1a(Uint8List bytes) {
  var hash = 0xcbf29ce484222325;
  for (final b in bytes) {
    hash ^= b;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

Future<double> _meanAbsDiff(Uint8List a, Uint8List b) async {
  Future<({Uint8List rgba, int w, int h})> decode(Uint8List png) async {
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    try {
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      return (rgba: data!.buffer.asUint8List(), w: img.width, h: img.height);
    } finally {
      img.dispose();
    }
  }

  final da = await decode(a);
  final db = await decode(b);
  if (da.w != db.w || da.h != db.h) return double.infinity;
  var sum = 0;
  for (var i = 0; i < da.rgba.length; i++) {
    sum += (da.rgba[i] - db.rgba[i]).abs();
  }
  return sum / da.rgba.length;
}

void main() {
  test('P0.5 端到端小样 phase=$_phase', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final root = Directory(_workdir);
    if (_phase == 'write') {
      if (root.existsSync()) root.deleteSync(recursive: true);
      root.createSync(recursive: true);
      if (!File(_page1).existsSync()) {
        markTestSkipped('本机无真实页图 $_page1');
        return;
      }
      final timings = <String, int>{};

      // 1. 复制：原图 → imports/<task-id>/original.png。
      var sw = Stopwatch()..start();
      final taskDir = Directory('${root.path}/imports/task-p05')
        ..createSync(recursive: true);
      final copied = await File(_page1).copy('${taskDir.path}/original.png');
      sw.stop();
      timings['copyMs'] = sw.elapsedMilliseconds;
      final pageBytes = await copied.readAsBytes();

      // 2. 检测：真实 YOLO 第 1 层。
      final service = YoloOnnxService();
      sw = Stopwatch()..start();
      final boxes = (await service.detectPage(imagePath: copied.path, page: 1)).boxes;
      sw.stop();
      timings['detectMs'] = sw.elapsedMilliseconds;
      timings['inferMs'] = service.lastDetectStats?.totalMs ?? -1;
      expect(service.hasRealModel, isTrue,
          reason: '端到端小样必须跑真实推理；缺原生库时设 LD_LIBRARY_PATH 再跑');
      expect(boxes.length, greaterThanOrEqualTo(5));
      final box = boxes.first; // 修框起点：检测出的第 1 个框
      // ignore: avoid_print
      print('E2E 检测：${boxes.length} 框，首框 box-q1 '
          '(${box.x.toStringAsFixed(3)}, ${box.y.toStringAsFixed(3)}, '
          '${box.w.toStringAsFixed(3)}, ${box.h.toStringAsFixed(3)})');

      // 3. 修框：页旋转 90° 烘焙（模拟用户把歪页转正后确认）。
      sw = Stopwatch()..start();
      final rotated = await cropRotatedSlice(pageBytes, box, 90);
      sw.stop();
      timings['bakeCropMs'] = sw.elapsedMilliseconds;
      final pagesDir = Directory('${root.path}/imports/task-p05/pages')
        ..createSync(recursive: true);
      final bakedFile = File('${pagesDir.path}/page-001-r90.png');
      await bakedFile.writeAsBytes(rotated.bakedPagePng);

      // 4. 裁剪 → 存 PNG 切片。
      sw = Stopwatch()..start();
      final slicesDir = Directory('${root.path}/slices')
        ..createSync(recursive: true);
      final sliceFile = File('${slicesDir.path}/q-p05-1.png');
      await sliceFile.writeAsBytes(rotated.slicePng);
      sw.stop();
      timings['sliceWriteMs'] = sw.elapsedMilliseconds;

      // 5. 清单：重启后读回的校验依据。
      final rotatedBox = rotateBoxToRotatedPage(box, 90);
      final manifest = {
        'pageImage': 'imports/task-p05/original.png',
        'pageImageHash': _fnv1a(pageBytes),
        'bakedPage': 'imports/task-p05/pages/page-001-r90.png',
        'bakedPageHash': _fnv1a(rotated.bakedPagePng),
        'slice': 'slices/q-p05-1.png',
        'sliceHash': _fnv1a(rotated.slicePng),
        'sliceWidth': rotated.sliceWidth,
        'sliceHeight': rotated.sliceHeight,
        'boxOriginal': [box.x, box.y, box.w, box.h],
        'boxRotated': [rotatedBox.x, rotatedBox.y, rotatedBox.w, rotatedBox.h],
        'rotation': 90,
        'boxCount': boxes.length,
        'timingsMs': timings,
      };
      await File('${root.path}/manifest.json')
          .writeAsString(jsonEncode(manifest));
      // ignore: avoid_print
      print('E2E 写盘完成：页图 1653×2200，烘焙后页图与切片已落盘；'
          '耗时 $timings；切片 ${rotated.sliceWidth}×${rotated.sliceHeight}');
      expect(rotated.sliceWidth, greaterThanOrEqualTo(100));
      return;
    }

    // ---- read 阶段：全新进程，只读 /tmp/p05-spike 里上次写的东西 ----
    expect(_phase, 'read');
    final manifestFile = File('${root.path}/manifest.json');
    expect(manifestFile.existsSync(), isTrue,
        reason: '先跑 P05_PHASE=write 再跑 read');
    final manifest =
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;

    final sliceFile = File('${root.path}/${manifest['slice']}');
    expect(sliceFile.existsSync(), isTrue, reason: '切片文件重启后还在');
    final sliceBytes = await sliceFile.readAsBytes();
    expect(_fnv1a(sliceBytes), manifest['sliceHash'], reason: '切片字节未变');
    final codec = await ui.instantiateImageCodec(sliceBytes);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, manifest['sliceWidth']);
    expect(frame.image.height, manifest['sliceHeight']);
    frame.image.dispose();

    final bakedFile = File('${root.path}/${manifest['bakedPage']}');
    expect(_fnv1a(await bakedFile.readAsBytes()), manifest['bakedPageHash'],
        reason: '烘焙后页图字节未变');
    final pageFile = File('${root.path}/${manifest['pageImage']}');
    expect(_fnv1a(await pageFile.readAsBytes()), manifest['pageImageHash'],
        reason: '原页图字节未变');

    // 重切一次比对：从烘焙后页图 + 清单里的旋转后框重裁，应与存盘切片一致。
    final rb = (manifest['boxRotated'] as List).cast<num>();
    final reCrop = await cropBoxPng(
      await bakedFile.readAsBytes(),
      QuestionBox(
          id: 'b',
          layer: 1,
          type: 'question',
          x: rb[0].toDouble(),
          y: rb[1].toDouble(),
          w: rb[2].toDouble(),
          h: rb[3].toDouble()),
    );
    final diff = await _meanAbsDiff(sliceBytes, reCrop.png);
    // ignore: avoid_print
    print('E2E 重启后读回：切片哈希一致，尺寸 '
        '${manifest['sliceWidth']}×${manifest['sliceHeight']}，'
        '重裁像素差 $diff，框数 ${manifest['boxCount']}，'
        '写盘时耗时 ${manifest['timingsMs']}');
    expect(diff, lessThan(3.0));
  });
}
