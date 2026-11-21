// 十五批 M1-A：PDF 文档结构骨架（M1-DESIGN.md §7）。
//
// 两路线共用：几何、页眉页脚、第一页导出信息区、两遍布局框架、元数据。
// 内容构建器（C 文本流 / A 图片）与分页器在 M1-C / M1-D 落地，本文件只
// 提供它们挂接的骨架与契约点。
//
// 契约点（M1-DESIGN.md 新契约总表）：
// - C-6：C 路线文本一律 `TextOverflow.span`——唯一构造入口见 [spanText]，
//   实际 span 用法在 M1-C 落地；本文件不提供默认 overflow 的文本入口。
// - C-7：`Document.save()` 必须 await——唯一保存入口见 [savePdf]，
//   完成前不得发布文件。
// - 页数策略（REV2）：`MultiPage.maxPages` 显式设 500（见 [kPdfExportMaxPages]）；
//   该上限只作防失控保护，不作产品限制；maxPages 检查在 pdf 3.13.1 里包在
//   assert 内（只在 Debug 构建跑），Debug/Release 一致性由测试保证。
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// 几何（S1 生成器沿用，M1-DESIGN.md §1/§7）：A4 595.28×841.89 pt；
/// 边距上下左右各 15 mm；内容区宽 510.2 pt、高 756.85 pt。
class PdfExportGeometry {
  PdfExportGeometry._();

  /// 1 mm = 72 / 25.4 pt。
  static const double mm = 72.0 / 25.4;

  /// A4 页宽（pt）。
  static const double pageWidthPt = 595.28;

  /// A4 页高（pt）。
  static const double pageHeightPt = 841.89;

  /// 四边边距（mm）。
  static const double marginMm = 15;

  /// 四边边距（pt，≈ 42.52）。
  static double get marginPt => marginMm * mm;

  /// 内容区宽（pt，≈ 510.2）。
  static double get contentWidthPt => pageWidthPt - 2 * marginPt;

  /// 内容区高（pt，≈ 756.85）。
  static double get contentHeightPt => pageHeightPt - 2 * marginPt;
}

/// 字号（S1 生成器沿用，M1-DESIGN.md §7；M1-C/D 验证时复核可读性）。
class PdfExportTypography {
  PdfExportTypography._();

  /// 题号字号（加粗）。
  static const double questionNumberPt = 13;

  /// 正文字号。
  static const double bodyPt = 11;

  /// 页眉页脚字号。
  static const double headerFooterPt = 10;

  /// 行距倍数（初值 1.5×，M1-DESIGN.md §7）。
  ///
  /// 注意：pdf 3.13.1 的 `TextStyle.lineSpacing` 是每行附加的点数，
  /// 不是倍数；此处取附加 0.5 × 字号，使行高 ≈ 1.5 × 字号。
  /// 可读性在 M1-C/D 复核。
  static const double lineHeightFactor = 1.5;

  /// 正行附加行距（pt）。
  static double get bodyLineSpacingPt =>
      (lineHeightFactor - 1) * bodyPt;
}

/// `MultiPage.maxPages` 显式值（M1-DESIGN.md §7 REV2）：500。
///
/// 只作防失控保护，不作产品限制；50 道题不保证最多 20 页，默认 20 不可用。
const int kPdfExportMaxPages = 500;

/// PDF 元数据（M1-DESIGN.md §7：标题/作者/创建时间显式设定，不得留随机值）。
///
/// 说明：pdf 3.13.1 的 `pw.Document` 只公开 title/author/creator/subject/
/// keywords/producer，`/CreationDate` 由包内在建文档信息对象时写
/// `DateTime.now()`（无公开 setter），因此“创建时间”实际为文档构建时刻，
/// 不是随机值；其余字段全部由调用方显式传入，不留包默认值。
class PdfExportMetadata {
  const PdfExportMetadata({
    required this.title,
    this.author = 'quiz-master2',
    this.creator = 'quiz-master2',
    this.producer = 'quiz-master2',
    this.subject,
    this.keywords,
  });

  /// PDF 标题（建议含导出范围，如“错题本导出 · 数学”）。
  final String title;

  /// PDF 作者。
  final String author;

  /// PDF 创建者。
  final String creator;

  /// PDF 生产者（包内会追加库名后缀，见 pdf 3.13.1 PdfInfo）。
  final String producer;

  /// PDF 主题（可选）。
  final String? subject;

  /// PDF 关键词（可选）。
  final String? keywords;
}

/// 页眉学科名单行硬约束（D-183）：页眉整行“错题本 · 学科名 · 日期”
/// 在 10 pt 下按内容区宽 510.2 pt 排版；学科名超长时截断加省略号，
/// 防页眉换行顶高页眉/页脚（A 路线 40 pt 预留按单行页眉计）。
/// 固定段（“错题本 · ”+“ · ”+ 10 位日期）约占 125 pt，余量按
/// 全角字 10 pt/字计，30 字上限留足余量。
const int kExportHeaderSubjectMaxChars = 30;

/// 页眉信息（M1-DESIGN.md §7：页眉 = 错题本 · 学科名 · 导出日期）。
class PdfExportHeaderInfo {
  const PdfExportHeaderInfo({
    required this.subjectName,
    required this.exportDateText,
  });

  /// 学科名；多学科用“多学科”（不得取第一道题的学科代表整个导出范围）。
  final String subjectName;

  /// 导出日期文字（已格式化，如“2026-11-20”）。
  final String exportDateText;

  /// 页眉整行文字（单行硬约束：学科名超长时截断加省略号，见
  /// [kExportHeaderSubjectMaxChars]）。
  String get line {
    final name = subjectName.trim();
    final shown = name.length <= kExportHeaderSubjectMaxChars
        ? name
        : '${name.substring(0, kExportHeaderSubjectMaxChars)}…';
    return '错题本 · $shown · $exportDateText';
  }
}

/// 第一页导出信息区内容（M1-DESIGN.md §7：第一页页眉下方印导出信息区）。
class PdfExportInfo {
  const PdfExportInfo({
    required this.filterText,
    required this.questionCount,
    required this.exportDateText,
    required this.sortText,
    required this.routeText,
  });

  /// 筛选条件文字。
  final String filterText;

  /// 本次导出题数。
  final int questionCount;

  /// 导出日期文字（已格式化）。
  final String exportDateText;

  /// 排序方式文字。
  final String sortText;

  /// 本次路线文字（C/A + 原因，如“OCR 重排路线（已配置 OCR key）”）。
  final String routeText;

  /// 信息区各行文字（顺序即展示顺序）。
  List<String> get lines => <String>[
        '筛选：$filterText',
        '题数：$questionCount 道',
        '日期：$exportDateText',
        '排序：$sortText',
        '路线：$routeText',
      ];
}

/// 两遍布局的分页规划结果（M1-DESIGN.md §7）。
///
/// 第一遍：调用方（M1-C/M1-D 的分页器）对整份快照做完整分页规划，产出
/// 本对象（总页数 + 每页内容）；第二遍：按已知总页数渲染，页脚写
/// “第 x / y 页”。M1-A 只定义框架，规划算法在 M1-C/M1-D 落地。
class PdfPaginationPlan {
  const PdfPaginationPlan({required this.totalPages});

  /// 规划出的总页数（第二遍渲染时页脚的分母）。
  final int totalPages;
}

/// PDF 文档结构骨架：几何、页眉页脚、信息区、两遍布局框架、元数据。
///
/// 全部文字走构造时传入的内嵌字体（Noto Sans SC Regular，见 pdf_font.dart），
/// 不得依赖系统字体。只嵌入 Regular 一个字重：pdf 3.13.1 在 `fontWeight:
/// bold` 且未另给粗体字体时用同一字体渲染（无合成粗体、无 Helvetica 回退），
/// 因此题号加粗仍走内嵌字体；前提是每个样式都显式设 `font:`。
class PdfExportDocumentBuilder {
  PdfExportDocumentBuilder({required this.font});

  /// 内嵌导出字体。
  final pw.Font font;

  /// 题号样式：13 pt 加粗。
  pw.TextStyle get questionNumberStyle => pw.TextStyle(
        font: font,
        fontSize: PdfExportTypography.questionNumberPt,
        fontWeight: pw.FontWeight.bold,
      );

  /// 正 文样式：11 pt，行距 1.5×。
  pw.TextStyle get bodyStyle => pw.TextStyle(
        font: font,
        fontSize: PdfExportTypography.bodyPt,
        lineSpacing: PdfExportTypography.bodyLineSpacingPt,
      );

  /// 页眉页脚样式：10 pt。
  pw.TextStyle get headerFooterStyle => pw.TextStyle(
        font: font,
        fontSize: PdfExportTypography.headerFooterPt,
      );

  /// 建文档并显式设定元数据（标题/作者/创建者/生产者）。
  pw.Document createDocument({required PdfExportMetadata metadata}) {
    return pw.Document(
      title: metadata.title,
      author: metadata.author,
      creator: metadata.creator,
      subject: metadata.subject,
      keywords: metadata.keywords,
      producer: metadata.producer,
    );
  }

  /// 页面主题：A4 + 15 mm 边距 + 内嵌字体（正文/粗体均走同一字体）。
  pw.PageTheme pageTheme() {
    return pw.PageTheme(
      pageFormat: PdfPageFormat.a4,
      margin: pw.EdgeInsets.all(PdfExportGeometry.marginPt),
      theme: pw.ThemeData.withFont(base: font, bold: font),
    );
  }

  /// 页眉：错题本 · 学科名 · 导出日期（10 pt）。
  pw.Widget buildHeader(PdfExportHeaderInfo info) {
    return pw.Text(info.line, style: headerFooterStyle);
  }

  /// 页脚文字：第 x / y 页（10 pt）。
  String footerText(int pageNumber, int totalPages) {
    return '第 $pageNumber / $totalPages 页';
  }

  /// 页脚 widget。
  pw.Widget buildFooter(int pageNumber, int totalPages) {
    return pw.Text(
      footerText(pageNumber, totalPages),
      style: headerFooterStyle,
    );
  }

  /// 第一页导出信息区（页眉下方）：筛选条件、题数、日期、排序方式、本次路线。
  pw.Widget buildExportInfoZone(PdfExportInfo info) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: <pw.Widget>[
        for (final line in info.lines)
          pw.Text(line, style: headerFooterStyle),
      ],
    );
  }

  /// C-6 契约点：C 路线文本一律 `TextOverflow.span`。
  ///
  /// 唯一构造入口：禁止在 C 路线用默认 overflow（clip）建长文本，否则超一页
  /// 的文本会使 MultiPage 抛错（S1 §9 实测）。实际 span 用法在 M1-C 落地。
  pw.Text spanText(String text, {pw.TextStyle? style}) {
    return pw.Text(
      text,
      style: style ?? bodyStyle,
      overflow: pw.TextOverflow.span,
    );
  }

  /// 两遍布局的第二遍：按已知总页数渲染，页脚分母取规划总页数。
  ///
  /// [plan] 由第一遍分页规划产出；[children] 为已按页规划好的内容；
  /// [headerInfo] 供每页页眉使用。`maxPages` 显式设 500（C-页数策略）。
  pw.MultiPage multiPage({
    required List<pw.Widget> children,
    required PdfPaginationPlan plan,
    required PdfExportHeaderInfo headerInfo,
  }) {
    return pw.MultiPage(
      maxPages: kPdfExportMaxPages,
      pageTheme: pageTheme(),
      header: (pw.Context context) => buildHeader(headerInfo),
      footer: (pw.Context context) =>
          buildFooter(context.pageNumber, plan.totalPages),
      build: (pw.Context context) => children,
    );
  }

  /// C-7 契约点：`Document.save()` 必须 await。
  ///
  /// 唯一保存入口：返回完整 PDF 字节；调用方在 await 完成前不得发布文件。
  /// （pdf 3.13.1 的 save() 返回 `Future<Uint8List>`，无流式写入。）
  Future<Uint8List> savePdf(pw.Document document) {
    return document.save();
  }
}
