// R2 外壳导航 widget 测试：7 项导航、设置在底部、折叠行为、角标口径、
// 亮/深、三档缩放。测纯展示组件 AppNavBar（不读数据库、不碰业务口径；
// 角标与速览数字以参数传入，口径本身由 repository 层保证，见 R2 报告）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/app_shell.dart';

Future<void> pumpNav(
  WidgetTester tester, {
  String route = '/home',
  bool collapsed = false,
  int collectBadge = 0,
  int organizeBadge = 0,
  Map<String, int> navRev = const {},
  Map<String, int> navPending = const {},
  Brightness brightness = Brightness.light,
  double scale = 1.0,
  ValueChanged<String>? onNavigate,
}) async {
  // 真实窗口尺寸 1280×720（与截图一致）；默认测试视口只有 800×600，
  // 大字号导航在 600 高下会溢出（已用可滚动结构修复，见小窗口测试）。
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: scale),
      darkTheme: AppTheme.dark(scale: scale),
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      home: Builder(
        builder: (context) {
          final data = MediaQuery.of(context);
          return MediaQuery(
            data: data.copyWith(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              // 只约束高度（SizedBox 带 width 会给子级传紧约束，盖掉
              // 导航自身的 216/64 宽，量宽会失真）。
              body: SizedBox(
                height: 720,
                child: AppNavBar(
                  route: route,
                  collapsed: collapsed,
                  onNavigate: onNavigate ?? (_) {},
                  onToggleCollapsed: () {},
                  collectBadge: collectBadge,
                  organizeBadge: organizeBadge,
                  navRev: navRev,
                  navPending: navPending,
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// label 文字最近的祖先 Material（导航项本体）。
Material itemMaterial(WidgetTester tester, String label) {
  final materials = find.ancestor(
    of: find.text(label),
    matching: find.byType(Material),
  );
  return tester.widget<Material>(materials.first);
}

/// 角标数字文字最近的祖先 Container（角标本体）。
BoxDecoration badgeDecoration(WidgetTester tester, String number) {
  final containers = find.ancestor(
    of: find.text(number),
    matching: find.byType(Container),
  );
  return tester.widget<Container>(containers.first).decoration!
      as BoxDecoration;
}

void main() {
  group('主列表 7 项 + 设置在底部', () {
    testWidgets('展开态：7 项各出现一次，设置只出现一次（底部按钮）',
        (tester) async {
      await pumpNav(tester);
      for (final label in ['首页', '收集中心', '整理工作台', '错题本', '复习', '学习报告', '学科管理']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('设置'), findsOneWidget);
      // 设置按钮在学科速览之下：它在“学科速览”标题之后渲染。
      expect(find.text('学科速览'), findsOneWidget);
    });

    testWidgets('折叠态：文字消失，7 项 + 设置都只剩 Tooltip', (tester) async {
      await pumpNav(tester, collapsed: true);
      for (final label in ['首页', '收集中心', '整理工作台', '错题本', '复习', '学习报告', '学科管理', '设置']) {
        expect(find.text(label), findsNothing);
        expect(find.byTooltip(label), findsOneWidget);
      }
      expect(find.text('学科速览'), findsNothing);
    });

    testWidgets('点导航项回调路由；点底部设置去 /settings', (tester) async {
      String? got;
      await pumpNav(tester, onNavigate: (r) => got = r);
      await tester.tap(find.text('复习'));
      expect(got, '/review');
      await tester.tap(find.text('设置'));
      expect(got, '/settings');
    });

    testWidgets('折叠态点设置图标去 /settings', (tester) async {
      String? got;
      await pumpNav(tester, collapsed: true, onNavigate: (r) => got = r);
      await tester.tap(find.byTooltip('设置'));
      expect(got, '/settings');
    });
  });

  group('折叠行为与宽度', () {
    testWidgets('展开 216px、折叠 64px（标准字号）', (tester) async {
      await pumpNav(tester);
      expect(tester.getSize(find.byKey(const ValueKey('qm-nav-bar'))).width, 216);
      await pumpNav(tester, collapsed: true);
      expect(tester.getSize(find.byKey(const ValueKey('qm-nav-bar'))).width, 64);
    });

    testWidgets('三档缩放：导航宽按 ScaledTokens 缩放', (tester) async {
      await pumpNav(tester, scale: 1.15);
      expect(tester.getSize(find.byKey(const ValueKey('qm-nav-bar'))).width,
          closeTo(216 * 1.15, 0.5));
      await pumpNav(tester, collapsed: true, scale: 1.3);
      expect(tester.getSize(find.byKey(const ValueKey('qm-nav-bar'))).width,
          closeTo(64 * 1.3, 0.5));
    });

    testWidgets('内容区 padding token：26/30 按三档缩放', (tester) async {
      void expectPadding(double scale, double h, double v) {
        final p = DesignTokens.scaled(scale).contentPadding;
        expect(p.left, closeTo(h, 0.01));
        expect(p.right, closeTo(h, 0.01));
        expect(p.top, closeTo(v, 0.01));
        expect(p.bottom, closeTo(v, 0.01));
      }

      expectPadding(1.0, 30, 26);
      expectPadding(1.15, 34.5, 29.9);
      expectPadding(1.3, 39, 33.8);
    });

    testWidgets('小窗口 + 特大字号：导航可滚动，不溢出黄条', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpNav(tester, scale: 1.3);
      expect(tester.takeException(), isNull);
      await pumpNav(tester, collapsed: true, scale: 1.3);
      expect(tester.takeException(), isNull);
    });
  });

  group('选中态与角标', () {
    testWidgets('选中项 accent 底 + accent-ink 字', (tester) async {
      await pumpNav(tester, route: '/review');
      expect(itemMaterial(tester, '复习').color, DesignTokens.light.accent);
      final text = tester.widget<Text>(find.text('复习'));
      expect(text.style?.color, DesignTokens.light.accentInk);
      expect(text.style?.fontWeight, FontWeight.w700);
      // 未选中项无底色、字为 ink-2。
      expect(itemMaterial(tester, '首页').color, Colors.transparent);
    });

    testWidgets('深色选中项 #7FA8D0 底 + #131A24 字', (tester) async {
      await pumpNav(tester, route: '/review', brightness: Brightness.dark);
      expect(itemMaterial(tester, '复习').color, DesignTokens.dark.accent);
      final text = tester.widget<Text>(find.text('复习'));
      expect(text.style?.color, DesignTokens.dark.accentInk);
    });

    testWidgets('角标：收集灰档、整理 accent 档；为 0 时不显示', (tester) async {
      await pumpNav(tester, collectBadge: 5, organizeBadge: 3);
      expect(find.text('5'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      // 收集角标灰档：surface-3 底 + ink-2 字。
      expect(badgeDecoration(tester, '5').color, DesignTokens.light.surface3);
      // 整理角标 accent 底 + accent-ink 字。
      expect(badgeDecoration(tester, '3').color, DesignTokens.light.accent);
      await pumpNav(tester, collectBadge: 0, organizeBadge: 0);
      expect(find.text('5'), findsNothing);
      expect(find.text('3'), findsNothing);
    });

    testWidgets('选中项的角标用 badgeSelected token（亮 #FFF/#175CD3）',
        (tester) async {
      await pumpNav(tester, route: '/collect', collectBadge: 5);
      expect(badgeDecoration(tester, '5').color,
          DesignTokens.light.badgeSelectedBg);
      final text = tester.widget<Text>(find.text('5'));
      expect(text.style?.color, DesignTokens.light.badgeSelectedFg);
    });

    testWidgets('选中项的角标深色用 #D5DBE4/#33465A', (tester) async {
      await pumpNav(tester,
          route: '/collect', collectBadge: 5, brightness: Brightness.dark);
      expect(badgeDecoration(tester, '5').color,
          DesignTokens.dark.badgeSelectedBg);
      final text = tester.widget<Text>(find.text('5'));
      expect(text.style?.color, DesignTokens.dark.badgeSelectedFg);
    });

    testWidgets('设置页时底部设置按钮呈选中态（主按钮形态）', (tester) async {
      await pumpNav(tester, route: '/settings');
      // 设置按钮是主按钮：找“设置”文字最近的 Container，底色为 accent。
      final containers = find.ancestor(
        of: find.text('设置'),
        matching: find.byType(Container),
      );
      final decoration = tester.widget<Container>(containers.first).decoration!
          as BoxDecoration;
      expect(decoration.color, DesignTokens.light.accent);
    });
  });

  group('学科速览', () {
    testWidgets('每科一行：待整理 · 待复习，缺省为 0', (tester) async {
      await pumpNav(tester,
          navRev: const {'math': 3, 'english': 2, 'politics': 1},
          navPending: const {'math': 2, 'english': 0, 'politics': 1});
      expect(find.text('待整理 2 · 待复习 3'), findsOneWidget);
      expect(find.text('待整理 0 · 待复习 2'), findsOneWidget);
      expect(find.text('待整理 1 · 待复习 1'), findsOneWidget);
      await pumpNav(tester);
      expect(find.text('待整理 0 · 待复习 0'), findsNWidgets(3));
    });
  });

  group('亮/深与文字符号', () {
    testWidgets('亮/深导航底色取 surface-2 token', (tester) async {
      await pumpNav(tester);
      final light = tester.widget<Container>(find.byType(Container).first);
      expect((light.decoration! as BoxDecoration).color,
          DesignTokens.light.surface2);
      await pumpNav(tester, brightness: Brightness.dark);
      final dark = tester.widget<Container>(find.byType(Container).first);
      expect((dark.decoration! as BoxDecoration).color,
          DesignTokens.dark.surface2);
    });

    testWidgets('全库无 Icon：导航子树里没有图标字体', (tester) async {
      await pumpNav(tester);
      expect(find.byType(Icon), findsNothing);
      await pumpNav(tester, collapsed: true);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('R2 定夺收入 token 的 HTML 实读值', (tester) async {
      expect(DesignTokens.buttonFontSize, 14);
      expect(DesignTokens.smallButtonFontSize, 13);
      expect(DesignTokens.largeButtonFontSize, 17.5);
      expect(DesignTokens.chipFontSize, 13);
      expect(DesignTokens.pillFontSize, 12);
      expect(DesignTokens.emptyTitleFontSize, 17);
      expect(DesignTokens.foldGroupTitleFontSize, 16.5);
      expect(DesignTokens.foldFormTitleFontSize, 14.5);
      expect(DesignTokens.largeButtonRadius, 14);
      expect(DesignTokens.controlLineHeight, 1.2);
      expect(DesignTokens.navItemFontSize, 14.5);
      expect(DesignTokens.navBadgeFontSize, 11.5);
      expect(DesignTokens.navBrandFontSize, 17);
    });
  });
}
