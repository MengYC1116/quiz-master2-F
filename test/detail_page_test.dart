// R7 题目详情 widget 测试：方案 2 分段折叠式（默认全折叠）、
// 看答案、待补充进编辑、编辑保存/取消内联确认、收藏/归档/删除
//（内联确认，删后进下一题）、上一题/下一题顺序、加入/取消加入复习、
// 未整理题无加入按钮、无「开始复习」、图加载失败占位、亮/深 × 三档无溢出、
// 不用图标字体。用 FakeRepo 覆盖 repository 调用（不碰真实数据库）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/detail/question_detail_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';

Question dtq(
  String id,
  String title, {
  String subjectId = 'math',
  String sliceKind = 'limit',
  String sliceText = '题：求极限',
  List<String> folderIds = const [],
  String? examId,
  List<String> knowledgePointIds = const [],
  List<String> errorTypes = const [],
  List<String> tags = const [],
  String? answer,
  String? explanation,
  String? notes,
  DateTime? createdAt,
  bool isOrganized = true,
  bool isArchived = false,
  bool isFavorite = false,
  bool reviewJoined = false,
}) =>
    Question(
      id: id,
      title: title,
      subjectId: subjectId,
      folderIds: folderIds,
      examId: examId,
      knowledgePointIds: knowledgePointIds,
      errorTypes: errorTypes,
      tags: tags,
      answer: answer,
      explanation: explanation,
      notes: notes,
      createdAt: createdAt ?? DateTime.now().subtract(const Duration(days: 2)),
      isOrganized: isOrganized,
      isArchived: isArchived,
      isFavorite: isFavorite,
      reviewJoined: reviewJoined,
      sliceKind: sliceKind,
      sliceText: sliceText,
    );

class FakeDetailRepo extends QuestionRepository {
  FakeDetailRepo({
    required List<Question> questions,
    List<Folder> folderList = const [],
    List<Exam> examList = const [],
    List<KnowledgePoint> kpList = const [],
    List<String> tagList = const [],
    List<CauseRecord> records = const [],
    List<({String result, DateTime reviewedAt})> history = const [],
  })  : questions = List.of(questions),
        folderList = List.of(folderList),
        examList = List.of(examList),
        kpList = List.of(kpList),
        tagList = List.of(tagList),
        records = List.of(records),
        history = List.of(history),
        super(AppDatabase.instance);

  List<Question> questions;
  List<Folder> folderList;
  List<Exam> examList;
  List<KnowledgePoint> kpList;
  List<String> tagList;
  List<CauseRecord> records;
  List<({String result, DateTime reviewedAt})> history;

  final List<Question> saved = [];
  final List<String> deletedIds = [];

  @override
  Future<Question?> questionById(String id) async =>
      questions.where((q) => q.id == id).firstOrNull;

  @override
  Future<List<CauseRecord>> causeRecordsFor(String questionId) async =>
      records.where((r) => r.questionId == questionId).toList();

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
          String questionId) async =>
      List.of(history);

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
  Future<void> syncCauseRecords(Question q) async {}

  @override
  Future<void> toggleFavorite(Question q) async {
    await save(q.copyWith(isFavorite: !q.isFavorite));
  }

  @override
  Future<void> archive(Question q, {bool archived = true}) async {
    await save(q.copyWith(isArchived: archived));
  }

  @override
  Future<void> delete(Question question) async {
    deletedIds.add(question.id);
    questions.removeWhere((x) => x.id == question.id);
  }

  @override
  Future<bool> setReviewJoined(Question q, bool joined) async {
    if (joined && q.allCauses.isEmpty) return false;
    await save(q.copyWith(reviewJoined: joined));
    return true;
  }

  @override
  Future<void> addTag(String name) async {
    if (!tagList.contains(name)) tagList.add(name);
  }

  @override
  Future<void> saveFolder(Folder folder) async {
    final i = folderList.indexWhere((x) => x.id == folder.id);
    if (i >= 0) {
      folderList[i] = folder;
    } else {
      folderList.add(folder);
    }
  }

  @override
  Future<void> addKnowledgePoint(KnowledgePoint kp) async {
    kpList.add(kp);
  }

  @override
  Future<void> addExam(Exam e) async {
    examList.add(e);
  }
}

FakeDetailRepo detailRepo() {
  final now = DateTime.now();
  return FakeDetailRepo(
    questions: [
      dtq('q1', '函数极限',
          folderIds: const ['f1'],
          examId: 'e1',
          knowledgePointIds: const ['k1'],
          errorTypes: const ['概念不清'],
          tags: const ['易错', '常考'],
          answer: '1',
          explanation: 'lim(x→0) sin3x/x = 3。',
          createdAt: now.subtract(const Duration(days: 2)),
          isFavorite: true,
          reviewJoined: true),
      dtq('q2', '导数应用综合',
          sliceKind: 'function',
          sliceText: '题：设 f(x) = x³ − 3x² + 2。',
          folderIds: const ['f2'],
          examId: 'e1',
          knowledgePointIds: const ['k2'],
          errorTypes: const ['方法不会'],
          tags: const ['易错'],
          createdAt: now.subtract(const Duration(days: 5))),
      dtq('q3', '定积分阴影面积',
          sliceKind: 'chart',
          sliceText: '题：求阴影面积',
          folderIds: const ['f1'],
          errorTypes: const ['计算错误'],
          tags: const ['需重做'],
          answer: '见解析',
          explanation: '阴影面积 = ∫(1 − x²)dx。',
          createdAt: now.subtract(const Duration(days: 3)),
          isOrganized: false),
      dtq('q5', '无错因题',
          sliceText: '题：还没有填错误类型',
          folderIds: const ['f1'],
          createdAt: now.subtract(const Duration(days: 1))),
    ],
    folderList: const [
      Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
      Folder(id: 'f2', name: '平时作业', subjectId: 'math', sortOrder: 10),
    ],
    examList: [
      Exam(id: 'e1', name: '高等数学期末试卷', date: DateTime(2026, 11, 10)),
    ],
    kpList: const [
      KnowledgePoint(
          id: 'k1', subjectId: 'math', chapter: '第一章 函数与极限', name: '函数极限'),
      KnowledgePoint(
          id: 'k2', subjectId: 'math', chapter: '第二章 导数', name: '导数概念'),
    ],
    tagList: const ['易错', '常考', '需重做'],
    records: [
      CauseRecord(
          questionId: 'q1',
          cause: '概念不清',
          subjectId: 'math',
          status: CauseStatus.inProgress,
          solvedCount: 1,
          joinedAt: now.subtract(const Duration(days: 2))),
    ],
    history: [
      (result: 'solved', reviewedAt: now.subtract(const Duration(days: 1))),
      (result: 'unsolved', reviewedAt: now.subtract(const Duration(days: 2))),
    ],
  );
}

Future<void> pumpDetail(
  WidgetTester tester, {
  FakeDetailRepo? repo,
  String questionId = 'q1',
  List<String> orderIds = const ['q1', 'q2', 'q3'],
  String sourceLabel = '错题本',
  bool imageFailed = false,
  Brightness brightness = Brightness.light,
  double scale = 1.0,
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
              body: QuestionDetailPage(
                // 每次 pump 用新 Key：同一 testWidgets 内循环 pump 时，
                // 旧 State 会被复用（折叠态 / 编辑态残留），须强制重建
                //（R6 pumpWrongbook 的 pageKey ?? UniqueKey() 同款做法）。
                key: UniqueKey(),
                repo: repo ?? detailRepo(),
                questionId: questionId,
                orderIds: orderIds,
                sourceLabel: sourceLabel,
                imageFailed: imageFailed,
                onChanged: () {},
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> openSection(WidgetTester tester, String title) async {
  await tapText(tester, title);
}
/// 点按前先滚到可见（详情页整页滚动，折叠头 / 底部操作行常在 720 高视口外，
/// 直接 tap 会落空——见 R6 截图坐标教训同款问题）。
Future<void> tapText(WidgetTester tester, String text,
    {bool first = false}) async {
  final finder = first ? find.text(text).first : find.text(text);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}


void main() {
  group('结构与默认态', () {
    testWidgets('三段默认全折叠，标题 + 工具栏 + 无开始复习', (tester) async {
      await pumpDetail(tester);
      expect(find.text('数学 · 极限题｜函数极限'), findsOneWidget);
      expect(find.text('★'), findsOneWidget); // 已收藏
      expect(find.text('返回错题本'), findsNWidgets(2)); // 工具栏 + 底部
      expect(find.text('第 1 / 3 题 · 按错题本当前的顺序'), findsOneWidget);
      expect(find.text('答案解析'), findsOneWidget);
      expect(find.text('题目信息'), findsOneWidget);
      expect(find.text('复习记录'), findsOneWidget);
      expect(find.text('看答案'), findsNothing);
      expect(find.text('加入复习'), findsNothing);
      expect(find.text('开始复习'), findsNothing);
      expect(find.text('编辑'), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('来源标签来自调用页：复习', (tester) async {
      await pumpDetail(tester, sourceLabel: '复习');
      expect(find.text('返回复习'), findsNWidgets(2));
      expect(find.text('第 1 / 3 题 · 按复习当前的顺序'), findsOneWidget);
    });

    testWidgets('副标题含学科只读说明与错因汇总 pill', (tester) async {
      await pumpDetail(tester);
      expect(find.text('概念不清'), findsOneWidget); // 仅副标题可见，复习记录折叠
      expect(find.text('解决中'), findsOneWidget); // 副标题里的错因状态 pill
      expect(
          find.text('（只显示，不能改——导入时选定，详情和整理台都不能改）'),
          findsOneWidget);
    });
  });

  group('答案解析', () {
    testWidgets('展开后看答案，点开显示答案与解析，可收起', (tester) async {
      await pumpDetail(tester);
      await openSection(tester, '答案解析');
      expect(find.text('看答案'), findsOneWidget);
      expect(find.text('答案和解析默认藏起来，先自己想，再点开看'), findsOneWidget);
      await tapText(tester, '看答案');
      expect(find.text('1'), findsOneWidget);
      expect(find.text('lim(x→0) sin3x/x = 3。'), findsOneWidget);
      expect(find.text('收起答案'), findsOneWidget);
      await tapText(tester, '收起答案');
      expect(find.text('看答案'), findsOneWidget);
    });

    testWidgets('空答案显示待补充，点它进编辑模式', (tester) async {
      await pumpDetail(tester, questionId: 'q2');
      await openSection(tester, '答案解析');
      await tapText(tester, '看答案');
      expect(find.text('待补充 · 点这里补'), findsNWidgets(2)); // 答案 + 解析
      await tapText(tester, '待补充 · 点这里补', first: true);
      expect(find.text('保存'), findsNWidgets(2)); // 工具栏 + 底部
      expect(find.textContaining('正在编辑这道题'), findsOneWidget);
    });

    testWidgets('编辑态答案解析段只留提示，不直接改答案', (tester) async {
      await pumpDetail(tester);
      await tapText(tester, '编辑');
      expect(
          find.text('正在编辑：答案和解析在下方「题目信息」的编辑表单里改，改完点「保存」才生效。'),
          findsOneWidget);
      expect(find.text('看答案'), findsNothing);
    });
  });

  group('题目信息', () {
    testWidgets('查看态七行字段 + 来源行', (tester) async {
      await pumpDetail(tester);
      await openSection(tester, '题目信息');
      expect(find.text('学科（不能改）'), findsOneWidget);
      expect(find.text('文件夹（归类）'), findsOneWidget);
      expect(find.text('知识点'), findsOneWidget);
      expect(find.text('错误类型'), findsOneWidget);
      expect(find.text('标签'), findsOneWidget);
      expect(find.text('备注（笔记）'), findsOneWidget);
      expect(find.text('来源'), findsOneWidget);
      expect(find.text('来自试卷：高等数学期末试卷'), findsOneWidget);
      expect(find.text('#易错 #常考'), findsOneWidget);
      expect(find.text('数学 › 函数极限'), findsOneWidget);
      expect(find.text('概念不清'), findsNWidgets(2)); // 副标题 + 错误类型行
    });

    testWidgets('空字段显示待补充', (tester) async {
      await pumpDetail(tester, questionId: 'q2');
      await openSection(tester, '题目信息');
      // q2 有文件夹/知识点/错误类型/标签，无备注 → 只有备注是待补充
      expect(find.text('待补充 · 点这里补'), findsOneWidget);
    });
  });

  group('复习记录', () {
    testWidgets('已加入题：取消加入 + 错因状态 + 解决次数 + 全部记录', (tester) async {
      await pumpDetail(tester);
      await openSection(tester, '复习记录');
      expect(find.text('取消加入复习'), findsOneWidget);
      expect(find.text('已加入复习 · 还有 1 个错因未解决'), findsOneWidget);
      expect(find.text('取消加入不会删解决记录，再加入时接着上次解决，不用从头来'),
          findsOneWidget);
      expect(find.text('错因状态'), findsOneWidget);
      expect(find.text('概念不清'), findsNWidgets(2)); // 副标题 + 复习记录行
      expect(find.text('解决中'), findsNWidgets(2)); // 副标题 pill + 复习记录 pill
      expect(find.text('解决次数 1'), findsOneWidget);
      expect(
          find.textContaining('共解决错因 2 次 · 自查「已解决」1 次'),
          findsOneWidget);
      expect(find.text('解决记录（全部）'), findsOneWidget);
      expect(find.textContaining('已解决'), findsWidgets);
      expect(find.textContaining('未解决'), findsWidgets);
    });

    testWidgets('未加入题：加入复习，点后变取消加入复习', (tester) async {
      final repo = detailRepo();
      await pumpDetail(tester, repo: repo, questionId: 'q2');
      await openSection(tester, '复习记录');
      expect(find.text('加入复习'), findsOneWidget);
      await tapText(tester, '加入复习');
      expect(find.text('取消加入复习'), findsOneWidget);
      expect(repo.saved.last.reviewJoined, isTrue);
    });

    testWidgets('未整理题没有加入复习按钮', (tester) async {
      await pumpDetail(tester, questionId: 'q3');
      await openSection(tester, '复习记录');
      expect(find.text('加入复习'), findsNothing);
      expect(find.text('取消加入复习'), findsNothing);
      expect(find.text('未整理的题不能加入复习'), findsOneWidget);
    });

    testWidgets('无错因题加入时提示先补错误类型', (tester) async {
      await pumpDetail(tester, questionId: 'q5');
      await openSection(tester, '复习记录');
      expect(find.text('加入复习'), findsOneWidget);
      await tapText(tester, '加入复习');
      await tester.pump();
      expect(find.text('先补错误类型'), findsOneWidget);
    });
  });

  group('编辑', () {
    testWidgets('改标题后保存生效', (tester) async {
      final repo = detailRepo();
      await pumpDetail(tester, repo: repo);
      await tapText(tester, '编辑');
      expect(find.textContaining('正在编辑这道题'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '函数极限改');
      await tapText(tester, '保存', first: true);
      expect(find.text('数学 · 极限题｜函数极限改'), findsOneWidget);
      expect(repo.saved.last.title, '函数极限改');
      expect(find.text('编辑'), findsOneWidget);
    });

    testWidgets('取消无改动直接退出编辑', (tester) async {
      await pumpDetail(tester);
      await tapText(tester, '编辑');
      await tapText(tester, '取消', first: true);
      expect(find.text('编辑'), findsOneWidget);
      expect(find.text('保存'), findsNothing);
    });

    testWidgets('取消有改动弹出内联确认框，三按钮行为正确', (tester) async {
      final repo = detailRepo();
      await pumpDetail(tester, repo: repo);
      await tapText(tester, '编辑');
      await tester.enterText(find.byType(TextField).first, '函数极限改');
      await tapText(tester, '取消', first: true);
      expect(find.text('有还没保存的改动，要保存吗？'), findsOneWidget);
      expect(find.text('保存并退出'), findsOneWidget);
      expect(find.text('不保存，丢弃改动'), findsOneWidget);
      expect(find.text('继续编辑'), findsOneWidget);
      // 继续编辑：仍在编辑态
      await tapText(tester, '继续编辑');
      expect(find.text('保存'), findsNWidgets(2));
      // 不保存：退出编辑，标题未变
      await tapText(tester, '取消', first: true);
      await tapText(tester, '不保存，丢弃改动');
      expect(find.text('数学 · 极限题｜函数极限'), findsOneWidget);
      expect(repo.saved, isEmpty);
      // 保存并退出：保存且退出编辑
      await tapText(tester, '编辑');
      await tester.enterText(find.byType(TextField).first, '函数极限改');
      await tapText(tester, '取消', first: true);
      await tapText(tester, '保存并退出');
      expect(find.text('数学 · 极限题｜函数极限改'), findsOneWidget);
      expect(repo.saved.last.title, '函数极限改');
    });

    testWidgets('编辑表单含试卷下拉与芯片多选，学科不可改', (tester) async {
      await pumpDetail(tester);
      await tapText(tester, '编辑');
      expect(find.text('学科（不能改）'), findsOneWidget);
      expect(find.text('试卷（来源）'), findsOneWidget);
      expect(find.text('文件夹（归类 · 可多选，题只存一份 · 只列本题科目自己的文件夹）'),
          findsOneWidget);
      expect(find.text('知识点（可多选、不限个数）'), findsOneWidget);
      expect(find.text('错误类型（固定枚举多选 + 自定义）'), findsOneWidget);
      expect(find.text('标签（不限个数）'), findsOneWidget);
      expect(find.text('＋ 新建文件夹'), findsOneWidget);
      expect(find.text('＋ 新建知识点'), findsOneWidget);
      expect(find.text('＋ 新建错误类型'), findsOneWidget);
      expect(find.text('＋ 新建标签'), findsOneWidget);
    });
  });

  group('收藏 / 归档 / 删除 / 上一题 / 下一题', () {
    testWidgets('收藏切换：☆ 收藏 → ★ 已收藏', (tester) async {
      final repo = detailRepo();
      await pumpDetail(tester, repo: repo, questionId: 'q2');
      expect(find.text('☆'), findsOneWidget);
      await tapText(tester, '☆ 收藏');
      expect(find.text('★'), findsOneWidget);
      expect(find.text('★ 已收藏（点击取消）'), findsOneWidget);
      expect(repo.saved.last.isFavorite, isTrue);
    });

    testWidgets('归档切换：归档 → 已归档横幅 + 恢复', (tester) async {
      final repo = detailRepo();
      await pumpDetail(tester, repo: repo);
      await tapText(tester, '归档');
      expect(find.text('恢复（取消归档）'), findsOneWidget);
      expect(
          find.textContaining('这道题已归档：不在错题本列表里显示。'),
          findsOneWidget);
      expect(repo.saved.last.isArchived, isTrue);
    });

    testWidgets('删除内联确认：取消留题，确认删除后进下一题', (tester) async {
      final repo = detailRepo();
      await pumpDetail(tester, repo: repo);
      await tapText(tester, '删除');
      expect(find.textContaining('删了就没了，确定吗？'), findsOneWidget);
      expect(
          find.textContaining('整题图与全部补充内容一并删除，不可恢复。'),
          findsOneWidget);
      await tapText(tester, '取消', first: true);
      expect(find.text('数学 · 极限题｜函数极限'), findsOneWidget);
      expect(repo.deletedIds, isEmpty);
      await tapText(tester, '删除');
      await tapText(tester, '确认删除');
      expect(repo.deletedIds, ['q1']);
      expect(find.text('数学 · 函数题｜导数应用综合'), findsOneWidget);
      // 删掉 q1 后列表剩 2 项，q2 排第 1 位。
      expect(find.text('第 1 / 2 题 · 按错题本当前的顺序'), findsOneWidget);
    });

    testWidgets('上一题 / 下一题按来源列表顺序，首末禁用', (tester) async {
      await pumpDetail(tester);
      // 首题：上一题点按无反应
      await tapText(tester, '上一题');
      expect(find.text('数学 · 极限题｜函数极限'), findsOneWidget);
      await tapText(tester, '下一题');
      expect(find.text('数学 · 函数题｜导数应用综合'), findsOneWidget);
      await tapText(tester, '上一题');
      expect(find.text('数学 · 极限题｜函数极限'), findsOneWidget);
      // 到末题：下一题点按无反应
      await tapText(tester, '下一题');
      await tapText(tester, '下一题');
      expect(find.text('数学 · 图表题｜定积分阴影面积'), findsOneWidget);
      await tapText(tester, '下一题');
      expect(find.text('数学 · 图表题｜定积分阴影面积'), findsOneWidget);
    });
  });

  group('空态与错误态', () {
    testWidgets('无文字内容题显示空内容横幅', (tester) async {
      await pumpDetail(tester, questionId: 'q2');
      expect(
          find.textContaining('这道题还没有补充任何文字内容'),
          findsOneWidget);
    });

    testWidgets('imageFailed 显示学科图标 + 题型占位 + 错误横幅', (tester) async {
      await pumpDetail(tester, imageFailed: true);
      expect(find.text('数'), findsOneWidget);
      expect(find.text('数学 · 极限题'), findsOneWidget);
      expect(find.textContaining('这道题的图片读取失败'), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
    });
  });

  group('亮/深 × 三档缩放', () {
    testWidgets('详情页亮/深 × 1.00/1.15/1.30 无溢出', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        for (final scale in [1.0, 1.15, 1.3]) {
          await pumpDetail(tester, brightness: brightness, scale: scale);
          await openSection(tester, '答案解析');
          await tapText(tester, '看答案');
          await openSection(tester, '题目信息');
          await openSection(tester, '复习记录');
          expect(find.text('数学 · 极限题｜函数极限'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets('编辑态亮/深 × 1.00/1.15/1.30 无溢出', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        for (final scale in [1.0, 1.15, 1.3]) {
          await pumpDetail(tester, brightness: brightness, scale: scale);
          await tapText(tester, '编辑');
          expect(find.textContaining('正在编辑这道题'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      }
    });
  });
}
