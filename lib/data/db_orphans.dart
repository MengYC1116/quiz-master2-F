// B4：database.dart 拆分——孤儿文件扫描与清理。
// 与 database.dart 同一库（part of），共享库私有成员；纯重构，行为不变。

part of 'database.dart';

/// 十四批 M2：从 `questions.ocr_figures` JSON 文本里提取全部图块
/// 的 `crop_path`（相对路径）。非法/空 JSON → 空集（不抛错）。
/// 同一库内共用：孤儿引用集合与删除引用检查都走这里，图块裁图
/// 才不会被误判为孤儿删掉。
Set<String> _figureCropPathsFromJson(String? ocrFiguresJson) {
  final paths = <String>{};
  if (ocrFiguresJson == null || ocrFiguresJson.isEmpty) return paths;
  try {
    final decoded = jsonDecode(ocrFiguresJson);
    if (decoded is List) {
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          final crop = item['crop_path'];
          if (crop is String && crop.isNotEmpty) paths.add(crop);
        }
      }
    }
  } catch (_) {
    // 非法 JSON 按无图块计（旧数据/手写坏值不阻断清理）。
  }
  return paths;
}

/// WP-C #8 U3-2：`ocr_figures` JSON 是否“引用未知”。
/// 非空字符串解不出“Map 列表、且 crop_path 若在必为字符串”即未知——
/// 此时无法证明已枚举全部图块裁图，调用方必须按“引用未知”处理、
/// 永不删除相关文件（与上面静默空集的旧口径相反）。
/// 空 / null = 明确无图块，不算未知；`[]` = 明确空列表，不算未知。
bool _ocrFiguresJsonIsUnknown(String? ocrFiguresJson) {
  if (ocrFiguresJson == null || ocrFiguresJson.isEmpty) return false;
  try {
    final decoded = jsonDecode(ocrFiguresJson);
    if (decoded is! List) return true;
    for (final item in decoded) {
      if (item is! Map) return true;
      if (item.containsKey('crop_path') && item['crop_path'] is! String) {
        return true;
      }
    }
    return false;
  } catch (_) {
    return true;
  }
}

/// WP-C #8 U3-2：任一题的 `ocr_figures` JSON 无法解析 → 全库图块
/// 引用未知。删题级联、孤儿清理、启动清扫都以此为 fail-closed 开关。
Future<bool> _hasUnknownFigureRefs(QuizDatabase db) async {
  for (final row in await db.select(db.questions).get()) {
    if (_ocrFiguresJsonIsUnknown(row.ocrFigures)) return true;
  }
  return false;
}

/// WP-C #8 U3-2：某题的 `ocrFigures` JSON 是否未知（删题前快照用）。
/// 删题是“先删库行、后删文件”：行删后全库扫描已查不到被删行本身的
/// 未知 JSON，故调用方须在事务前先算好、经
/// [_deleteDataFileIfUnreferenced] 的 `unknownFigureRefsBeforeDelete`
/// 参数传进来；行不存在时返回 false。
Future<bool> _ocrFiguresUnknownOf(
  QuizDatabase db,
  String questionId,
) async {
  final row =
      await (db.select(
        db.questions,
      )..where((t) => t.id.equals(questionId))).getSingleOrNull();
  if (row == null) return false;
  return _ocrFiguresJsonIsUnknown(row.ocrFigures);
}

// ------------------------------------------------------------------
// WP-C #8 U3-2：回收站。
//
// 删除分两步：引用检查与“移入回收站”在文件守门内完成；物理删除只在
// 启动清扫（[sweepTrashImpl]）时执行。位置在数据目录内 `.trash/`，
// 清单 `.trash/manifest.json` 记每条的 trash 文件名、原相对路径与
// 移入时间戳。
// - 不被孤儿扫描计入：扫描只列 `imports/` 与 `slices/`；
// - 不进备份：备份只打包 `_referencedRelativePaths` 产出的
//   `imports/` / `slices/` 引用，回收站路径从不出现在引用集里；
// - 清单损坏 / 无法解析 → 全部留下、记日志、永不删除（fail-closed）；
// - 盘上有、清单里无的条目（移入与写清单之间崩溃）→ 留下、记日志；
// - 清单里有、盘上无的条目 → 删清单条目、记日志。
// 已知局限：回收站占用不计入 `_dataDirFileUsageBytes` 的 2GB 口径
// （该函数只数 `imports/` + `slices/`）；7 天内不释放空间是设计内
// 行为，设置页文案已明示。
// ------------------------------------------------------------------

/// 回收站目录名（数据目录内）。
const String _trashDirName = '.trash';

/// 回收站清单文件名（回收站目录内）。
const String _trashManifestName = 'manifest.json';

/// 回收站保留天数：移入超过 7 天（严格大于）才有资格被清扫物理删除。
const int _trashRetentionDays = 7;

/// 启动清扫回收站的结果。
typedef TrashSweepResult = ({
  int deletedCount,
  int freedBytes,
  int keptReferencedCount,
  int keptUnknownCount,
});

/// 回收站清单条目（内部表示）。
typedef _TrashEntry = ({
  String trashName,
  String originalRel,
  int movedAtMs,
});

int _trashRand() => DateTime.now().microsecondsSinceEpoch % (1 << 32);

/// 读清单：文件不存在 → 空清单；解析失败 / 结构不对 → null（损坏）。
/// 调用方见 null 必须按 fail-closed 处理（全部留下），不得当成空清单。
List<_TrashEntry>? _readTrashManifest(Directory trashDir) {
  final f = File(p.join(trashDir.path, _trashManifestName));
  if (!f.existsSync()) return [];
  try {
    final decoded = jsonDecode(f.readAsStringSync());
    if (decoded is! Map<String, Object?>) return null;
    final raw = decoded['entries'];
    if (raw is! List) return null;
    final entries = <_TrashEntry>[];
    for (final item in raw) {
      if (item is! Map<String, Object?>) return null;
      final trashName = item['trashName'];
      final originalRel = item['originalRel'];
      final movedAtMs = item['movedAtMs'];
      if (trashName is! String ||
          originalRel is! String ||
          movedAtMs is! int) {
        return null;
      }
      entries.add((
        trashName: trashName,
        originalRel: originalRel,
        movedAtMs: movedAtMs,
      ));
    }
    return entries;
  } catch (_) {
    return null;
  }
}

/// 写清单：先写临时文件再改名（同目录原子替换），不直接覆盖。
void _writeTrashManifest(Directory trashDir, List<_TrashEntry> entries) {
  final tmp = File(p.join(trashDir.path, '.$_trashManifestName.tmp'));
  tmp.writeAsStringSync(
    jsonEncode({
      'entries': [
        for (final e in entries)
          {
            'trashName': e.trashName,
            'originalRel': e.originalRel,
            'movedAtMs': e.movedAtMs,
          },
      ],
    }),
  );
  tmp.renameSync(p.join(trashDir.path, _trashManifestName));
}

/// 锁内把单个文件移入回收站（调用者已持锁）。
/// 返回 true = 已移入并记入清单；false = 未移入（文件原地保留）。
/// 清单损坏时拒绝移入（文件原地保留，记日志）；清单写失败时文件已在
/// 回收站、清单里无记录——清扫时按未知处理、永不删除，只记日志。
Future<bool> _moveFileToTrashLocked({
  required String dataDir,
  required File file,
  required String originalRel,
}) async {
  FileLifecycleGuard.instance.requireLocked();
  final trashDir = Directory(p.join(dataDir, _trashDirName));
  try {
    await trashDir.create(recursive: true);
  } catch (_) {
    return false;
  }
  final entries = _readTrashManifest(trashDir);
  if (entries == null) {
    debugPrint('U3-2 回收站：清单损坏，拒绝移入 $originalRel（文件原地保留）');
    return false;
  }
  final movedAtMs = DateTime.now().millisecondsSinceEpoch;
  final trashName =
      '$movedAtMs-${_trashRand()}-${p.basename(file.path)}';
  try {
    await file.rename(p.join(trashDir.path, trashName));
  } catch (_) {
    return false;
  }
  entries.add((
    trashName: trashName,
    originalRel: originalRel,
    movedAtMs: movedAtMs,
  ));
  try {
    _writeTrashManifest(trashDir, entries);
  } catch (_) {
    debugPrint(
      'U3-2 回收站：清单写入失败，$originalRel 已移入但未登记，清扫时按未知保留',
    );
  }
  return true;
}

/// 锁内把整个目录移入回收站（调用者已持锁；任务目录删除用）。
/// [originalRel] 记 `imports/<taskId>/`（带尾斜杠，标明是目录条目）。
/// 返回值语义同 [_moveFileToTrashLocked]。
Future<bool> _moveDirectoryToTrashLocked({
  required String dataDir,
  required Directory dir,
  required String originalRel,
}) async {
  FileLifecycleGuard.instance.requireLocked();
  final trashDir = Directory(p.join(dataDir, _trashDirName));
  try {
    await trashDir.create(recursive: true);
  } catch (_) {
    return false;
  }
  final entries = _readTrashManifest(trashDir);
  if (entries == null) {
    debugPrint('U3-2 回收站：清单损坏，拒绝移入 $originalRel（目录原地保留）');
    return false;
  }
  final movedAtMs = DateTime.now().millisecondsSinceEpoch;
  final trashName =
      '$movedAtMs-${_trashRand()}-${p.basename(dir.path)}';
  try {
    await dir.rename(p.join(trashDir.path, trashName));
  } catch (_) {
    return false;
  }
  entries.add((
    trashName: trashName,
    originalRel: originalRel,
    movedAtMs: movedAtMs,
  ));
  try {
    _writeTrashManifest(trashDir, entries);
  } catch (_) {
    debugPrint(
      'U3-2 回收站：清单写入失败，$originalRel 已移入但未登记，清扫时按未知保留',
    );
  }
  return true;
}

/// WP-C #8 U3-2：启动清扫回收站（开库后、best-effort，见 `_openDb`）。
/// 只删移入超过 7 天的条目；清扫时按原相对路径重新查引用——文件用
/// [_isFileReferenced]（含“引用未知”fail-closed：`slices/` 路径在
/// ocrFigures JSON 无法解析时一律视为被引用），任务目录用
/// [_isTaskDirReferenced]；仍有引用 → 留下并记日志。
/// 任何一步失败都不抛错（调用方 `_openDb` 另有 try/catch 兜底），
/// 失败只记日志、留待下次启动再清。
Future<TrashSweepResult> sweepTrashImpl(
  QuizDatabase db, {
  String? dataDir,
}) async {
  final dir = dataDir ?? AppDatabase.dataDirectoryPath();
  final guard = FileLifecycleGuard.instance;
  return guard.withLock(() async {
    var deleted = 0;
    var freed = 0;
    var keptReferenced = 0;
    var keptUnknown = 0;
    final trashDir = Directory(p.join(dir, _trashDirName));
    if (!trashDir.existsSync()) {
      return (
        deletedCount: deleted,
        freedBytes: freed,
        keptReferencedCount: keptReferenced,
        keptUnknownCount: keptUnknown,
      );
    }
    final entries = _readTrashManifest(trashDir);
    if (entries == null) {
      // 清单损坏：盘上条目数不清原路径，全部留下、永不删除。
      var count = 0;
      try {
        for (final e in trashDir.listSync()) {
          if (e.path.endsWith(_trashManifestName)) continue;
          count++;
        }
      } catch (_) {}
      debugPrint(
        'U3-2 回收站：清单损坏，$count 个条目全部留下，永不删除',
      );
      return (
        deletedCount: deleted,
        freedBytes: freed,
        keptReferencedCount: keptReferenced,
        keptUnknownCount: count,
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final cutoff =
        now - _trashRetentionDays * 24 * 3600 * 1000;
    // 盘上有、清单里无的条目：移入与写清单之间崩溃的残留，原路径
    // 未知 → 留下、记日志，永不删除。
    final knownNames = entries.map((e) => e.trashName).toSet();
    try {
      for (final e in trashDir.listSync()) {
        final name = p.basename(e.path);
        if (name == _trashManifestName ||
            name == '.$_trashManifestName.tmp') {
          continue;
        }
        if (!knownNames.contains(name)) {
          keptUnknown++;
          debugPrint('U3-2 回收站：清单外条目 $name 原路径未知，留下不删');
        }
      }
    } catch (_) {}
    var manifestChanged = false;
    // Win11 后续修复 Round 3（Q4，§1.9）：清扫复查用的完整引用集
    // （_referencedRelativePaths 口径，含派生构造路径），只在首次
    // 需要时算一次；见下面文件条目分支。
    Set<String>? sweepRefs;
    for (final entry in List.of(entries)) {
      final trashPath = p.join(trashDir.path, entry.trashName);
      final type = FileSystemEntity.typeSync(trashPath);
      if (type == FileSystemEntityType.notFound) {
        // 清单里有、盘上无：删清单条目、记日志。
        entries.remove(entry);
        manifestChanged = true;
        debugPrint('U3-2 回收站：清单条目 ${entry.originalRel} 的文件已不在，删清单记录');
        continue;
      }
      if (entry.movedAtMs >= cutoff) continue; // 未满 7 天，留下。
      // 已满 7 天：重新查引用，仍有引用 → 留下。
      final isDirEntry = entry.originalRel.endsWith('/');
      var referenced = false;
      if (isDirEntry) {
        final taskId = entry.originalRel
            .split('/')
            .where((s) => s.isNotEmpty)
            .last;
        referenced = await _isTaskDirReferenced(db, taskId);
        if (!referenced) {
          final prefix = 'imports/$taskId/';
          final inFlight = [
            ...guard.pendingSnapshot,
            ...guard.stagingSnapshot,
          ].any((r) => r.startsWith(prefix));
          if (inFlight) referenced = true;
        }
      } else {
        // U3-2：引用未知时 slices/ 条目按“未知”计、留下（与“仍有引用”
        // 区分计数；_isFileReferenced 内同样会拦下它，这里只为计数准确）。
        if (entry.originalRel.startsWith('slices/') &&
            await _hasUnknownFigureRefs(db)) {
          keptUnknown++;
          debugPrint(
            'U3-2 引用未知：ocrFigures JSON 无法解析，${entry.originalRel} 留下不删',
          );
          continue;
        }
        referenced = await _isFileReferenced(db, entry.originalRel);
        // Q4（§1.9）：清扫的文件条目也走 _referencedRelativePaths
        // 口径复查——_isFileReferenced 不含派生构造路径（如任务行仍
        // 在时的 `imports/<taskId>/page-normalized.png`），只用它复
        // 查会把已在回收站里、任务行仍在的归一化副本满 7 天即物理
        // 删除（到达该状态的前提是它先被移入回收站；D2/D3 在行存在
        // 时不会移它，行复活场景才碰得到，低严重度，顺手修掉）。
        if (!referenced) {
          final refs = sweepRefs ??= await _referencedRelativePaths(db, dir);
          if (refs.contains(entry.originalRel)) referenced = true;
        }
        if (!referenced &&
            (guard.isPending(entry.originalRel) ||
                guard.isStaged(entry.originalRel))) {
          referenced = true;
        }
      }
      if (referenced) {
        keptReferenced++;
        debugPrint('U3-2 回收站：${entry.originalRel} 仍有引用，留下不删');
        continue;
      }
      // 无引用：物理删除（已持锁，走内部删除）。
      var size = 0;
      try {
        if (type == FileSystemEntityType.directory) {
          for (final e in Directory(
            trashPath,
          ).listSync(recursive: true)) {
            if (e is File) {
              try {
                size += e.lengthSync();
              } catch (_) {}
            }
          }
          await guard.deleteDirectoryLocked(Directory(trashPath));
        } else {
          try {
            size = File(trashPath).lengthSync();
          } catch (_) {}
          final ok =
              await guard.deleteFileLocked(File(trashPath));
          if (!ok) continue;
        }
      } catch (_) {
        continue;
      }
      freed += size;
      deleted++;
      entries.remove(entry);
      manifestChanged = true;
    }
    if (manifestChanged) {
      try {
        _writeTrashManifest(trashDir, entries);
      } catch (_) {
        debugPrint('U3-2 回收站：清扫后清单写回失败，下次启动再清');
      }
    }
    return (
      deletedCount: deleted,
      freedBytes: freed,
      keptReferencedCount: keptReferenced,
      keptUnknownCount: keptUnknown,
    );
  });
}

/// 十四批 M2：某题的全部图块裁图相对路径（删题后逐个重查引用再删
/// 时用；与 [_figureCropPathsFromJson] 同口径）。
Future<List<String>> _figureCropPathsOf(
  QuizDatabase db,
  String questionId,
) async {
  final row = await (db.select(
    db.questions,
  )..where((t) => t.id.equals(questionId))).getSingleOrNull();
  if (row == null) return const [];
  return _figureCropPathsFromJson(row.ocrFigures).toList();
}

/// 十四批 M5 修复轮 2（B-FIX2-1）：库行直接引用的全部文件相对路径
/// （questions 的 source_path / page_image_path / slice_path +
/// ocr_figures JSON 里的全部 crop_path + collect_tasks 的 source_path +
/// ocr_jobs 的 crop_path）。**唯一口径来源**：孤儿扫描
/// ([_referencedRelativePaths]) 在此集合之外另加派生保护；备份恢复
/// 复核 ([_missingReferencedFiles]) 直接复用本函数再逐个查存在性；
/// 两处不再各写一份列清单，避免口径漂移。
/// 注意：本函数不含派生保护（任务的 page-normalized.png、pages/ 下
/// 页图、original.*）——那些是“有行即保护、文件本身未必存在”，
/// 只用于“能不能删 / 进不进备份”，不能用于“文件缺了没有”的存在性
/// 复核（见 [_missingReferencedFiles] 的注释）。
Future<Set<String>> _directlyReferencedRelativePaths(
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
  // 十四批 M2：ocr_figures JSON 里的全部 crop_path 也算被引用——
  // 不加这路，图块裁图会被孤儿扫描误判、也不会进 zip 备份。
  for (final row in await db.select(db.questions).get()) {
    add(row.sourcePath);
    add(row.pageImagePath);
    add(row.slicePath);
    for (final crop in _figureCropPathsFromJson(row.ocrFigures)) {
      add(crop);
    }
  }
  // 十三批 M2：ocr_jobs 的 crop_path 也是被引用的切片文件——
  // 不加这路，crop 指向的切片会被孤儿扫描误删、也不会进 zip 备份
  //（crop 通常就是 questions.slice_path 同一文件，此时是去重后的同一条）。
  for (final row in await db.select(db.ocrJobs).get()) {
    add(row.cropPath);
  }
  for (final row in await db.select(db.collectTasks).get()) {
    add(row.sourcePath);
  }
  return refs;
}

/// §4.5：库里引用到的全部文件相对路径 = 行直接引用
/// ([_directlyReferencedRelativePaths]) + 存续收集任务的派生文件。
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
  final refs = await _directlyReferencedRelativePaths(db, dataDir);
  void add(Object? v) {
    if (v is! String || v.isEmpty) return;
    final rel = _toDataRelative(v, dataDir);
    if (rel != null) refs.add(rel);
  }

  for (final row in await db.select(db.collectTasks).get()) {
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
      // 十四批 M2：`.tmp` 临时文件永不由孤儿清理删除——写一半的
      // 临时文件只由写路径自己在失败/回滚时清理。
      if (rel.endsWith('.tmp')) continue;
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
/// 且解析后必须在数据目录内；其它路径静默跳过）。WP-C #8 U3-2：
/// 不直接物理删除，改为在守门内移入回收站（`.trash/`），物理删除只在
/// 启动清扫时执行。返回的 `deletedCount` = 移入回收站的文件数、
/// `freedBytes` = 移入的字节数（尚未真正释放，7 天后清扫才释放）、
/// `skippedReferencedCount` = 删除前重算引用后发现仍被引用而跳过的
/// 文件数（含“引用未知”时跳过的 `slices/` 候选）。
///
/// FR-06(a)：不信任调用方传来的旧扫描——删除前用 [db] 重算一次引用
/// （复用 `_referencedRelativePaths`，一次调用只算一次），当时仍被
/// 引用的文件跳过不删、计入 `skippedReferencedCount`。
/// WP-C #8 U3-2：任一题的 `ocr_figures` JSON 无法解析时，图块裁图
/// 候选一律不删——`slices/` 候选全部跳过（图块裁图只活在 `slices/`），
/// `imports/` 候选不受影响；跳过记日志。
/// 十四批 M5 修复轮 2（B-FIX2-2）：`db` 改为必填——无数据库实时引用
/// 检查的删除路径已封闭；旧测试需要不带 DB 的行为时，用测试文件内
/// 的测试专用 helper，不要调生产入口。
Future<({int deletedCount, int freedBytes, int skippedReferencedCount})>
deleteOrphanFilesImpl(
  List<String> relativePaths, {
  String? dataDir,
  required QuizDatabase db,
}) async {
  final dir = dataDir ?? AppDatabase.dataDirectoryPath();
  final guard = FileLifecycleGuard.instance;
  // 十四批 M2（P1-B）：扫描与删除在同一锁内完成——锁内重算引用集合
  // （数据库实时查询 + 待提交集合 + 备份暂存区占用），只删三者皆无
  // 的文件；不得“扫描完放锁再删”。预览扫描（scanOrphanFilesFromImpl）
  // 只是给用户看的清单，不在锁内；删除时这一次重算才是权威口径。
  return guard.withLock(() async {
    // 删除前重算一次引用：扫描时无引用、删除时又被引用的文件——
    // 典型是恢复后旧扫描里的文件——必须跳过。
    final refs = await _referencedRelativePaths(db, dir);
    // WP-C #8 U3-2：引用未知时 `slices/` 候选一律不删（见函数注释）。
    final unknownFigureRefs = await _hasUnknownFigureRefs(db);
    var deleted = 0;
    var freed = 0;
    var skipped = 0;
    final touchedParents = <Directory>[];
    for (final rel in relativePaths) {
      if (!rel.startsWith('imports/') && !rel.startsWith('slices/')) {
        continue;
      }
      // 十四批 M2：`.tmp` 临时文件永不由孤儿清理删除（纵使调用方
      // 传进来了也跳过）。
      if (rel.endsWith('.tmp')) {
        skipped++;
        continue;
      }
      // WP-C #8 U3-2：引用未知 → `slices/` 候选永不删除，记日志。
      if (rel.startsWith('slices/') && unknownFigureRefs) {
        debugPrint(
          'U3-2 引用未知：ocrFigures JSON 无法解析，跳过 slices/ 候选 $rel，永不删除',
        );
        skipped++;
        continue;
      }
      // FR-06(a)：删除前重算的引用里有它——跳过不删，计入返回。
      // P1-B：待提交集合与备份暂存区占用同样视为“仍被引用”。
      if (refs.contains(rel) ||
          guard.isPending(rel) ||
          guard.isStaged(rel)) {
        skipped++;
        continue;
      }
      final abs = _resolveInsideDir(dir, rel);
      if (abs == null) continue;
      final f = File(abs);
      if (!f.existsSync()) continue;
      // FR-22：先记大小、删成功后再计入 freed——删失败时汇报数字
      // 不虚高（旧写法在 delete 之前就 +=，catch 为空时照计）。
      final size = f.lengthSync();
      // WP-C #8 U3-2：已持锁，走内部移入回收站（不再次取锁，P2 约束 1）。
      // 移入失败（清单损坏等）→ 文件原地保留，不计数。
      final moved = await _moveFileToTrashLocked(
        dataDir: dir,
        file: f,
        originalRel: rel,
      );
      if (!moved) continue;
      freed += size;
      deleted++;
      touchedParents.add(f.parent);
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
            await guard.deleteDirectoryLocked(d);
          } else {
            break;
          }
        } catch (_) {
          break;
        }
        d = d.parent;
      }
    }
    return (
      deletedCount: deleted,
      freedBytes: freed,
      skippedReferencedCount: skipped,
    );
  });
}

extension AppDatabaseOrphans on AppDatabase {
  /// 孤儿扫描（实例版）：扫当前库。
  Future<OrphanScan> scanOrphans() async =>
      AppDatabase.scanOrphanFilesFrom(await db);

  /// 孤儿清理（实例版）：把指定的孤儿文件移入回收站（WP-C #8 U3-2，
  /// 物理删除只在启动清扫时执行），删除前用当前库重算
  /// 一次引用（FR-06(a)，仍被引用的跳过并计入返回）。
  Future<({int deletedCount, int freedBytes, int skippedReferencedCount})>
  cleanOrphans(List<String> relativePaths) async =>
      AppDatabase.deleteOrphanFiles(relativePaths, db: await db);
}
