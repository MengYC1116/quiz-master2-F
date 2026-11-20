// WP-E #9 图片默认 100% + 居中（定稿 §9 + R7 + S6 + T6 + U4-2）。
//
// 覆盖：§9.3 六项（100% / 竖版 fit / 横版 fit / 小图不放大 /
// 手动放大约 150% 中心缩放+拖动+边界 / 窗口缩放后重开）；
// R7-4 五项（放大后改窗口保持 / 拖动后改窗口保持 / 加载前后改窗口
// 不跳回默认位置 / 关闭后才加载完成无迟到更新 / 重开回默认）；
// S6-4 三态（初始态未就绪 / 已就绪无交互 / 交互态 / 重开态）。
//
// 注意：widget 测试里 Image.file 的异步解码只在 runAsync + 真实延时
// 的 pump 中推进（见 _awaitImageDecode）；只 pump 假时间解码永不完成，
// 这正是“未就绪”态的测试手段，也是生产环境“图片未解码”的等价态。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';
import 'package:quiz_master2/widgets/widgets.dart';

late final Directory _tmp;

// ---- 最小 PNG 编码器（实色 RGBA）----
int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

void _chunk(BytesBuilder out, String type, List<int> data) {
  final t = utf8.encode(type);
  out.add([
    (data.length >> 24) & 0xFF,
    (data.length >> 16) & 0xFF,
    (data.length >> 8) & 0xFF,
    data.length & 0xFF,
  ]);
  out.add(t);
  out.add(data);
  final crc = _crc32([...t, ...data]);
  out.add([
    (crc >> 24) & 0xFF,
    (crc >> 16) & 0xFF,
    (crc >> 8) & 0xFF,
    crc & 0xFF,
  ]);
}

Uint8List _solidPng(int w, int h) {
  final out = BytesBuilder();
  out.add([137, 80, 78, 71, 13, 10, 26, 10]);
  final ihdr = BytesBuilder();
  ihdr.add([
    (w >> 24) & 0xFF, (w >> 16) & 0xFF, (w >> 8) & 0xFF, w & 0xFF,
    (h >> 24) & 0xFF, (h >> 16) & 0xFF, (h >> 8) & 0xFF, h & 0xFF,
    8, 6, 0, 0, 0,
  ]);
  _chunk(out, 'IHDR', ihdr.toBytes());
  final raw = BytesBuilder();
  for (var y = 0; y < h; y++) {
    raw.addByte(0);
    for (var x = 0; x < w; x++) {
      raw.add([200, 30, 30, 255]);
    }
  }
  _chunk(out, 'IDAT', ZLibEncoder().convert(raw.toBytes()));
  _chunk(out, 'IEND', []);
  return out.toBytes();
}

// ---- 测试帮手 ----

Question _imageQuestion(String id, String sliceRel) => Question(
      id: id,
      title: '第 1 题',
      subjectId: 'math',
      createdAt: DateTime.now(),
      slicePath: sliceRel,
      sourcePath: sliceRel,
    );

Question _demoQuestion() => Question(
      id: 'qd',
      title: '演示题',
      subjectId: 'math',
      createdAt: DateTime.now(),
      isDemo: true,
      sliceText: '求函数 f(x)=x^2 的导数',
    );

String _writePng(String name, int w, int h) {
  final dir = Directory('${_tmp.path}/slices')..createSync(recursive: true);
  File('${dir.path}/$name').writeAsBytesSync(_solidPng(w, h));
  return 'slices/$name';
}

void _setSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
  });
}

/// 在 runAsync 内打开对话框：Image.file 的加载链须在真实异步 zone
/// 里启动，之后 _awaitImageDecode 的真实延时才能推进解码。
Future<void> _openDialog(WidgetTester tester, Question q) async {
  await tester.runAsync(() async {
    await _pumpHome(tester, q);
    await tester.pump();
  });
  await tester.pump();
  await tester.pump();
}

/// runAsync 外打开（仅用于“未就绪”态测试）：加载链卡在 FakeAsync
/// 里永不解码，即生产环境“图片未就绪”的等价态。
Future<void> _openDialogNoAsync(WidgetTester tester, Question q) async {
  await _pumpHome(tester, q);
  await tester.pump();
}

Future<void> _pumpHome(WidgetTester tester, Question q) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showQuestionZoomDialog(context, q),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('打开'));
  await tester.pump();
}

/// 真实解码推进：文件 IO + 编解码只在 runAsync 的真实时间里完成。
Future<void> _awaitImageDecode(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await tester.pump();
  });
  await tester.pump();
  await tester.pump();
}

Matrix4 _matrix(WidgetTester tester) => tester
    .widget<InteractiveViewer>(find.byType(InteractiveViewer))
    .transformationController!
    .value;

int _badge(WidgetTester tester) {
  final text = tester.widget<Text>(find.textContaining(RegExp(r'^\d+%$')));
  return int.parse(text.data!.replaceAll('%', ''));
}

Rect _paperRect(WidgetTester tester) =>
    tester.getRect(find.byType(QuestionSlice));

Rect _viewportRect(WidgetTester tester) =>
    tester.getRect(find.byType(InteractiveViewer));

/// s0 = min(1.0, fit)，fit 用实测视口与纸面布局尺寸算（T6-1）。
double _expectedS0(WidgetTester tester) {
  final vp = tester.getSize(find.byType(InteractiveViewer));
  final paper = tester.getSize(find.byType(QuestionSlice));
  final fit =
      (vp.width / paper.width).clamp(0.0, double.infinity).toDouble();
  final fitH =
      (vp.height / paper.height).clamp(0.0, double.infinity).toDouble();
  final f = fit < fitH ? fit : fitH;
  return f < 1.0 ? f : 1.0;
}

/// 断言当前矩阵就是纯缩放 diagonal(s0, s0, 1)，无任何平移（R7-3）。
void _expectPureScale(WidgetTester tester, double s0) {
  final m = _matrix(tester);
  final s = m.storage;
  for (var i = 0; i < 16; i++) {
    final expected = i == 0 || i == 5
        ? s0
        : (i == 10 || i == 15 ? 1.0 : 0.0);
    expect(s[i], closeTo(expected, 1e-9), reason: '矩阵 storage[$i]');
  }
}

/// 断言纸面中心与视口中心重合（R7-3：矩阵值 + 居中几何双断言）。
void _expectCentered(WidgetTester tester) {
  final paper = _paperRect(tester);
  final vp = _viewportRect(tester);
  expect((paper.center.dx - vp.center.dx).abs(), lessThanOrEqualTo(1.0),
      reason: '纸面中心 x 偏离视口中心：paper=$paper vp=$vp');
  expect((paper.center.dy - vp.center.dy).abs(), lessThanOrEqualTo(1.0),
      reason: '纸面中心 y 偏离视口中心：paper=$paper vp=$vp');
}

/// 断言纸面中心与视口中心重合、无裁切（仅 s0 ≤ 1 时可用；放大后纸面
/// 本就大于视口，须改用 [_expectCentered]）。
void _expectCenteredNoClip(WidgetTester tester) {
  _expectCentered(tester);
  final paper = _paperRect(tester);
  final vp = _viewportRect(tester);
  expect(vp.left - 1.0 <= paper.left && paper.right <= vp.right + 1.0,
      isTrue,
      reason: '纸面横向裁切：paper=$paper vp=$vp');
  expect(vp.top - 1.0 <= paper.top && paper.bottom <= vp.bottom + 1.0,
      isTrue,
      reason: '纸面纵向裁切：paper=$paper vp=$vp');
}

Future<void> _closeDialog(WidgetTester tester) async {
  await tester.tap(find.text('关闭 ×'));
  await tester.pumpAndSettle();
  expect(find.text('整题图 · 放大查看'), findsNothing);
}

/// 精确拖动（REV5 修正后补）：按下后先走一小步（30px，超过手势识别
/// 的 pan slop 18px，触发 InteractiveViewer 的 scale 手势开始——
/// 这一步被识别消耗，不产生平移），再按 [offset] 移动，视图恰好
/// 跟随 [offset]。
///
/// 不能直接用 tester.drag：它把 offset 拆成 slop 步长（默认 20px）
/// 的多步移动，第一步被识别消耗，只剩 offset 减第一步的量生效
/// （如 (60,40) 只生效 (40,26.67)，探针实测）；且单步移动会在同一
/// 次事件里既触发开始又更新，位移为 0。生产环境手指拖动是连续多步
/// 移动，识别消耗的只是开头一小段，之后视图 1:1 跟随手指——本
/// helper 模拟的正是这段行为，“视图跟随拖动量”的断言才成立。
Future<void> _dragFully(
    WidgetTester tester, Finder finder, Offset offset) async {
  final gesture = await tester.startGesture(tester.getCenter(finder));
  await gesture.moveBy(const Offset(30, 0));
  await gesture.moveBy(offset);
  await gesture.up();
}

void main() {
  setUpAll(() async {
    _tmp = await Directory.systemTemp.createTemp('qm2-wpe-zoom');
    AppDatabase.testDataDirectory = _tmp.path;
  });

  tearDownAll(() async {
    AppDatabase.testDataDirectory = null;
    await _tmp.delete(recursive: true);
  });

  group('WP-E #9 §9.3 默认缩放与居中', () {
    testWidgets('普通尺寸图片：默认 100%，完整居中，无裁切', (tester) async {
      final q = _imageQuestion('q1', _writePng('land.png', 680, 480));
      await _openDialog(tester, q);
      await _awaitImageDecode(tester);
      // ResizeImage 解码取整会让布局宽比像素宽小零点几 px，用 closeTo。
      final paperSize = tester.getSize(find.byType(QuestionSlice));
      expect(paperSize.width, closeTo(680, 1.5));
      expect(paperSize.height, closeTo(480, 1.5));
      expect(_expectedS0(tester), 1.0);
      expect(_badge(tester), 100);
      _expectPureScale(tester, 1.0);
      _expectCenteredNoClip(tester);
    });

    testWidgets('超长竖版试卷：按 fit 缩小，完整居中', (tester) async {
      _setSurface(tester, const Size(500, 400));
      final q = _imageQuestion('q2', _writePng('port.png', 700, 1400));
      await _openDialog(tester, q);
      await _awaitImageDecode(tester);
      // 布局注：Center + IntrinsicHeight 已把纸面钳制进视口（纸面
      // 布局尺寸恒 ≤ 视口），故 fit 恒 ≥ 1、s0 恒为 1.0；“按 fit 缩小”
      // 在实测中表现为纸面贴合视口约束边（竖版贴满视口高）且 100%
      // 完整居中、无裁切。旧代码此处会把 2×2 占位锁成 150% 平移矩阵、
      // 纸面飞出视口。
      final paperSize = tester.getSize(find.byType(QuestionSlice));
      final vpSize = tester.getSize(find.byType(InteractiveViewer));
      expect(paperSize.height, closeTo(vpSize.height, 3.0),
          reason: '竖版纸面应贴满视口高');
      expect(paperSize.width, closeTo(paperSize.height / 2, 3.0),
          reason: '700×1400 纸面宽高比应为 1:2');
      final s0 = _expectedS0(tester);
      expect(_badge(tester), (s0 * 100).round());
      _expectPureScale(tester, s0);
      _expectCenteredNoClip(tester);
    });

    testWidgets('横版图片：按 fit 缩小，完整居中', (tester) async {
      _setSurface(tester, const Size(500, 400));
      final q = _imageQuestion('q3', _writePng('wide.png', 680, 340));
      await _openDialog(tester, q);
      await _awaitImageDecode(tester);
      // 同上：横版在小视口下贴满视口宽、100% 完整居中。
      final wideSize = tester.getSize(find.byType(QuestionSlice));
      final vpSize = tester.getSize(find.byType(InteractiveViewer));
      expect(wideSize.width, closeTo(vpSize.width, 3.0),
          reason: '横版纸面应贴满视口宽');
      expect(wideSize.height, closeTo(wideSize.width / 2, 3.0),
          reason: '680×340 纸面宽高比应为 2:1');
      final s0 = _expectedS0(tester);
      expect(_badge(tester), (s0 * 100).round());
      _expectPureScale(tester, s0);
      _expectCenteredNoClip(tester);
    });

    testWidgets('小尺寸图片：100%，不强制放大', (tester) async {
      final q = _imageQuestion('q4', _writePng('small.png', 200, 100));
      await _openDialog(tester, q);
      await _awaitImageDecode(tester);
      final smallSize = tester.getSize(find.byType(QuestionSlice));
      // 纸面 Container 边框会让布局尺寸比图片像素大 2px 左右。
      expect(smallSize.width, closeTo(200, 3.0));
      expect(smallSize.height, closeTo(100, 3.0));
      expect(_expectedS0(tester), 1.0);
      expect(_badge(tester), 100);
      _expectPureScale(tester, 1.0);
      _expectCenteredNoClip(tester);
    });

    testWidgets('手动放大到约 150%：以图片中心缩放，后续拖动正常，边界限制正常',
        (tester) async {
      final q = _imageQuestion('q5', _writePng('land5.png', 680, 480));
      await _openDialog(tester, q);
      await _awaitImageDecode(tester);
      expect(_badge(tester), 100);
      await tester.tap(find.text('＋'));
      await tester.pump();
      await tester.tap(find.text('＋'));
      await tester.pump();
      await tester.pump();
      // 1.25 × 1.25 = 156%（按钮档位；设计“约 150%”）。
      expect(_badge(tester), 156);
      expect(_matrix(tester).getMaxScaleOnAxis(), closeTo(1.5625, 1e-9));
      // 以图片中心缩放：放大后纸面中心仍在视口中心（只断言居中；
      // 156% 下纸面本就大于视口，不适用“无裁切”）。
      _expectCentered(tester);
      // 后续拖动正常：纸面中心跟随拖动量（_dragFully 精确拖动，
      // 见 helper 注释；tester.drag 的第一步会被识别消耗）。
      final before = _paperRect(tester).center;
      await _dragFully(
          tester, find.byType(QuestionSlice), const Offset(60, 40));
      await tester.pump();
      final afterDrag = _paperRect(tester).center;
      expect((afterDrag.dx - before.dx - 60).abs(), lessThanOrEqualTo(2.0));
      expect((afterDrag.dy - before.dy - 40).abs(), lessThanOrEqualTo(2.0));
      // 边界限制正常：往一侧猛拖，纸面仍盖住视口中心、不飞走。
      await tester.drag(
          find.byType(QuestionSlice), const Offset(2000, 0));
      await tester.pump();
      final paper = _paperRect(tester);
      final vpCenter = _viewportRect(tester).center;
      expect(paper.contains(vpCenter), isTrue,
          reason: '猛拖后纸面应仍盖住视口中心：paper=$paper');
      expect((paper.center.dx - vpCenter.dx).abs(), greaterThan(100),
          reason: '猛拖后纸面应已移动到边界');
    });

    testWidgets('窗口缩放后重开：仍居中，不沿用旧尺寸', (tester) async {
      final q = _imageQuestion('q6', _writePng('land6.png', 680, 480));
      await _openDialog(tester, q);
      await _awaitImageDecode(tester);
      expect(_badge(tester), 100);
      await _closeDialog(tester);
      _setSurface(tester, const Size(500, 400));
      await _openDialog(tester, q);
      await _awaitImageDecode(tester);
      // 重开后按新视口适配：680×480 图在 500×400 下是高约束，
      // 纸面贴满新视口高（297）、100% 完整居中（旧代码会沿用旧视口
      // 算出的平移矩阵，纸面偏出视口）。
      final paperSize = tester.getSize(find.byType(QuestionSlice));
      final vpSize = tester.getSize(find.byType(InteractiveViewer));
      expect(paperSize.height, closeTo(vpSize.height, 3.0));
      expect(paperSize.width,
          closeTo(paperSize.height * 680 / 480, 3.0));
      final s0 = _expectedS0(tester);
      expect(_badge(tester), (s0 * 100).round());
      _expectPureScale(tester, s0);
      _expectCenteredNoClip(tester);
    });
  });

  group('WP-E #9 R7-4 交互态与重开', () {
    testWidgets('用户放大到约 150% 后调整窗口尺寸：视图保持、不重置',
        (tester) async {
      final q = _imageQuestion('q7', _writePng('land7.png', 680, 480));
      await _openDialog(tester, q);
      await _awaitImageDecode(tester);
      await tester.tap(find.text('＋'));
      await tester.pump();
      await tester.tap(find.text('＋'));
      await tester.pump();
      await tester.pump();
      expect(_badge(tester), 156);
      final before = List<double>.of(_matrix(tester).storage);
      _setSurface(tester, const Size(500, 400));
      await tester.pump();
      await tester.pump();
      final after = _matrix(tester).storage;
      for (var i = 0; i < 16; i++) {
        expect(after[i], closeTo(before[i], 1e-9), reason: '矩阵 storage[$i]');
      }
      expect(_badge(tester), 156);
    });

    testWidgets('用户拖动后调整窗口尺寸：视图保持', (tester) async {
      final q = _imageQuestion('q8', _writePng('land8.png', 680, 480));
      await _openDialog(tester, q);
      await _awaitImageDecode(tester);
      // 100% 时 InteractiveViewer 的边界钳制不允许平移（子盒恰好等于
      // 视口），故先 ＋ 放大到 125% 再拖动，才有可断言的平移量。
      await tester.tap(find.text('＋'));
      await tester.pump();
      await tester.pump();
      expect(_badge(tester), 125);
      // REV5 修正（alignment 回 null）：初始矩阵为 T(C)·S(s0)·T(−C)，
      // ＋ 后矩阵平移已为 −0.25·C（C 为视口中心），不再是纯缩放的 0；
      // 断言拖动的增量（视图恰好跟随拖动量），而非绝对平移值。
      final preDrag = List<double>.of(_matrix(tester).storage);
      await _dragFully(
          tester, find.byType(QuestionSlice), const Offset(60, 40));
      await tester.pump();
      final before = List<double>.of(_matrix(tester).storage);
      expect(before[12], closeTo(preDrag[12] + 60, 2.0),
          reason: '拖动应产生 x 平移');
      expect(before[13], closeTo(preDrag[13] + 40, 2.0),
          reason: '拖动应产生 y 平移');
      _setSurface(tester, const Size(500, 400));
      await tester.pump();
      await tester.pump();
      final after = _matrix(tester).storage;
      for (var i = 0; i < 16; i++) {
        expect(after[i], closeTo(before[i], 1e-9), reason: '矩阵 storage[$i]');
      }
    });

    testWidgets('图片加载完成前后窗口尺寸变化：加载完成后不跳回默认位置',
        (tester) async {
      final q = _imageQuestion('q9', _writePng('land9.png', 680, 480));
      await _openDialog(tester, q);
      // 图片尚未解码时改窗口尺寸（此时应无矩阵、不重算）。
      expect(_matrix(tester), Matrix4.identity());
      _setSurface(tester, const Size(500, 400));
      await tester.pump();
      await tester.pump();
      expect(_matrix(tester), Matrix4.identity());
      // 此时图片才解码完成：初始矩阵必须按新视口算，不得用旧视口。
      // （布局已把纸面钳制进新视口，故 s0 取实测值；旧代码会在旧视口
      // 下把 2×2 占位锁成 150% 平移矩阵，纸面飞出视口。）
      await _awaitImageDecode(tester);
      final s0 = _expectedS0(tester);
      expect(_badge(tester), (s0 * 100).round());
      _expectPureScale(tester, s0);
      _expectCenteredNoClip(tester);
    });

    testWidgets('图片在对话框已关闭后才加载完成：无迟到状态更新、无崩溃',
        (tester) async {
      // 用大图拉长解码时间，使解码更可能落在对话框销毁之后；即使
      // 解码先完成，本测试仍校验关闭后无迟到更新、无崩溃。
      final q = _imageQuestion('q10', _writePng('land10.png', 1000, 1400));
      await _openDialog(tester, q);
      await _closeDialog(tester);
      // 对话框已销毁后图片才解码完成。
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await tester.pump();
      });
      await tester.pumpAndSettle();
      expect(find.text('整题图 · 放大查看'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('重新打开对话框：默认 min(100%, fit) + 居中',
        (tester) async {
      final q = _imageQuestion('q11', _writePng('land11.png', 680, 480));
      await _openDialog(tester, q);
      await _awaitImageDecode(tester);
      await tester.tap(find.text('＋'));
      await tester.pump();
      await tester.tap(find.text('＋'));
      await tester.pump();
      await tester.drag(
          find.byType(QuestionSlice), const Offset(30, 20));
      await tester.pump();
      expect(_badge(tester), 156);
      await _closeDialog(tester);
      await _openDialog(tester, q);
      await _awaitImageDecode(tester);
      expect(_badge(tester), 100);
      _expectPureScale(tester, 1.0);
      _expectCenteredNoClip(tester);
    });
  });

  group('WP-E #9 S6-4 三态', () {
    testWidgets('初始态未就绪：无矩阵、不显示错误位置，缩放/拖动均无动作',
        (tester) async {
      final q = _imageQuestion('q12', _writePng('land12.png', 680, 480));
      await _openDialogNoAsync(tester, q);
      // 只 pump 假时间：图片永不解码（生产环境“图片未就绪”的等价态）。
      expect(_matrix(tester), Matrix4.identity());
      expect(_badge(tester), 100);
      // 占位纸面居中在视口内，不显示错误位置。
      final paper = _paperRect(tester);
      final vp = _viewportRect(tester);
      expect(vp.contains(paper.center), isTrue,
          reason: '未就绪占位应在视口内：paper=$paper vp=$vp');
      // ＋/－ 按钮禁用（S6-3）。
      expect(
          tester.widget<QmButton>(find.widgetWithText(QmButton, '＋'))
              .onPressed,
          isNull);
      expect(
          tester.widget<QmButton>(find.widgetWithText(QmButton, '－'))
              .onPressed,
          isNull);
      await tester.tap(find.text('＋'));
      await tester.pump();
      expect(_matrix(tester), Matrix4.identity());
      expect(_badge(tester), 100);
      // 滚轮无动作。
      await tester.sendEventToBinding(PointerScrollEvent(
        position: _viewportRect(tester).center,
        scrollDelta: const Offset(0, -120),
      ));
      await tester.pump();
      expect(_matrix(tester), Matrix4.identity());
      expect(_badge(tester), 100);
      // 拖动无动作。
      await tester.drag(
          find.byType(QuestionSlice), const Offset(60, 40));
      await tester.pump();
      expect(_matrix(tester), Matrix4.identity());
    });

    testWidgets('初始态已就绪无交互：窗口尺寸变化时重新计算默认适配',
        (tester) async {
      final q = _imageQuestion('q13', _writePng('land13.png', 680, 480));
      await _openDialog(tester, q);
      await _awaitImageDecode(tester);
      expect(_badge(tester), 100);
      _expectPureScale(tester, 1.0);
      _setSurface(tester, const Size(500, 400));
      await tester.pump();
      await tester.pump();
      // 初始态下窗口变化重算默认适配：重算后仍为纯缩放矩阵、居中、
      // 无裁切，且纸面贴满新视口高（680×480 图在 500×400 下高约束；
      // 旧代码锁存一次、永不重算，平移矩阵仍按旧视口，纸面偏出视口）。
      final paperSize = tester.getSize(find.byType(QuestionSlice));
      final vpSize = tester.getSize(find.byType(InteractiveViewer));
      expect(paperSize.height, closeTo(vpSize.height, 3.0));
      expect(paperSize.width,
          closeTo(paperSize.height * 680 / 480, 3.0));
      final s0 = _expectedS0(tester);
      expect(_badge(tester), (s0 * 100).round());
      _expectPureScale(tester, s0);
      _expectCenteredNoClip(tester);
    });

    testWidgets('无图演示题：无图片可等，首帧即就绪、默认 100% 居中',
        (tester) async {
      await _openDialog(tester, _demoQuestion());
      await tester.pump();
      await tester.pump();
      expect(_expectedS0(tester), 1.0);
      expect(_badge(tester), 100);
      _expectPureScale(tester, 1.0);
      _expectCenteredNoClip(tester);
    });
  });
}
