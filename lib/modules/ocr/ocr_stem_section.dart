// 十三批 M5：识别题干区（整理工作台 + 详情页共用同一套组件）。
//
// 位置：整理页在每道题的切片图正下方；详情页在题目图下方，长期可用。
// 结构（GPT 评审 §3.6）：
//   原题切片（页面上方的图，永远保留）
//   识别后的题干（渲染好的公式）［编辑题干］［重新识别］
//   点“编辑题干”后在切片下方原地展开 [StemEditor]，不跳页面。
//
// 状态行只读 [deriveOcrStemStatus]（见 ocr_stem_status.dart）：
// 等待识别 / 识别中 / 等待设置 API Key / 稍后自动重试 / 识别完成 /
// 识别失败 / 已手动修改。没 key 时绝不显示“识别中”。
//
// 候选（有新的识别结果）：只凭 M3 的 [hasPendingOcrCandidate] 判定，
// 不自己比文本。未编辑时在区里显横幅；编辑中到了只在编辑器里显横幅，
// 不刷草稿（守门见 StemEditor.didUpdateWidget）。
//
// 重新识别：题干已手动改过时先弹确认（新结果只作候选，原内容保留，
// 确认替换后才换）；其余直接入队。入队本身由调用方做（见
// stem_correction.dart 的 [enqueueOcrForQuestion]），本组件只发请求。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/database.dart';
import '../../models/models.dart';
import '../../services/ocr_queue.dart';
import 'ocr_stem_status.dart';
import 'question_content.dart';
import 'question_content_renderer.dart';
import 'stem_editor.dart';

/// 接受候选失败的原因码 → 给用户看的明确文案（十三批 P1-2 任务 e）。
/// 原因码是 stem_correction.dart 的 [CandidateRejection.reason]
///（question_deleted / no_candidate / not_pending / hash_mismatch /
/// slice_missing）；'save_failed' 是写库等其他失败，'no_question'
/// 是当前题已不在。未知码回退通用提示，不要让用户对着通用报错猜。
String candidateRejectionMessage(String reason) => switch (reason) {
  'question_deleted' => '题目已被删除，候选无法接受',
  'no_candidate' => '没有待处理的识别结果',
  'not_pending' => '这份识别结果已经处理过，不能重复接受',
  'hash_mismatch' => '识别结果来自旧切片（已重新框选），已标记为过期，不能接受',
  'slice_missing' => '切片文件不存在，无法核对候选来源',
  'no_question' => '题目已被删除，候选无法接受',
  _ => '保存失败，请重试',
};

/// 识别题干区：状态 + 只读题干 + 编辑/重新识别 + 候选横幅 + 原地编辑器。
///
/// [question] 是当前题；[jobs] 是该题的 ocr_jobs 行（最新在前）；
/// [hasApiKey] 是设置里是否已存 key（只问有无，不读 key 值）。
/// [candidateStemOverride] 是“编辑中 OCR 回来了”的守门分支里页面
/// 另行取到的候选题干（见两页的 _onDataChange）：有值时优先用它，
/// 不用就按 [pendingCandidateStem] 从 question.ocrRaw 里取。
/// [sliceBytes] 是题切片字节（公式原图回退用；为空时组件自己按
/// slicePath 从磁盘读，读不到就用通用占位）。
/// 四个回调都不碰 UI 状态，只做保存/入队；保存失败时调用方自己提示，
/// 本组件只在成功后收起编辑器。
class OcrStemSection extends StatefulWidget {
  const OcrStemSection({
    super.key,
    required this.question,
    required this.jobs,
    required this.hasApiKey,
    this.candidateStemOverride,
    this.sliceBytes,
    required this.onSaveEdited,
    required this.onAcceptCandidate,
    required this.onDismissCandidate,
    required this.onRerecognize,
    this.onEditingChanged,
  });

  final Question question;
  final List<OcrJob> jobs;
  final bool hasApiKey;
  final String? candidateStemOverride;
  final Uint8List? sliceBytes;

  /// 保存手动编辑：收编辑器拼回的题干。返回 true = 已落库，
  /// 本组件收起编辑器；false = 保存失败，编辑器保持打开、调用方已提示。
  final Future<bool> Function(String newStem) onSaveEdited;

  /// 接受候选：收候选题干。返回 true = 已落库，收起编辑器；false 同上。
  final Future<bool> Function(String candidateStem) onAcceptCandidate;

  /// 忽略候选：清掉 raw 里的候选标志。
  final Future<void> Function() onDismissCandidate;

  /// 重新识别：调用方入队（已手动改过时本组件先弹确认再调）。
  final Future<void> Function() onRerecognize;

  /// 编辑器开合变化（页面用它做活页内刷新守门：编辑中不刷新该题）。
  final ValueChanged<bool>? onEditingChanged;

  @override
  State<OcrStemSection> createState() => _OcrStemSectionState();
}

class _OcrStemSectionState extends State<OcrStemSection> {
  bool _editing = false;
  bool _showCandidateInEditor = false;
  Uint8List? _sliceBytes;
  String? _sliceBytesForPath;

  @override
  void initState() {
    super.initState();
    _sliceBytes = widget.sliceBytes;
    _loadSliceBytesIfNeeded();
  }

  @override
  void didUpdateWidget(covariant OcrStemSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.question.id != oldWidget.question.id) {
      // 换题：编辑器收起（草稿随 StemEditor 的重建丢弃），不跨题带草稿。
      _editing = false;
      _showCandidateInEditor = false;
      _sliceBytes = widget.sliceBytes;
      _loadSliceBytesIfNeeded();
    } else if (widget.sliceBytes != oldWidget.sliceBytes) {
      _sliceBytes = widget.sliceBytes;
    }
  }

  void _loadSliceBytesIfNeeded() {
    if (_sliceBytes != null) return;
    final path = widget.question.slicePath;
    if (path == null || path.isEmpty) return;
    if (_sliceBytesForPath == path) return;
    _sliceBytesForPath = path;
    unawaited(_readSliceBytes(path));
  }

  Future<void> _readSliceBytes(String path) async {
    try {
      final abs = AppDatabase.resolveDataPath(path);
      if (abs == null) return;
      final bytes = await File(abs).readAsBytes();
      if (!mounted || _sliceBytesForPath != path) return;
      setState(() => _sliceBytes = bytes);
    } catch (_) {
      // 切片读不到：公式回退用通用占位，不挡题干显示。
    }
  }

  void _setEditing(bool open, {bool showCandidate = false}) {
    if (_editing == open && !showCandidate) return;
    setState(() {
      _editing = open;
      _showCandidateInEditor = showCandidate;
    });
    widget.onEditingChanged?.call(open);
  }

  Future<void> _rerecognize() async {
    if (widget.question.ocrManualEdited) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('重新识别'),
          content: const Text(
            '这道题干已手动修改过。重新识别会产生新的候选结果，'
            '原内容会保留，等你预览确认后才替换。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('重新识别'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await widget.onRerecognize();
  }

  @override
  Widget build(BuildContext context) {
    final question = widget.question;
    final status = deriveOcrStemStatus(
      question,
      jobs: widget.jobs,
      hasApiKey: widget.hasApiKey,
    );
    final candidateStem =
        widget.candidateStemOverride ?? pendingCandidateStem(question);
    final stem = (question.ocrStem ?? '').trim();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '识别题干',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 8),
            Container(
              key: const Key('ocr-stem-status'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(status.label, style: const TextStyle(fontSize: 12)),
            ),
            if (status == OcrStemStatus.completed) ...[
              const SizedBox(width: 8),
              Text(
                '切分：${question.ocrSplitStatus}',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        // 十三批 P1-2（GPT §4.2，M4 歧义 UI）：ocr_split_status = 存在歧义
        // 时，识别结果是“待确认”，绝不能只显示成普通“识别完成”。
        // 切分状态是独立内容状态（不混进队列七态——deriveOcrStemStatus
        // 不动，状态 chip 照常显示它的推导结果），这里另显醒目的
        // 待确认横幅：编辑态与非编辑态都显示（编辑时用户正要检查内容，
        // 更需要看到它）。自动切分 / 未切分 / 人工调整时不显示。
        if (question.ocrSplitStatus == OcrSplitStatus.ambiguous) ...[
          _ambiguousBanner(),
          const SizedBox(height: 8),
        ],
        if (_editing)
          StemEditor(
            key: ValueKey('stem-editor-${question.id}'),
            question: question,
            candidateStem: candidateStem,
            sliceBytes: _sliceBytes,
            initiallyShowCandidate: _showCandidateInEditor,
            onSave: (newStem) async {
              final ok = await widget.onSaveEdited(newStem);
              if (ok && mounted) _setEditing(false);
            },
            onAcceptCandidate: (candidate) async {
              final ok = await widget.onAcceptCandidate(candidate);
              if (ok && mounted) _setEditing(false);
            },
            onDismissCandidate: widget.onDismissCandidate,
            onCancel: () => _setEditing(false),
          )
        else ...[
          if (stem.isNotEmpty)
            QuestionContentRenderer(
              blocks: parseQuestionContent(stem),
              fallbackImage: _sliceImageWidget(),
            )
          else if (question.ocrRaw != null)
            const Text(
              '识别完成，但未得到可用题干，已按原图显示',
              style: TextStyle(fontSize: 13),
            )
          else if (status == OcrStemStatus.failed)
            const Text('识别失败，可手动重试', style: TextStyle(fontSize: 13)),
          if (candidateStem != null) ...[
            const SizedBox(height: 8),
            _candidateBanner(
              onView: () => _setEditing(true, showCandidate: true),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton(
                onPressed: () => _setEditing(true),
                child: const Text('编辑题干'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _rerecognize,
                child: Text(status == OcrStemStatus.failed ? '重试' : '重新识别'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget? _sliceImageWidget() {
    final bytes = _sliceBytes;
    if (bytes == null || bytes.isEmpty) return null;
    return Image.memory(bytes, fit: BoxFit.contain);
  }

  /// M4 歧义待确认横幅（GPT §4.2 原文案）：切分存在歧义时整段保留，
  /// 选项可能留在题干里，必须让用户检查题干内容，不能当成已分离的题干。
  Widget _ambiguousBanner() {
    final theme = Theme.of(context);
    return Container(
      key: const Key('ocr-split-ambiguous-banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        border: Border.all(color: theme.colorScheme.tertiary),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '识别结果待确认',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onTertiaryContainer,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '识别内容包含无法确定的选项边界，请检查题干内容。',
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onTertiaryContainer,
            ),
          ),
        ],
      ),
    );
  }

  /// 未编辑时的候选横幅：只提示，不自动替换；点“查看新旧对比”
  /// 展开编辑器并打开对比面板。
  Widget _candidateBanner({required VoidCallback onView}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Expanded(child: Text('有新的识别结果')),
          TextButton(
            onPressed: onView,
            child: const Text('查看新旧对比'),
          ),
          TextButton(
            onPressed: widget.onDismissCandidate,
            child: const Text('忽略'),
          ),
        ],
      ),
    );
  }
}
