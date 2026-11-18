// 十二批功能 4（D-91）：首页历史——详情加载记录一次查看。
// 覆盖：load() 成功后记一次（且只记一次）；记录抛错时详情照常加载
//（D-88：记录失败绝不能拖垮详情加载）；题不存在时不记；
// 切到另一题（goTo）时记新题。
// 注入方式与 detail_notifier_test.dart 同款：ProviderContainer.test +
// repositoryProvider.overrideWithValue（autoDispose 下持监听保活）。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/detail_notifier.dart';
import 'package:quiz_master2/state/repository_provider.dart';

class _HistoryDetailRepo extends QuestionRepository {
  _HistoryDetailRepo({required this.questions}) : super(AppDatabase.instance);

  List<Question> questions;

  /// 记到的查看（按调用顺序）。
  final List<String> recordedViews = [];

  /// 置真时 recordQuestionViewed 抛错（模拟记录失败）。
  bool recordShouldThrow = false;

  @override
  Future<Question?> questionById(String id) async =>
      questions.where((q) => q.id == id).firstOrNull;

  @override
  Future<List<CauseRecord>> causeRecordsFor(String questionId) async =>
      const [];

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
    String questionId,
  ) async => const [];

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [];

  @override
  Future<List<String>> tags() async => const [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  @override
  Future<void> recordQuestionViewed(String questionId) async {
    if (recordShouldThrow) throw StateError('记录失败（测试桩）');
    recordedViews.add(questionId);
  }
}

Question _dq(String id, String title) => Question(
  id: id,
  title: title,
  subjectId: 'math',
  createdAt: DateTime(2026, 11, 8),
  isOrganized: true,
);

ProviderContainer _container(
  _HistoryDetailRepo repo,
  String questionId, {
  List<String> orderIds = const [],
}) {
  final container = ProviderContainer.test(
    overrides: [
      repositoryProvider.overrideWithValue(repo),
      detailInitialProvider.overrideWithValue(
        DetailInitial(questionId: questionId, orderIds: orderIds),
      ),
    ],
  );
  addTearDown(container.dispose);
  // autoDispose 保活（D-36：只 read 不监听时 build 的 microtask 首查
  // 还没写回就被销毁），见 detail_notifier_test.dart。
  container.listen(detailProvider, (_, __) {});
  return container;
}

void main() {
  group('DetailNotifier.load() 记录一次查看', () {
    test('load() 成功后记一次该题', () async {
      final repo = _HistoryDetailRepo(questions: [_dq('q1', '函数极限')]);
      final container = _container(repo, 'q1');
      await container.read(detailProvider.notifier).load();
      expect(container.read(detailProvider).question?.id, 'q1');
      expect(repo.recordedViews, ['q1']);
    });

    test('记录抛错时详情照常加载完成（loading false、题在）', () async {
      final repo = _HistoryDetailRepo(questions: [_dq('q1', '函数极限')])
        ..recordShouldThrow = true;
      final container = _container(repo, 'q1');
      await container.read(detailProvider.notifier).load();
      final state = container.read(detailProvider);
      expect(state.loading, isFalse);
      expect(state.question?.id, 'q1');
      expect(repo.recordedViews, isEmpty);
    });

    test('题不存在时不记', () async {
      final repo = _HistoryDetailRepo(questions: [_dq('q1', '函数极限')]);
      final container = _container(repo, 'q-missing');
      await container.read(detailProvider.notifier).load();
      expect(container.read(detailProvider).question, isNull);
      expect(repo.recordedViews, isEmpty);
    });

    test('goTo 另一题时记新题（load() 每次成功都记）', () async {
      final repo = _HistoryDetailRepo(
        questions: [_dq('q1', '函数极限'), _dq('q2', '定积分')],
      );
      final container = _container(
        repo,
        'q1',
        orderIds: const ['q1', 'q2'],
      );
      await container.read(detailProvider.notifier).load();
      expect(repo.recordedViews, ['q1']);
      await container.read(detailProvider.notifier).goTo('q2');
      expect(container.read(detailProvider).question?.id, 'q2');
      expect(repo.recordedViews, ['q1', 'q2']);
    });
  });
}
