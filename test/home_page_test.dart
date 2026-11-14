// R3 首页 widget 测试：焦点卡整卡去复习、继续按钮 stopPropagation、
// 空状态、错误态、亮/深、三档缩放无溢出、页内无边距、底部 4 格按钮。
// 用 FakeRepo 覆盖 repository 调用（不碰真实数据库，不改口径）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/home/home_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';

class FakeRepo extends QuestionRepository {
  FakeRepo() : super(AppDatabase.instance);

  Map<String, int> rev = {'math': 2, 'english': 1, 'politics': 0};
  Map<String, int> pending = {'math': 1, 'english': 2, 'politics': 0};
  List<Question> due = [
    Question(
      id: 'q-m1',
      title: '函数极限',
      subjectId: 'math',
      isOrganized: true,
      reviewJoined: true,
      createdAt: DateTime(2026, 11, 10),
    ),
    Question(
      id: 'q-m2',
      title: '定积分',
      subjectId: 'math',
      isOrganized: true,
      reviewJoined: true,
      createdAt: DateTime(2026, 11, 10),
    ),
    Question(
      id: 'q-e1',
      title: '阅读理解',
      subjectId: 'english',
      isOrganized: true,
      reviewJoined: true,
      createdAt: DateTime(2026, 11, 10),
    ),
  ];
  List<CauseRecord> records = [
    CauseRecord(
      questionId: 'q-m1',
      cause: '概念不清',
      subjectId: 'math',
      status: CauseStatus.pending,
      joinedAt: DateTime(2026, 11, 10),
    ),
    CauseRecord(
      questionId: 'q-m2',
      cause: '概念不清',
      subjectId: 'math',
      status: CauseStatus.solved,
      solvedCount: 2,
      recheckDate: DateTime.now().subtract(const Duration(days: 1)),
      joinedAt: DateTime(2026, 11, 10),
    ),
    CauseRecord(
      questionId: 'q-e1',
      cause: '审题失误',
      subjectId: 'english',
      status: CauseStatus.pending,
      joinedAt: DateTime(2026, 11, 10),
    ),
  ];
  ({String kind, String subjectId, String title})? recent = (
    kind: '整理',
    subjectId: 'math',
    title: '函数极限',
  );

  /// B2：首页改读库后，_load 会调 subjects()；测试里用内存列表，
  /// 不碰真实数据库。
  List<Subject> subjectsList = Subject.all;

  @override
  Future<List<Subject>> subjects() async => subjectsList;

  @override
  Future<Map<String, int>> homeRevCounts() async => rev;

  @override
  Future<Map<String, int>> pendingOrganizeBySubject() async => pending;

  @override
  Future<({String kind, String subjectId, String title})?> recentTask() async =>
      recent;

  @override
  Future<List<Question>> dueToday({bool includeArchived = false}) async => due;

  @override
  Future<List<CauseRecord>> causeRecords() async => records;
}

Future<void> pumpHome(
  WidgetTester tester, {
  FakeRepo? repo,
  AppSettings settings = const AppSettings(),
  Brightness brightness = Brightness.light,
  double scale = 1.0,
  bool showBackupError = false,
  void Function()? onBackupErrorDismissed,
  void Function()? onGoCollect,
  void Function()? onGoOrganize,
  void Function(String)? onGoWrongbook,
  void Function()? onGoReview,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: scale),
      darkTheme: AppTheme.dark(scale: scale),
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      home: Builder(
        builder: (context) {
          final data = MediaQuery.of(context);
          return MediaQuery(
            data: data.copyWith(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: HomePage(
                repo: repo ?? FakeRepo(),
                settings: settings,
                onGoCollect: onGoCollect ?? () {},
                onGoOrganize: onGoOrganize ?? () {},
                onGoWrongbook: onGoWrongbook ?? (_) {},
                onGoReview: onGoReview ?? () {},
                showBackupError: showBackupError,
                onBackupErrorDismissed: onBackupErrorDismissed,
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('首页正常态', () {
    testWidgets('问候语 + 副标题 + 焦点卡数字与拆分', (tester) async {
      await pumpHome(tester);
      expect(find.text('今天也要加油呀'), findsOneWidget);
      expect(find.text('上次停在：整理工作台 · 数学「函数极限」'), findsOneWidget);
      expect(find.text('3 道要复习'), findsOneWidget);
      expect(find.text('待解决 2 道 · 复查 1 道'), findsOneWidget);
      expect(find.text('继续上次：整理工作台 · 数学「函数极限」'), findsOneWidget);
      expect(find.text('上次停在待整理队列的这道题'), findsOneWidget);
      expect(find.text('继续上次'), findsOneWidget);
    });

    testWidgets('自定义问候语取自设置', (tester) async {
      await pumpHome(
        tester,
        settings: const AppSettings(greeting: '明天也要加油呀'),
      );
      expect(find.text('明天也要加油呀'), findsOneWidget);
    });

    testWidgets('点焦点卡数字去复习', (tester) async {
      var review = 0;
      var organize = 0;
      await pumpHome(
        tester,
        onGoReview: () => review++,
        onGoOrganize: () => organize++,
      );
      await tester.tap(find.text('3 道要复习'));
      await tester.pumpAndSettle();
      expect(review, 1);
      expect(organize, 0);
    });

    testWidgets('点「继续上次」只走最近任务，不触发整卡去复习', (tester) async {
      var review = 0;
      var organize = 0;
      await pumpHome(
        tester,
        onGoReview: () => review++,
        onGoOrganize: () => organize++,
      );
      await tester.tap(find.text('继续上次'));
      await tester.pumpAndSettle();
      expect(organize, 1);
      expect(review, 0);
    });

    testWidgets('下方 4 格：快速收集 + 三科数字与按钮', (tester) async {
      var collect = 0;
      String? wrongbookSubject;
      var review = 0;
      await pumpHome(
        tester,
        onGoCollect: () => collect++,
        onGoWrongbook: (s) => wrongbookSubject = s,
        onGoReview: () => review++,
      );
      expect(find.text('快速收集与各学科待复习概览'), findsOneWidget);
      expect(find.text('快速收集'), findsOneWidget);
      expect(find.text('要复习 2 道 · 待整理 1 道'), findsOneWidget);
      expect(find.text('要复习 1 道 · 待整理 2 道'), findsOneWidget);
      expect(find.text('要复习 0 道 · 待整理 0 道'), findsOneWidget);
      await tester.tap(find.text('去收集中心'));
      await tester.pumpAndSettle();
      expect(collect, 1);
      await tester.tap(find.text('错题本').first);
      await tester.pumpAndSettle();
      expect(wrongbookSubject, 'math');
      await tester.tap(find.text('去复习').first);
      await tester.pumpAndSettle();
      expect(review, 1);
    });

    testWidgets('无复查时明细只写待解决', (tester) async {
      final repo = FakeRepo()
        ..due = [FakeRepo().due.first]
        ..records = [FakeRepo().records.first]
        ..rev = {'math': 1, 'english': 0, 'politics': 0};
      await pumpHome(tester, repo: repo);
      expect(find.text('1 道要复习'), findsOneWidget);
      expect(find.text('待解决 1 道'), findsOneWidget);
      expect(find.textContaining('复查'), findsNothing);
    });
  });

  group('首页空状态与无最近任务', () {
    testWidgets('无要复习：中性卡片 + 空状态文案，不可点去复习', (tester) async {
      var review = 0;
      final repo = FakeRepo()
        ..due = []
        ..records = []
        ..rev = {'math': 0, 'english': 0, 'politics': 0}
        ..recent = null;
      await pumpHome(tester, repo: repo, onGoReview: () => review++);
      expect(find.text('今天没有要复习的，明天再来吧'), findsOneWidget);
      expect(
        find.text('要复习 0 道 · 没有待解决的错因，也没有到复查时间的题'),
        findsOneWidget,
      );
      expect(find.text('今天休息一下'), findsOneWidget);
      expect(find.byKey(const Key('home-focus-card')), findsNothing);
      expect(find.text('上次停在：还没有记录'), findsOneWidget);
      await tester.tap(find.text('今天没有要复习的，明天再来吧'));
      await tester.pumpAndSettle();
      expect(review, 0);
    });

    testWidgets('无最近任务：继续条 fallback 为去收集', (tester) async {
      var collect = 0;
      var review = 0;
      final repo = FakeRepo()..recent = null;
      await pumpHome(
        tester,
        repo: repo,
        onGoCollect: () => collect++,
        onGoReview: () => review++,
      );
      expect(find.text('继续上次：还没有记录'), findsOneWidget);
      expect(find.text('先去收集第一道题吧'), findsOneWidget);
      await tester.tap(find.text('去收集'));
      await tester.pumpAndSettle();
      expect(collect, 1);
      expect(review, 0);
    });
  });

  group('首页错误态', () {
    testWidgets('手动备份失败：顶部红色横幅，可点「知道了」关闭', (tester) async {
      await pumpHome(tester, showBackupError: true);
      expect(find.text(HomePage.backupFailedMessage), findsOneWidget);
      expect(find.byType(QmBanner), findsOneWidget);
      final banner =
          tester.widget<QmBanner>(find.byType(QmBanner));
      expect(banner.tone, QmBannerTone.error);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.text(HomePage.backupFailedMessage), findsNothing);
    });

    testWidgets('待定3：点「知道了」调 onBackupErrorDismissed（应用层清标志）',
        (tester) async {
      var dismissed = 0;
      await pumpHome(
        tester,
        showBackupError: true,
        onBackupErrorDismissed: () => dismissed++,
      );
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(dismissed, 1);
      expect(find.text(HomePage.backupFailedMessage), findsNothing);
    });

    testWidgets('平时不显示错误横幅', (tester) async {
      await pumpHome(tester);
      expect(find.byType(QmBanner), findsNothing);
    });
  });

  group('首页亮/深与缩放', () {
    testWidgets('亮色焦点卡底色为 accentSoft', (tester) async {
      await pumpHome(tester, brightness: Brightness.light);
      final container = tester.widget<Container>(
        find.byKey(const Key('home-focus-card-body')),
      );
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, DesignTokens.light.accentSoft);
      expect(decoration.border?.top.color, DesignTokens.light.accent);
    });

    testWidgets('深色焦点卡底色为 accentSoft', (tester) async {
      await pumpHome(tester, brightness: Brightness.dark);
      final container = tester.widget<Container>(
        find.byKey(const Key('home-focus-card-body')),
      );
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, DesignTokens.dark.accentSoft);
      expect(decoration.border?.top.color, DesignTokens.dark.accent);
    });

    testWidgets('亮/深 × 三档缩放无溢出', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        for (final scale in [1.0, 1.15, 1.3]) {
          await pumpHome(tester, brightness: brightness, scale: scale);
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets('空状态 × 三档缩放无溢出', (tester) async {
      final repo = FakeRepo()
        ..due = []
        ..records = []
        ..rev = {'math': 0, 'english': 0, 'politics': 0}
        ..recent = null;
      for (final scale in [1.0, 1.15, 1.3]) {
        await pumpHome(tester, repo: repo, scale: scale);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('页内无边距：SingleChildScrollView padding 为零', (tester) async {
      await pumpHome(tester);
      final scrollView = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView).first,
      );
      expect(scrollView.padding, EdgeInsets.zero);
    });

    testWidgets('首页不用图标字体', (tester) async {
      await pumpHome(tester);
      expect(find.byType(Icon), findsNothing);
    });
  });
}
