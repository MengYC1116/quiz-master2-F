// 十六批 D-188：_FixedSizeBox 漏 paint 导致 C 路线图片全丢的回归测试
// （PDF-DEFECT-ROOT-CAUSE.md §1）。
//
// 缺陷：_FixedSizeBox 只重写 layout()、没重写 paint()，子件 pw.Image
// 的 paint 从未执行 → save() 后 PDF 里 0 张图片，全程无异常。
// 修法：补 paint 重写（super.paint(context); paintChild(context);，
// 照抄 ConstrainedBox.paint）+ _collectResults 汇总行内公式的原图 /
// 缩小标记（否则只有行内公式降级的题误判 COMPLETE 而非 PARTIAL）。
//
// 本文件只断言 save() 后的 PDF 字节与构建结果，不只断言 widget 树
// （既有 b15_m1c_builder_test 只断言树里有 WidgetSpan，正是漏网原因）。
// 图片用生成的纯色 PNG 占位（尺寸按规划），文本串均为普通中文。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/widgets.dart' as pw;
import 'package:quiz_master2/services/pdf_export/c_content_builder.dart';
import 'package:quiz_master2/services/pdf_export/pdf_document_builder.dart';
import 'package:quiz_master2/services/pdf_export/pdf_font.dart';
import 'package:quiz_master2/services/pdf_export/text_pagination.dart';

Future<pw.Font> _loadFont() async {
  final bytes = await File(
    'assets/fonts/NotoSansSC-Regular.ttf',
  ).readAsBytes();
  return PdfExportFont.fontFromBytes(bytes);
}

/// 生成一张纯色 PNG 字节（宽高 px，颜色区分三类图，避免 pdf 包去重）。
Uint8List _pngBytes(int widthPx, int heightPx, img.Color color) {
  final image = img.Image(width: widthPx, height: heightPx);
  img.fill(image, color: color);
  return img.encodePng(image);
}

/// 在任务临时目录写一张 PNG（[ref] 为相对路径，如 formulas/q0-f0.png）。
Future<void> _writePng(
  Directory tempDir,
  String ref,
  int widthPx,
  int heightPx,
  img.Color color,
) async {
  final file = File(
    '${tempDir.path}${Platform.pathSeparator}'
    '${ref.replaceAll('/', Platform.pathSeparator)}',
  );
  await file.parent.create(recursive: true);
  await file.writeAsBytes(_pngBytes(widthPx, heightPx, color));
}

PdfExportDocumentBuilder _docBuilder(pw.Font font) =>
    PdfExportDocumentBuilder(font: font);

PdfExportInfo _info({int count = 1}) => PdfExportInfo(
      filterText: '数学',
      questionCount: count,
      exportDateText: '2026-11-21',
      sortText: '按加入时间',
      routeText: 'C 路线',
    );

PdfExportHeaderInfo _header() => const PdfExportHeaderInfo(
      subjectName: '数学',
      exportDateText: '2026-11-21',
    );

PdfExportMetadata _meta() =>
    const PdfExportMetadata(title: '错题本导出 · 数学');

List<CBuildQuestion> _questions(int count) => [
      for (var i = 0; i < count; i++)
        CBuildQuestion(
          questionIndex: i,
          questionId: 'q$i',
          title: '第 ${i + 1} 题',
        ),
    ];

/// PDF 字节里 `/Subtype/Image` 的出现次数（每张嵌入图片一个 XObject）。
///
/// 注意：pdf 包写字典时名字值前不加空格，实际字节是 `/Subtype/Image`
/// （不是 `/Subtype /Image`）；内容流是 Flate 压缩的，故不数 `Do`。
int _imageXObjectCount(Uint8List pdfBytes) {
  final text = String.fromCharCodes(pdfBytes);
  return '/Subtype/Image'.allMatches(text).length;
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
    tempDir = await Directory.systemTemp.createTemp('b16-d188-');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('D-188 缺陷 1：save() 后三类图片都在 PDF 里', () {
    test('行内公式 + 独立公式 + 配图：/Subtype /Image 各至少一个', () async {
      await _writePng(
        tempDir,
        'formulas/q0-f0.png',
        184,
        67,
        img.ColorRgb8(200, 60, 60),
      );
      await _writePng(
        tempDir,
        'formulas/q0-d0.png',
        1500,
        200,
        img.ColorRgb8(60, 200, 60),
      );
      await _writePng(
        tempDir,
        'figures/q0-f0.png',
        1024,
        768,
        img.ColorRgb8(60, 60, 200),
      );
      final plan = paginator.paginate([
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: [
            CLayoutParagraph(
              CParagraph(
                text: '设实数满足条件，则取值范围是下列哪一项，请说明理由。',
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
            const CLayoutAtomic(
              CAtomicBlock(
                kind: CAtomicKind.displayFormula,
                ref: 'formulas/q0-d0.png',
                widthPt: 360,
                heightPt: 48,
              ),
            ),
            const CLayoutAtomic(
              CAtomicBlock(
                kind: CAtomicKind.figure,
                ref: 'figures/q0-f0.png',
                widthPt: 400,
                heightPt: 300,
              ),
            ),
          ],
        ),
      ]);
      final result = await CContentBuilder.buildDocument(
        plan: plan,
        tempDir: tempDir,
        questions: _questions(1),
        documentBuilder: _docBuilder(font),
        metadata: _meta(),
        headerInfo: _header(),
        info: _info(count: 1),
      );
      final bytes = await _docBuilder(font).savePdf(result.document);
      expect(bytes.length, greaterThan(0));
      // 三张不同的图 → 每张一个图片 XObject + 一个 SMask XObject
      //（pdf 包给解码图另建 alpha 掩码，也是 /Subtype/Image），共 6 个；
      // D-188 修前为 0。另按各自宽度断言三张图无一被去重/丢弃。
      expect(
        _imageXObjectCount(bytes),
        6,
        reason: '行内公式、独立公式、配图各一张（各含 SMask），共 6 个 /Subtype/Image',
      );
      final text = String.fromCharCodes(bytes);
      expect(text, contains('/Width 184')); // 行内公式 PNG 宽。
      expect(text, contains('/Width 1500')); // 独立公式 PNG 宽。
      expect(text, contains('/Width 1024')); // 配图 PNG 宽。
    });
  });

  group('D-188 顺带：_collectResults 汇总行内公式降级标记', () {
    test('只有行内公式为原图 → PARTIAL（修前误判 COMPLETE）', () async {
      await _writePng(
        tempDir,
        'formulas/q0-f0.png',
        184,
        67,
        img.ColorRgb8(200, 60, 60),
      );
      final plan = paginator.paginate([
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: [
            CLayoutParagraph(
              CParagraph(
                text: '设实数满足条件，则取值范围是下列哪一项，请说明理由。',
                inlineFormulas: const [
                  CInlineFormula(
                    offset: 10,
                    widthPt: 44,
                    heightPt: 16,
                    formulaId: 'f0',
                    ref: 'formulas/q0-f0.png',
                    isOriginal: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ]);
      final result = await CContentBuilder.buildDocument(
        plan: plan,
        tempDir: tempDir,
        questions: _questions(1),
        documentBuilder: _docBuilder(font),
        metadata: _meta(),
        headerInfo: _header(),
        info: _info(count: 1),
      );
      expect(result.questions.length, 1);
      expect(
        result.questions[0].status,
        CBuildQuestionStatus.partial,
        reason: '行内公式为原图降级，该题应为 PARTIAL',
      );
      expect(result.questions[0].hasOriginalFormula, isTrue);
    });

    test('行内公式被缩小 → hasShrunkFormula 为真，状态仍为 printed', () async {
      await _writePng(
        tempDir,
        'formulas/q0-f0.png',
        184,
        67,
        img.ColorRgb8(200, 60, 60),
      );
      final plan = paginator.paginate([
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: [
            CLayoutParagraph(
              CParagraph(
                text: '设实数满足条件，则取值范围是下列哪一项，请说明理由。',
                inlineFormulas: const [
                  CInlineFormula(
                    offset: 10,
                    widthPt: 44,
                    heightPt: 16,
                    formulaId: 'f0',
                    ref: 'formulas/q0-f0.png',
                    shrunk: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ]);
      final result = await CContentBuilder.buildDocument(
        plan: plan,
        tempDir: tempDir,
        questions: _questions(1),
        documentBuilder: _docBuilder(font),
        metadata: _meta(),
        headerInfo: _header(),
        info: _info(count: 1),
      );
      expect(result.questions[0].hasShrunkFormula, isTrue);
      expect(result.questions[0].status, CBuildQuestionStatus.printed);
    });

    test('超长题拆分后：行内公式原图标记不丢（分页重建透传）', () async {
      await _writePng(
        tempDir,
        'formulas/q0-f0.png',
        184,
        67,
        img.ColorRgb8(200, 60, 60),
      );
      final plan = paginator.paginate([
        CPaginableQuestion(
          questionIndex: 0,
          displayNumber: 1,
          blocks: [
            CLayoutParagraph(
              CParagraph(
                text: _longStem(2000),
                inlineFormulas: const [
                  CInlineFormula(
                    offset: 10,
                    widthPt: 44,
                    heightPt: 16,
                    formulaId: 'f0',
                    ref: 'formulas/q0-f0.png',
                    isOriginal: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ]);
      // 超长题确被拆成多段（走 _splitLongQuestion / groupForLines）。
      expect(plan.pages.length, greaterThan(1));
      final result = await CContentBuilder.buildDocument(
        plan: plan,
        tempDir: tempDir,
        questions: _questions(1),
        documentBuilder: _docBuilder(font),
        metadata: _meta(),
        headerInfo: _header(),
        info: _info(count: 1),
      );
      expect(
        result.questions[0].status,
        CBuildQuestionStatus.partial,
        reason: '拆分重建后行内公式原图标记仍应汇总为 PARTIAL',
      );
      expect(result.questions[0].hasOriginalFormula, isTrue);
    });
  });
}
