// B4：database.dart 拆分——数据目录迁移：migrateDataFiles（staging + 原子替换 + 回滚）/ migrateToDirectory。
// 与 database.dart 同一库（part of），共享库私有成员；纯重构，行为不变。

part of 'database.dart';

/// §4.6：文件目录迁移核心（可单测版，不碰标记文件、不碰单例）。
/// 把源数据目录的库文件（`quiz-master2.db` + `-wal`/`-shm`）与
/// `imports/`、`slices/` 一起搬到目标目录。
///
/// 顺序（与 §4.6 定稿一致）：
/// 1. 先清上次崩溃残留的 `<目标>.staging-*` 目录（B2-5d，只清目标
///    旁边、名字严格匹配 `.<目标名>.staging-<纯数字时间戳>` 的目录，
///    其它一概不动），再把全部文件复制到目标旁的 staging 目录
///    （`<目标>.staging-<时间戳>`）；复制中途失败/取消 → 删
///    staging，目标原封不动；
/// 2. 复制完成并校验（文件数与总字节对得上）后，目标已有文件先
///    备份：库 → `quiz-master2.db.old-<时间戳>`，目录 →
///    `imports.old-<时间戳>` / `slices.old-<时间戳>`；
/// 3. 再把 staging 里的内容 `rename` 到目标位置（同盘 rename
///    是原子操作）；任一步失败 → 删掉已移过去的新文件、把 `.old`
///    移回，返回 failed；
/// 4. 成功后删 `.old` 备份与 staging，进度报到 1.0——除非
///    `keepBackups` 为 true：此时 `.old` 备份留给调用方，等提交
///    点（[AppDatabase.migrateToDirectory] 写标记文件）成功后再删；写标记
///    失败时调用方用 [outBackups]/[outMoved] 调
///    [AppDatabase.rollbackMigrationFiles] 把新位置复原（B2-5a），不留重复副本。
/// 标记文件（`db_location.txt`）不在这里写——实例方法
/// [AppDatabase.migrateToDirectory] 在这步成功后才写，标记是提交点。
/// `onProgress` 按已复制字节回调 0..1；`isCancelled` 返回 true
/// 时停在当前文件之后，删 staging，返回 cancelled。
///
/// B2-5b（已知边界，未修）：目标只有孤儿文件、没有库时，
/// `overwrite=false` 下 staging 的 `rename` 会因目标目录已存在
/// 而失败，返回 failed，目标原封不动、无数据丢失。未做“跳过已
/// 存在文件”的合并式迁移——方案只定了覆盖/保留/取消三选一，未定
/// 合并口径；且只改这里也到不了覆盖对话框（设置页的对话框由
/// `databaseExistsAt` 触发，只认库文件），见 B2 报告。
Future<DbMigrationOutcome> migrateDataFilesImpl(
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
}) async {
  final src = p.normalize(sourceDir);
  final dst = p.normalize(targetDir);
  // B2-5d：先清上次崩溃残留的 staging 目录（只清严格匹配的，
  // 失败静默跳过，不阻塞本次迁移）。
  await _deleteStaleMigrationStaging(dst);
  if (p.equals(src, dst)) return DbMigrationOutcome.sameLocation;
  if (!overwrite && AppDatabase.databaseExistsAt(dst)) {
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

  for (final name in [
    'quiz-master2.db',
    'quiz-master2.db-wal',
    'quiz-master2.db-shm',
  ]) {
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
  final staging = Directory(
    p.join(p.dirname(dst), '.${p.basename(dst)}.staging-$stamp'),
  );
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
      onProgress?.call(
        totalBytes <= 0 ? 1.0 : (copiedBytes / totalBytes).clamp(0.0, 1.0),
      );
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
            final backup = p.join(dst, 'quiz-master2.db$suffix.old-$stamp');
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
      for (final name in [
        'quiz-master2.db',
        'quiz-master2.db-wal',
        'quiz-master2.db-shm',
      ]) {
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
      await AppDatabase.rollbackMigrationFiles(moved, backups);
      await _deleteDirQuietly(staging);
      return DbMigrationOutcome.failed;
    }
    // 成功：删 .old 备份与 staging。keepBackups 时 .old 留给调用方
    // 在提交点成功后再删（B2-5a），这里只把路径报出去。
    if (keepBackups) {
      outBackups?.addAll(backups);
      outMoved?.addAll(moved);
    } else {
      for (final b in backups) {
        await _deletePathQuietly(b.backup);
      }
    }
    await _deleteDirQuietly(staging);
    onProgress?.call(1.0);
    return DbMigrationOutcome.migrated;
  } catch (_) {
    await _deleteDirQuietly(staging);
    return DbMigrationOutcome.failed;
  }
}

/// B2-5a：迁移回滚（新位置复原）：删掉刚移入的新文件，把 `.old`
/// 备份移回原位。替换中途失败与写标记失败共用同一份回滚。
Future<void> rollbackMigrationFilesImpl(
  List<String> moved,
  List<({String current, String backup})> backups,
) async {
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
}

/// B2-5d：清掉上次崩溃残留的迁移 staging 目录。只删目标旁边、
/// 名字严格匹配 `.<目标名>.staging-<纯数字时间戳>` 的目录（时间戳
/// 是 `millisecondsSinceEpoch`，只含数字；形如
/// `.<目标名>.staging-backup` 的名字一概不动）；其它位置、其它
/// 名字、文件一概不动。失败静默跳过，不阻塞本次迁移。
Future<void> _deleteStaleMigrationStaging(String targetDir) async {
  try {
    final dst = p.normalize(targetDir);
    final parent = Directory(p.dirname(dst));
    if (!parent.existsSync()) return;
    final prefix = '.${p.basename(dst)}.staging-';
    for (final e in parent.listSync()) {
      if (e is! Directory) continue;
      final name = p.basename(e.path);
      if (!name.startsWith(prefix)) continue;
      if (!RegExp(r'^\d+$').hasMatch(name.substring(prefix.length))) {
        continue;
      }
      await _deleteDirQuietly(e);
    }
  } catch (_) {}
}

Future<void> _deleteDirQuietly(Directory dir) async {
  try {
    if (dir.existsSync()) await dir.delete(recursive: true);
  } catch (_) {}
}

Future<void> _deletePathQuietly(String path) async {
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

extension AppDatabaseStorage on AppDatabase {
  /// B4.3/§4.6：切换数据库位置并迁移旧库与文件目录。
  /// 顺序：先关当前库 → [AppDatabase.migrateDataFiles] 搬库文件 + `imports/` +
  /// `slices/`（staging + 原子替换，失败回滚；`.old` 备份保留到标记
  /// 写成功后才删）→ 最后写标记文件（标记是提交点：写标记前失败，
  /// 旧库与旧标记都原地不动）。写标记失败时新位置复原（B2-5a：
  /// 删刚移入的文件、`.old` 移回），不留重复副本。
  /// 复制成功后把 `databaseLocation` 写进新库（新库已存在，打开不
  /// 会触发建库播种；写失败也不影响——标记文件才是依据）。
  /// 调用方：目标已有库时先问用户，`overwrite` 按用户选择传
  /// （覆盖 / 保留 / 取消；文件目录沿用同一选择）。
  /// `onProgress` / `isCancelled` 见 [AppDatabase.migrateDataFiles]（大目录
  /// 复制进度 / 取消）。
  Future<DbMigrationOutcome> migrateToDirectory(
    String dir, {
    bool overwrite = false,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final currentDir = p.dirname(
      dbPathUsed ?? p.join(AppDatabase.dataDirectoryPath(), 'quiz-master2.db'),
    );
    final sourcePath = p.join(currentDir, 'quiz-master2.db');
    if (p.equals(p.normalize(currentDir), p.normalize(dir))) {
      return DbMigrationOutcome.sameLocation;
    }
    if (!overwrite && AppDatabase.databaseExistsAt(dir)) {
      return DbMigrationOutcome.targetExists;
    }
    final hadSource = File(sourcePath).existsSync();
    final targetExisted = Directory(dir).existsSync();
    try {
      await _db?.close();
    } catch (_) {}
    _db = null;
    _dbFuture = null;
    // B2-5a：.old 备份先保留，等标记写成功后再删；写标记失败时回滚。
    final backups = <({String current, String backup})>[];
    final moved = <String>[];
    final outcome = await AppDatabase.migrateDataFiles(
      currentDir,
      dir,
      overwrite: overwrite,
      onProgress: onProgress,
      isCancelled: isCancelled,
      keepBackups: true,
      outBackups: backups,
      outMoved: moved,
    );
    if (outcome != DbMigrationOutcome.migrated) return outcome;
    final def = AppDatabase.testMarkerDirectory ?? _defaultDataDirectoryPath();
    try {
      await Directory(def).create(recursive: true);
      await File(p.join(def, 'db_location.txt')).writeAsString(dir);
    } catch (_) {
      // 标记写失败：新位置复原，不留重复副本；旧位置与旧标记原地不动。
      await AppDatabase.rollbackMigrationFiles(moved, backups);
      if (!targetExisted) {
        // 目标目录是本次新建的、回滚后已空，顺手删掉（非空删不掉，不强求）。
        try {
          await Directory(dir).delete();
        } catch (_) {}
      }
      return DbMigrationOutcome.failed;
    }
    // 标记已确认写好：.old 备份可以删了。
    for (final b in backups) {
      await _deletePathQuietly(b.backup);
    }
    try {
      await saveSetting('databaseLocation', dir);
    } catch (_) {}
    return hadSource
        ? DbMigrationOutcome.migrated
        : DbMigrationOutcome.noSourceDb;
  }
}
