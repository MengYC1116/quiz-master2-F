// R1 UI Kit widget 测试：亮/深主题、三档缩放（1.00/1.15/1.30）、
// Hover / Focus / Pressed / Disabled 关键状态。
//
// 样式断言方式：取 label 文字最近的祖先 Container（即组件本体）的
// BoxDecoration（颜色/边框/圆角），焦点描边取再上一层 Container。
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';

Future<void> pumpUi(
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
  // pumpAndSettle：让 AnimatedTheme 的主题切换动画跑完，否则亮/深
  // 切换后读到的还是旧主题色。
  await tester.pumpAndSettle();
}

/// label 文字最近的祖先 Container 的 BoxDecoration（组件本体）。
BoxDecoration bodyDecoration(WidgetTester tester, String label) {
  final containers = find.ancestor(
    of: find.text(label),
    matching: find.byType(Container),
  );
  final container = tester.widget<Container>(containers.first);
  return container.decoration! as BoxDecoration;
}

/// 再上一层 Container 的 BoxDecoration（焦点描边层）。
BoxDecoration ringDecoration(WidgetTester tester, String label) {
  final containers = find.ancestor(
    of: find.text(label),
    matching: find.byType(Container),
  );
  final container = tester.widget<Container>(containers.at(1));
  return container.decoration! as BoxDecoration;
}

Color lighten(Color c, double amount) => Color.lerp(c, Colors.white, amount)!;
Color darken(Color c, double amount) => Color.lerp(c, Colors.black, amount)!;

void main() {
  group('QmButton 亮色', () {
    testWidgets('主按钮：亮色 #2E7CF6 白字、圆角 10', (tester) async {
      await pumpUi(tester, QmButton(label: '确定', onPressed: () {}));
      final d = bodyDecoration(tester, '确定');
      expect(d.color, const Color(0xFF2E7CF6));
      expect((d.borderRadius as BorderRadius).topLeft.x, 10);
      final text = tester.widget<Text>(find.text('确定'));
      expect(text.style?.color, const Color(0xFFFFFFFF));
      expect(text.style?.fontSize, 14);
    });

    testWidgets('次按钮：白底蓝字细蓝边；危险按钮：err 字 + err 边；幽灵按钮：无底无边',
        (tester) async {
      await pumpUi(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QmButton(
              label: '次按钮',
              variant: QmButtonVariant.secondary,
              onPressed: () {},
            ),
            QmButton(
              label: '删除',
              variant: QmButtonVariant.danger,
              onPressed: () {},
            ),
            QmButton(
              label: '取消',
              variant: QmButtonVariant.ghost,
              onPressed: () {},
            ),
          ],
        ),
      );
      final secondary = bodyDecoration(tester, '次按钮');
      expect(secondary.color, const Color(0xFFFFFEF9));
      expect((secondary.border as Border).top.color, const Color(0xFF2E7CF6));
      expect(tester.widget<Text>(find.text('次按钮')).style?.color,
          const Color(0xFF175CD3));
      final danger = bodyDecoration(tester, '删除');
      expect((danger.border as Border).top.color, const Color(0xFFF5B8AE));
      expect(tester.widget<Text>(find.text('删除')).style?.color,
          const Color(0xFFB42318));
      final ghost = bodyDecoration(tester, '取消');
      expect(ghost.color, Colors.transparent);
      expect(ghost.border, isNull);
    });

    testWidgets('普通按钮：surface 底 + ink 字 + line-strong 边', (tester) async {
      await pumpUi(
        tester,
        QmButton(
          label: '返回',
          variant: QmButtonVariant.plain,
          onPressed: () {},
        ),
      );
      final d = bodyDecoration(tester, '返回');
      expect(d.color, const Color(0xFFFFFEF9));
      expect((d.border as Border).top.color, const Color(0xFFCFC39E));
      expect(tester.widget<Text>(find.text('返回')).style?.color,
          const Color(0xFF17233B));
    });

    testWidgets('小按钮与大按钮尺寸', (tester) async {
      await pumpUi(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QmButton(
              label: '小',
              size: QmButtonSize.small,
              onPressed: () {},
            ),
            QmButton(
              label: '确认整理，去下一道',
              size: QmButtonSize.large,
              block: true,
              onPressed: () {},
            ),
          ],
        ),
      );
      expect(tester.getSize(find.ancestor(
        of: find.text('小'),
        matching: find.byType(Container),
      ).first).height, 34);
      final large = bodyDecoration(tester, '确认整理，去下一道');
      expect((large.borderRadius as BorderRadius).topLeft.x, 14);
      expect(tester.getSize(find.ancestor(
        of: find.text('确认整理，去下一道'),
        matching: find.byType(Container),
      ).first).height, 56);
      expect(tester.widget<Text>(find.text('确认整理，去下一道')).style?.fontSize,
          17.5);
    });

    testWidgets('Hover：主按钮提亮 7%', (tester) async {
      await pumpUi(tester, QmButton(label: '确定', onPressed: () {}));
      final gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.text('确定')));
      await tester.pump();
      expect(bodyDecoration(tester, '确定').color,
          lighten(const Color(0xFF2E7CF6), 0.07));
      await gesture.removePointer();
    });

    testWidgets('Focus：2px accent 描边；失焦后描边透明', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpUi(
        tester,
        QmButton(label: '确定', onPressed: () {}, focusNode: node),
      );
      expect((ringDecoration(tester, '确定').border as Border).top.color,
          Colors.transparent);
      node.requestFocus();
      // 焦点变化在第一帧生效，onFocusChange → setState 的重建要第二帧。
      await tester.pump();
      await tester.pump();
      expect((ringDecoration(tester, '确定').border as Border).top.color,
          const Color(0xFF2E7CF6));
      expect((ringDecoration(tester, '确定').border as Border).top.width, 2);
      node.unfocus();
      await tester.pump();
      await tester.pump();
      expect((ringDecoration(tester, '确定').border as Border).top.color,
          Colors.transparent);
    });

    testWidgets('Pressed：主按钮加深 10%，松开后恢复并触发 onPressed',
        (tester) async {
      var tapped = false;
      await pumpUi(
        tester,
        QmButton(label: '确定', onPressed: () => tapped = true),
      );
      final gesture = await tester.press(find.text('确定'));
      await tester.pump();
      expect(bodyDecoration(tester, '确定').color,
          darken(const Color(0xFF2E7CF6), 0.10));
      await gesture.up();
      await tester.pump();
      expect(tapped, isTrue);
      expect(bodyDecoration(tester, '确定').color, const Color(0xFF2E7CF6));
    });

    testWidgets('Disabled：opacity .45、不可点、颜色仍是正常态', (tester) async {
      var tapped = false;
      await pumpUi(
        tester,
        QmButton(label: '不可点', onPressed: null),
      );
      final opacity = tester.widget<Opacity>(
        find.ancestor(of: find.text('不可点'), matching: find.byType(Opacity)).first,
      );
      expect(opacity.opacity, 0.45);
      expect(bodyDecoration(tester, '不可点').color, const Color(0xFF2E7CF6));
      await tester.tap(find.text('不可点'), warnIfMissed: false);
      await tester.pump();
      expect(tapped, isFalse);
    });

    testWidgets('键盘 Enter 触发 onPressed', (tester) async {
      var tapped = false;
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpUi(
        tester,
        QmButton(
          label: '确定',
          onPressed: () => tapped = true,
          focusNode: node,
        ),
      );
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(tapped, isTrue);
    });
  });

  group('QmButton 深色', () {
    testWidgets('主按钮：深色 #7FA8D0 底 + #131A24 深字', (tester) async {
      await pumpUi(
        tester,
        QmButton(label: '确定', onPressed: () {}),
        brightness: Brightness.dark,
      );
      final d = bodyDecoration(tester, '确定');
      expect(d.color, const Color(0xFF7FA8D0));
      expect(tester.widget<Text>(find.text('确定')).style?.color,
          const Color(0xFF131A24));
    });

    testWidgets('次按钮深色：surface 底 + accent-text 字 + accent 边',
        (tester) async {
      await pumpUi(
        tester,
        QmButton(
          label: '次按钮',
          variant: QmButtonVariant.secondary,
          onPressed: () {},
        ),
        brightness: Brightness.dark,
      );
      final d = bodyDecoration(tester, '次按钮');
      expect(d.color, const Color(0xFF262B33));
      expect((d.border as Border).top.color, const Color(0xFF7FA8D0));
      expect(tester.widget<Text>(find.text('次按钮')).style?.color,
          const Color(0xFFA9C6E4));
    });
  });

  group('三档缩放', () {
    testWidgets('1.15 / 1.30：按钮最小高按因子缩放，字号不重复缩放',
        (tester) async {
      await pumpUi(
        tester,
        QmButton(label: '确定', onPressed: () {}),
        scale: 1.15,
      );
      expect(tester.getSize(find.ancestor(
        of: find.text('确定'),
        matching: find.byType(Container),
      ).first).height, closeTo(46, 0.5));
      expect(tester.widget<Text>(find.text('确定')).style?.fontSize, 14);

      await pumpUi(
        tester,
        QmButton(label: '确定', onPressed: () {}),
        scale: 1.3,
      );
      expect(tester.getSize(find.ancestor(
        of: find.text('确定'),
        matching: find.byType(Container),
      ).first).height, closeTo(52, 0.5));
      expect(tester.widget<Text>(find.text('确定')).style?.fontSize, 14);
    });

    testWidgets('1.30：芯片与分段控件同步放大', (tester) async {
      await pumpUi(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const QmChip(label: '易错', selected: true, onTap: null),
            QmSegmented<String>(
              options: const [
                QmSegmentOption(value: 'a', label: '亮色'),
                QmSegmentOption(value: 'b', label: '深色'),
              ],
              value: 'a',
              onChanged: (_) {},
            ),
          ],
        ),
        scale: 1.3,
      );
      // 芯片本体高度 = 字行 + 上下内边距，均按 1.3 缩放。
      final chipHeight = tester.getSize(find.ancestor(
        of: find.text('易错'),
        matching: find.byType(Container),
      ).first).height;
      expect(chipHeight, greaterThan(30));
      final segHeight = tester.getSize(find.ancestor(
        of: find.text('亮色'),
        matching: find.byType(Container),
      ).first).height;
      expect(segHeight, greaterThan(30));
      // 字号样式本身仍是基准值（缩放只由 TextScaler 做一次）。
      expect(tester.widget<Text>(find.text('易错')).style?.fontSize, 13);
      expect(tester.widget<Text>(find.text('亮色')).style?.fontSize, 14);
    });
  });

  group('QmChip', () {
    testWidgets('未选中：surface 底 + line-strong 边 + ink-2 字；选中：accent 填充',
        (tester) async {
      var tapped = false;
      await pumpUi(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QmChip(label: '易错', selected: false, onTap: () => tapped = true),
            const QmChip(label: '常考', selected: true),
          ],
        ),
      );
      final unselected = bodyDecoration(tester, '易错');
      expect(unselected.color, const Color(0xFFFFFEF9));
      expect((unselected.border as Border).top.color, const Color(0xFFCFC39E));
      expect(tester.widget<Text>(find.text('易错')).style?.color,
          const Color(0xFF3D4E6B));
      final selected = bodyDecoration(tester, '常考');
      expect(selected.color, const Color(0xFF2E7CF6));
      expect(find.text('✓'), findsOneWidget);
      await tester.tap(find.text('易错'));
      await tester.pump();
      expect(tapped, isTrue);
    });

    testWidgets('预置标签：易错 / 常考 / 需重做', (tester) async {
      expect(QmChip.presetTags, ['易错', '常考', '需重做']);
    });

    testWidgets('学科芯片：选中态用学科色填充；深色下字色 #1E2228',
        (tester) async {
      await pumpUi(
        tester,
        const QmChip(label: '数学', selected: true, subjectId: 'math'),
      );
      expect(bodyDecoration(tester, '数学').color, const Color(0xFF2E7CF6));
      await pumpUi(
        tester,
        const QmChip(label: '数学', selected: true, subjectId: 'math'),
        brightness: Brightness.dark,
      );
      expect(bodyDecoration(tester, '数学').color, const Color(0xFF87A9CC));
      expect(tester.widget<Text>(find.text('数学')).style?.color,
          const Color(0xFF1E2228));
    });

    testWidgets('可删除芯片：accent-soft 底 + ×，点整片删除', (tester) async {
      var deleted = false;
      await pumpUi(
        tester,
        QmChip(label: '审题失误', onDelete: () => deleted = true),
      );
      final d = bodyDecoration(tester, '审题失误 ✕');
      expect(d.color, const Color(0xFFE1EDFF));
      expect((d.border as Border).top.color, const Color(0xFF2E7CF6));
      await tester.tap(find.text('审题失误 ✕'));
      await tester.pump();
      expect(deleted, isTrue);
    });
  });

  group('QmSegmented', () {
    testWidgets('选中段 accent 填充，未选中段 muted 字；点按切换', (tester) async {
      String value = 'light';
      await pumpUi(
        tester,
        StatefulBuilder(
          builder: (context, setState) => QmSegmented<String>(
            options: const [
              QmSegmentOption(value: 'light', label: '亮色'),
              QmSegmentOption(value: 'dark', label: '深色'),
              QmSegmentOption(value: 'system', label: '跟随系统'),
            ],
            value: value,
            onChanged: (v) => setState(() => value = v),
          ),
        ),
      );
      expect(bodyDecoration(tester, '亮色').color, const Color(0xFF2E7CF6));
      expect(tester.widget<Text>(find.text('深色')).style?.color,
          const Color(0xFF5F718E));
      await tester.tap(find.text('深色'));
      await tester.pump();
      expect(value, 'dark');
      expect(bodyDecoration(tester, '深色').color, const Color(0xFF2E7CF6));
    });

    testWidgets('Disabled：opacity .45', (tester) async {
      await pumpUi(
        tester,
        QmSegmented<String>(
          options: const [QmSegmentOption(value: 'a', label: '亮色')],
          value: 'a',
          onChanged: null,
        ),
      );
      final opacity = tester.widget<Opacity>(
        find.ancestor(of: find.text('亮色'), matching: find.byType(Opacity)).first,
      );
      expect(opacity.opacity, 0.45);
    });
  });

  group('QmStatusPill', () {
    testWidgets('错因四态文案与颜色（亮色）', (tester) async {
      await pumpUi(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QmStatusPill.cause(QmCauseStatus.pending),
            QmStatusPill.cause(QmCauseStatus.inProgress),
            QmStatusPill.cause(QmCauseStatus.solved),
            QmStatusPill.cause(QmCauseStatus.recheck),
          ],
        ),
      );
      expect(bodyDecoration(tester, '待解决').color, const Color(0xFFFFF3D1));
      expect(bodyDecoration(tester, '解决中').color, const Color(0xFFE1EDFF));
      expect(bodyDecoration(tester, '已解决').color, const Color(0xFFE1EDFF));
      expect(bodyDecoration(tester, '复查').color, const Color(0xFFFFE9E5));
      expect(tester.widget<Text>(find.text('待解决')).style?.color,
          const Color(0xFF8A5A00));
      expect(tester.widget<Text>(find.text('复查')).style?.color,
          const Color(0xFFB42318));
    });

    testWidgets('错因四态深色', (tester) async {
      await pumpUi(
        tester,
        QmStatusPill.cause(QmCauseStatus.recheck),
        brightness: Brightness.dark,
      );
      expect(bodyDecoration(tester, '复查').color, const Color(0xFF352C31));
      expect(tester.widget<Text>(find.text('复查')).style?.color,
          const Color(0xFFD2A3AC));
    });

    testWidgets('warn / err / info 三色提示', (tester) async {
      await pumpUi(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QmStatusPill.tone(label: '警告', tone: QmTone.warn),
            QmStatusPill.tone(label: '错误', tone: QmTone.error),
            QmStatusPill.tone(label: '提示', tone: QmTone.info),
          ],
        ),
      );
      expect(bodyDecoration(tester, '警告').color, const Color(0xFFFFF3D1));
      expect(bodyDecoration(tester, '错误').color, const Color(0xFFFFE9E5));
      expect(bodyDecoration(tester, '提示').color, const Color(0xFFE1EDFF));
    });
  });

  group('QmBanner', () {
    testWidgets('三档颜色与关闭按钮', (tester) async {
      var dismissed = false;
      await pumpUi(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const QmBanner(tone: QmBannerTone.error, message: '备份失败'),
            const QmBanner(tone: QmBannerTone.warning, message: '文件已存在'),
            const QmBanner(tone: QmBannerTone.info, message: '已同步'),
            QmBanner(
              tone: QmBannerTone.error,
              message: '出错了',
              onDismiss: () => dismissed = true,
            ),
          ],
        ),
      );
      expect(bodyDecoration(tester, '备份失败').color, const Color(0xFFFFE9E5));
      expect(bodyDecoration(tester, '文件已存在').color, const Color(0xFFFFF3D1));
      expect(bodyDecoration(tester, '已同步').color, const Color(0xFFE1EDFF));
      expect(find.text('知道了'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pump();
      expect(dismissed, isTrue);
    });

    testWidgets('操作按钮与标题粗体前导', (tester) async {
      var again = false;
      await pumpUi(
        tester,
        QmBanner(
          tone: QmBannerTone.warning,
          title: '这个文件已经导入过。',
          message: '再导一份会多出一组重复任务。',
          actions: [
            QmBannerAction(label: '仍然再导一份', onPressed: () => again = true),
          ],
        ),
      );
      await tester.tap(find.text('仍然再导一份'));
      await tester.pump();
      expect(again, isTrue);
    });

    testWidgets('深色三档', (tester) async {
      await pumpUi(
        tester,
        const QmBanner(tone: QmBannerTone.error, message: '备份失败'),
        brightness: Brightness.dark,
      );
      expect(bodyDecoration(tester, '备份失败').color, const Color(0xFF352C31));
    });
  });

  group('QmEmptyState', () {
    testWidgets('小伙伴 + 标题 + 说明 + CTA', (tester) async {
      var tapped = false;
      await pumpUi(
        tester,
        QmEmptyState(
          title: '这里还没有错题，去收集吧',
          description: '在收集中心收进来的题，整理好之后都会放在这里。',
          actionLabel: '去收集中心',
          onAction: () => tapped = true,
        ),
      );
      expect(find.byType(CompanionWidget), findsOneWidget);
      expect(find.text('这里还没有错题，去收集吧'), findsOneWidget);
      expect(find.text('在收集中心收进来的题，整理好之后都会放在这里。'), findsOneWidget);
      await tester.tap(find.text('去收集中心'));
      await tester.pump();
      expect(tapped, isTrue);
    });
  });

  group('QmRowLine', () {
    testWidgets('虚线分隔线渲染（line / paper 两档）', (tester) async {
      await pumpUi(
        tester,
        const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QmRowLine(),
            QmRowLine(kind: QmRowLineKind.paper),
          ],
        ),
      );
      expect(find.byType(QmRowLine), findsNWidgets(2));
      expect(find.byType(CustomPaint), findsWidgets);
      expect(
        tester.getSize(find.byType(QmRowLine).first).height,
        1,
      );
    });
  });

  group('QmFoldSection', () {
    testWidgets('折叠切换：点头部回调，展开后显示内容与“收起”箭头',
        (tester) async {
      var expanded = false;
      var toggles = 0;
      await pumpUi(
        tester,
        StatefulBuilder(
          builder: (context, setState) => QmFoldSection(
            title: '外观',
            expanded: expanded,
            onToggle: () => setState(() {
              expanded = !expanded;
              toggles++;
            }),
            child: const Text('主题内容'),
          ),
        ),
      );
      expect(find.text('主题内容'), findsNothing);
      expect(find.text('▸ 展开'), findsOneWidget);
      await tester.tap(find.text('外观'));
      await tester.pump();
      expect(toggles, 1);
      expect(find.text('主题内容'), findsOneWidget);
      expect(find.text('▾ 收起'), findsOneWidget);
    });

    testWidgets('三种形态都渲染：group / form / detail', (tester) async {
      await pumpUi(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QmFoldSection(
              title: '学科',
              expanded: true,
              onToggle: () {},
              variant: QmFoldVariant.group,
              child: const Text('组内容'),
            ),
            QmFoldSection(
              title: '文件夹（归类）',
              subtitle: '可多选',
              expanded: true,
              onToggle: () {},
              variant: QmFoldVariant.form,
              child: const Text('表单内容'),
            ),
            QmFoldSection(
              title: '答案解析',
              expanded: false,
              onToggle: () {},
              variant: QmFoldVariant.detail,
              child: const Text('详情内容'),
            ),
          ],
        ),
      );
      expect(find.text('组内容'), findsOneWidget);
      expect(find.text('表单内容'), findsOneWidget);
      expect(find.text('详情内容'), findsNothing);
      // detail 形态箭头只有符号，没有“展开”二字。
      expect(find.text('▸'), findsOneWidget);
    });
  });

  group('QmGlyph（D3：文字符号，不用图标字体）', () {
    testWidgets('常用符号渲染，且 UI Kit 内无 Icon', (tester) async {
      await pumpUi(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const QmGlyph(QmGlyphs.back),
            const QmGlyph(QmGlyphs.plus),
            const QmGlyph(QmGlyphs.close),
            const QmGlyph(QmGlyphs.check),
            const QmGlyph(QmGlyphs.chevronRight),
            QmButton(
              label: '返回',
              leadingGlyph: QmGlyphs.back,
              variant: QmButtonVariant.plain,
              onPressed: () {},
            ),
            const QmChip(label: '标签', selected: true),
            QmStatusPill.cause(QmCauseStatus.pending),
            const QmBanner(tone: QmBannerTone.warning, message: '提示'),
            const QmEmptyState(title: '空'),
            QmFoldSection(
              title: '组',
              expanded: true,
              onToggle: () {},
              child: const Text('内容'),
            ),
          ],
        ),
      );
      expect(find.text('←'), findsNWidgets(2));
      expect(find.text('＋'), findsOneWidget);
      expect(find.text('×'), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
    });
  });
}
