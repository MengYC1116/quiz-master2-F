// 十三批 M2：v3 → v5 迁移 + ocr_jobs 表 + 备份互通验收；Win11 反馈包 5
// 后链式终点为 v6（questions 加 option_contents 两列）。
// v5 = v3 的 14 张表 + ocr_jobs 新表 + attempts 新表；questions 加 5 个
// OCR 列 + 9 个 M1 列（题型/背景标签/图块/答案版本等）。v3 库走 Drift
// onUpgrade 迁移，数据全保留；v2 库走 2→3 再 3→4 再 4→5 再 5→6 链式（见
// b12_schema_v3_migration_test 的链式测试）；v2/v3/v4/v5/v6 备份都能恢复进
// v6，>6 与 <2 拒绝。
// 全部用临时目录 / 内存库，不碰真实用户库。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// v3 基线 DDL（14 表 + 4 索引，取自十三批 M2 之前
/// test/b1_stage1_schema_test.dart 的 v3 期望值——建 v3 夹具库用）。
const _v3Ddl = [
  "CREATE TABLE cause_records( id INTEGER PRIMARY KEY AUTOINCREMENT, question_id TEXT NOT NULL, cause TEXT NOT NULL, subject_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', solved_count INTEGER NOT NULL DEFAULT 0, last_check INTEGER, recheck_date INTEGER, remedy_history TEXT NOT NULL DEFAULT '', joined_at INTEGER NOT NULL, UNIQUE(question_id, cause))",
  "CREATE TABLE collect_tasks( id TEXT PRIMARY KEY, name TEXT NOT NULL, file_name TEXT NOT NULL, subject_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'queued', progress INTEGER NOT NULL DEFAULT 0, page_count INTEGER NOT NULL DEFAULT 1, page INTEGER NOT NULL DEFAULT 1, error TEXT, question_id TEXT, created_at INTEGER NOT NULL DEFAULT 0, source_path TEXT NOT NULL DEFAULT '', page_rotations TEXT NOT NULL DEFAULT '{}', source_hash TEXT)",
  'CREATE TABLE exams(id TEXT PRIMARY KEY, name TEXT NOT NULL, date INTEGER)',
  'CREATE TABLE folders( id TEXT PRIMARY KEY, name TEXT NOT NULL, subject_id TEXT NOT NULL, parent_id TEXT, sort_order INTEGER NOT NULL DEFAULT 0)',
  'CREATE TABLE knowledge_points( id TEXT PRIMARY KEY, subject_id TEXT NOT NULL, chapter TEXT NOT NULL, name TEXT NOT NULL)',
  "CREATE TABLE question_boxes( id TEXT PRIMARY KEY, collect_task_id TEXT, question_id TEXT, parent_box_id TEXT, page INTEGER NOT NULL DEFAULT 1 CHECK (page >= 1), layer INTEGER NOT NULL CHECK (layer IN (1, 2)), type TEXT NOT NULL CHECK (type IN ('question', 'stem', 'option', 'figure')), x REAL NOT NULL CHECK (x >= 0 AND x <= 1), y REAL NOT NULL CHECK (y >= 0 AND y <= 1), w REAL NOT NULL CHECK (w >= 0 AND w <= 1), h REAL NOT NULL CHECK (h >= 0 AND h <= 1), confidence REAL CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)), origin TEXT NOT NULL DEFAULT 'manual' CHECK (origin IN ('yolo', 'manual')), updated_at INTEGER NOT NULL)",
  "CREATE TABLE questions( id TEXT PRIMARY KEY, title TEXT NOT NULL, subject_id TEXT NOT NULL, folder_ids TEXT NOT NULL DEFAULT '', exam_id TEXT, knowledge_ids TEXT NOT NULL DEFAULT '', error_types TEXT NOT NULL DEFAULT '', custom_error_types TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '', answer TEXT, explanation TEXT, notes TEXT, review_count INTEGER NOT NULL DEFAULT 0, is_organized INTEGER NOT NULL DEFAULT 0, is_demo INTEGER NOT NULL DEFAULT 0, is_favorite INTEGER NOT NULL DEFAULT 0, is_archived INTEGER NOT NULL DEFAULT 0, review_joined INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, slice_kind TEXT NOT NULL DEFAULT 'material', slice_text TEXT NOT NULL DEFAULT '', source_path TEXT, source_kind TEXT, source_page INTEGER, page_image_path TEXT, slice_path TEXT, slice_width INTEGER, slice_height INTEGER)",
  'CREATE TABLE recent_tasks( id INTEGER PRIMARY KEY CHECK (id = 1), kind TEXT NOT NULL, subject_id TEXT NOT NULL, title TEXT NOT NULL, updated_at INTEGER NOT NULL)',
  'CREATE TABLE recently_viewed_questions( question_id TEXT PRIMARY KEY, viewed_at INTEGER NOT NULL)',
  'CREATE TABLE review_history( id INTEGER PRIMARY KEY AUTOINCREMENT, question_id TEXT NOT NULL, result TEXT NOT NULL, reviewed_at INTEGER NOT NULL)',
  "CREATE TABLE review_state( id INTEGER PRIMARY KEY CHECK (id = 1), queue TEXT NOT NULL DEFAULT '', position INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL)",
  'CREATE TABLE settings( key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  "CREATE TABLE subjects( id TEXT PRIMARY KEY, name TEXT NOT NULL, color INTEGER NOT NULL, cover_style TEXT NOT NULL DEFAULT 'plain', cover_color TEXT NOT NULL DEFAULT 'blue')",
  'CREATE TABLE tags(id TEXT PRIMARY KEY, name TEXT NOT NULL)',
  'CREATE UNIQUE INDEX idx_boxes_one_layer1_per_question ON question_boxes(question_id) WHERE layer = 1 AND question_id IS NOT NULL',
  'CREATE INDEX idx_boxes_parent ON question_boxes(parent_box_id)',
  'CREATE INDEX idx_boxes_question ON question_boxes(question_id)',
  'CREATE INDEX idx_boxes_task_page ON question_boxes(collect_task_id, page)',
];

/// 造一个 v3 库文件：v3 DDL + user_version=3 + 一行题 + 一行失败任务 +
/// 一条浏览历史 + settings.schemaVersion='3'。
Future<String> _v3DbFile(Directory tmp) async {
  final dbPath = p.join(tmp.path, 'quiz-master2.db');
  final raw = sqlite3.sqlite3.open(dbPath);
  for (final ddl in _v3Ddl) {
    raw.execute(ddl);
  }
  raw.execute(
    "INSERT INTO subjects VALUES ('math', '数学', 4280391411, 'plain', 'blue')",
  );
  raw.execute(
    "INSERT INTO questions (id, title, subject_id, created_at) VALUES ('q1', '迁移后还在的题', 'math', 1700000000000)",
  );
  raw.execute(
    "INSERT INTO collect_tasks (id, name, file_name, subject_id, status, error, source_path, source_hash) VALUES ('task-1', 'paper.pdf', 'paper.pdf', 'math', 'failed', '旧失败原因', 'imports/task-1/original.pdf', 'deadbeef')",
  );
  raw.execute(
    "INSERT INTO recently_viewed_questions VALUES ('q1', 1700000001000)",
  );
  raw.execute("INSERT INTO settings VALUES ('schemaVersion', '3')");
  raw.execute('PRAGMA user_version = 3');
  raw.close();
  return dbPath;
}

Future<List<String>> _allDdl(String dbPath) async {
  final probe = sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
  try {
    return probe
        .select(
          "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL "
          "AND name != 'sqlite_sequence' ORDER BY type, name",
        )
        .map((r) => _norm(r['sql'] as String))
        .toList()
      ..sort();
  } finally {
    probe.close();
  }
}

Future<QuizDatabase> _openMemoryDb() async {
  final db = await AppDatabase.openForTest();
  addTearDown(() async => db.close());
  return db;
}

/// 种子：1 学科 + 1 道带 OCR 字段的题 + 2 个 OCR 任务（1 待处理、1 已完成）
/// + 1 条浏览历史。返回导出的备份 JSON。
Future<Map<String, dynamic>> _seedAndExport(QuizDatabase db) async {
  await db
      .into(db.subjects)
      .insert(
        SubjectsCompanion.insert(
          id: 'math',
          name: '数学',
          color: 0xFF2E7CF6,
        ),
      );
  await AppDatabase.upsertQuestionInto(
    db,
    Question(
      id: 'q1',
      title: '函数定义域',
      subjectId: 'math',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      slicePath: 'slices/q1.png',
      ocrRaw: r'已知函数 $f(x)=\frac{x^2-1}{x-1}$，求其定义域。',
      ocrStem: '已知函数 f(x)，求其定义域。',
      ocrSplitStatus: OcrSplitStatus.autoSegmented,
      ocrManualEdited: true,
      contentVersion: 2,
    ),
  );
  await db
      .into(db.ocrJobs)
      .insert(
        OcrJobsCompanion.insert(
          id: 'job-pending',
          questionId: 'q1',
          cropPath: const Value('slices/q1.png'),
          inputHash: const Value('aabbcc'),
          status: const Value('pending'),
          createdAt: 1700000000000,
          updatedAt: 1700000000000,
        ),
      );
  await db
      .into(db.ocrJobs)
      .insert(
        OcrJobsCompanion.insert(
          id: 'job-done',
          questionId: 'q1',
          cropPath: const Value('slices/q1.png'),
          inputHash: const Value('aabbcc'),
          status: const Value('completed'),
          attemptCount: const Value(1),
          startedAt: const Value(1700000001000),
          leaseUntil: const Value(1700000600000),
          createdAt: 1700000000000,
          updatedAt: 1700000002000,
          completedAt: const Value(1700000002000),
        ),
      );
  await AppDatabase.recordQuestionViewedInto(
    db,
    'q1',
    viewedAtMillis: 1700000003000,
  );
  return jsonDecode(await AppDatabase.exportBackupJsonFrom(db))
      as Map<String, dynamic>;
}

Future<List<Map<String, Object?>>> _rawRows(
  QuizDatabase db,
  String table,
) async => (await db.customSelect('SELECT * FROM $table').get())
    .map((r) => r.data)
    .toList();

void main() {
  group('十三批 M2：v3 → v6 迁移', () {
    test('v3 库打开即迁移到 v6：数据全保留，新列默认值正确', () async {
      final tmp = await Directory.systemTemp.createTemp('b13-migrate-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = await _v3DbFile(tmp);
      expect(await AppDatabase.deleteLegacyDatabaseIfPresent(dbPath), isFalse);

      final db = await AppDatabase.openAt(dbPath);
      addTearDown(() async => db.close());
      expect(
        (await db.customSelect('PRAGMA user_version').get())
            .single
            .data['user_version'],
        6,
      );
      // 旧数据还在。
      final qs = await AppDatabase.allQuestionsFrom(db);
      expect(qs, hasLength(1));
      expect(qs.single.title, '迁移后还在的题');
      final tasks = await AppDatabase.allCollectTasksFrom(db);
      expect(tasks, hasLength(1));
      expect(tasks.single.status, CollectStatus.failed);
      expect(tasks.single.sourceHash, 'deadbeef');
      // 浏览历史还在。
      final history = await AppDatabase.recentlyViewedQuestionsFrom(db);
      expect(history, hasLength(1));
      expect(history.single.question.id, 'q1');
      // 新列默认值：可空列 NULL，切分状态 '未切分'，标记与版本 0。
      expect(qs.single.ocrRaw, isNull);
      expect(qs.single.ocrStem, isNull);
      expect(qs.single.ocrSplitStatus, '未切分');
      expect(qs.single.ocrManualEdited, isFalse);
      expect(qs.single.contentVersion, 0);
      // 十四批 M1：v5 的 9 个新列默认值就位（题型 NULL/来源未分类/
      // 背景 ''/图块 []/答案与选项标签 NULL/answer_version=1）。
      expect(qs.single.questionType, isNull);
      expect(qs.single.questionTypeSource, 'unclassified');
      expect(qs.single.questionBackgroundTags, isEmpty);
      expect(qs.single.questionBackgroundTagsSource, 'unclassified');
      expect(qs.single.ocrFigures, '[]');
      expect(qs.single.correctOption, isNull);
      expect(qs.single.optionLabels, isNull);
      expect(qs.single.optionLabelsConfirmed, isFalse);
      expect(qs.single.answerVersion, 1);
      // ocr_jobs 表存在且为空。
      expect(await _rawRows(db, 'ocr_jobs'), isEmpty);
      // settings.schemaVersion 写回 6。
      final settings = await _rawRows(db, 'settings');
      expect(
        settings.singleWhere((r) => r['key'] == 'schemaVersion')['value'],
        '6',
      );
    });

    test('迁移后 DDL 与全新 v6 库逐字一致', () async {
      final tmp = await Directory.systemTemp.createTemp('b13-migrate-ddl-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final migratedPath = await _v3DbFile(tmp);
      final migrated = await AppDatabase.openAt(migratedPath);
      await migrated.close();

      final freshPath = p.join(tmp.path, 'fresh.db');
      final fresh = await AppDatabase.openAt(freshPath);
      await fresh.close();

      expect(await _allDdl(migratedPath), await _allDdl(freshPath));
    });

    test('全新 v6 库含 ocr_jobs 两个索引', () async {
      final tmp = await Directory.systemTemp.createTemp('b13-fresh-idx-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = p.join(tmp.path, 'quiz-master2.db');
      final db = await AppDatabase.openAt(dbPath);
      await db.close();
      final ddl = await _allDdl(dbPath);
      expect(
        ddl,
        contains(
          'CREATE INDEX idx_ocr_jobs_question ON ocr_jobs(question_id)',
        ),
      );
      expect(
        ddl,
        contains(
          'CREATE INDEX idx_ocr_jobs_pending ON ocr_jobs(status, available_at)',
        ),
      );
    });

    test('十三批 P1-1：全新 v6 与迁移后 v6 的 ocr_jobs 都有 lease_token 列', () async {
      final tmp = await Directory.systemTemp.createTemp('b13-lease-ddl-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      // 全新 v6。
      final freshPath = p.join(tmp.path, 'fresh.db');
      final fresh = await AppDatabase.openAt(freshPath);
      await fresh.close();
      expect(await _allDdl(freshPath), contains(contains('lease_token TEXT')));
      // v3 迁移到 v6：同一列也在（两份 DDL 字面量逐字一致，
      // “迁移后 DDL 与全新 v6 库逐字一致”一并锁定）。
      final migratedPath = await _v3DbFile(tmp);
      final migrated = await AppDatabase.openAt(migratedPath);
      await migrated.close();
      expect(
        await _allDdl(migratedPath),
        contains(contains('lease_token TEXT')),
      );
    });
  });

  group('十三批 M2：Question OCR 字段模型往返', () {
    test('upsert 带 OCR 字段的题 → 读回全对；copyWith 改版不抹 OCR 值', () async {
      final db = await _openMemoryDb();
      await db
          .into(db.subjects)
          .insert(
            SubjectsCompanion.insert(
              id: 'math',
              name: '数学',
              color: 0xFF2E7CF6,
            ),
          );
      final q = Question(
        id: 'q1',
        title: '函数定义域',
        subjectId: 'math',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ocrRaw: r'$\frac{1}{2}$',
        ocrStem: '题干',
        ocrSplitStatus: OcrSplitStatus.autoSegmented,
        ocrManualEdited: true,
        contentVersion: 3,
      );
      await AppDatabase.upsertQuestionInto(db, q);
      var back = (await AppDatabase.allQuestionsFrom(db)).single;
      expect(back.ocrRaw, r'$\frac{1}{2}$');
      expect(back.ocrStem, '题干');
      expect(back.ocrSplitStatus, '自动切分');
      expect(back.ocrManualEdited, isTrue);
      expect(back.contentVersion, 3);
      // copyWith 只改版本后整行写回，OCR 值不丢（_questionCompanion
      // 全列写回；缺了 OCR 列会把库里的值抹回默认值）。
      await AppDatabase.upsertQuestionInto(
        db,
        back.copyWith(contentVersion: 4),
      );
      back = (await AppDatabase.allQuestionsFrom(db)).single;
      expect(back.ocrRaw, r'$\frac{1}{2}$');
      expect(back.contentVersion, 4);
      // clearOcrRaw 真正清掉。
      await AppDatabase.upsertQuestionInto(
        db,
        back.copyWith(clearOcrRaw: true, clearOcrStem: true),
      );
      back = (await AppDatabase.allQuestionsFrom(db)).single;
      expect(back.ocrRaw, isNull);
      expect(back.ocrStem, isNull);
    });
  });

  group('十三批 M2：备份互通 sv5/sv3/sv2', () {
    test('sv5 往返：OCR 字段与 ocr_jobs 行都回来', () async {
      final db = await _openMemoryDb();
      final decoded = await _seedAndExport(db);
      await db.customUpdate('DELETE FROM questions');
      await db.customUpdate('DELETE FROM ocr_jobs');
      await db.customUpdate('DELETE FROM settings');
      await db.customUpdate('DELETE FROM recently_viewed_questions');
      await AppDatabase.importBackupJsonInto(db, decoded);
      final q = (await AppDatabase.allQuestionsFrom(db)).single;
      expect(q.ocrRaw, r'已知函数 $f(x)=\frac{x^2-1}{x-1}$，求其定义域。');
      expect(q.ocrStem, '已知函数 f(x)，求其定义域。');
      expect(q.ocrSplitStatus, '自动切分');
      expect(q.ocrManualEdited, isTrue);
      expect(q.contentVersion, 2);
      final jobs = await _rawRows(db, 'ocr_jobs');
      expect(jobs, hasLength(2));
      final pending = jobs.singleWhere((r) => r['id'] == 'job-pending');
      expect(pending['status'], 'pending');
      expect(pending['question_id'], 'q1');
      expect(pending['crop_path'], 'slices/q1.png');
      expect(pending['input_hash'], 'aabbcc');
      expect(pending['attempt_count'], 0);
      expect(pending['completed_at'], isNull);
      final done = jobs.singleWhere((r) => r['id'] == 'job-done');
      expect(done['status'], 'completed');
      expect(done['attempt_count'], 1);
      expect(done['completed_at'], 1700000002000);
      final settings = await _rawRows(db, 'settings');
      expect(
        settings.singleWhere((r) => r['key'] == 'schemaVersion')['value'],
        '6',
      );
    });

    test('sv3 备份恢复：ocr_jobs 缺键视为 empty，OCR 列走默认值', () async {
      final db = await _openMemoryDb();
      final decoded = await _seedAndExport(db);
      (decoded['_meta'] as Map<String, dynamic>)['schemaVersion'] = 3;
      decoded.remove('ocr_jobs');
      for (final row in decoded['questions'] as List) {
        final m = row as Map<String, dynamic>;
        for (final col in [
          'ocr_raw',
          'ocr_stem',
          'ocr_split_status',
          'ocr_manual_edited',
          'content_version',
        ]) {
          m.remove(col);
        }
      }
      await db.customUpdate('DELETE FROM questions');
      await db.customUpdate('DELETE FROM settings');
      await AppDatabase.importBackupJsonInto(db, decoded);
      final q = (await AppDatabase.allQuestionsFrom(db)).single;
      expect(q.title, '函数定义域');
      expect(q.ocrRaw, isNull);
      expect(q.ocrStem, isNull);
      expect(q.ocrSplitStatus, '未切分');
      expect(q.ocrManualEdited, isFalse);
      expect(q.contentVersion, 0);
      expect(await _rawRows(db, 'ocr_jobs'), isEmpty);
      // 浏览历史（v3 有的表）正常回来。
      final history = await AppDatabase.recentlyViewedQuestionsFrom(db);
      expect(history, hasLength(1));
    });

    test('sv2 备份恢复：新表缺键视为 empty，source_hash 为 NULL', () async {
      final db = await _openMemoryDb();
      final decoded = await _seedAndExport(db);
      (decoded['_meta'] as Map<String, dynamic>)['schemaVersion'] = 2;
      decoded.remove('ocr_jobs');
      decoded.remove('recently_viewed_questions');
      for (final row in decoded['questions'] as List) {
        final m = row as Map<String, dynamic>;
        for (final col in [
          'ocr_raw',
          'ocr_stem',
          'ocr_split_status',
          'ocr_manual_edited',
          'content_version',
        ]) {
          m.remove(col);
        }
      }
      await db.customUpdate('DELETE FROM questions');
      await db.customUpdate('DELETE FROM settings');
      await AppDatabase.importBackupJsonInto(db, decoded);
      final q = (await AppDatabase.allQuestionsFrom(db)).single;
      expect(q.title, '函数定义域');
      expect(q.ocrSplitStatus, '未切分');
      expect(await _rawRows(db, 'ocr_jobs'), isEmpty);
      expect(await _rawRows(db, 'recently_viewed_questions'), isEmpty);
    });

    test('sv6 恢复成功（当前版本），sv1 仍拒绝恢复，原库一动不动', () async {
      final db = await _openMemoryDb();
      final decoded = await _seedAndExport(db);
      // Win11 反馈包 5：当前版本已是 v6，sv6 备份恢复本应成功（不再是“更新的版本”）。
      final current = jsonDecode(jsonEncode(decoded)) as Map<String, dynamic>;
      (current['_meta'] as Map<String, dynamic>)['schemaVersion'] = 6;
      await AppDatabase.importBackupJsonInto(db, current);
      expect(await AppDatabase.allQuestionsFrom(db), hasLength(1));
      expect(await _rawRows(db, 'ocr_jobs'), hasLength(2));
      // sv1（<2）仍拒绝恢复，原库一动不动。
      final tooOld = jsonDecode(jsonEncode(decoded)) as Map<String, dynamic>;
      (tooOld['_meta'] as Map<String, dynamic>)['schemaVersion'] = 1;
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, tooOld),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(await AppDatabase.allQuestionsFrom(db), hasLength(1));
      expect(await _rawRows(db, 'ocr_jobs'), hasLength(2));
    });
  });

  group('十三批 M2：主键与值域校验（D-101 回归）', () {
    test('含 4 条浏览历史的备份往返成功，不再报“缺少主键 id”', () async {
      final db = await _openMemoryDb();
      await db
          .into(db.subjects)
          .insert(
            SubjectsCompanion.insert(
              id: 'math',
              name: '数学',
              color: 0xFF2E7CF6,
            ),
          );
      for (var i = 1; i <= 4; i++) {
        await AppDatabase.upsertQuestionInto(
          db,
          Question(
            id: 'q$i',
            title: '题 $i',
            subjectId: 'math',
            createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000 + i),
          ),
        );
        await AppDatabase.recordQuestionViewedInto(
          db,
          'q$i',
          viewedAtMillis: 1700000000000 + i,
        );
      }
      final decoded = jsonDecode(await AppDatabase.exportBackupJsonFrom(db))
          as Map<String, dynamic>;
      expect((decoded['recently_viewed_questions'] as List), hasLength(4));
      final target = await _openMemoryDb();
      await AppDatabase.importBackupJsonInto(target, decoded);
      final rows = await _rawRows(target, 'recently_viewed_questions');
      expect(rows.map((r) => r['question_id']).toSet(), {
        'q1',
        'q2',
        'q3',
        'q4',
      });
    });

    test('ocr_jobs 行缺 id：拒绝恢复，原库不动', () async {
      final db = await _openMemoryDb();
      final decoded = await _seedAndExport(db);
      (decoded['ocr_jobs'] as List).add({
        'question_id': 'q1',
        'status': 'pending',
        'created_at': 1700000000000,
        'updated_at': 1700000000000,
      });
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, decoded),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(await _rawRows(db, 'ocr_jobs'), hasLength(2));
    });

    test('ocr_jobs 行缺 question_id：拒绝恢复', () async {
      final db = await _openMemoryDb();
      final decoded = await _seedAndExport(db);
      (decoded['ocr_jobs'] as List).add({
        'id': 'job-bad',
        'status': 'pending',
        'created_at': 1700000000000,
        'updated_at': 1700000000000,
      });
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, decoded),
        throwsA(isA<BackupRestoreException>()),
      );
    });

    test('ocr_jobs status 非法：拒绝恢复', () async {
      final db = await _openMemoryDb();
      final decoded = await _seedAndExport(db);
      ((decoded['ocr_jobs'] as List).first as Map)['status'] = 'flying';
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, decoded),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.message,
            'message',
            contains('status'),
          ),
        ),
      );
      expect(await _rawRows(db, 'ocr_jobs'), hasLength(2));
    });

    test('questions ocr_split_status 非法：拒绝恢复', () async {
      final db = await _openMemoryDb();
      final decoded = await _seedAndExport(db);
      ((decoded['questions'] as List).first as Map)['ocr_split_status'] =
          '已切一半';
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, decoded),
        throwsA(isA<BackupRestoreException>()),
      );
      expect((await AppDatabase.allQuestionsFrom(db)).single.ocrSplitStatus,
          '自动切分');
    });

    test('questions ocr_manual_edited=2：拒绝恢复', () async {
      final db = await _openMemoryDb();
      final decoded = await _seedAndExport(db);
      ((decoded['questions'] as List).first as Map)['ocr_manual_edited'] = 2;
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, decoded),
        throwsA(isA<BackupRestoreException>()),
      );
    });

    test('ocr_jobs crop_path 非法（绝对路径 / 穿越）：拒绝恢复', () async {
      final db = await _openMemoryDb();
      final decoded = await _seedAndExport(db);
      ((decoded['ocr_jobs'] as List).first as Map)['crop_path'] =
          '/etc/passwd';
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, decoded),
        throwsA(isA<BackupRestoreException>()),
      );
      final decoded2 = await _seedAndExport(await _openMemoryDb());
      ((decoded2['ocr_jobs'] as List).first as Map)['crop_path'] =
          'slices/../secret.png';
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, decoded2),
        throwsA(isA<BackupRestoreException>()),
      );
    });
  });

  group('十三批 M2：zip 备份含 crop 文件 + 孤儿口径', () {
    test('zip 往返：crop 文件进包、恢复后文件与任务行都回来', () async {
      final tmp1 = await Directory.systemTemp.createTemp('b13-zip-src-');
      final tmp2 = await Directory.systemTemp.createTemp('b13-zip-dst-');
      addTearDown(() async {
        try {
          await tmp1.delete(recursive: true);
        } catch (_) {}
        try {
          await tmp2.delete(recursive: true);
        } catch (_) {}
      });
      final db = await _openMemoryDb();
      await _seedAndExport(db);
      // crop 用与 slice 不同的文件，证明 ocr_jobs.crop_path 单独进包。
      await db
          .into(db.ocrJobs)
          .insert(
            OcrJobsCompanion.insert(
              id: 'job-crop',
              questionId: 'q1',
              cropPath: const Value('slices/q1-crop.png'),
              createdAt: 1700000000000,
              updatedAt: 1700000000000,
            ),
          );
      final slices = Directory(p.join(tmp1.path, 'slices'));
      await slices.create(recursive: true);
      await File(p.join(slices.path, 'q1.png')).writeAsString('PNG-SLICE');
      await File(
        p.join(slices.path, 'q1-crop.png'),
      ).writeAsString('PNG-CROP');
      final zipBytes = await AppDatabase.exportBackupZipFrom(
        db,
        dataDir: tmp1.path,
      );
      final target = await _openMemoryDb();
      await AppDatabase.importBackupZipInto(target, zipBytes, dataDir: tmp2.path);
      expect(
        await File(p.join(tmp2.path, 'slices', 'q1.png')).readAsString(),
        'PNG-SLICE',
      );
      expect(
        await File(p.join(tmp2.path, 'slices', 'q1-crop.png')).readAsString(),
        'PNG-CROP',
      );
      final jobs = await _rawRows(target, 'ocr_jobs');
      expect(jobs.map((r) => r['id']).toSet(), {
        'job-pending',
        'job-done',
        'job-crop',
      });
      expect(
        (await AppDatabase.allQuestionsFrom(target)).single.ocrSplitStatus,
        '自动切分',
      );
    });

    test('只被 ocr_jobs.crop_path 引用的文件不是孤儿', () async {
      final tmp = await Directory.systemTemp.createTemp('b13-orphan-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final db = await _openMemoryDb();
      await AppDatabase.upsertQuestionInto(
        db,
        Question(
          id: 'q1',
          title: '题',
          subjectId: 'math',
          createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ),
      );
      await db
          .into(db.ocrJobs)
          .insert(
            OcrJobsCompanion.insert(
              id: 'job-1',
              questionId: 'q1',
              cropPath: const Value('slices/only-crop.png'),
              createdAt: 1700000000000,
              updatedAt: 1700000000000,
            ),
          );
      final slices = Directory(p.join(tmp.path, 'slices'));
      await slices.create(recursive: true);
      await File(
        p.join(slices.path, 'only-crop.png'),
      ).writeAsString('PNG-CROP');
      await File(p.join(slices.path, 'stray.png')).writeAsString('PNG-STRAY');
      final scan = await AppDatabase.scanOrphanFilesFrom(
        db,
        dataDir: tmp.path,
      );
      expect(
        scan.files.map((f) => f.relativePath).toList(),
        ['slices/stray.png'],
      );
    });
  });
}
