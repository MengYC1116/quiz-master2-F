// 十八批 P1（D-216）：公式基线对齐回归测试。
//
// 覆盖：
// - 栅格化器量出并报出基线偏移（行内 / 独立缩小 / 原图降级为 null）；
// - PDF 像素级：样例公式基线与文字基线对齐（反证：基线未知时旧居中
//   使公式浮起）；
// - 分页行高模型：基线对齐的行高与构建器实际行高一致（差分断言）；
// - Word：下移量换算、导出后 document.xml 注入（位置与值）、
//   zip 重建后仍为合法 docx、构建器按文档顺序记录下移表。
// 本文件不含任何公式源码以外的敏感内容；测试串只用最简占位形式。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:docx_creator/docx_creator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:quiz_master2/services/pdf_export/c_content_builder.dart';
import 'package:quiz_master2/services/pdf_export/export_route.dart';
import 'package:quiz_master2/services/pdf_export/export_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/export_versions.dart';
import 'package:quiz_master2/services/pdf_export/formula_rasterizer.dart';
import 'package:quiz_master2/services/pdf_export/pdf_document_builder.dart';
import 'package:quiz_master2/services/pdf_export/pdf_font.dart';
import 'package:quiz_master2/services/pdf_export/text_pagination.dart';
import 'package:quiz_master2/services/pdf_render_service.dart';
import 'package:quiz_master2/services/word_export/word_content_builder.dart';
import 'package:quiz_master2/services/word_export/word_delivery.dart';
import 'package:quiz_master2/services/word_export/word_formula_baseline.dart';

import 'b16_word_test_helpers.dart';

/// 挂载探针：首帧后把栅格化器挂到 Overlay 上（同 b15_m1c_formula_test）。
class _AttachProbe extends StatefulWidget {
  const _AttachProbe({required this.rasterizer});

  final FormulaRasterizer rasterizer;

  @override
  State<_AttachProbe> createState() => _AttachProbeState();
}

class _AttachProbeState extends State<_AttachProbe> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.rasterizer.attach(context);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// 假断行器：每行 floor(宽/字号) 字（同 b15_m1c_pagination_test）。
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late FormulaRasterizer rasterizer;

  setUp(() {
    // Win11 上 HOME 未设；用系统临时目录，避免拼出相对路径 null/workspace/…。
    tempRoot = Directory(
      '${Directory.systemTemp.path}/b18-p1-baseline',
    )..createSync(recursive: true);
    rasterizer = FormulaRasterizer();
  });

  tearDown(() {
    rasterizer.detach();
    try {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  Directory newTempDir(String name) =>
      Directory('${tempRoot.path}$name')..createSync(recursive: true);

  Future<void> pumpAttached(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: _AttachProbe(rasterizer: rasterizer)),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(rasterizer.isAttached, isTrue);
  }

  /// 驱动一个栅格化 future 直到完成（同 b15_m1c_formula_test 的 drive）。
  Future<T> drive<T>(WidgetTester tester, Future<T> Function() start) async {
    Object? error;
    StackTrace? stack;
    final result = await tester.runAsync<T?>(() async {
      try {
        final future = start();
        var rounds = 0;
        while (rounds < 200) {
          await tester.pump();
          final result = await Future.any<Object?>([
            future,
            Future<void>.delayed(const Duration(milliseconds: 10)),
          ]);
          if (result is T) return result;
          rounds++;
        }
        throw StateError('future 未在 200 轮内完成（疑似挂起）');
      } catch (e, s) {
        error = e;
        stack = s;
        return null;
      }
    });
    if (error != null) Error.throwWithStackTrace(error!, stack!);
    return result as T;
  }

  Future<FormulaRasterResult> render(
    WidgetTester tester,
    FormulaRasterRequest request,
    Directory tempDir,
  ) async {
    return drive(tester, () => rasterizer.rasterize(request, tempDir: tempDir));
  }

  group('栅格化器报基线偏移（D-216）', () {
    testWidgets('行内公式：基线偏移在图内、近底边（无下沉量）', (tester) async {
      await pumpAttached(tester);
      final result = await render(
        tester,
        const FormulaRasterRequest(
          formulaId: 'q0-f0',
          latex: 'x^2',
          displayMode: false,
        ),
        newTempDir('/inline-baseline'),
      );
      expect(result.baselineOffsetPt, isNotNull);
      expect(result.baselineOffsetPt, greaterThan(0));
      // 基线在图内（允许 0.5 pt 量取舍入）。
      expect(
        result.baselineOffsetPt!,
        lessThanOrEqualTo(result.logicalHeightPt + 0.5),
      );
      // x^2 无下沉：基线近底边，下沉量（高 − 基线）< 1 pt。
      expect(
        result.logicalHeightPt - result.baselineOffsetPt!,
        lessThan(1),
      );
    });

    testWidgets('含分式的行内公式：基线在图内、下沉量约 3–4 pt', (tester) async {
      await pumpAttached(tester);
      final result = await render(
        tester,
        const FormulaRasterRequest(
          formulaId: 'q0-f0',
          latex: r'\frac{1}{2}+x',
          displayMode: false,
        ),
        newTempDir('/frac-baseline'),
      );
      expect(result.baselineOffsetPt, isNotNull);
      final under = result.logicalHeightPt - result.baselineOffsetPt!;
      expect(under, greaterThan(2));
      expect(under, lessThan(6));
    });

    testWidgets('超长独立公式缩小后：基线同比缩放、仍在图内', (tester) async {
      await pumpAttached(tester);
      final longLatex = List.filled(80, 'a').join('+');
      final result = await render(
        tester,
        FormulaRasterRequest(
          formulaId: 'q0-f0',
          latex: longLatex,
          displayMode: true,
        ),
        newTempDir('/long-baseline'),
      );
      expect(result.shrunk, isTrue);
      expect(result.baselineOffsetPt, isNotNull);
      expect(result.baselineOffsetPt, greaterThan(0));
      expect(
        result.baselineOffsetPt!,
        lessThanOrEqualTo(result.logicalHeightPt + 0.5),
      );
    });

    testWidgets('原图降级：基线偏移为 null（未知，不猜）', (tester) async {
      await pumpAttached(tester);
      final tempDir = newTempDir('/original-baseline');
      final verdict = await drive(
        tester,
        () => rasterizer.rasterizeQuestionFormulas(
          requests: const [
            FormulaRasterRequest(
              formulaId: 'q0-f0',
              latex: r'\badcommand{',
              displayMode: false,
            ),
          ],
          tempDir: tempDir,
          cropOriginal: (index) async => makePng(200, 50),
        ),
      );
      expect(verdict.outcomes[0].kind, FormulaQuestionOutcomeKind.original);
      expect(verdict.outcomes[0].result!.baselineOffsetPt, isNull);
    });
  });

  group('PDF 基线对齐（像素级）', () {
    /// 用已栅格化的公式建一份单行 C 文档并渲染第 1 页，返回解码后的页图。
    ///
    /// 文本为 `x x`，公式插在偏移 2 处（空格后、第二个 x 前），左右
    /// 各一个文字 x 供量基线。返回（页图像素，公式行墨迹的 y 范围）。
    Future<img.Image> renderSingleLinePdf(
      WidgetTester tester,
      FormulaRasterResult result,
      Directory tempDir, {
      double? baselineOverride,
      bool useBaseline = true,
    }) async {
      final font = PdfExportFont.fontFromBytes(
        File('assets/fonts/NotoSansSC-Regular.ttf').readAsBytesSync(),
      );
      final plan = CPagePlan(
        pages: [
          CPlannedPage(
            parts: [
              CQuestionPart(
                questionIndex: 0,
                displayNumber: 1,
                continuation: false,
                last: true,
                blocks: [
                  CPartRichText(
                    text: 'x x',
                    inlineFormulas: [
                      CInlineFormula(
                        offset: 2,
                        widthPt: result.logicalWidthPt,
                        heightPt: result.logicalHeightPt,
                        formulaId: 'q0-f0',
                        ref: result.relativePath,
                        baselineOffsetPt: useBaseline
                            ? (baselineOverride ?? result.baselineOffsetPt)
                            : null,
                      ),
                    ],
                    fontSizePt: PdfExportTypography.bodyPt,
                    lines: 1,
                  ),
                ],
                heightPt: 100,
              ),
            ],
          ),
        ],
        firstPageAvailableHeightPt: kPdfFirstPageAvailableHeightPt,
        otherPageAvailableHeightPt: kPdfUsableHeightPt,
      );
      final builder = PdfExportDocumentBuilder(font: font);
      // buildDocument / savePdf 含真实异步 IO（读公式图文件），在
      // testWidgets 的 FakeAsync 下直接 await 会挂起，须走 runAsync。
      final built = await tester.runAsync(
        () => CContentBuilder.buildDocument(
          plan: plan,
          tempDir: tempDir,
          questions: const [
            CBuildQuestion(
              questionIndex: 0,
              questionId: 'q0',
              title: '测试题',
            ),
          ],
          documentBuilder: builder,
          metadata: const PdfExportMetadata(title: 'B18 P1 基线测试'),
          headerInfo: const PdfExportHeaderInfo(
            subjectName: '测试',
            exportDateText: '2026-11-21',
          ),
          info: const PdfExportInfo(
            filterText: '全部',
            questionCount: 1,
            exportDateText: '2026-11-21',
            sortText: '默认排序',
            routeText: 'C 路线',
          ),
        ),
      );
      final pdfBytes = await tester.runAsync(
        () => builder.savePdf(built!.document),
      );
      final pdfFile = File('${tempDir.path}/baseline.pdf');
      final rendered = await tester.runAsync(() async {
        pdfFile.writeAsBytesSync(pdfBytes!);
        return PdfRenderService().renderPagePng(pdfFile.path, 1);
      });
      final decoded = img.decodeImage(rendered!.png);
      expect(decoded, isNotNull);
      return decoded!;
    }

    /// 在公式行带内量文字 x 与公式墨迹的底行（基线行）。
    ///
    /// 公式行是页内唯一的图文混排行：取 y 在 350–700 px 之间的墨迹
    /// （信息区与题号行在其上、页脚在其下，均不在此带内）；左 x 在
    /// 列 [126, 146]，公式墨迹在列 [150, 204]（19.2pt 宽的公式图从
    /// 约 150 起，上限 204 排除其后第二个文字 x，公式的底行墨迹在
    /// 左部 x 字上，不受上限影响）。返回（文字底行，公式底行）。
    (int, int) measureBaselines(img.Image page) {
      bool dark(int x, int y) {
        final p = page.getPixel(x, y);
        return p.r.toInt() < 100 && p.g.toInt() < 100 && p.b.toInt() < 100;
      }

      var textBottom = -1;
      var formulaBottom = -1;
      for (var y = 350; y < 700; y++) {
        for (var x = 126; x < 146; x++) {
          if (dark(x, y)) textBottom = y;
        }
        for (var x = 150; x < 204; x++) {
          if (dark(x, y)) formulaBottom = y;
        }
      }
      expect(textBottom, greaterThan(0), reason: '须量到文字 x 的底行');
      expect(formulaBottom, greaterThan(0), reason: '须量到公式墨迹的底行');
      return (textBottom, formulaBottom);
    }

    testWidgets('行内公式基线与文字基线对齐（≤2px，约 0.7pt）', (tester) async {
      await pumpAttached(tester);
      final tempDir = newTempDir('/pdf-aligned');
      final result = await render(
        tester,
        const FormulaRasterRequest(
          formulaId: 'q0-f0',
          latex: 'x^2',
          displayMode: false,
        ),
        tempDir,
      );
      final page = await renderSingleLinePdf(tester, result, tempDir);
      final (textBottom, formulaBottom) = measureBaselines(page);
      // 公式墨迹底行（x 的底 = 数学基线）须与文字 x 的底行重合。
      expect(
        (formulaBottom - textBottom).abs(),
        lessThanOrEqualTo(2),
        reason: '文字底行=$textBottom，公式底行=$formulaBottom',
      );
    });

    testWidgets('反证：基线未知时旧居中使公式浮起（高于文字基线）', (tester) async {
      await pumpAttached(tester);
      final tempDir = newTempDir('/pdf-legacy');
      final result = await render(
        tester,
        const FormulaRasterRequest(
          formulaId: 'q0-f0',
          latex: 'x^2',
          displayMode: false,
        ),
        tempDir,
      );
      final page = await renderSingleLinePdf(
        tester,
        result,
        tempDir,
        useBaseline: false,
      );
      final (textBottom, formulaBottom) = measureBaselines(page);
      // 旧居中把 8.1pt 高的公式放在 15.97pt 行高盒中央，公式底行比
      // 文字基线高约 (15.97 − 8.1) / 2 ≈ 3.9pt ≈ 12px。
      expect(
        formulaBottom,
        lessThan(textBottom - 8),
        reason: '文字底行=$textBottom，公式底行=$formulaBottom（应浮起）',
      );
    });
  });

  group('分页行高模型（D-216）', () {
    late CTextPaginator paginator;

    setUp(() {
      paginator = CTextPaginator(splitter: _FakeSplitter());
    });

    CQuestionPart planSingleLine(
      CParagraph paragraph,
    ) {
      final plan = paginator.paginate([
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: [CLayoutParagraph(paragraph)],
        ),
      ]);
      expect(plan.pages.length, 1);
      expect(plan.pages[0].parts.length, 1);
      return plan.pages[0].parts[0];
    }

    test('基线靠下的公式行：行高 = max（上升沿，基线）+ max（下降沿，下沉）', () {
      // 公式高 20、基线 19：行高 = 19 + 3.17 = 22.17；
      // 旧模型 max（15.97，20）= 20，低估 2.17。
      final part = planSingleLine(
        CParagraph(
          text: '测' * 10,
          inlineFormulas: const [
            CInlineFormula(
              offset: 5,
              widthPt: 44,
              heightPt: 20,
              formulaId: 'f0',
              ref: 'formulas/q0-f0.png',
              baselineOffsetPt: 19,
            ),
          ],
        ),
      );
      // 段高 = 题号行 18.87 + 行高 22.17。
      expect(part.heightPt, closeTo(18.87 + 22.17, 0.05));
    });

    test('基线未知（原图降级）的公式行：仍按旧居中折算，不低估', () {
      // 公式高 20、无基线：上段 (15.97+20)/2 = 17.99，下段 3.17，
      // 行高 21.16（旧 max 模型给 20，低估 1.16）。
      final part = planSingleLine(
        CParagraph(
          text: '测' * 10,
          inlineFormulas: const [
            CInlineFormula(
              offset: 5,
              widthPt: 44,
              heightPt: 20,
              formulaId: 'f0',
              ref: 'formulas/q0-f0.png',
            ),
          ],
        ),
      );
      expect(part.heightPt, closeTo(18.87 + 21.16, 0.05));
    });

    test('基线未知的矮公式行：行高 16.15，不是 15.97（B18-P1 补修核实）', () {
      // 公式高 10、无基线：构建器 WidgetSpan(baseline:) = (15.97−10)/2
      // = +2.98。pdf 3.13.1 里该参数是公式底边到文字基线的距离
      // （底边在基线上方 2.98pt，不是"公式顶在行顶下 2.98pt"）：
      // 公式顶边 = 2.98 + 10 = 12.98，高于文字上升沿 12.76，
      // 行高 = 12.98 + 3.17 = 16.15。探针实测 box.height = 16.1529，
      // 与本模型一致。不要把期望改回 15.97——那是旧 max（单行高，
      // 公式高）模型的数，与构建器实际布局脱节（见 B18-P1-FIX-REPORT）。
      final part = planSingleLine(
        CParagraph(
          text: '测' * 10,
          inlineFormulas: const [
            CInlineFormula(
              offset: 5,
              widthPt: 44,
              heightPt: 10,
              formulaId: 'f0',
              ref: 'formulas/q0-f0.png',
            ),
          ],
        ),
      );
      expect(part.heightPt, closeTo(18.87 + 16.15, 0.05));
    });

    test('纯文本行高不变（与旧模型完全一致）', () {
      final part = planSingleLine(CParagraph(text: '测' * 10));
      expect(part.heightPt, closeTo(18.87 + 15.97, 0.05));
    });
  });

  group('Word 下移量与注入', () {
    test('wordFormulaPositionHalfPoints：分式下移约 3.8pt → −8 半磅', () {
      expect(
        wordFormulaPositionHalfPoints(
          heightPt: 13.1,
          baselineOffsetPt: 9.3,
        ),
        -8,
      );
    });

    test('wordFormulaPositionHalfPoints：无下沉 / 基线未知 → null', () {
      // x^2：基线近底边，下移量 −0.04pt，四舍五入到 0，不注入。
      expect(
        wordFormulaPositionHalfPoints(
          heightPt: 8.1,
          baselineOffsetPt: 8.14,
        ),
        isNull,
      );
      expect(
        wordFormulaPositionHalfPoints(heightPt: 20, baselineOffsetPt: null),
        isNull,
      );
    });

    test('注入：混排段公式 run 得 w:position，独立图 run 不动', () async {
      final docBuilder = DocxDocumentBuilder();
      docBuilder.paragraph(
        DocxParagraph(
          children: [
            DocxText('x', fontSize: 11),
            DocxInlineImage(
              bytes: makePng(120, 60),
              extension: 'png',
              width: 30,
              height: 15,
            ),
            DocxText('x', fontSize: 11),
          ],
        ),
      );
      docBuilder.image(
        DocxImage(
          bytes: makePng(120, 60),
          extension: 'png',
          width: 30,
          height: 15,
        ),
      );
      final bytes = await DocxExporter().exportToBytes(docBuilder.build());
      final shifted = applyWordFormulaBaselineShifts(bytes, [-8, null]);
      final archive = ZipDecoder().decodeBytes(shifted);
      var xml = '';
      for (final f in archive.files) {
        if (f.name == 'word/document.xml') {
          xml = String.fromCharCodes(f.content as List<int>);
        }
      }
      expect(
        '<w:r><w:rPr><w:position w:val="-8"/></w:rPr><w:drawing>'
            .allMatches(xml)
            .length,
        1,
        reason: '恰一个行内公式 run 被注入',
      );
      expect(
        '<w:r><w:drawing>'.allMatches(xml).length,
        1,
        reason: '独立图 run 保持无 rPr 的原样',
      );
      expect(
        archive.files.where((f) => f.name.startsWith('word/media/')).length,
        2,
        reason: '图片部件数不变',
      );
    });

    test('注入后仍为合法 docx（交付校验通过）', () async {
      final docBuilder = DocxDocumentBuilder();
      docBuilder.paragraph(
        DocxParagraph(
          children: [
            DocxText('x', fontSize: 11),
            DocxInlineImage(
              bytes: makePng(120, 60),
              extension: 'png',
              width: 30,
              height: 15,
            ),
          ],
        ),
      );
      final bytes = await DocxExporter().exportToBytes(docBuilder.build());
      final shifted = applyWordFormulaBaselineShifts(bytes, [-8]);
      final file = File('${tempRoot.path}/shifted.docx')
        ..writeAsBytesSync(shifted);
      expect(await defaultDocxFileValidator(file, 1), isTrue);
      // 未注入的字节原样返回（不碰 zip）；空表对有 drawing 的文档会抛错
      // （见下一测试），不是原样返回。
      expect(applyWordFormulaBaselineShifts(bytes, [null]), bytes);
    });

    test('下移表与 drawing 数不一致时响亮抛错', () async {
      final docBuilder = DocxDocumentBuilder();
      docBuilder.paragraph(
        DocxParagraph(
          children: [
            DocxText('x', fontSize: 11),
            DocxInlineImage(
              bytes: makePng(120, 60),
              extension: 'png',
              width: 30,
              height: 15,
            ),
          ],
        ),
      );
      final bytes = await DocxExporter().exportToBytes(docBuilder.build());
      expect(
        () => applyWordFormulaBaselineShifts(bytes, [-8, -8]),
        throwsStateError,
      );
      expect(
        () => applyWordFormulaBaselineShifts(bytes, []),
        throwsStateError,
      );
      expect(
        () => applyWordFormulaBaselineShifts(
          Uint8List.fromList([1, 2, 3]),
          [-8],
        ),
        throwsStateError,
      );
    });

    test('构建器按文档顺序记录下移表（行内公式 −8，独立图 null）', () async {
      final source = FakeExportQuestionSource();
      source.records['q0'] = choiceRecord(
        id: 'q0',
        stem: '求值 \$x^2\$ 的结果',
      );
      source.slices['q0'] = makePng(200, 100);
      final snapshot = await ExportSnapshot.fromSelection(
        ids: ['q0'],
        excluded: const [],
        route: ExportRoute.c,
        filterText: '全部',
        sortText: '默认排序',
        source: source,
        tempRoot: tempRoot,
      );
      final entry = snapshot.entries.single;
      expect(entry.outcome, SnapshotOutcome.ready);
      // 公式 PNG 写到快照临时目录（裁决引用的相对路径）。
      final formulasDir = Directory('${snapshot.tempDir.path}/formulas')
        ..createSync(recursive: true);
      File('${formulasDir.path}/q0-f0.png')
          .writeAsBytesSync(makePng(120, 60));
      final verdict = QuestionFormulaVerdict(
        outcomes: [
          FormulaQuestionOutcome(
            formulaId: 'q0-f0',
            kind: FormulaQuestionOutcomeKind.rastered,
            result: const FormulaRasterResult(
              formulaId: 'q0-f0',
              relativePath: 'formulas/q0-f0.png',
              pixelWidth: 120,
              pixelHeight: 60,
              logicalWidthPt: 37.2,
              logicalHeightPt: 13.1,
              effectiveDpi: 300,
              shrunk: false,
              baselineOffsetPt: 9.3,
            ),
          ),
        ],
      );
      final content = buildWordContent(
        snapshot: snapshot,
        answersById: const {},
        versions: const ExportVersionSelection.practiceOnly(),
        formulaVerdicts: {'q0': verdict},
      );
      expect(content.imageCount, 1);
      // 仅一张行内公式图：下移表恰一项 −8。
      expect(content.drawingPositionHalfPoints, [-8]);
      final bytes = await DocxExporter().exportToBytes(
        content.document.build(),
      );
      final shifted = applyWordFormulaBaselineShifts(
        bytes,
        content.drawingPositionHalfPoints,
      );
      final archive = ZipDecoder().decodeBytes(shifted);
      var xml = '';
      for (final f in archive.files) {
        if (f.name == 'word/document.xml') {
          xml = String.fromCharCodes(f.content as List<int>);
        }
      }
      expect(xml.contains('w:position w:val="-8"'), isTrue);
    });
  });
}
