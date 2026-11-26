// 方案 A 批量栏（2026-11-26，Meng 定）：错题本列表页批量模式由三行
// 平铺按钮改成单行工具条——已选文案 + 选择 / 整理 / 复习三个分组
// 菜单 + 批量删除（两段确认）+ 退出批量。覆盖新行为：0 选禁用态、
// 菜单项执行、删除两段确认（点别处 / 退出批量复位）、文件夹选择进菜单。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/widgets/uikit.dart';

import 'wrongbook_page_test.dart'
    show
        openBatchMenu,
        openMathDirectory,
        openMathList,
        pumpWrongbook,
        tapBatchMenuItem,
        threeSubjectRepo;

void main() {
  group('方案 A 批量栏', () {
    QmButton batchBtn(WidgetTester tester, String label) =>
        tester.widget<QmButton>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(QmButton),
          ),
        );

    testWidgets('0 选禁用态：整理/复习/删除禁用，选中后启用', (tester) async {
      await pumpWrongbook(tester);
      await openMathList(tester);
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();

      expect(batchBtn(tester, '选择').onPressed, isNotNull);
      expect(batchBtn(tester, '整理').onPressed, isNull);
      expect(batchBtn(tester, '复习').onPressed, isNull);
      expect(batchBtn(tester, '批量删除').onPressed, isNull);
      expect(batchBtn(tester, '退出批量').onPressed, isNotNull);
      // 勾两道后三者全启用。
      await tester.tap(find.byType(Checkbox).at(0));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 道'), findsOneWidget);
      expect(batchBtn(tester, '整理').onPressed, isNotNull);
      expect(batchBtn(tester, '复习').onPressed, isNotNull);
      expect(batchBtn(tester, '批量删除').onPressed, isNotNull);
    });

    testWidgets('菜单项执行：整理菜单收藏 3 道；选择菜单清除选择',
        (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo);
      await openMathList(tester);
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      await tapBatchMenuItem(tester, 'batch-select-menu', '全选当前结果');
      expect(find.text('已选 3 道'), findsOneWidget);
      // 点选项即执行并关菜单。
      await tapBatchMenuItem(tester, 'batch-organize-menu', '收藏');
      expect(find.text('已收藏 3 道'), findsOneWidget);
      expect(find.text('收藏'), findsNothing);
      // 收藏执行完清空通用选择：整理与删除重新禁用。
      expect(batchBtn(tester, '整理').onPressed, isNull);
      expect(batchBtn(tester, '批量删除').onPressed, isNull);
      // 加题选择还在（收藏只清通用选择）：清除选择把它也清掉。
      expect(find.text('已选 3 道'), findsOneWidget);
      await tapBatchMenuItem(tester, 'batch-select-menu', '清除选择');
      expect(find.text('已选 0 道'), findsOneWidget);
      expect(find.text('清除选择'), findsNothing);
    });

    testWidgets('删除两段确认：点别处取消待确认态', (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo);
      await openMathList(tester);
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).at(0));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 道'), findsOneWidget);
      // 第一下：只改文案，不删题。
      await tester.tap(find.text('批量删除'));
      await tester.pumpAndSettle();
      expect(find.text('再点一次确认删除 2 道'), findsOneWidget);
      expect(repo.deletedIds, isEmpty);
      // 点别处 1：点搜索框，待确认态取消。
      await tester.tap(find.byType(TextField).first);
      await tester.pumpAndSettle();
      expect(find.text('批量删除'), findsOneWidget);
      expect(find.text('再点一次确认删除 2 道'), findsNothing);
      expect(repo.deletedIds, isEmpty);
      // 重新待确认。
      await tester.tap(find.text('批量删除'));
      await tester.pumpAndSettle();
      expect(find.text('再点一次确认删除 2 道'), findsOneWidget);
      // 点别处 2：开选择菜单，待确认态取消（菜单本身正常打开）。
      await tester.tap(find.byKey(const Key('batch-select-menu')));
      await tester.pumpAndSettle();
      expect(find.text('批量删除'), findsOneWidget);
      expect(find.text('全选当前结果'), findsOneWidget);
      // 关菜单，再点删除：重新待确认；第二下真正执行。
      await tester.tap(find.byKey(const Key('batch-select-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量删除'));
      await tester.pumpAndSettle();
      expect(find.text('再点一次确认删除 2 道'), findsOneWidget);
      await tester.tap(find.text('再点一次确认删除 2 道'));
      await tester.pumpAndSettle();
      expect(repo.deletedIds, hasLength(2));
    });

    testWidgets('删除两段确认：退出批量后重进不再待确认', (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo);
      await openMathList(tester);
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).at(0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量删除'));
      await tester.pumpAndSettle();
      expect(find.text('再点一次确认删除 1 道'), findsOneWidget);
      // 退出批量再重进、重选：删除按钮回到未待确认态。
      await tester.tap(find.text('退出批量'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).at(0));
      await tester.pumpAndSettle();
      expect(find.text('批量删除'), findsOneWidget);
      expect(find.text('再点一次确认删除 1 道'), findsNothing);
      // 点一下只待确认，不删题。
      await tester.tap(find.text('批量删除'));
      await tester.pumpAndSettle();
      expect(repo.deletedIds, isEmpty);
    });

    testWidgets('文件夹选择进菜单：文件夹内移入', (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo);
      await openMathDirectory(tester);
      await tester.tap(find.text('平时作业'));
      await tester.pumpAndSettle();
      // 平时作业文件夹里只有 q2（q6 未整理，不进列表）。
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).at(0));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 道'), findsOneWidget);
      // 整理菜单里有移入文件夹子菜单与移出当前文件夹。
      await openBatchMenu(tester, 'batch-organize-menu');
      expect(find.text('移入文件夹'), findsOneWidget);
      expect(find.text('移出当前文件夹'), findsOneWidget);
      // 子菜单点「试卷」：q2 移进试卷文件夹。
      await tester.tap(find.text('移入文件夹'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('试卷').last);
      await tester.pumpAndSettle();
      final q2 = repo.questions.firstWhere((q) => q.id == 'q2');
      expect(q2.folderIds, contains('f1'));
      expect(q2.folderIds, isNot(contains('f2')));
    });

    testWidgets('文件夹选择进菜单：移出当前文件夹', (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo);
      await openMathDirectory(tester);
      await tester.tap(find.text('平时作业'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).at(0));
      await tester.pumpAndSettle();
      await tapBatchMenuItem(tester, 'batch-organize-menu', '移出当前文件夹');
      final q2 = repo.questions.firstWhere((q) => q.id == 'q2');
      expect(q2.folderIds, isNot(contains('f2')));
    });
  });
}
