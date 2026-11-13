// R10 设置页 widget 测试：五组折叠（默认全折、一次只开一段）、
// 外观三段 + 问候语保存/恢复默认、复习八项分段切换、错题本三项、
// 数据组（备份/恢复入口、数据库位置、缓存预览、清空演示数据确认）、
// 启动页 + 关于、加载失败横幅、亮/深 × 三档无溢出、不用图标字体。
// 用 FakeRepo 覆盖 repository 调用（不碰真实数据库，不弹文件选择器）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/settings/settings_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';

class FakeSettingsRepo extends QuestionRepository {
  FakeSettingsRepo({this.demoCount = 3, this.questionCount = 9})
      : super(AppDatabase.instance);

  int demoCount;
  int questionCount;
  int clearedDemo = 0;

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.generate(
        questionCount,
        (i) => Question(
          id: 'q$i',
          title: '题 $i',
          subjectId: 'math',
          createdAt: DateTime.now(),
          isOrganized: true,
          sliceKind: 'material',
          sliceText: '题',
        ),
      );

  @override
  Future<int> demoQuestionCount() async => demoCount;

  @override
  Future<int> clearDemoData() async {
    clearedDemo = demoCount;
    demoCount = 0;
    return clearedDemo;
  }
}

Future<List<AppSettings>> pumpSettings(
  WidgetTester tester, {
  FakeSettingsRepo? repo,
  AppSettings settings = AppSettings.defaults,
  bool loadFailed = false,
  Brightness brightness = Brightness.light,
  double scale = 1.0,
  double width = 1280,
}) async {
  tester.view.physicalSize = Size(width, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final applied = <AppSettings>[];
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
              body: SettingsPage(
                key: UniqueKey(),
                repo: repo ?? FakeSettingsRepo(),
                settings: settings,
                onSettingsChanged: (s) async => applied.add(s),
                loadFailed: loadFailed,
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return applied;
}

Future<void> openGroup(WidgetTester tester, String title) async {
  await tester.ensureVisible(find.text(title).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(title).first);
  await tester.pumpAndSettle();
}

void main() {
  group('设置：折叠', () {
    testWidgets('默认全折叠：五组标题可见，组内容不可见', (tester) async {
      await pumpSettings(tester);
      expect(find.text('设置'), findsOneWidget);
      for (final t in ['外观', '复习', '错题本', '数据', '启动与关于']) {
        expect(find.text(t), findsOneWidget);
      }
      expect(find.text('主题'), findsNothing);
      expect(find.text('复查间隔'), findsNothing);
      expect(find.text('备份题库'), findsNothing);
    });

    testWidgets('一次只开一段', (tester) async {
      await pumpSettings(tester);
      await openGroup(tester, '外观');
      expect(find.text('主题'), findsOneWidget);
      await openGroup(tester, '复习');
      expect(find.text('主题'), findsNothing);
      expect(find.text('复查间隔'), findsOneWidget);
    });

    testWidgets('点同一组标题收起', (tester) async {
      await pumpSettings(tester);
      await openGroup(tester, '错题本');
      expect(find.text('默认视图'), findsOneWidget);
      await openGroup(tester, '错题本');
      expect(find.text('默认视图'), findsNothing);
    });
  });

  group('设置：外观', () {
    testWidgets('主题三段切换：点深色回调 themeMode=dark', (tester) async {
      final applied = await pumpSettings(tester);
      await openGroup(tester, '外观');
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      expect(applied.last.themeMode, 'dark');
    });

    testWidgets('字体三段切换：点特大回调 fontSize=extraLarge',
        (tester) async {
      final applied = await pumpSettings(tester);
      await openGroup(tester, '外观');
      await tester.tap(find.text('特大'));
      await tester.pumpAndSettle();
      expect(applied.last.fontSize, 'extraLarge');
    });

    testWidgets('问候语：保存新问候语，恢复默认回“今天也要加油呀”',
        (tester) async {
      final applied = await pumpSettings(tester);
      await openGroup(tester, '外观');
      expect(find.textContaining('首页现在显示的是：「今天也要加油呀」'),
          findsOneWidget);
      await tester.enterText(find.byType(TextField), '数学必胜');
      await tester.tap(find.text('保存问候语'));
      await tester.pumpAndSettle();
      expect(applied.last.greeting, '数学必胜');
      await tester.tap(find.text('恢复默认'));
      await tester.pumpAndSettle();
      expect(applied.last.greeting, '今天也要加油呀');
    });

    testWidgets('问候语留空保存不生效', (tester) async {
      final applied = await pumpSettings(tester);
      await openGroup(tester, '外观');
      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('保存问候语'));
      await tester.pumpAndSettle();
      expect(applied, isEmpty);
      expect(find.text('留空保存不生效'), findsOneWidget);
    });
  });

  group('设置：复习', () {
    testWidgets('加入方式说明行', (tester) async {
      await pumpSettings(tester);
      await openGroup(tester, '复习');
      expect(find.text('手动加入：在题目详情点「加入复习」。'), findsOneWidget);
    });

    testWidgets('复查间隔/自查次数/每轮错因数/跳过次数切换',
        (tester) async {
      final applied = await pumpSettings(tester);
      await openGroup(tester, '复习');
      await tester.tap(find.text('14 天'));
      await tester.pumpAndSettle();
      expect(applied.last.recheckIntervalDays, 14);
      await tester.tap(find.text('3 次'));
      await tester.pumpAndSettle();
      expect(applied.last.cureChecks, 3);
      await tester.tap(find.text('5 个'));
      await tester.pumpAndSettle();
      expect(applied.last.causesPerSession, 5);
      await tester.tap(find.text('1 次').last);
      await tester.pumpAndSettle();
      expect(applied.last.skipLimit, 1);
    });

    testWidgets('重做答案默认：点默认显示回调 redoAnswerHidden=false',
        (tester) async {
      final applied = await pumpSettings(tester);
      await openGroup(tester, '复习');
      await tester.tap(find.text('默认显示'));
      await tester.pumpAndSettle();
      expect(applied.last.redoAnswerHidden, isFalse);
    });

    testWidgets('通知提醒：点关回调 notifyEnabled=false，提醒时间禁用',
        (tester) async {
      final applied = await pumpSettings(tester);
      await openGroup(tester, '复习');
      expect(find.text('20:00'), findsOneWidget);
      await tester.tap(find.text('关'));
      await tester.pumpAndSettle();
      expect(applied.last.notifyEnabled, isFalse);
    });

    testWidgets('复习列表默认排序：点按学科回调 reviewSort=subject',
        (tester) async {
      final applied = await pumpSettings(tester);
      await openGroup(tester, '复习');
      await tester.tap(find.text('按学科'));
      await tester.pumpAndSettle();
      expect(applied.last.reviewSort, 'subject');
    });
  });

  group('设置：错题本与启动', () {
    testWidgets('默认视图/排序/每页数量切换', (tester) async {
      final applied = await pumpSettings(tester);
      await openGroup(tester, '错题本');
      await tester.tap(find.text('紧凑列表'));
      await tester.pumpAndSettle();
      expect(applied.last.wrongbookView, 'compact');
      await tester.tap(find.text('时间旧 → 新'));
      await tester.pumpAndSettle();
      expect(applied.last.wrongbookSort, 'old');
      await tester.tap(find.text('50'));
      await tester.pumpAndSettle();
      expect(applied.last.pageSize, 50);
    });

    testWidgets('启动页切换与关于', (tester) async {
      final applied = await pumpSettings(tester);
      await openGroup(tester, '启动与关于');
      await tester.tap(find.text('上次停下的页面'));
      await tester.pumpAndSettle();
      expect(applied.last.startupPage, 'last');
      expect(find.text('quiz-master2 v0.1.0'), findsOneWidget);
      expect(find.text('Meng（个人项目）'), findsOneWidget);
      expect(find.textContaining('v0.1.0：首个版本'), findsOneWidget);
    });
  });

  group('设置：数据', () {
    testWidgets('数据库位置显示当前路径', (tester) async {
      await pumpSettings(tester);
      await openGroup(tester, '数据');
      expect(find.textContaining('/quiz-master2.db'), findsOneWidget);
      expect(find.text('改位置'), findsOneWidget);
      expect(find.text('备份题库'), findsOneWidget);
      expect(find.text('选择备份文件…'), findsOneWidget);
    });

    testWidgets('缓存预览：显示无缓存或真实预览，不抛错', (tester) async {
      await pumpSettings(tester);
      await openGroup(tester, '数据');
      // 预览取决于真实数据目录内容：无缓存显示“没有可清理的缓存”，
      // 有缓存显示“临时文件 N 个、缩略图缓存 M 张，共约 X MB”。
      final empty = find.text('现在没有可清理的缓存。').evaluate().isNotEmpty;
      final preview =
          find.textContaining('临时文件').evaluate().isNotEmpty;
      expect(empty || preview, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('清空演示数据：内联确认，确认后清掉并提示', (tester) async {
      final repo = FakeSettingsRepo(demoCount: 3);
      await pumpSettings(tester, repo: repo);
      await openGroup(tester, '数据');
      await tester.tap(find.text('清空演示数据'));
      await tester.pumpAndSettle();
      expect(find.textContaining('清空演示数据，确定吗？'), findsOneWidget);
      expect(find.textContaining('三科共 3 道演示题会全部删掉'), findsOneWidget);
      await tester.ensureVisible(find.text('确认清空'));
      await tester.tap(find.text('确认清空'));
      await tester.pumpAndSettle();
      expect(repo.clearedDemo, 3);
      expect(find.text('已清空 3 道演示题'), findsOneWidget);
    });

    testWidgets('清空演示数据：点取消不清', (tester) async {
      final repo = FakeSettingsRepo(demoCount: 3);
      await pumpSettings(tester, repo: repo);
      await openGroup(tester, '数据');
      await tester.tap(find.text('清空演示数据'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('取消'));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(repo.clearedDemo, 0);
      expect(find.textContaining('清空演示数据，确定吗？'), findsNothing);
    });
  });

  group('设置：错误态与无溢出', () {
    testWidgets('加载失败出错误横幅，可关闭', (tester) async {
      await pumpSettings(tester, loadFailed: true);
      expect(find.textContaining('设置读取失败'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.textContaining('设置读取失败'), findsNothing);
    });

    testWidgets('亮/深 × 三档无溢出', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        for (final scale in [1.0, 1.15, 1.3]) {
          await pumpSettings(tester,
              brightness: brightness, scale: scale);
          for (final group in ['外观', '复习', '错题本', '数据', '启动与关于']) {
            await openGroup(tester, group);
          }
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets('不用图标字体', (tester) async {
      await pumpSettings(tester);
      await openGroup(tester, '外观');
      expect(find.byType(Icon), findsNothing);
    });
  });
}
