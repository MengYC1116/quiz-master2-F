// Win11 反馈包 5：选项文字在选项区显示、可手动改（AnswerOptionEditor）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/modules/ocr/option_labels_editor.dart';

class _Cap {
  List<String>? currentLabels;
  String? currentCorrect;
  bool currentReconfirmed = false;
  Map<String, String>? currentContents;
  final List<List<String>?> labelsCalls = [];
  final List<Map<String, String>?> contentsCalls = [];
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
  group('AnswerOptionEditor optionContents', () {
    testWidgets('选项文字显示在对应字母位下方', (tester) async {
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
      expect(_findRendered('偶函数'), findsOneWidget);
      expect(_findRendered('奇函数'), findsOneWidget);
      expect(_findRendered('非奇非偶'), findsOneWidget);
      expect(_findRendered('既奇又偶'), findsOneWidget);
    });

    testWidgets('点“编辑选项文字”改文字：改动即上报新映射', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B'],
        optionContents: const {'A': '偶函数', 'B': '奇函数'},
        correctOption: 'A',
      );
      await tester.tap(find.byTooltip('编辑选项 A 文字'));
      await tester.pumpAndSettle();
      final field = find.byType(TextField);
      expect(field, findsOneWidget);
      await tester.enterText(field, '偶函数改');
      await tester.pumpAndSettle();
      expect(cap.contentsCalls.last, {'A': '偶函数改', 'B': '奇函数'});
      expect(find.text('偶函数改'), findsOneWidget);
    });

    testWidgets('删标签位时对应选项文字键一并去掉', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C'],
        optionContents: const {'A': '偶函数', 'B': '奇函数', 'C': '非奇非偶'},
        correctOption: 'A',
      );
      await tester.tap(find.byTooltip('删除选项 B'));
      await tester.pumpAndSettle();
      expect(cap.labelsCalls.last, ['A', 'C']);
      expect(cap.contentsCalls.last, {'A': '偶函数', 'C': '非奇非偶'});
      expect(_findRendered('奇函数'), findsNothing);
    });

    testWidgets('判断题不显示选项文字（固定正确/错误）', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'true_false',
        optionLabels: null,
        optionContents: const {'A': '偶函数'},
        correctOption: '正确',
      );
      expect(find.text('偶函数'), findsNothing);
      expect(find.text('正确'), findsWidgets);
    });

    testWidgets('无选项文字时可补充：编辑后上报新键', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B'],
        optionContents: const {},
        correctOption: 'A',
      );
      await tester.tap(find.byTooltip('编辑选项 A 文字'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '新补的文字');
      await tester.pumpAndSettle();
      expect(cap.contentsCalls.last, {'A': '新补的文字'});
    });

    testWidgets('选项文字输入框 hint 不教 LaTeX 写法（P10）', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B'],
        optionContents: const {},
        correctOption: 'A',
      );
      await tester.tap(find.byTooltip('编辑选项 A 文字'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('输入选项文字'), findsOneWidget);
      expect(find.textContaining(r'$...$'), findsNothing);
    });

    testWidgets('检测到的选项文字只作初始值：已有值时不覆盖', (tester) async {
      final cap = _Cap();
      await _pump(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B'],
        optionContents: const {'A': '人工改的', 'B': '奇函数'},
        detectedOptionContents: const {'A': '偶函数', 'B': '奇函数'},
        correctOption: 'A',
      );
      expect(_findRendered('人工改的'), findsOneWidget);
      expect(_findRendered('偶函数'), findsNothing);
    });
  });
}
