// ARCH-PLAN-A 第 3 阶段：ReviewNotifier 单测（不启动 widget）。
// 注入方式与 settings_controller_test.dart / home_provider_test.dart
// 一致：ProviderContainer.test + repositoryProvider.overrideWithValue。
// autoDispose 下单测要像页面 ref.watch 那样持一个监听保活
// （D-36：只 read 不监听时 build 里的 microtask 首查还没写回就被
// 销毁，轮询等不到 hasLoaded），见 `_container`。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
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
  Future<void> saveReviewState(
          {required List<ReviewQueueItem> queue, required int position}) async =>
      savedState = ReviewSessionState(
        queue: queue,
        position: position,
        updatedAt: DateTime.now(),
      );

  @override
  Future<void> clearReviewState() async {
    savedState = null;
  }

  @override
  Future<CauseRecord> recordSelfCheck(
    CauseRecord r,
    String result, {
    int cureChecks = 2,
    int recheckIntervalDays = 7,
    bool isRecheck = false,
  }) async {
    if (throwOnCheck) throw StateError('save failed');
    if (result == 'unsure') return r;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    late CauseRecord updated;
    if (result == 'solved') {
      final count = isRecheck ? r.solvedCount : r.solvedCount + 1;
      if (isRecheck || count >= cureChecks) {
        updated = r.copyWith(
          status: CauseStatus.solved,
          solvedCount: count,
          lastCheck: now,
          recheckDate: today.add(Duration(days: recheckIntervalDays)),
        );
      } else {
        updated = r.copyWith(
          status: CauseStatus.inProgress,
          solvedCount: count,
          lastCheck: now,
          clearRecheckDate: true,
        );
      }
    } else {
      updated = r.copyWith(
        status: CauseStatus.inProgress,
        solvedCount: 0,
        lastCheck: now,
        clearRecheckDate: true,
      );
    }
    final i = records.indexWhere(
        (x) => x.questionId == r.questionId && x.cause == r.cause);
    if (i >= 0) records[i] = updated;
    return updated;
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
        joinedAt: DateTime(2026, 11, 10)),
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

/// 走完单错因题的前三步，到自查步（单题库用）。
Future<void> _walkToCheck(
  ReviewNotifier notifier, {
  String cause = '概念不清',
}) async {
  notifier.setPhase(ReviewPhase.remedy);
  await notifier.nextFromRemedy('先看清题目问的是什么');
  notifier.setAnswerShown(true);
  notifier.enterCheck();
  notifier.setCheck(cause, '已解决');
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
    test('四步走完单题：自查 1 次未满 2 次，总结“待解决 → 解决中”，剩余 1', () async {
      final repo = _singleRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      var s = container.read(reviewProvider);
      expect(s.inSession, isTrue);
      expect(s.blocks.length, 1);
      expect(s.scopeLabel, '全部待解决错因');
      await _walkToCheck(notifier);
      await notifier.finishQuestion();
      await _waitFor(container, (s) => s.showSummary);
      s = container.read(reviewProvider);
      expect(s.showSummary, isTrue);
      expect(s.curedNow, 0);
      expect(s.summaryRemaining, 1);
      expect(s.changes.length, 1);
      expect(s.changes.single.before, '待解决');
      expect(s.changes.single.after, '解决中');
      expect(repo.records.single.solvedCount, 1);
      expect(repo.records.single.status, CauseStatus.inProgress);
    });

    test('自查“已解决”满 2 次算已解决：总结计 1 个已解决', () async {
      final repo = _singleRepo(solvedCount: 1);
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      await _walkToCheck(notifier);
      await notifier.finishQuestion();
      await _waitFor(container, (s) => s.showSummary);
      final s = container.read(reviewProvider);
      expect(s.curedNow, 1);
      expect(s.summaryRemaining, 0);
      expect(s.changes.single.after, '已解决');
      expect(s.changes.single.recheckDate, isNotNull);
      expect(repo.records.single.status, CauseStatus.solved);
      expect(repo.records.single.solvedCount, 2);
    });

    test('待定1：复查通过不加计数——已满 2 次治愈后复查通过仍为 2', () async {
      final repo = _recheckRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      await _walkToCheck(notifier);
      await notifier.finishQuestion();
      await _waitFor(container, (s) => s.showSummary);
      final s = container.read(reviewProvider);
      expect(s.changes.single.note, contains('复查通过'));
      expect(repo.records.single.solvedCount, 2);
      expect(repo.records.single.status, CauseStatus.solved);
      expect(repo.records.single.recheckDate, isNotNull);
    });

    test('选“不确定”不算：记录不动，总结留一行说明', () async {
      final repo = _singleRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      notifier.setPhase(ReviewPhase.remedy);
      await notifier.nextFromRemedy('补一补');
      notifier.enterCheck();
      notifier.setCheck('概念不清', '不确定');
      await notifier.finishQuestion();
      await _waitFor(container, (s) => s.showSummary);
      final s = container.read(reviewProvider);
      expect(s.curedNow, 0);
      expect(s.changes.single.after, '待解决');
      expect(s.changes.single.note, contains('不确定'));
      expect(repo.records.single.status, CauseStatus.pending);
      expect(repo.records.single.solvedCount, 0);
    });

    test('保存失败：自查提交抛错，出 saveError 并留在自查步', () async {
      final repo = _singleRepo()..throwOnCheck = true;
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      await _walkToCheck(notifier);
      await notifier.finishQuestion();
      final s = container.read(reviewProvider);
      expect(s.saveError, isTrue);
      expect(s.showSummary, isFalse);
      expect(s.phase, ReviewPhase.check);
    });

    test('按组开始解决：只治该组的错因（SR-P2-49 决定 (b)）', () async {
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
      expect(s.blocks.length, 1);
      expect(s.blocks.single.questionId, 'q2');
      expect(s.blocks.single.causes, ['计算错误']);
      expect(s.scopeLabel, '数学 · 计算错误');
    });
  });

  group('ReviewNotifier 会话：跳过与断点', () {
    test('跳过两次留到下次：第一次追加队尾，第二次出总结、无自查记录', () async {
      final repo = _singleRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      notifier.skipCurrent();
      var s = container.read(reviewProvider);
      expect(s.blocks.length, 1);
      expect(s.bi, 0);
      expect(s.phase, ReviewPhase.recall);
      notifier.skipCurrent();
      await _waitFor(container, (s) => s.showSummary);
      s = container.read(reviewProvider);
      expect(s.showSummary, isTrue);
      expect(s.changes, isEmpty);
      expect(s.curedNow, 0);
    });

    test('SR-P1-13：跳过双错因题的最后一个错因，直接进重做', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      // q1 单错因走完，到 q2（双错因）。
      await _walkToCheck(notifier);
      await notifier.finishQuestion();
      var s = container.read(reviewProvider);
      expect(s.bi, 1);
      expect(s.currentCause, '方法不会');
      notifier.setPhase(ReviewPhase.remedy);
      await notifier.nextFromRemedy('补方法不会');
      s = container.read(reviewProvider);
      expect(s.ci, 1);
      expect(s.currentCause, '计算错误');
      notifier.skipCurrent();
      s = container.read(reviewProvider);
      expect(s.phase, ReviewPhase.redo);
      expect(s.currentCause, '方法不会');
    });

    test('暂停后断点续治：继续解决回到中断的错因', () async {
      final repo = _reviewRepo();
      final container = _container(repo);
      final notifier = container.read(reviewProvider.notifier);
      await notifier.load();
      await notifier.startSession();
      // 走到 q2 的第 2 个错因再暂停。
      await _walkToCheck(notifier);
      await notifier.finishQuestion();
      notifier.setPhase(ReviewPhase.remedy);
      await notifier.nextFromRemedy('补方法不会');
      await notifier.pauseSession();
      var s = container.read(reviewProvider);
      expect(s.inSession, isFalse);
      expect(repo.savedState, isNotNull);
      expect(s.resume, isNotNull);
      expect(s.resume!.blockIndex, 1);
      expect(s.resume!.causeIndex, 1);
      await notifier.startSession(resume: true);
      s = container.read(reviewProvider);
      expect(s.inSession, isTrue);
      expect(s.bi, 1);
      expect(s.ci, 1);
      expect(s.currentCause, '计算错误');
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
      expect(repo.savedState, isNull);
      expect(s.resume, isNull);
      expect(s.inSession, isTrue);
      expect(s.bi, 0);
      expect(s.ci, 0);
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
    });
  });
}
