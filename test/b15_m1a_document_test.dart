// 十五批 M1-A：文档骨架测试（M1-DESIGN.md §7）。
//
// 覆盖：
// - 几何：A4 595.28×841.89 pt、边距 15 mm、内容宽 510.2 pt、内容高 756.85 pt；
// - 字号：题号 13 加粗 / 正文 11 / 页眉页脚 10，行距 1.5×；
// - 页数策略：MultiPage.maxPages 显式设 500；
// - 元数据：标题 / 作者 / 创建者显式设定；
// - 页眉（错题本 · 学科名 · 导出日期）、页脚（第 x / y 页）、
//   第一页导出信息区（筛选 / 题数 / 日期 / 排序 / 路线）；
// - C-6：spanText 一律 TextOverflow.span；
// - C-7：savePdf 返回 await 后的完整 PDF 字节（%PDF- 开头）。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:quiz_master2/services/pdf_export/pdf_document_builder.dart';
import 'package:quiz_master2/services/pdf_export/pdf_font.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('几何（S1 生成器沿用）', () {
    test('A4 尺寸', () {
      expect(PdfExportGeometry.pageWidthPt, 595.28);
      expect(PdfExportGeometry.pageHeightPt, 841.89);
    });

    test('边距 15 mm ≈ 42.52 pt', () {
      expect(PdfExportGeometry.marginMm, 15);
      expect(PdfExportGeometry.marginPt, closeTo(42.52, 0.01));
    });

    test('内容区宽 510.2 pt、高 756.85 pt', () {
      expect(PdfExportGeometry.contentWidthPt, closeTo(510.2, 0.1));
      expect(PdfExportGeometry.contentHeightPt, closeTo(756.85, 0.1));
    });
  });

  group('字号与行距', () {
    test('题号 13 加粗 / 正文 11 / 页眉页脚 10', () {
      expect(PdfExportTypography.questionNumberPt, 13);
      expect(PdfExportTypography.bodyPt, 11);
      expect(PdfExportTypography.headerFooterPt, 10);
    });

    test('行距 1.5×：正文附加行距为 0.5 × 字号', () {
      expect(PdfExportTypography.lineHeightFactor, 1.5);
      expect(PdfExportTypography.bodyLineSpacingPt, 5.5);
    });
  });

  group('页数策略', () {
    test('maxPages 显式设 500（默认 20 不可用）', () {
      expect(kPdfExportMaxPages, 500);
    });
  });

  group('页眉 / 页脚 / 信息区', () {
    test('页眉行：错题本 · 学科名 · 导出日期', () {
      const info = PdfExportHeaderInfo(
        subjectName: '数学',
        exportDateText: '2026-11-20',
      );
      expect(info.line, '错题本 · 数学 · 2026-11-20');
    });

    test('页脚文字：第 x / y 页', () {
      final builder = PdfExportDocumentBuilder(font: pw.Font.helvetica());
      expect(builder.footerText(3, 12), '第 3 / 12 页');
      expect(builder.footerText(1, 1), '第 1 / 1 页');
    });

    test('第一页信息区含筛选 / 题数 / 日期 / 排序 / 路线五项', () {
      const info = PdfExportInfo(
        filterText: '数学 · 全部文件夹',
        questionCount: 50,
        exportDateText: '2026-11-20',
        sortText: '按加入时间',
        routeText: 'OCR 重排路线（已配置 OCR key）',
      );
      expect(info.lines, <String>[
        '筛选：数学 · 全部文件夹',
        '题数：50 道',
        '日期：2026-11-20',
        '排序：按加入时间',
        '路线：OCR 重排路线（已配置 OCR key）',
      ]);
    });
  });

  group('文档构建与保存（C-6 / C-7）', () {
    late pw.Font font;
    late PdfExportDocumentBuilder builder;

    setUpAll(() async {
      font = await PdfExportFont.loadBundledFont();
      builder = PdfExportDocumentBuilder(font: font);
    });

    test('spanText 一律 TextOverflow.span（C-6）', () {
      final text = builder.spanText('超一页的长文本走 span 跨页流排');
      expect(text.overflow, pw.TextOverflow.span);
    });

    test('样式全部走内嵌字体（不依赖系统字体）', () {
      expect(builder.questionNumberStyle.font, font);
      expect(builder.bodyStyle.font, font);
      expect(builder.headerFooterStyle.font, font);
      expect(
        builder.questionNumberStyle.fontWeight,
        pw.FontWeight.bold,
      );
    });

    test('multiPage 的 maxPages 显式为 500', () {
      final page = builder.multiPage(
        children: <pw.Widget>[builder.spanText('第 1 题')],
        plan: const PdfPaginationPlan(totalPages: 1),
        headerInfo: const PdfExportHeaderInfo(
          subjectName: '数学',
          exportDateText: '2026-11-20',
        ),
      );
      expect(page.maxPages, 500);
    });

    test('savePdf 经 await 返回完整 PDF 字节（C-7）', () async {
      final doc = builder.createDocument(
        metadata: const PdfExportMetadata(title: '错题本导出 · 数学'),
      );
      doc.addPage(
        builder.multiPage(
          children: <pw.Widget>[
            builder.buildExportInfoZone(
              const PdfExportInfo(
                filterText: '数学 · 全部文件夹',
                questionCount: 1,
                exportDateText: '2026-11-20',
                sortText: '按加入时间',
                routeText: '图片增强路线（未配置 OCR key）',
              ),
            ),
            builder.spanText('第 1 题 错题本示例文本'),
          ],
          plan: const PdfPaginationPlan(totalPages: 1),
          headerInfo: const PdfExportHeaderInfo(
            subjectName: '数学',
            exportDateText: '2026-11-20',
          ),
        ),
      );
      // C-7：必须 await save()，完成前不得发布文件。
      final Uint8List bytes = await builder.savePdf(doc);
      expect(bytes.lengthInBytes, greaterThan(0));
      expect(bytes.sublist(0, 5), <int>[0x25, 0x50, 0x44, 0x46, 0x2D]);
      // 子集量级：单页中文 PDF 远小于 10.6 MB 全字体。
      expect(bytes.lengthInBytes, lessThan(1000000));
    });
  });
}
