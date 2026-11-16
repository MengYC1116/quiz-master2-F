// B8-1 真实交互用例（父任务补充要求）：不要只验逻辑，要真实走一遍交互。
//
// 用真实内存库（`AppDatabase.openForTest()`，只建表不播种、不碰真实库、
// 无文件 IO）+ 整应用 `QuizMasterApp`，按 Meng 真机验收的操作顺序：
// 学科管理页点“删除”→ 模态确认 → 删光三科 → 实际检查左导航速览、
// 收集下拉、错题本书架、首页四处界面上真的没了已删学科。
//
// 断言只看界面（`find.text` / 下拉提示 / 空状态），不读数据库断言
// 通过；库里空了只是辅助 sanity（最后一行）。
// 整应用 `pumpAndSettle` 永不静止（见 `s8b3_startup_test.dart` 文件头），
// 这里用有界手动 pump（`_pumpUntil`：pump 看条件 + `runAsync` 切回
// 真实异步等一轮延时 + 再 pump 渲染）等界面稳定，不用 pumpAndSettle。
// Drift 走同步 sqlite3 调用，仓库方法在 widget 测试里直接 await
// 即可；`tester.runAsync` 只用于 Future.delayed 这类真实延时。
// 注意：播种必须在测试体内做——setUp 跑在 fake async 区之外，
// setUp 里打开的库在测试体里 await 仓库方法会挂住（B Stage 1
// 探针 11/12/13）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/app.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';

/// 左导航栏本体的 key（`AppNavBar` 根 Container），断言只圈导航内，
/// 避免与内容页同名文字混淆（学科管理页本身也显示学科名）。
final _navBar = find.byKey(const ValueKey('qm-nav-bar'));

/// 导航栏内的某段文字。
Finder _navText(String text) =>
    find.descendant(of: _navBar, matching: find.text(text));

/// 有界手动 pump：每轮先 pump 一帧看条件，再切回真实异步等一轮、
/// 再 pump 渲染，直到条件成立或超限失败。
/// 不用 pumpAndSettle（整应用永不静止）；也不只用 `pump(Duration)`——
/// `runAsync` 在这里只等真实延时（Future.delayed），数据库读写走
/// Drift 同步调用、直接 await（见文件头）。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  int maxRounds = 30,
}) async {
  for (var i = 0; i < maxRounds; i++) {
    await tester.pump();
    if (condition()) return;
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    if (condition()) return;
  }
  fail('界面未稳定：$reason');
}

/// 点左导航某项（只圈导航栏内，避免与内容页同名标题混淆）。
Future<void> _goNav(WidgetTester tester, String label) async {
  await tester.tap(_navText(label));
}

/// 找到某学科行内的“删除”按钮：按钮的某个祖先 Row 里同时含该学科名。
/// 导航速览行里没有“删除”按钮，所以不会误挑导航里的同名行。
Finder _deleteButtonFor(String name) {
  final deletes = find.text('删除');
  for (var i = 0; i < deletes.evaluate().length; i++) {
    final btn = deletes.at(i);
    final rows = find.ancestor(of: btn, matching: find.byType(Row));
    for (final row in rows.evaluate()) {
      final inRow = find.descendant(
        of: find.byWidget(row.widget),
        matching: find.text(name),
      );
      if (inRow.evaluate().isNotEmpty) return btn;
    }
  }
  return find.text('__b8_1_no_such_delete_button__');
}

/// 在学科管理页真实删掉一科：点行内“删除”→ 模态确认 → 点确认删除。
/// 删完等到导航速览里该科消失（变更事件驱动的角标刷新已落地），
/// 再继续下一步——不断言数据库，只断言界面。
Future<void> _deleteSubjectViaUi(WidgetTester tester, String name) async {
  final btn = _deleteButtonFor(name);
  expect(btn, findsOneWidget, reason: '找不到 $name 行内的删除按钮');
  await tester.ensureVisible(btn);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(btn);
  await _pumpUntil(
    tester,
    () => find.text('删除学科「$name」，确定吗？').evaluate().isNotEmpty,
    reason: '删除确认弹窗未出现：$name',
  );
  // 空库删科：题数为 0，确认按钮文案含“全部 0 道题”。
  await tester.tap(find.text('确认删除这一科和全部 0 道题'));
  await _pumpUntil(
    tester,
    () => _navText(name).evaluate().isEmpty,
    reason: '删掉 $name 后导航速览里仍有它',
  );
}

void main() {
  // 播种必须在测试体内做（见文件头）：setUp 在 fake async 区之外。
  Future<QuestionRepository> seedB() async {
    // 真实内存库：只建表不播种；种预设三科（与新库首次启动一致），
    // 其余表全空（无题、无任务、无文件夹）。
    final db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(db);
    final repo = QuestionRepository(AppDatabase.instance);
    for (final s in Subject.all) {
      await repo.saveSubject(s);
    }
    addTearDown(() async {
      await AppDatabase.resetForTest();
    });
    return repo;
  }

  testWidgets('B8-1 真实交互：删光三科后四处界面都不再出现已删学科', (tester) async {
    final repo = await seedB();
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ProviderScope(child: QuizMasterApp()));

    // 1. 首页：导航速览里三科都在（删前基线，证明用例真的看到了它们）。
    await _pumpUntil(
      tester,
      () => _navText('数学').evaluate().isNotEmpty,
      reason: '启动后导航速览未出现数学',
    );
    for (final name in ['数学', '英语', '政治']) {
      expect(_navText(name), findsOneWidget);
    }

    // 2. 进学科管理页：先点开折叠的“学科”分区（默认全折叠，
    // 折叠时行内按钮不在树里；截图 image-89 里该分区也是展开态），
    // 再真实点“删除”删光三科（每次都走模态确认）。
    await _goNav(tester, '学科管理');
    await _pumpUntil(
      tester,
      () => find.text('学科').evaluate().isNotEmpty,
      reason: '学科管理页未加载',
    );
    await tester.tap(find.text('学科'));
    await _pumpUntil(
      tester,
      () => find.text('＋ 添加学科').evaluate().isNotEmpty,
      reason: '学科分区未展开',
    );
    for (final name in ['数学', '英语', '政治']) {
      await _deleteSubjectViaUi(tester, name);
    }
    // 学科管理页自己也显示空态。
    expect(find.text('还没有学科，先添加一个吧。'), findsOneWidget);
    for (final name in ['数学', '英语', '政治']) {
      expect(_navText(name), findsNothing);
    }

    // 3. 收集中心：导入学科下拉不再有已删学科。
    await _goNav(tester, '收集中心');
    await _pumpUntil(
      tester,
      () => find.text('还没有学科').evaluate().isNotEmpty,
      reason: '收集中心未显示无学科提示',
    );
    expect(find.text('还没有学科：先去「学科管理」添加一个，再回来导入。'), findsOneWidget);
    await tester.tap(find.byKey(const Key('collect-subject-select')));
    await tester.pump(const Duration(milliseconds: 200));
    for (final name in ['数学', '英语', '政治']) {
      expect(find.text(name), findsNothing);
    }

    // 4. 错题本：书架不再有已删学科的书，给空状态。
    await _goNav(tester, '错题本');
    await _pumpUntil(
      tester,
      () => find.text('还没有学科').evaluate().isNotEmpty,
      reason: '错题本书架未显示空状态',
    );
    expect(find.text('先去学科管理添加一个吧。'), findsOneWidget);
    for (final name in ['数学', '英语', '政治']) {
      expect(find.text(name), findsNothing);
    }
    expect(find.text('共 3 本'), findsNothing);

    // 5. 首页：学科格不再出现已删学科，只剩快速收集。
    await _goNav(tester, '首页');
    await _pumpUntil(
      tester,
      () => find.text('快速收集').evaluate().isNotEmpty,
      reason: '首页未加载',
    );
    for (final name in ['数学', '英语', '政治']) {
      expect(find.text(name), findsNothing);
    }

    // 收尾：等在途的角标重读 / saveLastRoute 落定再结束——
    // 它们是未 await 的异步写读，若测试体结束、tearDown 关库时仍在途，
    // 查询会报 database closed（偶发失败，见本文件调试记录）。
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }

    // 辅助 sanity（主断言全是界面）：库里学科表确实空了。
    // Drift 同步调用，直接 await（见文件头）。
    final remaining = await repo.subjects();
    expect(remaining, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
