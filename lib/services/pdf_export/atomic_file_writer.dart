// 十五批 M2-2：原子写入与目标冲突（PLAN-15-REV3 §5 M2-2）。
//
// 流程：写临时文件 → 完整关闭 → 验证（文件存在、大小 > 0、PDF 可打开、
// 页数与预期一致）→ 原子移动到正式文件名。
// - 临时文件与目标文件在同一目录（同一文件系统/卷），避免跨卷移动
//   退化成复制后删除、失去原子性；
// - 验证失败 → 临时文件删除，整单失败并明确报错，不得留半截 PDF；
// - 磁盘满/写失败 → 整单失败，明确报错，临时文件清理干净；
// - 目标文件已存在：默认在文件名后加 `（1）`、`（2）`……顺延
//   （不得静默覆盖用户原有文件）；调用方在另存为对话框里已取得
//   用户覆盖确认时，可传 `overwrite: true`，覆盖前须已完成临时文件
//   验证（不得先覆盖后验证）；
// - 失败不会破坏旧文件：重命名失败时旧文件原样保留（不先删旧文件
//   再移入——删后移入失败会丢旧文件）；Win11 上重命名覆盖已有文件
//   的实际行为列入 M4 真机清单验证。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'pdf_page_counter.dart';

/// 原子写入失败（整单失败，调用方按此文案向用户明确报错）。
class AtomicWriteException implements Exception {
  AtomicWriteException(this.message);

  /// 面向用户的明确说明。
  final String message;

  @override
  String toString() => 'AtomicWriteException: $message';
}

/// 临时文件验证（默认实现：存在、大小 > 0、PDF 可打开、页数与预期一致）。
///
/// 测试注入失败时传返回 false 的验证器（断言正式位置无半截文件、
// 原有文件未被破坏）；生产用默认实现。
typedef PdfFileValidator =
    Future<bool> Function(File file, int expectedPages);

/// 临时文件写盘步骤（默认实现：`writeAsBytes(bytes, flush: true)`）。
///
/// 测试注入写失败时传抛 [FileSystemException] 的写步骤（模拟磁盘满）。
typedef TempFileWriter =
    Future<void> Function(File tempFile, Uint8List bytes);

/// 目标冲突顺延：在文件名后加 `（1）`、`（2）`……直至不冲突。
///
/// [desired] 不存在时原样返回；存在时顺延（最多试 999 次，
// 仍冲突抛 [AtomicWriteException]）。顺延只在文件名干后、扩展名
// 前加后缀，不改动目录与扩展名。
File resolveTargetConflict(File desired) {
  if (!desired.existsSync()) return desired;
  final dir = desired.parent.path;
  final name = desired.uri.pathSegments.last;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var i = 1; i <= 999; i++) {
    final candidate = File(
      '$dir${Platform.pathSeparator}$stem（$i）$ext',
    );
    if (!candidate.existsSync()) return candidate;
  }
  throw AtomicWriteException(
    '目标位置已有同名文件，且无法自动生成新文件名：${desired.path}',
  );
}

/// 默认临时文件验证：存在、大小 > 0、PDF 可打开、页数与预期一致。
Future<bool> defaultPdfFileValidator(
  File file,
  int expectedPages,
) async {
  try {
    if (!file.existsSync()) return false;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return false;
    if (!isPdfBytes(bytes)) return false;
    final pages = countPdfPages(bytes);
    if (pages == null) return false;
    return pages == expectedPages;
  } catch (_) {
    return false;
  }
}

/// 原子写 PDF 到正式文件名（M2-2 流程）。
///
/// [target] 为正式目标文件；[bytes] 为已验证的 PDF 字节（`save()`
/// await 完成后的完整字节）；[expectedPages] 为预期页数（验证用）。
/// [overwrite] 为 true 时允许覆盖已存在的目标文件（仅当调用方已取得
/// 用户覆盖确认，如另存为对话框的确认；默认 false → 目标已存在时
/// 自动顺延命名）。返回实际落盘的文件（顺延时与 [target] 不同）。
///
/// 任一步骤失败都抛 [AtomicWriteException]，临时文件已清理，
/// 正式位置无半截文件、原有文件未被破坏。
Future<File> writePdfAtomically({
  required File target,
  required Uint8List bytes,
  required int expectedPages,
  bool overwrite = false,
  PdfFileValidator? validate,
  TempFileWriter? writeStep,
}) async {
  final validator = validate ?? defaultPdfFileValidator;
  final writer =
      writeStep ??
      ((File tempFile, Uint8List data) =>
          tempFile.writeAsBytes(data, flush: true));
  // 1. 目标目录须存在（不存在时尝试创建；创不出即整单失败）。
  final parent = target.parent;
  try {
    if (!parent.existsSync()) {
      await parent.create(recursive: true);
    }
  } on FileSystemException catch (e) {
    throw AtomicWriteException(
      '无法创建目标目录（${e.message}）：${parent.path}',
    );
  }
  // 2. 冲突策略在写盘前即确定：默认顺延；已确认覆盖时才用原名。
  final finalTarget = overwrite ? target : resolveTargetConflict(target);
  // 3. 临时文件与目标文件同一目录（同一文件系统/卷）。
  final tempFile = File(
    '${finalTarget.path}.tmp-'
    '${DateTime.now().millisecondsSinceEpoch}-'
    '${math.Random().nextInt(1 << 32)}',
  );
  try {
    // 4. 写临时文件并完整关闭。
    try {
      await writer(tempFile, bytes);
    } on FileSystemException catch (e) {
      throw AtomicWriteException(
        '写入临时文件失败（${e.message}），本次导出已中止，'
        '未生成半截 PDF。',
      );
    }
    // 5. 验证临时文件（存在、大小 > 0、PDF 可打开、页数与预期一致）。
    final ok = await validator(tempFile, expectedPages);
    if (!ok) {
      throw AtomicWriteException(
        '临时文件验证失败（文件损坏或页数与预期不一致），'
        '本次导出已中止，未生成半截 PDF。',
      );
    }
    // 6. 原子移动到正式文件名（验证已通过；覆盖情形下此时才动旧文件）。
    try {
      await tempFile.rename(finalTarget.path);
    } on FileSystemException catch (e) {
      throw AtomicWriteException(
        '保存文件失败（${e.message}），原有文件未被破坏。',
      );
    }
    return finalTarget;
  } finally {
    // 7. 残留临时文件一律清理（成功时 rename 已移走，existsSync 为 false）。
    try {
      if (tempFile.existsSync()) await tempFile.delete();
    } catch (_) {}
  }
}
