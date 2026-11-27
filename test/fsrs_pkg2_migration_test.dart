// FSRS 全量迁移包2 针对性测试（计划 §5）：
// - 题内错因：全部错因进会话、空错因题可练、会话中改错因不重置 FSRS、
//   本轮快照与下一轮取最新；
// - 会话恢复策略 A：旧会话按旧快照完成、新一轮新口径；
// - FSRS 队列：池空即无到期、到期集合只认 FSRS 卡、到期与新释放混合时
//   limit 按题数；
// - 重新加入：不在池建卡、已在池不重复建卡不重置状态。
// 内存 FakeRepo + 确定性调度器（fuzzing 关，InMemoryCardStore），不碰真实库。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/state/review_notifier.dart';

Question _q(
  String id, {
  List<String> errorTypes = const ['概念不清'],
  bool reviewJoined = true,
  int contentVersion = 1,
}) =>
    Question(
      id: id,
      title: '题 $id',
      subjectId: 'math',
      errorTypes: errorTypes,
      createdAt: DateTime(2026, 11, 8),
      isOrganized: true,
      reviewJoined: reviewJoined,
      contentVersion: contentVersion,
      sliceKind: 'material',
      sliceText: '题',
    );

CauseRecord _rec(String qid, String cause) => CauseRecord(
      questionId: qid,
      cause: cause,
      subjectId: 'math',
      joinedAt: DateTime(2026, 11, 10),
    );

class _Pkg2Repo extends QuestionRepository {
  _Pkg2Repo({
    required this.questions,
    required this.records,
    AppSettings? settings,
  })  : settingsValue = settings ?? AppSettings.defaults,
        super(AppDatabase.instance);

  List<Question> questions;
  List<CauseRecord> records;
  AppSettings settingsValue;
  ReviewSessionState? savedState;
  final Map<String, AttemptData> attempts = {};

  @override
  Future<List<Subject>> subjects() async => List.of(Subject.all);

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
  Future<AttemptData?> loadAttempt({
    required String sessionId,
    required String questionId,
  }) async =>
      attempts['$sessionId|$questionId'];

  @override
  Future<List<AttemptData>> loadAttemptsForSession(
    String sessionId,
  ) async =>
      attempts.values.where((a) => a.sessionId == sessionId).toList();

  @override
  Future<bool> setReviewJoinedFlag(Question q, bool joined) async {
    final i = questions.indexWhere((x) => x.id == q.id);
    if (i >= 0) questions[i] = questions[i].copyWith(reviewJoined: joined);
    return true;
  }

  @override
  Future<bool> recordQuestionPresented({
    required Question question,
    DateTime? now,
  }) async =>
      true;
}

FsrsReviewScheduler _scheduler() => FsrsReviewScheduler(
      config: const SchedulerConfig(enableFuzzing: false),
      store: InMemoryCardStore(),
    );

ProviderContainer _container(_Pkg2Repo repo, FsrsReviewScheduler scheduler) {
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

/// 建一张已到期的卡：建卡 + 3 天前答对一次（Good 首间隔 2 天，到期日在昨天）。
Future<void> _seedDueCard(FsrsReviewScheduler scheduler, String id) async {
  await scheduler.initializeQuestion(id);
  await scheduler.recordAnswer(
    id,
    ReviewResult.good,
    DateTime.now().subtract(const Duration(days: 3)),
    'evt-pkg2-$id',
  );
}

void main() {
  group('题内错因（FSRS 全量迁移包2）', () {
    test('全部错因进会话：已解决错因也在快照里，空错因题 causes 为空', () async {
      final repo = _Pkg2Repo(
        questions: [
          _q('q1', errorTypes: const ['概念不清', '计算错误']),
          _q('q2', errorTypes: const []),
        ],
        records: [
          _rec('q1', '概念不清'),
          _rec('q1', '计算错误'),
        ],
      );
      final container = _container(repo, _scheduler());
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      notifier.openPracticePicker();
      await notifier.startPracticeSession();
      final s = container.read(reviewProvider);
      expect(s.sessionQuestions.length, 2);
      SessionQuestionState sq(String id) =>
          s.sessionQuestions.firstWhere((e) => e.questionId == id);
      // 已解决的错因也在快照里（不按治愈状态筛）。
      expect(sq('q1').causes, ['概念不清', '计算错误']);
      // 空错因的题也可练，causes 为空。
      expect(sq('q2').causes, isEmpty);
    });

    test('空错因题可练：只有空错因题也能开练习', () async {
      final repo = _Pkg2Repo(
        questions: [_q('q1', errorTypes: const [])],
        records: const [],
      );
      final container = _container(repo, _scheduler());
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      notifier.openPracticePicker();
      await notifier.startPracticeSession();
      final s = container.read(reviewProvider);
      expect(s.sessionQuestions.length, 1);
      expect(s.currentSessionQuestion.questionId, 'q1');
      expect(s.currentSessionQuestion.causes, isEmpty);
    });

    test('会话中改错因不重置 FSRS、不影响本轮快照', () async {
      final scheduler = _scheduler();
      final repo = _Pkg2Repo(
        questions: [_q('q1', errorTypes: const ['概念不清'])],
        records: [_rec('q1', '概念不清')],
      );
      await _seedDueCard(scheduler, 'q1');
      final container = _container(repo, scheduler);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      expect(container.read(reviewProvider).inSession, isTrue);
      final dueBefore = await scheduler.nextDueAt('q1');
      expect(dueBefore, isNotNull);
      // 会话进行中改错因：加一个错因。
      repo.questions[0] = repo.questions[0]
          .copyWith(errorTypes: const ['概念不清', '计算错误']);
      final dueAfter = await scheduler.nextDueAt('q1');
      expect(dueAfter, dueBefore);
      // 本轮快照不变。
      expect(
        container.read(reviewProvider).sessionQuestions.single.causes,
        ['概念不清'],
      );
    });

    test('本轮快照与下一轮取最新：第二轮拿到新加的错因', () async {
      final repo = _Pkg2Repo(
        questions: [_q('q1', errorTypes: const ['概念不清'])],
        records: [_rec('q1', '概念不清')],
      );
      final container = _container(repo, _scheduler());
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      notifier.openPracticePicker();
      await notifier.startPracticeSession();
      expect(
        container.read(reviewProvider).sessionQuestions.single.causes,
        ['概念不清'],
      );
      // 第一轮结束后再改错因（回列表时 load 读到新题面）。
      repo.questions[0] = repo.questions[0]
          .copyWith(errorTypes: const ['概念不清', '计算错误']);
      await notifier.backToList();
      notifier.openPracticePicker();
      await notifier.startPracticeSession();
      expect(
        container.read(reviewProvider).sessionQuestions.single.causes,
        ['概念不清', '计算错误'],
      );
    });
  });

  group('会话恢复策略 A（FSRS 全量迁移包2，Meng 已确认）', () {
    test('旧会话按旧快照完成：新加的错因不进本轮，已删的错因剔除本题', () async {
      final q1 = _q('q1', errorTypes: const ['概念不清', '计算错误']);
      final q2 = _q('q2', errorTypes: const ['方法不会']);
      final repo = _Pkg2Repo(
        questions: [q1, q2],
        records: [
          _rec('q1', '概念不清'),
          _rec('q1', '计算错误'),
          _rec('q2', '方法不会'),
        ],
      );
      // 旧会话快照：q1 只有“概念不清”（“计算错误”是之后加的）；
      // q2 只有“审题失误”（已从题上删掉）。
      Map<String, Object?> sqState(Question q, List<String> causes) =>
          SessionQuestionState(
            questionId: q.id,
            causes: causes,
            answerVersionAtStart: q.answerVersion,
            contentVersionAtStart: q.contentVersion,
            questionSubmissionId: 'qs-${q.id}',
            attemptSubmissionId: 'attsub-${q.id}',
          ).toJson();
      repo.savedState = ReviewSessionState(
        queue: const [
          ReviewQueueItem(questionId: 'q1', cause: '概念不清'),
          ReviewQueueItem(questionId: 'q2', cause: '审题失误'),
        ],
        position: 0,
        updatedAt: DateTime.now(),
        sessionId: 'sess-old',
        mode: ReviewMode.due,
        perQuestionState: {
          'q1': sqState(q1, const ['概念不清']),
          'q2': sqState(q2, const ['审题失误']),
        },
      );
      final container = _container(repo, _scheduler());
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      final s = container.read(reviewProvider);
      expect(s.resume, isNotNull);
      // q1 按旧快照完成（只有“概念不清”，新加的“计算错误”不进本轮）；
      // q2 唯一保存的错因已不在题身上，本题剔除。
      expect(
        s.resume!.sessionQuestions.map((e) => e.questionId).toList(),
        ['q1'],
      );
      expect(s.resume!.sessionQuestions.single.causes, ['概念不清']);
    });

    test('下一轮起新口径：放弃旧会话后新开练习拿到全部错因', () async {
      final q1 = _q('q1', errorTypes: const ['概念不清', '计算错误']);
      final repo = _Pkg2Repo(
        questions: [q1],
        records: [
          _rec('q1', '概念不清'),
          _rec('q1', '计算错误'),
        ],
      );
      repo.savedState = ReviewSessionState(
        queue: const [
          ReviewQueueItem(questionId: 'q1', cause: '概念不清'),
        ],
        position: 0,
        updatedAt: DateTime.now(),
        sessionId: 'sess-old',
        mode: ReviewMode.due,
        perQuestionState: {
          'q1': SessionQuestionState(
            questionId: 'q1',
            causes: const ['概念不清'],
            answerVersionAtStart: q1.answerVersion,
            contentVersionAtStart: q1.contentVersion,
            questionSubmissionId: 'qs-q1',
            attemptSubmissionId: 'attsub-q1',
          ).toJson(),
        },
      );
      final container = _container(repo, _scheduler());
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      expect(
        container
            .read(reviewProvider)
            .resume!
            .sessionQuestions
            .single
            .causes,
        ['概念不清'],
      );
      await notifier.abandonResumeAndStartPractice();
      await notifier.startPracticeSession();
      expect(
        container.read(reviewProvider).sessionQuestions.single.causes,
        ['概念不清', '计算错误'],
      );
    });
  });

  group('FSRS 队列（FSRS 全量迁移包2）', () {
    test('池空即无到期：已加入、有待解决错因的题也不进到期', () async {
      final repo = _Pkg2Repo(
        questions: [_q('q1', errorTypes: const ['概念不清'])],
        records: [_rec('q1', '概念不清')],
      );
      final container = _container(repo, _scheduler());
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      final s = container.read(reviewProvider);
      // 旧回落已删除：池空时不看旧错因队列。
      expect(s.fsrsPoolIds, isEmpty);
      expect(s.fsrsDueIds, isEmpty);
      expect(s.canStartDueSession, isFalse);
      await notifier.startSession();
      expect(container.read(reviewProvider).inSession, isFalse);
    });

    test('到期集合只认 FSRS 卡：load 前后 due 集合与调度器一致', () async {
      final scheduler = _scheduler();
      final repo = _Pkg2Repo(
        questions: [_q('q1', errorTypes: const ['概念不清'])],
        records: [_rec('q1', '概念不清')],
      );
      await _seedDueCard(scheduler, 'q1');
      expect(
        await repo.fsrsDueQuestionIds(scheduler: scheduler),
        ['q1'],
      );
      final container = _container(repo, scheduler);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      final s = container.read(reviewProvider);
      expect(s.fsrsDueIds, {'q1'});
      expect(s.canStartDueSession, isTrue);
    });

    test('到期与新释放混合时 limit 按题数（共用一个上限）', () async {
      final scheduler = _scheduler();
      final repo = _Pkg2Repo(
        settings: AppSettings.defaults.copyWith(questionsPerSession: 2),
        questions: [
          _q('q1', errorTypes: const ['概念不清']),
          _q('q2', errorTypes: const ['计算错误']),
          _q('q3', errorTypes: const ['审题失误']),
        ],
        records: [
          _rec('q1', '概念不清'),
          _rec('q2', '计算错误'),
          _rec('q3', '审题失误'),
        ],
      );
      await _seedDueCard(scheduler, 'q1');
      await scheduler.initializeQuestion('q2');
      await scheduler.initializeQuestion('q3');
      final container = _container(repo, scheduler);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      final s = container.read(reviewProvider);
      expect(s.fsrsDueIds, {'q1'});
      expect(s.fsrsTodaysNewIds, {'q2', 'q3'});
      await notifier.startSession();
      final session = container.read(reviewProvider);
      expect(session.inSession, isTrue);
      // 到期 1 道 + 新释放 1 道 = 上限 2 道；q3 被截掉（按题数，不按错因数）。
      expect(
        session.sessionQuestions.map((e) => e.questionId).toList(),
        ['q1', 'q2'],
      );
    });
  });

  group('重新加入（FSRS 全量迁移包2，V3）', () {
    test('不在池建卡：无错因的题也可加', () async {
      final scheduler = _scheduler();
      final repo = _Pkg2Repo(
        questions: [
          _q('q1', errorTypes: const ['概念不清']),
          _q('q2', errorTypes: const []),
        ],
        records: [_rec('q1', '概念不清')],
      );
      final result = await repo.joinFsrsPool(
        questions: repo.questions,
        scheduler: scheduler,
      );
      expect(result, (added: 2, skipped: 0, failed: 0));
      expect(await scheduler.pooledQuestionIds(), {'q1', 'q2'});
      expect(
        repo.questions.map((q) => q.reviewJoined).toList(),
        [true, true],
      );
      // 不播种。
      expect(repo.records.length, 1);
    });

    test('已在池不重复建卡、不重置状态', () async {
      final scheduler = _scheduler();
      final repo = _Pkg2Repo(
        questions: [_q('q1', errorTypes: const ['概念不清'])],
        records: [_rec('q1', '概念不清')],
      );
      await _seedDueCard(scheduler, 'q1');
      final dueBefore = await scheduler.nextDueAt('q1');
      expect(dueBefore, isNotNull);
      final cardsBefore = await scheduler.loadAllCards();
      final result = await repo.joinFsrsPool(
        questions: repo.questions,
        scheduler: scheduler,
      );
      expect(result, (added: 0, skipped: 1, failed: 0));
      expect(await scheduler.nextDueAt('q1'), dueBefore);
      expect((await scheduler.loadAllCards()).length, cardsBefore.length);
    });

    test('同一批重复 id 只算一次', () async {
      final scheduler = _scheduler();
      final repo = _Pkg2Repo(
        questions: [
          _q('q1', errorTypes: const ['概念不清']),
          _q('q2', errorTypes: const ['计算错误']),
        ],
        records: const [],
      );
      final result = await repo.joinFsrsPool(
        questions: [repo.questions[0], repo.questions[0], repo.questions[1]],
        scheduler: scheduler,
      );
      expect(result, (added: 2, skipped: 0, failed: 0));
    });
  });
}
