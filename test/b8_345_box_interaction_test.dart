// B8-345 修框编辑器交互（第 3、4、5 项）真实交互测试。
//
// 按 flutter-testing skill 的分级：这里全是 widget 测试——用真实指针
// 事件（鼠标主按键拖动、真实 PointerScrollEvent 滚轮）驱动编辑器，
// 再用确认返回的 BoxEditorResult / 屏幕矩形 / 缩放百分比断言结果，
// 不是只验逻辑的单测。
//
// - 第 3 项：四角柄逐个拖（向外放大 + 向内缩回）、柄框外半边抓取、
//   柄命中区外的点抓不到柄；
// - 第 4 项：图上滚轮只缩放不滚动（zoom-to-cursor：指针下的内容点
//   在屏幕上不动）、图外滚轮不缩放只滚动页面、滚轮方向；
// - 第 5 项：角柄能把框缩到 0.08 以下、能放大到贴页边（不出页）、
//   右键手画小框也不补最小尺寸。
//
// 不碰真实演示库：页图是内嵌 1×1 PNG（base64），同步写临时文件
//（测试里不用异步文件 IO）；DB 一律不用。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/collect/collect_page.dart';
import 'package:quiz_master2/services/yolo_onnx_service.dart';
import 'package:quiz_master2/theme/app_theme.dart';

/// 1×1 白色 PNG（页图占位，解码后页尺寸 1×1，画布按 fit 取正方形）。
const _kPagePngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

late final Directory _testTmp;
late final String _pagePngPath;

/// 最近一次编辑器确认返回的结果（harness 的按钮回调写入）。
BoxEditorResult? _capturedResult;

QuestionBox _box({
  required String id,
  double x = 0.2,
  double y = 0.2,
  double w = 0.4,
  double h = 0.3,
}) => QuestionBox(
  id: id,
  layer: 1,
  type: 'question',
  x: x,
  y: y,
  w: w,
  h: h,
  page: 1,
  origin: 'manual',
);

/// 桩检测：不跑真实模型，返回空框（不走 fallback，不落占位框）。
class _EmptyYolo extends YoloOnnxService {
  @override
  Future<DetectionResult> detectPage({
    required String imagePath,
    required int page,
  }) async => const DetectionResult(boxes: [], usedFallback: false);
}

/// 画布内“题级框 1”标签所属的框手柄（GestureDetector，key 是 `editor-box-<id>`）。
/// 选中后标签变成“题级框 1 · 已选中”，用 textContaining 两种状态都找得到。
Finder _editorBoxHandle() => find.ancestor(
  of: find.descendant(
    of: find.byKey(const Key('box-editor-canvas')),
    matching: find.textContaining('题级框 1'),
  ),
  matching: find.byWidgetPredicate(
    (w) =>
        w is GestureDetector &&
        w.key is ValueKey<String> &&
        (w.key as ValueKey<String>).value.startsWith('editor-box-'),
  ),
);

/// 某角的缩放柄（key 是 `editor-resize-<corner>-<id>`，仅选中框才有）。
Finder _resizeHandle(String corner) =>
    find.byKey(Key('editor-resize-$corner-box-1'));

/// 打开修框编辑器的测试宿主：点“打开修框”按钮调 showBoxEditorDialog，
/// 确认结果写进 [_capturedResult]。每测一框：x=0.2, y=0.2, w=0.4, h=0.3。
Future<void> _openEditorDialog(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  _capturedResult = null;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              _capturedResult = await showBoxEditorDialog(
                context: context,
                fileName: 'test.pdf',
                pageImagePath: _pagePngPath,
                page: 1,
                pageCount: 1,
                subjectName: '数学',
                taskId: 'task-test',
                mode: BoxEditorMode.draft,
                initialBoxesByPage: {
                  1: [_box(id: 'box-1')],
                },
                yoloService: _EmptyYolo(),
              );
            },
            child: const Text('打开修框'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('打开修框'));
  await tester.pumpAndSettle();
  expect(find.textContaining('确认修框'), findsOneWidget);
  expect(find.text('100%'), findsOneWidget);
}

/// 点框选中它（柄出现），返回选中后的框矩形。
Future<Rect> _selectBox(WidgetTester tester) async {
  await tester.tap(_editorBoxHandle());
  await tester.pumpAndSettle();
  expect(_resizeHandle('se'), findsOneWidget);
  return tester.getRect(_editorBoxHandle());
}

/// 鼠标左键拖动（主要按键）——拖框 / 拖柄 / 平移图片用。
/// 分 4 步移：第一步可能被手势 slop 吃掉一部分，断言按此留余量。
Future<void> _dragMouseLeft(
  WidgetTester tester,
  Offset start,
  Offset offset,
) async {
  final gesture = await tester.startGesture(
    start,
    kind: ui.PointerDeviceKind.mouse,
    buttons: kPrimaryMouseButton,
  );
  for (var i = 0; i < 4; i++) {
    await gesture.moveBy(offset / 4);
    await tester.pump();
  }
  await tester.pumpAndSettle();
  await gesture.up();
  await tester.pumpAndSettle();
}

/// 鼠标右键拖动（次要按键）——画框用。
Future<void> _dragMouseRight(
  WidgetTester tester,
  Offset start,
  Offset offset,
) async {
  final gesture = await tester.startGesture(
    start,
    kind: ui.PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.moveBy(offset / 2);
  await gesture.moveBy(offset / 2);
  await tester.pumpAndSettle();
  await gesture.up();
  await tester.pumpAndSettle();
}

/// 指定位置发一次滚轮事件（dy < 0 上滚放大、dy > 0 下滚缩小）。
Future<void> _scrollWheel(
  WidgetTester tester,
  Offset location,
  Offset delta,
) async {
  await tester.sendEventToBinding(
    PointerScrollEvent(position: location, scrollDelta: delta),
  );
  await tester.pumpAndSettle();
}

Future<BoxEditorResult> _tapConfirm(WidgetTester tester) async {
  await tester.tap(find.textContaining('确认修框'));
  await tester.pumpAndSettle();
  expect(find.textContaining('确认修框'), findsNothing);
  expect(_capturedResult, isNotNull);
  return _capturedResult!;
}

/// 修框画布里竖向 / 横向滚动视图的当前偏移（滚动是否发生的标尺）。
double _editorPixels(WidgetTester tester, Axis axis) {
  final state = tester.state<ScrollableState>(
    find
        .descendant(
          of: find.byKey(const Key('box-editor-canvas')),
          matching: find.byWidgetPredicate(
            (w) => w is Scrollable && w.axis == axis,
          ),
        )
        .first,
  );
  return state.position.pixels;
}

/// 当前框矩形反推的画布原点与页宽/页高（页图 1×1，pw == ph）。
(Offset, double, double) _pageMetrics(WidgetTester tester) {
  final r = tester.getRect(_editorBoxHandle());
  final pw = r.width / 0.4;
  final ph = r.height / 0.3;
  return (Offset(r.left - 0.2 * pw, r.top - 0.2 * ph), pw, ph);
}

void main() {
  setUpAll(() {
    _testTmp = Directory.systemTemp.createTempSync('qm2-b8-345');
    _pagePngPath = '${_testTmp.path}/page.png';
    File(_pagePngPath).writeAsBytesSync(base64Decode(_kPagePngBase64));
  });

  tearDownAll(() {
    // 二十五批：先清图片缓存（page.png 经 Image.file 显示后 mmap
    // 占着文件），再删目录；否则 Windows 上报 errno 32。
    imageCache.clear();
    _testTmp.deleteSync(recursive: true);
  });

  group('B8-345(5) clampToPage：minSize: false 不补最小尺寸', () {
    test('小于 0.08 的框原样保留（编辑器入口的钳制语义）', () {
      final tiny = YoloOnnxService.clampToPage(
        _box(id: 't', x: 0.2, y: 0.2, w: 0.03, h: 0.02),
        minSize: false,
      );
      // 交集钳制会过一次加减法，浮点尾差用 epsilon 比。
      expect(tiny.w, moreOrLessEquals(0.03, epsilon: 1e-9));
      expect(tiny.h, moreOrLessEquals(0.02, epsilon: 1e-9));
      expect(tiny.x, 0.2);
      // 对照：默认分支仍补 0.08（S8A3 锁定，编辑器已不再走它）。
      final floored = YoloOnnxService.clampToPage(
        _box(id: 't', x: 0.2, y: 0.2, w: 0.03, h: 0.02),
      );
      expect(floored.w, 0.08);
      expect(floored.h, 0.08);
    });
  });

  group('B8-345(3) 角柄四角拖动', () {
    testWidgets('SE 角：向外拖放大、向内拖回到原位', (tester) async {
      await _openEditorDialog(tester);
      final rect0 = await _selectBox(tester);
      final handle = tester.getCenter(_resizeHandle('se'));
      expect((handle - rect0.bottomRight).distance, lessThan(1.0));
      // 向外拖：右、下两边都长，左、上两边不动。
      await _dragMouseLeft(tester, handle, const Offset(60, 45));
      final rect1 = tester.getRect(_editorBoxHandle());
      expect(rect1.left, moreOrLessEquals(rect0.left, epsilon: 2.0));
      expect(rect1.top, moreOrLessEquals(rect0.top, epsilon: 2.0));
      expect(rect1.right - rect0.right, greaterThan(20));
      expect(rect1.bottom - rect0.bottom, greaterThan(15));
      // 向内拖回：回到原位（余量是手势 slop 两头各吃一点）。
      final handle1 = tester.getCenter(_resizeHandle('se'));
      await _dragMouseLeft(tester, handle1, const Offset(-60, -45));
      final rect2 = tester.getRect(_editorBoxHandle());
      expect(rect2.left, moreOrLessEquals(rect0.left, epsilon: 20.0));
      expect(rect2.top, moreOrLessEquals(rect0.top, epsilon: 20.0));
      expect(rect2.right, moreOrLessEquals(rect0.right, epsilon: 20.0));
      expect(rect2.bottom, moreOrLessEquals(rect0.bottom, epsilon: 20.0));
      // 确认落盘：分数坐标回到 0.2 / 0.2 / 0.4 / 0.3 附近。
      final result = await _tapConfirm(tester);
      final box = result.boxesByPage[1]!.single;
      expect(box.x, moreOrLessEquals(0.2, epsilon: 0.06));
      expect(box.y, moreOrLessEquals(0.2, epsilon: 0.06));
      expect(box.w, moreOrLessEquals(0.4, epsilon: 0.06));
      expect(box.h, moreOrLessEquals(0.3, epsilon: 0.06));
    });

    testWidgets('NW 角：向外拖放大（左、上两边外扩，右、下两边不动）', (tester) async {
      await _openEditorDialog(tester);
      final rect0 = await _selectBox(tester);
      final handle = tester.getCenter(_resizeHandle('nw'));
      expect((handle - rect0.topLeft).distance, lessThan(1.0));
      await _dragMouseLeft(tester, handle, const Offset(-60, -45));
      final rect1 = tester.getRect(_editorBoxHandle());
      expect(rect1.right, moreOrLessEquals(rect0.right, epsilon: 2.0));
      expect(rect1.bottom, moreOrLessEquals(rect0.bottom, epsilon: 2.0));
      expect(rect0.left - rect1.left, greaterThan(20));
      expect(rect0.top - rect1.top, greaterThan(15));
      final result = await _tapConfirm(tester);
      final box = result.boxesByPage[1]!.single;
      expect(box.x, lessThan(0.2));
      expect(box.y, lessThan(0.2));
      expect(box.w, greaterThan(0.4));
      expect(box.h, greaterThan(0.3));
    });

    testWidgets('NE 角：向外拖放大（右、上两边动，左、下两边不动）', (tester) async {
      await _openEditorDialog(tester);
      final rect0 = await _selectBox(tester);
      final handle = tester.getCenter(_resizeHandle('ne'));
      expect((handle - rect0.topRight).distance, lessThan(1.0));
      await _dragMouseLeft(tester, handle, const Offset(60, -45));
      final rect1 = tester.getRect(_editorBoxHandle());
      expect(rect1.left, moreOrLessEquals(rect0.left, epsilon: 2.0));
      expect(rect1.bottom, moreOrLessEquals(rect0.bottom, epsilon: 2.0));
      expect(rect1.right - rect0.right, greaterThan(20));
      expect(rect0.top - rect1.top, greaterThan(15));
      final result = await _tapConfirm(tester);
      final box = result.boxesByPage[1]!.single;
      expect(box.x, moreOrLessEquals(0.2, epsilon: 0.02));
      expect(box.y, lessThan(0.2));
      expect(box.w, greaterThan(0.4));
      expect(box.h, greaterThan(0.3));
    });

    testWidgets('SW 角：向外拖放大（左、下两边动，右、上两边不动）', (tester) async {
      await _openEditorDialog(tester);
      final rect0 = await _selectBox(tester);
      final handle = tester.getCenter(_resizeHandle('sw'));
      expect((handle - rect0.bottomLeft).distance, lessThan(1.0));
      await _dragMouseLeft(tester, handle, const Offset(-60, 45));
      final rect1 = tester.getRect(_editorBoxHandle());
      expect(rect1.right, moreOrLessEquals(rect0.right, epsilon: 2.0));
      expect(rect1.top, moreOrLessEquals(rect0.top, epsilon: 2.0));
      expect(rect0.left - rect1.left, greaterThan(20));
      expect(rect1.bottom - rect0.bottom, greaterThan(15));
      final result = await _tapConfirm(tester);
      final box = result.boxesByPage[1]!.single;
      expect(box.x, lessThan(0.2));
      expect(box.y, moreOrLessEquals(0.2, epsilon: 0.02));
      expect(box.w, greaterThan(0.4));
      expect(box.h, greaterThan(0.3));
    });

    testWidgets('柄框外半边能抓住：从角外 10px 处（视觉柄外、24px 命中区内）拖动', (
      tester,
    ) async {
      // 四角各抓一次：起点在角点向外 10px——旧 13px 视觉柄（半边 6.5px）
      // 够不到，新 24px 命中区（半边 12px 的正方形）够得到。
      // 每项是（角外起点偏移， 向外拖动偏移）。
      const grabs = {
        'se': (Offset(10, 10), Offset(40, 30)),
        'nw': (Offset(-10, -10), Offset(-40, -30)),
        'ne': (Offset(10, -10), Offset(40, -30)),
        'sw': (Offset(-10, 10), Offset(-40, 30)),
      };
      for (final entry in grabs.entries) {
        await _openEditorDialog(tester);
        final rect0 = await _selectBox(tester);
        final corner = switch (entry.key) {
          'se' => rect0.bottomRight,
          'nw' => rect0.topLeft,
          'ne' => rect0.topRight,
          'sw' => rect0.bottomLeft,
          _ => rect0.center,
        };
        final before = tester.getRect(_editorBoxHandle());
        await _dragMouseLeft(
          tester,
          corner + entry.value.$1,
          entry.value.$2,
        );
        final after = tester.getRect(_editorBoxHandle());
        expect(
          (after.width - before.width).abs() +
              (after.height - before.height).abs(),
          greaterThan(10),
          reason: '${entry.key} 角：框外 10px 起点拖动后框尺寸应变化',
        );
        final result = await _tapConfirm(tester);
        expect(result.boxesByPage[1]!.single.id, 'box-1');
      }
    });

    testWidgets('对照：角外 16px 处抓不到柄（只平移图片，框分数坐标不动）', (
      tester,
    ) async {
      await _openEditorDialog(tester);
      final rect0 = await _selectBox(tester);
      // SE 角外 16px：超出 24px 命中区（半边 12px），落在图内空白处。
      final outside = rect0.bottomRight + const Offset(16, 16);
      await _dragMouseLeft(tester, outside, const Offset(40, 30));
      final result = await _tapConfirm(tester);
      final box = result.boxesByPage[1]!.single;
      expect(box.x, moreOrLessEquals(0.2, epsilon: 0.01));
      expect(box.y, moreOrLessEquals(0.2, epsilon: 0.01));
      expect(box.w, moreOrLessEquals(0.4, epsilon: 0.01));
      expect(box.h, moreOrLessEquals(0.3, epsilon: 0.01));
    });
  });

  group('B8-345(4) 滚轮', () {
    testWidgets('图上滚轮只缩放不滚动：zoom-to-cursor，指针下的内容点不动', (
      tester,
    ) async {
      await _openEditorDialog(tester);
      final (origin, pageW, pageH) = _pageMetrics(tester);
      final center = origin + Offset(pageW / 2, pageH / 2);
      // 先放大到 250%：横、竖内容都超出视口，两个方向都有滚动余量，
      // zoom-to-cursor 的补偿才能在两个方向都生效。
      for (var i = 0; i < 15; i++) {
        await _scrollWheel(tester, center, const Offset(0, -120));
      }
      expect(find.text('250%'), findsOneWidget);
      // 指针放在框中心：再滚一格放大到 260%，框中心在屏幕上应原地不动
      //（旧行为会同时滚动，框中心会被滚走几十像素）。
      final boxCenter0 = tester.getRect(_editorBoxHandle()).center;
      final v0 = _editorPixels(tester, Axis.vertical);
      final h0 = _editorPixels(tester, Axis.horizontal);
      await _scrollWheel(tester, boxCenter0, const Offset(0, -120));
      expect(find.text('260%'), findsOneWidget);
      final boxCenter1 = tester.getRect(_editorBoxHandle()).center;
      expect(boxCenter1.dx, moreOrLessEquals(boxCenter0.dx, epsilon: 3.0));
      expect(boxCenter1.dy, moreOrLessEquals(boxCenter0.dy, epsilon: 3.0));
      // 滚动偏移只应为 zoom-to-cursor 的补偿而动（指针不在视口正中，
      // 补偿量非零），且框没被滚走已由上断言覆盖。
      expect(
        (v0 - _editorPixels(tester, Axis.vertical)).abs() +
            (h0 - _editorPixels(tester, Axis.horizontal)).abs(),
        greaterThan(1.0),
      );
    });

    testWidgets('滚轮方向：上滚放大、下滚缩小', (tester) async {
      await _openEditorDialog(tester);
      final (origin, pageW, pageH) = _pageMetrics(tester);
      final center = origin + Offset(pageW / 2, pageH / 2);
      await _scrollWheel(tester, center, const Offset(0, -120));
      expect(find.text('110%'), findsOneWidget);
      await _scrollWheel(tester, center, const Offset(0, 120));
      expect(find.text('100%'), findsOneWidget);
    });

    testWidgets('图外滚轮不缩放、页面滚动', (tester) async {
      await _openEditorDialog(tester);
      final (origin, pageW, pageH) = _pageMetrics(tester);
      final center = origin + Offset(pageW / 2, pageH / 2);
      for (var i = 0; i < 10; i++) {
        await _scrollWheel(tester, center, const Offset(0, -120));
      }
      expect(find.text('200%'), findsOneWidget);
      // 图外边距：画布左缘外 10px 处（放大后页变大，用框矩形反推页左缘）。
      final canvasRect = tester.getRect(
        find.byKey(const Key('box-editor-canvas')),
      );
      final marginPoint = Offset(canvasRect.left + 10, canvasRect.center.dy);
      final zoomedBoxRect = tester.getRect(_editorBoxHandle());
      final pageLeft =
          zoomedBoxRect.left - 0.2 * (zoomedBoxRect.width / 0.4);
      expect(marginPoint.dx < pageLeft, isTrue);
      final before = _editorPixels(tester, Axis.vertical);
      await _scrollWheel(tester, marginPoint, const Offset(0, 120));
      expect(find.text('200%'), findsOneWidget);
      expect(_editorPixels(tester, Axis.vertical), greaterThan(before));
    });
  });

  group('B8-345(5) 框大小不限', () {
    testWidgets('角柄能把框缩到 0.08 以下（旧最小尺寸不再生效）', (tester) async {
      await _openEditorDialog(tester);
      final rect0 = await _selectBox(tester);
      // 按实测页宽算拖动量：向内拖 0.37pw / 0.28pw，w 0.4→约 0.03、
      // h 0.3→约 0.02（留出手势 slop 的余量，仍 < 0.08 且 > 0）。
      final pw = rect0.width / 0.4;
      final handle = tester.getCenter(_resizeHandle('se'));
      await _dragMouseLeft(
        tester,
        handle,
        Offset(-0.37 * pw, -0.28 * pw),
      );
      final result = await _tapConfirm(tester);
      final box = result.boxesByPage[1]!.single;
      expect(box.w, lessThan(0.08));
      expect(box.h, lessThan(0.08));
      expect(box.w, greaterThan(0.0));
      expect(box.h, greaterThan(0.0));
    });

    testWidgets('角柄能把框放大到贴页边（无最大尺寸，仍不出页）', (tester) async {
      await _openEditorDialog(tester);
      await _selectBox(tester);
      final handle = tester.getCenter(_resizeHandle('se'));
      await _dragMouseLeft(tester, handle, const Offset(300, 300));
      final result = await _tapConfirm(tester);
      final box = result.boxesByPage[1]!.single;
      expect(box.x + box.w, lessThanOrEqualTo(1.0));
      expect(box.y + box.h, lessThanOrEqualTo(1.0));
      expect(box.w, moreOrLessEquals(0.8, epsilon: 0.03));
      expect(box.h, moreOrLessEquals(0.8, epsilon: 0.03));
    });

    testWidgets('右键手画小框也不补最小尺寸', (tester) async {
      await _openEditorDialog(tester);
      // 先删掉现成的大框，再在空白处右键拖一个约 0.05×0.05 的小框。
      await tester.tap(_editorBoxHandle());
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除选中框'));
      await tester.pumpAndSettle();
      // 框已删，用画布矩形反推页位置：页图 1×1，页是画布区里
      // min(宽,高) 的正方形，居中。
      final canvasRect = tester.getRect(
        find.byKey(const Key('box-editor-canvas')),
      );
      final side = math.min(canvasRect.width, canvasRect.height);
      final pageOrigin = Offset(
        canvasRect.left + (canvasRect.width - side) / 2,
        canvasRect.top + (canvasRect.height - side) / 2,
      );
      await _dragMouseRight(
        tester,
        pageOrigin + Offset(0.1 * side, 0.1 * side),
        Offset(0.05 * side, 0.05 * side),
      );
      final result = await _tapConfirm(tester);
      final box = result.boxesByPage[1]!.single;
      expect(box.w, lessThan(0.08));
      expect(box.h, lessThan(0.08));
      expect(box.w, greaterThan(0.02));
      expect(box.h, greaterThan(0.02));
    });
  });
}
