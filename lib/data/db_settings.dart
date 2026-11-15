// B4：database.dart 拆分——设置（settings 表）/ 最近任务 / 演示数据。
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

/// §4.2/§4.5：清演示（可单测版）：一次事务，不 bump。
/// SR-P2-2：演示题走 [_deleteQuestionTxn]（与其它删题入口同一
/// 口径）：框、解决记录、自查历史、收集任务指向、复习队列里的项
/// 一并清掉；`recent_tasks` 不动（它只有 id=1 一行，旧写法
/// `delete('recent_tasks')` 会把非演示的“最近任务”也抹掉，
/// 与“非演示数据一律不动”矛盾——指向演示题的最近任务残留一
/// 条过期指向，首页按 kind 跳转时不读题行，影响小于误删）；
/// `review_state` 也不整行删（旧写法会把非演示的复习断点一起
/// 清掉），演示题只从队列里摘掉（_deleteQuestionTxn 内
/// _removeFromReviewQueueTxn 做）。
Future<int> clearDemoDataFromImpl(Database db) async {
  var n = 0;
  // §4.5：删前快照演示题的切片，事务提交后删无引用的切片文件。
  final demoSlices = await db.query(
    'questions',
    columns: ['slice_path'],
    where: 'is_demo = 1',
  );
  await db.transaction((txn) async {
    final demoRows = await txn.query(
      'questions',
      columns: ['id'],
      where: 'is_demo = 1',
    );
    for (final row in demoRows) {
      await _deleteQuestionTxn(txn, row['id'] as String);
    }
    n = demoRows.length;
  });
  for (final row in demoSlices) {
    await _deleteDataFileIfUnreferenced(db, row['slice_path'] as String?);
  }
  return n;
}

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

  /// 一键清空演示数据（只删 is_demo = 1 的题，同时删其解决记录与断点）。
  Future<int> clearDemoData() async {
    final d = await db;
    final n = await AppDatabase.clearDemoDataFrom(d);
    bumpBadgeVersion();
    return n;
  }

  Future<int> demoQuestionCount() async {
    final d = await db;
    final rows = await d.rawQuery(
      'SELECT COUNT(*) AS n FROM questions WHERE is_demo = 1',
    );
    return (rows.first['n'] as int?) ?? 0;
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
