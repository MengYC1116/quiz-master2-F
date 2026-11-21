// 十五批 M1-C：C 路线文本流分页测试（M1-DESIGN.md §10/§15）。
//
// 算法测试用假断行器（46 字/行，确定性、无字体依赖）；行切分与公式
// 映射用真断行器（TextPainterSplitter，Noto 字体）。
// 注意：本文件不含任何公式源码。
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/services/pdf_export/pdf_document_builder.dart';
import 'package:quiz_master2/services/pdf_export/text_pagination.dart';

/// 假断行器：每行 floor(宽/字号) 字（510.2/11 → 46 字/行）。
class _FakeSplitter implements CTextSplitter {
  @override
  Future<void> ensureFontLoaded() async {}

  @override
  List<int> lineStartOffsets(
    String text, {
    required double widthPt,
    required double fontSizePt,
  }) {
    if (text.isEmpty) return const [0];
    final perLine = math.max(1, (widthPt / fontSizePt).floor());
    final offsets = <int>[];
    for (var i = 0; i < text.length; i += perLine) {
      offsets.add(i);
    }
    offsets.add(text.length);
    return offsets;
  }
}

CPaginableQuestion _q(
  int index,
  String text, {
  List<CLayoutBlock> extra = const [],
  String source = '',
}) =>
    CPaginableQuestion(
      questionIndex: index,
      displayNumber: index + 1,
      blocks: [
        CLayoutParagraph(CParagraph(text: text)),
        ...extra,
      ],
      sourceText: source,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CTextPaginator paginator;

  setUp(() {
    paginator = CTextPaginator(splitter: _FakeSplitter());
  });

  group('普通题流式装箱', () {
    test('三道短题同页', () {
      final plan = paginator.paginate(
        [_q(0, '短题一'), _q(1, '短题二'), _q(2, '短题三')],
      );
      expect(plan.totalPages, 1);
      expect(plan.questionCount, 3);
      expect(validatePlan(plan), isEmpty);
      final parts = plan.pages.single.parts;
      expect(parts.map((p) => p.displayNumber), [1, 2, 3]);
      expect(parts.every((p) => !p.continuation && p.last), isTrue);
    });

    test('放不下的整题移下一页（不拆分）', () {
      // 每题高：题号 18.87 + 1 行 15.97 + 分隔 8.5 ≈ 43.34；
      // 页高 100 时第一页放 2 题，第三题整题移第 2 页。
      final plan = paginator.paginate(
        [_q(0, '甲'), _q(1, '乙'), _q(2, '丙')],
        firstPageAvailableHeightPt: 100,
        otherPageAvailableHeightPt: 100,
      );
      expect(plan.totalPages, 2);
      expect(plan.pages[0].parts.map((p) => p.displayNumber), [1, 2]);
      expect(plan.pages[1].parts.map((p) => p.displayNumber), [3]);
      expect(plan.pages[1].parts.single.continuation, isFalse);
      expect(validatePlan(plan), isEmpty);
    });

    test('第一页可用高度单独算（信息区占 72.6 pt）', () {
      // 默认第一页可用 655.27，其余页 727.87；每题 1 行高约 43.34：
      // 第一页可放 15 题（15×43.34=650.1），第 16 题去第 2 页。
      final qs = List.generate(16, (i) => _q(i, '题$i'));
      final plan = paginator.paginate(qs);
      expect(plan.pages[0].parts.length, 15);
      expect(plan.pages[1].parts.length, 1);
      expect(validatePlan(plan), isEmpty);
    });

    test('题高恰等于封顶减余量时放本页（D-183 边界）', () {
      // 3 行题高 = 题号行 + 3 行正文（末题，无分隔线）；页高取
      // 题高 + 整题余量（2 行 ≈ 29.04 pt）：题高恰等于封顶减余量，
      // 整题分支仍取；再少 0.5 pt 即强制走切分支（见下一测试）。
      final h = kPdfQuestionNumberHeightPt +
          pdfTextHeightPt(
            lines: 3,
            fontSizePt: PdfExportTypography.bodyPt,
            lineSpacingPt: PdfExportTypography.bodyLineSpacingPt,
          );
      final plan = paginator.paginate(
        [_q(0, '测' * (46 * 3))],
        firstPageAvailableHeightPt: h + kWholeQuestionSafetyMarginPt,
        otherPageAvailableHeightPt: h + kWholeQuestionSafetyMarginPt,
      );
      expect(plan.totalPages, 1);
      expect(validatePlan(plan), isEmpty);
      final part = plan.pages.single.parts.single;
      expect(part.continuation, isFalse);
      expect(part.heightPt, h);
    });

    test('题高比封顶减余量多 0.5 pt 时走切分支（D-183 边界）', () {
      // 12 行题：整题分支余量不足时强制切分，首段 11 行、续段 1 行，
      // 共 2 页；规划与实际的 ±1 行偏差不再能把整题推入危险带。
      final h = kPdfQuestionNumberHeightPt +
          pdfTextHeightPt(
            lines: 12,
            fontSizePt: PdfExportTypography.bodyPt,
            lineSpacingPt: PdfExportTypography.bodyLineSpacingPt,
          );
      final pageH = h + kWholeQuestionSafetyMarginPt - 0.5;
      final plan = paginator.paginate(
        [_q(0, '测' * (46 * 12))],
        firstPageAvailableHeightPt: pageH,
        otherPageAvailableHeightPt: pageH,
      );
      expect(plan.totalPages, 2);
      expect(validatePlan(plan), isEmpty);
      final parts = [
        for (final page in plan.pages) ...page.parts,
      ];
      expect(parts.length, 2);
      expect(parts[0].continuation, isFalse);
      expect(parts[0].last, isFalse);
      expect(parts[1].continuation, isTrue);
      expect(parts[1].last, isTrue);
      expect(parts[0].blocks.single, isA<CPartRichText>());
      expect(
        (parts[0].blocks.single as CPartRichText).lines,
        11,
      );
      expect(
        (parts[1].blocks.single as CPartRichText).lines,
        1,
      );
    });
  });

  group('超长题块边界拆分', () {
    test('长文本按行切分，续页标与末段标记正确，内容无丢失', () {
      final longText = '测' * (46 * 100); // 假断行器下 100 行。
      final plan = paginator.paginate(
        [_q(0, longText)],
        firstPageAvailableHeightPt: 727.87,
        otherPageAvailableHeightPt: 727.87,
      );
      expect(plan.totalPages, greaterThan(2));
      final parts = [
        for (final page in plan.pages) ...page.parts,
      ];
      expect(parts.first.continuation, isFalse);
      expect(parts.skip(1).every((p) => p.continuation), isTrue);
      expect(parts.last.last, isTrue);
      expect(parts.take(parts.length - 1).every((p) => !p.last), isTrue);
      // 内容拼接回原文，无丢失无重复。
      final joined = parts
          .expand((p) => p.blocks)
          .whereType<CPartRichText>()
          .map((b) => b.text)
          .join();
      expect(joined, longText);
      expect(validatePlan(plan), isEmpty);
    });

    test('单个超长文本块（仅一段）可拆分', () {
      final text = '测' * (46 * 40); // 40 行，超一页。
      final plan = paginator.paginate(
        [_q(0, text)],
        firstPageAvailableHeightPt: 727.87,
        otherPageAvailableHeightPt: 727.87,
      );
      expect(plan.totalPages, 2);
      expect(validatePlan(plan), isEmpty);
    });

    test('独立公式块不可拆，整块移页', () {
      final formula = CLayoutAtomic(
        const CAtomicBlock(
          kind: CAtomicKind.displayFormula,
          ref: 'formulas/q0-f0.png',
          widthPt: 400,
          heightPt: 300,
        ),
      );
      // 文本 30 行（约 628 pt）+ 公式 300 pt：整题超页；公式必须
      // 完整落在某一段内，不可拆成两半。
      final plan = paginator.paginate(
        [_q(0, '测' * (46 * 30), extra: [formula])],
        firstPageAvailableHeightPt: 727.87,
        otherPageAvailableHeightPt: 727.87,
      );
      final images = [
        for (final page in plan.pages)
          for (final part in page.parts)
            for (final b in part.blocks)
              if (b is CPartImage) b,
      ];
      expect(images.length, 1);
      expect(images.single.heightPt, 300);
      expect(images.single.ref, 'formulas/q0-f0.png');
      expect(validatePlan(plan), isEmpty);
    });

    test('图块原子性：图块不拆分，随题移动', () {
      final figure = CLayoutAtomic(
        const CAtomicBlock(
          kind: CAtomicKind.figure,
          ref: 'figures/q0-fig0.png',
          widthPt: 510.2,
          heightPt: 200,
        ),
      );
      final plan = paginator.paginate(
        [_q(0, '测' * (46 * 30), extra: [figure])],
        firstPageAvailableHeightPt: 727.87,
        otherPageAvailableHeightPt: 727.87,
      );
      final images = [
        for (final page in plan.pages)
          for (final part in page.parts)
            for (final b in part.blocks)
              if (b is CPartImage) b,
      ];
      expect(images.length, 1);
      expect(images.single.kind, CAtomicKind.figure);
      expect(validatePlan(plan), isEmpty);
    });

    test('超高原子块等比缩小到页内并标记 shrunk', () {
      final huge = CLayoutAtomic(
        const CAtomicBlock(
          kind: CAtomicKind.figure,
          ref: 'figures/big.png',
          widthPt: 510.2,
          heightPt: 2000,
        ),
      );
      final plan = paginator.paginate(
        [_q(0, '甲', extra: [huge])],
        firstPageAvailableHeightPt: 727.87,
        otherPageAvailableHeightPt: 727.87,
      );
      final image = [
        for (final page in plan.pages)
          for (final part in page.parts)
            for (final b in part.blocks)
              if (b is CPartImage) b,
      ].single;
      expect(image.shrunk, isTrue);
      expect(image.heightPt, lessThanOrEqualTo(677.87 + 0.01));
      expect(image.widthPt, lessThanOrEqualTo(510.2 + 0.01));
      expect(validatePlan(plan), isEmpty);
    });
  });

  group('题号唯一性与确定性', () {
    test('题号每题恰出现一次（续页段不重复题号）', () {
      final plan = paginator.paginate([
        _q(0, '测' * (46 * 100)),
        _q(1, '短题'),
        _q(2, '测' * (46 * 80)),
      ]);
      expect(validatePlan(plan), isEmpty);
      final numbers = [
        for (final page in plan.pages)
          for (final part in page.parts)
            if (!part.continuation) part.displayNumber,
      ];
      expect(numbers, [1, 2, 3]);
    });

    test('同一输入两次规划结果一致（页数、每页题目、断点位置）', () {
      final qs = [
        _q(0, '测' * (46 * 100)),
        _q(1, '短题'),
        _q(2, '测' * (46 * 80), source: '数学 · 第一章 · 期中考试'),
      ];
      final a = paginator.paginate(qs);
      final b = paginator.paginate(qs);
      expect(b.totalPages, a.totalPages);
      for (var i = 0; i < a.totalPages; i++) {
        expect(
          b.pages[i].parts.map((p) => (p.displayNumber, p.continuation, p.heightPt)).toList(),
          a.pages[i].parts.map((p) => (p.displayNumber, p.continuation, p.heightPt)).toList(),
        );
      }
    });
  });

  group('页数边界', () {
    test('恰好 20 页', () {
      // 每题独占一页（题高 700 pt，页高 727.87）。
      final qs = List.generate(
        20,
        (i) => _q(i, '测' * (46 * 30)), // 30 行 ≈ 628 + 题号/分隔 ≈ 655
      );
      final plan = paginator.paginate(
        qs,
        firstPageAvailableHeightPt: 727.87,
        otherPageAvailableHeightPt: 727.87,
      );
      expect(plan.totalPages, 20);
      expect(validatePlan(plan), isEmpty);
    });

    test('超 20 页（21 页）', () {
      final qs = List.generate(21, (i) => _q(i, '测' * (46 * 30)));
      final plan = paginator.paginate(
        qs,
        firstPageAvailableHeightPt: 727.87,
        otherPageAvailableHeightPt: 727.87,
      );
      expect(plan.totalPages, 21);
      expect(validatePlan(plan), isEmpty);
    });
  });

  group('validatePlan 自检', () {
    test('超高段与重复题号被检出', () {
      final bad = CPagePlan(
        pages: [
          CPlannedPage(parts: [
            CQuestionPart(
              questionIndex: 0,
              displayNumber: 1,
              continuation: false,
              last: true,
              blocks: const [],
              heightPt: 9999,
            ),
            CQuestionPart(
              questionIndex: 1,
              displayNumber: 1,
              continuation: false,
              last: true,
              blocks: const [],
              heightPt: 10,
            ),
          ]),
        ],
        firstPageAvailableHeightPt: 727.87,
        otherPageAvailableHeightPt: 727.87,
      );
      final violations = validatePlan(bad);
      expect(violations.length, 2);
    });
  });

  group('真断行器：行切分与行内公式映射', () {
    test('长中文按行切分后拼接回原文', () async {
      final splitter = TextPainterSplitter();
      await splitter.ensureFontLoaded();
      final realPaginator = CTextPaginator(splitter: splitter);
      final text = '已知函数满足下列条件：${'设实数满足不等式关系，且区间端点均为整数，试求满足条件的取值范围，并给出完整的推理过程。' * 40}';
      final plan = realPaginator.paginate(
        [_q(0, text)],
        firstPageAvailableHeightPt: 727.87,
        otherPageAvailableHeightPt: 727.87,
      );
      final joined = [
        for (final page in plan.pages)
          for (final part in page.parts)
            for (final b in part.blocks)
              if (b is CPartRichText) b.text,
      ].join();
      expect(joined, text);
      expect(validatePlan(plan), isEmpty);
    });

    test('行内公式恰归属一处，偏移正确，文本无丢失', () async {
      final splitter = TextPainterSplitter();
      await splitter.ensureFontLoaded();
      final realPaginator = CTextPaginator(splitter: splitter);
      // 公式位于第 200 字处（宽约 44 pt，约 4 个全角字占位）。
      final before = '测' * 200;
      final after = '测' * (46 * 60);
      final paragraph = CParagraph(
        text: before + after,
        inlineFormulas: const [
          CInlineFormula(
            offset: 200,
            widthPt: 44,
            heightPt: 16,
            formulaId: 'f0',
            ref: 'formulas/q0-f0.png',
          ),
        ],
      );
      final plan = realPaginator.paginate(
        [
          CPaginableQuestion(
            questionIndex: 0,
            displayNumber: 1,
            blocks: [CLayoutParagraph(paragraph)],
          ),
        ],
        firstPageAvailableHeightPt: 727.87,
        otherPageAvailableHeightPt: 727.87,
      );
      final texts = <CPartRichText>[];
      for (final page in plan.pages) {
        for (final part in page.parts) {
          for (final b in part.blocks) {
            if (b is CPartRichText) texts.add(b);
          }
        }
      }
      expect(texts.map((t) => t.text).join(), before + after);
      final withFormula =
          texts.where((t) => t.inlineFormulas.isNotEmpty).toList();
      expect(withFormula.length, 1);
      final f = withFormula.single.inlineFormulas.single;
      expect(f.formulaId, 'f0');
      // 公式偏移 + 其前文本长度 == 原文偏移 200。
      var seen = 0;
      for (final t in texts) {
        if (identical(t, withFormula.single)) {
          expect(seen + f.offset, 200);
          break;
        }
        seen += t.text.length;
      }
    });
  });

  group('高度模型', () {
    test('pdfTextHeightPt 与探针实测一致（11 pt 12 行 ≈ 252.1）', () {
      expect(
        pdfTextHeightPt(
          lines: 12,
          fontSizePt: PdfExportTypography.bodyPt,
          lineSpacingPt: PdfExportTypography.bodyLineSpacingPt,
        ),
        closeTo(252.1, 0.5),
      );
      expect(
        pdfTextHeightPt(lines: 1, fontSizePt: 11, lineSpacingPt: 5.5),
        closeTo(15.97, 0.05),
      );
    });
  });
}
