// 十九批 A3：「我的查找」——saved_searches 表。
// 与 database.dart 同一库（part of），共享库私有成员。
//
// 新表 saved_searches（id TEXT PRIMARY KEY, name TEXT NOT NULL,
// conditions TEXT NOT NULL DEFAULT '{}', created_at INTEGER NOT NULL，
// 毫秒时间戳）：一条已存查找 = 名字 + WrongbookState 筛选字段子集
// 的 JSON（见 models.dart 的 SavedSearch 与
// wrongbook_notifier.dart 的条件 helpers）。
//
// Schema 纪律（D-218）：schemaVersion 不升版（仍 6；备份表清单不加，
// 旧 v6 备份恢复不受影响）。建表 DDL 只写在两处——
// createTablesImpl（全新库）与 drift 的 _upgrade5To6 末尾（v≤5
// 迁移库与全新库 sqlite_master 逐字一致，见 b1/b13/b14 迁移测试）；
// 另有本文件的 ensure（CREATE TABLE IF NOT EXISTS），供 repository
// 方法每次操作前自愈：经 openForTest / 内存库 / 直接 QuizDatabase
// 打开的旧库也可能没有这张表，自愈后读写不抛“no such table”。

part of 'database.dart';

/// saved_searches 建表 DDL（与 db_schema.dart 的 createTablesImpl
/// 及 drift/quiz_database.dart 的 _upgrade5To6 末尾同一份字面量）。
const String savedSearchesTableDDL = '''
    CREATE TABLE saved_searches(
      id TEXT PRIMARY KEY, name TEXT NOT NULL,
      conditions TEXT NOT NULL DEFAULT '{}',
      created_at INTEGER NOT NULL)''';

/// 自愈建表（可单测版，直接对传入的库句柄执行，不碰单例）：
/// 表不存在时建表，已存在时空操作。SQLite 存 sqlite_master 时
/// 会去掉 IF NOT EXISTS，存下的文本与 [savedSearchesTableDDL]
/// 折叠空白后一致。
Future<void> ensureSavedSearchesTableIntoImpl(QuizDatabase db) async {
  await db.customStatement(
    'CREATE TABLE IF NOT EXISTS saved_searches(\n'
    '  id TEXT PRIMARY KEY, name TEXT NOT NULL,\n'
    "  conditions TEXT NOT NULL DEFAULT '{}',\n"
    '  created_at INTEGER NOT NULL)',
  );
}

/// 读全部已存查找（可单测版，直接对传入的库句柄读，不碰单例）：
/// created_at 倒序（最新存的在前）；坏 conditions JSON 的行
/// 按空条件读（SavedSearch.fromRow 兜底），不整批失败。
Future<List<SavedSearch>> savedSearchesFromImpl(QuizDatabase db) async {
  await ensureSavedSearchesTableIntoImpl(db);
  final rows = await db
      .customSelect(
        'SELECT id, name, conditions, created_at FROM saved_searches '
        'ORDER BY created_at DESC',
      )
      .get();
  return rows
      .map(
        (r) => SavedSearch.fromRow(
          r.read<String>('id'),
          r.read<String>('name'),
          r.read<String>('conditions'),
          r.read<int>('created_at'),
        ),
      )
      .toList();
}

/// 存一条查找（可单测版）：同 id 覆盖（原地更新）。
Future<void> saveSavedSearchIntoImpl(
  QuizDatabase db,
  SavedSearch search,
) async {
  await ensureSavedSearchesTableIntoImpl(db);
  await db.customStatement(
    'INSERT OR REPLACE INTO saved_searches(id, name, conditions, created_at) '
    'VALUES (?, ?, ?, ?)',
    [
      search.id,
      search.name,
      search.conditionsJson,
      search.createdAt.millisecondsSinceEpoch,
    ],
  );
}

/// 删一条查找（可单测版）：id 不存在时空操作。
Future<void> deleteSavedSearchFromImpl(QuizDatabase db, String id) async {
  await ensureSavedSearchesTableIntoImpl(db);
  await db.customStatement('DELETE FROM saved_searches WHERE id = ?', [id]);
}

extension AppDatabaseSavedSearches on AppDatabase {
  /// 十九批 A3：读全部已存查找（最新存的在前）。
  Future<List<SavedSearch>> savedSearches() async =>
      savedSearchesFromImpl(await db);

  /// 十九批 A3：存一条查找（同 id 覆盖）。
  Future<void> saveSavedSearch(SavedSearch search) async =>
      saveSavedSearchIntoImpl(await db, search);

  /// 十九批 A3：删一条查找（id 不存在时空操作）。
  Future<void> deleteSavedSearch(String id) async =>
      deleteSavedSearchFromImpl(await db, id);
}
