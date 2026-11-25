// 报告聚合纯函数单测（FSRS 口径迁移 §2.4）：夹具 attempts + 题目，
// 不依赖真库、不启动 widget。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/report_stats.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/models/models.dart';

DateTime get _today {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

int get _nowMs => _today.millisecondsSinceEpoch;

Question _tq(
  String id, {
  String subjectId = 'math',
  List<String> errorTypes = const ['概念不清'],
  List<String> knowledgePointIds = const [],
  DateTime? createdAt,
  bool isOrganized = true,
  bool isArchived = false,
}) =>
    Question(
      id: id,
      title: '题 $id',
      subjectId: subjectId,
      errorTypes: errorTypes,
      knowledgePointIds: knowledgePointIds,
      createdAt: createdAt ?? _today,
      isOrganized: isOrganized,
      isArchived: isArchived,
      reviewJoined: true,
      sliceKind: 'material',
      sliceText: '题：$id',
    );

AttemptData _att(
  String qid,
  String mode,
  int? correct,
  int createdAtMs, {
  List<String> causeIds = const [],
  String sessionId = 's1',
}) =>
    AttemptData(
      id: 'att-$qid-$createdAtMs-$correct-$sessionId',
      questionId: qid,
      sessionId: sessionId,
      mode: mode,
      correct: correct,
      answerVersion: 1,
      contentVersion: 0,
      status: '已提交',
      causeIds: causeIds,
      submissionId: 'sub-$qid-$createdAtMs-$correct-$sessionId',
      createdAt: createdAtMs,
    );

DateTime? _weekStart() {
  final today = _today;
  return today.subtract(Duration(days: today.weekday - 1));
}

void main() {
  group('computeReportStats', () {
    test('三个核心数：答对按次数、答错按题去重、未判分不进分母、专项不计', () {
      final now = _nowMs;
      final old = _today
          .subtract(const Duration(days: 40))
          .millisecondsSinceEpoch;
      final stats = computeReportStats(
        attempts: [
          _att('q1', ReviewMode.due, 1, now),
          _att('q1', ReviewMode.due, 0, now, causeIds: ['概念不清']),
          _att('q1', ReviewMode.due, null, now),
          _att('q2', ReviewMode.practice, 1, now),
          _att('q2', ReviewMode.due, 1, now),
          _att('q3', ReviewMode.due, 0, old, causeIds: ['计算错误']),
          // 题已删的 attempt：核心数照常计，归因与分布跳过。
          _att('q-gone', ReviewMode.due, 0, now, causeIds: ['概念不清']),
        ],
        questions: [_tq('q1'), _tq('q2'), _tq('q3')],
        knowledgePoints: const [],
        subjectIdsInOrder: const ['math'],
        rangeStart: _weekStart(),
      );
      // 答对 2 次（q1、q2 各 1 次；专项与未判分不计；范围外不计）。
      expect(stats.formalCorrectCount, 2);
      // 答错 2 道（q1、q-gone；q3 在范围外）。
      expect(stats.formalWrongQuestionCount, 2);
      // 已判分 4 次（答对 2 + 答错 2），答对率 50%。
      expect(stats.gradedFormalCount, 4);
      expect(stats.gradedFormalCorrectCount, 2);
      expect(stats.passRate, 50);
      // q-gone 无法归属：错因组只有 q1 一组，分布只有 q1/q2 两道。
      expect(stats.causeGroups.length, 1);
      expect(stats.causeGroups.single.key, '概念不清');
      expect(stats.answeredBySubject, {'math': 2});
    });

    test('无已判分记录时答对率为 null', () {
      final stats = computeReportStats(
        attempts: [_att('q1', ReviewMode.due, null, _nowMs)],
        questions: [_tq('q1')],
        knowledgePoints: const [],
        subjectIdsInOrder: const ['math'],
        rangeStart: _weekStart(),
      );
      expect(stats.passRate, isNull);
      expect(stats.gradedFormalCount, 0);
      expect(stats.formalCorrectCount, 0);
      expect(stats.formalWrongQuestionCount, 0);
    });

    test('按错因归因：同一题多次答错只取最早一次，一题多错因多计', () {
      final now = _nowMs;
      final stats = computeReportStats(
        attempts: [
          _att('q1', ReviewMode.due, 0, now, causeIds: ['方法不会'],
              sessionId: 's1'),
          _att('q1', ReviewMode.due, 0, now + 1000,
              causeIds: ['概念不清'], sessionId: 's2'),
          _att('q2', ReviewMode.due, 0, now,
              causeIds: ['方法不会', '概念不清']),
        ],
        questions: [_tq('q1'), _tq('q2')],
        knowledgePoints: const [],
        subjectIdsInOrder: const ['math'],
        rangeStart: _weekStart(),
      );
      // q1 只按最早一次的“方法不会”归因，不按第二次的“概念不清”。
      expect(stats.formalWrongQuestionCount, 2);
      final byKey = {for (final g in stats.causeGroups) g.key: g};
      expect(byKey['方法不会']!.questionIds, {'q1', 'q2'});
      expect(byKey['方法不会']!.count, 2);
      expect(byKey['概念不清']!.questionIds, {'q2'});
      expect(byKey['概念不清']!.count, 1);
    });

    test('按知识点：题目集合口径，不读 cause_records，不过滤“已掌握”', () {
      final stats = computeReportStats(
        attempts: const [],
        questions: [
          _tq('q1', knowledgePointIds: ['kp-a']),
          _tq('q2', knowledgePointIds: ['kp-a', 'kp-b']),
          // 无错因的题不进知识点组；未知知识点跳过。
          _tq('q3', errorTypes: const [], knowledgePointIds: ['kp-a']),
          _tq('q4', knowledgePointIds: ['kp-unknown']),
        ],
        knowledgePoints: const [
          KnowledgePoint(id: 'kp-a', subjectId: 'math', chapter: '一', name: '甲'),
          KnowledgePoint(id: 'kp-b', subjectId: 'math', chapter: '二', name: '乙'),
        ],
        subjectIdsInOrder: const ['math'],
        rangeStart: _weekStart(),
      );
      final byKey = {for (final g in stats.kpGroups) g.key: g};
      expect(byKey.keys, {'kp-a', 'kp-b'});
      expect(byKey['kp-a']!.questionIds, {'q1', 'q2'});
      expect(byKey['kp-b']!.questionIds, {'q2'});
      expect(stats.kpGroups.first.key, 'kp-a');
    });

    test('分布：范围内正式作答题数，按题去重、未判分也算', () {
      final stats = computeReportStats(
        attempts: [
          _att('q1', ReviewMode.due, 1, _nowMs),
          _att('q1', ReviewMode.due, 0, _nowMs, sessionId: 's2'),
          _att('q2', ReviewMode.due, null, _nowMs),
          _att('q3', ReviewMode.practice, 0, _nowMs),
        ],
        questions: [
          _tq('q1'),
          _tq('q2', subjectId: 'english'),
          _tq('q3'),
        ],
        knowledgePoints: const [],
        subjectIdsInOrder: const ['math', 'english'],
        rangeStart: _weekStart(),
      );
      // q1 两次作答只算 1 道；q2 未判分也算作答；q3 只有专项，不算。
      expect(stats.answeredBySubject, {'math': 1, 'english': 1});
    });
  });

  group('reportQuestionsInRange', () {
    test('只收已整理未归档；all 不按日期过滤，否则按 createdAt', () {
      final old = _today.subtract(const Duration(days: 40));
      final questions = [
        _tq('q1'),
        _tq('q2', isOrganized: false),
        _tq('q3', isArchived: true),
        _tq('q4', createdAt: old),
      ];
      expect(
        reportQuestionsInRange(
          questions: questions,
          rangeStart: _weekStart(),
        ).map((q) => q.id),
        ['q1'],
      );
      expect(
        reportQuestionsInRange(questions: questions, rangeStart: null)
            .map((q) => q.id),
        ['q1', 'q4'],
      );
    });
  });
}
