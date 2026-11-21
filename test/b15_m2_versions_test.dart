// 十五批 M2-1：两版生成测试（PLAN-15-REV3 §5 M2-1/M2-4）。
//
// 覆盖：版本模型与默认勾选；答案/解析分别判空（含纯空白、
// answerPendingRecheck 置位、`$...$` 纯文本）；答案区条目与练习版
// 题号一一对应（同一快照生成，断言题号序列相等；跳过题不列入，
// BROKEN 占位题照常列入）；路由切换（有 key / 无 key 各跑一次端到端，
// 断言路线判定正确）；双文件部分成功（注入第二版生成失败，断言第一版
// 已验证结果保留、逐版状态分别列出）；key 状态读错时整单失败。
// 本文件不含任何公式源码；测试串只用最简占位形式。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/services/pdf_export/answer_section.dart';
import 'package:quiz_master2/services/pdf_export/export_question_record.dart';
import 'package:quiz_master2/services/pdf_export/export_route.dart';
import 'package:quiz_master2/services/pdf_export/export_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/export_versions.dart';
import 'package:quiz_master2/services/pdf_export/pdf_export_service.dart';
import 'package:quiz_master2/services/pdf_export/pdf_page_counter.dart';

import 'b15_m1b_fake_source.dart';

Uint8List? _fontBytesCache;

Future<Uint8List> _fontBytes() async =>
    _fontBytesCache ??= await File(
      'assets/fonts/NotoSansSC-Regular.ttf',
    ).readAsBytes();

/// 任务临时目录下残留的导出临时目录（应为空：任务结束一律清理）。
List<String> _leftoverExportDirs(Directory tempRoot) {
  if (!tempRoot.existsSync()) return const [];
  return tempRoot
      .listSync()
      .whereType<Directory>()
      .map((d) => d.path)
      .where((p) => p.contains('quiz-master2-pdf-export-'))
      .toList();
}

/// PDF 文本抽取（pdftotext 不可用时返回 null，调用方跳过文本断言）。
Future<String?> _pdfText(
  Uint8List bytes,
  Directory dir,
  String name,
) async {
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes);
  try {
    final result = await Process.run('pdftotext', [
      '-layout',
      file.path,
      '-',
    ]);
    if (result.exitCode != 0) return null;
    return result.stdout as String;
  } catch (_) {
    return null;
  }
}

int _countOccurrences(String text, String needle) =>
    needle.isEmpty ? 0 : text.split(needle).length - 1;

/// A 路线桩：3 道可印题 + 1 道 BROKEN 题（切片不可用）。
FakeExportQuestionSource _aSource() {
  final source = FakeExportQuestionSource();
  final records = <String, ExportQuestionRecord>{
    'q1': choiceRecord(
      id: 'q1',
      answer: 'A',
      explanation: '解析一',
    ),
    'q2': choiceRecord(
      id: 'q2',
      answer: '   ',
      explanation: '解析二',
    ),
    'q3': choiceRecord(id: 'q3', answer: null, explanation: null),
    'q4': choiceRecord(id: 'q4', answer: 'D', explanation: null),
  };
  for (final entry in records.entries) {
    source.records[entry.key] = entry.value;
    source.slices[entry.key] = makePng(2126, 140);
  }
  source.unavailableSlices.add('q4');
  return source;
}

/// C 路线桩：2 道可印题 + 1 道跳过题（题干为空）。
FakeExportQuestionSource _cSource() {
  final source = FakeExportQuestionSource();
  source.records['c1'] = choiceRecord(
    id: 'c1',
    answer: 'B',
    explanation: '解析甲',
  );
  source.records['c2'] = choiceRecord(
    id: 'c2',
    answer: null,
    explanation: '解析乙',
  );
  source.records['c3'] = choiceRecord(
    id: 'c3',
    ocrStem: '',
    answer: '跳过题答案不应出现',
    explanation: '跳过题解析不应出现',
  );
  for (final id in ['c1', 'c2', 'c3']) {
    source.slices[id] = makePng(800, 200);
  }
  return source;
}

void main() {
  group('版本模型', () {
    test('默认只勾练习版，答案版须另外勾选', () {
      expect(ExportVersion.practice.defaultSelected, isTrue);
      expect(ExportVersion.answer.defaultSelected, isFalse);
      const selection = ExportVersionSelection.practiceOnly();
      expect(selection.practice, isTrue);
      expect(selection.answer, isFalse);
      expect(selection.hasAny, isTrue);
      expect(selection.selected, [ExportVersion.practice]);
    });

    test('两版都选时按练习版、答案版顺序', () {
      const selection = ExportVersionSelection.both();
      expect(selection.selected, [
        ExportVersion.practice,
        ExportVersion.answer,
      ]);
    });

    test('一个都不选时 hasAny 为 false', () {
      const selection = ExportVersionSelection(
        practice: false,
        answer: false,
      );
      expect(selection.hasAny, isFalse);
      expect(selection.selected, isEmpty);
    });

    test('文件名后缀与区别说明', () {
      expect(ExportVersion.practice.fileSuffix, '');
      expect(ExportVersion.answer.fileSuffix, '_答案');
      expect(ExportVersion.practice.label, '练习版');
      expect(ExportVersion.answer.label, '答案版');
      expect(ExportVersion.practice.difference, contains('不含答案'));
      expect(ExportVersion.answer.difference, contains('全部题目之后'));
    });
  });

  group('答案/解析分别判空', () {
    test('空字符串与纯空白视为未录入', () {
      expect(isAnswerRecorded(null), isFalse);
      expect(isAnswerRecorded(''), isFalse);
      expect(isAnswerRecorded('   '), isFalse);
      expect(isAnswerRecorded('\n\t '), isFalse);
      expect(isAnswerRecorded('A'), isTrue);
      expect(isAnswerRecorded('  B  '), isTrue);
    });

    test('answerPendingRecheck 置位期间旧值无效', () {
      expect(
        isAnswerRecorded('A', pendingRecheck: true),
        isFalse,
      );
      expect(
        recordedOrPlaceholder(
          'A',
          placeholder: kAnswerNotRecordedText,
          pendingRecheck: true,
        ),
        kAnswerNotRecordedText,
      );
    });

    test('未录入印占位文案，已录入印原文', () {
      expect(
        recordedOrPlaceholder(null, placeholder: kAnswerNotRecordedText),
        kAnswerNotRecordedText,
      );
      expect(
        recordedOrPlaceholder(
          '  ',
          placeholder: kExplanationNotRecordedText,
        ),
        kExplanationNotRecordedText,
      );
      expect(
        recordedOrPlaceholder('C', placeholder: kAnswerNotRecordedText),
        'C',
      );
    });

    test('含 \$...\$ 的文本默认纯文本，不静默解析', () {
      const raw = r'答案是 $x^2$ 形式';
      expect(
        recordedOrPlaceholder(raw, placeholder: kAnswerNotRecordedText),
        raw,
      );
      final entries = buildAnswerEntries(
        displayNumbersById: {'q1': 1},
        sources: [
          const AnswerSourceData(questionId: 'q1', answer: raw),
        ],
      );
      expect(entries.single.answerDisplay, raw);
    });

    test('答案区条目只含已印出的题，按题号排序', () {
      final entries = buildAnswerEntries(
        displayNumbersById: {'q2': 2, 'q1': 1},
        sources: [
          const AnswerSourceData(questionId: 'q1', answer: 'A'),
          const AnswerSourceData(questionId: 'q2', answer: 'B'),
          // q3 不在题号表里（跳过题），不列入。
          const AnswerSourceData(questionId: 'q3', answer: 'C'),
        ],
      );
      expect(
        entries.map((e) => e.questionId).toList(),
        ['q1', 'q2'],
      );
      expect(entries.map((e) => e.displayNumber).toList(), [1, 2]);
    });
  });

  group('双版生成端到端', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('b15-m2-versions-');
    });

    tearDown(() async {
      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('A 路线：两版题号一一对应，答案版含答案区、练习版不含', () async {
      final service = PdfExportService(
        source: _aSource(),
        hasApiKey: () async => false,
        fontBytesLoader: _fontBytes,
        tempRoot: tempRoot,
      );
      final result = await service.generateVersions(
        ids: ['q1', 'q2', 'q3', 'q4'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
        versions: const ExportVersionSelection.both(),
      );
      expect(result.route, ExportRoute.a);
      expect(result.allSucceeded, isTrue);
      final practice = result.practice!.result!;
      final answer = result.answer!.result!;
      expect(practice.variant, ExportVersion.practice);
      expect(answer.variant, ExportVersion.answer);
      // 题号序列相等（同一快照生成）。
      expect(
        answer.questionPages.map((q) => q.displayNumber).toList(),
        practice.questionPages.map((q) => q.displayNumber).toList(),
      );
      expect(
        answer.questionPages.map((q) => q.questionId).toList(),
        practice.questionPages.map((q) => q.questionId).toList(),
      );
      // BROKEN 占位题 q4 有题号、两版都在。
      expect(
        practice.questionPages.map((q) => q.questionId),
        contains('q4'),
      );
      // 答案版比练习版多答案区页数；页数与实际字节一致。
      expect(answer.totalPages, greaterThan(practice.totalPages));
      expect(countPdfPages(answer.pdfBytes), answer.totalPages);
      expect(countPdfPages(practice.pdfBytes), practice.totalPages);
      // 报告两版共用：答案已录入 2/4（q1、q4），解析已录入 2/4（q1、q2）。
      expect(result.report.answersRecorded, 2);
      expect(result.report.explanationsRecorded, 2);

      final practiceText = await _pdfText(
        practice.pdfBytes,
        tempRoot,
        'practice.pdf',
      );
      final answerText = await _pdfText(
        answer.pdfBytes,
        tempRoot,
        'answer.pdf',
      );
      if (practiceText == null || answerText == null) {
        markTestSkipped('pdftotext 不可用，跳过文本断言');
        return;
      }
      // 练习版无答案区、无占位文案。
      expect(practiceText, isNot(contains(kAnswerSectionTitle)));
      expect(practiceText, isNot(contains(kAnswerNotRecordedText)));
      expect(practiceText, isNot(contains(kExplanationNotRecordedText)));
      // 答案版有答案区标题；占位各出现 2 次（答案：q2 空白、q3 空；
      // 解析：q3 空、q4 空）。
      expect(answerText, contains(kAnswerSectionTitle));
      expect(_countOccurrences(answerText, kAnswerNotRecordedText), 2);
      expect(_countOccurrences(answerText, kExplanationNotRecordedText), 2);
      expect(answerText, contains('答案：A'));
      expect(answerText, contains('解析：解析一'));
      expect(answerText, contains('解析：解析二'));
      // 两版题号行一致（答案区题号与题目区题号对应）：去空白后比对，
      // 避开 pdftotext 对窄空格的抽取差异（抽出为“第1题”）。
      final squashedAnswer = answerText.replaceAll(RegExp(r'\s+'), '');
      expect(squashedAnswer, contains('第1题'));
      expect(squashedAnswer, contains('第4题'));
      expect(_leftoverExportDirs(tempRoot), isEmpty);
    });

    test('C 路线：跳过题两版都不印，答案区也不列', () async {
      // C 路线分页规划用 TextPainter/字体加载，须先初始化 binding
      //（M1-E 的 C 测试同款做法，见 testWidgets）。
      TestWidgetsFlutterBinding.ensureInitialized();
      final service = PdfExportService(
        source: _cSource(),
        hasApiKey: () async => true,
        fontBytesLoader: _fontBytes,
        tempRoot: tempRoot,
      );
      final result = await service.generateVersions(
        ids: ['c1', 'c2', 'c3'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
        versions: const ExportVersionSelection.both(),
      );
      expect(result.route, ExportRoute.c);
      expect(result.allSucceeded, isTrue);
      final practice = result.practice!.result!;
      final answer = result.answer!.result!;
      expect(
        practice.questionPages.map((q) => q.questionId).toList(),
        ['c1', 'c2'],
      );
      expect(
        answer.questionPages.map((q) => q.displayNumber).toList(),
        practice.questionPages.map((q) => q.displayNumber).toList(),
      );
      expect(answer.totalPages, greaterThan(practice.totalPages));
      expect(countPdfPages(answer.pdfBytes), answer.totalPages);
      // 跳过题计入报告（SKIPPED 1 道）。
      expect(result.report.skippedCount, 1);

      final answerText = await _pdfText(
        answer.pdfBytes,
        tempRoot,
        'answer-c.pdf',
      );
      if (answerText == null) {
        markTestSkipped('pdftotext 不可用，跳过文本断言');
        return;
      }
      expect(answerText, contains(kAnswerSectionTitle));
      expect(answerText, contains('答案：B'));
      expect(answerText, contains('解析：解析乙'));
      expect(answerText, contains(kAnswerNotRecordedText));
      // 跳过题的答案/解析不得出现在答案版。
      expect(answerText, isNot(contains('跳过题答案不应出现')));
      expect(answerText, isNot(contains('跳过题解析不应出现')));
      expect(_leftoverExportDirs(tempRoot), isEmpty);
    });

    test('只选练习版时答案版结果为 null', () async {
      final service = PdfExportService(
        source: _aSource(),
        hasApiKey: () async => false,
        fontBytesLoader: _fontBytes,
        tempRoot: tempRoot,
      );
      final result = await service.generateVersions(
        ids: ['q1', 'q2'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
      );
      expect(result.practice!.succeeded, isTrue);
      expect(result.answer, isNull);
      expect(result.allSucceeded, isTrue);
    });

    test('一个都不选时抛错', () async {
      final service = PdfExportService(
        source: _aSource(),
        hasApiKey: () async => false,
        fontBytesLoader: _fontBytes,
        tempRoot: tempRoot,
      );
      await expectLater(
        service.generateVersions(
          ids: ['q1'],
          excluded: const [],
          filterText: '全部',
          sortText: '默认',
          versions: const ExportVersionSelection(
            practice: false,
            answer: false,
          ),
        ),
        throwsArgumentError,
      );
    });

    test('generate 单版答案版：variant 与页脚分母正确', () async {
      final service = PdfExportService(
        source: _aSource(),
        hasApiKey: () async => false,
        fontBytesLoader: _fontBytes,
        tempRoot: tempRoot,
      );
      final result = await service.generate(
        ids: ['q1', 'q2'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
        variant: ExportVersion.answer,
      );
      expect(result.variant, ExportVersion.answer);
      expect(countPdfPages(result.pdfBytes), result.totalPages);
      final text = await _pdfText(result.pdfBytes, tempRoot, 'single.pdf');
      if (text == null) {
        markTestSkipped('pdftotext 不可用，跳过文本断言');
        return;
      }
      expect(text, contains(kAnswerSectionTitle));
      // 页脚分母为总页数（含答案区页）：去空白后比对，避开
      // pdftotext 排版空格差异。
      final squashed = text.replaceAll(RegExp(r'\s+'), '');
      expect(squashed, contains('第1/${result.totalPages}页'));
      expect(
        squashed,
        contains('第${result.totalPages}/${result.totalPages}页'),
      );
    });

    test('双文件部分成功：第二版生成失败时第一版保留、逐版列状态', () async {
      var fontCalls = 0;
      Future<Uint8List> countingFont() async {
        fontCalls++;
        if (fontCalls >= 2) {
          throw StateError('注入：字体加载失败');
        }
        return _fontBytes();
      }

      final service = PdfExportService(
        source: _aSource(),
        hasApiKey: () async => false,
        fontBytesLoader: countingFont,
        tempRoot: tempRoot,
      );
      final result = await service.generateVersions(
        ids: ['q1', 'q2'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
        versions: const ExportVersionSelection.both(),
      );
      // 练习版成功（已验证的字节完整），答案版失败（原因明确）。
      expect(result.practice!.succeeded, isTrue);
      expect(result.practice!.result, isNotNull);
      expect(
        countPdfPages(result.practice!.result!.pdfBytes),
        result.practice!.result!.totalPages,
      );
      expect(result.answer!.succeeded, isFalse);
      expect(result.answer!.result, isNull);
      expect(result.answer!.error, isNotNull);
      expect(result.answer!.error, isNotEmpty);
      // 部分成功不得伪装成全部成功；至少一版成功。
      expect(result.allSucceeded, isFalse);
      expect(result.anySucceeded, isTrue);
      // 两版仍用同一份快照（题号序列以练习版为准，无错位可言）；
      // 快照临时目录已清理，无半成品。
      expect(_leftoverExportDirs(tempRoot), isEmpty);
    });

    test('key 状态读错时整单失败，不产生逐版结果', () async {
      final service = PdfExportService(
        source: _aSource(),
        hasApiKey: () async => throw StateError('注入：读 key 失败'),
        fontBytesLoader: _fontBytes,
        tempRoot: tempRoot,
      );
      await expectLater(
        service.generateVersions(
          ids: ['q1'],
          excluded: const [],
          filterText: '全部',
          sortText: '默认',
          versions: const ExportVersionSelection.both(),
        ),
        throwsA(isA<RouteResolutionException>()),
      );
      expect(_leftoverExportDirs(tempRoot), isEmpty);
    });

    test('同一快照两次生成（generateFromSnapshot）：题号与页数一致', () async {
      final source = _aSource();
      final service = PdfExportService(
        source: source,
        hasApiKey: () async => false,
        fontBytesLoader: _fontBytes,
        tempRoot: tempRoot,
      );
      final snapshot = await ExportSnapshot.fromSelection(
        ids: ['q1', 'q2', 'q3'],
        excluded: const [],
        route: ExportRoute.a,
        filterText: '全部',
        sortText: '默认',
        source: source,
        tempRoot: tempRoot,
      );
      try {
        final practice = await service.generateFromSnapshot(
          snapshot: snapshot,
        );
        final answer = await service.generateFromSnapshot(
          snapshot: snapshot,
          variant: ExportVersion.answer,
        );
        expect(
          answer.questionPages.map((q) => q.displayNumber).toList(),
          practice.questionPages.map((q) => q.displayNumber).toList(),
        );
        expect(answer.totalPages, greaterThan(practice.totalPages));
      } finally {
        await snapshot.dispose();
      }
      expect(_leftoverExportDirs(tempRoot), isEmpty);
    });
  });
}
