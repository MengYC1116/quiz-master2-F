// Win11 反馈后续修复 Q1（round 2）：复合段落卡。
//
// StemEditor 把连续 TextBlock + 行内 FormulaBlock（displayMode=false）
// 归并成一张段落卡（[_DraftParagraph]，实现见 stem_editor.dart），
// 底层块顺序不变；分组在行间公式 / 表格 / 标题 / 图块 / 代码 /
// ImageFallback 处断开。
//
// 覆盖：
// - 文字 + 1 个行内公式、文字 + 多个行内公式 → 各一张卡，保存原样拼回；
// - 多段（行间公式隔开）、行内后接行间公式 → 行间公式不断进卡；
// - 图块在段之间 → 卡与图块顺序不变，保存不含图块；
// - 删公式、恢复为原图 → 只动该公式，相邻文字原样保留；
// - 各段文字独立 controller，改一段不碰相邻段；
// - 保存/重开往返；点公式不进文字编辑；代码/标题/表格断开分组。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/modules/ocr/question_content.dart';
import 'package:quiz_master2/modules/ocr/question_content_renderer.dart';
import 'package:quiz_master2/modules/ocr/stem_editor.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';

Question _q(String ocrStem, {Uint8List? sliceBytes}) => Question(
  id: 'q1',
  title: '题 q1',
  subjectId: 'math',
  createdAt: DateTime(2026, 11, 8),
  ocrStem: ocrStem,
);

/// 锚点不可用的图块（anchorSource 'fallback'）：buildContentBlocks
/// 把它默认放到序列末尾。
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
  List<OcrFigure> figures = const [],
  Uint8List? sliceBytes,
  required void Function(String savedStem) onSave,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: StemEditor(
            question: _q(stem, sliceBytes: sliceBytes),
            candidateStem: null,
            sliceBytes: sliceBytes,
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

/// 编辑器里段落卡的数量（按卡 key 计）。
int _paragraphCardCount(WidgetTester tester) => tester
    .widgetList<Container>(
      find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.key.toString().contains('stem-paragraph-card-'),
      ),
    )
    .length;

Finder _textFieldWithText(String text) => find.byWidgetPredicate(
  (w) => w is TextField && (w.controller?.text ?? '') == text,
);

Uint8List _tinyPng() {
  final image = img.Image(width: 10, height: 10);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  return img.encodePng(image);
}

Future<String> _save(WidgetTester tester) async {
  var saved = '';
  // 调用方在 _pumpEditor 里已把 onSave 绑到外部变量；此处直接点保存
  // 按钮、等保存回调写回（测试里用闭包捕获的变量断言）。
  await tester.tap(find.text('保存修改'));
  await tester.pumpAndSettle();
  saved = _lastSavedForTest;
  return saved;
}

// 最近一次保存回调写回的题干（_save 的中转；各测试在 pump 前清零）。
String _lastSavedForTest = '';

void main() {
  group('复合段落卡：分组', () {
    testWidgets('文字 + 1 个行内公式 → 一张卡，保存原样拼回', (tester) async {
      const stem = '在 100 kPa 下，吉布斯自由能\$\\Delta G\$随温度变化';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        onSave: (s) => _lastSavedForTest = s,
      );
      expect(_paragraphCardCount(tester), 1);
      expect(_draftTexts(tester), ['在 100 kPa 下，吉布斯自由能', '随温度变化']);
      expect(find.byType(FormulaView), findsOneWidget);
      expect(await _save(tester), stem);
    });

    testWidgets('文字 + 多个行内公式 → 仍一张卡，各段文字独立', (tester) async {
      const stem = '自由能\$\\Delta G\$和常数\$K_\\mathrm{p}\$随温度变化。';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        onSave: (s) => _lastSavedForTest = s,
      );
      expect(_paragraphCardCount(tester), 1);
      expect(_draftTexts(tester), ['自由能', '和常数', '随温度变化。']);
      expect(find.byType(FormulaView), findsNWidgets(2));
      // 各段文字各持独立 controller（不是一个大 TextField）。
      final controllers = tester
          .widgetList<TextField>(find.byType(TextField))
          .map((w) => w.controller)
          .toList();
      expect(controllers.length, 3);
      expect(identical(controllers[0], controllers[1]), isFalse);
      expect(identical(controllers[1], controllers[2]), isFalse);
      expect(await _save(tester), stem);
    });

    testWidgets('多段：行间公式隔开 → 两张卡，行间公式独立成卡', (tester) async {
      const stem = '第一段 \$a\$ 尾\n\n\$\$b\$\$\n\n第二段 \$c\$ 尾';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        onSave: (s) => _lastSavedForTest = s,
      );
      expect(_paragraphCardCount(tester), 2);
      expect(_draftTexts(tester), ['第一段 ', ' 尾\n\n', '\n\n第二段 ', ' 尾']);
      expect(find.byType(FormulaView), findsNWidgets(3));
      expect(await _save(tester), stem);
    });

    testWidgets('行内公式后接行间公式 → 一张卡 + 一个独立行间公式', (tester) async {
      const stem = '文字 \$x\$ 尾 \$\$y\$\$';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        onSave: (s) => _lastSavedForTest = s,
      );
      expect(_paragraphCardCount(tester), 1);
      expect(_draftTexts(tester), ['文字 ', ' 尾 ']);
      // 行内 1 个 + 行间 1 个；行间公式带自己的删除按钮。
      expect(find.byType(FormulaView), findsNWidgets(2));
      expect(find.text('删除'), findsNWidgets(2));
      expect(await _save(tester), stem);
    });

    testWidgets('图块在段之间：卡在上、图块在下，顺序不变，保存不含图块', (
      tester,
    ) async {
      const stem = '前置 \$x\$ 后置';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        figures: [_fallbackFigure()],
        onSave: (s) => _lastSavedForTest = s,
      );
      expect(_paragraphCardCount(tester), 1);
      expect(find.text('题目配图（图片缺失）'), findsOneWidget);
      final cardTop = tester
          .getTopLeft(find.byKey(const Key('stem-paragraph-card-0')))
          .dy;
      final figureTop = tester
          .getTopLeft(find.text('题目配图（图片缺失）'))
          .dy;
      expect(cardTop, lessThan(figureTop));
      final saved = await _save(tester);
      expect(saved, stem);
    });
  });

  group('复合段落卡：公式动作', () {
    testWidgets('删行内公式：相邻文字原样保留，不合并、不改字', (tester) async {
      const stem = '前 \$x\$ 后';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        onSave: (s) => _lastSavedForTest = s,
      );
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.byType(FormulaView), findsNothing);
      expect(_paragraphCardCount(tester), 1);
      // 两段文字仍在，各自原样（只是公式没了）。
      expect(_draftTexts(tester), ['前 ', ' 后']);
      // 拼回是两段文字的直接拼接，不多不少一个字。
      expect(await _save(tester), '前  后');
      // 再解析只剩一段纯文本。
      expect(
        parseQuestionContent(_lastSavedForTest).map((b) => b.runtimeType),
        [TextBlock],
      );
    });

    testWidgets('删段内唯一公式：整张卡消失，不留空卡', (tester) async {
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: '\$x\$',
        onSave: (s) => _lastSavedForTest = s,
      );
      expect(_paragraphCardCount(tester), 1);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(_paragraphCardCount(tester), 0);
      expect(find.text('还没有识别出的题干，可以直接输入'), findsOneWidget);
      expect(await _save(tester), '');
    });

    testWidgets('行内公式恢复为原图：显示原图，保存后题干里拿掉该公式', (
      tester,
    ) async {
      const stem = '已知 \$x\$ 求解';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        sliceBytes: _tinyPng(),
        onSave: (s) => _lastSavedForTest = s,
      );
      await tester.tap(find.text('恢复为原图'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已恢复为原图'), findsOneWidget);
      expect(find.byType(Image), findsWidgets);
      // 相邻文字不动。
      expect(_draftTexts(tester), ['已知 ', ' 求解']);
      var saved = await _save(tester);
      expect(saved.contains('\$'), isFalse);
      expect(saved.contains('已知'), isTrue);
      expect(saved.contains('求解'), isTrue);
      // 恢复渲染：公式回来，保存又含公式。
      await tester.tap(find.text('恢复渲染'));
      await tester.pumpAndSettle();
      expect(find.byType(FormulaView), findsOneWidget);
      saved = await _save(tester);
      expect(saved, stem);
    });

    testWidgets('点行内公式本身不进文字编辑：文字不变，保存不变', (tester) async {
      const stem = '甲 \$x\$ 乙';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        onSave: (s) => _lastSavedForTest = s,
      );
      await tester.tap(find.byType(FormulaView));
      await tester.pumpAndSettle();
      expect(_draftTexts(tester), ['甲 ', ' 乙']);
      expect(await _save(tester), stem);
    });
  });

  group('复合段落卡：编辑与往返', () {
    testWidgets('改一段文字：只动该段，相邻段与公式原样保留', (tester) async {
      const stem = '甲 \$x\$ 乙 \$y\$ 丙';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        onSave: (s) => _lastSavedForTest = s,
      );
      await tester.enterText(_textFieldWithText('甲 '), '甲改');
      await tester.pumpAndSettle();
      expect(_draftTexts(tester), ['甲改', ' 乙 ', ' 丙']);
      expect(find.byType(FormulaView), findsNWidgets(2));
      expect(await _save(tester), '甲改\$x\$ 乙 \$y\$ 丙');
    });

    testWidgets('保存/重开往返：卡数、文字、公式数都不变', (tester) async {
      const stem = '第一段 \$a\$ 尾\n\n\$\$b\$\$\n\n第二段 \$c\$ 尾';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        onSave: (s) => _lastSavedForTest = s,
      );
      final saved = await _save(tester);
      expect(saved, stem);
      // 重开：用保存后的题干再建一个编辑器。
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: saved,
        onSave: (s) => _lastSavedForTest = s,
      );
      expect(_paragraphCardCount(tester), 2);
      expect(_draftTexts(tester), ['第一段 ', ' 尾\n\n', '\n\n第二段 ', ' 尾']);
      expect(find.byType(FormulaView), findsNWidgets(3));
      expect(await _save(tester), stem);
      // 块序列往返不变（类型与内容）。
      final before = parseQuestionContent(stem);
      final after = parseQuestionContent(_lastSavedForTest);
      expect(after.length, before.length);
      for (var i = 0; i < before.length; i++) {
        expect(after[i].runtimeType, before[i].runtimeType);
      }
    });

    testWidgets('换行/空行原样保留：不 trim、不压空白', (tester) async {
      const stem = '第一行\n第二行 \$x\$ 尾\n\n下一段';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        onSave: (s) => _lastSavedForTest = s,
      );
      expect(_paragraphCardCount(tester), 1);
      expect(_draftTexts(tester), ['第一行\n第二行 ', ' 尾\n\n下一段']);
      expect(await _save(tester), stem);
    });
  });

  group('复合段落卡：分组断开', () {
    testWidgets('代码块断开分组：前后各一张卡', (tester) async {
      const stem = '前 \$x\$ 后\n```python\ncode()\n```\n尾 \$y\$ 末';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        onSave: (s) => _lastSavedForTest = s,
      );
      expect(_paragraphCardCount(tester), 2);
      // 前卡 2 段 + 代码 1 段 + 后卡 2 段。
      expect(_draftTexts(tester), ['前 ', ' 后\n', 'code()\n', '\n尾 ', ' 末']);
      expect(await _save(tester), stem);
    });

    testWidgets('标题断开分组：标题独立成段，后文一张卡', (tester) async {
      const stem = '# 标题\n正文 \$x\$ 尾';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        onSave: (s) => _lastSavedForTest = s,
      );
      expect(_paragraphCardCount(tester), 1);
      expect(_draftTexts(tester), ['# 标题', '正文 ', ' 尾']);
      // A3：标题草稿保存时须与后文断行，不得直接拼接。旧断言只查
      // contains（`'# 标题正文 $x$ 尾'` 也能通过），现锁等值拼回。
      expect(await _save(tester), stem);
    });

    testWidgets('表格断开分组：前后各一张卡，表格独立成段', (tester) async {
      const stem =
          '前 \$x\$ 后\n<table><tr><td>格</td></tr></table>\n尾 \$y\$ 末';
      _lastSavedForTest = '';
      await _pumpEditor(
        tester,
        stem: stem,
        onSave: (s) => _lastSavedForTest = s,
      );
      expect(_paragraphCardCount(tester), 2);
      expect(_draftTexts(tester), [
        '前 ',
        ' 后\n',
        '<table><tr><td>格</td></tr></table>',
        '\n尾 ',
        ' 末',
      ]);
      expect(await _save(tester), stem);
    });
  });
}
