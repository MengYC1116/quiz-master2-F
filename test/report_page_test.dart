// R9 学习报告页 widget 测试：三个核心数、弱点 Top 5（学科 × 错因 /
// 学科 × 知识点）、看更多展开、点行进错题本（带学科 + 错因/知识点）、
// 范围切换重算、空态、加载失败横幅、亮/深 × 三档无溢出、不用图标字体。
// 用 FakeRepo 覆盖 repository 调用（不碰真实数据库）；日期一律相对
// 今天取，跑在任何一天结果都一样。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/report/report_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';

DateTime get _today {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

Question tq(
  String id,
  String title, {
  String subjectId = 'math',
  List<String> errorTypes = const [],
  List<String> knowledgePointIds = const [],
  DateTime? createdAt,
}) =>
    Question(
      id: id,
      title: title,
      subjectId: subjectId,
      errorTypes: errorTypes,
      knowledgePointIds: knowledgePointIds,
      createdAt: createdAt ?? _today,
      isOrganized: true,
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
}) =>
    CauseRecord(
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

class FakeReportRepo extends QuestionRepository {
  FakeReportRepo({
    required this.questions,
    required this.records,
    required this.kps,
    this.history = const {},
    this.throwOnLoad = false,
    List<Subject>? subjects,
  })  : subjectsValue = subjects ?? Subject.all,
        super(AppDatabase.instance);

  List<Question> questions;
  List<CauseRecord> records;
  List<KnowledgePoint> kps;
  Map<String, List<({String result, DateTime reviewedAt})>> history;
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
  Future<List<KnowledgePoint>> knowledgePoints() async => List.of(kps);

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
          String questionId) async =>
      List.of(history[questionId] ?? const []);
}

/// 默认库：本周 8 道题（q-old 是 40 天前的题，只在“全部”里出现）。
FakeReportRepo reportRepo({bool withHistory = true}) {
  final today = _today;
  final questions = [
    tq('q1', '函数极限', errorTypes: ['概念不清'],
        knowledgePointIds: ['kp-limit']),
    tq('q2', '导数应用', errorTypes: ['方法不会'],
        knowledgePointIds: ['kp-derivative']),
    tq('q3', '定积分', errorTypes: ['计算错误'],
        knowledgePointIds: ['kp-integral']),
    tq('q4', '学术词汇', subjectId: 'english', errorTypes: ['概念不清'],
        knowledgePointIds: ['kp-vocab']),
    tq('q5', '长篇阅读', subjectId: 'english', errorTypes: ['审题失误'],
        knowledgePointIds: ['kp-reading']),
    tq('q6', '史纲时间轴', subjectId: 'politics', errorTypes: ['审题失误'],
        knowledgePointIds: ['kp-history']),
    tq('q7', '马原', subjectId: 'politics', errorTypes: ['概念不清'],
        knowledgePointIds: ['kp-marx']),
    tq('q8', '材料分析', subjectId: 'politics', errorTypes: ['方法不会'],
        knowledgePointIds: ['kp-marx']),
    tq('q-old', '旧题', errorTypes: ['概念不清'],
        knowledgePointIds: ['kp-limit'],
        createdAt: today.subtract(const Duration(days: 40))),
  ];
  final records = [
    trec('q1', '概念不清'),
    trec('q2', '方法不会'),
    trec('q3', '计算错误',
        status: CauseStatus.inProgress, solvedCount: 1, lastCheck: today),
    trec('q4', '概念不清',
        subjectId: 'english',
        status: CauseStatus.solved,
        solvedCount: 2,
        lastCheck: today),
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
  final history = withHistory
      ? {
          'q4': [
            (result: 'solved', reviewedAt: today),
            (result: 'solved', reviewedAt: today),
            (result: 'unsolved', reviewedAt: today),
          ],
        }
      : <String, List<({String result, DateTime reviewedAt})>>{};
  return FakeReportRepo(
    questions: questions,
    records: records,
    kps: kps,
    history: history,
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
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
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
                onOpenWrongbookFiltered: ({
                  String? subjectId,
                  String? cause,
                  String? knowledgePointId,
                }) =>
                    calls.add((
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

void main() {
  group('核心数', () {
    testWidgets('已解决 1 · 待解决 4 · 复查通过率 67%', (tester) async {
      await pumpReport(tester);
      expect(find.byKey(const ValueKey('report-core-solved')), findsOneWidget);
      // 数字与序号圆盘同字：用 Key 精确定位核心数。
      expect(
        (tester.widget(find.byKey(const ValueKey('report-core-solved')))
                as Text)
            .data,
        '1',
      );
      expect(
        (tester.widget(find.byKey(const ValueKey('report-core-pending')))
                as Text)
            .data,
        '4',
      );
      expect(
        (tester.widget(find.byKey(const ValueKey('report-core-rate')))
                as Text)
            .data,
        '67%',
      );
      expect(find.text('已解决错因'), findsOneWidget);
      expect(find.text('待解决错因'), findsOneWidget);
      expect(find.text('复查通过率'), findsOneWidget);
      expect(find.text('复查 3 次，通过 2 次（已解决满 7 天回来复查）'),
          findsOneWidget);
      expect(find.text('同一错因 2 次自查「已解决」才算解决'), findsOneWidget);
    });

    testWidgets('无复查记录时通过率显示 —', (tester) async {
      await pumpReport(tester, repo: reportRepo(withHistory: false));
      expect(find.text('—'), findsOneWidget);
      expect(find.text('这段时间还没有复查记录'), findsOneWidget);
    });

    testWidgets('范围说明：本周 · 周一 ~ 今天 · 数字按这个时间段算',
        (tester) async {
      await pumpReport(tester);
      final today = _today;
      final monday = today.subtract(Duration(days: today.weekday - 1));
      expect(
        find.text('本周 · ${monday.month}-${monday.day} ~ '
            '${today.month}-${today.day} · 数字按这个时间段算'),
        findsOneWidget,
      );
    });
  });

  group('待解决按范围过滤（S8 B1）', () {
    String pendingValue(WidgetTester tester) =>
        (tester.widget(find.byKey(const ValueKey('report-core-pending')))
                as Text)
            .data!;
    String solvedValue(WidgetTester tester) =>
        (tester.widget(find.byKey(const ValueKey('report-core-solved')))
                as Text)
            .data!;

    // A 待解决·今天（本周/本月/全部都进）；B 解决中·上周日（只进本月/
    // 全部，本周一是 1 号时不存在该档）；C 待解决·40 天前（只进全部）；
    // D 待解决·从未自查（lastCheck 为空，三档都进）；E 已解决·今天（不进待解决）。
    FakeReportRepo rangeRepo() {
      final today = _today;
      final monday = today.subtract(Duration(days: today.weekday - 1));
      final inMonthOutWeek =
          monday.day > 1 ? monday.subtract(const Duration(days: 1)) : null;
      final questions = [
        tq('qA', '题 A', errorTypes: ['概念不清']),
        tq('qB', '题 B', errorTypes: ['方法不会']),
        tq('qC', '题 C', errorTypes: ['计算错误']),
        tq('qD', '题 D', errorTypes: ['审题失误']),
        tq('qE', '题 E', errorTypes: ['概念不清']),
      ];
      final records = [
        trec('qA', '概念不清', lastCheck: today),
        if (inMonthOutWeek != null)
          trec('qB', '方法不会',
              status: CauseStatus.inProgress,
              solvedCount: 1,
              lastCheck: inMonthOutWeek),
        trec('qC', '计算错误',
            lastCheck: today.subtract(const Duration(days: 40))),
        trec('qD', '审题失误'),
        trec('qE', '概念不清',
            status: CauseStatus.solved, solvedCount: 2, lastCheck: today),
      ];
      return FakeReportRepo(questions: questions, records: records, kps: []);
    }

    testWidgets('本周 2 · 本月 2/3 · 全部 3/4，已解决恒为 1', (tester) async {
      final today = _today;
      final monday = today.subtract(Duration(days: today.weekday - 1));
      final hasInMonthOutWeek = monday.day > 1;
      final repo = rangeRepo();
      await pumpReport(tester, repo: repo);
      // 默认本周：A + D。
      expect(pendingValue(tester), '2');
      expect(solvedValue(tester), '1');
      await tapSegment(tester, '本月');
      // 本月：A + B（若存在）+ D。
      expect(pendingValue(tester), hasInMonthOutWeek ? '3' : '2');
      expect(solvedValue(tester), '1');
      await tapSegment(tester, '全部');
      // 全部：A + B（若存在）+ C + D。
      expect(pendingValue(tester), hasInMonthOutWeek ? '4' : '3');
      expect(solvedValue(tester), '1');
    });

  });

  group('弱点', () {
    testWidgets('原因组：学科 × 错因分组，已解决的错因不出现', (tester) async {
      await pumpReport(tester);
      // 原因组共 7 行：默认只显示 5 条。
      expect(find.text('1 道题'), findsNWidgets(5));
      expect(
        find.widgetWithText(QmButton, '看更多（共 7 个）'),
        findsOneWidget,
      );
      final more = find.widgetWithText(QmButton, '看更多（共 7 个）');
      await tester.ensureVisible(more);
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();
      // 概念不清只剩数学、政治两组（英语那组已解决，不出现）。
      expect(find.textContaining('概念不清'), findsNWidgets(2));
      expect(find.textContaining('审题失误'), findsNWidgets(2));
    });

    testWidgets('知识点组：矛盾观 2 道排第一，已解决题的知识点不出现',
        (tester) async {
      await pumpReport(tester);
      expect(find.textContaining('矛盾观'), findsOneWidget);
      expect(find.text('还没解决 2 道'), findsOneWidget);
      // q4 已解决：学术词汇不进弱点。
      expect(find.textContaining('学术词汇'), findsNothing);
      expect(
        find.widgetWithText(QmButton, '看更多（共 6 个）'),
        findsOneWidget,
      );
    });

    testWidgets('看更多展开 7 条，再点收起回 5 条', (tester) async {
      await pumpReport(tester);
      final more = find.widgetWithText(QmButton, '看更多（共 7 个）');
      await tester.ensureVisible(more);
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(find.text('1 道题'), findsNWidgets(7));
      expect(find.widgetWithText(QmButton, '收起'), findsOneWidget);
      await tester.tap(find.widgetWithText(QmButton, '收起'));
      await tester.pumpAndSettle();
      expect(find.text('1 道题'), findsNWidgets(5));
    });

    testWidgets('点原因行进错题本：带学科 + 错因', (tester) async {
      await pumpReport(tester);
      final row = find.textContaining('审题失误').first;
      final inkwell = find.ancestor(of: row, matching: find.byType(InkWell));
      await tester.ensureVisible(inkwell);
      await tester.pumpAndSettle();
      await tester.tap(inkwell);
      await tester.pumpAndSettle();
      expect(_lastCalls, hasLength(1));
      expect(_lastCalls.single.subjectId, 'english');
      expect(_lastCalls.single.cause, '审题失误');
    });

    testWidgets('点知识点行进错题本：带学科 + 知识点', (tester) async {
      await pumpReport(tester);
      final row = find.textContaining('矛盾观');
      final inkwell = find.ancestor(of: row, matching: find.byType(InkWell));
      await tester.ensureVisible(inkwell);
      await tester.pumpAndSettle();
      await tester.tap(inkwell);
      await tester.pumpAndSettle();
      expect(_lastCalls, hasLength(1));
      expect(_lastCalls.single.subjectId, 'politics');
      expect(_lastCalls.single.kp, 'kp-marx');
    });
  });

  group('范围与分布', () {
    testWidgets('切到“全部”：旧题进来，数学分布变 4 道，概念不清变 2 道',
        (tester) async {
      await pumpReport(tester);
      await tapSegment(tester, '全部');
      expect(find.text('数学 · 4 道错题'), findsOneWidget);
      expect(find.text('2 道题'), findsOneWidget);
      expect(find.text('先解决数学的概念不清。'), findsOneWidget);
      expect(
        find.text('全部时间 · 数字按这个时间段算'),
        findsOneWidget,
      );
    });

    testWidgets('分布只按学科：本周数学 3 · 英语 2 · 政治 3', (tester) async {
      await pumpReport(tester);
      expect(find.text('数学 · 3 道错题'), findsOneWidget);
      expect(find.text('英语 · 2 道错题'), findsOneWidget);
      expect(find.text('政治 · 3 道错题'), findsOneWidget);
    });

    testWidgets('接下来练什么只有一句话，无按钮', (tester) async {
      await pumpReport(tester);
      expect(find.text('接下来练什么'), findsOneWidget);
      expect(find.text('先解决数学的方法不会。'), findsOneWidget);
      expect(find.widgetWithText(QmButton, '练'), findsNothing);
    });

    testWidgets('切换范围会收起已展开的弱点列表', (tester) async {
      await pumpReport(tester);
      final more = find.widgetWithText(QmButton, '看更多（共 7 个）');
      await tester.ensureVisible(more);
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(find.text('1 道题'), findsNWidgets(7));
      await tapSegment(tester, '本月');
      expect(find.text('1 道题'), findsNWidgets(5));
    });
  });

  group('空态与错误态', () {
    testWidgets('没有任何记录：小伙伴 + 去复习', (tester) async {
      final empty = FakeReportRepo(
        questions: [],
        records: [],
        kps: [],
      );
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

    testWidgets('加载失败：出错误横幅，可点“知道了”关闭', (tester) async {
      final broken = reportRepo()..throwOnLoad = true;
      await pumpReport(tester, repo: broken);
      expect(
        find.text('报告数据读取失败，已显示上次成功加载的内容。可重启应用后重试。'),
        findsOneWidget,
      );
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(
        find.text('报告数据读取失败，已显示上次成功加载的内容。可重启应用后重试。'),
        findsNothing,
      );
    });
  });

  group('无旧模型、无图标字体', () {
    testWidgets('不出现“下次复习时间”、不出现导出、不使用 Icon',
        (tester) async {
      await pumpReport(tester);
      expect(find.textContaining('下次复习时间'), findsNothing);
      expect(find.textContaining('导出'), findsNothing);
      expect(find.byType(Icon), findsNothing);
    });
  });

  group('亮/深 × 三档无溢出', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      for (final scale in [1.0, 1.15, 1.3]) {
        testWidgets(
          '${brightness == Brightness.dark ? '深色' : '亮色'} × $scale',
          (tester) async {
            await pumpReport(tester, brightness: brightness, scale: scale);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }

    testWidgets('窄窗口单列：两组弱点上下排，无溢出', (tester) async {
      await pumpReport(tester, width: 900);
      expect(find.text('最常错的5个原因'), findsOneWidget);
      expect(find.text('最常错的5个知识点'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
