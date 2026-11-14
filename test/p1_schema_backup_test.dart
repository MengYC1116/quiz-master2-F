// P1（§2 / §1.2 / §8）：删老库建 v2 新库 + 备份版本字段 + schema 结构。
// 全部用临时目录 / 内存库，不碰真实用户库（§8.1）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> openMemoryDb() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, version) async =>
              AppDatabase.createTables(db)));
  addTearDown(() async => db.close());
  return db;
}

/// 经 AppDatabase.openAt 打开的临时文件库（走 _onCreate 全量播种）。
Future<(Directory, Database, String)> openTempDb() async {
  sqfliteFfiInit();
  final tmp = await Directory.systemTemp.createTemp('p1-schema-');
  final dbPath = p.join(tmp.path, 'quiz-master2.db');
  final db = await AppDatabase.openAt(dbPath);
  addTearDown(() async {
    try {
      await db.close();
    } catch (_) {}
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });
  return (tmp, db, dbPath);
}

Future<Map<String, Object?>> tableSql(
    Database db, String table) async {
  final rows = await db.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
      [table]);
  return rows.first;
}

Future<List<Map<String, Object?>>> indexesOf(
    Database db, String table) async {
  return db.rawQuery(
      "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ?",
      [table]);
}

Question testQuestion({
  String id = 'q1',
  String subjectId = 'math',
}) =>
    Question(
      id: id,
      title: '测试题',
      subjectId: subjectId,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      sourcePath: 'imports/task-1/original.png',
      sourceKind: 'image',
      sourcePage: 1,
      pageImagePath: 'imports/task-1/original.png',
      slicePath: 'slices/q1.png',
      sliceWidth: 800,
      sliceHeight: 600,
    );

QuestionBox testBox({
  String id = 'box-task-1-p1-a1b2c3d4',
  String? collectTaskId,
  String? questionId,
  String? parentBoxId,
  int layer = 1,
  String type = 'question',
  double x = 0.1,
  double y = 0.1,
  double w = 0.8,
  double h = 0.2,
  double? confidence,
  String origin = 'manual',
  int page = 1,
}) =>
    QuestionBox(
      id: id,
      collectTaskId: collectTaskId,
      questionId: questionId,
      parentBoxId: parentBoxId,
      layer: layer,
      type: type,
      x: x,
      y: y,
      w: w,
      h: h,
      confidence: confidence,
      origin: origin,
      page: page,
    );

void main() {
  group('P1 §8.1 schema 结构：_onCreate 建出的结构与 §1.2 DDL 一致', () {
    test('questions 表含 §1.2(a) 的 7 列', () async {
      final db = await openMemoryDb();
      final cols = await db.rawQuery('PRAGMA table_info(questions)');
      final byName = {
        for (final c in cols) c['name'] as String: c,
      };
      for (final entry in {
        'source_path': 'TEXT',
        'source_kind': 'TEXT',
        'source_page': 'INTEGER',
        'page_image_path': 'TEXT',
        'slice_path': 'TEXT',
        'slice_width': 'INTEGER',
        'slice_height': 'INTEGER',
      }.entries) {
        expect(byName, contains(entry.key),
            reason: 'questions 缺列 ${entry.key}');
        expect(byName[entry.key]!['type'], entry.value);
      }
      // 7 列全部可空（notnull == 0）。
      for (final name in [
        'source_path',
        'source_kind',
        'source_page',
        'page_image_path',
        'slice_path',
        'slice_width',
        'slice_height',
      ]) {
        expect(byName[name]!['notnull'], 0, reason: '$name 应可空');
      }
      // slice_kind / slice_text 保留（最小改动，不删列）。
      expect(byName, contains('slice_kind'));
      expect(byName, contains('slice_text'));
    });

    test('collect_tasks 表含 source_path / created_at / page_rotations',
        () async {
      final db = await openMemoryDb();
      final cols = await db.rawQuery('PRAGMA table_info(collect_tasks)');
      final byName = {
        for (final c in cols) c['name'] as String: c,
      };
      expect(byName['source_path']!['type'], 'TEXT');
      expect(byName['source_path']!['notnull'], 1);
      expect(byName['source_path']!['dflt_value'], "''");
      expect(byName['created_at']!['type'], 'INTEGER');
      expect(byName['created_at']!['notnull'], 1);
      expect(byName['page_rotations']!['type'], 'TEXT');
      expect(byName['page_rotations']!['notnull'], 1);
      expect(byName['page_rotations']!['dflt_value'], "'{}'");
    });

    test('question_boxes 表：列 + CHECK + 4 个索引', () async {
      final db = await openMemoryDb();
      final cols = await db.rawQuery('PRAGMA table_info(question_boxes)');
      final byName = {
        for (final c in cols) c['name'] as String: c,
      };
      for (final name in [
        'id',
        'collect_task_id',
        'question_id',
        'parent_box_id',
        'page',
        'layer',
        'type',
        'x',
        'y',
        'w',
        'h',
        'confidence',
        'origin',
        'updated_at',
      ]) {
        expect(byName, contains(name), reason: 'question_boxes 缺列 $name');
      }
      // collect_task_id 可空（修框草稿归属；确认后只保留 question_id）。
      expect(byName['collect_task_id']!['notnull'], 0);
      expect(byName['origin']!['dflt_value'], "'manual'");
      final sql = (await tableSql(db, 'question_boxes'))['sql'] as String;
      expect(sql, contains('CHECK (page >= 1)'));
      expect(sql, contains('CHECK (layer IN (1, 2))'));
      expect(
          sql, contains("CHECK (type IN ('question', 'stem', 'option', 'figure'))"));
      expect(sql, contains('CHECK (x >= 0 AND x <= 1)'));
      expect(sql, contains('CHECK (y >= 0 AND y <= 1)'));
      expect(sql, contains('CHECK (w >= 0 AND w <= 1)'));
      expect(sql, contains('CHECK (h >= 0 AND h <= 1)'));
      expect(
          sql,
          contains(
              'CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1))'));
      expect(sql, contains("CHECK (origin IN ('yolo', 'manual'))"));

      final indexes = indexesOf(db, 'question_boxes');
      final idx = await indexes;
      final byIdxName = {for (final i in idx) i['name'] as String: i};
      expect(byIdxName, contains('idx_boxes_task_page'));
      expect(byIdxName, contains('idx_boxes_question'));
      expect(byIdxName, contains('idx_boxes_parent'));
      expect(byIdxName, contains('idx_boxes_one_layer1_per_question'));
      // partial unique index：只约束已确认题的 layer = 1 框。
      expect(byIdxName['idx_boxes_one_layer1_per_question']!['sql'] as String,
          contains('WHERE layer = 1 AND question_id IS NOT NULL'));
    });

    test('CHECK 约束生效：越界坐标 / 非法 layer / 越界置信度拒绝写入',
        () async {
      final db = await openMemoryDb();
      await expectLater(
          () => AppDatabase.insertQuestionBoxInto(
              db, testBox(x: 1.5)),
          throwsA(isA<DatabaseException>()));
      await expectLater(
          () => AppDatabase.insertQuestionBoxInto(
              db, testBox(id: 'box-bad-layer', layer: 3)),
          throwsA(isA<DatabaseException>()));
      await expectLater(
          () => AppDatabase.insertQuestionBoxInto(
              db, testBox(id: 'box-bad-conf', confidence: 2.0)),
          throwsA(isA<DatabaseException>()));
      await expectLater(
          () => AppDatabase.insertQuestionBoxInto(
              db, testBox(id: 'box-bad-origin', origin: 'auto')),
          throwsA(isA<DatabaseException>()));
      await expectLater(
          () => AppDatabase.insertQuestionBoxInto(
              db, testBox(id: 'box-bad-page', page: 0)),
          throwsA(isA<DatabaseException>()));
    });

    test('partial unique：一题只能有一个 layer = 1 整题框', () async {
      final db = await openMemoryDb();
      await AppDatabase.insertQuestionBoxInto(
          db, testBox(questionId: 'q1'));
      // 同题第二个 layer = 1 框拒绝。
      await expectLater(
          () => AppDatabase.insertQuestionBoxInto(
              db, testBox(id: 'box-second', questionId: 'q1')),
          throwsA(isA<DatabaseException>()));
      // 修框中的框（question_id 为 NULL）不受限。
      await AppDatabase.insertQuestionBoxInto(db,
          testBox(id: 'box-draft-1', collectTaskId: 'task-1'));
      await AppDatabase.insertQuestionBoxInto(db,
          testBox(id: 'box-draft-2', collectTaskId: 'task-1'));
      // 同题的 layer = 2 框不受限。
      await AppDatabase.insertQuestionBoxInto(
          db,
          testBox(
              id: 'box-inner',
              questionId: 'q1',
              parentBoxId: 'box-task-1-p1-a1b2c3d4',
              layer: 2,
              type: 'stem'));
    });
  });

  group('P1 §2.2 删老库建新库', () {
    test('老 v1 库文件删除（含 -wal / -shm），新库从空开始、无演示题',
        () async {
      sqfliteFfiInit();
      final tmp = await Directory.systemTemp.createTemp('p1-legacy-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = p.join(tmp.path, 'quiz-master2.db');
      // 造一个 v1 库：version 1 + 一张旧表 + 一行旧数据。
      final legacy = await databaseFactoryFfi.openDatabase(dbPath,
          options: OpenDatabaseOptions(
              version: 1,
              onCreate: (db, version) async {
                await db.execute(
                    'CREATE TABLE legacy_marker(id TEXT PRIMARY KEY)');
                await db.insert('legacy_marker', {'id': 'old-row'});
              }));
      await legacy.close();
      // 残留的 -wal / -shm 也应随老库一起删。
      await File('$dbPath-wal').writeAsString('wal-bytes');
      await File('$dbPath-shm').writeAsString('shm-bytes');

      expect(await AppDatabase.deleteLegacyDatabaseIfPresent(dbPath),
          isTrue);
      expect(File(dbPath).existsSync(), isFalse);
      expect(File('$dbPath-wal').existsSync(), isFalse);
      expect(File('$dbPath-shm').existsSync(), isFalse);

      final db = await AppDatabase.openAt(dbPath);
      addTearDown(() async => db.close());
      expect(await db.getVersion(), 2);
      // 旧表没了，新库从空开始。
      final tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'");
      expect(tables.map((r) => r['name']), isNot(contains('legacy_marker')));
      expect(await db.query('questions'), isEmpty);
      expect(await db.rawQuery(
          'SELECT COUNT(*) AS n FROM questions WHERE is_demo = 1'),
          [
            {'n': 0}
          ]);
      // 产品预置项仍在（学科/文件夹/标签/知识点树，不是演示数据）。
      expect(await db.query('subjects'), hasLength(3));
      expect(await db.query('folders'), hasLength(9));
      // settings.schemaVersion 写回 2。
      final settings = await db.query('settings',
          where: 'key = ?', whereArgs: ['schemaVersion']);
      expect(settings.single['value'], '2');
    });

    test('已是 v2 的库不删：再次打开数据还在', () async {
      final (tmp, db, dbPath) = await openTempDb();
      await AppDatabase.upsertQuestionInto(db, testQuestion());
      await db.close();
      expect(await AppDatabase.deleteLegacyDatabaseIfPresent(dbPath),
          isFalse);
      final reopened = await AppDatabase.openAt(dbPath);
      addTearDown(() async => reopened.close());
      expect(await AppDatabase.allQuestionsFrom(reopened), hasLength(1));
      expect(await reopened.getVersion(), 2);
      expect(tmp.existsSync(), isTrue);
    });

    test('不存在的库文件：直接建 v2 新库，不报错', () async {
      sqfliteFfiInit();
      final tmp = await Directory.systemTemp.createTemp('p1-fresh-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = p.join(tmp.path, 'quiz-master2.db');
      expect(await AppDatabase.deleteLegacyDatabaseIfPresent(dbPath),
          isFalse);
      final db = await AppDatabase.openAt(dbPath);
      addTearDown(() async => db.close());
      expect(await db.getVersion(), 2);
      expect(await db.query('questions'), isEmpty);
    });
  });

  group('P1 §1.2 模型字段往返', () {
    test('Question 新列：source/path/slice 字段写读一致', () async {
      final db = await openMemoryDb();
      await AppDatabase.upsertQuestionInto(db, testQuestion());
      final back = await AppDatabase.allQuestionsFrom(db);
      expect(back, hasLength(1));
      final q = back.single;
      expect(q.sourcePath, 'imports/task-1/original.png');
      expect(q.sourceKind, 'image');
      expect(q.sourcePage, 1);
      expect(q.pageImagePath, 'imports/task-1/original.png');
      expect(q.slicePath, 'slices/q1.png');
      expect(q.sliceWidth, 800);
      expect(q.sliceHeight, 600);
      // 无图的新题：新列全空。
      await AppDatabase.upsertQuestionInto(
          db,
          Question(
              id: 'q2',
              title: '无图题',
              subjectId: 'math',
              createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000001)));
      final q2 = (await AppDatabase.allQuestionsFrom(db))
          .firstWhere((e) => e.id == 'q2');
      expect(q2.sourcePath, isNull);
      expect(q2.slicePath, isNull);
    });

    test('QuestionBox 行转换：confidence/origin/parent/page/归属一致',
        () async {
      final db = await openMemoryDb();
      await AppDatabase.insertQuestionBoxInto(
          db,
          testBox(
              collectTaskId: 'task-1',
              confidence: 0.93,
              origin: 'yolo'));
      await AppDatabase.insertQuestionBoxInto(
          db,
          testBox(
              id: 'box-inner-1',
              layer: 2,
              type: 'stem',
              parentBoxId: 'box-task-1-p1-a1b2c3d4',
              questionId: 'q1',
              collectTaskId: null));
      final boxes = await AppDatabase.boxesForQuestionFrom(db, 'q1');
      expect(boxes, hasLength(1));
      expect(boxes.single.parentBoxId, 'box-task-1-p1-a1b2c3d4');
      expect(boxes.single.layer, 2);
      final drafts = await db.query('question_boxes',
          where: 'collect_task_id = ?', whereArgs: ['task-1']);
      expect(drafts.single['confidence'], 0.93);
      expect(drafts.single['origin'], 'yolo');
    });

    test('CollectTask：source_path / page_rotations 写读一致', () async {
      final db = await openMemoryDb();
      final task = CollectTask(
        id: 'task-1',
        name: 'paper.png',
        fileName: 'paper.png',
        subjectId: 'math',
        sourcePath: 'imports/task-1/original.png',
        pageRotations: {1: 90, 2: 0},
        createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      await AppDatabase.upsertCollectTaskInto(db, task);
      final back = await AppDatabase.allCollectTasksFrom(db);
      expect(back.single.sourcePath, 'imports/task-1/original.png');
      expect(back.single.pageRotations, {1: 90, 2: 0});
      expect(back.single.createdAt?.millisecondsSinceEpoch, 1700000000000);
      // fileName 只做显示名，与 source_path 分离。
      expect(back.single.fileName, 'paper.png');
    });

    test('删题级联：该题的框（含子框）随题删', () async {
      final db = await openMemoryDb();
      await AppDatabase.upsertQuestionInto(db, testQuestion());
      await AppDatabase.insertQuestionBoxInto(
          db, testBox(questionId: 'q1'));
      await AppDatabase.insertQuestionBoxInto(
          db,
          testBox(
              id: 'box-child',
              questionId: 'q1',
              parentBoxId: 'box-task-1-p1-a1b2c3d4',
              layer: 2,
              type: 'stem'));
      await AppDatabase.deleteQuestionFrom(db, 'q1');
      expect(await db.query('question_boxes'), isEmpty);
      expect(await db.query('questions'), isEmpty);
    });

    test('删任务：只删未确认的草稿框，已确认的框随题保留', () async {
      final db = await openMemoryDb();
      await AppDatabase.upsertQuestionInto(db, testQuestion());
      await AppDatabase.upsertCollectTaskInto(
          db,
          CollectTask(
              id: 'task-1',
              name: 'paper.png',
              fileName: 'paper.png',
              subjectId: 'math'));
      await AppDatabase.insertQuestionBoxInto(
          db, testBox(id: 'box-draft', collectTaskId: 'task-1'));
      await AppDatabase.insertQuestionBoxInto(
          db,
          testBox(
              id: 'box-confirmed',
              collectTaskId: 'task-1',
              questionId: 'q1'));
      await AppDatabase.deleteCollectTaskFrom(db, 'task-1');
      expect(await db.query('collect_tasks'), isEmpty);
      final remaining = await db.query('question_boxes');
      expect(remaining.map((r) => r['id']), ['box-confirmed']);
    });
  });

  group('P1 §2.3 v2 备份恢复', () {
    Future<Map<String, dynamic>> seedAndExport(Database db) async {
      await AppDatabase.upsertQuestionInto(db, testQuestion());
      await AppDatabase.insertQuestionBoxInto(
          db, testBox(questionId: 'q1', confidence: 0.9, origin: 'yolo'));
      await AppDatabase.upsertCollectTaskInto(
          db,
          CollectTask(
              id: 'task-1',
              name: 'paper.png',
              fileName: 'paper.png',
              subjectId: 'math',
              sourcePath: 'imports/task-1/original.png',
              pageRotations: {1: 90},
              createdAt:
                  DateTime.fromMillisecondsSinceEpoch(1700000000000)));
      final exported = await AppDatabase.exportBackupJsonFrom(db);
      return jsonDecode(exported) as Map<String, dynamic>;
    }

    test('导出：平铺表名 + _meta，13 张表', () async {
      final db = await openMemoryDb();
      final decoded = await seedAndExport(db);
      final meta = decoded['_meta'] as Map<String, dynamic>;
      expect(meta['schemaVersion'], 2);
      expect(meta['appVersion'], AppDatabase.appVersion);
      expect(meta['exportedAt'], isA<int>());
      expect(AppDatabase.backupTables.length, 13);
      expect(AppDatabase.backupTables, contains('question_boxes'));
      for (final t in AppDatabase.backupTables) {
        expect(decoded, contains(t), reason: '导出缺表 $t');
      }
      expect((decoded['question_boxes'] as List), hasLength(1));
      expect((decoded['questions'] as List).single['slice_path'],
          'slices/q1.png');
      expect(
          (decoded['collect_tasks'] as List).single['page_rotations'],
          '{"1":90}');
    });

    test('备份 → 清空 → 恢复：题/框/任务回来，schemaVersion 写回 2',
        () async {
      final db = await openMemoryDb();
      final decoded = await seedAndExport(db);
      await db.delete('questions');
      await db.delete('question_boxes');
      await db.delete('collect_tasks');
      await db.delete('settings');
      expect(await db.query('questions'), isEmpty);
      await AppDatabase.importBackupJsonInto(db, decoded);
      final qs = await AppDatabase.allQuestionsFrom(db);
      expect(qs.single.slicePath, 'slices/q1.png');
      expect(qs.single.sourcePath, 'imports/task-1/original.png');
      final boxes = await AppDatabase.boxesForQuestionFrom(db, 'q1');
      expect(boxes.single.origin, 'yolo');
      expect(boxes.single.confidence, 0.9);
      final tasks = await AppDatabase.allCollectTasksFrom(db);
      expect(tasks.single.pageRotations, {1: 90});
      final settings = await db.query('settings',
          where: 'key = ?', whereArgs: ['schemaVersion']);
      expect(settings.single['value'], '2');
    });

    test('schemaVersion > 2：拒绝恢复，原库一动不动', () async {
      final db = await openMemoryDb();
      final decoded = await seedAndExport(db);
      (decoded['_meta'] as Map<String, dynamic>)['schemaVersion'] = 3;
      await expectLater(() => AppDatabase.importBackupJsonInto(db, decoded),
          throwsA(isA<BackupRestoreException>().having(
              (e) => e.message, 'message', contains('更新的版本'))));
      // 原库不动：题、框、任务都在。
      expect(await AppDatabase.allQuestionsFrom(db), hasLength(1));
      expect(await db.query('question_boxes'), hasLength(1));
      expect(await AppDatabase.allCollectTasksFrom(db), hasLength(1));
    });

    test('_meta 缺失（v1 备份）：拒绝恢复，原库一动不动', () async {
      final db = await openMemoryDb();
      final decoded = await seedAndExport(db);
      decoded.remove('_meta');
      await expectLater(() => AppDatabase.importBackupJsonInto(db, decoded),
          throwsA(isA<BackupRestoreException>().having(
              (e) => e.message, 'message', contains('v1'))));
      expect(await AppDatabase.allQuestionsFrom(db), hasLength(1));
      expect(await db.query('question_boxes'), hasLength(1));
    });

    test('schemaVersion 不是 2（=1 / 非整数）：拒绝恢复', () async {
      final db = await openMemoryDb();
      final decoded = await seedAndExport(db);
      (decoded['_meta'] as Map<String, dynamic>)['schemaVersion'] = 1;
      await expectLater(() => AppDatabase.importBackupJsonInto(db, decoded),
          throwsA(isA<BackupRestoreException>()));
      final decoded2 =
          jsonDecode(jsonEncode(decoded)) as Map<String, dynamic>;
      (decoded2['_meta'] as Map<String, dynamic>)['schemaVersion'] = '2';
      await expectLater(
          () => AppDatabase.importBackupJsonInto(db, decoded2),
          throwsA(isA<BackupRestoreException>()));
      expect(await AppDatabase.allQuestionsFrom(db), hasLength(1));
    });

    test('关键表不全 / 行不合法：拒绝恢复，原库一动不动', () async {
      final db = await openMemoryDb();
      final decoded = await seedAndExport(db);
      final noQuestions = Map<String, dynamic>.from(decoded)
        ..remove('questions');
      await expectLater(
          () => AppDatabase.importBackupJsonInto(db, noQuestions),
          throwsA(isA<BackupRestoreException>()));
      final badRow = Map<String, dynamic>.from(decoded)
        ..['questions'] = [
          {'title': '缺主键的行'}
        ];
      await expectLater(() => AppDatabase.importBackupJsonInto(db, badRow),
          throwsA(isA<BackupRestoreException>()));
      final notList = Map<String, dynamic>.from(decoded)
        ..['subjects'] = {'not': 'a-list'};
      await expectLater(
          () => AppDatabase.importBackupJsonInto(db, notList),
          throwsA(isA<BackupRestoreException>()));
      expect(await AppDatabase.allQuestionsFrom(db), hasLength(1));
    });

    test('缺表键的备份恢复不崩：缺的表被清空，其余表恢复', () async {
      final db = await openMemoryDb();
      final decoded = await seedAndExport(db);
      decoded.remove('collect_tasks');
      decoded.remove('review_state');
      await AppDatabase.importBackupJsonInto(db, decoded);
      expect(await AppDatabase.allCollectTasksFrom(db), isEmpty);
      expect(await AppDatabase.allQuestionsFrom(db), hasLength(1));
    });
  });
}
