// B4：database.dart 拆分——建库：openAt / 老库删除 / 13 张表 DDL（createTables）/ 播种（_seed）。
// 与 database.dart 同一库（part of），共享库私有成员；纯重构，行为不变。

part of 'database.dart';

/// B3-P01：主库打开失败后，是否允许回退到可执行文件同级的
/// `data/` 子目录（只供 [AppDatabase._openDb] 与测试调用）。
/// 只有主位置**不存在库文件**时才回退——全新安装 + 数据目录
/// 不可写（目录建不出来 / 库文件写不进去），此时没有既有数据
/// 可丢，回退是 §4.6 的原定设计；
/// 主位置已有库文件时一律不回退：损坏的 v2 库、权限错误、被
/// 占用等都明确报错——静默建个空库会造成新旧库并存、读写串库。
@visibleForTesting
bool shouldFallbackAfterOpenFailureImpl(String dbPath) {
  try {
    return !File(dbPath).existsSync();
  } catch (_) {
    return false;
  }
}

/// §2.2：删老库（v1）+ 建 v2 新库的唯一打开入口（§8.1 的测试工厂）：
/// - 文件不存在 → 全新安装，直接建 v2 新库；
/// - 文件是 v2（user_version == 2）→ 正常打开；
/// - 文件是老版本（v1，user_version == 1，或其它非 2 值）→
///   删除库文件（含 -wal / -shm），再建 v2 新库；无迁移、无 onUpgrade；
/// - 删除失败 → 抛错、拒绝打开（不许在老库尚在的情况下建新库，
///   避免新旧库并存、读写串库），下次启动重试删除。
/// 只读读 user_version 时不触发 onCreate/onUpgrade，删之前库是
/// 完整可读的旧库，不会拷到半截库。
Future<Database> openAtImpl(String dbPath, {DatabaseFactory? factory}) async {
  final f = factory ?? databaseFactoryFfi;
  await AppDatabase.deleteLegacyDatabaseIfPresent(dbPath, factory: f);
  return f.openDatabase(
    dbPath,
    options: OpenDatabaseOptions(
      version: AppDatabase.schemaVersion,
      onCreate: _onCreate,
      // B9-1 回填：每次开库扫一遍，把题已整理但任务仍
      // pendingOrganize 的卡住行持久化置 done（见
      // backfillCollectDoneIntoImpl）。新库刚建完表时无行可扫，
      // 是空操作；只读探针（deleteLegacyDatabaseIfPresent）用
      // 自己的 options，不走这里。onOpen 在 onCreate 之后跑，
      // 表一定已存在。
      onOpen: (db) async => backfillCollectDoneIntoImpl(db),
      // §2.1：旧版应用打开 v2 库：直接抛错并提示用新版打开，
      // 不许静默删库重建。
      onDowngrade: (db, oldVersion, newVersion) async {
        throw StateError('数据库是新版格式（v$oldVersion），请用新版打开（当前要求 v$newVersion）');
      },
    ),
  );
}

/// §2.2：删老库（可单测版）：文件不存在或已是 v2 时什么都不做，
/// 返回 false；删掉老库文件（含 -wal / -shm）时返回 true。
/// 删除失败抛 StateError（调用方拒绝打开、不建新库）。
Future<bool> deleteLegacyDatabaseIfPresentImpl(
  String dbPath, {
  DatabaseFactory? factory,
}) async {
  final file = File(dbPath);
  if (!file.existsSync()) return false;
  final f = factory ?? databaseFactoryFfi;
  int version;
  Database? probe;
  try {
    probe = await f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(readOnly: true),
    );
    version = await probe.getVersion();
  } catch (_) {
    // 只读打不开的库文件（损坏/被占用）：按老库处理不了版本，
    // 保守起见拒绝打开，不删——删了可能是丢数据。
    throw LegacyDatabaseException('数据库文件无法打开，无法确认版本，已拒绝打开：$dbPath');
  } finally {
    try {
      await probe?.close();
    } catch (_) {}
  }
  if (version == AppDatabase.schemaVersion) return false;
  // 老库：删 -wal / -shm 再删主库（SR-P2-11）。
  // 旧顺序是先删主库、附属删失败才抛错：主库已删、抛错却称
  // “删除失败，下次启动重试”——下次启动文件已不存在、直接建空库，
  // 所谓“重试”不存在；残留的旧 -wal 还会留在新库旁边。
  // 新顺序：附属文件删失败只静默跳过（主库删掉即算删除成功，
  // 残留的 -wal 由 SQLite 按 salt 校验忽略，不阻塞新库）；
  // 只有主库本身删失败才抛错、下次启动重试（此时老库还在，
  // 重试才有意义）。删之前先 checkpoint 的说明不变：只读连接
  // 已关，WAL 里的数据若没 checkpoint 进主库，删 -wal 会丢——
  // 但老库本来就要整体删除（§6 第 1 条），不保留任何老数据。
  for (final suffix in ['-wal', '-shm']) {
    final side = File('$dbPath$suffix');
    try {
      if (side.existsSync()) await side.delete();
    } catch (_) {}
  }
  try {
    await file.delete();
  } catch (e) {
    throw LegacyDatabaseException('老数据库删除失败，已拒绝打开，下次启动重试：$e');
  }
  return true;
}

Future<void> _onCreate(Database db, int version) async {
  await createTablesImpl(db);
  await _seed(db);
}

/// 测试用：在已打开的空库上建全部表（不播种演示数据）。
/// 与 _onCreate 共用同一份建表语句，测试库与真实库结构一致。
Future<void> createTablesImpl(Database db) async {
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
      slice_text TEXT NOT NULL DEFAULT '',
      source_path TEXT, source_kind TEXT, source_page INTEGER,
      page_image_path TEXT, slice_path TEXT,
      slice_width INTEGER, slice_height INTEGER)''');
  await db.execute('''
    CREATE TABLE folders(
      id TEXT PRIMARY KEY, name TEXT NOT NULL, subject_id TEXT NOT NULL,
      parent_id TEXT, sort_order INTEGER NOT NULL DEFAULT 0)''');
  await db.execute('''
    CREATE TABLE tags(id TEXT PRIMARY KEY, name TEXT NOT NULL)''');
  await db.execute(
    '''
    CREATE TABLE exams(id TEXT PRIMARY KEY, name TEXT NOT NULL, date INTEGER)''',
  );
  await db.execute('''
    CREATE TABLE knowledge_points(
      id TEXT PRIMARY KEY, subject_id TEXT NOT NULL,
      chapter TEXT NOT NULL, name TEXT NOT NULL)''');
  await db.execute('''
    CREATE TABLE collect_tasks(
      id TEXT PRIMARY KEY, name TEXT NOT NULL, file_name TEXT NOT NULL,
      subject_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'queued',
      progress INTEGER NOT NULL DEFAULT 0, page_count INTEGER NOT NULL DEFAULT 1,
      page INTEGER NOT NULL DEFAULT 1, error TEXT, question_id TEXT,
      created_at INTEGER NOT NULL DEFAULT 0,
      source_path TEXT NOT NULL DEFAULT '',
      page_rotations TEXT NOT NULL DEFAULT '{}')''');
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
  // §1.2(c)：question_boxes（每框一行）。collect_task_id 可空：
  // 修框阶段的草稿归属，确认后只保留 question_id（原任务会被删）。
  await db.execute('''
    CREATE TABLE question_boxes(
      id TEXT PRIMARY KEY,
      collect_task_id TEXT,
      question_id TEXT,
      parent_box_id TEXT,
      page INTEGER NOT NULL DEFAULT 1 CHECK (page >= 1),
      layer INTEGER NOT NULL CHECK (layer IN (1, 2)),
      type TEXT NOT NULL CHECK (type IN ('question', 'stem', 'option', 'figure')),
      x REAL NOT NULL CHECK (x >= 0 AND x <= 1),
      y REAL NOT NULL CHECK (y >= 0 AND y <= 1),
      w REAL NOT NULL CHECK (w >= 0 AND w <= 1),
      h REAL NOT NULL CHECK (h >= 0 AND h <= 1),
      confidence REAL CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
      origin TEXT NOT NULL DEFAULT 'manual' CHECK (origin IN ('yolo', 'manual')),
      updated_at INTEGER NOT NULL)''');
  await db.execute(
    'CREATE INDEX idx_boxes_task_page ON question_boxes(collect_task_id, page)',
  );
  await db.execute(
    'CREATE INDEX idx_boxes_question ON question_boxes(question_id)',
  );
  await db.execute(
    'CREATE INDEX idx_boxes_parent ON question_boxes(parent_box_id)',
  );
  // 一题只能有一个 layer = 1 的整题框（修框中的框 question_id 为 NULL，
  // 不受限；确认回填时若已存在同题整题框，须先删旧框再回填）。
  await db.execute(
    '''
    CREATE UNIQUE INDEX idx_boxes_one_layer1_per_question
      ON question_boxes(question_id) WHERE layer = 1 AND question_id IS NOT NULL''',
  );
}

/// 错因记录播种：每个错因一条待解决记录（已存在的不动）。
/// 参数是 [DatabaseExecutor]（Database 与 Transaction 的公共父类），
/// SR-P2-8 的事务版加入/同步在事务内直接调它，不另开事务。
Future<void> _seedCauseRecordsFor(
  DatabaseExecutor db,
  Question q, {
  required DateTime joinedAt,
  int solvedCount = 0,
}) async {
  for (final cause in q.allCauses) {
    await db.insert('cause_records', {
      'question_id': q.id,
      'cause': cause,
      'subject_id': q.subjectId,
      'status': 'pending',
      'solved_count': solvedCount,
      'last_check': null,
      'recheck_date': null,
      'remedy_history': '[]',
      'joined_at': joinedAt.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
}

Future<void> _seed(Database db) async {
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
  // §2.1：settings 表写 schemaVersion = '2'（与备份 _meta 同一口径；
  // 与 sqflite 的 version 参数是两回事）。新库从空开始，不预置演示
  // 数据（§6 第 1 条）：演示题、演示解决记录、演示 recent_tasks 一律不建。
  await db.insert('settings', {'key': 'schemaVersion', 'value': '2'});
}
