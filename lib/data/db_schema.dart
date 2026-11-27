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

/// §2.2：删老库（v1）+ 建 v7 新库的唯一打开入口（§8.1 的测试工厂）：
/// - 文件不存在 → 全新安装，直接建 v7 新库；
/// - 文件是 v7（user_version == 7）→ 正常打开；
/// - 文件是 v6（user_version == 6）→ 保留，Drift onUpgrade 迁到 v7
///   （二十七批 D-257：subjects 加 english_name +
///   english_name_manual 两列，预设三科回填英文名，数据全保留）；
/// - 文件是 v5（user_version == 5）→ 保留，Drift onUpgrade 先迁到 v6
///   再迁到 v7（两步链式，数据全保留；Win11 反馈包 5：questions 加
///   option_contents + option_contents_parser_version 两列，不再删除）；
/// - 文件是 v4（user_version == 4）→ 保留，Drift onUpgrade 先迁到 v5
///   再迁到 v6 再迁到 v7（三步链式，数据全保留）；
/// - 文件是 v3（user_version == 3）→ 保留，Drift onUpgrade 先迁到 v4
///   再迁到 v5 再迁到 v6 再迁到 v7（四步链式，数据全保留）；
/// - 文件是 v2（user_version == 2）→ 保留，Drift onUpgrade 先迁到 v3
///   再迁到 v4 再迁到 v5 再迁到 v6 再迁到 v7（五步链式，数据全保留）；
/// - 文件是老版本（v1，user_version < 2）→ 删除库文件（含 -wal / -shm），
///   再建 v7 新库；无 v1 迁移；
/// - 文件是更新的版本（user_version > 7）→ 预检不动它，Drift onUpgrade
///   按 from > to 抛“请用新版打开”，不静默删掉新版库；
/// P5（2026-11-25）：当前版本改为 v8——上面“v7 新库”读作 v8；
/// v7 库走 Drift onUpgrade 迁到 v8（新表 fsrs_cards / fsrs_events /
/// fsrs_migration_log，见 _upgrade7To8），再由 onBeforeOpen 的
/// v7→v8 迁移做历史审计 + attempts 唯一来源重放（见 db_fsrs.dart）；
/// 更老的版本走 2→8 / 3→8 / … 链式（各步之后追加 _upgrade7To8）；
/// v1 仍删除（无迁移）；更新的版本（user_version > 8）仍按 from > to 抛错。
/// - 删除失败 → 抛错、拒绝打开（不许在老库尚在的情况下建新库，
///   避免新旧库并存、读写串库），下次启动重试删除。
/// 只读读 user_version 时不触发 onCreate/onUpgrade，删之前库是
/// 完整可读的旧库，不会拷到半截库。
/// B1-Drift：预检（deleteLegacyDatabaseIfPresent）仍在 Drift 打开之前
/// 跑；建表 + 播种走 QuizDatabase 的 onCreateTables 回调，B9-1 回填
/// 与十二批中断导入回填走 onBeforeOpen 回调（每次开库都跑；新库刚建完表时无行可扫，
/// 是空操作；只读探针用自己的 sqlite3 连接，不走这里）。
/// onCreate 在 onBeforeOpen 之前跑，表一定已存在。
Future<QuizDatabase> openAtImpl(String dbPath) async {
  await AppDatabase.deleteLegacyDatabaseIfPresent(dbPath);
  final db = QuizDatabase.file(
    File(dbPath),
    onCreateTables: (db) async {
      await createTablesImpl(db);
      await _seed(db);
    },
    onBeforeOpen: (db) async {
      await backfillCollectDoneIntoImpl(db);
      await backfillInterruptedImportsIntoImpl(db);
      // Win11 反馈包 5：老数据回填选项内容（读 ocr_raw 重解析，
      // 不调接口、不覆盖人工改过的选项；见 db_option_contents.dart）。
      await backfillOptionContentsIntoImpl(db);
      // P5：v7 → v8 迁移（历史审计 + attempts 唯一来源重放，
      // 见 db_fsrs.dart 的 migrateFsrsV7ToV8IntoImpl）。
      // 已完成过一次的库直接跳过（幂等）；失败时抛错、开库失败，
      // 不留半张卡，下次启动重跑。每次开库都跑到这里：新库刚建完
      // 表时 attempts 为空，审计全零、只写一行日志，是空操作。
      await migrateFsrsV7ToV8IntoImpl(db);
      // 跟进批第 1 项（2026-11-27）：V5 缺卡一次性补建（通用规则，
      // 见 db_fsrs.dart 的 backfillMissingFsrsCardsIntoImpl）——
      // 跑在 v7→v8 迁移之后：重放先建出有正式作答记录的题的卡，
      // 补建只接手重放后仍无卡的已加入题；已跑过一次的库直接跳过。
      await backfillMissingFsrsCardsIntoImpl(db);
    },
  );
  // B1-Drift：Drift 是懒打开——不发查询就不建文件、不跑 onCreate /
  // beforeOpen；sqflite 的 openDatabase 则是打开即建库。Stage 1 要求
  // 行为零变（建库要在打开时完成；打不开要在打开时抛出来、走 _openDb
  // 的 B3-P01 fallback，而不是拖到首次查询时才在业务代码里炸），
  // 因此这里发一条 SELECT 1 强制建立连接。收尾验证发现：不加这句，
  // openAt 后直接 close 再用只读探针开文件会报 SQLITE_CANTOPEN（14），
  // test/b1_stage1_schema_test.dart 即因此失败。
  await db.customSelect('SELECT 1').get();
  return db;
}

/// §2.2：删老库（可单测版）：文件不存在或版本 >= 2（v2 待迁移、v3/v4/v5/v6
/// 已是当前版或待迁移）时什么都不做，返回 false；删掉老库文件（含 -wal / -shm）
/// 时返回 true。十二批 D-91：只删 user_version < 2 的 v1 老库；v2
/// 不再删（走 Drift 迁移到 v3），更新的版本（> 6）也不删（交给
/// Drift onUpgrade 按 from > to 抛“请用新版打开”）。
/// 删除失败抛 StateError（调用方拒绝打开、不建新库）。
/// B1-Drift：只读探针改走 `package:sqlite3` 的 `open(mode: readOnly)` +
/// `PRAGMA user_version`（Drift 打开之前探，探针关闭后再删）；
/// 删的顺序与失败语义与原注释完全一致。
Future<bool> deleteLegacyDatabaseIfPresentImpl(String dbPath) async {
  final file = File(dbPath);
  if (!file.existsSync()) return false;
  int version;
  try {
    final probe = sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      final rows = probe.select('PRAGMA user_version');
      version = rows.first['user_version'] as int;
    } finally {
      probe.close();
    }
  } catch (_) {
    // 只读打不开的库文件（损坏/被占用）：按老库处理不了版本，
    // 保守起见拒绝打开，不删——删了可能是丢数据。
    throw LegacyDatabaseException('数据库文件无法打开，无法确认版本，已拒绝打开：$dbPath');
  }
  if (version >= 2) return false;
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
  // 十四批 M2（P2-2）：老库文件删除也经统一文件操作锁（启动时
  // 不可能有其它删除在跑，取锁只是审计口径统一；删的是数据库文件
  // 本身，不在 imports//slices/ 引用集合里）。
  final guard = FileLifecycleGuard.instance;
  for (final suffix in ['-wal', '-shm']) {
    final side = File('$dbPath$suffix');
    await guard.deleteFile(side);
  }
  final deleted = await guard.deleteFile(file);
  if (!deleted && file.existsSync()) {
    throw LegacyDatabaseException('老数据库删除失败，已拒绝打开，下次启动重试');
  }
  return true;
}

/// 测试用：在已打开的空库上建全部表（不播种演示数据）。
/// 与 openAtImpl 的 onCreateTables 回调共用同一份建表语句，测试库与真实库结构一致。
/// Win11 反馈包 5：v6 建表（questions 末尾加 option_contents +
/// option_contents_parser_version；DDL 字面量须与
/// quiz_database.dart 的 _upgrade5To6 迁移字面量一字不差，见该函数注释）。
/// 二十七批 D-257：v7 建表（subjects 末尾加 english_name +
/// english_name_manual；DDL 字面量须与 _upgrade6To7 迁移字面量一字不差）。
Future<void> createTablesImpl(QuizDatabase db) async {
  await db.customStatement('''
    CREATE TABLE subjects(
      id TEXT PRIMARY KEY, name TEXT NOT NULL, color INTEGER NOT NULL,
      cover_style TEXT NOT NULL DEFAULT 'plain',
      cover_color TEXT NOT NULL DEFAULT 'blue',
      english_name TEXT,
      english_name_manual INTEGER NOT NULL DEFAULT 0)''');
  await db.customStatement('''
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
      slice_width INTEGER, slice_height INTEGER,
      ocr_raw TEXT, ocr_stem TEXT,
      ocr_split_status TEXT NOT NULL DEFAULT '未切分',
      ocr_manual_edited INTEGER NOT NULL DEFAULT 0,
      content_version INTEGER NOT NULL DEFAULT 0,
      question_type TEXT,
      question_type_source TEXT NOT NULL DEFAULT 'unclassified',
      question_background_tags TEXT NOT NULL DEFAULT '',
      question_background_tags_source TEXT NOT NULL DEFAULT 'unclassified',
      ocr_figures TEXT NOT NULL DEFAULT '[]',
      correct_option TEXT, option_labels TEXT,
      option_labels_confirmed INTEGER NOT NULL DEFAULT 0,
      answer_version INTEGER NOT NULL DEFAULT 1,
      answer_pending_recheck INTEGER NOT NULL DEFAULT 0,
      option_contents TEXT, option_contents_parser_version INTEGER)''');
  await db.customStatement('''
    CREATE TABLE folders(
      id TEXT PRIMARY KEY, name TEXT NOT NULL, subject_id TEXT NOT NULL,
      parent_id TEXT, sort_order INTEGER NOT NULL DEFAULT 0)''');
  await db.customStatement('''
    CREATE TABLE tags(id TEXT PRIMARY KEY, name TEXT NOT NULL)''');
  await db.customStatement(
    '''
    CREATE TABLE exams(id TEXT PRIMARY KEY, name TEXT NOT NULL, date INTEGER)''',
  );
  await db.customStatement('''
    CREATE TABLE knowledge_points(
      id TEXT PRIMARY KEY, subject_id TEXT NOT NULL,
      chapter TEXT NOT NULL, name TEXT NOT NULL)''');
  await db.customStatement('''
    CREATE TABLE collect_tasks(
      id TEXT PRIMARY KEY, name TEXT NOT NULL, file_name TEXT NOT NULL,
      subject_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'queued',
      progress INTEGER NOT NULL DEFAULT 0, page_count INTEGER NOT NULL DEFAULT 1,
      page INTEGER NOT NULL DEFAULT 1, error TEXT, question_id TEXT,
      created_at INTEGER NOT NULL DEFAULT 0,
      source_path TEXT NOT NULL DEFAULT '',
      page_rotations TEXT NOT NULL DEFAULT '{}',
      source_hash TEXT)''');
  await db.customStatement('''
    CREATE TABLE cause_records(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      question_id TEXT NOT NULL, cause TEXT NOT NULL,
      subject_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
      solved_count INTEGER NOT NULL DEFAULT 0,
      last_check INTEGER, recheck_date INTEGER,
      remedy_history TEXT NOT NULL DEFAULT '',
      joined_at INTEGER NOT NULL,
      last_counted_success_at INTEGER, last_counted_session_id TEXT,
      UNIQUE(question_id, cause))''');
  await db.customStatement('''
    CREATE TABLE review_state(
      id INTEGER PRIMARY KEY CHECK (id = 1),
      queue TEXT NOT NULL DEFAULT '', position INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL,
      session_id TEXT, mode TEXT, skips TEXT, per_question_state TEXT)''');
  await db.customStatement('''
    CREATE TABLE review_history(
      id INTEGER PRIMARY KEY AUTOINCREMENT, question_id TEXT NOT NULL,
      result TEXT NOT NULL, reviewed_at INTEGER NOT NULL,
      cause_id TEXT, session_id TEXT,
      review_mode TEXT CHECK (review_mode IN ('到期复习')),
      verdict TEXT, verification_source TEXT,
      verification_status TEXT CHECK ((verification_status IS NULL AND verification_source IS NULL) OR (verification_status = '已核验' AND verification_source IN ('软件标准答案', '客观判分', '外部资料核对')) OR (verification_status = '未核验' AND verification_source = '未核验')),
      attempt_id TEXT, submission_id TEXT)''');
  // 十四批 M1：submission_id 的 UNIQUE 不写在列定义里（SQLite 禁止
  // ALTER TABLE ADD COLUMN 带 UNIQUE），由独立唯一索引保证；字面量须与
  // _upgrade4To5 的建索引语句一字不差。
  await db.customStatement(
    'CREATE UNIQUE INDEX idx_review_history_submission ON review_history(submission_id)',
  );
  // 十四批 M1：attempts 新表（M3-14；DDL 字面量须与 _upgrade4To5 一字不差）。
  await db.customStatement('''
    CREATE TABLE attempts(
      id TEXT PRIMARY KEY, question_id TEXT NOT NULL,
      session_id TEXT NOT NULL, mode TEXT NOT NULL,
      selected TEXT, correct INTEGER, confidence TEXT,
      answer_version INTEGER NOT NULL DEFAULT 1,
      content_version INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL, cause_ids TEXT NOT NULL DEFAULT '[]',
      duration_ms INTEGER, submission_id TEXT UNIQUE,
      created_at INTEGER NOT NULL,
      UNIQUE(session_id, question_id))''');
  await db.customStatement('''
    CREATE TABLE recent_tasks(
      id INTEGER PRIMARY KEY CHECK (id = 1), kind TEXT NOT NULL,
      subject_id TEXT NOT NULL, title TEXT NOT NULL,
      updated_at INTEGER NOT NULL)''');
  await db.customStatement('''
    CREATE TABLE recently_viewed_questions(
      question_id TEXT PRIMARY KEY, viewed_at INTEGER NOT NULL)''');
  // 十三批 M2：ocr_jobs（OCR 持久化队列，GPT 评审 §2.2 字段表；字段名/
  // 类型/枚举取值见 lib/models/models.dart 的 OcrJob）。
  // DDL 须与 quiz_database.dart 的 onUpgrade 3→4 迁移字面量一字不差
  //（十二批 D-91 的教训：迁移后库与全新 v4 库 sqlite_master 逐字一致）。
  // 十三批 P1-1：加 lease_token（租约 token，见 db_ocr_jobs.dart）。
  await db.customStatement('''
    CREATE TABLE ocr_jobs(
      id TEXT PRIMARY KEY, question_id TEXT NOT NULL,
      crop_path TEXT, input_hash TEXT,
      status TEXT NOT NULL DEFAULT 'pending',
      attempt_count INTEGER NOT NULL DEFAULT 0,
      available_at INTEGER, started_at INTEGER, lease_until INTEGER,
      lease_token TEXT,
      last_error_code TEXT, last_error_message TEXT,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
      completed_at INTEGER)''');
  await db.customStatement(
    'CREATE INDEX idx_ocr_jobs_question ON ocr_jobs(question_id)',
  );
  await db.customStatement(
    'CREATE INDEX idx_ocr_jobs_pending ON ocr_jobs(status, available_at)',
  );
  // 十四批 M1：题型筛选索引（筛选查询走索引；字面量须与 _upgrade4To5 一字不差）。
  await db.customStatement(
    'CREATE INDEX idx_questions_question_type ON questions(question_type)',
  );
  // 十九批 A3：「我的查找」saved_searches 表（DDL 字面量须与
  // db_saved_searches.dart 的 savedSearchesTableDDL 及
  // drift/quiz_database.dart 的 _upgrade5To6 末尾一字不差）。
  await db.customStatement('''
    CREATE TABLE saved_searches(
      id TEXT PRIMARY KEY, name TEXT NOT NULL,
      conditions TEXT NOT NULL DEFAULT '{}',
      created_at INTEGER NOT NULL)''');
  await db.customStatement('''
    CREATE TABLE settings(
      key TEXT PRIMARY KEY, value TEXT NOT NULL)''');
  // §1.2(c)：question_boxes（每框一行）。collect_task_id 可空：
  // 修框阶段的草稿归属，确认后只保留 question_id（原任务会被删）。
  await db.customStatement('''
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
  await db.customStatement(
    'CREATE INDEX idx_boxes_task_page ON question_boxes(collect_task_id, page)',
  );
  await db.customStatement(
    'CREATE INDEX idx_boxes_question ON question_boxes(question_id)',
  );
  await db.customStatement(
    'CREATE INDEX idx_boxes_parent ON question_boxes(parent_box_id)',
  );
  // 一题只能有一个 layer = 1 的整题框（修框中的框 question_id 为 NULL，
  // 不受限；确认回填时若已存在同题整题框，须先删旧框再回填）。
  await db.customStatement(
    '''
    CREATE UNIQUE INDEX idx_boxes_one_layer1_per_question
      ON question_boxes(question_id) WHERE layer = 1 AND question_id IS NOT NULL''',
  );
  // P5 schema v8：fsrs_cards / fsrs_events / fsrs_migration_log
  //（DDL 常量见 db_fsrs.dart；迁移 _upgrade7To8 的字面量须与这里
  // 一字不差，见 drift/quiz_database.dart 该函数注释）。
  await db.customStatement(fsrsCardsTableDDL);
  await db.customStatement(fsrsEventsTableDDL);
  await db.customStatement(fsrsMigrationLogTableDDL);
  await db.customStatement(fsrsCardsDueIndexDDL);
}

/// B2 集成：`_seedCauseRecordsFor` 已删；FSRS 全量迁移包2：
/// 错因播种已删除（`ensureCauseRecords` / `_seedCauseRecordsTyped`
/// 已删，入池不再播种 cause_records，状态列冻结为历史）。
/// B3：以下播种全部走 Drift 类型化 insert（`db.into(...).insert`），
/// 不再手写 customInsert SQL 字符串；settings.schemaVersion 走
/// db_settings 的类型化 upsert（与备份恢复的写回同口径）。
/// onCreate 的其他种子逻辑（subjects/folders/tags/exams/
/// knowledge_points/schemaVersion 原始 DDL）保留不动。
Future<void> _seed(QuizDatabase db) async {
  for (final s in Subject.all) {
    await db
        .into(db.subjects)
        .insert(
          SubjectsCompanion.insert(
            id: s.id,
            name: s.name,
            color: s.color.toARGB32(),
            coverStyle: const Value('plain'),
            coverColor: Value(switch (s.id) {
              'math' => 'blue',
              'english' => 'green',
              _ => 'red',
            }),
            // D-257：预设三科英文名直接写进库（与 _Book12Palette
            // 预设值一致），manual 置 1（固定值，不走自动翻译）。
            englishName: Value(s.englishName),
            englishNameManual: const Value(1),
          ),
        );
  }
  // 每科一套预置文件夹（v2：文件夹按学科分）。
  for (final s in Subject.all) {
    for (var i = 0; i < presetFolders.length; i++) {
      final f = presetFolders[i];
      await db
          .into(db.folders)
          .insert(
            FoldersCompanion.insert(
              id: 'folder-${s.id}-$f',
              name: f,
              subjectId: s.id,
              parentId: const Value(null),
              sortOrder: Value(i),
            ),
          );
    }
  }
  for (final t in presetTags) {
    await db.into(db.tags).insert(TagsCompanion.insert(id: 'tag-$t', name: t));
  }
  for (final e in demoExams()) {
    await db
        .into(db.exams)
        .insert(
          ExamsCompanion.insert(
            id: e.id,
            name: e.name,
            date: Value(e.date?.millisecondsSinceEpoch),
          ),
        );
  }
  for (final kp in demoKnowledgePoints()) {
    await db
        .into(db.knowledgePoints)
        .insert(
          KnowledgePointsCompanion.insert(
            id: kp.id,
            subjectId: kp.subjectId,
            chapter: kp.chapter,
            name: kp.name,
          ),
        );
  }
  // §2.1：settings 表写 schemaVersion = '8'（与备份 _meta 同一口径；
  // 与 PRAGMA user_version 是两回事）。新库从空开始，不预置演示
  // 数据（§6 第 1 条）：演示题、演示解决记录、演示 recent_tasks 一律不建。
  await _upsertSettingInto(db, 'schemaVersion', '8');
}
