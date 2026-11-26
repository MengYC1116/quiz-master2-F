// FR-02 时序回归：save 先发角标事件、syncCauseRecords 后写库时，
// 复习角标重读可能抢在同步提交前（错因同步改变题目复习归属时角标
// 滞后一次）。修法：三处调用点（organize saveCurrent / confirmCurrent、
// detail saveEdit）用 DataChangeBus.instance.scope() 包起来，事件在
// 同步提交后才合并发出一次（与 joinReviewBatch 同款）。
//
// FakeRepo 模拟真实写路径的时序：save() 写库后立即发含 badges 的
// 事件（与 db_questions.upsertQuestion 同款）；syncCauseRecords()
// 改变题的复习归属（全解决的题改出一个新错因 → 重新计入“要复习”）。
// 断言：监听方收到事件那一刻，归属已是同步后的新状态；修法前（无
// scope）事件在 save 时立即发出，归属还是同步前的旧状态，测试失败。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/data_change_events.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/detail_notifier.dart';
import 'package:quiz_master2/state/organize_notifier.dart';
import 'package:quiz_master2/state/repository_provider.dart';

Question _q(String id, {bool isOrganized = false}) => Question(
  id: id,
  title: '题 $id',
  subjectId: 'math',
  createdAt: DateTime(2026, 11, 8),
  isOrganized: isOrganized,
  sliceKind: 'material',
  sliceText: '题',
);

/// 模拟真实写路径时序的 FakeRepo：save 立即发事件，sync 改归属。
class TimingFakeRepo extends QuestionRepository {
  TimingFakeRepo() : super(AppDatabase.instance);

  List<Question> questions = [_q('q1')];

  /// 题目是否计入“要复习”（角标/首页数的读侧口径简化版）。
  final Map<String, bool> reviewMembership = {'q1': false};

  int syncCauseRecordsCalls = 0;
  int saveRecentTaskCalls = 0;

  @override
  Future<List<Subject>> subjects() async => List.of(Subject.all);

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [
    Folder(id: 'f1', name: '试卷', subjectId: 'math'),
  ];

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<List<String>> tags() async => const [];

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
  Future<void> save(Question question, {SaveToken? token}) async {
    final i = questions.indexWhere((x) => x.id == question.id);
    if (i >= 0) {
      questions[i] = question;
    } else {
      questions.add(question);
    }
    // 与真实 upsertQuestion 同款：写库成功后立即发含 badges 的事件。
    DataChangeBus.instance.emit(
      const DataChangeEvent(
        kinds: {DataChangeKind.badges, DataChangeKind.questions},
      ),
    );
  }

  @override
  Future<void> syncCauseRecords(Question question) async {
    syncCauseRecordsCalls++;
    // 模拟错因同步改变归属：全解决的题改出一个新错因，重新计入要复习。
    reviewMembership[question.id] = true;
  }

  @override
  Future<void> saveRecentTask({
    required String kind,
    required String subjectId,
    required String title,
  }) async {
    saveRecentTaskCalls++;
  }

  @override
  Future<int> organizedTodayCount({DateTime? now}) async => 0;

  /// 十二批功能 4（D-91）：记一次查看的桩（不碰真实库；detail 用例
  /// 调 DetailNotifier.load，不覆盖会落到基类读真实 Drift 库，
  /// fake async 里永不完成，见 D-88）。
  @override
  Future<void> recordQuestionViewed(String questionId) async {}

  /// FR-09：详情 load() 读复查间隔（默认 7 天），不碰真实库（见 D-88）。
  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  /// 十三批 M5：OCR 状态是 best-effort 加载（不 await）；返回空任务行
  /// 与“无 key”，不碰真实库（见 D-88）。
  @override
  Future<List<OcrJob>> ocrJobsForQuestion(String questionId) async =>
      const [];

  @override
  Future<bool> hasOcrApiKey() async => false;
}

void main() {
  group('FR-02 角标事件在错因同步提交后才发出', () {
    test('organize saveCurrent：事件发出时归属已是同步后的新状态', () async {
      final repo = TimingFakeRepo();
      final container = ProviderContainer.test(
        overrides: [repositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
      container.listen(organizeProvider, (_, __) {});
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      expect(container.read(organizeProvider).current?.id, 'q1');
      expect(repo.reviewMembership['q1'], isFalse);

      final seenAtEvent = <Map<String, bool>>[];
      final sub = DataChangeBus.instance.stream.listen((_) {
        seenAtEvent.add(Map.of(repo.reviewMembership));
      });
      addTearDown(sub.cancel);
      final ok = await notifier.saveCurrent(
        answer: '',
        explanation: '',
        notes: '',
      );
      expect(ok, isTrue);
      // broadcast 流异步投递：等一个 microtask 再断言。
      await Future<void>.delayed(Duration.zero);
      expect(repo.syncCauseRecordsCalls, 1);
      expect(seenAtEvent, isNotEmpty);
      // 关键断言：事件发出那一刻，同步已提交、归属已是新状态。
      expect(seenAtEvent.first['q1'], isTrue);
    });

    test('organize confirmCurrent：save+同步+记最近任务同一事件，发出时同步已提交', () async {
      final repo = TimingFakeRepo();
      final container = ProviderContainer.test(
        overrides: [repositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
      container.listen(organizeProvider, (_, __) {});
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();

      final seenAtEvent = <Map<String, bool>>[];
      final sub = DataChangeBus.instance.stream.listen((_) {
        seenAtEvent.add(Map.of(repo.reviewMembership));
      });
      addTearDown(sub.cancel);
      await notifier.confirmCurrent(answer: '', explanation: '', notes: '');
      await Future<void>.delayed(Duration.zero);
      expect(repo.syncCauseRecordsCalls, 1);
      expect(repo.saveRecentTaskCalls, 1);
      expect(seenAtEvent, isNotEmpty);
      expect(seenAtEvent.first['q1'], isTrue);
    });

    test('detail saveEdit：事件发出时归属已是同步后的新状态', () async {
      final repo = TimingFakeRepo();
      repo.questions = [_q('q1', isOrganized: true)];
      final container = ProviderContainer.test(
        overrides: [
          repositoryProvider.overrideWithValue(repo),
          detailInitialProvider.overrideWithValue(
            const DetailInitial(questionId: 'q1', orderIds: ['q1']),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(detailProvider, (_, __) {});
      final notifier = container.read(detailProvider.notifier);
      await notifier.load();
      expect(container.read(detailProvider).question?.id, 'q1');
      notifier.enterEdit();

      final seenAtEvent = <Map<String, bool>>[];
      final sub = DataChangeBus.instance.stream.listen((_) {
        seenAtEvent.add(Map.of(repo.reviewMembership));
      });
      addTearDown(sub.cancel);
      await notifier.saveEdit(
        title: '题 q1',
        answer: '',
        explanation: '',
        notes: '',
      );
      await Future<void>.delayed(Duration.zero);
      expect(repo.syncCauseRecordsCalls, 1);
      expect(seenAtEvent, isNotEmpty);
      expect(seenAtEvent.first['q1'], isTrue);
    });
  });
}
