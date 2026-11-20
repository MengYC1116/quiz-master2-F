// 十四批 M5 修复轮 3（P1-1，GPT fix2 窄审 §3）：编辑器重确认信号重置
//（见 lib/modules/ocr/option_labels_editor.dart D-152）。
//
// 旧缺陷：OptionLabelsEditor._onLabelsTextChanged() 只处理正确选项
// 是否仍在新集合，没有清除 _draftReconfirmed，也没有通知调用方把
// answerReconfirmed 置回 false。用户先勾选重确认、再改标签，旧确认
// 仍有效，旧答案可能被保留；单选先点选正确选项、再调顺序同理。
//
// WP-A #1 REV5 起文本框与「确认选项」按钮已移除：标签改动改为按位
// 增删（「+」追加、✕ 删除），顺序重排不再可能。本文件覆盖的信号重置
// 语义不变，操作序列改走新 UI：先在 widget 里走完“改标签 → 确认 →
// 再改标签 → 保存”的真实操作序列，取编辑器回调汇总的表单值，再按
// 详情页查看态 saveOptionBlock 的同款拼装（confirmLabels=false，
// REV5 起编辑器不再写确认列）经 repo.save 写进真实内存库，断言库里
// 最终状态——不只测编辑器内部状态。
// 数据层口径（_applyOptionLabelChangeRules）未动：单选题集合变化、
// 旧正确选项仍在新集合时保留，是 REV4.3 既定口径（GPT fix2 回复
// 第 1 节已撤回对它的质疑，见 D-153）；本文件 (b) 只覆盖“删答案位
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
  ///（REV5 起 confirmLabels 恒为 false：编辑器不再写确认列）。
  /// 调用方用编辑器回调汇总的当前表单值组装 payload。
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
      // 第一次改标签（「+」追加 E）→ 出现重确认复选框 → 勾选。
      await tester.tap(find.widgetWithText(QmButton, '+ 添加选项'));
      await tester.pumpAndSettle();
      expect(find.text('确认此答案和解析仍有效'), findsOneWidget);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, [true]);
      // 第二次改标签：旧确认必须立即失效。
      await tester.tap(find.widgetWithText(QmButton, '+ 添加选项'));
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, [true, false]);
      expect(find.byType(Checkbox).evaluate().first.widget as Checkbox,
          isA<Checkbox>().having((c) => c.value, 'value', isFalse));
      // 保存（信号 false → 数据层清掉旧答案）。
      final payload = {
        'labels': cap.currentLabels,
        'correct': cap.currentCorrect,
        'reconfirmed': cap.currentReconfirmed,
        'confirm': false,
      };
      expect(payload['labels'], ['A', 'B', 'C', 'D', 'E', 'F']);
      expect(payload['reconfirmed'], isFalse);
      await saveViewBlock(await reload('q1'), payload);
      final stored = await reload('q1');
      expect(stored.optionLabels, ['A', 'B', 'C', 'D', 'E', 'F']);
      expect(stored.answer, isNull, reason: '第二次改标签后未重新确认，旧答案失效');
      expect(stored.explanation, isNull);
      expect(stored.answerPendingRecheck, isTrue);
    });

    testWidgets('(b) 单选：重新选择正确选项后删掉该位，保存时正确选项必须清空',
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
      // 删掉 B 位：旧确认必须失效（正确答案已被删，草稿里已清空）。
      await tester.tap(find.byTooltip('删除选项 B'));
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, [true, false]);
      expect(cap.currentCorrect, isNull);
      final payload = {
        'labels': cap.currentLabels,
        'correct': cap.currentCorrect,
        'reconfirmed': cap.currentReconfirmed,
        'confirm': false,
      };
      expect(payload['labels'], ['A', 'C', 'D']);
      expect(payload['correct'], isNull, reason: '编辑器草稿已清空被删的正确选项');
      expect(payload['reconfirmed'], isFalse);
      await saveViewBlock(await reload('q1'), payload);
      final stored = await reload('q1');
      expect(stored.optionLabels, ['A', 'C', 'D']);
      expect(stored.correctOption, isNull,
          reason: '删答案位、未重确认，数据层清空正确选项');
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
      await tester.tap(find.widgetWithText(QmButton, '+ 添加选项'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, [true]);
      final payload = {
        'labels': cap.currentLabels,
        'correct': cap.currentCorrect,
        'reconfirmed': cap.currentReconfirmed,
        'confirm': false,
      };
      expect(payload['reconfirmed'], isTrue);
      await saveViewBlock(await reload('q1'), payload);
      final stored = await reload('q1');
      expect(stored.optionLabels, ['A', 'B', 'C', 'D', 'E']);
      expect(stored.answer, 'B、C', reason: '最后一次改标签后重新确认，答案保留');
      expect(stored.explanation, '解析');
      expect(stored.answerPendingRecheck, isFalse);
    });

    testWidgets('(c2) 单选：删非答案位后重新点选正确选项，保存才允许保留正确选项',
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
      // 先删 D 位（此时无重确认信号），再重新点选 B。
      await tester.tap(find.byTooltip('删除选项 D'));
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, isEmpty, reason: '从未确认过，无信号可清');
      await tester.tap(find.widgetWithText(QmChip, 'B'));
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, [true]);
      final payload = {
        'labels': cap.currentLabels,
        'correct': cap.currentCorrect,
        'reconfirmed': cap.currentReconfirmed,
        'confirm': false,
      };
      expect(payload['labels'], ['A', 'B', 'C']);
      expect(payload['correct'], 'B');
      expect(payload['reconfirmed'], isTrue);
      await saveViewBlock(await reload('q1'), payload);
      final stored = await reload('q1');
      expect(stored.correctOption, 'B', reason: '删位后重新点选，正确选项保留');
      expect(stored.answerPendingRecheck, isFalse);
    });

    testWidgets('(d) 对照：单选点选后增非答案位，信号不重置，保存后正确选项保留',
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
      await tester.tap(find.widgetWithText(QmChip, 'B'));
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, [true]);
      // 增一位（非答案位）：S2-1 会话内点选信号不重置（正确答案含义未变）。
      await tester.tap(find.widgetWithText(QmButton, '+ 添加选项'));
      await tester.pumpAndSettle();
      expect(cap.reconfirmCalls, [true], reason: '增非答案位不重置点选信号');
      final payload = {
        'labels': cap.currentLabels,
        'correct': cap.currentCorrect,
        'reconfirmed': cap.currentReconfirmed,
        'confirm': false,
      };
      expect(payload['labels'], ['A', 'B', 'C', 'D', 'E']);
      expect(payload['reconfirmed'], isTrue);
      await saveViewBlock(await reload('q1'), payload);
      final stored = await reload('q1');
      expect(stored.correctOption, 'B', reason: '增位后点选信号仍有效，答案保留');
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
/// 都回写表单值并重建，didUpdateWidget 的外部同步据此更新草稿）。
class _Captured {
  List<String>? currentLabels;
  String? currentCorrect;
  bool currentReconfirmed = false;
  final List<bool> reconfirmCalls = [];
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
              }) {},
            );
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
