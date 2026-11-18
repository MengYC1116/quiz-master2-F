// 十二批功能 7（D-91）：失败任务原地重试（同一任务行/id）的回归测试。
//
// 覆盖 GPT 8 点（启动恢复已由 b12_schema_v3_migration_test 覆盖，
// 这里不重写）：
// - 同 id 保留（failed → needBox，只有一行，字段保留）；
// - enqueue 存哈希（导入时算 SHA-256 存行，进度写库不抹哈希）；
// - 原文件被删 → 明确报错、无新任务；
// - 原文件被替换 → 指纹不一致拒绝、清 sourcePath；
// - 多个原文件 → 拒绝、两个候选一个不少；
// - 并发双重试 → 管线只跑一次（假引擎 open 计数）；
// - 非法重试（needBox 任务）→ 拒绝、任务不变；
// - 重试再失败 → 仍 failed、带新原因、仍可重试；
// - 成功后重试 → 拒绝；
// - 图片重试走抽出的 _importImage 管线；
// - sourceHash 为 NULL（v2 旧行）时拒绝重试（D-99，GPT P1-01），
//   拒绝后再次点击仍拒绝；算不出哈希时同样拒绝；
// - Notifier.retryFailedTask：非法重试走 error 文案、成功重读、
//   重试中标志事后摘掉；NULL hash 拒绝经 Notifier 返回原句文案；
// - 收集页：失败行有“重试”按钮、needBox 行没有；点重试后行变待框选。
//
// 写法铁律（D-45）：库在测试体内建、直接 await；service/notifier
// 部分不用 testWidgets；内存库 + 临时数据目录，不碰真实演示库。
// 渲染用注入的假引擎（不碰 PDFium）；图片用 test_fixtures 的固件。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/collect/collect_page.dart';
import 'package:quiz_master2/services/import_guess.dart';
import 'package:quiz_master2/services/import_service.dart';
import 'package:quiz_master2/services/pdf_render_service.dart';
import 'package:quiz_master2/state/collect_notifier.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';

import 'test_fixtures.dart';

late final Directory _tmp;

Future<void> openMemoryDb() async {
  final db = await AppDatabase.openForTest();
  AppDatabase.useDatabaseForTest(db);
  addTearDown(() async => db.close());
}

/// 渲染必成的假引擎：1 页，返回 10×10 红色 PNG（不碰 PDFium）。
class _OkDoc implements PdfEngineDocument {
  @override
  int get pageCount => 1;

  @override
  Future<PdfPageRender> renderPage(
    int page, {
    required int targetLongEdge,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 10, 10),
      ui.Paint()..color = const ui.Color(0xFFFF0000),
    );
    final img = await recorder.endRecording().toImage(10, 10);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return PdfPageRender(
      png: data!.buffer.asUint8List(),
      width: 10,
      height: 10,
    );
  }

  @override
  Future<void> close() async {}
}

class _OkEngine implements PdfEngine {
  @override
  Future<PdfEngineDocument> open(String path) async => _OkDoc();
}

/// 渲染即抛 FileSystemException 的假文档（模拟渲染中途磁盘满）。
class _RenderFailDoc implements PdfEngineDocument {
  @override
  int get pageCount => 2;

  @override
  Future<PdfPageRender> renderPage(
    int page, {
    required int targetLongEdge,
  }) async {
    throw FileSystemException('磁盘已满，写不进去', 'page-001.png');
  }

  @override
  Future<void> close() async {}
}

class _RenderFailEngine implements PdfEngine {
  @override
  Future<PdfEngineDocument> open(String path) async => _RenderFailDoc();
}

/// 第一次渲染失败、之后成功的假文档（模拟“失败后凭原图重试成功”）。
class _FlakyDoc implements PdfEngineDocument {
  static var _failedOnce = false;

  static void reset() => _failedOnce = false;

  @override
  int get pageCount => 1;

  @override
  Future<PdfPageRender> renderPage(
    int page, {
    required int targetLongEdge,
  }) async {
    if (!_failedOnce) {
      _failedOnce = true;
      throw FileSystemException('磁盘已满，写不进去', 'page-001.png');
    }
    return _OkDoc().renderPage(page, targetLongEdge: targetLongEdge);
  }

  @override
  Future<void> close() async {}
}

class _FlakyEngine implements PdfEngine {
  @override
  Future<PdfEngineDocument> open(String path) async => _FlakyDoc();
}

/// 计数 + 慢开的假引擎：open 每次计数并等一会，让两次并发重试
/// 在第一条管线还没跑完时撞上；单次管线 open 两次（pageCount 一次、
/// renderAllPagesToDir 一次），跑两次就是四次。
class _CountingEngine implements PdfEngine {
  var opens = 0;

  @override
  Future<PdfEngineDocument> open(String path) async {
    opens++;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return _OkDoc();
  }
}

ImportService _service({PdfEngine? engine}) => ImportService(
  AppDatabase.instance,
  pdfRenderService: engine == null ? null : PdfRenderService(engine: engine),
);

PdfRenderService _pdfService(PdfEngine engine) =>
    PdfRenderService(engine: engine);

/// 种子一个失败任务行 + 库内原图文件（`imports/<id>/original.<ext>`）。
/// [storedBytes] 是库内原图内容；[sourceHash] 不传时按库内原图现内容算
///（与导入时存的哈希一致）；显式传 null 表示 v2 旧行（无哈希基线）。
Future<CollectTask> _seedFailedTask({
  required String id,
  required String fileName,
  required List<int> storedBytes,
  String? sourceHash = _useStoredHash,
  String error = '导入失败：渲染这份 PDF 时出了问题',
  String subjectId = 'math',
}) async {
  final ext = fileName.split('.').last.toLowerCase();
  final dir = Directory(
    AppDatabase.resolveDataPath(ImportService.taskDirRelative(id))!,
  );
  await dir.create(recursive: true);
  final stored = File('${dir.path}/original.$ext');
  await stored.writeAsBytes(storedBytes);
  final hash = sourceHash == _useStoredHash
      ? await sha256HexOfFile(stored)
      : sourceHash;
  final task = CollectTask(
    id: id,
    name: '$fileName · 第1页 · 第1题',
    fileName: fileName,
    subjectId: subjectId,
    status: CollectStatus.failed,
    error: error,
    createdAt: DateTime(2026, 11, 17, 10, 30),
    sourcePath: ImportService.originalRelative(id, ext),
    sourceHash: hash,
  );
  await AppDatabase.instance.upsertCollectTask(task);
  return task;
}

/// [_seedFailedTask] 的 sourceHash 哨兵：用库内原图现内容算哈希。
const _useStoredHash = '__useStoredHash__';

Future<List<CollectTask>> _allTasks() =>
    AppDatabase.instance.allCollectTasks();

/// Notifier 测试容器：真实库 + 真实 QuestionRepository（load 读库）。
/// autoDispose 下持一个监听保活（collect_notifier_test 同款）。
ProviderContainer _notifierContainer() {
  final container = ProviderContainer.test(
    overrides: [
      repositoryProvider.overrideWithValue(
        QuestionRepository(AppDatabase.instance),
      ),
    ],
  );
  final sub = container.listen(collectProvider, (_, _) {});
  addTearDown(sub.close);
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpRetryPage(
  WidgetTester tester, {
  PdfEngine? engine,
  required QuestionRepository repo,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: CollectPage(
          repo: repo,
          onOpenOrganize: () {},
          pdfRenderService: engine == null
              ? null
              : PdfRenderService(engine: engine),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// widget 测试用的最小 FakeRepo（collect_page_test 同款口径）：
/// 页面列表走它（fake 区可完成）；重试的 service 走它底下的真库
///（`super(AppDatabase.instance)`，测试体内已指到内存库），与
///页面列表无关——重试成功后库里行已翻 needBox，页面重进重读即见。
class _PageFakeRepo extends QuestionRepository {
  _PageFakeRepo(this.tasks) : super(AppDatabase.instance);

  List<CollectTask> tasks;

  @override
  Future<List<CollectTask>> collectTasks() async => List.of(tasks);

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<List<QuestionBox>> boxesForTask(String taskId) async => const [];
}

void main() {
  setUpAll(() async {
    _tmp = await Directory.systemTemp.createTemp('qm2-b12-retry');
    AppDatabase.testDataDirectory = _tmp.path;
  });

  tearDownAll(() async {
    AppDatabase.testDataDirectory = null;
    await _tmp.delete(recursive: true);
  });

  group('service：enqueue 存哈希', () {
    test('PDF 导入成功后行里有原文件 SHA-256，进度写库不抹哈希', () async {
      await openMemoryDb();
      final pdf = File('${_tmp.path}/hash-me.pdf');
      final bytes = List.generate(2000, (i) => i % 251);
      await pdf.writeAsBytes(bytes);
      final tasks = await _service(
        engine: _OkEngine(),
      ).enqueue([pdf.path], subjectId: 'math');
      expect(tasks.length, 1);
      expect(tasks.first.status, CollectStatus.needBox);
      final stored = await _allTasks();
      expect(stored.length, 1);
      // 渲染中途多次 _updateProgress 全列写回，哈希必须还在。
      expect(stored.first.sourceHash, await sha256HexOfFile(pdf));
      expect(stored.first.sourceHash, isNotNull);
    });

    test('图片导入成功后行里也有哈希', () async {
      await openMemoryDb();
      final photo = await writeFixtureFile(
        _tmp,
        'hash-photo.jpg',
        photoFixtureBytes(),
      );
      final tasks = await _service().enqueue([photo.path], subjectId: 'math');
      expect(tasks.length, 1);
      expect(tasks.first.status, CollectStatus.needBox);
      final stored = await _allTasks();
      expect(stored.first.sourceHash, await sha256HexOfFile(photo));
    });
  });

  group('service：原地重试', () {
    test('同 id 保留：failed → needBox，只有一行，字段保留', () async {
      await openMemoryDb();
      _FlakyDoc.reset();
      final pdf = File('${_tmp.path}/same-id.pdf');
      await pdf.writeAsBytes(List.generate(2000, (i) => i % 251));
      final first = await _service(
        engine: _FlakyEngine(),
      ).enqueue([pdf.path], subjectId: 'math');
      expect(first.length, 1);
      final failed = first.first;
      expect(failed.status, CollectStatus.failed);
      expect(failed.sourceHash, isNotNull);

      final retried = await _service(
        engine: _OkEngine(),
      ).retryFromStoredOriginal(failed);
      expect(retried.status, CollectStatus.needBox);
      expect(retried.id, failed.id);
      // 重置后恢复：progress 0 → 100、error 清空，其余保留。
      expect(retried.progress, 100);
      expect(retried.error, isNull);
      expect(retried.createdAt, failed.createdAt);
      expect(retried.name, failed.name);
      expect(retried.fileName, failed.fileName);
      expect(retried.subjectId, failed.subjectId);
      expect(retried.sourcePath, failed.sourcePath);
      expect(retried.sourceHash, failed.sourceHash);
      final after = await _allTasks();
      expect(after.length, 1);
      expect(after.first.id, failed.id);
      expect(after.first.status, CollectStatus.needBox);
      expect(after.first.sourceHash, failed.sourceHash);
      expect(
        File(
          AppDatabase.resolveDataPath(
            ImportService.renderedPageRelative(retried.id, 1),
          )!,
        ).existsSync(),
        isTrue,
      );
    });

    test('原文件被删：明确报错、无新任务', () async {
      await openMemoryDb();
      final task = await _seedFailedTask(
        id: 'task-retry-gone',
        fileName: 'gone.pdf',
        storedBytes: [1, 2, 3],
      );
      // 删掉库内原图（连同任务目录），模拟原文件丢失。
      await Directory(
        AppDatabase.resolveDataPath(
          ImportService.taskDirRelative(task.id),
        )!,
      ).delete(recursive: true);

      final retried = await _service().retryFromStoredOriginal(task);
      expect(retried.status, CollectStatus.failed);
      expect(retried.error, contains('找不到原来导入的文件'));
      expect(retried.error, contains('重新提供原文件'));
      expect(retried.sourcePath, isEmpty);
      final after = await _allTasks();
      expect(after.length, 1);
      expect(after.first.id, task.id);
      expect(after.first.status, CollectStatus.failed);
      expect(after.first.sourcePath, isEmpty);
    });

    test('原文件被替换：指纹不一致拒绝、清 sourcePath、原文件不动', () async {
      await openMemoryDb();
      final originalBytes = List.generate(2000, (i) => i % 251);
      final task = await _seedFailedTask(
        id: 'task-retry-replaced',
        fileName: 'replaced.pdf',
        storedBytes: originalBytes,
      );
      // 库内原图被换成另一份内容（同路径、不同哈希）。
      final stored = File(
        AppDatabase.resolveDataPath(task.sourcePath)!,
      );
      await stored.writeAsBytes(List.generate(2000, (i) => (i + 7) % 251));

      final retried = await _service(
        engine: _OkEngine(),
      ).retryFromStoredOriginal(task);
      expect(retried.status, CollectStatus.failed);
      expect(retried.error, contains('原文件已被替换或改动'));
      expect(retried.error, contains('重新提供原文件'));
      expect(retried.sourcePath, isEmpty);
      // 被换的文件本身不动（不删用户文件，只清引用）。
      expect(stored.existsSync(), isTrue);
      final after = await _allTasks();
      expect(after.length, 1);
      expect(after.first.sourcePath, isEmpty);
      expect(after.first.sourceHash, task.sourceHash);
    });

    test('多个原文件：拒绝、两个候选一个不少、引用保留', () async {
      await openMemoryDb();
      final task = await _seedFailedTask(
        id: 'task-retry-multi',
        fileName: 'multi.pdf',
        storedBytes: [1, 2, 3],
        sourceHash: null,
      );
      final dir = Directory(
        AppDatabase.resolveDataPath(
          ImportService.taskDirRelative(task.id),
        )!,
      );
      final extra = File('${dir.path}/original.jpg')
        ..writeAsBytesSync([9, 9, 9]);
      expect(
        ImportService.locateStoredOriginals(task.id),
        hasLength(2),
      );

      final retried = await _service().retryFromStoredOriginal(task);
      expect(retried.status, CollectStatus.failed);
      expect(retried.error, contains('多个原文件'));
      expect(retried.error, contains('重新提供原文件'));
      expect(extra.existsSync(), isTrue);
      expect(
        File(AppDatabase.resolveDataPath(task.sourcePath)!).existsSync(),
        isTrue,
      );
      // sourcePath 仍指向真实存在的文件，保留不动。
      expect(retried.sourcePath, task.sourcePath);
    });

    test('并发双重试：管线只跑一次', () async {
      await openMemoryDb();
      final engine = _CountingEngine();
      final task = await _seedFailedTask(
        id: 'task-retry-twice',
        fileName: 'twice.pdf',
        storedBytes: List.generate(2000, (i) => i % 251),
      );
      final service = _service(engine: engine);
      final results = await Future.wait([
        service.retryFromStoredOriginal(task),
        service.retryFromStoredOriginal(task),
      ]);
      expect(results[0].status, CollectStatus.needBox);
      expect(results[1].status, CollectStatus.needBox);
      expect(results[0].id, task.id);
      expect(results[1].id, task.id);
      // 单次管线 open 两次（pageCount + renderAll）；跑两次就是四次。
      expect(engine.opens, 2);
      final after = await _allTasks();
      expect(after.length, 1);
      expect(after.first.status, CollectStatus.needBox);
    });

    test('非法重试：needBox 任务拒绝、任务不变', () async {
      await openMemoryDb();
      final task = CollectTask(
        id: 'task-retry-illegal',
        name: 'ok.pdf · 第1页 · 第1题',
        fileName: 'ok.pdf',
        subjectId: 'math',
        status: CollectStatus.needBox,
        progress: 100,
        pageCount: 1,
        page: 1,
        sourcePath: 'imports/task-retry-illegal/original.pdf',
      );
      await AppDatabase.instance.upsertCollectTask(task);
      await expectLater(
        _service(engine: _OkEngine()).retryFromStoredOriginal(task),
        throwsStateError,
      );
      final after = await _allTasks();
      expect(after.length, 1);
      expect(after.first.status, CollectStatus.needBox);
      expect(after.first.progress, 100);
    });

    test('重试再失败：仍 failed、带新原因、仍可重试', () async {
      await openMemoryDb();
      final task = await _seedFailedTask(
        id: 'task-retry-again',
        fileName: 'again.pdf',
        storedBytes: List.generate(2000, (i) => i % 251),
        error: '第一次失败：渲染这份 PDF 时出了问题',
      );
      final first = await _service(
        engine: _RenderFailEngine(),
      ).retryFromStoredOriginal(task);
      expect(first.status, CollectStatus.failed);
      expect(first.id, task.id);
      expect(first.error, contains('渲染'));
      expect(first.error, isNot('第一次失败：渲染这份 PDF 时出了问题'));
      // 失败行 sourcePath 仍指向真实存在的原图，可再重试。
      expect(first.sourcePath, task.sourcePath);
      final mid = await _allTasks();
      expect(mid.length, 1);
      expect(mid.first.status, CollectStatus.failed);

      final second = await _service(
        engine: _OkEngine(),
      ).retryFromStoredOriginal(mid.first);
      expect(second.status, CollectStatus.needBox);
      expect(second.id, task.id);
      expect((await _allTasks()).length, 1);
    });

    test('成功后重试：拒绝、任务不变', () async {
      await openMemoryDb();
      final task = await _seedFailedTask(
        id: 'task-retry-done',
        fileName: 'done.pdf',
        storedBytes: List.generate(2000, (i) => i % 251),
      );
      final ok = await _service(
        engine: _OkEngine(),
      ).retryFromStoredOriginal(task);
      expect(ok.status, CollectStatus.needBox);
      await expectLater(
        _service(engine: _OkEngine()).retryFromStoredOriginal(ok),
        throwsStateError,
      );
      final after = await _allTasks();
      expect(after.length, 1);
      expect(after.first.status, CollectStatus.needBox);
      expect(after.first.id, task.id);
    });

    test('图片重试：走抽出的 _importImage 管线，同 id 进 needBox', () async {
      await openMemoryDb();
      final photoBytes = photoFixtureBytes();
      final task = await _seedFailedTask(
        id: 'task-retry-photo',
        fileName: 'photo.jpg',
        storedBytes: photoBytes,
        error: '导入失败：这张图片导进来了，但写不进任务列表',
      );
      final retried = await _service().retryFromStoredOriginal(task);
      expect(retried.status, CollectStatus.needBox);
      expect(retried.id, task.id);
      expect(retried.pageCount, 1);
      final after = await _allTasks();
      expect(after.length, 1);
      expect(after.first.sourceHash, task.sourceHash);
    });

    test('sourceHash 为 NULL（v2 旧行）：拒绝重试，D-99', () async {
      await openMemoryDb();
      final task = await _seedFailedTask(
        id: 'task-retry-legacy',
        fileName: 'legacy.pdf',
        storedBytes: List.generate(2000, (i) => i % 251),
        sourceHash: null,
      );
      expect(task.sourceHash, isNull);
      final retried = await _service(
        engine: _OkEngine(),
      ).retryFromStoredOriginal(task);
      // 拒绝：仍是 failed、同 id、文案一字不改（GPT P1-01 建议原句）。
      expect(retried.status, CollectStatus.failed);
      expect(retried.id, task.id);
      expect(
        retried.error,
        '旧任务缺少原文件校验信息，请重新导入原文件',
      );
      // 无法验证不是已证伪：原文件不动，sourcePath 引用保留。
      expect(
        File(AppDatabase.resolveDataPath(task.sourcePath)!).existsSync(),
        isTrue,
      );
      expect(retried.sourcePath, task.sourcePath);
      final after = await _allTasks();
      expect(after.length, 1);
      expect(after.first.status, CollectStatus.failed);
      expect(after.first.id, task.id);
      expect(after.first.sourceHash, isNull);
      expect(after.first.sourcePath, task.sourcePath);
      expect(
        after.first.error,
        '旧任务缺少原文件校验信息，请重新导入原文件',
      );
    });

    test('sourceHash 为 NULL：拒绝后再次点击仍拒绝', () async {
      await openMemoryDb();
      final task = await _seedFailedTask(
        id: 'task-retry-legacy-again',
        fileName: 'legacy-again.pdf',
        storedBytes: List.generate(2000, (i) => i % 251),
        sourceHash: null,
      );
      final first = await _service(
        engine: _OkEngine(),
      ).retryFromStoredOriginal(task);
      expect(first.status, CollectStatus.failed);
      expect(
        first.error,
        '旧任务缺少原文件校验信息，请重新导入原文件',
      );
      // 用库里拒绝后的行再点一次：同样拒绝，不会变成“成功”。
      final mid = await _allTasks();
      expect(mid.length, 1);
      expect(mid.first.status, CollectStatus.failed);
      final second = await _service(
        engine: _OkEngine(),
      ).retryFromStoredOriginal(mid.first);
      expect(second.status, CollectStatus.failed);
      expect(second.id, task.id);
      expect(
        second.error,
        '旧任务缺少原文件校验信息，请重新导入原文件',
      );
      expect(second.sourcePath, task.sourcePath);
      final after = await _allTasks();
      expect(after.length, 1);
      expect(after.first.status, CollectStatus.failed);
      expect(
        File(AppDatabase.resolveDataPath(task.sourcePath)!).existsSync(),
        isTrue,
      );
    });
  });

  group('notifier：retryFailedTask', () {
    test('非法重试：返回 error 文案、任务不动', () async {
      await openMemoryDb();
      final task = CollectTask(
        id: 'task-notifier-illegal',
        name: 'ok.pdf · 第1页 · 第1题',
        fileName: 'ok.pdf',
        subjectId: 'math',
        status: CollectStatus.needBox,
        progress: 100,
        sourcePath: 'imports/task-notifier-illegal/original.pdf',
      );
      await AppDatabase.instance.upsertCollectTask(task);
      final container = _notifierContainer();
      final notifier = container.read(collectProvider.notifier);
      await notifier.load();
      final outcome = await notifier.retryFailedTask(task);
      expect(outcome.task, isNull);
      expect(outcome.error, contains('只有导入失败的任务可以重试'));
      expect(container.read(collectProvider).retryingTaskIds, isEmpty);
      final after = await _allTasks();
      expect(after.length, 1);
      expect(after.first.status, CollectStatus.needBox);
    });

    test('成功：返回 needBox 行、重读后列表同 id、重试标志摘掉', () async {
      await openMemoryDb();
      final task = await _seedFailedTask(
        id: 'task-notifier-ok',
        fileName: 'notifier.pdf',
        storedBytes: List.generate(2000, (i) => i % 251),
      );
      final container = _notifierContainer();
      final notifier = container.read(collectProvider.notifier);
      await notifier.load();
      final outcome = await notifier.retryFailedTask(
        task,
        pdfRenderService: _pdfService(_OkEngine()),
      );
      expect(outcome.error, isNull);
      expect(outcome.task?.status, CollectStatus.needBox);
      expect(outcome.task?.id, task.id);
      final state = container.read(collectProvider);
      expect(state.retryingTaskIds, isEmpty);
      expect(state.tasks.length, 1);
      expect(state.tasks.first.id, task.id);
      expect(state.tasks.first.status, CollectStatus.needBox);
    });

    test('sourceHash 为 NULL：Notifier 返回拒绝文案、行仍 failed、仍可再点', () async {
      await openMemoryDb();
      final task = await _seedFailedTask(
        id: 'task-notifier-legacy',
        fileName: 'notifier-legacy.pdf',
        storedBytes: List.generate(2000, (i) => i % 251),
        sourceHash: null,
      );
      final container = _notifierContainer();
      final notifier = container.read(collectProvider.notifier);
      await notifier.load();
      final outcome = await notifier.retryFailedTask(task);
      expect(outcome.task?.status, CollectStatus.failed);
      expect(
        outcome.error,
        '旧任务缺少原文件校验信息，请重新导入原文件',
      );
      expect(container.read(collectProvider).retryingTaskIds, isEmpty);
      expect(container.read(collectProvider).tasks.length, 1);
      expect(
        container.read(collectProvider).tasks.first.status,
        CollectStatus.failed,
      );
      // 再点一次：同样拒绝，不会翻成成功，按钮仍在。
      final again = await notifier.retryFailedTask(
        container.read(collectProvider).tasks.first,
      );
      expect(again.task?.status, CollectStatus.failed);
      expect(
        again.error,
        '旧任务缺少原文件校验信息，请重新导入原文件',
      );
      final after = await _allTasks();
      expect(after.length, 1);
      expect(after.first.status, CollectStatus.failed);
    });

    test('再失败：返回新 failed 行 + 新原因，仍可重试', () async {
      await openMemoryDb();
      final task = await _seedFailedTask(
        id: 'task-notifier-fail',
        fileName: 'notifier-fail.pdf',
        storedBytes: List.generate(2000, (i) => i % 251),
        error: '第一次失败',
      );
      final container = _notifierContainer();
      final notifier = container.read(collectProvider.notifier);
      await notifier.load();
      final outcome = await notifier.retryFailedTask(
        task,
        pdfRenderService: _pdfService(_RenderFailEngine()),
      );
      expect(outcome.task?.status, CollectStatus.failed);
      expect(outcome.error, contains('渲染'));
      expect(container.read(collectProvider).retryingTaskIds, isEmpty);
      expect(container.read(collectProvider).tasks.length, 1);
      expect(
        container.read(collectProvider).tasks.first.status,
        CollectStatus.failed,
      );
      // 仍可重试：换好引擎再跑一次即成功。
      final again = await notifier.retryFailedTask(
        container.read(collectProvider).tasks.first,
        pdfRenderService: _pdfService(_OkEngine()),
      );
      expect(again.error, isNull);
      expect(again.task?.status, CollectStatus.needBox);
    });
  });

  group('collect page：失败行重试按钮', () {
    // 仓库先例（collect_page_test / b11_dragdrop）：泵页面的 widget
    // 测试一律用 FakeRepo——Notifier 的 load() 读真库在 fake 异步区
    // 里不完成，页面会一直空列表。重试的 service 仍走 FakeRepo 底
    // 下的真库（内存库，runAsync 里种子与查库）；点重试触发的重
    // 试管线（Drift 读写）同样包进 tester.runAsync（真实异步区），
    // 再回 fake 区刷新界面。
    testWidgets('失败行有“重试”，点后库里行变待框选；needBox 行没有“重试”', (
      tester,
    ) async {
      late final CollectTask failed;
      final needBox = CollectTask(
        id: 'task-page-needbox',
        name: 'ok.pdf · 第1页 · 第1题',
        fileName: 'ok.pdf',
        subjectId: 'math',
        status: CollectStatus.needBox,
        progress: 100,
        sourcePath: 'imports/task-page-needbox/original.pdf',
      );
      final repo = _PageFakeRepo([]);
      await tester.runAsync(() async {
        await openMemoryDb();
        failed = await _seedFailedTask(
          id: 'task-page-retry',
          fileName: 'page.pdf',
          storedBytes: List.generate(2000, (i) => i % 251),
        );
        repo.tasks = [failed, needBox];
      });
      await _pumpRetryPage(tester, engine: _OkEngine(), repo: repo);
      // 只有失败行有“重试”按钮。
      expect(find.text('重试'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('重试'));
        // 真实时间里等重试落盘（库里行变 needBox）再回 fake 区刷新。
        for (var i = 0; i < 200; i++) {
          final tasks = await AppDatabase.instance.allCollectTasks();
          if (tasks.any(
            (t) =>
                t.id == failed.id &&
                t.status == CollectStatus.needBox,
          )) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        fail('重试未在时限内完成');
      });
      // 库里行已翻 needBox 且仍是同一 id；页面重进重读即见待框选，
      // “重试”按钮随之消失（FakeRepo 列表是本次泵页时的快照，重进
      // 才重读——重读本身走同一 load()，service 测试已覆盖）。
      final after = await tester.runAsync(
        () => AppDatabase.instance.allCollectTasks(),
      );
      expect(after!.length, 1);
      expect(after.first.id, failed.id);
      expect(after.first.status, CollectStatus.needBox);
      repo.tasks = [after.first, needBox];
      // 二次 pumpWidget 同型复用元素树，旧 ProviderScope / notifier
      // 不重建、状态仍是旧列表；先泵占位页把旧 scope 卸掉，再重进
      // 收集页（新 notifier 的 load() 重读更新后的列表）。
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox())),
      );
      await tester.pumpAndSettle();
      await _pumpRetryPage(tester, engine: _OkEngine(), repo: repo);
      expect(find.text('重试'), findsNothing);
      expect(find.text('待框选'), findsWidgets);
    });

    testWidgets('重试进行中按钮禁用：onPressed 为 null，跑完恢复', (
      tester,
    ) async {
      late final CollectTask failed;
      final repo = _PageFakeRepo([]);
      await tester.runAsync(() async {
        await openMemoryDb();
        failed = await _seedFailedTask(
          id: 'task-page-busy',
          fileName: 'busy.pdf',
          storedBytes: List.generate(2000, (i) => i % 251),
        );
        repo.tasks = [failed];
      });
      await _pumpRetryPage(tester, engine: _CountingEngine(), repo: repo);
      expect(find.text('重试'), findsOneWidget);
      // 点重试（真实异步区里触发管线），不等它跑完就回 fake 区
      // pump 一帧：慢引擎 open 要 100ms，重试还在跑，按钮应禁用。
      await tester.runAsync(() async {
        await tester.tap(find.text('重试'));
      });
      await tester.pump();
      final button = tester.widget<QmButton>(
        find.widgetWithText(QmButton, '重试'),
      );
      expect(button.onPressed, isNull);
      // 等重试在真实时间里跑完（库里行翻 needBox）再回 fake 区刷新。
      await tester.runAsync(() async {
        for (var i = 0; i < 200; i++) {
          final tasks = await AppDatabase.instance.allCollectTasks();
          if (tasks.any(
            (t) =>
                t.id == failed.id &&
                t.status == CollectStatus.needBox,
          )) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        fail('重试未在时限内完成');
      });
      await tester.pumpAndSettle();
      // 跑完后按钮恢复可用（FakeRepo 列表仍是失败行快照，行本身
      // 不翻页；库里行已变 needBox，service 测试已覆盖）。
      final done = tester.widget<QmButton>(
        find.widgetWithText(QmButton, '重试'),
      );
      expect(done.onPressed, isNotNull);
      final after = await tester.runAsync(
        () => AppDatabase.instance.allCollectTasks(),
      );
      expect(after!.first.status, CollectStatus.needBox);
    });
  });
}
