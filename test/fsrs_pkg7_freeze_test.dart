// FSRS 全量迁移包 7：cause_records 冻结 + 数据完整性关口 + V8/V13。
//
// 针对性测试（计划 §5）：
// - UPDATE 只改 remedy 列（状态列全不动）；
// - INSERT 只允许冻结默认值；
// - 备份往返后 cause_records 状态列值不变、remedy_history 不丢；
// - V8：saveRemedy 全链路（写 → 读展示字段 → 备份往返）；
// - V13：删题同删 fsrs_cards、事件账本保留；归档滤掉、取消归档恢复、
//   归档卡不参与新释放计数。
// 全部用内存库 + 临时目录，不碰真实演示库。
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';

Future<QuizDatabase> _openTestDb() => AppDatabase.openForTest();

Future<Map<String, dynamic>> _causeRow(
  QuizDatabase db,
  String questionId,
  String cause,
) async {
  final rows = (await db
          .customSelect(
            'SELECT * FROM cause_records WHERE question_id = ? AND cause = ?',
            variables: [
              Variable.withString(questionId),
              Variable.withString(cause),
            ],
          )
          .get())
      .map((r) => r.data)
      .toList();
  return rows.single;
}

Future<void> _insertCauseRow(
  QuizDatabase db,
  String questionId,
  String cause, {
  String subjectId = 'math',
  String status = 'pending',
  int solvedCount = 0,
  int? lastCheck,
  int? recheckDate,
  int? anchorMs,
  String? anchorSession,
  String remedyHistory = '',
}) async {
  await db.customInsert(
    'INSERT INTO cause_records (question_id, cause, subject_id, status, '
    'solved_count, last_check, recheck_date, remedy_history, joined_at, '
    'last_counted_success_at, last_counted_session_id) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    variables: [
      Variable.withString(questionId),
      Variable.withString(cause),
      Variable.withString(subjectId),
      Variable.withString(status),
      Variable.withInt(solvedCount),
      Variable(lastCheck),
      Variable(recheckDate),
      Variable.withString(remedyHistory),
      Variable.withInt(1000),
      Variable(anchorMs),
      Variable(anchorSession),
    ],
  );
}

Future<void> _insertQuestion(
  QuizDatabase db,
  String id, {
  String subjectId = 'math',
  int isOrganized = 1,
  int reviewJoined = 1,
}) async {
  await db.customInsert(
    'INSERT INTO questions (id, title, subject_id, folder_ids, created_at, '
    'is_demo, is_organized, review_joined, review_count) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    variables: [
      Variable.withString(id),
      Variable.withString('t-$id'),
      Variable.withString(subjectId),
      Variable.withString('[]'),
      Variable.withInt(1000),
      Variable.withInt(0),
      Variable.withInt(isOrganized),
      Variable.withInt(reviewJoined),
      Variable.withInt(0),
    ],
  );
}

Question _q(String id) => Question(
      id: id,
      title: '题 $id',
      subjectId: 'math',
      createdAt: DateTime(2026, 11, 10),
      sliceText: '题干占位文字',
      errorTypes: const ['概念不清'],
      isOrganized: true,
      reviewJoined: true,
    );

FsrsReviewScheduler _scheduler() => FsrsReviewScheduler(
      config: const SchedulerConfig(enableFuzzing: false),
      store: SqliteCardStore(),
    );

/// 建一张已到期的 FSRS 卡：建卡 + 3 天前答对一次（Good 首间隔 2 天，
/// 到期日在昨天）。
Future<void> _seedDueCard(String id) async {
  final scheduler = _scheduler();
  await scheduler.initializeQuestion(id);
  await scheduler.recordAnswer(
    id,
    ReviewResult.good,
    DateTime.now().subtract(const Duration(days: 3)),
    'evt-pkg7-$id',
  );
}

Future<int> _count(
  QuizDatabase db,
  String sql, [
  List<Variable> variables = const [],
]) async {
  final rows = (await db.customSelect(sql, variables: variables).get())
      .map((r) => r.data)
      .toList();
  return (rows.single['n'] as num).toInt();
}

void main() {
  group('包 7 关口①②：cause_records 冻结', () {
    test('UPDATE 只改 remedy_history：已解决行的全部状态列原值不动', () async {
      final db = await _openTestDb();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async {
        await db.close();
        await AppDatabase.resetForTest();
      });
      final recheck = DateTime.now().add(const Duration(days: 7));
      final lastCheck = DateTime.now().subtract(const Duration(days: 1));
      await _insertCauseRow(
        db,
        'q1',
        '计算错误',
        status: 'solved',
        solvedCount: 2,
        lastCheck: lastCheck.millisecondsSinceEpoch,
        recheckDate: recheck.millisecondsSinceEpoch,
        anchorMs: lastCheck.millisecondsSinceEpoch,
        anchorSession: 'sess-old',
        remedyHistory: '["2026-11-10：旧补救"]',
      );
      await AppDatabase.instance.updateCauseRemedy(
        CauseRecord(
          questionId: 'q1',
          cause: '计算错误',
          subjectId: 'math',
          remedyHistory: ['2026-11-15：先列错因再算'],
          joinedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      );
      final row = await _causeRow(db, 'q1', '计算错误');
      expect(row['status'], 'solved');
      expect(row['solved_count'], 2);
      expect(row['last_check'], lastCheck.millisecondsSinceEpoch);
      expect(row['recheck_date'], recheck.millisecondsSinceEpoch);
      expect(
        row['last_counted_success_at'],
        lastCheck.millisecondsSinceEpoch,
      );
      expect(row['last_counted_session_id'], 'sess-old');
      expect(AppDatabase.decodeRemedyList(row['remedy_history']), [
        '2026-11-15：先列错因再算',
      ]);
    });

    test('INSERT 只允许冻结默认值：缺行写入不复活活状态行', () async {
      final db = await _openTestDb();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async {
        await db.close();
        await AppDatabase.resetForTest();
      });
      final repo = QuestionRepository(AppDatabase.instance);
      await repo.saveCauseRecord(
        CauseRecord(
          questionId: 'q2',
          cause: '概念不清',
          subjectId: 'math',
          remedyHistory: const ['2026-11-15：先看概念再做题'],
          joinedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      );
      final row = await _causeRow(db, 'q2', '概念不清');
      expect(row['status'], 'pending');
      expect(row['solved_count'], 0);
      expect(row['recheck_date'], isNull);
      expect(row['last_check'], isNull);
      expect(row['last_counted_success_at'], isNull);
      expect(row['last_counted_session_id'], isNull);
      expect(AppDatabase.decodeRemedyList(row['remedy_history']), [
        '2026-11-15：先看概念再做题',
      ]);
    });

    test('V8 saveRemedy：追加补救并返回更新后记录；空内容不写库', () async {
      final db = await _openTestDb();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async {
        await db.close();
        await AppDatabase.resetForTest();
      });
      final repo = QuestionRepository(AppDatabase.instance);
      final recheck = DateTime.now().add(const Duration(days: 7));
      await _insertCauseRow(
        db,
        'q1',
        '计算错误',
        status: 'solved',
        solvedCount: 2,
        recheckDate: recheck.millisecondsSinceEpoch,
        remedyHistory: '["2026-11-10：旧补救"]',
      );
      final before = (await repo.causeRecordsFor('q1')).single;
      expect(before.remedyHistory, ['2026-11-10：旧补救']);
      final updated = await repo.saveRemedy(before, '先列错因再算');
      expect(updated.remedyHistory.first, contains('先列错因再算'));
      expect(updated.remedyHistory, hasLength(2));
      // 写后读回：补救已追加，状态列仍是冻结原值。
      final row = await _causeRow(db, 'q1', '计算错误');
      expect(row['status'], 'solved');
      expect(row['solved_count'], 2);
      expect(row['recheck_date'], recheck.millisecondsSinceEpoch);
      expect(AppDatabase.decodeRemedyList(row['remedy_history']), hasLength(2));
      // 空内容不保存：返回原记录、不写库（q1 的补救仍是 2 条）。
      final same = await repo.saveRemedy(before, '   ');
      expect(identical(same, before), isTrue);
      final rowAfterEmpty = await _causeRow(db, 'q1', '计算错误');
      expect(
        AppDatabase.decodeRemedyList(rowAfterEmpty['remedy_history']),
        hasLength(2),
      );
    });
  });

  group('包 7 关口①：备份往返', () {
    test('备份导出再恢复：cause_records 状态列值与 remedy_history 原样回来',
        () async {
      final source = await _openTestDb();
      addTearDown(() async {
        await source.close();
        await AppDatabase.resetForTest();
      });
      for (final s in Subject.all) {
        await source
            .into(source.subjects)
            .insert(
              SubjectsCompanion.insert(
                id: s.id,
                name: s.name,
                color: 0xFF2E7CF6,
              ),
            );
      }
      await _insertQuestion(source, 'q1');
      final recheck = DateTime.now().add(const Duration(days: 7));
      await _insertCauseRow(
        source,
        'q1',
        '计算错误',
        status: 'solved',
        solvedCount: 2,
        recheckDate: recheck.millisecondsSinceEpoch,
        anchorMs: 123456789,
        anchorSession: 'sess-old',
        remedyHistory: '["2026-11-10：旧补救", "2026-11-15：新补救"]',
      );
      final json = await AppDatabase.exportBackupJsonFrom(source);
      final data = jsonDecode(json) as Map<String, dynamic>;
      final target = await _openTestDb();
      addTearDown(() async {
        await target.close();
        await AppDatabase.resetForTest();
      });
      await AppDatabase.importBackupJsonInto(target, data);
      final row = await _causeRow(target, 'q1', '计算错误');
      expect(row['status'], 'solved');
      expect(row['solved_count'], 2);
      expect(row['recheck_date'], recheck.millisecondsSinceEpoch);
      expect(row['last_counted_success_at'], 123456789);
      expect(row['last_counted_session_id'], 'sess-old');
      expect(AppDatabase.decodeRemedyList(row['remedy_history']), [
        '2026-11-10：旧补救',
        '2026-11-15：新补救',
      ]);
    });
  });

  group('包 7 关口③：旧设置字段退役', () {
    test('AppSettings：toMap 不写旧键，fromMap 忽略旧键', () {
      const settings = AppSettings();
      final map = settings.toMap();
      expect(map.containsKey('cureChecks'), isFalse);
      expect(map.containsKey('recheckIntervalDays'), isFalse);
      final restored = AppSettings.fromMap({
        ...map,
        'cureChecks': '1',
        'recheckIntervalDays': '3',
      });
      expect(restored.toMap(), settings.toMap());
    });
  });

  group('V13：删题 / 归档对 FSRS 的影响', () {
    test('删题：fsrs_cards 行同删，due 队列排除，事件账本与 cause 行按契约处理',
        () async {
      final db = await _openTestDb();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async {
        await db.close();
        await AppDatabase.resetForTest();
      });
      final repo = QuestionRepository(AppDatabase.instance);
      for (final s in Subject.all) {
        await repo.saveSubject(s);
      }
      final q = _q('q1');
      await repo.save(q);
      await _seedDueCard('q1');
      final scheduler = _scheduler();
      expect(await repo.fsrsDueQuestionIds(scheduler: scheduler), ['q1']);
      final eventsBefore = await _count(db, 'SELECT COUNT(*) AS n FROM fsrs_events');
      expect(eventsBefore, greaterThan(0));
      await repo.delete(q);
      expect(await repo.fsrsDueQuestionIds(scheduler: scheduler), isEmpty);
      expect(
        await _count(
          db,
          'SELECT COUNT(*) AS n FROM fsrs_cards WHERE question_id = ?',
          [Variable.withString('q1')],
        ),
        0,
      );
      // 事件账本是幂等审计记录，保留不动。
      expect(
        await _count(db, 'SELECT COUNT(*) AS n FROM fsrs_events'),
        eventsBefore,
      );
      // 删题事务同时删 cause_records 行（既有级联契约）。
      expect(
        await _count(
          db,
          'SELECT COUNT(*) AS n FROM cause_records WHERE question_id = ?',
          [Variable.withString('q1')],
        ),
        0,
      );
    });

    test('归档：due 队列与新释放都滤掉归档题；取消归档后卡恢复可见', () async {
      final db = await _openTestDb();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async {
        await db.close();
        await AppDatabase.resetForTest();
      });
      final repo = QuestionRepository(AppDatabase.instance);
      for (final s in Subject.all) {
        await repo.saveSubject(s);
      }
      final qDue = _q('q-due');
      final qNew = _q('q-new');
      await repo.save(qDue);
      await repo.save(qNew);
      await _seedDueCard('q-due');
      await _scheduler().initializeQuestion('q-new');
      final scheduler = _scheduler();
      expect(await repo.fsrsDueQuestionIds(scheduler: scheduler), ['q-due']);
      var plan = await repo.previewNewRelease(
        scheduler: scheduler,
        dailyNewLimit: 10,
      );
      expect(plan.newlyReleasableIds, contains('q-new'));

      // 归档两题：到期队列与新释放都看不到它们，但卡还在库里。
      await repo.save(qDue.copyWith(isArchived: true));
      await repo.save(qNew.copyWith(isArchived: true));
      expect(await repo.fsrsDueQuestionIds(scheduler: scheduler), isEmpty);
      plan = await repo.previewNewRelease(
        scheduler: scheduler,
        dailyNewLimit: 10,
      );
      expect(plan.newlyReleasableIds, isNot(contains('q-new')));
      expect(
        await _count(
          db,
          'SELECT COUNT(*) AS n FROM fsrs_cards WHERE question_id IN (?, ?)',
          [Variable.withString('q-due'), Variable.withString('q-new')],
        ),
        2,
      );

      // 取消归档：卡恢复可见（到期与新释放都回来）。
      await repo.save(qDue.copyWith(isArchived: false));
      await repo.save(qNew.copyWith(isArchived: false));
      expect(await repo.fsrsDueQuestionIds(scheduler: scheduler), ['q-due']);
      plan = await repo.previewNewRelease(
        scheduler: scheduler,
        dailyNewLimit: 10,
      );
      expect(plan.newlyReleasableIds, contains('q-new'));
    });
  });
}
