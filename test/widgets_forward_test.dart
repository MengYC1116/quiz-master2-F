// R2 widgets.dart 收口测试：EmptyState / InfoChip / DashedDivider
// 转发为 UI Kit（QmEmptyState / QmChip / QmRowLine），签名不变。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';
import 'package:quiz_master2/widgets/widgets.dart';

Future<void> pumpShell(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
  double scale = 1.0,
}) async {
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
            child: Scaffold(body: Center(child: child)),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('EmptyState 转发为 QmEmptyState：标题 + CTA 可点', (tester) async {
    var tapped = false;
    await pumpShell(
      tester,
      EmptyState(
        message: '都整理完了，去复习吧',
        actionLabel: '去复习',
        onAction: () => tapped = true,
      ),
    );
    expect(find.byType(QmEmptyState), findsOneWidget);
    expect(find.text('都整理完了，去复习吧'), findsOneWidget);
    await tester.tap(find.text('去复习'));
    expect(tapped, isTrue);
  });

  testWidgets('EmptyState 无操作时只有标题', (tester) async {
    await pumpShell(tester, const EmptyState(message: '没有符合条件的题'));
    expect(find.byType(QmEmptyState), findsOneWidget);
    expect(find.text('没有符合条件的题'), findsOneWidget);
  });

  testWidgets('InfoChip 转发为 QmChip 展示态：不被当成 Disabled 置灰',
      (tester) async {
    await pumpShell(tester, const InfoChip(label: '易错'));
    expect(find.byType(QmChip), findsOneWidget);
    expect(find.text('易错'), findsOneWidget);
    // 展示态不包 _QmPressable 的 Opacity .45。
    final opacities = tester.widgetList<Opacity>(find.byType(Opacity));
    expect(opacities.where((o) => o.opacity == 0.45), isEmpty);
  });

  testWidgets('InfoChip 带 color 时保留该色 10% 透明底', (tester) async {
    const green = Color(0xFF1F9D66);
    await pumpShell(tester, const InfoChip(label: '概念不清', color: green));
    expect(find.text('概念不清'), findsOneWidget);
    final containers = find.ancestor(
      of: find.text('概念不清'),
      matching: find.byType(Container),
    );
    final decoration =
        tester.widget<Container>(containers.first).decoration! as BoxDecoration;
    expect(decoration.color, green.withValues(alpha: 0.1));
  });

  testWidgets('DashedDivider 纸线色转发为 QmRowLine paper 档', (tester) async {
    await pumpShell(
      tester,
      const DashedDivider(color: Color(0xFFE3D9BE)),
    );
    final line = tester.widget<QmRowLine>(find.byType(QmRowLine));
    expect(line.kind, QmRowLineKind.paper);
  });

  testWidgets('DashedDivider 其他色转发为 QmRowLine line 档', (tester) async {
    await pumpShell(
      tester,
      DashedDivider(color: DesignTokens.light.line),
    );
    final line = tester.widget<QmRowLine>(find.byType(QmRowLine));
    expect(line.kind, QmRowLineKind.line);
  });
}
