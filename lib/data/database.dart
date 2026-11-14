import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/models.dart';
import '../services/zip_archive.dart';
import 'badge_notifier.dart';
import 'demo_data.dart';

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

  /// 复制或写标记失败，旧库与旧标记原地不动。
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

  /// §2：备份/恢复与 settings 表共用的 schema 版本号（与 sqflite 的
  /// `version` 参数、PRAGMA user_version 是两回事，别混用——后者是
  /// 打开时驱动的，前者是给备份/恢复与排障看的）。
  static const int schemaVersion = 2;

  /// §2.3：备份里的应用版本号（与 pubspec.yaml 的 version 一致）。
  static const String appVersion = '0.1.0+1';

  Database? _db;
  Future<Database>? _dbFuture;
  String? dbPathUsed;

  /// 数据库位置可改：设置页改位置后，把新路径写进默认数据目录下的
  /// `db_location.txt` 标记文件；下次启动先读标记文件，读到就用它。
  /// （设置本身存在数据库里，换库后读不到旧设置，所以位置必须存在库外。）
  ///
  /// 测试用：[testDataDirectory] 非空时直接用它（ImportService 的
  /// 复制目标跟着数据目录走，测试才不会把文件拷进真实库目录）。
  @visibleForTesting
  static String? testDataDirectory;

  static String dataDirectoryPath() {
    final override = testDataDirectory;
    if (override != null) return override;
    final def = _defaultDataDirectoryPath();
    try {
      final marker = File(p.join(def, 'db_location.txt'));
      if (marker.existsSync()) {
        final custom = marker.readAsStringSync().trim();
        if (custom.isNotEmpty) return custom;
      }
    } catch (_) {}
    return def;
  }

  /// 改数据库位置：写标记文件（下次启动生效，须重启）。
  Future<void> setCustomDataDirectory(String dir) async {
    final def = _defaultDataDirectoryPath();
    final markerDir = Directory(def);
    await markerDir.create(recursive: true);
    await File(p.join(def, 'db_location.txt')).writeAsString(dir);
    await saveSetting('databaseLocation', dir);
  }

  /// §1.4/§4.6：库内相对路径 → 绝对路径（统一 resolver）。
  /// - 相对路径（如 `imports/<task-id>/original.jpg`）：拼上数据目录；
  /// - 绝对路径：原样返回（测试里用临时目录的绝对路径时走这条）。
  /// 规范化后必须以数据目录为前缀，否则返回 null（禁止 `..` 越出
  /// 数据目录，按“文件缺失”处理，见 §4.6；绝对路径的测试值不受此限）。
  static String? resolveDataPath(String path) {
    if (p.isAbsolute(path)) return p.normalize(path);
    final dataDir = p.normalize(dataDirectoryPath());
    final abs = p.normalize(p.join(dataDir, path));
    if (abs != dataDir && !abs.startsWith('$dataDir${p.separator}')) {
      return null;
    }
    return abs;
  }

  /// §1.2(c)：框 id 规则 `box-<scope>-p<page>-<uuid8>`（v2.1 补丁定稿；
  /// 草稿 scope 是任务 id，重框 scope 是 `rework-<questionId>`）。
  /// uuid8 用 Random.secure() 生成 8 位十六进制（P2 实施注意 3，
  /// 不引入 uuid 包）。
  static String newBoxId(String scope, int page) {
    final r = math.Random.secure();
    final uuid8 = List.generate(
      8,
      (_) => '0123456789abcdef'[r.nextInt(16)],
    ).join();
    return 'box-$scope-p$page-$uuid8';
  }

  /// 测试用：让单例直接用已打开的库（内存库 / 临时目录库），
  /// 不走 `_openDb` 的真实路径。只供测试调用。
  @visibleForTesting
  static void useDatabaseForTest(Database db) {
    instance._db = db;
    instance._dbFuture = Future.value(db);
    instance.dbPathUsed = 'test';
  }

  /// B4.3：新位置是否已有库文件（设置页切换前问“覆盖 / 保留”用）。
  static bool databaseExistsAt(String dir) =>
      File(p.join(dir, 'quiz-master2.db')).existsSync();

  /// B4.3：把旧库文件复制到新位置（纯文件操作，可单测，不碰标记文件）。
  /// - 旧库不存在 → 无可迁移，返回 true（调用方只写标记即可）；
  /// - 目标已有库且 `overwrite` 为 false → 不动任何文件，返回 false；
  /// - 复制失败 → 返回 false（旧库原地不动）。
  /// 除主库文件外，-wal / -shm 若存在也一并复制（ffi 默认 journal
  /// 下一般没有，有则说明上次未正常关闭，带上才不丢数据）。
  static Future<bool> copyDatabaseFileTo(String sourcePath, String targetDir,
      {bool overwrite = false}) async {
    final target = File(p.join(targetDir, 'quiz-master2.db'));
    if (!overwrite && target.existsSync()) return false;
    final targetExisted = target.existsSync();
    final source = File(sourcePath);
    if (!source.existsSync()) return true;
    try {
      await Directory(targetDir).create(recursive: true);
      await source.copy(target.path);
      for (final suffix in ['-wal', '-shm']) {
        final side = File('$sourcePath$suffix');
        if (side.existsSync()) {
          await side.copy('$targetDir${p.separator}quiz-master2.db$suffix');
        }
      }
      return true;
    } catch (_) {
      // 复制中途失败：只删本次新建的目标文件，不留坏库；覆盖模式下
      // 目标原先就有文件时不动它（删了就是丢用户数据）。
      try {
        if (!targetExisted && target.existsSync()) await target.delete();
      } catch (_) {}
      return false;
    }
  }

  /// §4.6：文件目录迁移核心（可单测版，不碰标记文件、不碰单例）。
  /// 把源数据目录的库文件（`quiz-master2.db` + `-wal`/`-shm`）与
  /// `imports/`、`slices/` 一起搬到目标目录。
  ///
  /// 顺序（与 §4.6 定稿一致）：
  /// 1. 先算总字节（进度用），再把全部文件复制到目标旁的 staging
  ///    目录（`<目标>.staging-<时间戳>`）；复制中途失败/取消 → 删
  ///    staging，目标原封不动；
  /// 2. 复制完成并校验（文件数与总字节对得上）后，目标已有文件先
  ///    备份：库 → `quiz-master2.db.old-<时间戳>`，目录 →
  ///    `imports.old-<时间戳>` / `slices.old-<时间戳>`；
  /// 3. 再把 staging 里的内容 `rename` 到目标位置（同盘 rename
  ///    是原子操作）；任一步失败 → 删掉已移过去的新文件、把 `.old`
  ///    移回，返回 failed；
  /// 4. 成功后删 `.old` 备份与 staging，进度报到 1.0。
  /// 标记文件（`db_location.txt`）不在这里写——实例方法
  /// [migrateToDirectory] 在这步成功后才写，标记是提交点。
  /// `onProgress` 按已复制字节回调 0..1；`isCancelled` 返回 true
  /// 时停在当前文件之后，删 staging，返回 cancelled。
  static Future<DbMigrationOutcome> migrateDataFiles(
    String sourceDir,
    String targetDir, {
    bool overwrite = false,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final src = p.normalize(sourceDir);
    final dst = p.normalize(targetDir);
    if (p.equals(src, dst)) return DbMigrationOutcome.sameLocation;
    if (!overwrite && databaseExistsAt(dst)) {
      return DbMigrationOutcome.targetExists;
    }
    // 复制清单：库文件 + imports/ + slices/ 下的全部文件。
    final jobs = <({File file, String relative})>[];
    var totalBytes = 0;
    void addFile(File f, String relative) {
      var size = 0;
      try {
        size = f.lengthSync();
      } catch (_) {
        // 读不到大小的文件（如悬空符号链接）照常列入清单，
        // 复制时会抛错走失败回滚，不在这里静默跳过。
      }
      jobs.add((file: f, relative: relative));
      totalBytes += size;
    }

    for (final name in ['quiz-master2.db', 'quiz-master2.db-wal',
        'quiz-master2.db-shm']) {
      final f = File(p.join(src, name));
      if (f.existsSync()) addFile(f, name);
    }
    for (final sub in ['imports', 'slices']) {
      final dir = Directory(p.join(src, sub));
      if (!dir.existsSync()) continue;
      for (final e in dir.listSync(recursive: true)) {
        // Link 也列入清单：悬空链接复制时会抛错，走失败回滚，
        // 不能在这里静默跳过（跳过等于丢文件还报成功）。
        if (e is File || e is Link) {
          addFile(File(e.path), p.relative(e.path, from: src));
        }
      }
    }

    final stamp = DateTime.now().millisecondsSinceEpoch;
    final staging = Directory(p.join(
        p.dirname(dst), '.${p.basename(dst)}.staging-$stamp'));
    // 目标旧文件的备份（只在覆盖且目标存在时产生）：(现位置, 备份位置)。
    final backups = <({String current, String backup})>[];
    // 本次已移进目标的新文件（回滚时删除）。
    final moved = <String>[];
    try {
      await staging.create(recursive: true);
      var copiedBytes = 0;
      for (final job in jobs) {
        if (isCancelled?.call() == true) {
          await _deleteDirQuietly(staging);
          return DbMigrationOutcome.cancelled;
        }
        final dest = File(p.join(staging.path, job.relative));
        await dest.parent.create(recursive: true);
        await job.file.copy(dest.path);
        try {
          copiedBytes += await dest.length();
        } catch (_) {}
        onProgress?.call(totalBytes <= 0
            ? 1.0
            : (copiedBytes / totalBytes).clamp(0.0, 1.0));
      }
      // 校验：staging 里的文件数与总字节与清单一致。
      var stagedCount = 0;
      var stagedBytes = 0;
      for (final e in staging.listSync(recursive: true)) {
        if (e is File) {
          stagedCount++;
          try {
            stagedBytes += e.lengthSync();
          } catch (_) {}
        }
      }
      if (stagedCount != jobs.length || stagedBytes != totalBytes) {
        await _deleteDirQuietly(staging);
        return DbMigrationOutcome.failed;
      }
      // 备份目标旧文件（覆盖模式且目标存在时）+ 原子替换，两步在
      // 同一个 try 里：任一步失败都把 .old 移回、删已移入的新文件。
      try {
        if (overwrite) {
          final dbTarget = File(p.join(dst, 'quiz-master2.db'));
          if (dbTarget.existsSync()) {
            final backup = p.join(dst, 'quiz-master2.db.old-$stamp');
            await dbTarget.rename(backup);
            backups.add((current: dbTarget.path, backup: backup));
          }
          for (final suffix in ['-wal', '-shm']) {
            final side = File(p.join(dst, 'quiz-master2.db$suffix'));
            if (side.existsSync()) {
              final backup =
                  p.join(dst, 'quiz-master2.db$suffix.old-$stamp');
              await side.rename(backup);
              backups.add((current: side.path, backup: backup));
            }
          }
          for (final sub in ['imports', 'slices']) {
            final dir = Directory(p.join(dst, sub));
            if (dir.existsSync()) {
              final backup = p.join(dst, '$sub.old-$stamp');
              await dir.rename(backup);
              backups.add((current: dir.path, backup: backup));
            }
          }
        }
        // 原子替换：staging → 目标。
        await Directory(dst).create(recursive: true);
        for (final name in ['quiz-master2.db', 'quiz-master2.db-wal',
            'quiz-master2.db-shm']) {
          final staged = File(p.join(staging.path, name));
          if (!staged.existsSync()) continue;
          final dest = p.join(dst, name);
          await staged.rename(dest);
          moved.add(dest);
        }
        for (final sub in ['imports', 'slices']) {
          final staged = Directory(p.join(staging.path, sub));
          if (!staged.existsSync()) continue;
          final dest = p.join(dst, sub);
          await staged.rename(dest);
          moved.add(dest);
        }
      } catch (_) {
        // 替换中途失败：删掉已移过去的新文件，把 .old 移回。
        for (final m in moved) {
          await _deletePathQuietly(m);
        }
        for (final b in backups.reversed) {
          try {
            if (File(b.backup).existsSync()) {
              await File(b.backup).rename(b.current);
            } else if (Directory(b.backup).existsSync()) {
              await Directory(b.backup).rename(b.current);
            }
          } catch (_) {}
        }
        await _deleteDirQuietly(staging);
        return DbMigrationOutcome.failed;
      }
      // 成功：删 .old 备份与 staging。
      for (final b in backups) {
        await _deletePathQuietly(b.backup);
      }
      await _deleteDirQuietly(staging);
      onProgress?.call(1.0);
      return DbMigrationOutcome.migrated;
    } catch (_) {
      await _deleteDirQuietly(staging);
      return DbMigrationOutcome.failed;
    }
  }

  static Future<void> _deleteDirQuietly(Directory dir) async {
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  static Future<void> _deletePathQuietly(String path) async {
    try {
      final f = File(path);
      if (f.existsSync()) {
        await f.delete();
        return;
      }
      final d = Directory(path);
      if (d.existsSync()) await d.delete(recursive: true);
    } catch (_) {}
  }

  /// B4.3/§4.6：切换数据库位置并迁移旧库与文件目录。
  /// 顺序：先关当前库 → [migrateDataFiles] 搬库文件 + `imports/` +
  /// `slices/`（staging + 原子替换，失败回滚）→ 最后写标记文件
  /// （标记是提交点：写标记前失败，旧库与旧标记都原地不动）。
  /// 复制成功后把 `databaseLocation` 写进新库（新库已存在，打开不
  /// 会触发建库播种；写失败也不影响——标记文件才是依据）。
  /// 调用方：目标已有库时先问用户，`overwrite` 按用户选择传
  /// （覆盖 / 保留 / 取消；文件目录沿用同一选择）。
  /// `onProgress` / `isCancelled` 见 [migrateDataFiles]（大目录
  /// 复制进度 / 取消）。
  Future<DbMigrationOutcome> migrateToDirectory(String dir,
      {bool overwrite = false,
      void Function(double progress)? onProgress,
      bool Function()? isCancelled}) async {
    final currentDir = p.dirname(dbPathUsed ??
        p.join(dataDirectoryPath(), 'quiz-master2.db'));
    final sourcePath = p.join(currentDir, 'quiz-master2.db');
    if (p.equals(p.normalize(currentDir), p.normalize(dir))) {
      return DbMigrationOutcome.sameLocation;
    }
    if (!overwrite && databaseExistsAt(dir)) {
      return DbMigrationOutcome.targetExists;
    }
    final hadSource = File(sourcePath).existsSync();
    try {
      await _db?.close();
    } catch (_) {}
    _db = null;
    _dbFuture = null;
    final outcome = await migrateDataFiles(currentDir, dir,
        overwrite: overwrite,
        onProgress: onProgress,
        isCancelled: isCancelled);
    if (outcome != DbMigrationOutcome.migrated) return outcome;
    final def = _defaultDataDirectoryPath();
    try {
      await Directory(def).create(recursive: true);
      await File(p.join(def, 'db_location.txt')).writeAsString(dir);
    } catch (_) {
      return DbMigrationOutcome.failed;
    }
    try {
      await saveSetting('databaseLocation', dir);
    } catch (_) {}
    return hadSource
        ? DbMigrationOutcome.migrated
        : DbMigrationOutcome.noSourceDb;
  }

  static String _defaultDataDirectoryPath() {
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

  /// §4.1：缓存 `Future<Database>` 本身：启动时多处同时 `await db`
  /// 只会打开一次连接（旧写法是 `if (_db != null)`，并发调用会
  /// 各自 openDatabase，旧连接泄漏、多连接同时写同一文件）。
  /// 打开失败时清掉缓存，下次重试重新打开——失败的 Future 不会
  /// 被永久缓存。`migrateToDirectory` 关库时同时清 `_dbFuture`。
  Future<Database> get db {
    final cached = _dbFuture;
    if (cached != null) return cached;
    late final Future<Database> opened;
    opened = _openDb().then((d) => d, onError: (Object e) {
      if (identical(_dbFuture, opened)) _dbFuture = null;
      throw e;
    });
    _dbFuture = opened;
    return opened;
  }

  Future<Database> _openDb() async {
    sqfliteFfiInit();
    final factory = databaseFactoryFfi;
    final dataDir = Directory(dataDirectoryPath());
    await dataDir.create(recursive: true);
    var dbPath = p.join(dataDir.path, 'quiz-master2.db');
    try {
      _db = await openAt(dbPath, factory: factory);
    } on LegacyDatabaseException {
      // 删老库失败：拒绝打开，不滑入 fallback（否则新旧库并存）。
      rethrow;
    } catch (_) {
      final installDir = p.dirname(Platform.resolvedExecutable);
      final fallbackDir = Directory(p.join(installDir, 'data'));
      await fallbackDir.create(recursive: true);
      dbPath = p.join(fallbackDir.path, 'quiz-master2.db');
      _db = await openAt(dbPath, factory: factory);
    }
    dbPathUsed = dbPath;
    return _db!;
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
  static Future<Database> openAt(String dbPath,
      {DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactoryFfi;
    await deleteLegacyDatabaseIfPresent(dbPath, factory: f);
    return f.openDatabase(dbPath,
        options: OpenDatabaseOptions(
          version: schemaVersion,
          onCreate: _onCreate,
          // §2.1：旧版应用打开 v2 库：直接抛错并提示用新版打开，
          // 不许静默删库重建。
          onDowngrade: (db, oldVersion, newVersion) async {
            throw StateError(
                '数据库是新版格式（v$oldVersion），请用新版打开（当前要求 v$newVersion）');
          },
        ));
  }

  /// §2.2：删老库（可单测版）：文件不存在或已是 v2 时什么都不做，
  /// 返回 false；删掉老库文件（含 -wal / -shm）时返回 true。
  /// 删除失败抛 StateError（调用方拒绝打开、不建新库）。
  static Future<bool> deleteLegacyDatabaseIfPresent(String dbPath,
      {DatabaseFactory? factory}) async {
    final file = File(dbPath);
    if (!file.existsSync()) return false;
    final f = factory ?? databaseFactoryFfi;
    int version;
    Database? probe;
    try {
      probe = await f.openDatabase(dbPath,
          options: OpenDatabaseOptions(readOnly: true));
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
    if (version == schemaVersion) return false;
    // 老库：删主库 + -wal / -shm。删之前先 checkpoint：只读连接已关，
    // WAL 里的数据若没 checkpoint 进主库，删 -wal 会丢——但老库本来
    // 就要整体删除（§6 第 1 条），不保留任何老数据。
    try {
      await file.delete();
      for (final suffix in ['-wal', '-shm']) {
        final side = File('$dbPath$suffix');
        if (side.existsSync()) await side.delete();
      }
    } catch (e) {
      throw LegacyDatabaseException('老数据库删除失败，已拒绝打开，下次启动重试：$e');
    }
    return true;
  }

  static Future<void> _onCreate(Database db, int version) async {
    await createTables(db);
    await _seed(db);
  }

  /// 测试用：在已打开的空库上建全部表（不播种演示数据）。
  /// 与 _onCreate 共用同一份建表语句，测试库与真实库结构一致。
  static Future<void> createTables(Database db) async {
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
        'CREATE INDEX idx_boxes_task_page ON question_boxes(collect_task_id, page)');
    await db.execute(
        'CREATE INDEX idx_boxes_question ON question_boxes(question_id)');
    await db.execute(
        'CREATE INDEX idx_boxes_parent ON question_boxes(parent_box_id)');
    // 一题只能有一个 layer = 1 的整题框（修框中的框 question_id 为 NULL，
    // 不受限；确认回填时若已存在同题整题框，须先删旧框再回填）。
    await db.execute('''
      CREATE UNIQUE INDEX idx_boxes_one_layer1_per_question
        ON question_boxes(question_id) WHERE layer = 1 AND question_id IS NOT NULL''');
  }

  static Future<void> _seedCauseRecordsFor(Database db, Question q,
      {required DateTime joinedAt, int solvedCount = 0}) async {
    for (final cause in q.allCauses) {
      await db.insert(
        'cause_records',
        {
          'question_id': q.id,
          'cause': cause,
          'subject_id': q.subjectId,
          'status': 'pending',
          'solved_count': solvedCount,
          'last_check': null,
          'recheck_date': null,
          'remedy_history': '[]',
          'joined_at': joinedAt.millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  static Future<void> _seed(Database db) async {
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

  /// §3.2：多值字段编解码收口（全部 11 处读写点统一调这里，
  /// 业务代码里不许再出现裸 `join(',')` / `split(',')`）：
  /// - [encodeStringList]/[decodeStringList]：folder_ids /
  ///   knowledge_ids / error_types / custom_error_types / tags；
  /// - [encodeRemedyList]/[decodeRemedyList]：remedy_history
  ///   （与字符串列表同构，单列一对函数是为将来补救条目变对象时只改一处）；
  /// - [encodeQueue]/[decodeQueue]：review_state.queue（对象数组，
  ///   见 §3.4 的 ReviewQueueItem）。
  /// 空串 '' 与 NULL 统一解码为 []；编码空列表写 '[]'，不写 ''。
  /// 读到非法值（不是 JSON 字符串数组）按空列表处理，不猜逗号拆分
  /// （§3.3：没有老数据需要兼容，读侧只认 JSON）。
  static String encodeStringList(List<String> values) =>
      jsonEncode(values);

  static List<String> decodeStringList(Object? value) {
    if (value == null) return const [];
    if (value is! String || value.isEmpty) return const [];
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) {
        return decoded.whereType<String>().toList();
      }
    } catch (_) {}
    return const [];
  }

  static String encodeRemedyList(List<String> values) =>
      jsonEncode(values);

  static List<String> decodeRemedyList(Object? value) =>
      decodeStringList(value);

  static String encodeQueue(List<ReviewQueueItem> queue) => jsonEncode([
        for (final item in queue)
          {'q': item.questionId, 'c': item.cause},
      ]);

  static List<ReviewQueueItem> decodeQueue(Object? value) {
    if (value == null) return const [];
    if (value is! String || value.isEmpty) return const [];
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) {
        return [
          for (final e in decoded)
            if (e is Map && e['q'] is String && e['c'] is String)
              ReviewQueueItem(
                  questionId: e['q'] as String, cause: e['c'] as String),
        ];
      }
    } catch (_) {}
    return const [];
  }

  static Map<String, Object?> _toRow(Question q) => {
        'id': q.id,
        'title': q.title,
        'subject_id': q.subjectId,
        'folder_ids': encodeStringList(q.folderIds),
        'exam_id': q.examId,
        'knowledge_ids': encodeStringList(q.knowledgePointIds),
        'error_types': encodeStringList(q.errorTypes),
        'custom_error_types': encodeStringList(q.customErrorTypes),
        'tags': encodeStringList(q.tags),
        'answer': q.answer,
        'explanation': q.explanation,
        'notes': q.notes,
        'review_count': q.reviewCount,
        'is_organized': q.isOrganized ? 1 : 0,
        'is_demo': q.isDemo ? 1 : 0,
        'is_favorite': q.isFavorite ? 1 : 0,
        'is_archived': q.isArchived ? 1 : 0,
        'review_joined': q.reviewJoined ? 1 : 0,
        'created_at': q.createdAt.millisecondsSinceEpoch,
        'slice_kind': q.sliceKind,
        'slice_text': q.sliceText,
        // §1.2(a)：图片链路列（全部可空）。
        'source_path': q.sourcePath,
        'source_kind': q.sourceKind,
        'source_page': q.sourcePage,
        'page_image_path': q.pageImagePath,
        'slice_path': q.slicePath,
        'slice_width': q.sliceWidth,
        'slice_height': q.sliceHeight,
      };

  static Question _fromRow(Map<String, Object?> r) {
    return Question(
      id: r['id'] as String,
      title: r['title'] as String,
      subjectId: r['subject_id'] as String,
      folderIds: decodeStringList(r['folder_ids']),
      examId: r['exam_id'] as String?,
      knowledgePointIds: decodeStringList(r['knowledge_ids']),
      errorTypes: decodeStringList(r['error_types']),
      customErrorTypes: decodeStringList(r['custom_error_types']),
      tags: decodeStringList(r['tags']),
      answer: r['answer'] as String?,
      explanation: r['explanation'] as String?,
      notes: r['notes'] as String?,
      reviewCount: (r['review_count'] as int?) ?? 0,
      isOrganized: (r['is_organized'] as int?) == 1,
      isDemo: (r['is_demo'] as int?) == 1,
      isFavorite: (r['is_favorite'] as int?) == 1,
      isArchived: (r['is_archived'] as int?) == 1,
      reviewJoined: (r['review_joined'] as int?) == 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      sliceKind: (r['slice_kind'] as String?) ?? 'material',
      sliceText: (r['slice_text'] as String?) ?? '',
      sourcePath: r['source_path'] as String?,
      sourceKind: r['source_kind'] as String?,
      sourcePage: r['source_page'] as int?,
      pageImagePath: r['page_image_path'] as String?,
      slicePath: r['slice_path'] as String?,
      sliceWidth: r['slice_width'] as int?,
      sliceHeight: r['slice_height'] as int?,
    );
  }

  Future<List<Question>> allQuestions() async =>
      allQuestionsFrom(await db);

  /// §8.1：读全部题（可单测版）：直接对传入的库句柄读，不碰单例。
  static Future<List<Question>> allQuestionsFrom(Database db) async {
    final rows = await db.query('questions', orderBy: 'created_at DESC');
    return rows.map(_fromRow).toList();
  }

  Future<Question?> questionById(String id) async {
    final d = await db;
    final rows =
        await d.query('questions', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
      String questionId) async {
    final d = await db;
    final rows = await d.query('review_history',
        where: 'question_id = ?',
        whereArgs: [questionId],
        orderBy: 'reviewed_at DESC');
    return rows
        .map((r) => (
              result: r['result'] as String,
              reviewedAt: DateTime.fromMillisecondsSinceEpoch(
                  r['reviewed_at'] as int),
            ))
        .toList();
  }

  Future<void> addCauseCheckHistory(
      {required String questionId, required String result}) async {
    final d = await db;
    await d.insert('review_history', {
      'question_id': questionId,
      'result': result,
      'reviewed_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  static CauseRecord _causeFromRow(Map<String, Object?> r) {
    return CauseRecord(
      questionId: r['question_id'] as String,
      cause: r['cause'] as String,
      subjectId: r['subject_id'] as String,
      status: switch (r['status'] as String?) {
        'inProgress' => CauseStatus.inProgress,
        'solved' => CauseStatus.solved,
        _ => CauseStatus.pending,
      },
      solvedCount: (r['solved_count'] as int?) ?? 0,
      lastCheck: r['last_check'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(r['last_check'] as int),
      recheckDate: r['recheck_date'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(r['recheck_date'] as int),
      remedyHistory: decodeRemedyList(r['remedy_history']),
      joinedAt: DateTime.fromMillisecondsSinceEpoch(r['joined_at'] as int),
    );
  }

  Future<List<CauseRecord>> allCauseRecords() async {
    final d = await db;
    final rows =
        await d.query('cause_records', orderBy: 'joined_at ASC, id ASC');
    return rows.map(_causeFromRow).toList();
  }

  Future<List<CauseRecord>> causeRecordsForQuestion(
      String questionId) async {
    final d = await db;
    final rows = await d.query('cause_records',
        where: 'question_id = ?', whereArgs: [questionId], orderBy: 'id ASC');
    return rows.map(_causeFromRow).toList();
  }

  Future<void> ensureCauseRecords(Question q) async {
    final d = await db;
    await _seedCauseRecordsFor(d, q, joinedAt: DateTime.now());
  }

  static Map<String, Object?> _causeRecordToRow(CauseRecord r) => {
        'question_id': r.questionId,
        'cause': r.cause,
        'subject_id': r.subjectId,
        'status': r.status.name,
        'solved_count': r.solvedCount,
        'last_check': r.lastCheck?.millisecondsSinceEpoch,
        'recheck_date': r.recheckDate?.millisecondsSinceEpoch,
        'remedy_history': encodeRemedyList(r.remedyHistory),
        'joined_at': r.joinedAt.millisecondsSinceEpoch,
      };

  Future<void> upsertCauseRecord(CauseRecord r) async {
    final d = await db;
    await d.insert(
      'cause_records',
      _causeRecordToRow(r),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    bumpBadgeVersion();
  }

  /// §4.2：自查三步同事务：改错因记录 → 记自查历史 → 题目自查次数 +1。
  /// 中间失败整体回滚，不留“状态已变、历史没记、次数没加”的半截记录。
  /// 角标在提交成功后才 bump 一次（事务内不调 UI 通知）。
  Future<void> recordSelfCheckTxn({
    required CauseRecord updated,
    required String questionId,
    required String result,
  }) async {
    final d = await db;
    await recordSelfCheckInto(d,
        updated: updated, questionId: questionId, result: result);
    bumpBadgeVersion();
  }

  /// §4.2：自查事务（可单测版）：直接对传入的库句柄做，不碰单例、不 bump。
  static Future<void> recordSelfCheckInto(
    Database db, {
    required CauseRecord updated,
    required String questionId,
    required String result,
  }) async {
    await db.transaction((txn) async {
      await txn.insert(
        'cause_records',
        _causeRecordToRow(updated),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert('review_history', {
        'question_id': questionId,
        'result': result,
        'reviewed_at': DateTime.now().millisecondsSinceEpoch,
      });
      await txn.rawUpdate(
          'UPDATE questions SET review_count = review_count + 1 WHERE id = ?',
          [questionId]);
    });
  }

  Future<void> deleteCauseRecordsForQuestion(String questionId) async {
    final d = await db;
    await d.delete('cause_records',
        where: 'question_id = ?', whereArgs: [questionId]);
  }

  Future<void> deleteCauseRecord(String questionId, String cause) async {
    final d = await db;
    await d.delete('cause_records',
        where: 'question_id = ? AND cause = ?',
        whereArgs: [questionId, cause]);
  }

  Future<void> saveReviewState(
      {required List<ReviewQueueItem> queue, required int position}) async {
    final d = await db;
    await d.insert('review_state', {
      'id': 1,
      'queue': encodeQueue(queue),
      'position': position,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<ReviewSessionState?> loadReviewState() async {
    final d = await db;
    final rows = await d.query('review_state', where: 'id = 1', limit: 1);
    if (rows.isEmpty) return null;
    final r = rows.first;
    final queue = decodeQueue(r['queue']);
    if (queue.isEmpty) return null;
    return ReviewSessionState(
      queue: queue,
      position: (r['position'] as int?) ?? 0,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
    );
  }

  Future<void> clearReviewState() async {
    final d = await db;
    await d.delete('review_state', where: 'id = 1');
  }

  // ---------- 学科 / 文件夹 / 标签 / 试卷 / 知识点 ----------

  Future<List<Subject>> allSubjects() async {
    final d = await db;
    // 显式按插入顺序读：subjects 表没有 sort_order 列，顺序就是 rowid 顺序；
    // 不写 orderBy 时 SQLite 不保证返回顺序，曾经因此出现过学科乱序。
    final rows = await d.query('subjects', orderBy: 'rowid');
    return rows
        .map((r) => Subject(
              id: r['id'] as String,
              name: r['name'] as String,
              color: Color((r['color'] as int?) ?? 0xFF2F7CF6),
              icon: _iconFor(r['id'] as String),
              coverStyle: (r['cover_style'] as String?) ?? 'plain',
              coverColor: (r['cover_color'] as String?) ?? 'blue',
            ))
        .toList();
  }

  static String _iconFor(String id) => switch (id) {
        'math' => '数',
        'english' => '英',
        'politics' => '政',
        _ => id.isEmpty ? '学' : id[0],
      };

  Future<void> upsertSubject(Subject s) async {
    final d = await db;
    final values = {
      'id': s.id,
      'name': s.name,
      'color': s.color.toARGB32(),
      'cover_style': s.coverStyle,
      'cover_color': s.coverColor,
    };
    // 原地更新：ConflictAlgorithm.replace 是先删后插，会把这行顶到表尾，
    // 导致学科顺序乱掉（点数学的封面，数学就跑到最下面）。已存在的行只
    // UPDATE，rowid 不变，顺序就不会动；不存在时才 INSERT。
    final updated = await d.update('subjects', values,
        where: 'id = ?', whereArgs: [s.id]);
    if (updated == 0) {
      await d.insert('subjects', values);
    }
    bumpBadgeVersion();
  }

  Future<void> deleteSubject(String id) async {
    final d = await db;
    await deleteSubjectFrom(d, id);
    bumpBadgeVersion();
  }

  /// §4.2/§4.5：删学科同事务：该科各题（经 _deleteQuestionTxn，含
  /// review_history、自查历史、review_state 队列、collect_tasks 指向）
  /// → 该科收集任务 → recent_tasks 里该科行 → 文件夹 / 知识点 / 学科行。
  /// 中途失败整体回滚，不留“题删了、学科还在”的半截状态。
  static Future<void> deleteSubjectFrom(Database db, String id) async {
    // §4.5：删前快照该科题的切片与任务 id，事务提交后删文件：
    // 切片是题独占的，任务目录只在无人引用时删（页图可能还被题引用，
    // 但该科题已全删，引用已不存在；仍走引用检查，不误删）。
    final slices = await db.query('questions',
        columns: ['slice_path'],
        where: 'subject_id = ?',
        whereArgs: [id]);
    final taskRows = await db.query('collect_tasks',
        columns: ['id'], where: 'subject_id = ?', whereArgs: [id]);
    await db.transaction((txn) async {
      final qs = await txn.query('questions',
          columns: ['id'], where: 'subject_id = ?', whereArgs: [id]);
      for (final row in qs) {
        await _deleteQuestionTxn(txn, row['id'] as String);
      }
      await txn.delete('collect_tasks',
          where: 'subject_id = ?', whereArgs: [id]);
      await txn.delete('recent_tasks',
          where: 'subject_id = ?', whereArgs: [id]);
      await txn.delete('folders', where: 'subject_id = ?', whereArgs: [id]);
      await txn.delete('knowledge_points',
          where: 'subject_id = ?', whereArgs: [id]);
      await txn.delete('subjects', where: 'id = ?', whereArgs: [id]);
    });
    for (final row in slices) {
      await _deleteDataFileIfUnreferenced(db, row['slice_path'] as String?);
    }
    for (final row in taskRows) {
      await _deleteTaskDirIfUnreferenced(db, row['id'] as String);
    }
  }

  Future<List<Folder>> allFolders({String? subjectId}) async {
    final d = await db;
    final rows = subjectId == null
        ? await d.query('folders', orderBy: 'subject_id ASC, sort_order ASC')
        : await d.query('folders',
            where: 'subject_id = ?',
            whereArgs: [subjectId],
            orderBy: 'sort_order ASC');
    return rows
        .map((r) => Folder(
              id: r['id'] as String,
              name: r['name'] as String,
              subjectId: r['subject_id'] as String,
              parentId: r['parent_id'] as String?,
              sortOrder: (r['sort_order'] as int?) ?? 0,
            ))
        .toList();
  }

  Future<void> upsertFolder(Folder f) async {
    final d = await db;
    await d.insert('folders', {
      'id': f.id,
      'name': f.name,
      'subject_id': f.subjectId,
      'parent_id': f.parentId,
      'sort_order': f.sortOrder,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    bumpBadgeVersion();
  }

  /// 删文件夹：只在这个文件夹里的题跟着删；在多个文件夹里的题只移走
  /// 这个文件夹的关联。返回删掉的题数。
  Future<int> deleteFolder(Folder f) async {
    final d = await db;
    final deleted = await deleteFolderFrom(d, f);
    bumpBadgeVersion();
    return deleted;
  }

  /// §4.2：删文件夹（可单测版）：整棵子树一次事务，不 bump。
  /// 事务提交后删被删掉的题的切片（只删库里已不存在的题的切片，
  /// 且只删无引用文件；只移走关联的题不动文件）。
  static Future<int> deleteFolderFrom(Database db, Folder f) async {
    final before = await db.query('questions',
        columns: ['id', 'slice_path']);
    var deleted = 0;
    await db.transaction((txn) async {
      deleted = await _deleteFolderTxn(txn, f);
    });
    final remaining = await db.query('questions', columns: ['id']);
    final remainingIds = {for (final r in remaining) r['id'] as String};
    for (final row in before) {
      if (!remainingIds.contains(row['id'] as String)) {
        await _deleteDataFileIfUnreferenced(db, row['slice_path'] as String?);
      }
    }
    return deleted;
  }

  /// §4.2：递归删文件夹（事务内传 Transaction，不开嵌套事务——
  /// sqflite 不支持嵌套事务，递归里再 transaction 会抛错）。
  static Future<int> _deleteFolderTxn(Transaction txn, Folder f) async {
    final rows = await txn.query('questions');
    var deleted = 0;
    for (final row in rows) {
      final q = _fromRow(row);
      if (!q.folderIds.contains(f.id)) continue;
      if (q.folderIds.length == 1) {
        await _deleteQuestionTxn(txn, q.id);
        deleted++;
      } else {
        final rest = q.folderIds.where((e) => e != f.id).toList();
        await txn.update('questions',
            {'folder_ids': encodeStringList(rest)},
            where: 'id = ?',
            whereArgs: [q.id]);
      }
    }
    // 子文件夹随父文件夹一起删（同规则递归到子文件夹里的题）。
    final subs = await txn.query('folders',
        where: 'parent_id = ?', whereArgs: [f.id]);
    for (final s in subs) {
      final sub = Folder(
          id: s['id'] as String,
          name: s['name'] as String,
          subjectId: s['subject_id'] as String,
          parentId: s['parent_id'] as String?);
      deleted += await _deleteFolderTxn(txn, sub);
    }
    await txn.delete('folders', where: 'id = ?', whereArgs: [f.id]);
    return deleted;
  }

  Future<List<String>> allTags() async {
    final d = await db;
    final rows = await d.query('tags');
    return rows.map((r) => r['name'] as String).toList();
  }

  Future<void> insertTag(String name) async {
    final d = await db;
    await d.insert('tags', {'id': 'tag-$name', 'name': name},
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> renameTag(String oldName, String newName) async {
    final d = await db;
    await renameTagFrom(d, oldName, newName);
  }

  /// §4.2：改标签名同事务：标签行改名 + 所有挂了旧标签的题改标签。
  /// 可单测版（直接对传入的库句柄做，不碰单例）。
  static Future<void> renameTagFrom(
      Database db, String oldName, String newName) async {
    await db.transaction((txn) async {
      await txn.update('tags', {'id': 'tag-$newName', 'name': newName},
          where: 'name = ?', whereArgs: [oldName]);
      final rows = await txn.query('questions');
      for (final row in rows) {
        final q = _fromRow(row);
        if (!q.tags.contains(oldName)) continue;
        final tags = q.tags.map((t) => t == oldName ? newName : t).toList();
        await txn.update('questions',
            {'tags': encodeStringList(tags)},
            where: 'id = ?',
            whereArgs: [q.id]);
      }
    });
  }

  Future<void> deleteTag(String name) async {
    final d = await db;
    await deleteTagFrom(d, name);
  }

  /// §4.2：删标签同事务：标签行 + 所有题上的该标签。可单测版。
  static Future<void> deleteTagFrom(Database db, String name) async {
    await db.transaction((txn) async {
      await txn.delete('tags', where: 'name = ?', whereArgs: [name]);
      final rows = await txn.query('questions');
      for (final row in rows) {
        final q = _fromRow(row);
        if (!q.tags.contains(name)) continue;
        final tags = q.tags.where((t) => t != name).toList();
        await txn.update('questions',
            {'tags': encodeStringList(tags)},
            where: 'id = ?',
            whereArgs: [q.id]);
      }
    });
  }

  Future<List<Exam>> allExams() async {
    final d = await db;
    final rows = await d.query('exams');
    return rows
        .map((r) => Exam(
              id: r['id'] as String,
              name: r['name'] as String,
              date: r['date'] == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(r['date'] as int),
            ))
        .toList();
  }

  Future<void> insertExam(Exam e) async {
    final d = await db;
    await d.insert('exams', {
      'id': e.id,
      'name': e.name,
      'date': e.date?.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> renameExam(String id, String newName) async {
    final d = await db;
    await d.update('exams', {'name': newName},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteExam(String id) async {
    final d = await db;
    await d.update('exams', {'name': ''}, where: 'id = ?', whereArgs: [id]);
    await d.delete('exams', where: 'id = ?', whereArgs: [id]);
    await d.update('questions', {'exam_id': null},
        where: 'exam_id = ?', whereArgs: [id]);
  }

  Future<List<KnowledgePoint>> allKnowledgePoints() async {
    final d = await db;
    final rows = await d.query('knowledge_points');
    return rows
        .map((r) => KnowledgePoint(
              id: r['id'] as String,
              subjectId: r['subject_id'] as String,
              chapter: r['chapter'] as String,
              name: r['name'] as String,
            ))
        .toList();
  }

  Future<void> insertKnowledgePoint(KnowledgePoint kp) async {
    final d = await db;
    await d.insert('knowledge_points', {
      'id': kp.id,
      'subject_id': kp.subjectId,
      'chapter': kp.chapter,
      'name': kp.name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> renameKnowledgePoint(String id, String newName) async {
    final d = await db;
    await d.update('knowledge_points', {'name': newName},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteKnowledgePoint(String id) async {
    final d = await db;
    await deleteKnowledgePointFrom(d, id);
  }

  /// §4.2：删知识点同事务：知识点行 + 所有题上的该知识点。可单测版。
  static Future<void> deleteKnowledgePointFrom(
      Database db, String id) async {
    await db.transaction((txn) async {
      await txn.delete('knowledge_points', where: 'id = ?', whereArgs: [id]);
      final rows = await txn.query('questions');
      for (final row in rows) {
        final q = _fromRow(row);
        if (!q.knowledgePointIds.contains(id)) continue;
        final kps = q.knowledgePointIds.where((e) => e != id).toList();
        await txn.update('questions',
            {'knowledge_ids': encodeStringList(kps)},
            where: 'id = ?',
            whereArgs: [q.id]);
      }
    });
  }

  /// 章节改名：只改 `knowledge_points.chapter` 的名字，题上挂的知识点
  /// id 不变，题跟着改名。空章节存不下来（章节只随知识点存在），
  /// 所以加章节仍须同时给第一个知识点（见 repository.addChapter）。
  Future<void> renameChapter(
      String subjectId, String oldChapter, String newChapter) async {
    final d = await db;
    await d.update('knowledge_points', {'chapter': newChapter},
        where: 'subject_id = ? AND chapter = ?',
        whereArgs: [subjectId, oldChapter]);
  }

  /// 删除章节：删掉该章节下全部知识点；题还在，只是这些知识点变空、
  /// 成为待补充（与删知识点同一口径）。
  Future<void> deleteChapter(String subjectId, String chapter) async {
    final d = await db;
    await deleteChapterFrom(d, subjectId, chapter);
  }

  /// §4.2：删除章节同事务：该章节全部知识点行 + 所有题上的这些
  /// 知识点。可单测版。
  static Future<void> deleteChapterFrom(
      Database db, String subjectId, String chapter) async {
    await db.transaction((txn) async {
      final rows = await txn.query('knowledge_points',
          columns: ['id'],
          where: 'subject_id = ? AND chapter = ?',
          whereArgs: [subjectId, chapter]);
      final ids = rows.map((r) => r['id'] as String).toList();
      await txn.delete('knowledge_points',
          where: 'subject_id = ? AND chapter = ?',
          whereArgs: [subjectId, chapter]);
      if (ids.isEmpty) return;
      final qrows = await txn.query('questions');
      for (final row in qrows) {
        final q = _fromRow(row);
        final kept =
            q.knowledgePointIds.where((e) => !ids.contains(e)).toList();
        if (kept.length == q.knowledgePointIds.length) continue;
        await txn.update('questions',
            {'knowledge_ids': encodeStringList(kept)},
            where: 'id = ?',
            whereArgs: [q.id]);
      }
    });
  }

  Future<void> upsertQuestion(Question q) async {
    final d = await db;
    await upsertQuestionInto(d, q);
    bumpBadgeVersion();
  }

  /// §8.1：写题（可单测版）：直接对传入的库句柄写，不碰单例、不 bump。
  static Future<void> upsertQuestionInto(Database db, Question q) async {
    await db.insert('questions', _toRow(q),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteQuestion(String id) async {
    final d = await db;
    await deleteQuestionFrom(d, id);
    bumpBadgeVersion();
  }

  /// §4.5：删题（可单测版）：一次事务，不 bump。事务提交后删该题
  /// 独占的切片文件（页图不删，同页多题共享；文件删失败不回滚，
  /// 由孤儿清理兜底）。
  static Future<void> deleteQuestionFrom(Database db, String id) async {
    final slice = await _slicePathOf(db, id);
    await db.transaction((txn) => _deleteQuestionTxn(txn, id));
    await _deleteDataFileIfUnreferenced(db, slice);
  }

  static Future<String?> _slicePathOf(Database db, String id) async {
    final rows = await db.query('questions',
        columns: ['slice_path'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['slice_path'] as String?;
  }

  /// §4.5/§3.4：从复习队列里去掉该题的项（队列是 ReviewQueueItem
  /// 对象数组，按 questionId 匹配，不再拼字符串比对）。
  static Future<void> _removeFromReviewQueueTxn(
      Transaction txn, String questionId) async {
    final rows =
        await txn.query('review_state', where: 'id = 1', limit: 1);
    if (rows.isEmpty) return;
    final queue = decodeQueue(rows.first['queue']);
    final kept =
        queue.where((e) => e.questionId != questionId).toList();
    if (kept.length == queue.length) return;
    await txn.update('review_state', {'queue': encodeQueue(kept)},
        where: 'id = ?', whereArgs: [1]);
  }

  /// §4.2/§4.5：删题的全部写操作（事务内，不 bump、不开新事务）：
  /// 解决记录 → 自查历史 → 收集任务的指向置空（任务本身保留）→
  /// 复习队列里的项 → §1.2(c) 该题的框（含第 1 层框及其子框，
  /// parent_box_id 指向该题整题框的行）→ 题目行。
  /// 注意：页图不删（同页多题共享）；切片文件在事务提交后由调用方
  /// 处理（P2 落盘后，见 §4.5）。
  static Future<void> _deleteQuestionTxn(
      Transaction txn, String id) async {
    await txn.delete('cause_records',
        where: 'question_id = ?', whereArgs: [id]);
    await txn.delete('review_history',
        where: 'question_id = ?', whereArgs: [id]);
    await txn.update('collect_tasks', {'question_id': null},
        where: 'question_id = ?', whereArgs: [id]);
    await _removeFromReviewQueueTxn(txn, id);
    // 先删子框（parent_box_id 指向该题整题框的行），再删该题的框。
    final ownBoxes = await txn.query('question_boxes',
        columns: ['id'],
        where: 'question_id = ?',
        whereArgs: [id]);
    for (final row in ownBoxes) {
      await txn.delete('question_boxes',
          where: 'parent_box_id = ?', whereArgs: [row['id'] as String]);
    }
    await txn.delete('question_boxes',
        where: 'question_id = ?', whereArgs: [id]);
    await txn.delete('questions', where: 'id = ?', whereArgs: [id]);
  }

  /// B7：最近任务 kind 归一化（纯函数，便于单测）。
  /// 写入点现已统一写中文 '整理' / '收集'；库里已有的旧英文值
  /// 'organize' / 'collect' 在读出时映射成中文显示，不丢数据、
  /// 不改库。未知值原样返回（首页再按默认“复习”处理）。
  static String normalizeRecentKind(String kind) => switch (kind) {
        'organize' => '整理',
        'collect' => '收集',
        _ => kind,
      };

  Future<({String kind, String subjectId, String title})?> recentTask() async {
    final d = await db;
    final rows = await d.query('recent_tasks', where: 'id = 1', limit: 1);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return (
      kind: normalizeRecentKind(r['kind'] as String),
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

  /// 一键清空演示数据（只删 is_demo = 1 的题，同时删其解决记录与断点）。
  Future<int> clearDemoData() async {
    final d = await db;
    final n = await clearDemoDataFrom(d);
    bumpBadgeVersion();
    return n;
  }

  /// §4.2/§4.5：清演示（可单测版）：一次事务，不 bump。演示题的
  /// 解决记录与自查历史 → review_state 断点 → recent_tasks →
  /// 演示题；非演示数据一律不动。
  static Future<int> clearDemoDataFrom(Database db) async {
    var n = 0;
    // §4.5：删前快照演示题的切片，事务提交后删无引用的切片文件。
    final demoSlices = await db.query('questions',
        columns: ['slice_path'], where: 'is_demo = 1');
    await db.transaction((txn) async {
      final demoRows = await txn.query('questions',
          columns: ['id'], where: 'is_demo = 1');
      for (final row in demoRows) {
        final id = row['id'] as String;
        await txn.delete('cause_records',
            where: 'question_id = ?', whereArgs: [id]);
        await txn.delete('review_history',
            where: 'question_id = ?', whereArgs: [id]);
      }
      await txn.delete('review_state', where: 'id = 1');
      await txn.delete('recent_tasks');
      n = await txn.delete('questions', where: 'is_demo = 1');
    });
    for (final row in demoSlices) {
      await _deleteDataFileIfUnreferenced(db, row['slice_path'] as String?);
    }
    return n;
  }

  Future<int> demoQuestionCount() async {
    final d = await db;
    final rows = await d.rawQuery(
        'SELECT COUNT(*) AS n FROM questions WHERE is_demo = 1');
    return (rows.first['n'] as int?) ?? 0;
  }

  static CollectTask _collectTaskFromRow(Map<String, Object?> r) {
    final createdMs = r['created_at'] as int?;
    // §1.6.1：page_rotations 是 JSON（{"1": 90}），键是字符串页码；
    // 读不到/非法时按 {} 处理（草稿无旋转）。
    Map<int, int> rotations = const {};
    final rawRotations = r['page_rotations'] as String?;
    if (rawRotations != null && rawRotations.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawRotations);
        if (decoded is Map) {
          rotations = {
            for (final e in decoded.entries)
              if (int.tryParse('${e.key}') != null &&
                  e.value is num)
                int.parse('${e.key}'): (e.value as num).toInt(),
          };
        }
      } catch (_) {}
    }
    return CollectTask(
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
      questionId: r['question_id'] as String?,
      createdAt: createdMs == null || createdMs == 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(createdMs),
      sourcePath: (r['source_path'] as String?) ?? '',
      pageRotations: rotations,
    );
  }

  static Map<String, Object?> _collectTaskToRow(CollectTask t) => {
        'id': t.id,
        'name': t.name,
        'file_name': t.fileName,
        'subject_id': t.subjectId,
        'status': t.status.name,
        'progress': t.progress,
        'page_count': t.pageCount,
        'page': t.page,
        'error': t.error,
        'question_id': t.questionId,
        // §1.2(b)：source_path 与 fileName 分离；page_rotations 写 JSON。
        'source_path': t.sourcePath,
        'page_rotations': jsonEncode({
          for (final e in t.pageRotations.entries) '${e.key}': e.value,
        }),
      };

  Future<List<CollectTask>> allCollectTasks() async =>
      allCollectTasksFrom(await db);

  /// §4.3：按 created_at 稳定排序（同毫秒建的批量任务用 rowid 兜底）。
  static Future<List<CollectTask>> allCollectTasksFrom(Database db) async {
    final rows = await db.query('collect_tasks',
        orderBy: 'created_at DESC, rowid DESC');
    return rows.map(_collectTaskFromRow).toList();
  }

  /// §4.3：角标刷新节流（只在状态变化时 bump）：进度百分比高频更新
  /// （真实导入按字节回调）不触发 `_refreshBadges` 的 5 个查询；
  /// 新任务、状态变化（导入中 → 待框选等）时才 bump。
  Future<void> upsertCollectTask(CollectTask t) async {
    final d = await db;
    final old = await d.query('collect_tasks',
        columns: ['status'], where: 'id = ?', whereArgs: [t.id], limit: 1);
    await upsertCollectTaskInto(d, t);
    if (old.isEmpty || old.first['status'] != t.status.name) {
      bumpBadgeVersion();
    }
  }

  /// §4.3：UPDATE-first（照 upsertSubject 的正面先例）：REPLACE 是
  /// 先删后插，会改 rowid、把行顶到最上面，进度高频更新时任务列表
  /// 自己跳序。已存在的行只 UPDATE（不碰 created_at，rowid 不变，
  /// 顺序就不动）；不存在时才 INSERT，并写 created_at（调用方没给
  /// 就写当前时间）。
  static Future<void> upsertCollectTaskInto(
      Database db, CollectTask t) async {
    final values = _collectTaskToRow(t);
    final updated = await db.update('collect_tasks', values,
        where: 'id = ?', whereArgs: [t.id]);
    if (updated == 0) {
      await db.insert('collect_tasks', {
        ...values,
        'created_at': t.createdAt?.millisecondsSinceEpoch ??
            DateTime.now().millisecondsSinceEpoch,
      });
    }
  }

  /// §1.2(c)：删任务时同事务删该任务未确认的草稿框
  /// （collect_task_id = ? AND question_id IS NULL）；已确认的框
  /// （question_id 已回填）随题保留，不删。页图目录的处理见 §4.5
  /// （P2 落盘后：页图可能还被已建的题引用，不能随任务删）。
  Future<void> deleteCollectTask(String id) async {
    final d = await db;
    await deleteCollectTaskFrom(d, id);
    bumpBadgeVersion();
  }

  /// §1.2(c)：删任务（可单测版）：一次事务，不 bump。事务提交后，
  /// 若没有任何题的 source_path / page_image_path 还指向该任务
  /// 目录（`imports/<taskId>/`），删整个任务目录；已确认拆题的
  /// 任务页图还被题引用，目录保留（§4.5）。
  static Future<void> deleteCollectTaskFrom(
      Database db, String id) async {
    await db.transaction((txn) async {
      await txn.delete('question_boxes',
          where: 'collect_task_id = ? AND question_id IS NULL',
          whereArgs: [id]);
      await txn.delete('collect_tasks', where: 'id = ?', whereArgs: [id]);
    });
    await _deleteTaskDirIfUnreferenced(db, id);
  }

  /// §4.5 文件级联：删库内文件（只删无引用文件）。
  /// - [rel] 是库内相对路径（如 `slices/<qid>.png`）；解析失败
  ///   （`..` 越界）或仍被任何题/任务引用 → 不删；
  /// - 文件删失败静默跳过（由孤儿清理兜底），不抛错、不回滚数据库。
  /// 宁留孤儿，不误删：孤儿只占空间，误删是丢数据。
  static Future<void> _deleteDataFileIfUnreferenced(
      Database db, String? rel) async {
    if (rel == null || rel.isEmpty) return;
    final abs = resolveDataPath(rel);
    if (abs == null) return;
    if (await _isFileReferenced(db, rel)) return;
    try {
      final f = File(abs);
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }

  static Future<bool> _isFileReferenced(Database db, String rel) async {
    for (final col in ['source_path', 'page_image_path', 'slice_path']) {
      final rows = await db.query('questions',
          columns: ['id'],
          where: '$col = ?',
          whereArgs: [rel],
          limit: 1);
      if (rows.isNotEmpty) return true;
    }
    final tasks = await db.query('collect_tasks',
        columns: ['id'],
        where: 'source_path = ?',
        whereArgs: [rel],
        limit: 1);
    return tasks.isNotEmpty;
  }

  /// §4.5：删任务目录（`imports/<taskId>/`）——仅当没有任何题的
  /// source_path / page_image_path 还指向该目录下时才删。
  static Future<void> _deleteTaskDirIfUnreferenced(
      Database db, String taskId) async {
    final prefix = 'imports/$taskId/';
    for (final col in ['source_path', 'page_image_path']) {
      final rows = await db.query('questions',
          columns: ['id'],
          where: '$col LIKE ?',
          whereArgs: ['$prefix%'],
          limit: 1);
      if (rows.isNotEmpty) return;
    }
    final abs = resolveDataPath('imports/$taskId');
    if (abs == null) return;
    try {
      final dir = Directory(abs);
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// 数据目录内的相对路径解析（`..` 越界返回 null，不许读盘）。
  static String? _resolveInsideDir(String dataDir, String rel) {
    if (p.isAbsolute(rel)) return null;
    final base = p.normalize(dataDir);
    final abs = p.normalize(p.join(base, rel.replaceAll('\\', '/')));
    if (abs != base && !abs.startsWith('$base${p.separator}')) return null;
    return abs;
  }

  /// 库内存的路径 → 数据目录内的 `/` 分隔相对路径；越界或库外
  /// 绝对路径返回 null（不是库管的文件，不参与备份/清理）。
  static String? _toDataRelative(String stored, String dataDir) {
    final base = p.normalize(dataDir);
    if (p.isAbsolute(stored)) {
      final abs = p.normalize(stored);
      if (!abs.startsWith('$base${p.separator}')) return null;
      return p.relative(abs, from: base).replaceAll('\\', '/');
    }
    final rel = stored.replaceAll('\\', '/');
    if (rel.startsWith('/')) return null;
    final abs = p.normalize(p.join(base, rel));
    if (abs != base && !abs.startsWith('$base${p.separator}')) return null;
    return p.relative(abs, from: base).replaceAll('\\', '/');
  }

  /// §4.5：库里引用到的全部文件相对路径（questions 的
  /// source_path / page_image_path / slice_path +
  /// collect_tasks 的 source_path）。
  static Future<Set<String>> _referencedRelativePaths(
      Database db, String dataDir) async {
    final refs = <String>{};
    void add(Object? v) {
      if (v is! String || v.isEmpty) return;
      final rel = _toDataRelative(v, dataDir);
      if (rel != null) refs.add(rel);
    }

    for (final row in await db.query('questions', columns: [
      'source_path',
      'page_image_path',
      'slice_path',
    ])) {
      add(row['source_path']);
      add(row['page_image_path']);
      add(row['slice_path']);
    }
    for (final row in
        await db.query('collect_tasks', columns: ['source_path'])) {
      add(row['source_path']);
    }
    return refs;
  }

  /// §4.5：孤儿文件清理入口的数据层 API。
  /// 扫描 `imports/` 与 `slices/`，列出“没有任何 questions /
  /// collect_tasks 行引用”的文件（只删无引用文件，不删在用文件；
  /// 空目录随文件删完后顺带清理）。清理前由调用方（设置页）向
  /// 用户预览将删文件与大小、确认后执行。
  static Future<OrphanScan> scanOrphanFilesFrom(Database db,
      {String? dataDir}) async {
    final dir = dataDir ?? dataDirectoryPath();
    final refs = await _referencedRelativePaths(db, dir);
    final found = <OrphanFile>[];
    for (final sub in ['imports', 'slices']) {
      final root = Directory(p.join(dir, sub));
      if (!root.existsSync()) continue;
      for (final e in root.listSync(recursive: true)) {
        if (e is! File) continue;
        final rel = p.relative(e.path, from: dir).replaceAll('\\', '/');
        if (refs.contains(rel)) continue;
        var size = 0;
        try {
          size = e.lengthSync();
        } catch (_) {}
        found.add(OrphanFile(relativePath: rel, bytes: size));
      }
    }
    found.sort((a, b) => a.relativePath.compareTo(b.relativePath));
    return OrphanScan(found);
  }

  /// 删指定的孤儿文件（只接受 `imports/` / `slices/` 下的相对路径，
  /// 且解析后必须在数据目录内；其它路径静默跳过）。删完把空的父
  /// 目录也清掉（只到 `imports/<taskId>` 这一层，不删根）。
  /// 返回实际删掉的文件数与释放字节数。
  static Future<({int deletedCount, int freedBytes})> deleteOrphanFiles(
      List<String> relativePaths,
      {String? dataDir}) async {
    final dir = dataDir ?? dataDirectoryPath();
    var deleted = 0;
    var freed = 0;
    final touchedParents = <Directory>[];
    for (final rel in relativePaths) {
      if (!rel.startsWith('imports/') && !rel.startsWith('slices/')) {
        continue;
      }
      final abs = _resolveInsideDir(dir, rel);
      if (abs == null) continue;
      final f = File(abs);
      if (!f.existsSync()) continue;
      try {
        freed += f.lengthSync();
        await f.delete();
        deleted++;
        touchedParents.add(f.parent);
      } catch (_) {}
    }
    for (final parent in touchedParents) {
      var d = parent;
      while (true) {
        final rel = p.relative(d.path, from: dir).replaceAll('\\', '/');
        if (rel == 'imports' || rel == 'slices') break;
        if (!rel.startsWith('imports/') && !rel.startsWith('slices/')) {
          break;
        }
        try {
          if (d.listSync().isEmpty) {
            await d.delete();
          } else {
            break;
          }
        } catch (_) {
          break;
        }
        d = d.parent;
      }
    }
    return (deletedCount: deleted, freedBytes: freed);
  }

  /// 孤儿扫描（实例版）：扫当前库。
  Future<OrphanScan> scanOrphans() async =>
      scanOrphanFilesFrom(await db);

  /// 孤儿清理（实例版）：删指定的孤儿文件。
  Future<({int deletedCount, int freedBytes})> cleanOrphans(
          List<String> relativePaths) async =>
      deleteOrphanFiles(relativePaths);

  // ---------- 框（question_boxes，§1.2(c)；P2 已接线） ----------

  static Map<String, Object?> _questionBoxToRow(QuestionBox b) => {
        'id': b.id,
        'collect_task_id': b.collectTaskId,
        'question_id': b.questionId,
        'parent_box_id': b.parentBoxId,
        'page': b.page,
        'layer': b.layer,
        'type': b.type,
        'x': b.x,
        'y': b.y,
        'w': b.w,
        'h': b.h,
        'confidence': b.confidence,
        'origin': b.origin,
        'updated_at': (b.updatedAt ?? DateTime.now())
            .millisecondsSinceEpoch,
      };

  static QuestionBox _questionBoxFromRow(Map<String, Object?> r) =>
      QuestionBox(
        id: r['id'] as String,
        collectTaskId: r['collect_task_id'] as String?,
        questionId: r['question_id'] as String?,
        parentBoxId: r['parent_box_id'] as String?,
        page: (r['page'] as int?) ?? 1,
        layer: (r['layer'] as int?) ?? 1,
        type: (r['type'] as String?) ?? 'question',
        x: (r['x'] as num).toDouble(),
        y: (r['y'] as num).toDouble(),
        w: (r['w'] as num).toDouble(),
        h: (r['h'] as num).toDouble(),
        confidence: (r['confidence'] as num?)?.toDouble(),
        origin: (r['origin'] as String?) ?? 'manual',
        updatedAt: r['updated_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
      );

  /// §8.1：写框（可单测版）：直接对传入的库句柄写，不碰单例、不 bump。
  /// id 规则见 §1.2(c)：`box-<taskId>-p<page>-<uuid8>`（调用方生成）。
  static Future<void> insertQuestionBoxInto(
      Database db, QuestionBox b) async {
    await db.insert('question_boxes', _questionBoxToRow(b));
  }

  /// §8.1：读某题的全部框（可单测版）。
  static Future<List<QuestionBox>> boxesForQuestionFrom(
      Database db, String questionId) async {
    final rows = await db.query('question_boxes',
        where: 'question_id = ?', whereArgs: [questionId]);
    return rows.map(_questionBoxFromRow).toList();
  }

  /// §1.5：读某任务的全部草稿框（各页，用于“继续修框”恢复）。
  static Future<List<QuestionBox>> boxesForTaskFrom(
      Database db, String taskId) async {
    final rows = await db.query('question_boxes',
        where: 'collect_task_id = ? AND question_id IS NULL',
        whereArgs: [taskId],
        orderBy: 'page ASC, id ASC');
    return rows.map(_questionBoxFromRow).toList();
  }

  /// §1.5：读某任务某页的草稿框。
  static Future<List<QuestionBox>> boxesForTaskPageFrom(
      Database db, String taskId, int page) async {
    final rows = await db.query('question_boxes',
        where: 'collect_task_id = ? AND page = ? AND question_id IS NULL',
        whereArgs: [taskId, page]);
    return rows.map(_questionBoxFromRow).toList();
  }

  /// §1.5.1：读同一页图上全部已确认题的框（重框同页上下文）：
  /// 分组键是 `questions.page_image_path`（确认后 collect_task_id
  /// 已是 NULL，不能靠任务分组）。返回该页各题的全部框（1 层 + 2 层）。
  static Future<List<QuestionBox>> boxesForPageImageFrom(
      Database db, String pageImagePath) async {
    final qs = await db.query('questions',
        columns: ['id'],
        where: 'page_image_path = ?',
        whereArgs: [pageImagePath]);
    if (qs.isEmpty) return const [];
    final ids = qs.map((r) => r['id'] as String).toList();
    final where = 'question_id IN (${List.filled(ids.length, '?').join(',')})';
    final rows = await db.query('question_boxes',
        where: where, whereArgs: ids);
    return rows.map(_questionBoxFromRow).toList();
  }

  /// §1.5：草稿保存（可单测版）：一次事务。
  /// - 按页替换：删该任务该页的草稿框，再插入当前页内存里的框
  ///   （1 层 + 2 层，2 层框的 parent_box_id 指向所属 1 层框）；
  /// - `rotations` 是草稿的全部按页旋转角度，一起写进
  ///   `collect_tasks.page_rotations`（§1.6.1）。
  /// 只动该任务该页的草稿框，已确认的题框一律不动。
  static Future<void> saveDraftBoxesInto(
    Database db, {
    required String taskId,
    required Map<int, List<QuestionBox>> boxesByPage,
    required Map<String, List<QuestionBox>> inners,
    required Map<int, List<QuestionBox>> standaloneInner,
    required Map<int, int> rotations,
  }) async {
    final pages = <int>{
      ...boxesByPage.keys,
      ...standaloneInner.keys,
    };
    await db.transaction((txn) async {
      for (final page in pages) {
        await txn.delete('question_boxes',
            where:
                'collect_task_id = ? AND page = ? AND question_id IS NULL',
            whereArgs: [taskId, page]);
        final flat = <QuestionBox>[
          ...?boxesByPage[page],
          for (final b in (boxesByPage[page] ?? const <QuestionBox>[]))
            ...?inners['$page:${b.id}'],
          ...?standaloneInner[page],
        ];
        for (final b in flat) {
          final row = _questionBoxToRow(b.copyWith(
            collectTaskId: taskId,
            page: page,
            clearQuestionId: true,
            updatedAt: DateTime.now(),
          ));
          await txn.insert('question_boxes', row,
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      await txn.update(
        'collect_tasks',
        {
          'page_rotations': jsonEncode({
            for (final e in rotations.entries) '${e.key}': e.value,
          }),
        },
        where: 'id = ?',
        whereArgs: [taskId],
      );
    });
  }

  /// §1.5：草稿保存（实例版）：直接调可单测版，不 bump
  /// （草稿保存不改变任务状态，角标不用刷新）。
  Future<void> saveDraftBoxes({
    required String taskId,
    required Map<int, List<QuestionBox>> boxesByPage,
    required Map<String, List<QuestionBox>> inners,
    required Map<int, List<QuestionBox>> standaloneInner,
    required Map<int, int> rotations,
  }) async {
    final d = await db;
    await saveDraftBoxesInto(d,
        taskId: taskId,
        boxesByPage: boxesByPage,
        inners: inners,
        standaloneInner: standaloneInner,
        rotations: rotations);
  }

  /// §1.5：读某任务的全部草稿框（实例版）。
  Future<List<QuestionBox>> boxesForTask(String taskId) async =>
      boxesForTaskFrom(await db, taskId);

  /// §1.5.1：读同一页图上全部已确认题的框（实例版）。
  Future<List<QuestionBox>> boxesForPageImage(String pageImagePath) async =>
      boxesForPageImageFrom(await db, pageImagePath);

  /// §1.5.1：详情页重框（可单测版）：一次事务，只动这一题——
  /// 删该题的旧框（先删子框再删本体）后插入新框（question_id 回填、
  /// collect_task_id 置空）。同页其他题的框与切片一律不动。
  static Future<void> replaceQuestionBoxesInto(
      Database db, String questionId, List<QuestionBox> boxes) async {
    await db.transaction((txn) async {
      await _deleteBoxesForQuestionTxn(txn, questionId);
      for (final b in boxes) {
        await txn.insert(
          'question_boxes',
          _questionBoxToRow(b.copyWith(
            questionId: questionId,
            clearCollectTaskId: true,
            updatedAt: DateTime.now(),
          )),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// §1.5.1：详情页重框（实例版）。
  Future<void> replaceQuestionBoxes(
      String questionId, List<QuestionBox> boxes) async {
    final d = await db;
    await replaceQuestionBoxesInto(d, questionId, boxes);
    bumpBadgeVersion();
  }

  /// 删某题的全部框（事务内）：先删子框（parent_box_id 指向该题
  /// 1 层框的行），再删该题的框。
  static Future<void> _deleteBoxesForQuestionTxn(
      Transaction txn, String questionId) async {
    final ownBoxes = await txn.query('question_boxes',
        columns: ['id'],
        where: 'question_id = ?',
        whereArgs: [questionId]);
    for (final row in ownBoxes) {
      await txn.delete('question_boxes',
          where: 'parent_box_id = ?', whereArgs: [row['id'] as String]);
    }
    await txn.delete('question_boxes',
        where: 'question_id = ?', whereArgs: [questionId]);
  }

  /// §1.5：确认拆题四步同事务（可单测版；切片写盘在事务**前**，
  /// 由调用方先写好，失败不写库）：
  /// 建题 + 回填 `question_boxes.question_id` + 建拆分任务 + 删原任务。
  /// 框的回填：先删该题已有的旧框（防重复确认/重检测产生两个
  /// layer = 1 框，partial unique 的防呆），再把传入的框逐行
  /// upsert（question_id 回填、collect_task_id 置空）。
  /// 拆分任务行同样写 source_path / created_at / page_count
  /// （§1.2(b)，调用方在 splitTasks 里给好）。
  static Future<void> confirmSplitInto(
    Database db, {
    required CollectTask originalTask,
    required List<Question> questions,
    required List<CollectTask> splitTasks,
    required Map<String, List<QuestionBox>> boxesByQuestionId,
  }) async {
    await db.transaction((txn) async {
      for (final q in questions) {
        await txn.insert('questions', _toRow(q),
            conflictAlgorithm: ConflictAlgorithm.replace);
        await _deleteBoxesForQuestionTxn(txn, q.id);
        for (final b in boxesByQuestionId[q.id] ?? const <QuestionBox>[]) {
          await txn.insert(
            'question_boxes',
            _questionBoxToRow(b.copyWith(
              questionId: q.id,
              clearCollectTaskId: true,
              updatedAt: DateTime.now(),
            )),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
      for (final t in splitTasks) {
        final values = _collectTaskToRow(t);
        await txn.insert('collect_tasks', {
          ...values,
          'created_at': t.createdAt?.millisecondsSinceEpoch ??
              DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      // 删原任务：残留的草稿框（本次没确认的页/删掉的框）随任务删，
      // 已回填 question_id 的框不受影响（见 deleteCollectTaskFrom）。
      await txn.delete('question_boxes',
          where: 'collect_task_id = ? AND question_id IS NULL',
          whereArgs: [originalTask.id]);
      await txn.delete('collect_tasks',
          where: 'id = ?', whereArgs: [originalTask.id]);
    });
  }

  /// §1.5：确认拆题（实例版）：事务提交后 bump 一次。
  Future<void> confirmSplit({
    required CollectTask originalTask,
    required List<Question> questions,
    required List<CollectTask> splitTasks,
    required Map<String, List<QuestionBox>> boxesByQuestionId,
  }) async {
    final d = await db;
    await confirmSplitInto(d,
        originalTask: originalTask,
        questions: questions,
        splitTasks: splitTasks,
        boxesByQuestionId: boxesByQuestionId);
    bumpBadgeVersion();
  }

  // ---------- 设置（settings 表） ----------

  Future<AppSettings> loadSettings() async {
    final d = await db;
    final rows = await d.query('settings');
    final map = {
      for (final r in rows) r['key'] as String: r['value'] as String
    };
    return AppSettings.fromMap(map);
  }

  Future<void> saveSetting(String key, String value) async {
    final d = await db;
    await d.insert('settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> saveSettings(AppSettings s) async {
    for (final e in s.toMap().entries) {
      await saveSetting(e.key, e.value);
    }
  }

  /// B3：上次停留的路由（启动页“上次停下的页面”用）。
  /// 复用 settings 表的 key/value（key `lastRoute`），不新开表、不加
  /// 字段、不碰 Schema；与 AppSettings.toMap 无关——saveSettings
  /// 只写已知键，不会误删它；loadSettings 的 fromMap 忽略未知键。
  static const String lastRouteKey = 'lastRoute';

  Future<String?> loadLastRoute() async {
    final d = await db;
    final rows = await d.query('settings',
        columns: ['value'], where: 'key = ?', whereArgs: [lastRouteKey]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> saveLastRoute(String route) async =>
      saveSetting(lastRouteKey, route);

  /// B4.1：今天是否已弹过复查提醒（`yyyy-MM-dd`，一天一次）。
  /// 与 lastRoute 同一做法：复用 settings 表 key/value，不新开表。
  static const String lastRecheckReminderKey = 'lastRecheckReminderDate';

  Future<String?> loadLastRecheckReminderDate() async {
    final d = await db;
    final rows = await d.query('settings',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: [lastRecheckReminderKey]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> saveLastRecheckReminderDate(String date) async =>
      saveSetting(lastRecheckReminderKey, date);

  /// 待定3：手动备份失败标志（首页红色横幅用）。
  /// 与 lastRoute 同一做法：复用 settings 表 key/value，不新开表、
  /// 不改 Schema。'1' = 有一次备份失败待提示，'0' / 无行 = 没有。
  /// 置标志：设置页 `_backup` 失败时；清标志：首页横幅点“知道了”，
  /// 或下一次备份成功时。
  static const String backupFailedKey = 'backupFailed';

  /// 待定3：读标志（可单测版，直接对传入的库句柄读，不碰单例）。
  static Future<bool> loadBackupFailedFrom(Database db) async {
    final rows = await db.query('settings',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: [backupFailedKey]);
    if (rows.isEmpty) return false;
    return (rows.first['value'] as String?) == '1';
  }

  /// 待定3：写标志（可单测版）。
  static Future<void> saveBackupFailedInto(Database db, bool failed) async {
    await db.insert('settings', {
      'key': backupFailedKey,
      'value': failed ? '1' : '0',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<bool> loadBackupFailed() async => loadBackupFailedFrom(await db);

  Future<void> saveBackupFailed(bool failed) async =>
      saveBackupFailedInto(await db, failed);

  /// B4.2：备份表清单（导出与恢复共用；恢复只插这里的表）。
  /// v2 共 13 张表：原 12 张 + §1.2(c) 的 question_boxes。
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
    'settings',
  ];

  /// 备份：把题库导出为 JSON 文本（恢复时校验后整体覆盖）。
  Future<String> exportBackupJson() async =>
      exportBackupJsonFrom(await db);

  /// B4.2：导出（可单测版）：直接对传入的库句柄导出，不碰单例。
  /// §4.4：用 dart:convert 的 jsonEncode（手写 _jsonValue 只转义了
  /// `\` / `"` / `\n`，漏 `\r` / `\t` / `\b` / `\f` 与其它控制字符，
  /// 含制表符或回车的笔记会导出非法 JSON、恢复不了）。
  /// §2.3：保持表名平铺在顶层，额外加 `_meta`
  /// {schemaVersion, appVersion, exportedAt}（先加后用）。
  static Future<String> exportBackupJsonFrom(Database db) async {
    final out = <String, dynamic>{
      '_meta': {
        'schemaVersion': schemaVersion,
        'appVersion': appVersion,
        'exportedAt': DateTime.now().millisecondsSinceEpoch,
      },
    };
    for (final t in backupTables) {
      out[t] = await db.query(t);
    }
    return jsonEncode(out);
  }

  /// §2.3：恢复前校验（纯校验，不动库；设置页选文件时先调它给即时
  /// 反馈，importBackupJsonInto 里再调一次，双保险）。
  /// 校验顺序：① `_meta.schemaVersion` 存在且为整数（缺失 → 按 v1
  /// 备份处理，拒绝：v1 从未发布、老库已删，不存在合法的 v1 备份）；
  /// ② `== 2` 才放行，`> 2` 拒绝（备份来自更新的版本），`< 2` 也拒绝；
  /// ③ 关键表齐全（subjects / questions 为数组）；④ 每行是对象、
  /// 主键列存在（各表 'id'，settings 是 'key'）。
  /// 任一步不过 → 抛 BackupRestoreException（带具体原因），
  /// 调用方一律不动原库。
  static void validateBackupData(Map<String, dynamic> data) {
    final meta = data['_meta'];
    if (meta is! Map) {
      throw BackupRestoreException(
          '这份备份没有版本信息，是旧版（v1）备份，新版不再支持恢复');
    }
    final sv = meta['schemaVersion'];
    if (sv is! int) {
      throw BackupRestoreException(
          '这份备份没有版本信息，是旧版（v1）备份，新版不再支持恢复');
    }
    if (sv > schemaVersion) {
      throw BackupRestoreException(
          '这份备份来自更新的版本（v$sv），请先更新应用再恢复');
    }
    if (sv != schemaVersion) {
      throw BackupRestoreException(
          '这份备份是旧版本（v$sv）的，新版不再支持恢复');
    }
    for (final keyTable in ['subjects', 'questions']) {
      if (data[keyTable] is! List) {
        throw BackupRestoreException('这份备份文件已损坏：缺少 $keyTable 表');
      }
    }
    for (final t in backupTables) {
      final rows = data[t];
      if (rows == null) continue; // 缺的表键按空表处理（清掉，不报错）
      if (rows is! List) {
        throw BackupRestoreException('这份备份文件已损坏：$t 表不是列表');
      }
      for (final row in rows) {
        if (row is! Map) {
          throw BackupRestoreException('这份备份文件已损坏：$t 表里有坏行');
        }
        if (!row.containsKey('id') && !row.containsKey('key')) {
          throw BackupRestoreException(
              '这份备份文件已损坏：$t 表里有行缺少主键');
        }
      }
    }
  }

  /// B4.2：恢复：整体覆盖——先校验（版本 + 关键表 + 行类型），
  /// 校验通过才清表再插回；校验不过一律不动原库。
  /// 清表/插表只按 backupTables 一份清单走（§2.3：删掉另一份手写
  /// 清单）；question_boxes 先清、随 questions 之后插（外键是逻辑
  /// 上的，没有声明 FK，顺序只是为可读性）。
  /// 恢复后 settings.schemaVersion 写回 2。
  Future<void> importBackupJson(Map<String, dynamic> data) async =>
      importBackupJsonInto(await db, data);

  /// B4.2：恢复（可单测版）。
  static Future<void> importBackupJsonInto(
      Database db, Map<String, dynamic> data) async {
    validateBackupData(data);
    final clearOrder = <String>[
      'question_boxes',
      ...backupTables.reversed.where((t) => t != 'question_boxes'),
    ];
    await db.transaction((txn) async {
      for (final t in clearOrder) {
        await txn.delete(t);
      }
      for (final t in backupTables) {
        final rows = data[t];
        if (rows is! List) continue;
        for (final row in rows) {
          if (row is! Map) continue;
          await txn.insert(
            t,
            Map<String, Object?>.from(row),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
      // §2.3：恢复后 settings.schemaVersion 写回 2（备份里的 settings
      // 行若缺这一键，在此补写；若有，也以 2 为准）。
      await txn.insert(
        'settings',
        {'key': 'schemaVersion', 'value': '$schemaVersion'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  /// §2.3/P3：zip 文件级备份（`backup.json` + `imports/` + `slices/`）。
  /// 只打包库里引用到的文件（questions 的 source_path /
  /// page_image_path / slice_path + collect_tasks 的 source_path）；
  /// 无引用的孤儿文件不进备份。缺文件（路径在库里、文件不在盘上）
  /// 不进包，恢复后该题走“图片缺失”，不静默造假文件。
  static Future<List<int>> exportBackupZipFrom(Database db,
      {String? dataDir}) async {
    final dir = dataDir ?? dataDirectoryPath();
    final json = await exportBackupJsonFrom(db);
    final entries = <ZipEntryData>[
      ZipEntryData('backup.json', utf8.encode(json)),
    ];
    final refs = await _referencedRelativePaths(db, dir);
    final sorted = refs.toList()..sort();
    for (final rel in sorted) {
      if (!rel.startsWith('imports/') && !rel.startsWith('slices/')) {
        continue;
      }
      final abs = _resolveInsideDir(dir, rel);
      if (abs == null) continue;
      final f = File(abs);
      if (!f.existsSync()) continue;
      entries.add(ZipEntryData(rel, await f.readAsBytes()));
    }
    return buildZip(entries);
  }

  /// zip 备份（实例版）。
  Future<List<int>> exportBackupZip() async =>
      exportBackupZipFrom(await db);

  static List<ZipEntryData> _readZipOrThrow(List<int> bytes) {
    try {
      return readZip(bytes);
    } on ZipFormatException catch (e) {
      throw BackupRestoreException('这份备份文件已损坏：${e.message}');
    }
  }

  static Map<String, dynamic> _decodeBackupJson(List<int> bytes) {
    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      throw BackupRestoreException('这份备份文件已损坏：题目数据不是合法 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw BackupRestoreException('这份备份文件已损坏：题目数据格式不对');
    }
    validateBackupData(decoded);
    return decoded;
  }

  /// §2.3/P3：从 zip 备份里读出 JSON（只读 `backup.json`，不解文件），
  /// 供设置页“选完文件先确认”时预览题数与版本校验。
  /// 不是 zip / 缺 backup.json / JSON 非法 / 版本校验不过 → 抛
  /// BackupRestoreException（带具体原因），原库不动。
  static Map<String, dynamic> readBackupJsonFromZip(List<int> bytes) {
    final entries = _readZipOrThrow(bytes);
    ZipEntryData? jsonEntry;
    for (final e in entries) {
      if (e.name == 'backup.json') jsonEntry = e;
    }
    if (jsonEntry == null) {
      throw BackupRestoreException('这份备份里没有题目数据（缺少 backup.json）');
    }
    return _decodeBackupJson(jsonEntry.bytes);
  }

  /// §2.3/P3：zip 备份恢复（JSON + 文件一起恢复，恢复即完整）。
  /// 1. 解包并校验每个条目路径（zip slip：任一条目非法 → 拒绝整个包，
  ///    见 zip_archive.dart；含 `imports/` / `slices/` 之外的文件
  ///    条目也拒绝）；
  /// 2. 先把文件解到 staging 目录（数据目录内的
  ///    `.restore-staging-<时间戳>`），再校验 backup.json；
  /// 3. 校验通过后：文件原子替换进位（先把被覆盖的原文件挪到
  ///    staging 的 `.overwritten/` 里），再走 [importBackupJsonInto]
  ///    整体覆盖数据库；
  /// 4. 任一步失败 → 删 staging、不动原库（数据库失败时已移入的
  ///    文件也从 `.overwritten/` 移回）；成功后删 staging。
  /// 老 JSON 备份（`.qm2backup` 但内容是 JSON）不走这里，走
  /// [importBackupJsonInto]（见设置页的魔数识别）。
  static Future<void> importBackupZipInto(Database db, List<int> bytes,
      {String? dataDir}) async {
    final dir = dataDir ?? dataDirectoryPath();
    final entries = _readZipOrThrow(bytes);
    ZipEntryData? jsonEntry;
    for (final e in entries) {
      if (e.name == 'backup.json') jsonEntry = e;
    }
    if (jsonEntry == null) {
      throw BackupRestoreException('这份备份里没有题目数据（缺少 backup.json）');
    }
    final data = _decodeBackupJson(jsonEntry.bytes);
    for (final e in entries) {
      if (e.name == 'backup.json') continue;
      if (!e.name.startsWith('imports/') &&
          !e.name.startsWith('slices/')) {
        throw BackupRestoreException('这份备份里有不支持的文件：${e.name}');
      }
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final staging = Directory(p.join(dir, '.restore-staging-$stamp'));
    final overwritten = Directory(p.join(staging.path, '.overwritten'));
    final movedIn = <String>[];
    final backedUp = <({String current, String backup})>[];
    try {
      // 上次崩溃残留的 staging（本次不是它）顺带清掉。
      try {
        for (final e in Directory(dir).listSync()) {
          if (e is Directory &&
              p.basename(e.path).startsWith('.restore-staging-')) {
            await e.delete(recursive: true);
          }
        }
      } catch (_) {}
      await staging.create(recursive: true);
      await overwritten.create(recursive: true);
      for (final e in entries) {
        if (e.name == 'backup.json') continue;
        final dest = File(p.join(staging.path, e.name));
        await dest.parent.create(recursive: true);
        await dest.writeAsBytes(e.bytes);
      }
      // 文件进位：原文件先挪到 .overwritten/，失败可移回。
      for (final e in entries) {
        if (e.name == 'backup.json') continue;
        final staged = File(p.join(staging.path, e.name));
        final destPath = _resolveInsideDir(dir, e.name);
        if (destPath == null) {
          throw BackupRestoreException('这份备份里有非法路径：${e.name}');
        }
        final dest = File(destPath);
        await dest.parent.create(recursive: true);
        if (dest.existsSync()) {
          final backup = File(p.join(overwritten.path, e.name));
          await backup.parent.create(recursive: true);
          await dest.rename(backup.path);
          backedUp.add((current: dest.path, backup: backup.path));
        }
        await staged.rename(dest.path);
        movedIn.add(dest.path);
      }
      // 数据库整体覆盖（事务内；失败抛错走下面的回滚）。
      await importBackupJsonInto(db, data);
    } catch (e) {
      for (final m in movedIn) {
        await _deletePathQuietly(m);
      }
      for (final b in backedUp.reversed) {
        try {
          if (File(b.backup).existsSync()) {
            await File(b.backup).rename(b.current);
          }
        } catch (_) {}
      }
      await _deleteDirQuietly(staging);
      if (e is BackupRestoreException) rethrow;
      throw BackupRestoreException('恢复失败：文件写不进去，原题库没动');
    }
    await _deleteDirQuietly(staging);
  }

  /// zip 备份恢复（实例版）。
  Future<void> importBackupZip(List<int> bytes) async =>
      importBackupZipInto(await db, bytes);

  /// zip 备份恢复（实例版，按文件路径读）。
  Future<void> importBackupZipFile(String path) async {
    final bytes = await File(path).readAsBytes();
    await importBackupZip(bytes);
  }

}
