// B2 leftover：错题本视图模式（大卡片 / 紧凑列表）在 _load() 刷新后保留。
// 回归：_load() 曾每次都用 settings.wrongbookView 覆盖 _viewMode，
// 从题目详情返回（以及点星、批量操作等刷新）都会把用户切好的紧凑
// 列表弹回默认大卡片。修法：只在首次 _load() 应用设置默认值。
// 用独立 FakeRepo（不碰真实数据库），只覆盖本文件用到的 repository 调用。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/wrongbook/wrongbook_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/widgets.dart';

Question _q(
  String id,
  String title, {
  List<String> errorTypes = const [],
  DateTime? createdAt,
  bool isFavorite = false,
}) =>
    Question(
      id: id,
      title: title,
      subjectId: 'math',
      folderIds: const ['f1'],
      errorTypes: errorTypes,
      sliceKind: 'limit',
      sliceText: '题：求极限',
      createdAt: createdAt ?? DateTime.now().subtract(const Duration(days: 2)),
      isOrganized: true,
      isFavorite: isFavorite,
    );

class FakeViewRepo extends QuestionRepository {
  FakeViewRepo({this.settingsValue = const AppSettings()})
      : questions = [
          _q('q1', '函数极限',
              errorTypes: const ['概念不清'],
              createdAt: DateTime.now().subtract(const Duration(days: 2)),
              isFavorite: true),
          _q('q2', '导数综合',
              errorTypes: const ['方法不会'],
              createdAt: DateTime.now().subtract(const Duration(days: 10))),
          _q('q3', '定积分',
              errorTypes: const ['计算错误'],
              createdAt: DateTime.now().subtract(const Duration(days: 5))),
        ],
        super(AppDatabase.instance);

  AppSettings settingsValue;
  List<Question> questions;

  @override
  Future<List<Subject>> subjects() async =>
      [Subject.math, Subject.english, Subject.politics];

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [
        Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
      ];

  @override
  Future<List<Exam>> exams() async => [];

  @override
  Future<List<String>> tags() async => [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => [];

  @override
  Future<Map<String, (int, int, int)>> subjectCounts(
          {bool includeArchived = false}) async =>
      const {'math': (0, 0, 0)};

  @override
  Future<List<CauseRecord>> causeRecords() async => [];

  @override
  Future<AppSettings> settings() async => settingsValue;

  @override
  Future<void> save(Question question) async {
    final i = questions.indexWhere((x) => x.id == question.id);
    if (i >= 0) questions[i] = question;
  }

  @override
  Future<void> toggleFavorite(Question q) async {
    await save(q.copyWith(isFavorite: !q.isFavorite));
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required FakeViewRepo repo,
  Future<void> Function(Question q, List<String> orderIds)? onOpenDetail,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      home: Scaffold(
        body: WrongbookPage(
          key: UniqueKey(),
          repo: repo,
          onOpenHome: () {},
          onOpenDetail: onOpenDetail ?? (_, __) async {},
          onGoReview: ({String? subjectId}) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openMathList(WidgetTester tester) async {
  await tester.tap(find.text('数学'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('全部题目'));
  await tester.pumpAndSettle();
}

void main() {
  group('B2 leftover：视图模式跨 _load() 保留', () {
    testWidgets('首次进入用设置默认值：默认 large 显示大卡片', (tester) async {
      await _pump(tester, repo: FakeViewRepo());
      await _openMathList(tester);
      expect(find.byType(QuestionSlice), findsNWidgets(3));
      expect(find.byType(CompactSliceThumb), findsNothing);
    });

    testWidgets('首次进入用设置默认值：设置 compact 则默认紧凑列表',
        (tester) async {
      await _pump(
        tester,
        repo: FakeViewRepo(
          settingsValue: const AppSettings(wrongbookView: 'compact'),
        ),
      );
      await _openMathList(tester);
      expect(find.byType(CompactSliceThumb), findsNWidgets(3));
      expect(find.byType(QuestionSlice), findsNothing);
    });

    testWidgets('切到紧凑列表后从详情返回，仍是紧凑列表', (tester) async {
      await _pump(tester, repo: FakeViewRepo());
      await _openMathList(tester);
      await tester.tap(find.text('紧凑列表'));
      await tester.pumpAndSettle();
      expect(find.byType(CompactSliceThumb), findsNWidgets(3));
      // 进详情再返回：行 onTap 里 onOpenDetail 之后会 await _load()。
      await tester.tap(find.text('导数综合'));
      await tester.pumpAndSettle();
      expect(find.byType(CompactSliceThumb), findsNWidgets(3));
      expect(find.byType(QuestionSlice), findsNothing);
    });

    testWidgets('切到紧凑列表后点星刷新，仍是紧凑列表', (tester) async {
      final repo = FakeViewRepo();
      await _pump(tester, repo: repo);
      await _openMathList(tester);
      await tester.tap(find.text('紧凑列表'));
      await tester.pumpAndSettle();
      // 行内点星走 _toggleFavorite → _load()。
      await tester.tap(find.text('☆').last);
      await tester.pumpAndSettle();
      expect(find.byType(CompactSliceThumb), findsNWidgets(3));
      expect(find.byType(QuestionSlice), findsNothing);
    });

    testWidgets('切到大卡片后从详情返回，仍是大卡片（双向保留）',
        (tester) async {
      await _pump(
        tester,
        repo: FakeViewRepo(
          settingsValue: const AppSettings(wrongbookView: 'compact'),
        ),
      );
      await _openMathList(tester);
      expect(find.byType(CompactSliceThumb), findsNWidgets(3));
      await tester.tap(find.text('大卡片'));
      await tester.pumpAndSettle();
      expect(find.byType(QuestionSlice), findsNWidgets(3));
      await tester.tap(find.byType(QuestionSlice).first);
      await tester.pumpAndSettle();
      expect(find.byType(QuestionSlice), findsNWidgets(3));
      expect(find.byType(CompactSliceThumb), findsNothing);
    });

    testWidgets('新进错题本重新读设置默认值', (tester) async {
      await _pump(
        tester,
        repo: FakeViewRepo(
          settingsValue: const AppSettings(wrongbookView: 'compact'),
        ),
      );
      await _openMathList(tester);
      expect(find.byType(CompactSliceThumb), findsNWidgets(3));
      // 全新页面实例（新 State，标志位复位）读另一份设置的默认值。
      await _pump(tester, repo: FakeViewRepo());
      await _openMathList(tester);
      expect(find.byType(QuestionSlice), findsNWidgets(3));
      expect(find.byType(CompactSliceThumb), findsNothing);
    });
  });
}
