// Batch 5 第五阶段 P2（收集 / 整理 / 详情）回归测试。
//
// 覆盖：SR-P2-19（恢复自动框的手动判断）、SR-P2-20（重框恢复自动框
// 只换 1 层框坐标）、SR-P2-25（无框警告收窄）、SR-P2-26（详情页新建
// 文件夹取消路径）、SR-P2-27（自定义错因与固定枚举同名）、SR-P2-28
//（newEntityId 防撞）、SR-P2-29（整理页修框切片传学科）、SR-P2-30
//（_donePages 文案）、SR-P2-31（切页/取消保存草稿 try）、SR-P2-32
//（删框后继续画框不崩）、SR-P2-35（队列弹窗日期补零）。
// B8-2 已删：SR-P2-18（切页检测门控）、SR-P2-21（鼠标左键点空白退出
// 内框模式）、SR-P2-23（叠加层按 parentBoxId 换算）、SR-P2-24（同区域
// 多框确定性优先级）——二层模型已移除。
// 补充转交：SR-P2-3（详情页重框事务失败删新切片）、SR-P2-22（收集页
// 确认失败清新切片与烘焙图）、SR-P2-36（组织/详情新建文件夹整科同名预检）。
// SR-P2-33（done 死分支）与 SR-P2-34（死代码删除）无行为可测，
// 见 B5-P2-COLLECT 报告。
//
// 不碰真实演示库：页图是 setUpAll 生成的临时 PNG；DB 一律不用。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/collect/collect_page.dart';
import 'package:quiz_master2/modules/detail/question_detail_page.dart';
import 'package:quiz_master2/modules/organize/organize_page.dart';
import 'package:quiz_master2/services/yolo_onnx_service.dart';
import 'package:quiz_master2/theme/app_theme.dart';

late final Directory _testTmp;
late final String _pagePngPath;

/// 最近一次编辑器确认返回的结果（harness 的按钮回调写入）。
BoxEditorResult? _capturedResult;

QuestionBox _box({
  required String id,
  int layer = 1,
  String type = 'question',
  double x = 0.1,
  double y = 0.1,
  double w = 0.5,
  double h = 0.3,
  int page = 1,
  String? parentBoxId,
  String? questionId,
  String? origin,
}) => QuestionBox(
  id: id,
  layer: layer,
  type: type,
  x: x,
  y: y,
  w: w,
  h: h,
  page: page,
  parentBoxId: parentBoxId,
  questionId: questionId,
  origin: origin ?? 'manual',
);

/// 桩检测：不跑真实模型，返回空框（不走 fallback，不落占位框）。
class _EmptyYolo extends YoloOnnxService {
  @override
  Future<DetectionResult> detectPage({
    required String imagePath,
    required int page,
  }) async => const DetectionResult(boxes: [], usedFallback: false);
}

/// 桩检测：记录每次调用的页码，返回固定框列表。
class _CountingYolo extends YoloOnnxService {
  _CountingYolo({this.boxes = const []});
  final List<QuestionBox> boxes;
  final List<int> calls = [];

  @override
  Future<DetectionResult> detectPage({
    required String imagePath,
    required int page,
  }) async {
    calls.add(page);
    return DetectionResult(boxes: boxes, usedFallback: false);
  }
}

/// 画布内的框标签（底部 hint 也含“题级框 N”，必须限定在画布内找）。
Finder _editorBoxLabel(String label) => find.descendant(
  of: find.byKey(const Key('box-editor-canvas')),
  matching: find.textContaining(label),
);

/// 画布内某标签所属的框手柄（GestureDetector，key 是 `editor-box-<id>`）。
Finder _editorBoxHandle(String label) => find.ancestor(
  of: _editorBoxLabel(label),
  matching: find.byWidgetPredicate(
    (w) =>
        w is GestureDetector &&
        w.key is ValueKey<String> &&
        (w.key as ValueKey<String>).value.startsWith('editor-box-'),
  ),
);

/// 打开修框编辑器的测试宿主：点“打开修框”按钮调 showBoxEditorDialog，
/// 确认结果写进 [_capturedResult]。
Future<void> _openEditorDialog(
  WidgetTester tester, {
  required int page,
  int pageCount = 1,
  required BoxEditorMode mode,
  Map<int, List<QuestionBox>> initialBoxesByPage = const {},
  List<QuestionBox> initialDetected = const [],
  String taskId = 'task-test',
  String? reworkQuestionId,
  List<QuestionBox> readOnlyBoxes = const [],
  YoloOnnxService? yoloService,
  Future<void> Function(BoxEditorResult draft)? onSaveDraft,
}) async {
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
                page: page,
                pageCount: pageCount,
                subjectName: '数学',
                taskId: taskId,
                mode: mode,
                initialBoxesByPage: initialBoxesByPage,
                initialDetected: initialDetected,
                reworkQuestionId: reworkQuestionId,
                readOnlyBoxes: readOnlyBoxes,
                yoloService: yoloService ?? _EmptyYolo(),
                onSaveDraft: onSaveDraft,
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
  // 确认按钮文案随模式变（FR-34 / D-87）：草稿模式随 1 层框总数变，
  // 1 个是“确认修框，去整理”，多个是“确认修框，拆成 N 个待整理任务”；
  // 重框模式固定是“确认重新框选”。只断言按钮在。
  expect(_confirmFinder(mode), findsOneWidget);
}

/// 确认按钮的查找器：重框模式是固定文案“确认重新框选”，草稿模式
/// 按“确认修框”前缀找（两档文案都以它开头）。
Finder _confirmFinder(BoxEditorMode mode) => mode == BoxEditorMode.rework
    ? find.text('确认重新框选')
    : find.textContaining('确认修框');

Future<void> _tapConfirm(WidgetTester tester, BoxEditorMode mode) async {
  await tester.tap(_confirmFinder(mode));
  await tester.pumpAndSettle();
  expect(_confirmFinder(mode), findsNothing);
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

/// 点按前先滚到可见（详情/整理页整页滚动，直接 tap 会落空）。
Future<void> _tapText(
  WidgetTester tester,
  String text, {
  bool first = false,
}) async {
  final finder = first ? find.text(text).first : find.text(text);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    _testTmp = await Directory.systemTemp.createTemp('qm2-b5-p2-collect');
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 560, 700),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    final img = await recorder.endRecording().toImage(560, 700);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    final file = File('${_testTmp.path}/page.png');
    await file.writeAsBytes(png!.buffer.asUint8List());
    _pagePngPath = file.path;
  });

  tearDownAll(() async {
    await _testTmp.delete(recursive: true);
  });

  group('SR-P2-28 newEntityId：毫秒 + 随机后缀防撞', () {
    test('快速连点 2000 次无重复，格式为 前缀-毫秒-8 位十六进制', () {
      final ids = {
        for (var i = 0; i < 2000; i++) newEntityId('folder'),
      };
      expect(ids.length, 2000);
      final pattern = RegExp(r'^folder-\d+-[0-9a-f]{8}$');
      expect(ids.every(pattern.hasMatch), isTrue);
      expect(
        {for (var i = 0; i < 200; i++) newEntityId('exam')}.length,
        200,
      );
    });
  });

  group('SR-P2-19 “恢复自动框”的手动判断', () {
    testWidgets('对照：纯 YOLO 的页不弹确认，直接替换', (tester) async {
      final yolo = _CountingYolo(
        boxes: [
          _box(id: 'yolo-2', x: 0.1, y: 0.1, w: 0.8, h: 0.3, origin: 'yolo'),
        ],
      );
      await _openEditorDialog(
        tester,
        page: 1,
        mode: BoxEditorMode.draft,
        initialDetected: [
          _box(id: 'yolo-1', x: 0.05, y: 0.05, w: 0.9, h: 0.4, origin: 'yolo'),
        ],
        yoloService: yolo,
      );
      await tester.tap(find.text('恢复自动框'));
      await tester.pumpAndSettle();
      expect(find.text('用自动框替换当前页的手动框？'), findsNothing);
      expect(yolo.calls, [1]);
      expect(find.text('确认修框，去整理'), findsOneWidget);
    });

    testWidgets('SR2-21：手画框在别页时，当前页纯 YOLO 不弹确认', (tester) async {
      // 第 2 页的手画题级框在别页；旧代码查全部页的手画框，
      // 在第 1 页点“恢复自动框”也会误弹确认（确认后却只替换当前页）。
      final yolo = _CountingYolo(
        boxes: [
          _box(id: 'yolo-2', x: 0.1, y: 0.1, w: 0.8, h: 0.3, origin: 'yolo'),
        ],
      );
      await _openEditorDialog(
        tester,
        page: 1,
        pageCount: 2,
        mode: BoxEditorMode.draft,
        initialBoxesByPage: {
          1: [
            _box(
              id: 'yolo-1',
              x: 0.05,
              y: 0.05,
              w: 0.9,
              h: 0.4,
              origin: 'yolo',
            ),
          ],
          2: [_box(id: 'b2', page: 2, x: 0.1, y: 0.1, w: 0.5, h: 0.3)],
        },
        yoloService: yolo,
      );
      await tester.tap(find.text('恢复自动框'));
      await tester.pumpAndSettle();
      expect(find.text('用自动框替换当前页的手动框？'), findsNothing);
      expect(yolo.calls, [1]);
      // 两页共 2 个 1 层框，确认按钮是“拆成 2 个待整理任务”。
      expect(find.text('确认修框，拆成 2 个待整理任务'), findsOneWidget);
    });
  });

  group('SR-P2-20 重框模式“恢复自动框”只换 1 层框坐标', () {
    testWidgets('恢复自动框只换题级框坐标', (tester) async {
      final yolo = _CountingYolo(
        boxes: [
          _box(id: 'yolo-1', x: 0.2, y: 0.2, w: 0.5, h: 0.4, origin: 'yolo'),
        ],
      );
      await _openEditorDialog(
        tester,
        page: 2,
        mode: BoxEditorMode.rework,
        initialBoxesByPage: {
          2: [_box(id: 'q1-box', page: 2, x: 0.1, y: 0.1, w: 0.5, h: 0.4)],
        },
        taskId: 'rework-q1',
        reworkQuestionId: 'q1',
        yoloService: yolo,
      );
      await tester.tap(find.text('恢复自动框'));
      await tester.pumpAndSettle();
      await _tapConfirm(tester, BoxEditorMode.rework);
      final result = _capturedResult!;
      // 1 层框换成检测框。
      final layer1 = result.boxesByPage[2]!.firstWhere((b) => b.layer == 1);
      expect(layer1.x, closeTo(0.2, 1e-9));
      expect(layer1.y, closeTo(0.2, 1e-9));
      expect(layer1.w, closeTo(0.5, 1e-9));
      expect(layer1.h, closeTo(0.4, 1e-9));
    });
    testWidgets('SR2-20：两道 1 层框恢复后各就其位', (tester) async {
      // reworkQuestionId 是题 id（'q1'），永不等于框 id（'b1'/'b2'）：
      // 旧代码只认第一道框，第二道框原地不动。
      final yolo = _CountingYolo(
        boxes: [
          _box(id: 'yolo-1', x: 0.1, y: 0.1, w: 0.4, h: 0.3, origin: 'yolo'),
          _box(id: 'yolo-2', x: 0.6, y: 0.1, w: 0.4, h: 0.3, origin: 'yolo'),
        ],
      );
      await _openEditorDialog(
        tester,
        page: 2,
        mode: BoxEditorMode.rework,
        initialBoxesByPage: {
          2: [
            _box(
              id: 'b1',
              page: 2,
              x: 0.05,
              y: 0.05,
              w: 0.4,
              h: 0.3,
              questionId: 'q1',
            ),
            _box(
              id: 'b2',
              page: 2,
              x: 0.55,
              y: 0.05,
              w: 0.4,
              h: 0.3,
              questionId: 'q1',
            ),
          ],
        },
        taskId: 'rework-q1',
        reworkQuestionId: 'q1',
        yoloService: yolo,
      );
      await tester.tap(find.text('恢复自动框'));
      await tester.pumpAndSettle();
      // 两道框都找到了对应的检测框，不弹“没找到对应的题”。
      expect(find.textContaining('没找到对应的题'), findsNothing);
      await _tapConfirm(tester, BoxEditorMode.rework);
      final result = _capturedResult!;
      final layer1 = result.boxesByPage[2]!.where((b) => b.layer == 1).toList();
      expect(layer1, hasLength(2));
      // 两道框各就其位（不是都挪到第一道检测框的位置上）。
      final first = layer1.firstWhere((b) => b.id == 'b1');
      expect(first.x, closeTo(0.1, 1e-9));
      expect(first.y, closeTo(0.1, 1e-9));
      final second = layer1.firstWhere((b) => b.id == 'b2');
      expect(second.x, closeTo(0.6, 1e-9));
      expect(second.y, closeTo(0.1, 1e-9));
    });
  });

  group('SR3-13 重框恢复不认邻题检测框', () {
    testWidgets('阈值 0.3：与目标框 IoU 0.23 的检测框不再认领，目标框不动',
        (tester) async {
      // 检测框与目标框 IoU ≈ 0.231（> 旧阈值 0.05、< 新阈值 0.3）：
      // 旧逻辑会把它认领、把目标框拽到 0.30 处；新逻辑不认领。
      final yolo = _CountingYolo(
        boxes: [
          _box(id: 'yolo-1', x: 0.30, y: 0.05, w: 0.4, h: 0.3, origin: 'yolo'),
        ],
      );
      await _openEditorDialog(
        tester,
        page: 2,
        mode: BoxEditorMode.rework,
        initialBoxesByPage: {
          2: [_box(id: 'b1', page: 2, x: 0.05, y: 0.05, w: 0.4, h: 0.3)],
        },
        taskId: 'rework-q1',
        reworkQuestionId: 'q1',
        yoloService: yolo,
      );
      await tester.tap(find.text('恢复自动框'));
      await tester.pumpAndSettle();
      expect(find.textContaining('没找到对应的检测框'), findsOneWidget);
      // SnackBar 默认 4 秒后消失：等它走完再点确认，否则会被盖住。
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await _tapConfirm(tester, BoxEditorMode.rework);
      final result = _capturedResult!;
      final layer1 = result.boxesByPage[2]!.firstWhere((b) => b.layer == 1);
      expect(layer1.x, closeTo(0.05, 1e-9));
      expect(layer1.y, closeTo(0.05, 1e-9));
      expect(tester.takeException(), isNull);
    });

    testWidgets('候选池过滤：中心落在邻题只读框内的检测框不参与认领',
        (tester) async {
      // 检测框与目标框 IoU ≈ 0.389（> 0.3，单看阈值会被认领），
      // 但它的中心 (0.47, 0.20) 落在邻题只读框（0.46–0.86）内——
      // 那是邻题的框，不在候选池里，目标框应原地不动。
      // 只读框与目标框留 0.01 缝隙（不重叠，确认不被拦下）。
      final yolo = _CountingYolo(
        boxes: [
          _box(id: 'yolo-1', x: 0.17, y: 0.05, w: 0.6, h: 0.3, origin: 'yolo'),
        ],
      );
      await _openEditorDialog(
        tester,
        page: 2,
        mode: BoxEditorMode.rework,
        initialBoxesByPage: {
          2: [_box(id: 'b1', page: 2, x: 0.05, y: 0.05, w: 0.4, h: 0.3)],
        },
        taskId: 'rework-q1',
        reworkQuestionId: 'q1',
        readOnlyBoxes: [
          _box(id: 'q2-box', page: 2, x: 0.46, y: 0.05, w: 0.4, h: 0.3,
              questionId: 'q2'),
        ],
        yoloService: yolo,
      );
      await tester.tap(find.text('恢复自动框'));
      await tester.pumpAndSettle();
      expect(find.textContaining('没找到对应的检测框'), findsOneWidget);
      // SnackBar 默认 4 秒后消失：等它走完再点确认，否则会被盖住。
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await _tapConfirm(tester, BoxEditorMode.rework);
      final result = _capturedResult!;
      final layer1 = result.boxesByPage[2]!.firstWhere((b) => b.layer == 1);
      expect(layer1.x, closeTo(0.05, 1e-9));
      expect(layer1.y, closeTo(0.05, 1e-9));
      expect(tester.takeException(), isNull);
    });
  });

  group('SR-P2-30 _donePages 只是本页装饰态：文案说清', () {
    testWidgets('打勾按钮与说明文案讲明只是本次打开的标记', (tester) async {
      await _openEditorDialog(
        tester,
        page: 1,
        pageCount: 2,
        mode: BoxEditorMode.draft,
        initialBoxesByPage: {
          1: [_box(id: 'b1')],
        },
      );
      expect(find.text('标记本页修完'), findsOneWidget);
      expect(find.textContaining('打勾只是本次打开的标记'), findsOneWidget);
      await tester.tap(find.text('标记本页修完'));
      await tester.pumpAndSettle();
      expect(find.text('已标记修完（点击取消）'), findsOneWidget);
      expect(find.text('第 1 页 ✓'), findsOneWidget);
    });
  });

  group('SR-P2-31 切页与取消保存草稿无 try', () {
    testWidgets('切页时保存抛错：提示、不崩、照常切页', (tester) async {
      await _openEditorDialog(
        tester,
        page: 1,
        pageCount: 2,
        mode: BoxEditorMode.draft,
        initialBoxesByPage: {
          1: [_box(id: 'b1')],
        },
        onSaveDraft: (_) async => throw StateError('disk full'),
      );
      await tester.tap(find.byKey(const Key('editor-thumb-2')));
      await tester.pumpAndSettle();
      expect(find.textContaining('草稿保存失败'), findsOneWidget);
      expect(find.textContaining('修框 · test.pdf 第2页'), findsOneWidget);
    });

    testWidgets('取消时保存抛错：提示后仍退出，不把用户困住', (tester) async {
      await _openEditorDialog(
        tester,
        page: 1,
        mode: BoxEditorMode.draft,
        initialBoxesByPage: {
          1: [_box(id: 'b1')],
        },
        onSaveDraft: (_) async => throw StateError('disk full'),
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('确认修框，去整理'), findsNothing);
      expect(_capturedResult, isNull);
      expect(find.textContaining('草稿保存失败'), findsOneWidget);
    });
  });

  group('SR-P2-32 删框后继续画框不崩', () {
    testWidgets('删框后右键拖画新框不崩，新框直接成题级框', (tester) async {
      await _openEditorDialog(
        tester,
        page: 1,
        mode: BoxEditorMode.draft,
        initialBoxesByPage: {
          1: [_box(id: 'b1', x: 0.1, y: 0.1, w: 0.5, h: 0.3)],
        },
      );
      // 删选中的框，再右键拖画一个新框。
      final box = _editorBoxHandle('题级框 1');
      await tester.ensureVisible(box);
      await tester.pumpAndSettle();
      await tester.tap(box);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除选中框'));
      await tester.pumpAndSettle();
      final canvasRect = tester.getRect(
        find.byKey(const Key('box-editor-canvas')),
      );
      await _dragMouseRight(
        tester,
        canvasRect.center,
        const Offset(100, 60),
      );
      // 新框直接落下成题级框，不弹选类型菜单。
      expect(find.text('这个框是？'), findsNothing);
      expect(_editorBoxLabel('题级框 1'), findsOneWidget);
      await _tapConfirm(tester, BoxEditorMode.draft);
      final result = _capturedResult!;
      expect(result.boxesByPage[1]!.where((b) => b.layer == 1), hasLength(1));
    });
  });

  // ---------- 收集页 SR-P2-25 ----------
  group('SR-P2-25 无框警告只对打开过或已有草稿框的任务显示', () {
    testWidgets('新导入任务不警告；修框中任务警告；只有旧草稿框的待框选任务也警告',
        (tester) async {
      final repo = _CollectFakeRepo([
        CollectTask(
          id: 't-new',
          name: 'new.pdf · 第1页 · 第1题',
          fileName: 'new.pdf',
          subjectId: 'math',
          status: CollectStatus.needBox,
        ),
        CollectTask(
          id: 't-boxing',
          name: 'boxing.pdf · 第1页 · 第1题',
          fileName: 'boxing.pdf',
          subjectId: 'math',
          status: CollectStatus.boxing,
        ),
        CollectTask(
          id: 't-draft',
          name: 'draft.pdf · 第1页 · 第1题',
          fileName: 'draft.pdf',
          subjectId: 'math',
          status: CollectStatus.needBox,
        ),
      ]);
      // 只有旧草稿框（历史层级行）：按“任意已存框都算”口径，
      // 仍算“已有草稿”，警告范围不收窄。
      repo.draftBoxes['t-draft'] = [
        _box(
          id: 'draft-stem',
          layer: 2,
          type: 'stem',
          parentBoxId: 'gone',
        ),
      ];
      await _pumpCollect(tester, repo: repo);
      expect(find.text('new.pdf · 第1页 · 第1题'), findsOneWidget);
      expect(find.text('boxing.pdf · 第1页 · 第1题'), findsOneWidget);
      expect(find.text('draft.pdf · 第1页 · 第1题'), findsOneWidget);
      // 修前：三行都警告（findsNWidgets(3)）；修后：只有打开过
      // （boxing）与有草稿（t-draft）的两行警告，新导入的不警告。
      expect(find.text('这张图还没有框'), findsNWidgets(2));
    });
  });

  // ---------- 详情页 SR-P2-26 / SR-P2-27 ----------
  group('SR-P2-26 详情页新建文件夹：取消路径真正取消', () {
    Future<void> newFolderFlow(
      WidgetTester tester,
      _DetailFakeRepo repo,
      String name,
    ) async {
      await _tapText(tester, '＋ 新建文件夹');
      expect(find.text('新建文件夹'), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        name,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('确定'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('放在哪里'), findsOneWidget);
    }

    testWidgets('点“取消”与点框外关闭都不建文件夹；点“顶层”才建', (tester) async {
      final repo = _detailRepo();
      await _pumpDetail(tester, repo: repo);
      await _tapText(tester, '编辑');
      expect(repo.folderList.length, 1);
      // 点“取消”。
      await newFolderFlow(tester, repo, '新文件夹1');
      await tester.tap(
        find.descendant(
          of: find.byType(SimpleDialog),
          matching: find.text('取消'),
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.folderList.length, 1);
      expect(find.text('放在哪里'), findsNothing);
      // 点框外关闭（SimpleDialog 默认 barrierDismissible）。
      await newFolderFlow(tester, repo, '新文件夹2');
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(repo.folderList.length, 1);
      expect(find.text('放在哪里'), findsNothing);
      // 点“顶层”：真正建一个顶层文件夹。
      await newFolderFlow(tester, repo, '新文件夹3');
      await tester.tap(find.text('顶层'));
      await tester.pumpAndSettle();
      expect(repo.folderList.length, 2);
      expect(repo.folderList.last.name, '新文件夹3');
      expect(repo.folderList.last.parentId, isNull);
    });
  });

  group('SR-P2-27 详情页自定义错因与固定枚举同名', () {
    testWidgets('旧数据同名自定义读入即合并进固定项，保存不丢、不重复',
        (tester) async {
      final repo = _detailRepo(
        questions: [
          _dtq(
            'q1',
            '函数极限',
            errorTypes: const [],
            customErrorTypes: const ['其他'],
          ),
        ],
      );
      await _pumpDetail(tester, repo: repo);
      await _tapText(tester, '编辑');
      // 读入已合并：保存后固定项里有“其他”，自定义里没有，allCauses 不重复。
      await _tapText(tester, '保存', first: true);
      final saved = repo.saved.last;
      expect(saved.errorTypes, contains('其他'));
      expect(saved.customErrorTypes, isNot(contains('其他')));
      expect(saved.allCauses.where((c) => c == '其他'), hasLength(1));
    });

    testWidgets('新建自定义输入固定名时直接选中固定项并提示', (tester) async {
      final repo = _detailRepo();
      await _pumpDetail(tester, repo: repo);
      await _tapText(tester, '编辑');
      await _tapText(tester, '＋ 新建错误类型');
      expect(find.text('自定义错误类型'), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '其他',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('确定'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('“其他”是固定错误类型，已帮你选中'), findsOneWidget);
      await _tapText(tester, '保存', first: true);
      final saved = repo.saved.last;
      expect(saved.errorTypes, containsAll(['概念不清', '其他']));
      expect(saved.customErrorTypes, isEmpty);
    });

    test('SR2-23：allCauses 保序去重，旧数据同名自定义只显示一次', () {
      final q = _dtq(
        'q-old',
        '旧题',
        errorTypes: const ['计算错误', '其他'],
        customErrorTypes: const ['其他', '看错单位'],
      );
      expect(q.allCauses, ['计算错误', '其他', '看错单位']);
    });
  });

  // ---------- 整理页 SR-P2-27 / SR-P2-29 / SR-P2-35 ----------
  group('SR-P2-27 整理页自定义错因与固定枚举同名', () {
    testWidgets('输入固定名时直接选中固定项，保存合并、不重复', (tester) async {
      final repo = _organizeRepo();
      await _pumpOrganize(tester, repo: repo);
      // 分类补充段默认折叠，先展开。
      await tester.ensureVisible(find.text('分类补充（可选）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('分类补充（可选）'));
      await tester.pumpAndSettle();
      final field = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.hintText == '自定义错误类型…（枚举之外的情况）',
      );
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      await tester.enterText(field, '其他');
      await tester.pumpAndSettle();
      await _tapText(tester, '添加并选上');
      expect(find.text('“其他”是固定错误类型，已帮你选中'), findsOneWidget);
      // 没有“其他（自定义）”芯片出现。
      expect(find.text('其他（自定义）'), findsNothing);
      await _tapText(tester, '保存草稿');
      final saved = repo.saved.last;
      expect(saved.errorTypes, contains('其他'));
      expect(saved.customErrorTypes, isNot(contains('其他')));
      expect(saved.allCauses.where((c) => c == '其他'), hasLength(1));
    });
  });

  group('SR-P2-29 整理页修框切片整题卡传学科对象', () {
    testWidgets('新学科缺图占位显示新学科名，不回退成数学', (tester) async {
      final chem = Subject(
        id: 'chem',
        name: '化学',
        color: const Color(0xFF7C3AED),
        icon: '化',
      );
      final repo = _OrganizeFakeRepo(
        questions: [
          Question(
            id: 'q-chem',
            title: '化学题',
            subjectId: 'chem',
            sliceKind: 'limit',
            sliceText: '',
            // 切片路径有值但文件缺失 → 走缺图占位，学科取自传入的 subject。
            slicePath: 'slices/missing.png',
            createdAt: DateTime(2026, 11, 8),
          ),
        ],
        folderList: const [
          Folder(id: 'fc', name: '试卷', subjectId: 'chem'),
        ],
        subjectsValue: [...Subject.all, chem],
      );
      await _pumpOrganize(tester, repo: repo);
      // 整题卡出现两处：左栏大图（_paperImage）与修框切片段，两处都传了
      // 学科对象；修前切片段那处回退成数学，会是化学 ×1 + 数学 ×1。
      expect(find.text('化学 · 极限题'), findsNWidgets(2));
      expect(find.text('数学 · 极限题'), findsNothing);
    });
  });

  group('SR-P2-35 队列弹窗与父页共用日期文本（补零）', () {
    testWidgets('队列详情行日期零补齐：2026-11-08 不是 2026-11-8', (tester) async {
      await _pumpOrganize(tester, repo: _organizeRepo());
      await tester.tap(find.text('队列'));
      await tester.pumpAndSettle();
      expect(find.text('待整理队列 · 3 道'), findsOneWidget);
      final popup = find.byKey(const Key('organize-queue-popup'));
      expect(
        find.descendant(
          of: popup,
          matching: find.textContaining('2026-11-08'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: popup,
          matching: find.textContaining('2026-11-8'),
        ),
        findsNothing,
      );
    });
  });

  // ---------- SR-P2-3 / SR-P2-22 / SR-P2-36（补充转交） ----------
  group('SR-P2-3 详情页重框事务失败不留孤儿切片', () {
    testWidgets('事务失败：新切片被删、提示失败、框与题不动', (tester) async {
      // 切片写盘走 testDataDirectory；页图放进临时数据目录。
      // 注意：testWidgets 体是 FakeAsync 区，异步文件 IO 的完成事件
      // 等不到——文件准备必须用同步 IO（setUpAll 里才可用异步 IO）。
      addTearDown(() => AppDatabase.testDataDirectory = null);
      AppDatabase.testDataDirectory = _testTmp.path;
      final pageDir = Directory('${_testTmp.path}/imports/rework-task');
      pageDir.createSync(recursive: true);
      File(_pagePngPath).copySync('${pageDir.path}/page.png');
      final repo = _detailRepo(
        questions: [
          _dtq('q1', '函数极限', errorTypes: const ['概念不清']).copyWith(
            pageImagePath: 'imports/rework-task/page.png',
            sourcePath: 'imports/rework-task/page.png',
            slicePath: 'slices/q1.png',
            sliceWidth: 200,
            sliceHeight: 100,
          ),
        ],
      );
      repo.pageBoxes = [
        QuestionBox(
          id: 'q1-box',
          layer: 1,
          type: 'question',
          x: 0.06,
          y: 0.05,
          w: 0.88,
          h: 0.4,
          page: 1,
          questionId: 'q1',
        ),
      ];
      repo.replaceShouldThrow = true;
      await _pumpDetail(tester, repo: repo);
      await _tapText(tester, '题目信息');
      await _tapText(tester, '重新框选这道题');
      expect(find.textContaining('修框 ·'), findsOneWidget);
      // 真实裁剪 + 写盘须在 runAsync 内反复 pump 推进。
      await tester.runAsync(() async {
        // 详情页开的是重框模式（FR-34 / D-87）：确认按钮是“确认重新框选”。
        await tester.tap(find.text('确认重新框选'));
        for (var i = 0; i < 20; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        await tester.pumpAndSettle();
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('修框 ·'), findsNothing);
      expect(repo.replaceCalled, isTrue);
      expect(find.text('重新框选失败：保存失败，请重试'), findsOneWidget);
      // 刚写盘的新切片已删干净（未修前 slices/q1.png 不存在）。
      expect(
        File('${_testTmp.path}/slices/q1.png').existsSync(),
        isFalse,
      );
      // 框与题都没动：没有保存过题。
      expect(repo.saved.where((q) => q.id == 'q1'), isEmpty);
    });
  });

  group('SR-P2-22 收集页确认失败不留孤儿文件', () {
    /// 两页 PDF 任务：第 1 页旋转 90°（会写烘焙图），两页各 1 个草稿框。
    /// [corruptPage2] 为真时第 2 页图是损坏字节（裁剪抛错）；
    /// 为假时两页都正常，失败由事务桩抛。
    Future<_CollectFakeRepo> pumpPdf2(
      WidgetTester tester, {
      required bool corruptPage2,
      required bool txnShouldThrow,
      // SR2-22：为真时第 2 页不给草稿框——确认后第 2 页留在保留任务里。
      bool leavePage2Unboxed = false,
    }) async {
      addTearDown(() => AppDatabase.testDataDirectory = null);
      AppDatabase.testDataDirectory = _testTmp.path;
      final pagesDir = Directory('${_testTmp.path}/imports/t-pdf2/pages');
      // 同上：testWidgets 体内文件准备用同步 IO（异步 IO 会挂起）。
      pagesDir.createSync(recursive: true);
      File(_pagePngPath).copySync('${pagesDir.path}/page-001.png');
      if (corruptPage2) {
        File(
          '${pagesDir.path}/page-002.png',
        ).writeAsBytesSync(const [0, 1, 2, 3, 4, 5]);
      } else {
        File(_pagePngPath).copySync('${pagesDir.path}/page-002.png');
      }
      final repo = _CollectFakeRepo([
        CollectTask(
          id: 't-pdf2',
          name: '多页卷.pdf',
          fileName: '多页卷.pdf',
          subjectId: 'math',
          status: CollectStatus.needBox,
          progress: 100,
          pageCount: 2,
          page: 1,
          createdAt: DateTime(2026, 11, 8),
          sourcePath: 'imports/t-pdf2/source.pdf',
          pageRotations: const {1: 90},
        ),
      ]);
      repo.draftBoxes['t-pdf2'] = [
        _box(id: 'b1', page: 1),
        if (!leavePage2Unboxed) _box(id: 'b2', page: 2),
      ];
      repo.confirmSplitShouldThrow = txnShouldThrow;
      await _pumpCollect(tester, repo: repo);
      await tester.tap(find.text('修框'));
      await tester.pumpAndSettle();
      expect(find.textContaining('修框 ·'), findsOneWidget);
      // 2 个题级框 → 确认按钮是“拆成 2 个待整理任务”；只剩 1 个框时
      // 是“确认修框，去整理”。未框页确认框出现时点“确认拆题”。
      final confirmLabel = leavePage2Unboxed
          ? '确认修框，去整理'
          : '确认修框，拆成 2 个待整理任务';
      // _confirmSplit 的图片 IO（旋转烘焙 + 裁剪）是真异步、偏慢：
      // 轮询等失败提示条出现，最多 8 秒；不要定死循环次数（太短则
      // 流程还没跑完、太长则提示条 4 秒过期）。成功提示条出现也可停。
      await tester.runAsync(() async {
        await tester.tap(find.text(confirmLabel));
        // 未框页确认框（仅 leavePage2Unboxed 时出现）：编辑器先退场，
        // _confirmSplit 再弹框，轮询等它出现再点“确认拆题”。
        for (var i = 0; i < 20; i++) {
          await tester.pump();
          if (find.text('确认拆题').evaluate().isNotEmpty) {
            await tester.tap(find.text('确认拆题'));
            break;
          }
          if (find.textContaining('拆题失败').evaluate().isNotEmpty) break;
          if (find.textContaining('已生成').evaluate().isNotEmpty) break;
        }
        for (var i = 0; i < 40; i++) {
          await tester.pump();
          if (find.textContaining('拆题失败').evaluate().isNotEmpty) break;
          if (find.textContaining('已生成').evaluate().isNotEmpty) break;
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        await tester.pumpAndSettle();
      });
      await tester.pumpAndSettle();
      return repo;
    }

    /// 失败后应清理干净：新切片与烘焙图都不留，原任务页图还在。
    void expectCleanedUp() {
      final slicesDir = Directory('${_testTmp.path}/slices');
      expect(
        !slicesDir.existsSync() || slicesDir.listSync().isEmpty,
        isTrue,
      );
      expect(
        File('${_testTmp.path}/imports/t-pdf2/pages/page-1-r90.png')
            .existsSync(),
        isFalse,
      );
      expect(
        File('${_testTmp.path}/imports/t-pdf2/pages/page-001.png')
            .existsSync(),
        isTrue,
      );
      expect(
        File('${_testTmp.path}/imports/t-pdf2/pages/page-002.png')
            .existsSync(),
        isTrue,
      );
    }

    testWidgets('第 2 页裁剪失败：第 1 页已写的切片与烘焙图被清掉',
        (tester) async {
      final repo = await pumpPdf2(
        tester,
        corruptPage2: true,
        txnShouldThrow: false,
      );
      // 诊断：编辑器应已关闭（确认走完了）；confirmSplit 不应被调用。
      expect(
        find.textContaining('修框 ·'),
        findsNothing,
        reason: 'editor still open after confirm',
      );
      expect(repo.confirmSplitCalled, isFalse);
      // 先验清理（catch 里的删文件跑没跑），再验提示条。
      expectCleanedUp();
      expect(find.textContaining('拆题失败：切片写不进去'), findsOneWidget);
      // 任务还在待框选，可重试。
      expect(repo.tasks.where((t) => t.id == 't-pdf2'), hasLength(1));
      expect(find.text('多页卷.pdf'), findsOneWidget);
    });

    testWidgets('事务失败：第 1 页已写的切片与烘焙图同样被清掉',
        (tester) async {
      final repo = await pumpPdf2(
        tester,
        corruptPage2: false,
        txnShouldThrow: true,
      );
      expect(find.textContaining('拆题失败：保存失败'), findsOneWidget);
      expect(repo.confirmSplitCalled, isTrue);
      expectCleanedUp();
      expect(repo.tasks.where((t) => t.id == 't-pdf2'), hasLength(1));
    });

    testWidgets('成功确认：拆出的题与拆分任务 id 带 6 位随机段（SR-P2-60 同款）',
        (tester) async {
      final repo = await pumpPdf2(
        tester,
        corruptPage2: false,
        txnShouldThrow: false,
      );
      expect(repo.confirmSplitCalled, isTrue);
      final questions = repo.confirmedQuestions!;
      final splitTasks = repo.confirmedSplitTasks!;
      expect(questions, hasLength(2));
      expect(splitTasks, hasLength(2));
      // import-<毫秒13位>-<随机6位>-<页>-<序号>；task- 同款。
      final qPattern = RegExp(r'^import-\d{13}-\d{6}-\d+-\d+$');
      final tPattern = RegExp(r'^task-\d{13}-\d{6}-\d+-\d+$');
      for (var i = 0; i < 2; i++) {
        expect(questions[i].id, matches(qPattern));
        expect(splitTasks[i].id, matches(tPattern));
        expect(splitTasks[i].questionId, questions[i].id);
      }
      // 同一次确认内随机段相同、两次确认的随机段大概率不同（格式即防线）。
      final rnds = questions
          .map((q) => q.id.split('-')[2])
          .toSet();
      expect(rnds, hasLength(1));
    });

    testWidgets('SR2-22：保留任务重建带 boxing 状态，删拆分任务行后警告仍在',
        (tester) async {
      final repo = await pumpPdf2(
        tester,
        corruptPage2: false,
        txnShouldThrow: false,
        leavePage2Unboxed: true,
      );
      expect(repo.confirmSplitCalled, isTrue);
      // 保留任务重建时带上 boxing 状态（不是 needBox），且只有 1 道题被拆出。
      final retained = repo.confirmedRetainedTask!;
      expect(retained.id, 't-pdf2');
      expect(retained.status, CollectStatus.boxing);
      expect(repo.confirmedQuestions, hasLength(1));
      expect(repo.confirmedSplitTasks, hasLength(1));
      // 删掉全部同源拆分任务行（模拟用户在待整理行上点删除），重进列表：
      // _hasSplitSibling 是派生信号、此时已为空，警告只能靠保留任务
      // 自身的 boxing 状态 + 未框页草稿（本例未框页无草稿）。
      // 注意：删拆分任务行也带走了第 1 页的覆盖（那页的题随任务删，
      // 见收集任务删除语义），重进后未框页是 [1, 2]、全页未框，
      // 文案是“这份文件还有 2 页没有框”而不是“还有 1 页没有框：第 2 页”。
      // SR2-22 的要点仍成立：警告还在，靠的是保留任务自身的 boxing
      // 状态，不是派生信号。
      repo.tasks.removeWhere((t) => t.status == CollectStatus.pendingOrganize);
      await _pumpCollect(tester, repo: repo);
      expect(find.text('多页卷.pdf'), findsOneWidget);
      expect(find.text('这份文件还有 2 页没有框'), findsOneWidget);
    });

    testWidgets('SR2-62：同一用例内连续确认两次，两次的随机段不同',
        (tester) async {
      // 两次确认都在同一用例内跑（各走一次完整确认流程）；SR2-62 的
      // 同毫秒撞戳由 _lastSplitStamp 重抽兜底，这里断言可观测的性质：
      // 两次确认的随机段不同、题 id 全集无交集。
      final repo1 = await pumpPdf2(
        tester,
        corruptPage2: false,
        txnShouldThrow: false,
      );
      // 两次确认之间清掉上一次的“已生成”提示条：它是确认流程在
      // runAsync（真实时区）里弹的，假时间 pump 推不动它的 4 秒定时；
      // 不清掉，第二次确认的轮询会在陈旧提示条上立刻跳出、确认还没跑完
      // 就返回，repo2.confirmedQuestions 还是 null。
      tester
          .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
          .clearSnackBars();
      await tester.pumpAndSettle();
      final repo2 = await pumpPdf2(
        tester,
        corruptPage2: false,
        txnShouldThrow: false,
      );
      final rnd1 = repo1.confirmedQuestions!.first.id.split('-')[2];
      final rnd2 = repo2.confirmedQuestions!.first.id.split('-')[2];
      expect(rnd1, isNot(rnd2));
      final ids1 = repo1.confirmedQuestions!.map((q) => q.id).toSet();
      final ids2 = repo2.confirmedQuestions!.map((q) => q.id).toSet();
      expect(ids1.intersection(ids2), isEmpty);
    });
  });

  group('SR-P2-36 组织/详情新建文件夹整科同名预检', () {
    testWidgets('整理页：顶层已有同名，跨层同名也拦', (tester) async {
      final repo = _organizeRepo();
      await _pumpOrganize(tester, repo: repo);
      // 数学已有顶层“试卷”（f1）；再建同名顶层 → 提示，不建。
      await _tapText(tester, '添加新文件夹…');
      await tester.enterText(
        find.byWidgetPredicate(
          (w) =>
              w is TextField && w.decoration?.hintText == '文件夹名，如：错题精选',
        ),
        '试卷',
      );
      await _tapText(tester, '添加');
      expect(find.text('已经有了'), findsOneWidget);
      expect(repo.folderList.where((f) => f.name == '试卷'), hasLength(2));
      expect(repo.savedFolders, isEmpty);
      // 跨层：数学只有子文件夹叫“错题精选”时，建同名顶层同样拦。
      // （folderList 字段可整体替换；_organizeRepo 传的是 const 列表，
      // 不能原地 clear/add。）
      repo.folderList = const [
        Folder(id: 'f9', name: '错题精选', subjectId: 'math', parentId: 'f1'),
      ];
      await _pumpOrganize(tester, repo: repo);
      await _tapText(tester, '添加新文件夹…');
      await tester.enterText(
        find.byWidgetPredicate(
          (w) =>
              w is TextField && w.decoration?.hintText == '文件夹名，如：错题精选',
        ),
        '错题精选',
      );
      await _tapText(tester, '添加');
      expect(find.text('已经有了'), findsOneWidget);
      expect(repo.savedFolders, isEmpty);
    });

    testWidgets('详情页：已有同名，选顶层也拦', (tester) async {
      final repo = _detailRepo();
      await _pumpDetail(tester, repo: repo);
      await _tapText(tester, '编辑');
      await _tapText(tester, '＋ 新建文件夹');
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '试卷',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('确定'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('顶层'));
      await tester.pumpAndSettle();
      expect(find.text('已经有了'), findsOneWidget);
      expect(repo.folderList, hasLength(1));
    });
  });
}

/// ---------- 收集页测试桩 ----------

class _CollectFakeRepo extends QuestionRepository {
  _CollectFakeRepo(this.tasks) : super(AppDatabase.instance);

  List<CollectTask> tasks;
  final Map<String, List<QuestionBox>> draftBoxes = {};
  bool confirmSplitCalled = false;
  bool confirmSplitShouldThrow = false;
  List<Question>? confirmedQuestions;
  List<CollectTask>? confirmedSplitTasks;
  /// SR2-22：记录保留任务（断言其重建状态用）。
  CollectTask? confirmedRetainedTask;

  @override
  Future<List<CollectTask>> collectTasks() async => List.of(tasks);

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<List<QuestionBox>> boxesForTask(String taskId) async =>
      List.of(draftBoxes[taskId] ?? const []);

  @override
  Future<void> saveCollectTask(CollectTask t) async {}

  @override
  Future<void> saveDraftBoxes({
    required String taskId,
    required Map<int, List<QuestionBox>> boxesByPage,
    required Map<int, int> rotations,
  }) async {}

  @override
  Future<void> confirmSplit({
    required CollectTask originalTask,
    required List<Question> questions,
    required List<CollectTask> splitTasks,
    required Map<String, List<QuestionBox>> boxesByQuestionId,
    CollectTask? retainedTask,
    Map<int, List<QuestionBox>> retainedBoxesByPage = const {},
  }) async {
    confirmSplitCalled = true;
    confirmedQuestions = List.of(questions);
    confirmedSplitTasks = List.of(splitTasks);
    confirmedRetainedTask = retainedTask;
    if (confirmSplitShouldThrow) throw StateError('事务失败（测试桩）');
    // 模拟真实 confirmSplit 的任务替换与草稿清理：原任务删掉，保留
    // 任务（若有）与拆分任务入表；已确认页的草稿框随原任务删，只留
    // 保留任务未框页的草稿——SR2-22 的警告判断要靠它之外的信号。
    tasks.removeWhere((t) => t.id == originalTask.id);
    if (retainedTask != null) tasks.add(retainedTask);
    tasks.addAll(splitTasks);
    draftBoxes[originalTask.id] = [
      for (final e in retainedBoxesByPage.entries) ...e.value,
    ];
  }

  @override
  Future<void> saveRecentTask({
    required String kind,
    required String subjectId,
    required String title,
  }) async {}

  @override
  Future<void> deleteCollectTask(String id) async {}
}

Future<void> _pumpCollect(WidgetTester tester, {required _CollectFakeRepo repo}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      // 每次 pump 都挂新 State：同一用例内两次 pump 若复用旧 State，
      // 旧 State 的任务列表还停在上一次的 repo 上（CollectPage 只在
      // initState 读库，没有 didUpdateWidget）；SR2-62 同一用例内
      // 两次确认、各用一个新 FakeRepo，必须每次都从传入的 repo 重读。
      home: Scaffold(body: CollectPage(key: UniqueKey(), repo: repo, onOpenOrganize: () {})),
    ),
  );
  await tester.pumpAndSettle();
}

/// ---------- 详情页测试桩 ----------

Question _dtq(
  String id,
  String title, {
  String subjectId = 'math',
  List<String> folderIds = const [],
  List<String> errorTypes = const [],
  List<String> customErrorTypes = const [],
}) => Question(
  id: id,
  title: title,
  subjectId: subjectId,
  folderIds: folderIds,
  errorTypes: errorTypes,
  customErrorTypes: customErrorTypes,
  sliceKind: 'limit',
  sliceText: '题：求极限',
  createdAt: DateTime(2026, 11, 8),
  isOrganized: true,
);

class _DetailFakeRepo extends QuestionRepository {
  _DetailFakeRepo({
    required this.questions,
    required List<Folder> folderList,
  }) : folderList = List.of(folderList),
       super(AppDatabase.instance);

  List<Question> questions;
  List<Folder> folderList;
  final List<Question> saved = [];
  // SR-P2-3：重框同页框（boxesForPageImage 的桩数据）与事务桩。
  List<QuestionBox> pageBoxes = [];
  bool replaceCalled = false;
  bool replaceShouldThrow = false;

  @override
  Future<Question?> questionById(String id) async =>
      questions.where((q) => q.id == id).firstOrNull;

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  // FR-09（D-88）：DetailNotifier.load() 多读 repo.settings()；FakeRepo
  // 不覆写会落到基类读真实 Drift 库，测试 fake async 里永不完成，
  // loading 一直 true、转圈拖死 pumpAndSettle。
  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  @override
  Future<List<Folder>> folders({String? subjectId}) async => subjectId == null
      ? List.of(folderList)
      : folderList.where((f) => f.subjectId == subjectId).toList();

  /// SR-P2-36：整科同名预检的内存版（与 upsertFolder 的把关同语义）。
  @override
  Future<bool> folderNameExistsInSubject(
    String subjectId,
    String name, {
    String? excludeId,
  }) async =>
      folderList.any(
        (f) =>
            f.subjectId == subjectId &&
            f.name == name &&
            f.id != excludeId,
      );

  @override
  Future<List<QuestionBox>> boxesForPageImage(String pageImagePath) async =>
      List.of(pageBoxes);

  @override
  Future<void> replaceQuestionBoxesAndSlice(
    String questionId,
    List<QuestionBox> boxes, {
    required String slicePath,
    required int sliceWidth,
    required int sliceHeight,
  }) async {
    replaceCalled = true;
    if (replaceShouldThrow) throw StateError('事务失败（测试桩）');
  }

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<List<String>> tags() async => const [];

  @override
  Future<List<CauseRecord>> causeRecordsFor(String questionId) async =>
      const [];

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
    String questionId,
  ) async => const [];

  @override
  Future<void> save(Question question) async {
    saved.add(question);
    final i = questions.indexWhere((x) => x.id == question.id);
    if (i >= 0) {
      questions[i] = question;
    } else {
      questions.add(question);
    }
  }

  @override
  Future<void> syncCauseRecords(Question q) async {}

  @override
  Future<void> saveFolder(Folder folder) async {
    final i = folderList.indexWhere((x) => x.id == folder.id);
    if (i >= 0) {
      folderList[i] = folder;
    } else {
      folderList.add(folder);
    }
  }

  @override
  Future<void> addKnowledgePoint(KnowledgePoint kp) async {}

  @override
  Future<void> addExam(Exam e) async {}

  @override
  Future<void> addTag(String name) async {}

  @override
  Future<bool> setReviewJoined(Question q, bool joined) async => false;

  @override
  Future<void> toggleFavorite(Question q) async {}

  @override
  Future<void> archive(Question q, {bool archived = true}) async {}

  @override
  Future<void> delete(Question question) async {}

  /// 十二批功能 4（D-91）：记一次查看的桩（不碰真实库；不覆盖会落到
  /// 基类读真实 Drift 库，fake async 里永不完成，见 D-88）。
  @override
  Future<void> recordQuestionViewed(String questionId) async {}
}

_DetailFakeRepo _detailRepo({
  List<Question>? questions,
  List<Folder>? folders,
}) => _DetailFakeRepo(
  questions: questions ?? [_dtq('q1', '函数极限', errorTypes: const ['概念不清'])],
  folderList:
      folders ??
      const [Folder(id: 'f1', name: '试卷', subjectId: 'math')],
);

Future<void> _pumpDetail(WidgetTester tester, {required _DetailFakeRepo repo}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: QuestionDetailPage(
          key: UniqueKey(),
          repo: repo,
          questionId: 'q1',
          orderIds: const ['q1'],
          sourceLabel: '错题本',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// ---------- 整理页测试桩 ----------

Question _oq(
  String id,
  String title, {
  String subjectId = 'math',
  String sliceKind = 'limit',
  String sliceText = '题：lim(x→0) sin 3x / x 的值是（　）',
  List<String> folderIds = const [],
  DateTime? createdAt,
}) => Question(
  id: id,
  title: title,
  subjectId: subjectId,
  folderIds: folderIds,
  sliceKind: sliceKind,
  sliceText: sliceText,
  createdAt: createdAt ?? DateTime(2026, 11, 8),
);

class _OrganizeFakeRepo extends QuestionRepository {
  _OrganizeFakeRepo({
    required this.questions,
    required this.folderList,
    this.tagList = const [],
    List<Subject>? subjectsValue,
  }) : subjectsValue = subjectsValue ?? Subject.all,
       super(AppDatabase.instance);

  List<Question> questions;
  List<Folder> folderList;
  final List<Exam> examList = [];
  final List<KnowledgePoint> kpList = const [];
  List<String> tagList;
  List<Subject> subjectsValue;
  final List<Question> saved = [];
  final List<Folder> savedFolders = [];

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);

  @override
  Future<List<Folder>> folders({String? subjectId}) async => subjectId == null
      ? List.of(folderList)
      : folderList.where((f) => f.subjectId == subjectId).toList();

  @override
  Future<List<Exam>> exams() async => List.of(examList);

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => List.of(kpList);

  @override
  Future<List<String>> tags() async => List.of(tagList);

  @override
  Future<void> save(Question question) async {
    saved.add(question);
    final i = questions.indexWhere((x) => x.id == question.id);
    if (i >= 0) {
      questions[i] = question;
    } else {
      questions.add(question);
    }
  }

  @override
  Future<void> delete(Question question) async {
    questions.removeWhere((x) => x.id == question.id);
  }

  @override
  Future<void> saveFolder(Folder folder) async {
    savedFolders.add(folder);
    folderList.add(folder);
  }

  /// SR-P2-36：整科同名预检的内存版（与 upsertFolder 的把关同语义）。
  @override
  Future<bool> folderNameExistsInSubject(
    String subjectId,
    String name, {
    String? excludeId,
  }) async =>
      folderList.any(
        (f) =>
            f.subjectId == subjectId &&
            f.name == name &&
            f.id != excludeId,
      );

  @override
  Future<void> addExam(Exam exam) async {
    examList.add(exam);
  }

  @override
  Future<void> addTag(String name) async {
    if (!tagList.contains(name)) tagList.add(name);
  }

  @override
  Future<void> syncCauseRecords(Question question) async {}

  @override
  Future<void> saveRecentTask({
    required String kind,
    required String subjectId,
    required String title,
  }) async {}

  @override
  Future<List<QuestionBox>> boxesForPageImage(String pageImagePath) async =>
      const [];
}

_OrganizeFakeRepo _organizeRepo() => _OrganizeFakeRepo(
  questions: [
    _oq('q1', '函数极限', createdAt: DateTime(2026, 11, 8)),
    _oq(
      'q2',
      '导数综合',
      sliceKind: 'function',
      sliceText: '题：设 f(x) = x³ − 3x² + 2。',
      folderIds: const ['f1'],
      createdAt: DateTime(2026, 11, 5),
    ),
    _oq(
      'q3',
      '阅读主旨',
      subjectId: 'english',
      sliceKind: 'material',
      sliceText: '题：The new evidence ______ the original hypothesis.',
      createdAt: DateTime(2026, 11, 3),
    ),
  ],
  folderList: const [
    Folder(id: 'f1', name: '试卷', subjectId: 'math'),
    Folder(id: 'f2', name: '平时作业', subjectId: 'math'),
    Folder(id: 'f3', name: '试卷', subjectId: 'english'),
  ],
  tagList: const ['易错', '常考'],
);

Future<void> _pumpOrganize(
  WidgetTester tester, {
  required _OrganizeFakeRepo repo,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: OrganizePage(
          repo: repo,
          onOpenDetail: (_, __) async {},
          onGoReview: () {},
          onGoCollect: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
