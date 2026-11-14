// P0B1-4 设置单 owner 回归测试：复习页分页改 pageSize 与设置页失同步。
//
// 失同步链（改前）：复习页 onChanged 直接 `repo.saveSettings(s)`，
// 绕过了 app 的 `_updateSettings`，app 的 `_settings` 快照仍是旧
// pageSize；设置页 initState 取 `widget.settings`（旧快照）显示旧值，
// 再改别的项时 `_apply(_s.copyWith(...))` 全量写回，把旧 pageSize
// 覆盖回去。修法：复习页改分页也走 `onSettingsChanged` 回调
// （app 传 `_updateSettings`），写库 + 同步快照同一条路。
// 用 FakeRepo + 模拟的 app 快照复现完整场景，不碰真实数据库。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/review/review_page.dart';
import 'package:quiz_master2/modules/settings/settings_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';

class FakeOwnerRepo extends QuestionRepository {
  FakeOwnerRepo({AppSettings? settings})
      : settingsValue = settings ?? AppSettings.defaults,
        super(AppDatabase.instance);

  AppSettings settingsValue;
  int saveSettingsCalls = 0;

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
  ];

  final List<CauseRecord> records = [
    CauseRecord(
      questionId: 'q1',
      cause: '概念不清',
      subjectId: 'math',
      status: CauseStatus.pending,
      joinedAt: DateTime(2026, 11, 10),
    ),
    CauseRecord(
      questionId: 'q2',
      cause: '方法不会',
      subjectId: 'math',
      status: CauseStatus.inProgress,
      solvedCount: 1,
      lastCheck: DateTime(2026, 11, 10),
      joinedAt: DateTime(2026, 11, 10, 1),
    ),
    CauseRecord(
      questionId: 'q2',
      cause: '计算错误',
      subjectId: 'math',
      status: CauseStatus.pending,
      joinedAt: DateTime(2026, 11, 10, 1),
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
  }

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<ReviewSessionState?> reviewState() async => null;
}

Future<void> pumpReview(
  WidgetTester tester, {
  required FakeOwnerRepo repo,
  Future<void> Function(AppSettings s)? onSettingsChanged,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      home: Scaffold(
        body: ReviewPage(
          key: UniqueKey(),
          repo: repo,
          onOpenDetail: (q, ids) async {},
          onGoWrongbook: () {},
          onSettingsChanged: onSettingsChanged,
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
  final applied = <AppSettings>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      home: Scaffold(
        body: SettingsPage(
          key: UniqueKey(),
          repo: repo,
          settings: settings,
          onSettingsChanged: (s) async => applied.add(s),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return applied;
}

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

Future<void> openGroup(WidgetTester tester, String title) async {
  await tester.ensureVisible(find.text(title).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(title).first);
  await tester.pumpAndSettle();
}

void main() {
  // P0B2 已取代 P0B1-4 的复习分页口径：复习页“每页”下拉改成本地行为
  // （与错题本一致），不再经 onSettingsChanged 改设置、不写库；
  // 设置页 #17 仍是改默认值的唯一入口。以下两测按新口径重写，
  // 设置页本身那测不变。
  group('P0B2 复习分页本地化：复习分页 ↔ 设置页', () {
    testWidgets('复习页改每页数量：本页显示变了，回调不触发、库与快照不动',
        (tester) async {
      // 模拟 app：_updateSettings（写库 + 更新 _settings 快照）。
      final repo = FakeOwnerRepo(
        settings: AppSettings.defaults.copyWith(pageSize: 2),
      );
      var appSnapshot = AppSettings.defaults.copyWith(pageSize: 2);
      final notified = <AppSettings>[];
      await pumpReview(
        tester,
        repo: repo,
        onSettingsChanged: (s) async {
          notified.add(s);
          appSnapshot = s;
          await repo.saveSettings(s);
        },
      );
      expect(find.text('共 3 条 · 第 1 / 2 页'), findsOneWidget);

      await pickMenuItem<int>(
          tester, find.byType(DropdownButton<int>), 20);
      expect(find.text('共 3 条 · 第 1 / 1 页'), findsOneWidget);

      // 本地行为：回调收不到、库不写、app 快照仍是 2。
      expect(repo.settingsValue.pageSize, 2);
      expect(repo.saveSettingsCalls, 0);
      expect(notified, isEmpty);
      expect(appSnapshot.pageSize, 2);
    });

    testWidgets('设置页：拿到新快照后显示 20，改主题不再把 pageSize 覆盖回去',
        (tester) async {
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
        find.byWidgetPredicate(
            (w) => w is QmSegmented<int> && w.value == 20),
        findsOneWidget,
      );

      // 再改另一项（主题换深色）：写回的设置里 pageSize 仍是 20。
      await openGroup(tester, '外观');
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      expect(applied.last.themeMode, 'dark');
      expect(applied.last.pageSize, 20);
    });

    testWidgets('未接回调时也不写库（P0B2：本地行为，无回退写库）',
        (tester) async {
      final repo = FakeOwnerRepo(
        settings: AppSettings.defaults.copyWith(pageSize: 2),
      );
      await pumpReview(tester, repo: repo);
      await pickMenuItem<int>(
          tester, find.byType(DropdownButton<int>), 20);
      expect(find.text('共 3 条 · 第 1 / 1 页'), findsOneWidget);
      expect(repo.settingsValue.pageSize, 2);
      expect(repo.saveSettingsCalls, 0);
    });
  });
}
