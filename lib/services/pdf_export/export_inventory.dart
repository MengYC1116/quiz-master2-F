// 十五批 M1-B：导出前盘点 M1-0（M1-DESIGN.md §5）。
//
// 盘点输出纯数据（供 M3 展示），不建快照、不生成 PDF、不写库。
// - C 路线：可印性判定四条（§5）+ NULL 四种情形 + guard 估算；
// - A 路线：切片可用性 + 有效 DPI 分布 + guard 估算；
// - 跳过清单完整展示、可滚动、不静默截断；跳过数 > 20 或跳过比例
//   > 50% 须二次确认的数据标记；
// - 可印题数为 0 → 不生成 PDF、不建快照（调用方据此拦截，见
//   [ExportInventory.hasPrintable]）。
//
// 四种题数区分（不得混用）：圈定题数（筛选范围）/ 已选题数（本次
// 选中，含排除题）/ 最终可印题数（盘点判定可印）/ 预计跳过题数
// （已选非排除中不可印的题）。跳过题仍占 50 名额（C-14）。
import '../../modules/ocr/ocr_figures.dart';
import '../../modules/ocr/question_content.dart';
import 'content_guard.dart';
import 'export_question_record.dart';
import 'export_route.dart';
import 'export_snapshot.dart';
import 'ocr_content_snapshot.dart';
import 'pdf_document_builder.dart';
import 'slice_snapshot.dart';

/// 盘点跳过清单的一项（每题：题号/标题 + 跳过原因；可点进详情页
/// 纠错/补 OCR，入口由 M3 接）。
class SkipEntry {
  const SkipEntry({
    required this.questionId,
    required this.title,
    required this.reason,
  });

  /// 题目 ID。
  final String questionId;

  /// 题目标题。
  final String title;

  /// 跳过原因（“无 OCR 结果” / “题干缺失” / “选项无法派生” /
  /// “切片不可用” / “题目不存在”）。
  final String reason;
}

/// 低可疑标记题清单的一项（C 路线：可印但标可疑，走纠错入口）。
class SuspiciousEntry {
  const SuspiciousEntry({
    required this.questionId,
    required this.title,
    required this.flags,
  });

  /// 题目 ID。
  final String questionId;

  /// 题目标题。
  final String title;

  /// 可疑标记（如 optionSplitUncertain）。
  final List<String> flags;
}

/// 低于清晰度阈值的题（A 路线清单）。
class LowDpiEntry {
  const LowDpiEntry({
    required this.questionId,
    required this.title,
    required this.dpi,
    required this.severe,
  });

  /// 题目 ID。
  final String questionId;

  /// 题目标题。
  final String title;

  /// 有效 DPI（按内容区宽 510.2 pt 算）。
  final double dpi;

  /// 是否明显偏低（< 150 DPI；false = < 200 DPI 警告档）。
  final bool severe;
}

/// 盘点输出（纯数据，供 M3 展示；不存库）。
class ExportInventory {
  const ExportInventory({
    required this.route,
    required this.routeReason,
    required this.circledCount,
    required this.selectedCount,
    required this.excluded,
    required this.printableCount,
    required this.skippedCount,
    required this.skipped,
    required this.suspicious,
    required this.lowDpi,
    required this.guard,
  });

  /// 本次路线。
  final ExportRoute route;

  /// 路由原因（“已配置 OCR key” / “未配置 OCR key”）。
  final String routeReason;

  /// 圈定题数（筛选范围大小）。
  final int circledCount;

  /// 已选题数（本次选中，含排除题，占 50 名额）。
  final int selectedCount;

  /// 排除题（用户主动排除 / 清晰度门禁排除）。
  final List<ExcludedQuestion> excluded;

  /// 最终可印题数（盘点判定）。
  final int printableCount;

  /// 预计跳过题数（已选非排除中不可印的题）。
  final int skippedCount;

  /// 跳过清单（完整，不截断）。
  final List<SkipEntry> skipped;

  /// 低可疑标记题清单（C 路线可印但标可疑的题）。
  final List<SuspiciousEntry> suspicious;

  /// 低于清晰度阈值题清单（A 路线）。
  final List<LowDpiEntry> lowDpi;

  /// guard 预估（总栅格 Mpx + 预估 save 增量 + 超阈值状态；
  /// 明确标注“估算值”，见 [ContentGuardResult.isEstimate]）。
  final ContentGuardResult guard;

  /// 是否可印题数为 0 → 不生成 PDF、不建快照。
  bool get hasPrintable => printableCount > 0;

  /// 是否须二次确认：跳过数 > 20 或跳过比例 > 50%
  /// （“将跳过 M / N 道题，确认继续吗？”；N = 已选题数）。
  bool get needsSecondConfirmation =>
      skippedCount > 20 ||
      (selectedCount > 0 && skippedCount / selectedCount > 0.5);

  /// 计数守恒核对（盘点层）：已选 == 排除 + 可印 + 跳过。
  String? conservationError() {
    if (selectedCount !=
        excluded.length + printableCount + skippedCount) {
      return '计数守恒失败：已选 $selectedCount ≠ 排除 ${excluded.length} '
          '+ 可印 $printableCount + 跳过 $skippedCount';
    }
    return null;
  }
}

/// 导出前盘点（M1-0）。
///
/// [decision] 为路由判定结果；[circledCount] 为筛选范围题数；
/// [selected] 为本次选中的题目行（filteredAll() 顺序，含排除题，
/// ≤ 50）；[excluded] 为其中被排除的题；[source] 为数据源
/// （A 路线读切片头用；C 路线不读文件）。
Future<ExportInventory> runInventory({
  required ExportRouteDecision decision,
  required int circledCount,
  required List<ExportQuestionRecord> selected,
  required List<ExcludedQuestion> excluded,
  required ExportQuestionSource source,
}) async {
  final excludedIds = excluded.map((e) => e.id).toSet();
  final targets =
      selected.where((r) => !excludedIds.contains(r.id)).toList();
  final skipped = <SkipEntry>[];
  final suspicious = <SuspiciousEntry>[];
  final lowDpi = <LowDpiEntry>[];
  final guardItems = <GuardRasterItem>[];
  var printableCount = 0;

  for (final record in targets) {
    if (decision.route == ExportRoute.c) {
      final p = assessCPrintability(record);
      if (!p.printable) {
        skipped.add(
          SkipEntry(
            questionId: record.id,
            title: record.title,
            reason: p.skipReason ?? '选项无法派生',
          ),
        );
        guardItems.add(
          GuardRasterItem(
            questionId: record.id,
            title: record.title,
            rasterMpx: 0,
          ),
        );
        continue;
      }
      printableCount++;
      if (p.suspiciousFlags.isNotEmpty) {
        suspicious.add(
          SuspiciousEntry(
            questionId: record.id,
            title: record.title,
            flags: List.of(p.suspiciousFlags),
          ),
        );
      }
      guardItems.add(
        GuardRasterItem(
          questionId: record.id,
          title: record.title,
          rasterMpx: _estimateCQuestionMpx(record, p),
        ),
      );
    } else {
      final head = await source.readSliceHead(record);
      final dims =
          head == null ? null : readPngDimensions(head);
      if (dims == null) {
        skipped.add(
          SkipEntry(
            questionId: record.id,
            title: record.title,
            reason: '切片不可用',
          ),
        );
        guardItems.add(
          GuardRasterItem(
            questionId: record.id,
            title: record.title,
            rasterMpx: 0,
          ),
        );
        continue;
      }
      printableCount++;
      final dpi = ContentGuard.effectiveDpi(
        widthPx: dims.width,
        displayWidthPt: PdfExportGeometry.contentWidthPt,
      );
      if (dpi < 200) {
        lowDpi.add(
          LowDpiEntry(
            questionId: record.id,
            title: record.title,
            dpi: dpi,
            severe: dpi < 150,
          ),
        );
      }
      guardItems.add(
        GuardRasterItem(
          questionId: record.id,
          title: record.title,
          rasterMpx: ContentGuard.rasterMpxForSlice(
            widthPx: dims.width,
            heightPx: dims.height,
          ),
        ),
      );
    }
  }

  final inventory = ExportInventory(
    route: decision.route,
    routeReason: decision.reason,
    circledCount: circledCount,
    selectedCount: selected.length,
    excluded: List.of(excluded),
    printableCount: printableCount,
    skippedCount: skipped.length,
    skipped: skipped,
    suspicious: suspicious,
    lowDpi: lowDpi,
    guard: ContentGuard.evaluate(guardItems, isEstimate: true),
  );
  final error = inventory.conservationError();
  if (error != null) {
    throw StateError(error);
  }
  return inventory;
}

/// 一道 C 路线题的盘点估算栅格量（Mpx，估算值）。
///
/// 公式计数取组装后 Markdown 的块序列（与快照同一组装口径，
/// 见 assembleCMarkdown）；图块按 bbox 与切片尺寸估算。
double _estimateCQuestionMpx(
  ExportQuestionRecord record,
  CPrintability printability,
) {
  final assembled = assembleCMarkdown(record, printability);
  List<QuestionContentBlock> blocks;
  try {
    blocks = parseQuestionContent(assembled);
  } catch (_) {
    // 解析异常时按纯文本计：公式数为 0（与快照回退口径一致）。
    blocks = const [];
  }
  var inlineCount = 0;
  var displayCount = 0;
  for (final block in blocks) {
    if (block is FormulaBlock) {
      if (block.displayMode) {
        displayCount++;
      } else {
        inlineCount++;
      }
    }
  }
  final figures = parseOcrFigures(record.ocrFigures);
  return ContentGuard.estimateCQuestionMpx(
    inlineFormulaCount: inlineCount,
    displayFormulaCount: displayCount,
    figureBboxes: [
      for (final f in figures)
        if (f.bbox2d.length == 4)
          (
            x1: f.bbox2d[0],
            y1: f.bbox2d[1],
            x2: f.bbox2d[2],
            y2: f.bbox2d[3],
            spaceW: f.spaceWidth,
            spaceH: f.spaceHeight,
          ),
    ],
    sliceWidthPx: record.sliceWidth ?? 0,
    sliceHeightPx: record.sliceHeight ?? 0,
  );
}
