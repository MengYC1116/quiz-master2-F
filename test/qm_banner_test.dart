// A4：QmBanner 横幅组件补充测试（R11 §8.3 “重复/超限黄色横幅无测试”）。
//
// 覆盖点：
// - warning 档黄底色值与文字色（亮/深两套主题，按 DesignTokens.of 取值）；
// - 标题（粗体前导句）+ 正文渲染；
// - 收集页两处黄色横幅的操作按钮（重复：仍然再导一份/不导了；
//   超限：仍然再导一份/不导了）都存在且点按回调触发；
// - onDismiss 时「知道了」出现且点按回调触发，无 onDismiss 时不出现；
// - error/info 档颜色区分（亮/深各一例）；
// - 大/特大字号（1.15/1.30）下 pump 不抛错、不溢出。
//
// 文案以代码现状为准：收集页重复横幅标题「这个文件已经导入过。」、
// 超限横幅标题「文件超过大小上限，只是提示，不直接判失败。」
// （collect_page.dart 约 398–430 行）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';

Future<void> pumpBanner(
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
            child: Scaffold(
              body: Center(
                child: SizedBox(width: 320, child: child),
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// label 文字最近的祖先 Container 的 BoxDecoration（横幅本体）。
BoxDecoration bannerDecoration(WidgetTester tester, String label) {
  final containers = find.ancestor(
    of: find.textContaining(label),
    matching: find.byType(Container),
  );
  final container = tester.widget<Container>(containers.first);
  return container.decoration! as BoxDecoration;
}

/// 横幅内 Text.rich 根 TextSpan 的样式（字号/文字色/行高）。
/// 用正文内容定位，避开左侧 QmGlyph（⚠/ℹ 本身也是一个 Text）。
TextStyle bannerTextStyle(WidgetTester tester, String message) {
  return bannerRootSpan(tester, message).style!;
}

/// 含指定正文的横幅 RichText 根 TextSpan。
/// Text.rich 会把传入的 span 包成子 span（外层是 DefaultTextStyle 合并
/// 后的样式），故取 children.first 才是横幅自己的 span。
TextSpan bannerRootSpan(WidgetTester tester, String message) {
  final rich = tester.widget<RichText>(
    find.byWidgetPredicate(
      (w) =>
          w is RichText && w.text.toPlainText().contains(message),
    ),
  );
  final outer = rich.text as TextSpan;
  if (outer.children != null && outer.children!.isNotEmpty) {
    return outer.children!.first as TextSpan;
  }
  return outer;
}

void main() {
  group('QmBanner A4 warning 黄底', () {
    testWidgets('亮色：黄底 #FFF3D1、文字色 warnInk、边框 warnLine', (tester) async {
      const palette = DesignTokens.light;
      await pumpBanner(
        tester,
        const QmBanner(tone: QmBannerTone.warning, message: '文件已存在'),
      );
      final d = bannerDecoration(tester, '文件已存在');
      expect(d.color, palette.warnBg);
      expect(d.color, const Color(0xFFFFF3D1));
      expect((d.border as Border).top.color, palette.warnLine);
      expect((d.border as Border).top.color, const Color(0xFFF0D488));
      expect(bannerTextStyle(tester, '文件已存在').color, palette.warnInk);
      expect(bannerTextStyle(tester, '文件已存在').color, const Color(0xFF8A5A00));
    });

    testWidgets('深色：黄底按 DesignTokens.of(dark) 取，文字色 warnInk',
        (tester) async {
      const palette = DesignTokens.dark;
      await pumpBanner(
        tester,
        const QmBanner(tone: QmBannerTone.warning, message: '文件已存在'),
        brightness: Brightness.dark,
      );
      final d = bannerDecoration(tester, '文件已存在');
      expect(d.color, palette.warnBg);
      expect(d.color, const Color(0xFF32342C));
      expect((d.border as Border).top.color, palette.warnLine);
      expect(bannerTextStyle(tester, '文件已存在').color, palette.warnInk);
      expect(bannerTextStyle(tester, '文件已存在').color, const Color(0xFFCFC488));
    });
  });

  group('QmBanner A4 标题 + 正文', () {
    testWidgets('重复横幅：标题粗体前导 + 正文都渲染', (tester) async {
      await pumpBanner(
        tester,
        const QmBanner(
          tone: QmBannerTone.warning,
          title: '这个文件已经导入过。',
          message: '列表里已有「数学试卷.jpg」的任务，再导一份会多出一组重复任务。要再导一份吗？',
        ),
      );
      expect(find.textContaining('这个文件已经导入过。'), findsOneWidget);
      expect(find.textContaining('再导一份会多出一组重复任务'), findsOneWidget);
      final span = bannerRootSpan(tester, '再导一份会多出一组重复任务');
      expect(span.children!.length, 2);
      final titleSpan = span.children!.first as TextSpan;
      expect(titleSpan.text, '这个文件已经导入过。');
      expect(titleSpan.style?.fontWeight, FontWeight.w700);
      final bodySpan = span.children!.last as TextSpan;
      expect(bodySpan.text, contains('要再导一份吗？'));
    });

    testWidgets('超限横幅：标题 + 正文都渲染', (tester) async {
      await pumpBanner(
        tester,
        const QmBanner(
          tone: QmBannerTone.warning,
          title: '文件超过大小上限，只是提示，不直接判失败。',
          message: '文件较大（25.0MB），超过建议上限 20MB，仍可继续导入。可以先压缩再重新选，也可以仍要导入，大文件检测会慢一些。',
        ),
      );
      expect(find.textContaining('文件超过大小上限，只是提示，不直接判失败。'),
          findsOneWidget);
      expect(find.textContaining('超过建议上限 20MB'), findsOneWidget);
    });

    testWidgets('无标题时只渲染正文', (tester) async {
      await pumpBanner(
        tester,
        const QmBanner(tone: QmBannerTone.warning, message: '只有正文'),
      );
      final span = bannerRootSpan(tester, '只有正文');
      expect(span.children!.length, 1);
    });
  });

  group('QmBanner A4 操作按钮', () {
    testWidgets('重复横幅两操作：仍然再导一份 / 不导了，点按回调都触发',
        (tester) async {
      var again = false;
      var noMore = false;
      await pumpBanner(
        tester,
        QmBanner(
          tone: QmBannerTone.warning,
          title: '这个文件已经导入过。',
          message: '要再导一份吗？',
          actions: [
            QmBannerAction(label: '仍然再导一份', onPressed: () => again = true),
            QmBannerAction(label: '不导了', onPressed: () => noMore = true),
          ],
        ),
      );
      expect(find.text('仍然再导一份'), findsOneWidget);
      expect(find.text('不导了'), findsOneWidget);
      await tester.tap(find.text('仍然再导一份'));
      await tester.pump();
      expect(again, isTrue);
      await tester.tap(find.text('不导了'));
      await tester.pump();
      expect(noMore, isTrue);
    });

    testWidgets('超限横幅两操作：仍然再导一份 / 不导了，点按回调都触发',
        (tester) async {
      var goOn = false;
      var holdOff = false;
      await pumpBanner(
        tester,
        QmBanner(
          tone: QmBannerTone.warning,
          title: '文件超过大小上限，只是提示，不直接判失败。',
          message: '可以先压缩再重新选，也可以仍要导入。',
          actions: [
            QmBannerAction(label: '仍然再导一份', onPressed: () => goOn = true),
            QmBannerAction(label: '不导了', onPressed: () => holdOff = true),
          ],
        ),
      );
      expect(find.text('仍然再导一份'), findsOneWidget);
      expect(find.text('不导了'), findsOneWidget);
      await tester.tap(find.text('仍然再导一份'));
      await tester.pump();
      expect(goOn, isTrue);
      await tester.tap(find.text('不导了'));
      await tester.pump();
      expect(holdOff, isTrue);
    });

    testWidgets('深色下重复横幅两操作仍可点按', (tester) async {
      var again = false;
      await pumpBanner(
        tester,
        QmBanner(
          tone: QmBannerTone.warning,
          title: '这个文件已经导入过。',
          message: '要再导一份吗？',
          actions: [
            QmBannerAction(label: '仍然再导一份', onPressed: () => again = true),
            QmBannerAction(label: '不导了', onPressed: () {}),
          ],
        ),
        brightness: Brightness.dark,
      );
      await tester.tap(find.text('仍然再导一份'));
      await tester.pump();
      expect(again, isTrue);
    });
  });

  group('QmBanner A4 关闭按钮', () {
    testWidgets('有 onDismiss 时「知道了」出现，点按回调触发', (tester) async {
      var dismissed = false;
      await pumpBanner(
        tester,
        QmBanner(
          tone: QmBannerTone.warning,
          title: '先选学科。',
          message: '没选学科不能导入。',
          onDismiss: () => dismissed = true,
        ),
      );
      expect(find.text('知道了'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pump();
      expect(dismissed, isTrue);
    });

    testWidgets('无 onDismiss 时不出现「知道了」', (tester) async {
      await pumpBanner(
        tester,
        const QmBanner(tone: QmBannerTone.warning, message: '没有关闭按钮'),
      );
      expect(find.text('知道了'), findsNothing);
    });

    testWidgets('深色下「知道了」点按回调触发', (tester) async {
      var dismissed = false;
      await pumpBanner(
        tester,
        QmBanner(
          tone: QmBannerTone.error,
          message: '出错了',
          onDismiss: () => dismissed = true,
        ),
        brightness: Brightness.dark,
      );
      expect(find.text('知道了'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pump();
      expect(dismissed, isTrue);
    });
  });

  group('QmBanner A4 三档颜色区分', () {
    testWidgets('亮色 error 红 / warning 黄 / info 蓝互不相同', (tester) async {
      await pumpBanner(
        tester,
        const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QmBanner(tone: QmBannerTone.error, message: '备份失败'),
            QmBanner(tone: QmBannerTone.warning, message: '文件已存在'),
            QmBanner(tone: QmBannerTone.info, message: '已同步'),
          ],
        ),
      );
      expect(bannerDecoration(tester, '备份失败').color,
          const Color(0xFFFFE9E5));
      expect(bannerDecoration(tester, '文件已存在').color,
          const Color(0xFFFFF3D1));
      expect(bannerDecoration(tester, '已同步').color, const Color(0xFFE1EDFF));
    });

    testWidgets('深色 error / warning / info 三档互不相同', (tester) async {
      await pumpBanner(
        tester,
        const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QmBanner(tone: QmBannerTone.error, message: '备份失败'),
            QmBanner(tone: QmBannerTone.warning, message: '文件已存在'),
            QmBanner(tone: QmBannerTone.info, message: '已同步'),
          ],
        ),
        brightness: Brightness.dark,
      );
      expect(bannerDecoration(tester, '备份失败').color,
          DesignTokens.dark.errBg);
      expect(bannerDecoration(tester, '备份失败').color,
          const Color(0xFF352C31));
      expect(bannerDecoration(tester, '文件已存在').color,
          DesignTokens.dark.warnBg);
      expect(bannerDecoration(tester, '文件已存在').color,
          const Color(0xFF32342C));
      expect(
          bannerDecoration(tester, '已同步').color, DesignTokens.dark.infoBg);
      expect(bannerDecoration(tester, '已同步').color, const Color(0xFF2C3949));
    });
  });

  group('QmBanner A4 大字号不溢出', () {
    testWidgets('大字号 1.15：两操作长文案横幅 pump 不抛错', (tester) async {
      await pumpBanner(
        tester,
        QmBanner(
          tone: QmBannerTone.warning,
          title: '这个文件已经导入过。',
          message: '列表里已有「数学试卷.jpg」的任务，再导一份会多出一组重复任务。要再导一份吗？',
          actions: [
            QmBannerAction(label: '仍然再导一份', onPressed: () {}),
            QmBannerAction(label: '不导了', onPressed: () {}),
          ],
        ),
        scale: 1.15,
      );
      expect(find.textContaining('这个文件已经导入过。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('特大字号 1.30：两操作长文案横幅 pump 不抛错', (tester) async {
      await pumpBanner(
        tester,
        QmBanner(
          tone: QmBannerTone.warning,
          title: '文件超过大小上限，只是提示，不直接判失败。',
          message: '文件较大（25.0MB），超过建议上限 20MB，仍可继续导入。可以先压缩再重新选，也可以仍要导入，大文件检测会慢一些。',
          actions: [
            QmBannerAction(label: '仍然再导一份', onPressed: () {}),
            QmBannerAction(label: '不导了', onPressed: () {}),
          ],
        ),
        scale: 1.30,
      );
      expect(find.textContaining('文件超过大小上限'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
