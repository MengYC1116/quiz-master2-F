// 十六批 C：内容去重与块翻译（WORD-DESIGN.md §4，D-189/D-194/D-198）。
//
// 与 PDF assembleCMarkdown 去重同口径（D-189）：题干含选项时不重复
// 追加；选项切分不确定直通报告；C/A 双路线；LaTeX 源码不外露；
// 表格展平；标题/代码各成一段。
import 'dart:io';

import 'package:docx_creator/docx_creator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/services/pdf_export/export_route.dart';
import 'package:quiz_master2/services/pdf_export/export_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/export_versions.dart';
import 'package:quiz_master2/services/word_export/word_content_builder.dart';

import 'b16_word_test_helpers.dart';

void main() {
  late Directory tempRoot;
  late FakeExportQuestionSource source;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('b16-word-content-');
    source = FakeExportQuestionSource();
  });

  tearDown(() async {
    if (tempRoot.existsSync()) {
      await tempRoot.delete(recursive: true);
    }
  });

  Future<ExportSnapshot> buildSnapshot(
    List<String> ids,
    ExportRoute route, {
    List<ExcludedQuestion> excluded = const [],
  }) => ExportSnapshot.fromSelection(
    ids: ids,
    excluded: excluded,
    route: route,
    filterText: '全部',
    sortText: '默认排序',
    source: source,
    tempRoot: tempRoot,
  );

  Future<UnpackedDocx> exportContent(WordContentResult content) async {
    final bytes = await DocxExporter().exportToBytes(
      content.document.build(),
    );
    return UnpackedDocx(bytes);
  }

  /// 加一道指定题干的 C 路线选择题（选项默认 A–D 甲乙丙丁）。
  void addStemQuestion(String id, String stem) {
    source.records[id] = choiceRecord(id: id, stem: stem);
    source.slices[id] = makePng(200, 100);
  }

  group('内容去重与块翻译（D-189/D-194）', () {
    test('题干含全部选项 → 每选项恰好出现一次', () async {
      addStemQuestion(
        'q0',
        '求下列各题的值\nA. 甲\nB. 乙\nC. 丙\nD. 丁',
      );
      final snapshot = await buildSnapshot(['q0'], ExportRoute.c);
      final content = buildWordContent(
        snapshot: snapshot,
        answersById: const {},
        versions: const ExportVersionSelection.practiceOnly(),
      );
      final doc = await exportContent(content);
      for (final label in ['A. 甲', 'B. 乙', 'C. 丙', 'D. 丁']) {
        expect(doc.countInDocument(label), 1, reason: label);
      }
    });

    test('题干只含 A/B → A/B 只在题干出现，C/D 追加一次', () async {
      addStemQuestion('q0', '求下列各题的值\nA. 甲\nB. 乙');
      final snapshot = await buildSnapshot(['q0'], ExportRoute.c);
      final content = buildWordContent(
        snapshot: snapshot,
        answersById: const {},
        versions: const ExportVersionSelection.practiceOnly(),
      );
      final doc = await exportContent(content);
      for (final label in ['A. 甲', 'B. 乙', 'C. 丙', 'D. 丁']) {
        expect(doc.countInDocument(label), 1, reason: label);
      }
    });

    test('题干无选项 → 四选项照常各追加一次', () async {
      addStemQuestion('q0', '求下列各题的值');
      final snapshot = await buildSnapshot(['q0'], ExportRoute.c);
      final content = buildWordContent(
        snapshot: snapshot,
        answersById: const {},
        versions: const ExportVersionSelection.practiceOnly(),
      );
      final doc = await exportContent(content);
      for (final label in ['A. 甲', 'B. 乙', 'C. 丙', 'D. 丁']) {
        expect(doc.countInDocument(label), 1, reason: label);
      }
    });

    test('optionSplitUncertain 直通报告（题干含全部标签时 true，无选项时 false）',
        () async {
      addStemQuestion(
        'q0',
        '求下列各题的值\nA. 甲\nB. 乙\nC. 丙\nD. 丁',
      );
      addStemQuestion('q1', '求下列各题的值');
      final snapshot = await buildSnapshot(['q0', 'q1'], ExportRoute.c);
      final content = buildWordContent(
        snapshot: snapshot,
        answersById: const {},
        versions: const ExportVersionSelection.practiceOnly(),
      );
      expect(content.questions[0].optionUncertain, isTrue);
      expect(content.questions[1].optionUncertain, isFalse);
    });

    test('C 路线无图题不嵌图片；A 路线嵌切片图', () async {
      addStemQuestion('q0', '求下列各题的值');
      final snapshotC = await buildSnapshot(['q0'], ExportRoute.c);
      final contentC = buildWordContent(
        snapshot: snapshotC,
        answersById: const {},
        versions: const ExportVersionSelection.practiceOnly(),
      );
      expect(contentC.imageCount, 0);
      final docC = await exportContent(contentC);
      expect(docC.mediaNames, isEmpty);

      addChoiceQuestion(source, 'q1');
      final snapshotA = await buildSnapshot(['q1'], ExportRoute.a);
      final contentA = buildWordContent(
        snapshot: snapshotA,
        answersById: const {},
        versions: const ExportVersionSelection.practiceOnly(),
        aPrepared: {
          'q1': WordAPreparedQuestion(
            enhancedBytes: makePng(200, 100),
            cappedWidthPx: 200,
            cappedHeightPx: 100,
            warnings: const [],
          ),
        },
      );
      expect(contentA.imageCount, 1);
      final docA = await exportContent(contentA);
      expect(docA.mediaNames.length, 1);
    });

    test('LaTeX 源码不在任何 XML 文本节点中（C-11）', () async {
      final slice = makePng(200, 100);
      // 注意：快照块序列由 ocrStem + option_contents 组装（不是 md_results），
      // 公式须写进 ocrStem；裁剪框在 ocrRaw 的 layout_details 里。
      source.records['q0'] = choiceRecord(
        id: 'q0',
        sliceWidth: 200,
        sliceHeight: 100,
        ocrStem: r'求 $x^2$ 的值',
        ocrRaw: formulaRaw(
          md: r'求 $x^2$ 的值',
          sliceW: 200,
          sliceH: 100,
        ),
      );
      source.slices['q0'] = slice;
      final service = makeWordService(source, tempRoot, hasKey: true);
      final result = await generateWord(service, ['q0']);
      final doc = UnpackedDocx(result.docxBytes);
      expect(doc.allXmlText, isNot(contains('x^2')));
      expect(doc.allXmlText, isNot(contains(r'$x^2$')));
      expect(doc.mediaNames.length, 1);
    });

    test('表格按行展平：单元格文本都在文档中', () async {
      addStemQuestion(
        'q0',
        '如下表所示\n| 姓名 | 分数 |\n|---|---|\n| 甲 | 90 |\n| 乙 | 80 |\nA. 甲\nB. 乙\nC. 丙\nD. 丁',
      );
      final snapshot = await buildSnapshot(['q0'], ExportRoute.c);
      final content = buildWordContent(
        snapshot: snapshot,
        answersById: const {},
        versions: const ExportVersionSelection.practiceOnly(),
      );
      final doc = await exportContent(content);
      for (final cell in ['姓名', '分数', '甲', '90', '乙', '80']) {
        expect(doc.documentXml, contains(cell), reason: cell);
      }
    });

    test('标题与代码各成一段', () async {
      addStemQuestion(
        'q0',
        '# 小标题\n```\ncode x\n```\n求下列各题的值\nA. 甲\nB. 乙\nC. 丙\nD. 丁',
      );
      final snapshot = await buildSnapshot(['q0'], ExportRoute.c);
      final content = buildWordContent(
        snapshot: snapshot,
        answersById: const {},
        versions: const ExportVersionSelection.practiceOnly(),
      );
      final doc = await exportContent(content);
      expect(doc.documentXml, contains('小标题'));
      expect(doc.documentXml, contains('code x'));
    });
  });
}
