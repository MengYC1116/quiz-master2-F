// P5 测试：schema v8 + 迁移 + 事件幂等 + SQLite 落盘
//（实施方案 v2 §7、§8 P5 相关项；GPT 第五轮 P0-4/P0-5、第六轮补充第 1、3 项）。
//
// 全部用临时目录 / 内存库，不碰真实用户库；演示库只读复制品。
// v7 夹具 DDL 取自 v7 代码的 createTablesImpl（16 表 + 8 索引，
// 与 b13 的 _v3Ddl 同一做法）；v7 夹具数据按审计场景手写，期望数
// 在注释里算死，不靠口头说。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/state/review_notifier.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// v7 基线 DDL（16 表 + 8 索引，取自 v7 的 createTablesImpl；
/// P5 只加 fsrs_* 三表 + 1 索引，不改旧表 DDL）。
const _v7Ddl = [
  "CREATE TABLE subjects( id TEXT PRIMARY KEY, name TEXT NOT NULL, color INTEGER NOT NULL, cover_style TEXT NOT NULL DEFAULT 'plain', cover_color TEXT NOT NULL DEFAULT 'blue', english_name TEXT, english_name_manual INTEGER NOT NULL DEFAULT 0)",
  "CREATE TABLE questions( id TEXT PRIMARY KEY, title TEXT NOT NULL, subject_id TEXT NOT NULL, folder_ids TEXT NOT NULL DEFAULT '', exam_id TEXT, knowledge_ids TEXT NOT NULL DEFAULT '', error_types TEXT NOT NULL DEFAULT '', custom_error_types TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '', answer TEXT, explanation TEXT, notes TEXT, review_count INTEGER NOT NULL DEFAULT 0, is_organized INTEGER NOT NULL DEFAULT 0, is_demo INTEGER NOT NULL DEFAULT 0, is_favorite INTEGER NOT NULL DEFAULT 0, is_archived INTEGER NOT NULL DEFAULT 0, review_joined INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, slice_kind TEXT NOT NULL DEFAULT 'material', slice_text TEXT NOT NULL DEFAULT '', source_path TEXT, source_kind TEXT, source_page INTEGER, page_image_path TEXT, slice_path TEXT, slice_width INTEGER, slice_height INTEGER, ocr_raw TEXT, ocr_stem TEXT, ocr_split_status TEXT NOT NULL DEFAULT '未切分', ocr_manual_edited INTEGER NOT NULL DEFAULT 0, content_version INTEGER NOT NULL DEFAULT 0, question_type TEXT, question_type_source TEXT NOT NULL DEFAULT 'unclassified', question_background_tags TEXT NOT NULL DEFAULT '', question_background_tags_source TEXT NOT NULL DEFAULT 'unclassified', ocr_figures TEXT NOT NULL DEFAULT '[]', correct_option TEXT, option_labels TEXT, option_labels_confirmed INTEGER NOT NULL DEFAULT 0, answer_version INTEGER NOT NULL DEFAULT 1, answer_pending_recheck INTEGER NOT NULL DEFAULT 0, option_contents TEXT, option_contents_parser_version INTEGER)",
  "CREATE TABLE folders( id TEXT PRIMARY KEY, name TEXT NOT NULL, subject_id TEXT NOT NULL, parent_id TEXT, sort_order INTEGER NOT NULL DEFAULT 0)",
  "CREATE TABLE tags(id TEXT PRIMARY KEY, name TEXT NOT NULL)",
  "CREATE TABLE exams(id TEXT PRIMARY KEY, name TEXT NOT NULL, date INTEGER)",
  "CREATE TABLE knowledge_points( id TEXT PRIMARY KEY, subject_id TEXT NOT NULL, chapter TEXT NOT NULL, name TEXT NOT NULL)",
  "CREATE TABLE collect_tasks( id TEXT PRIMARY KEY, name TEXT NOT NULL, file_name TEXT NOT NULL, subject_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'queued', progress INTEGER NOT NULL DEFAULT 0, page_count INTEGER NOT NULL DEFAULT 1, page INTEGER NOT NULL DEFAULT 1, error TEXT, question_id TEXT, created_at INTEGER NOT NULL DEFAULT 0, source_path TEXT NOT NULL DEFAULT '', page_rotations TEXT NOT NULL DEFAULT '{}', source_hash TEXT)",
  "CREATE TABLE cause_records( id INTEGER PRIMARY KEY AUTOINCREMENT, question_id TEXT NOT NULL, cause TEXT NOT NULL, subject_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', solved_count INTEGER NOT NULL DEFAULT 0, last_check INTEGER, recheck_date INTEGER, remedy_history TEXT NOT NULL DEFAULT '', joined_at INTEGER NOT NULL, last_counted_success_at INTEGER, last_counted_session_id TEXT, UNIQUE(question_id, cause))",
  "CREATE TABLE review_state( id INTEGER PRIMARY KEY CHECK (id = 1), queue TEXT NOT NULL DEFAULT '', position INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL, session_id TEXT, mode TEXT, skips TEXT, per_question_state TEXT)",
  "CREATE TABLE review_history( id INTEGER PRIMARY KEY AUTOINCREMENT, question_id TEXT NOT NULL, result TEXT NOT NULL, reviewed_at INTEGER NOT NULL, cause_id TEXT, session_id TEXT, review_mode TEXT CHECK (review_mode IN ('到期复习')), verdict TEXT, verification_source TEXT, verification_status TEXT CHECK ((verification_status IS NULL AND verification_source IS NULL) OR (verification_status = '已核验' AND verification_source IN ('软件标准答案', '客观判分', '外部资料核对')) OR (verification_status = '未核验' AND verification_source = '未核验')), attempt_id TEXT, submission_id TEXT)",
  "CREATE TABLE attempts( id TEXT PRIMARY KEY, question_id TEXT NOT NULL, session_id TEXT NOT NULL, mode TEXT NOT NULL, selected TEXT, correct INTEGER, confidence TEXT, answer_version INTEGER NOT NULL DEFAULT 1, content_version INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL, cause_ids TEXT NOT NULL DEFAULT '[]', duration_ms INTEGER, submission_id TEXT UNIQUE, created_at INTEGER NOT NULL, UNIQUE(session_id, question_id))",
  "CREATE TABLE recent_tasks( id INTEGER PRIMARY KEY CHECK (id = 1), kind TEXT NOT NULL, subject_id TEXT NOT NULL, title TEXT NOT NULL, updated_at INTEGER NOT NULL)",
  "CREATE TABLE recently_viewed_questions( question_id TEXT PRIMARY KEY, viewed_at INTEGER NOT NULL)",
  "CREATE TABLE ocr_jobs( id TEXT PRIMARY KEY, question_id TEXT NOT NULL, crop_path TEXT, input_hash TEXT, status TEXT NOT NULL DEFAULT 'pending', attempt_count INTEGER NOT NULL DEFAULT 0, available_at INTEGER, started_at INTEGER, lease_until INTEGER, lease_token TEXT, last_error_code TEXT, last_error_message TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, completed_at INTEGER)",
  "CREATE TABLE saved_searches( id TEXT PRIMARY KEY, name TEXT NOT NULL, conditions TEXT NOT NULL DEFAULT '{}', created_at INTEGER NOT NULL)",
  "CREATE TABLE settings( key TEXT PRIMARY KEY, value TEXT NOT NULL)",
  "CREATE TABLE question_boxes( id TEXT PRIMARY KEY, collect_task_id TEXT, question_id TEXT, parent_box_id TEXT, page INTEGER NOT NULL DEFAULT 1 CHECK (page >= 1), layer INTEGER NOT NULL CHECK (layer IN (1, 2)), type TEXT NOT NULL CHECK (type IN ('question', 'stem', 'option', 'figure')), x REAL NOT NULL CHECK (x >= 0 AND x <= 1), y REAL NOT NULL CHECK (y >= 0 AND y <= 1), w REAL NOT NULL CHECK (w >= 0 AND w <= 1), h REAL NOT NULL CHECK (h >= 0 AND h <= 1), confidence REAL CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)), origin TEXT NOT NULL DEFAULT 'manual' CHECK (origin IN ('yolo', 'manual')), updated_at INTEGER NOT NULL)",
  'CREATE UNIQUE INDEX idx_review_history_submission ON review_history(submission_id)',
  'CREATE INDEX idx_questions_question_type ON questions(question_type)',
  'CREATE INDEX idx_ocr_jobs_question ON ocr_jobs(question_id)',
  'CREATE INDEX idx_ocr_jobs_pending ON ocr_jobs(status, available_at)',
  'CREATE INDEX idx_boxes_task_page ON question_boxes(collect_task_id, page)',
  'CREATE INDEX idx_boxes_question ON question_boxes(question_id)',
  'CREATE INDEX idx_boxes_parent ON question_boxes(parent_box_id)',
  'CREATE UNIQUE INDEX idx_boxes_one_layer1_per_question ON question_boxes(question_id) WHERE layer = 1 AND question_id IS NOT NULL',
];

// 审计场景的时间基线（毫秒时间戳，2026-01-01 起按秒排布，便于算 due）。
const _t1 = 1700000001000; // q1 第 1 次（答对）
const _t2 = 1700000002000; // q1 第 2 次（答错）
const _t3 = 1700000003000; // q1 第 3 次（答对）
const _tQ4 = 1700000001200; // q4 唯一一次（答对）
const _tQ2 = 1700000001500; // q2 正式答错
const _tQ2Null = 1700000001550; // q2 正式未判分（correct NULL）
const _tQ2Practice = 1700000001560; // q2 专项练习答对（不重放）
const _tQ3 = 1700000001600; // q3 正式答对，但内容版本不匹配
const _tQx = 1700000001700; // 题目已不存在的题的正式记录
const _tQ8 = 1700000001800; // q8 正式答对
const _tQ6 = 1700000002500; // q6 两次独立作答（同一毫秒、同一对错）

/// 造一个 v7 库文件：v7 DDL + user_version=7 + 审计场景数据。
/// 期望审计（见 migrateFsrsV7ToV8IntoImpl 的审计口径）：
/// - attempts 正式总量 12（q1×3、q2 正式×2、q3×1、q4×1、q6×2、q8×2、qx×1；
///   q2 的专项练习 1 条不计入正式总量）
/// - correct 为 NULL 1（q2 未判分）；内容版本不匹配 1（q3）；
///   题目不存在 1（qx）；作答时间无效 1（q8 的 created_at=0 那条）
/// - review_history 总量 2、正式 2、仅 history 有 1（q7；q1 那条
///   与 attempts 的 submission_id 相同，只算一次）
/// - 疑似重复 2 行 / 1 组（q6 同一毫秒同一对错两次独立作答——只审计
///   不合并，两次都要重放）
/// - 可重放 8（q1×3、q2×1、q4×1、q6×2、q8×1），跳过 2（q3、qx）
/// - 旧到期时间候选 2（q5、q7：已解决且有 recheck_date，但无卡）
/// - 建卡 5 道：q1、q4、q2、q8、q6（按首次重放顺序 card_id 1..5）
Future<String> _v7DbFile(Directory tmp) async {
  final dbPath = p.join(tmp.path, 'quiz-master2.db');
  final raw = sqlite3.sqlite3.open(dbPath);
  for (final ddl in _v7Ddl) {
    raw.execute(ddl);
  }
  raw.execute(
    "INSERT INTO subjects VALUES ('math', '数学', 4280391411, 'plain', 'blue', 'MATHEMATICS', 1)",
  );
  raw.execute(
    "INSERT INTO subjects VALUES ('english', '英语', 4280391411, 'plain', 'green', 'ENGLISH', 1)",
  );
  raw.execute(
    "INSERT INTO subjects VALUES ('politics', '政治', 4280391411, 'plain', 'red', 'POLITICS', 1)",
  );
  // 9 道题（q1..q9；内容版本各不相同，覆盖匹配/不匹配）。
  final questions = [
    ('q1', '函数极限', 'math', 1),
    ('q2', '求导数', 'math', 1),
    ('q3', '定积分', 'math', 2),
    ('q4', '学术词汇辨析', 'english', 0),
    ('q5', '马原', 'politics', 1),
    ('q6', '级数收敛', 'math', 1),
    ('q7', '线性代数', 'math', 1),
    ('q8', '阅读理解', 'english', 3),
    ('q9', '近代史', 'politics', 1),
  ];
  for (final (id, title, subjectId, cv) in questions) {
    raw.execute(
      'INSERT INTO questions (id, title, subject_id, error_types, '
      'created_at, is_organized, review_joined, content_version, '
      'question_type, correct_option, answer) '
      "VALUES ('$id', '$title', '$subjectId', '[\"概念不清\"]', "
      '1700000000000, 1, 1, $cv, '
      "'choice_single', 'B', 'B')",
    );
  }
  void attempt(
    String id,
    String qid,
    String session,
    String mode,
    int? correct,
    int cv,
    int createdAt,
    String submission,
  ) {
    raw.execute(
      'INSERT INTO attempts (id, question_id, session_id, mode, '
      'selected, correct, confidence, answer_version, content_version, '
      'status, cause_ids, submission_id, created_at) VALUES '
      "(?, ?, ?, ?, '[\"B\"]', ?, NULL, 1, ?, '已提交', '[\"概念不清\"]', ?, ?)",
      [id, qid, session, mode, correct, cv, submission, createdAt],
    );
  }

  attempt('att-q1-1', 'q1', 'sess-1', '到期复习', 1, 1, _t1, 'attsub-q1-1');
  attempt('att-q1-2', 'q1', 'sess-2', '到期复习', 0, 1, _t2, 'attsub-q1-2');
  attempt('att-q1-3', 'q1', 'sess-3', '到期复习', 1, 1, _t3, 'attsub-q1-3');
  attempt('att-q4-1', 'q4', 'sess-1', '到期复习', 1, 0, _tQ4, 'attsub-q4-1');
  attempt('att-q2-1', 'q2', 'sess-1', '到期复习', 0, 1, _tQ2, 'attsub-q2-1');
  attempt(
    'att-q2-null',
    'q2',
    'sess-2',
    '到期复习',
    null,
    1,
    _tQ2Null,
    'attsub-q2-null',
  );
  attempt(
    'att-q2-practice',
    'q2',
    'sess-p1',
    '专项练习',
    1,
    1,
    _tQ2Practice,
    'attsub-q2-practice',
  );
  attempt('att-q3-1', 'q3', 'sess-1', '到期复习', 1, 1, _tQ3, 'attsub-q3-1');
  attempt('att-qx-1', 'qx', 'sess-1', '到期复习', 1, 1, _tQx, 'attsub-qx-1');
  attempt('att-q8-1', 'q8', 'sess-1', '到期复习', 1, 3, _tQ8, 'attsub-q8-1');
  attempt('att-q8-bad', 'q8', 'sess-2', '到期复习', 1, 3, 0, 'attsub-q8-bad');
  attempt('att-q6-1', 'q6', 'sess-1', '到期复习', 1, 1, _tQ6, 'attsub-q6-1');
  attempt('att-q6-2', 'q6', 'sess-2', '到期复习', 1, 1, _tQ6, 'attsub-q6-2');
  // review_history：q7 只有 history（无 attempts）；q1 的与 attempts 同一事件。
  raw.execute(
    "INSERT INTO review_history (question_id, result, reviewed_at, cause_id, session_id, review_mode, verdict, verification_status, verification_source, attempt_id, submission_id) VALUES ('q7', 'solved', 1700000005000, 'q7|概念不清', 'sess-old', '到期复习', '已解决', '未核验', '未核验', NULL, 'hist-q7-1')",
  );
  raw.execute(
    "INSERT INTO review_history (question_id, result, reviewed_at, cause_id, session_id, review_mode, verdict, verification_status, verification_source, attempt_id, submission_id) VALUES ('q1', 'solved', $_t1, 'q1|概念不清', 'sess-1', '到期复习', '已解决', '已核验', '客观判分', 'att-q1-1', 'attsub-q1-1')",
  );
  // cause_records：q1 待解决；q5、q7 已解决且有复查日（旧到期时间候选）。
  raw.execute(
    "INSERT INTO cause_records (question_id, cause, subject_id, status, solved_count, last_check, recheck_date, remedy_history, joined_at) VALUES ('q1', '概念不清', 'math', 'pending', 0, NULL, NULL, '', 1700000000000)",
  );
  raw.execute(
    "INSERT INTO cause_records (question_id, cause, subject_id, status, solved_count, last_check, recheck_date, remedy_history, joined_at) VALUES ('q5', '概念不清', 'politics', 'solved', 2, 1700000000000, 1800000000000, '', 1700000000000)",
  );
  raw.execute(
    "INSERT INTO cause_records (question_id, cause, subject_id, status, solved_count, last_check, recheck_date, remedy_history, joined_at) VALUES ('q7', '概念不清', 'math', 'solved', 2, 1700000000000, 1800000000000, '', 1700000000000)",
  );
  // review_state：旧会话停在 selfCheck（升 v8 时的旧会话迁移用；
  // 迁移本身不动这行，只断言它原样保留）。
  final perQuestion = jsonEncode({
    'q1': {
      'question_submission_id': 'qs-1',
      'attempt_submission_id': 'attsub-1',
      'answer_version_at_start': 1,
      'content_version_at_start': 1,
      'stage': 'selfCheck',
      'attempt_id': null,
      'selected': null,
      'correct': null,
      'check_submitted': false,
      'notes_shown': false,
      'skips': 0,
      'deferred': false,
    },
  });
  raw.execute(
    "INSERT INTO review_state (id, queue, position, updated_at, session_id, mode, skips, per_question_state) VALUES (1, '[{\"q\":\"q1\",\"c\":\"概念不清\"}]', 0, 1700000006000, 'sess-old-1', '到期复习', NULL, ?)",
    [perQuestion],
  );
  raw.execute("INSERT INTO settings VALUES ('schemaVersion', '7')");
  raw.execute('PRAGMA user_version = 7');
  raw.close();
  return dbPath;
}

Future<List<Map<String, Object?>>> _rows(
  String dbPath,
  String sql,
) async {
  final probe = sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
  try {
    return probe.select(sql).map((r) => Map<String, Object?>.from(r)).toList();
  } finally {
    probe.close();
  }
}

Future<int> _count(String dbPath, String sql) async =>
    (await _rows(dbPath, sql)).first.values.first as int;

/// 确定性调度器（fuzzing 关）+ SQLite store，绑指定库。
FsrsReviewScheduler _testScheduler(QuizDatabase db) => FsrsReviewScheduler(
  config: const SchedulerConfig(enableFuzzing: false),
  store: SqliteCardStore.forDatabase(db),
);

/// save 时抛错的 store 装饰器（事务回滚测试用：卡片保存失败时，
/// attempts 行与事件账本必须一起回滚）。
class _ThrowingStore implements CardStore {
  _ThrowingStore(this.inner);
  final SqliteCardStore inner;

  @override
  Future<int> allocateCardId(String questionId) =>
      inner.allocateCardId(questionId);

  @override
  Future<StoredCard?> load(String questionId) => inner.load(questionId);

  @override
  Future<void> save(StoredCard card) async {
    throw StateError('boom-save');
  }

  @override
  Future<List<StoredCard>> loadAll() => inner.loadAll();

  @override
  Future<bool> hasProcessedEvent(String eventId) =>
      inner.hasProcessedEvent(eventId);

  @override
  Future<void> markEventProcessed(String eventId) =>
      inner.markEventProcessed(eventId);
}

Question _q(
  String id, {
  String subjectId = 'math',
  int contentVersion = 1,
  String? ocrStem,
  String? answer,
  String? explanation,
  List<String>? tags,
}) => Question(
  id: id,
  title: '题 $id',
  subjectId: subjectId,
  errorTypes: const ['概念不清'],
  createdAt: DateTime(2026, 11, 8),
  isOrganized: true,
  reviewJoined: true,
  sliceKind: 'material',
  sliceText: '题：$id',
  contentVersion: contentVersion,
  questionType: 'choice_single',
  optionLabels: const ['A', 'B', 'C', 'D'],
  correctOption: 'B',
  answer: answer ?? 'B',
  ocrStem: ocrStem ?? '题干 $id',
  explanation: explanation ?? '解析 $id',
  tags: tags ?? const [],
);

AttemptData _attempt({
  required String id,
  required String questionId,
  required String sessionId,
  required String mode,
  int? correct,
  int contentVersion = 1,
  required String submissionId,
  required int createdAt,
}) => AttemptData(
  id: id,
  questionId: questionId,
  sessionId: sessionId,
  mode: mode,
  selected: const ['B'],
  correct: correct,
  confidence: null,
  answerVersion: 1,
  contentVersion: contentVersion,
  status: '已提交',
  causeIds: const ['概念不清'],
  submissionId: submissionId,
  createdAt: createdAt,
);

void main() {
  group('P5 schema v8', () {
    test('全新 v8 库：三张新表 + due 索引就位，user_version=8', () async {
      final tmp = await Directory.systemTemp.createTemp('p5-schema-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = p.join(tmp.path, 'quiz-master2.db');
      final db = await AppDatabase.openAt(dbPath);
      await db.close();
      expect(await _count(dbPath, 'PRAGMA user_version'), 8);
      final names = (await _rows(
        dbPath,
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
      )).map((r) => r['name'] as String).toList();
      expect(names, containsAll(['fsrs_cards', 'fsrs_events', 'fsrs_migration_log']));
      final indexes = (await _rows(
        dbPath,
        "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_fsrs_cards_due'",
      )).length;
      expect(indexes, 1);
      final settings = await _rows(
        dbPath,
        "SELECT value FROM settings WHERE key = 'schemaVersion'",
      );
      expect(settings.single['value'], '8');
      // 全新库的迁移日志：attempts 为空，审计全零；开库两步各写一行
      // completed（v7→v8 迁移 + 跟进批第 1 项缺卡补建，后者本次无题可补）。
      final logs = await _rows(
        dbPath,
        'SELECT * FROM fsrs_migration_log ORDER BY id ASC',
      );
      expect(logs.length, 2);
      expect(
        logs.map((r) => r['source']).toList(),
        ['v7→v8', 'v8-backfill-missing-cards'],
      );
      expect(logs.map((r) => r['status']).toSet(), {'completed'});
      final audit =
          jsonDecode(logs.first['audit_json'] as String)
              as Map<String, dynamic>;
      expect(audit['attemptsFormalTotal'], 0);
      expect(audit['deterministicReplay'], isTrue);
      final backfillAudit =
          jsonDecode(logs.last['audit_json'] as String)
              as Map<String, dynamic>;
      expect(backfillAudit['backfilledCount'], 0);
      expect(backfillAudit['skippedWithCardCount'], 0);
    });

    test('内存库建表即 v8：三张新表都在', () async {
      final db = await AppDatabase.openForTest();
      addTearDown(() async => db.close());
      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'fsrs_%'",
          )
          .get();
      expect(
        tables.map((r) => r.data['name'] as String).toList()..sort(),
        ['fsrs_cards', 'fsrs_events', 'fsrs_migration_log'],
      );
    });
  });

  group('P5 v7 真实库升 v8：迁移', () {
    test('审计数正确、只从 attempts 重放、卡片与关系正确', () async {
      final tmp = await Directory.systemTemp.createTemp('p5-migrate-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = await _v7DbFile(tmp);
      // 迁移前快照：旧表行数与旧会话行（迁移后必须原样保留）。
      final attemptsBefore = await _count(dbPath, 'SELECT COUNT(*) FROM attempts');
      final historyBefore = await _count(
        dbPath,
        'SELECT COUNT(*) FROM review_history',
      );
      final stateBefore = await _rows(dbPath, 'SELECT * FROM review_state');
      expect(attemptsBefore, 13); // 12 正式 + 1 专项
      expect(historyBefore, 2);

      final db = await AppDatabase.openAt(dbPath);
      addTearDown(() async => db.close());
      expect(await _count(dbPath, 'PRAGMA user_version'), 8);

      // 审计日志：数字与种子场景逐项一致。开库写两行 completed：
      // v7→v8 重放审计 + 跟进批第 1 项缺卡补建（q3/q5/q7/q9 无卡可重放，
      // 补建各补一张未开始新卡；5 道重放出卡的题计入跳过）。
      final logs = await _rows(
        dbPath,
        'SELECT * FROM fsrs_migration_log ORDER BY id ASC',
      );
      expect(logs.length, 2);
      final v7v8Log = logs.firstWhere((r) => r['source'] == 'v7→v8');
      expect(v7v8Log['replayed_count'], 8);
      expect(v7v8Log['skipped_count'], 2);
      final audit =
          jsonDecode(v7v8Log['audit_json'] as String) as Map<String, dynamic>;
      final backfillLog = logs.firstWhere(
        (r) => r['source'] == 'v8-backfill-missing-cards',
      );
      expect(backfillLog['replayed_count'], 4);
      expect(backfillLog['skipped_count'], 5);
      final backfillAudit =
          jsonDecode(backfillLog['audit_json'] as String)
              as Map<String, dynamic>;
      expect(
        (backfillAudit['backfilledQuestionIds'] as List).toSet(),
        {'q3', 'q5', 'q7', 'q9'},
      );
      expect(audit['attemptsFormalTotal'], 12);
      expect(audit['attemptsFormalNullCorrect'], 1);
      expect(audit['attemptsFormalVersionMismatch'], 1);
      expect(audit['attemptsFormalNoQuestion'], 1);
      expect(audit['attemptsFormalBadTime'], 1);
      expect(audit['reviewHistoryTotal'], 2);
      expect(audit['reviewHistoryFormal'], 2);
      expect(audit['reviewHistoryOnly'], 1);
      expect(audit['suspectedDuplicateRows'], 2);
      expect(audit['suspectedDuplicateGroups'], 1);
      expect(audit['eligibleCount'], 8);
      expect(audit['replayedCount'], 8);
      expect(audit['skippedCount'], 2);
      expect(audit['deterministicReplay'], isTrue);
      // 审计账算得平：正式总量 = 可重放 + 跳过 + 未判分 + 时间无效。
      expect(
        audit['attemptsFormalTotal'],
        audit['eligibleCount'] +
            audit['skippedCount'] +
            audit['attemptsFormalNullCorrect'] +
            audit['attemptsFormalBadTime'],
      );
      // 旧到期时间候选：q5、q7（有可信旧复查日但无卡，只记录不伪造）。
      final legacy = (audit['legacyDueCandidates'] as List)
          .map((e) => (e as Map)['question_id'] as String)
          .toList()
        ..sort();
      expect(legacy, ['q5', 'q7']);

      // 卡片：重放只建 5 张（q1/q4/q2/q8/q6），card_id 按首次重放顺序 1..5；
      // 跟进批第 1 项补建再给无卡的 q3/q5/q7/q9 各补一张未开始新卡
      // （card_id 6..9，按题 id 升序，first_reviewed_at 为空）。
      final cards = await _rows(
        dbPath,
        'SELECT question_id, card_id, content_version, first_reviewed_at, next_due_at FROM fsrs_cards ORDER BY card_id ASC',
      );
      expect(
        cards.map((r) => r['question_id']).toList(),
        ['q1', 'q4', 'q2', 'q8', 'q6', 'q3', 'q5', 'q7', 'q9'],
      );
      expect(
        cards.map((r) => r['card_id']).toList(),
        [1, 2, 3, 4, 5, 6, 7, 8, 9],
      );
      final byQ = {for (final c in cards) c['question_id'] as String: c};
      expect(byQ['q1']!['first_reviewed_at'], _t1);
      expect(byQ['q1']!['content_version'], 1);
      expect(byQ['q4']!['first_reviewed_at'], _tQ4);
      expect(byQ['q4']!['content_version'], 0);
      expect(byQ['q2']!['first_reviewed_at'], _tQ2);
      expect(byQ['q8']!['first_reviewed_at'], _tQ8);
      expect(byQ['q8']!['content_version'], 3);
      expect(byQ['q6']!['first_reviewed_at'], _tQ6);
      // q3（版本不匹配）、q5/q7/q9（无可信正式历史）：重放不伪造历史，
      // 没有重放出的卡；跟进批第 1 项补建给它们各补一张未开始新卡
      // （first_reviewed_at 为空，不是重放出的历史状态）。
      for (final id in ['q3', 'q5', 'q7', 'q9']) {
        expect(byQ[id]!['first_reviewed_at'], isNull);
      }
      // q4 单次 Good：间隔 2 天（P1 官方向量，全 Good 链首间隔）。
      final q4Due = byQ['q4']!['next_due_at'] as int;
      expect(
        DateTime.fromMillisecondsSinceEpoch(q4Due, isUtc: true)
            .difference(DateTime.fromMillisecondsSinceEpoch(_tQ4, isUtc: true))
            .inDays,
        2,
      );
      // 首次呈现字段：迁移不伪造，全部为空。
      final presented = await _rows(
        dbPath,
        'SELECT COUNT(*) AS n FROM fsrs_cards WHERE first_presented_at IS NOT NULL',
      );
      expect(presented.single['n'], 0);

      // 旧表旧数据一律保留：attempts、review_history 行数不变，
      // review_state 旧会话行原样保留（不删、不改写）。
      expect(await _count(dbPath, 'SELECT COUNT(*) FROM attempts'), attemptsBefore);
      expect(
        await _count(dbPath, 'SELECT COUNT(*) FROM review_history'),
        historyBefore,
      );
      final stateAfter = await _rows(dbPath, 'SELECT * FROM review_state');
      expect(stateAfter, stateBefore);
      // 9 道题都在。
      expect(await _count(dbPath, 'SELECT COUNT(*) FROM questions'), 9);
      // attempts 事实与 fsrs_cards 状态核对一致。
      expect(await verifyFsrsConsistencyInto(db), isEmpty);

      // 迁移可重复验证：再跑一次是 no-op，不重复建卡、不重复记日志。
      final second = await migrateFsrsV7ToV8IntoImpl(db);
      expect(second['status'], 'already_migrated');
      expect(await _count(dbPath, 'SELECT COUNT(*) FROM fsrs_cards'), 9);
      expect(
        await _count(dbPath, 'SELECT COUNT(*) FROM fsrs_migration_log'),
        2,
      );
      // 补建同样幂等：第二遍直接跳过，不写第二行日志。
      final secondBackfill = await backfillMissingFsrsCardsIntoImpl(db);
      expect(secondBackfill['status'], 'already_backfilled');
      expect(
        await _count(dbPath, 'SELECT COUNT(*) FROM fsrs_migration_log'),
        2,
      );
      expect(await verifyFsrsConsistencyInto(db), isEmpty);
    });

    test('两份相同 v7 库迁移结果逐字一致（确定性重放）', () async {
      final tmp = await Directory.systemTemp.createTemp('p5-determinism-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final pathA = await _v7DbFile(Directory(p.join(tmp.path, 'a'))
        ..createSync(recursive: true));
      final pathB = await _v7DbFile(Directory(p.join(tmp.path, 'b'))
        ..createSync(recursive: true));
      final dbA = await AppDatabase.openAt(pathA);
      final dbB = await AppDatabase.openAt(pathB);
      addTearDown(() async => dbA.close());
      addTearDown(() async => dbB.close());
      // 确定性只针对重放出的卡：补建的新卡 due 取开库当时时间，
      // 两次开库的毫秒不同，不逐字比较；只比补建题 id 与未开始状态一致。
      final cardsA = await _rows(
        pathA,
        'SELECT question_id, card_state_json, next_due_at FROM fsrs_cards WHERE first_reviewed_at IS NOT NULL ORDER BY question_id',
      );
      final cardsB = await _rows(
        pathB,
        'SELECT question_id, card_state_json, next_due_at FROM fsrs_cards WHERE first_reviewed_at IS NOT NULL ORDER BY question_id',
      );
      expect(cardsA, cardsB);
      final freshA = await _rows(
        pathA,
        'SELECT question_id FROM fsrs_cards WHERE first_reviewed_at IS NULL ORDER BY question_id',
      );
      final freshB = await _rows(
        pathB,
        'SELECT question_id FROM fsrs_cards WHERE first_reviewed_at IS NULL ORDER BY question_id',
      );
      expect(
        freshA.map((r) => r['question_id']).toList(),
        ['q3', 'q5', 'q7', 'q9'],
      );
      expect(freshA, freshB);
    });

    test('真实演示库 v2 复制品：9 道题都在，链式升到 v8', () async {
      if (!Platform.isLinux) {
        markTestSkipped('演示库只在 Linux 开发机路径下，Win11 无此文件');
        return;
      }
      final tmp = await Directory.systemTemp.createTemp('p5-demo-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      // 只读复制品：绝不动原库（~/.local/share/quiz-master2/quiz-master2.db）。
      final src = File(
        '${Platform.environment['HOME']}/.local/share/quiz-master2/quiz-master2.db',
      );
      expect(src.existsSync(), isTrue, reason: '演示库原文件不存在');
      final dbPath = p.join(tmp.path, 'quiz-master2.db');
      await src.copy(dbPath);
      final db = await AppDatabase.openAt(dbPath);
      addTearDown(() async => db.close());
      expect(await _count(dbPath, 'PRAGMA user_version'), 8);
      expect(await _count(dbPath, 'SELECT COUNT(*) FROM questions'), 9);
      // 开库写两行 completed：v7→v8 重放 + 跟进批第 1 项缺卡补建。
      final logs = await _rows(dbPath, 'SELECT * FROM fsrs_migration_log');
      expect(logs.length, 2);
      expect(logs.map((r) => r['status']).toSet(), {'completed'});
      expect(
        logs.map((r) => r['source']).toSet(),
        {'v7→v8', 'v8-backfill-missing-cards'},
      );
    });
  });

  group('P5 事务双写 + 事件幂等', () {
    late QuizDatabase db;
    late QuestionRepository repo;
    late FsrsReviewScheduler scheduler;

    setUp(() async {
      db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      repo = QuestionRepository(AppDatabase.instance);
      scheduler = _testScheduler(db);
      await AppDatabase.upsertQuestionInto(db, _q('q1', contentVersion: 2));
      await AppDatabase.upsertQuestionInto(db, _q('q2', contentVersion: 1));
    });

    tearDown(() async {
      await AppDatabase.resetForTest();
    });

    test('同一 eventId 重复提交：attempts 一行、卡片只推进一次', () async {
      final reviewedAt = DateTime.utc(2026, 11, 25, 10);
      final attempt = _attempt(
        id: 'att-1',
        questionId: 'q1',
        sessionId: 'sess-1',
        mode: '到期复习',
        correct: 1,
        contentVersion: 2,
        submissionId: 'attsub-1',
        createdAt: reviewedAt.millisecondsSinceEpoch,
      );
      final first = await repo.submitReviewCheck(
        attempt: attempt,
        result: ReviewResult.good,
        reviewedAt: reviewedAt,
        eventId: 'attsub-1',
        scheduler: scheduler,
      );
      expect(first.attemptId, 'att-1');
      expect(first.nextDue, isNotNull);
      final cardBefore = (await db
              .customSelect(
                'SELECT card_state_json, next_due_at FROM fsrs_cards WHERE question_id = ?',
                variables: [Variable.withString('q1')],
              )
              .getSingle())
          .data;
      // 同一 eventId 再提交一次（重复点击 / 崩溃恢复重放）。
      final second = await repo.submitReviewCheck(
        attempt: attempt,
        result: ReviewResult.good,
        reviewedAt: reviewedAt,
        eventId: 'attsub-1',
        scheduler: scheduler,
      );
      expect(second.attemptId, 'att-1');
      expect(second.nextDue, first.nextDue);
      expect(
        await db
            .customSelect('SELECT COUNT(*) AS n FROM attempts')
            .getSingle()
            .then((r) => r.data['n']),
        1,
      );
      final cardAfter = (await db
              .customSelect(
                'SELECT card_state_json, next_due_at FROM fsrs_cards WHERE question_id = ?',
                variables: [Variable.withString('q1')],
              )
              .getSingle())
          .data;
      expect(cardAfter, cardBefore);
      expect(
        await db
            .customSelect(
              "SELECT COUNT(*) AS n FROM fsrs_events WHERE event_id = 'attsub-1'",
            )
            .getSingle()
            .then((r) => r.data['n']),
        1,
      );
      // 卡片内容版本按作答版本回填（调度器本身不知道题目版本）。
      final cardRow = (await db
              .customSelect(
                'SELECT content_version, first_reviewed_at FROM fsrs_cards WHERE question_id = ?',
                variables: [Variable.withString('q1')],
              )
              .getSingle())
          .data;
      expect(cardRow['content_version'], 2);
      expect(
        cardRow['first_reviewed_at'],
        reviewedAt.millisecondsSinceEpoch,
      );
      expect(await verifyFsrsConsistencyInto(db), isEmpty);
    });

    test('事务失败：卡片保存失败时 attempts 行与事件一起回滚，重试成功', () async {
      final reviewedAt = DateTime.utc(2026, 11, 25, 10);
      final throwingScheduler = FsrsReviewScheduler(
        config: const SchedulerConfig(enableFuzzing: false),
        store: _ThrowingStore(SqliteCardStore.forDatabase(db)),
      );
      final attempt = _attempt(
        id: 'att-2',
        questionId: 'q2',
        sessionId: 'sess-2',
        mode: '到期复习',
        correct: 0,
        contentVersion: 1,
        submissionId: 'attsub-2',
        createdAt: reviewedAt.millisecondsSinceEpoch,
      );
      // P2 报告的窗口：attempts 已写、FSRS 没写成——整笔回滚，什么都不留。
      await expectLater(
        repo.submitReviewCheck(
          attempt: attempt,
          result: ReviewResult.again,
          reviewedAt: reviewedAt,
          eventId: 'attsub-2',
          scheduler: throwingScheduler,
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        await db
            .customSelect('SELECT COUNT(*) AS n FROM attempts')
            .getSingle()
            .then((r) => r.data['n']),
        0,
      );
      expect(
        await db
            .customSelect('SELECT COUNT(*) AS n FROM fsrs_cards')
            .getSingle()
            .then((r) => r.data['n']),
        0,
      );
      expect(
        await db
            .customSelect('SELECT COUNT(*) AS n FROM fsrs_events')
            .getSingle()
            .then((r) => r.data['n']),
        0,
      );
      // 同一 eventId 重试：是第一次提交，不是第二次推进。
      final retried = await repo.submitReviewCheck(
        attempt: attempt,
        result: ReviewResult.again,
        reviewedAt: reviewedAt,
        eventId: 'attsub-2',
        scheduler: scheduler,
      );
      expect(retried.attemptId, 'att-2');
      expect(
        await db
            .customSelect('SELECT COUNT(*) AS n FROM attempts')
            .getSingle()
            .then((r) => r.data['n']),
        1,
      );
      expect(await verifyFsrsConsistencyInto(db), isEmpty);
    });

    test('专项练习与未判分：只写 attempts，不建卡、不改到期', () async {
      final at = DateTime.utc(2026, 11, 25, 10);
      final practice = _attempt(
        id: 'att-p1',
        questionId: 'q1',
        sessionId: 'sess-p1',
        mode: '专项练习',
        correct: 0,
        contentVersion: 2,
        submissionId: 'attsub-p1',
        createdAt: at.millisecondsSinceEpoch,
      );
      final r1 = await repo.submitReviewCheck(
        attempt: practice,
        result: null,
        reviewedAt: at,
        eventId: 'attsub-p1',
        scheduler: scheduler,
      );
      expect(r1.nextDue, isNull);
      expect(
        await db
            .customSelect('SELECT COUNT(*) AS n FROM fsrs_cards')
            .getSingle()
            .then((r) => r.data['n']),
        0,
      );
      // 未判分（correct NULL）绝不写成 false；也不推进 FSRS。
      final ungraded = _attempt(
        id: 'att-u1',
        questionId: 'q2',
        sessionId: 'sess-1',
        mode: '到期复习',
        correct: null,
        contentVersion: 1,
        submissionId: 'attsub-u1',
        createdAt: at.millisecondsSinceEpoch,
      );
      await repo.submitReviewCheck(
        attempt: ungraded,
        result: null,
        reviewedAt: at,
        eventId: 'attsub-u1',
        scheduler: scheduler,
      );
      final row = (await db
              .customSelect(
                'SELECT correct, confidence FROM attempts WHERE id = ?',
                variables: [Variable.withString('att-u1')],
              )
              .getSingle())
          .data;
      expect(row['correct'], isNull);
      expect(row['confidence'], isNull);
      expect(
        await db
            .customSelect('SELECT COUNT(*) AS n FROM fsrs_cards')
            .getSingle()
            .then((r) => r.data['n']),
        0,
      );
    });

    test('包 5：submitReviewCheck 不写 review_history（旧行冻结）', () async {
      // 旧行先有一条历史事实；新流程提交一次正式作答后，review_history
      // 行数与内容都不变（新流程只写 attempts + FSRS 卡片 + 事件账本）。
      await db.customInsert(
        "INSERT INTO review_history (question_id, result, reviewed_at) "
        "VALUES ('q1', 'solved', 1700000001000)",
      );
      final reviewedAt = DateTime.utc(2026, 11, 25, 10);
      await repo.submitReviewCheck(
        attempt: _attempt(
          id: 'att-h1',
          questionId: 'q1',
          sessionId: 'sess-h1',
          mode: '到期复习',
          correct: 1,
          contentVersion: 2,
          submissionId: 'attsub-h1',
          createdAt: reviewedAt.millisecondsSinceEpoch,
        ),
        result: ReviewResult.good,
        reviewedAt: reviewedAt,
        eventId: 'attsub-h1',
        scheduler: scheduler,
      );
      expect(
        await db
            .customSelect('SELECT COUNT(*) AS n FROM review_history')
            .getSingle()
            .then((r) => r.data['n']),
        1,
      );
      final row = (await db
              .customSelect(
                'SELECT result, reviewed_at FROM review_history WHERE question_id = ?',
                variables: [Variable.withString('q1')],
              )
              .getSingle())
          .data;
      expect(row['result'], 'solved');
      expect(row['reviewed_at'], 1700000001000);
      expect(await verifyFsrsConsistencyInto(db), isEmpty);
    });
  });

  group('P5 首次呈现', () {
    late QuizDatabase db;
    late QuestionRepository repo;

    setUp(() async {
      db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      repo = QuestionRepository(AppDatabase.instance);
      await AppDatabase.upsertQuestionInto(db, _q('q9', contentVersion: 2));
    });

    tearDown(() async {
      await AppDatabase.resetForTest();
    });

    Future<Map<String, Object?>> cardRow(String qid) async =>
        (await db
                .customSelect(
                  'SELECT * FROM fsrs_cards WHERE question_id = ?',
                  variables: [Variable.withString(qid)],
                )
                .getSingle())
            .data;

    test('首次显示写一次：退出恢复、第二天都不重计；新版本重计', () async {
      final t1 = DateTime.utc(2026, 11, 25, 9);
      expect(
        await repo.recordFirstPresented(
          questionId: 'q9',
          presentedAtUtc: t1,
          localDate: '2026-11-25',
          contentVersion: 2,
        ),
        isTrue,
      );
      var row = await cardRow('q9');
      expect(row['first_presented_at'], t1.millisecondsSinceEpoch);
      expect(row['first_presented_local_date'], '2026-11-25');
      expect(row['first_presented_content_version'], 2);
      expect(row['first_reviewed_at'], isNull); // 只呈现、没作答
      // 第二天再看：不重计。
      expect(
        await repo.recordFirstPresented(
          questionId: 'q9',
          presentedAtUtc: DateTime.utc(2026, 11, 26, 9),
          localDate: '2026-11-26',
          contentVersion: 2,
        ),
        isFalse,
      );
      row = await cardRow('q9');
      expect(row['first_presented_at'], t1.millisecondsSinceEpoch);
      expect(row['first_presented_local_date'], '2026-11-25');
      // 内容新版本：重新计。
      final t2 = DateTime.utc(2026, 11, 27, 9);
      expect(
        await repo.recordFirstPresented(
          questionId: 'q9',
          presentedAtUtc: t2,
          localDate: '2026-11-27',
          contentVersion: 3,
        ),
        isTrue,
      );
      row = await cardRow('q9');
      expect(row['first_presented_at'], t2.millisecondsSinceEpoch);
      expect(row['first_presented_local_date'], '2026-11-27');
      expect(row['first_presented_content_version'], 3);
    });

    test('内容重置清掉首次呈现，card_id 不变', () async {
      final scheduler = _testScheduler(db);
      await scheduler.initializeQuestion('q9');
      await repo.recordFirstPresented(
        questionId: 'q9',
        presentedAtUtc: DateTime.utc(2026, 11, 25, 9),
        localDate: '2026-11-25',
        contentVersion: 2,
      );
      final before = await cardRow('q9');
      await scheduler.resetQuestion('q9');
      final after = await cardRow('q9');
      expect(after['card_id'], before['card_id']);
      expect(after['first_presented_at'], isNull);
      expect(after['first_presented_local_date'], isNull);
      expect(after['first_presented_content_version'], isNull);
      expect(after['first_reviewed_at'], isNull);
    });
  });

  group('P5 内容修改重置（upsert 钩子）', () {
    late QuizDatabase db;
    late FsrsReviewScheduler scheduler;

    setUp(() async {
      db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      scheduler = _testScheduler(db);
      await AppDatabase.upsertQuestionInto(db, _q('q1', contentVersion: 1));
    });

    tearDown(() async {
      await AppDatabase.resetForTest();
    });

    Future<Map<String, Object?>> cardRow(String qid) async =>
        (await db
                .customSelect(
                  'SELECT * FROM fsrs_cards WHERE question_id = ?',
                  variables: [Variable.withString(qid)],
                )
                .getSingle())
            .data;

    Future<void> submitGood() async {
      final at = DateTime.utc(2026, 11, 25, 10);
      final repo = QuestionRepository(AppDatabase.instance);
      await repo.submitReviewCheck(
        attempt: _attempt(
          id: 'att-1',
          questionId: 'q1',
          sessionId: 'sess-1',
          mode: '到期复习',
          correct: 1,
          contentVersion: 1,
          submissionId: 'attsub-1',
          createdAt: at.millisecondsSinceEpoch,
        ),
        result: ReviewResult.good,
        reviewedAt: at,
        eventId: 'attsub-1',
        scheduler: scheduler,
      );
    }

    test('改题干 → 重置：card_id 不变，首次复习清空，旧记录保留', () async {
      await submitGood();
      final before = await cardRow('q1');
      expect(before['first_reviewed_at'], isNotNull);
      expect(before['content_version'], 1);
      final q = (await AppDatabase.allQuestionsFrom(db)).singleWhere(
        (e) => e.id == 'q1',
      );
      await AppDatabase.upsertQuestionInto(
        db,
        q.copyWith(ocrStem: '改过的题干'),
      );
      final after = await cardRow('q1');
      expect(after['card_id'], before['card_id']);
      expect(after['first_reviewed_at'], isNull);
      expect(after['content_version'], 2); // upsert 抬了一版
      expect(after['next_due_at'], isNot(before['next_due_at']));
      // 旧作答事实保留（不参与新版本重放）。
      expect(
        await db
            .customSelect('SELECT COUNT(*) AS n FROM attempts')
            .getSingle()
            .then((r) => r.data['n']),
        1,
      );
      // 重置后首次新流程正式复习重建 FSRS 状态（与旧记录核对一致）。
      await scheduler.recordAnswer(
        'q1',
        ReviewResult.good,
        DateTime.utc(2026, 11, 26, 10),
        'evt-after-reset',
      );
      final rebuilt = await cardRow('q1');
      expect(rebuilt['first_reviewed_at'], isNotNull);
      expect(rebuilt['card_id'], before['card_id']);
    });

    test('只改分类标签 → 保留；只改解析 → 保留；改标准答案 → 重置', () async {
      await submitGood();
      final before = await cardRow('q1');
      var q = (await AppDatabase.allQuestionsFrom(db)).singleWhere(
        (e) => e.id == 'q1',
      );
      await AppDatabase.upsertQuestionInto(db, q.copyWith(tags: ['易错']));
      expect((await cardRow('q1'))['first_reviewed_at'], isNotNull);
      q = (await AppDatabase.allQuestionsFrom(db)).singleWhere(
        (e) => e.id == 'q1',
      );
      await AppDatabase.upsertQuestionInto(db, q.copyWith(explanation: '新解析'));
      expect((await cardRow('q1'))['first_reviewed_at'], isNotNull);
      q = (await AppDatabase.allQuestionsFrom(db)).singleWhere(
        (e) => e.id == 'q1',
      );
      await AppDatabase.upsertQuestionInto(db, q.copyWith(answer: 'C'));
      final after = await cardRow('q1');
      expect(after['card_id'], before['card_id']);
      expect(after['first_reviewed_at'], isNull);
    });
  });

  group('P5 SqliteCardStore', () {
    test('allocate 稳定映射、save/load 往返、first_presented 字段保留', () async {
      final db = await AppDatabase.openForTest();
      addTearDown(() async => db.close());
      final store = SqliteCardStore.forDatabase(db);
      expect(await store.allocateCardId('qa'), 1);
      // 未落盘前不占位：qb 此时也算得 MAX+1 = 1（与内存实现不同；
      // 真正分配发生在 save 时的冲突重算，见 _saveCardInto）。
      expect(await store.allocateCardId('qb'), 1);
      expect(await store.allocateCardId('qa'), 1);
      final scheduler = FsrsReviewScheduler(
        config: const SchedulerConfig(enableFuzzing: false),
        store: store,
      );
      await scheduler.initializeQuestion('qa');
      await scheduler.recordAnswer(
        'qa',
        ReviewResult.good,
        DateTime.utc(2026, 11, 25, 10),
        'evt-qa-1',
      );
      // 新开一个 store 实例读同一库：映射与状态都在。
      final store2 = SqliteCardStore.forDatabase(db);
      expect(await store2.allocateCardId('qa'), 1);
      expect(await store2.allocateCardId('qb'), 2);
      final loaded = (await store2.load('qa'))!;
      expect(loaded.cardId, 1);
      expect(loaded.firstReviewedAt, isNotNull);
      expect(loaded.contentVersion, 0); // 调度器不知道题目版本，落盘入口回填
      final all = await store2.loadAll();
      expect(all.map((c) => c.questionId).toList(), ['qa']);
      expect(await scheduler.getDueQuestions(DateTime.utc(2026, 11, 28)), ['qa']);
      expect(await scheduler.getNewQuestions(10), isEmpty);
    });
  });

  group('P5 备份往返', () {
    test('v8 备份导出再恢复：fsrs_cards / 事件账本原样回来', () async {
      final db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => AppDatabase.resetForTest());
      await AppDatabase.upsertQuestionInto(db, _q('q1', contentVersion: 2));
      // 先跑一次迁移（模拟首次开库：此时无历史，审计全零、记一行
      // completed），再生产提交——顺序不能反：迁移重放的是升级前
      // 历史，生产提交后的记录绝不能再以 'mig:' 事件名重算一次。
      await migrateFsrsV7ToV8IntoImpl(db);
      final scheduler = _testScheduler(db);
      final repo = QuestionRepository(AppDatabase.instance);
      final at = DateTime.utc(2026, 11, 25, 10);
      await repo.submitReviewCheck(
        attempt: _attempt(
          id: 'att-1',
          questionId: 'q1',
          sessionId: 'sess-1',
          mode: '到期复习',
          correct: 1,
          contentVersion: 2,
          submissionId: 'attsub-1',
          createdAt: at.millisecondsSinceEpoch,
        ),
        result: ReviewResult.good,
        reviewedAt: at,
        eventId: 'attsub-1',
        scheduler: scheduler,
      );
      final jsonText = await AppDatabase.exportBackupJsonFrom(db);
      final decoded = jsonDecode(jsonText) as Map<String, dynamic>;
      expect((decoded['_meta'] as Map)['schemaVersion'], 8);
      expect((decoded['fsrs_cards'] as List).length, 1);
      expect((decoded['fsrs_events'] as List).length, 1);
      expect((decoded['fsrs_migration_log'] as List).length, 1);

      final db2 = await AppDatabase.openForTest();
      addTearDown(() async => db2.close());
      await AppDatabase.importBackupJsonInto(db2, decoded);
      final cards = await db2
          .customSelect('SELECT * FROM fsrs_cards')
          .get();
      expect(cards.length, 1);
      expect(cards.single.data['question_id'], 'q1');
      final before = (await db
              .customSelect('SELECT card_state_json FROM fsrs_cards')
              .getSingle())
          .data['card_state_json'];
      expect(cards.single.data['card_state_json'], before);
      // 恢复后迁移日志里有 completed 行：重跑迁移直接跳过，不重放。
      final again = await migrateFsrsV7ToV8IntoImpl(db2);
      expect(again['status'], 'already_migrated');
    });

    test('v7 备份仍能恢复（16 表清单），恢复后迁移重放', () async {
      final db = await AppDatabase.openForTest();
      addTearDown(() async => db.close());
      await AppDatabase.upsertQuestionInto(db, _q('q1', contentVersion: 1));
      final jsonText = await AppDatabase.exportBackupJsonFrom(db);
      final decoded = jsonDecode(jsonText) as Map<String, dynamic>;
      // 降级为 v7：去掉 fsrs_* 三键，schemaVersion 写 7。
      decoded.remove('fsrs_cards');
      decoded.remove('fsrs_events');
      decoded.remove('fsrs_migration_log');
      (decoded['_meta'] as Map<String, dynamic>)['schemaVersion'] = 7;
      final db2 = await AppDatabase.openForTest();
      addTearDown(() async => db2.close());
      await AppDatabase.importBackupJsonInto(db2, decoded);
      expect(
        await db2
            .customSelect('SELECT COUNT(*) AS n FROM questions')
            .getSingle()
            .then((r) => r.data['n']),
        1,
      );
      // v7 备份恢复后库里没有迁移日志：开库回填/显式迁移会跑一次。
      final result = await migrateFsrsV7ToV8IntoImpl(db2);
      expect(result['status'], 'completed');
    });
  });

  group('P5 旧会话迁移（§7）', () {
    Future<ProviderContainer> containerFor({
      required QuizDatabase db,
      required bool withAttempt,
    }) async {
      await AppDatabase.upsertQuestionInto(
        db,
        Question(
          id: 'q1',
          title: '函数极限',
          subjectId: 'math',
          errorTypes: const ['概念不清'],
          createdAt: DateTime(2026, 11, 8),
          isOrganized: true,
          reviewJoined: true,
          sliceKind: 'material',
          sliceText: '题：函数极限',
          questionType: 'choice_single',
          optionLabels: const ['A', 'B', 'C', 'D'],
          correctOption: 'B',
          contentVersion: 1,
        ),
      );
      // FSRS 全量迁移包2：播种（syncCauseRecordsInto）已删；策略 A 的
      // 恢复校验不读 cause_records，保存的错因只要在题身上就保留，
      // 此处不再需要先种一条记录。
      final repo = QuestionRepository(AppDatabase.instance);
      await repo.saveReviewState(
        queue: const [ReviewQueueItem(questionId: 'q1', cause: '概念不清')],
        position: 0,
        sessionId: 'sess-old-1',
        mode: ReviewMode.due,
        perQuestionState: {
          'q1': {
            'question_submission_id': 'qs-1',
            'attempt_submission_id': 'attsub-1',
            'answer_version_at_start': 1,
            'content_version_at_start': 1,
            // 旧流程的 selfCheck 阶段（P2 的 SessionStage 已无此值）。
            'stage': 'selfCheck',
            'attempt_id': null,
            'selected': null,
            'correct': null,
            'check_submitted': false,
            'notes_shown': false,
            'skips': 0,
            'deferred': false,
          },
        },
      );
      if (withAttempt) {
        await repo.recordAttempt(
          AttemptData(
            id: 'att-old-1',
            questionId: 'q1',
            sessionId: 'sess-old-1',
            mode: ReviewMode.due,
            selected: const ['B'],
            correct: 1,
            confidence: null,
            answerVersion: 1,
            contentVersion: 1,
            status: '已提交',
            causeIds: const ['概念不清'],
            submissionId: 'attsub-1',
            createdAt: DateTime.utc(2026, 11, 24, 10).millisecondsSinceEpoch,
          ),
        );
      }
      final container = ProviderContainer.test(
        overrides: [
          repositoryProvider.overrideWithValue(repo),
          reviewSchedulerProvider.overrideWithValue(_testScheduler(db)),
        ],
      );
      addTearDown(container.dispose);
      container.listen(reviewProvider, (_, __) {});
      return container;
    }

    Future<void> waitLoaded(ProviderContainer container) async {
      for (var i = 0; i < 100 && !container.read(reviewProvider).hasLoaded; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('selfCheck 无客观记录 → 回到核对步重做', () async {
      final db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => AppDatabase.resetForTest());
      final container = await containerFor(db: db, withAttempt: false);
      await waitLoaded(container);
      final state = container.read(reviewProvider);
      expect(state.resume, isNotNull);
      expect(state.resume!.sessionQuestions.single.stage, SessionStage.check);
      expect(state.resume!.sessionQuestions.single.checkSubmitted, isFalse);
    });

    test('selfCheck 有客观记录 → 视为已完成，不重计分', () async {
      final db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => AppDatabase.resetForTest());
      final container = await containerFor(db: db, withAttempt: true);
      await waitLoaded(container);
      final state = container.read(reviewProvider);
      expect(state.resume, isNotNull);
      expect(state.resume!.sessionQuestions.single.stage, SessionStage.done);
      expect(state.resume!.sessionQuestions.single.checkSubmitted, isTrue);
    });
  });
}
