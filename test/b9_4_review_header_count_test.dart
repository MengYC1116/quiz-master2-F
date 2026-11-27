// B9-4（面 A 改写）：复习页顶两数按 FSRS 口径计（与首页焦点卡、
// 角标同一口径，见 FSRS 口径迁移方案 §2.0/§2.1）：
// - 到期：`fsrsDueQuestionIds()` 的题数（已开始且 next_due_at 已到）；
// - 今日新题：`previewNewRelease().todaysNewIds` 的题数（Y=0 时不显示）。
// 旧三数（待解决 / 复查 / 已解决）已取消；列表按 FSRS 卡片状态
// 分组（已逾期 / 今日到期 / 未到期 / 未开始），不再按错因记录分流。
//
// 用 FakeRepo 直接泵 ReviewPage（review_page_test.dart 同款做法，
// 不碰真实数据库）；断言只圈页顶两数与分组头，列表本身的分组展示
// 由 review_page_test.dart 覆盖。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' as fsrs;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/review/review_page.dart';
import 'package:quiz_master2/state/review_notifier.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';

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

CauseRecord _rec(String questionId, String cause) => CauseRecord(
      questionId: questionId,
      cause: cause,
      subjectId: 'math',
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
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<ReviewSessionState?> reviewState() async => null;

  /// 复习 load() 只有在 reviewState() 返回非空会话时才调这三口
  /// （M3-10 断点恢复校验）；本 Fake 的会话恒为 null，返回“无会话”
  /// 默认值，不碰真实库（见 D-88）。
  @override
  Future<bool> hasSessionVerdict({
    required String causeStableId,
    required String sessionId,
  }) async => false;

  @override
  Future<AttemptData?> loadAttempt({
    required String sessionId,
    required String questionId,
  }) async => null;

  @override
  Future<void> clearReviewState() async {}
}

/// 面 A：往内存卡库里预置一张已开始的 FSRS 卡（review_page_test.dart
/// 同款做法）。[dueLocalDayOffset] 是下次到期日的本地日偏移
/// （0 = 今天，负数 = 已逾期）；到期日取本地 00:00 换算成 UTC 存卡。
Future<void> _seedStartedCard(
  InMemoryCardStore store,
  String questionId,
  int cardId, {
  int dueLocalDayOffset = 0,
}) async {
  final now = DateTime.now();
  final todayStart = DateTime(now.year, now.month, now.day);
  final dueLocal = todayStart.add(Duration(days: dueLocalDayOffset));
  await store.save(
    StoredCard(
      questionId: questionId,
      cardId: cardId,
      card: fsrs.Card(
        cardId: cardId,
        state: fsrs.State.review,
        due: dueLocal.toUtc(),
        lastReview: now.toUtc(),
      ),
      configId: 'fsrs-6-v1',
      firstReviewedAt: now.toUtc(),
    ),
  );
}

Future<void> _pumpReview(
  WidgetTester tester,
  _FakeRepo repo, {
  InMemoryCardStore? cardStore,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    // P3：ReviewNotifier.load() 读调度器池内标记（fsrsPoolIds）——
    // 外层覆盖一个确定性内存调度器（fuzzing 关），不碰真实数据库
    //（review_page_test.dart 同款做法）。
    ProviderScope(
      overrides: [
        reviewSchedulerProvider.overrideWithValue(
          FsrsReviewScheduler(
            config: const SchedulerConfig(enableFuzzing: false),
            store: cardStore ?? InMemoryCardStore(),
          ),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        home: Scaffold(
          body: ReviewPage(
            repo: repo,
            onOpenDetail: (_, __, {String? searchContext}) async {},
            onGoWrongbook: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('2 道题 3 条待解决错因：无卡时页顶到期 0 道，两题都在未开始组',
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
    // 旧口径按错因记录会算“待解决 2 道题”；新口径只认 FSRS 卡，
    // 无卡即未开始、不到期，页顶只显示到期 0 道。
    expect(find.textContaining('到期 0 道'), findsOneWidget);
    expect(find.text('待解决 / 解决中 2 道题'), findsNothing);
    expect(find.text('待解决 / 解决中 3 条解决记录'), findsNothing);
    expect(find.text('已解决 0 道'), findsNothing);
    expect(find.text('复查 1 道'), findsNothing);
    expect(find.text('未开始'), findsOneWidget);
    expect(find.text('第一题'), findsOneWidget);
    expect(find.text('第二题'), findsOneWidget);
    // FSRS 全量迁移包2：池空即无到期（旧回落已删），开始复习禁用。
    expect(
      tester.widget<QmButton>(find.widgetWithText(QmButton, '开始复习')).onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('旧复查场景：某题全部错因已解决且 1 条到复查时间，无卡仍算未开始',
      (tester) async {
    final repo = _FakeRepo(
      questions: [
        _q('q1', '第一题', errorTypes: const ['概念不清', '计算错误']),
      ],
      records: [
        // 两条都已解决；只有“概念不清”到了复查时间，旧口径整题落
        // recheck 桶；新口径不看错因记录，无卡即未开始。
        _rec('q1', '概念不清'),
        _rec('q1', '计算错误'),
      ],
    );
    await _pumpReview(tester, repo);
    expect(find.textContaining('到期 0 道'), findsOneWidget);
    expect(find.text('待解决 / 解决中 0 道题'), findsNothing);
    expect(find.text('复查 1 道'), findsNothing);
    expect(find.text('已解决 0 道'), findsNothing);
    expect(find.text('未开始'), findsOneWidget);
    expect(find.text('第一题'), findsOneWidget);
    // FSRS 全量迁移包2：池空即无到期（旧回落已删），开始复习禁用。
    expect(
      tester.widget<QmButton>(find.widgetWithText(QmButton, '开始复习')).onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('有卡场景：1 道已逾期 + 1 道今日到期，页顶到期 2 道', (tester) async {
    final repo = _FakeRepo(
      questions: [
        _q('q1', '第一题', errorTypes: const ['概念不清']),
        _q('q2', '第二题', errorTypes: const ['审题失误']),
      ],
      records: [
        _rec('q1', '概念不清'),
        _rec('q2', '审题失误'),
      ],
    );
    final store = InMemoryCardStore();
    await _seedStartedCard(store, 'q1', 1, dueLocalDayOffset: -1);
    await _seedStartedCard(store, 'q2', 2, dueLocalDayOffset: 0);
    await _pumpReview(tester, repo, cardStore: store);
    // 页顶与 FSRS 当日清单盒同一口径：到期 2 道；今日新题 0 道，
    // 页顶不显示，只在当日清单盒里出现。
    expect(find.textContaining('到期 2 道'), findsNWidgets(2)); // 页顶 + FSRS 盒
    expect(find.textContaining('今日新题 0 道'), findsOneWidget); // 仅 FSRS 盒
    expect(find.text('已逾期'), findsOneWidget);
    expect(find.text('今日到期'), findsOneWidget);
    expect(find.textContaining('已逾期 1 天'), findsOneWidget);
    expect(
      tester.widget<QmButton>(find.widgetWithText(QmButton, '开始复习')).onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  // M3-11：全部无卡且无到期项时出提示条（伙伴 + “今天没有到期
  // 复习” + 未到期/未开始题数），列表仍在下面按分组列出；
  // 已解决区与原查看入口已取消。
  testWidgets('无卡无到期：提示条 + 未开始列表同在，已解决区不出', (tester) async {
    final repo = _FakeRepo(
      questions: [
        _q('q1', '第一题', errorTypes: const ['概念不清', '计算错误']),
      ],
      records: [
        // 两条都已解决、复查日都未到，旧口径整题落 solved 桶；
        // 新口径无卡即未开始。
        _rec('q1', '概念不清'),
        _rec('q1', '计算错误'),
      ],
    );
    await _pumpReview(tester, repo);
    expect(find.text('今天没有到期复习'), findsOneWidget);
    expect(
      find.text('未到期的题有 0 道，未开始的题有 1 道。'),
      findsOneWidget,
    );
    expect(find.widgetWithText(QmButton, '查看已掌握题目'), findsNothing);
    expect(find.textContaining('关联 1 道题'), findsNothing);
    expect(find.textContaining('关联 2 道题'), findsNothing);
    expect(find.text('未开始'), findsOneWidget);
    expect(find.text('第一题'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
