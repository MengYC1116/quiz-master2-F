// 十五批 M1-B：完整性状态与报告 M1-4（M1-DESIGN.md §12，C-14）。
//
// 两路线各一张表；报告为任务内纯数据，不存库、不进备份。
//
// C 路线：
// - COMPLETE：OCR 文本完整（题干 + 按题型应有的选项齐全）、全部公式
//   栅格化成功、图块位置已确认；
// - PARTIAL：可印但有降级（公式为原图、图块缺失或未确认、选项切分
//   不确定但已印），明确标记降级内容与警告；
// - SKIPPED：无 OCR 结果 / 题干缺失 / 选项无法派生 / 公式裁剪亦失败，
//   不印，只列入警告清单。
// A 路线：
// - COMPLETE：增强后切片正常印出；
// - PARTIAL：增强失败回退到 300 DPI 限制后图像（题面标“增强失败，
//   已用原图”）或低于清晰度阈值（已标记）；
// - BROKEN：源切片缺失/损坏/无法解码，印占位说明并列入缺失警告。
// 答案/解析缺失不影响正文状态（只影响答案版对应条目，M2）。
//
// 计数守恒（C-14）：全部被选中题最终恰好属于一个结果类别——
// 正常印出（COMPLETE）、降级后印出（PARTIAL）、BROKEN 占位、
// SKIPPED、用户主动排除或清晰度门禁排除。计数公式：
// 选中题数 == 快照题数 + 排除题数；
// 快照题数 == 正常印出 + 降级后印出 + BROKEN 占位 + 快照后 SKIPPED。
// 对不上即整单失败。
import 'export_route.dart';
import 'export_snapshot.dart';

/// 完整性状态（两路线共用一张枚举，BROKEN 只出现在 A 路线）。
enum IntegrityStatus {
  /// 正常印出。
  complete,

  /// 降级后印出。
  partial,

  /// BROKEN 占位（A 路线：源切片缺失/损坏/无法解码）。
  broken,

  /// 跳过，不印。
  skipped;

  /// 报告展示文案。
  String get label => switch (this) {
        IntegrityStatus.complete => '正常印出',
        IntegrityStatus.partial => '降级后印出',
        IntegrityStatus.broken => 'BROKEN 占位',
        IntegrityStatus.skipped => '跳过',
      };
}

/// C 路线完整性判定（纯函数）。
///
/// [printable] 为 false → SKIPPED；可印且任一降级成立 → PARTIAL；
/// 可印且无降级 → COMPLETE。
/// - [formulaOriginal]：任一公式为原图（渲染失败但裁剪成功，M1-C 填）；
/// - [figureMissing]：图块缺失或未确认；
/// - [optionUncertain]：选项切分不确定但已印；
/// - [contentParseFallback]：内容解析回退为纯文本。
IntegrityStatus classifyC({
  required bool printable,
  bool formulaOriginal = false,
  bool figureMissing = false,
  bool optionUncertain = false,
  bool contentParseFallback = false,
}) {
  if (!printable) return IntegrityStatus.skipped;
  if (formulaOriginal ||
      figureMissing ||
      optionUncertain ||
      contentParseFallback) {
    return IntegrityStatus.partial;
  }
  return IntegrityStatus.complete;
}

/// A 路线完整性判定（纯函数）。
///
/// [sliceOk] 为 false → BROKEN；切片正常且任一降级成立 → PARTIAL；
/// 切片正常且无降级 → COMPLETE。
/// - [enhanceFailedFallback]：增强失败回退到 300 DPI 限制后图像
///   （M1-D 填；内部状态区分“源切片原图”与“DPI 限制后未增强图”，
///   见 D-182）；
/// - [lowDpi]：低于清晰度阈值（已标记）。
IntegrityStatus classifyA({
  required bool sliceOk,
  bool enhanceFailedFallback = false,
  bool lowDpi = false,
}) {
  if (!sliceOk) return IntegrityStatus.broken;
  if (enhanceFailedFallback || lowDpi) return IntegrityStatus.partial;
  return IntegrityStatus.complete;
}

/// 完整性报告逐题条目（纯数据）。
class IntegrityEntry {
  const IntegrityEntry({
    required this.questionId,
    required this.title,
    required this.status,
    required this.warnings,
    this.skipReason,
  });

  /// 从快照条目建报告条目（M1-B 快照后的初步状态；公式栅格化与
  /// 增强结果在 M1-C/M1-D 生成时再定最终状态，见 [classifyC] /
  /// [classifyA] 的对应入参）。
  factory IntegrityEntry.fromSnapshotEntry(
    SnapshotQuestionEntry entry,
    ExportRoute route,
  ) {
    if (route == ExportRoute.c) {
      final ocr = entry.ocrContent;
      if (entry.outcome == SnapshotOutcome.skipped || ocr == null) {
        return IntegrityEntry(
          questionId: entry.questionId,
          title: entry.title,
          status: IntegrityStatus.skipped,
          warnings: List.of(entry.warnings),
          skipReason: entry.skipReason,
        );
      }
      return IntegrityEntry(
        questionId: entry.questionId,
        title: entry.title,
        status: classifyC(
          printable: true,
          figureMissing: ocr.hasFigureMissing,
          optionUncertain: ocr.hasOptionUncertain,
          contentParseFallback: ocr.contentParseFallback,
        ),
        warnings: List.of(entry.warnings),
      );
    }
    return IntegrityEntry(
      questionId: entry.questionId,
      title: entry.title,
      status: classifyA(
        sliceOk: entry.outcome != SnapshotOutcome.broken,
        lowDpi: entry.lowDpi,
      ),
      warnings: List.of(entry.warnings),
    );
  }

  /// 题目 ID。
  final String questionId;

  /// 题目标题。
  final String title;

  /// 完整性状态。
  final IntegrityStatus status;

  /// 警告（降级内容、跳过原因等）。
  final List<String> warnings;

  /// 跳过原因（status 为 skipped 时非空）。
  final String? skipReason;
}

/// 完整性报告（任务内输出，不存库）。
class IntegrityReport {
  const IntegrityReport({
    required this.route,
    required this.selectedCount,
    required this.snapshotCount,
    required this.excludedCount,
    required this.entries,
    required this.answersRecorded,
    required this.answersTotal,
    required this.explanationsRecorded,
    required this.explanationsTotal,
  });

  /// 从快照建报告（M1-B 快照后的初步报告；M1-C/M1-D 生成后按
  /// 最终状态重建，计数守恒口径不变）。
  ///
  /// 答案/解析已录入数在快照条目里没有（冻结内容只含正文所需字段），
  /// 调用方（M1-E，手里有冻结行记录）可经 [answersRecorded] /
  /// [explanationsRecorded] 传入；不传为 null（未知）。
  factory IntegrityReport.fromSnapshot(
    ExportSnapshot snapshot, {
    int? answersRecorded,
    int? explanationsRecorded,
  }) {
    final entries = [
      for (final e in snapshot.entries)
        IntegrityEntry.fromSnapshotEntry(e, snapshot.route),
    ];
    return IntegrityReport(
      route: snapshot.route,
      selectedCount: snapshot.selectedCount,
      snapshotCount: snapshot.questionCount,
      excludedCount: snapshot.excluded.length,
      entries: entries,
      answersRecorded: answersRecorded,
      answersTotal: snapshot.questionCount,
      explanationsRecorded: explanationsRecorded,
      explanationsTotal: snapshot.questionCount,
    );
  }

  /// 本次路线。
  final ExportRoute route;

  /// 选中题数。
  final int selectedCount;

  /// 快照题数。
  final int snapshotCount;

  /// 排除题数。
  final int excludedCount;

  /// 逐题状态。
  final List<IntegrityEntry> entries;

  /// 答案已录入数（快照层未知为 null；M1-E 生成答案版时覆盖，
  /// 见 [IntegrityReport.fromSnapshot] 注释）。
  final int? answersRecorded;

  /// 答案总数（= 快照题数）。
  final int answersTotal;

  /// 解析已录入数（同上）。
  final int? explanationsRecorded;

  /// 解析总数（= 快照题数）。
  final int explanationsTotal;

  /// 正常印出数。
  int get completeCount =>
      entries.where((e) => e.status == IntegrityStatus.complete).length;

  /// 降级后印出数。
  int get partialCount =>
      entries.where((e) => e.status == IntegrityStatus.partial).length;

  /// BROKEN 占位数。
  int get brokenCount =>
      entries.where((e) => e.status == IntegrityStatus.broken).length;

  /// SKIPPED 数。
  int get skippedCount =>
      entries.where((e) => e.status == IntegrityStatus.skipped).length;

  /// 跳过清单（只含 SKIPPED 条目）。
  List<IntegrityEntry> get skippedList =>
      entries.where((e) => e.status == IntegrityStatus.skipped).toList();

  /// 计数守恒核对（C-14）：返回 null 表示守恒，否则返回 mismatch 描述。
  String? conservationError() {
    if (selectedCount != snapshotCount + excludedCount) {
      return '计数守恒失败：选中 $selectedCount ≠ 快照 $snapshotCount '
          '+ 排除 $excludedCount';
    }
    if (entries.length != snapshotCount) {
      return '计数守恒失败：报告条目 ${entries.length} ≠ 快照题数 $snapshotCount';
    }
    final sum =
        completeCount + partialCount + brokenCount + skippedCount;
    if (snapshotCount != sum) {
      return '计数守恒失败：快照 $snapshotCount ≠ 正常印出 $completeCount '
          '+ 降级后印出 $partialCount + BROKEN 占位 $brokenCount '
          '+ 跳过 $skippedCount';
    }
    return null;
  }

  /// 计数守恒核对（对不上即整单失败，抛 [StateError]）。
  void checkConservationOrThrow() {
    final error = conservationError();
    if (error != null) {
      throw StateError(error);
    }
  }
}
