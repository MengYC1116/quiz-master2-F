import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'badge_notifier.dart';
import '../models/models.dart';
import 'demo_data.dart';

/// SQLite：文件在用户数据目录，文件名 quiz-master2.db（D-05 已确认改口径）。
/// - Win11：`%LOCALAPPDATA%\quiz-master2\quiz-master2.db`；
///   切片图也放同一数据目录；安装目录只放程序。
/// - Linux 验证环境：`$XDG_DATA_HOME/quiz-master2/`，未设置时
///   `~/.local/share/quiz-master2/`。
/// 数据目录不可写时才回退到可执行文件同级的 `data/` 子目录，并记录
/// `dbPathUsed`。数据库版本 3：v2 的 is_organized 之后新增 is_demo
/// 标记（D-11）与 recent_tasks 表（D-01 最近任务持久化）。
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Database? _db;
  String? dbPathUsed;

  /// 用户数据目录（数据库与切片图的存放目录）。
  static String dataDirectoryPath() {
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
              version: 3, onCreate: _onCreate, onUpgrade: _onUpgrade));
    } catch (_) {
      // 回退：数据目录不可写时用可执行文件同级 data/ 目录。
      final installDir = p.dirname(Platform.resolvedExecutable);
      final fallbackDir = Directory(p.join(installDir, 'data'));
      await fallbackDir.create(recursive: true);
      dbPath = p.join(fallbackDir.path, 'quiz-master2.db');
      _db = await factory.openDatabase(dbPath,
          options: OpenDatabaseOptions(
              version: 3, onCreate: _onCreate, onUpgrade: _onUpgrade));
    }
    dbPathUsed = dbPath;
    return _db!;
  }

  /// v1 → v2：新增 is_organized（确认整理标记）。旧库里已复习过的题
  ///（review_count > 0）一定已整理过，直接回填为 1；其余为 0。
  /// v2 → v3：新增 is_demo（演示题标记，D-11）与 recent_tasks 表（D-01）；
  /// 旧库的演示题按 id 前缀回填 is_demo = 1。
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
          'ALTER TABLE questions ADD COLUMN is_organized INTEGER NOT NULL DEFAULT 0');
      await db.execute(
          'UPDATE questions SET is_organized = 1 WHERE review_count > 0');
    }
    if (oldVersion < 3) {
      await db.execute(
          'ALTER TABLE questions ADD COLUMN is_demo INTEGER NOT NULL DEFAULT 0');
      await db.execute(
          "UPDATE questions SET is_demo = 1 WHERE id LIKE 'q-%'");
      await db.execute('''
        CREATE TABLE IF NOT EXISTS recent_tasks(
          id INTEGER PRIMARY KEY CHECK (id = 1), kind TEXT NOT NULL,
          subject_id TEXT NOT NULL, title TEXT NOT NULL,
          updated_at INTEGER NOT NULL)''');
      await db.insert('recent_tasks', {
        'id': 1,
        'kind': '整理',
        'subject_id': 'math',
        'title': '函数极限',
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE subjects(
        id TEXT PRIMARY KEY, name TEXT NOT NULL, color INTEGER NOT NULL)''');
    await db.execute('''
      CREATE TABLE questions(
        id TEXT PRIMARY KEY, title TEXT NOT NULL, subject_id TEXT NOT NULL,
        folder_ids TEXT NOT NULL DEFAULT '', exam_id TEXT,
        knowledge_ids TEXT NOT NULL DEFAULT '',
        error_types TEXT NOT NULL DEFAULT '', custom_error_types TEXT NOT NULL DEFAULT '',
        tags TEXT NOT NULL DEFAULT '', answer TEXT, explanation TEXT, notes TEXT,
        review_status TEXT NOT NULL DEFAULT 'inReview', review_count INTEGER NOT NULL DEFAULT 0,
        is_organized INTEGER NOT NULL DEFAULT 0, is_demo INTEGER NOT NULL DEFAULT 0,
        next_review INTEGER, overdue_days INTEGER NOT NULL DEFAULT 0,
        is_favorite INTEGER NOT NULL DEFAULT 0, is_archived INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL, slice_kind TEXT NOT NULL DEFAULT 'material',
        slice_text TEXT NOT NULL DEFAULT '')''');
    await db.execute('''
      CREATE TABLE folders(
        id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_id TEXT)''');
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
        page INTEGER NOT NULL DEFAULT 1, error TEXT)''');
    await db.execute('''
      CREATE TABLE review_history(
        id INTEGER PRIMARY KEY AUTOINCREMENT, question_id TEXT NOT NULL,
        result TEXT NOT NULL, reviewed_at INTEGER NOT NULL)''');
    await db.execute('''
      CREATE TABLE recent_tasks(
        id INTEGER PRIMARY KEY CHECK (id = 1), kind TEXT NOT NULL,
        subject_id TEXT NOT NULL, title TEXT NOT NULL,
        updated_at INTEGER NOT NULL)''');
    await _seed(db);
  }

  Future<void> _seed(Database db) async {
    for (final s in Subject.all) {
      await db.insert('subjects', {
        'id': s.id,
        'name': s.name,
        'color': s.color.toARGB32(),
      });
    }
    for (final f in presetFolders) {
      await db.insert('folders', {'id': 'folder-$f', 'name': f});
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
    // D-01：演示最近任务——整理工作台 · 数学“函数极限”。
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
        'review_status':
            q.reviewStatus == ReviewStatus.mastered ? 'mastered' : 'inReview',
        'review_count': q.reviewCount,
        'is_organized': q.isOrganized ? 1 : 0,
        'is_demo': q.isDemo ? 1 : 0,
        'next_review': q.nextReview?.millisecondsSinceEpoch,
        'overdue_days': q.overdueDays,
        'is_favorite': q.isFavorite ? 1 : 0,
        'is_archived': q.isArchived ? 1 : 0,
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
      reviewStatus: r['review_status'] == 'mastered'
          ? ReviewStatus.mastered
          : ReviewStatus.inReview,
      reviewCount: (r['review_count'] as int?) ?? 0,
      isOrganized: (r['is_organized'] as int?) == 1,
      isDemo: (r['is_demo'] as int?) == 1,
      nextReview: r['next_review'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(r['next_review'] as int),
      overdueDays: (r['overdue_days'] as int?) ?? 0,
      isFavorite: (r['is_favorite'] as int?) == 1,
      isArchived: (r['is_archived'] as int?) == 1,
      createdAt:
          DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      sliceKind: (r['slice_kind'] as String?) ?? 'material',
      sliceText: (r['slice_text'] as String?) ?? '',
    );
  }

  /// 全库题目（错题本 / 整理 / 首页共用；一道题只存一份）。
  Future<List<Question>> allQuestions() async {
    final d = await db;
    final rows = await d.query('questions', orderBy: 'created_at DESC');
    return rows.map(_fromRow).toList();
  }

  Future<void> upsertQuestion(Question q) async {
    final d = await db;
    await d.insert('questions', _toRow(q),
        conflictAlgorithm: ConflictAlgorithm.replace);
    bumpBadgeVersion();
  }

  Future<void> deleteQuestion(String id) async {
    final d = await db;
    await d.delete('questions', where: 'id = ?', whereArgs: [id]);
    bumpBadgeVersion();
  }

  /// D-01：最近任务（单行，id = 1）。kind 为 复习 / 整理 / 收集。
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

  /// D-11：一键清空演示数据（只删 is_demo = 1 的题）。
  Future<int> clearDemoData() async {
    final d = await db;
    final n =
        await d.delete('questions', where: 'is_demo = 1');
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
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    bumpBadgeVersion();
  }

  Future<void> deleteCollectTask(String id) async {
    final d = await db;
    await d.delete('collect_tasks', where: 'id = ?', whereArgs: [id]);
    bumpBadgeVersion();
  }
}
