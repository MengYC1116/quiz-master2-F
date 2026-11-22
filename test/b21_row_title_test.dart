// 二十一批（D-244，2026-11-22 11:32 修订：取消 15 字限制，
// 行标题完整显示、自动换行）。
//
// 两层测试：
// 1. widget 层（完整显示 / 高亮）：只用演示库 9 道真题
//    （liveDemoRepo，逐字抄自 live 库），不编新题。
// 2. 纯函数层（回退 / LaTeX / 空白折叠 / 完整显示）：直接测
//    rowDisplayTitle / stripLatexForRow，输入是普通合成字符串
//    （字符串格式化函数的输入，不算模拟题；Question 只作
//    承载 sliceText 的容器，标题用占位字符串）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/wrongbook/wrongbook_page.dart';

import 'b21_content_search_test.dart';
import 'wrongbook_page_test.dart';

/// 格式化探针用的最小 Question：只承载 sliceText 与回退标题。
Question _probe({required String title, required String sliceText}) =>
    Question(
      id: 'fmt-probe',
      title: title,
      subjectId: 'math',
      sliceText: sliceText,
      createdAt: DateTime(2026, 11, 22),
    );

void main() {
  group('二十一批：行标题完整显示（D-244 修订，真题干）', () {
    testWidgets('5 道已整理真题行全是完整题干，不再显示旧标题', (tester) async {
      await pumpWrongbook(tester, repo: liveDemoRepo());
      expect(demoRow('题：lim(x→0) sin 3x / x 的值是（ ）'), findsOneWidget);
      expect(demoRow('题：下图阴影部分由曲线 y = x² 与直线 y = 1 围成。用定积分表示阴影部分的面积，并计算其值。'), findsOneWidget);
      expect(demoRow('题：The new evidence ______ the original hypothesis, forcing the team to revise the whole model.'), findsOneWidget);
      expect(demoRow('题：Figure 1 · Students’ monthly spending (demo chart) Food / Books / Trans / Clothes'), findsOneWidget);
      expect(demoRow('题：运用矛盾普遍性与特殊性的关系，说明如何推进中国式现代化。'), findsOneWidget);
      // 旧标题不再画在行里。
      expect(find.text('函数极限'), findsNothing);
      expect(find.text('定积分阴影面积'), findsNothing);
      expect(find.text('学术词汇辨析'), findsNothing);
      expect(find.text('图表作文'), findsNothing);
      expect(find.text('马原'), findsNothing);
    });

    // 多行题干折叠只在纯函数层测（见下）：5 道已整理真题的题干
    // 全是单行，多行题干的真题（导数/长篇阅读/史纲/材料分析）
    // 都未整理，不进 L1 列表，widget 层测不到。
  });

  group('二十一批：行标题高亮（D-244，真题干）', () {
    testWidgets('搜“阴影”：两处命中字都黄底高亮，行其余文字不高亮', (tester) async {
      await pumpWrongbook(tester, repo: liveDemoRepo());
      await typeSearch(tester, '阴影');
      final rt = tester.widget<RichText>(
        demoRow('题：下图阴影部分由曲线 y = x² 与直线 y = 1 围成。用定积分表示阴影部分的面积，并计算其值。'),
      );
      final spans = (rt.text as TextSpan).children!.whereType<TextSpan>();
      // 完整题干里“阴影”出现两次（阴影部分 / 阴影部分的面积），
      // 旧 15 字截断只露一次；修订后两处都高亮。
      final hits = spans.where((s) => s.text == '阴影').toList();
      expect(hits, hasLength(2));
      expect(
        hits.every(
          (s) => s.style?.backgroundColor == const Color(0xFFFFF1B8),
        ),
        isTrue,
      );
      // 其余 span 无黄底。
      expect(
        spans.where((s) => s.text != '阴影').every(
          (s) => s.style?.backgroundColor != const Color(0xFFFFF1B8),
        ),
        isTrue,
      );
    });
  });

  group('二十一批：行标题纯函数（D-244，合成字符串）', () {
    test('空题干回退标题', () {
      expect(rowDisplayTitle(_probe(title: '占位标题', sliceText: '')), '占位标题');
    });

    test('空白题干回退标题', () {
      expect(
        rowDisplayTitle(_probe(title: '占位标题', sliceText: '  \n\t  ')),
        '占位标题',
      );
    });

    test('只剩公式的题干回退标题', () {
      expect(
        rowDisplayTitle(_probe(title: '占位标题', sliceText: r'$x^2$')),
        '占位标题',
      );
    });

    test('换行与多余空白折成一个空格', () {
      expect(
        rowDisplayTitle(
          _probe(title: '占位标题', sliceText: '题：第一行\n  第二行   第三行'),
        ),
        '题：第一行 第二行 第三行',
      );
    });

    test('长题干完整显示，不截断、不加省略号', () {
      expect(
        rowDisplayTitle(
          _probe(title: '占位标题', sliceText: '123456789012345678901234567890'),
        ),
        '123456789012345678901234567890',
      );
    });

    test('16 字完整显示，不截断', () {
      expect(
        rowDisplayTitle(
          _probe(title: '占位标题', sliceText: '1234567890123456'),
        ),
        '1234567890123456',
      );
    });

    test('长题干含空格也完整显示，空白折叠后原样保留', () {
      expect(
        rowDisplayTitle(
          _probe(title: '占位标题', sliceText: '12345678901234 6789'),
        ),
        '12345678901234 6789',
      );
    });

    test('公式整段去掉、结果里不露 \$', () {
      expect(stripLatexForRow(r'求 $x^2$ 的值'), '求   的值');
      expect(stripLatexForRow(r'$$x^2$$ 保留'), '  保留');
      expect(stripLatexForRow(r'a \(x\) b'), 'a   b');
      expect(stripLatexForRow(r'a \[x\] b'), 'a   b');
      expect(stripLatexForRow('单 \$ 价'), '单  价');
      expect(stripLatexForRow('没有公式'), '没有公式');
    });

    test('行标题：公式去掉后折叠空白，不露 \$', () {
      final shown = rowDisplayTitle(
        _probe(title: '占位标题', sliceText: r'题：设 $f(x)=x^2$，求单调区间'),
      );
      expect(shown.contains('\$'), isFalse);
      expect(shown, '题：设 ，求单调区间');
    });
  });
}
