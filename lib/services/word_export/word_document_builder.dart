// 十六批 C（D-195）：Word 文档骨架——几何、分节、页眉页脚、字号行距
// （WORD-DESIGN.md §3）。
//
// 几何数值与 PDF 同源（M1 §7）：A4 纵向、页边距 15 mm、内容宽
// 510.2 pt；字号与行距按设计 §3.2 表。不 import pdf 包，只复用
// `PdfExportGeometry` / `PdfExportTypography` / `PdfExportHeaderInfo`
// 的常量与页眉行（同一口径，单点来源）。
import 'dart:typed_data';

import 'package:docx_creator/docx_creator.dart';

import '../pdf_export/pdf_document_builder.dart';
import '../pdf_export/slice_snapshot.dart' show readPngDimensions;
import 'word_font.dart';

/// 页边距 15 mm（twips；1 mm ≈ 56.6929 twips，15 mm ≈ 850 twips）。
///
/// 不得用 docx_creator 的默认边距（kDefaultMargin* 是 Letter 习惯值，
/// 与本设计无关）。
const int kWordMarginTwips = 850;

/// 内容宽（pt，与 PDF 同源：A4 595.28 − 2×42.52 ≈ 510.2）。
double get kWordContentWidthPt => PdfExportGeometry.contentWidthPt;

/// 单个图片最大显示高度（pt，WORD-DESIGN.md §3.5）。
///
/// 绝不能放出高于单页可用内容的部件：单个段落/图片不得高于一页可用
/// 内容高（A4 纵向 15 mm 边距下约 700 pt 级；PDF 的实测可用高为
/// 727.81 pt，Word 侧取整 700 pt 保守值）。文本段由 Word 自然断行，
/// 不受此限；单个图片超高时按比例缩小到页高内（宽高同比，标记该题
/// 可疑“图片已缩小”），不得原样放出导致 Word 顶页/裁图。
const double kWordMaxImageHeightPt = 700;

/// 行距：正文 1.5 倍（`w:line` 360；单倍 240、双倍 480，见
/// docx_creator `defaults.dart`）。
const int kWordLineSpacing150 = 360;

/// 行距：单倍（页眉页脚不参与正文行距）。
const int kWordLineSpacingSingle = 240;

/// 字号（pt，WORD-DESIGN.md §3.2，与 PDF M1 §7 同款初值）。
class WordTypography {
  WordTypography._();

  /// 文档标题（错题本导出）。
  static const double titlePt = 16;

  /// 说明段（导出信息：筛选/题数/日期/排序/路线）。
  static const double infoPt = 10;

  /// 题号行（第 N 题 + 题型）。
  static const double questionNumberPt = 13;

  /// 题干正文 / 选项行 / 答案区条目。
  static const double bodyPt = 11;

  /// 来源行（学科 / 文件夹 / 考试名，灰色）。
  static const double sourcePt = 10;

  /// 答案区标题（参考答案与解析）。
  static const double answerTitlePt = 14;

  /// 页眉 / 页脚。
  static const double headerFooterPt = 10;
}

/// 图片显示尺寸（pt，宽高比自算，防拉伸；docx_creator 的
/// `DocxImage(width:, height:)` 宽高都手填，库不自动保比例）。
///
/// [pngBytes] 为 PNG 字节；[maxWidthPt] 为显示宽上限（通常为内容宽
/// 510.2 pt）；[maxHeightPt] 为显示高上限（通常为 [kWordMaxImageHeightPt]）。
/// 返回 null 表示字节解不出尺寸（调用方按图块缺失/裁剪失败处理）。
/// [wasHeightCapped] 为 true 表示因超高被等比缩小（调用方标记该题
/// 可疑“图片已缩小”）。
({double widthPt, double heightPt, bool wasHeightCapped})? wordImageSize(
  Uint8List pngBytes, {
  double maxWidthPt = 510.2,
  double maxHeightPt = kWordMaxImageHeightPt,
}) {
  final dims = readPngDimensions(pngBytes);
  if (dims == null || dims.width <= 0 || dims.height <= 0) return null;
  // 显示宽 = min(内容宽，裁剪宽按 300 DPI 换算的自然宽)，与 guard 的
  // `_figureDisplaySize` 同口径（D-187）。
  final naturalWidthPt = dims.width / 300 * 72;
  var widthPt = naturalWidthPt < maxWidthPt ? naturalWidthPt : maxWidthPt;
  var heightPt = dims.height / dims.width * widthPt;
  var capped = false;
  if (heightPt > maxHeightPt) {
    final scale = maxHeightPt / heightPt;
    widthPt *= scale;
    heightPt = maxHeightPt;
    capped = true;
  }
  return (widthPt: widthPt, heightPt: heightPt, wasHeightCapped: capped);
}

/// 嵌入前 DPI 复核（WORD-DESIGN.md §4.2）：PNG 像素 ÷ 显示英寸 ≤ 300
///（+5% 容差）。
///
/// 超了说明快照侧漏压（上限的执行点在快照，Word 侧只复核），Word 侧
/// 不得静默放大或缩小蒙混——抛错（实现阶段的防御性断言，不是用户
/// 可见分支；服务层按生成失败处理）。
void checkWordImageDpi({
  required int widthPx,
  required double displayWidthPt,
}) {
  if (widthPx <= 0 || displayWidthPt <= 0) return;
  final dpi = widthPx / (displayWidthPt / 72);
  if (dpi > 300 * 1.05) {
    throw StateError(
      '图片分辨率异常（有效分辨率约 ${dpi.toStringAsFixed(0)} DPI，'
      '超过 300 DPI 上限），生成已中止。',
    );
  }
}

/// 全文档一个节：A4 纵向、页边距 15 mm、页眉/页脚（WORD-DESIGN.md §3.1）。
///
/// 练习版与答案版是同一文档内的两部分（答案版另起一页，分页符分隔），
/// 不是两个节。
void applyWordSection(
  DocxDocumentBuilder builder, {
  required DocxHeader header,
  required DocxFooter footer,
}) {
  builder.section(
    pageSize: DocxPageSize.a4,
    header: header,
    footer: footer,
    marginTop: kWordMarginTwips,
    marginBottom: kWordMarginTwips,
    marginLeft: kWordMarginTwips,
    marginRight: kWordMarginTwips,
  );
}

/// 页眉（每页重复，居中，10 pt）：`错题本 · 学科名 · 导出日期`。
///
/// 学科名截断复用 [PdfExportHeaderInfo.line]（30 字上限，D-183 同款）。
DocxHeader wordHeader({
  required String subjectName,
  required String exportDateText,
}) {
  final line = PdfExportHeaderInfo(
    subjectName: subjectName,
    exportDateText: exportDateText,
  ).line;
  return DocxHeader(
    children: [
      DocxParagraph(
        align: DocxAlign.center,
        lineSpacing: kWordLineSpacingSingle,
        children: [
          wordRun(
            line,
            fontSize: WordTypography.headerFooterPt,
          ),
        ],
      ),
    ],
  );
}

/// 页脚（每页重复，居中，10 pt）：`第 x / y 页`，x = PAGE 字段、
/// y = NUMPAGES 字段（WORD-DESIGN.md §3.3，D-196）。
///
/// docx_creator 用 `fldChar begin / instrText / fldChar end` 结构写
/// 字段，无缓存值（不更新字段的查看器会显示空白）；Win11 Word 打开即
/// 更新字段（LibreOffice 已实证），v1 接受现状、不补缓存值；复核见
/// W-V-05，失败时的 fallback 是完成界面提示 Ctrl+A 后 F9 更新域
/// （协调员裁决，见 D-196），不补占位缓存值。
DocxFooter wordFooter() {
  return DocxFooter(
    children: [
      DocxParagraph(
        align: DocxAlign.center,
        lineSpacing: kWordLineSpacingSingle,
        children: [
          wordRun('第 ', fontSize: WordTypography.headerFooterPt),
          const DocxPageNumber(),
          wordRun(' / ', fontSize: WordTypography.headerFooterPt),
          const DocxPageCount(),
          wordRun(' 页', fontSize: WordTypography.headerFooterPt),
        ],
      ),
    ],
  );
}

/// 正文段落（1.5 倍行距；默认段后 6 pt，不得用空段落撑间距）。
DocxParagraph wordTextParagraph(
  String text, {
  double fontSize = 11,
  bool bold = false,
  bool italic = false,
  DocxColor? color,
  DocxAlign align = DocxAlign.left,
  int? spacingBefore,
  int? spacingAfter,
}) => DocxParagraph(
  align: align,
  lineSpacing: kWordLineSpacing150,
  spacingBefore: spacingBefore,
  spacingAfter: spacingAfter ?? 120,
  children: [
    wordRun(text, fontSize: fontSize, bold: bold, italic: italic, color: color),
  ],
);

/// 多 run 段落（行内公式图嵌在文本行内时用；不得把行内公式另起一段）。
DocxParagraph wordMixedParagraph(
  List<DocxInline> children, {
  DocxAlign align = DocxAlign.left,
  int? spacingBefore,
  int? spacingAfter,
}) => DocxParagraph(
  align: align,
  lineSpacing: kWordLineSpacing150,
  spacingBefore: spacingBefore,
  spacingAfter: spacingAfter ?? 120,
  children: children,
);

/// 独立图片段落（居中；图下不写图注，与 PDF 一致）。
DocxImage wordImageBlock(
  Uint8List pngBytes, {
  required double widthPt,
  required double heightPt,
}) => DocxImage(
  bytes: pngBytes,
  extension: 'png',
  width: widthPt,
  height: heightPt,
  align: DocxAlign.center,
);
