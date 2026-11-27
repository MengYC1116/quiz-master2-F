// WP-A #1（九项修复 REV5 §1 + R1 + S2 + T2-3）：答案区选项编辑器回归测试。
//
// 覆盖定稿 §1.5 全部用例 + R1-5：
// - answerConfigValid（R1-3 拆分：结构完整、内部一致，与判分无关；
//   R1-4 纠正：多选 answer 是自由文本，只按“去空白后非空”判，不解析）。
// - objectiveGradingAvailable（R1-3：answerConfigValid &&
//   !answerPendingRecheck && 题型 ∈ {单选，判断}；多选永远 false；
//   不再读 optionLabelsConfirmed 列）。
// - AnswerOptionEditor：无标签文本框、无「确认选项」按钮；按位增删、
//   「+」追加下一字母、判断题固定两行、单选点选正确答案即带重确认
//   信号（S2-1：信号 = 本会话内点选过正确答案位）。
// - R1-5：标签变更后重选正确答案清 pending；改非正确答案位旧答案
//   仍有效；多选自由文本只按非空判；删位后重加同一字母不恢复旧
//   correctOption；optionLabelsConfirmed 新旧值均不影响新判定。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/ocr/option_labels_editor.dart';
import 'package:quiz_master2/widgets/uikit.dart';

Question _q(
  String id, {
  String subjectId = 'math',
  String? questionType,
  List<String>? optionLabels,
  bool optionLabelsConfirmed = false,
  String? correctOption,
  String? answer,
  String? explanation,
  bool answerPendingRecheck = false,
  bool isOrganized = false,
}) => Question(
  id: id,
  title: '题 $id',
  subjectId: subjectId,
  questionType: questionType,
  optionLabels: optionLabels,
  optionLabelsConfirmed: optionLabelsConfirmed,
  correctOption: correctOption,
  answer: answer,
  explanation: explanation,
  answerPendingRecheck: answerPendingRecheck,
  createdAt: DateTime(2026, 11, 8),
  isOrganized: isOrganized,
  sliceKind: 'material',
  sliceText: '题：$id',
);

void main() {
  // -------------------------------------------------------------------------
  // answerConfigValid（R1-3 / R1-4）
  // -------------------------------------------------------------------------
  group('answerConfigValid', () {
    test('单选：标签 ≥2 且正确答案在标签中 → 有效（confirmed=false 也不影响）', () {
      final q = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        optionLabelsConfirmed: false,
        correctOption: 'C',
      );
      expect(q.answerConfigValid, isTrue);
      expect(objectiveGradingAvailable(q), isTrue);
    });

    test('单选：正确答案为空 → 无效', () {
      final q = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
      );
      expect(q.answerConfigValid, isFalse);
      expect(objectiveGradingAvailable(q), isFalse);
    });

    test('单选：正确答案 E 不在标签中 → 无效', () {
      final q = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        correctOption: 'E',
      );
      expect(q.answerConfigValid, isFalse);
      expect(objectiveGradingAvailable(q), isFalse);
    });

    test('单选：标签只剩 [A] / 标签为空 / 标签为 null → 均无效', () {
      expect(
        _q(
          'q1',
          questionType: 'choice_single',
          optionLabels: const ['A'],
          correctOption: 'A',
        ).answerConfigValid,
        isFalse,
      );
      expect(
        _q(
          'q1',
          questionType: 'choice_single',
          optionLabels: const [],
          correctOption: 'A',
        ).answerConfigValid,
        isFalse,
      );
      expect(
        _q(
          'q1',
          questionType: 'choice_single',
          correctOption: 'A',
        ).answerConfigValid,
        isFalse,
      );
    });

    test('单选：待核对时结构仍有效，但判分不可用（R1-3 拆分）', () {
      final q = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        correctOption: 'B',
        answerPendingRecheck: true,
      );
      expect(q.answerConfigValid, isTrue);
      expect(objectiveGradingAvailable(q), isFalse);
      expect(gradeObjective(q, 'B'), isNull);
    });

    test('判断：correctOption 为 正确/错误 → 有效；null 或字母 → 无效', () {
      expect(
        _q(
          'q1',
          questionType: 'true_false',
          correctOption: '正确',
        ).answerConfigValid,
        isTrue,
      );
      expect(
        _q(
          'q1',
          questionType: 'true_false',
          correctOption: '错误',
        ).answerConfigValid,
        isTrue,
      );
      expect(
        _q('q1', questionType: 'true_false').answerConfigValid,
        isFalse,
      );
      expect(
        _q(
          'q1',
          questionType: 'true_false',
          correctOption: 'A',
        ).answerConfigValid,
        isFalse,
      );
      expect(
        objectiveGradingAvailable(
          _q('q1', questionType: 'true_false', correctOption: '正确'),
        ),
        isTrue,
      );
    });

    test('多选：answer 自由文本只按“去空白后非空”判，不解析（R1-4）', () {
      Question multi(String? answer) => _q(
        'q1',
        questionType: 'choice_multi',
        optionLabels: const ['A', 'B', 'C', 'D'],
        answer: answer,
      );
      // 常规、自然语言、重复字母、未知字母 → 全部有效。
      expect(multi('A、C').answerConfigValid, isTrue);
      expect(multi('选 A 和 C').answerConfigValid, isTrue);
      expect(multi('第一项和第三项').answerConfigValid, isTrue);
      expect(multi('A、A').answerConfigValid, isTrue);
      expect(multi('选 X 和 Y').answerConfigValid, isTrue);
      // 空字符串 / 全空白 / null → 无效。
      expect(multi('').answerConfigValid, isFalse);
      expect(multi('   ').answerConfigValid, isFalse);
      expect(multi(null).answerConfigValid, isFalse);
      // 多选永远不判分。
      expect(objectiveGradingAvailable(multi('A、C')), isFalse);
      expect(gradeObjective(multi('A、C'), 'A'), isNull);
    });

    test('多选/不定项：标签不足 2 位 → 无效（与 answer 无关）', () {
      expect(
        _q(
          'q1',
          questionType: 'choice_multi',
          optionLabels: const ['A'],
          answer: 'A',
        ).answerConfigValid,
        isFalse,
      );
      expect(
        _q(
          'q1',
          questionType: 'choice_variable',
          optionLabels: const ['A', 'B'],
          answer: 'A、B',
        ).answerConfigValid,
        isTrue,
      );
    });

    test('其他题型：沿用 hasValidStandardAnswer 口径', () {
      expect(
        _q(
          'q1',
          questionType: 'calculation',
          answer: 'x=2',
        ).answerConfigValid,
        isTrue,
      );
      expect(
        _q('q1', questionType: 'calculation').answerConfigValid,
        isFalse,
      );
      expect(
        _q(
          'q1',
          questionType: 'calculation',
          answer: 'x=2',
          answerPendingRecheck: true,
        ).answerConfigValid,
        isFalse,
      );
    });

    test('R1-5：optionLabelsConfirmed 新旧值均不影响新判定', () {
      final confirmedTrue = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        optionLabelsConfirmed: true,
        correctOption: 'B',
      );
      final confirmedFalse = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        optionLabelsConfirmed: false,
        correctOption: 'B',
      );
      expect(confirmedTrue.answerConfigValid, isTrue);
      expect(confirmedFalse.answerConfigValid, isTrue);
      expect(objectiveGradingAvailable(confirmedTrue), isTrue);
      expect(objectiveGradingAvailable(confirmedFalse), isTrue);
      expect(gradeObjective(confirmedFalse, 'B'), 1);
      expect(gradeObjective(confirmedFalse, 'A'), 0);
    });

    test('gradeObjective：所选标签不在当前标签集时拒绝判分', () {
      final q = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        correctOption: 'B',
      );
      expect(gradeObjective(q, 'E'), isNull);
      final tf = _q(
        'q1',
        questionType: 'true_false',
        correctOption: '正确',
      );
      expect(gradeObjective(tf, '正确'), 1);
      expect(gradeObjective(tf, '错误'), 0);
      expect(gradeObjective(tf, 'A'), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // AnswerOptionEditor
  // -------------------------------------------------------------------------
  group('AnswerOptionEditor', () {
    testWidgets('单选：纵向列出选项位，无标签文本框、无「确认选项」按钮', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        correctOption: 'B',
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.widgetWithText(QmButton, '确认选项'), findsNothing);
      for (final letter in ['A', 'B', 'C', 'D']) {
        expect(find.widgetWithText(QmChip, letter), findsOneWidget);
      }
      expect(find.widgetWithText(QmButton, '+ 添加选项'), findsOneWidget);
      // B 已选。
      expect(
        find.widgetWithText(QmChip, 'B').evaluate().first.widget as QmChip,
        isA<QmChip>().having((c) => c.selected, 'selected', isTrue),
      );
    });

    testWidgets('单选：点选正确答案即带重确认信号（S2-1）', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        correctOption: 'B',
      );
      await tester.tap(find.widgetWithText(QmChip, 'C'));
      await tester.pumpAndSettle();
      expect(cap.correctCalls, ['C']);
      expect(cap.reconfirmCalls, [true]);
      // 再次点选同一位：仍是本次会话内的点选，信号再次发出。
      await tester.tap(find.widgetWithText(QmChip, 'C'));
      await tester.pumpAndSettle();
      expect(cap.correctCalls, ['C', 'C']);
      expect(cap.reconfirmCalls, [true, true]);
    });

    testWidgets('「+」追加下一字母，正确答案保持原值', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        correctOption: 'B',
      );
      await tester.tap(find.widgetWithText(QmButton, '+ 添加选项'));
      await tester.pumpAndSettle();
      expect(cap.labelsCalls.last, ['A', 'B', 'C', 'D', 'E']);
      expect(find.widgetWithText(QmChip, 'E'), findsOneWidget);
      expect(cap.correctCalls, isEmpty, reason: '追加位不改动正确答案');
      await tester.tap(find.widgetWithText(QmButton, '+ 添加选项'));
      await tester.pumpAndSettle();
      expect(cap.labelsCalls.last, ['A', 'B', 'C', 'D', 'E', 'F']);
    });

    testWidgets('删非正确答案位：旧答案仍有效，不产生重确认信号变化', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        correctOption: 'C',
      );
      await tester.tap(find.byTooltip('删除选项 B'));
      await tester.pumpAndSettle();
      expect(cap.labelsCalls.last, ['A', 'C', 'D']);
      expect(cap.correctCalls, isEmpty, reason: '正确答案 C 未被删，不清空');
      expect(cap.reconfirmCalls, isEmpty);
      expect(find.widgetWithText(QmChip, 'B'), findsNothing);
    });

    testWidgets('删正确答案位：correctOption 清空并提示重新选定', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        correctOption: 'C',
      );
      await tester.tap(find.byTooltip('删除选项 C'));
      await tester.pumpAndSettle();
      expect(cap.labelsCalls.last, ['A', 'B', 'D']);
      expect(cap.correctCalls, [null]);
      expect(find.textContaining('未设正确答案'), findsOneWidget);
    });

    testWidgets('判断题：只显示「正确」「错误」两行，无「+」、无删除', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'true_false',
        correctOption: '正确',
      );
      expect(find.widgetWithText(QmChip, '正确'), findsOneWidget);
      expect(find.widgetWithText(QmChip, '错误'), findsOneWidget);
      expect(find.widgetWithText(QmButton, '+ 添加选项'), findsNothing);
      expect(find.byTooltip('删除选项 正确'), findsNothing);
      expect(find.byTooltip('删除选项 错误'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.widgetWithText(QmChip, '错误'));
      await tester.pumpAndSettle();
      expect(cap.correctCalls, ['错误']);
      expect(cap.reconfirmCalls, [true]);
    });

    testWidgets('非选择题：不显示编辑器', (tester) async {
      final cap = _Cap();
      await _pump(tester, cap, questionType: 'fill_blank');
      expect(find.widgetWithText(QmChip, 'A'), findsNothing);
      expect(find.widgetWithText(QmButton, '+ 添加选项'), findsNothing);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('§1.4：optionLabels 为 null 时默认 A–D，且只写入一次', (tester) async {
      final cap = _Cap();
      await _pump(tester, cap, questionType: 'choice_single');
      for (final letter in ['A', 'B', 'C', 'D']) {
        expect(find.widgetWithText(QmChip, letter), findsOneWidget);
      }
      // 初次进入整理：默认值上报给调用方一次（表单级写入）。
      expect(cap.labelsCalls, [
        ['A', 'B', 'C', 'D'],
      ]);
      await tester.pumpAndSettle();
      expect(cap.labelsCalls, [
        ['A', 'B', 'C', 'D'],
      ], reason: '不重复上报');
    });

    testWidgets('§1.4：库里已有三位时不恢复成四位', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C'],
        correctOption: 'B',
      );
      expect(find.widgetWithText(QmChip, 'D'), findsNothing);
      expect(cap.labelsCalls, isEmpty, reason: '已有值时不写默认值');
      await tester.tap(find.byTooltip('删除选项 A'));
      await tester.pumpAndSettle();
      expect(cap.labelsCalls.last, ['B', 'C']);
      // 重建后仍为两位，不恢复。
      await tester.pumpAndSettle();
      expect(find.widgetWithText(QmChip, 'A'), findsNothing);
      expect(find.widgetWithText(QmChip, 'B'), findsOneWidget);
      expect(find.widgetWithText(QmChip, 'C'), findsOneWidget);
    });

    testWidgets('§1.4：检测结果只作初始值（detectedOptionLabels 缝）', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        detectedOptionLabels: const ['A', 'B'],
      );
      expect(find.widgetWithText(QmChip, 'A'), findsOneWidget);
      expect(find.widgetWithText(QmChip, 'B'), findsOneWidget);
      expect(find.widgetWithText(QmChip, 'C'), findsNothing);
      expect(cap.labelsCalls, [
        ['A', 'B'],
      ]);
    });

    testWidgets('WP-A #1 收尾：5 项检测值作初始值（optionLabels == null）', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        detectedOptionLabels: const ['A', 'B', 'C', 'D', 'E'],
      );
      for (final letter in ['A', 'B', 'C', 'D', 'E']) {
        expect(find.widgetWithText(QmChip, letter), findsOneWidget);
      }
      expect(find.widgetWithText(QmChip, 'F'), findsNothing);
      expect(cap.labelsCalls, [
        ['A', 'B', 'C', 'D', 'E'],
      ]);
    });

    testWidgets('WP-A #1 收尾：已有 optionLabels 时检测值永不覆盖', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C'],
        correctOption: 'B',
        detectedOptionLabels: const ['A', 'B', 'C', 'D', 'E'],
      );
      expect(find.widgetWithText(QmChip, 'C'), findsOneWidget);
      expect(find.widgetWithText(QmChip, 'D'), findsNothing);
      expect(find.widgetWithText(QmChip, 'E'), findsNothing);
      expect(cap.labelsCalls, isEmpty, reason: '已有值时检测值不写回');
    });

    testWidgets('多选：点选多个位走 answer 字段（onMultiSelectionChanged）', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_multi',
        optionLabels: const ['A', 'B', 'C', 'D'],
      );
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.widgetWithText(QmChip, 'A'));
      await tester.pumpAndSettle();
      expect(cap.multiCalls, ['A']);
      await tester.tap(find.widgetWithText(QmChip, 'C'));
      await tester.pumpAndSettle();
      expect(cap.multiCalls, ['A', 'A,C']);
      await tester.tap(find.widgetWithText(QmChip, 'A'));
      await tester.pumpAndSettle();
      expect(cap.multiCalls, ['A', 'A,C', 'C']);
      expect(cap.correctCalls, isEmpty, reason: '多选不写 correctOption');
    });

    testWidgets('多选改标签 + 旧答案：重确认复选框；再改标签则信号失效', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_multi',
        optionLabels: const ['A', 'B', 'C', 'D'],
        storedOptionLabels: const ['A', 'B', 'C', 'D'],
        hadOldAnswer: true,
      );
      // 初始与库里一致：不显示复选框。
      expect(find.text('确认此答案和解析仍有效'), findsNothing);
      await tester.tap(find.widgetWithText(QmButton, '+ 添加选项'));
      await tester.pumpAndSettle();
      expect(find.textContaining('选项标签已改：旧答案与解析待重新核对'), findsOneWidget);
      expect(find.text('确认此答案和解析仍有效'), findsOneWidget);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, [true]);
      // 再改一次标签：旧确认失效。
      await tester.tap(find.widgetWithText(QmButton, '+ 添加选项'));
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, [true, false]);
      expect(
        find.byType(Checkbox).evaluate().first.widget as Checkbox,
        isA<Checkbox>().having((c) => c.value, 'value', isFalse),
      );
    });

    testWidgets('R1-5：删位后重加同一字母，旧 correctOption 不被恢复', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        correctOption: 'C',
      );
      await tester.tap(find.byTooltip('删除选项 C'));
      await tester.pumpAndSettle();
      expect(cap.correctCalls, [null]);
      // 再删 D → [A,B]，再「+」→ [A,B,C]：C 回来了，但正确答案仍是空。
      await tester.tap(find.byTooltip('删除选项 D'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(QmButton, '+ 添加选项'));
      await tester.pumpAndSettle();
      expect(cap.labelsCalls.last, ['A', 'B', 'C']);
      expect(cap.correctCalls, [null], reason: '重加的 C 不恢复旧答案');
      expect(find.textContaining('未设正确答案'), findsOneWidget);
    });

    testWidgets('S2-1：点选后改非答案位，信号不重置；删答案位则信号清零', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        correctOption: 'B',
      );
      await tester.tap(find.widgetWithText(QmChip, 'C'));
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, [true]);
      await tester.tap(find.byTooltip('删除选项 B'));
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, [true], reason: '改非答案位不重置会话内点选信号');
      await tester.tap(find.byTooltip('删除选项 C'));
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, [true, false]);
    });

    testWidgets('待核对标记：提示重新选定；重选后带信号', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        answerPendingRecheck: true,
      );
      expect(find.textContaining('正确答案待重新核对'), findsOneWidget);
      await tester.tap(find.widgetWithText(QmChip, 'B'));
      await tester.pumpAndSettle();
      expect(cap.correctCalls, ['B']);
      expect(cap.reconfirmCalls, [true]);
    });

    testWidgets('标签为空列表：提示 + 「+」从 A 开始', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const [],
      );
      await tester.tap(find.widgetWithText(QmButton, '+ 添加选项'));
      await tester.pumpAndSettle();
      expect(cap.labelsCalls.last, ['A']);
    });

    testWidgets('「+」到 Z 后禁用', (tester) async {
      final cap = _Cap();
      final all = List.generate(26, (i) => String.fromCharCode(65 + i));
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: all,
        correctOption: 'A',
      );
      final button = find
          .widgetWithText(QmButton, '+ 添加选项')
          .evaluate()
          .first
          .widget as QmButton;
      expect(button.onPressed, isNull);
    });

    testWidgets('即时保存模式：点选正确答案立即走 onConfirm', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        correctOption: 'B',
        correctOptionSavesImmediately: true,
      );
      await tester.tap(find.widgetWithText(QmChip, 'C'));
      await tester.pumpAndSettle();
      expect(cap.confirms.length, 1);
      expect(cap.confirms.single['labels'], ['A', 'B', 'C', 'D']);
      expect(cap.confirms.single['correct'], 'C');
      expect(cap.confirms.single['reconfirmed'], isTrue);
      expect(cap.confirms.single['confirm'], isFalse);
    });

    testWidgets('OptionLabelsEditor 兼容包装：旧调用方参数仍可编译渲染', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OptionLabelsEditor(
              key: const ValueKey('q1'),
              questionId: 'q1',
              questionType: 'choice_single',
              optionLabels: const ['A', 'B', 'C', 'D'],
              storedOptionLabels: const ['A', 'B', 'C', 'D'],
              optionLabelsConfirmed: false,
              correctOption: 'B',
              storedCorrectOption: 'B',
              answerPendingRecheck: false,
              hadOldAnswer: false,
              answerReconfirmed: false,
              onLabelsChanged: (_) {},
              onCorrectOptionChanged: (_) {},
              onAnswerReconfirmedChanged: (_) {},
              onConfirm:
                  ({
                    required List<String>? labels,
                    required String? correctOption,
                    required bool answerReconfirmed,
                    required bool confirmLabels,
                  }) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.widgetWithText(QmButton, '确认选项'), findsNothing);
      expect(find.widgetWithText(QmChip, 'A'), findsOneWidget);
      expect(find.widgetWithText(QmButton, '+ 添加选项'), findsOneWidget);
    });
  });
}

// ---------------------------------------------------------------------------
// 捕获回调的宿主（模拟真实调用方：回调回写表单值并重建）
// ---------------------------------------------------------------------------

class _Cap {
  List<String>? currentLabels;
  String? currentCorrect;
  bool currentReconfirmed = false;
  final List<List<String>?> labelsCalls = [];
  final List<String?> correctCalls = [];
  final List<bool> reconfirmCalls = [];
  final List<String> multiCalls = [];
  final List<Map<String, Object?>> confirms = [];
}

Future<void> _pump(
  WidgetTester tester,
  _Cap cap, {
  required String questionType,
  List<String>? optionLabels,
  List<String>? storedOptionLabels,
  String? correctOption,
  String? storedCorrectOption,
  bool answerPendingRecheck = false,
  bool hadOldAnswer = false,
  bool correctOptionSavesImmediately = false,
  List<String>? detectedOptionLabels,
}) async {
  cap.currentLabels = optionLabels;
  cap.currentCorrect = correctOption;
  cap.currentReconfirmed = false;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: StatefulBuilder(
            builder: (context, setState) {
              return AnswerOptionEditor(
              key: const ValueKey('q1'),
              questionId: 'q1',
              questionType: questionType,
              optionLabels: cap.currentLabels,
              storedOptionLabels: storedOptionLabels ?? optionLabels,
              correctOption: cap.currentCorrect,
              storedCorrectOption: storedCorrectOption ?? correctOption,
              answerPendingRecheck: answerPendingRecheck,
              hadOldAnswer: hadOldAnswer,
              answerReconfirmed: cap.currentReconfirmed,
              detectedOptionLabels: detectedOptionLabels,
              onLabelsChanged: (v) {
                cap.labelsCalls.add(v == null ? null : List.of(v));
                setState(() => cap.currentLabels = v);
              },
              onCorrectOptionChanged: (v) {
                cap.correctCalls.add(v);
                setState(() => cap.currentCorrect = v);
              },
              onAnswerReconfirmedChanged: (v) {
                cap.reconfirmCalls.add(v);
                setState(() => cap.currentReconfirmed = v);
              },
              onMultiSelectionChanged: (v) => cap.multiCalls.add(v),
              onConfirm: ({
                required List<String>? labels,
                required String? correctOption,
                required bool answerReconfirmed,
                required bool confirmLabels,
              }) {
                cap.confirms.add({
                  'labels': labels,
                  'correct': correctOption,
                  'reconfirmed': answerReconfirmed,
                  'confirm': confirmLabels,
                });
                setState(() {});
              },
              correctOptionSavesImmediately: correctOptionSavesImmediately,
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
