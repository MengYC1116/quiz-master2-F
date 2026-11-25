// 十四批 M3：review_engine 纯逻辑单测（客观判分、选题、跳过、版本
// 检查、提交身份）。不碰库。
// P2（2026-11-25）：核验判定 resolveVerification 与治愈规则
// evaluateCure 两组已随简化基线删除（判定函数本身已删；
// evaluateCure 仅供旧写入层保留在 db_questions.dart，覆盖见
// b14_m3_verdict_test.dart）。
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

    test('单选：标签未确认但配置有效时仍可判分（WP-A #1 REV5：不再读 confirmed 列）', () {
      final q = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: ['A', 'B', 'C', 'D'],
        correctOption: 'B',
      );
      expect(objectiveGradingAvailable(q), isTrue);
      expect(gradeObjective(q, 'B'), 1);
      expect(gradeObjective(q, 'A'), 0);
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
