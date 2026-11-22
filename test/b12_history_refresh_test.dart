// 十二批 D-94：首页历史返回刷新小尾巴。
// 覆盖三层：
// 1. 数据层——`recordQuestionViewed` 写库成功后发一次含
//    `recentlyViewed` + questionId 的事件；纯写库版
//    `recordQuestionViewedIntoImpl` 不发；写库失败时不发。
// 2. Provider 层——`HomeNotifier` 收到 `recentlyViewed` 事件后重读
//    历史（不重置 loading、不闪加载卡）；无关 kind 不触发重读；
//    首查进行中发来的事件不丢失（FR-31 订阅时序教训）。
// 3. 页面层（回归测试）——首页打开（历史已有题 A）→ 打开题 B 详情
//    （记一次查看）→ 返回首页（不重新进首页）→ 历史刷新、题 B 顶到首位。
// 详情打开走真实 `DetailNotifier.load()`；FakeRepo 的
// `recordQuestionViewed` 在更新历史的同时发与生产扩展方法相同的
// 事件（生产侧发事件由第 1 组数据层测试覆盖）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/data_change_events.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/exam_event.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/home/home_page.dart';
import 'package:quiz_master2/state/detail_notifier.dart';
import 'package:quiz_master2/state/home_provider.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/theme/app_theme.dart';

Question _q(String id, String title, {String subjectId = 'math'}) =>
    Question(
      id: id,
      title: title,
      subjectId: subjectId,
      createdAt: DateTime(2026, 11, 10),
    );

Future<QuizDatabase> _openMemoryDb() async {
  final db = await AppDatabase.openForTest();
  AppDatabase.useDatabaseForTest(db);
  addTearDown(() async {
    await AppDatabase.resetForTest();
  });
  return db;
}

/// 等待条件成立（轮询，最多约 1 秒），超时即失败。
Future<void> _waitUntil(bool Function() cond) async {
  for (var i = 0; i < 100; i++) {
    if (cond()) return;
    await Future.delayed(const Duration(milliseconds: 10));
  }
  fail('条件未在 1 秒内成立');
}

void main() {
  group('数据层：recordQuestionViewed 发事件', () {
    test('写库成功后发一次含 recentlyViewed + questionId 的事件', () async {
      await _openMemoryDb();
      await AppDatabase.instance.upsertQuestion(_q('q1', '函数极限'));
      final events = <DataChangeEvent>[];
      final sub = DataChangeBus.instance.stream.listen(events.add);
      addTearDown(sub.cancel);
      await AppDatabase.instance.recordQuestionViewed('q1');
      // broadcast 流异步投递，等一拍再断言。
      await Future.delayed(const Duration(milliseconds: 50));
      expect(events, hasLength(1));
      expect(events.single.kinds, {DataChangeKind.recentlyViewed});
      expect(events.single.questionId, 'q1');
      // 写库本身也成功了（事件是写后发的）。
      final back = await AppDatabase.instance.recentlyViewedQuestions();
      expect(back.map((e) => e.question.id).toList(), ['q1']);
    });

    test('纯写库版 recordQuestionViewedIntoImpl 不发事件', () async {
      final db = await _openMemoryDb();
      await AppDatabase.instance.upsertQuestion(_q('q1', '函数极限'));
      final events = <DataChangeEvent>[];
      final sub = DataChangeBus.instance.stream.listen(events.add);
      addTearDown(sub.cancel);
      await recordQuestionViewedIntoImpl(db, 'q1', viewedAtMillis: 1000);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(events, isEmpty);
      // 写库本身成功（impl 只是不发事件）。
      final back = await AppDatabase.instance.recentlyViewedQuestions();
      expect(back, hasLength(1));
    });

    test('写库失败时不发事件', () async {
      final db = await _openMemoryDb();
      await AppDatabase.instance.upsertQuestion(_q('q1', '函数极限'));
      final events = <DataChangeEvent>[];
      final sub = DataChangeBus.instance.stream.listen(events.add);
      addTearDown(sub.cancel);
      // 关掉库连接再记：扩展方法里写库抛错，emit 在写库之后、跑不到。
      await db.close();
      await expectLater(
        AppDatabase.instance.recordQuestionViewed('q1'),
        throwsA(anything),
      );
      await Future.delayed(const Duration(milliseconds: 50));
      expect(events, isEmpty);
    });
  });

  group('Provider 层：HomeNotifier 订阅 recentlyViewed', () {
    /// 先配好 FakeRepo 再建 container：build 的 microtask 首查可能在
    /// setUp 与测试体之间的 microtask 间隙里就跑完——建完容器再配
    /// historyList 的话，首查读到的是配之前的空列表。
    ProviderContainer homeContainer(_RefreshFakeRepo repo) {
      final c = ProviderContainer.test(
        overrides: [repositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(c.dispose);
      // autoDispose 保活（D-36）：只 read 不监听时 build 的 microtask
      // 首查还没写回就被销毁。
      c.listen(homeProvider, (_, __) {});
      return c;
    }

    test('收到事件后重读历史：B 进库后首位变成 B，不闪 loading', () async {
      final now = DateTime.now();
      final repo = _RefreshFakeRepo()
        ..historyList = [
          (question: _q('q-a', '题 A'), viewedAt: now),
        ];
      final container = homeContainer(repo);
      // 等首查落定。
      await _waitUntil(() => container.read(homeProvider).hasLoaded);
      expect(
        container.read(homeProvider).history.map((e) => e.question.id).toList(),
        ['q-a'],
      );
      expect(repo.recentlyViewedCalls, 1);

      // 详情页记了一次 B（FakeRepo 里历史已更新），再发事件。
      repo.historyList = [
        (question: _q('q-b', '题 B'), viewedAt: now),
        (question: _q('q-a', '题 A'), viewedAt: now),
      ];
      DataChangeBus.instance.emit(
        const DataChangeEvent(
          kinds: {DataChangeKind.recentlyViewed},
          questionId: 'q-b',
        ),
      );
      await _waitUntil(
        () =>
            container.read(homeProvider).history.isNotEmpty &&
            container.read(homeProvider).history.first.question.id == 'q-b',
      );
      expect(
        container.read(homeProvider).history.map((e) => e.question.id).toList(),
        ['q-b', 'q-a'],
      );
      // 事件触发的是 load() 重读，不是 invalidateSelf：state 没有
      // 回到 loading，首页不闪加载卡。
      expect(container.read(homeProvider).loading, isFalse);
      expect(repo.recentlyViewedCalls, 2);
    });

    test('无关 kind 的事件不触发重读', () async {
      final repo = _RefreshFakeRepo()
        ..historyList = [
          (question: _q('q-a', '题 A'), viewedAt: DateTime.now()),
        ];
      final container = homeContainer(repo);
      await _waitUntil(() => container.read(homeProvider).hasLoaded);
      expect(repo.recentlyViewedCalls, 1);
      DataChangeBus.instance.emit(
        const DataChangeEvent(kinds: {DataChangeKind.badges}),
      );
      await Future.delayed(const Duration(milliseconds: 100));
      expect(repo.recentlyViewedCalls, 1);
      expect(
        container.read(homeProvider).history.map((e) => e.question.id).toList(),
        ['q-a'],
      );
    });

    test('首查进行中发来的事件不丢失（先订阅、后首查）', () async {
      // 首查的第 1 次历史读取被卡住：事件在这期间发出。
      final repo = _RefreshFakeRepo()
        ..blockFirstHistoryRead = Completer<void>()
        ..historyList = [
          (question: _q('q-a', '题 A'), viewedAt: DateTime.now()),
        ];
      final container = homeContainer(repo);
      // 让 build 的 microtask 首查跑起来、卡在第 1 次历史读取上。
      await Future.delayed(const Duration(milliseconds: 50));
      expect(repo.recentlyViewedCalls, 1);
      expect(container.read(homeProvider).hasLoaded, isFalse);
      // 期间题 B 被看过、历史已更新，再发事件。
      final now = DateTime.now();
      repo.historyList = [
        (question: _q('q-b', '题 B'), viewedAt: now),
        (question: _q('q-a', '题 A'), viewedAt: now),
      ];
      DataChangeBus.instance.emit(
        const DataChangeEvent(
          kinds: {DataChangeKind.recentlyViewed},
          questionId: 'q-b',
        ),
      );
      // 放行首查；事件触发的重读随后读到含 B 的历史。
      repo.blockFirstHistoryRead!.complete();
      await _waitUntil(
        () =>
            container.read(homeProvider).history.isNotEmpty &&
            container.read(homeProvider).history.first.question.id == 'q-b',
      );
      expect(
        container.read(homeProvider).history.map((e) => e.question.id).toList(),
        ['q-b', 'q-a'],
      );
    });
  });

  group('页面层回归：详情返回首页，历史刷新、刚看的题顶到首位', () {
    testWidgets('首页打开 → 打开题 B 详情 → 返回首页，全程不用重新进首页', (
      tester,
    ) async {
      final now = DateTime.now();
      final repo = _RefreshFakeRepo()
        ..questions = [_q('q-a', '题 A'), _q('q-b', '题 B')]
        ..historyList = [
          (question: _q('q-a', '题 A'), viewedAt: now),
        ];
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
              onOpenDetail: (_, __, {String? searchContext}) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('最近查看'), findsOneWidget);
      expect(find.text('题 A'), findsOneWidget);
      expect(find.text('题 B'), findsNothing);

      // 打开题 B 详情：走真实 DetailNotifier.load()，记一次查看
      // → FakeRepo 发 recentlyViewed 事件 → 首页重读历史。
      // （生产里这一步是详情页压栈；首页仍挂载、不重建、不重进。）
      final detailContainer = ProviderContainer.test(
        overrides: [
          repositoryProvider.overrideWithValue(repo),
          detailInitialProvider.overrideWithValue(
            const DetailInitial(questionId: 'q-b', orderIds: ['q-b']),
          ),
        ],
      );
      addTearDown(detailContainer.dispose);
      detailContainer.listen(detailProvider, (_, __) {});
      await detailContainer.read(detailProvider.notifier).load();
      expect(repo.recordedViews, ['q-b']);

      // 返回首页：只泵首页、不重建 ProviderScope、不重新进首页。
      await tester.pumpAndSettle();
      expect(find.text('题 B'), findsOneWidget);
      expect(find.text('题 A'), findsOneWidget);
      // 题 B 顶到首位：行在列表里的纵向位置高于题 A。
      final topB = tester.getTopLeft(find.byKey(const Key('home-history-q-b')));
      final topA = tester.getTopLeft(find.byKey(const Key('home-history-q-a')));
      expect(topB.dy, lessThan(topA.dy));
    });
  });
}

/// 首页 + 详情共用的 FakeRepo（只盖住本文件走到的 repo 方法；
/// 其余方法走基类会读真库——本文件不调它们）。
class _RefreshFakeRepo extends QuestionRepository {
  _RefreshFakeRepo() : super(AppDatabase.instance);

  List<({Question question, DateTime viewedAt})> historyList = const [];

  /// recentlyViewedQuestions 被调的次数（断言事件是否触发重读用）。
  int recentlyViewedCalls = 0;

  /// 置上时，第 1 次历史读取卡住，直到外部 complete（订阅时序测试用）。
  Completer<void>? blockFirstHistoryRead;

  /// 详情页记到的查看（按调用顺序）。
  final List<String> recordedViews = [];

  /// 详情加载用的题。
  List<Question> questions = const [];

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

  // FR-45（二十批 P3 后续分诊）：DetailNotifier.load() 内 unawaited
  // _refreshRelated 调 repo.all() + repo.causeRecords()；未覆写时走真实
  // QuestionRepository → 单例 db getter → 本文件数据层 tearDown 的
  // resetForTest 已把 testDataDirectory 置 null 的窗口里会打开真实演示库
  // 跑 v2→v7 迁移（探针 zz_probe_b12_test 复现：md5 9c5640… → 0a7e7dd0…，
  // 见 batch20-work/p3-followup/STATUS.md）。本文件整文件跑干净只因
  // load() 在 testWidgets（FakeAsync  stalls 真实 Drift 打开）且是最后
  // 一个测试；改 plain load 或在后面加测试即会咬人。causeRecords() 本
  // 文件已有桩；all() 补内存版。右栏无变化：本文件两题无共享错因 /
  // 知识点 / 文件夹，related 恒空。
  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<CauseRecord>> causeRecords() async => const [];

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<List<ExamEvent>> examEvents() async => const [];

  @override
  Future<List<({Question question, DateTime viewedAt})>>
  recentlyViewedQuestions() async {
    recentlyViewedCalls++;
    if (blockFirstHistoryRead != null && recentlyViewedCalls == 1) {
      await blockFirstHistoryRead!.future;
    }
    return List.of(historyList);
  }

  @override
  Future<void> recordQuestionViewed(String questionId) async {
    recordedViews.add(questionId);
    // 与生产扩展方法同款：写库（这里是更新 FakeRepo 的历史）成功后
    // 发一次 recentlyViewed 事件；生产侧发事件由数据层测试覆盖。
    final now = DateTime.now();
    final q = questions.where((e) => e.id == questionId).firstOrNull;
    if (q != null) {
      historyList = [
        (question: q, viewedAt: now),
        ...historyList.where((e) => e.question.id != questionId),
      ];
    }
    DataChangeBus.instance.emit(
      DataChangeEvent(
        kinds: {DataChangeKind.recentlyViewed},
        questionId: questionId,
      ),
    );
  }

  @override
  Future<Question?> questionById(String id) async =>
      questions.where((q) => q.id == id).firstOrNull;

  @override
  Future<List<CauseRecord>> causeRecordsFor(String questionId) async =>
      const [];

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
    String questionId,
  ) async => const [];

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [];

  @override
  Future<List<String>> tags() async => const [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  /// 十三批 M5：OCR 状态是 best-effort 加载（不 await）；返回空任务行
  /// 与“无 key”，不碰真实库（见 D-88）。
  @override
  Future<List<OcrJob>> ocrJobsForQuestion(String questionId) async =>
      const [];

  @override
  Future<bool> hasOcrApiKey() async => false;

  /// 详情页自愈（_healSliceIfNeeded）读同页框：无框，不碰真实库（见 D-88）。
  @override
  Future<List<QuestionBox>> boxesForPageImage(String pageImagePath) async =>
      const [];
}
