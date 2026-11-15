// B2 Win11 bug 批（工人 B）：整理工作台 Bug 2 / Bug 3 / Bug 4 回归测试。
//
// Bug 2：真实切片图是宽条形（固有尺寸窄于布局容器）时，stem / option /
// figure 虚线框按容器宽度画，右端伸到图片外面；放大查看 overlay 同样。
// Bug 3：修框切片里整题框切片卡的边框比里面的图宽，框伸到图片外面。
// Bug 4：表单四区（文件夹 / 来源 / 分类补充 / 答案·解析·笔记）须各自
// 独立折叠，可同时打开多个；默认文件夹展开、其余折叠。
//
// 夹具：test/fixtures/slice-narrow-500x120.png（500×120 白底黑条，
// 模拟真实题目切片：固有宽度 500，小于 1280 宽窗口下左栏约 628 的
// 容器宽）。B3-P01：slicePath 不再用绝对路径（resolveDataPath
// 已拒绝绝对路径）；夹具在 setUpAll 拷进 testDataDirectory，
// slicePath 用相对路径 `slices/q-real.png`，预热用的绝对路径
// 只传给 precacheImage 的 FileImage，不走 resolveDataPath。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/organize/organize_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/widgets.dart';

class _FakeRepo extends QuestionRepository {
  _FakeRepo({required this.questions, required this.folderList})
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
  Future<void> save(Question question) async {}

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
}

/// 带真实窄切片的题（复现 Win11 上报的那道：英语 gs_p018.png 第 1 页
/// 第 9 题；sliceText 为空是真实题的形态，区域只剩 stem）。
Question _realSliceQuestion(String slicePath) => Question(
  id: 'q-real',
  title: 'gs_p018.png · 第1页 · 第9题',
  subjectId: 'english',
  folderIds: const [],
  sliceKind: 'limit',
  sliceText: '',
  slicePath: slicePath,
  sliceWidth: 500,
  sliceHeight: 120,
  createdAt: DateTime(2026, 11, 8),
);

Question _demoQuestion() => Question(
  id: 'q-demo',
  title: '函数极限',
  subjectId: 'math',
  folderIds: const ['f1'],
  sliceKind: 'limit',
  sliceText: '题：lim(x→0) sin 3x / x 的值是（　）',
  createdAt: DateTime(2026, 11, 8),
);

Future<void> _pump(
  WidgetTester tester,
  QuestionRepository repo, {
  String? sliceAbs,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (sliceAbs != null) {
    // Image.file 的真实解码在 fake zone 里等不到完成（见
    // p2_main_chain_test 的注释），图会一直是 0 尺寸、量不到几何。
    // 先用真实异步把图预热进 imageCache：cacheWidth 须与
    // QuestionSlice 两处调用一致（纸面图 480*2=960、切片卡 220*2=440），
    // 键一致才命中缓存；预热完再正常 pump，图同步有尺寸。
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SizedBox(key: Key('precache-anchor'))),
      ),
    );
    final ctx = tester.element(find.byKey(const Key('precache-anchor')));
    final file = File(sliceAbs);
    await tester.runAsync(() async {
      await precacheImage(ResizeImage(FileImage(file), width: 960), ctx);
      await precacheImage(ResizeImage(FileImage(file), width: 440), ctx);
    });
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      home: Scaffold(
        body: OrganizePage(
          repo: repo,
          onOpenDetail: (_, __) async {},
          onGoReview: () {},
          onGoCollect: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

_FakeRepo _repoWith(List<Question> qs) => _FakeRepo(
  questions: qs,
  folderList: const [
    Folder(id: 'f1', name: '试卷', subjectId: 'math'),
    Folder(id: 'f2', name: '平时作业', subjectId: 'math'),
    Folder(id: 'f3', name: '试卷', subjectId: 'english'),
  ],
);

void main() {
  late Directory fixtureTmp;
  late String sliceAbs; // 临时目录里的夹具副本绝对路径（只给预热用）
  late String sliceRel; // 库内相对路径（给 Question.slicePath 用）

  setUpAll(() async {
    fixtureTmp = await Directory.systemTemp.createTemp('b2-organize-');
    final sliceDir = Directory('${fixtureTmp.path}/slices');
    await sliceDir.create(recursive: true);
    final fixture = File('test/fixtures/slice-narrow-500x120.png');
    expect(fixture.existsSync(), isTrue);
    final copy = await fixture.copy('${sliceDir.path}/q-real.png');
    sliceAbs = copy.path;
    sliceRel = 'slices/q-real.png';
    AppDatabase.testDataDirectory = fixtureTmp.path;
  });

  tearDownAll(() async {
    AppDatabase.testDataDirectory = null;
    try {
      await fixtureTmp.delete(recursive: true);
    } catch (_) {}
  });

  group('Bug 2：区域虚线框不超出图片边界', () {
    testWidgets('整理页：stem 框右端不超过整题图右端', (tester) async {
      await _pump(
        tester,
        _repoWith([_realSliceQuestion(sliceRel)]),
        sliceAbs: sliceAbs,
      );
      // 整理页只画一个 overlay（_paperImage），图是第一张 Image。
      expect(find.byType(QuestionRegionOverlays), findsOneWidget);
      expect(find.byType(Image), findsNWidgets(2)); // 纸面图 + 切片卡图
      final overlayRect = tester.getRect(find.byType(QuestionRegionOverlays));
      final paperRect = tester.getRect(find.byType(QuestionSlice).first);
      final imageRect = tester.getRect(find.byType(Image).first);
      // 图固有宽 500，小于左栏容器宽：修好前 overlay 宽 ≈ 容器宽 629。
      expect(imageRect.width, closeTo(500, 1));
      // 叠加层与纸面容器同宽（容器比图宽 2px 是 1px 边框 ×2）。
      expect(overlayRect.width, closeTo(paperRect.width, 1));
      expect(overlayRect.left, closeTo(paperRect.left, 1));
      // stem 框是叠加层左右各 inset 10px：左右都不出图（图 = 纸面去 1px 边框）。
      expect(overlayRect.left + 10, greaterThanOrEqualTo(imageRect.left - 1));
      expect(overlayRect.right - 10, lessThanOrEqualTo(imageRect.right + 1));
    });

    testWidgets('放大查看：stem 框右端不超过整题图右端', (tester) async {
      await _pump(
        tester,
        _repoWith([_realSliceQuestion(sliceRel)]),
        sliceAbs: sliceAbs,
      );
      await tester.tap(find.byType(Image).first);
      await tester.pumpAndSettle();
      expect(find.text('整题图 · 放大查看'), findsOneWidget);
      // 整理页一个 overlay + 对话框里一个；对话框里是最后一个。
      expect(find.byType(QuestionRegionOverlays), findsNWidgets(2));
      final overlayRect = tester.getRect(
        find.byType(QuestionRegionOverlays).last,
      );
      final paperRect = tester.getRect(find.byType(QuestionSlice).last);
      final imageRect = tester.getRect(find.byType(Image).last);
      // 对话框里 InteractiveViewer 带缩放（修好后纸面 500 宽，fit 到
      // 150%），图与框同乘一个变换：只断言相对关系。修好前 overlay
      // 是 680 宽的 Stack，图只有 500 宽。
      expect(overlayRect.width, closeTo(paperRect.width, 2));
      expect(overlayRect.left, closeTo(paperRect.left, 2));
      expect(overlayRect.right, closeTo(paperRect.right, 2));
      expect(overlayRect.width, lessThanOrEqualTo(imageRect.width + 5));
    });
  });

  group('Bug 3：修框切片卡不比图宽', () {
    testWidgets('整题框切片卡右端不超过图右端', (tester) async {
      await _pump(
        tester,
        _repoWith([_realSliceQuestion(sliceRel)]),
        sliceAbs: sliceAbs,
      );
      expect(find.text('整题框切片'), findsOneWidget);
      // 切片卡图是第二张 Image；卡是离「整题框切片」文字最近的 Container。
      final imageRect = tester.getRect(find.byType(Image).at(1));
      final cardRect = tester.getRect(
        find
            .ancestor(of: find.text('整题框切片'), matching: find.byType(Container))
            .first,
      );
      // 修好前卡宽 ≈ 左栏宽 591，图只有 268 宽，卡框伸到图外面。
      // 修好后卡贴图：卡比图宽的只是卡自身内边距（左右 10）+ 两层
      // 1px 边框（卡 1px + 纸面 1px），共约 24px。
      expect(cardRect.width, lessThanOrEqualTo(imageRect.width + 25));
      expect(imageRect.left - cardRect.left, lessThanOrEqualTo(12));
      expect(cardRect.right - imageRect.right, lessThanOrEqualTo(12));
    });
  });

  group('Bug 4：表单各区独立折叠', () {
    testWidgets('默认文件夹展开、其余折叠；同时打开两区都保持展开', (tester) async {
      await _pump(tester, _repoWith([_demoQuestion()]));
      // 默认态：文件夹体可见，来源 / 分类补充体不可见。
      expect(find.text('平时作业'), findsOneWidget);
      expect(find.text('选择试卷（可选）'), findsNothing);
      expect(find.text('已选 0 个'), findsNothing);
      // 打开分类补充，再打开来源：两者 + 文件夹三区同时展开。
      await tester.tap(find.text('分类补充（可选）'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 个'), findsOneWidget);
      await tester.tap(find.text('来源（可选）'));
      await tester.pumpAndSettle();
      expect(find.text('选择试卷（可选）'), findsOneWidget);
      expect(find.text('已选 0 个'), findsOneWidget);
      expect(find.text('平时作业'), findsOneWidget);
      // 再打开答案区：之前开着的三区仍保持展开（答案区在页下方，
      // 先滚到可见再点；收起数从 4 变 5）。
      expect(find.textContaining('收起'), findsNWidgets(4));
      await tester.ensureVisible(find.text('答案 · 解析 · 笔记（可选）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('答案 · 解析 · 笔记（可选）'));
      await tester.pumpAndSettle();
      expect(find.textContaining('收起'), findsNWidgets(5));
      expect(find.text('选择试卷（可选）'), findsOneWidget);
      expect(find.text('已选 0 个'), findsOneWidget);
      expect(find.text('平时作业'), findsOneWidget);
    });
  });
}
