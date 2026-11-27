// 十六批 B（D-190）：导出确认步 widget 测试（D-168/D-169 的向导
// 已废，确认步从向导第 3 步抽出为 ExportConfirmDialog，展示口径
// 与生成流程不变；向导第 1/2 步的测试随向导删除，不再保留）。
//
// 确认步盘点加载时有转圈动画，等待盘点完成不用 pumpAndSettle，
// 用有界 pump（既有教训：整页首加载测试不用 pumpAndSettle）。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
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

Question cq(
  String id, {
  String subjectId = 'math',
  List<String> folderIds = const ['f1'],
  String? examId,
  List<String> errorTypes = const [],
  List<String> knowledgePointIds = const [],
}) => Question(
  id: id,
  title: '第 $id 题',
  subjectId: subjectId,
  folderIds: folderIds,
  examId: examId,
  errorTypes: errorTypes,
  knowledgePointIds: knowledgePointIds,
  createdAt: DateTime(2026, 11, 20),
);

ExportConfirmInput confirmInput({int count = 3}) {
  final questions = <Question>[];
  for (var i = 0; i < count; i++) {
    questions.add(
      cq(
        'q$i',
        subjectId: i < 2 ? 'math' : 'english',
        folderIds: i < 2 ? const ['f1'] : const ['f2'],
      ),
    );
  }
  return ExportConfirmInput(
    questions: questions,
    subjects: [Subject.math, Subject.english, Subject.politics],
    folders: const [
      Folder(id: 'f1', name: '试卷', subjectId: 'math'),
      Folder(id: 'f2', name: '作业', subjectId: 'english'),
    ],
    sortText: '时间新→旧',
    filterText: '全部题目',
    subjectName: '多学科',
    circledCount: count,
  );
}

ExportInventory confirmInventory({
  ExportRoute route = ExportRoute.a,
  int selectedCount = 3,
  int printableCount = 3,
  int skippedCount = 0,
  List<SkipEntry> skipped = const [],
  List<SuspiciousEntry> suspicious = const [],
  List<LowDpiEntry> lowDpi = const [],
  ContentGuardResult? guard,
}) => ExportInventory(
  route: route,
  routeReason: route == ExportRoute.c ? '已配置 OCR key' : '未配置 OCR key',
  circledCount: selectedCount,
  selectedCount: selectedCount,
  excluded: const [],
  printableCount: printableCount,
  skippedCount: skippedCount,
  skipped: skipped,
  suspicious: suspicious,
  lowDpi: lowDpi,
  guard: guard ?? ContentGuard.evaluate(const [], isEstimate: true),
);

IntegrityReport confirmReport() => IntegrityReport(
  route: ExportRoute.a,
  selectedCount: 3,
  snapshotCount: 3,
  excludedCount: 0,
  entries: const [
    IntegrityEntry(
      questionId: 'q0',
      title: '第 q0 题',
      status: IntegrityStatus.complete,
      warnings: [],
    ),
    IntegrityEntry(
      questionId: 'q1',
      title: '第 q1 题',
      status: IntegrityStatus.partial,
      warnings: ['增强失败，已用原图'],
    ),
    IntegrityEntry(
      questionId: 'q2',
      title: '第 q2 题',
      status: IntegrityStatus.complete,
      warnings: [],
    ),
  ],
  answersRecorded: 1,
  answersTotal: 3,
  explanationsRecorded: 0,
  explanationsTotal: 3,
);

PdfExportResult confirmPdfResult({ExportVersion variant = ExportVersion.practice}) =>
    PdfExportResult(
      pdfBytes: Uint8List.fromList(const [37, 80, 68, 70]),
      report: confirmReport(),
      route: ExportRoute.a,
      totalPages: variant == ExportVersion.answer ? 5 : 3,
      questionPages: const [],
      estimatedGuard: ContentGuard.evaluate(const [], isEstimate: true),
      actualGuard: ContentGuard.evaluate(const [], isEstimate: false),
      guardDeviation: const GuardDeviation(estimatedMpx: 0, actualMpx: 0),
      variant: variant,
    );

TwoVersionExportResult confirmTwoVersion({bool answerSucceeds = true}) =>
    TwoVersionExportResult(
      practice: VersionExportOutcome.success(confirmPdfResult()),
      answer: answerSucceeds
          ? VersionExportOutcome.success(
              confirmPdfResult(variant: ExportVersion.answer),
            )
          : const VersionExportOutcome.failure('答案版生成失败'),
      route: ExportRoute.a,
      report: confirmReport(),
    );

/// 确认步测试用控制器（盘点 / 生成 / 交付全部可注入桩）。
ExportFlowController confirmController({
  ExportInventory? inventory,
  TwoVersionExportResult? twoVersion,
  Object? generateError,
  GenerateVersionsFn? generateOverride,
  List<List<ExcludedQuestion>>? excludedCalls,
  PdfDeliveryPlatform? platformOverride,
}) {
  return ExportFlowController(
    computeInventory:
        ({
          required List<String> ids,
          required List<ExcludedQuestion> excluded,
          required int circledCount,
        }) async {
          excludedCalls?.add(List.of(excluded));
          if (inventory == null) throw StateError('盘点失败');
          return inventory;
        },
    generateVersions:
        generateOverride ??
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
          onProgress?.call(ids.length, ids.length, '正在生成 PDF…');
          if (generateError != null) throw generateError;
          if (twoVersion != null) return twoVersion;
          // 未传桩结果时按所选版本生成（与生产 generateVersions 同口径：
          // 未选中的版本不在结果里出现）。
          return TwoVersionExportResult(
            practice: versions.practice
                ? VersionExportOutcome.success(confirmPdfResult())
                : null,
            answer: versions.answer
                ? VersionExportOutcome.success(
                    confirmPdfResult(variant: ExportVersion.answer),
                  )
                : null,
            route: ExportRoute.a,
            report: confirmReport(),
          );
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
    openFile: (_) async => true,
    openFolder: (_) async => true,
    shareFile: (_) async =>
        const ShareResult(outcome: ShareOutcome.shared),
    platformOverride: platformOverride,
  );
}

Future<void> pumpConfirm(
  WidgetTester tester, {
  required ExportConfirmInput input,
  required ExportFlowController controller,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const Key('open-confirm'),
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (_) => ExportConfirmDialog(
                    input: input,
                    controller: controller,
                  ),
                );
              },
              child: const Text('打开确认步'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('open-confirm')));
  await tester.pump();
  for (var i = 0; i < 10; i++) {
    if (find.text('正在盘点…').evaluate().isEmpty) break;
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump();
}

/// 点一个可能在滚动区外的控件（先滚到可见再点）。
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// 点「生成」后等终态（有界等待）。
Future<void> waitForTerminal(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    if (find.text('导出完成').evaluate().isNotEmpty) break;
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump();
}

void main() {
  group('确认步：信息完整', () {
    testWidgets('已选数 / 范围 / 路线 / 文件名默认齐全；格式只留 PDF', (tester) async {
      await pumpConfirm(
        tester,
        input: confirmInput(),
        controller: confirmController(inventory: confirmInventory()),
      );
      expect(find.text('确认导出'), findsOneWidget);
      expect(find.text('已选 3 道（当前列表共 3 道）'), findsOneWidget);
      expect(find.text('范围：全部题目'), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const Key('export-file-name')),
      );
      expect(field.controller?.text.startsWith('错题本_多学科_'), isTrue);
      expect(field.controller?.text.endsWith('.pdf'), isTrue);
      // 十六批 C：格式均可选（PDF / Word）；Word 不再置灰。
      expect(find.text('PDF'), findsOneWidget);
      expect(find.text('Word'), findsOneWidget);
      final wordTile = tester.widget<RadioListTile<ExportFormat>>(
        find.byWidgetPredicate(
          (w) =>
              w is RadioListTile<ExportFormat> &&
              w.value == ExportFormat.word,
        ),
      );
      // 未显式传 enabled 时为 null，即启用（旧断言 isFalse 是置灰行为）。
      expect(wordTile.enabled ?? true, isTrue);
    });

    testWidgets('C 路线：路线明示、可印/跳过数、跳过清单展开', (tester) async {
      final controller = confirmController(
        inventory: confirmInventory(
          route: ExportRoute.c,
          selectedCount: 3,
          printableCount: 2,
          skippedCount: 1,
          skipped: const [
            SkipEntry(questionId: 'q2', title: '第 q2 题', reason: '无 OCR 结果'),
          ],
          suspicious: const [
            SuspiciousEntry(
              questionId: 'q0',
              title: '第 q0 题',
              flags: ['optionSplitUncertain'],
            ),
          ],
        ),
      );
      await pumpConfirm(
        tester,
        input: confirmInput(),
        controller: controller,
      );
      expect(find.text('可印 2 题 / 将跳过 1 题'), findsOneWidget);
      await tapVisible(tester, find.text('跳过清单（1）'));
      expect(find.text('无 OCR 结果'), findsOneWidget);
    });

    testWidgets('C 路线：跳过 0 题时只显示可印数，不拼“将跳过 0 题”（P8）', (
      tester,
    ) async {
      final controller = confirmController(
        inventory: confirmInventory(
          route: ExportRoute.c,
          selectedCount: 3,
          printableCount: 3,
          skippedCount: 0,
          skipped: const [],
        ),
      );
      await pumpConfirm(
        tester,
        input: confirmInput(),
        controller: controller,
      );
      expect(find.text('可印 3 题'), findsOneWidget);
      expect(find.textContaining('将跳过'), findsNothing);
    });

    testWidgets('A 路线：低于阈值数 + 排除勾选会重新盘点', (tester) async {
      final excludedCalls = <List<ExcludedQuestion>>[];
      final controller = confirmController(
        inventory: confirmInventory(
          lowDpi: const [
            LowDpiEntry(questionId: 'q0', title: '第 q0 题', dpi: 180, severe: false),
            LowDpiEntry(questionId: 'q1', title: '第 q1 题', dpi: 120, severe: true),
          ],
        ),
        excludedCalls: excludedCalls,
      );
      await pumpConfirm(
        tester,
        input: confirmInput(),
        controller: controller,
      );
      expect(find.text('低于清晰度阈值 2 题'), findsOneWidget);
      await tapVisible(tester, find.text('排除低于清晰度阈值的题'));
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        if (find.text('正在盘点…').evaluate().isEmpty) break;
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump();
      expect(excludedCalls.last, hasLength(2));
      expect(
        excludedCalls.last.map((e) => e.id).toSet(),
        {'q0', 'q1'},
      );
    });

    testWidgets('文件名非法时阻断并报错；修正后可生成', (tester) async {
      final controller = confirmController(inventory: confirmInventory());
      await pumpConfirm(
        tester,
        input: confirmInput(),
        controller: controller,
      );
      await tester.ensureVisible(find.byKey(const Key('export-file-name')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('export-file-name')),
        '错题本/测试.pdf',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('export-generate')));
      await tester.pump();
      expect(find.text('文件名不能包含 \\ / : * ? " < > |'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('export-file-name')),
        '错题本_多学科_20261121.pdf',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('export-generate')));
      await waitForTerminal(tester);
      expect(find.text('全部完成'), findsOneWidget);
    });

    testWidgets('guard 软警告明示预计占用', (tester) async {
      final soft = confirmController(
        inventory: confirmInventory(
          guard: ContentGuard.evaluate(
            const [
              GuardRasterItem(questionId: 'q0', title: '第 q0 题', rasterMpx: 90),
            ],
            isEstimate: true,
          ),
        ),
      );
      await pumpConfirm(
        tester,
        input: confirmInput(),
        controller: soft,
      );
      expect(
        find.text('内容较重，预计占用约 900 MB（估算值），确认后继续生成。'),
        findsOneWidget,
      );
    });

    testWidgets('guard 硬拒绝阻断生成', (tester) async {
      final hard = confirmController(
        inventory: confirmInventory(
          guard: ContentGuard.evaluate(
            const [
              GuardRasterItem(questionId: 'q0', title: '第 q0 题', rasterMpx: 160),
            ],
            isEstimate: true,
          ),
        ),
      );
      await pumpConfirm(
        tester,
        input: confirmInput(),
        controller: hard,
      );
      expect(find.byKey(const Key('export-guard-hard')), findsOneWidget);
      await tester.tap(find.byKey(const Key('export-generate')));
      await tester.pump();
      expect(
        find.text('本次导出内容过重，已停止生成。请减少题数，或去详情页重新框选。'),
        findsOneWidget,
      );
    });

    testWidgets('跳过数 > 20 时二次确认：取消则停下，确认则继续', (tester) async {
      final controller = confirmController(
        inventory: confirmInventory(
          route: ExportRoute.c,
          selectedCount: 30,
          printableCount: 9,
          skippedCount: 21,
          skipped: [
            for (var i = 0; i < 21; i++)
              SkipEntry(questionId: 's$i', title: '跳过题 $i', reason: '无 OCR 结果'),
          ],
        ),
      );
      await pumpConfirm(
        tester,
        input: confirmInput(count: 30),
        controller: controller,
      );
      await tester.tap(find.byKey(const Key('export-generate')));
      await tester.pumpAndSettle();
      expect(find.text('将跳过 21 / 30 道题，确认继续吗？'), findsOneWidget);
      // 二次确认弹窗里的「取消」（确认步操作栏里也有一个「取消」，
      // 须限定在弹窗内点按）。
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog).last,
          matching: find.text('取消'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('确认导出'), findsOneWidget);
      await tester.tap(find.byKey(const Key('export-generate')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认继续'));
      await waitForTerminal(tester);
      expect(find.text('全部完成'), findsOneWidget);
    });

    testWidgets('超限确认前阻断生成（防御性检查）', (tester) async {
      // 直接构造 51 道的输入：正常流程下勾选上限已拦住，确认步
      // 再断言一次，超限时阻断、不生成。
      final controller = confirmController(
        inventory: confirmInventory(selectedCount: 51, printableCount: 51),
      );
      await pumpConfirm(
        tester,
        input: confirmInput(count: 51),
        controller: controller,
      );
      await tester.tap(find.byKey(const Key('export-generate')));
      await tester.pump();
      expect(find.text('单次最多导出 50 道题'), findsOneWidget);
      expect(find.text('确认导出'), findsOneWidget);
    });
  });

  group('进度、取消与完成', () {
    testWidgets('进度按题推进；取消后显示已取消、不留交付', (tester) async {
      final controller = confirmController(
        inventory: confirmInventory(),
        generateOverride:
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
              onProgress?.call(1, 3, '正在准备题目…');
              await token.whenCancelled;
              throw const ExportCancelledException();
            },
      );
      await pumpConfirm(
        tester,
        input: confirmInput(),
        controller: controller,
      );
      await tester.tap(find.byKey(const Key('export-generate')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('当前第 1 / 3 题'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('已取消'), findsOneWidget);
      expect(find.text('导出已取消，未生成文件。'), findsOneWidget);
    });

    testWidgets('完成界面：报告摘要、警告清单展开、桌面端打开按钮', (tester) async {
      final controller = confirmController(inventory: confirmInventory());
      await pumpConfirm(
        tester,
        input: confirmInput(),
        controller: controller,
      );
      final fileName = tester
          .widget<TextField>(find.byKey(const Key('export-file-name')))
          .controller
          ?.text;
      await tester.tap(find.byKey(const Key('export-generate')));
      await waitForTerminal(tester);
      expect(find.text('全部完成'), findsOneWidget);
      expect(find.text('练习版：$fileName'), findsOneWidget);
      expect(find.textContaining('增强后印出 3 / 3 道'), findsOneWidget);
      expect(find.textContaining('答案已录入 1 / 3 道'), findsOneWidget);
      expect(find.text('打开文件'), findsOneWidget);
      expect(find.text('打开所在文件夹'), findsOneWidget);
      await tapVisible(tester, find.text('警告清单（1）'));
      expect(find.text('增强失败，已用原图'), findsOneWidget);
    });

    testWidgets('部分成功：逐份列出成功/失败，不得伪装成全部成功', (tester) async {
      final controller = confirmController(
        inventory: confirmInventory(),
        twoVersion: confirmTwoVersion(answerSucceeds: false),
      );
      await pumpConfirm(
        tester,
        input: confirmInput(),
        controller: controller,
      );
      await tapVisible(tester, find.text('答案版'));
      final fileName = tester
          .widget<TextField>(find.byKey(const Key('export-file-name')))
          .controller
          ?.text;
      await tester.tap(find.byKey(const Key('export-generate')));
      await waitForTerminal(tester);
      expect(find.text('部分成功：以下文件未完成。'), findsOneWidget);
      expect(find.text('练习版：$fileName'), findsOneWidget);
      expect(find.text('生成失败：答案版生成失败'), findsOneWidget);
    });

    testWidgets('Android 出「分享」+ 独立「打开 PDF」，不出桌面打开按钮', (tester) async {
      final controller = confirmController(
        inventory: confirmInventory(),
        platformOverride: PdfDeliveryPlatform.android,
      );
      await pumpConfirm(
        tester,
        input: confirmInput(),
        controller: controller,
      );
      await tester.tap(find.byKey(const Key('export-generate')));
      await waitForTerminal(tester);
      expect(find.text('全部完成'), findsOneWidget);
      expect(find.text('分享'), findsOneWidget);
      // 二十批 P7（十五批 #31）：Android 在「分享」旁加独立
      // 「打开 PDF」按钮（open_filex 通道）。
      expect(find.text('打开 PDF'), findsOneWidget);
      expect(find.text('打开文件'), findsNothing);
      expect(find.text('打开所在文件夹'), findsNothing);
    });

    testWidgets('整单失败：明确报错 + 临时文件已清理说明', (tester) async {
      final controller = confirmController(
        inventory: confirmInventory(),
        generateError: ExportNoPrintableException('本次没有可导出题目。'),
      );
      await pumpConfirm(
        tester,
        input: confirmInput(),
        controller: controller,
      );
      await tester.tap(find.byKey(const Key('export-generate')));
      await waitForTerminal(tester);
      expect(find.text('导出失败'), findsOneWidget);
      expect(find.textContaining('本次没有可导出题目。'), findsOneWidget);
      expect(find.textContaining('临时文件已清理，未生成损坏文件。'), findsOneWidget);
    });
  });
}
