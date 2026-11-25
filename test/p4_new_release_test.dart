// P4 测试：新题释放 + 积压控制 + 完整验收（实施方案 v2 §6、§8、§10）。
//
// 覆盖：每日新增上限（默认 10/上限 50/设置改上限生效）/ 跨日 /
// 未完成续接不重耗额度、积压上限 10（昨日遗留 8 道今日最多再呈现 2 道）、
// 首次呈现不重计（退出恢复/第二天/内容重置后新版本重计）、
// 到期与新题区分显示（getDueQuestions 不含未释放新卡 + 行标）、
// 专项练习不改到期（练 20 道到期列表不变）、一次加 60 道只放 10 道、
// 复习会话只进当日到期 + 今日新题。
// 纯逻辑组用内存调度器；DB 组用 openForTest 内存库（P5 同款脚手架）；
// Notifier 组用 FakeRepo（只覆盖实际调的方法，不碰真实数据库）。
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' as fsrs;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/p4_new_release.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/state/review_notifier.dart';

const _today = '2026-11-25';
const _yesterday = '2026-11-24';

StoredCard _card(
  String questionId,
  int cardId, {
  DateTime? firstReviewedAt,
  DateTime? firstPresentedAt,
  String? firstPresentedLocalDate,
  int? firstPresentedContentVersion,
}) => StoredCard(
  questionId: questionId,
  cardId: cardId,
  card: fsrs.Card(cardId: cardId, due: DateTime.utc(2026, 11, 25, 9)),
  configId: 'fsrs-6-v1',
  firstReviewedAt: firstReviewedAt,
  firstPresentedAt: firstPresentedAt,
  firstPresentedLocalDate: firstPresentedLocalDate,
  firstPresentedContentVersion: firstPresentedContentVersion,
);

/// [n] 道未呈现新题（cardId 1..n，加入顺序即 id 顺序）。
List<StoredCard> _fresh(int n) => [
  for (var i = 1; i <= n; i++) _card('q$i', i),
];

/// [n] 道已呈现未完成的新题（首次呈现日期均为 [localDate]）。
List<StoredCard> _presented(int n, String localDate, {int startCardId = 1}) => [
  for (var i = 0; i < n; i++)
    _card(
      'p${startCardId + i}',
      startCardId + i,
      firstPresentedAt: DateTime.utc(2026, 11, 24, 9),
      firstPresentedLocalDate: localDate,
      firstPresentedContentVersion: 1,
    ),
];

FsrsReviewScheduler _memScheduler({InMemoryCardStore? store}) =>
    FsrsReviewScheduler(
      config: const SchedulerConfig(enableFuzzing: false),
      store: store ?? InMemoryCardStore(),
    );

void main() {
  group('P4 释放计划（纯逻辑）', () {
    test('默认每天释放 10 道：60 道未呈现只放 10 道，剩下 50 道待开始', () {
      final plan = planNewRelease(
        cards: _fresh(60),
        archivedIds: const {},
        dailyNewLimit: kDailyNewDefault,
        todayLocalDate: _today,
      );
      expect(plan.dailyLimit, 10);
      expect(plan.todaysNewIds, [for (var i = 1; i <= 10; i++) 'q$i']);
      expect(plan.newlyReleasableIds, plan.todaysNewIds);
      expect(plan.waitingIds.length, 50);
      expect(plan.waitingIds.first, 'q11');
      expect(plan.releaseAllowance, 10);
      expect(plan.pendingBacklogCount, 0);
      expect(plan.presentedTodayCount, 0);
      expect(plan.canReleaseMore, isTrue);
    });

    test('设置改上限 50 后每天最多放 50 道', () {
      final plan = planNewRelease(
        cards: _fresh(60),
        archivedIds: const {},
        dailyNewLimit: 50,
        todayLocalDate: _today,
      );
      expect(plan.todaysNewIds.length, 50);
      expect(plan.waitingIds.length, 10);
      expect(plan.releaseAllowance, 50);
    });

    test('上限归一：0 与负数夹到 1，超过 50 夹到 50', () {
      expect(clampDailyNewLimit(0), 1);
      expect(clampDailyNewLimit(-5), 1);
      expect(clampDailyNewLimit(1), 1);
      expect(clampDailyNewLimit(10), 10);
      expect(clampDailyNewLimit(50), 50);
      expect(clampDailyNewLimit(99), 50);
      expect(AppSettings.defaults.copyWith(dailyNewQuestions: 99).dailyNewQuestions, 50);
      expect(AppSettings.fromMap({'dailyNewQuestions': '77'}).dailyNewQuestions, 50);
      expect(AppSettings.fromMap({}).dailyNewQuestions, 10);
      expect(AppSettings.defaults.dailyNewQuestions, 10);
    });

    test('本地日期字符串：按本地日历日切，yyyy-MM-dd', () {
      expect(localDateString(DateTime(2026, 11, 25, 9, 5)), '2026-11-25');
      expect(localDateString(DateTime(2026, 1, 5)), '2026-01-05');
    });

    test('昨日遗留 8 道：今日最多再呈现 2 道，遗留优先续接', () {
      final cards = [
        ..._presented(8, _yesterday, startCardId: 1),
        ..._fresh(4).map(
          (c) => _card('q${c.cardId}', c.cardId + 8),
        ),
      ];
      final plan = planNewRelease(
        cards: cards,
        archivedIds: const {},
        dailyNewLimit: 10,
        todayLocalDate: _today,
      );
      expect(plan.pendingBacklogCount, 8);
      expect(plan.releaseAllowance, 2);
      expect(plan.carryoverIds.length, 8);
      expect(plan.todaysNewIds.length, 10);
      expect(plan.todaysNewIds.sublist(0, 8), plan.carryoverIds);
      expect(plan.newlyReleasableIds.length, 2);
      expect(plan.waitingIds.length, 2);
    });

    test('待完成新题满 10 道：暂停释放额外新题，有空位才继续', () {
      final cards = [
        ..._presented(10, _yesterday, startCardId: 1),
        ..._fresh(5).map((c) => _card('q${c.cardId}', c.cardId + 10)),
      ];
      // 默认每日上限 10 时积压上限就是 10：满 10 道一题也不放。
      // （每日上限调到 50 时积压上限跟到 50，见“设置改上限 50”那组。）
      final plan = planNewRelease(
        cards: cards,
        archivedIds: const {},
        dailyNewLimit: kDailyNewDefault,
        todayLocalDate: _today,
      );
      expect(plan.pendingBacklogCount, 10);
      expect(plan.releaseAllowance, 0);
      expect(plan.canReleaseMore, isFalse);
      expect(plan.newlyReleasableIds, isEmpty);
      expect(plan.todaysNewIds.length, 10);
      expect(plan.waitingIds.length, 5);
    });

    test('今日已呈现 6 道：今日剩余额度 4 道，续接不重耗额度', () {
      final cards = [
        ..._presented(6, _today, startCardId: 1),
        ..._fresh(6).map((c) => _card('q${c.cardId}', c.cardId + 6)),
      ];
      final plan = planNewRelease(
        cards: cards,
        archivedIds: const {},
        dailyNewLimit: 10,
        todayLocalDate: _today,
      );
      expect(plan.presentedTodayCount, 6);
      expect(plan.pendingBacklogCount, 6);
      expect(plan.releaseAllowance, 4);
      expect(plan.todaysNewIds.length, 10);
      expect(plan.waitingIds.length, 2);
    });

    test('跨日：昨日呈现的不计入今日已呈现，第二天优先续接', () {
      final cards = [
        ..._presented(3, _yesterday, startCardId: 1),
        ..._fresh(3).map((c) => _card('q${c.cardId}', c.cardId + 3)),
      ];
      final plan = planNewRelease(
        cards: cards,
        archivedIds: const {},
        dailyNewLimit: 10,
        todayLocalDate: _today,
      );
      expect(plan.presentedTodayCount, 0);
      expect(plan.carryoverIds.length, 3);
      expect(plan.todaysNewIds.length, 6);
      expect(plan.waitingIds, isEmpty);
    });

    test('已开始正式复习的题永远不再算新题', () {
      final cards = [
        _card('done1', 1, firstReviewedAt: DateTime.utc(2026, 11, 20, 9)),
        _card(
          'done2',
          2,
          firstReviewedAt: DateTime.utc(2026, 11, 20, 9),
          firstPresentedAt: DateTime.utc(2026, 11, 19, 9),
          firstPresentedLocalDate: '2026-11-19',
          firstPresentedContentVersion: 1,
        ),
        ..._fresh(3).map((c) => _card('q${c.cardId}', c.cardId + 2)),
      ];
      final plan = planNewRelease(
        cards: cards,
        archivedIds: const {},
        dailyNewLimit: 10,
        todayLocalDate: _today,
      );
      expect(plan.todaysNewIds, ['q1', 'q2', 'q3']);
      expect(plan.waitingIds, isEmpty);
      expect(plan.pendingBacklogCount, 0);
    });

    test('归档题保留卡片但不进新题队列', () {
      final plan = planNewRelease(
        cards: _fresh(12),
        archivedIds: {'q1', 'q2'},
        dailyNewLimit: 10,
        todayLocalDate: _today,
      );
      expect(plan.todaysNewIds.length, 10);
      expect(plan.todaysNewIds, isNot(contains('q1')));
      expect(plan.todaysNewIds, isNot(contains('q2')));
      expect(plan.waitingIds, isEmpty);
    });

    test('列表标：到期优先于新题，待开始不混入到期', () {
      const due = {'q1'};
      const todaysNew = {'q2'};
      const waiting = {'q3'};
      expect(
        fsrsListLabel(
          questionId: 'q1',
          dueIds: due,
          todaysNewIds: todaysNew,
          waitingIds: waiting,
        ),
        '到期',
      );
      expect(
        fsrsListLabel(
          questionId: 'q2',
          dueIds: due,
          todaysNewIds: todaysNew,
          waitingIds: waiting,
        ),
        '今日新题',
      );
      expect(
        fsrsListLabel(
          questionId: 'q3',
          dueIds: due,
          todaysNewIds: todaysNew,
          waitingIds: waiting,
        ),
        '待开始',
      );
      expect(
        fsrsListLabel(
          questionId: 'q9',
          dueIds: due,
          todaysNewIds: todaysNew,
          waitingIds: waiting,
        ),
        isNull,
      );
    });
  });

  group('P4 调度器隔离：新卡不算到期，重置后重新进待释放', () {
    test('getDueQuestions 不含未释放新卡；getNewQuestions 只给新题', () async {
      final store = InMemoryCardStore();
      final scheduler = _memScheduler(store: store);
      await scheduler.initializeQuestion('new1');
      await scheduler.initializeQuestion('new2');
      await scheduler.initializeQuestion('due1');
      // due1 在 5 天前答对：Good 间隔约 2 天，到期日已过。
      await scheduler.recordAnswer(
        'due1',
        ReviewResult.good,
        DateTime.utc(2026, 11, 20, 9),
        'evt-due1',
      );
      final now = DateTime.utc(2026, 11, 25, 9);
      expect(await scheduler.getDueQuestions(now), ['due1']);
      expect(
        await scheduler.getNewQuestions(10),
        ['new1', 'new2'],
      );
      expect(await scheduler.loadAllCards(), hasLength(3));
    });

    test('内容重置后首次呈现清空，重新进待释放状态，card_id 不变', () async {
      final store = InMemoryCardStore();
      final scheduler = _memScheduler(store: store);
      await scheduler.initializeQuestion('q1');
      final before = (await store.load('q1'))!;
      await store.save(
        before.copyWithCard(
          before.card,
          firstPresentedAt: DateTime.utc(2026, 11, 25, 9),
          firstPresentedLocalDate: _today,
          firstPresentedContentVersion: 1,
        ),
      );
      var plan = planNewRelease(
        cards: await scheduler.loadAllCards(),
        archivedIds: const {},
        dailyNewLimit: 10,
        todayLocalDate: _today,
      );
      expect(plan.presentedTodayCount, 1);
      expect(plan.waitingIds, isEmpty);
      await scheduler.resetQuestion('q1');
      final after = (await store.load('q1'))!;
      expect(after.cardId, before.cardId);
      expect(after.firstPresentedAt, isNull);
      plan = planNewRelease(
        cards: await scheduler.loadAllCards(),
        archivedIds: const {},
        dailyNewLimit: 10,
        todayLocalDate: _today,
      );
      expect(plan.presentedTodayCount, 0);
      expect(plan.todaysNewIds, ['q1']);
    });
  });

  group('P4 仓库 + 真实库', () {
    late QuizDatabase db;
    late QuestionRepository repo;
    late FsrsReviewScheduler scheduler;

    setUp(() async {
      db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      repo = QuestionRepository(AppDatabase.instance);
      scheduler = FsrsReviewScheduler(
        config: const SchedulerConfig(enableFuzzing: false),
        store: SqliteCardStore.forDatabase(db),
      );
    });

    tearDown(() async {
      await AppDatabase.resetForTest();
    });

    Question q(String id) => Question(
      id: id,
      title: '题 $id',
      subjectId: 'math',
      errorTypes: const ['概念不清'],
      createdAt: DateTime(2026, 11, 8),
      isOrganized: true,
      reviewJoined: true,
      sliceKind: 'material',
      sliceText: '题：$id',
      contentVersion: 1,
      questionType: 'choice_single',
      optionLabels: const ['A', 'B', 'C', 'D'],
      correctOption: 'B',
      answer: 'B',
    );

    Future<Map<String, Object?>> cardRow(String qid) async =>
        (await db
                .customSelect(
                  'SELECT * FROM fsrs_cards WHERE question_id = ?',
                  variables: [Variable.withString(qid)],
                )
                .getSingle())
            .data;

    AttemptData attempt({
      required String id,
      required String qid,
      required String sessionId,
      required String mode,
      int? correct,
      required String submissionId,
    }) => AttemptData(
      id: id,
      questionId: qid,
      sessionId: sessionId,
      mode: mode,
      selected: const ['B'],
      correct: correct,
      confidence: null,
      answerVersion: 1,
      contentVersion: 1,
      status: '已提交',
      causeIds: const ['概念不清'],
      submissionId: submissionId,
      createdAt: DateTime.utc(2026, 11, 25, 10).millisecondsSinceEpoch,
    );

    test('一次加 60 道：当天待练新题只多 10 道，剩下排队；上限改 50 后放 50 道', () async {
      final questions = [for (var i = 1; i <= 60; i++) q('q$i')];
      for (final question in questions) {
        await AppDatabase.upsertQuestionInto(db, question);
      }
      final outcome = await repo.joinFsrsPool(
        questions: questions,
        scheduler: scheduler,
      );
      expect((outcome.added, outcome.skipped), (60, 0));
      var plan = await repo.previewNewRelease(
        scheduler: scheduler,
        dailyNewLimit: 10,
      );
      expect(plan.todaysNewIds.length, 10);
      expect(plan.waitingIds.length, 50);
      expect(plan.pendingBacklogCount, 0);
      // 设置改上限 50 后每天最多放 50 道（验收 §10-4 后半句）。
      plan = await repo.previewNewRelease(
        scheduler: scheduler,
        dailyNewLimit: 50,
      );
      expect(plan.todaysNewIds.length, 50);
      expect(plan.waitingIds.length, 10);
      // 重复加同一批：去重，已在池的全部跳过，不建第二张卡。
      final again = await repo.joinFsrsPool(
        questions: questions,
        scheduler: scheduler,
      );
      expect((again.added, again.skipped), (0, 60));
      expect(await scheduler.pooledQuestionIds(), hasLength(60));
    });

    test('recordQuestionPresented：首次显示写一次，退出恢复/第二天不重计', () async {
      await AppDatabase.upsertQuestionInto(db, q('q1'));
      await scheduler.initializeQuestion('q1');
      final t1 = DateTime(2026, 11, 25, 9); // 本地时间（测试机时区）
      expect(await repo.recordQuestionPresented(question: q('q1'), now: t1), isTrue);
      var row = await cardRow('q1');
      expect(row['first_presented_at'], t1.toUtc().millisecondsSinceEpoch);
      expect(row['first_presented_local_date'], localDateString(t1));
      // 同一天再显示：不重计。
      expect(
        await repo.recordQuestionPresented(
          question: q('q1'),
          now: DateTime(2026, 11, 25, 15),
        ),
        isFalse,
      );
      // 第二天再显示：不重计（同版本）。
      expect(
        await repo.recordQuestionPresented(
          question: q('q1'),
          now: DateTime(2026, 11, 26, 9),
        ),
        isFalse,
      );
      row = await cardRow('q1');
      expect(row['first_presented_local_date'], localDateString(t1));
      // 内容新版本：重新计。
      expect(
        await repo.recordQuestionPresented(
          question: q('q1').copyWith(contentVersion: 2),
          now: DateTime(2026, 11, 27, 9),
        ),
        isTrue,
      );
      row = await cardRow('q1');
      expect(row['first_presented_content_version'], 2);
    });

    test('积压：昨日遗留 8 道，今日最多再呈现 2 道', () async {
      for (var i = 1; i <= 12; i++) {
        await AppDatabase.upsertQuestionInto(db, q('q$i'));
        await scheduler.initializeQuestion('q$i');
      }
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      for (var i = 1; i <= 8; i++) {
        expect(
          await repo.recordFirstPresented(
            questionId: 'q$i',
            presentedAtUtc: yesterday.toUtc(),
            localDate: localDateString(yesterday),
            contentVersion: 1,
          ),
          isTrue,
        );
      }
      final plan = await repo.previewNewRelease(
        scheduler: scheduler,
        dailyNewLimit: 10,
      );
      expect(plan.pendingBacklogCount, 8);
      expect(plan.releaseAllowance, 2);
      expect(plan.todaysNewIds.length, 10);
      expect(plan.waitingIds.length, 2);
    });

    test('专项练习不改到期时间：练 20 道，到期列表与下次到期不变', () async {
      await AppDatabase.upsertQuestionInto(db, q('due1'));
      await scheduler.initializeQuestion('due1');
      await scheduler.recordAnswer(
        'due1',
        ReviewResult.good,
        DateTime.utc(2026, 11, 20, 9),
        'evt-due1',
      );
      final now = DateTime.utc(2026, 11, 25, 9);
      final dueBefore = await scheduler.getDueQuestions(now);
      final nextDueBefore = await scheduler.nextDueAt('due1');
      expect(dueBefore, ['due1']);
      // 20 道专项练习作答（result 为 null：只写 attempts，不推进 FSRS）。
      // 每道用不同 sessionId：attempts 对 (session_id, question_id)
      // 唯一，同会话同题只留一行，20 道须分属 20 个会话才各记一条。
      for (var i = 0; i < 20; i++) {
        await repo.submitReviewCheck(
          attempt: attempt(
            id: 'att-p$i',
            qid: 'due1',
            sessionId: 'sess-practice-$i',
            mode: '专项练习',
            correct: i.isEven ? 1 : 0,
            submissionId: 'attsub-p$i',
          ),
          result: null,
          reviewedAt: now,
          eventId: 'attsub-p$i',
          scheduler: scheduler,
        );
      }
      expect(await scheduler.getDueQuestions(now), dueBefore);
      expect(await scheduler.nextDueAt('due1'), nextDueBefore);
      // attempts 里确实记了 20 条专项练习事实（只练不排，事实保留）。
      final n = (await db
              .customSelect(
                "SELECT COUNT(*) AS n FROM attempts WHERE mode = '专项练习'",
              )
              .getSingle())
          .data['n'];
      expect(n, 20);
    });
  });

  group('P4 复习页 Notifier：当日清单 + 会话只进当日题', () {
    late _FakeP4Repo repo;
    late InMemoryCardStore store;
    late FsrsReviewScheduler scheduler;
    late ProviderContainer container;

    setUp(() {
      store = InMemoryCardStore();
      scheduler = _memScheduler(store: store);
      repo = _FakeP4Repo(store: store, scheduler: scheduler);
      container = ProviderContainer.test(
        overrides: [
          repositoryProvider.overrideWithValue(repo),
          reviewSchedulerProvider.overrideWithValue(scheduler),
        ],
      );
      addTearDown(container.dispose);
      container.listen(reviewProvider, (_, __) {});
    });

    Future<void> waitFor(bool Function(ReviewState s) done) async {
      for (var i = 0; i < 100 && !done(container.read(reviewProvider)); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    /// 池子搭好后显式重载（容器创建时的首查可能在 pool() 之前就跑完，
    /// 那时库还是空的；重载后按池内题数等清单落定）。
    Future<void> reloadAndWait(int poolSize) async {
      await container.read(reviewProvider.notifier).load();
      await waitFor((s) => s.fsrsPoolIds.length == poolSize);
    }

    Future<void> pool(int n) async {
      repo.questions = [
        for (var i = 1; i <= n; i++)
          _rq('q$i', '题 q$i', reviewJoined: true),
      ];
      repo.records = [
        for (var i = 1; i <= n; i++) _rec('q$i'),
      ];
      for (var i = 1; i <= n; i++) {
        await scheduler.initializeQuestion('q$i');
      }
    }

    test('load 后当日清单：12 道在池，今日新题 10 道、待开始 2 道', () async {
      await pool(12);
      await reloadAndWait(12);
      final st = container.read(reviewProvider);
      expect(st.fsrsPoolIds.length, 12);
      expect(st.fsrsTodaysNewIds.length, 10);
      expect(st.fsrsWaitingIds.length, 2);
      expect(st.fsrsDueIds, isEmpty);
      expect(st.fsrsPresentedTodayCount, 0);
      expect(st.fsrsPendingBacklogCount, 0);
    });

    test('设置每日新增改 50：12 道全放，待开始 0 道', () async {
      repo.settingsValue = AppSettings.defaults.copyWith(
        dailyNewQuestions: 50,
      );
      await pool(12);
      await reloadAndWait(12);
      final st = container.read(reviewProvider);
      expect(st.fsrsTodaysNewIds.length, 12);
      expect(st.fsrsWaitingIds, isEmpty);
    });

    test('开始到期复习：会话只进今日新题 10 道，首题记首次呈现，待开始不进会话', () async {
      await pool(12);
      await reloadAndWait(12);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.startSession();
      final st = container.read(reviewProvider);
      expect(st.inSession, isTrue);
      expect(st.sessionQuestions.length, 10);
      expect(
        st.sessionQuestions.map((sq) => sq.questionId).toSet(),
        st.fsrsTodaysNewIds,
      );
      expect(
        st.sessionQuestions.map((sq) => sq.questionId),
        isNot(contains('q11')),
      );
      // 首题进入“看题”步：首次呈现已记（unawaited，轮询等它落库）。
      final firstId = st.sessionQuestions.first.questionId;
      await waitFor(
        (_) => repo.presentedLocalDate(firstId) != null,
      );
      expect(repo.presentedLocalDate(firstId), isNotNull);
      // 待开始的两道题没被呈现。
      expect(repo.presentedLocalDate('q11'), isNull);
      expect(repo.presentedLocalDate('q12'), isNull);
    });

    test('积压 8 道昨日遗留：会话 10 道（8 续接 + 2 新放），剩下 2 道待开始', () async {
      await pool(12);
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      for (var i = 1; i <= 8; i++) {
        final card = (await store.load('q$i'))!;
        await store.save(
          card.copyWithCard(
            card.card,
            firstPresentedAt: yesterday.toUtc(),
            firstPresentedLocalDate: localDateString(yesterday),
            firstPresentedContentVersion: 1,
          ),
        );
      }
      await reloadAndWait(12);
      var st = container.read(reviewProvider);
      expect(st.fsrsPendingBacklogCount, 8);
      expect(st.fsrsTodaysNewIds.length, 10);
      expect(st.fsrsWaitingIds.length, 2);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.startSession();
      st = container.read(reviewProvider);
      expect(st.sessionQuestions.length, 10);
      expect(
        st.sessionQuestions.map((sq) => sq.questionId).toSet(),
        st.fsrsTodaysNewIds,
      );
    });

    test('专项练习不记首次呈现：只练不排，不耗新题额度', () async {
      await pool(3);
      await reloadAndWait(3);
      final notifier = container.read(reviewProvider.notifier);
      final outcome = await notifier.startPracticeWithIds(['q1', 'q2']);
      expect(outcome, PracticeStartOutcome.started);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(repo.presentedLocalDate('q1'), isNull);
      expect(repo.presentedLocalDate('q2'), isNull);
    });
  });
}

Question _rq(
  String id,
  String title, {
  bool reviewJoined = false,
}) => Question(
  id: id,
  title: title,
  subjectId: 'math',
  errorTypes: const ['概念不清'],
  createdAt: DateTime(2026, 11, 8),
  isOrganized: true,
  reviewJoined: reviewJoined,
  sliceKind: 'material',
  sliceText: '题：$title',
);

CauseRecord _rec(String questionId, {String cause = '概念不清'}) =>
    CauseRecord(
      questionId: questionId,
      cause: cause,
      subjectId: 'math',
      joinedAt: DateTime(2026, 11, 10),
    );

/// P4 Notifier 用 Fake：只覆盖实际调的方法；首次呈现走内存 store
/// 模拟（与 SqliteCardStore 同语义：同版本只写一次）。
class _FakeP4Repo extends QuestionRepository {
  _FakeP4Repo({required this.store, required this.scheduler})
    : super(AppDatabase.instance);

  final InMemoryCardStore store;
  final FsrsReviewScheduler scheduler;
  List<Question> questions = [];
  List<CauseRecord> records = [];
  AppSettings settingsValue = AppSettings.defaults;
  ReviewSessionState? savedState;
  final Map<String, AttemptData> attempts = {};

  String? presentedLocalDate(String questionId) => _presented[questionId];
  final Map<String, String> _presented = {};

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<AppSettings> settings() async => settingsValue;

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
    String questionId,
  ) async => const [];

  @override
  Future<ReviewSessionState?> reviewState() async => savedState;

  @override
  Future<void> saveReviewState({
    required List<ReviewQueueItem> queue,
    required int position,
    String? sessionId,
    String? mode,
    Map<String, int>? skips,
    Map<String, Map<String, Object?>>? perQuestionState,
  }) async =>
      savedState = ReviewSessionState(
        queue: queue,
        position: position,
        updatedAt: DateTime.now(),
        sessionId: sessionId,
        mode: mode,
        skips: skips ?? const {},
        perQuestionState: perQuestionState ?? const {},
      );

  @override
  Future<void> clearReviewState() async {
    savedState = null;
  }

  @override
  Future<bool> setReviewJoined(Question q, bool joined) async {
    if (q.allCauses.isEmpty) return false;
    final i = questions.indexWhere((e) => e.id == q.id);
    if (i >= 0) questions[i] = q.copyWith(reviewJoined: joined);
    return true;
  }

  @override
  Future<Set<String>> fsrsPoolQuestionIds() async =>
      scheduler.pooledQuestionIds();

  @override
  Future<FsrsReleasePlan> previewNewRelease({
    required ReviewScheduler scheduler,
    required int dailyNewLimit,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    return planNewRelease(
      cards: await scheduler.loadAllCards(),
      archivedIds: {
        for (final q in questions)
          if (q.isArchived) q.id,
      },
      dailyNewLimit: dailyNewLimit,
      todayLocalDate: localDateString(at),
    );
  }

  @override
  Future<List<String>> fsrsDueQuestionIds({
    required ReviewScheduler scheduler,
    DateTime? now,
  }) async {
    final due = await scheduler.getDueQuestions(now ?? DateTime.now());
    final archived = {
      for (final q in questions)
        if (q.isArchived) q.id,
    };
    return due.where((id) => !archived.contains(id)).toList();
  }

  @override
  Future<bool> recordQuestionPresented({
    required Question question,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final card = await store.load(question.id);
    if (card == null) return false;
    if (card.firstPresentedContentVersion == question.contentVersion) {
      return false;
    }
    await store.save(
      card.copyWithCard(
        card.card,
        firstPresentedAt: at.toUtc(),
        firstPresentedLocalDate: localDateString(at),
        firstPresentedContentVersion: question.contentVersion,
      ),
    );
    _presented[question.id] = localDateString(at);
    return true;
  }

  @override
  Future<String> recordAttempt(AttemptData attempt) async {
    attempts['${attempt.sessionId}|${attempt.questionId}'] = attempt;
    return attempt.id;
  }

  @override
  Future<AttemptData?> loadAttempt({
    required String sessionId,
    required String questionId,
  }) async => attempts['$sessionId|$questionId'];

  @override
  Future<List<AttemptData>> loadAttemptsForSession(String sessionId) async =>
      attempts.values.where((a) => a.sessionId == sessionId).toList();
}
