// Win11 后续修复 Round 3 Stream C：confirmSplit 竞态（Q4 §1.8）。
//
// confirmSplit 先写切片/烘焙图、后提交事务；窗口期内新文件在盘上存在、
// 库里无任何行引用它。修法：写盘前 registerPending，事务提交成功后解除；
// 失败路径先按清单删文件、再解除登记（与 figure_files 回滚同款顺序）。
//
// 本文件不用 widget：直接驱动 CollectNotifier + 可阻塞的 confirmSplit
// 桩，造出“写盘已完成、事务尚未提交”的确定性窗口，并在窗口内调真实
// 孤儿删除入口验证 pending 保护。
//
// 注意：预览扫描 scanOrphanFilesFromImpl 本身不查 pending（它只产候选
// 清单），真正的保护在删除时——deleteOrphanFilesImpl 在锁内重算引用并
// 查 pending，命中即跳过。所以本文件断言删除入口的行为，而不是扫描
// 清单；pending 集本身的成员关系另行直接断言。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/file_lifecycle_guard.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/collect_notifier.dart';
import 'package:quiz_master2/state/repository_provider.dart';

Uint8List _pagePngBytes() {
  final image = img.Image(width: 560, height: 700);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  return img.encodePng(image);
}

QuestionBox _box(String id) => QuestionBox(
  id: id,
  layer: 1,
  type: 'question',
  x: 0.1,
  y: 0.1,
  w: 0.5,
  h: 0.2,
  page: 1,
);

/// confirmSplit 桩：可阻塞（造写盘/事务窗口）或直接抛错（事务失败）。
class _BlockingSplitRepo extends QuestionRepository {
  _BlockingSplitRepo(this.tasks) : super(AppDatabase.instance);

  List<CollectTask> tasks;
  bool shouldThrow = false;

  final entered = Completer<void>();
  final release = Completer<void>();
  List<Question>? capturedQuestions;
  List<CollectTask>? capturedSplitTasks;

  @override
  Future<List<CollectTask>> collectTasks() async => List.of(tasks);

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<List<QuestionBox>> boxesForTask(String taskId) async => const [];

  @override
  Future<void> saveCollectTask(CollectTask t) async {}

  @override
  Future<void> saveRecentTask({
    required String kind,
    required String subjectId,
    required String title,
  }) async {}

  @override
  Future<void> confirmSplit({
    required CollectTask originalTask,
    required List<Question> questions,
    required List<CollectTask> splitTasks,
    required Map<String, List<QuestionBox>> boxesByQuestionId,
    CollectTask? retainedTask,
    Map<int, List<QuestionBox>> retainedBoxesByPage = const {},
  }) async {
    capturedQuestions = List.of(questions);
    capturedSplitTasks = List.of(splitTasks);
    if (!entered.isCompleted) entered.complete();
    if (shouldThrow) throw StateError('事务失败（测试桩）');
    await release.future;
  }
}

void main() {
  late Directory tmpDir;
  late QuizDatabase db;
  late _BlockingSplitRepo repo;
  late ProviderContainer container;
  late CollectNotifier notifier;

  /// 单页 PDF 任务：第 1 页旋转 90°，确认时会新写一张烘焙图 + 1 个切片。
  CollectTask pdfTask() => CollectTask(
    id: 't-pdf',
    name: '卷.pdf',
    fileName: '卷.pdf',
    subjectId: 'math',
    status: CollectStatus.needBox,
    progress: 100,
    pageCount: 1,
    page: 1,
    createdAt: DateTime(2026, 11, 20),
    sourcePath: 'imports/t-pdf/source.pdf',
    pageRotations: const {1: 90},
  );

  Future<void> setUpNotifier({
    required bool corruptPage,
    required bool txnShouldThrow,
  }) async {
    tmpDir = await Directory.systemTemp.createTemp('qm2-r3-confirm-split-');
    AppDatabase.testDataDirectory = tmpDir.path;
    final pagesDir = Directory(p.join(tmpDir.path, 'imports', 't-pdf', 'pages'));
    await pagesDir.create(recursive: true);
    final pageFile = File(p.join(pagesDir.path, 'page-001.png'));
    if (corruptPage) {
      await pageFile.writeAsBytes(const [0, 1, 2, 3, 4, 5]);
    } else {
      await pageFile.writeAsBytes(_pagePngBytes());
    }
    db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(db);
    FileLifecycleGuard.instance.debugClearPendingForTest();
    FileLifecycleGuard.instance.debugClearStagingForTest();
    repo = _BlockingSplitRepo([pdfTask()]);
    repo.shouldThrow = txnShouldThrow;
    container = ProviderContainer.test(
      overrides: [repositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    container.listen(collectProvider, (_, __) {});
    notifier = container.read(collectProvider.notifier);
    await notifier.load();
  }

  tearDown(() async {
    FileLifecycleGuard.instance.debugClearPendingForTest();
    FileLifecycleGuard.instance.debugClearStagingForTest();
    await AppDatabase.resetForTest();
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  test('窗口内：切片与烘焙图在 pending 集里，孤儿删除跳过它们；提交后登记解除', () async {
    await setUpNotifier(corruptPage: false, txnShouldThrow: false);
    final task = container.read(collectProvider).tasks.single;

    // 不 await：confirmSplit 会在桩的 release 处挂起，停在“写盘已完成、
    // 事务尚未提交”的窗口里。
    final future = notifier.confirmSplit(task, {
      1: [_box('b1')],
    }, {1: 90});
    await repo.entered.future.timeout(const Duration(seconds: 10));

    final sliceRel = repo.capturedQuestions!.single.slicePath!;
    final bakedRel = repo.capturedQuestions!.single.pageImagePath!;
    expect(bakedRel, 'imports/t-pdf/pages/page-1-r90.png');
    expect(File(p.join(tmpDir.path, sliceRel)).existsSync(), isTrue);
    expect(File(p.join(tmpDir.path, bakedRel)).existsSync(), isTrue);

    // 窗口期内：两条新路径都在 pending 集里（库里尚无题行引用它们）。
    final pending = FileLifecycleGuard.instance.pendingSnapshot;
    expect(pending, contains(sliceRel));
    expect(pending, contains(bakedRel));

    // 真实孤儿删除入口（锁内重算引用 + 查 pending）：两条都必须跳过，
    // 一条也不得移入回收站。注意：本用例的真实库里没有任务行/题行，
    // 两条路径没有任何数据库引用——跳过只能来自 pending 登记，
    // 这正是要证明的保护（生产上烘焙图另有 pages/ 枚举兜底，切片没有）。
    final result = await deleteOrphanFilesImpl(
      [sliceRel, bakedRel],
      db: db,
      dataDir: tmpDir.path,
    );
    expect(result.deletedCount, 0);
    expect(result.skippedReferencedCount, 2);
    expect(File(p.join(tmpDir.path, sliceRel)).existsSync(), isTrue);
    expect(File(p.join(tmpDir.path, bakedRel)).existsSync(), isTrue);

    // 放行事务：提交成功后登记解除，文件仍在。
    repo.release.complete();
    final outcome = await future.timeout(const Duration(seconds: 10));
    expect(outcome.kind, ConfirmSplitKind.done);
    expect(FileLifecycleGuard.instance.pendingSnapshot, isEmpty);
    expect(File(p.join(tmpDir.path, sliceRel)).existsSync(), isTrue);
    expect(File(p.join(tmpDir.path, bakedRel)).existsSync(), isTrue);
  });

  test('事务失败：新写的文件被清掉，pending 登记不泄漏', () async {
    await setUpNotifier(corruptPage: false, txnShouldThrow: true);
    final task = container.read(collectProvider).tasks.single;

    final outcome = await notifier.confirmSplit(task, {
      1: [_box('b1')],
    }, {1: 90});
    expect(outcome.kind, ConfirmSplitKind.saveFailed);
    expect(repo.capturedQuestions, hasLength(1));
    final sliceRel = repo.capturedQuestions!.single.slicePath!;
    final bakedRel = repo.capturedQuestions!.single.pageImagePath!;
    expect(File(p.join(tmpDir.path, sliceRel)).existsSync(), isFalse);
    expect(File(p.join(tmpDir.path, bakedRel)).existsSync(), isFalse);
    expect(FileLifecycleGuard.instance.pendingSnapshot, isEmpty);
  });

  test('写盘失败（第 1 页裁剪失败）：已登记的烘焙图随清理解除，pending 不泄漏', () async {
    await setUpNotifier(corruptPage: true, txnShouldThrow: false);
    final task = container.read(collectProvider).tasks.single;

    final outcome = await notifier.confirmSplit(task, {
      1: [_box('b1')],
    }, {1: 90});
    expect(outcome.kind, ConfirmSplitKind.sliceFailed);
    expect(repo.entered.isCompleted, isFalse);
    final slicesDir = Directory(p.join(tmpDir.path, 'slices'));
    expect(
      !slicesDir.existsSync() || slicesDir.listSync().isEmpty,
      isTrue,
    );
    expect(
      File(
        p.join(tmpDir.path, 'imports', 't-pdf', 'pages', 'page-1-r90.png'),
      ).existsSync(),
      isFalse,
    );
    expect(FileLifecycleGuard.instance.pendingSnapshot, isEmpty);
  });
}
