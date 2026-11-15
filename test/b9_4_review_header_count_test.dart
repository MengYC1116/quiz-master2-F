// B9-4：复习页顶三数按题数计（Meng 2026-11-15 ~19:43 裁决：
// 与角标 / 首页统一，见 docs/ui-replication/B9-4-REVIEW-HEADER-COUNT.md）。
//
// 三数的精确定义（复用 QuestionRepository.reviewBucketOf 的共享口径，
// 一道题按其全部错因记录只落一个桶）：
// - 待解决 / 解决中：桶为 pending 的题数（≥1 个错因未解决）；
// - 复查：桶为 recheck 的题数（全部已解决且 ≥1 条到复查时间）；
// - 已解决：桶为 solved 的题数（全部已解决且无一条到复查时间）。
// 多错因一题只计 1 道；同一题不双计（一条记录只进 _groups 或
// _curedGroups 其中一边，按题汇总后才是该题的全部记录）。
//
// 用 FakeRepo 直接泵 ReviewPage（review_page_test.dart 同款做法，
// 不碰真实数据库）；断言只圈页顶三数，列表本身的分组展示不动。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/review/review_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';

Question _q(
  String id,
  String title, {
  List<String> errorTypes = const [],
}) =>
    Question(
      id: id,
      title: title,
      subjectId: 'math',
      errorTypes: errorTypes,
      createdAt: DateTime(2026, 11, 8),
      isOrganized: true,
      reviewJoined: true,
      sliceKind: 'material',
      sliceText: '题：$title',
    );

CauseRecord _rec(
  String questionId,
  String cause, {
  CauseStatus status = CauseStatus.pending,
  int solvedCount = 0,
  DateTime? recheckDate,
}) =>
    CauseRecord(
      questionId: questionId,
      cause: cause,
      subjectId: 'math',
      status: status,
      solvedCount: solvedCount,
      lastCheck:
          status == CauseStatus.solved ? DateTime(2026, 11, 10) : null,
      recheckDate: recheckDate,
      joinedAt: DateTime(2026, 11, 10),
    );

class _FakeRepo extends QuestionRepository {
  _FakeRepo({required this.questions, required this.records})
      : super(AppDatabase.instance);

  List<Question> questions;
  List<CauseRecord> records;

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<ReviewSessionState?> reviewState() async => null;
}

Future<void> _pumpReview(WidgetTester tester, _FakeRepo repo) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: Scaffold(
        body: ReviewPage(
          repo: repo,
          onOpenDetail: (_, __) async {},
          onGoWrongbook: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('2 道题 3 条待解决错因：页顶待解决显示 2 道题，不显示 3',
      (tester) async {
    final repo = _FakeRepo(
      questions: [
        _q('q1', '第一题', errorTypes: const ['概念不清', '计算错误']),
        _q('q2', '第二题', errorTypes: const ['审题失误']),
      ],
      records: [
        _rec('q1', '概念不清'),
        _rec('q1', '计算错误'),
        _rec('q2', '审题失误'),
      ],
    );
    await _pumpReview(tester, repo);
    // 按题数：q1、q2 各计 1，共 2 道题（不是 3 条错因记录）。
    expect(find.text('待解决 / 解决中 2 道题'), findsOneWidget);
    expect(find.text('待解决 / 解决中 3 条解决记录'), findsNothing);
    expect(find.text('已解决 0 道'), findsOneWidget);
    expect(find.text('复查 1 道'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('复查场景：某题全部错因已解决且 1 条到复查时间，复查计 1、待解决计 0',
      (tester) async {
    final repo = _FakeRepo(
      questions: [
        _q('q1', '第一题', errorTypes: const ['概念不清', '计算错误']),
      ],
      records: [
        // 两条都已解决；只有“概念不清”到了复查时间，整题落 recheck 桶。
        _rec('q1', '概念不清',
            status: CauseStatus.solved,
            solvedCount: 2,
            recheckDate: DateTime.now().subtract(const Duration(days: 1))),
        _rec('q1', '计算错误',
            status: CauseStatus.solved,
            solvedCount: 2,
            recheckDate: DateTime.now().add(const Duration(days: 7))),
      ],
    );
    await _pumpReview(tester, repo);
    expect(find.text('待解决 / 解决中 0 道题'), findsOneWidget);
    expect(find.text('复查 1 道'), findsOneWidget);
    expect(find.text('已解决 0 道'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已解决区多错因一题只计 1 道', (tester) async {
    final repo = _FakeRepo(
      questions: [
        _q('q1', '第一题', errorTypes: const ['概念不清', '计算错误']),
      ],
      records: [
        // 两条都已解决、复查日都未到，整题落 solved 桶，只计 1 道。
        _rec('q1', '概念不清',
            status: CauseStatus.solved,
            solvedCount: 2,
            recheckDate: DateTime.now().add(const Duration(days: 7))),
        _rec('q1', '计算错误',
            status: CauseStatus.solved,
            solvedCount: 2,
            recheckDate: DateTime.now().add(const Duration(days: 7))),
      ],
    );
    await _pumpReview(tester, repo);
    expect(find.text('待解决 / 解决中 0 道题'), findsOneWidget);
    expect(find.text('已解决 1 道'), findsOneWidget);
    expect(find.text('已解决 2 道'), findsNothing);
    expect(find.text('复查 1 道'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
