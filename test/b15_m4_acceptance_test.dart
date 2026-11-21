// 十五批 M4：验收补测（PLAN-15-REV3 §7 M4-1/M4-2，Linux 可验缺口）。
//
// M1–M3 覆盖核对后补的三项字节/文本级验收（其余 M4-1 分层项已有测试）：
// 1. 页眉页脚文字可提取（可选、可搜索）——A 路线生成 PDF 经 pdftotext
//    抽取，页眉与页脚均可读（M1-A 只在文档模型层断言页眉字符串，
//    M2 只断言页脚分母与答案区文本）；
// 2. C 路线正文为矢量文字——无公式无图块的题，生成 PDF 不含任何
//    /Subtype/Image 对象，且题干/选项可经 pdftotext 抽取；
// 3. 跳过题不在 PDF 里（文本级）——C 路线跳过题的题干与答案均不可
//    在练习版 PDF 文本中抽取（M2 只断言跳过题答案不在答案版）；
// 4. A 路线图片为增强后版本——PDF 内嵌图片像素等于生产增强器输出
//    的像素，不等于原切片像素（字节级：解开 /Image 流的 Flate 数据
//    后比对像素值）。
//
// 本文件不含任何公式源码；测试串只用最简占位形式。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:quiz_master2/services/pdf_export/export_question_record.dart';
import 'package:quiz_master2/services/pdf_export/export_route.dart';
import 'package:quiz_master2/services/pdf_export/image_enhancer.dart';
import 'package:quiz_master2/services/pdf_export/pdf_export_service.dart';

import 'b15_m1b_fake_source.dart';

Uint8List? _fontBytesCache;

Future<Uint8List> _fontBytes() async =>
    _fontBytesCache ??= await File(
      'assets/fonts/NotoSansSC-Regular.ttf',
    ).readAsBytes();

/// PDF 文本抽取（pdftotext 不可用时返回 null，调用方跳过文本断言）。
Future<String?> _pdfText(
  Uint8List bytes,
  Directory dir,
  String name,
) async {
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes);
  try {
    final result = await Process.run('pdftotext', [
      '-layout',
      file.path,
      '-',
    ]);
    if (result.exitCode != 0) return null;
    return result.stdout as String;
  } catch (_) {
    return null;
  }
}

/// 在字节串里找 ASCII 标记首次出现的位置（-1 为未找到）。
int _indexOfBytes(Uint8List haystack, List<int> needle, [int from = 0]) {
  outer:
  for (var i = from; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// 解开 PDF 里全部 /Subtype/Image 对象的 Flate 流，返回解压后字节。
///
/// 只取图片对象流（字体流等不取），以便像素比对不受其它流干扰。
/// 注意：pdf 包写字典不带空格，标记是 `/Subtype/Image`（不是
/// `/Subtype /Image`）；每张 PNG 图对应两个图片对象——RGB 主图
/// （宽×高×3 字节）与 SMask 灰度掩码（宽×高字节），调用方按长度区分。
List<Uint8List> _imageStreams(Uint8List pdfBytes) {
  final out = <Uint8List>[];
  const imageMarker = [
    0x2F, 0x53, 0x75, 0x62, 0x74, 0x79, 0x70, 0x65, 0x2F, 0x49, 0x6D,
    0x61, 0x67, 0x65,
  ]; // '/Subtype/Image'
  const streamLf = [0x73, 0x74, 0x72, 0x65, 0x61, 0x6D, 0x0A]; // 'stream\n'
  const streamCrlf = [
    0x73, 0x74, 0x72, 0x65, 0x61, 0x6D, 0x0D, 0x0A,
  ]; // 'stream\r\n'
  const endstream = [
    0x65, 0x6E, 0x64, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6D,
  ]; // 'endstream'
  var from = 0;
  while (true) {
    final imageAt = _indexOfBytes(pdfBytes, imageMarker, from);
    if (imageAt < 0) break;
    var streamAt = _indexOfBytes(pdfBytes, streamLf, imageAt);
    var dataStart = -1;
    if (streamAt >= 0) {
      dataStart = streamAt + streamLf.length;
    } else {
      streamAt = _indexOfBytes(pdfBytes, streamCrlf, imageAt);
      if (streamAt >= 0) dataStart = streamAt + streamCrlf.length;
    }
    if (dataStart < 0) break;
    final endAt = _indexOfBytes(pdfBytes, endstream, dataStart);
    if (endAt < 0) break;
    final raw = pdfBytes.sublist(dataStart, endAt);
    try {
      out.add(Uint8List.fromList(ZLibDecoder().convert(raw)));
    } catch (_) {
      // 非 Flate 流（如 JPEG 图片）不在此口径内，跳过。
    }
    from = endAt + endstream.length;
  }
  return out;
}

/// 统计 [data] 里连续三字节 [v, v, v] 出现的次数（像素值比对用）。
int _countTriple(Uint8List data, int v) {
  var count = 0;
  for (var i = 0; i + 2 < data.length; i++) {
    if (data[i] == v && data[i + 1] == v && data[i + 2] == v) count++;
  }
  return count;
}

/// 生成一张宽 [w] 高 [h] 的纯色 PNG（R=G=B=[gray]）。
Uint8List _grayPng(int w, int h, int gray) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(gray, gray, gray));
  return img.encodePng(image);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  var counter = 0;

  setUp(() {
    tempRoot =
        Directory(
          '${Directory.current.path}/../flutter-test-tmp/m4-acceptance-t${counter++}',
        )..createSync(recursive: true);
  });

  tearDown(() {
    try {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  PdfExportService service({
    required FakeExportQuestionSource source,
    required bool hasKey,
  }) => PdfExportService(
    source: source,
    hasApiKey: () async => hasKey,
    fontBytesLoader: _fontBytes,
    tempRoot: tempRoot,
  );

  group('M4-2 第一层：生成正确性（字节/文本级）', () {
    test('页眉页脚文字可提取：A 路线 PDF 经 pdftotext 抽出页眉与页脚', () async {
      final source = FakeExportQuestionSource();
      for (final id in ['q1', 'q2']) {
        source.records[id] = ExportQuestionRecord(
          id: id,
          title: '题 $id',
          subjectId: 'math',
          slicePath: 'slices/$id.png',
          sliceWidth: 2126,
          sliceHeight: 140,
          contentVersion: 0,
        );
        source.slices[id] = makePng(2126, 140);
      }
      final result = await service(source: source, hasKey: false).generate(
        ids: const ['q1', 'q2'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
      );
      expect(result.route, ExportRoute.a);
      expect(result.totalPages, greaterThanOrEqualTo(1));

      final text = await _pdfText(result.pdfBytes, tempRoot, 'a-header.pdf');
      if (text == null) {
        markTestSkipped('pdftotext 不可用，跳过文本断言');
        return;
      }
      // 页眉：错题本 · 多学科 · 导出日期（服务默认 subjectName 为多学科）。
      expect(text, contains('错题本'));
      expect(text, contains('多学科'));
      // 页脚：去空白后比对，避开 pdftotext 排版空格差异。
      final squashed = text.replaceAll(RegExp(r'\s+'), '');
      expect(squashed, contains('第1/${result.totalPages}页'));
      // 题号行同样为矢量文字、可抽取。
      expect(squashed, contains('第1题'));
      expect(squashed, contains('第2题'));
    });

    test('C 路线正文为矢量文字：无公式无图块的题不嵌图片对象，题干可抽取', () async {
      final source = FakeExportQuestionSource();
      for (final id in ['v1', 'v2']) {
        source.records[id] = choiceRecord(
          id: id,
          stem: id == 'v1' ? '矢量题干甲' : '矢量题干乙',
        );
        source.slices[id] = makePng(800, 200);
      }
      final result = await service(source: source, hasKey: true).generate(
        ids: const ['v1', 'v2'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
      );
      expect(result.route, ExportRoute.c);
      expect(result.report.completeCount, 2);
      // 无公式、无图块 → PDF 里不得有任何图片对象。
      final latin1Text = latin1.decode(result.pdfBytes, allowInvalid: true);
      expect(latin1Text, isNot(contains('/Subtype/Image')));
      expect(_imageStreams(result.pdfBytes), isEmpty);

      final text = await _pdfText(result.pdfBytes, tempRoot, 'c-vector.pdf');
      if (text == null) {
        markTestSkipped('pdftotext 不可用，跳过文本断言');
        return;
      }
      // 题干与选项均为矢量文字、可抽取。
      expect(text, contains('矢量题干甲'));
      expect(text, contains('矢量题干乙'));
      expect(text, contains('甲'));
      expect(text, contains('乙'));
    });

    test('跳过题不在 PDF 里：C 路线跳过题的题干与答案均不可抽取', () async {
      final source = FakeExportQuestionSource();
      source.records['c1'] = choiceRecord(id: 'c1', stem: '可印题干甲乙');
      source.records['c2'] = choiceRecord(
        id: 'c2',
        ocrStem: '',
        ocrRaw: mdRaw('跳过题独有题干'),
        answer: '跳过题答案不应出现',
        explanation: '跳过题解析不应出现',
      );
      for (final id in ['c1', 'c2']) {
        source.slices[id] = makePng(800, 200);
      }
      final result = await service(source: source, hasKey: true).generate(
        ids: const ['c1', 'c2'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
      );
      expect(result.route, ExportRoute.c);
      expect(
        result.questionPages.map((q) => q.questionId).toList(),
        ['c1'],
      );
      expect(result.report.skippedCount, 1);

      final text = await _pdfText(result.pdfBytes, tempRoot, 'c-skip.pdf');
      if (text == null) {
        markTestSkipped('pdftotext 不可用，跳过文本断言');
        return;
      }
      expect(text, contains('可印题干甲乙'));
      // 跳过题的题干（只在 ocr_raw 里）与答案/解析均不得出现在 PDF 里。
      expect(text, isNot(contains('跳过题独有题干')));
      expect(text, isNot(contains('跳过题答案不应出现')));
      expect(text, isNot(contains('跳过题解析不应出现')));
    });

    test('A 路线图片为增强后版本：内嵌图片像素等于增强后像素，不等于原图', () async {
      const gray = 100;
      final sliceBytes = _grayPng(2126, 140, gray);
      final source = FakeExportQuestionSource();
      source.records['a1'] = ExportQuestionRecord(
        id: 'a1',
        title: '题 a1',
        subjectId: 'math',
        slicePath: 'slices/a1.png',
        sliceWidth: 2126,
        sliceHeight: 140,
        contentVersion: 0,
      );
      source.slices['a1'] = sliceBytes;
      final result = await service(source: source, hasKey: false).generate(
        ids: const ['a1'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
      );
      expect(result.route, ExportRoute.a);
      expect(result.report.completeCount, 1);

      // 期望像素：直接跑生产增强器（亮度 1.25 / 对比 1.10），
      // 不在测试里硬编增强算子的输出值。
      final enhanced = ImageEnhancer.enhanceSlice(sliceBytes: sliceBytes);
      expect(enhanced.isEnhanced, isTrue);
      final enhancedImage = enhanced.decodedImage!;
      final expected = enhancedImage.getPixel(0, 0).r.toInt();
      expect(expected, isNot(gray));

      final streams = _imageStreams(result.pdfBytes);
      // 一张 PNG 图对应两个图片对象：RGB 主图（宽×高×3）与 SMask
      // 灰度掩码（宽×高）；只在 RGB 主图上比对像素。
      expect(streams, hasLength(2));
      final rgb = streams.singleWhere(
        (s) => s.length == 2126 * 140 * 3,
        orElse: () => Uint8List(0),
      );
      expect(rgb, isNotEmpty);
      expect(
        streams.singleWhere((s) => s.length == 2126 * 140),
        isNotEmpty,
      );
      // 增强后像素应大量出现（整图纯色），原图像素不得出现。
      expect(_countTriple(rgb, expected), greaterThan(1000));
      expect(_countTriple(rgb, gray), 0);
    });
  });
}
