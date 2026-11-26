// R9 学习报告页 widget 测试：三个核心数、弱点 Top 5（学科 × 错因 /
// 学科 × 知识点）、看更多展开、点行进错题本（带学科 + 错因/知识点）、
// 范围切换重算、空态、加载失败横幅、亮/深 × 三档无溢出、不用图标字体。
// 用 FakeRepo 覆盖 repository 调用（不碰真实数据库）；日期一律相对
// 今天取，跑在任何一天结果都一样。
// FSRS 口径迁移（Meng 2026-11-25 定）：三个核心数、两组 Top 5、分布
// 全部按 attempts / 题目集合新定义重写断言；weakStats 不变，只做回归。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/report/report_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';

DateTime get _today {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

int get _nowMs => _today.millisecondsSinceEpoch;

Question tq(
  String id,
  String title, {
  String subjectId = 'math',
  List<String> errorTypes = const [],
  List<String> knowledgePointIds = const [],
  DateTime? createdAt,
  bool isOrganized = true,
  bool isArchived = false,
}) => Question(
  id: id,
  title: title,
  subjectId: subjectId,
  errorTypes: errorTypes,
  knowledgePointIds: knowledgePointIds,
  createdAt: createdAt ?? _today,
  isOrganized: isOrganized,
  isArchived: isArchived,
  reviewJoined: true,
  sliceKind: 'material',
  sliceText: '题：$title',
);

CauseRecord trec(
  String questionId,
  String cause, {
  String subjectId = 'math',
  CauseStatus status = CauseStatus.pending,
  int solvedCount = 0,
  DateTime? lastCheck,
  DateTime? joinedAt,
}) => CauseRecord(
  questionId: questionId,
  cause: cause,
  subjectId: subjectId,
  status: status,
  solvedCount: solvedCount,
  lastCheck: lastCheck,
  joinedAt: joinedAt ?? _today,
);

KnowledgePoint tkp(String id, String subjectId, String chapter, String name) =>
    KnowledgePoint(id: id, subjectId: subjectId, chapter: chapter, name: name);

AttemptData tatt(
  String qid,
  String mode,
  int? correct,
  int createdAtMs, {
  List<String> causeIds = const [],
  String sessionId = 's1',
}) => AttemptData(
  id: 'att-$qid-$createdAtMs-$correct-$sessionId',
  questionId: qid,
  sessionId: sessionId,
  mode: mode,
  correct: correct,
  answerVersion: 1,
  contentVersion: 0,
  status: '已提交',
  causeIds: causeIds,
  submissionId: 'sub-$qid-$createdAtMs-$correct-$sessionId',
  createdAt: createdAtMs,
);

class FakeReportRepo extends QuestionRepository {
  FakeReportRepo({
    required this.questions,
    required this.records,
    required this.kps,
    this.attemptsValue = const [],
    this.throwOnLoad = false,
    List<Subject>? subjects,
  }) : subjectsValue = subjects ?? Subject.all,
       super(AppDatabase.instance);

  List<Question> questions;
  List<CauseRecord> records;
  List<KnowledgePoint> kps;
  List<AttemptData> attemptsValue;
  bool throwOnLoad;
  List<Subject> subjectsValue;

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);

  @override
  Future<List<Question>> all({bool includeArchived = false}) async {
    if (throwOnLoad) throw StateError('db down');
    return List.of(questions);
  }

  @override
  Future<List<CauseRecord>> causeRecords() async {
    if (throwOnLoad) throw StateError('db down');
    return List.of(records);
  }

  @override
  Future<List<AttemptData>> loadAllAttempts() async =>
      List.of(attemptsValue);

  @override
  Future<Set<String>> fsrsPoolQuestionIds() async => const {};

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => List.of(kps);

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;
}

/// 默认库：本周 8 道题（q-old 是 40 天前的题，只在“全部”里出现）。
/// 本周正式作答：q1 答对 1 次 + 答错 1 次 + 未判分 1 次；q2 正式答错
/// 1 次 + 专项答对 1 次；q3 正式答对 2 次；q4/q5/q6 正式答错各 1 次；
/// q7 正式答对 1 次；q8 正式答错 1 次（错因两个）。
/// 本周：答对 4 次，答错 6 道，已判分 10 次，答对率 40%。
FakeReportRepo reportRepo() {
  final today = _today;
  final now = _nowMs;
  final old = today.subtract(const Duration(days: 40)).millisecondsSinceEpoch;
  final questions = [
    tq('q1', '函数极限', errorTypes: ['概念不清'], knowledgePointIds: ['kp-limit']),
    tq(
      'q2',
      '导数应用',
      errorTypes: ['方法不会'],
      knowledgePointIds: ['kp-derivative'],
    ),
    tq('q3', '定积分', errorTypes: ['计算错误'], knowledgePointIds: ['kp-integral']),
    tq(
      'q4',
      '学术词汇',
      subjectId: 'english',
      errorTypes: ['概念不清'],
      knowledgePointIds: ['kp-vocab'],
    ),
    tq(
      'q5',
      '长篇阅读',
      subjectId: 'english',
      errorTypes: ['审题失误'],
      knowledgePointIds: ['kp-reading'],
    ),
    tq(
      'q6',
      '史纲时间轴',
      subjectId: 'politics',
      errorTypes: ['审题失误'],
      knowledgePointIds: ['kp-history'],
    ),
    tq(
      'q7',
      '马原',
      subjectId: 'politics',
      errorTypes: ['概念不清'],
      knowledgePointIds: ['kp-marx'],
    ),
    tq(
      'q8',
      '材料分析',
      subjectId: 'politics',
      errorTypes: ['方法不会'],
      knowledgePointIds: ['kp-marx'],
    ),
    tq(
      'q-old',
      '旧题',
      errorTypes: ['概念不清'],
      knowledgePointIds: ['kp-limit'],
      createdAt: today.subtract(const Duration(days: 40)),
    ),
  ];
  final records = [
    trec('q1', '概念不清'),
    trec('q2', '方法不会'),
    trec(
      'q3',
      '计算错误',
      status: CauseStatus.inProgress,
      solvedCount: 1,
      lastCheck: today,
    ),
    trec(
      'q4',
      '概念不清',
      subjectId: 'english',
      status: CauseStatus.solved,
      solvedCount: 2,
      lastCheck: today,
    ),
    trec('q-old', '概念不清', joinedAt: today.subtract(const Duration(days: 40))),
  ];
  final kps = [
    tkp('kp-limit', 'math', '函数与极限', '函数极限'),
    tkp('kp-derivative', 'math', '导数与微分', '导数应用'),
    tkp('kp-integral', 'math', '定积分', '定积分应用'),
    tkp('kp-vocab', 'english', '词汇', '学术词汇'),
    tkp('kp-reading', 'english', '阅读', '长篇阅读'),
    tkp('kp-history', 'politics', '史纲', '时间轴'),
    tkp('kp-marx', 'politics', '马原', '矛盾观'),
  ];
  final attempts = [
    tatt('q1', ReviewMode.due, 1, now, sessionId: 's1'),
    tatt('q1', ReviewMode.due, 0, now, causeIds: ['概念不清'],
        sessionId: 's2'),
    tatt('q1', ReviewMode.due, null, now, sessionId: 's3'),
    tatt('q2', ReviewMode.due, 0, now, causeIds: ['方法不会']),
    tatt('q2', ReviewMode.practice, 1, now),
    tatt('q3', ReviewMode.due, 1, now, sessionId: 's1'),
    tatt('q3', ReviewMode.due, 1, now, sessionId: 's2'),
    tatt('q4', ReviewMode.due, 0, now, causeIds: ['概念不清']),
    tatt('q5', ReviewMode.due, 0, now, causeIds: ['审题失误']),
    tatt('q6', ReviewMode.due, 0, now, causeIds: ['审题失误']),
    tatt('q7', ReviewMode.due, 1, now),
    tatt('q8', ReviewMode.due, 0, now, causeIds: ['方法不会', '概念不清']),
    tatt('q-old', ReviewMode.due, 0, old, causeIds: ['概念不清']),
  ];
  return FakeReportRepo(
    questions: questions,
    records: records,
    kps: kps,
    attemptsValue: attempts,
  );
}

Future<void> pumpReport(
  WidgetTester tester, {
  FakeReportRepo? repo,
  Brightness brightness = Brightness.light,
  double scale = 1.0,
  double width = 1280,
}) async {
  tester.view.physicalSize = Size(width, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final calls = <({String? subjectId, String? cause, String? kp})>[];
  var wentReview = false;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: scale),
      darkTheme: AppTheme.dark(scale: scale),
      themeMode: brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      home: Builder(
        builder: (context) {
          final data = MediaQuery.of(context);
          return MediaQuery(
            data: data.copyWith(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: ReportPage(
                key: UniqueKey(),
                repo: repo ?? reportRepo(),
                onGoReview: () => wentReview = true,
                onOpenWrongbookFiltered:
                    ({
                      String? subjectId,
                      String? cause,
                      String? knowledgePointId,
                    }) => calls.add((
                      subjectId: subjectId,
                      cause: cause,
                      kp: knowledgePointId,
                    )),
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  // 回调记录供断言用（每次 pump 都重置）。
  _lastCalls = calls;
  _lastWentReview = () => wentReview;
}

List<({String? subjectId, String? cause, String? kp})> _lastCalls = [];
bool Function() _lastWentReview = () => false;

Future<void> tapSegment(WidgetTester tester, String label) async {
  final finder = find.text(label);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

String _coreValue(WidgetTester tester, String key) => (tester.widget(
  find.byKey(ValueKey(key)),
) as Text).data!;

void main() {
  group('核心数', () {
    testWidgets('正式答对 4 次 · 正式答错 6 道 · 答对率 40%', (tester) async {
      await pumpReport(tester);
      expect(
        find.byKey(const ValueKey('report-core-formal-correct')),
        findsOneWidget,
      );
      // 数字与序号圆盘同字：用 Key 精确定位核心数。
      expect(_coreValue(tester, 'report-core-formal-correct'), '4');
      expect(_coreValue(tester, 'report-core-formal-wrong'), '6');
      expect(_coreValue(tester, 'report-core-formal-rate'), '40%');
      expect(find.text('正式复习答对'), findsOneWidget);
      expect(find.text('正式复习答错'), findsOneWidget);
      expect(find.text('正式复习答对率'), findsOneWidget);
      expect(find.text('按作答次数计（正式复习）'), findsOneWidget);
      expect(find.text('按题数计，同一题多次答错只算 1 道'), findsOneWidget);
      expect(
        find.text('正式复习 10 次已判分，答对 4 次 · 客观答对率，与旧的自查通过率不是同一回事'),
        findsOneWidget,
      );
    });

    testWidgets('无已判分记录时答对率显示 —', (tester) async {
      final repo = FakeReportRepo(
        questions: [tq('q1', '题', errorTypes: ['概念不清'])],
        records: [trec('q1', '概念不清')],
        kps: [],
        attemptsValue: [tatt('q1', ReviewMode.due, null, _nowMs)],
      );
      await pumpReport(tester, repo: repo);
      expect(find.text('—'), findsOneWidget);
      expect(find.text('这段时间还没有已判分的正式复习作答'), findsOneWidget);
    });

    testWidgets('范围说明：本周 · 周一 ~ 今天 · 数字按这个时间段算', (tester) async {
      await pumpReport(tester);
      final today = _today;
      final monday = today.subtract(Duration(days: today.weekday - 1));
      expect(
        find.text(
          '本周 · ${monday.month}-${monday.day} ~ '
          '${today.month}-${today.day} · 数字按这个时间段算',
        ),
        findsOneWidget,
      );
    });
  });

  group('核心数按范围过滤（attempts.created_at）', () {
    testWidgets('本周答对 4 次 · 答错 6 道 · 40%；全部答错 7 道 · 36%', (
      tester,
    ) async {
      await pumpReport(tester);
      expect(_coreValue(tester, 'report-core-formal-correct'), '4');
      expect(_coreValue(tester, 'report-core-formal-wrong'), '6');
      expect(_coreValue(tester, 'report-core-formal-rate'), '40%');
      await tapSegment(tester, '全部');
      // 40 天前旧题的正式答错进来：答对仍 4 次，答错 7 道，
      // 已判分 11 次，答对率 36%。
      expect(_coreValue(tester, 'report-core-formal-correct'), '4');
      expect(_coreValue(tester, 'report-core-formal-wrong'), '7');
      expect(_coreValue(tester, 'report-core-formal-rate'), '36%');
    });
  });

  group('弱点', () {
    testWidgets('原因组：学科 × 错因分组，正式答错的题才出现', (tester) async {
      await pumpReport(tester);
      // 原因组共 7 行：默认只显示 5 条；知识点组同样 7 行。
      // 两组弱点行都显示“1 道题”（知识点组“2 道题”只有矛盾观一行）。
      expect(find.text('1 道题'), findsNWidgets(9));
      expect(
        find.widgetWithText(QmButton, '看更多（共 7 个）'),
        findsNWidgets(2),
      );
      final more = find.widgetWithText(QmButton, '看更多（共 7 个）').first;
      await tester.ensureVisible(more);
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();
      // 概念不清三组（数学、英语、政治各一）；审题失误两组。
      expect(find.textContaining('概念不清'), findsNWidgets(3));
      expect(find.textContaining('审题失误'), findsNWidgets(2));
    });

    testWidgets('知识点组：矛盾观 2 道排第一；已解决题的知识点仍在列', (tester) async {
      await pumpReport(tester);
      expect(find.textContaining('矛盾观'), findsOneWidget);
      expect(find.text('2 道题'), findsOneWidget);
      // D-259：已解决记录不再排除任何题——q4 正式答错过，学术词汇在列
      //（题名与知识点同名，故标题行“英语 · 学术词汇”恰出现一次）。
      expect(find.textContaining('英语 · 学术词汇'), findsOneWidget);
      expect(
        find.widgetWithText(QmButton, '看更多（共 7 个）'),
        findsNWidgets(2),
      );
    });

    testWidgets('FR-18：知识点弱点为空时文案是“这段时间没有带知识点的错题。”', (
      tester,
    ) async {
      final repo = FakeReportRepo(
        questions: [
          tq('q1', '函数极限', errorTypes: ['概念不清']),
        ],
        records: [trec('q1', '概念不清')],
        kps: const [],
        attemptsValue: [
          tatt('q1', ReviewMode.due, 0, _nowMs, causeIds: ['概念不清']),
        ],
      );
      await pumpReport(tester, repo: repo);
      expect(find.text('这段时间没有带知识点的错题。'), findsOneWidget);
      expect(find.text('这段时间没有待解决的知识点。'), findsNothing);
      expect(find.text('这段时间没有待解决的错因。'), findsNothing);
      expect(find.text('这段时间正式复习还没有答错的题。'), findsNothing);
    });

    testWidgets('看更多展开 7 条，再点收起回 5 条', (tester) async {
      await pumpReport(tester);
      // 初始：原因组 5 条“1 道题” + 知识点组 4 条“1 道题”（第 5 条是 2 道）。
      expect(find.text('1 道题'), findsNWidgets(9));
      final more = find.widgetWithText(QmButton, '看更多（共 7 个）').first;
      await tester.ensureVisible(more);
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(find.text('1 道题'), findsNWidgets(11));
      expect(find.widgetWithText(QmButton, '收起'), findsOneWidget);
      await tester.tap(find.widgetWithText(QmButton, '收起'));
      await tester.pumpAndSettle();
      expect(find.text('1 道题'), findsNWidgets(9));
    });

    testWidgets('点原因行进薄弱点列表页：先看题目，再决定练多少', (tester) async {
      await pumpReport(tester);
      final row = find.textContaining('审题失误').first;
      final inkwell = find.ancestor(of: row, matching: find.byType(InkWell));
      await tester.ensureVisible(inkwell);
      await tester.pumpAndSettle();
      await tester.tap(inkwell);
      await tester.pumpAndSettle();
      // P3 入口 3：点行先进题目列表页，不再直接跳错题本。
      expect(_lastCalls, isEmpty);
      expect(find.byKey(const Key('weak-list-title')), findsOneWidget);
      expect(find.text('开始专项练习'), findsOneWidget);
      expect(find.text('加入复习'), findsOneWidget);
      // 列表页里的“在错题本中查看”仍走旧深链路（带学科 + 错因）。
      // 归因方式变了（attempts 的 cause_ids），筛选键仍是错因文本。
      await tester.tap(find.text('在错题本中查看'));
      await tester.pumpAndSettle();
      expect(_lastCalls, hasLength(1));
      expect(_lastCalls.single.subjectId, 'english');
      expect(_lastCalls.single.cause, '审题失误');
    });

    testWidgets('点知识点行进薄弱点列表页：先看题目，再决定练多少', (tester) async {
      await pumpReport(tester);
      final row = find.textContaining('矛盾观');
      final inkwell = find.ancestor(of: row, matching: find.byType(InkWell));
      await tester.ensureVisible(inkwell);
      await tester.pumpAndSettle();
      await tester.tap(inkwell);
      await tester.pumpAndSettle();
      // P3 入口 3：点行先进题目列表页，不再直接跳错题本。
      expect(_lastCalls, isEmpty);
      expect(find.byKey(const Key('weak-list-title')), findsOneWidget);
      expect(find.text('开始专项练习'), findsOneWidget);
      // 列表页里的“在错题本中查看”仍走旧深链路（带学科 + 知识点）。
      await tester.tap(find.text('在错题本中查看'));
      await tester.pumpAndSettle();
      expect(_lastCalls, hasLength(1));
      expect(_lastCalls.single.subjectId, 'politics');
      expect(_lastCalls.single.kp, 'kp-marx');
    });
  });

  group('SR-P1-10 / SR-P1-11 口径', () {
    testWidgets('SR-P1-10：同名不同题各算 1 道，原因组与知识点组都计 2 道', (tester) async {
      final repo = FakeReportRepo(
        questions: [
          tq(
            'qA',
            '选择题',
            errorTypes: ['概念不清'],
            knowledgePointIds: ['kp-limit'],
          ),
          tq(
            'qB',
            '选择题',
            errorTypes: ['概念不清'],
            knowledgePointIds: ['kp-limit'],
          ),
        ],
        records: [trec('qA', '概念不清'), trec('qB', '概念不清')],
        kps: [tkp('kp-limit', 'math', '函数与极限', '函数极限')],
        attemptsValue: [
          tatt('qA', ReviewMode.due, 0, _nowMs, causeIds: ['概念不清']),
          tatt('qB', ReviewMode.due, 0, _nowMs, causeIds: ['概念不清']),
        ],
      );
      await pumpReport(tester, repo: repo);
      expect(find.text('2 道题'), findsNWidgets(2));
      expect(find.text('数学 · 作答 2 道'), findsOneWidget);
    });

    testWidgets('SR-P1-11：未整理题与已归档题不进弱点 Top5 与学科分布', (tester) async {
      final repo = FakeReportRepo(
        questions: [
          tq(
            'q1',
            '已整理题',
            errorTypes: ['概念不清'],
            knowledgePointIds: ['kp-limit'],
          ),
          tq(
            'q2',
            '未整理题',
            errorTypes: ['概念不清'],
            knowledgePointIds: ['kp-limit'],
            isOrganized: false,
          ),
          tq(
            'q3',
            '已归档题',
            errorTypes: ['概念不清'],
            knowledgePointIds: ['kp-limit'],
            isArchived: true,
          ),
        ],
        records: [trec('q1', '概念不清')],
        kps: [tkp('kp-limit', 'math', '函数与极限', '函数极限')],
        attemptsValue: [
          tatt('q1', ReviewMode.due, 0, _nowMs, causeIds: ['概念不清']),
        ],
      );
      await pumpReport(tester, repo: repo);
      expect(find.text('1 道题'), findsNWidgets(2));
      expect(find.text('数学 · 作答 1 道'), findsOneWidget);
      expect(find.textContaining('未整理题'), findsNothing);
      expect(find.textContaining('已归档题'), findsNothing);
    });
  });

  group('范围与分布', () {
    testWidgets('切到“全部”：旧题进来，数学作答变 4 道，概念不清变 2 道', (tester) async {
      await pumpReport(tester);
      await tapSegment(tester, '全部');
      expect(find.text('数学 · 作答 4 道'), findsOneWidget);
      // “2 道题”共 3 处：原因组数学·概念不清 1 处 + 知识点组
      // 函数极限、矛盾观各 1 处。
      expect(find.text('2 道题'), findsNWidgets(3));
      expect(find.text('先解决数学的概念不清。'), findsOneWidget);
      expect(find.text('全部时间 · 数字按这个时间段算'), findsOneWidget);
    });

    testWidgets('分布是范围内作答题数：本周数学 3 · 英语 2 · 政治 3', (tester) async {
      await pumpReport(tester);
      expect(find.text('数学 · 作答 3 道'), findsOneWidget);
      expect(find.text('英语 · 作答 2 道'), findsOneWidget);
      expect(find.text('政治 · 作答 3 道'), findsOneWidget);
    });

    testWidgets('无正式作答的学科显示作答 0 道', (tester) async {
      // 只有数学题有正式作答 → 英语、政治作答 0 道。
      final repo = FakeReportRepo(
        questions: [
          tq(
            'q1',
            '函数极限',
            errorTypes: ['概念不清'],
            knowledgePointIds: ['kp-limit'],
          ),
          tq(
            'q2',
            '导数应用',
            errorTypes: ['方法不会'],
            knowledgePointIds: ['kp-derivative'],
          ),
          tq(
            'q3',
            '定积分',
            errorTypes: ['计算错误'],
            knowledgePointIds: ['kp-integral'],
          ),
        ],
        records: [
          trec('q1', '概念不清'),
          trec('q2', '方法不会'),
          trec(
            'q3',
            '计算错误',
            status: CauseStatus.inProgress,
            solvedCount: 1,
            lastCheck: _today,
          ),
        ],
        kps: const [],
        attemptsValue: [
          tatt('q1', ReviewMode.due, 1, _nowMs),
          tatt('q2', ReviewMode.due, 0, _nowMs, causeIds: ['方法不会']),
          tatt('q3', ReviewMode.due, 1, _nowMs),
        ],
      );
      await pumpReport(tester, repo: repo);
      expect(find.text('数学 · 作答 3 道'), findsOneWidget);
      expect(find.text('英语 · 作答 0 道'), findsOneWidget);
      expect(find.text('政治 · 作答 0 道'), findsOneWidget);
    });

    testWidgets('接下来练什么只有一句话，无按钮', (tester) async {
      await pumpReport(tester);
      expect(find.text('接下来练什么'), findsOneWidget);
      expect(find.text('先解决数学的方法不会。'), findsOneWidget);
      expect(find.widgetWithText(QmButton, '练'), findsNothing);
    });

    testWidgets('切换范围会收起已展开的弱点列表', (tester) async {
      await pumpReport(tester);
      final more = find.widgetWithText(QmButton, '看更多（共 7 个）').first;
      await tester.ensureVisible(more);
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(find.text('1 道题'), findsNWidgets(11));
      await tapSegment(tester, '本月');
      expect(find.text('1 道题'), findsNWidgets(9));
    });
  });

  group('空态与错误态', () {
    testWidgets('没有任何记录：小伙伴 + 去复习', (tester) async {
      final empty = FakeReportRepo(questions: [], records: [], kps: []);
      await pumpReport(tester, repo: empty);
      expect(find.text('还没有复习记录，先去复习吧'), findsOneWidget);
      final go = find.widgetWithText(QmButton, '去复习');
      expect(go, findsOneWidget);
      await tester.ensureVisible(go);
      await tester.pumpAndSettle();
      await tester.tap(go);
      await tester.pumpAndSettle();
      expect(_lastWentReview(), isTrue);
    });

    testWidgets('FSRS 口径迁移面 D：空态文案是三步（看题、作答、核对），不出现“四步”', (
      tester,
    ) async {
      final empty = FakeReportRepo(questions: [], records: [], kps: []);
      await pumpReport(tester, repo: empty);
      expect(
        find.text('在复习页按三步（看题、作答、核对）练几道题，回来这里就会告诉你弱在哪、有没有效果、接下来练什么。'),
        findsOneWidget,
      );
      expect(find.textContaining('四步'), findsNothing);
    });

    testWidgets('加载失败：出错误横幅，可点“知道了”关闭', (tester) async {
      final broken = reportRepo()..throwOnLoad = true;
      await pumpReport(tester, repo: broken);
      expect(find.text('报告数据读取失败，已显示上次成功加载的内容。可重启应用后重试。'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.text('报告数据读取失败，已显示上次成功加载的内容。可重启应用后重试。'), findsNothing);
    });
  });

  group('无旧模型、无图标字体', () {
    testWidgets('不出现“下次复习时间”、不出现导出、不使用 Icon', (tester) async {
      await pumpReport(tester);
      expect(find.textContaining('下次复习时间'), findsNothing);
      expect(find.textContaining('导出'), findsNothing);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('不出现“已解决/待解决/复查通过率/已掌握”旧词', (tester) async {
      await pumpReport(tester);
      expect(find.text('已解决错因'), findsNothing);
      expect(find.text('待解决错因'), findsNothing);
      expect(find.text('复查通过率'), findsNothing);
      expect(find.textContaining('已掌握'), findsNothing);
      expect(find.textContaining('待解决'), findsNothing);
    });
  });

  group('亮/深 × 三档无溢出', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      for (final scale in [1.0, 1.15, 1.3]) {
        testWidgets('${brightness == Brightness.dark ? '深色' : '亮色'} × $scale', (
          tester,
        ) async {
          await pumpReport(tester, brightness: brightness, scale: scale);
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('窄窗口单列：两组弱点上下排，无溢出', (tester) async {
      await pumpReport(tester, width: 900);
      expect(find.text('最常错的 5 个原因'), findsOneWidget);
      expect(find.text('最常错的 5 个知识点'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
