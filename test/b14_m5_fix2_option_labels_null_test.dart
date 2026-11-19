// 十四批 M5 修复轮 2（P1，GPT fix1 窄审 §3.3）：_optionLabelsOf 把 NULL 与
// [] 等同的修复测试（见 docs/decision-log.md D-119：NULL = 未确认，与 [] 不同义）。
//
// 旧实现把两者都编码成 ''，NULL↔[] 变化漏触发 _applyOptionLabelChangeRules，
// 导致 option_labels_confirmed 不清零、答案失效处理不执行。本文件在真实
// 内存库上经 repo.save → upsertQuestionIntoImpl 验证两个方向的状态转换，
// 沿 test/b14_m2_versions_test.dart 的模式。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';

void main() {
  late QuizDatabase db;
  late QuestionRepository repo;

  Future<void> insert(Question q) async {
    await AppDatabase.upsertQuestionInto(db, q);
  }

  Future<Question> reload(String id) async => (await repo.questionById(id))!;

  Question base(
    String id, {
    String? questionType,
    List<String>? optionLabels,
    bool optionLabelsConfirmed = false,
    String? correctOption,
    String? answer,
    String? explanation,
    bool answerPendingRecheck = false,
    int contentVersion = 3,
    int answerVersion = 2,
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
    answerPendingRecheck: answerPendingRecheck,
    createdAt: DateTime(2026, 11, 18),
    contentVersion: contentVersion,
    answerVersion: answerVersion,
  );

  setUp(() async {
    db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(db);
    repo = QuestionRepository(AppDatabase.instance);
  });

  test('NULL → []（多选，旧答案在，无重确认）：确认清零、答案失效、待核对、answer +1', () async {
    await insert(
      base(
        'q1',
        questionType: 'choice_multi',
        // optionLabels 保持 null（未确认）。
        optionLabelsConfirmed: true,
        answer: 'B、C',
        explanation: '解析',
      ),
    );
    final stored0 = await reload('q1');
    expect(stored0.optionLabels, isNull);
    await repo.save((await reload('q1')).copyWith(optionLabels: const []));
    final stored = await reload('q1');
    expect(stored.optionLabels, isEmpty);
    expect(stored.optionLabelsConfirmed, isFalse, reason: '标签变化须清零确认');
    expect(stored.answer, isNull, reason: '多选改标签且无重确认，旧答案失效');
    expect(stored.explanation, isNull);
    expect(stored.answerPendingRecheck, isTrue);
    expect(stored.answerVersion, 3, reason: '答案侧变化，answer_version +1');
    expect(stored.contentVersion, 3, reason: '内容侧未变');
  });

  test('[] → NULL（多选，旧答案在，无重确认）：同上，标签回到未确认', () async {
    await insert(
      base(
        'q1',
        questionType: 'choice_multi',
        optionLabels: const [],
        optionLabelsConfirmed: true,
        answer: 'B、C',
        explanation: '解析',
      ),
    );
    expect((await reload('q1')).optionLabels, isEmpty);
    // 注意：copyWith(optionLabels: null) 是“不改”，置 NULL 须用
    // clearOptionLabels（与整理页/详情页清标签的路径一致）。
    await repo.save((await reload('q1')).copyWith(clearOptionLabels: true));
    final stored = await reload('q1');
    expect(stored.optionLabels, isNull);
    expect(stored.optionLabelsConfirmed, isFalse);
    expect(stored.answer, isNull);
    expect(stored.explanation, isNull);
    expect(stored.answerPendingRecheck, isTrue);
    expect(stored.answerVersion, 3);
    expect(stored.contentVersion, 3);
  });

  test('NULL → []（单选，correctOption=B）：正确选项失效、待核对、answer +1', () async {
    await insert(
      base(
        'q1',
        questionType: 'choice_single',
        optionLabelsConfirmed: true,
        correctOption: 'B',
        answer: 'B',
      ),
    );
    await repo.save((await reload('q1')).copyWith(optionLabels: const []));
    final stored = await reload('q1');
    expect(stored.optionLabels, isEmpty);
    expect(stored.optionLabelsConfirmed, isFalse);
    expect(
      stored.correctOption,
      isNull,
      reason: '新集合为空，旧正确选项 B 不在集合里，须失效',
    );
    expect(stored.answerPendingRecheck, isTrue);
    expect(stored.answerVersion, 3);
    expect(stored.contentVersion, 3);
  });

  test('[] → NULL（单选，correctOption=B）：正确选项失效、待核对、answer +1', () async {
    await insert(
      base(
        'q1',
        questionType: 'choice_single',
        optionLabels: const [],
        optionLabelsConfirmed: true,
        correctOption: 'B',
        answer: 'B',
      ),
    );
    await repo.save((await reload('q1')).copyWith(clearOptionLabels: true));
    final stored = await reload('q1');
    expect(stored.optionLabels, isNull);
    expect(stored.optionLabelsConfirmed, isFalse);
    expect(stored.correctOption, isNull);
    expect(stored.answerPendingRecheck, isTrue);
    expect(stored.answerVersion, 3);
    expect(stored.contentVersion, 3);
  });

  test('对照：NULL → NULL 与 [] → [] 重保存，版本不动、确认态与答案保留', () async {
    await insert(
      base(
        'q1',
        questionType: 'choice_multi',
        optionLabelsConfirmed: true,
        answer: 'B、C',
        explanation: '解析',
      ),
    );
    await repo.save(await reload('q1'));
    var stored = await reload('q1');
    expect(stored.optionLabels, isNull);
    expect(stored.optionLabelsConfirmed, isTrue);
    expect(stored.answer, 'B、C');
    expect(stored.answerPendingRecheck, isFalse);
    expect(stored.answerVersion, 2);
    expect(stored.contentVersion, 3);

    await insert(
      base(
        'q2',
        questionType: 'choice_multi',
        optionLabels: const [],
        optionLabelsConfirmed: true,
        answer: 'B、C',
        explanation: '解析',
      ),
    );
    await repo.save(await reload('q2'));
    stored = await reload('q2');
    expect(stored.optionLabels, isEmpty);
    expect(stored.optionLabelsConfirmed, isTrue);
    expect(stored.answer, 'B、C');
    expect(stored.answerPendingRecheck, isFalse);
    expect(stored.answerVersion, 2);
    expect(stored.contentVersion, 3);
  });

  test('对照：NULL → [] 带重确认信号，答案保留、标记清除、answer +1', () async {
    await insert(
      base(
        'q1',
        questionType: 'choice_multi',
        optionLabelsConfirmed: true,
        answer: 'B、C',
        explanation: '解析',
      ),
    );
    await repo.save(
      (await reload('q1')).copyWith(
        optionLabels: const [],
        optionLabelsJustConfirmed: true,
        answerReconfirmed: true,
      ),
    );
    final stored = await reload('q1');
    expect(stored.optionLabels, isEmpty);
    // 本次就是确认保存：确认不清零。
    expect(stored.optionLabelsConfirmed, isTrue);
    expect(stored.answer, 'B、C');
    expect(stored.explanation, '解析');
    expect(stored.answerPendingRecheck, isFalse);
    // 标签本身变了，答案侧仍 +1。
    expect(stored.answerVersion, 3);
    expect(stored.contentVersion, 3);
  });
}
