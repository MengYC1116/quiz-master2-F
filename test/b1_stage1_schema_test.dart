// 架构 B 第 1 阶段验收：新代码（Drift 驱动）建出的空库，schema 与 v3
// 基线逐项零差异（方案 §六.3 每阶段门禁）。
//
// 期望值取自 v3 演示库的 sqlite_master（14 张表 + 4 个显式索引，
// 空白已折叠；sqlite_sequence 是 AUTOINCREMENT 附属表，排除在外）。
// DDL 文本一字不改是第 1 阶段的硬约束——此处逐字比对，改了 DDL
// 本测试即失败。
// 十二批 D-91：v3（新表 recently_viewed_questions + collect_tasks
// 新增 source_hash 列）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'package:quiz_master2/data/database.dart';

String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// v3 基线：18 条（14 表 + 4 索引），按 ORDER BY type, name 的顺序。
const _expected = [
  'CREATE UNIQUE INDEX idx_boxes_one_layer1_per_question ON question_boxes(question_id) WHERE layer = 1 AND question_id IS NOT NULL',
  'CREATE INDEX idx_boxes_parent ON question_boxes(parent_box_id)',
  'CREATE INDEX idx_boxes_question ON question_boxes(question_id)',
  'CREATE INDEX idx_boxes_task_page ON question_boxes(collect_task_id, page)',
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
];

void main() {
  group('B Stage 1：新代码建库 schema 与 v2 基线零差异', () {
    test('openAt 新建空库：user_version=3，18 条 DDL 逐字一致', () async {
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
          3,
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
