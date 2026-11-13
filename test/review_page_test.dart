// R8 复习页 widget 测试：学科 × 错因分组列表、元信息、筛选回第 1 页、
// 分页、已治愈分组展开、空态、恢复条、四步会话（看错因 → 写补救 →
// 重做 → 自查）、跳过两次留到下次、暂停续接、自查治愈计数、保存失败
// 横幅、亮/深 × 三档无溢出、不用图标字体。用 FakeRepo 覆盖 repository
// 调用（不碰真实数据库）；recordSelfCheck 按真实语义实现。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
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
}) =>
    Question(
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
}) =>
    CauseRecord(
      questionId: questionId,
      cause: cause,
      subjectId: subjectId,
      status: status,
      solvedCount: solvedCount,
      lastCheck: status == CauseStatus.solved
          ? DateTime(2026, 11, 10)
          : null,
      recheckDate: recheckDate,
      remedyHistory: remedyHistory,
      joinedAt: joinedAt ?? DateTime(2026, 11, 10),
    );

class FakeReviewRepo extends QuestionRepository {
  FakeReviewRepo({
    required this.questions,
    required this.records,
    AppSettings? settings,
    this.throwOnCheck = false,
    List<Subject>? subjects,
  })  : settingsValue = settings ?? AppSettings.defaults,
        subjectsValue = subjects ?? Subject.all,
        super(AppDatabase.instance);

  List<Question> questions;
  List<CauseRecord> records;
  AppSettings settingsValue;
  bool throwOnCheck;
  List<Subject> subjectsValue;
  ReviewSessionState? savedState;

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);

  final Map<String, List<({String result, DateTime reviewedAt})>> history =
      {};

  @override
  Future<AppSettings> settings() async => settingsValue;

  @override
  Future<void> saveSettings(AppSettings s) async {
    settingsValue = s;
  }

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
          String questionId) async =>
      List.of(history[questionId] ?? const []);

  @override
  Future<ReviewSessionState?> reviewState() async => savedState;

  @override
  Future<void> saveReviewState(
          {required List<String> queue, required int position}) async =>
      savedState = ReviewSessionState(
        queue: queue,
        position: position,
        updatedAt: DateTime.now(),
      );

  @override
  Future<void> clearReviewState() async {
    savedState = null;
  }

  @override
  Future<CauseRecord> recordSelfCheck(
    CauseRecord r,
    String result, {
    int cureChecks = 2,
    int recheckIntervalDays = 7,
    // 待定1：与真实实现同语义——复查通过不加计数，只顺延复查日。
    bool isRecheck = false,
  }) async {
    if (throwOnCheck) throw StateError('save failed');
    if (result == 'unsure') return r;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    late CauseRecord updated;
    if (result == 'solved') {
      final count = isRecheck ? r.solvedCount : r.solvedCount + 1;
      if (isRecheck || count >= cureChecks) {
        updated = r.copyWith(
          status: CauseStatus.solved,
          solvedCount: count,
          lastCheck: now,
          recheckDate: today.add(Duration(days: recheckIntervalDays)),
        );
      } else {
        updated = r.copyWith(
          status: CauseStatus.inProgress,
          solvedCount: count,
          lastCheck: now,
          clearRecheckDate: true,
        );
      }
    } else {
      updated = r.copyWith(
        status: CauseStatus.inProgress,
        solvedCount: 0,
        lastCheck: now,
        clearRecheckDate: true,
      );
    }
    final i = records.indexWhere(
        (x) => x.questionId == r.questionId && x.cause == r.cause);
    if (i >= 0) records[i] = updated;
    return updated;
  }

  @override
  Future<CauseRecord> saveRemedy(CauseRecord r, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return r;
    final now = DateTime.now();
    final entry = '${now.year}-${now.month}-${now.day}：$trimmed';
    final updated =
        r.copyWith(remedyHistory: [entry, ...r.remedyHistory]);
    final i = records.indexWhere(
        (x) => x.questionId == r.questionId && x.cause == r.cause);
    if (i >= 0) records[i] = updated;
    return updated;
  }
}

FakeReviewRepo reviewRepo({int pageSize = 10}) {
  final now = DateTime(2026, 11, 10);
  return FakeReviewRepo(
    settings: AppSettings.defaults.copyWith(pageSize: pageSize),
    questions: [
      rq('q1', '函数极限',
          errorTypes: const ['概念不清'],
          answer: '3',
          explanation: 'lim sin3x/x = 3。',
          notes: '当时没看清题目。',
          createdAt: DateTime(2026, 11, 8),
          reviewJoined: true),
      rq('q2', '导数应用综合',
          errorTypes: const ['方法不会', '计算错误'],
          answer: '见解析',
          explanation: '先求导，再列表。',
          createdAt: DateTime(2026, 11, 9),
          reviewJoined: true),
      rq('q3', '学术词汇辨析',
          subjectId: 'english',
          errorTypes: const ['概念不清'],
          createdAt: DateTime(2026, 11, 7),
          reviewJoined: true),
      rq('q4', '马原',
          subjectId: 'politics',
          errorTypes: const ['概念不清'],
          createdAt: DateTime(2026, 11, 6)),
      rq('q5', '未整理题',
          errorTypes: const ['方法不会'],
          createdAt: DateTime(2026, 11, 5),
          isOrganized: false,
          reviewJoined: true),
    ],
    records: [
      rec('q1', '概念不清', joinedAt: now),
      rec('q2', '方法不会',
          status: CauseStatus.inProgress,
          solvedCount: 1,
          joinedAt: now.add(const Duration(hours: 1))),
      rec('q2', '计算错误', joinedAt: now.add(const Duration(hours: 1))),
      rec('q3', '概念不清',
          subjectId: 'english',
          status: CauseStatus.solved,
          solvedCount: 2,
          recheckDate: DateTime.now().add(const Duration(days: 7)),
          remedyHistory: const ['2026-11-10：把词根表抄了一遍'],
          joinedAt: now.subtract(const Duration(hours: 1))),
      rec('q5', '方法不会', joinedAt: now),
    ],
  );
}

/// 只有 q1 一道待治题的库（单块会话、治愈路径短）。
FakeReviewRepo singleRepo({int solvedCount = 0}) {
  final repo = reviewRepo();
  repo.questions = [
    rq('q1', '函数极限',
        errorTypes: const ['概念不清'],
        answer: '3',
        explanation: 'lim sin3x/x = 3。',
        notes: '当时没看清题目。',
        createdAt: DateTime(2026, 11, 8),
        reviewJoined: true),
  ];
  repo.records = [
    rec('q1', '概念不清',
        status: solvedCount > 0 ? CauseStatus.inProgress : CauseStatus.pending,
        solvedCount: solvedCount,
        joinedAt: DateTime(2026, 11, 10)),
  ];
  return repo;
}

/// B6：库里多一道已归档但已加入复习的题（q9）；取消归档用时把
/// 同一道题的 isArchived 改回 false 即可。
FakeReviewRepo archivedRepo({bool archived = true}) {
  final repo = reviewRepo();
  repo.questions = [
    ...repo.questions,
    rq('q9', '已归档题',
        errorTypes: const ['概念不清'],
        createdAt: DateTime(2026, 11, 9),
        reviewJoined: true,
        isArchived: archived),
  ];
  repo.records = [
    ...repo.records,
    rec('q9', '概念不清', joinedAt: DateTime(2026, 11, 9)),
  ];
  return repo;
}

/// 待定1：只有一道复查到期的题——已解决、solvedCount 已满 2、
/// 复查日是昨天（已到期）。
FakeReviewRepo recheckRepo() {
  final repo = reviewRepo();
  repo.questions = [
    rq('q1', '函数极限',
        errorTypes: const ['概念不清'],
        answer: '3',
        explanation: 'lim sin3x/x = 3。',
        notes: '当时没看清题目。',
        createdAt: DateTime(2026, 11, 8),
        reviewJoined: true),
  ];
  repo.records = [
    rec('q1', '概念不清',
        status: CauseStatus.solved,
        solvedCount: 2,
        recheckDate: DateTime.now().subtract(const Duration(days: 1)),
        joinedAt: DateTime(2026, 11, 10)),
  ];
  return repo;
}

Future<void> pumpReview(
  WidgetTester tester, {
  FakeReviewRepo? repo,
  Brightness brightness = Brightness.light,
  double scale = 1.0,
  String? initialSubjectId,
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
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
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
                onOpenDetail: (q, ids) async {
                  opened.add(q);
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

Future<void> tapText(WidgetTester tester, String text,
    {bool first = false}) async {
  final finder = first ? find.text(text).first : find.text(text);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> tapButton(WidgetTester tester, String label,
    {int at = 0}) async {
  final finder = find.widgetWithText(QmButton, label);
  await tester.ensureVisible(finder.at(at));
  await tester.pumpAndSettle();
  await tester.tap(finder.at(at));
  await tester.pumpAndSettle();
}

/// 点下拉里的菜单项（按 DropdownMenuItem 的 value 精确定位）。
Future<void> pickMenuItem<T>(
    WidgetTester tester, Finder dropdown, T value) async {
  await tester.ensureVisible(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  final item = find.byWidgetPredicate(
      (w) => w is DropdownMenuItem<T> && w.value == value);
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(item);
  await tester.pumpAndSettle();
}

void main() {
  group('列表', () {
    testWidgets('按学科 × 错因分组、每组一行：关联题数 + 状态 pill + 复查标记',
        (tester) async {
      await pumpReview(tester);
      // 三组待治：数学|概念不清、数学|方法不会、数学|计算错误。
      // 已治愈行的错因是 Text.rich（“概念不清 · 关联 1 道题”），用包含匹配。
      expect(find.textContaining('概念不清'), findsNWidgets(2)); // 待治组 + 已治愈组
      expect(find.text('方法不会'), findsOneWidget);
      expect(find.text('计算错误'), findsOneWidget);
      expect(find.text('关联 1 道题：函数极限'), findsOneWidget);
      expect(find.text('关联 1 道题：导数应用综合'), findsNWidgets(2));
      // 组状态 pill：待解决 ×2、解决中 ×1；已治愈组另有已解决 pill。
      expect(find.text('待解决'), findsNWidgets(2));
      expect(find.text('解决中'), findsOneWidget);
      expect(find.text('已解决'), findsOneWidget);
      // 未整理的题不在列表里；未加入的题只在“还没加入复习”盒里。
      expect(find.text('关联 1 道题：未整理题'), findsNothing);
      expect(find.textContaining('还没加入复习的题'), findsOneWidget);
      expect(find.textContaining('政治「马原」'), findsOneWidget);
    });

    testWidgets('元信息行：待解决/解决中 3 条 · 已解决 1 条', (tester) async {
      await pumpReview(tester);
      expect(
          find.text('待解决 / 解决中 3 条解决记录'), findsOneWidget);
      expect(find.text('已解决 1 条'), findsOneWidget);
      expect(find.textContaining('列表按加入时间排，先加入的先解决'),
          findsOneWidget);
    });

    testWidgets('B6：已归档的已加入题不在复习列表里，取消归档后回来',
        (tester) async {
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

    testWidgets('学科筛选：只留英语组，待治为空出提示 + 已治愈组仍在',
        (tester) async {
      await pumpReview(tester);
      await pickMenuItem<String>(
          tester, find.byType(DropdownButton<String>).first, 'english');
      expect(find.text('当前筛选下没有待解决错因，换个学科 / 错因试试。'),
          findsOneWidget);
      expect(find.textContaining('概念不清'), findsOneWidget); // 仅已治愈组
      expect(find.text('方法不会'), findsNothing);
    });

    testWidgets('错因筛选：只留计算错误组', (tester) async {
      await pumpReview(tester);
      await pickMenuItem<String>(tester,
          find.byType(DropdownButton<String>).last, '计算错误');
      // 下拉框当前值 + 分组行各一个“计算错误”。
      expect(find.text('计算错误'), findsNWidgets(2));
      expect(find.text('方法不会'), findsNothing);
      expect(find.text('关联 1 道题：导数应用综合'), findsOneWidget);
    });

    testWidgets('分页：每页 2 条共 2 页，翻页后筛选回第 1 页', (tester) async {
      await pumpReview(tester, repo: reviewRepo(pageSize: 2));
      expect(find.text('共 3 条 · 第 1 / 2 页'), findsOneWidget);
      expect(find.text('计算错误'), findsNothing); // 第 3 组在第 2 页
      await tapButton(tester, '下一页');
      expect(find.text('共 3 条 · 第 2 / 2 页'), findsOneWidget);
      expect(find.text('计算错误'), findsOneWidget);
      await pickMenuItem<String>(tester,
          find.byType(DropdownButton<String>).last, '计算错误');
      expect(find.text('共 1 条 · 第 1 / 1 页'), findsOneWidget);
      // 下拉框当前值 + 分组行各一个“计算错误”。
      expect(find.text('计算错误'), findsNWidgets(2));
    });

    testWidgets('每页数量可改：改成 20 条后只剩 1 页', (tester) async {
      final repo = reviewRepo(pageSize: 2);
      await pumpReview(tester, repo: repo);
      expect(find.text('共 3 条 · 第 1 / 2 页'), findsOneWidget);
      await pickMenuItem<int>(
          tester, find.byType(DropdownButton<int>), 20);
      expect(find.text('共 3 条 · 第 1 / 1 页'), findsOneWidget);
      expect(repo.settingsValue.pageSize, 20);
    });

    testWidgets('S8A6 大库 55 组：五档页数与末页条数', (tester) async {
      // 与真机大库同口径：55 道题已加入复习；复习列表按 subject|cause
      // 分组，固定错因只有 5 种会并组，所以每题给一个唯一自定义错因，
      // 55 道题即 55 组。加入时间递增，组顺序即题号顺序。
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
            rec('b$i', '分页错因 $i',
                joinedAt: base.add(Duration(minutes: i))),
        ],
      );
      await pumpReview(tester, repo: repo);
      // 每档：每页数 → 总页数 / 末页首组 / 上一页首组（不在末页）。
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
              tester, find.byType(DropdownButton<int>), size);
        }
        expect(find.text('共 55 条 · 第 1 / $pages 页'), findsOneWidget);
        for (var p = 1; p < pages; p++) {
          await tapButton(tester, '下一页');
        }
        expect(find.text('共 55 条 · 第 $pages / $pages 页'), findsOneWidget);
        expect(find.text(first), findsOneWidget);
        expect(find.text('分页错因 54'), findsOneWidget);
        expect(find.text(before), findsNothing);
      }
    });

    testWidgets('已治愈组：点一行展开看解决记录，再点收起', (tester) async {
      await pumpReview(tester);
      expect(find.textContaining('解决于'), findsNothing);
      await tapText(tester, '解决记录');
      expect(find.textContaining('解决于 2026-11-10'), findsOneWidget);
      expect(find.textContaining('下次复查'), findsOneWidget);
      expect(find.textContaining('补救记录：2026-11-10：把词根表抄了一遍'),
          findsOneWidget);
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

    testWidgets('无旧翻卡模型：不出现“下次复习时间”', (tester) async {
      await pumpReview(tester);
      expect(find.textContaining('下次复习时间'), findsNothing);
      expect(find.textContaining('翻卡'), findsNothing);
    });
  });

  group('会话', () {
    testWidgets('四步走完一题：看错因 → 写补救 → 重做 → 自查 → 看总结',
        (tester) async {
      await pumpReview(tester, repo: singleRepo());
      await tapButton(tester, '开始解决');
      expect(find.textContaining('第 1 / 1 道题'), findsOneWidget);
      expect(find.text('① 看错因'), findsOneWidget);
      expect(find.text('跳过该题'), findsOneWidget);
      await tapButton(tester, '下一步：写补救');
      expect(find.text('② 写补救'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '先看清题目问的是什么');
      await tester.pumpAndSettle();
      await tapButton(tester, '下一步：重做');
      expect(find.text('③ 重做'), findsOneWidget);
      expect(find.text('看答案'), findsOneWidget);
      expect(find.textContaining('答案：'), findsNothing);
      await tapButton(tester, '看答案');
      expect(find.textContaining('lim sin3x/x = 3。'), findsOneWidget);
      await tapButton(tester, '下一步：自查');
      expect(find.text('④ 自查'), findsOneWidget);
      await tapText(tester, '已解决');
      await tapButton(tester, '看总结');
      expect(find.text('本轮复习总结'), findsOneWidget);
      expect(find.textContaining('今天解决了'), findsOneWidget);
      expect(find.textContaining('待解决 → 解决中'), findsOneWidget);
      await tapButton(tester, '回复习列表');
      expect(find.text('复习列表还是空的'), findsNothing);
      expect(find.text('概念不清'), findsOneWidget); // 单题库：仅待治组
    });

    testWidgets('自查“已解决”满 2 次算已解决：总结计 1 个已解决',
        (tester) async {
      await pumpReview(tester, repo: singleRepo(solvedCount: 1));
      await tapButton(tester, '开始解决');
      await tapButton(tester, '下一步：写补救');
      await tapButton(tester, '下一步：重做');
      await tapButton(tester, '看答案');
      await tapButton(tester, '下一步：自查');
      await tapText(tester, '已解决');
      await tapButton(tester, '看总结');
      expect(find.textContaining('今天解决了 1 个错因'), findsOneWidget);
      expect(find.textContaining('解决中 → 已解决'), findsOneWidget);
      expect(find.textContaining('下次复查'), findsOneWidget);
    });

    testWidgets('待定1：复查通过不加计数——已满 2 次治愈后复查通过仍为 2',
        (tester) async {
      final repo = recheckRepo();
      await pumpReview(tester, repo: repo);
      // 复查到期的题在列表里，带复查标记。
      expect(find.text('复查'), findsOneWidget);
      await tapButton(tester, '开始解决');
      await tapButton(tester, '下一步：写补救');
      await tapButton(tester, '下一步：重做');
      await tapButton(tester, '看答案');
      await tapButton(tester, '下一步：自查');
      // 自查选项是 QmButton；复查记录的状态 pill 也叫“已解决”，
      // 不能用 tapText（会命中两个），按 QmButton 精确定位。
      final checkButton = find.widgetWithText(QmButton, '已解决');
      await tester.ensureVisible(checkButton);
      await tester.pumpAndSettle();
      await tester.tap(checkButton);
      await tester.pumpAndSettle();
      await tapButton(tester, '看总结');
      expect(find.textContaining('复查通过'), findsOneWidget);
      final r = repo.records.single;
      expect(r.status, CauseStatus.solved);
      expect(r.solvedCount, 2);
      final today = DateTime.now();
      final todayStart = DateTime(today.year, today.month, today.day);
      expect(r.recheckDate, isNotNull);
      expect(!r.recheckDate!.isBefore(todayStart), isTrue);
    });

    testWidgets('自查要全选完才能“下一题”：双错因题先选一个仍禁用',
        (tester) async {
      await pumpReview(tester);
      await tapButton(tester, '开始解决');
      // q1 一因走完，到 q2（双错因）。
      await tapButton(tester, '下一步：写补救');
      await tapButton(tester, '下一步：重做');
      await tapButton(tester, '看答案');
      await tapButton(tester, '下一步：自查');
      await tapText(tester, '已解决');
      await tapButton(tester, '下一题');
      expect(find.textContaining('第 2 / 2 道题'), findsOneWidget);
      expect(find.text('本题错因 1 / 2'), findsOneWidget);
      await tapButton(tester, '下一步：写补救');
      await tapButton(tester, '下一步：下个错因');
      expect(find.text('本题错因 2 / 2'), findsOneWidget);
      await tapButton(tester, '下一步：写补救');
      await tapButton(tester, '下一步：重做');
      await tapButton(tester, '看答案');
      await tapButton(tester, '下一步：自查');
      // 只选第一个错因。
      final first = find.text('已解决').first;
      await tester.ensureVisible(first);
      await tester.pumpAndSettle();
      await tester.tap(first);
      await tester.pumpAndSettle();
      final nextBtn =
          find.widgetWithText(QmButton, '看总结').evaluate().first.widget
              as QmButton;
      expect(nextBtn.onPressed, isNull);
      // 选完第二个才能走。
      final second = find.text('已解决').last;
      await tester.ensureVisible(second);
      await tester.pumpAndSettle();
      await tester.tap(second);
      await tester.pumpAndSettle();
      await tapButton(tester, '看总结');
      expect(find.text('本轮复习总结'), findsOneWidget);
    });

    testWidgets('跳过两次留到下次：第二次跳过后直接出总结', (tester) async {
      await pumpReview(tester, repo: singleRepo());
      await tapButton(tester, '开始解决');
      await tapButton(tester, '跳过该题');
      // 第 1 次跳过：追加到队尾，本轮还有这道题。
      expect(find.textContaining('第 1 / 1 道题'), findsOneWidget);
      expect(find.text('① 看错因'), findsOneWidget);
      await tapButton(tester, '跳过该题');
      // 第 2 次跳过：留到下次，本轮结束出总结。
      expect(find.text('本轮复习总结'), findsOneWidget);
      expect(find.text('这一轮还没有自查记录。'), findsOneWidget);
    });

    testWidgets('暂停后列表出恢复条：继续解决回到中断的错因', (tester) async {
      final repo = reviewRepo();
      await pumpReview(tester, repo: repo);
      await tapButton(tester, '开始解决');
      await tapButton(tester, '暂停');
      expect(find.textContaining('上次解决到一半'), findsOneWidget);
      expect(find.text('继续解决'), findsOneWidget);
      expect(find.text('从头开始'), findsOneWidget);
      expect(repo.savedState, isNotNull);
      await tapButton(tester, '继续解决');
      expect(find.textContaining('第 1 / 2 道题'), findsOneWidget);
      expect(find.text('① 看错因'), findsOneWidget);
    });

    testWidgets('按组开始解决：从含该错因的块开始（块内仍从首个错因治起）',
        (tester) async {
      await pumpReview(tester);
      // 第 3 个“开始解决”按钮 = 计算错误组（顶栏 1 个 + 三组各 1 个）。
      await tapButton(tester, '开始解决', at: 3);
      expect(find.textContaining('第 2 / 2 道题'), findsOneWidget);
      expect(find.text('本题错因 1 / 2'), findsOneWidget);
    });

    testWidgets('放大浮层：点题图弹出，标题“整题图 · 放大查看”',
        (tester) async {
      await pumpReview(tester, repo: singleRepo());
      await tapButton(tester, '开始解决');
      await tester.tap(find.byType(QuestionSlice).first);
      await tester.pumpAndSettle();
      expect(find.text('整题图 · 放大查看'), findsOneWidget);
      await tapButton(tester, '关闭 ×');
      expect(find.text('整题图 · 放大查看'), findsNothing);
    });

    testWidgets('保存失败：自查提交抛错，出错误横幅并留在自查步',
        (tester) async {
      final repo = singleRepo();
      repo.throwOnCheck = true;
      await pumpReview(tester, repo: repo);
      await tapButton(tester, '开始解决');
      await tapButton(tester, '下一步：写补救');
      await tapButton(tester, '下一步：重做');
      await tapButton(tester, '看答案');
      await tapButton(tester, '下一步：自查');
      await tapText(tester, '已解决');
      await tapButton(tester, '看总结');
      expect(find.textContaining('复习记录保存失败'), findsOneWidget);
      expect(find.text('④ 自查'), findsOneWidget);
    });
  });

  group('亮/深 × 三档无溢出', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      for (final scale in [1.0, 1.15, 1.3]) {
        testWidgets(
            '${brightness == Brightness.light ? '亮' : '深'} × $scale 列表 + 会话无溢出',
            (tester) async {
          await pumpReview(tester,
              brightness: brightness, scale: scale);
          expect(tester.takeException(), isNull);
          await tapButton(tester, '开始解决');
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tapButton(tester, '下一步：写补救');
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}
