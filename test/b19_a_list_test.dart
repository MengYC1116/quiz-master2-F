// 十九批 A：L1 默认落点、命令面板、保存查找（widget 层）。
// 复用 wrongbook_page_test.dart 的 pumpWrongbook / threeSubjectRepo /
// boardRow（同仓已成惯例：b11_6 亦从该文件 import helper）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';

import 'wrongbook_page_test.dart';

void main() {
  group('十九批 A：L1 落点与查找', () {
    testWidgets('默认落点：不带参数进书架（二十三批 D-250）', (tester) async {
      await pumpWrongbook(tester);
      // 二十三批 D-250：默认落点恢复书架，L1 大搜索框与「全部题目」
      // 在列表页，不在书架上。
      expect(find.text('错题本'), findsOneWidget);
      expect(
        find.text('一科一本错题本，点一本打开看这一科的错题。'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('big-search')), findsNothing);
      expect(find.text('全部题目'), findsNothing);
      // 书架 → 目录 → 列表后才是 L1。
      await openMathList(tester);
      expect(find.text('全部题目'), findsOneWidget);
      expect(boardRow('函数极限'), findsOneWidget);
      expect(boardRow('阅读主旨'), findsNothing);
    });

    testWidgets('只带学科：落到该学科目录（二十三批 D-250）', (tester) async {
      await pumpWrongbook(tester, initialSubjectId: 'math');
      // 二十三批 D-250：只带学科落目录，页头标题恢复。
      expect(find.text('数学 · 错题本'), findsOneWidget);
      expect(find.text('全部题目'), findsOneWidget);
      expect(find.byKey(const ValueKey('big-search')), findsNothing);
      // 点「全部题目」进按该学科筛选的列表。
      await openSubjectList(tester);
      expect(boardRow('函数极限'), findsOneWidget);
      expect(boardRow('导数综合'), findsOneWidget);
      expect(boardRow('定积分'), findsOneWidget);
      expect(boardRow('阅读主旨'), findsNothing);
      expect(boardRow('图表作文'), findsNothing);
    });

    testWidgets('命令面板：点范围说明行的 Ctrl+K kbd 呼出，点文件夹应用', (tester) async {
      await pumpWrongbook(tester);
      // 二十三批 D-250：默认落点是书架，命令面板在列表页，先进列表。
      await openMathList(tester);
      // 二十一批 D-242：大搜索框里的深色 Ctrl+K kbd 已去掉，
      // 页面上只剩范围说明行里的一对浅色 kbd。
      expect(find.text('Ctrl'), findsOneWidget);
      expect(find.text('K'), findsOneWidget);
      await tester.tap(find.text('Ctrl').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('command-palette')), findsOneWidget);
      // 二十一批 D-241：旧“只搜元数据”全站消失（含命令面板 placeholder）。
      expect(find.textContaining('只搜元数据'), findsNothing);
      expect(find.text('文件夹'), findsOneWidget);
      // 两个「📁 试卷」（数学 f1 在前、英语 f3 在后），点第一个进 f1。
      await tester.tap(find.text('📁 试卷').first);
      await tester.pump();
      expect(find.text('已用命令面板打开查找：试卷'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('command-palette')), findsNothing);
      // 二十三批 D-250：页头恢复，文件夹范围以页头标题呈现。
      expect(find.text('数学 · 试卷'), findsOneWidget);
      expect(boardRow('函数极限'), findsOneWidget);
      expect(boardRow('定积分'), findsOneWidget);
      expect(boardRow('导数综合'), findsNothing);
      expect(boardRow('阅读主旨'), findsNothing);
    });

    testWidgets('我的查找：saved chip 点按应用条件 + toast', (tester) async {
      final repo = threeSubjectRepo();
      repo.savedSearchList.add(
        SavedSearch(
          id: 'ss1',
          name: '概念不清题',
          conditions: const {'cause': '概念不清'},
          createdAt: DateTime(2026, 11, 19),
        ),
      );
      await pumpWrongbook(tester, repo: repo);
      // 二十三批 D-250：默认落点是书架，「我的查找」行在列表页，先进列表。
      await openMathList(tester);
      expect(find.text('★ 概念不清题'), findsOneWidget);
      await tester.tap(find.text('★ 概念不清题'));
      await tester.pump();
      expect(find.text('已应用查找：概念不清题'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('「概念不清」的结果'), findsOneWidget);
      expect(boardRow('函数极限'), findsOneWidget);
      expect(boardRow('导数综合'), findsNothing);
      expect(boardRow('定积分'), findsNothing);
    });

    testWidgets('我的查找：存当前条件 + chip 小 × 删除', (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo);
      // 二十三批 D-250：默认落点是书架，「＋ 存当前条件」在列表页，先进列表。
      await openMathList(tester);
      expect(find.text('★ 我的概念不清'), findsNothing);
      await tester.tap(find.text('＋ 存当前条件'));
      await tester.pumpAndSettle();
      expect(find.text('存当前条件'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('save-search-name')),
        '我的概念不清',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('已保存查找：我的概念不清'), findsOneWidget);
      expect(find.text('★ 我的概念不清'), findsOneWidget);
      expect(repo.savedSearchList.map((s) => s.name), contains('我的概念不清'));
      // chip 上的小 × 删除（无确认）。
      await tester.tap(find.text('✕'));
      await tester.pumpAndSettle();
      expect(find.text('★ 我的概念不清'), findsNothing);
      expect(repo.savedSearchList, isEmpty);
    });
  });
}
