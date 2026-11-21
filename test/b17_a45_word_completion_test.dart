// 十七批 A4+A5：Word 完成界面页数估计 + 页码提示（D-207/D-208）。
//
// A4：Word 完成行显示估计页数「约 N 页（估计值）」，实测页数仍未知
// （pageCount 保持 null，原有「页数以 Word 打开为准」保留）；
// A5：Word 已交付时提示「在 Word 里按 Ctrl+A 再按 F9 更新页码」
// （只在 Word 行出现，PDF 行不出现；未交付时不出现）。
//
// 本文件为本包新增测试；b16 测试文件由并行包在改，不碰。
import 'dart:io';
import 'dart:typed_data';

import 'package:docx_creator/docx_creator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/modules/wrongbook/export_confirm.dart';
import 'package:quiz_master2/services/pdf_export/content_guard.dart';
import 'package:quiz_master2/services/pdf_export/export_flow.dart';
import 'package:quiz_master2/services/pdf_export/export_integrity.dart';
import 'package:quiz_master2/services/pdf_export/export_inventory.dart';
import 'package:quiz_master2/services/pdf_export/export_route.dart';
import 'package:quiz_master2/services/pdf_export/export_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/export_versions.dart';
import 'package:quiz_master2/services/pdf_export/pdf_delivery.dart';
import 'package:quiz_master2/services/pdf_export/pdf_export_service.dart';
import 'package:quiz_master2/services/word_export/word_export_service.dart';
import 'package:quiz_master2/services/word_export/word_page_estimate.dart';

import 'b16_word_test_helpers.dart';

ExportInventory a45Inventory() => ExportInventory(
  route: ExportRoute.a,
  routeReason: '未配置 OCR key',
  circledCount: 1,
  selectedCount: 1,
  excluded: const [],
  printableCount: 1,
  skippedCount: 0,
  skipped: const [],
  suspicious: const [],
  lowDpi: const [],
  guard: ContentGuard.evaluate(const [], isEstimate: true),
);

IntegrityReport a45Report() => IntegrityReport(
  route: ExportRoute.a,
  selectedCount: 1,
  snapshotCount: 1,
  excludedCount: 0,
  entries: const [
    IntegrityEntry(
      questionId: 'q0',
      title: '第 q0 题',
      status: IntegrityStatus.complete,
      warnings: [],
    ),
  ],
  answersRecorded: 0,
  answersTotal: 1,
  explanationsRecorded: 0,
  explanationsTotal: 1,
);

TwoVersionExportResult a45TwoVersion() => TwoVersionExportResult(
  practice: VersionExportOutcome.success(
    PdfExportResult(
      pdfBytes: Uint8List.fromList(const [37, 80, 68, 70]),
      report: a45Report(),
      route: ExportRoute.a,
      totalPages: 3,
      questionPages: const [],
      estimatedGuard: ContentGuard.evaluate(const [], isEstimate: true),
      actualGuard: ContentGuard.evaluate(const [], isEstimate: false),
      guardDeviation: const GuardDeviation(estimatedMpx: 0, actualMpx: 0),
      variant: ExportVersion.practice,
    ),
  ),
  answer: null,
  route: ExportRoute.a,
  report: a45Report(),
);

/// 未带估计页数的 Word 结果（旧构造口径：estimatedPageCount 为 null）。
WordExportResult a45WordResultNoEstimate(Uint8List docxBytes) =>
    WordExportResult(
      docxBytes: docxBytes,
      report: a45Report(),
      route: ExportRoute.a,
      estimatedGuard: ContentGuard.evaluate(const [], isEstimate: true),
      actualGuard: ContentGuard.evaluate(const [], isEstimate: false),
      guardDeviation: const GuardDeviation(estimatedMpx: 0, actualMpx: 0),
      imageCount: 0,
    );

void main() {
  group('估计器纯函数（D-207 口径）', () {
    test('空内容为 1 页', () {
      expect(WordPageEstimator().estimatedPageCount, 1);
    });

    test('字宽模型：46 个汉字一行、47 个汉字两行、空文本 0 行', () {
      expect(estimateWordTextLines('字' * 46, 11), 1);
      expect(estimateWordTextLines('字' * 47, 11), 2);
      expect(estimateWordTextLines('a' * 92, 11), 1);
      expect(estimateWordTextLines('', 11), 0);
    });

    test('长文本跨页：5000 汉字 11pt 约 3 页', () {
      final estimator = WordPageEstimator();
      estimator.addText(text: '字' * 5000, fontSize: 11);
      // 5000 字 × 11pt = 55000pt → 108 行 × 16.5pt = 1782pt →
      // 727.81 × 2 = 1455.62 < 1782 ≤ 2183.43，故 3 页。
      expect(estimator.estimatedPageCount, 3);
    });

    test('原子图放不下整段换页', () {
      final estimator = WordPageEstimator();
      estimator.addSpacer(700);
      estimator.addAtomic(100);
      expect(estimator.estimatedPageCount, 2);
      estimator.addAtomic(700);
      expect(estimator.estimatedPageCount, 3);
    });

    test('分页符在新页开头不产生空白页', () {
      final estimator = WordPageEstimator();
      estimator.addPageBreak();
      expect(estimator.estimatedPageCount, 1);
      estimator.addText(text: '测', fontSize: 11);
      estimator.addPageBreak();
      expect(estimator.estimatedPageCount, 2);
    });

    test('混排段：行内图参与折行与行高', () {
      final estimator = WordPageEstimator();
      estimator.addMixedParagraph([
        const DocxText('测', fontSize: 11),
        DocxInlineImage(
          bytes: Uint8List(0),
          extension: 'png',
          width: 100,
          height: 50,
        ),
      ]);
      // 宽 111pt → 1 行，行高取 max(16.5, 50) = 50pt，仍在 1 页内。
      expect(estimator.estimatedPageCount, 1);
    });
  });

  group('服务：WordExportResult.estimatedPageCount', () {
    late Directory tempRoot;
    late FakeExportQuestionSource source;
    late WordExportResult realWordResult;
    late WordExportResult answerWordResult;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('b17-a45-word-');
      source = FakeExportQuestionSource();
      addChoiceQuestion(source, 'q0');
      final service = makeWordService(source, tempRoot, hasKey: true);
      realWordResult = await generateWord(service, ['q0']);
      answerWordResult = await generateWord(
        service,
        ['q0'],
        versions: const ExportVersionSelection(
          practice: true,
          answer: true,
        ),
      );
    });

    tearDown(() async {
      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('单题 C 路线估计 1 页', () {
      expect(realWordResult.estimatedPageCount, 1);
    });

    test('答案版另起一页，估计 2 页', () {
      expect(answerWordResult.estimatedPageCount, 2);
    });

    test('多题估计随题数增长', () async {
      for (var i = 1; i < 20; i++) {
        addChoiceQuestion(source, 'q$i');
      }
      final service = makeWordService(source, tempRoot, hasKey: true);
      final result = await generateWord(
        service,
        [for (var i = 0; i < 20; i++) 'q$i'],
      );
      expect(result.estimatedPageCount, greaterThan(1));
    });

    test('A 路线单题估计 1 页', () async {
      final service = makeWordService(source, tempRoot, hasKey: false);
      final result = await generateWord(service, ['q0']);
      expect(result.estimatedPageCount, 1);
    });

    test('A 路线长切片估计多页', () async {
      addChoiceQuestion(source, 'qTall', w: 200, h: 1500);
      final service = makeWordService(source, tempRoot, hasKey: false);
      final result = await generateWord(service, ['qTall']);
      // 显示高约 1500/200 × 510.2 ≈ 3826pt，约 6 页（切段按页切分，
      // 估计不低于 5 页即合理）。
      expect(result.estimatedPageCount, greaterThanOrEqualTo(5));
    });
  });

  group('完成界面 widget（A4+A5）', () {
    late Directory tempRoot;
    late FakeExportQuestionSource source;
    late WordExportResult realWordResult;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('b17-a45-flow-');
      source = FakeExportQuestionSource();
      addChoiceQuestion(source, 'q0');
      final service = makeWordService(source, tempRoot, hasKey: true);
      realWordResult = await generateWord(service, ['q0']);
    });

    tearDown(() async {
      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    ExportFlowController flowController({
      WordExportResult? wordResult,
      FileDeliveryResult? wordDelivery,
    }) {
      return ExportFlowController(
        computeInventory:
            ({
              required List<String> ids,
              required List<ExcludedQuestion> excluded,
              required int circledCount,
            }) async => a45Inventory(),
        generateVersions:
            ({
              required List<String> ids,
              required List<ExcludedQuestion> excluded,
              required String filterText,
              required String sortText,
              required ExportVersionSelection versions,
              required int circledCount,
              required ExportCancellationToken token,
              void Function(int done, int total, String label)? onProgress,
              String subjectName = '多学科',
              String? folderName,
              bool excludeLowDpi = false,
            }) async => a45TwoVersion(),
        deliverAll: ({required List<VersionDeliveryRequest> requests}) async => [
          for (final r in requests)
            FileDeliveryResult(
              status: FileDeliveryStatus.delivered,
              version: r.version,
              fileName: r.fileName,
              filePath: '/tmp/${r.fileName}',
              pageCount: r.expectedPages,
            ),
        ],
        generateWord:
            ({
              required List<String> ids,
              required List<ExcludedQuestion> excluded,
              required String filterText,
              required String sortText,
              required ExportVersionSelection versions,
              required int circledCount,
              required ExportCancellationToken token,
              void Function(int done, int total, String label)? onProgress,
              String subjectName = '多学科',
              String? folderName,
              bool excludeLowDpi = false,
            }) async => wordResult ?? realWordResult,
        deliverWord:
            ({
              required Uint8List docxBytes,
              required String fileName,
              required int expectedImageCount,
            }) async =>
                wordDelivery ??
                FileDeliveryResult(
                  status: FileDeliveryStatus.delivered,
                  version: ExportVersion.practice,
                  fileName: fileName,
                  filePath: '/tmp/$fileName',
                ),
      );
    }

    Future<void> startWord(ExportFlowController controller) =>
        controller.start(
          ids: const ['q0'],
          excluded: const [],
          filterText: '全部',
          sortText: '默认排序',
          versions: const ExportVersionSelection.practiceOnly(),
          circledCount: 1,
          fileNameFor: (_) => 'out.docx',
          format: ExportFormat.word,
        );

    Future<void> pumpCompletion(
      WidgetTester tester,
      ExportFlowController controller,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExportCompletionView(
              controller: controller,
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('Word 完成：估计行 + 提示行出现，原有行保留', (tester) async {
      final controller = flowController();
      await startWord(controller);
      expect(controller.phase, ExportFlowPhase.done);
      expect(controller.completionRows.single.pageCount, isNull);
      expect(controller.completionRows.single.estimatedPageCount, 1);

      await pumpCompletion(tester, controller);
      expect(find.text('Word：out.docx'), findsOneWidget);
      expect(
        find.text('共 1 道题 · 页数以 Word 打开为准'),
        findsOneWidget,
      );
      expect(find.text('约 1 页（估计值）'), findsOneWidget);
      expect(
        find.byKey(const Key('export-word-estimated-pages')),
        findsOneWidget,
      );
      expect(
        find.text('在 Word 里按 Ctrl+A 再按 F9 更新页码'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('export-word-refresh-fields-hint')),
        findsOneWidget,
      );
    });

    testWidgets('PDF 完成：无估计行、无提示行，实测页数不变', (tester) async {
      final controller = flowController();
      await controller.start(
        ids: const ['q0'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认排序',
        versions: const ExportVersionSelection.practiceOnly(),
        circledCount: 1,
        fileNameFor: (_) => 'out.pdf',
        format: ExportFormat.pdf,
      );
      expect(controller.phase, ExportFlowPhase.done);
      expect(controller.completionRows.single.pageCount, 3);
      expect(controller.completionRows.single.estimatedPageCount, isNull);

      await pumpCompletion(tester, controller);
      expect(find.text('共 3 页 · 1 道题'), findsOneWidget);
      expect(
        find.byKey(const Key('export-word-estimated-pages')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('export-word-refresh-fields-hint')),
        findsNothing,
      );
      expect(find.textContaining('约'), findsNothing);
    });

    testWidgets('Word 未交付：有估计行、无提示行', (tester) async {
      final controller = flowController(
        wordDelivery: const FileDeliveryResult(
          status: FileDeliveryStatus.cancelled,
          version: ExportVersion.practice,
          fileName: 'out.docx',
        ),
      );
      await startWord(controller);
      expect(controller.phase, ExportFlowPhase.done);
      expect(controller.completionRows.single.isDelivered, isFalse);

      await pumpCompletion(tester, controller);
      expect(find.text('约 1 页（估计值）'), findsOneWidget);
      expect(
        find.byKey(const Key('export-word-refresh-fields-hint')),
        findsNothing,
      );
    });

    testWidgets('估计值缺失：不显示估计行，提示行仍显示', (tester) async {
      final controller = flowController(
        wordResult: a45WordResultNoEstimate(realWordResult.docxBytes),
      );
      await startWord(controller);
      expect(controller.phase, ExportFlowPhase.done);
      expect(controller.completionRows.single.estimatedPageCount, isNull);

      await pumpCompletion(tester, controller);
      expect(
        find.byKey(const Key('export-word-estimated-pages')),
        findsNothing,
      );
      expect(
        find.text('在 Word 里按 Ctrl+A 再按 F9 更新页码'),
        findsOneWidget,
      );
    });
  });
}
