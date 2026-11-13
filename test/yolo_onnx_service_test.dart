// S8A3 clampToPage 回归测试：框贴到右/下边时旧实现 `w.clamp(0.08, 1.0 - x)`
// 在 `1.0 - x < 0.08` 时下限大于上限，Dart 抛 ArgumentError。
// 新实现对任何输入都不抛错：贴边允许宽/高小于 0.08（不收左上角），
// 空间足够时仍把过小的宽/高补回 0.08。
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

    test('负坐标：左上角收到 0，尺寸不变', () {
      final r = YoloOnnxService.clampToPage(box(-0.2, -0.1, 0.5, 0.5));
      expect(r.x, 0.0);
      expect(r.y, 0.0);
      expect(r.w, 0.5);
      expect(r.h, 0.5);
      expectInPage(r);
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
      final r = YoloOnnxService.clampToPage(box(0.13, 0.26, 0.8, 0.041),
          minSize: false);
      expect(r.h, closeTo(0.041, 1e-9));
      final opt = YoloOnnxService.clampToPage(box(0.15, 0.11, 0.044, 0.03),
          minSize: false);
      expect(opt.w, closeTo(0.044, 1e-9));
      expect(opt.h, closeTo(0.03, 1e-9));
      // 默认行为不变：同样输入不传参仍补回 0.08。
      expect(YoloOnnxService.clampToPage(box(0.13, 0.26, 0.8, 0.041)).h,
          0.08);
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

  group('groupInners（第 2 层框按中心点归属）', () {
    test('中心点在整题框内：归属该题；落不到任何题里：进 orphans', () {
      final boxes = [
        const QuestionBox(
            id: 'q1', layer: 1, type: 'question', x: 0.1, y: 0.1, w: 0.8, h: 0.3),
        const QuestionBox(
            id: 'q2', layer: 1, type: 'question', x: 0.1, y: 0.5, w: 0.8, h: 0.3),
        const QuestionBox(
            id: 'q1-stem-1', layer: 2, type: 'stem', x: 0.2, y: 0.15, w: 0.5, h: 0.1),
        const QuestionBox(
            id: 'q2-option-1', layer: 2, type: 'option', x: 0.2, y: 0.6, w: 0.2, h: 0.1),
        const QuestionBox(
            id: 'orphan', layer: 2, type: 'figure', x: 0.2, y: 0.85, w: 0.2, h: 0.1),
      ];
      final grouped = YoloOnnxService.groupInners(boxes);
      expect(grouped.inners['q1']!.map((b) => b.id), ['q1-stem-1']);
      expect(grouped.inners['q2']!.map((b) => b.id), ['q2-option-1']);
      expect(grouped.orphans.map((b) => b.id), ['orphan']);
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
          canvas.drawRect(
              ui.Rect.fromLTWH(80, 80.0 + i * 90, 640, 12), bar);
        }
        final img =
            await recorder.endRecording().toImage(800, 1000);
        final png =
            await img.toByteData(format: ui.ImageByteFormat.png);
        img.dispose();
        final file = File('${dir.path}/page.png');
        await file.writeAsBytes(png!.buffer.asUint8List());
        final boxes =
            await service.detectPage(imagePath: file.path, page: 1);
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
    });

    test('图片文件不存在：回占位，不抛错', () async {
      final service = YoloOnnxService();
      final boxes = await service.detectPage(
        imagePath: '/definitely/not/here/page.png',
        page: 1,
      );
      expect(boxes.length, 1);
      expect(boxes.first.id, 'box-q1');
      expect(boxes.first.layer, 1);
    });
  });
}
