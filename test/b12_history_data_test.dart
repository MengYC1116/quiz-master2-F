// 十二批功能 4（D-91）：首页历史——数据层测试。
// 覆盖：空表读空、记录一条、同一题去重（时间更新为最后一次）、
// 顺序最新在前、剪到最新 30 条、已删题读出时跳过。
// 用内存库（openForTest + useDatabaseForTest，见 b2_recent_task_test）。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';

Question _q(String id, String title, {String subjectId = 'math'}) =>
    Question(
      id: id,
      title: title,
      subjectId: subjectId,
      createdAt: DateTime(2026, 11, 10),
    );

Future<QuizDatabase> _openMemoryDb() async {
  final db = await AppDatabase.openForTest();
  AppDatabase.useDatabaseForTest(db);
  addTearDown(() async {
    await AppDatabase.resetForTest();
  });
  return db;
}

void main() {
  group('recently_viewed_questions 数据层', () {
    test('空表读空列表', () async {
      await _openMemoryDb();
      expect(await AppDatabase.instance.recentlyViewedQuestions(), isEmpty);
    });

    test('记录一条后读出题 + 最后查看时间', () async {
      await _openMemoryDb();
      await AppDatabase.instance.upsertQuestion(_q('q1', '函数极限'));
      final at = DateTime(2026, 11, 17, 22, 44).millisecondsSinceEpoch;
      await AppDatabase.instance.recordQuestionViewed(
        'q1',
        viewedAtMillis: at,
      );
      final back = await AppDatabase.instance.recentlyViewedQuestions();
      expect(back, hasLength(1));
      expect(back.single.question.id, 'q1');
      expect(back.single.question.title, '函数极限');
      expect(
        back.single.viewedAt,
        DateTime.fromMillisecondsSinceEpoch(at),
      );
    });

    test('同一题只留一条：再记一次，时间更新为最后一次', () async {
      final db = await _openMemoryDb();
      await AppDatabase.instance.upsertQuestion(_q('q1', '函数极限'));
      await AppDatabase.instance.recordQuestionViewed(
        'q1',
        viewedAtMillis: 1000,
      );
      await AppDatabase.instance.recordQuestionViewed(
        'q1',
        viewedAtMillis: 2000,
      );
      final rows = await db.select(db.recentlyViewedQuestions).get();
      expect(rows, hasLength(1));
      expect(rows.single.viewedAt, 2000);
      final back = await AppDatabase.instance.recentlyViewedQuestions();
      expect(back, hasLength(1));
      expect(
        back.single.viewedAt,
        DateTime.fromMillisecondsSinceEpoch(2000),
      );
    });

    test('顺序最新在前：后看的排前面', () async {
      await _openMemoryDb();
      for (final id in ['q1', 'q2', 'q3']) {
        await AppDatabase.instance.upsertQuestion(_q(id, '题 $id'));
      }
      await AppDatabase.instance.recordQuestionViewed(
        'q1',
        viewedAtMillis: 1000,
      );
      await AppDatabase.instance.recordQuestionViewed(
        'q2',
        viewedAtMillis: 3000,
      );
      await AppDatabase.instance.recordQuestionViewed(
        'q3',
        viewedAtMillis: 2000,
      );
      final back = await AppDatabase.instance.recentlyViewedQuestions();
      expect(
        back.map((e) => e.question.id).toList(),
        ['q2', 'q3', 'q1'],
      );
    });

    test('重看旧题顶到最前：时间更新后顺序跟着变', () async {
      await _openMemoryDb();
      for (final id in ['q1', 'q2']) {
        await AppDatabase.instance.upsertQuestion(_q(id, '题 $id'));
      }
      await AppDatabase.instance.recordQuestionViewed(
        'q1',
        viewedAtMillis: 1000,
      );
      await AppDatabase.instance.recordQuestionViewed(
        'q2',
        viewedAtMillis: 2000,
      );
      await AppDatabase.instance.recordQuestionViewed(
        'q1',
        viewedAtMillis: 3000,
      );
      final back = await AppDatabase.instance.recentlyViewedQuestions();
      expect(
        back.map((e) => e.question.id).toList(),
        ['q1', 'q2'],
      );
    });

    test('剪到最新 30 条：记 35 道，只留最新 30 道', () async {
      final db = await _openMemoryDb();
      for (var i = 0; i < 35; i++) {
        await AppDatabase.instance.upsertQuestion(_q('q$i', '题 $i'));
      }
      for (var i = 0; i < 35; i++) {
        await AppDatabase.instance.recordQuestionViewed(
          'q$i',
          viewedAtMillis: 1000 + i,
        );
      }
      final rows = await db.select(db.recentlyViewedQuestions).get();
      expect(rows, hasLength(30));
      final back = await AppDatabase.instance.recentlyViewedQuestions();
      expect(back, hasLength(30));
      expect(back.first.question.id, 'q34');
      expect(back.last.question.id, 'q5');
      expect(
        back.map((e) => e.question.id),
        isNot(contains('q0')),
      );
    });

    test('已删题读出时跳过：删题后只剩在库的题', () async {
      await _openMemoryDb();
      await AppDatabase.instance.upsertQuestion(_q('q1', '函数极限'));
      await AppDatabase.instance.upsertQuestion(_q('q2', '定积分'));
      await AppDatabase.instance.recordQuestionViewed(
        'q1',
        viewedAtMillis: 1000,
      );
      await AppDatabase.instance.recordQuestionViewed(
        'q2',
        viewedAtMillis: 2000,
      );
      await AppDatabase.instance.deleteQuestion('q2');
      final back = await AppDatabase.instance.recentlyViewedQuestions();
      expect(
        back.map((e) => e.question.id).toList(),
        ['q1'],
      );
    });

    test('仓库透传：record / recentlyViewedQuestions 走同一张表', () async {
      await _openMemoryDb();
      final repo = QuestionRepository(AppDatabase.instance);
      await AppDatabase.instance.upsertQuestion(_q('q1', '函数极限'));
      await repo.recordQuestionViewed('q1');
      final back = await repo.recentlyViewedQuestions();
      expect(back, hasLength(1));
      expect(back.single.question.id, 'q1');
    });
  });
}
