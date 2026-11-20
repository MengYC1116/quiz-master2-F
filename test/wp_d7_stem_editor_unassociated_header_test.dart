// WP-D #7 收尾小修：StemEditor 草稿不得把「未关联图片」区标题写进 ocr_stem。
//
// 背景：buildContentBlocks 给无归属图片在题干末尾加独立「未关联图片」区，
// 区标题是 TextBlock(unassociatedFiguresHeader)。_buildDrafts 原来把每个
// TextBlock 都转成 _DraftText，保存时标题文字会泄漏进 ocr_stem。
// 本修在 _buildDrafts 里跳过 text 恰好等于该常量的 TextBlock。
//
// 已知局限（实现注释同步记录）：用户题干原文恰好一字不差就是这句标题时
// 也会被跳过——概率可忽略，记为已知局限。
//
// 选新文件而不进 test/b13_stem_correction_test.dart：b13 文件测的是
// OcrStemSection 整段流程（1450 行），本修只涉 StemEditor 草稿构建，
// 直接 pump StemEditor 对外入口更贴近被测单元、失败定位更准。
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
/// 把它放进题干末尾的「未关联图片」区（标题块 + 图块）。
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
  testWidgets('未关联区标题不进草稿：标题文字不出现，图块与前后题干都在且顺序不变', (
    tester,
  ) async {
    var savedStem = '';
    // 行内公式把题干切成前后两个 TextBlock：标题块正好插在两者“之间”
    // 的位置概念上不存在（区在末尾），断言前后文本相对顺序不变。
    await _pumpEditor(
      tester,
      stem: '前置题干文字 \$x\$ 后置题干文字',
      figures: [_fallbackFigure()],
      onSave: (s) => savedStem = s,
    );

    // 草稿里没有任何 _DraftText 含标题文字（标题 TextBlock 被跳过）。
    final texts = _draftTexts(tester);
    expect(
      texts.any((t) => t.contains(unassociatedFiguresHeader)),
      isFalse,
      reason: '未关联区标题不得以草稿文字段出现，否则保存会写进 ocr_stem',
    );
    // 图块草稿仍在（裁图缺失时显示占位行）。
    expect(find.text('题目配图（图片缺失）'), findsOneWidget);
    // 正常题干文本仍在，且标题块前后文本顺序不变。
    final before = texts.indexWhere((t) => t.contains('前置题干文字'));
    final after = texts.indexWhere((t) => t.contains('后置题干文字'));
    expect(before, isNot(-1));
    expect(after, isNot(-1));
    expect(before, lessThan(after));

    // 保存拼回的题干也不含标题文字。
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();
    expect(savedStem.contains(unassociatedFiguresHeader), isFalse);
    expect(savedStem.contains('前置题干文字'), isTrue);
    expect(savedStem.contains('后置题干文字'), isTrue);
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
