// B4：database.dart 拆分——设置（settings 表）/ 最近任务。
// 与 database.dart 同一库（part of），共享库私有成员；纯重构，行为不变。

part of 'database.dart';

/// B7：最近任务 kind 归一化（纯函数，便于单测）。
/// 写入点现已统一写中文 '整理' / '收集'；库里已有的旧英文值
/// 'organize' / 'collect' 在读出时映射成中文显示，不丢数据、
/// 不改库。未知值原样返回（首页再按默认“复习”处理）。
String normalizeRecentKindImpl(String kind) => switch (kind) {
  'organize' => '整理',
  'collect' => '收集',
  _ => kind,
};

/// SR-P2-9：一次保存全部设置（可单测版）：一个事务批量 replace，
/// 中途失败整体回滚，不留新旧混杂的设置组合（如主题已换、字体未换）。
/// 旧写法是循环调 [AppDatabaseSettings.saveSetting]，每次独立 insert。
Future<void> saveSettingsIntoImpl(Database db, AppSettings s) async {
  final entries = s.toMap().entries.toList();
  await db.transaction((txn) async {
    for (final e in entries) {
      await txn.insert('settings', {
        'key': e.key,
        'value': e.value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  });
}

/// 待定3：读标志（可单测版，直接对传入的库句柄读，不碰单例）。
Future<bool> loadBackupFailedFromImpl(Database db) async {
  final rows = await db.query(
    'settings',
    columns: ['value'],
    where: 'key = ?',
    whereArgs: [AppDatabase.backupFailedKey],
  );
  if (rows.isEmpty) return false;
  return (rows.first['value'] as String?) == '1';
}

/// 待定3：写标志（可单测版）。
Future<void> saveBackupFailedIntoImpl(Database db, bool failed) async {
  await db.insert('settings', {
    'key': AppDatabase.backupFailedKey,
    'value': failed ? '1' : '0',
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}

extension AppDatabaseSettings on AppDatabase {
  Future<({String kind, String subjectId, String title})?> recentTask() async {
    final d = await db;
    final rows = await d.query('recent_tasks', where: 'id = 1', limit: 1);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return (
      kind: AppDatabase.normalizeRecentKind(r['kind'] as String),
      subjectId: r['subject_id'] as String,
      title: r['title'] as String,
    );
  }

  Future<void> saveRecentTask({
    required String kind,
    required String subjectId,
    required String title,
  }) async {
    final d = await db;
    await d.insert('recent_tasks', {
      'id': 1,
      'kind': kind,
      'subject_id': subjectId,
      'title': title,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<AppSettings> loadSettings() async {
    final d = await db;
    final rows = await d.query('settings');
    final map = {
      for (final r in rows) r['key'] as String: r['value'] as String,
    };
    return AppSettings.fromMap(map);
  }

  Future<void> saveSetting(String key, String value) async {
    final d = await db;
    await d.insert('settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> saveSettings(AppSettings s) async {
    final d = await db;
    await AppDatabase.saveSettingsInto(d, s);
  }

  Future<String?> loadLastRoute() async {
    final d = await db;
    final rows = await d.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [AppDatabase.lastRouteKey],
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> saveLastRoute(String route) async =>
      saveSetting(AppDatabase.lastRouteKey, route);

  Future<String?> loadLastRecheckReminderDate() async {
    final d = await db;
    final rows = await d.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [AppDatabase.lastRecheckReminderKey],
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> saveLastRecheckReminderDate(String date) async =>
      saveSetting(AppDatabase.lastRecheckReminderKey, date);

  Future<bool> loadBackupFailed() async =>
      AppDatabase.loadBackupFailedFrom(await db);

  Future<void> saveBackupFailed(bool failed) async =>
      AppDatabase.saveBackupFailedInto(await db, failed);
}
