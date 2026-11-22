// 十四批 M1：v4 → v5 迁移 + 删除语义 + v4 备份恢复默认值。
// v5 = v4 的 15 张表 + attempts 新表；questions 加 9 列、
// cause_records 加 2 列、review_history 加 8 列、review_state 加 4 列、
// questions.question_type 加索引。content_version 不新增、原值保留；
// 旧 solved_count 按保守方案迁移；迁移后 DDL 与全新 v5 库逐字一致。
// 全部用临时目录 / 内存库，不碰真实用户库。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// v4 基线 DDL（15 表 + 6 索引，取自 test/b1_stage1_schema_test.dart
/// 的 v4 期望值——建 v4 夹具库用）。
const _v4Ddl = [
  "CREATE TABLE cause_records( id INTEGER PRIMARY KEY AUTOINCREMENT, question_id TEXT NOT NULL, cause TEXT NOT NULL, subject_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', solved_count INTEGER NOT NULL DEFAULT 0, last_check INTEGER, recheck_date INTEGER, remedy_history TEXT NOT NULL DEFAULT '', joined_at INTEGER NOT NULL, UNIQUE(question_id, cause))",
  "CREATE TABLE collect_tasks( id TEXT PRIMARY KEY, name TEXT NOT NULL, file_name TEXT NOT NULL, subject_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'queued', progress INTEGER NOT NULL DEFAULT 0, page_count INTEGER NOT NULL DEFAULT 1, page INTEGER NOT NULL DEFAULT 1, error TEXT, question_id TEXT, created_at INTEGER NOT NULL DEFAULT 0, source_path TEXT NOT NULL DEFAULT '', page_rotations TEXT NOT NULL DEFAULT '{}', source_hash TEXT)",
  'CREATE TABLE exams(id TEXT PRIMARY KEY, name TEXT NOT NULL, date INTEGER)',
  'CREATE TABLE folders( id TEXT PRIMARY KEY, name TEXT NOT NULL, subject_id TEXT NOT NULL, parent_id TEXT, sort_order INTEGER NOT NULL DEFAULT 0)',
  'CREATE TABLE knowledge_points( id TEXT PRIMARY KEY, subject_id TEXT NOT NULL, chapter TEXT NOT NULL, name TEXT NOT NULL)',
  "CREATE TABLE question_boxes( id TEXT PRIMARY KEY, collect_task_id TEXT, question_id TEXT, parent_box_id TEXT, page INTEGER NOT NULL DEFAULT 1 CHECK (page >= 1), layer INTEGER NOT NULL CHECK (layer IN (1, 2)), type TEXT NOT NULL CHECK (type IN ('question', 'stem', 'option', 'figure')), x REAL NOT NULL CHECK (x >= 0 AND x <= 1), y REAL NOT NULL CHECK (y >= 0 AND y <= 1), w REAL NOT NULL CHECK (w >= 0 AND w <= 1), h REAL NOT NULL CHECK (h >= 0 AND h <= 1), confidence REAL CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)), origin TEXT NOT NULL DEFAULT 'manual' CHECK (origin IN ('yolo', 'manual')), updated_at INTEGER NOT NULL)",
  "CREATE TABLE questions( id TEXT PRIMARY KEY, title TEXT NOT NULL, subject_id TEXT NOT NULL, folder_ids TEXT NOT NULL DEFAULT '', exam_id TEXT, knowledge_ids TEXT NOT NULL DEFAULT '', error_types TEXT NOT NULL DEFAULT '', custom_error_types TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '', answer TEXT, explanation TEXT, notes TEXT, review_count INTEGER NOT NULL DEFAULT 0, is_organized INTEGER NOT NULL DEFAULT 0, is_demo INTEGER NOT NULL DEFAULT 0, is_favorite INTEGER NOT NULL DEFAULT 0, is_archived INTEGER NOT NULL DEFAULT 0, review_joined INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, slice_kind TEXT NOT NULL DEFAULT 'material', slice_text TEXT NOT NULL DEFAULT '', source_path TEXT, source_kind TEXT, source_page INTEGER, page_image_path TEXT, slice_path TEXT, slice_width INTEGER, slice_height INTEGER, ocr_raw TEXT, ocr_stem TEXT, ocr_split_status TEXT NOT NULL DEFAULT '未切分', ocr_manual_edited INTEGER NOT NULL DEFAULT 0, content_version INTEGER NOT NULL DEFAULT 0)",
  'CREATE TABLE ocr_jobs( id TEXT PRIMARY KEY, question_id TEXT NOT NULL, crop_path TEXT, input_hash TEXT, status TEXT NOT NULL DEFAULT \'pending\', attempt_count INTEGER NOT NULL DEFAULT 0, available_at INTEGER, started_at INTEGER, lease_until INTEGER, lease_token TEXT, last_error_code TEXT, last_error_message TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, completed_at INTEGER)',
  'CREATE TABLE recent_tasks( id INTEGER PRIMARY KEY CHECK (id = 1), kind TEXT NOT NULL, subject_id TEXT NOT NULL, title TEXT NOT NULL, updated_at INTEGER NOT NULL)',
  'CREATE TABLE recently_viewed_questions( question_id TEXT PRIMARY KEY, viewed_at INTEGER NOT NULL)',
  'CREATE TABLE review_history( id INTEGER PRIMARY KEY AUTOINCREMENT, question_id TEXT NOT NULL, result TEXT NOT NULL, reviewed_at INTEGER NOT NULL)',
  "CREATE TABLE review_state( id INTEGER PRIMARY KEY CHECK (id = 1), queue TEXT NOT NULL DEFAULT '', position INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL)",
  'CREATE TABLE settings( key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  "CREATE TABLE subjects( id TEXT PRIMARY KEY, name TEXT NOT NULL, color INTEGER NOT NULL, cover_style TEXT NOT NULL DEFAULT 'plain', cover_color TEXT NOT NULL DEFAULT 'blue')",
  'CREATE TABLE tags(id TEXT PRIMARY KEY, name TEXT NOT NULL)',
  // 索引必须建在表之后（上面按 b1 期望值的排序抄时索引在前，建库会失败）。
  'CREATE UNIQUE INDEX idx_boxes_one_layer1_per_question ON question_boxes(question_id) WHERE layer = 1 AND question_id IS NOT NULL',
  'CREATE INDEX idx_boxes_parent ON question_boxes(parent_box_id)',
  'CREATE INDEX idx_boxes_question ON question_boxes(question_id)',
  'CREATE INDEX idx_boxes_task_page ON question_boxes(collect_task_id, page)',
  'CREATE INDEX idx_ocr_jobs_pending ON ocr_jobs(status, available_at)',
  'CREATE INDEX idx_ocr_jobs_question ON ocr_jobs(question_id)',
];

/// 造一个 v4 库文件：v4 DDL + user_version=4 + 两道题 +
/// 三类旧错因记录（已治愈 / 未治愈且 solved_count=1 / solved_count=0）+
/// 一条旧复习记录 + q2 的一个框 + settings.schemaVersion='4'。
Future<String> _v4DbFile(Directory tmp) async {
  final dbPath = p.join(tmp.path, 'quiz-master2.db');
  final raw = sqlite3.sqlite3.open(dbPath);
  for (final ddl in _v4Ddl) {
    raw.execute(ddl);
  }
  raw.execute(
    "INSERT INTO subjects VALUES ('math', '数学', 4280391411, 'plain', 'blue')",
  );
  raw.execute(
    "INSERT INTO questions (id, title, subject_id, created_at, content_version) VALUES ('q1', '迁移后还在的题', 'math', 1700000000000, 7)",
  );
  raw.execute(
    "INSERT INTO questions (id, title, subject_id, created_at, content_version) VALUES ('q2', '待删的题', 'math', 1700000000000, 0)",
  );
  // 已治愈：保留状态与复查日期；未治愈且旧 solved_count=1：进度重置为 0；
  // solved_count=0：保持原值。
  raw.execute(
    "INSERT INTO cause_records (question_id, cause, subject_id, status, solved_count, recheck_date, joined_at) VALUES ('q1', '审题失误', 'math', 'solved', 2, 1700000005000, 1700000000000)",
  );
  raw.execute(
    "INSERT INTO cause_records (question_id, cause, subject_id, status, solved_count, joined_at) VALUES ('q1', '计算错误', 'math', 'inProgress', 1, 1700000000000)",
  );
  raw.execute(
    "INSERT INTO cause_records (question_id, cause, subject_id, status, solved_count, joined_at) VALUES ('q2', '概念不清', 'math', 'pending', 0, 1700000000000)",
  );
  raw.execute(
    "INSERT INTO review_history (question_id, result, reviewed_at) VALUES ('q1', 'solved', 1700000001000)",
  );
  raw.execute(
    "INSERT INTO question_boxes (id, question_id, page, layer, type, x, y, w, h, origin, updated_at) VALUES ('box-q2', 'q2', 1, 1, 'question', 0.1, 0.1, 0.5, 0.2, 'manual', 1700000000000)",
  );
  raw.execute("INSERT INTO settings VALUES ('schemaVersion', '4')");
  raw.execute('PRAGMA user_version = 4');
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

Future<List<Map<String, Object?>>> _rawRows(
  QuizDatabase db,
  String table, {
  String where = '',
}) async => (await db.customSelect('SELECT * FROM $table $where').get())
    .map((r) => r.data)
    .toList();

Future<QuizDatabase> _openMemoryDb() async {
  final db = await AppDatabase.openForTest();
  addTearDown(() async => db.close());
  return db;
}

/// 种子：1 道带 v5 新字段的题 + 1 条带新列的复习记录 + 1 条作答记录。
/// 返回导出的备份 JSON。
Future<Map<String, dynamic>> _seedAndExport(QuizDatabase db) async {
  await db
      .into(db.subjects)
      .insert(
        SubjectsCompanion.insert(id: 'math', name: '数学', color: 0xFF2E7CF6),
      );
  await AppDatabase.upsertQuestionInto(
    db,
    Question(
      id: 'q1',
      title: '函数定义域',
      subjectId: 'math',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      questionType: 'choice_single',
      questionTypeSource: 'auto',
      questionBackgroundTags: '材料',
      questionBackgroundTagsSource: 'auto',
      ocrFigures: '[{"x":0.1}]',
      correctOption: 'A',
      optionLabels: const ['A', 'B', 'C', 'D'],
      optionLabelsConfirmed: true,
      answerVersion: 2,
      contentVersion: 5,
    ),
  );
  await db.customUpdate(
    'INSERT INTO review_history (question_id, result, reviewed_at, cause_id, session_id, review_mode, verdict, verification_source, verification_status, submission_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    variables: [
      Variable.withString('q1'),
      Variable.withString('solved'),
      Variable.withInt(1700000001000),
      Variable.withString('cause-1'),
      Variable.withString('sess-1'),
      Variable.withString('到期复习'),
      Variable.withString('已解决'),
      Variable.withString('客观判分'),
      Variable.withString('已核验'),
      Variable.withString('sub-1'),
    ],
  );
  await db.customUpdate(
    'INSERT INTO attempts (id, question_id, session_id, mode, selected, correct, confidence, answer_version, content_version, status, cause_ids, duration_ms, submission_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    variables: [
      Variable.withString('att-1'),
      Variable.withString('q1'),
      Variable.withString('sess-1'),
      Variable.withString('专项练习'),
      Variable.withString('A'),
      Variable.withInt(1),
      Variable.withString('确定'),
      Variable.withInt(2),
      Variable.withInt(5),
      // 十四批 M2：attempts.status 枚举取自 PLAN-14-REV4.3（已提交 /
      // 已完成作答 / 跳过），'已判分' 不在枚举内，备份校验会拒绝；
      // 此处合成数据改用合法值（往返断言只关心值原样回来）。
      Variable.withString('已提交'),
      Variable.withString('["cause-1"]'),
      Variable.withInt(12000),
      Variable.withString('sub-a1'),
      Variable.withInt(1700000001000),
    ],
  );
  return jsonDecode(await AppDatabase.exportBackupJsonFrom(db))
      as Map<String, dynamic>;
}

void main() {
  group('十四批 M1：v4 → v7 迁移', () {
    test('v4 库打开即迁移到 v7：数据全保留，新列默认值正确，content_version 原值保留', () async {
      final tmp = await Directory.systemTemp.createTemp('b14-migrate-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = await _v4DbFile(tmp);
      expect(await AppDatabase.deleteLegacyDatabaseIfPresent(dbPath), isFalse);

      final db = await AppDatabase.openAt(dbPath);
      addTearDown(() async => db.close());
      expect(
        (await db.customSelect('PRAGMA user_version').get())
            .single
            .data['user_version'],
        7,
      );
      final settings = await _rawRows(db, 'settings');
      expect(
        settings.singleWhere((r) => r['key'] == 'schemaVersion')['value'],
        '7',
      );
      // 旧数据还在。
      final qs = await AppDatabase.allQuestionsFrom(db);
      expect(qs, hasLength(2));
      final q1 = qs.singleWhere((q) => q.id == 'q1');
      expect(q1.title, '迁移后还在的题');
      // 新列默认值：题型 NULL/来源未分类/背景 ''/图块 []/答案与选项标签
      // NULL/answer_version=1；content_version 原值 7 原样保留。
      expect(q1.questionType, isNull);
      expect(q1.questionTypeSource, 'unclassified');
      expect(q1.questionBackgroundTags, isEmpty);
      expect(q1.questionBackgroundTagsSource, 'unclassified');
      expect(q1.ocrFigures, '[]');
      expect(q1.correctOption, isNull);
      expect(q1.optionLabels, isNull);
      expect(q1.optionLabelsConfirmed, isFalse);
      expect(q1.answerVersion, 1);
      expect(q1.contentVersion, 7);
      // Win11 反馈包 5（v5→v6）：新列默认值 NULL（本夹具题无 ocr_raw，
      // 开库回填不产出内容）。
      expect(q1.optionContents, isNull);
      expect(q1.optionContentsParserVersion, isNull);
      // 旧复习记录还在，新增列全 NULL。
      final history = await _rawRows(db, 'review_history');
      expect(history, hasLength(1));
      expect(history.single['question_id'], 'q1');
      expect(history.single['result'], 'solved');
      for (final col in [
        'cause_id',
        'session_id',
        'review_mode',
        'verdict',
        'verification_status',
        'verification_source',
        'attempt_id',
        'submission_id',
      ]) {
        expect(history.single[col], isNull, reason: col);
      }
      // attempts 表存在且为空；question_type 索引存在。
      expect(await _rawRows(db, 'attempts'), isEmpty);
      final indexes = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_questions_question_type'",
          )
          .get();
      expect(indexes, hasLength(1));
    });

    test('旧 solved_count 三类：已治愈保留状态与复查日期；未治愈进度重置为 0；0 保持原值', () async {
      final tmp = await Directory.systemTemp.createTemp('b14-migrate-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = await _v4DbFile(tmp);
      final db = await AppDatabase.openAt(dbPath);
      addTearDown(() async => db.close());
      final rows = await _rawRows(
        db,
        'cause_records',
        where: 'ORDER BY cause',
      );
      expect(rows, hasLength(3));
      final solved = rows.singleWhere((r) => r['cause'] == '审题失误');
      expect(solved['status'], 'solved');
      expect(solved['solved_count'], 2);
      expect(solved['recheck_date'], 1700000005000);
      expect(solved['last_counted_success_at'], isNull);
      expect(solved['last_counted_session_id'], isNull);
      final inProgress = rows.singleWhere((r) => r['cause'] == '计算错误');
      expect(inProgress['status'], 'inProgress');
      expect(inProgress['solved_count'], 0);
      expect(inProgress['last_counted_success_at'], isNull);
      expect(inProgress['last_counted_session_id'], isNull);
      final pending = rows.singleWhere((r) => r['cause'] == '概念不清');
      expect(pending['status'], 'pending');
      expect(pending['solved_count'], 0);
    });

    test('cureChecks=2：旧 solved_count=1 不会通过一次新成功就治愈', () async {
      final tmp = await Directory.systemTemp.createTemp('b14-migrate-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = await _v4DbFile(tmp);
      final db = await AppDatabase.openAt(dbPath);
      addTearDown(() async => db.close());
      // 迁移后“计算错误”进度已重置为 0；一次新“已解决”后应为 1、仍未治愈。
      final written = await AppDatabase.recordSelfCheckInto(
        db,
        updated: CauseRecord(
          questionId: 'q1',
          cause: '计算错误',
          subjectId: 'math',
          joinedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ),
        questionId: 'q1',
        result: 'solved',
      );
      expect(written.solvedCount, 1);
      expect(written.status, isNot('solved'));
      final rows = await _rawRows(
        db,
        'cause_records',
        where: "WHERE cause = '计算错误'",
      );
      expect(rows.single['solved_count'], 1);
      expect(rows.single['status'], 'inProgress');
    });

    test('迁移后 DDL 与全新 v7 库逐字一致', () async {
      final tmp = await Directory.systemTemp.createTemp('b14-migrate-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final migratedPath = await _v4DbFile(tmp);
      final migrated = await AppDatabase.openAt(migratedPath);
      addTearDown(() async => migrated.close());
      final freshPath = p.join(tmp.path, 'fresh.db');
      final fresh = await AppDatabase.openAt(freshPath);
      addTearDown(() async => fresh.close());
      expect(await _allDdl(migratedPath), await _allDdl(freshPath));
    });
  });

  group('十四批 M1：删除语义（P1-3）', () {
    test('删题：review_history → attempts → cause_records → question_boxes → questions 同事务清除', () async {
      final db = await _openMemoryDb();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => AppDatabase.resetForTest());
      final repo = QuestionRepository(AppDatabase.instance);
      final q1 = Question(
        id: 'q1',
        title: '留下的题',
        subjectId: 'math',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      final q2 = Question(
        id: 'q2',
        title: '待删的题',
        subjectId: 'math',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      await AppDatabase.upsertQuestionInto(db, q1);
      await AppDatabase.upsertQuestionInto(db, q2);
      // q2 的关联行：复习记录、作答记录、错因记录、框。
      await db.customUpdate(
        'INSERT INTO review_history (question_id, result, reviewed_at, cause_id) VALUES (?, ?, ?, ?)',
        variables: [
          Variable.withString('q2'),
          Variable.withString('solved'),
          Variable.withInt(1700000001000),
          Variable.withString('cause-2'),
        ],
      );
      await db.customUpdate(
        'INSERT INTO attempts (id, question_id, session_id, mode, status, created_at) VALUES (?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('att-2'),
          Variable.withString('q2'),
          Variable.withString('sess-2'),
          Variable.withString('专项练习'),
          Variable.withString('已提交'),
          Variable.withInt(1700000001000),
        ],
      );
      await db
          .into(db.causeRecords)
          .insert(
            CauseRecordsCompanion.insert(
              questionId: 'q2',
              cause: '计算错误',
              subjectId: 'math',
              joinedAt: 1700000000000,
            ),
          );
      await db.customUpdate(
        'INSERT INTO question_boxes (id, question_id, page, layer, type, x, y, w, h, origin, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('box-q2'),
          Variable.withString('q2'),
          Variable.withInt(1),
          Variable.withInt(1),
          Variable.withString('question'),
          Variable.withReal(0.1),
          Variable.withReal(0.1),
          Variable.withReal(0.5),
          Variable.withReal(0.2),
          Variable.withString('manual'),
          Variable.withInt(1700000000000),
        ],
      );
      // q1 的一行复习记录（删 q2 时不动）。
      await db.customUpdate(
        'INSERT INTO review_history (question_id, result, reviewed_at) VALUES (?, ?, ?)',
        variables: [
          Variable.withString('q1'),
          Variable.withString('solved'),
          Variable.withInt(1700000001000),
        ],
      );

      await repo.delete(q2);

      expect(await _rawRows(db, 'questions', where: "WHERE id = 'q2'"), isEmpty);
      expect(
        await _rawRows(db, 'review_history', where: "WHERE question_id = 'q2'"),
        isEmpty,
      );
      expect(
        await _rawRows(db, 'attempts', where: "WHERE question_id = 'q2'"),
        isEmpty,
      );
      expect(
        await _rawRows(db, 'cause_records', where: "WHERE question_id = 'q2'"),
        isEmpty,
      );
      expect(
        await _rawRows(db, 'question_boxes', where: "WHERE question_id = 'q2'"),
        isEmpty,
      );
      // q1 及其复习记录不受影响。
      expect(await _rawRows(db, 'questions', where: "WHERE id = 'q1'"), hasLength(1));
      expect(
        await _rawRows(db, 'review_history', where: "WHERE question_id = 'q1'"),
        hasLength(1),
      );
    });
  });

  group('十四批 M1：v4 备份恢复默认值', () {
    test('sv4 备份恢复：新列走默认值，content_version 原值保留，attempts 为空', () async {
      final db = await _openMemoryDb();
      final decoded = await _seedAndExport(db);
      (decoded['_meta'] as Map<String, dynamic>)['schemaVersion'] = 4;
      decoded.remove('attempts');
      for (final row in decoded['questions'] as List) {
        final m = row as Map<String, dynamic>;
        for (final col in [
          'question_type',
          'question_type_source',
          'question_background_tags',
          'question_background_tags_source',
          'ocr_figures',
          'correct_option',
          'option_labels',
          'option_labels_confirmed',
          'answer_version',
        ]) {
          m.remove(col);
        }
      }
      for (final row in decoded['review_history'] as List) {
        final m = row as Map<String, dynamic>;
        for (final col in [
          'cause_id',
          'session_id',
          'review_mode',
          'verdict',
          'verification_status',
          'verification_source',
          'attempt_id',
          'submission_id',
        ]) {
          m.remove(col);
        }
      }
      for (final row in decoded['cause_records'] as List) {
        final m = row as Map<String, dynamic>;
        m.remove('last_counted_success_at');
        m.remove('last_counted_session_id');
      }
      await db.customUpdate('DELETE FROM questions');
      await db.customUpdate('DELETE FROM review_history');
      await db.customUpdate('DELETE FROM cause_records');
      await db.customUpdate('DELETE FROM attempts');
      await db.customUpdate('DELETE FROM settings');
      await AppDatabase.importBackupJsonInto(db, decoded);
      final q = (await AppDatabase.allQuestionsFrom(db)).single;
      expect(q.title, '函数定义域');
      expect(q.questionType, isNull);
      expect(q.questionTypeSource, 'unclassified');
      expect(q.questionBackgroundTags, isEmpty);
      expect(q.questionBackgroundTagsSource, 'unclassified');
      expect(q.ocrFigures, '[]');
      expect(q.correctOption, isNull);
      expect(q.optionLabels, isNull);
      expect(q.optionLabelsConfirmed, isFalse);
      expect(q.answerVersion, 1);
      expect(q.contentVersion, 5);
      final history = await _rawRows(db, 'review_history');
      expect(history, hasLength(1));
      for (final col in [
        'cause_id',
        'session_id',
        'review_mode',
        'verdict',
        'verification_status',
        'verification_source',
        'attempt_id',
        'submission_id',
      ]) {
        expect(history.single[col], isNull, reason: col);
      }
      expect(await _rawRows(db, 'attempts'), isEmpty);
    });

    test('sv5 往返：M1 新列与复习新字段原样回来（D-119）', () async {
      final db = await _openMemoryDb();
      final decoded = await _seedAndExport(db);
      await db.customUpdate('DELETE FROM questions');
      await db.customUpdate('DELETE FROM review_history');
      await db.customUpdate('DELETE FROM attempts');
      await db.customUpdate('DELETE FROM settings');
      await AppDatabase.importBackupJsonInto(db, decoded);
      final q = (await AppDatabase.allQuestionsFrom(db)).single;
      expect(q.questionType, 'choice_single');
      expect(q.questionTypeSource, 'auto');
      expect(q.questionBackgroundTags, '材料');
      expect(q.questionBackgroundTagsSource, 'auto');
      expect(q.ocrFigures, '[{"x":0.1}]');
      expect(q.correctOption, 'A');
      expect(q.optionLabels, ['A', 'B', 'C', 'D']);
      expect(q.optionLabelsConfirmed, isTrue);
      expect(q.answerVersion, 2);
      expect(q.contentVersion, 5);
      final history = await _rawRows(db, 'review_history');
      expect(history, hasLength(1));
      expect(history.single['cause_id'], 'cause-1');
      expect(history.single['session_id'], 'sess-1');
      expect(history.single['review_mode'], '到期复习');
      expect(history.single['verdict'], '已解决');
      expect(history.single['verification_source'], '客观判分');
      expect(history.single['verification_status'], '已核验');
      expect(history.single['submission_id'], 'sub-1');
    });
  });
}
