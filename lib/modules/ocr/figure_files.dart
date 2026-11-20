// 十四批 M2：图块裁图文件的写文件协议（REV4.3 双路径预登记版）。
//
// 协议七条，缺一不可（旧“同一同步段”口径已废止——Dart 的文件改名是
// 异步操作，改名完成后再补登记存在并发窗口）：
// 1. 创建临时文件之前，登记临时路径；
// 2. 在执行 rename 之前，提前登记正式目标路径；
// 3. 执行异步 rename；
// 4. rename 成功后，移除临时路径登记，保留正式路径登记；
// 5. 数据库引用事务提交成功后，移除正式路径登记（[commitFigureFiles]）；
// 6. 数据库事务失败时，在统一文件操作锁内清理正式文件，确认清理
//    完成后再移除登记（[rollbackFigureFiles]）；
// 7. rename 失败时，按照实际文件存在状态清理，并确保两条路径的登记
//    最终正确解除。
// 关键原则：在异步文件系统操作开始之前，必须已经保护操作可能产生
// 的所有路径。任一步失败不写引用、不留无效路径；进程中断产生的孤儿
// 文件由清理机制处理。本协议适用于一切走写文件协议的新文件写入
// （OCR 自动应用、候选接受、重识别替换的新图块）。
//
// 图块裁图失败不阻断题干写回：裁图是增强，题干是主体——任一图块
// 写失败时整批图块写失败（已写文件按协议清理），调用方按“无图块”
// （ocr_figures='[]'）继续写回题干，不让一次裁图失败丢掉整份识别结果。

import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../data/file_lifecycle_guard.dart';
import 'ocr_figures.dart';

/// 图块文件写入失败（调用方按“无图块”降级，见文件头）。
class FigureWriteException implements Exception {
  FigureWriteException(this.message);

  final String message;

  @override
  String toString() => 'FigureWriteException: $message';
}

/// 一批图块文件写入的结果：已落盘的图块（带 crop_path）+ 仍登记在
/// 待提交集合里的正式路径（提交成功后调 [commitFigureFiles] 解除，
/// 提交失败时调 [rollbackFigureFiles] 清理后解除）。
class FigureWriteResult {
  FigureWriteResult({required this.figures, required this.registeredPaths});

  final List<OcrFigure> figures;
  final List<String> registeredPaths;
}

/// 物理删除的区分结果（M5 修复轮 2，GPT fix1 窄审 §3.1 问题 B）：
/// deleteFileLocked() 返回 false 时不区分“文件原本不存在”与“文件存在
/// 但删除失败”，调用方必须先判存在再认结果——不存在视为已清理完成，
/// 删失败则保留登记，不得把未确认清理成功等同于清理完成。
enum _FigureDeleteOutcome {
  /// 文件存在且已删除。
  deleted,

  /// 文件原本不存在（无须删除，视为已清理）。
  notExisted,

  /// 文件存在但删除失败（登记必须保留，见 [rollbackFigureFiles]）。
  failed,
}

/// 锁内删一个图块文件并区分结果（调用方必须已持锁）。
/// 存在性用 [FileSystemEntity.typeSync] 判，不用 `File.existsSync()`——
/// 后者对目录路径返回 false，会把“路径上有目录”误判为不存在。
Future<_FigureDeleteOutcome> _deleteFigureFileLocked(File file) async {
  if (FileSystemEntity.typeSync(file.path) ==
      FileSystemEntityType.notFound) {
    return _FigureDeleteOutcome.notExisted;
  }
  final ok = await FileLifecycleGuard.instance.deleteFileLocked(file);
  return ok ? _FigureDeleteOutcome.deleted : _FigureDeleteOutcome.failed;
}

/// 按写文件协议写出一批图块裁图（数据库事务外先做）。
///
/// - [dataDir]：数据目录（相对路径的解析基准；测试传临时目录）；
/// - [sliceBytes]：源切片字节（裁图用，不含白边）；
/// - [figures]：待写图块（cropPath 为空，由本函数分配正式路径）；
/// - [beforeRename]：仅测试用——在登记正式路径后、执行 rename 前调用
///   （⑦ rename 并发清理测试用它在该窗口触发孤儿清理）。
///
/// 成功时返回带 crop_path 的图块与仍登记的正式路径；任一步失败时
/// 已写文件按协议清理（两条路径登记在确认清理完成后再解除；删除
/// 失败的路径保留登记，见 [_FigureDeleteOutcome]）并抛
/// [FigureWriteException]。
Future<FigureWriteResult> writeFigureFiles({
  required String dataDir,
  required String questionId,
  required Uint8List sliceBytes,
  required List<OcrFigure> figures,
  Future<void> Function()? beforeRename,
}) async {
  final guard = FileLifecycleGuard.instance;
  final written = <OcrFigure>[];
  final registeredFinals = <String>[];
  // 本批内已登记、待收尾的临时路径（失败时一并解除）。
  final registeredTmps = <String>[];
  Future<void> cleanupOnFailure() async {
    // 按实际文件存在状态清理：正式文件与临时文件哪个存在删哪个；
    // 清理完成后再移除登记（第 6/7 条：先清文件，后解登记）。
    // 删除失败的路径保留登记（§3.1 问题 B）：未确认清理成功不得
    // 等同于清理完成；登记保留在内存 pending 集合里，进程重启后
    // 由孤儿清理收尾。
    final failed = <String>{};
    await guard.withLock(() async {
      for (final rel in [...registeredFinals, ...registeredTmps]) {
        final abs = _resolveInside(dataDir, rel);
        if (abs == null) continue;
        if (await _deleteFigureFileLocked(File(abs)) ==
            _FigureDeleteOutcome.failed) {
          failed.add(rel);
        }
      }
    });
    for (final rel in [...registeredFinals, ...registeredTmps]) {
      if (!failed.contains(rel)) guard.unregisterPending(rel);
    }
  }

  try {
    for (var fi = 0; fi < figures.length; fi++) {
      final figure = figures[fi];
      final png = cropFigurePng(sliceBytes: sliceBytes, rect: figure.srcRect);
      if (png == null || png.isEmpty) {
        throw FigureWriteException('图块裁图失败：${figure.id}');
      }
      // 校验：解码成功、尺寸 > 0（写临时文件前先在内存里验）。
      final decoded = img.decodeImage(png);
      if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
        throw FigureWriteException('图块校验失败（解不出图）：${figure.id}');
      }
      // 1. 创建临时文件之前，登记临时路径（同目录 `.tmp`，孤儿清理
      // 永不删 `.tmp`，见 P1-B；写一半的临时文件只由写路径自己清理）。
      final tmpRel =
          'slices/$questionId-fig-${DateTime.now().millisecondsSinceEpoch}-$fi-${_rand()}.tmp';
      guard.registerPending(tmpRel);
      registeredTmps.add(tmpRel);
      final tmpAbs = _resolveInside(dataDir, tmpRel);
      if (tmpAbs == null) {
        throw FigureWriteException('图块临时路径非法：$tmpRel');
      }
      // 正式路径含图块 ID（§3.1 问题 A：同一题多张图块路径必然不同）；
      // 目标已存在时换新时间戳+随机数重算，绝不覆盖旧文件（rename
      // 在 Linux 上会静默覆盖已存在目标）。最多重算 8 次。
      var finalRel = figureCropFileName(questionId, figureId: figure.id);
      var finalAbs = _resolveInside(dataDir, finalRel);
      if (finalAbs == null) {
        throw FigureWriteException('图块目标路径非法：$finalRel');
      }
      var attempts = 0;
      while (File(finalAbs!).existsSync()) {
        if (++attempts > 8) {
          throw FigureWriteException('图块目标路径被占用：$finalRel');
        }
        finalRel = figureCropFileName(questionId, figureId: figure.id);
        finalAbs = _resolveInside(dataDir, finalRel);
        if (finalAbs == null) {
          throw FigureWriteException('图块目标路径非法：$finalRel');
        }
      }
      // 流分析：到这里 finalAbs 不可能为 null（为 null 的分支上面都已抛错）。
      final targetAbs = finalAbs;
      try {
        await File(tmpAbs).parent.create(recursive: true);
        // WP-C #8 U3-1：写盘持守门——备份复制与写盘串行化，不读半写文件。
        await guard.withLock(() => File(tmpAbs).writeAsBytes(png));
      } catch (_) {
        throw FigureWriteException('图块临时文件写失败：${figure.id}');
      }
      // 2. 执行异步 rename 之前，提前登记正式目标路径。
      guard.registerPending(finalRel);
      registeredFinals.add(finalRel);
      // 3. 原子改名（异步）。[beforeRename] 只在测试里用来在登记与
      // 改名之间的窗口触发孤儿清理（⑦）——它自己要取锁，故必须在
      // 锁外调用；改名本身持守门（WP-C #8 U3-1）。
      try {
        await beforeRename?.call();
        await guard.withLock(() => File(tmpAbs).rename(targetAbs));
      } catch (_) {
        // 7. rename 失败：按实际文件存在状态清理（临时文件还在就删
        // 临时文件；正式文件若已出现——如目标已存在导致 rename 失败
        // 后残留——也清理），确认清理完成后再解除对应登记；删除失败
        // 的路径保留登记，并留在待收尾列表里由外层 cleanupOnFailure
        // 再试一次（§3.1 问题 B）。
        final failed = <String>{};
        await guard.withLock(() async {
          for (final rel in [tmpRel, finalRel]) {
            final abs = _resolveInside(dataDir, rel);
            if (abs == null) continue;
            if (await _deleteFigureFileLocked(File(abs)) ==
                _FigureDeleteOutcome.failed) {
              failed.add(rel);
            }
          }
        });
        for (final rel in [tmpRel, finalRel]) {
          if (failed.contains(rel)) continue;
          guard.unregisterPending(rel);
          registeredTmps.remove(rel);
          registeredFinals.remove(rel);
        }
        throw FigureWriteException('图块改名失败：${figure.id}');
      }
      // 4. rename 成功后，移除临时路径登记，保留正式路径登记。
      guard.unregisterPending(tmpRel);
      registeredTmps.remove(tmpRel);
      written.add(figure.copyWith(cropPath: finalRel));
    }
    return FigureWriteResult(
      figures: written,
      registeredPaths: registeredFinals,
    );
  } catch (_) {
    await cleanupOnFailure();
    rethrow;
  }
}

/// 数据库引用提交成功后调：移除正式路径登记（第 5 条）。
void commitFigureFiles(List<String> registeredPaths) {
  final guard = FileLifecycleGuard.instance;
  for (final rel in registeredPaths) {
    guard.unregisterPending(rel);
  }
}

/// 数据库事务失败时调：在统一文件操作锁内清理正式文件，确认清理
/// 完成后再移除登记（第 6 条）；数据库不留下无效引用。
///
/// 返回清理失败的相对路径（文件存在但删除失败）：这些路径的登记被
/// 保留，调用方可记日志/重试；pending 是内存集合，进程重启后登记
/// 消失，失败文件由下次启动的孤儿清理收尾。文件原本不存在的路径
/// 视为清理完成，不在返回里（§3.1 问题 B）。
Future<List<String>> rollbackFigureFiles(
  List<String> registeredPaths, {
  required String dataDir,
}) async {
  final guard = FileLifecycleGuard.instance;
  final failed = <String>[];
  await guard.withLock(() async {
    for (final rel in registeredPaths) {
      final abs = _resolveInside(dataDir, rel);
      if (abs == null) continue;
      if (await _deleteFigureFileLocked(File(abs)) ==
          _FigureDeleteOutcome.failed) {
        failed.add(rel);
      }
    }
  });
  for (final rel in registeredPaths) {
    if (!failed.contains(rel)) guard.unregisterPending(rel);
  }
  return failed;
}

int _rand() => DateTime.now().microsecondsSinceEpoch % (1 << 32);

String? _resolveInside(String dataDir, String rel) {
  // 与 AppDatabase._resolveInsideDir 同口径：只允许 imports/ 与
  // slices/ 下的相对路径，`..` 越界一律拒绝。
  final normalized = rel.replaceAll('\\', '/');
  if (!normalized.startsWith('imports/') &&
      !normalized.startsWith('slices/')) {
    return null;
  }
  final abs = p.normalize(p.join(dataDir, normalized));
  final root = p.normalize(dataDir);
  if (!p.isWithin(root, abs) && abs != root) return null;
  return abs;
}
