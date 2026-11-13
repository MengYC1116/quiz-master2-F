// 回归测试：选中态导航项悬停/点按/聚焦时底色必须保持 accent 不变（HTML
// 原型里选中项的 aria-current 规则优先于 :hover）。实测：导航后鼠标停在
// 选中项上时，InkWell 遮罩会被画成不透明（黑 4% → 纯黑、白 10% → 纯白、
// 透明 → 纯黑），所以选中态四层反馈色全部取 accent 本身。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/app_shell.dart';

Future<void> pumpNav(
  WidgetTester tester, {
  String route = '/home',
  bool collapsed = false,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      home: Scaffold(
        body: SizedBox(
          height: 720,
          child: AppNavBar(
            route: route,
            collapsed: collapsed,
            onNavigate: (_) {},
            onToggleCollapsed: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

InkWell navInkWell(WidgetTester tester, String label) {
  final wells = find.ancestor(
    of: find.text(label),
    matching: find.byType(InkWell),
  );
  return tester.widget<InkWell>(wells.first);
}

void main() {
  testWidgets('选中态导航项：hover/splash/highlight/focus 全取 accent',
      (tester) async {
    await pumpNav(tester, route: '/review', brightness: Brightness.light);
    final well = navInkWell(tester, '复习');
    const accent = Color(0xFF2E7CF6);
    expect(well.hoverColor, accent);
    expect(well.splashColor, accent);
    expect(well.highlightColor, accent);
    expect(well.focusColor, accent);
    // 未选中项保持原有 surface 悬停。
    final home = navInkWell(tester, '首页');
    expect(home.hoverColor, DesignTokens.light.surface);
  });

  testWidgets('深色选中态导航项：四层反馈色同样全取 accent', (tester) async {
    await pumpNav(tester, route: '/review', brightness: Brightness.dark);
    final well = navInkWell(tester, '复习');
    const accent = Color(0xFF7FA8D0);
    expect(well.hoverColor, accent);
    expect(well.splashColor, accent);
    expect(well.highlightColor, accent);
    expect(well.focusColor, accent);
  });

  testWidgets('折叠态选中态导航项：hover 同样取 accent', (tester) async {
    await pumpNav(tester, route: '/review', collapsed: true);
    // 折叠态只有图标 + Tooltip，没有文字：按 Tooltip 的 message 找其子孙 InkWell。
    final wells = find.descendant(
      of: find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == '复习'),
      matching: find.byType(InkWell),
    );
    final well = tester.widget<InkWell>(wells.first);
    expect(well.hoverColor, const Color(0xFF2E7CF6));
    expect(well.splashColor, const Color(0xFF2E7CF6));
  });
}
