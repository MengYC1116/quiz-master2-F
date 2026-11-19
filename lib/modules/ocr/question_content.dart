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

/// 题目内容的一段。sealed：M5 穷举分发，新增段类型编译期可发现。
sealed class QuestionContentBlock {
  const QuestionContentBlock();
}

/// 普通文字段（中文 / 英文 / 已转圈号字符 ①②③④ 等）。
class TextBlock extends QuestionContentBlock {
  const TextBlock(this.text);
  final String text;
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
/// 时位置未确认，界面必须明确标注（绝不静默当成已确认顺序展示）。
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
///
/// - 先做圈号预处理（见 [preprocessCircledNumbers]）。
/// - ```` ``` ```` 围栏代码块优先于公式定界符：代码里的 `$` 不切公式。
/// - `\$` 是转义美元符，不切公式。
/// - 公式内首尾空白去掉（GLM 常输出 `$ 4 x^{2}... $` 这种带空格形式）。
/// - 空公式（`$ $` / `$$ $$`）直接丢弃，不产生空段。
/// - 相邻 TextBlock 合并；全空输入返回空列表。
/// - 注意：本函数只切段，不校验 LaTeX 合法性；非法公式由渲染层
///   [FormulaView] 在 build 时捕获并换成 [ImageFallbackBlock]。
List<QuestionContentBlock> parseQuestionContent(String markdown) {
  final input = preprocessCircledNumbers(markdown);
  final blocks = <QuestionContentBlock>[];
  var i = 0;

  void addText(String text) {
    if (text.isEmpty) return;
    final last = blocks.isEmpty ? null : blocks.last;
    if (last is TextBlock) {
      blocks[blocks.length - 1] = TextBlock(last.text + text);
    } else {
      blocks.add(TextBlock(text));
    }
  }

  while (i < input.length) {
    // 1. 围栏代码块 ```lang\n...\n```：整段当 CodeBlock。
    if (input.startsWith('```', i)) {
      final fenceEnd = input.indexOf('\n', i + 3);
      final language = fenceEnd == -1
          ? input.substring(i + 3).trim()
          : input.substring(i + 3, fenceEnd).trim();
      final close = input.indexOf('```', fenceEnd == -1 ? i + 3 : fenceEnd);
      if (close == -1) {
        // 无闭合围栏：剩余全部按代码处理，不再切公式。
        addText(input.substring(i));
        break;
      }
      final codeStart = fenceEnd == -1 ? i + 3 : fenceEnd + 1;
      blocks.add(CodeBlock(
        input.substring(codeStart, close),
        language: language.isEmpty ? null : language,
      ));
      i = close + 3;
      continue;
    }

    // 2. 转义美元符 \$：当普通字符并入文本。
    if (input.startsWith(r'\$', i)) {
      addText(r'$');
      i += 2;
      continue;
    }

    // 3. 独立公式 $$...$$。
    if (input.startsWith(r'$$', i)) {
      final close = input.indexOf(r'$$', i + 2);
      if (close == -1) {
        addText(input.substring(i));
        break;
      }
      final latex = input.substring(i + 2, close).trim();
      if (latex.isNotEmpty) {
        if (_isCircledLabel(latex)) {
          addText(latex);
        } else {
          blocks.add(FormulaBlock(latex, displayMode: true));
        }
      }
      i = close + 2;
      continue;
    }

    // 4. 行内公式 $...$。
    if (input[i] == r'$') {
      final close = _findInlineClose(input, i + 1);
      if (close == -1) {
        addText(input.substring(i));
        break;
      }
      final latex = input.substring(i + 1, close).trim();
      if (latex.isNotEmpty) {
        if (_isCircledLabel(latex)) {
          addText(latex);
        } else {
          blocks.add(FormulaBlock(latex));
        }
      }
      i = close + 1;
      continue;
    }

    // 5. 普通文本：推进到下一个可能的分界点。
    var next = i + 1;
    while (next < input.length) {
      if (input.startsWith('```', next) ||
          input.startsWith(r'\$', next) ||
          input.startsWith(r'$$', next) ||
          input[next] == r'$') {
        break;
      }
      next++;
    }
    addText(input.substring(i, next));
    i = next;
  }

  return blocks;
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
/// - TextBlock：原样拼回；FormulaBlock：行内 `$...$`、独立 `$$...$$`；
/// - CodeBlock：围栏 ```lang\n...\n```（语言为空时不写语言名）；
/// - ImageFallbackBlock：不拼（恢复为原图的公式在保存时从题干里拿掉，
///   以原图显示；原始公式仍在 ocr_raw 的 md_results 里，不丢）。
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
    }
  }
  return buf.toString();
}
