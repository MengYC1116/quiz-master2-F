// WP-A #1（九项修复 REV5 §1 + R1 + S2）：答案区选项编辑器。
//
// REV5 起：删除标签文本框与「确认选项」按钮，改为答案区内置的
// [AnswerOptionEditor]：选项位纵向排列，每位一行 = 标签字母（不可改
// 字母本身，只能增删位）+ 正确答案点选；D 位后一个「+」按钮，点一下
// 追加下一字母（E、F……按字母表顺序）。
//
// Win11 反馈包 1：字母位改小尺寸横向 chip（Wrap，超宽换行；chip 上
// 带小 × 删除——QmChip 可删除双区形态，点片身点选、点 × 删除）；
// 选项文字行改纵向列表、行首标字母，跟在芯片区下方。本编辑器已移进
// “答案”区内（整理页与详情编辑态的答案区里），不再是题型区独立区块。
//
// - 单选（choice_single）：点选一个正确答案位；点选即带重确认信号
//   （S2-1：保存时 answerReconfirmed = 本会话内是否点选过正确答案位）。
// - 判断（true_false）：只显示「正确」「错误」两个固定位 + 点选；
//   不显示「+」、不可删位。判断题内部从来不是 A/B，correctOption 存
//   的就是 正确/错误，无需任何存储迁移。
// - 多选/不定项（choice_multi / choice_variable）：每位可点选多个，
//   点选结果走 answer 字段（[onMultiSelectionChanged]，逗号分隔的
//   字母串；多选不写 correctOption）。answer 是自由文本，不得解析
//   （R1-4）：编辑器不从 answer 文本反推点选态，点选集合只活在本
//   会话内、初始为空。
// - 非选择题：不显示本编辑器。
//
// Win11 反馈包 5（识别全部）：每位下方显示选项文字（与字母一一对应；
// 题干区仍只显示题干）。选项文字按 [parseQuestionContent] +
// [QuestionContentRenderer] 渲染——公式按 LaTeX 渲染，反斜杠与上下标
// 不破坏，渲染失败回退原图占位、不外露源码。文字可手动改：点行尾的
// 编辑按钮切到文本框，改完点 ✓ 即上报（[onOptionContentsChanged]）；
// 删位时对应键一并去掉（标签映射只动对应键，不串位）。
// 显示门由调用方守：只在切分成功（autoSplit）时传 optionContents /
// detectedOptionContents；切分失败时传 null（选项文字已在题干里，
// 选项区不重复显示）；判断题固定“正确/错误”，不走选项解析、不显示
// 选项文字。detectedOptionContents 只作初始值：只在 optionContents
// == null 时上报一次，此后以库里存的为准，永不以检测结果覆盖。
//
// 选项位数（§1.4，Meng 已定）：初始值 = 切分器检测到的选项个数
// （[detectedOptionLabels]，调用方传入；无检测结果但用户手动设为
// 选择题时默认 A–D 四位）。检测结果只作初始值：只在“首次进入整理且
// optionLabels == null”时写入一次（上报给调用方，由调用方表单值
// 落盘）；此后以库里存的 optionLabels 为准，永不以检测结果覆盖。
// 本编辑器只负责“初始值怎么来、怎么显示”；检测值 → 本编辑器的接线
// （organize_page 已算出 splitStem 结果处传入）是后续一行业务接线，
// 不在本包内。
//
// 重确认状态机（R1-1，保存侧由数据层 _applyOptionLabelChangeRules
// 执行，本编辑器只生产信号）：
// - 单选/判断点选正确答案并保存 → 信号 true；只改标签位或只改其他
//   字段时信号 false（S2-1：信号 = 本会话内点选过正确答案位）。
// - 删位时若被删的是正确答案位 → correctOption 清空、信号清零（走
//   无效态）；删非正确答案位 → 旧答案保留、信号不变。
// - 多选改标签 → 保留旧 answer 文本（不自动清空），信号只来自勾选
//   「已重新核对」复选框（S2-2）；未带信号保存时 answer 与 explanation
//   清空并标记待核对（数据层既有行为，S2-3）。
// - 只改答案/解析文本、未点选正确答案位时：correctOption 不清空，
//   answerPendingRecheck 不变（T2-3；保存侧既有行为，本编辑器不碰
//   这些字段）。
// - 切题（loadForm）→ 信号强制 false：本 widget 按 questionId 挂 key，
//   切题即重建 state，信号不跨题。
//
// optionLabelsConfirmed 列：REV5 起保留列、停止读写。编辑器不再写它，
// 判分不再读它（见 review_engine.dart R1-3）。[OptionLabelsEditor]
// 仍接受该参数，仅为旧调用方源码兼容，不再产生任何效果。
//
// 本 widget 只管展示与草稿：标签增删草稿、正确选项点选、P1-A 待核对
// 提示与重确认复选框都活在本 widget 的 state 里；落盘由调用方做——
// 整理页是表单式（只改表单值，确认栏保存），详情页查看态是即时保存式
// （正确选项点选 / 增删位立即走 onConfirm 保存）。调用方 key 必须按题
// 挂（ValueKey(questionId)），切题后草稿随题重建。

import 'package:flutter/material.dart';

import '../../theme/design_tokens.dart';
import '../../widgets/uikit.dart';
import 'question_content.dart';
import 'question_content_renderer.dart';

/// 解析逗号分隔的选项标签：按 `[,，、；;\s]+` 切分、去空、去重保序。
/// 空串返回 null（= 未确认）。REV5 起编辑器不再用文本框输入，本函数
/// 仅保留作公共解析口径（既有测试与外部调用仍可用）。
List<String>? parseOptionLabels(String text) {
  final parts = text
      .split(RegExp(r'[,，、；;\s]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  final seen = <String>{};
  final out = <String>[];
  for (final p in parts) {
    if (seen.add(p)) out.add(p);
  }
  return out.isEmpty ? null : out;
}

/// 选项标签按值比较（顺序也算；Dart 的 List == 是同一性，不能直接比）。
bool sameOptionLabels(List<String>? a, List<String>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return a == null && b == null;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 默认选项位：无检测结果且用户手动设为选择题时 A–D 四位（§1.4）。
const List<String> _defaultOptionLabels = ['A', 'B', 'C', 'D'];

/// 判断题固定选项位（不存 optionLabels，只作显示与点选）。
const List<String> _trueFalseOptions = ['正确', '错误'];

/// 下一个可追加的选项字母：取末位字母的下一个（A–Y）；末位为 Z 或
/// 非单字母时取首个未用字母；A–Z 已用完返回 null（「+」禁用）。
String? _nextOptionLabel(List<String> labels) {
  if (labels.isEmpty) return 'A';
  final last = labels.last;
  if (last.length == 1) {
    final code = last.codeUnitAt(0);
    if (code >= 65 && code < 90) return String.fromCharCode(code + 1);
  }
  for (var c = 65; c <= 90; c++) {
    final letter = String.fromCharCode(c);
    if (!labels.contains(letter)) return letter;
  }
  return null;
}

/// 答案区选项编辑器（WP-A #1 新 widget）。
class AnswerOptionEditor extends StatefulWidget {
  const AnswerOptionEditor({
    super.key,
    required this.questionId,
    required this.questionType,
    required this.optionLabels,
    required this.storedOptionLabels,
    required this.correctOption,
    required this.storedCorrectOption,
    required this.answerPendingRecheck,
    required this.hadOldAnswer,
    required this.answerReconfirmed,
    required this.onLabelsChanged,
    required this.onCorrectOptionChanged,
    required this.onAnswerReconfirmedChanged,
    required this.onConfirm,
    this.correctOptionSavesImmediately = false,
    this.detectedOptionLabels,
    this.onMultiSelectionChanged,
    // Win11 反馈包 5：选项文字（标签映射；null = 未解析/不显示）。
    this.optionContents,
    this.detectedOptionContents,
    this.onOptionContentsChanged,
  });

  /// 当前题 id（调用方 key 也按它挂；变了草稿重建）。
  final String questionId;

  /// 当前题型（表单值；非选择/判断题型时本编辑器不渲染）。
  final String? questionType;

  /// 当前标签（表单值；null = 未确认）。整理页传表单值，详情页查看态
  /// 传库里值（无表单态，草稿只活在编辑器内）。null 时草稿按 §1.4
  /// 取初始值（检测结果优先，无则 A–D），并在首帧后上报一次。
  final List<String>? optionLabels;

  /// 库里存的标签（「本次是否改了标签」按草稿与它比较）。
  final List<String>? storedOptionLabels;

  /// 切分器检测到的选项位（§1.4 初始值；null/空 = 无检测结果）。
  /// 只在 optionLabels == null 时作初始值，永不覆盖库里已存值。
  final List<String>? detectedOptionLabels;

  /// 当前正确选项（表单值；单选/判断用）。
  final String? correctOption;

  /// 库里存的正确选项（改标签前的旧值；保留供调用方传值）。
  final String? storedCorrectOption;

  /// 库里存的待重新核对标记。
  final bool answerPendingRecheck;

  /// 库里旧答案或解析是否非空（P1-A 多选改标签提示用）。
  final bool hadOldAnswer;

  /// 本次编辑是否已重确认答案（表单值）。
  final bool answerReconfirmed;

  /// 标签改动（增删位后的列表；清空为 null）。
  final ValueChanged<List<String>?> onLabelsChanged;

  /// 正确选项改动（点选即带重确认信号，见文件头注释）。
  final ValueChanged<String?> onCorrectOptionChanged;

  /// 重确认信号改动（单选/判断点选、多选复选框）。
  final ValueChanged<bool> onAnswerReconfirmedChanged;

  /// 即时保存（仅详情页查看态用：正确选项点选、增删位、勾选复选框
  /// 时立即保存）。参数是编辑器当前草稿；confirmLabels 恒为 false
  /// （REV5：编辑器不再写 optionLabelsConfirmed 列，false = 保持
  /// 库里原确认状态）。非即时模式下永不调用。
  final void Function({
    required List<String>? labels,
    required String? correctOption,
    required bool answerReconfirmed,
    required bool confirmLabels,
  }) onConfirm;

  /// 正确选项点选 / 增删位是否立即保存（详情页查看态 true；整理页
  /// 表单式与详情编辑态 false）。
  final bool correctOptionSavesImmediately;

  /// 多选点选结果（走 answer 字段）：当前会话内点选的字母按标签位
  /// 顺序逗号拼接（如 'A,C'；空选为 ''）。仅多选/不定项点选时调用；
  /// 调用方把它写进答案字段。不传则点选只活在编辑器内。
  final ValueChanged<String>? onMultiSelectionChanged;

  /// 当前选项文字（表单值；null = 未解析/不显示）。整理页传表单值，
  /// 详情页查看态传库里值。null 时草稿按 detectedOptionContents
  /// 取初始值（见 [_initialContents]）。
  final Map<String, String>? optionContents;

  /// 切分器检测到的选项文字（与 detectedOptionLabels 同款初始值口径；
  /// null/空 = 无检测结果）。只在 optionContents == null 时作初始值，
  /// 永不覆盖库里已存值。
  final Map<String, String>? detectedOptionContents;

  /// 选项文字改动（改写/删位后的完整映射；调用方写进表单值或即时保存）。
  /// 不传则文字只活在编辑器草稿里。
  final ValueChanged<Map<String, String>?>? onOptionContentsChanged;

  @override
  State<AnswerOptionEditor> createState() => _AnswerOptionEditorState();
}

class _AnswerOptionEditorState extends State<AnswerOptionEditor> {
  late List<String> _draftLabels;
  String? _draftCorrect;

  /// Win11 反馈包 5：选项文字草稿（标签 → 文字；判断题恒为空）。
  late Map<String, String> _draftContents;

  /// 正在编辑文字的选项位（null = 都在查看态）；编辑中的文本框用
  /// [_contentCtrl]，切位即重建，不跨位。
  String? _editingContentLabel;
  TextEditingController? _contentCtrl;

  /// S2-1：本编辑会话内用户是否点选过正确答案位。保存时
  /// answerReconfirmed 即取此值；切题重建 state 时清零，不跨题。
  bool _correctTouched = false;

  /// 多选重确认复选框草稿（S2-2：勾选即信号 true）。
  bool _draftReconfirmed = false;

  /// 多选本会话内点选的字母集合（只活在本会话内，初始为空；不从
  /// answer 自由文本反推，见文件头 R1-4）。
  final Set<String> _multiSelected = {};

  /// §1.4 初始值是否已上报过（只报一次）。
  bool _initialReported = false;

  /// Win11 反馈包 5：检测到的选项文字是否已上报过（只报一次）。
  bool _contentsInitialReported = false;

  bool get _isSingle => widget.questionType == 'choice_single';
  bool get _isMulti =>
      widget.questionType == 'choice_multi' ||
      widget.questionType == 'choice_variable';
  bool get _isTrueFalse => widget.questionType == 'true_false';
  bool get _isChoice => _isSingle || _isMulti || _isTrueFalse;
  bool get _isChoiceNonTF => _isSingle || _isMulti;

  /// 本次编辑是否改了标签（草稿与库里值比较；增删位都算改）。
  /// 判断题无可编辑标签，恒为 false。
  bool get _labelsChanged =>
      _isTrueFalse
          ? false
          : !sameOptionLabels(_draftLabels, widget.storedOptionLabels);

  List<String> _initialLabels() {
    final stored = widget.optionLabels;
    if (stored != null) return List.of(stored);
    if (_isTrueFalse) return const [];
    final detected = widget.detectedOptionLabels;
    if (detected != null && detected.isNotEmpty) {
      return List.of(detected);
    }
    if (_isChoiceNonTF) return List.of(_defaultOptionLabels);
    return const [];
  }

  /// Win11 反馈包 5：选项文字初始值——库里已存的优先；没有时用
  /// 检测结果；都没有时为空映射（各行显示“暂无选项文字”）。
  /// 判断题恒为空（固定“正确/错误”，不走选项解析）。
  /// 必须返回可变映射（删位/编辑会原地改 _draftContents；const {}
  /// 会在 _deleteLabel 里抛 UnsupportedError）。
  Map<String, String> _initialContents() {
    if (_isTrueFalse) return <String, String>{};
    final stored = widget.optionContents;
    if (stored != null) return Map<String, String>.of(stored);
    final detected = widget.detectedOptionContents;
    if (detected != null && detected.isNotEmpty) {
      return Map<String, String>.of(detected);
    }
    return <String, String>{};
  }

  @override
  void initState() {
    super.initState();
    _draftLabels = _initialLabels();
    _draftContents = _initialContents();
    _draftCorrect = widget.correctOption;
    _draftReconfirmed = widget.answerReconfirmed;
    _maybeReportInitialLabels();
    _maybeReportInitialContents();
  }

  @override
  void dispose() {
    _contentCtrl?.dispose();
    super.dispose();
  }

  /// Win11 反馈包 5：首次进入且 optionContents == null 时，检测到的
  /// 选项文字上报一次（上报给调用方，由调用方表单值落盘）。只报一次；
  /// 上报时父级若已有值（别的路径先写了）则跳过，永不覆盖。
  void _maybeReportInitialContents() {
    if (widget.optionContents != null || _isTrueFalse) return;
    final detected = widget.detectedOptionContents;
    if (detected == null || detected.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _contentsInitialReported) return;
      if (widget.optionContents != null) return;
      _contentsInitialReported = true;
      widget.onOptionContentsChanged?.call(Map<String, String>.of(detected));
    });
  }

  /// Win11 反馈包 5：选项文字草稿改动即上报（调用方写进表单值或
  /// 即时保存；编辑中每键一报，调用方只改内存表单值、不写库——
  /// 详情查看态的即时保存只在编辑完成（点 ✓）时触发，见
  /// [_finishEditingContent]）。
  void _reportContents() {
    widget.onOptionContentsChanged?.call(Map<String, String>.of(_draftContents));
  }

  /// 开始编辑某位的选项文字：为该位建文本框控制器（当前文字作初值）。
  void _startEditingContent(String letter) {
    _contentCtrl?.dispose();
    _contentCtrl = TextEditingController(text: _draftContents[letter] ?? '');
    setState(() => _editingContentLabel = letter);
  }

  /// 完成编辑某位的选项文字：退出编辑态；即时保存模式下立即保存
  /// （与正确选项点选同款口径）。
  void _finishEditingContent() {
    _contentCtrl?.dispose();
    _contentCtrl = null;
    setState(() => _editingContentLabel = null);
    if (widget.correctOptionSavesImmediately) {
      _confirmNow();
    }
  }

  /// §1.4：首次进入且 optionLabels == null 时，初始值写入一次
  /// （上报给调用方，由调用方表单值落盘）。只报一次；上报时父级
  /// 若已有值（别的路径先写了）则跳过，永不覆盖。
  void _maybeReportInitialLabels() {
    if (widget.optionLabels != null || !_isChoiceNonTF) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _initialReported) return;
      if (widget.optionLabels != null) return;
      _initialReported = true;
      widget.onLabelsChanged(List.of(_draftLabels));
    });
  }

  @override
  void didUpdateWidget(AnswerOptionEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.questionId != oldWidget.questionId) {
      // 切题：草稿按新题重建，信号强制清零，不跨题。
      _draftLabels = _initialLabels();
      _draftContents = _initialContents();
      _draftCorrect = widget.correctOption;
      _correctTouched = false;
      _draftReconfirmed = widget.answerReconfirmed;
      _multiSelected.clear();
      _initialReported = false;
      _contentsInitialReported = false;
      _editingContentLabel = null;
      _contentCtrl?.dispose();
      _contentCtrl = null;
      _maybeReportInitialLabels();
      _maybeReportInitialContents();
      return;
    }
    // 外部标签值变了（非本编辑器发起）→ 同步草稿；本编辑器自己的
    // 改动回显回来时值相同，不动。父级仍为 null 时不动草稿（初始
    // 默认值只活在草稿里，等上报后父级即有值）。
    final external = widget.optionLabels;
    if (external != null && !sameOptionLabels(external, _draftLabels)) {
      _draftLabels = List.of(external);
    }
    // 外部选项文字变了（非本编辑器发起）→ 同步草稿；本编辑器自己的
    // 改动回显回来时值相同，不动。父级仍为 null 时不动草稿。
    final externalContents = widget.optionContents;
    if (externalContents != null &&
        !_sameContents(externalContents, _draftContents)) {
      _draftContents = Map<String, String>.of(externalContents);
    }
    if (widget.correctOption != _draftCorrect) {
      _draftCorrect = widget.correctOption;
    }
    if (_isMulti) {
      if (widget.answerReconfirmed != _draftReconfirmed) {
        _draftReconfirmed = widget.answerReconfirmed;
      }
    } else if (widget.answerReconfirmed) {
      // 单选/判断：父级信号为 true 说明本会话内点过正确答案位。
      _correctTouched = true;
    }
  }

  /// 选项文字映射按值比较（键序不同不算变）。
  bool _sameContents(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  /// 即时保存（详情查看态）：草稿原样带上，confirmLabels 恒 false
  /// （保持库里原确认状态，编辑器不再写确认列）。
  void _confirmNow() {
    widget.onConfirm(
      labels: _isTrueFalse
          ? widget.optionLabels
          : (_draftLabels.isEmpty ? null : List.of(_draftLabels)),
      correctOption: _draftCorrect,
      answerReconfirmed: _isMulti ? _draftReconfirmed : _correctTouched,
      confirmLabels: false,
    );
  }

  /// 标签增删后的公共收尾：上报新标签；多选复选框信号失效（D-152）；
  /// 即时模式下按规则立即保存（多选旧答案未复核时先不存，等勾选）。
  void _afterLabelsChanged() {
    widget.onLabelsChanged(
      _draftLabels.isEmpty ? null : List.of(_draftLabels),
    );
    if (_isMulti && _draftReconfirmed) {
      setState(() => _draftReconfirmed = false);
      widget.onAnswerReconfirmedChanged(false);
    }
    if (widget.correctOptionSavesImmediately) {
      if (_isMulti &&
          _labelsChanged &&
          widget.hadOldAnswer &&
          !_draftReconfirmed) {
        return;
      }
      _confirmNow();
    }
  }

  void _addLabel() {
    final next = _nextOptionLabel(_draftLabels);
    if (next == null) return;
    setState(() => _draftLabels = [..._draftLabels, next]);
    _afterLabelsChanged();
  }

  void _deleteLabel(String letter) {
    final wasCorrect = _draftCorrect == letter;
    final hadTouch = _correctTouched;
    final selectionChanged = _multiSelected.remove(letter);
    // Win11 反馈包 5：删位时对应选项文字键一并去掉（只动对应键）。
    final hadContent = _draftContents.remove(letter) != null;
    if (_editingContentLabel == letter) {
      _editingContentLabel = null;
      _contentCtrl?.dispose();
      _contentCtrl = null;
    }
    setState(() {
      _draftLabels = _draftLabels.where((e) => e != letter).toList();
      if (wasCorrect) {
        // 被删的是正确答案位：清空，并提示重新选定（走无效态）。
        _draftCorrect = null;
        _correctTouched = false;
      }
    });
    if (hadContent) _reportContents();
    if (wasCorrect) {
      widget.onCorrectOptionChanged(null);
      if (hadTouch) widget.onAnswerReconfirmedChanged(false);
    }
    if (_isMulti && selectionChanged) {
      widget.onMultiSelectionChanged?.call(_orderedMultiSelection());
    }
    _afterLabelsChanged();
  }

  String _orderedMultiSelection() =>
      _draftLabels.where(_multiSelected.contains).join(',');

  void _pickCorrect(String value) {
    setState(() {
      _draftCorrect = value;
      // 点选正确选项即重确认（D-133 / S2-1：本次会话内点选过）。
      _correctTouched = true;
    });
    widget.onCorrectOptionChanged(value);
    widget.onAnswerReconfirmedChanged(true);
    if (widget.correctOptionSavesImmediately) {
      _confirmNow();
    }
  }

  void _toggleMulti(String letter) {
    setState(() {
      if (_multiSelected.contains(letter)) {
        _multiSelected.remove(letter);
      } else {
        _multiSelected.add(letter);
      }
    });
    // 多选点选多个走 answer 字段；不写 correctOption、不产生
    // 单选式重确认信号（多选信号只来自复选框，S2-2）。
    widget.onMultiSelectionChanged?.call(_orderedMultiSelection());
  }

  void _onReconfirmCheckbox(bool? value) {
    if (value == null) return;
    setState(() => _draftReconfirmed = value);
    widget.onAnswerReconfirmedChanged(value);
    if (widget.correctOptionSavesImmediately && value && _labelsChanged) {
      // 查看态：勾选即保存，旧答案与解析得以保留（S2-3 带信号保存）。
      _confirmNow();
    }
  }

  /// 单选/判断状态行（§1.3 无效态提示）。
  String get _singleStatus {
    if (widget.answerPendingRecheck && !_labelsChanged) {
      return '正确答案待重新核对：请在下方重新选定正确选项。';
    }
    final correct = _draftCorrect;
    if (correct == null || correct.isEmpty) return '未设正确答案';
    if (_isTrueFalse) {
      return (correct == '正确' || correct == '错误')
          ? '已设正确答案，可客观判分'
          : '正确答案不在选项中';
    }
    if (!_draftLabels.contains(correct)) return '正确答案不在选项中';
    return '已设正确答案，可客观判分';
  }

  /// Win11 反馈包 5：选项文字行只在已解析出选项内容时渲染
  /// （optionContents != null，含空映射 {}——解析过但无内容时
  /// 仍显示“暂无选项文字”行供手动补充）。未解析（null）时不渲染，
  /// 编辑器保持旧高度（无内容的题不凭空变高，底部确认区不被顶出）。
  /// 检测值上报后父级回填 optionContents，下一帧即显示。
  /// Win11 反馈包 1：字母位横排后，文字行是纵向列表，行首标字母。
  bool get _showContentRows => widget.optionContents != null;

  /// 行首字母标（与文字行对齐）。
  Widget _contentRowLetter(String letter, double scale) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Padding(
      padding: EdgeInsets.only(top: 2 * scale, right: 6 * scale),
      child: Text(
        letter,
        style: TextStyle(
          fontSize: DesignTokens.organizeFieldFontSize,
          fontWeight: FontWeight.w800,
          color: palette.ink2,
          height: DesignTokens.bodyLineHeight,
        ),
      ),
    );
  }

  /// Win11 反馈包 5：某一位的选项文字行。
  /// - 查看态：有文字时按 [parseQuestionContent] +
  ///   [QuestionContentRenderer] 渲染（公式按 LaTeX 渲染，不外露源码）；
  ///   无文字时显示“暂无选项文字”；行尾都是编辑按钮。
  /// - 编辑态：文本框（初值是当前文字；每键一报草稿给调用方），
  ///   行尾 ✓ 退出编辑态；即时保存模式下退出即保存。
  Widget _optionContentRow(String letter, double scale) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final content = _draftContents[letter] ?? '';
    if (_editingContentLabel == letter) {
      return Padding(
        padding: EdgeInsets.only(top: 4 * scale),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _contentRowLetter(letter, scale),
            Expanded(
              child: TextField(
                controller: _contentCtrl,
                autofocus: true,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(
                  hintText: '输入选项文字（公式用 \$...\$）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (value) {
                  _draftContents[letter] = value;
                  _reportContents();
                },
                onSubmitted: (_) => _finishEditingContent(),
              ),
            ),
            IconButton(
              tooltip: '保存选项 $letter 文字',
              icon: const Icon(Icons.check),
              onPressed: _finishEditingContent,
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(top: 4 * scale),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _contentRowLetter(letter, scale),
          Expanded(
            child: content.trim().isEmpty
                ? Text(
                    '暂无选项文字',
                    style: TextStyle(
                      fontSize: DesignTokens.captionFontSize,
                      color: palette.muted,
                      height: DesignTokens.bodyLineHeight,
                    ),
                  )
                : QuestionContentRenderer(
                    blocks: parseQuestionContent(content),
                  ),
          ),
          IconButton(
            tooltip: '编辑选项 $letter 文字',
            icon: const Icon(Icons.edit_outlined, size: 18),
            onPressed: () => _startEditingContent(letter),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isChoice) return const SizedBox.shrink();
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    final rows =
        _isTrueFalse ? _trueFalseOptions : _draftLabels;
    final nextLabel = _nextOptionLabel(_draftLabels);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _isMulti ? '选项' : '正确答案',
          style: TextStyle(
            fontSize: DesignTokens.organizeFieldFontSize,
            fontWeight: FontWeight.w700,
            color: palette.ink2,
            height: 1.2,
          ),
        ),
        SizedBox(height: 5 * scale),
        if (_isTrueFalse)
          Text(
            '判断题选项固定为「正确 / 错误」，无需增删。',
            style: TextStyle(
              fontSize: DesignTokens.captionFontSize,
              color: palette.muted,
              height: DesignTokens.bodyLineHeight,
            ),
          ),
        if (_isMulti)
          Text(
            '点选多个字母，拼成多选答案（如 AB）。',
            style: TextStyle(
              fontSize: DesignTokens.captionFontSize,
              color: palette.muted,
              height: DesignTokens.bodyLineHeight,
            ),
          ),
        SizedBox(height: 5 * scale),
        if (_isChoiceNonTF && _draftLabels.isEmpty)
          Padding(
            padding: EdgeInsets.only(bottom: 5 * scale),
            child: Text(
              '还没有选项标签：点「+」添加第一位。',
              style: TextStyle(
                fontSize: DesignTokens.captionFontSize,
                color: palette.muted,
                height: DesignTokens.bodyLineHeight,
              ),
            ),
          ),
        // Win11 反馈包 1：字母位改小尺寸横向 chip（Wrap，超宽换行；
        // chip 上带小 × 删除——QmChip 可删除双区形态，点片身点选、
        // 点 × 删除）。5 个（A–E）甚至更多位时自动换行，不挤出容器。
        Wrap(
          spacing: 6 * scale,
          runSpacing: 6 * scale,
          children: [
            for (final letter in rows)
              QmChip(
                label: letter,
                selected: _isMulti
                    ? _multiSelected.contains(letter)
                    : _draftCorrect == letter,
                // Win11 反馈 Q3：答案芯片按选中画空闲态（未选白、已选蓝）。
                selectionAwareDeletable: true,
                onTap: () => _isMulti
                    ? _toggleMulti(letter)
                    : _pickCorrect(letter),
                onDelete:
                    _isChoiceNonTF ? () => _deleteLabel(letter) : null,
                deleteTooltip:
                    _isChoiceNonTF ? '删除选项 $letter' : null,
              ),
          ],
        ),
        // Win11 反馈包 5：各选项位的文字行（判断题没有；未解析出
        // 内容时不渲染，见 _showContentRows）。字母位横排后，文字
        // 行改纵向列表、行首标字母，跟在芯片区下方。
        if (_isChoiceNonTF && _showContentRows) ...[
          SizedBox(height: 6 * scale),
          for (final letter in rows) _optionContentRow(letter, scale),
        ],
        if (_isChoiceNonTF) ...[
          SizedBox(height: 2 * scale),
          QmButton(
            label: '+ 添加选项',
            size: QmButtonSize.small,
            variant: QmButtonVariant.primary,
            onPressed: nextLabel == null ? null : _addLabel,
          ),
          SizedBox(height: 8 * scale),
        ],
        // P1-A：多选改标签，旧答案待重新核对。
        if (_isMulti && _labelsChanged && widget.hadOldAnswer) ...[
          const QmBanner(
            tone: QmBannerTone.warning,
            message:
                '选项标签已改：旧答案与解析待重新核对。不确认就保存，旧答案与解析会被清空，并标记「标准答案待重新核对」。',
          ),
          SizedBox(height: 6 * scale),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: _draftReconfirmed,
                onChanged: _onReconfirmCheckbox,
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    '确认此答案和解析仍有效',
                    style: TextStyle(
                      fontSize: DesignTokens.organizeFieldFontSize,
                      color: palette.ink2,
                    ),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 4 * scale),
        ],
        // 待核对标记（多选：标签本次没改，但库里仍挂着标记时）。
        if (_isMulti && !_labelsChanged && widget.answerPendingRecheck) ...[
          const QmBanner(
            tone: QmBannerTone.warning,
            message: '标准答案待重新核对：请在答案区重新填写或确认，保存后恢复。',
          ),
          SizedBox(height: 8 * scale),
        ],
        if (_isMulti && _draftLabels.isNotEmpty && _draftLabels.length < 2)
          Padding(
            padding: EdgeInsets.only(bottom: 4 * scale),
            child: Text(
              '选项不足：至少需要两个选项位。',
              style: TextStyle(
                fontSize: DesignTokens.captionFontSize,
                color: palette.muted,
                height: DesignTokens.bodyLineHeight,
              ),
            ),
          ),
        if (_isSingle || _isTrueFalse)
          Text(
            _singleStatus,
            style: TextStyle(
              fontSize: DesignTokens.captionFontSize,
              color: palette.muted,
              height: DesignTokens.bodyLineHeight,
            ),
          ),
      ],
    );
  }
}

/// 旧名兼容包装：与 [AnswerOptionEditor] 同一实现，仅保留旧调用方
/// （整理页、详情页）的构造参数 shape。`optionLabelsConfirmed` 与
/// `confirmLabel` 只为源码兼容而接受：REV5 起确认列不再读写、确认
/// 按钮已移除，两者不再产生任何效果。新代码直接用 [AnswerOptionEditor]。
class OptionLabelsEditor extends StatelessWidget {
  const OptionLabelsEditor({
    super.key,
    required this.questionId,
    required this.questionType,
    required this.optionLabels,
    required this.storedOptionLabels,
    required this.optionLabelsConfirmed,
    required this.correctOption,
    required this.storedCorrectOption,
    required this.answerPendingRecheck,
    required this.hadOldAnswer,
    required this.answerReconfirmed,
    required this.onLabelsChanged,
    required this.onCorrectOptionChanged,
    required this.onAnswerReconfirmedChanged,
    required this.onConfirm,
    this.correctOptionSavesImmediately = false,
    this.confirmLabel = '确认选项',
    // Win11 反馈包 5：选项文字（与 AnswerOptionEditor 同款口径）。
    this.optionContents,
    this.detectedOptionContents,
    this.onOptionContentsChanged,
  });

  final String questionId;
  final String? questionType;
  final List<String>? optionLabels;
  final List<String>? storedOptionLabels;

  /// 兼容保留：REV5 起不再读取。
  final bool optionLabelsConfirmed;
  final String? correctOption;
  final String? storedCorrectOption;
  final bool answerPendingRecheck;
  final bool hadOldAnswer;
  final bool answerReconfirmed;
  final ValueChanged<List<String>?> onLabelsChanged;
  final ValueChanged<String?> onCorrectOptionChanged;
  final ValueChanged<bool> onAnswerReconfirmedChanged;
  final void Function({
    required List<String>? labels,
    required String? correctOption,
    required bool answerReconfirmed,
    required bool confirmLabels,
  }) onConfirm;
  final bool correctOptionSavesImmediately;

  /// Win11 反馈包 5：选项文字（见 [AnswerOptionEditor.optionContents]）。
  final Map<String, String>? optionContents;
  final Map<String, String>? detectedOptionContents;
  final ValueChanged<Map<String, String>?>? onOptionContentsChanged;

  /// 兼容保留：确认按钮已移除，不再显示。
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    return AnswerOptionEditor(
      key: key,
      questionId: questionId,
      questionType: questionType,
      optionLabels: optionLabels,
      storedOptionLabels: storedOptionLabels,
      correctOption: correctOption,
      storedCorrectOption: storedCorrectOption,
      answerPendingRecheck: answerPendingRecheck,
      hadOldAnswer: hadOldAnswer,
      answerReconfirmed: answerReconfirmed,
      onLabelsChanged: onLabelsChanged,
      onCorrectOptionChanged: onCorrectOptionChanged,
      onAnswerReconfirmedChanged: onAnswerReconfirmedChanged,
      onConfirm: onConfirm,
      correctOptionSavesImmediately: correctOptionSavesImmediately,
      optionContents: optionContents,
      detectedOptionContents: detectedOptionContents,
      onOptionContentsChanged: onOptionContentsChanged,
    );
  }
}
