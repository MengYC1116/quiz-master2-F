// P0B2 “每页”下拉本地化回归测试：复习页与错题本一致，只改本页显示。
//
// 口径（Meng 定）：两页的“每页”下拉都是本地 setState，初值仍从设置
// 默认值（设置页 #17“每页显示数量”）读；下拉改动不写库、不改设置
// 默认值。设置页 #17 仍是改默认值的唯一入口，两页首次打开跟新默认值。
// 用 FakeRepo 覆盖三页的 repository 调用，不碰真实数据库。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/exam_event.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/review/review_page.dart';
import 'package:quiz_master2/modules/settings/settings_page.dart';
import 'package:quiz_master2/modules/wrongbook/wrongbook_page.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/state/review_notifier.dart';
import 'package:quiz_master2/theme/app_theme.dart';

/// 15 道数学题：每题一个唯一自定义错因 → 复习列表 15 组；
/// 同在 f1 文件夹 → 错题本“全部题目”15 道。默认 pageSize 10 时
/// 两页都是 2 页，改 20 后都是 1 页，刚好区分初值与本地改动。
class FakeP0B2Repo extends QuestionRepository {
  FakeP0B2Repo({int pageSize = 10})
    : settingsValue = AppSettings.defaults.copyWith(pageSize: pageSize),
      super(AppDatabase.instance);

  AppSettings settingsValue;
  int saveSettingsCalls = 0;

  final List<Question> questions = [
    for (var i = 0; i < 15; i++)
      Question(
        id: 'p$i',
        title: '分页题 $i',
        subjectId: 'math',
        folderIds: const ['f1'],
        customErrorTypes: ['分页错因 $i'],
        createdAt: DateTime(2026, 11, 10).subtract(Duration(hours: 15 - i)),
        isOrganized: true,
        reviewJoined: true,
        sliceKind: 'material',
        sliceText: '题：分页题 $i',
      ),
  ];

  final List<CauseRecord> records = [
    for (var i = 0; i < 15; i++)
      CauseRecord(
        questionId: 'p$i',
        cause: '分页错因 $i',
        subjectId: 'math',
        status: CauseStatus.pending,
        joinedAt: DateTime(2026, 11, 10).add(Duration(minutes: i)),
      ),
  ];

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
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<AppSettings> settings() async => settingsValue;

  @override
  Future<void> saveSettings(AppSettings s) async {
    saveSettingsCalls++;
    settingsValue = s;
  }

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [
    Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
  ];

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<String>> tags() async => const [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  // P3 入口 1：错题本 load() 读池内标记（不覆写会走真实库、页面卡
  // loading、pumpAndSettle 超时）。
  @override
  Future<Set<String>> fsrsPoolQuestionIds() async => const {};

  @override
  Future<Map<String, (int, int, int)>> subjectCounts({
    bool includeArchived = false,
  }) async => const {'math': (0, 0, 0)};

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<ReviewSessionState?> reviewState() async => null;

  /// B11-9：考试事件内存版（设置页考试组打开时读；不覆盖会落到基类
  /// 读真实库，fake async 里永不完成，见 D-88）。
  @override
  Future<List<ExamEvent>> examEvents() async => const [];

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

Future<void> _pump(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      home: Scaffold(body: page),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> pumpReviewP0B2(
  WidgetTester tester, {
  required FakeP0B2Repo repo,
}) async {
  await _pump(
    tester,
    // P3：复习页 load() 读调度器池内标记——外层覆盖一个确定性内存
    // 调度器（fuzzing 关），不碰真实数据库（review_page_test.dart
    // 同款做法）。只包复习页/错题本页，不包 _pump：设置页那测自带
    // 一个 repositoryProvider override 的 ProviderScope，两套
    // overrides 在 Scaffold body 同一位置交替出现时，Flutter 会
    // 复用无 key 的 ProviderScope 元素，Riverpod 的
    // updateOverrides 校验抛错（“Tried to update the override of
    // a provider that was not overridden before”）→ pumpAndSettle
    // 永不收敛。三个 ProviderScope 都挂 UniqueKey()，每次重建。
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        reviewSchedulerProvider.overrideWithValue(
          FsrsReviewScheduler(
            config: const SchedulerConfig(enableFuzzing: false),
            store: InMemoryCardStore(),
          ),
        ),
      ],
      child: ReviewPage(
        key: UniqueKey(),
        repo: repo,
        onOpenDetail: (q, ids, {String? searchContext}) async {},
        onGoWrongbook: () {},
      ),
    ),
  );
}

Future<void> pumpWrongbookP0B2(
  WidgetTester tester, {
  required FakeP0B2Repo repo,
}) async {
  await _pump(
    tester,
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        reviewSchedulerProvider.overrideWithValue(
          FsrsReviewScheduler(
            config: const SchedulerConfig(enableFuzzing: false),
            store: InMemoryCardStore(),
          ),
        ),
      ],
      child: WrongbookPage(
        key: UniqueKey(),
        repo: repo,
        initialSubjectId: 'math',
        onOpenHome: () {},
        onOpenDetail: (q, ids, {String? searchContext}) async {},
        onGoReview: ({String? subjectId}) {},
      ),
    ),
  );
  // 二十三批 D-250：只带学科落目录，点「全部题目」进列表
  //（十九批 A5“直接落列表”已废）。
  await tester.tap(find.text('全部题目'));
  await tester.pumpAndSettle();
}

Future<void> pickPageSize(WidgetTester tester, int size) async {
  final dropdown = find.byType(DropdownButton<int>);
  await tester.ensureVisible(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  final item = find.byWidgetPredicate(
    (w) => w is DropdownMenuItem<int> && w.value == size,
  );
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(item);
  await tester.pumpAndSettle();
}

void main() {
  group('P0B2 每页下拉本地化', () {
    testWidgets('复习页改 10→20：设置默认值不变，错题本首次打开仍是 10 条/页', (tester) async {
      final repo = FakeP0B2Repo();
      await pumpReviewP0B2(tester, repo: repo);
      expect(find.text('共 15 条 · 第 1 / 2 页'), findsOneWidget);

      await pickPageSize(tester, 20);
      expect(find.text('共 15 条 · 第 1 / 1 页'), findsOneWidget);
      // 本地行为：不写库、设置默认值仍是 10。
      expect(repo.settingsValue.pageSize, 10);
      expect(repo.saveSettingsCalls, 0);

      // 同一库新开错题本：仍跟默认值 10（不是复习页改出的 20）。
      await pumpWrongbookP0B2(tester, repo: repo);
      // 十九批 A1：分页无数字按钮，计数与页码分两处断言。
      expect(find.text('共 15 道 · 按收集时间 新 → 旧'), findsOneWidget);
      expect(find.textContaining('第 1/2 页'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is DropdownButton<int> && w.value == 10,
        ),
        findsOneWidget,
      );

      // 反向：错题本改 20 同样不碰设置默认值。
      await pickPageSize(tester, 20);
      expect(find.textContaining('第 1/1 页'), findsOneWidget);
      expect(repo.settingsValue.pageSize, 10);
      expect(repo.saveSettingsCalls, 0);
    });

    testWidgets('设置页 #17 改默认 10→20：两页首次打开跟新默认值', (tester) async {
      final repo = FakeP0B2Repo();
      // Stage 1：设置页经 settingsProvider 读写设置，Fake 用
      // ProviderScope override 注入（原 settings / onSettingsChanged
      // 构造参数已删除，保存直接走 Fake 的 saveSettings，断言不变）。
      await _pump(
        tester,
        ProviderScope(
          // P3：与上面两个调度器 override 的 ProviderScope 同位置
          // 交替出现，须挂 UniqueKey() 防元素复用时 overrides 校验
          // 抛错（见 pumpReviewP0B2 注释）。
          key: UniqueKey(),
          overrides: [repositoryProvider.overrideWithValue(repo)],
          child: SettingsPage(key: UniqueKey()),
        ),
      );
      await tester.tap(find.text('错题本').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('20').first);
      await tester.pumpAndSettle();
      expect(repo.settingsValue.pageSize, 20);
      expect(repo.saveSettingsCalls, 1);

      // 复习页首次打开跟新默认 20。
      await pumpReviewP0B2(tester, repo: repo);
      expect(find.text('共 15 条 · 第 1 / 1 页'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is DropdownButton<int> && w.value == 20,
        ),
        findsOneWidget,
      );

      // 错题本首次打开跟新默认 20。
      await pumpWrongbookP0B2(tester, repo: repo);
      expect(find.text('共 15 道 · 按收集时间 新 → 旧'), findsOneWidget);
      expect(find.textContaining('第 1/1 页'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is DropdownButton<int> && w.value == 20,
        ),
        findsOneWidget,
      );
    });
  });
}
