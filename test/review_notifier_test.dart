// ARCH-PLAN-A 第 3 阶段：ReviewNotifier 单测（不启动 widget）。
// P2 简化基线：三段统一流程（看题 → 作答 → 核对 → 下一题 → 小结），
// 一道题内部的状态变化；核对提交是唯一正式提交入口（写 attempts +
// 调 FSRS，如适用）。一题多错因时题目只展示一次。
// 注入方式与 settings_controller_test.dart / home_provider_test.dart
// 一致：ProviderContainer.test + repositoryProvider.overrideWithValue。
// autoDispose 下单测要像页面 ref.watch 那样持一个监听保活
// （D-36：只 read 不监听时 build 里的 microtask 首查还没写回就被
// 销毁，轮询等不到 hasLoaded），见 `_container`。
// 调度器经 reviewSchedulerProvider 注入确定性实现（fuzzing 关），
// 测试用 container.read(reviewSchedulerProvider) 拿同一实例断言。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/state/review_notifier.dart';

Question _rq(
  String id,
  String title, {
  String subjectId = 'math',
  List<String> errorTypes = const [],
  DateTime? createdAt,
  bool isOrganized = true,
  bool reviewJoined = false,
  bool isArchived = false,
}) =>
    Question(
      id: id,
      title: title,
      subjectId: subjectId,
      errorTypes: errorTypes,
      createdAt: createdAt ?? DateTime(2026, 11, 8),
      isOrganized: isOrganized,
      reviewJoined: reviewJoined,
      isArchived: isArchived,
      sliceKind: 'material',
      sliceText: '题：$title',
    );

CauseRecord _rec(
  String questionId,
  String cause, {
  String subjectId = 'math',
  DateTime? joinedAt,
}) =>
    CauseRecord(
      questionId: questionId,
      cause: cause,
      subjectId: subjectId,
      joinedAt: joinedAt ?? DateTime(2026, 11, 10),
    );

class FakeReviewNotifierRepo extends QuestionRepository {
  FakeReviewNotifierRepo({
    required this.questions,
    required this.records,
    AppSettings? settings,
    this.throwOnCheck = false,
    List<Subject>? subjects,
  })  : settingsValue = settings ?? AppSettings.defaults,
        subjectsValue = subjects ?? Subject.all,
        super(AppDatabase.instance);

  List<Question> questions;
  List<CauseRecord> records;
  AppSettings settingsValue;
  bool throwOnCheck;
  List<Subject> subjectsValue;
  ReviewSessionState? savedState;
  bool throwOnLoad = false;

  final Map<String, List<({String result, DateTime reviewedAt})>> history =
      {};
  final Map<String, AttemptData> attempts = {};

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => [];

  @override
  Future<AppSettings> settings() async {
    if (throwOnLoad) throw StateError('boom');
    return settingsValue;
  }

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
          String questionId) async =>
      List.of(history[questionId] ?? const []);

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
  Future<String> recordAttempt(AttemptData attempt) async {
    if (throwOnCheck) throw StateError('save failed');
    attempts['${attempt.sessionId}|${attempt.questionId}'] = attempt;
    return attempt.id;
  }

  // P5：submitCheck 改走 repo.submitReviewCheck（事务双写）；Fake
  // 不碰真实数据库，这里用旧的两步行为复刻（写 attempts + 调调度器），
  // 事务语义由 P5 测试对真实库验证。throwOnCheck 时 recordAttempt
  // 先抛错，submitCheck 仍走 saveError 分支。
  @override
  Future<({String attemptId, DateTime? nextDue})> submitReviewCheck({
    required AttemptData attempt,
    required ReviewResult? result,
    required DateTime reviewedAt,
    required String eventId,
    required ReviewScheduler scheduler,
  }) async {
    final attemptId = await recordAttempt(attempt);
    DateTime? nextDue;
    if (result != null) {
      await scheduler.recordAnswer(
        attempt.questionId,
        result,
        reviewedAt,
        eventId,
      );
      nextDue = await scheduler.nextDueAt(attempt.questionId);
    }
    return (attemptId: attemptId, nextDue: nextDue);
  }

  @override
  Future<AttemptData?> loadAttempt({
    required String sessionId,
    required String questionId,
  }) async =>
      attempts['$sessionId|$questionId'];

  @override
  Future<List<AttemptData>> loadAttemptsForSession(
          String sessionId) async =>
      attempts.values.where((a) => a.sessionId == sessionId).toList();

  /// FSRS 全量迁移包2：假池（内存 Set）复刻 joinFsrsPool 的幂等语义——
  /// 不在池建卡（计 added）、已在池跳过（计 skipped）、不重置状态、
  /// 不碰 cause_records（状态列冻结）。旧 rejoinCause 桩已随方法删除。
  final Set<String> pooledIds = {};

  @override
  Future<({int added, int skipped, int failed})> joinFsrsPool({
    required List<Question> questions,
    required ReviewScheduler scheduler,
  }) async {
    var added = 0;
    var skipped = 0;
    for (final q in questions) {
      if (pooledIds.add(q.id)) {
        added++;
        final qi = this.questions.indexWhere((e) => e.id == q.id);
        if (qi >= 0) {
          this.questions[qi] =
              this.questions[qi].copyWith(reviewJoined: true);
        }
      } else {
        skipped++;
      }
    }
    return (added: added, skipped: skipped, failed: 0);
  }

  @override
  Future<CauseRecord> saveRemedy(CauseRecord r, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return r;
    final now = DateTime.now();
    final entry = '${now.year}-${now.month}-${now.day}：$trimmed';
    final updated =
        r.copyWith(remedyHistory: [entry, ...r.remedyHistory]);
    final i = records.indexWhere(
        (x) => x.questionId == r.questionId && x.cause == r.cause);
    if (i >= 0) records[i] = updated;
    return updated;
  }
}

FakeReviewNotifierRepo _reviewRepo({int pageSize = 10}) {
  final now = DateTime(2026, 11, 10);
  return FakeReviewNotifierRepo(
    settings: AppSettings.defaults.copyWith(pageSize: pageSize),
    questions: [
      _rq('q1', '函数极限',
          errorTypes: const ['概念不清'],
          createdAt: DateTime(2026, 11, 8),
          reviewJoined: true),
      _rq('q2', '导数应用综合',
          errorTypes: const ['方法不会', '计算错误'],
          createdAt: DateTime(2026, 11, 9),
          reviewJoined: true),
      _rq('q3', '学术词汇辨析',
          subjectId: 'english',
          errorTypes: const ['概念不清'],
          createdAt: DateTime(2026, 11, 7),
          reviewJoined: true),
      _rq('q4', '马原',
          subjectId: 'politics',
          errorTypes: const ['概念不清'],
          createdAt: DateTime(2026, 11, 6)),
      _rq('q5', '未整理题',
          errorTypes: const ['方法不会'],
          createdAt: DateTime(2026, 11, 5),
          isOrganized: false,
          reviewJoined: true),
    ],
    records: [
      _rec('q1', '概念不清', joinedAt: now),
      _rec('q2', '方法不会',
          joinedAt: now.add(const Duration(hours: 1))),
      _rec('q2', '计算错误', joinedAt: now.add(const Duration(hours: 1))),
      _rec('q3', '概念不清',
          subjectId: 'english',
          joinedAt: now.subtract(const Duration(hours: 1))),
      _rec('q5', '方法不会', joinedAt: now),
    ],
  );
}

FakeReviewNotifierRepo _singleRepo() {
  final repo = _reviewRepo();
  repo.questions = [
    _rq('q1', '函数极限',
        errorTypes: const ['概念不清'],
        createdAt: DateTime(2026, 11, 8),
        reviewJoined: true),
  ];
  repo.records = [
    _rec('q1', '概念不清', joinedAt: DateTime(2026, 11, 10)),
  ];
  return repo;
}

/// P2：确定性调度器（fuzzing 关），经 reviewSchedulerProvider 注入；
/// 测试用 container.read(reviewSchedulerProvider) 拿同一实例断言 FSRS 状态。
FsrsReviewScheduler _testScheduler() => FsrsReviewScheduler(
  config: const SchedulerConfig(enableFuzzing: false),
  store: InMemoryCardStore(),
);

/// FSRS 全量迁移包2：到期会话只走 FSRS——先给题建已到期的卡再 load，
/// 否则池空、startSession 建不出队列（旧回落已删）。建卡 + 3 天前答对
/// 一次（Good 首间隔 2 天，到期日在昨天）。
Future<void> _seedDueCards(
  ProviderContainer container,
  List<String> ids,
) async {
  final scheduler = container.read(reviewSchedulerProvider);
  for (final id in ids) {
    await scheduler.initializeQuestion(id);
    await scheduler.recordAnswer(
      id,
      ReviewResult.good,
      DateTime.now().subtract(const Duration(days: 3)),
      'evt-rn-$id',
    );
  }
}

ProviderContainer _container(
  FakeReviewNotifierRepo repo, {
  String? initialSubjectId,
}) {
  final container = ProviderContainer.test(
    overrides: [
      repositoryProvider.overrideWithValue(repo),
      reviewSchedulerProvider.overrideWithValue(_testScheduler()),
      if (initialSubjectId != null)
        reviewInitialProvider.overrideWithValue(
          ReviewInitial(subjectId: initialSubjectId),
        ),
    ],
  );
  addTearDown(container.dispose);
  // autoDispose 保活（D-36）：像页面 ref.watch 那样持一个监听，
  // 否则 build 里的 microtask 首查还没写回就被销毁。
  container.listen(reviewProvider, (_, __) {});
  return container;
}

Future<void> _waitFor(
  ProviderContainer container,
  bool Function(ReviewState s) done,
) async {
  for (var i = 0; i < 100 && !done(container.read(reviewProvider)); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// 走完一道题的前两段，到核对步（纸上作答：无标准答案，不判分）。
Future<void> _walkToCheck(ReviewNotifier notifier) async {
  notifier.beginAnswer();
  await notifier.completePaperAnswer();
}

/// 走完一道题并核对提交（P2：核对提交是唯一正式提交入口）。
Future<void> _walkAndCommit(ReviewNotifier notifier) async {
  await _walkToCheck(notifier);
  await notifier.submitCheck();
}

void main() {
  group('ReviewNotifier load', () {
    test('load()：4 组全错因（已治愈 q3 不再分流），未加入盒只 1 道，未开始 3 道',
        () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      final s = container.read(reviewProvider);
      expect(s.loading, isFalse);
      expect(s.loadError, isFalse);
      expect(s.hasLoaded, isTrue);
      // FSRS 全量迁移包2：分组不再按治愈状态拆两组；q3 已治愈的错因
      // 仍在组内——math 3 组（q1 一因、q2 两因）+ english 1 组（q3）。
      // 默认 joinTime 排序：q3 的记录加入最早（11/9 23:00），排最前。
      expect(s.groups.length, 4);
      expect(
        s.groups.map((g) => '${g.subjectId}|${g.cause}').toList(),
        [
          'english|概念不清',
          'math|概念不清',
          'math|方法不会',
          'math|计算错误',
        ],
      );
      expect(s.notJoined.map((q) => q.id), ['q4']);
      // 无 FSRS 卡：三道已列入的题全落「未开始」，未到期 0 道。
      expect(s.fsrsCardStatus, isEmpty);
      expect(s.fsrsFutureCounts, (0, 3));
      expect(s.resume, isNull);
      expect(s.allCauses, ['概念不清', '计算错误', '方法不会']);
    });

    test('build() 触发首查：只读 state 也能等到加载完成', () async {
      final container = _container(_reviewRepo());
      container.read(reviewProvider);
      await _waitFor(container, (s) => s.hasLoaded);
      expect(container.read(reviewProvider).hasLoaded, isTrue);
      expect(container.read(reviewProvider).groups.length, 4);
    });

    test('初始学科筛选走 reviewInitialProvider：带 english 进来只留英语组',
        () async {
      final container = _container(_reviewRepo(), initialSubjectId: 'english');
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      final s = container.read(reviewProvider);
      expect(s.subjectFilter, 'english');
      // FSRS 全量迁移包2：分组不再按治愈拆两组，英语组就在 groups 里，
      // 筛选后 filtered 只剩 q3 所在的 english|概念不清一组（旧口径
      // 里英语组在 curedGroups，filtered 为空）。
      expect(s.filtered.length, 1);
      // FSRS 全量迁移包2：curedGroups 已删；英语筛选后只剩 q3 所在的
      // english|概念不清一组。
      expect(s.filterGroups(s.groups).length, 1);
      expect(
        s.filterGroups(s.groups).single.items.single.question.id,
        'q3',
      );
    });

    test('读库失败：loadError，hasLoaded false；retry 成功后恢复', () async {
      final repo = _reviewRepo()..throwOnLoad = true;
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      var s = container.read(reviewProvider);
      expect(s.loading, isFalse);
      expect(s.loadError, isTrue);
      expect(s.hasLoaded, isFalse);
      repo.throwOnLoad = false;
      await notifier.retryLoad();
      s = container.read(reviewProvider);
      expect(s.loadError, isFalse);
      expect(s.hasLoaded, isTrue);
      // FSRS 全量迁移包2：分组不再按治愈拆两组，共 4 组。
      expect(s.groups.length, 4);
    });

    test('筛选回第 1 页、每页条数只改本页：设置默认值不动', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      notifier.setPage(2);
      notifier.setCauseFilter('计算错误');
      var s = container.read(reviewProvider);
      expect(s.page, 1);
      expect(s.filtered.length, 1);
      notifier.setPageSize(20);
      s = container.read(reviewProvider);
      expect(s.pageSize, 20);
      expect(repo.settingsValue.pageSize, 10);
    });
  });

  group('ReviewNotifier 会话：三步流程与核对提交', () {
    test('三步走完单题（纸上作答不判分）：核对提交写一条 attempt，小结只报对错/用时', () async {
      final repo = _singleRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await _seedDueCards(container, ['q1']);
      await notifier.load();
      await notifier.startSession();
      var s = container.read(reviewProvider);
      expect(s.inSession, isTrue);
      expect(s.sessionQuestions.length, 1);
      expect(s.sessionTotals, (1, 1));
      expect(s.scopeLabel, '全部复习题');
      // 作答只记内存，不写库。
      notifier.beginAnswer();
      await notifier.completePaperAnswer();
      s = container.read(reviewProvider);
      expect(s.currentSessionQuestion.stage, SessionStage.check);
      expect(repo.attempts, isEmpty);
      // 核对提交：写一条 attempt（已完成作答，correct=NULL），不调 FSRS。
      expect(await notifier.submitCheck(), isTrue);
      await _waitFor(container, (s) => s.showSummary);
      s = container.read(reviewProvider);
      expect(s.showSummary, isTrue);
      expect(s.sumCompleted, 1);
      expect(s.sumHandled, 1);
      expect(s.sumUngraded, 1);
      expect(s.sumObjCorrect, 0);
      expect(s.sumObjWrong, 0);
      expect(s.sumWeakKp, isEmpty);
      expect(s.sumNextDueDate, isNull);
      expect(s.sumElapsedSeconds, greaterThanOrEqualTo(0));
      expect(repo.attempts.length, 1);
      expect(repo.attempts.values.single.status, '已完成作答');
      expect(repo.attempts.values.single.correct, isNull);
      // 错因记录本身不动（新流程不推进治愈）。
      // FSRS 全量迁移包 7：CauseRecord 已无状态列；冻结改为断言
      // 记录仍在、补救历史未被改写。
      expect(repo.records.single.remedyHistory, isEmpty);
    });

    test('核对提交失败：recordAttempt 抛错，出 saveError 并留在核对步', () async {
      final repo = _singleRepo()..throwOnCheck = true;
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await _seedDueCards(container, ['q1']);
      await notifier.load();
      await notifier.startSession();
      await _walkToCheck(notifier);
      expect(await notifier.submitCheck(), isFalse);
      final s = container.read(reviewProvider);
      expect(s.saveError, isTrue);
      expect(s.showSummary, isFalse);
      expect(
        s.currentSessionQuestion.stage,
        SessionStage.check,
      );
      expect(repo.attempts, isEmpty);
    });

    test('按组开始：只进该组的题，题内仍是全部错因', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await _seedDueCards(container, ['q1', 'q2']);
      await notifier.load();
      final group = container
          .read(reviewProvider)
          .groups
          .firstWhere(
            (g) => g.subjectId == 'math' && g.cause == '计算错误',
          );
      await notifier.startSession(fromGroup: group);
      final s = container.read(reviewProvider);
      expect(s.sessionQuestions.length, 1);
      expect(s.currentSessionQuestion.questionId, 'q2');
      // FSRS 全量迁移包2：组筛选只决定哪道题进会话，题内快照仍是全部错因。
      expect(s.currentSessionQuestion.causes, ['方法不会', '计算错误']);
      // 组级标题：起会话时直接用进来的那个组的学科·错因，不从会话题
      // 的错因并集推导（并集有 2 个错因时会退为「数学这一科」）。
      expect(s.scopeLabel, '数学 · 计算错误');
    });

    test('一题多错因：题目只展示一次，一题一条 attempt', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await _seedDueCards(container, ['q1', 'q2']);
      await notifier.load();
      await notifier.startSession();
      // q1 走完，到 q2（双错因）。
      await _walkAndCommit(notifier);
      var s = container.read(reviewProvider);
      expect(s.sessionIndex, 1);
      expect(s.currentSessionQuestion.questionId, 'q2');
      expect(s.currentSessionQuestion.causes,
          ['方法不会', '计算错误']);
      await _walkAndCommit(notifier);
      await _waitFor(container, (s) => s.showSummary);
      s = container.read(reviewProvider);
      expect(s.showSummary, isTrue);
      expect(s.sumCompleted, 2);
      expect(s.sumHandled, 3);
      // 两道题各一条 attempt（一题一条）。
      expect(repo.attempts.length, 2);
    });
  });

  group('ReviewNotifier 会话：跳过与断点', () {
    test('跳过单题队列直接留到下次：不写 attempt，进总结', () async {
      final repo = _singleRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await _seedDueCards(container, ['q1']);
      await notifier.load();
      await notifier.startSession();
      await notifier.skipCurrent();
      await _waitFor(container, (s) => s.showSummary);
      final s = container.read(reviewProvider);
      expect(s.showSummary, isTrue);
      expect(s.sumCompleted, 0);
      expect(s.sumDeferred, 1);
      expect(s.sumSkipped, 1);
      // 只跳过、从未作答的题不建 attempt。
      expect(repo.attempts, isEmpty);
    });

    test('跳过两次留到下次：第一次追加队尾，第二次移出会话', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await _seedDueCards(container, ['q1', 'q2']);
      await notifier.load();
      await notifier.startSession();
      // 队列 [q1, q2]；跳过 q1 → [q2, q1]。
      await notifier.skipCurrent();
      var s = container.read(reviewProvider);
      expect(
        s.sessionQuestions.map((e) => e.questionId).toList(),
        ['q2', 'q1'],
      );
      expect(s.currentSessionQuestion.questionId, 'q2');
      expect(s.sessionQuestions.last.skips, 1);
      // 跳过 q2 → [q1, q2]。
      await notifier.skipCurrent();
      s = container.read(reviewProvider);
      expect(
        s.sessionQuestions.map((e) => e.questionId).toList(),
        ['q1', 'q2'],
      );
      // 再跳 q1（第二次）→ 移出，剩 [q2]。
      await notifier.skipCurrent();
      s = container.read(reviewProvider);
      expect(
        s.sessionQuestions.map((e) => e.questionId).toList(),
        ['q2'],
      );
      expect(s.sumDeferred, 1);
      expect(s.sumSkipped, 3);
    });

    test('跳过后重遇恢复原状态：核对步的题不重新给答题机会，可直接核对提交', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await _seedDueCards(container, ['q1', 'q2']);
      await notifier.load();
      await notifier.startSession();
      // q1 作答到核对步再跳过 → 队尾，状态保留（P2：attempt 只在
      // 核对提交时才写，跳过前 attemptId 为空）。
      notifier.beginAnswer();
      await notifier.completePaperAnswer();
      var s = container.read(reviewProvider);
      expect(s.currentSessionQuestion.stage, SessionStage.check);
      await notifier.skipCurrent();
      s = container.read(reviewProvider);
      expect(s.currentSessionQuestion.questionId, 'q2');
      expect(s.sessionQuestions.last.stage, SessionStage.check);
      expect(s.sessionQuestions.last.attemptId, isNull);
      // 跳过 q2 → 回到 q1，仍在核对步。
      await notifier.skipCurrent();
      s = container.read(reviewProvider);
      expect(s.currentSessionQuestion.questionId, 'q1');
      expect(s.currentSessionQuestion.stage, SessionStage.check);
      expect(s.currentSessionQuestion.attemptId, isNull);
      // 仍可直接核对提交，不重新作答；提交后进 q2。
      expect(await notifier.submitCheck(), isTrue);
      s = container.read(reviewProvider);
      expect(s.currentSessionQuestion.questionId, 'q2');
      expect(s.currentSessionQuestion.stage, SessionStage.view);
      expect(repo.attempts.length, 1);
    });

    test('暂停后断点续治：继续解决回到中断的题', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await _seedDueCards(container, ['q1', 'q2']);
      await notifier.load();
      await notifier.startSession();
      // q1 走完，到 q2 再暂停。
      await _walkAndCommit(notifier);
      await notifier.pauseSession();
      var s = container.read(reviewProvider);
      expect(s.inSession, isFalse);
      expect(repo.savedState, isNotNull);
      expect(s.resume, isNotNull);
      expect(s.resume!.sessionQuestions.length, 2);
      expect(s.resume!.sessionIndex, 1);
      await notifier.startSession(resume: true);
      s = container.read(reviewProvider);
      expect(s.inSession, isTrue);
      expect(s.sessionIndex, 1);
      expect(s.currentSessionQuestion.questionId, 'q2');
    });

    test('崩溃窗口恢复：数据库已写、review_state 未更新时，按 attempts 行重建已提交态', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await _seedDueCards(container, ['q1', 'q2']);
      await notifier.load();
      await notifier.startSession();
      // q1 核对提交已写库（attempt 行已存在）。
      await _walkAndCommit(notifier);
      expect(repo.attempts.length, 1);
      await notifier.pauseSession();
      expect(repo.savedState, isNotNull);
      // 模拟崩溃窗口：review_state 没来得及更新——把 perQuestionState
      // 里的已提交标记抹掉（只留队列与位置），attempt 行仍在。
      final stale = repo.savedState!;
      repo.savedState = ReviewSessionState(
        queue: stale.queue,
        position: stale.position,
        updatedAt: DateTime.now(),
        sessionId: stale.sessionId,
        mode: stale.mode,
        skips: stale.skips,
        perQuestionState: {
          for (final e in stale.perQuestionState.entries)
            e.key: {
              ...e.value,
              'check_submitted': false,
              'attempt_id': null,
            },
        },
      );
      await notifier.load();
      final s = container.read(reviewProvider);
      expect(s.resume, isNotNull);
      final resumed = s.resume!.sessionQuestions.firstWhere(
        (sq) => sq.questionId == 'q1',
      );
      expect(resumed.checkSubmitted, isTrue);
      expect(resumed.stage, SessionStage.done);
      expect(
        resumed.attemptId,
        repo.attempts.values.single.id,
      );
      // 恢复本身不重新提交、不重复计数。
      expect(repo.attempts.length, 1);
      expect(
        repo.records.firstWhere((r) => r.questionId == 'q1').remedyHistory,
        isEmpty,
      );
    });

    test('版本变化恢复：未作答的题刷新快照，从看题重新开始', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await _seedDueCards(container, ['q1', 'q2']);
      await notifier.load();
      await notifier.startSession();
      await notifier.pauseSession();
      // 暂停后答案版本变了（详情页改过答案），本题尚未作答。
      final qi = repo.questions.indexWhere((q) => q.id == 'q1');
      repo.questions[qi] = repo.questions[qi].copyWith(answerVersion: 2);
      await notifier.load();
      final s = container.read(reviewProvider);
      expect(s.resume, isNotNull);
      final resumed = s.resume!.sessionQuestions.firstWhere(
        (sq) => sq.questionId == 'q1',
      );
      expect(resumed.answerVersionAtStart, 2);
      expect(resumed.stage, SessionStage.view);
    });

    test('版本变化恢复：已提交作答的题移出本次会话，不覆盖历史 attempt', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await _seedDueCards(container, ['q1', 'q2']);
      await notifier.load();
      await notifier.startSession();
      // q1 核对提交完成（attempt 已建），已进 q2。
      await _walkAndCommit(notifier);
      await notifier.pauseSession();
      // 暂停后答案与内容版本都变了。
      final qi = repo.questions.indexWhere((q) => q.id == 'q1');
      repo.questions[qi] = repo.questions[qi].copyWith(
        answerVersion: 2,
        contentVersion: 2,
      );
      await notifier.load();
      final s = container.read(reviewProvider);
      expect(s.resume, isNotNull);
      // q1 已移出，只剩 q2；原 attempt 仍在库里。
      expect(
        s.resume!.sessionQuestions.map((sq) => sq.questionId),
        ['q2'],
      );
      expect(repo.attempts.length, 1);
    });

    test('从头开始：清掉断点与保存状态，从头开新会话', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await _seedDueCards(container, ['q1', 'q2']);
      await notifier.load();
      await notifier.startSession();
      await notifier.pauseSession();
      expect(repo.savedState, isNotNull);
      await notifier.startOver();
      final s = container.read(reviewProvider);
      // 旧断点已清（resume 为 null）；新会话随即开出并持久化了自己的
      // 快照——savedState 是新会话的，不是旧断点。
      expect(s.resume, isNull);
      expect(repo.savedState, isNotNull);
      expect(repo.savedState!.sessionId, s.sessionId);
      expect(repo.savedState!.position, 0);
      expect(s.inSession, isTrue);
      expect(s.sessionIndex, 0);
      expect(s.currentSessionQuestion.questionId, 'q1');
    });

    test('陈旧断点回收：保存队列已无待治项时清掉，不出恢复条', () async {
      final repo = _reviewRepo();
      repo.savedState = ReviewSessionState(
        queue: const [
          ReviewQueueItem(questionId: 'q9', cause: '概念不清'),
        ],
        position: 0,
        updatedAt: DateTime.now(),
      );
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      final s = container.read(reviewProvider);
      expect(s.resume, isNull);
      expect(repo.savedState, isNull);
      expect(s.resumeExpired, isTrue);
    });
  });

  group('ReviewNotifier 专项练习', () {
    test('专项练习不调 FSRS、不写正式复习记录', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      notifier.openPracticePicker();
      expect(container.read(reviewProvider).showPracticePicker, isTrue);
      await notifier.startPracticeSession();
      var s = container.read(reviewProvider);
      expect(s.inSession, isTrue);
      expect(s.isPracticeSession, isTrue);
      // 练习池：q1/q2/q3/q4（未加入复习的 q4 也可练，未整理的 q5 不可练）。
      expect(s.sessionQuestions.length, 4);
      expect(
        s.sessionQuestions.map((e) => e.questionId).toSet(),
        {'q1', 'q2', 'q3', 'q4'},
      );
      // 四题都纸上作答 + 核对提交走完。
      for (var i = 0; i < 4; i++) {
        notifier.beginAnswer();
        await notifier.completePaperAnswer();
        await notifier.submitCheck();
      }
      await _waitFor(container, (s) => s.showSummary);
      s = container.read(reviewProvider);
      expect(s.showSummary, isTrue);
      expect(s.sumCompleted, 4);
      expect(s.sumUngraded, 4);
      expect(s.sumNextDueDate, isNull);
      // 错因记录一点没动。
      expect(
        repo.records.where((r) => r.questionId == 'q1').single.remedyHistory,
        isEmpty,
      );
      expect(repo.attempts.length, 4);
    });

    test('专项练习重新加入复习：按题入池，记录冻结不动；再点提示已在复习中', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      notifier.openPracticePicker();
      // 只练英语（q3）。
      notifier.setPracticeSubjectFilter('english');
      await notifier.startPracticeSession();
      var s = container.read(reviewProvider);
      expect(s.sessionQuestions.length, 1);
      expect(s.currentSessionQuestion.questionId, 'q3');
      // FSRS 全量迁移包2（V3）：按题重入池，不在池建卡；包 7：
      // CauseRecord 已无状态列，冻结改为断言记录本身未被改写。
      await notifier.rejoinCauseFromPractice();
      expect(
        container.read(reviewProvider).rejoinNotice,
        contains('已重新加入复习'),
      );
      final record = repo.records
          .where((r) => r.questionId == 'q3')
          .single;
      expect(record.cause, '概念不清');
      expect(record.remedyHistory, isEmpty);
      expect(repo.pooledIds, contains('q3'));
      // 再点一次：已在池，不重复建卡，提示已在复习中。
      await notifier.rejoinCauseFromPractice();
      expect(
        container.read(reviewProvider).rejoinNotice,
        '这道题已在复习中',
      );
      expect(repo.pooledIds.length, 1);
    });
  });
}
