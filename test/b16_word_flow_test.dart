// 十六批 C：流程分发与终态（WORD-DESIGN.md §5，D-194/D-200/D-203）。
//
// 格式可选、PDF/Word 各走各的服务、取消清理、零可印不生成、
// 快照中途被改整单失效、完成界面不编页数、摘要行含文件大小与
// 字体未嵌入提示。
import 'dart:io';
import 'dart:typed_data';

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
import 'package:quiz_master2/services/pdf_export/slice_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/snapshot_exceptions.dart';
import 'package:quiz_master2/services/word_export/word_export_service.dart';

import 'b16_word_test_helpers.dart';

ExportInventory flowInventory() => ExportInventory(
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

IntegrityReport flowReport() => IntegrityReport(
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

TwoVersionExportResult flowTwoVersion() => TwoVersionExportResult(
  practice: VersionExportOutcome.success(
    PdfExportResult(
      pdfBytes: Uint8List.fromList(const [37, 80, 68, 70]),
      report: flowReport(),
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
  report: flowReport(),
);

void main() {
  late Directory tempRoot;
  late FakeExportQuestionSource source;
  late WordExportResult realWordResult;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('b16-word-flow-');
    source = FakeExportQuestionSource();
    addChoiceQuestion(source, 'q0');
    final service = makeWordService(source, tempRoot, hasKey: true);
    realWordResult = await generateWord(service, ['q0']);
    SliceSnapshot.debugOnTempCopied = null;
  });

  tearDown(() async {
    SliceSnapshot.debugOnTempCopied = null;
    if (tempRoot.existsSync()) {
      await tempRoot.delete(recursive: true);
    }
  });

  ExportFlowController flowController({
    required bool Function() onPdfGenerate,
    required bool Function() onWordGenerate,
    WordExportResult? wordResult,
  }) {
    return ExportFlowController(
      computeInventory:
          ({
            required List<String> ids,
            required List<ExcludedQuestion> excluded,
            required int circledCount,
          }) async => flowInventory(),
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
          }) async {
            onPdfGenerate();
            return flowTwoVersion();
          },
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
          }) async {
            onWordGenerate();
            return wordResult ?? realWordResult;
          },
      deliverWord:
          ({
            required Uint8List docxBytes,
            required String fileName,
            required int expectedImageCount,
          }) async => FileDeliveryResult(
            status: FileDeliveryStatus.delivered,
            version: ExportVersion.practice,
            fileName: fileName,
            filePath: '/tmp/$fileName',
          ),
    );
  }

  Future<void> startWord(
    ExportFlowController controller, {
    String Function(ExportVersion version)? fileNameFor,
  }) => controller.start(
    ids: const ['q0'],
    excluded: const [],
    filterText: '全部',
    sortText: '默认排序',
    versions: const ExportVersionSelection.practiceOnly(),
    circledCount: 1,
    fileNameFor: fileNameFor ?? (_) => 'out.docx',
    format: ExportFormat.word,
  );

  group('流程分发与终态（D-194/D-200/D-203）', () {
    test('确认步 Word 可选（availableNow true）', () {
      expect(ExportFormat.word.availableNow, isTrue);
      expect(ExportFormat.pdf.availableNow, isTrue);
    });

    test('格式分发：PDF 走 PDF 服务，Word 走 Word 服务', () async {
      var pdfCalled = false;
      var wordCalled = false;
      final controller = flowController(
        onPdfGenerate: () => pdfCalled = true,
        onWordGenerate: () => wordCalled = true,
      );
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
      expect(pdfCalled, isTrue);
      expect(wordCalled, isFalse);
      expect(controller.wordResult, isNull);
      expect(controller.versionsResult, isNotNull);

      pdfCalled = false;
      wordCalled = false;
      await startWord(controller);
      expect(controller.phase, ExportFlowPhase.done);
      expect(pdfCalled, isFalse);
      expect(wordCalled, isTrue);
      expect(controller.wordResult, isNotNull);
      expect(controller.wordDeliveryResult?.isDelivered, isTrue);
    });

    test('取消：生成中取消 → 整单取消、临时目录已清理、不留文件', () async {
      for (var i = 1; i < 5; i++) {
        addChoiceQuestion(source, 'q$i');
      }
      final service = makeWordService(source, tempRoot, hasKey: true);
      final token = ExportCancellationToken();
      await expectLater(
        service.generateVersions(
          ids: const ['q0', 'q1', 'q2', 'q3', 'q4'],
          excluded: const [],
          filterText: '全部',
          sortText: '默认排序',
          versions: const ExportVersionSelection.practiceOnly(),
          circledCount: 5,
          token: token,
          onProgress: (done, total, label) {
            // 栅格化阶段取消：此时快照已建，取消后须 dispose 整个临时目录。
            if (label.contains('公式')) token.cancel();
          },
        ),
        throwsA(isA<ExportCancelledException>()),
      );
      expect(tempRoot.listSync().whereType<Directory>(), isEmpty);
    });

    test('零可印 → 不生成（ExportNoPrintableException）', () async {
      final service = makeWordService(source, tempRoot, hasKey: true);
      await expectLater(
        () => generateWord(
          service,
          ['q0'],
          excluded: const [ExcludedQuestion(id: 'q0', reason: '用户排除')],
        ),
        throwsA(isA<ExportNoPrintableException>()),
      );
    });

    test('快照中途被改 → 整单失效（D-178，哈希不一致）', () async {
      addChoiceQuestion(source, 'q1');
      SliceSnapshot.debugOnTempCopied = (target) async {
        // 快照复制完成后篡改临时副本：生成时验哈希须整单中止。
        await target.writeAsBytes(
          Uint8List.fromList([...await target.readAsBytes(), 0]),
        );
      };
      final service = makeWordService(source, tempRoot, hasKey: false);
      await expectLater(
        () => generateWord(service, ['q0', 'q1']),
        throwsA(isA<SnapshotIntegrityException>()),
      );
    });

    testWidgets('完成行：无页数、写“以 Word 打开为准”、单行 Word',
        (tester) async {
      final controller = flowController(
        onPdfGenerate: () => false,
        onWordGenerate: () => true,
      );
      await startWord(controller);
      expect(controller.phase, ExportFlowPhase.done);
      final rows = controller.completionRows;
      expect(rows.length, 1);
      expect(rows.single.pageCount, isNull);
      expect(rows.single.labelOverride, 'Word');
      expect(rows.single.isWordCombined, isTrue);
      expect(rows.single.fileSizeBytes, realWordResult.docxBytes.length);

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
      expect(find.text('Word：out.docx'), findsOneWidget);
      expect(
        find.text('共 1 道题 · 页数以 Word 打开为准'),
        findsOneWidget,
      );
      expect(find.textContaining('共 1 页'), findsNothing);
    });

    test('摘要行：文件实际大小 + 字体未嵌入提示', () async {
      final controller = flowController(
        onPdfGenerate: () => false,
        onWordGenerate: () => true,
      );
      await startWord(controller);
      final lines = controller.reportSummaryLines;
      expect(lines.any((l) => l.startsWith('文件大小：')), isTrue);
      expect(lines.any((l) => l.contains('字体未嵌入')), isTrue);
      expect(lines.any((l) => l.contains('页')), isFalse);
    });
  });
}
