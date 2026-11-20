// WP-C #6（九项修复 REV5）：HTML 表格与标题渲染回归测试。
//
// 定稿：`~/workspace/batch14-work/FIX-DESIGN-9-ISSUES.md`
// §6.3 + 附录 R4（REV2）+ S3-1/S7（REV3）+ T5/T7（REV4）+ U4（REV5）。
// 覆盖：§6.3 全部用例、R4-4 补充用例、S3-1 组合测试、U4-1/U4-3
// 占位符与实体/空白规则、渲染层（Table/Heading/居中/上下标）。
//
// 运行（只跑本文件，不跑全量）：
// TMPDIR=$HOME/workspace/flutter-test-tmp \
// LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux \
// flutter test --concurrency=1 test/wp_c6_html_table_heading_test.dart

import 'package:flutter/material.dart' hide TableCell;
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/modules/ocr/question_content.dart';
import 'package:quiz_master2/modules/ocr/question_content_renderer.dart';
import 'package:quiz_master2/services/stem_splitter.dart';

/// 单元格内全部文字（TextBlock 原文；公式还原成 `$...$` 形式）。
String cellText(TableCell cell) {
  final buf = StringBuffer();
  for (final c in cell.children) {
    switch (c) {
      case TextBlock(:final text):
        buf.write(text);
      case FormulaBlock(:final latex, :final displayMode):
        buf.write(displayMode ? '\$\$$latex\$\$' : '\$$latex\$');
      case CodeBlock(:final code):
        buf.write(code);
      case ImageFallbackBlock():
        break;
      case FigureBlock():
        break;
      case TableBlock():
        break;
      case HeadingBlock(:final text):
        buf.write(text);
    }
  }
  return buf.toString();
}

/// 全部块的文字拼接（表格/标题也展平，便于“不丢字”断言）。
String blocksText(List<QuestionContentBlock> blocks) {
  final buf = StringBuffer();
  for (final b in blocks) {
    switch (b) {
      case TextBlock(:final text):
        buf.write(text);
      case FormulaBlock(:final latex, :final displayMode):
        buf.write(displayMode ? '\$\$$latex\$\$' : '\$$latex\$');
      case CodeBlock(:final code):
        buf.write(code);
      case ImageFallbackBlock():
        break;
      case FigureBlock():
        break;
      case TableBlock(:final rows):
        for (final r in rows) {
          for (final c in r) {
            buf.write(cellText(c));
          }
        }
      case HeadingBlock(:final text):
        buf.write(text);
    }
  }
  return buf.toString();
}

/// 某单元格内全部文本 run（含无样式 run）。
List<TextRun> cellRuns(TableCell cell) {
  final out = <TextRun>[];
  for (final c in cell.children) {
    if (c is TextBlock) {
      out.addAll(c.runs ?? [TextRun(c.text)]);
    }
  }
  return out;
}

/// 全部块内全部文本 run。
List<TextRun> blocksRuns(List<QuestionContentBlock> blocks) {
  final out = <TextRun>[];
  for (final b in blocks) {
    if (b is TextBlock) {
      out.addAll(b.runs ?? [TextRun(b.text)]);
    }
  }
  return out;
}

/// 单元格文字在 RichText 里（find.text 只认 Text），按 plain text 找。
Finder findRichText(String text) => find.byWidgetPredicate(
  (w) => w is RichText && w.text.toPlainText() == text,
);

Finder findRichTextContaining(String text) => find.byWidgetPredicate(
  (w) => w is RichText && w.text.toPlainText().contains(text),
);

void main() {
  group('§6.3 核心用例', () {
    test('6.3-1 <table> 两行四列 → 2×4 表格，单元格文字正确', () {
      const input =
          '<table><tr><td>A</td><td>甲</td><td>B</td><td>乙</td></tr>'
          '<tr><td>C</td><td>丙</td><td>D</td><td>丁</td></tr></table>';
      final blocks = parseQuestionContent(input);
      expect(blocks.length, 1);
      final table = blocks.single as TableBlock;
      expect(table.rows.length, 2);
      expect(table.rows[0].length, 4);
      expect(table.rows[1].length, 4);
      expect(cellText(table.rows[0][0]), 'A');
      expect(cellText(table.rows[0][1]), '甲');
      expect(cellText(table.rows[0][3]), '乙');
      expect(cellText(table.rows[1][0]), 'C');
      expect(cellText(table.rows[1][3]), '丁');
    });

    test('6.3-2 单元格内 \$…\$ 公式正常渲染为公式块', () {
      final blocks = parseQuestionContent(
        r'<table><tr><td>$x^2$</td><td>文字</td></tr></table>',
      );
      final table = blocks.single as TableBlock;
      final first = table.rows[0][0].children.single;
      expect(first, isA<FormulaBlock>());
      expect((first as FormulaBlock).latex, r'x^2');
      expect((first).displayMode, isFalse);
      expect(cellText(table.rows[0][1]), '文字');
    });

    test('6.3-3 <div align="center"><table> → 居中表格，不显示源码', () {
      final blocks = parseQuestionContent(
        '<div align="center"><table><tr><td>甲</td></tr></table></div>',
      );
      expect(blocks.length, 1);
      final table = blocks.single as TableBlock;
      expect(table.centered, isTrue);
      expect(cellText(table.rows[0][0]), '甲');
      expect(blocksText(blocks), isNot(contains('div')));
      expect(blocksText(blocks), isNot(contains('table')));
    });

    test('6.3-4 ## 5. → 标题块；正文中间的 #（C#）保留原文', () {
      final headed = parseQuestionContent('## 5. 下列说法正确的是');
      expect(headed.length, 1);
      final heading = headed.single as HeadingBlock;
      expect(heading.level, 2);
      expect(heading.text, '5. 下列说法正确的是');

      final plain = parseQuestionContent('语言 C# 与 C++ #保留');
      expect(plain.whereType<HeadingBlock>(), isEmpty);
      expect((plain.single as TextBlock).text, contains('C#'));
    });

    test('6.3-5 未闭合 <table><tr><td>甲 → 回退纯文本，不丢字、不崩溃', () {
      final blocks = parseQuestionContent('<table><tr><td>甲');
      expect(blocks.whereType<TableBlock>(), isEmpty);
      expect(blocksText(blocks), contains('甲'));
      expect(blocksText(blocks), isNot(contains('<table>')));

      final blocks2 = parseQuestionContent('<table><tr><td>甲</td></tr>');
      expect(blocks2.whereType<TableBlock>(), isEmpty);
      expect(blocksText(blocks2), contains('甲'));
    });

    test('6.3-6 colspan=2 → 内容在首格，次格留空', () {
      final blocks = parseQuestionContent(
        '<table><tr><td colspan="2">甲</td><td>乙</td></tr></table>',
      );
      final table = blocks.single as TableBlock;
      expect(table.rows[0].length, 3);
      expect(cellText(table.rows[0][0]), '甲');
      expect(table.rows[0][0].colspan, 2);
      expect(table.rows[0][1].children, isEmpty);
      expect(cellText(table.rows[0][2]), '乙');
    });

    test('6.3-7 表格前后普通 Markdown 内容 → 顺序正确', () {
      final blocks = parseQuestionContent(
        r'前文 $x$ 之后' '\n<table><tr><td>甲</td></tr></table>\n后文',
      );
      expect(blocks.length, 5);
      expect(blocks[0], isA<TextBlock>());
      expect((blocks[0] as TextBlock).text, '前文 ');
      expect(blocks[1], isA<FormulaBlock>());
      expect((blocks[1] as FormulaBlock).latex, 'x');
      expect(blocks[2], isA<TextBlock>());
      expect((blocks[2] as TextBlock).text, ' 之后\n');
      expect(blocks[3], isA<TableBlock>());
      expect(blocks[4], isA<TextBlock>());
      expect((blocks[4] as TextBlock).text, '\n后文');
    });
  });

  group('R4-4 补充用例', () {
    test('R4-4-1 fenced 代码内含完整 <table> 仍按代码显示', () {
      final blocks = parseQuestionContent(
        '```html\n<table><tr><td>甲</td></tr></table>\n```',
      );
      expect(blocks.whereType<TableBlock>(), isEmpty);
      expect(blocks.whereType<FormulaBlock>(), isEmpty);
      final code = blocks.whereType<CodeBlock>().single;
      expect(code.language, 'html');
      expect(code.code, contains('<table>'));
    });

    test('R4-4-2 单元格同时含普通文字、粗体、公式与上下标', () {
      final blocks = parseQuestionContent(
        r'<table><tr><td>甲 <strong>乙</strong> $x$ <sup>2</sup> <sub>1</sub></td></tr></table>',
      );
      final table = blocks.single as TableBlock;
      final cell = table.rows[0][0];
      expect(
        cell.children.whereType<FormulaBlock>().single.latex,
        'x',
      );
      final runs = cellRuns(cell);
      expect(runs.any((r) => r.text == '乙' && r.bold), isTrue);
      expect(runs.any((r) => r.text == '2' && r.script == 1), isTrue);
      expect(runs.any((r) => r.text == '1' && r.script == -1), isTrue);
      expect(cellText(cell), contains('甲'));
    });

    test('R4-4-3 未知标签嵌套在已知标签内、内部文字不丢失', () {
      final inP = parseQuestionContent('<p>甲<unknown>乙</unknown>丙</p>');
      expect(blocksText(inP), '甲乙丙');

      final inCell = parseQuestionContent(
        '<table><tr><td><foo>甲<bar>乙</bar></foo></td></tr></table>',
      );
      final table = inCell.single as TableBlock;
      expect(cellText(table.rows[0][0]), '甲乙');
    });

    test('R4-4-4 同一段出现两个独立表格', () {
      final blocks = parseQuestionContent(
        '<table><tr><td>一</td></tr></table>中间'
        '<table><tr><td>二</td></tr></table>',
      );
      expect(blocks.length, 3);
      expect(blocks[0], isA<TableBlock>());
      expect((blocks[1] as TextBlock).text, '中间');
      expect(blocks[2], isA<TableBlock>());
      expect(
        cellText((blocks[0] as TableBlock).rows[0][0]),
        '一',
      );
      expect(
        cellText((blocks[2] as TableBlock).rows[0][0]),
        '二',
      );
    });

    test('R4-4-5 空单元格、缺失单元格、不规则行列', () {
      final blocks = parseQuestionContent(
        '<table><tr><td></td><td>甲</td></tr>'
        '<tr><td>乙</td></tr>'
        '<tr><td>丙</td><td>丁</td><td>戊</td></tr></table>',
      );
      final table = blocks.single as TableBlock;
      expect(table.rows.length, 3);
      for (final row in table.rows) {
        expect(row.length, 3);
      }
      expect(table.rows[0][0].children, isEmpty);
      expect(cellText(table.rows[0][1]), '甲');
      expect(cellText(table.rows[1][0]), '乙');
      expect(table.rows[1][1].children, isEmpty);
      expect(table.rows[1][2].children, isEmpty);
      expect(cellText(table.rows[2][0]), '丙');
      expect(cellText(table.rows[2][1]), '丁');
      expect(cellText(table.rows[2][2]), '戊');
    });

    testWidgets('R4-4-6 表格前后有图片块：渲染顺序 图—表—图',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: QuestionContentRenderer(
                blocks: [
                  const FigureBlock(
                      figureId: 'f1', cropPath: 'missing/f1.png'),
                  TableBlock([
                    [const TableCell(children: [TextBlock('甲')])],
                  ]),
                  const FigureBlock(
                      figureId: 'f2', cropPath: 'missing/f2.png'),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 两个“图片缺失”占位夹住表格单元格文字（Text 与 RichText 都按
      // 文档顺序收集：图占位是 Text，单元格文字在 RichText 里）。
      final texts = tester
          .elementList(
            find.byWidgetPredicate((w) => w is Text || w is RichText),
          )
          .map((e) {
            final w = e.widget;
            if (w is Text) return w.data ?? '';
            return (w as RichText).text.toPlainText();
          })
          .toList();
      final firstFigure = texts.indexOf('题目配图（图片缺失）');
      final cell = texts.indexOf('甲');
      final secondFigure = texts.lastIndexOf('题目配图（图片缺失）');
      expect(firstFigure, isNot(-1));
      expect(cell, isNot(-1));
      expect(secondFigure, isNot(-1));
      expect(firstFigure, lessThan(cell));
      expect(cell, lessThan(secondFigure));
    });

    test('R4-4-7 HTML 标签大小写不同、属性单引号', () {
      final upper = parseQuestionContent(
        '<TABLE BORDER="1"><TR><TD>甲</TD></TR></TABLE>',
      );
      expect(upper.single, isA<TableBlock>());
      expect(
        cellText((upper.single as TableBlock).rows[0][0]),
        '甲',
      );

      final center = parseQuestionContent(
        '<DIV ALIGN="center"><TABLE><TR><TD>甲</TD></TR></TABLE></DIV>',
      );
      expect((center.single as TableBlock).centered, isTrue);

      final singleQuote = parseQuestionContent(
        "<table><tr><td colspan='2'>甲</td><td>乙</td></tr></table>",
      );
      final table = singleQuote.single as TableBlock;
      expect(table.rows[0][0].colspan, 2);
      expect(table.rows[0].length, 3);
    });

    test('R4-4-8 单元格内出现 <br> 与多个 <p>', () {
      final blocks = parseQuestionContent(
        '<table><tr><td>甲<br>乙<p>丙</p><p>丁</p></td></tr></table>',
      );
      final table = blocks.single as TableBlock;
      final children = table.rows[0][0].children;
      expect(children.length, 3);
      expect((children[0] as TextBlock).text, '甲\n乙');
      expect((children[1] as TextBlock).text, '丙');
      expect((children[2] as TextBlock).text, '丁');
    });

    test('R4-4-9 嵌套表格展平成纯文本，不丢字、不产生嵌套表', () {
      final blocks = parseQuestionContent(
        '<table><tr><td>外<table><tr><td>内1</td><td>内2</td></tr>'
        '<tr><td>内3</td></tr></table>后</td></tr></table>',
      );
      expect(blocks.whereType<TableBlock>().length, 1);
      final table = blocks.single as TableBlock;
      expect(table.rows.length, 1);
      final text = cellText(table.rows[0][0]);
      expect(text, '外内1 内2\n内3后');
    });

    test('R4-4-10 错误嵌套按规定回退、不产生部分内容丢失', () {
      // <td> 未闭合即被 </tr> 关闭：整表回退为纯文本。
      final mismatched = parseQuestionContent(
        '<table><tr><td>甲</tr></table>',
      );
      expect(mismatched.whereType<TableBlock>(), isEmpty);
      expect(blocksText(mismatched), contains('甲'));

      // <div> 未闭合：整段回退，表内文字仍在。
      final openDiv = parseQuestionContent(
        '<div><table><tr><td>甲</td></tr></table>',
      );
      expect(openDiv.whereType<TableBlock>(), isEmpty);
      expect(blocksText(openDiv), contains('甲'));

      // 结构异常：tr 下直接出现文字，整表回退。
      final badRow = parseQuestionContent(
        '<table><tr>甲<td>乙</td></tr></table>',
      );
      expect(badRow.whereType<TableBlock>(), isEmpty);
      expect(blocksText(badRow), contains('甲'));
      expect(blocksText(badRow), contains('乙'));
    });
  });

  group('S3-1 组合测试（与 splitStem 共用优先级）', () {
    test('S3-1 代码块内含 \$A\$ 与 <table>：两路径一致处理', () {
      const input =
          '```\n\$A\$ 与 <table><tr><td>x</td></tr></table>\n```';
      final blocks = parseQuestionContent(input);
      expect(blocks.whereType<TableBlock>(), isEmpty);
      expect(blocks.whereType<FormulaBlock>(), isEmpty);
      expect(blocks.whereType<CodeBlock>().length, 1);

      final split = splitStem(input);
      expect(split.status, StemSplitStatus.notSplit);
    });

    test('S3-1 行内代码含 <table> 与公式：按字面文本保留', () {
      final blocks = parseQuestionContent(
        r'甲 `含 <table> 与 $x$ 的代码` 乙',
      );
      expect(blocks.whereType<TableBlock>(), isEmpty);
      expect(blocks.whereType<FormulaBlock>(), isEmpty);
      expect(blocks.length, 1);
      final text = (blocks.single as TextBlock).text;
      expect(text, contains('<table>'));
      expect(text, contains(r'$x$'));
    });
  });

  group('U4-1/U4-3 占位符、实体与空白', () {
    test('U4-3 实体解码：命名、数字引用、非法值 → U+FFFD', () {
      final blocks = parseQuestionContent(
        '甲 &amp; 乙 &#65;&#x42; &nbsp;丙 &#xD800; &#99999999;',
      );
      final text = blocksText(blocks);
      expect(text, contains('甲 & 乙'));
      expect(text, contains('AB'));
      expect(text, contains('丙'));
      expect('�'.allMatches(text).length, 2);
    });

    test('U4-3 &lt; 编码的表格按解码后结构解析（解码先于结构解析）', () {
      final blocks = parseQuestionContent(
        '&lt;table&gt;&lt;tr&gt;&lt;td&gt;甲&lt;/td&gt;&lt;/tr&gt;'
        '&lt;/table&gt;',
      );
      expect(blocks.single, isA<TableBlock>());
      expect(
        cellText((blocks.single as TableBlock).rows[0][0]),
        '甲',
      );
    });

    test('U4-3 &nbsp; 转为空格', () {
      final blocks = parseQuestionContent('甲&nbsp;乙');
      expect(blocksText(blocks), '甲 乙');
    });

    test('U4-1/T5-2 异常回退中代码占位符原样保留', () {
      final blocks = parseQuestionContent(
        r'<table><tr><td>`$x$` 甲</td>',
      );
      expect(blocks.whereType<TableBlock>(), isEmpty);
      expect(blocks.whereType<FormulaBlock>(), isEmpty);
      final text = blocksText(blocks);
      expect(text, contains(r'`$x$`'));
      expect(text, contains('甲'));
    });

    test('U4-3 HTML 内连续空白折叠、无连续空行', () {
      final blocks = parseQuestionContent(
        '<table><tr><td>甲   乙\n\n 丙</td></tr></table>',
      );
      final table = blocks.single as TableBlock;
      expect(cellText(table.rows[0][0]), '甲 乙 丙');

      final div = parseQuestionContent('<div><p>甲</p>  <p>乙</p></div>');
      expect(div.length, 2);
      expect((div[0] as TextBlock).text, '甲');
      expect((div[1] as TextBlock).text, '乙');
    });

    test('U4-1 行内反引号与围栏块重叠时围栏优先（与 splitStem 同款守卫）', () {
      // 行内段 `a 从 0 起、止于围栏块的开围栏内，与 fenced span 重叠；
      // 收集时即跳过重叠的行内匹配，围栏块整体受保护，其内的表格不渲染。
      final blocks = parseQuestionContent(
        '`a ```\n<table><tr><td>甲</td></tr></table>\n```',
      );
      expect(blocks.whereType<TableBlock>(), isEmpty);
      expect(blocks.whereType<CodeBlock>().length, 1);
    });
  });

  group('标题', () {
    test('行首 # / ## / ### → 1–3 级标题块', () {
      final blocks = parseQuestionContent('# 一级\n## 二级\n### 三级');
      expect(blocks.length, 3);
      expect((blocks[0] as HeadingBlock).level, 1);
      expect((blocks[0] as HeadingBlock).text, '一级');
      expect((blocks[1] as HeadingBlock).level, 2);
      expect((blocks[1] as HeadingBlock).text, '二级');
      expect((blocks[2] as HeadingBlock).level, 3);
      expect((blocks[2] as HeadingBlock).text, '三级');
    });

    test('#### 不成标题；行中 ## 不成标题', () {
      expect(parseQuestionContent('#### 四级').whereType<HeadingBlock>(),
          isEmpty);
      expect(
        parseQuestionContent('前文 ## 不是标题').whereType<HeadingBlock>(),
        isEmpty,
      );
      expect(blocksText(parseQuestionContent('#### 四级')), contains('####'));
    });

    test('标题内联 HTML 展平为标题文字', () {
      final blocks = parseQuestionContent('## 5. <strong>重点</strong>内容');
      expect(blocks.length, 1);
      final heading = blocks.single as HeadingBlock;
      expect(heading.level, 2);
      expect(heading.text, '5. 重点内容');
      expect(blocksText(blocks), isNot(contains('<strong>')));
    });

    test('div 内的行首标题同样识别', () {
      final blocks = parseQuestionContent('<div>\n## 标题\n后文</div>');
      expect(blocks.length, 2);
      expect((blocks[0] as HeadingBlock).text, '标题');
      expect((blocks[1] as TextBlock).text, '后文');
    });
  });

  group('行内样式与块边界', () {
    test('<br> = 当前块内换行；<p> = 段落边界', () {
      final br = parseQuestionContent('甲<br>乙');
      expect(br.length, 1);
      expect((br.single as TextBlock).text, '甲\n乙');

      final ps = parseQuestionContent('<p>第一段</p><p>第二段</p>');
      expect(ps.length, 2);
      expect((ps[0] as TextBlock).text, '第一段');
      expect((ps[1] as TextBlock).text, '第二段');

      final mixed = parseQuestionContent('<p>甲</p>乙<p>丙</p>');
      expect(mixed.length, 3);
      expect((mixed[0] as TextBlock).text, '甲');
      expect((mixed[1] as TextBlock).text, '乙');
      expect((mixed[2] as TextBlock).text, '丙');
    });

    test('strong/b → 粗体 run；em/i → 斜体 run', () {
      final blocks = parseQuestionContent('<strong>粗</strong>与<em>斜</em>');
      expect(blocks.length, 1);
      final runs = blocksRuns(blocks);
      expect(runs.any((r) => r.text == '粗' && r.bold), isTrue);
      expect(runs.any((r) => r.text == '与' && !r.bold && !r.italic),
          isTrue);
      expect(runs.any((r) => r.text == '斜' && r.italic), isTrue);
    });

    test('sup/sub → 上下标 run', () {
      final blocks =
          parseQuestionContent(r'x<sup>2</sup>与x<sub>1</sub>');
      final runs = blocksRuns(blocks);
      expect(runs.any((r) => r.text == '2' && r.script == 1), isTrue);
      expect(runs.any((r) => r.text == '1' && r.script == -1), isTrue);
    });

    test('span 剥标签保留文字，属性忽略', () {
      final blocks =
          parseQuestionContent('<span style="color:red">甲</span>');
      expect(blocks.length, 1);
      expect((blocks.single as TextBlock).text, '甲');
    });

    test('未知标签剥掉标签、保留内部文字', () {
      final blocks = parseQuestionContent('甲<foo>乙</foo>丙');
      expect(blocks.length, 1);
      expect((blocks.single as TextBlock).text, '甲乙丙');
    });

    test('div 为容器：内容直通，段落顺序正确', () {
      final blocks = parseQuestionContent('<div>甲<p>乙</p></div>丙');
      expect(blocks.length, 3);
      expect((blocks[0] as TextBlock).text, '甲');
      expect((blocks[1] as TextBlock).text, '乙');
      expect((blocks[2] as TextBlock).text, '丙');
    });

    test('div align 非 center 时不居中；未知属性忽略', () {
      final left = parseQuestionContent(
        '<div align="left"><table><tr><td>甲</td></tr></table></div>',
      );
      expect((left.single as TableBlock).centered, isFalse);

      final unknownAttr = parseQuestionContent(
        '<div data-x="1"><table><tr><td>甲</td></tr></table></div>',
      );
      expect(unknownAttr.single, isA<TableBlock>());
    });
  });

  group('colspan / rowspan', () {
    test('rowspan=2 → 内容在首行，次行同列留空', () {
      final blocks = parseQuestionContent(
        '<table><tr><td rowspan="2">甲</td><td>乙</td></tr>'
        '<tr><td>丙</td></tr></table>',
      );
      final table = blocks.single as TableBlock;
      expect(table.rows.length, 2);
      expect(cellText(table.rows[0][0]), '甲');
      expect(table.rows[0][0].rowspan, 2);
      expect(cellText(table.rows[0][1]), '乙');
      expect(table.rows[1][0].children, isEmpty);
      expect(cellText(table.rows[1][1]), '丙');
    });

    test('非法 colspan/rowspan → 1', () {
      final bad = parseQuestionContent(
        '<table><tr><td colspan="abc">甲</td><td>乙</td></tr></table>',
      );
      final table = bad.single as TableBlock;
      expect(table.rows[0][0].colspan, 1);
      expect(table.rows[0].length, 2);

      final zero = parseQuestionContent(
        '<table><tr><td colspan="0">甲</td><td>乙</td></tr></table>',
      );
      expect((zero.single as TableBlock).rows[0][0].colspan, 1);
    });

    test('th 与 thead/tbody 正常解析', () {
      final blocks = parseQuestionContent(
        '<table><thead><tr><th>表头</th><th>H2</th></tr></thead>'
        '<tbody><tr><td>甲</td><td>乙</td></tr></tbody></table>',
      );
      final table = blocks.single as TableBlock;
      expect(table.rows.length, 2);
      expect(cellText(table.rows[0][0]), '表头');
      expect(cellText(table.rows[1][1]), '乙');
    });
  });

  group('拼回往返', () {
    test('表格 + 标题：解析→拼回→再解析，结构不变', () {
      final first = parseQuestionContent(
        r'<table><tr><td>甲 $x$</td><td>乙</td></tr></table>' '\n## 5. 标题',
      );
      expect(first.length, 2);
      final rebuilt = blocksToMarkdown(first);
      final second = parseQuestionContent(rebuilt);
      expect(second.length, 2);
      final table = second[0] as TableBlock;
      expect(table.rows.length, 1);
      expect(table.rows[0].length, 2);
      expect(cellText(table.rows[0][0]), '甲 \$x\$');
      expect(
        table.rows[0][0].children.whereType<FormulaBlock>().single.latex,
        'x',
      );
      expect(cellText(table.rows[0][1]), '乙');
      expect((second[1] as HeadingBlock).level, 2);
      expect((second[1] as HeadingBlock).text, '5. 标题');
    });
  });

  group('渲染层', () {
    testWidgets('TableBlock 渲染为 Flutter Table，单元格文字可见',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: QuestionContentRenderer(
                blocks: [
                  TableBlock([
                    [
                      const TableCell(children: [TextBlock('甲')]),
                      const TableCell(children: [TextBlock('乙')]),
                    ],
                    [
                      const TableCell(children: [TextBlock('丙')]),
                      const TableCell(children: [TextBlock('丁')]),
                    ],
                  ]),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Table), findsOneWidget);
      expect(findRichText('甲'), findsOneWidget);
      expect(findRichText('丁'), findsOneWidget);
    });

    testWidgets('HeadingBlock 按级别字号渲染', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuestionContentRenderer(
              blocks: const [
                HeadingBlock('一级标题', 1),
                HeadingBlock('二级标题', 2),
                HeadingBlock('三级标题', 3),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      TextStyle? styleOf(String text) =>
          tester.widget<Text>(find.text(text)).style;
      expect(styleOf('一级标题')?.fontSize, 20);
      expect(styleOf('二级标题')?.fontSize, 18);
      expect(styleOf('三级标题')?.fontSize, 16);
      expect(styleOf('一级标题')?.fontWeight, FontWeight.bold);
    });

    testWidgets('居中表格包在 Center 里；非居中表格不包', (tester) async {
      Future<void> pump(List<QuestionContentBlock> blocks) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: QuestionContentRenderer(blocks: blocks),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pump([
        TableBlock([
          [const TableCell(children: [TextBlock('甲')])],
        ], centered: true),
      ]);
      expect(find.byType(Center), findsWidgets);

      await pump([
        TableBlock([
          [const TableCell(children: [TextBlock('甲')])],
        ]),
      ]);
      expect(find.byType(Center), findsNothing);
    });

    testWidgets('长文本单元格自动换行、不溢出', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: QuestionContentRenderer(
                blocks: [
                  TableBlock([
                    [
                      const TableCell(children: [TextBlock('甲')]),
                      TableCell(
                        children: [TextBlock('长文' * 60)],
                      ),
                    ],
                  ]),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(findRichTextContaining('长文'), findsOneWidget);
    });

    testWidgets('上下标 run 渲染不报错', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuestionContentRenderer(
              blocks: const [
                TextBlock(
                  'x2',
                  runs: [
                    TextRun('x'),
                    TextRun('2', script: 1),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('空表格不崩溃', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuestionContentRenderer(
              blocks: const [TableBlock([])],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Table), findsNothing);
    });
  });

  group('边界与既有行为', () {
    test('空输入 → 空列表；纯文本无 HTML 时保持原样', () {
      expect(parseQuestionContent(''), isEmpty);
      final blocks = parseQuestionContent('第一行\n第二行');
      expect(blocks.length, 1);
      expect((blocks.single as TextBlock).text, '第一行\n第二行');
    });

    test(r'单元格内独立公式 $$…$$ 仍为独立公式块', () {
      final blocks = parseQuestionContent(
        r'<table><tr><td>$$x=1$$</td></tr></table>',
      );
      final table = blocks.single as TableBlock;
      final formula =
          table.rows[0][0].children.single as FormulaBlock;
      expect(formula.displayMode, isTrue);
      expect(formula.latex, 'x=1');
    });

    test('多处异常 HTML 不抛异常、不丢字', () {
      final blocks = parseQuestionContent('<table><div><p><strong>甲');
      expect(blocksText(blocks), contains('甲'));
      expect(blocks.whereType<TableBlock>(), isEmpty);
    });

    test('空表格解析为零行表块', () {
      final blocks = parseQuestionContent('<table></table>');
      expect(blocks.length, 1);
      expect((blocks.single as TableBlock).rows, isEmpty);
    });

    test('居中 div 只含文字时文字保留（文本本身无居中表示）', () {
      final blocks = parseQuestionContent('<div align="center">甲</div>');
      expect(blocksText(blocks), '甲');
    });
  });
}
