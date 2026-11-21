// 十五批 M1-B：内容 guard（M1-DESIGN.md §3，C-5/C-13/D-176/D-181）。
//
// 纯函数层，不读库、不读文件、不做任何 I/O，可独立测试。
//
// 估算模型（S1b 实测）：预估 save 增量 ≈ 10 MB × 总栅格 Mpx（300 DPI
// 上限应用后的像素数）。阈值已定（Meng 2026-11-20 22:35）：
// 80 Mpx 软警告 / 150 Mpx 硬拒绝 / 单图 12 Mpx 警告。
// 阈值是初值：M1 实现后用真实样本复核，调阈值走决策日志，不静默改。
//
// 时序（REV2，D-181）：盘点阶段用估算值（结果明确标注“估算值”）；
// 快照完成后、生成开始前用实际栅格化像素数复核一次（实际值超硬阈值
// → 中止生成）。本文件提供同一评估函数给两阶段用（[isEstimate] 区分），
// 偏差记录见 [GuardDeviation]。
//
// 最终嵌入的全部栅格必须计入 guard（C-13）：A 路线切片、图块裁剪、
// 公式位图、公式原图降级图、增强回退图，均为 300 DPI 限制后像素数。
import 'pdf_document_builder.dart';

/// guard 软警告阈值：总栅格 > 80 Mpx（预估 save 增量约 800 MB）。
const double kGuardSoftWarnMpx = 80;

/// guard 硬拒绝阈值：总栅格 > 150 Mpx（预估 save 增量约 1.5 GB）。
const double kGuardHardRejectMpx = 150;

/// 单图警告阈值：单张图 > 12 Mpx（约整页 11 MP 手机照片）。
const double kGuardSingleImageWarnMpx = 12;

/// 估算模型：每 1 Mpx 嵌入栅格约 10 MB save 增量（S1b 实测）。
const double kGuardMbPerMpx = 10;

/// guard 评估结论。
enum ContentGuardStatus {
  /// 总栅格 ≤ 80 Mpx：正常继续。
  ok,

  /// 总栅格 > 80 Mpx：向导确认步明确提示，用户确认后才继续。
  softWarning,

  /// 总栅格 > 150 Mpx：阻断生成，不生成 PDF。
  hardReject,
}

/// 一道题的栅格量输入（估算值或实际值均可，见 [isEstimate]）。
class GuardRasterItem {
  const GuardRasterItem({
    required this.questionId,
    required this.title,
    required this.rasterMpx,
    this.isEstimate = true,
  });

  /// 题目 ID。
  final String questionId;

  /// 题目标题（仅供盘点清单展示用）。
  final String title;

  /// 本题栅格总量（Mpx，300 DPI 限制后像素数）。
  final double rasterMpx;

  /// 是否估算值（盘点阶段 true；快照后实际值复核 false）。
  final bool isEstimate;
}

/// guard 评估结果（纯数据，供 M3 展示；不存库）。
class ContentGuardResult {
  const ContentGuardResult({
    required this.totalRasterMpx,
    required this.estimatedSaveMb,
    required this.status,
    required this.oversizeQuestions,
    required this.singleImageWarnings,
    required this.isEstimate,
  });

  /// 总栅格（Mpx）。
  final double totalRasterMpx;

  /// 预估 save 增量（MB，= 总栅格 Mpx × 10 MB/Mpx）。
  final double estimatedSaveMb;

  /// 结论：正常 / 软警告 / 硬拒绝。
  final ContentGuardStatus status;

  /// 超阈值题清单：单图最大的前 5 道（按栅格量从大到小）。
  final List<GuardRasterItem> oversizeQuestions;

  /// 单图警告清单：单张图 > 12 Mpx 的题（逐题警告，不阻断）。
  final List<GuardRasterItem> singleImageWarnings;

  /// 本次结果是否估算值（盘点阶段 true；快照后实际值复核 false）。
  ///
  /// 盘点输出必须明确标注“估算值”（D-181）。
  final bool isEstimate;

  /// 是否硬拒绝（总栅格 > 150 Mpx）。
  bool get isHardReject => status == ContentGuardStatus.hardReject;

  /// 是否软警告（总栅格 > 80 Mpx 且未超硬阈值）。
  bool get isSoftWarning => status == ContentGuardStatus.softWarning;

  /// 展示用文案（诚实口径：写“预计占用约 X MB”，不得写“保证成功”；
  /// 50 道上限本身也不是安全保证，见 C-2）。
  String get estimateNote =>
      '预计占用约 ${estimatedSaveMb.toStringAsFixed(0)} MB'
      '${isEstimate ? '（估算值）' : ''}';
}

/// 估算值与实际值的偏差记录（§15 V-内存：记入验证记录，尤其 C 路线）。
class GuardDeviation {
  const GuardDeviation({
    required this.estimatedMpx,
    required this.actualMpx,
    this.actualSaveMb,
  });

  /// 盘点估算的总栅格（Mpx）。
  final double estimatedMpx;

  /// 快照后实际的总栅格（Mpx）。
  final double actualMpx;

  /// 实测 save 增量（MB，有实测时才填；生成前复核时未知，留 null）。
  final double? actualSaveMb;

  /// 偏差（Mpx，实际 − 估算）。
  double get deltaMpx => actualMpx - estimatedMpx;

  /// 相对偏差（实际 ÷ 估算 − 1；估算为 0 时为 null）。
  double? get deltaRatio =>
      estimatedMpx == 0 ? null : actualMpx / estimatedMpx - 1;
}

/// 内容 guard：栅格总量 → 预估 save 增量 → 软警告 / 硬拒绝判定。
class ContentGuard {
  ContentGuard._();

  /// 300 DPI 上限对应的显示宽度像素数（内容区宽 510.2 pt → 约 2126 px）。
  ///
  /// 上限像素 = 显示宽 pt ÷ 72 × 300（§4）。窄图按实际显示宽度算，
  /// 调用方传入实际显示宽度。
  static int dpiCapWidthPx(double displayWidthPt) =>
      (displayWidthPt / 72 * 300).round();

  /// 有效分辨率（DPI）= 图片像素数 ÷ PDF 中的物理显示尺寸（英寸）。
  static double effectiveDpi({
    required int widthPx,
    required double displayWidthPt,
  }) =>
      widthPx / (displayWidthPt / 72);

  /// 应用 300 DPI 上限后的像素数（§4）：
  /// 超了下采样（按显示宽度等比缩），低了不得放大。
  ///
  /// [displayWidthPt] 是图片在 PDF 中的物理显示宽度（A 路线整题图
  /// 与 C 路线图块默认取内容区宽 510.2 pt；窄图按实际显示宽度算）。
  static int cappedRasterPixels({
    required int widthPx,
    required int heightPx,
    double displayWidthPt = 510.2,
  }) {
    if (widthPx <= 0 || heightPx <= 0) return 0;
    final capW = dpiCapWidthPx(displayWidthPt);
    if (widthPx <= capW) return widthPx * heightPx;
    final scaledH = heightPx * capW / widthPx;
    return (capW * scaledH).round();
  }

  /// 评估一组题的栅格总量（盘点估算与快照后实际复核共用）。
  ///
  /// 全部输入必须已是 300 DPI 限制后像素数（C-13）；[isEstimate]
  /// 标记本次输入是估算值还是实际值。
  static ContentGuardResult evaluate(
    List<GuardRasterItem> items, {
    bool isEstimate = true,
  }) {
    var total = 0.0;
    for (final item in items) {
      total += item.rasterMpx;
    }
    final status = total > kGuardHardRejectMpx
        ? ContentGuardStatus.hardReject
        : total > kGuardSoftWarnMpx
            ? ContentGuardStatus.softWarning
            : ContentGuardStatus.ok;
    final sorted = List<GuardRasterItem>.of(items)
      ..sort((a, b) => b.rasterMpx.compareTo(a.rasterMpx));
    return ContentGuardResult(
      totalRasterMpx: total,
      estimatedSaveMb: total * kGuardMbPerMpx,
      status: status,
      oversizeQuestions: sorted.take(5).toList(),
      singleImageWarnings: sorted
          .where((i) => i.rasterMpx > kGuardSingleImageWarnMpx)
          .toList(),
      isEstimate: isEstimate,
    );
  }

  /// 估算与实际 save 增量的偏差记入验证记录（§3/C-13）。
  ///
  /// 生成前复核时 [actualSaveMb] 未知（save() 还没跑），留 null；
  /// 生成后有实测 save 增量时再补填。
  static GuardDeviation compareEstimateVsActual({
    required double estimatedMpx,
    required double actualMpx,
    double? actualSaveMb,
  }) =>
      GuardDeviation(
        estimatedMpx: estimatedMpx,
        actualMpx: actualMpx,
        actualSaveMb: actualSaveMb,
      );

  // ------------------------------------------------------------------
  // C 路线盘点估算（§3 时序：盘点时公式位图尚未栅格化，按显示尺寸
  // × 300 DPI 估算，均为估算值；快照后用实际像素数复核）。
  // ------------------------------------------------------------------

  /// 行内公式估算像素数：按正文字号高度渲染（11 pt → 300 DPI 约 45.8 px
  /// 高），宽度按 4 倍高度估算（短行内公式的典型量级）。
  static double estimateInlineFormulaPx() {
    final heightPx = PdfExportTypography.bodyPt / 72 * 300;
    return heightPx * (heightPx * 4);
  }

  /// 独立公式估算像素数：按内容宽渲染，高度按 2 行正文估算。
  static double estimateDisplayFormulaPx() {
    final widthPx = PdfExportGeometry.contentWidthPt / 72 * 300;
    final heightPx = PdfExportTypography.bodyPt / 72 * 300 * 2;
    return widthPx * heightPx;
  }

  /// 一道 C 路线题的盘点估算栅格量（Mpx）。
  ///
  /// - 公式：行内公式与独立公式分别按显示尺寸 × 300 DPI 估算；
  /// - 图块：按 bbox 裁剪像素数，再按 300 DPI 上限（显示宽度取内容区
  ///   宽——图块实际显示可能更窄，用内容区宽是偏保守的高估，guard
  ///   宁可高估不可低估）。
  /// [figureBboxes] 每项为 (x1, y1, x2, y2, spaceWidth, spaceHeight)，
  /// 坐标为 0–1000 空间；space 尺寸未知时回退用切片尺寸。
  static double estimateCQuestionMpx({
    required int inlineFormulaCount,
    required int displayFormulaCount,
    required List<({int x1, int y1, int x2, int y2, int? spaceW, int? spaceH})>
        figureBboxes,
    required int sliceWidthPx,
    required int sliceHeightPx,
  }) {
    var pixels = inlineFormulaCount * estimateInlineFormulaPx() +
        displayFormulaCount * estimateDisplayFormulaPx();
    for (final b in figureBboxes) {
      final spaceW = b.spaceW ?? sliceWidthPx;
      final spaceH = b.spaceH ?? sliceHeightPx;
      if (spaceW <= 0 || spaceH <= 0) continue;
      final cropW = ((b.x2 - b.x1) / 1000 * spaceW).round();
      final cropH = ((b.y2 - b.y1) / 1000 * spaceH).round();
      if (cropW <= 0 || cropH <= 0) continue;
      pixels += cappedRasterPixels(
        widthPx: cropW,
        heightPx: cropH,
        displayWidthPt: PdfExportGeometry.contentWidthPt,
      );
    }
    return pixels / 1000000;
  }

  /// 一道 A 路线题的栅格量（Mpx）：切片像素数应用 300 DPI 上限后。
  static double rasterMpxForSlice({
    required int widthPx,
    required int heightPx,
  }) =>
      cappedRasterPixels(
            widthPx: widthPx,
            heightPx: heightPx,
            displayWidthPt: PdfExportGeometry.contentWidthPt,
          ) /
          1000000;
}
