// R8 复习页 widget 测试（十四批 M3 重写）：
// - 列表：按学习状态分组（已逾期复查 → 今日到期复查 → 未解决错因 →
//   已掌握未到期），一题一行；页顶今日待复习 + 开始复习 / 专项练习；
//   学科/题型/错因筛选、分页、已治愈区、未加入盒、空态、恢复条。
// - 三步会话（看题 → 作答 → 核对 → 下一题 → 小结），一道题内部的
//   状态变化；跳过两次留到下次、暂停续接、保存失败横幅。
// - 软件内答题：单选/判断点选 + 客观判分、判分不可用走纸上作答 +
//   补全答案跳转返回、多选只记录不判分、批注开关。
// - 专项练习：选题页、隔离（不调 FSRS、不改到期时间）、空范围、
//   重新加入复习。
// - 亮/深 × 三档无溢出、不用图标字体。
// 用 FakeRepo 覆盖 repository 调用（不碰真实数据库）；核对提交走
// 真实 ReviewNotifier + 默认内存调度器（P1）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/review/review_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';
import 'package:quiz_master2/widgets/widgets.dart';

Question rq(
  String id,
  String title, {
  String subjectId = 'math',
  List<String> errorTypes = const [],
  String? answer,
  String? explanation,
  String? notes,
  DateTime? createdAt,
  bool isOrganized = true,
  bool reviewJoined = false,
  bool isArchived = false,
  String? questionType,
  List<String>? optionLabels,
  bool optionLabelsConfirmed = false,
  String? correctOption,
  List<String> knowledgePointIds = const [],
}) => Question(
  id: id,
  title: title,
  subjectId: subjectId,
  errorTypes: errorTypes,
  answer: answer,
  explanation: explanation,
  notes: notes,
  createdAt: createdAt ?? DateTime(2026, 11, 8),
  isOrganized: isOrganized,
  reviewJoined: reviewJoined,
  isArchived: isArchived,
  sliceKind: 'material',
  sliceText: '题：$title',
  questionType: questionType,
  optionLabels: optionLabels,
  optionLabelsConfirmed: optionLabelsConfirmed,
  correctOption: correctOption,
  knowledgePointIds: knowledgePointIds,
);

CauseRecord rec(
  String questionId,
  String cause, {
  String subjectId = 'math',
  CauseStatus status = CauseStatus.pending,
  int solvedCount = 0,
  DateTime? recheckDate,
  List<String> remedyHistory = const [],
  DateTime? joinedAt,
  int? lastCountedSuccessAt,
  String? lastCountedSessionId,
}) => CauseRecord(
  questionId: questionId,
  cause: cause,
  subjectId: subjectId,
  status: status,
  solvedCount: solvedCount,
  lastCheck: status == CauseStatus.solved ? DateTime(2026, 11, 10) : null,
  recheckDate: recheckDate,
  remedyHistory: remedyHistory,
  joinedAt: joinedAt ?? DateTime(2026, 11, 10),
  lastCountedSuccessAt: lastCountedSuccessAt,
  lastCountedSessionId: lastCountedSessionId,
);

class FakeReviewRepo extends QuestionRepository {
  FakeReviewRepo({
    required this.questions,
    required this.records,
    AppSettings? settings,
    this.throwOnCheck = false,
    List<Subject>? subjects,
  }) : settingsValue = settings ?? AppSettings.defaults,
       subjectsValue = subjects ?? Subject.all,
       super(AppDatabase.instance);

  List<Question> questions;
  List<CauseRecord> records;
  AppSettings settingsValue;
  int saveSettingsCalls = 0;
  bool throwOnCheck;
  List<Subject> subjectsValue;
  ReviewSessionState? savedState;

  /// SR-P2-48：错误态测试用——设置后 settings() 抛错，模拟读库失败。
  bool throwOnLoad = false;

  final Map<String, List<({String result, DateTime reviewedAt})>> history = {};
  final Map<String, AttemptData> attempts = {};

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);

  @override
  Future<AppSettings> settings() async {
    if (throwOnLoad) throw StateError('boom');
    return settingsValue;
  }

  @override
  Future<void> saveSettings(AppSettings s) async {
    saveSettingsCalls++;
    settingsValue = s;
  }

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
    String questionId,
  ) async => List.of(history[questionId] ?? const []);

  @override
  Future<ReviewSessionState?> reviewState() async => savedState;

  @override
  Future<void> saveReviewState({
    required List<ReviewQueueItem> queue,
    required int position,
    String? sessionId,
    String? mode,
    Map<String, int>? skips,
    Map<String, Map<String, Object?>>? perQuestionState,
  }) async => savedState = ReviewSessionState(
    queue: queue,
    position: position,
    updatedAt: DateTime.now(),
    sessionId: sessionId,
    mode: mode,
    skips: skips ?? const {},
    perQuestionState: perQuestionState ?? const {},
  );

  @override
  Future<void> clearReviewState() async {
    savedState = null;
  }

  @override
  Future<String> recordAttempt(AttemptData attempt) async {
    if (throwOnCheck) throw StateError('save failed');
    attempts['${attempt.sessionId}|${attempt.questionId}'] = attempt;
    return attempt.id;
  }

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [
    KnowledgePoint(
      id: 'kp-lim',
      subjectId: 'math',
      chapter: '第一章',
      name: '函数极限',
    ),
  ];

  @override
  Future<AttemptData?> loadAttempt({
    required String sessionId,
    required String questionId,
  }) async =>
      attempts['$sessionId|$questionId'];

  @override
  Future<List<AttemptData>> loadAttemptsForSession(
          String sessionId) async =>
      attempts.values.where((a) => a.sessionId == sessionId).toList();

  @override
  Future<void> rejoinCause({
    required String questionId,
    required String cause,
    required String subjectId,
  }) async {
    final qi = questions.indexWhere((q) => q.id == questionId);
    if (qi >= 0) {
      questions[qi] = questions[qi].copyWith(reviewJoined: true);
    }
    final i = records.indexWhere(
        (x) => x.questionId == questionId && x.cause == cause);
    if (i < 0) {
      records.add(CauseRecord(
        questionId: questionId,
        cause: cause,
        subjectId: subjectId,
        joinedAt: DateTime.now(),
      ));
      return;
    }
    if (records[i].status == CauseStatus.solved) {
      records[i] = records[i].copyWith(
        status: CauseStatus.inProgress,
        solvedCount: 0,
        lastCheck: DateTime.now(),
        clearRecheckDate: true,
        clearCountedAnchors: true,
      );
    }
  }

  @override
  Future<CauseRecord> saveRemedy(CauseRecord r, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return r;
    final now = DateTime.now();
    final entry = '${now.year}-${now.month}-${now.day}：$trimmed';
    final updated = r.copyWith(remedyHistory: [entry, ...r.remedyHistory]);
    final i = records.indexWhere(
      (x) => x.questionId == r.questionId && x.cause == r.cause,
    );
    if (i >= 0) records[i] = updated;
    return updated;
  }
}

FakeReviewRepo reviewRepo({int pageSize = 10}) {
  final now = DateTime(2026, 11, 10);
  return FakeReviewRepo(
    settings: AppSettings.defaults.copyWith(pageSize: pageSize),
    questions: [
      rq(
        'q1',
        '函数极限',
        errorTypes: const ['概念不清'],
        answer: '3',
        explanation: 'lim sin3x/x = 3。',
        notes: '当时没看清题目。',
        createdAt: DateTime(2026, 11, 8),
        reviewJoined: true,
      ),
      rq(
        'q2',
        '导数应用综合',
        errorTypes: const ['方法不会', '计算错误'],
        answer: '见解析',
        explanation: '先求导，再列表。',
        createdAt: DateTime(2026, 11, 9),
        reviewJoined: true,
      ),
      rq(
        'q3',
        '学术词汇辨析',
        subjectId: 'english',
        errorTypes: const ['概念不清'],
        createdAt: DateTime(2026, 11, 7),
        reviewJoined: true,
      ),
      rq(
        'q4',
        '马原',
        subjectId: 'politics',
        errorTypes: const ['概念不清'],
        createdAt: DateTime(2026, 11, 6),
      ),
      rq(
        'q5',
        '未整理题',
        errorTypes: const ['方法不会'],
        createdAt: DateTime(2026, 11, 5),
        isOrganized: false,
        reviewJoined: true,
      ),
    ],
    records: [
      rec('q1', '概念不清', joinedAt: now),
      rec(
        'q2',
        '方法不会',
        status: CauseStatus.inProgress,
        solvedCount: 1,
        joinedAt: now.add(const Duration(hours: 1)),
      ),
      rec('q2', '计算错误', joinedAt: now.add(const Duration(hours: 1))),
      rec(
        'q3',
        '概念不清',
        subjectId: 'english',
        status: CauseStatus.solved,
        solvedCount: 2,
        recheckDate: DateTime.now().add(const Duration(days: 7)),
        remedyHistory: const ['2026-11-10：把词根表抄了一遍'],
        joinedAt: now.subtract(const Duration(hours: 1)),
      ),
      rec('q5', '方法不会', joinedAt: now),
    ],
  );
}

/// SR3-17：跨学科同错因库——在 reviewRepo() 基础上加一道英语题 q6，
/// 待治错因同样是“计算错误”。错因筛选“计算错误”进会话时，队列是
/// q2（数学）+ q6（英语），共 2 道题。
FakeReviewRepo crossSubjectRepo() {
  final repo = reviewRepo();
  final now = DateTime(2026, 11, 10);
  repo.questions = [
    ...repo.questions,
    rq(
      'q6',
      '英语完形填空',
      subjectId: 'english',
      errorTypes: const ['计算错误'],
      createdAt: DateTime(2026, 11, 9),
      reviewJoined: true,
    ),
  ];
  repo.records = [
    ...repo.records,
    rec(
      'q6',
      '计算错误',
      subjectId: 'english',
      joinedAt: now.add(const Duration(hours: 2)),
    ),
  ];
  return repo;
}

/// 只有 q1 一道待治题的库（单题会话）。
FakeReviewRepo singleRepo() {
  final repo = reviewRepo();
  repo.questions = [
    rq(
      'q1',
      '函数极限',
      errorTypes: const ['概念不清'],
      answer: '3',
      explanation: 'lim sin3x/x = 3。',
      notes: '当时没看清题目。',
      createdAt: DateTime(2026, 11, 8),
      reviewJoined: true,
    ),
  ];
  repo.records = [
    rec('q1', '概念不清', joinedAt: DateTime(2026, 11, 10)),
  ];
  return repo;
}

/// 单选题库：标签已确认（或未确认）+ 正确答案 B，供客观判分测试。
/// WP-A #1 收尾：correctOption 可空——未设正确答案时判分不可用，
/// 走纸上作答（不再由 optionLabelsConfirmed 决定）。
FakeReviewRepo choiceRepo({bool labelsConfirmed = true, String? correctOption = 'B'}) {
  final repo = reviewRepo();
  repo.questions = [
    rq(
      'q1',
      '函数极限',
      errorTypes: const ['概念不清'],
      answer: '3',
      explanation: 'lim sin3x/x = 3。',
      notes: '当时没看清题目。',
      createdAt: DateTime(2026, 11, 8),
      reviewJoined: true,
      questionType: 'choice_single',
      optionLabels: const ['A', 'B', 'C', 'D'],
      optionLabelsConfirmed: labelsConfirmed,
      correctOption: correctOption,
      knowledgePointIds: const ['kp-lim'],
    ),
  ];
  repo.records = [
    rec('q1', '概念不清', joinedAt: DateTime(2026, 11, 10)),
  ];
  return repo;
}

/// 多选题库：标签已确认，正确答案写 answer 字段，不自动判分。
/// WP-A #1 收尾：labelsConfirmed 可关——多选门禁只看标签是否齐全，
/// 不读确认列。
FakeReviewRepo multiRepo({bool labelsConfirmed = true}) {
  final repo = reviewRepo();
  repo.questions = [
    rq(
      'q1',
      '函数极限',
      errorTypes: const ['概念不清'],
      answer: 'B、C',
      explanation: '两项都对。',
      createdAt: DateTime(2026, 11, 8),
      reviewJoined: true,
      questionType: 'choice_multi',
      optionLabels: const ['A', 'B', 'C', 'D'],
      optionLabelsConfirmed: labelsConfirmed,
    ),
  ];
  repo.records = [
    rec('q1', '概念不清', joinedAt: DateTime(2026, 11, 10)),
  ];
  return repo;
}

/// B6：库里多一道已归档但已加入复习的题（q9）；取消归档用时把
/// 同一道题的 isArchived 改回 false 即可。
FakeReviewRepo archivedRepo({bool archived = true}) {
  final repo = reviewRepo();
  repo.questions = [
    ...repo.questions,
    rq(
      'q9',
      '已归档题',
      errorTypes: const ['概念不清'],
      createdAt: DateTime(2026, 11, 9),
      reviewJoined: true,
      isArchived: archived,
    ),
  ];
  repo.records = [
    ...repo.records,
    rec('q9', '概念不清', joinedAt: DateTime(2026, 11, 9)),
  ];
  return repo;
}

Future<void> pumpReview(
  WidgetTester tester, {
  FakeReviewRepo? repo,
  Brightness brightness = Brightness.light,
  double scale = 1.0,
  String? initialSubjectId,
  Future<void> Function(Question q, List<String> ids)? onOpenDetail,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final opened = <Question>[];
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
              body: ReviewPage(
                key: UniqueKey(),
                repo: repo ?? reviewRepo(),
                initialSubjectId: initialSubjectId,
                onOpenDetail: (q, ids, {String? searchContext}) async {
                  opened.add(q);
                  if (onOpenDetail != null) await onOpenDetail(q, ids);
                },
                onGoWrongbook: () {},
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tapText(
  WidgetTester tester,
  String text, {
  bool first = false,
}) async {
  final finder = first ? find.text(text).first : find.text(text);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> tapButton(WidgetTester tester, String label, {int at = 0}) async {
  final finder = find.widgetWithText(QmButton, label);
  await tester.ensureVisible(finder.at(at));
  await tester.pumpAndSettle();
  await tester.tap(finder.at(at));
  await tester.pumpAndSettle();
}

/// 点下拉里的菜单项（按 DropdownMenuItem 的 value 精确定位）。
/// 菜单打开时 value 相同的 DropdownMenuItem 有两个：按钮上显示的
/// 当前值与菜单里的项，后者在树里居后，取 .last 才是菜单项
/// （错题本分页测试同款做法）。
Future<void> pickMenuItem<T>(
  WidgetTester tester,
  Finder dropdown,
  T value,
) async {
  await tester.ensureVisible(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  final item = find
      .byWidgetPredicate(
        (w) => w is DropdownMenuItem<T> && w.value == value,
      )
      .last;
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(item);
  await tester.pumpAndSettle();
}

/// 纸上作答的题走完“看题 → 作答 → 核对”三段。
Future<void> walkPaperToCheck(WidgetTester tester) async {
  await tapButton(tester, '开始作答');
  await tapButton(tester, '我已完成作答');
}

/// 单选题走完“看题 → 作答（点选 + 提交）→ 核对”。
Future<void> walkObjectiveToCheck(
  WidgetTester tester, {
  required String option,
}) async {
  await tapButton(tester, '开始作答');
  await tapButton(tester, option);
  await tapButton(tester, '提交答案');
}

void main() {
  group('列表', () {
    testWidgets('按学习状态分组、一题一行：题名 + 错因名 + 状态', (tester) async {
      await pumpReview(tester);
      expect(find.text('未解决错因'), findsOneWidget);
      expect(find.text('函数极限'), findsOneWidget);
      expect(find.text('导数应用综合'), findsOneWidget);
      expect(find.text('学术词汇辨析'), findsOneWidget); // 已掌握未到期
      expect(find.text('已掌握未到期'), findsOneWidget);
      // 错因名在行副标题里：q1 一处 + q3（已掌握行）一处 + 已治愈行一处。
      expect(find.textContaining('概念不清'), findsNWidgets(3));
      expect(find.textContaining('方法不会'), findsOneWidget);
      expect(find.textContaining('计算错误'), findsOneWidget);
      expect(find.textContaining('关联 1 道题'), findsOneWidget);
      expect(find.text('已解决'), findsOneWidget); // 已治愈行 pill
      // 未整理的题不在列表里；未加入的题只在“还没加入复习”盒里。
      expect(find.text('未整理题'), findsNothing);
      expect(find.textContaining('还没加入复习的题'), findsOneWidget);
      expect(find.textContaining('政治「马原」'), findsOneWidget);
    });

    testWidgets('页顶：今日待复习 2 道题 / 3 个错因 + 开始复习 / 专项练习', (tester) async {
      await pumpReview(tester);
      expect(find.textContaining('今日待复习'), findsOneWidget);
      expect(find.textContaining('2 道题 / 3 个错因'), findsOneWidget);
      expect(find.widgetWithText(QmButton, '开始复习'), findsOneWidget);
      expect(find.widgetWithText(QmButton, '专项练习'), findsOneWidget);
    });

    testWidgets('元信息行：待解决/解决中 2 道题 · 已解决 1 道', (tester) async {
      await pumpReview(tester);
      // B9-4（Meng 2026-11-15 ~19:43 裁决：与角标 / 首页统一，按题数）：
      // 种子库待治 3 条错因记录分属 2 道题（q1 1 条、q2 2 条），
      // 页顶按题计是 2 道题，不是 3 条；q3 已解决（复查日未到）计 1 道。
      expect(find.text('待解决 / 解决中 2 道题'), findsOneWidget);
      expect(find.text('已解决 1 道'), findsOneWidget);
      expect(find.textContaining('列表按加入时间排，先加入的先解决'), findsOneWidget);
    });

    testWidgets('B6：已归档的已加入题不在复习列表里，取消归档后回来', (tester) async {
      await pumpReview(tester, repo: archivedRepo());
      expect(find.textContaining('已归档题'), findsNothing);
      // 归档题的记录保留在库里（只是列表不显示），取消归档即回来。
      await pumpReview(tester, repo: archivedRepo(archived: false));
      expect(find.textContaining('已归档题'), findsOneWidget);
    });

    testWidgets('无外层卡片框、无 Icon', (tester) async {
      await pumpReview(tester);
      expect(find.byType(Icon), findsNothing);
      expect(find.byType(Card), findsNothing);
    });

    testWidgets('学科筛选：只留英语组，数学行消失，已掌握行与已治愈组仍在', (tester) async {
      await pumpReview(tester);
      await pickMenuItem<String>(
        tester,
        find.byType(DropdownButton<String>).first,
        'english',
      );
      expect(find.text('函数极限'), findsNothing);
      expect(find.text('导数应用综合'), findsNothing);
      expect(find.text('学术词汇辨析'), findsOneWidget); // 已掌握未到期行
      expect(find.textContaining('概念不清'), findsNWidgets(2)); // 已掌握行 + 已治愈行
      expect(find.text('方法不会'), findsNothing);
    });

    testWidgets('错因筛选：只留计算错误组', (tester) async {
      await pumpReview(tester);
      await pickMenuItem<String>(
        tester,
        find.byType(DropdownButton<String>).last,
        '计算错误',
      );
      // 下拉框当前值一个“计算错误”；行副标题里还有一个。
      expect(find.text('计算错误'), findsOneWidget);
      expect(find.textContaining('计算错误'), findsNWidgets(2));
      expect(find.text('方法不会'), findsNothing);
      expect(find.text('导数应用综合'), findsOneWidget);
      expect(find.text('函数极限'), findsNothing);
    });

    testWidgets('分页：每页 1 条共 3 页，翻页后筛选回第 1 页', (tester) async {
      await pumpReview(tester, repo: reviewRepo(pageSize: 1));
      // 待治 2 行 + 已掌握 1 行 = 3 行。
      expect(find.text('共 3 条 · 第 1 / 3 页'), findsOneWidget);
      expect(find.text('导数应用综合'), findsNothing); // 第 2 行在第 2 页
      await tapButton(tester, '下一页');
      expect(find.text('共 3 条 · 第 2 / 3 页'), findsOneWidget);
      expect(find.text('导数应用综合'), findsOneWidget);
      await pickMenuItem<String>(
        tester,
        find.byType(DropdownButton<String>).last,
        '计算错误',
      );
      expect(find.text('共 1 条 · 第 1 / 1 页'), findsOneWidget);
      expect(find.text('计算错误'), findsOneWidget);
    });

    testWidgets('每页数量可改：改成 20 条后只剩 1 页，设置默认值不动（P0B2 本地行为）', (tester) async {
      final repo = reviewRepo(pageSize: 1);
      await pumpReview(tester, repo: repo);
      expect(find.text('共 3 条 · 第 1 / 3 页'), findsOneWidget);
      await pickMenuItem<int>(tester, find.byType(DropdownButton<int>), 20);
      expect(find.text('共 3 条 · 第 1 / 1 页'), findsOneWidget);
      // 本地行为：只改本页显示，不写库、不改设置默认值。
      expect(repo.settingsValue.pageSize, 1);
      expect(repo.saveSettingsCalls, 0);
    });

    testWidgets('S8A6 大库 55 组：五档页数与末页条数', (tester) async {
      // 与真机大库同口径：55 道题已加入复习；复习列表按题分组，
      // 固定错因只有 5 种会并组，所以每题给一个唯一自定义错因，
      // 55 道题即 55 行。加入时间递增，行顺序即题号顺序。
      final base = DateTime(2026, 11, 10);
      final repo = FakeReviewRepo(
        questions: [
          for (var i = 0; i < 55; i++)
            Question(
              id: 'b$i',
              title: '分页题 $i',
              subjectId: 'math',
              customErrorTypes: ['分页错因 $i'],
              createdAt: base.subtract(Duration(hours: 55 - i)),
              isOrganized: true,
              reviewJoined: true,
              sliceKind: 'material',
              sliceText: '题：分页题 $i',
            ),
        ],
        records: [
          for (var i = 0; i < 55; i++)
            rec('b$i', '分页错因 $i', joinedAt: base.add(Duration(minutes: i))),
        ],
      );
      await pumpReview(tester, repo: repo);
      // 每档：每页数 → 总页数 / 末页首行 / 上一页末行（不在末页）。
      const cases = [
        (10, 6, '分页错因 50', '分页错因 49'),
        (20, 3, '分页错因 40', '分页错因 39'),
        (30, 2, '分页错因 30', '分页错因 29'),
        (40, 2, '分页错因 40', '分页错因 39'),
        (50, 2, '分页错因 50', '分页错因 49'),
      ];
      for (final (size, pages, first, before) in cases) {
        if (size != 10) {
          await pickMenuItem<int>(
            tester,
            find.byType(DropdownButton<int>),
            size,
          );
        }
        expect(find.text('共 55 条 · 第 1 / $pages 页'), findsOneWidget);
        for (var p = 1; p < pages; p++) {
          await tapButton(tester, '下一页');
        }
        expect(find.text('共 55 条 · 第 $pages / $pages 页'), findsOneWidget);
        expect(find.textContaining(first), findsOneWidget);
        expect(find.textContaining('分页错因 54'), findsOneWidget);
        expect(find.textContaining(before), findsNothing);
      }
    });

    testWidgets('已治愈组：点一行展开看解决记录，再点收起', (tester) async {
      await pumpReview(tester);
      expect(find.textContaining('解决于'), findsNothing);
      await tapText(tester, '解决记录');
      expect(find.textContaining('解决于 2026-11-10'), findsOneWidget);
      expect(find.textContaining('下次复查'), findsOneWidget);
      expect(find.textContaining('补救记录：2026-11-10：把词根表抄了一遍'), findsOneWidget);
      await tapText(tester, '收起');
      expect(find.textContaining('解决于'), findsNothing);
    });

    testWidgets('空态：没有加入复习的题', (tester) async {
      final repo = reviewRepo();
      repo.questions = [rq('q9', '马原', subjectId: 'politics')];
      repo.records = [];
      await pumpReview(tester, repo: repo);
      expect(find.text('复习列表还是空的'), findsOneWidget);
      expect(find.text('去错题本选题'), findsOneWidget);
    });

    testWidgets('空状态：今天没有到期复习', (tester) async {
      // 只有已掌握未到期（q3）与未加入题：到期池为空。
      final repo = reviewRepo();
      repo.questions = [repo.questions[2], repo.questions[3]];
      repo.records = [repo.records[3]];
      await pumpReview(tester, repo: repo);
      expect(find.textContaining('今天没有到期复习'), findsOneWidget);
      expect(find.textContaining('正在等待未来复查的错因有 1 个'), findsOneWidget);
      expect(find.widgetWithText(QmButton, '去专项练习'), findsOneWidget);
      expect(find.widgetWithText(QmButton, '查看已掌握题目'), findsOneWidget);
      await tapButton(tester, '查看已掌握题目');
      expect(find.textContaining('关联 1 道题'), findsOneWidget);
    });

    testWidgets('无旧翻卡模型：不出现“下次复习时间”', (tester) async {
      await pumpReview(tester);
      expect(find.textContaining('下次复习时间'), findsNothing);
      expect(find.textContaining('翻卡'), findsNothing);
    });

    testWidgets('FR-10：按学科排时括号现拼学科名，不写死预设三科', (tester) async {
      final repo = reviewRepo();
      repo.settingsValue = repo.settingsValue.copyWith(reviewSort: 'subject');
      repo.subjectsValue = [
        Subject.math,
        Subject(id: 'chem', name: '化学', color: Subject.math.color, icon: '化'),
      ];
      await pumpReview(tester, repo: repo);
      expect(find.text('列表按学科排（数学、化学），同一科里先加入的先解决'), findsOneWidget);
      expect(find.textContaining('数学 / 英语 / 政治'), findsNothing);
    });

    testWidgets('FR-10：学科超过 3 科时只列前 3 科 +“等”', (tester) async {
      final repo = reviewRepo();
      repo.settingsValue = repo.settingsValue.copyWith(reviewSort: 'subject');
      repo.subjectsValue = [
        Subject.math,
        Subject.english,
        Subject.politics,
        Subject(id: 'chem', name: '化学', color: Subject.math.color, icon: '化'),
      ];
      await pumpReview(tester, repo: repo);
      expect(find.text('列表按学科排（数学、英语、政治等），同一科里先加入的先解决'), findsOneWidget);
    });
  });

  group('会话三步', () {
    testWidgets('三步走完一题：看题 → 作答 → 核对 → 下一题 → 小结', (tester) async {
      await pumpReview(tester, repo: singleRepo());
      await tapButton(tester, '开始复习');
      expect(find.textContaining('第 1 / 1 道题'), findsOneWidget);
      expect(find.textContaining('本轮共 1 道题、1 个错因'), findsOneWidget);
      expect(find.text('① 看题'), findsOneWidget);
      await walkPaperToCheck(tester);
      expect(find.text('③ 核对'), findsOneWidget);
      expect(find.textContaining('lim sin3x/x = 3。'), findsOneWidget);
      await tapButton(tester, '确认核对，下一题');
      expect(find.text('本轮复习总结'), findsOneWidget);
      expect(
        find.textContaining('完成 1 道题 · 答对 0 道 · 答错 0 道 · 未判分 1 道'),
        findsOneWidget,
      );
      expect(find.textContaining('用时'), findsOneWidget);
      expect(find.text('本次没有按知识点排出的薄弱点。'), findsOneWidget);
      await tapButton(tester, '回复习列表');
      expect(find.text('复习列表还是空的'), findsNothing);
      expect(find.textContaining('概念不清'), findsOneWidget); // 单题库：仅待治行
    });

    testWidgets('跳过单题队列直接留到下次：不写 attempt，进总结', (tester) async {
      await pumpReview(tester, repo: singleRepo());
      await tapButton(tester, '开始复习');
      await tapButton(tester, '跳过');
      // 单题队列：第一次跳过不能马上再次出现，直接留到下次出总结。
      expect(find.text('本轮复习总结'), findsOneWidget);
      expect(find.text('本次没有按知识点排出的薄弱点。'), findsOneWidget);
      expect(find.textContaining('留待下次 1 道'), findsOneWidget);
    });

    testWidgets('暂停后列表出恢复条：继续上次会话回到中断的题', (tester) async {
      final repo = reviewRepo();
      await pumpReview(tester, repo: repo);
      await tapButton(tester, '开始复习');
      await tapButton(tester, '暂停');
      expect(find.textContaining('继续上次会话'), findsNWidgets(2)); // 恢复条文案 + 按钮
      expect(find.text('放弃重开'), findsOneWidget);
      expect(repo.savedState, isNotNull);
      await tapButton(tester, '继续上次会话');
      expect(find.textContaining('第 1 / 2 道题'), findsOneWidget);
      expect(find.text('① 看题'), findsOneWidget);
    });

    testWidgets('单活动会话：暂停会话时开另一模式先二选一', (tester) async {
      final repo = reviewRepo();
      await pumpReview(tester, repo: repo);
      await tapButton(tester, '开始复习');
      await tapButton(tester, '暂停');
      // 开专项练习：先弹二选一，不直接进选题页。
      await tapButton(tester, '专项练习');
      expect(find.textContaining('有一个暂停的学习会话'), findsOneWidget);
      // 选“继续上次会话”（对话框里的按钮）：回到中断的到期复习。
      final dialogContinue = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('继续上次会话'),
      );
      await tester.tap(dialogContinue);
      await tester.pumpAndSettle();
      expect(find.textContaining('第 1 / 2 道题'), findsOneWidget);
      // 再暂停、再开专项练习，选“放弃上次会话”：旧断点清掉，进选题页。
      await tapButton(tester, '暂停');
      await tapButton(tester, '专项练习');
      // 对话框按钮是 TextButton（不是 QmButton），直接点文本。
      await tester.tap(find.text('放弃上次会话'));
      await tester.pumpAndSettle();
      expect(find.text('专项练习'), findsOneWidget);
      expect(repo.savedState, isNull);
    });

    testWidgets('放大浮层：点题图弹出，标题“整题图 · 放大查看”', (tester) async {
      await pumpReview(tester, repo: singleRepo());
      await tapButton(tester, '开始复习');
      await tester.tap(find.byType(QuestionSlice).first);
      await tester.pumpAndSettle();
      expect(find.text('整题图 · 放大查看'), findsOneWidget);
      await tapButton(tester, '关闭 ×');
      expect(find.text('整题图 · 放大查看'), findsNothing);
    });

    testWidgets('保存失败：核对提交抛错，出错误横幅并留在核对步', (tester) async {
      final repo = singleRepo();
      repo.throwOnCheck = true;
      await pumpReview(tester, repo: repo);
      await tapButton(tester, '开始复习');
      await walkPaperToCheck(tester);
      await tapButton(tester, '确认核对，下一题');
      expect(find.textContaining('复习记录保存失败'), findsOneWidget);
      expect(find.text('③ 核对'), findsOneWidget);
      expect(find.text('本轮复习总结'), findsNothing);
    });

    testWidgets('批注默认隐藏：显示笔记后出提示横条，再隐藏', (tester) async {
      await pumpReview(tester, repo: singleRepo());
      await tapButton(tester, '开始复习');
      expect(find.textContaining('已显示笔记'), findsNothing);
      await tapButton(tester, '显示笔记');
      expect(find.text('已显示笔记（含你自己的提示）'), findsOneWidget);
      await tapButton(tester, '隐藏笔记');
      expect(find.textContaining('已显示笔记'), findsNothing);
    });
  });

  group('软件内答题', () {
    testWidgets('单选点选 + 客观判分：答对进 FSRS，下次时间按 FSRS 算', (tester) async {
      await pumpReview(tester, repo: choiceRepo());
      await tapButton(tester, '开始复习');
      await walkObjectiveToCheck(tester, option: 'B');
      expect(find.text('回答正确'), findsOneWidget);
      await tapButton(tester, '确认核对，下一题');
      expect(find.text('本轮复习总结'), findsOneWidget);
      expect(
        find.textContaining('完成 1 道题 · 答对 1 道 · 答错 0 道 · 未判分 0 道'),
        findsOneWidget,
      );
      expect(find.textContaining('下次复习最早'), findsOneWidget);
    });

    testWidgets('单选点选：答错进薄弱点', (tester) async {
      await pumpReview(tester, repo: choiceRepo());
      await tapButton(tester, '开始复习');
      await walkObjectiveToCheck(tester, option: 'A');
      expect(find.text('回答错误'), findsOneWidget);
      await tapButton(tester, '确认核对，下一题');
      expect(find.text('本轮复习总结'), findsOneWidget);
      expect(
        find.textContaining('完成 1 道题 · 答对 0 道 · 答错 1 道 · 未判分 0 道'),
        findsOneWidget,
      );
      expect(find.textContaining('薄弱点（按答错题数排）：'), findsOneWidget);
      expect(find.text('函数极限'), findsOneWidget); // 知识点名
      expect(find.text('答错 1 道'), findsOneWidget);
    });

    testWidgets('配置有效但未确认的单选题显示选项按钮（不读确认列）', (tester) async {
      final repo = choiceRepo(labelsConfirmed: false);
      await pumpReview(tester, repo: repo);
      await tapButton(tester, '开始复习');
      await tapButton(tester, '开始作答');
      // 标签 [A,B,C,D] + 正确答案 B 齐全：objectiveGradingAvailable
      // 为 true，确认列为 false 也不应挡住选项按钮。
      expect(find.widgetWithText(QmButton, 'A'), findsOneWidget);
      expect(find.textContaining('选项标签尚未确认'), findsNothing);
      expect(find.textContaining('未配置有效答案'), findsNothing);
      await tapButton(tester, 'B');
      await tapButton(tester, '提交答案');
      expect(find.text('回答正确'), findsOneWidget);
    });

    testWidgets('未设正确答案：不显示选项按钮，走纸上作答；补全答案后返回会话继续点选', (tester) async {
      final repo = choiceRepo(labelsConfirmed: false, correctOption: null);
      await pumpReview(
        tester,
        repo: repo,
        onOpenDetail: (q, ids, {String? searchContext}) async {
          // 模拟详情页补全答案：填上正确答案 B（确认列不动，仍为 false）。
          final i = repo.questions.indexWhere((x) => x.id == q.id);
          repo.questions[i] = repo.questions[i].copyWith(correctOption: 'B');
        },
      );
      await tapButton(tester, '开始复习');
      await tapButton(tester, '开始作答');
      expect(find.textContaining('未配置有效答案'), findsOneWidget);
      expect(find.textContaining('选项标签尚未确认'), findsNothing);
      expect(find.widgetWithText(QmButton, 'A'), findsNothing);
      expect(find.widgetWithText(QmButton, '补全答案'), findsOneWidget);
      await tapButton(tester, '补全答案');
      // 返回会话：沿用同一会话，不出“继续上次会话”选择，回到看题步。
      expect(find.textContaining('继续上次会话'), findsNothing);
      expect(find.textContaining('第 1 / 1 道题'), findsOneWidget);
      await tapButton(tester, '开始作答');
      expect(find.widgetWithText(QmButton, 'A'), findsOneWidget);
      await tapButton(tester, 'B');
      await tapButton(tester, '提交答案');
      expect(find.text('回答正确'), findsOneWidget);
    });

    testWidgets('多选：标签未确认但标签齐全时仍显示选项按钮（不读确认列）', (tester) async {
      await pumpReview(tester, repo: multiRepo(labelsConfirmed: false));
      await tapButton(tester, '开始复习');
      await tapButton(tester, '开始作答');
      expect(find.widgetWithText(QmButton, 'B'), findsOneWidget);
      expect(find.textContaining('选项标签尚未确认'), findsNothing);
      await tapButton(tester, 'B');
      await tapButton(tester, 'C');
      expect(find.textContaining('不自动判分'), findsOneWidget);
      await tapButton(tester, '提交答案');
      expect(find.textContaining('B、C'), findsOneWidget);
    });

    testWidgets('多选只记录选择、不自动判分', (tester) async {
      await pumpReview(tester, repo: multiRepo());
      await tapButton(tester, '开始复习');
      await tapButton(tester, '开始作答');
      // 多选没有置信度采集；只记录选择、不自动判分。
      expect(find.text('这次作答有多大把握？'), findsNothing);
      await tapButton(tester, 'B');
      await tapButton(tester, 'C');
      expect(find.textContaining('不自动判分'), findsOneWidget);
      await tapButton(tester, '提交答案');
      expect(find.textContaining('B、C'), findsOneWidget);
    });

    testWidgets('未选选项提交按钮不可点：选了选项后可点', (tester) async {
      await pumpReview(tester, repo: choiceRepo());
      await tapButton(tester, '开始复习');
      await tapButton(tester, '开始作答');
      final submit =
          find.widgetWithText(QmButton, '提交答案').evaluate().first.widget
              as QmButton;
      expect(submit.onPressed, isNull);
      await tapButton(tester, 'B');
      final submit2 =
          find.widgetWithText(QmButton, '提交答案').evaluate().first.widget
              as QmButton;
      expect(submit2.onPressed, isNotNull);
    });
  });

  group('专项练习', () {
    testWidgets('选题页 → 会话 → 小结：不改变到期时间', (tester) async {
      final repo = reviewRepo();
      await pumpReview(tester, repo: repo);
      await tapButton(tester, '专项练习');
      expect(find.text('专项练习'), findsOneWidget);
      expect(find.textContaining('本次练习不改变到期时间'), findsOneWidget);
      await tapButton(tester, '加入时间');
      await tapButton(tester, '开始练习');
      // 4 道题、4 个错因：q1 1 个 + q2 2 个 + q3 1 个 + q4 0 个
      //（q4 无错因记录；q5 不在池内）。
      expect(find.textContaining('本轮共 4 道题、4 个错因'), findsOneWidget);
      expect(find.textContaining('专项练习：本次练习不改变到期时间'), findsOneWidget);
      for (var i = 0; i < 4; i++) {
        await tapButton(tester, '开始作答');
        await tapButton(tester, '我已完成作答');
        await tapButton(tester, '下一题');
      }
      expect(find.text('本次专项练习小结'), findsOneWidget);
      expect(find.textContaining('本次练习不改变到期时间'), findsOneWidget);
      expect(repo.records.firstWhere((r) => r.questionId == 'q1').solvedCount, 0);
    });

    testWidgets('所选范围无题：专项练习空状态，不进空白会话', (tester) async {
      await pumpReview(tester);
      await tapButton(tester, '专项练习');
      await pickMenuItem<String>(
        tester,
        find.byType(DropdownButton<String>).first,
        'politics',
      );
      await pickMenuItem<String>(
        tester,
        find.byType(DropdownButton<String>).last,
        '计算错误',
      );
      await tapButton(tester, '开始练习');
      expect(find.textContaining('该范围内没有可练的题，换个范围试试'), findsOneWidget);
      expect(find.textContaining('第 1 /'), findsNothing);
      await tapButton(tester, '返回选题页');
      expect(find.textContaining('该范围内没有可练的题'), findsNothing);
      expect(find.text('专项练习'), findsOneWidget);
    });

    testWidgets('专项练习重新加入复习：已治愈错因回到解决中', (tester) async {
      final repo = reviewRepo();
      await pumpReview(tester, repo: repo);
      await tapButton(tester, '专项练习');
      await pickMenuItem<String>(
        tester,
        find.byType(DropdownButton<String>).first,
        'english',
      );
      await tapButton(tester, '开始练习');
      await tapButton(tester, '开始作答');
      await tapButton(tester, '我已完成作答');
      await tapButton(tester, '将此错因重新加入复习');
      expect(find.textContaining('已重新加入复习'), findsOneWidget);
      final record =
          repo.records.firstWhere((r) => r.questionId == 'q3');
      expect(record.status, CauseStatus.inProgress);
      expect(record.solvedCount, 0);
    });
  });

  group('B5 SR-P1-12 / SR-P1-13', () {
    testWidgets('SR-P1-12：复习每页条数改后，进会话再暂停回列表，仍保留', (tester) async {
      final repo = reviewRepo(pageSize: 1);
      await pumpReview(tester, repo: repo);
      expect(find.text('共 3 条 · 第 1 / 3 页'), findsOneWidget);
      await pickMenuItem<int>(tester, find.byType(DropdownButton<int>), 20);
      expect(find.text('共 3 条 · 第 1 / 1 页'), findsOneWidget);
      // 进会话再暂停：load() 重读列表，旧代码会在此把页数弹回默认值。
      await tapButton(tester, '开始复习');
      await tapButton(tester, '暂停');
      expect(find.text('共 3 条 · 第 1 / 1 页'), findsOneWidget);
      expect(repo.settingsValue.pageSize, 1);
    });
  });

  group('亮/深 × 三档无溢出', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      for (final scale in [1.0, 1.15, 1.3]) {
        testWidgets(
          '${brightness == Brightness.light ? '亮' : '深'} × $scale 列表 + 会话无溢出',
          (tester) async {
            await pumpReview(tester, brightness: brightness, scale: scale);
            expect(tester.takeException(), isNull);
            await tapButton(tester, '开始复习');
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tapButton(tester, '开始作答');
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tapButton(tester, '我已完成作答');
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  });

  group('B5-P2 复习', () {
    testWidgets('SR-P2-39 未加入盒只列真能加入的题：未整理、无错因不进', (tester) async {
      final repo = reviewRepo();
      repo.questions = [
        ...repo.questions,
        rq('q6', '未整理新题', errorTypes: const ['概念不清'], isOrganized: false),
        rq('q7', '无错因题', errorTypes: const []),
        rq('q8', '新加入候选题', errorTypes: const ['方法不会']),
      ];
      await pumpReview(tester, repo: repo);
      expect(find.textContaining('数学「新加入候选题」'), findsOneWidget);
      expect(find.textContaining('政治「马原」'), findsOneWidget);
      expect(find.textContaining('未整理新题'), findsNothing);
      expect(find.textContaining('无错因题'), findsNothing);
    });

    testWidgets('SR-P2-47 已解决区也分页：5 组每页 2 条共 3 页', (tester) async {
      final repo = FakeReviewRepo(
        settings: AppSettings.defaults.copyWith(pageSize: 2),
        questions: [
          rq('q1', '函数极限', errorTypes: const ['概念不清'], reviewJoined: true),
          rq(
            'q3',
            '学术词汇辨析',
            subjectId: 'english',
            errorTypes: const ['概念不清'],
            reviewJoined: true,
          ),
          rq('c1', '治愈题 1', errorTypes: const ['方法不会'], reviewJoined: true),
          rq('c2', '治愈题 2', errorTypes: const ['计算错误'], reviewJoined: true),
          rq('c3', '治愈题 3', errorTypes: const ['审题失误'], reviewJoined: true),
          rq('c4', '治愈题 4', errorTypes: const ['其他'], reviewJoined: true),
        ],
        records: [
          rec('q1', '概念不清', joinedAt: DateTime(2026, 11, 10)),
          rec(
            'q3',
            '概念不清',
            subjectId: 'english',
            status: CauseStatus.solved,
            solvedCount: 2,
            recheckDate: DateTime.now().add(const Duration(days: 7)),
            joinedAt: DateTime(2026, 11, 10),
          ),
          rec(
            'c1',
            '方法不会',
            status: CauseStatus.solved,
            solvedCount: 2,
            recheckDate: DateTime.now().add(const Duration(days: 7)),
            joinedAt: DateTime(2026, 11, 10),
          ),
          rec(
            'c2',
            '计算错误',
            status: CauseStatus.solved,
            solvedCount: 2,
            recheckDate: DateTime.now().add(const Duration(days: 7)),
            joinedAt: DateTime(2026, 11, 10),
          ),
          rec(
            'c3',
            '审题失误',
            status: CauseStatus.solved,
            solvedCount: 2,
            recheckDate: DateTime.now().add(const Duration(days: 7)),
            joinedAt: DateTime(2026, 11, 10),
          ),
          rec(
            'c4',
            '其他',
            status: CauseStatus.solved,
            solvedCount: 2,
            recheckDate: DateTime.now().add(const Duration(days: 7)),
            joinedAt: DateTime(2026, 11, 10),
          ),
        ],
      );
      await pumpReview(tester, repo: repo);
      // 待治 1 行 + 已掌握未到期 5 行（q3、c1–c4）共 6 条，每页 2 条共 3 页；
      // 已治愈 5 组每页 2 条共 3 页，翻页要点第 2 个“下一页”。
      expect(find.text('共 6 条 · 第 1 / 3 页'), findsOneWidget);
      expect(find.text('共 5 组 · 第 1 / 3 页'), findsOneWidget);
      final next = find.widgetWithText(QmButton, '下一页').at(1);
      await tester.ensureVisible(next);
      await tester.pumpAndSettle();
      await tester.tap(next);
      await tester.pumpAndSettle();
      expect(find.text('共 5 组 · 第 2 / 3 页'), findsOneWidget);
    });

    testWidgets('SR-P2-47 未加入盒：超 10 道默认只列前 10，可展开看全部', (tester) async {
      final repo = reviewRepo();
      repo.questions = [
        ...repo.questions,
        for (var i = 0; i < 12; i++)
          rq('n$i', '待加入题 $i', errorTypes: const ['概念不清']),
      ];
      await pumpReview(tester, repo: repo);
      expect(find.text('展开全部（共 13 道）'), findsOneWidget);
      expect(find.textContaining('待加入题 9'), findsOneWidget);
      expect(find.textContaining('待加入题 10'), findsNothing);
      expect(find.textContaining('政治「马原」'), findsNothing);
      await tapButton(tester, '展开全部（共 13 道）');
      expect(find.textContaining('待加入题 10'), findsOneWidget);
      expect(find.textContaining('待加入题 11'), findsOneWidget);
      expect(find.textContaining('政治「马原」'), findsOneWidget);
      expect(find.text('收起'), findsOneWidget);
    });

    testWidgets('SR2-75 未加入盒按学科分行：新学科/未知学科排最后', (tester) async {
      final repo = reviewRepo();
      // 新学科化学进学科表（排在预设三科之后）；未知学科不在表里。
      repo.subjectsValue = [
        ...Subject.all,
        Subject(
          id: 'chemistry',
          name: '化学',
          color: Color(0xFF7C4DDB),
          icon: '化',
        ),
      ];
      repo.questions = [
        ...repo.questions,
        rq('n0', '数学新题', errorTypes: const ['方法不会']),
        rq('n1', '化学新题', subjectId: 'chemistry', errorTypes: const ['概念不清']),
        rq('n2', '未知学科题', subjectId: 'weird', errorTypes: const ['概念不清']),
      ];
      await pumpReview(tester, repo: repo);
      // 未加入盒共 4 行，按学科表顺序：数学 → 政治 → 化学 → 未知学科。
      // 未知学科名回退到数学（Subject.byId 兜底），但行本身排在最后。
      double dy(String s) => tester.getTopLeft(find.textContaining(s)).dy;
      expect(dy('数学新题'), lessThan(dy('马原')));
      expect(dy('马原'), lessThan(dy('化学新题')));
      expect(dy('化学新题'), lessThan(dy('未知学科题')));
    });

    testWidgets('SR-P2-48 读库失败出错误横幅；重试失败仍在，成功后恢复', (tester) async {
      final repo = reviewRepo();
      repo.throwOnLoad = true;
      await pumpReview(tester, repo: repo);
      expect(find.textContaining('复习数据读取失败'), findsOneWidget);
      expect(find.text('重新加载'), findsOneWidget);
      await tapButton(tester, '重新加载');
      expect(find.textContaining('复习数据读取失败'), findsOneWidget);
      repo.throwOnLoad = false;
      await tapButton(tester, '重新加载');
      // q1、q3 行副标题 + 已治愈行各一处“概念不清”。
      expect(find.textContaining('概念不清'), findsNWidgets(3));
    });

    testWidgets('SR-P2-49 错因筛选进会话：只治筛选命中的错因', (tester) async {
      await pumpReview(tester);
      await pickMenuItem<String>(
        tester,
        find.byType(DropdownButton<String>).last,
        '计算错误',
      );
      await tapButton(tester, '开始复习');
      expect(find.textContaining('第 1 / 1 道题'), findsOneWidget);
      expect(find.textContaining('错因「计算错误」'), findsOneWidget);
      expect(find.textContaining('本轮共 1 道题、1 个错因'), findsOneWidget);
    });

    testWidgets('SR3-17 错因筛选进会话跨学科同错因：文案退为错因「…」，会话共 2 道题', (tester) async {
      await pumpReview(tester, repo: crossSubjectRepo());
      await pickMenuItem<String>(
        tester,
        find.byType(DropdownButton<String>).last,
        '计算错误',
      );
      await tapButton(tester, '开始复习');
      // 会话是（当前筛选 × 计算错误）：q2（数学）+ q6（英语），共 2 道题；
      // 文案按实际队列算，跨学科单错因退为“错因「计算错误」”，不再写
      // “数学 · 计算错误”（旧文案只在单科单错因时才成立）。
      expect(find.textContaining('第 1 / 2 道题'), findsOneWidget);
      expect(find.textContaining('错因「计算错误」'), findsOneWidget);
      expect(find.textContaining('数学 · 计算错误'), findsNothing);
      // 走完 q2 的单个错因，到第 2 道题：是英语题，文案仍是错因口径。
      await walkPaperToCheck(tester);
      await tapButton(tester, '确认核对，下一题');
      expect(find.textContaining('第 2 / 2 道题'), findsOneWidget);
      expect(find.textContaining('错因「计算错误」'), findsOneWidget);
      expect(find.textContaining('英语 · 材料题｜英语完形填空'), findsOneWidget);
    });

    testWidgets('SR2-34：筛“计算错误”进会话，详情里删掉唯一带它的题，'
        '回列表不断言、筛选回到全部', (tester) async {
      // 只有 q2 带“计算错误”（待治组里唯一）；详情页删题由
      // onOpenDetail 模拟：删题 + 删记录。
      final repo = reviewRepo();
      await pumpReview(
        tester,
        repo: repo,
        onOpenDetail: (q, ids, {String? searchContext}) async {
          repo.questions.removeWhere((x) => x.id == q.id);
          repo.records.removeWhere((r) => r.questionId == q.id);
        },
      );
      await pickMenuItem<String>(
        tester,
        find.byType(DropdownButton<String>).last,
        '计算错误',
      );
      await tapButton(tester, '开始复习');
      expect(find.textContaining('第 1 / 1 道题'), findsOneWidget);
      expect(find.textContaining('错因「计算错误」'), findsOneWidget);
      // 会话里进详情删题：题没了，会话切到总结页。
      await tapButton(tester, '查看题目详情');
      expect(repo.questions.where((x) => x.id == 'q2'), isEmpty);
      expect(find.text('本轮复习总结'), findsOneWidget);
      await tapButton(tester, '回复习列表');
      // 未修时 _causeFilter 仍是“计算错误”，而选项里已无它，
      // 回列表重建下拉会抛 DropdownButton 断言。
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byType(DropdownButton<String>).last,
            )
            .value,
        '全部',
      );
      expect(find.text('计算错误'), findsNothing);
      expect(find.textContaining('函数极限'), findsOneWidget);
    });

    testWidgets('SR-P2-57 断点恢复的范围按保存队列写，不写死“全部待解决错因”', (tester) async {
      await pumpReview(tester);
      await pickMenuItem<String>(
        tester,
        find.byType(DropdownButton<String>).first,
        'math',
      );
      await tapButton(tester, '开始复习');
      expect(find.textContaining('第 1 / 2 道题'), findsOneWidget);
      expect(find.textContaining('数学这一科'), findsOneWidget);
      await tapButton(tester, '暂停');
      expect(find.textContaining('继续上次会话'), findsNWidgets(2));
      await tapButton(tester, '继续上次会话');
      expect(find.textContaining('第 1 / 2 道题'), findsOneWidget);
      expect(find.textContaining('数学这一科'), findsOneWidget);
      expect(find.textContaining('全部待解决错因'), findsNothing);
    });
  });
}
