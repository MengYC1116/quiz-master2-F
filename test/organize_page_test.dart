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
    List<Subject>? subjectsValue,
  })  : subjectsValue = subjectsValue ?? Subject.all,
        super(AppDatabase.instance);

  List<Question> questions;
  List<Folder> folderList;
  List<Exam> examList;
  List<KnowledgePoint> kpList;
  List<String> tagList;
  List<Subject> subjectsValue;

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);
  final List<Question> saved = [];
  final List<String> deletedIds = [];
  final List<Folder> savedFolders = [];

  /// B7：最近一次 saveRecentTask 记下的 kind（应为中文 '整理'）。
  String? lastRecentKind;

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

  /// SR3-15：指定 id 的 save 抛错（批量打标签部分保存失败路径用）。
  final Set<String> failSaveIds = {};

  @override
  Future<void> save(Question question) async {
    if (failSaveIds.contains(question.id)) {
      throw StateError('模拟写库失败');
    }
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

  /// SR-P2-36：整科同名预检的内存版（与 upsertFolder 的把关同语义：
  /// 同一学科、同名、id 不是 excludeId 即命中）。
  @override
  Future<bool> folderNameExistsInSubject(
    String subjectId,
    String name, {
    String? excludeId,
  }) async =>
      folderList.any(
        (f) =>
            f.subjectId == subjectId &&
            f.name == name &&
            f.id != excludeId,
      );

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
  }) async {
    lastRecentKind = kind;
  }
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
  // B9-2：窄窗口用例用（默认 1280×720）。
  Size viewSize = const Size(1280, 720),
}) async {
  tester.view.physicalSize = viewSize;
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

/// 队列弹窗内各题行的 Checkbox（不含列表顶栏的“全选”三态框，
/// B9-2：全选框 `tristate == true`，行内框是默认 `false`）。
Finder popupCheckboxes(WidgetTester tester) => find.descendant(
      of: find.byKey(const Key('organize-queue-popup')),
      matching: find.byWidgetPredicate(
        (w) => w is Checkbox && w.tristate != true,
      ),
    );

/// B6-P1 SR2-26：写库失败模拟——`failSave` 打开后 `save` 一律抛错，
/// 其余调用仍走内存假实现。开关留在测试手里：先正常打开队列、再
/// 打开失败，分别覆盖 `_openQueue` 与 `_jumpToQuestion` /
/// `_applyQueueSort` 的失败路径。
class FailingSaveRepo extends FakeOrganizeRepo {
  FailingSaveRepo(FakeOrganizeRepo base)
      : super(
          questions: base.questions,
          folderList: base.folderList,
          examList: base.examList,
          kpList: base.kpList,
          tagList: base.tagList,
          subjectsValue: base.subjectsValue,
        );

  bool failSave = false;

  @override
  Future<void> save(Question question) async {
    if (failSave) throw StateError('模拟写库失败');
    return super.save(question);
  }
}

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

    testWidgets('B7：确认整理后最近任务 kind 记中文“整理”', (tester) async {
      final repo = threeQuestionRepo();
      await pumpOrganize(tester, repo: repo);
      await tester.tap(find.text('试卷').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('确认整理，去下一道'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认整理，去下一道'));
      await tester.pumpAndSettle();
      expect(repo.lastRecentKind, '整理');
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

    testWidgets('修框切片默认展开：只有整题一张卡', (tester) async {
      await pumpOrganize(tester);
      expect(find.text('修框切片'), findsOneWidget);
      expect(find.text('整题框切片'), findsOneWidget);
      expect(find.text('题干框切片'), findsNothing);
      expect(find.text('选项框切片'), findsNothing);
      expect(find.text('配图框切片'), findsNothing);
      expect(find.text('切片图'), findsWidgets);
    });

    testWidgets('放大浮层：点图弹出、纸面居中完整可见、带比例 pill，关闭回到整理台',
        (tester) async {
      await pumpOrganize(tester);
      await tester.tap(find.byType(QuestionSlice));
      await tester.pumpAndSettle();
      expect(find.text('整题图 · 放大查看'), findsOneWidget);
      // S8A1：初始缩放不再是写死的 1.5×，而是 min(1.5, fit)。
      // 1280×720 下视口 900 宽、纸面封顶 680 宽，fit=900/680≈1.32，
      // 徽标 132%。纸面渲染中心须与视口中心重合（±3px），且整张
      // 纸面在视口内（无裁切）。
      expect(find.text('132%'), findsOneWidget);
      final paperRect = tester.getRect(find.descendant(
          of: find.byType(Dialog), matching: find.byType(QuestionSlice)));
      final viewerRect = tester.getRect(find.byType(InteractiveViewer));
      final viewerCenter = tester.getCenter(find.byType(InteractiveViewer));
      expect((paperRect.center.dx - viewerCenter.dx).abs(), lessThan(3));
      expect((paperRect.center.dy - viewerCenter.dy).abs(), lessThan(3));
      // 整张纸面在视口内（无裁切；Rect.contains 右/下边是开区间，
      // 渲染宽恰等于视口宽时会贴边，故用 ±1px 容差逐边比）。
      expect(paperRect.left, greaterThanOrEqualTo(viewerRect.left - 1));
      expect(paperRect.right, lessThanOrEqualTo(viewerRect.right + 1));
      expect(paperRect.top, greaterThanOrEqualTo(viewerRect.top - 1));
      expect(paperRect.bottom, lessThanOrEqualTo(viewerRect.bottom + 1));
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
      expect(find.text('批量打标签'), findsOneWidget);
      expect(find.text('批量确认整理'), findsOneWidget);
      expect(find.text('批量删除'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.textContaining('批量操作 · 已选'), findsNothing);
    });

    testWidgets('批量打标签（默认需重做）', (tester) async {
      final repo = threeQuestionRepo();
      await pumpOrganize(tester, repo: repo);
      await openQueue(tester);
      await tester.tap(popupCheckboxes(tester).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量打标签'));
      await tester.pumpAndSettle();
      expect(
        repo.saved.any(
          (x) => x.id == 'q1' && x.tags.contains('需重做'),
        ),
        isTrue,
      );
      expect(find.textContaining('已给 1 道题打上 #需重做'), findsOneWidget);
    });

    testWidgets('SR3-15：批量打标签中途写库失败，已保存题的标签仍在快照里、后续批量加文件夹不丢',
        (tester) async {
      final repo = threeQuestionRepo();
      repo.failSaveIds.add('q2');
      await pumpOrganize(tester, repo: repo);
      await openQueue(tester);
      // 勾选前两道（时间降序：q1、q2）；q2 的 save 会抛错。
      await tester.tap(popupCheckboxes(tester).first);
      await tester.pumpAndSettle();
      await tester.tap(popupCheckboxes(tester).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量打标签'));
      await tester.pumpAndSettle();
      // 部分失败提示出现，异常没逃出按钮回调。
      expect(find.textContaining('部分保存失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // 第一题已落盘。
      expect(
        repo.saved.any((x) => x.id == 'q1' && x.tags.contains('需重做')),
        isTrue,
      );
      // 后续批量加文件夹：文件夹下拉默认已选中首个文件夹（f1“试卷”），
      // 直接点加入——保存用的是弹窗快照里的行，q1 的标签应还在。
      repo.failSaveIds.clear();
      await tester.tap(find.text('批量加入该文件夹'));
      await tester.pumpAndSettle();
      // 加文件夹的保存用的是弹窗快照里的行：q1 的标签还在。
      final q1 = repo.saved.lastWhere((x) => x.id == 'q1');
      expect(q1.tags, contains('需重做'));
      expect(q1.folderIds, contains('f1'));
      expect(tester.takeException(), isNull);
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

  group('SR-P1-7 打开队列前保存当前表单', () {
    /// 改当前题表单：选文件夹「平时作业」+ 填答案。只改表单 state，
    /// 不点保存/确认——复现报告里的丢改动路径。
    Future<void> editCurrentForm(WidgetTester tester) async {
      await tester.ensureVisible(find.text('平时作业').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('平时作业').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('答案 · 解析 · 笔记（可选）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('答案 · 解析 · 笔记（可选）'));
      await tester.pumpAndSettle();
      final answerField = find.byWidgetPredicate(
        (w) =>
            w is TextField && w.decoration?.hintText == '还没想好可留空',
      );
      await tester.enterText(answerField, '答案：1');
      await tester.pumpAndSettle();
      // 填答案时页面滚到底了，顶栏「队列」按钮已滚出视口，先滚回去。
      await tester.ensureVisible(find.text('队列'));
      await tester.pumpAndSettle();
    }

    testWidgets('打开队列前改动已落盘（还没做批量操作）', (tester) async {
      final repo = threeQuestionRepo();
      await pumpOrganize(tester, repo: repo);
      await editCurrentForm(tester);
      // 改动只在表单 state，还没落盘。
      expect(repo.saved, isEmpty);
      await openQueue(tester);
      final saved = repo.saved.where((x) => x.id == 'q1').toList();
      expect(saved, isNotEmpty);
      expect(saved.last.folderIds, contains('f2'));
      expect(saved.last.answer, '答案：1');
    });

    testWidgets('批量打标签后，打开队列前的表单改动仍在', (tester) async {
      final repo = threeQuestionRepo();
      await pumpOrganize(tester, repo: repo);
      await editCurrentForm(tester);
      await openQueue(tester);
      await tester.tap(popupCheckboxes(tester).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量打标签'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭 ×'));
      await tester.pumpAndSettle();
      final q1 = repo.questions.firstWhere((x) => x.id == 'q1');
      expect(q1.tags, contains('需重做'));
      expect(q1.folderIds, contains('f2'));
      expect(q1.answer, '答案：1');
      // 关队列回来，表单里仍是改动后的值（不是打开前的旧快照）。
      expect(find.textContaining('本题必填已齐'), findsOneWidget);
    });

    testWidgets('批量确认整理后，打开队列前的表单改动仍在', (tester) async {
      final repo = threeQuestionRepo();
      await pumpOrganize(tester, repo: repo);
      await editCurrentForm(tester);
      await openQueue(tester);
      await tester.tap(popupCheckboxes(tester).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量确认整理'));
      await tester.pumpAndSettle();
      final q1 = repo.questions.firstWhere((x) => x.id == 'q1');
      expect(q1.isOrganized, isTrue);
      expect(q1.folderIds, contains('f2'));
      expect(q1.answer, '答案：1');
      expect(find.text('还剩 2 道'), findsOneWidget);
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

  group('P1-1 二层切片已移除（B8-2）', () {
    testWidgets('真实题（空 sliceText）：不显示 region 开关，只留整题切片', (
      tester,
    ) async {
      await pumpOrganize(
        tester,
        repo: FakeOrganizeRepo(
          questions: [
            q('qr', '真实题', sliceText: '', sliceKind: 'limit'),
          ],
          folderList: const [
            Folder(id: 'f1', name: '试卷', subjectId: 'math'),
          ],
        ),
      );
      expect(find.text('stem 题干'), findsNothing);
      expect(find.text('option 选项'), findsNothing);
      expect(find.text('figure 插图'), findsNothing);
      expect(find.text('区域仅作辅助定位，整题图始终是主体'), findsNothing);
      expect(find.byType(Checkbox), findsNothing);
      // 只留整题切片一张卡，题干 / 选项 / 配图卡不出现。
      expect(find.text('修框切片'), findsOneWidget);
      expect(find.text('整题框切片'), findsOneWidget);
      expect(find.text('题干框切片'), findsNothing);
      expect(find.text('选项框切片'), findsNothing);
      expect(find.text('配图框切片'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('B6-P1 队列快照（SR2-5 / SR2-6 / SR2-26）', () {
    /// 与 SR-P1-7 组同款：改当前题表单（选文件夹「平时作业」+ 填答案），
    /// 只改表单 state，不点保存/确认。
    Future<void> editCurrentForm(WidgetTester tester) async {
      await tester.ensureVisible(find.text('平时作业').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('平时作业').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('答案 · 解析 · 笔记（可选）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('答案 · 解析 · 笔记（可选）'));
      await tester.pumpAndSettle();
      final answerField = find.byWidgetPredicate(
        (w) =>
            w is TextField && w.decoration?.hintText == '还没想好可留空',
      );
      await tester.enterText(answerField, '答案：1');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('队列'));
      await tester.pumpAndSettle();
    }

    testWidgets('SR2-5：同一弹窗内打标签 → 加文件夹 → 关闭，标签与文件夹都在',
        (tester) async {
      final repo = threeQuestionRepo();
      await pumpOrganize(tester, repo: repo);
      await openQueue(tester);
      await tester.tap(popupCheckboxes(tester).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量打标签'));
      await tester.pumpAndSettle();
      // 批量加文件夹默认选中本科第一个文件夹「试卷」(f1)。
      await tester.tap(find.text('批量加入该文件夹'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭 ×'));
      await tester.pumpAndSettle();
      final q1 = repo.questions.firstWhere((x) => x.id == 'q1');
      expect(q1.tags, contains('需重做'));
      expect(q1.folderIds, contains('f1'));
    });

    testWidgets('SR2-5：同一弹窗内加文件夹 → 打标签 → 批量确认，标签与文件夹都在',
        (tester) async {
      final repo = threeQuestionRepo();
      await pumpOrganize(tester, repo: repo);
      await openQueue(tester);
      await tester.tap(popupCheckboxes(tester).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量加入该文件夹'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量打标签'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量确认整理'));
      await tester.pumpAndSettle();
      final q1 = repo.questions.firstWhere((x) => x.id == 'q1');
      expect(q1.isOrganized, isTrue);
      expect(q1.tags, contains('需重做'));
      expect(q1.folderIds, contains('f1'));
      expect(find.text('还剩 2 道'), findsOneWidget);
    });

    testWidgets('SR2-6：改表单 → 下一道 → 上一道 → 保存草稿，文件夹与答案仍在',
        (tester) async {
      final repo = threeQuestionRepo();
      await pumpOrganize(tester, repo: repo);
      await editCurrentForm(tester);
      await tester.ensureVisible(find.text('下一道'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一道'));
      await tester.pumpAndSettle();
      expect(find.textContaining('数学 · 导数综合'), findsOneWidget);
      await tester.ensureVisible(find.text('上一道'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('上一道'));
      await tester.pumpAndSettle();
      expect(find.textContaining('数学 · 函数极限'), findsOneWidget);
      // 切回来后表单仍是改动后的值（不是打开前的旧快照）。
      expect(find.textContaining('本题必填已齐'), findsOneWidget);
      await tester.ensureVisible(find.text('保存草稿'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存草稿'));
      await tester.pumpAndSettle();
      expect(find.text('草稿已保存'), findsOneWidget);
      final saves = repo.saved.where((x) => x.id == 'q1').toList();
      expect(saves, isNotEmpty);
      expect(saves.last.folderIds, contains('f2'));
      expect(saves.last.answer, '答案：1');
    });

    testWidgets('SR2-26：打开队列时保存失败，弹提示且队列打不开',
        (tester) async {
      final repo = FailingSaveRepo(threeQuestionRepo())..failSave = true;
      await pumpOrganize(tester, repo: repo);
      await tester.tap(find.text('队列'));
      await tester.pumpAndSettle();
      expect(find.text('保存失败，请重试'), findsOneWidget);
      expect(find.text('待整理队列 · 3 道'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('SR2-26：切题时保存失败，弹提示且留在当前题', (tester) async {
      final repo = FailingSaveRepo(threeQuestionRepo())..failSave = true;
      await pumpOrganize(tester, repo: repo);
      await tester.ensureVisible(find.text('下一道'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一道'));
      await tester.pumpAndSettle();
      expect(find.text('保存失败，请重试'), findsOneWidget);
      expect(find.textContaining('数学 · 函数极限'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('SR2-26：队列内跳转时保存失败，弹提示且留在当前题',
        (tester) async {
      final repo = FailingSaveRepo(threeQuestionRepo());
      await pumpOrganize(tester, repo: repo);
      await openQueue(tester);
      repo.failSave = true;
      await tester.tap(find.text('导数综合'));
      await tester.pumpAndSettle();
      expect(find.text('保存失败，请重试'), findsOneWidget);
      expect(find.text('待整理队列 · 3 道'), findsNothing);
      expect(find.textContaining('数学 · 函数极限'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('SR2-26：队列内改排序时保存失败，弹提示且主队列排序不变',
        (tester) async {
      final repo = FailingSaveRepo(threeQuestionRepo());
      await pumpOrganize(tester, repo: repo);
      await openQueue(tester);
      repo.failSave = true;
      await tester.tap(find.text('时间降序'));
      await tester.pumpAndSettle();
      // B9-2：排序下拉已改内联菜单（SR3-15 根因修复），菜单项真实
      // 点按可选中，不再走键盘绕路。
      await tester.tap(find.text('时间升序'));
      await tester.pumpAndSettle();
      expect(find.text('保存失败，请重试'), findsOneWidget);
      expect(find.text('待整理队列 · 3 道'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // 恢复写库后关掉重开：父页排序仍是时间降序（q1 在上）。
      repo.failSave = false;
      await tester.tap(find.text('关闭 ×'));
      await tester.pumpAndSettle();
      await openQueue(tester);
      final y1 = tester.getTopLeft(find.text('函数极限')).dy;
      final y3 = tester.getTopLeft(find.text('阅读主旨')).dy;
      expect(y1, lessThan(y3));
    });

    testWidgets('SR2-26（对照）：队列内改排序保存成功时，主队列按新排序重排',
        (tester) async {
      final repo = FailingSaveRepo(threeQuestionRepo());
      await pumpOrganize(tester, repo: repo);
      await openQueue(tester);
      await tester.tap(find.text('时间降序'));
      await tester.pumpAndSettle();
      // B9-2：同上，内联菜单真实点按。
      await tester.tap(find.text('时间升序'));
      await tester.pumpAndSettle();
      // 队列内已按时间升序重排：q3（11/3）在上，q1（11/8）在下。
      final y1 = tester.getTopLeft(find.text('函数极限')).dy;
      final y3 = tester.getTopLeft(find.text('阅读主旨')).dy;
      expect(y3, lessThan(y1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('SR2-26：保存草稿失败时提示失败，不谎报已保存',
        (tester) async {
      final repo = FailingSaveRepo(threeQuestionRepo())..failSave = true;
      await pumpOrganize(tester, repo: repo);
      await tester.ensureVisible(find.text('保存草稿'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存草稿'));
      await tester.pumpAndSettle();
      expect(find.text('保存失败，请重试'), findsOneWidget);
      expect(find.text('草稿已保存'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('B9-2 队列批量操作：全选 / 可选标签 / 内联下拉', () {
    Finder popupText(String text) => find.descendant(
          of: find.byKey(const Key('organize-queue-popup')),
          matching: find.text(text),
        );

    testWidgets('全选：点全选勾上全部、批量条计数对；再点取消全选', (tester) async {
      await pumpOrganize(tester);
      await openQueue(tester);
      expect(find.text('已选 0 / 共 3 道'), findsOneWidget);
      expect(find.textContaining('批量操作 · 已选'), findsNothing);
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('批量操作 · 已选 3 道'), findsOneWidget);
      expect(find.text('已选 3 / 共 3 道'), findsOneWidget);
      final boxes = popupCheckboxes(tester);
      expect(boxes.evaluate().length, 3);
      for (var i = 0; i < 3; i++) {
        expect(tester.widget<Checkbox>(boxes.at(i)).value, isTrue);
      }
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.textContaining('批量操作 · 已选'), findsNothing);
      for (var i = 0; i < 3; i++) {
        expect(tester.widget<Checkbox>(boxes.at(i)).value, isFalse);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('全选范围是当前筛选：搜到 1 道时全选只勾那 1 道，筛外已选保留',
        (tester) async {
      await pumpOrganize(tester);
      await openQueue(tester);
      final searchField = find.byWidgetPredicate(
        (w) =>
            w is TextField && w.decoration?.hintText == '搜题名、学科、试卷',
      );
      await tester.enterText(searchField, '函数');
      await tester.pumpAndSettle();
      expect(find.textContaining('搜到 1 道'), findsOneWidget);
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('批量操作 · 已选 1 道'), findsOneWidget);
      // 清掉搜索：q1 的勾保留，q2/q3 没勾，全选框呈部分选（三态 null）。
      await tester.enterText(searchField, '');
      await tester.pumpAndSettle();
      expect(find.text('已选 1 / 共 3 道'), findsOneWidget);
      final selectAllBox = find.descendant(
        of: find.byKey(const Key('organize-queue-popup')),
        matching: find.byWidgetPredicate(
          (w) => w is Checkbox && w.tristate == true,
        ),
      );
      expect(tester.widget<Checkbox>(selectAllBox).value, isNull);
      // 再搜“导数”全选：q2 加进来，q1 保留。
      await tester.enterText(searchField, '导数');
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('批量操作 · 已选 2 道'), findsOneWidget);
      // 清搜索后全选补上 q3 成 3 道；再点一次全清。
      await tester.enterText(searchField, '');
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('批量操作 · 已选 3 道'), findsOneWidget);
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.textContaining('批量操作 · 已选'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('批量打标签可选：下拉选预设标签落库，打完不清空选中',
        (tester) async {
      final repo = threeQuestionRepo();
      await pumpOrganize(tester, repo: repo);
      await openQueue(tester);
      await tester.tap(popupCheckboxes(tester).first);
      await tester.pumpAndSettle();
      // 标签字段默认 '#需重做'；改选预设 '易错'。
      await tester.tap(find.text('#需重做'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('#易错'));
      await tester.pumpAndSettle();
      expect(find.text('#易错'), findsOneWidget);
      await tester.tap(find.text('批量打标签'));
      await tester.pumpAndSettle();
      expect(
        repo.saved.any((x) => x.id == 'q1' && x.tags.contains('易错')),
        isTrue,
      );
      expect(find.textContaining('已给 1 道题打上 #易错'), findsOneWidget);
      // 打完不清空选中（与批量加文件夹一致）。
      expect(find.text('批量操作 · 已选 1 道'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('批量打标签可选：下拉选自定义标签落库', (tester) async {
      final repo = threeQuestionRepo();
      repo.tagList = ['易错', '常考', '期末重点'];
      await pumpOrganize(tester, repo: repo);
      await openQueue(tester);
      await tester.tap(popupCheckboxes(tester).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('#需重做'));
      await tester.pumpAndSettle();
      // 预设在前、自定义在后：菜单里三预设与自定义都在。
      expect(find.text('#易错'), findsOneWidget);
      expect(find.text('#期末重点'), findsOneWidget);
      await tester.tap(find.text('#期末重点'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量打标签'));
      await tester.pumpAndSettle();
      expect(
        repo.saved.any((x) => x.id == 'q1' && x.tags.contains('期末重点')),
        isTrue,
      );
      expect(find.textContaining('已给 1 道题打上 #期末重点'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('SR3-15 文件夹下拉：真实点按选平时作业，菜单关闭且值生效',
        (tester) async {
      final repo = threeQuestionRepo();
      await pumpOrganize(tester, repo: repo);
      await openQueue(tester);
      await tester.tap(popupCheckboxes(tester).first);
      await tester.pumpAndSettle();
      // 文件夹字段默认 '试卷'；点开菜单、真实点按选 '平时作业'。
      await tester.tap(popupText('试卷'));
      await tester.pumpAndSettle();
      expect(find.text('＋ 添加新文件夹…'), findsOneWidget);
      await tester.tap(find.text('平时作业').last);
      await tester.pumpAndSettle();
      // 菜单关闭、值生效（字段显示 '平时作业'）。
      expect(find.text('＋ 添加新文件夹…'), findsNothing);
      expect(popupText('平时作业'), findsOneWidget);
      await tester.tap(find.text('批量加入该文件夹'));
      await tester.pumpAndSettle();
      expect(
        repo.saved.any(
          (x) => x.id == 'q1' && x.folderIds.contains('f2'),
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('SR3-15 文件夹下拉：真实点按“添加新文件夹”打开新建表单',
        (tester) async {
      await pumpOrganize(tester);
      await openQueue(tester);
      await tester.tap(popupCheckboxes(tester).first);
      await tester.pumpAndSettle();
      await tester.tap(popupText('试卷'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('＋ 添加新文件夹…'));
      await tester.pumpAndSettle();
      expect(find.text('＋ 添加新文件夹…'), findsNothing);
      expect(find.text('添加新文件夹'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Esc 先关内联菜单，不关队列', (tester) async {
      await pumpOrganize(tester);
      await openQueue(tester);
      await tester.tap(popupCheckboxes(tester).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('#需重做'));
      await tester.pumpAndSettle();
      expect(find.text('#易错'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('#易错'), findsNothing);
      expect(find.text('待整理队列 · 3 道'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄窗口 480：全选后批量条无溢出，标签菜单能打开',
        (tester) async {
      await pumpOrganize(tester, viewSize: const Size(480, 720));
      await openQueue(tester);
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('批量操作 · 已选 3 道'), findsOneWidget);
      await tester.tap(find.text('#需重做'));
      await tester.pumpAndSettle();
      expect(find.text('#易错'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
