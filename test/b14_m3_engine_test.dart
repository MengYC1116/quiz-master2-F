// 十四批 M3：review_engine 纯逻辑单测（判定表、证据关联、治愈规则、
// 选题、跳过、版本检查）。不碰库。
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/models/models.dart';

Question _q(
  String id, {
  String? questionType,
  List<String>? optionLabels,
  bool optionLabelsConfirmed = false,
  String? correctOption,
  String? answer,
  String? explanation,
  bool answerPendingRecheck = false,
  List<String> errorTypes = const [],
  bool isOrganized = true,
  bool reviewJoined = true,
}) =>
    Question(
      id: id,
      title: '题 $id',
      subjectId: 'math',
      errorTypes: errorTypes,
      createdAt: DateTime(2026, 11, 10),
      isOrganized: isOrganized,
      reviewJoined: reviewJoined,
      questionType: questionType,
      optionLabels: optionLabels,
      optionLabelsConfirmed: optionLabelsConfirmed,
      correctOption: correctOption,
      answer: answer,
      explanation: explanation,
      answerPendingRecheck: answerPendingRecheck,
    );

CauseRecord _rec(
  String questionId,
  String cause, {
  CauseStatus status = CauseStatus.pending,
  int solvedCount = 0,
  DateTime? recheckDate,
  DateTime? joinedAt,
  int? lastCountedSuccessAt,
  String? lastCountedSessionId,
}) =>
    CauseRecord(
      questionId: questionId,
      cause: cause,
      subjectId: 'math',
      status: status,
      solvedCount: solvedCount,
      recheckDate: recheckDate,
      joinedAt: joinedAt ?? DateTime(2026, 11, 10),
      lastCountedSuccessAt: lastCountedSuccessAt,
      lastCountedSessionId: lastCountedSessionId,
    );

void main() {
  group('客观判分 gradeObjective', () {
    test('单选：标签已确认且正确答案有效时判分', () {
      final q = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: ['A', 'B', 'C', 'D'],
        optionLabelsConfirmed: true,
        correctOption: 'B',
      );
      expect(gradeObjective(q, 'B'), 1);
      expect(gradeObjective(q, 'A'), 0);
    });

    test('单选：标签未确认时不判分（走纸上作答）', () {
      final q = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: ['A', 'B', 'C', 'D'],
        correctOption: 'B',
      );
      expect(objectiveGradingAvailable(q), isFalse);
      expect(gradeObjective(q, 'B'), isNull);
    });

    test('单选：已确认但未填正确答案时不判分', () {
      final q = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: ['A', 'B', 'C', 'D'],
        optionLabelsConfirmed: true,
      );
      expect(gradeObjective(q, 'B'), isNull);
    });

    test('单选：所选标签不在当前标签集时拒绝判分', () {
      final q = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: ['A', 'B', 'C', 'D'],
        optionLabelsConfirmed: true,
        correctOption: 'B',
      );
      expect(gradeObjective(q, 'E'), isNull);
    });

    test('单选：正确答案不在标签集时不判分', () {
      final q = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: ['A', 'B', 'C'],
        optionLabelsConfirmed: true,
        correctOption: 'D',
      );
      expect(objectiveGradingAvailable(q), isFalse);
    });

    test('判断题：判分条件独立于 option_labels_confirmed', () {
      final q = _q('q1', questionType: 'true_false', correctOption: '正确');
      expect(objectiveGradingAvailable(q), isTrue);
      expect(gradeObjective(q, '正确'), 1);
      expect(gradeObjective(q, '错误'), 0);
      final noAnswer = _q('q2', questionType: 'true_false');
      expect(gradeObjective(noAnswer, '正确'), isNull);
    });

    test('多选/不定项：correct_option 恒为 NULL，不判分', () {
      final q = _q(
        'q1',
        questionType: 'choice_multi',
        optionLabels: ['A', 'B', 'C', 'D'],
        optionLabelsConfirmed: true,
        answer: 'A、C',
      );
      expect(objectiveGradingAvailable(q), isFalse);
      expect(gradeObjective(q, 'A'), isNull);
    });

    test('待重新核对时不判分', () {
      final q = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: ['A', 'B', 'C', 'D'],
        optionLabelsConfirmed: true,
        correctOption: 'B',
        answerPendingRecheck: true,
      );
      expect(objectiveGradingAvailable(q), isFalse);
      expect(gradeObjective(q, 'B'), isNull);
    });
  });

  group('核验判定 resolveVerification（表 A/B/C）', () {
    final objQ = _q(
      'q1',
      questionType: 'choice_single',
      optionLabels: ['A', 'B', 'C', 'D'],
      optionLabelsConfirmed: true,
      correctOption: 'B',
    );
    final subjQ = _q(
      'q2',
      questionType: 'calculation',
      answer: 'x=2',
      explanation: '代入得 2',
    );
    final noAnswerQ = _q('q3', questionType: 'calculation');

    test('表 A：答对+确定+关联是 → 客观判分，attempt_id 记入', () {
      final v = resolveVerification(
        question: objQ,
        verdict: '已解决',
        objectiveCorrect: 1,
        confidence: '确定',
        evidenceLink: '是',
        attemptId: 'att-1',
      );
      expect(v.isVerified, isTrue);
      expect(v.source, '客观判分');
      expect(v.attemptId, 'att-1');
    });

    test('表 A：关联否/不确定/未选 → 未核验', () {
      for (final link in ['否', '不确定', null]) {
        final v = resolveVerification(
          question: objQ,
          verdict: '已解决',
          objectiveCorrect: 1,
          confidence: '确定',
          evidenceLink: link,
          attemptId: 'att-1',
        );
        expect(v.isVerified, isFalse, reason: 'link=$link');
        expect(v.source, '未核验');
        expect(v.attemptId, isNull);
      }
    });

    test('表 A：答对+不太确定/猜的 → 未核验（不做证据关联判断）', () {
      for (final c in ['不太确定', '猜的']) {
        final v = resolveVerification(
          question: objQ,
          verdict: '已解决',
          objectiveCorrect: 1,
          confidence: c,
          evidenceLink: '是',
          attemptId: 'att-1',
        );
        expect(v.isVerified, isFalse, reason: 'confidence=$c');
      }
    });

    test('表 A：答错 → 不允许记为已核验已解决', () {
      final v = resolveVerification(
        question: objQ,
        verdict: '已解决',
        objectiveCorrect: 0,
        confidence: '确定',
        evidenceLink: '是',
        attemptId: 'att-1',
      );
      expect(v.isVerified, isFalse);
    });

    test('主观题：核对确认四态各自核验资格', () {
      final ok = resolveVerification(
        question: subjQ,
        verdict: '已解决',
        checkConfirm: '已对照，关键答案/步骤符合',
      );
      expect(ok.source, '软件标准答案');
      expect(ok.isVerified, isTrue);
      for (final c in [
        '已对照，有错误或明显遗漏',
        '无法判断',
        '尚未核对',
        null,
      ]) {
        final v = resolveVerification(
          question: subjQ,
          verdict: '已解决',
          checkConfirm: c,
        );
        expect(v.isVerified, isFalse, reason: 'checkConfirm=$c');
      }
    });

    test('表 B：无答案时勾选外部核对才计入，不勾选即未核验', () {
      final checked = resolveVerification(
        question: noAnswerQ,
        verdict: '已解决',
        externalChecked: true,
      );
      expect(checked.source, '外部资料核对');
      expect(checked.isVerified, isTrue);
      final unchecked = resolveVerification(
        question: noAnswerQ,
        verdict: '已解决',
      );
      expect(unchecked.isVerified, isFalse);
      expect(unchecked.source, '未核验');
    });

    test('非已解决 verdict 一律未核验', () {
      for (final verdict in ['未解决', '不确定']) {
        final v = resolveVerification(
          question: objQ,
          verdict: verdict,
          objectiveCorrect: 1,
          confidence: '确定',
          evidenceLink: '是',
          attemptId: 'att-1',
        );
        expect(v.isVerified, isFalse);
      }
    });
  });

  group('治愈规则 evaluateCure（(d)+⑥）', () {
    final t0 = DateTime(2026, 11, 19, 9).millisecondsSinceEpoch;
    final h23 = Duration(hours: 23, minutes: 59).inMilliseconds;
    final h24 = Duration(hours: 24).inMilliseconds;

    test('第一次有效成功计数并保存锚点', () {
      final r = _rec('q1', '计算错误');
      final e = evaluateCure(
        record: r,
        sessionId: 'sess-a',
        nowMs: t0,
        cureChecks: 2,
        recheckIntervalDays: 7,
      );
      expect(e.counted, isTrue);
      expect(e.newSolvedCount, 1);
      expect(e.newStatus, CauseStatus.inProgress);
      expect(e.newLastCountedSuccessAt, t0);
      expect(e.newLastCountedSessionId, 'sess-a');
    });

    test('24 小时边界：23:59 不计、24:00 计入；未计入不刷新锚点', () {
      final r = _rec(
        'q1',
        '计算错误',
        solvedCount: 1,
        lastCountedSuccessAt: t0,
        lastCountedSessionId: 'sess-a',
      );
      final early = evaluateCure(
        record: r,
        sessionId: 'sess-b',
        nowMs: t0 + h23,
        cureChecks: 2,
        recheckIntervalDays: 7,
      );
      expect(early.counted, isFalse);
      expect(early.newLastCountedSuccessAt, isNull);
      final onTime = evaluateCure(
        record: r,
        sessionId: 'sess-b',
        nowMs: t0 + h24,
        cureChecks: 2,
        recheckIntervalDays: 7,
      );
      expect(onTime.counted, isTrue);
      expect(onTime.newSolvedCount, 2);
      expect(onTime.newStatus, CauseStatus.solved);
      expect(onTime.newRecheckDate, isNotNull);
    });

    test('同会话不同、间隔够，但同会话已有已解决事件 → 不计入', () {
      final r = _rec(
        'q1',
        '计算错误',
        solvedCount: 1,
        lastCountedSuccessAt: t0,
        lastCountedSessionId: 'sess-a',
      );
      final e = evaluateCure(
        record: r,
        sessionId: 'sess-b',
        nowMs: t0 + 30 * 60 * 60 * 1000,
        cureChecks: 2,
        recheckIntervalDays: 7,
        alreadySolvedInSession: true,
      );
      expect(e.counted, isFalse);
    });

    test('同一会话计入后第二次成功不计（session 相同）', () {
      final r = _rec(
        'q1',
        '计算错误',
        solvedCount: 1,
        lastCountedSuccessAt: t0,
        lastCountedSessionId: 'sess-a',
      );
      final e = evaluateCure(
        record: r,
        sessionId: 'sess-a',
        nowMs: t0 + 25 * 60 * 60 * 1000,
        cureChecks: 2,
        recheckIntervalDays: 7,
      );
      expect(e.counted, isFalse);
    });

    test('cureChecks=1 时一次有效成功直接治愈，不等待 24 小时', () {
      final r = _rec('q1', '计算错误');
      final e = evaluateCure(
        record: r,
        sessionId: 'sess-a',
        nowMs: t0,
        cureChecks: 1,
        recheckIntervalDays: 7,
      );
      expect(e.counted, isTrue);
      expect(e.newStatus, CauseStatus.solved);
    });

    test('cureChecks=3 需三次计入成功', () {
      var r = _rec('q1', '计算错误');
      var e = evaluateCure(
        record: r,
        sessionId: 's1',
        nowMs: t0,
        cureChecks: 3,
        recheckIntervalDays: 7,
      );
      expect(e.counted, isTrue);
      expect(e.newSolvedCount, 1);
      r = r.copyWith(
        solvedCount: 1,
        lastCountedSuccessAt: t0,
        lastCountedSessionId: 's1',
      );
      e = evaluateCure(
        record: r,
        sessionId: 's2',
        nowMs: t0 + h24,
        cureChecks: 3,
        recheckIntervalDays: 7,
      );
      expect(e.newSolvedCount, 2);
      expect(e.newStatus, CauseStatus.inProgress);
      r = r.copyWith(
        solvedCount: 2,
        lastCountedSuccessAt: t0 + h24,
        lastCountedSessionId: 's2',
      );
      e = evaluateCure(
        record: r,
        sessionId: 's3',
        nowMs: t0 + 2 * h24,
        cureChecks: 3,
        recheckIntervalDays: 7,
      );
      expect(e.newSolvedCount, 3);
      expect(e.newStatus, CauseStatus.solved);
    });

    test('复查通过不增加初次治愈次数，只顺延复查日', () {
      final r = _rec(
        'q1',
        '计算错误',
        status: CauseStatus.solved,
        solvedCount: 2,
        lastCountedSuccessAt: t0,
        lastCountedSessionId: 's1',
      );
      final e = evaluateCure(
        record: r,
        sessionId: 's2',
        nowMs: t0 + 8 * 24 * 60 * 60 * 1000,
        cureChecks: 2,
        recheckIntervalDays: 7,
        isRecheck: true,
      );
      expect(e.counted, isFalse);
      expect(e.newSolvedCount, 2);
      expect(e.newStatus, CauseStatus.solved);
      expect(e.newRecheckDate, isNotNull);
    });

    test('未解决重置锚点', () {
      final r = _rec(
        'q1',
        '计算错误',
        status: CauseStatus.inProgress,
        solvedCount: 1,
        lastCountedSuccessAt: t0,
        lastCountedSessionId: 's1',
      );
      final reset = unsolvedReset(r, DateTime(2026, 11, 20));
      expect(reset.solvedCount, 0);
      expect(reset.status, CauseStatus.inProgress);
      expect(reset.lastCountedSuccessAt, isNull);
      expect(reset.lastCountedSessionId, isNull);
      expect(reset.recheckDate, isNull);
    });
  });

  group('选题 buildDueQueue / buildPracticeQueue', () {
    final questions = {
      'q1': _q('q1', errorTypes: ['计算错误']),
      'q2': _q('q2', errorTypes: ['概念不清']),
      'q3': _q('q3', errorTypes: ['审题失误']),
      'q4': _q('q4', errorTypes: ['方法不会']),
    };
    final today = DateTime(2026, 11, 19);
    final records = [
      _rec('q1', '计算错误', joinedAt: DateTime(2026, 11, 10)),
      _rec(
        'q2',
        '概念不清',
        status: CauseStatus.solved,
        solvedCount: 2,
        recheckDate: DateTime(2026, 11, 18),
        joinedAt: DateTime(2026, 11, 9),
      ),
      _rec(
        'q3',
        '审题失误',
        status: CauseStatus.solved,
        solvedCount: 2,
        recheckDate: DateTime(2026, 11, 19),
        joinedAt: DateTime(2026, 11, 8),
      ),
      _rec(
        'q4',
        '方法不会',
        status: CauseStatus.solved,
        solvedCount: 2,
        recheckDate: DateTime(2026, 11, 25),
        joinedAt: DateTime(2026, 11, 7),
      ),
    ];

    test('默认池：逾期复查 → 今日到期复查 → 未解决；已治愈未到期不进池', () {
      final queue = buildDueQueue(
        records: records,
        joinedQuestionIds: {'q1', 'q2', 'q3', 'q4'},
        questionsById: questions,
        now: today,
      );
      expect(
        queue.map((e) => e.questionId).toList(),
        ['q2', 'q3', 'q1'],
      );
    });

    test('按错因数截断：同一题的本轮错因完整处理，可少量超出', () {
      final multi = [
        _rec('q1', '计算错误', joinedAt: DateTime(2026, 11, 10)),
        _rec('q1', '概念不清', joinedAt: DateTime(2026, 11, 10)),
        _rec('q2', '审题失误', joinedAt: DateTime(2026, 11, 11)),
      ];
      final qs = {
        'q1': _q('q1', errorTypes: ['计算错误', '概念不清']),
        'q2': _q('q2', errorTypes: ['审题失误']),
      };
      final queue = buildDueQueue(
        records: multi,
        joinedQuestionIds: {'q1', 'q2'},
        questionsById: qs,
        limit: 1,
        now: today,
      );
      // limit=1 但 q1 的 2 个错因必须完整处理，会话为 1 题 2 错因。
      expect(queue.length, 1);
      expect(queue.single.causes, ['计算错误', '概念不清']);
    });

    test('一题多错因先筛错因再按题去重', () {
      final multi = [
        _rec('q1', '计算错误', joinedAt: DateTime(2026, 11, 10)),
        _rec('q1', '概念不清', joinedAt: DateTime(2026, 11, 10)),
      ];
      final queue = buildDueQueue(
        records: multi,
        joinedQuestionIds: {'q1'},
        questionsById: {'q1': _q('q1')},
        now: today,
      );
      expect(queue.length, 1);
      expect(queue.single.causes.length, 2);
    });

    test('专项练习可含已掌握/未到期题，数量按去重后题数，默认随机', () {
      final qs = [
        _q('q1', errorTypes: ['计算错误']),
        _q('q2', errorTypes: ['概念不清']),
        _q('q3', errorTypes: ['审题失误']),
      ];
      final byQ = {
        for (final r in records) r.questionId: [r],
      };
      final queue = buildPracticeQueue(
        questions: qs,
        recordsByQ: byQ,
        count: 2,
        randomOrder: true,
        random: Random(42),
      );
      expect(queue.length, 2);
      final queue2 = buildPracticeQueue(
        questions: qs,
        recordsByQ: byQ,
        count: 10,
        randomOrder: false,
      );
      expect(queue2.length, 3);
      expect(queue2.first.questionId, 'q1');
    });
  });

  group('跳过 skipDecision 与版本检查 versionCheck', () {
    test('单题队列第一次跳过直接留到下次，不循环', () {
      expect(
        skipDecision(queueLength: 1, skips: 0),
        SkipAction.defer,
      );
    });

    test('多题队列第一次队尾、第二次留到下次', () {
      expect(skipDecision(queueLength: 3, skips: 0), SkipAction.toTail);
      expect(skipDecision(queueLength: 3, skips: 1), SkipAction.defer);
    });

    test('版本无变化 ok；未作答刷新；已提交移出', () {
      expect(
        versionCheck(
          snapshotAnswerVersion: 1,
          snapshotContentVersion: 2,
          currentAnswerVersion: 1,
          currentContentVersion: 2,
          hasSubmitted: false,
        ),
        VersionAction.ok,
      );
      expect(
        versionCheck(
          snapshotAnswerVersion: 1,
          snapshotContentVersion: 2,
          currentAnswerVersion: 2,
          currentContentVersion: 2,
          hasSubmitted: false,
        ),
        VersionAction.refresh,
      );
      expect(
        versionCheck(
          snapshotAnswerVersion: 1,
          snapshotContentVersion: 2,
          currentAnswerVersion: 1,
          currentContentVersion: 3,
          hasSubmitted: true,
        ),
        VersionAction.remove,
      );
    });
  });

  group('提交身份', () {
    test('子级 submission_id 由父 ID 与错因稳定身份确定性派生', () {
      expect(
        childSubmissionId('parent-1', 'cause-7'),
        childSubmissionId('parent-1', 'cause-7'),
      );
      expect(
        childSubmissionId('parent-1', 'cause-7'),
        isNot(childSubmissionId('parent-1', 'cause-8')),
      );
      expect(
        childSubmissionId('parent-1', 'cause-7'),
        isNot(childSubmissionId('parent-2', 'cause-7')),
      );
    });

    test('causeStableId：有行 id 用 id，无 id 回退 questionId|cause', () {
      expect(causeStableId(_rec('q1', '计算错误')), 'q1|计算错误');
      final withId = CauseRecord(
        id: 42,
        questionId: 'q1',
        cause: '计算错误',
        subjectId: 'math',
        joinedAt: DateTime(2026, 11, 10),
      );
      expect(causeStableId(withId), '42');
    });
  });
}
