// 十五批 M1-C：C 路线文本流分页（M1-DESIGN.md §10，D-180）。
//
// 机制（探针已验证，见 M1-DESIGN.md 附录 C；探针文件
// test/b15_m1c_probe_test.dart）：
// - 普通题（题高 ≤ 一页可用高）：整题包 `Inseparable` 强制整体移页；
// - 超长题（题高 > 一页可用高）：块边界拆分分支——文本段用 TextPainter
//   以同一字体/同一字号预估行数（CJK 按字断行），按行切成页内组；
//   公式/图块等原子块整块移页，不可拆；续页标「第 N 题（接上页）」，
//   末段标「本题完」，题号只出现在第一页。
//
// 本文件是分页规划（纯数据输出，不建 pdf widgets，可在主 Isolate 用
// TextPainter 规划、把规划传给生成 Isolate 建文档；见 §7 两遍布局）。
// 建文档用 `c_content_builder.dart`，它只认本文件的规划数据。
//
// 高度模型（探针实测校准，pdf 3.13.1 + Noto Sans SC wght=400）：
// - 可用内容高 727.81 pt（内容区 756.85 − 页眉/页脚约 29.04；页眉/页脚
//   在 MultiPage 内占用内容区空间；D-183：原 727.87 比实测高 0.06 pt，
//   已修正）；
// - pdf 行高因子 1.4518×字号（11 pt 单行 15.97 pt、13 pt 题号行 18.87 pt、
//   10 pt 行 14.52 pt），行间另加 lineSpacing；11 pt 正文 N 行高
//   = N×21.47 − 5.5；Flutter TextPainter 的行高（11×1.5 = 16.5）是
//   另一套度量，只用来定断行位置（行首字符偏移），绝不用来算 pdf 高度。
// - 超长题拆分支的行预算留 5% 安全余量（kPaginationSafetyMargin）。
//
// 安全硬规则（附录 C.4）：绝不能放出高于单页可用内容的部件（超高不可拆
// 分部件会使 MultiPage 无限翻页，Release 下无断言保护）。原子块超高时
// 本文件按比例缩小到页内（宽高同比，标记 shrunk）；文本段按行切分，
// 每组高度必 ≤ 页高。规划完成后可用 [validatePlan] 自检。
//
// LaTeX 源码只存在于内部数据里，绝不出现在报错、日志里（C-11）：
// 本文件的异常只含题号与原因。
import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import 'pdf_document_builder.dart';
import 'pdf_font.dart';

/// 实测可用内容高（pt，附录 C.2：内容区 756.85 − 页眉/页脚 29.04；
/// D-183：原 727.87 比实测值高 0.06 pt，已修正）。
const double kPdfUsableHeightPt = 727.81;

/// pdf 行高因子（附录 C.2：单行高 ≈ 字号 × 1.4518）。
const double kPdfLineHeightFactor = 1.4518;

/// Noto Sans SC Regular 的 hhea 上升沿占比（十八批 P1 D-216）。
///
/// hhea ascender 1160 / unitsPerEm 1000；pdf 3.13.1 的行高按
/// ascent − descent 计，文本行高 = 字号 × (1.16 + 0.288) = 1.448 ×
/// 字号（与 [kPdfLineHeightFactor] 的 1.4518 差 0.004×字号，文本行
/// 仍以单行高为准；此处只用来拆出行内公式行的基线上/下两段）。
const double kPdfFontAscentFactor = 1.16;

/// Noto Sans SC Regular 的 hhea 下降沿占比（hhea descender −288）。
const double kPdfFontDescentFactor = 0.288;

/// 11 pt 正文单行高（pt，实测 ≈ 15.97）。
const double kPdfBodySingleLineHeightPt =
    PdfExportTypography.bodyPt * kPdfLineHeightFactor;

/// 11 pt 正文行距（pt，M1-A：lineSpacing = (1.5 − 1) × 11 = 5.5）。
const double kPdfBodyLineSpacingPt =
    (PdfExportTypography.lineHeightFactor - 1) *
        PdfExportTypography.bodyPt;

/// 11 pt 正文每增一行的增量（pt，实测 ≈ 21.47）。
const double kPdfBodyLinePitchPt =
    kPdfBodySingleLineHeightPt + kPdfBodyLineSpacingPt;

/// 13 pt 题号行高（pt，≈ 18.87）。
const double kPdfQuestionNumberHeightPt =
    PdfExportTypography.questionNumberPt * kPdfLineHeightFactor;

/// 10 pt 来源行高（pt，≈ 14.52）。
const double kPdfSourceLineHeightPt =
    PdfExportTypography.headerFooterPt * kPdfLineHeightFactor;

/// 题间分隔线高（pt：上下各 4 pt 间距 + 0.5 pt 细线；构建器须同值）。
const double kPdfSeparatorHeightPt = 8.5;

/// 第一页导出信息区高（pt：5 行 × 10 pt 行高 14.52；构建器须同值）。
const double kPdfExportInfoZoneHeightPt = 5 * kPdfSourceLineHeightPt;

/// 第一页题目可用高（pt：可用内容高 − 信息区高）。
const double kPdfFirstPageAvailableHeightPt =
    kPdfUsableHeightPt - kPdfExportInfoZoneHeightPt;

/// 超长题拆分支的安全余量（§10：预估误差留 5%）。
const double kPaginationSafetyMargin = 0.05;

/// 整题分支安全余量（pt，D-183：2 行 ≈ 29 pt）。
///
/// 规划与实际高度的偏差（TextPainter 与 pdf 行数 ±1 行，约 21.47 pt）
/// 可能把封顶附近的整题推入危险带（727.81, 756.85]，Release 下
/// MultiPage 无限翻页直至 OOM。整题规划高度距封顶不足本余量时不取
/// 整题，强制走切分支（切分支自带 5% 余量，不另加）。
const double kWholeQuestionSafetyMarginPt = 2 * kPdfSourceLineHeightPt;

/// pdf 文本块高度模型（N 行，字号 [fontSizePt]，行间 [lineSpacingPt]）。
///
/// 单行高 = 字号 × 1.4518；每增一行加（单行高 + 行间）。11 pt 正文
/// 12 行 = 252.08 pt（探针二分实测 252.1，见附录 C）。
double pdfTextHeightPt({
  required int lines,
  required double fontSizePt,
  double lineSpacingPt = 0,
}) {
  if (lines <= 0) return 0;
  final single = fontSizePt * kPdfLineHeightFactor;
  return single + (lines - 1) * (single + lineSpacingPt);
}

/// 文本断行器：给定文本，返回每行行首字符偏移（末尾追加文本长度作哨兵）。
///
/// 只定断行位置（CJK 按字断行），不算 pdf 高度（见文件头）。实现用
/// Flutter TextPainter（与 pdf 同一字体文件 Noto Sans SC Regular，
/// 同一字号/同一宽度；探针 (b) 5 样本行数误差均在 ±1 行内）。
abstract class CTextSplitter {
  /// 保证断行用字体已加载（主 Isolate 调用一次；重复调用无操作）。
  Future<void> ensureFontLoaded();

  /// 每行行首字符偏移 + 末尾哨兵（文本长度）。空文本返回 [0]。
  List<int> lineStartOffsets(
    String text, {
    required double widthPt,
    required double fontSizePt,
  });
}

/// 生产断行器（TextPainter + Noto Sans SC Regular）。
class TextPainterSplitter implements CTextSplitter {
  /// 断行用字体族名（与 UI 字体隔离，只供 TextPainter 用）。
  static const String fontFamily = 'PdfExportNoto';

  bool _loaded = false;

  @override
  Future<void> ensureFontLoaded() async {
    if (_loaded) return;
    final loader = FontLoader(fontFamily);
    loader.addFont(rootBundle.load(kExportFontAssetPath));
    await loader.load();
    _loaded = true;
  }

  @override
  List<int> lineStartOffsets(
    String text, {
    required double widthPt,
    required double fontSizePt,
  }) {
    if (text.isEmpty) return const [0];
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: fontSizePt,
          height: 1.5,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: widthPt);
    final metrics = painter.computeLineMetrics();
    // 行首偏移用 getPositionForOffset 取（LineMetrics 不含字符偏移）；
    // y 取行内 1 pt 处，避免落在行边界上。
    final lineHeight = fontSizePt * 1.5;
    final starts = <int>[];
    for (var i = 0; i < metrics.length; i++) {
      starts.add(
        painter
            .getPositionForOffset(Offset(0.5, i * lineHeight + 1))
            .offset,
      );
    }
    // 去重并保序（空行等边界情况可能重复偏移），末尾加哨兵。
    final deduped = <int>[];
    for (final s in starts) {
      if (deduped.isEmpty || deduped.last != s) deduped.add(s);
    }
    if (deduped.isEmpty || deduped.last != text.length) {
      deduped.add(text.length);
    }
    return deduped;
  }
}

/// 行内公式引用（段落文本内的占位信息；LaTeX 本身不在此结构里）。
class CInlineFormula {
  const CInlineFormula({
    required this.offset,
    required this.widthPt,
    required this.heightPt,
    required this.formulaId,
    required this.ref,
    this.isOriginal = false,
    this.shrunk = false,
    this.baselineOffsetPt,
  });

  /// 在段落原文中的字符偏移（公式位于该偏移处，即该偏移字符之前）。
  final int offset;

  /// 栅格化位图的逻辑宽（pt，PDF 中的显示宽）。
  final double widthPt;

  /// 栅格化位图的逻辑高（pt，PDF 中的显示高）。
  final double heightPt;

  /// 公式标识（题内公式序号的字符串化，与栅格化结果的键一致）。
  final String formulaId;

  /// 图片引用（任务临时目录内的相对路径，如 `formulas/q1-f0.png`；
  /// 构建器凭此取字节；与 [CAtomicBlock.ref] 同口径）。
  final String ref;

  /// 是否为原图降级（公式渲染失败但裁剪成功；PARTIAL 标记用，
  /// D-188：与 [CAtomicBlock.isOriginal] 同口径，分页重建时透传）。
  final bool isOriginal;

  /// 是否已被缩小（超宽行内公式等比缩小；可疑标记“公式已缩小”用，
  /// D-188：与 [CAtomicBlock.shrunk] 同口径，分页重建时透传）。
  final bool shrunk;

  /// 数学基线偏移（pt，十八批 P1 D-216：图片顶到数学基线的距离，
  /// 栅格化器量得；构建器按此把公式基线落在文字基线上）。
  /// 为 null = 未知基线（原图降级等），构建器按旧居中启发式放。
  final double? baselineOffsetPt;
}

/// 一个段落：连续的文本 + 行内公式（行内公式随行不断，整行移页）。
class CParagraph {
  const CParagraph({
    required this.text,
    this.inlineFormulas = const [],
    this.fontSizePt = PdfExportTypography.bodyPt,
  });

  /// 段落文本（不含行内公式占位符；公式位置见 [inlineFormulas]）。
  final String text;

  /// 行内公式（按 offset 升序）。
  final List<CInlineFormula> inlineFormulas;

  /// 字号（M1-C 只用 11 pt 正文）。
  final double fontSizePt;
}

/// 原子块种类（整块移页，不可拆）。
enum CAtomicKind {
  /// 独立公式位图。
  displayFormula,

  /// 图块裁剪图。
  figure,
}

/// 原子块（独立公式 / 图块；宽高为 PDF 显示尺寸，超高时由分页器等比缩小）。
class CAtomicBlock {
  const CAtomicBlock({
    required this.kind,
    required this.ref,
    required this.widthPt,
    required this.heightPt,
    this.isOriginal = false,
    this.shrunk = false,
  });

  /// 种类。
  final CAtomicKind kind;

  /// 图片引用（任务临时目录内的相对路径，如 `formulas/q1-f0.png`；
  /// 构建器凭此取字节）。
  final String ref;

  /// PDF 显示宽（pt）。
  final double widthPt;

  /// PDF 显示高（pt）。
  final double heightPt;

  /// 是否为原图降级（公式渲染失败但裁剪成功；PARTIAL 标记用）。
  final bool isOriginal;

  /// 是否已被缩小（超宽/超高公式等比缩小；可疑标记“公式已缩小”用）。
  final bool shrunk;
}

/// 分页输入的一块内容：段落（可按行拆）或原子块（整块移页）。
sealed class CLayoutBlock {
  const CLayoutBlock();
}

/// 可按行拆分的段落块。
class CLayoutParagraph extends CLayoutBlock {
  const CLayoutParagraph(this.paragraph);

  /// 段落。
  final CParagraph paragraph;
}

/// 整块移页的原子块。
class CLayoutAtomic extends CLayoutBlock {
  const CLayoutAtomic(this.atomic);

  /// 原子块。
  final CAtomicBlock atomic;
}

/// 分页输入的一道题。
class CPaginableQuestion {
  const CPaginableQuestion({
    required this.questionIndex,
    required this.displayNumber,
    required this.blocks,
    this.sourceText = '',
  });

  /// 题序（快照顺序，从 0 计）。
  final int questionIndex;

  /// 导出内题号（从 1 计，只出现在第一页）。
  final int displayNumber;

  /// 内容块序列（段落 / 原子块）。
  final List<CLayoutBlock> blocks;

  /// 来源行文字（学科 · 文件夹 · 考试）；空则不印来源行。
  final String sourceText;
}

// ------------------------------------------------------------------
// 规划输出（纯数据；构建器凭此建 pdf widgets）
// ------------------------------------------------------------------

/// 规划后的一块内容。
sealed class CPartBlock {
  const CPartBlock();
}

/// 规划后的富文本块（文本 + 落在本块内的行内公式）。
class CPartRichText extends CPartBlock {
  const CPartRichText({
    required this.text,
    required this.inlineFormulas,
    required this.fontSizePt,
    required this.lines,
  });

  /// 文本（已去掉公式占位符；公式位置见 [inlineFormulas] 的 offset，
  /// 以本块文本计）。
  final String text;

  /// 落在本块内的行内公式（offset 以本块文本计）。
  final List<CInlineFormula> inlineFormulas;

  /// 字号。
  final double fontSizePt;

  /// 行数（断行器给出的行数；高度按行内公式建模，见
  /// [_MeasuredParagraph.heightForLineRange]）。
  final int lines;
}

/// 规划后的图片块（独立公式 / 图块；宽高为最终显示尺寸）。
class CPartImage extends CPartBlock {
  const CPartImage({
    required this.kind,
    required this.ref,
    required this.widthPt,
    required this.heightPt,
    this.isOriginal = false,
    this.shrunk = false,
  });

  /// 种类。
  final CAtomicKind kind;

  /// 图片引用（任务临时目录内的相对路径）。
  final String ref;

  /// PDF 显示宽（pt）。
  final double widthPt;

  /// PDF 显示高（pt）。
  final double heightPt;

  /// 是否为原图降级。
  final bool isOriginal;

  /// 是否已被缩小。
  final bool shrunk;
}

/// 规划后的一道题的一段（一段 = 一页内的一组内容）。
class CQuestionPart {
  const CQuestionPart({
    required this.questionIndex,
    required this.displayNumber,
    required this.continuation,
    required this.last,
    required this.blocks,
    required this.heightPt,
  });

  /// 题序（快照顺序，从 0 计）。
  final int questionIndex;

  /// 导出内题号。
  final int displayNumber;

  /// 是否续页段（true 时印「第 N 题（接上页）」，不印题号行）。
  final bool continuation;

  /// 是否末段（true 时末尾印「本题完」）。
  final bool last;

  /// 内容块。
  final List<CPartBlock> blocks;

  /// 本段规划高度（pt，含题号/续页标/来源行/分隔线；构建器实际
  /// widget 高度须与此一致，见 c_content_builder.dart）。
  final double heightPt;
}

/// 规划后的一页。
class CPlannedPage {
  const CPlannedPage({required this.parts});

  /// 本页的题段（按题序）。
  final List<CQuestionPart> parts;
}

/// C 路线分页规划结果（确定性：同一输入同一平台两次规划结果一致）。
class CPagePlan {
  const CPagePlan({
    required this.pages,
    required this.firstPageAvailableHeightPt,
    required this.otherPageAvailableHeightPt,
  });

  /// 页序列。
  final List<CPlannedPage> pages;

  /// 第一页题目可用高（pt）。
  final double firstPageAvailableHeightPt;

  /// 其余页题目可用高（pt）。
  final double otherPageAvailableHeightPt;

  /// 总页数。
  int get totalPages => pages.length;

  /// 规划内题数（去重题序数）。
  int get questionCount {
    final seen = <int>{};
    for (final page in pages) {
      for (final part in page.parts) {
        seen.add(part.questionIndex);
      }
    }
    return seen.length;
  }
}

// ------------------------------------------------------------------
// 分页算法
// ------------------------------------------------------------------

/// C 路线文本流分页器（§10：按题流式装箱 + 超长题块边界拆分）。
class CTextPaginator {
  CTextPaginator({required this.splitter});

  /// 断行器（生产用 [TextPainterSplitter]；测试可用桩实现）。
  final CTextSplitter splitter;

  /// 内容区宽（pt）。
  double get contentWidthPt => PdfExportGeometry.contentWidthPt;

  /// 规划全部题目。
  ///
  /// [firstPageAvailableHeightPt] 默认 [kPdfFirstPageAvailableHeightPt]
  /// （第一页有导出信息区）；[otherPageAvailableHeightPt] 默认
  /// [kPdfUsableHeightPt]。
  CPagePlan paginate(
    List<CPaginableQuestion> questions, {
    double firstPageAvailableHeightPt = kPdfFirstPageAvailableHeightPt,
    double otherPageAvailableHeightPt = kPdfUsableHeightPt,
  }) {
    final pages = <CPlannedPage>[];
    var currentParts = <CQuestionPart>[];
    var currentRemaining = firstPageAvailableHeightPt;
    var isFirstPage = true;

    double pageAvailable() =>
        isFirstPage ? firstPageAvailableHeightPt : otherPageAvailableHeightPt;

    void closePage() {
      pages.add(CPlannedPage(parts: List.of(currentParts)));
      currentParts = <CQuestionPart>[];
      isFirstPage = false;
      currentRemaining = otherPageAvailableHeightPt;
    }

    for (var qi = 0; qi < questions.length; qi++) {
      final q = questions[qi];
      final isLastQuestion = qi == questions.length - 1;
      final whole = _measureWholeQuestion(q, isLastQuestion: isLastQuestion);
      // 下一新页的可用高：放不下当前页时，下一新页必为非第一页
      // （当前页为空且为第一页时，下一页是第二页；其余情况下一页
      // 也是非第一页），故一律取其余页可用高（第一页可用高 ≤ 其余页
      // 可用高，见 kPdfFirstPageAvailableHeightPt 的定义）。
      final freshAvailable = otherPageAvailableHeightPt;
      // 整题分支（D-183）：规划高度距封顶不足 2 行安全余量时不取整题，
      // 强制走切分支——规划与实际的 ±1 行偏差可能把封顶附近的整题
      // 推入危险带（727.81, 756.85]，Release 下无限翻页。
      final wholeFitsFreshPage =
          whole.heightPt <=
          freshAvailable - kWholeQuestionSafetyMarginPt;
      if (whole.heightPt <= currentRemaining && wholeFitsFreshPage) {
        // 普通题：放本页。
        currentParts.add(whole);
        currentRemaining -= whole.heightPt;
        continue;
      }
      if (wholeFitsFreshPage) {
        // 整题放得下一页：移下一页（Inseparable 由构建器包）。
        if (currentParts.isNotEmpty) {
          closePage();
        } else if (isFirstPage) {
          // 当前页即第一页且为空：第一页只留导出信息区，题移第二页。
          pages.add(const CPlannedPage(parts: []));
          isFirstPage = false;
          currentRemaining = otherPageAvailableHeightPt;
        }
        currentParts.add(whole);
        currentRemaining = pageAvailable() - whole.heightPt;
        continue;
      }
      // 超长题：块边界拆分分支。拆分段每段独占一页；首段落在当前页
      // （当前页有内容时先关页，首段落在新页；当前页为空时首段直接
      // 用当前页剩余高度——第一页时为第一页可用高）。
      final firstPartBudget = currentParts.isEmpty
          ? currentRemaining
          : otherPageAvailableHeightPt;
      if (currentParts.isNotEmpty) closePage();
      final parts = _splitLongQuestion(
        q,
        isLastQuestion: isLastQuestion,
        firstPartAvailableHeightPt: firstPartBudget,
        otherPageAvailableHeightPt: otherPageAvailableHeightPt,
      );
      for (var pi = 0; pi < parts.length; pi++) {
        final part = parts[pi];
        currentParts.add(part);
        final budget =
            pi == 0 ? firstPartBudget : otherPageAvailableHeightPt;
        currentRemaining = budget - part.heightPt;
        // 非末段独占一页；末段所在页保持打开，供下一题继续装箱。
        if (pi < parts.length - 1) closePage();
      }
    }
    if (currentParts.isNotEmpty) {
      pages.add(CPlannedPage(parts: List.of(currentParts)));
    }
    final plan = CPagePlan(
      pages: pages,
      firstPageAvailableHeightPt: firstPageAvailableHeightPt,
      otherPageAvailableHeightPt: otherPageAvailableHeightPt,
    );
    // D-183：规划自检 Release 下也执行（原 assert 在 Release 下消除，
    // 违规规划会静默通过并在生成时无限翻页）。违规即整单失败，
    // 不生成 PDF。
    final violations = validatePlan(plan);
    if (violations.isNotEmpty) {
      throw StateError('分页规划自检失败：${violations.join('；')}');
    }
    return plan;
  }

  /// 整题规划高度（含题号行、来源行、分隔线）与整题一段。
  CQuestionPart _measureWholeQuestion(
    CPaginableQuestion q, {
    required bool isLastQuestion,
  }) {
    final blocks = <CPartBlock>[];
    var height = kPdfQuestionNumberHeightPt;
    if (q.sourceText.isNotEmpty) height += kPdfSourceLineHeightPt;
    for (final block in q.blocks) {
      switch (block) {
        case CLayoutParagraph(:final paragraph):
          final measured = _MeasuredParagraph(paragraph);
          final offsets = splitter.lineStartOffsets(
            measured.text,
            widthPt: contentWidthPt,
            fontSizePt: paragraph.fontSizePt,
          );
          final lines = offsets.length - 1;
          // D-183：行高按行内公式建模（见 _MeasuredParagraph.lineHeights）；
          // 十八批 P1：基线对齐建模（上段 max（上升沿，基线偏移）+
          // 下段 max（下降沿，高 − 基线偏移）），不是纯文本行高。
          height += measured.heightForLineRange(
            offsets,
            0,
            lines,
            paragraph.fontSizePt,
            _lineSpacingFor(paragraph.fontSizePt),
          );
          blocks.add(
            CPartRichText(
              text: paragraph.text,
              inlineFormulas: List.of(paragraph.inlineFormulas),
              fontSizePt: paragraph.fontSizePt,
              lines: lines,
            ),
          );
        case CLayoutAtomic(:final atomic):
          final capped = _capAtomic(atomic);
          height += capped.heightPt;
          blocks.add(
            CPartImage(
              kind: capped.kind,
              ref: capped.ref,
              widthPt: capped.widthPt,
              heightPt: capped.heightPt,
              isOriginal: capped.isOriginal,
              shrunk: capped.shrunk,
            ),
          );
      }
    }
    if (!isLastQuestion) height += kPdfSeparatorHeightPt;
    return CQuestionPart(
      questionIndex: q.questionIndex,
      displayNumber: q.displayNumber,
      continuation: false,
      last: true,
      blocks: blocks,
      heightPt: height,
    );
  }

  /// 超长题拆分支：按块边界切成若干段，每段 ≤ 其所在页可用高。
  ///
  /// 首段用 [firstPartAvailableHeightPt]（当前页剩余高度；第一页时
  /// 为第一页可用高），其余段用 [otherPageAvailableHeightPt]。
  /// 段内开销：首段题号行 + 来源行；续段续页标行；每段预留「本题完」行
  /// （末段才印，但切分时不知哪段是末段，统一预留一行，避免末段放不下
  /// 「本题完」；浪费 ≤ 每页一行）。
  List<CQuestionPart> _splitLongQuestion(
    CPaginableQuestion q, {
    required bool isLastQuestion,
    required double firstPartAvailableHeightPt,
    required double otherPageAvailableHeightPt,
  }) {
    var partBudget = firstPartAvailableHeightPt;
    final parts = <CQuestionPart>[];
    var currentBlocks = <CPartBlock>[];
    var currentHeight = _splitPartOverhead(
      continuation: false,
      sourceText: q.sourceText,
    );
    var isFirstPart = true;

    void closePart() {
      parts.add(
        CQuestionPart(
          questionIndex: q.questionIndex,
          displayNumber: q.displayNumber,
          continuation: !isFirstPart,
          last: false,
          blocks: List.of(currentBlocks),
          heightPt: currentHeight,
        ),
      );
      currentBlocks = <CPartBlock>[];
      isFirstPart = false;
      partBudget = otherPageAvailableHeightPt;
      currentHeight = _splitPartOverhead(
        continuation: true,
        sourceText: q.sourceText,
      );
    }

    for (final block in q.blocks) {
      switch (block) {
        case CLayoutParagraph(:final paragraph):
          final measured = _MeasuredParagraph(paragraph);
          final offsets = splitter.lineStartOffsets(
            measured.text,
            widthPt: contentWidthPt,
            fontSizePt: paragraph.fontSizePt,
          );
          final totalLines = offsets.length - 1;
          // D-183：按行高逐行累积取行（行高含行内公式建模，见
          // _MeasuredParagraph.lineHeights），不用统一行距估算。
          final spacing = _lineSpacingFor(paragraph.fontSizePt);
          final heights = measured.lineHeights(
            offsets,
            paragraph.fontSizePt,
          );
          var lineIndex = 0;
          while (lineIndex < totalLines) {
            // 本页剩余可放高度（5% 安全余量 + 预留「本题完」行已在
            // currentHeight 的开销里——见 _splitPartOverhead）。
            final remainingForLines = partBudget - currentHeight;
            final budgetForLines =
                remainingForLines * (1 - kPaginationSafetyMargin);
            var take = 0;
            var takeHeight = 0.0;
            while (lineIndex + take < totalLines) {
              final add = take == 0
                  ? heights[lineIndex + take]
                  : heights[lineIndex + take] + spacing;
              if (takeHeight + add > budgetForLines && take > 0) break;
              takeHeight += add;
              take++;
            }
            if (take <= 0) {
              // 本段已满（连一行都放不下）：关段重开。
              if (currentBlocks.isEmpty) {
                // 段首即放不下一行：段开销（题号行 + 预留「本题完」行）
                // 本身已超页高，调用方给的页高不合法——明确抛错，
                // 绝不能硬塞出一行超高段（会使 MultiPage 无限翻页，
                // 见附录 C.4）。
                throw ArgumentError(
                  '页面可用高 $partBudget pt 小于拆分段开销 '
                  '$currentHeight pt，无法分页',
                );
              } else {
                closePart();
                continue;
              }
            }
            final group = measured.groupForLines(
              offsets,
              lineIndex,
              lineIndex + take,
            );
            currentBlocks.add(group);
            currentHeight += takeHeight;
            lineIndex += take;
            if (lineIndex < totalLines) closePart();
          }
        case CLayoutAtomic(:final atomic):
          final capped = _capAtomic(atomic);
          if (capped.heightPt > partBudget - currentHeight) {
            if (currentBlocks.isNotEmpty) closePart();
          }
          currentBlocks.add(
            CPartImage(
              kind: capped.kind,
              ref: capped.ref,
              widthPt: capped.widthPt,
              heightPt: capped.heightPt,
              isOriginal: capped.isOriginal,
              shrunk: capped.shrunk,
            ),
          );
          currentHeight += capped.heightPt;
      }
    }
    // 收尾段：加分隔线（非末题）与末段标记。
    if (!isLastQuestion) currentHeight += kPdfSeparatorHeightPt;
    parts.add(
      CQuestionPart(
        questionIndex: q.questionIndex,
        displayNumber: q.displayNumber,
        continuation: !isFirstPart,
        last: true,
        blocks: List.of(currentBlocks),
        heightPt: currentHeight,
      ),
    );
    return parts;
  }

  /// 拆分段的固定开销：题号行/续页标行 + 来源行（首段）+ 预留「本题完」行。
  double _splitPartOverhead({
    required bool continuation,
    required String sourceText,
  }) {
    var h = continuation
        ? kPdfBodySingleLineHeightPt
        : kPdfQuestionNumberHeightPt;
    if (!continuation && sourceText.isNotEmpty) {
      h += kPdfSourceLineHeightPt;
    }
    h += kPdfBodySingleLineHeightPt; // 预留「本题完」行。
    return h;
  }

  /// 原子块超高时等比缩小到页内（宽高同比；附录 C.4 安全规则）。
  ///
  /// 上限留出段开销（题号/续页标行 + 来源行 + 预留「本题完」行，
  /// 约 50 pt），保证原子块 + 段开销仍 ≤ 页高。
  CAtomicBlock _capAtomic(CAtomicBlock atomic) {
    const maxPartOverheadPt = 50.0;
    final capH = kPdfUsableHeightPt - maxPartOverheadPt;
    if (atomic.heightPt <= capH && atomic.widthPt <= contentWidthPt) {
      return atomic;
    }
    final scale = math.min(
      capH / atomic.heightPt,
      contentWidthPt / atomic.widthPt,
    );
    return CAtomicBlock(
      kind: atomic.kind,
      ref: atomic.ref,
      widthPt: atomic.widthPt * scale,
      heightPt: atomic.heightPt * scale,
      isOriginal: atomic.isOriginal,
      shrunk: true,
    );
  }

  double _lineSpacingFor(double fontSizePt) =>
      fontSizePt == PdfExportTypography.bodyPt
          ? kPdfBodyLineSpacingPt
          : 0;
}

/// 段落测量辅助：行内公式替换为等宽占位符（全角字，按字断行），
// 断行后再映射回原文 + 公式归属。
class _MeasuredParagraph {
  _MeasuredParagraph(this.paragraph)
      : text = _buildMeasuredText(paragraph),
        spans = _buildSpans(paragraph);

  /// 原段落。
  final CParagraph paragraph;

  /// 测量用文本（行内公式处插入占位符）。
  final String text;

  /// 占位符区间（测量坐标 → 公式）。
  final List<_PlaceholderSpan> spans;

  static String _buildMeasuredText(CParagraph p) {
    if (p.inlineFormulas.isEmpty) return p.text;
    final buf = StringBuffer();
    var cursor = 0;
    for (final f in p.inlineFormulas) {
      buf.write(p.text.substring(cursor, f.offset));
      final count = (f.widthPt / p.fontSizePt).ceil().clamp(1, 1 << 20);
      buf.write('测' * count);
      cursor = f.offset;
    }
    buf.write(p.text.substring(cursor));
    return buf.toString();
  }

  static List<_PlaceholderSpan> _buildSpans(CParagraph p) {
    final out = <_PlaceholderSpan>[];
    var shift = 0; // 测量坐标 − 原文坐标的累计偏移。
    for (final f in p.inlineFormulas) {
      final count = (f.widthPt / p.fontSizePt).ceil().clamp(1, 1 << 20);
      final measuredStart = f.offset + shift;
      out.add(
        _PlaceholderSpan(
          measuredStart: measuredStart,
          length: count,
          formula: f,
        ),
      );
      shift += count;
    }
    return out;
  }

  /// 每行高度（pt，D-183：行内公式建模；十八批 P1 D-216：基线对齐建模）。
  ///
  /// 行高 = 基线上段 + 基线下段（pdf 3.13.1 的行高 = bottom − top，
  /// 探针 2c 实测：文本行 15.93 = 12.76 + 3.17，WidgetSpan 行与
  /// 模型分毫不差）。文本行：上段 = 字号 × 1.16、下段 = 字号 × 0.288，
  /// 合计取 max（单行高，上下段和）——与旧模型文本行完全一致。
  /// 含行内公式行：上段取 max（文本上升沿，各公式基线偏移），下段取
  /// max（文本下降沿，各公式高 − 基线偏移）；基线未知的公式（原图
  /// 降级）仍按旧居中启发式折算（上段 (单行高 + 公式高) / 2、
  /// 下段 (公式高 − 单行高) / 2）。公式只影响其占位符起点所在行
  /// （WidgetSpan 是单行内联部件，不跨行）。
  /// 旧模型（max（单行高，公式高））在基线靠下的公式上会低估行高
  /// （如高 15、基线 14 的公式：旧 15.97，实 17.17），封顶附近的
  /// 题会被推入危险带；新模型与构建器的实际行高一致。
  List<double> lineHeights(List<int> offsets, double fontSizePt) {
    final single = fontSizePt * kPdfLineHeightFactor;
    final ascent = fontSizePt * kPdfFontAscentFactor;
    final descent = fontSizePt * kPdfFontDescentFactor;
    final heights = List<double>.filled(offsets.length - 1, single);
    // 每行的基线上/下段（下标与 heights 对齐；无公式行保持单行高）。
    final above = List<double>.filled(offsets.length - 1, ascent);
    final below = List<double>.filled(offsets.length - 1, descent);
    for (final span in spans) {
      var line = -1;
      for (var i = 0; i < offsets.length - 1; i++) {
        if (span.measuredStart >= offsets[i] &&
            span.measuredStart < offsets[i + 1]) {
          line = i;
          break;
        }
      }
      if (line < 0) continue;
      final h = span.formula.heightPt;
      final b = span.formula.baselineOffsetPt;
      if (b != null) {
        if (b > above[line]) above[line] = b;
        final under = h - b;
        if (under > below[line]) below[line] = under;
      } else {
        // 未知基线：旧居中启发式（WidgetSpan baseline = (单行高 − 高)/2）
        // 下公式在行内的上下段。
        final centeredAbove = (single + h) / 2;
        if (centeredAbove > above[line]) above[line] = centeredAbove;
        final centeredBelow = (h - single) / 2;
        if (centeredBelow > below[line]) below[line] = centeredBelow;
      }
      final modeled = above[line] + below[line];
      if (modeled > heights[line]) heights[line] = modeled;
    }
    return heights;
  }

  /// [startLine, endLine) 行组的高度（各行高之和 +（行数 − 1）× 行间；
  /// 无公式时与 [pdfTextHeightPt] 同值）。
  double heightForLineRange(
    List<int> offsets,
    int startLine,
    int endLine,
    double fontSizePt,
    double lineSpacingPt,
  ) {
    final count = endLine - startLine;
    if (count <= 0) return 0;
    final heights = lineHeights(offsets, fontSizePt);
    var total = 0.0;
    for (var i = startLine; i < endLine; i++) {
      total += heights[i];
    }
    return total + (count - 1) * lineSpacingPt;
  }

  /// 取测量行 [startLine, endLine) 对应的一组内容（原文子串 + 公式）。
  ///
  /// [offsets] 为断行器给出的行首偏移（含末尾哨兵）。
  CPartRichText groupForLines(
    List<int> offsets,
    int startLine,
    int endLine,
  ) {
    final mStart = offsets[startLine];
    final mEnd = offsets[endLine];
    final buf = StringBuffer();
    final formulas = <CInlineFormula>[];
    var cursor = mStart;
    for (final span in spans) {
      if (span.measuredStart >= mEnd) break;
      if (span.measuredStart + span.length <= mStart) {
        // 占位符完全在本组之前：公式已归属前一组，跳过。
        continue;
      }
      if (span.measuredStart < mStart) {
        // 占位符跨组首：公式随起点行走（归前一组），本组只跳过
        // 落在本组内的占位符字符，不把占位符写进原文。
        cursor = span.measuredStart + span.length;
        continue;
      }
      // 公式归属：占位符起点落在本组内的公式归本组（占位符跨行时
      // 公式随起点行走，不拆分）。
      buf.write(text.substring(cursor, span.measuredStart));
      // 占位符不进原文；记录公式在本组原文中的偏移。
      final offsetInGroup = buf.length;
      formulas.add(
        CInlineFormula(
          offset: offsetInGroup,
          widthPt: span.formula.widthPt,
          heightPt: span.formula.heightPt,
          formulaId: span.formula.formulaId,
          ref: span.formula.ref,
          // D-188：分页重建行内公式时透传原图/缩小标记，否则
          // _collectResults 汇总不到行内公式的降级状态。
          isOriginal: span.formula.isOriginal,
          shrunk: span.formula.shrunk,
          // 十八批 P1：透传基线偏移，否则分页按旧模型算、构建器
          // 按新基线放，两边行高脱节。
          baselineOffsetPt: span.formula.baselineOffsetPt,
        ),
      );
      cursor = span.measuredStart + span.length;
    }
    buf.write(text.substring(cursor, mEnd));
    final lines = endLine - startLine;
    return CPartRichText(
      text: buf.toString(),
      inlineFormulas: formulas,
      fontSizePt: paragraph.fontSizePt,
      lines: lines,
    );
  }
}

class _PlaceholderSpan {
  const _PlaceholderSpan({
    required this.measuredStart,
    required this.length,
    required this.formula,
  });

  /// 占位符在测量文本中的起始偏移。
  final int measuredStart;

  /// 占位符字符数。
  final int length;

  /// 对应公式。
  final CInlineFormula formula;
}

/// 规划自检：每段高度 ≤ 其所在页可用高；题号唯一性；续页标/末段标记。
///
/// 返回违规描述列表（空 = 通过）。分页器内部 assert 用；测试直接调。
List<String> validatePlan(CPagePlan plan) {
  final violations = <String>[];
  final numberSeen = <int, int>{};
  for (var pi = 0; pi < plan.pages.length; pi++) {
    final page = plan.pages[pi];
    final available = pi == 0
        ? plan.firstPageAvailableHeightPt
        : plan.otherPageAvailableHeightPt;
    for (final part in page.parts) {
      if (part.heightPt > available + 0.01) {
        violations.add(
          '第 ${pi + 1} 页题 ${part.displayNumber} 段高 '
          '${part.heightPt.toStringAsFixed(1)} > 可用高 '
          '${available.toStringAsFixed(1)}',
        );
      }
      if (!part.continuation) {
        numberSeen[part.displayNumber] =
            (numberSeen[part.displayNumber] ?? 0) + 1;
      }
      if (part.continuation && part.blocks.isEmpty) {
        violations.add('第 ${pi + 1} 页题 ${part.displayNumber} 续页段无内容');
      }
    }
  }
  for (final entry in numberSeen.entries) {
    if (entry.value != 1) {
      violations.add('题号 ${entry.key} 出现 ${entry.value} 次（应为 1 次）');
    }
  }
  return violations;
}
