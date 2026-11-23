// 二十批 P8（D-239）：v1 schema 却标 user_version=2 的旧库，迁移后首页
// 正常加载的回归测试。
//
// 背景：演示库备份本是 v1 文件（user_version=1），B19 截图转换脚本只改了
// user_version=2 与 questions 的 JSON 字段，未补 v2 时代的列/表；这种库
// 绕过 D-91 的删 v1 守卫、进 2→3 链式迁移后虽升到 user_version=6，
// schema 却不是 v6——questions 缺 source_path 等 7 列、collect_tasks
// 缺 3 列、question_boxes 表缺失。单表 SELECT 用 `*` 容忍缺列，但类型化
// JOIN（recentlyViewedQuestions）与整行写回（upsertQuestion /
// upsertCollectTask）按列名点名、报 no such column，首页翻 loadError。
// 修法：_upgrade2To3 开头补齐 v2 基线（缺什么补什么，已有的不动）。
//
// 夹具在测试内现造（v1 DDL + user_version=2 + 种子数据），不依赖工作区
// 任何真实库文件；全部用临时目录，不碰真实用户库。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/state/home_provider.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// v1 schema DDL（取自演示库备份实测：questions 止于 slice_text，
/// collect_tasks 无 created_at/source_path/page_rotations，
/// 无 question_boxes 表）。顺序：先建表。
const _v1Ddl = [
  "CREATE TABLE subjects( id TEXT PRIMARY KEY, name TEXT NOT NULL, color INTEGER NOT NULL, cover_style TEXT NOT NULL DEFAULT 'plain', cover_color TEXT NOT NULL DEFAULT 'blue')",
  "CREATE TABLE questions( id TEXT PRIMARY KEY, title TEXT NOT NULL, subject_id TEXT NOT NULL, folder_ids TEXT NOT NULL DEFAULT '', exam_id TEXT, knowledge_ids TEXT NOT NULL DEFAULT '', error_types TEXT NOT NULL DEFAULT '', custom_error_types TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '', answer TEXT, explanation TEXT, notes TEXT, review_count INTEGER NOT NULL DEFAULT 0, is_organized INTEGER NOT NULL DEFAULT 0, is_demo INTEGER NOT NULL DEFAULT 0, is_favorite INTEGER NOT NULL DEFAULT 0, is_archived INTEGER NOT NULL DEFAULT 0, review_joined INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, slice_kind TEXT NOT NULL DEFAULT 'material', slice_text TEXT NOT NULL DEFAULT '')",
  "CREATE TABLE folders( id TEXT PRIMARY KEY, name TEXT NOT NULL, subject_id TEXT NOT NULL, parent_id TEXT, sort_order INTEGER NOT NULL DEFAULT 0)",
  "CREATE TABLE tags(id TEXT PRIMARY KEY, name TEXT NOT NULL)",
  "CREATE TABLE exams(id TEXT PRIMARY KEY, name TEXT NOT NULL, date INTEGER)",
  "CREATE TABLE knowledge_points( id TEXT PRIMARY KEY, subject_id TEXT NOT NULL, chapter TEXT NOT NULL, name TEXT NOT NULL)",
  "CREATE TABLE collect_tasks( id TEXT PRIMARY KEY, name TEXT NOT NULL, file_name TEXT NOT NULL, subject_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'queued', progress INTEGER NOT NULL DEFAULT 0, page_count INTEGER NOT NULL DEFAULT 1, page INTEGER NOT NULL DEFAULT 1, error TEXT, question_id TEXT)",
  "CREATE TABLE cause_records( id INTEGER PRIMARY KEY AUTOINCREMENT, question_id TEXT NOT NULL, cause TEXT NOT NULL, subject_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', solved_count INTEGER NOT NULL DEFAULT 0, last_check INTEGER, recheck_date INTEGER, remedy_history TEXT NOT NULL DEFAULT '', joined_at INTEGER NOT NULL, UNIQUE(question_id, cause))",
  "CREATE TABLE review_state( id INTEGER PRIMARY KEY CHECK (id = 1), queue TEXT NOT NULL DEFAULT '', position INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL)",
  "CREATE TABLE review_history( id INTEGER PRIMARY KEY AUTOINCREMENT, question_id TEXT NOT NULL, result TEXT NOT NULL, reviewed_at INTEGER NOT NULL)",
  "CREATE TABLE recent_tasks( id INTEGER PRIMARY KEY CHECK (id = 1), kind TEXT NOT NULL, subject_id TEXT NOT NULL, title TEXT NOT NULL, updated_at INTEGER NOT NULL)",
  "CREATE TABLE settings( key TEXT PRIMARY KEY, value TEXT NOT NULL)",
];

/// 造一个“v1 schema + user_version=2”的库文件：3 学科 + 1 道待复习题
///（已整理、已加入复习、1 条待解决错因）+ 1 道待整理题 + 1 条最近任务。
Future<String> _v1StampedV2DbFile(Directory tmp) async {
  final dbPath = p.join(tmp.path, 'quiz-master2.db');
  final raw = sqlite3.sqlite3.open(dbPath);
  for (final ddl in _v1Ddl) {
    raw.execute(ddl);
  }
  raw.execute(
    "INSERT INTO subjects VALUES ('math', '数学', 4280391411, 'plain', 'blue')",
  );
  raw.execute(
    "INSERT INTO subjects VALUES ('english', '英语', 4280391411, 'plain', 'green')",
  );
  raw.execute(
    "INSERT INTO subjects VALUES ('politics', '政治', 4280391411, 'plain', 'red')",
  );
  raw.execute(
    "INSERT INTO questions (id, title, subject_id, folder_ids, knowledge_ids, error_types, tags, is_organized, review_joined, created_at) VALUES ('q-due', '函数极限', 'math', '[]', '[]', '[\"概念不清\"]', '[]', 1, 1, 1700000000000)",
  );
  raw.execute(
    "INSERT INTO questions (id, title, subject_id, folder_ids, knowledge_ids, error_types, tags, is_organized, review_joined, created_at) VALUES ('q-pending', '阅读理解', 'english', '[]', '[]', '[]', '[]', 0, 0, 1700000001000)",
  );
  raw.execute(
    "INSERT INTO cause_records (question_id, cause, subject_id, status, solved_count, joined_at) VALUES ('q-due', '概念不清', 'math', 'pending', 0, 1700000000000)",
  );
  raw.execute(
    "INSERT INTO recent_tasks VALUES (1, '整理', 'math', '函数极限', 1700000002000)",
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
  group('D-239：v1 schema 标 v2 的旧库迁移后首页正常', () {
    test('迁移后 DDL 与全新 v6 库逐字一致', () async {
      final tmp = await Directory.systemTemp.createTemp('b20-d231-ddl-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final migratedPath = await _v1StampedV2DbFile(tmp);
      final migrated = await AppDatabase.openAt(migratedPath);
      await migrated.close();

      final freshPath = p.join(tmp.path, 'fresh.db');
      final fresh = await AppDatabase.openAt(freshPath);
      await fresh.close();

      expect(await _allDdl(migratedPath), await _allDdl(freshPath));
    });

    test('HomeNotifier.load()：无 loadError，各区有数，写路径也通', () async {
      final tmp = await Directory.systemTemp.createTemp('b20-d231-home-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = await _v1StampedV2DbFile(tmp);
      final db = await AppDatabase.openAt(dbPath);
      addTearDown(() async => AppDatabase.resetForTest());
      AppDatabase.useDatabaseForTest(db);
      final repo = QuestionRepository(AppDatabase.instance);

      // 迁移后 user_version=7，2 道题都在。
      expect(
        (await db.customSelect('PRAGMA user_version').get())
            .single
            .data['user_version'],
        7,
      );
      expect(await repo.all(), hasLength(2));
      // 写路径：整行写回不再报 no such column。
      final q = (await repo.all()).firstWhere((e) => e.id == 'q-due');
      await repo.save(q.copyWith(notes: '回归探针改写'));
      expect(
        (await repo.all())
            .firstWhere((e) => e.id == 'q-due')
            .notes,
        '回归探针改写',
      );
      // 最近查看：迁移新建的表可写可读，JOIN 不再炸。
      await AppDatabase.instance.recordQuestionViewed('q-due');
      expect(
        await repo.recentlyViewedQuestions(),
        hasLength(1),
      );

      final container = ProviderContainer.test(
        overrides: [repositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
      container.listen(homeProvider, (_, __) {});
      await container.read(homeProvider.notifier).load();
      final s = container.read(homeProvider);
      expect(s.loading, isFalse);
      expect(s.loadError, isFalse);
      expect(s.hasLoaded, isTrue);
      expect(s.totalDue, 1);
      expect(s.duePending, 1);
      expect(s.dueRecheck, 0);
      expect(s.revCounts, {'math': 1, 'english': 0, 'politics': 0});
      expect(s.pendingCounts, {'math': 0, 'english': 1, 'politics': 0});
      expect(s.subjects.map((e) => e.id), ['math', 'english', 'politics']);
      expect(s.recent?.title, '函数极限');
      expect(s.history, hasLength(1));
      expect(s.history.single.question.id, 'q-due');

      // 幂等：已是 v6 的库再打开一次，首页仍正常。
      await AppDatabase.resetForTest();
      final db2 = await AppDatabase.openAt(dbPath);
      AppDatabase.useDatabaseForTest(db2);
      final repo2 = QuestionRepository(AppDatabase.instance);
      final container2 = ProviderContainer.test(
        overrides: [repositoryProvider.overrideWithValue(repo2)],
      );
      addTearDown(container2.dispose);
      container2.listen(homeProvider, (_, __) {});
      await container2.read(homeProvider.notifier).load();
      final s2 = container2.read(homeProvider);
      expect(s2.loadError, isFalse);
      expect(s2.hasLoaded, isTrue);
      expect(s2.totalDue, 1);
    });
  });
}
