// Win11 反馈后续修复 Q2（round 3）：题干图按段落段尾放置（REV2）。
//
// 覆盖：
// - §6 `rel <= acc` 边界契约（6.1–6.6、6.8–6.10；6.7 零长块永不为宿主
//   是结构性证明——parseQuestionContent 从不产出零长块，
//   无法经公开 API 构造，故无独立用例；其 tie 语义由 6.5 覆盖）。
// - §9.1 GPT 15 例（案例 1–15）。
// - §9.2 化学题真题（twin2/twin1，~/workspace/figure-diag/ 原样读入）。
//
// 断言口径：按相邻块内容断言，不只断言下标（§9.2 的注：twin2 fig-0
// 的 insertion_index 修复前后同为 5，只断言数值会误报通过）。
//
// 测试构造说明：md 由题干文本插入 `![](page=0,bbox=[…])` 引用得到；
// 引用插入点在题干文本中的偏移就是 rel（md 坐标减去之前引用的长度
// 后等于题干坐标；首个引用无此修正）。题干首行须在 md 里完整出现，
// 否则 _stemStartInMd 找不到题干起点、md 锚定整体失效——各用例的
// 插入点都落在首行之后。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/modules/ocr/question_content.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';

const _transform = OcrRequestTransform(
  srcW: 400,
  srcH: 500,
  reqW: 400,
  reqH: 500,
  padX: 0,
  padY: 0,
);

/// md 锚定的图块：anchorRef 为 md 引用序号；bbox 与 md 引用一致。
OcrFigure _mdFig(
  String id,
  int seq,
  int order, {
  String? optionLabel,
}) => OcrFigure(
  id: id,
  slicePath: 'slices/q1.png',
  inputHash: 'h1',
  sequenceIndex: seq,
  anchorSource: 'md',
  anchorRef: '$order',
  bbox2d: [order * 100, 0, order * 100 + 50, 50],
  spaceWidth: 400,
  spaceHeight: 500,
  transform: _transform,
  srcRect: SrcRect(x: order * 100, y: 0, width: 50, height: 50),
  cropPath: '',
  optionLabel: optionLabel,
);

/// 非 md 锚定的图块（manual / text / fallback）。
OcrFigure _fig(
  String id,
  int seq, {
  required String anchorSource,
  String anchorRef = '',
  String? optionLabel,
  int srcY = 0,
  int srcH = 100,
}) => OcrFigure(
  id: id,
  slicePath: 'slices/q1.png',
  inputHash: 'h1',
  sequenceIndex: seq,
  anchorSource: anchorSource,
  anchorRef: anchorRef,
  bbox2d: [0, 0, 50, 50],
  spaceWidth: 400,
  spaceHeight: 500,
  transform: _transform,
  srcRect: SrcRect(x: 0, y: srcY, width: 50, height: srcH),
  cropPath: '',
  optionLabel: optionLabel,
);

String _ref(int order) =>
    '![](page=0,bbox=[${order * 100}, 0, ${order * 100 + 50}, 50])';

/// 在题干文本的指定位置插入 md 引用（按位置升序），得到 md 全文。
/// 各引用在题干坐标里的 rel 就等于其插入偏移（见文件头）。
String _mdWithRefs(String stem, List<({int at, int order})> refs) {
  final sorted = [...refs]..sort((a, b) => a.at.compareTo(b.at));
  final buf = StringBuffer();
  var pos = 0;
  for (final r in sorted) {
    buf.write(stem.substring(pos, r.at));
    buf.write(_ref(r.order));
    pos = r.at;
  }
  buf.write(stem.substring(pos));
  return buf.toString();
}

List<QuestionContentBlock> _render(
  String stem,
  List<OcrFigure> figs,
  String md,
) => buildContentBlocks(stemMarkdown: stem, figures: figs, mdResults: md);

int _figIndex(List<QuestionContentBlock> blocks, String id) =>
    blocks.indexWhere((b) => b is FigureBlock && b.figureId == id);

QuestionContentBlock _before(
  List<QuestionContentBlock> blocks,
  String id,
) => blocks[_figIndex(blocks, id) - 1];

QuestionContentBlock _after(
  List<QuestionContentBlock> blocks,
  String id,
) => blocks[_figIndex(blocks, id) + 1];

String _textOf(QuestionContentBlock b) =>
    b is TextBlock ? b.text : '<${b.runtimeType}>';

Map<String, Object?> _placementDetail(
  String id,
  String stem,
  List<OcrFigure> figs,
  String md,
) {
  final diag = diagnoseFigures(
    figures: figs,
    stemMarkdown: stem,
    mdResults: md,
  );
  final row = diag.firstWhere((r) => r['figure_id'] == id);
  return row['placement_detail'] as Map<String, Object?>;
}

Map<String, Object?> _diagRow(
  String id,
  String stem,
  List<OcrFigure> figs,
  String md,
) {
  final diag = diagnoseFigures(
    figures: figs,
    stemMarkdown: stem,
    mdResults: md,
  );
  return diag.firstWhere((r) => r['figure_id'] == id);
}

/// 块序列的结构摘要（往返比较用）：类型 + 文本/公式内容。
List<String> _structureOf(List<QuestionContentBlock> blocks) => [
  for (final b in blocks)
    switch (b) {
      TextBlock(:final text) => 'TEXT:$text',
      FormulaBlock(:final latex, :final displayMode) =>
        'FORMULA:$latex:${displayMode ? 'display' : 'inline'}',
      CodeBlock(:final code) => 'CODE:$code',
      TableBlock() => 'TABLE',
      HeadingBlock(:final text) => 'HEADING:$text',
      ImageFallbackBlock() => 'IMAGE_FALLBACK',
      FigureBlock(:final figureId) => 'FIG:$figureId',
    },
];

/// runs 展开成逐项可比的列表（runs 为 null 时视作一段无样式 run）。
List<TextRun> _expandedRuns(TextBlock b) =>
    b.runs ?? [TextRun(b.text)];

/// 合并相邻同样式 run（切分点落在某 run 内时，该 run 一分为二；
/// 拼接后相邻同样式 run 应合并回原 run 再比较）。
List<TextRun> _mergedRuns(List<TextRun> runs) {
  final out = <TextRun>[];
  for (final r in runs) {
    if (out.isNotEmpty &&
        out.last.bold == r.bold &&
        out.last.italic == r.italic &&
        out.last.script == r.script) {
      final last = out.removeLast();
      out.add(
        TextRun(
          last.text + r.text,
          bold: last.bold,
          italic: last.italic,
          script: last.script,
        ),
      );
    } else {
      out.add(r);
    }
  }
  return out;
}

bool _sameRuns(List<TextRun> a, List<TextRun> b) {
  a = _mergedRuns(a);
  b = _mergedRuns(b);
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].text != b[i].text ||
        a[i].bold != b[i].bold ||
        a[i].italic != b[i].italic ||
        a[i].script != b[i].script) {
      return false;
    }
  }
  return true;
}

void main() {
  group('§6 rel <= acc 边界契约', () {
    test('rel_le_acc_6_1_rel_before_stem_start_goes_after_first_block', () {
      // 引用在题干起点之前（md 开头是图引用，题干在后）：按今天行为
      // 放第一块之后，不发明 at=0。
      const stem = '题干文字内容在此。';
      final md = '${_ref(0)}\n\n$stem';
      final figs = [_mdFig('figure-q1-0', 0, 0)];
      final blocks = _render(stem, figs, md);
      expect(blocks.length, 2);
      expect(blocks[0], isA<TextBlock>());
      expect(blocks[1], isA<FigureBlock>());
      final detail = _placementDetail('figure-q1-0', stem, figs, md);
      expect(detail['rule'], 'fallback_no_boundary');
      expect(detail['epsilon'], 0);
    });

    test('rel_le_acc_6_2_rel_at_stem_start_goes_after_first_segment', () {
      // rel==0：引用恰在题干起点。构造：题干首行就是引用原文+第一段
      // （md 与题干同文，首行即引用位置），图属于题首段，段尾即题首
      // 段之后；不产生 at=0 落点。
      final stem =
          '${_ref(0)}第一段落文字内容。\n\n\n第二段落文字内容。';
      final figs = [_mdFig('figure-q1-0', 0, 0)];
      final blocks = _render(stem, figs, stem);
      expect(_figIndex(blocks, 'figure-q1-0'), 1);
      expect(
        _textOf(_before(blocks, 'figure-q1-0')).trimRight(),
        endsWith('第一段落文字内容。'),
      );
      expect(_textOf(_after(blocks, 'figure-q1-0')), '第二段落文字内容。');
      final detail = _placementDetail('figure-q1-0', stem, figs, stem);
      expect(detail['rule'], 'segment');
      expect(detail['split_block'], 0);
    });

    test('rel_le_acc_6_3_rel_strictly_inside_block_goes_to_segment_tail', () {
      const stem = '第一段落文字。\n\n\n第二段落文字。\n\n\n第三段落文字。';
      // rel=13：在第二段中部（无邻近分隔符）→ 该段段尾（第二段之后）。
      final md = _mdWithRefs(stem, [(at: 13, order: 0)]);
      final figs = [_mdFig('figure-q1-0', 0, 0)];
      final blocks = _render(stem, figs, md);
      expect(_figIndex(blocks, 'figure-q1-0'), 1);
      expect(
        _textOf(_before(blocks, 'figure-q1-0')),
        endsWith('第二段落文字。\n\n\n'),
      );
      expect(_textOf(_after(blocks, 'figure-q1-0')), '第三段落文字。');
      final detail = _placementDetail('figure-q1-0', stem, figs, md);
      expect(detail['rule'], 'segment');
      expect(detail['split_offset'], 20);
    });

    test('rel_le_acc_6_4_rel_at_block_end_stays_after_block', () {
      // rel==acc[0]==4：恰在块 0 末尾 → 不切分，at=1（第一段之后、
      // 公式之前）；宿主块无尾分隔符，rule 为 fallback。
      const stem = '第一段 \$x\$ 第二段';
      final md = _mdWithRefs(stem, [(at: 4, order: 0)]);
      final figs = [_mdFig('figure-q1-0', 0, 0)];
      final blocks = _render(stem, figs, md);
      expect(blocks.length, 4);
      expect(_figIndex(blocks, 'figure-q1-0'), 1);
      expect(blocks[2], isA<FormulaBlock>());
      final detail = _placementDetail('figure-q1-0', stem, figs, md);
      expect(detail['rule'], 'fallback_no_boundary');
      expect(detail['split_block'], isNull);
    });

    test('rel_le_acc_6_5_boundary_belongs_to_previous_block', () {
      // rel==acc[0]==10：既是块 0 末尾又是块 1 开头，宿主是块 0 不是
      // 块 1——图在块 0 之后、公式之前；若宿主错判为公式块，图会按
      // §6.10 落到段尾（题干末尾）。
      const stem = '第一段落文字。\n\n\n\$x\$ 第二段落文字。';
      final md = _mdWithRefs(stem, [(at: 10, order: 0)]);
      final figs = [_mdFig('figure-q1-0', 0, 0)];
      final blocks = _render(stem, figs, md);
      expect(_figIndex(blocks, 'figure-q1-0'), 1);
      expect(blocks[2], isA<FormulaBlock>());
      // 块 0 以分隔符结尾：该边界即段边界，rule 为 segment。
      final detail = _placementDetail('figure-q1-0', stem, figs, md);
      expect(detail['rule'], 'segment');
    });

    test('rel_le_acc_6_6_rel_beyond_stem_goes_to_unassociated_zone', () {
      const stem = '第一段落文字内容。';
      final md = '$stem\n\n${_ref(0)}';
      final figs = [_mdFig('figure-q1-0', 0, 0)];
      final blocks = _render(stem, figs, md);
      expect(blocks.last, isA<FigureBlock>());
      expect((blocks.last as FigureBlock).unconfirmed, isTrue);
      final row = _diagRow('figure-q1-0', stem, figs, md);
      expect(row['in_unassociated_zone'], isTrue);
      final detail = _placementDetail('figure-q1-0', stem, figs, md);
      expect(detail['rule'], 'zone');
    });

    test('rel_le_acc_6_8_two_figures_same_rel_share_slot_in_order', () {
      const stem = '第一段落文字内容。\n\n\n第二段落文字内容。';
      // 两引用相邻（rel 均为 14）：同一分槽，按 sequenceIndex 排序。
      final md =
          '第一段落文字内容。\n\n${_ref(0)}${_ref(1)}\n\n第二段落文字内容。';
      final figs = [_mdFig('figure-q1-0', 0, 0), _mdFig('figure-q1-1', 1, 1)];
      final blocks = _render(stem, figs, md);
      expect(_figIndex(blocks, 'figure-q1-0'), 1);
      expect(_figIndex(blocks, 'figure-q1-1'), 2);
      expect(
        _textOf(_before(blocks, 'figure-q1-0')),
        '第一段落文字内容。\n\n\n',
      );
      expect(_textOf(_after(blocks, 'figure-q1-1')), '第二段落文字内容。');
    });

    test('rel_le_acc_6_9_rel_inside_separator_run_goes_to_that_boundary', () {
      const stem = '甲段落文字内容。\n\n\n乙段落文字内容。';
      // rel=9：在分隔符行程 [8,11) 内 → 该边界。
      final md = _mdWithRefs(stem, [(at: 9, order: 0)]);
      final figs = [_mdFig('figure-q1-0', 0, 0)];
      final blocks = _render(stem, figs, md);
      expect(_figIndex(blocks, 'figure-q1-0'), 1);
      expect(_textOf(_before(blocks, 'figure-q1-0')), '甲段落文字内容。\n\n\n');
      expect(_textOf(_after(blocks, 'figure-q1-0')), '乙段落文字内容。');
    });

    test('rel_le_acc_6_9_rel_within_epsilon_after_separator_adsorbs', () {
      // rel 在分隔符结束后 ε 内（ε=2，rel 距行程末尾 1 字）→ 吸附
      // 到该边界，而不是落到下一段段尾。见 §9.1 案例 3 同款成因。
      const stem = '第一段有公式 \$x\$ 在此。\n\n\n第二段开头文字在此。';
      final md = _mdWithRefs(stem, [(at: 19, order: 0)]);
      final figs = [_mdFig('figure-q1-0', 0, 0)];
      final blocks = _render(stem, figs, md);
      expect(_figIndex(blocks, 'figure-q1-0'), 3);
      expect(_textOf(_before(blocks, 'figure-q1-0')), ' 在此。\n\n\n');
      expect(_textOf(_after(blocks, 'figure-q1-0')), '第二段开头文字在此。');
      final detail = _placementDetail('figure-q1-0', stem, figs, md);
      expect(detail['rule'], 'segment');
      expect(detail['epsilon'], 2);
      expect(detail['split_block'], 2);
      expect(detail['split_offset'], 7);
    });

    test('rel_le_acc_6_10_rel_inside_formula_span_goes_to_segment_tail', () {
      const stem = '第一段文字 \$x\$ 第二段文字。\n\n\n第三段文字。';
      // rel=7：在行内公式 span [6,9) 内 → 包含该公式的段的段尾；
      // 图不在公式与其同段相邻文本之间，公式块本身未被切分。
      final md = _mdWithRefs(stem, [(at: 7, order: 0)]);
      final figs = [_mdFig('figure-q1-0', 0, 0)];
      final blocks = _render(stem, figs, md);
      expect(_figIndex(blocks, 'figure-q1-0'), 3);
      expect(blocks[1], isA<FormulaBlock>());
      expect(
        _textOf(_before(blocks, 'figure-q1-0')),
        ' 第二段文字。\n\n\n',
      );
      expect(_textOf(_after(blocks, 'figure-q1-0')), '第三段文字。');
      final detail = _placementDetail('figure-q1-0', stem, figs, md);
      expect(detail['rule'], 'segment');
      expect(detail['epsilon'], 0);
    });

    test('rel_le_acc_6_10_rel_at_formula_span_end_goes_to_segment_tail', () {
      const stem = '第一段文字 \$x\$ 第二段文字。\n\n\n第三段文字。';
      // rel=9：恰在公式 span 末尾（宿主仍是公式块，不是后一文本块）
      // → 与 span 内同落点。
      final md = _mdWithRefs(stem, [(at: 9, order: 0)]);
      final figs = [_mdFig('figure-q1-0', 0, 0)];
      final blocks = _render(stem, figs, md);
      expect(_figIndex(blocks, 'figure-q1-0'), 3);
      expect(
        _textOf(_before(blocks, 'figure-q1-0')),
        ' 第二段文字。\n\n\n',
      );
      expect(_textOf(_after(blocks, 'figure-q1-0')), '第三段文字。');
    });
  });

  group('§9.1 GPT 15 例', () {
    test('q2_01_figure_after_paragraph', () {
      const stem = '第一段落的文字内容在此。\n\n\n第二段落的文字内容在此。';
      final md = _mdWithRefs(stem, [(at: 14, order: 0)]);
      final figs = [_mdFig('figure-q1-0', 0, 0)];
      final blocks = _render(stem, figs, md);
      expect(_figIndex(blocks, 'figure-q1-0'), 1);
      expect(
        _textOf(_before(blocks, 'figure-q1-0')),
        '第一段落的文字内容在此。\n\n\n',
      );
      expect(_textOf(_after(blocks, 'figure-q1-0')), '第二段落的文字内容在此。');
      final detail = _placementDetail('figure-q1-0', stem, figs, md);
      expect(detail['rule'], 'segment');
      expect(detail['split_block'], 0);
      expect(detail['split_offset'], 15);
      expect(detail['epsilon'], 0);
    });

    test('q2_02_in_middle_of_paragraph_goes_to_segment_tail', () {
      const stem = '第一段落文字内容很长很长。\n\n\n第二段落文字内容也很长。';
      // rel=22：在第二段中部 → 该段段尾（即题干末尾）；不在段中、
      // 不在题干末尾之外的任何位置——段尾是模型表达上限。
      final md = _mdWithRefs(stem, [(at: 22, order: 0)]);
      final figs = [_mdFig('figure-q1-0', 0, 0)];
      final blocks = _render(stem, figs, md);
      expect(blocks.length, 2);
      expect(blocks[1], isA<FigureBlock>());
      expect(_textOf(blocks[0]), contains('第二段落文字内容也很长。'));
      final detail = _placementDetail('figure-q1-0', stem, figs, md);
      expect(detail['rule'], 'fallback_no_boundary');
    });

    test('q2_03_before_paragraph_adsorbs_to_previous_boundary', () {
      const stem = '第一段有公式 \$x\$ 在此。\n\n\n第二段开头文字在此。';
      // rel=19：在第二段开头 1 字处、行程结束后 ε 内 → 吸附到
      // 第一段之后（与案例 1 同槽，不同成因）。
      final md = _mdWithRefs(stem, [(at: 19, order: 0)]);
      final figs = [_mdFig('figure-q1-0', 0, 0)];
      final blocks = _render(stem, figs, md);
      expect(_figIndex(blocks, 'figure-q1-0'), 3);
      expect(_textOf(_before(blocks, 'figure-q1-0')), ' 在此。\n\n\n');
      expect(_textOf(_after(blocks, 'figure-q1-0')), '第二段开头文字在此。');
    });

    test('q2_04_at_paragraph_boundary_start_inside_end_same_slot', () {
      const stem = '甲段落文字内容。\n\n\n乙段落文字内容。';
      // rel 在行程起点（8）/ 行程内（9）/ 行程终点（11）：三者同一
      // 分槽、同一位置；无空块、无丢换行。
      final expected = ['甲段落文字内容。\n\n\n', '乙段落文字内容。'];
      final original = parseQuestionContent(stem).single as TextBlock;
      for (final at in [8, 9, 11]) {
        final md = _mdWithRefs(stem, [(at: at, order: 0)]);
        final figs = [_mdFig('figure-q1-0', 0, 0)];
        final blocks = _render(stem, figs, md);
        expect(blocks.length, 3, reason: 'rel=$at 时不应产出空块');
        expect(_figIndex(blocks, 'figure-q1-0'), 1, reason: 'rel=$at');
        expect(_textOf(blocks[0]), expected[0], reason: 'rel=$at');
        expect(_textOf(blocks[2]), expected[1], reason: 'rel=$at');
        // 两半拼接 = 原文。
        expect(
          (blocks[0] as TextBlock).text + (blocks[2] as TextBlock).text,
          original.text,
          reason: 'rel=$at 时两半拼接须等于原文',
        );
      }
    });

    test('q2_05_multiple_figures_in_one_block', () {
      const stem = '第一段文字。\n\n\n第二段文字。\n\n\n第三段文字。';
      // 同一 TextBlock 内两图，分属两段：一次切分出三段，两图各就
      // 其位，顺序不变；切分点不重复构造（原块只产出三段）。
      final md = _mdWithRefs(stem, [(at: 8, order: 0), (at: 18, order: 1)]);
      final figs = [_mdFig('figure-q1-0', 0, 0), _mdFig('figure-q1-1', 1, 1)];
      final blocks = _render(stem, figs, md);
      expect(
        blocks.map((b) => b is FigureBlock ? 'FIG' : _textOf(b)).toList(),
        [
          '第一段文字。\n\n\n',
          'FIG',
          '第二段文字。\n\n\n',
          'FIG',
          '第三段文字。',
        ],
      );
      expect(_figIndex(blocks, 'figure-q1-0'), 1);
      expect(_figIndex(blocks, 'figure-q1-1'), 3);
      // 三段文本拼接 = 原块文本。
      final original = parseQuestionContent(stem).single as TextBlock;
      expect(
        blocks.whereType<TextBlock>().map((b) => b.text).join(),
        original.text,
      );
    });

    test('q2_05_multiple_figures_in_one_block_with_runs', () {
      const stem = '第一段落文字内容在此。\n\n\n第二段 <strong>粗体</strong> 尾文字。';
      final original = parseQuestionContent(stem).single as TextBlock;
      expect(original.runs, isNotNull);
      final md = _mdWithRefs(stem, [(at: 13, order: 0)]);
      final figs = [_mdFig('figure-q1-0', 0, 0)];
      final blocks = _render(stem, figs, md);
      expect(blocks.length, 3);
      final part0 = blocks[0] as TextBlock;
      final part1 = blocks[2] as TextBlock;
      expect(part0.text, '第一段落文字内容在此。\n\n\n');
      expect(part1.text, '第二段 粗体 尾文字。');
      // 文本拼接 = 原文；runs 拼接（逐项：文本 + 样式）= 原 runs。
      expect(part0.text + part1.text, original.text);
      expect(
        _sameRuns(
          [..._expandedRuns(part0), ..._expandedRuns(part1)],
          _expandedRuns(original),
        ),
        isTrue,
      );
    });

    test('q2_06_equal_offsets', () {
      const stem = '第一段落文字内容。\n\n\n第二段落文字内容。';
      final md =
          '第一段落文字内容。\n\n${_ref(0)}${_ref(1)}\n\n第二段落文字内容。';
      final figs = [_mdFig('figure-q1-0', 0, 0), _mdFig('figure-q1-1', 1, 1)];
      final blocks = _render(stem, figs, md);
      expect(_figIndex(blocks, 'figure-q1-0'), 1);
      expect(_figIndex(blocks, 'figure-q1-1'), 2);
      expect(_textOf(_after(blocks, 'figure-q1-1')), '第二段落文字内容。');
    });

    test('q2_07_single_paragraph_stem_fallback_no_boundary', () {
      const stem = '第一段文字 \$x\$ 第二段文字。';
      final md = _mdWithRefs(stem, [(at: 10, order: 0)]);
      final figs = [_mdFig('figure-q1-0', 0, 0)];
      final blocks = _render(stem, figs, md);
      // 单段题干：无分隔符可切，兜底放块尾（题干末尾），不断言段中位置。
      expect(blocks.length, 4);
      expect(blocks.last, isA<FigureBlock>());
      final detail = _placementDetail('figure-q1-0', stem, figs, md);
      expect(detail['rule'], 'fallback_no_boundary');
      expect(detail['split_block'], isNull);
    });

    test('q2_08_very_long_stem_single_split', () {
      final paras = [
        for (var i = 1; i <= 11; i++) '第${i.toString().padLeft(2, '0')}段落文字。',
      ];
      final stem = paras.join('\n\n\n');
      expect(parseQuestionContent(stem).length, 1);
      // rel=64：在第 6 段之后的分隔符行程内 → 落在正确段（第 6 段后）。
      final md = _mdWithRefs(stem, [(at: 64, order: 0)]);
      final figs = [_mdFig('figure-q1-0', 0, 0)];
      final blocks = _render(stem, figs, md);
      expect(blocks.length, 3);
      expect(_figIndex(blocks, 'figure-q1-0'), 1);
      expect(
        _textOf(_before(blocks, 'figure-q1-0')).trimRight(),
        endsWith('第06段落文字。'),
      );
      expect(_textOf(_after(blocks, 'figure-q1-0')), startsWith('第07段落文字。'));
      // 单块只切一次：切出恰好两段，不是图数 × 块数的重复构造。
      expect(blocks.whereType<TextBlock>().length, 2);
    });

    test('q2_09_figure_inside_formula_offset', () {
      const stem = '第一段文字 \$x\$ 第二段文字。\n\n\n第三段文字。';
      // rel 在行内公式 span 内（7）与 span 末尾（9）：同一落点——
      // 包含该公式的段的段尾；图块不在公式与其同段相邻文本之间。
      for (final at in [7, 9]) {
        final md = _mdWithRefs(stem, [(at: at, order: 0)]);
        final figs = [_mdFig('figure-q1-0', 0, 0)];
        final blocks = _render(stem, figs, md);
        expect(_figIndex(blocks, 'figure-q1-0'), 3, reason: 'rel=$at');
        expect(blocks[1], isA<FormulaBlock>(), reason: 'rel=$at 公式块未被切分');
        expect(
          _textOf(_before(blocks, 'figure-q1-0')),
          ' 第二段文字。\n\n\n',
          reason: 'rel=$at',
        );
        expect(_textOf(_after(blocks, 'figure-q1-0')), '第三段文字。');
      }
    });

    test('q2_10_manual_anchor_with_split', () {
      const stem = '第一段落文字内容。\n\n\n第二段落文字内容。';
      final md = _mdWithRefs(stem, [(at: 11, order: 0)]);
      // 场景 A：manual "1"（原块 1 之前 = 题干末尾）相对原块不变。
      final figsA = [
        _mdFig('figure-q1-0', 0, 0),
        _fig('figure-q1-1', 1, anchorSource: 'manual', anchorRef: '1'),
      ];
      final blocksA = _render(stem, figsA, md);
      expect(_figIndex(blocksA, 'figure-q1-0'), 1);
      expect(_figIndex(blocksA, 'figure-q1-1'), 3);
      expect(blocksA.last, isA<FigureBlock>());
      // 场景 B：manual "0:1"（原块 0 的第 1 段之前）与 md 图同槽，
      // 按 sequenceIndex 排序。
      final figsB = [
        _mdFig('figure-q1-0', 0, 0),
        _fig('figure-q1-1', 1, anchorSource: 'manual', anchorRef: '0:1'),
      ];
      final blocksB = _render(stem, figsB, md);
      expect(_figIndex(blocksB, 'figure-q1-0'), 1);
      expect(_figIndex(blocksB, 'figure-q1-1'), 2);
      expect(_textOf(_after(blocksB, 'figure-q1-1')), '第二段落文字内容。');
    });

    test('q2_10_manual_anchor_hs_roundtrip_and_clamp', () {
      const stem = '第一段落文字内容。\n\n\n第二段落文字内容。';
      final md = _mdWithRefs(stem, [(at: 11, order: 0)]);
      final figs = [
        _mdFig('figure-q1-0', 0, 0),
        _fig('figure-q1-1', 1, anchorSource: 'md', anchorRef: '0'),
      ];
      // 拖动往返：manualTextAt "0:1" 写进 anchorRef，重建后位置不变。
      final reordered = reorderFigures(
        figs,
        orderedIds: ['figure-q1-1', 'figure-q1-0'],
        movedFigureId: 'figure-q1-1',
        manualTextAt: '0:1',
      );
      final moved = reordered.firstWhere((f) => f.id == 'figure-q1-1');
      expect(moved.anchorSource, 'manual');
      expect(moved.anchorRef, '0:1');
      final blocks = _render(stem, reordered, md);
      expect(_figIndex(blocks, 'figure-q1-1'), 1);
      expect(_textOf(_before(blocks, 'figure-q1-1')), '第一段落文字内容。\n\n\n');
      // 非法值钳制到最近合法分槽，不丢图、不抛错。
      for (final bad in ['0:99', '99', 'abc', '0:-1']) {
        final badFigs = [
          _mdFig('figure-q1-0', 0, 0),
          _fig('figure-q1-1', 1, anchorSource: 'manual', anchorRef: bad),
        ];
        final badBlocks = _render(stem, badFigs, md);
        expect(
          badBlocks.whereType<FigureBlock>().map((b) => b.figureId).toList(),
          containsAll(['figure-q1-0', 'figure-q1-1']),
          reason: 'anchorRef=$bad 时不丢图',
        );
        // "0:99" 钳制到块尾（题干末尾）；其余钳制到序列末尾。
        if (bad == '0:99') {
          expect(_figIndex(badBlocks, 'figure-q1-1'), 3);
        }
      }
    });

    test('q2_11_text_anchor_translated_through_split', () {
      const stem = '第一段落文字内容。\n\n\n第二段落文字内容。';
      final md = _mdWithRefs(stem, [(at: 11, order: 0)]);
      // text 图：纵向比例 0.5 × 1 块 → at=0（题干最前）；md 图触发
      // 的切分不改变它的视觉区间。
      final figs = [
        _mdFig('figure-q1-0', 0, 0),
        _fig(
          'figure-q1-1',
          1,
          anchorSource: 'text',
          anchorRef: 'text-0',
          srcY: 200,
          srcH: 100,
        ),
      ];
      final blocks = _render(stem, figs, md);
      expect(_figIndex(blocks, 'figure-q1-1'), 0);
      expect(_figIndex(blocks, 'figure-q1-0'), 2);
      expect(_textOf(_after(blocks, 'figure-q1-0')), '第二段落文字内容。');
      final detail = _placementDetail('figure-q1-1', stem, figs, md);
      expect(detail['rule'], 'text');
      // 无切分时与今天逐字一致：同一 text 图、同一题干、无 md 图。
      final plain = _render(stem, [figs[1]], '第一段落文字内容。');
      expect(plain.length, 2);
      expect(plain[0], isA<FigureBlock>());
      expect((plain[0] as FigureBlock).figureId, 'figure-q1-1');
    });

    test('q2_12_fallback_anchor_goes_to_unassociated_zone', () {
      const stem = '第一段落文字内容。\n\n\n第二段落文字内容。';
      final figs = [_fig('figure-q1-0', 0, anchorSource: 'fallback')];
      final blocks = _render(stem, figs, '第一段落文字内容。');
      expect(blocks.last, isA<FigureBlock>());
      expect((blocks.last as FigureBlock).unconfirmed, isTrue);
      final row = _diagRow('figure-q1-0', stem, figs, '第一段落文字内容。');
      expect(row['in_unassociated_zone'], isTrue);
    });

    test('q2_13_option_figure_unaffected_by_stem_split', () {
      const stem =
          '第一段落文字。\n\n\n第二段落文字。\n\n'
          '<div>A. 选项甲</div>\n\n<div>B. 选项乙</div>\n\n'
          '<div>C. 选项丙</div>\n\n<div>D. 选项丁</div>';
      // 题干解析为 5 块：一段题干文本 + 4 个选项标号块。
      final parsed = parseQuestionContent(stem);
      expect(parsed.length, 5);
      expect(_textOf(parsed[4]), 'D. 选项丁');
      // md 图在题干两段之间；D 图引用在 D 标号 div 内。
      final md =
          '第一段落文字。\n${_ref(0)}\n\n第二段落文字。\n\n'
          '<div>A. 选项甲</div>\n\n<div>B. 选项乙</div>\n\n'
          '<div>C. 选项丙</div>\n\n<div>D. 选项丁${_ref(1)}</div>';
      final figs = [
        _mdFig('figure-q1-0', 0, 0),
        _mdFig('figure-q1-1', 1, 1, optionLabel: 'D'),
      ];
      final blocks = _render(stem, figs, md);
      // md 图在两段之间；选项图位置不变（标号块之后、序列末尾）。
      expect(_figIndex(blocks, 'figure-q1-0'), 1);
      expect(
        _textOf(_before(blocks, 'figure-q1-0')),
        '第一段落文字。\n\n\n',
      );
      expect(_textOf(_after(blocks, 'figure-q1-0')), '第二段落文字。\n\n');
      expect(blocks.last, isA<FigureBlock>());
      expect((blocks.last as FigureBlock).figureId, 'figure-q1-1');
      expect(_textOf(blocks[blocks.length - 2]), 'D. 选项丁');
      final detail = _placementDetail('figure-q1-1', stem, figs, md);
      expect(detail['rule'], 'option');
    });

    test('q2_14_unassociated_figure', () {
      // (a) 引用超出题干范围 → 未关联区。
      const stemA = '第一段落文字内容。';
      final mdA = '$stemA\n\n${_ref(0)}';
      final figsA = [_mdFig('figure-q1-0', 0, 0)];
      final blocksA = _render(stemA, figsA, mdA);
      expect(blocksA.last, isA<FigureBlock>());
      expect(
        _diagRow('figure-q1-0', stemA, figsA, mdA)['in_unassociated_zone'],
        isTrue,
      );
      // (b) 选项图但题干块里无标号块 → 未关联区。
      const stemB = '第一段落文字内容。\n\n\n第二段落文字内容。';
      final figsB = [_mdFig('figure-q1-0', 0, 0, optionLabel: 'D')];
      final blocksB = _render(
        stemB,
        figsB,
        _mdWithRefs(stemB, [(at: 14, order: 0)]),
      );
      expect(blocksB.last, isA<FigureBlock>());
      expect(
        _diagRow(
          'figure-q1-0',
          stemB,
          figsB,
          _mdWithRefs(stemB, [(at: 14, order: 0)]),
        )['in_unassociated_zone'],
        isTrue,
      );
    });

    test('q2_15_save_reopen_roundtrip', () {
      const stem = '第一段落文字 \$x\$ 内容。\n\n\n第二段落文字内容。';
      final md = _mdWithRefs(stem, [(at: 16, order: 0)]);
      final figs = [_mdFig('figure-q1-0', 0, 0)];
      final rendered = _render(stem, figs, md);
      // 拼回文本与原题干逐字一致（跳过图块；\$x\$ 无空格，无归一化差）。
      final roundtripped = blocksToMarkdown(rendered);
      expect(roundtripped, stem);
      // 再解析得原块序列。
      expect(
        _structureOf(parseQuestionContent(roundtripped)),
        _structureOf(parseQuestionContent(stem)),
      );
      // ocr_figures JSON 编解码往返后渲染序列一致、insertion_index 一致。
      final decoded = parseOcrFigures(encodeOcrFigures(figs));
      final rendered2 = _render(stem, decoded, md);
      expect(_structureOf(rendered2), _structureOf(rendered));
      final idx1 = _diagRow('figure-q1-0', stem, figs, md)['insertion_index'];
      final idx2 =
          _diagRow('figure-q1-0', stem, decoded, md)['insertion_index'];
      expect(idx2, idx1);
    });
  });

  group('§9.2 化学题真题（twin2/twin1，原样读入）', () {
    const dir = '/home/hatch/workspace/figure-diag';

    test('q2_twin2_fig0_after_first_segment_not_at_stem_end', () {
      final stem = File('$dir/twin2_stem.md').readAsStringSync();
      final figs = parseOcrFigures(
        File('$dir/twin2_figures.json').readAsStringSync(),
      );
      final md = File('$dir/twin2_md.md').readAsStringSync();
      expect(figs.length, 2);
      final blocks = _render(stem, figs, md);
      // fig-0 之前一块是 TextBlock，以“不随温度而改变。”结尾（(1) 段尾）；
      // fig-0 之后一块是 TextBlock，以“该反应的正反应活化能”开头（填空行段）。
      expect(_figIndex(blocks, figs[0].id), 5);
      final before = _before(blocks, figs[0].id);
      expect(before, isA<TextBlock>());
      expect(_textOf(before).trimRight(), endsWith('不随温度而改变。）'));
      final after = _after(blocks, figs[0].id);
      expect(after, isA<TextBlock>());
      expect(_textOf(after), startsWith('该反应的正反应活化能'));
      // insertion_index 仍是 5（数值与修复前相同），但含义变了：
      // 修复前是“5 个内容块之后 = 题干末尾”，修复后是“(1) 段之后、
      // 填空行之前”——只断言数值会误报通过，故上面断言了相邻块内容。
      final row = _diagRow(figs[0].id, stem, figs, md);
      expect(row['insertion_index'], 5);
      expect(row['in_unassociated_zone'], isFalse);
      expect(row['anchor_source'], 'md');
      expect(row['md_ref_offset'], 101);
      expect(row['stem_start_in_md'], 0);
      final detail = _placementDetail(figs[0].id, stem, figs, md);
      expect(detail['rule'], 'segment');
      expect(detail['split_block'], 4);
      expect(detail['split_offset'], 38);
      expect(detail['epsilon'], 4);
      // fig-1（选项 D）仍在未关联区、序列末尾。
      expect(blocks.last, isA<FigureBlock>());
      expect((blocks.last as FigureBlock).figureId, figs[1].id);
      expect(
        _diagRow(figs[1].id, stem, figs, md)['in_unassociated_zone'],
        isTrue,
      );
    });

    test('q2_twin2_roundtrip_blocks_to_markdown', () {
      final stem = File('$dir/twin2_stem.md').readAsStringSync();
      final figs = parseOcrFigures(
        File('$dir/twin2_figures.json').readAsStringSync(),
      );
      final md = File('$dir/twin2_md.md').readAsStringSync();
      final blocks = _render(stem, figs, md);
      // 拼回（跳过图块）：公式两侧空格有既有归一化（`$ \Delta G $` →
      // `$\Delta G$`，解析器去空格、拼回不补空格，Q2 未动此行为），
      // 故按归一化后逐字比较；结构上再解析得原块序列。
      String normalize(String s) => s.replaceAllMapped(
        RegExp(r'\$\s+(.+?)\s+\$'),
        (m) => '\$${m.group(1)}\$',
      );
      expect(normalize(blocksToMarkdown(blocks)), normalize(stem));
      expect(
        _structureOf(parseQuestionContent(blocksToMarkdown(blocks))),
        _structureOf(parseQuestionContent(stem)),
      );
    });

    test('q2_twin1_manual_anchor_unchanged', () {
      final stem = File('$dir/twin1_stem.md').readAsStringSync();
      final figs = parseOcrFigures(
        File('$dir/twin1_figures.json').readAsStringSync(),
      );
      final md = File('$dir/twin1_md.md').readAsStringSync();
      expect(figs.length, 2);
      expect(figs[0].anchorSource, 'manual');
      expect(figs[0].anchorRef, '2');
      final blocks = _render(stem, figs, md);
      // twin1 无 md 题干图、无切分，展开 = 原序列，manual 图位置不变：
      // 在 ΔG 公式块之后、“和压强平衡常数”文本块之前。
      expect(_figIndex(blocks, figs[0].id), 2);
      expect(blocks[1], isA<FormulaBlock>());
      expect(_textOf(blocks[3]), startsWith('和压强平衡常数'));
      // fig-1（选项 D）仍在未关联区、序列末尾。
      expect(blocks.last, isA<FigureBlock>());
      expect((blocks.last as FigureBlock).figureId, figs[1].id);
      expect(
        _diagRow(figs[1].id, stem, figs, md)['in_unassociated_zone'],
        isTrue,
      );
    });
  });
}
