// 十五批修复批 C-13：图块裁剪降采样（D-187）。
//
// 覆盖：cropFigurePng 调用处加 capPngTo300Dpi（与公式原图裁剪同款）。
// 证明：宽图块裁剪结果写入临时目录时已降采样到 300 DPI 上限宽
// （2126 px，对应内容宽 510.2 pt），窄图块原样不动；guard 实际值
// 从临时文件读尺寸计入，故计入像素数 = 实际嵌入像素数，不再低估。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/modules/ocr/question_content.dart';
import 'package:quiz_master2/services/pdf_export/ocr_content_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/slice_snapshot.dart';

import 'b15_m1b_fake_source.dart';

void main() {
  group('C-13 图块裁剪降采样（D-187）', () {
    late Directory tempRoot;
    late Directory figureDir;

    setUp(() async {
      tempRoot = Directory(
        '${Directory.current.path}/../flutter-test-tmp/fix-c13-t0',
      )..createSync(recursive: true);
      figureDir = Directory('${tempRoot.path}/figures')..createSync();
    });

    tearDown(() {
      try {
        if (tempRoot.existsSync()) {
          tempRoot.deleteSync(recursive: true);
        }
      } catch (_) {}
    });

    Future<(int, int)> croppedDims({
      required int sliceW,
      required int sliceH,
      required SrcRect rect,
    }) async {
      final sliceBytes = makePng(sliceW, sliceH);
      final slicePath = 'slices/q1.png';
      final record = choiceRecord(
        id: 'q1',
        slicePath: slicePath,
        sliceWidth: sliceW,
        sliceHeight: sliceH,
        ocrFigures: singleFigureJson(
          questionId: 'q1',
          slicePath: slicePath,
          sliceBytes: sliceBytes,
          srcRect: rect,
        ),
      );
      final snap = await buildOcrContentSnapshot(
        record: record,
        sliceBytes: sliceBytes,
        sliceHash: hashBytes(sliceBytes),
        figureTempDir: figureDir,
      );
      expect(snap.printable, isTrue);
      final figureBlocks = snap.blocks.whereType<FigureBlock>().toList();
      expect(figureBlocks.length, 1);
      final tempFile = File(
        '${figureDir.path}/${figureBlocks.first.cropPath.split('/').last}',
      );
      expect(tempFile.existsSync(), isTrue);
      expect(snap.figures.single.cropped, isTrue);
      final dims = readPngDimensions(tempFile.readAsBytesSync());
      return (dims!.width, dims.height);
    }

    test('宽图块裁剪降采样到 300 DPI 上限宽 2126 px', () async {
      // 切片 3000×1000，裁 3000×600：显示宽 = min(510.2, 3000/300*72=720)
      // = 510.2 pt → 上限宽 2126 px；高按比例 600×2126/3000 = 425.2 → 425。
      final (w, h) = await croppedDims(
        sliceW: 3000,
        sliceH: 1000,
        rect: const SrcRect(x: 0, y: 0, width: 3000, height: 600),
      );
      expect(w, 2126);
      expect(h, 425);
    });

    test('窄图块不降采样：裁剪尺寸原样写入', () async {
      // 裁 1500×500：显示宽 = min(510.2, 1500/300*72=360) = 360 pt →
      // 上限宽 1500 px，裁剪宽未超上限，原样返回。
      final (w, h) = await croppedDims(
        sliceW: 2000,
        sliceH: 1000,
        rect: const SrcRect(x: 0, y: 0, width: 1500, height: 500),
      );
      expect(w, 1500);
      expect(h, 500);
    });

    test('恰好 2126 px 宽的图块不降采样', () async {
      final (w, h) = await croppedDims(
        sliceW: 2126,
        sliceH: 800,
        rect: const SrcRect(x: 0, y: 0, width: 2126, height: 400),
      );
      expect(w, 2126);
      expect(h, 400);
    });
  });
}
