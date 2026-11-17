// R6 错题本 widget 测试：三层链路（书架 → 目录 → 列表）、目录树展开 /
// 移动禁则、筛选面板无学科 / 文件夹下拉、大卡片形态与序号重编号、
// 批量模式、分页、亮 / 深 × 三档缩放无溢出、页内无边距、不用图标字体。
// 用 FakeRepo 覆盖 repository 调用（不碰真实数据库，不改口径）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/wrongbook/wrongbook_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/widgets.dart';

Question wbq(
  String id,
  String title, {
  String subjectId = 'math',
  String sliceKind = 'limit',
  String sliceText = '题：求极限',
  List<String> folderIds = const [],
  String? examId,
  List<String> errorTypes = const [],
  List<String> customErrorTypes = const [],
  List<String> tags = const [],
  DateTime? createdAt,
  bool isOrganized = true,
  bool isArchived = false,
  bool isFavorite = false,
}) => Question(
  id: id,
  title: title,
  subjectId: subjectId,
  folderIds: folderIds,
  examId: examId,
  errorTypes: errorTypes,
  customErrorTypes: customErrorTypes,
  tags: tags,
  sliceKind: sliceKind,
  sliceText: sliceText,
  createdAt: createdAt ?? DateTime.now().subtract(const Duration(days: 2)),
  isOrganized: isOrganized,
  isArchived: isArchived,
  isFavorite: isFavorite,
);

class FakeWrongbookRepo extends QuestionRepository {
  FakeWrongbookRepo({
    required List<Question> questions,
    required List<Folder> folderList,
    List<Exam> examList = const [],
    List<KnowledgePoint> kpList = const [],
    List<String> tagList = const [],
    List<CauseRecord> records = const [],
    this.counts = const {},
    List<Subject>? subjects,
    this.settingsValue = const AppSettings(),
  }) : questions = List.of(questions),
       folderList = List.of(folderList),
       examList = List.of(examList),
       kpList = List.of(kpList),
       tagList = List.of(tagList),
       records = List.of(records),
       subjectsValue =
           subjects ??
           [
             Subject.math.copyWith(coverColor: 'green'),
             Subject.english,
             Subject.politics,
           ],
       super(AppDatabase.instance);

  List<Question> questions;
  List<Folder> folderList;
  List<Exam> examList;
  List<KnowledgePoint> kpList;
  List<String> tagList;
  List<CauseRecord> records;
  Map<String, (int, int, int)> counts;
  List<Subject> subjectsValue;
  AppSettings settingsValue;

  final List<Question> saved = [];
  final List<String> deletedIds = [];
  final List<Folder> savedFolders = [];
  final List<String> deletedFolderIds = [];
  final List<String> toggledFavoriteIds = [];
  final List<(String, bool)> archivedChanges = [];

  /// SR-P2-36：防线测试用——设置后 saveFolder 抛该错误。
  Object? saveFolderError;

  /// SR-P2-48：错误态测试用——设置后 subjects() 抛错，模拟读库失败。
  bool throwOnLoad = false;

  /// SR-P2-36：整科同名预检（按 fake 的 folderList 实扫，与真实
  /// AppDatabase.folderNameExistsInSubjectFrom 同语义）。
  @override
  Future<bool> folderNameExistsInSubject(
    String subjectId,
    String name, {
    String? excludeId,
  }) async => folderList.any(
    (f) => f.subjectId == subjectId && f.name == name && f.id != excludeId,
  );

  @override
  Future<List<Subject>> subjects() async {
    if (throwOnLoad) throw StateError('boom');
    return List.of(subjectsValue);
  }

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<Folder>> folders({String? subjectId}) async => subjectId == null
      ? List.of(folderList)
      : folderList.where((f) => f.subjectId == subjectId).toList();

  @override
  Future<List<Exam>> exams() async => List.of(examList);

  @override
  Future<List<String>> tags() async => List.of(tagList);

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => List.of(kpList);

  @override
  Future<Map<String, (int, int, int)>> subjectCounts({
    bool includeArchived = false,
  }) async => counts;

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<AppSettings> settings() async => settingsValue;

  @override
  Future<void> save(Question question) async {
    saved.add(question);
    final i = questions.indexWhere((x) => x.id == question.id);
    if (i >= 0) {
      questions[i] = question;
    } else {
      questions.add(question);
    }
  }

  @override
  Future<void> delete(Question question) async {
    deletedIds.add(question.id);
    questions.removeWhere((x) => x.id == question.id);
  }

  @override
  Future<void> saveFolder(Folder folder) async {
    if (saveFolderError != null) throw saveFolderError!;
    savedFolders.add(folder);
    final i = folderList.indexWhere((x) => x.id == folder.id);
    if (i >= 0) {
      folderList[i] = folder;
    } else {
      folderList.add(folder);
    }
  }

  @override
  Future<int> deleteFolder(Folder folder) async {
    deletedFolderIds.add(folder.id);
    final ids = <String>{folder.id};
    void collect(String id) {
      for (final s in folderList.where((f) => f.parentId == id)) {
        ids.add(s.id);
        collect(s.id);
      }
    }

    collect(folder.id);
    questions.removeWhere(
      (q) =>
          q.folderIds.isNotEmpty && q.folderIds.every((id) => ids.contains(id)),
    );
    folderList.removeWhere((f) => ids.contains(f.id));
    return 1;
  }

  @override
  Future<void> toggleFavorite(Question q) async {
    toggledFavoriteIds.add(q.id);
    await save(q.copyWith(isFavorite: !q.isFavorite));
  }

  @override
  Future<void> archive(Question q, {bool archived = true}) async {
    archivedChanges.add((q.id, archived));
    await save(q.copyWith(isArchived: archived));
  }

  @override
  Future<void> addTag(String name) async {
    if (!tagList.contains(name)) tagList.add(name);
  }
}

FakeWrongbookRepo threeSubjectRepo() {
  final now = DateTime.now();
  return FakeWrongbookRepo(
    questions: [
      wbq(
        'q1',
        '函数极限',
        folderIds: const ['f1'],
        examId: 'e1',
        errorTypes: const ['概念不清'],
        tags: const ['易错'],
        sliceText: '题：lim(x→0) sin 3x / x 单调递增',
        createdAt: now.subtract(const Duration(days: 2)),
        isFavorite: true,
      ),
      wbq(
        'q2',
        '导数综合',
        sliceKind: 'function',
        sliceText: '题：设 f(x) = x³ − 3x² + 2，求单调区间',
        folderIds: const ['f2'],
        errorTypes: const ['方法不会'],
        tags: const ['常考'],
        createdAt: now.subtract(const Duration(days: 10)),
      ),
      wbq(
        'q3',
        '定积分',
        sliceKind: 'chart',
        sliceText: '题：求阴影面积',
        folderIds: const ['f1'],
        errorTypes: const ['计算错误'],
        tags: const ['需重做'],
        createdAt: now.subtract(const Duration(days: 5)),
      ),
      wbq(
        'q4',
        '阅读主旨',
        subjectId: 'english',
        sliceKind: 'material',
        sliceText: '题：The evidence ______ the hypothesis.',
        folderIds: const ['f3'],
        errorTypes: const ['审题失误'],
        createdAt: now.subtract(const Duration(days: 3)),
      ),
      wbq(
        'q8',
        '图表作文',
        subjectId: 'english',
        sliceKind: 'chart',
        sliceText: '题：Describe the chart.',
        folderIds: const ['f3'],
        errorTypes: const ['方法不会'],
        tags: const ['需重做'],
        createdAt: now.subtract(const Duration(days: 4)),
      ),
      wbq(
        'q7',
        '极限已掌握',
        sliceText: '题：已掌握的极限题',
        folderIds: const ['f1'],
        errorTypes: const ['概念不清'],
        createdAt: now.subtract(const Duration(days: 6)),
      ),
      wbq(
        'q5',
        '旧题',
        sliceText: '题：已归档的旧题',
        folderIds: const ['f1'],
        errorTypes: const ['审题失误'],
        createdAt: now.subtract(const Duration(days: 20)),
        isArchived: true,
      ),
      wbq(
        'q6',
        '未整理题',
        sliceText: '题：还没整理的题',
        // 未整理但导入时已挂文件夹：目录计数必须不算它（与列表口径一致），
        // 否则“平时作业”行会写 1 道题、点进去却是空列表。
        folderIds: const ['f2'],
        errorTypes: const ['概念不清'],
        createdAt: now.subtract(const Duration(days: 1)),
        isOrganized: false,
      ),
    ],
    folderList: const [
      Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
      Folder(
        id: 'f1s',
        name: '期中试卷',
        subjectId: 'math',
        parentId: 'f1',
        sortOrder: 0,
      ),
      Folder(id: 'f2', name: '平时作业', subjectId: 'math', sortOrder: 10),
      Folder(id: 'f3', name: '试卷', subjectId: 'english', sortOrder: 0),
      Folder(id: 'f4', name: '平时作业', subjectId: 'english', sortOrder: 10),
      Folder(id: 'f5', name: '模拟卷', subjectId: 'politics', sortOrder: 0),
    ],
    examList: [Exam(id: 'e1', name: '高等数学期末试卷', date: DateTime(2026, 11, 10))],
    kpList: const [
      KnowledgePoint(
        id: 'k1',
        subjectId: 'math',
        chapter: '第一章 函数与极限',
        name: '函数极限',
      ),
      KnowledgePoint(
        id: 'k2',
        subjectId: 'math',
        chapter: '第一章 函数与极限',
        name: '导数概念',
      ),
    ],
    tagList: const ['易错', '常考', '需重做'],
    records: [
      CauseRecord(
        questionId: 'q1',
        cause: '概念不清',
        subjectId: 'math',
        status: CauseStatus.pending,
        joinedAt: DateTime.now(),
      ),
      CauseRecord(
        questionId: 'q2',
        cause: '方法不会',
        subjectId: 'math',
        status: CauseStatus.pending,
        joinedAt: DateTime.now(),
      ),
      CauseRecord(
        questionId: 'q3',
        cause: '计算错误',
        subjectId: 'math',
        status: CauseStatus.inProgress,
        solvedCount: 1,
        joinedAt: DateTime.now(),
      ),
      CauseRecord(
        questionId: 'q4',
        cause: '审题失误',
        subjectId: 'english',
        status: CauseStatus.pending,
        joinedAt: DateTime.now(),
      ),
      CauseRecord(
        questionId: 'q8',
        cause: '方法不会',
        subjectId: 'english',
        status: CauseStatus.solved,
        solvedCount: 2,
        recheckDate: DateTime.now().subtract(const Duration(days: 1)),
        joinedAt: DateTime.now(),
      ),
      CauseRecord(
        questionId: 'q7',
        cause: '概念不清',
        subjectId: 'math',
        status: CauseStatus.solved,
        solvedCount: 2,
        recheckDate: DateTime.now().add(const Duration(days: 7)),
        joinedAt: DateTime.now(),
      ),
    ],
    counts: const {
      'math': (2, 0, 1),
      'english': (1, 1, 0),
      'politics': (0, 0, 0),
    },
  );
}

FakeWrongbookRepo manyQuestionRepo() {
  final now = DateTime.now();
  return FakeWrongbookRepo(
    questions: [
      for (var i = 0; i < 12; i++)
        wbq(
          'm$i',
          '数学题 $i',
          folderIds: const ['f1'],
          errorTypes: const ['概念不清'],
          createdAt: now.subtract(Duration(days: i + 1)),
        ),
    ],
    folderList: const [
      Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
    ],
    counts: const {'math': (0, 0, 0)},
  );
}

Future<void> pumpWrongbook(
  WidgetTester tester, {
  FakeWrongbookRepo? repo,
  String? initialSubjectId,
  String? filterCause,
  String? filterKnowledgePointId,
  Brightness brightness = Brightness.light,
  double scale = 1.0,
  Key? pageKey,
  Future<void> Function(Question q, List<String> orderIds)? onOpenDetail,
  void Function({String? subjectId})? onGoReview,
  VoidCallback? onGoCollect,
  VoidCallback? onGoOrganize,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: scale),
      darkTheme: AppTheme.dark(scale: scale),
      themeMode: brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      home: Builder(
        builder: (context) {
          final data = MediaQuery.of(context);
          return MediaQuery(
            data: data.copyWith(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: WrongbookPage(
                key: pageKey ?? UniqueKey(),
                repo: repo ?? threeSubjectRepo(),
                initialSubjectId: initialSubjectId,
                filterCause: filterCause,
                filterKnowledgePointId: filterKnowledgePointId,
                onOpenHome: () {},
                onGoCollect: onGoCollect,
                onGoOrganize: onGoOrganize,
                onOpenDetail: onOpenDetail ?? (_, __) async {},
                onGoReview: onGoReview ?? ({String? subjectId}) {},
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 只匹配普通 Text（不匹配搜索框里的 EditableText）：搜索框输入查询词后，
/// 查询词与行标题同文时 find.text 会把两者都算上。
Finder plainText(String s) =>
    find.byWidgetPredicate((w) => w is Text && w.data == s);

Future<void> openMathList(WidgetTester tester) async {
  await tester.tap(find.text('数学'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('全部题目'));
  await tester.pumpAndSettle();
}

Future<void> openMathListCompact(WidgetTester tester) async {
  await openMathList(tester);
  await tester.tap(find.text('紧凑列表'));
  await tester.pumpAndSettle();
}

/// 紧凑列表第一个缩略图的纸面色（根 Container 的 BoxDecoration.color）。
Color _thumbPaperColor(WidgetTester tester) {
  final container = tester.widget<Container>(
    find
        .descendant(
          of: find.byType(CompactSliceThumb).first,
          matching: find.byType(Container),
        )
        .first,
  );
  return (container.decoration as BoxDecoration).color!;
}

void main() {
  group('书架', () {
    testWidgets('三科封面 + 计数牌 + 开始复习，无搜索/筛选', (tester) async {
      await pumpWrongbook(tester);
      expect(find.text('错题本'), findsOneWidget);
      expect(find.text('一科一本错题本，点一本打开看这一科的错题。'), findsOneWidget);
      expect(find.text('数学'), findsOneWidget);
      expect(find.text('英语'), findsOneWidget);
      expect(find.text('政治'), findsOneWidget);
      expect(find.text('错 题 本'), findsNWidgets(3));
      expect(find.text('开始复习'), findsNWidgets(3));
      expect(find.text('已归档（1）'), findsOneWidget);
      // 书架无搜索框、无筛选按钮、无排序下拉。
      expect(find.byType(TextField), findsNothing);
      expect(find.text('筛选'), findsNothing);
      // 封面计数：数学已整理未掌握 3 道（q1/q2/q3；q7 已掌握不计入，
      // SR-P2-38 决定 (a)，与列表默认视图同口径），要复习 2，待复查 0。
      expect(find.text('3'), findsOneWidget);
      // 分页器按 HTML 常驻：单页也显示。
      expect(find.text('第 1 / 1 页 · 共 3 本（每页最多 6 本）'), findsOneWidget);
      // 页内无边距、无图标字体。
      final scroll = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView).first,
      );
      expect(scroll.padding, EdgeInsets.zero);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('封面顶部无英文：数学/英语/政治/新学科均无英文行', (tester) async {
      // 新学科化学：封面中文名 + 一道题；旧写死映射会把它写成 MATHEMATICS。
      final repo = threeSubjectRepo();
      repo.subjectsValue = [
        ...repo.subjectsValue,
        Subject(
          id: 'chemistry',
          name: '化学',
          color: const Color(0xFF7C3AED),
          icon: '化',
          coverColor: 'purple',
        ),
      ];
      repo.questions = [
        ...repo.questions,
        wbq('q9', '化学平衡', subjectId: 'chemistry'),
      ];
      await pumpWrongbook(tester, repo: repo);
      expect(find.text('数学'), findsOneWidget);
      expect(find.text('英语'), findsOneWidget);
      expect(find.text('政治'), findsOneWidget);
      expect(find.text('化学'), findsOneWidget);
      expect(find.text('错 题 本'), findsNWidgets(4));
      expect(find.text('第 1 / 1 页 · 共 4 本（每页最多 6 本）'), findsOneWidget);
      // 四科封面顶部均无英文行（含旧写死映射的三词与新学科的回退词）。
      expect(find.text('MATHEMATICS'), findsNothing);
      expect(find.text('ENGLISH'), findsNothing);
      expect(find.text('POLITICS'), findsNothing);
    });

    testWidgets('书架封面按预览画法：名下移、书页边/内阴影/折角/虚线框齐全', (tester) async {
      await pumpWrongbook(tester);
      // 顶部无英文行（Meng 2026-11-14 决定；预览里的英文是有意的不同点）。
      expect(find.text('MATHEMATICS'), findsNothing);
      expect(find.text('ENGLISH'), findsNothing);
      expect(find.text('POLITICS'), findsNothing);
      // 三本书各一套封面绘制层：纹样 + 内阴影 + 虚线内框 + 书页边 + 折角。
      // 内阴影画笔分两处用（左暗带在封面边缘、右亮带在内层），共 6 个。
      Finder byPainter(String name) => find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter?.runtimeType.toString() == name,
      );
      expect(byPainter('_CoverPatternPainter'), findsNWidgets(3));
      expect(byPainter('_CoverInsetShadowPainter'), findsNWidgets(6));
      expect(byPainter('_DashedBorderPainter'), findsNWidgets(3));
      expect(byPainter('_CoverPageEdgePainter'), findsNWidgets(3));
      expect(byPainter('_CoverFoldPainter'), findsNWidgets(3));
      // 学科名纵向位置：去掉英文行后仍按预览排布——学科名上方
      // 40.4px 占位（英文行 margin-top 26 + 12px×1.2 行高），不顶上去。
      expect(
        find.byWidgetPredicate((w) => w is SizedBox && w.height == 40.4),
        findsNWidgets(3),
      );
      // 计数条：HTML `.nb-book-counts` 深色半透明底 + 白 .35 边框 + 圆角 12。
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color ==
                  const Color.fromRGBO(0, 0, 0, 0.20) &&
              (w.decoration as BoxDecoration).borderRadius ==
                  BorderRadius.circular(12),
        ),
        findsNWidgets(3),
      );
      // 副标题与计数标签的透明度按 HTML（.95 / .92）。
      final sub = tester.widget<Text>(find.text('错 题 本').first);
      expect(sub.style?.color, const Color.fromRGBO(255, 255, 255, 0.95));
      expect(sub.style?.letterSpacing, 13.6);
      final label = tester.widget<Text>(find.text('道题').first);
      expect(label.style?.color, const Color.fromRGBO(255, 255, 255, 0.92));
    });

    testWidgets('B8-8 封面固定 300×376：窗口变窄只改每行本数，不改封面尺寸', (tester) async {
      await pumpWrongbook(tester);
      // 按学科名找各自的封面盒子（_buildBook 的 AnimatedContainer）。
      Finder bookBox(String name) => find.ancestor(
        of: find.text(name),
        matching: find.byType(AnimatedContainer),
      );
      // 1280 宽：三本一行，都是 300×376。
      for (final name in ['数学', '英语', '政治']) {
        expect(tester.getSize(bookBox(name)), const Size(300, 376));
      }
      expect(
        tester.getTopLeft(bookBox('英语')).dy,
        tester.getTopLeft(bookBox('数学')).dy,
      );
      expect(
        tester.getTopLeft(bookBox('政治')).dy,
        tester.getTopLeft(bookBox('数学')).dy,
      );
      // 窗口缩到 900：三本放不下一行（3×300 + 2×22 = 944 > 900），
      // 政治换到第二行；封面尺寸不变。
      tester.view.physicalSize = const Size(900, 720);
      await tester.pumpAndSettle();
      for (final name in ['数学', '英语', '政治']) {
        expect(tester.getSize(bookBox(name)), const Size(300, 376));
      }
      expect(
        tester.getTopLeft(bookBox('英语')).dy,
        tester.getTopLeft(bookBox('数学')).dy,
      );
      expect(
        tester.getTopLeft(bookBox('政治')).dy,
        greaterThan(tester.getTopLeft(bookBox('数学')).dy),
      );
      // image-95 回归：只剩一本也不拉满全宽，仍是 300×376。
      final oneRepo = threeSubjectRepo();
      oneRepo.subjectsValue = [Subject.math];
      await pumpWrongbook(tester, repo: oneRepo);
      expect(find.text('数学'), findsOneWidget);
      expect(find.text('英语'), findsNothing);
      expect(tester.getSize(bookBox('数学')), const Size(300, 376));
    });

    testWidgets('书脊贴着封面左边缘、通顶通底（与预览一致）', (tester) async {
      await pumpWrongbook(tester);
      // 书脊：黑 .20 + 右白 .25 竖线（与计数条区分：计数条是
      // 黑 .20 + 圆角 12 全边框）。
      final spineFinder = find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color ==
                const Color.fromRGBO(0, 0, 0, 0.20) &&
            (w.decoration as BoxDecoration).border is Border &&
            ((w.decoration as BoxDecoration).border as Border).right ==
                const BorderSide(color: Color.fromRGBO(255, 255, 255, 0.25)),
      );
      expect(spineFinder, findsNWidgets(3));
      // 每本书的书脊都贴着各自封面的左边缘、通顶通底，宽 11。
      // 根因回归：书脊原来在内容内边距里，left:0 实际落在封面
      // 左缘内 18px，且上下各短 34px/20px。
      final books = find.ancestor(
        of: spineFinder,
        matching: find.byType(AnimatedContainer),
      );
      expect(books, findsNWidgets(3));
      for (var i = 0; i < 3; i++) {
        final spine = tester.getRect(spineFinder.at(i));
        final book = tester.getRect(books.at(i));
        expect(spine.left, moreOrLessEquals(book.left, epsilon: 0.5));
        expect(spine.top, moreOrLessEquals(book.top, epsilon: 0.5));
        expect(spine.bottom, moreOrLessEquals(book.bottom, epsilon: 0.5));
        expect(spine.width, 11);
      }
      // 内阴影左暗带跟着移到封面边缘（被书脊盖住），右亮带不动：
      // 画笔分两处用，共 6 个（原来 3 个都在内层 Stack 里）。
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is CustomPaint &&
              w.painter?.runtimeType.toString() == '_CoverInsetShadowPainter',
        ),
        findsNWidgets(6),
      );
    });

    testWidgets('点封面进目录；封面内开始复习只走复习、不打开书', (tester) async {
      String? reviewSubject;
      await pumpWrongbook(
        tester,
        onGoReview: ({String? subjectId}) => reviewSubject = subjectId,
      );
      await tester.tap(find.text('开始复习').first);
      await tester.pumpAndSettle();
      expect(reviewSubject, 'math');
      // 还在书架，没有进目录。
      expect(find.text('一科一本错题本，点一本打开看这一科的错题。'), findsOneWidget);
      await tester.tap(find.text('数学'));
      await tester.pumpAndSettle();
      expect(find.text('数学 · 错题本'), findsOneWidget);
      expect(find.text('全部题目'), findsOneWidget);
    });

    testWidgets('书架顶部已归档入口：跨学科归档列表，可恢复', (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo);
      await tester.tap(find.text('已归档（1）'));
      await tester.pumpAndSettle();
      expect(find.text('已归档'), findsWidgets);
      expect(find.text('旧题'), findsOneWidget);
      expect(find.text('恢复到错题本'), findsOneWidget);
      await tester.tap(find.text('恢复到错题本'));
      await tester.pumpAndSettle();
      expect(repo.archivedChanges, contains(('q5', false)));
      expect(find.text('还没有归档的题'), findsOneWidget);
    });
  });

  group('目录页', () {
    testWidgets('文件夹树：全部题目在上、题数含子文件夹、空文件夹显示 0', (tester) async {
      await pumpWrongbook(tester, initialSubjectId: 'math');
      expect(find.text('数学 · 错题本'), findsOneWidget);
      expect(find.text('返回书架'), findsOneWidget);
      expect(find.text('全部题目'), findsOneWidget);
      expect(find.text('试卷'), findsOneWidget);
      expect(find.text('平时作业'), findsOneWidget);
      // 全部题目：已整理未掌握的数学 3 道（q1/q2/q3；q7 已掌握不计入，
      // SR-P2-38）；试卷含子文件夹的题：q1/q3 共 2 道；平时作业 1 道。
      expect(find.text('3 道题'), findsOneWidget);
      expect(find.text('2 道题'), findsOneWidget);
      expect(find.text('1 道题'), findsOneWidget); // 平时作业 q2
      // 子文件夹默认收起。
      expect(find.text('期中试卷'), findsNothing);
      // 目录页顶无长段设计说明。
      expect(find.textContaining('目录的内容就是文件夹'), findsNothing);
    });

    testWidgets('展开块点展/收；回目录后展开状态不记住', (tester) async {
      await pumpWrongbook(tester, initialSubjectId: 'math');
      await tester.tap(find.text('▸'));
      await tester.pumpAndSettle();
      expect(find.text('期中试卷'), findsOneWidget);
      expect(find.text('0 道题'), findsOneWidget);
      expect(find.text('▾'), findsOneWidget);
      await tester.tap(find.text('▾'));
      await tester.pumpAndSettle();
      expect(find.text('期中试卷'), findsNothing);
      // 展开后进列表再回目录，展开状态已重置。
      await tester.tap(find.text('▸'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('← 目录'));
      await tester.pumpAndSettle();
      expect(find.text('期中试卷'), findsNothing);
    });

    testWidgets('点文件夹行进该文件夹的题列表；点其余部分才进，展开块不进', (tester) async {
      await pumpWrongbook(tester, initialSubjectId: 'math');
      await tester.tap(find.text('平时作业'));
      await tester.pumpAndSettle();
      // 大卡片模式不显示题名：只有 1 张卡。
      expect(find.byType(QuestionSlice), findsOneWidget);
      expect(find.text('共 1 道 · 第 1 / 1 页'), findsOneWidget);
    });

    testWidgets('搜索文件夹：搜到子文件夹自动展开父级；无匹配提示', (tester) async {
      await pumpWrongbook(tester, initialSubjectId: 'math');
      await tester.enterText(find.byType(TextField).first, '期中');
      await tester.pumpAndSettle();
      expect(find.text('期中试卷'), findsOneWidget);
      expect(find.text('平时作业'), findsNothing);
      await tester.enterText(find.byType(TextField).first, '不存在');
      await tester.pumpAndSettle();
      expect(find.text('没找到这个文件夹，换个词试试'), findsOneWidget);
    });

    testWidgets('内联新建文件夹；重名拦下', (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(1), '月考卷');
      await tester.tap(find.text('加文件夹'));
      await tester.pumpAndSettle();
      expect(
        repo.savedFolders.any((f) => f.name == '月考卷' && f.parentId == null),
        isTrue,
      );
      await tester.enterText(fields.at(1), '试卷');
      await tester.tap(find.text('加文件夹'));
      await tester.pumpAndSettle();
      expect(find.text('已经有了'), findsOneWidget);
    });

    testWidgets('内联改名', (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      await tester.tap(find.text('改名').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '月考卷');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(
        repo.savedFolders.any((f) => f.id == 'f1' && f.name == '月考卷'),
        isTrue,
      );
    });

    group('B5 SR-P2-36：文件夹整科判重', () {
      testWidgets('新建：子文件夹已有的名字，在顶层新建也拦下', (tester) async {
        final repo = threeSubjectRepo();
        await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
        final fields = find.byType(TextField);
        // “期中试卷”只在子文件夹 f1s 里，顶层没有——旧的只查同层会放行。
        await tester.enterText(fields.at(1), '期中试卷');
        await tester.tap(find.text('加文件夹'));
        await tester.pumpAndSettle();
        expect(find.text('已经有了'), findsOneWidget);
        expect(repo.savedFolders.any((f) => f.name == '期中试卷'), isFalse);
      });

      testWidgets('新建：别科同名不拦', (tester) async {
        final repo = threeSubjectRepo();
        await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
        final fields = find.byType(TextField);
        // “模拟卷”只在政治科 f5 里，数学科没有——整科判重只看本科。
        await tester.enterText(fields.at(1), '模拟卷');
        await tester.tap(find.text('加文件夹'));
        await tester.pumpAndSettle();
        expect(
          repo.savedFolders.any(
            (f) => f.name == '模拟卷' && f.subjectId == 'math',
          ),
          isTrue,
        );
      });

      testWidgets('改名：改成别层级已有的名字拦下', (tester) async {
        final repo = threeSubjectRepo();
        await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
        // 第二个“改名”是顶层 f2“平时作业”的；改成子文件夹 f1s 已有的名字。
        await tester.tap(find.text('改名').at(1));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, '期中试卷');
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(find.text('已经有了'), findsOneWidget);
        expect(
          repo.savedFolders.any((f) => f.id == 'f2' && f.name == '期中试卷'),
          isFalse,
        );
      });

      testWidgets('移动：目标层是空的、但别层级已有同名时拦下', (tester) async {
        final repo = threeSubjectRepo();
        // 遗留状态：顶层 f6 与子文件夹 f1s 同名“期中试卷”。
        repo.folderList.add(
          const Folder(
            id: 'f6',
            name: '期中试卷',
            subjectId: 'math',
            sortOrder: 20,
          ),
        );
        await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
        await tester.tap(find.text('选择文件夹'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('期中试卷'));
        await tester.pumpAndSettle();
        expect(find.text('已选 1 个文件夹'), findsOneWidget);
        await tester.tap(find.byType(DropdownButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('移到「平时作业」下面').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('移动'));
        await tester.pumpAndSettle();
        // 目标“平时作业”下面是空的——旧的只查目标层会放行。
        expect(find.textContaining('同一学科下已经有同名文件夹'), findsOneWidget);
        expect(
          repo.savedFolders.where((f) => f.id == 'f6' && f.parentId == 'f2'),
          isEmpty,
        );
      });

      testWidgets('防线：saveFolder 抛 StateError 时只提示“已经有了”', (tester) async {
        final repo = threeSubjectRepo();
        repo.saveFolderError = StateError('已经有了：同一学科下已有同名文件夹“全新名”');
        await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
        final fields = find.byType(TextField);
        // 预检放行（全新名），保存时防线抛错——页内须捕获转提示、不崩页。
        await tester.enterText(fields.at(1), '全新名');
        await tester.tap(find.text('加文件夹'));
        await tester.pumpAndSettle();
        expect(find.text('已经有了'), findsOneWidget);
      });
    });

    testWidgets('删除确认文案带数：只在该文件夹的题 + 子文件夹一起删', (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      await tester.tap(find.text('删除').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('会删掉其中 4 道题（只在这个文件夹里的）'), findsOneWidget);
      expect(find.textContaining('它下面的 1 个子文件夹也会一起删掉'), findsOneWidget);
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(repo.deletedFolderIds, contains('f1'));
      expect(find.text('试卷'), findsNothing);
    });

    testWidgets('选择模式：点行勾选不进列表；移动禁则拦下带子文件夹的一级文件夹', (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      await tester.tap(find.text('选择文件夹'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 个文件夹'), findsOneWidget);
      // 选择模式下点行 = 勾选，不进列表。
      await tester.tap(find.text('试卷'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 个文件夹'), findsOneWidget);
      expect(find.text('数学 · 错题本'), findsOneWidget);
      // 目标选「平时作业」下面：带子文件夹的「试卷」不能放进去。
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移到「平时作业」下面').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('移动'));
      await tester.pumpAndSettle();
      expect(find.textContaining('只留一层'), findsOneWidget);
      expect(
        repo.savedFolders.where((f) => f.id == 'f1' && f.parentId == 'f2'),
        isEmpty,
      );
    });

    testWidgets('选择模式：点「全部题目」仍进列表（与 HTML 一致，全部题目不可选）', (tester) async {
      await pumpWrongbook(tester, initialSubjectId: 'math');
      await tester.tap(find.text('选择文件夹'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      // 全部题目不参与勾选，点它仍进列表（数学已整理 3 道进大卡片）。
      expect(find.byType(QuestionSlice), findsNWidgets(3));
    });

    testWidgets('选择模式：子文件夹可移回顶层', (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      await tester.tap(find.text('▸'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择文件夹'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('期中试卷'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 个文件夹'), findsOneWidget);
      await tester.tap(find.text('移动'));
      await tester.pumpAndSettle();
      expect(
        repo.savedFolders.any((f) => f.id == 'f1s' && f.parentId == null),
        isTrue,
      );
      expect(find.textContaining('已移动 1 个文件夹'), findsOneWidget);
    });

    testWidgets('SR2-7：A 科选了移动目标，进 B 科开移动条不断言、回落到顶层', (tester) async {
      await pumpWrongbook(tester, initialSubjectId: 'math');
      await tester.tap(find.text('选择文件夹'));
      await tester.pumpAndSettle();
      // 数学顶层目标选「平时作业」（f2，另一科没有这个 id）。
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移到「平时作业」下面').last);
      await tester.pumpAndSettle();
      expect(find.text('移到「平时作业」下面'), findsOneWidget);
      // 回书架进英语目录，再开移动条：旧值 f2 不在英语顶层选项里，
      // 未修时会抛 DropdownButton 断言。
      await tester.tap(find.text('返回书架'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('英语'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择文件夹'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 个文件夹'), findsOneWidget);
      expect(
        tester
            .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
            .value,
        '__top__',
      );
      expect(find.text('移到顶层（成为一级文件夹）'), findsOneWidget);
    });

    testWidgets('SR2-7：选定移动目标后删掉它，移动条不断言、回落到顶层', (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      await tester.tap(find.text('选择文件夹'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移到「平时作业」下面').last);
      await tester.pumpAndSettle();
      expect(find.text('移到「平时作业」下面'), findsOneWidget);
      // 直接删目标文件夹 f2（顶层行第 2 个“删除”按钮）并确认。
      await tester.tap(find.text('删除').at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(repo.deletedFolderIds, contains('f2'));
      // 移动条还开着，旧值 f2 已不在选项里，未修时会抛断言。
      expect(find.text('已选 0 个文件夹'), findsOneWidget);
      expect(
        tester
            .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
            .value,
        '__top__',
      );
      expect(find.text('移到顶层（成为一级文件夹）'), findsOneWidget);
    });
  });

  group('列表页', () {
    testWidgets('书头 + 副标题 + 目录/合上；默认隐藏已掌握', (tester) async {
      await pumpWrongbook(tester);
      await openMathListCompact(tester);
      expect(find.text('数学 · 错题本'), findsOneWidget);
      expect(
        find.text('这一科的题目列表，点一道题进题目详情；筛选里没有文件夹，文件夹在目录页选。'),
        findsOneWidget,
      );
      expect(find.text('← 目录'), findsOneWidget);
      expect(find.text('合上 ✕'), findsOneWidget);
      expect(find.text('函数极限'), findsOneWidget);
      expect(find.text('导数综合'), findsOneWidget);
      expect(find.text('定积分'), findsOneWidget);
      // q7 已掌握，默认不显示。
      expect(find.text('极限已掌握'), findsNothing);
      // 隐藏提示行。
      expect(find.textContaining('错因已全部解决 1 道默认不显示'), findsOneWidget);
      // 合上回书架。
      await tester.tap(find.text('合上 ✕'));
      await tester.pumpAndSettle();
      expect(find.text('一科一本错题本，点一本打开看这一科的错题。'), findsOneWidget);
    });

    testWidgets('大卡片：一题一行整题切片，无题名/学科/错误类型/标签/收藏星', (tester) async {
      await pumpWrongbook(tester);
      await openMathList(tester);
      expect(find.byType(QuestionSlice), findsNWidgets(3));
      expect(find.text('函数极限'), findsNothing);
      expect(find.text('数学'), findsNothing);
      expect(find.text('概念不清'), findsNothing);
      expect(find.text('易错'), findsNothing);
      expect(find.text('★'), findsNothing);
      expect(find.text('☆'), findsNothing);
      // 序号圆盘：本页 1、2、3。
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('共 3 道 · 第 1 / 1 页'), findsOneWidget);
    });

    // B8-9：内部滚动容器已删除——>2 张卡也不再套固定高度 ListView，
    // 整页只有一个 SingleChildScrollView，卡片全部建出来、随页滚动。
    testWidgets('B8-9：>2 张卡也不用固定高度内部滚动容器；≤2 张同样无 ListView', (tester) async {
      await pumpWrongbook(tester);
      await openMathList(tester);
      // 数学 3 张卡：无内部 ListView，3 张卡一次建齐。
      expect(find.byType(ListView), findsNothing);
      expect(find.byType(QuestionSlice), findsNWidgets(3));
      // 英语 2 张卡：同样无内部 ListView。
      await tester.tap(find.text('← 目录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('返回书架'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('英语'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      expect(find.byType(ListView), findsNothing);
      expect(find.byType(QuestionSlice), findsNWidgets(2));
    });

    testWidgets('序号随排序重编号：时间新→旧首题 q1，旧→新首题 q2', (tester) async {
      Question? opened;
      await pumpWrongbook(tester, onOpenDetail: (q, _) async => opened = q);
      await openMathList(tester);
      await tester.tap(find.byType(QuestionSlice).first);
      await tester.pumpAndSettle();
      expect(opened?.id, 'q1');
      // 切旧→新。
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('排序：时间 旧 → 新').last);
      await tester.pumpAndSettle();
      opened = null;
      await tester.tap(find.byType(QuestionSlice).first);
      await tester.pumpAndSettle();
      expect(opened?.id, 'q2');
    });

    // SR-P0-2：设置里旧值 wrongbookSort='subject'（或任意未知值）进列表
    // 不得触发 DropdownButton 断言；'subject' 按原意归一为 subj-asc，
    // 未知值回落到 'new'。旧值直接用 AppSettings 构造器传入（构造器
    // 不归一），走错题本 _load 的归一分支；读库 / copyWith 的归一另见
    // 模型层单测（AppSettings.fromMap / copyWith）。
    testWidgets("旧值 wrongbookSort='subject' 进列表不断言，按学科首字母排", (tester) async {
      final now = DateTime.now();
      final repo = FakeWrongbookRepo(
        questions: [
          wbq(
            'qe',
            '英语题',
            subjectId: 'english',
            errorTypes: const ['概念不清'],
            createdAt: now.subtract(const Duration(days: 1)),
          ),
          wbq(
            'qm',
            '数学题',
            subjectId: 'math',
            errorTypes: const ['概念不清'],
            createdAt: now.subtract(const Duration(days: 5)),
          ),
        ],
        folderList: const [],
        // 时间新→旧会把英语题（新）放前面；学科升序应把数学题放前面。
        settingsValue: const AppSettings(wrongbookSort: 'subject'),
      );
      Question? opened;
      await pumpWrongbook(
        tester,
        repo: repo,
        filterCause: '概念不清',
        onOpenDetail: (q, _) async => opened = q,
      );
      // 若 _sort 仍是 'subject'，DropdownButton 在 build 时即断言失败。
      expect(find.text('排序：学科首字母 A → Z'), findsOneWidget);
      await tester.tap(find.byType(QuestionSlice).first);
      await tester.pumpAndSettle();
      expect(opened?.id, 'qm');
    });

    testWidgets("未知 wrongbookSort 回落到时间新→旧，不断言", (tester) async {
      final now = DateTime.now();
      final repo = FakeWrongbookRepo(
        questions: [
          wbq(
            'qe',
            '英语题',
            subjectId: 'english',
            errorTypes: const ['概念不清'],
            createdAt: now.subtract(const Duration(days: 1)),
          ),
          wbq(
            'qm',
            '数学题',
            subjectId: 'math',
            errorTypes: const ['概念不清'],
            createdAt: now.subtract(const Duration(days: 5)),
          ),
        ],
        folderList: const [],
        settingsValue: const AppSettings(wrongbookSort: 'bogus'),
      );
      Question? opened;
      await pumpWrongbook(
        tester,
        repo: repo,
        filterCause: '概念不清',
        onOpenDetail: (q, _) async => opened = q,
      );
      expect(find.text('排序：时间 新 → 旧'), findsOneWidget);
      await tester.tap(find.byType(QuestionSlice).first);
      await tester.pumpAndSettle();
      expect(opened?.id, 'qe');
    });

    testWidgets('紧凑列表：缩略图 + 题名 + 学科·错误类型·标签 + 错因 pill + 收藏星', (tester) async {
      await pumpWrongbook(tester);
      await openMathListCompact(tester);
      expect(find.byType(CompactSliceThumb), findsNWidgets(3));
      // 明细行是 RichText（学科名着学科色），textContaining 默认不匹配
      // 独立 RichText，需 findRichText: true。
      expect(
        find.textContaining('数学 · 错误类型：概念不清 · 标签：易错', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('概念不清·待解决'), findsOneWidget);
      expect(find.text('计算错误·解决中'), findsOneWidget);
      expect(find.text('★'), findsOneWidget); // q1 已收藏
      expect(find.text('☆'), findsNWidgets(2));
      expect(find.text('下次复查 —'), findsNWidgets(3)); // 无复查日期
    });

    testWidgets('紧凑列表缩略图：亮色纸面 #FFFDF4、深色纸面 #D8DCE2，与大卡片一致', (tester) async {
      // S8A2（A2 项）：旧代码写死 Colors.white，深色下仍是纯白；
      // 改后与 QuestionSlice 同取 palette.paper。
      await pumpWrongbook(tester);
      await openMathListCompact(tester);
      expect(find.byType(CompactSliceThumb), findsNWidgets(3));
      expect(_thumbPaperColor(tester), const Color(0xFFFFFDF4));
      await pumpWrongbook(tester, brightness: Brightness.dark);
      await openMathListCompact(tester);
      expect(_thumbPaperColor(tester), const Color(0xFFD8DCE2));
    });

    testWidgets('点紧凑行收藏星切换收藏', (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo);
      await openMathListCompact(tester);
      await tester.tap(find.text('☆').last);
      await tester.pumpAndSettle();
      expect(repo.toggledFavoriteIds, contains('q2'));
    });

    testWidgets('搜索只查元数据：搜题干词无匹配，搜标签/题名有匹配', (tester) async {
      await pumpWrongbook(tester);
      await openMathListCompact(tester);
      // “单调”只在 q1/q2 的题干切片里，不在元数据里。
      await tester.enterText(find.byType(TextField).first, '单调');
      await tester.pumpAndSettle();
      expect(find.text('没找到这道题，换个词试试'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '易错');
      await tester.pumpAndSettle();
      expect(plainText('函数极限'), findsOneWidget);
      expect(find.text('导数综合'), findsNothing);
      await tester.enterText(find.byType(TextField).first, '函数极限');
      await tester.pumpAndSettle();
      expect(plainText('函数极限'), findsOneWidget);
    });

    testWidgets('筛选面板无学科/文件夹下拉；四下拉 + 标签行 + 只看行', (tester) async {
      await pumpWrongbook(tester);
      await openMathListCompact(tester);
      await tester.tap(find.text('筛选 ▾'));
      await tester.pumpAndSettle();
      expect(find.text('试卷（来源）'), findsOneWidget);
      expect(find.text('错误类型'), findsOneWidget);
      expect(find.text('收集时间'), findsOneWidget);
      expect(find.text('错因状态'), findsOneWidget);
      expect(find.text('标签'), findsOneWidget);
      expect(find.text('只看'), findsOneWidget);
      expect(find.text('仅收藏'), findsOneWidget);
      expect(find.text('仅逾期'), findsOneWidget);
      expect(find.text('已归档'), findsOneWidget);
      expect(find.text('学科'), findsNothing);
      expect(find.text('文件夹'), findsNothing);
      // HTML：筛选按钮只在有已选筛选项时才带「（已选 N）」，0 项时不带；
      // 此时面板已打开，箭头为 ▴。
      expect(find.text('筛选 ▴'), findsOneWidget);
    });

    testWidgets('筛选：错误类型“方法不会”只剩 q2；重置恢复全部', (tester) async {
      await pumpWrongbook(tester);
      await openMathListCompact(tester);
      await tester.tap(find.text('筛选 ▾'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<String>).at(2));
      await tester.pumpAndSettle();
      await tester.tap(find.text('方法不会').last);
      await tester.pumpAndSettle();
      expect(find.text('导数综合'), findsOneWidget);
      expect(find.text('函数极限'), findsNothing);
      // 按钮文案含箭头「筛选（已选 1） ▴」，用 textContaining 匹配。
      expect(find.textContaining('筛选（已选 1）'), findsOneWidget);
      await tester.tap(find.text('重置'));
      await tester.pumpAndSettle();
      expect(find.text('函数极限'), findsOneWidget);
      expect(find.text('导数综合'), findsOneWidget);
      expect(find.text('定积分'), findsOneWidget);
    });

    testWidgets('筛选：错因状态“已解决”才显示已掌握题', (tester) async {
      await pumpWrongbook(tester);
      await openMathListCompact(tester);
      await tester.tap(find.text('筛选 ▾'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<String>).at(4));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已解决').last);
      await tester.pumpAndSettle();
      expect(find.text('极限已掌握'), findsOneWidget);
      expect(find.text('函数极限'), findsNothing);
    });

    testWidgets('筛选：收集时间“最近一周”排除 10 天前的题', (tester) async {
      await pumpWrongbook(tester);
      await openMathListCompact(tester);
      await tester.tap(find.text('筛选 ▾'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<String>).at(3));
      await tester.pumpAndSettle();
      await tester.tap(find.text('最近一周').last);
      await tester.pumpAndSettle();
      expect(find.text('函数极限'), findsOneWidget);
      expect(find.text('定积分'), findsOneWidget);
      expect(find.text('导数综合'), findsNothing);
    });

    testWidgets('筛选：仅逾期只显示复查到期的题', (tester) async {
      await pumpWrongbook(tester, initialSubjectId: 'english');
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('紧凑列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('筛选 ▾'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('仅逾期'));
      await tester.pumpAndSettle();
      expect(find.text('图表作文'), findsOneWidget);
      expect(find.text('阅读主旨'), findsNothing);
    });

    testWidgets('本学科已归档视图：archbar + 恢复入口', (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('筛选 ▾'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已归档'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已归档 · 共 1 道'), findsOneWidget);
      expect(find.text('旧题'), findsOneWidget);
      // HTML 归档条按钮文案就是「← 返回题目列表」。
      expect(find.text('← 返回题目列表'), findsOneWidget);
      await tester.tap(find.text('恢复到错题本'));
      await tester.pumpAndSettle();
      expect(repo.archivedChanges, contains(('q5', false)));
    });
  });

  group('B8-9 空状态文案', () {
    testWidgets('文件夹为空：显示“这个文件夹还是空的”+收集/整理引导，不显示搜索无结果文案', (tester) async {
      final repo = FakeWrongbookRepo(
        questions: [
          wbq(
            'q1',
            '函数极限',
            folderIds: const ['f1'],
            errorTypes: const ['概念不清'],
          ),
        ],
        folderList: const [
          Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
          Folder(id: 'fEmpty', name: '空文件夹', subjectId: 'math', sortOrder: 10),
        ],
        counts: const {'math': (0, 0, 0)},
      );
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      await tester.tap(find.text('空文件夹'));
      await tester.pumpAndSettle();
      expect(find.text('数学 · 空文件夹'), findsOneWidget);
      expect(find.text('这个文件夹还是空的'), findsOneWidget);
      expect(find.textContaining('去收集中心拍一道题'), findsOneWidget);
      expect(find.textContaining('去整理工作台'), findsOneWidget);
      expect(find.text('没找到这道题，换个词试试'), findsNothing);
      expect(find.text('返回目录'), findsOneWidget);
      await tester.tap(find.text('返回目录'));
      await tester.pumpAndSettle();
      expect(find.text('数学 · 错题本'), findsOneWidget);
    });

    testWidgets('D-32：文件夹为空且双入口接通：显示“去收集 / 去整理”双按钮，点后走对应回调', (tester) async {
      var wentCollect = false;
      var wentOrganize = false;
      final repo = FakeWrongbookRepo(
        questions: [
          wbq(
            'q1',
            '函数极限',
            folderIds: const ['f1'],
            errorTypes: const ['概念不清'],
          ),
        ],
        folderList: const [
          Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
          Folder(id: 'fEmpty', name: '空文件夹', subjectId: 'math', sortOrder: 10),
        ],
        counts: const {'math': (0, 0, 0)},
      );
      await pumpWrongbook(
        tester,
        repo: repo,
        initialSubjectId: 'math',
        onGoCollect: () => wentCollect = true,
        onGoOrganize: () => wentOrganize = true,
      );
      await tester.tap(find.text('空文件夹'));
      await tester.pumpAndSettle();
      expect(find.text('这个文件夹还是空的'), findsOneWidget);
      expect(find.textContaining('去收集中心拍一道题'), findsOneWidget);
      expect(find.text('去收集'), findsOneWidget);
      expect(find.text('去整理'), findsOneWidget);
      expect(find.text('返回目录'), findsNothing);
      await tester.tap(find.text('去收集'));
      await tester.pump();
      expect(wentCollect, isTrue);
      expect(wentOrganize, isFalse);
      await tester.tap(find.text('去整理'));
      await tester.pump();
      expect(wentOrganize, isTrue);
    });

    testWidgets('搜索确实无结果：仍显示搜索无结果文案，不显示文件夹为空文案', (tester) async {
      await pumpWrongbook(tester);
      await openMathList(tester);
      await tester.enterText(find.byType(TextField).first, '不存在的词');
      await tester.pumpAndSettle();
      expect(find.text('没找到这道题，换个词试试'), findsOneWidget);
      expect(find.text('这个文件夹还是空的'), findsNothing);
      expect(find.text('清除全部筛选'), findsOneWidget);
    });

    testWidgets('范围有题但全已解决：显示“这里的题错因都已解决”，点按钮看到已解决的题', (tester) async {
      final now = DateTime.now();
      final repo = FakeWrongbookRepo(
        questions: [
          wbq(
            'q1',
            '已掌握的题',
            folderIds: const ['f1'],
            errorTypes: const ['概念不清'],
            createdAt: now.subtract(const Duration(days: 2)),
          ),
          wbq(
            'q2',
            '另一道题',
            folderIds: const ['f2'],
            errorTypes: const ['方法不会'],
            createdAt: now.subtract(const Duration(days: 3)),
          ),
        ],
        folderList: const [
          Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
          Folder(id: 'f2', name: '平时作业', subjectId: 'math', sortOrder: 10),
        ],
        records: [
          CauseRecord(
            questionId: 'q1',
            cause: '概念不清',
            subjectId: 'math',
            status: CauseStatus.solved,
            solvedCount: 2,
            joinedAt: now,
          ),
        ],
        counts: const {'math': (0, 0, 0)},
      );
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      await tester.tap(find.text('试卷'));
      await tester.pumpAndSettle();
      expect(find.text('这里的题错因都已解决'), findsOneWidget);
      expect(find.text('没找到这道题，换个词试试'), findsNothing);
      expect(find.text('看看已解决的题'), findsOneWidget);
      await tester.tap(find.text('看看已解决的题'));
      await tester.pumpAndSettle();
      expect(find.byType(QuestionSlice), findsOneWidget);
    });

    testWidgets('定稿 A 也含空状态修复：文件夹为空文案一致', (tester) async {
      final repo = FakeWrongbookRepo(
        questions: [
          wbq(
            'q1',
            '函数极限',
            folderIds: const ['f1'],
            errorTypes: const ['概念不清'],
          ),
        ],
        folderList: const [
          Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
          Folder(id: 'fEmpty', name: '空文件夹', subjectId: 'math', sortOrder: 10),
        ],
        counts: const {'math': (0, 0, 0)},
      );
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      await tester.tap(find.text('空文件夹'));
      await tester.pumpAndSettle();
      expect(find.text('这个文件夹还是空的'), findsOneWidget);
      expect(find.text('没找到这道题，换个词试试'), findsNothing);
    });

    testWidgets('定稿 A 列表能渲染：大卡片 3 张、序号圆盘、分页都在', (tester) async {
      await pumpWrongbook(tester);
      await openMathList(tester);
      expect(find.byType(QuestionSlice), findsNWidgets(3));
      expect(find.text('1'), findsOneWidget);
      expect(find.text('共 3 道 · 第 1 / 1 页'), findsOneWidget);
      expect(find.byType(ListView), findsNothing);
    });
  });

  group('详情返回刷新', () {
    testWidgets('大卡片：详情里删题，返回后卡片消失', (tester) async {
      final repo = threeSubjectRepo();
      Question? opened;
      await pumpWrongbook(
        tester,
        repo: repo,
        onOpenDetail: (q, _) async {
          opened = q;
          await repo.delete(q);
        },
      );
      await openMathList(tester);
      expect(find.byType(QuestionSlice), findsNWidgets(3));
      await tester.tap(find.byType(QuestionSlice).first);
      await tester.pumpAndSettle();
      expect(opened?.id, 'q1');
      expect(find.byType(QuestionSlice), findsNWidgets(2));
    });

    testWidgets('SR2-34：错误类型筛自定义错因，详情里删掉唯一带它的题，'
        '返回后不断言、筛选回到全部', (tester) async {
      // 只有 q9 带自定义错因“粗心大意”；固定错因一直在选项里，
      // 测不出旧值失效，必须用自定义错因。
      final repo = threeSubjectRepo();
      repo.questions.add(
        wbq(
          'q9',
          '粗心大意题',
          folderIds: const ['f1'],
          customErrorTypes: const ['粗心大意'],
          createdAt: DateTime.now().subtract(const Duration(days: 1)),
        ),
      );
      await pumpWrongbook(
        tester,
        repo: repo,
        onOpenDetail: (q, _) async => repo.delete(q),
      );
      await openMathListCompact(tester);
      await tester.tap(find.text('筛选 ▾'));
      await tester.pumpAndSettle();
      // 筛选面板第 3 个 String 下拉是错误类型（第 1 个是排序，
      // 第 2 个是试卷来源）。
      await tester.tap(find.byType(DropdownButton<String>).at(2));
      await tester.pumpAndSettle();
      await tester.tap(find.text('粗心大意').last);
      await tester.pumpAndSettle();
      expect(find.text('粗心大意题'), findsOneWidget);
      expect(find.text('函数极限'), findsNothing);
      // 进详情删掉 q9 再返回：_load 后选项里已无“粗心大意”，
      // 未修时旧值会让 DropdownButton 断言。
      await tester.tap(find.text('粗心大意题'));
      await tester.pumpAndSettle();
      expect(repo.deletedIds, contains('q9'));
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byType(DropdownButton<String>).at(2),
            )
            .value,
        isNull,
      );
      expect(find.text('函数极限'), findsOneWidget);
      expect(find.text('导数综合'), findsOneWidget);
    });

    testWidgets('紧凑列表：详情里改收藏，返回后星标出现', (tester) async {
      final repo = threeSubjectRepo();
      Question? opened;
      await pumpWrongbook(
        tester,
        repo: repo,
        onOpenDetail: (q, _) async {
          opened = q;
          await repo.toggleFavorite(q);
        },
      );
      await openMathListCompact(tester);
      expect(find.text('★'), findsOneWidget); // 只有 q1 已收藏
      await tester.tap(find.text('导数综合'));
      await tester.pumpAndSettle();
      expect(opened?.id, 'q2');
      // 注意：_load 会把视图重置为设置里的默认视图（大卡片），这是
      // _load 的既有行为（行内点星 _toggleFavorite 同样走 _load），
      // 与本次修的“返回刷新”无关；切回紧凑列表再断言星标。
      await tester.tap(find.text('紧凑列表'));
      await tester.pumpAndSettle();
      expect(find.text('★'), findsNWidgets(2));
      expect(find.text('☆'), findsOneWidget);
    });

    testWidgets('已归档行：详情里恢复归档，返回后该行消失', (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(
        tester,
        repo: repo,
        initialSubjectId: 'math',
        onOpenDetail: (q, _) async => repo.archive(q, archived: false),
      );
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('筛选 ▾'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已归档'));
      await tester.pumpAndSettle();
      expect(find.text('旧题'), findsOneWidget);
      await tester.tap(find.text('旧题'));
      await tester.pumpAndSettle();
      expect(find.text('旧题'), findsNothing);
    });
  });

  group('批量模式', () {
    testWidgets('进入批量：批量条出现；全选 + 已选 N；退出清空', (tester) async {
      await pumpWrongbook(tester);
      await openMathList(tester);
      expect(find.text('批量操作'), findsOneWidget);
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      expect(find.text('全选当前结果'), findsOneWidget);
      expect(find.text('已选 0 道'), findsOneWidget);
      expect(find.text('批量收藏'), findsOneWidget);
      expect(find.text('批量归档'), findsOneWidget);
      expect(find.text('批量删除'), findsOneWidget);
      expect(find.text('退出批量'), findsOneWidget);
      await tester.tap(find.text('全选当前结果'));
      await tester.pumpAndSettle();
      expect(find.text('已选 3 道'), findsOneWidget);
      await tester.tap(find.text('退出批量'));
      await tester.pumpAndSettle();
      expect(find.text('全选当前结果'), findsNothing);
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 道'), findsOneWidget);
    });

    testWidgets('单选卡片复选框；批量删除模态弹窗确认', (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo);
      await openMathList(tester);
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      // 第 0 个复选框是批量条的全选，第 1 个是首张卡。
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 道'), findsOneWidget);
      await tester.tap(find.text('批量删除'));
      await tester.pumpAndSettle();
      expect(find.text('删了就没了，确定吗？'), findsOneWidget);
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(repo.deletedIds, contains('q1'));
      expect(find.text('批量操作'), findsOneWidget);
    });

    testWidgets('批量加入文件夹', (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo);
      await openMathList(tester);
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      // 批量文件夹下拉是第 2 个 String 下拉（第 1 个是排序）。
      await tester.tap(find.byType(DropdownButton<String>).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('平时作业').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量加入文件夹'));
      await tester.pumpAndSettle();
      final q1 = repo.questions.firstWhere((q) => q.id == 'q1');
      expect(q1.folderIds, contains('f2'));
    });
  });

  group('分页', () {
    testWidgets('12 道题：每页 10，第一页序号 1–10，第二页重编号为 1、2', (tester) async {
      final repo = manyQuestionRepo();
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      expect(find.text('共 12 道 · 第 1 / 2 页'), findsOneWidget);
      // B8-9：卡片不再懒加载（Column 全量建出），'9' 不用滚到底就有；
      // 序号按页重编号，第一页是 1–10；用 '9' 校验（'10' 会同时命中
      // 每页下拉的显示值）。
      expect(find.text('9'), findsOneWidget);
      await tester.ensureVisible(find.text('下一页'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一页'));
      await tester.pumpAndSettle();
      expect(find.text('共 12 道 · 第 2 / 2 页'), findsOneWidget);
      expect(find.byType(QuestionSlice), findsNWidgets(2));
      // 序号重编号：页码钮与序号圆盘各一份 '1'/'2'。
      expect(find.text('1'), findsNWidgets(2));
      expect(find.text('2'), findsNWidgets(2));
      expect(find.text('12'), findsNothing);
    });

    testWidgets('每页数量可改 10/20/30/40/50', (tester) async {
      final repo = manyQuestionRepo();
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      // B8-9：12 张大卡片随页排布，分页器在首屏外；先滚出来再点下拉。
      await tester.ensureVisible(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('20').last);
      await tester.pumpAndSettle();
      expect(find.text('共 12 道 · 第 1 / 1 页'), findsOneWidget);
      // 12 道同在一页：第 12 张卡在页底部，用 dragUntilVisible
      // 逐步滚到底（一次大 drag 在 12 张卡时不一定触底）。
      // B8-9：内部 ListView 已删，滚页面的 SingleChildScrollView。
      await tester.dragUntilVisible(
        find.text('12'),
        find.byType(SingleChildScrollView),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      expect(find.text('12'), findsOneWidget);
    });

    testWidgets('S8A6 大库 54 道：五档页数与末页题数', (tester) async {
      // 与真机大库同口径：数学已整理 54 道；标题按时间倒序排，
      // 分页题 53 最新、分页题 0 最旧。
      // 用紧凑列表跑矩阵：大卡片不渲染题名文字（只有序号圆盘），
      // 紧凑行是 Column 全量构建、题名是普通 Text，可直接断言；
      // 大卡片五档已由真机截图覆盖（见 S8A6 报告）。
      final now = DateTime.now();
      final repo = FakeWrongbookRepo(
        questions: [
          for (var i = 0; i < 54; i++)
            wbq(
              'p$i',
              '分页题 $i',
              folderIds: const ['f1'],
              errorTypes: const ['概念不清'],
              createdAt: now.subtract(Duration(hours: 54 - i)),
            ),
        ],
        folderList: const [
          Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
        ],
        counts: const {'math': (0, 0, 0)},
      );
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('紧凑列表'));
      await tester.pumpAndSettle();
      // 每档：每页数 → 总页数 / 末页首题 / 上一页首题（不在末页）。
      const cases = [
        (10, 6, '分页题 3', '分页题 4'),
        (20, 3, '分页题 13', '分页题 14'),
        (30, 2, '分页题 23', '分页题 24'),
        (40, 2, '分页题 13', '分页题 14'),
        (50, 2, '分页题 3', '分页题 4'),
      ];
      for (final (size, pages, first, before) in cases) {
        // 切档：按 value 选菜单项（不用 find.text，序号圆盘里也有 '10'）。
        // 菜单打开时 value==size 的 DropdownMenuItem 有两个：按钮上显示
        // 的当前值（40×34）与菜单里的项（62×48），后者在树里居后，
        // 取 .last 才是菜单项。先 ensureVisible 下拉按钮：分页器在长列
        // 表底部，不先滚出来 tap 会落空、菜单打不开，后续点到的就是
        // 菜单遮罩而不是分页按钮。
        await tester.ensureVisible(find.byType(DropdownButton<int>));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(DropdownButton<int>));
        await tester.pumpAndSettle();
        final item = find
            .byWidgetPredicate(
              (w) => w is DropdownMenuItem<int> && w.value == size,
            )
            .last;
        await tester.ensureVisible(item);
        await tester.pumpAndSettle();
        await tester.tap(item);
        await tester.pumpAndSettle();
        expect(find.text('共 54 道 · 第 1 / $pages 页'), findsOneWidget);
        // 翻到末页：点 (pages - 1) 次下一页。
        for (var p = 1; p < pages; p++) {
          await tester.ensureVisible(find.text('下一页'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('下一页'));
          await tester.pumpAndSettle();
        }
        expect(find.text('共 54 道 · 第 $pages / $pages 页'), findsOneWidget);
        // 末页首题与最末题都在；上一页首题不在本页。
        expect(find.text(first), findsOneWidget);
        expect(find.text('分页题 0'), findsOneWidget);
        expect(find.text(before), findsNothing);
      }
    });
  });

  group('B5 SR-P1-12：排序与每页条数跨 _load() 保留', () {
    testWidgets('排序改成旧→新后进详情返回，仍是旧→新', (tester) async {
      await pumpWrongbook(tester);
      await openMathList(tester);
      expect(find.text('排序：时间 新 → 旧'), findsOneWidget);
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('排序：时间 旧 → 新').last);
      await tester.pumpAndSettle();
      expect(find.text('排序：时间 旧 → 新'), findsOneWidget);
      // 进详情再返回：行 onTap 里 onOpenDetail 之后会 await _load()，
      // 旧代码会在此把 _sort 弹回设置默认值（新→旧）。
      await tester.tap(find.byType(QuestionSlice).first);
      await tester.pumpAndSettle();
      expect(find.text('排序：时间 旧 → 新'), findsOneWidget);
    });

    testWidgets('每页改成 20 后进详情返回，仍是每页 20', (tester) async {
      final repo = manyQuestionRepo();
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      expect(find.text('共 12 道 · 第 1 / 2 页'), findsOneWidget);
      // B8-9：12 张大卡片随页排布，分页器在首屏外；先滚出来再点下拉。
      await tester.ensureVisible(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('20').last);
      await tester.pumpAndSettle();
      expect(find.text('共 12 道 · 第 1 / 1 页'), findsOneWidget);
      // 进详情再返回：_load() 旧代码会把 _pageSize 弹回设置默认值 10。
      await tester.tap(find.byType(QuestionSlice).first);
      await tester.pumpAndSettle();
      expect(find.text('共 12 道 · 第 1 / 1 页'), findsOneWidget);
    });
  });

  group('错误态占位', () {
    testWidgets('QuestionSlice(failed: true) 显示学科图标 + 学科 · 题型占位', (
      tester,
    ) async {
      // 应用内暂无真实图片通道，失败占位无应用级触发入口（与 R5
      // imageFailed 开关同款情况）；此处在组件级验证占位形态。
      final q = wbq('q1', '函数极限');
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(scale: 1.0),
          home: Scaffold(body: QuestionSlice(question: q, failed: true)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('数'), findsOneWidget); // 数学科图标
      expect(find.text('数学 · 极限题'), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
    });
  });

  group('亮/深 × 三档缩放', () {
    testWidgets('书架亮/深 × 1.00/1.15/1.30 无溢出', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        for (final scale in [1.0, 1.15, 1.3]) {
          await pumpWrongbook(tester, brightness: brightness, scale: scale);
          expect(find.text('错题本'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets('列表页亮/深 × 1.00/1.15/1.30 无溢出', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        for (final scale in [1.0, 1.15, 1.3]) {
          await pumpWrongbook(
            tester,
            brightness: brightness,
            scale: scale,
            initialSubjectId: 'math',
          );
          await tester.tap(find.text('全部题目'));
          await tester.pumpAndSettle();
          expect(find.byType(QuestionSlice), findsNWidgets(3));
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets('目录页亮/深 × 1.00/1.15/1.30 无溢出', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        for (final scale in [1.0, 1.15, 1.3]) {
          await pumpWrongbook(
            tester,
            brightness: brightness,
            scale: scale,
            initialSubjectId: 'math',
          );
          await tester.tap(find.text('▸'));
          await tester.pumpAndSettle();
          expect(find.text('期中试卷'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      }
    });
  });

  group('B5-P2 错题本', () {
    /// SR-P2-37：五科各一题同一错因；化学最旧（10 天前），
    /// 按时间新→旧排它会垫底，按学科首字母排它应排第一。
    FakeWrongbookRepo fiveSubjectRepo({String sort = 'subj-asc'}) {
      final now = DateTime.now();
      return FakeWrongbookRepo(
        questions: [
          wbq(
            'q-chem',
            '化学题',
            subjectId: 'chemistry',
            errorTypes: const ['概念不清'],
            createdAt: now.subtract(const Duration(days: 10)),
          ),
          wbq(
            'q-math',
            '数学题',
            errorTypes: const ['概念不清'],
            createdAt: now.subtract(const Duration(days: 2)),
          ),
          wbq(
            'q-phys',
            '物理题',
            subjectId: 'physics',
            errorTypes: const ['概念不清'],
            createdAt: now.subtract(const Duration(days: 1)),
          ),
          wbq(
            'q-eng',
            '英语题',
            subjectId: 'english',
            errorTypes: const ['概念不清'],
            createdAt: now.subtract(const Duration(days: 3)),
          ),
          wbq(
            'q-pol',
            '政治题',
            subjectId: 'politics',
            errorTypes: const ['概念不清'],
            createdAt: now.subtract(const Duration(days: 4)),
          ),
        ],
        folderList: const [],
        subjects: [
          Subject.math,
          Subject.english,
          Subject.politics,
          Subject(
            id: 'chemistry',
            name: '化学',
            color: const Color(0xFF7C4DDB),
            icon: '化',
          ),
          Subject(
            id: 'physics',
            name: '物理',
            color: const Color(0xFFED7D31),
            icon: '物',
          ),
        ],
        settingsValue: AppSettings(wrongbookSort: sort),
      );
    }

    /// SR-P2-42：把 [name] 文件夹拖到第 [gapIndex] 个缝隙上。
    /// 拖拽手柄是行右侧的 Draggable（小拖动图标），不是文件夹名——
    /// 从名字处起拖不会启动拖拽。
    Future<void> dragFolder(
      WidgetTester tester,
      String name,
      int gapIndex,
    ) async {
      final from = tester.getCenter(
        find.byWidgetPredicate(
          (w) => w is Draggable<Folder> && w.data?.name == name,
        ),
      );
      final to = tester.getCenter(find.byType(DragTarget<Folder>).at(gapIndex));
      final gesture = await tester.startGesture(from);
      await gesture.moveBy((to - from) / 2);
      await gesture.moveBy((to - from) / 2);
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('SR-P2-37 学科首字母升序：化学（H）在前，时间不干扰', (tester) async {
      final repo = fiveSubjectRepo(sort: 'subj-asc');
      Question? opened;
      await pumpWrongbook(
        tester,
        repo: repo,
        filterCause: '概念不清',
        onOpenDetail: (q, _) async => opened = q,
      );
      await tester.tap(find.byType(QuestionSlice).first);
      await tester.pumpAndSettle();
      expect(opened?.id, 'q-chem');
    });

    testWidgets('SR-P2-37 学科首字母降序：政治（Z）在前', (tester) async {
      final repo = fiveSubjectRepo(sort: 'subj-desc');
      Question? opened;
      await pumpWrongbook(
        tester,
        repo: repo,
        filterCause: '概念不清',
        onOpenDetail: (q, _) async => opened = q,
      );
      await tester.tap(find.byType(QuestionSlice).first);
      await tester.pumpAndSettle();
      expect(opened?.id, 'q-pol');
    });

    testWidgets('SR2-74 同首字母平局：生物（SHENG）在数学（SHU）前面', (tester) async {
      // 数学更新（1 天前）、生物更旧（10 天前）：时间与码点都偏向数学，
      // 只有拼音序能把生物排前面（旧代码按码点比全名：数 U+6570 < 生 U+751F）。
      final now = DateTime.now();
      final repo = FakeWrongbookRepo(
        questions: [
          wbq(
            'q-math',
            '数学题',
            errorTypes: const ['概念不清'],
            createdAt: now.subtract(const Duration(days: 1)),
          ),
          wbq(
            'q-bio',
            '生物题',
            subjectId: 'biology',
            errorTypes: const ['概念不清'],
            createdAt: now.subtract(const Duration(days: 10)),
          ),
        ],
        folderList: const [],
        subjects: [
          Subject.math,
          Subject(
            id: 'biology',
            name: '生物',
            color: Color(0xFF84CC16),
            icon: '生',
          ),
        ],
        settingsValue: const AppSettings(wrongbookSort: 'subj-asc'),
      );
      Question? opened;
      await pumpWrongbook(
        tester,
        repo: repo,
        filterCause: '概念不清',
        onOpenDetail: (q, _) async => opened = q,
      );
      await tester.tap(find.byType(QuestionSlice).first);
      await tester.pumpAndSettle();
      expect(opened?.id, 'q-bio');
    });

    testWidgets('SR2-74 未映射汉字：排在已映射字母之后', (tester) async {
      // “量子力学”首字“量”不在拼音首字母表里，回退为原字比较——
      // 汉字码点恒大于拉丁字母，排在数学（S）之后（注释写明不是拼音序）。
      final now = DateTime.now();
      final repo = FakeWrongbookRepo(
        questions: [
          wbq(
            'q-quantum',
            '量子题',
            subjectId: 'quantum',
            errorTypes: const ['概念不清'],
            createdAt: now.subtract(const Duration(days: 1)),
          ),
          wbq(
            'q-math',
            '数学题',
            errorTypes: const ['概念不清'],
            createdAt: now.subtract(const Duration(days: 2)),
          ),
        ],
        folderList: const [],
        subjects: [
          Subject.math,
          Subject(
            id: 'quantum',
            name: '量子力学',
            color: Color(0xFF7C4DDB),
            icon: '量',
          ),
        ],
        settingsValue: const AppSettings(wrongbookSort: 'subj-asc'),
      );
      Question? opened;
      await pumpWrongbook(
        tester,
        repo: repo,
        filterCause: '概念不清',
        onOpenDetail: (q, _) async => opened = q,
      );
      await tester.tap(find.byType(QuestionSlice).first);
      await tester.pumpAndSettle();
      expect(opened?.id, 'q-math');
    });

    testWidgets('SR2-74 空名学科：排最后，不置顶', (tester) async {
      // 空名回退到 '{'（排在 Z 之后）；旧代码回退 '' 会把它排最前面。
      final now = DateTime.now();
      final repo = FakeWrongbookRepo(
        questions: [
          wbq(
            'q-empty',
            '无名学科题',
            subjectId: 'empty',
            errorTypes: const ['概念不清'],
            createdAt: now.subtract(const Duration(days: 1)),
          ),
          wbq(
            'q-math',
            '数学题',
            errorTypes: const ['概念不清'],
            createdAt: now.subtract(const Duration(days: 2)),
          ),
        ],
        folderList: const [],
        subjects: [
          Subject.math,
          Subject(id: 'empty', name: '', color: Color(0xFF64748F), icon: ''),
        ],
        settingsValue: const AppSettings(wrongbookSort: 'subj-asc'),
      );
      Question? opened;
      await pumpWrongbook(
        tester,
        repo: repo,
        filterCause: '概念不清',
        onOpenDetail: (q, _) async => opened = q,
      );
      await tester.tap(find.byType(QuestionSlice).first);
      await tester.pumpAndSettle();
      expect(opened?.id, 'q-math');
    });

    testWidgets('SR-P2-38/53 文件夹列表标题带文件夹名；已掌握提示按当前文件夹计', (tester) async {
      await pumpWrongbook(tester, initialSubjectId: 'math');
      await tester.tap(find.text('试卷'));
      await tester.pumpAndSettle();
      expect(find.text('数学 · 试卷'), findsOneWidget);
      expect(find.textContaining('这个文件夹里错因已全部解决 1 道默认不显示'), findsOneWidget);
    });

    testWidgets('SR-P2-38 没有已掌握题的文件夹不显示提示', (tester) async {
      await pumpWrongbook(tester, initialSubjectId: 'math');
      await tester.tap(find.text('平时作业'));
      await tester.pumpAndSettle();
      expect(find.textContaining('错因已全部解决'), findsNothing);
    });

    testWidgets('SR-P2-40 批量加标签：含逗号的新标签拦下，不入库不保存', (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo);
      await openMathList(tester);
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量加标签'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '新标,签');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('不能含逗号或竖线'), findsOneWidget);
      expect(repo.tagList, isNot(contains('新标,签')));
      expect(repo.saved, isEmpty);
    });

    testWidgets('SR2-53 批量加标签：含竖线的新标签拦下，不入库不保存', (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo);
      await openMathList(tester);
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量加标签'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '新标|签');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('不能含逗号或竖线'), findsOneWidget);
      expect(repo.tagList, isNot(contains('新标|签')));
      expect(repo.saved, isEmpty);
    });

    testWidgets('SR-P2-41 批量收藏：已删的题报“不在列表里”，其余照常收藏', (tester) async {
      final repo = threeSubjectRepo();
      Question? opened;
      await pumpWrongbook(
        tester,
        repo: repo,
        onOpenDetail: (q, _) async {
          opened = q;
          await repo.delete(q);
        },
      );
      await openMathList(tester);
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选当前结果'));
      await tester.pumpAndSettle();
      expect(find.text('已选 3 道'), findsOneWidget);
      await tester.tap(find.byType(QuestionSlice).first);
      await tester.pumpAndSettle();
      expect(opened?.id, 'q1');
      await tester.tap(find.text('批量收藏'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已收藏 2 道'), findsOneWidget);
      expect(find.textContaining('1 道已不在列表里，跳过'), findsOneWidget);
    });

    testWidgets('SR-P2-41 跨学科列表批量模式提示不能批量移文件夹', (tester) async {
      await pumpWrongbook(tester, filterCause: '概念不清');
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      expect(find.text('跨学科列表不能批量移文件夹：先打开一本书，再批量移'), findsOneWidget);
    });

    testWidgets('SR-P2-42 拖拽调顺序：往下拖一格不动；拖到末尾换位', (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      Folder lastSave(String id) =>
          repo.savedFolders.lastWhere((f) => f.id == id);
      // 拖“试卷”到它与“平时作业”之间的缝隙（gap1）：删前下标 1，
      // 删后减 1 回 0，顺序不变。
      await dragFolder(tester, '试卷', 3);
      expect(lastSave('f1').sortOrder, 0);
      expect(lastSave('f2').sortOrder, 10);
      // 拖“试卷”到末尾缝隙（gap2）：[平时作业，试卷]。
      await dragFolder(tester, '试卷', 5);
      expect(lastSave('f2').sortOrder, 0);
      expect(lastSave('f1').sortOrder, 10);
    });

    testWidgets('SR2-28 搜索文件夹时缝隙拖拽拒收，顺序不变', (tester) async {
      // 数学顶层加第三个文件夹“模拟卷”：搜“卷”只剩 试卷 / 模拟卷可见
      //（平时作业被滤掉）。把“模拟卷”拖到 试卷 与 模拟卷 之间的缝隙，
      // 按所见应不动；旧代码按全量下标解释会把它插到平时作业前面。
      final repo = threeSubjectRepo();
      repo.folderList.add(
        const Folder(id: 'f6', name: '模拟卷', subjectId: 'math', sortOrder: 20),
      );
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      await tester.enterText(find.byType(TextField).first, '卷');
      await tester.pumpAndSettle();
      expect(find.text('平时作业'), findsNothing);
      expect(find.text('模拟卷'), findsOneWidget);
      // 可见缝隙下标：全部题目(0) / 顶层 gap0(1) / 试卷行(2) /
      // 子缝隙(3) / 子行“期中试卷”(4) / 子缝隙(5) / 顶层 gap1(6) /
      // 模拟卷行(7) / 顶层 gap2(8)——拖到 6。
      await dragFolder(tester, '模拟卷', 6);
      expect(repo.savedFolders, isEmpty);
    });

    testWidgets('SR3-18 搜索文件夹时显示“不能调顺序”提示，清空后消失', (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      expect(find.text('搜索时不能调顺序，先清空搜索'), findsNothing);
      await tester.enterText(find.byType(TextField).first, '卷');
      await tester.pumpAndSettle();
      expect(find.text('搜索时不能调顺序，先清空搜索'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pumpAndSettle();
      expect(find.text('搜索时不能调顺序，先清空搜索'), findsNothing);
    });

    testWidgets('SR-P2-44 换科/换文件夹时搜索与筛选清零', (tester) async {
      await pumpWrongbook(tester);
      await openMathListCompact(tester);
      await tester.enterText(find.byType(TextField).first, '函数极限');
      await tester.pumpAndSettle();
      expect(plainText('函数极限'), findsOneWidget);
      expect(find.text('导数综合'), findsNothing);
      // SR2-52：换科前再设一个筛选（错误类型“计算错误”），换科后它也
      // 要回到默认值“全部”，不只搜索清零。筛选与搜索无交集时列表为空。
      await tester.tap(find.text('筛选 ▾'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<String>).at(2));
      await tester.pumpAndSettle();
      await tester.tap(find.text('计算错误').last);
      await tester.pumpAndSettle();
      // 用 plainText：find.text 也会命中搜索框自身的 EditableText，
      // 而搜索框里本来就留着“函数极限”。
      expect(plainText('函数极限'), findsNothing);
      expect(plainText('定积分'), findsNothing);
      await tester.tap(find.text('← 目录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('返回书架'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('英语'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      expect(find.text('阅读主旨'), findsOneWidget);
      expect(find.text('图表作文'), findsOneWidget);
      // 错误类型下拉回到“全部”（value 为 null），筛选面板仍开着可直接读值。
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byType(DropdownButton<String>).at(2),
            )
            .value,
        isNull,
      );
    });

    testWidgets('SR-P2-45 “最近一周”是 7 天含今天：6 天前在内，7 天前在外', (tester) async {
      final now = DateTime.now();
      final repo = FakeWrongbookRepo(
        questions: [
          wbq(
            'w6',
            '六天前',
            folderIds: const ['f1'],
            errorTypes: const ['概念不清'],
            createdAt: now.subtract(const Duration(days: 6)),
          ),
          wbq(
            'w7',
            '七天前',
            folderIds: const ['f1'],
            errorTypes: const ['概念不清'],
            createdAt: now.subtract(const Duration(days: 7)),
          ),
        ],
        folderList: const [
          Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
        ],
      );
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('紧凑列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('筛选 ▾'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<String>).at(3));
      await tester.pumpAndSettle();
      await tester.tap(find.text('最近一周').last);
      await tester.pumpAndSettle();
      expect(find.text('六天前'), findsOneWidget);
      expect(find.text('七天前'), findsNothing);
    });

    testWidgets('SR2-76 月筛选 “最近 30 天”：29 天前在内，30 天前在外', (tester) async {
      // 与 SR-P2-45 周筛选同款边界：30 天含今天是 age < 30，
      // 不是 age <= 30（那是 31 天）。
      final now = DateTime.now();
      final repo = FakeWrongbookRepo(
        questions: [
          wbq(
            'm29',
            '二十九天前',
            folderIds: const ['f1'],
            errorTypes: const ['概念不清'],
            createdAt: now.subtract(const Duration(days: 29)),
          ),
          wbq(
            'm30',
            '三十天前',
            folderIds: const ['f1'],
            errorTypes: const ['概念不清'],
            createdAt: now.subtract(const Duration(days: 30)),
          ),
        ],
        folderList: const [
          Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
        ],
      );
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('紧凑列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('筛选 ▾'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<String>).at(3));
      await tester.pumpAndSettle();
      await tester.tap(find.text('最近 30 天').last);
      await tester.pumpAndSettle();
      expect(find.text('二十九天前'), findsOneWidget);
      expect(find.text('三十天前'), findsNothing);
    });

    testWidgets('SR-P2-45 日期搜索：补零与不补零两种写法都搜到', (tester) async {
      final repo = FakeWrongbookRepo(
        questions: [
          wbq(
            'wd',
            '指定日期题',
            folderIds: const ['f1'],
            errorTypes: const ['概念不清'],
            createdAt: DateTime(2026, 11, 5, 10),
          ),
          wbq(
            'w6',
            '六天前',
            folderIds: const ['f1'],
            errorTypes: const ['概念不清'],
            createdAt: DateTime.now().subtract(const Duration(days: 6)),
          ),
        ],
        folderList: const [
          Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
        ],
      );
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('紧凑列表'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '2026-11-05');
      await tester.pumpAndSettle();
      expect(find.text('指定日期题'), findsOneWidget);
      expect(find.text('六天前'), findsNothing);
      await tester.enterText(find.byType(TextField).first, '2026-11-5');
      await tester.pumpAndSettle();
      expect(find.text('指定日期题'), findsOneWidget);
      expect(find.text('六天前'), findsNothing);
    });

    testWidgets('SR-P2-46 书架顶部跨学科已归档视图分页：12 道两页', (tester) async {
      final now = DateTime.now();
      final repo = FakeWrongbookRepo(
        questions: [
          for (var i = 0; i < 12; i++)
            wbq(
              'a$i',
              '归档题 $i',
              folderIds: const ['f1'],
              errorTypes: const ['概念不清'],
              isArchived: true,
              createdAt: now.subtract(Duration(days: i + 1)),
            ),
        ],
        folderList: const [
          Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
        ],
      );
      await pumpWrongbook(tester, repo: repo);
      expect(find.text('已归档（12）'), findsOneWidget);
      await tester.tap(find.text('已归档（12）'));
      await tester.pumpAndSettle();
      expect(find.text('共 12 道 · 第 1 / 2 页'), findsOneWidget);
      expect(find.text('恢复到错题本'), findsNWidgets(10));
      await tester.ensureVisible(find.text('下一页'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一页'));
      await tester.pumpAndSettle();
      expect(find.text('共 12 道 · 第 2 / 2 页'), findsOneWidget);
      expect(find.text('恢复到错题本'), findsNWidgets(2));
    });

    testWidgets('SR2-76 归档后页码越界回落：第 2 页归档完只剩 1 页时回到第 1 页', (tester) async {
      // 12 道、每页 10 条：第 2 页只有 m10、m11 两道；紧凑列表里把这
      // 两道勾上批量归档，列表只剩 10 道、1 页，_page 仍是旧值 1，
      // 渲染按 clamp 回落到第 1 页（不是空白页）。
      final repo = manyQuestionRepo();
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('紧凑列表'));
      await tester.pumpAndSettle();
      expect(find.text('共 12 道 · 第 1 / 2 页'), findsOneWidget);
      await tester.ensureVisible(find.text('下一页'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一页'));
      await tester.pumpAndSettle();
      expect(find.text('共 12 道 · 第 2 / 2 页'), findsOneWidget);
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      // 第 0 个 Checkbox 是批量条的全选框，第 1、2 个是第 2 页的两道题。
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).at(2));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 道'), findsOneWidget);
      await tester.tap(find.text('批量归档'));
      await tester.pumpAndSettle();
      expect(find.text('共 10 道 · 第 1 / 1 页'), findsOneWidget);
      expect(repo.archivedChanges.length, 2);
    });

    testWidgets('SR2-76 每页条数切换后页码复位到第 1 页', (tester) async {
      final repo = manyQuestionRepo();
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      expect(find.text('共 12 道 · 第 1 / 2 页'), findsOneWidget);
      await tester.ensureVisible(find.text('下一页'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一页'));
      await tester.pumpAndSettle();
      expect(find.text('共 12 道 · 第 2 / 2 页'), findsOneWidget);
      // 每页 10 → 20 条：只有 1 页了，页码回到第 1 页。
      await tester.tap(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('20').last);
      await tester.pumpAndSettle();
      expect(find.text('共 12 道 · 第 1 / 1 页'), findsOneWidget);
    });

    testWidgets('SR-P2-48 读库失败出错误横幅；重试失败仍在，成功后恢复', (tester) async {
      final repo = threeSubjectRepo();
      repo.throwOnLoad = true;
      await pumpWrongbook(tester, repo: repo);
      expect(find.textContaining('错题本数据读取失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.textContaining('错题本数据读取失败'), findsOneWidget);
      repo.throwOnLoad = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('数学'), findsOneWidget);
    });

    testWidgets('SR-P2-52 封面“错 题 本”字距跟全局字号缩放', (tester) async {
      await pumpWrongbook(tester, scale: 1.3);
      final w = tester.getSize(find.text('错 题 本').first).width;
      expect(w, greaterThan(185));
    });

    // B8-9：蓝色大框已整体去掉——跨学科列表不再有任何学科色外框
    //（SR-P2-54 原先防的“回退数学蓝”已无从发生）；数学列表同样无框。
    testWidgets('B8-9：题目列表无任何学科色外框（SR-P2-54 原书框已删）', (tester) async {
      final coverFrame = find.byWidgetPredicate((w) {
        if (w is! Container || w.decoration is! BoxDecoration) {
          return false;
        }
        final color = (w.decoration as BoxDecoration).color;
        // 中性灰 0xFF64748F；数学封面蓝 0xFF2F7CF6（与序号圆盘的
        // accent 0xFF2E7CF6 不是同一个值，不会误判）。
        return color == const Color(0xFF64748F) ||
            color == const Color(0xFF2F7CF6);
      });
      await pumpWrongbook(tester, filterCause: '概念不清');
      expect(coverFrame, findsNothing);
      await pumpWrongbook(tester);
      await openMathList(tester);
      expect(coverFrame, findsNothing);
    });

    testWidgets('SR-P2-58 “重置”后排序固定回时间新→旧，不回设置默认值', (tester) async {
      final repo = threeSubjectRepo();
      repo.settingsValue = const AppSettings(wrongbookSort: 'old');
      await pumpWrongbook(tester, repo: repo);
      await openMathList(tester);
      expect(find.text('排序：时间 旧 → 新'), findsOneWidget);
      await tester.tap(find.text('重置'));
      await tester.pumpAndSettle();
      expect(find.text('排序：时间 新 → 旧'), findsOneWidget);
    });
  });

  group('D-50 报告深链路', () {
    testWidgets('学科 + 错因直达已筛选列表，不经过目录页', (tester) async {
      // 大卡片默认视图不画题目标题，只画题干切片文字：用 sliceText 区分。
      final repo = FakeWrongbookRepo(
        questions: [
          wbq('m1', '数学概念不清题', sliceText: '题：求极限', errorTypes: const ['概念不清']),
          wbq('m2', '数学计算错误题', sliceText: '题：求导数', errorTypes: const ['计算错误']),
          wbq(
            'e1',
            '英语概念不清题',
            subjectId: 'english',
            sliceText: '题：英语词汇',
            errorTypes: const ['概念不清'],
          ),
        ],
        folderList: const [
          Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
        ],
      );
      await pumpWrongbook(
        tester,
        repo: repo,
        initialSubjectId: 'math',
        filterCause: '概念不清',
      );
      // 直接落在列表页：页头是“← 目录”，不是目录页的“全部题目”行。
      expect(find.text('← 目录'), findsOneWidget);
      expect(find.text('全部题目'), findsNothing);
      expect(find.text('题：求极限'), findsOneWidget);
      expect(find.text('题：求导数'), findsNothing);
      expect(find.text('题：英语词汇'), findsNothing);
    });

    testWidgets('学科 + 知识点直达已筛选列表', (tester) async {
      final repo = FakeWrongbookRepo(
        questions: [
          wbq(
            'm1',
            '数学极限题',
            sliceText: '题：求极限',
          ).copyWith(knowledgePointIds: const ['kp-math-limit']),
          wbq(
            'm2',
            '数学导数题',
            sliceText: '题：求导数',
            errorTypes: const ['计算错误'],
          ).copyWith(knowledgePointIds: const ['kp-math-derivative']),
        ],
        folderList: const [
          Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
        ],
        kpList: const [
          KnowledgePoint(
            id: 'kp-math-limit',
            subjectId: 'math',
            chapter: '第一章',
            name: '函数极限',
          ),
          KnowledgePoint(
            id: 'kp-math-derivative',
            subjectId: 'math',
            chapter: '第二章',
            name: '导数应用',
          ),
        ],
      );
      await pumpWrongbook(
        tester,
        repo: repo,
        initialSubjectId: 'math',
        filterKnowledgePointId: 'kp-math-limit',
      );
      expect(find.text('← 目录'), findsOneWidget);
      expect(find.text('题：求极限'), findsOneWidget);
      expect(find.text('题：求导数'), findsNothing);
    });

    testWidgets('深链路列表返回目录，再进列表筛选已清', (tester) async {
      final repo = FakeWrongbookRepo(
        questions: [
          wbq('m1', '数学概念不清题', sliceText: '题：求极限', errorTypes: const ['概念不清']),
          wbq('m2', '数学计算错误题', sliceText: '题：求导数', errorTypes: const ['计算错误']),
        ],
        folderList: const [
          Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
        ],
      );
      await pumpWrongbook(
        tester,
        repo: repo,
        initialSubjectId: 'math',
        filterCause: '概念不清',
      );
      expect(find.text('题：求极限'), findsOneWidget);
      expect(find.text('题：求导数'), findsNothing);
      // 返回路径：列表页头“← 目录”回数学目录（D-50 定：不回报告，
      // 应用无路由栈，目录是书内一致的返回落点；报告在左导航一跳可达）。
      await tester.tap(find.text('← 目录'));
      await tester.pumpAndSettle();
      expect(find.text('全部题目'), findsOneWidget);
      expect(find.text('题：求极限'), findsNothing);
      // 从目录再进列表：SR-P2-44 清筛选，深链路是一次性入口，不残留。
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      expect(find.text('题：求极限'), findsOneWidget);
      expect(find.text('题：求导数'), findsOneWidget);
    });
  });
}
