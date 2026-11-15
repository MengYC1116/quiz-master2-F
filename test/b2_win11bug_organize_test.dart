// B2 Win11 bug 批（工人 B）：整理工作台 Bug 3 / Bug 4 回归测试。
// Bug 2（B8-2 已删）：宽条形真实切片图上 stem / option / figure 虚线
// 叠加层按容器宽度画、右端伸到图片外面——叠加层随二层模型一并移除。
// Bug 3：修框切片里整题框切片卡的边框比里面的图宽，框伸到图片外面。
// Bug 4：表单四区（文件夹 / 来源 / 分类补充 / 答案·解析·笔记）手风琴，
// 一次只开一个；默认文件夹展开、其余折叠。B8-6 口径翻转：第二批时
// Meng 要求“能同时打开多个”，本文件当时按多开锁了行为；2026-11-15
// Win11 验收第 6 项他明确改回手风琴，本组已按新口径重写，详见
// docs/ui-replication/B8-6-ACCORDION.md。
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
/// 第 9 题；sliceText 为空是真实题的形态）。
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

  group('Bug 4：表单四区手风琴（B8-6 翻转：一次只开一个）', () {
    testWidgets('默认只文件夹展开；点开一区、其他区收起；再点已开区收起它',
        (tester) async {
      await _pump(tester, _repoWith([_demoQuestion()]));
      // 默认态：文件夹体可见，来源 / 分类补充体不可见。
      expect(find.text('平时作业'), findsOneWidget);
      expect(find.text('选择试卷（可选）'), findsNothing);
      expect(find.text('已选 0 个'), findsNothing);
      // 打开分类补充：文件夹收起（手风琴，一次只开一个）。
      await tester.tap(find.text('分类补充（可选）'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 个'), findsOneWidget);
      expect(find.text('平时作业'), findsNothing);
      expect(find.text('选择试卷（可选）'), findsNothing);
      // 再打开来源：分类补充收起，只剩来源开着。
      await tester.tap(find.text('来源（可选）'));
      await tester.pumpAndSettle();
      expect(find.text('选择试卷（可选）'), findsOneWidget);
      expect(find.text('已选 0 个'), findsNothing);
      expect(find.text('平时作业'), findsNothing);
      // 再点已展开的来源区：收起它，四区全收（左栏修框切片不受影响，
      // 仍是独立折叠段，单独展开）。
      await tester.tap(find.text('来源（可选）'));
      await tester.pumpAndSettle();
      expect(find.text('选择试卷（可选）'), findsNothing);
      expect(find.text('已选 0 个'), findsNothing);
      expect(find.text('平时作业'), findsNothing);
      // 右侧四区全收时只剩左栏修框切片一个「收起」。
      expect(find.textContaining('收起'), findsOneWidget);
      // 答案区同理：点开只它展开（答案区在页下方，先滚到可见再点）。
      // 答案体标记用字段 hint「与解析分开」（_fieldLabel 是 Text.rich，
      // find.text('答案') 匹配不到；该串只在答案体里出现一次）。
      await tester.ensureVisible(find.text('答案 · 解析 · 笔记（可选）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('答案 · 解析 · 笔记（可选）'));
      await tester.pumpAndSettle();
      expect(find.textContaining('与解析分开'), findsOneWidget);
      expect(find.text('平时作业'), findsNothing);
      expect(find.text('选择试卷（可选）'), findsNothing);
      expect(find.text('已选 0 个'), findsNothing);
    });
  });
}
