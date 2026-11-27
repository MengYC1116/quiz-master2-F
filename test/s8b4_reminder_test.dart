// S8 B4.1：到期复习提醒触发条件（纯函数 + 仓库计数）。
//
// FSRS 全量迁移包 3：计数源由错因数 `recheckDueCauseCount`（已删除）
// 换成到期题数 `fsrsDueTotal`；纯函数 `shouldShowRecheckReminder`
// 本身不变（参数化，换数据源改动面小），只同步文案措辞。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/recheck_reminder.dart';

/// 确定性调度器（fuzzing 关）+ SQLite store，绑当前测试库。
FsrsReviewScheduler _testScheduler() => FsrsReviewScheduler(
  config: const SchedulerConfig(enableFuzzing: false),
  store: SqliteCardStore(),
);

Future<QuestionRepository> _seedMemoryRepo() async {
  final db = await AppDatabase.openForTest();
  AppDatabase.useDatabaseForTest(db);
  addTearDown(() async {
    await AppDatabase.resetForTest();
  });
  final repo = QuestionRepository(AppDatabase.instance);
  for (final s in Subject.all) {
    await repo.saveSubject(s);
  }
  return repo;
}

Question _q(String id, {required String subjectId}) => Question(
  id: id,
  title: '题 $id',
  subjectId: subjectId,
  createdAt: DateTime(2026, 11, 1),
  isOrganized: true,
  sliceText: '题干占位文字',
  errorTypes: const ['概念不清'],
);

/// 建一张已到期的卡：建卡 + 3 天前答对一次（Good 首间隔 2 天）。
Future<void> _seedDueCard(String id) async {
  final scheduler = _testScheduler();
  await scheduler.initializeQuestion(id);
  await scheduler.recordAnswer(
    id,
    ReviewResult.good,
    DateTime.now().subtract(const Duration(days: 3)),
    'evt-reminder-$id',
  );
}

void main() {
  group('shouldShowRecheckReminder', () {
    // 当天 20:00 提醒；有 FSRS 卡到期时才弹。
    const time = '20:00';
    final after = DateTime(2026, 11, 13, 20, 30);
    final before = DateTime(2026, 11, 13, 19, 30);

    test('开关关掉不提醒', () {
      expect(
          shouldShowRecheckReminder(
              notifyEnabled: false,
              notifyTime: time,
              dueRecheckCount: 1,
              now: after),
          isFalse);
    });

    test('没有到期的题不提醒', () {
      expect(
          shouldShowRecheckReminder(
              notifyEnabled: true,
              notifyTime: time,
              dueRecheckCount: 0,
              now: after),
          isFalse);
    });

    test('还没到当日提醒时间不提醒', () {
      expect(
          shouldShowRecheckReminder(
              notifyEnabled: true,
              notifyTime: time,
              dueRecheckCount: 1,
              now: before),
          isFalse);
    });

    test('到了提醒时间就提醒', () {
      expect(
          shouldShowRecheckReminder(
              notifyEnabled: true,
              notifyTime: time,
              dueRecheckCount: 1,
              now: after),
          isTrue);
    });

    test('整点那一刻也算到点', () {
      expect(
          shouldShowRecheckReminder(
              notifyEnabled: true,
              notifyTime: time,
              dueRecheckCount: 1,
              now: DateTime(2026, 11, 13, 20, 0)),
          isTrue);
    });

    test('今天已提醒过不再弹', () {
      expect(
          shouldShowRecheckReminder(
              notifyEnabled: true,
              notifyTime: time,
              dueRecheckCount: 1,
              now: after,
              lastRemindedDate: '2026-11-13'),
          isFalse);
    });

    test('昨天提醒过、今天没提醒过，到了时间就弹', () {
      expect(
          shouldShowRecheckReminder(
              notifyEnabled: true,
              notifyTime: time,
              dueRecheckCount: 1,
              now: after,
              lastRemindedDate: '2026-11-12'),
          isTrue);
    });

    test('提醒时间写坏了按默认 20:00 算', () {
      expect(
          shouldShowRecheckReminder(
              notifyEnabled: true,
              notifyTime: 'abc',
              dueRecheckCount: 1,
              now: DateTime(2026, 11, 13, 19, 0)),
          isFalse);
      expect(
          shouldShowRecheckReminder(
              notifyEnabled: true,
              notifyTime: 'abc',
              dueRecheckCount: 1,
              now: DateTime(2026, 11, 13, 21, 0)),
          isTrue);
    });
  });

  group('parseNotifyTime / recheckReminderDateString', () {
    test('正常解析与回落', () {
      expect(parseNotifyTime('20:00'), (hour: 20, minute: 0));
      expect(parseNotifyTime('08:30'), (hour: 8, minute: 30));
      expect(parseNotifyTime('25:00'), (hour: 20, minute: 0));
      expect(parseNotifyTime(''), (hour: 20, minute: 0));
    });

    test('日期串格式 yyyy-MM-dd', () {
      expect(recheckReminderDateString(DateTime(2026, 11, 3, 9, 5)),
          '2026-11-03');
    });
  });

  group('fsrsDueTotal（提醒计数源，FSRS 全量迁移包 3）', () {
    test('计数 = 到期题数，不含未开始新题', () async {
      final repo = await _seedMemoryRepo();
      final scheduler = _testScheduler();
      // q1 数学到期；q2 数学只建卡未开始（新题，走 previewNewRelease，
      // 不算到期）；q3 英语到期。
      await repo.save(_q('q1', subjectId: 'math'));
      await repo.save(_q('q2', subjectId: 'math'));
      await repo.save(_q('q3', subjectId: 'english'));
      await _seedDueCard('q1');
      await scheduler.initializeQuestion('q2');
      await _seedDueCard('q3');
      expect(await repo.fsrsDueTotal(scheduler: scheduler), 2);
    });

    test('与队列到期集合一致：总数 = fsrsDueQuestionIds 长度', () async {
      final repo = await _seedMemoryRepo();
      final scheduler = _testScheduler();
      await repo.save(_q('q1', subjectId: 'math'));
      await repo.save(_q('q2', subjectId: 'math'));
      await repo.save(_q('q3', subjectId: 'english'));
      await _seedDueCard('q1');
      await scheduler.initializeQuestion('q2');
      await _seedDueCard('q3');
      // _buildDueSessionQuestions 的到期题集合即由此取数
      //（同一数据源 fsrsDueQuestionIds）。
      final dueIds = await repo.fsrsDueQuestionIds(scheduler: scheduler);
      expect(dueIds, unorderedEquals(['q1', 'q3']));
      expect(await repo.fsrsDueTotal(scheduler: scheduler), dueIds.length);
    });

    test('归档题不计入，取消归档后恢复计入', () async {
      final repo = await _seedMemoryRepo();
      final scheduler = _testScheduler();
      await repo.save(_q('q1', subjectId: 'math'));
      await _seedDueCard('q1');
      expect(await repo.fsrsDueTotal(scheduler: scheduler), 1);
      await repo.archive((await repo.questionById('q1'))!);
      expect(await repo.fsrsDueTotal(scheduler: scheduler), 0);
      await repo.archive((await repo.questionById('q1'))!,
          archived: false);
      expect(await repo.fsrsDueTotal(scheduler: scheduler), 1);
    });

    test('无卡的题不计入（未加入复习）', () async {
      final repo = await _seedMemoryRepo();
      final scheduler = _testScheduler();
      await repo.save(_q('q1', subjectId: 'math'));
      expect(await repo.fsrsDueTotal(scheduler: scheduler), 0);
    });
  });
}
