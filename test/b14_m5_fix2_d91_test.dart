// 十四批 M5 修复轮 2（B 路）：D-91 证据——迁移后的 v8 库与全新 v8 库
// sqlite_master 逐字一致（实际跑出来的比对结果）。
// 方法：用 v4 夹具 DDL 建 v4 库 → AppDatabase.openAt 走 Drift 迁移到 v8；
// 另建全新 v8 库；两库各取 sqlite_master（type/name/tbl_name/sql，
// 按 type, name 排序）逐行比对。比对输出写进本测试的临时目录
// fix2-d91-sqlite-master-diff.txt（含两库完整 sqlite_master 清单、
// user_version、表/索引计数与 diff 结果）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// v4 基线 DDL（15 表 + 6 索引，与 test/b14_m1_migration_test.dart
/// 的 v4 夹具同一份——建 v4 库用）。
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
  'CREATE UNIQUE INDEX idx_boxes_one_layer1_per_question ON question_boxes(question_id) WHERE layer = 1 AND question_id IS NOT NULL',
  'CREATE INDEX idx_boxes_parent ON question_boxes(parent_box_id)',
  'CREATE INDEX idx_boxes_question ON question_boxes(question_id)',
  'CREATE INDEX idx_boxes_task_page ON question_boxes(collect_task_id, page)',
  'CREATE INDEX idx_ocr_jobs_pending ON ocr_jobs(status, available_at)',
  'CREATE INDEX idx_ocr_jobs_question ON ocr_jobs(question_id)',
];

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
  raw.execute("INSERT INTO settings VALUES ('schemaVersion', '4')");
  raw.execute('PRAGMA user_version = 4');
  raw.close();
  return dbPath;
}

/// sqlite_master 全量行（type|name|tbl_name|sql，sql 为 NULL 时记
/// `<NULL>`；按 type, name 排序；含 sqlite_sequence 行）。
List<String> _dumpMaster(String dbPath) {
  final probe = sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
  try {
    return probe
        .select(
          'SELECT type, name, tbl_name, sql FROM sqlite_master '
          'ORDER BY type, name',
        )
        .map((r) {
          final sql = r['sql'];
          return "${r['type']}|${r['name']}|${r['tbl_name']}|${sql ?? '<NULL>'}";
        })
        .toList();
  } finally {
    probe.close();
  }
}

int _userVersion(String dbPath) {
  final probe = sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
  try {
    return probe.select('PRAGMA user_version').first['user_version'] as int;
  } finally {
    probe.close();
  }
}

/// unified diff（行级）：以 `-` 标仅迁移库有、`+` 标仅全新库有；
/// 相同行不输出。零差异时返回空串。
String _unifiedDiff(List<String> a, List<String> b) {
  final out = <String>[];
  final setB = b.toSet();
  final setA = a.toSet();
  for (final line in a) {
    if (!setB.contains(line)) out.add('- $line');
  }
  for (final line in b) {
    if (!setA.contains(line)) out.add('+ $line');
  }
  return out.join('\n');
}

void main() {
  test('D-91：v4 迁移到 v8 后的库与全新 v8 库 sqlite_master 逐字一致（实际比对）', () async {
    final tmp = await Directory.systemTemp.createTemp('b14-fix2-d91-');
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

    final migratedRows = _dumpMaster(migratedPath);
    final freshRows = _dumpMaster(freshPath);
    final migratedVersion = _userVersion(migratedPath);
    final freshVersion = _userVersion(freshPath);

    // 逐字比对分两层：① sql 原文逐行比较（不做空白归一化）；
    // ② 空白归一化后比对（与 test/b14_m1_migration_test.dart 的既有
    // 口径一致）。SQLite 对 ALTER TABLE 的表保留原始建表文本，v4 夹具
    // DDL 是单行写法、createTablesImpl 是多行写法，原文层必然有
    // 空白差异；关键断言是归一化后零差异，且每个原文差异都逐一核对
    // 为“仅空白不同”。
    final rawDiff = _unifiedDiff(migratedRows, freshRows);
    final normDiff = _unifiedDiff(
      migratedRows.map(_norm).toList(),
      freshRows.map(_norm).toList(),
    );

    // 按 (type, name) 逐对象核对原文差异：只允许“归一化后相同”。
    Map<String, String> sqlByName(List<String> rows) {
      final map = <String, String>{};
      for (final row in rows) {
        final first = row.indexOf('|');
        final second = row.indexOf('|', first + 1);
        final third = row.indexOf('|', second + 1);
        map[row.substring(0, second)] = row.substring(third + 1);
      }
      return map;
    }

    final migratedSql = sqlByName(migratedRows);
    final freshSql = sqlByName(freshRows);
    final explanations = <String>[];
    for (final key in {...migratedSql.keys, ...freshSql.keys}.toList()
      ..sort()) {
      final a = migratedSql[key];
      final b = freshSql[key];
      if (a == b) continue;
      if (a != null && b != null && _norm(a) == _norm(b)) {
        explanations.add(
          '$key：仅空白/换行差异，归一化后相同；无列、类型、默认值、CHECK、UNIQUE 差异。',
        );
      } else {
        explanations.add('$key：!!! 归一化后仍不同（非空白差异），须人工核查。');
      }
    }
    final tableCount = migratedRows
        .where((r) => r.startsWith('table|') && !r.startsWith('table|sqlite_sequence|'))
        .length;
    final indexRows = migratedRows.where((r) => r.startsWith('index|')).toList();
    final explicitIndexCount = indexRows
        .where((r) => !r.split('|')[1].startsWith('sqlite_autoindex'))
        .length;
    final autoIndexCount = indexRows.length - explicitIndexCount;

    final buf = StringBuffer();
    buf.writeln('D-91 sqlite_master 对比证据（十四批 M5 修复轮 2，B 路）');
    buf.writeln('方法：v4 夹具库（15 表 + 6 索引，user_version=4）经 '
        'AppDatabase.openAt 走 Drift 迁移到 v8；另建全新 v8 库；两库各取 '
        'sqlite_master（SELECT type, name, tbl_name, sql ORDER BY type, name）'
        '逐行比对。源码 DDL 见 lib/data/db_schema.dart createTablesImpl；'
        '迁移 DDL 见 lib/data/drift/quiz_database.dart _upgrade4To5 与 _upgrade5To6。');
    buf.writeln('迁移库 user_version=$migratedVersion，全新库 '
        'user_version=$freshVersion。');
    buf.writeln('迁移库 sqlite_master 行数=${migratedRows.length}，'
        '全新库行数=${freshRows.length}（表 $tableCount 张 + sqlite_sequence '
        '1 行 + 索引 ${indexRows.length} 个，其中显式索引 $explicitIndexCount 个、'
        'sqlite_autoindex_* 主键/唯一自动索引 $autoIndexCount 个）。');
    buf.writeln('');
    buf.writeln('== 原文逐行 diff（`-` 仅迁移库有，`+` 仅全新库有；空即零差异） ==');
    buf.writeln(rawDiff.isEmpty ? '（零差异）' : rawDiff);
    buf.writeln('');
    buf.writeln('== 原文差异逐行解释 ==');
    buf.writeln(
      '成因（唯一）：SQLite 对 ALTER TABLE ADD COLUMN 的表保留原始建表'
      '文本；v4 夹具 DDL 是单行写法，createTablesImpl 是多行写法，'
      '故迁移库里 15 张旧表的 sql 是单行、全新库是多行。新表 attempts '
      '与新索引的迁移 DDL 字面量与建表 DDL 一字不差，原文即相同。'
      '以下逐一核对：',
    );
    if (explanations.isEmpty) {
      buf.writeln('（原文零差异，无需解释）');
    } else {
      for (final e in explanations) {
        buf.writeln('- $e');
      }
    }
    buf.writeln('');
    buf.writeln('== 空白归一化后 diff（对照；空即零差异） ==');
    buf.writeln(normDiff.isEmpty ? '（零差异）' : normDiff);
    buf.writeln('');
    buf.writeln('== 完整建表 DDL（全新 v8 库 sqlite_master 的 sql 原文，'
        '即 lib/data/db_schema.dart createTablesImpl 实际执行的建表语句） ==');
    for (final row in freshRows) {
      final parts = row.split('|');
      final sql = parts.sublist(3).join('|');
      buf.writeln('[${parts[0]}] ${parts[1]}: $sql');
    }
    buf.writeln('');
    buf.writeln('== 迁移库 sqlite_master 全文（type|name|tbl_name|sql） ==');
    for (final row in migratedRows) {
      buf.writeln(row);
    }
    buf.writeln('');
    buf.writeln('== 全新库 sqlite_master 全文（type|name|tbl_name|sql） ==');
    for (final row in freshRows) {
      buf.writeln(row);
    }

    // 二十五批：证据文件改写进本测试的临时目录。原来拼
    // $HOME/workspace/batch14-work/...，Windows 上 HOME 未设置时
    // 变成相对路径、父目录不存在，写文件抛 PathNotFoundException，
    // 断言一行都没跑到（Win11 errno 3）。
    final outPath = p.join(tmp.path, 'fix2-d91-sqlite-master-diff.txt');
    await File(outPath).writeAsString(buf.toString());

    expect(migratedVersion, 8);
    expect(freshVersion, 8);
    // D-91 的“逐字一致”按本项目既有口径（b14_m1_migration_test）指
    // 空白归一化后逐字一致；原文层差异已在证据文件里逐行解释为仅
    // 空白不同（此处断言每个原文差异的归一化形式都相同）。
    expect(normDiff, isEmpty);
    expect(
      explanations.every((e) => e.contains('仅空白/换行差异')),
      isTrue,
      reason: '存在非空白的原文差异，见 $outPath',
    );
    expect(migratedRows.map(_norm).toList(), freshRows.map(_norm).toList());
  });
}
