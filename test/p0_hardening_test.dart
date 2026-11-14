// P0 数据层加固（DB-CHANGE-PLAN.md §4.1–§4.5）回归测试。
// 全部用内存库（createTables 建表，不播种演示数据），不碰真实库；
// 只有 §4.1 一项走 AppDatabase.instance.db（验证并发只 open 一次），
// 该调用只读真实库（旧库缺 created_at 列时补一列，见 §4.3）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> openTestDb() async {
  sqfliteFfiInit();
  return databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async =>
              AppDatabase.createTables(db)));
}

Future<void> insertQuestion(Database db, String id,
    {String subjectId = 'math',
    int isDemo = 0,
    int reviewCount = 0,
    String folderIds = ''}) async {
  await db.insert('questions', {
    'id': id,
    'title': 't-$id',
    'subject_id': subjectId,
    'folder_ids': folderIds,
    'created_at': 1000,
    'is_demo': isDemo,
    'review_count': reviewCount,
  });
}

Future<void> insertCauseRecord(Database db, String questionId, String cause,
    {String subjectId = 'math', String status = 'pending'}) async {
  await db.insert('cause_records', {
    'question_id': questionId,
    'cause': cause,
    'subject_id': subjectId,
    'status': status,
    'solved_count': 0,
    'joined_at': 1000,
  });
}

Future<void> insertHistory(Database db, String questionId,
    {String result = 'solved'}) async {
  await db.insert('review_history', {
    'question_id': questionId,
    'result': result,
    'reviewed_at': 1000,
  });
}

void main() {
  group('§4.1 db 缓存 Future', () {
    test('并发 await db 只打开一次（同一 Database 对象）', () async {
      final results = await Future.wait([
        AppDatabase.instance.db,
        AppDatabase.instance.db,
        AppDatabase.instance.db,
      ]);
      expect(results[0], same(results[1]));
      expect(results[1], same(results[2]));
      // 串行再取仍是同一个连接。
      expect(await AppDatabase.instance.db, same(results[0]));
    });
  });

  group('§4.4 备份 jsonEncode', () {
    test('笔记含 Tab/CR/控制字符：导出是合法 JSON，恢复后内容一致', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      const notes = '第一行\t第二列\r回车\x01控制\x08退格\x0c换页\\反斜杠"引号\n换行';
      await insertQuestion(db, 'q1', subjectId: 'math');
      await db.update('questions', {'notes': notes},
          where: 'id = ?', whereArgs: ['q1']);
      // 旧手写 _jsonValue 漏转 \r \t \b \f 与控制字符，导出的 JSON
      // 是非法的；jsonEncode 必须能导出且 jsonDecode 不抛错。
      final exported = await AppDatabase.exportBackupJsonFrom(db);
      final decoded = jsonDecode(exported) as Map<String, dynamic>;
      await AppDatabase.importBackupJsonInto(db, decoded);
      final rows = await db.query('questions');
      expect(rows, hasLength(1));
      expect(rows.first['notes'], notes);
    });
  });

  group('§4.2 事务', () {
    test('recordSelfCheckInto 成功：三步都写', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertQuestion(db, 'q1', reviewCount: 5);
      await insertCauseRecord(db, 'q1', '计算错误');
      final record = CauseRecord(
        questionId: 'q1',
        cause: '计算错误',
        subjectId: 'math',
        status: CauseStatus.pending,
        solvedCount: 0,
        joinedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      await AppDatabase.recordSelfCheckInto(db,
          updated: record.copyWith(
              status: CauseStatus.inProgress, solvedCount: 1),
          questionId: 'q1',
          result: 'solved');
      final causes = await db.query('cause_records');
      expect(causes.single['solved_count'], 1);
      expect(causes.single['status'], 'inProgress');
      expect(await db.query('review_history'), hasLength(1));
      final q = await db.query('questions');
      expect(q.single['review_count'], 6);
    });

    test('recordSelfCheckInto 中途失败：三步整体回滚', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertQuestion(db, 'q1', reviewCount: 5);
      await insertCauseRecord(db, 'q1', '计算错误');
      // 让第二步（写 review_history）必失败，模拟中途崩溃/抛错。
      await db.execute(
          "CREATE TRIGGER trg_fail_history BEFORE INSERT ON review_history "
          "BEGIN SELECT RAISE(ABORT, 'boom'); END;");
      final record = CauseRecord(
        questionId: 'q1',
        cause: '计算错误',
        subjectId: 'math',
        status: CauseStatus.pending,
        solvedCount: 0,
        joinedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      await expectLater(
          AppDatabase.recordSelfCheckInto(db,
              updated: record.copyWith(
                  status: CauseStatus.inProgress, solvedCount: 1),
              questionId: 'q1',
              result: 'solved'),
          throwsA(anything));
      // 回滚：错因记录没变、自查历史没写、题目次数没加。
      final causes = await db.query('cause_records');
      expect(causes.single['solved_count'], 0);
      expect(causes.single['status'], 'pending');
      expect(await db.query('review_history'), isEmpty);
      final q = await db.query('questions');
      expect(q.single['review_count'], 5);
    });

    test('deleteSubjectFrom 中途失败：整科整体回滚', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await db.insert(
          'subjects', {'id': 'math', 'name': '数学', 'color': 0xFF000000});
      await insertQuestion(db, 'q1');
      await insertCauseRecord(db, 'q1', '计算错误');
      await db.execute(
          "CREATE TRIGGER trg_fail_qdel BEFORE DELETE ON questions "
          "BEGIN SELECT RAISE(ABORT, 'boom'); END;");
      await expectLater(
          AppDatabase.deleteSubjectFrom(db, 'math'), throwsA(anything));
      expect(await db.query('subjects'), hasLength(1));
      expect(await db.query('questions'), hasLength(1));
      expect(await db.query('cause_records'), hasLength(1));
    });

    test('deleteFolderFrom 中途失败：文件夹与题整体回滚', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await db.insert('folders', {
        'id': 'f1',
        'name': '试卷',
        'subject_id': 'math',
        'parent_id': null,
        'sort_order': 0,
      });
      await insertQuestion(db, 'q1', folderIds: '["f1"]');
      await db.execute(
          "CREATE TRIGGER trg_fail_qdel BEFORE DELETE ON questions "
          "BEGIN SELECT RAISE(ABORT, 'boom'); END;");
      await expectLater(
          AppDatabase.deleteFolderFrom(
              db,
              const Folder(
                  id: 'f1', name: '试卷', subjectId: 'math')),
          throwsA(anything));
      expect(await db.query('folders'), hasLength(1));
      expect(await db.query('questions'), hasLength(1));
    });

    test('deleteFolderFrom 成功：子文件夹递归、只挂多文件夹的题只移走关联',
        () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await db.insert('folders', {
        'id': 'f1',
        'name': '试卷',
        'subject_id': 'math',
        'parent_id': null,
        'sort_order': 0,
      });
      await db.insert('folders', {
        'id': 'f2',
        'name': '子卷',
        'subject_id': 'math',
        'parent_id': 'f1',
        'sort_order': 0,
      });
      await insertQuestion(db, 'q1', folderIds: '["f1"]');
      await insertQuestion(db, 'q2', folderIds: '["f1","f2"]');
      await insertQuestion(db, 'q3', folderIds: '["f2"]');
      final deleted = await AppDatabase.deleteFolderFrom(
          db, const Folder(id: 'f1', name: '试卷', subjectId: 'math'));
      expect(deleted, 3);
      expect(await db.query('questions'), isEmpty);
      expect(await db.query('folders'), isEmpty);
    });
  });

  group('§4.3 upsertCollectTask', () {
    test('多次更新不改变任务顺序、不改 rowid', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final t1 = DateTime.fromMillisecondsSinceEpoch(1000);
      final t2 = DateTime.fromMillisecondsSinceEpoch(2000);
      await AppDatabase.upsertCollectTaskInto(
          db,
          CollectTask(
              id: 'a',
              name: 'a',
              fileName: 'a.png',
              subjectId: 'math',
              createdAt: t1));
      await AppDatabase.upsertCollectTaskInto(
          db,
          CollectTask(
              id: 'b',
              name: 'b',
              fileName: 'b.png',
              subjectId: 'math',
              createdAt: t2));
      final rowidBefore = {
        for (final r in await db.query('collect_tasks', columns: ['id', 'rowid']))
          r['id'] as String: r['rowid'] as int,
      };
      expect(
          (await AppDatabase.allCollectTasksFrom(db))
              .map((t) => t.id)
              .toList(),
          ['b', 'a']);
      // 模拟导入进度高频更新：REPLACE 会把 a 顶到最上面，UPDATE 不会。
      for (var p = 10; p <= 90; p += 10) {
        await AppDatabase.upsertCollectTaskInto(
            db,
            CollectTask(
                id: 'a',
                name: 'a',
                fileName: 'a.png',
                subjectId: 'math',
                status: CollectStatus.importing,
                progress: p,
                createdAt: t1));
      }
      expect(
          (await AppDatabase.allCollectTasksFrom(db))
              .map((t) => t.id)
              .toList(),
          ['b', 'a']);
      final rowidAfter = {
        for (final r in await db.query('collect_tasks', columns: ['id', 'rowid']))
          r['id'] as String: r['rowid'] as int,
      };
      expect(rowidAfter, rowidBefore);
    });

    test('新建写 created_at；更新不改 created_at；同毫秒用 rowid 兜底',
        () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      // 不给 createdAt：新建时写当前时间。
      await AppDatabase.upsertCollectTaskInto(
          db,
          CollectTask(
              id: 'a', name: 'a', fileName: 'a.png', subjectId: 'math'));
      var tasks = await AppDatabase.allCollectTasksFrom(db);
      expect(tasks.single.createdAt, isNotNull);
      final created = tasks.single.createdAt!;
      await AppDatabase.upsertCollectTaskInto(
          db,
          CollectTask(
              id: 'a',
              name: 'a',
              fileName: 'a.png',
              subjectId: 'math',
              status: CollectStatus.done,
              progress: 100));
      tasks = await AppDatabase.allCollectTasksFrom(db);
      expect(tasks.single.createdAt, created);
      // 同毫秒建的两个任务：后插的 rowid 大，排前面。
      final same = DateTime.fromMillisecondsSinceEpoch(5000);
      await AppDatabase.upsertCollectTaskInto(
          db,
          CollectTask(
              id: 'c',
              name: 'c',
              fileName: 'c.png',
              subjectId: 'math',
              createdAt: same));
      await AppDatabase.upsertCollectTaskInto(
          db,
          CollectTask(
              id: 'd',
              name: 'd',
              fileName: 'd.png',
              subjectId: 'math',
              createdAt: same));
      tasks = await AppDatabase.allCollectTasksFrom(db);
      // a 的 created_at 是新建时刻（远大于 5000），排第一；c/d 同为
      // 5000 毫秒，后插的 d（rowid 大）排前面。
      expect(tasks.map((t) => t.id).toList(), ['a', 'd', 'c']);
    });
  });

  group('§4.5 级联清理（无孤儿行）', () {
    test('deleteQuestionFrom：清 review_history，任务指向置空、任务保留，队列去项',
        () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertQuestion(db, 'q1');
      await insertQuestion(db, 'q2');
      await insertCauseRecord(db, 'q1', '计算错误');
      await insertHistory(db, 'q1');
      await insertHistory(db, 'q2');
      await AppDatabase.upsertCollectTaskInto(
          db,
          CollectTask(
              id: 'ct1',
              name: 'ct1',
              fileName: 'x.png',
              subjectId: 'math',
              questionId: 'q1'));
      await db.insert('review_state', {
        'id': 1,
        'queue': '[{"q":"q1","c":"计算错误"},{"q":"q2","c":"概念不清"}]',
        'position': 0,
        'updated_at': 1,
      });
      await AppDatabase.deleteQuestionFrom(db, 'q1');
      expect(await db.query('questions'), hasLength(1));
      expect(await db.query('cause_records'), isEmpty);
      final history = await db.query('review_history');
      expect(history.map((r) => r['question_id']).toList(), ['q2']);
      final tasks = await db.query('collect_tasks');
      expect(tasks, hasLength(1));
      expect(tasks.single['question_id'], isNull);
      final state = await db.query('review_state');
      expect(state.single['queue'], '[{"q":"q2","c":"概念不清"}]');
    });

    test('deleteSubjectFrom：清该科 collect_tasks / review_history / recent_tasks，他科不动',
        () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await db.insert(
          'subjects', {'id': 'math', 'name': '数学', 'color': 0xFF000000});
      await db.insert(
          'subjects', {'id': 'english', 'name': '英语', 'color': 0xFF000000});
      await insertQuestion(db, 'q1', subjectId: 'math');
      await insertQuestion(db, 'q2', subjectId: 'english');
      await insertCauseRecord(db, 'q1', '计算错误');
      await insertHistory(db, 'q1');
      await insertHistory(db, 'q2');
      await AppDatabase.upsertCollectTaskInto(
          db,
          CollectTask(
              id: 'ct-math',
              name: 'm',
              fileName: 'm.png',
              subjectId: 'math'));
      await AppDatabase.upsertCollectTaskInto(
          db,
          CollectTask(
              id: 'ct-eng',
              name: 'e',
              fileName: 'e.png',
              subjectId: 'english'));
      await db.insert('recent_tasks', {
        'id': 1,
        'kind': '整理',
        'subject_id': 'math',
        'title': 't',
        'updated_at': 1,
      });
      await db.insert('folders', {
        'id': 'f1',
        'name': '试卷',
        'subject_id': 'math',
        'parent_id': null,
        'sort_order': 0,
      });
      await AppDatabase.deleteSubjectFrom(db, 'math');
      expect(
          (await db.query('subjects')).map((r) => r['id']).toList(),
          ['english']);
      expect(
          (await db.query('questions')).map((r) => r['id']).toList(),
          ['q2']);
      expect(await db.query('cause_records'), isEmpty);
      expect(
          (await db.query('review_history'))
              .map((r) => r['question_id'])
              .toList(),
          ['q2']);
      expect(
          (await db.query('collect_tasks')).map((r) => r['id']).toList(),
          ['ct-eng']);
      expect(await db.query('recent_tasks'), isEmpty);
      expect(await db.query('folders'), isEmpty);
    });

    test('clearDemoDataFrom：清演示复习历史与 recent_tasks，非演示不动',
        () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertQuestion(db, 'demo1', isDemo: 1);
      await insertQuestion(db, 'real1', isDemo: 0);
      await insertCauseRecord(db, 'demo1', '计算错误');
      await insertCauseRecord(db, 'real1', '概念不清');
      await insertHistory(db, 'demo1');
      await insertHistory(db, 'real1');
      await db.insert('recent_tasks', {
        'id': 1,
        'kind': '整理',
        'subject_id': 'math',
        'title': 't',
        'updated_at': 1,
      });
      await db.insert('review_state', {
        'id': 1,
        'queue': '[{"q":"demo1","c":"计算错误"}]',
        'position': 0,
        'updated_at': 1,
      });
      final n = await AppDatabase.clearDemoDataFrom(db);
      expect(n, 1);
      expect(
          (await db.query('questions')).map((r) => r['id']).toList(),
          ['real1']);
      expect(
          (await db.query('cause_records'))
              .map((r) => r['question_id'])
              .toList(),
          ['real1']);
      expect(
          (await db.query('review_history'))
              .map((r) => r['question_id'])
              .toList(),
          ['real1']);
      expect(await db.query('recent_tasks'), isEmpty);
      expect(await db.query('review_state'), isEmpty);
    });
  });
}
