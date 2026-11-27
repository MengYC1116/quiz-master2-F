// P0B1-4 设置单 owner 回归测试：复习页分页改 pageSize 与设置页失同步。
//
// 失同步链（改前）：复习页 onChanged 直接 `repo.saveSettings(s)`，
// 绕过了 app 的 `_updateSettings`，app 的 `_settings` 快照仍是旧
// pageSize；设置页 initState 取 `widget.settings`（旧快照）显示旧值，
// 再改别的项时 `_apply(_s.copyWith(...))` 全量写回，把旧 pageSize
// 覆盖回去。P0B1-4 的修法是复习页改分页走 `onSettingsChanged` 回调
// （app 传 `_updateSettings`），写库 + 同步快照同一条路；P0B2 又
// 把复习页分页改成本地行为，回调参数随之删除（见 B2 报告），
// 以下两测按本地口径重写。
// 用 FakeRepo + 模拟的 app 快照复现完整场景，不碰真实数据库。
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
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/state/review_notifier.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';

class FakeOwnerRepo extends QuestionRepository {
  FakeOwnerRepo({AppSettings? settings})
    : settingsValue = settings ?? AppSettings.defaults,
      super(AppDatabase.instance);

  AppSettings settingsValue;
  int saveSettingsCalls = 0;

  /// Stage 1：设置页经 settingsProvider 保存，保存记录在这里
  /// （原 `onSettingsChanged` 回调的观察点改到这里；断言口径不变）。
  final List<AppSettings> savedSettings = [];

  final List<Question> questions = [
    Question(
      id: 'q1',
      title: '函数极限',
      subjectId: 'math',
      errorTypes: const ['概念不清'],
      createdAt: DateTime(2026, 11, 8),
      isOrganized: true,
      reviewJoined: true,
      sliceKind: 'material',
      sliceText: '题：函数极限',
    ),
    Question(
      id: 'q2',
      title: '导数应用综合',
      subjectId: 'math',
      errorTypes: const ['方法不会', '计算错误'],
      createdAt: DateTime(2026, 11, 9),
      isOrganized: true,
      reviewJoined: true,
      sliceKind: 'material',
      sliceText: '题：导数应用综合',
    ),
    Question(
      id: 'q3',
      title: '数列求和',
      subjectId: 'math',
      errorTypes: const ['审题失误'],
      createdAt: DateTime(2026, 11, 10),
      isOrganized: true,
      reviewJoined: true,
      sliceKind: 'material',
      sliceText: '题：数列求和',
    ),
  ];

  final List<CauseRecord> records = [
    CauseRecord(
      questionId: 'q1',
      cause: '概念不清',
      subjectId: 'math',
      joinedAt: DateTime(2026, 11, 10),
    ),
    CauseRecord(
      questionId: 'q2',
      cause: '方法不会',
      subjectId: 'math',
      joinedAt: DateTime(2026, 11, 10, 1),
    ),
    CauseRecord(
      questionId: 'q2',
      cause: '计算错误',
      subjectId: 'math',
      joinedAt: DateTime(2026, 11, 10, 1),
    ),
    // M3 D-138：扁平分页按题行计（不是按错因记录计）。3 道题 =
    // 3 行，pageSize 2 时 2 页、改 20 后 1 页，断言才有区分度。
    CauseRecord(
      questionId: 'q3',
      cause: '审题失误',
      subjectId: 'math',
      joinedAt: DateTime(2026, 11, 10, 2),
    ),
  ];

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<AppSettings> settings() async => settingsValue;

  @override
  Future<void> saveSettings(AppSettings s) async {
    saveSettingsCalls++;
    settingsValue = s;
    savedSettings.add(s);
  }

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

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
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<void> clearReviewState() async {}
}

Future<void> pumpReview(
  WidgetTester tester, {
  required FakeOwnerRepo repo,
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
        theme: AppTheme.light(scale: 1.0),
        home: Scaffold(
          body: ReviewPage(
            key: UniqueKey(),
            repo: repo,
            onOpenDetail: (q, ids, {String? searchContext}) async {},
            onGoWrongbook: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<List<AppSettings>> pumpSettings(
  WidgetTester tester, {
  required FakeOwnerRepo repo,
  required AppSettings settings,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // Stage 1：设置页经 settingsProvider 读写设置——传入的 settings
  // 是“app 快照”，先放进 Fake 的 settingsValue（Provider 的
  // build() 从这里读），再用 ProviderScope override 注入 Fake。
  repo.settingsValue = settings;
  final applied = repo.savedSettings;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        theme: AppTheme.light(scale: 1.0),
        home: Scaffold(body: SettingsPage(key: UniqueKey())),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return applied;
}

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
      // 菜单打开时 value 相同的 DropdownMenuItem 有两个（按钮上显示
      // 的当前值与菜单里的项，后者在树里居后），须取 .last 才是
      // 菜单里可点的那项（review_page_test 同款做法）。
      .last;
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(item);
  await tester.pumpAndSettle();
}

Future<void> openGroup(WidgetTester tester, String title) async {
  await tester.ensureVisible(find.text(title).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(title).first);
  await tester.pumpAndSettle();
}

void main() {
  // P0B2 已取代 P0B1-4 的复习分页口径：复习页“每页”下拉改成本地行为
  // （与错题本一致），不改设置、不写库；ReviewPage 已无
  // onSettingsChanged 参数。设置页 #17 仍是改默认值的唯一入口。
  // 以下两测按新口径重写，设置页本身那测不变。
  group('P0B2 复习分页本地化：复习分页 ↔ 设置页', () {
    testWidgets('复习页改每页数量：本页显示变了，库与设置默认值不动', (tester) async {
      final repo = FakeOwnerRepo(
        settings: AppSettings.defaults.copyWith(pageSize: 2),
      );
      await pumpReview(tester, repo: repo);
      expect(find.text('共 3 道 · 第 1 / 2 页'), findsOneWidget);

      await pickMenuItem<int>(tester, find.byType(DropdownButton<int>), 20);
      expect(find.text('共 3 道 · 第 1 / 1 页'), findsOneWidget);

      // 本地行为：库不写、设置默认值仍是 2。
      expect(repo.settingsValue.pageSize, 2);
      expect(repo.saveSettingsCalls, 0);
    });

    testWidgets('设置页：拿到新快照后显示 20，改主题不再把 pageSize 覆盖回去', (tester) async {
      final repo = FakeOwnerRepo();
      // 设置页取 app 快照（此处直接给 20，模拟已在设置页改过默认值；
      // P0B2 起复习页改每页不再产生这样的快照）。
      final appSnapshot = AppSettings.defaults.copyWith(pageSize: 20);
      final applied = await pumpSettings(
        tester,
        repo: repo,
        settings: appSnapshot,
      );

      await openGroup(tester, '错题本');
      // “每页显示数量”分段选中 20（不是旧值 10）。
      expect(
        find.byWidgetPredicate((w) => w is QmSegmented<int> && w.value == 20),
        findsOneWidget,
      );

      // 再改另一项（主题换深色）：写回的设置里 pageSize 仍是 20。
      await openGroup(tester, '外观');
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      expect(applied.last.themeMode, 'dark');
      expect(applied.last.pageSize, 20);
    });

    testWidgets('改每页数量不写库、不持久化：重开复习页仍跟默认值', (tester) async {
      final repo = FakeOwnerRepo(
        settings: AppSettings.defaults.copyWith(pageSize: 2),
      );
      await pumpReview(tester, repo: repo);
      await pickMenuItem<int>(tester, find.byType(DropdownButton<int>), 20);
      expect(find.text('共 3 道 · 第 1 / 1 页'), findsOneWidget);
      expect(repo.settingsValue.pageSize, 2);
      expect(repo.saveSettingsCalls, 0);

      // 本地改动不持久化：重开一页仍是默认值 2（2 页）。
      await pumpReview(tester, repo: repo);
      expect(find.text('共 3 道 · 第 1 / 2 页'), findsOneWidget);
    });
  });
}
