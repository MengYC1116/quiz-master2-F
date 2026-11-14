// P0B2 “每页”下拉本地化回归测试：复习页与错题本一致，只改本页显示。
//
// 口径（Meng 定）：两页的“每页”下拉都是本地 setState，初值仍从设置
// 默认值（设置页 #17“每页显示数量”）读；下拉改动不写库、不调
// onSettingsChanged、不改设置默认值。设置页 #17 仍是改默认值的
// 唯一入口，两页首次打开跟新默认值。
// 用 FakeRepo 覆盖三页的 repository 调用，不碰真实数据库。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/review/review_page.dart';
import 'package:quiz_master2/modules/settings/settings_page.dart';
import 'package:quiz_master2/modules/wrongbook/wrongbook_page.dart';
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

  @override
  Future<Map<String, (int, int, int)>> subjectCounts(
          {bool includeArchived = false}) async =>
      const {'math': (0, 0, 0)};

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<ReviewSessionState?> reviewState() async => null;
}

Future<void> _pump(
  WidgetTester tester,
  Widget page,
) async {
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
  List<AppSettings>? notified,
}) async {
  await _pump(
    tester,
    ReviewPage(
      key: UniqueKey(),
      repo: repo,
      onOpenDetail: (q, ids) async {},
      onGoWrongbook: () {},
      onSettingsChanged: (s) async => notified?.add(s),
    ),
  );
}

Future<void> pumpWrongbookP0B2(
  WidgetTester tester, {
  required FakeP0B2Repo repo,
}) async {
  await _pump(
    tester,
    WrongbookPage(
      key: UniqueKey(),
      repo: repo,
      initialSubjectId: 'math',
      onOpenHome: () {},
      onOpenDetail: (q, ids) async {},
      onGoReview: ({String? subjectId}) {},
    ),
  );
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
      (w) => w is DropdownMenuItem<int> && w.value == size);
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(item);
  await tester.pumpAndSettle();
}

void main() {
  group('P0B2 每页下拉本地化', () {
    testWidgets('复习页改 10→20：设置默认值不变，错题本首次打开仍是 10 条/页',
        (tester) async {
      final repo = FakeP0B2Repo();
      final notified = <AppSettings>[];
      await pumpReviewP0B2(tester, repo: repo, notified: notified);
      expect(find.text('共 15 条 · 第 1 / 2 页'), findsOneWidget);

      await pickPageSize(tester, 20);
      expect(find.text('共 15 条 · 第 1 / 1 页'), findsOneWidget);
      // 本地行为：不写库、不调回调、设置默认值仍是 10。
      expect(repo.settingsValue.pageSize, 10);
      expect(repo.saveSettingsCalls, 0);
      expect(notified, isEmpty);

      // 同一库新开错题本：仍跟默认值 10（不是复习页改出的 20）。
      await pumpWrongbookP0B2(tester, repo: repo);
      expect(find.text('共 15 道 · 第 1 / 2 页'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
            (w) => w is DropdownButton<int> && w.value == 10),
        findsOneWidget,
      );

      // 反向：错题本改 20 同样不碰设置默认值。
      await pickPageSize(tester, 20);
      expect(find.text('共 15 道 · 第 1 / 1 页'), findsOneWidget);
      expect(repo.settingsValue.pageSize, 10);
      expect(repo.saveSettingsCalls, 0);
    });

    testWidgets('设置页 #17 改默认 10→20：两页首次打开跟新默认值',
        (tester) async {
      final repo = FakeP0B2Repo();
      // 模拟 app：设置页改动经 _updateSettings 写库。
      await _pump(
        tester,
        SettingsPage(
          key: UniqueKey(),
          repo: repo,
          settings: repo.settingsValue,
          onSettingsChanged: (s) async => repo.saveSettings(s),
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
            (w) => w is DropdownButton<int> && w.value == 20),
        findsOneWidget,
      );

      // 错题本首次打开跟新默认 20。
      await pumpWrongbookP0B2(tester, repo: repo);
      expect(find.text('共 15 道 · 第 1 / 1 页'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
            (w) => w is DropdownButton<int> && w.value == 20),
        findsOneWidget,
      );
    });
  });
}
