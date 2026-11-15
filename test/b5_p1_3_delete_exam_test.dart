// SR-P1-3 回归测试：deleteExam 三步写不在事务里，且第一步
// `update exams set name=''` 是死步骤。
// 修后：删试卷行 + 题上 exam_id 置空包进同一事务（deleteExamFromImpl），
// 无意义的 name='' 步骤已删。
// 全部用内存库（createTables 建表，不播种演示数据），不碰真实库。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> openTestDb() async {
  sqfliteFfiInit();
  return databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async =>
              AppDatabase.createTables(db)));
}

Future<void> insertExamRow(Database db, String id, String name) async {
  await db.insert('exams', {'id': id, 'name': name});
}

Future<void> insertQuestionRow(Database db, String id,
    {String? examId}) async {
  await db.insert('questions', {
    'id': id,
    'title': 't-$id',
    'subject_id': 'math',
    'folder_ids': '',
    'created_at': 1000,
    'tags': '',
    'knowledge_ids': '',
    'exam_id': examId,
  });
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
          (await db.query('exams')).map((r) => r['id']).toList(), ['e2']);
      final qs = await db.query('questions', orderBy: 'id');
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
      await db.execute(
          "CREATE TRIGGER trg_fail_qup BEFORE UPDATE ON questions "
          "BEGIN SELECT RAISE(ABORT, 'boom'); END;");
      await expectLater(
          AppDatabase.deleteExamFrom(db, 'e1'), throwsA(anything));
      // 回滚：试卷行还在（名字未被清空成 ''），题仍指着它。
      final exams = await db.query('exams');
      expect(exams.single['id'], 'e1');
      expect(exams.single['name'], '期中考试');
      final q = await db.query('questions');
      expect(q.single['exam_id'], 'e1');
    });

    test('删不存在的试卷：不抛错，不动任何题', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertExamRow(db, 'e1', '期中考试');
      await insertQuestionRow(db, 'q1', examId: 'e1');

      await AppDatabase.deleteExamFrom(db, 'no-such-exam');

      expect((await db.query('exams')).single['id'], 'e1');
      expect((await db.query('questions')).single['exam_id'], 'e1');
    });
  });
}
