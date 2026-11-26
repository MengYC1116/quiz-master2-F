// FR-19 回归测试：其余 5 个页 Provider（home/collect/organize/report/
// subjects）补 `dependencies: [repositoryProvider]`（D-49 同款）。
// 触发形态与 detail_push_scope_regression_test.dart 相同——
// “根 ProviderScope + Navigator.push 进嵌套 ProviderScope”：
// 未声明 dependencies 时 Notifier 挂到根容器，build() 里
// ref.read(repositoryProvider) 读到根默认值（真实单例库），嵌套
// override 的 FakeRepo 被静默无视；声明后读到 FakeRepo。
// 判别信号：FakeRepo 只返回一个“假学科 / 假题”，真实库（测试隔离的
// 临时空库）里没有它——读到即证明 override 生效。
// 用 FakeRepo，不碰真实库（D-45：repo 调用直接 await，不用 runAsync）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/p4_new_release.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/exam_event.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/collect_notifier.dart';
import 'package:quiz_master2/state/home_provider.dart';
import 'package:quiz_master2/state/organize_notifier.dart';
import 'package:quiz_master2/state/report_provider.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/state/subjects_notifier.dart';

final _fakeSubject = Subject(
  id: 'fake-subj',
  name: '假学科',
  color: const Color(0xFF123456),
  icon: '假',
);

final _fakeQuestion = Question(
  id: 'q-fake',
  title: '假题',
  subjectId: 'fake-subj',
  createdAt: DateTime(2026, 11, 10),
  isOrganized: false,
);

class Fr19FakeRepo extends QuestionRepository {
  Fr19FakeRepo() : super(AppDatabase.instance);

  @override
  Future<List<Subject>> subjects() async => [_fakeSubject];

  /// 2026-11-25 口径迁移 §2.1：homeProvider.load() 在 Future.wait 里读
  /// fsrsDueCountsBySubject，随后调 previewNewRelease() 取今日新题数。
  /// 不覆写会走真调度器 + 真库、load() 永不完成、首页 subjects 为空、
  /// 找不到「假学科」（同款 home_page_test.dart /
  /// b12_history_home_test.dart、b8_1 补丁 79edabd）。
  @override
  Future<Map<String, int>> fsrsDueCountsBySubject({
    required ReviewScheduler scheduler,
    DateTime? now,
  }) async => const {};

  @override
  Future<FsrsReleasePlan> previewNewRelease({
    required ReviewScheduler scheduler,
    required int dailyNewLimit,
    DateTime? now,
  }) async => FsrsReleasePlan(
    todaysNewIds: const [],
    newlyReleasableIds: const [],
    carryoverIds: const [],
    presentedTodayIds: const [],
    waitingIds: const [],
    presentedTodayCount: 0,
    pendingBacklogCount: 0,
    dailyLimit: dailyNewLimit,
    releaseAllowance: 0,
  );

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      [_fakeQuestion];

  @override
  Future<Map<String, int>> pendingOrganizeBySubject() async => {};

  @override
  Future<({String kind, String subjectId, String title})?> recentTask() async =>
      null;

  @override
  Future<List<CauseRecord>> causeRecords() async => [];

  @override
  Future<List<ExamEvent>> examEvents() async => [];

  @override
  Future<List<CollectTask>> collectTasks() async => [];

  @override
  Future<List<QuestionBox>> boxesForTask(String taskId) async => [];

  @override
  Future<List<Exam>> exams() async => [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => [];

  @override
  Future<List<String>> tags() async => [];

  @override
  Future<List<Folder>> folders({String? subjectId}) async => [];

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
    String qid,
  ) async => [];

  /// P3 入口 3：报告页读全部 attempts 与池内题 id（WeakSampleStats /
  /// 行内“已在复习”标记）。不覆写会落到基类读真实 Drift 库，fake async
  /// 里永不完成、load() 卡住（见 D-88）；其他 Fake 同款覆写
  ///（report_page_test / report_provider_test）。
  @override
  Future<List<AttemptData>> loadAllAttempts() async => const [];

  @override
  Future<Set<String>> fsrsPoolQuestionIds() async => const {};

  /// 十二批功能 4（D-91）：最近查看列表（默认空；home 用例会走
  /// HomeNotifier.load，不覆盖会落到真实库、fake async 里永不完成，
  /// 见 D-88）。
  @override
  Future<List<({Question question, DateTime viewedAt})>>
  recentlyViewedQuestions() async => const [];

  /// B11-10：OrganizeNotifier 只在队列已空且库里有题时读今日已整理
  /// 数（今日小结行用）；返回 0，不碰真实库（见 D-88）。
  @override
  Future<int> organizedTodayCount({DateTime? now}) async => 0;

  /// 十三批 M5：OCR 状态是 best-effort 加载（不 await）；返回空任务行
  /// 与“无 key”，不碰真实库（见 D-88）。
  @override
  Future<List<OcrJob>> ocrJobsForQuestion(String questionId) async =>
      const [];

  @override
  Future<bool> hasOcrApiKey() async => false;
}

/// 根 Scope + push：点按钮进嵌套 ProviderScope 包裹的路由，路由内
/// Consumer watch 对应 Provider 并把判别信号画成文字。
Future<void> _pumpPushed(
  WidgetTester tester,
  Widget Function(BuildContext context) pushedBody,
) async {
  final repo = Fr19FakeRepo();
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ProviderScope(
                        overrides: [
                          repositoryProvider.overrideWithValue(repo),
                        ],
                        child: Scaffold(body: pushedBody(context)),
                      ),
                    ),
                  );
                },
                child: const Text('进页'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('进页'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('home：根 Scope + push 后读到 FakeRepo 的假学科', (tester) async {
    await _pumpPushed(
      tester,
      (_) => Consumer(
        builder: (context, ref, __) {
          final st = ref.watch(homeProvider);
          return Text(st.subjects.map((s) => s.name).join(','));
        },
      ),
    );
    expect(find.text('假学科'), findsOneWidget);
  });

  testWidgets('collect：根 Scope + push 后读到 FakeRepo 的任务列表', (tester) async {
    await _pumpPushed(
      tester,
      (_) => Consumer(
        builder: (context, ref, __) {
          final st = ref.watch(collectProvider);
          return Text(st.subjects.map((s) => s.name).join(','));
        },
      ),
    );
    expect(find.text('假学科'), findsOneWidget);
  });

  testWidgets('organize：根 Scope + push 后队列里有 FakeRepo 的假题', (tester) async {
    await _pumpPushed(
      tester,
      (_) => Consumer(
        builder: (context, ref, __) {
          final st = ref.watch(organizeProvider);
          return Text(st.queue.map((q) => q.title).join(','));
        },
      ),
    );
    expect(find.text('假题'), findsOneWidget);
  });

  testWidgets('report：根 Scope + push 后读到 FakeRepo 的假学科与假题', (tester) async {
    await _pumpPushed(
      tester,
      (_) => Consumer(
        builder: (context, ref, __) {
          final st = ref.watch(reportProvider);
          return Text(
            '${st.subjects.map((s) => s.name).join(',')}/'
            '${st.questions.map((q) => q.title).join(',')}',
          );
        },
      ),
    );
    expect(find.text('假学科/假题'), findsOneWidget);
  });

  testWidgets('subjects：根 Scope + push 后读到 FakeRepo 的假学科', (tester) async {
    await _pumpPushed(
      tester,
      (_) => Consumer(
        builder: (context, ref, __) {
          final st = ref.watch(subjectsProvider);
          return Text(st.subjects.map((s) => s.name).join(','));
        },
      ),
    );
    expect(find.text('假学科'), findsOneWidget);
  });
}
