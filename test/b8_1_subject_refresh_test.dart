// B8-1：删学科后残留刷新回归（Meng Win11 真机验收 image-89 / 90 / 98）。
//
// 根因：各页 `_load()` 与外壳 `_refreshBadges()` 在 subjects 表为空时
// 回退 `Subject.all` 预设三科——新库建表时已预置三科（db_schema `_seed`），
// 表空只发生在用户删光学科后，回退就是幽灵行/幽灵下拉项/幽灵书。
// 修法：空表就是空（各页直接用库里的列表）；删学科已 bump badgeVersion
//（`deleteSubject`），外壳经监听即时刷新，无需新通道。
// 用 FakeRepo，不碰真实数据库；无文件 IO。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/exam_event.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/collect/collect_page.dart';
import 'package:quiz_master2/modules/home/home_page.dart';
import 'package:quiz_master2/modules/wrongbook/wrongbook_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/app_shell.dart';
import 'package:quiz_master2/widgets/uikit.dart';

/// B8-1 测试用 FakeRepo：学科列表可配（含空表），其余全返回空。
class _B8FakeRepo extends QuestionRepository {
  _B8FakeRepo({List<Subject>? subjects})
      : subjectsValue = subjects ?? Subject.all,
        super(AppDatabase.instance);

  List<Subject> subjectsValue;

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);

  @override
  Future<List<CollectTask>> collectTasks() async => const [];

  @override
  Future<List<QuestionBox>> boxesForTask(String taskId) async => const [];

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      const [];

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [];

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<String>> tags() async => const [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<Map<String, (int, int, int)>> subjectCounts(
          {bool includeArchived = false}) async =>
      const {};

  @override
  Future<List<CauseRecord>> causeRecords() async => const [];

  @override
  Future<AppSettings> settings() async => const AppSettings();

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

  /// B11-9：考试事件列表（默认空，首页不显示倒计时条；不覆盖会走到
  /// 真实库——旧 Fake 必须补这一行，见 B11-9 报告 §6）。
  @override
  Future<List<ExamEvent>> examEvents() async => const [];
}

Future<void> _pumpNav(
  WidgetTester tester, {
  List<Subject>? subjects,
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
        body: SizedBox(
          height: 720,
          child: AppNavBar(
            route: '/home',
            collapsed: false,
            onNavigate: (_) {},
            onToggleCollapsed: () {},
            subjects: subjects,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpPage(
  WidgetTester tester,
  Widget page,
) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      darkTheme: AppTheme.dark(scale: 1.0),
      home: Scaffold(body: page),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('B8-1 左导航速览：删空后不再出现已删学科', () {
    testWidgets('学科表为空：速览无任何学科行，标题与设置仍在', (tester) async {
      await _pumpNav(tester, subjects: const []);
      for (final name in ['数学', '英语', '政治']) {
        expect(find.text(name), findsNothing);
      }
      expect(find.text('待整理 0 · 待复习 0'), findsNothing);
      expect(find.text('学科速览'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('只删一科：速览只剩其余两科', (tester) async {
      await _pumpNav(tester, subjects: [Subject.english, Subject.politics]);
      expect(find.text('数学'), findsNothing);
      expect(find.text('英语'), findsOneWidget);
      expect(find.text('政治'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('B8-1 纠正：速览块底部锚定，最后一行底边紧贴设置按钮顶边（无空隙）',
        (tester) async {
      await _pumpNav(tester, subjects: Subject.all);
      // 行区（shrinkWrap，按内容定高）底边 == 设置按钮顶边：
      // 中间没有 Expanded 撑出来的空段，也没有 Padding 间隙。
      final scrollBottom = tester
          .getRect(find.byKey(const ValueKey('qm-nav-subject-scroll')))
          .bottom;
      final buttonTop = tester.getRect(find.byType(QmButton)).top;
      expect(buttonTop - scrollBottom, closeTo(0, 1.0));
      // 空出来的地方在速览块上方：标题离学科管理行有一大段空，
      // 而不是速览与设置之间有空。
      final manageBottom = tester.getRect(find.text('学科管理')).bottom;
      final titleTop = tester.getRect(find.text('学科速览')).top;
      expect(titleTop - manageBottom, greaterThan(20));
      expect(tester.takeException(), isNull);
    });

    testWidgets('B8-1 纠正：学科删空时速览标题也紧贴设置按钮', (tester) async {
      await _pumpNav(tester, subjects: const []);
      final scrollBottom = tester
          .getRect(find.byKey(const ValueKey('qm-nav-subject-scroll')))
          .bottom;
      final buttonTop = tester.getRect(find.byType(QmButton)).top;
      expect(buttonTop - scrollBottom, closeTo(0, 1.0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('顺序：学科管理 < 学科速览 < 设置（设置最末一位）',
        (tester) async {
      await _pumpNav(tester, subjects: Subject.all);
      final manageY = tester.getCenter(find.text('学科管理')).dy;
      final quickY = tester.getCenter(find.text('学科速览')).dy;
      final settingsY = tester.getCenter(find.text('设置')).dy;
      expect(manageY, lessThan(quickY));
      expect(quickY, lessThan(settingsY));
      // 设置固定在导航底部：不随速览滚动区滚动（不在滚动区子树内）。
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('qm-nav-subject-scroll')),
          matching: find.text('设置'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('B8-1 收集中心：学科删空后下拉不再出现已删学科', () {
    testWidgets('学科表为空：下拉提示“还没有学科”，点不开幽灵项',
        (tester) async {
      var wentToSubjects = false;
      await _pumpPage(
        tester,
        CollectPage(
          repo: _B8FakeRepo(subjects: const []),
          onOpenOrganize: () {},
          onGoSubjects: () => wentToSubjects = true,
        ),
      );
      expect(find.text('还没有学科'), findsOneWidget);
      expect(
        find.text('还没有学科：先去「学科管理」添加一个，再回来导入。'),
        findsOneWidget,
      );
      // 下拉已禁用：点它不会弹出数学/英语/政治。
      await tester.tap(find.byKey(const Key('collect-subject-select')));
      await tester.pumpAndSettle();
      for (final name in ['数学', '英语', '政治']) {
        expect(find.text(name), findsNothing);
      }
      // 去学科管理按钮可用。
      await tester.tap(find.text('去学科管理'));
      expect(wentToSubjects, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('学科表非空：下拉仍能选到学科（正常路径未破坏）',
        (tester) async {
      await _pumpPage(
        tester,
        CollectPage(
          repo: _B8FakeRepo(),
          onOpenOrganize: () {},
        ),
      );
      expect(find.text('请选择学科'), findsOneWidget);
      await tester.tap(find.byKey(const Key('collect-subject-select')));
      await tester.pumpAndSettle();
      expect(find.text('数学'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('B8-1 错题本书架：学科删空后不再出现已删学科的书', () {
    testWidgets('学科表为空：书架无书，给空状态 + 去学科管理',
        (tester) async {
      var wentToSubjects = false;
      await _pumpPage(
        tester,
        WrongbookPage(
          repo: _B8FakeRepo(subjects: const []),
          onOpenHome: () {},
          onGoSubjects: () => wentToSubjects = true,
          onOpenDetail: (_, __) async {},
          onGoReview: ({String? subjectId}) {},
        ),
      );
      for (final name in ['数学', '英语', '政治']) {
        expect(find.text(name), findsNothing);
      }
      expect(find.text('还没有学科'), findsOneWidget);
      expect(find.text('先去学科管理添加一个吧。'), findsOneWidget);
      expect(find.text('共 3 本'), findsNothing);
      await tester.tap(find.text('去学科管理'));
      expect(wentToSubjects, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('学科表非空：三本书仍在（正常路径未破坏）', (tester) async {
      await _pumpPage(
        tester,
        WrongbookPage(
          repo: _B8FakeRepo(),
          onOpenHome: () {},
          onOpenDetail: (_, __) async {},
          onGoReview: ({String? subjectId}) {},
        ),
      );
      for (final name in ['数学', '英语', '政治']) {
        expect(find.text(name), findsOneWidget);
      }
      expect(find.text('还没有学科'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('B8-1 首页：学科删空后学科格不再出现已删学科', () {
    testWidgets('学科表为空：只有快速收集格，无学科格', (tester) async {
      await _pumpPage(
        tester,
        HomePage(
          repo: _B8FakeRepo(subjects: const []),
          settings: const AppSettings(),
          onGoCollect: () {},
          onGoOrganize: () {},
          onGoWrongbook: (_) {},
          onGoReview: () {},
        ),
      );
      expect(find.text('快速收集'), findsOneWidget);
      for (final name in ['数学', '英语', '政治']) {
        expect(find.text(name), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('学科表非空：三科格仍在（正常路径未破坏）', (tester) async {
      await _pumpPage(
        tester,
        HomePage(
          repo: _B8FakeRepo(),
          settings: const AppSettings(),
          onGoCollect: () {},
          onGoOrganize: () {},
          onGoWrongbook: (_) {},
          onGoReview: () {},
        ),
      );
      for (final name in ['数学', '英语', '政治']) {
        expect(find.text(name), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  });
}
