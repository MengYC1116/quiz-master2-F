// Win11 反馈包 3：图块自由拖动（TDD，先写失败测试，再写实现）。
//
// 覆盖：
// - 纯函数 reorderFigures：按稳定 figure ID 重排、sequence_index 重编、
//   被拖图块记 anchorSource='manual' + 落点（anchorRef 为落点前的文字
//   段数）、裁图路径不动、非法顺序抛错。
// - buildContentBlocks：manual 图块按 anchorRef 落到指定文字段之后
//   （只读渲染与编辑器读同一份持久化顺序）；未锚定图块默认放序列
//   末尾，不再插「未关联图片」区标题、不作任何“位置未确认”标注。
// - 纯函数 mergeManualFigures：重识别产生新图块 ID 时，按裁图区域匹配
//   保留已有 manual 图块；匹配不上的 manual 图块保留在末尾并上报，
//   绝不静默丢弃（调用方据此提示用户）。
// - StemEditor：每图块左上角拖动柄（⋮⋮）、块间插入线、落下即调
//   onReorderFigure 保存、取消不写库、保存失败回滚；文字块不可拖。
// - OcrStemSection：编辑题干 / 重新识别按钮移到“识别题干”标题行。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/modules/ocr/ocr_stem_section.dart';
import 'package:quiz_master2/modules/ocr/question_content.dart';
import 'package:quiz_master2/modules/ocr/question_content_renderer.dart';
import 'package:quiz_master2/modules/ocr/stem_editor.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';
import 'package:quiz_master2/theme/app_theme.dart';

const _transform = OcrRequestTransform(
  srcW: 400,
  srcH: 500,
  reqW: 400,
  reqH: 500,
  padX: 0,
  padY: 0,
);

OcrFigure _fig(
  String id,
  int seq, {
  String anchorSource = 'fallback',
  String anchorRef = '',
  String cropPath = '',
  String slicePath = 'slices/q1.png',
  int x = 0,
  int y = 0,
  int w = 10,
  int h = 10,
  String? optionLabel,
}) => OcrFigure(
  id: id,
  slicePath: slicePath,
  inputHash: 'h1',
  sequenceIndex: seq,
  anchorSource: anchorSource,
  anchorRef: anchorRef,
  bbox2d: [x, y, x + w, y + h],
  spaceWidth: 400,
  spaceHeight: 500,
  transform: _transform,
  srcRect: SrcRect(x: x, y: y, width: w, height: h),
  cropPath: cropPath,
  optionLabel: optionLabel,
);

Question _q(
  String ocrStem, {
  List<OcrFigure> figures = const [],
  String? slicePath,
}) => Question(
  id: 'q1',
  title: '题 q1',
  subjectId: 'math',
  createdAt: DateTime(2026, 11, 8),
  ocrStem: ocrStem,
  slicePath: slicePath,
  ocrFigures: encodeOcrFigures(figures),
);

Future<void> _pumpEditor(
  WidgetTester tester, {
  required String stem,
  required List<OcrFigure> figures,
  Future<bool> Function(List<String> orderedIds, String movedId, String movedTextAt)?
  onReorderFigure,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: StemEditor(
            question: _q(stem),
            candidateStem: null,
            figures: figures,
            mdResults: null,
            onSave: (_) async {},
            onAcceptCandidate: (_) async {},
            onDismissCandidate: () async {},
            onCancel: () {},
            onReorderFigure: onReorderFigure,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 编辑器里图块拖动柄按显示顺序的图块 ID（柄 key 带图块 ID）。
List<String> _handleOrder(WidgetTester tester) => tester
    .widgetList<Draggable<String>>(find.byType(Draggable<String>))
    .map((w) => w.data!)
    .toList();

/// 某图块柄左上角的纵坐标（判断显示顺序用）。
double _handleTop(WidgetTester tester, String figureId) => tester
    .getTopLeft(find.byKey(Key('figure-drag-handle-$figureId')))
    .dy;

void main() {
  group('reorderFigures（纯函数）', () {
    test('重排三图块：顺序按新 ID 顺序、sequence_index 重编、被拖者记 manual + 落点', () {
      final figs = [
        _fig('figure-q1-0', 0, anchorSource: 'md', cropPath: 'slices/a.png'),
        _fig('figure-q1-1', 1, anchorSource: 'text', cropPath: 'slices/b.png'),
        _fig('figure-q1-2', 2, anchorSource: 'fallback', cropPath: 'slices/c.png'),
      ];
      final reordered = reorderFigures(
        figs,
        orderedIds: ['figure-q1-2', 'figure-q1-0', 'figure-q1-1'],
        movedFigureId: 'figure-q1-2',
        manualTextAt: '2',
      );
      expect(
        reordered.map((f) => f.id).toList(),
        ['figure-q1-2', 'figure-q1-0', 'figure-q1-1'],
      );
      expect(reordered.map((f) => f.sequenceIndex).toList(), [0, 1, 2]);
      // 被拖的图块记 manual + 落点（落点前有 2 个文字段）；没动的保持原锚定来源。
      expect(reordered[0].anchorSource, 'manual');
      expect(reordered[0].anchorRef, '2');
      expect(reordered[1].anchorSource, 'md');
      expect(reordered[2].anchorSource, 'text');
      // 拖动只改顺序，不改裁图文件本身。
      expect(
        reordered.map((f) => f.cropPath).toList(),
        ['slices/c.png', 'slices/a.png', 'slices/b.png'],
      );
      // 原列表不动（纯函数，不原地改）。
      expect(figs.map((f) => f.sequenceIndex).toList(), [0, 1, 2]);
      expect(figs[2].anchorSource, 'fallback');
    });

    test('已是 manual 的图块再拖：落点更新，仍是 manual', () {
      final figs = [
        _fig('figure-q1-0', 0, anchorSource: 'manual', anchorRef: '0'),
        _fig('figure-q1-1', 1, anchorSource: 'md'),
      ];
      final reordered = reorderFigures(
        figs,
        orderedIds: ['figure-q1-1', 'figure-q1-0'],
        movedFigureId: 'figure-q1-0',
        manualTextAt: '1',
      );
      expect(reordered[1].anchorSource, 'manual');
      expect(reordered[1].anchorRef, '1');
      expect(reordered[0].anchorSource, 'md');
    });

    test('新顺序不是原集合的排列时抛错（不多不少、不丢图块）', () {
      final figs = [_fig('figure-q1-0', 0), _fig('figure-q1-1', 1)];
      expect(
        () => reorderFigures(
          figs,
          orderedIds: ['figure-q1-0'],
          movedFigureId: 'figure-q1-0',
        ),
        throwsArgumentError,
      );
      expect(
        () => reorderFigures(
          figs,
          orderedIds: ['figure-q1-0', 'figure-q1-0'],
          movedFigureId: 'figure-q1-0',
        ),
        throwsArgumentError,
      );
      expect(
        () => reorderFigures(
          figs,
          orderedIds: ['figure-q1-0', 'figure-q1-9'],
          movedFigureId: 'figure-q1-0',
        ),
        throwsArgumentError,
      );
      expect(
        () => reorderFigures(
          figs,
          orderedIds: ['figure-q1-1', 'figure-q1-0'],
          movedFigureId: 'figure-q1-9',
        ),
        throwsArgumentError,
      );
    });
  });

  group('manual 图块的只读渲染位置', () {
    test('manual 图块按 anchorRef 落到指定文字段之后（与编辑器同一份顺序）', () {
      // 公式把题干切成 3 段：Text / Formula / Text。
      const stem = '第一段 \$x\$ 第二段';
      final figs = [
        _fig('figure-q1-0', 0, anchorSource: 'manual', anchorRef: '2'),
      ];
      final blocks = buildContentBlocks(
        stemMarkdown: stem,
        figures: figs,
        mdResults: null,
      );
      // 段 2（第二个 TextBlock）之前插入图块。
      expect(blocks.length, 4);
      expect(blocks[2], isA<FigureBlock>());
      expect((blocks[2] as FigureBlock).figureId, 'figure-q1-0');
    });

    test('manual 图块 anchorRef=0 落到最前面；越界钳制到末尾', () {
      const stem = '第一段 \$x\$ 第二段';
      final first = buildContentBlocks(
        stemMarkdown: stem,
        figures: [_fig('figure-q1-0', 0, anchorSource: 'manual', anchorRef: '0')],
        mdResults: null,
      );
      expect(first.first, isA<FigureBlock>());
      final clamped = buildContentBlocks(
        stemMarkdown: stem,
        figures: [_fig('figure-q1-0', 0, anchorSource: 'manual', anchorRef: '99')],
        mdResults: null,
      );
      expect(clamped.last, isA<FigureBlock>());
    });

    test('重排后编解码往返：只读渲染按存好的顺序显示同一份顺序', () {
      final figs = [
        _fig('figure-q1-0', 0, anchorSource: 'md'),
        _fig('figure-q1-1', 1, anchorSource: 'md'),
        _fig('figure-q1-2', 2, anchorSource: 'md'),
      ];
      final reordered = reorderFigures(
        figs,
        orderedIds: ['figure-q1-2', 'figure-q1-0', 'figure-q1-1'],
        movedFigureId: 'figure-q1-2',
        manualTextAt: '1',
      );
      // 落库形态：JSON 顺序即新顺序；读回后再渲染，顺序一致。
      final stored = parseOcrFigures(encodeOcrFigures(reordered));
      final blocks = buildContentBlocks(
        stemMarkdown: '题干文字',
        figures: stored,
        mdResults: '题干文字',
      );
      final figureIds = [
        for (final b in blocks.whereType<FigureBlock>()) b.figureId,
      ];
      expect(figureIds, ['figure-q1-2', 'figure-q1-0', 'figure-q1-1']);
      // 被拖者带 manual 落点，读回后仍在。
      expect(stored.first.anchorSource, 'manual');
      expect(stored.first.anchorRef, '1');
    });
  });

  group('mergeManualFigures（重识别保留 manual 图块）', () {
    test('按裁图区域匹配：manual 图块占新派生位置，旧裁图与落点都保留', () {
      final oldFigures = [
        _fig('figure-q1-0', 0, anchorSource: 'manual', anchorRef: '1', cropPath: 'slices/old-a.png', x: 40, y: 92, w: 100, h: 16),
        _fig('figure-q1-1', 1, anchorSource: 'md', cropPath: 'slices/old-b.png', x: 40, y: 142, w: 100, h: 16),
      ];
      // 新识别派生顺序颠倒、ID 全是新的（index 变了）。
      final newFigures = [
        _fig('figure-q1-0', 0, anchorSource: 'md', x: 40, y: 142, w: 100, h: 16),
        _fig('figure-q1-1', 1, anchorSource: 'md', x: 40, y: 92, w: 100, h: 16),
      ];
      final merged = mergeManualFigures(
        oldFigures: oldFigures,
        newFigures: newFigures,
      );
      expect(merged.unmatchedManualIds, isEmpty);
      // B 区图是新派生的（ID 取新派生）；A 区图是 manual 旧图，
      // 取新派生 ID（防 ID 撞车）、保留旧裁图文件与 manual 落点。
      expect(merged.figures.map((f) => f.id).toList(), ['figure-q1-0', 'figure-q1-1']);
      expect(merged.figures[0].anchorSource, 'md');
      expect(merged.figures[1].anchorSource, 'manual');
      expect(merged.figures[1].cropPath, 'slices/old-a.png');
      expect(merged.figures[1].anchorRef, '1');
      expect(merged.figures.map((f) => f.sequenceIndex).toList(), [0, 1]);
    });

    test('匹配不上的 manual 图块保留在末尾并上报，不静默丢弃', () {
      final oldFigures = [
        _fig('figure-q1-0', 0, anchorSource: 'manual', anchorRef: '1', cropPath: 'slices/old-a.png', x: 40, y: 92, w: 100, h: 16),
      ];
      // 新识别里没有这块区域了（图被 OCR 漏掉），新派生占了同名 ID。
      final newFigures = [
        _fig('figure-q1-0', 0, anchorSource: 'md', x: 200, y: 300, w: 50, h: 20),
      ];
      final merged = mergeManualFigures(
        oldFigures: oldFigures,
        newFigures: newFigures,
      );
      expect(merged.figures.length, 2);
      expect(merged.figures.map((f) => f.id).toList(), ['figure-q1-0', 'figure-q1-0-manual']);
      expect(merged.figures.last.cropPath, 'slices/old-a.png');
      expect(merged.figures.last.anchorSource, 'manual');
      expect(merged.unmatchedManualIds, ['figure-q1-0-manual']);
    });

    test('没有 manual 图块时原样返回新派生结果', () {
      final oldFigures = [
        _fig('figure-q1-0', 0, anchorSource: 'md', x: 40, y: 92, w: 100, h: 16),
      ];
      final newFigures = [
        _fig('figure-q1-0', 0, anchorSource: 'md', x: 40, y: 142, w: 100, h: 16),
      ];
      final merged = mergeManualFigures(
        oldFigures: oldFigures,
        newFigures: newFigures,
      );
      expect(merged.unmatchedManualIds, isEmpty);
      expect(merged.figures.single.srcRect.y, 142);
      expect(merged.figures.single.anchorSource, 'md');
    });
  });

  group('未锚定图块默认放序列末尾（无任何未确认提示）', () {
    test('buildContentBlocks：fallback 图块在末尾，没有区标题块', () {
      final figs = [
        _fig('figure-q1-0', 0, anchorSource: 'fallback'),
        _fig('figure-q1-1', 1, anchorSource: 'fallback'),
      ];
      final blocks = buildContentBlocks(
        stemMarkdown: '题干文字',
        figures: figs,
        mdResults: '题干文字',
      );
      // 没有“以下图片未确认属于哪个选项”标题块（Win11 反馈包 3 已删）。
      expect(
        blocks.whereType<TextBlock>().any(
          (b) => b.text == '以下图片未确认属于哪个选项',
        ),
        isFalse,
      );
      expect(blocks.last, isA<FigureBlock>());
      expect((blocks.last as FigureBlock).figureId, 'figure-q1-1');
    });

    test('diagnoseFigures：末尾的未锚定图仍能诊断出在未关联区', () {
      final figs = [_fig('figure-q1-0', 0, anchorSource: 'fallback')];
      final diag = diagnoseFigures(
        figures: figs,
        stemMarkdown: '题干文字',
        mdResults: '题干文字',
      );
      expect(diag.single['in_unassociated_zone'], isTrue);
    });
  });

  group('StemEditor 图块拖动（widget）', () {
    testWidgets('每图块左上角有拖动柄；文字块没有', (tester) async {
      await _pumpEditor(
        tester,
        stem: '第一段 \$x\$ 第二段',
        figures: [
          _fig('figure-q1-0', 0),
          _fig('figure-q1-1', 1),
        ],
      );
      // 两图块 → 两个柄；文字/公式段没有柄。
      expect(find.byIcon(Icons.drag_indicator), findsNWidgets(2));
      expect(
        find.byKey(const Key('figure-drag-handle-figure-q1-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('figure-drag-handle-figure-q1-1')),
        findsOneWidget,
      );
    });

    testWidgets('fallback 图块不显示“位置未确认”', (tester) async {
      await _pumpEditor(
        tester,
        stem: '题干文字',
        figures: [_fig('figure-q1-0', 0, anchorSource: 'fallback')],
      );
      expect(find.text('位置未确认'), findsNothing);
      expect(find.text('题目配图（图片缺失）'), findsOneWidget);
    });

    testWidgets('拖图块到末尾：落下即调 onReorderFigure，顺序换位', (tester) async {
      List<String>? savedOrder;
      String? savedMoved;
      String? savedTextAt;
      await _pumpEditor(
        tester,
        stem: '第一段\n\n第二段',
        figures: [_fig('figure-q1-0', 0), _fig('figure-q1-1', 1)],
        onReorderFigure: (orderedIds, movedId, movedTextAt) async {
          savedOrder = orderedIds;
          savedMoved = movedId;
          savedTextAt = movedTextAt;
          return true;
        },
      );
      expect(_handleOrder(tester), ['figure-q1-0', 'figure-q1-1']);
      // 图 0 的柄拖到最后一条间隔槽（gap 3，在图 1 之后）。
      final handleCenter = tester.getCenter(
        find.byKey(const Key('figure-drag-handle-figure-q1-0')),
      );
      final gapCenter = tester.getCenter(
        find.byKey(const Key('figure-drop-gap-3')),
      );
      await tester.drag(
        find.byKey(const Key('figure-drag-handle-figure-q1-0')),
        gapCenter - handleCenter,
      );
      await tester.pumpAndSettle();
      expect(savedOrder, ['figure-q1-1', 'figure-q1-0']);
      expect(savedMoved, 'figure-q1-0');
      // 落点在唯一文字段之后。
      expect(savedTextAt, '1');
      // 编辑器里图 1 已在图 0 上方。
      expect(_handleTop(tester, 'figure-q1-1'), lessThan(_handleTop(tester, 'figure-q1-0')));
    });

    testWidgets('拖到原位：不调保存、不改顺序', (tester) async {
      var calls = 0;
      await _pumpEditor(
        tester,
        stem: '第一段\n\n第二段',
        figures: [_fig('figure-q1-0', 0), _fig('figure-q1-1', 1)],
        onReorderFigure: (_, _, _) async {
          calls++;
          return true;
        },
      );
      // 图 0 的柄拖到它自己正前方的间隔槽（gap 1）→ 原位。
      final handleCenter = tester.getCenter(
        find.byKey(const Key('figure-drag-handle-figure-q1-0')),
      );
      final gapCenter = tester.getCenter(
        find.byKey(const Key('figure-drop-gap-1')),
      );
      await tester.drag(
        find.byKey(const Key('figure-drag-handle-figure-q1-0')),
        gapCenter - handleCenter,
      );
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(_handleOrder(tester), ['figure-q1-0', 'figure-q1-1']);
    });

    testWidgets('拖动取消（落到间隔槽之外）：不调保存、不改顺序', (tester) async {
      var calls = 0;
      await _pumpEditor(
        tester,
        stem: '第一段\n\n第二段',
        figures: [_fig('figure-q1-0', 0), _fig('figure-q1-1', 1)],
        onReorderFigure: (_, _, _) async {
          calls++;
          return true;
        },
      );
      await tester.drag(
        find.byKey(const Key('figure-drag-handle-figure-q1-0')),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(_handleOrder(tester), ['figure-q1-0', 'figure-q1-1']);
    });

    testWidgets('保存失败：编辑器回滚到原顺序', (tester) async {
      await _pumpEditor(
        tester,
        stem: '第一段\n\n第二段',
        figures: [_fig('figure-q1-0', 0), _fig('figure-q1-1', 1)],
        onReorderFigure: (_, _, _) async => false,
      );
      final handleCenter = tester.getCenter(
        find.byKey(const Key('figure-drag-handle-figure-q1-0')),
      );
      final gapCenter = tester.getCenter(
        find.byKey(const Key('figure-drop-gap-3')),
      );
      await tester.drag(
        find.byKey(const Key('figure-drag-handle-figure-q1-0')),
        gapCenter - handleCenter,
      );
      await tester.pumpAndSettle();
      expect(_handleTop(tester, 'figure-q1-0'), lessThan(_handleTop(tester, 'figure-q1-1')));
    });
  });

  group('QuestionContentRenderer：图块不再标未确认', () {
    testWidgets('unconfirmed 图块也不显示“位置未确认”', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuestionContentRenderer(
              blocks: const [
                TextBlock('题干文字'),
                FigureBlock(figureId: 'f0', cropPath: '', unconfirmed: true),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('位置未确认'), findsNothing);
      expect(find.text('题目配图（图片缺失）'), findsOneWidget);
    });
  });

  group('OcrStemSection：编辑 / 重新识别按钮上移到标题行', () {
    Future<void> pumpSection(
      WidgetTester tester, {
      Future<bool> Function(List<String>, String, String)? onReorderFigure,
    }) async {
      // 切片路径须与题目的 slicePath（''）一致，否则展示层按
      // currentFiguresForDisplay 滤掉图块。
      final figs = [
        _fig('figure-q1-0', 0, slicePath: ''),
        _fig('figure-q1-1', 1, slicePath: ''),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: OcrStemSection(
                question: _q('题干文字', figures: figs, slicePath: ''),
                jobs: [
                  OcrJob(
                    id: 'j1',
                    questionId: 'q1',
                    status: OcrJobStatus.completed,
                    createdAt: DateTime(2026, 11, 18, 12, 0),
                    updatedAt: DateTime(2026, 11, 18, 12, 0),
                  ),
                ],
                hasApiKey: true,
                onSaveEdited: (_) async => true,
                onAcceptCandidate: (_) async => true,
                onDismissCandidate: () async {},
                onRerecognize: () async {},
                onReorderFigure: onReorderFigure,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('两按钮与“识别题干”标题在同一行；点编辑题干仍打开编辑器', (tester) async {
      await pumpSection(tester);
      expect(find.text('编辑题干'), findsOneWidget);
      expect(find.text('重新识别'), findsOneWidget);
      // 同一行：纵坐标与标题基本一致（同一 Row 内）。
      final titleTop = tester.getTopLeft(find.text('识别题干')).dy;
      final editTop = tester.getTopLeft(find.text('编辑题干')).dy;
      final rerecTop = tester.getTopLeft(find.text('重新识别')).dy;
      expect((editTop - titleTop).abs(), lessThan(8));
      expect((rerecTop - titleTop).abs(), lessThan(8));
      await tester.tap(find.text('编辑题干'));
      await tester.pumpAndSettle();
      expect(find.text('保存修改'), findsOneWidget);
    });

    testWidgets('编辑态时标题行按钮隐藏（编辑器自带保存/取消）', (tester) async {
      await pumpSection(tester);
      await tester.tap(find.text('编辑题干'));
      await tester.pumpAndSettle();
      expect(find.text('编辑题干'), findsNothing);
      expect(find.text('重新识别'), findsNothing);
      expect(find.text('保存修改'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
    });

    testWidgets('经 OcrStemSection 拖图块：onReorderFigure 透传到底层', (tester) async {
      List<String>? savedOrder;
      await pumpSection(
        tester,
        onReorderFigure: (orderedIds, _, _) async {
          savedOrder = orderedIds;
          return true;
        },
      );
      await tester.tap(find.text('编辑题干'));
      await tester.pumpAndSettle();
      final handleCenter = tester.getCenter(
        find.byKey(const Key('figure-drag-handle-figure-q1-0')),
      );
      final gapCenter = tester.getCenter(
        find.byKey(const Key('figure-drop-gap-3')),
      );
      await tester.drag(
        find.byKey(const Key('figure-drag-handle-figure-q1-0')),
        gapCenter - handleCenter,
      );
      await tester.pumpAndSettle();
      expect(savedOrder, ['figure-q1-1', 'figure-q1-0']);
    });
  });
}
