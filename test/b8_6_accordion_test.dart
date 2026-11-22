// B8-6：整理工作台右侧表单四区手风琴回归（Meng 2026-11-15 Win11
// 验收第 6 项：一次只能展开一个，点开一个就收起其他）。
//
// 口径翻转记录：第二批 Bug 4 时 Meng 要求“能同时打开多个”，
// test/b2_win11bug_organize_test.dart 当时按多开锁了行为（同时开
// 三区 + 文件夹都保持展开）；这次他明确改回手风琴，该组已按新口径
// 重写，本文件另补覆盖：默认态、逐区切换、点已开区收起、确认校验
// 跳回文件夹。左栏「修框切片」是独立折叠段，不参与手风琴。
// 用 FakeRepo，不碰真实数据库；无文件 IO。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/organize/organize_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';

class _B86FakeRepo extends QuestionRepository {
  _B86FakeRepo({required this.questions, required this.folderList})
    : super(AppDatabase.instance);

  List<Question> questions;
  List<Folder> folderList;

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<Folder>> folders({String? subjectId}) async => subjectId == null
      ? List.of(folderList)
      : folderList.where((f) => f.subjectId == subjectId).toList();

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [
    KnowledgePoint(
      id: 'k1',
      subjectId: 'math',
      chapter: '第一章 函数与极限',
      name: '函数极限',
    ),
  ];

  @override
  Future<List<String>> tags() async => const ['易错'];

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<void> save(Question question, {SaveToken? token}) async {}

  @override
  Future<void> syncCauseRecords(Question question) async {}

  @override
  Future<void> saveRecentTask({
    required String kind,
    required String subjectId,
    required String title,
  }) async {}

  @override
  Future<void> saveFolder(Folder folder) async {}

  @override
  Future<void> addTag(String name) async {}

  @override
  Future<void> addExam(Exam exam) async {}

  /// B11-10：OrganizeNotifier 只在队列已空且库里有题时读这两个数
  /// （今日小结行用）；返回 0 / 空，不碰真实库（见 D-88）。
  @override
  Future<int> organizedTodayCount({DateTime? now}) async => 0;

  @override
  Future<List<CauseRecord>> causeRecords() async => const [];

  /// 十三批 M5：OCR 状态是 best-effort 加载（不 await）；返回空任务行
  /// 与“无 key”，不碰真实库（见 D-88）。
  @override
  Future<List<OcrJob>> ocrJobsForQuestion(String questionId) async =>
      const [];

  @override
  Future<bool> hasOcrApiKey() async => false;
}

/// 未选文件夹的待整理题（确认校验跳转用：_folderIds 为空才会拦下）。
Question _pendingQuestion() => Question(
  id: 'q1',
  title: '函数极限',
  subjectId: 'math',
  folderIds: const [],
  sliceKind: 'limit',
  sliceText: '题：lim(x→0) sin 3x / x 的值是（　）',
  createdAt: DateTime(2026, 11, 8),
);

_B86FakeRepo _repo() => _B86FakeRepo(
  questions: [_pendingQuestion()],
  folderList: const [
    Folder(id: 'f1', name: '试卷', subjectId: 'math'),
    Folder(id: 'f2', name: '平时作业', subjectId: 'math'),
  ],
);

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      home: Scaffold(
        body: OrganizePage(
          repo: _repo(),
          onOpenDetail: (_, __, {String? searchContext}) async {},
          onGoReview: () {},
          onGoCollect: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 四区体标记：文件夹体含文件夹名、来源体含选试卷行、分类补充体含
/// 「已选 0 个」、答案体含字段 hint「与解析分开」（_fieldLabel 是
/// Text.rich，find.text('答案') 匹配不到；该串只在答案体里出现一次）。
void _expectOnlyOpen(
  WidgetTester tester, {
  bool folder = false,
  bool source = false,
  bool classify = false,
  bool answer = false,
}) {
  expect(
    find.text('平时作业'),
    folder ? findsOneWidget : findsNothing,
  );
  expect(
    find.text('选择试卷（可选）'),
    source ? findsOneWidget : findsNothing,
  );
  expect(find.text('已选 0 个'), classify ? findsOneWidget : findsNothing);
  expect(
    find.textContaining('与解析分开'),
    answer ? findsOneWidget : findsNothing,
  );
}

void main() {
  group('B8-6 整理表单手风琴：一次只展开一个区', () {
    testWidgets('默认只文件夹展开，其余三区收起；左栏修框切片独立展开',
        (tester) async {
      await _pump(tester);
      _expectOnlyOpen(tester, folder: true);
      // 左栏修框切片不受手风琴影响，仍独立展开。
      expect(find.text('整题框切片'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点开来源收起文件夹；再点分类补充收起来源', (tester) async {
      await _pump(tester);
      await tester.tap(find.text('来源（可选）'));
      await tester.pumpAndSettle();
      _expectOnlyOpen(tester, source: true);
      await tester.tap(find.text('分类补充（可选）'));
      await tester.pumpAndSettle();
      _expectOnlyOpen(tester, classify: true);
      expect(find.text('整题框切片'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点已展开的区收起它：四区全收，只剩左栏切片一个「收起」',
        (tester) async {
      await _pump(tester);
      await tester.tap(find.text('来源（可选）'));
      await tester.pumpAndSettle();
      _expectOnlyOpen(tester, source: true);
      await tester.tap(find.text('来源（可选）'));
      await tester.pumpAndSettle();
      _expectOnlyOpen(tester);
      expect(find.textContaining('收起'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('确认校验跳回文件夹：只开文件夹区，其余收起', (tester) async {
      await _pump(tester);
      // 先打开来源区（文件夹随之收起），再点确认：未选文件夹被拦下，
      // 提示 + 只开文件夹区。
      await tester.tap(find.text('来源（可选）'));
      await tester.pumpAndSettle();
      _expectOnlyOpen(tester, source: true);
      await tester.ensureVisible(find.text('确认整理，去下一道'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认整理，去下一道'));
      await tester.pumpAndSettle();
      expect(find.text('先选文件夹'), findsOneWidget);
      _expectOnlyOpen(tester, folder: true);
      expect(tester.takeException(), isNull);
    });
  });
}
