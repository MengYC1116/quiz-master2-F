// Win11 反馈后续修复 Q1+Q2 联合不变量（REV2 §10，与流 A 共担）。
//
// 视觉分组绝不能改变底层内容块的逻辑顺序：
// - S0 = parseQuestionContent(stem)（不含图块）；
// - S1 = buildContentBlocks(...)（Q2 切分后，含图块）；
// - S2 = StemEditor 的复合卡展开（Q1 分组后）。
// 则：blocksToMarkdown(S1，跳过图块) == blocksToMarkdown(S0)；
// S2 的复合卡按段内顺序展平、去掉图块卡后，块序列与 S0 逐项一致
// （TextBlock 允许是切分后的两半，其拼接等于原块；FormulaBlock 逐项一致）。
// 机制保证：Q1 分组遇到 FigureBlock 即断开；Q2 的切分 halves 是普通
// TextBlock，Q1 把它们当普通文本段分组；图块永远不在任何复合卡内部。
//
// S2 经编辑器 widget 断言（_buildDrafts 是私有的，不直接调）：段落卡
// 内 TextField 的 controller 文本按段内顺序排列，图块柄在两卡之间。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/modules/ocr/question_content.dart';
import 'package:quiz_master2/modules/ocr/stem_editor.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';

const _transform = OcrRequestTransform(
  srcW: 400,
  srcH: 500,
  reqW: 400,
  reqH: 500,
  padX: 0,
  padY: 0,
);

const _dir = '/home/hatch/workspace/figure-diag';

OcrFigure _mdFig(String id, int seq, int order) => OcrFigure(
  id: id,
  slicePath: 'slices/q1.png',
  inputHash: 'h1',
  sequenceIndex: seq,
  anchorSource: 'md',
  anchorRef: '$order',
  bbox2d: [order * 100, 0, order * 100 + 50, 50],
  spaceWidth: 400,
  spaceHeight: 500,
  transform: _transform,
  srcRect: SrcRect(x: order * 100, y: 0, width: 50, height: 50),
  cropPath: '',
);

String _ref(int order) =>
    '![](page=0,bbox=[${order * 100}, 0, ${order * 100 + 50}, 50])';

Question _q(String ocrStem) => Question(
  id: 'q1',
  title: '题 q1',
  subjectId: 'math',
  createdAt: DateTime(2026, 11, 8),
  ocrStem: ocrStem,
);

/// 编辑器里图块拖动柄按显示顺序的图块 ID（柄 key 带图块 ID）。
List<String> _handleOrder(WidgetTester tester) => tester
    .widgetList<Draggable<String>>(find.byType(Draggable<String>))
    .map((w) => w.data!)
    .toList();

/// 某段落卡内的 TextField 文本（按段内顺序）。
List<String> _cardTexts(WidgetTester tester, int cardIndex) {
  final fields = find.descendant(
    of: find.byKey(Key('stem-paragraph-card-$cardIndex')),
    matching: find.byType(TextField),
  );
  return tester
      .widgetList<TextField>(fields)
      .map((w) => w.controller!.text)
      .toList();
}

void main() {
  group('Q1+Q2 共享不变量：视觉分组不改变底层块顺序', () {
    test('twin2：切分后拼回与原题干一致，文本拼接等于原块', () {
      final stem = File('$_dir/twin2_stem.md').readAsStringSync();
      final figs = parseOcrFigures(
        File('$_dir/twin2_figures.json').readAsStringSync(),
      );
      final md = File('$_dir/twin2_md.md').readAsStringSync();
      final s0 = parseQuestionContent(stem);
      final s1 = buildContentBlocks(
        stemMarkdown: stem,
        figures: figs,
        mdResults: md,
      );
      // blocksToMarkdown 跳过图块：S1 与 S0 拼回一致。
      expect(blocksToMarkdown(s1), blocksToMarkdown(s0));
      // S1 的非图块：原块 4 的两半拼接等于原块；其余逐项一致。
      final s1Text = s1.whereType<TextBlock>().map((b) => b.text).join();
      final s0Text = s0.whereType<TextBlock>().map((b) => b.text).join();
      expect(s1Text, s0Text);
      expect(
        s1.whereType<FormulaBlock>().map((b) => b.latex).toList(),
        s0.whereType<FormulaBlock>().map((b) => b.latex).toList(),
      );
      // 图块不在任何文本段内部：S1 里图块前后都是完整的内容块。
      final fig0At = s1.indexWhere(
        (b) => b is FigureBlock && b.figureId == figs[0].id,
      );
      expect(s1[fig0At - 1], isA<TextBlock>());
      expect(s1[fig0At + 1], isA<TextBlock>());
    });

    test('多图同块：切分后拼回一致，图块顺序不变', () {
      const stem = '第一段文字。\n\n\n第二段文字。\n\n\n第三段文字。';
      final md =
          '第一段文字。\n${_ref(0)}\n\n第二段文字。\n${_ref(1)}\n\n第三段文字。';
      final figs = [_mdFig('figure-q1-0', 0, 0), _mdFig('figure-q1-1', 1, 1)];
      final s0 = parseQuestionContent(stem);
      final s1 = buildContentBlocks(
        stemMarkdown: stem,
        figures: figs,
        mdResults: md,
      );
      expect(blocksToMarkdown(s1), blocksToMarkdown(s0));
      expect(
        s1.whereType<TextBlock>().map((b) => b.text).join(),
        s0.whereType<TextBlock>().map((b) => b.text).join(),
      );
      expect(
        [
          for (final b in s1.whereType<FigureBlock>()) b.figureId,
        ],
        ['figure-q1-0', 'figure-q1-1'],
      );
    });

    test('无切分：S1 只是 S0 加图块，不改文本块', () {
      const stem = '第一段文字 \$x\$ 第二段文字。';
      final figs = [
        OcrFigure(
          id: 'figure-q1-0',
          slicePath: 'slices/q1.png',
          inputHash: 'h1',
          sequenceIndex: 0,
          anchorSource: 'text',
          anchorRef: 'text-0',
          bbox2d: const [0, 0, 50, 50],
          spaceWidth: 400,
          spaceHeight: 500,
          transform: _transform,
          srcRect: const SrcRect(x: 0, y: 200, width: 50, height: 100),
          cropPath: '',
        ),
      ];
      final s0 = parseQuestionContent(stem);
      final s1 = buildContentBlocks(
        stemMarkdown: stem,
        figures: figs,
        mdResults: stem,
      );
      expect(blocksToMarkdown(s1), blocksToMarkdown(s0));
      expect(
        s1.whereType<TextBlock>().map((b) => b.text).toList(),
        s0.whereType<TextBlock>().map((b) => b.text).toList(),
      );
    });

    testWidgets('twin2 编辑器：图块在两段落卡之间的独立卡位，保存拼回原题干', (
      tester,
    ) async {
      late String stem;
      late List<OcrFigure> figs;
      late String md;
      await tester.runAsync(() async {
        stem = File('$_dir/twin2_stem.md').readAsStringSync();
        figs = parseOcrFigures(
          File('$_dir/twin2_figures.json').readAsStringSync(),
        ).map((f) => f.copyWith(cropPath: '')).toList();
        md = File('$_dir/twin2_md.md').readAsStringSync();
      });
      String? savedStem;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StemEditor(
                question: _q(stem),
                candidateStem: null,
                figures: figs,
                mdResults: md,
                onSave: (s) async => savedStem = s,
                onAcceptCandidate: (_) async {},
                onDismissCandidate: () async {},
                onCancel: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 草稿为 [段落卡 0，图块 0，段落卡 2，图块 1]：图块断开分组。
      expect(find.byKey(const Key('stem-paragraph-card-0')), findsOneWidget);
      expect(find.byKey(const Key('stem-paragraph-card-2')), findsOneWidget);
      expect(find.byKey(const Key('stem-paragraph-card-1')), findsNothing);
      // 卡 0 按段内顺序展开：文字 / 公式 / 文字 / 公式 / 文字（切分后半）。
      final card0 = _cardTexts(tester, 0);
      expect(card0.length, 3);
      expect(card0[0], '(1) 在 100 kPa下，该反应的吉布斯自由能 ');
      expect(card0[1], '和压强平衡常数 ');
      expect(card0[2], startsWith('随温度的变化如图所示。'));
      expect(card0[2].trimRight(), endsWith('不随温度而改变。）'));
      // 卡 2 只有填空行段（切分后半）。
      final card2 = _cardTexts(tester, 2);
      expect(card2.length, 1);
      expect(card2[0], startsWith('该反应的正反应活化能'));
      // 图块柄按显示顺序是两图；图 0 在两卡之间的独立卡位。
      expect(_handleOrder(tester), [figs[0].id, figs[1].id]);
      final card0Bottom = tester
          .getBottomRight(find.byKey(const Key('stem-paragraph-card-0')))
          .dy;
      final fig0Top = tester
          .getTopLeft(find.byKey(Key('figure-drag-handle-${figs[0].id}')))
          .dy;
      final card2Top = tester
          .getTopLeft(find.byKey(const Key('stem-paragraph-card-2')))
          .dy;
      expect(card0Bottom, lessThan(fig0Top));
      expect(fig0Top, lessThan(card2Top));
      // 保存按钮在长编辑器底部、视口之外：先滚到可见再点。
      // 保存：复合卡按段内顺序展开拼回，与原题干拼回一致（图块不拼回）。
      await tester.ensureVisible(find.text('保存修改'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();
      expect(savedStem, isNotNull);
      expect(savedStem, blocksToMarkdown(parseQuestionContent(stem)));
    });
  });
}
