// SR-P1-3 回归测试：deleteExam 三步写不在事务里，且第一步
// `update exams set name=''` 是死步骤。
// 修后：删试卷行 + 题上 exam_id 置空包进同一事务（deleteExamFromImpl），
// 无意义的 name='' 步骤已删。
// 全部用内存库（createTables 建表，不播种演示数据），不碰真实库。
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';

Future<QuizDatabase> openTestDb() => AppDatabase.openForTest();

Future<void> insertExamRow(QuizDatabase db, String id, String name) async {
  await db.customInsert(
    'INSERT INTO exams (id, name) VALUES (?, ?)',
    variables: [Variable.withString(id), Variable.withString(name)],
  );
}

Future<void> insertQuestionRow(
  QuizDatabase db,
  String id, {
  String? examId,
}) async {
  await db.customInsert(
    'INSERT INTO questions (id, title, subject_id, folder_ids, created_at, '
    'tags, knowledge_ids, exam_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
    variables: [
      Variable.withString(id),
      Variable.withString('t-$id'),
      Variable.withString('math'),
      Variable.withString(''),
      Variable.withInt(1000),
      Variable.withString(''),
      Variable.withString(''),
      Variable(examId),
    ],
  );
}

void main() {
  group('SR-P1-3 deleteExam 事务性', () {
    test('删试卷：试卷行消失，挂了该试卷的题 exam_id 置空，其余不动', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertExamRow(db, 'e1', '期中考试');
      await insertExamRow(db, 'e2', '期末考试');
      await insertQuestionRow(db, 'q1', examId: 'e1');
      await insertQuestionRow(db, 'q2', examId: 'e1');
      await insertQuestionRow(db, 'q3', examId: 'e2');
      await insertQuestionRow(db, 'q4');

      await AppDatabase.deleteExamFrom(db, 'e1');

      expect(
        (await db.customSelect('SELECT * FROM exams').get())
            .map((r) => r.data['id'])
            .toList(),
        ['e2'],
      );
      final qs =
          (await db.customSelect('SELECT * FROM questions ORDER BY id').get())
              .map((r) => r.data)
              .toList();
      expect(qs.map((r) => (r['id'], r['exam_id'])).toList(), [
        ('q1', null),
        ('q2', null),
        ('q3', 'e2'),
        ('q4', null),
      ]);
    });

    test('deleteExamFrom 中途失败：试卷行与题上的引用整体回滚', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertExamRow(db, 'e1', '期中考试');
      await insertQuestionRow(db, 'q1', examId: 'e1');
      // 让第二步（题上 exam_id 置空）必失败：试卷行已删，题还没改。
      await db.customStatement(
        "CREATE TRIGGER trg_fail_qup BEFORE UPDATE ON questions "
        "BEGIN SELECT RAISE(ABORT, 'boom'); END;",
      );
      await expectLater(
        AppDatabase.deleteExamFrom(db, 'e1'),
        throwsA(anything),
      );
      // 回滚：试卷行还在（名字未被清空成 ''），题仍指着它。
      final exams = (await db.customSelect('SELECT * FROM exams').get())
          .map((r) => r.data)
          .toList();
      expect(exams.single['id'], 'e1');
      expect(exams.single['name'], '期中考试');
      final q = (await db.customSelect('SELECT * FROM questions').get())
          .map((r) => r.data)
          .toList();
      expect(q.single['exam_id'], 'e1');
    });

    test('删不存在的试卷：不抛错，不动任何题', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertExamRow(db, 'e1', '期中考试');
      await insertQuestionRow(db, 'q1', examId: 'e1');

      await AppDatabase.deleteExamFrom(db, 'no-such-exam');

      expect(
        (await db.customSelect('SELECT * FROM exams').get())
            .map((r) => r.data)
            .toList()
            .single['id'],
        'e1',
      );
      expect(
        (await db.customSelect('SELECT * FROM questions').get())
            .map((r) => r.data)
            .toList()
            .single['exam_id'],
        'e1',
      );
    });
  });
}
