// B4：database.dart 拆分——孤儿文件扫描与清理。
// 与 database.dart 同一库（part of），共享库私有成员；纯重构，行为不变。

part of 'database.dart';

/// §4.5：库里引用到的全部文件相对路径（questions 的
/// source_path / page_image_path / slice_path +
/// collect_tasks 的 source_path），外加存续收集任务的派生文件。
///
/// SR-P0-1：未拆分任务的派生文件没有任何行引用——PDF 任务渲染出的
/// 页图在 `imports/<taskId>/pages/`、图片任务的 EXIF 归一化副本在
/// `imports/<taskId>/page-normalized.png`，而任务行的 source_path
/// 只是 `imports/<taskId>/original.*`。旧口径会把这些页图列为孤儿，
/// 设置页一键清理即删掉它们，修框页又无重新渲染入口，任务只能删掉
/// 重导。故按任务 id 把这两类也算作被引用（只保这两类：任务目录里
/// 的其它杂文件仍按孤儿处理）。
/// 附带：同一口径也被 zip 备份共用（db_backup.dart），修后未拆分
/// 任务的页图也会进备份，恢复后任务不再丢页图。
///
/// B2 第 2 阶段（B-NEW-15）：`imports/<taskId>/original.*` 也受保护——
/// 只要 collect_tasks 里存在该 taskId 的任务行，即使其 source_path
/// 暂时为空（原始文件刚落盘、source_path 还没来得及持久化的崩溃
/// 窗口），该原始输入文件也不得判定为孤儿、不得被一键清理删除。
/// 实现按任务目录枚举现存的 `original.*` 文件（不按 source_path
/// 猜扩展名、不挑选候选：扫描只做保护，不做恢复定位）。
Future<Set<String>> _referencedRelativePaths(
  QuizDatabase db,
  String dataDir,
) async {
  final refs = <String>{};
  void add(Object? v) {
    if (v is! String || v.isEmpty) return;
    final rel = _toDataRelative(v, dataDir);
    if (rel != null) refs.add(rel);
  }

  // B2 集成：questions 三列读走 Drift 类型化（原 SELECT
  // source_path, page_image_path, slice_path FROM questions）。
  for (final row in await db.select(db.questions).get()) {
    add(row.sourcePath);
    add(row.pageImagePath);
    add(row.slicePath);
  }
  for (final row in await db.select(db.collectTasks).get()) {
    add(row.sourcePath);
    final taskId = row.id;
    // 任务 id 是应用生成的目录名；含分隔符即不合法，跳过派生口径，
    // 防止 p.join 被带出 imports/<taskId>/。
    if (taskId.isEmpty || taskId.contains('/') || taskId.contains('\\')) {
      continue;
    }
    add('imports/$taskId/page-normalized.png');
    // B-NEW-15：任务行存在即保护其原始输入文件。枚举任务目录里
    // 现存的 original.*（source_path 为空的崩溃窗口也保得住；
    // 多个候选全保护，不挑选、不删除——恢复定位的多候选异常
    // 处理在导入/重试入口，不在扫描里做）。
    final taskDir = Directory(p.join(dataDir, 'imports', taskId));
    if (taskDir.existsSync()) {
      for (final e in taskDir.listSync()) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        if (name == 'original' || name.startsWith('original.')) {
          add(p.relative(e.path, from: dataDir));
        }
      }
    }
    final pagesDir = Directory(p.join(dataDir, 'imports', taskId, 'pages'));
    if (!pagesDir.existsSync()) continue;
    for (final e in pagesDir.listSync()) {
      if (e is! File) continue;
      add(p.relative(e.path, from: dataDir));
    }
  }
  return refs;
}

/// §4.5：孤儿文件清理入口的数据层 API。
/// 扫描 `imports/` 与 `slices/`，列出“没有任何 questions /
/// collect_tasks 行引用”的文件（只删无引用文件，不删在用文件；
/// 空目录随文件删完后顺带清理）。清理前由调用方（设置页）向
/// 用户预览将删文件与大小、确认后执行。
Future<OrphanScan> scanOrphanFilesFromImpl(
  QuizDatabase db, {
  String? dataDir,
}) async {
  final dir = dataDir ?? AppDatabase.dataDirectoryPath();
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
Future<({int deletedCount, int freedBytes})> deleteOrphanFilesImpl(
  List<String> relativePaths, {
  String? dataDir,
}) async {
  final dir = dataDir ?? AppDatabase.dataDirectoryPath();
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

extension AppDatabaseOrphans on AppDatabase {
  /// 孤儿扫描（实例版）：扫当前库。
  Future<OrphanScan> scanOrphans() async =>
      AppDatabase.scanOrphanFilesFrom(await db);

  /// 孤儿清理（实例版）：删指定的孤儿文件。
  Future<({int deletedCount, int freedBytes})> cleanOrphans(
    List<String> relativePaths,
  ) async => AppDatabase.deleteOrphanFiles(relativePaths);
}
