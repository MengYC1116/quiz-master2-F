// WP-A #1（九项修复 REV5 §1 + R1 + S2）：答案区选项编辑器。
//
// REV5 起：删除标签文本框与「确认选项」按钮，改为答案区内置的
// [AnswerOptionEditor]：选项位纵向排列，每位一行 = 标签字母（不可改
// 字母本身，只能增删位）+ 正确答案点选；D 位后一个「+」按钮，点一下
// 追加下一字母（E、F……按字母表顺序）。
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

  @override
  State<AnswerOptionEditor> createState() => _AnswerOptionEditorState();
}

class _AnswerOptionEditorState extends State<AnswerOptionEditor> {
  late List<String> _draftLabels;
  String? _draftCorrect;

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

  @override
  void initState() {
    super.initState();
    _draftLabels = _initialLabels();
    _draftCorrect = widget.correctOption;
    _draftReconfirmed = widget.answerReconfirmed;
    _maybeReportInitialLabels();
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
      _draftCorrect = widget.correctOption;
      _correctTouched = false;
      _draftReconfirmed = widget.answerReconfirmed;
      _multiSelected.clear();
      _initialReported = false;
      _maybeReportInitialLabels();
      return;
    }
    // 外部标签值变了（非本编辑器发起）→ 同步草稿；本编辑器自己的
    // 改动回显回来时值相同，不动。父级仍为 null 时不动草稿（初始
    // 默认值只活在草稿里，等上报后父级即有值）。
    final external = widget.optionLabels;
    if (external != null && !sameOptionLabels(external, _draftLabels)) {
      _draftLabels = List.of(external);
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
    setState(() {
      _draftLabels = _draftLabels.where((e) => e != letter).toList();
      if (wasCorrect) {
        // 被删的是正确答案位：清空，并提示重新选定（走无效态）。
        _draftCorrect = null;
        _correctTouched = false;
      }
    });
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
            '多选正确答案写在答案区。',
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
        for (final letter in rows)
          Padding(
            padding: EdgeInsets.only(bottom: 6 * scale),
            child: Row(
              children: [
                Expanded(
                  child: QmChip(
                    label: letter,
                    selected: _isMulti
                        ? _multiSelected.contains(letter)
                        : _draftCorrect == letter,
                    onTap: () => _isMulti
                        ? _toggleMulti(letter)
                        : _pickCorrect(letter),
                  ),
                ),
                if (_isChoiceNonTF) ...[
                  SizedBox(width: 8 * scale),
                  IconButton(
                    tooltip: '删除选项 $letter',
                    icon: const Icon(Icons.close),
                    onPressed: () => _deleteLabel(letter),
                  ),
                ],
              ],
            ),
          ),
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
    );
  }
}
