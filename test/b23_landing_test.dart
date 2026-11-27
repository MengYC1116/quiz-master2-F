// 二十三批第 1 件（D-250）：错题本落点三档 + 页头返回按钮（widget 层）。
// 复用 wrongbook_page_test.dart 的 pumpWrongbook / openMathList /
// boardRow 与 b21_content_search_test.dart 的 liveDemoRepo / demoRow。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'b21_content_search_test.dart';
import 'wrongbook_page_test.dart';

void main() {
  group('二十三批：错题本落点三档（D-250）', () {
    testWidgets('都不带：落书架', (tester) async {
      await pumpWrongbook(tester);
      expect(
        find.text('错 题 本'),
        findsWidgets,
      );
      expect(find.byKey(const ValueKey('big-search')), findsNothing);
    });

    testWidgets('只带学科：落目录', (tester) async {
      await pumpWrongbook(tester, initialSubjectId: 'math');
      expect(find.text('数学 · 错题本'), findsOneWidget);
      expect(find.text('返回书架'), findsOneWidget);
      expect(find.text('全部题目'), findsOneWidget);
      expect(find.byKey(const ValueKey('big-search')), findsNothing);
    });

    testWidgets('带错因：直达带筛选列表', (tester) async {
      await pumpWrongbook(
        tester,
        initialSubjectId: 'math',
        filterCause: '概念不清',
      );
      expect(find.text('数学 · 错题本'), findsOneWidget);
      expect(find.text('← 目录'), findsOneWidget);
      expect(find.text('合上 ✕'), findsOneWidget);
      expect(find.text('「概念不清」的结果'), findsOneWidget);
      expect(boardRow('函数极限'), findsOneWidget);
      expect(boardRow('导数综合'), findsNothing);
    });

    testWidgets('带知识点：直达带筛选列表', (tester) async {
      await pumpWrongbook(
        tester,
        repo: liveDemoRepo(),
        initialSubjectId: 'math',
        filterKnowledgePointId: 'kp-math-limit',
      );
      expect(find.text('← 目录'), findsOneWidget);
      expect(find.text('合上 ✕'), findsOneWidget);
      expect(
        demoRow('题：lim(x→0) sin 3x / x 的值是（ ）'),
        findsOneWidget,
      );
      expect(
        demoRow('题：下图阴影部分由曲线 y = x² 与直线 y = 1 围成。用定积分表示阴影部分的面积，并计算其值。'),
        findsNothing,
      );
    });
  });

  group('二十三批：列表页头返回按钮（D-250）', () {
    testWidgets('「← 目录」：有学科回目录', (tester) async {
      await pumpWrongbook(tester);
      await openMathList(tester);
      // 走查 P4：有学科时页头按钮说“← 目录”、不说“← 书架”。
      expect(find.text('← 目录'), findsOneWidget);
      expect(find.text('← 书架'), findsNothing);
      await tester.tap(find.text('← 目录'));
      await tester.pumpAndSettle();
      expect(find.text('数学 · 错题本'), findsOneWidget);
      expect(find.text('全部题目'), findsOneWidget);
      expect(find.byKey(const ValueKey('big-search')), findsNothing);
    });

    testWidgets('「合上 ✕」回书架', (tester) async {
      await pumpWrongbook(tester);
      await openMathList(tester);
      await tester.tap(find.text('合上 ✕'));
      await tester.pumpAndSettle();
      expect(
        find.text('错 题 本'),
        findsWidgets,
      );
    });

    testWidgets('无学科列表「← 书架」回书架', (tester) async {
      // 带错因但不带学科 → 列表，subjectId 为空 → 页头按钮说“← 书架”、
      // 点后回书架（走查 P4：标签跟实际去向走，不再说“← 目录”）。
      await pumpWrongbook(tester, filterCause: '概念不清');
      expect(find.text('错题本'), findsOneWidget);
      expect(find.text('← 书架'), findsOneWidget);
      expect(find.text('← 目录'), findsNothing);
      await tester.tap(find.text('← 书架'));
      await tester.pumpAndSettle();
      expect(
        find.text('错 题 本'),
        findsWidgets,
      );
    });

    testWidgets('目录「返回书架」回书架', (tester) async {
      await pumpWrongbook(tester, initialSubjectId: 'math');
      await tester.tap(find.text('返回书架'));
      await tester.pumpAndSettle();
      expect(
        find.text('错 题 本'),
        findsWidgets,
      );
    });
  });
}
