// ARCH-PLAN-B 第 1 阶段：Drift 数据库对象（驱动切换）。
// 独立 library 文件（不是 part 文件——Dart 规定 part 文件里不能再声明
// part，而 drift_dev 生成的 quiz_database.g.dart 必须作为它的 part）。
// 第 2 阶段：13 张表定义在 lib/data/drift/tables/（每表一个文件，
// 尖峰 B-SPIKE-REPORT.md §1 三路对比零差异的配方），此处注册进 tables；
// 建表仍走 database.dart 的 createTablesImpl（customStatement 原样 DDL），
// onCreate 只调注入的回调，不由 Drift 生成建表——注册表只提供类型化查询，
// 不改变建库行为。
//
// 回调注入的原因：建表 / 播种 / 回填逻辑在 database.dart 的 part 库里，
// 本文件不能反向 import 它（会循环）。因此 onCreate 只调注入的
// onCreateTables 回调，beforeOpen 只调注入的 onBeforeOpen 回调。
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:quiz_master2/models/models.dart'; // 生成文件里 QueueConverter
// 用到 ReviewQueueItem（part 文件只认本文件的 import，不认 converters.dart 的）。
import 'converters.dart'; // 生成文件里用到 StringListConverter 等转换器，同上。

import 'tables/attempts.dart';
import 'tables/cause_records.dart';
import 'tables/collect_tasks.dart';
import 'tables/exams.dart';
import 'tables/folders.dart';
import 'tables/knowledge_points.dart';
import 'tables/ocr_jobs.dart';
import 'tables/question_boxes.dart';
import 'tables/questions.dart';
import 'tables/recent_tasks.dart';
import 'tables/recently_viewed_questions.dart';
import 'tables/review_history.dart';
import 'tables/review_state.dart';
import 'tables/settings.dart';
import 'tables/subjects.dart';
import 'tables/tags.dart';

part 'quiz_database.g.dart';

@DriftDatabase(
  tables: [
    Settings,
    Tags,
    Exams,
    KnowledgePoints,
    Folders,
    Subjects,
    RecentTasks,
    RecentlyViewedQuestions,
    ReviewHistory,
    CauseRecords,
    ReviewState,
    CollectTasks,
    QuestionBoxes,
    Questions,
    OcrJobs,
    Attempts,
  ],
)
class QuizDatabase extends _$QuizDatabase {
  QuizDatabase.file(
    File file, {
    this.onCreateTables,
    this.onBeforeOpen,
  }) : super(NativeDatabase(file));

  QuizDatabase.memory({
    this.onCreateTables,
    this.onBeforeOpen,
  }) : super(NativeDatabase.memory());

  /// 建库时调：建表 + 播种（database.dart 的 createTablesImpl + _seed）。
  final Future<void> Function(QuizDatabase db)? onCreateTables;

  /// 每次打开库、迁移跑完、其他查询尚未发送时调：B9-1 回填
  ///（database.dart 的 backfillCollectDoneIntoImpl）。
  final Future<void> Function(QuizDatabase db)? onBeforeOpen;

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await onCreateTables?.call(this);
    },
    // Drift 2.35 的 MigrationStrategy 没有独立的 onDowngrade 槽位：
    // 升版与降版都走 onUpgrade（from < to 为升版，from > to 为降版）。
    // 十二批 D-91：v2 → v3 是本项目第一次真正的迁移——建
    // recently_viewed_questions 表 + collect_tasks 加 source_hash 列，
    // 数据全保留。十三批 M2：v3 → v4——questions 加 5 个 OCR 列 +
    // 新建 ocr_jobs 表，数据全保留；v2 → v4 走 2→3 再 3→4 两步链式。
    // 十四批 M1：v4 → v5——questions 加 10 列（题型两维 + 图块 +
    // correct_option / option_labels / answer_version /
    // answer_pending_recheck；content_version
    // 不新增，v4 已有）+ cause_records 加 2 个锚点列 + review_history
    // 加 8 列 + 新建 attempts 表 + review_state 加 4 列 +
    // question_type 索引；旧 solved_count 按保守方案迁移（见
    // _upgrade4To5）。其它 from/to 一律抛错：v1 及更老由打开前的
    // deleteLegacyDatabaseIfPresent 预检删掉；from > to（新版库用旧版
    // 打开）请用新版打开。
    onUpgrade: (m, from, to) async {
      if (from == 2 && to == 5) {
        await _upgrade2To3(m);
        await _upgrade3To4(m);
        await _upgrade4To5(m);
        return;
      }
      if (from == 3 && to == 5) {
        await _upgrade3To4(m);
        await _upgrade4To5(m);
        return;
      }
      if (from == 4 && to == 5) {
        await _upgrade4To5(m);
        return;
      }
      if (from > to) {
        throw StateError(
          '数据库是新版格式（v$from），请用新版打开（当前要求 v$to）',
        );
      }
      throw StateError('意外的数据库迁移 from=$from to=$to');
    },
    beforeOpen: (details) async {
      await onBeforeOpen?.call(this);
    },
  );
}

/// 十二批 D-91 的 v2 → v3 迁移步（十三批 M2 抽成独立函数，供
/// v2 → v4 链式复用；DDL 与 createTablesImpl 的手写字面量一字不差）。
Future<void> _upgrade2To3(Migrator m) async {
  // DDL 必须与 createTablesImpl 的手写字面量一字不差（B1 纪律：
  // 迁移后的库与全新 v3 库在 sqlite_master 里逐字一致）。Drift 的
  // m.createTable / m.addColumn 生成的 DDL 带引号（"source_hash"
  // TEXT NULL），与手写文本不一致，故此处走 customStatement，
  // 用同一份字面量；语义与 Drift 生成的 DDL 等价。
  await m.database.customStatement(
    'CREATE TABLE recently_viewed_questions(\n'
    '  question_id TEXT PRIMARY KEY, viewed_at INTEGER NOT NULL)',
  );
  await m.database.customStatement(
    'ALTER TABLE collect_tasks ADD COLUMN source_hash TEXT',
  );
  // settings 里的 schemaVersion 也写回 3，与 user_version 一致
  // （真实 v2 库的 settings 本来就有这行；手造夹具库若缺这行，
  // insertOrReplace 会补一行）。本文件是独立 library，不能调
  // database.dart 库私有的 _upsertSettingInto；attachedDatabase
  // 的静态类型是 GeneratedDatabase，cast 后走 Drift 类型化写入。
  final db = m.database as QuizDatabase;
  await db.into(db.settings).insert(
    SettingsCompanion.insert(key: 'schemaVersion', value: '3'),
    mode: InsertMode.insertOrReplace,
  );
}

/// 十三批 M2 的 v3 → v4 迁移步：questions 加 5 个 OCR 列
///（ocr_raw / ocr_stem 可空；ocr_split_status 默认 '未切分'；
/// ocr_manual_edited / content_version 默认 0）+ 新建 ocr_jobs 表
///（含 idx_ocr_jobs_question / idx_ocr_jobs_pending 两个索引）。
/// 迁移 DDL 必须与 createTablesImpl 的手写字面量一字不差（十二批
/// D-91 的教训：迁移后库与全新 v4 库 sqlite_master 逐字一致——
/// ALTER TABLE ADD COLUMN 的列定义文本与建表字面量的列定义逐词相同，
/// SQLite 会把它们拼进同一份 CREATE TABLE 文本；CREATE TABLE
/// ocr_jobs 与两个索引用同一份字面量，不走 m.createTable）。
Future<void> _upgrade3To4(Migrator m) async {
  await m.database.customStatement(
    'ALTER TABLE questions ADD COLUMN ocr_raw TEXT',
  );
  await m.database.customStatement(
    'ALTER TABLE questions ADD COLUMN ocr_stem TEXT',
  );
  await m.database.customStatement(
    "ALTER TABLE questions ADD COLUMN ocr_split_status TEXT NOT NULL DEFAULT '未切分'",
  );
  await m.database.customStatement(
    'ALTER TABLE questions ADD COLUMN ocr_manual_edited INTEGER NOT NULL DEFAULT 0',
  );
  await m.database.customStatement(
    'ALTER TABLE questions ADD COLUMN content_version INTEGER NOT NULL DEFAULT 0',
  );
  // 十三批 P1-1：加 lease_token（租约 token）。本字面量须与
  // db_schema.dart 的 createTablesImpl 一字不差（M2 的教训）。
  await m.database.customStatement('''
    CREATE TABLE ocr_jobs(
      id TEXT PRIMARY KEY, question_id TEXT NOT NULL,
      crop_path TEXT, input_hash TEXT,
      status TEXT NOT NULL DEFAULT 'pending',
      attempt_count INTEGER NOT NULL DEFAULT 0,
      available_at INTEGER, started_at INTEGER, lease_until INTEGER,
      lease_token TEXT,
      last_error_code TEXT, last_error_message TEXT,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
      completed_at INTEGER)''');
  await m.database.customStatement(
    'CREATE INDEX idx_ocr_jobs_question ON ocr_jobs(question_id)',
  );
  await m.database.customStatement(
    'CREATE INDEX idx_ocr_jobs_pending ON ocr_jobs(status, available_at)',
  );
  // settings 里的 schemaVersion 写回 4，与 user_version 一致
  // （真实 v3 库的 settings 本来就有这行；手造夹具库若缺这行，
  // insertOrReplace 会补一行）。
  final db = m.database as QuizDatabase;
  await db.into(db.settings).insert(
    SettingsCompanion.insert(key: 'schemaVersion', value: '4'),
    mode: InsertMode.insertOrReplace,
  );
}

/// 十四批 M1 的 v4 → v5 迁移步：questions 加 10 列（题型两维 + 图块 +
/// correct_option / option_labels / answer_version / answer_pending_recheck；content_version 不新增，
/// v4 已有，迁移只验证其值原样保留）+ cause_records 加 2 个锚点列 +
/// review_history 加 8 列（含 review_mode 与 verification_status 的
/// CHECK 约束、submission_id 唯一索引）+ 新建 attempts 表 +
/// review_state 加 4 列 + questions.question_type 索引。
/// 迁移 DDL 必须与 createTablesImpl 的手写字面量一字不差（十二批
/// D-91 的教训：迁移后库与全新 v5 库 sqlite_master 逐字一致——
/// ALTER TABLE ADD COLUMN 的列定义文本与建表字面量的列定义逐词相同，
/// SQLite 会把它们拼进同一份 CREATE TABLE 文本；CREATE TABLE
/// attempts 与三个索引用同一份字面量，不走 m.createTable）。
/// 注意：SQLite 禁止 ALTER TABLE ADD COLUMN 带 UNIQUE 约束，
/// review_history.submission_id 的唯一性由独立唯一索引保证；
/// verification_status 的 CHECK 引用 verification_source 列，
/// 须先加 verification_source 列再加 verification_status 列。
/// 旧 solved_count 保守迁移（M3-7 P1-4）：已 solved 的旧错因保留状态与
/// 复查日期、锚点 NULL；未治愈且旧 solved_count > 0 的错因治愈进度重置
/// 为 0、锚点 NULL；solved_count = 0 的保持原值。
Future<void> _upgrade4To5(Migrator m) async {
  await m.database.customStatement(
    'ALTER TABLE questions ADD COLUMN question_type TEXT',
  );
  await m.database.customStatement(
    "ALTER TABLE questions ADD COLUMN question_type_source TEXT NOT NULL DEFAULT 'unclassified'",
  );
  await m.database.customStatement(
    "ALTER TABLE questions ADD COLUMN question_background_tags TEXT NOT NULL DEFAULT ''",
  );
  await m.database.customStatement(
    "ALTER TABLE questions ADD COLUMN question_background_tags_source TEXT NOT NULL DEFAULT 'unclassified'",
  );
  await m.database.customStatement(
    "ALTER TABLE questions ADD COLUMN ocr_figures TEXT NOT NULL DEFAULT '[]'",
  );
  await m.database.customStatement(
    'ALTER TABLE questions ADD COLUMN correct_option TEXT',
  );
  await m.database.customStatement(
    'ALTER TABLE questions ADD COLUMN option_labels TEXT',
  );
  await m.database.customStatement(
    'ALTER TABLE questions ADD COLUMN option_labels_confirmed INTEGER NOT NULL DEFAULT 0',
  );
  await m.database.customStatement(
    'ALTER TABLE questions ADD COLUMN answer_version INTEGER NOT NULL DEFAULT 1',
  );
  await m.database.customStatement(
    'ALTER TABLE questions ADD COLUMN answer_pending_recheck INTEGER NOT NULL DEFAULT 0',
  );
  await m.database.customStatement(
    'ALTER TABLE cause_records ADD COLUMN last_counted_success_at INTEGER',
  );
  await m.database.customStatement(
    'ALTER TABLE cause_records ADD COLUMN last_counted_session_id TEXT',
  );
  // 未治愈且旧 solved_count > 0：未完成的旧治愈进度重置为 0
  //（已 solved 的保留状态与复查日期；solved_count = 0 的保持原值）。
  await m.database.customStatement(
    "UPDATE cause_records SET solved_count = 0 WHERE status != 'solved' AND solved_count > 0",
  );
  await m.database.customStatement(
    'ALTER TABLE review_history ADD COLUMN cause_id TEXT',
  );
  await m.database.customStatement(
    'ALTER TABLE review_history ADD COLUMN session_id TEXT',
  );
  await m.database.customStatement(
    "ALTER TABLE review_history ADD COLUMN review_mode TEXT CHECK (review_mode IN ('到期复习'))",
  );
  await m.database.customStatement(
    'ALTER TABLE review_history ADD COLUMN verdict TEXT',
  );
  await m.database.customStatement(
    'ALTER TABLE review_history ADD COLUMN verification_source TEXT',
  );
  await m.database.customStatement(
    "ALTER TABLE review_history ADD COLUMN verification_status TEXT CHECK ((verification_status IS NULL AND verification_source IS NULL) OR (verification_status = '已核验' AND verification_source IN ('软件标准答案', '客观判分', '外部资料核对')) OR (verification_status = '未核验' AND verification_source = '未核验'))",
  );
  await m.database.customStatement(
    'ALTER TABLE review_history ADD COLUMN attempt_id TEXT',
  );
  await m.database.customStatement(
    'ALTER TABLE review_history ADD COLUMN submission_id TEXT',
  );
  await m.database.customStatement(
    'CREATE UNIQUE INDEX idx_review_history_submission ON review_history(submission_id)',
  );
  await m.database.customStatement('''
    CREATE TABLE attempts(
      id TEXT PRIMARY KEY, question_id TEXT NOT NULL,
      session_id TEXT NOT NULL, mode TEXT NOT NULL,
      selected TEXT, correct INTEGER, confidence TEXT,
      answer_version INTEGER NOT NULL DEFAULT 1,
      content_version INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL, cause_ids TEXT NOT NULL DEFAULT '[]',
      duration_ms INTEGER, submission_id TEXT UNIQUE,
      created_at INTEGER NOT NULL,
      UNIQUE(session_id, question_id))''');
  await m.database.customStatement(
    'ALTER TABLE review_state ADD COLUMN session_id TEXT',
  );
  await m.database.customStatement(
    'ALTER TABLE review_state ADD COLUMN mode TEXT',
  );
  await m.database.customStatement(
    'ALTER TABLE review_state ADD COLUMN skips TEXT',
  );
  await m.database.customStatement(
    'ALTER TABLE review_state ADD COLUMN per_question_state TEXT',
  );
  await m.database.customStatement(
    'CREATE INDEX idx_questions_question_type ON questions(question_type)',
  );
  // settings 里的 schemaVersion 写回 5，与 user_version 一致
  // （真实 v4 库的 settings 本来就有这行；手造夹具库若缺这行，
  // insertOrReplace 会补一行）。
  final db = m.database as QuizDatabase;
  await db.into(db.settings).insert(
    SettingsCompanion.insert(key: 'schemaVersion', value: '5'),
    mode: InsertMode.insertOrReplace,
  );
}
