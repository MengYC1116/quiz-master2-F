// 十九批 A（D-223）：详情页右栏跳转接线——整应用（内存库）验证。
//
// 「全部 ›」经 `_goWrongbookFiltered(cause:)` 落到按错因筛选的列表；
// 「打开列表 ›」经 `_goWrongbookFiltered(folderId: + subjectId:)` 落到
// 该文件夹的列表；普通导航（左导航点「错题本」）后 `_folderArg` 已清，
// 下次进错题本不再带文件夹筛选。
//
// 用真实内存库 + 整应用 `QuizMasterApp`（同
// b8_1_subject_refresh_flow_test 的 pump 方式：`openForTest` +
// `useDatabaseForTest` + `_pumpUntil`，不用 `pumpAndSettle`）；
// 播种在测试体内做。种子：q1/q6/q7 同错因（概念不清），q1 与 q3
// 同文件夹（f1 试卷）；各题不带知识点（无同知识点组，右栏只出
// 一个「全部 ›」）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/app.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/detail/question_detail_page.dart';
import 'package:quiz_master2/modules/review/review_page.dart';

/// 左导航栏本体的 key（见 b8_1_subject_refresh_flow_test）。
final _navBar = find.byKey(const ValueKey('qm-nav-bar'));

/// 导航栏内的某段文字。
Finder _navText(String text) =>
    find.descendant(of: _navBar, matching: find.text(text));

/// 板子行标题是 RichText（不是普通 Text）：按题名找行。
Finder _boardRow(String title) =>
    find.textContaining(title, findRichText: true);

/// 有界手动 pump（同 b8_1_subject_refresh_flow_test）：整应用
/// `pumpAndSettle` 永不静止，pump 看条件 + 真实异步等一轮延时。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  int maxRounds = 40,
}) async {
  for (var i = 0; i < maxRounds; i++) {
    await tester.pump();
    if (condition()) return;
    // 推进假时间：pop / 滚动动画靠它走（无时长 pump 不推进假时间，
    // 300ms 的 pop 动画会永远卡在起点）；再给真实异步 I/O 留时间。
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) return;
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    if (condition()) return;
  }
  fail('界面未稳定：$reason');
}

Future<void> _seed() async {
  final db = await AppDatabase.openForTest();
  AppDatabase.useDatabaseForTest(db);
  final repo = QuestionRepository(AppDatabase.instance);
  for (final s in Subject.all) {
    await repo.saveSubject(s);
  }
  for (final f in const [
    Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
    Folder(id: 'f2', name: '平时作业', subjectId: 'math', sortOrder: 10),
    Folder(id: 'f3', name: '试卷', subjectId: 'english', sortOrder: 0),
  ]) {
    await repo.saveFolder(f);
  }
  Question q(
    String id,
    String title, {
    required String subjectId,
    required List<String> folderIds,
    required List<String> errorTypes,
    required DateTime createdAt,
  }) =>
      Question(
        id: id,
        title: title,
        subjectId: subjectId,
        folderIds: folderIds,
        errorTypes: errorTypes,
        isOrganized: true,
        createdAt: createdAt,
      );
  for (final question in [
    q(
      'q1',
      '函数极限',
      subjectId: 'math',
      folderIds: const ['f1'],
      errorTypes: const ['概念不清'],
      createdAt: DateTime(2026, 11, 6),
    ),
    q(
      'q6',
      '洛必达法则',
      subjectId: 'math',
      folderIds: const ['f2'],
      errorTypes: const ['概念不清'],
      createdAt: DateTime(2026, 11, 5),
    ),
    q(
      // 第二道同错因题：右栏「全部 ›」只在同错因其他题 ≥2 道时才出
      //（`items.length > 1` 才画汇总行），只给一道时点不出来。
      'q7',
      '泰勒公式',
      subjectId: 'math',
      folderIds: const ['f2'],
      errorTypes: const ['概念不清'],
      createdAt: DateTime(2026, 11, 4),
    ),
    q(
      'q2',
      '导数综合',
      subjectId: 'math',
      folderIds: const ['f2'],
      errorTypes: const ['方法不会'],
      createdAt: DateTime(2026, 11, 7),
    ),
    q(
      'q3',
      '定积分',
      subjectId: 'math',
      folderIds: const ['f1'],
      errorTypes: const ['计算错误'],
      createdAt: DateTime(2026, 11, 8),
    ),
    q(
      'q4',
      '阅读主旨',
      subjectId: 'english',
      folderIds: const ['f3'],
      errorTypes: const ['审题失误'],
      createdAt: DateTime(2026, 11, 9),
    ),
    q(
      'q5',
      '图表作文',
      subjectId: 'english',
      folderIds: const ['f3'],
      errorTypes: const ['方法不会'],
      createdAt: DateTime(2026, 11, 10),
    ),
  ]) {
    await repo.save(question);
  }
  addTearDown(() async {
    await AppDatabase.resetForTest();
  });
}

Future<void> _pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(const ProviderScope(child: QuizMasterApp()));
  await _pumpUntil(
    tester,
    () => find.text('快速收集').evaluate().isNotEmpty,
    reason: '首页未加载',
  );
}

/// 首页 → 错题本 → 点 q1 行进详情，停在详情页右栏可见处。
/// 二十三批 D-250：导航进错题本先落书架，点「数学」封面进目录、
/// 点「全部题目」进列表，再点行（十九批 A5“直接落列表”已废）。
Future<void> _openQ1Detail(WidgetTester tester) async {
  await tester.tap(_navText('错题本'));
  await _pumpUntil(
    tester,
    () =>
        find
            .text('一科一本错题本，点一本打开看这一科的错题。')
            .evaluate()
            .isNotEmpty,
    reason: '错题本未落到书架',
  );
  // 整应用里「数学」出现两次（左导航学科速览 13.5px + 书架封面
  // 38px 大字）：点封面按 38px 大字定位，左导航那行点不到封面。
  // 二十六批 D-256：封面学科名由 52px 改 38px（板子 12 号值）。
  await tester.tap(
    find.byWidgetPredicate(
      (w) =>
          w is Text &&
          w.data == '数学' &&
          w.style?.fontSize == 38,
    ),
  );
  await _pumpUntil(
    tester,
    () => find.text('全部题目').evaluate().isNotEmpty,
    reason: '错题本未落到数学目录',
  );
  await tester.tap(find.text('全部题目'));
  await _pumpUntil(
    tester,
    () => _boardRow('函数极限').evaluate().isNotEmpty,
    reason: '错题本列表未加载',
  );
  await tester.tap(_boardRow('函数极限'));
  await _pumpUntil(
    tester,
    () => find.text('全部 ›').evaluate().isNotEmpty,
    reason: '详情页右栏未加载',
  );
}

/// 点详情页右栏跳转入口：ensureVisible 的滚动动画要多 pump 几帧等它
/// 跑完再点，否则点按会被滚动吃掉（B 测试用 pumpAndSettle，整应用测
/// 不能用它——应用永不静止）。只 pump 一次就点时回调根本不会触发。
Future<void> _tapJumpEntry(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  await tester.tap(find.text(label));
}

void main() {
  group('十九批 A：详情页右栏跳转接线', () {
    testWidgets('「全部 ›」经 _goWrongbookFiltered(cause:) 落到按错因筛选的列表',
        (tester) async {
      await _seed();
      await _pumpApp(tester);
      await _openQ1Detail(tester);
      await _tapJumpEntry(tester, '全部 ›');
      // 详情被 pop，底层重挂载为按错因筛选的列表：同错因的 q1/q6/q7
      // 在，不同错因的 q2/q3 不在；结果头标题带错因名。
      await _pumpUntil(
        tester,
        () =>
            find.text('全部 ›').evaluate().isEmpty &&
            _boardRow('洛必达法则').evaluate().isNotEmpty,
        reason: '点「全部 ›」后未落到按错因筛选的列表',
      );
      expect(_boardRow('函数极限'), findsOneWidget);
      expect(_boardRow('洛必达法则'), findsOneWidget);
      expect(_boardRow('泰勒公式'), findsOneWidget);
      expect(_boardRow('导数综合'), findsNothing);
      expect(_boardRow('定积分'), findsNothing);
      expect(find.text('「概念不清」的结果'), findsOneWidget);
    });

    testWidgets('「打开列表 ›」经 _goWrongbookFiltered(folderId:+subjectId:) 落到该文件夹的列表',
        (tester) async {
      await _seed();
      await _pumpApp(tester);
      await _openQ1Detail(tester);
      await _tapJumpEntry(tester, '打开列表 ›');
      // 详情被 pop，底层重挂载为 f1 的列表：f1 的 q1/q3 在，
      // f2 的 q2/q6 不在；二十三批 D-250 页头恢复后，文件夹范围
      // 以页头标题「数学 · 试卷」呈现，标题断言即证明落到了该文件夹的列表。
      await _pumpUntil(
        tester,
        () =>
            find.text('打开列表 ›').evaluate().isEmpty &&
            _boardRow('定积分').evaluate().isNotEmpty,
        reason: '点「打开列表 ›」后未落到该文件夹的列表',
      );
      expect(_boardRow('函数极限'), findsOneWidget);
      expect(_boardRow('定积分'), findsOneWidget);
      expect(_boardRow('导数综合'), findsNothing);
      expect(_boardRow('洛必达法则'), findsNothing);
      expect(find.text('数学 · 试卷'), findsOneWidget);
    });

    testWidgets('普通导航后 _folderArg 已清：下次进错题本不再带文件夹筛选',
        (tester) async {
      await _seed();
      await _pumpApp(tester);
      await _openQ1Detail(tester);
      await _tapJumpEntry(tester, '打开列表 ›');
      await _pumpUntil(
        tester,
        () =>
            find.text('打开列表 ›').evaluate().isEmpty &&
            _boardRow('定积分').evaluate().isNotEmpty,
        reason: '点「打开列表 ›」后未落到该文件夹的列表',
      );
      expect(_boardRow('导数综合'), findsNothing);
      // 左导航点「错题本」是普通导航：清 _folderArg，重挂载后
      // 不再带文件夹筛选；二十三批 D-250：普通导航落书架（不再是
      // 无筛选列表），再经目录进数学列表，f2 的题也回来了。
      await tester.tap(_navText('错题本'));
      await _pumpUntil(
        tester,
        () =>
            find
                .text('一科一本错题本，点一本打开看这一科的错题。')
                .evaluate()
                .isNotEmpty,
        reason: '普通导航后未回到书架',
      );
      await tester.tap(
        find.byWidgetPredicate(
          (w) =>
              w is Text && w.data == '数学' && w.style?.fontSize == 38,
        ),
      );
      await _pumpUntil(
        tester,
        () => find.text('全部题目').evaluate().isNotEmpty,
        reason: '普通导航后未落到数学目录',
      );
      await tester.tap(find.text('全部题目'));
      await _pumpUntil(
        tester,
        () => _boardRow('导数综合').evaluate().isNotEmpty,
        reason: '普通导航后未回到无筛选的列表',
      );
      expect(_boardRow('函数极限'), findsOneWidget);
      expect(_boardRow('洛必达法则'), findsOneWidget);
      expect(_boardRow('泰勒公式'), findsOneWidget);
      expect(_boardRow('定积分'), findsOneWidget);
      expect(find.text('全部题目'), findsOneWidget);
    });

    // Win11 反馈：详情页「复习记录」空状态的「去复习」点了没反应——详情
    // 压在根 Navigator 栈顶，只改底层路由不 pop，用户看到的仍是详情。
    testWidgets('详情页「去复习」：详情出栈并落到复习页', (tester) async {
      await _seed();
      await _pumpApp(tester);
      await _openQ1Detail(tester);
      expect(find.byType(QuestionDetailPage), findsOneWidget);
      await _tapJumpEntry(tester, '去复习');
      // 详情被 pop，底层切到复习页（不能只断言回调被调到）。
      await _pumpUntil(
        tester,
        () => find.byType(ReviewPage).evaluate().isNotEmpty,
        reason: '点「去复习」后未落到复习页',
      );
      await _pumpUntil(
        tester,
        () => find.byType(QuestionDetailPage).evaluate().isEmpty,
        reason: '点「去复习」后详情页仍在栈顶',
      );
      expect(
        find.text('暂无复习记录，去复习页练一次会出现在这里'),
        findsNothing,
      );
    });
  });
}
