// ARCH-PLAN-A 第 3 阶段：ReviewNotifier 单测（不启动 widget）。
// 十四批 M3 重写：旧四步（recall/remedy/redo/check，按错因逐个走）
// 已废止，改为五段统一流程（看题 → 作答 → 核对 → 错因自查 → 下一题
// → 小结），一道题内部的状态变化；一题多错因时题目只展示一次、
// 各错因分别记录 verdict。
// 注入方式与 settings_controller_test.dart / home_provider_test.dart
// 一致：ProviderContainer.test + repositoryProvider.overrideWithValue。
// autoDispose 下单测要像页面 ref.watch 那样持一个监听保活
// （D-36：只 read 不监听时 build 里的 microtask 首查还没写回就被
// 销毁，轮询等不到 hasLoaded），见 `_container`。
//
// Fake 的 submitCauseVerdict 只模拟真实写库语义的子集（治愈规则
// (d)+⑥、24h 锚点链、复查通过不加计数、不确定中性事件、子级
// submission_id 幂等），供 notifier 流程断言；写库本身的完整语义
// 由 test/b14_m3_verdict_test.dart 对真实库覆盖。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
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
  CauseStatus status = CauseStatus.pending,
  int solvedCount = 0,
  DateTime? recheckDate,
  DateTime? joinedAt,
  int? lastCountedSuccessAt,
  String? lastCountedSessionId,
}) =>
    CauseRecord(
      questionId: questionId,
      cause: cause,
      subjectId: subjectId,
      status: status,
      solvedCount: solvedCount,
      lastCheck: status == CauseStatus.solved
          ? DateTime(2026, 11, 10)
          : null,
      recheckDate: recheckDate,
      joinedAt: joinedAt ?? DateTime(2026, 11, 10),
      lastCountedSuccessAt: lastCountedSuccessAt,
      lastCountedSessionId: lastCountedSessionId,
    );

/// Fake 写库时记下的 verdict 事件（(d) 同会话重复检查与恢复校验用）。
class FakeHistoryEvent {
  FakeHistoryEvent({
    required this.stableId,
    required this.sessionId,
    required this.verdict,
  });

  final String stableId;
  final String sessionId;
  final String verdict;
}

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
  final List<FakeHistoryEvent> historyEvents = [];
  final Map<String, AttemptData> attempts = {};
  final Map<String, VerdictSubmitResult> submissionResults = {};
  var _nextHistoryId = 0;
  var submitVerdictCalls = 0;

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);

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
  Future<VerdictSubmitResult> submitCauseVerdict({
    required String questionId,
    required CauseRecord record,
    required String verdict,
    required String verificationStatus,
    required String verificationSource,
    String? attemptId,
    required String sessionId,
    required String submissionId,
    int cureChecks = 2,
    int recheckIntervalDays = 7,
    bool isRecheck = false,
    DateTime? now,
  }) async {
    submitVerdictCalls++;
    if (throwOnCheck) throw StateError('save failed');
    final currentNow = now ?? DateTime.now();
    // 幂等：同一子级 submission_id 重试返回已有结果，不写新事件。
    final seen = submissionResults[submissionId];
    if (seen != null) {
      return VerdictSubmitResult(
        record: seen.record,
        counted: seen.counted,
        alreadySubmitted: true,
        historyId: seen.historyId,
        cured: seen.cured,
        isRecheckPassed: seen.isRecheckPassed,
        isRecheckFailed: seen.isRecheckFailed,
      );
    }
    final i = records.indexWhere(
        (x) => x.questionId == questionId && x.cause == record.cause);
    if (i < 0) throw CauseRecordMissingException(questionId, record.cause);
    final current = records[i];
    final verified = verificationStatus == '已核验';
    var updated = current;
    var counted = false;
    var cured = false;
    var recheckPassed = false;
    var recheckFailed = false;
    final stableId = causeStableId(current);
    final today = DateTime(
        currentNow.year, currentNow.month, currentNow.day);
    if (verdict == '不确定') {
      // 中性事件：只记 history，不改记录、不刷新锚点。
    } else if (verdict == '未解决') {
      updated = unsolvedReset(current, currentNow);
      if (isRecheck) recheckFailed = true;
    } else if (verdict == '已解决' && verified) {
      // (d) 同会话重复检查：同一会话已有“已解决”事件（包括未核验的）
      // → 本次不计入、不刷新锚点。
      final sameSessionSolved = historyEvents.any((e) =>
          e.stableId == stableId &&
          e.sessionId == sessionId &&
          e.verdict == '已解决');
      if (!sameSessionSolved) {
        // ⑥ 锚点链：首次计入，或不同会话且距上次已计入成功 ≥ 24h。
        final anchorOk = current.lastCountedSuccessAt == null ||
            (sessionId != current.lastCountedSessionId &&
                currentNow.millisecondsSinceEpoch -
                        current.lastCountedSuccessAt! >=
                    cureMinIntervalMs);
        if (anchorOk) {
          if (isRecheck) {
            // 复查通过不增加初次治愈次数，只推复查日。
            recheckPassed = true;
            updated = current.copyWith(
              lastCheck: currentNow,
              recheckDate:
                  today.add(Duration(days: recheckIntervalDays)),
            );
          } else {
            counted = true;
            final count = current.solvedCount + 1;
            if (count >= cureChecks) {
              cured = true;
              updated = current.copyWith(
                status: CauseStatus.solved,
                solvedCount: count,
                lastCheck: currentNow,
                recheckDate:
                    today.add(Duration(days: recheckIntervalDays)),
                lastCountedSuccessAt:
                    currentNow.millisecondsSinceEpoch,
                lastCountedSessionId: sessionId,
              );
            } else {
              updated = current.copyWith(
                status: CauseStatus.inProgress,
                solvedCount: count,
                lastCheck: currentNow,
                clearRecheckDate: true,
                lastCountedSuccessAt:
                    currentNow.millisecondsSinceEpoch,
                lastCountedSessionId: sessionId,
              );
            }
          }
        }
      }
    }
    // 未核验的“已解决”：只记 history，不改记录、不计入。
    records[i] = updated;
    final historyId = ++_nextHistoryId;
    historyEvents.add(FakeHistoryEvent(
      stableId: stableId,
      sessionId: sessionId,
      verdict: verdict,
    ));
    final resultLabel = switch (verdict) {
      '已解决' => 'solved',
      '未解决' => 'unsolved',
      _ => 'unsure',
    };
    (history[questionId] ??= []).add(
      (result: resultLabel, reviewedAt: currentNow),
    );
    final result = VerdictSubmitResult(
      record: updated,
      counted: counted,
      alreadySubmitted: false,
      historyId: historyId,
      cured: cured,
      isRecheckPassed: recheckPassed,
      isRecheckFailed: recheckFailed,
    );
    submissionResults[submissionId] = result;
    return result;
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
  }) async =>
      attempts['$sessionId|$questionId'];

  @override
  Future<List<AttemptData>> loadAttemptsForSession(
          String sessionId) async =>
      attempts.values.where((a) => a.sessionId == sessionId).toList();

  /// M3-10 断点恢复重建用：本会话里该错因是否已有 verdict 事件。
  @override
  Future<bool> hasSessionVerdict({
    required String causeStableId,
    required String sessionId,
  }) async => historyEvents.any(
    (e) => e.stableId == causeStableId && e.sessionId == sessionId,
  );

  @override
  Future<void> rejoinCause({
    required String questionId,
    required String cause,
    required String subjectId,
  }) async {
    final qi = questions.indexWhere((q) => q.id == questionId);
    if (qi >= 0) {
      questions[qi] = questions[qi].copyWith(reviewJoined: true);
    }
    final i = records.indexWhere(
        (x) => x.questionId == questionId && x.cause == cause);
    if (i < 0) {
      records.add(CauseRecord(
        questionId: questionId,
        cause: cause,
        subjectId: subjectId,
        joinedAt: DateTime.now(),
      ));
      return;
    }
    if (records[i].status == CauseStatus.solved) {
      records[i] = unsolvedReset(records[i], DateTime.now());
    }
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
          status: CauseStatus.inProgress,
          solvedCount: 1,
          joinedAt: now.add(const Duration(hours: 1))),
      _rec('q2', '计算错误', joinedAt: now.add(const Duration(hours: 1))),
      _rec('q3', '概念不清',
          subjectId: 'english',
          status: CauseStatus.solved,
          solvedCount: 2,
          recheckDate: DateTime.now().add(const Duration(days: 7)),
          joinedAt: now.subtract(const Duration(hours: 1))),
      _rec('q5', '方法不会', joinedAt: now),
    ],
  );
}

FakeReviewNotifierRepo _singleRepo({int solvedCount = 0}) {
  final repo = _reviewRepo();
  repo.questions = [
    _rq('q1', '函数极限',
        errorTypes: const ['概念不清'],
        createdAt: DateTime(2026, 11, 8),
        reviewJoined: true),
  ];
  repo.records = [
    _rec('q1', '概念不清',
        status: solvedCount > 0 ? CauseStatus.inProgress : CauseStatus.pending,
        solvedCount: solvedCount,
        joinedAt: DateTime(2026, 11, 10),
        // 已有 1 次已计入成功：上次会话距今 25 小时（过 24h 锚点）。
        lastCountedSuccessAt: solvedCount > 0
            ? DateTime.now()
                .subtract(const Duration(hours: 25))
                .millisecondsSinceEpoch
            : null,
        lastCountedSessionId: solvedCount > 0 ? 'sess-old' : null),
  ];
  return repo;
}

FakeReviewNotifierRepo _recheckRepo() {
  final repo = _reviewRepo();
  repo.questions = [
    _rq('q1', '函数极限',
        errorTypes: const ['概念不清'],
        createdAt: DateTime(2026, 11, 8),
        reviewJoined: true),
  ];
  repo.records = [
    _rec('q1', '概念不清',
        status: CauseStatus.solved,
        solvedCount: 2,
        recheckDate: DateTime.now().subtract(const Duration(days: 1)),
        joinedAt: DateTime(2026, 11, 10)),
  ];
  return repo;
}

ProviderContainer _container(
  FakeReviewNotifierRepo repo, {
  String? initialSubjectId,
}) {
  final container = ProviderContainer.test(
    overrides: [
      repositoryProvider.overrideWithValue(repo),
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

/// 走完单错因题的前三段，到自查步（纸上作答：无软件答案，默认走外部
/// 核对勾选；不勾选时为未核验自评）。
Future<void> _walkToSelfCheck(
  ReviewNotifier notifier, {
  String cause = '概念不清',
  String verdict = '已解决',
  bool externalChecked = false,
}) async {
  notifier.beginAnswer();
  await notifier.completePaperAnswer();
  notifier.enterSelfCheck();
  notifier.setVerdict(cause, verdict);
  if (externalChecked) notifier.setExternalChecked(cause, true);
}

/// 双错因题（q2）走完自查：两个错因都选“已解决”+ 外部核对。
Future<void> _walkQ2ToSelfCheck(ReviewNotifier notifier) async {
  notifier.beginAnswer();
  await notifier.completePaperAnswer();
  notifier.enterSelfCheck();
  notifier.setVerdict('方法不会', '已解决');
  notifier.setExternalChecked('方法不会', true);
  notifier.setVerdict('计算错误', '已解决');
  notifier.setExternalChecked('计算错误', true);
}

void main() {
  group('ReviewNotifier load', () {
    test('load()：分组 3 待治 + 1 已治愈，未加入盒只 1 道，元信息 2/0/1', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      final s = container.read(reviewProvider);
      expect(s.loading, isFalse);
      expect(s.loadError, isFalse);
      expect(s.hasLoaded, isTrue);
      expect(s.groups.length, 3);
      expect(s.curedGroups.length, 1);
      expect(s.notJoined.map((q) => q.id), ['q4']);
      expect(s.pendingByQ['q1']?.length, 1);
      expect(s.pendingByQ['q2']?.length, 2);
      expect(s.metaCounts, (2, 0, 1));
      expect(s.resume, isNull);
      expect(s.allCauses, ['概念不清', '计算错误', '方法不会']);
    });

    test('build() 触发首查：只读 state 也能等到加载完成', () async {
      final container = _container(_reviewRepo());
      container.read(reviewProvider);
      await _waitFor(container, (s) => s.hasLoaded);
      expect(container.read(reviewProvider).hasLoaded, isTrue);
      expect(container.read(reviewProvider).groups.length, 3);
    });

    test('初始学科筛选走 reviewInitialProvider：带 english 进来只留英语组',
        () async {
      final container = _container(_reviewRepo(), initialSubjectId: 'english');
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      final s = container.read(reviewProvider);
      expect(s.subjectFilter, 'english');
      expect(s.filtered, isEmpty);
      expect(s.filteredCured.length, 1);
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
      expect(s.groups.length, 3);
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

  group('ReviewNotifier 会话：治愈与自查', () {
    test('五段走完单题（外部核对）：自查 1 次未满 2 次，总结“待解决 → 解决中”，剩余 1',
        () async {
      final repo = _singleRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      var s = container.read(reviewProvider);
      expect(s.inSession, isTrue);
      expect(s.sessionQuestions.length, 1);
      expect(s.sessionTotals, (1, 1));
      expect(s.scopeLabel, '全部待解决错因');
      await _walkToSelfCheck(notifier, externalChecked: true);
      await notifier.finishQuestion();
      await _waitFor(container, (s) => s.showSummary);
      s = container.read(reviewProvider);
      expect(s.showSummary, isTrue);
      expect(s.curedNow, 0);
      expect(s.summaryRemaining, 1);
      expect(s.changes.length, 1);
      expect(s.changes.single.before, '待解决');
      expect(s.changes.single.after, '解决中');
      expect(s.sumUnverified, 0);
      expect(repo.records.single.solvedCount, 1);
      expect(repo.records.single.status, CauseStatus.inProgress);
      // 纸上作答建了一条 attempt（已完成作答，correct=NULL）。
      expect(repo.attempts.length, 1);
      expect(repo.attempts.values.single.status, '已完成作答');
      expect(repo.attempts.values.single.correct, isNull);
    });

    test('自查“已解决”满 2 次算已解决：总结计 1 个已解决', () async {
      final repo = _singleRepo(solvedCount: 1);
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      await _walkToSelfCheck(notifier, externalChecked: true);
      await notifier.finishQuestion();
      await _waitFor(container, (s) => s.showSummary);
      final s = container.read(reviewProvider);
      expect(s.curedNow, 1);
      expect(s.summaryRemaining, 0);
      expect(s.changes.single.after, '已解决');
      expect(s.changes.single.recheckDate, isNotNull);
      expect(s.changes.single.note, contains('已解决，下次复查'));
      expect(repo.records.single.status, CauseStatus.solved);
      expect(repo.records.single.solvedCount, 2);
    });

    test('复查通过不加计数——已满 2 次治愈后复查通过仍为 2', () async {
      final repo = _recheckRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      await _walkToSelfCheck(notifier, externalChecked: true);
      await notifier.finishQuestion();
      await _waitFor(container, (s) => s.showSummary);
      final s = container.read(reviewProvider);
      expect(s.changes.single.note, contains('复查通过'));
      expect(s.sumRecheckPassed, 1);
      expect(repo.records.single.solvedCount, 2);
      expect(repo.records.single.status, CauseStatus.solved);
      expect(repo.records.single.recheckDate, isNotNull);
    });

    test('选“不确定”记中性事件：记录不动，总结留一行说明', () async {
      final repo = _singleRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      await _walkToSelfCheck(notifier, verdict: '不确定');
      await notifier.finishQuestion();
      await _waitFor(container, (s) => s.showSummary);
      final s = container.read(reviewProvider);
      expect(s.curedNow, 0);
      expect(s.changes.single.after, '待解决');
      expect(s.changes.single.note, contains('不确定'));
      expect(repo.records.single.status, CauseStatus.pending);
      expect(repo.records.single.solvedCount, 0);
      // 中性事件写了库（history 有一行），但不改治疗记录。
      expect(repo.historyEvents.length, 1);
      expect(repo.historyEvents.single.verdict, '不确定');
      expect(repo.history['q1']?.length, 1);
    });

    test('未核验自评不推进治愈：不勾选外部核对，次数不动', () async {
      final repo = _singleRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      await _walkToSelfCheck(notifier, externalChecked: false);
      await notifier.finishQuestion();
      await _waitFor(container, (s) => s.showSummary);
      final s = container.read(reviewProvider);
      expect(s.curedNow, 0);
      expect(s.sumUnverified, 1);
      expect(s.changes.single.note, contains('未核验'));
      expect(repo.records.single.status, CauseStatus.pending);
      expect(repo.records.single.solvedCount, 0);
    });

    test('保存失败：自查提交抛错，出 saveError 并留在自查步', () async {
      final repo = _singleRepo()..throwOnCheck = true;
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      await _walkToSelfCheck(notifier, externalChecked: true);
      await notifier.finishQuestion();
      final s = container.read(reviewProvider);
      expect(s.saveError, isTrue);
      expect(s.showSummary, isFalse);
      expect(
        s.currentSessionQuestion.stage,
        SessionStage.selfCheck,
      );
    });

    test('按组开始解决：只治该组的错因', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
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
      expect(s.currentSessionQuestion.causes, ['计算错误']);
      expect(s.scopeLabel, '数学 · 计算错误');
    });

    test('一题多错因：题目只展示一次，两个错因分别提交', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      // q1 走完，到 q2（双错因）。
      await _walkToSelfCheck(notifier, externalChecked: true);
      await notifier.finishQuestion();
      var s = container.read(reviewProvider);
      expect(s.sessionIndex, 1);
      expect(s.currentSessionQuestion.questionId, 'q2');
      expect(s.currentSessionQuestion.causes,
          ['方法不会', '计算错误']);
      await _walkQ2ToSelfCheck(notifier);
      await notifier.finishQuestion();
      await _waitFor(container, (s) => s.showSummary);
      s = container.read(reviewProvider);
      expect(s.showSummary, isTrue);
      expect(s.sumHandled, 3);
      expect(s.changes.length, 3);
      // q2 的两个错因各提交一次，attempt 仍只有两条（一题一条）。
      expect(repo.attempts.length, 2);
      expect(repo.submitVerdictCalls, 3);
    });
  });

  group('ReviewNotifier 会话：跳过与断点', () {
    test('跳过单题队列直接留到下次：不写 verdict，进总结', () async {
      final repo = _singleRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      await notifier.skipCurrent();
      await _waitFor(container, (s) => s.showSummary);
      final s = container.read(reviewProvider);
      expect(s.showSummary, isTrue);
      expect(s.changes, isEmpty);
      expect(s.curedNow, 0);
      expect(s.sumDeferred, 1);
      expect(s.sumSkipped, 1);
      expect(repo.submitVerdictCalls, 0);
      // 只跳过、从未作答的题不建 attempt。
      expect(repo.attempts, isEmpty);
    });

    test('跳过两次留到下次：第一次追加队尾，第二次移出会话', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
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
      expect(repo.submitVerdictCalls, 0);
    });

    test('跳过后重遇恢复原状态：已完成作答的题不重新给答题机会', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      // q1 作答到核对步再跳过 → 队尾，状态保留。
      notifier.beginAnswer();
      await notifier.completePaperAnswer();
      var s = container.read(reviewProvider);
      expect(s.currentSessionQuestion.stage, SessionStage.check);
      await notifier.skipCurrent();
      s = container.read(reviewProvider);
      expect(s.currentSessionQuestion.questionId, 'q2');
      expect(s.sessionQuestions.last.stage, SessionStage.check);
      expect(s.sessionQuestions.last.attemptId, isNotNull);
      // 跳过 q2 → 回到 q1，仍在核对步，attempt 保留。
      await notifier.skipCurrent();
      s = container.read(reviewProvider);
      expect(s.currentSessionQuestion.questionId, 'q1');
      expect(s.currentSessionQuestion.stage, SessionStage.check);
      expect(s.currentSessionQuestion.attemptId, isNotNull);
      // 仍可继续自查，不重新作答。
      notifier.enterSelfCheck();
      expect(
        container.read(reviewProvider).currentSessionQuestion.stage,
        SessionStage.selfCheck,
      );
    });

    test('暂停后断点续治：继续解决回到中断的题', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      // q1 走完，到 q2 再暂停。
      await _walkToSelfCheck(notifier, externalChecked: true);
      await notifier.finishQuestion();
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

    test('崩溃窗口恢复：数据库已写、review_state 未更新时，按 history 重建已提交态', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      // q1 自查已解决 + 外部核对（已核验）→ 提交写库（history 有行）。
      await _walkToSelfCheck(notifier, externalChecked: true);
      await notifier.finishQuestion();
      expect(repo.historyEvents.length, 1);
      await notifier.pauseSession();
      expect(repo.savedState, isNotNull);
      // 模拟崩溃窗口：review_state 没来得及更新——把 perQuestionState
      // 里的已提交标记抹掉（只留队列与位置），history 仍在。
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
            e.key: {...e.value, 'submitted_causes': <String>[]},
        },
      );
      // 真实库里 history 行与 verdict 事件是同一批写入。
      repo.history['q1'] = [(result: 'solved', reviewedAt: DateTime.now())];
      await notifier.load();
      final s = container.read(reviewProvider);
      expect(s.resume, isNotNull);
      final resumed = s.resume!.sessionQuestions.firstWhere(
        (sq) => sq.questionId == 'q1',
      );
      expect(resumed.submittedCauses, contains('概念不清'));
      // 恢复本身不重新提交、不重复计数。
      expect(repo.historyEvents.length, 1);
      expect(
        repo.records
            .firstWhere((r) => r.questionId == 'q1')
            .solvedCount,
        1,
      );
    });

    test('版本变化恢复：未作答的题刷新快照，从看题重新开始', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
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
      await notifier.load();
      await notifier.startSession();
      // q1 纸上作答完成（attempt 已建），停在核对步。
      notifier.beginAnswer();
      await notifier.completePaperAnswer();
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
    test('专项练习不推进治愈、不写正式 verdict', () async {
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
      // 四题都纸上作答 + 下一题走完。
      for (var i = 0; i < 4; i++) {
        notifier.beginAnswer();
        await notifier.completePaperAnswer();
        await notifier.nextPracticeQuestion();
      }
      await _waitFor(container, (s) => s.showSummary);
      s = container.read(reviewProvider);
      expect(s.showSummary, isTrue);
      expect(s.sumCompleted, 4);
      expect(s.curedNow, 0);
      expect(repo.submitVerdictCalls, 0);
      expect(repo.historyEvents, isEmpty);
      // 治疗状态一点没动。
      expect(
        repo.records
            .where((r) => r.questionId == 'q1')
            .single
            .solvedCount,
        0,
      );
      expect(repo.attempts.length, 4);
    });

    test('专项练习重新加入复习：已治愈错因回到解决中', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      notifier.openPracticePicker();
      // 只练英语（q3，已治愈）。
      notifier.setPracticeSubjectFilter('english');
      await notifier.startPracticeSession();
      var s = container.read(reviewProvider);
      expect(s.sessionQuestions.length, 1);
      expect(s.currentSessionQuestion.questionId, 'q3');
      await notifier.rejoinCauseFromPractice('概念不清');
      expect(
        container.read(reviewProvider).rejoinNotice,
        contains('已重新加入复习'),
      );
      final record = repo.records
          .where((r) => r.questionId == 'q3')
          .single;
      expect(record.status, CauseStatus.inProgress);
      expect(record.solvedCount, 0);
      // 本次练习记录不受影响：不写 verdict。
      expect(repo.submitVerdictCalls, 0);
    });
  });
}
