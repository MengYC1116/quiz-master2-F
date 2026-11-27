// R3 首页 widget 测试：焦点卡整卡去复习、继续按钮 stopPropagation、
// 空状态、错误态、亮/深、三档缩放无溢出、页内无边距、底部 4 格按钮。
// 用 FakeRepo 覆盖 repository 调用（不碰真实数据库，不改口径）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/p4_new_release.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/exam_event.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/home/home_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';

class FakeRepo extends QuestionRepository {
  FakeRepo() : super(AppDatabase.instance);

  Map<String, int> rev = {'math': 2, 'english': 1, 'politics': 0};
  Map<String, int> pending = {'math': 1, 'english': 2, 'politics': 0};
  List<String> todayNewIds = ['q-n1'];
  // 2026-11-26 面 C：旧口径桩 due / dueToday() 已随三方法删除而移除；
  // records 仍保留（causeRecords 是现行方法，错因记录仍是复习列表
  // 分组与详情页的线上状态）。
  List<CauseRecord> records = [
    CauseRecord(
      questionId: 'q-m1',
      cause: '概念不清',
      subjectId: 'math',
      joinedAt: DateTime(2026, 11, 10),
    ),
    CauseRecord(
      questionId: 'q-m2',
      cause: '概念不清',
      subjectId: 'math',
      joinedAt: DateTime(2026, 11, 10),
    ),
    CauseRecord(
      questionId: 'q-e1',
      cause: '审题失误',
      subjectId: 'english',
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

  /// SR-P2-48：错误态测试用——设置后 fsrsDueCountsBySubject() 抛错，
  /// 模拟读库失败。
  bool throwOnLoad = false;

  @override
  Future<List<Subject>> subjects() async => subjectsList;

  @override
  Future<Map<String, int>> fsrsDueCountsBySubject({
    required ReviewScheduler scheduler,
    DateTime? now,
  }) async {
    if (throwOnLoad) throw StateError('boom');
    return Map.of(rev);
  }

  @override
  Future<FsrsReleasePlan> previewNewRelease({
    required ReviewScheduler scheduler,
    required int dailyNewLimit,
    DateTime? now,
  }) async => FsrsReleasePlan(
    todaysNewIds: List.of(todayNewIds),
    newlyReleasableIds: const [],
    carryoverIds: const [],
    presentedTodayIds: const [],
    waitingIds: const [],
    presentedTodayCount: 0,
    pendingBacklogCount: 0,
    dailyLimit: dailyNewLimit,
    releaseAllowance: 0,
  );

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  @override
  Future<Map<String, int>> pendingOrganizeBySubject() async => pending;

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<({String kind, String subjectId, String title})?> recentTask() async =>
      recent;

  /// B11-9：考试事件列表（默认空，首页不显示倒计时条）。
  List<ExamEvent> examEventsList = const [];

  @override
  Future<List<ExamEvent>> examEvents() async => examEventsList;

  /// 十二批功能 4（D-91）：最近查看列表（默认空，首页不显示该区；
  /// 不覆盖会走到真实库，fake async 里永不完成、拖死 pumpAndSettle，
  /// 见 D-88）。
  List<({Question question, DateTime viewedAt})> historyList = const [];

  @override
  Future<List<({Question question, DateTime viewedAt})>>
  recentlyViewedQuestions() async => List.of(historyList);
}

/// SR2-61：repo 参数放宽为 QuestionRepository（FakeRepo 是其子类，
/// 现有用例不受影响），真实仓储用例可直接传 QuestionRepository
/// 泵首页，钉住“仓储 → 首页”接线。
/// `settle`：默认 pumpAndSettle；真实仓储用例传 false——首页 `_load`
/// 的 Future.wait 在 FakeAsync 下不完成、加载圈一直转，
/// pumpAndSettle 会超时，调用方改用真实时间驱动（见 SR2-61 用例）。
Future<void> pumpHome(
  WidgetTester tester, {
  QuestionRepository? repo,
  AppSettings settings = const AppSettings(),
  Brightness brightness = Brightness.light,
  double scale = 1.0,
  bool showBackupError = false,
  void Function()? onBackupErrorDismissed,
  void Function()? onGoCollect,
  void Function()? onGoOrganize,
  void Function(String)? onGoWrongbook,
  void Function()? onGoReview,
  bool settle = true,
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
  if (settle) await tester.pumpAndSettle();
}

void main() {
  group('首页正常态', () {
    testWidgets('问候语 + 副标题 + 焦点卡数字与拆分', (tester) async {
      await pumpHome(tester);
      expect(find.text('今天也要加油呀'), findsOneWidget);
      expect(find.text('上次停在：整理工作台 · 数学「函数极限」'), findsOneWidget);
      expect(find.text('3 道到期'), findsOneWidget);
      expect(find.text('到期 3 道 · 今日新题 1 道'), findsOneWidget);
      expect(find.text('继续上次：整理工作台 · 数学「函数极限」'), findsOneWidget);
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
      await tester.tap(find.text('3 道到期'));
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
      expect(find.text('到期 2 道 · 待整理 1 道'), findsOneWidget);
      expect(find.text('到期 1 道 · 待整理 2 道'), findsOneWidget);
      expect(find.text('到期 0 道 · 待整理 0 道'), findsOneWidget);
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

    testWidgets('无今日新题时小字只写到期', (tester) async {
      final repo = FakeRepo()
        ..todayNewIds = []
        ..rev = {'math': 1, 'english': 0, 'politics': 0};
      await pumpHome(tester, repo: repo);
      expect(find.text('1 道到期'), findsOneWidget);
      expect(find.text('到期 1 道'), findsOneWidget);
      expect(find.textContaining('今日新题'), findsNothing);
    });

    testWidgets('只有今日新题、到期为 0：出正常卡，不走空状态', (tester) async {
      final repo = FakeRepo()
        ..todayNewIds = ['q-n1', 'q-n2']
        ..rev = {'math': 0, 'english': 0, 'politics': 0};
      await pumpHome(tester, repo: repo);
      expect(find.text('0 道到期'), findsOneWidget);
      expect(find.text('到期 0 道 · 今日新题 2 道'), findsOneWidget);
      expect(find.text('今天没有到期的题，明天再来吧'), findsNothing);
      expect(find.byKey(const Key('home-focus-card')), findsOneWidget);
    });
  });

  group('首页空状态与无最近任务', () {
    testWidgets('无到期也无今日新题：中性卡片 + 空状态文案，不可点去复习', (tester) async {
      var review = 0;
      final repo = FakeRepo()
        ..todayNewIds = []
        ..rev = {'math': 0, 'english': 0, 'politics': 0}
        ..recent = null;
      await pumpHome(tester, repo: repo, onGoReview: () => review++);
      expect(find.text('今天没有到期的题，明天再来吧'), findsOneWidget);
      expect(
        find.text('到期 0 道 · 今日新题 0 道'),
        findsOneWidget,
      );
      expect(find.text('今天休息一下'), findsOneWidget);
      expect(find.byKey(const Key('home-focus-card')), findsNothing);
      expect(find.text('上次停在：还没有记录'), findsOneWidget);
      await tester.tap(find.text('今天没有到期的题，明天再来吧'));
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
        ..todayNewIds = []
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

    testWidgets('SR-P2-48 读库失败出错误横幅；重试失败仍在，成功后恢复',
        (tester) async {
      final repo = FakeRepo();
      repo.throwOnLoad = true;
      await pumpHome(tester, repo: repo);
      expect(find.textContaining('首页数据读取失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('3 道到期'), findsNothing);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.textContaining('首页数据读取失败'), findsOneWidget);
      repo.throwOnLoad = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('3 道到期'), findsOneWidget);
    });
  });
}
