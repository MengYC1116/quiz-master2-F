// 收藏星星（2026-11-26 跟进，用户要求一直显示、可点切换）：
// 错题本列表页的题目行上，星星一直显示——已收藏 ★ 实心、未收藏 ☆
// 空心，同色（paperStarOn）、同字号；点星星切换收藏/取消收藏，
// 与详情页同一持久化方法（WrongbookNotifier.toggleFavorite），
// 点完当场变；点星星不进详情。
// 大卡片形态不在验收里：十九批 A1 已随视图切换去掉大卡片与序号圆盘，
// 列表只剩板子一种行设计（见 wrongbook_list.dart _buildListBody 注释）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/theme/design_tokens.dart';

import 'wrongbook_page_test.dart'
    show
        boardRow,
        openMathList,
        openShelfFromList,
        pumpWrongbook,
        threeSubjectRepo;

void main() {
  group('错题本列表收藏星星', () {
    testWidgets('已收藏画 ★、未收藏画 ☆，星在题干后 pill 前', (tester) async {
      await pumpWrongbook(tester);
      await openMathList(tester);
      // threeSubjectRepo：数学列表里只有 q1（函数极限）已收藏；
      // 包 4 默认隐藏取消后 q7 也显示，未收藏 ☆ 共 3 个（q2/q3/q7）。
      expect(find.text('★'), findsOneWidget);
      expect(find.text('☆'), findsNWidgets(3));
      expect(find.byKey(const ValueKey('favorite-star-q1')), findsOneWidget);
      expect(find.byKey(const ValueKey('favorite-star-q2')), findsOneWidget);
      expect(find.byKey(const ValueKey('favorite-star-q3')), findsOneWidget);
      // 与详情页同星形同色同字号。
      final star = tester.widget<Text>(
        find.byKey(const ValueKey('favorite-star-q1')),
      );
      expect(star.data, '★');
      expect(star.style?.color, DesignTokens.of(Brightness.light).paperStarOn);
      expect(star.style?.fontSize, DesignTokens.detailStarFontSize);
      // 空心星同色同字号。
      final hollow = tester.widget<Text>(
        find.byKey(const ValueKey('favorite-star-q2')),
      );
      expect(hollow.data, '☆');
      expect(
        hollow.style?.color,
        DesignTokens.of(Brightness.light).paperStarOn,
      );
      expect(hollow.style?.fontSize, DesignTokens.detailStarFontSize);
    });

    testWidgets('批量模式下已收藏的行同样画 ★、未收藏画 ☆', (tester) async {
      await pumpWrongbook(tester);
      await openMathList(tester);
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 道'), findsOneWidget);
      expect(find.byKey(const ValueKey('favorite-star-q1')), findsOneWidget);
      expect(find.text('★'), findsOneWidget);
      expect(find.text('☆'), findsNWidgets(3));
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

    testWidgets('点 ☆ 变 ★ 且持久化，重进列表仍是 ★；再点变回 ☆', (
      tester,
    ) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo);
      await openMathList(tester);
      // q2 未收藏，先是 ☆。
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('favorite-star-q2')))
            .data,
        '☆',
      );
      await tester.tap(find.byKey(const ValueKey('favorite-star-q2')));
      await tester.pumpAndSettle();
      // 点完当场变 ★，库里已翻过来。
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('favorite-star-q2')))
            .data,
        '★',
      );
      expect(
        repo.questions.firstWhere((q) => q.id == 'q2').isFavorite,
        isTrue,
      );
      // 重进列表仍是 ★。
      await openShelfFromList(tester);
      await openMathList(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('favorite-star-q2')))
            .data,
        '★',
      );
      // 再点取消收藏。
      await tester.tap(find.byKey(const ValueKey('favorite-star-q2')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('favorite-star-q2')))
            .data,
        '☆',
      );
      expect(
        repo.questions.firstWhere((q) => q.id == 'q2').isFavorite,
        isFalse,
      );
    });

    testWidgets('点星星不进详情', (tester) async {
      Question? opened;
      await pumpWrongbook(
        tester,
        onOpenDetail: (q, _, {String? searchContext}) async => opened = q,
      );
      await openMathList(tester);
      await tester.tap(find.byKey(const ValueKey('favorite-star-q2')));
      await tester.pumpAndSettle();
      expect(opened, isNull);
      // 星星翻过来了，说明点到了星星而不是行。
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('favorite-star-q2')))
            .data,
        '★',
      );
    });

    testWidgets('没有收藏的列表全是 ☆、没有 ★', (tester) async {
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
      expect(find.text('☆'), findsNWidgets(2));
    });
  });
}
