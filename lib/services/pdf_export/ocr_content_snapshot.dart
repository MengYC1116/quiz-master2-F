// 十五批 M1-B：C 路线 OCR 内容快照（M1-DESIGN.md §5/§9，D-177）。
//
// 权威来源（D-177）：库里已存的 `ocr_stem`（题干）+ `option_contents`
// （选项，标签映射 JSON，解析器 v2），导出时不重派 `md_results`
// （重派会丢掉用户纠错）。快照复制纠错后的题干和选项值整体冻结，
// 不只留 questionId 再查库；快照后用户再纠错，当前导出保持快照值。
//
// 组装（§9）：`ocr_stem` + 选项块（按标签顺序重建为 `A. <内容>` 行）
// 拼成 Markdown → `parseQuestionContent` → 块序列。图块不在该
// Markdown 里：图块由快照层按 `ocr_figures` 的放置逻辑以 FigureBlock
// 插入序列——复用详情页渲染器现有图块合并逻辑
// `buildContentBlocks`（ocr_figures.dart，与详情页
// ocr_stem_section.dart 同一套排序：sequence_index / 锚点 / ε 吸附 /
// `"h:s"` 手动锚点），不得另写一套。图块在快照时从当前切片裁剪到
// 任务临时目录（`cropFigurePng`），裁图路径指向任务临时目录。
//
// 可印性判定（§5）与 NULL 四种情形：
// (a) option_contents 为 NULL 且题干含选项 → 选项 inline 在题干里
//     显示，可印（与详情页行为一致）；
// (b) NULL 且题干无选项 → 按选择题要求选项时判不可印；
// (c) 非 NULL 但 JSON 损坏或版本不兼容 → 该题标可疑并按不可印处理，
//     不得悄悄用当前解析器重解释旧数据；
// (d) 非 NULL 但内容为空、标签重复或顺序异常 → 标可疑
//    （`optionSplitUncertain`），走纠错入口，不静默猜。
// NULL 本身不自动等于选项不完整，也不自动等于完整。
//
// 未知解析器版本（§9 REV2）：已知版本只有 v2（`option_contents`
// 列随 schema v6 / Win11 反馈包 5 引入，产出时即记 v2；不存在带 v1
// 标记的旧行）。版本为 NULL 表示未经解析器解析（如人工填写），
// 此时只校验 JSON 形状本身，不按版本拒；版本非 NULL 且 ≠ v2 →
// 未知版本，标可疑并按不可印处理。
//
// 注意：LaTeX 源码只存在于内部数据（FormulaBlock）里，绝不出现在
// 界面、复制文本、报错、日志里（C-11）。本文件的报错与警告只含题号、
// 原因与计数，不含公式内容。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../modules/ocr/ocr_figures.dart';
import '../../modules/ocr/question_content.dart';
import '../../services/glm_ocr_client.dart';
import '../../services/option_contents.dart';
import '../../services/stem_splitter.dart';
import 'export_question_record.dart';
import 'formula_rasterizer.dart';
import 'pdf_document_builder.dart';
import 'slice_snapshot.dart';
import 'snapshot_exceptions.dart';

/// 要求选项的题型（§5 第 3 点）：选择类三型要求已存 option_contents
/// 中至少 2 个标签槽有非空文字。
const Set<String> kChoiceQuestionTypes = {
  'choice_single',
  'choice_multi',
  'choice_variable',
};

/// 已知选项解析器版本（§9 REV2：只有 v2；见文件头注释）。
const Set<int> kKnownOptionParserVersions = {optionContentsParserVersion};

/// C 路线可印性判定结果（纯数据）。
class CPrintability {
  const CPrintability({
    required this.printable,
    this.skipReason,
    this.optionsState = OptionsState.notRequired,
    this.suspiciousFlags = const [],
  });

  /// 是否可印。
  final bool printable;

  /// 不可印原因（printable 为 false 时非空，如“无 OCR 结果” /
  /// “题干缺失” / “选项无法派生”）。
  final String? skipReason;

  /// 选项状态（判定过程的中间结论，供快照组装与报告用）。
  final OptionsState optionsState;

  /// 可疑标记（来源见各标记含义；不呈现为置信度数字，§9）。
  final List<String> suspiciousFlags;
}

/// 选项状态（§5/§9）。
enum OptionsState {
  /// 本题型不要求选项（判断 / 填空 / 简答 / 论述及其他非选择题型）。
  notRequired,

  /// 已存选项可用（≥ 2 个标签槽有非空文字，标签连续）。
  available,

  /// 选项 inline 在题干里（NULL 情形 (a)），按题干文本印，不另附选项块。
  inlineInStem,

  /// 选项切分不确定但已印（NULL 情形 (d)：内容为空、标签重复或顺序
  /// 异常），标可疑 `optionSplitUncertain`，走纠错入口。
  uncertain,

  /// 选项无法派生（NULL 情形 (b)/(c)）：不可印。
  unavailable,
}

/// C 路线可印性判定（§5，纯函数，不读文件）。
///
/// 顺序：(1) ocr_raw 非空且能解析出 md_results → (2) ocr_stem 非空
/// → (3) 按题型需要选项时选项可用 → (4) 公式解析失败不直接判不可印
/// （快照构建/栅格化时走降级链，§8）。
CPrintability assessCPrintability(ExportQuestionRecord record) {
  final suspicious = <String>[];
  // (1) ocr_raw 非空且能解析出 md_results。
  final raw = GlmOcrRawData.tryParse(record.ocrRaw);
  final mdResults = raw?.mdResults;
  if (mdResults == null || mdResults.trim().isEmpty) {
    return const CPrintability(
      printable: false,
      skipReason: '无 OCR 结果',
    );
  }
  // (2) ocr_stem 非空（去空白后）。
  final stem = record.ocrStem;
  if (stem == null || stem.trim().isEmpty) {
    return const CPrintability(
      printable: false,
      skipReason: '题干缺失',
    );
  }
  // (3) 按题型需要选项时，选项可用。
  final needsOptions = _needsOptions(record.questionType, mdResults);
  if (!needsOptions) {
    return CPrintability(
      printable: true,
      optionsState: OptionsState.notRequired,
      suspiciousFlags: suspicious,
    );
  }
  final optionsJson = record.optionContentsJson;
  if (optionsJson == null) {
    // NULL 情形 (a)/(b)：题干含选项 → inline 可印；否则不可印。
    if (_stemContainsOptions(stem)) {
      return CPrintability(
        printable: true,
        optionsState: OptionsState.inlineInStem,
        suspiciousFlags: suspicious,
      );
    }
    return const CPrintability(
      printable: false,
      skipReason: '选项无法派生',
      optionsState: OptionsState.unavailable,
    );
  }
  // 非 NULL：先查版本（NULL 版本 = 未经解析器解析，如人工填写，
  // 只校验 JSON 形状；非 NULL 未知版本 → 情形 (c)，不可印）。
  final version = record.optionContentsParserVersion;
  if (version != null && !kKnownOptionParserVersions.contains(version)) {
    return CPrintability(
      printable: false,
      skipReason: '选项无法派生',
      optionsState: OptionsState.unavailable,
      suspiciousFlags: const ['unknownParserVersion'],
    );
  }
  final decoded = decodeOptionContents(optionsJson);
  if (decoded == null) {
    // 情形 (c)：JSON 损坏。
    return CPrintability(
      printable: false,
      skipReason: '选项无法派生',
      optionsState: OptionsState.unavailable,
      suspiciousFlags: const ['optionContentsCorrupt'],
    );
  }
  final nonEmpty =
      decoded.values.where((v) => v.trim().isNotEmpty).length;
  if (nonEmpty == 0) {
    // 无可用选项文字：按规则 (3) 的“至少 2 个非空槽”判不可印。
    return const CPrintability(
      printable: false,
      skipReason: '选项无法派生',
      optionsState: OptionsState.unavailable,
    );
  }
  // D-189：题干已含全部非空选项 → 视同 inlineInStem，不另附选项块
  // （与 assembleCMarkdown 同一口径，见 _stemOptionLabels）；遗留
  // 行（题干含选项 + option_contents 非空并存）标可疑
  // optionSplitUncertain，走纠错入口。只含部分标签时不断言
  // inlineInStem，assembleCMarkdown 逐标签去重、补齐其余标签。
  final stemLabels = _stemOptionLabels(stem);
  final nonEmptyLabels = decoded.entries
      .where((e) => e.value.trim().isNotEmpty)
      .map((e) => e.key)
      .toSet();
  if (stemLabels.isNotEmpty &&
      nonEmptyLabels.every(stemLabels.contains)) {
    suspicious.add('optionSplitUncertain');
    return CPrintability(
      printable: true,
      optionsState: OptionsState.inlineInStem,
      suspiciousFlags: suspicious,
    );
  }
  // 情形 (d)：标签不连续 / 个别槽为空 / 非空槽不足 2 个 → 可疑但已印。
  final labels = decoded.keys.toList()..sort();
  final expected = List<String>.generate(
    labels.length,
    (i) => String.fromCharCode('A'.codeUnitAt(0) + i),
  );
  final orderAnomaly = !_sameLabels(labels, expected);
  final hasEmptySlot = decoded.values.any((v) => v.trim().isEmpty);
  if (orderAnomaly || hasEmptySlot || nonEmpty < 2) {
    suspicious.add('optionSplitUncertain');
    return CPrintability(
      printable: true,
      optionsState: OptionsState.uncertain,
      suspiciousFlags: suspicious,
    );
  }
  return CPrintability(
    printable: true,
    optionsState: OptionsState.available,
    suspiciousFlags: suspicious,
  );
}

bool _sameLabels(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 本题是否要求选项（§5 第 3 点）。
///
/// - 选择类三型 → 要求；`true_false` 固定“正确/错误”，不要求；
//  `fill_blank` / `short_answer` / `essay` 及其他题型不要求；
// - 题型为 NULL（未确认）时，用 `splitStem(md_results)` 纯函数判定：
//   `autoSplit` → 按选择题要求选项，否则不要求。
bool _needsOptions(String? questionType, String mdResults) {
  if (questionType == null) {
    return splitStem(mdResults).status == StemSplitStatus.autoSplit;
  }
  return kChoiceQuestionTypes.contains(questionType);
}

/// 题干里已含的选项标签（D-189）：对题干文本本身跑 `splitStem`，
/// autoSplit 时返回其 optionLabels 集合；其余状态返回空集。
///
/// assessCPrintability 与 assembleCMarkdown 共用同一口径（只读冻结
/// 后的 ocrStem，不回写、不改库，D-177）：全覆盖 → inlineInStem；
/// 部分覆盖 → 逐标签去重。ambiguous / notSplit 时不去重（宁可重复
/// 也不丢选项）。
Set<String> _stemOptionLabels(String stem) {
  final result = splitStem(stem);
  if (result.status != StemSplitStatus.autoSplit) return const {};
  return result.optionLabels?.toSet() ?? const {};
}

/// 题干是否含选项（NULL 情形 (a) 的判定）：对题干文本本身跑
/// `splitStem`，能自动切分出选项序列即视为选项 inline 在题干里。
bool _stemContainsOptions(String stem) =>
    _stemOptionLabels(stem).isNotEmpty;

/// 可追溯性（§9 P2-8，per-question 记录，不存库）。
class OcrTraceability {
  const OcrTraceability({
    required this.stemSource,
    required this.optionParserVersion,
    required this.figureSources,
    required this.inlineFormulaCount,
    required this.displayFormulaCount,
    required this.suspiciousFlags,
    required this.corrected,
    required this.contentVersion,
  });

  /// 题干来源：库内已存值（原始 md 在 ocr_raw.md_results）。
  final String stemSource;

  /// 选项解析器版本（option_contents_parser_version）。
  final int? optionParserVersion;

  /// 图块来源：每图（图块 ID → 锚点方式 md/text/fallback/manual）。
  final Map<String, String> figureSources;

  /// 公式计数（行内 / 独立）。
  final int inlineFormulaCount;
  final int displayFormulaCount;

  /// 可疑标记列表及其来源（不呈现为置信度数字）。
  final List<String> suspiciousFlags;

  /// 是否被人工纠错过（Question.ocrManualEdited）。
  final bool corrected;

  /// 内容版本（快照时冻结的值）。
  final int contentVersion;
}

/// 一个图块的快照（纯数据）。
class OcrFigureSnapshot {
  const OcrFigureSnapshot({
    required this.figureId,
    required this.tempRelativePath,
    required this.anchorSource,
    required this.cropped,
    this.missingReason,
  });

  /// 图块 ID。
  final String figureId;

  /// 临时裁图相对路径（任务临时目录内；裁剪失败时为 ''）。
  final String tempRelativePath;

  /// 锚点方式（md/text/fallback/manual）。
  final String anchorSource;

  /// 是否成功裁剪到临时目录。
  final bool cropped;

  /// 裁剪失败原因（cropped 为 false 时非空，如“切片缺失，无法裁剪”）。
  final String? missingReason;
}

/// C 路线一题的冻结内容（纯数据 + 临时文件引用，不含 LaTeX 明文日志）。
class OcrContentSnapshot {
  const OcrContentSnapshot({
    required this.questionId,
    required this.blocks,
    required this.figures,
    required this.stemText,
    required this.optionContents,
    required this.optionParserVersion,
    required this.traceability,
    required this.warnings,
    required this.printable,
    this.skipReason,
    this.contentParseFallback = false,
  });

  /// 题目 ID。
  final String questionId;

  /// 冻结的块序列（题干 + 选项 + 图块；FigureBlock.cropPath 指向
  /// 任务临时目录；不可印时为空）。
  final List<QuestionContentBlock> blocks;

  /// 图块快照（每图裁剪结果）。
  final List<OcrFigureSnapshot> figures;

  /// 冻结的题干（库内已存 ocr_stem 原值）。
  final String stemText;

  /// 冻结的选项内容（标签映射；NULL = 未解析，inline 在题干里）。
  final Map<String, String>? optionContents;

  /// 冻结的选项解析器版本。
  final int? optionParserVersion;

  /// 可追溯性。
  final OcrTraceability traceability;

  /// 警告（可疑标记 + 图块缺失 + 解析异常等，供报告与纠错入口用）。
  final List<String> warnings;

  /// 是否可印（与 [assessCPrintability] 一致）。
  final bool printable;

  /// 不可印原因（printable 为 false 时非空）。
  final String? skipReason;

  /// 内容解析是否回退为纯文本（parseQuestionContent 抛错时 true；
  /// PARTIAL 降级依据之一，见 §12）。
  final bool contentParseFallback;

  /// 行内公式数（块序列统计）。
  int get inlineFormulaCount => traceability.inlineFormulaCount;

  /// 独立公式数（块序列统计）。
  int get displayFormulaCount => traceability.displayFormulaCount;

  /// 是否有图块缺失（裁剪失败 / 切片缺失导致图块未入序列）。
  bool get hasFigureMissing => figures.any((f) => !f.cropped);

  /// 选项切分是否不确定（NULL 情形 (d)，标可疑 optionSplitUncertain）。
  bool get hasOptionUncertain =>
      traceability.suspiciousFlags.contains('optionSplitUncertain');
}

/// 组装 C 路线 Markdown（纯函数）：题干 + 选项块（按标签顺序重建为
/// `A. <内容>` 行，公式原样保留；非空槽才成行；NULL inline 情形与
/// 不要求选项的题型不另附选项块）。
///
/// D-189：题干里已有的标签不重复追加（逐标签去重，与
/// assessCPrintability 同一口径 _stemOptionLabels）。
///
/// 快照组装与盘点公式计数共用同一函数（同一组装口径，不各行其是）。
String assembleCMarkdown(
  ExportQuestionRecord record,
  CPrintability printability,
) {
  final mdBuffer = StringBuffer(record.ocrStem ?? '');
  final options = record.optionContents;
  if (printability.optionsState == OptionsState.available ||
      printability.optionsState == OptionsState.uncertain) {
    // D-189：追加前逐标签去重——题干里已有的标签不重复追加（遗留行：
    // 题干含选项 + optionContents 非空并存）。检测只读冻结后的
    // ocrStem，与 assessCPrintability 同一口径（_stemOptionLabels）；
    // 全部标签都已在题干时 lines 为空，不追加任何内容。
    final stemLabels = _stemOptionLabels(record.ocrStem ?? '');
    final labels = (options ?? {}).keys.toList()..sort();
    final lines = <String>[];
    for (final label in labels) {
      if (stemLabels.contains(label)) continue;
      final content = options![label] ?? '';
      if (content.trim().isEmpty) continue;
      lines.add('$label. $content');
    }
    if (lines.isNotEmpty) {
      mdBuffer.write('\n\n');
      mdBuffer.write(lines.join('\n'));
    }
  }
  return mdBuffer.toString();
}
String _safeFileSegment(String value) {
  final cleaned =
      value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_').trim();
  return cleaned.isEmpty ? 'q' : cleaned;
}

/// 构建一题的 C 路线冻结内容。
///
/// [record] 为快照冻结的行副本；[sliceBytes] 为快照时刻的切片字节
/// （调用方在 SliceWriteGuard 锁内读出；null = 切片缺失，图块无法
/// 裁剪，但正文仍可印）；[sliceHash] 为切片 SHA-256（图块“当前性”
/// 比对用，与详情页同一口径）；[figureTempDir] 为图块临时目录
/// （须已存在；裁图写盘失败 → 抛 [SnapshotInfrastructureException]，
/// 整单中止）。
///
/// 图块生成期间切片被重框时，按快照时刻的切片裁剪（传入的
/// [sliceBytes] 即快照时刻的字节），不得静默用新图裁（§6）。
Future<OcrContentSnapshot> buildOcrContentSnapshot({
  required ExportQuestionRecord record,
  required Uint8List? sliceBytes,
  required String? sliceHash,
  required Directory figureTempDir,
}) async {
  final printability = assessCPrintability(record);
  final stemText = record.ocrStem ?? '';
  final warnings = <String>[...printability.suspiciousFlags];
  if (!printability.printable) {
    return OcrContentSnapshot(
      questionId: record.id,
      blocks: const [],
      figures: const [],
      stemText: stemText,
      optionContents: record.optionContents,
      optionParserVersion: record.optionContentsParserVersion,
      traceability: OcrTraceability(
        stemSource: '库内已存值',
        optionParserVersion: record.optionContentsParserVersion,
        figureSources: const {},
        inlineFormulaCount: 0,
        displayFormulaCount: 0,
        suspiciousFlags: List.of(warnings),
        corrected: record.ocrManualEdited,
        contentVersion: record.contentVersion,
      ),
      warnings: warnings,
      printable: false,
      skipReason: printability.skipReason,
    );
  }

  // 组装 Markdown：题干 + 选项块（见 assembleCMarkdown）。
  final assembled = assembleCMarkdown(record, printability);
  final mdResults = GlmOcrRawData.tryParse(record.ocrRaw)?.mdResults;

  // 图块：与详情页同一口径——只取与当前切片一致的图块，旧图块不展示。
  final storedFigures = parseOcrFigures(record.ocrFigures);
  final display = currentFiguresForDisplay(
    storedFigures,
    slicePath: record.slicePath,
    inputHash: sliceHash,
  );
  final staleCount = storedFigures.length - display.figures.length;
  if (staleCount > 0) {
    warnings.add('图块与当前切片不一致，已略过 $staleCount 张');
  }

  // 块序列：复用详情页图块合并逻辑 buildContentBlocks（同一套排序）。
  List<QuestionContentBlock> blocks;
  var contentParseFallback = false;
  try {
    blocks = buildContentBlocks(
      stemMarkdown: assembled,
      figures: display.figures,
      mdResults: mdResults,
    );
  } catch (_) {
    // 解析异常不得丢字：整段回退为纯文本（最小失败单元原则同 §9）。
    // 回退后块序列只剩纯文本：公式计数为 0（栅格化在 M1-C 按块序列做，
    // 回退题无公式块，不触发栅格化）。
    contentParseFallback = true;
    blocks = [TextBlock(assembled)];
    warnings.add('内容解析异常，已按纯文本处理');
  }

  // 图块裁剪：按快照时刻的切片字节裁到任务临时目录；裁出的
  // FigureBlock.cropPath 指向临时副本（不引用库内原裁图）。
  final figureById = {
    for (final f in display.figures) f.id: f,
  };
  final figureSnapshots = <OcrFigureSnapshot>[];
  var figureMissing = false;
  if (display.figures.isNotEmpty && sliceBytes == null) {
    figureMissing = true;
    warnings.add('切片缺失，${display.figures.length} 张图块无法裁剪');
    for (final f in display.figures) {
      figureSnapshots.add(
        OcrFigureSnapshot(
          figureId: f.id,
          tempRelativePath: '',
          anchorSource: f.anchorSource,
          cropped: false,
          missingReason: '切片缺失，无法裁剪',
        ),
      );
    }
  }
  final rebuiltBlocks = <QuestionContentBlock>[];
  for (final block in blocks) {
    if (block is! FigureBlock) {
      rebuiltBlocks.add(block);
      continue;
    }
    final figure = figureById[block.figureId];
    if (figure == null || sliceBytes == null) {
      // 详情页渲染器会为 FigureBlock 显示占位；导出不印无图可指的
      // 图块（PARTIAL 降级，见 §12），直接丢弃该块。
      figureMissing = true;
      continue;
    }
    var cropped = cropFigurePng(
      sliceBytes: sliceBytes,
      rect: figure.srcRect,
    );
    if (cropped != null) {
      // D-187：图块裁剪降采样——裁剪结果按 300 DPI 上限处理（与公式
      // 原图裁剪同款 capPngTo300Dpi），否则 guard 按显示宽计入的像素
      // 数会低估（裁剪宽超 2126 px 时低估可达约 2 倍）。显示宽 =
      // min(内容宽，裁剪宽按 300 DPI 换算的自然宽），与 guard 的
      // _figureDisplaySize 同口径；解不出尺寸按裁剪失败处理。
      final dims = readPngDimensions(cropped);
      cropped = dims == null
          ? null
          : capPngTo300Dpi(
              cropped,
              math.min(
                PdfExportGeometry.contentWidthPt,
                dims.width / 300 * 72,
              ),
            );
    }
    if (cropped == null) {
      figureMissing = true;
      warnings.add('图块裁剪失败，已略过（${figure.id}）');
      figureSnapshots.add(
        OcrFigureSnapshot(
          figureId: figure.id,
          tempRelativePath: '',
          anchorSource: figure.anchorSource,
          cropped: false,
          missingReason: '图块裁剪失败',
        ),
      );
      continue;
    }
    final fileName =
        '${_safeFileSegment(record.id)}-${_safeFileSegment(figure.id)}.png';
    final target = File(
      '${figureTempDir.path}${Platform.pathSeparator}$fileName',
    );
    try {
      await target.writeAsBytes(cropped);
    } on FileSystemException catch (e) {
      throw SnapshotInfrastructureException(
        '写入图块临时副本失败：${e.message}（${e.path ?? ''}）',
      );
    }
    figureSnapshots.add(
      OcrFigureSnapshot(
        figureId: figure.id,
        tempRelativePath: 'figures/$fileName',
        anchorSource: figure.anchorSource,
        cropped: true,
      ),
    );
    rebuiltBlocks.add(
      FigureBlock(
        figureId: block.figureId,
        cropPath: 'figures/$fileName',
        unconfirmed: block.unconfirmed,
      ),
    );
  }
  if (figureMissing) {
    warnings.add('图块缺失');
  }
  var inlineCount = 0;
  var displayCount = 0;
  for (final block in rebuiltBlocks) {
    if (block is FormulaBlock) {
      if (block.displayMode) {
        displayCount++;
      } else {
        inlineCount++;
      }
    }
  }
  return OcrContentSnapshot(
    questionId: record.id,
    blocks: rebuiltBlocks,
    figures: figureSnapshots,
    stemText: stemText,
    optionContents: record.optionContents,
    optionParserVersion: record.optionContentsParserVersion,
    traceability: OcrTraceability(
      stemSource: '库内已存值',
      optionParserVersion: record.optionContentsParserVersion,
      figureSources: {
        for (final f in display.figures) f.id: f.anchorSource,
      },
      inlineFormulaCount: inlineCount,
      displayFormulaCount: displayCount,
      suspiciousFlags: List.of(warnings),
      corrected: record.ocrManualEdited,
      contentVersion: record.contentVersion,
    ),
    warnings: warnings,
    printable: true,
    contentParseFallback: contentParseFallback,
  );
}
