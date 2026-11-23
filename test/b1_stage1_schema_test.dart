// 架构 B 第 1 阶段验收：新代码（Drift 驱动）建出的空库，schema 与 v4
// 基线逐项零差异（方案 §六.3 每阶段门禁）。
//
// 期望值取自 v4 演示库的 sqlite_master（15 张表 + 6 个显式索引，
// 空白已折叠；sqlite_sequence 是 AUTOINCREMENT 附属表，排除在外）。
// DDL 文本一字不改是第 1 阶段的硬约束——此处逐字比对，改了 DDL
// 本测试即失败。
// 十二批 D-91：v3（新表 recently_viewed_questions + collect_tasks
// 新增 source_hash 列）。
// 十三批 M2：v4（questions 加 5 个 OCR 列 + 新表 ocr_jobs +
// idx_ocr_jobs_question / idx_ocr_jobs_pending 两个索引）。
// 十三批 P1-1：ocr_jobs 加 lease_token 列（租约 token）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'package:quiz_master2/data/database.dart';

String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// v4 基线：21 条（15 表 + 6 索引），按 ORDER BY type, name 的顺序。
// 十四批 M1：v5 期望 DDL（16 表 + 8 索引，24 条）。v5 = v4 的 15 张表
// + attempts 新表；questions 加 10 列（M1 的 9 列 + M3 的
// answer_pending_recheck，D-130：仍属 v5，不升 v6）、cause_records
// 加 2 列、review_history 加 8 列、review_state 加 4 列；新增索引 2 个
//（idx_questions_question_type、idx_review_history_submission）。
// Win11 反馈包 5：v6 期望 DDL（16 表 + 8 索引，仍 24 条；questions
// 末尾加 option_contents + option_contents_parser_version 两列）。
// 十九批 A3（D-218）：saved_searches 新表，不升版（仍 v6），25 条
//（17 表 + 8 索引）。
// 二十七批 D-257：v7（subjects 末尾加 english_name + english_name_manual
// 两列），仍 25 条。
const _expected = [
  'CREATE UNIQUE INDEX idx_boxes_one_layer1_per_question ON question_boxes(question_id) WHERE layer = 1 AND question_id IS NOT NULL',
  'CREATE INDEX idx_boxes_parent ON question_boxes(parent_box_id)',
  'CREATE INDEX idx_boxes_question ON question_boxes(question_id)',
  'CREATE INDEX idx_boxes_task_page ON question_boxes(collect_task_id, page)',
  'CREATE INDEX idx_ocr_jobs_pending ON ocr_jobs(status, available_at)',
  'CREATE INDEX idx_ocr_jobs_question ON ocr_jobs(question_id)',
  'CREATE INDEX idx_questions_question_type ON questions(question_type)',
  'CREATE UNIQUE INDEX idx_review_history_submission ON review_history(submission_id)',
  "CREATE TABLE attempts( id TEXT PRIMARY KEY, question_id TEXT NOT NULL, session_id TEXT NOT NULL, mode TEXT NOT NULL, selected TEXT, correct INTEGER, confidence TEXT, answer_version INTEGER NOT NULL DEFAULT 1, content_version INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL, cause_ids TEXT NOT NULL DEFAULT '[]', duration_ms INTEGER, submission_id TEXT UNIQUE, created_at INTEGER NOT NULL, UNIQUE(session_id, question_id))",
  "CREATE TABLE cause_records( id INTEGER PRIMARY KEY AUTOINCREMENT, question_id TEXT NOT NULL, cause TEXT NOT NULL, subject_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', solved_count INTEGER NOT NULL DEFAULT 0, last_check INTEGER, recheck_date INTEGER, remedy_history TEXT NOT NULL DEFAULT '', joined_at INTEGER NOT NULL, last_counted_success_at INTEGER, last_counted_session_id TEXT, UNIQUE(question_id, cause))",
  "CREATE TABLE collect_tasks( id TEXT PRIMARY KEY, name TEXT NOT NULL, file_name TEXT NOT NULL, subject_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'queued', progress INTEGER NOT NULL DEFAULT 0, page_count INTEGER NOT NULL DEFAULT 1, page INTEGER NOT NULL DEFAULT 1, error TEXT, question_id TEXT, created_at INTEGER NOT NULL DEFAULT 0, source_path TEXT NOT NULL DEFAULT '', page_rotations TEXT NOT NULL DEFAULT '{}', source_hash TEXT)",
  'CREATE TABLE exams(id TEXT PRIMARY KEY, name TEXT NOT NULL, date INTEGER)',
  'CREATE TABLE folders( id TEXT PRIMARY KEY, name TEXT NOT NULL, subject_id TEXT NOT NULL, parent_id TEXT, sort_order INTEGER NOT NULL DEFAULT 0)',
  'CREATE TABLE knowledge_points( id TEXT PRIMARY KEY, subject_id TEXT NOT NULL, chapter TEXT NOT NULL, name TEXT NOT NULL)',
  "CREATE TABLE question_boxes( id TEXT PRIMARY KEY, collect_task_id TEXT, question_id TEXT, parent_box_id TEXT, page INTEGER NOT NULL DEFAULT 1 CHECK (page >= 1), layer INTEGER NOT NULL CHECK (layer IN (1, 2)), type TEXT NOT NULL CHECK (type IN ('question', 'stem', 'option', 'figure')), x REAL NOT NULL CHECK (x >= 0 AND x <= 1), y REAL NOT NULL CHECK (y >= 0 AND y <= 1), w REAL NOT NULL CHECK (w >= 0 AND w <= 1), h REAL NOT NULL CHECK (h >= 0 AND h <= 1), confidence REAL CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)), origin TEXT NOT NULL DEFAULT 'manual' CHECK (origin IN ('yolo', 'manual')), updated_at INTEGER NOT NULL)",
  "CREATE TABLE questions( id TEXT PRIMARY KEY, title TEXT NOT NULL, subject_id TEXT NOT NULL, folder_ids TEXT NOT NULL DEFAULT '', exam_id TEXT, knowledge_ids TEXT NOT NULL DEFAULT '', error_types TEXT NOT NULL DEFAULT '', custom_error_types TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '', answer TEXT, explanation TEXT, notes TEXT, review_count INTEGER NOT NULL DEFAULT 0, is_organized INTEGER NOT NULL DEFAULT 0, is_demo INTEGER NOT NULL DEFAULT 0, is_favorite INTEGER NOT NULL DEFAULT 0, is_archived INTEGER NOT NULL DEFAULT 0, review_joined INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, slice_kind TEXT NOT NULL DEFAULT 'material', slice_text TEXT NOT NULL DEFAULT '', source_path TEXT, source_kind TEXT, source_page INTEGER, page_image_path TEXT, slice_path TEXT, slice_width INTEGER, slice_height INTEGER, ocr_raw TEXT, ocr_stem TEXT, ocr_split_status TEXT NOT NULL DEFAULT '未切分', ocr_manual_edited INTEGER NOT NULL DEFAULT 0, content_version INTEGER NOT NULL DEFAULT 0, question_type TEXT, question_type_source TEXT NOT NULL DEFAULT 'unclassified', question_background_tags TEXT NOT NULL DEFAULT '', question_background_tags_source TEXT NOT NULL DEFAULT 'unclassified', ocr_figures TEXT NOT NULL DEFAULT '[]', correct_option TEXT, option_labels TEXT, option_labels_confirmed INTEGER NOT NULL DEFAULT 0, answer_version INTEGER NOT NULL DEFAULT 1, answer_pending_recheck INTEGER NOT NULL DEFAULT 0, option_contents TEXT, option_contents_parser_version INTEGER)",
  'CREATE TABLE ocr_jobs( id TEXT PRIMARY KEY, question_id TEXT NOT NULL, crop_path TEXT, input_hash TEXT, status TEXT NOT NULL DEFAULT \'pending\', attempt_count INTEGER NOT NULL DEFAULT 0, available_at INTEGER, started_at INTEGER, lease_until INTEGER, lease_token TEXT, last_error_code TEXT, last_error_message TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, completed_at INTEGER)',
  'CREATE TABLE recent_tasks( id INTEGER PRIMARY KEY CHECK (id = 1), kind TEXT NOT NULL, subject_id TEXT NOT NULL, title TEXT NOT NULL, updated_at INTEGER NOT NULL)',
  'CREATE TABLE recently_viewed_questions( question_id TEXT PRIMARY KEY, viewed_at INTEGER NOT NULL)',
  "CREATE TABLE review_history( id INTEGER PRIMARY KEY AUTOINCREMENT, question_id TEXT NOT NULL, result TEXT NOT NULL, reviewed_at INTEGER NOT NULL, cause_id TEXT, session_id TEXT, review_mode TEXT CHECK (review_mode IN ('到期复习')), verdict TEXT, verification_source TEXT, verification_status TEXT CHECK ((verification_status IS NULL AND verification_source IS NULL) OR (verification_status = '已核验' AND verification_source IN ('软件标准答案', '客观判分', '外部资料核对')) OR (verification_status = '未核验' AND verification_source = '未核验')), attempt_id TEXT, submission_id TEXT)",
  "CREATE TABLE review_state( id INTEGER PRIMARY KEY CHECK (id = 1), queue TEXT NOT NULL DEFAULT '', position INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL, session_id TEXT, mode TEXT, skips TEXT, per_question_state TEXT)",
  "CREATE TABLE saved_searches( id TEXT PRIMARY KEY, name TEXT NOT NULL, conditions TEXT NOT NULL DEFAULT '{}', created_at INTEGER NOT NULL)",
  'CREATE TABLE settings( key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  "CREATE TABLE subjects( id TEXT PRIMARY KEY, name TEXT NOT NULL, color INTEGER NOT NULL, cover_style TEXT NOT NULL DEFAULT 'plain', cover_color TEXT NOT NULL DEFAULT 'blue', english_name TEXT, english_name_manual INTEGER NOT NULL DEFAULT 0)",
  'CREATE TABLE tags(id TEXT PRIMARY KEY, name TEXT NOT NULL)',
];

void main() {
  group('B Stage 1：新代码建库 schema 与 v2 基线零差异', () {
    test('openAt 新建空库：user_version=7，25 条 DDL 逐字一致', () async {
      final tmp = await Directory.systemTemp.createTemp('b1-schema-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = p.join(tmp.path, 'quiz-master2.db');

      final db = await AppDatabase.openAt(dbPath);
      await db.close();

      final probe = sqlite3.sqlite3.open(
        dbPath,
        mode: sqlite3.OpenMode.readOnly,
      );
      try {
        expect(
          probe
              .select('PRAGMA user_version')
              .single['user_version'],
          7,
        );
        final actual =
            probe
                .select(
                  "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL "
                  "AND name != 'sqlite_sequence' ORDER BY type, name",
                )
                .map((r) => _norm(r['sql'] as String))
                .toList()
              ..sort();
        final expected = _expected.map(_norm).toList()..sort();
        expect(actual, expected);
      } finally {
        probe.close();
      }
    });
  });
}
