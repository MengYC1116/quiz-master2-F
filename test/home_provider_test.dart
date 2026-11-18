// ARCH-PLAN-A 第 2 阶段 A 路：HomeNotifier 单测（不启动 widget）。
// 注入方式与 settings_controller_test.dart 一致：ProviderContainer.test
// + repositoryProvider.overrideWithValue(FakeRepo)。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/exam_event.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/home_provider.dart';
import 'package:quiz_master2/state/repository_provider.dart';

/// 与 home_page_test.dart 的 FakeRepo 同口径（rev/pending/due/records/
/// recent/subjects/考试事件均可配），只覆盖读方法，不碰真实数据库。
class FakeHomeRepo extends QuestionRepository {
  FakeHomeRepo() : super(AppDatabase.instance);

  Map<String, int> rev = {'math': 2, 'english': 1, 'politics': 0};
  Map<String, int> pending = {'math': 1, 'english': 2, 'politics': 0};
  List<Question> due = [
    Question(
      id: 'q-m1',
      title: '函数极限',
      subjectId: 'math',
      isOrganized: true,
      reviewJoined: true,
      createdAt: DateTime(2026, 11, 10),
    ),
    Question(
      id: 'q-m2',
      title: '定积分',
      subjectId: 'math',
      isOrganized: true,
      reviewJoined: true,
      createdAt: DateTime(2026, 11, 10),
    ),
    Question(
      id: 'q-e1',
      title: '阅读理解',
      subjectId: 'english',
      isOrganized: true,
      reviewJoined: true,
      createdAt: DateTime(2026, 11, 10),
    ),
  ];
  List<CauseRecord> records = [
    CauseRecord(
      questionId: 'q-m1',
      cause: '概念不清',
      subjectId: 'math',
      status: CauseStatus.pending,
      joinedAt: DateTime(2026, 11, 10),
    ),
    CauseRecord(
      questionId: 'q-m2',
      cause: '概念不清',
      subjectId: 'math',
      status: CauseStatus.solved,
      solvedCount: 2,
      recheckDate: DateTime.now().subtract(const Duration(days: 1)),
      joinedAt: DateTime(2026, 11, 10),
    ),
    CauseRecord(
      questionId: 'q-e1',
      cause: '审题失误',
      subjectId: 'english',
      status: CauseStatus.pending,
      joinedAt: DateTime(2026, 11, 10),
    ),
  ];
  ({String kind, String subjectId, String title})? recent = (
    kind: '整理',
    subjectId: 'math',
    title: '函数极限',
  );
  List<Subject> subjectsList = Subject.all;
  List<ExamEvent> examEventsList = const [];
  bool throwOnLoad = false;

  @override
  Future<List<Subject>> subjects() async => subjectsList;

  @override
  Future<Map<String, int>> homeRevCounts() async {
    if (throwOnLoad) throw StateError('boom');
    return rev;
  }

  @override
  Future<Map<String, int>> pendingOrganizeBySubject() async => pending;

  @override
  Future<({String kind, String subjectId, String title})?> recentTask() async =>
      recent;

  @override
  Future<List<Question>> dueToday({bool includeArchived = false}) async => due;

  @override
  Future<List<CauseRecord>> causeRecords() async => records;

  @override
  Future<List<ExamEvent>> examEvents() async => examEventsList;

  /// 十二批功能 4（D-91）：最近查看列表（默认空；不覆盖会走到真实库，
  /// fake async 里永不完成，见 D-88）。
  @override
  Future<List<({Question question, DateTime viewedAt})>>
  recentlyViewedQuestions() async => const [];
}

ProviderContainer _container(FakeHomeRepo repo) {
  final container = ProviderContainer.test(
    overrides: [repositoryProvider.overrideWithValue(repo)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('HomeNotifier', () {
    test('load()：总数 3 = 待解决 2 + 复查 1，学科格与最近任务齐全', () async {
      final container = _container(FakeHomeRepo());
      final notifier = container.read(homeProvider.notifier);
      await notifier.load();
      final s = container.read(homeProvider);
      expect(s.loading, isFalse);
      expect(s.loadError, isFalse);
      expect(s.hasLoaded, isTrue);
      expect(s.totalDue, 3);
      expect(s.duePending, 2);
      expect(s.dueRecheck, 1);
      expect(s.revCounts, {'math': 2, 'english': 1, 'politics': 0});
      expect(s.pendingCounts, {'math': 1, 'english': 2, 'politics': 0});
      expect(s.subjects.length, 3);
      expect(s.recent?.title, '函数极限');
      expect(s.nearestExam, isNull);
    });

    test('build() 触发首查：只读 state 也能等到加载完成', () async {
      final container = _container(FakeHomeRepo());
      // autoDispose 的 Provider 无监听者时会被销毁：像页面 ref.watch 那样
      // 持一个监听保活，否则 build 里的 microtask 首查还没写回就被丢掉。
      container.listen(homeProvider, (_, __) {});
      // 只读 state，不调 load()：build 里的 microtask 会自己读库。
      container.read(homeProvider);
      for (var i = 0; i < 100 && !container.read(homeProvider).hasLoaded; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(container.read(homeProvider).hasLoaded, isTrue);
      expect(container.read(homeProvider).totalDue, 3);
    });

    test('最近考试：多场取最近一场，无考试为 null', () async {
      final repo = FakeHomeRepo()
        ..examEventsList = [
          ExamEvent(
            id: 'e-far',
            name: '期末',
            date: DateTime.now().add(const Duration(days: 30)),
          ),
          ExamEvent(
            id: 'e-near',
            name: '期中',
            date: DateTime.now().add(const Duration(days: 5)),
          ),
        ];
      final container = _container(repo);
      await container.read(homeProvider.notifier).load();
      expect(container.read(homeProvider).nearestExam?.id, 'e-near');
    });

    test('无要复习：总数 0，焦点卡走空状态口径', () async {
      final repo = FakeHomeRepo()
        ..due = []
        ..records = []
        ..rev = {'math': 0, 'english': 0, 'politics': 0}
        ..recent = null;
      final container = _container(repo);
      await container.read(homeProvider.notifier).load();
      final s = container.read(homeProvider);
      expect(s.totalDue, 0);
      expect(s.duePending, 0);
      expect(s.dueRecheck, 0);
      expect(s.recent, isNull);
      expect(s.hasLoaded, isTrue);
    });

    test('读库失败：loadError，hasLoaded false；retry 成功后恢复', () async {
      final repo = FakeHomeRepo()..throwOnLoad = true;
      final container = _container(repo);
      final notifier = container.read(homeProvider.notifier);
      await notifier.load();
      var s = container.read(homeProvider);
      expect(s.loading, isFalse);
      expect(s.loadError, isTrue);
      expect(s.hasLoaded, isFalse);
      repo.throwOnLoad = false;
      await notifier.retry();
      s = container.read(homeProvider);
      expect(s.loadError, isFalse);
      expect(s.hasLoaded, isTrue);
      expect(s.totalDue, 3);
    });

    test('SR-P2-48：失败后留住旧内容，retry 失败仍在、成功后恢复', () async {
      final repo = FakeHomeRepo();
      final container = _container(repo);
      final notifier = container.read(homeProvider.notifier);
      await notifier.load();
      expect(container.read(homeProvider).totalDue, 3);
      repo.throwOnLoad = true;
      await notifier.retry();
      var s = container.read(homeProvider);
      expect(s.loadError, isTrue);
      expect(s.hasLoaded, isTrue);
      expect(s.totalDue, 3);
      expect(s.revCounts['math'], 2);
      repo.throwOnLoad = false;
      await notifier.retry();
      s = container.read(homeProvider);
      expect(s.loadError, isFalse);
      expect(s.totalDue, 3);
    });
  });
}
