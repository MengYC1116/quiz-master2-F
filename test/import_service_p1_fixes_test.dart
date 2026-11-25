// Batch 5 第二阶段 P1 丢数据类：SR-P1-4 + SR-P1-14 + SR-P1-17 回归测试
//（都在 lib/services/import_service.dart；另含收集页超限横幅文案）。
//
// - SR-P1-4：_importPdf 末尾成功路径的 upsertCollectTask(done) 在 try 之外，
//   写库失败逃出 enqueue、任务卡 importing、整批中断。修后：末尾 upsert
//   包进 try/catch，失败走 _failAndClean（再失败也只返回内存里的 failed
//   任务），enqueue 的 _importPdf 调用点也加兜底，整批继续。
//   触发写库失败不用真写满磁盘：内存库上建一个 BEFORE UPDATE 触发器，
//   凡是把状态写成 needBox 的 UPDATE 一律 RAISE(ABORT)——upsert 是
//   UPDATE-first（见 db_collect.dart），初始 importing 行与进度更新
//   （status 仍是 importing）不受影响，只有收尾写 needBox 会炸。
//   Batch 6（SR2-1/SR2-2/SR2-60）补齐同款缺口：图片尾部 upsert、
//   _failAndClean 自身写库失败、全部写操作失败时 enqueue 仍不抛。
// - SR-P1-14：图片 20MB 上限只提示不执行。修后：enqueue 对图片也硬判
//   20MB（与 PDF 50MB 同款），超限横幅文案同步改成“导入会失败”。
//   Batch 6（SR2-71）补恰好 20MB / 恰好 50MB 的边界用例。
// - SR-P1-17：enqueue 的重复判断是空分支。修后：同批按源路径去重，
//   同一文件只建一个任务；跨批重复仍允许重导（D-08：收集页先弹
//   “已经导入过”，用户确认后才进 enqueue）。
//   Batch 6（SR2-72）补同文件不同写法（相对/绝对路径、符号链接、
//   大小写）的去重用例，去重键改为规范化路径（见 import_service.dart）。
// 内存库 + 临时数据目录，不碰真实用户库。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/import_service.dart';
import 'package:quiz_master2/services/pdf_render_service.dart';

import 'test_fixtures.dart';

late final Directory _tmp;
late final String _photoPath; // B10-2：生成的照片固件
late final String _exif6Path; // B10-2：生成的方向 6 固件

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

/// 打开即抛损坏的假引擎（SR2-2：_importPdf 的 pageCount 失败进
/// _failAndClean，触发器再让 _failAndClean 自己的写库也失败）。
class _CorruptEngine implements PdfEngine {
  @override
  Future<PdfEngineDocument> open(String path) async {
    throw const PdfCorruptException('假引擎：文件损坏');
  }
}

ImportService _service() => ImportService(
  AppDatabase.instance,
  pdfRenderService: PdfRenderService(engine: _OkEngine()),
);

void main() {
  setUpAll(() async {
    _tmp = await Directory.systemTemp.createTemp('qm2-import-p1-fixes');
    AppDatabase.testDataDirectory = _tmp.path;
    // B10-2：照片 / 方向 6 固件写进临时目录，不读磁盘夹具。
    _photoPath = (await writeFixtureFile(
      _tmp,
      'photo.jpg',
      photoFixtureBytes(),
    )).path;
    _exif6Path = (await writeFixtureFile(
      _tmp,
      'exif-orientation-6.jpg',
      exifFixtureBytes(6),
    )).path;
  });

  tearDownAll(() async {
    AppDatabase.testDataDirectory = null;
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

  group('SR-P1-4 _importPdf 末尾写库失败', () {
    test('收尾 upsert 失败：enqueue 不抛、任务失败、整批继续', () async {
      final db = await openMemoryDb();
      // 只有写 needBox 的 UPDATE 会炸：初始 importing 行、进度更新、
      // _failAndClean 的 failed 写库都不受影响。
      await db.customStatement('''
        CREATE TRIGGER trg_p1_4_fail_needbox_upsert
        BEFORE UPDATE ON collect_tasks
        WHEN NEW.status = 'needBox'
        BEGIN
          SELECT RAISE(ABORT, 'simulated write failure');
        END
      ''');
      final pdf1 = File('${_tmp.path}/p1-4-a.pdf');
      final pdf2 = File('${_tmp.path}/p1-4-b.pdf');
      await pdf1.writeAsBytes(List.generate(2000, (i) => i % 251));
      await pdf2.writeAsBytes(List.generate(2000, (i) => i % 251));
      final tasks = await _service().enqueue([
        pdf1.path,
        pdf2.path,
      ], subjectId: 'math');
      // 没修之前：第一个 PDF 的末尾 upsert 抛错逃出 enqueue，
      // 整个 await 抛错、一个任务都拿不到。修后：两个任务都在，
      // 且第二个也被处理（不是整批中断）。
      expect(tasks.length, 2);
      for (final t in tasks) {
        expect(t.status, CollectStatus.failed);
        expect(t.error, contains('写不进任务列表'));
        // B2 B-NEW-10/B-NEW-12：失败清理只删派生文件、保留原图；
        // 复制完成时 sourcePath 已立即持久化，失败行指向真实文件。
        expect(t.sourcePath, ImportService.originalRelative(t.id, 'pdf'));
        expect(
          Directory(
            AppDatabase.resolveDataPath(ImportService.taskDirRelative(t.id))!,
          ).existsSync(),
          isTrue,
        );
        expect(
          File(AppDatabase.resolveDataPath(t.sourcePath)!).existsSync(),
          isTrue,
        );
        expect(
          Directory(AppDatabase.resolveDataPath('imports/${t.id}/pages')!)
              .existsSync(),
          isFalse,
        );
      }
      // 库里也是 failed 行（_failAndClean 的重试写成功了），
      // 没有任务卡在 importing。
      final stored = await AppDatabase.instance.allCollectTasks();
      expect(stored.length, 2);
      expect(stored.map((t) => t.status).toSet(), {CollectStatus.failed});
    });

    test('对照：写库正常时 PDF 仍成功进 needBox、页图在盘上', () async {
      await openMemoryDb();
      final pdf = File('${_tmp.path}/p1-4-ok.pdf');
      await pdf.writeAsBytes(List.generate(2000, (i) => i % 251));
      final tasks = await _service().enqueue([pdf.path], subjectId: 'math');
      expect(tasks.length, 1);
      final t = tasks.first;
      expect(t.status, CollectStatus.needBox);
      expect(t.pageCount, 1);
      expect(
        File(
          AppDatabase.resolveDataPath(
            ImportService.renderedPageRelative(t.id, 1),
          )!,
        ).existsSync(),
        isTrue,
      );
    });

    test('图片尾部 upsert 失败（SR2-1）：enqueue 不抛、图片任务失败、整批继续', () async {
      final db = await openMemoryDb();
      await db.customStatement('''
        CREATE TRIGGER trg_p1_4_fail_needbox_upsert_img
        BEFORE UPDATE ON collect_tasks
        WHEN NEW.status = 'needBox'
        BEGIN
          SELECT RAISE(ABORT, 'simulated write failure');
        END
      ''');
      final tasks = await ImportService(AppDatabase.instance)
          .enqueue([_photoPath, _exif6Path], subjectId: 'math');
      // 没修之前：第一张图的尾部 upsert 抛错逃出 enqueue，整个 await
      // 抛错、一个任务都拿不到。修后：两个任务都在，且第二个也被处理。
      expect(tasks.length, 2);
      for (final t in tasks) {
        expect(t.status, CollectStatus.failed);
        expect(t.error, contains('写不进任务列表'));
        // B2 B-NEW-10/B-NEW-12：同上，原图保留、失败行带 sourcePath。
        expect(t.sourcePath, ImportService.originalRelative(t.id, 'jpg'));
        expect(
          Directory(
            AppDatabase.resolveDataPath(ImportService.taskDirRelative(t.id))!,
          ).existsSync(),
          isTrue,
        );
        expect(
          File(AppDatabase.resolveDataPath(t.sourcePath)!).existsSync(),
          isTrue,
        );
      }
      // 库里也是 failed 行（_failAndClean 的重试写成功了），
      // 没有任务卡在 importing。
      final stored = await AppDatabase.instance.allCollectTasks();
      expect(stored.length, 2);
      expect(stored.map((t) => t.status).toSet(), {CollectStatus.failed});
    });

    test('_failAndClean 自身写库失败（SR2-2）：仍返回内存 failed 任务、不抛', () async {
      final db = await openMemoryDb();
      // 只让写 failed 的 UPDATE 炸：初始 importing 行（INSERT）不受
      // 影响，_failAndClean 的 failed 写库必然失败。
      await db.customStatement('''
        CREATE TRIGGER trg_fail_failed_upsert
        BEFORE UPDATE ON collect_tasks
        WHEN NEW.status = 'failed'
        BEGIN
          SELECT RAISE(ABORT, 'simulated write failure');
        END
      ''');
      final pdf = File('${_tmp.path}/p1-4-corrupt.pdf');
      await pdf.writeAsBytes(List.generate(2000, (i) => i % 251));
      final tasks = await ImportService(
        AppDatabase.instance,
        pdfRenderService: PdfRenderService(engine: _CorruptEngine()),
      ).enqueue([pdf.path], subjectId: 'math');
      // 没修之前：_importPdf → _failAndClean 的 upsert 抛错逃出
      // enqueue，整个 await 抛错。修后：内存里仍返回 failed 任务。
      expect(tasks.length, 1);
      expect(tasks.first.status, CollectStatus.failed);
      expect(tasks.first.error, contains('文件损坏'));
      // B2 B-NEW-10/B-NEW-12：_failAndClean 写库失败时不删任何文件
      //（先写库、成功后再删派生文件的顺序）；任务目录与原图都在，
      // 内存 failed 任务的 sourcePath 仍指向原图。
      expect(
        tasks.first.sourcePath,
        ImportService.originalRelative(tasks.first.id, 'pdf'),
      );
      expect(
        Directory(
          AppDatabase.resolveDataPath(
            ImportService.taskDirRelative(tasks.first.id),
          )!,
        ).existsSync(),
        isTrue,
      );
      expect(
        File(AppDatabase.resolveDataPath(tasks.first.sourcePath)!).existsSync(),
        isTrue,
      );
      // 库里只剩初始 importing 行——failed 行写不进去是触发器模拟的
      // “库已坏到 failed 行也写不进”的降级态，内存结果为准。
      // B2 B-NEW-12：复制后的立即持久化（importing，不被触发器拦）
      // 已成功，库里这行 sourcePath 已指向原图。
      final stored = await AppDatabase.instance.allCollectTasks();
      expect(stored.length, 1);
      expect(stored.first.status, CollectStatus.importing);
      expect(
        stored.first.sourcePath,
        ImportService.originalRelative(tasks.first.id, 'pdf'),
      );
    });

    test(
      '全部 collect_tasks 写操作失败（SR2-60）：enqueue 不抛、返回 2 个内存 failed 任务',
      () async {
        final db = await openMemoryDb();
        // INSERT 与 UPDATE 全炸：连初始 importing 行都写不进。
        await db.customStatement('''
        CREATE TRIGGER trg_fail_all_insert
        BEFORE INSERT ON collect_tasks
        BEGIN
          SELECT RAISE(ABORT, 'simulated write failure');
        END
      ''');
        await db.customStatement('''
        CREATE TRIGGER trg_fail_all_update
        BEFORE UPDATE ON collect_tasks
        BEGIN
          SELECT RAISE(ABORT, 'simulated write failure');
        END
      ''');
        final pdf1 = File('${_tmp.path}/p1-4-all-fail-a.pdf');
        final pdf2 = File('${_tmp.path}/p1-4-all-fail-b.pdf');
        await pdf1.writeAsBytes(List.generate(2000, (i) => i % 251));
        await pdf2.writeAsBytes(List.generate(2000, (i) => i % 251));
        final tasks = await _service().enqueue([
          pdf1.path,
          pdf2.path,
        ], subjectId: 'math');
        // 没修之前：第一个文件的初始 upsert 就抛错逃出 enqueue，
        // 整个 await 抛错、一个任务都拿不到。修后：两个内存 failed
        // 任务都在（库里一行也写不进，这是触发器模拟的降级态）。
        expect(tasks.length, 2);
        for (final t in tasks) {
          expect(t.status, CollectStatus.failed);
          expect(t.error, isNotNull);
        }
        expect(await AppDatabase.instance.allCollectTasks(), isEmpty);
      },
    );
  });

  group('SR-P1-14 图片 20MB 硬判', () {
    test('21MB 图片：直接失败、提示 20MB 上限、不复制进库', () async {
      await openMemoryDb();
      final big = File('${_tmp.path}/big.jpg');
      await big.writeAsBytes(List.filled(21 * 1024 * 1024, 0));
      final tasks = await ImportService(AppDatabase.instance)
          .enqueue([big.path], subjectId: 'math');
      expect(tasks.length, 1);
      final t = tasks.first;
      expect(t.status, CollectStatus.failed);
      expect(t.error, contains('超过 20MB 上限'));
      expect(
        Directory(
          AppDatabase.resolveDataPath(ImportService.taskDirRelative(t.id))!,
        ).existsSync(),
        isFalse,
      );
    });

    test('对照：20MB 以内图片仍正常进 needBox', () async {
      await openMemoryDb();
      final tasks = await ImportService(AppDatabase.instance)
          .enqueue([_photoPath], subjectId: 'math');
      expect(tasks.length, 1);
      expect(tasks.first.status, CollectStatus.needBox);
    });

    test('oversizeHint 与硬判一致：超限说“导入会失败”，不超限为 null', () async {
      final big = File('${_tmp.path}/hint-big.jpg');
      await big.writeAsBytes(List.filled(21 * 1024 * 1024, 0));
      final hint = ImportService.oversizeHint(big);
      expect(hint, contains('超过 20MB 上限'));
      expect(hint, contains('导入会失败'));
      expect(hint, isNot(contains('仍可继续导入')));
      expect(ImportService.oversizeHint(File(_photoPath)), isNull);
    });

    test('恰好 20MB 图片（SR2-71，size == limit）：放行进 needBox', () async {
      await openMemoryDb();
      // photo.jpg 后补 0 到恰好 20MB：JPEG 解码在 EOI 后停，尾部
      // 补零不影响解码；断言 size == limit 时 `size > limit` 不触发。
      final bytes = photoFixtureBytes();
      final padded = Uint8List(ImportService.maxImageBytes)
        ..setRange(0, bytes.length, bytes);
      final exact = File('${_tmp.path}/exact-20mb.jpg');
      await exact.writeAsBytes(padded);
      expect(await exact.length(), ImportService.maxImageBytes);
      final tasks = await ImportService(AppDatabase.instance)
          .enqueue([exact.path], subjectId: 'math');
      expect(tasks.length, 1);
      expect(tasks.first.status, CollectStatus.needBox);
    });

    test('恰好 50MB PDF（SR2-71，size == limit）：放行进 needBox', () async {
      await openMemoryDb();
      final exact = File('${_tmp.path}/exact-50mb.pdf');
      await exact.writeAsBytes(List.filled(ImportService.maxPdfBytes, 0));
      expect(await exact.length(), ImportService.maxPdfBytes);
      final tasks = await _service().enqueue([exact.path], subjectId: 'math');
      expect(tasks.length, 1);
      expect(tasks.first.status, CollectStatus.needBox);
      expect(tasks.first.pageCount, 1);
    });
  });

  group('SR-P1-17 enqueue 同批去重', () {
    test('同批两次选同一文件：只建一个任务', () async {
      await openMemoryDb();
      final src = _photoPath;
      // _tmp 是本文件各测试共享的：只断言本次调用新增的任务目录数。
      final importsDir = Directory('${_tmp.path}/imports');
      final before = importsDir.existsSync()
          ? importsDir.listSync().map((e) => e.path).toSet()
          : <String>{};
      final tasks = await ImportService(AppDatabase.instance)
          .enqueue([src, src], subjectId: 'math');
      expect(tasks.length, 1);
      expect(tasks.first.status, CollectStatus.needBox);
      final stored = await AppDatabase.instance.allCollectTasks();
      expect(stored.length, 1);
      final after = importsDir.listSync().map((e) => e.path).toSet();
      expect(after.difference(before).length, 1);
    });

    test('同批两个不同文件：仍建两个任务', () async {
      await openMemoryDb();
      final tasks = await ImportService(AppDatabase.instance)
          .enqueue([_photoPath, _exif6Path], subjectId: 'math');
      expect(tasks.length, 2);
      expect(tasks.map((t) => t.status).toSet(), {CollectStatus.needBox});
    });

    test('跨批重复仍允许重导（D-08）：两次调用各建一个任务', () async {
      await openMemoryDb();
      final service = ImportService(AppDatabase.instance);
      final src = _photoPath;
      final first = await service.enqueue([src], subjectId: 'math');
      // 任务 id 含毫秒时间戳，同毫秒两次调用会撞 id，隔一下再导。
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final second = await service.enqueue([src], subjectId: 'math');
      expect(first.length, 1);
      expect(second.length, 1);
      expect(first.first.id, isNot(second.first.id));
      final stored = await AppDatabase.instance.allCollectTasks();
      expect(stored.length, 2);
    });

    test('同文件相对路径与绝对路径写法（SR2-72）：只建一个任务', () async {
      await openMemoryDb();
      // B10-2：照片固件在临时目录；相对写法用 path.relative 算出。
      final relative = p.relative(_photoPath, from: Directory.current.path);
      final absolute = _photoPath;
      expect(absolute, isNot(relative));
      final tasks = await ImportService(AppDatabase.instance)
          .enqueue([relative, absolute], subjectId: 'math');
      expect(tasks.length, 1);
      expect(tasks.first.status, CollectStatus.needBox);
      expect((await AppDatabase.instance.allCollectTasks()).length, 1);
    });

    test('同文件符号链接写法（SR2-72）：只建一个任务', () async {
      await openMemoryDb();
      final src = _photoPath;
      final link = Link('${_tmp.path}/link-photo.jpg');
      await link.create(File(src).absolute.path);
      final tasks = await ImportService(AppDatabase.instance)
          .enqueue([src, link.path], subjectId: 'math');
      expect(tasks.length, 1);
      expect(tasks.first.status, CollectStatus.needBox);
      expect((await AppDatabase.instance.allCollectTasks()).length, 1);
    });

    test('同文件大小写不同写法（SR2-72/SR3-5）：Windows 只建 1 个任务，Linux 区分大小写', () async {
      await openMemoryDb();
      // B10-2：大写拼写取生成路径整体大写（临时目录名本身含小写，
      // 大写后一定不存在于 Linux）。Windows 文件系统不区分大小写，
      // 两种拼写打开同一文件，去重后只建一个任务；Linux 上大写
      // 路径本身打不开，是两个独立任务（一个 needBox、一个 failed）。
      final tasks = await ImportService(AppDatabase.instance)
          .enqueue([_photoPath, _photoPath.toUpperCase()], subjectId: 'math');
      if (Platform.isWindows) {
        expect(tasks.length, 1);
        expect(tasks.single.status, CollectStatus.needBox);
        expect((await AppDatabase.instance.allCollectTasks()).length, 1);
      } else {
        expect(tasks.length, 2);
        expect(tasks.map((t) => t.status).toSet(), {
          CollectStatus.needBox,
          CollectStatus.failed,
        });
        expect((await AppDatabase.instance.allCollectTasks()).length, 2);
      }
    });

    test('不存在的大写拼写在前（SR3-5）：Windows 仍只建 1 个任务', () async {
      await openMemoryDb();
      // Windows：先给的大写路径仍打开真实文件，去重后只建一个
      // needBox 任务，真实文件不会被遮蔽。Linux：两个任务，真实
      // 文件正常进 needBox，大写拼写单独 failed。
      final tasks = await ImportService(AppDatabase.instance)
          .enqueue([_photoPath.toUpperCase(), _photoPath], subjectId: 'math');
      if (Platform.isWindows) {
        expect(tasks.length, 1);
        expect(tasks.single.status, CollectStatus.needBox);
        expect((await AppDatabase.instance.allCollectTasks()).length, 1);
      } else {
        expect(tasks.length, 2);
        final real = tasks.firstWhere((t) => t.fileName == 'photo.jpg');
        expect(real.status, CollectStatus.needBox);
        final ghost = tasks.firstWhere((t) => t.fileName == 'PHOTO.JPG');
        expect(ghost.status, CollectStatus.failed);
        expect((await AppDatabase.instance.allCollectTasks()).length, 2);
      }
    });
  });

  group('SR3-6 onProgress 抛错不翻转任务状态', () {
    test('图片复制循环内回调抛错：任务仍进 needBox，不判复制失败', () async {
      await openMemoryDb();
      final tasks = await ImportService(AppDatabase.instance).enqueue(
        [_photoPath],
        subjectId: 'math',
        onProgress: (_, _) => throw StateError('UI 回调炸了'),
      );
      expect(tasks.length, 1);
      expect(tasks.first.status, CollectStatus.needBox);
      expect((await AppDatabase.instance.allCollectTasks()).length, 1);
    });

    test('PDF 渲染回调内抛错：任务仍进 needBox，不判渲染失败', () async {
      await openMemoryDb();
      final pdf = File('${_tmp.path}/sr3-6.pdf');
      await pdf.writeAsBytes(List.generate(2000, (i) => i % 251));
      final tasks = await _service().enqueue(
        [pdf.path],
        subjectId: 'math',
        onProgress: (_, _) => throw StateError('UI 回调炸了'),
      );
      expect(tasks.length, 1);
      expect(tasks.first.status, CollectStatus.needBox);
      expect(tasks.first.pageCount, 1);
      expect((await AppDatabase.instance.allCollectTasks()).length, 1);
    });
  });

  group('B 包 P1-05 图片像素上限', () {
    // 只构造 PNG 签名 + IHDR 宽高，不构造真实像素数据：
    // 60MP 检查在读头阶段就应拒绝，不能走到解码。
    Uint8List pngHeader(int width, int height) {
      final b = BytesBuilder();
      b.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      b.add(const [0x00, 0x00, 0x00, 0x0D]);
      b.add(const [0x49, 0x48, 0x44, 0x52]);
      for (final v in [width, height]) {
        b.add([
          (v >> 24) & 0xFF,
          (v >> 16) & 0xFF,
          (v >> 8) & 0xFF,
          v & 0xFF,
        ]);
      }
      b.add(const [8, 6, 0, 0, 0]); // bit depth/color/compression/filter/interlace
      b.add(const [0, 0, 0, 0]); // CRC（readImageDimensions 不校验 CRC）
      return b.takeBytes();
    }

    test('8000×8000 PNG 头：导入直接 failed，提示 60MP 上限', () async {
      await openMemoryDb();
      final bomb = File('${_tmp.path}/pixel-bomb.png');
      await bomb.writeAsBytes(pngHeader(8000, 8000));
      final tasks = await ImportService(AppDatabase.instance)
          .enqueue([bomb.path], subjectId: 'math');
      expect(tasks.length, 1);
      expect(tasks.single.status, CollectStatus.failed);
      expect(tasks.single.error, contains('60MP'));
      expect(await AppDatabase.instance.allCollectTasks(), hasLength(1));
    });
  });
}
