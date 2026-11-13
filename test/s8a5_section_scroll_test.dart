// A5：点段头后页面上滚——根因是 app.dart 内容区 Row 默认垂直居中
// （CrossAxisAlignment.center），内容区容器按页面内容高度收起；
// 内容短的页悬在窗口中间，点段头展开/折叠改变内容高度时整个页面
// 跟着上下跳（展开外观约 +238px 内容，页面上窜约 119px）。
// 不是焦点滚动：点按不请求焦点（primaryFocus 不变），也无任何
// ensureVisible 调用；滚动偏移本身在点按前后恒为 0。
//
// 修法：app.dart 的 Row 改 crossAxisAlignment: CrossAxisAlignment.stretch
// （容器恒满高、顶对齐，与 HTML `.main` 一致），见 lib/app.dart。
//
// 本测试复现 app.dart 的内容区结构（Stack > Positioned.fill > Row
// [导航占位, Expanded(Container(padding 26, SettingsPage))]），
// 因为整应用 QuizMasterApp 在 widget 测试里 pumpAndSettle 永不
// 静止（应用内有持续 Timer）且要读真实演示库，按仓库惯例不直接
// 测整应用；app.dart 本身的改动以 Linux 真机前后截图为直接证据
// （见 docs/ui-replication/S8A5-SECTION-SCROLL-REPORT.md §5）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/settings/settings_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'settings_page_test.dart' show FakeSettingsRepo;

Future<void> pumpShellRow(
  WidgetTester tester, {
  required CrossAxisAlignment alignment,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      darkTheme: AppTheme.dark(scale: 1.0),
      themeMode: ThemeMode.dark,
      home: Scaffold(
        body: Stack(
          children: [
            const Positioned.fill(child: SizedBox()),
            Positioned.fill(
              child: Row(
                crossAxisAlignment: alignment,
                children: [
                  Container(
                    width: 216,
                    color: const Color(0xFF21262E),
                    child: const Column(
                      children: [SizedBox(height: 700)],
                    ),
                  ),
                  Expanded(
                    child: Container(
                      color: const Color(0xFF262B33),
                      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
                      child: SettingsPage(
                        repo: FakeSettingsRepo(),
                        settings: AppSettings.defaults,
                        onSettingsChanged: (_) async {},
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

double scrollOffset(WidgetTester tester) {
  final state = tester.state<ScrollableState>(find.byType(Scrollable).first);
  return state.position.pixels;
}

void main() {
  testWidgets('A5 stretch 布局：点段头标题不动、滚动偏移恒为 0', (tester) async {
    await pumpShellRow(tester, alignment: CrossAxisAlignment.stretch);
    final titleBefore = tester.getTopLeft(find.text('设置')).dy;
    expect(titleBefore, moreOrLessEquals(26, epsilon: 2.0));
    expect(scrollOffset(tester), 0.0);

    // 展开「外观」：内容变高，标题与滚动偏移都不应动。
    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('设置')).dy,
        moreOrLessEquals(titleBefore, epsilon: 1.0));
    expect(scrollOffset(tester), 0.0);

    // 再点「复习」：上方「外观」收起、下方「复习」展开，标题仍不动。
    await tester.tap(find.text('复习'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('设置')).dy,
        moreOrLessEquals(titleBefore, epsilon: 1.0));
    expect(scrollOffset(tester), 0.0);
  });

  testWidgets('A5 对照：center 布局（旧）点段头标题确实上窜', (tester) async {
    await pumpShellRow(tester, alignment: CrossAxisAlignment.center);
    final titleBefore = tester.getTopLeft(find.text('设置')).dy;
    // 旧布局下短页面垂直居中，标题不在顶部（约 175）。
    expect(titleBefore, greaterThan(100.0));
    expect(scrollOffset(tester), 0.0);

    // 展开「外观」：内容变高、容器重新居中，标题上窜（滚动偏移仍为 0，
    // 窜动来自容器重居中，不是滚动）。
    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();
    final titleAfter = tester.getTopLeft(find.text('设置')).dy;
    expect(titleBefore - titleAfter, greaterThan(50.0));
    expect(scrollOffset(tester), 0.0);
  });
}
