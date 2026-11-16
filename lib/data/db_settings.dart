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

/// B11-9 考试倒计时：读考试事件列表（可单测版，直接对传入的库句柄读，
/// 不碰单例）。存在 settings 表 `examEvents` 键下，JSON 数组；
/// 无行 / 空串 / 坏 JSON / 坏行一律按空列表处理（坏行单独跳过，
/// 不让一行坏数据拖垮整个列表、不弹错）。
/// 返回的列表始终是可变的：调用方（repository）会原地排序/增删。
Future<List<ExamEvent>> loadExamEventsFromImpl(Database db) async {
  final rows = await db.query(
    'settings',
    columns: ['value'],
    where: 'key = ?',
    whereArgs: [AppDatabase.examEventsKey],
  );
  if (rows.isEmpty) return <ExamEvent>[];
  final raw = rows.first['value'] as String?;
  if (raw == null || raw.isEmpty) return <ExamEvent>[];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <ExamEvent>[];
    return decoded
        .map(ExamEvent.fromJson)
        .whereType<ExamEvent>()
        .toList();
  } catch (_) {
    return <ExamEvent>[];
  }
}

/// B11-9 考试倒计时：写考试事件列表（可单测版）。
/// 整表替换（列表很小，用户手管几场考试；增删改都在 repository 层
/// 读-改-写回）。空列表也写一行 `[]`（与“无行”同义，读出来都是空）。
Future<void> saveExamEventsIntoImpl(
    Database db, List<ExamEvent> events) async {
  await db.insert('settings', {
    'key': AppDatabase.examEventsKey,
    'value': jsonEncode(events.map((e) => e.toJson()).toList()),
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}

/// B11-10 今日小结：今天已整理题数的 settings 表值格式与口径（纯函数，
/// 便于单测；DB 读写见下面的 load/bumpOrganizedToday*IntoImpl）。
/// 值是 `yyyy-MM-dd|N`（本地日期，月、日零补齐）：
/// - N 是当天内经整理确认（含队列批量确认）由未整理变为已整理的题数；
///   只在 upsertQuestionIntoImpl 里检测到 false→true 的跃迁时 +1
///   （见 db_questions.dart）。
/// - 新行直接以已整理入库（种子/恢复路径）不是一次整理动作，不计；
///   已整理题的重复保存不计；已整理后又被删的题不回减（最小版口径）。
/// - 日期不是当天时读出来是 0；值损坏（不是 `日期|整数`）也按 0 读，
///   下一次 +1 时按当天重写，不弹错。
String organizedTodayDateText(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// B11-10：从 settings 值读今天已整理的题数（见上）。
int organizedTodayCountFromValue(String? raw, DateTime now) {
  if (raw == null || raw.isEmpty) return 0;
  final parts = raw.split('|');
  if (parts.length != 2) return 0;
  if (parts[0] != organizedTodayDateText(now)) return 0;
  return int.tryParse(parts[1]) ?? 0;
}

/// B11-10：+1 后的 settings 值（当天接着加；跨天从 1 重新计）。
String bumpOrganizedTodayValue(String? raw, DateTime now) {
  final count = organizedTodayCountFromValue(raw, now);
  return '${organizedTodayDateText(now)}|${count + 1}';
}

/// B11-10 今日小结：读今天已整理的题数（可单测版，直接对传入的库句柄
/// 读，不碰单例）。
Future<int> loadOrganizedTodayFromImpl(Database db, {DateTime? now}) async {
  final rows = await db.query(
    'settings',
    columns: ['value'],
    where: 'key = ?',
    whereArgs: [AppDatabase.organizedTodayKey],
  );
  return organizedTodayCountFromValue(
    rows.isEmpty ? null : rows.first['value'] as String?,
    now ?? DateTime.now(),
  );
}

/// B11-10 今日小结：今天已整理的题数 +1（可单测版，直接对传入的库句柄
/// 读-改-写，不碰单例；与 [AppDatabase.saveExamEventsInto] 同一写法）。
Future<void> bumpOrganizedTodayIntoImpl(Database db, {DateTime? now}) async {
  final rows = await db.query(
    'settings',
    columns: ['value'],
    where: 'key = ?',
    whereArgs: [AppDatabase.organizedTodayKey],
  );
  final next = bumpOrganizedTodayValue(
    rows.isEmpty ? null : rows.first['value'] as String?,
    now ?? DateTime.now(),
  );
  await db.insert('settings', {
    'key': AppDatabase.organizedTodayKey,
    'value': next,
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
    DataChangeBus.instance.emit(
      const DataChangeEvent(kinds: {DataChangeKind.settings}),
    );
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

  Future<void> saveBackupFailed(bool failed) async {
    await AppDatabase.saveBackupFailedInto(await db, failed);
    // 备份失败标志是 settings 表里的键，首页横幅在启动时读它。
    DataChangeBus.instance.emit(
      const DataChangeEvent(kinds: {DataChangeKind.settings}),
    );
  }

  /// B11-9 考试倒计时：读考试事件列表（settings 表 `examEvents` 键）。
  Future<List<ExamEvent>> loadExamEvents() async =>
      AppDatabase.loadExamEventsFrom(await db);

  /// B11-9 考试倒计时：写考试事件列表（整表替换）。
  Future<void> saveExamEvents(List<ExamEvent> events) async {
    await AppDatabase.saveExamEventsInto(await db, events);
    // 考试事件存在 settings 表里；首页倒计时与设置页考试组读同一份。
    DataChangeBus.instance.emit(
      const DataChangeEvent(kinds: {DataChangeKind.settings}),
    );
  }

  /// B11-10 今日小结：读今天已整理的题数（settings 表 `organizedToday`
  /// 键；口径见本文件顶部的 organizedToday* 注释）。
  Future<int> organizedTodayCount({DateTime? now}) async =>
      AppDatabase.loadOrganizedTodayFrom(await db, now: now);
}
