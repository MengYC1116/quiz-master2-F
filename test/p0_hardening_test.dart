// P0 数据层加固（DB-CHANGE-PLAN.md §4.1–§4.5）回归测试。
// 全部用内存库（createTables 建表，不播种演示数据），不碰真实库；
// 只有 §4.1 一项走 AppDatabase.instance.db（验证并发只 open 一次），
// 此时 testDataDirectory 指向临时目录，单例在临时目录建全新 v2 库，
// 不碰真实数据目录；tearDown 用 resetForTest() 复位单例与重定向。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/models/models.dart';

Future<QuizDatabase> openTestDb() => AppDatabase.openForTest();

Future<void> insertQuestion(
  QuizDatabase db,
  String id, {
  String subjectId = 'math',
  int isDemo = 0,
  int reviewCount = 0,
  String folderIds = '',
}) async {
  await db.customInsert(
    'INSERT INTO questions (id, title, subject_id, folder_ids, created_at, '
    'is_demo, review_count) VALUES (?, ?, ?, ?, ?, ?, ?)',
    variables: [
      Variable.withString(id),
      Variable.withString('t-$id'),
      Variable.withString(subjectId),
      Variable.withString(folderIds),
      Variable.withInt(1000),
      Variable.withInt(isDemo),
      Variable.withInt(reviewCount),
    ],
  );
}

Future<void> insertCauseRecord(
  QuizDatabase db,
  String questionId,
  String cause, {
  String subjectId = 'math',
  String status = 'pending',
}) async {
  await db.customInsert(
    'INSERT INTO cause_records (question_id, cause, subject_id, status, '
    'solved_count, joined_at) VALUES (?, ?, ?, ?, ?, ?)',
    variables: [
      Variable.withString(questionId),
      Variable.withString(cause),
      Variable.withString(subjectId),
      Variable.withString(status),
      Variable.withInt(0),
      Variable.withInt(1000),
    ],
  );
}

Future<void> insertHistory(
  QuizDatabase db,
  String questionId, {
  String result = 'solved',
}) async {
  await db.customInsert(
    'INSERT INTO review_history (question_id, result, reviewed_at) '
    'VALUES (?, ?, ?)',
    variables: [
      Variable.withString(questionId),
      Variable.withString(result),
      Variable.withInt(1000),
    ],
  );
}

void main() {
  // 全文件：每个测试前把 testDataDirectory 指到 fresh 临时目录，
  // 任何落盘路径都不碰真实数据目录；测后 resetForTest() 复位单例
  // 与重定向并删临时目录。§4.1 以外各组只用内存库，本重定向是兜底。
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('p0-hardening-');
    AppDatabase.testDataDirectory = tmpDir.path;
    addTearDown(() async {
      await AppDatabase.resetForTest();
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    });
  });

  group('§4.1 db 缓存 Future', () {
    // 意图保留：并发 await instance.db 必须只触发一次 _openDb，
    // 返回同一 Database 对象。单例不预置（不用 useDatabaseForTest），
    // 否则缓存已命中、测不到打开路径；_openDb 在上面的临时目录
    // 建全新 v2 库，不碰真实库。
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
      await db.customUpdate(
        'UPDATE questions SET notes = ? WHERE id = ?',
        variables: [Variable.withString(notes), Variable.withString('q1')],
      );
      // 旧手写 _jsonValue 漏转 \r \t \b \f 与控制字符，导出的 JSON
      // 是非法的；jsonEncode 必须能导出且 jsonDecode 不抛错。
      final exported = await AppDatabase.exportBackupJsonFrom(db);
      final decoded = jsonDecode(exported) as Map<String, dynamic>;
      await AppDatabase.importBackupJsonInto(db, decoded);
      final rows = (await db.customSelect('SELECT * FROM questions').get())
          .map((r) => r.data)
          .toList();
      expect(rows, hasLength(1));
      expect(rows.first['notes'], notes);
    });
  });

  group('§4.2 事务', () {
    test('deleteSubjectFrom 中途失败：整科整体回滚', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await db.customInsert(
        'INSERT INTO subjects (id, name, color) VALUES (?, ?, ?)',
        variables: [
          Variable.withString('math'),
          Variable.withString('数学'),
          Variable.withInt(0xFF000000),
        ],
      );
      await insertQuestion(db, 'q1');
      await insertCauseRecord(db, 'q1', '计算错误');
      await db.customStatement(
        "CREATE TRIGGER trg_fail_qdel BEFORE DELETE ON questions "
        "BEGIN SELECT RAISE(ABORT, 'boom'); END;",
      );
      await expectLater(
        AppDatabase.deleteSubjectFrom(db, 'math'),
        throwsA(anything),
      );
      expect(
        await db.customSelect('SELECT * FROM subjects').get(),
        hasLength(1),
      );
      expect(
        await db.customSelect('SELECT * FROM questions').get(),
        hasLength(1),
      );
      expect(
        await db.customSelect('SELECT * FROM cause_records').get(),
        hasLength(1),
      );
    });

    test('deleteFolderFrom 中途失败：文件夹与题整体回滚', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await db.customInsert(
        'INSERT INTO folders (id, name, subject_id, parent_id, sort_order) '
        'VALUES (?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('f1'),
          Variable.withString('试卷'),
          Variable.withString('math'),
          const Variable<String>(null),
          Variable.withInt(0),
        ],
      );
      await insertQuestion(db, 'q1', folderIds: '["f1"]');
      await db.customStatement(
        "CREATE TRIGGER trg_fail_qdel BEFORE DELETE ON questions "
        "BEGIN SELECT RAISE(ABORT, 'boom'); END;",
      );
      await expectLater(
        AppDatabase.deleteFolderFrom(
          db,
          const Folder(id: 'f1', name: '试卷', subjectId: 'math'),
        ),
        throwsA(anything),
      );
      expect(
        await db.customSelect('SELECT * FROM folders').get(),
        hasLength(1),
      );
      expect(
        await db.customSelect('SELECT * FROM questions').get(),
        hasLength(1),
      );
    });

    test('deleteFolderFrom 成功：子文件夹递归、只挂多文件夹的题只移走关联', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await db.customInsert(
        'INSERT INTO folders (id, name, subject_id, parent_id, sort_order) '
        'VALUES (?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('f1'),
          Variable.withString('试卷'),
          Variable.withString('math'),
          const Variable<String>(null),
          Variable.withInt(0),
        ],
      );
      await db.customInsert(
        'INSERT INTO folders (id, name, subject_id, parent_id, sort_order) '
        'VALUES (?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('f2'),
          Variable.withString('子卷'),
          Variable.withString('math'),
          Variable.withString('f1'),
          Variable.withInt(0),
        ],
      );
      await insertQuestion(db, 'q1', folderIds: '["f1"]');
      await insertQuestion(db, 'q2', folderIds: '["f1","f2"]');
      await insertQuestion(db, 'q3', folderIds: '["f2"]');
      final deleted = await AppDatabase.deleteFolderFrom(
        db,
        const Folder(id: 'f1', name: '试卷', subjectId: 'math'),
      );
      expect(deleted, 3);
      expect(await db.customSelect('SELECT * FROM questions').get(), isEmpty);
      expect(await db.customSelect('SELECT * FROM folders').get(), isEmpty);
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
          createdAt: t1,
        ),
      );
      await AppDatabase.upsertCollectTaskInto(
        db,
        CollectTask(
          id: 'b',
          name: 'b',
          fileName: 'b.png',
          subjectId: 'math',
          createdAt: t2,
        ),
      );
      final rowidBefore = {
        for (final r
            in (await db
                    .customSelect('SELECT id, rowid FROM collect_tasks')
                    .get())
                .map((r) => r.data)
                .toList())
          r['id'] as String: r['rowid'] as int,
      };
      expect(
        (await AppDatabase.allCollectTasksFrom(db)).map((t) => t.id).toList(),
        ['b', 'a'],
      );
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
            createdAt: t1,
          ),
        );
      }
      expect(
        (await AppDatabase.allCollectTasksFrom(db)).map((t) => t.id).toList(),
        ['b', 'a'],
      );
      final rowidAfter = {
        for (final r
            in (await db
                    .customSelect('SELECT id, rowid FROM collect_tasks')
                    .get())
                .map((r) => r.data)
                .toList())
          r['id'] as String: r['rowid'] as int,
      };
      expect(rowidAfter, rowidBefore);
    });

    test('新建写 created_at；更新不改 created_at；同毫秒用 rowid 兜底', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      // 不给 createdAt：新建时写当前时间。
      await AppDatabase.upsertCollectTaskInto(
        db,
        CollectTask(id: 'a', name: 'a', fileName: 'a.png', subjectId: 'math'),
      );
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
          progress: 100,
        ),
      );
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
          createdAt: same,
        ),
      );
      await AppDatabase.upsertCollectTaskInto(
        db,
        CollectTask(
          id: 'd',
          name: 'd',
          fileName: 'd.png',
          subjectId: 'math',
          createdAt: same,
        ),
      );
      tasks = await AppDatabase.allCollectTasksFrom(db);
      // a 的 created_at 是新建时刻（远大于 5000），排第一；c/d 同为
      // 5000 毫秒，后插的 d（rowid 大）排前面。
      expect(tasks.map((t) => t.id).toList(), ['a', 'd', 'c']);
    });
  });

  group('§4.5 级联清理（无孤儿行）', () {
    test('deleteQuestionFrom：清 review_history，任务指向置空、任务保留，队列去项', () async {
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
          questionId: 'q1',
        ),
      );
      await db.customInsert(
        'INSERT INTO review_state (id, queue, position, updated_at) '
        'VALUES (?, ?, ?, ?)',
        variables: [
          Variable.withInt(1),
          Variable.withString('[{"q":"q1","c":"计算错误"},{"q":"q2","c":"概念不清"}]'),
          Variable.withInt(0),
          Variable.withInt(1),
        ],
      );
      await AppDatabase.deleteQuestionFrom(db, 'q1');
      expect(
        await db.customSelect('SELECT * FROM questions').get(),
        hasLength(1),
      );
      expect(
        await db.customSelect('SELECT * FROM cause_records').get(),
        isEmpty,
      );
      final history =
          (await db.customSelect('SELECT * FROM review_history').get())
              .map((r) => r.data)
              .toList();
      expect(history.map((r) => r['question_id']).toList(), ['q2']);
      final tasks = (await db.customSelect('SELECT * FROM collect_tasks').get())
          .map((r) => r.data)
          .toList();
      expect(tasks, hasLength(1));
      expect(tasks.single['question_id'], isNull);
      final state = (await db.customSelect('SELECT * FROM review_state').get())
          .map((r) => r.data)
          .toList();
      expect(state.single['queue'], '[{"q":"q2","c":"概念不清"}]');
    });

    test('deleteSubjectFrom：清该科 collect_tasks / review_history / recent_tasks，他科不动', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await db.customInsert(
        'INSERT INTO subjects (id, name, color) VALUES (?, ?, ?)',
        variables: [
          Variable.withString('math'),
          Variable.withString('数学'),
          Variable.withInt(0xFF000000),
        ],
      );
      await db.customInsert(
        'INSERT INTO subjects (id, name, color) VALUES (?, ?, ?)',
        variables: [
          Variable.withString('english'),
          Variable.withString('英语'),
          Variable.withInt(0xFF000000),
        ],
      );
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
          subjectId: 'math',
        ),
      );
      await AppDatabase.upsertCollectTaskInto(
        db,
        CollectTask(
          id: 'ct-eng',
          name: 'e',
          fileName: 'e.png',
          subjectId: 'english',
        ),
      );
      await db.customInsert(
        'INSERT INTO recent_tasks (id, kind, subject_id, title, updated_at) '
        'VALUES (?, ?, ?, ?, ?)',
        variables: [
          Variable.withInt(1),
          Variable.withString('整理'),
          Variable.withString('math'),
          Variable.withString('t'),
          Variable.withInt(1),
        ],
      );
      await db.customInsert(
        'INSERT INTO folders (id, name, subject_id, parent_id, sort_order) '
        'VALUES (?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('f1'),
          Variable.withString('试卷'),
          Variable.withString('math'),
          const Variable<String>(null),
          Variable.withInt(0),
        ],
      );
      await AppDatabase.deleteSubjectFrom(db, 'math');
      expect(
        (await db.customSelect('SELECT * FROM subjects').get())
            .map((r) => r.data['id'])
            .toList(),
        ['english'],
      );
      expect(
        (await db.customSelect('SELECT * FROM questions').get())
            .map((r) => r.data['id'])
            .toList(),
        ['q2'],
      );
      expect(
        await db.customSelect('SELECT * FROM cause_records').get(),
        isEmpty,
      );
      expect(
        (await db.customSelect('SELECT * FROM review_history').get())
            .map((r) => r.data['question_id'])
            .toList(),
        ['q2'],
      );
      expect(
        (await db.customSelect('SELECT * FROM collect_tasks').get())
            .map((r) => r.data['id'])
            .toList(),
        ['ct-eng'],
      );
      expect(
        await db.customSelect('SELECT * FROM recent_tasks').get(),
        isEmpty,
      );
      expect(await db.customSelect('SELECT * FROM folders').get(), isEmpty);
    });
  });
}
