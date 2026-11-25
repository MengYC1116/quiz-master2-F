// P3 入口 3：薄弱点题目列表页（实施方案 v2 §5，D8）。
//
// 点报告 Top 5 的一行进来：先看题目列表，再决定练多少。
// - 列表题数不限：查询结果全量进页，页面用分页加载（每页 20 道），
//   不一次全渲染；同一题多标签按 question_id 去重（调用方与本页各做一次）；
// - 列表上可勾选（默认全选）；底部主按钮“开始专项练习”，数量给预选项
//   （10/20/全部）+ 自定义输入，自定义超可选数时自动限到可选数；
//   随机抽题与“同一知识点尽量不连续集中”由复习页的
//   pickPracticeQuestions 做，本页只传题单与数量；
// - 次按钮“加入复习”只对勾选的题生效（Meng 已定，按原型来）；
//   已在复习池的题行内标“已在复习”，可立即专项练习，但不重复加入 FSRS。
import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../state/report_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/uikit.dart';

/// 薄弱点题目列表页。
class WeakPointListPage extends StatefulWidget {
  const WeakPointListPage({
    super.key,
    required this.group,
    required this.report,
    required this.questions,
    required this.isKp,
    required this.onStartPractice,
    required this.onJoinReview,
    this.onOpenInWrongbook,
  });

  /// 点进来的薄弱点组（学科 × 错因 / 学科 × 知识点）。
  final WeakGroup group;

  /// 报告状态（样本统计、学科名、知识点名用）。
  final ReportState report;

  /// 该组的题（调用方已按 question_id 去重；本页再去重一次兜底）。
  final List<Question> questions;

  /// true = 知识点组，false = 错因组。
  final bool isKp;

  /// 开始专项练习（题 id + 数量；数量 <= 0 表示全部）。
  final void Function(List<String> questionIds, {int? count})
  onStartPractice;

  /// 加入复习（只对勾选的题生效）；返回结果文案，本页展示。
  final Future<String> Function(List<String> questionIds) onJoinReview;

  /// 在错题本中查看（旧深链路，保留作次入口；可空）。
  final VoidCallback? onOpenInWrongbook;

  @override
  State<WeakPointListPage> createState() => _WeakPointListPageState();
}

class _WeakPointListPageState extends State<WeakPointListPage> {
  /// 每页题数（分页加载，不一次全渲染）。
  static const int pageSize = 20;

  late final List<Question> _questions;
  late Set<String> _selected;
  int _page = 0;

  /// 数量预选项：10 / 20 / 0（全部）。默认 10 道。
  int _countPreset = 10;
  final _customCountCtrl = TextEditingController();
  String? _joinMessage;

  @override
  void initState() {
    super.initState();
    // 按 question_id 去重（同一题多标签只出现一次），保序。
    final seen = <String>{};
    _questions = [
      for (final q in widget.questions)
        if (seen.add(q.id)) q,
    ];
    _selected = {for (final q in _questions) q.id};
  }

  @override
  void dispose() {
    _customCountCtrl.dispose();
    super.dispose();
  }

  int get _totalPages =>
      (_questions.length / pageSize).ceil().clamp(1, 9999);

  List<Question> get _pageItems {
    final page = _page.clamp(0, _totalPages - 1);
    return _questions.skip(page * pageSize).take(pageSize).toList();
  }

  /// 本次练习题数：自定义输入优先（超可选数时自动限到可选数），
  /// 否则按预选项；“全部”即全部勾选数。
  int get _effectiveCount {
    final custom = int.tryParse(_customCountCtrl.text.trim());
    if (custom != null) {
      if (custom <= 0) return _selected.length;
      return custom.clamp(0, _selected.length);
    }
    if (_countPreset <= 0) return _selected.length;
    return _countPreset.clamp(0, _selected.length);
  }

  void _toggle(String id, bool value) {
    setState(() {
      if (value) {
        _selected.add(id);
      } else {
        _selected.remove(id);
      }
    });
  }

  void _togglePage(bool value) {
    setState(() {
      if (value) {
        _selected.addAll(_pageItems.map((q) => q.id));
      } else {
        for (final q in _pageItems) {
          _selected.remove(q.id);
        }
      }
    });
  }

  Future<void> _joinReview() async {
    if (_selected.isEmpty) return;
    final message = await widget.onJoinReview(_selected.toList());
    if (!mounted) return;
    setState(() => _joinMessage = message);
  }

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final group = widget.group;
    final report = widget.report;
    final stats = report.weakStats(group);
    final subject = report.subjectOf(group.subjectId);
    final title = widget.isKp
        ? report.kpName(group.key)
        : group.key;
    final pageItems = _pageItems;
    final page = _page.clamp(0, _totalPages - 1);
    final selectedCount = _selected.length;
    final pageChecked =
        pageItems.isNotEmpty &&
        pageItems.every((q) => _selected.contains(q.id));
    return Scaffold(
      appBar: AppBar(
        title: Text('${subject.name} · $title'),
      ),
      body: SingleChildScrollView(
        padding: DesignTokens.scaled(scale).contentPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${subject.name} · $title',
              key: const Key('weak-list-title'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            SizedBox(height: 8 * scale),
            Text(
              stats.label,
              key: const Key('weak-sample-label'),
              style: TextStyle(
                fontSize: DesignTokens.bodySmallFontSize,
                color: palette.muted,
              ),
            ),
            SizedBox(height: 4 * scale),
            Row(
              children: [
                Text(
                  stats.sourceLabel,
                  style: TextStyle(
                    fontSize: DesignTokens.bodySmallFontSize,
                    color: palette.muted,
                  ),
                ),
                if (stats.sparse) ...[
                  SizedBox(width: 8 * scale),
                  Container(
                    key: const Key('weak-sparse-tag'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF4D6),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      '数据较少',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF8A6D00),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            if (widget.onOpenInWrongbook != null) ...[
              SizedBox(height: 8 * scale),
              QmButton(
                label: '在错题本中查看',
                variant: QmButtonVariant.secondary,
                size: QmButtonSize.small,
                onPressed: widget.onOpenInWrongbook,
              ),
            ],
            SizedBox(height: 14 * scale),
            Row(
              children: [
                Checkbox(
                  value: pageChecked,
                  onChanged: (v) => _togglePage(v == true),
                ),
                GestureDetector(
                  onTap: () => _togglePage(!pageChecked),
                  child: const Text(
                    '勾选当前页',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                SizedBox(width: 12 * scale),
                Text(
                  '已选 ${_selected.length} 道',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            SizedBox(height: 8 * scale),
            if (_questions.isEmpty)
              const QmEmptyState(
                title: '这组里没有题目',
                description: '这组薄弱点下没有可练的题，换一组试试。',
              )
            else
              for (final q in pageItems)
                _WeakQuestionRow(
                  question: q,
                  checked: _selected.contains(q.id),
                  inPool: report.fsrsPoolIds.contains(q.id),
                  onChanged: (v) => _toggle(q.id, v == true),
                ),
            if (_totalPages > 1) ...[
              SizedBox(height: 12 * scale),
              Row(
                children: [
                  Text(
                    '共 ${_questions.length} 道 · 第 ${page + 1} / $_totalPages 页',
                    key: const Key('weak-page-label'),
                    style: TextStyle(
                      fontSize: DesignTokens.pagerFontSize,
                      color: palette.muted,
                    ),
                  ),
                  const Spacer(),
                  QmButton(
                    label: '上一页',
                    size: QmButtonSize.small,
                    variant: QmButtonVariant.secondary,
                    onPressed: page > 0
                        ? () => setState(() => _page = page - 1)
                        : null,
                  ),
                  SizedBox(width: 6 * scale),
                  QmButton(
                    label: '下一页',
                    size: QmButtonSize.small,
                    variant: QmButtonVariant.secondary,
                    onPressed: page < _totalPages - 1
                        ? () => setState(() => _page = page + 1)
                        : null,
                  ),
                ],
              ),
            ],
            SizedBox(height: 16 * scale),
            const Text(
              '练多少道',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 6 * scale),
            Wrap(
              spacing: 10 * scale,
              runSpacing: 8 * scale,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final n in [10, 20, 0])
                  QmButton(
                    label: n == 0 ? '全部' : '$n 道',
                    size: QmButtonSize.small,
                    variant: _countPreset == n && _customCountCtrl.text.isEmpty
                        ? QmButtonVariant.primary
                        : QmButtonVariant.secondary,
                    onPressed: () => setState(() {
                      _countPreset = n;
                      _customCountCtrl.clear();
                    }),
                  ),
                SizedBox(
                  width: 110 * scale,
                  child: TextField(
                    key: const Key('weak-custom-count'),
                    controller: _customCountCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      hintText: '自定义数量',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            SizedBox(height: 8 * scale),
            Text(
              '将练习 $_effectiveCount 道（共可选 $selectedCount 道）',
              key: const Key('weak-practice-count'),
              style: TextStyle(
                fontSize: DesignTokens.bodySmallFontSize,
                color: palette.muted,
              ),
            ),
            SizedBox(height: 12 * scale),
            Wrap(
              spacing: 8 * scale,
              runSpacing: 8 * scale,
              children: [
                QmButton(
                  label: '开始专项练习',
                  onPressed: _selected.isEmpty
                      ? null
                      : () => widget.onStartPractice(
                          _selected.toList(),
                          count: _effectiveCount,
                        ),
                ),
                QmButton(
                  label: '加入复习',
                  variant: QmButtonVariant.secondary,
                  onPressed: _selected.isEmpty ? null : _joinReview,
                ),
              ],
            ),
            if (_joinMessage != null) ...[
              SizedBox(height: 8 * scale),
              Text(
                _joinMessage!,
                key: const Key('weak-join-message'),
                style: TextStyle(
                  fontSize: DesignTokens.bodySmallFontSize,
                  color: palette.ink,
                ),
              ),
            ],
            SizedBox(height: 24 * scale),
          ],
        ),
      ),
    );
  }
}

class _WeakQuestionRow extends StatelessWidget {
  const _WeakQuestionRow({
    required this.question,
    required this.checked,
    required this.inPool,
    required this.onChanged,
  });

  final Question question;
  final bool checked;
  final bool inPool;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Container(
      padding: EdgeInsets.symmetric(vertical: 4 * scale),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            key: ValueKey('weak-row-${question.id}'),
            value: checked,
            onChanged: onChanged,
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: 12 * scale),
              child: Text(
                question.title,
                style: TextStyle(
                  fontSize: DesignTokens.bodySmallFontSize,
                  color: palette.ink,
                ),
              ),
            ),
          ),
          if (inPool)
            Padding(
              padding: EdgeInsets.only(top: 12 * scale),
              child: Text(
                '已在复习',
                key: ValueKey('weak-in-review-${question.id}'),
                style: TextStyle(
                  fontSize: 12,
                  color: Color(0xFF0B7A55),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
