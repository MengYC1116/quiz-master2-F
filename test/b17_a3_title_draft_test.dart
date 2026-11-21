// 十七批 A3：Q1 标题草稿拼接。
//
// 原发现：batch14-work/WIN11-FIXES-ROUND2-STATUS.md:9（附带发现，未修）：
// 标题草稿保存时与后文直接拼接（`'# 标题'` + `'正文 '` 存成
// `'# 标题正文 $x$ 尾'`），旧代码既有行为。
//
// 复现：题干 `'# 标题\n正文 $x$ 尾'` 进 StemEditor 后直接保存，
// 应原样拼回；bug 是标题行丢了行尾换行，后文被标题行吞掉，
// 再解析时标题变成 `'标题正文 $x$ 尾'`、行内公式 `$x$` 丢失。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/ocr/question_content.dart';
import 'package:quiz_master2/modules/ocr/stem_editor.dart';

Question _q(String ocrStem) => Question(
  id: 'q1',
  title: '题 q1',
  subjectId: 'math',
  createdAt: DateTime(2026, 11, 8),
  ocrStem: ocrStem,
);

String _lastSavedForTest = '';

Future<void> _pumpEditor(
  WidgetTester tester, {
  required String stem,
  required void Function(String savedStem) onSave,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: StemEditor(
            question: _q(stem),
            candidateStem: null,
            sliceBytes: null,
            figures: const [],
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

Future<String> _save(WidgetTester tester) async {
  await tester.tap(find.text('保存修改'));
  await tester.pumpAndSettle();
  return _lastSavedForTest;
}

List<String> _draftTexts(WidgetTester tester) => tester
    .widgetList<TextField>(find.byType(TextField))
    .map((w) => w.controller?.text ?? '')
    .toList();

void main() {
  group('A3 标题草稿拼接：blocksToMarkdown 标题后不断行', () {
    test('标题块后接正文：拼回须补换行，再解析结构不变', () {
      final blocks = [
        const HeadingBlock('标题', 1),
        const TextBlock('正文 '),
        const FormulaBlock('x', displayMode: false),
        const TextBlock(' 尾'),
      ];
      final rebuilt = blocksToMarkdown(blocks);
      expect(rebuilt, '# 标题\n正文 \$x\$ 尾');
      final reparsed = parseQuestionContent(rebuilt);
      expect(reparsed[0], isA<HeadingBlock>());
      expect((reparsed[0] as HeadingBlock).text, '标题');
      expect(reparsed.whereType<FormulaBlock>().single.latex, 'x');
    });

    test('标题块在末尾：拼回不强制多一个换行', () {
      final rebuilt = blocksToMarkdown([
        const TextBlock('正文 '),
        const HeadingBlock('标题', 1),
      ]);
      expect(rebuilt, '正文 \n# 标题');
    });
  });

  group('A3 标题草稿拼接：StemEditor 保存往返', () {
    testWidgets('标题在首：直接保存原样拼回', (tester) async {
      const stem = '# 标题\n正文 \$x\$ 尾';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        onSave: (s) => _lastSavedForTest = s,
      );
      expect(_draftTexts(tester), ['# 标题', '正文 ', ' 尾']);
      expect(await _save(tester), stem);
    });

    testWidgets('标题在中：前后文不断行丢失', (tester) async {
      const stem = '前文\n# 标题\n后文';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        onSave: (s) => _lastSavedForTest = s,
      );
      expect(await _save(tester), stem);
    });

    testWidgets('标题在末：直接保存原样拼回', (tester) async {
      const stem = '正文 \$x\$ 尾\n# 标题';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        onSave: (s) => _lastSavedForTest = s,
      );
      expect(await _save(tester), stem);
    });
  });
}
