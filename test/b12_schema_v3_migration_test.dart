// 十二批 D-91：v2 → v3 迁移验收。
// v3 = v2 的 13 张表 + recently_viewed_questions 新表 + collect_tasks
// 新增 source_hash 列。v2 库文件不再删除，走 Drift onUpgrade 迁移，
// 数据全保留；v2 备份仍可恢复（见 p1_schema_backup_test 的 v2 备份用例）。
// 十三批 M2：当前版本已是 v4，v2 库走 2→3 再 3→4 两步链式迁移到 v4
//（本文件原断言的 user_version 3 / settings '3' 已按 D-98 的 stale
// 断言口径更新为 4；单步 v3 → v4 见 test/b13_migration_test.dart）。
// 全部用临时目录，不碰真实用户库。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// v2 基线 DDL（13 表 + 4 索引，取自 test/b1_stage1_schema_test.dart
/// 的 v2 期望值——建 v2 夹具库用。顺序：先建表，后建索引。）
const _v2Ddl = [
  "CREATE TABLE cause_records( id INTEGER PRIMARY KEY AUTOINCREMENT, question_id TEXT NOT NULL, cause TEXT NOT NULL, subject_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', solved_count INTEGER NOT NULL DEFAULT 0, last_check INTEGER, recheck_date INTEGER, remedy_history TEXT NOT NULL DEFAULT '', joined_at INTEGER NOT NULL, UNIQUE(question_id, cause))",
  "CREATE TABLE collect_tasks( id TEXT PRIMARY KEY, name TEXT NOT NULL, file_name TEXT NOT NULL, subject_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'queued', progress INTEGER NOT NULL DEFAULT 0, page_count INTEGER NOT NULL DEFAULT 1, page INTEGER NOT NULL DEFAULT 1, error TEXT, question_id TEXT, created_at INTEGER NOT NULL DEFAULT 0, source_path TEXT NOT NULL DEFAULT '', page_rotations TEXT NOT NULL DEFAULT '{}')",
  'CREATE TABLE exams(id TEXT PRIMARY KEY, name TEXT NOT NULL, date INTEGER)',
  'CREATE TABLE folders( id TEXT PRIMARY KEY, name TEXT NOT NULL, subject_id TEXT NOT NULL, parent_id TEXT, sort_order INTEGER NOT NULL DEFAULT 0)',
  'CREATE TABLE knowledge_points( id TEXT PRIMARY KEY, subject_id TEXT NOT NULL, chapter TEXT NOT NULL, name TEXT NOT NULL)',
  "CREATE TABLE question_boxes( id TEXT PRIMARY KEY, collect_task_id TEXT, question_id TEXT, parent_box_id TEXT, page INTEGER NOT NULL DEFAULT 1 CHECK (page >= 1), layer INTEGER NOT NULL CHECK (layer IN (1, 2)), type TEXT NOT NULL CHECK (type IN ('question', 'stem', 'option', 'figure')), x REAL NOT NULL CHECK (x >= 0 AND x <= 1), y REAL NOT NULL CHECK (y >= 0 AND y <= 1), w REAL NOT NULL CHECK (w >= 0 AND w <= 1), h REAL NOT NULL CHECK (h >= 0 AND h <= 1), confidence REAL CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)), origin TEXT NOT NULL DEFAULT 'manual' CHECK (origin IN ('yolo', 'manual')), updated_at INTEGER NOT NULL)",
  "CREATE TABLE questions( id TEXT PRIMARY KEY, title TEXT NOT NULL, subject_id TEXT NOT NULL, folder_ids TEXT NOT NULL DEFAULT '', exam_id TEXT, knowledge_ids TEXT NOT NULL DEFAULT '', error_types TEXT NOT NULL DEFAULT '', custom_error_types TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '', answer TEXT, explanation TEXT, notes TEXT, review_count INTEGER NOT NULL DEFAULT 0, is_organized INTEGER NOT NULL DEFAULT 0, is_demo INTEGER NOT NULL DEFAULT 0, is_favorite INTEGER NOT NULL DEFAULT 0, is_archived INTEGER NOT NULL DEFAULT 0, review_joined INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, slice_kind TEXT NOT NULL DEFAULT 'material', slice_text TEXT NOT NULL DEFAULT '', source_path TEXT, source_kind TEXT, source_page INTEGER, page_image_path TEXT, slice_path TEXT, slice_width INTEGER, slice_height INTEGER)",
  'CREATE TABLE recent_tasks( id INTEGER PRIMARY KEY CHECK (id = 1), kind TEXT NOT NULL, subject_id TEXT NOT NULL, title TEXT NOT NULL, updated_at INTEGER NOT NULL)',
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

/// 造一个 v2 库文件：v2 DDL + user_version=2 + 一行题 + 一行失败任务。
Future<String> _v2DbFile(Directory tmp) async {
  final dbPath = p.join(tmp.path, 'quiz-master2.db');
  final raw = sqlite3.sqlite3.open(dbPath);
  for (final ddl in _v2Ddl) {
    raw.execute(ddl);
  }
  raw.execute("INSERT INTO subjects VALUES ('math', '数学', 4280391411, 'plain', 'blue')");
  raw.execute(
    "INSERT INTO questions (id, title, subject_id, created_at) VALUES ('q1', '迁移后还在的题', 'math', 1700000000000)",
  );
  raw.execute(
    "INSERT INTO collect_tasks (id, name, file_name, subject_id, status, error, source_path) VALUES ('task-1', 'paper.pdf', 'paper.pdf', 'math', 'failed', '旧失败原因', 'imports/task-1/original.pdf')",
  );
  raw.execute('PRAGMA user_version = 2');
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

void main() {
  group('十二批 D-91 + 十三批 M2：v2 → v7 链式迁移', () {
    test('v2 库打开即链式迁移到 v7：数据全保留，新表与新列就位', () async {
      final tmp = await Directory.systemTemp.createTemp('b12-migrate-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = await _v2DbFile(tmp);
      // 预检不删 v2 库。
      expect(await AppDatabase.deleteLegacyDatabaseIfPresent(dbPath), isFalse);
      expect(File(dbPath).existsSync(), isTrue);

      final db = await AppDatabase.openAt(dbPath);
      addTearDown(() async => db.close());
      expect(
        (await db.customSelect('PRAGMA user_version').get())
            .single
            .data['user_version'],
        7,
      );
      // 旧数据还在。
      final qs = await AppDatabase.allQuestionsFrom(db);
      expect(qs, hasLength(1));
      expect(qs.single.title, '迁移后还在的题');
      // 十三批 M2：questions 的 5 个 OCR 列默认值就位。
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
      final tasks = await AppDatabase.allCollectTasksFrom(db);
      expect(tasks, hasLength(1));
      expect(tasks.single.status, CollectStatus.failed);
      expect(tasks.single.error, '旧失败原因');
      // v2 行的 source_hash 为 NULL（无指纹基线）。
      expect(tasks.single.sourceHash, isNull);
      // 新表存在且为空。
      expect(
        await db
            .customSelect('SELECT * FROM recently_viewed_questions')
            .get(),
        isEmpty,
      );
      // 十三批 M2：ocr_jobs 表存在且为空。
      expect(
        await db.customSelect('SELECT * FROM ocr_jobs').get(),
        isEmpty,
      );
      // settings.schemaVersion 写回 7。
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

    test('迁移后 DDL 与全新 v7 库逐字一致', () async {
      final tmp = await Directory.systemTemp.createTemp('b12-migrate-ddl-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final migratedPath = await _v2DbFile(tmp);
      final migrated = await AppDatabase.openAt(migratedPath);
      await migrated.close();

      final freshPath = p.join(tmp.path, 'fresh.db');
      final fresh = await AppDatabase.openAt(freshPath);
      await fresh.close();

      expect(await _allDdl(migratedPath), await _allDdl(freshPath));
    });

    test('v1 库仍删除：user_version < 2 才删', () async {
      final tmp = await Directory.systemTemp.createTemp('b12-migrate-v1-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = p.join(tmp.path, 'quiz-master2.db');
      final raw = sqlite3.sqlite3.open(dbPath);
      raw.execute('CREATE TABLE legacy_marker(id TEXT PRIMARY KEY)');
      raw.execute('PRAGMA user_version = 1');
      raw.close();
      expect(await AppDatabase.deleteLegacyDatabaseIfPresent(dbPath), isTrue);
      expect(File(dbPath).existsSync(), isFalse);
    });

    test('启动恢复：卡在 importing 的任务行置 failed，可重试', () async {
      final tmp = await Directory.systemTemp.createTemp('b12-recover-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = p.join(tmp.path, 'quiz-master2.db');
      final db = await AppDatabase.openAt(dbPath);
      addTearDown(() async => db.close());
      await AppDatabase.upsertCollectTaskInto(
        db,
        CollectTask(
          id: 'task-importing',
          name: 'half.pdf',
          fileName: 'half.pdf',
          subjectId: 'math',
          status: CollectStatus.importing,
          progress: 42,
        ),
      );
      await AppDatabase.upsertCollectTaskInto(
        db,
        CollectTask(
          id: 'task-needbox',
          name: 'ok.pdf',
          fileName: 'ok.pdf',
          subjectId: 'math',
          status: CollectStatus.needBox,
        ),
      );
      // 直接调回填（openAt 的 onBeforeOpen 同款逻辑）：
      // importing → failed；needBox 不动。
      final fixed = await backfillInterruptedImportsIntoImpl(db);
      expect(fixed, 1);
      final tasks = await AppDatabase.allCollectTasksFrom(db);
      final crashed =
          tasks.singleWhere((t) => t.id == 'task-importing');
      expect(crashed.status, CollectStatus.failed);
      expect(crashed.error, '上次导入被中断，请重试');
      expect(crashed.progress, 0);
      expect(
        tasks.singleWhere((t) => t.id == 'task-needbox').status,
        CollectStatus.needBox,
      );
      // 幂等：再跑一次无事可做。
      expect(await backfillInterruptedImportsIntoImpl(db), 0);
    });
  });
}
