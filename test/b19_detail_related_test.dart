// 十九批 D1 右栏三组测试：Notifier 层 computeDetailRelated /
// reviewStatusPillLabel / formalAttemptsLabel 单测 + widget 层三组渲染与跳转。
// 数据按真实演示库 9 道题的分组仿造（3 科 × 3 题，错因/知识点/
// 文件夹交叉），再加 1 道已归档题验排除。FakeRepo 覆写 all() 与
// loadAllAttempts()（不覆写会落到真实 Drift，fake async 里永不完成，
// 见 D-88）；其余 load() 要读的口与 detail_page_test 的 FakeDetailRepo
// 同款覆写，不碰真实数据库。状态文案只记正式复习对错事实
//（D-259，方案 §5 第 3 项选 (A)），不再用错因治愈记录推结论。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/detail/question_detail_page.dart';
import 'package:quiz_master2/state/detail_notifier.dart';
import 'package:quiz_master2/theme/app_theme.dart';

Question _rq(
  String id,
  String title, {
  required String subjectId,
  required String folderId,
  String? kpId,
  List<String> causes = const [],
  required DateTime createdAt,
  bool isOrganized = true,
  bool isArchived = false,
  bool reviewJoined = false,
}) => Question(
  id: id,
  title: title,
  subjectId: subjectId,
  folderIds: [folderId],
  knowledgePointIds: kpId == null ? const [] : [kpId],
  errorTypes: causes,
  createdAt: createdAt,
  isOrganized: isOrganized,
  isArchived: isArchived,
  reviewJoined: reviewJoined,
  sliceKind: 'limit',
  sliceText: '题：$title',
);

/// 9 道演示分组 + 1 道已归档（概念不清，须被排除）。
List<Question> b19Questions() => [
  _rq(
    'q-math-1',
    '函数极限',
    subjectId: 'math',
    folderId: 'f1',
    kpId: 'k1',
    causes: const ['概念不清'],
    createdAt: DateTime(2026, 11, 6),
    reviewJoined: true,
  ),
  _rq(
    'q-math-2',
    '导数应用综合',
    subjectId: 'math',
    folderId: 'f2',
    kpId: 'k2',
    causes: const ['方法不会'],
    createdAt: DateTime(2026, 11, 7),
  ),
  _rq(
    'q-math-3',
    '定积分阴影面积',
    subjectId: 'math',
    folderId: 'f3',
    kpId: 'k3',
    causes: const ['计算错误'],
    createdAt: DateTime(2026, 11, 8),
    isOrganized: false,
  ),
  _rq(
    'q-eng-1',
    '学术词汇辨析',
    subjectId: 'english',
    folderId: 'f2',
    kpId: 'k4',
    causes: const ['概念不清'],
    createdAt: DateTime(2026, 11, 9),
  ),
  _rq(
    'q-eng-2',
    '长篇阅读',
    subjectId: 'english',
    folderId: 'f1',
    kpId: 'k5',
    causes: const ['审题失误'],
    createdAt: DateTime(2026, 11, 10),
  ),
  _rq(
    'q-eng-3',
    '图表作文',
    subjectId: 'english',
    folderId: 'f3',
    kpId: 'k6',
    causes: const ['方法不会'],
    createdAt: DateTime(2026, 11, 11),
  ),
  _rq(
    'q-pol-1',
    '史纲时间轴图题',
    subjectId: 'politics',
    folderId: 'f1',
    kpId: 'k7',
    causes: const ['审题失误'],
    createdAt: DateTime(2026, 11, 12),
  ),
  _rq(
    'q-pol-2',
    '马原',
    subjectId: 'politics',
    folderId: 'f2',
    kpId: 'k8',
    causes: const ['概念不清'],
    createdAt: DateTime(2026, 11, 13),
  ),
  _rq(
    'q-pol-3',
    '材料分析：中国式现代化',
    subjectId: 'politics',
    folderId: 'f3',
    kpId: 'k8',
    causes: const ['方法不会'],
    createdAt: DateTime(2026, 11, 14),
  ),
  _rq(
    'q-old',
    '已归档概念不清题',
    subjectId: 'math',
    folderId: 'f1',
    kpId: 'k1',
    causes: const ['概念不清'],
    createdAt: DateTime(2026, 11, 5),
    isArchived: true,
  ),
];

List<CauseRecord> b19Records() {
  final now = DateTime.now();
  return [
    CauseRecord(
      questionId: 'q-math-1',
      cause: '概念不清',
      subjectId: 'math',
      status: CauseStatus.inProgress,
      solvedCount: 1,
      joinedAt: now.subtract(const Duration(days: 2)),
    ),
    CauseRecord(
      questionId: 'q-eng-1',
      cause: '概念不清',
      subjectId: 'english',
      status: CauseStatus.pending,
      joinedAt: now.subtract(const Duration(days: 1)),
    ),
    CauseRecord(
      questionId: 'q-pol-2',
      cause: '概念不清',
      subjectId: 'politics',
      status: CauseStatus.solved,
      solvedCount: 2,
      joinedAt: now.subtract(const Duration(days: 1)),
      recheckDate: now.add(const Duration(days: 7)),
    ),
    CauseRecord(
      questionId: 'q-eng-3',
      cause: '方法不会',
      subjectId: 'english',
      status: CauseStatus.solved,
      solvedCount: 2,
      joinedAt: now.subtract(const Duration(days: 1)),
      recheckDate: now.add(const Duration(days: 7)),
    ),
    CauseRecord(
      questionId: 'q-pol-3',
      cause: '方法不会',
      subjectId: 'politics',
      status: CauseStatus.inProgress,
      solvedCount: 1,
      joinedAt: now.subtract(const Duration(days: 1)),
    ),
  ];
}

/// 一条作答夹具：默认正式复习（mode = 到期复习）。
AttemptData _attempt(
  String questionId, {
  String mode = ReviewMode.due,
  int? correct,
  String session = 's1',
}) => AttemptData(
  id: 'att-$questionId-$mode-$correct-$session',
  questionId: questionId,
  sessionId: session,
  mode: mode,
  correct: correct,
  answerVersion: 1,
  contentVersion: 0,
  status: '已提交',
  submissionId: 'sub-$questionId-$mode-$correct-$session',
  createdAt: DateTime.now().millisecondsSinceEpoch,
);

/// 正式复习对错夹具（`_refreshRelated` 过滤用：专项与未判分不计）：
/// q-eng-1 答错 1 次（另有未判分 1 次 + 专项答对 1 次，均不计）；
/// q-pol-2 答对 2 次（另有专项答对 1 次不计）；
/// q-pol-3 答对 1 次、答错 1 次。
List<AttemptData> b19Attempts() => [
  _attempt('q-eng-1', correct: 0, session: 's1'),
  _attempt('q-eng-1', session: 's2'),
  _attempt('q-eng-1', mode: ReviewMode.practice, correct: 1, session: 's3'),
  _attempt('q-pol-2', correct: 1, session: 's1'),
  _attempt('q-pol-2', correct: 1, session: 's2'),
  _attempt('q-pol-2', mode: ReviewMode.practice, correct: 1, session: 's3'),
  _attempt('q-pol-3', correct: 1, session: 's1'),
  _attempt('q-pol-3', correct: 0, session: 's2'),
];

class _B19Repo extends QuestionRepository {
  _B19Repo({
    required this.questions,
    required this.records,
    this.attempts = const [],
  }) : super(AppDatabase.instance);

  final List<Question> questions;
  final List<CauseRecord> records;

  /// 正式复习作答夹具（`_refreshRelated` 读它算相关题状态文案；
  /// 不覆写会落到真实 Drift，fake async 里永不完成，见 D-88）。
  final List<AttemptData> attempts;

  @override
  Future<List<AttemptData>> loadAllAttempts() async => List.of(attempts);

  /// `_refreshReviewStatus` 读池 id；夹具题都不在池里。
  @override
  Future<Set<String>> fsrsPoolQuestionIds() async => const {};
  final List<Folder> folderList = const [
    Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
    Folder(id: 'f2', name: '平时作业', subjectId: 'math', sortOrder: 10),
    Folder(id: 'f3', name: '模拟卷', subjectId: 'math', sortOrder: 20),
  ];
  final List<KnowledgePoint> kpList = const [
    KnowledgePoint(id: 'k1', subjectId: 'math', chapter: '第一章', name: '函数极限'),
    KnowledgePoint(id: 'k2', subjectId: 'math', chapter: '第二章', name: '导数应用'),
    KnowledgePoint(id: 'k3', subjectId: 'math', chapter: '第三章', name: '定积分应用'),
    KnowledgePoint(id: 'k4', subjectId: 'english', chapter: '', name: '学术词汇'),
    KnowledgePoint(id: 'k5', subjectId: 'english', chapter: '', name: '长篇阅读'),
    KnowledgePoint(id: 'k6', subjectId: 'english', chapter: '', name: '图表作文'),
    KnowledgePoint(id: 'k7', subjectId: 'politics', chapter: '', name: '时间轴'),
    KnowledgePoint(id: 'k8', subjectId: 'politics', chapter: '', name: '矛盾观'),
  ];

  final List<Question> saved = [];

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      includeArchived
          ? List.of(questions)
          : questions.where((q) => !q.isArchived).toList();

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<Question?> questionById(String id) async =>
      questions.where((q) => q.id == id).firstOrNull;

  @override
  Future<List<CauseRecord>> causeRecordsFor(String questionId) async =>
      records.where((r) => r.questionId == questionId).toList();

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
    String questionId,
  ) async => const [];

  @override
  Future<List<Folder>> folders({String? subjectId}) async =>
      subjectId == null
          ? List.of(folderList)
          : folderList.where((f) => f.subjectId == subjectId).toList();

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<String>> tags() async => const [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => List.of(kpList);

  @override
  Future<void> recordQuestionViewed(String questionId) async {}

  @override
  Future<void> syncCauseRecords(Question q) async {}

  @override
  Future<void> save(Question question, {SaveToken? token}) async {
    saved.add(question);
    final i = questions.indexWhere((x) => x.id == question.id);
    if (i >= 0) {
      questions[i] = question;
    } else {
      questions.add(question);
    }
  }

  @override
  Future<void> toggleFavorite(Question q) async {
    await save(q.copyWith(isFavorite: !q.isFavorite));
  }

  @override
  Future<void> archive(Question q, {bool archived = true}) async {
    await save(q.copyWith(isArchived: archived));
  }

  @override
  Future<void> delete(Question question) async {
    questions.removeWhere((x) => x.id == question.id);
  }

  @override
  Future<bool> setReviewJoined(Question q, bool joined) async {
    if (joined && q.allCauses.isEmpty) return false;
    await save(q.copyWith(reviewJoined: joined));
    return true;
  }

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

_B19Repo _b19Repo() => _B19Repo(
  questions: b19Questions(),
  records: b19Records(),
  attempts: b19Attempts(),
);

Future<void> _pumpB19Detail(
  WidgetTester tester, {
  _B19Repo? repo,
  String questionId = 'q-math-1',
  List<String> orderIds = const [
    'q-math-1',
    'q-math-2',
    'q-math-3',
    'q-eng-1',
    'q-eng-2',
    'q-eng-3',
    'q-pol-1',
    'q-pol-2',
    'q-pol-3',
  ],
  String? searchContext,
  OpenWrongbookFiltered? onOpenWrongbookFiltered,
  double width = 1280,
  double height = 720,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: Scaffold(
        body: QuestionDetailPage(
          key: UniqueKey(),
          repo: repo ?? _b19Repo(),
          questionId: questionId,
          orderIds: orderIds,
          sourceLabel: '错题本',
          searchContext: searchContext,
          onOpenWrongbookFiltered: onOpenWrongbookFiltered,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tapB19Text(WidgetTester tester, String text) async {
  final finder = find.text(text);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// 导航后新旧两页同在栈里：取最上面那页的文本点按。
Future<void> tapB19TextLast(WidgetTester tester, String text) async {
  final finder = find.text(text).last;
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  group('reviewStatusPillLabel 与 formalAttemptsLabel', () {
    test('pill：不在池里 → 未加入复习；在池未开始 → 未开始', () {
      expect(
        reviewStatusPillLabel(
          const DetailReviewStatus(
            inPool: false,
            formalCorrect: 0,
            formalWrong: 0,
          ),
        ),
        '未加入复习',
      );
      expect(
        reviewStatusPillLabel(
          const DetailReviewStatus(
            inPool: true,
            formalCorrect: 0,
            formalWrong: 0,
          ),
        ),
        '未开始',
      );
    });

    test('pill：已开始，到期 → 已到期；未到 → 未到期', () {
      final now = DateTime(2026, 11, 26, 12);
      expect(
        reviewStatusPillLabel(
          DetailReviewStatus(
            inPool: true,
            nextDueAt: DateTime(2026, 11, 25),
            formalCorrect: 1,
            formalWrong: 0,
          ),
          now: now,
        ),
        '已到期',
      );
      expect(
        reviewStatusPillLabel(
          DetailReviewStatus(
            inPool: true,
            nextDueAt: DateTime(2026, 11, 28),
            formalCorrect: 1,
            formalWrong: 0,
          ),
          now: now,
        ),
        '未到期',
      );
    });

    test('对错事实：无记录 → 暂无正式复习记录；有记录 → 按次计', () {
      expect(formalAttemptsLabel(0, 0), '暂无正式复习记录');
      expect(formalAttemptsLabel(2, 1), '正式复习答对 2 次 · 答错 1 次');
      expect(formalAttemptsLabel(0, 1), '正式复习答对 0 次 · 答错 1 次');
    });
  });

  /// 相关题状态文案夹具（只记正式复习对错事实）：q-eng-1 答错 1 次、
  /// q-pol-2 答对 2 次、q-pol-3 答对 1 次答错 1 次；其余题无记录。
  const b19AttemptsByQ = {
    'q-eng-1': (correct: 0, wrong: 1),
    'q-pol-2': (correct: 2, wrong: 0),
    'q-pol-3': (correct: 1, wrong: 1),
  };

  group('computeDetailRelated', () {
    test('q-math-1：同错因 2 道（答错过优先，归档排除）+ 同文件夹 3 道第 1 位', () {
      final all = b19Questions();
      final current = all.firstWhere((q) => q.id == 'q-math-1');
      final rel = computeDetailRelated(
        current: current,
        all: all,
        formalAttemptsByQuestion: b19AttemptsByQ,
        folderName: '试卷',
      );
      // 同错因「概念不清」：q-eng-1（答错过）排前，q-pol-2（只答对过）排后；
      // 已归档 q-old 不进组，当前题不进组。
      expect(
        rel.sameCause.map((e) => e.question.id).toList(),
        ['q-eng-1', 'q-pol-2'],
      );
      expect(rel.sameCause.first.statusLabel, '正式复习答对 0 次 · 答错 1 次');
      expect(rel.sameCause.last.statusLabel, '正式复习答对 2 次 · 答错 0 次');
      // 同知识点「函数极限」只有已归档的 q-old → 空组。
      expect(rel.sameKp, isEmpty);
      // 同文件夹 f1：q-math-1、q-eng-2、q-pol-1（q-old 归档不计），当前题第 1 位。
      expect(rel.folder, isNotNull);
      expect(rel.folder!.name, '试卷');
      expect(rel.folder!.totalCount, 3);
      expect(rel.folder!.currentPosition, 1);
    });

    test('q-pol-2：同错因新→旧 + 同知识点 1 道 + 文件夹第 3 位', () {
      final all = b19Questions();
      final current = all.firstWhere((q) => q.id == 'q-pol-2');
      final rel = computeDetailRelated(
        current: current,
        all: all,
        formalAttemptsByQuestion: b19AttemptsByQ,
        folderName: '平时作业',
      );
      // 同错因：q-eng-1 答错过排前，q-math-1 无正式复习记录排后。
      expect(
        rel.sameCause.map((e) => e.question.id).toList(),
        ['q-eng-1', 'q-math-1'],
      );
      // 同知识点「矛盾观」：q-pol-3（答对 1 次、答错 1 次）。
      expect(
        rel.sameKp.map((e) => e.question.id).toList(),
        ['q-pol-3'],
      );
      expect(rel.sameKp.first.statusLabel, '正式复习答对 1 次 · 答错 1 次');
      // 同文件夹 f2：q-math-2、q-eng-1、q-pol-2，当前题最晚收集 → 第 3 位。
      expect(rel.folder!.totalCount, 3);
      expect(rel.folder!.currentPosition, 3);
    });

    test('q-math-3：同错因/同知识点都空，只剩文件夹', () {
      final all = b19Questions();
      final current = all.firstWhere((q) => q.id == 'q-math-3');
      final rel = computeDetailRelated(
        current: current,
        all: all,
        formalAttemptsByQuestion: b19AttemptsByQ,
        folderName: '模拟卷',
      );
      expect(rel.sameCause, isEmpty);
      expect(rel.sameKp, isEmpty);
      expect(rel.folder!.totalCount, 3);
      expect(rel.folder!.currentPosition, 1);
    });

    test('当前题不在 all 里 → folder 为 null；无文件夹 → folder 为 null', () {
      final all = b19Questions();
      final outsider = _rq(
        'q-out',
        '库外题',
        subjectId: 'math',
        folderId: 'f1',
        causes: const ['概念不清'],
        createdAt: DateTime(2026, 11, 15),
      );
      final relOut = computeDetailRelated(
        current: outsider,
        all: all,
        formalAttemptsByQuestion: b19AttemptsByQ,
        folderName: '试卷',
      );
      expect(relOut.folder, isNull);
      final noFolder = _rq(
        'q-nf',
        '无文件夹题',
        subjectId: 'math',
        folderId: 'f1',
        causes: const ['概念不清'],
        createdAt: DateTime(2026, 11, 15),
      ).copyWith(folderIds: const []);
      final relNf = computeDetailRelated(
        current: noFolder,
        all: all,
        formalAttemptsByQuestion: b19AttemptsByQ,
      );
      expect(relNf.folder, isNull);
    });
  });

  group('右栏三组渲染', () {
    testWidgets('q-math-1：同错因 + 同文件夹有数据，同知识点空组不显示', (tester) async {
      await _pumpB19Detail(tester);
      expect(find.byKey(const Key('detail-right-302')), findsOneWidget);
      expect(find.byKey(const Key('related-same-cause')), findsOneWidget);
      expect(find.byKey(const Key('related-same-folder')), findsOneWidget);
      expect(find.byKey(const Key('related-same-kp')), findsNothing);
      // 同错因 panel：首行 + 汇总行（N 含已展示那道）。
      expect(find.text('同错因的其他题 · 概念不清'), findsOneWidget);
      expect(find.text('学术词汇辨析'), findsOneWidget);
      expect(
        find.text('英语 · 正式复习答对 0 次 · 答错 1 次 · 也栽在「概念不清」上，可对照着看'),
        findsOneWidget,
      );
      expect(find.text('跳过去 ›'), findsOneWidget);
      expect(find.text('还有 2 道同错因的题'), findsOneWidget);
      expect(find.text('政治 1 · 英语 1'), findsOneWidget);
      expect(find.text('全部 ›'), findsOneWidget);
      // 同文件夹 panel：标题含计数 + 入口行。
      expect(find.text('同文件夹 · 试卷（3 道）'), findsOneWidget);
      expect(find.text('按收集顺序继续看这个文件夹'), findsOneWidget);
      expect(find.text('当前第 1 道 · 共 3 道'), findsOneWidget);
      expect(find.text('打开列表 ›'), findsOneWidget);
    });

    testWidgets('q-pol-2：三组都有数据，同知识点只列具体题', (tester) async {
      await _pumpB19Detail(tester, questionId: 'q-pol-2');
      expect(find.text('同错因的其他题 · 概念不清'), findsOneWidget);
      expect(find.text('学术词汇辨析'), findsOneWidget);
      expect(find.text('还有 2 道同错因的题'), findsOneWidget);
      expect(find.text('数学 1 · 英语 1'), findsOneWidget);
      expect(find.text('同知识点的题 · 矛盾观'), findsOneWidget);
      expect(find.text('材料分析：中国式现代化'), findsOneWidget);
      expect(find.text('政治 · 正式复习答对 1 次 · 答错 1 次 · 错因 方法不会'), findsOneWidget);
      expect(find.text('同文件夹 · 平时作业（3 道）'), findsOneWidget);
      expect(find.text('当前第 3 道 · 共 3 道'), findsOneWidget);
    });

    testWidgets('q-math-3：同错因/同知识点都空，只剩文件夹 panel', (tester) async {
      await _pumpB19Detail(tester, questionId: 'q-math-3');
      expect(find.byKey(const Key('related-same-cause')), findsNothing);
      expect(find.byKey(const Key('related-same-kp')), findsNothing);
      expect(find.byKey(const Key('related-same-folder')), findsOneWidget);
      expect(find.text('同文件夹 · 模拟卷（3 道）'), findsOneWidget);
      expect(find.text('当前第 1 道 · 共 3 道'), findsOneWidget);
    });

    testWidgets('窄屏（700px）：右栏落左栏下方，不再是 302px 固定栏', (tester) async {
      await _pumpB19Detail(tester, width: 700, height: 900);
      expect(find.byKey(const Key('detail-right-302')), findsNothing);
      expect(find.text('同错因的其他题 · 概念不清'), findsOneWidget);
      expect(find.text('同文件夹 · 试卷（3 道）'), findsOneWidget);
    });
  });

  group('右栏跳转', () {
    testWidgets('点相关题行进详情：orderIds 为同错因组全量，返回行带分组上下文', (tester) async {
      await _pumpB19Detail(tester);
      await tapB19Text(tester, '学术词汇辨析');
      // 新页返回行：同错因组 [q-eng-1, q-pol-2]，q-eng-1 是第 1/2 道。
      expect(
        find.text('‹ 返回搜索结果（同错因 · 概念不清，第 1/2 道）'),
        findsOneWidget,
      );
      // 下一题按该组全量走：q-pol-2。
      await tapB19TextLast(tester, '下一题 ↓');
      expect(find.text('马原'), findsOneWidget);
      expect(
        find.text('‹ 返回搜索结果（同错因 · 概念不清，第 2/2 道）'),
        findsOneWidget,
      );
    });

    testWidgets('「全部 ›」调 onOpenWrongbookFiltered，传同错因', (tester) async {
      String? gotCause;
      String? gotSubject;
      String? gotKp;
      String? gotFolder;
      await _pumpB19Detail(
        tester,
        onOpenWrongbookFiltered:
            ({String? subjectId, String? cause, String? knowledgePointId, String? folderId}) {
          gotCause = cause;
          gotSubject = subjectId;
          gotKp = knowledgePointId;
          gotFolder = folderId;
        },
      );
      await tapB19Text(tester, '全部 ›');
      expect(gotCause, '概念不清');
      expect(gotSubject, isNull);
      expect(gotKp, isNull);
      expect(gotFolder, isNull);
    });

    testWidgets('「打开列表 ›」调 onOpenWrongbookFiltered，传文件夹 + 学科', (tester) async {
      String? gotCause;
      String? gotSubject;
      String? gotFolder;
      await _pumpB19Detail(
        tester,
        onOpenWrongbookFiltered:
            ({String? subjectId, String? cause, String? knowledgePointId, String? folderId}) {
          gotCause = cause;
          gotSubject = subjectId;
          gotFolder = folderId;
        },
      );
      await tapB19Text(tester, '打开列表 ›');
      expect(gotFolder, 'f1');
      expect(gotSubject, 'math');
      expect(gotCause, isNull);
    });
  });

  group('返回行 searchContext 与编辑入口', () {
    testWidgets('searchContext 非 null 时返回行显示搜索结果 + 第 N/M 道', (tester) async {
      await _pumpB19Detail(
        tester,
        questionId: 'q-eng-1',
        orderIds: const ['q-math-1', 'q-eng-1', 'q-pol-2'],
        searchContext: '数学 · 概念不清 · 未解决',
      );
      expect(
        find.text('‹ 返回搜索结果（数学 · 概念不清 · 未解决，第 2/3 道）'),
        findsOneWidget,
      );
      expect(find.text('返回错题本'), findsNothing);
    });

    testWidgets('searchContext 为 null 时沿用返回{来源}文案', (tester) async {
      await _pumpB19Detail(tester);
      expect(find.text('返回错题本'), findsOneWidget);
      expect(find.text('第 1 / 9 题 · 按错题本当前的顺序'), findsOneWidget);
    });

    testWidgets('编辑入口在题目信息 panel 底部；编辑态左列底部显示保存/取消', (tester) async {
      await _pumpB19Detail(tester);
      expect(find.text('编辑'), findsOneWidget);
      await tapB19Text(tester, '编辑');
      expect(find.text('保存'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('归档'), findsNothing);
      expect(find.text('删除'), findsNothing);
    });
  });
}
