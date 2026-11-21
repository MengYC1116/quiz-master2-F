// 十六批 B（D-190）：错题本直接勾选后的导出确认步。
//
// 取代十五批 M3 的三步向导（D-168/D-169 已废，见 docs/decision-log.md
// D-190）：选题不在这里做——用户在错题本列表页逐题勾选，确认步只做
// 确认（选练习版 / 答案版、文件名、路线与跳过提示）+ 生成 + 完成。
// 确认步内容沿用向导第 3 步的展示口径（M1-DESIGN.md §2/§5）：
// 路线明示、版本、纸张（A4 纵向固定）、文件名、提醒清单；guard 软
// 警告明示、硬拒绝阻断；跳过数 > 20 或 > 50% 二次确认。点「生成」
// 后冻结快照并开始生成；面板关闭不取消生成（生成在后台跑，完成时
// 由 [ExportConfirmSession] 再次弹出完成界面）。
//
// 导出格式选择（ExportFormat）：PDF 与 Word（.docx）均可选
//（十六批 C，D-190/D-194）；格式传给生成入口按格式分发
//（ExportFlowController.start 的 format 参数）。Word 为单份文件，
// 练习版与答案版在同一份 .docx 内，不另存答案版文件。
//
// 风格：沿用 minimalist × professional + 年轻学习伙伴感（现有
// 主题与组件，不引入卡片堆叠 / 数据墙 / 渐变 / 玻璃拟态）。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../widgets/uikit.dart';
import '../../services/pdf_export/export_filename.dart';
import '../../services/pdf_export/export_flow.dart';
import '../../services/pdf_export/export_integrity.dart';
import '../../services/pdf_export/export_inventory.dart';
import '../../services/pdf_export/export_route.dart';
import '../../services/pdf_export/export_snapshot.dart';
import '../../services/pdf_export/export_versions.dart';
import '../../services/pdf_export/pdf_delivery.dart';

/// 确认步输入（打开时拍下的快照；生成过程中用户改筛选 / 改题均不
/// 影响本次导出——确认步只用这份输入，不再读错题本状态）。
class ExportConfirmInput {
  const ExportConfirmInput({
    required this.questions,
    required this.subjects,
    required this.folders,
    required this.sortText,
    required this.filterText,
    required this.subjectName,
    this.folderName,
    required this.circledCount,
  });

  /// 本次选中的题目（列表页勾选，filteredAll() 顺序；≤ 50 道，
  /// 打开前已由勾选上限拦过，确认前再断言一次）。
  final List<Question> questions;

  /// 全部学科（名称展示用）。
  final List<Subject> subjects;

  /// 全部文件夹（名称展示用）。
  final List<Folder> folders;

  /// 排序文案（PDF 信息区用，如“时间新→旧”）。
  final String sortText;

  /// 范围摘要（一行，如“学科：数学；文件夹：试卷”或“全部题目”，
  /// 由调用方按当前列表范围算好传入，不得取第一道题的学科 /
  /// 文件夹代表范围）。
  final String filterText;

  /// 本次范围的展示学科名（单科为该科名，多科 / 跨科为“多学科”）。
  final String subjectName;

  /// 本次范围的展示文件夹名（单文件夹为该名，多文件夹时为 null）。
  final String? folderName;

  /// 打开时当前列表的题数（用户从多少道题里勾选了本次题目）。
  final int circledCount;
}

/// 导出确认对话框（确认导出 → 进度 → 完成；由
/// [ExportConfirmSession] 打开与管理）。
class ExportConfirmDialog extends StatefulWidget {
  const ExportConfirmDialog({
    super.key,
    required this.input,
    required this.controller,
    this.onOpenQuestion,
  });

  /// 确认步输入（快照）。
  final ExportConfirmInput input;

  /// 流程控制器（盘点 / 生成 / 交付 / 终态；由调用方持有，
  /// 对话框关闭后仍继续跑，直到终态）。
  final ExportFlowController controller;

  /// 跳过 / 可疑清单里点某题：打开详情页纠错 / 补 OCR（可空；
  /// 不传时清单只展示，不可点）。
  final void Function(String questionId)? onOpenQuestion;

  @override
  State<ExportConfirmDialog> createState() => _ExportConfirmDialogState();
}

class _ExportConfirmDialogState extends State<ExportConfirmDialog> {
  /// 确认步。
  static const _stepConfirm = 0;

  /// 进度。
  static const _stepProgress = 1;

  /// 完成。
  static const _stepDone = 2;

  int _step = _stepConfirm;
  ExportVersionSelection _versions =
      const ExportVersionSelection.practiceOnly();
  // 十六批 C：格式选择（PDF / Word 均可选；切换格式时文件名扩展名
  // 跟随切换，干不变）。
  ExportFormat _format = ExportFormat.pdf;
  final _fileNameCtrl = TextEditingController();
  bool _excludeLowDpi = false;
  List<ExcludedQuestion> _excluded = const [];
  bool _secondConfirmed = false;
  String? _formError;

  ExportFlowController get _flow => widget.controller;
  ExportConfirmInput get _input => widget.input;

  List<String> get _selectedIds =>
      _input.questions.map((q) => q.id).toList();

  @override
  void initState() {
    super.initState();
    _fileNameCtrl.text = buildExportFileName(
      subjectName: _input.subjectName,
      folderName: _input.folderName,
      date: DateTime.now(),
      version: ExportVersion.practice,
    );
    _flow.addListener(_onFlowChanged);
    unawaited(_prepare());
  }

  @override
  void dispose() {
    _flow.removeListener(_onFlowChanged);
    _fileNameCtrl.dispose();
    super.dispose();
  }

  void _onFlowChanged() {
    if (!mounted) return;
    setState(() {
      if (_flow.isTerminal && _step == _stepProgress) _step = _stepDone;
    });
  }

  // ---------- 盘点与生成 ----------

  Future<void> _prepare() async {
    _secondConfirmed = false;
    await _flow.prepare(
      ids: _selectedIds,
      excluded: _excluded,
      circledCount: _input.circledCount,
    );
  }

  String _answerFileName(String practiceName) {
    final name = practiceName.trim();
    final ext = _format.extension;
    if (name.toLowerCase().endsWith(ext)) {
      return '${name.substring(0, name.length - ext.length)}_答案$ext';
    }
    return '${name}_答案$ext';
  }

  /// 切换格式时文件名扩展名跟随切换（干不变；无扩展名时直接追加）。
  void _syncFileNameExtension() {
    final ext = _format.extension;
    var name = _fileNameCtrl.text.trim();
    for (final e in ['.pdf', '.docx']) {
      if (name.toLowerCase().endsWith(e)) {
        name = name.substring(0, name.length - e.length);
        break;
      }
    }
    _fileNameCtrl.text = '$name$ext';
  }

  Future<void> _onGenerate() async {
    final inv = _flow.inventory;
    if (inv == null) return;
    if (_selectedIds.length > kExportMaxQuestions) {
      setState(() => _formError = '单次最多导出 50 道题');
      return;
    }
    if (_selectedIds.isEmpty) {
      setState(() => _formError = '请至少选择 1 道题');
      return;
    }
    if (!_versions.hasAny) {
      setState(() => _formError = '至少选择一个版本');
      return;
    }
    final nameError = validateExportFileName(
      _fileNameCtrl.text.trim(),
      format: _format,
    );
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
      _step = _stepProgress;
    });
    unawaited(
      _flow.start(
        ids: _selectedIds,
        excluded: _excluded,
        filterText: _input.filterText,
        sortText: _input.sortText,
        versions: _versions,
        circledCount: _input.circledCount,
        fileNameFor: (v) =>
            v == ExportVersion.practice ? practiceName : answerName,
        subjectName: _input.subjectName,
        folderName: _input.folderName,
        excludeLowDpi: _excludeLowDpi,
        format: _format,
      ),
    );
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    final title = switch (_step) {
      _stepConfirm => '确认导出',
      _stepProgress => '正在生成…',
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
      case _stepConfirm:
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
      case _stepConfirm:
        return _confirmStep();
      case _stepProgress:
        return _progressStep();
      default:
        return ExportCompletionView(
          controller: _flow,
          onClose: () => Navigator.of(context).pop(),
          onOpenQuestion: widget.onOpenQuestion,
        );
    }
  }

  // ---------- 确认步 ----------

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
          '已选 ${_selectedIds.length} 道（当前列表共 ${_input.circledCount} 道）',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text('范围：${_input.filterText}'),
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
              // 十六批 C（D-202）：Word 软警告只显示 Mpx、不显示 MB 预估
              //（与 PDF 文案不一致，接受）。
              _format == ExportFormat.word
                  ? '内容较重，栅格总量约 '
                        '${inv.guard.totalRasterMpx.toStringAsFixed(1)} Mpx，'
                        '确认后继续生成。'
                  : '内容较重，${inv.guard.estimateNote}，确认后继续生成。',
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
        // 十六批 C：格式选择（PDF / Word 均可选）。
        const Text('导出格式'),
        RadioGroup<ExportFormat>(
          groupValue: _format,
          onChanged: (v) => setState(() {
            _format = v ?? ExportFormat.pdf;
            _syncFileNameExtension();
          }),
          child: Column(
            children: [
              RadioListTile<ExportFormat>(
                title: const Text('PDF'),
                value: ExportFormat.pdf,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
              RadioListTile<ExportFormat>(
                title: const Text('Word'),
                value: ExportFormat.word,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ],
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
                final ext = _format.extension;
                _fileNameCtrl.text = stem.toLowerCase().endsWith(ext)
                    ? stem
                    : '$stem$ext';
                _formError = null;
              }),
            ),
            const SizedBox(width: 8),
            Expanded(
              // 十六批 C：Word 为单份文件，答案版包含在同一文件内，
              // 不另存文件；答案版文件名预览行隐藏，改显示合并说明。
              child: _format == ExportFormat.word
                  ? const Text(
                      '答案版包含在同一文件内，不另存文件。',
                      key: Key('export-word-merged-note'),
                    )
                  : Text(
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

/// 完成界面（确认步内与 [ExportConfirmSession] 再次弹出的对话
/// 框共用）：逐份文件成功 / 失败状态 + 完整性报告摘要 + 警告清单展开 +
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
    final report =
        controller.wordResult?.report ?? controller.versionsResult?.report;
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
            '${row.labelOverride ?? row.version.label}：${row.fileName.isEmpty ? '（未生成）' : row.fileName}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (row.pageCount != null)
            Text('共 ${row.pageCount} 页 · ${row.questionCount ?? 0} 道题')
          else if (row.isWordCombined)
            // 十六批 C（W-11）：Word 总页数生成时未知，完成界面不得编造
            // 页数，写“以 Word 打开为准”。
            Text('共 ${row.questionCount ?? 0} 道题 · 页数以 Word 打开为准'),
          // 十七批 A4（D-207）：Word 估计页数（内容高度贪心分页模拟，
          // 只是估计，标「约」+「估计值」；实测页数仍未知，pageCount
          // 保持 null；估计值缺失时不显示此行）。
          if (row.isWordCombined && row.estimatedPageCount != null)
            Text(
              '约 ${row.estimatedPageCount} 页（估计值）',
              key: const Key('export-word-estimated-pages'),
            ),
          Text(statusText, key: Key('export-file-status-${row.version.name}')),
          // 十七批 A5（D-208）：Word 页脚 PAGE/NUMPAGES 字段无缓存值，
          // 不更新字段的查看器会显示空白；只在 Word 文件已交付时提示
          // 用户在 Word 里按 Ctrl+A 再按 F9 更新页码。PDF 行不显示。
          if (row.isWordCombined && row.isDelivered)
            const Text(
              '在 Word 里按 Ctrl+A 再按 F9 更新页码',
              key: Key('export-word-refresh-fields-hint'),
            ),
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

/// 确认会话：打开确认对话框，并在生成终态时管理完成界面的再次弹出。
///
/// - 确认对话框关闭不取消生成：生成在后台跑；若关闭时生成尚未终态，
///   终态到达时本会话再次弹出完成界面（[ExportCompletionView]）；
/// - 若关闭时确认步从未开始生成，直接收尾（调 [onFinished]，如卸载
///   公式栅格化器）；终态到达后收尾同样只调一次。
class ExportConfirmSession {
  ExportConfirmSession({
    required this.controller,
    required this.input,
    this.onOpenQuestion,
    this.onFinished,
  });

  /// 流程控制器（由调用方持有并注入生产 / 测试回调）。
  final ExportFlowController controller;

  /// 确认步输入（快照）。
  final ExportConfirmInput input;

  /// 跳过 / 可疑 / 警告清单里点某题的回调。
  final void Function(String questionId)? onOpenQuestion;

  /// 收尾回调（只调一次：卸载栅格化器等）。
  final VoidCallback? onFinished;

  BuildContext? _context;
  bool _dialogOpen = false;
  bool _completionShown = false;
  bool _finished = false;

  /// 打开确认对话框。
  void show(BuildContext context) {
    _context = context;
    controller.addListener(_onFlowChanged);
    _dialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => ExportConfirmDialog(
        input: input,
        controller: controller,
        onOpenQuestion: onOpenQuestion,
      ),
    ).then((_) {
      _dialogOpen = false;
      if (controller.phase == ExportFlowPhase.idle) {
        _finishOnce();
      } else if (controller.isTerminal && !_completionShown) {
        // 完成界面已在确认步内展示过，用户看完关闭对话框，直接收尾。
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
