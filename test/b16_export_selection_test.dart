// 十六批 B（D-190）：导出勾选状态（Notifier 层，不启动 widget）。
//
// 覆盖：勾选 / 取消勾选、50 道上限拒绝（点选第 51 道返回
// “单次最多导出 50 道题”，选择不变）、清除、换筛选不丢已选、
// 题目从库里消失时 load() 收敛、与批量 selected 互不干扰。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/wrongbook/wrongbook_page.dart';
import 'package:quiz_master2/services/pdf_export/content_guard.dart';
import 'package:quiz_master2/services/pdf_export/export_flow.dart';
import 'package:quiz_master2/services/pdf_export/export_inventory.dart';
import 'package:quiz_master2/services/pdf_export/export_route.dart';
import 'package:quiz_master2/services/pdf_export/export_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/export_versions.dart';
import 'package:quiz_master2/services/pdf_export/pdf_delivery.dart';
import 'package:quiz_master2/services/pdf_export/pdf_export_service.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/state/wrongbook_notifier.dart';
import 'package:quiz_master2/theme/app_theme.dart';

Question _eq(
  String id, {
  String subjectId = 'math',
  List<String> folderIds = const ['f1'],
  DateTime? createdAt,
  String? title,
}) => Question(
  id: id,
  title: title ?? '题 $id',
  subjectId: subjectId,
  folderIds: folderIds,
  errorTypes: const ['概念不清'],
  createdAt: createdAt ?? DateTime(2026, 11, 10),
  isOrganized: true,
  sliceKind: 'material',
  sliceText: '题',
);

class B16FakeRepo extends QuestionRepository {
  B16FakeRepo({required this.questions}) : super(AppDatabase.instance);

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

Future<(B16FakeRepo, WrongbookNotifier, ProviderContainer)> _setUp({
  List<Question>? questions,
}) async {
  final repo = B16FakeRepo(
    questions: questions ?? [_eq('q1'), _eq('q2'), _eq('q3')],
  );
  final container = ProviderContainer.test(
    overrides: [
      repositoryProvider.overrideWithValue(repo),
      wrongbookInitialProvider.overrideWithValue(
        const WrongbookInitial(subjectId: 'math', filterCause: null),
      ),
    ],
  );
  final notifier = container.read(wrongbookProvider.notifier);
  await notifier.load();
  return (repo, notifier, container);
}

/// D-206 widget 测试用最小桩控制器：只实现后台盘点（勾选后 300ms
/// 防抖触发）；生成 / 交付本组测试不走到，调到即抛错。
ExportFlowController _stubSelectionController() {
  return ExportFlowController(
    computeInventory:
        ({
          required List<String> ids,
          required List<ExcludedQuestion> excluded,
          required int circledCount,
        }) async => ExportInventory(
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
        ),
    generateVersions: _neverGenerate,
    deliverAll: _neverDeliver,
  );
}

Future<TwoVersionExportResult> _neverGenerate({
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
}) => throw UnimplementedError('D-206 测试不走到生成');

Future<List<FileDeliveryResult>> _neverDeliver({
  required List<VersionDeliveryRequest> requests,
}) => throw UnimplementedError('D-206 测试不走到交付');

Future<void> _pumpSelection(
  WidgetTester tester, {
  required B16FakeRepo repo,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: Scaffold(
        body: WrongbookPage(
          repo: repo,
          exportControllerFactory: _stubSelectionController,
          onOpenHome: () {},
          onOpenDetail: (_, __) async {},
          onGoReview: ({String? subjectId}) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openMathListCompact(WidgetTester tester) async {
  await tester.tap(find.text('数学'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('全部题目'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('紧凑列表'));
  await tester.pumpAndSettle();
}

Future<void> _tapCheck(WidgetTester tester, String id) async {
  final finder = find.byKey(ValueKey('export-check-$id'));
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(finder);
  await tester.pump();
}

void main() {
  group('50 道上限纯口径 checkSelectionCap', () {
    test('50 道放行，51 道拒绝并给出文案', () {
      expect(
        checkSelectionCap(List.generate(50, (i) => 'q$i')).allowed,
        isTrue,
      );
      final over = checkSelectionCap(List.generate(51, (i) => 'q$i'));
      expect(over.allowed, isFalse);
      expect(over.reason, '单次最多导出 50 道题');
    });
  });

  group('导出勾选 toggleExportSelected', () {
    test('勾选 / 取消勾选，汇总数跟着变', () async {
      final (_, notifier, container) = await _setUp();
      addTearDown(container.dispose);
      expect(notifier.toggleExportSelected('q1'), isNull);
      expect(
        container.read(wrongbookProvider).exportSelected,
        {'q1'},
      );
      expect(notifier.toggleExportSelected('q2'), isNull);
      expect(
        container.read(wrongbookProvider).exportSelected,
        {'q1', 'q2'},
      );
      expect(notifier.toggleExportSelected('q1'), isNull);
      expect(
        container.read(wrongbookProvider).exportSelected,
        {'q2'},
      );
    });

    test('点选第 51 道拒绝 + 提示，选择不变；腾出位置后可再选', () async {
      final questions = List.generate(51, (i) => _eq('q$i'));
      final (_, notifier, container) = await _setUp(questions: questions);
      addTearDown(container.dispose);
      for (var i = 0; i < 50; i++) {
        expect(notifier.toggleExportSelected('q$i'), isNull);
      }
      expect(
        container.read(wrongbookProvider).exportSelected.length,
        50,
      );
      expect(
        notifier.toggleExportSelected('q50'),
        '单次最多导出 50 道题',
      );
      expect(
        container.read(wrongbookProvider).exportSelected.length,
        50,
      );
      expect(
        container.read(wrongbookProvider).exportSelected.contains('q50'),
        isFalse,
      );
      expect(notifier.toggleExportSelected('q0'), isNull);
      expect(notifier.toggleExportSelected('q50'), isNull);
      expect(
        container.read(wrongbookProvider).exportSelected.length,
        50,
      );
    });

    test('清除选择', () async {
      final (_, notifier, container) = await _setUp();
      addTearDown(container.dispose);
      notifier.toggleExportSelected('q1');
      notifier.toggleExportSelected('q2');
      notifier.clearExportSelected();
      expect(
        container.read(wrongbookProvider).exportSelected,
        isEmpty,
      );
    });

    test('逐个取消（汇总清单用）', () async {
      final (_, notifier, container) = await _setUp();
      addTearDown(container.dispose);
      notifier.toggleExportSelected('q1');
      notifier.toggleExportSelected('q2');
      notifier.removeExportSelected('q1');
      expect(
        container.read(wrongbookProvider).exportSelected,
        {'q2'},
      );
      // 取消不存在的题是空操作，不抛错。
      notifier.removeExportSelected('q9');
      expect(
        container.read(wrongbookProvider).exportSelected,
        {'q2'},
      );
    });
  });

  group('翻页 / 换筛选不丢已选；与批量选择互不干扰', () {
    test('换筛选（applyFilterChange）只收敛批量 selected，不动 exportSelected', () async {
      final (_, notifier, container) = await _setUp();
      addTearDown(container.dispose);
      notifier.toggleExportSelected('q1');
      notifier.toggleSelected('q1', true);
      // 设一个筛掉 q1 的错因筛选（q1 只有“概念不清”）。
      notifier.setFilterErrorType('计算错误');
      final s = container.read(wrongbookProvider);
      expect(s.exportSelected, {'q1'});
      expect(s.selected, isEmpty);
    });

    test('题目从库里消失时 load() 收敛 exportSelected', () async {
      final (repo, notifier, container) = await _setUp();
      addTearDown(container.dispose);
      notifier.toggleExportSelected('q1');
      notifier.toggleExportSelected('q2');
      repo.questions.removeWhere((q) => q.id == 'q1');
      await notifier.load();
      expect(
        container.read(wrongbookProvider).exportSelected,
        {'q2'},
      );
    });

    test('批量操作清 selected 时不动 exportSelected', () async {
      final (_, notifier, container) = await _setUp();
      addTearDown(container.dispose);
      notifier.toggleExportSelected('q1');
      notifier.toggleSelected('q1', true);
      notifier.update((st) => st.copyWith(selected: const <String>{}));
      final s = container.read(wrongbookProvider);
      expect(s.exportSelected, {'q1'});
      expect(s.selected, isEmpty);
    });
  });

  group('筛选外已选题相对顺序（D-206：确定性次键）', () {
    testWidgets('筛选外已选题按 createdAt 降序，筛选内的仍在前', (tester) async {
      await _pumpSelection(
        tester,
        repo: B16FakeRepo(
          questions: [
            _eq(
              'qIn',
              title: '第 qIn 题：求导数',
              createdAt: DateTime(2026, 11, 1),
            ),
            _eq(
              'qOld',
              title: '第 qOld 题：求极限',
              createdAt: DateTime(2026, 11, 8),
            ),
            _eq(
              'qMid',
              title: '第 qMid 题：求极限',
              createdAt: DateTime(2026, 11, 9),
            ),
            _eq(
              'qNew',
              title: '第 qNew 题：求极限',
              createdAt: DateTime(2026, 11, 10),
            ),
          ],
        ),
      );
      await _openMathListCompact(tester);
      await _tapCheck(tester, 'qIn');
      await _tapCheck(tester, 'qOld');
      await _tapCheck(tester, 'qMid');
      await _tapCheck(tester, 'qNew');
      // 搜一个只命中 qIn 的词，其余三道从当前筛选消失。
      await tester.enterText(find.byType(TextField).first, '求导数');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('export-check-qOld')), findsNothing);
      // 汇总清单题号即 _exportSelectedQuestions 的顺序。
      await tester.tap(find.byKey(const Key('export-summary-numbers')));
      await tester.pump();
      expect(find.text('1. 第 qIn 题：求导数'), findsOneWidget);
      expect(find.text('2. 第 qNew 题：求极限'), findsOneWidget);
      expect(find.text('3. 第 qMid 题：求极限'), findsOneWidget);
      expect(find.text('4. 第 qOld 题：求极限'), findsOneWidget);
    });

    testWidgets('createdAt 相同时按 id 升序，与入库顺序无关', (tester) async {
      await _pumpSelection(
        tester,
        repo: B16FakeRepo(
          questions: [
            // 故意把 qB 放 qA 前面：入库顺序不得影响题号顺序。
            _eq(
              'qB',
              title: '第 qB 题：求极限',
              createdAt: DateTime(2026, 11, 9),
            ),
            _eq(
              'qA',
              title: '第 qA 题：求极限',
              createdAt: DateTime(2026, 11, 9),
            ),
            _eq(
              'qIn',
              title: '第 qIn 题：求导数',
              createdAt: DateTime(2026, 11, 1),
            ),
          ],
        ),
      );
      await _openMathListCompact(tester);
      await _tapCheck(tester, 'qB');
      await _tapCheck(tester, 'qA');
      await _tapCheck(tester, 'qIn');
      await tester.enterText(find.byType(TextField).first, '求导数');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('export-summary-numbers')));
      await tester.pump();
      expect(find.text('1. 第 qIn 题：求导数'), findsOneWidget);
      expect(find.text('2. 第 qA 题：求极限'), findsOneWidget);
      expect(find.text('3. 第 qB 题：求极限'), findsOneWidget);
    });
  });
}
