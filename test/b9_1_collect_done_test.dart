// B9-1：整理完题后收集中心仍显示“待整理”——任务状态从不断。
//
// 根因：确认切分建题时每道题一个 CollectTask（pendingOrganize，
// question_id 指向题）；整理确认只把题存为 organized:true，从不
// 动任务；全仓没有任何生产代码给任务赋 CollectStatus.done；收集
// 中心计数/列表只读任务的持久化 status，整理队列与导航角标读题
// 的 is_organized——三处数字对不上。
//
// 修法（数据层集中处理）：
// - `upsertQuestionIntoImpl`：题存为已整理时，同句柄把指向它的
//   pendingOrganize 任务置 done（单题确认、批量整理都走 repo.save
//   → 这里，不会漏；详情/错题本的保存只是顺带自愈卡住行）。
// - `backfillCollectDoneIntoImpl` + `openAtImpl` 的 onOpen：每次
//   开库扫一遍，题已整理但任务仍 pendingOrganize 的行持久化置
//   done（Meng 库里卡住的 13 行下次启动即变过来）。
//
// 用例口径：数据层用真实内存库（`AppDatabase.openForTest()`，只建
// 表不播种、不碰真实库）；全流程用真实内存库 + 整应用
// `QuizMasterApp` 真点按（参照 B8-1 的写法：有界手动 pump，
// 不用 pumpAndSettle——整应用永不静止）。
// Drift 走同步 sqlite3 调用，仓库方法在 widget 测试里直接 await
// 即可；`tester.runAsync` 只用于 Future.delayed 这类真实延时。
// 注意：播种必须在测试体内做——setUp 跑在 fake async 区之外，
// setUp 里打开的库在测试体里 await 仓库方法会挂住（B Stage 1
// 探针 11/12/13）；普通 test（非 testWidgets）跑在真实异步区，
// setUp 播种不受影响。
// 种子库验证：回填的 open  wiring 用真实文件库（openAt 打开、
// 原始 SQL 插卡住行模拟旧版库、关闭、再 openAt）验证；演示库
// 是标准 v1（9 道题、0 行 pendingOrganize），不在本文件里动。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/app.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';

/// 左导航栏本体的 key（`AppNavBar` 根 Container），断言只圈导航内，
/// 避免与内容页同名文字混淆。
final _navBar = find.byKey(const ValueKey('qm-nav-bar'));

/// 导航栏内的某段文字。
Finder _navText(String text) =>
    find.descendant(of: _navBar, matching: find.text(text));

/// 有界手动 pump：每轮先 pump 一帧看条件，再切回真实异步等一轮、
/// 再 pump 渲染，直到条件成立或超限失败（B8-1 同款）。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  int maxRounds = 40,
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
  await tester.pump();
}

/// 拆分后的题 + 任务（确认切分刚完成时的状态）：题未整理，任务
/// pendingOrganize 且 question_id 指向题。
Question _splitQuestion(String id, {DateTime? createdAt}) => Question(
  id: id,
  title: '试卷 · 第1页 · 第$id题',
  subjectId: 'math',
  createdAt: createdAt ?? DateTime(2026, 11, 14),
  sliceText: '题干占位文字',
);

CollectTask _splitTask(String id, String questionId) => CollectTask(
  id: 'task-$id',
  name: '试卷 · 第1页 · 第$id题',
  fileName: '试卷.pdf',
  subjectId: 'math',
  status: CollectStatus.pendingOrganize,
  progress: 100,
  pageCount: 1,
  page: 1,
  questionId: questionId,
  createdAt: DateTime(2026, 11, 14),
);

/// 内存库 + 三科 + 数学预置文件夹（整理页文件夹区要显示“试卷”）。
Future<QuestionRepository> _seedMemoryRepo() async {
  final db = await AppDatabase.openForTest();
  AppDatabase.useDatabaseForTest(db);
  final repo = QuestionRepository(AppDatabase.instance);
  for (final s in Subject.all) {
    await repo.saveSubject(s);
  }
  await repo.saveFolder(
    const Folder(id: 'folder-math-试卷', name: '试卷', subjectId: 'math'),
  );
  return repo;
}

/// 种子两道待整理题 + 两条待整理任务（q1 更新、q2 更旧）。
Future<void> _seedTwoPending(QuestionRepository repo) async {
  await repo.save(_splitQuestion('q1', createdAt: DateTime(2026, 11, 14, 10)));
  await repo.save(_splitQuestion('q2', createdAt: DateTime(2026, 11, 14, 9)));
  await repo.saveCollectTask(_splitTask('q1', 'q1'));
  await repo.saveCollectTask(_splitTask('q2', 'q2'));
}

Future<List<CollectTask>> _tasks(QuestionRepository repo) =>
    repo.collectTasks();

void main() {
  group('B9-1 数据层：整理即置任务 done', () {
    late QuestionRepository repo;

    setUp(() async {
      repo = await _seedMemoryRepo();
      addTearDown(() async {
        await AppDatabase.resetForTest();
      });
    });

    test('单题确认路径：repo.save(organized:true) 后任务变 done', () async {
      await _seedTwoPending(repo);
      final q1 = (await repo.questionById('q1'))!;
      await repo.save(q1.copyWith(isOrganized: true));
      final tasks = await _tasks(repo);
      expect(
        tasks.firstWhere((t) => t.id == 'task-q1').status,
        CollectStatus.done,
      );
      // 另一道没整理的题，任务仍是待整理。
      expect(
        tasks.firstWhere((t) => t.id == 'task-q2').status,
        CollectStatus.pendingOrganize,
      );
    });

    test('未整理保存不动任务；已整理题再保存会自愈卡住的任务', () async {
      await _seedTwoPending(repo);
      final q1 = (await repo.questionById('q1'))!;
      // 只保存、不整理：任务不动（copyWith 没有 title 参数，标题
      // 改动与本用例无关，直接原样保存即可）。
      await repo.save(q1);
      expect(
        (await _tasks(repo)).firstWhere((t) => t.id == 'task-q1').status,
        CollectStatus.pendingOrganize,
      );
      // 模拟旧版卡住态：题已整理、任务仍待整理（原始 SQL 插，
      // 绕过 upsertQuestion 的流转），再任意保存一次已整理题。
      final db = await AppDatabase.instance.db;
      await db.customUpdate(
        'UPDATE questions SET is_organized = ? WHERE id = ?',
        variables: [Variable.withInt(1), Variable.withString('q1')],
      );
      final healed = (await repo.questionById('q1'))!;
      await repo.save(healed);
      expect(
        (await _tasks(repo)).firstWhere((t) => t.id == 'task-q1').status,
        CollectStatus.done,
      );
    });

    test('批量整理路径：逐题 save(organized:true) 后任务全变 done', () async {
      await _seedTwoPending(repo);
      for (final id in ['q1', 'q2']) {
        final q = (await repo.questionById(id))!;
        await repo.save(q.copyWith(isOrganized: true));
      }
      final tasks = await _tasks(repo);
      expect(tasks.map((t) => t.status), everyElement(CollectStatus.done));
    });
  });

  group('B9-1 回填：开库扫一遍治好卡住行', () {
    late QuestionRepository repo;

    setUp(() async {
      repo = await _seedMemoryRepo();
      addTearDown(() async {
        await AppDatabase.resetForTest();
      });
    });

    /// 原始 SQL 直接插卡住行（绕过 upsertQuestion 的流转，模拟
    /// 旧版库里已有的状态）：q1 已整理但任务待整理；q2 未整理、
    /// 任务待整理（不应动）；q3 已整理、任务已是 done（不应动）；
    /// task-orphan 无 question_id（不应动）。
    Future<void> seedStuckRows() async {
      final db = await AppDatabase.instance.db;
      for (final entry in [
        ('q1', 1, 'task-q1', 'pendingOrganize'),
        ('q2', 0, 'task-q2', 'pendingOrganize'),
        ('q3', 1, 'task-q3', 'done'),
      ]) {
        await db.customInsert(
          'INSERT INTO questions (id, title, subject_id, folder_ids, '
          'knowledge_ids, error_types, custom_error_types, tags, created_at, '
          'slice_kind, slice_text, is_organized) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          variables: [
            Variable.withString(entry.$1),
            Variable.withString('题 ${entry.$1}'),
            Variable.withString('math'),
            Variable.withString(''),
            Variable.withString(''),
            Variable.withString(''),
            Variable.withString(''),
            Variable.withString(''),
            Variable.withInt(1700000000000),
            Variable.withString('material'),
            Variable.withString(''),
            Variable.withInt(entry.$2),
          ],
        );
        await db.customInsert(
          'INSERT INTO collect_tasks (id, name, file_name, subject_id, '
          'status, progress, page_count, page, question_id) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
          variables: [
            Variable.withString(entry.$3),
            Variable.withString('试卷 · 第1页 · 第${entry.$1}题'),
            Variable.withString('试卷.pdf'),
            Variable.withString('math'),
            Variable.withString(entry.$4),
            Variable.withInt(100),
            Variable.withInt(1),
            Variable.withInt(1),
            Variable.withString(entry.$1),
          ],
        );
      }
      await db.customInsert(
        'INSERT INTO collect_tasks (id, name, file_name, subject_id, '
        'status, progress, page_count, page, question_id) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('task-orphan'),
          Variable.withString('孤儿任务'),
          Variable.withString('试卷.pdf'),
          Variable.withString('math'),
          Variable.withString('pendingOrganize'),
          Variable.withInt(100),
          Variable.withInt(1),
          Variable.withInt(1),
          const Variable<String>(null),
        ],
      );
    }

    test('回填只治卡住行：返回 1，余者不动', () async {
      await seedStuckRows();
      final db = await AppDatabase.instance.db;
      final fixed = await AppDatabase.backfillCollectDoneFrom(db);
      expect(fixed, 1);
      final tasks = await _tasks(repo);
      expect(
        tasks.firstWhere((t) => t.id == 'task-q1').status,
        CollectStatus.done,
      );
      expect(
        tasks.firstWhere((t) => t.id == 'task-q2').status,
        CollectStatus.pendingOrganize,
      );
      expect(
        tasks.firstWhere((t) => t.id == 'task-q3').status,
        CollectStatus.done,
      );
      expect(
        tasks.firstWhere((t) => t.id == 'task-orphan').status,
        CollectStatus.pendingOrganize,
      );
      // 幂等：再扫一次返回 0。
      expect(await AppDatabase.backfillCollectDoneFrom(db), 0);
    });

    test('开库即回填：文件库关了再开（openAt），卡住行已变 done', () async {
      final dir = await Directory.systemTemp.createTemp('b9_1_open_');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = '${dir.path}${Platform.pathSeparator}quiz-master2.db';
      // 第一次打开：建表播种；原始 SQL 插卡住行（绕过流转）。
      var db = await AppDatabase.openAt(dbPath);
      await db.customInsert(
        'INSERT INTO questions (id, title, subject_id, folder_ids, '
        'knowledge_ids, error_types, custom_error_types, tags, created_at, '
        'slice_kind, slice_text, is_organized) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('q1'),
          Variable.withString('题 q1'),
          Variable.withString('math'),
          Variable.withString(''),
          Variable.withString(''),
          Variable.withString(''),
          Variable.withString(''),
          Variable.withString(''),
          Variable.withInt(1700000000000),
          Variable.withString('material'),
          Variable.withString(''),
          Variable.withInt(1),
        ],
      );
      await db.customInsert(
        'INSERT INTO collect_tasks (id, name, file_name, subject_id, '
        'status, progress, page_count, page, question_id) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('task-q1'),
          Variable.withString('试卷 · 第1页 · 第q1题'),
          Variable.withString('试卷.pdf'),
          Variable.withString('math'),
          Variable.withString('pendingOrganize'),
          Variable.withInt(100),
          Variable.withInt(1),
          Variable.withInt(1),
          Variable.withString('q1'),
        ],
      );
      await db.close();
      // 第二次打开（生产开库路径，onOpen 回填）：不经任何用户操作。
      db = await AppDatabase.openAt(dbPath);
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
      });
      final tasks = await AppDatabase.allCollectTasksFrom(db);
      expect(tasks.single.status, CollectStatus.done);
    });
  });

  group('B9-1 真实交互：整理完回收集中心', () {
    // 播种必须在测试体内做（见文件头）：setUp 在 fake async 区之外。
    Future<QuestionRepository> seedB() async {
      final repo = await _seedMemoryRepo();
      addTearDown(() async {
        await AppDatabase.resetForTest();
      });
      return repo;
    }

    Future<void> pumpApp(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const ProviderScope(child: QuizMasterApp()));
      // B8-1 同款：等导航速览出现数学（启动基线）。
      await _pumpUntil(
        tester,
        () => _navText('数学').evaluate().isNotEmpty,
        reason: '启动后导航速览未出现数学',
      );
    }

    /// 收尾沉降（B8-1 同款）：等在途的角标重读 / saveLastRoute
    /// 落定再结束——它们是未 await 的异步写读，若测试体结束、
    /// tearDown 关库时仍在途，查询会报 database closed。
    /// 本用例在途工作比 B8-1 多（整理确认 + 跳页 + 收集 _load），
    /// 轮数给到 5 × 200ms。
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump();
      }
    }

    /// 在收集中心断言：待整理计数 0、两行都是“已整理” pill。
    /// 注意：等“全部 2”而不是“待整理 0”——_load 完成前 _tasks
    /// 为空，chip 也显示“待整理 0”，那个条件在加载前就成立，
    /// 会误判（行还没出来）。
    Future<void> expectCollectDone(WidgetTester tester) async {
      await _goNav(tester, '收集中心');
      await _pumpUntil(
        tester,
        () => find.text('全部 2').evaluate().isNotEmpty,
        reason: '收集中心未加载出两行任务',
      );
      expect(find.text('全部 2'), findsOneWidget);
      expect(find.text('待整理 0'), findsOneWidget);
      expect(find.text('已整理'), findsNWidgets(2));
      expect(find.text('待整理'), findsNothing);
    }

    testWidgets('单题确认：逐题整理完，收集中心待整理归零、行变已整理', (tester) async {
      final repo = await seedB();
      // Drift 同步调用，直接 await（见文件头）。
      await _seedTwoPending(repo);
      await pumpApp(tester);
      await _goNav(tester, '整理工作台');
      await _pumpUntil(
        tester,
        () => find.text('还剩 2 道').evaluate().isNotEmpty,
        reason: '整理工作台未显示“还剩 2 道”',
      );
      // q1（更新的在先）：选文件夹 → 确认整理，进下一道。
      await tester.tap(find.text('试卷').first);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.ensureVisible(find.text('确认整理，去下一道'));
      await tester.tap(find.text('确认整理，去下一道'));
      await _pumpUntil(
        tester,
        () => find.text('还剩 1 道').evaluate().isNotEmpty,
        reason: '确认 q1 后未进下一道',
      );
      // q2：同样选文件夹 → 确认整理，队列空。
      await tester.tap(find.text('试卷').first);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.ensureVisible(find.text('确认整理，去下一道'));
      await tester.tap(find.text('确认整理，去下一道'));
      await _pumpUntil(
        tester,
        () => find.text('都整理完了，去复习吧').evaluate().isNotEmpty,
        reason: '确认 q2 后未显示整理完成空状态',
      );
      await expectCollectDone(tester);
      await settle(tester);
      // 库里状态也已持久化（不只是界面派生）。
      final tasks = await _tasks(repo);
      expect(tasks.map((t) => t.status), everyElement(CollectStatus.done));
      expect(tester.takeException(), isNull);
    });

    testWidgets('批量确认：队列里全选后批量确认，任务同样变 done', (tester) async {
      final repo = await seedB();
      // 批量确认只认已有文件夹的题：种子题直接带文件夹。
      await repo.save(
        _splitQuestion(
          'q1',
          createdAt: DateTime(2026, 11, 14, 10),
        ).copyWith(folderIds: ['folder-math-试卷']),
      );
      await repo.save(
        _splitQuestion(
          'q2',
          createdAt: DateTime(2026, 11, 14, 9),
        ).copyWith(folderIds: ['folder-math-试卷']),
      );
      await repo.saveCollectTask(_splitTask('q1', 'q1'));
      await repo.saveCollectTask(_splitTask('q2', 'q2'));
      await pumpApp(tester);
      await _goNav(tester, '整理工作台');
      await _pumpUntil(
        tester,
        () => find.text('还剩 2 道').evaluate().isNotEmpty,
        reason: '整理工作台未显示“还剩 2 道”',
      );
      await tester.tap(find.text('队列'));
      await _pumpUntil(
        tester,
        () => find.text('待整理队列 · 2 道').evaluate().isNotEmpty,
        reason: '队列弹窗未打开',
      );
      final checkboxes = find.descendant(
        of: find.byKey(const Key('organize-queue-popup')),
        matching: find.byType(Checkbox),
      );
      // 弹窗已有 B9-2 的全选框：1 个全选 + 每题 1 个，共 3 个。
      expect(checkboxes, findsNWidgets(3));
      // 点“全选”一次选两道（B9-2 入口，不用先逐个勾）。
      await tester.tap(find.text('全选'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('批量确认整理'));
      await _pumpUntil(
        tester,
        () => find.text('都整理完了，去复习吧').evaluate().isNotEmpty,
        reason: '批量确认后未显示整理完成空状态',
      );
      await expectCollectDone(tester);
      await settle(tester);
      final tasks = await _tasks(repo);
      expect(tasks.map((t) => t.status), everyElement(CollectStatus.done));
      expect(tester.takeException(), isNull);
    });
  });
}
