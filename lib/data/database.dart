import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:fsrs/fsrs.dart' as fsrs;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../models/exam_event.dart';
import '../models/models.dart';
import '../services/glm_ocr_client.dart';
import '../services/option_contents.dart';
import '../services/stem_splitter.dart';
import '../services/zip_archive.dart';
import 'data_change_events.dart';
import 'demo_data.dart';
import 'drift/quiz_database.dart';
import 'file_lifecycle_guard.dart';
import 'journal_ffi.dart';
import 'restore_journal.dart';
import 'review_engine.dart';
import 'review_scheduler.dart';
// B4：database.dart 拆分——AppDatabase 类与对外接口保留在此文件，
// 实现按职责拆到以下 part 文件（同一库，共享库私有成员；纯重构，
// 不改行为、不改签名、不改调用方与测试）。
part 'db_paths.dart';
part 'db_schema.dart';
part 'db_storage.dart';
part 'db_codec.dart';
part 'db_questions.dart';
part 'db_option_contents.dart';
part 'db_catalog.dart';
part 'db_collect.dart';
part 'db_orphans.dart';
part 'db_settings.dart';
part 'db_recently_viewed.dart';
part 'db_ocr_jobs.dart';
part 'db_saved_searches.dart';
part 'db_backup.dart';
part 'db_fsrs.dart';

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
  /// Win11 反馈包 5：v6（questions 加 option_contents +
  /// option_contents_parser_version 两列；v5 库走 Drift 迁移到 v6，
  /// 不再删除）。
  /// 二十七批 D-257：v7（subjects 加 english_name +
  /// english_name_manual 两列；v6 库走 Drift 迁移到 v7）。
  /// P5（2026-11-25）：v8（新表 fsrs_cards / fsrs_events /
  /// fsrs_migration_log；v7 库走 Drift 迁移到 v8，再由开库回填做
  /// 历史审计 + attempts 唯一来源重放，见 db_fsrs.dart）。
  static const int schemaVersion = 8;

  /// §2.3：备份里的应用版本号（与 pubspec.yaml 的 version 一致）。
  static const String appVersion = '0.1.0+1';

  /// B4.2：备份表清单（导出与恢复共用；恢复只插这里的表）。
  /// v6 库共 16 张表，备份表清单也是 16 张。
  /// 十四批 M2（P1-6）：attempts 全表纳入备份和恢复；review_state
  /// 仍在清单里（恢复时清表、但不插备份里的行——备份不含未完成会话，
  /// 见 importBackupJsonIntoImpl；导出时 review_state 写 `[]`）。
  /// `_meta` 不是表，不在这里；导出时另加，恢复时跳过。
  /// P5（2026-11-25）：v8 库共 19 张表——新表 fsrs_cards /
  /// fsrs_events / fsrs_migration_log 全表纳入备份和恢复（FSRS 状态
  /// 与事件账本随备份走；恢复后迁移日志行原样回来，不重跑迁移——
  /// fsrs_migration_log 里有 completed 行时迁移直接跳过）。
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
    'ocr_jobs',
    'settings',
    'attempts',
    'fsrs_cards',
    'fsrs_events',
    'fsrs_migration_log',
  ];

  /// Win11 反馈包 5：v5 备份的表清单（v5 也是 16 张表，与 v6 同名；
  /// questions 行没有 option_contents / option_contents_parser_version
  /// 两列）。v5 备份恢复时按这份清单校验，两列缺失走 NULL 默认值，
  /// 不拒绝（见 validateBackupDataImpl 与 _backupInsertRowTyped）。
  static const List<String> backupTablesV5 = [
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
    'ocr_jobs',
    'settings',
    'attempts',
  ];

  /// P5：v6 与 v7 备份的表清单（v6/v7 也是 16 张表，与 v5 同名；
  /// fsrs_* 三表只在 v8 出现）。v6/v7 备份恢复时按这份清单校验，
  /// 新表缺键视为 empty（importBackupJsonIntoImpl 里 rows is! List
  /// 即跳过），不拒绝；恢复后开库回填再跑 v7→v8 迁移重放。
  static const List<String> backupTablesV6 = [
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
    'ocr_jobs',
    'settings',
    'attempts',
  ];

  /// 十四批 M2：v4 备份的表清单（v4 只有 15 张表，没有 attempts）。
  /// v4 备份恢复时按这份清单校验，attempts 缺键视为 empty，
  /// 不拒绝（见 validateBackupDataImpl）。
  static const List<String> backupTablesV4 = [
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
    'ocr_jobs',
    'settings',
  ];

  /// 十三批 M2：v3 备份的表清单（v3 只有 14 张表，没有 ocr_jobs；
  /// questions 行也没有 5 个 OCR 列）。v3 备份恢复时按这份清单校验，
  /// 新表缺键视为 empty、新列缺失走 DDL 默认值，不静默清空——
  /// ocr_jobs 在 v3 里本来就没有，旧题的 OCR 字段本来就是空的。
  static const List<String> backupTablesV3 = [
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

  /// B4.1：今天是否已弹过到期复习提醒（`yyyy-MM-dd`，一天一次）。
  /// 与 lastRoute 同一做法：复用 settings 表 key/value，不新开表。
  /// 键名 `lastRecheckReminderDate` 保留不改（FSRS 全量迁移包 3：
  /// 改名会导致迁移当天重复提醒）。
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

  /// 二十四批 D-253：生产用——启动时解析出的安卓数据目录根
  /// （main() 里先 await path_provider 的
  /// getApplicationDocumentsDirectory() 再设置；未设时安卓分支
  /// 直接抛错，绝不回退到相对路径）。
  /// 与 [testDataDirectory] 的区别：测试钩子只供测试用、且优先级
  /// 更高（[dataDirectoryPathImpl] 先认测试钩子，测试里即使设了
  /// 本字段也被测试钩子覆盖，保证测试隔离）；本字段只供生产启动
  /// 流程设置，测试里除非特意测安卓分支否则不动它。
  /// [resetForTest] 里一并清掉，防止泄漏到下一个测试。
  static String? startupDataDirectory;

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
  /// `dbPathUsed`、把 [startupDataDirectory] 置回 null，并把
  /// [testDataDirectory] / [testMarkerDirectory] 重指到一个全新的
  /// 临时目录。同一文件里多个测试都要碰单例时，在 tearDown 里
  /// 调它，避免前一个测试的库/目录泄漏到下一个测试。
  /// 不改动任何生产打开路径的行为。
  ///
  /// D-88 残留（D-260）：旧写法把两个测试目录置 null，复位后到下一
  /// 个测试重设之间的窗口里，任何未等待的异步工作读
  /// `dataDirectoryPath()` 都会回落到真实默认数据目录，进而打开／
  /// 迁移真实演示库（FR-45，见 D-234）。新写法先同步建全新临时目录
  /// 并重指（`createTempSync`，关库的 await 之前就已生效，窗口不
  /// 存在），再关旧库；旧临时目录不删——未等待的工作可能还在往里
  /// 写文件，删目录会让它写失败，残留空目录由系统临时目录清理。
  /// 建新目录失败时保留旧的临时目录（仍是隔离目录），绝不回落 null。
  @visibleForTesting
  static Future<void> resetForTest() async {
    try {
      final fresh = Directory.systemTemp.createTempSync('qm2-reset-test-data-');
      testDataDirectory = fresh.path;
      testMarkerDirectory = fresh.path;
    } catch (_) {
      // 建不出新目录：保留旧的临时目录指向，仍隔离，不置 null。
    }
    startupDataDirectory = null;
    try {
      await instance._db?.close();
    } catch (_) {}
    instance._db = null;
    instance._dbFuture = null;
    instance.dbPathUsed = null;
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
    // WP-C #8 U3-2：启动清扫回收站（只删移入超过 7 天且重查无引用
    // 的条目）。清扫要读库重查引用，故放在开库后（暂存区清理在开库前、
    // 无库句柄，不放同一处）；任何失败都不阻断开库，留待下次启动再清。
    try {
      await sweepTrashImpl(_db!, dataDir: p.dirname(dbPath));
    } catch (_) {}
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

  /// FSRS 全量迁移包2：只翻 `review_joined` 标志位，不播种 cause_records。
  static Future<bool> setReviewJoinedFlagInto(
    QuizDatabase db,
    Question q,
    bool joined,
  ) => setReviewJoinedFlagIntoImpl(db, q, joined);

  // -- 十四批 M3：attempts / 重新加入复习 --

  static Future<String> recordAttemptInto(
    QuizDatabase db, {
    required AttemptData attempt,
  }) => recordAttemptIntoImpl(db, attempt: attempt);

  static Future<AttemptData?> loadAttemptInto(
    QuizDatabase db, {
    required String sessionId,
    required String questionId,
  }) => loadAttemptIntoImpl(db, sessionId: sessionId, questionId: questionId);

  static Future<List<AttemptData>> loadAttemptsForSessionInto(
    QuizDatabase db, {
    required String sessionId,
  }) => loadAttemptsForSessionIntoImpl(db, sessionId: sessionId);

  /// 十四批 M3（M3-10 断点恢复重建用）：本会话里该错因是否已有 verdict 事件。
  /// P2 起产品流程不再调用（恢复只认 attempts 行），仅供旧写入层保留。
  static Future<bool> hasSessionVerdictInto(
    QuizDatabase db, {
    required String causeStableId,
    required String sessionId,
  }) => hasSessionVerdictIntoImpl(
    db,
    causeStableId: causeStableId,
    sessionId: sessionId,
  );

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

  /// Win11 反馈包 5 回填（可单测版）：读 ocr_raw 重解析出选项内容
  /// 回填进 option_contents，返回回填的题数。见
  /// [backfillOptionContentsIntoImpl]。
  static Future<int> backfillOptionContentsInto(QuizDatabase db) =>
      backfillOptionContentsIntoImpl(db);

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
    // 十四批 M5 修复轮 2（B-FIX2-2）：db 必填——删除前必须重算
    // 数据库实时引用；无 DB 检查的删除路径已封闭。
    required QuizDatabase db,
  }) => deleteOrphanFilesImpl(relativePaths, dataDir: dataDir, db: db);

  /// WP-C #8 U3-2：启动清扫回收站（只删移入超过 7 天且重查无引用
  /// 的条目；仍有引用 / 引用未知 / 清单损坏 → 留下并记日志）。
  /// 生产调用在 `_openDb` 开库后（best-effort，失败不阻断开库）。
  static Future<TrashSweepResult> sweepTrashFrom(
    QuizDatabase db, {
    String? dataDir,
  }) => sweepTrashImpl(db, dataDir: dataDir);
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
  // -- db_ocr_jobs.dart --

  /// 十三批 M3：入队（同一题 + 同一切片哈希的未完成任务已存在时返回它）。
  static Future<OcrJob> enqueueOcrJobInto(QuizDatabase db, OcrJob job) =>
      enqueueOcrJobIntoImpl(db, job);

  /// 十三批 M3：领任务（最早创建的一条可跑 pending 任务改 running + 写租约）。
  static Future<OcrJob?> claimNextOcrJobInto(
    QuizDatabase db, {
    required Duration leaseDuration,
    DateTime? now,
  }) => claimNextOcrJobIntoImpl(db, leaseDuration: leaseDuration, now: now);

  /// 十三批 M3：回收过期租约（running 且租约已过 → pending）。返回行数。
  static Future<int> reclaimExpiredLeasesInto(
    QuizDatabase db, {
    DateTime? now,
  }) => reclaimExpiredLeasesIntoImpl(db, now: now);

  /// 十三批 M3：发请求前记一次尝试（attempt_count +1）。
  static Future<OcrJob?> markOcrJobAttemptInto(
    QuizDatabase db,
    String id, {
    DateTime? now,
  }) => markOcrJobAttemptIntoImpl(db, id, now: now);

  /// 十三批 M3：可重试的失败（回 pending + 退避到期点 + 记错误）。
  static Future<OcrJob?> retryOcrJobInto(
    QuizDatabase db,
    String id, {
    required DateTime availableAt,
    required String errorCode,
    String? errorMessage,
    DateTime? now,
  }) => retryOcrJobIntoImpl(
    db,
    id,
    availableAt: availableAt,
    errorCode: errorCode,
    errorMessage: errorMessage,
    now: now,
  );

  /// 十三批 M3：终态失败。
  static Future<OcrJob?> failOcrJobInto(
    QuizDatabase db,
    String id, {
    required String errorCode,
    String? errorMessage,
    DateTime? now,
  }) => failOcrJobIntoImpl(
    db,
    id,
    errorCode: errorCode,
    errorMessage: errorMessage,
    now: now,
  );

  /// 十三批 M3：终态完成。
  static Future<OcrJob?> completeOcrJobInto(
    QuizDatabase db,
    String id, {
    DateTime? now,
  }) => completeOcrJobIntoImpl(db, id, now: now);

  /// 十三批 M3：按 id 读一条任务。
  static Future<OcrJob?> ocrJobByIdFrom(QuizDatabase db, String id) =>
      ocrJobByIdIntoImpl(db, id);

  /// 十三批 M3：按题读任务（最新在前）。
  static Future<List<OcrJob>> ocrJobsForQuestionFrom(
    QuizDatabase db,
    String questionId,
  ) => ocrJobsForQuestionIntoImpl(db, questionId);
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

  /// 十四批 M2：带警告的 zip 导出（字节 + 可见警告列表；警告只列
  /// 派生文件缺失/不可读与图块损坏）。十四批 M5 修复轮 3（D-155）：
  /// 库行直接引用的资产缺失/不可读时备份直接失败（抛
  /// BackupRestoreException，指明题目/任务 ID 与相对路径），
  /// 不再静默生成不完整备份。设置页走这条；旧的 exportBackupZipFrom
  /// 保留给不需要警告的调用方（警告丢弃）。
  /// [onStagedForTest] 仅测试用：透传给 Impl 的故障注入钩子（见
  /// exportBackupZipFromWithReportImpl 的参数注释），生产调用不传。
  /// WP-C #8 U3-2：返回另含 `brokenFiles`（未进包的文件相对路径
  /// 清单）与 `status`（complete 仅当零警告且零 BROKEN 文件）。
  static Future<
    ({
      List<int> bytes,
      List<String> warnings,
      List<String> brokenFiles,
      BackupExportStatus status,
    })
  >
  exportBackupZipFromWithReport(
    QuizDatabase db, {
    String? dataDir,
    void Function(Directory stagingDir, List<String> stagedRels)?
    onStagedForTest,
  }) => exportBackupZipFromWithReportImpl(
    db,
    dataDir: dataDir,
    onStagedForTest: onStagedForTest,
  );

  static Map<String, dynamic> readBackupJsonFromZip(List<int> bytes) =>
      readBackupJsonFromZipImpl(bytes);

  /// 十四批 M2：返回恢复警告列表（缺失/不可读的图块已从 JSON 引用里
  /// 去掉、不展示）。`Future<void>` 改为 `Future<List<String>>`，
  /// 只 await 的调用方源码兼容。
  static Future<List<String>> importBackupZipInto(
    QuizDatabase db,
    List<int> bytes, {
    String? dataDir,
  }) => importBackupZipIntoImpl(db, bytes, dataDir: dataDir);
}
