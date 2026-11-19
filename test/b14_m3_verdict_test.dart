// 十四批 M3：verdict 提交事务（治愈规则 (d)+⑥、幂等、中性事件）、
// attempts 生命周期、P1-A 标签改动、会话持久化、恢复清会话。
// 走真实内存库（AppDatabase.openForTest），不调真实接口。
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/models/models.dart';

Question _q(
  String id, {
  List<String> errorTypes = const ['计算错误'],
  String? questionType,
  List<String>? optionLabels,
  bool optionLabelsConfirmed = false,
  String? correctOption,
  String? answer,
  String? explanation,
}) =>
    Question(
      id: id,
      title: '题 $id',
      subjectId: 'math',
      errorTypes: errorTypes,
      createdAt: DateTime(2026, 11, 10),
      isOrganized: true,
      reviewJoined: true,
      questionType: questionType,
      optionLabels: optionLabels,
      optionLabelsConfirmed: optionLabelsConfirmed,
      correctOption: correctOption,
      answer: answer,
      explanation: explanation,
    );

void main() {
  late QuizDatabase db;
  late QuestionRepository repo;

  setUp(() async {
    db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(db);
    repo = QuestionRepository(AppDatabase.instance);
  });

  tearDown(() async {
    await db.close();
  });

  /// 建题 + 加入复习，返回库内错因记录。
  Future<CauseRecord> seedCause(
    String qid,
    String cause, {
    List<String> errorTypes = const ['计算错误'],
  }) async {
    final q = _q(qid, errorTypes: errorTypes);
    await AppDatabase.upsertQuestionInto(db, q);
    await repo.setReviewJoined(q, true);
    final records = await repo.causeRecordsFor(qid);
    return records.firstWhere((r) => r.cause == cause);
  }

  Future<List<Map<String, Object?>>> historyRows(String causeStable) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM review_history WHERE cause_id = ? ORDER BY id',
          variables: [Variable.withString(causeStable)],
        )
        .get();
    return rows.map((r) => r.data).toList();
  }

  Future<VerdictSubmitResult> submit({
    required CauseRecord record,
    required String verdict,
    String verificationStatus = '未核验',
    String verificationSource = '未核验',
    String? attemptId,
    required String sessionId,
    required String submissionId,
    int cureChecks = 2,
    bool isRecheck = false,
    DateTime? now,
  }) =>
      repo.submitCauseVerdict(
        questionId: record.questionId,
        record: record,
        verdict: verdict,
        verificationStatus: verificationStatus,
        verificationSource: verificationSource,
        attemptId: attemptId,
        sessionId: sessionId,
        submissionId: submissionId,
        cureChecks: cureChecks,
        isRecheck: isRecheck,
        now: now,
      );

  group('治愈规则 (d)+⑥：P1-3 强制场景', () {
    test('A 计入 → B 第一次未满 24h 不计 → B 第二次即使超 24h 也不计 → C 计入', () async {
      final record = await seedCause('q1', '计算错误');
      final t0 = DateTime(2026, 11, 16, 9);
      const verified = '已核验';
      const external = '外部资料核对';
      // 会话 A 第一次成功计入（solvedCount 0→1，锚点 t0/sess-a）。
      final a = await submit(
        record: record,
        verdict: '已解决',
        verificationStatus: verified,
        verificationSource: external,
        sessionId: 'sess-a',
        submissionId: 'sub-a1',
        now: t0,
      );
      expect(a.counted, isTrue);
      expect(a.record.solvedCount, 1);
      expect(a.record.lastCountedSuccessAt, t0.millisecondsSinceEpoch);
      expect(a.record.lastCountedSessionId, 'sess-a');
      // 会话 B 第一次成功未满 24 小时不计入，锚点不刷新。
      final b1 = await submit(
        record: a.record,
        verdict: '已解决',
        verificationStatus: verified,
        verificationSource: external,
        sessionId: 'sess-b',
        submissionId: 'sub-b1',
        now: t0.add(const Duration(hours: 11)),
      );
      expect(b1.counted, isFalse);
      expect(b1.record.solvedCount, 1);
      expect(b1.record.lastCountedSuccessAt, t0.millisecondsSinceEpoch);
      // 会话 B 第二次真实操作：即使已超过 A 的 24 小时也不计入（(d)）。
      final b2 = await submit(
        record: b1.record,
        verdict: '已解决',
        verificationStatus: verified,
        verificationSource: external,
        sessionId: 'sess-b',
        submissionId: 'sub-b2',
        now: t0.add(const Duration(hours: 30)),
      );
      expect(b2.counted, isFalse);
      expect(b2.record.solvedCount, 1);
      expect(b2.record.lastCountedSuccessAt, t0.millisecondsSinceEpoch);
      // 会话 C 第一次独立成功且距上一次已计入事件 ≥24 小时才计入 → 治愈。
      final c = await submit(
        record: b2.record,
        verdict: '已解决',
        verificationStatus: verified,
        verificationSource: external,
        sessionId: 'sess-c',
        submissionId: 'sub-c1',
        now: t0.add(const Duration(hours: 30)),
      );
      expect(c.counted, isTrue);
      expect(c.record.solvedCount, 2);
      expect(c.record.status, CauseStatus.solved);
      expect(c.cured, isTrue);
      expect(c.record.recheckDate, isNotNull);
      // 四次均为独立 history 行（B2 不是重试，是第二次真实操作）。
      final rows = await historyRows(causeStableId(c.record));
      expect(rows.length, 4);
      expect(
        rows.map((r) => r['verdict']).toList(),
        ['已解决', '已解决', '已解决', '已解决'],
      );
    });

    test('同会话第一次未核验、第二次变已核验也不能绕过 (d)', () async {
      final record = await seedCause('q1', '计算错误');
      final t0 = DateTime(2026, 11, 16, 9);
      final first = await submit(
        record: record,
        verdict: '已解决',
        sessionId: 'sess-x',
        submissionId: 'sub-x1',
        now: t0,
      );
      expect(first.counted, isFalse);
      expect(first.record.solvedCount, 0);
      final second = await submit(
        record: first.record,
        verdict: '已解决',
        verificationStatus: '已核验',
        verificationSource: '外部资料核对',
        sessionId: 'sess-x',
        submissionId: 'sub-x2',
        now: t0.add(const Duration(hours: 30)),
      );
      expect(second.counted, isFalse);
      expect(second.record.solvedCount, 0);
    });

    test('24 小时边界：23:59 不计、24:00 计入；未计入不刷新锚点', () async {
      final record = await seedCause('q1', '计算错误');
      final t0 = DateTime(2026, 11, 16, 9);
      const verified = '已核验';
      const external = '外部资料核对';
      final a = await submit(
        record: record,
        verdict: '已解决',
        verificationStatus: verified,
        verificationSource: external,
        sessionId: 'sess-a',
        submissionId: 'sub-a1',
        now: t0,
      );
      expect(a.counted, isTrue);
      final early = await submit(
        record: a.record,
        verdict: '已解决',
        verificationStatus: verified,
        verificationSource: external,
        sessionId: 'sess-b',
        submissionId: 'sub-b1',
        now: t0.add(const Duration(hours: 23, minutes: 59)),
      );
      expect(early.counted, isFalse);
      // 第三次按第一次计入锚点判定：距 t0 已 24h → 计入。
      final onTime = await submit(
        record: early.record,
        verdict: '已解决',
        verificationStatus: verified,
        verificationSource: external,
        sessionId: 'sess-c',
        submissionId: 'sub-c1',
        now: t0.add(const Duration(hours: 24)),
      );
      expect(onTime.counted, isTrue);
      expect(onTime.record.solvedCount, 2);
    });

    test('未核验的自评不推进治愈；外部核对勾选才计入', () async {
      final record = await seedCause('q1', '计算错误');
      final t0 = DateTime(2026, 11, 16, 9);
      final unverified = await submit(
        record: record,
        verdict: '已解决',
        sessionId: 'sess-a',
        submissionId: 'sub-a1',
        now: t0,
      );
      expect(unverified.counted, isFalse);
      expect(unverified.record.solvedCount, 0);
      // 同会话内第二次（已核验）仍被 (d) 拦住，另起会话才计入。
      final verifiedOtherSession = await submit(
        record: unverified.record,
        verdict: '已解决',
        verificationStatus: '已核验',
        verificationSource: '外部资料核对',
        sessionId: 'sess-b',
        submissionId: 'sub-b1',
        now: t0,
      );
      expect(verifiedOtherSession.counted, isTrue);
      expect(verifiedOtherSession.record.solvedCount, 1);
    });

    test('未解决重置锚点与进度', () async {
      final record = await seedCause('q1', '计算错误');
      final t0 = DateTime(2026, 11, 16, 9);
      final a = await submit(
        record: record,
        verdict: '已解决',
        verificationStatus: '已核验',
        verificationSource: '外部资料核对',
        sessionId: 'sess-a',
        submissionId: 'sub-a1',
        now: t0,
      );
      expect(a.record.solvedCount, 1);
      final reset = await submit(
        record: a.record,
        verdict: '未解决',
        sessionId: 'sess-b',
        submissionId: 'sub-b1',
        now: t0.add(const Duration(hours: 1)),
      );
      expect(reset.record.solvedCount, 0);
      expect(reset.record.status, CauseStatus.inProgress);
      expect(reset.record.lastCountedSuccessAt, isNull);
      expect(reset.record.lastCountedSessionId, isNull);
      expect(reset.record.recheckDate, isNull);
    });
  });

  group('幂等与中性事件', () {
    test('同一子级 submission_id 重试返回已有结果，不重复计数、不写新事件', () async {
      final record = await seedCause('q1', '计算错误');
      final t0 = DateTime(2026, 11, 16, 9);
      final first = await submit(
        record: record,
        verdict: '已解决',
        verificationStatus: '已核验',
        verificationSource: '外部资料核对',
        sessionId: 'sess-a',
        submissionId: 'sub-same',
        now: t0,
      );
      expect(first.alreadySubmitted, isFalse);
      final retry = await submit(
        record: first.record,
        verdict: '已解决',
        verificationStatus: '已核验',
        verificationSource: '外部资料核对',
        sessionId: 'sess-a',
        submissionId: 'sub-same',
        now: t0,
      );
      expect(retry.alreadySubmitted, isTrue);
      expect(retry.historyId, first.historyId);
      expect(retry.record.solvedCount, 1);
      final rows = await historyRows(causeStableId(first.record));
      expect(rows.length, 1);
    });

    test('一次按题提交三错因：三条 history 各用自己的子级 ID，父级 ID 不入 history', () async {
      final q = _q(
        'q1',
        errorTypes: ['计算错误', '概念不清', '审题失误'],
      );
      await AppDatabase.upsertQuestionInto(db, q);
      await repo.setReviewJoined(q, true);
      final records = await repo.causeRecordsFor('q1');
      expect(records.length, 3);
      const parentId = 'parent-uuid-1';
      final results = <VerdictSubmitResult>[];
      for (final r in records) {
        results.add(
          await submit(
            record: r,
            verdict: '已解决',
            verificationStatus: '已核验',
            verificationSource: '外部资料核对',
            sessionId: 'sess-a',
            submissionId: childSubmissionId(parentId, causeStableId(r)),
            now: DateTime(2026, 11, 16, 9),
          ),
        );
      }
      final ids = results.map((r) => r.historyId).toSet();
      expect(ids.length, 3);
      final rows = await db
          .customSelect('SELECT submission_id FROM review_history')
          .get();
      final subs = rows.map((r) => r.data['submission_id'] as String).toList();
      expect(subs, isNot(contains(parentId)));
      expect(subs.length, 3);
    });

    test('不确定写中性事件：写库、不改 cause_records、不刷新锚点', () async {
      final record = await seedCause('q1', '计算错误');
      final t0 = DateTime(2026, 11, 16, 9);
      final result = await submit(
        record: record,
        verdict: '不确定',
        sessionId: 'sess-a',
        submissionId: 'sub-u1',
        now: t0,
      );
      expect(result.counted, isFalse);
      expect(result.record.solvedCount, 0);
      expect(result.record.status, CauseStatus.pending);
      final rows = await historyRows(causeStableId(record));
      expect(rows.length, 1);
      expect(rows.single['verdict'], '不确定');
      expect(rows.single['verification_status'], '未核验');
      expect(rows.single['verification_source'], '未核验');
      expect(rows.single['result'], 'unsure');
    });

    test('非法核验组合拒绝写入（已核验配未核验来源；客观判分缺 attempt_id）', () async {
      final record = await seedCause('q1', '计算错误');
      await expectLater(
        submit(
          record: record,
          verdict: '已解决',
          verificationStatus: '已核验',
          verificationSource: '未核验',
          sessionId: 'sess-a',
          submissionId: 'sub-bad1',
        ),
        throwsArgumentError,
      );
      await expectLater(
        submit(
          record: record,
          verdict: '已解决',
          verificationStatus: '已核验',
          verificationSource: '客观判分',
          sessionId: 'sess-a',
          submissionId: 'sub-bad2',
        ),
        throwsArgumentError,
      );
      final rows = await historyRows(causeStableId(record));
      expect(rows, isEmpty);
    });

    test('错因记录不存在时抛错、不写 history', () async {
      final ghost = CauseRecord(
        questionId: 'q-missing',
        cause: '计算错误',
        subjectId: 'math',
        joinedAt: DateTime(2026, 11, 10),
      );
      await expectLater(
        submit(
          record: ghost,
          verdict: '已解决',
          verificationStatus: '已核验',
          verificationSource: '外部资料核对',
          sessionId: 'sess-a',
          submissionId: 'sub-ghost',
        ),
        throwsA(isA<CauseRecordMissingException>()),
      );
    });

    test('复查通过不增加初次治愈次数；复查失败打回解决中', () async {
      final record = await seedCause('q1', '计算错误');
      final t0 = DateTime(2026, 11, 16, 9);
      // 先治愈（cureChecks=2，两次计入成功）。
      var current = record;
      for (var i = 0; i < 2; i++) {
        final r = await submit(
          record: current,
          verdict: '已解决',
          verificationStatus: '已核验',
          verificationSource: '外部资料核对',
          sessionId: 'sess-$i',
          submissionId: 'sub-cure-$i',
          now: t0.add(Duration(hours: 25 * i)),
        );
        current = r.record;
      }
      expect(current.status, CauseStatus.solved);
      expect(current.solvedCount, 2);
      // 复查通过：solvedCount 不变，复查日顺延。
      final passed = await submit(
        record: current,
        verdict: '已解决',
        verificationStatus: '已核验',
        verificationSource: '外部资料核对',
        sessionId: 'sess-r',
        submissionId: 'sub-recheck-pass',
        isRecheck: true,
        now: t0.add(const Duration(days: 8)),
      );
      expect(passed.counted, isFalse);
      expect(passed.record.solvedCount, 2);
      expect(passed.record.status, CauseStatus.solved);
      expect(passed.isRecheckPassed, isTrue);
      // 复查失败：打回解决中，进度清零。
      final failed = await submit(
        record: passed.record,
        verdict: '未解决',
        sessionId: 'sess-r2',
        submissionId: 'sub-recheck-fail',
        isRecheck: true,
        now: t0.add(const Duration(days: 8, hours: 1)),
      );
      expect(failed.record.status, CauseStatus.inProgress);
      expect(failed.record.solvedCount, 0);
      expect(failed.isRecheckFailed, isTrue);
    });
  });

  group('attempts 生命周期', () {
    test('只跳过、从未作答的题不建 attempt；作答后同一条记录更新、不新建', () async {
      await seedCause('q1', '计算错误');
      final none = await repo.loadAttempt(
        sessionId: 'sess-a',
        questionId: 'q1',
      );
      expect(none, isNull);
      final attempt = AttemptData(
        id: 'att-1',
        questionId: 'q1',
        sessionId: 'sess-a',
        mode: '到期复习',
        selected: ['B'],
        correct: 1,
        confidence: '确定',
        answerVersion: 1,
        contentVersion: 2,
        status: '已提交',
        causeIds: ['计算错误'],
        submissionId: 'att-sub-1',
        createdAt: DateTime(2026, 11, 16, 9).millisecondsSinceEpoch,
      );
      final id = await repo.recordAttempt(attempt);
      expect(id, 'att-1');
      // 跳过后重遇：同一条记录更新（保留原选择与客观结果，不重新提交）。
      final updated = attempt.copyWith(status: '跳过');
      final id2 = await repo.recordAttempt(updated);
      expect(id2, 'att-1');
      final rows = await db
          .customSelect(
            'SELECT * FROM attempts WHERE session_id = ? AND question_id = ?',
            variables: [
              Variable.withString('sess-a'),
              Variable.withString('q1'),
            ],
          )
          .get();
      expect(rows.length, 1);
      expect(rows.single.data['submission_id'], 'att-sub-1');
      expect(rows.single.data['status'], '跳过');
      expect(rows.single.data['correct'], 1);
      expect(rows.single.data['content_version'], 2);
      // 同一会话同一题再建一条 attempt（不同 submission_id）仍是同一行。
      final again = AttemptData(
        id: 'att-2',
        questionId: 'q1',
        sessionId: 'sess-a',
        mode: '到期复习',
        selected: ['A'],
        correct: 0,
        confidence: '猜的',
        answerVersion: 1,
        contentVersion: 2,
        status: '已提交',
        causeIds: ['计算错误'],
        submissionId: 'att-sub-2',
        createdAt: DateTime(2026, 11, 16, 10).millisecondsSinceEpoch,
      );
      final id3 = await repo.recordAttempt(again);
      expect(id3, 'att-1');
      final rows2 = await db
          .customSelect('SELECT * FROM attempts')
          .get();
      expect(rows2.length, 1);
    });
  });

  group('P1-A：改标签后旧答案重新核对', () {
    Future<Question> readQuestion(String id) async {
      final rows = await (db.select(
        db.questions,
      )..where((t) => t.id.equals(id))).get();
      return rows.map((r) {
        return Question(
          id: r.id,
          title: r.title,
          subjectId: r.subjectId,
          createdAt: DateTime.fromMillisecondsSinceEpoch(r.createdAt),
          answer: r.answer,
          explanation: r.explanation,
          questionType: r.questionType,
          correctOption: r.correctOption,
          optionLabels: r.optionLabels,
          optionLabelsConfirmed: r.optionLabelsConfirmed == 1,
          answerVersion: r.answerVersion,
          answerPendingRecheck: r.answerPendingRecheck == 1,
        );
      }).single;
    }

    test('多选改标签不重新确认 → 答案与解析置 NULL、待核对、answer_version+1', () async {
      final q = _q(
        'q1',
        questionType: 'choice_multi',
        optionLabels: ['A', 'B', 'C', 'D'],
        optionLabelsConfirmed: true,
        answer: 'A、C',
        explanation: '解析文本',
      );
      await AppDatabase.upsertQuestionInto(db, q);
      var saved = await readQuestion('q1');
      expect(saved.answerVersion, 1);
      expect(saved.answerPendingRecheck, isFalse);
      // 改标签（增 E），不带重确认信号。
      await repo.save(
        saved.copyWith(optionLabels: ['A', 'B', 'C', 'D', 'E']),
      );
      saved = await readQuestion('q1');
      expect(saved.answer, isNull);
      expect(saved.explanation, isNull);
      expect(saved.answerPendingRecheck, isTrue);
      expect(saved.answerVersion, 2);
      expect(saved.optionLabelsConfirmed, isFalse);
      expect(saved.hasValidStandardAnswer, isFalse);
    });

    test('多选改标签并重新确认 → 新答案和新标签原子保存，answer_version 只 +1', () async {
      final q = _q(
        'q1',
        questionType: 'choice_multi',
        optionLabels: ['A', 'B', 'C', 'D'],
        optionLabelsConfirmed: true,
        answer: 'A、C',
        explanation: '解析文本',
      );
      await AppDatabase.upsertQuestionInto(db, q);
      var saved = await readQuestion('q1');
      await repo.save(
        saved.copyWith(
          optionLabels: ['A', 'B', 'C', 'D', 'E'],
          answer: 'A、C、E',
          explanation: '新解析',
          answerReconfirmed: true,
        ),
      );
      saved = await readQuestion('q1');
      expect(saved.answer, 'A、C、E');
      expect(saved.explanation, '新解析');
      expect(saved.answerPendingRecheck, isFalse);
      expect(saved.answerVersion, 2);
    });

    test('单选只改标签顺序、未重选 → correct_option 置 NULL、待核对、不判分', () async {
      final q = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: ['A', 'B', 'C', 'D'],
        optionLabelsConfirmed: true,
        correctOption: 'B',
      );
      await AppDatabase.upsertQuestionInto(db, q);
      var saved = await readQuestion('q1');
      await repo.save(saved.copyWith(optionLabels: ['B', 'A', 'C', 'D']));
      saved = await readQuestion('q1');
      expect(saved.correctOption, isNull);
      expect(saved.answerPendingRecheck, isTrue);
      expect(saved.answerVersion, 2);
      expect(objectiveGradingAvailable(saved), isFalse);
    });

    test('单选只改标签顺序、重选同一标签 → 恢复判分（须另点确认选项）', () async {
      final q = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: ['A', 'B', 'C', 'D'],
        optionLabelsConfirmed: true,
        correctOption: 'B',
      );
      await AppDatabase.upsertQuestionInto(db, q);
      var saved = await readQuestion('q1');
      // 同一次保存重选正确标签：correct_option 保留、待核对清除，
      // 但标签确认须另点“确认选项”才能恢复，判分仍关闭。
      await repo.save(
        saved.copyWith(
          optionLabels: ['B', 'A', 'C', 'D'],
          correctOption: 'B',
          answerReconfirmed: true,
        ),
      );
      saved = await readQuestion('q1');
      expect(saved.correctOption, 'B');
      expect(saved.answerPendingRecheck, isFalse);
      expect(saved.optionLabelsConfirmed, isFalse);
      expect(objectiveGradingAvailable(saved), isFalse);
      // 点“确认选项”保存后恢复判分。
      await repo.save(
        saved.copyWith(
          optionLabelsConfirmed: true,
          optionLabelsJustConfirmed: true,
        ),
      );
      saved = await readQuestion('q1');
      expect(saved.optionLabelsConfirmed, isTrue);
      expect(objectiveGradingAvailable(saved), isTrue);
      expect(gradeObjective(saved, 'B'), 1);
    });

    test('单选集合变化致正确答案失效 → correct_option 置 NULL', () async {
      final q = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: ['A', 'B', 'C', 'D'],
        optionLabelsConfirmed: true,
        correctOption: 'B',
      );
      await AppDatabase.upsertQuestionInto(db, q);
      var saved = await readQuestion('q1');
      await repo.save(saved.copyWith(optionLabels: ['A', 'C', 'D']));
      saved = await readQuestion('q1');
      expect(saved.correctOption, isNull);
      expect(saved.answerPendingRecheck, isTrue);
    });

    test('改标签后确认清零；确认保存带信号时保留确认状态', () async {
      final q = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: ['A', 'B', 'C', 'D'],
        optionLabelsConfirmed: true,
        correctOption: 'B',
      );
      await AppDatabase.upsertQuestionInto(db, q);
      var saved = await readQuestion('q1');
      await repo.save(saved.copyWith(optionLabels: ['A', 'B', 'C', 'D', 'E']));
      saved = await readQuestion('q1');
      expect(saved.optionLabelsConfirmed, isFalse);
      // 确认保存：标签 + 确认一起落盘。
      await repo.save(
        saved.copyWith(
          optionLabels: ['A', 'B', 'C', 'D', 'E'],
          optionLabelsConfirmed: true,
          optionLabelsJustConfirmed: true,
          correctOption: 'B',
          answerReconfirmed: true,
        ),
      );
      saved = await readQuestion('q1');
      expect(saved.optionLabelsConfirmed, isTrue);
      expect(saved.correctOption, 'B');
    });
  });

  group('会话持久化 review_state', () {
    test('保存/读取完整快照：session_id、模式、跳过次数、每题状态', () async {
      final perQuestion = {
        'q1': <String, Object?>{
          'question_submission_id': 'qs-1',
          'answer_version_at_start': 1,
          'content_version_at_start': 2,
          'stage': 'checking',
          'attempt_id': 'att-1',
          'submitted_causes': ['计算错误'],
        },
      };
      await repo.saveReviewState(
        queue: const [
          ReviewQueueItem(questionId: 'q1', cause: '计算错误'),
          ReviewQueueItem(questionId: 'q2', cause: '概念不清'),
        ],
        position: 1,
        sessionId: 'sess-1',
        mode: '到期复习',
        skips: {'q1': 1},
        perQuestionState: perQuestion,
      );
      final loaded = await repo.reviewState();
      expect(loaded, isNotNull);
      expect(loaded!.sessionId, 'sess-1');
      expect(loaded.mode, '到期复习');
      expect(loaded.position, 1);
      expect(loaded.queue.length, 2);
      expect(loaded.skips, {'q1': 1});
      expect(
        loaded.perQuestionState['q1']!['question_submission_id'],
        'qs-1',
      );
      expect(loaded.perQuestionState['q1']!['answer_version_at_start'], 1);
      await repo.clearReviewState();
      expect(await repo.reviewState(), isNull);
    });

    test('恢复备份时目标库原有暂停会话被清除', () async {
      await repo.saveReviewState(
        queue: const [ReviewQueueItem(questionId: 'q1', cause: '计算错误')],
        position: 0,
        sessionId: 'sess-old',
        mode: '到期复习',
      );
      expect(await repo.reviewState(), isNotNull);
      // 导出当前库（含一道题），再恢复进同一库：恢复事务清空 review_state。
      final q = _q('q1');
      await AppDatabase.upsertQuestionInto(db, q);
      final dataDir = await Directory.systemTemp.createTemp('m3-restore');
      addTearDown(() => dataDir.delete(recursive: true));
      final bytes = await AppDatabase.exportBackupZipFrom(
        db,
        dataDir: dataDir.path,
      );
      final warnings = await AppDatabase.importBackupZipInto(
        db,
        bytes,
        dataDir: dataDir.path,
      );
      expect(warnings, isEmpty);
      expect(await repo.reviewState(), isNull);
      // 恢复后不创建任何活动会话：再读一次仍为空。
      expect(await repo.reviewState(), isNull);
    });
  });

  group('专项练习重新加入复习', () {
    test('已治愈错因回到解决中，进度与锚点清空；本次练习记录不受影响', () async {
      final record = await seedCause('q1', '计算错误');
      final t0 = DateTime(2026, 11, 16, 9);
      var current = record;
      for (var i = 0; i < 2; i++) {
        final r = await submit(
          record: current,
          verdict: '已解决',
          verificationStatus: '已核验',
          verificationSource: '外部资料核对',
          sessionId: 'sess-$i',
          submissionId: 'sub-cure-$i',
          now: t0.add(Duration(hours: 25 * i)),
        );
        current = r.record;
      }
      expect(current.status, CauseStatus.solved);
      await repo.rejoinCause(
        questionId: 'q1',
        cause: '计算错误',
        subjectId: 'math',
      );
      final after = (await repo.causeRecordsFor('q1')).single;
      expect(after.status, CauseStatus.inProgress);
      expect(after.solvedCount, 0);
      expect(after.lastCountedSuccessAt, isNull);
      expect(after.lastCountedSessionId, isNull);
      expect(after.recheckDate, isNull);
    });
  });

  group('M3-10 断点恢复重建：hasSessionVerdict', () {
    test('已提交任何 verdict 的错因在该会话查到；他会话 / 未提交查不到', () async {
      final record = await seedCause('q1', '计算错误');
      final stable = causeStableId(record);
      expect(
        await repo.hasSessionVerdict(
          causeStableId: stable,
          sessionId: 'sess-a',
        ),
        isFalse,
      );
      await submit(
        record: record,
        verdict: '未解决',
        sessionId: 'sess-a',
        submissionId: 'sub-hsv-1',
      );
      // “未解决”也是已提交过的 verdict，恢复重建要认它。
      expect(
        await repo.hasSessionVerdict(
          causeStableId: stable,
          sessionId: 'sess-a',
        ),
        isTrue,
      );
      expect(
        await repo.hasSessionVerdict(
          causeStableId: stable,
          sessionId: 'sess-b',
        ),
        isFalse,
      );
      expect(
        await repo.hasSessionVerdict(
          causeStableId: 'q1|不存在的错因',
          sessionId: 'sess-a',
        ),
        isFalse,
      );
    });

    test('崩溃窗口：数据库已写、review_state 未更新时，恢复后不重复计数', () async {
      // 模拟崩溃窗口的另一半：verdict 已写库（history 有行），
      // review_state 的 per_question_state 没更新——恢复时若按
      // “未提交”重走自查再提交，(d) 规则必须挡住第二次计数。
      final record = await seedCause('q1', '计算错误');
      final t0 = DateTime(2026, 11, 16, 9);
      final first = await submit(
        record: record,
        verdict: '已解决',
        verificationStatus: '已核验',
        verificationSource: '外部资料核对',
        sessionId: 'sess-a',
        submissionId: 'sub-crash-1',
        now: t0,
      );
      expect(first.counted, isTrue);
      // 崩溃后恢复：用户以为没提交，用新子级 submission_id 再提交一次。
      final retry = await submit(
        record: first.record,
        verdict: '已解决',
        verificationStatus: '已核验',
        verificationSource: '外部资料核对',
        sessionId: 'sess-a',
        submissionId: 'sub-crash-2',
        now: t0.add(const Duration(hours: 1)),
      );
      expect(retry.counted, isFalse);
      expect(retry.record.solvedCount, 1);
      expect(
        retry.record.lastCountedSuccessAt,
        t0.millisecondsSinceEpoch,
      );
    });
  });
}
