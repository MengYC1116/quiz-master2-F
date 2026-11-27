// P2 简化基线测试：三步流程、核对三情况、幂等、旧会话兼容、小结、
// 会话切换守卫、review_history 停止写入。调度器用确定性实现
// （fuzzing 关），经 reviewSchedulerProvider 注入；Fake 只覆盖
// repository 调用，不碰真实数据库。
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
  String? questionType,
  List<String>? optionLabels,
  String? correctOption,
  List<String> knowledgePointIds = const [],
}) => Question(
  id: id,
  title: title,
  subjectId: subjectId,
  errorTypes: const ['概念不清'],
  createdAt: DateTime(2026, 11, 8),
  isOrganized: true,
  reviewJoined: true,
  sliceKind: 'material',
  sliceText: '题：$title',
  questionType: questionType,
  optionLabels: optionLabels,
  correctOption: correctOption,
  knowledgePointIds: knowledgePointIds,
);

CauseRecord _rec(String questionId) => CauseRecord(
  questionId: questionId,
  cause: '概念不清',
  subjectId: 'math',
  joinedAt: DateTime(2026, 11, 10),
);

class _FakeP2Repo extends QuestionRepository {
  _FakeP2Repo({required this.questions, required this.records})
    : super(AppDatabase.instance);

  List<Question> questions;
  List<CauseRecord> records;
  ReviewSessionState? savedState;
  final Map<String, AttemptData> attempts = {};

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [
    KnowledgePoint(
      id: 'kp-lim',
      subjectId: 'math',
      chapter: '第一章',
      name: '函数极限',
    ),
  ];

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

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
  }) async => savedState = ReviewSessionState(
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
    attempts['${attempt.sessionId}|${attempt.questionId}'] = attempt;
    return attempt.id;
  }

  // P5：submitCheck 改走 repo.submitReviewCheck（事务双写）；Fake
  // 不碰真实数据库，这里用旧的两步行为复刻（写 attempts + 调调度器），
  // 事务语义由 P5 测试对真实库验证。
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
  }) async => attempts['$sessionId|$questionId'];

  @override
  Future<List<AttemptData>> loadAttemptsForSession(String sessionId) async =>
      attempts.values.where((a) => a.sessionId == sessionId).toList();
}

_FakeP2Repo _choiceRepo() => _FakeP2Repo(
  questions: [
    _rq(
      'q1',
      '函数极限',
      questionType: 'choice_single',
      optionLabels: const ['A', 'B', 'C', 'D'],
      correctOption: 'B',
      knowledgePointIds: const ['kp-lim'],
    ),
  ],
  records: [_rec('q1')],
);

_FakeP2Repo _tfRepo() => _FakeP2Repo(
  questions: [
    _rq(
      'q1',
      '极限为零的函数是无穷小',
      questionType: 'true_false',
      optionLabels: const ['正确', '错误'],
      correctOption: '正确',
      knowledgePointIds: const ['kp-lim'],
    ),
  ],
  records: [_rec('q1')],
);

_FakeP2Repo _paperRepo() =>
    _FakeP2Repo(questions: [_rq('q1', '求极限')], records: [_rec('q1')]);

_FakeP2Repo _twoRepo() => _FakeP2Repo(
  questions: [
    _rq(
      'q1',
      '函数极限',
      questionType: 'choice_single',
      optionLabels: const ['A', 'B', 'C', 'D'],
      correctOption: 'B',
      knowledgePointIds: const ['kp-lim'],
    ),
    _rq('q2', '求导数'),
  ],
  records: [_rec('q1'), _rec('q2')],
);

FsrsReviewScheduler _testScheduler() => FsrsReviewScheduler(
  config: const SchedulerConfig(enableFuzzing: false),
  store: InMemoryCardStore(),
);

/// FSRS 全量迁移包 2 遗留同步（包 7 补 detail_review_subscribe_test
/// 同款办法）：legacy 回落已删，池空即无到期；复习页要建出到期会话，
/// 须先给每道题建一张 FSRS 卡。只建卡、不预答一次——建卡后即进今日
/// 新题释放，当天可练；若预答一次再建到期卡，nextDueAt 在“无法判分
/// （纸上作答）→ 不调 FSRS”测试里不再是 null。必须在 load() 之前调
/// （load() 快照 fsrsPoolIds / fsrsTodaysNewIds 进 state，建队读快照）。
Future<void> _seedNewCards(
  ProviderContainer container,
  _FakeP2Repo repo,
) async {
  final scheduler = container.read(reviewSchedulerProvider);
  for (final q in repo.questions) {
    await scheduler.initializeQuestion(q.id);
  }
}

ProviderContainer _container(_FakeP2Repo repo) {
  final container = ProviderContainer.test(
    overrides: [
      repositoryProvider.overrideWithValue(repo),
      reviewSchedulerProvider.overrideWithValue(_testScheduler()),
    ],
  );
  addTearDown(container.dispose);
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

/// 单选/判断：点选 → 提交答案 → 核对步。
Future<void> _walkObjective(ReviewNotifier notifier, String option) async {
  notifier.beginAnswer();
  notifier.selectOption(option);
  await notifier.submitObjectiveAnswer();
}

/// 纸上作答：开始作答 → 已完成作答 → 核对步。
Future<void> _walkPaper(ReviewNotifier notifier) async {
  notifier.beginAnswer();
  await notifier.completePaperAnswer();
}

void main() {
  group('P2 简化基线：三步流程', () {
    test('stageLabels 只有 3 步：看题 → 作答 → 核对', () {
      expect(stageLabels, ['① 看题', '② 作答', '③ 核对']);
      expect(SessionStage.values, [
        SessionStage.view,
        SessionStage.answer,
        SessionStage.check,
        SessionStage.done,
      ]);
    });

    test('三步走完单题：作答不写库，核对提交写一条 attempt 后出小结', () async {
      final repo = _paperRepo();
      final container = _container(repo);
      await _seedNewCards(container, repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      var s = container.read(reviewProvider);
      expect(s.currentSessionQuestion.stage, SessionStage.view);
      notifier.beginAnswer();
      s = container.read(reviewProvider);
      expect(s.currentSessionQuestion.stage, SessionStage.answer);
      await notifier.completePaperAnswer();
      s = container.read(reviewProvider);
      expect(s.currentSessionQuestion.stage, SessionStage.check);
      expect(repo.attempts, isEmpty);
      expect(await notifier.submitCheck(), isTrue);
      await _waitFor(container, (s) => s.showSummary);
      s = container.read(reviewProvider);
      expect(s.showSummary, isTrue);
      expect(s.sumCompleted, 1);
      expect(s.sumUngraded, 1);
      expect(s.sumObjCorrect, 0);
      expect(s.sumObjWrong, 0);
      expect(s.sessionStartedAt, isNotNull);
      expect(s.sumElapsedSeconds, greaterThanOrEqualTo(0));
      expect(repo.attempts.length, 1);
      final attempt = repo.attempts.values.single;
      expect(attempt.correct, isNull);
      expect(attempt.confidence, isNull);
      expect(attempt.status, '已完成作答');
    });
  });

  group('P2 核对三情况', () {
    test('单选答对 → Good：卡 due 在未来，attempt correct=1', () async {
      final repo = _choiceRepo();
      final container = _container(repo);
      await _seedNewCards(container, repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      await _walkObjective(notifier, 'B');
      var s = container.read(reviewProvider);
      expect(s.currentSessionQuestion.correct, 1);
      expect(await notifier.submitCheck(), isTrue);
      final scheduler = container.read(reviewSchedulerProvider);
      final due = await scheduler.nextDueAt('q1');
      expect(due, isNotNull);
      expect(due!.isAfter(DateTime.now()), isTrue);
      final attempt = repo.attempts.values.single;
      expect(attempt.correct, 1);
      expect(attempt.confidence, isNull);
      expect(attempt.submissionId, isNotEmpty);
      s = container.read(reviewProvider);
      expect(s.sumObjCorrect, 1);
      expect(s.sumNextDueDate, due);
    });

    test('单选答错 → Again：due 早于答对的 due', () async {
      // 答错一路。
      final wrongRepo = _choiceRepo();
      final wrongContainer = _container(wrongRepo);
      await _seedNewCards(wrongContainer, wrongRepo);
      final wrongNotifier = wrongContainer.read(reviewProvider.notifier);
      await wrongNotifier.load();
      await wrongNotifier.startSession();
      await _walkObjective(wrongNotifier, 'A');
      expect(await wrongNotifier.submitCheck(), isTrue);
      final wrongDue = await wrongContainer
          .read(reviewSchedulerProvider)
          .nextDueAt('q1');
      expect(wrongDue, isNotNull);
      // 答对一路（全新调度器，同一题）。
      final rightRepo = _choiceRepo();
      final rightContainer = _container(rightRepo);
      await _seedNewCards(rightContainer, rightRepo);
      final rightNotifier = rightContainer.read(reviewProvider.notifier);
      await rightNotifier.load();
      await rightNotifier.startSession();
      await _walkObjective(rightNotifier, 'B');
      expect(await rightNotifier.submitCheck(), isTrue);
      final rightDue = await rightContainer
          .read(reviewSchedulerProvider)
          .nextDueAt('q1');
      expect(rightDue, isNotNull);
      expect(wrongDue!.isBefore(rightDue!), isTrue);
    });

    test('判断答对 → 调 FSRS：due 在未来，attempt correct=1', () async {
      final repo = _tfRepo();
      final container = _container(repo);
      await _seedNewCards(container, repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      await _walkObjective(notifier, '正确');
      expect(container.read(reviewProvider).currentSessionQuestion.correct, 1);
      expect(await notifier.submitCheck(), isTrue);
      final due = await container.read(reviewSchedulerProvider).nextDueAt('q1');
      expect(due, isNotNull);
      expect(due!.isAfter(DateTime.now()), isTrue);
      expect(repo.attempts.values.single.correct, 1);
    });

    test('无法判分（纸上作答）→ 不调 FSRS：nextDueAt 为 null', () async {
      final repo = _paperRepo();
      final container = _container(repo);
      await _seedNewCards(container, repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      await _walkPaper(notifier);
      expect(await notifier.submitCheck(), isTrue);
      expect(
        await container.read(reviewSchedulerProvider).nextDueAt('q1'),
        isNull,
      );
      expect(repo.attempts.values.single.correct, isNull);
      final s = container.read(reviewProvider);
      expect(s.sumNextDueDate, isNull);
      expect(s.sumUngraded, 1);
    });
  });

  group('P2 幂等', () {
    test('同一 eventId 重复调 recordAnswer：第二次不推进 due', () async {
      final container = _container(_paperRepo());
      final scheduler = container.read(reviewSchedulerProvider);
      final now = DateTime.now();
      await scheduler.recordAnswer('q1', ReviewResult.good, now, 'evt-1');
      final firstDue = await scheduler.nextDueAt('q1');
      expect(firstDue, isNotNull);
      await scheduler.recordAnswer('q1', ReviewResult.good, now, 'evt-1');
      expect(await scheduler.nextDueAt('q1'), firstDue);
      // 不同 eventId 才会处理：用一天后的时间再答一次，due 随之推进。
      await scheduler.recordAnswer(
        'q1',
        ReviewResult.good,
        now.add(const Duration(days: 1)),
        'evt-2',
      );
      expect((await scheduler.nextDueAt('q1'))!.isAfter(firstDue!), isTrue);
    });

    test(
      '核对提交的 eventId 稳定：attempt.submissionId 就是建队时的 attemptSubmissionId',
      () async {
        final repo = _choiceRepo();
        final container = _container(repo);
        await _seedNewCards(container, repo);
        final notifier = container.read(reviewProvider.notifier);
        await notifier.load();
        await notifier.startSession();
        final eventId = container
            .read(reviewProvider)
            .currentSessionQuestion
            .attemptSubmissionId;
        expect(eventId, isNotEmpty);
        await _walkObjective(notifier, 'B');
        expect(
          container
              .read(reviewProvider)
              .currentSessionQuestion
              .attemptSubmissionId,
          eventId,
        );
        expect(await notifier.submitCheck(), isTrue);
        expect(repo.attempts.values.single.submissionId, eventId);
      },
    );

    test(
      '崩溃恢复重放：review_state 标记丢失但 attempt 已写，按 attempt 重建已提交态，不重写不重计分',
      () async {
        final repo = _twoRepo();
        final container = _container(repo);
        await _seedNewCards(container, repo);
        final notifier = container.read(reviewProvider.notifier);
        await notifier.load();
        await notifier.startSession();
        await _walkObjective(notifier, 'B');
        expect(await notifier.submitCheck(), isTrue);
        expect(repo.attempts.length, 1);
        final dueBefore = await container
            .read(reviewSchedulerProvider)
            .nextDueAt('q1');
        await notifier.pauseSession();
        // 模拟崩溃窗口：review_state 没来得及更新已提交标记。
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
              e.key: {...e.value, 'check_submitted': false, 'attempt_id': null},
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
        expect(resumed.attemptId, repo.attempts.values.single.id);
        expect(repo.attempts.length, 1);
        expect(
          await container.read(reviewSchedulerProvider).nextDueAt('q1'),
          dueBefore,
        );
      },
    );
  });

  group('P2 旧会话兼容', () {
    test('selfCheck + 有客观记录 → 恢复为 done，不重计分', () async {
      final repo = _paperRepo();
      final container = _container(repo);
      await _seedNewCards(container, repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      await _walkPaper(notifier);
      expect(await notifier.submitCheck(), isTrue);
      expect(repo.attempts.length, 1);
      await notifier.pauseSession();
      // 旧会话停在 selfCheck 阶段（P2 前的保存格式）。
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
            e.key: {...e.value, 'stage': 'selfCheck'},
        },
      );
      await notifier.load();
      final s = container.read(reviewProvider);
      expect(s.resume, isNotNull);
      final resumed = s.resume!.sessionQuestions.single;
      expect(resumed.stage, SessionStage.done);
      expect(resumed.checkSubmitted, isTrue);
      expect(repo.attempts.length, 1);
    });

    test('selfCheck + 无客观记录 → 回到安全核对步，不重复写', () async {
      final repo = _paperRepo();
      final container = _container(repo);
      await _seedNewCards(container, repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      await _walkPaper(notifier);
      await notifier.pauseSession();
      expect(repo.attempts, isEmpty);
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
            e.key: {...e.value, 'stage': 'selfCheck'},
        },
      );
      await notifier.load();
      final s = container.read(reviewProvider);
      expect(s.resume, isNotNull);
      final resumed = s.resume!.sessionQuestions.single;
      expect(resumed.stage, SessionStage.check);
      expect(resumed.checkSubmitted, isFalse);
      // 恢复后正常提交：只写一条。
      await notifier.startSession(resume: true);
      expect(await notifier.submitCheck(), isTrue);
      expect(repo.attempts.length, 1);
    });

    test('看题 / 作答阶段保留当前题恢复原阶段', () async {
      final repo = _twoRepo();
      final container = _container(repo);
      await _seedNewCards(container, repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      await notifier.pauseSession();
      await notifier.load();
      var s = container.read(reviewProvider);
      expect(s.resume!.sessionQuestions.first.stage, SessionStage.view);
      await notifier.startSession(resume: true);
      notifier.beginAnswer();
      await notifier.pauseSession();
      await notifier.load();
      s = container.read(reviewProvider);
      expect(s.resume!.sessionQuestions.first.stage, SessionStage.answer);
      expect(repo.attempts, isEmpty);
    });
  });

  group('P2 小结', () {
    test('小结只报对错数/用时/弱点/下次时间：答错进弱点，下次时间取 FSRS 最早', () async {
      final repo = _twoRepo();
      final container = _container(repo);
      await _seedNewCards(container, repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      // q1 单选答错（kp-lim），q2 纸上作答不判分。
      await _walkObjective(notifier, 'A');
      expect(await notifier.submitCheck(), isTrue);
      await _walkPaper(notifier);
      expect(await notifier.submitCheck(), isTrue);
      await _waitFor(container, (s) => s.showSummary);
      final s = container.read(reviewProvider);
      expect(s.showSummary, isTrue);
      expect(s.sumCompleted, 2);
      expect(s.sumObjCorrect, 0);
      expect(s.sumObjWrong, 1);
      expect(s.sumUngraded, 1);
      expect(s.sumWeakKp, {'kp-lim': 1});
      expect(s.sumNextDueDate, isNotNull);
      expect(
        s.sumNextDueDate,
        await container.read(reviewSchedulerProvider).nextDueAt('q1'),
      );
      expect(s.sumElapsedSeconds, greaterThanOrEqualTo(0));
      expect(s.sessionStartedAt, isNotNull);
    });
  });

  group('P2 会话切换守卫', () {
    test('有未完成正式复习时直接开专项练习不覆盖断点', () async {
      final repo = _twoRepo();
      final container = _container(repo);
      await _seedNewCards(container, repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      await notifier.pauseSession();
      expect(repo.savedState, isNotNull);
      final savedBefore = repo.savedState;
      await notifier.startPracticeSession();
      final s = container.read(reviewProvider);
      expect(s.inSession, isFalse);
      expect(s.resume, isNotNull);
      expect(repo.savedState, same(savedBefore));
      // 断点仍可恢复。
      await notifier.startSession(resume: true);
      expect(container.read(reviewProvider).inSession, isTrue);
      expect(
        container.read(reviewProvider).currentSessionQuestion.questionId,
        'q1',
      );
    });
  });

  group('P2 review_history 停止写入', () {
    test('走完一轮到期复习：只写 attempts，不写 review_history', () async {
      final repo = _twoRepo();
      final container = _container(repo);
      await _seedNewCards(container, repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      await _walkObjective(notifier, 'B');
      expect(await notifier.submitCheck(), isTrue);
      await _walkPaper(notifier);
      expect(await notifier.submitCheck(), isTrue);
      await _waitFor(container, (s) => s.showSummary);
      // 旧写入层（submitCauseVerdict / recordSelfCheck）已随 FSRS
      // 全量迁移（包1）退役删除：Fake 上不再有这两个入口可调。
      expect(repo.attempts.length, 2);
    });
  });
}
