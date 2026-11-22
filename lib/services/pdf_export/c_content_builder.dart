// 十五批 M1-C：C 路线内容构建器（M1-DESIGN.md §7/§9/§10，D-180）。
//
// 输入：[CPagePlan]（text_pagination.dart 的规划输出）+ 任务临时目录
// （图片引用 [CPartImage.ref] / [CInlineFormula.ref] 均为其下相对路径）
// + 每题记录 [CBuildQuestion]（题号/来源行/警告由调用方 M1-E 从快照与
// 栅格化结论拼出；构建器只按规划渲染，不重组选项、不碰 LaTeX）。
//
// 组装方式（附录 C 的结论，不是 A 路线的固定页高容器）：
// - MultiPage 的 children = 导出信息区 + 每段一个 [pw.Inseparable]
//   （canSpan: false）。段的实际高度由 pdf 引擎按内容自然排版，
//   与规划高度的偏差（探针 (b)：TextPainter vs pdf 行数误差 ±1 行）
//   由 Inseparable 吸收：放不下的整段整体移下一页，不拆分、不裁剪、
//   不丢内容；规划页数与实际页数一致是 V-分页验证的断言对象，
//   不是本构建器用固定高度硬保证的。
// - 文本行一律自然高度（不用固定高 SizedBox 包文本）：来源行已截断
//   单行（D-183：formatExportSourceText 超长截断加省略号），段高与
//   规划一致；固定高反而会在换行时裁字或抛错。
// - 非末段的拆分段末尾补一段空白（kPdfBodySingleLineHeightPt）：
//   分页器在每段开销里预留了一行「本题完」（末段才印），构建器用
//   空白占位把段高补到与 [CQuestionPart.heightPt] 一致，页分配
//   与规划保持一致。
// - 题间分隔线 8.5 pt（上下各 4 pt 间距 + 0.5 pt 细灰线，
//   与 kPdfSeparatorHeightPt 同值）。
//
// 文本入口（C-6）：无行内公式的段落走 M1-A 的 [PdfExportDocumentBuilder.spanText]
// （TextOverflow.span）；含行内公式的段落只能用 [pw.RichText] +
// [pw.WidgetSpan] 嵌图片（pw.Text 接不了 WidgetSpan），同样
// overflow: TextOverflow.span。这是同一条规则在富文本上的应用，
// 不是新入口——未改 M1-A 接口（见 M1-STATUS 的 M1-C 备注）。
// 行内公式的垂直对齐（十八批 P1 D-216）：WidgetSpan baseline =
// 公式基线偏移 − 公式高，即公式顶落在文字基线上方一个基线偏移处，
// 公式基线与文字基线重合（探针 2 实测：baseline = 0 时图底贴文字
// 基线；baseline = 基线偏移 − 高时公式基线落文字基线上）。
// 基线未知（原图降级，CInlineFormula.baselineOffsetPt 为 null）时
// 仍用旧居中启发式（单行高 − 公式高）/ 2，不得用猜的数。
//
// 多文件夹 / 多学科文案（§7）：页眉学科名取 [PdfExportHeaderInfo.subjectName]
// （多学科时 M1-E 传“多学科”，构建器不取第一道题的学科作代表）；
// 信息区筛选行取 [PdfExportInfo.filterText]（M1-E 拼“多文件夹”
// 等文案）。构建器不拼这些字符串。
//
// 图片读取：按 ref 从任务临时目录读字节；引用缺失 →
// [SnapshotInfrastructureException]（整单中止，与 A 路线哈希
// 不一致中止同级；上游栅格化/快照已验过这些文件，缺失即临时
// 目录损坏）。图片字节不解码校验——无效字节会在 save() 时由
// pdf 包抛错（响亮失败，不静默出坏 PDF）。
//
// 图片尺寸钉死（附录 C 补充）：`pw.Image` 默认 `BoxFit.contain`，
// `layout()` 取 fitted 尺寸作盒子——PNG 宽高比与规划显示尺寸
// 不一致时盒子会缩水（实测：1200×1200 方图按 510.2×700 显示，
// 盒高只剩 510.2），段高与规划脱节、页分配上涌；`SizedBox` /
// `Container` 也钉不住（`ConstrainedBox.layout` 取 `box = 子件.box`）。
// 本构建器所有图片一律包一层 [_FixedSizeBox]（`layout()` 里把 `box`
// 写死为规划尺寸），图片在盒内按比例绘制、不拉伸；真实内容（栅格化
// 公式 / 图块裁剪）的显示尺寸本就按像素宽高比算出，与规划一致，
// 盒内无留白。
//
// LaTeX 源码绝不出现（C-11）：本文件只见 ref / formulaId / 题号，
// 异常信息只含题号与引用路径。
import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'pdf_document_builder.dart';
import 'snapshot_exceptions.dart';
import 'text_pagination.dart';

/// C 路线一道题的构建输入（M1-E 提供；只含渲染与结果要用的字段）。
class CBuildQuestion {
  const CBuildQuestion({
    required this.questionIndex,
    required this.questionId,
    required this.title,
    this.sourceText = '',
    this.warnings = const [],
  });

  /// 题序（快照顺序，从 0 计；与规划的 [CQuestionPart.questionIndex] 一致）。
  final int questionIndex;

  /// 题目 ID（结果用，不渲染）。
  final String questionId;

  /// 题目标题（结果用，不渲染）。
  final String title;

  /// 来源行文字（学科 · 文件夹 · 考试）；空则不印来源行。
  ///
  /// 必须与构建 [CPaginableQuestion] 时用的 sourceText 完全一致，
  /// 否则来源行高度与规划不一致。
  final String sourceText;

  /// 上游警告（快照 / 栅格化结论，如“公式为原图”；构建器原样透传）。
  final List<String> warnings;
}

/// C 路线一道题的构建结果。
class CQuestionBuildResult {
  const CQuestionBuildResult({
    required this.questionId,
    required this.title,
    required this.questionNumber,
    required this.status,
    required this.segmentCount,
    required this.plannedPages,
    required this.hasOriginalFormula,
    required this.hasShrunkFormula,
    required this.warnings,
  });

  /// 题目 ID。
  final String questionId;

  /// 题目标题。
  final String title;

  /// 导出内题号（规划值，只出现在第一页）。
  final int questionNumber;

  /// 印出状态：原图降级的题为 partial，其余 printed。
  final CBuildQuestionStatus status;

  /// 段数（规划段数；1 = 整题一段，多段 = 超长题拆分）。
  final int segmentCount;

  /// 规划页号（从 1 计；跨页题含多页）。
  final List<int> plannedPages;

  /// 是否含原图降级公式（渲染失败、裁剪成功）。
  final bool hasOriginalFormula;

  /// 是否含被缩小的公式 / 图块（超宽 / 超高按比例缩小）。
  final bool hasShrunkFormula;

  /// 警告（上游透传）。
  final List<String> warnings;
}

/// C 路线题目印出状态。
enum CBuildQuestionStatus {
  /// 正常印出。
  printed,

  /// 含原图降级公式（PARTIAL；见 §8 降级链）。
  partial,
}

/// C 路线构建结果。
class CBuildResult {
  const CBuildResult({
    required this.document,
    required this.plan,
    required this.questions,
    required this.totalPages,
  });

  /// 建好的 PDF 文档（调用方用 [PdfExportDocumentBuilder.savePdf] 保存，
  /// C-7：必须 await）。
  final pw.Document document;

  /// 本次用的分页规划（与 [document] 同源）。
  final CPagePlan plan;

  /// 每题构建结果（按题序，即规划顺序）。
  final List<CQuestionBuildResult> questions;

  /// 规划总页数（页脚分母用；实际页数以 V-分页验证为准）。
  final int totalPages;
}

/// 定尺寸盒：把子件（图片）按规划尺寸钉死。
///
/// pdf 包的 `ConstrainedBox` / `SizedBox` / `Container` 在 `layout()`
/// 里都把 `box` 取成子件上报的盒子；`pw.Image`（`BoxFit.contain`）
/// 在 PNG 宽高比与规划尺寸不一致时上报 fitted 小盒子，父件跟着缩水、
/// 段高与规划脱节（实测：方图按 510.2×700 显示，SizedBox 包裹后盒高
/// 仍只剩 510.2）。本 widget 在 `layout()` 里亲自把 `box` 写死为
/// 规划尺寸，子件只在盒内按比例绘制（不拉伸，顶对齐）。真实内容
/// 宽高比与规划一致，盒内无留白。
class _FixedSizeBox extends pw.SingleChildWidget {
  _FixedSizeBox({
    required this.width,
    required this.height,
    required pw.Widget child,
  }) : super(child: child);

  /// 盒宽（pt，规划显示宽）。
  final double width;

  /// 盒高（pt，规划显示高）。
  final double height;

  @override
  void layout(
    pw.Context context,
    pw.BoxConstraints constraints, {
    bool parentUsesSize = false,
  }) {
    child!.layout(
      context,
      pw.BoxConstraints.tightFor(width: width, height: height),
      parentUsesSize: parentUsesSize,
    );
    box = PdfRect.fromPoints(PdfPoint.zero, PdfPoint(width, height));
  }

  // D-188：pdf 包的 SingleChildWidget 不重写 paint（Widget.paint
  // 默认空操作），只重写 layout 会导致子件图片永远不画（十五批
  // 20261121.pdf 公式/配图全丢的根源）。照抄 ConstrainedBox.paint：
  // 先画自身（空操作），再画子件。
  @override
  void paint(pw.Context context) {
    super.paint(context);
    paintChild(context);
  }
}

/// C 路线内容构建器：规划（[CPagePlan]）→ pdf widgets → [pw.Document]。
class CContentBuilder {
  CContentBuilder._();

  /// 按规划建文档（第二遍布局）。
  ///
  /// [plan] 为分页器输出；[tempDir] 为任务临时目录（图片引用相对
  /// 于此）；[questions] 为每题记录（须覆盖规划中出现的全部
  /// questionIndex，否则抛 [ArgumentError]——来源行缺失是硬错，
  /// 不能静默按无来源行印）；[documentBuilder] / [metadata] /
  /// [headerInfo] / [info] 同 A 路线。
  /// [totalPagesOverride]：答案版（M2-1）时题目区页脚分母须为
  /// 题目页 + 答案区页（答案区另起 MultiPage 接在后面，页码全局
  /// 连续）；不传时分母为规划页数（练习版原行为，不变）。
  static Future<CBuildResult> buildDocument({
    required CPagePlan plan,
    required Directory tempDir,
    required List<CBuildQuestion> questions,
    required PdfExportDocumentBuilder documentBuilder,
    required PdfExportMetadata metadata,
    required PdfExportHeaderInfo headerInfo,
    required PdfExportInfo info,
    int? totalPagesOverride,
  }) async {
    if (plan.pages.isEmpty) {
      throw StateError('本次没有可导出题目');
    }
    final byIndex = {
      for (final q in questions) q.questionIndex: q,
    };
    for (final page in plan.pages) {
      for (final part in page.parts) {
        if (!byIndex.containsKey(part.questionIndex)) {
          throw ArgumentError(
            '规划含题序 ${part.questionIndex}，但未提供其构建记录',
          );
        }
      }
    }
    // 预读全部图片字节（引用去重；文档本身也要持有这些字节，预读
    // 不增加峰值；缺失引用在此处一次报清）。
    final imageBytes = <String, Uint8List>{};
    for (final page in plan.pages) {
      for (final part in page.parts) {
        for (final block in part.blocks) {
          switch (block) {
            case CPartRichText(:final inlineFormulas):
              for (final f in inlineFormulas) {
                await _readImageBytes(
                  tempDir: tempDir,
                  ref: f.ref,
                  questionNumber: part.displayNumber,
                  into: imageBytes,
                );
              }
            case CPartImage(:final ref):
              await _readImageBytes(
                tempDir: tempDir,
                ref: ref,
                questionNumber: part.displayNumber,
                into: imageBytes,
              );
          }
        }
      }
    }
    final children = <pw.Widget>[
      _infoZoneWidget(documentBuilder, info),
      for (final page in plan.pages)
        for (final part in page.parts)
          _partWidget(
            part: part,
            sourceText: byIndex[part.questionIndex]!.sourceText,
            isLastQuestion: part.questionIndex == _lastQuestionIndex(plan),
            imageBytes: imageBytes,
            documentBuilder: documentBuilder,
          ),
    ];
    final document = documentBuilder.createDocument(metadata: metadata);
    document.addPage(
      documentBuilder.multiPage(
        children: children,
        plan: PdfPaginationPlan(
          totalPages: totalPagesOverride ?? plan.pages.length,
        ),
        headerInfo: headerInfo,
      ),
    );
    return CBuildResult(
      document: document,
      plan: plan,
      questions: _collectResults(plan: plan, byIndex: byIndex),
      totalPages: plan.pages.length,
    );
  }

  /// 仅建 MultiPage 的 children（信息区 + 每段一个 Inseparable）。
  ///
  /// 供测试复用（包一层 paint 记录可验每段实际落在哪页）；
  /// [buildDocument] 内部同样走这里（再包 multiPage）。
  /// 调用前须保证图片引用都存在（[buildDocument] 已预读校验；
  /// 直接调本方法时缺失引用抛 [SnapshotInfrastructureException]）。
  static Future<List<pw.Widget>> buildChildren({
    required CPagePlan plan,
    required Directory tempDir,
    required List<CBuildQuestion> questions,
    required PdfExportDocumentBuilder documentBuilder,
    required PdfExportInfo info,
  }) async {
    final byIndex = {
      for (final q in questions) q.questionIndex: q,
    };
    final imageBytes = <String, Uint8List>{};
    for (final page in plan.pages) {
      for (final part in page.parts) {
        for (final block in part.blocks) {
          switch (block) {
            case CPartRichText(:final inlineFormulas):
              for (final f in inlineFormulas) {
                await _readImageBytes(
                  tempDir: tempDir,
                  ref: f.ref,
                  questionNumber: part.displayNumber,
                  into: imageBytes,
                );
              }
            case CPartImage(:final ref):
              await _readImageBytes(
                tempDir: tempDir,
                ref: ref,
                questionNumber: part.displayNumber,
                into: imageBytes,
              );
          }
        }
      }
    }
    return <pw.Widget>[
      _infoZoneWidget(documentBuilder, info),
      for (final page in plan.pages)
        for (final part in page.parts)
          _partWidget(
            part: part,
            sourceText: byIndex[part.questionIndex]?.sourceText ?? '',
            isLastQuestion: part.questionIndex == _lastQuestionIndex(plan),
            imageBytes: imageBytes,
            documentBuilder: documentBuilder,
          ),
    ];
  }

  /// 规划中最后一道题的题序（分隔线只印到倒数第二题为止；
  /// 分页器的 isLastQuestion 即按此口径）。
  static int _lastQuestionIndex(CPagePlan plan) {
    var last = -1;
    for (final page in plan.pages) {
      for (final part in page.parts) {
        if (part.questionIndex > last) last = part.questionIndex;
      }
    }
    return last;
  }

  /// 读一张图片的字节（去重；缺失抛基础设施异常，整单中止）。
  static Future<void> _readImageBytes({
    required Directory tempDir,
    required String ref,
    required int questionNumber,
    required Map<String, Uint8List> into,
  }) async {
    if (into.containsKey(ref)) return;
    final file = File(
      '${tempDir.path}${Platform.pathSeparator}'
      '${ref.replaceAll('/', Platform.pathSeparator)}',
    );
    late final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on FileSystemException catch (e) {
      throw SnapshotInfrastructureException(
        '第 $questionNumber 题图片缺失（${e.path ?? ref}），本次导出中止。',
      );
    }
    into[ref] = bytes;
  }

  /// 第一页导出信息区（5 行 × 10 pt；自然高度，正常为 72.6 pt）。
  static pw.Widget _infoZoneWidget(
    PdfExportDocumentBuilder documentBuilder,
    PdfExportInfo info,
  ) {
    return documentBuilder.buildExportInfoZone(info);
  }

  /// 一段（规划的一页内一组内容）→ 一个 Inseparable。
  ///
  /// 段内顺序：题号行 / 续页标行 → 来源行（首段且非空）→ 内容块 →
  /// 「本题完」（末段且为拆分题）或预留行空白（非末段）→ 分隔线
  /// （末段且非末题；分隔线在段内，段高才与规划一致）。
  static pw.Widget _partWidget({
    required CQuestionPart part,
    required String sourceText,
    required bool isLastQuestion,
    required Map<String, Uint8List> imageBytes,
    required PdfExportDocumentBuilder documentBuilder,
  }) {
    final children = <pw.Widget>[];
    if (part.continuation) {
      children.add(
        documentBuilder.spanText(
          '第 ${part.displayNumber} 题（接上页）',
          style: documentBuilder.bodyStyle,
        ),
      );
    } else {
      children.add(
        pw.Text(
          '第 ${part.displayNumber} 题',
          style: documentBuilder.questionNumberStyle,
        ),
      );
      if (sourceText.isNotEmpty) {
        children.add(
          documentBuilder.spanText(
            sourceText,
            style: documentBuilder.headerFooterStyle,
          ),
        );
      }
    }
    for (final block in part.blocks) {
      switch (block) {
        case CPartRichText():
          children.add(
            _richTextWidget(block, imageBytes, documentBuilder),
          );
        case CPartImage():
          children.add(
            _sizedImage(
              bytes: imageBytes[block.ref]!,
              widthPt: block.widthPt,
              heightPt: block.heightPt,
            ),
          );
      }
    }
    if (part.last) {
      if (part.continuation) {
        // 拆分题末段：印「本题完」（占预留的一行）。
        children.add(
          pw.Text(
            '本题完',
            style: pw.TextStyle(
              font: documentBuilder.font,
              fontSize: PdfExportTypography.bodyPt,
              color: PdfColors.grey700,
            ),
          ),
        );
      }
      // 分隔线（末段且非末题；规划把 8.5 pt 计在本段高度里）。
      if (!isLastQuestion) children.add(_separatorWidget());
    } else {
      // 非末段：预留的「本题完」行以空白占位，段高与规划一致。
      children.add(
        pw.SizedBox(height: kPdfBodySingleLineHeightPt),
      );
    }
    return pw.Inseparable(
      canSpan: false,
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  /// 富文本段：无行内公式走 spanText；有行内公式走 RichText +
  /// WidgetSpan（与 spanText 同一条 C-6 规则：TextOverflow.span）。
  static pw.Widget _richTextWidget(
    CPartRichText block,
    Map<String, Uint8List> imageBytes,
    PdfExportDocumentBuilder documentBuilder,
  ) {
    final style = block.fontSizePt == PdfExportTypography.bodyPt
        ? documentBuilder.bodyStyle
        : documentBuilder.bodyStyle.copyWith(fontSize: block.fontSizePt);
    if (block.inlineFormulas.isEmpty) {
      return documentBuilder.spanText(block.text, style: style);
    }
    // 行内公式按基线对齐（十八批 P1，见文件头）；基线未知时旧居中。
    final singleLine = pdfTextHeightPt(
      lines: 1,
      fontSizePt: block.fontSizePt,
      lineSpacingPt: block.fontSizePt == PdfExportTypography.bodyPt
          ? kPdfBodyLineSpacingPt
          : 0,
    );
    final spans = <pw.InlineSpan>[];
    var cursor = 0;
    for (final f in block.inlineFormulas) {
      if (f.offset > cursor) {
        spans.add(
          pw.TextSpan(text: block.text.substring(cursor, f.offset)),
        );
      }
      final baseline = f.baselineOffsetPt == null
          ? (singleLine - f.heightPt) / 2
          : f.baselineOffsetPt! - f.heightPt;
      spans.add(
        pw.WidgetSpan(
          baseline: baseline,
          child: _sizedImage(
            bytes: imageBytes[f.ref]!,
            widthPt: f.widthPt,
            heightPt: f.heightPt,
          ),
        ),
      );
      cursor = f.offset;
    }
    if (cursor < block.text.length) {
      spans.add(pw.TextSpan(text: block.text.substring(cursor)));
    }
    return pw.RichText(
      text: pw.TextSpan(style: style, children: spans),
      overflow: pw.TextOverflow.span,
    );
  }

  /// 定尺寸图片：外层盒子钉死规划尺寸（见文件头“图片尺寸钉死”），
  /// 内层 Image 在盒内按比例居中、不拉伸。
  static pw.Widget _sizedImage({
    required Uint8List bytes,
    required double widthPt,
    required double heightPt,
  }) {
    return _FixedSizeBox(
      width: widthPt,
      height: heightPt,
      child: pw.Image(
        pw.MemoryImage(bytes),
        width: widthPt,
        height: heightPt,
      ),
    );
  }

  /// 题间分隔线（8.5 pt = 上 4 pt + 0.5 pt 细灰线 + 下 4 pt）。
  static pw.Widget _separatorWidget() => pw.Column(
        children: [
          pw.SizedBox(height: 4),
          pw.Container(
            height: 0.5,
            width: PdfExportGeometry.contentWidthPt,
            color: PdfColors.grey300,
          ),
          pw.SizedBox(height: 4),
        ],
      );

  /// 按规划汇总每题结果（段数、规划页号、原图/缩小标记、状态）。
  static List<CQuestionBuildResult> _collectResults({
    required CPagePlan plan,
    required Map<int, CBuildQuestion> byIndex,
  }) {
    final partsByQuestion = <int, List<CQuestionPart>>{};
    final pagesByQuestion = <int, List<int>>{};
    for (var pi = 0; pi < plan.pages.length; pi++) {
      for (final part in plan.pages[pi].parts) {
        (partsByQuestion[part.questionIndex] ??= []).add(part);
        (pagesByQuestion[part.questionIndex] ??= []).add(pi + 1);
      }
    }
    final results = <CQuestionBuildResult>[];
    final indices = partsByQuestion.keys.toList()..sort();
    for (final qi in indices) {
      final parts = partsByQuestion[qi]!;
      final q = byIndex[qi]!;
      var hasOriginal = false;
      var hasShrunk = false;
      for (final part in parts) {
        for (final block in part.blocks) {
          if (block is CPartImage) {
            if (block.isOriginal) hasOriginal = true;
            if (block.shrunk) hasShrunk = true;
          } else if (block is CPartRichText) {
            // D-188：行内公式的原图/缩小标记同样汇总——只扫 CPartImage
            // 时，只有行内公式降级的题会被误判 COMPLETE 而非 PARTIAL。
            for (final f in block.inlineFormulas) {
              if (f.isOriginal) hasOriginal = true;
              if (f.shrunk) hasShrunk = true;
            }
          }
        }
      }
      results.add(
        CQuestionBuildResult(
          questionId: q.questionId,
          title: q.title,
          questionNumber: parts.first.displayNumber,
          status: hasOriginal
              ? CBuildQuestionStatus.partial
              : CBuildQuestionStatus.printed,
          segmentCount: parts.length,
          plannedPages: pagesByQuestion[qi]!.toSet().toList()..sort(),
          hasOriginalFormula: hasOriginal,
          hasShrunkFormula: hasShrunk,
          warnings: List.of(q.warnings),
        ),
      );
    }
    return results;
  }
}
