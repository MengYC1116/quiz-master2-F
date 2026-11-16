// ARCH-PLAN-A 第 3 阶段：CollectNotifier 单测（不启动 widget）。
// 注入方式与 detail_notifier_test.dart 一致：ProviderContainer.test +
// repositoryProvider.overrideWithValue。autoDispose 下单测要像页面
// ref.watch 那样持一个监听保活（D-36：只 read 不监听时 build 里的
// microtask 首查还没写回就被销毁），见 `_container`。首查直接调
// `await notifier.load()`（与 review / organize / detail 单测同款），
// 不等 build 里的 microtask。
// 导入成功路径（真实 enqueue / 修框确认拆题）由既有 widget 测试覆盖
//（collect_page_test / pdf_collect_page_test / b8_345_box_interaction /
// b11_dragdrop / b11_batch_import），这里只测 Notifier 的业务返回值与
// 落盘结果：load 的未框页与“打开过”信号、导入入口的去重/暂存/待确认、
// 失败任务、修框准备与确认拆题的早期分支。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/collect_notifier.dart';
import 'package:quiz_master2/state/repository_provider.dart';

CollectTask _task(
  String id,
  String fileName, {
  CollectStatus status = CollectStatus.needBox,
  int pageCount = 1,
  int page = 1,
  String subjectId = 'math',
  String sourcePath = '',
  String? questionId,
}) => CollectTask(
  id: id,
  name: '$fileName · 第$page页 · 第1题',
  fileName: fileName,
  subjectId: subjectId,
  status: status,
  pageCount: pageCount,
  page: page,
  sourcePath: sourcePath,
  questionId: questionId,
);

QuestionBox _box(String id, {int page = 1, int layer = 1}) => QuestionBox(
  id: id,
  layer: layer,
  type: 'question',
  x: 0.1,
  y: 0.1,
  w: 0.5,
  h: 0.2,
  page: page,
);

class FakeCollectNotifierRepo extends QuestionRepository {
  FakeCollectNotifierRepo({
    List<CollectTask>? tasks,
    List<Subject>? subjectsValue,
    Map<String, List<QuestionBox>>? boxesByTask,
    this.throwOnBoxes = false,
  }) : tasks = List.of(tasks ?? const []),
       subjectsValue = subjectsValue ?? Subject.all,
       boxesByTask = boxesByTask ?? {},
       super(AppDatabase.instance);

  List<CollectTask> tasks;
  List<Subject> subjectsValue;
  Map<String, List<QuestionBox>> boxesByTask;
  bool throwOnBoxes;

  final List<CollectTask> savedTasks = [];
  final List<String> deletedIds = [];
  final List<(String, String, String)> recentTasks = [];
  final List<String> draftSavedTaskIds = [];

  @override
  Future<List<CollectTask>> collectTasks() async => List.of(tasks);

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);

  @override
  Future<List<QuestionBox>> boxesForTask(String taskId) async {
    if (throwOnBoxes) throw StateError('boxes boom');
    return List.of(boxesByTask[taskId] ?? const []);
  }

  @override
  Future<void> saveCollectTask(CollectTask t) async {
    savedTasks.add(t);
    final i = tasks.indexWhere((x) => x.id == t.id);
    if (i >= 0) {
      tasks[i] = t;
    } else {
      tasks.add(t);
    }
  }

  @override
  Future<void> saveDraftBoxes({
    required String taskId,
    required Map<int, List<QuestionBox>> boxesByPage,
    required Map<int, int> rotations,
  }) async {
    draftSavedTaskIds.add(taskId);
    boxesByTask[taskId] = [
      for (final e in boxesByPage.entries)
        ...e.value,
    ];
  }

  @override
  Future<void> saveRecentTask({
    required String kind,
    required String subjectId,
    required String title,
  }) async {
    recentTasks.add((kind, subjectId, title));
  }

  @override
  Future<void> deleteCollectTask(String id) async {
    deletedIds.add(id);
    tasks.removeWhere((x) => x.id == id);
  }
}

void main() {
  late FakeCollectNotifierRepo repo;
  late ProviderContainer container;
  late CollectNotifier notifier;
  late Directory tmpDir;

  ProviderContainer makeContainer(FakeCollectNotifierRepo fake) {
    final c = ProviderContainer.test(
      overrides: [repositoryProvider.overrideWithValue(fake)],
    );
    addTearDown(c.dispose);
    // D-36：autoDispose 单测必须持一个监听保活，不要裸 read 轮询等首查。
    c.listen(collectProvider, (_, __) {});
    return c;
  }

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('qm2-collect-notifier-');
  });

  tearDown(() async {
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  Future<File> makeTmpFile(String name, List<int> bytes) async {
    final f = File('${tmpDir.path}/$name');
    await f.writeAsBytes(bytes);
    return f;
  }

  group('load', () {
    test('未框页只认 1 层框：layer-2 框不算已框', () async {
      repo = FakeCollectNotifierRepo(
        tasks: [_task('t1', 'a.png', pageCount: 2)],
        boxesByTask: {
          't1': [_box('b1', page: 1, layer: 1), _box('b2', page: 2, layer: 2)],
        },
      );
      container = makeContainer(repo);
      notifier = container.read(collectProvider.notifier);
      await notifier.load();
      expect(container.read(collectProvider).tasks.length, 1);
      // 第 1 页有 1 层框算已框；第 2 页只有 layer-2 框，仍算未框。
      expect(container.read(collectProvider).unboxedPagesByTask, {
        't1': [2],
      });
    });

    test('“打开过”信号：任意草稿框与同源拆分任务', () async {
      repo = FakeCollectNotifierRepo(
        tasks: [
          _task('t1', 'a.png'),
          _task('t2', 'b.png', pageCount: 2, sourcePath: 'imports/t2/x.png'),
          _task(
            't2-split',
            'b.png',
            status: CollectStatus.pendingOrganize,
            sourcePath: 'imports/t2/x.png',
          ),
        ],
        boxesByTask: {
          't1': [_box('b1')],
        },
      );
      container = makeContainer(repo);
      notifier = container.read(collectProvider.notifier);
      await notifier.load();
      final s = container.read(collectProvider);
      expect(s.hasAnyDraftBox, {'t1'});
      // t2 有同源拆分任务（待整理）→ 打开过；t1 没有拆分任务。
      expect(s.hasSplitSibling, {'t2'});
      // t1 已框完不警告；t2 第 1 页已拆（不算未框），第 2 页未框。
      expect(s.unboxedPagesByTask, {
        't2': [2],
      });
    });

    test('草稿读不到不影响列表本身', () async {
      repo = FakeCollectNotifierRepo(
        tasks: [_task('t1', 'a.png')],
        throwOnBoxes: true,
      );
      container = makeContainer(repo);
      notifier = container.read(collectProvider.notifier);
      await notifier.load();
      final s = container.read(collectProvider);
      expect(s.tasks.length, 1);
      expect(s.unboxedPagesByTask, isEmpty);
      expect(s.hasAnyDraftBox, isEmpty);
    });
  });

  group('selectSubject', () {
    test('改选学科并清除猜测提示', () async {
      repo = FakeCollectNotifierRepo();
      container = makeContainer(repo);
      notifier = container.read(collectProvider.notifier);
      await notifier.load();
      // 先用文件名猜出一个提示（见 handleIncomingPaths 组），再手动改选。
      notifier.selectSubject('english');
      final s = container.read(collectProvider);
      expect(s.selectedSubjectId, 'english');
      expect(s.subjectGuessHint, isNull);
    });
  });

  group('handleIncomingPaths', () {
    test('不支持的文件只提示，不建任务、不改状态', () async {
      repo = FakeCollectNotifierRepo();
      container = makeContainer(repo);
      notifier = container.read(collectProvider.notifier);
      await notifier.load();
      final f = await makeTmpFile('a.docx', [1, 2, 3]);
      final notices = <String>[];
      await notifier.handleIncomingPaths([f.path], onNotice: notices.add);
      expect(notices.single, contains('只收 PDF / JPG / PNG'));
      final s = container.read(collectProvider);
      expect(s.stagedPaths, isNull);
      expect(s.pendingImport, isNull);
      expect(repo.savedTasks, isEmpty);
    });

    test('没选学科且猜不出时暂存文件', () async {
      repo = FakeCollectNotifierRepo();
      container = makeContainer(repo);
      notifier = container.read(collectProvider.notifier);
      await notifier.load();
      final f = await makeTmpFile('xyz.png', [1, 2, 3]);
      await notifier.handleIncomingPaths([f.path]);
      final s = container.read(collectProvider);
      expect(s.selectedSubjectId, isNull);
      expect(s.subjectGuessHint, isNull);
      expect(s.stagedPaths, [f.path]);
      expect(s.pendingImport, isNull);
    });

    test('没选学科时按文件名猜学科并进待确认（文件名重复）', () async {
      repo = FakeCollectNotifierRepo(
        tasks: [_task('t1', '数学卷子.png', status: CollectStatus.needBox)],
      );
      container = makeContainer(repo);
      notifier = container.read(collectProvider.notifier);
      await notifier.load();
      final f = await makeTmpFile('数学卷子.png', [1, 2, 3]);
      await notifier.handleIncomingPaths([f.path]);
      final s = container.read(collectProvider);
      // 猜出数学并预填下拉，提示还在；重复文件名进待确认，不暂存。
      expect(s.selectedSubjectId, 'math');
      expect(s.subjectGuessHint, contains('数学'));
      expect(s.stagedPaths, isNull);
      expect(s.pendingImport, isNotNull);
      expect(s.pendingImport!.duplicateNames, ['数学卷子.png']);
    });

    test('已选学科 + 文件名重复进待确认', () async {
      repo = FakeCollectNotifierRepo(
        tasks: [_task('t1', 'a.png', status: CollectStatus.needBox)],
      );
      container = makeContainer(repo);
      notifier = container.read(collectProvider.notifier);
      await notifier.load();
      notifier.selectSubject('math');
      final f = await makeTmpFile('a.png', [1, 2, 3]);
      await notifier.handleIncomingPaths([f.path]);
      final s = container.read(collectProvider);
      expect(s.pendingImport, isNotNull);
      expect(s.pendingImport!.paths, [f.path]);
      expect(s.pendingImport!.duplicateNames, ['a.png']);
      expect(s.pendingImport!.oversizeHints, isEmpty);
    });

    test('已选学科 + 超限图片进待确认（超限横幅）', () async {
      repo = FakeCollectNotifierRepo();
      container = makeContainer(repo);
      notifier = container.read(collectProvider.notifier);
      await notifier.load();
      notifier.selectSubject('math');
      // 21MB 图片（上限 20MB）。
      final f = await makeTmpFile('big.png', List.filled(21 * 1024 * 1024, 0));
      await notifier.handleIncomingPaths([f.path]);
      final s = container.read(collectProvider);
      expect(s.pendingImport, isNotNull);
      expect(s.pendingImport!.oversizeHints.single, contains('超过 20MB 上限'));
      expect(s.pendingImport!.duplicateNames, isEmpty);
    });

    test('同批内容重复只留第一份并提示', () async {
      repo = FakeCollectNotifierRepo(
        tasks: [_task('t1', 'a.png', status: CollectStatus.needBox)],
      );
      container = makeContainer(repo);
      notifier = container.read(collectProvider.notifier);
      await notifier.load();
      notifier.selectSubject('math');
      final f1 = await makeTmpFile('a.png', [1, 2, 3]);
      final f2 = await makeTmpFile('b.png', [1, 2, 3]);
      final notices = <String>[];
      await notifier.handleIncomingPaths(
        [f1.path, f2.path],
        onNotice: notices.add,
      );
      expect(notices.single, contains('只导一份'));
      final s = container.read(collectProvider);
      // 第二份内容相同被丢掉，只留第一份进待确认（文件名重复）。
      expect(s.pendingImport, isNotNull);
      expect(s.pendingImport!.paths, [f1.path]);
    });
  });

  group('startStagedImport / discard', () {
    test('暂存 + 没选学科 → needsSubject，暂存还在', () async {
      repo = FakeCollectNotifierRepo();
      container = makeContainer(repo);
      notifier = container.read(collectProvider.notifier);
      await notifier.load();
      final f = await makeTmpFile('xyz.png', [1, 2, 3]);
      await notifier.handleIncomingPaths([f.path]);
      expect(container.read(collectProvider).stagedPaths, [f.path]);
      final outcome = await notifier.startStagedImport();
      expect(outcome.needsSubject, isTrue);
      expect(container.read(collectProvider).stagedPaths, [f.path]);
    });

    test('暂存 + 已选学科 → 重走检查（重复进待确认，暂存清空）', () async {
      repo = FakeCollectNotifierRepo(
        tasks: [_task('t1', 'xyz.png', status: CollectStatus.needBox)],
      );
      container = makeContainer(repo);
      notifier = container.read(collectProvider.notifier);
      await notifier.load();
      final f = await makeTmpFile('xyz.png', [1, 2, 3]);
      await notifier.handleIncomingPaths([f.path]);
      expect(container.read(collectProvider).stagedPaths, [f.path]);
      notifier.selectSubject('math');
      final outcome = await notifier.startStagedImport();
      expect(outcome.needsSubject, isFalse);
      final s = container.read(collectProvider);
      expect(s.stagedPaths, isNull);
      expect(s.pendingImport, isNotNull);
      expect(s.pendingImport!.duplicateNames, ['xyz.png']);
    });

    test('discardStagedImport / discardPendingImport / dismissBatch 清状态', () async {
      repo = FakeCollectNotifierRepo(
        tasks: [_task('t1', 'a.png', status: CollectStatus.needBox)],
      );
      container = makeContainer(repo);
      notifier = container.read(collectProvider.notifier);
      await notifier.load();
      final f = await makeTmpFile('a.png', [1, 2, 3]);
      await notifier.handleIncomingPaths([f.path]);
      expect(container.read(collectProvider).stagedPaths, [f.path]);
      notifier.discardStagedImport();
      expect(container.read(collectProvider).stagedPaths, isNull);
      notifier.selectSubject('math');
      await notifier.handleIncomingPaths([f.path]);
      expect(container.read(collectProvider).pendingImport, isNotNull);
      notifier.discardPendingImport();
      expect(container.read(collectProvider).pendingImport, isNull);
    });
  });

  group('importFiles / confirmPendingImport', () {
    test('不存在的文件记失败任务、清空已选学科', () async {
      repo = FakeCollectNotifierRepo();
      container = makeContainer(repo);
      notifier = container.read(collectProvider.notifier);
      await notifier.load();
      notifier.selectSubject('math');
      await notifier.importFiles(['/nonexistent/missing.png'], 'math');
      expect(repo.savedTasks.length, 1);
      final failed = repo.savedTasks.single;
      expect(failed.status, CollectStatus.failed);
      expect(failed.error, '文件损坏：找不到这个文件');
      expect(failed.subjectId, 'math');
      final s = container.read(collectProvider);
      expect(s.selectedSubjectId, isNull);
      expect(s.tasks.any((t) => t.id == failed.id), isTrue);
      expect(
        repo.recentTasks.single,
        ('收集', 'math', 'missing.png'),
      );
    });

    test('confirmPendingImport：无待确认时 no-op；有待确认时清掉并导入', () async {
      repo = FakeCollectNotifierRepo(
        tasks: [_task('t1', 'gone.png', status: CollectStatus.needBox)],
      );
      container = makeContainer(repo);
      notifier = container.read(collectProvider.notifier);
      await notifier.load();
      await notifier.confirmPendingImport();
      expect(repo.savedTasks, isEmpty);
      // 不存在的文件也能进待确认（文件名重复判的是任务表，不读盘）；
      // 确认后走 importFiles，不存在 → 记失败任务。
      notifier.selectSubject('english');
      const missing = '/nonexistent/gone.png';
      await notifier.handleIncomingPaths([missing]);
      expect(container.read(collectProvider).pendingImport, isNotNull);
      await notifier.confirmPendingImport();
      expect(container.read(collectProvider).pendingImport, isNull);
      expect(repo.savedTasks.length, 1);
      expect(repo.savedTasks.single.fileName, 'gone.png');
      expect(repo.savedTasks.single.status, CollectStatus.failed);
    });
  });

  group('prepareBoxEditor', () {
    test('页图缺失返回 error，不开编辑器', () async {
      repo = FakeCollectNotifierRepo(
        tasks: [_task('t1', 'a.png', sourcePath: '')],
      );
      container = makeContainer(repo);
      notifier = container.read(collectProvider.notifier);
      await notifier.load();
      final task = container.read(collectProvider).tasks.single;
      final (prep: prep, error: error) = await notifier.prepareBoxEditor(
        task,
      );
      expect(prep, isNull);
      expect(error, contains('页图缺失'));
      // 页图缺失时不置 boxing、不落盘。
      expect(repo.savedTasks, isEmpty);
    });
  });

  group('confirmSplit 早期分支', () {
    test('没有可拆的框 → nothingToSplit（无提示）', () async {
      repo = FakeCollectNotifierRepo(
        tasks: [_task('t1', 'a.png')],
      );
      container = makeContainer(repo);
      notifier = container.read(collectProvider.notifier);
      await notifier.load();
      final task = container.read(collectProvider).tasks.single;
      final outcome = await notifier.confirmSplit(task, {1: const []}, {});
      expect(outcome.kind, ConfirmSplitKind.nothingToSplit);
      expect(outcome.message, isNull);
    });

    test('有框的页都已拆过 → nothingToSplit 带“已经拆成题了”提示', () async {
      repo = FakeCollectNotifierRepo(
        tasks: [
          _task('t1', 'a.png', sourcePath: 'imports/t1/x.png'),
          _task(
            't1-split',
            'a.png',
            status: CollectStatus.pendingOrganize,
            sourcePath: 'imports/t1/x.png',
          ),
        ],
      );
      container = makeContainer(repo);
      notifier = container.read(collectProvider.notifier);
      await notifier.load();
      final task = container
          .read(collectProvider)
          .tasks
          .singleWhere((t) => t.id == 't1');
      final outcome = await notifier.confirmSplit(task, {
        1: [_box('b1', page: 1)],
      }, {});
      expect(outcome.kind, ConfirmSplitKind.nothingToSplit);
      expect(outcome.message, '这些页已经拆成题了，不用再拆');
    });

    test('还有未框页 → needsUnboxedConfirm（未确认时不写任何东西）', () async {
      repo = FakeCollectNotifierRepo(
        tasks: [_task('t1', 'a.png', pageCount: 2)],
      );
      container = makeContainer(repo);
      notifier = container.read(collectProvider.notifier);
      await notifier.load();
      final task = container.read(collectProvider).tasks.single;
      final outcome = await notifier.confirmSplit(task, {
        1: [_box('b1', page: 1)],
      }, {});
      expect(outcome.kind, ConfirmSplitKind.needsUnboxedConfirm);
      expect(outcome.unboxedPages, [2]);
      expect(outcome.boxedPages, 1);
      expect(outcome.total, 1);
      expect(repo.savedTasks, isEmpty);
    });
  });

  group('deleteTask / saveDraftBoxes', () {
    test('deleteTask 删库并重读', () async {
      repo = FakeCollectNotifierRepo(
        tasks: [
          _task('t1', 'a.png'),
          _task('t2', 'b.png'),
        ],
      );
      container = makeContainer(repo);
      notifier = container.read(collectProvider.notifier);
      await notifier.load();
      final t1 = container
          .read(collectProvider)
          .tasks
          .singleWhere((t) => t.id == 't1');
      await notifier.deleteTask(t1);
      expect(repo.deletedIds, ['t1']);
      expect(
        container.read(collectProvider).tasks.map((t) => t.id),
        ['t2'],
      );
    });

    test('saveDraftBoxes 交给 repo', () async {
      repo = FakeCollectNotifierRepo();
      container = makeContainer(repo);
      notifier = container.read(collectProvider.notifier);
      await notifier.saveDraftBoxes('t1', {
        1: [_box('b1', page: 1)],
      }, {});
      expect(repo.draftSavedTaskIds, ['t1']);
      expect(repo.boxesByTask['t1']!.single.id, 'b1');
    });
  });

  group('纯函数', () {
    test('splitPagesFor 只认同 sourcePath 的待整理/已整理拆分任务', () {
      final tasks = [
        _task('t1', 'a.png', sourcePath: 'imports/t1/x.png'),
        _task(
          's1',
          'a.png',
          status: CollectStatus.pendingOrganize,
          sourcePath: 'imports/t1/x.png',
        ),
        _task(
          's2',
          'a.png',
          status: CollectStatus.done,
          page: 2,
          sourcePath: 'imports/t1/x.png',
        ),
        _task(
          's3',
          'a.png',
          status: CollectStatus.needBox,
          page: 3,
          sourcePath: 'imports/t1/x.png',
        ),
        _task(
          'other',
          'a.png',
          status: CollectStatus.pendingOrganize,
          sourcePath: 'imports/other/x.png',
        ),
      ];
      expect(splitPagesFor(tasks, tasks.first), {1, 2});
    });

    test('pageListText / noBoxWarningText / taskNote', () {
      expect(pageListText([1, 2]), '1、2');
      expect(pageListText([1, 2, 3, 4, 5, 6]), '1、2、3、4、5 等');
      final single = _task('t1', 'a.png');
      expect(noBoxWarningText(single, [1]), '这张图还没有框');
      final multi = _task('t1', 'a.png', pageCount: 3);
      expect(noBoxWarningText(multi, [2, 3]), '还有 2 页没有框：第 2、3 页');
      expect(noBoxWarningText(multi, [1, 2, 3]), '这份文件还有 3 页没有框');
      expect(
        taskNote(_task('t1', 'a.png', status: CollectStatus.needBox), '数学'),
        '检测完成，等你修框确认 · 数学 · 第1页',
      );
    });
  });
}
