// 十六批 C：图片嵌入与降级（WORD-DESIGN.md §4，D-198/D-199）。
//
// 嵌入字节与快照临时文件 md5 一致、显示尺寸保宽高比、300 DPI 上限
// 防御断言、图块缺失 PARTIAL、公式原图 PARTIAL、公式裁剪亦失败则
// 整题跳过。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/modules/ocr/formula_crop.dart';
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/services/pdf_export/export_integrity.dart';
import 'package:quiz_master2/services/pdf_export/formula_rasterizer.dart';
import 'package:quiz_master2/services/word_export/word_document_builder.dart';

import 'b16_word_test_helpers.dart';

void main() {
  late Directory tempRoot;
  late FakeExportQuestionSource source;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('b16-word-image-');
    source = FakeExportQuestionSource();
  });

  tearDown(() async {
    if (tempRoot.existsSync()) {
      await tempRoot.delete(recursive: true);
    }
  });

  /// 加一道含行内公式的 C 路线题（ocrStem 含公式，裁剪框在 ocrRaw 里）。
  void addFormulaQuestion(
    String id, {
    String latex = r'x^2',
    List<int> bbox = const [10, 5, 60, 30],
    bool withLayout = true,
  }) {
    final slice = makePng(200, 100);
    source.records[id] = choiceRecord(
      id: id,
      sliceWidth: 200,
      sliceHeight: 100,
      ocrStem: '求 \$$latex\$ 的值',
      ocrRaw: withLayout
          ? formulaRaw(md: '求 \$$latex\$ 的值', sliceW: 200, sliceH: 100)
          : mdRaw('求 \$$latex\$ 的值'),
    );
    source.slices[id] = slice;
  }

  group('图片嵌入与降级（D-198）', () {
    test('嵌入的公式图字节与裁剪结果 md5 一致（同一批图）', () async {
      addFormulaQuestion('q0');
      final service = makeWordService(source, tempRoot, hasKey: true);
      final result = await generateWord(service, ['q0']);
      final doc = UnpackedDocx(result.docxBytes);
      expect(doc.mediaNames.length, 1);
      final cropped = cropFormulaImageBytes(
        sliceBytes: source.slices['q0']!,
        ocrRaw: source.records['q0']!.ocrRaw,
        formulaIndex: 0,
      );
      expect(cropped, isNotNull);
      // 行内公式显示宽 44 pt（正文 11 pt，高按 300 DPI 估算宽高比 4:1）；
      // 服务侧 capPngTo300Dpi 后写入临时文件并嵌入，字节须一致。
      final expected = capPngTo300Dpi(cropped!, 44.0) ?? cropped;
      expect(doc.mediaMd5(doc.mediaNames.single), md5Of(expected));
    });

    test('显示尺寸保宽高比（A 路线 200×100 切片 → 内容宽 × 一半高）',
        () async {
      addChoiceQuestion(source, 'q0', w: 200, h: 100);
      final service = makeWordService(source, tempRoot, hasKey: false);
      final result = await generateWord(service, ['q0']);
      expect(result.route.name, 'a');
      final doc = UnpackedDocx(result.docxBytes);
      expect(doc.mediaNames.length, 1);
      // 内容宽精确值 510.2406 pt（595.28 − 2×15 mm），高一半；
      // 1 pt = 12700 EMU：宽 → 6480056，高 → 3240028（cy/cx = 0.5）。
      expect(doc.documentXml, contains('cx="6480056"'));
      expect(doc.documentXml, contains('cy="3240028"'));
    });

    test('300 DPI 上限防御断言：超限抛 StateError，未超限不抛', () {
      expect(
        () => checkWordImageDpi(widthPx: 10000, displayWidthPt: 100),
        throwsA(isA<StateError>()),
      );
      expect(
        () => checkWordImageDpi(widthPx: 400, displayWidthPt: 100),
        returnsNormally,
      );
    });

    test('图块裁剪失败 → PARTIAL（图块缺失，不印无图可指的块）', () async {
      final slice = makePng(200, 100);
      source.records['q0'] = choiceRecord(
        id: 'q0',
        sliceWidth: 200,
        sliceHeight: 100,
        ocrFigures: singleFigureJson(
          questionId: 'q0',
          slicePath: 'slices/q0.png',
          sliceBytes: slice,
          // 越界裁剪区 → cropFigurePng 返回 null。
          srcRect: const SrcRect(x: 9000, y: 9000, width: 100, height: 100),
        ),
      );
      source.slices['q0'] = slice;
      final service = makeWordService(source, tempRoot, hasKey: true);
      final result = await generateWord(service, ['q0']);
      final entry = result.report.entries.single;
      expect(entry.status, IntegrityStatus.partial);
      expect(entry.warnings, contains('图块缺失'));
      expect(UnpackedDocx(result.docxBytes).mediaNames, isEmpty);
    });

    test('公式为原图 → PARTIAL（警告“公式为原图”）', () async {
      addFormulaQuestion('q0');
      final service = makeWordService(source, tempRoot, hasKey: true);
      final result = await generateWord(service, ['q0']);
      final entry = result.report.entries.single;
      expect(entry.status, IntegrityStatus.partial);
      expect(entry.warnings, contains('公式为原图'));
    });

    test('公式裁剪亦失败 → 整题跳过（其余题照常印）', () async {
      addChoiceQuestion(source, 'q0');
      addFormulaQuestion('q1', latex: r'y^2', withLayout: false);
      final service = makeWordService(source, tempRoot, hasKey: true);
      final result = await generateWord(service, ['q0', 'q1']);
      expect(result.report.completeCount, 1);
      expect(result.report.skippedCount, 1);
      final skipped = result.report.entries
          .singleWhere((e) => e.questionId == 'q1');
      expect(skipped.status, IntegrityStatus.skipped);
      expect(skipped.skipReason, '公式无法呈现');
      final doc = UnpackedDocx(result.docxBytes);
      expect(doc.documentXml, contains('第 1 题'));
      expect(doc.documentXml, isNot(contains('第 2 题')));
    });
  });
}
