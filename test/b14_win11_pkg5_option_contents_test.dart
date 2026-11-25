// Win11 反馈包 5：识别全部（题干 + 选项）。
//
// 覆盖：统一选项解析器（纯函数）、分类器结构化选项信号、
// option_contents 编解码/校验、v5→v7 迁移、v5/v7 备份恢复双向、
// ocr_raw 回填（幂等 + 不覆盖人工改过的选项）、模型与 upsert 的
// 标签删除剪枝。全部用临时目录 / 内存库，不碰真实用户库。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/ocr/question_classifier.dart';
import 'package:quiz_master2/services/option_contents.dart';
import 'package:quiz_master2/services/stem_splitter.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// v5 基线 DDL（16 表 + 索引）：v4 DDL（test/b14_m1_migration_test.dart
/// 的 _v4Ddl）按 _upgrade4To5 的顺序追加 v5 列/表/索引。
/// questions 的 v5 列按迁移追加顺序排在 content_version 之后。
const _v5Ddl = [
  "CREATE TABLE cause_records( id INTEGER PRIMARY KEY AUTOINCREMENT, question_id TEXT NOT NULL, cause TEXT NOT NULL, subject_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', solved_count INTEGER NOT NULL DEFAULT 0, last_check INTEGER, recheck_date INTEGER, remedy_history TEXT NOT NULL DEFAULT '', joined_at INTEGER NOT NULL, last_counted_success_at INTEGER, last_counted_session_id TEXT, UNIQUE(question_id, cause))",
  "CREATE TABLE collect_tasks( id TEXT PRIMARY KEY, name TEXT NOT NULL, file_name TEXT NOT NULL, subject_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'queued', progress INTEGER NOT NULL DEFAULT 0, page_count INTEGER NOT NULL DEFAULT 1, page INTEGER NOT NULL DEFAULT 1, error TEXT, question_id TEXT, created_at INTEGER NOT NULL DEFAULT 0, source_path TEXT NOT NULL DEFAULT '', page_rotations TEXT NOT NULL DEFAULT '{}', source_hash TEXT)",
  'CREATE TABLE exams(id TEXT PRIMARY KEY, name TEXT NOT NULL, date INTEGER)',
  'CREATE TABLE folders( id TEXT PRIMARY KEY, name TEXT NOT NULL, subject_id TEXT NOT NULL, parent_id TEXT, sort_order INTEGER NOT NULL DEFAULT 0)',
  'CREATE TABLE knowledge_points( id TEXT PRIMARY KEY, subject_id TEXT NOT NULL, chapter TEXT NOT NULL, name TEXT NOT NULL)',
  "CREATE TABLE question_boxes( id TEXT PRIMARY KEY, collect_task_id TEXT, question_id TEXT, parent_box_id TEXT, page INTEGER NOT NULL DEFAULT 1 CHECK (page >= 1), layer INTEGER NOT NULL CHECK (layer IN (1, 2)), type TEXT NOT NULL CHECK (type IN ('question', 'stem', 'option', 'figure')), x REAL NOT NULL CHECK (x >= 0 AND x <= 1), y REAL NOT NULL CHECK (y >= 0 AND y <= 1), w REAL NOT NULL CHECK (w >= 0 AND w <= 1), h REAL NOT NULL CHECK (h >= 0 AND h <= 1), confidence REAL CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)), origin TEXT NOT NULL DEFAULT 'manual' CHECK (origin IN ('yolo', 'manual')), updated_at INTEGER NOT NULL)",
  "CREATE TABLE questions( id TEXT PRIMARY KEY, title TEXT NOT NULL, subject_id TEXT NOT NULL, folder_ids TEXT NOT NULL DEFAULT '', exam_id TEXT, knowledge_ids TEXT NOT NULL DEFAULT '', error_types TEXT NOT NULL DEFAULT '', custom_error_types TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '', answer TEXT, explanation TEXT, notes TEXT, review_count INTEGER NOT NULL DEFAULT 0, is_organized INTEGER NOT NULL DEFAULT 0, is_demo INTEGER NOT NULL DEFAULT 0, is_favorite INTEGER NOT NULL DEFAULT 0, is_archived INTEGER NOT NULL DEFAULT 0, review_joined INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, slice_kind TEXT NOT NULL DEFAULT 'material', slice_text TEXT NOT NULL DEFAULT '', source_path TEXT, source_kind TEXT, source_page INTEGER, page_image_path TEXT, slice_path TEXT, slice_width INTEGER, slice_height INTEGER, ocr_raw TEXT, ocr_stem TEXT, ocr_split_status TEXT NOT NULL DEFAULT '未切分', ocr_manual_edited INTEGER NOT NULL DEFAULT 0, content_version INTEGER NOT NULL DEFAULT 0, question_type TEXT, question_type_source TEXT NOT NULL DEFAULT 'unclassified', question_background_tags TEXT NOT NULL DEFAULT '', question_background_tags_source TEXT NOT NULL DEFAULT 'unclassified', ocr_figures TEXT NOT NULL DEFAULT '[]', correct_option TEXT, option_labels TEXT, option_labels_confirmed INTEGER NOT NULL DEFAULT 0, answer_version INTEGER NOT NULL DEFAULT 1, answer_pending_recheck INTEGER NOT NULL DEFAULT 0)",
  'CREATE TABLE ocr_jobs( id TEXT PRIMARY KEY, question_id TEXT NOT NULL, crop_path TEXT, input_hash TEXT, status TEXT NOT NULL DEFAULT \'pending\', attempt_count INTEGER NOT NULL DEFAULT 0, available_at INTEGER, started_at INTEGER, lease_until INTEGER, lease_token TEXT, last_error_code TEXT, last_error_message TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, completed_at INTEGER)',
  'CREATE TABLE recent_tasks( id INTEGER PRIMARY KEY CHECK (id = 1), kind TEXT NOT NULL, subject_id TEXT NOT NULL, title TEXT NOT NULL, updated_at INTEGER NOT NULL)',
  'CREATE TABLE recently_viewed_questions( question_id TEXT PRIMARY KEY, viewed_at INTEGER NOT NULL)',
  "CREATE TABLE review_history( id INTEGER PRIMARY KEY AUTOINCREMENT, question_id TEXT NOT NULL, result TEXT NOT NULL, reviewed_at INTEGER NOT NULL, cause_id TEXT, session_id TEXT, review_mode TEXT CHECK (review_mode IN ('到期复习')), verdict TEXT, verification_source TEXT, verification_status TEXT CHECK ((verification_status IS NULL AND verification_source IS NULL) OR (verification_status = '已核验' AND verification_source IN ('软件标准答案', '客观判分', '外部资料核对')) OR (verification_status = '未核验' AND verification_source = '未核验')), attempt_id TEXT, submission_id TEXT)",
  "CREATE TABLE review_state( id INTEGER PRIMARY KEY CHECK (id = 1), queue TEXT NOT NULL DEFAULT '', position INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL, session_id TEXT, mode TEXT, skips TEXT, per_question_state TEXT)",
  'CREATE TABLE settings( key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  "CREATE TABLE subjects( id TEXT PRIMARY KEY, name TEXT NOT NULL, color INTEGER NOT NULL, cover_style TEXT NOT NULL DEFAULT 'plain', cover_color TEXT NOT NULL DEFAULT 'blue')",
  'CREATE TABLE tags(id TEXT PRIMARY KEY, name TEXT NOT NULL)',
  'CREATE TABLE attempts( id TEXT PRIMARY KEY, question_id TEXT NOT NULL, session_id TEXT NOT NULL, mode TEXT NOT NULL, selected TEXT, correct INTEGER, confidence TEXT, answer_version INTEGER NOT NULL DEFAULT 1, content_version INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL, cause_ids TEXT NOT NULL DEFAULT \'[]\', duration_ms INTEGER, submission_id TEXT UNIQUE, created_at INTEGER NOT NULL, UNIQUE(session_id, question_id))',
  'CREATE UNIQUE INDEX idx_boxes_one_layer1_per_question ON question_boxes(question_id) WHERE layer = 1 AND question_id IS NOT NULL',
  'CREATE INDEX idx_boxes_parent ON question_boxes(parent_box_id)',
  'CREATE INDEX idx_boxes_question ON question_boxes(question_id)',
  'CREATE INDEX idx_boxes_task_page ON question_boxes(collect_task_id, page)',
  'CREATE INDEX idx_ocr_jobs_pending ON ocr_jobs(status, available_at)',
  'CREATE INDEX idx_ocr_jobs_question ON ocr_jobs(question_id)',
  'CREATE UNIQUE INDEX idx_review_history_submission ON review_history(submission_id)',
  'CREATE INDEX idx_questions_question_type ON questions(question_type)',
];

/// 造一个 v5 库文件：v5 DDL + user_version=5 + 一道已 OCR 的选择题
///（ocr_raw 存全文 md，option_contents 列尚不存在）+ settings '5'。
Future<String> _v5DbFile(Directory tmp) async {
  final dbPath = p.join(tmp.path, 'quiz-master2.db');
  final raw = sqlite3.sqlite3.open(dbPath);
  for (final ddl in _v5Ddl) {
    raw.execute(ddl);
  }
  raw.execute(
    "INSERT INTO subjects VALUES ('math', '数学', 4280391411, 'plain', 'blue')",
  );
  final md =
      '下列函数中是偶函数的是\nA. 偶函数\nB. 奇函数\nC. 非奇非偶函数\nD. 既奇又偶函数';
  final ocrRaw = jsonEncode({
    'md_results': md,
    'layout_details': [],
  });
  raw.execute(
    "INSERT INTO questions (id, title, subject_id, created_at, content_version, ocr_raw, ocr_stem, ocr_split_status, question_type, question_type_source, option_labels) VALUES ('q1', '偶函数选择', 'math', 1700000000000, 3, '${ocrRaw.replaceAll("'", "''")}', '下列函数中是偶函数的是', '自动切分', 'choice_single', 'auto', '[\"A\",\"B\",\"C\",\"D\"]')",
  );
  raw.execute(
    "INSERT INTO questions (id, title, subject_id, created_at, content_version) VALUES ('q2', '无 OCR 的题', 'math', 1700000000000, 0)",
  );
  raw.execute("INSERT INTO settings VALUES ('schemaVersion', '5')");
  raw.execute('PRAGMA user_version = 5');
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

Question _q(
  String id, {
  String? questionType,
  List<String>? optionLabels,
  Map<String, String>? optionContents,
  int? optionContentsParserVersion,
  String? ocrRaw,
  String ocrSplitStatus = '未切分',
  int contentVersion = 0,
}) => Question(
  id: id,
  title: '题 $id',
  subjectId: 'math',
  questionType: questionType,
  optionLabels: optionLabels,
  optionContents: optionContents,
  optionContentsParserVersion: optionContentsParserVersion,
  ocrRaw: ocrRaw,
  ocrSplitStatus: ocrSplitStatus,
  contentVersion: contentVersion,
  createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
);

/// 带全文 md 的 ocr_raw（GlmOcrRawData.toJsonString 口径的最小子集：
/// tryParse 只读 md_results；其余键缺失按缺省处理）。
String _ocrRawOf(String md) => jsonEncode({'md_results': md});

void main() {
  // -------------------------------------------------------------------------
  // 统一选项解析器（纯函数）
  // -------------------------------------------------------------------------
  group('parseOptionContents', () {
    test('行首 A. 序列：内容按标签对齐，开头标记去掉', () {
      const md = '下列函数中是偶函数的是\nA. 偶函数\nB. 奇函数\nC. 非奇非偶函数\nD. 既奇又偶函数';
      final parsed = parseOptionContentsForText(md);
      expect(parsed.contents, {
        'A': '偶函数',
        'B': '奇函数',
        'C': '非奇非偶函数',
        'D': '既奇又偶函数',
      });
      expect(parsed.orphans, isEmpty);
      expect(parsed.parserVersion, optionContentsParserVersion);
      expect(parsed.nonEmptyCount, 4);
      expect(parsed.hasStructuredOptions, isTrue);
    });

    test('标记变体：顿号/括号式/全角/冒号都去掉标记只留文字', () {
      const md = '选择正确的\nA、偶函数\nB、奇函数\n（C）非奇非偶\nD：既奇又偶';
      final parsed = parseOptionContentsForText(md);
      expect(parsed.contents, {
        'A': '偶函数',
        'B': '奇函数',
        'C': '非奇非偶',
        'D': '既奇又偶',
      });
    });

    test('同行双栏：A. x B. y 同行也按顺序切开', () {
      const md = '下列说法正确的是 A. 偶函数 B. 奇函数 C. 非奇非偶 D. 既奇又偶';
      final parsed = parseOptionContentsForText(md);
      expect(parsed.contents, {
        'A': '偶函数',
        'B': '奇函数',
        'C': '非奇非偶',
        'D': '既奇又偶',
      });
    });

    test('选项里公式原样保留：反斜杠与上下标不破坏', () {
      const md =
          '下列函数是\nA. \$f(x)=x^2\$\nB. \$g(x)=\\frac{1}{2}x\$\nC. \$h(x)=x_{1}+y^{2}\$\nD. \$k(x)=2x\$';
      final parsed = parseOptionContentsForText(md);
      expect(parsed.contents['A'], r'$f(x)=x^2$');
      expect(parsed.contents['B'], r'$g(x)=\frac{1}{2}x$');
      expect(parsed.contents['C'], r'$h(x)=x_{1}+y^{2}$');
    });

    test('选项里公式内的字母不是标记：\$A+B\$ 不切断选项', () {
      const md = '选择\nA. \$A+B\$ 的值\nB. \$C-D\$ 的值';
      final parsed = parseOptionContentsForText(md);
      expect(parsed.contents, {'A': r'$A+B$ 的值', 'B': r'$C-D$ 的值'});
      expect(parsed.orphans, isEmpty);
    });

    test('有标签无文字允许空：A 空、B 有文字', () {
      const md = '选择\nA. \nB. 奇函数';
      final parsed = parseOptionContentsForText(md);
      expect(parsed.contents, {'A': '', 'B': '奇函数'});
      expect(parsed.nonEmptyCount, 1);
      expect(parsed.hasStructuredOptions, isFalse);
    });

    test('重复标签不覆盖：第二个 B 的文字进 orphans，不丢', () {
      const md = '选择\nA. 偶函数\nB. 奇函数\nB. 重复的 B';
      final parsed = parseOptionContentsForText(md);
      expect(parsed.contents, {'A': '偶函数', 'B': '奇函数'});
      expect(parsed.orphans, ['重复的 B']);
    });

    test('超范围标记不丢弃：F. 的文字进 orphans', () {
      const md = '选择\nA. 偶函数\nB. 奇函数\nF. 多出来的项';
      final parsed = parseOptionContentsForText(md);
      expect(parsed.contents, {'A': '偶函数', 'B': '奇函数'});
      expect(parsed.orphans, ['多出来的项']);
    });

    test('选项配图引用行剥离：内容里不留引用行，引用记入 strippedFigureRefs', () {
      const md =
          '选择\nA. 偶函数\n![](page=0,bbox=[1, 2, 3, 4])\nB. 奇函数';
      final parsed = parseOptionContentsForText(md);
      expect(parsed.contents, {'A': '偶函数', 'B': '奇函数'});
      expect(parsed.strippedFigureRefs, [
        '![](page=0,bbox=[1, 2, 3, 4])',
      ]);
    });

    test('表格选项：<td>A</td><td>文字</td> 也解析', () {
      const md =
          '选择\n<table><tr><td>A</td><td>偶函数</td></tr><tr><td>B</td><td>奇函数</td></tr></table>';
      final parsed = parseOptionContentsForText(md);
      expect(parsed.contents['A'], '偶函数');
      expect(parsed.contents['B'], '奇函数');
    });

    test('无选项标记：contents 为空，不硬猜', () {
      const md = r'求函数 $f(x)=x^2$ 的定义域。';
      final parsed = parseOptionContentsForText(md);
      expect(parsed.contents, isEmpty);
      expect(parsed.hasStructuredOptions, isFalse);
    });

    test('切分失败（notSplit）时解析结果为空：选项区不重复显示的依据', () {
      // 仅 A 一个标记：splitStem 判 notSplit，解析也不产出选项内容。
      const md = '下列说法正确的是\nA. 偶函数';
      final split = splitStem(md);
      expect(split.status, StemSplitStatus.notSplit);
      final parsed = parseOptionContents(md, split);
      expect(parsed.contents, isEmpty);
    });

    test('解析器版本常量为 2', () {
      expect(optionContentsParserVersion, 2);
    });
  });

  // -------------------------------------------------------------------------
  // 分类器：结构化选项内容作选择候选
  // -------------------------------------------------------------------------
  group('classifier structured-options signal', () {
    test('切分失败但有 ≥2 槽选项文字 → 仍判单项选择', () {
      // A 行首强、B 单空格弱、仅两项：splitStem 判 notSplit（结构分不足）。
      const md = '下列函数是偶函数的是 A. 偶函数 B. 奇函数';
      expect(splitStem(md).status, StemSplitStatus.notSplit);
      expect(classifyQuestionText(md).questionType, 'choice_single');
    });

    test('只有 1 槽有文字 → 不作选择候选', () {
      const md = '下列函数是偶函数的是 A. 偶函数 B. ';
      expect(classifyQuestionText(md).questionType, isNull);
    });

    test('判断题不走选项解析：判断信号仍判判断题', () {
      const md = '判断下列说法是否正确，对的打√，错的打×：函数是偶函数。';
      expect(classifyQuestionText(md).questionType, 'true_false');
    });

    test('自动切分的选择题仍判选择（信号互补不改变已有判定）', () {
      const md = '下列函数中是偶函数的是\nA. 偶函数\nB. 奇函数\nC. 非奇非偶\nD. 既奇又偶';
      expect(classifyQuestionText(md).questionType, 'choice_single');
    });
  });

  // -------------------------------------------------------------------------
  // 编解码与校验
  // -------------------------------------------------------------------------
  group('optionContents codec', () {
    test('null ↔ null；空 map 编码为 {}；解码保留 LaTeX 反斜杠', () {
      expect(encodeOptionContents(null), isNull);
      expect(encodeOptionContents(const {}), '{}');
      expect(decodeOptionContents(null), isNull);
      expect(decodeOptionContents(''), isNull);
      expect(
        decodeOptionContents(r'{"A":"$f(x)=x^2$","B":"奇函数"}'),
        {'A': r'$f(x)=x^2$', 'B': '奇函数'},
      );
    });

    test('非法 JSON 解码为 null（读侧可识别，不抛）', () {
      expect(decodeOptionContents('{不是 json'), isNull);
      expect(decodeOptionContents('["A","B"]'), isNull);
      expect(decodeOptionContents('{"A":1}'), isNull);
    });

    test('isValidOptionContentsJson：非法 JSON / 非对象 / 非字符串值 / 非法标签都拒绝', () {
      expect(isValidOptionContentsJson(null), isTrue);
      expect(isValidOptionContentsJson(''), isTrue);
      expect(isValidOptionContentsJson('{}'), isTrue);
      expect(isValidOptionContentsJson('{"A":"偶函数"}'), isTrue);
      expect(isValidOptionContentsJson('{不是 json'), isFalse);
      expect(isValidOptionContentsJson('["A"]'), isFalse);
      expect(isValidOptionContentsJson('{"A":1}'), isFalse);
      expect(isValidOptionContentsJson('{"AA":"偶函数"}'), isFalse);
      expect(isValidOptionContentsJson('{"a":"偶函数"}'), isFalse);
    });

    test('标签映射按标签取：删 B 不影响 C 的键', () {
      const contents = {'A': '偶函数', 'B': '奇函数', 'C': '非奇非偶'};
      final afterDelete = Map<String, String>.of(contents)..remove('B');
      expect(afterDelete, {'A': '偶函数', 'C': '非奇非偶'});
    });
  });

  // -------------------------------------------------------------------------
  // 迁移 v5 → v6
  // -------------------------------------------------------------------------
  group('v5 → v7 migration', () {
    test('v5 库打开即升 v8：旧题保留，新列默认空，DDL 与全新 v8 库一致', () async {
      final tmp = await Directory.systemTemp.createTemp('pkg5-migrate-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = await _v5DbFile(tmp);
      expect(await AppDatabase.deleteLegacyDatabaseIfPresent(dbPath), isFalse);

      final db = await AppDatabase.openAt(dbPath);
      addTearDown(() async => db.close());
      expect(
        (await db.customSelect('PRAGMA user_version').get())
            .single
            .data['user_version'],
        8,
      );
      expect(AppDatabase.schemaVersion, 8);
      final settings = (await db.customSelect(
        'SELECT * FROM settings',
      ).get()).map((r) => r.data).toList();
      expect(
        settings.singleWhere((r) => r['key'] == 'schemaVersion')['value'],
        '8',
      );
      final qs = await AppDatabase.allQuestionsFrom(db);
      expect(qs, hasLength(2));
      final q1 = qs.singleWhere((q) => q.id == 'q1');
      expect(q1.title, '偶函数选择');
      expect(q1.contentVersion, 3);
      // 迁移本身新列默认 NULL；openAt 的 onBeforeOpen 随即跑回填，
      // q1 有 ocr_raw 且自动切分，选项内容当场补齐（迁移 + 回填链路
      // 一次打开即完成）；无 ocr_raw 的 q2 仍为 NULL。
      expect(q1.optionContents, {
        'A': '偶函数',
        'B': '奇函数',
        'C': '非奇非偶函数',
        'D': '既奇又偶函数',
      });
      expect(q1.optionContentsParserVersion, optionContentsParserVersion);
      final q2 = qs.singleWhere((q) => q.id == 'q2');
      expect(q2.optionContents, isNull);
      expect(q2.optionContentsParserVersion, isNull);
      expect(q1.optionLabels, ['A', 'B', 'C', 'D']);
      // 迁移后 DDL 与全新 v6 库逐字一致。
      final freshTmp = await Directory.systemTemp.createTemp('pkg5-fresh-');
      addTearDown(() async {
        try {
          await freshTmp.delete(recursive: true);
        } catch (_) {}
      });
      final freshPath = p.join(freshTmp.path, 'quiz-master2.db');
      final fresh = await AppDatabase.openAt(freshPath);
      addTearDown(() async => fresh.close());
      expect(await _allDdl(dbPath), await _allDdl(freshPath));
    });

    test('重复打开已迁移的库不重复加字段、不报错', () async {
      final tmp = await Directory.systemTemp.createTemp('pkg5-migrate2-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = await _v5DbFile(tmp);
      final db1 = await AppDatabase.openAt(dbPath);
      await db1.close();
      final db2 = await AppDatabase.openAt(dbPath);
      addTearDown(() async => db2.close());
      expect(
        (await db2.customSelect('PRAGMA user_version').get())
            .single
            .data['user_version'],
        8,
      );
      final cols = (await db2.customSelect(
        'PRAGMA table_info(questions)',
      ).get()).map((r) => r.data['name'] as String).toList();
      expect(cols.where((c) => c == 'option_contents'), hasLength(1));
      expect(
        cols.where((c) => c == 'option_contents_parser_version'),
        hasLength(1),
      );
    });

    test('全新 v8 库：新题默认 option_contents 与解析器版本均为 null', () async {
      final db = await _openMemoryDb();
      await AppDatabase.upsertQuestionInto(db, _q('q-new'));
      final q = (await AppDatabase.allQuestionsFrom(db)).single;
      expect(q.optionContents, isNull);
      expect(q.optionContentsParserVersion, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // 备份恢复（双向）
  // -------------------------------------------------------------------------
  group('backup roundtrip', () {
    Future<Map<String, dynamic>> seedAndExport(QuizDatabase db) async {
      await db.into(db.subjects).insert(
        SubjectsCompanion.insert(id: 'math', name: '数学', color: 0xFF2E7CF6),
      );
      await AppDatabase.upsertQuestionInto(
        db,
        _q(
          'q1',
          questionType: 'choice_single',
          optionLabels: const ['A', 'B', 'C', 'D'],
          optionContents: {
            'A': '偶函数',
            'B': r'$g(x)=x^2$',
            'C': '非奇非偶',
            'D': '既奇又偶',
          },
          optionContentsParserVersion: 1,
          contentVersion: 2,
        ),
      );
      return jsonDecode(await AppDatabase.exportBackupJsonFrom(db))
          as Map<String, dynamic>;
    }

    test('v8 → v8：选项内容与解析器版本原样回来（含 LaTeX 反斜杠）', () async {
      final db = await _openMemoryDb();
      final decoded = await seedAndExport(db);
      expect(decoded['_meta']['schemaVersion'], 8);
      await db.customUpdate('DELETE FROM questions');
      await db.customUpdate('DELETE FROM settings');
      await AppDatabase.importBackupJsonInto(db, decoded);
      final q = (await AppDatabase.allQuestionsFrom(db)).single;
      expect(q.optionContents, {
        'A': '偶函数',
        'B': r'$g(x)=x^2$',
        'C': '非奇非偶',
        'D': '既奇又偶',
      });
      expect(q.optionContentsParserVersion, 1);
      expect(q.contentVersion, 2);
    });

    test('v5 → v8：缺 option_contents 键按空值兼容，其余原样', () async {
      final db = await _openMemoryDb();
      final decoded = await seedAndExport(db);
      (decoded['_meta'] as Map<String, dynamic>)['schemaVersion'] = 5;
      for (final row in decoded['questions'] as List) {
        final m = row as Map<String, dynamic>;
        m.remove('option_contents');
        m.remove('option_contents_parser_version');
      }
      await db.customUpdate('DELETE FROM questions');
      await db.customUpdate('DELETE FROM settings');
      await AppDatabase.importBackupJsonInto(db, decoded);
      final q = (await AppDatabase.allQuestionsFrom(db)).single;
      expect(q.optionContents, isNull);
      expect(q.optionContentsParserVersion, isNull);
      expect(q.questionType, 'choice_single');
      expect(q.optionLabels, ['A', 'B', 'C', 'D']);
    });

    test('v9 备份被旧版本恢复时明确报错：schemaVersion > 当前版本拒绝', () {
      final decoded = <String, dynamic>{
        '_meta': {'schemaVersion': 9, 'appVersion': '0.1.0+1'},
        'subjects': <dynamic>[],
        'questions': <dynamic>[],
        'question_boxes': <dynamic>[],
        'folders': <dynamic>[],
        'tags': <dynamic>[],
        'exams': <dynamic>[],
        'knowledge_points': <dynamic>[],
        'cause_records': <dynamic>[],
        'collect_tasks': <dynamic>[],
        'review_state': <dynamic>[],
        'review_history': <dynamic>[],
        'recent_tasks': <dynamic>[],
        'recently_viewed_questions': <dynamic>[],
        'ocr_jobs': <dynamic>[],
        'settings': <dynamic>[],
        'attempts': <dynamic>[],
      };
      expect(
        () => AppDatabase.validateBackupData(decoded),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.message,
            'message',
            contains('更新的版本'),
          ),
        ),
      );
    });

    test('非法 option_contents JSON 拒绝整个恢复（可识别，不静默丢）', () async {
      final db = await _openMemoryDb();
      final decoded = await seedAndExport(db);
      final row = (decoded['questions'] as List).single as Map<String, dynamic>;
      row['option_contents'] = '{不是 json';
      expect(
        () => AppDatabase.validateBackupData(decoded),
        throwsA(isA<BackupRestoreException>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // 回填（ocr_raw → option_contents）
  // -------------------------------------------------------------------------
  group('backfillOptionContents', () {
    test('有 ocr_raw 且自动切分：回填选项内容，ocr_raw 原文保留，记解析器版本', () async {
      final db = await _openMemoryDb();
      const md = '下列函数中是偶函数的是\nA. 偶函数\nB. 奇函数\nC. 非奇非偶\nD. 既奇又偶';
      await AppDatabase.upsertQuestionInto(
        db,
        _q(
          'q1',
          questionType: 'choice_single',
          optionLabels: const ['A', 'B', 'C', 'D'],
          ocrRaw: _ocrRawOf(md),
          ocrSplitStatus: '自动切分',
          contentVersion: 3,
        ),
      );
      final filled = await AppDatabase.backfillOptionContentsInto(db);
      expect(filled, 1);
      final q = (await AppDatabase.allQuestionsFrom(db)).single;
      expect(q.optionContents, {
        'A': '偶函数',
        'B': '奇函数',
        'C': '非奇非偶',
        'D': '既奇又偶',
      });
      expect(q.optionContentsParserVersion, optionContentsParserVersion);
      expect(q.ocrRaw, _ocrRawOf(md));
      expect(q.contentVersion, 3, reason: '回填不抬 content_version');
    });

    test('回填幂等：第二次回填 0 行，内容不变', () async {
      final db = await _openMemoryDb();
      const md = '选择\nA. 偶函数\nB. 奇函数';
      await AppDatabase.upsertQuestionInto(
        db,
        _q('q1', ocrRaw: _ocrRawOf(md), ocrSplitStatus: '自动切分'),
      );
      expect(await AppDatabase.backfillOptionContentsInto(db), 1);
      expect(await AppDatabase.backfillOptionContentsInto(db), 0);
      final q = (await AppDatabase.allQuestionsFrom(db)).single;
      expect(q.optionContents, {'A': '偶函数', 'B': '奇函数'});
    });

    test('人工改过的选项不覆盖：已有 option_contents 的题不动', () async {
      final db = await _openMemoryDb();
      const md = '选择\nA. 偶函数\nB. 奇函数';
      await AppDatabase.upsertQuestionInto(
        db,
        _q(
          'q1',
          optionLabels: const ['A', 'B'],
          optionContents: const {'A': '人工改的', 'B': '奇函数'},
          ocrRaw: _ocrRawOf(md),
          ocrSplitStatus: '自动切分',
        ),
      );
      expect(await AppDatabase.backfillOptionContentsInto(db), 0);
      final q = (await AppDatabase.allQuestionsFrom(db)).single;
      expect(q.optionContents, {'A': '人工改的', 'B': '奇函数'});
      expect(q.optionContentsParserVersion, isNull);
    });

    test('判断题不回填选项内容', () async {
      final db = await _openMemoryDb();
      const md = '判断\nA. 偶函数\nB. 奇函数';
      await AppDatabase.upsertQuestionInto(
        db,
        _q(
          'q1',
          questionType: 'true_false',
          ocrRaw: _ocrRawOf(md),
          ocrSplitStatus: '自动切分',
        ),
      );
      expect(await AppDatabase.backfillOptionContentsInto(db), 0);
      final q = (await AppDatabase.allQuestionsFrom(db)).single;
      expect(q.optionContents, isNull);
    });

    test('未切分（notSplit）的题不回填：选项区不重复显示', () async {
      final db = await _openMemoryDb();
      const md = '下列说法正确的是\nA. 偶函数';
      await AppDatabase.upsertQuestionInto(
        db,
        _q('q1', ocrRaw: _ocrRawOf(md), ocrSplitStatus: '未切分'),
      );
      expect(await AppDatabase.backfillOptionContentsInto(db), 0);
      final q = (await AppDatabase.allQuestionsFrom(db)).single;
      expect(q.optionContents, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // 模型与 upsert：标签删除只动对应键
  // -------------------------------------------------------------------------
  group('optionContents model + upsert', () {
    test('upsert 往返：选项内容与解析器版本原样存取', () async {
      final db = await _openMemoryDb();
      await AppDatabase.upsertQuestionInto(
        db,
        _q(
          'q1',
          optionLabels: const ['A', 'B'],
          optionContents: const {'A': '偶函数', 'B': '奇函数'},
          optionContentsParserVersion: 1,
        ),
      );
      final q = (await AppDatabase.allQuestionsFrom(db)).single;
      expect(q.optionContents, {'A': '偶函数', 'B': '奇函数'});
      expect(q.optionContentsParserVersion, 1);
    });

    test('删标签 B：对应选项内容键随之删，A/C 的键与文字不动（不串位）', () async {
      final db = await _openMemoryDb();
      await AppDatabase.upsertQuestionInto(
        db,
        _q(
          'q1',
          questionType: 'choice_single',
          optionLabels: const ['A', 'B', 'C'],
          optionContents: const {'A': '偶函数', 'B': '奇函数', 'C': '非奇非偶'},
          optionContentsParserVersion: 1,
        ),
      );
      final saved = (await AppDatabase.allQuestionsFrom(db)).single;
      await AppDatabase.upsertQuestionInto(
        db,
        saved.copyWith(
          optionLabels: const ['A', 'C'],
          optionContents: const {'A': '偶函数', 'C': '非奇非偶'},
        ),
      );
      final q = (await AppDatabase.allQuestionsFrom(db)).single;
      expect(q.optionLabels, ['A', 'C']);
      expect(q.optionContents, {'A': '偶函数', 'C': '非奇非偶'});
    });

    test('改选项文字：content_version +1（选项文字是内容，不是答案）', () async {
      final db = await _openMemoryDb();
      await AppDatabase.upsertQuestionInto(
        db,
        _q(
          'q1',
          optionLabels: const ['A', 'B'],
          optionContents: const {'A': '偶函数', 'B': '奇函数'},
          contentVersion: 5,
        ),
      );
      final saved = (await AppDatabase.allQuestionsFrom(db)).single;
      await AppDatabase.upsertQuestionInto(
        db,
        saved.copyWith(
          optionContents: const {'A': '偶函数改', 'B': '奇函数'},
        ),
      );
      final q = (await AppDatabase.allQuestionsFrom(db)).single;
      expect(q.optionContents?['A'], '偶函数改');
      expect(q.contentVersion, 6);
    });
  });
}
