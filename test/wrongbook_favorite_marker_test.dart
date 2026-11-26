// 收藏标志（2026-11-26，用户要求列表可区分收藏）：错题本列表页的
// 题目行上，已收藏的题在题干后、状态 pill 前画 ★，与详情页同星形
// 同色（paperStarOn）；只展示，不拦截点行进详情。
// 大卡片形态不在验收里：十九批 A1 已随视图切换去掉大卡片与序号圆盘，
// 列表只剩板子一种行设计（见 wrongbook_list.dart _buildListBody 注释）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/theme/design_tokens.dart';

import 'wrongbook_page_test.dart'
    show boardRow, openMathList, openShelfFromList, pumpWrongbook;

void main() {
  group('错题本列表收藏标志', () {
    testWidgets('已收藏的行画 ★、未收藏的不画，星在题干后 pill 前', (tester) async {
      await pumpWrongbook(tester);
      await openMathList(tester);
      // threeSubjectRepo：数学列表里只有 q1（函数极限）已收藏。
      expect(find.text('★'), findsOneWidget);
      expect(find.byKey(const ValueKey('favorite-star-q1')), findsOneWidget);
      expect(find.byKey(const ValueKey('favorite-star-q2')), findsNothing);
      expect(find.byKey(const ValueKey('favorite-star-q3')), findsNothing);
      // 与详情页同星形同色同字号。
      final star = tester.widget<Text>(
        find.byKey(const ValueKey('favorite-star-q1')),
      );
      expect(star.data, '★');
      expect(star.style?.color, DesignTokens.of(Brightness.light).paperStarOn);
      expect(star.style?.fontSize, DesignTokens.detailStarFontSize);
    });

    testWidgets('批量模式下已收藏的行同样画 ★', (tester) async {
      await pumpWrongbook(tester);
      await openMathList(tester);
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 道'), findsOneWidget);
      expect(find.byKey(const ValueKey('favorite-star-q1')), findsOneWidget);
      expect(find.text('★'), findsOneWidget);
    });

    testWidgets('点带星的行照常进详情，星不拦截点击', (tester) async {
      Question? opened;
      await pumpWrongbook(
        tester,
        onOpenDetail: (q, _, {String? searchContext}) async => opened = q,
      );
      await openMathList(tester);
      expect(find.byKey(const ValueKey('favorite-star-q1')), findsOneWidget);
      await tester.tap(boardRow('函数极限'));
      await tester.pumpAndSettle();
      expect(opened?.id, 'q1');
    });

    testWidgets('没有收藏的列表一行星也没有', (tester) async {
      await pumpWrongbook(tester);
      await openShelfFromList(tester);
      await tester.tap(find.text('英语'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      // 英语两题（q4/q8）都未收藏。
      expect(boardRow('阅读主旨'), findsOneWidget);
      expect(boardRow('图表作文'), findsOneWidget);
      expect(find.text('★'), findsNothing);
      expect(find.text('☆'), findsNothing);
    });
  });
}
