// 十六批 C（D-194/D-197/D-198/D-199）：Word 内容构建器——快照块序列
// → docx 节点（WORD-DESIGN.md §2.4/§3/§4）。
//
// 唯一的快照→docx 翻译层。只读快照的冻结内容，不改快照、不写库：
//  - 每题只读三样东西：(1) entry.title / entry.folderNames /
//    entry.examName（来源行，经 [recordsById] + [sourceTextFor] 拼，
//    与 PDF `_planC` / A 路线 `aSourceTexts` 同口径）；(2)
//    entry.ocrContent?.blocks（C 路线去重后的块序列，D-189；不得按
//    ocrStem + option_contents 自行重拼）；(3) entry.sliceCopy（A
//    路线切片副本引用）与 entry.ocrContent.figures 的 tempRelativePath
//   （图文件在 snapshot.tempDir 内，按相对路径取字节）。
//  - 不读 ExportQuestionRecord 的 ocrRaw / md_results（快照已消化完）；
//  - 不读 LaTeX 源码：FormulaBlock 只取栅格化后的位图引用（[formulaVerdicts]
//    里 `FormulaRasterResult.relativePath`），不取源码字段（C-11）。
//  - 不得新增 WordSnapshot / WordPrintability / WordGuard 等平行模型。
//
// 服务侧准备的输入（非快照内容，编排层在调用前算好，与 PDF
// `PdfExportService` 的栅格化/增强准备同款）：
//  - [formulaVerdicts]：C 路线逐题公式裁决（栅格化位图在快照临时目录
//    内，`relativePath` 取字节；无公式的题无裁决）；任一公式失败 →
//    整题不印（与 PDF `_rasterizeSnapshotFormulas` 同口径）；
//  - [aPrepared]：A 路线逐题增强结果（增强后字节 + 上限后尺寸 +
//    清晰度门禁结论）；段规划复用 `AContentBuilder.planQuestions`
//   （与 PDF A 路线同一批切段、同一固定缩放比例）；
//  - [recordsById] + [sourceTextFor]：来源行与题型名（快照条目里没有
//    学科 ID 与题型；不传则不印来源行、不写题型后缀，与 PDF
//    “不传则不印来源行”同款默认）。
import 'dart:io';
import 'dart:typed_data';

import 'package:docx_creator/docx_creator.dart';
import 'package:image/image.dart' as img;

import '../../modules/ocr/question_classifier.dart';
import '../../modules/ocr/question_content.dart';
import '../pdf_export/a_content_builder.dart';
import '../pdf_export/answer_section.dart';
import '../pdf_export/export_question_record.dart';
import '../pdf_export/export_route.dart';
import '../pdf_export/export_snapshot.dart';
import '../pdf_export/export_versions.dart';
import '../pdf_export/formula_rasterizer.dart';
import '../pdf_export/slice_snapshot.dart' show readPngDimensions;
import 'word_answer_section.dart';
import 'word_document_builder.dart';
import 'word_font.dart';
import 'word_page_estimate.dart';

/// A 路线逐题增强结果（服务侧准备，见 [WordAPreparedQuestion]）。
///
/// 由 `ImageEnhancer.enhanceSlice`（快照临时副本字节）+ 清晰度门禁
/// 判定产出，与 PDF `AContentBuilder._prepareEntry` 同口径；本构建器
/// 只消费，不重算增强、不重做门禁。
class WordAPreparedQuestion {
  const WordAPreparedQuestion({
    this.enhancedBytes,
    this.cappedWidthPx = 0,
    this.cappedHeightPx = 0,
    this.isBroken = false,
    this.brokenReason,
    this.isSkipped = false,
    this.skipReason,
    this.enhanceFallback = false,
    this.lowDpi = false,
    this.effectiveDpi = 0,
    required this.warnings,
  });

  /// 增强后 PNG 字节（可印题有值；BROKEN/跳过题为 null）。
  final Uint8List? enhancedBytes;

  /// 300 DPI 上限后像素尺寸（可印题有值）。
  final int cappedWidthPx;
  final int cappedHeightPx;

  /// 是否 BROKEN（占位；源切片缺失/损坏/无法解码）。
  final bool isBroken;

  /// BROKEN 原因（占位说明第二行）。
  final String? brokenReason;

  /// 是否跳过（不印；清晰度门禁排除时）。
  final bool isSkipped;

  /// 跳过原因（status 为 skipped 时非空）。
  final String? skipReason;

  /// 是否增强失败回退（题面警告“增强失败，已用原图”，PARTIAL）。
  final bool enhanceFallback;

  /// 是否低于清晰度阈值（已标记，PARTIAL）。
  final bool lowDpi;

  /// 有效分辨率（DPI）。
  final double effectiveDpi;

  /// 警告（降级内容、跳过原因等，供报告用）。
  final List<String> warnings;
}

/// 一道已印出题的构建结果（供服务层组装完整性报告用；状态判定复用
/// `classifyC` / `classifyA`，与 PDF `_finishC` / `_finishA` 同口径）。
class WordBuiltQuestion {
  const WordBuiltQuestion({
    required this.questionId,
    required this.displayNumber,
    required this.warnings,
    this.formulaOriginal = false,
    this.figureMissing = false,
    this.optionUncertain = false,
    this.contentParseFallback = false,
    this.enhanceFallback = false,
    this.lowDpi = false,
    this.isBroken = false,
  });

  /// 题目 ID。
  final String questionId;

  /// 导出内题号（从 1 计，只计已印出的题；跳过题不占题号）。
  final int displayNumber;

  /// 警告（降级内容等，供报告用）。
  final List<String> warnings;

  /// 是否有公式为原图（C 路线 PARTIAL 判定用）。
  final bool formulaOriginal;

  /// 是否图块缺失（C 路线 PARTIAL 判定用）。
  final bool figureMissing;

  /// 选项切分是否不确定（C 路线 PARTIAL 判定用）。
  final bool optionUncertain;

  /// 内容解析是否回退（C 路线 PARTIAL 判定用）。
  final bool contentParseFallback;

  /// 是否增强失败回退（A 路线 PARTIAL 判定用）。
  final bool enhanceFallback;

  /// 是否低于清晰度阈值（A 路线 PARTIAL 判定用）。
  final bool lowDpi;

  /// 是否 BROKEN 占位（A 路线）。
  final bool isBroken;
}

/// buildWordContent 的输出：已建好的文档骨架 + 逐题构建结果。
class WordContentResult {
  const WordContentResult({
    required this.document,
    required this.questions,
    required this.displayNumbersById,
    required this.imageCount,
    required this.estimatedPageCount,
  });

  /// 已含全部题目段落与答案区的文档（待 `exportToBytes`）。
  final DocxDocumentBuilder document;

  /// 已印出题的构建结果（按题号顺序；跳过题不在其中）。
  final List<WordBuiltQuestion> questions;

  /// 已印出题的题号表（题目 ID → 导出内题号；答案区与报告用）。
  final Map<String, int> displayNumbersById;

  /// 本次嵌入的图片部件数（交付校验 `defaultDocxFileValidator` 用：
  /// `word/media/*` 部件数须与此一致，防导出器静默丢图）。
  final int imageCount;

  /// 估计总页数（十七批 A4，D-207：内容高度贪心分页模拟，见
  /// word_page_estimate.dart；只是估计，完成界面以「约 N 页
  /// （估计值）」展示，实际页数以 Word 打开为准）。
  final int estimatedPageCount;

  /// 已印出题数。
  int get printedCount => questions.length;
}

/// 快照 → docx 翻译入口（WORD-DESIGN.md §2.4）。
///
/// 输入为已冻结的 [ExportSnapshot]（只读）；输出为已含全部题目段落
/// 与答案区的 [DocxDocumentBuilder]（待 `exportToBytes`）。
/// 题间不人为分页（分页由 Word 自然分页；答案区前的分页符除外）；
/// 续页不标「接上页」/「本题完」（Word 自然分页不知道断点在哪）。
WordContentResult buildWordContent({
  required ExportSnapshot snapshot,
  required Map<String, AnswerSourceData> answersById,
  required ExportVersionSelection versions,
  String subjectName = '多学科',
  Map<String, ExportQuestionRecord>? recordsById,
  String Function(ExportQuestionRecord record)? sourceTextFor,
  Map<String, QuestionFormulaVerdict> formulaVerdicts = const {},
  Map<String, WordAPreparedQuestion> aPrepared = const {},
}) {
  final now = DateTime.now();
  final exportDateText =
      '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
  final builder = DocxDocumentBuilder();
  // 十七批 A4（D-207）：建文档的同时把每段的估计高度喂给分页模拟器
  //（只做加法，不影响文档本身；估计值随 WordContentResult 返回）。
  final pageEstimator = WordPageEstimator();
  applyWordSection(
    builder,
    header: wordHeader(
      subjectName: subjectName,
      exportDateText: exportDateText,
    ),
    footer: wordFooter(),
  );

  final routeNotice = ExportRouteDecision(
    route: snapshot.route,
    reason: snapshot.route == ExportRoute.c ? '已配置 OCR key' : '未配置 OCR key',
  ).notice;

  // --- 第一遍：定已印出题与题号（跳过题不占题号，BROKEN 占位题占题号）。
  final planned = <_PlannedQuestion>[];
  var displayNumber = 0;
  for (var qi = 0; qi < snapshot.entries.length; qi++) {
    final entry = snapshot.entries[qi];
    if (entry.outcome == SnapshotOutcome.skipped) continue;
    if (snapshot.route == ExportRoute.c) {
      if (formulaVerdicts[entry.questionId]?.skipQuestion == true) {
        continue;
      }
      if (entry.ocrContent == null) continue;
    } else {
      final prep = aPrepared[entry.questionId];
      if (prep == null || prep.isSkipped) continue;
    }
    displayNumber++;
    planned.add(
      _PlannedQuestion(entry: entry, questionIndex: qi, number: displayNumber),
    );
  }
  final displayNumbersById = {
    for (final p in planned) p.entry.questionId: p.number,
  };

  // --- 标题 + 说明段（导出信息区，与 PdfExportInfo.lines 同款 5 行）。
  builder.paragraph(
    wordTextParagraph(
      '错题本导出',
      fontSize: WordTypography.titlePt,
      bold: true,
      align: DocxAlign.center,
      spacingAfter: 120,
    ),
  );
  pageEstimator.addText(
    text: '错题本导出',
    fontSize: WordTypography.titlePt,
    spacingAfterPt: 6,
  );
  for (final line in <String>[
    '筛选：${snapshot.filterText}',
    '题数：${planned.length} 道',
    '日期：$exportDateText',
    '排序：${snapshot.sortText}',
    '路线：$routeNotice',
  ]) {
    builder.paragraph(
      wordTextParagraph(
        line,
        fontSize: WordTypography.infoPt,
        spacingAfter: 60,
      ),
    );
    pageEstimator.addText(
      text: line,
      fontSize: WordTypography.infoPt,
      spacingAfterPt: 3,
    );
  }

  // --- A 路线：段规划（复用 PDF A 路线同一批切段，见 §4.3）。
  Map<String, List<APlannedSegment>> aSegmentsById = const {};
  if (snapshot.route == ExportRoute.a && planned.isNotEmpty) {
    final planInputs = <APlanQuestion>[];
    for (final p in planned) {
      final prep = aPrepared[p.entry.questionId]!;
      final sourceText = _sourceText(p, recordsById, sourceTextFor);
      if (prep.isBroken) {
        planInputs.add(
          APlanQuestion(
            questionId: p.entry.questionId,
            questionNumber: p.number,
            cappedWidthPx: 0,
            cappedHeightPx: 0,
            isBroken: true,
            brokenReason: prep.brokenReason,
            sourceText: sourceText,
          ),
        );
      } else {
        planInputs.add(
          APlanQuestion(
            questionId: p.entry.questionId,
            questionNumber: p.number,
            cappedWidthPx: prep.cappedWidthPx,
            cappedHeightPx: prep.cappedHeightPx,
            sourceText: sourceText,
          ),
        );
      }
    }
    final plan = AContentBuilder.planQuestions(questions: planInputs);
    final segments = <String, List<APlannedSegment>>{};
    final broken = <String, APlannedBroken>{};
    for (final page in plan.pages) {
      for (final item in page.items) {
        if (item is APlannedSegment) {
          (segments[item.questionId] ??= []).add(item);
        } else if (item is APlannedBroken) {
          broken[item.questionId] = item;
        }
      }
    }
    aSegmentsById = segments;
  }

  // --- 第二遍：逐题建段落。
  final built = <WordBuiltQuestion>[];
  var imageCount = 0;
  for (var pi = 0; pi < planned.length; pi++) {
    final p = planned[pi];
    final entry = p.entry;
    final warnings = <String>[...entry.warnings];
    void addWarning(String w) {
      if (!warnings.contains(w)) warnings.add(w);
    }

    // 题号行：`第 N 题` + 题型（题型为 NULL 时不写括号部分，不猜题型）。
    final record = recordsById?[entry.questionId];
    final typeName = record == null || record.questionType == null
        ? null
        : questionTypeLabels[record.questionType];
    final numberLine = typeName == null
        ? '第 ${p.number} 题'
        : '第 ${p.number} 题（$typeName）';
    builder.paragraph(
      wordTextParagraph(
        numberLine,
        fontSize: WordTypography.questionNumberPt,
        bold: true,
        spacingBefore: pi == 0 ? null : 120,
        spacingAfter: 60,
      ),
    );
    pageEstimator.addText(
      text: numberLine,
      fontSize: WordTypography.questionNumberPt,
      spacingBeforePt: pi == 0 ? 0 : 6,
      spacingAfterPt: 3,
    );

    var formulaOriginal = false;
    var figureMissing = false;
    var enhanceFallback = false;
    var lowDpi = false;
    var isBroken = false;

    if (snapshot.route == ExportRoute.c) {
      final ocr = entry.ocrContent!;
      final verdict = formulaVerdicts[entry.questionId];
      final converted = _convertCQuestion(
        entry: entry,
        questionIndex: p.questionIndex,
        verdict: verdict,
        tempDir: snapshot.tempDir,
        builder: builder,
        addWarning: addWarning,
        onImageEmbedded: () => imageCount++,
        pageEstimator: pageEstimator,
      );
      formulaOriginal = converted.hasOriginalFormula;
      figureMissing = converted.figureMissing;
      if (converted.hasOriginalFormula) addWarning('公式为原图');
      if (converted.hasShrunkFormula) addWarning('公式已缩小');
      if (converted.figureMissing) addWarning('图块缺失');
      // 逐题来源行（快照冻结值；不传 sourceTextFor 则不印）。
      final sourceText = _sourceText(p, recordsById, sourceTextFor);
      if (sourceText.isNotEmpty) {
        builder.paragraph(
          wordTextParagraph(
            sourceText,
            fontSize: WordTypography.sourcePt,
            color: DocxColor.gray,
            spacingAfter: 60,
          ),
        );
        pageEstimator.addText(
          text: sourceText,
          fontSize: WordTypography.sourcePt,
          spacingAfterPt: 3,
        );
      }
      built.add(
        WordBuiltQuestion(
          questionId: entry.questionId,
          displayNumber: p.number,
          warnings: warnings,
          formulaOriginal: formulaOriginal,
          figureMissing: figureMissing,
          optionUncertain: ocr.hasOptionUncertain,
          contentParseFallback: ocr.contentParseFallback,
        ),
      );
    } else {
      final prep = aPrepared[entry.questionId]!;
      final sourceText = _sourceText(p, recordsById, sourceTextFor);
      if (prep.isBroken) {
        isBroken = true;
        // BROKEN 占位：题号行 + 来源行（有则印）+ 占位说明（2 行，与
        // PDF `_brokenBlockWidget` 同口径；原因超 40 字截断加省略号）。
        if (sourceText.isNotEmpty) {
          builder.paragraph(
            wordTextParagraph(
              sourceText,
              fontSize: WordTypography.sourcePt,
              color: DocxColor.gray,
              spacingAfter: 60,
            ),
          );
          pageEstimator.addText(
            text: sourceText,
            fontSize: WordTypography.sourcePt,
            spacingAfterPt: 3,
          );
        }
        builder.paragraph(
          wordTextParagraph(
            '本题图片缺失，无法印出',
            fontSize: WordTypography.bodyPt,
            spacingAfter: 60,
          ),
        );
        pageEstimator.addText(
          text: '本题图片缺失，无法印出',
          fontSize: WordTypography.bodyPt,
          spacingAfterPt: 3,
        );
        final reason = prep.brokenReason ?? '源切片缺失';
        builder.paragraph(
          wordTextParagraph(
            reason.length > 40 ? '${reason.substring(0, 40)}…' : reason,
            fontSize: WordTypography.bodyPt,
            color: DocxColor.gray,
            spacingAfter: 60,
          ),
        );
        pageEstimator.addText(
          text: reason.length > 40 ? '${reason.substring(0, 40)}…' : reason,
          fontSize: WordTypography.bodyPt,
          spacingAfterPt: 3,
        );
      } else {
        enhanceFallback = prep.enhanceFallback;
        lowDpi = prep.lowDpi;
        if (prep.enhanceFallback) addWarning('增强失败，已用原图');
        // 段落依次排列；续页标不印（Word 自然分页不知道段落在第几页，
        // 印「接上页」会错位）；题号行只出现在第一段之前。
        final segments = aSegmentsById[entry.questionId] ?? const [];
        final bytes = prep.enhancedBytes!;
        img.Image? decoded;
        for (final seg in segments) {
          if (seg.isFirst && sourceText.isNotEmpty) {
            builder.paragraph(
              wordTextParagraph(
                sourceText,
                fontSize: WordTypography.sourcePt,
                color: DocxColor.gray,
                spacingAfter: 60,
              ),
            );
            pageEstimator.addText(
              text: sourceText,
              fontSize: WordTypography.sourcePt,
              spacingAfterPt: 3,
            );
          }
          Uint8List png;
          if (segments.length == 1) {
            // 单段题直接嵌增强后 PNG 字节，不重编码。
            png = bytes;
          } else {
            decoded ??= img.decodeImage(bytes);
            if (decoded == null) {
              throw StateError('增强后图像无法解码（${entry.questionId}）');
            }
            final cropped = img.copyCrop(
              decoded,
              x: 0,
              y: seg.yStartPx,
              width: prep.cappedWidthPx,
              height: seg.heightPx,
            );
            png = img.encodePng(cropped);
          }
          checkWordImageDpi(
            widthPx: prep.cappedWidthPx,
            displayWidthPt: kWordContentWidthPt,
          );
          builder.image(
            wordImageBlock(
              png,
              widthPt: kWordContentWidthPt,
              heightPt: seg.displayHeightPt,
            ),
          );
          pageEstimator.addAtomic(seg.displayHeightPt);
          imageCount++;
        }
      }
      built.add(
        WordBuiltQuestion(
          questionId: entry.questionId,
          displayNumber: p.number,
          warnings: warnings,
          enhanceFallback: enhanceFallback,
          lowDpi: lowDpi,
          isBroken: isBroken,
        ),
      );
    }

    // 题间分隔线；最后一题后不画分隔线；答案区之前用分页符，不用分隔线。
    if (pi < planned.length - 1) {
      builder.hr();
      pageEstimator.addSpacer(kWordEstimatedHrHeightPt);
    }
  }

  // --- 答案区（答案版勾选时）：另起一页，只含已印出的题。
  if (versions.answer && planned.isNotEmpty) {
    final answerSources = [
      for (final p in planned)
        answersById[p.entry.questionId] ??
            AnswerSourceData(questionId: p.entry.questionId),
    ];
    final entries = buildAnswerEntries(
      displayNumbersById: displayNumbersById,
      sources: answerSources,
    );
    addWordAnswerSection(builder, entries, pageEstimator: pageEstimator);
  }

  return WordContentResult(
    document: builder,
    questions: built,
    displayNumbersById: displayNumbersById,
    imageCount: imageCount,
    estimatedPageCount: pageEstimator.estimatedPageCount,
  );
}

/// 一道已规划题（题号已定）。
class _PlannedQuestion {
  const _PlannedQuestion({
    required this.entry,
    required this.questionIndex,
    required this.number,
  });

  final SnapshotQuestionEntry entry;

  /// 在 snapshot.entries 里的序号（公式编号 `q<序号>-f<n>` 与 PDF
  /// `_convertCQuestion` / `_rasterizeOneQuestion` 同口径）。
  final int questionIndex;

  /// 导出内题号。
  final int number;
}

/// 逐题来源行文字（快照冻结值；不传 [sourceTextFor] 则不印来源行，
/// 与 PDF “不传则不印来源行”同款默认）。
String _sourceText(
  _PlannedQuestion p,
  Map<String, ExportQuestionRecord>? recordsById,
  String Function(ExportQuestionRecord record)? sourceTextFor,
) {
  final record = recordsById?[p.entry.questionId];
  if (record == null || sourceTextFor == null) return '';
  return sourceTextFor(record);
}

/// C 路线一题的块序列 → docx 节点（与 PDF `_convertCQuestion`
/// 同口径的块走访；只翻译，不重排、不重拼）。
///
/// - TextBlock / CodeBlock / HeadingBlock → 段落文本；
/// - 行内公式 → 段落内行内公式图（图文混排段，不得另起一段）；
/// - 独立公式 / 图块 → 独立图片段落（居中）；
/// - ImageFallbackBlock → 不印（导出不采用整题切片回退）；
/// - TableBlock → 单元格展平为行文本（公式随行内处理）。
_CConverted _convertCQuestion({
  required SnapshotQuestionEntry entry,
  required int questionIndex,
  required QuestionFormulaVerdict? verdict,
  required Directory tempDir,
  required DocxDocumentBuilder builder,
  required void Function(String warning) addWarning,
  required void Function() onImageEmbedded,
  required WordPageEstimator pageEstimator,
}) {
  final ocr = entry.ocrContent!;
  final byId = {
    for (final outcome in verdict?.outcomes ?? const [])
      outcome.formulaId: outcome,
  };
  var formulaCounter = 0;
  var hasOriginal = false;
  var hasShrunk = false;
  var figureMissing = false;
  var imageShrunk = false;

  var paraInlines = <DocxInline>[];

  void flushParagraph() {
    if (paraInlines.isEmpty) return;
    builder.paragraph(
      wordMixedParagraph(List.of(paraInlines), spacingAfter: 60),
    );
    // 十七批 A4（D-207）：混排段按行内图文折行估高（段后 60 twips = 3 pt）。
    pageEstimator.addMixedParagraph(paraInlines, spacingAfterPt: 3);
    paraInlines = <DocxInline>[];
  }

  void addTextRuns(String text, {List<TextRun>? runs, bool bold = false}) {
    if (runs != null && runs.isNotEmpty) {
      for (final run in runs) {
        if (run.text.isEmpty) continue;
        paraInlines.add(
          DocxText(
            run.text,
            fontSize: WordTypography.bodyPt,
            fontFamily: kWordFontFamily,
            fontWeight:
                run.bold || bold ? DocxFontWeight.bold : DocxFontWeight.normal,
            fontStyle:
                run.italic ? DocxFontStyle.italic : DocxFontStyle.normal,
            isSuperscript: run.script == 1,
            isSubscript: run.script == -1,
          ),
        );
      }
      return;
    }
    if (text.isEmpty) return;
    paraInlines.add(
      wordRun(text, fontSize: WordTypography.bodyPt, bold: bold),
    );
  }

  /// 嵌一张图（独立公式/图块）：尺寸复核 + 超高缩小 + 计数。
  void addStandaloneImage(
    Uint8List pngBytes, {
    required double widthPt,
    required double heightPt,
    required bool isFormula,
  }) {
    final dims = readPngDimensions(pngBytes);
    if (dims != null) {
      checkWordImageDpi(widthPx: dims.width, displayWidthPt: widthPt);
    }
    var w = widthPt;
    var h = heightPt;
    if (h > kWordMaxImageHeightPt) {
      final scale = kWordMaxImageHeightPt / h;
      w *= scale;
      h = kWordMaxImageHeightPt;
      if (isFormula) {
        hasShrunk = true;
      } else {
        imageShrunk = true;
      }
    }
    builder.image(wordImageBlock(pngBytes, widthPt: w, heightPt: h));
    // 十七批 A4（D-207）：独立图不可拆分，按最终显示高整段计入估计。
    pageEstimator.addAtomic(h);
    onImageEmbedded();
  }

  Uint8List? tempBytes(String relativePath) {
    try {
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}'
        '${relativePath.replaceAll('/', Platform.pathSeparator)}',
      );
      if (!file.existsSync()) return null;
      return file.readAsBytesSync();
    } catch (_) {
      return null;
    }
  }

  void visitBlocks(List<QuestionContentBlock> blocks) {
    for (final block in blocks) {
      switch (block) {
        case TextBlock(:final text, :final runs):
          addTextRuns(text, runs: runs);
        case HeadingBlock(:final text):
          flushParagraph();
          addTextRuns(text, bold: true);
          flushParagraph();
        case CodeBlock(:final code):
          flushParagraph();
          addTextRuns(code);
          flushParagraph();
        case FormulaBlock(:final displayMode):
          final id = 'q$questionIndex-f${formulaCounter++}';
          final outcome = byId[id];
          final result = outcome?.result;
          if (result == null) {
            // 无裁决结果的公式（不应发生：栅格化覆盖全部公式块）→
            // 防御性跳过该公式块（上游已按 verdict.skipQuestion 把
            // 整题跳过，此处不抛错）。
            continue;
          }
          if (outcome!.kind == FormulaQuestionOutcomeKind.original) {
            hasOriginal = true;
          }
          if (result.shrunk) hasShrunk = true;
          final bytes = tempBytes(result.relativePath);
          if (bytes == null) {
            // 位图文件缺失 → 按图块缺失处理（PARTIAL 降级，不静默丢图）。
            figureMissing = true;
            continue;
          }
          if (displayMode) {
            flushParagraph();
            addStandaloneImage(
              bytes,
              widthPt: result.logicalWidthPt,
              heightPt: result.logicalHeightPt,
              isFormula: true,
            );
          } else {
            paraInlines.add(
              DocxInlineImage(
                bytes: bytes,
                extension: 'png',
                width: result.logicalWidthPt,
                height: result.logicalHeightPt,
              ),
            );
            onImageEmbedded();
          }
        case FigureBlock(:final cropPath):
          flushParagraph();
          final bytes = tempBytes(cropPath);
          if (bytes == null) {
            figureMissing = true;
            continue;
          }
          final size = wordImageSize(bytes);
          if (size == null) {
            figureMissing = true;
            continue;
          }
          if (size.wasHeightCapped) imageShrunk = true;
          addStandaloneImage(
            bytes,
            widthPt: size.widthPt,
            heightPt: size.heightPt,
            isFormula: false,
          );
        case TableBlock(:final rows):
          flushParagraph();
          for (var ri = 0; ri < rows.length; ri++) {
            final row = rows[ri];
            for (var ci = 0; ci < row.length; ci++) {
              visitBlocks(row[ci].children);
              if (ci < row.length - 1 && paraInlines.isNotEmpty) {
                paraInlines.add(
                  wordRun('  ', fontSize: WordTypography.bodyPt),
                );
              }
            }
            flushParagraph();
          }
        case ImageFallbackBlock():
          // 导出不印（§8：不采用整题切片回退，不得印无图可指的图块）。
          break;
      }
    }
  }

  visitBlocks(ocr.blocks);
  flushParagraph();
  if (imageShrunk) addWarning('图片已缩小');
  return _CConverted(
    hasOriginalFormula: hasOriginal,
    hasShrunkFormula: hasShrunk,
    figureMissing: figureMissing,
  );
}

class _CConverted {
  const _CConverted({
    required this.hasOriginalFormula,
    required this.hasShrunkFormula,
    required this.figureMissing,
  });

  final bool hasOriginalFormula;
  final bool hasShrunkFormula;
  final bool figureMissing;
}
