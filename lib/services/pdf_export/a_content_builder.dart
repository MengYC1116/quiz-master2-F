// 十五批 M1-D：A 路线内容构建器（M1-DESIGN.md §7/§10/§11/§12）。
//
// 两遍布局：先 [AContentBuilder.planQuestions] 做完整分页规划
// （总页数 + 每页内容 + 断点位置），再按已知总页数渲染，页脚写
// “第 x / y 页”。分页结果确定性：同一快照两次生成，分页一致。
//
// A 路线图片硬切（§10，P2-2 继承）：
// - 题高 > 一页内容区 → 按原始图片坐标分段，保留原始像素，不缩小整题；
// - 固定缩放比例：整题先确定统一显示缩放比例（内容区宽 ÷ 上限后图宽），
//   所有分页片段用同一比例，按每页实际可用高度换算原图切割坐标，
//   片段之间不得遗漏或重叠，续页标识占用的空间须从该页图片可用高度中
//   扣除，不得每页重新计算图片缩放比例；
// - 切分约束：图块不得与题干内容合并成一张长图后再切（A 路线无图块，
//   整题即单张切片）；上下片段显示比例须一致；
// - 空白区检测（水平投影找低墨量切割点）不在 v1 做；v1 硬切 + 续页标识
//   即为完整实现。
//
// 渲染机制（§7 骨架 + pdf 3.13.1 实测）：每页规划内容包成一个固定高度
// 的 Container，再包 Inseparable(canSpan: false)，作为 MultiPage 的
// 一个子件——Container 包 Column 会跨页拆分（SingleChildWidget.canSpan
// 委托给子件），不包 Inseparable 会把一页内容拆散；固定高度保证
// MultiPage 按规划一页一个子件流排，不重排不断页。容器高度 =
// 内容区高 − 页眉/页脚预留 40pt（单行 10pt 文本实测约 14.52pt，
// 页眉 + 页脚合计约 29.04pt；40pt 预留留约 11pt 余量。D-183：原 32pt
// 预留余量仅约 3pt，且页眉学科名换行会顶破预留——学科名现已截断
// 单行（见 PdfExportHeaderInfo.line），页眉恒为单行。
// 注意：若实际页眉/页脚合计超过预留，容器在新页也放不下时，Release
// 下 MultiPage 不会抛错（maxPages 保护在 assert 内），而是无限翻页
// 直至 OOM——旧注释“会抛错”是错的；预留 + 截断即为本路线的主防线，
// 生成超时看门狗（PdfExportService）为兜底。
// 第一页导出信息区在第一页容器内（固定 75pt），不另占子件。
//
// 准备阶段（本文件内）：逐题读快照临时副本 → 验哈希（D-179：副本不
// 一致 → 整单中止）→ 增强（[ImageEnhancer]）→ 增强后 PNG 写任务
// 临时目录 enhanced/（快照 dispose 时一并清理）。只做一次全分辨率
// 解码（准备阶段）；渲染阶段只解码上限后图像再裁剪分段。增强只作用
// 于临时副本，库里原切片不动。
//
// 门禁（§11）：增强成功但清晰度门禁不通过 → 该题跳过（不回退，
// D-167 边界）；默认只警告、不排除，面板勾选排除（M3）时才跳过，
// 由 [ImageEnhancer.shouldSkipForClarity] 判定。
// 源切片缺失/损坏/无法解码 → 该题 BROKEN（占位 + 警告，继续其余题）。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'export_integrity.dart';
import 'export_route.dart';
import 'export_snapshot.dart';
import 'image_enhancer.dart';
import 'pdf_document_builder.dart';
import 'slice_snapshot.dart';
import 'snapshot_exceptions.dart';
import 'text_pagination.dart';

/// MultiPage 页眉/页脚扣减预留（pt，D-183：40pt）。
///
/// MultiPage 在每页新建时把页眉/页脚高度从内容区扣掉；单行 10pt
/// 文本实测高约 14.52pt，页眉 + 页脚合计约 29.04pt，40pt 预留留
/// 约 11pt 余量（原 32pt 仅余约 3pt）。页眉学科名已截断单行
/// （PdfExportHeaderInfo.line），页眉恒为单行，本预留为有效上限。
/// 容器高度 = 内容区高 − 40。
const double kAHeaderFooterReservePt = 40;

/// 第一页导出信息区固定高度（pt）：5 行 × 15pt。
const double kAInfoZoneHeightPt = 75;

/// 题号行固定高度（pt）：13pt × 1.5 行距 + 6pt 间距。
const double kAQuestionNumberHeightPt = 25.5;

/// 续页标行固定高度（pt）：11pt × 1.5 + 6pt。
const double kAContinuationLabelHeightPt = 22.5;

/// 「本题完」行固定高度（pt）：同续页标。
const double kAEndLabelHeightPt = 22.5;

/// BROKEN 占位块固定高度（pt）：题号行 25.5 + 占位说明 2 行 × 16.5。
const double kABrokenBlockHeightPt = 58.5;

/// 来源行固定高度（pt）：与 C 路线同一口径（M3-F：逐题来源行
/// “学科 / 文件夹 / 考试名”，单行；D-183：超长截断加省略号，
/// 单行硬约束，与 C 路线分页器的单行假设一致）。
const double kASourceLineHeightPt = kPdfSourceLineHeightPt;

/// 题间分隔固定高度（pt）：9.5pt 空白 + 0.5pt 细灰线（§7 题间细灰线分隔）。
const double kAQuestionGapPt = 10;

/// 首段最小可用高度（pt）：当前页剩余不足此时整题移下一页，
// 不在页底留一条细缝。
const double kAMinFirstSegmentPt = 40;

/// 规划输入：一道题（300 DPI 上限后尺寸；BROKEN 题尺寸为 0）。
class APlanQuestion {
  const APlanQuestion({
    required this.questionId,
    required this.questionNumber,
    required this.cappedWidthPx,
    required this.cappedHeightPx,
    this.isBroken = false,
    this.brokenReason,
    this.sourceText = '',
  });

  /// 题目 ID。
  final String questionId;

  /// 导出内题号（仅印出题编号；跳过题不参与规划）。
  final int questionNumber;

  /// 300 DPI 上限后图宽（px）；BROKEN 题为 0。
  final int cappedWidthPx;

  /// 300 DPI 上限后图高（px）；BROKEN 题为 0。
  final int cappedHeightPx;

  /// 是否 BROKEN 占位块（不印图，只印占位说明）。
  final bool isBroken;

  /// BROKEN 原因（占位说明第二行）。
  final String? brokenReason;

  /// 逐题来源行文字（M3-F：“学科 / 文件夹 / 考试名”；空 = 不印来源行，
  /// 不占高度）。首段与 BROKEN 占位块印，续段不印（与 C 路线同口径）。
  final String sourceText;

  /// 是否印来源行。
  bool get hasSourceLine => sourceText.isNotEmpty;
}

/// 规划出的一段图片（A 路线硬切的最小单位）。
class APlannedSegment {
  const APlannedSegment({
    required this.questionId,
    required this.questionNumber,
    required this.segmentIndex,
    required this.segmentCount,
    required this.yStartPx,
    required this.heightPx,
    required this.displayHeightPt,
    required this.gapBeforePt,
    this.sourceText = '',
  });

  /// 题目 ID。
  final String questionId;

  /// 导出内题号。
  final int questionNumber;

  /// 本题内段序号（0 起）。
  final int segmentIndex;

  /// 本题总段数。
  final int segmentCount;

  /// 在上限后图像坐标系内的起始 y（px）。
  final int yStartPx;

  /// 段高（px）。
  final int heightPx;

  /// 段显示高度（pt，= heightPx × 统一缩放比例）。
  final double displayHeightPt;

  /// 本段之前的题间分隔高度（pt；同题续段与页首段为 0）。
  final double gapBeforePt;

  /// 逐题来源行文字（仅首段非空；续段为空，见 [isFirst]）。
  final String sourceText;

  /// 是否本题首段（题号行只出现在此段）。
  bool get isFirst => segmentIndex == 0;

  /// 是否本题末段（末段标「本题完」，仅多段题）。
  bool get isLast => segmentIndex == segmentCount - 1;
}

/// 规划出的一个 BROKEN 占位块。
class APlannedBroken {
  const APlannedBroken({
    required this.questionId,
    required this.questionNumber,
    required this.reason,
    required this.gapBeforePt,
    this.sourceText = '',
  });

  /// 题目 ID。
  final String questionId;

  /// 导出内题号。
  final int questionNumber;

  /// BROKEN 原因（占位说明第二行）。
  final String reason;

  /// 本块之前的题间分隔高度（pt；页首块为 0）。
  final double gapBeforePt;

  /// 逐题来源行文字（空 = 不印来源行，不占高度；与可印题同口径）。
  final String sourceText;
}

/// 规划出的一页（[items] 为 [APlannedSegment] / [APlannedBroken]，按序）。
class APlannedPage {
  const APlannedPage({
    required this.pageIndex,
    required this.isFirstPage,
    required this.items,
  });

  /// 页序号（0 起）。
  final int pageIndex;

  /// 是否第一页（第一页容器内含导出信息区）。
  final bool isFirstPage;

  /// 本页内容（段 / 占位块，按序）。
  final List<Object> items;
}

/// A 路线分页规划结果（纯数据；第一遍产物）。
class AContentPlan {
  const AContentPlan({required this.pages, required this.segmentsByQuestion});

  /// 规划出的页（按序）。
  final List<APlannedPage> pages;

  /// 每题段数（questionId → 段数；仅印出题）。
  final Map<String, int> segmentsByQuestion;

  /// 规划总页数（第二遍渲染时页脚的分母）。
  int get totalPages => pages.length;
}

/// 一道题的 A 路线生成结果（纯数据，供报告与 M1-E 用）。
class AQuestionBuildResult {
  const AQuestionBuildResult({
    required this.questionId,
    required this.title,
    required this.questionNumber,
    required this.status,
    required this.enhanceOutcome,
    required this.effectiveDpi,
    required this.clarity,
    required this.rasterPixels,
    required this.segmentCount,
    required this.warnings,
    this.skipReason,
  });

  /// 题目 ID。
  final String questionId;

  /// 题目标题。
  final String title;

  /// 导出内题号（0 = 未印出：跳过题）。
  final int questionNumber;

  /// 完整性状态（[classifyA] 口径；跳过题为 skipped）。
  final IntegrityStatus status;

  /// 增强结果种类（null = 未增强：源缺失 BROKEN / 门禁跳过前未增强？
  /// 门禁判定在增强后，故跳过题也有值；源缺失 BROKEN 为 null）。
  final EnhanceOutcome? enhanceOutcome;

  /// 有效分辨率（DPI；无法解码/源缺失为 0）。
  final double effectiveDpi;

  /// 清晰度门禁档位。
  final ClarityLevel clarity;

  /// 300 DPI 限制后像素数（guard 计入值，C-13）。
  final int rasterPixels;

  /// 段数（0 = 未印出）。
  final int segmentCount;

  /// 警告（降级内容、跳过原因等，供报告用）。
  final List<String> warnings;

  /// 跳过原因（status 为 skipped 时非空）。
  final String? skipReason;
}

/// A 路线生成结果（文档 + 规划 + 逐题结果）。
class ABuildResult {
  const ABuildResult({
    required this.document,
    required this.plan,
    required this.questions,
  });

  /// 已建好的 PDF 文档（调用方经 [PdfExportDocumentBuilder.savePdf]
  /// await 后得字节；完成前不得发布文件，C-7）。
  final pw.Document document;

  /// 分页规划（总页数 = 页脚分母）。
  final AContentPlan plan;

  /// 逐题结果（与快照条目同顺序，恰好覆盖全部快照题，C-14）。
  final List<AQuestionBuildResult> questions;

  /// 增强后印出数（COMPLETE + PARTIAL 中增强成功者）。
  int get enhancedCount => questions
      .where((q) => q.enhanceOutcome == EnhanceOutcome.enhanced)
      .length;

  /// 回退原图数（增强失败回退到 DPI 限制后图像者，PARTIAL）。
  int get fallbackCount => questions
      .where((q) => q.enhanceOutcome == EnhanceOutcome.fallbackCapped)
      .length;

  /// 低于清晰度阈值题数（已印出且 clarity != ok 者，PARTIAL）。
  int get lowDpiCount => questions
      .where(
        (q) =>
            q.status != IntegrityStatus.skipped &&
            q.status != IntegrityStatus.broken &&
            q.clarity != ClarityLevel.ok,
      )
      .length;

  /// BROKEN 占位数。
  int get brokenCount => questions
      .where((q) => q.status == IntegrityStatus.broken)
      .length;

  /// 跳过数（快照后 SKIPPED，含门禁排除）。
  int get skippedCount => questions
      .where((q) => q.status == IntegrityStatus.skipped)
      .length;

  /// 转完整性报告条目（与快照条目同顺序；M1-E 组装报告用）。
  List<IntegrityEntry> toIntegrityEntries() => [
        for (final q in questions)
          IntegrityEntry(
            questionId: q.questionId,
            title: q.title,
            status: q.status,
            warnings: List.of(q.warnings),
            skipReason: q.skipReason,
          ),
      ];
}

/// A 路线内容构建器（增强后切片 + 硬切分页，§10/§11）。
class AContentBuilder {
  AContentBuilder._();

  /// 每页容器固定高度（pt）= 内容区高 − 页眉/页脚预留 40pt。
  static double get pageContainerHeightPt =>
      PdfExportGeometry.contentHeightPt - kAHeaderFooterReservePt;

  /// 第一页图片可用高度（pt）= 容器高 − 信息区 75pt。
  static double get firstPageAvailableHeightPt =>
      pageContainerHeightPt - kAInfoZoneHeightPt;

  /// 其余页图片可用高度（pt）= 容器高。
  static double get otherPageAvailableHeightPt => pageContainerHeightPt;

  // ------------------------------------------------------------------
  // 第一遍：分页规划（纯函数，不解码、不读文件，可独立测试）。
  // ------------------------------------------------------------------

  /// A 路线分页规划（纯函数）。
  ///
  /// [questions] 为将印出的题（跳过题不传；BROKEN 题传 isBroken，
  /// 尺寸为 0）；题号由调用方事先按印出顺序编好（仅印出题编号）。
  /// 固定缩放比例：每题 scale = 内容区宽 ÷ 上限后图宽，全题共用；
  /// 段边界为整像素，首尾相接，无遗漏无重叠。
  static AContentPlan planQuestions({
    required List<APlanQuestion> questions,
    double? firstPageAvailableHeightPt,
    double? otherPageAvailableHeightPt,
  }) {
    final firstAvail =
        firstPageAvailableHeightPt ?? AContentBuilder.firstPageAvailableHeightPt;
    final otherAvail =
        otherPageAvailableHeightPt ?? AContentBuilder.otherPageAvailableHeightPt;
    if (firstAvail <= 0 || otherAvail <= 0) {
      throw ArgumentError('页面可用高度必须 > 0');
    }
    final pages = <APlannedPage>[];
    final segmentsByQuestion = <String, int>{};
    var pageIndex = 0;
    var available = firstAvail;
    var items = <Object>[];
    var used = 0.0;

    double remaining() => available - used;

    void flushPage() {
      if (items.isNotEmpty) {
        pages.add(
          APlannedPage(
            pageIndex: pageIndex,
            isFirstPage: pageIndex == 0,
            items: List.of(items),
          ),
        );
      }
    }

    void newPage() {
      flushPage();
      pageIndex++;
      available = otherAvail;
      items = <Object>[];
      used = 0.0;
    }

    for (final q in questions) {
      final sourceH =
          q.hasSourceLine ? kASourceLineHeightPt : 0.0;
      if (q.isBroken) {
        var gap = items.isEmpty ? 0.0 : kAQuestionGapPt;
        var need = gap + kABrokenBlockHeightPt + sourceH;
        if (need > remaining()) {
          newPage();
          gap = 0.0;
          need = kABrokenBlockHeightPt + sourceH;
        }
        items.add(
          APlannedBroken(
            questionId: q.questionId,
            questionNumber: q.questionNumber,
            reason: q.brokenReason ?? '源切片缺失',
            gapBeforePt: gap,
            sourceText: q.sourceText,
          ),
        );
        used += need;
        segmentsByQuestion[q.questionId] = 0;
        continue;
      }
      if (q.cappedWidthPx <= 0 || q.cappedHeightPx <= 0) {
        throw ArgumentError('题 ${q.questionId} 上限后尺寸非法');
      }
      // 固定缩放比例：整题共用（内容区宽 ÷ 上限后图宽）。
      final scale =
          PdfExportGeometry.contentWidthPt / q.cappedWidthPx;
      final displayH = q.cappedHeightPx * scale;

      // 整题放得下 → 单段。
      var gap = items.isEmpty ? 0.0 : kAQuestionGapPt;
      final singleNeed =
          gap + kAQuestionNumberHeightPt + sourceH + displayH;
      if (singleNeed <= remaining()) {
        items.add(
          APlannedSegment(
            questionId: q.questionId,
            questionNumber: q.questionNumber,
            segmentIndex: 0,
            segmentCount: 1,
            yStartPx: 0,
            heightPx: q.cappedHeightPx,
            displayHeightPt: displayH,
            gapBeforePt: gap,
            sourceText: q.sourceText,
          ),
        );
        used += singleNeed;
        segmentsByQuestion[q.questionId] = 1;
        continue;
      }

      // 硬切：首段用当前页剩余（扣题号行、来源行与题间分隔），不足 40pt 则整题
      // 移下一页；续段每段独占一页（扣续页标与「本题完」预留）。
      var firstCap =
          remaining() - gap - kAQuestionNumberHeightPt - sourceH;
      if (firstCap < kAMinFirstSegmentPt) {
        newPage();
        gap = 0.0;
        firstCap = remaining() - kAQuestionNumberHeightPt - sourceH;
      }
      // 先算全部段边界（整像素，首尾相接），再落页。
      final takes = <int>[];
      var left = q.cappedHeightPx;
      var capPx = math.max(1, (firstCap / scale).floor());
      while (left > 0) {
        final take = math.min(capPx, left);
        takes.add(take);
        left -= take;
        if (left > 0) {
          final contCap = otherAvail -
              kAContinuationLabelHeightPt -
              kAEndLabelHeightPt;
          capPx = math.max(1, (contCap / scale).floor());
        }
      }
      final segmentCount = takes.length;
      var yStart = 0;
      for (var i = 0; i < takes.length; i++) {
        final take = takes[i];
        final segH = take * scale;
        if (i == 0) {
          items.add(
            APlannedSegment(
              questionId: q.questionId,
              questionNumber: q.questionNumber,
              segmentIndex: 0,
              segmentCount: segmentCount,
              yStartPx: 0,
              heightPx: take,
              displayHeightPt: segH,
              gapBeforePt: gap,
              sourceText: q.sourceText,
            ),
          );
          used += gap + kAQuestionNumberHeightPt + sourceH + segH;
        } else {
          // 续段独占一页（前一页已无空间放下一段整段）。
          newPage();
          items.add(
            APlannedSegment(
              questionId: q.questionId,
              questionNumber: q.questionNumber,
              segmentIndex: i,
              segmentCount: segmentCount,
              yStartPx: yStart,
              heightPx: take,
              displayHeightPt: segH,
              gapBeforePt: 0,
            ),
          );
          used += kAContinuationLabelHeightPt +
              kAEndLabelHeightPt +
              segH;
        }
        yStart += take;
      }
      segmentsByQuestion[q.questionId] = segmentCount;
    }
    flushPage();
    return AContentPlan(pages: pages, segmentsByQuestion: segmentsByQuestion);
  }

  // ------------------------------------------------------------------
  // 第二遍：准备 + 渲染 + 组装文档。
  // ------------------------------------------------------------------

  /// 构建 A 路线整份 PDF 文档（准备 → 规划 → 渲染）。
  ///
  /// - [snapshot] 须为 A 路线快照（路由在快照创建时冻结，C-8）；
  /// - [excludeLowDpi] 为 M3 面板勾选“排除低于清晰度阈值的题”
  ///   （默认 false，只警告、不排除；勾选时门禁不通过 → 跳过，不回退）；
  /// - [excludeBelowDpi] 为排除阈值（默认 200 DPI）；
  /// - [sourceTextById] 为逐题来源行文字（M3-F：questionId →
  ///   “学科 / 文件夹 / 考试名”，调用方在主 Isolate 按与 C 路线
  ///   相同的口径拼好传入；缺省/空 = 不印来源行，不占高度）；
  /// - 增强后 PNG 写任务临时目录 enhanced/（快照 dispose 时清理）；
  /// - 快照副本哈希不一致 → 抛 [SnapshotIntegrityException]（整单中止，
  ///   D-179）；无可印题 → 抛 [StateError]（调用方据此拦截，见 §5）。
  /// - [totalPagesOverride]：答案版（M2-1）时题目区页脚分母须为
  ///   题目页 + 答案区页（答案区另起 MultiPage 接在后面，页码全局
  ///   连续）；不传时分母为规划页数（练习版原行为，不变）。
  static Future<ABuildResult> buildDocument({
    required ExportSnapshot snapshot,
    required PdfExportDocumentBuilder documentBuilder,
    required PdfExportMetadata metadata,
    required PdfExportHeaderInfo headerInfo,
    required PdfExportInfo info,
    bool excludeLowDpi = false,
    double excludeBelowDpi = kClarityWarnDpi,
    ImageEnhanceParams enhanceParams =
        const ImageEnhanceParams.defaults(),
    int? totalPagesOverride,
    Map<String, String> sourceTextById = const {},
  }) async {
    if (snapshot.route != ExportRoute.a) {
      throw ArgumentError('AContentBuilder 只接受 A 路线快照');
    }
    // 1. 准备：逐题验哈希 → 增强 → 写 enhanced/ 临时文件。
    final enhancedDir = Directory(
      '${snapshot.tempDir.path}${Platform.pathSeparator}enhanced',
    );
    try {
      await enhancedDir.create(recursive: true);
    } on FileSystemException catch (e) {
      throw SnapshotInfrastructureException(
        '创建增强临时目录失败：${e.message}（${e.path ?? ''}）',
      );
    }
    final prepared = <_PreparedQuestion>[];
    for (var i = 0; i < snapshot.entries.length; i++) {
      prepared.add(
        await _prepareEntry(
          entry: snapshot.entries[i],
          index: i,
          snapshot: snapshot,
          enhancedDir: enhancedDir,
          excludeLowDpi: excludeLowDpi,
          excludeBelowDpi: excludeBelowDpi,
          enhanceParams: enhanceParams,
        ),
      );
    }
    // 2. 编号（仅印出题：可印图像题 + BROKEN 占位，按快照顺序）。
    var number = 0;
    final planInputs = <APlanQuestion>[];
    for (final p in prepared) {
      if (p.isSkipped) continue;
      number++;
      p.questionNumber = number;
      final sourceText = sourceTextById[p.entry.questionId] ?? '';
      if (p.isBroken) {
        planInputs.add(
          APlanQuestion(
            questionId: p.entry.questionId,
            questionNumber: number,
            cappedWidthPx: 0,
            cappedHeightPx: 0,
            isBroken: true,
            brokenReason: p.brokenReason,
            sourceText: sourceText,
          ),
        );
      } else {
        planInputs.add(
          APlanQuestion(
            questionId: p.entry.questionId,
            questionNumber: number,
            cappedWidthPx: p.cappedWidthPx,
            cappedHeightPx: p.cappedHeightPx,
            sourceText: sourceText,
          ),
        );
      }
    }
    if (planInputs.isEmpty) {
      throw StateError('本次没有可导出题目');
    }
    // 3. 规划（第一遍）+ 回填段数（渲染用）。
    final plan = planQuestions(questions: planInputs);
    for (final p in prepared) {
      p.segmentCount = plan.segmentsByQuestion[p.entry.questionId] ?? 0;
    }
    // 4. 渲染（第二遍）：逐页容器 → MultiPage（已知总页数）。
    final preparedById = {
      for (final p in prepared) p.entry.questionId: p,
    };
    final pageWidgets = await _renderPages(
      plan: plan,
      preparedById: preparedById,
      documentBuilder: documentBuilder,
      info: info,
    );
    final document = documentBuilder.createDocument(metadata: metadata);
    document.addPage(
      documentBuilder.multiPage(
        children: pageWidgets,
        plan: PdfPaginationPlan(
          totalPages: totalPagesOverride ?? plan.totalPages,
        ),
        headerInfo: headerInfo,
      ),
    );
    // 5. 逐题结果（与快照条目同顺序，恰好覆盖全部快照题，C-14）。
    final questions = [
      for (final p in prepared)
        AQuestionBuildResult(
          questionId: p.entry.questionId,
          title: p.entry.title,
          questionNumber: p.questionNumber,
          status: p.status,
          enhanceOutcome: p.enhance?.outcome,
          effectiveDpi: p.effectiveDpi,
          clarity: p.clarity,
          rasterPixels: p.rasterPixels,
          segmentCount:
              p.isSkipped || p.isBroken ? 0 : plan.segmentsByQuestion[p.entry.questionId] ?? 0,
          warnings: List.of(p.warnings),
          skipReason: p.skipReason,
        ),
    ];
    return ABuildResult(
      document: document,
      plan: plan,
      questions: questions,
    );
  }

  /// 准备一道题：验哈希 → 增强 → 写 enhanced/ 临时文件。
  ///
  /// 失败分类（D-179）：源缺失/损坏/无法解码 → 题目级 BROKEN；
  /// 快照副本哈希不一致 → 整单中止（抛 [SnapshotIntegrityException]）。
  static Future<_PreparedQuestion> _prepareEntry({
    required SnapshotQuestionEntry entry,
    required int index,
    required ExportSnapshot snapshot,
    required Directory enhancedDir,
    required bool excludeLowDpi,
    required double excludeBelowDpi,
    required ImageEnhanceParams enhanceParams,
  }) async {
    if (entry.outcome == SnapshotOutcome.skipped) {
      return _PreparedQuestion(
        entry: entry,
        isSkipped: true,
        skipReason: entry.skipReason,
        warnings: List.of(entry.warnings),
      );
    }
    if (entry.outcome == SnapshotOutcome.broken ||
        entry.sliceCopy == null) {
      return _PreparedQuestion(
        entry: entry,
        isBroken: true,
        brokenReason: entry.warnings.isNotEmpty
            ? entry.warnings.first
            : '源切片缺失',
        warnings: List.of(entry.warnings),
      );
    }
    final copy = entry.sliceCopy!;
    final tempFile = File(
      '${snapshot.tempDir.path}${Platform.pathSeparator}'
      '${copy.tempRelativePath}',
    );
    // 验哈希：生成只读临时副本，读取时核对（§6）。
    final hashOk = await SliceSnapshot.verifyTempCopy(
      tempFile: tempFile,
      expectedHash: copy.sourceHash,
    );
    if (!hashOk) {
      throw SnapshotIntegrityException(
        '快照副本哈希不一致（临时副本与源切片不符），本次导出中止。',
      );
    }
    late final Uint8List bytes;
    try {
      bytes = await tempFile.readAsBytes();
    } catch (_) {
      throw SnapshotIntegrityException(
        '读取快照临时副本失败，本次导出中止。',
      );
    }
    // 增强（解码 → 下采样到上限 → 增强 → 编码；失败回退，见 D-182）。
    final enhance = ImageEnhancer.enhanceSlice(
      sliceBytes: bytes,
      params: enhanceParams,
    );
    if (enhance.isUndecodable) {
      return _PreparedQuestion(
        entry: entry,
        isBroken: true,
        brokenReason: '切片无法解码',
        warnings: ['切片无法解码'],
        effectiveDpi: 0,
        clarity: ClarityLevel.severe,
      );
    }
    final dpi = enhance.effectiveDpi;
    // 门禁：增强成功但门禁不通过 → 跳过（不回退，D-167 边界）。
    if (ImageEnhancer.shouldSkipForClarity(
      effectiveDpi: dpi,
      excludeLowDpi: excludeLowDpi,
      excludeBelowDpi: excludeBelowDpi,
    )) {
      return _PreparedQuestion(
        entry: entry,
        isSkipped: true,
        skipReason:
            '清晰度低于门禁（有效分辨率约 ${dpi.toStringAsFixed(0)} DPI）',
        warnings: [
          '清晰度低于门禁（有效分辨率约 ${dpi.toStringAsFixed(0)} DPI）',
        ],
        enhance: enhance,
        effectiveDpi: dpi,
        clarity: enhance.clarity,
        rasterPixels: enhance.rasterPixels,
      );
    }
    // 增强后 PNG 写任务临时目录（渲染时裁剪分段；快照 dispose 清理）。
    final target = File(
      '${enhancedDir.path}${Platform.pathSeparator}'
      '$index-${_safeFileSegment(entry.questionId)}.png',
    );
    try {
      await target.writeAsBytes(enhance.bytes!);
    } on FileSystemException catch (e) {
      throw SnapshotInfrastructureException(
        '写入增强临时文件失败：${e.message}（${e.path ?? ''}）',
      );
    }
    final warnings = <String>[];
    if (enhance.isFallback) {
      warnings.add('增强失败，已用原图');
    }
    if (enhance.clarity == ClarityLevel.severe) {
      warnings.add(
        '图片清晰度明显偏低（有效分辨率约 ${dpi.toStringAsFixed(0)} DPI）',
      );
    } else if (enhance.clarity == ClarityLevel.warning) {
      warnings.add(
        '图片清晰度偏低（有效分辨率约 ${dpi.toStringAsFixed(0)} DPI）',
      );
    }
    return _PreparedQuestion(
      entry: entry,
      enhance: enhance,
      enhancedFile: target,
      cappedWidthPx: enhance.cappedWidthPx,
      cappedHeightPx: enhance.cappedHeightPx,
      effectiveDpi: dpi,
      clarity: enhance.clarity,
      rasterPixels: enhance.rasterPixels,
      warnings: warnings,
    );
  }

  /// 渲染全部页容器（第二遍）。
  ///
  /// 逐题解码增强后文件 → 裁剪分段 → 编码；一次只持有一题的解码图，
  /// 用完即释。单段题直接嵌增强后 PNG 字节，不重编码。
  static Future<List<pw.Widget>> _renderPages({
    required AContentPlan plan,
    required Map<String, _PreparedQuestion> preparedById,
    required PdfExportDocumentBuilder documentBuilder,
    required PdfExportInfo info,
  }) async {
    final pageWidgets = <pw.Widget>[];
    // 当前题的渲染缓存（题内各段连续出现，一题一释）。
    String? currentQuestionId;
    img.Image? currentDecoded;
    Uint8List? currentSingleBytes;
    final currentSegments = <int, Uint8List>{};

    Future<Uint8List> segmentBytes(
      _PreparedQuestion q,
      APlannedSegment seg,
    ) async {
      if (q.questionId != currentQuestionId) {
        currentDecoded = null;
        currentSingleBytes = null;
        currentSegments.clear();
        currentQuestionId = q.questionId;
        final bytes = await q.enhancedFile!.readAsBytes();
        if (q.segmentCount == 1) {
          currentSingleBytes = bytes;
        } else {
          final decoded = img.decodeImage(bytes);
          if (decoded == null) {
            throw StateError('增强后图像无法解码（${q.questionId}）');
          }
          currentDecoded = decoded;
        }
      }
      if (q.segmentCount == 1) {
        return currentSingleBytes!;
      }
      final cached = currentSegments[seg.segmentIndex];
      if (cached != null) return cached;
      final cropped = img.copyCrop(
        currentDecoded!,
        x: 0,
        y: seg.yStartPx,
        width: q.cappedWidthPx,
        height: seg.heightPx,
      );
      final encoded = img.encodePng(cropped);
      currentSegments[seg.segmentIndex] = encoded;
      return encoded;
    }

    for (final page in plan.pages) {
      final children = <pw.Widget>[];
      if (page.isFirstPage) {
        children.add(
          pw.SizedBox(
            height: kAInfoZoneHeightPt,
            child: documentBuilder.buildExportInfoZone(info),
          ),
        );
      }
      for (final item in page.items) {
        if (item is APlannedBroken) {
          if (item.gapBeforePt > 0) children.add(_gapWidget());
          children.add(_brokenBlockWidget(item, documentBuilder));
        } else if (item is APlannedSegment) {
          final q = preparedById[item.questionId]!;
          if (item.gapBeforePt > 0) children.add(_gapWidget());
          if (item.isFirst) {
            children.add(
              pw.SizedBox(
                height: kAQuestionNumberHeightPt,
                child: pw.Text(
                  '第 ${item.questionNumber} 题',
                  style: documentBuilder.questionNumberStyle,
                ),
              ),
            );
            // M3-F：逐题来源行（仅首段；高度已在规划里计入，与 C 路线同口径）。
            if (item.sourceText.isNotEmpty) {
              children.add(
                pw.SizedBox(
                  height: kASourceLineHeightPt,
                  child: documentBuilder.spanText(
                    item.sourceText,
                    style: documentBuilder.headerFooterStyle,
                  ),
                ),
              );
            }
          } else {
            children.add(
              pw.SizedBox(
                height: kAContinuationLabelHeightPt,
                child: pw.Text(
                  '第 ${item.questionNumber} 题（接上页）',
                  style: documentBuilder.bodyStyle,
                ),
              ),
            );
          }
          final png = await segmentBytes(q, item);
          children.add(
            pw.Image(
              pw.MemoryImage(png),
              width: PdfExportGeometry.contentWidthPt,
              height: item.displayHeightPt,
            ),
          );
          if (item.isLast && item.segmentCount > 1) {
            children.add(
              pw.SizedBox(
                height: kAEndLabelHeightPt,
                child: pw.Text(
                  '本题完',
                  style: pw.TextStyle(
                    font: documentBuilder.font,
                    fontSize: PdfExportTypography.bodyPt,
                    color: PdfColors.grey700,
                  ),
                ),
              ),
            );
          }
        }
      }
      pageWidgets.add(
        pw.Inseparable(
          canSpan: false,
          child: pw.Container(
            height: pageContainerHeightPt,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ),
      );
    }
    return pageWidgets;
  }

  /// 题间分隔：9.5pt 空白 + 0.5pt 细灰线（§7）。
  static pw.Widget _gapWidget() => pw.Column(
        children: [
          pw.SizedBox(height: kAQuestionGapPt - 0.5),
          pw.Container(
            height: 0.5,
            width: PdfExportGeometry.contentWidthPt,
            color: PdfColors.grey300,
          ),
        ],
      );

  /// BROKEN 占位块：题号行 + 来源行（有则印）+ 占位说明（2 行）。
  static pw.Widget _brokenBlockWidget(
    APlannedBroken item,
    PdfExportDocumentBuilder documentBuilder,
  ) {
    final reason = item.reason.length > 40
        ? '${item.reason.substring(0, 40)}…'
        : item.reason;
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(
          height: kAQuestionNumberHeightPt,
          child: pw.Text(
            '第 ${item.questionNumber} 题',
            style: documentBuilder.questionNumberStyle,
          ),
        ),
        // M3-F：逐题来源行（与可印题同口径；高度已在规划里计入）。
        if (item.sourceText.isNotEmpty)
          pw.SizedBox(
            height: kASourceLineHeightPt,
            child: documentBuilder.spanText(
              item.sourceText,
              style: documentBuilder.headerFooterStyle,
            ),
          ),
        pw.SizedBox(
          height: kABrokenBlockHeightPt - kAQuestionNumberHeightPt,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('本题图片缺失，无法印出', style: documentBuilder.bodyStyle),
              pw.Text(
                reason,
                style: pw.TextStyle(
                  font: documentBuilder.font,
                  fontSize: PdfExportTypography.bodyPt,
                  color: PdfColors.grey700,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 准备阶段的一道题（内部结构）。
class _PreparedQuestion {
  _PreparedQuestion({
    required this.entry,
    this.isBroken = false,
    this.isSkipped = false,
    this.brokenReason,
    this.skipReason,
    this.enhance,
    this.enhancedFile,
    this.cappedWidthPx = 0,
    this.cappedHeightPx = 0,
    this.effectiveDpi = 0,
    this.clarity = ClarityLevel.ok,
    this.rasterPixels = 0,
    required this.warnings,
  });

  /// 快照条目。
  final SnapshotQuestionEntry entry;

  /// 题目 ID（[entry] 的快捷方式）。
  String get questionId => entry.questionId;

  /// 是否 BROKEN（占位）。
  final bool isBroken;

  /// 是否跳过（不印）。
  final bool isSkipped;

  /// BROKEN 原因。
  final String? brokenReason;

  /// 跳过原因。
  final String? skipReason;

  /// 增强结果（可印题与门禁跳过题有值；源缺失 BROKEN 为 null）。
  final EnhanceResult? enhance;

  /// 增强后 PNG 临时文件（可印题有值）。
  final File? enhancedFile;

  /// 上限后像素尺寸（可印题有值）。
  final int cappedWidthPx;
  final int cappedHeightPx;

  /// 有效 DPI。
  final double effectiveDpi;

  /// 清晰度档位。
  final ClarityLevel clarity;

  /// 上限后像素数（guard 计入值）。
  final int rasterPixels;

  /// 警告。
  final List<String> warnings;

  /// 导出内题号（准备后编号；0 = 未印出）。
  int questionNumber = 0;

  /// 段数（规划后由 buildDocument 填入；准备阶段为 0）。
  int segmentCount = 0;

  /// 完整性状态（[classifyA] 口径；跳过题为 skipped）。
  IntegrityStatus get status {
    if (isSkipped) return IntegrityStatus.skipped;
    if (isBroken) return IntegrityStatus.broken;
    return classifyA(
      sliceOk: true,
      enhanceFailedFallback:
          enhance?.outcome == EnhanceOutcome.fallbackCapped,
      lowDpi: clarity != ClarityLevel.ok,
    );
  }
}

/// 文件名安全段（临时文件名用）：只留字母数字与 `._-`，其余换 `_`。
String _safeFileSegment(String value) {
  final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_').trim();
  return cleaned.isEmpty ? 'q' : cleaned;
}
