import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../models/exam_event.dart';
import '../models/models.dart';
import '../services/zip_archive.dart';
import 'data_change_events.dart';
import 'demo_data.dart';
import 'drift/quiz_database.dart';
import 'journal_ffi.dart';
import 'restore_journal.dart';
// B4：database.dart 拆分——AppDatabase 类与对外接口保留在此文件，
// 实现按职责拆到以下 part 文件（同一库，共享库私有成员；纯重构，
// 不改行为、不改签名、不改调用方与测试）。
part 'db_paths.dart';
part 'db_schema.dart';
part 'db_storage.dart';
part 'db_codec.dart';
part 'db_questions.dart';
part 'db_catalog.dart';
part 'db_collect.dart';
part 'db_orphans.dart';
part 'db_settings.dart';
part 'db_recently_viewed.dart';
part 'db_backup.dart';

/// §2.2：老库处理失败（文件无法确认版本 / 删除失败）：调用方拒绝
/// 打开、不建新库、不滑入 fallback 目录（否则新旧库并存）。
class LegacyDatabaseException implements Exception {
  LegacyDatabaseException(this.message);
  final String message;
  @override
  String toString() => 'LegacyDatabaseException: $message';
}

/// §2.3：备份恢复被拒绝（版本不对 / 关键表不全 / 行不合法）：
/// message 直接展示给用户（须是具体原因，不是笼统的“恢复失败”）。
class BackupRestoreException implements Exception {
  BackupRestoreException(this.message);
  final String message;
  @override
  String toString() => 'BackupRestoreException: $message';
}

/// 备份文件读不到（文件被删 / 无权限等），与“文件不是备份”区分提示。
/// FR-43：解析备份时读不到文件即按此口径抛（与设置页 parseRestoreFile
/// 同口径）。恢复不再按路径重读文件（GPT-P1），不再需要重读入口。
class RestoreFileReadException implements Exception {
  const RestoreFileReadException(this.path);

  final String path;

  @override
  String toString() => 'RestoreFileReadException: $path';
}

/// §4.5：一个孤儿文件——`imports/` / `slices/` 下没有任何
/// questions / collect_tasks 行引用的文件。
class OrphanFile {
  const OrphanFile({required this.relativePath, required this.bytes});

  /// `/` 分隔的相对路径，如 `imports/<taskId>/original.jpg`。
  final String relativePath;

  /// 文件字节数（预览“共约多少 MB”用）。
  final int bytes;
}

/// §4.5：孤儿扫描结果。
class OrphanScan {
  const OrphanScan(this.files);
  final List<OrphanFile> files;
  int get count => files.length;
  int get totalBytes => files.fold(0, (sum, f) => sum + f.bytes);
}

/// B4.3：数据库位置迁移的结果。
enum DbMigrationOutcome {
  /// 旧库已复制到新位置，标记文件已更新。
  migrated,

  /// 旧位置没有库文件（全新安装等），只写了标记文件。
  noSourceDb,

  /// 新位置已有库文件且未指定覆盖，什么都没动。
  targetExists,

  /// 复制或写标记失败，旧库与旧标记原地不动；新位置复原，不留重复副本。
  failed,

  /// 用户中途取消迁移，旧库与旧标记原地不动。
  cancelled,

  /// 新位置就是当前位置，不用动。
  sameLocation,
}

/// v2 全新数据库（version 2，无迁移历史；§6 第 1 条：老 v1 库首次启动
/// 直接删除，不迁移；新库从空开始，不预置演示数据）。
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

  /// §2：备份/恢复与 settings 表共用的 schema 版本号（与
  /// `PRAGMA user_version` 是两回事，别混用——后者是打开时驱动的，
  /// 前者是给备份/恢复与排障看的）。
  /// 十二批 D-91：v3（新表 recently_viewed_questions + collect_tasks
  /// 新增 source_hash 列；v2 库走 Drift 迁移到 v3，不再删除）。
  static const int schemaVersion = 3;

  /// §2.3：备份里的应用版本号（与 pubspec.yaml 的 version 一致）。
  static const String appVersion = '0.1.0+1';

  /// B4.2：备份表清单（导出与恢复共用；恢复只插这里的表）。
  /// v3 共 14 张表：v2 的 13 张 + 十二批的 recently_viewed_questions。
  /// `_meta` 不是表，不在这里；导出时另加，恢复时跳过。
  static const List<String> backupTables = [
    'subjects',
    'questions',
    'question_boxes',
    'folders',
    'tags',
    'exams',
    'knowledge_points',
    'cause_records',
    'collect_tasks',
    'review_state',
    'review_history',
    'recent_tasks',
    'recently_viewed_questions',
    'settings',
  ];

  /// 十二批 D-91：v2 备份的表清单（v2 只有 13 张表，没有
  /// recently_viewed_questions）。v2 备份恢复时按这份清单校验，
  /// 新表缺键视为 empty，不静默清空——新表在 v2 里本来就没有。
  static const List<String> backupTablesV2 = [
    'subjects',
    'questions',
    'question_boxes',
    'folders',
    'tags',
    'exams',
    'knowledge_points',
    'cause_records',
    'collect_tasks',
    'review_state',
    'review_history',
    'recent_tasks',
    'settings',
  ];

  /// B3：上次停留的路由（启动页“上次停下的页面”用）。
  /// 复用 settings 表的 key/value（key `lastRoute`），不新开表、不加
  /// 字段、不碰 Schema；与 AppSettings.toMap 无关——saveSettings
  /// 只写已知键，不会误删它；loadSettings 的 fromMap 忽略未知键。
  static const String lastRouteKey = 'lastRoute';

  /// B4.1：今天是否已弹过复查提醒（`yyyy-MM-dd`，一天一次）。
  /// 与 lastRoute 同一做法：复用 settings 表 key/value，不新开表。
  static const String lastRecheckReminderKey = 'lastRecheckReminderDate';

  /// 待定3：手动备份失败标志（首页红色横幅用）。
  /// 与 lastRoute 同一做法：复用 settings 表 key/value，不新开表、
  /// 不改 Schema。'1' = 有一次备份失败待提示，'0' / 无行 = 没有。
  /// 置标志：设置页 `_backup` 失败时；清标志：首页横幅点“知道了”，
  /// 或下一次备份成功时。
  static const String backupFailedKey = 'backupFailed';

  /// B11-9 考试倒计时：考试事件列表的 settings 表键（JSON 数组，
  /// 见 db_settings.dart 的 load/saveExamEvents*）。
  /// 与 lastRoute / backupFailed 同一做法：复用 settings 表 key/value，
  /// 不新开表、不改 Schema、不碰备份表清单——settings 表整表备份，
  /// 考试事件随备份走、随恢复回来；旧备份恢复也不受影响（新备份
  /// 才多这一行，旧备份缺行按空列表读，不拒绝恢复）。
  static const String examEventsKey = 'examEvents';

  /// B11-10 今日小结：今天已整理题数的 settings 表键（值 `yyyy-MM-dd|N`，
  /// 见 db_settings.dart 的 load/bumpOrganizedToday*）。
  /// 与 lastRoute / backupFailed / examEvents 同一做法：复用 settings 表
  /// key/value，不新开表、不改 Schema、不碰备份表清单——settings 表整表
  /// 备份，计数随备份走、随恢复回来；旧备份恢复也不受影响（新备份
  /// 才多这一行，旧备份缺行按 0 读）。
  static const String organizedTodayKey = 'organizedToday';

  QuizDatabase? _db;
  Future<QuizDatabase>? _dbFuture;
  String? dbPathUsed;

  /// B2：备份恢复维护状态。恢复期间（快照 → 切换 → 写库）禁止业务访问：
  /// 单连接应用里业务读写都走 [db] getter，维护中取连接即拒绝；
  /// 恢复流程本身用调用方传入的已打开连接，不受影响。
  /// [importBackupZipIntoImpl] 在快照前置起、收尾后清掉（finally）。
  static bool _restoreMaintenance = false;

  /// B2：是否正处于备份恢复维护状态（测试用）。
  static bool get inRestoreMaintenance => _restoreMaintenance;

  /// 数据库位置可改：设置页改位置后，把新路径写进默认数据目录下的
  /// `db_location.txt` 标记文件；下次启动先读标记文件，读到就用它。
  /// （设置本身存在数据库里，换库后读不到旧设置，所以位置必须存在库外。）
  ///
  /// 测试用：[testDataDirectory] 非空时直接用它（ImportService 的
  /// 复制目标跟着数据目录走，测试才不会把文件拷进真实库目录）。
  @visibleForTesting
  static String? testDataDirectory;

  /// 测试用：[testMarkerDirectory] 非空时，[migrateToDirectory] 把
  /// `db_location.txt` 标记写到这里而不是默认数据目录（与
  /// [testDataDirectory] 同一口径，测试才不会动真实标记文件）。
  @visibleForTesting
  static String? testMarkerDirectory;

  /// 测试用：让单例直接用已打开的库（内存库 / 临时目录库），
  /// 不走 `_openDb` 的真实路径。只供测试调用。
  @visibleForTesting
  static void useDatabaseForTest(QuizDatabase db) {
    instance._db = db;
    instance._dbFuture = Future.value(db);
    instance.dbPathUsed = 'test';
  }

  /// B3-P01 测试钩子：打开一个测试库（不碰单例、不碰真实库）。
  /// - [path] 为空 → 内存库；
  /// - [path] 给文件路径 → 该路径的库文件（父目录须已存在，
  ///   调用方先建临时目录；不存在则新建）。
  /// 两种都只建表（[createTables]），不播种演示数据，与真实库
  /// 结构一致。调用方负责 `await db.close()`。
  /// 与 [useDatabaseForTest] 的区别：这里只打开库，不把它设为
  /// 单例；需要走单例的测试再调 [useDatabaseForTest]。
  /// B1-Drift：内存库走 `QuizDatabase.memory()`，文件库走
  /// `QuizDatabase.file(...)`；schemaVersion 为 2（与生产一致，
  /// 现 openForTest 的 version: 1 是旧不一致，对齐掉）。
  @visibleForTesting
  static Future<QuizDatabase> openForTest({String? path}) async {
    final db = path == null
        ? QuizDatabase.memory(onCreateTables: createTablesImpl)
        : QuizDatabase.file(File(path), onCreateTables: createTablesImpl);
    // B1-Drift：与 openAtImpl 同理——Drift 是懒打开，不发查询就不建
    // 文件、不跑 onCreate；本方法的契约是“不存在则新建”（文件库须
    // 在打开后即存在，见 SR-P2-11 v2 测试），因此发一条 SELECT 1
    // 强制建立连接。收尾验证发现：不加这句，openForTest(path:) 后
    // 直接 close，文件根本不存在，SR-P2-11 失败。
    await db.customSelect('SELECT 1').get();
    return db;
  }

  /// B3-P01 测试钩子：复位单例与测试目录重定向（只供测试调用）。
  /// 关掉单例当前持有的库（若有）、清掉缓存的 `_dbFuture` 与
  /// `dbPathUsed`、把 [testDataDirectory] / [testMarkerDirectory]
  /// 置回 null。同一文件里多个测试都要碰单例时，在 tearDown 里
  /// 调它，避免前一个测试的库/目录泄漏到下一个测试。
  /// 不改动任何生产打开路径的行为。
  @visibleForTesting
  static Future<void> resetForTest() async {
    try {
      await instance._db?.close();
    } catch (_) {}
    instance._db = null;
    instance._dbFuture = null;
    instance.dbPathUsed = null;
    testDataDirectory = null;
    testMarkerDirectory = null;
  }

  /// §4.1：缓存 `Future<QuizDatabase>` 本身：启动时多处同时 `await db`
  /// 只会打开一次连接（旧写法是 `if (_db != null)`，并发调用会
  /// 各自 openDatabase，旧连接泄漏、多连接同时写同一文件）。
  /// 打开失败时清掉缓存，下次重试重新打开——失败的 Future 不会
  /// 被永久缓存。`migrateToDirectory` 关库时同时清 `_dbFuture`。
  Future<QuizDatabase> get db {
    // B2：恢复维护状态下拒绝业务取连接（见 [_restoreMaintenance]）。
    // 恢复流程本身不走这里（用调用方传入的已打开连接）。
    if (_restoreMaintenance) {
      throw StateError('正在恢复备份，数据库处于维护状态，请稍后再试');
    }
    final cached = _dbFuture;
    if (cached != null) return cached;
    late final Future<QuizDatabase> opened;
    opened = _openDb().then(
      (d) => d,
      onError: (Object e) {
        if (identical(_dbFuture, opened)) _dbFuture = null;
        throw e;
      },
    );
    _dbFuture = opened;
    return opened;
  }

  Future<QuizDatabase> _openDb() async {
    final dataDir = Directory(dataDirectoryPath());
    var dbPath = p.join(dataDir.path, 'quiz-master2.db');
    try {
      await dataDir.create(recursive: true);
      // B2 启动恢复钩子（plan §四第 2 阶段第 5 条 + B-NEW-17）：
      // 时序是“删老库 → 启动恢复 → QuizDatabase.file”。删老库在
      // openAtImpl 内（db_schema.dart，本阶段不改该文件）也会跑一次，
      // 这里先显式跑一次以保证该时序；第二次调用是幂等的（老库已删
      // 或已是 v2 时直接返回 false，只多一次只读探针）。
      // 启动恢复在开库前跑：回滚要换库文件（快照拷回），连接未建时才安全。
      await AppDatabase.deleteLegacyDatabaseIfPresent(dbPath);
      await performStartupRestoreIfNeeded(dbPath);
      _db = await openAt(dbPath);
    } on LegacyDatabaseException {
      // 删老库失败 / 库文件无法确认版本：拒绝打开，不滑入
      // fallback（否则新旧库并存）。
      rethrow;
    } on JournalCorruptException {
      // 恢复日志损坏 / 快照缺失 / 回滚目录缺失：拒绝开库，不滑入
      // fallback（否则中断的恢复会被静默丢下、新旧库并存）。
      rethrow;
    } catch (e) {
      // B3-P01：fallback 只收窄到“主位置无库文件”的不可写情况。
      // 已有库文件时任何打开失败（损坏的 v2 库、权限错误、被占用）
      // 都明确报错，不静默建空库。
      if (!shouldFallbackAfterOpenFailure(dbPath)) {
        throw StateError('数据库打不开，已拒绝新建空库，请检查文件权限或备份后处理：$dbPath（$e）');
      }
      final installDir = p.dirname(Platform.resolvedExecutable);
      final fallbackDir = Directory(p.join(installDir, 'data'));
      await fallbackDir.create(recursive: true);
      dbPath = p.join(fallbackDir.path, 'quiz-master2.db');
      _db = await openAt(dbPath);
    }
    dbPathUsed = dbPath;
    return _db!;
  }

  // ---------- B4：静态 API 转发 ----------
  // 实现在 lib/data/db_*.dart（同一库的 part 文件）；这里只保留
  // 对外接口（签名与调用点一律不变），每行转发到对应的 `<name>Impl` 顶层函数。
  // -- db_paths.dart --

  static String dataDirectoryPath() => dataDirectoryPathImpl();

  static String? resolveDataPath(String path, {bool allowAbsolute = false}) =>
      resolveDataPathImpl(path, allowAbsolute: allowAbsolute);

  static bool isAllowedDataRelativePath(String value) =>
      isAllowedDataRelativePathImpl(value);

  static String newBoxId(String scope, int page) => newBoxIdImpl(scope, page);

  static bool databaseExistsAt(String dir) => databaseExistsAtImpl(dir);
  // -- db_storage.dart --

  static Future<DbMigrationOutcome> migrateDataFiles(
    String sourceDir,
    String targetDir, {
    bool overwrite = false,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
    // B2-5a：为 true 时成功后不删 .old 备份（调用方在提交点成功后
    // 再删），并把备份与新移入文件的路径填进 [outBackups]/[outMoved]，
    // 供调用方在提交失败时回滚。默认 false：原有调用方行为不变。
    bool keepBackups = false,
    List<({String current, String backup})>? outBackups,
    List<String>? outMoved,
  }) => migrateDataFilesImpl(
    sourceDir,
    targetDir,
    overwrite: overwrite,
    onProgress: onProgress,
    isCancelled: isCancelled,
    keepBackups: keepBackups,
    outBackups: outBackups,
    outMoved: outMoved,
  );

  static Future<void> rollbackMigrationFiles(
    List<String> moved,
    List<({String current, String backup})> backups,
  ) => rollbackMigrationFilesImpl(moved, backups);
  // -- db_schema.dart --

  @visibleForTesting
  static bool shouldFallbackAfterOpenFailure(String dbPath) =>
      shouldFallbackAfterOpenFailureImpl(dbPath);

  static Future<QuizDatabase> openAt(String dbPath) => openAtImpl(dbPath);

  static Future<bool> deleteLegacyDatabaseIfPresent(String dbPath) =>
      deleteLegacyDatabaseIfPresentImpl(dbPath);

  static Future<void> createTables(QuizDatabase db) => createTablesImpl(db);
  // -- db_codec.dart --

  static String encodeStringList(List<String> values) =>
      encodeStringListImpl(values);

  static List<String> decodeStringList(Object? value) =>
      decodeStringListImpl(value);

  static String encodeRemedyList(List<String> values) =>
      encodeRemedyListImpl(values);

  static List<String> decodeRemedyList(Object? value) =>
      decodeRemedyListImpl(value);

  static String encodeQueue(List<ReviewQueueItem> queue) =>
      encodeQueueImpl(queue);

  static List<ReviewQueueItem> decodeQueue(Object? value) =>
      decodeQueueImpl(value);

  static Map<int, int> decodeRotations(Object? value) =>
      decodeRotationsImpl(value);
  // -- db_questions.dart --

  static Future<List<Question>> allQuestionsFrom(QuizDatabase db) =>
      allQuestionsFromImpl(db);

  static Future<CauseRecord> recordSelfCheckInto(
    QuizDatabase db, {
    required CauseRecord updated,
    required String questionId,
    required String result,
    int cureChecks = 2,
    int recheckIntervalDays = 7,
    bool isRecheck = false,
  }) => recordSelfCheckIntoImpl(
    db,
    updated: updated,
    questionId: questionId,
    result: result,
    cureChecks: cureChecks,
    recheckIntervalDays: recheckIntervalDays,
    isRecheck: isRecheck,
  );

  static Future<bool> setReviewJoinedInto(
    QuizDatabase db,
    Question q,
    bool joined,
  ) => setReviewJoinedIntoImpl(db, q, joined);

  static Future<void> syncCauseRecordsInto(QuizDatabase db, Question q) =>
      syncCauseRecordsIntoImpl(db, q);
  // -- db_catalog.dart --

  static Future<void> deleteSubjectFrom(QuizDatabase db, String id) =>
      deleteSubjectFromImpl(db, id);

  static Future<bool> folderNameExistsInSubjectFrom(
    QuizDatabase db,
    String subjectId,
    String name, {
    String? excludeId,
  }) => folderNameExistsInSubjectFromImpl(
    db,
    subjectId,
    name,
    excludeId: excludeId,
  );

  static Future<int> deleteFolderFrom(QuizDatabase db, Folder f) =>
      deleteFolderFromImpl(db, f);

  static Future<List<String>> allTagsFrom(QuizDatabase db) =>
      allTagsFromImpl(db);

  static Future<void> renameTagFrom(
    QuizDatabase db,
    String oldName,
    String newName,
  ) => renameTagFromImpl(db, oldName, newName);

  static Future<void> deleteTagFrom(QuizDatabase db, String name) =>
      deleteTagFromImpl(db, name);

  static Future<List<Exam>> allExamsFrom(QuizDatabase db) =>
      allExamsFromImpl(db);

  static Future<void> insertExamInto(QuizDatabase db, Exam e) =>
      insertExamIntoImpl(db, e);

  static Future<void> deleteExamFrom(QuizDatabase db, String id) =>
      deleteExamFromImpl(db, id);

  static Future<List<KnowledgePoint>> allKnowledgePointsFrom(QuizDatabase db) =>
      allKnowledgePointsFromImpl(db);

  static Future<void> insertKnowledgePointInto(
    QuizDatabase db,
    KnowledgePoint kp,
  ) => insertKnowledgePointIntoImpl(db, kp);

  static Future<void> deleteKnowledgePointFrom(QuizDatabase db, String id) =>
      deleteKnowledgePointFromImpl(db, id);

  static Future<void> deleteChapterFrom(
    QuizDatabase db,
    String subjectId,
    String chapter,
  ) => deleteChapterFromImpl(db, subjectId, chapter);
  // -- db_questions.dart --

  static Future<void> upsertQuestionInto(QuizDatabase db, Question q) =>
      upsertQuestionIntoImpl(db, q);

  static Future<void> deleteQuestionFrom(QuizDatabase db, String id) =>
      deleteQuestionFromImpl(db, id);

  /// FR-37：批量删题，整批一个事务（见 [deleteQuestionsBatchFromImpl]）。
  static Future<void> deleteQuestionsBatchFrom(
    QuizDatabase db,
    List<String> ids,
  ) => deleteQuestionsBatchFromImpl(db, ids);
  // -- db_settings.dart --

  static String normalizeRecentKind(String kind) =>
      normalizeRecentKindImpl(kind);

  static Future<void> saveSettingsInto(QuizDatabase db, AppSettings s) =>
      saveSettingsIntoImpl(db, s);
  // -- db_collect.dart --

  static Future<List<CollectTask>> allCollectTasksFrom(QuizDatabase db) =>
      allCollectTasksFromImpl(db);

  static Future<void> upsertCollectTaskInto(QuizDatabase db, CollectTask t) =>
      upsertCollectTaskIntoImpl(db, t);

  /// B9-1 回填（可单测版）：题已整理但任务仍 pendingOrganize 的
  /// 卡住行持久化置 done，返回治好的行数。见
  /// [backfillCollectDoneIntoImpl]。
  static Future<int> backfillCollectDoneFrom(QuizDatabase db) =>
      backfillCollectDoneIntoImpl(db);

  static Future<void> deleteCollectTaskFrom(QuizDatabase db, String id) =>
      deleteCollectTaskFromImpl(db, id);
  // -- db_orphans.dart --

  static Future<OrphanScan> scanOrphanFilesFrom(
    QuizDatabase db, {
    String? dataDir,
  }) => scanOrphanFilesFromImpl(db, dataDir: dataDir);

  static Future<
    ({int deletedCount, int freedBytes, int skippedReferencedCount})
  >
  deleteOrphanFiles(
    List<String> relativePaths, {
    String? dataDir,
    // FR-06(a)：传了就删除前重算引用，仍被引用的跳过；不传保持旧行为。
    QuizDatabase? db,
  }) => deleteOrphanFilesImpl(relativePaths, dataDir: dataDir, db: db);
  // -- db_collect.dart --

  static Future<void> insertQuestionBoxInto(QuizDatabase db, QuestionBox b) =>
      insertQuestionBoxIntoImpl(db, b);

  static Future<List<QuestionBox>> boxesForQuestionFrom(
    QuizDatabase db,
    String questionId,
  ) => boxesForQuestionFromImpl(db, questionId);

  static Future<List<QuestionBox>> boxesForTaskFrom(
    QuizDatabase db,
    String taskId,
  ) => boxesForTaskFromImpl(db, taskId);

  static Future<List<QuestionBox>> boxesForTaskPageFrom(
    QuizDatabase db,
    String taskId,
    int page,
  ) => boxesForTaskPageFromImpl(db, taskId, page);

  static Future<List<QuestionBox>> boxesForPageImageFrom(
    QuizDatabase db,
    String pageImagePath,
  ) => boxesForPageImageFromImpl(db, pageImagePath);

  static Future<void> saveDraftBoxesInto(
    QuizDatabase db, {
    required String taskId,
    required Map<int, List<QuestionBox>> boxesByPage,
    required Map<int, int> rotations,
  }) => saveDraftBoxesIntoImpl(
    db,
    taskId: taskId,
    boxesByPage: boxesByPage,
    rotations: rotations,
  );

  static Future<void> replaceQuestionBoxesInto(
    QuizDatabase db,
    String questionId,
    List<QuestionBox> boxes,
  ) => replaceQuestionBoxesIntoImpl(db, questionId, boxes);

  static Future<void> replaceQuestionBoxesAndSliceInto(
    QuizDatabase db, {
    required String questionId,
    required List<QuestionBox> boxes,
    required String slicePath,
    required int sliceWidth,
    required int sliceHeight,
  }) => replaceQuestionBoxesAndSliceIntoImpl(
    db,
    questionId: questionId,
    boxes: boxes,
    slicePath: slicePath,
    sliceWidth: sliceWidth,
    sliceHeight: sliceHeight,
  );

  static Future<void> confirmSplitInto(
    QuizDatabase db, {
    required CollectTask originalTask,
    required List<Question> questions,
    required List<CollectTask> splitTasks,
    required Map<String, List<QuestionBox>> boxesByQuestionId,
    CollectTask? retainedTask,
    Map<int, List<QuestionBox>> retainedBoxesByPage = const {},
  }) => confirmSplitIntoImpl(
    db,
    originalTask: originalTask,
    questions: questions,
    splitTasks: splitTasks,
    boxesByQuestionId: boxesByQuestionId,
    retainedTask: retainedTask,
    retainedBoxesByPage: retainedBoxesByPage,
  );
  // -- db_settings.dart --

  static Future<bool> loadBackupFailedFrom(QuizDatabase db) =>
      loadBackupFailedFromImpl(db);

  static Future<void> saveBackupFailedInto(QuizDatabase db, bool failed) =>
      saveBackupFailedIntoImpl(db, failed);

  static Future<List<ExamEvent>> loadExamEventsFrom(QuizDatabase db) =>
      loadExamEventsFromImpl(db);

  static Future<void> saveExamEventsInto(
    QuizDatabase db,
    List<ExamEvent> events,
  ) => saveExamEventsIntoImpl(db, events);

  /// FR-38/FR-39：考试事件单条保存 / 删除（可单测版）：在原始 JSON
  /// 数组上按 id 改动目标行，其余行原样保留；读-改-写回在同一事务内。
  static Future<void> saveExamEventFrom(QuizDatabase db, ExamEvent e) =>
      saveExamEventIntoImpl(db, e);

  static Future<void> deleteExamEventFrom(QuizDatabase db, String id) =>
      deleteExamEventIntoImpl(db, id);

  static Future<void> mutateExamEventsRawFrom(
    QuizDatabase db,
    List<Object?> Function(List<Object?> raw) mutate,
  ) => mutateExamEventsRawIntoImpl(db, mutate);

  /// B11-10 今日小结：读今天已整理题数（settings 表 `organizedToday` 键）。
  static Future<int> loadOrganizedTodayFrom(QuizDatabase db, {DateTime? now}) =>
      loadOrganizedTodayFromImpl(db, now: now);

  /// B11-10 今日小结：今天已整理题数 +1（跃迁时调，见 db_questions.dart）。
  static Future<void> bumpOrganizedTodayInto(
    QuizDatabase db, {
    DateTime? now,
  }) => bumpOrganizedTodayIntoImpl(db, now: now);
  // -- db_recently_viewed.dart --

  /// 十二批功能 4：记一次查看（同一题只留一条，时间更新为最后一次；
  /// 超过 30 条时剪掉最旧的）。
  static Future<void> recordQuestionViewedInto(
    QuizDatabase db,
    String questionId, {
    int? viewedAtMillis,
  }) => recordQuestionViewedIntoImpl(
    db,
    questionId,
    viewedAtMillis: viewedAtMillis,
  );

  /// 十二批功能 4：读最近查看的题（最新在前，最多 30 条；已删题跳过）。
  static Future<List<({Question question, DateTime viewedAt})>>
  recentlyViewedQuestionsFrom(QuizDatabase db) =>
      recentlyViewedQuestionsIntoImpl(db);
  // -- db_backup.dart --

  static Future<String> exportBackupJsonFrom(QuizDatabase db) =>
      exportBackupJsonFromImpl(db);

  static void validateBackupData(Map<String, dynamic> data) =>
      validateBackupDataImpl(data);

  static Future<void> importBackupJsonInto(
    QuizDatabase db,
    Map<String, dynamic> data,
  ) => importBackupJsonIntoImpl(db, data);

  static Future<List<int>> exportBackupZipFrom(
    QuizDatabase db, {
    String? dataDir,
  }) => exportBackupZipFromImpl(db, dataDir: dataDir);

  static Map<String, dynamic> readBackupJsonFromZip(List<int> bytes) =>
      readBackupJsonFromZipImpl(bytes);

  static Future<void> importBackupZipInto(
    QuizDatabase db,
    List<int> bytes, {
    String? dataDir,
  }) => importBackupZipIntoImpl(db, bytes, dataDir: dataDir);
}
