// Win11 反馈包 3：StemEditor 草稿里不再有「未关联图片」区标题。
//
// 背景：buildContentBlocks 原来给无归属图片在题干末尾加独立「未关联图片」区
// （标题块 TextBlock('以下图片未确认属于哪个选项') + 图块），_buildDrafts
// 里曾跳过该标题块以防标题文字泄漏进 ocr_stem。包 3 关掉全部“位置未确认”
// 提示、未锚定图块默认放序列末尾后，区标题块本身已不再产生，_buildDrafts
// 里的跳过逻辑随之删除（留着反而会吃掉用户题干原文恰好就是这句标题的
// 情形）；本文件改测新行为：fallback 图块仍在草稿末尾、无标题文字、
// 保存拼回的题干不含标题文字。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/modules/ocr/stem_editor.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';

Question _q(String ocrStem) => Question(
  id: 'q1',
  title: '题 q1',
  subjectId: 'math',
  createdAt: DateTime(2026, 11, 8),
  ocrStem: ocrStem,
);

/// 锚点不可用的图块（anchorSource 'fallback'）：buildContentBlocks
/// 把它默认放到序列末尾，不插区标题、不作未确认标注。
OcrFigure _fallbackFigure() => const OcrFigure(
  id: 'figure-q1-0',
  slicePath: '',
  inputHash: null,
  sequenceIndex: 0,
  anchorSource: 'fallback',
  anchorRef: '',
  bbox2d: [0, 0, 0, 0],
  spaceWidth: 0,
  spaceHeight: 0,
  transform: OcrRequestTransform(
    srcW: 0,
    srcH: 0,
    reqW: 0,
    reqH: 0,
    padX: 0,
    padY: 0,
  ),
  srcRect: SrcRect(x: 0, y: 0, width: 0, height: 0),
  cropPath: '',
);

Future<void> _pumpEditor(
  WidgetTester tester, {
  required String stem,
  required List<OcrFigure> figures,
  required void Function(String savedStem) onSave,
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
            onSave: (s) async => onSave(s),
            onAcceptCandidate: (_) async {},
            onDismissCandidate: () async {},
            onCancel: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 编辑器里所有文字草稿段的当前文本（按显示顺序）。
List<String> _draftTexts(WidgetTester tester) => tester
    .widgetList<TextField>(find.byType(TextField))
    .map((w) => w.controller?.text ?? '')
    .toList();

void main() {
  testWidgets('未锚定图块默认放末尾：无区标题文字，图块与前后题干都在且顺序不变', (
    tester,
  ) async {
    var savedStem = '';
    // 行内公式把题干切成前后两个 TextBlock。
    await _pumpEditor(
      tester,
      stem: '前置题干文字 \$x\$ 后置题干文字',
      figures: [_fallbackFigure()],
      onSave: (s) => savedStem = s,
    );

    // 草稿里没有任何文字段含旧区标题文字（区标题已不再产生）。
    const headerText = '以下图片未确认属于哪个选项';
    final texts = _draftTexts(tester);
    expect(
      texts.any((t) => t.contains(headerText)),
      isFalse,
      reason: '区标题块已取消，不得以草稿文字段出现，否则保存会写进 ocr_stem',
    );
    // 图块草稿仍在（裁图缺失时显示占位行），且不在题干文字之前。
    expect(find.text('题目配图（图片缺失）'), findsOneWidget);
    // 正常题干文本仍在，且前后文本相对顺序不变。
    final before = texts.indexWhere((t) => t.contains('前置题干文字'));
    final after = texts.indexWhere((t) => t.contains('后置题干文字'));
    expect(before, isNot(-1));
    expect(after, isNot(-1));
    expect(before, lessThan(after));

    // 保存拼回的题干也不含标题文字。
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();
    expect(savedStem.contains(headerText), isFalse);
    expect(savedStem.contains('前置题干文字'), isTrue);
    expect(savedStem.contains('后置题干文字'), isTrue);
  });

  testWidgets('题干原文恰好是旧区标题文字时不再被吃掉', (tester) async {
    // 过去 _buildDrafts 会跳过与标题一字不差的 TextBlock；区标题取消后，
    // 用户自己的这句题干应原样进草稿、原样保存。
    const headerText = '以下图片未确认属于哪个选项';
    var savedStem = '';
    await _pumpEditor(
      tester,
      stem: headerText,
      figures: const [],
      onSave: (s) => savedStem = s,
    );
    expect(_draftTexts(tester), [headerText]);
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();
    expect(savedStem, headerText);
  });

  testWidgets('无图块时：正常题干原样进草稿，不引入标题', (tester) async {
    await _pumpEditor(
      tester,
      stem: '前置题干文字 \$x\$ 后置题干文字',
      figures: const [],
      onSave: (_) {},
    );
    final texts = _draftTexts(tester);
    expect(texts.length, 2);
    expect(texts[0].contains('前置题干文字'), isTrue);
    expect(texts[1].contains('后置题干文字'), isTrue);
  });
}
