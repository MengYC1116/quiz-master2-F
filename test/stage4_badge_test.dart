// Stage 4：角标接管（DataChangeBus + badgeCountsProvider）。
//
// 三层用例：
// - A 组：总线 + 仓储事件（纯 test，内存库）：写成功发一个带完整
//   kind 集的事件且 questionId 只在单题时有；写失败/回滚不发；
//   批量提交只发一个合并事件；备份恢复只发一个全 kind 事件。
// - B 组：badgeCountsProvider（ProviderContainer）：含 badges 才
//   重读、无交集不重读、初始化期间写入最终计入、dispose 后不再
//   触达、OrganizeNotifier 批量确认只发一个事件。
// - C 组：10 个整应用 widget 场景（A v4 §四第 4 阶段清单）：
//   写库后角标在原页面即时刷新，全程不切导航、不打开目标页。
//
// 整应用 `pumpAndSettle` 永不静止（见 `s8b3_startup_test.dart`
// 文件头），用有界手动 pump（B8-1 / B9-3 同款 `_pumpUntil`）；
// testWidgets 体跑在 fake async 里，真实 ffi 数据库的 Future
// 须用 `tester.runAsync` 切回真实异步等它完成。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/app.dart';
import 'package:quiz_master2/data/data_change_events.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/badge_counts_provider.dart';
import 'package:quiz_master2/state/organize_notifier.dart';
import 'package:quiz_master2/state/repository_provider.dart';

// ---------- 共享 ----------

/// 内存库 + 预设三科（与新库首次启动一致），其余表全空。
Future<QuestionRepository> _seedMemoryRepo() async {
  final db = await AppDatabase.openForTest();
  AppDatabase.useDatabaseForTest(db);
  addTearDown(() async {
    await AppDatabase.resetForTest();
  });
  final repo = QuestionRepository(AppDatabase.instance);
  for (final s in Subject.all) {
    await repo.saveSubject(s);
  }
  return repo;
}

/// 未整理题（整理角标的原料）。
Question _unorganized(String id) => Question(
  id: id,
  title: '数学 · 第$id题',
  subjectId: 'math',
  createdAt: DateTime(2026, 11, 14),
  sliceText: '题干占位文字',
  errorTypes: const [],
  isOrganized: false,
);

/// 已整理、已加入复习的题（复习角标的原料）。
Question _joinedQuestion(String id, {required List<String> errorTypes}) =>
    Question(
      id: id,
      title: '数学 · 第$id题',
      subjectId: 'math',
      createdAt: DateTime(2026, 11, 14),
      sliceText: '题干占位文字',
      errorTypes: errorTypes,
      isOrganized: true,
    );

Future<void> _seedDue(
  QuestionRepository repo,
  String id, {
  List<String> errorTypes = const ['概念不清'],
}) async {
  final q = _joinedQuestion(id, errorTypes: errorTypes);
  await repo.save(q);
  expect(await repo.setReviewJoined(q, true), isTrue);
}

/// 广播流是异步投递：等一轮事件循环再断言。
Future<void> _flushEvents() async {
  await Future<void>.delayed(const Duration(milliseconds: 100));
}

/// 纯 test 里的有界等待（真实异步）。
Future<void> _waitFor(
  bool Function() cond, {
  required String reason,
  int maxRounds = 100,
}) async {
  for (var i = 0; i < maxRounds; i++) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('条件未成立：$reason');
}

// ---------- C 组：整应用 ----------

/// 左导航栏本体的 key，断言只圈导航内，避免与内容页同名文字混淆。
final _navBar = find.byKey(const ValueKey('qm-nav-bar'));

/// 导航栏内的某段文字。
Finder _navText(String text) =>
    find.descendant(of: _navBar, matching: find.text(text));

/// 导航某项的角标是否为 [number]：找该项 label 的最近 Row 祖先，
/// 再在其子树里找数字文字。行内定位，避免收集/整理角标同数时
/// `find.text(number)` 命中两处。
bool _navBadgeIs(WidgetTester tester, String label, String number) {
  final labels = _navText(label).evaluate();
  if (labels.isEmpty) return false;
  Element? row;
  labels.first.visitAncestorElements((e) {
    if (e.widget is Row) {
      row = e;
      return false;
    }
    return true;
  });
  if (row == null) return false;
  return find
      .descendant(of: find.byWidget(row!.widget), matching: find.text(number))
      .evaluate()
      .isNotEmpty;
}

/// 有界手动 pump：每轮先 pump 一帧看条件，再切回真实异步等一轮、
// 再 pump 渲染，直到条件成立或超限失败（B8-1 同款）。
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

Future<void> _pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(const ProviderScope(child: QuizMasterApp()));
}

/// 在 testWidgets 体内建内存库并做种子写入：真实 ffi Future 必须在
/// `runAsync` 里等（见 B9-3 文件头），在 fake async 体里直接 await
/// 会挂住（S4-1 曾因此超时）。
Future<QuestionRepository> _seedWidgetRepo(
  WidgetTester tester, {
  Future<void> Function(QuestionRepository repo)? seed,
}) async {
  return tester.runAsync(() async {
    final repo = await _seedMemoryRepo();
    if (seed != null) await seed(repo);
    return repo;
  }).then((repo) => repo!);
}

/// 把一条错因记录自查“已解决”到治愈（默认 cureChecks=2，需两次；
/// 复查日顺延到今天 +7 天，不到复查时间，桶落 solved）。
Future<CauseRecord> _cureCause(
  WidgetTester tester,
  QuestionRepository repo,
  CauseRecord rec,
) async {
  var cur = rec;
  for (var i = 0; i < 2; i++) {
    cur = (await tester.runAsync(() => repo.recordSelfCheck(cur, 'solved')))!;
  }
  expect(cur.status, CauseStatus.solved);
  return cur;
}

// ---------- A 组：总线 + 仓储事件 ----------

void main() {
  group('A：写方法 → 事件（一次写入只发一个带完整 kind 集的事件）', () {
    late QuestionRepository repo;
    late List<DataChangeEvent> events;
    late StreamSubscription<DataChangeEvent> sub;

    setUp(() async {
      repo = await _seedMemoryRepo();
      events = <DataChangeEvent>[];
      sub = DataChangeBus.instance.stream.listen(events.add);
      addTearDown(sub.cancel);
    });

    test('save 成功：一个事件，kinds={badges, questions}，questionId=题 id', () async {
      final q = _unorganized('q1');
      await repo.save(q);
      await _flushEvents();
      expect(events.length, 1);
      expect(events.single.kinds, {
        DataChangeKind.badges,
        DataChangeKind.questions,
      });
      expect(events.single.questionId, 'q1');
    });

    test('recordSelfCheck 判 unsure 不发事件（不计一次自查）', () async {
      await _seedDue(repo, 'q1');
      final recs = await repo.causeRecordsFor('q1');
      expect(recs, isNotEmpty);
      events.clear();
      final out = await repo.recordSelfCheck(recs.first, 'unsure');
      expect(out, isNotNull);
      await _flushEvents();
      expect(events, isEmpty);
    });

    test('写失败不发事件：同名文件夹保存抛 StateError', () async {
      const f1 = Folder(
        id: 'f1',
        name: '试卷',
        subjectId: 'math',
        sortOrder: 0,
      );
      await repo.saveFolder(f1);
      await _flushEvents();
      expect(events.length, 1);
      expect(events.single.kinds, {DataChangeKind.subjects});
      expect(
        () => repo.saveFolder(
          const Folder(
            id: 'f2',
            name: '试卷',
            subjectId: 'math',
            sortOrder: 1,
          ),
        ),
        throwsStateError,
      );
      await _flushEvents();
      expect(events.length, 1, reason: '失败的写不追加事件');
    });

    test('joinReviewBatch 两题只发一个事件，kinds={badges, reviewRecords}，questionId 为空', () async {
      final q1 = _joinedQuestion('q1', errorTypes: ['概念不清']);
      final q2 = _joinedQuestion('q2', errorTypes: ['审题失误']);
      await repo.save(q1);
      await repo.save(q2);
      // 广播投递比 await 慢一拍：先等在途事件落定再清计数，
      // 否则上一笔写事件会迟到、污染本轮计数。
      await _flushEvents();
      events.clear();
      final result = await repo.joinReviewBatch([q1, q2]);
      expect(result.joined, 2);
      await _flushEvents();
      expect(events.length, 1);
      expect(events.single.kinds, {
        DataChangeKind.badges,
        DataChangeKind.reviewRecords,
      });
      expect(events.single.questionId, isNull);
    });

    test('cancelReviewBatch 全跳过（都未加入）不发事件', () async {
      final q1 = _joinedQuestion('q1', errorTypes: ['概念不清']);
      await repo.save(q1);
      // 同上：先等在途事件落定再清计数。
      await _flushEvents();
      events.clear();
      final result = await repo.cancelReviewBatch([q1]);
      expect(result.cancelled, 0);
      expect(result.skipped, 1);
      await _flushEvents();
      expect(events, isEmpty);
    });

    test('importBackupJson 只发一个含全部五种 kind 的事件', () async {
      await _seedDue(repo, 'q1');
      final json = await repo.exportBackupJson();
      await repo.delete((await repo.questionById('q1'))!);
      // 同上：先等在途事件落定再清计数。
      await _flushEvents();
      events.clear();
      await repo.importBackupJson(
        jsonDecode(json) as Map<String, dynamic>,
      );
      await _flushEvents();
      expect(events.length, 1);
      expect(events.single.kinds, DataChangeKind.values.toSet());
      expect(events.single.questionId, isNull);
    });

    test('saveSettings 发 {settings}；saveLastRoute 不发事件', () async {
      await repo.saveSettings(const AppSettings());
      await _flushEvents();
      expect(events.length, 1);
      expect(events.single.kinds, {DataChangeKind.settings});
      await repo.saveLastRoute('/home');
      await _flushEvents();
      expect(events.length, 1, reason: '路由记忆不是数据变更');
    });

    test('scope：嵌套 emit 合并成一个事件；体内抛错后仍 flush 且异常外传', () async {
      final bus = DataChangeBus.instance;
      await bus.scope(() async {
        bus.emit(
          const DataChangeEvent(kinds: {DataChangeKind.badges}),
        );
        await bus.scope(() async {
          bus.emit(
            const DataChangeEvent(kinds: {DataChangeKind.questions}),
          );
        });
      });
      await _flushEvents();
      expect(events.length, 1);
      expect(events.single.kinds, {
        DataChangeKind.badges,
        DataChangeKind.questions,
      });

      events.clear();
      expect(
        () => bus.scope(() async {
          bus.emit(
            const DataChangeEvent(kinds: {DataChangeKind.badges}),
          );
          throw StateError('boom');
        }),
        throwsStateError,
      );
      await _flushEvents();
      expect(events.length, 1, reason: '抛错后缓冲的事件仍发出');
    });
  });

  // ---------- B 组：badgeCountsProvider ----------

  group('B：badgeCountsProvider 按 kind 订阅刷新', () {
    Future<ProviderContainer> containerWith(
      QuestionRepository repo,
    ) async {
      final container = ProviderContainer.test(
        overrides: [repositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('首查读到当前计数：1 道待复习 → reviewBadge=1', () async {
      final repo = await _seedMemoryRepo();
      await _seedDue(repo, 'q1');
      final container = await containerWith(repo);
      container.listen(badgeCountsProvider, (_, __) {});
      await _waitFor(
        () => container.read(badgeCountsProvider).value?.reviewBadge == 1,
        reason: '首查完成',
      );
      final counts = container.read(badgeCountsProvider).value!;
      expect(counts.organizeBadge, 0);
      expect(counts.collectBadge, 0);
      expect(counts.subjects, hasLength(3));
    });

    test('含 badges 的事件触发重读：再加入一道 → reviewBadge=2', () async {
      final repo = await _seedMemoryRepo();
      await _seedDue(repo, 'q1');
      final container = await containerWith(repo);
      container.listen(badgeCountsProvider, (_, __) {});
      await _waitFor(
        () => container.read(badgeCountsProvider).value?.reviewBadge == 1,
        reason: '首查完成',
      );
      await _seedDue(repo, 'q2');
      await _waitFor(
        () => container.read(badgeCountsProvider).value?.reviewBadge == 2,
        reason: '事件后重读',
      );
    });

    test('无交集 kind 的事件不重读：状态对象不变且不 loading', () async {
      final repo = await _seedMemoryRepo();
      await _seedDue(repo, 'q1');
      final container = await containerWith(repo);
      container.listen(badgeCountsProvider, (_, __) {});
      await _waitFor(
        () => container.read(badgeCountsProvider).value?.reviewBadge == 1,
        reason: '首查完成',
      );
      final before = container.read(badgeCountsProvider);
      DataChangeBus.instance.emit(
        const DataChangeEvent(kinds: {DataChangeKind.subjects}),
      );
      await _flushEvents();
      final after = container.read(badgeCountsProvider);
      expect(identical(before, after), isTrue);
      expect(after.isLoading, isFalse);
    });

    test('初始化期间写入：首查完成时计入新题', () async {
      final repo = await _seedMemoryRepo();
      await _seedDue(repo, 'q1');
      final container = await containerWith(repo);
      container.listen(badgeCountsProvider, (_, __) {});
      // 首查尚在途时再写一道待复习题。
      await _seedDue(repo, 'q2');
      await _waitFor(
        () => container.read(badgeCountsProvider).value?.reviewBadge == 2,
        reason: '首查的最终值应含 q2',
      );
    });

    test('dispose 后事件不再触达监听', () async {
      final repo = await _seedMemoryRepo();
      await _seedDue(repo, 'q1');
      final container = ProviderContainer.test(
        overrides: [repositoryProvider.overrideWithValue(repo)],
      );
      var calls = 0;
      container.listen(badgeCountsProvider, (_, __) {
        calls++;
      });
      await _waitFor(
        () => container.read(badgeCountsProvider).value?.reviewBadge == 1,
        reason: '首查完成',
      );
      final callsAfterInit = calls;
      container.dispose();
      DataChangeBus.instance.emit(
        const DataChangeEvent(kinds: {DataChangeKind.badges}),
      );
      await _flushEvents();
      expect(calls, callsAfterInit);
    });

    test('OrganizeNotifier.batchConfirmQuestions 三题只发一个事件', () async {
      final repo = await _seedMemoryRepo();
      await repo.saveFolder(
        const Folder(
          id: 'f1',
          name: '试卷',
          subjectId: 'math',
          sortOrder: 0,
        ),
      );
      final qs = [
        _unorganized('q1').copyWith(folderIds: const ['f1']),
        _unorganized('q2').copyWith(folderIds: const ['f1']),
        _unorganized('q3').copyWith(folderIds: const ['f1']),
      ];
      for (final q in qs) {
        await repo.save(q);
      }
      final events = <DataChangeEvent>[];
      final sub = DataChangeBus.instance.stream.listen(events.add);
      addTearDown(sub.cancel);
      final container = await containerWith(repo);
      container.listen(organizeProvider, (_, __) {});
      final blocked = await container
          .read(organizeProvider.notifier)
          .batchConfirmQuestions(qs);
      expect(blocked, 0);
      await _flushEvents();
      expect(events.length, 1);
      expect(events.single.kinds, {
        DataChangeKind.badges,
        DataChangeKind.questions,
      });
      expect(events.single.questionId, isNull);
    });
  });

  // ---------- C 组：整应用 10 个角标场景（不切导航） ----------

  group('C：整应用角标（写库后原页面即时刷新，不切导航）', () {
    testWidgets('S4-1 删学科：导航速览里该科消失', (tester) async {
      final repo = await _seedWidgetRepo(tester);
      await _pumpApp(tester);
      await _pumpUntil(
        tester,
        () => _navText('数学').evaluate().isNotEmpty,
        reason: '导航速览出现数学',
      );
      await tester.runAsync(() => repo.deleteSubject('math'));
      await _pumpUntil(
        tester,
        () => _navText('数学').evaluate().isEmpty,
        reason: '删学科后导航速览去掉数学',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('S4-2 整理完一道：整理角标 1→0', (tester) async {
      final repo = await _seedWidgetRepo(
        tester,
        seed: (repo) async => repo.save(_unorganized('q1')),
      );
      await _pumpApp(tester);
      await _pumpUntil(
        tester,
        () => _navBadgeIs(tester, '整理工作台', '1'),
        reason: '整理角标出现 1',
      );
      await tester.runAsync(
        () => repo.save(_unorganized('q1').copyWith(isOrganized: true)),
      );
      await _pumpUntil(
        tester,
        () => !_navBadgeIs(tester, '整理工作台', '1'),
        reason: '整理完后整理角标消失',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('S4-3 批量整理三道：整理角标 3→0', (tester) async {
      final repo = await _seedWidgetRepo(
        tester,
        seed: (repo) async {
          for (final id in ['q1', 'q2', 'q3']) {
            await repo.save(_unorganized(id));
          }
        },
      );
      await _pumpApp(tester);
      await _pumpUntil(
        tester,
        () => _navBadgeIs(tester, '整理工作台', '3'),
        reason: '整理角标出现 3',
      );
      await tester.runAsync(() async {
        for (final id in ['q1', 'q2', 'q3']) {
          await repo.save(
            _unorganized(id).copyWith(isOrganized: true),
          );
        }
      });
      await _pumpUntil(
        tester,
        () => !_navBadgeIs(tester, '整理工作台', '3'),
        reason: '批量整理完后整理角标消失',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('S4-4 加入复习：复习角标 0→1', (tester) async {
      final repo = await _seedWidgetRepo(
        tester,
        seed: (repo) async {
          final q = _joinedQuestion('q1', errorTypes: ['概念不清']);
          await repo.save(q);
        },
      );
      await _pumpApp(tester);
      await _pumpUntil(
        tester,
        () => !_navBadgeIs(tester, '复习', '1'),
        reason: '初始复习角标为空',
      );
      final q = (await tester.runAsync(() => repo.questionById('q1')))!;
      await tester.runAsync(() => repo.setReviewJoined(q, true));
      await _pumpUntil(
        tester,
        () => _navBadgeIs(tester, '复习', '1'),
        reason: '加入复习后复习角标出现 1',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('S4-5 取消加入复习：复习角标 1→0', (tester) async {
      final repo = await _seedWidgetRepo(
        tester,
        seed: (repo) => _seedDue(repo, 'q1'),
      );
      await _pumpApp(tester);
      await _pumpUntil(
        tester,
        () => _navBadgeIs(tester, '复习', '1'),
        reason: '复习角标出现 1',
      );
      final q = (await tester.runAsync(() => repo.questionById('q1')))!;
      await tester.runAsync(() => repo.setReviewJoined(q, false));
      await _pumpUntil(
        tester,
        () => !_navBadgeIs(tester, '复习', '1'),
        reason: '取消加入后复习角标消失',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('S4-6 自查治愈：复习角标 1→0', (tester) async {
      final repo = await _seedWidgetRepo(
        tester,
        seed: (repo) => _seedDue(repo, 'q1'),
      );
      await _pumpApp(tester);
      await _pumpUntil(
        tester,
        () => _navBadgeIs(tester, '复习', '1'),
        reason: '复习角标出现 1',
      );
      final recs = await tester.runAsync(() => repo.causeRecordsFor('q1'));
      expect(recs, hasLength(1));
      await _cureCause(tester, repo, recs!.first);
      await _pumpUntil(
        tester,
        () => !_navBadgeIs(tester, '复习', '1'),
        reason: '治愈后复习角标消失',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('S4-7 归档待复习题：复习角标 1→0', (tester) async {
      final repo = await _seedWidgetRepo(
        tester,
        seed: (repo) => _seedDue(repo, 'q1'),
      );
      await _pumpApp(tester);
      await _pumpUntil(
        tester,
        () => _navBadgeIs(tester, '复习', '1'),
        reason: '复习角标出现 1',
      );
      final q = (await tester.runAsync(() => repo.questionById('q1')))!;
      await tester.runAsync(() => repo.archive(q));
      await _pumpUntil(
        tester,
        () => !_navBadgeIs(tester, '复习', '1'),
        reason: '归档后复习角标消失',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('S4-8 恢复归档：复习角标 0→1', (tester) async {
      final repo = await _seedWidgetRepo(
        tester,
        seed: (repo) async {
          final q = _joinedQuestion('q1', errorTypes: ['概念不清']);
          await repo.save(q);
          await repo.setReviewJoined(q, true);
          // 归档须用库里刚读回的题：q 仍是 setReviewJoined 之前
          // 的旧对象（reviewJoined=false），直接归档它会把已加入
          // 的标记写回 false（全行 upsert 语义）。
          final joined = (await repo.questionById('q1'))!;
          await repo.archive(joined);
        },
      );
      await _pumpApp(tester);
      await _pumpUntil(
        tester,
        () => !_navBadgeIs(tester, '复习', '1'),
        reason: '归档题不计入复习角标',
      );
      final q = (await tester.runAsync(() => repo.questionById('q1')))!;
      await tester.runAsync(() => repo.archive(q, archived: false));
      await _pumpUntil(
        tester,
        () => _navBadgeIs(tester, '复习', '1'),
        reason: '恢复归档后复习角标出现 1',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('S4-9 删除待复习题：复习角标 1→0', (tester) async {
      final repo = await _seedWidgetRepo(
        tester,
        seed: (repo) => _seedDue(repo, 'q1'),
      );
      await _pumpApp(tester);
      await _pumpUntil(
        tester,
        () => _navBadgeIs(tester, '复习', '1'),
        reason: '复习角标出现 1',
      );
      final q = (await tester.runAsync(() => repo.questionById('q1')))!;
      await tester.runAsync(() => repo.delete(q));
      await _pumpUntil(
        tester,
        () => !_navBadgeIs(tester, '复习', '1'),
        reason: '删除后复习角标消失',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('S4-10 备份恢复：删题后角标 0，恢复后角标回 1', (tester) async {
      final repo = await _seedWidgetRepo(
        tester,
        seed: (repo) => _seedDue(repo, 'q1'),
      );
      final json =
          (await tester.runAsync(() => repo.exportBackupJson()))!;
      await _pumpApp(tester);
      await _pumpUntil(
        tester,
        () => _navBadgeIs(tester, '复习', '1'),
        reason: '复习角标出现 1',
      );
      final q = (await tester.runAsync(() => repo.questionById('q1')))!;
      await tester.runAsync(() => repo.delete(q));
      await _pumpUntil(
        tester,
        () => !_navBadgeIs(tester, '复习', '1'),
        reason: '删除后复习角标消失',
      );
      await tester.runAsync(
        () => repo.importBackupJson(
          jsonDecode(json) as Map<String, dynamic>,
        ),
      );
      await _pumpUntil(
        tester,
        () => _navBadgeIs(tester, '复习', '1'),
        reason: '备份恢复后复习角标回到 1',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
