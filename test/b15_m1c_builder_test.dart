// 十五批 M1-C：C 路线内容构建器测试（M1-DESIGN.md §7/§10，V-分页）。
//
// 覆盖：
// - 结构：每段包 Inseparable(canSpan: false)；题号 / 来源行 / 续页标 /
//   「本题完」/ 分隔线位置；行内公式 RichText + WidgetSpan；图块尺寸；
//   结果汇总（段数、规划页号、PARTIAL、缩小标记）；错误分支。
// - 绘制页分配：paint 记录验每段实际落在哪页（探针同款手法），
//   普通题整题移页、超长题拆分、首题超大（第一页只留信息区）。
// - 边界：题高恰等于 / 略超 / 远超剩余空间（手建规划，图块定高）。
// - 页数：恰好 20 页 / 21 页（手建规划；Debug 下 maxPages=500 不抛错）。
// - 确定性：同一规划两次构建，绘制记录一致。
// - V-分页样例 PDF：写 ~/workspace/batch15-work/spikes/（本文件末尾组）。
//
// 本文件不含任何公式源码；公式只用生成的纯色 PNG 占位（尺寸按规划），
// 文本串均为普通中文 / 英文单词。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/widgets.dart' as pw;
import 'package:quiz_master2/services/pdf_export/c_content_builder.dart';
import 'package:quiz_master2/services/pdf_export/pdf_document_builder.dart';
import 'package:quiz_master2/services/pdf_export/pdf_font.dart';
import 'package:quiz_master2/services/pdf_export/snapshot_exceptions.dart';
import 'package:quiz_master2/services/pdf_export/text_pagination.dart';

/// paint 时记录“某部件实际绘制在哪一页”（探针同款手法）。
class _PageRecorder extends pw.StatelessWidget {
  _PageRecorder({
    required this.id,
    required this.onPaint,
    required this.child,
  });

  final String id;
  final void Function(String id, int page) onPaint;
  final pw.Widget child;

  @override
  pw.Widget build(pw.Context context) => child;

  @override
  void paint(pw.Context context) {
    onPaint(id, context.pageNumber);
    super.paint(context);
  }
}

/// 一份构建文档的绘制记录：子件下标 → 绘制页号（按绘制顺序）。
class _Harness {
  _Harness({required this.font, required this.children});

  final pw.Font font;
  final List<pw.Widget> children;
  final Map<String, List<int>> painted = {};
  var maxPage = 0;

  /// 建文档并保存；返回 PDF 字节（[painted] / [maxPage] 记录绘制结果）。
  Future<Uint8List> build({required int totalPages}) async {
    final builder = PdfExportDocumentBuilder(font: font);
    final doc = builder.createDocument(
      metadata: const PdfExportMetadata(title: 'M1-C 构建器测试'),
    );
    final recorded = <pw.Widget>[];
    for (var i = 0; i < children.length; i++) {
      recorded.add(
        _PageRecorder(
          id: 'w$i',
          onPaint: (id, p) {
            painted.putIfAbsent(id, () => []).add(p);
            if (p > maxPage) maxPage = p;
          },
          child: children[i],
        ),
      );
    }
    doc.addPage(
      builder.multiPage(
        children: recorded,
        plan: PdfPaginationPlan(totalPages: totalPages),
        headerInfo: const PdfExportHeaderInfo(
          subjectName: '测试',
          exportDateText: '2026-11-20',
        ),
      ),
    );
    return builder.savePdf(doc);
  }
}

Future<pw.Font> _loadFont() async {
  final bytes = await File(
    'assets/fonts/NotoSansSC-Regular.ttf',
  ).readAsBytes();
  return PdfExportFont.fontFromBytes(bytes);
}

/// 生成一张纯色 PNG 字节（宽高 px）。
Uint8List _pngBytes(int widthPx, int heightPx) {
  final image = img.Image(width: widthPx, height: heightPx);
  img.fill(image, color: img.ColorRgb8(120, 160, 200));
  return img.encodePng(image);
}

/// 在任务临时目录写一张 PNG（[ref] 为相对路径，如 formulas/q0-f0.png）。
Future<void> _writePng(
  Directory tempDir,
  String ref,
  int widthPx,
  int heightPx,
) async {
  final file = File(
    '${tempDir.path}${Platform.pathSeparator}'
    '${ref.replaceAll('/', Platform.pathSeparator)}',
  );
  await file.parent.create(recursive: true);
  await file.writeAsBytes(_pngBytes(widthPx, heightPx));
}

PdfExportDocumentBuilder _docBuilder(pw.Font font) =>
    PdfExportDocumentBuilder(font: font);

PdfExportInfo _info({int count = 2}) => PdfExportInfo(
      filterText: '数学',
      questionCount: count,
      exportDateText: '2026-11-20',
      sortText: '按加入时间',
      routeText: 'C 路线',
    );

PdfExportHeaderInfo _header() => const PdfExportHeaderInfo(
      subjectName: '数学',
      exportDateText: '2026-11-20',
    );

PdfExportMetadata _meta() =>
    const PdfExportMetadata(title: '错题本导出 · 数学');

List<CBuildQuestion> _questions(
  int count, {
  Map<int, String> sourceTexts = const {},
}) {
  return [
    for (var i = 0; i < count; i++)
      CBuildQuestion(
        questionIndex: i,
        questionId: 'q$i',
        title: '第 ${i + 1} 题',
        sourceText: sourceTexts[i] ?? '',
      ),
  ];
}

/// 通用 widget 树遍历（访问每个节点；进 RichText 的 WidgetSpan、
/// 单子件 / 多子件 / Container 的 child）。
void _walk(pw.Widget w, void Function(pw.Widget) visit) {
  visit(w);
  if (w is pw.RichText) {
    void walkSpan(pw.InlineSpan span) {
      if (span is pw.WidgetSpan) {
        _walk(span.child, visit);
      } else if (span is pw.TextSpan) {
        for (final c in span.children ?? const <pw.InlineSpan>[]) {
          walkSpan(c);
        }
      }
    }

    walkSpan(w.text);
  } else if (w is pw.Column) {
    for (final c in w.children) {
      _walk(c, visit);
    }
  } else if (w is pw.Inseparable) {
    final c = w.child;
    if (c != null) _walk(c, visit);
  } else if (w is pw.Container) {
    final c = w.child;
    if (c != null) _walk(c, visit);
  } else if (w is pw.SizedBox) {
    final c = w.child;
    if (c != null) _walk(c, visit);
  } else if (w is pw.SingleChildWidget) {
    final c = w.child;
    if (c != null) _walk(c, visit);
  } else if (w is pw.MultiChildWidget) {
    for (final c in w.children) {
      _walk(c, visit);
    }
  }
}

/// 收集 widget 子树里全部文本（含 RichText 的 TextSpan 文本）。
List<String> _texts(pw.Widget widget) {
  final out = <String>[];
  void collectSpan(pw.InlineSpan span) {
    if (span is pw.TextSpan) {
      if (span.text != null) out.add(span.text!);
      for (final c in span.children ?? const <pw.InlineSpan>[]) {
        collectSpan(c);
      }
    }
  }

  _walk(widget, (w) {
    if (w is pw.RichText) collectSpan(w.text);
  });
  return out;
}

/// 收集 widget 子树里全部图片的（宽，高）pt。
List<(double, double)> _images(pw.Widget widget) {
  final out = <(double, double)>[];
  _walk(widget, (w) {
    if (w is pw.Image) out.add((w.width ?? -1, w.height ?? -1));
  });
  return out;
}

/// 收集 widget 子树里分隔线（高 0.5 的 Container）的个数。
///
/// 分隔线 Container 的高度折进 constraints（tightFor：maxHeight 0.5）。
int _separators(pw.Widget widget) {
  var count = 0;
  _walk(widget, (w) {
    if (w is pw.Container && w.constraints?.maxHeight == 0.5) count++;
  });
  return count;
}

/// 收集 widget 子树里空白占位 SizedBox 的高度。
List<double> _spacers(pw.Widget widget) {
  final out = <double>[];
  _walk(widget, (w) {
    if (w is pw.SizedBox && w.height != null) out.add(w.height!);
  });
  return out;
}

/// 用真实断行器 + 分页器规划（与生产同路径）。
Future<CPagePlan> _realPlan(
  CTextPaginator paginator,
  List<CPaginableQuestion> questions,
) async {
  return paginator.paginate(questions);
}

/// 中文长题干（约 46 字 / 行，510.2 pt 宽）。
String _longStem(int chars) {
  const sentence = '已知函数满足下列条件：设实数满足不等式关系，且区间端点均为整数，'
      '试求满足条件的取值范围，并给出完整的推理过程。';
  final buf = StringBuffer();
  while (buf.length < chars) {
    buf.write(sentence);
  }
  return buf.toString().substring(0, chars);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late pw.Font font;
  late CTextPaginator paginator;
  late Directory tempDir;

  setUpAll(() async {
    font = await _loadFont();
    final splitter = TextPainterSplitter();
    await splitter.ensureFontLoaded();
    paginator = CTextPaginator(splitter: splitter);
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('b15_m1c_builder_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('结构：段 / 题号 / 来源行 / 分隔线', () {
    test('两道普通题：每段包 Inseparable，题号各一次，分隔线只在非末题', () async {
      final plan = await _realPlan(paginator, [
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          sourceText: '数学 · 高数 · 期中',
          blocks: [
            CLayoutParagraph(
              CParagraph(text: _longStem(200)),
            ),
          ],
        ),
        CPaginableQuestion(
          questionIndex: 1,
          displayNumber: 2,
          sourceText: '数学 · 线代 · 作业',
          blocks: [
            CLayoutParagraph(
              CParagraph(text: _longStem(100)),
            ),
          ],
        ),
      ]);
      final children = await CContentBuilder.buildChildren(
        plan: plan,
        tempDir: tempDir,
        questions: _questions(2, sourceTexts: {
          0: '数学 · 高数 · 期中',
          1: '数学 · 线代 · 作业',
        }),
        documentBuilder: _docBuilder(font),
        info: _info(count: 2),
      );
      // children[0] 信息区，children[1] 第 1 题，children[2] 第 2 题。
      expect(children.length, 3);
      for (var i = 1; i < children.length; i++) {
        final part = children[i];
        expect(part, isA<pw.Inseparable>());
        expect((part as pw.Inseparable).canSpan, isFalse);
      }
      final t1 = _texts(children[1]);
      expect(t1, contains('第 1 题'));
      expect(t1, contains('数学 · 高数 · 期中'));
      expect(t1.where((t) => t == '第 1 题').length, 1);
      final t2 = _texts(children[2]);
      expect(t2, contains('第 2 题'));
      expect(t2, contains('数学 · 线代 · 作业'));
      // 分隔线：第 1 题后有，第 2 题（末题）后无。
      expect(_separators(children[1]), 1);
      expect(_separators(children[2]), 0);
    });

    test('无来源行时不印来源行', () async {
      final plan = await _realPlan(paginator, [
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: [CLayoutParagraph(CParagraph(text: _longStem(100)))],
        ),
      ]);
      final children = await CContentBuilder.buildChildren(
        plan: plan,
        tempDir: tempDir,
        questions: _questions(1),
        documentBuilder: _docBuilder(font),
        info: _info(count: 1),
      );
      expect(_texts(children[1]), contains('第 1 题'));
      expect(_texts(children[1]).length, 2); // 题号行 + 正文，无来源行。
    });
  });

  group('结构：行内公式与图块', () {
    test('行内公式段落建成 RichText，WidgetSpan 尺寸与规划一致', () async {
      await _writePng(tempDir, 'formulas/q0-f0.png', 184, 67);
      await _writePng(tempDir, 'formulas/q0-f1.png', 120, 60);
      final plan = await _realPlan(paginator, [
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: [
            CLayoutParagraph(
              CParagraph(
                text: '设实数满足条件，则取值范围是下列哪一项，请说明理由。'
                    '若取边界值代入验证，可得结论成立。',
                inlineFormulas: const [
                  CInlineFormula(
                    offset: 10,
                    widthPt: 44,
                    heightPt: 16,
                    formulaId: 'f0',
                    ref: 'formulas/q0-f0.png',
                  ),
                  CInlineFormula(
                    offset: 30,
                    widthPt: 29,
                    heightPt: 14,
                    formulaId: 'f1',
                    ref: 'formulas/q0-f1.png',
                  ),
                ],
              ),
            ),
          ],
        ),
      ]);
      final children = await CContentBuilder.buildChildren(
        plan: plan,
        tempDir: tempDir,
        questions: _questions(1),
        documentBuilder: _docBuilder(font),
        info: _info(count: 1),
      );
      final part = children[1];
      final images = _images(part);
      // 两个行内公式图片，尺寸即规划值（与栅格化逻辑尺寸一致）。
      expect(images, contains((44.0, 16.0)));
      expect(images, contains((29.0, 14.0)));
      // 文本拼接后与原文一致（公式不占文本位置）。
      final joined = _texts(part).join();
      expect(
        joined,
        contains('设实数满足条件，则取值范围是下列哪一项，请说明理由。'),
      );
    });

    test('独立公式与图块按规划尺寸嵌入；原图题判 PARTIAL', () async {
      await _writePng(tempDir, 'formulas/q0-d0.png', 1500, 200);
      await _writePng(tempDir, 'figures/q1-f0.png', 1024, 768);
      final plan = await _realPlan(paginator, [
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: [
            CLayoutParagraph(CParagraph(text: _longStem(100))),
            const CLayoutAtomic(
              CAtomicBlock(
                kind: CAtomicKind.displayFormula,
                ref: 'formulas/q0-d0.png',
                widthPt: 360,
                heightPt: 48,
                isOriginal: true,
              ),
            ),
          ],
        ),
        CPaginableQuestion(
          questionIndex: 1,
          displayNumber: 2,
          blocks: [
            const CLayoutAtomic(
              CAtomicBlock(
                kind: CAtomicKind.figure,
                ref: 'figures/q1-f0.png',
                widthPt: 400,
                heightPt: 300,
                shrunk: true,
              ),
            ),
          ],
        ),
      ]);
      final result = await CContentBuilder.buildDocument(
        plan: plan,
        tempDir: tempDir,
        questions: _questions(2),
        documentBuilder: _docBuilder(font),
        metadata: _meta(),
        headerInfo: _header(),
        info: _info(count: 2),
      );
      expect(result.totalPages, plan.pages.length);
      expect(result.questions.length, 2);
      expect(
        result.questions[0].status,
        CBuildQuestionStatus.partial,
        reason: '含原图降级公式的题为 PARTIAL',
      );
      expect(result.questions[0].hasOriginalFormula, isTrue);
      expect(result.questions[1].status, CBuildQuestionStatus.printed);
      expect(result.questions[1].hasShrunkFormula, isTrue);
      // 结构：独立公式 360×48、图块 400×300。
      final children = await CContentBuilder.buildChildren(
        plan: plan,
        tempDir: tempDir,
        questions: _questions(2),
        documentBuilder: _docBuilder(font),
        info: _info(count: 2),
      );
      expect(_images(children[1]), contains((360.0, 48.0)));
      expect(_images(children[2]), contains((400.0, 300.0)));
    });
  });

  group('结构：拆分题标记与结果汇总', () {
    test('超长题：续页标只在续段，「本题完」只在末段，非末段有预留行空白', () async {
      final plan = await _realPlan(paginator, [
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: [CLayoutParagraph(CParagraph(text: _longStem(4600)))],
        ),
      ]);
      expect(plan.pages.length, greaterThanOrEqualTo(3));
      final children = await CContentBuilder.buildChildren(
        plan: plan,
        tempDir: tempDir,
        questions: _questions(1),
        documentBuilder: _docBuilder(font),
        info: _info(count: 1),
      );
      // children[0] 信息区，其余每段一段。
      final parts = children.sublist(1);
      expect(parts.length, plan.pages.length);
      // 首段：题号行，无续页标，无「本题完」，有预留行空白。
      expect(_texts(parts[0]), contains('第 1 题'));
      expect(
        _texts(parts[0]).any((t) => t.contains('接上页')),
        isFalse,
      );
      expect(_texts(parts[0]), isNot(contains('本题完')));
      expect(_spacers(parts[0]), contains(kPdfBodySingleLineHeightPt));
      // 续段：续页标，无题号行。
      for (var i = 1; i < parts.length; i++) {
        expect(_texts(parts[i]), contains('第 1 题（接上页）'));
        expect(_texts(parts[i]), isNot(contains('第 1 题')));
      }
      // 末段：「本题完」，无预留行空白。
      expect(_texts(parts.last), contains('本题完'));
      expect(_spacers(parts.last), isNot(contains(kPdfBodySingleLineHeightPt)));
      // 题号只出现一次（首段）。
      final allNumberLines = parts
          .expand(_texts)
          .where((t) => t == '第 1 题')
          .length;
      expect(allNumberLines, 1);
    });

    test('结果汇总：段数、规划页号、警告透传', () async {
      final plan = await _realPlan(paginator, [
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: [CLayoutParagraph(CParagraph(text: _longStem(4600)))],
        ),
        CPaginableQuestion(
          questionIndex: 1,
          displayNumber: 2,
          blocks: [CLayoutParagraph(CParagraph(text: _longStem(100)))],
        ),
      ]);
      final result = await CContentBuilder.buildDocument(
        plan: plan,
        tempDir: tempDir,
        questions: const [
          CBuildQuestion(
            questionIndex: 0,
            questionId: 'q0',
            title: '长题',
            warnings: ['公式为原图'],
          ),
          CBuildQuestion(
            questionIndex: 1,
            questionId: 'q1',
            title: '短题',
          ),
        ],
        documentBuilder: _docBuilder(font),
        metadata: _meta(),
        headerInfo: _header(),
        info: _info(count: 2),
      );
      expect(
        result.questions[0].segmentCount,
        plan.pages
            .expand((p) => p.parts)
            .where((part) => part.questionIndex == 0)
            .length,
      );
      expect(result.questions[0].plannedPages.first, 1);
      expect(result.questions[0].warnings, ['公式为原图']);
      expect(result.questions[1].segmentCount, 1);
      expect(result.questions[1].plannedPages.length, 1);
    });
  });

  group('错误分支', () {
    test('空规划抛 StateError', () async {
      const empty = CPagePlan(
        pages: [],
        firstPageAvailableHeightPt: kPdfFirstPageAvailableHeightPt,
        otherPageAvailableHeightPt: kPdfUsableHeightPt,
      );
      await expectLater(
        CContentBuilder.buildDocument(
          plan: empty,
          tempDir: tempDir,
          questions: const [],
          documentBuilder: _docBuilder(font),
          metadata: _meta(),
          headerInfo: _header(),
          info: _info(count: 0),
        ),
        throwsStateError,
      );
    });

    test('规划含题但无构建记录抛 ArgumentError', () async {
      final plan = await _realPlan(paginator, [
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: [CLayoutParagraph(CParagraph(text: _longStem(100)))],
        ),
      ]);
      await expectLater(
        CContentBuilder.buildDocument(
          plan: plan,
          tempDir: tempDir,
          questions: const [],
          documentBuilder: _docBuilder(font),
          metadata: _meta(),
          headerInfo: _header(),
          info: _info(count: 1),
        ),
        throwsArgumentError,
      );
    });

    test('图片引用缺失抛 SnapshotInfrastructureException', () async {
      final plan = await _realPlan(paginator, [
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: const [
            CLayoutAtomic(
              CAtomicBlock(
                kind: CAtomicKind.figure,
                ref: 'figures/missing.png',
                widthPt: 400,
                heightPt: 300,
              ),
            ),
          ],
        ),
      ]);
      await expectLater(
        CContentBuilder.buildDocument(
          plan: plan,
          tempDir: tempDir,
          questions: _questions(1),
          documentBuilder: _docBuilder(font),
          metadata: _meta(),
          headerInfo: _header(),
          info: _info(count: 1),
        ),
        throwsA(isA<SnapshotInfrastructureException>()),
      );
    });
  });

  group('绘制页分配：paint 记录 vs 规划', () {
    /// 断言绘制结果与规划一致：w0 为信息区（第 1 页），其余按规划顺序
    /// 每段一段，页号即规划页号；maxPage 即规划总页数。
    Future<void> expectPaintMatchesPlan(
      CPagePlan plan,
      List<pw.Widget> children,
    ) async {
      final harness = _Harness(font: font, children: children);
      await harness.build(totalPages: plan.pages.length);
      final expected = <String, int>{'w0': 1};
      var idx = 1;
      for (var pi = 0; pi < plan.pages.length; pi++) {
        for (final _ in plan.pages[pi].parts) {
          expected['w$idx'] = pi + 1;
          idx++;
        }
      }
      for (final e in expected.entries) {
        expect(
          harness.painted[e.key],
          [e.value],
          reason: '${e.key} 应绘制在第 ${e.value} 页，实际 ${harness.painted[e.key]}',
        );
      }
      expect(
        harness.maxPage,
        plan.pages.length,
        reason: '实际页数 ${harness.maxPage} ≠ 规划页数 ${plan.pages.length}',
      );
    }

    test('两道短题一页', () async {
      final plan = await _realPlan(paginator, [
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: [CLayoutParagraph(CParagraph(text: _longStem(200)))],
        ),
        CPaginableQuestion(
          questionIndex: 1,
          displayNumber: 2,
          blocks: [CLayoutParagraph(CParagraph(text: _longStem(100)))],
        ),
      ]);
      expect(plan.pages.length, 1);
      final children = await CContentBuilder.buildChildren(
        plan: plan,
        tempDir: tempDir,
        questions: _questions(2),
        documentBuilder: _docBuilder(font),
        info: _info(count: 2),
      );
      await expectPaintMatchesPlan(plan, children);
    });

    test('普通题整题移页：第二题整体到第 2 页，不拆分', () async {
      final plan = await _realPlan(paginator, [
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: [CLayoutParagraph(CParagraph(text: _longStem(1200)))],
        ),
        CPaginableQuestion(
          questionIndex: 1,
          displayNumber: 2,
          blocks: [CLayoutParagraph(CParagraph(text: _longStem(100)))],
        ),
      ]);
      expect(plan.pages.length, 2);
      expect(plan.pages[0].parts.length, 1);
      expect(plan.pages[1].parts.length, 1);
      final children = await CContentBuilder.buildChildren(
        plan: plan,
        tempDir: tempDir,
        questions: _questions(2),
        documentBuilder: _docBuilder(font),
        info: _info(count: 2),
      );
      await expectPaintMatchesPlan(plan, children);
    });

    test('超长题三段落在第 1/2/3 页', () async {
      final plan = await _realPlan(paginator, [
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: [CLayoutParagraph(CParagraph(text: _longStem(3800)))],
        ),
      ]);
      expect(plan.pages.length, 3);
      final children = await CContentBuilder.buildChildren(
        plan: plan,
        tempDir: tempDir,
        questions: _questions(1),
        documentBuilder: _docBuilder(font),
        info: _info(count: 1),
      );
      await expectPaintMatchesPlan(plan, children);
    });

    test('首题超大：第一页只留信息区，题到第 2 页', () async {
      await _writePng(tempDir, 'figures/q0-big.png', 1200, 1200);
      final plan = await _realPlan(paginator, [
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: const [
            CLayoutAtomic(
              CAtomicBlock(
                kind: CAtomicKind.figure,
                ref: 'figures/q0-big.png',
                widthPt: 510.2,
                heightPt: 650,
              ),
            ),
          ],
        ),
        CPaginableQuestion(
          questionIndex: 1,
          displayNumber: 2,
          blocks: [CLayoutParagraph(CParagraph(text: '短题。'))],
        ),
      ]);
      expect(plan.pages.length, 2);
      expect(plan.pages[0].parts, isEmpty);
      expect(plan.pages[1].parts.length, 2);
      final children = await CContentBuilder.buildChildren(
        plan: plan,
        tempDir: tempDir,
        questions: _questions(2),
        documentBuilder: _docBuilder(font),
        info: _info(count: 2),
      );
      await expectPaintMatchesPlan(plan, children);
    });

    test('行内公式 + 图块混合题落在正确页', () async {
      await _writePng(tempDir, 'formulas/q0-f0.png', 184, 67);
      await _writePng(tempDir, 'figures/q1-f0.png', 1024, 768);
      final plan = await _realPlan(paginator, [
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: [
            CLayoutParagraph(
              CParagraph(
                text: '设实数满足条件，则取值范围是下列哪一项，请说明理由。'
                    '若取边界值代入验证，可得结论成立。',
                inlineFormulas: const [
                  CInlineFormula(
                    offset: 10,
                    widthPt: 44,
                    heightPt: 16,
                    formulaId: 'f0',
                    ref: 'formulas/q0-f0.png',
                  ),
                ],
              ),
            ),
            CLayoutParagraph(CParagraph(text: _longStem(1200))),
          ],
        ),
        CPaginableQuestion(
          questionIndex: 1,
          displayNumber: 2,
          blocks: const [
            CLayoutAtomic(
              CAtomicBlock(
                kind: CAtomicKind.figure,
                ref: 'figures/q1-f0.png',
                widthPt: 400,
                heightPt: 300,
              ),
            ),
          ],
        ),
      ]);
      expect(plan.pages.length, 2);
      final children = await CContentBuilder.buildChildren(
        plan: plan,
        tempDir: tempDir,
        questions: _questions(2),
        documentBuilder: _docBuilder(font),
        info: _info(count: 2),
      );
      await expectPaintMatchesPlan(plan, children);
    });

    test('确定性：同一规划两次构建，绘制记录一致', () async {
      final plan = await _realPlan(paginator, [
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: [CLayoutParagraph(CParagraph(text: _longStem(3800)))],
        ),
        CPaginableQuestion(
          questionIndex: 1,
          displayNumber: 2,
          blocks: [CLayoutParagraph(CParagraph(text: _longStem(300)))],
        ),
      ]);
      final qs = _questions(2);
      final info = _info(count: 2);
      final c1 = await CContentBuilder.buildChildren(
        plan: plan,
        tempDir: tempDir,
        questions: qs,
        documentBuilder: _docBuilder(font),
        info: info,
      );
      final c2 = await CContentBuilder.buildChildren(
        plan: plan,
        tempDir: tempDir,
        questions: qs,
        documentBuilder: _docBuilder(font),
        info: info,
      );
      final h1 = _Harness(font: font, children: c1);
      final h2 = _Harness(font: font, children: c2);
      await h1.build(totalPages: plan.pages.length);
      await h2.build(totalPages: plan.pages.length);
      expect(h1.painted, h2.painted);
      expect(h1.maxPage, h2.maxPage);
    });
  });

  group('边界：题高 vs 剩余空间（手建规划，图块定高）', () {
    CPagePlan handPlan(List<List<CQuestionPart>> pages) => CPagePlan(
          pages: [for (final parts in pages) CPlannedPage(parts: parts)],
          firstPageAvailableHeightPt: kPdfFirstPageAvailableHeightPt,
          otherPageAvailableHeightPt: kPdfUsableHeightPt,
        );

    /// 单图块题段（题号行 + 图块 + 分隔线；末题无分隔线）。
    CQuestionPart figurePart({
      required int qi,
      required double figureHeightPt,
      required bool isLast,
    }) {
      final height = kPdfQuestionNumberHeightPt +
          figureHeightPt +
          (isLast ? 0 : kPdfSeparatorHeightPt);
      return CQuestionPart(
        questionIndex: qi,
        displayNumber: qi + 1,
        continuation: false,
        last: true,
        blocks: [
          CPartImage(
            kind: CAtomicKind.figure,
            ref: 'figures/big.png',
            widthPt: 510.2,
            heightPt: figureHeightPt,
          ),
        ],
        heightPt: height,
      );
    }

    /// 单行文本题段（题号行 + 1 行正文；末题无分隔线）。
    CQuestionPart oneLinePart({required int qi, required bool isLast}) {
      final height = kPdfQuestionNumberHeightPt +
          kPdfBodySingleLineHeightPt +
          (isLast ? 0 : kPdfSeparatorHeightPt);
      return CQuestionPart(
        questionIndex: qi,
        displayNumber: qi + 1,
        continuation: false,
        last: true,
        blocks: const [
          CPartRichText(
            text: '短题。',
            inlineFormulas: [],
            fontSizePt: 11,
            lines: 1,
          ),
        ],
        heightPt: height,
      );
    }

    Future<void> expectPaint(
      CPagePlan plan,
      List<pw.Widget> children,
      Map<String, int> expected,
    ) async {
      final harness = _Harness(font: font, children: children);
      await harness.build(totalPages: plan.pages.length);
      for (final e in expected.entries) {
        expect(
          harness.painted[e.key],
          [e.value],
          reason: '${e.key} 应在第 ${e.value} 页，实际 ${harness.painted[e.key]}',
        );
      }
    }

    test('题高恰等于剩余空间：留在本页', () async {
      await _writePng(tempDir, 'figures/big.png', 1200, 1200);
      // 第 1 题模型高 = 18.87 + 627.9 + 8.5 = 655.27 = 第一页可用高。
      final plan = handPlan([
        [figurePart(qi: 0, figureHeightPt: 627.9, isLast: false)],
        [oneLinePart(qi: 1, isLast: true)],
      ]);
      final children = await CContentBuilder.buildChildren(
        plan: plan,
        tempDir: tempDir,
        questions: _questions(2),
        documentBuilder: _docBuilder(font),
        info: _info(count: 2),
      );
      await expectPaint(plan, children, {'w0': 1, 'w1': 1, 'w2': 2});
    });

    test('题高略超剩余空间（+2 pt）：整题移下一页', () async {
      await _writePng(tempDir, 'figures/big.png', 1200, 1200);
      final plan = handPlan([
        [],
        [
          figurePart(qi: 0, figureHeightPt: 629.9, isLast: false),
          oneLinePart(qi: 1, isLast: true),
        ],
      ]);
      final children = await CContentBuilder.buildChildren(
        plan: plan,
        tempDir: tempDir,
        questions: _questions(2),
        documentBuilder: _docBuilder(font),
        info: _info(count: 2),
      );
      await expectPaint(plan, children, {'w0': 1, 'w1': 2, 'w2': 2});
    });

    test('题高远超剩余空间：整题移下一页', () async {
      await _writePng(tempDir, 'figures/big.png', 1200, 1200);
      final plan = handPlan([
        [figurePart(qi: 0, figureHeightPt: 600, isLast: false)],
        [figurePart(qi: 1, figureHeightPt: 500, isLast: true)],
      ]);
      final children = await CContentBuilder.buildChildren(
        plan: plan,
        tempDir: tempDir,
        questions: _questions(2),
        documentBuilder: _docBuilder(font),
        info: _info(count: 2),
      );
      await expectPaint(plan, children, {'w0': 1, 'w1': 1, 'w2': 2});
    });
  });

  group('页数边界：恰好 20 页 / 21 页', () {
    /// 每页一段图块的手建规划：第 1 页图块 600 pt，其余页 700 pt。
    CPagePlan manyPagePlan(int totalPages) {
      final pages = <CPlannedPage>[];
      for (var i = 0; i < totalPages; i++) {
        final h = i == 0 ? 600.0 : 700.0;
        pages.add(
          CPlannedPage(
            parts: [
              CQuestionPart(
                questionIndex: i,
                displayNumber: i + 1,
                continuation: false,
                last: true,
                blocks: [
                  CPartImage(
                    kind: CAtomicKind.figure,
                    ref: 'figures/big.png',
                    widthPt: 510.2,
                    heightPt: h,
                  ),
                ],
                heightPt: kPdfQuestionNumberHeightPt +
                    h +
                    (i == totalPages - 1 ? 0 : kPdfSeparatorHeightPt),
              ),
            ],
          ),
        );
      }
      return CPagePlan(
        pages: pages,
        firstPageAvailableHeightPt: kPdfFirstPageAvailableHeightPt,
        otherPageAvailableHeightPt: kPdfUsableHeightPt,
      );
    }

    Future<void> checkPages(int totalPages) async {
      await _writePng(tempDir, 'figures/big.png', 1200, 1200);
      final plan = manyPagePlan(totalPages);
      final qs = _questions(totalPages);
      // 完整 buildDocument 路径在 Debug 下不抛错（maxPages=500）。
      final result = await CContentBuilder.buildDocument(
        plan: plan,
        tempDir: tempDir,
        questions: qs,
        documentBuilder: _docBuilder(font),
        metadata: _meta(),
        headerInfo: _header(),
        info: _info(count: totalPages),
      );
      final bytes = await _docBuilder(font).savePdf(result.document);
      expect(bytes.length, greaterThan(0));
      expect(result.totalPages, totalPages);
      // 绘制页分配与规划一致。
      final children = await CContentBuilder.buildChildren(
        plan: plan,
        tempDir: tempDir,
        questions: qs,
        documentBuilder: _docBuilder(font),
        info: _info(count: totalPages),
      );
      final harness = _Harness(font: font, children: children);
      await harness.build(totalPages: totalPages);
      expect(harness.maxPage, totalPages);
      for (var i = 0; i < totalPages; i++) {
        expect(
          harness.painted['w${i + 1}'],
          [i + 1],
          reason: '第 ${i + 1} 题应在第 ${i + 1} 页',
        );
      }
    }

    test('恰好 20 页', () async {
      await checkPages(20);
    });

    test('恰好 21 页（超 20 页）', () async {
      await checkPages(21);
    });
  });

  group('V-分页样例 PDF（留档 spikes/）', () {
    late Directory spikesDir;

    setUpAll(() async {
      spikesDir = Directory(
        '${Platform.environment['HOME']}/workspace/batch15-work/spikes',
      );
      await spikesDir.create(recursive: true);
    });

    Future<void> saveSample({
      required String fileName,
      required CPagePlan plan,
      required List<CBuildQuestion> questions,
      required int expectedPages,
    }) async {
      expect(
        plan.pages.length,
        expectedPages,
        reason: '$fileName 规划页数不符预期（文本长度校准见注释）',
      );
      // 绘制与规划一致。
      final children = await CContentBuilder.buildChildren(
        plan: plan,
        tempDir: tempDir,
        questions: questions,
        documentBuilder: _docBuilder(font),
        info: _info(count: questions.length),
      );
      final harness = _Harness(font: font, children: children);
      await harness.build(totalPages: plan.pages.length);
      expect(
        harness.maxPage,
        expectedPages,
        reason: '$fileName 实际页数 ${harness.maxPage} ≠ 规划 $expectedPages',
      );
      var idx = 1;
      for (var pi = 0; pi < plan.pages.length; pi++) {
        for (final _ in plan.pages[pi].parts) {
          expect(
            harness.painted['w$idx'],
            [pi + 1],
            reason: '$fileName 第 $idx 段应在第 ${pi + 1} 页',
          );
          idx++;
        }
      }
      // 落盘用完整 buildDocument 路径。
      final result = await CContentBuilder.buildDocument(
        plan: plan,
        tempDir: tempDir,
        questions: questions,
        documentBuilder: _docBuilder(font),
        metadata: _meta(),
        headerInfo: _header(),
        info: _info(count: questions.length),
      );
      final bytes = await _docBuilder(font).savePdf(result.document);
      final file = File('${spikesDir.path}/$fileName');
      await file.writeAsBytes(bytes);
      expect(await file.exists(), isTrue);
      expect(bytes.length, greaterThan(0));
    }

    test('超长文本题 1.2× 内容区', () async {
      final plan = await _realPlan(paginator, [
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: [CLayoutParagraph(CParagraph(text: _longStem(1800)))],
        ),
      ]);
      await saveSample(
        fileName: 'M1C-V-fenye-overlong-1.2x.pdf',
        plan: plan,
        questions: _questions(1),
        expectedPages: 2,
      );
    });

    test('超长文本题 2× 内容区', () async {
      final plan = await _realPlan(paginator, [
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: [CLayoutParagraph(CParagraph(text: _longStem(3000)))],
        ),
      ]);
      await saveSample(
        fileName: 'M1C-V-fenye-overlong-2x.pdf',
        plan: plan,
        questions: _questions(1),
        expectedPages: 3,
      );
    });

    test('超长文本题 3× 内容区', () async {
      final plan = await _realPlan(paginator, [
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: [CLayoutParagraph(CParagraph(text: _longStem(4600)))],
        ),
      ]);
      await saveSample(
        fileName: 'M1C-V-fenye-overlong-3x.pdf',
        plan: plan,
        questions: _questions(1),
        expectedPages: 4,
      );
    });

    test('题高恰等于剩余空间（样例）', () async {
      await _writePng(tempDir, 'figures/big.png', 1200, 1200);
      final plan = CPagePlan(
        pages: [
          CPlannedPage(
            parts: [
              CQuestionPart(
                questionIndex: 0,
                displayNumber: 1,
                continuation: false,
                last: true,
                blocks: const [
                  CPartImage(
                    kind: CAtomicKind.figure,
                    ref: 'figures/big.png',
                    widthPt: 510.2,
                    heightPt: 627.9,
                  ),
                ],
                heightPt: kPdfQuestionNumberHeightPt +
                    627.9 +
                    kPdfSeparatorHeightPt,
              ),
            ],
          ),
          CPlannedPage(
            parts: [
              CQuestionPart(
                questionIndex: 1,
                displayNumber: 2,
                continuation: false,
                last: true,
                blocks: const [
                  CPartRichText(
                    text: '短题。',
                    inlineFormulas: [],
                    fontSizePt: 11,
                    lines: 1,
                  ),
                ],
                heightPt: kPdfQuestionNumberHeightPt +
                    kPdfBodySingleLineHeightPt,
              ),
            ],
          ),
        ],
        firstPageAvailableHeightPt: kPdfFirstPageAvailableHeightPt,
        otherPageAvailableHeightPt: kPdfUsableHeightPt,
      );
      await saveSample(
        fileName: 'M1C-V-fenye-boundary-equal.pdf',
        plan: plan,
        questions: _questions(2),
        expectedPages: 2,
      );
    });

    test('题高略超剩余空间（样例）', () async {
      await _writePng(tempDir, 'figures/big.png', 1200, 1200);
      final plan = CPagePlan(
        pages: [
          const CPlannedPage(parts: []),
          CPlannedPage(
            parts: [
              CQuestionPart(
                questionIndex: 0,
                displayNumber: 1,
                continuation: false,
                last: true,
                blocks: const [
                  CPartImage(
                    kind: CAtomicKind.figure,
                    ref: 'figures/big.png',
                    widthPt: 510.2,
                    heightPt: 629.9,
                  ),
                ],
                heightPt: kPdfQuestionNumberHeightPt +
                    629.9 +
                    kPdfSeparatorHeightPt,
              ),
              CQuestionPart(
                questionIndex: 1,
                displayNumber: 2,
                continuation: false,
                last: true,
                blocks: const [
                  CPartRichText(
                    text: '短题。',
                    inlineFormulas: [],
                    fontSizePt: 11,
                    lines: 1,
                  ),
                ],
                heightPt: kPdfQuestionNumberHeightPt +
                    kPdfBodySingleLineHeightPt,
              ),
            ],
          ),
        ],
        firstPageAvailableHeightPt: kPdfFirstPageAvailableHeightPt,
        otherPageAvailableHeightPt: kPdfUsableHeightPt,
      );
      await saveSample(
        fileName: 'M1C-V-fenye-boundary-slightly-over.pdf',
        plan: plan,
        questions: _questions(2),
        expectedPages: 2,
      );
    });

    test('题高远超剩余空间（样例）', () async {
      await _writePng(tempDir, 'figures/big.png', 1200, 1200);
      final plan = CPagePlan(
        pages: [
          CPlannedPage(
            parts: [
              CQuestionPart(
                questionIndex: 0,
                displayNumber: 1,
                continuation: false,
                last: true,
                blocks: const [
                  CPartImage(
                    kind: CAtomicKind.figure,
                    ref: 'figures/big.png',
                    widthPt: 510.2,
                    heightPt: 600,
                  ),
                ],
                heightPt: kPdfQuestionNumberHeightPt +
                    600 +
                    kPdfSeparatorHeightPt,
              ),
            ],
          ),
          CPlannedPage(
            parts: [
              CQuestionPart(
                questionIndex: 1,
                displayNumber: 2,
                continuation: false,
                last: true,
                blocks: const [
                  CPartImage(
                    kind: CAtomicKind.figure,
                    ref: 'figures/big.png',
                    widthPt: 510.2,
                    heightPt: 500,
                  ),
                ],
                heightPt:
                    kPdfQuestionNumberHeightPt + 500,
              ),
            ],
          ),
        ],
        firstPageAvailableHeightPt: kPdfFirstPageAvailableHeightPt,
        otherPageAvailableHeightPt: kPdfUsableHeightPt,
      );
      await saveSample(
        fileName: 'M1C-V-fenye-boundary-far-over.pdf',
        plan: plan,
        questions: _questions(2),
        expectedPages: 2,
      );
    });

    test('行内不断词、中文断行抽查（样例）', () async {
      await _writePng(tempDir, 'formulas/q2-f0.png', 184, 67);
      await _writePng(tempDir, 'figures/q2-f0.png', 1024, 768);
      const cjk = '已知集合，元素，子集，并集，交集，补集，空集，全集，幂集，'
          '笛卡尔积，映射，函数，定义域，值域，单调性，奇偶性，周期性，'
          '有界性，连续性，可导性，可积性，收敛性，发散性。';
      const mixed = '阅读下面这段文字：The function is defined on the interval，'
          '并且满足以下条件：当自变量趋近于零时，函数值趋近于一；请判断'
          '下列命题的真假，并说明理由。photosynthesis electromagnetic';
      final plan = await _realPlan(paginator, [
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: [CLayoutParagraph(CParagraph(text: cjk * 6))],
        ),
        CPaginableQuestion(
          questionIndex: 1,
          displayNumber: 2,
          blocks: [CLayoutParagraph(CParagraph(text: mixed * 4))],
        ),
        CPaginableQuestion(
          questionIndex: 2,
          displayNumber: 3,
          blocks: [
            CLayoutParagraph(
              CParagraph(
                text: '设实数满足条件，则取值范围是下列哪一项，请说明理由。'
                    '若取边界值代入验证，可得结论成立。',
                inlineFormulas: const [
                  CInlineFormula(
                    offset: 10,
                    widthPt: 44,
                    heightPt: 16,
                    formulaId: 'f0',
                    ref: 'formulas/q2-f0.png',
                  ),
                ],
              ),
            ),
            const CLayoutAtomic(
              CAtomicBlock(
                kind: CAtomicKind.figure,
                ref: 'figures/q2-f0.png',
                widthPt: 400,
                heightPt: 300,
              ),
            ),
          ],
        ),
      ]);
      await saveSample(
        fileName: 'M1C-V-fenye-cjk-breaks.pdf',
        plan: plan,
        questions: _questions(3),
        expectedPages: plan.pages.length,
      );
    });
  });
}
