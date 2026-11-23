// 十五批 M3：导出流程控制器（PLAN-15-REV3 §6 M3-2；P1-5 部分成功语义）。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/services/pdf_export/content_guard.dart';
import 'package:quiz_master2/services/pdf_export/export_flow.dart';
import 'package:quiz_master2/services/pdf_export/export_integrity.dart';
import 'package:quiz_master2/services/pdf_export/export_inventory.dart';
import 'package:quiz_master2/services/pdf_export/export_route.dart';
import 'package:quiz_master2/services/pdf_export/export_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/export_versions.dart';
import 'package:quiz_master2/services/pdf_export/pdf_delivery.dart';
import 'package:quiz_master2/services/pdf_export/pdf_export_service.dart';

ExportInventory fakeInventory({
  ExportRoute route = ExportRoute.a,
  int circledCount = 2,
  int selectedCount = 2,
  int printableCount = 2,
  int skippedCount = 0,
  List<SkipEntry> skipped = const [],
  List<LowDpiEntry> lowDpi = const [],
  ContentGuardResult? guard,
}) => ExportInventory(
  route: route,
  routeReason: route == ExportRoute.c ? '已配置 OCR key' : '未配置 OCR key',
  circledCount: circledCount,
  selectedCount: selectedCount,
  excluded: const [],
  printableCount: printableCount,
  skippedCount: skippedCount,
  skipped: skipped,
  suspicious: const [],
  lowDpi: lowDpi,
  guard: guard ?? ContentGuard.evaluate(const [], isEstimate: true),
);

IntegrityReport fakeReport({ExportRoute route = ExportRoute.a}) =>
    IntegrityReport(
      route: route,
      selectedCount: 2,
      snapshotCount: 2,
      excludedCount: 0,
      entries: const [
        IntegrityEntry(
          questionId: 'q1',
          title: '题 q1',
          status: IntegrityStatus.complete,
          warnings: [],
        ),
        IntegrityEntry(
          questionId: 'q2',
          title: '题 q2',
          status: IntegrityStatus.partial,
          warnings: ['增强失败，已用原图'],
        ),
      ],
      answersRecorded: 1,
      answersTotal: 2,
      explanationsRecorded: 0,
      explanationsTotal: 2,
    );

PdfExportResult fakePdfResult({
  ExportVersion variant = ExportVersion.practice,
  int totalPages = 3,
}) => PdfExportResult(
  pdfBytes: Uint8List.fromList(const [37, 80, 68, 70]),
  report: fakeReport(),
  route: ExportRoute.a,
  totalPages: totalPages,
  questionPages: const [],
  estimatedGuard: ContentGuard.evaluate(const [], isEstimate: true),
  actualGuard: ContentGuard.evaluate(const [], isEstimate: false),
  guardDeviation: const GuardDeviation(estimatedMpx: 0, actualMpx: 0),
  variant: variant,
);

TwoVersionExportResult fakeTwoVersion({
  bool answerSucceeds = true,
  bool practiceSucceeds = true,
}) => TwoVersionExportResult(
  practice: practiceSucceeds
      ? VersionExportOutcome.success(fakePdfResult())
      : const VersionExportOutcome.failure('练习版生成失败'),
  answer: answerSucceeds
      ? VersionExportOutcome.success(
          fakePdfResult(variant: ExportVersion.answer, totalPages: 5),
        )
      : const VersionExportOutcome.failure('答案版生成失败'),
  route: ExportRoute.a,
  report: fakeReport(),
);

ExportFlowController fakeController({
  ExportInventory? inventory,
  TwoVersionExportResult? twoVersion,
  Object? generateError,
  Future<List<FileDeliveryResult>> Function({
    required List<VersionDeliveryRequest> requests,
  })?
  deliver,
  void Function(List<String> ids)? onStartIds,
  PdfDeliveryPlatform? platformOverride,
}) {
  return ExportFlowController(
    computeInventory:
        ({
          required List<String> ids,
          required List<ExcludedQuestion> excluded,
          required int circledCount,
        }) async {
          if (inventory == null) throw StateError('盘点失败');
          return inventory;
        },
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
          onStartIds?.call(ids);
          onProgress?.call(1, ids.length, '正在准备题目…');
          onProgress?.call(ids.length, ids.length, '正在生成 PDF…');
          if (generateError != null) throw generateError;
          // 取消路径：等待取消信号再抛取消（模拟长生成）。
          if (twoVersion == null) {
            await token.whenCancelled;
            throw const ExportCancelledException();
          }
          return twoVersion;
        },
    deliverAll:
        deliver ??
        ({
          required List<VersionDeliveryRequest> requests,
        }) async => [
          for (final r in requests)
            FileDeliveryResult(
              status: FileDeliveryStatus.delivered,
              version: r.version,
              fileName: r.fileName,
              filePath: '/tmp/${r.fileName}',
              pageCount: r.expectedPages,
            ),
        ],
    platformOverride: platformOverride,
  );
}

void main() {
  group('ExportFlowController.prepare', () {
    test('盘点成功：存 inventory，阶段 preparing', () async {
      final c = fakeController(inventory: fakeInventory());
      await c.prepare(ids: const ['q1', 'q2'], excluded: const [], circledCount: 2);
      expect(c.inventory, isNotNull);
      expect(c.phase, ExportFlowPhase.preparing);
      expect(c.error, isNull);
    });

    test('盘点失败：阶段 failed + 原因', () async {
      final c = fakeController();
      await c.prepare(ids: const ['q1'], excluded: const [], circledCount: 1);
      expect(c.phase, ExportFlowPhase.failed);
      expect(c.error, isNotNull);
    });
  });

  group('ExportFlowController.start', () {
    test('两版都成功：done，逐份交付，进度按题推进', () async {
      final seenProgress = <(int, int, String)>[];
      final c = ExportFlowController(
        computeInventory:
            ({
              required List<String> ids,
              required List<ExcludedQuestion> excluded,
              required int circledCount,
            }) async => fakeInventory(),
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
              onProgress?.call(1, 2, '正在准备题目…');
              onProgress?.call(2, 2, '正在生成 PDF…');
              return fakeTwoVersion();
            },
        deliverAll:
            ({required List<VersionDeliveryRequest> requests}) async => [
              for (final r in requests)
                FileDeliveryResult(
                  status: FileDeliveryStatus.delivered,
                  version: r.version,
                  fileName: r.fileName,
                  filePath: '/tmp/${r.fileName}',
                  pageCount: r.expectedPages,
                ),
            ],
      );
      c.addListener(() {
        seenProgress.add((c.progressDone, c.progressTotal, c.progressLabel));
      });
      await c.start(
        ids: const ['q1', 'q2'],
        excluded: const [],
        filterText: '全部题目',
        sortText: '时间新→旧',
        versions: const ExportVersionSelection.both(),
        circledCount: 2,
        fileNameFor: (v) => '错题本_多学科_20261121${v.fileSuffix}.pdf',
      );
      expect(c.phase, ExportFlowPhase.done);
      expect(c.deliveryResults, hasLength(2));
      expect(c.completionRows, hasLength(2));
      expect(c.completionRows.every((r) => r.isDelivered), isTrue);
      expect(c.progressDone, 2);
      expect(c.progressTotal, 2);
      expect(seenProgress.any((p) => p.$3 == '正在准备题目…'), isTrue);
      // 报告摘要：A 路线行 + 答案/解析已录入行。
      expect(
        c.reportSummaryLines.any((l) => l.contains('图片增强路线')),
        isTrue,
      );
      expect(
        c.reportSummaryLines.any((l) => l.contains('答案已录入 1 / 2 道')),
        isTrue,
      );
    });

    test('start 重入保护：generating 中第二次 start 直接返回，不重复生成（P2-02）', () async {
      final gate = Completer<TwoVersionExportResult>();
      var generateCalls = 0;
      final c = ExportFlowController(
        computeInventory:
            ({
              required List<String> ids,
              required List<ExcludedQuestion> excluded,
              required int circledCount,
            }) async => fakeInventory(),
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
              generateCalls++;
              return gate.future;
            },
        deliverAll:
            ({required List<VersionDeliveryRequest> requests}) async => [
              for (final r in requests)
                FileDeliveryResult(
                  status: FileDeliveryStatus.delivered,
                  version: r.version,
                  fileName: r.fileName,
                  filePath: '/tmp/${r.fileName}',
                  pageCount: r.expectedPages,
                ),
            ],
      );

      final first = c.start(
        ids: const ['q1', 'q2'],
        excluded: const [],
        filterText: '全部题目',
        sortText: '时间新→旧',
        versions: const ExportVersionSelection.both(),
        circledCount: 2,
        fileNameFor: (v) => '错题本_多学科_20261121${v.fileSuffix}.pdf',
      );
      expect(c.phase, ExportFlowPhase.generating);
      final second = c.start(
        ids: const ['q1', 'q2'],
        excluded: const [],
        filterText: '全部题目',
        sortText: '时间新→旧',
        versions: const ExportVersionSelection.both(),
        circledCount: 2,
        fileNameFor: (v) => '错题本_多学科_20261121${v.fileSuffix}.pdf',
      );
      await Future<void>.delayed(Duration.zero);
      expect(generateCalls, 1);

      gate.complete(fakeTwoVersion());
      await Future.wait([first, second]);
      expect(c.phase, ExportFlowPhase.done);
      expect(generateCalls, 1);
    });

    test('部分成功：答案版生成失败时练习版保留，逐份列出状态', () async {
      final c = fakeController(
        inventory: fakeInventory(),
        twoVersion: fakeTwoVersion(answerSucceeds: false),
      );
      await c.start(
        ids: const ['q1', 'q2'],
        excluded: const [],
        filterText: '全部题目',
        sortText: '时间新→旧',
        versions: const ExportVersionSelection.both(),
        circledCount: 2,
        fileNameFor: (v) => '错题本_多学科_20261121${v.fileSuffix}.pdf',
      );
      expect(c.phase, ExportFlowPhase.done);
      final rows = c.completionRows;
      expect(rows, hasLength(2));
      expect(rows[0].isDelivered, isTrue);
      expect(rows[1].generationFailed, isTrue);
      expect(rows[1].generationError, '答案版生成失败');
      expect(c.versionsResult?.allSucceeded, isFalse);
      expect(c.versionsResult?.anySucceeded, isTrue);
    });

    test('整单失败（guard 硬拒绝）：failed + 原因，不产生交付', () async {
      final c = fakeController(
        inventory: fakeInventory(),
        generateError: ExportGuardRejectException(
          '本次导出内容过重，已停止生成。',
          ContentGuard.evaluate(const [], isEstimate: true),
        ),
      );
      await c.start(
        ids: const ['q1', 'q2'],
        excluded: const [],
        filterText: '全部题目',
        sortText: '时间新→旧',
        versions: const ExportVersionSelection.practiceOnly(),
        circledCount: 2,
        fileNameFor: (v) => 'x.pdf',
      );
      expect(c.phase, ExportFlowPhase.failed);
      expect(c.error, contains('内容过重'));
      expect(c.deliveryResults, isNull);
    });

    test('51 道阻断：确认前断言，不调生成', () async {
      var called = false;
      final c = fakeController(
        inventory: fakeInventory(),
        twoVersion: fakeTwoVersion(),
        onStartIds: (_) => called = true,
      );
      await c.start(
        ids: List.generate(51, (i) => 'q$i'),
        excluded: const [],
        filterText: '全部题目',
        sortText: '时间新→旧',
        versions: const ExportVersionSelection.practiceOnly(),
        circledCount: 60,
        fileNameFor: (v) => 'x.pdf',
      );
      expect(c.phase, ExportFlowPhase.failed);
      expect(c.error, '单次最多导出 50 道题');
      expect(called, isFalse);
    });

    test('取消：阶段 cancelled，不留交付结果', () async {
      final c = fakeController(inventory: fakeInventory(), twoVersion: null);
      final started = c.start(
        ids: const ['q1', 'q2'],
        excluded: const [],
        filterText: '全部题目',
        sortText: '时间新→旧',
        versions: const ExportVersionSelection.practiceOnly(),
        circledCount: 2,
        fileNameFor: (v) => 'x.pdf',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      c.cancel();
      await started;
      expect(c.phase, ExportFlowPhase.cancelled);
      expect(c.deliveryResults, isNull);
    });

    test('Android 只出分享：supportsOpen 为 false', () {
      final c = fakeController(
        inventory: fakeInventory(),
        twoVersion: fakeTwoVersion(),
        platformOverride: PdfDeliveryPlatform.android,
      );
      expect(c.isAndroid, isTrue);
      expect(c.supportsOpen, isFalse);
    });

    test('桌面端支持打开：supportsOpen 为 true', () {
      final c = fakeController(
        inventory: fakeInventory(),
        twoVersion: fakeTwoVersion(),
        platformOverride: PdfDeliveryPlatform.windows,
      );
      expect(c.isAndroid, isFalse);
      expect(c.supportsOpen, isTrue);
    });
  });
}
