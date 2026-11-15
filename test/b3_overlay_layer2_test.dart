// B3 追加项 1：整理页叠加层改用库里真实的 Layer-2 框坐标。
//
// 有 layer=2 真实框时叠加层按真实框画（页图坐标经 layer-1 框换算到
// 整题切片坐标，见 widgets.dart 的 layer2BoxToSliceRect /
// realRegionRects）；没有真实框时回退现有示意框。是否显示仍由
// regionsOfQuestion 决定：真实题（空 sliceText）即使库里有框也不
// 显示区域（P1-1 红线）。
//
// 换算关系：切片就是页图按 layer-1 框裁出的图（cropBoxPng），确认时
// 框已随页图旋转烘焙到同一坐标系（collect_page 的
// rotateBoxToRotatedPage 调用），所以 x'=(x−lx)/lw，y'=(y−ly)/lh，
// w'=w/lw，h'=h/lh，结果钳制进 0..1。
//
// 用例不碰真实库：FakeRepo 覆盖 boxesForPageImage；整理页只在
// pageImagePath 非空时才读库（演示题 pageImagePath 为空，不读库）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/organize/organize_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/widgets.dart';

QuestionBox _box({
  required String id,
  required int layer,
  required String type,
  required double x,
  required double y,
  required double w,
  required double h,
  String? questionId,
}) => QuestionBox(
  id: id,
  layer: layer,
  type: type,
  x: x,
  y: y,
  w: w,
  h: h,
  questionId: questionId,
);

Question _question({
  String id = 'qo',
  String sliceText = '题：lim(x→0) sin 3x / x 的值是（　）',
  String sliceKind = 'limit',
  String? pageImagePath,
}) => Question(
  id: id,
  title: '测试题',
  subjectId: 'math',
  sliceKind: sliceKind,
  sliceText: sliceText,
  pageImagePath: pageImagePath,
  createdAt: DateTime(2026, 11, 8),
);

void main() {
  group('layer2BoxToSliceRect：页图坐标 → 切片坐标', () {
    test('基本换算：框在 layer-1 框内的相对位置', () {
      final layer1 = _box(
        id: 'b1',
        layer: 1,
        type: 'question',
        x: 0.1,
        y: 0.2,
        w: 0.5,
        h: 0.4,
      );
      final layer2 = _box(
        id: 'b2',
        layer: 2,
        type: 'stem',
        x: 0.2,
        y: 0.3,
        w: 0.1,
        h: 0.1,
      );
      final r = layer2BoxToSliceRect(layer1, layer2);
      expect(r, isNotNull);
      expect(r!.left, closeTo(0.2, 1e-9));
      expect(r.top, closeTo(0.25, 1e-9));
      expect(r.width, closeTo(0.2, 1e-9));
      expect(r.height, closeTo(0.25, 1e-9));
    });

    test('部分落在整题框外：钳制进 0..1，不丢框', () {
      final layer1 = _box(
        id: 'b1',
        layer: 1,
        type: 'question',
        x: 0.1,
        y: 0.1,
        w: 0.8,
        h: 0.8,
      );
      final layer2 = _box(
        id: 'b2',
        layer: 2,
        type: 'stem',
        x: 0.05,
        y: 0.05,
        w: 0.4,
        h: 0.4,
      );
      final r = layer2BoxToSliceRect(layer1, layer2);
      expect(r, isNotNull);
      expect(r!.left, 0.0);
      expect(r.top, 0.0);
      expect(r.right, closeTo((0.05 + 0.4 - 0.1) / 0.8, 1e-9));
    });

    test('layer-1 框无面积 / layer-2 框完全在整题框外：返回 null', () {
      final flat = _box(
        id: 'b1',
        layer: 1,
        type: 'question',
        x: 0.1,
        y: 0.1,
        w: 0.0,
        h: 0.8,
      );
      final inner = _box(
        id: 'b2',
        layer: 2,
        type: 'stem',
        x: 0.2,
        y: 0.2,
        w: 0.1,
        h: 0.1,
      );
      expect(layer2BoxToSliceRect(flat, inner), isNull);
      final layer1 = _box(
        id: 'b1',
        layer: 1,
        type: 'question',
        x: 0.1,
        y: 0.1,
        w: 0.5,
        h: 0.5,
      );
      final outside = _box(
        id: 'b3',
        layer: 2,
        type: 'stem',
        x: 0.8,
        y: 0.8,
        w: 0.1,
        h: 0.1,
      );
      expect(layer2BoxToSliceRect(layer1, outside), isNull);
    });
  });

  group('realRegionRects：从一题的框算各区域切片矩形', () {
    test('有 layer-1 + stem/option 框：各区域换算正确', () {
      final rects = realRegionRects([
        _box(
          id: 'b1',
          layer: 1,
          type: 'question',
          x: 0.1,
          y: 0.1,
          w: 0.8,
          h: 0.8,
          questionId: 'qo',
        ),
        _box(
          id: 'b2',
          layer: 2,
          type: 'stem',
          x: 0.2,
          y: 0.2,
          w: 0.4,
          h: 0.2,
          questionId: 'qo',
        ),
        _box(
          id: 'b3',
          layer: 2,
          type: 'option',
          x: 0.2,
          y: 0.6,
          w: 0.4,
          h: 0.2,
          questionId: 'qo',
        ),
      ]);
      expect(rects.keys, {'stem', 'option'});
      expect(rects['stem']!.left, closeTo(0.125, 1e-9));
      expect(rects['stem']!.top, closeTo(0.125, 1e-9));
      expect(rects['stem']!.width, closeTo(0.5, 1e-9));
      expect(rects['stem']!.height, closeTo(0.25, 1e-9));
      expect(rects['option']!.top, closeTo(0.625, 1e-9));
    });

    test('无 layer-1 框：返回空（回退示意框）', () {
      expect(
        realRegionRects([
          _box(
            id: 'b2',
            layer: 2,
            type: 'stem',
            x: 0.2,
            y: 0.2,
            w: 0.4,
            h: 0.2,
          ),
        ]),
        isEmpty,
      );
      expect(realRegionRects(const []), isEmpty);
    });

    test('非 stem/option/figure 的 layer-2 行忽略；同区域多个框取第一个', () {
      final rects = realRegionRects([
        _box(
          id: 'b1',
          layer: 1,
          type: 'question',
          x: 0.0,
          y: 0.0,
          w: 1.0,
          h: 1.0,
        ),
        _box(
          id: 'b2',
          layer: 2,
          type: 'question',
          x: 0.1,
          y: 0.1,
          w: 0.2,
          h: 0.2,
        ),
        _box(
          id: 'b3',
          layer: 2,
          type: 'stem',
          x: 0.1,
          y: 0.1,
          w: 0.2,
          h: 0.2,
        ),
        _box(
          id: 'b4',
          layer: 2,
          type: 'stem',
          x: 0.5,
          y: 0.5,
          w: 0.2,
          h: 0.2,
        ),
      ]);
      expect(rects.keys, {'stem'});
      expect(rects['stem'], const Rect.fromLTWH(0.1, 0.1, 0.2, 0.2));
    });
  });

  group('QuestionRegionOverlays：真实框 / 示意框', () {
    Future<void> pumpOverlay(
      WidgetTester tester, {
      required Set<String> visible,
      Map<String, Rect> realRects = const {},
    }) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(scale: 1.0),
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 300,
              child: QuestionRegionOverlays(
                question: _question(),
                visible: visible,
                realRects: realRects,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// 叠加层内某区域标签相对叠加层原点的偏移（标签在框内左上 +4px）。
    Offset labelOffset(WidgetTester tester, String label) {
      final labelFinder = find.descendant(
        of: find.byType(QuestionRegionOverlays),
        matching: find.text(label),
      );
      final overlayFinder = find.byType(QuestionRegionOverlays);
      final labelTopLeft = tester.getTopLeft(labelFinder);
      final overlayTopLeft = tester.getTopLeft(overlayFinder);
      return labelTopLeft - overlayTopLeft;
    }

    testWidgets('有真实框：stem 按真实框位置画，不是示意比例', (tester) async {
      await pumpOverlay(
        tester,
        visible: {'stem'},
        realRects: const {'stem': Rect.fromLTWH(0.2, 0.25, 0.3, 0.2)},
      );
      // 真实框：左 0.2×400+4=84，上 0.25×300+4=79；示意框会是 (14,14)。
      final offset = labelOffset(tester, 'stem 题干');
      expect(offset.dx, closeTo(84, 1.0));
      expect(offset.dy, closeTo(79, 1.0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('无真实框：回退示意框（stem 左上 10,10）', (tester) async {
      await pumpOverlay(tester, visible: {'stem', 'option'});
      final stem = labelOffset(tester, 'stem 题干');
      expect(stem.dx, closeTo(14, 1.0));
      expect(stem.dy, closeTo(14, 1.0));
      // option 示意框：左 10，上 300−12−300×0.36=180。
      final option = labelOffset(tester, 'option 选项');
      expect(option.dx, closeTo(14, 1.0));
      expect(option.dy, closeTo(184, 1.0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('部分真实：有框的区域用真实框，无框的区域回退示意框', (
      tester,
    ) async {
      await pumpOverlay(
        tester,
        visible: {'stem', 'option'},
        realRects: const {'stem': Rect.fromLTWH(0.2, 0.25, 0.3, 0.2)},
      );
      final stem = labelOffset(tester, 'stem 题干');
      expect(stem.dx, closeTo(84, 1.0));
      expect(stem.dy, closeTo(79, 1.0));
      final option = labelOffset(tester, 'option 选项');
      expect(option.dx, closeTo(14, 1.0));
      expect(option.dy, closeTo(184, 1.0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('visible 为空：不画任何框', (tester) async {
      await pumpOverlay(
        tester,
        visible: const {},
        realRects: const {'stem': Rect.fromLTWH(0.2, 0.25, 0.3, 0.2)},
      );
      expect(find.text('stem 题干'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('整理页叠加层：真实框接线', () {
    testWidgets('有真实框的老题：叠加层画真实框坐标', (tester) async {
      final repo = FakeOverlayRepo(
        questions: [
          _question(pageImagePath: 'pages/p1.png'),
        ],
        boxesByPageImage: {
          'pages/p1.png': [
            _box(
              id: 'b1',
              layer: 1,
              type: 'question',
              x: 0.1,
              y: 0.1,
              w: 0.8,
              h: 0.8,
              questionId: 'qo',
            ),
            _box(
              id: 'b2',
              layer: 2,
              type: 'stem',
              x: 0.2,
              y: 0.2,
              w: 0.4,
              h: 0.2,
              questionId: 'qo',
            ),
            _box(
              id: 'b3',
              layer: 2,
              type: 'option',
              x: 0.2,
              y: 0.6,
              w: 0.4,
              h: 0.2,
              questionId: 'qo',
            ),
            // 同页别题的框：必须被 questionId 过滤掉。
            _box(
              id: 'b9',
              layer: 2,
              type: 'stem',
              x: 0.3,
              y: 0.3,
              w: 0.1,
              h: 0.1,
              questionId: 'other',
            ),
          ],
        },
      );
      await pumpOrganize(tester, repo: repo);
      final overlaySize = tester.getSize(find.byType(QuestionRegionOverlays));
      final overlayTopLeft = tester.getTopLeft(
        find.byType(QuestionRegionOverlays),
      );
      // stem 真实框：切片坐标 (0.125, 0.125, 0.5, 0.25)，标签在框内
      // 左上 +4px；示意框会是 (14,14)。
      final stemTopLeft = tester.getTopLeft(
        find.descendant(
          of: find.byType(QuestionRegionOverlays),
          matching: find.text('stem 题干'),
        ),
      );
      final stemOffset = stemTopLeft - overlayTopLeft;
      expect(stemOffset.dx, closeTo(0.125 * overlaySize.width + 4, 1.0));
      expect(stemOffset.dy, closeTo(0.125 * overlaySize.height + 4, 1.0));
      // option 真实框：切片坐标 (0.125, 0.625, 0.5, 0.25)。
      final optionTopLeft = tester.getTopLeft(
        find.descendant(
          of: find.byType(QuestionRegionOverlays),
          matching: find.text('option 选项'),
        ),
      );
      final optionOffset = optionTopLeft - overlayTopLeft;
      expect(optionOffset.dx, closeTo(0.125 * overlaySize.width + 4, 1.0));
      expect(optionOffset.dy, closeTo(0.625 * overlaySize.height + 4, 1.0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('无真实框的老题：回退示意框', (tester) async {
      final repo = FakeOverlayRepo(
        questions: [_question(pageImagePath: 'pages/p1.png')],
        boxesByPageImage: const {'pages/p1.png': []},
      );
      await pumpOrganize(tester, repo: repo);
      final overlayTopLeft = tester.getTopLeft(
        find.byType(QuestionRegionOverlays),
      );
      final stemTopLeft = tester.getTopLeft(
        find.descendant(
          of: find.byType(QuestionRegionOverlays),
          matching: find.text('stem 题干'),
        ),
      );
      final stemOffset = stemTopLeft - overlayTopLeft;
      expect(stemOffset.dx, closeTo(14, 1.0));
      expect(stemOffset.dy, closeTo(14, 1.0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('真实题（空 sliceText）即使库里有框：仍不显示区域', (
      tester,
    ) async {
      final repo = FakeOverlayRepo(
        questions: [
          _question(sliceText: '', pageImagePath: 'pages/p1.png'),
        ],
        boxesByPageImage: {
          'pages/p1.png': [
            _box(
              id: 'b1',
              layer: 1,
              type: 'question',
              x: 0.1,
              y: 0.1,
              w: 0.8,
              h: 0.8,
              questionId: 'qo',
            ),
            _box(
              id: 'b2',
              layer: 2,
              type: 'stem',
              x: 0.2,
              y: 0.2,
              w: 0.4,
              h: 0.2,
              questionId: 'qo',
            ),
          ],
        },
      );
      await pumpOrganize(tester, repo: repo);
      expect(find.text('stem 题干'), findsNothing);
      expect(find.text('option 选项'), findsNothing);
      expect(find.text('区域仅作辅助定位，整题图始终是主体'), findsNothing);
      expect(find.byType(Checkbox), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('放大浮层：同样按真实框画', (tester) async {
      final repo = FakeOverlayRepo(
        questions: [_question(pageImagePath: 'pages/p1.png')],
        boxesByPageImage: {
          'pages/p1.png': [
            _box(
              id: 'b1',
              layer: 1,
              type: 'question',
              x: 0.1,
              y: 0.1,
              w: 0.8,
              h: 0.8,
              questionId: 'qo',
            ),
            _box(
              id: 'b2',
              layer: 2,
              type: 'stem',
              x: 0.2,
              y: 0.2,
              w: 0.4,
              h: 0.2,
              questionId: 'qo',
            ),
          ],
        },
      );
      await pumpOrganize(tester, repo: repo);
      await tester.tap(find.byType(QuestionSlice));
      await tester.pumpAndSettle();
      expect(find.text('整题图 · 放大查看'), findsOneWidget);
      final dialogOverlay = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(QuestionRegionOverlays),
      );
      expect(dialogOverlay, findsOneWidget);
      // 放大浮层里纸面经 InteractiveViewer 缩放（初始 min(1.5, fit)，
      // 1280×720 下约 1.32×）：屏幕坐标偏移 = 缩放 × 布局偏移。用对话
      // 框内 QuestionSlice 的屏幕宽 / 布局宽实测该缩放，再算期望值。
      final dialogSlice = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(QuestionSlice),
      );
      final zoomScale =
          tester.getRect(dialogSlice).width / tester.getSize(dialogSlice).width;
      final overlaySize = tester.getSize(dialogOverlay);
      final overlayTopLeft = tester.getTopLeft(dialogOverlay);
      final stemTopLeft = tester.getTopLeft(
        find.descendant(
          of: dialogOverlay,
          matching: find.text('stem 题干'),
        ),
      );
      final stemOffset = stemTopLeft - overlayTopLeft;
      expect(
        stemOffset.dx,
        closeTo(zoomScale * (0.125 * overlaySize.width + 4), 1.0),
      );
      expect(
        stemOffset.dy,
        closeTo(zoomScale * (0.125 * overlaySize.height + 4), 1.0),
      );
      expect(tester.takeException(), isNull);
    });
  });
}

/// 只覆盖整理页用到的仓库调用；boxesForPageImage 按页图路径返回
/// 预置的框（不碰真实库）。
class FakeOverlayRepo extends QuestionRepository {
  FakeOverlayRepo({
    required this.questions,
    this.boxesByPageImage = const {},
  }) : super(AppDatabase.instance);

  List<Question> questions;
  Map<String, List<QuestionBox>> boxesByPageImage;

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [
    Folder(id: 'f1', name: '试卷', subjectId: 'math'),
  ];

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<List<String>> tags() async => const [];

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<List<QuestionBox>> boxesForPageImage(String pageImagePath) async =>
      List.of(boxesByPageImage[pageImagePath] ?? const <QuestionBox>[]);

  @override
  Future<void> save(Question question) async {}

  @override
  Future<void> syncCauseRecords(Question question) async {}

  @override
  Future<void> saveRecentTask({
    required String kind,
    required String subjectId,
    required String title,
  }) async {}
}

Future<void> pumpOrganize(WidgetTester tester, {required FakeOverlayRepo repo}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
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
