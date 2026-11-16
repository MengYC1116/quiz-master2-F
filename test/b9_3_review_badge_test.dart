// B9-3：左导航“复习”角标。
//
// 口径（与首页焦点卡一致，数题不数错因）：角标 = `homeRevCounts`
// 各科之和 = `dueToday().length`（手动加入复习、已整理、错因桶
// 落在 pending 或 recheck 的题数）。多错因一题只计 1。
// B9-4（Meng 2026-11-15 ~19:43 裁决：统一按题数）：复习页顶
// 三数也按题数计（见 test/b9_4_review_header_count_test.dart），
// 与角标 / 首页同一口径；B9-3 当时锁死的“页顶按条数计”已作废。
//
// 两层用例：
// - A 组：纯展示组件 `AppNavBar`（参数驱动，不读库）：N 显示、
//   0 隐藏、accent 档、折叠态显示、选中态 token。
// - B 组：真实内存库 + 整应用 `QuizMasterApp` 真实交互：按题数计、
//   治愈后角标即减一（不进复习页、只切导航）、取消加入即减、
//   折叠态同样显示。
//
// 整应用 `pumpAndSettle` 永不静止（见 `s8b3_startup_test.dart`
// 文件头），用有界手动 pump（B8-1 同款 `_pumpUntil`）；
// Drift 走同步 sqlite3 调用，仓库方法在 widget 测试里直接 await
// 即可；`tester.runAsync` 只用于 Future.delayed 这类真实延时。
// 注意：播种必须在测试体内做——setUp 跑在 fake async 区之外，
// setUp 里打开的库在测试体里 await 仓库方法会挂住（B Stage 1
// 探针 11/12/13）；同理 runAsync 里多段仓库调用也会挂住。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/app.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/app_shell.dart';

// ---------- A 组：AppNavBar ----------

Future<void> _pumpNav(
  WidgetTester tester, {
  String route = '/home',
  bool collapsed = false,
  int collectBadge = 0,
  int organizeBadge = 0,
  int reviewBadge = 0,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      home: Scaffold(
        body: SizedBox(
          height: 720,
          child: AppNavBar(
            route: route,
            collapsed: collapsed,
            onNavigate: (_) {},
            onToggleCollapsed: () {},
            collectBadge: collectBadge,
            organizeBadge: organizeBadge,
            reviewBadge: reviewBadge,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 角标数字文字最近的祖先 Container（角标本体）。
BoxDecoration _badgeDecoration(WidgetTester tester, String number) {
  final containers = find.ancestor(
    of: find.text(number),
    matching: find.byType(Container),
  );
  return tester.widget<Container>(containers.first).decoration!
      as BoxDecoration;
}

// ---------- B 组：整应用 ----------

/// 左导航栏本体的 key，断言只圈导航内，避免与内容页同名文字混淆。
final _navBar = find.byKey(const ValueKey('qm-nav-bar'));

/// 导航栏内的某段文字。
Finder _navText(String text) =>
    find.descendant(of: _navBar, matching: find.text(text));

/// 有界手动 pump：每轮先 pump 一帧看条件，再切回真实异步等一轮、
// 再 pump 渲染，直到条件成立或超限失败（B8-1 同款）。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  int maxRounds = 40,
}) async {
  for (var i = 0; i < maxRounds; i++) {
    await tester.pump();
    if (condition()) return;
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    if (condition()) return;
  }
  fail('界面未稳定：$reason');
}

/// 点左导航某项（只圈导航栏内，避免与内容页同名标题混淆）。
Future<void> _goNav(WidgetTester tester, String label) async {
  await tester.tap(_navText(label));
  await tester.pump();
}

/// 内存库 + 预设三科（与新库首次启动一致），其余表全空。
Future<QuestionRepository> _seedMemoryRepo() async {
  final db = await AppDatabase.openForTest();
  AppDatabase.useDatabaseForTest(db);
  final repo = QuestionRepository(AppDatabase.instance);
  for (final s in Subject.all) {
    await repo.saveSubject(s);
  }
  return repo;
}

/// 已整理、已加入复习的题：q1 带 2 个错因，q2 带 1 个错因。
Question _joinedQuestion(String id, {required List<String> errorTypes}) =>
    Question(
      id: id,
      title: '数学 · 第$id题',
      subjectId: 'math',
      createdAt: DateTime(2026, 11, 14),
      sliceText: '题干占位文字',
      errorTypes: errorTypes,
      isOrganized: true,
    );

Future<void> _seedTwoDue(QuestionRepository repo) async {
  final q1 = _joinedQuestion('q1', errorTypes: ['概念不清', '计算错误']);
  final q2 = _joinedQuestion('q2', errorTypes: ['审题失误']);
  await repo.save(q1);
  await repo.save(q2);
  // 加入复习：每错因建一条待解决记录（q1 两条、q2 一条）。
  expect(await repo.setReviewJoined(q1, true), isTrue);
  expect(await repo.setReviewJoined(q2, true), isTrue);
}

/// 把一条错因记录自查“已解决”到治愈（默认 cureChecks=2，需两次；
/// 复查日顺延到今天 +7 天，不到复查时间，桶落 solved）。
/// Drift 同步调用，直接 await（见文件头）。
Future<CauseRecord> _cureCause(
  QuestionRepository repo,
  CauseRecord rec,
) async {
  var cur = rec;
  for (var i = 0; i < 2; i++) {
    cur = await repo.recordSelfCheck(cur, 'solved');
  }
  expect(cur.status, CauseStatus.solved);
  return cur;
}

/// 某题的全部错因记录（Drift 同步调用，直接 await）。
Future<List<CauseRecord>> _recordsFor(
  QuestionRepository repo,
  String questionId,
) async => await repo.causeRecordsFor(questionId);

void main() {
  group('A：AppNavBar 复习角标', () {
    testWidgets('reviewBadge=N 显示 N，accent 底（不是灰档）', (tester) async {
      await _pumpNav(tester, reviewBadge: 3);
      expect(find.text('3'), findsOneWidget);
      expect(_badgeDecoration(tester, '3').color, DesignTokens.light.accent);
    });

    testWidgets('reviewBadge=0 时不渲染', (tester) async {
      await _pumpNav(tester, reviewBadge: 0);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('折叠态下角标同样显示', (tester) async {
      await _pumpNav(tester, collapsed: true, reviewBadge: 3);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('选中复习页时角标用 badgeSelected token', (tester) async {
      await _pumpNav(tester, route: '/review', reviewBadge: 3);
      expect(
        _badgeDecoration(tester, '3').color,
        DesignTokens.light.badgeSelectedBg,
      );
      final text = tester.widget<Text>(find.text('3'));
      expect(text.style?.color, DesignTokens.light.badgeSelectedFg);
    });
  });

  group('B：整应用复习角标（共享口径：数题不数错因）', () {
    // 播种必须在测试体内做（见文件头）：setUp 在 fake async 区之外，
    // setUp 里打开的库在测试体里 await 仓库方法会挂住。
    Future<QuestionRepository> seedB() async {
      final repo = await _seedMemoryRepo();
      await _seedTwoDue(repo);
      addTearDown(() async {
        await AppDatabase.resetForTest();
      });
      return repo;
    }

    Future<void> pumpApp(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const ProviderScope(child: QuizMasterApp()));
    }

    testWidgets('多错因一题只计 1：两道待复习题（q1 有 2 个待解决错因）角标是 2 不是 3', (tester) async {
      final repo = await seedB();
      await pumpApp(tester);
      await _pumpUntil(
        tester,
        () => _navText('2').evaluate().isNotEmpty,
        reason: '启动后复习角标未显示 2',
      );

      // 口径锁定（B9-4 已统一按题数）：
      // - 角标 / 首页焦点卡 / dueToday：按题数——q1、q2 各计 1，共 2。
      // - 复习页顶三数（review_page.dart _metaCounts）同样按题数：
      //   q1 两条 + q2 一条错因记录 = 2 道题（见本用例末尾进复习页
      //   的断言与 test/b9_4_review_header_count_test.dart）。
      final due = await repo.dueToday();
      expect(due.map((q) => q.id), unorderedEquals(['q1', 'q2']));
      final q1Records = await _recordsFor(repo, 'q1');
      expect(q1Records.length, 2);
      expect(q1Records.where((r) => r.status != CauseStatus.solved).length, 2);
      final q2Records = await _recordsFor(repo, 'q2');
      expect(q2Records.length, 1);

      // 折叠态：角标同样显示（图标模式右上角）。
      await tester.tap(find.byTooltip('折叠导航'));
      await _pumpUntil(
        tester,
        () => _navText('2').evaluate().isNotEmpty,
        reason: '折叠导航后复习角标 2 未显示',
      );
      await tester.tap(find.byTooltip('展开导航'));
      await _pumpUntil(
        tester,
        () => _navText('2').evaluate().isNotEmpty,
        reason: '展开导航后复习角标 2 未显示',
      );

      // B9-4：进复习页，页顶与角标同口径——2 道题，不是 3 条；
      // 无已解决题，第三数是 0 道。
      await _goNav(tester, '复习');
      await _pumpUntil(
        tester,
        () => find.text('待解决 / 解决中 2 道题').evaluate().isNotEmpty,
        reason: '复习页顶未显示“待解决 / 解决中 2 道题”',
      );
      expect(find.text('已解决 0 道'), findsOneWidget);
      expect(find.text('待解决 / 解决中 3 条解决记录'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('治愈一条后角标即减一：不进复习页、只切导航，角标已更新', (tester) async {
      final repo = await seedB();
      await pumpApp(tester);
      await _pumpUntil(
        tester,
        () => _navText('2').evaluate().isNotEmpty,
        reason: '启动后复习角标未显示 2',
      );

      // 治愈 q1 的两个错因（每条两次“已解决”自查）：q1 整题治愈，
      // 桶落 solved，不再计入要复习；q2 仍待解决，角标应变 1。
      // 自查走仓库方法（与复习页会话内同一 recordSelfCheck 入口），
      // 不打开复习页——角标靠 recordSelfCheck 的变更事件
      // + badgeCountsProvider 订阅刷新。
      for (final rec in await _recordsFor(repo, 'q1')) {
        await _cureCause(repo, rec);
      }
      // 只切导航（首页 → 收集中心 → 首页），不进复习页。
      await _goNav(tester, '收集中心');
      await _goNav(tester, '首页');
      await _pumpUntil(
        tester,
        () => _navText('1').evaluate().isNotEmpty,
        reason: '治愈 q1 后复习角标未变为 1',
      );

      // 再治愈 q2 唯一的错因：无待复习题，角标隐藏（0 不渲染）。
      for (final rec in await _recordsFor(repo, 'q2')) {
        await _cureCause(repo, rec);
      }
      await _goNav(tester, '收集中心');
      await _goNav(tester, '首页');
      await _pumpUntil(
        tester,
        () =>
            _navText('1').evaluate().isEmpty &&
            _navText('2').evaluate().isEmpty,
        reason: '全部治愈后复习角标未隐藏',
      );
      final due = await repo.dueToday();
      expect(due, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('取消加入复习后角标即减（不进复习页）', (tester) async {
      final repo = await seedB();
      await pumpApp(tester);
      await _pumpUntil(
        tester,
        () => _navText('2').evaluate().isNotEmpty,
        reason: '启动后复习角标未显示 2',
      );

      // 取消 q1 的加入复习（记录保留，桶不再计入要复习）。
      final q1 = await repo.questionById('q1');
      expect(
        await repo.setReviewJoined(q1!, false),
        isTrue,
      );
      await _goNav(tester, '收集中心');
      await _goNav(tester, '首页');
      await _pumpUntil(
        tester,
        () => _navText('1').evaluate().isNotEmpty,
        reason: '取消 q1 加入复习后角标未变为 1',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
