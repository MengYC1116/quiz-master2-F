// 十五批 M1-B：导出快照 ExportSnapshot（M1-DESIGN.md §2/§6，D-178/D-179）。
//
// 冻结内容（一次读齐，同一逻辑时刻）：筛选条件 + 题目 ID 列表 +
// 题目顺序（filteredAll() 顺序）+ 本次路线 + 50 道上限校验。
// - C 路线：每题的 OCR 文本块序列、图块引用（快照时从当前切片裁剪
//   到任务临时目录 + 内容哈希）、答案、解析、来源元数据；
// - A 路线：每题切片流式复制到任务临时目录（不一次性进内存）+
//   内容哈希；生成只读临时副本，读取时核对哈希。
// 任务结束（发布/取消/失败）后清理整个临时目录。
//
// 一致性策略（D-178：源文件版本冻结 + 终态复核，变化则整单失效）：
// 快照开始时记录全部源切片的内容哈希与相关 OCR 记录版本
// （contentVersion）；全部复制/裁剪完成后逐项复核，任一变化 →
// 整单失效，清理临时目录，明确报错“快照期间题目内容发生变化，
// 请重试”，不生成 PDF。逐题持锁只保证单题复制期间不被并发写入，
// 不能保证整批文件快照属于同一逻辑时刻——终态复核是真正的安全网，
// 能发现静默替换（备份恢复、文件替换）。
//
// 失败分类（D-179）：源损坏归题目级（C 跳过 / A BROKEN），快照副本
// 哈希不一致与临时目录写入失败归整单中止。
//
// 计数守恒（C-14，本文件只做快照层的一半）：选中题数 == 快照题数 +
// 排除题数；快照题数 == 正常印出 + 降级后印出 + BROKEN 占位 +
// 快照后 SKIPPED。快照包含全部非排除的选中题（含盘点已判 SKIPPED
// 的题，以 SKIPPED 条目记入报告，不建临时文件）；“正常/降级印出”
// 的区分在 M1-C/M1-D 生成时定，完整性报告层（export_integrity.dart）
// 做最终守恒核对。
import 'dart:io';
import 'dart:typed_data';

import 'content_guard.dart';
import 'export_question_record.dart';
import 'export_route.dart';
import 'ocr_content_snapshot.dart';
import 'pdf_document_builder.dart';
import 'slice_snapshot.dart';
import 'slice_write_guard.dart';
import 'snapshot_exceptions.dart';

/// 用户主动排除 / 清晰度门禁排除的题（占 50 名额，不计入快照题数）。
class ExcludedQuestion {
  const ExcludedQuestion({required this.id, required this.reason});

  /// 题目 ID。
  final String id;

  /// 排除原因（如“用户主动排除”“低于清晰度阈值，已排除”）。
  final String reason;
}

/// 快照内一题的初步结果（生成前的状态；COMPLETE/PARTIAL 的最终
/// 判定在 M1-C/M1-D 生成时做，见 export_integrity.dart）。
enum SnapshotOutcome {
  /// 将印出（C：可印；A：切片已复制）。
  ready,

  /// A 路线：源切片缺失/损坏/无法解码，印占位说明（BROKEN）。
  broken,

  /// 不印（C：无 OCR 结果 / 题干缺失 / 选项无法派生；或行已删除）。
  skipped,
}

/// 快照内一题的冻结条目（纯数据 + 临时文件引用）。
class SnapshotQuestionEntry {
  const SnapshotQuestionEntry({
    required this.questionId,
    required this.title,
    required this.outcome,
    required this.warnings,
    required this.sourceHash,
    required this.contentVersion,
    this.skipReason,
    this.sliceCopy,
    this.ocrContent,
    this.lowDpi = false,
    this.folderNames = const [],
    this.examName,
  });

  /// 题目 ID。
  final String questionId;

  /// 题目标题。
  final String title;

  /// 初步结果。
  final SnapshotOutcome outcome;

  /// 警告（降级内容、图块缺失、可疑标记等，供报告用）。
  final List<String> warnings;

  /// 源切片 SHA-256（快照时刻；切片缺失时为 null）。
  final String? sourceHash;

  /// 内容版本（快照时刻；行不存在时为 null）。
  final int? contentVersion;

  /// 不可印原因（outcome 为 skipped 时非空）。
  final String? skipReason;

  /// A 路线切片副本（outcome 为 ready/broken 时：ready 有值，
  /// broken 为 null）。
  final SliceCopyResult? sliceCopy;

  /// C 路线冻结内容（outcome 为 ready/skipped 时：ready 有值，
  /// skipped 为 null——跳过题不组装块序列）。
  final OcrContentSnapshot? ocrContent;

  /// A 路线：切片有效 DPI < 200（清晰度警告，PARTIAL 降级依据，§12）。
  final bool lowDpi;

  /// 归属文件夹展示名（M3-F：快照时刻冻结，[ExportQuestionRecord.folderNames]
  /// 的副本；快照后改文件夹不影响本次导出）。
  final List<String> folderNames;

  /// 考试展示名（M3-F：快照时刻冻结；null = 无考试）。
  final String? examName;

  /// 是否将印出。
  bool get isPrintable => outcome == SnapshotOutcome.ready;
}

/// 导出快照：一次导出的全部冻结内容（内存内结构，不入库、不进备份、
// 不做导出历史，C-10）。
class ExportSnapshot {
  ExportSnapshot._({
    required this.route,
    required this.filterText,
    required this.sortText,
    required this.questionIds,
    required this.excluded,
    required this.entries,
    required this.tempDir,
    required this.createdAt,
  });

  /// 本次路线（快照创建时冻结，中途 key 变化不切换）。
  final ExportRoute route;

  /// 冻结的筛选条件文字。
  final String filterText;

  /// 冻结的排序方式文字。
  final String sortText;

  /// 冻结的题目 ID 列表（filteredAll() 顺序，不含排除题）。
  final List<String> questionIds;

  /// 排除题（用户主动排除 / 清晰度门禁排除）。
  final List<ExcludedQuestion> excluded;

  /// 每题冻结条目（与 [questionIds] 同顺序；含 SKIPPED 条目）。
  final List<SnapshotQuestionEntry> entries;

  /// 任务临时目录（切片副本 / 图块裁图 / 公式位图所在目录）。
  final Directory tempDir;

  /// 快照创建时间。
  final DateTime createdAt;

  /// 快照题数（§2 第 3 点：生成结束核对计数守恒用）。
  int get questionCount => entries.length;

  /// 选中题数（= 快照题数 + 排除题数，C-14）。
  int get selectedCount => questionCount + excluded.length;

  /// 将印出题数。
  int get printableCount =>
      entries.where((e) => e.outcome == SnapshotOutcome.ready).length;

  /// BROKEN 占位题数（A 路线）。
  int get brokenCount =>
      entries.where((e) => e.outcome == SnapshotOutcome.broken).length;

  /// SKIPPED 题数（快照后仍不印的题）。
  int get skippedCount =>
      entries.where((e) => e.outcome == SnapshotOutcome.skipped).length;

  /// 计数守恒核对（C-14 快照层）：返回 null 表示守恒，否则返回
  ///  mismatch 描述（调用方按整单失败处理）。
  String? conservationError() {
    if (selectedCount != questionCount + excluded.length) {
      return '计数守恒失败：选中 $selectedCount ≠ 快照 $questionCount '
          '+ 排除 ${excluded.length}';
    }
    if (questionCount != printableCount + brokenCount + skippedCount) {
      return '计数守恒失败：快照 $questionCount ≠ 印出 $printableCount '
          '+ BROKEN $brokenCount + 跳过 $skippedCount';
    }
    return null;
  }

  /// 任务结束清理整个临时目录（发布/取消/失败后都调；失败静默，
  /// 不掩盖主流程的异常）。
  Future<void> dispose() async {
    // 删除失败时重试一次（M1-E：整文件跑时曾出现一次瞬时删不掉、
    // 残留 quiz-master2-pdf-export-* 目录；疑似与刚退出的生成
    // Isolate 的收尾时序有关；重试一次即可，仍失败则静默放弃，
    // 由调用方的残留检查/上层清理兜底）。
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
        return;
      } catch (_) {
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    }
  }

  /// 快照工厂（§2 第 3 点）：入口校验 `ids.length <= 50`，超限抛
  /// [ArgumentError]，不截断、不继续。
  ///
  /// [ids] 为选中的原始题目 ID（filteredAll() 顺序，含排除题；
  /// 跳过题仍占名额，C-14）；[excluded] 为其中被排除的题（用户
  /// 主动排除 / 清晰度门禁排除）；[source] 为数据源（M1-E 实现）；
  /// [tempRoot] 仅测试用（默认系统临时目录）。
  ///
  /// [recordsById]（D-186，单次读行）：调用方已读好的行记录
  /// （targetIds → 记录，缺题为 null），传了即复用、不再调
  /// `source.fetchQuestions` 二次读行；不传则内部一次读齐。
  /// 终态复核（阶段三）的第三次重读不受影响，仍从 source 重读。
  static Future<ExportSnapshot> fromSelection({
    required List<String> ids,
    required List<ExcludedQuestion> excluded,
    required ExportRoute route,
    required String filterText,
    required String sortText,
    required ExportQuestionSource source,
    SliceWriteGuard guard = SliceWriteGuard.instance,
    Directory? tempRoot,
    Map<String, ExportQuestionRecord?>? recordsById,
  }) async {
    if (ids.isEmpty) {
      throw ArgumentError('请至少选择 1 道题');
    }
    if (ids.length > kExportMaxQuestions) {
      throw ArgumentError('单次最多导出 50 道题');
    }
    if (ids.toSet().length != ids.length) {
      throw ArgumentError('选中题目 ID 重复');
    }
    final excludedIds = excluded.map((e) => e.id).toSet();
    if (!excludedIds.every(ids.contains)) {
      throw ArgumentError('排除题不在选中题目内');
    }
    final targetIds =
        ids.where((id) => !excludedIds.contains(id)).toList();

    // 任务临时目录（创建失败 → 基础设施失败，整单中止）。
    late final Directory tempDir;
    try {
      final root = tempRoot ?? Directory.systemTemp;
      tempDir = await root.createTemp('quiz-master2-pdf-export-');
      await Directory(
        '${tempDir.path}${Platform.pathSeparator}slices',
      ).create();
      await Directory(
        '${tempDir.path}${Platform.pathSeparator}figures',
      ).create();
    } on FileSystemException catch (e) {
      throw SnapshotInfrastructureException(
        '创建快照临时目录失败：${e.message}（${e.path ?? ''}）',
      );
    }

    try {
      final entries = await _buildEntries(
        targetIds: targetIds,
        route: route,
        source: source,
        guard: guard,
        tempDir: tempDir,
        recordsById: recordsById,
      );
      final snapshot = ExportSnapshot._(
        route: route,
        filterText: filterText,
        sortText: sortText,
        questionIds: targetIds,
        excluded: List.of(excluded),
        entries: entries,
        tempDir: tempDir,
        createdAt: DateTime.now(),
      );
      final error = snapshot.conservationError();
      if (error != null) {
        throw StateError(error);
      }
      return snapshot;
    } catch (_) {
      // 整单失败：清理临时目录后原样抛错。
      await _deleteQuietly(tempDir);
      rethrow;
    }
  }

  static Future<void> _deleteQuietly(Directory dir) async {
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// 逐题构建冻结条目 + 终态复核（D-178）。
  static Future<List<SnapshotQuestionEntry>> _buildEntries({
    required List<String> targetIds,
    required ExportRoute route,
    required ExportQuestionSource source,
    required SliceWriteGuard guard,
    required Directory tempDir,
    Map<String, ExportQuestionRecord?>? recordsById,
  }) async {
    // 阶段一：一次读齐行（同一逻辑时刻的冻结副本；行不存在 → 跳过）。
    // M3-F：走批量接口（生产实现一次读齐题目行 + 文件夹名 + 考试名）。
    // D-186：调用方传了 recordsById 即复用，不再二次 fetch。
    final records = recordsById != null
        ? [for (final id in targetIds) recordsById[id]]
        : await source.fetchQuestions(targetIds);

    // 阶段二：逐题持锁复制/裁剪（单题“读源 + 复制/裁剪 + 验哈希”
    // 在一次 withLock 内完成；整批不全程持锁）。
    final entries = <SnapshotQuestionEntry>[];
    for (var i = 0; i < targetIds.length; i++) {
      final record = records[i];
      if (record == null) {
        entries.add(
          SnapshotQuestionEntry(
            questionId: targetIds[i],
            title: '',
            outcome: SnapshotOutcome.skipped,
            warnings: const ['题目不存在'],
            sourceHash: null,
            contentVersion: null,
            skipReason: '题目不存在',
          ),
        );
        continue;
      }
      if (route == ExportRoute.a) {
        entries.add(
          await _buildAEntry(
            record: record,
            index: i,
            source: source,
            guard: guard,
            tempDir: tempDir,
          ),
        );
      } else {
        entries.add(
          await _buildCEntry(
            record: record,
            source: source,
            guard: guard,
            tempDir: tempDir,
          ),
        );
      }
    }

    // 阶段三：终态复核（D-178）——全部复制/裁剪完成后逐项复核源切片
    // 哈希与内容版本，任一变化 → 整单失效。
    await _verifyUnchanged(
      entries: entries,
      records: records,
      source: source,
      guard: guard,
    );
    return entries;
  }

  /// A 路线一题：流式复制切片到任务临时目录 + 哈希核对。
  static Future<SnapshotQuestionEntry> _buildAEntry({
    required ExportQuestionRecord record,
    required int index,
    required ExportQuestionSource source,
    required SliceWriteGuard guard,
    required Directory tempDir,
  }) async {
    final fileName =
        '$index-${_safeFileSegment(record.id)}.png';
    final target = File(
      '${tempDir.path}${Platform.pathSeparator}slices'
      '${Platform.pathSeparator}$fileName',
    );
    try {
      final result = await guard.withLock(
        () => SliceSnapshot.copySlice(
          source: source.openSliceBytes(record),
          targetFile: target,
          tempRelativePath: 'slices/$fileName',
        ),
      );
      final dpi = ContentGuard.effectiveDpi(
        widthPx: result.dimensions.width,
        displayWidthPt: PdfExportGeometry.contentWidthPt,
      );
      return SnapshotQuestionEntry(
        questionId: record.id,
        title: record.title,
        outcome: SnapshotOutcome.ready,
        warnings: _dpiWarnings(result.dimensions),
        sourceHash: result.sourceHash,
        contentVersion: record.contentVersion,
        sliceCopy: result,
        lowDpi: dpi < 200,
        folderNames: List.of(record.folderNames),
        examName: record.examName,
      );
    } on SliceUnavailableException catch (e) {
      // 源缺失/不可读：题目级 BROKEN，继续其余题。
      return SnapshotQuestionEntry(
        questionId: record.id,
        title: record.title,
        outcome: SnapshotOutcome.broken,
        warnings: [e.message],
        sourceHash: null,
        contentVersion: record.contentVersion,
        folderNames: List.of(record.folderNames),
        examName: record.examName,
      );
    } on SliceSourceCorruptException catch (e) {
      // 源不是合法 PNG：题目级 BROKEN，继续其余题。损坏源的哈希
      // 随条目记录，供终态复核比对（字节被换过 → 整单失效）。
      await _deleteFileQuietly(target);
      return SnapshotQuestionEntry(
        questionId: record.id,
        title: record.title,
        outcome: SnapshotOutcome.broken,
        warnings: [e.message],
        sourceHash: e.sourceHash,
        contentVersion: record.contentVersion,
        folderNames: List.of(record.folderNames),
        examName: record.examName,
      );
    }
    // SnapshotIntegrityException / SnapshotInfrastructureException
    // 不捕获：整单中止（由 fromSelection 清理临时目录后抛错）。
  }

  /// A 路线清晰度提示（§4/§11 门禁初值：< 200 警告、< 150 明显警告；
  /// 默认只警告、不排除；是否排除由 M3 面板勾选决定）。
  static List<String> _dpiWarnings(PngDimensions dimensions) {
    final dpi = ContentGuard.effectiveDpi(
      widthPx: dimensions.width,
      displayWidthPt: PdfExportGeometry.contentWidthPt,
    );
    if (dpi < 150) {
      return ['图片清晰度明显偏低（有效分辨率约 ${dpi.toStringAsFixed(0)} DPI）'];
    }
    if (dpi < 200) {
      return ['图片清晰度偏低（有效分辨率约 ${dpi.toStringAsFixed(0)} DPI）'];
    }
    return const [];
  }

  /// C 路线一题：读快照时刻切片字节（锁内）→ 组装冻结内容（锁外，
  /// 裁剪只读已冻结的内存字节，不碰共享文件）。
  static Future<SnapshotQuestionEntry> _buildCEntry({
    required ExportQuestionRecord record,
    required ExportQuestionSource source,
    required SliceWriteGuard guard,
    required Directory tempDir,
  }) async {
    Uint8List? sliceBytes;
    String? sliceHash;
    try {
      final bytes = await guard.withLock(() async {
        final builder = BytesBuilder();
        await for (final chunk in source.openSliceBytes(record)) {
          builder.add(chunk);
        }
        return builder.takeBytes();
      });
      sliceBytes = bytes;
      sliceHash = hashBytes(bytes);
    } on SliceUnavailableException {
      // 切片缺失：正文仍可印，图块无法裁剪（PARTIAL 降级，见 §12）。
      sliceBytes = null;
      sliceHash = null;
    } catch (_) {
      // 读流中途失败：同缺失处理（正文可印，图块略过）。
      sliceBytes = null;
      sliceHash = null;
    }
    final figureTempDir = Directory(
      '${tempDir.path}${Platform.pathSeparator}figures',
    );
    final ocr = await buildOcrContentSnapshot(
      record: record,
      sliceBytes: sliceBytes,
      sliceHash: sliceHash,
      figureTempDir: figureTempDir,
    );
    if (!ocr.printable) {
      return SnapshotQuestionEntry(
        questionId: record.id,
        title: record.title,
        outcome: SnapshotOutcome.skipped,
        warnings: List.of(ocr.warnings),
        sourceHash: sliceHash,
        contentVersion: record.contentVersion,
        skipReason: ocr.skipReason,
        ocrContent: null,
        folderNames: List.of(record.folderNames),
        examName: record.examName,
      );
    }
    return SnapshotQuestionEntry(
      questionId: record.id,
      title: record.title,
      outcome: SnapshotOutcome.ready,
      warnings: List.of(ocr.warnings),
      sourceHash: sliceHash,
      contentVersion: record.contentVersion,
      ocrContent: ocr,
      folderNames: List.of(record.folderNames),
      examName: record.examName,
    );
  }

  /// 终态复核（D-178）：逐项复核源切片哈希与内容版本。
  ///
  /// - 行消失 / 内容版本变化 / 源切片哈希变化 / 切片出现或消失 →
  ///   整单失效（SnapshotChangedException，固定文案）。
  /// - M3-F：文件夹归属与考试名同属冻结内容，变化同样整单失效
  ///   （与内容版本同一口径；快照后改文件夹/改考试名不影响本次导出
  ///   是指快照建成之后，建成过程中的变化仍须失效重建）。
  /// - 复核本身逐题持锁读源切片，不与写入入口交错读半写文件。
  static Future<void> _verifyUnchanged({
    required List<SnapshotQuestionEntry> entries,
    required List<ExportQuestionRecord?> records,
    required ExportQuestionSource source,
    required SliceWriteGuard guard,
  }) async {
    // 一次批量重读（生产实现一次读齐，不逐题 N+1）。
    final ids = [
      for (final r in records)
        if (r != null) r.id,
    ];
    final currents = await source.fetchQuestions(ids);
    final currentById = <String, ExportQuestionRecord?>{
      for (var i = 0; i < ids.length; i++) ids[i]: currents[i],
    };
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final record = records[i];
      if (record == null) continue; // 行本来就不存在，无可复核。
      final current = currentById[record.id];
      if (current == null) {
        throw SnapshotChangedException();
      }
      if (current.contentVersion != entry.contentVersion) {
        throw SnapshotChangedException();
      }
      if (!_stringListsEqual(current.folderNames, entry.folderNames) ||
          current.examName != entry.examName) {
        throw SnapshotChangedException();
      }
      final currentHash = await guard.withLock(() async {
        try {
          return await hashByteStream(source.openSliceBytes(current));
        } on SliceUnavailableException {
          return null;
        } catch (_) {
          return null;
        }
      });
      if (currentHash != entry.sourceHash) {
        throw SnapshotChangedException();
      }
    }
  }

  static Future<void> _deleteFileQuietly(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } catch (_) {}
  }
}

/// 文件名安全段（临时文件名用）：只留字母数字与 `._-`，其余换 `_`。
String _safeFileSegment(String value) {
  final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_').trim();
  return cleaned.isEmpty ? 'q' : cleaned;
}

/// 有序字符串列表相等（M3-F：终态复核比对文件夹归属用；顺序即
/// questions.folder_ids 的存储顺序）。
bool _stringListsEqual(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
