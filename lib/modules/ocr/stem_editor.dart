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
// - Win11 反馈后续修复 Q1：连续文字 + 行内公式并成一张段落卡
//   （[_DraftParagraph]，卡内每段文字独立 TextField、公式只读），
//   行间公式/表格/标题/图块/代码断开另起卡；底层块顺序不变，
//   保存时按段内顺序展开拼回。
// - 图块自由拖动（Win11 反馈包 3）：每个图块左上角有拖动柄（⋮⋮），
//   按住柄拖动，块间出现插入线指示落点，松手落位；拖到滚动区上下边缘
//   自动滚动；鼠标直接拖、触屏从柄上拖（柄是独立响应区，不抢滚动手势
//   的地盘——柄之外仍可正常滚动）；只有图块可拖，文字块不动、只作落点
//   间隔槽；图块不能拆开文字块、不能拖出题干区。落下即保存（与“删图块
//   即时落库”一致，见 [StemEditor.onReorderFigure]），顺序写进
//   ocr_figures 的 JSON 顺序，记 anchorSource='manual'；拖动取消
//   恢复原顺序、不写库；保存失败同样回滚，不假装已保存。
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
  _DraftText(String text, {this.origin})
    : controller = TextEditingController(text: text);
  final TextEditingController controller;

  /// 该段在原块序列里的起源（原块下标，段序号）；Q2 切分出的两段
  /// 共享同一原块下标（见 expandedBlockOrigins）。
  final ({int orig, int part})? origin;
}

class _DraftCode extends _DraftBlock {
  _DraftCode(String code, {this.language, this.origin})
    : controller = TextEditingController(text: code);
  final TextEditingController controller;
  final String? language;

  /// 见 [_DraftText.origin]。
  final ({int orig, int part})? origin;
}

class _DraftFormula extends _DraftBlock {
  _DraftFormula(this.latex, {this.displayMode = false, this.origin});
  final String latex;
  final bool displayMode;

  /// 见 [_DraftText.origin]（公式块是原子，不切分，段序号恒为 0）。
  final ({int orig, int part})? origin;

  /// 已恢复为原图：保存时从题干里拿掉（以原图显示）。
  bool restoredAsImage = false;

  /// 恢复为原图时显示的裁图（裁不到时为 null，用整张切片）。
  Uint8List? restoredImage;
}

/// Win11 反馈后续修复 Q1（round 2）：复合段落草稿。
///
/// 一段连续的 TextBlock + 行内 FormulaBlock（displayMode=false）在
/// 编辑器里只显示一张“段落卡”：卡内每段文字各持独立 TextEditingController
/// （绝不合成一个带公式 widget 的大 TextField，跨公式连续选区接受做不到）、
/// 每个行内公式仍是只读 FormulaView + 恢复为原图 / 删除按钮，点公式
/// 不进文字编辑；底层块顺序不变，保存时按段展开拼回。
/// 分组只在连续文本/行内公式处发生，遇到行间公式、表格、标题、图块、
/// 代码、ImageFallback 就断开，各自另起草稿（见 [_buildDrafts]）。
class _DraftParagraph extends _DraftBlock {
  _DraftParagraph(this.segments);

  /// 段内草稿，按原块顺序：只含 [_DraftText] 与行内 [_DraftFormula]。
  final List<_DraftBlock> segments;
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
    this.onReorderFigure,
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

  /// 图块换位（Win11 反馈包 3）：落下即保存。调用方用
  /// [reorderFigures] 重排 + repo.save 落库（顺序写进 ocr_figures
  /// 的 JSON 顺序，被拖图块记 anchorSource='manual'）；返回 true =
  /// 已保存，编辑器保持新顺序；false = 保存失败，编辑器回滚到原顺序。
  /// [orderedFigureIds] 是换位后全部图块按显示顺序的 ID；
  /// [movedFigureId] 是被拖的图块 ID；[movedTextAt] 是 manual 落点
  /// 字符串（Q2 REV2 §5.1：`"h"` = 原块 `h` 之前，`"h:s"` = 原块 `h`
  /// 的第 `s` 段之前——落点恰在某切分块的两段之间时记后者，其余记前者）。
  /// 为 null 时拖动不生效（落下即回滚，不假装已保存）——调用方未接线
  /// 前拖了也白拖，不如明确回滚。
  final Future<bool> Function(
    List<String> orderedFigureIds,
    String movedFigureId,
    String movedTextAt,
  )?
  onReorderFigure;

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
        case _DraftParagraph(:final segments):
          // 段内每段文字各持独立 controller，各自释放。
          for (final seg in segments) {
            if (seg is _DraftText) seg.controller.dispose();
          }
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
    //
    // Win11 反馈后续修复 Q1：连续的 TextBlock + 行内 FormulaBlock
    // （displayMode=false）归并成一个 [_DraftParagraph]（一张段落卡），
    // 底层块顺序不变；分组在行间公式 / 表格 / 标题 / 图块 / 代码 /
    // ImageFallback 处断开。解析器本身不动（M1-S1 锁死块模型），
    // 只读渲染的归并口径见 QuestionContentRenderer.flushInline。
    final blocks = buildContentBlocks(
      stemMarkdown: question.ocrStem ?? '',
      figures: figures,
      mdResults: mdResults,
    );
    // Q2 REV2 §5.1(a)：展开块的起源表（与 blocks 一一对应；图块为 null），
    // 供拖动计数用（切分出的两段共享同一原块下标）。
    final origins = expandedBlockOrigins(
      stemMarkdown: question.ocrStem ?? '',
      figures: figures,
      mdResults: mdResults,
    );
    final byId = {for (final f in figures) f.id: f};
    final drafts = <_DraftBlock>[];
    var run = <_DraftBlock>[];
    void flushRun() {
      if (run.isEmpty) return;
      drafts.add(_DraftParagraph(run));
      run = <_DraftBlock>[];
    }

    for (var bi = 0; bi < blocks.length; bi++) {
      final block = blocks[bi];
      final origin = origins[bi];
      switch (block) {
        case TextBlock(:final text):
          run.add(_DraftText(text, origin: origin));
        case FormulaBlock(:final latex, :final displayMode):
          if (displayMode) {
            flushRun();
            drafts.add(
              _DraftFormula(latex, displayMode: true, origin: origin),
            );
          } else {
            run.add(_DraftFormula(latex, origin: origin));
          }
        case CodeBlock(:final code, :final language):
          flushRun();
          drafts.add(
            _DraftCode(code, language: language, origin: origin),
          );
        case ImageFallbackBlock():
          flushRun();
          drafts.add(_DraftText('', origin: origin));
        case FigureBlock(:final figureId):
          flushRun();
          drafts.add(
            _DraftFigure(byId[figureId] ?? _placeholderFigure(figureId)),
          );
        // WP-C #6：表格/标题在纠错编辑器里以可再解析的文本形式进草稿
        // （表格拼回 HTML、标题拼回 `#` 行），保存时重新解析，不丢内容。
        // 它们各成独立草稿，不并进段落卡。
        case TableBlock():
          flushRun();
          drafts.add(
            _DraftText(blocksToMarkdown([block]), origin: origin),
          );
        case HeadingBlock(:final text, :final level):
          flushRun();
          drafts.add(
            _DraftText('${'#' * level} $text', origin: origin),
          );
      }
    }
    flushRun();
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

  /// 标题行末补换行（A3，仅保存时用，不动编辑器里的显示文本）。
  ///
  /// 标题行的语法是行首 `#{1,3}` + 空格/制表符、读到行尾为止
  ///（与解析器 `_findNextHeading` 的判定一致）；草稿里的标题
  /// 以 `'# 标题'` 形式存为纯文本、无尾换行，若其末行是标题行，
  /// 保存时补一个 `'\n'`，否则后文直接拼在同一行、再解析时被
  /// 标题吞掉。末行不是标题行、或已有尾换行时原样返回。
  static String _terminateHeadingLine(String text) {
    if (text.isEmpty || text.endsWith('\n')) return text;
    final lastBreak = text.lastIndexOf('\n');
    final lastLine = lastBreak < 0
        ? text
        : text.substring(lastBreak + 1);
    if (RegExp(r'^#{1,3}[ \t]').hasMatch(lastLine)) return '$text\n';
    return text;
  }

  /// 草稿按块拼回题干（保存用）。空文字段跳过；恢复为原图的公式
  /// 从题干里拿掉（以原图显示，见文件头）；其余按 [blocksToMarkdown]。
  /// 图块不拼回题干（只存在 ocr_figures 里，见 question_content.dart）。
  /// 段落卡按段内顺序展开成原块序列再拼回：绝不扁平成显示串，
  /// 换行/空行原样保留，不做任何 trim 与空白规范化。
  /// 标题草稿（`'# 标题'` 形式的纯文本）末行是标题行时补一个尾换行
  ///（[_terminateHeadingLine]，A3）：标题行读到行尾为止，草稿里
  /// 标题行无尾换行，后文直接拼在同一行会被标题吞掉。
  String _draftsToMarkdown() {
    final blocks = <QuestionContentBlock>[];
    void addDraft(_DraftBlock draft, {required bool isLast}) {
      switch (draft) {
        case _DraftText(:final controller):
          // 只有后面还有草稿时才补标题行尾换行：标题在末尾时不补，
          // 保存结果不给原题干多加尾换行（往返须原样）。
          final text = isLast
              ? controller.text
              : _terminateHeadingLine(controller.text);
          if (text.isNotEmpty) {
            blocks.add(TextBlock(text));
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
        case _DraftParagraph(:final segments):
          for (var j = 0; j < segments.length; j++) {
            addDraft(
              segments[j],
              isLast: isLast && j + 1 == segments.length,
            );
          }
        case _DraftFigure():
          break;
      }
    }

    for (var i = 0; i < _drafts.length; i++) {
      addDraft(_drafts[i], isLast: i + 1 == _drafts.length);
    }
    return blocksToMarkdown(blocks);
  }

  /// 草稿里第 [formula] 个公式是第几个公式（裁图下标用，
  /// 按题干里 FormulaBlock 的出现顺序计；段落卡内按段内顺序计）。
  int _formulaIndexOf(_DraftFormula formula) {
    var index = 0;
    for (final draft in _drafts) {
      switch (draft) {
        case _DraftParagraph(:final segments):
          for (final seg in segments) {
            if (identical(seg, formula)) return index;
            if (seg is _DraftFormula) index++;
          }
        case _DraftFormula():
          if (identical(draft, formula)) return index;
          index++;
        default:
          break;
      }
    }
    return index;
  }

  /// Win11 反馈包 3：块间隔槽（落点）。
  ///
  /// [gap] 是插入下标（插到 `_drafts[gap]` 之前；gap == 长度时插末尾）。
  /// 槽高固定 10px（命中范围稳定，显不显线都不改布局）；拖到槽上时
  /// 槽内显一条 3px 主色插入线。只接受当前草稿里有的图块 ID。
  Widget _dropGap(int gap) {
    return DragTarget<String>(
      key: Key('figure-drop-gap-$gap'),
      onWillAcceptWithDetails: (details) =>
          _drafts.any((d) => d is _DraftFigure && d.figure.id == details.data),
      onAcceptWithDetails: (details) => _moveFigureToGap(details.data, gap),
      builder: (context, candidateData, rejectedData) {
        final active = candidateData.isNotEmpty;
        return SizedBox(
          height: 10,
          child: Center(
            child: Container(
              height: active ? 3 : 2,
              decoration: BoxDecoration(
                color: active
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Win11 反馈包 3：图块左上角的拖动柄（⋮⋮）。
  ///
  /// 柄是独立响应区：只有按住柄才能拖图块（整个图块不响应拖动，
  /// 避免被父级滚动手势抢走；柄之外仍可正常滚动）。鼠标直接拖；
  /// 触屏从柄上拖起（柄只有 20px，不占滚动地盘）。拖动中原位置的柄
  /// 变淡，指针旁跟一张小卡片；拖到滚动区上下边缘时自动滚动。
  Widget _dragHandle(OcrFigure figure) {
    return Draggable<String>(
      key: Key('figure-drag-handle-${figure.id}'),
      data: figure.id,
      feedback: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 160,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border.all(color: Theme.of(context).colorScheme.outline),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.drag_indicator, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '配图 ${figure.id}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: const Opacity(
        opacity: 0.4,
        child: Icon(Icons.drag_indicator, size: 20),
      ),
      onDragUpdate: (details) => _maybeAutoScroll(details.globalPosition),
      child: const MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Icon(Icons.drag_indicator, size: 20),
      ),
    );
  }

  /// Win11 反馈包 3：拖到滚动区上下边缘时自动滚动（题干再长也能拖过去）。
  /// 滚速固定一小步（每收到一次拖动更新滚 24px），到顶/底即停；
  /// 外层没有可滚容器时静默不做（不抛、不拦拖动）。
  void _maybeAutoScroll(Offset globalPosition) {
    final scrollable = Scrollable.maybeOf(context);
    if (scrollable == null) return;
    final position = scrollable.position;
    if (!position.hasContentDimensions) return;
    final renderBox =
        scrollable.context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return;
    final viewportTop = renderBox.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + renderBox.size.height;
    const edgeDistance = 64.0;
    const step = 24.0;
    if (globalPosition.dy < viewportTop + edgeDistance) {
      final target = (position.pixels - step).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (target != position.pixels) position.jumpTo(target);
    } else if (globalPosition.dy > viewportBottom - edgeDistance) {
      final target = (position.pixels + step).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (target != position.pixels) position.jumpTo(target);
    }
  }

  /// Win11 反馈包 3：图块落到间隔槽 [gap]（插到 `_drafts[gap]` 之前）。
  ///
  /// manual 落点（Q2 REV2 §5.1）：按去重后的原块下标计数——切分出的
  /// 两段共享同一原块下标，只计 1；只有落点恰好在某切分块的两段之间
  /// 时，才记 `"h:s"` 格式（`h` = 原块下标，`s` = 后一段的段序号），
  /// 其余落点记 `"h"`（落点前有几个不同原块）。起源信息存在草稿段
  /// 自身上（[_DraftText.origin] 等），删段时随段一起走，不会错位。
  /// 原位（gap 紧贴图块自身两侧）不调保存；取消拖动时本函数根本
  /// 不被调用（拖动中不改草稿，取消即恢复原顺序、不写库）；保存
  /// 失败（回调返回 false / 未接线）时回滚到原顺序，不假装已保存。
  Future<void> _moveFigureToGap(String figureId, int gap) async {
    final from = _drafts.indexWhere(
      (d) => d is _DraftFigure && d.figure.id == figureId,
    );
    if (from < 0) return;
    var to = gap > from ? gap - 1 : gap;
    if (to == from) return;
    final previous = [..._drafts];
    final drafts = [..._drafts];
    final moved = drafts.removeAt(from);
    drafts.insert(to, moved);
    final movedTextAt = _manualAnchorForGap(drafts, to);
    final orderedIds = [
      for (final d in drafts)
        if (d is _DraftFigure) d.figure.id,
    ];
    setState(() => _drafts = drafts);
    final persist = widget.onReorderFigure;
    if (persist == null) {
      setState(() => _drafts = previous);
      return;
    }
    final ok = await persist(orderedIds, figureId, movedTextAt);
    if (!ok && mounted) setState(() => _drafts = previous);
  }

  /// 草稿 [draft] 里的全部内容起源（按顺序；图块草稿为空）。
  static List<({int orig, int part})> _contentOriginsOf(_DraftBlock draft) {
    switch (draft) {
      case _DraftParagraph(:final segments):
        return [
          for (final seg in segments)
            if (_segmentOrigin(seg) != null) _segmentOrigin(seg)!,
        ];
      case _DraftText(:final origin):
        return origin == null ? const [] : [origin];
      case _DraftCode(:final origin):
        return origin == null ? const [] : [origin];
      case _DraftFormula(:final origin):
        return origin == null ? const [] : [origin];
      case _DraftFigure():
        return const [];
    }
  }

  /// 段落卡内一段的起源（文字段 / 行内公式段自带 origin）。
  static ({int orig, int part})? _segmentOrigin(_DraftBlock segment) {
    return switch (segment) {
      _DraftText(:final origin) => origin,
      _DraftFormula(:final origin) => origin,
      _DraftCode(:final origin) => origin,
      _ => null,
    };
  }

  /// 落点 [to]（插到 `drafts[to]` 之前）的 manual 落点字符串。
  /// 落点前后两段同属一个原块（即落点在切分块的两段之间）时记
  /// `"h:s"`；否则记落点前不同原块的个数（`"h"`）。
  static String _manualAnchorForGap(List<_DraftBlock> drafts, int to) {
    ({int orig, int part})? prev;
    for (var i = to - 1; i >= 0; i--) {
      final origins = _contentOriginsOf(drafts[i]);
      if (origins.isNotEmpty) {
        prev = origins.last;
        break;
      }
    }
    ({int orig, int part})? next;
    for (var i = to; i < drafts.length; i++) {
      final origins = _contentOriginsOf(drafts[i]);
      if (origins.isNotEmpty) {
        next = origins.first;
        break;
      }
    }
    if (prev != null && next != null && prev.orig == next.orig) {
      return '${next.orig}:${next.part}';
    }
    final seen = <int>{};
    for (var i = 0; i < to; i++) {
      for (final o in _contentOriginsOf(drafts[i])) {
        seen.add(o.orig);
      }
    }
    return '${seen.length}';
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
          '普通文字直接改；公式可看、可删、可恢复为原图；配图可删除，按住配图左上角 ⋮⋮ 可拖动换位',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 8),
        if (_drafts.isEmpty)
          const Text(
            '还没有识别出的题干，可以直接输入',
            style: TextStyle(fontSize: 13),
          ),
        // Win11 反馈包 3：每两个相邻段之间一条间隔槽（DragTarget）。
        // 间隔槽平时是 10px 的空白（代替原来的 SizedBox 间距），拖图块
        // 时经过的槽显插入线；图块只能落在槽里——文字块是原子段，不会
        // 被图块拆开，也拖不出题干区。
        for (var i = 0; i <= _drafts.length; i++) ...[
          _dropGap(i),
          if (i < _drafts.length) _draftBlockWidget(_drafts[i], i),
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

  Widget _draftBlockWidget(_DraftBlock draft, int index) {
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
      case _DraftParagraph():
        return _paragraphWidget(draft, index);
      case _DraftFigure(:final figure, :final deleted):
        return _figureBlockWidget(draft, figure, deleted);
    }
  }

  /// Win11 反馈后续修复 Q1：复合段落卡。
  ///
  /// 一张卡装一段连续文本 + 行内公式（按原块顺序上下排列）：
  /// 每段文字是独立的无边框 TextField（各持自己的 controller，
  /// 改一段不碰相邻段）；每个行内公式是只读的 FormulaView + 恢复 /
  /// 删除按钮（点公式本身不进文字编辑）。卡外只有一道边框，
  /// 题干不再被行内公式切成多张卡。
  Widget _paragraphWidget(_DraftParagraph paragraph, int index) {
    return Container(
      key: Key('stem-paragraph-card-$index'),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var s = 0; s < paragraph.segments.length; s++)
            switch (paragraph.segments[s]) {
              _DraftText(:final controller) => TextField(
                key: Key('stem-paragraph-text-$index-$s'),
                controller: controller,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  hintText: '题干文字',
                  contentPadding: EdgeInsets.zero,
                  isDense: true,
                ),
              ),
              _DraftFormula(:final latex, :final displayMode) =>
                _paragraphFormulaWidget(
                  paragraph,
                  paragraph.segments[s] as _DraftFormula,
                  latex,
                  displayMode,
                  index,
                  s,
                ),
              _ => const SizedBox.shrink(),
            },
        ],
      ),
    );
  }

  /// 段落卡内的行内公式段：只读渲染 + 恢复为原图 / 删除（与独立
  /// 公式卡 [_formulaBlockWidget] 同款动作、同一份裁图下标逻辑，
  /// 只是不另套卡边框）。删公式只摘掉本段：相邻文字段原样保留，
  /// 不合并、不改字；段内删空时整张段落卡随之消失。
  Widget _paragraphFormulaWidget(
    _DraftParagraph paragraph,
    _DraftFormula formula,
    String latex,
    bool displayMode,
    int paragraphIndex,
    int segmentIndex,
  ) {
    return Container(
      key: Key('stem-paragraph-formula-$paragraphIndex-$segmentIndex'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
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
                  key: Key(
                    'stem-paragraph-formula-restore-render-$paragraphIndex-$segmentIndex',
                  ),
                  onPressed: () =>
                      setState(() => formula.restoredAsImage = false),
                  child: const Text('恢复渲染'),
                )
              else
                OutlinedButton(
                  key: Key(
                    'stem-paragraph-formula-restore-image-$paragraphIndex-$segmentIndex',
                  ),
                  onPressed: () => _restoreFormulaAsImage(formula),
                  child: const Text('恢复为原图'),
                ),
              const SizedBox(width: 8),
              OutlinedButton(
                key: Key(
                  'stem-paragraph-formula-delete-$paragraphIndex-$segmentIndex',
                ),
                onPressed: () => _deleteFormulaFromParagraph(
                  paragraph,
                  formula,
                ),
                child: const Text('删除'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 段内删公式：只摘掉该公式段，相邻文字段的 controller 与文字
  /// 原样不动；段内删空时整张段落卡从草稿里移除（不留空卡）。
  void _deleteFormulaFromParagraph(
    _DraftParagraph paragraph,
    _DraftFormula formula,
  ) {
    setState(() {
      paragraph.segments.remove(formula);
      if (paragraph.segments.isEmpty) _drafts.remove(paragraph);
    });
  }

  /// Win11 反馈包 3：图块段——左上角拖动柄 + 裁图 + 删除按钮。
  /// 删除是即时落库动作（不等“保存修改”）；删除成功后本段换成
  /// 整题原图（“删除后回退整题原图”），不直接消失。
  /// 不再显示“位置未确认”标注（全部关闭，见 question_content_renderer.dart）。
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
          Row(children: [_dragHandle(figure)]),
          const SizedBox(height: 4),
          FigureImageView(cropPath: figure.cropPath),
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
