// B3 备份新旧互通（plan v9 §四第 3 阶段第 3 条 + §六第 6 条，强制验收条件）。
// ① 旧备份 → 新库：test/fixtures/b3-old-backup.json/.zip（B3 之前代码
//    导出的黄金夹具，13 张表全覆盖，含满值 / '[]' / '{}' / 非规范 ''）
//    经新的类型化恢复后，业务值不变、存储表示规范化为 '[]' / '{}'；
// ② 新备份 → 旧代码库：新代码导出的备份，经旧恢复逻辑（手拼 SQL 的
//    _backupInsertRow，本文件内逐字复刻、仅供测试）的恢复后业务值不变；
// ③ 现场往返：新导出 → 清空 → 新恢复 → 再导出，两次导出除 _meta 外一致。
// 全部用内存库 / 临时目录，不碰真实库。按 D-45：种子放测试体内、
// repo 调用直接 await，不用 runAsync。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/zip_archive.dart';

Future<QuizDatabase> openMemoryDb() async {
  final db = await AppDatabase.openForTest();
  addTearDown(() async => db.close());
  return db;
}

Future<Map<String, dynamic>> readGoldenJson() async {
  final text = await File('test/fixtures/b3-old-backup.json').readAsString();
  return jsonDecode(text) as Map<String, dynamic>;
}

Future<List<Map<String, Object?>>> rawRows(
  QuizDatabase db,
  String table,
) async => (await db.customSelect('SELECT * FROM $table').get())
    .map((r) => r.data)
    .toList();

Future<String?> rawString(
  QuizDatabase db,
  String table,
  String where,
  String column,
) async {
  final rows = await db
      .customSelect('SELECT $column FROM $table WHERE $where')
      .get();
  if (rows.isEmpty) return null;
  return rows.single.data[column] as String?;
}

/// B3 之前的恢复插行（逐字复刻，仅供“新备份 → 旧代码库”测试用）。
/// 来源：B3 之前 lib/data/db_backup.dart 的 `_backupInsertRow`。
Future<int> oldBackupInsertRow(
  DatabaseConnectionUser db,
  String table,
  Map<String, Object?> row,
) async {
  final cols = row.keys.toList();
  final sql =
      'INSERT OR REPLACE INTO $table '
      '(${cols.map((c) => '"${c.replaceAll('"', '""')}"').join(', ')}) '
      'VALUES (${List.filled(cols.length, '?').join(', ')})';
  return db.customInsert(
    sql,
    variables: [for (final c in cols) Variable(row[c])],
  );
}

/// B3 之前的恢复流程复刻（清表 + 逐行手拼 SQL 插回 + schemaVersion 写回）。
Future<void> oldRestoreJson(QuizDatabase db, Map<String, dynamic> data) async {
  AppDatabase.validateBackupData(data);
  final clearOrder = <String>[
    'question_boxes',
    ...AppDatabase.backupTables.reversed.where((t) => t != 'question_boxes'),
  ];
  await db.transaction(() async {
    for (final t in clearOrder) {
      await db.customUpdate('DELETE FROM $t');
    }
    for (final t in AppDatabase.backupTables) {
      final rows = data[t];
      if (rows is! List) continue;
      for (final row in rows) {
        if (row is! Map) continue;
        await oldBackupInsertRow(db, t, Map<String, Object?>.from(row));
      }
    }
    await db
        .into(db.settings)
        .insert(
          const SettingsCompanion(
            key: Value('schemaVersion'),
            value: Value('2'),
          ),
          mode: InsertMode.insertOrReplace,
        );
  });
}

/// 新代码的类型化 API 种子（与黄金夹具同构的富数据，供新 → 旧测试用；
/// 不含非规范 '' 行——新代码的类型化写入不会产出 ''）。
Future<void> seedRichDb(QuizDatabase db) async {
  for (final (id, name, color, cover) in [
    ('math', '数学', 0xFF2E7CF6, 'blue'),
    ('english', '英语', 0xFF2E9E5B, 'green'),
    ('politics', '政治', 0xFFE5484D, 'red'),
  ]) {
    await db
        .into(db.subjects)
        .insert(
          SubjectsCompanion.insert(
            id: id,
            name: name,
            color: color,
            coverStyle: const Value('plain'),
            coverColor: Value(cover),
          ),
        );
  }
  for (final t in ['易错', '常考', '需重做']) {
    await db.into(db.tags).insert(TagsCompanion.insert(id: 'tag-$t', name: t));
  }
  await AppDatabase.insertExamInto(
    db,
    Exam(id: 'exam-math-mid', name: '高等数学期中试卷', date: DateTime(2026, 11, 3)),
  );
  await AppDatabase.insertKnowledgePointInto(
    db,
    const KnowledgePoint(
      id: 'kp-math-limit',
      subjectId: 'math',
      chapter: '函数与极限',
      name: '函数极限',
    ),
  );
  await AppDatabase.upsertQuestionInto(
    db,
    Question(
      id: 'q-rich-1',
      title: '函数极限综合题',
      subjectId: 'math',
      folderIds: const ['folder-math-试卷'],
      examId: 'exam-math-mid',
      knowledgePointIds: const ['kp-math-limit'],
      errorTypes: const ['概念不清'],
      customErrorTypes: const ['审题漏条件'],
      tags: const ['易错', '常考'],
      answer: '答案：0',
      explanation: '解析：洛必达',
      notes: '笔记',
      reviewCount: 3,
      isOrganized: true,
      isFavorite: true,
      reviewJoined: true,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      sourcePath: 'imports/task-1/original.png',
      sourceKind: 'image',
      sourcePage: 1,
      pageImagePath: 'imports/task-1/original.png',
      slicePath: 'slices/q-rich-1.png',
      sliceWidth: 800,
      sliceHeight: 600,
    ),
  );
  await AppDatabase.upsertQuestionInto(
    db,
    Question(
      id: 'q-rich-2',
      title: '空 JSON 列表题',
      subjectId: 'english',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000001000),
    ),
  );
  await AppDatabase.insertQuestionBoxInto(
    db,
    const QuestionBox(
      id: 'box-1',
      collectTaskId: 'task-1',
      questionId: 'q-rich-1',
      layer: 1,
      type: 'question',
      x: 0.1,
      y: 0.1,
      w: 0.8,
      h: 0.2,
      confidence: 0.9,
      origin: 'yolo',
      page: 1,
    ),
  );
  await AppDatabase.insertQuestionBoxInto(
    db,
    const QuestionBox(
      id: 'box-2',
      questionId: 'q-rich-1',
      layer: 2,
      type: 'stem',
      x: 0.12,
      y: 0.12,
      w: 0.5,
      h: 0.1,
      origin: 'manual',
      page: 1,
    ),
  );
  await db
      .into(db.causeRecords)
      .insert(
        CauseRecordsCompanion.insert(
          questionId: 'q-rich-1',
          cause: '概念不清',
          subjectId: 'math',
          status: const Value('pending'),
          solvedCount: const Value(0),
          remedyHistory: const Value(['先画图', '再列式']),
          joinedAt: 1700000000000,
        ),
      );
  await db
      .into(db.causeRecords)
      .insert(
        CauseRecordsCompanion.insert(
          questionId: 'q-rich-2',
          cause: '计算错误',
          subjectId: 'english',
          remedyHistory: const Value([]),
          joinedAt: 1700000001000,
        ),
      );
  await AppDatabase.upsertCollectTaskInto(
    db,
    CollectTask(
      id: 'task-1',
      name: 'paper.png',
      fileName: 'paper.png',
      subjectId: 'math',
      sourcePath: 'imports/task-1/original.png',
      pageRotations: const {1: 90, 3: 270},
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    ),
  );
  await db
      .into(db.collectTasks)
      .insert(
        CollectTasksCompanion.insert(
          id: 'task-2',
          name: 'paper2.png',
          fileName: 'paper2.png',
          subjectId: 'english',
          pageRotations: const Value({}),
          createdAt: const Value(1700000001000),
        ),
      );
  await db
      .into(db.reviewState)
      .insert(
        ReviewStateCompanion.insert(
          id: const Value(1),
          queue: const Value([
            ReviewQueueItem(questionId: 'q-rich-1', cause: '概念不清'),
            ReviewQueueItem(questionId: 'q-rich-2', cause: '计算错误'),
            ReviewQueueItem(questionId: 'q-rich-1', cause: '方法不会'),
          ]),
          position: const Value(1),
          updatedAt: 1700000003000,
        ),
      );
  await db
      .into(db.reviewHistory)
      .insert(
        ReviewHistoryCompanion.insert(
          questionId: 'q-rich-1',
          result: 'solved',
          reviewedAt: 1700000004000,
        ),
      );
  await db
      .into(db.reviewHistory)
      .insert(
        ReviewHistoryCompanion.insert(
          questionId: 'q-rich-2',
          result: 'unsolved',
          reviewedAt: 1700000005000,
        ),
      );
  await db
      .into(db.recentTasks)
      .insert(
        RecentTasksCompanion.insert(
          id: const Value(1),
          kind: '整理',
          subjectId: 'math',
          title: '整理 1 道题',
          updatedAt: 1700000006000,
        ),
      );
  // 十二批 D-91：种子模拟的是当前版本库，schemaVersion 须跟踪当前版本
  // （恢复末尾会把 settings.schemaVersion 写回当前版本；种子若仍写
  // 死 '2'，现场往返的两次导出会在该行上不一致）。
  for (final (k, v) in [
    ('schemaVersion', '${AppDatabase.schemaVersion}'),
    ('lastRoute', '/home'),
  ]) {
    await db
        .into(db.settings)
        .insert(SettingsCompanion.insert(key: k, value: v));
  }
}

/// 业务值断言：恢复后的库与期望的富数据一致（新旧两个方向共用）。
Future<void> expectRichData(QuizDatabase db) async {
  final qs = await AppDatabase.allQuestionsFrom(db);
  expect(qs, hasLength(2));
  final q1 = qs.singleWhere((q) => q.id == 'q-rich-1');
  expect(q1.folderIds, ['folder-math-试卷']);
  expect(q1.knowledgePointIds, ['kp-math-limit']);
  expect(q1.errorTypes, ['概念不清']);
  expect(q1.customErrorTypes, ['审题漏条件']);
  expect(q1.tags, ['易错', '常考']);
  expect(q1.answer, '答案：0');
  expect(q1.explanation, '解析：洛必达');
  expect(q1.sourcePath, 'imports/task-1/original.png');
  expect(q1.slicePath, 'slices/q-rich-1.png');
  final q2 = qs.singleWhere((q) => q.id == 'q-rich-2');
  expect(q2.folderIds, isEmpty);
  expect(q2.tags, isEmpty);
  expect(q2.errorTypes, isEmpty);

  final boxes = await AppDatabase.boxesForQuestionFrom(db, 'q-rich-1');
  expect(boxes, hasLength(2));
  expect(
    boxes.singleWhere((b) => b.id == 'box-1').confidence,
    closeTo(0.9, 1e-9),
  );
  expect(boxes.singleWhere((b) => b.id == 'box-2').confidence, isNull);

  final causes = await db.select(db.causeRecords).get();
  expect(causes, hasLength(2));
  expect(causes.singleWhere((c) => c.questionId == 'q-rich-1').remedyHistory, [
    '先画图',
    '再列式',
  ]);
  expect(
    causes.singleWhere((c) => c.questionId == 'q-rich-2').remedyHistory,
    isEmpty,
  );

  final tasks = await AppDatabase.allCollectTasksFrom(db);
  expect(tasks, hasLength(2));
  expect(tasks.singleWhere((t) => t.id == 'task-1').pageRotations, {
    1: 90,
    3: 270,
  });
  expect(tasks.singleWhere((t) => t.id == 'task-2').pageRotations, isEmpty);

  final state = await db.select(db.reviewState).getSingle();
  expect(state.queue, [
    const ReviewQueueItem(questionId: 'q-rich-1', cause: '概念不清'),
    const ReviewQueueItem(questionId: 'q-rich-2', cause: '计算错误'),
    const ReviewQueueItem(questionId: 'q-rich-1', cause: '方法不会'),
  ]);
  expect(state.position, 1);

  final history = await db.select(db.reviewHistory).get();
  expect(history, hasLength(2));
  expect(history.map((h) => h.result).toSet(), {'solved', 'unsolved'});
}

void main() {
  group('B3 旧备份 → 新库（黄金夹具 JSON）', () {
    test('全部 13 张表行数与业务值一致', () async {
      final db = await openMemoryDb();
      final golden = await readGoldenJson();
      await AppDatabase.importBackupJsonInto(db, golden);

      expect((await rawRows(db, 'subjects')), hasLength(3));
      expect((await rawRows(db, 'questions')), hasLength(3));
      expect((await rawRows(db, 'question_boxes')), hasLength(2));
      expect((await rawRows(db, 'folders')), hasLength(9));
      expect((await rawRows(db, 'tags')), hasLength(3));
      expect((await rawRows(db, 'exams')), hasLength(2));
      expect((await rawRows(db, 'knowledge_points')), hasLength(2));
      expect((await rawRows(db, 'cause_records')), hasLength(3));
      expect((await rawRows(db, 'collect_tasks')), hasLength(3));
      expect((await rawRows(db, 'review_state')), hasLength(1));
      expect((await rawRows(db, 'review_history')), hasLength(2));
      expect((await rawRows(db, 'recent_tasks')), hasLength(1));
      expect((await rawRows(db, 'settings')), hasLength(4));

      // 满值行与空值行的业务值（q-legacy-1 的 '' 行在下一组单独验）。
      final qs = await AppDatabase.allQuestionsFrom(db);
      final q1 = qs.singleWhere((q) => q.id == 'q-rich-1');
      expect(q1.folderIds, ['folder-math-试卷']);
      expect(q1.tags, ['易错', '常考']);
      expect(q1.notes, contains('\t'));
      final qLegacy = qs.singleWhere((q) => q.id == 'q-legacy-1');
      expect(qLegacy.folderIds, isEmpty);
      expect(qLegacy.tags, isEmpty);
      expect(qLegacy.errorTypes, isEmpty);
      expect(qLegacy.customErrorTypes, isEmpty);
      expect(qLegacy.knowledgePointIds, isEmpty);

      final causes = await db.select(db.causeRecords).get();
      expect(
        causes.singleWhere((c) => c.questionId == 'q-rich-1').remedyHistory,
        ['先画图', '再列式'],
      );
      expect(
        causes.singleWhere((c) => c.questionId == 'q-legacy-1').remedyHistory,
        isEmpty,
      );

      final tasks = await AppDatabase.allCollectTasksFrom(db);
      expect(tasks.singleWhere((t) => t.id == 'task-1').pageRotations, {
        1: 90,
        3: 270,
      });
      expect(
        tasks.singleWhere((t) => t.id == 'task-legacy').pageRotations,
        isEmpty,
      );
    });

    test('review_state.queue 逐项验证：questionId / cause / 队列位置不变', () async {
      final db = await openMemoryDb();
      final golden = await readGoldenJson();
      await AppDatabase.importBackupJsonInto(db, golden);
      final state = await db.select(db.reviewState).getSingle();
      expect(state.queue, hasLength(3));
      expect(state.queue[0].questionId, 'q-rich-1');
      expect(state.queue[0].cause, '概念不清');
      expect(state.queue[1].questionId, 'q-rich-2');
      expect(state.queue[1].cause, '计算错误');
      expect(state.queue[2].questionId, 'q-rich-1');
      expect(state.queue[2].cause, '方法不会');
      expect(state.position, 1);
    });

    test('存储表示规范化：非规范 \'\' 编回规范值，规范值逐字节不变', () async {
      final db = await openMemoryDb();
      final golden = await readGoldenJson();
      await AppDatabase.importBackupJsonInto(db, golden);
      // 非规范 '' → 规范 '[]' / '{}'。
      for (final col in [
        'folder_ids',
        'knowledge_ids',
        'error_types',
        'custom_error_types',
        'tags',
      ]) {
        expect(
          await rawString(db, 'questions', "id = 'q-legacy-1'", col),
          '[]',
          reason: 'q-legacy-1.$col 应由 \'\' 规范化为 \'[]\'',
        );
      }
      expect(
        await rawString(
          db,
          'cause_records',
          "question_id = 'q-legacy-1'",
          'remedy_history',
        ),
        '[]',
      );
      expect(
        await rawString(
          db,
          'collect_tasks',
          "id = 'task-legacy'",
          'page_rotations',
        ),
        '{}',
      );
      // 规范值逐字节不变。
      expect(
        await rawString(db, 'questions', "id = 'q-rich-1'", 'folder_ids'),
        '["folder-math-试卷"]',
      );
      expect(
        await rawString(db, 'questions', "id = 'q-rich-1'", 'tags'),
        '["易错","常考"]',
      );
      expect(
        await rawString(db, 'collect_tasks', "id = 'task-1'", 'page_rotations'),
        '{"1":90,"3":270}',
      );
      expect(
        await rawString(db, 'review_state', 'id = 1', 'queue'),
        '[{"q":"q-rich-1","c":"概念不清"},{"q":"q-rich-2","c":"计算错误"},'
        '{"q":"q-rich-1","c":"方法不会"}]',
      );
    });

    test('重导出与黄金夹具对比：差异仅 17 处规范化', () async {
      final db = await openMemoryDb();
      final golden = await readGoldenJson();
      await AppDatabase.importBackupJsonInto(db, golden);
      final reExported = jsonDecode(
        await AppDatabase.exportBackupJsonFrom(db),
      ) as Map<String, dynamic>;
      // 十二批 D-91：黄金夹具是 v2 备份（_meta.schemaVersion = 2），
      // 重导出盖的是当前版本戳（AppDatabase.schemaVersion = 4），
      // 两者不等是迁移的正常结果，不是回归；断言当前版本。
      expect(
        (reExported['_meta'] as Map)['schemaVersion'],
        AppDatabase.schemaVersion,
      );
      String pkOf(Map row) => '${row['id'] ?? row['key']}';
      // cause_records 的主键是自增 id：遗留行的 pk 从黄金夹具里现取，
      // 不写死数字（生成器里它是第 3 行，但测试不应依赖这个）。
      final legacyCausePk = pkOf(
        (golden['cause_records'] as List).cast<Map>().singleWhere(
          (r) => r['question_id'] == 'q-legacy-1',
        ),
      );
      final diffs = <String>[];
      for (final t in AppDatabase.backupTables) {
        // 十二批 D-91：v2 黄金夹具里没有 recently_viewed_questions
        // 键，缺键按空表算（v3 重导出里它是空列表）。
        final oldRows = {
          for (final r in (golden[t] as List? ?? [])) pkOf(r): r,
        };
        final newRows = {for (final r in reExported[t] as List) pkOf(r): r};
        expect(
          newRows.keys.toSet(),
          oldRows.keys.toSet(),
          reason: '$t 表主键集合变了',
        );
        for (final pk in oldRows.keys) {
          final oldRow = oldRows[pk]! as Map;
          final newRow = newRows[pk]! as Map;
          final cols = {...oldRow.keys, ...newRow.keys};
          for (final col in cols) {
            if (oldRow[col] != newRow[col]) {
              diffs.add('$t/$pk/$col: ${oldRow[col]} → ${newRow[col]}');
            }
          }
        }
      }
      expect(
        diffs,
        unorderedEquals([
          "questions/q-legacy-1/folder_ids:  → []",
          "questions/q-legacy-1/knowledge_ids:  → []",
          "questions/q-legacy-1/error_types:  → []",
          "questions/q-legacy-1/custom_error_types:  → []",
          "questions/q-legacy-1/tags:  → []",
          "cause_records/$legacyCausePk/remedy_history:  → []",
          "collect_tasks/task-legacy/page_rotations:  → {}",
          // 十二批 D-91：第 8 处是迁移写回——恢复把 settings.schemaVersion
          // 写回当前版本（v4 的 '4'），黄金夹具（v2）里它是 '2'。
          "settings/schemaVersion/value: 2 → 4",
          // 十三批 M2：第 9–17 处是 v4 新列的 DDL 默认值——v2 黄金夹具
          // 的 questions 行没有这 3 列（ocr_raw / ocr_stem 是可空列，
          // 缺键与 NULL 同值，不产生差异），恢复时按 DDL 默认值补齐。
          "questions/q-rich-1/ocr_split_status: null → 未切分",
          "questions/q-rich-1/ocr_manual_edited: null → 0",
          "questions/q-rich-1/content_version: null → 0",
          "questions/q-rich-2/ocr_split_status: null → 未切分",
          "questions/q-rich-2/ocr_manual_edited: null → 0",
          "questions/q-rich-2/content_version: null → 0",
          "questions/q-legacy-1/ocr_split_status: null → 未切分",
          "questions/q-legacy-1/ocr_manual_edited: null → 0",
          "questions/q-legacy-1/content_version: null → 0",
        ]),
      );
    });

    test('恢复进非空库：旧行清掉、新行回来', () async {
      final db = await openMemoryDb();
      await AppDatabase.upsertQuestionInto(
        db,
        Question(
          id: 'q-other',
          title: '会被清掉的题',
          subjectId: 'math',
          createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ),
      );
      final golden = await readGoldenJson();
      await AppDatabase.importBackupJsonInto(db, golden);
      final qs = await AppDatabase.allQuestionsFrom(db);
      expect(
        qs.map((q) => q.id),
        unorderedEquals(['q-rich-1', 'q-rich-2', 'q-legacy-1']),
      );
    });

    test('多余列的备份行拒绝恢复（旧 strict 口径保留）', () async {
      final db = await openMemoryDb();
      final golden = await readGoldenJson();
      final tampered = jsonDecode(jsonEncode(golden)) as Map<String, dynamic>;
      final questions = tampered['questions'] as List;
      (questions.first as Map)['unknown_column'] = 'x';
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, tampered),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(await AppDatabase.allQuestionsFrom(db), isEmpty);
    });
  });

  group('B3 旧备份 → 新库（黄金夹具 zip）', () {
    test('zip 恢复：库 + 文件都回来', () async {
      final db = await openMemoryDb();
      final tmp = await Directory.systemTemp.createTemp('b3-zip-restore-');
      addTearDown(() async => tmp.delete(recursive: true));
      final zipBytes = await File('test/fixtures/b3-old-backup.zip')
          .readAsBytes();
      await AppDatabase.importBackupZipInto(db, zipBytes, dataDir: tmp.path);
      final qs = await AppDatabase.allQuestionsFrom(db);
      expect(qs, hasLength(3));
      final state = await db.select(db.reviewState).getSingle();
      expect(state.queue, hasLength(3));
      expect(state.queue[0].questionId, 'q-rich-1');
      final original = File(
        p.join(tmp.path, 'imports', 'task-1', 'original.png'),
      );
      expect(await original.readAsString(), 'PNG-ORIGINAL');
      final slice = File(p.join(tmp.path, 'slices', 'q-rich-1.png'));
      expect(await slice.readAsString(), 'PNG-SLICE');
    });
  });

  group('B3 新备份 → 旧代码库（旧恢复逻辑复刻）', () {
    test('新导出经旧恢复逻辑后业务值一致', () async {
      final source = await openMemoryDb();
      await seedRichDb(source);
      final exported = jsonDecode(
        await AppDatabase.exportBackupJsonFrom(source),
      ) as Map<String, dynamic>;
      final target = await openMemoryDb();
      await oldRestoreJson(target, exported);
      await expectRichData(target);
    });

    test('新 zip 的 backup.json 经旧恢复逻辑后业务值一致，文件条目在包内', () async {
      final source = await openMemoryDb();
      await seedRichDb(source);
      final tmp = await Directory.systemTemp.createTemp('b3-zip-new-');
      addTearDown(() async => tmp.delete(recursive: true));
      final imp = Directory(p.join(tmp.path, 'imports', 'task-1'));
      await imp.create(recursive: true);
      await File(p.join(imp.path, 'original.png'))
          .writeAsBytes(utf8.encode('PNG-ORIGINAL'));
      final slices = Directory(p.join(tmp.path, 'slices'));
      await slices.create(recursive: true);
      await File(p.join(slices.path, 'q-rich-1.png'))
          .writeAsBytes(utf8.encode('PNG-SLICE'));
      final zipBytes = await AppDatabase.exportBackupZipFrom(
        source,
        dataDir: tmp.path,
      );
      final data = AppDatabase.readBackupJsonFromZip(zipBytes);
      final target = await openMemoryDb();
      await oldRestoreJson(target, data);
      await expectRichData(target);
      final entries = readZip(zipBytes);
      expect(entries.map((e) => e.name).toSet(), {
        'backup.json',
        'imports/task-1/original.png',
        'slices/q-rich-1.png',
      });
    });
  });

  group('B3 现场往返（新 → 新）', () {
    test('导出 → 恢复 → 再导出：两次导出除 _meta 外一致', () async {
      final source = await openMemoryDb();
      await seedRichDb(source);
      final first = jsonDecode(
        await AppDatabase.exportBackupJsonFrom(source),
      ) as Map<String, dynamic>;
      final target = await openMemoryDb();
      await AppDatabase.importBackupJsonInto(target, first);
      final second = jsonDecode(
        await AppDatabase.exportBackupJsonFrom(target),
      ) as Map<String, dynamic>;
      first.remove('_meta');
      second.remove('_meta');
      // 导出是 SELECT * 无 ORDER BY，行顺序不保证；恢复末尾的
      // schemaVersion 写回（insertOrReplace）会把该行移到 settings
      // 末尾——新旧代码同行为，与内容无关，故按主键排序后再比。
      String sortKey(Map row) => '${row['id'] ?? row['key']}';
      for (final t in AppDatabase.backupTables) {
        (first[t] as List).sort(
          (a, b) => sortKey(a as Map).compareTo(sortKey(b as Map)),
        );
        (second[t] as List).sort(
          (a, b) => sortKey(a as Map).compareTo(sortKey(b as Map)),
        );
      }
      expect(second, first);
    });
  });

  group('FR-20 可选 int 列小数被拒（_ri/_riN 不再静默截断）', () {
    test('questions.review_count 写 2.5：拒绝恢复，原库不动', () async {
      final db = await openMemoryDb();
      final golden = await readGoldenJson();
      final tampered = jsonDecode(jsonEncode(golden)) as Map<String, dynamic>;
      final questions = tampered['questions'] as List;
      (questions.first as Map)['review_count'] = 2.5;
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, tampered),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(await AppDatabase.allQuestionsFrom(db), isEmpty);
    });

    test('collect_tasks.page_count 写 1.5：拒绝恢复', () async {
      final db = await openMemoryDb();
      final golden = await readGoldenJson();
      final tampered = jsonDecode(jsonEncode(golden)) as Map<String, dynamic>;
      final tasks = tampered['collect_tasks'] as List;
      (tasks.first as Map)['page_count'] = 1.5;
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, tampered),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(await AppDatabase.allCollectTasksFrom(db), isEmpty);
    });

    test('整数值 double（review_count 2.0）放行：同一数值，不是猜测转换', () async {
      final db = await openMemoryDb();
      final golden = await readGoldenJson();
      final tampered = jsonDecode(jsonEncode(golden)) as Map<String, dynamic>;
      final questions = tampered['questions'] as List;
      (questions.first as Map)['review_count'] = 2.0;
      await AppDatabase.importBackupJsonInto(db, tampered);
      final q = (await AppDatabase.allQuestionsFrom(db))
          .singleWhere((q) => q.id == 'q-rich-1');
      expect(q.reviewCount, 2);
    });
  });

  group('FR-21 JSON 列缺键走 Value.absent()（旧口径存储表示）', () {
    test('缺 JSON 列的行恢复后是 \'\' 而不是 \'[]\'；page_rotations 缺键仍是 \'{}\'', () async {
      final db = await openMemoryDb();
      final golden = await readGoldenJson();
      final tampered = jsonDecode(jsonEncode(golden)) as Map<String, dynamic>;
      // q-legacy-1 行删掉 5 个 questions JSON 列。
      final legacyQ = (tampered['questions'] as List).cast<Map>().singleWhere(
        (r) => r['id'] == 'q-legacy-1',
      );
      for (final col in [
        'folder_ids',
        'knowledge_ids',
        'error_types',
        'custom_error_types',
        'tags',
      ]) {
        legacyQ.remove(col);
      }
      // q-legacy-1 的错因行删 remedy_history。
      final legacyCause = (tampered['cause_records'] as List)
          .cast<Map>()
          .singleWhere((r) => r['question_id'] == 'q-legacy-1');
      legacyCause.remove('remedy_history');
      // task-legacy 行删 page_rotations；review_state 行删 queue。
      final legacyTask = (tampered['collect_tasks'] as List)
          .cast<Map>()
          .singleWhere((r) => r['id'] == 'task-legacy');
      legacyTask.remove('page_rotations');
      final stateRow = (tampered['review_state'] as List).cast<Map>().single;
      stateRow.remove('queue');

      await AppDatabase.importBackupJsonInto(db, tampered);

      // 缺键行恢复后是 DDL 默认值 ''（旧口径），不是规范值 '[]'；
      // 键在但值是 '' 的行仍按 D-51 编回 '[]'（见“存储表示规范化”组对照）。
      for (final col in [
        'folder_ids',
        'knowledge_ids',
        'error_types',
        'custom_error_types',
        'tags',
      ]) {
        expect(
          await rawString(db, 'questions', "id = 'q-legacy-1'", col),
          '',
          reason: 'q-legacy-1.$col 缺键应落 DDL 默认 \'\'',
        );
      }
      expect(
        await rawString(
          db,
          'cause_records',
          "question_id = 'q-legacy-1'",
          'remedy_history',
        ),
        '',
      );
      // page_rotations 缺键时新旧一致，都是 '{}'（DDL 默认值）。
      expect(
        await rawString(
          db,
          'collect_tasks',
          "id = 'task-legacy'",
          'page_rotations',
        ),
        '{}',
      );
      expect(await rawString(db, 'review_state', 'id = 1', 'queue'), '');
      // 业务值仍为空集合（语义等价）。
      final qLegacy = (await AppDatabase.allQuestionsFrom(db))
          .singleWhere((q) => q.id == 'q-legacy-1');
      expect(qLegacy.folderIds, isEmpty);
      expect(qLegacy.tags, isEmpty);
      final state = await db.select(db.reviewState).getSingle();
      expect(state.queue, isEmpty);
    });
  });

  group('FR-23 域外值备份被拒（枚举/布尔白名单）', () {
    test('cause_records.status 写域外值：拒绝恢复，原库不动', () async {
      final db = await openMemoryDb();
      final golden = await readGoldenJson();
      final tampered = jsonDecode(jsonEncode(golden)) as Map<String, dynamic>;
      final causes = tampered['cause_records'] as List;
      (causes.first as Map)['status'] = 'weird';
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, tampered),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(await db.select(db.causeRecords).get(), isEmpty);
    });

    test('questions.is_organized 写 2：拒绝恢复，原库不动', () async {
      final db = await openMemoryDb();
      final golden = await readGoldenJson();
      final tampered = jsonDecode(jsonEncode(golden)) as Map<String, dynamic>;
      final questions = tampered['questions'] as List;
      (questions.first as Map)['is_organized'] = 2;
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, tampered),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(await AppDatabase.allQuestionsFrom(db), isEmpty);
    });

    test('合法值对照：status solved、布尔列 0/1 能恢复', () async {
      final db = await openMemoryDb();
      final golden = await readGoldenJson();
      final tampered = jsonDecode(jsonEncode(golden)) as Map<String, dynamic>;
      final causes = tampered['cause_records'] as List;
      (causes.first as Map)['status'] = 'solved';
      final questions = tampered['questions'] as List;
      (questions.first as Map)['is_organized'] = 1;
      (questions.first as Map)['is_favorite'] = 0;
      await AppDatabase.importBackupJsonInto(db, tampered);
      final causesBack = await db.select(db.causeRecords).get();
      expect(
        causesBack.singleWhere((c) => c.questionId == 'q-rich-1').status,
        'solved',
      );
    });
  });

  group('FR-40 备份里两份 backup.json：恢复层拒绝', () {
    test('含两个 backup.json 的 zip 被拒绝，原库不动', () async {
      final db = await openMemoryDb();
      final tmp = await Directory.systemTemp.createTemp('b3-fr40-');
      addTearDown(() async => tmp.delete(recursive: true));
      final golden = await readGoldenJson();
      final other = jsonDecode(jsonEncode(golden)) as Map<String, dynamic>;
      ((other['questions'] as List).first as Map)['title'] = '另一份题目数据';
      final zip = buildZip([
        ZipEntryData('backup.json', utf8.encode(jsonEncode(golden))),
        ZipEntryData('backup.json', utf8.encode(jsonEncode(other))),
      ]);
      await expectLater(
        () => AppDatabase.importBackupZipInto(db, zip, dataDir: tmp.path),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.message,
            'message',
            contains('备份里有两份题目数据'),
          ),
        ),
      );
      expect(await AppDatabase.allQuestionsFrom(db), isEmpty);
    });
  });
}
