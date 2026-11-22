// 十六批 B（D-190）+ 十七批 P2（D-208）＋十九批 A2（D-220）：
// 错题本列表页导出模式＋点选高亮（widget 测试）。十九批 A1 去掉
// 大卡片／紧凑列表，只剩板子一种行设计；A2 按板子 §1.6 重做入口
// 与汇总条（入口「导出打印」；汇总条只在模式里显示，
// 「已选 N 道：题名…」；旧的可展开清单与盘点显示已删）。
//
// 覆盖：进模式 / 退模式、模式里点行切换选中与 ✓ / 蓝底、模式外点行
// 进详情、汇总题名清单、跨科点选不丢已选、翻页与换筛选不丢已选、
// 50 道上限拒绝、工具栏导出入口与确认步全流程。两种模式下列表里
// 都没有 Checkbox。导出流程控制器用桩（经
// WrongbookPage.exportControllerFactory 注入），不碰真实数据库。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/wrongbook/wrongbook_page.dart';
import 'package:quiz_master2/services/pdf_export/content_guard.dart';
import 'package:quiz_master2/services/pdf_export/export_flow.dart';
import 'package:quiz_master2/services/pdf_export/export_integrity.dart';
import 'package:quiz_master2/services/pdf_export/export_inventory.dart';
import 'package:quiz_master2/services/pdf_export/export_route.dart';
import 'package:quiz_master2/services/pdf_export/export_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/export_versions.dart';
import 'package:quiz_master2/services/pdf_export/pdf_delivery.dart';
import 'package:quiz_master2/services/pdf_export/pdf_export_service.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';

Question dq(
  String id, {
  String subjectId = 'math',
  List<String> folderIds = const ['f1'],
  String? title,
  DateTime? createdAt,
}) => Question(
  id: id,
  title: title ?? '第 $id 题：求极限',
  subjectId: subjectId,
  folderIds: folderIds,
  errorTypes: const ['概念不清'],
  createdAt: createdAt ?? DateTime(2026, 11, 10),
  isOrganized: true,
  sliceKind: 'limit',
  sliceText: '题：求极限',
);

class DirectFakeRepo extends QuestionRepository {
  DirectFakeRepo({required this.questions}) : super(AppDatabase.instance);

  List<Question> questions;

  /// 十九批 A3：内存版已存查找（不碰真实库）。
  final List<SavedSearch> savedSearchList = [];

  @override
  Future<List<SavedSearch>> savedSearches() async =>
      List.of(savedSearchList);

  @override
  Future<void> saveSavedSearch(SavedSearch search) async {
    savedSearchList.removeWhere((s) => s.id == search.id);
    savedSearchList.add(search);
  }

  @override
  Future<void> deleteSavedSearch(String id) async {
    savedSearchList.removeWhere((s) => s.id == id);
  }

  @override
  Future<List<Subject>> subjects() async => [
    Subject.math,
    Subject.english,
    Subject.politics,
  ];

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [
    Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
    Folder(id: 'f2', name: '作业', subjectId: 'english', sortOrder: 0),
  ];

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<String>> tags() async => const [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<Map<String, (int, int, int)>> subjectCounts({
    bool includeArchived = false,
  }) async => const {};

  @override
  Future<List<CauseRecord>> causeRecords() async => const [];

  @override
  Future<AppSettings> settings() async => const AppSettings();
}

/// 桩控制器：盘点按 [inventoryFor] 算（默认全部可印、无跳过），
/// 生成与交付全部成功。
ExportFlowController stubExportController({
  ExportInventory Function(List<String> ids)? inventoryFor,
}) {
  ExportInventory defaultInventory(List<String> ids) => ExportInventory(
    route: ExportRoute.a,
    routeReason: '未配置 OCR key',
    circledCount: ids.length,
    selectedCount: ids.length,
    excluded: const [],
    printableCount: ids.length,
    skippedCount: 0,
    skipped: const [],
    suspicious: const [],
    lowDpi: const [],
    guard: ContentGuard.evaluate(const [], isEstimate: true),
  );
  return ExportFlowController(
    computeInventory:
        ({
          required List<String> ids,
          required List<ExcludedQuestion> excluded,
          required int circledCount,
        }) async =>
            (inventoryFor ?? defaultInventory)(ids),
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
          onProgress?.call(ids.length, ids.length, '正在生成 PDF…');
          final report = IntegrityReport(
            route: ExportRoute.a,
            selectedCount: ids.length,
            snapshotCount: ids.length,
            excludedCount: 0,
            answersRecorded: ids.length,
            answersTotal: ids.length,
            explanationsRecorded: 0,
            explanationsTotal: ids.length,
            entries: [
              for (final id in ids)
                IntegrityEntry(
                  questionId: id,
                  title: '第 $id 题',
                  status: IntegrityStatus.complete,
                  warnings: const [],
                ),
            ],
          );
          PdfExportResult result(ExportVersion v) => PdfExportResult(
            pdfBytes: Uint8List.fromList(const [37, 80, 68, 70]),
            report: report,
            route: ExportRoute.a,
            totalPages: 1,
            questionPages: const [],
            estimatedGuard: ContentGuard.evaluate(const [], isEstimate: true),
            actualGuard: ContentGuard.evaluate(const [], isEstimate: false),
            guardDeviation: const GuardDeviation(
              estimatedMpx: 0,
              actualMpx: 0,
            ),
            variant: v,
          );
          return TwoVersionExportResult(
            practice: versions.practice
                ? VersionExportOutcome.success(result(ExportVersion.practice))
                : null,
            answer: versions.answer
                ? VersionExportOutcome.success(result(ExportVersion.answer))
                : null,
            route: ExportRoute.a,
            report: report,
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
  );
}

Future<void> pumpDirect(
  WidgetTester tester, {
  required DirectFakeRepo repo,
  ExportFlowController? controller,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final ctrl = controller ?? stubExportController();
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: Scaffold(
        body: WrongbookPage(
          repo: repo,
          exportControllerFactory: () => ctrl,
          onOpenHome: () {},
          onOpenDetail: (_, __, {String? searchContext}) async {},
          onGoReview: ({String? subjectId}) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

// 二十三批 D-250：/wrongbook 默认落点恢复书架，进数学列表走
// 书架 → 点数学封面进目录 → 全部题目；A1 去掉视图切换。
Future<void> openMathList(WidgetTester tester) async {
  await tester.tap(find.text('数学'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('全部题目'));
  await tester.pumpAndSettle();
}

Future<void> openMathListCompact(WidgetTester tester) async {
  await openMathList(tester);
}

/// 回书架（二十三批 D-250：页头恢复后走列表页头「合上 ✕」；
/// 已在书架时 no-op。十九批 A5 的筛选面板顶部入口已删）。
Future<void> openShelfFromList(WidgetTester tester) async {
  if (find
      .text('一科一本错题本，点一本打开看这一科的错题。')
      .evaluate()
      .isNotEmpty) {
    return; // 已在书架。
  }
  if (find.text('合上 ✕').evaluate().isNotEmpty) {
    await tester.tap(find.text('合上 ✕'));
  } else if (find.text('返回书架').evaluate().isNotEmpty) {
    await tester.tap(find.text('返回书架'));
  } else {
    fail('不在列表 / 目录 / 书架任一视图，回不了书架');
  }
  await tester.pumpAndSettle();
}

/// 进导出模式（入口「导出打印」平时是进模式的入口，
/// 不是直接确认）。
Future<void> enterExportMode(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('export-selected-toolbar')));
  await tester.pump();
}

/// 导出模式里点一行切换选中（十九批 A1：只剩板子行，行 key 是
/// `export-row-$id`；先滚到可见再点，只 pump 一帧，不用
/// pumpAndSettle 等动画）。
Future<void> tapExportRow(WidgetTester tester, String id) async {
  final finder = find.byKey(ValueKey('export-row-$id'));
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(finder);
  await tester.pump();
}

/// 该题是否处于导出选中态（选中行右端的小 ✓ 在不在）。
bool isExportSelected(WidgetTester tester, String id) =>
    find.byKey(ValueKey('export-mark-$id')).evaluate().isNotEmpty;

/// 点一个可能在滚动区外的文本按钮（分页器在列表底部，可能在折叠线下）。
Future<void> tapVisibleText(WidgetTester tester, String label) async {
  final finder = find.text(label);
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// 汇总条数字行文本（折叠态只剩数字；展开时仍在同一行）。
String summaryNumbers(WidgetTester tester) {
  final text = tester.widget<Text>(
    find.byKey(const Key('export-summary-numbers')),
  );
  return text.data ?? '';
}

/// 等后台盘点防抖（300ms）+ 异步盘点完成。
Future<void> waitForInventory(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

void main() {
  group('勾选与汇总', () {
    testWidgets('勾选 / 取消勾选，汇总数跟着变；勾过行高亮', (tester) async {
      await pumpDirect(
        tester,
        repo: DirectFakeRepo(
          questions: [dq('q1'), dq('q2'), dq('q3')],
        ),
      );
      await openMathListCompact(tester);
      // 汇总条只在模式里画，平时不画；平时列表里没有导出方框。
      expect(find.byKey(const Key('export-summary-numbers')), findsNothing);
      expect(find.byType(Checkbox), findsNothing);
      // 入口「导出打印」平时是进模式的入口（空选也能进）。
      expect(find.text('导出打印'), findsOneWidget);

      await enterExportMode(tester);
      expect(find.byKey(const Key('export-mode-hint')), findsOneWidget);
      expect(summaryNumbers(tester), contains('已选 0 道'));
      // 模式里也没有方框；n = 0 时「导出」置灰。
      expect(find.byType(Checkbox), findsNothing);
      final toolbarBtnInMode = tester.widget<QmButton>(
        find.byKey(const Key('export-selected-toolbar')),
      );
      expect(toolbarBtnInMode.onPressed, isNull);
      expect(toolbarBtnInMode.label, '导出');

      await tapExportRow(tester, 'q1');
      expect(isExportSelected(tester, 'q1'), isTrue);
      expect(summaryNumbers(tester), contains('已选 1 道'));
      // 勾过行高亮：行容器的浅底色。
      final row = tester.widget<Container>(
        find.byKey(const ValueKey('export-row-q1')),
      );
      expect(
        (row.decoration as BoxDecoration?)?.color,
        DesignTokens.of(Brightness.light).accentSoft,
      );
      // 未勾选的行不高亮、无 ✓（板子行底色是 surface 白底）。
      final row2 = tester.widget<Container>(
        find.byKey(const ValueKey('export-row-q2')),
      );
      expect(
        (row2.decoration as BoxDecoration?)?.color,
        DesignTokens.of(Brightness.light).surface,
      );
      expect(isExportSelected(tester, 'q2'), isFalse);
      // 工具栏导出按钮可用，带数量。
      final toolbarBtn2 = tester.widget<QmButton>(
        find.byKey(const Key('export-selected-toolbar')),
      );
      expect(toolbarBtn2.onPressed, isNotNull);
      expect(toolbarBtn2.label, '导出（1）');

      await tapExportRow(tester, 'q1');
      expect(isExportSelected(tester, 'q1'), isFalse);
      expect(summaryNumbers(tester), contains('已选 0 道'));
    });

    testWidgets('板子行点选，勾过行变色＋出 ✓', (tester) async {
      await pumpDirect(
        tester,
        repo: DirectFakeRepo(
          questions: [dq('q1'), dq('q2')],
        ),
      );
      await openMathList(tester);
      // 平时无方框。
      expect(find.byType(Checkbox), findsNothing);
      await enterExportMode(tester);
      expect(find.byType(Checkbox), findsNothing);
      await tapExportRow(tester, 'q1');
      expect(isExportSelected(tester, 'q1'), isTrue);
      expect(summaryNumbers(tester), contains('已选 1 道'));
      final row = tester.widget<Container>(
        find.byKey(const ValueKey('export-row-q1')),
      );
      expect(
        (row.decoration as BoxDecoration?)?.color,
        DesignTokens.of(Brightness.light).accentSoft,
      );
    });

    testWidgets('汇总条题名清单：已选 N 道：题名1、题名2；再点行取消', (tester) async {
      // 十九批 A2（D-220）：旧的可展开清单已删，汇总条只剩一行
      // 「已选 N 道：题名1、题名2…」＋操作按钮；取消勾选仍走行点按。
      await pumpDirect(
        tester,
        repo: DirectFakeRepo(
          questions: [dq('q1'), dq('q2'), dq('q3')],
        ),
      );
      await openMathListCompact(tester);
      await enterExportMode(tester);
      await tapExportRow(tester, 'q1');
      await tapExportRow(tester, 'q3');
      expect(
        summaryNumbers(tester),
        '已选 2 道：第 q1 题：求极限、第 q3 题：求极限',
      );
      // 再点 q1 行取消：只剩 q3，清单跟着变。
      await tapExportRow(tester, 'q1');
      await tester.pump();
      expect(summaryNumbers(tester), contains('已选 1 道'));
      expect(summaryNumbers(tester), contains('第 q3 题：求极限'));
      expect(summaryNumbers(tester), isNot(contains('第 q1 题')));
      expect(isExportSelected(tester, 'q1'), isFalse);
      expect(isExportSelected(tester, 'q3'), isTrue);
    });

    testWidgets('跨科点选：汇总题名清单含两科的题，不丢已选', (tester) async {
      // 十九批 A2（D-220）：旧汇总「N 个学科 · N 个文件夹」文案
      // 已删，汇总条只剩「已选 N 道：题名…」。跨科点选仍走书架 →
      // 目录 → 全部题目（导出模式随页面状态保留，不用重进）。
      await pumpDirect(
        tester,
        repo: DirectFakeRepo(
          questions: [
            dq('q1', subjectId: 'math', folderIds: const ['f1']),
            dq('q2', subjectId: 'english', folderIds: const ['f2']),
            dq('q3', subjectId: 'math', folderIds: const ['f1']),
          ],
        ),
      );
      await openMathListCompact(tester);
      // 当前在数学列表里：进导出模式，先点 q1（数学 / f1）。
      await enterExportMode(tester);
      await tapExportRow(tester, 'q1');
      expect(summaryNumbers(tester), contains('已选 1 道'));
      // 回书架进英语列表点 q2（跨科点选不丢 q1）。
      // 二十三批 D-250：页头恢复，回书架走「合上 ✕」。
      await openShelfFromList(tester);
      await tester.tap(find.text('英语'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      await tapExportRow(tester, 'q2');
      expect(summaryNumbers(tester), contains('已选 2 道'));
      expect(summaryNumbers(tester), contains('第 q1 题'));
      expect(summaryNumbers(tester), contains('第 q2 题'));
    });

    // 十九批 A2（D-219/D-220）：汇总条的后台盘点显示已删——旧汇总
    // 条「正在盘点…」「将跳过 N 道」「全部可印，无跳过」三项断言随
    // 之删除（盘点仍在确认步里跑，覆盖在确认步测试里，不删覆盖，
    // 只是不在汇总条上断言）。
  });

  group('翻页与换筛选不丢已选', () {
    testWidgets('翻页不丢已选，翻回后勾选与高亮仍在', (tester) async {
      await pumpDirect(
        tester,
        repo: DirectFakeRepo(
          questions: List.generate(12, (i) => dq('q$i')),
        ),
      );
      await openMathListCompact(tester);
      await enterExportMode(tester);
      await tapExportRow(tester, 'q0');
      expect(summaryNumbers(tester), contains('已选 1 道'));
      await tapVisibleText(tester, '下一页');
      expect(summaryNumbers(tester), contains('已选 1 道'));
      expect(find.byKey(const ValueKey('export-row-q0')), findsNothing);
      await tapVisibleText(tester, '上一页');
      expect(isExportSelected(tester, 'q0'), isTrue);
      expect(summaryNumbers(tester), contains('已选 1 道'));
    });

    testWidgets('换筛选（搜索）不丢已选，搜不到时汇总仍在', (tester) async {
      await pumpDirect(
        tester,
        repo: DirectFakeRepo(
          questions: [
            dq('q1', title: '第 q1 题：求极限'),
            dq('q2', title: '第 q2 题：求导数'),
          ],
        ),
      );
      await openMathListCompact(tester);
      await enterExportMode(tester);
      await tapExportRow(tester, 'q1');
      // 搜一个只命中 q2 的词，q1 从列表消失。
      await tester.enterText(
        find.byType(TextField).first,
        '求导数',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('export-row-q1')), findsNothing);
      expect(summaryNumbers(tester), contains('已选 1 道'));
      // 清空搜索，q1 回来，勾选仍在。
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pumpAndSettle();
      expect(isExportSelected(tester, 'q1'), isTrue);
    });
  });

  group('跨筛选确认快照（P0-1 锁定）', () {
    testWidgets('筛选 A 选 A1 → 切筛选 B 选 B1 → 确认步快照同时含 A1 与 B1', (tester) async {
      // 确认步盘点收到的 ids 即确认快照：ExportConfirmDialog._prepare
      // 以快照 _selectedIds 调 controller.prepare（→ computeInventory）。
      // 打开确认前清空，只录确认步这次调用。
      final confirmSnapshots = <List<String>>[];
      final controller = stubExportController(
        inventoryFor: (ids) {
          confirmSnapshots.add(List.of(ids));
          return ExportInventory(
            route: ExportRoute.a,
            routeReason: '未配置 OCR key',
            circledCount: ids.length,
            selectedCount: ids.length,
            excluded: const [],
            printableCount: ids.length,
            skippedCount: 0,
            skipped: const [],
            suspicious: const [],
            lowDpi: const [],
            guard: ContentGuard.evaluate(const [], isEstimate: true),
          );
        },
      );
      await pumpDirect(
        tester,
        repo: DirectFakeRepo(
          questions: [
            dq('a1', title: '第 a1 题：求极限'),
            dq('b1', title: '第 b1 题：求导数'),
          ],
        ),
        controller: controller,
      );
      await openMathListCompact(tester);
      await enterExportMode(tester);
      // 筛选 A（只命中 a1）下选 a1。
      await tester.enterText(find.byType(TextField).first, '求极限');
      await tester.pumpAndSettle();
      await tapExportRow(tester, 'a1');
      expect(summaryNumbers(tester), contains('已选 1 道'));
      // 切筛选 B（只命中 b1）选 b1；a1 已不在当前列表。
      await tester.enterText(find.byType(TextField).first, '求导数');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('export-row-a1')), findsNothing);
      await tapExportRow(tester, 'b1');
      expect(summaryNumbers(tester), contains('已选 2 道'));
      await waitForInventory(tester);

      confirmSnapshots.clear();
      await tester.tap(find.byKey(const Key('export-selected-toolbar')));
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        if (confirmSnapshots.isNotEmpty) break;
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump();
      expect(find.text('确认导出'), findsOneWidget);
      // 当前列表只有 b1，但确认步仍说已选 2 道。
      expect(find.text('已选 2 道（当前列表共 1 道）'), findsOneWidget);
      // 快照同时含 a1 与 b1；当前筛选内的 b1 在前，筛选外的 a1 在后。
      // 不断言多个筛选外题之间的相对顺序（第 4 项范围）。
      expect(confirmSnapshots, isNotEmpty);
      expect(confirmSnapshots.last, ['b1', 'a1']);
    });
  });

  group('50 道上限', () {
    testWidgets('点选第 51 道拒绝 + 提示，选择不变', (tester) async {
      await pumpDirect(
        tester,
        repo: DirectFakeRepo(
          questions: List.generate(
            51,
            // 各题 createdAt 不同：实测 Dart sort 在 51 个全相等比较器下
            // 不保序（q0 会被换到后面），用不同时间让“时间新→旧”顺序确定。
            (i) => dq(
              'q$i',
              createdAt: DateTime(2026, 11, 10).subtract(
                Duration(minutes: i),
              ),
            ),
          ),
        ),
      );
      await openMathListCompact(tester);
      await enterExportMode(tester);
      // 每页 10 道，5 页点满 50 道。
      for (var page = 0; page < 5; page++) {
        for (var i = 0; i < 10; i++) {
          final id = 'q${page * 10 + i}';
          await tapExportRow(tester, id);
        }
        if (page < 4) {
          await tapVisibleText(tester, '下一页');
        }
      }
      expect(summaryNumbers(tester), contains('已选 50 道'));
      // 第 6 页只有 q50，点选被拒绝。
      await tapVisibleText(tester, '下一页');
      await tapExportRow(tester, 'q50');
      await tester.pumpAndSettle();
      expect(find.text('单次最多导出 50 道题'), findsOneWidget);
      expect(summaryNumbers(tester), contains('已选 50 道'));
      expect(isExportSelected(tester, 'q50'), isFalse);
    });
  });

  group('工具栏导出入口与确认步', () {
    testWidgets('点导出进确认步，生成完成后勾选清空', (tester) async {
      await pumpDirect(
        tester,
        repo: DirectFakeRepo(
          questions: [dq('q1'), dq('q2')],
        ),
      );
      await openMathListCompact(tester);
      await enterExportMode(tester);
      await tapExportRow(tester, 'q1');
      await tapExportRow(tester, 'q2');
      await waitForInventory(tester);
      await tester.tap(find.byKey(const Key('export-selected-toolbar')));
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        if (find.text('正在盘点…').evaluate().isEmpty) break;
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump();
      expect(find.text('确认导出'), findsOneWidget);
      expect(find.text('已选 2 道（当前列表共 2 道）'), findsOneWidget);
      await tester.tap(find.byKey(const Key('export-generate')));
      for (var i = 0; i < 10; i++) {
        if (find.text('导出完成').evaluate().isNotEmpty) break;
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump();
      expect(find.text('全部完成'), findsOneWidget);
      // 关闭完成界面：生成已完成，本次勾选清空、退出导出模式。
      // 汇总条只在模式里画，退出后不画；入口回到「导出打印」。
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('export-summary-numbers')), findsNothing);
      expect(find.byKey(const Key('export-mode-cancel')), findsNothing);
      expect(find.text('导出打印'), findsOneWidget);
      expect(isExportSelected(tester, 'q1'), isFalse);
      expect(isExportSelected(tester, 'q2'), isFalse);
    });

    testWidgets('汇总条里的导出按钮同样进确认步', (tester) async {
      await pumpDirect(
        tester,
        repo: DirectFakeRepo(
          questions: [dq('q1')],
        ),
      );
      await openMathListCompact(tester);
      await enterExportMode(tester);
      await tapExportRow(tester, 'q1');
      // 汇总条里的「下一步：选版本与文件名 →」进确认步。
      await tester.tap(find.byKey(const Key('export-next')));
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        if (find.text('正在盘点…').evaluate().isEmpty) break;
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump();
      expect(find.text('确认导出'), findsOneWidget);
    });
  });
}
