/// PDF 渲染服务：把 PDF 按页渲染成 PNG 页图（方案 §1.4 / §6 第 3 条）。
///
/// 选型结论（详见 `docs/ui-replication/P0B2-PDF-REPORT.md`）：
/// 只引 `pdfrx_engine`（PDFium 引擎的纯 Dart 封装，MIT），不引完整
/// `pdfrx` 插件——我们只要“打开文档 + 按页渲染成像素”两个能力，
/// 不需要它的查看器 widget；引擎版不带 `material_ui` / `url_launcher` /
/// `path_provider` 等传递依赖，也不要求 Win11 开开发者模式（那是完整
/// `pdfrx` 插件的符号链接构建要求）。
///
/// 渲染流程：打开一次文档 → 逐页渲染 → 每页写盘后立即释放像素
/// （不把全部页的像素同时留在内存里；50MB 的 PDF 也按这个节奏走）。
/// 页图长边 2500px（方案 §1.4：长边 2000–3000），PNG 编码。
/// 加密 PDF 抛 [PdfEncryptedException]；损坏 / 不是 PDF 抛
/// [PdfCorruptException]（带具体原因）；其余渲染异常同样包成
/// [PdfCorruptException]，调用方按“文件损坏”提示，不建无页图任务。
///
/// `pdfrxInitialize()` 在首次打开前调一次（引擎自带幂等保护）；
/// BGRA 像素经 `dart:ui` 转 PNG（只输出 PNG，见方案 §1.4）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdfrx_engine/pdfrx_engine.dart' as pdfrx;

/// 加密 PDF：带密码，打不开（调用方提示“这个 PDF 带密码，解开密码再导”）。
class PdfEncryptedException implements Exception {
  const PdfEncryptedException([this.message = '这个 PDF 带密码']);
  final String message;
  @override
  String toString() => 'PdfEncryptedException: $message';
}

/// 损坏 / 不是 PDF / 渲染失败：[reason] 是给用户看的具体原因。
class PdfCorruptException implements Exception {
  const PdfCorruptException(this.reason);
  final String reason;
  @override
  String toString() => 'PdfCorruptException: $reason';
}

/// 一页渲染结果：PNG 字节 + 像素尺寸。
class PdfPageRender {
  const PdfPageRender({
    required this.png,
    required this.width,
    required this.height,
  });
  final Uint8List png;
  final int width;
  final int height;
}

/// 渲染引擎抽象（可注入假引擎做单测；生产用 [PdfrxEngine]）。
abstract class PdfEngine {
  Future<PdfEngineDocument> open(String path);
}

/// 已打开的 PDF 文档：页数 + 按页渲染 + 关闭。
abstract class PdfEngineDocument {
  int get pageCount;
  Future<PdfPageRender> renderPage(int page, {required int targetLongEdge});
  Future<void> close();
}

/// 生产引擎：pdfrx_engine（PDFium）。
class PdfrxEngine implements PdfEngine {
  @override
  Future<PdfEngineDocument> open(String path) async {
    await pdfrx.pdfrxInitialize();
    pdfrx.PdfDocument doc;
    try {
      doc = await pdfrx.PdfDocument.openFile(path);
    } on pdfrx.PdfPasswordException {
      throw const PdfEncryptedException();
    } on pdfrx.PdfException catch (e) {
      throw PdfCorruptException(_readableOpenError(e.message));
    } catch (e) {
      throw PdfCorruptException('打不开这个 PDF（$e）');
    }
    return _PdfrxDocument(doc);
  }
}

class _PdfrxDocument implements PdfEngineDocument {
  _PdfrxDocument(this._doc);
  final pdfrx.PdfDocument _doc;

  @override
  int get pageCount => _doc.pages.length;

  @override
  Future<PdfPageRender> renderPage(
    int page, {
    required int targetLongEdge,
  }) async {
    if (page < 1 || page > _doc.pages.length) {
      throw PdfCorruptException('没有第 $page 页（共 ${_doc.pages.length} 页）');
    }
    final pdfPage = _doc.pages[page - 1];
    final longEdge =
        pdfPage.width > pdfPage.height ? pdfPage.width : pdfPage.height;
    if (longEdge <= 0) {
      throw const PdfCorruptException('这页没有尺寸，渲不出来');
    }
    final scale = targetLongEdge / longEdge;
    final width = (pdfPage.width * scale).round().clamp(1, 10000);
    final height = (pdfPage.height * scale).round().clamp(1, 10000);
    pdfrx.PdfImage? image;
    try {
      image = await pdfPage.render(
        fullWidth: width.toDouble(),
        fullHeight: height.toDouble(),
      );
    } on pdfrx.PdfException catch (e) {
      throw PdfCorruptException('第 $page 页渲染失败（${e.message}）');
    } catch (e) {
      throw PdfCorruptException('第 $page 页渲染失败（$e）');
    }
    if (image == null) {
      throw PdfCorruptException('第 $page 页渲染失败（没有返回图像）');
    }
    try {
      final png = await _bgraToPng(image.pixels, image.width, image.height);
      return PdfPageRender(
          png: png, width: image.width, height: image.height);
    } finally {
      image.dispose();
    }
  }

  @override
  Future<void> close() => _doc.dispose();
}

/// 把 PDF 打开失败的引擎文案翻成用户能看懂的原因。
String _readableOpenError(String message) {
  final lower = message.toLowerCase();
  if (lower.contains('password')) return '这个 PDF 带密码，解开密码再导';
  if (lower.contains('not a pdf') || lower.contains('invalid')) {
    return '这不是一个有效的 PDF 文件';
  }
  return '文件损坏：$message';
}

/// BGRA 像素 → PNG 字节（dart:ui 只方便输出 PNG）。
Future<Uint8List> _bgraToPng(
    Uint8List bgra, int width, int height) async {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      bgra, width, height, ui.PixelFormat.bgra8888, completer.complete);
  final image = await completer.future;
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw const PdfCorruptException('页图转 PNG 失败');
    }
    return data.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// PDF 渲染服务：打开 → 逐页渲染 → 写盘。
///
/// 页数上限不在这里判（调用方 `ImportService` 在打开后、渲染前按
/// `maxPdfPages` 判，超了不渲染任何一页）。
class PdfRenderService {
  PdfRenderService({PdfEngine? engine})
      : _engine = engine ?? PdfrxEngine();
  final PdfEngine _engine;

  /// 页图长边目标（方案 §1.4：2000–3000）。
  static const int targetLongEdge = 2500;

  /// 只打开、读页数（加密 / 损坏直接抛错；用完即关）。
  Future<int> pageCount(String pdfPath) async {
    final doc = await _engine.open(pdfPath);
    try {
      return doc.pageCount;
    } finally {
      await doc.close();
    }
  }

  /// 渲染单页为 PNG（打开 → 渲染 → 关闭；调用方自己写盘）。
  Future<PdfPageRender> renderPagePng(
    String pdfPath,
    int page, {
    int targetLongEdge = targetLongEdge,
  }) async {
    final doc = await _engine.open(pdfPath);
    try {
      return await doc.renderPage(page, targetLongEdge: targetLongEdge);
    } finally {
      await doc.close();
    }
  }

  /// 渲染全部页到 [outDir]，文件名为 `page-001.png`…（[pageFileName]
  /// 决定命名，默认与 `ImportService.renderedPageRelative` 一致）。
  /// 逐页渲染、逐页写盘、逐页释放；返回总页数。
  /// [onProgress] 按（已渲染页数，总页数）回调。
  /// 任何一页失败都抛错（调用方删掉已写出的页图，不留半截任务）。
  Future<int> renderAllPagesToDir(
    String pdfPath,
    String outDir, {
    int targetLongEdge = targetLongEdge,
    String Function(int page)? pageFileName,
    Future<void> Function(int rendered, int total)? onProgress,
  }) async {
    final nameOf =
        pageFileName ?? (page) => 'page-${page.toString().padLeft(3, '0')}.png';
    final doc = await _engine.open(pdfPath);
    try {
      final total = doc.pageCount;
      await Directory(outDir).create(recursive: true);
      for (var page = 1; page <= total; page++) {
        final rendered =
            await doc.renderPage(page, targetLongEdge: targetLongEdge);
        await File('$outDir/${nameOf(page)}').writeAsBytes(rendered.png);
        await onProgress?.call(page, total);
      }
      return total;
    } finally {
      await doc.close();
    }
  }
}
