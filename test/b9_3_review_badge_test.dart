// B9-3：左导航“复习”角标。
//
// 口径（FSRS，2026-11-25 口径迁移 §2.2，与首页焦点卡一致，数题不数
// 错因）：角标 = `fsrsDueCountsBySubject` 各科之和 =
// `fsrsDueQuestionIds().length`（池里已开始正式复习且 next_due_at
// <= now 的题）。只加入复习不够：FSRS 卡未开始不算到期；多错因一题
// 只计 1。B9-4（Meng 2026-11-15 ~19:43 裁决：统一按题数）：复习页顶
// 三数也按题数计（见 test/b9_4_review_header_count_test.dart），
// 与角标 / 首页同一口径；B9-3 当时锁死的“页顶按条数计”已作废。
// 复习页顶分组本身仍是旧错因口径（§5 第 10 项定：不进本批），本文件
// 末尾进复习页的断言仍按旧分组写，只锁角标与首页的 FSRS 新口径。
//
// 两层用例：
// - A 组：纯展示组件 `AppNavBar`（参数驱动，不读库）：N 显示、
//   0 隐藏、accent 档、折叠态显示、选中态 token。
// - B 组：真实内存库 + 整应用 `QuizMasterApp` 真实交互：按题数计、
//   核对提交后角标即减一（不进复习页、只切导航）、归档即减、
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
import 'package:quiz_master2/data/data_change_events.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
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

/// 确定性调度器（fuzzing 关）+ SQLite store，绑当前测试库。
FsrsReviewScheduler _testScheduler() => FsrsReviewScheduler(
  config: const SchedulerConfig(enableFuzzing: false),
  store: SqliteCardStore(),
);

/// 给 [id] 建一张已到期的 FSRS 卡：建卡 + 3 天前答对一次
///（Good 首间隔 2 天，到期日在昨天）。
Future<void> _seedDueCard(String id) async {
  final scheduler = _testScheduler();
  await scheduler.initializeQuestion(id);
  await scheduler.recordAnswer(
    id,
    ReviewResult.good,
    DateTime.now().subtract(const Duration(days: 3)),
    'evt-b93-$id',
  );
}

Future<void> _seedTwoDue(QuestionRepository repo) async {
  final q1 = _joinedQuestion('q1', errorTypes: ['概念不清', '计算错误']);
  final q2 = _joinedQuestion('q2', errorTypes: ['审题失误']);
  await repo.save(q1);
  await repo.save(q2);
  // 加入复习：每错因建一条待解决记录（q1 两条、q2 一条）。
  expect(await repo.setReviewJoined(q1, true), isTrue);
  expect(await repo.setReviewJoined(q2, true), isTrue);
  // FSRS 口径：两题各建一张已到期的卡，角标才计 2。
  await _seedDueCard('q1');
  await _seedDueCard('q2');
}

/// 核对提交一次（答对，Good）：卡片 next_due_at 移到未来，不再到期。
/// 直接调仓库方法（不走 review_notifier）：产品里提交成功后的 badges
/// 事件由 review_notifier.submitCheck 补发（见 stage4 的 notifier
/// 测试）；此处提交后由测试显式发一次同款事件，只验证角标收到事件后
/// 按 FSRS 新数重算。
Future<void> _submitGood(
  QuestionRepository repo,
  String questionId,
) async {
  final now = DateTime.now();
  await repo.submitReviewCheck(
    attempt: AttemptData(
      id: 'att-b93-$questionId',
      questionId: questionId,
      sessionId: 'sess-b93',
      mode: '到期复习',
      selected: const ['B'],
      correct: 1,
      answerVersion: 1,
      contentVersion: 1,
      status: '已提交',
      causeIds: const ['概念不清'],
      submissionId: 'attsub-b93-$questionId',
      createdAt: now.millisecondsSinceEpoch,
    ),
    result: ReviewResult.good,
    reviewedAt: now,
    eventId: 'attsub-b93-$questionId',
    scheduler: _testScheduler(),
  );
  DataChangeBus.instance.emit(
    const DataChangeEvent(kinds: {DataChangeKind.badges}),
  );
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

      // 口径锁定（FSRS，数题不数错因）：
      // - 角标 / 首页焦点卡 / fsrsDueQuestionIds：按题数——q1、q2 各计 1，共 2。
      // - 复习页顶两数（review_page.dart）同样按题数：
      //   q1 两条 + q2 一条错因记录 = 2 道题（见本用例末尾进复习页
      //   的断言与 test/b9_4_review_header_count_test.dart）。
      final due = await repo.fsrsDueQuestionIds(scheduler: _testScheduler());
      expect(due, unorderedEquals(['q1', 'q2']));
      expect(
        await repo.fsrsDueTotal(scheduler: _testScheduler()),
        2,
      );
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

      // 面 A：进复习页，页顶与角标同口径——到期 2 道题，不是 3 条错因；
      // 两题的卡都已到期，同落「已逾期」组。
      await _goNav(tester, '复习');
      await _pumpUntil(
        tester,
        () => find.textContaining('到期 2 道').evaluate().isNotEmpty,
        reason: '复习页顶未显示“到期 2 道”',
      );
      expect(find.text('待解决 / 解决中 2 道题'), findsNothing);
      expect(find.text('已解决 0 道'), findsNothing);
      expect(find.text('待解决 / 解决中 3 条解决记录'), findsNothing);
      expect(find.text('已逾期'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('核对提交一道后角标即减一：不进复习页、只切导航，角标已更新', (tester) async {
      final repo = await seedB();
      await pumpApp(tester);
      await _pumpUntil(
        tester,
        () => _navText('2').evaluate().isNotEmpty,
        reason: '启动后复习角标未显示 2',
      );

      // 核对提交 q1（答对，Good）：卡片 next_due_at 移到未来，不再到期；
      // q2 仍到期，角标应变 1。旧口径的“治愈一条错因即减”已断：
      // 错因自查不再影响 FSRS 角标（见 stage4 S4-6）。
      await _submitGood(repo, 'q1');
      // 只切导航（首页 → 收集中心 → 首页），不进复习页。
      await _goNav(tester, '收集中心');
      await _goNav(tester, '首页');
      await _pumpUntil(
        tester,
        () => _navText('1').evaluate().isNotEmpty,
        reason: '核对提交 q1 后复习角标未变为 1',
      );

      // 再核对提交 q2：无到期题，角标隐藏（0 不渲染）。
      await _submitGood(repo, 'q2');
      await _goNav(tester, '收集中心');
      await _goNav(tester, '首页');
      await _pumpUntil(
        tester,
        () =>
            _navText('1').evaluate().isEmpty &&
            _navText('2').evaluate().isEmpty,
        reason: '全部核对提交后复习角标未隐藏',
      );
      final due = await repo.fsrsDueQuestionIds(scheduler: _testScheduler());
      expect(due, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('归档一道题后角标即减（不进复习页）', (tester) async {
      final repo = await seedB();
      await pumpApp(tester);
      await _pumpUntil(
        tester,
        () => _navText('2').evaluate().isNotEmpty,
        reason: '启动后复习角标未显示 2',
      );

      // 归档 q1（已到期卡保留，但归档题不进到期队列）。
      // 旧口径的“取消加入即减”已断：取消加入不删 FSRS 卡，角标不变
      //（见 stage4 S4-5）；归档仍是角标减一的入口。
      final q1 = await repo.questionById('q1');
      await repo.archive(q1!);
      await _goNav(tester, '收集中心');
      await _goNav(tester, '首页');
      await _pumpUntil(
        tester,
        () => _navText('1').evaluate().isNotEmpty,
        reason: '归档 q1 后复习角标未变为 1',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
