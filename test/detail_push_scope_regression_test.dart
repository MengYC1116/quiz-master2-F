// 回归测试：详情页“这道题不存在了”（2026-11-17 诊断，见诊断报告）。
// 根因是 Riverpod 3.x 的传递 override 挂载规则：手写 NotifierProvider
// 未声明 dependencies 时，Notifier 被挂载到根容器，build() 里
// ref.read(detailInitialProvider) 读到的是默认值（questionId: ''），
// 嵌套 ProviderScope 的 override 不生效。触发条件是“根 ProviderScope
// （main.dart）+ Navigator.push 进详情页”——现有 detail_page_test
// 把详情页直接当 home（无根 Scope）所以一直是绿的，没 catch 到。
// 本文件三组：直接当 home（对照，应过）、根 Scope + push（回归项，
// 修复前失败：currentId=''）、无根 Scope + push（对照，应过）。
// 修复后三组应全过。用 FakeRepo，不碰真实库（避开 FakeAsync + Drift
// 的挂起问题，见 D-45）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/detail/question_detail_page.dart';
import 'package:quiz_master2/state/detail_notifier.dart';
import 'package:quiz_master2/theme/app_theme.dart';

class MechFakeRepo extends QuestionRepository {
  MechFakeRepo(this.questions) : super(AppDatabase.instance);
  final List<Question> questions;

  @override
  Future<Question?> questionById(String id) async =>
      questions.where((q) => q.id == id).firstOrNull;

  @override
  Future<List<CauseRecord>> causeRecordsFor(String qid) async => [];

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
    String qid,
  ) async => [];

  @override
  Future<List<Exam>> exams() async => [];

  @override
  Future<List<Folder>> folders({String? subjectId}) async => [];

  @override
  Future<List<String>> tags() async => [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => [];

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  /// FR-09（批三）起 DetailNotifier.load() 也读 repo.settings()；
  /// 本测试的 FakeRepo 须给桩，否则走真实库（见批四批报告）。
  @override
  Future<AppSettings> settings() async => AppSettings.defaults;
}

final _q = Question(
  id: 'q-math-1',
  title: '函数极限',
  subjectId: 'math',
  createdAt: DateTime.now().subtract(const Duration(days: 2)),
  isOrganized: true,
  isDemo: true,
);

/// 从详情页的 Scaffold 元素定位内层 ProviderScope，读 detail 状态。
/// 找不到 Scaffold 时返回 null（并打印计数，不抛错）。
DetailState? readDetailState(WidgetTester tester) {
  final scaffolds = find.byType(Scaffold).evaluate();
  // ignore: avoid_print
  print('DIAG scaffolds=${scaffolds.length}');
  if (scaffolds.isEmpty) return null;
  final container = ProviderScope.containerOf(scaffolds.last);
  return container.read(detailProvider);
}

/// 让路由过渡动画（300ms）与 FakeRepo 的 load() 都跑完。
Future<void> settleDetail(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  testWidgets('对照：详情页直接当 home（现有测试做法）', (tester) async {
    final repo = MechFakeRepo([_q]);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(scale: 1.0),
        home: Scaffold(
          body: QuestionDetailPage(
            repo: repo,
            questionId: 'q-math-1',
            orderIds: const ['q-math-1'],
          ),
        ),
      ),
    );
    await settleDetail(tester);
    final st = readDetailState(tester);
    // ignore: avoid_print
    print(
      'DIAG mech-direct: currentId="${st?.currentId}" '
      'question=${st?.question == null ? 'NULL' : st!.question!.title} '
      'loading=${st?.loading}',
    );
    expect(st, isNotNull);
    expect(st!.currentId, 'q-math-1');
    expect(st.question, isNotNull);
  });

  testWidgets('复现：根 ProviderScope + Navigator.push 进详情页', (tester) async {
    final repo = MechFakeRepo([_q]);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(scale: 1.0),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => QuestionDetailPage(
                          repo: repo,
                          questionId: 'q-math-1',
                          orderIds: const ['q-math-1'],
                        ),
                      ),
                    );
                  },
                  child: const Text('打开详情'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开详情'));
    await settleDetail(tester);
    final st = readDetailState(tester);
    final notExist = find.text('这道题不存在了').evaluate().isNotEmpty;
    final title = find.text('函数极限').evaluate().isNotEmpty;
    // ignore: avoid_print
    print(
      'DIAG mech-push: currentId="${st?.currentId}" '
      'question=${st?.question == null ? 'NULL' : st!.question!.title} '
      'loading=${st?.loading} notExist=$notExist title=$title',
    );
    expect(st, isNotNull);
    expect(st!.currentId, 'q-math-1');
    expect(st.question, isNotNull);
  });

  testWidgets('变体：无根 Scope，只 Navigator.push 进详情页', (tester) async {
    final repo = MechFakeRepo([_q]);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(scale: 1.0),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => QuestionDetailPage(
                        repo: repo,
                        questionId: 'q-math-1',
                        orderIds: const ['q-math-1'],
                      ),
                    ),
                  );
                },
                child: const Text('打开详情'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开详情'));
    await settleDetail(tester);
    final st = readDetailState(tester);
    // ignore: avoid_print
    print(
      'DIAG mech-push-noroot: currentId="${st?.currentId}" '
      'question=${st?.question == null ? 'NULL' : st!.question!.title} '
      'loading=${st?.loading}',
    );
    expect(st, isNotNull);
    expect(st!.currentId, 'q-math-1');
    expect(st.question, isNotNull);
  });
}
