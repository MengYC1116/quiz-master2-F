// FSRS 迁移跟进批第 1 项：V5 缺卡一次性补建（通用规则）针对性测试。
//
// 场景（内存库，不碰真实库；演示题 id 只作先验案例重建，不改演示库数据本身）：
// - 7 道演示题 q-eng-1、q-eng-2、q-math-1、q-math-2、q-math-3、q-pol-1、
//   q-pol-3：reviewJoined=1、无卡 → 补建后各有一张未开始新卡；
// - q-has-card：reviewJoined=1、已有正式复习过的卡 → 状态一根指头都不碰；
// - q-not-joined：reviewJoined=0、无卡 → 不补建。
// 断言：补建结果与 audit_json、已有卡不动、第二遍跑无变化（幂等，
// migration_log 只有一行 completed）、新卡 firstReviewedAt 为空、
// scheduler.nextDueAt 为 null、不进到期队列、进新题释放。
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';

/// 演示库先验案例的 7 道缺卡题（reviewJoined=1、有卡数 0）。
const _demoMissingIds = [
  'q-eng-1',
  'q-eng-2',
  'q-math-1',
  'q-math-2',
  'q-math-3',
  'q-pol-1',
  'q-pol-3',
];

Question _q(String id, {bool reviewJoined = true}) => Question(
  id: id,
  title: '题 $id',
  subjectId: 'math',
  errorTypes: const ['概念不清'],
  createdAt: DateTime(2026, 11, 8),
  isOrganized: true,
  reviewJoined: reviewJoined,
  sliceKind: 'material',
  sliceText: '题：$id',
  contentVersion: 1,
);

FsrsReviewScheduler _testScheduler(QuizDatabase db) => FsrsReviewScheduler(
  config: const SchedulerConfig(enableFuzzing: false),
  store: SqliteCardStore.forDatabase(db),
);

Future<Map<String, dynamic>?> _cardRow(QuizDatabase db, String questionId) async {
  final row = await db
      .customSelect(
        'SELECT * FROM fsrs_cards WHERE question_id = ?',
        variables: [Variable.withString(questionId)],
      )
      .getSingleOrNull();
  return row?.data;
}

Future<int> _cardCount(QuizDatabase db) async => (await db
        .customSelect('SELECT COUNT(*) AS n FROM fsrs_cards')
        .getSingle())
    .data['n'] as int;

void main() {
  group('V5 缺卡一次性补建（跟进批第 1 项）', () {
    late QuizDatabase db;
    late FsrsReviewScheduler scheduler;
    late Map<String, Object?> hasCardBefore;

    setUp(() async {
      db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      scheduler = _testScheduler(db);
      for (final id in _demoMissingIds) {
        await AppDatabase.upsertQuestionInto(db, _q(id));
      }
      // 已有卡的题：先建卡再正式答对一次（Good），卡片进入已开始状态。
      await AppDatabase.upsertQuestionInto(db, _q('q-has-card'));
      await scheduler.recordAnswer(
        'q-has-card',
        ReviewResult.good,
        DateTime.utc(2026, 11, 26, 10),
        'test-has-card-1',
      );
      hasCardBefore = (await _cardRow(db, 'q-has-card'))!;
      // 未加入复习的题：无卡，补建不应碰它。
      await AppDatabase.upsertQuestionInto(
        db,
        _q('q-not-joined', reviewJoined: false),
      );
    });

    tearDown(() async {
      await AppDatabase.resetForTest();
    });

    test('7 道演示题情形可补上卡：新卡未开始、不进到期队列、进新题释放', () async {
      final result = await backfillMissingFsrsCardsIntoImpl(db);
      expect(result['status'], 'completed');
      expect(result['backfilledCount'], 7);
      expect(
        (result['backfilledQuestionIds'] as List).toSet(),
        _demoMissingIds.toSet(),
      );
      expect(result['skippedWithCardCount'], 1);

      final now = DateTime.now().toUtc();
      final due = await scheduler.getDueQuestions(now);
      final fresh = await scheduler.getNewQuestions(50);
      for (final id in _demoMissingIds) {
        final row = await _cardRow(db, id);
        expect(row, isNotNull, reason: '$id 应补出一张卡');
        // 未开始新卡：firstReviewedAt 为空、调度器口径无下次到期日。
        expect(row!['first_reviewed_at'], isNull);
        expect(await scheduler.nextDueAt(id), isNull);
        // 不直接进到期队列，进“今日新题”释放。
        expect(due, isNot(contains(id)));
        expect(fresh, contains(id));
      }
      // 未加入的题不补建。
      expect(await _cardRow(db, 'q-not-joined'), isNull);
      expect(await _cardCount(db), 8);
      // 新卡结构一致：next_due_at 与卡片 JSON 里的 due 相等。
      expect(await verifyFsrsConsistencyInto(db), isEmpty);
    });

    test('已有卡的题状态不动', () async {
      await backfillMissingFsrsCardsIntoImpl(db);
      final after = (await _cardRow(db, 'q-has-card'))!;
      expect(after['card_state_json'], hasCardBefore['card_state_json']);
      expect(after['next_due_at'], hasCardBefore['next_due_at']);
      expect(after['first_reviewed_at'], hasCardBefore['first_reviewed_at']);
      expect(after['card_id'], hasCardBefore['card_id']);
      expect(await _cardCount(db), 8);
    });

    test('第二遍跑无变化（幂等，migration_log 只有一行 completed）', () async {
      final first = await backfillMissingFsrsCardsIntoImpl(db);
      expect(first['status'], 'completed');
      final cardsAfterFirst = await _cardCount(db);
      final sampleAfterFirst = await _cardRow(db, 'q-math-1');

      final second = await backfillMissingFsrsCardsIntoImpl(db);
      expect(second['status'], 'already_backfilled');
      expect(await _cardCount(db), cardsAfterFirst);
      final sampleAfterSecond = await _cardRow(db, 'q-math-1');
      expect(
        sampleAfterSecond!['card_state_json'],
        sampleAfterFirst!['card_state_json'],
      );
      expect(
        sampleAfterSecond['card_id'],
        sampleAfterFirst['card_id'],
      );
      final logRows = await db
          .customSelect(
            "SELECT COUNT(*) AS n FROM fsrs_migration_log WHERE source = ? AND status = 'completed'",
            variables: [
              Variable.withString(backfillMissingCardsSource),
            ],
          )
          .getSingle();
      expect(logRows.data['n'], 1);
    });

    test('audit_json 记录补建题 id 与跳过已有卡数', () async {
      await backfillMissingFsrsCardsIntoImpl(db);
      final row = (await db
              .customSelect(
                'SELECT audit_json, replayed_count, skipped_count FROM fsrs_migration_log WHERE source = ?',
                variables: [
                  Variable.withString(backfillMissingCardsSource),
                ],
              )
              .getSingle())
          .data;
      final audit =
          jsonDecode(row['audit_json'] as String) as Map<String, dynamic>;
      expect(
        (audit['backfilledQuestionIds'] as List).toSet(),
        _demoMissingIds.toSet(),
      );
      expect(audit['backfilledCount'], 7);
      expect(audit['skippedWithCardCount'], 1);
      expect(row['replayed_count'], 7);
      expect(row['skipped_count'], 1);
    });
  });
}
