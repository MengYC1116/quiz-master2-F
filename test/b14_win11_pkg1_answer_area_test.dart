// Win11 反馈包 1：答案区——正确答案选择器改小尺寸横向 chip（Wrap，
// chip 上带小 × 删除），按题型分流答案区（AnswerOptionEditor 级）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/modules/ocr/option_labels_editor.dart';
import 'package:quiz_master2/widgets/uikit.dart';

class _Cap {
  List<String>? currentLabels;
  String? currentCorrect;
  bool currentReconfirmed = false;
  Map<String, String>? currentContents;
  final List<List<String>?> labelsCalls = [];
  final List<Map<String, String>?> contentsCalls = [];
  final List<String> multiCalls = [];
}

Future<void> _pump(
  WidgetTester tester,
  _Cap cap, {
  required String questionType,
  List<String>? optionLabels,
  Map<String, String>? optionContents,
  Map<String, String>? detectedOptionContents,
  String? correctOption,
}) async {
  cap.currentLabels = optionLabels;
  cap.currentCorrect = correctOption;
  cap.currentContents = optionContents;
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
                storedOptionLabels: optionLabels,
                correctOption: cap.currentCorrect,
                storedCorrectOption: correctOption,
                answerPendingRecheck: false,
                hadOldAnswer: false,
                answerReconfirmed: cap.currentReconfirmed,
                optionContents: cap.currentContents,
                detectedOptionContents: detectedOptionContents,
                onOptionContentsChanged: (v) {
                  cap.contentsCalls.add(
                    v == null ? null : Map<String, String>.of(v),
                  );
                  setState(() => cap.currentContents = v);
                },
                onLabelsChanged: (v) {
                  cap.labelsCalls.add(v == null ? null : List.of(v));
                  setState(() => cap.currentLabels = v);
                },
                onCorrectOptionChanged: (v) {
                  setState(() => cap.currentCorrect = v);
                },
                onAnswerReconfirmedChanged: (v) {
                  setState(() => cap.currentReconfirmed = v);
                },
                onMultiSelectionChanged: (v) {
                  cap.multiCalls.add(v);
                },
                onConfirm: ({
                  required List<String>? labels,
                  required String? correctOption,
                  required bool answerReconfirmed,
                  required bool confirmLabels,
                }) {},
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 渲染出的选项文字在 RichText 里（QuestionContentRenderer），
/// find.text 不匹配 RichText，改用谓词查找。
Finder _findRendered(String text) => find.byWidgetPredicate(
  (w) => w is RichText && w.text.toPlainText() == text,
);

void main() {
  group('Win11 反馈包 1：AnswerOptionEditor 横向小 chip', () {
    testWidgets('字母芯片横向 Wrap：A–E 五位都在同一 Wrap 内', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D', 'E'],
        correctOption: 'A',
      );
      // 五个字母位都在 Wrap 里（超宽自动换行，不挤出容器）。
      for (final letter in ['A', 'B', 'C', 'D', 'E']) {
        expect(
          find.descendant(
            of: find.byType(Wrap),
            matching: find.widgetWithText(QmChip, letter),
          ),
          findsOneWidget,
          reason: '选项 $letter 应在 Wrap 内的 QmChip 里',
        );
      }
    });

    testWidgets('chip 上小 × 删除：点 × 删 B，标签与内容键同步去掉', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        optionContents: const {
          'A': '偶函数',
          'B': '奇函数',
          'C': '非奇非偶',
          'D': '既奇又偶',
        },
        correctOption: 'A',
      );
      await tester.tap(find.byTooltip('删除选项 B'));
      await tester.pumpAndSettle();
      expect(cap.labelsCalls.last, ['A', 'C', 'D']);
      // 标签映射只动对应键：B 的文字去掉，C、D 的文字原样保留、不串位。
      expect(cap.contentsCalls.last, {
        'A': '偶函数',
        'C': '非奇非偶',
        'D': '既奇又偶',
      });
      expect(find.widgetWithText(QmChip, 'B'), findsNothing);
    });

    testWidgets('多选删除已选字母后答案字符串同步更新', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_multi',
        optionLabels: const ['A', 'B', 'C', 'D'],
      );
      await tester.tap(find.widgetWithText(QmChip, 'A'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(QmChip, 'C'));
      await tester.pumpAndSettle();
      expect(cap.multiCalls.last, 'A,C');
      await tester.tap(find.byTooltip('删除选项 A'));
      await tester.pumpAndSettle();
      expect(cap.multiCalls.last, 'C');
      expect(cap.labelsCalls.last, ['B', 'C', 'D']);
    });

    testWidgets('判断题只留正确/错误，无 × 删除', (tester) async {
      final cap = _Cap();
      await _pump(tester, cap, questionType: 'true_false');
      expect(find.widgetWithText(QmChip, '正确'), findsOneWidget);
      expect(find.widgetWithText(QmChip, '错误'), findsOneWidget);
      expect(find.byTooltip('删除选项 正确'), findsNothing);
      expect(find.byTooltip('删除选项 错误'), findsNothing);
    });

    testWidgets('非选择题不渲染编辑器', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'fill_blank',
        optionLabels: const ['A', 'B', 'C', 'D'],
      );
      expect(find.text('正确答案'), findsNothing);
      expect(find.byType(QmChip), findsNothing);
    });

    testWidgets('选项文字行仍显示在芯片区下方（包 5 回归）', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B'],
        optionContents: const {'A': '偶函数', 'B': '奇函数'},
        correctOption: 'A',
      );
      expect(_findRendered('偶函数'), findsOneWidget);
      expect(_findRendered('奇函数'), findsOneWidget);
    });
  });
}
