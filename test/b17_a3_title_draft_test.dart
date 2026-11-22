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

  group('A3 反方向（B20-P2）：blocksToMarkdown 标题前缺换行须补回', () {
    test('公式块后接标题：拼回须补换行', () {
      final rebuilt = blocksToMarkdown([
        const FormulaBlock('x', displayMode: false),
        const HeadingBlock('标题', 1),
      ]);
      expect(rebuilt, '\$x\$\n# 标题');
    });

    test('代码块后接标题：拼回须补换行', () {
      final rebuilt = blocksToMarkdown([
        const CodeBlock('a=1', language: 'python'),
        const HeadingBlock('标题', 1),
      ]);
      expect(rebuilt, '```python\na=1\n```\n# 标题');
    });

    test('图块在标题前：图块无文本输出，标题前仍须补换行', () {
      final rebuilt = blocksToMarkdown([
        const TextBlock('前文'),
        const FigureBlock(figureId: 'f1', cropPath: ''),
        const HeadingBlock('标题', 1),
      ]);
      expect(rebuilt, '前文\n# 标题');
    });

    test('连续标题：只补一处换行，不重复补空行', () {
      final rebuilt = blocksToMarkdown([
        const HeadingBlock('标题1', 1),
        const HeadingBlock('标题2', 1),
      ]);
      expect(rebuilt, '# 标题1\n# 标题2');
    });

    test('标题在首：不补前换行', () {
      final rebuilt = blocksToMarkdown([
        const HeadingBlock('标题', 1),
        const TextBlock('后文'),
      ]);
      expect(rebuilt, '# 标题\n后文');
    });
  });

  group('A3 反方向（B20-P2）：StemEditor 标题卡前一段尾换行被删，保存时补回', () {
    testWidgets('标题在中：前段尾换行被删，保存时补回', (tester) async {
      const stem = '前文\n# 标题\n后文';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        onSave: (s) => _lastSavedForTest = s,
      );
      expect(_draftTexts(tester), ['前文\n', '# 标题', '后文']);
      await _deleteTrailingNewline(tester, 0);
      expect(_draftTexts(tester), ['前文', '# 标题', '后文']);
      expect(await _save(tester), stem);
      // 再解析：标题仍为标题，不被前文吞掉。
      final reparsed = parseQuestionContent(_lastSavedForTest);
      expect(reparsed[1], isA<HeadingBlock>());
      expect((reparsed[1] as HeadingBlock).text, '标题');
    });

    testWidgets('标题在末：前段尾换行被删，保存时补回且不加尾换行', (tester) async {
      const stem = '前文\n# 标题';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        onSave: (s) => _lastSavedForTest = s,
      );
      expect(_draftTexts(tester), ['前文\n', '# 标题']);
      await _deleteTrailingNewline(tester, 0);
      expect(await _save(tester), stem);
    });

    testWidgets('连续标题：前段尾换行被删，只补第一处', (tester) async {
      const stem = '前文\n# 标题1\n# 标题2\n后文';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        onSave: (s) => _lastSavedForTest = s,
      );
      expect(
        _draftTexts(tester),
        ['前文\n', '# 标题1', '# 标题2', '后文'],
      );
      await _deleteTrailingNewline(tester, 0);
      expect(await _save(tester), stem);
    });

    testWidgets('标题前是含公式段落卡：段内末段尾换行被删，保存时补回',
        (tester) async {
      const stem = '前文 \$x\$ 尾\n# 标题\n后文';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        onSave: (s) => _lastSavedForTest = s,
      );
      expect(_draftTexts(tester), ['前文 ', ' 尾\n', '# 标题', '后文']);
      await _deleteTrailingNewline(tester, 1);
      expect(await _save(tester), stem);
    });

    testWidgets('二级标题：前段尾换行被删，保存时补回', (tester) async {
      const stem = '前文\n## 副标题\n后文';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        onSave: (s) => _lastSavedForTest = s,
      );
      expect(_draftTexts(tester), ['前文\n', '## 副标题', '后文']);
      await _deleteTrailingNewline(tester, 0);
      expect(await _save(tester), stem);
    });
  });
}

/// 模拟用户在编辑器里删掉第 [index] 个草稿段的尾换行。
Future<void> _deleteTrailingNewline(WidgetTester tester, int index) async {
  final field = tester.widget<TextField>(find.byType(TextField).at(index));
  final text = field.controller?.text ?? '';
  expect(
    text.endsWith('\n'),
    isTrue,
    reason: '前置条件：第 $index 个草稿段应以换行结尾，实际为 "$text"',
  );
  await tester.enterText(
    find.byType(TextField).at(index),
    text.substring(0, text.length - 1),
  );
  await tester.pumpAndSettle();
}
