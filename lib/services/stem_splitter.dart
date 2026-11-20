// WP-A #2（九项修复 REV5）：题干切分——候选提取 → 序列组装 → 三证据判定。
//
// 输入是 GLM-OCR 返回的原始 Markdown 文本（`md_results`），输出切分后
// 的题干 + 切分状态。只做一件事：用选项标记（A–E）当切分边界，把题干
// 和选项分开；选项部分丢弃（原始 OCR 文本由调用方另存，不在这里丢）。
//
// 算法定稿：`~/workspace/batch14-work/FIX-DESIGN-9-ISSUES.md`
// §2.2（步骤 1–4）+ 附录 R2（REV2）+ S3（REV3）+ T2（REV4）+ U4-1（REV5）。
// 与正文及之前附录冲突时以附录为准；本文件注释里标明的条目号即定稿条目。
//
// 统一词法优先级（S3-1，与 `parseQuestionContent`
// ——`lib/modules/ocr/question_content.dart`——共用，不得各行其是；
// 两处解析器实现同一顺序，并在代码注释中互相引用；WP-C #6 在该文件
// 里补 reciprocal 引用）：
//   1. 代码保护：fenced ``` 块与行内 ` 段 → 占位符隔离，永不参与
//      选项/公式/HTML 扫描；
//   2. 公式识别：`$$…$$`、再 `$…$`（`\$` 字面、未闭合 `$` 字面，见 R2-5）；
//   3. HTML 结构与选项候选解析（白名单，见 S7；嵌套表展平，见 S3-3）；
//   4. 普通 Markdown 文本。
//
// 占位符（U4-1/T5-1）：固定处理顺序 ① 原始文本上做代码保护；
// ② 对其余文本做 HTML 实体解码；③ 结构解析。位置映射以步骤 ① 完成
// 后的文本版本为基准；统一解析上下文（[_ParseContext]）为每个代码
// 占位符保存原始起止偏移、原始顺序序号、原始行号、是否位于选项候选
// 内容区间内；解析完成后按偏移原位恢复，不得重排；`(n)` 小问判别查
// 位置映射里的原始行号，不得用替换后文本的行号。占位符用含 NUL 字节
// 的内部标识（NUL 不可能出现在 OCR 文本里），恢复时按标识精确还原。
// 代码占位符在正常解析与异常回退中都必须原样保留，不得被 HTML 清理器
// 当作普通 HTML 二次处理。本切分器的题干取自原始文本前缀、切分点按
// 偏移映射回原始文本，因此工作文本（含占位符）永不外泄；回退路径
// （notSplit/ambiguous）直接返回原始文本。
// v1 不保护 HTML 的 `<pre>`/`<code>` 标签，按普通未知标签处理
// （剥标签、保留内部文字，见 T5-3）。
//
// 判定（三证据，全部为“与”关系，缺一不可，§2.2 步骤 3）：
//   1. 存在至少一个 A 候选，且序列至少到 B；
//   2. 结构分：序列中至少 2 个标记为强，或序列完整 A–D 且每个标记后
//      有内容；两项序列（仅 A、B）要求两个标记均为强（R2-1）；
//   3. 每个标记后都有实际内容（内容区间见 R2-2）；
//   4. 无排除规则命中。
// 满足 → `autoSplit`，切分点 = A 候选位置（文本标记为标记起点；
// 表格/div 选项为容器起点，即 `<table>`/`<div>` 的 `<` 处，
// 使题干不含半截 HTML）；不满足 → `notSplit`（不硬猜）。
//
// 已知局限（明确记录，不是 bug）：
// - T2-1：凡满足 S3-2 四个条件者一律作为小问，不再追加上下文判据；
//   普通编号列表因此被误判为小问的情形是已知局限。
// - S3-3：嵌套表格内的字母标记不参与选项判定（v1 已知局限）。
// - 行首“数字.”的续行：选项续行若恰为行首“数字.”形式（如 `2. 续行`），
//   会被当作新题边界切断序列；续行中的行中数字不受影响。
// - 标记被 HTML 标签从中截断时（如 `A<b>.</b>`）无法识别。
//
// 类型定义只在一处：[StemSplitStatus] 与 [StemSplitResult] 都在本文件，
// M3（存储）与 M5（纠错编辑器）直接 import 本文件复用。
//
// 十四批 M2 #7：GLM 单题 md 里图引用独占一行
// （`![](page=0,bbox=[...])`），它是图块锚点——锚点以 ocr_raw.md_results
// 为准，不靠题干文本。题干文本里留着它，界面会直接显示这行机器文本
// （模拟核验 FAIL-7-1）。splitStem 在返回前去掉独占一行的图引用行；
// 行内引用、普通 md 图片一律不动（D-106：宁可保留，不要误删）。
// cutIndex 仍指原始输入里的 A 标记位置，不动。
//
// 纯函数：无 UI、无网络、无数据库依赖，不读 layout bbox。GLM 的
// `layout_details` bbox 只做辅助信号，见文件末尾的说明；本版接口
// 不为它留参数——以后要接时由调用方在调 [splitStem] 之前按 bbox
// 重排/过滤文本即可，签名不用改。

/// 切分状态。`manuallyAdjusted`（人工调整）由 M5 的纠错编辑器在用户
/// 手动改过题干后写入，本切分器永不产出该值。
enum StemSplitStatus {
  /// 未切分：整段保留为题干（无选项标记 / 证据不足）。
  notSplit,

  /// 自动切分：高置信度识别到 A→B 选项序列，已在 A 处切开。
  autoSplit,

  /// 存在歧义：发现多个候选切分点，未自动选择，整段保留待人工确认。
  ambiguous,

  /// 人工调整：用户在纠错编辑器里手动改过题干（M5 写，本切分器不产出）。
  manuallyAdjusted,
}

/// [StemSplitStatus] 的中文显示名。
extension StemSplitStatusLabel on StemSplitStatus {
  String get label => switch (this) {
        StemSplitStatus.notSplit => '未切分',
        StemSplitStatus.autoSplit => '自动切分',
        StemSplitStatus.ambiguous => '存在歧义',
        StemSplitStatus.manuallyAdjusted => '人工调整',
      };
}

/// 题干切分结果。
class StemSplitResult {
  const StemSplitResult({
    required this.stemText,
    required this.status,
    required this.cutIndex,
    required this.reason,
    this.optionLabels,
  });

  /// 切分后的题干。自动切分时是 A 标记之前的文本（去首尾空白，题号保留）；
  /// 未切分 / 存在歧义时是整段原文（去首尾空白），内容一句不丢。
  /// 独占一行的 md 图引用行已去掉（十四批 M2 #7；锚点在 ocr_raw 的
  /// md_results 里，不靠题干文本）；其余内容原样保留。
  final String stemText;

  /// 切分状态，见 [StemSplitStatus]。
  final StemSplitStatus status;

  /// 切分位置：原始 OCR 文本中的字符下标，指向 A 标记的首字符
  /// （表格/div 选项指向容器起点 `<table>`/`<div>` 的 `<` 处）。
  /// 未切分 / 存在歧义时为 null。
  final int? cutIndex;

  /// 简短说明：切了说明切的证据（序列 + 格式），没切说明哪条规则没守住。
  final String reason;

  /// 检测到的选项字母序列（WP-A #1 收尾，只加字段、不改判定逻辑）：
  /// autoSplit 时为步骤 2 组装出的序列（如 [A, B, C, D]）；notSplit /
  /// ambiguous / 无序列时为 null。调用方只把它作
  /// [AnswerOptionEditor] 的初始值（optionLabels == null 时），
  /// 永不覆盖库里已存值。
  final List<String>? optionLabels;
}

/// 选项标记的格式类。同一序列里格式归一化，混用不扣分（§2.2 步骤 2）。
enum _MarkerFormat {
  /// `A.` / `A．`（句点）。
  dot,

  /// `A、`（顿号）。
  dun,

  /// `A)` / `A）`（右括号）。
  parenClose,

  /// `(A)` / `（A）`（左右括号）。
  paren,

  /// `A:` / `A：`（冒号）。
  colon,

  /// 裸字母 `A ` 后跟内容（`A 甲`）。
  bare,
}

/// 文本中扫到的一个选项标记（§2.2 步骤 1 的候选）。
class _Marker {
  const _Marker({
    required this.letter,
    required this.format,
    required this.start,
    required this.end,
    required this.text,
  });

  /// 归一化后的字母（A–E；全角 Ａ–Ｅ 已归一化为半角）。
  final String letter;

  /// 标记格式，见 [_MarkerFormat]。
  final _MarkerFormat format;

  /// 在工作文本中的起始下标（含左括号，如 `(A)` 的 `(` 处）。
  final int start;

  /// 在工作文本中的结束下标（不含）。
  final int end;

  /// 匹配到的原文片段（如 `A.` / `(A)` / `Ａ．`）。
  final String text;
}

/// GLM md 图引用行：独占一行的 `![](page=<n>,bbox=[x1, y1, x2, y2])`。
/// 与 ocr_figures.dart 的 `_mdFigureRefs` 同款格式（只认 page=/bbox= 形，
/// 普通 md 图片如 `![](https://…)` 不认）。
final _figureRefLinePattern = RegExp(
  r'^\s*!\[.*?\]\(page=\d+,bbox=\[\d+,\s*\d+,\s*\d+,\s*\d+\]\)\s*$',
);

/// 去掉独占一行的 md 图引用行（十四批 M2 #7）。
/// 只删整行都是引用的行；行内引用不动。返回去掉后的文本（不 trim，
/// 调用方按原有口径 trim）。
String _stripFigureRefLines(String text) {
  final lines = text.split('\n');
  final kept = lines.where((line) => !_figureRefLinePattern.hasMatch(line));
  return kept.join('\n');
}

/// 选项标记正则：括号式优先（避免 `(A)` 被拆成 `A)`），再是后缀式。
/// 只认大写 A–E（含全角 Ａ–Ｅ），小写 a–e 不认（多为句中缩写）。
/// 含冒号式 `A:`/`A：`（§2.2 步骤 1 表）。
final _markerPattern = RegExp(
  r'[（(]\s*[A-EＡ-Ｅ]\s*[)）]|[A-EＡ-Ｅ][.．、)）:：]',
);

/// 裸字母标记：字母 + 单个空格 + 内容字符（`A 甲`，§2.2 步骤 1 表）。
/// 须再经边界与内容检查（见 [_scanTextCandidates]）。
final _barePattern = RegExp(r'[A-EＡ-Ｅ] (?=\S)');

/// 不算内容的首字符集（句末/分隔标点）。
const _noContentChars = '.,;:!?，。；：、）)）';

/// 选项扫描排除区间（原始文本坐标）：fenced/行内代码块 + 公式区间。
/// 与 [splitStem] 同一词法优先级（S3-1）：代码保护 → 公式识别 →
/// HTML/选项扫描。`question_classifier.dart` 的带圈选项判定共用本函数；
/// `parseQuestionContent`（`lib/modules/ocr/question_content.dart`，#6）
/// 也须按同一顺序处理（见该文件的注释）。
List<({int start, int end})> optionScanExcludedRanges(String text) {
  final ctx = _ParseContext.protect(text);
  final formulas = _scanFormulas(ctx.protectedText);
  final out = <({int start, int end})>[
    for (final p in ctx.placeholders)
      (start: p.origStart, end: p.origEnd),
    for (final f in formulas)
      (start: ctx.protToOrig(f.start), end: ctx.protToOrig(f.end)),
  ];
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// 切分原始 OCR 文本，返回题干 + 切分状态。纯函数，不抛异常。
StemSplitResult splitStem(String ocrText) {
  final text = ocrText;
  if (text.trim().isEmpty) {
    return const StemSplitResult(
      stemText: '',
      status: StemSplitStatus.notSplit,
      cutIndex: null,
      reason: '识别文本为空',
    );
  }

  // 统一词法优先级（S3-1/U4-1）：① 代码保护 → ② 实体解码 → ③ 结构解析。
  final ctx = _ParseContext.protect(text);
  final working = ctx.workingText;
  final formulas = _scanFormulas(ctx.protectedText);
  final tree = _parseHtml(working);
  final tableSpans = _topLevelTables(tree)
      .map((t) => (start: t.start, end: t.end))
      .toList();

  // 步骤 1：候选标记提取（表格 / div 块 / 文本三路）。
  final candidates = <_Candidate>[];
  candidates.addAll(_tableCandidates(working, tree));
  final blockCandidates = _blockCandidates(working, tree, tableSpans);
  candidates.addAll(blockCandidates);
  candidates.addAll(
    _scanTextCandidates(
      ctx,
      formulas,
      tableSpans,
      blockCandidates.map((c) => c.orderKey).toSet(),
    ),
  );
  candidates.sort((a, b) => a.orderKey.compareTo(b.orderKey));

  if (!candidates.any((c) => c.letter == 'A')) {
    return StemSplitResult(
      stemText: _stripFigureRefLines(text).trim(),
      status: StemSplitStatus.notSplit,
      cutIndex: null,
      reason: '未发现选项标记，整段保留为题干',
    );
  }

  // 步骤 2 前置：逻辑块（第一遍：自然段 + 题号边界，不含小问边界）
  // 与内容区间；小问边界（S3-2）据此判定后重算逻辑块（第二遍）。
  // 行首 (n) 标记行是内容区间的终点（R2-2 的“逻辑块结束”）：续行
  // 属于当前选项，但新结构行不属于；(b) 排除的只是行中 (n) 标记。
  final structuralNLines = _structuralNLineStarts(ctx, formulas, tableSpans);
  var blocks = _LineBlocks(working, const {});
  var allSpans = _assignBlockIds(candidates, blocks, tableSpans, blockCandidates);
  _computeContentIntervals(candidates, allSpans, ctx, structuralNLines);
  final subBoundaries = _detectSubQuestionBoundaries(ctx, candidates, formulas, blocks);
  if (subBoundaries.isNotEmpty) {
    blocks = _LineBlocks(working, subBoundaries);
    allSpans = _assignBlockIds(candidates, blocks, tableSpans, blockCandidates);
    _computeContentIntervals(candidates, allSpans, ctx, structuralNLines);
  }
  // T5-1：占位符是否位于选项候选内容区间内（记入统一解析上下文）。
  for (final p in ctx.placeholders) {
    p.inOptionContent = candidates.any(
      (c) => p.workStart >= c.contentStart && p.workStart < c.contentEnd,
    );
  }

  // 步骤 2 + 3：逐个验证 A 候选，组装序列并判定。
  final validSeqs = <List<_Candidate>>[];
  String? firstFailure;
  for (final a in candidates.where((c) => c.letter == 'A')) {
    final outcome = _validateSequence(candidates, a, working);
    if (outcome.$1 != null) {
      validSeqs.add(outcome.$1!);
    } else {
      firstFailure ??= outcome.$2;
    }
  }

  if (validSeqs.length > 1) {
    return StemSplitResult(
      stemText: _stripFigureRefLines(text).trim(),
      status: StemSplitStatus.ambiguous,
      cutIndex: null,
      reason: '发现 ${validSeqs.length} 个候选切分点，不自动选择',
    );
  }
  if (validSeqs.isEmpty) {
    return StemSplitResult(
      stemText: _stripFigureRefLines(text).trim(),
      status: StemSplitStatus.notSplit,
      cutIndex: null,
      reason: firstFailure ?? '未发现可信的选项序列，不切分',
    );
  }

  final seq = validSeqs.single;
  final a = seq.first;
  final cutOrig = ctx.workingToOrig(a.start);
  return StemSplitResult(
    stemText: _stripFigureRefLines(text.substring(0, cutOrig)).trim(),
    status: StemSplitStatus.autoSplit,
    cutIndex: cutOrig,
    reason: '选项序列 ${seq.map((c) => c.letter).join(' ')}'
        '（${a.kind.label}），自 A 处切分',
    optionLabels: seq.map((c) => c.letter).toList(),
  );
}

// ---------------------------------------------------------------------------
// 统一解析上下文（U4-1/T5-1）：代码保护 + 实体解码 + 位置映射
// ---------------------------------------------------------------------------

/// 一个代码占位符（fenced ``` 块或行内 ` 段）。
class _CodePlaceholder {
  _CodePlaceholder({
    required this.sequence,
    required this.origStart,
    required this.origEnd,
    required this.protStart,
    required this.protEnd,
    required this.origLine,
  });

  /// 原始顺序序号。
  final int sequence;

  /// 原始文本内的起止偏移（保护前文本内）。
  final int origStart;
  final int origEnd;

  /// 步骤 ① 完成后文本内的起止偏移。
  final int protStart;
  final int protEnd;

  /// 原始行号（1 起）。
  final int origLine;

  /// 步骤 ② 完成后工作文本内的起止偏移（实体解码可能改变偏移，
  /// 按占位符标识精确定位）。
  int workStart = -1;
  int workEnd = -1;

  /// 是否位于选项候选内容区间内（候选提取后填入）。
  bool inOptionContent = false;
}

/// 统一解析上下文：原始文本、步骤 ① 后的文本、步骤 ② 后的工作文本，
/// 以及三者之间的位置映射。位置映射以步骤 ① 完成后的文本版本为基准。
class _ParseContext {
  _ParseContext._({
    required this.original,
    required this.protectedText,
    required this.placeholders,
    required this.workingText,
    required this.workingToProtected,
  });

  final String original;

  /// 步骤 ① 完成后的文本（代码块已替换为占位符）。
  final String protectedText;

  final List<_CodePlaceholder> placeholders;

  /// 步骤 ② 完成后的工作文本（其余文本已做 HTML 实体解码）。
  final String workingText;

  /// 工作文本每字符 → 步骤 ① 文本偏移（实体解码的位置映射）。
  final List<int> workingToProtected;

  /// 构造：① 代码保护；② 对其余文本做 HTML 实体解码。
  factory _ParseContext.protect(String original) {
    final rebuilt = _rebuildProtection(original);
    final protectedText = rebuilt.$1;
    final placeholders = rebuilt.$2;
    final decoded = _decodeEntities(protectedText, placeholders);
    final workingText = decoded.$1;
    // 占位符在工作文本中的位置：按含 NUL 的标识精确定位。
    for (final p in placeholders) {
      final id = '\x00MUSE_PH_${p.sequence}\x00';
      final at = workingText.indexOf(id);
      p.workStart = at;
      p.workEnd = at < 0 ? at : at + id.length;
    }
    return _ParseContext._(
      original: original,
      protectedText: protectedText,
      placeholders: placeholders,
      workingText: workingText,
      workingToProtected: decoded.$2,
    );
  }

  /// 步骤 ① 完成后的偏移 → 原始文本偏移。
  int protToOrig(int p) {
    var delta = 0;
    for (final ph in placeholders) {
      if (p < ph.protStart) break;
      if (p < ph.protEnd) return ph.origStart;
      delta += (ph.origEnd - ph.origStart) - (ph.protEnd - ph.protStart);
    }
    return p + delta;
  }

  /// 工作文本偏移 → 原始文本偏移。
  int workingToOrig(int w) {
    final p = w < workingToProtected.length
        ? workingToProtected[w]
        : protectedText.length;
    return protToOrig(p);
  }

  /// 工作文本偏移对应的原始行号（1 起；`(n)` 小问判别查此号，T5-1）。
  int origLineOfWorking(int w) {
    final o = workingToOrig(w);
    return '\n'.allMatches(original.substring(0, o)).length + 1;
  }
}

/// 一次扫描重建代码保护：按原始文本顺序找出 fenced 块与行内段，
/// 逐个替换为占位符，并填好全部偏移与原始行号。
/// 占位符用含 NUL 字节的内部标识（NUL 不可能出现在 OCR 文本里）。
/// 返回（保护后文本，修正后的占位符列表）。
(String, List<_CodePlaceholder>) _rebuildProtection(String original) {
  final spans = <({int start, int end})>[];
  final fenced = RegExp(r'```.*?```', dotAll: true);
  for (final m in fenced.allMatches(original)) {
    spans.add((start: m.start, end: m.end));
  }
  // 行内段：跳过与 fenced 块重叠的反引号（任一方向的重叠都跳过；
  // 只判起点会漏掉“行内段起点在块外、终点落在块内”的情形，重建时
  // substring(cursor, s.start) 会因 start < cursor 抛 RangeError）。
  // 未闭合的反引号按字面处理。
  final inline = RegExp(r'`[^`\n]+`');
  for (final m in inline.allMatches(original)) {
    if (spans.any((s) => m.start < s.end && m.end > s.start)) continue;
    spans.add((start: m.start, end: m.end));
  }
  spans.sort((a, b) => a.start.compareTo(b.start));
  final out = StringBuffer();
  final placeholders = <_CodePlaceholder>[];
  var cursor = 0;
  var seq = 0;
  for (final s in spans) {
    out.write(original.substring(cursor, s.start));
    final protStart = out.length;
    final ph = '\x00MUSE_PH_$seq\x00';
    out.write(ph);
    placeholders.add(
      _CodePlaceholder(
        sequence: seq,
        origStart: s.start,
        origEnd: s.end,
        protStart: protStart,
        protEnd: protStart + ph.length,
        origLine:
            '\n'.allMatches(original.substring(0, s.start)).length + 1,
      ),
    );
    seq++;
    cursor = s.end;
  }
  out.write(original.substring(cursor));
  return (out.toString(), placeholders);
}

/// HTML 实体解码（T7-3）：`&amp;` `&lt;` `&gt;` `&quot;` `&#39;`
/// `&apos;` `&nbsp;`（转为空格）及数字字符引用（`&#NN;` / `&#xHH;`）。
/// 数字引用只接受合法 Unicode 标量值；代理区码点与越界值统一替换为
/// U+FFFD。返回（解码后文本，每字符对应的步骤 ① 文本偏移）。
/// 占位符 span 内的文本永不解码（占位符本身不含 `&`，此处再加一道 guard）。
(String, List<int>) _decodeEntities(
  String text,
  List<_CodePlaceholder> placeholders,
) {
  final out = StringBuffer();
  final src = <int>[];
  final pattern = RegExp(
    r'&(#x[0-9A-Fa-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);',
  );
  var i = 0;
  bool insidePlaceholder(int offset) => placeholders.any(
    (p) => offset >= p.protStart && offset < p.protEnd,
  );
  while (i < text.length) {
    if (!insidePlaceholder(i)) {
      final m = pattern.matchAsPrefix(text, i);
      if (m != null) {
        final decoded = _decodeEntity(m.group(1)!);
        if (decoded != null) {
          out.write(decoded);
          src.add(i);
          i = m.end;
          continue;
        }
      }
    }
    out.write(text[i]);
    src.add(i);
    i++;
  }
  return (out.toString(), src);
}

String? _decodeEntity(String body) {
  switch (body) {
    case 'amp':
      return '&';
    case 'lt':
      return '<';
    case 'gt':
      return '>';
    case 'quot':
      return '"';
    case 'apos':
      return "'";
    case 'nbsp':
      return ' ';
  }
  if (body.startsWith('#x') || body.startsWith('#X')) {
    final v = int.tryParse(body.substring(2), radix: 16);
    if (v == null) return null;
    return _scalarOrReplacement(v);
  }
  if (body.startsWith('#')) {
    final v = int.tryParse(body.substring(1));
    if (v == null) return null;
    return _scalarOrReplacement(v);
  }
  return null;
}

/// 合法 Unicode 标量值 → 该字符；代理区/越界 → U+FFFD（T7-3）。
String _scalarOrReplacement(int v) {
  if (v < 0 || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF)) {
    return '�';
  }
  return String.fromCharCode(v);
}

// ---------------------------------------------------------------------------
// 公式扫描（S3-1 步骤 2；R2-5）
// ---------------------------------------------------------------------------

/// 先扫描 `$…$` / `$$…$$` 公式区间，区间内标记作废；
/// `\$` 是字面美元符；未闭合的 `$` 按字面文本处理，其后标记仍可参与判定；
/// 公式紧闭后立即出现的标记可参与判定。
List<({int start, int end})> _scanFormulas(String text) {
  final ranges = <({int start, int end})>[];
  var i = 0;
  while (i < text.length) {
    if (text.codeUnitAt(i) != 0x24) {
      i++;
      continue;
    }
    if (i > 0 && text.codeUnitAt(i - 1) == 0x5C) {
      i++;
      continue; // `\$` 字面
    }
    if (i + 1 < text.length && text.codeUnitAt(i + 1) == 0x24) {
      final close = text.indexOf('\$\$', i + 2);
      if (close < 0) {
        i += 2;
        continue;
      }
      if (text.substring(i + 2, close).trim().isEmpty) {
        i += 2;
        continue;
      }
      ranges.add((start: i, end: close + 2));
      i = close + 2;
      continue;
    }
    var j = i + 1;
    var close = -1;
    while (j < text.length) {
      final c = text.codeUnitAt(j);
      if (c == 0x0A) break; // `$…$` 不跨行
      if (c == 0x24 && text.codeUnitAt(j - 1) != 0x5C) {
        close = j;
        break;
      }
      j++;
    }
    if (close < 0) {
      i++;
      continue; // 未闭合的 `$` 按字面处理
    }
    if (text.substring(i + 1, close).trim().isEmpty) {
      i++;
      continue;
    }
    ranges.add((start: i, end: close + 1));
    i = close + 1;
  }
  return ranges;
}

// ---------------------------------------------------------------------------
// 极简 HTML 解析器（手写有限解析器，不新增依赖；白名单见 S7）
// ---------------------------------------------------------------------------

/// HTML 节点：`tag == ''` 为文本节点。
class _HtmlNode {
  _HtmlNode.element({
    required this.tag,
    required this.attrs,
    required this.start,
  }) : text = null,
       children = <_HtmlNode>[];

  _HtmlNode.text({required this.text, required this.start})
    : tag = '',
      attrs = const {},
      children = const [];

  final String tag;
  final String? text;
  final Map<String, String> attrs;
  final List<_HtmlNode> children;
  final int start;
  int end = 0;

  bool get isText => tag.isEmpty;
}

const _voidTags = {
  'br',
  'hr',
  'img',
  'input',
  'meta',
  'link',
  'col',
  'base',
  'area',
  'wbr',
  'source',
  'track',
  'embed',
};

final _attrPattern = RegExp(
  '''([A-Za-z_:][A-Za-z0-9_.:-]*)\\s*=\\s*("[^"]*"|'[^']*'|[^\\s"'=<>`]+)''',
);

/// 容错解析：未闭合标签在文末自动闭合；不匹配的闭合标签忽略；
/// 注释与 `<!…>` 跳过。`<pre>`/`<code>` 按普通未知标签处理
/// （剥标签、保留内部文字，T5-3）。
_HtmlNode _parseHtml(String text) {
  final root = _HtmlNode.element(tag: '__root__', attrs: {}, start: 0);
  root.end = text.length;
  final stack = <_HtmlNode>[root];
  final tagPattern = RegExp(
    r'<!--.*?-->|<!\[CDATA\[.*?\]\]>|<[^>]*>',
    dotAll: true,
  );
  var cursor = 0;
  for (final m in tagPattern.allMatches(text)) {
    if (m.start > cursor) {
      stack.last.children.add(
        _HtmlNode.text(text: text.substring(cursor, m.start), start: cursor),
      );
    }
    final raw = m.group(0)!;
    if (raw.startsWith('<!--') || raw.startsWith('<!')) {
      cursor = m.end;
      continue;
    }
    final inner = raw.substring(1, raw.length - 1).trim();
    if (inner.startsWith('/')) {
      final name = inner
          .substring(1)
          .trim()
          .split(RegExp(r'\s'))
          .first
          .toLowerCase();
      var idx = -1;
      for (var k = stack.length - 1; k >= 1; k--) {
        if (stack[k].tag == name) {
          idx = k;
          break;
        }
      }
      if (idx >= 0) {
        while (stack.length > idx) {
          stack.removeLast().end = m.end;
        }
      }
      cursor = m.end;
      continue;
    }
    final selfClosing = inner.endsWith('/');
    final body = selfClosing
        ? inner.substring(0, inner.length - 1).trim()
        : inner;
    final nameEnd = body.indexOf(RegExp(r'\s'));
    final name = (nameEnd < 0 ? body : body.substring(0, nameEnd))
        .toLowerCase();
    if (name.isEmpty || !RegExp(r'^[a-z][a-z0-9]*$').hasMatch(name)) {
      cursor = m.end;
      continue;
    }
    final attrs = <String, String>{};
    for (final a in _attrPattern.allMatches(body)) {
      var value = a.group(2)!;
      if ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))) {
        value = value.substring(1, value.length - 1);
      }
      attrs[a.group(1)!.toLowerCase()] = value;
    }
    final node = _HtmlNode.element(tag: name, attrs: attrs, start: m.start);
    stack.last.children.add(node);
    if (!selfClosing && !_voidTags.contains(name)) {
      stack.add(node);
    } else {
      node.end = m.end;
    }
    cursor = m.end;
  }
  if (cursor < text.length) {
    stack.last.children.add(
      _HtmlNode.text(text: text.substring(cursor), start: cursor),
    );
  }
  for (final n in stack) {
    n.end = text.length;
  }
  return root;
}

void _walkElements(_HtmlNode node, void Function(_HtmlNode) visit) {
  if (!node.isText) visit(node);
  for (final c in node.children) {
    _walkElements(c, visit);
  }
}

/// 展平为纯文本：剥标签、保留文字，不丢字。
/// `<br>` → 换行；嵌套 `<table>` 一律展平（T5-4：同一行内单元格之间
/// 用一个空格分隔，行之间用一个换行分隔；展平优先于 children 模型，T5-5）。
String _flattenText(_HtmlNode node) {
  if (node.isText) return node.text!;
  if (node.tag == 'br') return '\n';
  if (node.tag == 'table') {
    final rows = _tableRows(node);
    return rows
        .map((r) => _rowCells(r).map(_flattenText).join(' '))
        .join('\n');
  }
  final buf = StringBuffer();
  for (final c in node.children) {
    buf.write(_flattenText(c));
  }
  return buf.toString();
}

/// 某表格的行：最近的 table 祖先是本表自身的 `<tr>`（thead/tbody 亦可）。
List<_HtmlNode> _tableRows(_HtmlNode table) {
  final rows = <_HtmlNode>[];
  void walk(_HtmlNode node, _HtmlNode? nearestTable) {
    if (node.tag == 'table') {
      if (nearestTable != null && node != table) return;
      nearestTable = node;
    }
    if (node.tag == 'tr' && nearestTable == table) rows.add(node);
    for (final c in node.children) {
      if (!c.isText) walk(c, nearestTable);
    }
  }

  walk(table, null);
  return rows;
}

/// 某行的单元格：直接 td/th 子节点；无则取最近 tr 祖先是本行的后代 td/th。
List<_HtmlNode> _rowCells(_HtmlNode tr) {
  final direct = tr.children
      .where((c) => c.tag == 'td' || c.tag == 'th')
      .toList();
  if (direct.isNotEmpty) return direct;
  final out = <_HtmlNode>[];
  void walk(_HtmlNode node, _HtmlNode? nearestTr) {
    if (node.tag == 'tr') nearestTr = node;
    if ((node.tag == 'td' || node.tag == 'th') && nearestTr == tr) {
      out.add(node);
    }
    for (final c in node.children) {
      if (!c.isText) walk(c, nearestTr);
    }
  }

  walk(tr, null);
  return out;
}

/// 顶层表格（不嵌套在另一张表内的表；S3-3：嵌套表不解析为独立表格）。
List<_HtmlNode> _topLevelTables(_HtmlNode root) {
  final out = <_HtmlNode>[];
  void walk(_HtmlNode node, bool insideTable) {
    if (node.tag == 'table') {
      if (!insideTable) out.add(node);
      insideTable = true;
    }
    for (final c in node.children) {
      if (!c.isText) walk(c, insideTable);
    }
  }

  walk(root, false);
  return out;
}

// ---------------------------------------------------------------------------
// 候选提取（§2.2 步骤 1）
// ---------------------------------------------------------------------------

/// 候选来源。
enum _CandidateKind {
  text('文本'),
  table('表格'),
  block('块级元素');

  const _CandidateKind(this.label);
  final String label;
}

/// 一个选项候选。
class _Candidate {
  _Candidate({
    required this.letter,
    required this.format,
    required this.strong,
    required this.start,
    required this.orderKey,
    required this.markerEnd,
    required this.kind,
    required this.contentStart,
    required this.contentEnd,
    required this.hasContent,
    this.runId = -1,
  });

  final String letter;

  /// 标记格式（见 [_MarkerFormat]；Win11 包 4：跨段组装的格式门用它——
  /// 裸字母（`bare`）是题干引用还是选项分不清，不得借空行拼成选项）。
  final _MarkerFormat format;

  /// 结构强度：强（2 分）/ 弱（0 分）。
  final bool strong;

  /// 切分点（工作文本偏移；文本标记为标记起点，表格/div 为容器起点）。
  final int start;

  /// 排序键（工作文本偏移；字母标记本身的位置）。
  final int orderKey;

  /// 标记结束偏移（不含）。
  final int markerEnd;

  final _CandidateKind kind;

  /// 内容区间 [contentStart, contentEnd)（R2-2）。
  int contentStart;
  int contentEnd;

  /// 标记后是否有实际内容。
  bool hasContent;

  /// 所属 div run 编号（仅块级候选有效；同一 run 共享一个逻辑块）。
  int runId;

  /// 所属逻辑块 id（候选提取后填入）。
  int blockId = -1;
}

/// 归一化字母（全角 Ａ–Ｅ → 半角 A–E）。
String _normalizeLetter(String raw) {
  final c = raw.codeUnitAt(0);
  if (c >= 0xFF21 && c <= 0xFF25) {
    return String.fromCharCode(c - 0xFF21 + 0x41);
  }
  return raw;
}

/// 由原始片段构造标记（[start] 为工作文本偏移，[raw] 为匹配到的原文片段）。
_Marker _markerFromRaw(int start, int end, String raw) {
  final letterCode = raw.codeUnits.firstWhere(
    (c) => (c >= 0x41 && c <= 0x45) || (c >= 0xFF21 && c <= 0xFF25),
  );
  final letter = _normalizeLetter(String.fromCharCode(letterCode));
  final _MarkerFormat format;
  if (raw.startsWith('(') || raw.startsWith('（')) {
    format = _MarkerFormat.paren;
  } else if (raw.endsWith('.') || raw.endsWith('．')) {
    format = _MarkerFormat.dot;
  } else if (raw.endsWith('、')) {
    format = _MarkerFormat.dun;
  } else if (raw.endsWith(':') || raw.endsWith('：')) {
    format = _MarkerFormat.colon;
  } else {
    format = _MarkerFormat.parenClose;
  }
  return _Marker(
    letter: letter,
    format: format,
    start: start,
    end: end,
    text: raw,
  );
}

/// 文本是否在任一区间内。
bool _insideAny(int offset, List<({int start, int end})> ranges) =>
    ranges.any((r) => offset >= r.start && offset < r.end);

/// 空白字符：空格、制表符、换行、回车、全角空格。
bool _isSpace(int c) {
  return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x3000;
}

/// 行内空白（不含换行）：空格、制表符、回车、全角空格。
bool _isBlank(int c) {
  return c == 0x20 || c == 0x09 || c == 0x0D || c == 0x3000;
}

/// 拉丁字母或数字（半角 + 全角），用于排除规则“字母前后紧贴其他拉丁字母或数字”。
bool _isLatinOrDigit(int c) {
  return (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      (c >= 0xFF10 && c <= 0xFF19) ||
      (c >= 0xFF21 && c <= 0xFF3A) ||
      (c >= 0xFF41 && c <= 0xFF5A);
}

/// 是否行首：从行首到 [start] 之间只有空白。
bool _isLineStart(String text, int start) {
  var i = start - 1;
  while (i >= 0) {
    final c = text.codeUnitAt(i);
    if (c == 0x0A) return true;
    if (!_isBlank(c)) return false;
    i--;
  }
  return true;
}

/// 候选所在行是否为 `## ` 标题行（排除规则）。
bool _isHeadingLine(String text, int offset) {
  var ls = offset - 1;
  while (ls >= 0 && text.codeUnitAt(ls) != 0x0A) {
    ls--;
  }
  var i = ls + 1;
  var hashes = 0;
  while (i < text.length && text.codeUnitAt(i) == 0x23) {
    hashes++;
    i++;
  }
  if (hashes == 0 || hashes > 6) return false;
  return i < text.length && _isSpace(text.codeUnitAt(i));
}

/// 结构强度（§2.2 步骤 1 表）：行首强；行内 ≥2 空格/制表符强；
/// 行内 1 空格的括号式强；行内 1 空格的后缀式弱；其余弱。
bool _isStrongMarker(String text, _Marker marker) {
  if (_isLineStart(text, marker.start)) return true;
  var i = marker.start - 1;
  var run = 0;
  var hasTab = false;
  while (i >= 0 && _isBlank(text.codeUnitAt(i))) {
    if (text.codeUnitAt(i) == 0x09) hasTab = true;
    run++;
    i--;
  }
  if (run >= 2 || hasTab) return true;
  if (marker.format == _MarkerFormat.paren &&
      marker.start > 0 &&
      _isSpace(text.codeUnitAt(marker.start - 1))) {
    return true;
  }
  return false;
}

/// 排除规则（任一命中即该候选作废）：公式内；字母前后紧贴其他拉丁字母
/// 或数字；位于 `## ` 标题行内。
bool _isExcluded(
  String text,
  _Marker marker,
  List<({int start, int end})> formulas,
) {
  if (_insideAny(marker.start, formulas)) return true;
  if (_isHeadingLine(text, marker.start)) return true;
  final letterPos = marker.text.codeUnits.toList().indexWhere(
    (c) => (c >= 0x41 && c <= 0x45) || (c >= 0xFF21 && c <= 0xFF25),
  );
  final lp = marker.start + letterPos;
  if (lp > 0 && _isLatinOrDigit(text.codeUnitAt(lp - 1))) return true;
  if (lp + 1 < text.length && _isLatinOrDigit(text.codeUnitAt(lp + 1))) {
    return true;
  }
  return false;
}

/// 标签区间：`<…>` 在 [from, to) 内的全部 span。
List<({int start, int end})> _tagSpans(String text, int from, int to) {
  final out = <({int start, int end})>[];
  for (final m in RegExp(r'<[^>]*>').allMatches(text.substring(from, to))) {
    out.add((start: from + m.start, end: from + m.end));
  }
  return out;
}

/// 在 [from, to) 内找第一个选项标记（跳过 `<…>` 标签内部的匹配）。
/// 返回 null 表示无。用于 div/table 单元格的标记定位。
_Marker? _firstMarkerInSpan(String text, int from, int to) {
  if (from >= to) return null;
  final tags = _tagSpans(text, from, to);
  for (final m in _markerPattern.allMatches(text.substring(from, to))) {
    final start = from + m.start;
    if (_insideAny(start, tags)) continue;
    return _markerFromRaw(start, from + m.end, m.group(0)!);
  }
  for (final m in _barePattern.allMatches(text.substring(from, to))) {
    final start = from + m.start;
    if (_insideAny(start, tags)) continue;
    final contentPos = start + 2;
    if (contentPos >= to) continue;
    final c = text.codeUnitAt(contentPos);
    if (_isSpace(c) || _noContentChars.contains(String.fromCharCode(c))) {
      continue;
    }
    return _Marker(
      letter: _normalizeLetter(text[start]),
      format: _MarkerFormat.bare,
      start: start,
      end: start + 1,
      text: text[start],
    );
  }
  return null;
}

/// 单元格文本 span 内找字母偏移（跳过 `<…>` 标签内字符）。
int _findLetterOffsetInSpan(String text, int from, int to, String letter) {
  final tags = _tagSpans(text, from, to);
  for (var i = from; i < to; i++) {
    if (_insideAny(i, tags)) continue;
    final c = text.codeUnitAt(i);
    if ((c >= 0x41 && c <= 0x45) || (c >= 0xFF21 && c <= 0xFF25)) {
      if (_normalizeLetter(text[i]) == letter) return i;
    }
  }
  return -1;
}

/// 文本以标记开头时返回 true（用于 div 块与单元格的开头判定）。
/// [marker] 为同一 span 内定位到的原始标记（位置以它为准）。
bool _markerAtStart(String flatStart, _Marker marker) {
  final m = _markerPattern.matchAsPrefix(flatStart);
  if (m != null) {
    return _markerFromRaw(0, m.end, m.group(0)!).letter == marker.letter;
  }
  final b = _barePattern.matchAsPrefix(flatStart);
  if (b != null) {
    return _normalizeLetter(flatStart[0]) == marker.letter;
  }
  return false;
}

/// 一段纯文本是否有实际内容：去空白后有字，且不是下一个选项标记、
/// 也不只剩标点（沿用旧 `_hasRealContent` 口径）。
bool _textHasContent(String s) {
  var i = 0;
  while (i < s.length && _isSpace(s.codeUnitAt(i))) {
    i++;
  }
  if (i >= s.length) return false;
  if (_markerPattern.matchAsPrefix(s, i) != null) return false;
  if (_barePattern.matchAsPrefix(s, i) != null) return false;
  if (_noContentChars.contains(s[i])) return false;
  return true;
}

/// 表格选项候选（§2.3）：`<table>` 的行中，首列单元格去空白后依次为
/// A、B、C、D（严格连续）则该表即选项表；选项内容取同行第二列单元格
/// 文本；结构强度按“强”计；序列组装直接取表行，不走文本扫描。
/// R2-4：文本、单元格、div 全部支持 A–E；表格仅 A/B 两行时首列恰为
/// A、B（强）且第二列内容非空 → 构成选择题；非首列出现的字母标记
/// 一律忽略；空行与表头行跳过（不中断序列）。
List<_Candidate> _tableCandidates(String working, _HtmlNode root) {
  final out = <_Candidate>[];
  for (final table in _topLevelTables(root)) {
    for (final row in _tableRows(table)) {
      final cells = _rowCells(row);
      if (cells.isEmpty) continue;
      final first = _flattenText(cells[0]).trim();
      if (first.isEmpty) continue; // 空行跳过
      String? letter;
      String content;
      int markerPos;
      int contentStart;
      int contentEnd;
      _MarkerFormat format;
      final exact = RegExp(r'^([A-EＡ-Ｅ])$').firstMatch(first);
      if (exact != null) {
        letter = _normalizeLetter(exact.group(1)!);
        format = _MarkerFormat.bare;
        content = cells.length > 1 ? _flattenText(cells[1]).trim() : '';
        markerPos = _findLetterOffsetInSpan(
          working,
          cells[0].start,
          cells[0].end,
          letter,
        );
        if (markerPos < 0) continue;
        contentStart = cells.length > 1 ? cells[1].start : cells[0].end;
        contentEnd = cells.length > 1 ? cells[1].end : cells[0].end;
      } else {
        final marker = _firstMarkerInSpan(
          working,
          cells[0].start,
          cells[0].end,
        );
        if (marker == null) continue; // 表头行等非选项行跳过
        // 单元格须以标记开头（`A. 甲` 在同一格内）。
        final flatStart = _flattenText(cells[0]).trimLeft();
        if (!_markerAtStart(flatStart, marker)) continue;
        letter = marker.letter;
        format = marker.format;
        content = flatStart.substring(marker.text.length).trim();
        markerPos = marker.start;
        contentStart = marker.end;
        contentEnd = cells[0].end;
      }
      out.add(
        _Candidate(
          letter: letter,
          format: format,
          strong: true,
          start: table.start,
          orderKey: markerPos,
          markerEnd: markerPos + 1,
          kind: _CandidateKind.table,
          contentStart: contentStart,
          contentEnd: contentEnd,
          hasContent: _textHasContent(content),
        ),
      );
      // Win11 包 4：两列表格的第二列也是选项（`<tr><td>A. 甲</td>
      // <td>B. 乙</td></tr>`）。仅当首列不是单字母格（`| A | 内容 |`
      // 形）时扫描——单字母格的第二列是内容，不是选项。
      // 单元格须以标记开头，且标记后有实际内容。
      if (exact == null) {
        for (var i = 1; i < cells.length; i++) {
          final flat = _flattenText(cells[i]).trimLeft();
          if (flat.isEmpty) continue;
          final extra = _firstMarkerInSpan(
            working,
            cells[i].start,
            cells[i].end,
          );
          if (extra == null) continue;
          if (!_markerAtStart(flat, extra)) continue;
          final after = flat.substring(extra.text.length).trim();
          if (!_textHasContent(after)) continue;
          out.add(
            _Candidate(
              letter: extra.letter,
              format: extra.format,
              strong: true,
              start: table.start,
              orderKey: extra.start,
              markerEnd: extra.start + 1,
              kind: _CandidateKind.table,
              contentStart: extra.end,
              contentEnd: cells[i].end,
              hasContent: true,
            ),
          );
        }
      }
    }
  }
  return out;
}

/// div/p 选项块候选（§2.3）：连续的多个 `<div>`/`<p>` 块，每块去空白后
/// 以字母标记开头且块内除标记外有内容，即视为选项序列；
/// 单个 `<div>答案是 A，B，C 都有可能。</div>` 这种块内含多个字母的，
/// 不计为选项（块内字母不是块首标记）。
/// R2-3(c)：连续兄弟 div 选项块——同一父节点下连续的 div，中间夹杂
/// 一个非选项 div 即中断序列；不含字母标记的 div 不是选项块，中断序列。
/// 表格内的 div 不参与（外层单元格不向下钻取，S3-3）。
List<_Candidate> _blockCandidates(
  String working,
  _HtmlNode root,
  List<({int start, int end})> tableSpans,
) {
  // 1. 找出全部选项块元素（div/p，以标记开头且有内容，首标记不在子块内）。
  final optionBlocks = <_HtmlNode, _Marker>{};
  _walkElements(root, (el) {
    if (el.tag != 'div' && el.tag != 'p') return;
    if (_insideAny(el.start, tableSpans)) return; // 表格内不参与
    final flat = _flattenText(el).trim();
    if (flat.isEmpty) return;
    final head = _markerPattern.matchAsPrefix(flat) ??
        _barePattern.matchAsPrefix(flat);
    if (head == null) return;
    final marker = _firstMarkerInSpan(working, el.start, el.end);
    if (marker == null) return;
    if (!_markerAtStart(flat, marker)) return;
    // 首标记若在某个 div/p/table 子元素内，归属子元素，本元素不算。
    for (final c in el.children) {
      if (!c.isText &&
          (c.tag == 'div' || c.tag == 'p' || c.tag == 'table') &&
          marker.start >= c.start &&
          marker.start < c.end) {
        return;
      }
    }
    final after = flat.substring(head.group(0)!.length).trim();
    if (!_textHasContent(after)) return;
    optionBlocks[el] = marker;
  });

  // 2. 按父节点分组，找连续兄弟 run（之间只允许空白文本节点）。
  final out = <_Candidate>[];
  var runCounter = 0;
  final parents = <_HtmlNode>{};
  _walkElements(root, (el) {
    if (el.children.any((c) => optionBlocks.containsKey(c))) {
      parents.add(el);
    }
  });
  for (final parent in parents) {
    var run = <_HtmlNode>[];
    void flush() {
      if (run.isEmpty) return;
      final runId = runCounter++;
      for (final el in run) {
        final marker = optionBlocks[el]!;
        out.add(
          _Candidate(
            letter: marker.letter,
            format: marker.format,
            strong: true,
            start: el.start,
            orderKey: marker.start,
            markerEnd: marker.start + 1,
            kind: _CandidateKind.block,
            contentStart: marker.end,
            contentEnd: el.end,
            hasContent: true,
            runId: runId,
          ),
        );
      }
      run = <_HtmlNode>[];
    }

    for (final child in parent.children) {
      if (!child.isText && optionBlocks.containsKey(child)) {
        run.add(child);
      } else if (child.isText && child.text!.trim().isEmpty) {
        continue; // 空白文本不中断 run
      } else {
        flush();
      }
    }
    flush();
  }
  return out;
}

/// 文本候选扫描（§2.2 步骤 1 表）：行首/行内后缀式、括号式与裸字母；
/// 跳过公式区间、代码占位符、表格区域、`## ` 标题行与排除规则；
/// 与块级候选去重（同一标记位置只保留块级候选）。
List<_Candidate> _scanTextCandidates(
  _ParseContext ctx,
  List<({int start, int end})> formulas,
  List<({int start, int end})> tableSpans,
  Set<int> blockOrderKeys,
) {
  final text = ctx.workingText;
  final out = <_Candidate>[];
  final taken = <int>{};

  bool inCode(int offset) => ctx.placeholders.any(
    (p) => offset >= p.workStart && offset < p.workEnd,
  );

  bool excluded(_Marker marker) {
    if (blockOrderKeys.contains(marker.start)) return true;
    if (taken.contains(marker.start)) return true;
    if (_insideAny(marker.start, formulas)) return true;
    if (inCode(marker.start)) return true;
    if (_insideAny(marker.start, tableSpans)) return true;
    return _isExcluded(text, marker, formulas);
  }

  for (final m in _markerPattern.allMatches(text)) {
    final marker = _markerFromRaw(m.start, m.end, m.group(0)!);
    if (excluded(marker)) continue;
    taken.add(marker.start);
    out.add(
      _Candidate(
        letter: marker.letter,
        format: marker.format,
        strong: _isStrongMarker(text, marker),
        start: marker.start,
        orderKey: marker.start,
        markerEnd: marker.end,
        kind: _CandidateKind.text,
        contentStart: marker.end,
        contentEnd: marker.end,
        hasContent: false,
      ),
    );
  }
  for (final m in _barePattern.allMatches(text)) {
    final start = m.start;
    if (taken.contains(start) || blockOrderKeys.contains(start)) continue;
    if (_insideAny(start, formulas)) continue;
    if (inCode(start)) continue;
    if (_insideAny(start, tableSpans)) continue;
    if (_isHeadingLine(text, start)) continue;
    if (start > 0 && _isLatinOrDigit(text.codeUnitAt(start - 1))) continue;
    final contentPos = start + 2;
    if (contentPos >= text.length) continue;
    final c = text.codeUnitAt(contentPos);
    if (_isSpace(c) || _noContentChars.contains(String.fromCharCode(c))) {
      continue;
    }
    taken.add(start);
    out.add(
      _Candidate(
        letter: _normalizeLetter(text[start]),
        format: _MarkerFormat.bare,
        strong: false, // 裸字母恒为弱；完整 A–D 序列由结构分第二条放行
        start: start,
        orderKey: start,
        markerEnd: start + 1,
        kind: _CandidateKind.text,
        contentStart: start + 1,
        contentEnd: start + 1,
        hasContent: false,
      ),
    );
  }
  return out;
}

// ---------------------------------------------------------------------------
// 逻辑块（R2-3）与小问边界（S3-2/T2）
// ---------------------------------------------------------------------------

/// 按行划分的逻辑块：自然段（连续非空行）+ 题号边界 + 小问边界。
/// [boundaryLines] 为小问边界所在行号集合（第二遍才传入）。
class _LineBlocks {
  _LineBlocks(String text, Set<int> boundaryLines) {
    final starts = <int>[0];
    for (var k = 0; k < text.length; k++) {
      if (text.codeUnitAt(k) == 0x0A) starts.add(k + 1);
    }
    lineStarts = starts;
    final ends = <int>[];
    for (var j = 0; j < starts.length; j++) {
      ends.add(j + 1 < starts.length ? starts[j + 1] - 1 : text.length);
    }
    final isBlank = <bool>[];
    for (var j = 0; j < starts.length; j++) {
      isBlank.add(text.substring(starts[j], ends[j]).trim().isEmpty);
    }
    final lineBlock = List<int>.filled(starts.length, -1);
    var blockId = -1;
    var seenContent = false;
    for (var j = 0; j < starts.length; j++) {
      if (isBlank[j]) continue;
      final line = text.substring(starts[j], ends[j]);
      final isQuestionNumber = _isQuestionNumberLine(line);
      final isBoundary = boundaryLines.contains(j);
      if (!seenContent) {
        blockId = 0;
        seenContent = true;
      } else if (isQuestionNumber || isBoundary || (j > 0 && isBlank[j - 1])) {
        blockId++;
      }
      lineBlock[j] = blockId;
    }
    this.lineBlock = lineBlock;
    final spans = <int, ({int start, int end})>{};
    for (var j = 0; j < starts.length; j++) {
      final id = lineBlock[j];
      if (id < 0) continue;
      final prev = spans[id];
      spans[id] = (
        start: prev == null ? starts[j] : prev.start,
        end: ends[j],
      );
    }
    this.spans = spans;
  }

  late final List<int> lineStarts;
  late final List<int> lineBlock;
  late final Map<int, ({int start, int end})> spans;

  /// 偏移所在行的块 id（空行返回 -1）。
  int blockIdOf(int offset) {
    return lineBlock[lineOf(offset)];
  }

  /// 偏移所在行号。
  int lineOf(int offset) {
    var lo = 0;
    var hi = lineStarts.length - 1;
    var line = 0;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (lineStarts[mid] <= offset) {
        line = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return line;
  }
}

/// 行首题号：`数字.` / `数字、` / `## `（R2-3(d)；`（数字）` 形归 S3-2 管）。
bool _isQuestionNumberLine(String line) {
  final t = line.trimLeft();
  if (RegExp(r'^\d+[.、]').hasMatch(t)) return true;
  if (RegExp(r'^#{1,6}\s').hasMatch(t)) return true;
  return false;
}

/// 给候选分配逻辑块 id，并返回全部块的 span 表（含行块、表格块、div run 块）。
/// 表格候选归表，块级候选归所在 run，文本候选归行块（在某选项块元素内
/// 的文本候选归该 run）。
Map<int, ({int start, int end})> _assignBlockIds(
  List<_Candidate> candidates,
  _LineBlocks blocks,
  List<({int start, int end})> tableSpans,
  List<_Candidate> blockCandidates,
) {
  final allSpans = Map<int, ({int start, int end})>.of(blocks.spans);
  var nextId = allSpans.keys.isEmpty
      ? 0
      : allSpans.keys.reduce((a, b) => a > b ? a : b) + 1;
  final tableBlockIds = <({int start, int end}), int>{};
  for (final s in tableSpans) {
    final id = nextId++;
    tableBlockIds[s] = id;
    allSpans[id] = s;
  }
  final runIds = <int>[];
  for (final b in blockCandidates) {
    if (!runIds.contains(b.runId)) runIds.add(b.runId);
  }
  final runBlockIds = <int, int>{};
  final runSpans = <int, ({int start, int end})>{};
  for (final b in blockCandidates) {
    final prev = runSpans[b.runId];
    runSpans[b.runId] = (
      start: prev == null ? b.start : prev.start,
      end: b.contentEnd,
    );
  }
  for (final r in runIds) {
    final id = nextId++;
    runBlockIds[r] = id;
    allSpans[id] = runSpans[r]!;
  }
  for (final c in candidates) {
    if (c.kind == _CandidateKind.table) {
      final span = tableSpans.firstWhere(
        (s) => c.orderKey >= s.start && c.orderKey < s.end,
        orElse: () => tableSpans.first,
      );
      c.blockId = tableBlockIds[span]!;
    } else if (c.kind == _CandidateKind.block) {
      c.blockId = runBlockIds[c.runId]!;
    } else {
      final hosts = blockCandidates
          .where(
            (b) => c.orderKey >= b.contentStart && c.orderKey < b.contentEnd,
          )
          .toList();
      if (hosts.isNotEmpty) {
        c.blockId = runBlockIds[hosts.first.runId]!;
      } else {
        c.blockId = blocks.blockIdOf(c.orderKey);
      }
    }
  }
  return allSpans;
}

/// 内容区间（R2-2）：从当前候选标记结束处起，至下一个有效候选标记
/// 或逻辑块结束为止；续行属于当前选项。
/// 文本候选的区间与有内容判定据此算出；表格/div 候选的区间在提取时已定。
/// [structuralNLines] 为行首 (n) 标记行的起点：内容区间到此为止
/// （新结构行不属于当前选项的内容；行中 (n) 标记仍在区间内，受 S3-2(b) 排除）。
void _computeContentIntervals(
  List<_Candidate> candidates,
  Map<int, ({int start, int end})> allSpans,
  _ParseContext ctx,
  List<int> structuralNLines,
) {
  final sorted = [...candidates]..sort((a, b) => a.orderKey.compareTo(b.orderKey));
  for (var i = 0; i < sorted.length; i++) {
    final c = sorted[i];
    if (c.kind != _CandidateKind.text) continue;
    final blockEnd = allSpans[c.blockId]?.end ?? c.markerEnd;
    var end = blockEnd;
    // 内容边界取块内下一个真正的选项标记：文本裸字母是题干噪声
    // （`A∩B` 里的 B 是句中文字），不是选项边界——跳过它找下一个
    // 标记；否则前一候选的内容区间会被句中裸字母提前截断（Win11 包 4：
    // 守门用例里 B 的内容区间因此在 `A∩B` 处断掉，跨段门误判 gap 有
    // 实质文字）。非裸候选仍按原规则截断。
    for (var k = i + 1; k < sorted.length; k++) {
      final nxt = sorted[k];
      if (nxt.orderKey >= end) break;
      if (nxt.kind == _CandidateKind.text &&
          nxt.format == _MarkerFormat.bare) {
        continue;
      }
      end = nxt.orderKey;
      break;
    }
    for (final nLine in structuralNLines) {
      if (nLine > c.markerEnd && nLine < end) {
        end = nLine;
        break;
      }
    }
    if (end < c.markerEnd) end = c.markerEnd;
    c.contentStart = c.markerEnd;
    c.contentEnd = end;
    c.hasContent = _intervalHasContent(ctx, c.markerEnd, end);
  }
}

/// 标记后同行是否有非空内容（S3-2(d)）：同行剩余文本去标签、
/// 去代码占位符后含非标点字符。
bool _sameLineHasContent(String text, int from) {
  final lineEnd = text.indexOf('\n', from);
  final lineTail = text.substring(from, lineEnd < 0 ? text.length : lineEnd);
  final stripped = lineTail
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll(RegExp(r'\x00MUSE_PH_\d+\x00'), '');
  for (var t = 0; t < stripped.length; t++) {
    final ch = stripped.codeUnitAt(t);
    if (_isSpace(ch)) continue;
    if (_noContentChars.contains(stripped[t])) continue;
    return true;
  }
  return false;
}

/// 行首 (n) 标记行的起点（工作文本坐标）：行首的 `(n)`/`（n）`
/// （n 为阿拉伯数字或带圈数字）且标记后同行有非空内容。
/// 用于截断内容区间；是否成为小问边界还须过 S3-2 的 (b)(c) 两关。
List<int> _structuralNLineStarts(
  _ParseContext ctx,
  List<({int start, int end})> formulas,
  List<({int start, int end})> tableSpans,
) {
  final text = ctx.workingText;
  final pattern = RegExp(
    r'[（(]\s*(\d{1,2})\s*[)）]|([①②③④⑤⑥⑦⑧⑨⑩])',
  );
  final out = <int>[];
  for (final m in pattern.allMatches(text)) {
    final start = m.start;
    if (_insideAny(start, formulas)) continue;
    if (ctx.placeholders.any(
      (p) => start >= p.workStart && start < p.workEnd,
    )) {
      continue;
    }
    if (_insideAny(start, tableSpans)) continue;
    if (!_isLineStart(text, start)) continue;
    if (!_sameLineHasContent(text, m.end)) continue;
    out.add(start);
  }
  return out;
}

/// 区间内是否有实际内容：跳过空白与 HTML 标签后须有字，且不是下一个
/// 选项标记、也不只剩标点；区间内含代码占位符即算有内容（代码本身就是
/// 选项内容）。
bool _intervalHasContent(_ParseContext ctx, int from, int to) {
  if (from >= to) return false;
  if (ctx.placeholders.any(
    (p) => p.workStart >= from && p.workStart < to,
  )) {
    return true;
  }
  final raw = ctx.workingText
      .substring(from, to)
      .replaceAll(RegExp(r'<[^>]*>'), '');
  var i = 0;
  while (i < raw.length && _isSpace(raw.codeUnitAt(i))) {
    i++;
  }
  if (i >= raw.length) return false;
  if (_markerPattern.matchAsPrefix(raw, i) != null) return false;
  if (_barePattern.matchAsPrefix(raw, i) != null) return false;
  if (_noContentChars.contains(raw[i])) return false;
  return true;
}

/// 行首 `(n)` 小问标记判别（S3-2/T2-2）：当且仅当同时满足
/// (a) 位于行首（按原始行号，T5-1）；(b) 不在已认定的选项候选的内容
/// 区间内；(c) 它是本茎干内第一个此类标记且 n == 1，或 n == 上一个
/// 小问标记的编号 + 1；(d) 标记后同行有非空内容。
/// 任一不满足 → 按普通文本处理。T2-1：凡满足四条件者一律作为小问，
/// 不再追加上下文判据；普通编号列表因此被误判为小问是已知局限。
/// 返回小问边界所在行号集合（工作文本行号）。
Set<int> _detectSubQuestionBoundaries(
  _ParseContext ctx,
  List<_Candidate> candidates,
  List<({int start, int end})> formulas,
  _LineBlocks blocks,
) {
  final text = ctx.workingText;
  // 括号式 (n)/（n）与裸带圈数字 ①②…（T2-2：带圈数字规范化后参与
  // 小问序列与选项序列判定；裸阿拉伯数字是题号，不归此处管）。
  final pattern = RegExp(
    r'[（(]\s*(\d{1,2})\s*[)）]|([①②③④⑤⑥⑦⑧⑨⑩])',
  );
  final boundaries = <int>{};
  int? expected;
  for (final m in pattern.allMatches(text)) {
    final n = _subQuestionNumber(m.group(1), m.group(2));
    if (n == null) continue;
    final start = m.start;
    if (_insideAny(start, formulas)) continue;
    if (ctx.placeholders.any(
      (p) => start >= p.workStart && start < p.workEnd,
    )) {
      continue;
    }
    // (b) 不在已认定的选项候选的内容区间内。
    if (candidates.any(
      (c) => start >= c.contentStart && start < c.contentEnd,
    )) {
      continue;
    }
    // (a) 位于行首：按原始文本查（T5-1）。
    final origOffset = ctx.workingToOrig(start);
    var k = origOffset - 1;
    var atLineStart = true;
    while (k >= 0) {
      final ch = ctx.original.codeUnitAt(k);
      if (ch == 0x0A) break;
      if (!_isBlank(ch)) {
        atLineStart = false;
        break;
      }
      k--;
    }
    if (!atLineStart) continue;
    // (d) 标记后同行有非空内容。
    if (!_sameLineHasContent(text, m.end)) continue;
    // (c) 序列：首个须为 1，后续须为上一个 + 1。
    if (expected == null) {
      if (n != 1) continue;
    } else {
      if (n != expected) continue;
    }
    expected = n + 1;
    boundaries.add(blocks.lineOf(start));
  }
  return boundaries;
}

/// 小问编号归一化：阿拉伯数字直取；带圈数字 ①②③④⑤⑥⑦⑧⑨⑩ → 1–10（T2-2）。
int? _subQuestionNumber(String? arabic, String? circledRaw) {
  if (circledRaw != null) {
    const circled = '①②③④⑤⑥⑦⑧⑨⑩';
    return circled.indexOf(circledRaw) + 1;
  }
  if (arabic == null) return null;
  return int.tryParse(arabic);
}

// ---------------------------------------------------------------------------
// 序列组装与判定（§2.2 步骤 2–3；R2-1/R2-4）
// ---------------------------------------------------------------------------

/// 跨段接续门（Win11 包 4）：判断 [prev] 与 [next] 两个候选能否在一条
/// 选项序列里前后相邻。返回 null 表示可以接续，否则返回阻断原因（供
/// [_validateSequence] 汇总进 [StemSplitResult.reason] 诊断）。
///
/// * 同段（同一逻辑块，即中间无空行/题号行）→ 直接放行；
/// * 不同段、中间只有空白（空行）→ 仅当两边都是显式格式（非 `bare`）
///   标记时放行——裸字母（`A 甲`）是题干引用还是选项分不清，不得借空
///   行拼成选项（守门：图九 `A、B` 题干引用 + 空行 + 只有 `C、D` 时
///   不切分）；
/// * 不同段、中间有实质文字 → 一律阻断（选项序列被逻辑块隔开）。
String? _crossingBlockReason(
  String working,
  _Candidate prev,
  _Candidate next,
) {
  if (prev.blockId == next.blockId) return null;
  final gap = working.substring(prev.contentEnd, next.orderKey);
  if (gap.trim().isNotEmpty) return '选项序列被逻辑块隔开，不切分';
  if (prev.format == _MarkerFormat.bare ||
      next.format == _MarkerFormat.bare) {
    return '跨段选项序列含裸字母标记，不切分';
  }
  return null;
}

/// 从 A 候选起按文本顺序组装序列：字母严格连续，不跳号、不重复、
/// 不倒序；标记形式归一化，混用不扣分；E 只允许紧跟 D 之后（R2-4）；
/// 跨段接续走 [_crossingBlockReason] 门（Win11 包 4：空行分隔的双栏
/// 选项可跨段组装，裸字母或有实质文字隔开时阻断）。
/// 组装不到 B 时返回 null run；序列紧后的同块候选若不是新题的 A，
/// 说明缺号/重复，序列作废（R2-4：A/B/C/E 缺 D → 拒绝）。
/// 返回的 `blockedReason` 记录组装中遇到的第一条跨段阻断原因，供
/// [_validateSequence] 在结构门未过时汇总进诊断。
({List<_Candidate>? run, String? blockedReason}) _assembleSequence(
  List<_Candidate> candidates,
  _Candidate a,
  String working,
) {
  const order = ['A', 'B', 'C', 'D', 'E'];
  final sorted = [...candidates]..sort((x, y) => x.orderKey.compareTo(y.orderKey));
  final aIndex = sorted.indexOf(a);
  final run = <_Candidate>[a];
  var expected = 1; // 下一个期望字母在 order 中的下标
  var j = aIndex + 1;
  _Candidate? breaker;
  String? blockedReason;
  while (j < sorted.length) {
    final next = sorted[j];
    if (expected >= order.length) break;
    if (next.letter == order[expected]) {
      final reason = _crossingBlockReason(working, run.last, next);
      if (reason != null) {
        blockedReason = reason;
        break;
      }
      run.add(next);
      expected++;
      j++;
      continue;
    }
    // 非期望字母：文本裸字母是题干噪声（`A∩B` 里的 B、句首的 `B teacher…`），
    // 不是选项——跳过继续找期望字母，不作废序列、也不停止；其余
    // （显式格式标记、表格单字母格）才是缺号/重复的 breaker（仅当
    // 与序列尾同块时；跨块的候选不属于本序列，直接停止，原行为）。
    if (next.kind == _CandidateKind.text &&
        next.format == _MarkerFormat.bare) {
      j++;
      continue;
    }
    if (next.blockId != run.last.blockId) break;
    breaker = next;
    break;
  }
  if (run.length < 2) return (run: null, blockedReason: blockedReason);
  // 缺号/重复作废：序列紧后的同块候选若不是新题的 A，则序列作废。
  if (breaker != null && breaker.letter != 'A') {
    return (run: null, blockedReason: blockedReason);
  }
  return (run: run, blockedReason: blockedReason);
}

/// 验证一个 A 候选：返回（组装出的有效序列，失败原因）。
/// 失败原因供 notSplit 的 reason 使用；成功时原因为 null。
/// [working] 为工作文本，供跨段接续门判断两段之间的间隔。
(List<_Candidate>?, String?) _validateSequence(
  List<_Candidate> candidates,
  _Candidate a,
  String working,
) {
  if (!a.hasContent) {
    return (null, 'A 标记后无实际选项内容，不切分');
  }
  final sorted = [...candidates]..sort((x, y) => x.orderKey.compareTo(y.orderKey));
  final aIndex = sorted.indexOf(a);
  final next = aIndex + 1 < sorted.length ? sorted[aIndex + 1] : null;
  if (next == null) {
    return (null, '仅发现 A 标记，未见 B，不切分');
  }
  if (next.letter == 'A') {
    return (null, '仅发现 A 标记，未见 B，不切分');
  }
  if (next.letter != 'B') {
    return (null, '选项序列缺号/重复，不切分');
  }
  // B 接续门（Win11 包 4）：B 与 A 跨段时走跨段规则——空行 + 双边
  // 显式格式才放行，裸字母或中间有实质文字时阻断（原“同块”要求
  // 放宽为空行分隔的双栏选项服务）。
  final crossing = _crossingBlockReason(working, a, next);
  if (crossing != null) {
    return (null, crossing);
  }
  final assembled = _assembleSequence(candidates, a, working);
  final seq = assembled.run;
  if (seq == null) {
    return (null, assembled.blockedReason ?? '选项序列缺号/重复，不切分');
  }
  for (final c in seq) {
    if (!c.hasContent) {
      return (null, '${c.letter} 标记后无实际选项内容，不切分');
    }
  }
  // 结构分（R2-1）：至少 2 个强标记，或完整 A–D 且每标记后有内容。
  // 两项序列时“至少 2 个强”即两个标记均为强；裸字母的“升格”由完整
  // A–D 一条实现（裸 A–D 序列经此放行）。
  final strongCount = seq.where((c) => c.strong).length;
  final completeAD = seq.length >= 4 &&
      seq[0].letter == 'A' &&
      seq[1].letter == 'B' &&
      seq[2].letter == 'C' &&
      seq[3].letter == 'D';
  if (strongCount < 2 && !completeAD) {
    return (
      null,
      assembled.blockedReason ?? '结构分不足（强标记少于 2 个且序列非完整 A–D），不切分',
    );
  }
  return (seq, null);
}

// ---------------------------------------------------------------------------
// 关于 layout bbox 辅助信号（本版纯文本，不接；留给以后）：
// GLM-OCR 的 `layout_details` 里每块有 `bbox_2d`。以后如果要接，做法是
// 调用方在调 splitStem 之前利用 bbox 做两件事，不改本函数签名：
//   1. 块过滤：只把“选项块”下方的文本拼进输入，或把明显属于页眉、
//      页脚、水印的块去掉，减少误切的输入噪声；
//   2. 位置校验：把本函数找到的候选切分点映射回块——A、B 是否落在
//      同一水平行、是否集中在题目下半部、是否各占独立文本块，
//      用来给“存在歧义”的候选排序或升级为自动切分。
// 单题裁剪上 GLM 只返回 1 个块（整题一块），bbox 在此场景下几乎没有
// 区分度，所以本版先做纯文本版；走“整页调一次再映射回各题”路线时
// bbox 才有实际价值。
// ---------------------------------------------------------------------------
