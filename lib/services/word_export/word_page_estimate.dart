// 十七批 A4（D-207）：Word 完成界面页数估计（内容高度贪心分页模拟）。
//
// 背景：docx 生成时不知道 Word 渲染后的实际页数（D-203/W-11：
// Word 自然分页，无分页规划；`WordExportResult` 没有 totalPages
// 字段；完成界面不得编造页数）。本文件只做「估计」，结果一律以
// 「约 N 页（估计值）」展示，实际页数仍以 Word 打开为准。
//
// 估算口径（D-207，写死在这里，改口径须同步改本文件头与报告）：
//  1. 几何与 PDF 管线同源：A4 纵向、内容宽 510.2 pt；每页可用高取
//     PDF 实测可用高 727.81 pt（内容区 756.85 − 页眉/页脚约 29.04，
//     见 text_pagination.dart `kPdfUsableHeightPt`）。Word 页眉页脚
//     位于边距区，实际可用高可能略大，故本估计偏保守（页数可能略
//     高估，不会低估）。
//  2. 逐块贪心分页：文本段可跨页断开（按高度切分进页）；图片段
//     不可拆分（本页剩余高度放不下时整段移到下一页）；答案区前
//     有分页符（新页开头遇分页符不产生空白页，与 Word 行为一致）。
//  3. 文本行数用字宽模型估算（无字体度量数据，不读字体文件）：
//     汉字/全角字符按 1 em、ASCII 字母数字按 0.5 em、空格按 0.25 em、
//     其余按 0.5 em；行高 = 字号 × 1.5（与导出行距一致）；段后距按
//     代码实际传入的 twips 值折算（1 pt = 20 twips）。
//  4. 图片段间距按 0 计（导出 XML 未显式写图片段间距；Normal 样式
//     也无段距，见 docx_creator styles_generator）；分隔线 hr 为
//     空段落，按 11 pt（默认字号单倍行高）计。
//  5. 不考虑 Word 的孤行/寡行控制（widow control）、字体回退导致
//     的字宽变化、打印机驱动差异：这些都只会让实际页数在估计值
//     上下浮动 1 页左右，故界面一律写「约 N 页（估计值）」，不写
//     精确页数。
//
// 本文件是纯函数 + 无状态模拟器，不读库、不碰文件、不依赖 Widget
// 环境；估计值由 `buildWordContent` 在建文档的同时喂入（见
// word_content_builder.dart），经 `WordExportResult` /
// `ExportCompletionRow` 传到完成界面。
import 'dart:math' as math;

import 'package:docx_creator/docx_creator.dart';

import '../pdf_export/pdf_document_builder.dart';

/// 每页可用高（pt，D-207 口径第 1 条：与 PDF 实测可用高同值）。
const double kWordEstimatedUsableHeightPt = 727.81;

/// 分隔线 hr 的估计高度（pt，D-207 口径第 4 条：空段落，默认字号
/// 11 pt 单倍行高）。
const double kWordEstimatedHrHeightPt = 11.0;

/// 内容宽（pt，与 PDF/Word 几何同源）。
double get kWordEstimatedContentWidthPt =>
    PdfExportGeometry.contentWidthPt;

/// 正文默认字号（pt；混合段落里未写字号的 run 按此计）。
const double kWordEstimatedBodyPt = 11.0;

/// 估算一段文本的显示宽度（pt，D-207 口径第 3 条的字宽模型）。
double estimateWordTextWidthPt(String text, double fontSizePt) {
  var width = 0.0;
  for (final rune in text.runes) {
    if (rune == 0x20) {
      width += fontSizePt * 0.25;
    } else if (_isFullWidthRune(rune)) {
      width += fontSizePt;
    } else {
      width += fontSizePt * 0.5;
    }
  }
  return width;
}

/// 全角字符判定（汉字 / 全角标点 / 全角形式 / 带圈数字，按 1 em 计）。
bool _isFullWidthRune(int rune) =>
    (rune >= 0x2E80 && rune <= 0x303F) || // CJK 部首 / 标点
    (rune >= 0x3400 && rune <= 0x4DBF) || // CJK 扩展 A
    (rune >= 0x4E00 && rune <= 0x9FFF) || // CJK 统一表意文字
    (rune >= 0xF900 && rune <= 0xFAFF) || // CJK 兼容表意文字
    (rune >= 0xFF00 && rune <= 0xFFEF) || // 全角形式
    (rune >= 0x2460 && rune <= 0x24FF); // 带圈数字 / 字母（如 ①②③④）

/// 估算一段文本占几行（D-207 口径第 3 条；空文本为 0 行）。
int estimateWordTextLines(String text, double fontSizePt) {
  if (text.isEmpty) return 0;
  final width = estimateWordTextWidthPt(text, fontSizePt);
  return math.max(
    1,
    (width / kWordEstimatedContentWidthPt).ceil(),
  );
}

/// Word 内容高度贪心分页模拟器（D-207 口径第 2 条）。
///
/// 用法：按文档顺序喂入文本段 / 图片段 / 分隔线 / 分页符，结束时
/// 读 [estimatedPageCount]。只做加法模拟，不改文档、不返回值给
/// 导出引擎（估计值只用于完成界面展示）。
class WordPageEstimator {
  WordPageEstimator({
    this.usableHeightPt = kWordEstimatedUsableHeightPt,
  }) : _remainingPt = usableHeightPt;

  /// 每页可用高（pt）。
  final double usableHeightPt;

  int _pages = 1;
  double _remainingPt;

  /// 估计总页数（≥ 1）。
  int get estimatedPageCount => _pages;

  /// 喂入一段纯文本（可跨页；行高 = 字号 × 1.5）。
  void addText({
    required String text,
    required double fontSize,
    double spacingBeforePt = 0,
    double spacingAfterPt = 0,
  }) {
    final lines = estimateWordTextLines(text, fontSize);
    _placeSplittable(
      spacingBeforePt + lines * fontSize * 1.5 + spacingAfterPt,
    );
  }

  /// 喂入一个图文混排段落（行内公式图按其宽高参与折行与行高；
  /// 可跨页；行高取段内最大行高）。
  void addMixedParagraph(
    List<DocxInline> inlines, {
    double spacingBeforePt = 0,
    double spacingAfterPt = 0,
  }) {
    var width = 0.0;
    var lineHeight = 0.0;
    var hasContent = false;
    for (final inline in inlines) {
      if (inline is DocxText) {
        if (inline.content.isEmpty) continue;
        hasContent = true;
        final size = inline.fontSize ?? kWordEstimatedBodyPt;
        width += estimateWordTextWidthPt(inline.content, size);
        lineHeight = math.max(lineHeight, size * 1.5);
      } else if (inline is DocxInlineImage) {
        hasContent = true;
        width += inline.width;
        lineHeight = math.max(lineHeight, inline.height);
      }
    }
    if (!hasContent) return;
    final lines = math.max(
      1,
      (width / kWordEstimatedContentWidthPt).ceil(),
    );
    _placeSplittable(
      spacingBeforePt + lines * lineHeight + spacingAfterPt,
    );
  }

  /// 喂入一段独立图片（不可拆分；本页放不下时整段移到下一页）。
  void addAtomic(double heightPt, {double spacingAfterPt = 0}) {
    final height = heightPt + spacingAfterPt;
    if (height > _remainingPt && _remainingPt < usableHeightPt) {
      _pages++;
      _remainingPt = usableHeightPt;
    }
    _remainingPt = math.max(0, _remainingPt - height);
  }

  /// 喂入一个分页符（新页开头时不产生空白页）。
  void addPageBreak() {
    if (_remainingPt < usableHeightPt) {
      _pages++;
      _remainingPt = usableHeightPt;
    }
  }

  /// 喂入一段分隔线 hr（小高度，可跨页，按
  /// [kWordEstimatedHrHeightPt] 计）。
  void addSpacer(double heightPt) => _placeSplittable(heightPt);

  /// 可跨页块的放置：填满本页剩余高度后顺延到下一页。
  void _placeSplittable(double height) {
    var rest = height;
    while (rest > _remainingPt) {
      rest -= _remainingPt;
      _pages++;
      _remainingPt = usableHeightPt;
    }
    _remainingPt -= rest;
  }
}
