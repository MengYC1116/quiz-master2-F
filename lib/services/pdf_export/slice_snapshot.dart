// 十五批 M1-B：A 路线切片快照（M1-DESIGN.md §5/§6，D-179）。
//
// 快照创建时把每道题的切片文件流式复制到任务临时目录（不一次性进
// 内存），并记录内容哈希（SHA-256，package:crypto 已是直接依赖）；
// 生成只读临时副本，读取时核对哈希。
//
// 失败分类（D-179，REV2 统一口径）：
// - 源数据缺失/损坏/无法解码（源文件本身问题，复制前即发现）→
//   题目级处理（A：BROKEN 占位 + 警告），继续导出；
// - 已成功创建的快照副本哈希不一致（复制完成后复核发现临时副本与源
//   不一致）→ 快照完整性失败，中止本次任务并清理临时目录；
// - 任务临时目录写入失败、磁盘满、权限不足 → 快照基础设施失败，
//   中止本次任务并清理临时目录。
//
// PNG 结构检查只做“可解码”的廉价近似（签名 + IHDR 合法 + 含 IEND
// 块头扫描，不全图解码）：真正的像素级解码失败在 M1-D 嵌入时才暴露，
// 按 §11 判 BROKEN。盘点阶段不得为“可解码”把 50 张切片全解进内存。
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'snapshot_exceptions.dart';

/// PNG 文件头尺寸（只读 IHDR 用，不全图解码）。
const int kPngHeadReadBytes = 64;

/// PNG 尺寸（IHDR 里的宽高，像素）。
typedef PngDimensions = ({int width, int height});

/// PNG 签名（8 字节）。
const _pngSignature = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// 从字节头读 PNG IHDR 宽高（不全图解码）。
///
/// 返回 null 的情形：不是 PNG、头不足 33 字节、首块不是 IHDR、
// 宽高非法、位深/颜色类型不在 PNG 规范值域内。
PngDimensions? readPngDimensions(Uint8List bytes) {
  if (bytes.length < 33) return null;
  for (var i = 0; i < _pngSignature.length; i++) {
    if (bytes[i] != _pngSignature[i]) return null;
  }
  // 首块必须是 IHDR：块类型在偏移 12–15。
  if (bytes[12] != 0x49 || // I
      bytes[13] != 0x48 || // H
      bytes[14] != 0x44 || // D
      bytes[15] != 0x52) {
    return null;
  }
  final width =
      (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
  final height =
      (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
  if (width <= 0 || height <= 0) return null;
  final bitDepth = bytes[24];
  final colorType = bytes[25];
  if (!const {1, 2, 4, 8, 16}.contains(bitDepth)) return null;
  if (!const {0, 2, 3, 4, 6}.contains(colorType)) return null;
  return (width: width, height: height);
}

/// 流式哈希：不一次性进内存（db_backup.dart 同款 `sha256.bind().first`）。
Future<String> hashByteStream(Stream<List<int>> stream) async {
  final digest = await sha256.bind(stream).first;
  return digest.toString();
}

/// 内存字节的 SHA-256（小对象用，如已读入的单张切片）。
String hashBytes(Uint8List bytes) => sha256.convert(bytes).toString();

/// 切片流式复制结果（纯数据）。
class SliceCopyResult {
  const SliceCopyResult({
    required this.tempRelativePath,
    required this.sourceHash,
    required this.tempHash,
    required this.byteCount,
    required this.dimensions,
  });

  /// 临时副本相对路径（任务临时目录内，如 `slices/<题 ID>.png`）。
  final String tempRelativePath;

  /// 源切片 SHA-256（复制时流式算出）。
  final String sourceHash;

  /// 临时副本 SHA-256（复制后重读算出；与 sourceHash 一致才算成功）。
  final String tempHash;

  /// 字节数。
  final int byteCount;

  /// 切片像素尺寸（IHDR）。
  final PngDimensions dimensions;
}

/// A 路线切片快照：流式复制 + 哈希核对。
class SliceSnapshot {
  SliceSnapshot._();

  /// 测试缝：复制写盘完成、验哈希之前调用（见 [copySlice] 内注释）。
  /// 生产代码永不设置；测试用完须置回 null。
  @visibleForTesting
  static Future<void> Function(File target)? debugOnTempCopied;

  /// 把源切片流式复制到任务临时目录并核对哈希。
  ///
  /// - [source]：源切片字节流（调用方在 SliceWriteGuard 锁内打开，
  ///   本函数只消费流，不另取锁）；
  /// - [targetFile]：临时副本目标文件（父目录须已存在）；
  /// - [tempRelativePath]：记入结果的相对路径。
  ///
  /// 成功返回复制结果（sourceHash == tempHash 已核对）。
  /// 临时副本哈希不一致 → 抛 [SnapshotIntegrityException]（整单中止）；
  /// 写入失败（磁盘满/权限不足等）→ 抛 [SnapshotInfrastructureException]
  /// （整单中止）。源流读失败（缺失/不可读）由调用方在复制前按题目级
  /// 处理（BROKEN），不进本函数。
  static Future<SliceCopyResult> copySlice({
    required Stream<List<int>> source,
    required File targetFile,
    required String tempRelativePath,
  }) async {
    var byteCount = 0;
    final head = <int>[];
    // 源哈希：边复制边流式算（db_backup.dart 同款 sha256.bind；
    // StreamController 把同一批 chunk 同时喂给哈希与写盘，内存只持
    // 一个 chunk，不一次性进内存）。
    final hashController = StreamController<List<int>>();
    final hashFuture = sha256.bind(hashController.stream).first;
    late final String sourceHash;
    try {
      final sink = targetFile.openWrite();
      try {
        // 读源流阶段抛错 = 源文件本身问题（缺失/读失败/中途损坏），
        // 归题目级（SliceSourceCorruptException）；写目标阶段抛错
        // （sink.close 冲刷失败，如磁盘满）归基础设施失败。
        // IOSink.add 是缓冲写，写失败一般在 close 时才暴露，因此
        // 循环体内只把源流异常包成源损坏，close 的异常另行处理。
        try {
          await for (final chunk in source) {
            if (chunk.isEmpty) continue;
            byteCount += chunk.length;
            hashController.add(chunk);
            if (head.length < kPngHeadReadBytes) {
              head.addAll(
                chunk.take(kPngHeadReadBytes - head.length),
              );
            }
            sink.add(chunk);
          }
        } catch (e) {
          if (e is SliceSourceCorruptException) rethrow;
          throw SliceSourceCorruptException('读取源切片失败：${e.runtimeType}');
        }
      } finally {
        try {
          await sink.close();
        } on FileSystemException catch (e) {
          throw SnapshotInfrastructureException(
            '写入快照临时副本失败：${e.message}（${e.path ?? ''}）',
          );
        }
      }
      await hashController.close();
      sourceHash = (await hashFuture).toString();
    } catch (_) {
      if (!hashController.isClosed) {
        await hashController.close();
      }
      rethrow;
    }
    // 测试缝（仅测试用）：写盘完成、验哈希之前调用，供测试模拟
    // “临时副本写盘后被外部改写”的场景（D-179：副本哈希不一致
    // 归整单中止）。生产代码永不设置。
    await debugOnTempCopied?.call(targetFile);
    final dimensions = readPngDimensions(Uint8List.fromList(head));
    if (dimensions == null) {
      // 流里读到的不是合法 PNG：源文件本身损坏，归题目级——调用方
      // 收到本异常后按 BROKEN 处理（不整单中止）。用源损坏异常
      // 与整单中止的完整性异常区分。源哈希随异常带出，供终态复核
      // 用（损坏源的字节同样要复核：复核时哈希变了说明源被换过）。
      throw SliceSourceCorruptException(
        '源切片不是合法 PNG（IHDR 无法解析）',
        sourceHash: sourceHash,
      );
    }
    // 复核：重读临时副本算哈希，与源哈希比对。
    late final String tempHash;
    try {
      tempHash = await hashByteStream(targetFile.openRead());
    } on FileSystemException catch (e) {
      throw SnapshotInfrastructureException(
        '读取快照临时副本失败：${e.message}（${e.path ?? ''}）',
      );
    }
    if (tempHash != sourceHash) {
      throw SnapshotIntegrityException(
        '快照副本哈希不一致（临时副本与源切片不符），本次导出中止。',
      );
    }
    return SliceCopyResult(
      tempRelativePath: tempRelativePath,
      sourceHash: sourceHash,
      tempHash: tempHash,
      byteCount: byteCount,
      dimensions: dimensions,
    );
  }

  /// 核对已存在的临时副本：重读算哈希，与期望哈希比对。
  ///
  /// 一致返回 true；不一致返回 false（调用方按 D-179 归整单中止，
  /// 不得静默用该副本生成）。
  static Future<bool> verifyTempCopy({
    required File tempFile,
    required String expectedHash,
  }) async {
    try {
      final actual = await hashByteStream(tempFile.openRead());
      return actual == expectedHash;
    } catch (_) {
      return false;
    }
  }
}

/// 源切片本身损坏（不是合法 PNG / 读不到 IHDR）：题目级处理（BROKEN），
/// 不整单中止。只在复制流内发现时抛；复制前即发现的缺失/不可读由
/// 数据源以 null/异常在锁内报告，同样归题目级。
///
/// [sourceHash]：损坏源字节的 SHA-256（流完整读完才有值；读流中途
/// 失败时为 null）。终态复核用它比对损坏源是否被换过——损坏源的
/// 字节变了同样是“快照期间内容发生变化”，不能因“反正已是 BROKEN”
/// 就放过。
class SliceSourceCorruptException implements Exception {
  SliceSourceCorruptException(this.message, {this.sourceHash});

  final String message;

  /// 损坏源字节的 SHA-256（未知时为 null）。
  final String? sourceHash;

  @override
  String toString() => 'SliceSourceCorruptException: $message';
}
