// R2 widgets.dart 收口测试：EmptyState 转发为 UI Kit（QmEmptyState），
// 签名不变。
// SR-P2-34：InfoChip / DashedDivider 在 lib/ 内零调用点，已删除，
// 对应转发测试随之删除（调用方直接用 QmChip / QmRowLine）。
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
}
