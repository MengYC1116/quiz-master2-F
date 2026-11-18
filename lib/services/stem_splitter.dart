// M4（十三批）：题干切分——纯文本保守启发式。
//
// 输入是 GLM-OCR 返回的原始 Markdown 文本（`md_results`），输出切分后
// 的题干 + 切分状态。只做一件事：用选项标记（A–E）当切分边界，把题干
// 和选项分开；选项部分丢弃（原始 OCR 文本由调用方另存，不在这里丢）。
//
// 保守策略（GPT 评审 §1.3 + D-106）：宁可保留选项，也不要误删题干。
// 只有同时满足以下条件才切：
//   1. 找到 A 标记，且其后出现 B 标记；
//   2. A、B 格式一致（同为 `A.` / `A、` / `A)` / `(A)` 其中一类，
//      全角半角不区分，全角字母 Ａ–Ｅ 视为 A–E）；
//   3. 每个标记后都有实际选项内容（不是空标记、也不是下一个标记）；
//   4. A 处于选项起始位置（行首，或 ≥2 空格的栏位间隔，或括号式
//      `(A)` 前有空白）；行文中单空格后的 `A.`（如“集合 A，且 A. B …”）
//      不算候选；
//   5. B 与 A 位置合理：B 在 A 所在行或之后 2 行内出现（远在数段之后
//      的 A、B 句子对不算选项序列）。
// C、D、E 出现是更强证据，但不是必要条件（只有 A、B 也切；医学常 5 选项）。
//
// 不切的情况：只出现 A；A、B 格式不一致；B 后无内容；出现多个候选切
// 分点（标“存在歧义”，不随便选第一个）；完全没选项标记（填空、解答、
// 非选择题整段当题干）。①②③④、(1)(2) 小问、( ) 答题空不参与切分。
// 开头题号不盲删：“1.” 可能是题干里的数学序号，留着。
//
// 这只是用选项标记当切分边界，不是“用 A/B/C/D 判题型”（该方案已被
// Meng 否决），本文件不含任何题型判断。
//
// 纯函数：无 UI、无网络、无数据库依赖，不读 layout bbox。GLM 的
// `layout_details` bbox 只做辅助信号，见文件末尾的说明；本版接口
// 不为它留参数——以后要接时由调用方在调 [splitStem] 之前按 bbox
// 重排/过滤文本即可，签名不用改。
//
// 类型定义只在一处：[StemSplitStatus] 与 [StemSplitResult] 都在本文件，
// M3（存储）与 M5（纠错编辑器）直接 import 本文件复用。

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
  });

  /// 切分后的题干。自动切分时是 A 标记之前的文本（去首尾空白，题号保留）；
  /// 未切分 / 存在歧义时是整段原文（去首尾空白），内容一句不丢。
  final String stemText;

  /// 切分状态，见 [StemSplitStatus]。
  final StemSplitStatus status;

  /// 切分位置：原始 OCR 文本中的字符下标，指向 A 标记的首字符。
  /// 未切分 / 存在歧义时为 null。
  final int? cutIndex;

  /// 简短说明：切了说明切的证据（序列 + 格式），没切说明哪条规则没守住。
  final String reason;
}

/// 选项标记的格式类。同一序列里的 A、B 必须同类（全角半角不区分）。
enum _MarkerFormat {
  /// `A.` / `A．`（句点）。
  dot,

  /// `A、`（顿号）。
  dun,

  /// `A)` / `A）`（右括号）。
  parenClose,

  /// `(A)` / `（A）`（左右括号）。
  paren,
}

/// 文本中扫到的一个选项标记。
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

  /// 在原文中的起始下标（含左括号，如 `(A)` 的 `(` 处）。
  final int start;

  /// 在原文中的结束下标（不含）。
  final int end;

  /// 匹配到的原文片段（如 `A.` / `(A)` / `Ａ．`）。
  final String text;
}

/// 选项标记正则：括号式优先（避免 `(A)` 被拆成 `A)`），再是后缀式。
/// 只认大写 A–E（含全角 Ａ–Ｅ），小写 a–e 不认（多为句中缩写）。
final _markerPattern = RegExp(
  r'[(（]\s*[A-EＡ-Ｅ]\s*[)）]|[A-EＡ-Ｅ][.．、)）]',
);

/// B 相对 A 的最远距离：B 标记须在 A 所在行或之后 2 行内。
/// 选项换行、A 项内容折行都覆盖得到；远在数段之后的 A、B 句子对不算。
const _maxLinesBetweenAAndB = 2;

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

  final markers = _scanMarkers(text);
  final aMarkers = markers.where((m) => m.letter == 'A').toList();
  if (aMarkers.isEmpty) {
    return StemSplitResult(
      stemText: text.trim(),
      status: StemSplitStatus.notSplit,
      cutIndex: null,
      reason: '未发现选项标记，整段保留为题干',
    );
  }

  // 逐个验证 A 候选：强边界 + 有内容 + 其后有同格式、有内容的 B。
  final candidates = <_Marker>[];
  String? firstFailure;
  for (final a in aMarkers) {
    final failure = _validateA(text, markers, a);
    if (failure == null) {
      candidates.add(a);
    } else {
      firstFailure ??= failure;
    }
  }

  if (candidates.length > 1) {
    return StemSplitResult(
      stemText: text.trim(),
      status: StemSplitStatus.ambiguous,
      cutIndex: null,
      reason: '发现 ${candidates.length} 个候选切分点，不自动选择',
    );
  }
  if (candidates.isEmpty) {
    return StemSplitResult(
      stemText: text.trim(),
      status: StemSplitStatus.notSplit,
      cutIndex: null,
      reason: firstFailure ?? '未发现可信的选项序列，不切分',
    );
  }

  final a = candidates.single;
  final optionTexts = _optionSequenceTexts(text, markers, a);
  return StemSplitResult(
    stemText: text.substring(0, a.start).trim(),
    status: StemSplitStatus.autoSplit,
    cutIndex: a.start,
    reason: '选项序列 ${optionTexts.join(' ')} 格式一致，自 A 处切分',
  );
}

/// 扫出全部选项标记并归一化字母（全角 Ａ–Ｅ → 半角 A–E）。
List<_Marker> _scanMarkers(String text) {
  final out = <_Marker>[];
  for (final m in _markerPattern.allMatches(text)) {
    final raw = m.group(0)!;
    final letterCode = raw.codeUnits.firstWhere(
      (c) => (c >= 0x41 && c <= 0x45) || (c >= 0xFF21 && c <= 0xFF25),
    );
    final letter = String.fromCharCode(
      letterCode >= 0xFF21 ? letterCode - 0xFF21 + 0x41 : letterCode,
    );
    final _MarkerFormat format;
    if (raw.startsWith('(') || raw.startsWith('（')) {
      format = _MarkerFormat.paren;
    } else if (raw.endsWith('.') || raw.endsWith('．')) {
      format = _MarkerFormat.dot;
    } else if (raw.endsWith('、')) {
      format = _MarkerFormat.dun;
    } else {
      format = _MarkerFormat.parenClose;
    }
    out.add(
      _Marker(
        letter: letter,
        format: format,
        start: m.start,
        end: m.end,
        text: raw,
      ),
    );
  }
  return out;
}

/// 验证一个 A 标记是否可信：返回 null 表示通过，否则返回没守住的规则。
String? _validateA(String text, List<_Marker> markers, _Marker a) {
  if (!_isOptionStart(text, a)) {
    return 'A 标记不在选项起始位置，不切分';
  }
  if (!_hasRealContent(text, a.end)) {
    return 'A 标记后无实际选项内容，不切分';
  }
  final aIndex = markers.indexOf(a);
  if (aIndex + 1 >= markers.length) {
    return '仅发现 A 标记，未见 B，不切分';
  }
  final next = markers[aIndex + 1];
  if (next.letter != 'B') {
    return 'A 之后未见 B 标记，不切分';
  }
  if (next.format != a.format) {
    return 'A、B 标记格式不一致，不切分';
  }
  if (!_isWeakBoundary(text, next.start)) {
    return 'B 标记位置不合理，不切分';
  }
  if (_linesBetween(text, a.end, next.start) > _maxLinesBetweenAAndB) {
    return 'B 标记离 A 过远，不切分';
  }
  if (!_hasRealContent(text, next.end)) {
    return 'B 标记后无实际选项内容，不切分';
  }
  return null;
}

/// A 候选的强边界：行首，或 ≥2 空格/制表符的栏位间隔，或括号式
/// `(A)` 前有空白。行文中单空格后的 `A.`（如“集合 A，且 A. B …”）
/// 不算，避免把题干里的句子误当选项。
bool _isOptionStart(String text, _Marker marker) {
  if (_isLineStart(text, marker.start)) {
    return true;
  }
  // 行内：往前数连续空白（空格/制表符/全角空格）。
  var i = marker.start - 1;
  var run = 0;
  var hasTab = false;
  while (i >= 0 && _isBlank(text.codeUnitAt(i))) {
    if (text.codeUnitAt(i) == 0x09) {
      hasTab = true;
    }
    run++;
    i--;
  }
  if (run >= 2 || hasTab) {
    return true;
  }
  // 括号式 `(A)` 在行文中极少是普通文字，单空格前也认。
  if (marker.format == _MarkerFormat.paren &&
      marker.start > 0 &&
      _isSpace(text.codeUnitAt(marker.start - 1))) {
    return true;
  }
  return false;
}

/// 后续标记（B/C/D/E）的弱边界：文本开头，或前面是空白。
bool _isWeakBoundary(String text, int start) {
  return start == 0 || _isSpace(text.codeUnitAt(start - 1));
}

/// 是否行首：从行首到 [start] 之间只有空白（空格/制表符/回车/全角空格）。
bool _isLineStart(String text, int start) {
  var i = start - 1;
  while (i >= 0) {
    final c = text.codeUnitAt(i);
    if (c == 0x0A) {
      return true;
    }
    if (!_isBlank(c)) {
      return false;
    }
    i--;
  }
  return true;
}

/// 标记后是否有实际选项内容：跳过空白后，须有字（字母/数字/中文/公式
/// `$` 等），且不能是下一个选项标记、也不能只剩标点。`A. B. C. …`
/// 这种连排标记会被这条拦住（B 的“内容”是 C 标记，不算内容）。
bool _hasRealContent(String text, int from) {
  var i = from;
  while (i < text.length && _isSpace(text.codeUnitAt(i))) {
    i++;
  }
  if (i >= text.length) {
    return false;
  }
  if (_markerPattern.matchAsPrefix(text, i) != null) {
    return false;
  }
  final c = text.codeUnitAt(i);
  // 句末/分隔标点不算内容。
  const noContent = '.,;:!?，。；：、）)）';
  if (noContent.contains(String.fromCharCode(c))) {
    return false;
  }
  return true;
}

/// [from] 到 [to] 之间的换行数（衡量 A、B 相隔几行）。
int _linesBetween(String text, int from, int to) {
  var n = 0;
  for (var i = from; i < to && i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) {
      n++;
    }
  }
  return n;
}

/// 收集切分证据：A 起按字母顺序连续出现的同格式标记文本
///（如 `A. B. C. D.`；C/D/E 缺失不影响切分，只影响 reason 的写法）。
List<String> _optionSequenceTexts(
  String text,
  List<_Marker> markers,
  _Marker a,
) {
  final out = <String>[a.text];
  const expected = ['B', 'C', 'D', 'E'];
  var aIndex = markers.indexOf(a);
  for (final letter in expected) {
    if (aIndex + 1 >= markers.length) {
      break;
    }
    final next = markers[aIndex + 1];
    if (next.letter != letter ||
        next.format != a.format ||
        !_isWeakBoundary(text, next.start) ||
        !_hasRealContent(text, next.end)) {
      break;
    }
    out.add(next.text);
    aIndex++;
  }
  return out;
}

/// 空白字符：空格、制表符、换行、回车、全角空格。
bool _isSpace(int c) {
  return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x3000;
}

/// 行内空白（不含换行）：空格、制表符、回车、全角空格。
bool _isBlank(int c) {
  return c == 0x20 || c == 0x09 || c == 0x0D || c == 0x3000;
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
