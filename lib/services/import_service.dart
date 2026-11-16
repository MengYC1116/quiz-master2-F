import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../data/database.dart';
import '../models/models.dart';
import 'import_guess.dart';
import 'page_image_pipeline.dart';
import 'pdf_render_service.dart';

/// 导入服务：PDF / JPG / PNG；PDF 50MB / 20 页、图片 20MB；
/// 多文件排队逐个导入，带真实复制进度；导入可取消；队列重启后保留
/// （任务持久化在 collect_tasks 表）。
///
/// §1.4（P2）：导入时把文件复制进数据目录（`imports/<task-id>/`），
/// `collect_tasks.source_path` 写库内副本的相对路径，`file_name` 只做
/// 显示名；图片导入时页图即原图副本（EXIF == 1 时两路径同一文件，
/// EXIF != 1 且可旋转时生成归一化副本 `page-normalized.png`，
/// 镜像方向 2/4/5/7 暂不支持，任务直接失败并显式提示）。
/// PDF（§6 第 3 条）：导入时整本渲染——`PdfRenderService`
///（pdfrx_engine / PDFium）把每页渲成 `imports/<task-id>/pages/`
/// 下的 `page-001.png`…（PNG，长边 2500px），修框翻页直接读页图、
/// 超 50MB / 超 20 页 / 加密 / 损坏都进 failed 任务并显式提示，
/// 不建无页图任务、不静默截断。
class ImportService {
  ImportService(this._db, {PdfRenderService? pdfRenderService})
    : _pdfRenderService = pdfRenderService ?? PdfRenderService();
  final AppDatabase _db;
  final PdfRenderService _pdfRenderService;

  /// SR-P2-60：任务 id 的随机段来源（见 enqueue 的 id 生成）。
  static final _idRandom = math.Random();

  static const allowedExtensions = ['pdf', 'jpg', 'jpeg', 'png'];
  static const maxPdfBytes = 50 * 1024 * 1024;
  static const maxImageBytes = 20 * 1024 * 1024;

  /// §6 第 3 条：单个 PDF 不超过 20 页。
  static const maxPdfPages = 20;

  /// 渲染一页 PNG 的磁盘占用估算（上限判断用；实测见 PDF 报告 §5）。
  static const estimatedBytesPerRenderedPage = 2 * 1024 * 1024;

  /// §1.4/§6 第 9 条：`imports/` + `slices/` 空间上限 2GB。
  static const maxStorageBytes = 2 * 1024 * 1024 * 1024;

  /// 任务目录（相对数据目录）：`imports/<task-id>`。
  static String taskDirRelative(String taskId) => 'imports/$taskId';

  /// 原文件副本（相对数据目录）：`imports/<task-id>/original.<ext>`。
  static String originalRelative(String taskId, String ext) =>
      'imports/$taskId/original.$ext';

  /// EXIF 归一化页图副本（相对数据目录）：
  /// `imports/<task-id>/page-normalized.png`（仅 EXIF != 1 时生成）。
  static String normalizedPageRelative(String taskId) =>
      'imports/$taskId/page-normalized.png';

  /// 旋转烘焙后的页图（相对数据目录）：
  /// `imports/<task-id>/pages/page-<page>-r<degrees>.png`。
  static String bakedPageRelative(String taskId, int page, int degrees) =>
      'imports/$taskId/pages/page-$page-r$degrees.png';

  /// 整题切片（相对数据目录）：`slices/<question-id>.png`。
  static String sliceRelative(String questionId) => 'slices/$questionId.png';

  /// PDF 渲染出的页图（相对数据目录）：
  /// `imports/<task-id>/pages/page-<页码三位>.png`。
  static String renderedPageRelative(String taskId, int page) =>
      'imports/$taskId/pages/page-${page.toString().padLeft(3, '0')}.png';

  /// 某任务某页的页图相对路径。
  /// - PDF：渲染出的 `pages/page-<页码>.png`（[page] 默认任务当前页）；
  /// - 图片：归一化副本存在时用它，否则用源文件副本。
  ///
  /// SR-P2-76：这里的 `existsSync` 是有意的同步读。P0.5 实测同步读
  /// 一张 1653×2200 PNG 约 0.22–3.2ms，打开慢的主因是 YOLO 推理
  /// 约 3–6 秒，不是同步读；后续优化打开体感时优先把推理放后台、
  /// 先显页图，而不是只改读图方式。本处维持同步，不改异步。
  static String pageImageRelativeForTask(CollectTask task, {int? page}) {
    if (isPdfTask(task)) {
      return renderedPageRelative(task.id, page ?? task.page);
    }
    final normalized = normalizedPageRelative(task.id);
    final abs = AppDatabase.resolveDataPath(normalized);
    if (abs != null && File(abs).existsSync()) return normalized;
    return task.sourcePath;
  }

  /// 是否 PDF 任务（按源文件扩展名判；`file_name` 是显示名，
  /// 但扩展名与源文件一致，见 enqueue 的复制逻辑）。
  static bool isPdfTask(CollectTask task) {
    final name = task.sourcePath.isNotEmpty ? task.sourcePath : task.fileName;
    return name.toLowerCase().endsWith('.pdf');
  }

  /// 当前 `imports/` + `slices/` 已占字节数（上限判断用）。
  static Future<int> storageUsageBytes() async {
    final usage = await storageUsageBreakdown();
    return usage.importsBytes + usage.slicesBytes;
  }

  /// §4.5/P3：空间占用分项（设置页“空间占用”显示用）。
  static Future<({int importsBytes, int slicesBytes})>
  storageUsageBreakdown() async {
    var importsBytes = 0;
    var slicesBytes = 0;
    for (final rel in ['imports', 'slices']) {
      final abs = AppDatabase.resolveDataPath(rel);
      if (abs == null) continue;
      final dir = Directory(abs);
      if (!dir.existsSync()) continue;
      var total = 0;
      await for (final e in dir.list(recursive: true)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
      if (rel == 'imports') {
        importsBytes = total;
      } else {
        slicesBytes = total;
      }
    }
    return (importsBytes: importsBytes, slicesBytes: slicesBytes);
  }

  /// 字节数 → `12.3 MB` / `456 KB`（设置页显示用）。
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  /// §6 第 9 条：空间上限 2GB 的超限提示；不超限返回 null。
  static String? storageLimitMessage(int totalBytes) {
    if (totalBytes <= maxStorageBytes) return null;
    return '题图与原图已超过 2GB 上限（现在 ${formatBytes(totalBytes)}），'
        '先清理孤儿文件或删掉不需要的题目，再导入新题。';
  }

  /// 超限硬判（与 enqueue 的失败行为一致，见 SR-P1-14）；
  /// 返回提示文案，null 表示不超限。
  static String? oversizeHint(File file) {
    final ext = file.path.split('.').last.toLowerCase();
    final limit = ext == 'pdf' ? maxPdfBytes : maxImageBytes;
    if (file.lengthSync() > limit) {
      return '文件较大（${(file.lengthSync() / 1024 / 1024).toStringAsFixed(1)}MB），'
          '超过 ${limit ~/ 1024 ~/ 1024}MB 上限，导入会失败。';
    }
    return null;
  }

  /// B11-2：文件内容 SHA-256（流式读；读不到返回 null，不抛错）。
  static Future<String?> contentHashOfFile(File file) async {
    try {
      return await sha256HexOfFile(file);
    } catch (_) {
      return null;
    }
  }

  /// B11-2：已入库任务的原文件内容哈希（按任务 `sourcePath` 找库内
  /// 副本 `imports/<task-id>/original.*`；副本缺失、读不到的任务
  /// 不进结果——没法验证的就不判重复，不误拦）。
  /// 返回 taskId → 哈希；不改库、不写新字段（无 Schema 变动）。
  Future<Map<String, String>> contentHashesForTasks(
    List<CollectTask> tasks,
  ) async {
    final hashes = <String, String>{};
    for (final task in tasks) {
      if (task.sourcePath.isEmpty) continue;
      final abs = AppDatabase.resolveDataPath(task.sourcePath);
      if (abs == null) continue;
      final hash = await contentHashOfFile(File(abs));
      if (hash != null) hashes[task.id] = hash;
    }
    return hashes;
  }

  /// B11-2：一次去重检查的结果。
  /// - [libraryDuplicates]：与已入库任务内容相同（SHA-256 命中）
  ///   的待导入文件名——收集页用既有“已经导入过”横幅提示；
  /// - [withinBatchDropped]：同批里后出现的相同内容文件路径——
  ///   收集页只留第一份导入，其余直接丢掉，不建重复任务。
  /// 两种都只拦“内容相同”，文件名不同、内容相同也算重复；
  /// 只有路径相同的同批重复仍由 enqueue 的路径去重兜底。
  Future<({List<String> libraryDuplicates, List<String> withinBatchDropped})>
  checkContentDuplicates(
    List<String> paths,
    List<CollectTask> existingTasks,
  ) async {
    final existingHashes = (await contentHashesForTasks(existingTasks)).values
        .toSet();
    final libraryDuplicates = <String>[];
    final withinBatchDropped = <String>[];
    final seenHashes = <String>{};
    for (final path in paths) {
      final hash = await contentHashOfFile(File(path));
      if (hash == null) continue;
      final name = File(path).uri.pathSegments.last;
      if (!seenHashes.add(hash)) {
        withinBatchDropped.add(path);
        continue;
      }
      if (existingHashes.contains(hash) && !libraryDuplicates.contains(name)) {
        libraryDuplicates.add(name);
      }
    }
    return (
      libraryDuplicates: libraryDuplicates,
      withinBatchDropped: withinBatchDropped,
    );
  }

  /// 系统文件选择器，多选。返回选中的文件路径。
  Future<List<String>> pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      allowMultiple: true,
    );
    if (result == null) return [];
    return result.files
        .where((f) => f.path != null)
        .map((f) => f.path!)
        .toList();
  }

  /// SR2-72 / SR3-5：同批去重键——同一文件的不同写法只建一个任务。
  /// `resolveSymbolicLinks` 同时完成绝对化（相对路径 → 绝对路径）
  /// 与链接解析（符号链接 → 目标路径）；可解析时再整体小写折叠，
  /// 覆盖 Windows/macOS 不区分大小写的文件系统（产品跑在 Windows
  /// 上；Linux 下同目录仅大小写不同的两个真实文件是病态构造，
  /// 折叠后仍会被当成同一文件，这是已确认的取舍）。
  /// 解析失败（文件不存在）时回退键用原始路径、不折叠小写：不存在
  /// 的大写拼写（如 `TEST/FIXTURES/PHOTO.JPG`）若也折叠，会与真实
  /// 文件解析出的键撞键，排在前面时先建失败任务、真实文件随后被当
  /// 作重复跳过（SR3-5）。回退不折叠后，不存在的拼写只与它自身的
  /// 写法撞键；Linux 下 [真实, 不存在的大写] 会建两个任务（一个
  /// needBox、一个 failed），这是诚实行为。去重键只用于比较，实际
  /// 打开的仍是调用方传的原路径。
  Future<String> _dedupKey(String path) async {
    try {
      return (await File(path).resolveSymbolicLinks()).toLowerCase();
    } catch (_) {
      try {
        // SR3-5：回退分支不折叠小写（见上）。
        return File(path).absolute.path;
      } catch (_) {
        return path;
      }
    }
  }

  /// 多文件排队：逐个导入，下一文件自动开始；返回创建的任务。
  ///
  /// 真实进度（替换旧 `_simulateImport` 假进度）：复制按字节回调
  /// 0→70%，EXIF 归一化 70→90%，收尾 100%（`onProgress` 按
  /// (taskId, progress) 回调，调用方只在百分比变化时刷新 UI；
  /// 写库走无 bump 的 `upsertCollectTaskInto`，只有状态变化才 bump）。
  /// 复制失败 / 镜像方向 / 空间不足 → 任务直接进 `failed`，
  /// 错误写进 `collect_tasks.error`，不建“只有文件名”的空任务。
  Future<List<CollectTask>> enqueue(
    List<String> paths, {
    required String subjectId,
    void Function(String taskId, int progress)? onProgress,
  }) async {
    final tasks = <CollectTask>[];
    // SR3-6：进度回调永不抛错的转发。收集页的回调（setState 等）在
    // dispose 竞态下仍可抛错；直接调 onProgress 时，复制循环的
    // catch 会把它当成“文件复制不进去”、_importPdf 的渲染 catch
    // 会把它当成“渲染失败”，好文件被判失败、目录被删。在入口包
    // 一处，五处调用点（复制循环 / 图片 90% / 图片 100% /
    // PDF 渲染回调 / PDF 100%）全部受益；尾部三处原有的
    // try/catch 保留作双保险。
    final safeOnProgress = onProgress == null
        ? null
        : (String taskId, int progress) {
            try {
              onProgress(taskId, progress);
            } catch (_) {}
          };
    // SR-P1-17：同批去重。同一文件在一次多选里出现两次时只建一个
    // 任务，后面的直接跳过。跨批重复不在这里拦：D-08 定了重复导入
    // 允许重导，收集页先弹“已经导入过”提示，用户点“仍然再导一份”
    // 才进 enqueue。SR2-72：去重键是规范化后的路径（见 _dedupKey），
    // 同一文件的不同写法（相对/绝对路径、符号链接、大小写）也只建
    // 一个任务。
    final seenPaths = <String>{};
    for (var i = 0; i < paths.length; i++) {
      if (!seenPaths.add(await _dedupKey(paths[i]))) continue;
      final file = File(paths[i]);
      final name = file.uri.pathSegments.last;
      // SR-P2-60：id 后缀加 6 位随机段。旧 id 是“毫秒时间戳 + 批内序号”，
      // 两次 enqueue 在同一毫秒启动且序号相同时会撞 id，后一次
      // upsert 会覆盖前一次的任务行（丢任务且无报错）。
      final id =
          'task-${DateTime.now().millisecondsSinceEpoch}-$i-${_idRandom.nextInt(1000000).toString().padLeft(6, '0')}';
      var task = CollectTask(
        id: id,
        // 任务名 = 文件名 + 页 + 题号；此处先按第 1 页第 1 题，修框确认后拆题改名。
        name: '$name · 第1页 · 第1题',
        fileName: name,
        subjectId: subjectId,
        status: CollectStatus.importing,
        progress: 0,
        createdAt: DateTime.now(),
      );
      // SR2-1/SR2-2：每文件一层兜底 try。单个文件任何一步抛错
      // （含初始 importing 行写库失败）都转成该任务的 failed 行
      // （能写库就写，写不进也只返回内存里的 failed 任务），继续
      // 下一个文件，绝不逃出 enqueue、中断整批。taskAdded 记 tasks
      // 里是否已有本任务的行，cleanupDir 记已建的任务目录（供兜底
      // 清理用，未建目录时为 null）。
      var taskAdded = false;
      String? cleanupDir;
      try {
        await _db.upsertCollectTask(task);
        tasks.add(task);
        taskAdded = true;

        final ext = name.split('.').last.toLowerCase();
        // 单文件大小上限（§6 第 3 条）：PDF 50MB / 图片 20MB，复制前
        // 先判，超了直接失败，不复制、不渲染；文案说清怎么处理
        //（PDF 拆成多个小 PDF，图片压缩到 20MB 以内）。
        // SR-P1-14：图片与 PDF 同款硬判，不再只提示不执行。
        // SR2-1(a)：读长度与“超限失败”分开——读不到文件时走后面的
        // 复制失败路径；超限失败行的 upsert 各自包 try，写不进也只
        // 返回内存 failed 任务，不再被读长度的 catch 吞掉后继续复制。
        var oversize = false;
        String? oversizeError;
        try {
          final size = await file.length();
          final limit = ext == 'pdf' ? maxPdfBytes : maxImageBytes;
          if (size > limit) {
            oversize = true;
            oversizeError = ext == 'pdf'
                ? '这个 PDF 有 ${(size / 1024 / 1024).toStringAsFixed(1)}MB，超过 50MB 上限，请拆成多个小 PDF 再导入'
                : '这张图片有 ${(size / 1024 / 1024).toStringAsFixed(1)}MB，超过 20MB 上限，请压缩到 20MB 以内再导入';
          }
        } catch (_) {}
        if (oversize) {
          task = _failed(task, oversizeError!);
          try {
            await _db.upsertCollectTask(task);
          } catch (_) {}
          tasks[tasks.length - 1] = task;
          continue;
        }
        // 空间上限 2GB：导入前估算（已有占用 + 本文件），超了直接失败。
        // SR2-1(a)：同上，估算与失败写库分开。
        var storageFull = false;
        try {
          final used = await storageUsageBytes();
          storageFull = used + await file.length() > maxStorageBytes;
        } catch (_) {}
        if (storageFull) {
          task = _failed(task, '空间不足：题库文件已超过 2GB 上限，先在设置里清理空间再导入');
          try {
            await _db.upsertCollectTask(task);
          } catch (_) {}
          tasks[tasks.length - 1] = task;
          continue;
        }
        // 复制进库（按字节真实进度 0→70%）。
        final dirAbs = AppDatabase.resolveDataPath(taskDirRelative(id))!;
        final targetAbs = AppDatabase.resolveDataPath(
          originalRelative(id, ext),
        )!;
        cleanupDir = dirAbs;
        // B2 B-NEW-12：lastDbPct 提到复制 try 之外——复制完成后立即
        // 持久化 source_path 时，要把已写库的进度原样带回去（不能写
        // 回 task.progress 的 0，否则进度从 70% 跌回 0）。
        var lastDbPct = -1;
        try {
          await Directory(dirAbs).create(recursive: true);
          final total = await file.length();
          var copied = 0;
          var lastReported = -1;
          // SR-P2-62：进度写库节流到每 5 个百分点一次（0→70% 原来最多
          // 约 70 次写库，现约 15 次）；UI 回调 onProgress 保持逐次。
          final sink = File(targetAbs).openWrite();
          try {
            await for (final chunk in file.openRead()) {
              sink.add(chunk);
              copied += chunk.length;
              final pct = total == 0 ? 70 : (copied * 70 ~/ total).clamp(0, 70);
              if (pct != lastReported) {
                lastReported = pct;
                safeOnProgress?.call(id, pct);
                if (lastDbPct < 0 || pct - lastDbPct >= 5) {
                  lastDbPct = pct;
                  await _updateProgress(task, pct);
                }
              }
            }
          } finally {
            await sink.close();
          }
        } catch (e) {
          try {
            await Directory(dirAbs).delete(recursive: true);
          } catch (_) {}
          task = _failed(task, '导入失败：文件复制不进去（$e）');
          // SR2-1(a)：失败行的 upsert 也包 try，写不进只返回内存任务。
          try {
            await _db.upsertCollectTask(task);
          } catch (_) {}
          tasks[tasks.length - 1] = task;
          continue;
        }
        // B2 B-NEW-12：原图落盘后立即持久化 source_path——在渲染 /
        // 归一化之前补一次 upsert，崩溃窗口只剩“落盘→本次 upsert”
        // 之间（兜底仍是 taskId + 固定命名定位原图，见协议第 1 条）。
        // upsertCollectTaskInto 是 UPDATE-first 全列写回（除
        // created_at 外全列，见 db_collect.dart），所以不能只传
        // sourcePath：把任务现有的全部字段值原样带回，只改
        // sourcePath（与已写库的进度 lastDbPct）；状态仍为 importing，
        // created_at 不变（UPDATE 分支不碰它）。
        final persistedTask = CollectTask(
          id: task.id,
          name: task.name,
          fileName: task.fileName,
          subjectId: task.subjectId,
          status: task.status,
          progress: lastDbPct < 0 ? task.progress : lastDbPct,
          pageCount: task.pageCount,
          page: task.page,
          error: task.error,
          questionId: task.questionId,
          createdAt: task.createdAt,
          sourcePath: originalRelative(id, ext),
          pageRotations: task.pageRotations,
        );
        try {
          await _db.upsertCollectTask(persistedTask);
          task = persistedTask;
        } catch (e) {
          // 持久化本身失败：原图已在盘上，失败行仍带 sourcePath
          //（引用真实存在的文件，不悬空），走 _failAndClean
          //（只清派生文件、保留原图），任务可凭原图重试。
          final failedTask = await _failAndClean(
            persistedTask,
            dirAbs,
            '导入失败：原图已存进来了，但写不进任务列表（$e）',
          );
          tasks[tasks.length - 1] = failedTask;
          continue;
        }
        // PDF：复制完先读页数判 20 页上限，再整本渲染成页图
        // （70→100%）；加密 / 损坏 / 超页 / 渲染失败都进 failed
        // 任务（B-NEW-10：只清派生文件、保留原图供重试），
        // 不建无页图任务。
        if (ext == 'pdf') {
          // SR2-1：_importPdf 调用点也兜底——其内部失败已由
          // _failAndClean 转成 failed 任务（SR2-2 保证 _failAndClean
          // 自身不抛错），这里只接真正意外的异常。
          CollectTask done;
          try {
            done = await _importPdf(task, targetAbs, dirAbs, safeOnProgress);
          } catch (e) {
            done = await _failAndClean(task, dirAbs, '导入失败：这个 PDF 没导进去（$e）');
          }
          try {
            await _db.upsertCollectTask(done);
          } catch (_) {
            // SR-P1-4：收尾重写失败也不中断整批；_importPdf 返回的
            // 任务状态即为准（内存里），继续下一个文件。
          }
          tasks[tasks.length - 1] = done;
          continue;
        }
        // EXIF 方向归一化（仅 != 1 时生成副本；镜像方向显式失败）。
        // SR2-1(b)：分清两种失败——
        //   (1) “已判定解不开图片”（canDecode 为假 / 镜像方向 2/4/5/7）：
        //       走 _failAndClean（B-NEW-10：只清派生文件、保留原图，
        //       失败行 sourcePath 仍指向原图，可重试），失败后绝不
        //       再复活成 needBox；
        //   (2) “读盘 / 写盘失败”（读不到原图、归一化写盘失败）：
        //       原因不明，保留旧降级（原图已拷进库，修框时按原图走）。
        Uint8List? bytes;
        try {
          bytes = await File(targetAbs).readAsBytes();
        } catch (_) {
          bytes = null;
        }
        String? decodeError;
        if (bytes != null) {
          try {
            // SR-P2-61：先校验图片能不能解码。改后缀的非图片文件（如 .txt
            // 改 .jpg）能通过扩展名检查，解不开时不再静默按原图进 needBox，
            // 任务直接失败并提示“这张图片打不开”（修框时才暴露太晚了）。
            if (!await canDecodeImageBytes(bytes)) {
              decodeError = '这张图片打不开，请确认文件是完好的图片再导入';
            } else {
              final normalized = await normalizeExifImageBytes(bytes);
              if (normalized.orientation >= 2 &&
                  normalized.orientation <= 7 &&
                  exifOrientationToClockwiseDegrees(normalized.orientation) ==
                      null) {
                // 镜像方向（2/4/5/7）：暂不支持，不可静默按旋转处理。
                decodeError =
                    '这张照片是镜像方向（EXIF ${normalized.orientation}），暂不支持，请先转存为正向照片再导入';
              } else if (normalized.wasNormalized) {
                final normAbs = AppDatabase.resolveDataPath(
                  normalizedPageRelative(id),
                )!;
                await File(normAbs).writeAsBytes(normalized.bytes);
              }
            }
          } catch (_) {
            // 归一化 / 写盘失败：原因不明 → 旧降级（decodeError 保持
            // null，原图还在）。canDecode 本身不抛错，走到这里的不是
            // 解码失败，而是 normalize / 写盘失败。
            decodeError = null;
          }
        }
        if (decodeError != null) {
          // B2 B-NEW-10：与 _failAndClean 同款——只清派生文件、保留
          // 原图（原图已在立即持久化时写进 sourcePath，失败行指向
          // 真实存在的文件，可重试）；不再整目录删掉。
          task = await _failAndClean(task, dirAbs, decodeError);
          tasks[tasks.length - 1] = task;
          continue;
        }
        // 读盘失败（bytes 为 null）或归一化失败：旧降级，按原图进 needBox。
        // 读不到 / 归一化失败等原因不明的失败：保留旧降级（原图已拷进
        // 库，修框时按原图走）。SR-P2-61 只把“确实解不开的图片”判
        // 失败，上面 canDecodeImageBytes 已先行拦截，走到这里的不是
        // 解码失败，而是读盘 / 写盘等不明确的原因。
        try {
          safeOnProgress?.call(id, 90);
        } catch (_) {}
        try {
          await _updateProgress(task, 90);
        } catch (_) {}
        task = CollectTask(
          id: task.id,
          name: task.name,
          fileName: task.fileName,
          subjectId: task.subjectId,
          status: CollectStatus.needBox,
          progress: 100,
          pageCount: 1,
          page: 1,
          createdAt: task.createdAt,
          sourcePath: originalRelative(id, ext),
        );
        // 状态变化（importing → needBox）才 bump（见 §4.3 节流）。
        // SR2-1：图片尾部 upsert 与 PDF 分支同款包进 try/catch，
        // 失败走 _failAndClean（失败任务 + 只清派生文件、保留原图）；
        // 其自身写库再失败时只返回内存里的 failed 任务，绝不逃出 enqueue。
        try {
          await _db.upsertCollectTask(task);
        } catch (e) {
          task = await _failAndClean(
            task,
            dirAbs,
            '导入失败：这张图片导进来了，但写不进任务列表（$e）',
          );
          tasks[tasks.length - 1] = task;
          continue;
        }
        try {
          safeOnProgress?.call(id, 100);
        } catch (_) {}
        tasks[tasks.length - 1] = task;
      } catch (e) {
        // 兜底（SR2-1/SR2-2）：单个文件任何一步抛错都只影响本任务，
        // 转成 failed 行（能写库就写，写不进也只返回内存里的 failed
        // 任务），继续下一个文件，绝不逃出 enqueue、中断整批。
        // 若 task 已是带具体原因的 failed 任务（如某失败分支的
        // upsert 刚抛错），保留原原因，不用笼统文案覆盖。
        final failed = task.status == CollectStatus.failed
            ? task
            : _failed(task, '导入失败：这个文件没导进去（$e）');
        CollectTask result;
        if (cleanupDir != null) {
          result = await _failAndClean(
            failed,
            cleanupDir,
            failed.error ?? '导入失败',
          );
        } else {
          try {
            await _db.upsertCollectTask(failed);
          } catch (_) {}
          result = failed;
        }
        if (taskAdded) {
          tasks[tasks.length - 1] = result;
        } else {
          tasks.add(result);
        }
        continue;
      }
    }
    return tasks;
  }

  /// PDF 导入（原文件已复制进库，[originalAbs] 是库内副本）：
  /// 先读页数（不渲染）判 20 页上限 → 再整本渲染成页图。
  /// 返回成功（needBox，pageCount 为真实页数）或失败任务；
  /// 失败时走 _failAndClean（B-NEW-10：只清派生文件、保留原图）。
  Future<CollectTask> _importPdf(
    CollectTask task,
    String originalAbs,
    String dirAbs,
    void Function(String taskId, int progress)? onProgress,
  ) async {
    int total;
    try {
      total = await _pdfRenderService.pageCount(originalAbs);
    } on PdfEncryptedException {
      return _failAndClean(task, dirAbs, '这个 PDF 带密码，解开密码再导');
    } on PdfCorruptException catch (e) {
      return _failAndClean(task, dirAbs, '文件损坏：${e.reason}');
    } catch (e) {
      // 兜底（磁盘满等 FileSystemException）：不让异常逃出 enqueue，
      // 任务进 failed 并清掉半写派生文件（原图保留），不卡在导入中。
      return _failAndClean(task, dirAbs, '导入失败：这个 PDF 没导进去（$e）');
    }
    if (total == 0) {
      return _failAndClean(task, dirAbs, '文件损坏：这个 PDF 没有页面');
    }
    if (total > maxPdfPages) {
      return _failAndClean(
        task,
        dirAbs,
        '这份 PDF 有 $total 页，超过 20 页上限，请分批导入：拆成每份不超过 20 页再导入',
      );
    }
    // 空间上限 2GB：已有占用 + 预估页图（每页约 2MB）。
    // SR-P2-59：只加页图，不再加原文件——原文件在进 _importPdf 之前
    // 已复制进库，storageUsageBytes() 的 used 里已经含它，再加一次
    // fileSize 是把原文件算了两次，接近 2GB 上限时会误拒合法 PDF。
    var storageFull = false;
    try {
      final used = await storageUsageBytes();
      storageFull =
          used + total * estimatedBytesPerRenderedPage > maxStorageBytes;
    } catch (_) {}
    if (storageFull) {
      return _failAndClean(
        task,
        dirAbs,
        '空间不足：渲染这份 PDF 会超过 2GB 上限，先在设置里清理空间再导入',
      );
    }
    // 整本渲染（真实进度 70→100%，按页回调）。
    final pagesAbs = AppDatabase.resolveDataPath('imports/${task.id}/pages')!;
    try {
      await _pdfRenderService.renderAllPagesToDir(
        originalAbs,
        pagesAbs,
        onProgress: (rendered, totalPages) async {
          final pct = 70 + (rendered * 30 ~/ totalPages).clamp(0, 30);
          onProgress?.call(task.id, pct);
          await _updateProgress(task, pct);
        },
      );
    } on PdfEncryptedException {
      return _failAndClean(task, dirAbs, '这个 PDF 带密码，解开密码再导');
    } on PdfCorruptException catch (e) {
      return _failAndClean(task, dirAbs, '文件损坏：${e.reason}');
    } catch (e) {
      // 兜底（渲染中途磁盘满等）：同上，失败任务 + 清半写派生文件
      //（原图保留），不让任务卡在导入中。
      return _failAndClean(task, dirAbs, '导入失败：渲染这份 PDF 时出了问题（$e）');
    }
    final done = CollectTask(
      id: task.id,
      name: task.name,
      fileName: task.fileName,
      subjectId: task.subjectId,
      status: CollectStatus.needBox,
      progress: 100,
      pageCount: total,
      page: 1,
      createdAt: task.createdAt,
      sourcePath: originalRelative(task.id, 'pdf'),
    );
    // 状态变化（importing → needBox）才 bump（见 §4.3 节流）。
    // SR-P1-4：这一步写库失败也不能逃出 enqueue——先走
    // _failAndClean（失败任务 + 只清派生文件、保留原图）；其自身写库
    // 再失败时返回内存里的 failed 任务，绝不抛到 enqueue 外卡住整批。
    // SR2-2：_failAndClean 内部已有兜底，不再抛错，这里不再套 try。
    try {
      await _db.upsertCollectTask(done);
    } catch (e) {
      return _failAndClean(done, dirAbs, '导入失败：这个 PDF 渲完了，但写不进任务列表（$e）');
    }
    try {
      onProgress?.call(task.id, 100);
    } catch (_) {}
    return done;
  }

  /// 失败任务 + 只清派生文件（B2 B-NEW-10），返回已写库的失败任务。
  /// SR2-2：自身的写库也包进 try——13 处调用点只有尾部 1 处有保护，
  /// 在这里包一处，十三处受益；写不进时只返回内存里的 failed 任务，
  /// 本函数绝不抛错。
  ///
  /// 清理范围：只删派生文件——`pages/`（PDF 渲染页图，含旋转烘焙
  /// 页图）与 `page-normalized.png`（EXIF 归一化副本）；原始输入
  /// 文件 `imports/<taskId>/original.*` 一律保留，失败任务凭它
  /// 重试（见 [retryFromStoredOriginal]）。顺序按协议第 1 条：
  /// 先写库（失败行，sourcePath 保持指向保留的原图），写库成功
  /// 后再删派生文件；写库失败时不删任何文件。collect_tasks 行不存
  /// 派生文件路径（页图按 taskId 派生，见 pageImageRelativeForTask），
  /// 所以没有需要先清的库路径字段；失败行引用的唯一文件就是保留
  /// 的原图，写库前校验它仍在盘上（sourcePath 若指向已不存在的
  /// 文件则清掉，不留悬空引用；路径解析不到时不动，不误删有效引用）。
  Future<CollectTask> _failAndClean(
    CollectTask task,
    String dirAbs,
    String error,
  ) async {
    final failed = _failed(
      task,
      error,
      sourcePath: _sourcePathIfFileExists(task.sourcePath),
    );
    try {
      await _db.upsertCollectTask(failed);
    } catch (_) {
      return failed;
    }
    // 写库成功后才删派生文件；原图（original.*）一律保留。
    try {
      final pagesDir = Directory('$dirAbs/pages');
      if (await pagesDir.exists()) {
        await pagesDir.delete(recursive: true);
      }
    } catch (_) {}
    try {
      final normalized = File('$dirAbs/page-normalized.png');
      if (await normalized.exists()) await normalized.delete();
    } catch (_) {}
    return failed;
  }

  /// sourcePath 指向的文件若已不在盘上，返回 ''（不留悬空引用）；
  /// 为空或路径解析不到时原样返回，不误删有效引用。
  String _sourcePathIfFileExists(String sourcePath) {
    if (sourcePath.isEmpty) return sourcePath;
    final abs = AppDatabase.resolveDataPath(sourcePath);
    if (abs == null) return sourcePath;
    return File(abs).existsSync() ? sourcePath : '';
  }

  /// B2 ⑫：按 taskId + 固定命名定位库内原图（协议第 1 条的唯一口径，
  /// 不依赖 source_path 是否已持久化；与 db_orphans.dart 的保护口径
  /// 同款：`original` 或 `original.*`）。返回匹配到的候选文件
  /// （0 个、1 个或多个——调用方按候选数处理，不得自行挑选）。
  static List<File> locateStoredOriginals(String taskId) {
    final dirAbs = AppDatabase.resolveDataPath(taskDirRelative(taskId));
    if (dirAbs == null) return const [];
    final dir = Directory(dirAbs);
    if (!dir.existsSync()) return const [];
    return dir.listSync().whereType<File>().where((f) {
      final name = f.uri.pathSegments.last;
      return name == 'original' || name.startsWith('original.');
    }).toList();
  }

  /// B2 ⑫：用库内保留的原图重试失败任务（导入/重试入口）。
  /// 批量重试（collect_notifier 的 retryBatchFailures /
  /// retryBatchPath）用的是用户原路径重导，不走这里；这里是
  /// “原路径已不在手边、只能凭库内原图重试”的入口（崩溃后恢复的
  /// 失败任务、以及后续收集页按任务重试的接线点——接线本身在
  /// collect_notifier，不在本文件）。
  /// - 恰好一个 original.* 候选：用它重新走一次 [enqueue]
  ///   （与批量重试同一机制：成功时建新任务行，旧失败行保留——
  ///   与批量重试“失败行留着、新行另建”的行为一致）；
  /// - 找不到原图，或找到多个候选：不挑其中一个、不删任何一个，
  ///   任务标失败并提示用户重新提供原文件（走 _failAndClean +
  ///   任务 error 文案，与其它失败同一通道，不新造提示体系）。
  ///   无文件时 sourcePath 会被清掉（原引用已悬空）；多候选时
  ///   sourcePath 若仍指向真实存在的文件则保留，否则清掉。
  /// 返回重试结果任务（成功为 needBox，异常为 failed）。
  Future<CollectTask> retryFromStoredOriginal(
    CollectTask task, {
    void Function(String taskId, int progress)? onProgress,
  }) async {
    final dirAbs = AppDatabase.resolveDataPath(taskDirRelative(task.id));
    final candidates = locateStoredOriginals(task.id);
    if (candidates.length != 1) {
      final error = candidates.isEmpty
          ? '找不到原来导入的文件，请重新提供原文件再导入'
          : '这个任务有多个原文件，无法确定用哪一个，请重新提供原文件再导入';
      if (dirAbs == null) {
        // 数据目录解析不到：连任务目录都定位不了，只写失败行
        //（_failAndClean 的删派生步骤无目录可删）；sourcePath 清掉，
        // 不留指向未知位置的引用。
        final failed = _failed(task, error, sourcePath: '');
        try {
          await _db.upsertCollectTask(failed);
        } catch (_) {}
        return failed;
      }
      return _failAndClean(task, dirAbs, error);
    }
    final retried = await enqueue(
      [candidates.single.path],
      subjectId: task.subjectId,
      onProgress: onProgress,
    );
    return retried.first;
  }

  /// 进度更新：只写 progress，不改 status，不 bump（§4.3 节流）。
  Future<void> _updateProgress(CollectTask task, int progress) async {
    final d = await _db.db;
    final updated = CollectTask(
      id: task.id,
      name: task.name,
      fileName: task.fileName,
      subjectId: task.subjectId,
      status: task.status,
      progress: progress,
      pageCount: task.pageCount,
      page: task.page,
      error: task.error,
      questionId: task.questionId,
      createdAt: task.createdAt,
      sourcePath: task.sourcePath,
      pageRotations: task.pageRotations,
    );
    await AppDatabase.upsertCollectTaskInto(d, updated);
  }

  /// [sourcePath] 为空串时把失败行的 sourcePath 清掉（原引用已悬空）；
  /// 不传时沿用任务现有的 sourcePath。
  CollectTask _failed(CollectTask task, String error, {String? sourcePath}) =>
      CollectTask(
        id: task.id,
        name: task.name,
        fileName: task.fileName,
        subjectId: task.subjectId,
        status: CollectStatus.failed,
        progress: 0,
        pageCount: task.pageCount,
        page: task.page,
        error: error,
        createdAt: task.createdAt,
        sourcePath: sourcePath ?? task.sourcePath,
        pageRotations: task.pageRotations,
      );
}
