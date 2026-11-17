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
import 'package:quiz_master2/data/repository.dart';
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

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      [_fakeQuestion];

  @override
  Future<Map<String, int>> homeRevCounts() async => {};

  @override
  Future<Map<String, int>> pendingOrganizeBySubject() async => {};

  @override
  Future<({String kind, String subjectId, String title})?> recentTask() async =>
      null;

  @override
  Future<List<Question>> dueToday({bool includeArchived = false}) async => [];

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
