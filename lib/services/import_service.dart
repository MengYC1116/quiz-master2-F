import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../data/database.dart';
import '../models/models.dart';
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
    final name = task.sourcePath.isNotEmpty
        ? task.sourcePath
        : task.fileName;
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

  static bool isAllowed(String path) {
    final ext = path.split('.').last.toLowerCase();
    return allowedExtensions.contains(ext);
  }

  /// 超限只提示不硬拦；返回提示文案，null 表示不超限。
  static String? oversizeHint(File file) {
    final ext = file.path.split('.').last.toLowerCase();
    final limit = ext == 'pdf' ? maxPdfBytes : maxImageBytes;
    if (file.lengthSync() > limit) {
      return '文件较大（${(file.lengthSync() / 1024 / 1024).toStringAsFixed(1)}MB），'
          '超过建议上限 ${limit ~/ 1024 ~/ 1024}MB，仍可继续导入。';
    }
    return null;
  }

  /// 系统文件选择器，多选。返回选中的文件路径。
  Future<List<String>> pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      allowMultiple: true,
    );
    if (result == null) return [];
    return result.files.where((f) => f.path != null).map((f) => f.path!).toList();
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
    final existing = await _db.allCollectTasks();
    for (var i = 0; i < paths.length; i++) {
      final file = File(paths[i]);
      final name = file.uri.pathSegments.last;
      final id = 'task-${DateTime.now().millisecondsSinceEpoch}-$i';
      final duplicate = existing.any((t) => t.fileName == name);
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
      // 重复导入提示“已经导入过”，仍可再次导入（由调用方弹提示，见 D-08）。
      if (duplicate) {
        // 保留任务，仅标记；UI 层据此弹“已经导入过”提示。
      }
      await _db.upsertCollectTask(task);
      tasks.add(task);

      final ext = name.split('.').last.toLowerCase();
      // PDF 50MB 上限（§6 第 3 条）：复制前先判，超了直接失败，
      // 不复制、不渲染；文案说清怎么分批（拆成多个小 PDF）。
      if (ext == 'pdf') {
        try {
          final size = await file.length();
          if (size > maxPdfBytes) {
            task = _failed(task,
                '这个 PDF 有 ${(size / 1024 / 1024).toStringAsFixed(1)}MB，超过 50MB 上限，请拆成多个小 PDF 再导入');
            await _db.upsertCollectTask(task);
            tasks[tasks.length - 1] = task;
            continue;
          }
        } catch (_) {}
      }
      // 空间上限 2GB：导入前估算（已有占用 + 本文件），超了直接失败。
      try {
        final used = await storageUsageBytes();
        if (used + await file.length() > maxStorageBytes) {
          task = _failed(task, '空间不足：题库文件已超过 2GB 上限，先在设置里清理空间再导入');
          await _db.upsertCollectTask(task);
          tasks[tasks.length - 1] = task;
          continue;
        }
      } catch (_) {}
      // 复制进库（按字节真实进度 0→70%）。
      final dirAbs = AppDatabase.resolveDataPath(taskDirRelative(id))!;
      final targetAbs =
          AppDatabase.resolveDataPath(originalRelative(id, ext))!;
      try {
        await Directory(dirAbs).create(recursive: true);
        final total = await file.length();
        var copied = 0;
        var lastReported = -1;
        final sink = File(targetAbs).openWrite();
        try {
          await for (final chunk in file.openRead()) {
            sink.add(chunk);
            copied += chunk.length;
            final pct = total == 0
                ? 70
                : (copied * 70 ~/ total).clamp(0, 70);
            if (pct != lastReported) {
              lastReported = pct;
              onProgress?.call(id, pct);
              await _updateProgress(task, pct);
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
        await _db.upsertCollectTask(task);
        tasks[tasks.length - 1] = task;
        continue;
      }
      // PDF：复制完先读页数判 20 页上限，再整本渲染成页图
      // （70→100%）；加密 / 损坏 / 超页 / 渲染失败都进 failed
      // 任务并删目录，不建无页图任务。
      if (ext == 'pdf') {
        final done = await _importPdf(
          task,
          targetAbs,
          dirAbs,
          onProgress,
        );
        await _db.upsertCollectTask(done);
        tasks[tasks.length - 1] = done;
        continue;
      }
      // EXIF 方向归一化（仅 != 1 时生成副本；镜像方向显式失败）。
      try {
        final bytes = await File(targetAbs).readAsBytes();
        final normalized = await normalizeExifImageBytes(bytes);
        if (normalized.orientation >= 2 && normalized.orientation <= 7 &&
            exifOrientationToClockwiseDegrees(normalized.orientation) ==
                null) {
          // 镜像方向（2/4/5/7）：暂不支持，不可静默按旋转处理。
          try {
            await Directory(dirAbs).delete(recursive: true);
          } catch (_) {}
          task = _failed(task,
              '这张照片是镜像方向（EXIF ${normalized.orientation}），暂不支持，请先转存为正向照片再导入');
          await _db.upsertCollectTask(task);
          tasks[tasks.length - 1] = task;
          continue;
        }
        if (normalized.wasNormalized) {
          final normAbs =
              AppDatabase.resolveDataPath(normalizedPageRelative(id))!;
          await File(normAbs).writeAsBytes(normalized.bytes);
        }
        onProgress?.call(id, 90);
        await _updateProgress(task, 90);
      } catch (e) {
        // 读不到 / 解码失败：原图已拷进库，仍可继续（修框时按原图走）。
        onProgress?.call(id, 90);
        await _updateProgress(task, 90);
      }
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
      await _db.upsertCollectTask(task);
      onProgress?.call(id, 100);
      tasks[tasks.length - 1] = task;
    }
    return tasks;
  }

  /// PDF 导入（原文件已复制进库，[originalAbs] 是库内副本）：
  /// 先读页数（不渲染）判 20 页上限 → 再整本渲染成页图。
  /// 返回成功（needBox，pageCount 为真实页数）或失败任务；
  /// 失败时删掉任务目录（不留原文件与半截页图）。
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
    }
    if (total == 0) {
      return _failAndClean(task, dirAbs, '文件损坏：这个 PDF 没有页面');
    }
    if (total > maxPdfPages) {
      return _failAndClean(task, dirAbs,
          '这份 PDF 有 $total 页，超过 20 页上限，请分批导入：拆成每份不超过 20 页再导入');
    }
    // 空间上限 2GB：已有占用 + 原文件 + 预估页图（每页约 2MB）。
    var storageFull = false;
    try {
      final used = await storageUsageBytes();
      final fileSize = await File(originalAbs).length();
      storageFull = used + fileSize + total * estimatedBytesPerRenderedPage >
          maxStorageBytes;
    } catch (_) {}
    if (storageFull) {
      return _failAndClean(task, dirAbs,
          '空间不足：渲染这份 PDF 会超过 2GB 上限，先在设置里清理空间再导入');
    }
    // 整本渲染（真实进度 70→100%，按页回调）。
    final pagesAbs =
        AppDatabase.resolveDataPath('imports/${task.id}/pages')!;
    try {
      await _pdfRenderService.renderAllPagesToDir(
        originalAbs,
        pagesAbs,
        onProgress: (rendered, totalPages) async {
          final pct =
              70 + (rendered * 30 ~/ totalPages).clamp(0, 30);
          onProgress?.call(task.id, pct);
          await _updateProgress(task, pct);
        },
      );
    } on PdfEncryptedException {
      return _failAndClean(task, dirAbs, '这个 PDF 带密码，解开密码再导');
    } on PdfCorruptException catch (e) {
      return _failAndClean(task, dirAbs, '文件损坏：${e.reason}');
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
    await _db.upsertCollectTask(done);
    onProgress?.call(task.id, 100);
    return done;
  }

  /// 失败任务 + 删任务目录（不留半截文件），返回已写库的失败任务。
  Future<CollectTask> _failAndClean(
    CollectTask task,
    String dirAbs,
    String error,
  ) async {
    try {
      await Directory(dirAbs).delete(recursive: true);
    } catch (_) {}
    final failed = _failed(task, error);
    await _db.upsertCollectTask(failed);
    return failed;
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

  CollectTask _failed(CollectTask task, String error) => CollectTask(
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
        sourcePath: task.sourcePath,
        pageRotations: task.pageRotations,
      );
}
