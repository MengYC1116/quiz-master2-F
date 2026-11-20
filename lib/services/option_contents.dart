// Win11 反馈包 5（识别全部）：选项内容统一解析器（纯函数）。
//
// 一份解析规则，三处共用：新 OCR 写回（ocr_queue）、ocr_raw 回填、
// 分类器结构化选项信号（question_classifier）。不得各行其是。
//
// 输入：GLM-OCR 返回的原始 Markdown 全文 + [splitStem] 的判定。
// 输出：按标签映射的选项内容 `{"A":"偶函数","B":"奇函数",...}`。
//
// 规则：
// - 只认严格连续的 A→B→C… 序列（从 A 起，不跳号）；每槽内容是
//   该标记之后、下一标记之前的文本，去掉开头的 A. /（A）等标记
//   再存（内容区间本身就从标记结束处起，标记不在内容里）。
// - 有标签无文字允许空（该槽记 ''）；有文字无标签不静默丢弃：
//   重复标签、超范围标记（F…）的文字进 [orphans]，调用方负责
//   报告/诊断，不得直接扔掉。
// - 公式与代码块内的字母不是标记（与 splitStem 同一词法优先级：
//   代码保护 → 公式识别 → 选项扫描；见 optionScanExcludedRanges）。
// - 选项里的公式按原文保留（$…$ / $$…$$ 不动，反斜杠与上下标
//   不破坏）；选项里的配图引用行（独占一行的
//   `![](page=…,bbox=[…])`）从内容里剥离，记入
//   [strippedFigureRefs]（图块本身在 ocr_figures 里，不丢；
//   这里只记诊断，不删图）。
// - 切分失败（notSplit：连 A→B 序列都没有）时不产出选项内容：
//   选项文字已在题干文本里，选项区不再重复显示。
// - 切分失败时即使扫出 A→B 序列，也只认含显式标记（A. / A、/ （A）等）
//   的序列：全是裸字母（`A 甲`）的序列不产出选项内容——裸字母在行内
//   文本里太常见（REV5 §2.4“裸 A/B 不硬猜”），否则分类器的结构化
//   选项信号会把题干里的裸字母误判成选项。切分成功时不设此门（切分
//   器已判定序列是真选项，裸标记也认）。
// - 判断题不走本解析器（调用方按题型守门，固定“正确/错误”）。
// - 表格/div 选项：先把块级闭合标签（</td> </tr> </div> </p> <br>）
//   换成换行、其余标签剥掉，再按同一规则扫描，标记与内容一一对应。

import 'dart:convert';

import 'stem_splitter.dart';

/// 选项内容解析器版本：回填与新 OCR 写回都记这个版本；规则变了就 +1，
// 旧数据可凭版本识别是用哪版规则解析的。
// v2（Win11 反馈全量复核）：切分失败时全裸标记序列不产出选项内容
//（见 parseOptionContents 的 hasExplicitAccepted 门）。
const int optionContentsParserVersion = 2;

/// 统一解析器的解析结果。
class ParsedOptionContents {
  const ParsedOptionContents({
    required this.contents,
    required this.orphans,
    required this.strippedFigureRefs,
    required this.parserVersion,
  });

  /// 按标签映射的选项内容；有标签无文字的槽记 ''。
  final Map<String, String> contents;

  /// 有文字无标签、不便归入任何槽的文本（重复标签、超范围标记的
  /// 文字）：保留下来供调用方报告/诊断，不静默丢弃。
  final List<String> orphans;

  /// 从选项内容里剥离的独占一行图引用原文（诊断用；图块在
  /// ocr_figures 里，不丢）。
  final List<String> strippedFigureRefs;

  /// 解析时用的解析器版本（见 [optionContentsParserVersion]）。
  final int parserVersion;

  /// 有实际文字的选项槽数。
  int get nonEmptyCount =>
      contents.values.where((v) => v.trim().isNotEmpty).length;

  /// 是否有结构化选项内容（≥2 个选项槽有文字）：分类器的选择候选
  /// 信号，与切分信号互补。
  bool get hasStructuredOptions => nonEmptyCount >= 2;
}

const _emptyParsed = ParsedOptionContents(
  contents: {},
  orphans: [],
  strippedFigureRefs: [],
  parserVersion: optionContentsParserVersion,
);

/// 对一段 OCR 全文跑切分 + 选项解析（回填与测试的便捷入口）。
ParsedOptionContents parseOptionContentsForText(String ocrText) =>
    parseOptionContents(ocrText, splitStem(ocrText));

/// 统一选项解析器：纯函数，不抛异常。
ParsedOptionContents parseOptionContents(
  String ocrText,
  StemSplitResult split,
) {
  if (ocrText.trim().isEmpty) return _emptyParsed;
  // 切分成功时从 A 处切（与题干切分点一致）；否则全段扫描——
// 能扫出严格连续的 A→B 序列才产出内容（分类器信号用），扫不出
  // 时返回空（notSplit 的题选项区不重复显示）。
  final segment = split.status == StemSplitStatus.autoSplit &&
          split.cutIndex != null
      ? ocrText.substring(split.cutIndex!)
      : ocrText;
  // 块级闭合标签换行、其余标签剥掉（表格/div 选项与文本选项同一规则）。
  final search = _flattenForScan(segment);
  if (search.trim().isEmpty) return _emptyParsed;
  final excluded = optionScanExcludedRanges(search);
  final markers = _scanMarkers(search, excluded);
  if (markers.isEmpty) return _emptyParsed;

  final contents = <String, String>{};
  final orphans = <String>[];
  final strippedFigureRefs = <String>[];
  var expected = 'A'.codeUnitAt(0);
  var lastBoundaryEnd = -1; // 上一个已认选项标记的结束位置
  String? lastLabel;
  // 序列里是否至少含一个显式标记（_markerPattern 命中；裸字母不算）：
  // 切分失败时全裸序列不产出选项内容（REV5 §2.4“裸 A/B 不硬猜”）。
  var hasExplicitAccepted = false;
  // 逐个标记：符合期望字母的作选项边界；不符合的（重复/超范围/
  // 缺号后的）整段进 orphans，期望字母不动，继续向后找。
  // 任一标记到来时，先把上一选项的内容结算到本标记起点为止。
  for (var i = 0; i < markers.length; i++) {
    final m = markers[i];
    final nextStart = i + 1 < markers.length
        ? markers[i + 1].start
        : search.length;
    if (lastLabel != null) {
      final raw = search.substring(lastBoundaryEnd, m.start);
      contents[lastLabel] = _cleanChunk(raw, strippedFigureRefs);
      lastLabel = null;
    }
    if (m.letter.codeUnitAt(0) == expected &&
        m.letter.codeUnitAt(0) <= 'E'.codeUnitAt(0)) {
      lastLabel = m.letter;
      lastBoundaryEnd = m.end;
      if (m.explicit) hasExplicitAccepted = true;
      expected++;
    } else {
      // 不合期望的标记：重复标签、超范围标记（F…）、E 之后的标记——
      // 它到下一标记之间的文字是孤儿文本，保留。
      final raw = search.substring(m.end, nextStart);
      final cleaned = _cleanChunk(raw, strippedFigureRefs);
      if (cleaned.isNotEmpty) orphans.add(cleaned);
    }
  }
  // 最后一个选项的内容收到段尾。
  if (lastLabel != null) {
    final raw = search.substring(lastBoundaryEnd);
    contents[lastLabel] = _cleanChunk(raw, strippedFigureRefs);
  }
  // 序列必须至少到 B 才算数（只有 A 一个标记不是选项序列，与
  // splitStem 的“只 A 不切”同口径）；否则不产出内容。
  if (contents.length < 2) {
    return ParsedOptionContents(
      contents: const {},
      orphans: orphans,
      strippedFigureRefs: strippedFigureRefs,
      parserVersion: optionContentsParserVersion,
    );
  }
  // 切分失败且序列全是裸标记时不产出选项内容：裸字母在行内文本里太
  // 常见，不能当作结构化选项的证据（否则分类器会把题干里的裸字母
  // 误判成选项，见 wp_a2 §2.4）；序列里至少含一个显式标记，或切分
  // 成功时，不受此限。
  if (split.status != StemSplitStatus.autoSplit && !hasExplicitAccepted) {
    return ParsedOptionContents(
      contents: const {},
      orphans: orphans,
      strippedFigureRefs: strippedFigureRefs,
      parserVersion: optionContentsParserVersion,
    );
  }
  return ParsedOptionContents(
    contents: contents,
    orphans: orphans,
    strippedFigureRefs: strippedFigureRefs,
    parserVersion: optionContentsParserVersion,
  );
}

/// 扫描用的一个选项标记。
class _ScanMarker {
  const _ScanMarker({
    required this.letter,
    required this.start,
    required this.end,
    required this.explicit,
  });
  final String letter;
  final int start;
  final int end;

  /// 是否显式标记（_markerPattern 命中，如 `A.` / `A、` / `(A)`）；
  /// 裸字母（_barePattern，如 `A 甲`）为 false。
  final bool explicit;
}

/// 选项标记正则（与 stem_splitter 的 _markerPattern 同款形状，
/// 只认大写 A–E 含全角；括号式优先，再是后缀式）。
/// 另扫 A–Z 超范围标记（F…）：它们永不成选项，只作孤儿文本的边界，
/// 使“有文字无标签不静默丢弃”可落实。
final _markerPattern = RegExp(
  r'[（(]\s*[A-ZＡ-Ｚ]\s*[)）]|[A-ZＡ-Ｚ][.．、)）:：]',
);

/// 裸字母标记：字母 + 单个空格 + 内容字符（`A 甲`）。
final _barePattern = RegExp(r'[A-ZＡ-Ｚ] (?=\S)');

/// 不算内容的首字符集（与 stem_splitter 同口径）。
const _noContentChars = '.,;:!?，。；：、）)）';

String _normalizeLetter(String raw) {
  final c = raw.codeUnitAt(0);
  if (c >= 0xFF21 && c <= 0xFF3A) {
    return String.fromCharCode(c - 0xFF21 + 0x41);
  }
  return raw;
}

bool _isSpace(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x3000;

bool _insideAny(int offset, List<({int start, int end})> ranges) =>
    ranges.any((r) => offset >= r.start && offset < r.end);

/// 标记边界：段首、行首、或前面是空白（行内紧贴其他字符的字母不是标记）。
bool _hasMarkerBoundary(String text, int start) {
  if (start == 0) return true;
  return _isSpace(text.codeUnitAt(start - 1));
}

/// 在搜索文本里扫出全部候选标记（跳过公式/代码区间、无边界的）。
List<_ScanMarker> _scanMarkers(
  String text,
  List<({int start, int end})> excluded,
) {
  final out = <_ScanMarker>[];
  final taken = <int>{};
  for (final m in _markerPattern.allMatches(text)) {
    if (_insideAny(m.start, excluded)) continue;
    if (!_hasMarkerBoundary(text, m.start)) continue;
    final raw = m.group(0)!;
    final letterCode = raw.codeUnits.firstWhere(
      (c) => (c >= 0x41 && c <= 0x5A) || (c >= 0xFF21 && c <= 0xFF3A),
    );
    taken.add(m.start);
    out.add(
      _ScanMarker(
        letter: _normalizeLetter(String.fromCharCode(letterCode)),
        start: m.start,
        end: m.end,
        explicit: true,
      ),
    );
  }
  for (final m in _barePattern.allMatches(text)) {
    final start = m.start;
    if (taken.contains(start)) continue;
    if (_insideAny(start, excluded)) continue;
    if (!_hasMarkerBoundary(text, start)) continue;
    final contentPos = start + 2;
    if (contentPos >= text.length) continue;
    final c = text.codeUnitAt(contentPos);
    if (_isSpace(c) || _noContentChars.contains(String.fromCharCode(c))) {
      continue;
    }
    taken.add(start);
    out.add(
      _ScanMarker(
        letter: _normalizeLetter(text[start]),
        start: start,
        end: start + 1,
        explicit: false,
      ),
    );
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// 块级闭合标签换行、其余 HTML 标签剥掉，得到扫描用纯文本。
/// 公式 `$…$` 与行内代码 `` `…` `` 不含标签，原样保留。
String _flattenForScan(String segment) {
  var text = segment;
  // 单元格闭合换空格：`<td>A</td><td>偶函数</td>` 展平后成
  // `A 偶函数`，裸字母标记可认；行/块闭合换行。
  text = text.replaceAll(RegExp(r'</(td|th)>'), ' ');
  text = text.replaceAll(RegExp(r'</(tr|table|div|p|li|ul|ol)>'), '\n');
  text = text.replaceAll(RegExp(r'<br\s*/?>'), '\n');
  text = text.replaceAll(RegExp(r'<[^>]*>'), '');
  return text;
}

/// GLM md 图引用行：独占一行的 `![](page=<n>,bbox=[...])`
///（与 stem_splitter / ocr_figures 同款格式）。
final _figureRefLinePattern = RegExp(
  r'^\s*!\[.*?\]\(page=\d+,bbox=\[\d+,\s*\d+,\s*\d+,\s*\d+\]\)\s*$',
  multiLine: true,
);

/// 清理一个选项内容块：去掉独占一行的图引用行（记入
/// [strippedFigureRefs] 做诊断）、去首尾空白。公式、反斜杠与
/// 上下标原样保留；行内图引用不动。
String _cleanChunk(String raw, List<String> strippedFigureRefs) {
  final lines = raw.split('\n');
  final kept = <String>[];
  for (final line in lines) {
    if (_figureRefLinePattern.hasMatch(line)) {
      strippedFigureRefs.add(line.trim());
      continue;
    }
    kept.add(line);
  }
  return kept.join('\n').trim();
}

// ---------------------------------------------------------------------------
// 编解码：option_contents 列的存储表示是标签映射 JSON
// `{"A":"偶函数","B":"奇函数",...}`；NULL = 未解析/无选项内容。
// ---------------------------------------------------------------------------

/// 编码：null → null（未解析）；map → JSON 文本。
String? encodeOptionContents(Map<String, String>? contents) =>
    contents == null ? null : jsonEncode(contents);

/// 解码：null/''/非法 JSON/非对象/非字符串值 → null（读侧可识别，
/// 不抛异常）。合法的标签映射原样返回。
Map<String, String>? decodeOptionContents(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final out = <String, String>{};
    for (final e in decoded.entries) {
      if (e.key is! String || e.value is! String) return null;
      out[e.key as String] = e.value as String;
    }
    return out;
  } catch (_) {
    return null;
  }
}

/// 校验（备份恢复用）：null/'' → 合法（未解析）；否则必须是
/// JSON 对象、键为单个大写字母 A–Z、值为字符串。
bool isValidOptionContentsJson(String? raw) {
  if (raw == null || raw.isEmpty) return true;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return false;
    for (final e in decoded.entries) {
      if (e.key is! String ||
          e.value is! String ||
          !RegExp(r'^[A-Z]$').hasMatch(e.key as String)) {
        return false;
      }
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// 按标签取某选项的文字；无该键时返回 null。
String? optionContentFor(Map<String, String>? contents, String label) =>
    contents?[label];
