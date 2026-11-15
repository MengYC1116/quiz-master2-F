// S8A3 clampToPage 回归测试：框贴到右/下边时旧实现 `w.clamp(0.08, 1.0 - x)`
// 在 `1.0 - x < 0.08` 时下限大于上限，Dart 抛 ArgumentError。
// 新实现对任何输入都不抛错：贴边允许宽/高小于 0.08（不收左上角），
// 空间足够时仍把过小的宽/高补回 0.08。
// SR-P2-77：真实模型冒烟 group 带 5 分钟超时余量（与 PDF 组并行跑时
// 的 CPU 争用超时抖动同源，见 test/pdf_render_service_test.dart 头注）。
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/yolo_onnx_service.dart';

QuestionBox box(double x, double y, double w, double h) =>
    QuestionBox(id: 'b', layer: 1, type: 'question', x: x, y: y, w: w, h: h);

/// 结果框必须落在页内：左上角在 0..1，宽/高不超出剩余空间。
void expectInPage(QuestionBox r) {
  expect(r.x, inInclusiveRange(0.0, 1.0));
  expect(r.y, inInclusiveRange(0.0, 1.0));
  expect(r.w, greaterThanOrEqualTo(0.0));
  expect(r.h, greaterThanOrEqualTo(0.0));
  expect(r.x + r.w, lessThanOrEqualTo(1.0 + 1e-9));
  expect(r.y + r.h, lessThanOrEqualTo(1.0 + 1e-9));
}

/// SR2-73：生成一张纯白 PNG 页图（100×100），供并发检测用例用。
/// 与冒烟组同款画法抽成辅助函数，不复写三遍。
Future<File> _whitePagePng(Directory dir, {String name = 'page.png'}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 100, 100),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  final img = await recorder.endRecording().toImage(100, 100);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(png!.buffer.asUint8List());
  return file;
}

/// SR2-73：轮询等条件成立（默认最多 5 秒），超时返回 false。
/// 用在“等第一次检测进入 _loadOnce 并停在屏障处”。
Future<bool> _waitFor(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) return false;
    await Future.delayed(const Duration(milliseconds: 10));
  }
  return true;
}

void main() {
  group('clampToPage', () {
    test('正常框：原样保留', () {
      final r = YoloOnnxService.clampToPage(box(0.1, 0.1, 0.5, 0.5));
      expect(r.x, 0.1);
      expect(r.y, 0.1);
      expect(r.w, 0.5);
      expect(r.h, 0.5);
      expectInPage(r);
    });

    test('贴右边：不抛错，左上角不动，宽收到剩余空间', () {
      final r = YoloOnnxService.clampToPage(box(0.95, 0.1, 0.2, 0.5));
      expect(r.x, 0.95);
      expect(r.w, closeTo(0.05, 1e-9));
      expect(r.h, 0.5);
      expectInPage(r);
    });

    test('贴下边：不抛错，左上角不动，高收到剩余空间', () {
      final r = YoloOnnxService.clampToPage(box(0.1, 0.95, 0.5, 0.2));
      expect(r.y, 0.95);
      expect(r.h, closeTo(0.05, 1e-9));
      expect(r.w, 0.5);
      expectInPage(r);
    });

    test('贴右下角：宽高都收到剩余空间', () {
      final r = YoloOnnxService.clampToPage(box(0.95, 0.96, 0.3, 0.3));
      expect(r.x, 0.95);
      expect(r.y, 0.96);
      expect(r.w, closeTo(0.05, 1e-9));
      expect(r.h, closeTo(0.04, 1e-9));
      expectInPage(r);
    });

    test('x=1.0 / y=1.0：不抛错，宽/高为 0', () {
      final r = YoloOnnxService.clampToPage(box(1.0, 1.0, 0.1, 0.1));
      expect(r.x, 1.0);
      expect(r.y, 1.0);
      expect(r.w, 0.0);
      expect(r.h, 0.0);
      expectInPage(r);
    });

    test('浮点坑：x=0.92 时 1.0 - x 是 0.07999…，不抛错', () {
      final r = YoloOnnxService.clampToPage(box(0.92, 0.92, 0.5, 0.5));
      expect(r.x, 0.92);
      expect(r.w, closeTo(1.0 - 0.92, 1e-9));
      expect(r.h, closeTo(1.0 - 0.92, 1e-9));
      expectInPage(r);
    });

    test('负坐标：minSize: false 时左溢出扣宽（交集语义），默认时尺寸不变', () {
      // SR2-38：检测路径（minSize: false）改成交集语义——
      // x=-0.2, w=0.5 → 交集 [0, 0.3]，宽扣到 0.3；
      // y=-0.1, h=0.5 → 交集 [0, 0.4]，高扣到 0.4。
      final detected = YoloOnnxService.clampToPage(
        box(-0.2, -0.1, 0.5, 0.5),
        minSize: false,
      );
      expect(detected.x, 0.0);
      expect(detected.y, 0.0);
      expect(detected.w, closeTo(0.3, 1e-9));
      expect(detected.h, closeTo(0.4, 1e-9));
      expectInPage(detected);
      // 编辑器路径（默认 minSize: true）保持现状：左上角收到 0，
      // 尺寸不变——框被拖出页边时不静默缩小、保持可抓取。
      final edited = YoloOnnxService.clampToPage(box(-0.2, -0.1, 0.5, 0.5));
      expect(edited.x, 0.0);
      expect(edited.y, 0.0);
      expect(edited.w, 0.5);
      expect(edited.h, 0.5);
      expectInPage(edited);
    });

    test('框完全在页外：收到右下角，宽/高为 0', () {
      final r = YoloOnnxService.clampToPage(box(1.5, 1.2, 0.5, 0.5));
      expect(r.x, 1.0);
      expect(r.y, 1.0);
      expect(r.w, 0.0);
      expect(r.h, 0.0);
      expectInPage(r);
    });

    test('w/h 为 0 或负数：空间足够时补回最小尺寸 0.08', () {
      final zero = YoloOnnxService.clampToPage(box(0.1, 0.1, 0.0, 0.0));
      expect(zero.w, 0.08);
      expect(zero.h, 0.08);
      final neg = YoloOnnxService.clampToPage(box(0.1, 0.1, -0.3, -0.2));
      expect(neg.w, 0.08);
      expect(neg.h, 0.08);
      expectInPage(zero);
      expectInPage(neg);
    });

    test('w/h 超大：收到剩余空间', () {
      final r = YoloOnnxService.clampToPage(box(0.1, 0.2, 5.0, 5.0));
      expect(r.w, closeTo(0.9, 1e-9));
      expect(r.h, closeTo(0.8, 1e-9));
      expectInPage(r);
    });

    test('空间足够时过小的宽/高补回 0.08', () {
      final r = YoloOnnxService.clampToPage(box(0.1, 0.1, 0.01, 0.02));
      expect(r.w, 0.08);
      expect(r.h, 0.08);
      expectInPage(r);
    });

    test('minSize: false：检测输出的薄框原样保留，不补 0.08', () {
      // 题行实测高 0.018~0.10、选项框约 0.04×0.03：默认补 0.08 会让
      // 相邻题行互相重叠、确认被拦；检测管线用 minSize: false。
      final r = YoloOnnxService.clampToPage(
        box(0.13, 0.26, 0.8, 0.041),
        minSize: false,
      );
      expect(r.h, closeTo(0.041, 1e-9));
      final opt = YoloOnnxService.clampToPage(
        box(0.15, 0.11, 0.044, 0.03),
        minSize: false,
      );
      expect(opt.w, closeTo(0.044, 1e-9));
      expect(opt.h, closeTo(0.03, 1e-9));
      // 默认行为不变：同样输入不传参仍补回 0.08。
      expect(YoloOnnxService.clampToPage(box(0.13, 0.26, 0.8, 0.041)).h, 0.08);
      expectInPage(r);
      expectInPage(opt);
    });

    test('贴边且 w/h 为 0：不抛错，宽/高保持 0（剩余空间 < 0.08，不补）', () {
      final r = YoloOnnxService.clampToPage(box(1.0, 0.95, 0.0, 0.0));
      expect(r.w, 0.0);
      expect(r.h, 0.0);
      expectInPage(r);
    });
  });

  group('decodeYoloOutput（YOLO11 后处理）', () {
    // 通道顺序：cx、cy、w、h、类别分数…；每通道一个 anchor 一列。
    List<List<num>> channels(List<List<num>> rows) => rows;

    test('低于阈值的不要，高于阈值的留', () {
      final out = YoloOnnxService.decodeYoloOutput(
        channels([
          [100, 200], // cx
          [100, 200], // cy
          [50, 60], // w
          [40, 50], // h
          [0.9, 0.1], // 类别 0 分数
        ]),
        numClasses: 1,
        confThreshold: 0.45,
        nmsIou: 0.5,
        crossClassIou: 0.8,
      );
      expect(out.length, 1);
      expect(out.first.score, 0.9);
      expect(out.first.x1, 75);
      expect(out.first.y1, 80);
      expect(out.first.x2, 125);
      expect(out.first.y2, 120);
    });

    test('同类重叠框：NMS 只留置信度高的', () {
      final out = YoloOnnxService.decodeYoloOutput(
        channels([
          [100, 102, 500],
          [100, 101, 500],
          [50, 52, 60],
          [40, 42, 50],
          [0.9, 0.8, 0.95],
        ]),
        numClasses: 1,
        confThreshold: 0.45,
        nmsIou: 0.5,
        crossClassIou: 0.8,
      );
      expect(out.length, 2);
      expect(out.map((d) => d.score), [0.95, 0.9]);
    });

    test('跨类同框重复：只留置信度高的（stem/figure 混淆去重）', () {
      final out = YoloOnnxService.decodeYoloOutput(
        channels([
          [100, 100],
          [100, 100],
          [50, 50],
          [40, 40],
          [0.31, 0.0], // 类别 0（stem）0.31
          [0.0, 0.0], // 类别 1（option）无
          [0.92, 0.0], // 类别 2（figure）0.92
        ]),
        numClasses: 3,
        confThreshold: 0.25,
        nmsIou: 0.5,
        crossClassIou: 0.8,
      );
      expect(out.length, 1);
      expect(out.first.cls, 2);
      expect(out.first.score, 0.92);
    });

    test('类别下标按通道取：分数最高的通道定类别', () {
      final out = YoloOnnxService.decodeYoloOutput(
        channels([
          [100],
          [100],
          [50],
          [40],
          [0.1], // stem
          [0.9], // option
          [0.2], // figure
        ]),
        numClasses: 3,
        confThreshold: 0.25,
        nmsIou: 0.5,
        crossClassIou: 0.8,
      );
      expect(out.length, 1);
      expect(out.first.cls, 1);
    });

    test('通道数不对 / 空输出：返回空，不抛错', () {
      expect(
        YoloOnnxService.decodeYoloOutput(
          const [],
          numClasses: 1,
          confThreshold: 0.45,
          nmsIou: 0.5,
          crossClassIou: 0.8,
        ),
        isEmpty,
      );
      expect(
        YoloOnnxService.decodeYoloOutput(
          channels([
            [100],
            [100],
          ]),
          numClasses: 1,
          confThreshold: 0.45,
          nmsIou: 0.5,
          crossClassIou: 0.8,
        ),
        isEmpty,
      );
    });
  });

  group('letterboxFit', () {
    test('1653×2200 竖页 → 1280：按高缩放，左右留灰边', () {
      final fit = YoloOnnxService.letterboxFit(1653, 2200, 1280);
      expect(fit.scale, closeTo(1280 / 2200, 1e-9));
      expect(fit.dy, 0.0);
      expect(fit.dx, closeTo((1280 - 1653 * 1280 / 2200) / 2, 1e-9));
    });

    test('方形图：无灰边', () {
      final fit = YoloOnnxService.letterboxFit(1000, 1000, 1280);
      expect(fit.scale, closeTo(1.28, 1e-9));
      expect(fit.dx, 0.0);
      expect(fit.dy, 0.0);
    });
  });

  group('真实模型冒烟（assets 里的真模型 + 临时合成图）', () {
    test('加载成功时 hasRealModel 为真，推理不抛错；原生库缺失时跳过', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final service = YoloOnnxService();
      final dir = await Directory.systemTemp.createTemp('yolo-smoke');
      try {
        // 合成一张白底黑横条的假“试卷页”（800×1000 PNG）。
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawRect(
          const ui.Rect.fromLTWH(0, 0, 800, 1000),
          ui.Paint()..color = const ui.Color(0xFFFFFFFF),
        );
        final bar = ui.Paint()..color = const ui.Color(0xFF000000);
        for (var i = 0; i < 10; i++) {
          canvas.drawRect(ui.Rect.fromLTWH(80, 80.0 + i * 90, 640, 12), bar);
        }
        final img = await recorder.endRecording().toImage(800, 1000);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        img.dispose();
        final file = File('${dir.path}/page.png');
        await file.writeAsBytes(png!.buffer.asUint8List());
        final boxes = (await service.detectPage(
          imagePath: file.path,
          page: 1,
        )).boxes;
        if (!service.hasRealModel) {
          markTestSkipped('本机无 onnxruntime 原生库，跳过真实推理');
          return;
        }
        // 合成图不要求检出题，只要求流程跑通、不抛错、有耗时记录。
        expect(boxes, isA<List<QuestionBox>>());
        expect(service.lastDetectStats, isNotNull);
        expect(service.lastDetectStats!.totalMs, greaterThan(0));
      } finally {
        await dir.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('图片文件不存在：不回占位框，usedFallback 为真、显式提示手动框选', () async {
      final service = YoloOnnxService();
      final result = await service.detectPage(
        imagePath: '/definitely/not/here/page.png',
        page: 1,
      );
      expect(result.usedFallback, isTrue);
      expect(result.boxes, isEmpty);
      expect(result.error, contains('页图缺失'));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('模型缺失时：不回占位框，usedFallback 为真、提示手动框选', () async {
      // 先重置加载缓存：真实推理测试跑过后 _loadOk 已缓存为真。
      YoloOnnxService.resetLoadStateForTest();
      final service = YoloOnnxService(
        questionModelAsset: 'assets/models/question/does-not-exist.onnx',
      );
      final dir = await Directory.systemTemp.createTemp('yolo-nomodel');
      try {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawRect(
          const ui.Rect.fromLTWH(0, 0, 100, 100),
          ui.Paint()..color = const ui.Color(0xFFFFFFFF),
        );
        final img = await recorder.endRecording().toImage(100, 100);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        img.dispose();
        final file = File('${dir.path}/page.png');
        await file.writeAsBytes(png!.buffer.asUint8List());
        final result = await service.detectPage(imagePath: file.path, page: 1);
        expect(result.usedFallback, isTrue);
        expect(result.boxes, isEmpty);
        expect(result.error, contains('手动框选'));
      } finally {
        await dir.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('SR-P1-16：首次加载失败后补放模型（换回真实模型路径），下次检测可恢复，无需重启', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      YoloOnnxService.resetLoadStateForTest();
      final dir = await Directory.systemTemp.createTemp('yolo-retry-load');
      try {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawRect(
          const ui.Rect.fromLTWH(0, 0, 100, 100),
          ui.Paint()..color = const ui.Color(0xFFFFFFFF),
        );
        final img = await recorder.endRecording().toImage(100, 100);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        img.dispose();
        final file = File('${dir.path}/page.png');
        await file.writeAsBytes(png!.buffer.asUint8List());

        // 第一次：模型路径不存在，加载失败 → fallback，不锁死。
        final missing = YoloOnnxService(
          questionModelAsset: 'assets/models/question/does-not-exist.onnx',
        );
        final first = await missing.detectPage(imagePath: file.path, page: 1);
        expect(first.usedFallback, isTrue);
        expect(first.boxes, isEmpty);
        expect(first.error, contains('手动框选'));
        expect(missing.hasRealModel, isFalse);

        // 运行中“补放模型”：同一进程内换回真实模型路径再次检测。
        // 旧实现 `_loadAttempted` 锁死，这里会一直返回 fallback。
        final real = YoloOnnxService();
        final second = await real.detectPage(imagePath: file.path, page: 1);
        if (!real.hasRealModel) {
          markTestSkipped('本机无 onnxruntime 原生库，跳过真实推理恢复验证');
          return;
        }
        expect(second.usedFallback, isFalse);
        expect(real.lastDetectStats, isNotNull);

        // 成功后缓存复用：换成缺失模型路径的实例再次检测，
        // 仍走已加载的会话，不重新加载模型。
        final stale = YoloOnnxService(
          questionModelAsset: 'assets/models/question/does-not-exist.onnx',
        );
        final third = await stale.detectPage(imagePath: file.path, page: 1);
        expect(third.usedFallback, isFalse);
        expect(stale.hasRealModel, isTrue);
      } finally {
        await dir.delete(recursive: true);
        YoloOnnxService.resetLoadStateForTest();
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('SR2-73 并发检测共用 _loadFuture', () {
    test('模型缺失路径：两次并发检测只加载一次，无原生库也可断言', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      YoloOnnxService.resetLoadStateForTest();
      // 屏障：第一次加载停在 gate 处，第二次检测发起时它仍在进行中，
      // 必须加入同一个 _loadFuture。无屏障时无原生库的加载在
      // OrtEnv.init 处同步失败，两次检测几乎不可能在同一次加载内
      // 重叠，计数断言会抖动——屏障只在测试里设置，生产恒为 null。
      final gate = Completer<void>();
      YoloOnnxService.loadGateForTest = gate;
      final dir = await Directory.systemTemp.createTemp('yolo-concurrent');
      try {
        final file = await _whitePagePng(dir);
        // 两个不同实例：_loadFuture 是静态的，跨实例也应共用。
        final a = YoloOnnxService(
          questionModelAsset: 'assets/models/question/does-not-exist.onnx',
        );
        final b = YoloOnnxService(
          questionModelAsset: 'assets/models/question/does-not-exist.onnx',
        );
        final first = a.detectPage(imagePath: file.path, page: 1);
        // 等第一次检测真正进入 _loadOnce 并停在屏障处。
        expect(
          await _waitFor(() => YoloOnnxService.loadAttemptsForTest == 1),
          isTrue,
          reason: '第一次检测应在超时前进入加载',
        );
        final second = b.detectPage(imagePath: file.path, page: 1);
        // 给第二次检测留出解码 + 到达 _ensureLoaded 的时间（100×100
        // PNG 解码是毫秒级，500ms 余量充足）：加载仍被屏障按住，
        // 晚到也会加入同一个 _loadFuture，不会另起加载。
        await Future.delayed(const Duration(milliseconds: 500));
        gate.complete();
        final results = await Future.wait([first, second]);
        for (final r in results) {
          expect(r.usedFallback, isTrue);
          expect(r.error, contains('手动框选'));
        }
        // 两次并发检测只触发一次加载：第二次加入了第一次的 _loadFuture。
        expect(YoloOnnxService.loadAttemptsForTest, 1);
      } finally {
        // 失败时也放行屏障，免得停在 gate 处的加载一直挂起。
        if (!gate.isCompleted) gate.complete();
        await dir.delete(recursive: true);
        YoloOnnxService.resetLoadStateForTest();
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('真实模型路径：两次并发检测只加载一次；无原生库时跳过原因可观测', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      YoloOnnxService.resetLoadStateForTest();
      final gate = Completer<void>();
      YoloOnnxService.loadGateForTest = gate;
      final dir = await Directory.systemTemp.createTemp('yolo-concurrent-real');
      try {
        final file = await _whitePagePng(dir);
        final a = YoloOnnxService();
        final b = YoloOnnxService();
        final first = a.detectPage(imagePath: file.path, page: 1);
        expect(
          await _waitFor(() => YoloOnnxService.loadAttemptsForTest == 1),
          isTrue,
          reason: '第一次检测应在超时前进入加载',
        );
        final second = b.detectPage(imagePath: file.path, page: 1);
        await Future.delayed(const Duration(milliseconds: 500));
        gate.complete();
        final results = await Future.wait([first, second]);
        // 共享加载的断言与原生库无关：有库无库都只加载一次。
        expect(YoloOnnxService.loadAttemptsForTest, 1);
        if (!a.hasRealModel) {
          // 跳过原因可观测：先断言两次结果都是“加载失败 → fallback”
          // 的确定行为，再记跳过——这次跳过不是关键断言空跑，而是
          // 环境缺 onnxruntime 原生库；共享加载已由计数断言覆盖。
          for (final r in results) {
            expect(r.usedFallback, isTrue);
            expect(r.error, contains('手动框选'));
          }
          markTestSkipped(
            'SR2-73 并发真实推理：本机无 onnxruntime 原生库'
            '（hasRealModel=false），成功路径不断言；共享加载已由'
            'loadAttemptsForTest == 1 覆盖',
          );
          return;
        }
        for (final r in results) {
          expect(r.usedFallback, isFalse);
        }
        expect(a.lastDetectStats, isNotNull);
        expect(b.lastDetectStats, isNotNull);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await dir.delete(recursive: true);
        YoloOnnxService.resetLoadStateForTest();
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('SR3-23：测试屏障以 error 完成时 _loadFuture 不被毒化，下次检测重试加载', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      YoloOnnxService.resetLoadStateForTest();
      final gate = Completer<void>();
      YoloOnnxService.loadGateForTest = gate;
      final dir = await Directory.systemTemp.createTemp('yolo-gate-error');
      try {
        final file = await _whitePagePng(dir);
        final service = YoloOnnxService(
          questionModelAsset: 'assets/models/question/does-not-exist.onnx',
        );
        final first = service.detectPage(imagePath: file.path, page: 1);
        expect(
          await _waitFor(() => YoloOnnxService.loadAttemptsForTest == 1),
          isTrue,
          reason: '第一次检测应在超时前进入加载',
        );
        gate.completeError(StateError('gate boom'));
        final firstResult = await first;
        expect(firstResult.usedFallback, isTrue);
        expect(firstResult.error, contains('手动框选'));
        expect(YoloOnnxService.loadAttemptsForTest, 1);
        // 第二次检测：屏障换成已正常完成的 completer，加载应重试
        //（旧实现里 gate 在 try 外抛错，失败的 _loadFuture 永远留在
        // 原地，计数恒为 1、加载永不重试）。
        YoloOnnxService.loadGateForTest = Completer<void>()..complete();
        final second = await service.detectPage(imagePath: file.path, page: 1);
        expect(second.usedFallback, isTrue);
        expect(YoloOnnxService.loadAttemptsForTest, 2);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await dir.delete(recursive: true);
        YoloOnnxService.resetLoadStateForTest();
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('SR3-24：单次推理超时走 fallback，队列不被堵住，下次检测仍能跑', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      YoloOnnxService.resetLoadStateForTest();
      final dir = await Directory.systemTemp.createTemp('yolo-detect-timeout');
      try {
        final file = await _whitePagePng(dir);
        final service = YoloOnnxService();
        // 先跑一次正常检测把模型加载好（超时只包推理，不包加载）；
        // 无原生库时跳过：超时路径须真实推理才可达。
        final warmup = await service.detectPage(imagePath: file.path, page: 1);
        if (!service.hasRealModel) {
          markTestSkipped('本机无 onnxruntime 原生库，跳过推理超时验证');
          return;
        }
        expect(warmup.usedFallback, isFalse);
        // 超时缩到 1ms：这次推理必超时 → fallback。原生推理仍在后台
        // 跑（不取消），等它跑完（lastDetectStats 晚到）再发起下一次，
        // 避免两次原生 runAsync 重叠（SR2-73 的 SIGSEGV 起因）。
        YoloOnnxService.detectTimeoutForTest = const Duration(milliseconds: 1);
        final timedOut = await service.detectPage(
          imagePath: file.path,
          page: 1,
        );
        expect(timedOut.usedFallback, isTrue);
        expect(timedOut.error, contains('手动框选'));
        expect(
          await _waitFor(
            () => service.lastDetectStats != null,
            timeout: const Duration(seconds: 30),
          ),
          isTrue,
          reason: '后台超时的推理应在 30 秒内跑完',
        );
        // 队列未被超时毒化：恢复 60 秒后下一次检测正常成功。
        YoloOnnxService.detectTimeoutForTest = YoloOnnxService.detectTimeout;
        final second = await service.detectPage(imagePath: file.path, page: 1);
        expect(second.usedFallback, isFalse);
        expect(service.lastDetectStats, isNotNull);
      } finally {
        await dir.delete(recursive: true);
        YoloOnnxService.resetLoadStateForTest();
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
