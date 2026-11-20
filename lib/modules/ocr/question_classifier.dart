// 十四批 M1：题型分类器（纯函数，无 UI、无网络、无数据库依赖）。
//
// 输入 = GlmOcrRawData（md_results 全文 + layout_details）+ splitStem
// 的判定；输出 =（主题型，来源，背景标签，背景标签来源，证据摘要 reason）。
// reason 只进日志与测试断言，不进 UI。
//
// 规则（PLAN-14-REV4.3 M1 P1-1/P1-2）：
// - 主题型枚举 17 个值 + NULL（待确认）；判定描述里只用这些值；
//   名词解释/案例简答归 short_answer；没有“解答类默认 short_answer”；
//   无信号即 NULL。
// - 裸关键词永不单独定型：求/计算/证明/简述/论述等动词本身只是低信号，
//   只有与结构条件组合成中信号时才参与判定。
// - 单题路径：恰好一个高/中信号成立且无冲突信号才自动定型，否则待确认；
//   冲突 = 两个及以上不同主型的中/高信号同时成立。
// - 多小问结构（≥2 个同格式小问标记）先走小问分类路径：逐小问判定，
//   全同型才赋型，否则 NULL + 提示拆框；标记混杂/边界不清/切分后某小问
//   为空 → 待确认。**只有多小问结构不足以自动打“材料”标签**。
// - 背景标签第一版只自动生成“材料”和“听力”：材料须明确材料依赖证据
//   （材料引导语 + 其后有对应设问）；听力须明确听力结构证据。无可靠
//   证据 → ''。案例/阅读/完形/图表/实验场景仅保留枚举、不自动赋值。
// - 主观作答信号是兜底信号（D-118）：仅当无其他中/高信号时才参与判定；
//   有任一其他信号时不单独成候选——“分析+计算”类复合指令不因此误判冲突。
//   论述特殊条件优先：同一主观信号内先判 essay 再判 short_answer，
//   不同时产生两个候选类型。

import '../../models/models.dart';
import '../../services/glm_ocr_client.dart';
import '../../services/option_contents.dart';
import '../../services/stem_splitter.dart';

/// 主题型枚举值（存储值），按展示顺序。
const List<String> questionTypeValues = [
  'choice_single',
  'choice_multi',
  'choice_variable',
  'true_false',
  'fill_blank',
  'calculation',
  'proof',
  'short_answer',
  'essay',
  'matching',
  'ordering',
  'diagram_label',
  'programming',
  'experiment_analysis',
  'translation',
  'writing',
  'other',
];

/// 主题型中文显示名。
const Map<String, String> questionTypeLabels = {
  'choice_single': '单项选择',
  'choice_multi': '多项选择',
  'choice_variable': '不定项选择',
  'true_false': '判断题',
  'fill_blank': '填空题',
  'calculation': '计算题',
  'proof': '证明题',
  'short_answer': '简答题',
  'essay': '论述题',
  'matching': '匹配题',
  'ordering': '排序题',
  'diagram_label': '绘图标注题',
  'programming': '编程题',
  'experiment_analysis': '实验分析题',
  'translation': '翻译题',
  'writing': '写作题',
  'other': '其他',
};

/// 主题型显示名；NULL = 待确认。
String questionTypeDisplay(String? type) =>
    type == null ? '待确认' : (questionTypeLabels[type] ?? '其他');

/// 背景标签枚举（第一版只自动生成“材料”和“听力”，其余为预留值）。
const List<String> questionBackgroundTagValues = [
  '材料',
  '案例',
  '阅读',
  '完形',
  '听力',
  '图表',
  '实验场景',
];

/// 分类结果。
class QuestionClassification {
  const QuestionClassification({
    required this.questionType,
    required this.questionTypeSource,
    required this.backgroundTags,
    required this.backgroundTagsSource,
    required this.reason,
    this.suggestSplit = false,
  });

  /// 主题型；NULL = 待确认。
  final String? questionType;

  /// 主题型来源：'auto'（本次自动定型）或 'unclassified'（未定型）。
  /// 分类器本身永不写 'manual'。
  final String questionTypeSource;

  /// 背景标签（逗号分隔，如 '材料'；无可靠证据时 ''）。
  final String backgroundTags;

  /// 背景标签来源：'auto' 或 'unclassified'。
  final String backgroundTagsSource;

  /// 证据摘要（只进日志与测试断言，不进 UI）。
  final String reason;

  /// 是否提示拆框：多小问类型不一致/任一小问判不出/无法可靠分割时为真。
  final bool suggestSplit;
}

/// 按当前来源守门，决定分类结果里哪些字段可以写库。
/// 'manual' 的字段不写（互不影响）；其余字段写分类器的结果
///（定型为 NULL 时也写——内容变了，旧的自动分类不再有依据）。
class ClassificationWrite {
  const ClassificationWrite({
    required this.writeType,
    this.questionType,
    this.questionTypeSource = 'unclassified',
    required this.writeTags,
    this.backgroundTags = '',
    this.backgroundTagsSource = 'unclassified',
  });

  final bool writeType;
  final String? questionType;
  final String questionTypeSource;
  final bool writeTags;
  final String backgroundTags;
  final String backgroundTagsSource;
}

ClassificationWrite planClassificationWrite({
  required String? currentTypeSource,
  required String? currentTagsSource,
  required QuestionClassification classification,
}) {
  final writeType = currentTypeSource != 'manual';
  final writeTags = currentTagsSource != 'manual';
  return ClassificationWrite(
    writeType: writeType,
    questionType: writeType ? classification.questionType : null,
    questionTypeSource: writeType
        ? classification.questionTypeSource
        : 'unclassified',
    writeTags: writeTags,
    backgroundTags: writeTags ? classification.backgroundTags : '',
    backgroundTagsSource: writeTags
        ? classification.backgroundTagsSource
        : 'unclassified',
  );
}

/// 人工改题型（整理页/详情页）：写 question_type_source='manual'。
/// 题型值变化时 content_version +1（题型是作答形式决定字段，不是普通
/// 归类字段）；值不变时只改来源保护位，不递增版本。
/// [newType] 为 null 表示人工主动指定“待确认”（NULL + source=manual，
/// 之后 OCR 也不得自动分类）。
Question withManualQuestionType(Question question, String? newType) {
  final changed = question.questionType != newType;
  var updated = question.copyWith(
    questionTypeSource: 'manual',
    clearQuestionType: newType == null,
  );
  if (newType != null) {
    updated = updated.copyWith(questionType: newType);
  }
  if (changed) {
    updated = updated.copyWith(contentVersion: question.contentVersion + 1);
  }
  return updated;
}

/// 自动重算题型（Win11 包 4）：对一道题用其 OCR 原文重新跑分类，返回
/// 应写入库的新题；无需写库时返回 null（调用方不写库，防循环）。
///
/// 返回 null 的情形：
/// * 题型来源为 manual（人工指定永不覆盖）；
/// * 无 OCR 原文或原文解析失败；
/// * 重算结果与库里已存的题型/来源/背景标签/标签来源全等（同一输入
///   版本只自动算一次，写库无意义——[planClassificationWrite] 的
///   per-field 门保证 manual 字段不动）。
/// 否则返回 copyWith：题型/标签按 per-field 门写，contentVersion +1
///（与 [withManualQuestionType] 同口径；调用方用 SaveToken 以旧版本
/// 写库，版本冲突即失败不覆盖）。
Question? reclassifiedQuestion(Question question) {
  if (question.questionTypeSource == 'manual') return null;
  final rawText = question.ocrRaw;
  if (rawText == null) return null;
  final raw = GlmOcrRawData.tryParse(rawText);
  if (raw == null) return null;
  final classification = classifyQuestion(
    raw: raw,
    split: splitStem(raw.mdResults),
  );
  final plan = planClassificationWrite(
    currentTypeSource: question.questionTypeSource,
    currentTagsSource: question.questionBackgroundTagsSource,
    classification: classification,
  );
  final newType = plan.writeType ? plan.questionType : question.questionType;
  final newTypeSource = plan.writeType
      ? plan.questionTypeSource
      : question.questionTypeSource;
  final newTags = plan.writeTags
      ? plan.backgroundTags
      : question.questionBackgroundTags;
  final newTagsSource = plan.writeTags
      ? plan.backgroundTagsSource
      : question.questionBackgroundTagsSource;
  if (newType == question.questionType &&
      newTypeSource == question.questionTypeSource &&
      newTags == question.questionBackgroundTags &&
      newTagsSource == question.questionBackgroundTagsSource) {
    return null;
  }
  var updated = question.copyWith(
    questionTypeSource: newTypeSource,
    questionBackgroundTagsSource: newTagsSource,
    clearQuestionType: newType == null,
  );
  if (newType != null) {
    updated = updated.copyWith(questionType: newType);
  }
  updated = updated.copyWith(
    questionBackgroundTags: newTags,
    contentVersion: question.contentVersion + 1,
  );
  return updated;
}

/// 直接对一段 OCR 文本分类（splitStem 在内部跑；UI 提示与测试用）。
QuestionClassification classifyQuestionText(String mdText) {
  final raw = GlmOcrRawData(mdResults: mdText);
  return classifyQuestion(raw: raw, split: splitStem(mdText));
}

/// 分类主入口：md 全文 + splitStem 判定。
QuestionClassification classifyQuestion({
  required GlmOcrRawData raw,
  required StemSplitResult split,
}) {
  final md = raw.mdResults;
  final tags = _classifyBackgroundTags(md);
  // 多小问结构先走小问路径（不直接对整框应用单题规则）。
  final sub = _trySubQuestionPath(md);
  if (sub != null) {
    return QuestionClassification(
      questionType: sub.type,
      questionTypeSource: sub.type == null ? 'unclassified' : 'auto',
      backgroundTags: tags.tags,
      backgroundTagsSource: tags.source,
      reason: sub.reason,
      suggestSplit: sub.suggestSplit,
    );
  }
  final single = _classifySingle(md, split);
  return QuestionClassification(
    questionType: single.type,
    questionTypeSource: single.type == null ? 'unclassified' : 'auto',
    backgroundTags: tags.tags,
    backgroundTagsSource: tags.source,
    reason: single.reason,
  );
}

/// 背景标签：只自动生成“材料”和“听力”。
({String tags, String source}) _classifyBackgroundTags(String md) {
  final found = <String>[];
  if (_hasMaterialEvidence(md)) found.add('材料');
  if (_hasListeningEvidence(md)) found.add('听力');
  if (found.isEmpty) return (tags: '', source: 'unclassified');
  return (tags: found.join(','), source: 'auto');
}

/// 材料依赖证据：材料引导语 + 其后有对应设问。
bool _hasMaterialEvidence(String md) {
  const guides = [
    '阅读下列材料',
    '根据上述材料',
    '根据下列材料',
    '阅读以下材料',
    '根据所给材料',
    '阅读材料',
    '根据材料',
    '结合材料',
    '材料一',
    '材料二',
    '材料三',
  ];
  for (final g in guides) {
    final i = md.indexOf(g);
    if (i < 0) continue;
    final tail = md.substring(i + g.length);
    if (_hasQuestionAfter(tail)) return true;
  }
  return false;
}

/// 引导语后有对应设问：问号、设问动词或小问标记。
bool _hasQuestionAfter(String tail) {
  if (tail.contains('？') || tail.contains('?')) return true;
  const cues = [
    '回答',
    '请简述',
    '请分析',
    '请论述',
    '请计算',
    '请判断',
    '请说明',
    '请解释',
    '请指出',
    '请列出',
    '请谈谈',
  ];
  if (cues.any(tail.contains)) return true;
  if (_subQuestionMarkers(tail).isNotEmpty) return true;
  return false;
}

/// 听力结构证据：听力关键词 + 听力题型结构（对话/录音后设问）。
bool _hasListeningEvidence(String md) {
  if (md.contains('听力')) return true;
  if (md.contains('听录音') || md.contains('听对话')) return true;
  if (md.contains('听') &&
      md.contains('对话') &&
      (md.contains('回答') ||
          md.contains('选择') ||
          md.contains('？') ||
          md.contains('?'))) {
    return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// 多小问路径
// ---------------------------------------------------------------------------

/// 小问路径结果；返回 null 表示未检测到多小问结构，走单题路径。
class _SubQuestionOutcome {
  const _SubQuestionOutcome({
    required this.type,
    required this.reason,
    required this.suggestSplit,
  });
  final String? type;
  final String reason;
  final bool suggestSplit;
}

_SubQuestionOutcome? _trySubQuestionPath(String md) {
  final markers = _subQuestionMarkers(md);
  if (markers.isEmpty) {
    // 无标记：换行分隔的独立设问句（每段以问号收尾）也算多小问结构。
    final paras = _independentQuestionParagraphs(md);
    if (paras == null) return null;
    return _classifySubQuestions(paras, '换行分隔的独立设问句');
  }
  // ①② 须先区分是选项序列还是小问序列。
  if (markers.kind == _MarkerKind.circled) {
    final kind = _distinguishCircled(md, markers);
    if (kind == _CircledKind.options) return null;
    if (kind == _CircledKind.undecided) {
      return const _SubQuestionOutcome(
        type: null,
        reason: '①② 序列无法区分是选项还是小问，不强行分类',
        suggestSplit: true,
      );
    }
  }
  // 标记格式混杂（两种以上格式同时成序列）→ 无法可靠分割。
  if (markers.mixed) {
    return const _SubQuestionOutcome(
      type: null,
      reason: '小问标记格式混杂，无法可靠分割',
      suggestSplit: true,
    );
  }
  final segments = _splitByMarkers(md, markers);
  if (segments == null) {
    return const _SubQuestionOutcome(
      type: null,
      reason: '小问切分后某段为空，无法可靠分割',
      suggestSplit: true,
    );
  }
  // （1）（2）、一、二 也须确认确实是小问边界：每段须有设问线索，
  // 否则可能是列举、推导步骤或普通正文编号。
  for (final s in segments) {
    if (!_looksLikeSubQuestion(s)) {
      return const _SubQuestionOutcome(
        type: null,
        reason: '小问边界不清（某段无设问线索），无法可靠分割',
        suggestSplit: true,
      );
    }
  }
  return _classifySubQuestions(segments, '小问标记 ${markers.kind.label}');
}

_SubQuestionOutcome _classifySubQuestions(
  List<String> segments,
  String how,
) {
  final types = <String?>[];
  for (final s in segments) {
    types.add(_classifySingle(s, splitStem(s)).type);
  }
  if (types.any((t) => t == null)) {
    return _SubQuestionOutcome(
      type: null,
      reason: '$how：${segments.length} 个小问中有 ${types.where((t) => t == null).length} 个无法判定，本题含多种作答形式，请拆框或人工指定',
      suggestSplit: true,
    );
  }
  if (types.toSet().length == 1) {
    // 注意：types 是每小问一个元素（长度 ≥2），不能直接 .single；
    // 先去重再取唯一值（M1 自测发现：直接 .single 会抛 Too many elements）。
    final only = types.toSet().single;
    return _SubQuestionOutcome(
      type: only,
      reason: '$how：${segments.length} 个小问全为 ${questionTypeLabels[only]}',
      suggestSplit: false,
    );
  }
  return _SubQuestionOutcome(
    type: null,
    reason: '$how：${segments.length} 个小问类型不一致（${types.map((t) => questionTypeLabels[t]).join('、')}），本题含多种作答形式，请拆框或人工指定',
    suggestSplit: true,
  );
}

/// 一段文本是否像一个小问：有问号或设问动词。
bool _looksLikeSubQuestion(String segment) {
  final s = segment.trim();
  if (s.isEmpty) return false;
  if (s.contains('？') || s.contains('?')) return true;
  const cues = [
    '请',
    '回答',
    '求',
    '判断',
    '计算',
    '证明',
    '简述',
    '论述',
    '解释',
    '分析',
    '讨论',
    '说明',
    '阐述',
    '指出',
    '列举',
    '选择',
    '翻译',
    '写出',
    '求出',
    '完成',
    '试',
  ];
  return cues.any(s.contains);
}

/// 换行分隔的独立设问句：≥2 段，每段以问号收尾；判不准即 null。
List<String>? _independentQuestionParagraphs(String md) {
  final paras = md
      .split(RegExp(r'\n\s*\n|\n'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  if (paras.length < 2) return null;
  for (final p in paras) {
    if (!p.endsWith('？') && !p.endsWith('?')) return null;
  }
  return paras;
}

enum _MarkerKind {
  parenNumber('（1）（2）'),
  parenChinese('（一）（二）'),
  circled('①②'),
  chineseNumeral('一、二');

  const _MarkerKind(this.label);
  final String label;
}

class _MarkerHit {
  const _MarkerHit({
    required this.kind,
    required this.start,
    required this.end,
    required this.index,
  });
  final _MarkerKind kind;
  final int start;
  final int end;
  final int index;
}

class _Markers {
  const _Markers({required this.kind, required this.hits, this.mixed = false});
  final _MarkerKind kind;
  final List<_MarkerHit> hits;
  final bool mixed;

  bool get isEmpty => hits.isEmpty;
  bool get isNotEmpty => hits.isNotEmpty;
}

/// 扫出同格式小问标记序列（≥2 个才算）。格式混杂时 mixed 为真。
_Markers _subQuestionMarkers(String text) {
  final byKind = <_MarkerKind, List<_MarkerHit>>{};
  void scan(_MarkerKind kind, RegExp pattern, int Function(String raw) indexOf) {
    final hits = <_MarkerHit>[];
    for (final m in pattern.allMatches(text)) {
      final idx = indexOf(m.group(0)!);
      if (idx < 0) continue;
      hits.add(_MarkerHit(kind: kind, start: m.start, end: m.end, index: idx));
    }
    // 只要从 1（一/①）起连续的序列。
    final seq = <_MarkerHit>[];
    for (final h in hits) {
      if (h.index == seq.length + 1) {
        seq.add(h);
      } else if (h.index == 1 && seq.isNotEmpty) {
        break;
      }
    }
    if (seq.length >= 2) byKind[kind] = seq;
  }

  scan(
    _MarkerKind.parenNumber,
    RegExp(r'[（(]\s*\d{1,2}\s*[)）]'),
    (raw) {
      final d = RegExp(r'\d+').firstMatch(raw);
      return d == null ? -1 : int.parse(d.group(0)!);
    },
  );
  scan(
    _MarkerKind.parenChinese,
    RegExp(r'[（(]\s*[一二三四五六七八九十]\s*[)）]'),
    (raw) => _chineseNumeralValue(raw),
  );
  scan(
    _MarkerKind.circled,
    RegExp(r'[①②③④⑤⑥⑦⑧⑨⑩]'),
    (raw) => '①②③④⑤⑥⑦⑧⑨⑩'.indexOf(raw) + 1,
  );
  scan(
    _MarkerKind.chineseNumeral,
    RegExp(r'(?:^|\n)\s*[一二三四五六七八九十][、．.]'),
    (raw) => _chineseNumeralValue(raw),
  );
  if (byKind.isEmpty) return const _Markers(kind: _MarkerKind.parenNumber, hits: []);
  if (byKind.length > 1) {
    final first = byKind.values.first;
    return _Markers(kind: byKind.keys.first, hits: first, mixed: true);
  }
  final kind = byKind.keys.single;
  return _Markers(kind: kind, hits: byKind[kind]!);
}

int _chineseNumeralValue(String raw) {
  const order = '一二三四五六七八九十';
  for (var i = 0; i < raw.length; i++) {
    final at = order.indexOf(raw[i]);
    if (at >= 0) return at + 1;
  }
  return -1;
}

/// 按标记切分出每小问的局部文本；某段为空时返回 null。
List<String>? _splitByMarkers(String text, _Markers markers) {
  final segments = <String>[];
  for (var i = 0; i < markers.hits.length; i++) {
    final start = markers.hits[i].end;
    final end = i + 1 < markers.hits.length
        ? markers.hits[i + 1].start
        : text.length;
    final seg = text.substring(start, end).trim();
    if (seg.isEmpty) return null;
    segments.add(seg);
  }
  return segments;
}

enum _CircledKind { options, subQuestions, undecided }

/// ①② 是选项还是小问：题干指令 + 文本形态 + 局部结构三点判定。
_CircledKind _distinguishCircled(String md, _Markers markers) {
  final first = markers.hits.first;
  final before = md.substring(0, first.start);
  const optionInstructions = ['下列说法正确的是', '下列选项', '单项选择', '多项选择', '不定项选择', '选择正确的'];
  const subInstructions = ['阅读下列材料', '根据材料', '回答下列问题', '回答问题', '结合材料', '阅读材料'];
  if (optionInstructions.any(before.contains)) return _CircledKind.options;
  if (subInstructions.any(before.contains)) return _CircledKind.subQuestions;
  // 文本形态：每段是短语/短句（选项）还是完整设问句（小问）。
  final segments = _splitByMarkers(md, markers);
  if (segments == null) return _CircledKind.undecided;
  var questionLike = 0;
  var phraseLike = 0;
  for (final s in segments) {
    if (_looksLikeSubQuestion(s)) {
      questionLike++;
    } else if (s.length <= 20) {
      phraseLike++;
    }
  }
  if (questionLike == segments.length) return _CircledKind.subQuestions;
  if (phraseLike == segments.length) return _CircledKind.options;
  // 局部结构：4 项左右同级并列的短项偏选项；其余判不准。
  if (markers.hits.length >= 4 && phraseLike > questionLike) {
    return _CircledKind.options;
  }
  return _CircledKind.undecided;
}

// ---------------------------------------------------------------------------
// 单题路径
// ---------------------------------------------------------------------------

class _SingleOutcome {
  const _SingleOutcome({required this.type, required this.reason});
  final String? type;
  final String reason;
}

_SingleOutcome _classifySingle(String md, StemSplitResult split) {
  final candidates = <String, String>{};
  // §2.2 步骤 4（REV5）：先算选择候选，再算填空候选。
  // 选择判定成立 → 判选择题，空括号 ( ) 不再触发填空。
  if (split.status == StemSplitStatus.autoSplit) {
    candidates[_choiceType(md, split.stemText)] = '自动切分检出 A–E 选项序列';
  }
  // Win11 反馈包 5：结构化选项内容信号，与切分信号互补——切分失败
  // （如双栏选项未过强边界）但统一解析器仍能按顺序解析出 ≥2 个有文字
  // 的选项槽时，也作选择候选；与切分信号是同一候选（putIfAbsent，
  // 不产生两个选择候选）。判断题固定“正确/错误”，不走选项解析：
  // 判断信号若同时成立，按既有冲突规则判待确认。
  if (parseOptionContents(md, split).hasStructuredOptions) {
    candidates.putIfAbsent(
      _choiceType(md, split.stemText),
      () => '结构化选项内容 ≥2 槽有文字',
    );
  }
  // ①②③④ 选项序列（中；小问路径已排除小问情形，到这里就是选项）。
  // 带圈数字在代码块/公式内时不计（与 splitStem 同一词法优先级，S3-1）。
  if (_hasCircledOptionSequence(md)) {
    candidates.putIfAbsent(
      _choiceType(md, md),
      () => '检测到 ①②③④ 选项序列',
    );
  }
  final blankKind = _blankKind(md);
  if (candidates.isEmpty) {
    if (blankKind == _BlankKind.strong) {
      candidates['fill_blank'] = '检测到填空空白';
    } else if (blankKind == _BlankKind.bare) {
      // 选择不成立、填空候选只有裸空括号 ( ) → 不自动定型（返回 null，不硬猜）。
      return const _SingleOutcome(
        type: null,
        reason: '仅有空括号，无选择/强填空结构，不自动定型',
      );
    }
  }
  // 判断（中）。
  if (_hasJudgeSignal(md)) {
    candidates['true_false'] = '检测到判断关键词 + √×/T·F 标记';
  }
  // 计算（中）。
  if (_hasCalculationSignal(md)) {
    candidates['calculation'] = '检测到计算动词 + 数学结构';
  }
  // 证明（中）。
  if (_hasProofSignal(md)) {
    candidates['proof'] = '检测到证明动词 + 数学或逻辑结构';
  }
  // 匹配/排序/绘图标注/编程/实验分析/翻译/写作（中，结构条件见各函数）。
  if (_hasMatchingSignal(md)) candidates['matching'] = '检测到配对/连线结构';
  if (_hasOrderingSignal(md)) candidates['ordering'] = '检测到排序结构';
  if (_hasDiagramSignal(md)) candidates['diagram_label'] = '检测到绘图标注结构';
  if (_hasProgrammingSignal(md)) {
    candidates['programming'] = '检测到代码块 + 编程指令';
  }
  if (_hasExperimentSignal(md)) {
    candidates['experiment_analysis'] = '检测到实验 + 分析/设计/数据结构';
  }
  if (_hasTranslationSignal(md)) {
    candidates['translation'] = '检测到翻译指令';
  }
  if (_hasWritingSignal(md)) candidates['writing'] = '检测到写作指令';
  // 主观作答（中，兜底：仅当无其他中/高信号时才参与判定）。
  if (candidates.isEmpty) {
    final subjective = _subjectiveType(md);
    if (subjective != null) {
      candidates[subjective.$1] = subjective.$2;
    }
  }
  if (candidates.isEmpty) {
    return const _SingleOutcome(type: null, reason: '无可靠信号，不硬猜');
  }
  if (candidates.length == 1) {
    final entry = candidates.entries.single;
    return _SingleOutcome(type: entry.key, reason: entry.value);
  }
  return _SingleOutcome(
    type: null,
    reason:
        '冲突：${candidates.entries.map((e) => '${questionTypeLabels[e.key]}（${e.value}）').join('；')}同时成立',
  );
}

/// 选择题细分：题干含“不定项”→ 不定项；含“多选”→ 多选；否则单选。
String _choiceType(String md, String stemText) {
  final text = stemText.isNotEmpty ? stemText : md;
  if (text.contains('不定项')) return 'choice_variable';
  if (text.contains('多选') || text.contains('多项选择')) return 'choice_multi';
  return 'choice_single';
}

/// ①②③④ 选项序列：① 起连续、同格式、强边界、后有实内容。
/// （小问路径已先行：判为小问或判不准时本信号不成立——调用方须先走
/// _trySubQuestionPath；单题路径里出现 ①② 且未进小问路径时才是选项。）
/// 代码块/公式内的带圈数字不计（与 splitStem 同一词法优先级，S3-1：
/// 代码保护 → 公式识别 → HTML/选项扫描）。
bool _hasCircledOptionSequence(String md) {
  const circled = '①②③④⑤';
  final excluded = optionScanExcludedRanges(md);
  bool isExcluded(int i) =>
      excluded.any((r) => i >= r.start && i < r.end);
  var expected = 0;
  var found = 0;
  var i = 0;
  while (i < md.length) {
    if (isExcluded(i)) {
      i++;
      continue;
    }
    final at = circled.indexOf(md[i]);
    if (at == expected) {
      if (!_isStrongBoundary(md, i) || !_hasRealContentAfter(md, i + 1)) {
        return false;
      }
      found++;
      expected++;
      i++;
      continue;
    }
    if (at >= 0) return false; // 乱序/跳号的带圈数字不是选项序列
    i++;
  }
  return found >= 2 && expected >= 2;
}

/// 强边界：行首，或 ≥2 空格/制表符的栏位间隔。
bool _isStrongBoundary(String text, int start) {
  if (start == 0) return true;
  var i = start - 1;
  if (text.codeUnitAt(i) == 0x0A) return true;
  var run = 0;
  while (i >= 0 && _isBlank(text.codeUnitAt(i))) {
    run++;
    i--;
  }
  return run >= 2;
}

/// 标记后有实际内容：跳过空白后有字，且不是下一个带圈数字标记。
bool _hasRealContentAfter(String text, int from) {
  var i = from;
  while (i < text.length && _isSpace(text.codeUnitAt(i))) {
    i++;
  }
  if (i >= text.length) return false;
  if ('①②③④⑤⑥⑦⑧⑨⑩'.contains(text[i])) return false;
  const noContent = '.,;:!?，。；：、）)）';
  if (noContent.contains(text[i])) return false;
  return true;
}

bool _isBlank(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0D || c == 0x3000;

bool _isSpace(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x3000;

/// 填空候选分级（§2.2 步骤 4）：强填空结构 = 连续 3 个以上下划线，
/// 或“填空”关键词；裸空括号/空方括号只有其一时为 bare，不自动定型。
enum _BlankKind { none, bare, strong }

_BlankKind _blankKind(String md) {
  if (RegExp(r'_{3,}').hasMatch(md)) return _BlankKind.strong;
  if (md.contains('填空')) return _BlankKind.strong;
  if (RegExp(r'[（(]\s*[)）]').hasMatch(md)) return _BlankKind.bare;
  if (RegExp(r'[［\[]\s*[］\]]').hasMatch(md)) return _BlankKind.bare;
  return _BlankKind.none;
}

/// 判断：判断关键词 + √×/T·F 标记。
bool _hasJudgeSignal(String md) {
  final hasKeyword =
      md.contains('判断') ||
      md.contains('对错') ||
      md.contains('正误') ||
      md.contains('是非');
  if (!hasKeyword) return false;
  if (md.contains('√') ||
      md.contains('×') ||
      md.contains('✓') ||
      md.contains('✗')) {
    return true;
  }
  if (RegExp(r'T\s*[·/、,，]\s*F').hasMatch(md)) return true;
  if (md.contains('正确') && md.contains('错误')) return true;
  return false;
}

/// 数学结构：LaTeX、数字表达式或数学符号/函数名。
bool _hasMathStructure(String md) {
  if (md.contains('\$')) return true;
  if (RegExp(r'\d\s*[+\-×÷*/^=]\s*\d').hasMatch(md)) return true;
  const symbols = ['²', '³', '√', 'π', '∫', '∑', '≈', '≠', '≤', '≥', '∞', '∴', '∵'];
  if (symbols.any(md.contains)) return true;
  if (RegExp(r'\b(sin|cos|tan|log|ln|lim|frac|dx|dy)\b').hasMatch(md)) {
    return true;
  }
  return false;
}

/// 计算：求/计算类动词 + 数学符号或公式；只有动词、无数学结构时不触发。
bool _hasCalculationSignal(String md) {
  const verbs = ['求', '计算', '求解', '算出', '求出', '计算出'];
  if (!verbs.any(md.contains)) return false;
  return _hasMathStructure(md);
}

/// 证明：证明类动词 + 数学或逻辑结构；只有动词、无结构时不触发。
bool _hasProofSignal(String md) {
  const verbs = ['证明', '求证', '试证明', '试证'];
  if (!verbs.any(md.contains)) return false;
  if (_hasMathStructure(md)) return true;
  const logic = ['已知', '求证', '充分', '必要', '当且仅当', '∴', '∵'];
  return logic.any(md.contains);
}

/// 主观作答（兜底）：简述/解释/论述/分析/讨论类动词，且全文无选项序列、
/// 无填空空白、无判断标记。论述 + 成段论证要求 → essay；其余（含名词
/// 解释、案例简答）→ short_answer。调用方已保证无其他候选时才查本信号。
(String, String)? _subjectiveType(String md) {
  if (md.contains('名词解释')) {
    return ('short_answer', '检测到名词解释');
  }
  const verbs = [
    '简述',
    '解释',
    '论述',
    '分析',
    '讨论',
    '说明',
    '阐述',
    '回答',
    '指出',
    '列举',
    '谈谈',
    '试述',
    '简答',
  ];
  if (!verbs.any(md.contains)) return null;
  // 论述特殊条件优先：论述 + 成段论证要求 → essay。
  if (md.contains('论述') &&
      (md.contains('结合') ||
          md.contains('试论述') ||
          md.contains('不少于') ||
          RegExp(r'\d+\s*字').hasMatch(md))) {
    return ('essay', '检测到论述动词 + 成段论证要求');
  }
  return ('short_answer', '检测到主观作答动词，且无选项/空白/判断结构');
}

/// 匹配：连线，或配对 + 左右栏/两组结构。
bool _hasMatchingSignal(String md) {
  if (md.contains('连线')) return true;
  if (md.contains('配对') &&
      (md.contains('左栏') ||
          md.contains('右栏') ||
          md.contains('左右') ||
          md.contains('两组') ||
          md.contains('A组') ||
          md.contains('B组'))) {
    return true;
  }
  return false;
}

/// 排序：排序/排列 + 顺序/先后/流程/步骤。
bool _hasOrderingSignal(String md) {
  if (md.contains('按正确顺序排列') || md.contains('按时间顺序排列')) {
    return true;
  }
  if (md.contains('排序') &&
      (md.contains('顺序') ||
          md.contains('先后') ||
          md.contains('流程') ||
          md.contains('步骤'))) {
    return true;
  }
  if (md.contains('排列') &&
      md.contains('顺序') &&
      (md.contains('将') || md.contains('请'))) {
    return true;
  }
  return false;
}

/// 绘图标注：绘图/画图 + 图，或标注 + 图/结构。
bool _hasDiagramSignal(String md) {
  if ((md.contains('绘图') || md.contains('画图')) &&
      (md.contains('图') || md.contains('表'))) {
    return true;
  }
  if (md.contains('画出') &&
      (md.contains('图像') || md.contains('示意图') || md.contains('结构图'))) {
    return true;
  }
  if (md.contains('标注') && (md.contains('图') || md.contains('结构'))) {
    return true;
  }
  return false;
}

/// 编程：代码块 + 编程指令。
bool _hasProgrammingSignal(String md) {
  if (!md.contains('```')) return false;
  return md.contains('程序') ||
      md.contains('代码') ||
      md.contains('函数') ||
      md.contains('编写') ||
      md.contains('纠错');
}

/// 实验分析：实验 + 分析/设计/数据/结论/现象/步骤。
bool _hasExperimentSignal(String md) {
  if (!md.contains('实验')) return false;
  const rest = ['分析', '设计', '数据', '结论', '现象', '步骤', '操作', '结果'];
  return rest.any(md.contains);
}

/// 翻译：翻译 + 译/语种。
bool _hasTranslationSignal(String md) {
  if (!md.contains('翻译')) return false;
  return md.contains('译') ||
      md.contains('英文') ||
      md.contains('英语') ||
      md.contains('中文') ||
      md.contains('汉语');
}

/// 写作：作文/写作 + 字数/题目要求。
bool _hasWritingSignal(String md) {
  if (!md.contains('作文') && !md.contains('写作')) return false;
  return md.contains('不少于') ||
      RegExp(r'\d+\s*字').hasMatch(md) ||
      md.contains('为题') ||
      md.contains('写一篇');
}
