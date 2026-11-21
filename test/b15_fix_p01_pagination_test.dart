// 十五批修复批 P0-1：分页运行时保护（D-183）。
//
// 覆盖：
// - 公式高度建模：含高行内公式的行按 max（文本行高，公式显示高）计，
//   整题分支与切分支均按此高度规划；
// - 整题分支 2 行安全余量：封顶附近的整题强制走切分支；
// - 来源行定长：formatExportSourceText 超长截断加省略号（单行硬约束）；
// - 页眉学科名定长：PdfExportHeaderInfo.line 超长截断加省略号；
// - A 路线预留：容器高 = 内容区高 − 40 pt。
// 本文件不含任何公式源码；测试串只用最简占位形式。
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/services/pdf_export/a_content_builder.dart';
import 'package:quiz_master2/services/pdf_export/export_question_record.dart';
import 'package:quiz_master2/services/pdf_export/pdf_document_builder.dart';
import 'package:quiz_master2/services/pdf_export/text_pagination.dart';

/// 假断行器：每行 floor(宽/字号) 字（510.2/11 → 46 字/行，M1-C 同款）。
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
  List<CInlineFormula> formulas = const [],
  String source = '',
}) =>
    CPaginableQuestion(
      questionIndex: index,
      displayNumber: index + 1,
      blocks: [
        CLayoutParagraph(
          CParagraph(text: text, inlineFormulas: formulas),
        ),
      ],
      sourceText: source,
    );

/// 1 行占位公式（宽 11 pt → 1 个占位符，高 [heightPt]）。
CInlineFormula _formula(double heightPt) => CInlineFormula(
      offset: 0,
      widthPt: 11,
      heightPt: heightPt,
      formulaId: 'f0',
      ref: 'formulas/q0-f0.png',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CTextPaginator paginator;

  setUp(() {
    paginator = CTextPaginator(splitter: _FakeSplitter());
  });

  group('公式高度建模（D-183）', () {
    test('单行含高公式：行高取公式显示高，不取纯文本行高', () {
      // 40 字 + 1 个高 30 pt 的行内公式 → 1 行，行高 30（不是 15.97）。
      final plan = paginator.paginate([_q(0, '测' * 40, formulas: [_formula(30)])]);
      expect(plan.totalPages, 1);
      expect(validatePlan(plan), isEmpty);
      final part = plan.pages.single.parts.single;
      expect(
        part.heightPt,
        closeTo(kPdfQuestionNumberHeightPt + 30, 0.01),
      );
    });

    test('多行含高公式：整题分支高度含公式超高部分', () {
      // 12 行文字 + 行首一个高 40 pt 的公式 → 13 行（占位符占 1 字，
      // 末行剩 1 字），总高 = 40 + 12×15.97 + 12×5.5 = 297.64，
      // 整题高 316.51；页高取整题 + 余量时仍走整题分支。
      final wholeH = kPdfQuestionNumberHeightPt + 40 + 12 * 15.97 + 12 * 5.5;
      final plan = paginator.paginate(
        [_q(0, '测' * (46 * 12), formulas: [_formula(40)])],
        firstPageAvailableHeightPt: wholeH + kWholeQuestionSafetyMarginPt,
        otherPageAvailableHeightPt: wholeH + kWholeQuestionSafetyMarginPt,
      );
      expect(plan.totalPages, 1);
      expect(validatePlan(plan), isEmpty);
      final part = plan.pages.single.parts.single;
      expect(part.heightPt, closeTo(wholeH, 0.01));
      expect((part.blocks.single as CPartRichText).lines, 13);
    });

    test('多行含高公式：切分支按行高取行，高公式行不挤进同一段', () {
      // 与上一测试同一题，页高少 0.5 pt → 强制走切分支；首段取 12 行
      // （含高公式行），续段 1 行，共 2 页。不建模时 13 行全进首段。
      final wholeH = kPdfQuestionNumberHeightPt + 40 + 12 * 15.97 + 12 * 5.5;
      final pageH = wholeH + kWholeQuestionSafetyMarginPt - 0.5;
      final plan = paginator.paginate(
        [_q(0, '测' * (46 * 12), formulas: [_formula(40)])],
        firstPageAvailableHeightPt: pageH,
        otherPageAvailableHeightPt: pageH,
      );
      expect(plan.totalPages, 2);
      expect(validatePlan(plan), isEmpty);
      final parts = [
        for (final page in plan.pages) ...page.parts,
      ];
      expect(parts.length, 2);
      expect((parts[0].blocks.single as CPartRichText).lines, 12);
      expect((parts[1].blocks.single as CPartRichText).lines, 1);
      expect(parts[1].continuation, isTrue);
    });

    test('矮公式不抬高行高：行高仍取文本行高', () {
      // 公式高 10 pt < 单行 15.97 pt，行高不变。
      final plan = paginator.paginate([_q(0, '测' * 40, formulas: [_formula(10)])]);
      expect(plan.totalPages, 1);
      final part = plan.pages.single.parts.single;
      expect(
        part.heightPt,
        closeTo(kPdfQuestionNumberHeightPt + 15.97, 0.01),
      );
    });
  });

  group('来源行与页眉定长（D-183）', () {
    test('来源行超长截断加省略号，单行硬约束', () {
      final text = formatExportSourceText(
        subjectName: '数学',
        folderNames: ['这是一个非常长的文件夹名字用来测试截断行为是否生效再加二十一个字补足四十五'],
        examName: '期末考试',
      );
      expect(text.endsWith('…'), isTrue);
      expect(text.length, kExportSourceLineMaxChars + 1);
      expect(text.startsWith('数学 / 这是一个非常长的文件夹名字'), isTrue);
    });

    test('来源行恰好 45 字不截断，46 字截断', () {
      final exact = formatExportSourceText(
        subjectName: '数学',
        folderNames: ['测' * 40],
      );
      // '数学 / '（5 字）+ 40 字 = 45 字，不截断。
      expect(exact.length, 45);
      expect(exact.endsWith('…'), isFalse);
      final over = formatExportSourceText(
        subjectName: '数学',
        folderNames: ['测' * 41],
      );
      expect(over.length, kExportSourceLineMaxChars + 1);
      expect(over.endsWith('…'), isTrue);
    });

    test('页眉学科名超长截断加省略号，页眉恒为单行', () {
      final info = PdfExportHeaderInfo(
        subjectName: '这是一个非常长的学科名称用来测试页眉截断行为是否生效呀再加十个字补足四十',
        exportDateText: '2026-11-21',
      );
      // 36 字学科名截断为前 30 字 + '…'。
      expect(info.line.contains('…'), isTrue);
      expect(
        info.line,
        startsWith('错题本 · 这是一个非常长的学科名称用来测试页眉截断行为是否生效呀再加十'),
      );
      expect(info.line, endsWith(' · 2026-11-21'));
    });

    test('页眉学科名 30 字以内不截断', () {
      final info = PdfExportHeaderInfo(
        subjectName: '高等数学',
        exportDateText: '2026-11-21',
      );
      expect(info.line, '错题本 · 高等数学 · 2026-11-21');
    });
  });

  group('A 路线预留（D-183）', () {
    test('容器高 = 内容区高 − 40 pt', () {
      expect(
        AContentBuilder.pageContainerHeightPt,
        closeTo(756.85 - 40, 0.01),
      );
      expect(kAHeaderFooterReservePt, 40);
    });
  });

  group('规划自检 Release 生效（D-183）', () {
    test('常量修正：可用高 727.81（原 727.87 高 0.06 pt）', () {
      expect(kPdfUsableHeightPt, 727.81);
      expect(
        kPdfFirstPageAvailableHeightPt,
        closeTo(727.81 - kPdfExportInfoZoneHeightPt, 0.01),
      );
    });

    test('整题余量常量 = 2 行来源行高（约 29 pt）', () {
      expect(
        kWholeQuestionSafetyMarginPt,
        closeTo(2 * kPdfSourceLineHeightPt, 0.01),
      );
    });
  });
}
