// 十八批 P2（D-217）：批量操作与导出彻底互斥（widget 测试）。
//
// 背景：Meng 真机截图——批量模式开着（黄色批量条、已选 6 道），
// 工具栏还挂着「导出 (2)」。按十七批推送代码（c086ca8d）那个画面
// 画不出来（进批量会退导出模式，工具栏只剩 plain「导出」），最可
// 能是旧构建；但 D-209 的「取消保留已选」让导出已选在切模式时活
// 下来，两个「已选」可以同时存在——这正是「不互斥」的设计问题。
// 本包定：进批量模式时清空导出已选；点「取消」退出导出模式仍保
// 留已选；进导出模式清空批量勾选不变。十九批 A2：汇总条只在导出
// 模式里显示（平时不画），入口文案改为「导出打印」；
// 汇总数字改「已选 N 道：题名…」（不再带 / 50）。
//
// 复用 b17_export_mode_test.dart 的 pump / 桩控制器 / 断言 helper
//（同为错题本导出模式的 widget 测试脚手架，不另抄一份）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'b17_export_mode_test.dart';

void main() {
  group('十八批 P2：进批量清空导出已选', () {
    testWidgets('Meng 的操作顺序：导出模式选 2 道 → 点批量操作', (tester) async {
      await pumpB17(
        tester,
        repo: B17FakeRepo(
          questions: [b17q('q1'), b17q('q2'), b17q('q3')],
        ),
      );
      await openMathListCompact(tester);

      // 进导出模式，选 2 道。
      await enterExportMode(tester);
      await tapExportRow(tester, 'q1');
      await tapExportRow(tester, 'q2');
      expect(toolbarExportLabel(tester), '导出（2）');
      expect(summaryNumbers(tester), contains('已选 2 道'));

      // 点「批量操作」：进批量模式。
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();

      // 工具栏只剩「导出打印」入口，没有「取消」与提示。
      expect(toolbarExportLabel(tester), '导出打印');
      expect(find.byKey(const Key('export-mode-cancel')), findsNothing);
      expect(find.byKey(const Key('export-mode-hint')), findsNothing);
      // 导出已选已清空：✓ 与蓝底消失；汇总条只在模式里画，退出后不画。
      expect(isExportSelected(tester, 'q1'), isFalse);
      expect(isExportSelected(tester, 'q2'), isFalse);
      expect(find.byKey(const Key('export-summary-numbers')), findsNothing);
      // 批量条可见，批量勾选从 0 开始。
      expect(find.byKey(const Key('batch-select-menu')), findsOneWidget);
      expect(find.text('已选 0 道'), findsOneWidget);
    });

    testWidgets('进批量后清掉的导出已选不会复活：再进导出模式仍是空选', (tester) async {
      await pumpB17(
        tester,
        repo: B17FakeRepo(
          questions: [b17q('q1'), b17q('q2'), b17q('q3')],
        ),
      );
      await openMathListCompact(tester);
      await enterExportMode(tester);
      await tapExportRow(tester, 'q1');
      expect(summaryNumbers(tester), contains('已选 1 道'));

      // 进批量（导出已选清空），再退出批量。
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('export-summary-numbers')), findsNothing);
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('batch-select-menu')), findsNothing);

      // 再进导出模式：之前选的 q1 不复活。
      await enterExportMode(tester);
      expect(isExportSelected(tester, 'q1'), isFalse);
      expect(toolbarExportLabel(tester), '导出');
      expect(summaryNumbers(tester), contains('已选 0 道'));
    });

    testWidgets('点「取消」退出导出模式仍保留已选（D-209 取消语义不变）', (tester) async {
      await pumpB17(
        tester,
        repo: B17FakeRepo(
          questions: [b17q('q1'), b17q('q2')],
        ),
      );
      await openMathListCompact(tester);
      await enterExportMode(tester);
      await tapExportRow(tester, 'q1');
      await tester.tap(find.byKey(const Key('export-mode-cancel')));
      await tester.pump();
      // 只有点「取消」退出才保留；进批量模式不适用这条。
      // 汇总条只在模式里画，退出后不画——再进模式看汇总仍在。
      expect(isExportSelected(tester, 'q1'), isTrue);
      expect(find.byKey(const Key('export-summary-numbers')), findsNothing);
      await enterExportMode(tester);
      expect(summaryNumbers(tester), contains('已选 1 道'));
    });
  });
}
