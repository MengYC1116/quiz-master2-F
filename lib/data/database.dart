import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/models.dart';
import 'badge_notifier.dart';
import 'demo_data.dart';

/// v2 全新数据库（version 1，无迁移历史；旧库不兼容，v2 首次建库即此结构）。
/// - Win11：`%LOCALAPPDATA%\quiz-master2\quiz-master2.db`；
///   切片图也放同一数据目录；安装目录只放程序。
/// - Linux 验证环境：`$XDG_DATA_HOME/quiz-master2/`，未设置时
///   `~/.local/share/quiz-master2/`。
/// 数据目录不可写时才回退到可执行文件同级的 `data/` 子目录。
/// v2 与 v1 的关键差别：文件夹按学科分（subject_id + parent_id +
/// sort_order）；subjects 表带封面样式/颜色；新增 settings 表；
/// questions 表删掉旧复习字段（review_status / next_review /
/// overdue_days，旧 1/3/7/14 口径已废弃）。
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Database? _db;
  String? dbPathUsed;

  /// 数据库位置可改：设置页改位置后，把新路径写进默认数据目录下的
  /// `db_location.txt` 标记文件；下次启动先读标记文件，读到就用它。
  /// （设置本身存在数据库里，换库后读不到旧设置，所以位置必须存在库外。）
  static String dataDirectoryPath() {
    final def = _defaultDataDirectoryPath();
    try {
      final marker = File(p.join(def, 'db_location.txt'));
      if (marker.existsSync()) {
        final custom = marker.readAsStringSync().trim();
        if (custom.isNotEmpty) return custom;
      }
    } catch (_) {}
    return def;
  }

  /// 改数据库位置：写标记文件（下次启动生效，须重启）。
  Future<void> setCustomDataDirectory(String dir) async {
    final def = _defaultDataDirectoryPath();
    final markerDir = Directory(def);
    await markerDir.create(recursive: true);
    await File(p.join(def, 'db_location.txt')).writeAsString(dir);
    await saveSetting('databaseLocation', dir);
  }

  static String _defaultDataDirectoryPath() {
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        return p.join(localAppData, 'quiz-master2');
      }
      return p.join(Platform.environment['USERPROFILE'] ?? '', 'AppData',
          'Local', 'quiz-master2');
    }
    final xdg = Platform.environment['XDG_DATA_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      return p.join(xdg, 'quiz-master2');
    }
    final home = Platform.environment['HOME'] ?? '';
    return p.join(home, '.local', 'share', 'quiz-master2');
  }

  Future<Database> get db async {
    if (_db != null) return _db!;
    sqfliteFfiInit();
    final factory = databaseFactoryFfi;
    final dataDir = Directory(dataDirectoryPath());
    await dataDir.create(recursive: true);
    var dbPath = p.join(dataDir.path, 'quiz-master2.db');
    try {
      _db = await factory.openDatabase(dbPath,
          options: OpenDatabaseOptions(
              version: 1, onCreate: _onCreate));
    } catch (_) {
      final installDir = p.dirname(Platform.resolvedExecutable);
      final fallbackDir = Directory(p.join(installDir, 'data'));
      await fallbackDir.create(recursive: true);
      dbPath = p.join(fallbackDir.path, 'quiz-master2.db');
      _db = await factory.openDatabase(dbPath,
          options: OpenDatabaseOptions(
              version: 1, onCreate: _onCreate));
    }
    dbPathUsed = dbPath;
    return _db!;
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE subjects(
        id TEXT PRIMARY KEY, name TEXT NOT NULL, color INTEGER NOT NULL,
        cover_style TEXT NOT NULL DEFAULT 'plain',
        cover_color TEXT NOT NULL DEFAULT 'blue')''');
    await db.execute('''
      CREATE TABLE questions(
        id TEXT PRIMARY KEY, title TEXT NOT NULL, subject_id TEXT NOT NULL,
        folder_ids TEXT NOT NULL DEFAULT '', exam_id TEXT,
        knowledge_ids TEXT NOT NULL DEFAULT '',
        error_types TEXT NOT NULL DEFAULT '',
        custom_error_types TEXT NOT NULL DEFAULT '',
        tags TEXT NOT NULL DEFAULT '', answer TEXT, explanation TEXT,
        notes TEXT, review_count INTEGER NOT NULL DEFAULT 0,
        is_organized INTEGER NOT NULL DEFAULT 0,
        is_demo INTEGER NOT NULL DEFAULT 0,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        is_archived INTEGER NOT NULL DEFAULT 0,
        review_joined INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL, slice_kind TEXT NOT NULL DEFAULT 'material',
        slice_text TEXT NOT NULL DEFAULT '')''');
    await db.execute('''
      CREATE TABLE folders(
        id TEXT PRIMARY KEY, name TEXT NOT NULL, subject_id TEXT NOT NULL,
        parent_id TEXT, sort_order INTEGER NOT NULL DEFAULT 0)''');
    await db.execute('''
      CREATE TABLE tags(id TEXT PRIMARY KEY, name TEXT NOT NULL)''');
    await db.execute('''
      CREATE TABLE exams(id TEXT PRIMARY KEY, name TEXT NOT NULL, date INTEGER)''');
    await db.execute('''
      CREATE TABLE knowledge_points(
        id TEXT PRIMARY KEY, subject_id TEXT NOT NULL,
        chapter TEXT NOT NULL, name TEXT NOT NULL)''');
    await db.execute('''
      CREATE TABLE collect_tasks(
        id TEXT PRIMARY KEY, name TEXT NOT NULL, file_name TEXT NOT NULL,
        subject_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'queued',
        progress INTEGER NOT NULL DEFAULT 0, page_count INTEGER NOT NULL DEFAULT 1,
        page INTEGER NOT NULL DEFAULT 1, error TEXT, question_id TEXT)''');
    await db.execute('''
      CREATE TABLE cause_records(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        question_id TEXT NOT NULL, cause TEXT NOT NULL,
        subject_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
        solved_count INTEGER NOT NULL DEFAULT 0,
        last_check INTEGER, recheck_date INTEGER,
        remedy_history TEXT NOT NULL DEFAULT '',
        joined_at INTEGER NOT NULL,
        UNIQUE(question_id, cause))''');
    await db.execute('''
      CREATE TABLE review_state(
        id INTEGER PRIMARY KEY CHECK (id = 1),
        queue TEXT NOT NULL DEFAULT '', position INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL)''');
    await db.execute('''
      CREATE TABLE review_history(
        id INTEGER PRIMARY KEY AUTOINCREMENT, question_id TEXT NOT NULL,
        result TEXT NOT NULL, reviewed_at INTEGER NOT NULL)''');
    await db.execute('''
      CREATE TABLE recent_tasks(
        id INTEGER PRIMARY KEY CHECK (id = 1), kind TEXT NOT NULL,
        subject_id TEXT NOT NULL, title TEXT NOT NULL,
        updated_at INTEGER NOT NULL)''');
    await db.execute('''
      CREATE TABLE settings(
        key TEXT PRIMARY KEY, value TEXT NOT NULL)''');
    await _seed(db);
  }

  static Future<void> _seedCauseRecordsFor(Database db, Question q,
      {required DateTime joinedAt, int solvedCount = 0}) async {
    for (final cause in q.allCauses) {
      await db.insert(
        'cause_records',
        {
          'question_id': q.id,
          'cause': cause,
          'subject_id': q.subjectId,
          'status': 'pending',
          'solved_count': solvedCount,
          'last_check': null,
          'recheck_date': null,
          'remedy_history': '',
          'joined_at': joinedAt.millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  static Future<void> _seed(Database db) async {
    for (final s in Subject.all) {
      await db.insert('subjects', {
        'id': s.id,
        'name': s.name,
        'color': s.color.toARGB32(),
        'cover_style': 'plain',
        'cover_color': switch (s.id) {
          'math' => 'blue',
          'english' => 'green',
          _ => 'red',
        },
      });
    }
    // 每科一套预置文件夹（v2：文件夹按学科分）。
    for (final s in Subject.all) {
      for (var i = 0; i < presetFolders.length; i++) {
        final f = presetFolders[i];
        await db.insert('folders', {
          'id': 'folder-${s.id}-$f',
          'name': f,
          'subject_id': s.id,
          'parent_id': null,
          'sort_order': i,
        });
      }
    }
    for (final t in presetTags) {
      await db.insert('tags', {'id': 'tag-$t', 'name': t});
    }
    for (final e in demoExams()) {
      await db.insert('exams', {
        'id': e.id,
        'name': e.name,
        'date': e.date?.millisecondsSinceEpoch,
      });
    }
    for (final kp in demoKnowledgePoints()) {
      await db.insert('knowledge_points', {
        'id': kp.id,
        'subject_id': kp.subjectId,
        'chapter': kp.chapter,
        'name': kp.name,
      });
    }
    for (final q in demoQuestions()) {
      await db.insert('questions', _toRow(q));
    }
    // 演示种子：7 道题已加入复习（加入顺序 m1, m2, e1, m3, p1, e2, p3），
    // 其余演示题未加入。m2/e2/p1/p3 未整理，进不了复习列表（模型要求
    // 已整理）， clean demo 下复习列表实际显示 3 组（m1 待解决、e1 复查、
    // m3 解决中），与首页焦点卡的 7 道一致（焦点卡数题不数错因）。
    final joinOrder = [
      'q-math-1',
      'q-math-2',
      'q-eng-1',
      'q-math-3',
      'q-pol-1',
      'q-eng-2',
      'q-pol-3',
    ];
    final base = DateTime.now().subtract(const Duration(days: 9));
    final byId = {for (final q in demoQuestions()) q.id: q};
    for (var i = 0; i < joinOrder.length; i++) {
      final q = byId[joinOrder[i]]!;
      await _seedCauseRecordsFor(db, q,
          joinedAt: base.add(Duration(minutes: i)));
    }
    // 演示“解决中”：q-math-3 计算错误已自查“已解决”1 次，还差 1 次。
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    await db.update(
      'cause_records',
      {
        'status': 'inProgress',
        'solved_count': 1,
        'last_check': yesterday.millisecondsSinceEpoch,
      },
      where: 'question_id = ? AND cause = ?',
      whereArgs: ['q-math-3', '计算错误'],
    );
    // 演示“复查”：q-eng-1 概念不清已解决，复查日为昨天（已到复查时间）。
    await db.update(
      'cause_records',
      {
        'status': 'solved',
        'solved_count': 2,
        'last_check': yesterday.millisecondsSinceEpoch,
        'recheck_date': yesterday.millisecondsSinceEpoch,
      },
      where: 'question_id = ? AND cause = ?',
      whereArgs: ['q-eng-1', '概念不清'],
    );
    await db.insert('recent_tasks', {
      'id': 1,
      'kind': '整理',
      'subject_id': 'math',
      'title': '函数极限',
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  static Map<String, Object?> _toRow(Question q) => {
        'id': q.id,
        'title': q.title,
        'subject_id': q.subjectId,
        'folder_ids': q.folderIds.join(','),
        'exam_id': q.examId,
        'knowledge_ids': q.knowledgePointIds.join(','),
        'error_types': q.errorTypes.join(','),
        'custom_error_types': q.customErrorTypes.join(','),
        'tags': q.tags.join(','),
        'answer': q.answer,
        'explanation': q.explanation,
        'notes': q.notes,
        'review_count': q.reviewCount,
        'is_organized': q.isOrganized ? 1 : 0,
        'is_demo': q.isDemo ? 1 : 0,
        'is_favorite': q.isFavorite ? 1 : 0,
        'is_archived': q.isArchived ? 1 : 0,
        'review_joined': q.reviewJoined ? 1 : 0,
        'created_at': q.createdAt.millisecondsSinceEpoch,
        'slice_kind': q.sliceKind,
        'slice_text': q.sliceText,
      };

  static Question _fromRow(Map<String, Object?> r) {
    List<String> split(Object? v) =>
        (v as String?)?.split(',').where((e) => e.isNotEmpty).toList() ?? [];
    return Question(
      id: r['id'] as String,
      title: r['title'] as String,
      subjectId: r['subject_id'] as String,
      folderIds: split(r['folder_ids']),
      examId: r['exam_id'] as String?,
      knowledgePointIds: split(r['knowledge_ids']),
      errorTypes: split(r['error_types']),
      customErrorTypes: split(r['custom_error_types']),
      tags: split(r['tags']),
      answer: r['answer'] as String?,
      explanation: r['explanation'] as String?,
      notes: r['notes'] as String?,
      reviewCount: (r['review_count'] as int?) ?? 0,
      isOrganized: (r['is_organized'] as int?) == 1,
      isDemo: (r['is_demo'] as int?) == 1,
      isFavorite: (r['is_favorite'] as int?) == 1,
      isArchived: (r['is_archived'] as int?) == 1,
      reviewJoined: (r['review_joined'] as int?) == 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      sliceKind: (r['slice_kind'] as String?) ?? 'material',
      sliceText: (r['slice_text'] as String?) ?? '',
    );
  }

  Future<List<Question>> allQuestions() async {
    final d = await db;
    final rows = await d.query('questions', orderBy: 'created_at DESC');
    return rows.map(_fromRow).toList();
  }

  Future<Question?> questionById(String id) async {
    final d = await db;
    final rows =
        await d.query('questions', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
      String questionId) async {
    final d = await db;
    final rows = await d.query('review_history',
        where: 'question_id = ?',
        whereArgs: [questionId],
        orderBy: 'reviewed_at DESC');
    return rows
        .map((r) => (
              result: r['result'] as String,
              reviewedAt: DateTime.fromMillisecondsSinceEpoch(
                  r['reviewed_at'] as int),
            ))
        .toList();
  }

  Future<void> addCauseCheckHistory(
      {required String questionId, required String result}) async {
    final d = await db;
    await d.insert('review_history', {
      'question_id': questionId,
      'result': result,
      'reviewed_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  static CauseRecord _causeFromRow(Map<String, Object?> r) {
    List<String> splitRemedies(Object? v) {
      final s = (v as String?) ?? '';
      if (s.isEmpty) return const [];
      return s.split('\n---\n').where((e) => e.isNotEmpty).toList();
    }

    return CauseRecord(
      questionId: r['question_id'] as String,
      cause: r['cause'] as String,
      subjectId: r['subject_id'] as String,
      status: switch (r['status'] as String?) {
        'inProgress' => CauseStatus.inProgress,
        'solved' => CauseStatus.solved,
        _ => CauseStatus.pending,
      },
      solvedCount: (r['solved_count'] as int?) ?? 0,
      lastCheck: r['last_check'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(r['last_check'] as int),
      recheckDate: r['recheck_date'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(r['recheck_date'] as int),
      remedyHistory: splitRemedies(r['remedy_history']),
      joinedAt: DateTime.fromMillisecondsSinceEpoch(r['joined_at'] as int),
    );
  }

  Future<List<CauseRecord>> allCauseRecords() async {
    final d = await db;
    final rows =
        await d.query('cause_records', orderBy: 'joined_at ASC, id ASC');
    return rows.map(_causeFromRow).toList();
  }

  Future<List<CauseRecord>> causeRecordsForQuestion(
      String questionId) async {
    final d = await db;
    final rows = await d.query('cause_records',
        where: 'question_id = ?', whereArgs: [questionId], orderBy: 'id ASC');
    return rows.map(_causeFromRow).toList();
  }

  Future<void> ensureCauseRecords(Question q) async {
    final d = await db;
    await _seedCauseRecordsFor(d, q, joinedAt: DateTime.now());
  }

  Future<void> upsertCauseRecord(CauseRecord r) async {
    final d = await db;
    await d.insert(
      'cause_records',
      {
        'question_id': r.questionId,
        'cause': r.cause,
        'subject_id': r.subjectId,
        'status': r.status.name,
        'solved_count': r.solvedCount,
        'last_check': r.lastCheck?.millisecondsSinceEpoch,
        'recheck_date': r.recheckDate?.millisecondsSinceEpoch,
        'remedy_history': r.remedyHistory.join('\n---\n'),
        'joined_at': r.joinedAt.millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    bumpBadgeVersion();
  }

  Future<void> deleteCauseRecordsForQuestion(String questionId) async {
    final d = await db;
    await d.delete('cause_records',
        where: 'question_id = ?', whereArgs: [questionId]);
  }

  Future<void> deleteCauseRecord(String questionId, String cause) async {
    final d = await db;
    await d.delete('cause_records',
        where: 'question_id = ? AND cause = ?',
        whereArgs: [questionId, cause]);
  }

  Future<void> saveReviewState(
      {required List<String> queue, required int position}) async {
    final d = await db;
    await d.insert('review_state', {
      'id': 1,
      'queue': queue.join(','),
      'position': position,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<ReviewSessionState?> loadReviewState() async {
    final d = await db;
    final rows = await d.query('review_state', where: 'id = 1', limit: 1);
    if (rows.isEmpty) return null;
    final r = rows.first;
    final queue = ((r['queue'] as String?) ?? '')
        .split(',')
        .where((e) => e.isNotEmpty)
        .toList();
    if (queue.isEmpty) return null;
    return ReviewSessionState(
      queue: queue,
      position: (r['position'] as int?) ?? 0,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
    );
  }

  Future<void> clearReviewState() async {
    final d = await db;
    await d.delete('review_state', where: 'id = 1');
  }

  // ---------- 学科 / 文件夹 / 标签 / 试卷 / 知识点 ----------

  Future<List<Subject>> allSubjects() async {
    final d = await db;
    // 显式按插入顺序读：subjects 表没有 sort_order 列，顺序就是 rowid 顺序；
    // 不写 orderBy 时 SQLite 不保证返回顺序，曾经因此出现过学科乱序。
    final rows = await d.query('subjects', orderBy: 'rowid');
    return rows
        .map((r) => Subject(
              id: r['id'] as String,
              name: r['name'] as String,
              color: Color((r['color'] as int?) ?? 0xFF2F7CF6),
              icon: _iconFor(r['id'] as String),
              coverStyle: (r['cover_style'] as String?) ?? 'plain',
              coverColor: (r['cover_color'] as String?) ?? 'blue',
            ))
        .toList();
  }

  static String _iconFor(String id) => switch (id) {
        'math' => '数',
        'english' => '英',
        'politics' => '政',
        _ => id.isEmpty ? '学' : id[0],
      };

  Future<void> upsertSubject(Subject s) async {
    final d = await db;
    final values = {
      'id': s.id,
      'name': s.name,
      'color': s.color.toARGB32(),
      'cover_style': s.coverStyle,
      'cover_color': s.coverColor,
    };
    // 原地更新：ConflictAlgorithm.replace 是先删后插，会把这行顶到表尾，
    // 导致学科顺序乱掉（点数学的封面，数学就跑到最下面）。已存在的行只
    // UPDATE，rowid 不变，顺序就不会动；不存在时才 INSERT。
    final updated = await d.update('subjects', values,
        where: 'id = ?', whereArgs: [s.id]);
    if (updated == 0) {
      await d.insert('subjects', values);
    }
    bumpBadgeVersion();
  }

  Future<void> deleteSubject(String id) async {
    final d = await db;
    final qs = await d.query('questions',
        columns: ['id'], where: 'subject_id = ?', whereArgs: [id]);
    for (final row in qs) {
      await d.delete('cause_records',
          where: 'question_id = ?', whereArgs: [row['id'] as String]);
    }
    await d.delete('questions', where: 'subject_id = ?', whereArgs: [id]);
    await d.delete('folders', where: 'subject_id = ?', whereArgs: [id]);
    await d.delete('knowledge_points',
        where: 'subject_id = ?', whereArgs: [id]);
    await d.delete('subjects', where: 'id = ?', whereArgs: [id]);
    bumpBadgeVersion();
  }

  Future<List<Folder>> allFolders({String? subjectId}) async {
    final d = await db;
    final rows = subjectId == null
        ? await d.query('folders', orderBy: 'subject_id ASC, sort_order ASC')
        : await d.query('folders',
            where: 'subject_id = ?',
            whereArgs: [subjectId],
            orderBy: 'sort_order ASC');
    return rows
        .map((r) => Folder(
              id: r['id'] as String,
              name: r['name'] as String,
              subjectId: r['subject_id'] as String,
              parentId: r['parent_id'] as String?,
              sortOrder: (r['sort_order'] as int?) ?? 0,
            ))
        .toList();
  }

  Future<void> upsertFolder(Folder f) async {
    final d = await db;
    await d.insert('folders', {
      'id': f.id,
      'name': f.name,
      'subject_id': f.subjectId,
      'parent_id': f.parentId,
      'sort_order': f.sortOrder,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    bumpBadgeVersion();
  }

  /// 删文件夹：只在这个文件夹里的题跟着删；在多个文件夹里的题只移走
  /// 这个文件夹的关联。返回删掉的题数。
  Future<int> deleteFolder(Folder f) async {
    final d = await db;
    final rows = await d.query('questions');
    var deleted = 0;
    for (final row in rows) {
      final q = _fromRow(row);
      if (!q.folderIds.contains(f.id)) continue;
      if (q.folderIds.length == 1) {
        await deleteQuestion(q.id);
        deleted++;
      } else {
        final rest = q.folderIds.where((e) => e != f.id).toList();
        await d.update('questions', {'folder_ids': rest.join(',')},
            where: 'id = ?', whereArgs: [q.id]);
      }
    }
    // 子文件夹随父文件夹一起删（同规则递归到子文件夹里的题）。
    final subs = await d.query('folders',
        where: 'parent_id = ?', whereArgs: [f.id]);
    for (final s in subs) {
      final sub = Folder(
          id: s['id'] as String,
          name: s['name'] as String,
          subjectId: s['subject_id'] as String,
          parentId: s['parent_id'] as String?);
      deleted += await deleteFolder(sub);
    }
    await d.delete('folders', where: 'id = ?', whereArgs: [f.id]);
    bumpBadgeVersion();
    return deleted;
  }

  Future<List<String>> allTags() async {
    final d = await db;
    final rows = await d.query('tags');
    return rows.map((r) => r['name'] as String).toList();
  }

  Future<void> insertTag(String name) async {
    final d = await db;
    await d.insert('tags', {'id': 'tag-$name', 'name': name},
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> renameTag(String oldName, String newName) async {
    final d = await db;
    await d.update('tags', {'id': 'tag-$newName', 'name': newName},
        where: 'name = ?', whereArgs: [oldName]);
    final rows = await d.query('questions');
    for (final row in rows) {
      final q = _fromRow(row);
      if (!q.tags.contains(oldName)) continue;
      final tags = q.tags.map((t) => t == oldName ? newName : t).toList();
      await d.update('questions', {'tags': tags.join(',')},
          where: 'id = ?', whereArgs: [q.id]);
    }
  }

  Future<void> deleteTag(String name) async {
    final d = await db;
    await d.delete('tags', where: 'name = ?', whereArgs: [name]);
    final rows = await d.query('questions');
    for (final row in rows) {
      final q = _fromRow(row);
      if (!q.tags.contains(name)) continue;
      final tags = q.tags.where((t) => t != name).toList();
      await d.update('questions', {'tags': tags.join(',')},
          where: 'id = ?', whereArgs: [q.id]);
    }
  }

  Future<List<Exam>> allExams() async {
    final d = await db;
    final rows = await d.query('exams');
    return rows
        .map((r) => Exam(
              id: r['id'] as String,
              name: r['name'] as String,
              date: r['date'] == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(r['date'] as int),
            ))
        .toList();
  }

  Future<void> insertExam(Exam e) async {
    final d = await db;
    await d.insert('exams', {
      'id': e.id,
      'name': e.name,
      'date': e.date?.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> renameExam(String id, String newName) async {
    final d = await db;
    await d.update('exams', {'name': newName},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteExam(String id) async {
    final d = await db;
    await d.update('exams', {'name': ''}, where: 'id = ?', whereArgs: [id]);
    await d.delete('exams', where: 'id = ?', whereArgs: [id]);
    await d.update('questions', {'exam_id': null},
        where: 'exam_id = ?', whereArgs: [id]);
  }

  Future<List<KnowledgePoint>> allKnowledgePoints() async {
    final d = await db;
    final rows = await d.query('knowledge_points');
    return rows
        .map((r) => KnowledgePoint(
              id: r['id'] as String,
              subjectId: r['subject_id'] as String,
              chapter: r['chapter'] as String,
              name: r['name'] as String,
            ))
        .toList();
  }

  Future<void> insertKnowledgePoint(KnowledgePoint kp) async {
    final d = await db;
    await d.insert('knowledge_points', {
      'id': kp.id,
      'subject_id': kp.subjectId,
      'chapter': kp.chapter,
      'name': kp.name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> renameKnowledgePoint(String id, String newName) async {
    final d = await db;
    await d.update('knowledge_points', {'name': newName},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteKnowledgePoint(String id) async {
    final d = await db;
    await d.delete('knowledge_points', where: 'id = ?', whereArgs: [id]);
    final rows = await d.query('questions');
    for (final row in rows) {
      final q = _fromRow(row);
      if (!q.knowledgePointIds.contains(id)) continue;
      final kps = q.knowledgePointIds.where((e) => e != id).toList();
      await d.update('questions', {'knowledge_ids': kps.join(',')},
          where: 'id = ?', whereArgs: [q.id]);
    }
  }

  /// 章节改名：只改 `knowledge_points.chapter` 的名字，题上挂的知识点
  /// id 不变，题跟着改名。空章节存不下来（章节只随知识点存在），
  /// 所以加章节仍须同时给第一个知识点（见 repository.addChapter）。
  Future<void> renameChapter(
      String subjectId, String oldChapter, String newChapter) async {
    final d = await db;
    await d.update('knowledge_points', {'chapter': newChapter},
        where: 'subject_id = ? AND chapter = ?',
        whereArgs: [subjectId, oldChapter]);
  }

  /// 删除章节：删掉该章节下全部知识点；题还在，只是这些知识点变空、
  /// 成为待补充（与删知识点同一口径）。
  Future<void> deleteChapter(String subjectId, String chapter) async {
    final d = await db;
    final rows = await d.query('knowledge_points',
        columns: ['id'],
        where: 'subject_id = ? AND chapter = ?',
        whereArgs: [subjectId, chapter]);
    final ids = rows.map((r) => r['id'] as String).toList();
    await d.delete('knowledge_points',
        where: 'subject_id = ? AND chapter = ?',
        whereArgs: [subjectId, chapter]);
    if (ids.isEmpty) return;
    final qrows = await d.query('questions');
    for (final row in qrows) {
      final q = _fromRow(row);
      final kept =
          q.knowledgePointIds.where((e) => !ids.contains(e)).toList();
      if (kept.length == q.knowledgePointIds.length) continue;
      await d.update('questions', {'knowledge_ids': kept.join(',')},
          where: 'id = ?', whereArgs: [q.id]);
    }
  }

  Future<void> upsertQuestion(Question q) async {
    final d = await db;
    await d.insert('questions', _toRow(q),
        conflictAlgorithm: ConflictAlgorithm.replace);
    bumpBadgeVersion();
  }

  Future<void> deleteQuestion(String id) async {
    final d = await db;
    await d.delete('cause_records', where: 'question_id = ?', whereArgs: [id]);
    await d.delete('questions', where: 'id = ?', whereArgs: [id]);
    bumpBadgeVersion();
  }

  Future<({String kind, String subjectId, String title})?> recentTask() async {
    final d = await db;
    final rows = await d.query('recent_tasks', where: 'id = 1', limit: 1);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return (
      kind: r['kind'] as String,
      subjectId: r['subject_id'] as String,
      title: r['title'] as String,
    );
  }

  Future<void> saveRecentTask(
      {required String kind,
      required String subjectId,
      required String title}) async {
    final d = await db;
    await d.insert('recent_tasks', {
      'id': 1,
      'kind': kind,
      'subject_id': subjectId,
      'title': title,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 一键清空演示数据（只删 is_demo = 1 的题，同时删其解决记录与断点）。
  Future<int> clearDemoData() async {
    final d = await db;
    final demoRows = await d.query('questions',
        columns: ['id'], where: 'is_demo = 1');
    for (final row in demoRows) {
      await d.delete('cause_records',
          where: 'question_id = ?', whereArgs: [row['id'] as String]);
    }
    await clearReviewState();
    final n = await d.delete('questions', where: 'is_demo = 1');
    bumpBadgeVersion();
    return n;
  }

  Future<int> demoQuestionCount() async {
    final d = await db;
    final rows = await d.rawQuery(
        'SELECT COUNT(*) AS n FROM questions WHERE is_demo = 1');
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<List<CollectTask>> allCollectTasks() async {
    final d = await db;
    final rows = await d.query('collect_tasks', orderBy: 'rowid DESC');
    return rows
        .map((r) => CollectTask(
              id: r['id'] as String,
              name: r['name'] as String,
              fileName: r['file_name'] as String,
              subjectId: r['subject_id'] as String,
              status: CollectStatus.values.firstWhere(
                  (s) => s.name == r['status'],
                  orElse: () => CollectStatus.queued),
              progress: (r['progress'] as int?) ?? 0,
              pageCount: (r['page_count'] as int?) ?? 1,
              page: (r['page'] as int?) ?? 1,
              error: r['error'] as String?,
              questionId: r['question_id'] as String?,
            ))
        .toList();
  }

  Future<void> upsertCollectTask(CollectTask t) async {
    final d = await db;
    await d.insert('collect_tasks', {
      'id': t.id,
      'name': t.name,
      'file_name': t.fileName,
      'subject_id': t.subjectId,
      'status': t.status.name,
      'progress': t.progress,
      'page_count': t.pageCount,
      'page': t.page,
      'error': t.error,
      'question_id': t.questionId,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    bumpBadgeVersion();
  }

  Future<void> deleteCollectTask(String id) async {
    final d = await db;
    await d.delete('collect_tasks', where: 'id = ?', whereArgs: [id]);
    bumpBadgeVersion();
  }

  // ---------- 设置（settings 表） ----------

  Future<AppSettings> loadSettings() async {
    final d = await db;
    final rows = await d.query('settings');
    final map = {
      for (final r in rows) r['key'] as String: r['value'] as String
    };
    return AppSettings.fromMap(map);
  }

  Future<void> saveSetting(String key, String value) async {
    final d = await db;
    await d.insert('settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> saveSettings(AppSettings s) async {
    for (final e in s.toMap().entries) {
      await saveSetting(e.key, e.value);
    }
  }

  /// 备份：把题库导出为 JSON 文本（恢复时校验后整体覆盖）。
  Future<String> exportBackupJson() async {
    final d = await db;
    final out = <String, dynamic>{};
    for (final t in [
      'subjects',
      'questions',
      'folders',
      'tags',
      'exams',
      'knowledge_points',
      'cause_records',
      'settings',
    ]) {
      out[t] = await d.query(t);
    }
    return _jsonEncode(out);
  }

  static String _jsonEncode(Map<String, dynamic> v) {
    final buf = StringBuffer('{');
    var first = true;
    for (final e in v.entries) {
      if (!first) buf.write(',');
      first = false;
      buf.write('"${e.key}":${_jsonValue(e.value)}');
    }
    buf.write('}');
    return buf.toString();
  }

  static String _jsonValue(Object? v) {
    if (v == null) return 'null';
    if (v is num || v is bool) return '$v';
    if (v is String) {
      return '"${v.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n')}"';
    }
    if (v is List) return '[${v.map(_jsonValue).join(',')}]';
    if (v is Map) {
      return '{${v.entries.map((e) => '"${e.key}":${_jsonValue(e.value)}').join(',')}}';
    }
    return '"$v"';
  }
}
