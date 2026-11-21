// 十六批 C：内容构建器断言（WORD-DESIGN.md §2.4/§3，D-194/D-197）。
//
// 快照 → buildWordContent → exportToBytes → 解包查 XML：标题/信息区/
// 题号/选项/来源行/分隔线/答案区。
import 'dart:io';

import 'package:docx_creator/docx_creator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/services/pdf_export/answer_section.dart';
import 'package:quiz_master2/services/pdf_export/export_question_record.dart';
import 'package:quiz_master2/services/pdf_export/export_route.dart';
import 'package:quiz_master2/services/pdf_export/export_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/export_versions.dart';
import 'package:quiz_master2/services/word_export/word_content_builder.dart';

import 'b16_word_test_helpers.dart';

void main() {
  late Directory tempRoot;
  late FakeExportQuestionSource source;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('b16-word-build-');
    source = FakeExportQuestionSource();
  });

  tearDown(() async {
    if (tempRoot.existsSync()) {
      await tempRoot.delete(recursive: true);
    }
  });

  Future<ExportSnapshot> buildC(
    List<String> ids, {
    List<ExcludedQuestion> excluded = const [],
  }) => ExportSnapshot.fromSelection(
    ids: ids,
    excluded: excluded,
    route: ExportRoute.c,
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

  String todayText() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  group('内容构建器（D-194/D-197）', () {
    test('标题 + 信息区 5 行 + 题号行 + 选项', () async {
      addChoiceQuestion(source, 'q0');
      addChoiceQuestion(source, 'q1');
      final snapshot = await buildC(['q0', 'q1']);
      final content = buildWordContent(
        snapshot: snapshot,
        answersById: const {},
        versions: const ExportVersionSelection.practiceOnly(),
      );
      final doc = await exportContent(content);
      expect(doc.documentXml, contains('错题本导出'));
      expect(doc.documentXml, contains('筛选：全部'));
      expect(doc.documentXml, contains('题数：2 道'));
      expect(doc.documentXml, contains('日期：${todayText()}'));
      expect(doc.documentXml, contains('排序：默认排序'));
      expect(doc.documentXml, contains('OCR 重排路线'));
      expect(doc.documentXml, contains('第 1 题'));
      expect(doc.documentXml, contains('第 2 题'));
      expect(doc.documentXml, contains('A. 甲'));
      expect(doc.documentXml, contains('D. 丁'));
      expect(content.questions.length, 2);
      expect(content.imageCount, 0);
    });

    test('连续编号：跳过题不占题号', () async {
      addChoiceQuestion(source, 'q0');
      addChoiceQuestion(source, 'q1');
      addChoiceQuestion(source, 'q2');
      final snapshot = await buildC(
        ['q0', 'q1', 'q2'],
        excluded: const [
          ExcludedQuestion(id: 'q1', reason: '用户排除'),
        ],
      );
      final content = buildWordContent(
        snapshot: snapshot,
        answersById: const {},
        versions: const ExportVersionSelection.practiceOnly(),
      );
      final doc = await exportContent(content);
      expect(doc.documentXml, contains('第 1 题'));
      expect(doc.documentXml, contains('第 2 题'));
      expect(doc.documentXml, isNot(contains('第 3 题')));
      expect(content.displayNumbersById, {'q0': 1, 'q2': 2});
    });

    test('多文件夹来源行列出全部文件夹名', () async {
      addChoiceQuestion(
        source,
        'q0',
        folderNames: const ['文件夹A', '文件夹B'],
      );
      final snapshot = await buildC(['q0']);
      final content = buildWordContent(
        snapshot: snapshot,
        answersById: const {},
        versions: const ExportVersionSelection.practiceOnly(),
        recordsById: source.records,
        sourceTextFor: (r) => formatExportSourceText(
          subjectName: '数学',
          folderNames: r.folderNames,
          examName: r.examName,
        ),
      );
      final doc = await exportContent(content);
      expect(doc.documentXml, contains('文件夹A'));
      expect(doc.documentXml, contains('文件夹B'));
    });

    test('多学科写“多学科”（页眉与信息区均不取首题学科）', () async {
      addChoiceQuestion(source, 'q0');
      final snapshot = await buildC(['q0']);
      final content = buildWordContent(
        snapshot: snapshot,
        answersById: const {},
        versions: const ExportVersionSelection.practiceOnly(),
        subjectName: '多学科',
      );
      final doc = await exportContent(content);
      expect(doc.allXmlText, contains('错题本 · 多学科 · '));
    });

    test('答案区在分页符后、按题号顺序、缺失印占位', () async {
      addChoiceQuestion(
        source,
        'q0',
        answer: 'A',
        explanation: '解析甲',
      );
      addChoiceQuestion(source, 'q1');
      final snapshot = await buildC(['q0', 'q1']);
      final content = buildWordContent(
        snapshot: snapshot,
        answersById: {
          'q0': const AnswerSourceData(
            questionId: 'q0',
            answer: 'A',
            explanation: '解析甲',
          ),
        },
        versions: const ExportVersionSelection.both(),
      );
      final doc = await exportContent(content);
      final xml = doc.documentXml;
      expect(xml, contains('pageBreakBefore'));
      expect(xml, contains('答案与解析'));
      // 答案区在最后一道题之后（答案区自己的“第 2 题”条目在标题后，
      // 故用首次出现的题号行比较）。
      expect(
        xml.indexOf('答案与解析') > xml.indexOf('第 2 题'),
        isTrue,
      );
      // q0 的答案在 q1 的占位之前（按题号顺序）。
      expect(xml.indexOf('答案：A') < xml.indexOf('本题未录入答案'), isTrue);
      expect(xml, contains('解析：解析甲'));
      expect(xml, contains('本题未录入答案'));
      expect(xml, contains('本题未录入解析'));
    });

    test('答案区标题下明示来源（非 OCR 识别结果）', () async {
      addChoiceQuestion(source, 'q0', answer: 'A');
      final snapshot = await buildC(['q0']);
      final content = buildWordContent(
        snapshot: snapshot,
        answersById: {
          'q0': const AnswerSourceData(questionId: 'q0', answer: 'A'),
        },
        versions: const ExportVersionSelection.both(),
      );
      final doc = await exportContent(content);
      expect(
        doc.documentXml,
        contains('答案与解析由用户在错题本中录入，非 OCR 识别结果。'),
      );
    });

    test('题间分隔线：最后一题后不画', () async {
      addChoiceQuestion(source, 'q0');
      addChoiceQuestion(source, 'q1');
      addChoiceQuestion(source, 'q2');
      final snapshot = await buildC(['q0', 'q1', 'q2']);
      final content = buildWordContent(
        snapshot: snapshot,
        answersById: const {},
        versions: const ExportVersionSelection.practiceOnly(),
      );
      final doc = await exportContent(content);
      // hr() 为单一下边框段落（`<w:bottom w:val="single"`）；3 道题 →
      // 2 条分隔线（页边距的 w:bottom="850" 不计入）。
      expect(
        '<w:bottom w:val="single"'.allMatches(doc.documentXml).length,
        2,
      );
    });

    test('题型为 NULL 时不写题型后缀、不猜题型', () async {
      addChoiceQuestion(source, 'q0', questionType: null);
      final snapshot = await buildC(['q0']);
      final content = buildWordContent(
        snapshot: snapshot,
        answersById: const {},
        versions: const ExportVersionSelection.practiceOnly(),
        recordsById: source.records,
      );
      final doc = await exportContent(content);
      expect(doc.documentXml, contains('第 1 题'));
      expect(doc.documentXml, isNot(contains('第 1 题（')));
    });
  });
}
