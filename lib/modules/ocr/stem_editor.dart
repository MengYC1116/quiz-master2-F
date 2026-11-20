// 十三批 M5：题干纠错编辑器（整理工作台 + 详情页共用同一套组件）。
//
// 只做一套：两页都用 [StemEditor]（经 [OcrStemSection] 挂进页面），
// 不各自另写。编辑器在切片下方原地展开，不跳页面。
//
// 交互（GPT 评审 §3）：
// - 普通文字段直接改（TextField）；代码段按等宽文本显示，缩进保留
//   （D-105：计算机题干里的程序不当公式解析）；公式块可看、可删、
//   可恢复为原图（按 ocr_raw 里 layout_details 的 bbox 裁公式小图，
//   裁不到用整张切片）；十三批不做可视化公式编辑器。
// - 重新识别产生新候选时不直接替换：用户预览新旧再确认（[candidateStem]
//   非空时显“有新的识别结果”，[查看新旧对比] 后 [用新结果替换] / [忽略]）。
// - 正在编辑时 OCR 回来了不许强行刷掉编辑器：草稿只在题目 id 变了时
//   重建（见 [didUpdateWidget]），同题的新候选只显横幅、不动草稿。
// - LaTeX 源码绝不外露：公式只渲染（[FormulaView]）或显示原图；
//   界面、复制文本、报错、日志里都不出现源码（本文件无任何日志输出）。
//
// 保存：[onSave] 收编辑器按块拼回的 Markdown 题干（见
// [blocksToMarkdown]：恢复为原图的公式从题干里拿掉，以原图显示；
// 原始公式仍在 ocr_raw 的 md_results 里，不丢）；版本 +1、人工
// 标记、切分状态“人工调整”由调用方按 stem_correction.dart 的规则写库，
// 不在本组件里碰数据库。

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/glm_ocr_client.dart';
import 'formula_crop.dart';
import 'ocr_figures.dart';
import 'question_content.dart';
import 'question_content_renderer.dart';

/// 编辑器草稿里的一段（与 [QuestionContentBlock] 一一对应，
// 文字段自带控制器，公式段自带“是否已恢复为原图”态）。
sealed class _DraftBlock {
  const _DraftBlock();
}

class _DraftText extends _DraftBlock {
  _DraftText(String text) : controller = TextEditingController(text: text);
  final TextEditingController controller;
}

class _DraftCode extends _DraftBlock {
  _DraftCode(String code, {this.language})
    : controller = TextEditingController(text: code);
  final TextEditingController controller;
  final String? language;
}

class _DraftFormula extends _DraftBlock {
  _DraftFormula(this.latex, {this.displayMode = false});
  final String latex;
  final bool displayMode;

  /// 已恢复为原图：保存时从题干里拿掉（以原图显示）。
  bool restoredAsImage = false;

  /// 恢复为原图时显示的裁图（裁不到时为 null，用整张切片）。
  Uint8List? restoredImage;
}

/// 十四批 M2：图块草稿（与 [FigureBlock] 一一对应）。
/// 删除是即时动作（调 [StemEditor.onDeleteFigure] 落库，不等“保存修改”）；
/// 删除成功后本段显示整题原图（“删除后回退整题原图”），不直接消失——
/// 用户仍能在原图里看到该配图内容。
class _DraftFigure extends _DraftBlock {
  _DraftFigure(this.figure);
  final OcrFigure figure;

  /// 已删除：显示整题原图 + 提示，不再显示裁图。
  bool deleted = false;
}

/// 题干纠错编辑器（原地展开用）。
///
/// [question] 提供题干（ocr_stem）与原始结果（ocr_raw，裁公式小图用）；
/// [candidateStem] 是待确认的新识别结果（无候选时为 null，
/// 调用方用 [hasPendingOcrCandidate] / [pendingCandidateStem] 取）；
/// [sliceBytes] 是题切片字节（恢复为原图 / 裁不到时的原图显示用；
/// 为空时恢复为原图只显示通用占位）。
/// [figures] 是当前切片的图块（按阅读顺序，调用方按
/// [currentFiguresForDisplay] 取好）；[mdResults] 是 ocr_raw 里的
/// md 全文（图块插入位置用）。
class StemEditor extends StatefulWidget {
  const StemEditor({
    super.key,
    required this.question,
    required this.candidateStem,
    this.sliceBytes,
    this.initiallyShowCandidate = false,
    this.figures = const [],
    this.mdResults,
    required this.onSave,
    required this.onAcceptCandidate,
    required this.onDismissCandidate,
    required this.onCancel,
    this.onDeleteFigure,
  });

  final Question question;
  final String? candidateStem;
  final Uint8List? sliceBytes;
  final bool initiallyShowCandidate;
  final List<OcrFigure> figures;
  final String? mdResults;

  /// 保存修改：收拼回的题干；调用方落库后关闭编辑器。
  final Future<void> Function(String newStem) onSave;

  /// 用新结果替换：收候选题干；调用方落库后关闭编辑器。
  final Future<void> Function(String candidateStem) onAcceptCandidate;

  /// 忽略候选：调用方清掉 raw 里的候选标志。
  final Future<void> Function() onDismissCandidate;

  /// 取消：丢弃草稿，调用方关闭编辑器。
  final VoidCallback onCancel;

  /// 删除单个图块（十四批 M2）：调用方调 deleteFigureFromQuestion +
  /// repo.save 落库；返回 true = 已删除，编辑器把该段换成整题原图；
  /// false = 删除失败，该段保持原样、调用方已提示。
  final Future<bool> Function(String figureId)? onDeleteFigure;

  @override
  State<StemEditor> createState() => _StemEditorState();
}

class _StemEditorState extends State<StemEditor> {
  late List<_DraftBlock> _drafts;
  late bool _showCandidate;

  @override
  void initState() {
    super.initState();
    _drafts = _buildDrafts(
      widget.question,
      figures: widget.figures,
      mdResults: widget.mdResults,
    );
    _showCandidate = widget.initiallyShowCandidate;
  }

  @override
  void didUpdateWidget(covariant StemEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 守门（M3 警告 + 任务 §6）：同题的新候选、新状态只刷新横幅，
    // 绝不重建草稿——用户正在改的字一个都不能丢。
    // 只有换题（question.id 变了）才重建草稿。
    if (widget.question.id != oldWidget.question.id) {
      _disposeDrafts();
      _drafts = _buildDrafts(
        widget.question,
        figures: widget.figures,
        mdResults: widget.mdResults,
      );
      _showCandidate = widget.initiallyShowCandidate;
    } else if (widget.candidateStem != oldWidget.candidateStem) {
      // 候选到了/走了：只重绘横幅，草稿不动。
      setState(() {});
    }
  }

  @override
  void dispose() {
    _disposeDrafts();
    super.dispose();
  }

  void _disposeDrafts() {
    for (final block in _drafts) {
      switch (block) {
        case _DraftText(:final controller):
          controller.dispose();
        case _DraftCode(:final controller):
          controller.dispose();
        case _DraftFormula():
          break;
        case _DraftFigure():
          break;
      }
    }
  }

  static List<_DraftBlock> _buildDrafts(
    Question question, {
    required List<OcrFigure> figures,
    required String? mdResults,
  }) {
    // 十四批 M2：草稿按“题干 + 图块”的合并内容序列建（与只读渲染
    // 同顺序，见 buildContentBlocks）；图块进草稿才能在编辑器里删。
    final blocks = buildContentBlocks(
      stemMarkdown: question.ocrStem ?? '',
      figures: figures,
      mdResults: mdResults,
    );
    final byId = {for (final f in figures) f.id: f};
    final drafts = <_DraftBlock>[];
    for (final block in blocks) {
      // WP-D #7 收尾：跳过「未关联图片」区标题块——它只是渲染用的分隔
      // 标记（ocr_figures.dart 的 [unassociatedFiguresHeader]），不是题干
      // 内容；进草稿会在保存时把标题文字写进 ocr_stem。
      // 已知局限：用户题干原文恰好一字不差就是这句标题时也会被跳过，
      // 概率可忽略，记为已知局限（不做内容嗅探区分）。
      if (block is TextBlock && block.text == unassociatedFiguresHeader) {
        continue;
      }
      drafts.add(
        switch (block) {
          TextBlock(:final text) => _DraftText(text),
          CodeBlock(:final code, :final language) =>
            _DraftCode(code, language: language),
          FormulaBlock(:final latex, :final displayMode) =>
            _DraftFormula(latex, displayMode: displayMode),
          ImageFallbackBlock() => _DraftText(''),
          FigureBlock(:final figureId) =>
            _DraftFigure(byId[figureId] ?? _placeholderFigure(figureId)),
          // WP-C #6：表格/标题在纠错编辑器里以可再解析的文本形式进草稿
          // （表格拼回 HTML、标题拼回 `#` 行），保存时重新解析，不丢内容。
          TableBlock() => _DraftText(blocksToMarkdown([block])),
          HeadingBlock(:final text, :final level) =>
            _DraftText('${'#' * level} $text'),
        },
      );
    }
    return drafts;
  }

  /// 图块 id 在 figures 里找不到时的占位（不应发生：调用方传的
  /// figures 与 buildContentBlocks 用的是同一份；防御性兜底，
  /// 删它时按 id 删库里引用，界面显示“图片缺失”占位）。
  static OcrFigure _placeholderFigure(String figureId) => OcrFigure(
    id: figureId,
    slicePath: '',
    inputHash: null,
    sequenceIndex: 0,
    anchorSource: 'fallback',
    anchorRef: '',
    bbox2d: const [0, 0, 0, 0],
    spaceWidth: 0,
    spaceHeight: 0,
    transform: const OcrRequestTransform(
      srcW: 0,
      srcH: 0,
      reqW: 0,
      reqH: 0,
      padX: 0,
      padY: 0,
    ),
    srcRect: const SrcRect(x: 0, y: 0, width: 0, height: 0),
    cropPath: '',
  );

  /// 草稿按块拼回题干（保存用）。空文字段跳过；恢复为原图的公式
  /// 从题干里拿掉（以原图显示，见文件头）；其余按 [blocksToMarkdown]。
  /// 图块不拼回题干（只存在 ocr_figures 里，见 question_content.dart）。
  String _draftsToMarkdown() {
    final blocks = <QuestionContentBlock>[];
    for (final draft in _drafts) {
      switch (draft) {
        case _DraftText(:final controller):
          if (controller.text.isNotEmpty) {
            blocks.add(TextBlock(controller.text));
          }
        case _DraftCode(:final controller, :final language):
          blocks.add(CodeBlock(controller.text, language: language));
        case _DraftFormula(
          :final latex,
          :final displayMode,
          :final restoredAsImage,
        ):
          if (!restoredAsImage) {
            blocks.add(FormulaBlock(latex, displayMode: displayMode));
          }
        case _DraftFigure():
          break;
      }
    }
    return blocksToMarkdown(blocks);
  }

  /// 草稿里第 [formula] 个公式是第几个公式（裁图下标用，
  /// 按题干里 FormulaBlock 的出现顺序计）。
  int _formulaIndexOf(_DraftFormula formula) {
    var index = 0;
    for (final draft in _drafts) {
      if (identical(draft, formula)) return index;
      if (draft is _DraftFormula) index++;
    }
    return index;
  }

  void _restoreFormulaAsImage(_DraftFormula formula) {
    final bytes = cropFormulaImageBytes(
      sliceBytes: widget.sliceBytes ?? Uint8List(0),
      ocrRaw: widget.question.ocrRaw,
      formulaIndex: _formulaIndexOf(formula),
    );
    setState(() {
      formula.restoredAsImage = true;
      // 裁不到（实测 GLM 单题常无 formula 块）时为 null，
      // 显示用整张切片（调用方传了 sliceBytes 时）。
      formula.restoredImage = bytes ?? widget.sliceBytes;
    });
  }

  @override
  Widget build(BuildContext context) {
    final candidateStem = widget.candidateStem;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (candidateStem != null && !_showCandidate)
          _candidateBanner(
            onView: () => setState(() => _showCandidate = true),
          ),
        if (candidateStem != null && _showCandidate)
          _candidatePanel(candidateStem),
        const SizedBox(height: 8),
        const Text(
          '普通文字直接改；公式可看、可删、可恢复为原图；配图可删除',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 8),
        if (_drafts.isEmpty)
          const Text(
            '还没有识别出的题干，可以直接输入',
            style: TextStyle(fontSize: 13),
          ),
        for (var i = 0; i < _drafts.length; i++) ...[
          _draftBlockWidget(_drafts[i]),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 4),
        Row(
          children: [
            FilledButton(
              onPressed: () async => widget.onSave(_draftsToMarkdown()),
              child: const Text('保存修改'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: widget.onCancel,
              child: const Text('取消'),
            ),
          ],
        ),
      ],
    );
  }

  /// “有新的识别结果”横幅（编辑中 OCR 回来了：只提示，不刷草稿）。
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
        ],
      ),
    );
  }

  /// 新旧对比：上面是当前草稿（渲染好的），下面是新识别结果（渲染好的），
  /// 用户确认后才替换；忽略则只清候选标志，当前内容不动。
  Widget _candidatePanel(String candidateStem) {
    final currentMd = _draftsToMarkdown();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('当前内容', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          QuestionContentRenderer(
            blocks: parseQuestionContent(currentMd),
            fallbackImage: _sliceImageWidget(),
          ),
          const Divider(),
          const Text('新的识别结果', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          QuestionContentRenderer(
            blocks: parseQuestionContent(candidateStem),
            fallbackImage: _sliceImageWidget(),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton(
                onPressed: () async =>
                    widget.onAcceptCandidate(candidateStem),
                child: const Text('用新结果替换'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () async {
                  await widget.onDismissCandidate();
                  if (mounted) setState(() => _showCandidate = false);
                },
                child: const Text('忽略'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget? _sliceImageWidget() {
    final bytes = widget.sliceBytes;
    if (bytes == null || bytes.isEmpty) return null;
    return Image.memory(bytes, fit: BoxFit.contain);
  }

  Widget _draftBlockWidget(_DraftBlock draft) {
    switch (draft) {
      case _DraftText(:final controller):
        return TextField(
          controller: controller,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '题干文字',
          ),
        );
      case _DraftCode(:final controller):
        return TextField(
          controller: controller,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '代码',
          ),
        );
      case _DraftFormula(:final latex, :final displayMode):
        return _formulaBlockWidget(draft, latex, displayMode);
      case _DraftFigure(:final figure, :final deleted):
        return _figureBlockWidget(draft, figure, deleted);
    }
  }

  /// 十四批 M2：图块段——裁图 + “位置未确认”标注 + 删除按钮。
  /// 删除是即时落库动作（不等“保存修改”）；删除成功后本段换成
  /// 整题原图（“删除后回退整题原图”），不直接消失。
  Widget _figureBlockWidget(
    _DraftFigure draft,
    OcrFigure figure,
    bool deleted,
  ) {
    if (deleted) {
      return Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outline),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '配图已删除，以下为整题原图',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 6),
            if (_sliceImageWidget() != null) _sliceImageWidget()!,
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FigureImageView(
            cropPath: figure.cropPath,
            unconfirmed: figure.unconfirmed,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              OutlinedButton(
                onPressed: widget.onDeleteFigure == null
                    ? null
                    : () async {
                        final ok = await widget.onDeleteFigure!(figure.id);
                        if (ok && mounted) {
                          setState(() => draft.deleted = true);
                        }
                      },
                child: const Text('删除配图'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _formulaBlockWidget(
    _DraftFormula formula,
    String latex,
    bool displayMode,
  ) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (formula.restoredAsImage)
            if (formula.restoredImage != null)
              Image.memory(formula.restoredImage!, fit: BoxFit.contain)
            else
              const FormulaImageFallback()
          else
            FormulaView(
              latex: latex,
              displayMode: displayMode,
              fallbackImage: _sliceImageWidget(),
            ),
          if (formula.restoredAsImage)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                '已恢复为原图：保存后该公式以原图显示，可重新识别恢复',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              if (formula.restoredAsImage)
                OutlinedButton(
                  onPressed: () =>
                      setState(() => formula.restoredAsImage = false),
                  child: const Text('恢复渲染'),
                )
              else
                OutlinedButton(
                  onPressed: () => _restoreFormulaAsImage(formula),
                  child: const Text('恢复为原图'),
                ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => setState(() => _drafts.remove(formula)),
                child: const Text('删除'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
