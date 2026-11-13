// R5 整理工作台 widget 测试：H 布局、队列弹窗（单行 + 详情展开、
// 搜索只匹配题名/学科/试卷、默认时间降序、批量条只在勾选时出现、
// 关闭清勾选、Esc 关闭）、确认进下一题、文件夹必填、切换自动保存、
// 空状态两种、图加载失败、高亮开关、修框切片、放大浮层、亮/深 ×
// 三档缩放无溢出、页内无边距、不用图标字体。
// 用 FakeRepo 覆盖 repository 调用（不碰真实数据库，不改口径）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/organize/organize_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';
import 'package:quiz_master2/widgets/widgets.dart';

Question q(
  String id,
  String title, {
  String subjectId = 'math',
  String sliceKind = 'limit',
  String sliceText = '题：lim(x→0) sin 3x / x 的值是（　）',
  List<String> folderIds = const [],
  String? examId,
  DateTime? createdAt,
  bool isOrganized = false,
}) =>
    Question(
      id: id,
      title: title,
      subjectId: subjectId,
      folderIds: folderIds,
      examId: examId,
      sliceKind: sliceKind,
      sliceText: sliceText,
      createdAt: createdAt ?? DateTime(2026, 11, 8),
      isOrganized: isOrganized,
    );

class FakeOrganizeRepo extends QuestionRepository {
  FakeOrganizeRepo({
    required this.questions,
    required this.folderList,
    this.examList = const [],
    this.kpList = const [],
    this.tagList = const [],
  }) : super(AppDatabase.instance);

  List<Question> questions;
  List<Folder> folderList;
  List<Exam> examList;
  List<KnowledgePoint> kpList;
  List<String> tagList;
  final List<Question> saved = [];
  final List<String> deletedIds = [];
  final List<Folder> savedFolders = [];

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
  Future<List<KnowledgePoint>> knowledgePoints() async => List.of(kpList);

  @override
  Future<List<String>> tags() async => List.of(tagList);

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
    folderList.add(folder);
  }

  @override
  Future<void> addExam(Exam exam) async {
    examList.add(exam);
  }

  @override
  Future<void> addTag(String name) async {
    if (!tagList.contains(name)) tagList.add(name);
  }

  @override
  Future<void> syncCauseRecords(Question question) async {}

  @override
  Future<void> saveRecentTask({
    required String kind,
    required String subjectId,
    required String title,
  }) async {}
}

FakeOrganizeRepo threeQuestionRepo() => FakeOrganizeRepo(
      questions: [
        q('q1', '函数极限', createdAt: DateTime(2026, 11, 8)),
        q(
          'q2',
          '导数综合',
          sliceKind: 'function',
          sliceText: '题：设 f(x) = x³ − 3x² + 2。\n（1）求 f(x) 的单调区间与极值；',
          folderIds: const ['f1'],
          examId: 'e1',
          createdAt: DateTime(2026, 11, 5),
        ),
        q(
          'q3',
          '阅读主旨',
          subjectId: 'english',
          sliceKind: 'material',
          sliceText: '题：The new evidence ______ the original hypothesis.',
          createdAt: DateTime(2026, 11, 3),
        ),
      ],
      folderList: const [
        Folder(id: 'f1', name: '试卷', subjectId: 'math'),
        Folder(id: 'f2', name: '平时作业', subjectId: 'math'),
        Folder(id: 'f3', name: '试卷', subjectId: 'english'),
      ],
      examList: [
        Exam(
          id: 'e1',
          name: '高等数学期末试卷',
          date: DateTime(2026, 11, 10),
        ),
      ],
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
        KnowledgePoint(
          id: 'k3',
          subjectId: 'english',
          chapter: '阅读理解',
          name: '主旨大意',
        ),
      ],
      tagList: const ['易错', '常考'],
    );

Future<void> pumpOrganize(
  WidgetTester tester, {
  FakeOrganizeRepo? repo,
  Brightness brightness = Brightness.light,
  double scale = 1.0,
  bool imageFailed = false,
  Key? pageKey,
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
              body: OrganizePage(
                key: pageKey,
                repo: repo ?? threeQuestionRepo(),
                onOpenDetail: (_, __) async {},
                onGoReview: () {},
                onGoCollect: () {},
                imageFailed: imageFailed,
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> openQueue(WidgetTester tester) async {
  await tester.tap(find.text('队列'));
  await tester.pumpAndSettle();
  expect(find.text('待整理队列 · 3 道'), findsOneWidget);
}

Finder popupCheckboxes(WidgetTester tester) => find.descendant(
      of: find.byKey(const Key('organize-queue-popup')),
      matching: find.byType(Checkbox),
    );

void main() {
  group('整理工作台正常态', () {
    testWidgets('H 布局：左图右表、顶栏队列 + 当前整理、页内无边距、无 Icon',
        (tester) async {
      await pumpOrganize(tester);
      expect(find.text('整理工作台'), findsOneWidget);
      expect(find.text('队列'), findsOneWidget);
      expect(find.text('还剩 3 道'), findsOneWidget);
      expect(find.textContaining('当前整理：'), findsOneWidget);
      expect(find.textContaining('数学 · 函数极限'), findsOneWidget);
      // 左图在左、右表单在右。
      final sliceX =
          tester.getTopLeft(find.byType(QuestionSlice)).dx;
      final folderX =
          tester.getTopLeft(find.text('文件夹（归类）')).dx;
      expect(sliceX, lessThan(folderX));
      // 页内无边距：外壳已给 26/30。
      final scroll = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView).first,
      );
      expect(scroll.padding, EdgeInsets.zero);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('待补充行只数必填项；文件夹必填，缺了确认被拦下',
        (tester) async {
      final repo = threeQuestionRepo();
      await pumpOrganize(tester, repo: repo);
      expect(find.textContaining('本题待补充 1 项（只数必填）'), findsOneWidget);
      await tester.ensureVisible(find.text('确认整理，去下一道'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认整理，去下一道'));
      await tester.pumpAndSettle();
      expect(find.text('先选文件夹'), findsOneWidget);
      expect(
        repo.saved.where((x) => x.isOrganized),
        isEmpty,
      );
    });

    testWidgets('选文件夹后确认整理，进下一道（按时间降序）', (tester) async {
      final repo = threeQuestionRepo();
      await pumpOrganize(tester, repo: repo);
      await tester.tap(find.text('试卷').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('本题必填已齐'), findsOneWidget);
      await tester.ensureVisible(find.text('确认整理，去下一道'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认整理，去下一道'));
      await tester.pumpAndSettle();
      expect(
        repo.saved.any((x) => x.id == 'q1' && x.isOrganized),
        isTrue,
      );
      expect(find.textContaining('数学 · 导数综合'), findsOneWidget);
      expect(find.text('还剩 2 道'), findsOneWidget);
    });

    testWidgets('切题自动保存：填了答案再点下一道，答案已落库',
        (tester) async {
      final repo = threeQuestionRepo();
      await pumpOrganize(tester, repo: repo);
      await tester.ensureVisible(find.text('答案 · 解析 · 笔记（可选）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('答案 · 解析 · 笔记（可选）'));
      await tester.pumpAndSettle();
      final answerField = find.byWidgetPredicate(
        (w) =>
            w is TextField && w.decoration?.hintText == '还没想好可留空',
      );
      await tester.enterText(answerField, '答案：1');
      await tester.ensureVisible(find.text('下一道'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一道'));
      await tester.pumpAndSettle();
      expect(
        repo.saved.any((x) => x.id == 'q1' && x.answer == '答案：1'),
        isTrue,
      );
      expect(find.textContaining('数学 · 导数综合'), findsOneWidget);
    });

    testWidgets('修框切片默认展开：每框一张卡（整题 + 题干 + 选项）',
        (tester) async {
      await pumpOrganize(tester);
      expect(find.text('修框切片'), findsOneWidget);
      expect(find.text('整题框切片'), findsOneWidget);
      expect(find.text('题干框切片'), findsOneWidget);
      expect(find.text('选项框切片'), findsOneWidget);
      expect(find.text('配图框切片'), findsNothing);
      expect(find.text('切片图'), findsWidgets);
    });

    testWidgets('高亮开关：关掉 stem，复选框值变 false', (tester) async {
      await pumpOrganize(tester);
      final toggles = find.byType(Checkbox);
      expect(toggles, findsNWidgets(2));
      await tester.tap(toggles.first);
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(toggles.first).value, isFalse);
    });

    testWidgets('放大浮层：点图弹出 1.5×、带比例 pill，关闭回到整理台',
        (tester) async {
      await pumpOrganize(tester);
      await tester.tap(find.byType(QuestionSlice));
      await tester.pumpAndSettle();
      expect(find.text('整题图 · 放大查看'), findsOneWidget);
      expect(find.text('150%'), findsOneWidget);
      await tester.tap(find.text('关闭 ×'));
      await tester.pumpAndSettle();
      expect(find.text('整题图 · 放大查看'), findsNothing);
    });

    testWidgets('分类补充：知识点树多选、自定义错误类型、预置标签',
        (tester) async {
      await pumpOrganize(tester);
      await tester.ensureVisible(find.text('分类补充（可选）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('分类补充（可选）'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('数学 › 第一章 函数与极限'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('数学 › 第一章 函数与极限'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('函数极限'));
      await tester.pumpAndSettle();
      final kpChip = tester.widget<QmChip>(
        find.byWidgetPredicate(
          (w) => w is QmChip && w.label == '函数极限',
        ),
      );
      expect(kpChip.selected, isTrue);
      expect(find.textContaining('已选 1 个'), findsWidgets);
      // 自定义错误类型。
      final customField = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.hintText == '自定义错误类型…（枚举之外的情况）',
      );
      await tester.enterText(customField, '公式记混');
      await tester.tap(find.text('添加并选上'));
      await tester.pumpAndSettle();
      expect(find.text('公式记混（自定义）'), findsWidgets);
      // 预置标签。
      await tester.tap(find.text('需重做'));
      await tester.pumpAndSettle();
      final tagChip = tester.widget<QmChip>(
        find.byWidgetPredicate(
          (w) => w is QmChip && w.label == '需重做',
        ),
      );
      expect(tagChip.selected, isTrue);
    });

    testWidgets('来源：试卷下拉可新建（带日期可选），建完自动归属',
        (tester) async {
      final repo = threeQuestionRepo();
      await pumpOrganize(tester, repo: repo);
      await tester.ensureVisible(find.text('来源（可选）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('来源（可选）'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('＋ 添加新试卷…').last);
      await tester.pumpAndSettle();
      final nameField = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.hintText == '试卷名，如：高等数学期末试卷',
      );
      await tester.enterText(nameField, '数学月考卷');
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();
      expect(repo.examList.any((e) => e.name == '数学月考卷'), isTrue);
      expect(find.textContaining('数学月考卷'), findsOneWidget);
    });
  });

  group('队列弹出层 D 极简式', () {
    testWidgets('单行 + 详情只在当前题下展开；默认时间降序',
        (tester) async {
      await pumpOrganize(tester);
      await openQueue(tester);
      expect(find.text('函数极限'), findsOneWidget);
      expect(find.text('导数综合'), findsOneWidget);
      expect(find.text('阅读主旨'), findsOneWidget);
      // 详情行只在当前题（q1）下方展开一行。
      expect(
        find.descendant(
          of: find.byKey(const Key('organize-queue-popup')),
          matching: find.textContaining('试卷（来源）：未归属'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('organize-queue-popup')),
          matching: find.textContaining('待补充 1 项'),
        ),
        findsOneWidget,
      );
      // 时间降序：新的在上。
      final y1 = tester.getTopLeft(find.text('函数极限')).dy;
      final y2 = tester.getTopLeft(find.text('导数综合')).dy;
      final y3 = tester.getTopLeft(find.text('阅读主旨')).dy;
      expect(y1, lessThan(y2));
      expect(y2, lessThan(y3));
    });

    testWidgets('点行跳转到那道题，弹出层关闭', (tester) async {
      await pumpOrganize(tester);
      await openQueue(tester);
      await tester.tap(find.text('导数综合'));
      await tester.pumpAndSettle();
      expect(find.text('待整理队列 · 3 道'), findsNothing);
      expect(find.textContaining('数学 · 导数综合'), findsOneWidget);
    });

    testWidgets('搜索只匹配题名/学科/试卷，不搜题干', (tester) async {
      await pumpOrganize(tester);
      await openQueue(tester);
      final searchField = find.byWidgetPredicate(
        (w) =>
            w is TextField && w.decoration?.hintText == '搜题名、学科、试卷',
      );
      await tester.enterText(searchField, '函数');
      await tester.pumpAndSettle();
      expect(find.text('函数极限'), findsOneWidget);
      expect(find.text('导数综合'), findsNothing);
      expect(find.textContaining('搜到 1 道'), findsOneWidget);
      // “单调”只在 q2 题干里，不应搜到。
      await tester.enterText(searchField, '单调');
      await tester.pumpAndSettle();
      expect(find.text('没找到这道题，换个词试试'), findsOneWidget);
    });

    testWidgets('批量条只在勾选时出现；取消清勾选，条消失',
        (tester) async {
      await pumpOrganize(tester);
      await openQueue(tester);
      expect(find.textContaining('批量操作 · 已选'), findsNothing);
      await tester.tap(popupCheckboxes(tester).first);
      await tester.pumpAndSettle();
      expect(find.text('批量操作 · 已选 1 道'), findsOneWidget);
      expect(find.text('批量打标签 #需重做'), findsOneWidget);
      expect(find.text('批量确认整理'), findsOneWidget);
      expect(find.text('批量删除'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.textContaining('批量操作 · 已选'), findsNothing);
    });

    testWidgets('批量打标签 #需重做', (tester) async {
      final repo = threeQuestionRepo();
      await pumpOrganize(tester, repo: repo);
      await openQueue(tester);
      await tester.tap(popupCheckboxes(tester).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量打标签 #需重做'));
      await tester.pumpAndSettle();
      expect(
        repo.saved.any(
          (x) => x.id == 'q1' && x.tags.contains('需重做'),
        ),
        isTrue,
      );
      expect(find.textContaining('已给 1 道题打上 #需重做'), findsOneWidget);
    });

    testWidgets('批量删除要二次确认；确认后题被删', (tester) async {
      final repo = threeQuestionRepo();
      await pumpOrganize(tester, repo: repo);
      await openQueue(tester);
      await tester.tap(popupCheckboxes(tester).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量删除'));
      await tester.pumpAndSettle();
      expect(find.text('删了就没了，确定吗？'), findsOneWidget);
      expect(repo.deletedIds, isEmpty);
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(repo.deletedIds, contains('q1'));
      expect(find.text('函数极限'), findsNothing);
      expect(find.textContaining('批量操作 · 已选'), findsNothing);
    });

    testWidgets('单行删除也要确认；取消则不删', (tester) async {
      final repo = threeQuestionRepo();
      await pumpOrganize(tester, repo: repo);
      await openQueue(tester);
      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();
      expect(find.text('确认删除这道题？'), findsOneWidget);
      expect(repo.deletedIds, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(repo.deletedIds, isEmpty);
      expect(find.text('阅读主旨'), findsOneWidget);
    });

    testWidgets('关闭弹窗清勾选：关掉再打开，已选归零', (tester) async {
      await pumpOrganize(tester);
      await openQueue(tester);
      await tester.tap(popupCheckboxes(tester).first);
      await tester.pumpAndSettle();
      expect(find.text('批量操作 · 已选 1 道'), findsOneWidget);
      await tester.tap(find.text('关闭 ×'));
      await tester.pumpAndSettle();
      expect(find.text('待整理队列 · 3 道'), findsNothing);
      await openQueue(tester);
      expect(find.textContaining('批量操作 · 已选'), findsNothing);
    });

    testWidgets('Esc 关闭弹窗并清勾选', (tester) async {
      await pumpOrganize(tester);
      await openQueue(tester);
      await tester.tap(popupCheckboxes(tester).first);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('待整理队列 · 3 道'), findsNothing);
      await openQueue(tester);
      expect(find.textContaining('批量操作 · 已选'), findsNothing);
    });
  });

  group('空状态与失败态', () {
    testWidgets('从未有题：去收集', (tester) async {
      await pumpOrganize(
        tester,
        repo: FakeOrganizeRepo(questions: [], folderList: []),
      );
      expect(find.text('没有待整理的题目'), findsOneWidget);
      expect(find.text('先去收集题目'), findsOneWidget);
      expect(find.text('都整理完了，去复习吧'), findsNothing);
    });

    testWidgets('队列已空：去复习', (tester) async {
      await pumpOrganize(
        tester,
        repo: FakeOrganizeRepo(
          questions: [
            q('q1', '函数极限', isOrganized: true),
          ],
          folderList: [],
        ),
      );
      expect(find.text('都整理完了，去复习吧'), findsOneWidget);
      expect(find.text('去复习'), findsOneWidget);
    });

    testWidgets('图加载失败：学科图标 + 题型文字占位，切片区隐藏',
        (tester) async {
      await pumpOrganize(tester, imageFailed: true);
      expect(find.textContaining('整题图加载失败'), findsOneWidget);
      expect(find.text('数学 · 极限题'), findsOneWidget);
      expect(find.text('修框切片'), findsNothing);
    });
  });

  group('亮/深与三档缩放', () {
    testWidgets('亮/深 × 1.00/1.15/1.30 无溢出', (tester) async {
      var n = 0;
      for (final brightness in [Brightness.light, Brightness.dark]) {
        for (final scale in [1.0, 1.15, 1.30]) {
          n++;
          await pumpOrganize(
            tester,
            brightness: brightness,
            scale: scale,
            pageKey: ValueKey('scale-$n'),
          );
          expect(find.text('整理工作台'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets('队列弹窗亮/深 × 三档缩放无溢出', (tester) async {
      var n = 0;
      for (final brightness in [Brightness.light, Brightness.dark]) {
        for (final scale in [1.0, 1.15, 1.30]) {
          n++;
          await pumpOrganize(
            tester,
            brightness: brightness,
            scale: scale,
            pageKey: ValueKey('queue-scale-$n'),
          );
          await openQueue(tester);
          expect(find.text('待整理队列 · 3 道'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('关闭 ×'));
          await tester.pumpAndSettle();
        }
      }
    });
  });
}
