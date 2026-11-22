// P1（§2 / §1.2 / §8）：删老库建 v4 新库 + 备份版本字段 + schema 结构。
// 十二批 D-91：v3（新表 recently_viewed_questions + collect_tasks
// 新增 source_hash 列；v2 库走 Drift 迁移到 v3，不再删除；v2 备份
// 仍可恢复、迁移进 v3）。
// 十三批 M2：v4（questions 加 5 个 OCR 列 + 新表 ocr_jobs；v2/v3 库
// 走 Drift 迁移到 v4，v2/v3 备份仍可恢复、迁移进 v4）。
// 全部用临时目录 / 内存库，不碰真实用户库（§8.1）。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

Future<QuizDatabase> openMemoryDb() async {
  final db = await AppDatabase.openForTest();
  addTearDown(() async => db.close());
  return db;
}

/// 经 AppDatabase.openAt 打开的临时文件库（走 _onCreate 全量播种）。
Future<(Directory, QuizDatabase, String)> openTempDb() async {
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

Future<Map<String, Object?>> tableSql(QuizDatabase db, String table) async {
  final rows =
      (await db
              .customSelect(
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
                variables: [Variable.withString(table)],
              )
              .get())
          .map((r) => r.data)
          .toList();
  return rows.first;
}

Future<List<Map<String, Object?>>> indexesOf(
  QuizDatabase db,
  String table,
) async {
  return (await db
          .customSelect(
            "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ?",
            variables: [Variable.withString(table)],
          )
          .get())
      .map((r) => r.data)
      .toList();
}

/// 读库文件 user_version（旧 `db.getVersion()` 的等价口径）。
Future<int> dbVersion(QuizDatabase db) async =>
    (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
      'user_version',
    );

Question testQuestion({
  String id = 'q1',
  String subjectId = 'math',
  bool isOrganized = false,
}) => Question(
  id: id,
  title: '测试题',
  subjectId: subjectId,
  isOrganized: isOrganized,
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
}) => QuestionBox(
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
      final cols = (await db.customSelect('PRAGMA table_info(questions)').get())
          .map((r) => r.data)
          .toList();
      final byName = {for (final c in cols) c['name'] as String: c};
      for (final entry in {
        'source_path': 'TEXT',
        'source_kind': 'TEXT',
        'source_page': 'INTEGER',
        'page_image_path': 'TEXT',
        'slice_path': 'TEXT',
        'slice_width': 'INTEGER',
        'slice_height': 'INTEGER',
      }.entries) {
        expect(
          byName,
          contains(entry.key),
          reason: 'questions 缺列 ${entry.key}',
        );
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

    test(
      'collect_tasks 表含 source_path / created_at / page_rotations',
      () async {
        final db = await openMemoryDb();
        final cols =
            (await db.customSelect('PRAGMA table_info(collect_tasks)').get())
                .map((r) => r.data)
                .toList();
        final byName = {for (final c in cols) c['name'] as String: c};
        expect(byName['source_path']!['type'], 'TEXT');
        expect(byName['source_path']!['notnull'], 1);
        expect(byName['source_path']!['dflt_value'], "''");
        expect(byName['created_at']!['type'], 'INTEGER');
        expect(byName['created_at']!['notnull'], 1);
        expect(byName['page_rotations']!['type'], 'TEXT');
        expect(byName['page_rotations']!['notnull'], 1);
        expect(byName['page_rotations']!['dflt_value'], "'{}'");
      },
    );

    test('question_boxes 表：列 + CHECK + 4 个索引', () async {
      final db = await openMemoryDb();
      final cols =
          (await db.customSelect('PRAGMA table_info(question_boxes)').get())
              .map((r) => r.data)
              .toList();
      final byName = {for (final c in cols) c['name'] as String: c};
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
        sql,
        contains("CHECK (type IN ('question', 'stem', 'option', 'figure'))"),
      );
      expect(sql, contains('CHECK (x >= 0 AND x <= 1)'));
      expect(sql, contains('CHECK (y >= 0 AND y <= 1)'));
      expect(sql, contains('CHECK (w >= 0 AND w <= 1)'));
      expect(sql, contains('CHECK (h >= 0 AND h <= 1)'));
      expect(
        sql,
        contains(
          'CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1))',
        ),
      );
      expect(sql, contains("CHECK (origin IN ('yolo', 'manual'))"));

      final indexes = indexesOf(db, 'question_boxes');
      final idx = await indexes;
      final byIdxName = {for (final i in idx) i['name'] as String: i};
      expect(byIdxName, contains('idx_boxes_task_page'));
      expect(byIdxName, contains('idx_boxes_question'));
      expect(byIdxName, contains('idx_boxes_parent'));
      expect(byIdxName, contains('idx_boxes_one_layer1_per_question'));
      // partial unique index：只约束已确认题的 layer = 1 框。
      expect(
        byIdxName['idx_boxes_one_layer1_per_question']!['sql'] as String,
        contains('WHERE layer = 1 AND question_id IS NOT NULL'),
      );
    });

    test('CHECK 约束生效：越界坐标 / 非法 layer / 越界置信度拒绝写入', () async {
      final db = await openMemoryDb();
      await expectLater(
        () => AppDatabase.insertQuestionBoxInto(db, testBox(x: 1.5)),
        throwsA(isA<sqlite3.SqliteException>()),
      );
      await expectLater(
        () => AppDatabase.insertQuestionBoxInto(
          db,
          testBox(id: 'box-bad-layer', layer: 3),
        ),
        throwsA(isA<sqlite3.SqliteException>()),
      );
      await expectLater(
        () => AppDatabase.insertQuestionBoxInto(
          db,
          testBox(id: 'box-bad-conf', confidence: 2.0),
        ),
        throwsA(isA<sqlite3.SqliteException>()),
      );
      await expectLater(
        () => AppDatabase.insertQuestionBoxInto(
          db,
          testBox(id: 'box-bad-origin', origin: 'auto'),
        ),
        throwsA(isA<sqlite3.SqliteException>()),
      );
      await expectLater(
        () => AppDatabase.insertQuestionBoxInto(
          db,
          testBox(id: 'box-bad-page', page: 0),
        ),
        throwsA(isA<sqlite3.SqliteException>()),
      );
    });

    test('partial unique：一题只能有一个 layer = 1 整题框', () async {
      final db = await openMemoryDb();
      await AppDatabase.insertQuestionBoxInto(db, testBox(questionId: 'q1'));
      // 同题第二个 layer = 1 框拒绝。
      await expectLater(
        () => AppDatabase.insertQuestionBoxInto(
          db,
          testBox(id: 'box-second', questionId: 'q1'),
        ),
        throwsA(isA<sqlite3.SqliteException>()),
      );
      // 修框中的框（question_id 为 NULL）不受限。
      await AppDatabase.insertQuestionBoxInto(
        db,
        testBox(id: 'box-draft-1', collectTaskId: 'task-1'),
      );
      await AppDatabase.insertQuestionBoxInto(
        db,
        testBox(id: 'box-draft-2', collectTaskId: 'task-1'),
      );
      // 同题的 layer = 2 框不受限。
      await AppDatabase.insertQuestionBoxInto(
        db,
        testBox(
          id: 'box-inner',
          questionId: 'q1',
          parentBoxId: 'box-task-1-p1-a1b2c3d4',
          layer: 2,
          type: 'stem',
        ),
      );
    });
  });

  group('P1 §2.2 删老库建新库', () {
    test('老 v1 库文件删除（含 -wal / -shm），新库从空开始、无演示题', () async {
      final tmp = await Directory.systemTemp.createTemp('p1-legacy-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = p.join(tmp.path, 'quiz-master2.db');
      // 造一个 v1 库：user_version 1 + 一张旧表 + 一行旧数据。
      // （旧写法走 sqflite openDatabase version: 1；新写法直接用
      // sqlite3 建文件——探针只认 user_version，不认驱动。）
      final legacy = sqlite3.sqlite3.open(dbPath);
      legacy.execute('CREATE TABLE legacy_marker(id TEXT PRIMARY KEY)');
      legacy.execute("INSERT INTO legacy_marker VALUES ('old-row')");
      legacy.execute('PRAGMA user_version = 1');
      legacy.close();
      // 残留的 -wal / -shm 也应随老库一起删。
      await File('$dbPath-wal').writeAsString('wal-bytes');
      await File('$dbPath-shm').writeAsString('shm-bytes');

      expect(await AppDatabase.deleteLegacyDatabaseIfPresent(dbPath), isTrue);
      expect(File(dbPath).existsSync(), isFalse);
      expect(File('$dbPath-wal').existsSync(), isFalse);
      expect(File('$dbPath-shm').existsSync(), isFalse);

      final db = await AppDatabase.openAt(dbPath);
      addTearDown(() async => db.close());
      expect(await dbVersion(db), 7);
      // 旧表没了，新库从空开始。
      final tables =
          (await db
                  .customSelect(
                    "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
                  )
                  .get())
              .map((r) => r.data)
              .toList();
      expect(tables.map((r) => r['name']), isNot(contains('legacy_marker')));
      expect(await db.customSelect('SELECT * FROM questions').get(), isEmpty);
      expect(
        (await db
                .customSelect(
                  'SELECT COUNT(*) AS n FROM questions WHERE is_demo = 1',
                )
                .get())
            .map((r) => r.data)
            .toList(),
        [
          {'n': 0},
        ],
      );
      // 产品预置项仍在（学科/文件夹/标签/知识点树，不是演示数据）。
      expect(
        await db.customSelect('SELECT * FROM subjects').get(),
        hasLength(3),
      );
      expect(
        await db.customSelect('SELECT * FROM folders').get(),
        hasLength(9),
      );
      // settings.schemaVersion 写回 7（二十七批 D-257：当前版本 v7）。
      final settings =
          (await db
                  .customSelect(
                    'SELECT * FROM settings WHERE key = ?',
                    variables: [Variable.withString('schemaVersion')],
                  )
                  .get())
              .map((r) => r.data)
              .toList();
      expect(settings.single['value'], '7');
    });

    test('已是 v7 的库不删：再次打开数据还在', () async {
      final (tmp, db, dbPath) = await openTempDb();
      await AppDatabase.upsertQuestionInto(db, testQuestion());
      await db.close();
      expect(await AppDatabase.deleteLegacyDatabaseIfPresent(dbPath), isFalse);
      final reopened = await AppDatabase.openAt(dbPath);
      addTearDown(() async => reopened.close());
      expect(await AppDatabase.allQuestionsFrom(reopened), hasLength(1));
      expect(await dbVersion(reopened), 7);
      expect(tmp.existsSync(), isTrue);
    });

    test('不存在的库文件：直接建 v7 新库，不报错', () async {
      final tmp = await Directory.systemTemp.createTemp('p1-fresh-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = p.join(tmp.path, 'quiz-master2.db');
      expect(await AppDatabase.deleteLegacyDatabaseIfPresent(dbPath), isFalse);
      final db = await AppDatabase.openAt(dbPath);
      addTearDown(() async => db.close());
      expect(await dbVersion(db), 7);
      expect(await db.customSelect('SELECT * FROM questions').get(), isEmpty);
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
          createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000001),
        ),
      );
      final q2 = (await AppDatabase.allQuestionsFrom(db))
          .firstWhere((e) => e.id == 'q2');
      expect(q2.sourcePath, isNull);
      expect(q2.slicePath, isNull);
    });

    test('QuestionBox 行转换：confidence/origin/parent/page/归属一致', () async {
      final db = await openMemoryDb();
      await AppDatabase.insertQuestionBoxInto(
        db,
        testBox(collectTaskId: 'task-1', confidence: 0.93, origin: 'yolo'),
      );
      await AppDatabase.insertQuestionBoxInto(
        db,
        testBox(
          id: 'box-inner-1',
          layer: 2,
          type: 'stem',
          parentBoxId: 'box-task-1-p1-a1b2c3d4',
          questionId: 'q1',
          collectTaskId: null,
        ),
      );
      final boxes = await AppDatabase.boxesForQuestionFrom(db, 'q1');
      expect(boxes, hasLength(1));
      expect(boxes.single.parentBoxId, 'box-task-1-p1-a1b2c3d4');
      expect(boxes.single.layer, 2);
      final drafts =
          (await db
                  .customSelect(
                    'SELECT * FROM question_boxes WHERE collect_task_id = ?',
                    variables: [Variable.withString('task-1')],
                  )
                  .get())
              .map((r) => r.data)
              .toList();
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
      await AppDatabase.insertQuestionBoxInto(db, testBox(questionId: 'q1'));
      await AppDatabase.insertQuestionBoxInto(
        db,
        testBox(
          id: 'box-child',
          questionId: 'q1',
          parentBoxId: 'box-task-1-p1-a1b2c3d4',
          layer: 2,
          type: 'stem',
        ),
      );
      await AppDatabase.deleteQuestionFrom(db, 'q1');
      expect(
        await db.customSelect('SELECT * FROM question_boxes').get(),
        isEmpty,
      );
      expect(await db.customSelect('SELECT * FROM questions').get(), isEmpty);
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
          subjectId: 'math',
        ),
      );
      await AppDatabase.insertQuestionBoxInto(
        db,
        testBox(id: 'box-draft', collectTaskId: 'task-1'),
      );
      await AppDatabase.insertQuestionBoxInto(
        db,
        testBox(id: 'box-confirmed', collectTaskId: 'task-1', questionId: 'q1'),
      );
      await AppDatabase.deleteCollectTaskFrom(db, 'task-1');
      expect(
        await db.customSelect('SELECT * FROM collect_tasks').get(),
        isEmpty,
      );
      final remaining =
          (await db.customSelect('SELECT * FROM question_boxes').get())
              .map((r) => r.data)
              .toList();
      expect(remaining.map((r) => r['id']), ['box-confirmed']);
    });

    test('B2-6a 删任务：拆出的待整理题随任务删，已整理的题保留', () async {
      final db = await openMemoryDb();
      await AppDatabase.upsertQuestionInto(db, testQuestion(id: 'q1'));
      await AppDatabase.upsertQuestionInto(
        db,
        testQuestion(id: 'q2', isOrganized: true),
      );
      await AppDatabase.upsertCollectTaskInto(
        db,
        CollectTask(
          id: 'task-1',
          name: 'paper.png',
          fileName: 'paper.png',
          subjectId: 'math',
          questionId: 'q1',
        ),
      );
      await AppDatabase.upsertCollectTaskInto(
        db,
        CollectTask(
          id: 'task-2',
          name: 'paper2.png',
          fileName: 'paper2.png',
          subjectId: 'math',
          questionId: 'q2',
        ),
      );
      // 待整理题 q1 的已确认框 + task-1 的草稿框；已整理题 q2 的确认框。
      await AppDatabase.insertQuestionBoxInto(
        db,
        testBox(id: 'box-q1', questionId: 'q1'),
      );
      await AppDatabase.insertQuestionBoxInto(
        db,
        testBox(id: 'box-draft', collectTaskId: 'task-1'),
      );
      await AppDatabase.insertQuestionBoxInto(
        db,
        testBox(id: 'box-q2', questionId: 'q2'),
      );
      // 删带待整理题的任务：题、题的框、草稿框、任务行一起没；
      // 已整理题的任务与题都不动。
      await AppDatabase.deleteCollectTaskFrom(db, 'task-1');
      expect(
        (await db.customSelect('SELECT * FROM questions').get()).map(
          (r) => r.data['id'],
        ),
        ['q2'],
      );
      expect(
        (await db.customSelect('SELECT * FROM question_boxes').get()).map(
          (r) => r.data['id'],
        ),
        ['box-q2'],
      );
      expect(
        (await db.customSelect('SELECT * FROM collect_tasks').get()).map(
          (r) => r.data['id'],
        ),
        ['task-2'],
      );
      // 删带已整理题的任务：题与框保留，只删任务行。
      await AppDatabase.deleteCollectTaskFrom(db, 'task-2');
      expect(
        (await db.customSelect('SELECT * FROM questions').get()).map(
          (r) => r.data['id'],
        ),
        ['q2'],
      );
      expect(
        (await db.customSelect('SELECT * FROM question_boxes').get()).map(
          (r) => r.data['id'],
        ),
        ['box-q2'],
      );
      expect(
        await db.customSelect('SELECT * FROM collect_tasks').get(),
        isEmpty,
      );
    });
  });

  group('P1 §2.3 v4 备份恢复（v2/v3 备份仍可恢复）', () {
    Future<Map<String, dynamic>> seedAndExport(QuizDatabase db) async {
      await AppDatabase.upsertQuestionInto(db, testQuestion());
      await AppDatabase.insertQuestionBoxInto(
        db,
        testBox(questionId: 'q1', confidence: 0.9, origin: 'yolo'),
      );
      await AppDatabase.upsertCollectTaskInto(
        db,
        CollectTask(
          id: 'task-1',
          name: 'paper.png',
          fileName: 'paper.png',
          subjectId: 'math',
          sourcePath: 'imports/task-1/original.png',
          pageRotations: {1: 90},
          createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ),
      );
      final exported = await AppDatabase.exportBackupJsonFrom(db);
      return jsonDecode(exported) as Map<String, dynamic>;
    }

    test('导出：平铺表名 + _meta，16 张表', () async {
      final db = await openMemoryDb();
      final decoded = await seedAndExport(db);
      final meta = decoded['_meta'] as Map<String, dynamic>;
      expect(meta['schemaVersion'], AppDatabase.schemaVersion);
      expect(meta['appVersion'], AppDatabase.appVersion);
      expect(meta['exportedAt'], isA<int>());
      // 十四批 M2：attempts 全表纳入备份，16 张。
      expect(AppDatabase.backupTables.length, 16);
      expect(AppDatabase.backupTables, contains('question_boxes'));
      expect(AppDatabase.backupTables, contains('recently_viewed_questions'));
      // 十三批 M2：v4 新表 ocr_jobs。
      expect(AppDatabase.backupTables, contains('ocr_jobs'));
      // 十四批 M2：v5 新表 attempts。
      expect(AppDatabase.backupTables, contains('attempts'));
      for (final t in AppDatabase.backupTables) {
        expect(decoded, contains(t), reason: '导出缺表 $t');
      }
      expect((decoded['question_boxes'] as List), hasLength(1));
      expect(
        (decoded['questions'] as List).single['slice_path'],
        'slices/q1.png',
      );
      expect(
        (decoded['collect_tasks'] as List).single['page_rotations'],
        '{"1":90}',
      );
      // 十二批 D-91：新表导出为空数组；collect_tasks 行带 source_hash
      // 列（本用例未设哈希，为 null）。
      expect(decoded['recently_viewed_questions'], isEmpty);
      // 十三批 M2：新表导出为空数组。
      expect(decoded['ocr_jobs'], isEmpty);
      expect(
        (decoded['collect_tasks'] as List).single,
        contains('source_hash'),
      );
    });

    test('备份 → 清空 → 恢复：题/框/任务回来，schemaVersion 写回 7', () async {
      final db = await openMemoryDb();
      final decoded = await seedAndExport(db);
      await db.customUpdate('DELETE FROM questions');
      await db.customUpdate('DELETE FROM question_boxes');
      await db.customUpdate('DELETE FROM collect_tasks');
      await db.customUpdate('DELETE FROM settings');
      expect(await db.customSelect('SELECT * FROM questions').get(), isEmpty);
      await AppDatabase.importBackupJsonInto(db, decoded);
      final qs = await AppDatabase.allQuestionsFrom(db);
      expect(qs.single.slicePath, 'slices/q1.png');
      expect(qs.single.sourcePath, 'imports/task-1/original.png');
      final boxes = await AppDatabase.boxesForQuestionFrom(db, 'q1');
      expect(boxes.single.origin, 'yolo');
      expect(boxes.single.confidence, 0.9);
      final tasks = await AppDatabase.allCollectTasksFrom(db);
      expect(tasks.single.pageRotations, {1: 90});
      final settings =
          (await db
                  .customSelect(
                    'SELECT * FROM settings WHERE key = ?',
                    variables: [Variable.withString('schemaVersion')],
                  )
                  .get())
              .map((r) => r.data)
              .toList();
      expect(settings.single['value'], '7');
    });

    test('schemaVersion > 7：拒绝恢复，原库一动不动', () async {
      final db = await openMemoryDb();
      final decoded = await seedAndExport(db);
      (decoded['_meta'] as Map<String, dynamic>)['schemaVersion'] = 8;
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, decoded),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.message,
            'message',
            contains('更新的版本'),
          ),
        ),
      );
      // 原库不动：题、框、任务都在。
      expect(await AppDatabase.allQuestionsFrom(db), hasLength(1));
      expect(
        await db.customSelect('SELECT * FROM question_boxes').get(),
        hasLength(1),
      );
      expect(await AppDatabase.allCollectTasksFrom(db), hasLength(1));
    });

    test('_meta 缺失（v1 备份）：拒绝恢复，原库一动不动', () async {
      final db = await openMemoryDb();
      final decoded = await seedAndExport(db);
      decoded.remove('_meta');
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, decoded),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.message,
            'message',
            contains('v1'),
          ),
        ),
      );
      expect(await AppDatabase.allQuestionsFrom(db), hasLength(1));
      expect(
        await db.customSelect('SELECT * FROM question_boxes').get(),
        hasLength(1),
      );
    });

    test('schemaVersion 不是 2、3、4、5、6 或 7（=1 / 非整数）：拒绝恢复', () async {
      final db = await openMemoryDb();
      final decoded = await seedAndExport(db);
      (decoded['_meta'] as Map<String, dynamic>)['schemaVersion'] = 1;
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, decoded),
        throwsA(isA<BackupRestoreException>()),
      );
      final decoded2 = jsonDecode(jsonEncode(decoded)) as Map<String, dynamic>;
      (decoded2['_meta'] as Map<String, dynamic>)['schemaVersion'] = '3';
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, decoded2),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(await AppDatabase.allQuestionsFrom(db), hasLength(1));
    });

    test('v2 备份恢复：新表缺键视为 empty，source_hash 为 NULL', () async {
      // 十二批 D-91：v2 备份（13 张表、无 recently_viewed_questions
      // 键、collect_tasks 行无 source_hash 列）仍可恢复进 v7
      //（十三批 M2：v2 备份也没有 ocr_jobs 键与 questions 的 OCR 列，
      // 新表缺键视为 empty、新列走 DDL 默认值）。
      final db = await openMemoryDb();
      final decoded = await seedAndExport(db);
      (decoded['_meta'] as Map<String, dynamic>)['schemaVersion'] = 2;
      decoded.remove('recently_viewed_questions');
      for (final row in decoded['collect_tasks'] as List) {
        (row as Map<String, dynamic>).remove('source_hash');
      }
      await db.customUpdate('DELETE FROM questions');
      await db.customUpdate('DELETE FROM question_boxes');
      await db.customUpdate('DELETE FROM collect_tasks');
      await db.customUpdate('DELETE FROM settings');
      await AppDatabase.importBackupJsonInto(db, decoded);
      expect(await AppDatabase.allQuestionsFrom(db), hasLength(1));
      final tasks = await AppDatabase.allCollectTasksFrom(db);
      expect(tasks.single.sourceHash, isNull);
      expect(
        await db
            .customSelect('SELECT * FROM recently_viewed_questions')
            .get(),
        isEmpty,
      );
    });

    test('关键表不全 / 行不合法：拒绝恢复，原库一动不动', () async {
      final db = await openMemoryDb();
      final decoded = await seedAndExport(db);
      final noQuestions = Map<String, dynamic>.from(decoded)
        ..remove('questions');
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, noQuestions),
        throwsA(isA<BackupRestoreException>()),
      );
      final badRow = Map<String, dynamic>.from(decoded)
        ..['questions'] = [
          {'title': '缺主键的行'},
        ];
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, badRow),
        throwsA(isA<BackupRestoreException>()),
      );
      final notList = Map<String, dynamic>.from(decoded)
        ..['subjects'] = {'not': 'a-list'};
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, notList),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(await AppDatabase.allQuestionsFrom(db), hasLength(1));
    });

    test('SR-P2-4：缺表键的备份拒绝恢复，原库一动不动（不再按空表静默清空）', () async {
      final db = await openMemoryDb();
      final decoded = await seedAndExport(db);
      decoded.remove('collect_tasks');
      decoded.remove('review_state');
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, decoded),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(await AppDatabase.allCollectTasksFrom(db), hasLength(1));
      expect(await AppDatabase.allQuestionsFrom(db), hasLength(1));
    });
  });
}
