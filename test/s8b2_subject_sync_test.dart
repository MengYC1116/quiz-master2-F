// S8 B2：新增学科同步首页 / 导航（导航速览最多 5 科）+ subjectInk /
// subjectSoft 的存色回退。
// - 首页：库里 subjects 表有第 4、第 6 个学科时，全部学科格都出现，
//   数字取 FakeRepo 的计数 map（含新学科 id 的键）。
// - 导航：传 6 科只显示前 5 科（入库顺序），传 4 科全显示。
// - 颜色：非预设学科的 ink / soft 不等于数学色；预设三科传了存色
//   也仍走主题固定色。
// 用 FakeRepo，不碰真实数据库。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/home/home_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/app_shell.dart';

/// B2 测试用的学科：预设三科 + 化学（紫，轮换表第 4 位）+
/// 历史（橙，轮换表第 5 位）+ 地理（青，与预设色均不同）。
final _chem = Subject(
    id: 'subject-chem',
    name: '化学',
    color: const Color(0xFF7C5CFC),
    icon: '化');
final _hist = Subject(
    id: 'subject-hist',
    name: '历史',
    color: const Color(0xFFF08A1D),
    icon: '历');
final _geo = Subject(
    id: 'subject-geo',
    name: '地理',
    color: const Color(0xFF009688),
    icon: '地');

List<Subject> subjects4() => [...Subject.all, _chem];
List<Subject> subjects6() => [...Subject.all, _chem, _hist, _geo];

class B2FakeRepo extends QuestionRepository {
  B2FakeRepo() : super(AppDatabase.instance);

  List<Subject> subjectsList = Subject.all;
  Map<String, int> rev = {
    'math': 2,
    'english': 1,
    'politics': 0,
    'subject-chem': 1,
    'subject-hist': 0,
    'subject-geo': 3,
  };
  Map<String, int> pending = {
    'math': 1,
    'english': 2,
    'politics': 0,
    'subject-chem': 1,
    'subject-hist': 0,
    'subject-geo': 0,
  };

  @override
  Future<List<Subject>> subjects() async => subjectsList;

  @override
  Future<Map<String, int>> homeRevCounts() async => rev;

  @override
  Future<Map<String, int>> pendingOrganizeBySubject() async => pending;

  @override
  Future<({String kind, String subjectId, String title})?> recentTask() async =>
      null;

  @override
  Future<List<Question>> dueToday() async => [];

  @override
  Future<List<CauseRecord>> causeRecords() async => [];
}

Future<void> pumpB2Home(
  WidgetTester tester, {
  required B2FakeRepo repo,
  Brightness brightness = Brightness.light,
  Size size = const Size(1280, 720),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      darkTheme: AppTheme.dark(scale: 1.0),
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      home: Scaffold(body: HomePage(
        repo: repo,
        settings: const AppSettings(),
        onGoCollect: () {},
        onGoOrganize: () {},
        onGoWrongbook: (_) {},
        onGoReview: () {},
      )),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> pumpB2Nav(
  WidgetTester tester, {
  List<Subject>? subjects,
  Map<String, int> navRev = const {},
  Map<String, int> navPending = const {},
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      darkTheme: AppTheme.dark(scale: 1.0),
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      home: Scaffold(
        body: SizedBox(
          height: 720,
          child: AppNavBar(
            route: '/home',
            collapsed: false,
            onNavigate: (_) {},
            onToggleCollapsed: () {},
            navRev: navRev,
            navPending: navPending,
            subjects: subjects,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('B2 首页：新增学科全部显示', () {
    testWidgets('新增第 4 科后首页显示 4 科格', (tester) async {
      final repo = B2FakeRepo()..subjectsList = subjects4();
      await pumpB2Home(tester, repo: repo);
      expect(find.text('数学'), findsOneWidget);
      expect(find.text('英语'), findsOneWidget);
      expect(find.text('政治'), findsOneWidget);
      expect(find.text('化学'), findsOneWidget);
      // 化学格的数字走新学科 id 的计数键，不是 0。
      expect(find.text('要复习 1 道 · 待整理 1 道'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('新增到第 6 科后首页显示全部 6 科格', (tester) async {
      final repo = B2FakeRepo()..subjectsList = subjects6();
      await pumpB2Home(tester, repo: repo);
      for (final name in ['数学', '英语', '政治', '化学', '历史', '地理']) {
        expect(find.text(name), findsOneWidget);
      }
      expect(find.text('要复习 3 道 · 待整理 0 道'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('6 科 × 亮/深 × 2 列窄窗无溢出', (tester) async {
      final repo = B2FakeRepo()..subjectsList = subjects6();
      for (final brightness in [Brightness.light, Brightness.dark]) {
        await pumpB2Home(tester,
            repo: repo,
            brightness: brightness,
            size: const Size(800, 1000));
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('新学科格标题色 / 底色走存色，不等于数学色', (tester) async {
      final repo = B2FakeRepo()..subjectsList = subjects4();
      for (final brightness in [Brightness.light, Brightness.dark]) {
        await pumpB2Home(tester, repo: repo, brightness: brightness);
        // 化学格：标题 Text 用存色紫，底色 Container 用存色 tint。
        final title = tester.widget<Text>(find.text('化学'));
        expect(title.style!.color, const Color(0xFF7C5CFC));
        final cell = tester.widget<Container>(
          find.ancestor(
              of: find.text('化学'), matching: find.byType(Container)).first,
        );
        final bg = (cell.decoration as BoxDecoration).color!;
        expect(
          bg,
          DesignTokens.subjectSoft('subject-chem', brightness,
              const Color(0xFF7C5CFC)),
        );
        expect(
          bg,
          isNot(DesignTokens.subjectSoft('math', brightness)),
        );
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('B2 导航速览：最多 5 科', () {
    testWidgets('4 科全显示', (tester) async {
      await pumpB2Nav(tester, subjects: subjects4());
      for (final name in ['数学', '英语', '政治', '化学']) {
        expect(find.text(name), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('6 科只显示前 5 科，第 6 科不出现', (tester) async {
      await pumpB2Nav(
        tester,
        subjects: subjects6(),
        navRev: const {'subject-geo': 3},
        navPending: const {'subject-geo': 0},
      );
      for (final name in ['数学', '英语', '政治', '化学', '历史']) {
        expect(find.text(name), findsOneWidget);
      }
      expect(find.text('地理'), findsNothing);
      // 第 5 科（历史）在，第 6 科的计数也不应出现。
      expect(find.text('待整理 0 · 待复习 3'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('未传 subjects 时沿用预设三科', (tester) async {
      await pumpB2Nav(tester);
      for (final name in ['数学', '英语', '政治']) {
        expect(find.text(name), findsOneWidget);
      }
      expect(find.text('待整理 0 · 待复习 0'), findsNWidgets(3));
    });
  });

  group('B2 颜色回退：subjectInk / subjectSoft', () {
    test('非预设学科 ink 直接用存色，亮/深都不等于数学 ink', () {
      const stored = Color(0xFF7C5CFC);
      for (final brightness in [Brightness.light, Brightness.dark]) {
        expect(
          DesignTokens.subjectInk('subject-chem', brightness, stored),
          stored,
        );
        expect(
          DesignTokens.subjectInk('subject-chem', brightness, stored),
          isNot(DesignTokens.subjectInk('math', brightness)),
        );
      }
    });

    test('非预设学科 soft 是存色 tint，不等于数学 soft', () {
      const stored = Color(0xFF7C5CFC);
      for (final brightness in [Brightness.light, Brightness.dark]) {
        final soft =
            DesignTokens.subjectSoft('subject-chem', brightness, stored);
        expect(soft, isNot(DesignTokens.subjectSoft('math', brightness)));
        expect(soft, isNot(stored));
      }
    });

    test('预设三科传了存色也仍走主题固定色', () {
      const stored = Color(0xFF7C5CFC);
      for (final id in ['math', 'english', 'politics']) {
        for (final brightness in [Brightness.light, Brightness.dark]) {
          expect(
            DesignTokens.subjectInk(id, brightness, stored),
            DesignTokens.subjectInk(id, brightness),
          );
          expect(
            DesignTokens.subjectSoft(id, brightness, stored),
            DesignTokens.subjectSoft(id, brightness),
          );
          expect(
            DesignTokens.subjectColor(id, brightness, stored),
            DesignTokens.subjectColor(id, brightness),
          );
        }
      }
    });

    test('无 stored 时与旧行为一致', () {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        expect(
          DesignTokens.subjectInk('subject-chem', brightness),
          DesignTokens.subjectInk('math', brightness),
        );
        expect(
          DesignTokens.subjectSoft('subject-chem', brightness),
          DesignTokens.subjectSoft('math', brightness),
        );
      }
    });
  });
}
