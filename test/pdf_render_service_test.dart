// PDF 渲染（§6 第 3 条）：pdfrx_engine 真实渲染单测、20 页 / 50MB 上限、
// 加密 / 损坏 PDF 提示、渲染失败不建无页图任务。
// 真实 PDFium + 真实文件 IO，用普通 test()（真实异步可用）；
// 手写最小 PDF 生成器（与 /tmp 夹具脚本同算法，见 gen_pdf.py 思路）：
// 每页一段文字 + 一个黑色实心矩形，渲染后可断言非白像素。
// 内存库 + 临时数据目录，不碰真实用户库。
import 'dart:io';
import 'dart:typed_data';
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
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, version) async => AppDatabase.createTables(db)));
  AppDatabase.useDatabaseForTest(db);
  addTearDown(() async => db.close());
  return db;
}

/// 手写最小 PDF：对象 1 Catalog、2 Pages、3 Helvetica 字体，
/// 每页一个 Page + Contents（文字 + 黑色实心矩形）。
/// 与 Python 夹具脚本同算法；pypdf / pdfinfo 已验过同款输出合法。
Uint8List buildTestPdf({required int pages}) {
  final objs = <(int, List<int>)>[];
  final kids =
      List.generate(pages, (i) => '${4 + i * 2} 0 R').join(' ');
  objs.add((1, '<< /Type /Catalog /Pages 2 0 R >>'.codeUnits));
  objs.add((2,
      '<< /Type /Pages /Kids [$kids] /Count $pages >>'.codeUnits));
  objs.add((3, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
      .codeUnits));
  for (var i = 0; i < pages; i++) {
    final pageNo = i + 1;
    final content =
        'BT /F1 48 Tf 100 700 Td (Page $pageNo - Hello) Tj ET\n'
        '0 0 0 rg 100 500 200 100 re f\n';
    objs.add((
      4 + i * 2,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
              '/Resources << /Font << /F1 3 0 R >> >> '
              '/Contents ${4 + i * 2 + 1} 0 R >>'
          .codeUnits
    ));
    final stream = '<< /Length ${content.length} >>\nstream\n'
        '$content\nendstream';
    objs.add((4 + i * 2 + 1, stream.codeUnits));
  }
  final out = <int>[...'%PDF-1.4\n'.codeUnits];
  final offsets = <int, int>{};
  for (final (num, body) in objs) {
    offsets[num] = out.length;
    out.addAll('$num 0 obj\n'.codeUnits);
    out.addAll(body);
    out.addAll('\nendobj\n'.codeUnits);
  }
  final xrefPos = out.length;
  final maxNum = objs.map((e) => e.$1).reduce((a, b) => a > b ? a : b);
  out.addAll('xref\n0 ${maxNum + 1}\n'.codeUnits);
  out.addAll('0000000000 65535 f \n'.codeUnits);
  for (var n = 1; n <= maxNum; n++) {
    out.addAll(
        '${offsets[n]!.toString().padLeft(10, '0')} 00000 n \n'.codeUnits);
  }
  out.addAll('trailer\n<< /Size ${maxNum + 1} /Root 1 0 R >>\n'
          'startxref\n$xrefPos\n%%EOF\n'
      .codeUnits);
  return Uint8List.fromList(out);
}

/// PNG 里是否含深色像素（渲染出的不是空白页）：解码后在黑色矩形区
/// 内抽样——矩形在 PDF 坐标是 (100,500)-(300,600)（y 自下而上），
/// 换算到长边 2500 的图像坐标约 x 316..947、y 606..922。
Future<bool> pngHasDarkPixels(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  try {
    final data =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return false;
    final bytes = data.buffer.asUint8List();
    final w = image.width;
    var dark = 0;
    for (var y = 650; y < 900; y += 17) {
      for (var x = 350; x < 900; x += 29) {
        final off = (y * w + x) * 4;
        if (bytes[off] < 100 &&
            bytes[off + 1] < 100 &&
            bytes[off + 2] < 100) {
          dark++;
        }
      }
    }
    return dark > 10;
  } finally {
    image.dispose();
  }
}

/// 假引擎：按页返回 10×10 红色 PNG（注入测试用，不碰 PDFium）。
class FakePdfEngine implements PdfEngine {
  FakePdfEngine({required this.pages, this.failOnPage, this.failOnOpen});

  final int pages;
  final int? failOnPage;
  final Object? failOnOpen;
  Uint8List? _redPng;

  Future<Uint8List> _redPngBytes() async {
    if (_redPng != null) return _redPng!;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 10, 10),
      ui.Paint()..color = const ui.Color(0xFFFF0000),
    );
    final img = await recorder.endRecording().toImage(10, 10);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    _redPng = data!.buffer.asUint8List();
    return _redPng!;
  }

  @override
  Future<PdfEngineDocument> open(String path) async {
    if (failOnOpen != null) throw failOnOpen!;
    return _FakeDoc(this);
  }
}

class _FakeDoc implements PdfEngineDocument {
  _FakeDoc(this._engine);
  final FakePdfEngine _engine;

  @override
  int get pageCount => _engine.pages;

  @override
  Future<PdfPageRender> renderPage(
    int page, {
    required int targetLongEdge,
  }) async {
    if (page == _engine.failOnPage) {
      throw PdfCorruptException('第 $page 页渲染失败（假引擎）');
    }
    return PdfPageRender(
      png: await _engine._redPngBytes(),
      width: 10,
      height: 10,
    );
  }

  @override
  Future<void> close() async {}
}

void main() {
  setUpAll(() async {
    _tmp = await Directory.systemTemp.createTemp('qm2-pdf-render');
    AppDatabase.testDataDirectory = _tmp.path;
  });

  tearDownAll(() async {
    AppDatabase.testDataDirectory = null;
    await _tmp.delete(recursive: true);
  });

  group('选型库真实渲染（pdfrx_engine / PDFium）', () {
    test('3 页 PDF：页数 3，第 1 页渲成 PNG（长边 2500，有内容）', () async {
      final pdf = File('${_tmp.path}/three.pdf');
      await pdf.writeAsBytes(buildTestPdf(pages: 3));
      final service = PdfRenderService();
      expect(await service.pageCount(pdf.path), 3);
      final rendered = await service.renderPagePng(pdf.path, 1);
      // PNG 魔数
      expect(rendered.png.sublist(0, 8),
          [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      // 612×792 pt：长边 2500 → 1932×2500。
      expect(rendered.width, 1932);
      expect(rendered.height, 2500);
      expect(await pngHasDarkPixels(rendered.png), isTrue);
    });

    test('renderAllPagesToDir：写出 page-001..003.png，进度走到 (3,3)',
        () async {
      final pdf = File('${_tmp.path}/three2.pdf');
      await pdf.writeAsBytes(buildTestPdf(pages: 3));
      final outDir = Directory('${_tmp.path}/pages-out');
      final progress = <(int, int)>[];
      final total = await PdfRenderService().renderAllPagesToDir(
        pdf.path,
        outDir.path,
        onProgress: (rendered, total) async {
          progress.add((rendered, total));
        },
      );
      expect(total, 3);
      expect(progress.last, (3, 3));
      for (var p = 1; p <= 3; p++) {
        final f = File(
            '${outDir.path}/page-${p.toString().padLeft(3, '0')}.png');
        expect(f.existsSync(), isTrue);
        expect(f.lengthSync(), greaterThan(10000));
      }
    });

    test('页码越界：渲染第 0 页 / 第 4 页抛 PdfCorruptException', () async {
      final pdf = File('${_tmp.path}/three3.pdf');
      await pdf.writeAsBytes(buildTestPdf(pages: 3));
      final service = PdfRenderService();
      await expectLater(
        service.renderPagePng(pdf.path, 0),
        throwsA(isA<PdfCorruptException>()),
      );
      await expectLater(
        service.renderPagePng(pdf.path, 4),
        throwsA(isA<PdfCorruptException>()),
      );
    });
  });

  group('加密 / 损坏 PDF', () {
    test('加密 PDF（密码 1234）：抛 PdfEncryptedException', () async {
      final service = PdfRenderService();
      await expectLater(
        service.pageCount('test/fixtures/pdf-encrypted.pdf'),
        throwsA(isA<PdfEncryptedException>()),
      );
      await expectLater(
        service.renderPagePng('test/fixtures/pdf-encrypted.pdf', 1),
        throwsA(isA<PdfEncryptedException>()),
      );
    });

    test('损坏 PDF：随机字节 / 空文件 / 截断都抛 PdfCorruptException',
        () async {
      final service = PdfRenderService();
      final random = File('${_tmp.path}/random.pdf');
      await random.writeAsBytes(List.generate(2000, (i) => i % 251));
      await expectLater(
        service.pageCount(random.path),
        throwsA(isA<PdfCorruptException>()),
      );
      final empty = File('${_tmp.path}/empty.pdf');
      await empty.writeAsBytes([]);
      await expectLater(
        service.pageCount(empty.path),
        throwsA(isA<PdfCorruptException>()),
      );
      final valid = buildTestPdf(pages: 2);
      final truncated = File('${_tmp.path}/truncated.pdf');
      await truncated.writeAsBytes(valid.sublist(0, valid.length ~/ 2));
      await expectLater(
        service.pageCount(truncated.path),
        throwsA(isA<PdfCorruptException>()),
      );
    });
  });

  group('导入：PDF 整本渲染进库', () {
    test('3 页 PDF：needBox、pageCount 3、原文件 + 3 张页图落盘',
        () async {
      await openMemoryDb();
      final service = ImportService(AppDatabase.instance);
      final pdf = File('${_tmp.path}/import-3.pdf');
      await pdf.writeAsBytes(buildTestPdf(pages: 3));
      final progress = <int>[];
      final tasks = await service.enqueue(
        [pdf.path],
        subjectId: 'math',
        onProgress: (_, p) => progress.add(p),
      );
      expect(tasks.length, 1);
      final t = tasks.first;
      expect(t.status, CollectStatus.needBox);
      expect(t.progress, 100);
      expect(t.pageCount, 3);
      expect(t.page, 1);
      expect(t.sourcePath, 'imports/${t.id}/original.pdf');
      final copied = File(AppDatabase.resolveDataPath(t.sourcePath)!);
      expect(copied.existsSync(), isTrue);
      expect(copied.readAsBytesSync(), pdf.readAsBytesSync());
      for (var p = 1; p <= 3; p++) {
        final pageFile = File(AppDatabase.resolveDataPath(
            ImportService.renderedPageRelative(t.id, p))!);
        expect(pageFile.existsSync(), isTrue);
        expect(pageFile.lengthSync(), greaterThan(10000));
      }
      // 按页取页图：第 2 页对应 page-002.png。
      expect(
        ImportService.pageImageRelativeForTask(t, page: 2),
        'imports/${t.id}/pages/page-002.png',
      );
      expect(progress, isNotEmpty);
      expect(progress.last, 100);
    });

    test('21 页 PDF：失败、提示 21 页超 20 页上限、不建任务目录',
        () async {
      await openMemoryDb();
      final service = ImportService(AppDatabase.instance);
      final pdf = File('${_tmp.path}/import-21.pdf');
      await pdf.writeAsBytes(buildTestPdf(pages: 21));
      final tasks = await service.enqueue([pdf.path], subjectId: 'math');
      final t = tasks.first;
      expect(t.status, CollectStatus.failed);
      expect(t.error, contains('21 页'));
      expect(t.error, contains('20 页上限'));
      expect(t.error, contains('分批'));
      expect(t.sourcePath, isEmpty);
      expect(
        Directory(AppDatabase.resolveDataPath(
                ImportService.taskDirRelative(t.id))!)
            .existsSync(),
        isFalse,
      );
    });

    test('51MB PDF：失败、提示超 50MB 上限、不建任务目录', () async {
      await openMemoryDb();
      final service = ImportService(AppDatabase.instance);
      final pdf = File('${_tmp.path}/big.pdf');
      final raf = await pdf.open(mode: FileMode.write);
      await raf.truncate(51 * 1024 * 1024);
      await raf.close();
      expect(pdf.lengthSync(), 51 * 1024 * 1024);
      final tasks = await service.enqueue([pdf.path], subjectId: 'math');
      final t = tasks.first;
      expect(t.status, CollectStatus.failed);
      expect(t.error, contains('50MB'));
      expect(t.error, contains('拆成多个小 PDF'));
      expect(
        Directory(AppDatabase.resolveDataPath(
                ImportService.taskDirRelative(t.id))!)
            .existsSync(),
        isFalse,
      );
    });

    test('加密 PDF 导入：失败、提示“这个 PDF 带密码，解开密码再导”',
        () async {
      await openMemoryDb();
      final service = ImportService(AppDatabase.instance);
      final tasks = await service.enqueue(
        ['test/fixtures/pdf-encrypted.pdf'],
        subjectId: 'math',
      );
      final t = tasks.first;
      expect(t.status, CollectStatus.failed);
      expect(t.error, '这个 PDF 带密码，解开密码再导');
      expect(t.sourcePath, isEmpty);
      expect(
        Directory(AppDatabase.resolveDataPath(
                ImportService.taskDirRelative(t.id))!)
            .existsSync(),
        isFalse,
      );
    });

    test('损坏 PDF 导入：失败、提示具体原因、不建任务目录', () async {
      await openMemoryDb();
      final service = ImportService(AppDatabase.instance);
      final pdf = File('${_tmp.path}/bad.pdf');
      await pdf.writeAsBytes(List.generate(2000, (i) => i % 251));
      final tasks = await service.enqueue([pdf.path], subjectId: 'math');
      final t = tasks.first;
      expect(t.status, CollectStatus.failed);
      expect(t.error, startsWith('文件损坏：'));
      expect(
        Directory(AppDatabase.resolveDataPath(
                ImportService.taskDirRelative(t.id))!)
            .existsSync(),
        isFalse,
      );
    });
  });

  group('导入：假引擎注入', () {
    test('假引擎 3 页：同样走整本渲染，页图是假引擎的红 PNG', () async {
      await openMemoryDb();
      final service = ImportService(
        AppDatabase.instance,
        pdfRenderService:
            PdfRenderService(engine: FakePdfEngine(pages: 3)),
      );
      final pdf = File('${_tmp.path}/fake-3.pdf');
      await pdf.writeAsBytes(buildTestPdf(pages: 3));
      final tasks = await service.enqueue([pdf.path], subjectId: 'math');
      final t = tasks.first;
      expect(t.status, CollectStatus.needBox);
      expect(t.pageCount, 3);
      final page1 = File(AppDatabase.resolveDataPath(
          ImportService.renderedPageRelative(t.id, 1))!);
      expect(page1.existsSync(), isTrue);
      final codec = await ui.instantiateImageCodec(
          await page1.readAsBytes());
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 10);
      expect(frame.image.height, 10);
      frame.image.dispose();
    });

    test('假引擎第 2 页渲染失败：失败任务、目录已删，不建无页图任务',
        () async {
      await openMemoryDb();
      final service = ImportService(
        AppDatabase.instance,
        pdfRenderService:
            PdfRenderService(engine: FakePdfEngine(pages: 3, failOnPage: 2)),
      );
      final pdf = File('${_tmp.path}/fake-fail.pdf');
      await pdf.writeAsBytes(buildTestPdf(pages: 3));
      final tasks = await service.enqueue([pdf.path], subjectId: 'math');
      final t = tasks.first;
      expect(t.status, CollectStatus.failed);
      expect(t.error, startsWith('文件损坏：'));
      expect(t.sourcePath, isEmpty);
      expect(
        Directory(AppDatabase.resolveDataPath(
                ImportService.taskDirRelative(t.id))!)
            .existsSync(),
        isFalse,
      );
    });

    test('假引擎打开即加密错：失败任务、提示带密码', () async {
      await openMemoryDb();
      final service = ImportService(
        AppDatabase.instance,
        pdfRenderService: PdfRenderService(
            engine: FakePdfEngine(
                pages: 1, failOnOpen: const PdfEncryptedException())),
      );
      final pdf = File('${_tmp.path}/fake-enc.pdf');
      await pdf.writeAsBytes(buildTestPdf(pages: 1));
      final tasks = await service.enqueue([pdf.path], subjectId: 'math');
      final t = tasks.first;
      expect(t.status, CollectStatus.failed);
      expect(t.error, '这个 PDF 带密码，解开密码再导');
    });
  });
}
