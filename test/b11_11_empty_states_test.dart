// B11-11 空状态接线 widget 测试：全应用空状态动作点按验证。
//
// 审计结论（见 docs/ui-replication/B11-11-EMPTY-STATES.md）：
// 全应用 8 处 QmEmptyState 动作按钮 + 首页 / 收集中心各动作按钮在
// 审计时已全部接线（onAction 非空 → 页回调 → app.dart _go /
// _goReview），没有发现死按钮。本文件补上此前只有“出现”断言、
// 没有“点按”断言的 8 处：点按后回调触发（= 要求跳往的路由）或
// 页内状态按预期变化。
// 用 FakeRepo 覆盖 repository 调用（不碰真实数据库，不改口径）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/collect/collect_page.dart';
import 'package:quiz_master2/modules/organize/organize_page.dart';
import 'package:quiz_master2/modules/review/review_page.dart';
import 'package:quiz_master2/modules/wrongbook/wrongbook_page.dart';
import 'package:quiz_master2/services/yolo_onnx_service.dart';
import 'package:quiz_master2/state/review_notifier.dart';
import 'package:quiz_master2/theme/app_theme.dart';

Future<void> _pumpScaffold(
  WidgetTester tester,
  Widget body, {
  double scale = 1.0,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    // P3：复习页 load() 读调度器池内标记——外层覆盖一个确定性内存
    // 调度器（fuzzing 关），不碰真实数据库（review_page_test.dart
    // 同款做法）。
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
        theme: AppTheme.light(scale: scale),
        darkTheme: AppTheme.dark(scale: scale),
        home: Builder(
          builder: (context) {
            final data = MediaQuery.of(context);
            return MediaQuery(
              data: data.copyWith(textScaler: TextScaler.linear(scale)),
              child: Scaffold(body: body),
            );
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapText(WidgetTester tester, String label) async {
  final finder = find.text(label);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

// --------------------------------------------------------------- 复习页 --

Question _rq(
  String id,
  String title, {
  String subjectId = 'math',
  bool reviewJoined = false,
}) =>
    Question(
      id: id,
      title: title,
      subjectId: subjectId,
      createdAt: DateTime(2026, 11, 8),
      isOrganized: true,
      reviewJoined: reviewJoined,
      sliceKind: 'material',
      sliceText: '题：$title',
    );

class _B11ReviewRepo extends QuestionRepository {
  _B11ReviewRepo({required this.questions, required this.records})
      : super(AppDatabase.instance);

  List<Question> questions;
  List<CauseRecord> records;

  /// 十九批 A3：内存版已存查找（不碰真实库）。
  final List<SavedSearch> savedSearchList = [];

  @override
  Future<List<SavedSearch>> savedSearches() async =>
      List.of(savedSearchList);

  @override
  Future<void> saveSavedSearch(SavedSearch search) async {
    savedSearchList.removeWhere((s) => s.id == search.id);
    savedSearchList.add(search);
  }

  @override
  Future<void> deleteSavedSearch(String id) async {
    savedSearchList.removeWhere((s) => s.id == id);
  }

  @override
  Future<List<Subject>> subjects() async => List.of(Subject.all);

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

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

// --------------------------------------------------------------- 整理页 --

Question _oq(
  String id,
  String title, {
  bool isOrganized = false,
}) =>
    Question(
      id: id,
      title: title,
      subjectId: 'math',
      sliceKind: 'limit',
      sliceText: '题：lim(x→0) sin 3x / x 的值是（　）',
      createdAt: DateTime(2026, 11, 8),
      isOrganized: isOrganized,
    );

class _B11OrganizeRepo extends QuestionRepository {
  _B11OrganizeRepo({required this.questions}) : super(AppDatabase.instance);

  List<Question> questions;

  /// 十九批 A3：内存版已存查找（不碰真实库）。
  final List<SavedSearch> savedSearchList = [];

  @override
  Future<List<SavedSearch>> savedSearches() async =>
      List.of(savedSearchList);

  @override
  Future<void> saveSavedSearch(SavedSearch search) async {
    savedSearchList.removeWhere((s) => s.id == search.id);
    savedSearchList.add(search);
  }

  @override
  Future<void> deleteSavedSearch(String id) async {
    savedSearchList.removeWhere((s) => s.id == id);
  }

  @override
  Future<List<Subject>> subjects() async => List.of(Subject.all);

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [];

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<List<String>> tags() async => const [];

  /// B11-10：OrganizePage 只在队列已空且库里有题时读这两个数（今日小结
  /// 行用）；假实现返回 0 / 空，不碰真实库（B11-4/10 worker 补）。
  @override
  Future<int> organizedTodayCount({DateTime? now}) async => 0;

  @override
  Future<List<Question>> dueToday({bool includeArchived = false}) async =>
      const [];

  /// 十三批 M5：OCR 状态是 best-effort 加载（不 await）；返回空任务行
  /// 与“无 key”，不碰真实库（见 D-88）。
  @override
  Future<List<OcrJob>> ocrJobsForQuestion(String questionId) async =>
      const [];

  @override
  Future<bool> hasOcrApiKey() async => false;
}

// --------------------------------------------------------------- 错题本 --

Question _wq(
  String id,
  String title, {
  List<String> errorTypes = const ['概念不清'],
  bool isArchived = false,
}) =>
    Question(
      id: id,
      title: title,
      subjectId: 'math',
      errorTypes: errorTypes,
      sliceKind: 'limit',
      sliceText: '题：求极限',
      createdAt: DateTime.now().subtract(const Duration(days: 2)),
      isOrganized: true,
      isArchived: isArchived,
    );

CauseRecord _wrec(
  String questionId,
  String cause, {
  CauseStatus status = CauseStatus.solved,
}) =>
    CauseRecord(
      questionId: questionId,
      cause: cause,
      subjectId: 'math',
      status: status,
      solvedCount: status == CauseStatus.solved ? 2 : 0,
      lastCheck: DateTime.now(),
      // 已解决且复查日在未来：不算“到了复查时间”，状态就是已解决。
      recheckDate: status == CauseStatus.solved
          ? DateTime.now().add(const Duration(days: 7))
          : null,
      joinedAt: DateTime.now().subtract(const Duration(days: 1)),
    );

class _B11WrongbookRepo extends QuestionRepository {
  _B11WrongbookRepo({required this.questions, required this.records})
      : super(AppDatabase.instance);

  List<Question> questions;
  List<CauseRecord> records;

  /// 十九批 A3：内存版已存查找（不碰真实库）。
  final List<SavedSearch> savedSearchList = [];

  @override
  Future<List<SavedSearch>> savedSearches() async =>
      List.of(savedSearchList);

  @override
  Future<void> saveSavedSearch(SavedSearch search) async {
    savedSearchList.removeWhere((s) => s.id == search.id);
    savedSearchList.add(search);
  }

  @override
  Future<void> deleteSavedSearch(String id) async {
    savedSearchList.removeWhere((s) => s.id == id);
  }

  @override
  Future<List<Subject>> subjects() async => [
        Subject.math.copyWith(coverColor: 'green'),
        Subject.english,
        Subject.politics,
      ];

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [];

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<String>> tags() async => const [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<Map<String, (int, int, int)>> subjectCounts(
          {bool includeArchived = false}) async =>
      const {'math': (0, 0, 0)};

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<AppSettings> settings() async => const AppSettings();

  // P3 入口 1：load() 读池内标记（不覆写会走真实库、页面卡 loading、
  // pumpAndSettle 超时）。
  @override
  Future<Set<String>> fsrsPoolQuestionIds() async => const {};
}

// --------------------------------------------------------------- 收集页 --

class _B11CollectRepo extends QuestionRepository {
  _B11CollectRepo({required this.subjectsValue}) : super(AppDatabase.instance);

  List<Subject> subjectsValue;

  /// 十九批 A3：内存版已存查找（不碰真实库）。
  final List<SavedSearch> savedSearchList = [];

  @override
  Future<List<SavedSearch>> savedSearches() async =>
      List.of(savedSearchList);

  @override
  Future<void> saveSavedSearch(SavedSearch search) async {
    savedSearchList.removeWhere((s) => s.id == search.id);
    savedSearchList.add(search);
  }

  @override
  Future<void> deleteSavedSearch(String id) async {
    savedSearchList.removeWhere((s) => s.id == id);
  }

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);

  @override
  Future<List<CollectTask>> collectTasks() async => const [];

  @override
  Future<List<QuestionBox>> boxesForTask(String taskId) async => const [];
}

/// 桩检测：本文件用例不跑检测，只是不让 CollectPage 建真实服务。
class _B11StubYolo extends YoloOnnxService {
  @override
  Future<DetectionResult> detectPage({
    required String imagePath,
    required int page,
  }) async =>
      const DetectionResult(boxes: [], usedFallback: true);
}

void main() {
  group('B11-11 空状态接线：点按跳往正确路由 / 页内状态', () {
    testWidgets('复习页空态：点“去错题本选题”走 onGoWrongbook', (tester) async {
      var went = 0;
      await _pumpScaffold(
        tester,
        ReviewPage(
          repo: _B11ReviewRepo(
            questions: [_rq('q9', '马原', subjectId: 'politics')],
            records: const [],
          ),
          onOpenDetail: (_, __, {String? searchContext}) async {},
          onGoWrongbook: () => went++,
        ),
      );
      expect(find.text('复习列表还是空的'), findsOneWidget);
      await _tapText(tester, '去错题本选题');
      expect(went, 1);
    });

    testWidgets('整理页从未有题：点“先去收集题目”走 onGoCollect',
        (tester) async {
      var went = 0;
      await _pumpScaffold(
        tester,
        OrganizePage(
          repo: _B11OrganizeRepo(questions: []),
          onOpenDetail: (_, __, {String? searchContext}) async {},
          onGoReview: () {},
          onGoCollect: () => went++,
        ),
      );
      expect(find.text('没有待整理的题目'), findsOneWidget);
      await _tapText(tester, '先去收集题目');
      expect(went, 1);
    });

    testWidgets('整理页队列已空：点“去复习”走 onGoReview', (tester) async {
      var went = 0;
      await _pumpScaffold(
        tester,
        OrganizePage(
          repo: _B11OrganizeRepo(
            questions: [_oq('q1', '函数极限', isOrganized: true)],
          ),
          onOpenDetail: (_, __, {String? searchContext}) async {},
          onGoReview: () => went++,
          onGoCollect: () {},
        ),
      );
      expect(find.text('都整理完了，去复习吧'), findsOneWidget);
      await _tapText(tester, '去复习');
      expect(went, 1);
    });

    testWidgets('错题本：全已解决时点“看看已解决的题”出现该题',
        (tester) async {
      await _pumpScaffold(
        tester,
        WrongbookPage(
          repo: _B11WrongbookRepo(
            questions: [_wq('q1', '函数极限')],
            records: [_wrec('q1', '概念不清')],
          ),
          initialSubjectId: 'math',
          onOpenHome: () {},
          onOpenDetail: (_, __, {String? searchContext}) async {},
          onGoReview: ({String? subjectId}) {},
        ),
      );
      // 二十三批 D-250：只带学科落目录，点「全部题目」进列表
      //（十九批 A5“直接落列表”已废）。
      await _tapText(tester, '全部题目');
      expect(find.text('这里的题错因都已解决'), findsOneWidget);
      await _tapText(tester, '看看已解决的题');
      // 十九批 A1：板子行标题常显，不用切视图。
      // 二十一批 D-244：行标题改显示题干（'题：求极限'），不再显示标题。
      expect(
        find.textContaining('题：求极限', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('错题本：搜不到时点“清除全部筛选”恢复列表', (tester) async {
      await _pumpScaffold(
        tester,
        WrongbookPage(
          repo: _B11WrongbookRepo(
            questions: [_wq('q1', '函数极限')],
            records: const [],
          ),
          filterCause: '不存在的错因',
          onOpenHome: () {},
          onOpenDetail: (_, __, {String? searchContext}) async {},
          onGoReview: ({String? subjectId}) {},
        ),
      );
      expect(find.text('没找到这道题，换个词试试'), findsOneWidget);
      await _tapText(tester, '清除全部筛选');
      // 十九批 A1：板子行标题常显，不用切视图。
      // 二十一批 D-244：行标题改显示题干（'题：求极限'），不再显示标题。
      expect(
        find.textContaining('题：求极限', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('没找到这道题，换个词试试'), findsNothing);
    });

    testWidgets('错题本：范围本身空时点“返回书架”回书架', (tester) async {
      await _pumpScaffold(
        tester,
        WrongbookPage(
          repo: _B11WrongbookRepo(questions: [], records: const []),
          filterCause: '不存在的错因',
          onOpenHome: () {},
          onOpenDetail: (_, __, {String? searchContext}) async {},
          onGoReview: ({String? subjectId}) {},
        ),
      );
      expect(find.text('错题本里还没有题'), findsOneWidget);
      await _tapText(tester, '返回书架');
      expect(find.text('错题本里还没有题'), findsNothing);
      expect(find.text('数学'), findsWidgets);
    });

    testWidgets('错题本：本学科已归档空时点“返回题目列表”回列表',
        (tester) async {
      await _pumpScaffold(
        tester,
        WrongbookPage(
          repo: _B11WrongbookRepo(
            questions: [_wq('q1', '函数极限')],
            records: const [],
          ),
          initialSubjectId: 'math',
          onOpenHome: () {},
          onOpenDetail: (_, __, {String? searchContext}) async {},
          onGoReview: ({String? subjectId}) {},
        ),
      );
      // 二十三批 D-250：只带学科落目录，点「全部题目」进列表
      //（十九批 A5“直接落列表”已废）；A1：板子行标题常显，不用切视图。
      // 二十一批 D-244：行标题改显示题干（'题：求极限'）。
      await _tapText(tester, '全部题目');
      expect(
        find.textContaining('题：求极限', findRichText: true),
        findsOneWidget,
      );
      await _tapText(tester, '筛选 ▾');
      expect(find.text('已归档'), findsOneWidget);
      await _tapText(tester, '已归档');
      expect(find.text('这一本里还没有归档的题'), findsOneWidget);
      await _tapText(tester, '返回题目列表');
      // 二十一批 D-244：行标题改显示题干（'题：求极限'）。
      expect(
        find.textContaining('题：求极限', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('这一本里还没有归档的题'), findsNothing);
    });

    testWidgets('收集页学科为空：点“去学科管理”走 onGoSubjects',
        (tester) async {
      var went = 0;
      await _pumpScaffold(
        tester,
        CollectPage(
          repo: _B11CollectRepo(subjectsValue: []),
          onOpenOrganize: () {},
          onGoSubjects: () => went++,
          yoloService: _B11StubYolo(),
        ),
      );
      expect(
        find.text('还没有学科：先去「学科管理」添加一个，再回来导入。'),
        findsOneWidget,
      );
      await _tapText(tester, '去学科管理');
      expect(went, 1);
    });
  });
}
