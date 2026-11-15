// _importPdf 兜底 catch（B3 P1-2）：读页数 / 渲染时抛出的非 PDF 异常
//（磁盘满等 FileSystemException）也要走 _failAndClean——任务进
// failed 并清掉半写目录，不让任务卡在导入中、不抛到 enqueue 外。
// 用注入的假引擎模拟异常，不真把磁盘写满；内存库 + 临时数据目录，
// 不碰真实用户库。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/import_service.dart';
import 'package:quiz_master2/services/pdf_render_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

late final Directory _tmp;

Future<Database> openMemoryDb() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, version) async => AppDatabase.createTables(db)));
  AppDatabase.useDatabaseForTest(db);
  addTearDown(() async => db.close());
  return db;
}

/// 打开即抛指定异常的假引擎（模拟读页数阶段磁盘满 / IO 失败）。
class _ThrowingEngine implements PdfEngine {
  _ThrowingEngine(this.error);
  final Object error;

  @override
  Future<PdfEngineDocument> open(String path) async => throw error;
}

/// 打开成功、渲染即抛 FileSystemException 的假文档
///（模拟渲染中途磁盘满）。
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

void main() {
  setUpAll(() async {
    _tmp = await Directory.systemTemp.createTemp('qm2-import-fallback');
    AppDatabase.testDataDirectory = _tmp.path;
  });

  tearDownAll(() async {
    AppDatabase.testDataDirectory = null;
    await _tmp.delete(recursive: true);
  });

  group('_importPdf 兜底 catch', () {
    test('读页数时磁盘满：enqueue 不抛、任务失败、半写目录已删', () async {
      await openMemoryDb();
      final service = ImportService(
        AppDatabase.instance,
        pdfRenderService: PdfRenderService(
          engine: _ThrowingEngine(
            const FileSystemException('磁盘已满，写不进去', 'original.pdf'),
          ),
        ),
      );
      final pdf = File('${_tmp.path}/full.pdf');
      await pdf.writeAsBytes(List.generate(2000, (i) => i % 251));
      final tasks = await service.enqueue([pdf.path], subjectId: 'math');
      expect(tasks.length, 1);
      final t = tasks.first;
      expect(t.status, CollectStatus.failed);
      expect(t.error, startsWith('导入失败：'));
      expect(
        Directory(AppDatabase.resolveDataPath(
                ImportService.taskDirRelative(t.id))!)
            .existsSync(),
        isFalse,
      );
    });

    test('渲染中途磁盘满：同样失败、不卡导入中、目录已删', () async {
      await openMemoryDb();
      final service = ImportService(
        AppDatabase.instance,
        pdfRenderService: PdfRenderService(engine: _RenderFailEngine()),
      );
      final pdf = File('${_tmp.path}/render-full.pdf');
      await pdf.writeAsBytes(List.generate(2000, (i) => i % 251));
      final tasks = await service.enqueue([pdf.path], subjectId: 'math');
      expect(tasks.length, 1);
      final t = tasks.first;
      expect(t.status, CollectStatus.failed);
      expect(t.error, startsWith('导入失败：'));
      expect(
        Directory(AppDatabase.resolveDataPath(
                ImportService.taskDirRelative(t.id))!)
            .existsSync(),
        isFalse,
      );
    });
  });
}
