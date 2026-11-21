// 十五批 M3：D-168 三步向导 + 进度 / 取消 / 完成界面（PLAN-15-REV3 §6，
// M1-DESIGN.md §2/§5；入口在书架页顶栏「新建导出单」，D-169）。
//
// - 向导单次使用：退出即丢弃本次选择，不保存、不做导出历史；可跨文件
//   夹与多学科；导出 = 选定题目集合的全部结果（不只导当页）。
// - 第 1 步选范围：复用错题本现有筛选条件（学科 / 文件夹 / 考试 /
//   错因 / 知识点 / 时间），实时显示圈定题数；默认路径 = 打开向导时
//   的当前筛选结果（filteredAll() 快照）。
// - 第 2 步挑题：搜索、分页、逐题勾选，翻页换筛选不丢已选，默认全选
//   圈定范围；50 道上限（M1-DESIGN §2 第 1–2 点）：点选第 51 道拒绝 +
//   提示，全选 = 前 50 道 + 明示，确认前断言 selected.length <= 50。
// - 第 3 步确认导出：范围摘要、路线明示、版本、纸张（A4 纵向固定）、
//   文件名、提醒清单；guard 软警告明示、硬拒绝阻断；跳过数 > 20 或
//   > 50% 二次确认。点「生成」后冻结快照并开始生成；面板关闭不取消
//   生成（生成在后台跑，完成时由 [ExportWizardSession] 再次弹出
//   完成界面）。
// - 完成界面：逐份文件成功 / 失败状态（P1-5，不得把部分成功伪装成
//   全部成功）+ 完整性报告摘要 + 警告清单展开；Windows「打开文件 /
//   打开所在文件夹」，Android 只出「分享」（无内置打开通道，见
//   pdf_delivery.dart；如需独立「打开 PDF」按钮，另批加依赖）。
// - 风格：沿用 minimalist × professional + 年轻学习伙伴感（现有
//   主题与组件，不引入卡片堆叠 / 数据墙 / 渐变 / 玻璃拟态）。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/app_theme.dart';
import '../../widgets/uikit.dart';
import '../../services/pdf_export/export_filename.dart';
import '../../services/pdf_export/export_flow.dart';
import '../../services/pdf_export/export_integrity.dart';
import '../../services/pdf_export/export_inventory.dart';
import '../../services/pdf_export/export_route.dart';
import '../../services/pdf_export/export_scope.dart';
import '../../services/pdf_export/export_snapshot.dart';
import '../../services/pdf_export/export_versions.dart';
import '../../services/pdf_export/pdf_delivery.dart';

/// 向导输入（打开时拍下的快照；生成过程中用户改筛选 / 改题均不影响
/// 本次导出——向导只用这份输入，不再读错题本状态）。
class ExportWizardInput {
  const ExportWizardInput({
    required this.questions,
    required this.subjects,
    required this.folders,
    required this.exams,
    required this.kps,
    required this.causeNames,
    this.sortText = '时间新→旧',
  });

  /// 当前筛选结果（filteredAll() 在打开瞬间的返回值）。
  final List<Question> questions;

  /// 全部学科（范围下拉用）。
  final List<Subject> subjects;

  /// 全部文件夹（范围下拉 + 文件夹名展示用）。
  final List<Folder> folders;

  /// 全部考试（范围下拉用）。
  final List<Exam> exams;

  /// 全部知识点（范围下拉用）。
  final List<KnowledgePoint> kps;

  /// 错因名（固定枚举 + 本次范围内的自定义错因）。
  final List<String> causeNames;

  /// 排序文案（PDF 信息区用，如“时间新→旧”）。
  final String sortText;
}

/// D-168 三步向导对话框（第 1 步选范围 / 第 2 步挑题 / 第 3 步确认导出，
// 随后是进度与完成界面；由 [ExportWizardSession] 打开与管理）。
class ExportWizardDialog extends StatefulWidget {
  const ExportWizardDialog({
    super.key,
    required this.input,
    required this.controller,
    this.onOpenQuestion,
  });

  /// 向导输入（快照）。
  final ExportWizardInput input;

  /// 流程控制器（盘点 / 生成 / 交付 / 终态；由调用方持有，
  /// 对话框关闭后仍继续跑，直到终态）。
  final ExportFlowController controller;

  /// 跳过 / 可疑清单里点某题：打开详情页纠错 / 补 OCR（可空；
  /// 不传时清单只展示，不可点）。
  final void Function(String questionId)? onOpenQuestion;

  @override
  State<ExportWizardDialog> createState() => _ExportWizardDialogState();
}

class _ExportWizardDialogState extends State<ExportWizardDialog> {
  static const _pageSize = 10;

  int _step = 0;
  ExportScopeFilter _scope = const ExportScopeFilter();
  late List<Question> _range;
  late ExportSelection _selection;
  String? _selectionNotice;
  String? _capMessage;
  final _searchCtrl = TextEditingController();
  String _search = '';
  int _page = 0;
  ExportVersionSelection _versions =
      const ExportVersionSelection.practiceOnly();
  final _fileNameCtrl = TextEditingController();
  bool _excludeLowDpi = false;
  List<ExcludedQuestion> _excluded = const [];
  bool _secondConfirmed = false;
  String? _formError;

  ExportFlowController get _flow => widget.controller;
  ExportWizardInput get _input => widget.input;

  @override
  void initState() {
    super.initState();
    _range = List.of(_input.questions);
    _selection = ExportSelection(
      rangeIds: _range.map((q) => q.id).toList(),
    );
    _selectionNotice = _selection.initialNotice;
    _flow.addListener(_onFlowChanged);
  }

  @override
  void dispose() {
    _flow.removeListener(_onFlowChanged);
    _searchCtrl.dispose();
    _fileNameCtrl.dispose();
    super.dispose();
  }

  void _onFlowChanged() {
    if (!mounted) return;
    setState(() {
      if (_flow.isTerminal && _step == 3) _step = 4;
    });
  }

  // ---------- 名称查找 ----------

  String? _subjectName(String id) =>
      _input.subjects.where((s) => s.id == id).firstOrNull?.name;
  String? _folderName(String id) =>
      _input.folders.where((f) => f.id == id).firstOrNull?.name;
  String? _examName(String id) =>
      _input.exams.where((e) => e.id == id).firstOrNull?.name;
  String? _kpName(String id) =>
      _input.kps.where((k) => k.id == id).firstOrNull?.name;

  String _questionSubtitle(Question q) {
    final subject = _subjectName(q.subjectId) ?? '';
    final folders = q.folderIds
        .map(_folderName)
        .whereType<String>()
        .join('、');
    if (folders.isEmpty) return subject;
    return '$subject · $folders';
  }

  // ---------- 范围与挑题 ----------

  void _applyScope() {
    setState(() {
      _range = applyExportScopeFilter(
        _input.questions,
        _input.folders,
        _scope,
      );
      _selection = ExportSelection(
        rangeIds: _range.map((q) => q.id).toList(),
      );
      _selectionNotice = _selection.initialNotice;
      _capMessage = null;
      _page = 0;
    });
  }

  List<Question> get _pickList {
    final kw = _search.trim().toLowerCase();
    if (kw.isEmpty) return _range;
    return _range
        .where(
          (q) =>
              q.title.toLowerCase().contains(kw) ||
              _questionSubtitle(q).toLowerCase().contains(kw),
        )
        .toList();
  }

  List<String> _selectedIdsInRangeOrder() => _range
      .where((q) => _selection.isSelected(q.id))
      .map((q) => q.id)
      .toList();

  String _scopeSummary() => exportScopeSummaryText(
    filter: _scope,
    subjectName: _scope.subjectId == null
        ? null
        : _subjectName(_scope.subjectId!),
    folderName: _scope.folderId == null
        ? null
        : _folderName(_scope.folderId!),
    examName: _scope.examId == null ? null : _examName(_scope.examId!),
    kpName: _scope.kpId == null ? null : _kpName(_scope.kpId!),
  );

  // ---------- 确认步：盘点与生成 ----------

  Future<void> _prepare() async {
    _secondConfirmed = false;
    await _flow.prepare(
      ids: _selectedIdsInRangeOrder(),
      excluded: _excluded,
      circledCount: _range.length,
    );
  }

  void _goToConfirm() {
    if (_fileNameCtrl.text.isEmpty) {
      _fileNameCtrl.text = buildExportFileName(
        subjectName: _scope.subjectId == null
            ? '多学科'
            : _subjectName(_scope.subjectId!) ?? '多学科',
        folderName: _scope.folderId == null
            ? null
            : _folderName(_scope.folderId!),
        date: DateTime.now(),
        version: ExportVersion.practice,
      );
    }
    setState(() => _step = 2);
    unawaited(_prepare());
  }

  String _answerFileName(String practiceName) {
    final name = practiceName.trim();
    if (name.toLowerCase().endsWith('.pdf')) {
      return '${name.substring(0, name.length - 4)}_答案.pdf';
    }
    return '${name}_答案.pdf';
  }

  Future<void> _onGenerate() async {
    final inv = _flow.inventory;
    if (inv == null) return;
    final cap = _selection.capViolation();
    if (cap != null) {
      setState(() => _formError = cap);
      return;
    }
    if (_selection.selectedCount == 0) {
      setState(() => _formError = '请至少选择 1 道题');
      return;
    }
    if (!_versions.hasAny) {
      setState(() => _formError = '至少选择一个版本');
      return;
    }
    final nameError = validateExportFileName(_fileNameCtrl.text.trim());
    if (nameError != null) {
      setState(() => _formError = nameError);
      return;
    }
    if (inv.guard.isHardReject) {
      setState(
        () => _formError =
            '本次导出内容过重，已停止生成。请减少题数，或去详情页重拍裁切。',
      );
      return;
    }
    if (inv.needsSecondConfirmation && !_secondConfirmed) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
            '将跳过 ${inv.skippedCount} / ${inv.selectedCount} 道题，确认继续吗？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('确认继续'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      _secondConfirmed = true;
    }
    final practiceName = _fileNameCtrl.text.trim();
    final answerName = _answerFileName(practiceName);
    setState(() {
      _formError = null;
      _step = 3;
    });
    unawaited(
      _flow.start(
        ids: _selectedIdsInRangeOrder(),
        excluded: _excluded,
        filterText: _scopeSummary(),
        sortText: _input.sortText,
        versions: _versions,
        circledCount: _range.length,
        fileNameFor: (v) =>
            v == ExportVersion.practice ? practiceName : answerName,
        subjectName: _scope.subjectId == null
            ? '多学科'
            : _subjectName(_scope.subjectId!) ?? '多学科',
        folderName: _scope.folderId == null
            ? null
            : _folderName(_scope.folderId!),
        excludeLowDpi: _excludeLowDpi,
      ),
    );
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    final title = switch (_step) {
      0 => '新建导出单 · 第 1 步：选范围',
      1 => '新建导出单 · 第 2 步：挑题',
      2 => '新建导出单 · 第 3 步：确认导出',
      3 => '正在生成…',
      _ => '导出完成',
    };
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 560,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SingleChildScrollView(child: _stepBody()),
            ),
            const SizedBox(height: 12),
            _actions(),
          ],
        ),
      ),
    );
  }

  Widget _actions() {
    switch (_step) {
      case 0:
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            QmButton(
              label: '取消',
              variant: QmButtonVariant.ghost,
              onPressed: () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 8),
            QmButton(
              label: '下一步',
              onPressed: _range.isEmpty
                  ? null
                  : () => setState(() => _step = 1),
            ),
          ],
        );
      case 1:
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            QmButton(
              label: '上一步',
              variant: QmButtonVariant.plain,
              onPressed: () => setState(() => _step = 0),
            ),
            const SizedBox(width: 8),
            QmButton(
              label: '下一步',
              onPressed: _selection.selectedCount == 0
                  ? null
                  : _goToConfirm,
            ),
          ],
        );
      case 2:
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            QmButton(
              label: '上一步',
              variant: QmButtonVariant.plain,
              onPressed: () => setState(() => _step = 1),
            ),
            const SizedBox(width: 8),
            QmButton(
              key: const Key('export-generate'),
              label: '生成',
              onPressed: _flow.inventory == null ? null : _onGenerate,
            ),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _stepBody() {
    switch (_step) {
      case 0:
        return _scopeStep();
      case 1:
        return _pickStep();
      case 2:
        return _confirmStep();
      case 3:
        return _progressStep();
      default:
        return ExportCompletionView(
          controller: _flow,
          onClose: () => Navigator.of(context).pop(),
          onOpenQuestion: widget.onOpenQuestion,
        );
    }
  }

  // ---------- 第 1 步：选范围 ----------

  Widget _scopeStep() {
    final folders = _scope.subjectId == null
        ? _input.folders
        : _input.folders
              .where((f) => f.subjectId == _scope.subjectId)
              .toList();
    final kps = _scope.subjectId == null
        ? _input.kps
        : _input.kps.where((k) => k.subjectId == _scope.subjectId).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '圈定导出范围（可跨文件夹与多学科）。默认路径：当前筛选共 '
          '${_input.questions.length} 道题。',
        ),
        const SizedBox(height: 12),
        _dropdown(
          label: '学科',
          value: _scope.subjectId,
          options: [
            (null, '全部学科'),
            for (final s in _input.subjects) (s.id, s.name),
          ],
          onChanged: (v) {
            _scope = _scope.copyWith(
              subjectId: v,
              folderId: null,
              kpId: null,
            );
            _applyScope();
          },
        ),
        const SizedBox(height: 12),
        _dropdown(
          label: '文件夹',
          value: _scope.folderId,
          options: [
            (null, '全部文件夹'),
            for (final f in folders)
              (
                f.id,
                _scope.subjectId == null
                    ? '${_subjectName(f.subjectId) ?? ''} / ${f.name}'
                    : f.name,
              ),
          ],
          onChanged: (v) {
            _scope = _scope.copyWith(folderId: v);
            _applyScope();
          },
        ),
        const SizedBox(height: 12),
        _dropdown(
          label: '考试',
          value: _scope.examId,
          options: [
            (null, '全部考试'),
            for (final e in _input.exams) (e.id, e.name),
          ],
          onChanged: (v) {
            _scope = _scope.copyWith(examId: v);
            _applyScope();
          },
        ),
        const SizedBox(height: 12),
        _dropdown(
          label: '错因',
          value: _scope.causeName,
          options: [
            (null, '全部错因'),
            for (final c in _input.causeNames) (c, c),
          ],
          onChanged: (v) {
            _scope = _scope.copyWith(causeName: v);
            _applyScope();
          },
        ),
        const SizedBox(height: 12),
        _dropdown(
          label: '知识点',
          value: _scope.kpId,
          options: [
            (null, '全部知识点'),
            for (final k in kps) (k.id, '${k.chapter} · ${k.name}'),
          ],
          onChanged: (v) {
            _scope = _scope.copyWith(kpId: v);
            _applyScope();
          },
        ),
        const SizedBox(height: 12),
        _dropdown(
          label: '时间',
          value: _scope.timeRange,
          options: const [
            ('all', '全部时间'),
            ('week', '最近一周'),
            ('month', '最近 30 天'),
          ],
          onChanged: (v) {
            _scope = _scope.copyWith(timeRange: v ?? 'all');
            _applyScope();
          },
        ),
        const SizedBox(height: 16),
        Text(
          '圈定 ${_range.length} 道题',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        if (_range.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('该范围下没有题目，请放宽筛选条件。'),
          ),
      ],
    );
  }

  Widget _dropdown({
    required String label,
    required String? value,
    required List<(String?, String)> options,
    required ValueChanged<String?> onChanged,
  }) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: palette.surface,
            border: Border.all(color: palette.lineStrong),
            borderRadius: BorderRadius.circular(10),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              items: [
                for (final (v, text) in options)
                  DropdownMenuItem<String>(value: v, child: Text(text)),
              ],
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }

  // ---------- 第 2 步：挑题 ----------

  Widget _pickStep() {
    final list = _pickList;
    final pages = (list.length / _pageSize).ceil().clamp(1, 999);
    final page = _page.clamp(0, pages - 1);
    final items = list.skip(page * _pageSize).take(_pageSize).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const Key('export-pick-search'),
          controller: _searchCtrl,
          decoration: const InputDecoration(
            hintText: '搜索题目',
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => setState(() {
            _search = v;
            _page = 0;
          }),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                _selection.countText,
                key: const Key('export-pick-count'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            QmButton(
              label: '全选',
              variant: QmButtonVariant.plain,
              size: QmButtonSize.small,
              onPressed: () => setState(() {
                _selectionNotice = _selection.selectAll();
                _capMessage = null;
              }),
            ),
            const SizedBox(width: 8),
            QmButton(
              label: '全不选',
              variant: QmButtonVariant.plain,
              size: QmButtonSize.small,
              onPressed: () => setState(() {
                _selection.selectNone();
                _selectionNotice = null;
                _capMessage = null;
              }),
            ),
          ],
        ),
        if (_selectionNotice != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _selectionNotice!,
              key: const Key('export-pick-notice'),
            ),
          ),
        if (_capMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _capMessage!,
              key: const Key('export-cap-message'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        const SizedBox(height: 8),
        if (items.isEmpty)
          const Text('没有符合条件的题目。')
        else
          for (final q in items)
            CheckboxListTile(
              key: ValueKey('export-pick-${q.id}'),
              title: Text(q.title),
              subtitle: Text(_questionSubtitle(q)),
              value: _selection.isSelected(q.id),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              onChanged: (_) => setState(() {
                final msg = _selection.toggle(q.id);
                _capMessage = msg;
                if (msg == null) _selectionNotice = null;
              }),
            ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            QmButton(
              label: '← 上一页',
              variant: QmButtonVariant.plain,
              size: QmButtonSize.small,
              onPressed: page > 0
                  ? () => setState(() => _page = page - 1)
                  : null,
            ),
            const SizedBox(width: 8),
            Text('第 ${page + 1} / $pages 页'),
            const SizedBox(width: 8),
            QmButton(
              label: '下一页 →',
              variant: QmButtonVariant.plain,
              size: QmButtonSize.small,
              onPressed: page < pages - 1
                  ? () => setState(() => _page = page + 1)
                  : null,
            ),
          ],
        ),
      ],
    );
  }

  // ---------- 第 3 步：确认导出 ----------

  Widget _confirmStep() {
    final inv = _flow.inventory;
    if (inv == null) {
      if (_flow.phase == ExportFlowPhase.failed) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('盘点失败：${_flow.error ?? '请重试。'}'),
            const SizedBox(height: 12),
            QmButton(label: '重试', onPressed: () => unawaited(_prepare())),
          ],
        );
      }
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: 24),
          Center(child: CircularProgressIndicator()),
          SizedBox(height: 12),
          Center(child: Text('正在盘点…')),
        ],
      );
    }
    final routeNotice = ExportRouteDecision(
      route: inv.route,
      reason: inv.routeReason,
    ).notice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '范围：${_scopeSummary()}；共 ${_range.length} 道，已选 '
          '${_selection.selectedCount} 道',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text('路线：$routeNotice', key: const Key('export-route-notice')),
        const SizedBox(height: 12),
        if (inv.route == ExportRoute.c) ...[
          Text(
            '可印 ${inv.printableCount} 题 / 将跳过 ${inv.skippedCount} 题',
            key: const Key('export-printable-count'),
          ),
          if (inv.skipped.isNotEmpty)
            _skipListTile(inv, '跳过清单（${inv.skipped.length}）'),
          if (inv.suspicious.isNotEmpty)
            _suspiciousTile(inv),
        ] else ...[
          Text(
            '低于清晰度阈值 ${inv.lowDpi.length} 题',
            key: const Key('export-lowdpi-count'),
          ),
          if (inv.lowDpi.isNotEmpty)
            ExpansionTile(
              key: const Key('export-lowdpi-list'),
              title: Text('低于清晰度阈值的题（${inv.lowDpi.length}）'),
              children: [
                for (final e in inv.lowDpi)
                  ListTile(
                    title: Text(e.title),
                    subtitle: Text(
                      '有效清晰度 ${e.dpi.toStringAsFixed(0)} DPI'
                      '${e.severe ? '（明显偏低）' : ''}',
                    ),
                  ),
              ],
            ),
          CheckboxListTile(
            key: const Key('export-exclude-lowdpi'),
            title: const Text('排除低于清晰度阈值的题'),
            value: _excludeLowDpi,
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            onChanged: (v) {
              setState(() => _excludeLowDpi = v ?? false);
              _excluded = _excludeLowDpi
                  ? [
                      for (final e in inv.lowDpi)
                        ExcludedQuestion(
                          id: e.questionId,
                          reason: '清晰度门禁排除',
                        ),
                    ]
                  : const [];
              unawaited(_prepare());
            },
          ),
        ],
        if (inv.guard.singleImageWarnings.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '以下题目图片过大：'
              '${inv.guard.singleImageWarnings.map((e) => e.title).join('、')}',
              key: const Key('export-single-image-warnings'),
            ),
          ),
        if (inv.guard.isSoftWarning)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '内容较重，${inv.guard.estimateNote}，确认后继续生成。',
              key: const Key('export-guard-soft'),
            ),
          ),
        if (inv.guard.isHardReject)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '本次导出内容过重（栅格总量约 '
              '${inv.guard.totalRasterMpx.toStringAsFixed(1)} Mpx，'
              '超过 150 Mpx 上限），已停止生成。请减少题数，或去详情页重拍裁切。',
              key: const Key('export-guard-hard'),
            ),
          ),
        if (inv.needsSecondConfirmation)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '将跳过 ${inv.skippedCount} / ${inv.selectedCount} 道题，'
              '点「生成」后会再次确认。',
              key: const Key('export-skip-second-confirm'),
            ),
          ),
        const SizedBox(height: 12),
        CheckboxListTile(
          title: const Text('练习版'),
          subtitle: Text(ExportVersion.practice.difference),
          value: _versions.practice,
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          onChanged: (v) => setState(
            () => _versions = ExportVersionSelection(
              practice: v ?? false,
              answer: _versions.answer,
            ),
          ),
        ),
        CheckboxListTile(
          title: const Text('答案版'),
          subtitle: Text(ExportVersion.answer.difference),
          value: _versions.answer,
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          onChanged: (v) => setState(
            () => _versions = ExportVersionSelection(
              practice: _versions.practice,
              answer: v ?? false,
            ),
          ),
        ),
        const Text('纸张：A4 纵向（固定，不可选）'),
        const SizedBox(height: 12),
        TextField(
          key: const Key('export-file-name'),
          controller: _fileNameCtrl,
          decoration: const InputDecoration(
            labelText: '文件名',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            QmButton(
              label: '自动修正',
              variant: QmButtonVariant.plain,
              size: QmButtonSize.small,
              onPressed: () => setState(() {
                final raw = _fileNameCtrl.text.trim();
                final stem = sanitizeExportFileName(raw);
                _fileNameCtrl.text = stem.toLowerCase().endsWith('.pdf')
                    ? stem
                    : '$stem.pdf';
                _formError = null;
              }),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '答案版：${_answerFileName(_fileNameCtrl.text)}',
                key: const Key('export-answer-file-name'),
              ),
            ),
          ],
        ),
        if (_formError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _formError!,
              key: const Key('export-form-error'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }

  Widget _skipListTile(ExportInventory inv, String title) {
    return ExpansionTile(
      key: const Key('export-skip-list'),
      title: Text(title),
      children: [
        for (final e in inv.skipped)
          ListTile(
            title: Text(e.title),
            subtitle: Text(e.reason),
            onTap: widget.onOpenQuestion == null
                ? null
                : () => widget.onOpenQuestion!(e.questionId),
          ),
      ],
    );
  }

  Widget _suspiciousTile(ExportInventory inv) {
    return ExpansionTile(
      key: const Key('export-suspicious-list'),
      title: Text('低可疑标记题（${inv.suspicious.length}）'),
      children: [
        for (final e in inv.suspicious)
          ListTile(
            title: Text(e.title),
            subtitle: Text('可疑标记：${e.flags.join('、')}，可去详情页纠错'),
            onTap: widget.onOpenQuestion == null
                ? null
                : () => widget.onOpenQuestion!(e.questionId),
          ),
      ],
    );
  }

  // ---------- 进度 ----------

  Widget _progressStep() {
    final total = _flow.progressTotal;
    final done = _flow.progressDone;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(
          value: total > 0 ? done / total : null,
        ),
        const SizedBox(height: 12),
        Text(
          total > 0 ? '当前第 $done / $total 题' : '正在准备…',
          key: const Key('export-progress-count'),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(_flow.progressLabel),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            QmButton(
              label: '取消',
              variant: QmButtonVariant.danger,
              onPressed: () => _flow.cancel(),
            ),
            const SizedBox(width: 8),
            QmButton(
              label: '关闭（后台继续跑）',
              variant: QmButtonVariant.plain,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Text('关闭后生成继续在后台跑，完成时将再次弹出。'),
      ],
    );
  }
}

/// 完成界面（向导内第 4 步与 [ExportWizardSession] 再次弹出的对话框
/// 共用）：逐份文件成功 / 失败状态 + 完整性报告摘要 + 警告清单展开 +
/// 平台操作按钮（Windows「打开文件 / 打开所在文件夹」，Android 只出
/// 「分享」）。
class ExportCompletionView extends StatelessWidget {
  const ExportCompletionView({
    super.key,
    required this.controller,
    required this.onClose,
    this.onOpenQuestion,
  });

  /// 流程控制器（终态数据来源）。
  final ExportFlowController controller;

  /// 关闭按钮回调。
  final VoidCallback onClose;

  /// 警告清单里点某题：打开详情页纠错 / 补 OCR（可空）。
  final void Function(String questionId)? onOpenQuestion;

  @override
  Widget build(BuildContext context) {
    if (controller.phase == ExportFlowPhase.cancelled) {
      return _simple(
        context,
        title: '已取消',
        message: '导出已取消，未生成文件。',
      );
    }
    if (controller.phase == ExportFlowPhase.failed) {
      return _simple(
        context,
        title: '导出失败',
        message:
            '${controller.error ?? '生成失败，请重试。'}\n临时文件已清理，未生成损坏文件。',
      );
    }
    final rows = controller.completionRows;
    final partial = rows.any((r) => !r.isDelivered);
    final report = controller.versionsResult?.report;
    final warnings = report == null
        ? const <IntegrityEntry>[]
        : report.entries
              .where((e) => e.status != IntegrityStatus.complete)
              .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          partial ? '部分成功：以下文件未完成。' : '全部完成',
          key: const Key('export-completion-status'),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        for (final row in rows) _fileRow(context, row),
        const SizedBox(height: 12),
        for (final line in controller.reportSummaryLines) Text(line),
        if (warnings.isNotEmpty)
          ExpansionTile(
            key: const Key('export-completion-warnings'),
            title: Text('警告清单（${warnings.length}）'),
            children: [
              for (final e in warnings)
                ListTile(
                  title: Text(e.title),
                  subtitle: Text(
                    e.status == IntegrityStatus.skipped
                        ? '跳过（${e.skipReason ?? '未印出'}）'
                        : e.status == IntegrityStatus.broken
                        ? '主图缺失，已印占位说明'
                        : e.warnings.join('；'),
                  ),
                  onTap: onOpenQuestion == null
                      ? null
                      : () => onOpenQuestion!(e.questionId),
                ),
            ],
          ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            QmButton(label: '关闭', onPressed: onClose),
          ],
        ),
      ],
    );
  }

  Widget _simple(BuildContext context, {required String title, required String message}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(message),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [QmButton(label: '关闭', onPressed: onClose)],
        ),
      ],
    );
  }

  Widget _fileRow(BuildContext context, ExportCompletionRow row) {
    final statusText = row.generationFailed
        ? '生成失败：${row.generationError}'
        : row.deliveryError != null
        ? '保存失败：${row.deliveryError}'
        : row.isDelivered
        ? '已生成'
        : '未完成';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${row.version.label}：${row.fileName.isEmpty ? '（未生成）' : row.fileName}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (row.pageCount != null)
            Text('共 ${row.pageCount} 页 · ${row.questionCount ?? 0} 道题'),
          Text(statusText, key: Key('export-file-status-${row.version.name}')),
          if (row.deliveredPath != null) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                if (controller.supportsOpen) ...[
                  QmButton(
                    label: '打开文件',
                    variant: QmButtonVariant.plain,
                    size: QmButtonSize.small,
                    onPressed: () async {
                      final ok = await controller.openDeliveredFile(
                        row.deliveredPath!,
                      );
                      if (!ok && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('打开文件失败')),
                        );
                      }
                    },
                  ),
                  QmButton(
                    label: '打开所在文件夹',
                    variant: QmButtonVariant.plain,
                    size: QmButtonSize.small,
                    onPressed: () async {
                      final ok = await controller.openDeliveredFolder(
                        row.deliveredPath!,
                      );
                      if (!ok && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('打开文件夹失败')),
                        );
                      }
                    },
                  ),
                ] else
                  QmButton(
                    label: '分享',
                    variant: QmButtonVariant.plain,
                    size: QmButtonSize.small,
                    onPressed: () async {
                      final result = await controller.shareDeliveredFile(
                        row.deliveredPath!,
                      );
                      if (result?.outcome == ShareOutcome.failed &&
                          context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              '分享失败：${result?.error ?? '请重试'}',
                            ),
                          ),
                        );
                      }
                    },
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 向导会话：打开向导对话框，并在生成终态时管理完成界面的再次弹出。
///
/// - 向导对话框关闭不取消生成：生成在后台跑；若关闭时生成尚未终态，
///   终态到达时本会话再次弹出完成界面（[ExportCompletionView]）；
/// - 若关闭时向导从未开始生成，直接收尾（调 [onFinished]，如卸载
///   公式栅格化器）；终态到达后收尾同样只调一次。
class ExportWizardSession {
  ExportWizardSession({
    required this.controller,
    required this.input,
    this.onOpenQuestion,
    this.onFinished,
  });

  /// 流程控制器（由调用方持有并注入生产 / 测试回调）。
  final ExportFlowController controller;

  /// 向导输入（快照）。
  final ExportWizardInput input;

  /// 跳过 / 可疑 / 警告清单里点某题的回调。
  final void Function(String questionId)? onOpenQuestion;

  /// 收尾回调（只调一次：卸载栅格化器等）。
  final VoidCallback? onFinished;

  BuildContext? _context;
  bool _dialogOpen = false;
  bool _completionShown = false;
  bool _finished = false;

  /// 打开向导对话框。
  void show(BuildContext context) {
    _context = context;
    controller.addListener(_onFlowChanged);
    _dialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => ExportWizardDialog(
        input: input,
        controller: controller,
        onOpenQuestion: onOpenQuestion,
      ),
    ).then((_) {
      _dialogOpen = false;
      if (controller.phase == ExportFlowPhase.idle) {
        _finishOnce();
      } else if (controller.isTerminal && !_completionShown) {
        // 完成界面已在向导内展示过，用户看完关闭向导，直接收尾。
        _finishOnce();
      }
    });
  }

  void _onFlowChanged() {
    if (!controller.isTerminal) return;
    final context = _context;
    if (!_dialogOpen && !_completionShown && context != null) {
      _showCompletion(context);
    }
  }

  void _showCompletion(BuildContext context) {
    _completionShown = true;
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => AlertDialog(
        title: const Text('导出完成'),
        content: SizedBox(
          width: 560,
          child: ExportCompletionView(
            controller: controller,
            onClose: () => Navigator.of(context).pop(),
            onOpenQuestion: onOpenQuestion,
          ),
        ),
      ),
    ).then((_) => _finishOnce());
  }

  void _finishOnce() {
    if (_finished) return;
    _finished = true;
    controller.removeListener(_onFlowChanged);
    onFinished?.call();
  }
}
