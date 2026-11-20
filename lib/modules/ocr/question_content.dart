// M1 十三批公式渲染器 POC（2026-11-18）。
//
// 题目内容段模型 + 混合文本解析器。给 M5 用：M5 接此接口做 OCR 题干入库与
// 展示，渲染实现可替换（flutter_math_fork / Ratex / 原图）而不改数据结构。
//
// 铁律（GPT 评审 §4.5 + 项目既定规则）：
// - LaTeX 只存在内部数据里（FormulaBlock.latex），绝不出现在界面、复制文本、
//   报错、日志里。本文件不做任何日志输出，调用方同样不得把 latex 打进日志。
// - 渲染失败回退原图（见 question_content_renderer.dart 的 FormulaView）。
// - 圈号预处理只在明确识别为 `\textcircled{n}` 命令的位置做确定性转换，
//   不对整个字符串做 Unicode 全量规范化（GPT 评审 §1.3 / §4.4）。
//
// WP-C #6（九项修复 REV5，2026-11-19）：HTML 表格与标题渲染。
// 定稿 `~/workspace/batch14-work/FIX-DESIGN-9-ISSUES.md`
// §6 + 附录 R4（REV2）+ S3/S7（REV3）+ T5/T7（REV4）+ U4（REV5）。
// - 新增 [TableBlock]/[HeadingBlock]；[TextBlock] 增加可选 inline run
//  （strong/b 粗体、em/i 斜体、sup/sub 上下标，见 [TextRun]）。
// - 解析优先级与 [splitStem]（`lib/services/stem_splitter.dart`）共用
//   （S3-1，不得各行其是）：1. 代码保护 → 2. 公式识别 →
//   3. HTML 结构解析（白名单）→ 4. 普通 Markdown 文本。
//   两处解析器在注释中互相引用；组合测试见
//   `test/wp_c6_html_table_heading_test.dart`（S3-1 组）。
// - 白名单（S7-1）：table/tr/td/th、div（仅 align="center" 有效）、p、br、
//   strong/b、em/i、sup/sub、span；其余标签剥掉标签、保留内部文字。
// - 异常结构回退（S7-3/T7-2）：最小失败单元（表/div/p/单元格/段落）
//   回退为纯文本，不丢字、不渲染半张表格；段根节点恒可回退，保证有穷终止。
//
// 已知局限（v1，写进代码与验收说明，不是 bug）：
// - 嵌套表格不支持：单元格内的 <table> 展平成纯文本（R4-3/S3-3/T5-4/T5-5）。
// - colspan/rowspan 无原生合并：内容放首格，余格留空（§6.2）。
// - div align="center" 只让内层表格居中；纯文本段落无居中表示。
// - <pre>/<code> 不受代码保护，按普通未知标签处理（T5-3）。
// - 数字字符引用只接受合法 Unicode 标量值，代理区/越界 → U+FFFD（U4-3）。

/// 题目内容的一段。sealed：M5 穷举分发，新增段类型编译期可发现。
sealed class QuestionContentBlock {
  const QuestionContentBlock();
}

/// 行内文本的一个 run：一段连续文字 + 粗体/斜体/上下标样式。
/// [script]：0 普通，1 上标，-1 下标。
class TextRun {
  const TextRun(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.script = 0,
  });

  final String text;
  final bool bold;
  final bool italic;
  final int script;
}

/// 普通文字段（中文 / 英文 / 已转圈号字符 ①②③④ 等）。
///
/// [runs] 为空时是纯文本段（与旧行为一致）；非空时 [text] 等于各 run
/// 文本的拼接，渲染层按 run 的样式出 RichText（WP-C #6，S7-2）。
class TextBlock extends QuestionContentBlock {
  const TextBlock(this.text, {this.runs});
  final String text;
  final List<TextRun>? runs;
}

/// 公式段。`latex` 不含 `$` 定界符，已做首尾去空格与圈号预处理。
/// [displayMode] 为 true 时是独立公式（`$$...$$`），否则是行内公式。
class FormulaBlock extends QuestionContentBlock {
  const FormulaBlock(this.latex, {this.displayMode = false});
  final String latex;
  final bool displayMode;
}

/// 公式原图回退段：渲染失败、或用户把公式恢复为原图时用。
///
/// [cropPath] 是按 GLM `layout_details` 坐标从题切片里裁出的公式小图；
/// 为空时用整张题切片（GPT 评审 §3.4：裁不到用整张切片）。
/// [formulaId] 仅内部标识，不展示。
class ImageFallbackBlock extends QuestionContentBlock {
  const ImageFallbackBlock({this.cropPath, this.formulaId});
  final String? cropPath;
  final String? formulaId;
}

/// 代码段（D-105 通用性要求）：计算机题干里的程序按等宽文本显示，不当公式解析。
class CodeBlock extends QuestionContentBlock {
  const CodeBlock(this.code, {this.language});
  final String code;
  final String? language;
}

/// 配图图块段（十四批 M2）：OCR 识别出的题目插图，按阅读顺序插在
/// 内容序列里。[cropPath] 是图块裁图相对路径；[unconfirmed] 为 true
/// 时位置未确认（数据层诊断用；界面不再作任何未确认标注，见 Win11
/// 反馈包 3）。
class FigureBlock extends QuestionContentBlock {
  const FigureBlock({
    required this.figureId,
    required this.cropPath,
    this.unconfirmed = false,
  });

  final String figureId;
  final String cropPath;
  final bool unconfirmed;
}

/// 表格单元格（WP-C #6，R4-1 富内容模型）。
///
/// [children] 是单元格内容的行内解析结果（TextBlock / FormulaBlock /
/// ImageFallbackBlock 等的混合），不再压成纯字符串；渲染时单元格内按
/// Column 依次渲染。单元格内遇到嵌套 <table> 时直接展平成纯文本
/// （T5-5），不进通用 children 递归解析器。
class TableCell {
  const TableCell({
    required this.children,
    this.colspan = 1,
    this.rowspan = 1,
  });

  final List<QuestionContentBlock> children;

  /// 占几列（正整数，默认 1；非法值解析时已归一为 1）。
  final int colspan;

  /// 占几行（正整数，默认 1；非法值解析时已归一为 1）。
  final int rowspan;
}

/// 表格段（WP-C #6）。
///
/// [rows] 已按 colspan/rowspan 展开为等长矩形网格：跨列/跨行的内容
/// 放在首格，余下被跨格是 [TableCell(children: [])] 的空单元格
/// （Flutter Table 无原生合并单元格，此为已知的 v1 局限，不静默丢字）。
/// [centered] 为 true 时表格居中（来自外层 `<div align="center">`）。
class TableBlock extends QuestionContentBlock {
  const TableBlock(this.rows, {this.centered = false});
  final List<List<TableCell>> rows;
  final bool centered;
}

/// 标题段（WP-C #6）：行首 `#`/`##`/`###` + 空格的标题行。
/// [level] 1–3；正文中间的 `#`（如 `C#`）不成标题，保留原文。
class HeadingBlock extends QuestionContentBlock {
  const HeadingBlock(this.text, this.level);
  final String text;
  final int level;
}

/// 圈号字符表：只覆盖 GLM 政治卷实际出现的 1–20。超出范围的不转换，
/// 留给渲染层走原图回退（不可静默编造不存在的圈号字符）。
const Map<int, String> circledNumbers = {
  1: '①',
  2: '②',
  3: '③',
  4: '④',
  5: '⑤',
  6: '⑥',
  7: '⑦',
  8: '⑧',
  9: '⑨',
  10: '⑩',
  11: '⑪',
  12: '⑫',
  13: '⑬',
  14: '⑭',
  15: '⑮',
  16: '⑯',
  17: '⑰',
  18: '⑱',
  19: '⑲',
  20: '⑳',
};

/// `\textcircled{n}` → ①②③④……确定性转换。
///
/// 只匹配命令本身出现的位置；其余字符（包括全角字母、破折号、其他数字）
/// 原样不动，不做任何 Unicode 全量规范化。`n` 不在 1–20 时保留原命令，
/// 由渲染层按不支持公式处理（回退原图），不在此静默改写。
String preprocessCircledNumbers(String input) {
  return input.replaceAllMapped(
    RegExp(r'\\textcircled\{(\d{1,2})\}'),
    (match) {
      final n = int.tryParse(match.group(1)!);
      return circledNumbers[n] ?? match.group(0)!;
    },
  );
}

/// 纯圈号内容（预处理后的 ①②③④……）不是公式，是正文标号（GPT 评审 §4.4：
/// “圈号如果属于正文标号，可以直接作为 Unicode 文本显示，不必再交给
/// 公式解析器”）。GLM 常把圈号包在 `$...$` 里输出，解析时把这类段
/// 还原成 TextBlock，避免无意义地走公式渲染。
bool _isCircledLabel(String latex) =>
    RegExp(r'^[①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳]+$').hasMatch(latex);

/// 解析题目内容（Markdown + 有限 HTML 子集）为内容段序列。
///
/// 统一词法优先级（S3-1，与 [splitStem]——`lib/services/stem_splitter.dart`
/// ——共用，不得各行其是；两处解析器实现同一顺序，并在代码注释中互相引用；
/// WP-A #2 已在 splitStem 侧写了互相引用注释，本函数即 reciprocal 一侧）：
///   1. 代码保护：fenced ``` 块与行内 ` 段 → 占位符隔离，永不参与
///      公式/HTML 扫描（U4-1：占位符用含 NUL 字节的内部标识
///      `\x00MUSE_PH_<序号>\x00`，与 #2 同款做法，恢复时按标识精确还原；
///      代码占位符在正常解析与异常回退中都必须原样保留）；
///   2. 公式识别：`$$…$$`、再 `$…$`（`\$` 字面、未闭合 `$` 字面）；
///   3. HTML 结构解析（白名单，见 S7；嵌套表展平，见 S3-3/T5-5）；
///   4. 普通 Markdown 文本。
/// 固定处理顺序（U4-1）：① 原始文本上做代码保护；② 对其余文本做 HTML
/// 实体解码；③ 结构解析。位置映射以步骤 ① 完成后的文本版本为基准。
/// v1 不保护 HTML 的 `<pre>`/`<code>` 标签，按普通未知标签处理
/// （剥标签、保留内部文字，T5-3）；受保护的代码形式只有 fenced ``` 块
/// 与行内 ` 段。
///
/// - 先做圈号预处理（见 [preprocessCircledNumbers]）。
/// - ```` ``` ```` 围栏代码块优先于公式定界符：代码里的 `$` 不切公式。
/// - `\$` 是转义美元符，不切公式。
/// - 公式内首尾空白去掉（GLM 常输出 `$ 4 x^{2}... $` 这种带空格形式）。
/// - 空公式（`$ $` / `$$ $$`）直接丢弃，不产生空段。
/// - 相邻 TextBlock 合并；全空输入返回空列表。
/// - 注意：本函数只切段，不校验 LaTeX 合法性；非法公式由渲染层
///   [FormulaView] 在 build 时捕获并换成 [ImageFallbackBlock]。
/// - 异常结构回退：见 [TableBlock]/[HeadingBlock] 的文档与 S7-3/T7-2。
List<QuestionContentBlock> parseQuestionContent(String markdown) {
  final input = preprocessCircledNumbers(markdown);
  // ① 代码保护（U4-1 步骤 ①）。
  final protection = _protectCode(input);
  // ② 对其余文本做 HTML 实体解码（U4-1 步骤 ②；占位符 span 不解码）。
  final working = _decodeEntities(
    protection.$1,
    protection.$2,
  );
  // ③ 结构解析（U4-1 步骤 ③）：先扫公式区间（公式内的 `<` 不当标签），
  // 再做 HTML 树解析，最后由块组装产出段序列。
  final formulas = _scanFormulas(working);
  final parsed = _parseHtml(working, formulas);
  final ctx = _ParseCtx(
    working: working,
    placeholders: protection.$2,
    strays: parsed.$2,
  );
  return _assembleBlocks(
    parsed.$1.children,
    ctx,
    centered: false,
    fold: false,
  );
}

/// 找行内公式的闭合 `$`：跳过 `\$`，且不跨行（行内公式不跨行；
/// 换行后仍无闭合 `$` 视为无公式，把 `$` 当普通字符）。
int _findInlineClose(String input, int from) {
  var j = from;
  while (j < input.length) {
    final c = input[j];
    if (c == '\n') return -1;
    if (c == r'\') {
      j += 2;
      continue;
    }
    if (c == r'$') return j;
    j++;
  }
  return -1;
}

/// 把内容段拼回 Markdown 题干（[parseQuestionContent] 的逆操作，
/// M5 纠错编辑器保存时用：编辑器按块改完后拼回 ocr_stem）。
///
/// - TextBlock：原样拼回（行内样式 run 拼回时只保留纯文本，粗体/斜体/
///   上下标标记不保留——纠错编辑器目前无样式编辑入口，样式信息在拼回
///   时丢失是已知的 v1 局限；原始题干仍在 ocr_raw 的 md_results 里）；
/// - FormulaBlock：行内 `$...$`、独立 `$$...$$`；
/// - CodeBlock：围栏 ```lang\n...\n```（语言为空时不写语言名）；
/// - ImageFallbackBlock：不拼（恢复为原图的公式在保存时从题干里拿掉，
///   以原图显示；原始公式仍在 ocr_raw 的 md_results 里，不丢）。
/// - TableBlock：拼回 `<table><tr><td>…` 形式（colspan/rowspan > 1 时
///   写回属性）；单元格内多段直接拼接，多段落单元格拼回后成为一段
///   （段落边界丢失是已知局限，文字不丢）；
/// - HeadingBlock：`#` × level + 空格 + 标题文字；拼回时若前一段
///   未以换行结尾，补一个换行（标题必须位于行首才能再解析出来）。
/// 拼回的文本再经 [parseQuestionContent] 应得到相同的段序列
///（首尾空白、围栏后的换行等排版细节除外，见测试锁定）。
String blocksToMarkdown(List<QuestionContentBlock> blocks) {
  final buf = StringBuffer();
  for (final block in blocks) {
    switch (block) {
      case TextBlock(:final text):
        buf.write(text);
      case FormulaBlock(:final latex, :final displayMode):
        if (displayMode) {
          buf.write('\$\$$latex\$\$');
        } else {
          buf.write('\$$latex\$');
        }
      case CodeBlock(:final code, :final language):
        // 解析时 code 含围栏闭合前的那个换行（见 parseQuestionContent）；
        // 拼回时去掉恰好一个尾换行再补围栏，否则每次拼回多一个空行，
        // 解析→拼回→再解析的段序列会对不上。
        final body = code.endsWith('\n')
            ? code.substring(0, code.length - 1)
            : code;
        buf.write('```${language ?? ''}\n$body\n```');
      case ImageFallbackBlock():
        break;
      case FigureBlock():
        // 图块不在题干文本里：拼回题干时跳过（图块只存在 ocr_figures 里）。
        break;
      case TableBlock(:final rows):
        buf.write('<table>');
        for (final row in rows) {
          buf.write('<tr>');
          for (final cell in row) {
            buf.write('<td');
            if (cell.colspan > 1) buf.write(' colspan="${cell.colspan}"');
            if (cell.rowspan > 1) buf.write(' rowspan="${cell.rowspan}"');
            buf.write('>');
            buf.write(blocksToMarkdown(cell.children));
            buf.write('</td>');
          }
          buf.write('</tr>');
        }
        buf.write('</table>');
      case HeadingBlock(:final text, :final level):
        if (buf.isNotEmpty) {
          final s = buf.toString();
          if (!s.endsWith('\n')) buf.write('\n');
        }
        buf.write('#' * level);
        buf.write(' ');
        buf.write(text);
    }
  }
  return buf.toString();
}

// ---------------------------------------------------------------------------
// 统一解析上下文（U4-1/T5-1）：代码保护 + 实体解码 + 位置映射
// 与 splitStem（`lib/services/stem_splitter.dart`）共用同一约定，
// 不得各行其是：固定处理顺序 ① 代码保护 → ② 实体解码 → ③ 结构解析；
// 占位符用含 NUL 字节的内部标识（NUL 不可能出现在 OCR 文本里）。
// ---------------------------------------------------------------------------

/// 一个代码占位符（fenced ``` 块或行内 ` 段）。
class _CodePlaceholder {
  _CodePlaceholder({
    required this.sequence,
    required this.fenced,
    required this.source,
    required this.code,
    required this.language,
    required this.protStart,
    required this.protEnd,
  });

  /// 原始顺序序号。
  final int sequence;

  /// true = fenced ``` 块；false = 行内 ` 段。
  final bool fenced;

  /// 原始源码（含围栏/反引号本身；异常回退时按此原样还原）。
  final String source;

  /// fenced 块的代码正文（围栏行与闭合围栏之间）；行内段为 null。
  final String? code;

  /// fenced 块的语言名（无则 null）；行内段为 null。
  final String? language;

  /// 步骤 ① 完成后文本内的起止偏移（实体解码的占位符保护用）。
  final int protStart;
  final int protEnd;

  /// 含 NUL 字节的内部标识。
  String get id => '\x00MUSE_PH_$sequence\x00';
}

/// fenced 围栏 span 的代码正文：围栏行换行之后、闭合围栏之前。
String _fencedCode(String span) {
  final inner = span.substring(3, span.length - 3);
  final nl = inner.indexOf('\n');
  return nl == -1 ? '' : inner.substring(nl + 1);
}

/// fenced 围栏 span 的语言名（围栏行内容去空白；空则 null）。
String? _fencedLanguage(String span) {
  final inner = span.substring(3, span.length - 3);
  final nl = inner.indexOf('\n');
  final lang = (nl == -1 ? inner : inner.substring(0, nl)).trim();
  return lang.isEmpty ? null : lang;
}

/// 步骤 ① 代码保护：按原始文本顺序找出 fenced 块与行内段，
/// 逐个替换为占位符。未闭合的围栏/反引号按字面文本处理，不保护。
/// 返回（保护后文本，占位符列表）。
(String, List<_CodePlaceholder>) _protectCode(String original) {
  final spans = <({int start, int end, bool fenced})>[];
  final fenced = RegExp(r'```.*?```', dotAll: true);
  for (final m in fenced.allMatches(original)) {
    spans.add((start: m.start, end: m.end, fenced: true));
  }
  // 行内段：跳过与 fenced 块重叠的反引号（任一方向的重叠都跳过；
  // 只判起点会漏掉“行内段起点在块外、终点落在块内”的情形，与 #2 的
  // _rebuildProtection 同款问题；此处重建循环另有 s.start < cursor
  // 守卫故不抛错，但为与 splitStem 保持同一优先级（围栏优先），
  // 收集时即跳过重叠匹配）。
  // 未闭合的反引号按字面处理。
  final inline = RegExp(r'`[^`\n]+`');
  for (final m in inline.allMatches(original)) {
    if (spans.any((s) => m.start < s.end && m.end > s.start)) continue;
    spans.add((start: m.start, end: m.end, fenced: false));
  }
  spans.sort((a, b) => a.start.compareTo(b.start));
  final out = StringBuffer();
  final placeholders = <_CodePlaceholder>[];
  var cursor = 0;
  var seq = 0;
  for (final s in spans) {
    // 重叠 span（行内匹配起点落在 fenced 块内等）：已被占位符覆盖，跳过。
    if (s.start < cursor) continue;
    out.write(original.substring(cursor, s.start));
    final protStart = out.length;
    final id = '\x00MUSE_PH_$seq\x00';
    final spanText = original.substring(s.start, s.end);
    placeholders.add(
      _CodePlaceholder(
        sequence: seq,
        fenced: s.fenced,
        source: spanText,
        code: s.fenced ? _fencedCode(spanText) : null,
        language: s.fenced ? _fencedLanguage(spanText) : null,
        protStart: protStart,
        protEnd: protStart + id.length,
      ),
    );
    out.write(id);
    seq++;
    cursor = s.end;
  }
  out.write(original.substring(cursor));
  return (out.toString(), placeholders);
}

/// 步骤 ② HTML 实体解码（T7-3/U4-3）：`&amp;` `&lt;` `&gt;` `&quot;`
/// `&#39;` `&apos;` `&nbsp;`（转为空格）及数字字符引用
/// （`&#NN;` / `&#xHH;`）。数字引用只接受合法 Unicode 标量值；
/// 代理区码点与越界值统一替换为 U+FFFD。
/// 占位符 span 内的文本永不解码（占位符本身不含 `&`，此处再加一道 guard）。
String _decodeEntities(
  String text,
  List<_CodePlaceholder> placeholders,
) {
  final out = StringBuffer();
  final pattern = RegExp(
    r'&(#(?:[xX][0-9A-Fa-f]+|\d+)|amp|lt|gt|quot|apos|nbsp);',
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
          i = m.end;
          continue;
        }
      }
    }
    out.write(text[i]);
    i++;
  }
  return out.toString();
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

/// 合法 Unicode 标量值 → 该字符；代理区/越界 → U+FFFD（T7-3/U4-3）。
String _scalarOrReplacement(int v) {
  if (v < 0 || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF)) {
    return '�';
  }
  return String.fromCharCode(v);
}

// ---------------------------------------------------------------------------
// 公式扫描（S3-1 步骤 2；与 splitStem 的 _scanFormulas 同款规则）
// ---------------------------------------------------------------------------

/// 先扫描 `$…$` / `$$…$$` 公式区间；`\$` 是字面美元符；
/// 未闭合的 `$` 按字面文本处理；空公式区间不计入（调用方跳过）。
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
/// [closed]：是否见到了匹配的闭合标签（void/自闭合标签恒为 true；
/// 文末仍开着的、或被外层闭合标签连带关闭的为 false；异常回退据此判定）。
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
  bool closed = false;

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

final _tagNamePattern = RegExp(r'^[a-z][a-z0-9]*$');

/// 开启 [name] 标签时隐式闭合的栈顶元素（HTML 语义）：
/// `<p>` 关闭已开的 `<p>`；`<tr>` 关闭已开的 `<td>`/`<th>`/`<tr>`；
/// `<td>`/`<th>` 关闭已开的 `<td>`/`<th>`。隐式闭合记为 closed。
Set<String> _autoCloseSet(String name) {
  switch (name) {
    case 'p':
      return {'p'};
    case 'tr':
      return {'td', 'th', 'tr'};
    case 'td':
    case 'th':
      return {'td', 'th'};
    default:
      return const {};
  }
}

/// 容错解析，返回（根节点，游离闭合标签的偏移列表）。
/// - 未闭合标签在文末自动闭合（closed=false，可供回退判定）；
/// - 不匹配的闭合标签记入游离列表（标签本身丢弃，不参与文本）；
/// - 注释与 `<!…>` 跳过；
/// - 标签名非法（如 `< b >`、`<3>`）时整段 `<…>` 当字面文本保留，不丢字；
/// - 公式区间内的 `<…>` 不是标签（调用方传入 [_scanFormulas] 的结果）；
/// - `<pre>`/`<code>` 按普通未知标签处理（T5-3）。
(_HtmlNode, List<int>) _parseHtml(
  String text,
  List<({int start, int end})> formulas,
) {
  final root = _HtmlNode.element(tag: '__root__', attrs: {}, start: 0);
  root.closed = true;
  root.end = text.length;
  final stack = <_HtmlNode>[root];
  final strays = <int>[];
  final tagPattern = RegExp(
    r'<!--.*?-->|<!\[CDATA\[.*?\]\]>|<[^>]*>',
    dotAll: true,
  );
  bool insideFormula(int offset) =>
      formulas.any((r) => offset >= r.start && offset < r.end);
  var cursor = 0;
  for (final m in tagPattern.allMatches(text)) {
    if (insideFormula(m.start)) continue;
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
      if (name.isEmpty || !_tagNamePattern.hasMatch(name)) {
        continue; // 非法闭合标签：当字面文本（不推进 cursor）。
      }
      var idx = -1;
      for (var k = stack.length - 1; k >= 1; k--) {
        if (stack[k].tag == name) {
          idx = k;
          break;
        }
      }
      if (idx < 0) {
        strays.add(m.start);
        cursor = m.end;
        continue;
      }
      while (stack.length > idx) {
        final popped = stack.removeLast();
        // 弹到匹配元素本身时 closed=true；其上被连带关闭的为 false。
        popped.closed = stack.length == idx;
        popped.end = m.end;
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
    if (name.isEmpty || !_tagNamePattern.hasMatch(name)) {
      continue; // 非法标签：当字面文本（不推进 cursor）。
    }
    final autoClose = _autoCloseSet(name);
    while (stack.length > 1 && autoClose.contains(stack.last.tag)) {
      final popped = stack.removeLast();
      popped.closed = true;
      popped.end = m.start;
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
      node.closed = true;
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
    n.closed = false;
    n.end = text.length;
  }
  root.closed = true;
  return (root, strays);
}

/// 某节点子树是否全部已闭合（不含文本节点）。
bool _subtreeAllClosed(_HtmlNode node) {
  if (!node.isText && !node.closed) return false;
  for (final c in node.children) {
    if (!_subtreeAllClosed(c)) return false;
  }
  return true;
}

/// 某节点是否解析失败：子树有未闭合元素，或其 span 内有游离闭合标签。
bool _nodeFailed(_HtmlNode node, List<int> strays) {
  if (!_subtreeAllClosed(node)) return true;
  for (final s in strays) {
    if (s >= node.start && s < node.end) return true;
  }
  return false;
}

/// 某节点是否解析失败（表外版）：子树里跳过 <table> 内部——表内失败
/// 由表自己处理（只扁平相关单元格/表），不上升为父 div/p 的失败。
/// 用于 div/p 的失败判定（T7-2：回退粒度是最小的失败单元）。
bool _nodeFailedOutsideTables(_HtmlNode node, List<int> strays) {
  if (!node.closed) return true;
  final tableSpans = <({int start, int end})>[];
  void collect(_HtmlNode n) {
    for (final c in n.children) {
      if (c.isText) continue;
      if (c.tag == 'table') {
        tableSpans.add((start: c.start, end: c.end));
        continue;
      }
      collect(c);
    }
  }

  collect(node);
  bool insideTable(int offset) =>
      tableSpans.any((s) => offset >= s.start && offset < s.end);
  bool walk(_HtmlNode n) {
    for (final c in n.children) {
      if (c.isText) continue;
      if (c.tag == 'table') continue;
      if (!c.closed) return false;
      if (!walk(c)) return false;
    }
    return true;
  }

  if (!walk(node)) return true;
  for (final s in strays) {
    if (s >= node.start && s < node.end && !insideTable(s)) return true;
  }
  return false;
}

/// 某表格是否解析失败（表级别）：只检查表/行/组级别——
/// table/tr/thead/tbody/tfoot 本身未闭合、td/th 本身未闭合、
/// 落在单元格之外的游离闭合标签。单元格内部的失败（未闭合行内元素、
/// 单元格内游离标签）由单元格自己处理，只扁平该格，不上升为整表失败。
bool _tableFailed(_HtmlNode table, List<int> strays) {
  if (!table.closed) return true;
  final cellSpans = <({int start, int end})>[];
  void collectCells(_HtmlNode node) {
    for (final c in node.children) {
      if (c.isText) continue;
      if (c.tag == 'td' || c.tag == 'th') {
        cellSpans.add((start: c.start, end: c.end));
        continue;
      }
      collectCells(c);
    }
  }

  collectCells(table);
  bool insideCell(int offset) =>
      cellSpans.any((s) => offset >= s.start && offset < s.end);
  bool walk(_HtmlNode node) {
    for (final c in node.children) {
      if (c.isText) continue;
      if (c.tag == 'td' || c.tag == 'th') {
        if (!c.closed) return false;
        continue; // 不钻进单元格内部
      }
      if (!c.closed) return false;
      if (!walk(c)) return false;
    }
    return true;
  }

  if (!walk(table)) return true;
  for (final s in strays) {
    if (s >= table.start && s < table.end && !insideCell(s)) return true;
  }
  return false;
}

/// 子树里是否含 table/div/p 元素（不含节点本身）。
bool _containsBlock(_HtmlNode node) {
  for (final c in node.children) {
    if (c.isText) continue;
    if (c.tag == 'table' || c.tag == 'div' || c.tag == 'p') return true;
    if (_containsBlock(c)) return true;
  }
  return false;
}

/// 子树里是否含 table 元素（不含节点本身）。
bool _containsTable(_HtmlNode node) {
  for (final c in node.children) {
    if (c.isText) continue;
    if (c.tag == 'table') return true;
    if (_containsTable(c)) return true;
  }
  return false;
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

/// 把占位符标识还原为原始源码（异常回退时代码占位符原样保留，T5-2）。
String _restorePlaceholders(
  String text,
  Map<String, _CodePlaceholder> byId,
) {
  var out = text;
  byId.forEach((id, ph) {
    if (out.contains(id)) out = out.replaceAll(id, ph.source);
  });
  return out;
}

/// 展平为纯文本：剥标签、保留文字，不丢字。
/// `<br>` → 换行；`<table>` 按 T5-4（同一行内单元格之间一个空格，
/// 行之间一个换行）展平；结构异常到无行的表按通用拼接展平，不丢字。
String _flattenText(
  _HtmlNode node,
  Map<String, _CodePlaceholder> byId,
) {
  if (node.isText) return _restorePlaceholders(node.text!, byId);
  if (node.tag == 'br') return '\n';
  if (node.tag == 'table') {
    final rows = _tableRows(node);
    var wellFormed = rows.isNotEmpty;
    if (wellFormed) {
      for (final c in node.children) {
        if (c.isText) {
          if (c.text!.trim().isNotEmpty) {
            wellFormed = false;
            break;
          }
        } else if (c.tag != 'tr' &&
            c.tag != 'thead' &&
            c.tag != 'tbody' &&
            c.tag != 'tfoot') {
          wellFormed = false;
          break;
        }
      }
    }
    if (wellFormed) {
      for (final r in rows) {
        for (final c in r.children) {
          if (c.isText && c.text!.trim().isNotEmpty) {
            wellFormed = false;
            break;
          }
        }
        if (!wellFormed) break;
      }
    }
    if (wellFormed) {
      return rows
          .map((r) => _rowCells(r).map((c) => _flattenText(c, byId)).join(' '))
          .join('\n');
    }
    final buf = StringBuffer();
    for (final c in node.children) {
      buf.write(_flattenText(c, byId));
    }
    return buf.toString();
  }
  final buf = StringBuffer();
  for (final c in node.children) {
    buf.write(_flattenText(c, byId));
  }
  return buf.toString();
}

/// 展平文本的空白规范化（U4-3/T7-3）：连续空白折叠为一个空格；
/// 换行保留为单个换行；块首尾空白去除；不得出现连续空行。
String _normalizeFlatText(String raw) {
  final lines = raw.split('\n');
  final kept = <String>[];
  for (final line in lines) {
    final folded = line
        .replaceAll(RegExp(r'[ \t\r\x0B\x0C\u3000]+'), ' ')
        .trim();
    if (folded.isNotEmpty) kept.add(folded);
  }
  return kept.join('\n');
}

// ---------------------------------------------------------------------------
// 行内切分与 token 化
// ---------------------------------------------------------------------------

/// 解析上下文：工作文本（步骤 ② 完成后的版本）、代码占位符、游离闭合标签。
class _ParseCtx {
  _ParseCtx({
    required this.working,
    required this.placeholders,
    required this.strays,
  }) : byId = {for (final p in placeholders) p.id: p};

  final String working;
  final List<_CodePlaceholder> placeholders;
  final Map<String, _CodePlaceholder> byId;
  final List<int> strays;
}

/// 行内样式（strong/b 粗体、em/i 斜体、sup/sub 上下标）。
class _Style {
  const _Style({this.bold = false, this.italic = false, this.script = 0});

  final bool bold;
  final bool italic;

  /// 0 普通，1 上标，-1 下标。
  final int script;

  _Style copyWith({bool? bold, bool? italic, int? script}) => _Style(
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    script: script ?? this.script,
  );
}

/// 行内切分结果：一段文本 / 一个公式 / 一个代码占位符。
/// [start]/[end] 是在被切字符串内的偏移。
sealed class _InlineSeg {
  const _InlineSeg(this.start, this.end);
  final int start;
  final int end;
}

class _SegText extends _InlineSeg {
  const _SegText(this.text, super.start, super.end);
  final String text;
}

class _SegFormula extends _InlineSeg {
  const _SegFormula(this.latex, this.displayMode, super.start, super.end);
  final String latex;
  final bool displayMode;
}

class _SegCode extends _InlineSeg {
  const _SegCode(this.ph, super.start, super.end);
  final _CodePlaceholder ph;
}

final _placeholderPattern = RegExp(r'\x00MUSE_PH_(\d+)\x00');

/// 把一段文本切成文本 / 公式 / 代码占位符（S3-1 步骤 2 的公式规则，
/// 与 [_scanFormulas] 同款：`\$` 字面、未闭合 `$` 字面、空公式丢弃、
/// 纯圈号公式段还原成文本；行内公式不跨行）。
List<_InlineSeg> _splitInline(
  String text,
  Map<String, _CodePlaceholder> byId,
) {
  final out = <_InlineSeg>[];
  final buf = StringBuffer();
  var segStart = 0;
  void flushText(int end) {
    if (buf.isNotEmpty) {
      out.add(_SegText(buf.toString(), segStart, end));
      buf.clear();
    }
  }

  var i = 0;
  while (i < text.length) {
    if (text.codeUnitAt(i) == 0) {
      final m = _placeholderPattern.matchAsPrefix(text, i);
      final ph = m == null ? null : byId[m.group(0)!];
      if (ph != null) {
        flushText(i);
        out.add(_SegCode(ph, i, m!.end));
        i = m.end;
        segStart = i;
        continue;
      }
      buf.write(text[i]);
      i++;
      continue;
    }
    if (text.startsWith(r'\$', i)) {
      buf.write(r'$');
      i += 2;
      continue;
    }
    if (text.startsWith(r'$$', i)) {
      final close = text.indexOf(r'$$', i + 2);
      if (close == -1) {
        buf.write(r'$$');
        i += 2;
        continue;
      }
      final latex = text.substring(i + 2, close).trim();
      if (latex.isEmpty) {
        i = close + 2;
        continue;
      }
      if (_isCircledLabel(latex)) {
        buf.write(latex);
      } else {
        flushText(i);
        out.add(_SegFormula(latex, true, i, close + 2));
      }
      i = close + 2;
      segStart = i;
      continue;
    }
    if (text[i] == r'$') {
      final close = _findInlineClose(text, i + 1);
      if (close == -1) {
        buf.write(r'$');
        i++;
        continue;
      }
      final latex = text.substring(i + 1, close).trim();
      if (latex.isEmpty) {
        i = close + 1;
        continue;
      }
      if (_isCircledLabel(latex)) {
        buf.write(latex);
      } else {
        flushText(i);
        out.add(_SegFormula(latex, false, i, close + 1));
      }
      i = close + 1;
      segStart = i;
      continue;
    }
    buf.write(text[i]);
    i++;
  }
  flushText(text.length);
  return out;
}

/// 组装用的 token。
sealed class _Tok {
  const _Tok();
}

/// 文本 token。[fold]：是否做空白折叠（元素内的文本折叠，根级纯文本不折，
/// 见 U4-3）。[tainted]：来自未闭合行内元素的文本（所在段落须回退展平）。
class _TextTok extends _Tok {
  const _TextTok(
    this.text,
    this.style, {
    required this.fold,
    required this.start,
    required this.end,
    this.tainted = false,
  });

  final String text;
  final _Style style;
  final bool fold;
  final int start;
  final int end;
  final bool tainted;
}

class _FormulaTok extends _Tok {
  const _FormulaTok(
    this.latex,
    this.displayMode, {
    required this.start,
    required this.end,
    this.tainted = false,
    this.fold = false,
  });

  final String latex;
  final bool displayMode;
  final int start;
  final int end;
  final bool tainted;
  final bool fold;
}

class _CodeTok extends _Tok {
  const _CodeTok(this.ph, {required this.start, required this.end});

  final _CodePlaceholder ph;
  final int start;
  final int end;
}

class _BrTok extends _Tok {
  const _BrTok({required this.start, required this.end});
  final int start;
  final int end;
}

/// 块级元素 token（table/div/p/未知块级容器），由组装阶段处理。
class _BlockTok extends _Tok {
  const _BlockTok(this.node);
  final _HtmlNode node;
}

/// 标题标记（预处理阶段在行首 `#{1,3} ` 处插入，`#` 本身已被消费）。
class _HeadingMarkTok extends _Tok {
  const _HeadingMarkTok(this.level);
  final int level;
}

/// 把节点列表 token 化（行内元素递归进样式，块级元素产出 [_BlockTok]）。
/// [fold]：直接文本子节点是否折叠空白（元素内为 true，根级为 false）。
/// [tainted]：当前子树位于未闭合行内元素内（其文本 token 标记 tainted）。
List<_Tok> _tokenizeNodes(
  List<_HtmlNode> nodes,
  _Style style,
  _ParseCtx ctx,
  List<_Tok> out, {
  required bool fold,
  bool tainted = false,
}) {
  for (final node in nodes) {
    _tokenizeNode(node, style, ctx, out, fold: fold, tainted: tainted);
  }
  return out;
}

void _tokenizeNode(
  _HtmlNode node,
  _Style style,
  _ParseCtx ctx,
  List<_Tok> out, {
  required bool fold,
  required bool tainted,
}) {
  if (node.isText) {
    for (final seg in _splitInline(node.text!, ctx.byId)) {
      switch (seg) {
        case _SegText(:final text, :final start, :final end):
          out.add(
            _TextTok(
              text,
              style,
              fold: fold,
              start: node.start + start,
              end: node.start + end,
              tainted: tainted,
            ),
          );
        case _SegFormula(
          :final latex,
          :final displayMode,
          :final start,
          :final end,
        ):
          out.add(
            _FormulaTok(
              latex,
              displayMode,
              start: node.start + start,
              end: node.start + end,
              tainted: tainted,
              fold: fold,
            ),
          );
        case _SegCode(:final ph, :final start, :final end):
          if (ph.fenced) {
            out.add(
              _CodeTok(ph, start: node.start + start, end: node.start + end),
            );
          } else {
            // 行内代码：按字面文本保留（含反引号），不折叠空白。
            out.add(
              _TextTok(
                ph.source,
                style,
                fold: false,
                start: node.start + start,
                end: node.start + end,
                tainted: tainted,
              ),
            );
          }
      }
    }
    return;
  }
  switch (node.tag) {
    case 'br':
      out.add(_BrTok(start: node.start, end: node.end));
    case 'table':
    case 'div':
    case 'p':
      out.add(_BlockTok(node));
    case 'strong':
    case 'b':
    case 'em':
    case 'i':
    case 'sup':
    case 'sub':
    case 'span':
      final next = switch (node.tag) {
        'strong' || 'b' => style.copyWith(bold: true),
        'em' || 'i' => style.copyWith(italic: true),
        'sup' => style.copyWith(script: 1),
        'sub' => style.copyWith(script: -1),
        _ => style,
      };
      _tokenizeNodes(
        node.children,
        next,
        ctx,
        out,
        fold: true,
        tainted: tainted || !node.closed,
      );
    default:
      // 其余标签：含 table/div/p 后代时当块级容器，否则剥标签、保留文字。
      // （未知标签不是错误，不报错；<pre>/<code> 同款处理，见 T5-3。）
      if (_containsBlock(node)) {
        out.add(_BlockTok(node));
      } else {
        _tokenizeNodes(
          node.children,
          style,
          ctx,
          out,
          fold: true,
          tainted: tainted || !node.closed,
        );
      }
  }
}

/// 在 [text] 中从 [from] 起找下一个行首标题起点。
/// 返回（# 起始下标，级数，标题内容起始下标），无则 null。
/// 行首 = 串首（且 [lineStartAtFrom]）或前一字符为 `\n`；
/// `#` 须为 1–3 个且后跟空格/制表符（`####` 不成标题）。
(int, int, int)? _nextHeading(
  String text,
  int from,
  bool lineStartAtFrom,
) {
  var i = from;
  while (i < text.length) {
    if (text[i] == '#') {
      final atLineStart =
          (i == 0 && lineStartAtFrom) ||
          (i > 0 && text[i - 1] == '\n');
      if (atLineStart) {
        var j = i;
        while (j < text.length && text[j] == '#') {
          j++;
        }
        final level = j - i;
        if (level >= 1 &&
            level <= 3 &&
            j < text.length &&
            (text[j] == ' ' || text[j] == '\t')) {
          return (i, level, j + 1);
        }
        i = j;
        continue;
      }
    }
    i++;
  }
  return null;
}

/// 标题预处理：在行首 `#{1,3} ` 处切分文本 token、插入 [_HeadingMarkTok]。
/// [initialLineStart]：首个 token 起始处是否位于行首（由工作文本判定：
/// 文首，或前一字符为换行）。`<br>` 不构成行首（须字面换行）。
List<_Tok> _markHeadings(List<_Tok> tokens, bool initialLineStart) {
  final out = <_Tok>[];
  var lineStart = initialLineStart;
  for (final tok in tokens) {
    if (tok is _TextTok) {
      final text = tok.text;
      var cursor = 0;
      var ls = lineStart;
      while (true) {
        final h = _nextHeading(text, cursor, cursor == 0 && ls);
        if (h == null) break;
        if (h.$1 > cursor) {
          out.add(
            _TextTok(
              text.substring(cursor, h.$1),
              tok.style,
              fold: tok.fold,
              start: tok.start + cursor,
              end: tok.start + h.$1,
              tainted: tok.tainted,
            ),
          );
        }
        out.add(_HeadingMarkTok(h.$2));
        cursor = h.$3;
        ls = false;
      }
      if (cursor < text.length) {
        out.add(
          _TextTok(
            text.substring(cursor),
            tok.style,
            fold: tok.fold,
            start: tok.start + cursor,
            end: tok.end,
            tainted: tok.tainted,
          ),
        );
      }
      lineStart = text.endsWith('\n');
    } else {
      out.add(tok);
      lineStart = false;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// 块组装
// ---------------------------------------------------------------------------

/// 段落累积中的一部分：一段文本 run / 一个行内公式。
sealed class _Part {
  const _Part();
}

class _PartText extends _Part {
  const _PartText(this.run);
  final TextRun run;
}

class _PartFormula extends _Part {
  const _PartFormula(this.latex);
  final String latex;
}

/// 把节点列表组装成内容段。
/// [fold]：直接文本子节点是否折叠空白（元素内 true，根级 false）。
/// [allowHeadings]：是否识别行首标题（单元格内为 false，标题是块级语法，
/// 单元格只做行内解析）。
/// [centered]：是否处于 `<div align="center">` 内（表格继承居中）。
List<QuestionContentBlock> _assembleBlocks(
  List<_HtmlNode> nodes,
  _ParseCtx ctx, {
  required bool centered,
  required bool fold,
  bool allowHeadings = true,
}) {
  final initialLineStart = nodes.isEmpty
      ? true
      : nodes.first.start == 0 ||
            ctx.working[nodes.first.start - 1] == '\n';
  final rawTokens = _tokenizeNodes(
    nodes,
    const _Style(),
    ctx,
    <_Tok>[],
    fold: fold,
  );
  final tokens = allowHeadings
      ? _markHeadings(rawTokens, initialLineStart)
      : rawTokens;

  final blocks = <QuestionContentBlock>[];
  final parts = <_Part>[];
  var paraFailed = false;
  var paraHasElement = false;
  var spanStart = -1;
  var spanEnd = -1;

  void noteSpan(int start, int end) {
    if (spanStart < 0 || start < spanStart) spanStart = start;
    if (end > spanEnd) spanEnd = end;
  }

  void appendText(String text, _Style style) {
    if (text.isEmpty) return;
    if (parts.isNotEmpty && parts.last is _PartText) {
      final last = (parts.last as _PartText).run;
      if (last.bold == style.bold &&
          last.italic == style.italic &&
          last.script == style.script) {
        parts[parts.length - 1] = _PartText(
          TextRun(
            last.text + text,
            bold: style.bold,
            italic: style.italic,
            script: style.script,
          ),
        );
        return;
      }
    }
    parts.add(
      _PartText(
        TextRun(
          text,
          bold: style.bold,
          italic: style.italic,
          script: style.script,
        ),
      ),
    );
  }

  /// 去一段 TextBlock 一侧的空白；空了返回 null。
  TextBlock? trimTextBlock(
    TextBlock block, {
    required bool left,
    required bool right,
  }) {
    final runs = block.runs;
    if (runs == null) {
      var text = block.text;
      if (left) text = text.trimLeft();
      if (right) text = text.trimRight();
      return text.isEmpty ? null : TextBlock(text);
    }
    final rs = List<TextRun>.of(runs);
    if (left && rs.isNotEmpty) {
      final first = rs.first;
      final t = first.text.trimLeft();
      if (t.isEmpty) {
        rs.removeAt(0);
      } else {
        rs[0] = TextRun(
          t,
          bold: first.bold,
          italic: first.italic,
          script: first.script,
        );
      }
    }
    if (right && rs.isNotEmpty) {
      final last = rs.last;
      final t = last.text.trimRight();
      if (t.isEmpty) {
        rs.removeLast();
      } else {
        rs[rs.length - 1] = TextRun(
          t,
          bold: last.bold,
          italic: last.italic,
          script: last.script,
        );
      }
    }
    if (rs.isEmpty) return null;
    final text = rs.map((r) => r.text).join();
    if (text.isEmpty) return null;
    final hasStyle = rs.any((r) => r.bold || r.italic || r.script != 0);
    return TextBlock(text, runs: hasStyle ? rs : null);
  }

  void flushParagraph() {
    if (parts.isEmpty) {
      paraFailed = false;
      paraHasElement = false;
      spanStart = -1;
      spanEnd = -1;
      return;
    }
    var failed = paraFailed;
    if (!failed && spanStart >= 0) {
      for (final s in ctx.strays) {
        if (s >= spanStart && s < spanEnd) {
          failed = true;
          break;
        }
      }
    }
    if (failed) {
      // 回退：整段展平成纯文本（不丢字；公式还原成 `$…$` 源码形式）。
      final buf = StringBuffer();
      for (final p in parts) {
        switch (p) {
          case _PartText(:final run):
            buf.write(run.text);
          case _PartFormula(:final latex):
            buf.write('\$$latex\$');
        }
      }
      final flat = _normalizeFlatText(buf.toString());
      if (flat.isNotEmpty) blocks.add(TextBlock(flat));
    } else {
      final out = <QuestionContentBlock>[];
      var runs = <TextRun>[];
      void flushRuns() {
        if (runs.isEmpty) return;
        final text = runs.map((r) => r.text).join();
        final hasStyle = runs.any((r) => r.bold || r.italic || r.script != 0);
        out.add(
          TextBlock(text, runs: hasStyle ? List<TextRun>.of(runs) : null),
        );
        runs = <TextRun>[];
      }

      for (final p in parts) {
        switch (p) {
          case _PartText(:final run):
            runs.add(run);
          case _PartFormula(:final latex):
            flushRuns();
            out.add(FormulaBlock(latex));
        }
      }
      flushRuns();
      // 块首尾空白去除（仅含 HTML 元素的段落；纯文本段落保持原样，
      // 以免改变既有纯 Markdown 的解析结果）。
      if (paraHasElement && out.isNotEmpty) {
        if (out.first is TextBlock) {
          final t = trimTextBlock(
            out.first as TextBlock,
            left: true,
            right: false,
          );
          if (t == null) {
            out.removeAt(0);
          } else {
            out[0] = t;
          }
        }
        if (out.isNotEmpty && out.last is TextBlock) {
          final t = trimTextBlock(
            out.last as TextBlock,
            left: false,
            right: true,
          );
          if (t == null) {
            out.removeLast();
          } else {
            out[out.length - 1] = t;
          }
        }
      }
      // 纯空白段落丢弃（无公式且全文空白）。
      final hasFormula = out.any((b) => b is FormulaBlock);
      final allText = out.whereType<TextBlock>().map((b) => b.text).join();
      if (hasFormula || allText.trim().isNotEmpty) {
        blocks.addAll(out);
      }
    }
    parts.clear();
    paraFailed = false;
    paraHasElement = false;
    spanStart = -1;
    spanEnd = -1;
  }

  var idx = 0;
  while (idx < tokens.length) {
    final tok = tokens[idx];
    switch (tok) {
      case _TextTok(
        :final text,
        :final style,
        :final fold,
        :final start,
        :final end,
        :final tainted,
      ):
        if (tainted) paraFailed = true;
        if (fold) paraHasElement = true;
        noteSpan(start, end);
        appendText(_foldText(text, fold), style);
        idx++;
      case _FormulaTok(
        :final latex,
        :final displayMode,
        :final start,
        :final end,
        :final tainted,
        :final fold,
      ):
        if (tainted) paraFailed = true;
        if (fold) paraHasElement = true;
        noteSpan(start, end);
        if (displayMode) {
          flushParagraph();
          blocks.add(FormulaBlock(latex, displayMode: true));
        } else {
          parts.add(_PartFormula(latex));
        }
        idx++;
      case _CodeTok(:final ph):
        flushParagraph();
        blocks.add(CodeBlock(ph.code ?? '', language: ph.language));
        idx++;
      case _BrTok(:final start, :final end):
        paraHasElement = true;
        noteSpan(start, end);
        appendText('\n', const _Style());
        idx++;
      case _BlockTok(:final node):
        flushParagraph();
        _processBlock(node, ctx, blocks, centered: centered);
        idx++;
      case _HeadingMarkTok(:final level):
        // 向前看收集标题行内容：直到换行、块、代码或独立公式为止。
        final buf = StringBuffer();
        var j = idx + 1;
        while (j < tokens.length) {
          final t = tokens[j];
          if (t is _TextTok) {
            final nl = t.text.indexOf('\n');
            if (nl == -1) {
              buf.write(t.text);
              j++;
              continue;
            }
            buf.write(t.text.substring(0, nl));
            final rest = t.text.substring(nl + 1);
            if (rest.isEmpty) {
              tokens.removeAt(j);
            } else {
              tokens[j] = _TextTok(
                rest,
                t.style,
                fold: t.fold,
                start: t.start + nl + 1,
                end: t.end,
                tainted: t.tainted,
              );
            }
            break;
          } else if (t is _FormulaTok && !t.displayMode) {
            buf.write('\$${t.latex}\$');
            j++;
            continue;
          } else {
            break;
          }
        }
        final headingText = buf.toString().trim();
        if (headingText.isEmpty) {
          // 空标题：`## ` 按字面文本处理。
          appendText('#' * level + ' ', const _Style());
          idx++;
        } else {
          tokens.removeRange(idx + 1, j);
          flushParagraph();
          blocks.add(HeadingBlock(headingText, level));
          idx = idx + 1;
        }
    }
  }
  flushParagraph();
  return blocks;
}

/// 文本 token 的空白折叠（U4-3）：连续空白折叠为一个空格。
/// 只对元素内的文本做；根级纯文本保持原样。
String _foldText(String text, bool fold) {
  if (!fold) return text;
  return text.replaceAll(RegExp(r'[ \t\r\x0B\x0C\u3000\n]+'), ' ');
}

/// 处理一个块级元素节点，产物追加到 [blocks]。
void _processBlock(
  _HtmlNode node,
  _ParseCtx ctx,
  List<QuestionContentBlock> blocks, {
  required bool centered,
}) {
  switch (node.tag) {
    case 'table':
      final table = _convertTable(node, ctx, centered: centered);
      if (table != null) {
        blocks.add(table);
        return;
      }
      final flat = _normalizeFlatText(_flattenText(node, ctx.byId));
      if (flat.isNotEmpty) blocks.add(TextBlock(flat));
    case 'div':
      if (_nodeFailedOutsideTables(node, ctx.strays)) {
        final flat = _normalizeFlatText(_flattenText(node, ctx.byId));
        if (flat.isNotEmpty) blocks.add(TextBlock(flat));
        return;
      }
      final childCentered =
          centered || node.attrs['align']?.trim().toLowerCase() == 'center';
      blocks.addAll(
        _assembleBlocks(
          node.children,
          ctx,
          centered: childCentered,
          fold: true,
        ),
      );
    case 'p':
      if (_nodeFailedOutsideTables(node, ctx.strays) ||
          _containsBlock(node)) {
        final flat = _normalizeFlatText(_flattenText(node, ctx.byId));
        if (flat.isNotEmpty) blocks.add(TextBlock(flat));
        return;
      }
      blocks.addAll(
        _assembleBlocks(node.children, ctx, centered: centered, fold: true),
      );
    default:
      // 未知块级容器（section/center 等）：与 div 同款处理。
      if (_nodeFailedOutsideTables(node, ctx.strays)) {
        final flat = _normalizeFlatText(_flattenText(node, ctx.byId));
        if (flat.isNotEmpty) blocks.add(TextBlock(flat));
        return;
      }
      blocks.addAll(
        _assembleBlocks(
          node.children,
          ctx,
          centered: centered,
          fold: true,
        ),
      );
  }
}

/// 某行是否结构合法：元素子节点只能是 td/th；直接文字须全为空白。
bool _rowStructureOk(_HtmlNode tr) {
  for (final c in tr.children) {
    if (c.isText) {
      if (c.text!.trim().isNotEmpty) return false;
      continue;
    }
    if (c.tag != 'td' && c.tag != 'th') return false;
  }
  return true;
}

/// colspan/rowspan 属性：正整数，默认 1；非法值 → 1（T7-1）。
int _spanAttr(_HtmlNode cell, String name) {
  final raw = cell.attrs[name]?.trim();
  if (raw == null) return 1;
  final v = int.tryParse(raw);
  if (v == null || v < 1) return 1;
  return v;
}

/// 单元格内容解析（R4-1 富内容模型）。
/// 嵌套 <table>（T5-5）或解析失败时，整个单元格展平成纯文本，
/// 不进入通用 children 递归解析器。
List<QuestionContentBlock> _cellChildren(_HtmlNode cell, _ParseCtx ctx) {
  if (_containsTable(cell) || _nodeFailed(cell, ctx.strays)) {
    final flat = _normalizeFlatText(_flattenText(cell, ctx.byId));
    return flat.isEmpty ? const [] : [TextBlock(flat)];
  }
  return _assembleBlocks(
    cell.children,
    ctx,
    centered: false,
    fold: true,
    allowHeadings: false,
  );
}

/// 表格转换：失败（结构异常/未闭合）返回 null，调用方整表回退为纯文本。
/// 成功时返回按 colspan/rowspan 展开的等长矩形网格（内容放首格，余格留空）。
TableBlock? _convertTable(
  _HtmlNode table,
  _ParseCtx ctx, {
  required bool centered,
}) {
  if (_tableFailed(table, ctx.strays)) return null;
  for (final child in table.children) {
    if (child.isText) {
      if (child.text!.trim().isNotEmpty) return null;
      continue;
    }
    if (child.tag == 'tr') {
      if (!_rowStructureOk(child)) return null;
      continue;
    }
    if (child.tag == 'thead' ||
        child.tag == 'tbody' ||
        child.tag == 'tfoot') {
      for (final g in child.children) {
        if (g.isText) {
          if (g.text!.trim().isNotEmpty) return null;
          continue;
        }
        if (g.tag != 'tr' || !_rowStructureOk(g)) return null;
      }
      continue;
    }
    return null;
  }
  final rows = _tableRows(table);
  if (rows.isEmpty) return TableBlock(const [], centered: centered);
  const emptyCell = TableCell(children: []);
  final grid = <List<TableCell>>[];
  final spanLeft = <int>[];
  for (final tr in rows) {
    final cells = _rowCells(tr);
    final rowOut = <TableCell>[];
    final consumed = <int>{};
    var col = 0;
    void ensureCol(int c) {
      while (spanLeft.length <= c) {
        spanLeft.add(0);
      }
    }

    for (final cellNode in cells) {
      while (col < spanLeft.length && spanLeft[col] > 0) {
        rowOut.add(emptyCell);
        consumed.add(col);
        col++;
      }
      final cs = _spanAttr(cellNode, 'colspan');
      final rs = _spanAttr(cellNode, 'rowspan');
      rowOut.add(
        TableCell(
          children: _cellChildren(cellNode, ctx),
          colspan: cs,
          rowspan: rs,
        ),
      );
      for (var k = 1; k < cs; k++) {
        rowOut.add(emptyCell);
      }
      for (var k = 0; k < cs; k++) {
        ensureCol(col + k);
        if (rs > 1) spanLeft[col + k] = rs - 1;
      }
      col += cs;
    }
    while (col < spanLeft.length && spanLeft[col] > 0) {
      rowOut.add(emptyCell);
      consumed.add(col);
      col++;
    }
    for (final c in consumed) {
      spanLeft[c]--;
    }
    grid.add(rowOut);
  }
  var maxWidth = 0;
  for (final r in grid) {
    if (r.length > maxWidth) maxWidth = r.length;
  }
  for (final r in grid) {
    while (r.length < maxWidth) {
      r.add(emptyCell);
    }
  }
  return TableBlock(grid, centered: centered);
}
