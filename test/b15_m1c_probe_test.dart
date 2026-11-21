// 十五批 M1-C：分页机制探针（M1-DESIGN.md §10，探针先行，硬性顺序）。
//
// 探针目标（结论见 M1-DESIGN.md 附录 C；本文件同时留作回归测试）：
// (a) Inseparable 包裹的整题 Column 放不下时整体移下一页；
// (a2) 超长题块边界拆分分支按预期切分；
// (b) TextPainter 预估与 pdf 包实际排版的行数误差；
// (c) 预切分 + 续页标的端到端小样；
// (d) 公式离屏渲染 4.17× 映射口径（输出像素 ÷ 显示英寸 ≈ 300 DPI）。
//
// 实测校准常数（2026-11-20，pdf 3.13.1 + Noto Sans SC wght=400，
// 诊断方法：二分填充分页阈值；见本文件“校准”组）：
// - 可用内容高 U ≈ 727.87 pt（内容区 756.85 − 页眉/页脚约 29 pt；
//   页眉/页脚在 MultiPage 内占用内容区空间，见 pdf 3.13.1
//   multi_page.dart generate() 的 offsetStart/offsetEnd 调整）。
// - pdf 行高（11 pt 正文，lineSpacing 5.5）：单行高 ≈ 15.97 pt，
//   每增一行 +21.47 pt；N 行文本高 ≈ N×21.47 − 5.5。
//   （Flutter TextPainter 的行高是 11×1.5 = 16.5 pt，两者是
//   不同排版引擎，不得混用——初版探针因此误报 −6 行误差。）
// - 超高不可拆分部件（高 > 可用内容高）会使 MultiPage 无限翻页：
//   Debug 下 500 页后抛 PdfTooBigPageException，Release 下断言
//   关闭会一直翻页；分页器绝不能放出这种部件（见附录 C）。
// - 离屏渲染须用屏幕外定位（Positioned left:-10000）挂载：
//   Offstage(offstage: true) 与 Opacity(0) 均不绘制，
//   toImage() 抛 !debugNeedsPaint 断言。
//
// 记录方式：页码在 widget 的 paint() 时记录（paint 只在真正绘制
// 的那一页调；StatelessWidget.build 只在首次布局调一次，移页重布
// 局时不重调，不能用来定页码）。
//
// 注意：本文件不含任何公式源码；测试串均为普通中文 / 符号文字，
// 公式只用最简占位形式作渲染路径验证（与 b15_m1b_fake_source.dart
// 同口径）。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:quiz_master2/services/pdf_export/pdf_document_builder.dart';
import 'package:quiz_master2/services/pdf_export/pdf_font.dart';

/// 内容区高（pt，M1-DESIGN.md §7：756.85）。
const double kContentH = 756.85;

/// 内容区宽（pt：510.2）。
const double kContentW = 510.2;

/// 实测可用内容高（pt：内容区高 − 页眉/页脚，见文件头校准说明）。
const double kUsableH = 727.87;

/// pdf 11 pt 正文单行高（pt，实测 ≈ 15.97）。
const double kPdfLineH11 = 15.97;

/// pdf 11 pt 正文每增一行的增量（pt，实测 ≈ 21.47 = 单行高 + 5.5）。
const double kPdfLinePitch11 = 21.47;

/// pdf 11 pt 正文 N 行文本高（pt，实测模型 N×21.47 − 5.5）。
double pdfTextHeight11(int lines) => lines * kPdfLinePitch11 - 5.5;

/// paint 时记录“某部件实际绘制在哪一页”。
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

/// 一份探针文档的绘制记录：部件 id → 绘制页号（按绘制顺序）。
class _ProbeDoc {
  _ProbeDoc({required this.font, required this.children});

  final pw.Font font;
  final List<pw.Widget> children;
  final Map<String, List<int>> painted = {};
  var maxPage = 0;

  Future<Uint8List> build() async {
    final builder = PdfExportDocumentBuilder(font: font);
    final doc = builder.createDocument(
      metadata: const PdfExportMetadata(title: 'M1-C 分页探针'),
    );
    doc.addPage(
      builder.multiPage(
        children: children,
        plan: const PdfPaginationPlan(totalPages: 99),
        headerInfo: const PdfExportHeaderInfo(
          subjectName: '探针',
          exportDateText: '2026-11-20',
        ),
      ),
    );
    return builder.savePdf(doc);
  }

  pw.Widget record(String id, pw.Widget child) => _PageRecorder(
        id: id,
        onPaint: (w, p) {
          painted.putIfAbsent(w, () => []).add(p);
          if (p > maxPage) maxPage = p;
        },
        child: child,
      );
}

Future<void> _loadFlutterFont(Uint8List fontBytes) async {
  final loader = FontLoader('ProbeNoto');
  loader.addFont(
    Future.value(ByteData.view(fontBytes.buffer)),
  );
  await loader.load();
}

/// TextPainter 行数（同一字体 / 同一字号 / 同一宽度 / 同一行高）。
int _textPainterLines(String text, double widthPt, double fontSize) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: 'ProbeNoto',
        fontSize: fontSize,
        height: 1.5,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: widthPt);
  return painter.computeLineMetrics().length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late pw.Font font;
  late Uint8List fontBytes;

  setUpAll(() async {
    fontBytes = await File(
      'assets/fonts/NotoSansSC-Regular.ttf',
    ).readAsBytes();
    font = PdfExportFont.fontFromBytes(fontBytes);
    await _loadFlutterFont(fontBytes);
  });

  group('校准：可用内容高与 pdf 行高', () {
    test('可用内容高 ≈ 727.87 pt（二分阈值，页眉/页脚占约 29 pt）',
        () async {
      Future<bool> fits(double h) async {
        final painted = <String, List<int>>{};
        final builder = PdfExportDocumentBuilder(font: font);
        final doc = builder.createDocument(
          metadata: const PdfExportMetadata(title: 'M1-C 分页探针'),
        );
        try {
          doc.addPage(
            builder.multiPage(
              children: [
                _PageRecorder(
                  id: 'box',
                  onPaint: (id, p) =>
                      painted.putIfAbsent(id, () => []).add(p),
                  child: pw.SizedBox(height: h),
                ),
              ],
              plan: const PdfPaginationPlan(totalPages: 99),
              headerInfo: const PdfExportHeaderInfo(
                subjectName: '探针',
                exportDateText: '2026-11-20',
              ),
            ),
          );
          await builder.savePdf(doc);
        } catch (_) {
          // 超高不可拆分部件致 MultiPage 无限翻页（Debug 抛错）→ 放不下。
          return false;
        }
        return painted['box']!.last == 1;
      }

      var lo = 600.0, hi = 740.0;
      for (var i = 0; i < 12; i++) {
        final mid = (lo + hi) / 2;
        if (await fits(mid)) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      expect(lo, inInclusiveRange(726, 730),
          reason: '可用内容高实测 $lo，不在 726–730 范围内（常数漂移）');
    });

    test('pdf 11 pt 行高：每增一行 +21.47 pt（显式换行标定）', () async {
      Future<double> maxFiller(String text) async {
        Future<bool> markerOnPage1(double fillerH) async {
          final painted = <String, List<int>>{};
          final builder = PdfExportDocumentBuilder(font: font);
          final doc = builder.createDocument(
            metadata: const PdfExportMetadata(title: 'M1-C 分页探针'),
          );
          try {
            doc.addPage(
              builder.multiPage(
                children: [
                  pw.SizedBox(height: fillerH),
                  builder.spanText(text),
                  _PageRecorder(
                    id: 'm',
                    onPaint: (id, p) =>
                        painted.putIfAbsent(id, () => []).add(p),
                    child: pw.Text('标记', style: builder.bodyStyle),
                  ),
                ],
                plan: const PdfPaginationPlan(totalPages: 99),
                headerInfo: const PdfExportHeaderInfo(
                  subjectName: '探针',
                  exportDateText: '2026-11-20',
                ),
              ),
            );
            await builder.savePdf(doc);
          } catch (_) {
            return false;
          }
          return painted['m']!.last == 1;
        }

        var lo = 0.0, hi = 727.0;
        for (var i = 0; i < 12; i++) {
          final mid = (lo + hi) / 2;
          if (await markerOnPage1(mid)) {
            lo = mid;
          } else {
            hi = mid;
          }
        }
        return lo;
      }

      final f1 = await maxFiller('测');
      final f2 = await maxFiller('测\n测');
      final f3 = await maxFiller('测\n测\n测');
      expect(f1 - f2, inInclusiveRange(21.0, 22.0));
      expect(f2 - f3, inInclusiveRange(21.0, 22.0));
    });
  });

  group('探针 (a)：Inseparable 整题移页', () {
    test('放不下的整题整体移下一页，不拆分、不裁剪、不抛错', () async {
      final doc = _ProbeDoc(font: font, children: []);
      // 第 1 页先占 600 pt，只剩约 127.87 pt；整题高 220 pt 放不下。
      doc.children.addAll([
        doc.record('filler', pw.SizedBox(height: 600)),
        doc.record(
          'q2',
          pw.Inseparable(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('第 2 题', style: PdfExportDocumentBuilder(
                  font: font,
                ).questionNumberStyle),
                pw.SizedBox(height: 200),
                pw.Text('题尾', style: PdfExportDocumentBuilder(
                  font: font,
                ).bodyStyle),
              ],
            ),
          ),
        ),
      ]);
      final bytes = await doc.build();
      expect(bytes.lengthInBytes, greaterThan(1000));
      expect(doc.painted['filler'], [1]);
      // 整题只在第 2 页绘制一次（题号行与题尾同页，未拆分）。
      expect(doc.painted['q2'], [2]);
      expect(doc.maxPage, 2);
    });

    test('对照：无 Inseparable 的 Column 会被跨页拆分', () async {
      final doc = _ProbeDoc(font: font, children: []);
      doc.children.addAll([
        doc.record('filler', pw.SizedBox(height: 600)),
        doc.record(
          'q2plain',
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('第 2 题', style: PdfExportDocumentBuilder(
                font: font,
              ).questionNumberStyle),
              pw.SizedBox(height: 200),
              pw.Text('题尾', style: PdfExportDocumentBuilder(
                font: font,
              ).bodyStyle),
            ],
          ),
        ),
      ]);
      await doc.build();
      // 无 Inseparable 时同一 Column 的绘制横跨两页（对照组，证明
      // Inseparable 才是强制移页的机制）。
      expect(doc.painted['q2plain']!.toSet(), {1, 2});
    });

    test('恰好放得下时留在本页（边界：剩余空间 = 题高）', () async {
      const qHeight = 200.0;
      final doc = _ProbeDoc(font: font, children: []);
      doc.children.addAll([
        doc.record('filler', pw.SizedBox(height: kUsableH - qHeight)),
        doc.record(
          'q2',
          pw.Inseparable(
            child: pw.SizedBox(height: qHeight),
          ),
        ),
      ]);
      await doc.build();
      expect(doc.painted['q2'], [1]);
      expect(doc.maxPage, 1);
    });

    test('略超剩余空间 1 pt 时整题移页', () async {
      const qHeight = 200.0;
      final doc = _ProbeDoc(font: font, children: []);
      doc.children.addAll([
        doc.record(
          'filler',
          pw.SizedBox(height: kUsableH - qHeight + 1),
        ),
        doc.record(
          'q2',
          pw.Inseparable(
            child: pw.SizedBox(height: qHeight),
          ),
        ),
      ]);
      await doc.build();
      expect(doc.painted['q2'], [2]);
      expect(doc.maxPage, 2);
    });
  });

  group('探针 (b)：TextPainter 预估 vs pdf 实际行数', () {
    // 边界翻转法（用 pdf 行高模型算阈值填充 F*，在 F* ± 33 pt 内
    // 以 8.25 pt 步进找“题后标记从第 1 页翻到第 2 页”的点；
    // 翻转点每偏一个 pdf 行距（21.47 pt）即 1 行误差）。
    // 返回 pdf 行数 − TextPainter 行数（>0 表示 pdf 行更多）。
    Future<int> lineError(
      String sample,
      double widthPt,
      double fontSize,
    ) async {
      final lines = _textPainterLines(sample, widthPt, fontSize);
      // 本探针只用 11 pt 正文；模型按 11 pt 取。
      assert(fontSize == 11);
      final fStar = kUsableH - pdfTextHeight11(lines) - kPdfLineH11;
      const deltas = [-33.0, -24.75, -16.5, -8.25, 0.0, 8.25, 16.5, 24.75, 33.0];
      var lastFitDelta = -99.0;
      for (final d in deltas) {
        final doc = _ProbeDoc(font: font, children: []);
        final builder = PdfExportDocumentBuilder(font: font);
        doc.children.addAll([
          doc.record('filler', pw.SizedBox(height: fStar + d)),
          doc.record(
            'text',
            pw.SizedBox(
              width: widthPt,
              child: builder.spanText(
                sample,
                style: pw.TextStyle(
                  font: font,
                  fontSize: fontSize,
                  lineSpacing: fontSize * 0.5,
                ),
              ),
            ),
          ),
          doc.record('marker', pw.Text('标记', style: builder.bodyStyle)),
        ]);
        await doc.build();
        if (doc.painted['marker']!.last == 1) lastFitDelta = d;
      }
      // pdf 行更多 → 文本更高 → 阈值填充更小 → lastFitDelta 为负。
      return (-lastFitDelta / kPdfLinePitch11).round();
    }

    test('样本 1：中文长题干（约 540 字），误差在 ±1 行内', () async {
      final sample = '已知函数满足下列条件：${'设实数满足不等式关系，且区间端点均为整数，试求满足条件的取值范围，并给出完整的推理过程。' * 12}';
      final err = await lineError(sample, kContentW, 11);
      expect(err.abs(), lessThanOrEqualTo(1),
          reason: '样本 1 行数误差 $err 行，超出 ±1 行');
    });

    test('样本 2：中文题干 + A–D 选项行', () async {
      final sample =
          '下列说法中正确的是哪一项？请结合所给条件逐项分析。' * 6 +
          '\nA. 第一个选项的内容描述较长，需要换行显示。'
              '\nB. 第二个选项的内容描述同样较长，需要换行显示。'
              '\nC. 第三个选项的内容描述同样较长，需要换行显示。'
              '\nD. 第四个选项的内容描述同样较长，需要换行显示。';
      final err = await lineError(sample, kContentW, 11);
      expect(err.abs(), lessThanOrEqualTo(1),
          reason: '样本 2 行数误差 $err 行，超出 ±1 行');
    });

    test('样本 3：中英混排 + 全角标点', () async {
      final sample =
          '阅读下面这段文字：The function f(x) is defined on the interval [0, 1]，'
              '并且满足以下条件：当 x 趋近于 0 时，函数值趋近于 1；当 x 趋近于 1 时，'
              '函数值趋近于 0。请判断下列命题的真假，并说明理由。' * 6;
      final err = await lineError(sample, kContentW, 11);
      expect(err.abs(), lessThanOrEqualTo(1),
          reason: '样本 3 行数误差 $err 行，超出 ±1 行');
    });

    test('样本 4：多逗号句号长句（断行压力）', () async {
      final sample =
          '已知集合，元素，子集，并集，交集，补集，空集，全集，幂集，笛卡尔积，'
              '映射，函数，定义域，值域，单调性，奇偶性，周期性，有界性，连续性，'
              '可导性，可积性，收敛性，发散性，有界性，单调性，奇偶性。' * 6;
      final err = await lineError(sample, kContentW, 11);
      expect(err.abs(), lessThanOrEqualTo(1),
          reason: '样本 4 行数误差 $err 行，超出 ±1 行');
    });

    test('样本 5：半宽（255.1 pt）中文长题干', () async {
      final sample = '已知函数满足下列条件：${'设实数满足不等式关系，且区间端点均为整数，试求满足条件的取值范围，并给出完整的推理过程。' * 8}';
      final err = await lineError(sample, kContentW / 2, 11);
      expect(err.abs(), lessThanOrEqualTo(1),
          reason: '样本 5 行数误差 $err 行，超出 ±1 行');
    });
  });

  group('探针 (a2/c)：超长题块边界拆分 + 续页标', () {
    test('约 3 页长文本按行预切分，续页标与题号位置正确', () async {
      // 用 TextPainter 按行切分：每页容纳 33 行（33 行文本高
      // 703.01 pt，另加题号/续页标行仍在可用内容高 727.87 内）。
      final longText =
          '本题为超长题干示例。${'设实数满足不等式关系，且区间端点均为整数，试求满足条件的取值范围，并给出完整的推理过程。' * 100}';
      final painter = TextPainter(
        text: TextSpan(
          text: longText,
          style: const TextStyle(
            fontFamily: 'ProbeNoto',
            fontSize: 11,
            height: 1.5,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: kContentW);
      final metrics = painter.computeLineMetrics();
      const linesPerPage = 33;
      expect(metrics.length, greaterThan(linesPerPage * 2));
      // 按行号切成页内组：行首字符偏移用 getPositionForOffset 取
      // （LineMetrics 不含字符偏移）。
      int lineStart(int lineIndex) {
        if (lineIndex >= metrics.length) return longText.length;
        return painter
            .getPositionForOffset(
              Offset(0.5, lineIndex * 16.5 + 1),
            )
            .offset;
      }

      final groups = <String>[];
      for (var start = 0; start < metrics.length; start += linesPerPage) {
        final end = (start + linesPerPage).clamp(0, metrics.length);
        groups.add(
          longText.substring(lineStart(start), lineStart(end)),
        );
      }
      expect(groups.length, 3);
      final builder = PdfExportDocumentBuilder(font: font);
      final doc = _ProbeDoc(font: font, children: []);
      for (var i = 0; i < groups.length; i++) {
        doc.children.add(
          doc.record(
            'q3-p${i + 1}',
            // 预切分组须包 Inseparable：否则 Column（可跨页）会在上一页
            // 剩余空间里先画一部分，续页标与题号错位。
            pw.Inseparable(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  if (i == 0)
                    pw.Text('第 3 题', style: builder.questionNumberStyle),
                  if (i > 0)
                    pw.Text('第 3 题（接上页）', style: builder.bodyStyle),
                  builder.spanText(groups[i]),
                  if (i == groups.length - 1)
                    pw.Text('本题完', style: builder.bodyStyle),
                ],
              ),
            ),
          ),
        );
      }
      await doc.build();
      expect(doc.maxPage, 3);
      expect(doc.painted['q3-p1'], [1]);
      expect(doc.painted['q3-p2'], [2]);
      expect(doc.painted['q3-p3'], [3]);
    });
  });

  group('探针 (d)：公式离屏渲染 4.17× 映射', () {
    // 屏幕外定位挂载（Offstage 与 Opacity(0) 均不绘制，toImage 失败）。
    Future<(ui.Image, ui.Size)> grabFormula(
      WidgetTester tester,
      String tex,
      MathStyle style,
    ) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: -10000,
                  top: 0,
                  child: RepaintBoundary(
                    key: key,
                    child: Math.tex(
                      tex,
                      mathStyle: style,
                      textStyle: const TextStyle(fontSize: 11),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 300 / 72);
      return (image, boundary.size);
    }

    testWidgets('行内公式离屏渲染输出像素 ÷ 显示英寸 ≈ 300 DPI',
        (tester) async {
      final (image, size) = await grabFormula(tester, 'x^2+1', MathStyle.text);
      expect(size.width, greaterThan(0));
      final dpi = image.width / (size.width / 72);
      // 300 DPI ±5%（285–315）。
      expect(dpi, inInclusiveRange(285, 315));
      image.dispose();
    });

    testWidgets('独立公式离屏渲染同样满足 300 DPI 映射',
        (tester) async {
      final (image, size) =
          await grabFormula(tester, 'x^2+1', MathStyle.display);
      final dpi = image.width / (size.width / 72);
      expect(dpi, inInclusiveRange(285, 315));
      image.dispose();
    });

    testWidgets('公式解析失败走 onErrorFallback，不抛错', (tester) async {
      var fallbackShown = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Math.tex(
              r'\badcommand{',
              mathStyle: MathStyle.text,
              textStyle: const TextStyle(fontSize: 11),
              onErrorFallback: (_) {
                fallbackShown = true;
                return const Text('公式渲染失败');
              },
            ),
          ),
        ),
      );
      await tester.pump();
      expect(fallbackShown, isTrue);
      expect(find.text('公式渲染失败'), findsOneWidget);
    });
  });
}
