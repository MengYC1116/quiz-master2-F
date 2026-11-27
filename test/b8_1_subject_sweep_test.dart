// B8-1 扫尾：删学科后幽灵学科复活——同模式剩余 5 处（Meng Win11 真机
// 验收 image-89 / 90 / 98 的同一根因 `subjects.isEmpty ? Subject.all
// : subjects`，第 1 项工人已修导航速览 / 收集下拉 / 错题本书架 /
// 首页四处，本文件覆盖剩下的详情 / 整理 / 报告 / 复习四页）。
//
// 修法与前四处一致：空表就是空（直接用库里的列表），初始值也改成
// 空（与 app.dart `_navSubjects = const []` 同款），删光学科后各页
// 不再摆出预设三科。`_subjectOf` / `_subjectName` 里 `Subject.byId`
// 的兜底只在数据不一致时触发，按任务要求不动——因此：
// - 报告页（分布行直接遍历 _subjects）与复习页（学科筛选下拉直接
//   遍历 _subjects）是真能抓 bug 的差分断言：修好前空表仍渲染三行 /
//   三个下拉项，修好后零行 / 零项；
// - 详情 / 整理两页只用 _subjectOf 查单题学科（经 byId 兜底），列表
//   级无渲染点，改动是防呆对齐；这两组锁的是“空学科库下页面正常
//   渲染、不崩、空状态里一个预设名都没有”，差分断言在报告 / 复习。
// 用 FakeRepo，不碰真实数据库；无文件 IO。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/report_stats.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/detail/question_detail_page.dart';
import 'package:quiz_master2/modules/organize/organize_page.dart';
import 'package:quiz_master2/modules/report/report_page.dart';
import 'package:quiz_master2/modules/review/review_page.dart';
import 'package:quiz_master2/state/review_notifier.dart';
import 'package:quiz_master2/theme/app_theme.dart';

DateTime get _today {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

Question _q(
  String id,
  String title, {
  String subjectId = 'math',
  List<String> errorTypes = const [],
  List<String> folderIds = const [],
  bool isOrganized = true,
  bool reviewJoined = false,
}) => Question(
  id: id,
  title: title,
  subjectId: subjectId,
  errorTypes: errorTypes,
  folderIds: folderIds,
  createdAt: _today,
  isOrganized: isOrganized,
  reviewJoined: reviewJoined,
  sliceKind: 'material',
  sliceText: '题：$title',
);

CauseRecord _rec(
  String questionId,
  String cause, {
  String subjectId = 'math',
}) => CauseRecord(
  questionId: questionId,
  cause: cause,
  subjectId: subjectId,
  joinedAt: _today,
);

Future<void> _pumpPage(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    // P3：复习页 load() 读调度器池内标记、详情页“加入复习”调
    // initializeQuestion——外层覆盖一个确定性内存调度器（fuzzing 关），
    // 不碰真实数据库（review_page_test.dart 同款做法）。
    ProviderScope(
      overrides: [
        reviewSchedulerProvider.overrideWithValue(
          FsrsReviewScheduler(
            config: const SchedulerConfig(enableFuzzing: false),
            store: InMemoryCardStore(),
          ),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light(scale: 1.0),
        darkTheme: AppTheme.dark(scale: 1.0),
        // 每次 pump 用新 Key：同一 testWidgets 内两次 pump 时旧 State
        // 会被复用（_load 只在 initState 跑），须强制重建
        //（detail_page_test 的 pumpDetail 同款做法）。
        home: Scaffold(body: KeyedSubtree(key: UniqueKey(), child: page)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

// ---------------------------------------------------------------- 详情页

class _SweepDetailRepo extends QuestionRepository {
  _SweepDetailRepo({required this.questions, List<Subject>? subjects})
    : subjectsValue = subjects ?? Subject.all,
      super(AppDatabase.instance);

  List<Question> questions;
  List<Subject> subjectsValue;

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);

  // FR-09（D-88）：DetailNotifier.load() 多读 repo.settings()；FakeRepo
  // 不覆写会落到基类读真实 Drift 库，测试 fake async 里永不完成，
  // loading 一直 true、转圈拖死 pumpAndSettle。
  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

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
  Future<List<Folder>> folders({String? subjectId}) async => const [];

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<String>> tags() async => const [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  /// 十二批功能 4（D-91）：记一次查看的桩（不碰真实库；不覆盖会落到
  /// 基类读真实 Drift 库，fake async 里永不完成，见 D-88）。
  @override
  Future<void> recordQuestionViewed(String questionId) async {}

  /// 十三批 M5：OCR 状态是 best-effort 加载（不 await）；返回空任务行
  /// 与“无 key”，不碰真实库（见 D-88）。
  @override
  Future<List<OcrJob>> ocrJobsForQuestion(String questionId) async =>
      const [];

  @override
  Future<bool> hasOcrApiKey() async => false;

  /// 详情页自愈（_healSliceIfNeeded）读同页框：无框，不碰真实库（见 D-88）。
  @override
  Future<List<QuestionBox>> boxesForPageImage(String pageImagePath) async =>
      const [];
}

// ---------------------------------------------------------------- 整理页

class _SweepOrganizeRepo extends QuestionRepository {
  _SweepOrganizeRepo({required this.questions, List<Subject>? subjects})
    : subjectsValue = subjects ?? Subject.all,
      super(AppDatabase.instance);

  List<Question> questions;
  List<Subject> subjectsValue;

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [
    Folder(id: 'f1', name: '平时作业', subjectId: 'math'),
  ];

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<List<String>> tags() async => const [];

  @override
  Future<void> save(Question question, {SaveToken? token}) async {}

  @override
  Future<void> saveRecentTask({
    required String kind,
    required String subjectId,
    required String title,
  }) async {}

  /// B11-10：OrganizeNotifier 只在队列已空且库里有题时读这两个数
  /// （今日小结行用）；返回 0 / 空，不碰真实库（见 D-88）。
  @override
  Future<int> organizedTodayCount({DateTime? now}) async => 0;

  @override
  Future<List<CauseRecord>> causeRecords() async => const [];

  /// 十三批 M5：OCR 状态是 best-effort 加载（不 await）；返回空任务行
  /// 与“无 key”，不碰真实库（见 D-88）。
  @override
  Future<List<OcrJob>> ocrJobsForQuestion(String questionId) async =>
      const [];

  @override
  Future<bool> hasOcrApiKey() async => false;
}

// ---------------------------------------------------------------- 报告页

class _SweepReportRepo extends QuestionRepository {
  _SweepReportRepo({
    required this.questions,
    required this.records,
    List<Subject>? subjects,
    this.attempts = const [],
  }) : subjectsValue = subjects ?? Subject.all,
       super(AppDatabase.instance);

  List<Question> questions;
  List<CauseRecord> records;
  List<Subject> subjectsValue;
  List<AttemptData> attempts;

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  // P3 入口 3：报告 load() 读全部 attempts 与池内标记（不覆写会走
  // 真实库、页面卡 loading、pumpAndSettle 超时）。
  @override
  Future<List<AttemptData>> loadAllAttempts() async => List.of(attempts);

  @override
  Future<Set<String>> fsrsPoolQuestionIds() async => const {};

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
    String questionId,
  ) async => const [];
}

// ---------------------------------------------------------------- 复习页

class _SweepReviewRepo extends QuestionRepository {
  _SweepReviewRepo({
    required this.questions,
    required this.records,
    List<Subject>? subjects,
  }) : subjectsValue = subjects ?? Subject.all,
       super(AppDatabase.instance);

  List<Question> questions;
  List<CauseRecord> records;
  List<Subject> subjectsValue;

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
    String questionId,
  ) async => const [];

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
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<void> clearReviewState() async {}
}

/// 报告分布行夹具（FSRS 口径，方案 §2.3）：一条正式复习作答，今天作答。
AttemptData _reportAttempt(
  String questionId, {
  int? correct,
  String session = 's1',
}) => AttemptData(
  id: 'att-$questionId-$correct-$session',
  questionId: questionId,
  sessionId: session,
  mode: ReviewMode.due,
  correct: correct,
  answerVersion: 1,
  contentVersion: 0,
  status: '已提交',
  submissionId: 'sub-$questionId-$correct-$session',
  createdAt: _today.millisecondsSinceEpoch,
);

/// 报告默认范围“本周”的起点（与 ReportState.rangeStart 同口径）。
DateTime get _weekStart {
  final t = _today;
  return t.subtract(Duration(days: t.weekday - 1));
}

/// 新口径分布行期望值：直接由 computeReportStats 算出，不手写数字。
/// 返回学科名 → 分布行文案。
Map<String, String> _expectedDistRows({
  required List<AttemptData> attempts,
  required List<Question> questions,
  required List<Subject> subjects,
}) {
  final stats = computeReportStats(
    attempts: attempts,
    questions: questions,
    knowledgePoints: const [],
    subjectIdsInOrder: [for (final s in subjects) s.id],
    rangeStart: _weekStart,
  );
  return {
    for (final s in subjects)
      s.name: '${s.name} · 作答 ${stats.answeredBySubject[s.id] ?? 0} 道',
  };
}

void main() {
  group('B8-1 扫尾：详情页——学科删空后无预设三科', () {
    testWidgets('学科表为空：题正常显示，不崩；题没了时空状态里无预设名',
        (tester) async {
      await _pumpPage(
        tester,
        QuestionDetailPage(
          repo: _SweepDetailRepo(
            questions: [_q('q1', '函数极限', reviewJoined: true)],
            subjects: const [],
          ),
          questionId: 'q1',
          orderIds: const ['q1'],
        ),
      );
      // 十九批 C：旧拼串标题「学科 · 题型｜题名」已随 D1 板子去掉
      //（板子 §2.3：学科 chip + 题名 + 状态 pill + 星）；题名本身仍在。
      expect(find.text('函数极限'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 题不存在（已被删）+ 学科表为空：空状态，不摆预设三科。
      await _pumpPage(
        tester,
        QuestionDetailPage(
          repo: _SweepDetailRepo(questions: const [], subjects: const []),
          questionId: 'q1',
          orderIds: const ['q1'],
        ),
      );
      expect(find.text('这道题不存在了'), findsOneWidget);
      for (final name in ['数学', '英语', '政治']) {
        expect(find.text(name), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('B8-1 扫尾：整理页——学科删空后无预设三科', () {
    testWidgets('学科表为空：队列正常显示；无待整理题时空状态里无预设名',
        (tester) async {
      await _pumpPage(
        tester,
        OrganizePage(
          repo: _SweepOrganizeRepo(
            questions: [_q('q1', '函数极限', isOrganized: false)],
            subjects: const [],
          ),
          onOpenDetail: (_, __, {String? searchContext}) async {},
          onGoReview: () {},
          onGoCollect: () {},
        ),
      );
      expect(find.text('整理工作台'), findsOneWidget);
      expect(find.text('还剩 1 道'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _pumpPage(
        tester,
        OrganizePage(
          repo: _SweepOrganizeRepo(questions: const [], subjects: const []),
          onOpenDetail: (_, __, {String? searchContext}) async {},
          onGoReview: () {},
          onGoCollect: () {},
        ),
      );
      expect(find.text('没有待整理的题目'), findsOneWidget);
      for (final name in ['数学', '英语', '政治']) {
        expect(find.text(name), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('B8-1 扫尾：报告页——学科删空后分布不再摆预设三科', () {
    testWidgets('学科表为空：有复习记录时分布零行（修好前是三行 0 道）',
        (tester) async {
      // 包 6：报告空态守门改看正式作答——本用例要进数据视图（不是空态），
      // 须给一条正式作答（旧守门只看错因记录，现已删除）。
      await _pumpPage(
        tester,
        ReportPage(
          repo: _SweepReportRepo(
            questions: [_q('q1', '函数极限', errorTypes: ['概念不清'])],
            records: [_rec('q1', '概念不清')],
            subjects: const [],
            attempts: [_reportAttempt('q1', correct: 0)],
          ),
          onGoReview: () {},
          onOpenWrongbookFiltered: ({subjectId, cause, knowledgePointId}) {},
        ),
      );
      // 主体正常渲染（不是空态），分布区标题在、但一行都没有。
      // 新口径标题是“各科正式作答”，分布行文案是“作答 N 道”。
      expect(find.text('还没有复习记录，先去复习吧'), findsNothing);
      expect(find.text('各科正式作答（只按学科看）'), findsOneWidget);
      // 「X · 作答 N 道」只在分布行里出现；修好前这里是数学/英语/政治三行。
      expect(find.textContaining('· 作答'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('学科表非空：分布三行仍在（正常路径未破坏）', (tester) async {
      // 新口径：分布 = 范围内有正式作答的题数（按题去重）。q1 有一条
      // 正式作答 → 数学 1 道；英/政无作答 → 0 道。期望值由
      // computeReportStats 直接算出。
      final questions = [_q('q1', '函数极限', errorTypes: ['概念不清'])];
      final attempts = [_reportAttempt('q1', correct: 0)];
      final expected = _expectedDistRows(
        attempts: attempts,
        questions: questions,
        subjects: Subject.all,
      );
      await _pumpPage(
        tester,
        ReportPage(
          repo: _SweepReportRepo(
            questions: questions,
            records: [_rec('q1', '概念不清')],
            attempts: attempts,
          ),
          onGoReview: () {},
          onOpenWrongbookFiltered: ({subjectId, cause, knowledgePointId}) {},
        ),
      );
      expect(find.text('各科正式作答（只按学科看）'), findsOneWidget);
      for (final row in expected.values) {
        expect(find.text(row), findsOneWidget);
      }
      expect(find.textContaining('道错题'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('B8-1 扫尾：复习页——学科删空后筛选下拉不再有预设三科', () {
    testWidgets('学科表为空：打开学科下拉，只有“全部”，无预设三科',
        (tester) async {
      await _pumpPage(
        tester,
        ReviewPage(
          repo: _SweepReviewRepo(
            questions: [
              _q(
                'q1',
                '函数极限',
                errorTypes: ['概念不清'],
                reviewJoined: true,
              ),
            ],
            records: [_rec('q1', '概念不清')],
            subjects: const [],
          ),
          onOpenDetail: (_, __, {String? searchContext}) async {},
          onGoWrongbook: () {},
        ),
      );
      // 分组行头的单题学科名走 sanctioned 的 Subject.byId 兜底
      //（任务要求不动），只出现一次；下拉里不应再出现。
      expect(find.text('数学'), findsOneWidget);
      await tester.tap(find.byType(DropdownButton<String>).first);
      await tester.pumpAndSettle();
      expect(find.text('全部'), findsWidgets);
      for (final name in ['英语', '政治']) {
        expect(find.text(name), findsNothing);
      }
      expect(find.text('数学'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('学科表非空：学科下拉三科仍在（正常路径未破坏）',
        (tester) async {
      await _pumpPage(
        tester,
        ReviewPage(
          repo: _SweepReviewRepo(
            questions: [
              _q(
                'q1',
                '函数极限',
                errorTypes: ['概念不清'],
                reviewJoined: true,
              ),
            ],
            records: [_rec('q1', '概念不清')],
          ),
          onOpenDetail: (_, __, {String? searchContext}) async {},
          onGoWrongbook: () {},
        ),
      );
      await tester.tap(find.byType(DropdownButton<String>).first);
      await tester.pumpAndSettle();
      // 行头一个「数学」+ 下拉里一个；英语 / 政治只在下拉里。
      expect(find.text('数学'), findsNWidgets(2));
      expect(find.text('英语'), findsOneWidget);
      expect(find.text('政治'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
