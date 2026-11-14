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
  List<String> tags = const [],
  DateTime? createdAt,
  bool isOrganized = true,
  bool isArchived = false,
  bool isFavorite = false,
}) =>
    Question(
      id: id,
      title: title,
      subjectId: subjectId,
      folderIds: folderIds,
      examId: examId,
      errorTypes: errorTypes,
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
  })  : questions = List.of(questions),
        folderList = List.of(folderList),
        examList = List.of(examList),
        kpList = List.of(kpList),
        tagList = List.of(tagList),
        records = List.of(records),
        subjectsValue = subjects ??
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

  final List<Question> saved = [];
  final List<String> deletedIds = [];
  final List<Folder> savedFolders = [];
  final List<String> deletedFolderIds = [];
  final List<String> toggledFavoriteIds = [];
  final List<(String, bool)> archivedChanges = [];

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<Folder>> folders({String? subjectId}) async =>
      subjectId == null
          ? List.of(folderList)
          : folderList.where((f) => f.subjectId == subjectId).toList();

  @override
  Future<List<Exam>> exams() async => List.of(examList);

  @override
  Future<List<String>> tags() async => List.of(tagList);

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => List.of(kpList);

  @override
  Future<Map<String, (int, int, int)>> subjectCounts({bool includeArchived = false}) async => counts;

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  @override
  Future<AppSettings> settings() async => const AppSettings();

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
    questions.removeWhere((q) =>
        q.folderIds.isNotEmpty &&
        q.folderIds.every((id) => ids.contains(id)));
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
      wbq('q1', '函数极限',
          folderIds: const ['f1'],
          examId: 'e1',
          errorTypes: const ['概念不清'],
          tags: const ['易错'],
          sliceText: '题：lim(x→0) sin 3x / x 单调递增',
          createdAt: now.subtract(const Duration(days: 2)),
          isFavorite: true),
      wbq('q2', '导数综合',
          sliceKind: 'function',
          sliceText: '题：设 f(x) = x³ − 3x² + 2，求单调区间',
          folderIds: const ['f2'],
          errorTypes: const ['方法不会'],
          tags: const ['常考'],
          createdAt: now.subtract(const Duration(days: 10))),
      wbq('q3', '定积分',
          sliceKind: 'chart',
          sliceText: '题：求阴影面积',
          folderIds: const ['f1'],
          errorTypes: const ['计算错误'],
          tags: const ['需重做'],
          createdAt: now.subtract(const Duration(days: 5))),
      wbq('q4', '阅读主旨',
          subjectId: 'english',
          sliceKind: 'material',
          sliceText: '题：The evidence ______ the hypothesis.',
          folderIds: const ['f3'],
          errorTypes: const ['审题失误'],
          createdAt: now.subtract(const Duration(days: 3))),
      wbq('q8', '图表作文',
          subjectId: 'english',
          sliceKind: 'chart',
          sliceText: '题：Describe the chart.',
          folderIds: const ['f3'],
          errorTypes: const ['方法不会'],
          tags: const ['需重做'],
          createdAt: now.subtract(const Duration(days: 4))),
      wbq('q7', '极限已掌握',
          sliceText: '题：已掌握的极限题',
          folderIds: const ['f1'],
          errorTypes: const ['概念不清'],
          createdAt: now.subtract(const Duration(days: 6))),
      wbq('q5', '旧题',
          sliceText: '题：已归档的旧题',
          folderIds: const ['f1'],
          errorTypes: const ['审题失误'],
          createdAt: now.subtract(const Duration(days: 20)),
          isArchived: true),
      wbq('q6', '未整理题',
          sliceText: '题：还没整理的题',
          // 未整理但导入时已挂文件夹：目录计数必须不算它（与列表口径一致），
          // 否则“平时作业”行会写 1 道题、点进去却是空列表。
          folderIds: const ['f2'],
          errorTypes: const ['概念不清'],
          createdAt: now.subtract(const Duration(days: 1)),
          isOrganized: false),
    ],
    folderList: const [
      Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
      Folder(id: 'f1s', name: '期中试卷', subjectId: 'math', parentId: 'f1', sortOrder: 0),
      Folder(id: 'f2', name: '平时作业', subjectId: 'math', sortOrder: 10),
      Folder(id: 'f3', name: '试卷', subjectId: 'english', sortOrder: 0),
      Folder(id: 'f4', name: '平时作业', subjectId: 'english', sortOrder: 10),
      Folder(id: 'f5', name: '模拟卷', subjectId: 'politics', sortOrder: 0),
    ],
    examList: [
      Exam(id: 'e1', name: '高等数学期末试卷', date: DateTime(2026, 11, 10)),
    ],
    kpList: const [
      KnowledgePoint(
          id: 'k1', subjectId: 'math', chapter: '第一章 函数与极限', name: '函数极限'),
      KnowledgePoint(
          id: 'k2', subjectId: 'math', chapter: '第一章 函数与极限', name: '导数概念'),
    ],
    tagList: const ['易错', '常考', '需重做'],
    records: [
      CauseRecord(
          questionId: 'q1',
          cause: '概念不清',
          subjectId: 'math',
          status: CauseStatus.pending,
          joinedAt: DateTime.now()),
      CauseRecord(
          questionId: 'q2',
          cause: '方法不会',
          subjectId: 'math',
          status: CauseStatus.pending,
          joinedAt: DateTime.now()),
      CauseRecord(
          questionId: 'q3',
          cause: '计算错误',
          subjectId: 'math',
          status: CauseStatus.inProgress,
          solvedCount: 1,
          joinedAt: DateTime.now()),
      CauseRecord(
          questionId: 'q4',
          cause: '审题失误',
          subjectId: 'english',
          status: CauseStatus.pending,
          joinedAt: DateTime.now()),
      CauseRecord(
          questionId: 'q8',
          cause: '方法不会',
          subjectId: 'english',
          status: CauseStatus.solved,
          solvedCount: 2,
          recheckDate: DateTime.now().subtract(const Duration(days: 1)),
          joinedAt: DateTime.now()),
      CauseRecord(
          questionId: 'q7',
          cause: '概念不清',
          subjectId: 'math',
          status: CauseStatus.solved,
          solvedCount: 2,
          recheckDate: DateTime.now().add(const Duration(days: 7)),
          joinedAt: DateTime.now()),
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
        wbq('m$i', '数学题 $i',
            folderIds: const ['f1'],
            errorTypes: const ['概念不清'],
            createdAt: now.subtract(Duration(days: i + 1))),
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
  Brightness brightness = Brightness.light,
  double scale = 1.0,
  Key? pageKey,
  Future<void> Function(Question q, List<String> orderIds)? onOpenDetail,
  void Function({String? subjectId})? onGoReview,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: scale),
      darkTheme: AppTheme.dark(scale: scale),
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
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
                onOpenHome: () {},
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
  final container = tester.widget<Container>(find
      .descendant(
          of: find.byType(CompactSliceThumb).first,
          matching: find.byType(Container))
      .first);
  return (container.decoration as BoxDecoration).color!;
}

void main() {
  group('书架', () {
    testWidgets('三科封面 + 计数牌 + 开始复习，无搜索/筛选',
        (tester) async {
      await pumpWrongbook(tester);
      expect(find.text('错题本'), findsOneWidget);
      expect(find.text('一科一本错题本，点一本打开看这一科的错题。'),
          findsOneWidget);
      expect(find.text('数学'), findsOneWidget);
      expect(find.text('英语'), findsOneWidget);
      expect(find.text('政治'), findsOneWidget);
      expect(find.text('错 题 本'), findsNWidgets(3));
      expect(find.text('开始复习'), findsNWidgets(3));
      expect(find.text('已归档（1）'), findsOneWidget);
      // 书架无搜索框、无筛选按钮、无排序下拉。
      expect(find.byType(TextField), findsNothing);
      expect(find.text('筛选'), findsNothing);
      // 封面计数：数学已整理 4 道（q1/q2/q3/q7），要复习 2，待复查 0。
      expect(find.text('4'), findsOneWidget);
      // 分页器按 HTML 常驻：单页也显示。
      expect(find.text('第 1 / 1 页 · 共 3 本（每页最多 6 本）'),
          findsOneWidget);
      // 页内无边距、无图标字体。
      final scroll = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView).first,
      );
      expect(scroll.padding, EdgeInsets.zero);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('封面顶部无英文：数学/英语/政治/新学科均无英文行',
        (tester) async {
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
      expect(find.text('第 1 / 1 页 · 共 4 本（每页最多 6 本）'),
          findsOneWidget);
      // 四科封面顶部均无英文行（含旧写死映射的三词与新学科的回退词）。
      expect(find.text('MATHEMATICS'), findsNothing);
      expect(find.text('ENGLISH'), findsNothing);
      expect(find.text('POLITICS'), findsNothing);
    });

    testWidgets('点封面进目录；封面内开始复习只走复习、不打开书',
        (tester) async {
      String? reviewSubject;
      await pumpWrongbook(tester,
          onGoReview: ({String? subjectId}) => reviewSubject = subjectId);
      await tester.tap(find.text('开始复习').first);
      await tester.pumpAndSettle();
      expect(reviewSubject, 'math');
      // 还在书架，没有进目录。
      expect(find.text('一科一本错题本，点一本打开看这一科的错题。'),
          findsOneWidget);
      await tester.tap(find.text('数学'));
      await tester.pumpAndSettle();
      expect(find.text('数学 · 错题本'), findsOneWidget);
      expect(find.text('全部题目'), findsOneWidget);
    });

    testWidgets('书架顶部已归档入口：跨学科归档列表，可恢复',
        (tester) async {
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
    testWidgets('文件夹树：全部题目在上、题数含子文件夹、空文件夹显示 0',
        (tester) async {
      await pumpWrongbook(tester, initialSubjectId: 'math');
      expect(find.text('数学 · 错题本'), findsOneWidget);
      expect(find.text('返回书架'), findsOneWidget);
      expect(find.text('全部题目'), findsOneWidget);
      expect(find.text('试卷'), findsOneWidget);
      expect(find.text('平时作业'), findsOneWidget);
      // 全部题目：已整理的数学 4 道（q1/q2/q3/q7）；试卷含子文件夹的题：
      // q1/q3/q7 共 3 道；平时作业 1 道。
      expect(find.text('4 道题'), findsOneWidget);
      expect(find.text('3 道题'), findsOneWidget);
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

    testWidgets('点文件夹行进该文件夹的题列表；点其余部分才进，展开块不进',
        (tester) async {
      await pumpWrongbook(tester, initialSubjectId: 'math');
      await tester.tap(find.text('平时作业'));
      await tester.pumpAndSettle();
      // 大卡片模式不显示题名：只有 1 张卡。
      expect(find.byType(QuestionSlice), findsOneWidget);
      expect(find.text('共 1 道 · 第 1 / 1 页'), findsOneWidget);
    });

    testWidgets('搜索文件夹：搜到子文件夹自动展开父级；无匹配提示',
        (tester) async {
      await pumpWrongbook(tester, initialSubjectId: 'math');
      await tester.enterText(
          find.byType(TextField).first, '期中');
      await tester.pumpAndSettle();
      expect(find.text('期中试卷'), findsOneWidget);
      expect(find.text('平时作业'), findsNothing);
      await tester.enterText(
          find.byType(TextField).first, '不存在');
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
          repo.savedFolders.any(
              (f) => f.name == '月考卷' && f.parentId == null),
          isTrue);
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
          repo.savedFolders.any((f) =>
              f.id == 'f1' && f.name == '月考卷'),
          isTrue);
    });

    testWidgets('删除确认文案带数：只在该文件夹的题 + 子文件夹一起删',
        (tester) async {
      final repo = threeSubjectRepo();
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      await tester.tap(find.text('删除').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('会删掉其中 4 道题（只在这个文件夹里的）'),
          findsOneWidget);
      expect(find.textContaining('它下面的 1 个子文件夹也会一起删掉'),
          findsOneWidget);
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(repo.deletedFolderIds, contains('f1'));
      expect(find.text('试卷'), findsNothing);
    });

    testWidgets('选择模式：点行勾选不进列表；移动禁则拦下带子文件夹的一级文件夹',
        (tester) async {
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
          repo.savedFolders
              .where((f) => f.id == 'f1' && f.parentId == 'f2'),
          isEmpty);
    });

    testWidgets('选择模式：点「全部题目」仍进列表（与 HTML 一致，全部题目不可选）',
        (tester) async {
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
          repo.savedFolders.any(
              (f) => f.id == 'f1s' && f.parentId == null),
          isTrue);
      expect(find.textContaining('已移动 1 个文件夹'), findsOneWidget);
    });
  });

  group('列表页', () {
    testWidgets('书头 + 副标题 + 目录/合上；默认隐藏已掌握', (tester) async {
      await pumpWrongbook(tester);
      await openMathListCompact(tester);
      expect(find.text('数学 · 错题本'), findsOneWidget);
      expect(find.text('这一科的题目列表，点一道题进题目详情；筛选里没有文件夹，文件夹在目录页选。'),
          findsOneWidget);
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
      expect(find.text('一科一本错题本，点一本打开看这一科的错题。'),
          findsOneWidget);
    });

    testWidgets('大卡片：一题一行整题切片，无题名/学科/错误类型/标签/收藏星',
        (tester) async {
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

    testWidgets('>2 张卡变固定高度内部滚动容器；≤2 张为普通列表',
        (tester) async {
      await pumpWrongbook(tester);
      await openMathList(tester);
      // 数学 3 张卡：内部 ListView。
      expect(find.byType(ListView), findsOneWidget);
      // 英语 2 张卡：普通列表，无内部 ListView。
      await tester.tap(find.text('← 目录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('返回书架'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('英语'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      expect(find.byType(ListView), findsNothing);
    });

    testWidgets('序号随排序重编号：时间新→旧首题 q1，旧→新首题 q2',
        (tester) async {
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

    testWidgets('紧凑列表：缩略图 + 题名 + 学科·错误类型·标签 + 错因 pill + 收藏星',
        (tester) async {
      await pumpWrongbook(tester);
      await openMathListCompact(tester);
      expect(find.byType(CompactSliceThumb), findsNWidgets(3));
      // 明细行是 RichText（学科名着学科色），textContaining 默认不匹配
      // 独立 RichText，需 findRichText: true。
      expect(
          find.textContaining('数学 · 错误类型：概念不清 · 标签：易错',
              findRichText: true),
          findsOneWidget);
      expect(find.text('概念不清·待解决'), findsOneWidget);
      expect(find.text('计算错误·解决中'), findsOneWidget);
      expect(find.text('★'), findsOneWidget); // q1 已收藏
      expect(find.text('☆'), findsNWidgets(2));
      expect(find.text('下次复查 —'), findsNWidgets(3)); // 无复查日期
    });

    testWidgets('紧凑列表缩略图：亮色纸面 #FFFDF4、深色纸面 #D8DCE2，与大卡片一致',
        (tester) async {
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

    testWidgets('搜索只查元数据：搜题干词无匹配，搜标签/题名有匹配',
        (tester) async {
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

    testWidgets('筛选面板无学科/文件夹下拉；四下拉 + 标签行 + 只看行',
        (tester) async {
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

    testWidgets('筛选：错误类型“方法不会”只剩 q2；重置恢复全部',
        (tester) async {
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

  group('详情返回刷新', () {
    testWidgets('大卡片：详情里删题，返回后卡片消失', (tester) async {
      final repo = threeSubjectRepo();
      Question? opened;
      await pumpWrongbook(tester,
          repo: repo,
          onOpenDetail: (q, _) async {
            opened = q;
            await repo.delete(q);
          });
      await openMathList(tester);
      expect(find.byType(QuestionSlice), findsNWidgets(3));
      await tester.tap(find.byType(QuestionSlice).first);
      await tester.pumpAndSettle();
      expect(opened?.id, 'q1');
      expect(find.byType(QuestionSlice), findsNWidgets(2));
    });

    testWidgets('紧凑列表：详情里改收藏，返回后星标出现', (tester) async {
      final repo = threeSubjectRepo();
      Question? opened;
      await pumpWrongbook(tester,
          repo: repo,
          onOpenDetail: (q, _) async {
            opened = q;
            await repo.toggleFavorite(q);
          });
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
      await pumpWrongbook(tester,
          repo: repo,
          initialSubjectId: 'math',
          onOpenDetail: (q, _) async => repo.archive(q, archived: false));
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
    testWidgets('进入批量：批量条出现；全选 + 已选 N；退出清空',
        (tester) async {
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

    testWidgets('单选卡片复选框；批量删除内联两步确认', (tester) async {
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
    testWidgets('12 道题：每页 10，第一页序号 1–10，第二页重编号为 1、2',
        (tester) async {
      final repo = manyQuestionRepo();
      await pumpWrongbook(tester, repo: repo, initialSubjectId: 'math');
      await tester.tap(find.text('全部题目'));
      await tester.pumpAndSettle();
      expect(find.text('共 12 道 · 第 1 / 2 页'), findsOneWidget);
      // 内部 ListView 懒加载：滚到底才建出最后一张卡。序号按页重编号，
      // 第一页是 1–10；用 '9' 校验（'10' 会同时命中每页下拉的显示值）。
      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pumpAndSettle();
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
      await tester.tap(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('20').last);
      await tester.pumpAndSettle();
      expect(find.text('共 12 道 · 第 1 / 1 页'), findsOneWidget);
      // 12 道同在一页：第 12 张卡在内部滚动容器底部，用 dragUntilVisible
      // 逐步滚到底（一次大 drag 在 12 张卡时不一定触底）。
      await tester.dragUntilVisible(
        find.text('12'),
        find.byType(ListView),
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
            wbq('p$i', '分页题 $i',
                folderIds: const ['f1'],
                errorTypes: const ['概念不清'],
                createdAt: now.subtract(Duration(hours: 54 - i))),
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
                (w) => w is DropdownMenuItem<int> && w.value == size)
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

  group('错误态占位', () {
    testWidgets('QuestionSlice(failed: true) 显示学科图标 + 学科 · 题型占位',
        (tester) async {
      // 应用内暂无真实图片通道，失败占位无应用级触发入口（与 R5
      // imageFailed 开关同款情况）；此处在组件级验证占位形态。
      final q = wbq('q1', '函数极限');
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(scale: 1.0),
          home: Scaffold(
            body: QuestionSlice(question: q, failed: true),
          ),
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
          await pumpWrongbook(tester,
              brightness: brightness, scale: scale);
          expect(find.text('错题本'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets('列表页亮/深 × 1.00/1.15/1.30 无溢出', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        for (final scale in [1.0, 1.15, 1.3]) {
          await pumpWrongbook(tester,
              brightness: brightness,
              scale: scale,
              initialSubjectId: 'math');
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
          await pumpWrongbook(tester,
              brightness: brightness,
              scale: scale,
              initialSubjectId: 'math');
          await tester.tap(find.text('▸'));
          await tester.pumpAndSettle();
          expect(find.text('期中试卷'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      }
    });
  });
}
