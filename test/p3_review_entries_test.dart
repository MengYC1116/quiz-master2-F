// P3 三个加题入口测试（实施方案 v2 §5、§8 P3 相关项；D6–D8）。
//
// 覆盖：批量去重、全筛选选择、分页选择、已在复习跳过与计数文案、
// “立即专项练习”不建卡、练习小结收题（默认全勾 / 未判分另列 /
// 已在复习默认不勾 / 重复进小结不重复建卡 / 中途退出不收题但事实保留）、
// 薄弱点列表去重 / 分页 / 数量预选与自定义上限 / 样本量与“数据较少” /
// 次按钮只对勾选生效、会话不互相覆盖、归档 / 取消 / 恢复 / 删除规则。
// Fake 只覆盖实际调的方法，不碰真实数据库（删除级联一组用内存库）。
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/p3_review_entries.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/report/weak_point_list_page.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/state/report_provider.dart';
import 'package:quiz_master2/state/review_notifier.dart';
import 'package:quiz_master2/state/wrongbook_notifier.dart';

Question _rq(
  String id,
  String title, {
  String subjectId = 'math',
  String? questionType,
  List<String>? optionLabels,
  String? correctOption,
  List<String> knowledgePointIds = const [],
  List<String> errorTypes = const ['概念不清'],
  bool isOrganized = true,
  bool isArchived = false,
  bool reviewJoined = false,
  DateTime? createdAt,
}) => Question(
  id: id,
  title: title,
  subjectId: subjectId,
  errorTypes: errorTypes,
  createdAt: createdAt ?? DateTime(2026, 11, 8),
  isOrganized: isOrganized,
  isArchived: isArchived,
  reviewJoined: reviewJoined,
  sliceKind: 'material',
  sliceText: '题：$title',
  questionType: questionType,
  optionLabels: optionLabels,
  correctOption: correctOption,
  knowledgePointIds: knowledgePointIds,
);

CauseRecord _rec(String questionId, {String cause = '概念不清'}) =>
    CauseRecord(
      questionId: questionId,
      cause: cause,
      subjectId: 'math',
      joinedAt: DateTime(2026, 11, 10),
    );

FsrsReviewScheduler _testScheduler() => FsrsReviewScheduler(
  config: const SchedulerConfig(enableFuzzing: false),
  store: InMemoryCardStore(),
);

/// initializeQuestion 在 qBad 上抛错：单题失败不中断整批。
class _FlakyScheduler extends FsrsReviewScheduler {
  _FlakyScheduler({required super.config, required super.store});

  @override
  Future<void> initializeQuestion(String questionId) async {
    if (questionId == 'qBad') throw StateError('boom');
    return super.initializeQuestion(questionId);
  }
}

/// 复习侧 Fake：P2 的 _FakeP2Repo + P3 入口要的覆写
///（setReviewJoined / fsrsPoolQuestionIds / loadAllAttempts / archive）。
class _FakeP3Repo extends QuestionRepository {
  _FakeP3Repo({required this.questions, required this.records})
    : super(AppDatabase.instance);

  List<Question> questions;
  List<CauseRecord> records;
  ReviewSessionState? savedState;
  final Map<String, AttemptData> attempts = {};
  List<AttemptData> allAttemptsValue = [];

  /// P3：池内标记读调度器（与真实 joinFsrsPool 同一个实例）。
  ReviewScheduler? scheduler;

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
    KnowledgePoint(
      id: 'kp-der',
      subjectId: 'math',
      chapter: '第二章',
      name: '导数',
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
  Future<bool> setReviewJoined(Question q, bool joined) async {
    if (q.allCauses.isEmpty) return false;
    final i = questions.indexWhere((e) => e.id == q.id);
    if (i >= 0) questions[i] = q.copyWith(reviewJoined: joined);
    return true;
  }

  @override
  Future<Set<String>> fsrsPoolQuestionIds() async =>
      scheduler == null ? const {} : scheduler!.pooledQuestionIds();

  @override
  Future<List<AttemptData>> loadAllAttempts() async =>
      List.of(allAttemptsValue);

  @override
  Future<void> archive(Question q, {bool archived = true}) async {
    final i = questions.indexWhere((e) => e.id == q.id);
    if (i >= 0) questions[i] = q.copyWith(isArchived: archived);
  }
}

_FakeP3Repo _twoQRepo() => _FakeP3Repo(
  questions: [
    _rq(
      'q1',
      '函数极限',
      questionType: 'choice_single',
      optionLabels: const ['A', 'B', 'C', 'D'],
      correctOption: 'B',
      knowledgePointIds: const ['kp-lim'],
      reviewJoined: true,
    ),
    _rq('q2', '求导数', reviewJoined: true),
  ],
  records: [_rec('q1'), _rec('q2')],
);

ProviderContainer _reviewContainer(_FakeP3Repo repo) {
  final scheduler = _testScheduler();
  repo.scheduler = scheduler;
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

Future<void> _waitFor(
  ProviderContainer container,
  bool Function(ReviewState s) done,
) async {
  for (var i = 0; i < 100 && !done(container.read(reviewProvider)); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _walkObjective(ReviewNotifier notifier, String option) async {
  notifier.beginAnswer();
  notifier.selectOption(option);
  await notifier.submitObjectiveAnswer();
}

Future<void> _walkPaper(ReviewNotifier notifier) async {
  notifier.beginAnswer();
  await notifier.completePaperAnswer();
}

/// 按当前题型走完一题并核对：startPracticeWithIds 内部会打乱题序，
/// 不能假定 q1 在前——按当前题 id 决定走客观题还是纸上作答。
Future<void> _walkCurrent(
  ReviewNotifier notifier,
  ProviderContainer container,
) async {
  final id = container
      .read(reviewProvider)
      .currentSessionQuestion
      .questionId;
  if (id == 'q1') {
    await _walkObjective(notifier, 'A'); // 单选答错
  } else {
    await _walkPaper(notifier); // 纸上作答，未判分
  }
  expect(await notifier.submitCheck(), isTrue);
}

/// 错题本侧 Fake：load() 全口径 + P3 入口要的覆写。
class _FakeP3WrongbookRepo extends QuestionRepository {
  _FakeP3WrongbookRepo() : super(AppDatabase.instance);

  List<Question> questions = [
    _rq('q1', '题 q1', errorTypes: const ['概念不清']),
    _rq(
      'q2',
      '题 q2',
      errorTypes: const ['概念不清'],
      createdAt: DateTime(2026, 11, 9),
    ),
    _rq(
      'q3',
      '题 q3',
      errorTypes: const ['计算错误'],
      createdAt: DateTime(2026, 11, 8),
    ),
    _rq('q4', '题 q4', subjectId: 'english'),
    _rq('q5', '题 q5', isArchived: true),
    _rq('q6', '题 q6', isOrganized: false),
  ];
  List<Folder> folderList = [
    const Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
    const Folder(id: 'f3', name: '试卷', subjectId: 'english', sortOrder: 0),
  ];
  List<CauseRecord> records = [
    _rec('q1'),
    _rec('q2').copyWith(status: CauseStatus.solved),
    _rec('q3', cause: '计算错误'),
  ];
  ReviewScheduler? scheduler;

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<Folder>> folders({String? subjectId}) async =>
      List.of(folderList);

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<String>> tags() async => const ['易错'];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<Map<String, (int, int, int)>> subjectCounts({
    bool includeArchived = false,
  }) async => const {
    'math': (3, 0, 0),
    'english': (1, 0, 0),
    'politics': (0, 0, 0),
  };

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<AppSettings> settings() async => const AppSettings(
    wrongbookView: 'compact',
    pageSize: 20,
    wrongbookSort: 'old',
  );

  @override
  Future<List<SavedSearch>> savedSearches() async => const [];

  @override
  Future<bool> setReviewJoined(Question q, bool joined) async {
    if (q.allCauses.isEmpty) return false;
    final i = questions.indexWhere((e) => e.id == q.id);
    if (i >= 0) questions[i] = q.copyWith(reviewJoined: joined);
    return true;
  }

  @override
  Future<Set<String>> fsrsPoolQuestionIds() async =>
      scheduler == null ? const {} : scheduler!.pooledQuestionIds();
}

Future<(WrongbookNotifier, ProviderContainer)> _wrongbookContainer(
  _FakeP3WrongbookRepo repo,
) async {
  final scheduler = _testScheduler();
  repo.scheduler = scheduler;
  final container = ProviderContainer.test(
    overrides: [
      repositoryProvider.overrideWithValue(repo),
      wrongbookInitialProvider.overrideWithValue(
        const WrongbookInitial(),
      ),
      reviewSchedulerProvider.overrideWithValue(scheduler),
    ],
  );
  addTearDown(container.dispose);
  final notifier = container.read(wrongbookProvider.notifier);
  await notifier.load();
  return (notifier, container);
}

void main() {
  group('P3 纯逻辑：计数文案 / 抽题 / 归档过滤', () {
    test('fsrsBatchMessage：新增 N 道，M 道已在复习，跳过', () {
      expect(
        fsrsBatchMessage(
          const FsrsBatchOutcome(added: 2, skipped: 1),
        ),
        contains('新增 2 道'),
      );
      expect(
        fsrsBatchMessage(
          const FsrsBatchOutcome(added: 2, skipped: 1),
        ),
        contains('1 道已在复习，跳过'),
      );
      expect(
        fsrsBatchMessage(
          const FsrsBatchOutcome(added: 0, skipped: 0, failed: 0),
        ),
        '没有题被加入复习',
      );
      expect(
        fsrsBatchMessage(
          const FsrsBatchOutcome(added: 1, skipped: 0, failed: 1),
        ),
        contains('加入失败'),
      );
    });

    test('pickPracticeQuestions：count<=0 为全部；数量封顶；知识点轮流取', () {
      final candidates = [
        for (var i = 0; i < 5; i++)
          _rq('a$i', '题 a$i', knowledgePointIds: const ['kp-lim']),
        for (var i = 0; i < 5; i++)
          _rq('b$i', '题 b$i', knowledgePointIds: const ['kp-der']),
      ];
      // 全部：10 道都在。
      final all = pickPracticeQuestions(
        candidates: candidates,
        count: 0,
        random: Random(1),
      );
      expect(all.map((q) => q.id).toSet().length, 10);
      // 数量封顶：只要 4 道。
      final four = pickPracticeQuestions(
        candidates: candidates,
        count: 4,
        random: Random(1),
      );
      expect(four.length, 4);
      // 5+5 轮流取：同一知识点不连续集中。
      final picked = pickPracticeQuestions(
        candidates: candidates,
        count: 10,
        random: Random(1),
      );
      final kps = picked.map((q) => q.knowledgePointIds.first).toList();
      for (var i = 1; i < kps.length; i++) {
        expect(kps[i], isNot(kps[i - 1]), reason: '第 $i 道与上一道同知识点');
      }
    });

    test('activePoolIds：归档题保留卡片但不进活动池', () {
      expect(
        activePoolIds(poolIds: {'q1', 'q2'}, archivedIds: {'q2'}),
        {'q1'},
      );
    });
  });

  group('P3 joinFsrsPool：去重 / 跳过 / 失败不中断', () {
    test('输入重复 id 只算一次；已在池的跳过，不建第二张卡', () async {
      final repo = _twoQRepo();
      final scheduler = _testScheduler();
      repo.scheduler = scheduler;
      await scheduler.initializeQuestion('q1');
      final result = await repo.joinFsrsPool(
        questions: [repo.questions[0], repo.questions[0], repo.questions[1]],
        scheduler: scheduler,
      );
      expect(result.added, 1);
      expect(result.skipped, 1);
      expect(result.failed, 0);
      expect(await scheduler.pooledQuestionIds(), {'q1', 'q2'});
    });

    test('同一轮重复入池：第二次 added 为 0，全部跳过', () async {
      final repo = _twoQRepo();
      final scheduler = _testScheduler();
      repo.scheduler = scheduler;
      final first = await repo.joinFsrsPool(
        questions: repo.questions,
        scheduler: scheduler,
      );
      expect(first.added, 2);
      final second = await repo.joinFsrsPool(
        questions: repo.questions,
        scheduler: scheduler,
      );
      expect(second.added, 0);
      expect(second.skipped, 2);
      expect(await scheduler.pooledQuestionIds(), {'q1', 'q2'});
    });

    test('单题失败计 failed，不中断整批', () async {
      final repo = _FakeP3Repo(
        questions: [
          _rq('q1', '题一'),
          _rq('qBad', '坏题'),
          _rq('q2', '题二'),
        ],
        records: [_rec('q1'), _rec('qBad'), _rec('q2')],
      );
      final scheduler = _FlakyScheduler(
        config: const SchedulerConfig(enableFuzzing: false),
        store: InMemoryCardStore(),
      );
      repo.scheduler = scheduler;
      final result = await repo.joinFsrsPool(
        questions: repo.questions,
        scheduler: scheduler,
      );
      expect(result.added, 2);
      expect(result.failed, 1);
      expect(await scheduler.pooledQuestionIds(), {'q1', 'q2'});
    });
  });

  group('P3 入口 1：错题本批量勾选', () {
    test('全选全部筛选结果：文案含数量与口径；已在池的跳过并计数', () async {
      final repo = _FakeP3WrongbookRepo();
      final (notifier, container) = await _wrongbookContainer(repo);
      final scheduler = container.read(reviewSchedulerProvider);
      await scheduler.initializeQuestion('q1');
      await notifier.load();
      expect(container.read(wrongbookProvider).fsrsPoolIds, {'q1'});

      notifier.selectReviewAllFiltered();
      expect(
        container.read(wrongbookProvider).reviewSelectionLabel(),
        '已选 3 道（全部筛选结果）',
      );
      final result = await notifier.joinReviewFsrs();
      expect(result.message, contains('新增 2 道'));
      expect(result.message, contains('1 道已在复习，跳过'));
      expect(result.showReviewAction, isTrue);
      expect(await scheduler.pooledQuestionIds(), {'q1', 'q3', 'q4'});
      // 做完清空选择。
      expect(
        container.read(wrongbookProvider).reviewSelectionLabel(),
        '已选 0 道',
      );
    });

    test('分页选择：勾选当前页只影响当页题；行内已在复习标记', () async {
      final repo = _FakeP3WrongbookRepo();
      final (notifier, container) = await _wrongbookContainer(repo);
      final scheduler = container.read(reviewSchedulerProvider);
      await scheduler.initializeQuestion('q1');
      await notifier.load();
      final s = container.read(wrongbookProvider);
      expect(s.isInReviewPool(s.questions[0]), isTrue);

      notifier.selectReviewPage([repo.questions[0], repo.questions[2]]);
      expect(
        container.read(wrongbookProvider).reviewSelectionLabel(),
        '已选 2 道',
      );
      final result = await notifier.joinReviewFsrs();
      expect(result.message, contains('新增 1 道'));
      expect(result.message, contains('1 道已在复习，跳过'));
    });

    test('筛选变了：全选口径立即过期清空，不隐式扩大范围', () async {
      final repo = _FakeP3WrongbookRepo();
      final (notifier, container) = await _wrongbookContainer(repo);
      final scheduler = container.read(reviewSchedulerProvider);
      notifier.selectReviewAllFiltered();
      expect(
        container.read(wrongbookProvider).reviewSelectionLabel(),
        '已选 3 道（全部筛选结果）',
      );
      // 筛选一变，_pruneReviewSelection 立即清空旧的全选（不留到确认时）。
      notifier.setFilterErrorType('计算错误');
      expect(
        container.read(wrongbookProvider).reviewSelectionLabel(),
        '已选 0 道',
      );
      final result = await notifier.joinReviewFsrs();
      expect(result.message, '没有题被加入复习');
      expect(result.showReviewAction, isFalse);
      expect(await scheduler.pooledQuestionIds(), isEmpty);
    });

    test('立即专项练习不建卡；导出勾选不影响加题选择', () async {
      final repo = _FakeP3WrongbookRepo();
      final (notifier, container) = await _wrongbookContainer(repo);
      final scheduler = container.read(reviewSchedulerProvider);
      notifier.selectReviewPage([repo.questions[0], repo.questions[2]]);
      final ids = notifier.practiceIdsFromReviewSelection();
      expect(ids, containsAll(['q1', 'q3']));
      expect(await scheduler.pooledQuestionIds(), isEmpty);
      // 导出勾选与加题选择互斥、互不影响。
      expect(notifier.toggleExportSelected('q1'), isNull);
      expect(
        container.read(wrongbookProvider).reviewSelectionLabel(),
        '已选 2 道',
      );
    });
  });

  group('P3 入口 2：练习小结收错题', () {
    Future<(ReviewNotifier, ProviderContainer)> startPracticeSummary({
      bool prePoolQ1 = false,
    }) async {
      final repo = _twoQRepo();
      final container = _reviewContainer(repo);
      final scheduler = container.read(reviewSchedulerProvider);
      if (prePoolQ1) await scheduler.initializeQuestion('q1');
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      expect(
        await notifier.startPracticeWithIds(['q1', 'q2']),
        PracticeStartOutcome.started,
      );
      await _walkCurrent(notifier, container);
      await _walkCurrent(notifier, container);
      await _waitFor(container, (s) => s.showSummary);
      expect(container.read(reviewProvider).showSummary, isTrue);
      return (notifier, container);
    }

    test('默认全勾答错题；未判分另列默认不勾；重复进小结不重复建卡', () async {
      final (notifier, container) = await startPracticeSummary();
      final scheduler = container.read(reviewSchedulerProvider);
      var s = container.read(reviewProvider);
      expect(s.sumWrongQuestionIds, {'q1'});
      expect(s.sumUngradedQuestionIds, {'q2'});

      notifier.initSummaryCollect();
      s = container.read(reviewProvider);
      expect(s.sumCollectSelected, {'q1'});
      // 未判分另列：可勾，默认不勾。
      notifier.toggleSummaryCollect('q2', true);
      expect(
        container.read(reviewProvider).sumCollectSelected,
        {'q1', 'q2'},
      );
      // 只建新卡：本次专项练习的错不产生正式 FSRS 事件。
      expect(await scheduler.pooledQuestionIds(), isEmpty);
      final message = await notifier.collectSummaryWrong();
      expect(message, contains('新增 2 道'));
      expect(await scheduler.pooledQuestionIds(), {'q1', 'q2'});
      final store = (scheduler as FsrsReviewScheduler).store;
      final card = await store.load('q1');
      expect(card, isNotNull);
      expect(card!.firstReviewedAt, isNull);
      // 同一轮重复进小结：再收一次不重复建卡（added 为 0 时文案只报跳过）。
      notifier.initSummaryCollect();
      final again = await notifier.collectSummaryWrong();
      expect(again, contains('2 道已在复习，跳过'));
      expect(await scheduler.pooledQuestionIds(), {'q1', 'q2'});
    });

    test('已在复习的答错题默认不勾', () async {
      final (notifier, container) = await startPracticeSummary(
        prePoolQ1: true,
      );
      notifier.initSummaryCollect();
      expect(
        container.read(reviewProvider).sumCollectSelected,
        isEmpty,
      );
      // 仍可手动勾未判分的题。
      notifier.toggleSummaryCollect('q2', true);
      final message = await notifier.collectSummaryWrong();
      expect(message, contains('新增 1 道'));
    });

    test('中途退出不产生小结、不自动收题；已核对的事实保留；恢复后出完整小结',
        () async {
      final repo = _twoQRepo();
      final container = _reviewContainer(repo);
      final scheduler = container.read(reviewSchedulerProvider);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      // 固定种子 Random(0) → 题序 [q1, q2]（不固定则打乱，测试不稳定）。
      expect(
        await notifier.startPracticeWithIds(
          ['q1', 'q2'],
          random: Random(0),
        ),
        PracticeStartOutcome.started,
      );
      await _walkObjective(notifier, 'A'); // q1 答错
      expect(await notifier.submitCheck(), isTrue);
      // 中途退出（暂停）：不产生小结。
      await notifier.pauseSession();
      var s = container.read(reviewProvider);
      expect(s.showSummary, isFalse);
      expect(s.inSession, isFalse);
      // 已核对的 q1 事实保留在 attempts 里，正式日期没动（没建卡）。
      expect(repo.attempts.length, 1);
      expect(repo.attempts.values.single.correct, 0);
      expect(await scheduler.pooledQuestionIds(), isEmpty);
      // 恢复完成后再出完整小结（恢复时重建计数，见 startSession resume 分支）。
      await notifier.startSession(resume: true);
      await _walkPaper(notifier); // q2 未判分
      expect(await notifier.submitCheck(), isTrue);
      await _waitFor(container, (s) => s.showSummary);
      s = container.read(reviewProvider);
      expect(s.showSummary, isTrue);
      expect(s.sumCompleted, 2);
      expect(s.sumWrongQuestionIds, {'q1'});
      expect(s.sumUngradedQuestionIds, {'q2'});
    });
  });

  group('P3 会话不互相覆盖：错题本批量开专项练习', () {
    test('已有未完成正式复习时开练被挡住、挂起；放弃后按挂起题单开练', () async {
      final repo = _twoQRepo();
      final container = _reviewContainer(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      await notifier.pauseSession();
      expect(repo.savedState, isNotNull);
      final savedBefore = repo.savedState;

      final outcome = await notifier.startPracticeWithIds(['q1', 'q2']);
      expect(outcome, PracticeStartOutcome.blockedByResume);
      var s = container.read(reviewProvider);
      expect(s.inSession, isFalse);
      expect(s.resume, isNotNull);
      expect(repo.savedState, same(savedBefore));
      expect(s.pendingPracticeIds, ['q1', 'q2']);
      // 放弃旧会话后按挂起题单开练，不断点。
      await notifier.abandonResumeAndStartPractice();
      s = container.read(reviewProvider);
      expect(s.inSession, isTrue);
      expect(s.sessionMode, ReviewMode.practice);
      expect(
        s.sessionQuestions.map((q) => q.questionId).toSet(),
        {'q1', 'q2'},
      );
    });

    test('进行中的会话里开练也被挡住，不覆盖单行表 review_state', () async {
      final repo = _twoQRepo();
      final container = _reviewContainer(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      final outcome = await notifier.startPracticeWithIds(['q1']);
      expect(outcome, PracticeStartOutcome.blockedByResume);
      expect(
        container.read(reviewProvider).pendingPracticeIds,
        ['q1'],
      );
    });
  });

  group('P3 归档 / 取消 / 恢复规则', () {
    test('归档：卡片保留，活动池滤掉；取消归档后恢复进池', () async {
      final repo = _twoQRepo();
      final scheduler = _testScheduler();
      repo.scheduler = scheduler;
      await repo.joinFsrsPool(
        questions: repo.questions,
        scheduler: scheduler,
      );
      expect(await scheduler.pooledQuestionIds(), {'q1', 'q2'});
      await repo.archive(repo.questions[0]);
      final archived = (await repo.all()).firstWhere((q) => q.id == 'q1');
      expect(archived.isArchived, isTrue);
      // 卡片还在（历史状态保留），活动池按 activePoolIds 滤掉。
      expect(await scheduler.pooledQuestionIds(), {'q1', 'q2'});
      expect(
        activePoolIds(
          poolIds: await scheduler.pooledQuestionIds(),
          archivedIds: {'q1'},
        ),
        {'q2'},
      );
      await repo.archive(archived, archived: false);
      expect(
        activePoolIds(
          poolIds: await scheduler.pooledQuestionIds(),
          archivedIds: const {},
        ),
        {'q1', 'q2'},
      );
    });

    test('取消加入：停后续调度、保留历史卡片；重加恢复原卡不重复建卡', () async {
      final repo = _twoQRepo();
      final scheduler = _testScheduler();
      repo.scheduler = scheduler;
      await repo.joinFsrsPool(
        questions: repo.questions,
        scheduler: scheduler,
      );
      final before = await scheduler.store.load(
        'q1',
      );
      expect(before, isNotNull);
      final cancelled = await repo.cancelReviewBatch(repo.questions);
      expect(cancelled.cancelled, 2);
      // 卡片保留（历史状态不删），题的 reviewJoined 已翻掉。
      expect(await scheduler.pooledQuestionIds(), {'q1', 'q2'});
      expect(repo.questions.every((q) => !q.reviewJoined), isTrue);
      // 重加：直接返回原卡（cardId 不变），不重复建卡。
      final rejoined = await repo.joinFsrsPool(
        questions: repo.questions,
        scheduler: scheduler,
      );
      expect(rejoined.added, 0);
      expect(rejoined.skipped, 2);
      final after = await scheduler.store.load(
        'q1',
      );
      expect(after!.cardId, before!.cardId);
    });
  });

  group('P3 入口 3：薄弱点样本量统计', () {
    AttemptData att(
      String qid,
      String mode,
      int? correct,
      int createdAt,
    ) => AttemptData(
      id: 'att-$qid-$createdAt-$correct',
      questionId: qid,
      sessionId: 'sess-1',
      mode: mode,
      correct: correct,
      answerVersion: 1,
      contentVersion: 0,
      status: '已提交',
      submissionId: 'sub-$qid-$createdAt-$correct',
      createdAt: createdAt,
    );

    test('正式与专项都参与、来源分别计数；近期错误率按已判分算；范围外不计', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final old = now - 30 * 24 * 60 * 60 * 1000; // 30 天前：本周范围外
      final group = WeakGroup(
        subjectId: 'math',
        key: '概念不清',
        titles: const ['题 q1', '题 q2', '题 q3'],
      )..questionIds.addAll({'q1', 'q2', 'q3'});
      final state = ReportState(
        range: 'week',
        loading: false,
        attempts: [
          att('q1', ReviewMode.due, 0, now),
          att('q1', ReviewMode.due, 1, now),
          att('q2', ReviewMode.practice, 0, now),
          att('q2', ReviewMode.practice, null, now),
          att('q3', ReviewMode.due, 1, now),
          att('q1', ReviewMode.due, 0, old), // 范围外，不计
        ],
      );
      final stats = state.weakStats(group);
      expect(stats.questionCount, 3);
      expect(stats.attemptCount, 5);
      expect(stats.wrongCount, 2);
      expect(stats.formalCount, 3);
      expect(stats.practiceCount, 2);
      // 近期错误率 = 2 答错 / 4 已判分（未判分不计入分母）。
      expect(stats.errorRate, closeTo(2 / 4, 0.001));
      expect(stats.rangeLabel, '本周');
      expect(stats.sparse, isFalse);
      expect(stats.label, contains('共 3 道'));
      expect(stats.label, contains('作答 5 次'));
      expect(stats.sourceLabel, '正式 3 次 / 专项 2 次');
    });

    test('样本少（题数 < 3 或作答 < 5）标数据较少；无已判分时错误率为 —', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final group = WeakGroup(
        subjectId: 'math',
        key: '计算错误',
        titles: const ['题 q1'],
      )..questionIds.addAll({'q1'});
      final state = ReportState(
        range: 'all',
        loading: false,
        attempts: [att('q1', ReviewMode.due, null, now)],
      );
      final stats = state.weakStats(group);
      expect(stats.sparse, isTrue);
      expect(stats.errorRate, isNull);
      expect(stats.label, contains('近期错误率 —'));
    });
  });

  group('P3 入口 3：薄弱点列表页', () {
    Future<void> pumpWeakList(
      WidgetTester tester, {
      required void Function(List<String> ids, {int? count}) onStart,
      required Future<String> Function(List<String> ids) onJoin,
    }) async {
      final questions = [
        for (var i = 0; i < 25; i++) _rq('q$i', '题 q$i'),
      ];
      final group = WeakGroup(
        subjectId: 'math',
        key: '概念不清',
        titles: const ['题 q0'],
      )..questionIds.addAll({for (final q in questions) q.id});
      final report = ReportState(
        range: 'all',
        loading: false,
        questions: questions,
        subjects: Subject.all,
        fsrsPoolIds: {'q0'},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: WeakPointListPage(
            group: group,
            report: report,
            questions: questions,
            isKp: false,
            onStartPractice: onStart,
            onJoinReview: onJoin,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('默认全选 + 数量预选 + 分页 + 自定义上限', (tester) async {
      List<String>? startedIds;
      int? startedCount;
      await pumpWeakList(
        tester,
        onStart: (ids, {count}) {
          startedIds = ids;
          startedCount = count;
        },
        onJoin: (_) async => '',
      );
      Future<void> tapText(String label) async {
        final finder = find.text(label);
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      // 默认预选 10 道，全选 25 道。
      expect(find.text('将练习 10 道（共可选 25 道）'), findsOneWidget);
      expect(find.text('共 25 道 · 第 1 / 2 页'), findsOneWidget);
      expect(find.text('已在复习'), findsOneWidget); // q0 在池里
      // 分页：下一页。
      await tapText('下一页');
      expect(find.text('共 25 道 · 第 2 / 2 页'), findsOneWidget);
      // 数量预选“全部”。
      await tapText('全部');
      expect(find.text('将练习 25 道（共可选 25 道）'), findsOneWidget);
      // 自定义超可选数时自动限到可选数。
      final customField = find.byKey(const Key('weak-custom-count'));
      await tester.ensureVisible(customField);
      await tester.enterText(customField, '999');
      await tester.pumpAndSettle();
      expect(find.text('将练习 25 道（共可选 25 道）'), findsOneWidget);
      await tester.enterText(customField, '3');
      await tester.pumpAndSettle();
      expect(find.text('将练习 3 道（共可选 25 道）'), findsOneWidget);
      // 开始专项练习：传全部勾选题 + 数量。
      await tapText('开始专项练习');
      expect(startedIds, hasLength(25));
      expect(startedCount, 3);
    });

    testWidgets('取消勾选一行后加入复习只对勾选的题生效', (tester) async {
      List<String>? joinedIds;
      await pumpWeakList(
        tester,
        onStart: (_, {count}) {},
        onJoin: (ids) async {
          joinedIds = ids;
          return '新增 ${ids.length} 道';
        },
      );
      // 取消勾选 q1（第 1 页上的行）。
      final row = find.byKey(const ValueKey('weak-row-q1'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text('将练习 10 道（共可选 24 道）'), findsOneWidget);
      final joinButton = find.text('加入复习');
      await tester.ensureVisible(joinButton);
      await tester.tap(joinButton);
      await tester.pumpAndSettle();
      expect(joinedIds, hasLength(24));
      expect(joinedIds, isNot(contains('q1')));
      expect(find.text('新增 24 道'), findsOneWidget);
    });

    testWidgets('样本少显示数据较少', (tester) async {
      await pumpWeakList(
        tester,
        onStart: (_, {count}) {},
        onJoin: (_) async => '',
      );
      // 25 道题、0 次作答：作答 < 5 → 数据较少。
      expect(find.byKey(const Key('weak-sparse-tag')), findsOneWidget);
      expect(find.text('数据较少'), findsOneWidget);
    });
  });

  group('P3 删除级联：永久删除删 fsrs_cards，留 fsrs_events', () {
    test('删题同事务删卡片行；事件账本保留', () async {
      final db = QuizDatabase.memory();
      addTearDown(db.close);
      await createTablesImpl(db);
      await db.customStatement(
        "INSERT INTO questions(id, title, subject_id, created_at) "
        "VALUES('q1','题一','math',1700000000000)",
      );
      await db.customStatement(
        "INSERT INTO fsrs_cards(question_id, card_id, scheduler_config_id,"
        " card_state_json, next_due_at, updated_at)"
        " VALUES('q1',1,'cfg','{}',1700000000000,1700000000000)",
      );
      await db.customStatement(
        "INSERT INTO fsrs_events(event_id, question_id, kind, processed_at)"
        " VALUES('evt-1','q1','review',1700000000000)",
      );
      Future<int> cardCount() async => (await db
              .customSelect('SELECT COUNT(*) AS c FROM fsrs_cards')
              .getSingle())
          .read<int>('c');
      Future<int> eventCount() async => (await db
              .customSelect('SELECT COUNT(*) AS c FROM fsrs_events')
              .getSingle())
          .read<int>('c');
      expect(await cardCount(), 1);
      expect(await eventCount(), 1);
      await deleteQuestionFromImpl(db, 'q1');
      expect(await cardCount(), 0);
      // 事件账本是幂等审计记录，不随删题删（新提交用新 eventId，不撞旧事件）。
      expect(await eventCount(), 1);
      final rows = await (db.select(
        db.questions,
      )..where((t) => t.id.equals('q1'))).get();
      expect(rows, isEmpty);
    });
  });
}
