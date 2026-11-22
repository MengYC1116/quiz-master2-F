// Win11 反馈 Q3：答案芯片开关 selectionAwareDeletable。
//
// 默认（开关省略 / false）可删除分支空闲态恒为 accent-soft（既有外观，
// 由 test/uikit_test.dart:448-458 锁定，本文件不重复改那组断言）；
// 开关开时空闲态按 selected 分支——未选白底、已选 accent 填充，
// 悬停/按压仍走 err 色，× 删除区与选中相互独立。整理页错因芯片与
// 错题本筛选芯片不传开关，外观保持不变。
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';

Future<void> _pumpChip(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      darkTheme: AppTheme.dark(scale: 1.0),
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      home: Scaffold(body: Center(child: SizedBox(width: 320, child: child))),
    ),
  );
  await tester.pumpAndSettle();
}

/// label 文字最近的祖先 Container 的 BoxDecoration（芯片本体）。
/// 仅可删除（无 onTap）时文字带 ` ✕` 后缀；双区（onTap + onDelete）
/// 时标签与 × 分离，文字就是 label 本身。
BoxDecoration _chipDecoration(
  WidgetTester tester,
  String label, {
  bool bothZones = false,
}) {
  final text = bothZones ? label : '$label ✕';
  final containers = find.ancestor(
    of: find.text(text),
    matching: find.byType(Container),
  );
  final container = tester.widget<Container>(containers.first);
  return container.decoration! as BoxDecoration;
}

Color _textColor(
  WidgetTester tester,
  String label, {
  bool bothZones = false,
}) =>
    tester
        .widget<Text>(find.text(bothZones ? label : '$label ✕'))
        .style!
        .color!;

Future<void> _hoverChip(WidgetTester tester, String label) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  await tester.pump();
  await gesture.moveTo(tester.getCenter(find.text('$label ✕')));
  await tester.pump();
  addTearDown(gesture.removePointer);
}

void main() {
  group('Win11 反馈 Q3：selectionAwareDeletable', () {
    testWidgets('开关省略 → 现有浅蓝（默认外观不变）', (tester) async {
      await _pumpChip(
        tester,
        QmChip(label: 'A', onDelete: () {}),
      );
      final d = _chipDecoration(tester, 'A');
      expect(d.color, const Color(0xFFE1EDFF));
      expect((d.border as Border).top.color, const Color(0xFF2E7CF6));
      expect(_textColor(tester, 'A'), const Color(0xFF175CD3));
    });

    testWidgets('开关 false → 现有浅蓝', (tester) async {
      await _pumpChip(
        tester,
        QmChip(
          label: 'A',
          selected: false,
          selectionAwareDeletable: false,
          onDelete: () {},
        ),
      );
      final d = _chipDecoration(tester, 'A');
      expect(d.color, const Color(0xFFE1EDFF));
      expect((d.border as Border).top.color, const Color(0xFF2E7CF6));
      expect(_textColor(tester, 'A'), const Color(0xFF175CD3));
    });

    testWidgets('开关 false + 已选 → 仍是浅蓝（不读 selected）', (tester) async {
      await _pumpChip(
        tester,
        QmChip(
          label: 'A',
          selected: true,
          selectionAwareDeletable: false,
          onDelete: () {},
        ),
      );
      final d = _chipDecoration(tester, 'A');
      expect(d.color, const Color(0xFFE1EDFF));
      expect((d.border as Border).top.color, const Color(0xFF2E7CF6));
    });

    testWidgets('开关 true + 未选 → 白底 + ink-2 字 + line-strong 边',
        (tester) async {
      await _pumpChip(
        tester,
        QmChip(
          label: 'A',
          selected: false,
          selectionAwareDeletable: true,
          onDelete: () {},
        ),
      );
      final d = _chipDecoration(tester, 'A');
      expect(d.color, const Color(0xFFFFFFFF));
      expect((d.border as Border).top.color, const Color(0xFFB9C6D8));
      expect(_textColor(tester, 'A'), const Color(0xFF3D4E6B));
    });

    testWidgets('开关 true + 已选 → accent 填充 + 白字 + accent 边',
        (tester) async {
      await _pumpChip(
        tester,
        QmChip(
          label: 'A',
          selected: true,
          selectionAwareDeletable: true,
          onDelete: () {},
        ),
      );
      final d = _chipDecoration(tester, 'A');
      expect(d.color, const Color(0xFF2E7CF6));
      expect((d.border as Border).top.color, const Color(0xFF2E7CF6));
      expect(_textColor(tester, 'A'), const Color(0xFFFFFFFF));
    });

    testWidgets('开关 true + 未选，悬停 → err 色（与默认分支一致）',
        (tester) async {
      await _pumpChip(
        tester,
        QmChip(
          label: 'A',
          selected: false,
          selectionAwareDeletable: true,
          onDelete: () {},
        ),
      );
      await _hoverChip(tester, 'A');
      final d = _chipDecoration(tester, 'A');
      expect(d.color, const Color(0xFFFFE9E5));
      expect((d.border as Border).top.color, const Color(0xFFF5B8AE));
      expect(_textColor(tester, 'A'), const Color(0xFFB42318));
    });

    testWidgets('开关 true + 已选，悬停 → err 色（悬停压过选中）',
        (tester) async {
      await _pumpChip(
        tester,
        QmChip(
          label: 'A',
          selected: true,
          selectionAwareDeletable: true,
          onDelete: () {},
        ),
      );
      await _hoverChip(tester, 'A');
      final d = _chipDecoration(tester, 'A');
      expect(d.color, const Color(0xFFFFE9E5));
      expect((d.border as Border).top.color, const Color(0xFFF5B8AE));
      expect(_textColor(tester, 'A'), const Color(0xFFB42318));
    });

    testWidgets('开关 true + 未选，按压 → err 混色（与默认分支一致）',
        (tester) async {
      await _pumpChip(
        tester,
        QmChip(
          label: 'A',
          selected: false,
          selectionAwareDeletable: true,
          onDelete: () {},
        ),
      );
      final gesture = await tester.press(find.text('A ✕'));
      await tester.pump();
      final d = _chipDecoration(tester, 'A');
      expect(
        d.color,
        Color.lerp(
          const Color(0xFFFFE9E5),
          const Color(0xFFB42318),
          0.18,
        ),
      );
      expect((d.border as Border).top.color, const Color(0xFFF5B8AE));
      expect(_textColor(tester, 'A'), const Color(0xFFB42318));
      await gesture.up();
      await tester.pump();
    });

    testWidgets('× 与选中独立：已选芯片点 × 只删除不选中；点片身只选中不删除',
        (tester) async {
      var tapped = 0;
      var deleted = 0;
      await _pumpChip(
        tester,
        QmChip(
          label: 'A',
          selected: true,
          selectionAwareDeletable: true,
          onTap: () => tapped++,
          onDelete: () => deleted++,
          deleteTooltip: '删除选项 A',
        ),
      );
      await tester.tap(find.byTooltip('删除选项 A'));
      await tester.pump();
      expect(deleted, 1);
      expect(tapped, 0);
      await tester.tap(find.text('A'));
      await tester.pump();
      expect(tapped, 1);
      expect(deleted, 1);
    });

    testWidgets('× 与选中独立：未选芯片点 × 只删除，不触发选中',
        (tester) async {
      var tapped = 0;
      var deleted = 0;
      await _pumpChip(
        tester,
        QmChip(
          label: 'B',
          selected: false,
          selectionAwareDeletable: true,
          onTap: () => tapped++,
          onDelete: () => deleted++,
          deleteTooltip: '删除选项 B',
        ),
      );
      await tester.tap(find.byTooltip('删除选项 B'));
      await tester.pump();
      expect(deleted, 1);
      expect(tapped, 0);
    });

    testWidgets('整理页错因芯片不变：可删除、无开关、未选 → 浅蓝',
        (tester) async {
      await _pumpChip(
        tester,
        QmChip(label: '审题失误', onDelete: () {}),
      );
      final d = _chipDecoration(tester, '审题失误');
      expect(d.color, const Color(0xFFE1EDFF));
      expect((d.border as Border).top.color, const Color(0xFF2E7CF6));
      expect(_textColor(tester, '审题失误'), const Color(0xFF175CD3));
    });

    testWidgets('错题本筛选芯片不变：已选 + 可删除、无开关 → 仍浅蓝非实心蓝',
        (tester) async {
      await _pumpChip(
        tester,
        QmChip(label: '错因：计算错误', selected: true, onDelete: () {}),
      );
      final d = _chipDecoration(tester, '错因：计算错误');
      expect(d.color, const Color(0xFFE1EDFF));
      expect((d.border as Border).top.color, const Color(0xFF2E7CF6));
      expect(_textColor(tester, '错因：计算错误'), const Color(0xFF175CD3));
    });
  });
}
