// 十五批 M3：向导 widget 测试（D-168 三步向导、50 道上限、盘点展示、
// guard、跳过二次确认、进度与取消、完成界面、Android 只出分享）。
//
// 注意：确认步盘点加载时有转圈动画，等待盘点完成不用 pumpAndSettle，
// 用有界 pump（既有教训：整页首加载测试不用 pumpAndSettle）。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/wrongbook/export_wizard.dart';
import 'package:quiz_master2/services/pdf_export/content_guard.dart';
import 'package:quiz_master2/services/pdf_export/export_flow.dart';
import 'package:quiz_master2/services/pdf_export/export_integrity.dart';
import 'package:quiz_master2/services/pdf_export/export_inventory.dart';
import 'package:quiz_master2/services/pdf_export/export_route.dart';
import 'package:quiz_master2/services/pdf_export/export_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/export_versions.dart';
import 'package:quiz_master2/services/pdf_export/pdf_delivery.dart';
import 'package:quiz_master2/services/pdf_export/pdf_export_service.dart';

Question wq(
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

ExportWizardInput wizardInput({int count = 3}) {
  final questions = <Question>[];
  for (var i = 0; i < count; i++) {
    questions.add(
      wq(
        'q$i',
        subjectId: i < 2 ? 'math' : 'english',
        folderIds: i < 2 ? const ['f1'] : const ['f2'],
      ),
    );
  }
  return ExportWizardInput(
    questions: questions,
    subjects: [Subject.math, Subject.english, Subject.politics],
    folders: const [
      Folder(id: 'f1', name: '试卷', subjectId: 'math'),
      Folder(id: 'f2', name: '作业', subjectId: 'english'),
    ],
    exams: const [Exam(id: 'e1', name: '期中考试')],
    kps: const [
      KnowledgePoint(id: 'k1', subjectId: 'math', chapter: '第一章', name: '极限'),
    ],
    causeNames: const ['计算错误', '概念不清'],
  );
}

ExportInventory wizardInventory({
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

IntegrityReport wizardReport() => IntegrityReport(
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

PdfExportResult wizardPdfResult({ExportVersion variant = ExportVersion.practice}) =>
    PdfExportResult(
      pdfBytes: Uint8List.fromList(const [37, 80, 68, 70]),
      report: wizardReport(),
      route: ExportRoute.a,
      totalPages: variant == ExportVersion.answer ? 5 : 3,
      questionPages: const [],
      estimatedGuard: ContentGuard.evaluate(const [], isEstimate: true),
      actualGuard: ContentGuard.evaluate(const [], isEstimate: false),
      guardDeviation: const GuardDeviation(estimatedMpx: 0, actualMpx: 0),
      variant: variant,
    );

TwoVersionExportResult wizardTwoVersion({bool answerSucceeds = true}) =>
    TwoVersionExportResult(
      practice: VersionExportOutcome.success(wizardPdfResult()),
      answer: answerSucceeds
          ? VersionExportOutcome.success(
              wizardPdfResult(variant: ExportVersion.answer),
            )
          : const VersionExportOutcome.failure('答案版生成失败'),
      route: ExportRoute.a,
      report: wizardReport(),
    );

/// 向导测试用控制器（盘点 / 生成 / 交付全部可注入桩）。
ExportFlowController wizardController({
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
                ? VersionExportOutcome.success(wizardPdfResult())
                : null,
            answer: versions.answer
                ? VersionExportOutcome.success(
                    wizardPdfResult(variant: ExportVersion.answer),
                  )
                : null,
            route: ExportRoute.a,
            report: wizardReport(),
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

Future<void> pumpWizard(
  WidgetTester tester, {
  required ExportWizardInput input,
  required ExportFlowController controller,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const Key('open-wizard'),
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (_) => ExportWizardDialog(
                    input: input,
                    controller: controller,
                  ),
                );
              },
              child: const Text('打开向导'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('open-wizard')));
  await tester.pumpAndSettle();
}

/// 点一个可能在滚动区外的控件（先滚到可见再点）。
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// 下一步（第 1 步 → 第 2 步；第 2 步 → 第 3 步不走此 helper，
/// 因第 3 步有盘点加载，需有界等待）。
Future<void> tapNext(WidgetTester tester) async {
  await tester.tap(find.text('下一步'));
  await tester.pumpAndSettle();
}

/// 进入确认步并等盘点完成（有界等待，不用 pumpAndSettle 等转圈）。
Future<void> enterConfirm(WidgetTester tester) async {
  await tester.tap(find.text('下一步'));
  await tester.pump();
  for (var i = 0; i < 10; i++) {
    if (find.text('正在盘点…').evaluate().isEmpty) break;
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump();
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
  group('第 1 步：选范围', () {
    testWidgets('默认圈定全部当前筛选题；改学科实时更新圈定数', (tester) async {
      await pumpWizard(
        tester,
        input: wizardInput(),
        controller: wizardController(inventory: wizardInventory()),
      );
      expect(find.text('新建导出单 · 第 1 步：选范围'), findsOneWidget);
      expect(find.text('圈定 3 道题'), findsOneWidget);
      await tester.tap(find.byType(DropdownButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('数学'));
      await tester.pumpAndSettle();
      expect(find.text('圈定 2 道题'), findsOneWidget);
    });
  });

  group('第 2 步：挑题与 50 道上限', () {
    testWidgets('默认全选；60 道范围只选中前 50 道并明示', (tester) async {
      await pumpWizard(
        tester,
        input: wizardInput(count: 60),
        controller: wizardController(inventory: wizardInventory()),
      );
      await tapNext(tester);
      expect(find.text('已选 50 / 50 道'), findsOneWidget);
      expect(
        find.text(
          '范围共 60 道，已按当前排序选中前 50 道，'
          '其余题目未选中。你可以调整本次选择。',
        ),
        findsOneWidget,
      );
    });

    testWidgets('点选第 51 道拒绝并提示；翻页不丢已选', (tester) async {
      await pumpWizard(
        tester,
        input: wizardInput(count: 60),
        controller: wizardController(inventory: wizardInventory()),
      );
      await tapNext(tester);
      // 翻到第 6 页（第 51–60 题，均未选）。
      for (var i = 0; i < 5; i++) {
        await tapVisible(tester, find.text('下一页 →'));
      }
      expect(find.text('第 6 / 6 页'), findsOneWidget);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('export-pick-q50')),
      );
      expect(find.text('单次最多导出 50 道题'), findsOneWidget);
      expect(find.text('已选 50 / 50 道'), findsOneWidget);
      // 翻回第 1 页，已选状态仍在。
      for (var i = 0; i < 5; i++) {
        await tapVisible(tester, find.text('← 上一页'));
      }
      expect(find.text('已选 50 / 50 道'), findsOneWidget);
    });

    testWidgets('已手动选部分题再点全选 = 替换为前 50 道', (tester) async {
      await pumpWizard(
        tester,
        input: wizardInput(count: 60),
        controller: wizardController(inventory: wizardInventory()),
      );
      await tapNext(tester);
      await tester.tap(find.text('全不选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 / 50 道'), findsOneWidget);
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 50 / 50 道'), findsOneWidget);
      expect(
        find.text(
          '范围共 60 道，已按当前排序选中前 50 道，'
          '其余题目未选中。你可以调整本次选择。',
        ),
        findsOneWidget,
      );
    });
  });

  group('第 3 步：确认导出', () {
    testWidgets('C 路线：路线明示、可印/跳过数、跳过清单展开、文件名默认', (tester) async {
      final controller = wizardController(
        inventory: wizardInventory(
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
      await pumpWizard(
        tester,
        input: wizardInput(),
        controller: controller,
      );
      await tapNext(tester);
      await enterConfirm(tester);
      expect(find.text('可印 2 题 / 将跳过 1 题'), findsOneWidget);
      expect(
        find.text(
          '路线：本次走 OCR 重排路线（已配置 OCR key）。'
          '本次不会自动补跑 OCR；没有 OCR 结果的题将被跳过，'
          '可去详情页重新触发 OCR。',
        ),
        findsOneWidget,
      );
      await tapVisible(tester, find.text('跳过清单（1）'));
      expect(find.text('无 OCR 结果'), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const Key('export-file-name')),
      );
      expect(field.controller?.text.startsWith('错题本_多学科_'), isTrue);
      expect(field.controller?.text.endsWith('.pdf'), isTrue);
    });

    testWidgets('A 路线：低于阈值数 + 排除勾选会重新盘点', (tester) async {
      final excludedCalls = <List<ExcludedQuestion>>[];
      final controller = wizardController(
        inventory: wizardInventory(
          lowDpi: const [
            LowDpiEntry(questionId: 'q0', title: '第 q0 题', dpi: 180, severe: false),
            LowDpiEntry(questionId: 'q1', title: '第 q1 题', dpi: 120, severe: true),
          ],
        ),
        excludedCalls: excludedCalls,
      );
      await pumpWizard(
        tester,
        input: wizardInput(),
        controller: controller,
      );
      await tapNext(tester);
      await enterConfirm(tester);
      expect(find.text('低于清晰度阈值 2 题'), findsOneWidget);
      expect(
        find.text('路线：本次走图片增强路线（未配置 OCR key）。'
            '去设置页配置 OCR key 可改走 OCR 重排路线（只提示，不强制跳转）。'),
        findsOneWidget,
      );
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
      final controller = wizardController(inventory: wizardInventory());
      await pumpWizard(
        tester,
        input: wizardInput(),
        controller: controller,
      );
      await tapNext(tester);
      await enterConfirm(tester);
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
      final soft = wizardController(
        inventory: wizardInventory(
          guard: ContentGuard.evaluate(
            const [
              GuardRasterItem(questionId: 'q0', title: '第 q0 题', rasterMpx: 90),
            ],
            isEstimate: true,
          ),
        ),
      );
      await pumpWizard(
        tester,
        input: wizardInput(),
        controller: soft,
      );
      await tapNext(tester);
      await enterConfirm(tester);
      expect(
        find.text('内容较重，预计占用约 900 MB（估算值），确认后继续生成。'),
        findsOneWidget,
      );
    });

    testWidgets('guard 硬拒绝阻断生成', (tester) async {
      final hard = wizardController(
        inventory: wizardInventory(
          guard: ContentGuard.evaluate(
            const [
              GuardRasterItem(questionId: 'q0', title: '第 q0 题', rasterMpx: 160),
            ],
            isEstimate: true,
          ),
        ),
      );
      await pumpWizard(
        tester,
        input: wizardInput(),
        controller: hard,
      );
      await tapNext(tester);
      await enterConfirm(tester);
      expect(find.byKey(const Key('export-guard-hard')), findsOneWidget);
      await tester.tap(find.byKey(const Key('export-generate')));
      await tester.pump();
      expect(
        find.text('本次导出内容过重，已停止生成。请减少题数，或去详情页重拍裁切。'),
        findsOneWidget,
      );
    });

    testWidgets('跳过数 > 20 时二次确认：取消则停下，确认则继续', (tester) async {
      final controller = wizardController(
        inventory: wizardInventory(
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
      await pumpWizard(
        tester,
        input: wizardInput(count: 30),
        controller: controller,
      );
      await tapNext(tester);
      await enterConfirm(tester);
      expect(
        find.text('将跳过 21 / 30 道题，点「生成」后会再次确认。'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('export-generate')));
      await tester.pumpAndSettle();
      expect(find.text('将跳过 21 / 30 道题，确认继续吗？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('新建导出单 · 第 3 步：确认导出'), findsOneWidget);
      await tester.tap(find.byKey(const Key('export-generate')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认继续'));
      await waitForTerminal(tester);
      expect(find.text('全部完成'), findsOneWidget);
    });
  });

  group('进度、取消与完成', () {
    testWidgets('进度按题推进；取消后显示已取消、不留交付', (tester) async {
      final controller = wizardController(
        inventory: wizardInventory(),
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
      await pumpWizard(
        tester,
        input: wizardInput(),
        controller: controller,
      );
      await tapNext(tester);
      await enterConfirm(tester);
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
      final controller = wizardController(inventory: wizardInventory());
      await pumpWizard(
        tester,
        input: wizardInput(),
        controller: controller,
      );
      await tapNext(tester);
      await enterConfirm(tester);
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
      final controller = wizardController(
        inventory: wizardInventory(),
        twoVersion: wizardTwoVersion(answerSucceeds: false),
      );
      await pumpWizard(
        tester,
        input: wizardInput(),
        controller: controller,
      );
      await tapNext(tester);
      await enterConfirm(tester);
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

    testWidgets('Android 只出「分享」，不出打开按钮', (tester) async {
      final controller = wizardController(
        inventory: wizardInventory(),
        platformOverride: PdfDeliveryPlatform.android,
      );
      await pumpWizard(
        tester,
        input: wizardInput(),
        controller: controller,
      );
      await tapNext(tester);
      await enterConfirm(tester);
      await tester.tap(find.byKey(const Key('export-generate')));
      await waitForTerminal(tester);
      expect(find.text('全部完成'), findsOneWidget);
      expect(find.text('分享'), findsOneWidget);
      expect(find.text('打开文件'), findsNothing);
      expect(find.text('打开所在文件夹'), findsNothing);
    });

    testWidgets('整单失败：明确报错 + 临时文件已清理说明', (tester) async {
      final controller = wizardController(
        inventory: wizardInventory(),
        generateError: ExportNoPrintableException('本次没有可导出题目。'),
      );
      await pumpWizard(
        tester,
        input: wizardInput(),
        controller: controller,
      );
      await tapNext(tester);
      await enterConfirm(tester);
      await tester.tap(find.byKey(const Key('export-generate')));
      await waitForTerminal(tester);
      expect(find.text('导出失败'), findsOneWidget);
      expect(find.textContaining('本次没有可导出题目。'), findsOneWidget);
      expect(find.textContaining('临时文件已清理，未生成损坏文件。'), findsOneWidget);
    });
  });
}
