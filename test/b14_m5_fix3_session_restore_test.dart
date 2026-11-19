// 十四批 M5 修复轮 3（B 路，D-156 / GPT fix2 P1-3）：会话恢复顺序。
//
// 旧顺序：_validateSavedSession 先按 review_state.perQuestionState
// 的缓存状态做 versionCheck，后才从 review_history 补回 submittedCauses。
// 崩溃窗口（verdict 事务已提交、review_state 未更新）+ 题目版本已变化时，
// 会先按“未提交”执行 refresh 而不是按“已提交”执行 remove，已提交题目
// 可能被刷新成新版本继续留在同一会话。
// 新顺序：先按当前 sessionId 从数据库重建真实提交状态（逐错因
// hasSessionVerdict + attempt 行是否存在），再执行版本判定；已提交且
// 版本变化按既定规则移出当前会话。另：不再用题目级 reviewHistory(qid)
// 是否为空决定是否清空 submittedCauses——改为按当前 sessionId +
// causeStableId 逐项核验，避免其他 session 的历史让当前 session
// 错误保留旧提交标记。
// 走真实内存库 + 真实仓库 + 真实 ReviewNotifier（ProviderContainer），
// 不调真实接口。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/state/review_notifier.dart';

Question _q(String id) => Question(
  id: id,
  title: '题 $id',
  subjectId: 'math',
  errorTypes: const ['计算错误'],
  createdAt: DateTime(2026, 11, 10),
  isOrganized: true,
  reviewJoined: true,
  contentVersion: 3,
  answerVersion: 2,
);

void main() {
  late QuizDatabase db;
  late QuestionRepository repo;

  /// 建题 + 加入复习，返回库内错因记录。
  Future<CauseRecord> seedCause(String qid) async {
    await AppDatabase.upsertQuestionInto(db, _q(qid));
    await repo.setReviewJoined(_q(qid), true);
    final records = await repo.causeRecordsFor(qid);
    return records.firstWhere((r) => r.cause == '计算错误');
  }

  /// 一题的保存快照（SessionQuestionState.toJson）：会话开始时的
  /// 版本快照（answer 2 / content 3），默认无提交、无 attempt。
  Map<String, Object?> savedSq(
    String qid, {
    Set<String> submittedCauses = const {},
    String? attemptId,
  }) => SessionQuestionState(
    questionId: qid,
    causes: const ['计算错误'],
    answerVersionAtStart: 2,
    contentVersionAtStart: 3,
    questionSubmissionId: 'qs-$qid',
    attemptSubmissionId: 'attsub-$qid',
    submittedCauses: submittedCauses,
    attemptId: attemptId,
  ).toJson();

  Future<void> saveSession({
    required Map<String, Map<String, Object?>> perQuestionState,
  }) async {
    await repo.saveReviewState(
      queue: const [
        ReviewQueueItem(questionId: 'q1', cause: '计算错误'),
        ReviewQueueItem(questionId: 'q2', cause: '计算错误'),
      ],
      position: 0,
      sessionId: 'sess-1',
      mode: ReviewMode.due,
      perQuestionState: perQuestionState,
    );
  }

  Future<ReviewState> loadState() async {
    final container = ProviderContainer.test(
      overrides: [repositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    // autoDispose 保活（D-36）：像页面 ref.watch 那样持一个监听。
    container.listen(reviewProvider, (_, __) {});
    final notifier = container.read(reviewProvider.notifier);
    await notifier.load();
    return container.read(reviewProvider);
  }

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

  group('十四批 M5 修复轮 3：崩溃窗口恢复先重建提交状态再判版本', () {
    test('数据库 verdict 已提交、review_state 未更新、题目版本随后变化、重启恢复：已提交题目被移出而不是刷新', () async {
      final rec1 = await seedCause('q1');
      await seedCause('q2');
      // 会话开始时的快照：两题都未提交、版本快照 answer 2 / content 3。
      await saveSession(
        perQuestionState: {'q1': savedSq('q1'), 'q2': savedSq('q2')},
      );
      // 崩溃窗口：verdict 事务已提交（纸上作答，无 attempt，
      // hasAttempt 为 false），review_state 没来得及更新。
      await repo.submitCauseVerdict(
        questionId: 'q1',
        record: rec1,
        verdict: ReviewVerdict.solved,
        verificationStatus: Verification.unverified,
        verificationSource: Verification.unverified,
        sessionId: 'sess-1',
        submissionId: childSubmissionId('qs-q1', causeStableId(rec1)),
      );
      // 题目版本随后变化（详情页改过内容）：content 3 → 4。
      final q1 = (await repo.questionById('q1'))!;
      await repo.save(q1.copyWith(contentVersion: 4));
      expect((await repo.questionById('q1'))!.contentVersion, 4);

      final s = await loadState();
      expect(s.loadError, isFalse, reason: '恢复加载本身不应失败');
      expect(s.resume, isNotNull, reason: 'q2 仍在，会话整体未失效');
      // 旧顺序会把 q1 按“未提交”刷新成新版本留在会话里；
      // 新顺序先从库重建提交态，q1 已提交 + 版本变化 → 移出。
      expect(
        s.resume!.sessionQuestions.map((sq) => sq.questionId),
        ['q2'],
        reason: '已提交且版本变化的 q1 必须移出当前会话',
      );
      // 修正后的快照已写回：库里 review_state 队列不再含 q1。
      final saved = (await repo.reviewState())!;
      expect(
        saved.queue.map((e) => e.questionId),
        ['q2'],
        reason: '移除后修正快照应持久化，不留已移出题目的断点',
      );
    });

    test('对照：同样崩溃窗口但版本不变，已提交题目保留且提交标记从库重建', () async {
      final rec1 = await seedCause('q1');
      await seedCause('q2');
      await saveSession(
        perQuestionState: {'q1': savedSq('q1'), 'q2': savedSq('q2')},
      );
      await repo.submitCauseVerdict(
        questionId: 'q1',
        record: rec1,
        verdict: ReviewVerdict.solved,
        verificationStatus: Verification.unverified,
        verificationSource: Verification.unverified,
        sessionId: 'sess-1',
        submissionId: childSubmissionId('qs-q1', causeStableId(rec1)),
      );

      final s = await loadState();
      expect(s.resume, isNotNull);
      expect(
        s.resume!.sessionQuestions.map((sq) => sq.questionId),
        ['q1', 'q2'],
      );
      final resumed1 = s.resume!.sessionQuestions.firstWhere(
        (sq) => sq.questionId == 'q1',
      );
      expect(
        resumed1.submittedCauses,
        contains('计算错误'),
        reason: 'review_state 里是空的，提交标记必须从数据库 verdict 行重建',
      );
    });
  });

  group('十四批 M5 修复轮 3：提交状态按当前 session 逐项核验', () {
    test('当前 session 无记录、其他 session 有历史时，不错误保留旧提交标记与旧 attemptId', () async {
      final rec1 = await seedCause('q1');
      await seedCause('q2');
      // 其他 session 的 verdict 行（题目级 reviewHistory(qid) 非空，
      // 但不是当前 session 的）。
      await repo.submitCauseVerdict(
        questionId: 'q1',
        record: rec1,
        verdict: ReviewVerdict.solved,
        verificationStatus: Verification.unverified,
        verificationSource: Verification.unverified,
        sessionId: 'sess-other',
        submissionId: childSubmissionId('qs-other', causeStableId(rec1)),
      );
      expect((await repo.reviewHistory('q1')).isNotEmpty, isTrue);
      // 当前 session 的快照里留着 stale 的提交标记与 attemptId
      // （库里当前 session 既无 verdict 行、也无 attempt 行）。
      // 旧代码：submittedCauses 非空 + 题目级 history 非空 → 保留旧标记。
      await saveSession(
        perQuestionState: {
          'q1': savedSq(
            'q1',
            submittedCauses: {'计算错误'},
            attemptId: 'att-stale',
          ),
          'q2': savedSq('q2'),
        },
      );

      final s = await loadState();
      expect(s.resume, isNotNull);
      final resumed1 = s.resume!.sessionQuestions.firstWhere(
        (sq) => sq.questionId == 'q1',
      );
      expect(
        resumed1.submittedCauses,
        isEmpty,
        reason: '其他 session 的历史不得让当前 session 保留旧提交标记',
      );
      expect(
        resumed1.attemptId,
        isNull,
        reason: '库里没有当前 session 的 attempt 行，缓存里的旧 attemptId 须清掉',
      );
      // q1 本身仍在（未提交、版本未变，只是标记被纠正）。
      expect(
        s.resume!.sessionQuestions.map((sq) => sq.questionId),
        ['q1', 'q2'],
      );
    });

    test('缓存有旧 attemptId、库里无 attempt 行、版本变化：按未提交刷新并清掉 attemptId', () async {
      await seedCause('q1');
      await seedCause('q2');
      await saveSession(
        perQuestionState: {
          'q1': savedSq('q1', attemptId: 'att-stale'),
          'q2': savedSq('q2'),
        },
      );
      final q1 = (await repo.questionById('q1'))!;
      await repo.save(q1.copyWith(contentVersion: 4));

      final s = await loadState();
      expect(s.resume, isNotNull);
      final resumed1 = s.resume!.sessionQuestions.firstWhere(
        (sq) => sq.questionId == 'q1',
      );
      // 无库内 attempt、无 verdict → 未提交 → 刷新而不是移出。
      expect(resumed1.answerVersionAtStart, 2);
      expect(resumed1.contentVersionAtStart, 4);
      expect(resumed1.stage, SessionStage.view);
      expect(
        resumed1.attemptId,
        isNull,
        reason: '旧代码 copyWith(attemptId: null) 是空操作（?? 保留旧值），须真正清掉',
      );
    });
  });
}
