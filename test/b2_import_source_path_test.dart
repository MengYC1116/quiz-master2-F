// ARCH-PLAN-B 第 2 阶段 W-import：导入 source_path 立即持久化
//（B-NEW-12）+ 失败清理只删派生文件、保留原图（B-NEW-10）+
// 恢复定位无文件 / 多候选异常处理（⑫，B-NEW-15）的回归测试。
//
// 与 test/b2_import_crash_test.dart 互补不重复：
// - b2_import_crash_test 验数据层可验证的部分（任务行状态、孤儿扫描
//   保护口径、多候选全保护不挑选），不管 ImportService；
// - 本文件验 ImportService.enqueue / _failAndClean /
//   retryFromStoredOriginal 的行为：复制完成后、渲染开始前
//   sourcePath 已持久化；渲染/后续步骤失败后原图仍在、失败行
//   sourcePath 指向真实存在的文件、可凭原图重试；复制本身失败时
//   sourcePath 为空、重试提示重供原文件。
//
// 写法铁律（D-45）：库在测试体内建、直接 await；不用 testWidgets；
// 不用 runAsync 包多段调用。内存库 + 临时数据目录，不碰真实演示库。
// 渲染用注入的假引擎（不碰 PDFium）；图片用 test_fixtures 的固件。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/import_guess.dart';
import 'package:quiz_master2/services/import_service.dart';
import 'package:quiz_master2/services/pdf_render_service.dart';

import 'test_fixtures.dart';

late final Directory _tmp;

Future<QuizDatabase> openMemoryDb() async {
  final db = await AppDatabase.openForTest();
  AppDatabase.useDatabaseForTest(db);
  addTearDown(() async => db.close());
  return db;
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

ImportService _service({PdfEngine? engine}) => ImportService(
  AppDatabase.instance,
  pdfRenderService: engine == null ? null : PdfRenderService(engine: engine),
);

File _storedOriginal(String taskId, String ext) => File(
  AppDatabase.resolveDataPath(ImportService.originalRelative(taskId, ext))!,
);

void main() {
  setUpAll(() async {
    _tmp = await Directory.systemTemp.createTemp('qm2-import-source-path');
    AppDatabase.testDataDirectory = _tmp.path;
  });

  tearDownAll(() async {
    await AppDatabase.resetForTest();
    // Windows 上删目录时可能仍有句柄未释放（errno 32）：重试 5 次。
    for (var i = 0; i < 5; i++) {
      try {
        await _tmp.delete(recursive: true);
        break;
      } catch (_) {
        if (i == 4) break;
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  });

  group('① B-NEW-12：复制完成后、渲染开始前 sourcePath 已持久化', () {
    test('PDF 渲染失败时，失败行 sourcePath 已写库、原图在盘上', () async {
      await openMemoryDb();
      final pdf = File('${_tmp.path}/render-fail.pdf');
      await pdf.writeAsBytes(List.generate(2000, (i) => i % 251));
      final tasks = await _service(engine: _RenderFailEngine())
          .enqueue([pdf.path], subjectId: 'math');
      expect(tasks.length, 1);
      final t = tasks.first;
      expect(t.status, CollectStatus.failed);
      expect(t.error, contains('渲染'));
      // 渲染失败后最终 needBox 的 upsert 从未跑过：失败行里的
      // sourcePath 只能来自复制完成后的立即持久化。
      expect(t.sourcePath, 'imports/${t.id}/original.pdf');
      expect(_storedOriginal(t.id, 'pdf').existsSync(), isTrue);

      final stored = await AppDatabase.instance.allCollectTasks();
      expect(stored.length, 1);
      expect(stored.first.id, t.id);
      expect(stored.first.status, CollectStatus.failed);
      expect(stored.first.sourcePath, 'imports/${t.id}/original.pdf');
      // 立即持久化只改 sourcePath：其它字段原样（状态 failed 是
      // _failAndClean 写进的；名字/学科/创建时间是 enqueue 建行时的）。
      expect(stored.first.name, t.name);
      expect(stored.first.fileName, 'render-fail.pdf');
      expect(stored.first.subjectId, 'math');
      expect(
        stored.first.createdAt?.millisecondsSinceEpoch,
        t.createdAt?.millisecondsSinceEpoch,
      );
      // 派生文件已清：渲染一半的 pages/ 目录不在了，原图还在。
      expect(
        Directory(AppDatabase.resolveDataPath('imports/${t.id}/pages')!)
            .existsSync(),
        isFalse,
      );
    });

    test('图片解不开时，失败行 sourcePath 已写库、原图保留', () async {
      await openMemoryDb();
      final fake = File('${_tmp.path}/not-image.jpg');
      await fake.writeAsString('这根本不是一张图片，只是一段文字。' * 20);
      final tasks = await _service().enqueue([fake.path], subjectId: 'math');
      expect(tasks.length, 1);
      final t = tasks.first;
      expect(t.status, CollectStatus.failed);
      expect(t.error, contains('打不开'));
      expect(t.sourcePath, 'imports/${t.id}/original.jpg');
      expect(_storedOriginal(t.id, 'jpg').existsSync(), isTrue);

      final stored = await AppDatabase.instance.allCollectTasks();
      expect(stored.length, 1);
      expect(stored.first.sourcePath, 'imports/${t.id}/original.jpg');
      expect(
        File(AppDatabase.resolveDataPath(stored.first.sourcePath)!)
            .existsSync(),
        isTrue,
      );
    });

    test('图片尾部 upsert 失败：归一化副本已清、原图保留、行带 sourcePath', () async {
      final db = await openMemoryDb();
      await db.customStatement('''
        CREATE TRIGGER trg_srcpath_fail_needbox_upsert
        BEFORE UPDATE ON collect_tasks
        WHEN NEW.status = 'needBox'
        BEGIN
          SELECT RAISE(ABORT, 'simulated write failure');
        END
      ''');
      final exif6 = await writeFixtureFile(
        _tmp,
        'srcpath-exif6.jpg',
        exifFixtureBytes(6),
      );
      final tasks = await _service().enqueue([exif6.path], subjectId: 'math');
      expect(tasks.length, 1);
      final t = tasks.first;
      expect(t.status, CollectStatus.failed);
      expect(t.error, contains('写不进任务列表'));
      // 触发器只拦 needBox 的 UPDATE：复制后的立即持久化
      //（importing）与 _failAndClean 的 failed 写库都不受影响。
      expect(t.sourcePath, 'imports/${t.id}/original.jpg');
      expect(_storedOriginal(t.id, 'jpg').existsSync(), isTrue);
      // 派生文件（EXIF 归一化副本）已清，原图保留。
      expect(
        File(
          AppDatabase.resolveDataPath(
            ImportService.normalizedPageRelative(t.id),
          )!,
        ).existsSync(),
        isFalse,
      );
      final stored = await AppDatabase.instance.allCollectTasks();
      expect(stored.length, 1);
      expect(stored.first.status, CollectStatus.failed);
      expect(stored.first.sourcePath, 'imports/${t.id}/original.jpg');
    });
  });

  group('② B-NEW-10：失败后原图仍在、失败行可重试', () {
    test('渲染失败后凭保留的原图重试成功，同一任务行原地变 needBox', () async {
      await openMemoryDb();
      _FlakyDoc.reset();
      final service = _service(engine: _FlakyEngine());
      final pdf = File('${_tmp.path}/flaky.pdf');
      await pdf.writeAsBytes(List.generate(2000, (i) => i % 251));
      final first = await service.enqueue([pdf.path], subjectId: 'math');
      expect(first.length, 1);
      final failed = first.first;
      expect(failed.status, CollectStatus.failed);
      expect(failed.sourcePath, 'imports/${failed.id}/original.pdf');
      expect(_storedOriginal(failed.id, 'pdf').existsSync(), isTrue);

      // 库里的失败行：sourcePath 指向真实存在的文件，可重试。
      final stored = await AppDatabase.instance.allCollectTasks();
      expect(stored.length, 1);
      expect(stored.first.status, CollectStatus.failed);
      expect(
        File(AppDatabase.resolveDataPath(stored.first.sourcePath)!)
            .existsSync(),
        isTrue,
      );

      // 凭库内原图重试（不依赖用户原路径）：第二次渲染成功。
      final retried = await service.retryFromStoredOriginal(stored.first);
      expect(retried.status, CollectStatus.needBox);
      expect(retried.pageCount, 1);
      expect(
        File(
          AppDatabase.resolveDataPath(
            ImportService.renderedPageRelative(retried.id, 1),
          )!,
        ).existsSync(),
        isTrue,
      );
      // 十二批 D-91 功能 7：原地重试——同一任务行/id，不建新行，
      // 旧失败行不保留（B2 旧语义已废弃）。
      expect(retried.id, failed.id);
      final after = await AppDatabase.instance.allCollectTasks();
      expect(after.length, 1);
      expect(after.first.id, failed.id);
      expect(after.first.status, CollectStatus.needBox);
    });

    test('图片成功导入仍走立即持久化：needBox 行 sourcePath 正常', () async {
      await openMemoryDb();
      final photo = await writeFixtureFile(
        _tmp,
        'srcpath-photo.jpg',
        photoFixtureBytes(),
      );
      final tasks = await _service().enqueue([photo.path], subjectId: 'math');
      expect(tasks.length, 1);
      expect(tasks.first.status, CollectStatus.needBox);
      expect(tasks.first.sourcePath, 'imports/${tasks.first.id}/original.jpg');
      expect(_storedOriginal(tasks.first.id, 'jpg').existsSync(), isTrue);
    });
  });

  group('③ 复制本身失败：sourcePath 为空、重试需重供原文件', () {
    test('源文件不存在：复制失败、失败行 sourcePath 为空、无任务目录', () async {
      await openMemoryDb();
      final missing = File('${_tmp.path}/no-such-file.jpg');
      final tasks = await _service().enqueue([missing.path], subjectId: 'math');
      expect(tasks.length, 1);
      final t = tasks.first;
      expect(t.status, CollectStatus.failed);
      expect(t.error, contains('复制不进去'));
      expect(t.sourcePath, isEmpty);
      expect(
        Directory(
          AppDatabase.resolveDataPath(ImportService.taskDirRelative(t.id))!,
        ).existsSync(),
        isFalse,
      );

      final stored = await AppDatabase.instance.allCollectTasks();
      expect(stored.length, 1);
      expect(stored.first.sourcePath, isEmpty);

      // 库内没有原图可重试：重试入口标失败并提示重供原文件。
      final retried = await _service().retryFromStoredOriginal(stored.first);
      expect(retried.status, CollectStatus.failed);
      expect(retried.error, contains('重新提供原文件'));
      expect(retried.sourcePath, isEmpty);
    });
  });

  group('⑫ 恢复定位无文件 / 多候选异常处理', () {
    test('无文件：标失败并提示重供原文件，悬空 sourcePath 被清掉', () async {
      await openMemoryDb();
      // 种子一个失败任务：sourcePath 指向已不存在的原图（悬空引用），
      // 任务目录里只有派生文件、没有 original.*。
      final task = CollectTask(
        id: 'task-locate-none',
        name: 'm.pdf · 第1页 · 第1题',
        fileName: 'm.pdf',
        subjectId: 'math',
        status: CollectStatus.failed,
        error: '导入失败：渲染这份 PDF 时出了问题',
        sourcePath: 'imports/task-locate-none/original.pdf',
      );
      await AppDatabase.instance.upsertCollectTask(task);
      final pagesDir = Directory(
        AppDatabase.resolveDataPath('imports/task-locate-none/pages')!,
      );
      await pagesDir.create(recursive: true);
      await File('${pagesDir.path}/page-001.png').writeAsBytes([1, 2, 3]);

      expect(ImportService.locateStoredOriginals('task-locate-none'), isEmpty);
      final retried = await _service().retryFromStoredOriginal(task);
      expect(retried.status, CollectStatus.failed);
      expect(retried.error, contains('找不到原来导入的文件'));
      expect(retried.error, contains('重新提供原文件'));
      // 悬空引用已清：失败行不再引用不存在的文件。
      expect(retried.sourcePath, isEmpty);
      final stored = await AppDatabase.instance.allCollectTasks();
      expect(stored.first.sourcePath, isEmpty);
      // 派生文件照常清理（失败清理的范围不变）。
      expect(pagesDir.existsSync(), isFalse);
    });

    test('多个候选：标失败并提示重供原文件，两个候选一个不少', () async {
      await openMemoryDb();
      final task = CollectTask(
        id: 'task-locate-multi',
        name: 'm.pdf · 第1页 · 第1题',
        fileName: 'm.pdf',
        subjectId: 'math',
        status: CollectStatus.failed,
        error: '导入失败：渲染这份 PDF 时出了问题',
        sourcePath: 'imports/task-locate-multi/original.jpg',
      );
      await AppDatabase.instance.upsertCollectTask(task);
      final dir = Directory(
        AppDatabase.resolveDataPath('imports/task-locate-multi')!,
      );
      await dir.create(recursive: true);
      final jpg = File('${dir.path}/original.jpg')..writeAsBytesSync([1]);
      final pdf = File('${dir.path}/original.pdf')..writeAsBytesSync([2]);

      expect(
        ImportService.locateStoredOriginals('task-locate-multi'),
        hasLength(2),
      );
      final retried = await _service().retryFromStoredOriginal(task);
      expect(retried.status, CollectStatus.failed);
      expect(retried.error, contains('多个原文件'));
      expect(retried.error, contains('重新提供原文件'));
      // 不挑选、不删除：两个候选都在；sourcePath 仍指向真实存在的
      // 文件（未悬空），保留不动。
      expect(jpg.existsSync(), isTrue);
      expect(pdf.existsSync(), isTrue);
      expect(retried.sourcePath, 'imports/task-locate-multi/original.jpg');
    });

    test('恰好一个候选：重试成功', () async {
      await openMemoryDb();
      final dir = Directory(
        AppDatabase.resolveDataPath('imports/task-locate-one')!,
      );
      await dir.create(recursive: true);
      final pdf = File('${_tmp.path}/locate-one.pdf');
      await pdf.writeAsBytes(List.generate(2000, (i) => i % 251));
      await File('${dir.path}/original.pdf')
          .writeAsBytes(await pdf.readAsBytes());
      // D-99：NULL hash 的任务重试会被拒绝；本用例验“恰好一个候选
      // → 重试成功”，种子行须带与库内原图一致的哈希基线。
      final task = CollectTask(
        id: 'task-locate-one',
        name: 'm.pdf · 第1页 · 第1题',
        fileName: 'm.pdf',
        subjectId: 'math',
        status: CollectStatus.failed,
        error: '导入失败：渲染这份 PDF 时出了问题',
        sourcePath: 'imports/task-locate-one/original.pdf',
        sourceHash: await sha256HexOfFile(pdf),
      );
      await AppDatabase.instance.upsertCollectTask(task);

      expect(
        ImportService.locateStoredOriginals('task-locate-one'),
        hasLength(1),
      );
      final retried = await _service(engine: _OkEngine())
          .retryFromStoredOriginal(task);
      expect(retried.status, CollectStatus.needBox);
      expect(retried.pageCount, 1);
    });
  });
}
