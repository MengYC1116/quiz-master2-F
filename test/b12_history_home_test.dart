// 十二批功能 4（D-91）：首页历史——首页 widget 测试 + 时间格式单测。
// 覆盖：有记录时显示“最近查看”区（标题、学科名、最后查看时间）、
// 点行进详情（onOpenDetail 回调，orderIds 为列表顺序）、
// 空时整区隐藏；时间格式：今天 / 昨天 / 同年 / 跨年。
// 用 FakeRepo 覆盖 repository 调用（不碰真实数据库，不改口径）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/exam_event.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/home/home_page.dart';
import 'package:quiz_master2/state/home_provider.dart';
import 'package:quiz_master2/theme/app_theme.dart';

class _HistoryFakeRepo extends QuestionRepository {
  _HistoryFakeRepo() : super(AppDatabase.instance);

  List<({Question question, DateTime viewedAt})> historyList = const [];

  @override
  Future<Map<String, int>> homeRevCounts() async => const {};

  @override
  Future<Map<String, int>> pendingOrganizeBySubject() async => const {};

  @override
  Future<({String kind, String subjectId, String title})?> recentTask() async =>
      null;

  @override
  Future<List<Question>> dueToday({bool includeArchived = false}) async =>
      const [];

  @override
  Future<List<CauseRecord>> causeRecords() async => const [];

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<List<ExamEvent>> examEvents() async => const [];

  @override
  Future<List<({Question question, DateTime viewedAt})>>
  recentlyViewedQuestions() async => List.of(historyList);
}

Question _hq(String id, String title, {String subjectId = 'math'}) =>
    Question(
      id: id,
      title: title,
      subjectId: subjectId,
      createdAt: DateTime(2026, 11, 10),
    );

Future<void> _pumpHistoryHome(
  WidgetTester tester, {
  required _HistoryFakeRepo repo,
  void Function(Question question, List<String> orderIds)? onOpenDetail,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      darkTheme: AppTheme.dark(scale: 1.0),
      home: Scaffold(
        body: HomePage(
          repo: repo,
          settings: const AppSettings(),
          onGoCollect: () {},
          onGoOrganize: () {},
          onGoWrongbook: (_) {},
          onGoReview: () {},
          onOpenDetail: onOpenDetail,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('首页“最近查看”区', () {
    testWidgets('有记录时显示：标题、学科名、最后查看时间', (tester) async {
      final now = DateTime.now();
      final viewedAt = DateTime(now.year, now.month, now.day, 9, 30);
      final repo = _HistoryFakeRepo()
        ..historyList = [
          (question: _hq('q-m1', '函数极限'), viewedAt: viewedAt),
          (
            question: _hq('q-e1', '阅读理解', subjectId: 'english'),
            viewedAt: viewedAt.subtract(const Duration(days: 1)),
          ),
        ];
      await _pumpHistoryHome(tester, repo: repo);
      expect(find.text('最近查看'), findsOneWidget);
      expect(find.text('函数极限'), findsOneWidget);
      expect(find.text('阅读理解'), findsOneWidget);
      expect(find.text('数学 · 今天 09:30'), findsOneWidget);
      expect(find.text('英语 · 昨天 09:30'), findsOneWidget);
    });

    testWidgets('点行进详情：回传该题 + 列表顺序的 orderIds', (tester) async {
      final now = DateTime.now();
      final repo = _HistoryFakeRepo()
        ..historyList = [
          (
            question: _hq('q-m1', '函数极限'),
            viewedAt: DateTime(now.year, now.month, now.day, 9, 30),
          ),
          (
            question: _hq('q-m2', '定积分'),
            viewedAt: DateTime(now.year, now.month, now.day, 8, 15),
          ),
        ];
      Question? opened;
      List<String>? openedIds;
      await _pumpHistoryHome(
        tester,
        repo: repo,
        onOpenDetail: (q, ids, {String? searchContext}) {
          opened = q;
          openedIds = ids;
        },
      );
      await tester.tap(find.byKey(const Key('home-history-q-m2')));
      await tester.pumpAndSettle();
      expect(opened?.id, 'q-m2');
      expect(openedIds, ['q-m1', 'q-m2']);
    });

    testWidgets('空时整区隐藏：不显示标题与空状态提示', (tester) async {
      final repo = _HistoryFakeRepo()..historyList = const [];
      await _pumpHistoryHome(tester, repo: repo);
      expect(find.text('最近查看'), findsNothing);
      expect(find.byKey(const Key('home-history-q-m1')), findsNothing);
    });

    testWidgets('已归档的题照常显示（归档显示由详情页自己处理）', (tester) async {
      final now = DateTime.now();
      final repo = _HistoryFakeRepo()
        ..historyList = [
          (
            question: Question(
              id: 'q-a1',
              title: '已归档的题',
              subjectId: 'math',
              createdAt: DateTime(2026, 11, 10),
              isArchived: true,
            ),
            viewedAt: DateTime(now.year, now.month, now.day, 9, 30),
          ),
        ];
      await _pumpHistoryHome(tester, repo: repo);
      expect(find.text('最近查看'), findsOneWidget);
      expect(find.text('已归档的题'), findsOneWidget);
    });
  });

  group('formatRecentlyViewedTime', () {
    test('同一天“今天 HH:mm”', () {
      final now = DateTime(2026, 11, 17, 22, 44);
      expect(
        formatRecentlyViewedTime(DateTime(2026, 11, 17, 9, 5), now: now),
        '今天 09:05',
      );
    });

    test('昨天“昨天 HH:mm”', () {
      final now = DateTime(2026, 11, 17, 22, 44);
      expect(
        formatRecentlyViewedTime(DateTime(2026, 11, 16, 23, 59), now: now),
        '昨天 23:59',
      );
    });

    test('同年其他天“MM-dd HH:mm”', () {
      final now = DateTime(2026, 11, 17, 22, 44);
      expect(
        formatRecentlyViewedTime(DateTime(2026, 11, 10, 8, 0), now: now),
        '11-10 08:00',
      );
    });

    test('跨年带年“yyyy-MM-dd HH:mm”', () {
      final now = DateTime(2026, 11, 17, 22, 44);
      expect(
        formatRecentlyViewedTime(DateTime(2025, 12, 31, 23, 59), now: now),
        '2025-12-31 23:59',
      );
    });
  });
}
