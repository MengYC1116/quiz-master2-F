// 十四批 M3：选项标签确认编辑器（整理页与详情页共用）。
//
// M3-4：A–D 只作默认预填的候选值，不是已确认的标签。选项标签及数量
// 必须由用户在题型区确认并保存（点「确认选项」），option_labels_confirmed
// 置 1，才能开启客观判分。correct_option 只用于单选与判断题；多选/
// 不定项不使用 correct_option（置 NULL），正确答案走 answer 字段。
// 判断题标签固定为「正确 / 错误」，不显示标签编辑器与「确认选项」。
//
// 本 widget 只管展示与草稿：标签文本框的草稿、正确选项的点选、
// P1-A 待核对提示与重确认复选框都活在本 widget 的 state 里；
// 落盘由调用方做——整理页是表单式（只改表单值，「确认选项」才落盘），
// 详情页查看态是即时保存式（正确选项点选立即保存，标签改动点
// 「确认选项」保存）。调用方 key 必须按题挂（ValueKey(questionId)），
// 切题后草稿随题重建。
//
// 正确选项点选即带重确认信号（answerReconfirmed=true，见 D-133）：
// 单选只改标签顺序后，重新选定同一标签也须带该信号才恢复判分。
//
// D-152（P1-1，GPT fix2 窄审 §3）：重确认信号只对“最后一次标签变化
// 之后”的确认有效。编辑器跟踪上一次已解析的标签列表；解析后标签
// 列表发生语义变化时，立即把 _draftReconfirmed 置回 false 并通知
// 调用方（onAnswerReconfirmedChanged(false)）。仅空格、分隔符格式
// 变化、解析结果相同时不重置。单选重排后须重新点选正确选项、多选/
// 不定项须在最后一次标签变化之后重新勾选复选框，才能再次产生信号。

import 'package:flutter/material.dart';

import '../../theme/design_tokens.dart';
import '../../widgets/uikit.dart';

/// 解析逗号分隔的选项标签：按 `[,，、；;\s]+` 切分、去空、去重保序。
/// 空串返回 null（= 未确认）。
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

/// 选项标签确认编辑器。
class OptionLabelsEditor extends StatefulWidget {
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

  /// 当前题 id（调用方 key 也按它挂；变了草稿重建）。
  final String questionId;

  /// 当前题型（表单值；非选择/判断题型时本编辑器不渲染）。
  final String? questionType;

  /// 当前标签（表单值；null = 未确认）。整理页传表单值，详情页查看态
  /// 传库里值（无表单态，草稿只活在编辑器内）。
  final List<String>? optionLabels;

  /// 库里存的标签（P1-A「本次是否改了标签」按草稿与它比较）。
  final List<String>? storedOptionLabels;

  /// 标签是否已确认（表单值）。
  final bool optionLabelsConfirmed;

  /// 当前正确选项（表单值；单选/判断用）。
  final String? correctOption;

  /// 库里存的正确选项（改标签前的旧值；单选顺序变化提示用）。
  final String? storedCorrectOption;

  /// 库里存的待重新核对标记。
  final bool answerPendingRecheck;

  /// 库里旧答案或解析是否非空（P1-A 多选改标签提示用）。
  final bool hadOldAnswer;

  /// 本次编辑是否已重确认答案（表单值）。
  final bool answerReconfirmed;

  /// 标签改动（解析后的列表；清空为 null）。
  final ValueChanged<List<String>?> onLabelsChanged;

  /// 正确选项改动（点选即带重确认信号，见文件头注释）。
  final ValueChanged<String?> onCorrectOptionChanged;

  /// P1-A 重确认复选框改动。
  final ValueChanged<bool> onAnswerReconfirmedChanged;

  /// 点「确认选项」（或正确选项即时保存）：
  /// 参数是编辑器当前草稿；confirmLabels=true 表示本次把标签置为已确认，
  /// false 表示保持库里原确认状态（正确选项即时保存时用）。
  final void Function({
    required List<String>? labels,
    required String? correctOption,
    required bool answerReconfirmed,
    required bool confirmLabels,
  }) onConfirm;

  /// 正确选项点选后是否立即保存（详情页查看态 true；整理页表单式 false）。
  final bool correctOptionSavesImmediately;

  /// 确认按钮文案（默认「确认选项」）。
  final String confirmLabel;

  @override
  State<OptionLabelsEditor> createState() => _OptionLabelsEditorState();
}

class _OptionLabelsEditorState extends State<OptionLabelsEditor> {
  late final TextEditingController _labelsCtrl;
  late final FocusNode _labelsFocus;
  String? _draftCorrect;
  bool _draftReconfirmed = false;
  // D-152：上一次已解析的标签列表（语义比较用；格式变化不算）。
  // _onLabelsTextChanged 每次解析后拿它比对，语义变化即清重确认信号。
  List<String>? _lastParsedLabels;

  bool get _isSingle => widget.questionType == 'choice_single';
  bool get _isMulti =>
      widget.questionType == 'choice_multi' ||
      widget.questionType == 'choice_variable';
  bool get _isTrueFalse => widget.questionType == 'true_false';
  bool get _isChoice => _isSingle || _isMulti || _isTrueFalse;

  List<String>? get _draftLabels => parseOptionLabels(_labelsCtrl.text);

  /// 本次编辑是否改了标签（草稿与库里值比较；顺序变化也算改）。
  bool get _labelsChanged =>
      !sameOptionLabels(_draftLabels, widget.storedOptionLabels);

  @override
  void initState() {
    super.initState();
    _labelsCtrl = TextEditingController(
      text: (widget.optionLabels ?? const []).join(','),
    );
    _labelsFocus = FocusNode();
    _draftCorrect = widget.correctOption;
    _draftReconfirmed = widget.answerReconfirmed;
    _lastParsedLabels = parseOptionLabels(_labelsCtrl.text);
  }

  @override
  void didUpdateWidget(OptionLabelsEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.questionId != oldWidget.questionId) {
      // 切题：草稿按新题重建。
      _labelsCtrl.text = (widget.optionLabels ?? const []).join(',');
      _draftCorrect = widget.correctOption;
      _draftReconfirmed = widget.answerReconfirmed;
      _lastParsedLabels = parseOptionLabels(_labelsCtrl.text);
      return;
    }
    // 外部值变了且文本框未聚焦时同步（输入中不抢控制器，避免
    // “A,B,” 这类半截输入被格式化回写打断）。外部同步不是用户
    // 本次编辑的标签变化：同步更新 _lastParsedLabels，不清重确认
    // 信号（重确认值本身下面按 widget.answerReconfirmed 同步）。
    if (!_labelsFocus.hasFocus) {
      final formatted = (widget.optionLabels ?? const []).join(',');
      if (_labelsCtrl.text != formatted) {
        _labelsCtrl.text = formatted;
        _lastParsedLabels = parseOptionLabels(formatted);
      }
    }
    if (widget.correctOption != _draftCorrect) {
      _draftCorrect = widget.correctOption;
    }
    if (widget.answerReconfirmed != _draftReconfirmed) {
      _draftReconfirmed = widget.answerReconfirmed;
    }
  }

  @override
  void dispose() {
    _labelsCtrl.dispose();
    _labelsFocus.dispose();
    super.dispose();
  }

  void _onLabelsTextChanged(String text) {
    final parsed = parseOptionLabels(text);
    // D-152（P1-1）：解析后标签列表发生语义变化时，之前产生的重确认
    // 信号立即失效——草稿置 false 并通知调用方把 answerReconfirmed
    // 置回 false；只有信号实际从 true 变 false 时才通知（false→false
    // 不重复回调、不无故标脏）。仅空格、分隔符格式变化、解析结果
    // 相同时不重置。比较用 sameOptionLabels（顺序敏感：重排也算变）。
    if (!sameOptionLabels(parsed, _lastParsedLabels)) {
      _lastParsedLabels = parsed;
      if (_draftReconfirmed) {
        setState(() => _draftReconfirmed = false);
        widget.onAnswerReconfirmedChanged(false);
      }
    }
    if (_draftCorrect != null &&
        parsed != null &&
        !parsed.contains(_draftCorrect)) {
      // 正确选项不在新标签集合里：草稿里清掉，保存时数据层同样失效。
      _draftCorrect = null;
      widget.onCorrectOptionChanged(null);
    }
    widget.onLabelsChanged(parsed);
  }

  void _pickCorrect(String value) {
    setState(() {
      _draftCorrect = value;
      // 点选正确选项即重确认（D-133）。
      _draftReconfirmed = true;
    });
    widget.onCorrectOptionChanged(value);
    widget.onAnswerReconfirmedChanged(true);
    if (widget.correctOptionSavesImmediately) {
      widget.onConfirm(
        labels: _draftLabels,
        correctOption: value,
        answerReconfirmed: true,
        confirmLabels: widget.optionLabelsConfirmed,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isChoice) return const SizedBox.shrink();
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    final labels = _draftLabels;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_isTrueFalse) ...[
          Text(
            '判断题选项固定为「正确 / 错误」，无需确认标签；判分只看下面选的正确答案。',
            style: TextStyle(
              fontSize: DesignTokens.captionFontSize,
              color: palette.muted,
              height: DesignTokens.bodyLineHeight,
            ),
          ),
          SizedBox(height: 8 * scale),
        ] else ...[
          Text(
            '选项标签',
            style: TextStyle(
              fontSize: DesignTokens.organizeFieldFontSize,
              fontWeight: FontWeight.w700,
              color: palette.ink2,
              height: 1.2,
            ),
          ),
          SizedBox(height: 5 * scale),
          TextField(
            controller: _labelsCtrl,
            focusNode: _labelsFocus,
            maxLines: 1,
            decoration: const InputDecoration(
              hintText: '选项标签，用逗号分隔，如 A,B,C,D',
            ),
            onChanged: _onLabelsTextChanged,
          ),
          SizedBox(height: 5 * scale),
          Text(
            (labels == null || labels.isEmpty)
                ? '还没有选项标签：先填标签，再点「确认选项」。'
                : (widget.optionLabelsConfirmed
                    ? '选项标签已确认，可客观判分。'
                    : '选项标签未确认：点「确认选项」后才能客观判分；未确认时复习里不显示选项按钮，走纸上作答。'),
            style: TextStyle(
              fontSize: DesignTokens.captionFontSize,
              color: palette.muted,
              height: DesignTokens.bodyLineHeight,
            ),
          ),
          SizedBox(height: 8 * scale),
          QmButton(
            label: widget.confirmLabel,
            size: QmButtonSize.small,
            variant: QmButtonVariant.primary,
            onPressed: (labels == null || labels.isEmpty)
                ? null
                : () => widget.onConfirm(
                      labels: labels,
                      correctOption: _draftCorrect,
                      answerReconfirmed: _draftReconfirmed,
                      confirmLabels: true,
                    ),
          ),
          SizedBox(height: 8 * scale),
        ],
        // P1-A：多选/不定项改标签，旧答案待重新核对。
        if (_isMulti && _labelsChanged && widget.hadOldAnswer) ...[
          const QmBanner(
            tone: QmBannerTone.warning,
            message: '选项标签已改：旧答案与解析待重新核对。不确认就保存，旧答案与解析会被清空，并标记「标准答案待重新核对」。',
          ),
          SizedBox(height: 6 * scale),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: _draftReconfirmed,
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _draftReconfirmed = v);
                  widget.onAnswerReconfirmedChanged(v);
                },
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
        // P1-A 延伸：单选只改标签顺序，正确答案待重新核对。
        if (_isSingle &&
            _labelsChanged &&
            (widget.storedCorrectOption != null &&
                widget.storedCorrectOption!.isNotEmpty)) ...[
          const QmBanner(
            tone: QmBannerTone.warning,
            message: '选项标签顺序变了：正确答案待重新核对，请在下方重新选定正确选项（选后点「确认选项」保存）。不重新选定就保存，正确答案会被清空。',
          ),
          SizedBox(height: 8 * scale),
        ],
        // 待核对标记（标签本次没改，但库里仍挂着标记时）。
        if (!_labelsChanged && widget.answerPendingRecheck) ...[
          QmBanner(
            tone: QmBannerTone.warning,
            message: _isSingle
                ? '正确答案待重新核对：请在下方重新选定正确选项，选后点「确认选项」保存。'
                : '标准答案待重新核对：请在答案区重新填写或确认，保存后恢复。',
          ),
          SizedBox(height: 8 * scale),
        ],
        if (_isSingle || _isTrueFalse) ...[
          Text(
            '正确答案',
            style: TextStyle(
              fontSize: DesignTokens.organizeFieldFontSize,
              fontWeight: FontWeight.w700,
              color: palette.ink2,
              height: 1.2,
            ),
          ),
          SizedBox(height: 5 * scale),
          Wrap(
            spacing: 8 * scale,
            runSpacing: 8 * scale,
            children: [
              for (final v in _isTrueFalse
                  ? const ['正确', '错误']
                  : (labels ?? const <String>[]))
                QmChip(
                  label: v,
                  selected: _draftCorrect == v,
                  onTap: () => _pickCorrect(v),
                ),
            ],
          ),
          if (_isSingle && (labels == null || labels.isEmpty))
            Padding(
              padding: EdgeInsets.only(top: 5 * scale),
              child: Text(
                '先填选项标签，才能选正确答案。',
                style: TextStyle(
                  fontSize: DesignTokens.captionFontSize,
                  color: palette.muted,
                ),
              ),
            ),
        ],
      ],
    );
  }
}
