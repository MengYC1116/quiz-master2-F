// 十四批 M5 修复轮 3（P1-1，GPT fix2 窄审 §3）：编辑器重确认信号重置
//（见 lib/modules/ocr/option_labels_editor.dart D-152）。
//
// 旧缺陷：OptionLabelsEditor._onLabelsTextChanged() 只处理正确选项
// 是否仍在新集合，没有清除 _draftReconfirmed，也没有通知调用方把
// answerReconfirmed 置回 false。用户先勾选重确认、再改标签，旧确认
// 仍有效，旧答案可能被保留；单选先点选正确选项、再调顺序同理。
//
// 本文件覆盖 GPT 列的三场景 + 格式-only 对照，全部落到保存结果：
// 先在 widget 里走完“改标签 → 确认 → 再改标签 → 点确认选项”
// 的真实操作序列，取编辑器 onConfirm 发出的信号，再按详情页查看态
// saveOptionBlock 的同款拼装（confirmLabels=true）经 repo.save
// 写进真实内存库，断言库里最终状态——不只测编辑器内部状态。
// 数据层口径（_applyOptionLabelChangeRules）未动：单选题集合变化、
// 旧正确选项仍在新集合时保留，是 REV4.3 既定口径（GPT fix2 回复
// 第 1 节已撤回对它的质疑，见 D-153）；本文件 (b) 只覆盖“顺序变化
// 未重确认 → 正确选项清空”这一条既定口径。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/ocr/option_labels_editor.dart';
import 'package:quiz_master2/widgets/uikit.dart';

void main() {
  late QuizDatabase db;
  late QuestionRepository repo;

  // 注意：不要把开库放进文件级 setUp——testWidgets 的 setUp 跑在
  // FakeAsync 区里，AppDatabase.openForTest() 在其中永不完成
  // （探针 P7 复现挂起、P6 体内开库通过）；每测开头体内调用 _openDb()。
  Future<void> openDb() async {
    db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(db);
    repo = QuestionRepository(AppDatabase.instance);
  }

  Question seed(
    String id, {
    required String questionType,
    List<String>? optionLabels,
    bool optionLabelsConfirmed = true,
    String? correctOption,
    String? answer,
    String? explanation,
  }) => Question(
    id: id,
    title: '题 $id',
    subjectId: 'math',
    questionType: questionType,
    optionLabels: optionLabels,
    optionLabelsConfirmed: optionLabelsConfirmed,
    correctOption: correctOption,
    answer: answer,
    explanation: explanation,
    createdAt: DateTime(2026, 11, 19),
  );

  Future<Question> reload(String id) async => (await repo.questionById(id))!;

  /// 按详情页查看态 DetailNotifier.saveOptionBlock 的同款拼装落盘
  ///（confirmLabels=true = 点「确认选项」；false = 正确选项即时保存）。
  Future<void> saveViewBlock(
    Question current,
    Map<String, Object?> payload,
  ) async {
    final labels = payload['labels'] as List<String>?;
    final correct = payload['correct'] as String?;
    final reconfirmed = payload['reconfirmed'] as bool;
    final confirmLabels = payload['confirm'] as bool;
    final updated = current.copyWith(
      optionLabels: labels,
      clearOptionLabels: labels == null && current.optionLabels != null,
      optionLabelsConfirmed:
          confirmLabels ? true : current.optionLabelsConfirmed,
      correctOption: correct,
      clearCorrectOption:
          correct == null && current.correctOption != null,
      answerReconfirmed: reconfirmed,
      optionLabelsJustConfirmed: confirmLabels,
    );
    await repo.save(updated);
  }

  group('P1-1 编辑器重确认信号重置（D-152）', () {
    testWidgets('(a) 多选：勾选重确认后再次修改标签，保存时旧答案必须失效',
        (tester) async {
      await openDb();
      await _insert(
        repo,
        seed(
          'q1',
          questionType: 'choice_multi',
          optionLabels: const ['A', 'B', 'C', 'D'],
          answer: 'B、C',
          explanation: '解析',
        ),
      );
      final cap = _Captured();
      await _pumpEditor(
        tester,
        cap,
        questionType: 'choice_multi',
        optionLabels: const ['A', 'B', 'C', 'D'],
        hadOldAnswer: true,
      );
      // 第一次改标签 → 出现重确认复选框 → 勾选。
      await tester.enterText(find.byType(TextField), 'A,B,C,D,E');
      await tester.pumpAndSettle();
      expect(find.text('确认此答案和解析仍有效'), findsOneWidget);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, [true]);
      // 第二次改标签：旧确认必须立即失效。
      await tester.enterText(find.byType(TextField), 'A,B,C,D,E,F');
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, [true, false]);
      expect(find.byType(Checkbox).evaluate().first.widget as Checkbox,
          isA<Checkbox>().having((c) => c.value, 'value', isFalse));
      // 点「确认选项」保存：信号 false → 数据层清掉旧答案。
      await tester.tap(find.widgetWithText(QmButton, '确认选项'));
      await tester.pumpAndSettle();
      final payload = cap.confirms.single;
      expect(payload['labels'], ['A', 'B', 'C', 'D', 'E', 'F']);
      expect(payload['reconfirmed'], isFalse);
      expect(payload['confirm'], isTrue);
      await saveViewBlock(await reload('q1'), payload);
      final stored = await reload('q1');
      expect(stored.optionLabels, ['A', 'B', 'C', 'D', 'E', 'F']);
      expect(stored.answer, isNull, reason: '第二次改标签后未重新确认，旧答案失效');
      expect(stored.explanation, isNull);
      expect(stored.answerPendingRecheck, isTrue);
    });

    testWidgets('(b) 单选：重新选择正确选项后再次调整顺序，保存时正确选项必须清空',
        (tester) async {
      await openDb();
      await _insert(
        repo,
        seed(
          'q1',
          questionType: 'choice_single',
          optionLabels: const ['A', 'B', 'C', 'D'],
          correctOption: 'B',
          answer: 'B',
        ),
      );
      final cap = _Captured();
      await _pumpEditor(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        correctOption: 'B',
      );
      // 重新点选同一正确选项 B → 产生重确认信号。
      await tester.tap(find.widgetWithText(QmChip, 'B'));
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, [true]);
      // 再次调整顺序：旧确认必须失效（顺序变化本身不清空草稿正确选项，
      // 清空发生在保存时的数据层）。
      await tester.enterText(find.byType(TextField), 'B,A,C,D');
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, [true, false]);
      await tester.tap(find.widgetWithText(QmButton, '确认选项'));
      await tester.pumpAndSettle();
      final payload = cap.confirms.single;
      expect(payload['labels'], ['B', 'A', 'C', 'D']);
      expect(payload['correct'], 'B', reason: '编辑器草稿仍保留点选值');
      expect(payload['reconfirmed'], isFalse);
      await saveViewBlock(await reload('q1'), payload);
      final stored = await reload('q1');
      expect(stored.optionLabels, ['B', 'A', 'C', 'D']);
      expect(stored.correctOption, isNull,
          reason: '只调换顺序、未重确认，数据层清空正确选项');
      expect(stored.answerPendingRecheck, isTrue);
    });

    testWidgets('(c1) 多选：最后一次标签修改后重新确认，保存才允许保留答案',
        (tester) async {
      await openDb();
      await _insert(
        repo,
        seed(
          'q1',
          questionType: 'choice_multi',
          optionLabels: const ['A', 'B', 'C', 'D'],
          answer: 'B、C',
          explanation: '解析',
        ),
      );
      final cap = _Captured();
      await _pumpEditor(
        tester,
        cap,
        questionType: 'choice_multi',
        optionLabels: const ['A', 'B', 'C', 'D'],
        hadOldAnswer: true,
      );
      await tester.enterText(find.byType(TextField), 'A,B,C,D,E');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, [true]);
      await tester.tap(find.widgetWithText(QmButton, '确认选项'));
      await tester.pumpAndSettle();
      final payload = cap.confirms.single;
      expect(payload['reconfirmed'], isTrue);
      await saveViewBlock(await reload('q1'), payload);
      final stored = await reload('q1');
      expect(stored.optionLabels, ['A', 'B', 'C', 'D', 'E']);
      expect(stored.answer, 'B、C', reason: '最后一次改标签后重新确认，答案保留');
      expect(stored.explanation, '解析');
      expect(stored.answerPendingRecheck, isFalse);
    });

    testWidgets('(c2) 单选：调换顺序后重新点选正确选项，保存才允许保留正确选项',
        (tester) async {
      await openDb();
      await _insert(
        repo,
        seed(
          'q1',
          questionType: 'choice_single',
          optionLabels: const ['A', 'B', 'C', 'D'],
          correctOption: 'B',
          answer: 'B',
        ),
      );
      final cap = _Captured();
      await _pumpEditor(
        tester,
        cap,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        correctOption: 'B',
      );
      // 先调换顺序（此时无重确认信号），再重新点选 B。
      await tester.enterText(find.byType(TextField), 'B,A,C,D');
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, isEmpty, reason: '从未确认过，无信号可清');
      await tester.tap(find.widgetWithText(QmChip, 'B'));
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, [true]);
      await tester.tap(find.widgetWithText(QmButton, '确认选项'));
      await tester.pumpAndSettle();
      final payload = cap.confirms.single;
      expect(payload['labels'], ['B', 'A', 'C', 'D']);
      expect(payload['correct'], 'B');
      expect(payload['reconfirmed'], isTrue);
      await saveViewBlock(await reload('q1'), payload);
      final stored = await reload('q1');
      expect(stored.correctOption, 'B', reason: '顺序变化后重新点选，正确选项保留');
      expect(stored.answerPendingRecheck, isFalse);
    });

    testWidgets('(d) 对照：仅空格/分隔符格式变化，解析结果相同，不重置重确认',
        (tester) async {
      await openDb();
      await _insert(
        repo,
        seed(
          'q1',
          questionType: 'choice_multi',
          optionLabels: const ['A', 'B', 'C', 'D'],
          answer: 'B、C',
          explanation: '解析',
        ),
      );
      final cap = _Captured();
      await _pumpEditor(
        tester,
        cap,
        questionType: 'choice_multi',
        optionLabels: const ['A', 'B', 'C', 'D'],
        hadOldAnswer: true,
      );
      await tester.enterText(find.byType(TextField), 'A,B,C,D,E');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, [true]);
      // 两次纯格式变化：加空格、换中文分隔符，解析结果不变。
      await tester.enterText(find.byType(TextField), 'A, B, C, D, E');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'A，B、C、D、E');
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, [true], reason: '格式-only 变化不产生 false 信号');
      await tester.tap(find.widgetWithText(QmButton, '确认选项'));
      await tester.pumpAndSettle();
      final payload = cap.confirms.single;
      expect(payload['labels'], ['A', 'B', 'C', 'D', 'E']);
      expect(payload['reconfirmed'], isTrue);
      await saveViewBlock(await reload('q1'), payload);
      final stored = await reload('q1');
      expect(stored.answer, 'B、C', reason: '格式变化不重置确认，答案保留');
      expect(stored.explanation, '解析');
      expect(stored.answerPendingRecheck, isFalse);
    });
  });
}

Future<void> _insert(QuestionRepository repo, Question q) async {
  final db = AppDatabase.instance;
  await AppDatabase.upsertQuestionInto(await db.db, q);
}

/// 编辑器回调捕获 + 回填给编辑器的当前表单值（模拟真实调用方：
/// onLabelsChanged/onCorrectOptionChanged/onAnswerReconfirmedChanged
/// 都回写表单值并重建，didUpdateWidget 的外部同步才不会把用户刚
/// 输入的文本格式化回写掉）。
class _Captured {
  List<String>? currentLabels;
  String? currentCorrect;
  bool currentReconfirmed = false;
  final List<bool> reconfirmCalls = [];
  final List<Map<String, Object?>> confirms = [];
}

Future<void> _pumpEditor(
  WidgetTester tester,
  _Captured cap, {
  required String questionType,
  List<String>? optionLabels,
  String? correctOption,
  bool optionLabelsConfirmed = true,
  bool hadOldAnswer = false,
}) async {
  cap.currentLabels = optionLabels;
  cap.currentCorrect = correctOption;
  cap.currentReconfirmed = false;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            return OptionLabelsEditor(
              key: const ValueKey('q1'),
              questionId: 'q1',
              questionType: questionType,
              optionLabels: cap.currentLabels,
              storedOptionLabels: optionLabels,
              optionLabelsConfirmed: optionLabelsConfirmed,
              correctOption: cap.currentCorrect,
              storedCorrectOption: correctOption,
              answerPendingRecheck: false,
              hadOldAnswer: hadOldAnswer,
              answerReconfirmed: cap.currentReconfirmed,
              onLabelsChanged: (v) => setState(() => cap.currentLabels = v),
              onCorrectOptionChanged: (v) =>
                  setState(() => cap.currentCorrect = v),
              onAnswerReconfirmedChanged: (v) {
                cap.reconfirmCalls.add(v);
                setState(() => cap.currentReconfirmed = v);
              },
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
            );
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
