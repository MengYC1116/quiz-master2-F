// 十七批 P2（D-208）：错题本导出模式＋点选高亮（widget 测试）。
//
// 覆盖：进模式 / 退模式、模式里点行切换选中＋✓＋蓝底（紧凑行 /
// 大卡片）、模式外点行进详情、退出模式保留已选、工具栏计数更新、
// 两种模式下列表里都没有 Checkbox、跨分页 / 换筛选不丢已选、
// 50 道上限仍拒绝、导出模式与批量模式互斥、从确认步取消回来留
// 在模式里。导出流程控制器用桩（经
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

Question b17q(
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

class B17FakeRepo extends QuestionRepository {
  B17FakeRepo({required this.questions}) : super(AppDatabase.instance);

  List<Question> questions;

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

/// 桩控制器：盘点全部可印、无跳过；生成与交付全部成功。
ExportFlowController b17StubController() {
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
        }) async => defaultInventory(ids),
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

Future<void> pumpB17(
  WidgetTester tester, {
  required B17FakeRepo repo,
  Future<void> Function(Question q, List<String> orderIds)? onOpenDetail,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final ctrl = b17StubController();
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: Scaffold(
        body: WrongbookPage(
          repo: repo,
          exportControllerFactory: () => ctrl,
          onOpenHome: () {},
          onOpenDetail: onOpenDetail ?? (_, __) async {},
          onGoReview: ({String? subjectId}) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> openMathList(WidgetTester tester) async {
  await tester.tap(find.text('数学'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('全部题目'));
  await tester.pumpAndSettle();
}

Future<void> openMathListCompact(WidgetTester tester) async {
  await openMathList(tester);
  await tester.tap(find.text('紧凑列表'));
  await tester.pumpAndSettle();
}

/// 进导出模式（工具栏「导出」平时是进模式的入口）。
Future<void> enterExportMode(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('export-selected-toolbar')));
  await tester.pump();
}

/// 导出模式里点一行切换选中（大卡片点卡片，紧凑行点行）。
Future<void> tapExportRow(
  WidgetTester tester,
  String id, {
  bool large = false,
}) async {
  final finder = find.byKey(
    ValueKey(large ? 'export-card-$id' : 'export-row-$id'),
  );
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(finder);
  await tester.pump();
}

/// 点一个可能在滚动区外的文本按钮（分页器在列表底部，可能在折叠线下）。
Future<void> tapVisibleText(WidgetTester tester, String label) async {
  final finder = find.text(label);
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// 该题是否处于导出选中态（选中行右端的小 ✓ 在不在）。
bool isExportSelected(WidgetTester tester, String id) =>
    find.byKey(ValueKey('export-mark-$id')).evaluate().isNotEmpty;

/// 汇总条数字行文本。
String summaryNumbers(WidgetTester tester) {
  final text = tester.widget<Text>(
    find.byKey(const Key('export-summary-numbers')),
  );
  return text.data ?? '';
}

/// 工具栏导出按钮的 label（平时「导出」，模式里「导出（n）」）。
String toolbarExportLabel(WidgetTester tester) =>
    tester
        .widget<QmButton>(
          find.byKey(const Key('export-selected-toolbar')),
        )
        .label;

void main() {
  group('进模式与退模式', () {
    testWidgets('点工具栏「导出」进模式：出现取消＋提示，导出（0）置灰', (tester) async {
      await pumpB17(
        tester,
        repo: B17FakeRepo(
          questions: [b17q('q1'), b17q('q2')],
        ),
      );
      await openMathListCompact(tester);
      // 平时：工具栏只有「导出」（进模式入口），没有「取消」。
      expect(toolbarExportLabel(tester), '导出');
      expect(find.byKey(const Key('export-mode-cancel')), findsNothing);
      expect(find.byKey(const Key('export-mode-hint')), findsNothing);

      await enterExportMode(tester);
      expect(find.byKey(const Key('export-mode-cancel')), findsOneWidget);
      expect(find.byKey(const Key('export-mode-hint')), findsOneWidget);
      expect(find.text('导出模式：点一行即选中，再点取消选中'), findsOneWidget);
      // n = 0 时模式里的「导出」置灰。
      final btn = tester.widget<QmButton>(
        find.byKey(const Key('export-selected-toolbar')),
      );
      expect(btn.label, '导出');
      expect(btn.onPressed, isNull);
    });

    testWidgets('点「取消」退出模式：工具栏恢复，提示消失', (tester) async {
      await pumpB17(
        tester,
        repo: B17FakeRepo(
          questions: [b17q('q1')],
        ),
      );
      await openMathListCompact(tester);
      await enterExportMode(tester);
      expect(find.byKey(const Key('export-mode-cancel')), findsOneWidget);
      await tester.tap(find.byKey(const Key('export-mode-cancel')));
      await tester.pump();
      expect(find.byKey(const Key('export-mode-cancel')), findsNothing);
      expect(find.byKey(const Key('export-mode-hint')), findsNothing);
      expect(toolbarExportLabel(tester), '导出');
    });

    testWidgets('退出模式保留已选：✓ 与蓝底仍在，再进模式还能看到', (tester) async {
      await pumpB17(
        tester,
        repo: B17FakeRepo(
          questions: [b17q('q1'), b17q('q2')],
        ),
      );
      await openMathListCompact(tester);
      await enterExportMode(tester);
      await tapExportRow(tester, 'q1');
      expect(isExportSelected(tester, 'q1'), isTrue);
      expect(summaryNumbers(tester), contains('已选 1 / 50 道'));

      await tester.tap(find.byKey(const Key('export-mode-cancel')));
      await tester.pump();
      // 退出模式：已选保留（✓ 与蓝底、汇总数都在）。
      expect(isExportSelected(tester, 'q1'), isTrue);
      expect(summaryNumbers(tester), contains('已选 1 / 50 道'));
      final row = tester.widget<Container>(
        find.byKey(const ValueKey('export-row-q1')),
      );
      expect(
        (row.decoration as BoxDecoration?)?.color,
        DesignTokens.of(Brightness.light).accentSoft,
      );
      // 再进模式，之前选的还在；点一下能取消。
      await enterExportMode(tester);
      expect(isExportSelected(tester, 'q1'), isTrue);
      await tapExportRow(tester, 'q1');
      expect(isExportSelected(tester, 'q1'), isFalse);
      expect(summaryNumbers(tester), contains('已选 0 / 50 道'));
    });
  });

  group('模式里点行切换选中', () {
    testWidgets('紧凑行：点行选中出 ✓＋蓝底，再点取消', (tester) async {
      await pumpB17(
        tester,
        repo: B17FakeRepo(
          questions: [b17q('q1'), b17q('q2')],
        ),
      );
      await openMathListCompact(tester);
      await enterExportMode(tester);
      await tapExportRow(tester, 'q1');
      expect(isExportSelected(tester, 'q1'), isTrue);
      expect(summaryNumbers(tester), contains('已选 1 / 50 道'));
      final row = tester.widget<Container>(
        find.byKey(const ValueKey('export-row-q1')),
      );
      expect(
        (row.decoration as BoxDecoration?)?.color,
        DesignTokens.of(Brightness.light).accentSoft,
      );
      // 未选的行无 ✓、不高亮。
      expect(isExportSelected(tester, 'q2'), isFalse);
      await tapExportRow(tester, 'q1');
      expect(isExportSelected(tester, 'q1'), isFalse);
      expect(summaryNumbers(tester), contains('已选 0 / 50 道'));
    });

    testWidgets('大卡片：点卡片选中出 ✓＋蓝底＋主色加粗边框', (tester) async {
      await pumpB17(
        tester,
        repo: B17FakeRepo(
          questions: [b17q('q1'), b17q('q2')],
        ),
      );
      await openMathList(tester);
      await enterExportMode(tester);
      await tapExportRow(tester, 'q1', large: true);
      expect(isExportSelected(tester, 'q1'), isTrue);
      expect(summaryNumbers(tester), contains('已选 1 / 50 道'));
      final card = tester.widget<Container>(
        find.byKey(const ValueKey('export-card-q1')),
      );
      final deco = card.decoration as BoxDecoration?;
      expect(deco?.color, DesignTokens.of(Brightness.light).accentSoft);
      expect(deco?.border?.top.color, DesignTokens.of(Brightness.light).accent);
      expect(deco?.border?.top.width, 2);
      // 未选的卡片无 ✓、边框是细线。
      expect(isExportSelected(tester, 'q2'), isFalse);
      final card2 = tester.widget<Container>(
        find.byKey(const ValueKey('export-card-q2')),
      );
      final deco2 = card2.decoration as BoxDecoration?;
      expect(deco2?.color, DesignTokens.of(Brightness.light).surface);
      expect(deco2?.border?.top.width, 1);
    });

    testWidgets('工具栏计数随选中更新', (tester) async {
      await pumpB17(
        tester,
        repo: B17FakeRepo(
          questions: [b17q('q1'), b17q('q2')],
        ),
      );
      await openMathListCompact(tester);
      await enterExportMode(tester);
      expect(toolbarExportLabel(tester), '导出');
      await tapExportRow(tester, 'q1');
      expect(toolbarExportLabel(tester), '导出（1）');
      await tapExportRow(tester, 'q2');
      expect(toolbarExportLabel(tester), '导出（2）');
      await tapExportRow(tester, 'q1');
      expect(toolbarExportLabel(tester), '导出（1）');
    });
  });

  group('模式外点行进详情', () {
    testWidgets('模式外点行进详情、不选中；模式里点行不进详情', (tester) async {
      Question? opened;
      await pumpB17(
        tester,
        repo: B17FakeRepo(
          questions: [b17q('q1'), b17q('q2')],
        ),
        onOpenDetail: (q, _) async {
          opened = q;
        },
      );
      await openMathListCompact(tester);
      // 模式外点行进详情。
      await tapExportRow(tester, 'q1');
      await tester.pump();
      expect(opened?.id, 'q1');
      expect(isExportSelected(tester, 'q1'), isFalse);
      expect(summaryNumbers(tester), contains('已选 0 / 50 道'));

      // 模式里点行不进详情，只切换选中。
      opened = null;
      await enterExportMode(tester);
      await tapExportRow(tester, 'q2');
      await tester.pump();
      expect(opened, isNull);
      expect(isExportSelected(tester, 'q2'), isTrue);
    });
  });

  group('两种模式下列表里都没有 Checkbox', () {
    testWidgets('平时与模式里：紧凑行与大卡片都没有导出方框', (tester) async {
      await pumpB17(
        tester,
        repo: B17FakeRepo(
          questions: [b17q('q1'), b17q('q2')],
        ),
      );
      await openMathListCompact(tester);
      expect(find.byType(Checkbox), findsNothing);
      await enterExportMode(tester);
      expect(find.byType(Checkbox), findsNothing);
      await tapExportRow(tester, 'q1');
      expect(find.byType(Checkbox), findsNothing);

      // 切大卡片视图：平时与模式里同样没有方框。
      await tester.tap(find.byKey(const Key('export-mode-cancel')));
      await tester.pump();
      await tester.tap(find.text('大卡片'));
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNothing);
      await enterExportMode(tester);
      expect(find.byType(Checkbox), findsNothing);
    });
  });

  group('跨分页 / 换筛选不丢已选', () {
    testWidgets('翻页不丢已选，翻回后 ✓ 与蓝底仍在', (tester) async {
      await pumpB17(
        tester,
        repo: B17FakeRepo(
          questions: List.generate(12, (i) => b17q('q$i')),
        ),
      );
      await openMathListCompact(tester);
      await enterExportMode(tester);
      await tapExportRow(tester, 'q0');
      expect(summaryNumbers(tester), contains('已选 1 / 50 道'));
      await tapVisibleText(tester, '下一页');
      expect(summaryNumbers(tester), contains('已选 1 / 50 道'));
      expect(find.byKey(const ValueKey('export-row-q0')), findsNothing);
      await tapVisibleText(tester, '上一页');
      expect(isExportSelected(tester, 'q0'), isTrue);
      final row = tester.widget<Container>(
        find.byKey(const ValueKey('export-row-q0')),
      );
      expect(
        (row.decoration as BoxDecoration?)?.color,
        DesignTokens.of(Brightness.light).accentSoft,
      );
    });

    testWidgets('换筛选（搜索）不丢已选，搜不到时汇总仍在', (tester) async {
      await pumpB17(
        tester,
        repo: B17FakeRepo(
          questions: [
            b17q('q1', title: '第 q1 题：求极限'),
            b17q('q2', title: '第 q2 题：求导数'),
          ],
        ),
      );
      await openMathListCompact(tester);
      await enterExportMode(tester);
      await tapExportRow(tester, 'q1');
      await tester.enterText(find.byType(TextField).first, '求导数');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('export-row-q1')), findsNothing);
      expect(summaryNumbers(tester), contains('已选 1 / 50 道'));
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pumpAndSettle();
      expect(isExportSelected(tester, 'q1'), isTrue);
    });
  });

  group('50 道上限', () {
    testWidgets('模式里点选第 51 道拒绝＋提示，选择不变', (tester) async {
      await pumpB17(
        tester,
        repo: B17FakeRepo(
          questions: List.generate(
            51,
            (i) => b17q(
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
      for (var page = 0; page < 5; page++) {
        for (var i = 0; i < 10; i++) {
          await tapExportRow(tester, 'q${page * 10 + i}');
        }
        if (page < 4) {
          await tapVisibleText(tester, '下一页');
        }
      }
      expect(summaryNumbers(tester), contains('已选 50 / 50 道'));
      await tapVisibleText(tester, '下一页');
      await tapExportRow(tester, 'q50');
      await tester.pumpAndSettle();
      expect(find.text('单次最多导出 50 道题'), findsOneWidget);
      expect(summaryNumbers(tester), contains('已选 50 / 50 道'));
      expect(isExportSelected(tester, 'q50'), isFalse);
    });
  });

  group('与批量模式互斥', () {
    testWidgets('进批量退导出（已选保留）；进导出退批量（批量勾选清空）', (tester) async {
      await pumpB17(
        tester,
        repo: B17FakeRepo(
          questions: [b17q('q1'), b17q('q2'), b17q('q3')],
        ),
      );
      await openMathListCompact(tester);
      await enterExportMode(tester);
      await tapExportRow(tester, 'q1');
      expect(summaryNumbers(tester), contains('已选 1 / 50 道'));

      // 进批量：导出模式退出，批量条出现，导出已选保留。
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('export-mode-cancel')), findsNothing);
      expect(find.text('全选当前结果'), findsOneWidget);
      expect(isExportSelected(tester, 'q1'), isTrue);
      expect(summaryNumbers(tester), contains('已选 1 / 50 道'));

      // 批量全选 3 道，再进导出模式：批量条消失、批量勾选清空。
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('已选 3 道'), findsOneWidget);
      await tester.tap(find.byKey(const Key('export-selected-toolbar')));
      await tester.pump();
      expect(find.byKey(const Key('export-mode-cancel')), findsOneWidget);
      expect(find.text('全选当前结果'), findsNothing);
      expect(find.text('已选 3 道'), findsNothing);
      // 导出已选不受影响。
      expect(isExportSelected(tester, 'q1'), isTrue);
      expect(summaryNumbers(tester), contains('已选 1 / 50 道'));
    });
  });

  group('确认步取消回来留在模式里', () {
    testWidgets('模式里进确认步点取消：仍在模式里，已选还在', (tester) async {
      await pumpB17(
        tester,
        repo: B17FakeRepo(
          questions: [b17q('q1')],
        ),
      );
      await openMathListCompact(tester);
      await enterExportMode(tester);
      await tapExportRow(tester, 'q1');
      await tester.tap(find.byKey(const Key('export-selected-toolbar')));
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        if (find.text('确认导出').evaluate().isNotEmpty) break;
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump();
      expect(find.text('确认导出'), findsOneWidget);
      // 确认步对话框里的「取消」（工具栏里也有一个「取消」，限定在
      // AlertDialog 内点按）。
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('取消'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('确认导出'), findsNothing);
      expect(find.byKey(const Key('export-mode-cancel')), findsOneWidget);
      expect(isExportSelected(tester, 'q1'), isTrue);
      expect(summaryNumbers(tester), contains('已选 1 / 50 道'));
    });
  });
}
