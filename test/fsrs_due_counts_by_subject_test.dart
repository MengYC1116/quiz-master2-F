// FSRS 口径迁移 §2.4：`fsrsDueCountsBySubject` 单测。
//
// - 纯函数核 `fsrsDueCountsBySubjectPure`：夹具数据，不依赖真库
//   （仿 `planNewRelease` 的纯函数模式）。
// - 真库对照：内存库 + 确定性调度器，断言分科计数、总数与
//   `fsrsDueQuestionIds().length` 相等、归档排除、未开始新卡不计。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';

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
  createdAt: DateTime(2026, 11, 14),
  sliceText: '题干占位文字',
  errorTypes: const ['概念不清'],
  isOrganized: true,
);

/// 建一张已到期的卡：建卡 + 3 天前答对一次（Good 首间隔 2 天）。
Future<void> _seedDueCard(String id) async {
  final scheduler = _testScheduler();
  await scheduler.initializeQuestion(id);
  await scheduler.recordAnswer(
    id,
    ReviewResult.good,
    DateTime.now().subtract(const Duration(days: 3)),
    'evt-counts-$id',
  );
}

void main() {
  group('fsrsDueCountsBySubjectPure（纯函数核）', () {
    test('按学科分组：到期 3 道 = 数学 2 + 英语 1，政治 0', () {
      expect(
        QuestionRepository.fsrsDueCountsBySubjectPure(
          dueIds: const ['q1', 'q2', 'q3'],
          subjectByQuestionId: const {
            'q1': 'math',
            'q2': 'math',
            'q3': 'english',
          },
          subjectIds: const ['math', 'english', 'politics'],
        ),
        {'math': 2, 'english': 1, 'politics': 0},
      );
    });

    test('空到期列表：各科全 0，但键都在', () {
      expect(
        QuestionRepository.fsrsDueCountsBySubjectPure(
          dueIds: const [],
          subjectByQuestionId: const {'q1': 'math'},
          subjectIds: const ['math', 'english'],
        ),
        {'math': 0, 'english': 0},
      );
    });

    test('查无此题的 id 跳过；subjects 表外学科单独立键、不丢数', () {
      expect(
        QuestionRepository.fsrsDueCountsBySubjectPure(
          dueIds: const ['q1', 'q-ghost', 'q9'],
          subjectByQuestionId: const {'q1': 'math', 'q9': 'chem'},
          subjectIds: const ['math', 'english'],
        ),
        {'math': 1, 'english': 0, 'chem': 1},
      );
    });
  });

  group('fsrsDueCountsBySubject（真库）', () {
    test('分科计数 = 到期集合分组；总数 = fsrsDueQuestionIds 长度', () async {
      final repo = await _seedMemoryRepo();
      final scheduler = _testScheduler();
      // q1 数学到期；q2 数学只建卡未开始（不算到期）；
      // q3 英语到期；q4 政治到期但已归档（不算）。
      for (final id in ['q1', 'q2', 'q3', 'q4']) {
        final subjectId = id == 'q3'
            ? 'english'
            : (id == 'q4' ? 'politics' : 'math');
        await repo.save(_q(id, subjectId: subjectId));
      }
      await _seedDueCard('q1');
      await scheduler.initializeQuestion('q2');
      await _seedDueCard('q3');
      await _seedDueCard('q4');
      await repo.archive((await repo.questionById('q4'))!);

      final counts = await repo.fsrsDueCountsBySubject(
        scheduler: scheduler,
      );
      expect(counts, {'math': 1, 'english': 1, 'politics': 0});
      final dueIds = await repo.fsrsDueQuestionIds(scheduler: scheduler);
      expect(dueIds, unorderedEquals(['q1', 'q3']));
      expect(await repo.fsrsDueTotal(scheduler: scheduler), dueIds.length);
      expect(await repo.fsrsDueTotal(scheduler: scheduler), 2);
    });
  });
}
