// 收尾第 2 路：详情页复习记录订阅（D-44 终态接线）。
//
// 端到端：详情页与复习页共用同一个 FakeRepo + 同一个确定性调度器
//（fuzzing 关），详情页打开后不重进（不调 load()），
// 复习页真实走完“看题 → 作答 → 核对提交”；
// DetailNotifier 收到 submitCheck 发出的 reviewRecords 事件后，
// 本题复习状态（DetailReviewStatus）自动刷新。
// 多轮一节里第二轮复刻一次真实提交的写库结果（attempts + FSRS）：
// 首轮 Again 后卡片未到期，ReviewNotifier 的 FSRS 建队取不到它，
// 第二轮建队行为本身不是本路的断言对象，不断言它。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/data_change_events.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/detail_notifier.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/state/review_notifier.dart';

Question _sq(
  String id,
  String title, {
  String? questionType,
  List<String>? optionLabels,
  String? correctOption,
}) => Question(
  id: id,
  title: title,
  subjectId: 'math',
  errorTypes: const ['概念不清'],
  createdAt: DateTime(2026, 11, 8),
  isOrganized: true,
  reviewJoined: true,
  sliceKind: 'material',
  sliceText: '题：$title',
  questionType: questionType,
  optionLabels: optionLabels,
  correctOption: correctOption,
);

CauseRecord _sr(String questionId) => CauseRecord(
  questionId: questionId,
  cause: '概念不清',
  subjectId: 'math',
  joinedAt: DateTime(2026, 11, 10),
);

AttemptData _attempt(
  String questionId, {
  required int? correct,
  String session = 's1',
  String submission = 'sub-1',
}) => AttemptData(
  id: 'att-$questionId-$session-$correct',
  questionId: questionId,
  sessionId: session,
  mode: ReviewMode.due,
  correct: correct,
  answerVersion: 1,
  contentVersion: 0,
  status: '已提交',
  submissionId: submission,
  createdAt: DateTime.now().millisecondsSinceEpoch,
);

/// 两页共用的 Fake：复习页走 legacy 到期队列（池空时回落），
/// 详情页读本题复习状态；池内 id 与全部 attempts 都以调度器 / attempts
/// 表为准，不另记一份（submitReviewCheck 写 attempts + 调调度器，
/// 与 p2_review_simplified_test 的 Fake 同款复刻）。
class _FakeSubscribeRepo extends QuestionRepository {
  _FakeSubscribeRepo({required this.questions, required this.records, required this.scheduler})
    : super(AppDatabase.instance);

  List<Question> questions;
  List<CauseRecord> records;
  final FsrsReviewScheduler scheduler;
  ReviewSessionState? savedState;
  final Map<String, AttemptData> attempts = {};
  final Map<String, List<({String result, DateTime reviewedAt})>> historyMap =
      {};
  final List<String> recordedViews = [];

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<List<CauseRecord>> causeRecordsFor(String questionId) async =>
      records.where((r) => r.questionId == questionId).toList();

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
    String questionId,
  ) async => List.of(historyMap[questionId] ?? const []);

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
    attempts['${attempt.sessionId}|${attempt.questionId}'] = attempt;
    return attempt.id;
  }

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

  @override
  Future<List<AttemptData>> loadAllAttempts() async =>
      attempts.values.toList();

  @override
  Future<Set<String>> fsrsPoolQuestionIds() async =>
      scheduler.pooledQuestionIds();

  @override
  Future<Question?> questionById(String id) async =>
      questions.where((q) => q.id == id).firstOrNull;

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [];

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<String>> tags() async => const [];

  @override
  Future<void> recordQuestionViewed(String questionId) async {
    recordedViews.add(questionId);
  }

  @override
  Future<List<OcrJob>> ocrJobsForQuestion(String questionId) async =>
      const [];

  @override
  Future<bool> hasOcrApiKey() async => false;

  @override
  Future<bool> recordQuestionPresented({
    required Question question,
    DateTime? now,
  }) async => false;
}

_FakeSubscribeRepo _repo(FsrsReviewScheduler scheduler) =>
    _FakeSubscribeRepo(
      scheduler: scheduler,
      questions: [
        _sq(
          'q1',
          '函数极限',
          questionType: 'choice_single',
          optionLabels: const ['A', 'B', 'C', 'D'],
          correctOption: 'B',
        ),
        _sq('q2', '导数应用综合'),
      ],
      records: [_sr('q1'), _sr('q2')],
    );

FsrsReviewScheduler _testScheduler() => FsrsReviewScheduler(
  config: const SchedulerConfig(enableFuzzing: false),
  store: InMemoryCardStore(),
);

ProviderContainer _detailContainer(
  _FakeSubscribeRepo repo,
  FsrsReviewScheduler scheduler,
) {
  final container = ProviderContainer.test(
    overrides: [
      repositoryProvider.overrideWithValue(repo),
      reviewSchedulerProvider.overrideWithValue(scheduler),
      detailInitialProvider.overrideWithValue(
        const DetailInitial(questionId: 'q1', orderIds: ['q1', 'q2']),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.listen(detailProvider, (_, __) {});
  return container;
}

ProviderContainer _reviewContainer(
  _FakeSubscribeRepo repo,
  FsrsReviewScheduler scheduler,
) {
  final container = ProviderContainer.test(
    overrides: [
      repositoryProvider.overrideWithValue(repo),
      reviewSchedulerProvider.overrideWithValue(scheduler),
    ],
  );
  addTearDown(container.dispose);
  container.listen(reviewProvider, (_, __) {});
  return container;
}

/// 等详情页复习状态出现（首查的 best-effort 异步读），1s 内未出现即失败。
Future<DetailReviewStatus> _waitReviewStatus(
  DetailNotifier notifier,
) async {
  for (var i = 0; i < 100; i++) {
    final s = notifier.state.reviewStatus;
    if (s != null) return s;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('reviewStatus 未在 1s 内填入');
}

/// 等详情页复习状态满足条件（订阅刷新后的值），1s 内未满足即失败。
Future<DetailReviewStatus> _waitReviewStatusWhere(
  DetailNotifier notifier,
  bool Function(DetailReviewStatus s) done,
) async {
  for (var i = 0; i < 100; i++) {
    final s = notifier.state.reviewStatus;
    if (s != null && done(s)) return s;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('reviewStatus 未在 1s 内更新到期望值');
}

/// 等详情页 state 满足条件（错因记录 / 解决记录刷新用），1s 内未满足即失败。
Future<void> _waitDetailWhere(
  DetailNotifier notifier,
  bool Function(DetailState s) done,
) async {
  for (var i = 0; i < 100; i++) {
    if (done(notifier.state)) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('详情页 state 未在 1s 内更新到期望值');
}

/// 单选作答并进核对步（p2 同款走法）。
Future<void> _walkObjective(ReviewNotifier notifier, String option) async {
  notifier.beginAnswer();
  notifier.selectOption(option);
  await notifier.submitObjectiveAnswer();
}

void main() {
  group('详情页复习记录订阅', () {
    test('一次到期复习后，不重进就显示最新复习状态', () async {
      final scheduler = _testScheduler();
      final repo = _repo(scheduler);
      final detailContainer = _detailContainer(repo, scheduler);
      final reviewContainer = _reviewContainer(repo, scheduler);
      final detailNotifier = detailContainer.read(detailProvider.notifier);
      await detailNotifier.load();
      final initial = await _waitReviewStatus(detailNotifier);
      expect(initial.inPool, isFalse);
      expect(initial.nextDueAt, isNull);
      expect(initial.formalCorrect, 0);
      expect(initial.formalWrong, 0);
      // FSRS 全量迁移包 2 遗留同步（包 7 补）：legacy 回落已删，池空
      // 即无到期；复习页要建出会话，须先给 q1 一张到期卡（建卡 + 3
      // 天前答对一次，Good 首间隔 2 天，到期日在昨天）。
      await scheduler.initializeQuestion('q1');
      await scheduler.recordAnswer(
        'q1',
        ReviewResult.good,
        DateTime.now().subtract(const Duration(days: 3)),
        'evt-drs-seed-q1',
      );

      // 复习页真实走完一道题：选错（A，正确答案 B）→ 核对提交。
      final reviewNotifier = reviewContainer.read(reviewProvider.notifier);
      await reviewNotifier.load();
      await reviewNotifier.startSession();
      await _walkObjective(reviewNotifier, 'A');
      expect(reviewContainer.read(reviewProvider).currentSessionQuestion.correct, 0);
      expect(await reviewNotifier.submitCheck(), isTrue);

      // 详情页没有调 load()：订阅刷新后的值。
      final updated = await _waitReviewStatusWhere(
        detailNotifier,
        (s) => s.formalWrong == 1,
      );
      expect(updated.inPool, isTrue);
      expect(updated.formalCorrect, 0);
      expect(updated.nextDueAt, isNotNull);
      expect(updated.nextDueAt, await scheduler.nextDueAt('q1'));
      expect(reviewDueLabel(updated), startsWith('下次到期'));
      expect(reviewFormalLabel(updated), '正式复习答对 0 次 · 答错 1 次');
    });

    test('多轮复习后，累计显示最新复习状态', () async {
      final scheduler = _testScheduler();
      final repo = _repo(scheduler);
      final detailContainer = _detailContainer(repo, scheduler);
      final reviewContainer = _reviewContainer(repo, scheduler);
      final detailNotifier = detailContainer.read(detailProvider.notifier);
      await detailNotifier.load();
      await _waitReviewStatus(detailNotifier);
      // FSRS 全量迁移包 2 遗留同步（包 7 补）：legacy 回落已删，池空
      // 即无到期；复习页要建出会话，须先给 q1 一张到期卡（建卡 + 3
      // 天前答对一次，Good 首间隔 2 天，到期日在昨天）。
      await scheduler.initializeQuestion('q1');
      await scheduler.recordAnswer(
        'q1',
        ReviewResult.good,
        DateTime.now().subtract(const Duration(days: 3)),
        'evt-drs-seed-q1',
      );

      // 第一轮：复习页真实提交，答错。
      final reviewNotifier = reviewContainer.read(reviewProvider.notifier);
      await reviewNotifier.load();
      await reviewNotifier.startSession();
      await _walkObjective(reviewNotifier, 'A');
      expect(await reviewNotifier.submitCheck(), isTrue);
      final afterRound1 = await _waitReviewStatusWhere(
        detailNotifier,
        (s) => s.formalWrong == 1,
      );
      final due1 = afterRound1.nextDueAt;
      expect(due1, isNotNull);

      // 第二轮：复刻一次真实提交的写库结果——一条答对的正式作答 +
      // 调度器再推进一轮（Good），再发与 submitCheck 同形的事件。
      repo.attempts['s2|q1'] = _attempt(
        'q1',
        correct: 1,
        session: 's2',
        submission: 'sub-2',
      );
      await scheduler.recordAnswer(
        'q1',
        ReviewResult.good,
        DateTime.now(),
        'evt-q1-round2',
      );
      DataChangeBus.instance.emit(
        const DataChangeEvent(
          kinds: {DataChangeKind.badges, DataChangeKind.reviewRecords},
          questionId: 'q1',
        ),
      );
      final afterRound2 = await _waitReviewStatusWhere(
        detailNotifier,
        (s) => s.formalCorrect == 1 && s.formalWrong == 1,
      );
      expect(afterRound2.inPool, isTrue);
      expect(afterRound2.nextDueAt, isNotNull);
      expect(afterRound2.nextDueAt, await scheduler.nextDueAt('q1'));
      expect(afterRound2.nextDueAt, isNot(due1));
      expect(reviewFormalLabel(afterRound2), '正式复习答对 1 次 · 答错 1 次');
    });

    test('他题的复习事件不刷新当前题，本题事件到时才刷新', () async {
      final scheduler = _testScheduler();
      final repo = _repo(scheduler);
      final detailContainer = _detailContainer(repo, scheduler);
      final detailNotifier = detailContainer.read(detailProvider.notifier);
      await detailNotifier.load();
      final initial = await _waitReviewStatus(detailNotifier);
      expect(initial.formalWrong, 0);
      expect(initial.nextDueAt, isNull);

      // 库里 q1 已多一条正式答错 + 卡片已推进，但只发 q2 的事件。
      repo.attempts['sX|q1'] = _attempt(
        'q1',
        correct: 0,
        session: 'sX',
        submission: 'sub-X',
      );
      await scheduler.recordAnswer(
        'q1',
        ReviewResult.again,
        DateTime.now(),
        'evt-q1-other',
      );
      DataChangeBus.instance.emit(
        const DataChangeEvent(
          kinds: {DataChangeKind.badges, DataChangeKind.reviewRecords},
          questionId: 'q2',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final still = detailNotifier.state.reviewStatus!;
      expect(still.formalWrong, 0);
      expect(still.nextDueAt, isNull);
      expect(still.inPool, isFalse);

      // 再发本题事件，同一批数据立刻刷出来（对照：订阅本身是通的）。
      DataChangeBus.instance.emit(
        const DataChangeEvent(
          kinds: {DataChangeKind.badges, DataChangeKind.reviewRecords},
          questionId: 'q1',
        ),
      );
      final updated = await _waitReviewStatusWhere(
        detailNotifier,
        (s) => s.formalWrong == 1,
      );
      expect(updated.inPool, isTrue);
      expect(updated.nextDueAt, isNotNull);
    });

    test('本题复习记录事件同时刷新错因记录与解决记录', () async {
      final scheduler = _testScheduler();
      final repo = _repo(scheduler);
      final detailContainer = _detailContainer(repo, scheduler);
      final detailNotifier = detailContainer.read(detailProvider.notifier);
      await detailNotifier.load();
      await _waitReviewStatus(detailNotifier);
      expect(detailNotifier.state.records.first.remedyHistory, isEmpty);
      expect(detailNotifier.state.history, isEmpty);

      // 模拟他处写入：补救历史新增一条 + 一条解决记录，再发本题事件。
      // FSRS 全量迁移包 7：CauseRecord 已无状态列，刷新断言改走
      // 仍存活的补救历史字段。
      repo.records[0] = repo.records[0].copyWith(
        remedyHistory: ['2026-11-27：新补救'],
      );
      repo.historyMap['q1'] = [
        (result: 'solved', reviewedAt: DateTime.now()),
      ];
      DataChangeBus.instance.emit(
        const DataChangeEvent(
          kinds: {DataChangeKind.badges, DataChangeKind.reviewRecords},
          questionId: 'q1',
        ),
      );
      await _waitDetailWhere(
        detailNotifier,
        (s) => s.history.length == 1,
      );
      expect(detailNotifier.state.records.first.remedyHistory,
          ['2026-11-27：新补救']);
      // 刷新只动复习相关字段：编辑表单值与当前题不受影响。
      expect(detailNotifier.state.question?.id, 'q1');
      expect(detailNotifier.state.editBase, isNull);
    });
  });
}
