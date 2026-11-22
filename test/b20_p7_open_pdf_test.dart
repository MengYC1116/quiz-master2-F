// 二十批 P7（十五批 #31）：Android 完成界面独立「打开 PDF」按钮
//（open_filex 方式）。
//
// 覆盖：
// - PdfDeliveryService.openPdf / openPdfWithResult 的 Android 分支
//   （注入 fake open_filex 通道，不真调系统打开；本机 Linux 测不了
//   Android 真机打开行为，真机验证见 STATUS.md 的复核项）；
// - ExportFlowController.supportsAndroidOpenPdf 与
//   openDeliveredPdf（详细结果 / 未接入时的 bool 回退）；
// - 完成界面按钮出现条件：PDF 行已交付时 Android 出「分享」+
//   「打开 PDF」；Word 行不出现；未交付行不出现；整单失败 / 取消
//   时不出现；桌面端不变（「打开文件 / 打开所在文件夹」，无
//   「打开 PDF」）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_filex/open_filex.dart';
import 'package:quiz_master2/modules/wrongbook/export_confirm.dart';
import 'package:quiz_master2/services/pdf_export/content_guard.dart';
import 'package:quiz_master2/services/pdf_export/export_flow.dart';
import 'package:quiz_master2/services/pdf_export/export_integrity.dart';
import 'package:quiz_master2/services/pdf_export/export_route.dart';
import 'package:quiz_master2/services/pdf_export/export_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/export_versions.dart';
import 'package:quiz_master2/services/pdf_export/pdf_delivery.dart';
import 'package:quiz_master2/services/pdf_export/pdf_export_service.dart';
import 'package:quiz_master2/services/word_export/word_export_service.dart';

IntegrityReport _report() => IntegrityReport(
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
  answersRecorded: 1,
  answersTotal: 1,
  explanationsRecorded: 0,
  explanationsTotal: 1,
);

PdfExportResult _pdfResult() => PdfExportResult(
  pdfBytes: Uint8List.fromList(const [37, 80, 68, 70]),
  report: _report(),
  route: ExportRoute.a,
  totalPages: 3,
  questionPages: const [],
  estimatedGuard: ContentGuard.evaluate(const [], isEstimate: true),
  actualGuard: ContentGuard.evaluate(const [], isEstimate: false),
  guardDeviation: const GuardDeviation(estimatedMpx: 0, actualMpx: 0),
  variant: ExportVersion.practice,
);

TwoVersionExportResult _twoVersion({
  bool answerSucceeds = true,
  bool includeAnswer = true,
}) => TwoVersionExportResult(
  practice: VersionExportOutcome.success(_pdfResult()),
  answer: includeAnswer
      ? (answerSucceeds
            ? VersionExportOutcome.success(_pdfResult())
            : const VersionExportOutcome.failure('答案版生成失败'))
      : null,
  route: ExportRoute.a,
  report: _report(),
);

/// 完成界面测试用控制器（生成 / 交付 / 打开全部可注入桩）。
ExportFlowController _p7Controller({
  TwoVersionExportResult? twoVersion,
  Object? generateError,
  PdfDeliveryPlatform? platformOverride,
  Future<OpenPdfResult?> Function(String path)? openPdfDetailed,
  Future<bool> Function(String path)? openFile,
  List<String>? openedPaths,
}) {
  return ExportFlowController(
    computeInventory: ({
      required List<String> ids,
      required List<ExcludedQuestion> excluded,
      required int circledCount,
    }) async => throw UnimplementedError(),
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
          if (generateError != null) throw generateError;
          // 默认只给练习版结果（与 practiceOnly 选择一致）：若两版
          // 结果都给、只选练习版，答案版行无交付 → 完成界面会判
          // 部分成功，不是“全部完成”。
          return twoVersion ?? _twoVersion(includeAnswer: false);
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
        }) async => WordExportResult(
          docxBytes: Uint8List.fromList(const [80, 75, 3, 4]),
          report: _report(),
          route: ExportRoute.a,
          estimatedGuard: ContentGuard.evaluate(const [], isEstimate: true),
          actualGuard: ContentGuard.evaluate(const [], isEstimate: false),
          guardDeviation: const GuardDeviation(
            estimatedMpx: 0,
            actualMpx: 0,
          ),
          imageCount: 0,
          estimatedPageCount: 2,
        ),
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
    openFile:
        openFile ??
        (openedPaths == null
            ? (_) async => true
            : (path) async {
                openedPaths.add(path);
                return true;
              }),
    openFolder: (_) async => true,
    openPdfDetailed: openPdfDetailed,
    shareFile: (_) async =>
        const ShareResult(outcome: ShareOutcome.shared),
    platformOverride: platformOverride,
  );
}

/// 把控制器跑到终态（PDF 流程，练习版单版）。
Future<ExportFlowController> _runPdfDone({
  TwoVersionExportResult? twoVersion,
  Object? generateError,
  PdfDeliveryPlatform? platformOverride,
  Future<OpenPdfResult?> Function(String path)? openPdfDetailed,
  List<String>? openedPaths,
}) async {
  final c = _p7Controller(
    twoVersion: twoVersion,
    generateError: generateError,
    platformOverride: platformOverride,
    openPdfDetailed: openPdfDetailed,
    openedPaths: openedPaths,
  );
  await c.start(
    ids: const ['q0'],
    excluded: const [],
    filterText: '全部题目',
    sortText: '时间新→旧',
    versions: const ExportVersionSelection.practiceOnly(),
    circledCount: 1,
    fileNameFor: (v) => 'x.pdf',
  );
  return c;
}

/// 把控制器跑到终态（Word 流程）。
Future<ExportFlowController> _runWordDone({
  PdfDeliveryPlatform? platformOverride,
}) async {
  final c = _p7Controller(platformOverride: platformOverride);
  await c.start(
    ids: const ['q0'],
    excluded: const [],
    filterText: '全部题目',
    sortText: '时间新→旧',
    versions: const ExportVersionSelection.practiceOnly(),
    circledCount: 1,
    fileNameFor: (v) => 'x.docx',
    format: ExportFormat.word,
  );
  return c;
}

Future<void> _pumpCompletion(
  WidgetTester tester,
  ExportFlowController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ExportCompletionView(
            controller: controller,
            onClose: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('openPdf：Android 分支走 open_filex（注入 fake 通道）', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('b20_p7_open_');
    });

    tearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    Future<String> existingPdf() async {
      final target = File('${tempRoot.path}/open.pdf');
      await target.writeAsBytes(const [37, 80, 68, 70]);
      return target.path;
    }

    test('done → true，错误为空', () async {
      final path = await existingPdf();
      final called = <String>[];
      final service = PdfDeliveryService(
        platformOverride: PdfDeliveryPlatform.android,
        openWithFilex: (p) async {
          called.add(p);
          return OpenResult(type: ResultType.done, message: 'done');
        },
      );
      final detailed = await service.openPdfWithResult(path);
      expect(detailed.success, isTrue);
      expect(detailed.error, isNull);
      expect(called, [path]);
      // openPdf 与 openPdfWithResult 各调通道一次：清掉计数再验
      // openPdf，避免两次调用叠加被误判为重复调起。
      called.clear();
      expect(await service.openPdf(path), isTrue);
      expect(called, [path]);
    });

    test('无可打开应用 → false，错误明确说缺阅读器', () async {
      final path = await existingPdf();
      final service = PdfDeliveryService(
        platformOverride: PdfDeliveryPlatform.android,
        openWithFilex: (_) async =>
            OpenResult(type: ResultType.noAppToOpen, message: 'No APP found'),
      );
      final detailed = await service.openPdfWithResult(path);
      expect(detailed.success, isFalse);
      expect(detailed.error, contains('没有可打开 PDF 的应用'));
      expect(await service.openPdf(path), isFalse);
    });

    test('无权限 / 通道报错 / 通道说文件不存在 → 各有明确错误', () async {
      final path = await existingPdf();
      final denied = PdfDeliveryService(
        platformOverride: PdfDeliveryPlatform.android,
        openWithFilex: (_) async => OpenResult(
          type: ResultType.permissionDenied,
          message: 'permission denied',
        ),
      );
      expect(
        (await denied.openPdfWithResult(path)).error,
        contains('权限'),
      );
      final errored = PdfDeliveryService(
        platformOverride: PdfDeliveryPlatform.android,
        openWithFilex: (_) async =>
            OpenResult(type: ResultType.error, message: 'boom'),
      );
      final errorResult = await errored.openPdfWithResult(path);
      expect(errorResult.success, isFalse);
      expect(errorResult.error, contains('boom'));
      final notFound = PdfDeliveryService(
        platformOverride: PdfDeliveryPlatform.android,
        openWithFilex: (_) async => OpenResult(
          type: ResultType.fileNotFound,
          message: 'file not found',
        ),
      );
      expect(
        (await notFound.openPdfWithResult(path)).error,
        contains('不存在'),
      );
    });

    test('通道抛错 → false，不静默吞掉（错误带回）', () async {
      final path = await existingPdf();
      final service = PdfDeliveryService(
        platformOverride: PdfDeliveryPlatform.android,
        openWithFilex: (_) async => throw StateError('channel gone'),
      );
      final detailed = await service.openPdfWithResult(path);
      expect(detailed.success, isFalse);
      expect(detailed.error, contains('打开 PDF 失败'));
    });

    test('文件不存在 → false 且不调通道', () async {
      final called = <String>[];
      final service = PdfDeliveryService(
        platformOverride: PdfDeliveryPlatform.android,
        openWithFilex: (p) async {
          called.add(p);
          return OpenResult(type: ResultType.done, message: 'done');
        },
      );
      final missing = '${tempRoot.path}/no-such.pdf';
      final detailed = await service.openPdfWithResult(missing);
      expect(detailed.success, isFalse);
      expect(detailed.error, contains('不存在'));
      expect(await service.openPdf(missing), isFalse);
      expect(called, isEmpty);
    });

    test('Android 分支不走桌面启动器注入（openFile 桩不被调用）', () async {
      final path = await existingPdf();
      final launcherCalls = <String>[];
      final service = PdfDeliveryService(
        platformOverride: PdfDeliveryPlatform.android,
        openFile: (p) async {
          launcherCalls.add(p);
          return true;
        },
        openWithFilex: (_) async =>
            OpenResult(type: ResultType.done, message: 'done'),
      );
      expect(await service.openPdf(path), isTrue);
      expect(launcherCalls, isEmpty);
    });

    test('桌面端仍走启动器注入，不走 open_filex', () async {
      final path = await existingPdf();
      final filexCalls = <String>[];
      final service = PdfDeliveryService(
        platformOverride: PdfDeliveryPlatform.windows,
        openFile: (_) async => true,
        openWithFilex: (p) async {
          filexCalls.add(p);
          return OpenResult(type: ResultType.done, message: 'done');
        },
      );
      expect(await service.openPdf(path), isTrue);
      expect(filexCalls, isEmpty);
    });
  });

  group('控制器：supportsAndroidOpenPdf 与 openDeliveredPdf', () {
    test('Android 出独立打开按钮开关为 true，桌面端为 false', () {
      final android = _p7Controller(
        platformOverride: PdfDeliveryPlatform.android,
      );
      expect(android.isAndroid, isTrue);
      expect(android.supportsAndroidOpenPdf, isTrue);
      // 桌面端仍只有「打开文件 / 打开所在文件夹」，无独立按钮。
      expect(android.supportsOpen, isFalse);
      final windows = _p7Controller(
        platformOverride: PdfDeliveryPlatform.windows,
      );
      expect(windows.isAndroid, isFalse);
      expect(windows.supportsAndroidOpenPdf, isFalse);
      expect(windows.supportsOpen, isTrue);
    });

    test('openDeliveredPdf：详细回调的成功/失败原样带回', () async {
      final opened = <String>[];
      final c = _p7Controller(
        openPdfDetailed: (path) async {
          opened.add(path);
          return const OpenPdfResult(
            success: false,
            error: '没有可打开 PDF 的应用，请先安装 PDF 阅读器。',
          );
        },
      );
      final result = await c.openDeliveredPdf('/tmp/x.pdf');
      expect(result.success, isFalse);
      expect(result.error, contains('没有可打开 PDF 的应用'));
      expect(opened, ['/tmp/x.pdf']);
      final okController = _p7Controller(
        openPdfDetailed: (_) async => const OpenPdfResult(success: true),
      );
      expect(
        (await okController.openDeliveredPdf('/tmp/x.pdf')).success,
        isTrue,
      );
    });

    test('openDeliveredPdf：未接入详细回调时退回 bool 结果', () async {
      final failing = _p7Controller(openFile: (_) async => false);
      final result = await failing.openDeliveredPdf('/tmp/x.pdf');
      expect(result.success, isFalse);
      expect(result.error, isNotNull);
      final succeeding = _p7Controller(openFile: (_) async => true);
      expect(
        (await succeeding.openDeliveredPdf('/tmp/x.pdf')).success,
        isTrue,
      );
    });
  });

  group('完成界面：按钮出现条件', () {
    testWidgets('Android + PDF 行已交付：出「分享」+「打开 PDF」', (tester) async {
      final opened = <String>[];
      final c = await _runPdfDone(
        platformOverride: PdfDeliveryPlatform.android,
        openPdfDetailed: (path) async {
          opened.add(path);
          return const OpenPdfResult(success: true);
        },
      );
      await _pumpCompletion(tester, c);
      expect(find.text('全部完成'), findsOneWidget);
      expect(find.text('分享'), findsOneWidget);
      expect(find.text('打开 PDF'), findsOneWidget);
      expect(find.text('打开文件'), findsNothing);
      expect(find.text('打开所在文件夹'), findsNothing);
      await tester.tap(find.text('打开 PDF'));
      await tester.pump();
      expect(opened, ['/tmp/x.pdf']);
    });

    testWidgets('Android + 打开失败：SnackBar 显示明确原因', (tester) async {
      final c = await _runPdfDone(
        platformOverride: PdfDeliveryPlatform.android,
        openPdfDetailed: (_) async => const OpenPdfResult(
          success: false,
          error: '没有可打开 PDF 的应用，请先安装 PDF 阅读器。',
        ),
      );
      await _pumpCompletion(tester, c);
      await tester.tap(find.text('打开 PDF'));
      await tester.pump();
      expect(find.text('没有可打开 PDF 的应用，请先安装 PDF 阅读器。'), findsOneWidget);
    });

    testWidgets('Android + Word 行已交付：只出「分享」，不出现「打开 PDF」',
        (tester) async {
      final c = await _runWordDone(
        platformOverride: PdfDeliveryPlatform.android,
      );
      await _pumpCompletion(tester, c);
      expect(find.text('全部完成'), findsOneWidget);
      expect(find.text('分享'), findsOneWidget);
      expect(find.text('打开 PDF'), findsNothing);
    });

    testWidgets('Android + 部分成功：未交付行不出按钮，已交付行出按钮',
        (tester) async {
      final c = await _runPdfDone(
        twoVersion: _twoVersion(answerSucceeds: false),
        platformOverride: PdfDeliveryPlatform.android,
      );
      await _pumpCompletion(tester, c);
      expect(find.text('部分成功：以下文件未完成。'), findsOneWidget);
      // 练习版已交付出一组按钮；答案版生成失败行无 deliveredPath，
      // 按钮只出现一次。
      expect(find.text('分享'), findsOneWidget);
      expect(find.text('打开 PDF'), findsOneWidget);
    });

    testWidgets('整单失败 / 取消：不出现「打开 PDF」', (tester) async {
      final failed = await _runPdfDone(
        generateError: StateError('生成失败'),
        platformOverride: PdfDeliveryPlatform.android,
      );
      await _pumpCompletion(tester, failed);
      expect(find.text('导出失败'), findsOneWidget);
      expect(find.text('打开 PDF'), findsNothing);
      expect(find.text('分享'), findsNothing);

      final cancelling = ExportFlowController(
        computeInventory: ({
          required List<String> ids,
          required List<ExcludedQuestion> excluded,
          required int circledCount,
        }) async => throw UnimplementedError(),
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
              await token.whenCancelled;
              throw const ExportCancelledException();
            },
        deliverAll: ({required List<VersionDeliveryRequest> requests}) async =>
            const [],
        platformOverride: PdfDeliveryPlatform.android,
      );
      final started = cancelling.start(
        ids: const ['q0'],
        excluded: const [],
        filterText: '全部题目',
        sortText: '时间新→旧',
        versions: const ExportVersionSelection.practiceOnly(),
        circledCount: 1,
        fileNameFor: (v) => 'x.pdf',
      );
      // testWidgets 用假时钟：直接 await Future.delayed 永远等不到
      // 真实时间流逝，会挂到 10 分钟超时（b15 的同款写法是普通 test，
      // 走真实时间才没事）。改走 tester.runAsync 用真实延时再取消。
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        cancelling.cancel();
      });
      await started;
      await _pumpCompletion(tester, cancelling);
      expect(find.text('已取消'), findsOneWidget);
      expect(find.text('打开 PDF'), findsNothing);
    });

    testWidgets('桌面端不变：出「打开文件 / 打开所在文件夹」，无「打开 PDF」',
        (tester) async {
      final c = await _runPdfDone(
        platformOverride: PdfDeliveryPlatform.windows,
      );
      await _pumpCompletion(tester, c);
      expect(find.text('全部完成'), findsOneWidget);
      expect(find.text('打开文件'), findsOneWidget);
      expect(find.text('打开所在文件夹'), findsOneWidget);
      expect(find.text('打开 PDF'), findsNothing);
      expect(find.text('分享'), findsNothing);
    });
  });
}
