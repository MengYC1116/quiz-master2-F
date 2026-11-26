// 专项练习暂停恢复（2026-11-26）：未加入复习的题没有 cause_records 行，
// 旧逻辑建队时错因取空、暂停存空队列，恢复校验又全删，导致恢复条不出。
// 修法：buildPracticeQueue 无记录时回退 q.allCauses；_validateSavedSession
// 无记录但错因在 q.allCauses 里就保留。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/state/review_notifier.dart';

import 'review_page_test.dart'
    show FakeReviewRepo, pumpReview, rq, tapButton;

/// 未加入复习的题（有题面错因、无 cause_records 行）。
Question _pq(String id, {List<String> errorTypes = const ['计算错误']}) =>
    Question(
      id: id,
      title: '题 $id',
      subjectId: 'math',
      errorTypes: errorTypes,
      createdAt: DateTime(2026, 11, 10),
      isOrganized: true,
      reviewJoined: false,
      contentVersion: 3,
      answerVersion: 2,
    );

/// 走完一道题并核对提交（P2：核对提交是唯一正式提交入口）。
Future<void> _walkAndCommit(ReviewNotifier notifier) async {
  notifier.beginAnswer();
  await notifier.completePaperAnswer();
  await notifier.submitCheck();
}

void main() {
  test('buildPracticeQueue：无 cause_records 的题回退到题面错因', () {
    final qs = [
      _pq('q1', errorTypes: ['计算错误']),
      _pq('q2', errorTypes: ['概念不清']),
    ];
    final queue = buildPracticeQueue(
      questions: qs,
      recordsByQ: const {},
      count: 0,
      randomOrder: false,
    );
    expect(queue.map((e) => e.questionId).toList(), ['q1', 'q2']);
    expect(
      queue.map((e) => e.causes).toList(),
      [
        ['计算错误'],
        ['概念不清'],
      ],
    );
  });

  group('专项练习暂停恢复（未加入复习）', () {
    late QuizDatabase db;
    late QuestionRepository repo;

    setUp(() async {
      db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      repo = QuestionRepository(AppDatabase.instance);
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
        AppDatabase.resetForTest();
      });
    });

    /// 新容器 + 确定性调度器（fuzzing 关）读当前库状态。
    (ProviderContainer, ReviewNotifier) loadNotifier() {
      final container = ProviderContainer.test(
        overrides: [
          repositoryProvider.overrideWithValue(repo),
          reviewSchedulerProvider.overrideWithValue(
            FsrsReviewScheduler(
              config: const SchedulerConfig(enableFuzzing: false),
              store: InMemoryCardStore(),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      // autoDispose 保活（D-36）：像页面 ref.watch 那样持一个监听。
      container.listen(reviewProvider, (_, __) {});
      return (container, container.read(reviewProvider.notifier));
    }

    test('暂停后断点保留、继续回到断点处', () async {
      await AppDatabase.upsertQuestionInto(db, _pq('q1'));
      await AppDatabase.upsertQuestionInto(db, _pq('q2'));
      final (container, notifier) = loadNotifier();
      await notifier.load();
      await notifier.startPracticeSession();
      var s = container.read(reviewProvider);
      expect(s.inSession, isTrue);
      expect(s.sessionQuestions.length, 2);
      expect(
        s.sessionQuestions.map((sq) => sq.causes).toList(),
        [
          ['计算错误'],
          ['计算错误'],
        ],
      );
      final firstId = s.sessionQuestions[0].questionId;
      final secondId = s.sessionQuestions[1].questionId;
      // 走完第 1 道，到第 2 道再暂停。
      await _walkAndCommit(notifier);
      s = container.read(reviewProvider);
      expect(s.sessionIndex, 1);
      expect(s.currentSessionQuestion.questionId, secondId);
      await notifier.pauseSession();
      s = container.read(reviewProvider);
      expect(s.inSession, isFalse);
      expect(await repo.reviewState(), isNotNull);
      expect(s.resume, isNotNull);
      expect(s.resume!.sessionIndex, 1);
      expect(
        s.resume!.sessionQuestions.map((sq) => sq.questionId).toList(),
        [firstId, secondId],
      );
      // 模拟重启：新容器重读，断点仍在；继续回到第 2 道。
      final (container2, notifier2) = loadNotifier();
      await notifier2.load();
      var s2 = container2.read(reviewProvider);
      expect(s2.resume, isNotNull);
      expect(s2.resume!.sessionIndex, 1);
      await notifier2.startSession(resume: true);
      s2 = container2.read(reviewProvider);
      expect(s2.inSession, isTrue);
      expect(s2.sessionIndex, 1);
      expect(s2.currentSessionQuestion.questionId, secondId);
    });

    test('批量入口同样能恢复', () async {
      await AppDatabase.upsertQuestionInto(db, _pq('q1'));
      await AppDatabase.upsertQuestionInto(db, _pq('q2'));
      final (container, notifier) = loadNotifier();
      await notifier.load();
      final outcome = await notifier.startPracticeWithIds(['q1', 'q2']);
      expect(outcome, PracticeStartOutcome.started);
      await notifier.pauseSession();
      var s = container.read(reviewProvider);
      expect(s.resume, isNotNull);
      expect(
        s.resume!.sessionQuestions.map((sq) => sq.questionId).toSet(),
        {'q1', 'q2'},
      );
      final (container2, notifier2) = loadNotifier();
      await notifier2.load();
      final s2 = container2.read(reviewProvider);
      expect(s2.resume, isNotNull);
      await notifier2.startSession(resume: true);
      expect(container2.read(reviewProvider).inSession, isTrue);
      expect(
        container2
            .read(reviewProvider)
            .sessionQuestions
            .map((sq) => sq.questionId)
            .toSet(),
        {'q1', 'q2'},
      );
    });

    test('恢复校验：暂停后归档的题被剔除，其余保留', () async {
      await AppDatabase.upsertQuestionInto(db, _pq('q1'));
      await AppDatabase.upsertQuestionInto(db, _pq('q2'));
      final (container, notifier) = loadNotifier();
      await notifier.load();
      await notifier.startPracticeSession();
      await notifier.pauseSession();
      expect(container.read(reviewProvider).resume, isNotNull);
      await repo.archive(_pq('q1'), archived: true);
      final (container2, notifier2) = loadNotifier();
      await notifier2.load();
      final s2 = container2.read(reviewProvider);
      expect(s2.resume, isNotNull);
      expect(
        s2.resume!.sessionQuestions.map((sq) => sq.questionId).toList(),
        ['q2'],
      );
    });

    test('版本检查不变：未作答的题版本变化后刷新快照，断点仍在', () async {
      await AppDatabase.upsertQuestionInto(db, _pq('q1'));
      await AppDatabase.upsertQuestionInto(db, _pq('q2'));
      final (container, notifier) = loadNotifier();
      await notifier.load();
      await notifier.startPracticeSession();
      await notifier.pauseSession();
      // 暂停后 q1 题面版本变了，本题尚未作答。
      await AppDatabase.upsertQuestionInto(
        db,
        _pq('q1').copyWith(answerVersion: 3, contentVersion: 4),
      );
      final (container2, notifier2) = loadNotifier();
      await notifier2.load();
      final s2 = container2.read(reviewProvider);
      expect(s2.resume, isNotNull);
      final resumed = s2.resume!.sessionQuestions.firstWhere(
        (sq) => sq.questionId == 'q1',
      );
      expect(resumed.answerVersionAtStart, 3);
      expect(resumed.contentVersionAtStart, 4);
      expect(resumed.stage, SessionStage.view);
    });
  });

  group('专项练习暂停恢复（无错因的题）', () {
    late QuizDatabase db;
    late QuestionRepository repo;

    setUp(() async {
      db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      repo = QuestionRepository(AppDatabase.instance);
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
        AppDatabase.resetForTest();
      });
    });

    /// 新容器 + 确定性调度器（fuzzing 关）读当前库状态。
    (ProviderContainer, ReviewNotifier) loadNotifier() {
      final container = ProviderContainer.test(
        overrides: [
          repositoryProvider.overrideWithValue(repo),
          reviewSchedulerProvider.overrideWithValue(
            FsrsReviewScheduler(
              config: const SchedulerConfig(enableFuzzing: false),
              store: InMemoryCardStore(),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      // autoDispose 保活（D-36）：像页面 ref.watch 那样持一个监听。
      container.listen(reviewProvider, (_, __) {});
      return (container, container.read(reviewProvider.notifier));
    }

    test('无错因的题暂停后仍有恢复条、继续回到断点', () async {
      await AppDatabase.upsertQuestionInto(
        db,
        _pq('q1', errorTypes: const []),
      );
      await AppDatabase.upsertQuestionInto(
        db,
        _pq('q2', errorTypes: const []),
      );
      final (container, notifier) = loadNotifier();
      await notifier.load();
      await notifier.startPracticeSession();
      var s = container.read(reviewProvider);
      expect(s.inSession, isTrue);
      expect(s.sessionQuestions.length, 2);
      expect(
        s.sessionQuestions.map((sq) => sq.causes).toList(),
        [<String>[], <String>[]],
      );
      // 走完第 1 道，到第 2 道再暂停（顺序随机，按实际队首队尾取）。
      final firstId = s.sessionQuestions[0].questionId;
      final secondId = s.sessionQuestions[1].questionId;
      await _walkAndCommit(notifier);
      s = container.read(reviewProvider);
      expect(s.sessionIndex, 1);
      expect(s.currentSessionQuestion.questionId, secondId);
      await notifier.pauseSession();
      s = container.read(reviewProvider);
      expect(s.inSession, isFalse);
      expect(await repo.reviewState(), isNotNull);
      expect(s.resume, isNotNull);
      expect(s.resume!.sessionIndex, 1);
      expect(
        s.resume!.sessionQuestions.map((sq) => sq.questionId).toList(),
        [firstId, secondId],
      );
      // 模拟重启：新容器重读，断点仍在；继续回到第 2 道。
      final (container2, notifier2) = loadNotifier();
      await notifier2.load();
      var s2 = container2.read(reviewProvider);
      expect(s2.resume, isNotNull);
      expect(s2.resume!.sessionIndex, 1);
      await notifier2.startSession(resume: true);
      s2 = container2.read(reviewProvider);
      expect(s2.inSession, isTrue);
      expect(s2.sessionIndex, 1);
      expect(s2.currentSessionQuestion.questionId, secondId);
    });
    test('混合会话：有错因的题与无错因的题混练，断点位置不错位', () async {
      await AppDatabase.upsertQuestionInto(
        db,
        _pq('q1', errorTypes: const ['计算错误']),
      );
      await AppDatabase.upsertQuestionInto(
        db,
        _pq('q2', errorTypes: const []),
      );
      final (container, notifier) = loadNotifier();
      await notifier.load();
      await notifier.startPracticeSession();
      var s = container.read(reviewProvider);
      expect(s.inSession, isTrue);
      expect(s.sessionQuestions.length, 2);
      // 一道有错因、一道无错因（顺序随机，只断言集合）。
      expect(
        s.sessionQuestions.map((sq) => sq.causes).toSet(),
        {
          ['计算错误'],
          <String>[],
        },
      );
      final secondId = s.sessionQuestions[1].questionId;
      await _walkAndCommit(notifier);
      s = container.read(reviewProvider);
      expect(s.sessionIndex, 1);
      await notifier.pauseSession();
      s = container.read(reviewProvider);
      expect(s.resume, isNotNull);
      expect(s.resume!.sessionIndex, 1);
      // 新容器重读，断点仍在第 2 道；继续回到断点。
      final (container2, notifier2) = loadNotifier();
      await notifier2.load();
      var s2 = container2.read(reviewProvider);
      expect(s2.resume, isNotNull);
      expect(s2.resume!.sessionIndex, 1);
      await notifier2.startSession(resume: true);
      s2 = container2.read(reviewProvider);
      expect(s2.inSession, isTrue);
      expect(s2.sessionIndex, 1);
      expect(s2.currentSessionQuestion.questionId, secondId);
    });
  });

  group('专项练习暂停恢复（页面）', () {
    testWidgets('暂停后出恢复条：继续回到中断的题', (tester) async {
      final repo = FakeReviewRepo(
        questions: [
          rq('q1', '函数极限', errorTypes: const ['概念不清']),
          rq('q2', '导数应用综合', errorTypes: const ['方法不会']),
        ],
        records: const [],
      );
      await pumpReview(tester, repo: repo);
      await tapButton(tester, '专项练习');
      await tapButton(tester, '开始练习');
      expect(find.textContaining('本轮共 2 道题、2 个错因'), findsOneWidget);
      // 走完第 1 道，到第 2 道再暂停。
      await tapButton(tester, '开始作答');
      await tapButton(tester, '我已完成作答');
      await tapButton(tester, '下一题');
      expect(find.textContaining('第 2 / 2 道题'), findsOneWidget);
      await tapButton(tester, '暂停');
      expect(find.textContaining('继续上次会话'), findsNWidgets(2)); // 恢复条文案 + 按钮
      expect(find.text('放弃重开'), findsOneWidget);
      await tapButton(tester, '继续上次会话');
      expect(find.textContaining('第 2 / 2 道题'), findsOneWidget);
      expect(find.text('① 看题'), findsOneWidget);
    });

    testWidgets('无错因的题暂停后出恢复条', (tester) async {
      final repo = FakeReviewRepo(
        questions: [
          rq('q1', '函数极限', errorTypes: const []),
          rq('q2', '导数应用综合', errorTypes: const []),
        ],
        records: const [],
      );
      await pumpReview(tester, repo: repo);
      await tapButton(tester, '专项练习');
      await tapButton(tester, '开始练习');
      expect(find.textContaining('本轮共 2 道题、0 个错因'), findsOneWidget);
      // 走完第 1 道，到第 2 道再暂停。
      await tapButton(tester, '开始作答');
      await tapButton(tester, '我已完成作答');
      await tapButton(tester, '下一题');
      expect(find.textContaining('第 2 / 2 道题'), findsOneWidget);
      await tapButton(tester, '暂停');
      expect(find.textContaining('继续上次会话'), findsNWidgets(2)); // 恢复条文案 + 按钮
      expect(find.text('放弃重开'), findsOneWidget);
      await tapButton(tester, '继续上次会话');
      expect(find.textContaining('第 2 / 2 道题'), findsOneWidget);
      expect(find.text('① 看题'), findsOneWidget);
    });
  });
}
