// R10 学科管理页 widget 测试：四段折叠（默认全折、一次只开一段）、
// 学科增删改名 + 删学科长文案确认、封面 6 样式 × 7 色点即生效、
// 知识点树页签/章节折叠/章节与知识点增删改名、标签/试卷增删改名、
// 试卷搜索无匹配文案、加载失败横幅、亮/深 × 三档无溢出、不用图标字体。
// 用 FakeRepo 覆盖 repository 调用（不碰真实数据库）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/subjects/subjects_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';

Question _tq(String id, String title,
        {String subjectId = 'math',
        List<String> tags = const [],
        String? examId}) =>
    Question(
      id: id,
      title: title,
      subjectId: subjectId,
      tags: tags,
      examId: examId,
      createdAt: DateTime.now(),
      isOrganized: true,
      sliceKind: 'material',
      sliceText: '题：$title',
    );

class FakeSubjectsRepo extends QuestionRepository {
  FakeSubjectsRepo({this.throwOnLoad = false})
      : super(AppDatabase.instance);

  bool throwOnLoad;
  List<Subject> subjectsList = List.of(Subject.all);
  List<Question> questions = [
    _tq('q1', '函数极限'),
    _tq('q2', '导数应用'),
    _tq('q3', '定积分', tags: ['易错'], examId: 'exam-1'),
    _tq('q4', '学术词汇', subjectId: 'english', tags: ['易错', '常考']),
    _tq('q5', '长篇阅读', subjectId: 'english'),
    _tq('q6', '史纲时间轴', subjectId: 'politics', examId: 'exam-1'),
  ];
  List<KnowledgePoint> kps = [
    KnowledgePoint(id: 'kp-1', subjectId: 'math', chapter: '函数与极限', name: '函数极限'),
    KnowledgePoint(id: 'kp-2', subjectId: 'math', chapter: '函数与极限', name: '导数应用'),
    KnowledgePoint(id: 'kp-3', subjectId: 'math', chapter: '定积分', name: '定积分应用'),
    KnowledgePoint(id: 'kp-4', subjectId: 'english', chapter: '词汇', name: '学术词汇'),
  ];
  List<String> tagsList = ['易错', '常考', '需重做'];
  List<Exam> examsList = [
    Exam(id: 'exam-1', name: '2026 期中考试', date: DateTime(2026, 11, 5)),
    Exam(id: 'exam-2', name: '2026 月考', date: DateTime(2026, 10, 20)),
  ];
  List<Folder> savedFolders = [];

  void _throw() {
    if (throwOnLoad) throw StateError('db down');
  }

  @override
  Future<List<Subject>> subjects() async {
    _throw();
    return List.of(subjectsList);
  }

  @override
  Future<List<Question>> all({bool includeArchived = false}) async {
    _throw();
    return List.of(questions);
  }

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async {
    _throw();
    return List.of(kps);
  }

  @override
  Future<List<String>> tags() async {
    _throw();
    return List.of(tagsList);
  }

  @override
  Future<List<Exam>> exams() async {
    _throw();
    return List.of(examsList);
  }

  @override
  Future<void> saveSubject(Subject s) async {
    final i = subjectsList.indexWhere((e) => e.id == s.id);
    if (i >= 0) {
      subjectsList[i] = s;
    } else {
      subjectsList.add(s);
    }
  }

  @override
  Future<void> deleteSubject(String id) async {
    subjectsList.removeWhere((e) => e.id == id);
    questions.removeWhere((q) => q.subjectId == id);
  }

  @override
  Future<void> saveFolder(Folder f) async {
    savedFolders.add(f);
  }

  @override
  Future<void> addKnowledgePoint(KnowledgePoint kp) async {
    kps.add(kp);
  }

  @override
  Future<void> renameKnowledgePoint(String id, String newName) async {
    final i = kps.indexWhere((e) => e.id == id);
    if (i >= 0) {
      kps[i] = KnowledgePoint(
          id: id,
          subjectId: kps[i].subjectId,
          chapter: kps[i].chapter,
          name: newName);
    }
  }

  @override
  Future<void> deleteKnowledgePoint(String id) async {
    kps.removeWhere((e) => e.id == id);
  }

  @override
  Future<void> renameChapter(
      String subjectId, String oldChapter, String newChapter) async {
    for (var i = 0; i < kps.length; i++) {
      if (kps[i].subjectId == subjectId && kps[i].chapter == oldChapter) {
        kps[i] = KnowledgePoint(
            id: kps[i].id,
            subjectId: subjectId,
            chapter: newChapter,
            name: kps[i].name);
      }
    }
  }

  @override
  Future<void> deleteChapter(String subjectId, String chapter) async {
    kps.removeWhere(
        (e) => e.subjectId == subjectId && e.chapter == chapter);
  }

  @override
  Future<void> addTag(String name) async {
    tagsList.add(name);
  }

  @override
  Future<void> renameTag(String oldName, String newName) async {
    final i = tagsList.indexOf(oldName);
    if (i >= 0) tagsList[i] = newName;
    // 与真实数据库一致：打了这个标签的题跟着改名。
    for (var j = 0; j < questions.length; j++) {
      final q = questions[j];
      if (!q.tags.contains(oldName)) continue;
      questions[j] = Question(
        id: q.id,
        title: q.title,
        subjectId: q.subjectId,
        folderIds: q.folderIds,
        examId: q.examId,
        knowledgePointIds: q.knowledgePointIds,
        errorTypes: q.errorTypes,
        customErrorTypes: q.customErrorTypes,
        tags: q.tags.map((t) => t == oldName ? newName : t).toList(),
        answer: q.answer,
        explanation: q.explanation,
        notes: q.notes,
        reviewCount: q.reviewCount,
        isOrganized: q.isOrganized,
        isDemo: q.isDemo,
        isFavorite: q.isFavorite,
        isArchived: q.isArchived,
        reviewJoined: q.reviewJoined,
        createdAt: q.createdAt,
        sliceKind: q.sliceKind,
        sliceText: q.sliceText,
      );
    }
  }

  @override
  Future<void> deleteTag(String name) async {
    tagsList.remove(name);
  }

  @override
  Future<void> addExam(Exam e) async {
    examsList.add(e);
  }

  @override
  Future<void> renameExam(String id, String newName) async {
    final i = examsList.indexWhere((e) => e.id == id);
    if (i >= 0) {
      examsList[i] = Exam(id: id, name: newName, date: examsList[i].date);
    }
  }

  @override
  Future<void> deleteExam(String id) async {
    examsList.removeWhere((e) => e.id == id);
  }
}

Future<void> pumpSubjects(
  WidgetTester tester, {
  FakeSubjectsRepo? repo,
  Brightness brightness = Brightness.light,
  double scale = 1.0,
  double width = 1280,
}) async {
  tester.view.physicalSize = Size(width, 720);
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
              body: SubjectsPage(
                key: UniqueKey(),
                repo: repo ?? FakeSubjectsRepo(),
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
  await tester.ensureVisible(find.text(title).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(title).first);
  await tester.pumpAndSettle();
}

void main() {
  group('学科管理：折叠', () {
    testWidgets('默认全折叠：四段标题可见，段内容不可见', (tester) async {
      await pumpSubjects(tester);
      expect(find.text('学科管理'), findsOneWidget);
      for (final t in ['学科', '知识点树', '标签', '试卷']) {
        expect(find.text(t), findsOneWidget);
      }
      expect(find.text('＋ 添加学科'), findsNothing);
      expect(find.text('＋ 添加标签'), findsNothing);
      expect(find.text('＋ 添加试卷'), findsNothing);
    });

    testWidgets('一次只开一段：开学科再开知识点树，学科内容收起',
        (tester) async {
      await pumpSubjects(tester);
      await openSection(tester, '学科');
      expect(find.text('＋ 添加学科'), findsOneWidget);
      await openSection(tester, '知识点树');
      expect(find.text('＋ 添加学科'), findsNothing);
      expect(find.text('＋ 添加章节'), findsOneWidget);
    });

    testWidgets('点同一段标题收起', (tester) async {
      await pumpSubjects(tester);
      await openSection(tester, '标签');
      expect(find.text('＋ 添加标签'), findsOneWidget);
      await openSection(tester, '标签');
      expect(find.text('＋ 添加标签'), findsNothing);
    });
  });

  group('学科管理：学科', () {
    testWidgets('学科行：色点 + 名 + N 道题 + 改名/删除', (tester) async {
      await pumpSubjects(tester);
      await openSection(tester, '学科');
      expect(find.text('数学'), findsOneWidget);
      expect(find.text('3 道题'), findsOneWidget);
      expect(find.text('英语'), findsOneWidget);
      expect(find.text('2 道题'), findsOneWidget);
      expect(find.text('政治'), findsOneWidget);
      expect(find.text('1 道题'), findsOneWidget);
      expect(find.text('改名'), findsWidgets);
      expect(find.text('删除'), findsWidgets);
    });

    testWidgets('添加学科：输入物理点按钮，新增且带预置文件夹',
        (tester) async {
      final repo = FakeSubjectsRepo();
      await pumpSubjects(tester, repo: repo);
      await openSection(tester, '学科');
      await tester.enterText(find.byType(TextField).first, '物理');
      await tester.tap(find.text('＋ 添加学科'));
      await tester.pumpAndSettle();
      expect(find.text('物理'), findsOneWidget);
      expect(find.text('0 道题'), findsOneWidget);
      // 新学科：圆点轮换到紫（新蓝/新绿/新红已被三科占掉），封面默认灰。
      final added = repo.subjectsList.last;
      expect(added.name, '物理');
      expect(added.color, const Color(0xFF7C5CFC));
      expect(added.coverColor, 'grey');
      // 列表里新学科的圆点必须真画成紫色（R1 前圆点直接读 s.color；
      // R1 改成按 id 查表后新学科永远是数学蓝，2026-11-13 修回）。
      expect(
          find.byWidgetPredicate((w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color ==
                  const Color(0xFF7C5CFC)),
          findsOneWidget);
      expect(repo.savedFolders.map((f) => f.name),
          containsAll(['试卷', '平时作业', '模拟卷']));
      expect(repo.savedFolders.every((f) => f.subjectId.startsWith('subject-')),
          isTrue);
    });

    testWidgets('添加重名学科提示已经有了', (tester) async {
      await pumpSubjects(tester);
      await openSection(tester, '学科');
      await tester.enterText(find.byType(TextField).first, '数学');
      await tester.tap(find.text('＋ 添加学科'));
      await tester.pumpAndSettle();
      expect(find.text('已经有了这个学科'), findsOneWidget);
      // 新增输入框里还留着“数学”，行里也有“数学”，共 2 处。
      expect(find.text('数学'), findsWidgets);
    });

    testWidgets('改名学科：行内改名保存', (tester) async {
      final repo = FakeSubjectsRepo();
      await pumpSubjects(tester, repo: repo);
      await openSection(tester, '学科');
      await tester.tap(find.text('改名').first);
      await tester.pumpAndSettle();
      expect(find.text('保存改名'), findsOneWidget);
      // 改名输入框是段内最后一个输入框（前面还有新增学科输入框）。
      await tester.enterText(find.byType(TextField).last, '高等数学');
      await tester.tap(find.text('保存改名'));
      await tester.pumpAndSettle();
      expect(find.text('高等数学'), findsOneWidget);
      expect(repo.subjectsList.first.name, '高等数学');
    });

    testWidgets('删除学科：长文案确认框，确认后删除', (tester) async {
      final repo = FakeSubjectsRepo();
      await pumpSubjects(tester, repo: repo);
      await openSection(tester, '学科');
      await tester.tap(find.text('删除').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('删除学科「数学」，确定吗？'), findsOneWidget);
      expect(
          find.textContaining('这一科现在有 3 道题，会全部一起删掉'),
          findsOneWidget);
      expect(find.textContaining('这一科自己的文件夹也跟着一起删掉'),
          findsOneWidget);
      expect(find.text('确认删除这一科和全部 3 道题'), findsOneWidget);
      await tester.tap(find.text('确认删除这一科和全部 3 道题'));
      await tester.pumpAndSettle();
      expect(find.text('数学'), findsNothing);
      expect(repo.subjectsList.map((s) => s.id), isNot(contains('math')));
    });

    testWidgets('删除学科：点取消不删', (tester) async {
      final repo = FakeSubjectsRepo();
      await pumpSubjects(tester, repo: repo);
      await openSection(tester, '学科');
      await tester.tap(find.text('删除').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消').first);
      await tester.pumpAndSettle();
      expect(find.text('数学'), findsOneWidget);
      expect(repo.subjectsList.length, 3);
    });
  });

  group('学科管理：封面样式', () {
    testWidgets('封面块默认折起，展开后 6 样式 × 7 色，点即生效',
        (tester) async {
      final repo = FakeSubjectsRepo();
      await pumpSubjects(tester, repo: repo);
      await openSection(tester, '学科');
      expect(find.text('纯色折角'), findsNothing);
      await tester.tap(find.text('错题本封面样式'));
      await tester.pumpAndSettle();
      for (final label in ['纯色折角', '横线纹', '圆点', '方格纹', '斜纹', '双线框']) {
        expect(find.text(label), findsWidgets);
      }
      for (final color in ['蓝', '绿', '红', '紫', '橙', '黄', '灰']) {
        expect(find.text(color), findsWidgets);
      }
      expect(find.textContaining('当前封面：纯色折角 · 蓝色'), findsWidgets);
      // 点数学的“圆点”样式：第一个“圆点”签属于数学。
      await tester.tap(find.text('圆点').first);
      await tester.pumpAndSettle();
      expect(repo.subjectsList.first.coverStyle, 'dots');
      expect(find.textContaining('当前封面：圆点 · 蓝色'), findsWidgets);
      // 点数学的“绿”色：第一个“绿”签属于数学。
      await tester.tap(find.text('绿').first);
      await tester.pumpAndSettle();
      expect(repo.subjectsList.first.coverColor, 'green');
      expect(find.textContaining('当前封面：圆点 · 绿色'), findsWidgets);
    });
  });

  group('学科管理：知识点树', () {
    testWidgets('默认数学页签，章节默认折起，点章节展开见知识点行',
        (tester) async {
      await pumpSubjects(tester);
      await openSection(tester, '知识点树');
      expect(find.textContaining('函数与极限'), findsOneWidget);
      expect(find.textContaining('定积分'), findsOneWidget);
      expect(find.text('函数极限'), findsNothing);
      await tester.tap(find.textContaining('函数与极限'));
      await tester.pumpAndSettle();
      expect(find.text('函数极限'), findsOneWidget);
      expect(find.text('导数应用'), findsOneWidget);
      expect(find.text('＋ 添加知识点'), findsOneWidget);
    });

    testWidgets('章节行带知识点数', (tester) async {
      await pumpSubjects(tester);
      await openSection(tester, '知识点树');
      expect(find.textContaining('2 个知识点'), findsOneWidget);
      expect(find.textContaining('1 个知识点'), findsOneWidget);
    });

    testWidgets('页签切换到英语，只看英语的树', (tester) async {
      await pumpSubjects(tester);
      await openSection(tester, '知识点树');
      await tester.tap(find.text('英语').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('词汇 · 1 个知识点'), findsOneWidget);
      expect(find.textContaining('函数与极限'), findsNothing);
    });

    testWidgets('添加章节：填章节 + 第一个知识点，章节出现且展开',
        (tester) async {
      final repo = FakeSubjectsRepo();
      await pumpSubjects(tester, repo: repo);
      await openSection(tester, '知识点树');
      await tester.tap(find.text('＋ 添加章节'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '导数与微分');
      await tester.enterText(fields.at(1), '导数定义');
      await tester.tap(find.text('添加章节'));
      await tester.pumpAndSettle();
      expect(find.textContaining('导数与微分'), findsOneWidget);
      expect(find.text('导数定义'), findsOneWidget);
      expect(repo.kps.any((k) => k.chapter == '导数与微分'), isTrue);
    });

    testWidgets('章节改名：行内改名保存', (tester) async {
      final repo = FakeSubjectsRepo();
      await pumpSubjects(tester, repo: repo);
      await openSection(tester, '知识点树');
      // 章节行的改名是第一个“改名”按钮（章节行在知识点行之前）。
      await tester.tap(find.text('改名').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '函数与极限二');
      await tester.tap(find.text('保存改名'));
      await tester.pumpAndSettle();
      expect(find.textContaining('函数与极限二'), findsOneWidget);
      expect(repo.kps.where((k) => k.chapter == '函数与极限二').length, 2);
    });

    testWidgets('删除章节：确认框含知识点数，确认后章节消失',
        (tester) async {
      final repo = FakeSubjectsRepo();
      await pumpSubjects(tester, repo: repo);
      await openSection(tester, '知识点树');
      await tester.tap(find.text('删除').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('删除章节「函数与极限」，确定吗？'), findsOneWidget);
      expect(find.textContaining('会删掉这个章节下的 2 个知识点'),
          findsOneWidget);
      await tester.ensureVisible(find.text('确认删除'));
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(find.textContaining('函数与极限'), findsNothing);
      expect(repo.kps.any((k) => k.chapter == '函数与极限'), isFalse);
    });

    testWidgets('知识点改名与删除', (tester) async {
      final repo = FakeSubjectsRepo();
      await pumpSubjects(tester, repo: repo);
      await openSection(tester, '知识点树');
      await tester.tap(find.textContaining('函数与极限'));
      await tester.pumpAndSettle();
      // 知识点行的改名：展开后第一个知识点行的改名按钮。
      final renameButtons = find.text('改名');
      await tester.tap(renameButtons.at(1));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '极限定义');
      await tester.tap(find.text('保存改名'));
      await tester.pumpAndSettle();
      expect(find.text('极限定义'), findsOneWidget);
      expect(repo.kps.firstWhere((k) => k.id == 'kp-1').name, '极限定义');
      // 删除该知识点。
      await tester.tap(find.text('删除').at(1));
      await tester.pumpAndSettle();
      expect(find.textContaining('删除知识点「极限定义」，确定吗？'), findsOneWidget);
      await tester.ensureVisible(find.text('确认删除'));
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(find.text('极限定义'), findsNothing);
    });

    testWidgets('添加知识点：展开章节底部输入添加', (tester) async {
      final repo = FakeSubjectsRepo();
      await pumpSubjects(tester, repo: repo);
      await openSection(tester, '知识点树');
      await tester.tap(find.textContaining('函数与极限'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('＋ 添加知识点'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '极限运算法则');
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();
      expect(find.text('极限运算法则'), findsOneWidget);
      expect(repo.kps.any((k) => k.name == '极限运算法则'), isTrue);
    });
  });

  group('学科管理：标签与试卷', () {
    testWidgets('标签行带 # 与题数，添加/改名/删除', (tester) async {
      final repo = FakeSubjectsRepo();
      await pumpSubjects(tester, repo: repo);
      await openSection(tester, '标签');
      expect(find.text('#易错 · 2 道'), findsOneWidget);
      expect(find.text('#常考 · 1 道'), findsOneWidget);
      expect(find.text('#需重做 · 0 道'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '高频');
      await tester.tap(find.text('＋ 添加标签'));
      await tester.pumpAndSettle();
      expect(find.text('#高频 · 0 道'), findsOneWidget);
      await tester.tap(find.text('改名').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '易错题');
      await tester.tap(find.text('保存改名'));
      await tester.pumpAndSettle();
      expect(find.text('#易错题 · 2 道'), findsOneWidget);
      await tester.tap(find.text('删除').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('删除标签「易错题」，确定吗？'), findsOneWidget);
      await tester.ensureVisible(find.text('确认删除'));
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(find.text('#易错题 · 2 道'), findsNothing);
    });

    testWidgets('试卷行带日期与题数，搜索无匹配显示提示', (tester) async {
      await pumpSubjects(tester);
      await openSection(tester, '试卷');
      expect(find.text('2026 期中考试 · 2026-11-05 · 2 道题来自这张试卷'),
          findsOneWidget);
      expect(find.text('2026 月考 · 2026-10-20 · 0 道题来自这张试卷'),
          findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '不存在的卷子');
      await tester.pumpAndSettle();
      expect(find.text('没找到这张试卷，换个词试试'), findsOneWidget);
      expect(find.textContaining('2026 期中考试'), findsNothing);
      await tester.enterText(find.byType(TextField).first, '月考');
      await tester.pumpAndSettle();
      expect(find.textContaining('2026 月考'), findsOneWidget);
      expect(find.textContaining('2026 期中考试'), findsNothing);
    });

    testWidgets('试卷添加/改名/删除', (tester) async {
      final repo = FakeSubjectsRepo();
      await pumpSubjects(tester, repo: repo);
      await openSection(tester, '试卷');
      // 搜索框是第 1 个输入框，新试卷名是第 2 个。
      await tester.enterText(find.byType(TextField).at(1), '2026 期末考试');
      await tester.tap(find.text('＋ 添加试卷'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2026 期末考试'), findsOneWidget);
      expect(repo.examsList.any((e) => e.name == '2026 期末考试'), isTrue);
      await tester.tap(find.text('改名').first);
      await tester.pumpAndSettle();
      // 改名输入框是段内最后一个输入框（前面还有搜索与新增试卷输入框）。
      await tester.enterText(find.byType(TextField).last, '2026 期中统考');
      await tester.tap(find.text('保存改名'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2026 期中统考'), findsOneWidget);
      await tester.tap(find.text('删除').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('删除试卷「2026 期中统考」，确定吗？'), findsOneWidget);
      await tester.ensureVisible(find.text('确认删除'));
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2026 期中统考'), findsNothing);
    });
  });

  group('学科管理：错误态与无溢出', () {
    testWidgets('加载失败出错误横幅，可关闭', (tester) async {
      await pumpSubjects(tester,
          repo: FakeSubjectsRepo(throwOnLoad: true));
      expect(find.textContaining('学科管理读取失败'), findsOneWidget);
      expect(find.text('知道了'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.textContaining('学科管理读取失败'), findsNothing);
    });

    testWidgets('亮/深 × 三档无溢出', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        for (final scale in [1.0, 1.15, 1.3]) {
          await pumpSubjects(tester,
              brightness: brightness, scale: scale);
          for (final section in ['学科', '知识点树', '标签', '试卷']) {
            await openSection(tester, section);
          }
          await openSection(tester, '学科');
          await tester.tap(find.text('错题本封面样式'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets('不用图标字体', (tester) async {
      await pumpSubjects(tester);
      await openSection(tester, '学科');
      expect(find.byType(Icon), findsNothing);
    });
  });
}
