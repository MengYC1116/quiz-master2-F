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
// - SR-P1-14：图片 20MB 上限只提示不执行。修后：enqueue 对图片也硬判
//   20MB（与 PDF 50MB 同款），超限横幅文案同步改成“导入会失败”。
// - SR-P1-17：enqueue 的重复判断是空分支。修后：同批按源路径去重，
//   同一文件只建一个任务；跨批重复仍允许重导（D-08：收集页先弹
//   “已经导入过”，用户确认后才进 enqueue）。
// 内存库 + 临时数据目录，不碰真实用户库。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/import_service.dart';
import 'package:quiz_master2/services/pdf_render_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

late final Directory _tmp;

Future<Database> openMemoryDb() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 2,
      onCreate: (db, version) async => AppDatabase.createTables(db),
    ),
  );
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

ImportService _service() => ImportService(
  AppDatabase.instance,
  pdfRenderService: PdfRenderService(engine: _OkEngine()),
);

void main() {
  setUpAll(() async {
    _tmp = await Directory.systemTemp.createTemp('qm2-import-p1-fixes');
    AppDatabase.testDataDirectory = _tmp.path;
  });

  tearDownAll(() async {
    AppDatabase.testDataDirectory = null;
    await _tmp.delete(recursive: true);
  });

  group('SR-P1-4 _importPdf 末尾写库失败', () {
    test('收尾 upsert 失败：enqueue 不抛、任务失败、整批继续', () async {
      final db = await openMemoryDb();
      // 只有写 needBox 的 UPDATE 会炸：初始 importing 行、进度更新、
      // _failAndClean 的 failed 写库都不受影响。
      await db.execute('''
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
        expect(
          Directory(
            AppDatabase.resolveDataPath(ImportService.taskDirRelative(t.id))!,
          ).existsSync(),
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
          .enqueue(['test/fixtures/photo.jpg'], subjectId: 'math');
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
      expect(
        ImportService.oversizeHint(File('test/fixtures/photo.jpg')),
        isNull,
      );
    });
  });

  group('SR-P1-17 enqueue 同批去重', () {
    test('同批两次选同一文件：只建一个任务', () async {
      await openMemoryDb();
      const src = 'test/fixtures/photo.jpg';
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
      final tasks = await ImportService(AppDatabase.instance).enqueue([
        'test/fixtures/photo.jpg',
        'test/fixtures/exif-orientation-6.jpg',
      ], subjectId: 'math');
      expect(tasks.length, 2);
      expect(tasks.map((t) => t.status).toSet(), {CollectStatus.needBox});
    });

    test('跨批重复仍允许重导（D-08）：两次调用各建一个任务', () async {
      await openMemoryDb();
      final service = ImportService(AppDatabase.instance);
      const src = 'test/fixtures/photo.jpg';
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
  });
}
