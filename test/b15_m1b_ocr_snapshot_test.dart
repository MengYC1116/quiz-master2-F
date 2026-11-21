// 十五批 M1-B：C 路线选项可印性判定 + 内容组装测试（M1-DESIGN.md §5/§9）。
//
// 覆盖：各题型选项要求、NULL 四种情形、未知解析器版本、组装
// （题干 + 选项块 → 块序列）、图块裁剪复用 buildContentBlocks、
// 可追溯性字段。公式用最简形式，仅作解析计数用。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/modules/ocr/question_content.dart';
import 'package:quiz_master2/services/pdf_export/ocr_content_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/slice_snapshot.dart';

import 'b15_m1b_fake_source.dart';

void main() {
  group('可印性判定：题型与选项（§5 第 3 点）', () {
    test('单选题：选项齐全 → 可印', () {
      final p = assessCPrintability(choiceRecord(id: 'q1'));
      expect(p.printable, isTrue);
      expect(p.optionsState, OptionsState.available);
      expect(p.suspiciousFlags, isEmpty);
    });

    test('多选题 / 不定项选择题：选项齐全 → 可印', () {
      for (final type in ['choice_multi', 'choice_variable']) {
        final p = assessCPrintability(
          choiceRecord(id: 'q1', questionType: type),
        );
        expect(p.printable, isTrue, reason: type);
      }
    });

    test('判断题：不要求选项，无选项内容也 → 可印', () {
      final p = assessCPrintability(
        choiceRecord(
          id: 'q1',
          questionType: 'true_false',
          optionContentsJson: null,
          options: const {},
          ocrRaw: mdRaw('判断下列说法是否正确'),
          ocrStem: '判断下列说法是否正确',
        ),
      );
      expect(p.printable, isTrue);
      expect(p.optionsState, OptionsState.notRequired);
    });

    test('填空 / 简答 / 论述题：不要求选项 → 可印', () {
      for (final type in ['fill_blank', 'short_answer', 'essay']) {
        final p = assessCPrintability(
          choiceRecord(
            id: 'q1',
            questionType: type,
            optionContentsJson: null,
            options: const {},
            ocrRaw: mdRaw('填空题干'),
            ocrStem: '填空题干',
          ),
        );
        expect(p.printable, isTrue, reason: type);
        expect(p.optionsState, OptionsState.notRequired, reason: type);
      }
    });

    test('题型为 NULL：md 能自动切分出选项 → 按选择题要求选项', () {
      // 有选项内容 → 可印。
      final ok = assessCPrintability(
        choiceRecord(id: 'q1', questionType: null),
      );
      expect(ok.printable, isTrue);
      // md 含选项但题干无选项、选项内容为 NULL → (b) 不可印。
      final bad = assessCPrintability(
        choiceRecord(
          id: 'q2',
          questionType: null,
          optionContentsJson: null,
          options: const {},
          ocrRaw: mdRaw(choiceMd('求值')),
          ocrStem: '求值',
        ),
      );
      expect(bad.printable, isFalse);
      expect(bad.skipReason, '选项无法派生');
    });

    test('题型为 NULL：md 切不出选项 → 不要求选项 → 可印', () {
      final p = assessCPrintability(
        choiceRecord(
          id: 'q1',
          questionType: null,
          optionContentsJson: null,
          options: const {},
          ocrRaw: mdRaw('请简述下列概念的含义'),
          ocrStem: '请简述下列概念的含义',
        ),
      );
      expect(p.printable, isTrue);
      expect(p.optionsState, OptionsState.notRequired);
    });

    test('选择题只有 1 个非空选项槽 → 可印 + 标可疑 optionSplitUncertain', () {
      final p = assessCPrintability(
        choiceRecord(
          id: 'q1',
          options: {'A': '甲', 'B': '', 'C': '', 'D': ''},
        ),
      );
      expect(p.printable, isTrue);
      expect(p.optionsState, OptionsState.uncertain);
      expect(p.suspiciousFlags, contains('optionSplitUncertain'));
    });

    test('选择题选项全空 → 不可印', () {
      final p = assessCPrintability(
        choiceRecord(
          id: 'q1',
          options: {'A': '', 'B': '', 'C': '', 'D': ''},
        ),
      );
      expect(p.printable, isFalse);
      expect(p.skipReason, '选项无法派生');
    });
  });

  group('可印性判定：前两条（§5）', () {
    test('无 OCR 结果 → 跳过', () {
      final p = assessCPrintability(
        choiceRecord(id: 'q1', ocrRaw: null),
      );
      expect(p.printable, isFalse);
      expect(p.skipReason, '无 OCR 结果');
    });

    test('ocr_raw 无法解析 → 跳过（按无原始结果处理）', () {
      final p = assessCPrintability(
        choiceRecord(id: 'q1', ocrRaw: 'not json at all'),
      );
      expect(p.printable, isFalse);
      expect(p.skipReason, '无 OCR 结果');
    });

    test('md_results 为空 → 跳过', () {
      final p = assessCPrintability(
        choiceRecord(id: 'q1', ocrRaw: mdRaw('   ')),
      );
      expect(p.printable, isFalse);
      expect(p.skipReason, '无 OCR 结果');
    });

    test('题干缺失（空白）→ 跳过', () {
      final p = assessCPrintability(
        choiceRecord(id: 'q1', ocrStem: '   '),
      );
      expect(p.printable, isFalse);
      expect(p.skipReason, '题干缺失');
    });
  });

  group('NULL 四种情形（§5 REV2）', () {
    test('(a) NULL 且题干含选项 → inline 可印', () {
      final stem = '求值\nA. 选项一\nB. 选项二\nC. 选项三\nD. 选项四';
      final p = assessCPrintability(
        choiceRecord(
          id: 'q1',
          ocrStem: stem,
          ocrRaw: mdRaw(choiceMd('求值')),
          optionContentsJson: null,
          options: const {},
        ),
      );
      expect(p.printable, isTrue);
      expect(p.optionsState, OptionsState.inlineInStem);
    });

    test('(b) NULL 且题干无选项 → 不可印', () {
      final p = assessCPrintability(
        choiceRecord(
          id: 'q1',
          ocrStem: '求值',
          ocrRaw: mdRaw(choiceMd('求值')),
          optionContentsJson: null,
          options: const {},
        ),
      );
      expect(p.printable, isFalse);
      expect(p.skipReason, '选项无法派生');
      expect(p.optionsState, OptionsState.unavailable);
    });

    test('(c) 非 NULL 但 JSON 损坏 → 标可疑 + 不可印', () {
      final p = assessCPrintability(
        choiceRecord(id: 'q1', optionContentsJson: '{bad json'),
      );
      expect(p.printable, isFalse);
      expect(p.skipReason, '选项无法派生');
      expect(p.suspiciousFlags, contains('optionContentsCorrupt'));
    });

    test('(c) 非 NULL 但版本未知 → 标可疑 + 不可印，不重解释旧数据', () {
      final p = assessCPrintability(
        choiceRecord(id: 'q1', parserVersion: 99),
      );
      expect(p.printable, isFalse);
      expect(p.skipReason, '选项无法派生');
      expect(p.suspiciousFlags, contains('unknownParserVersion'));
    });

    test('(c) 版本为 NULL + 内容为人工填写的有效 JSON → 不按版本拒', () {
      final p = assessCPrintability(
        choiceRecord(id: 'q1', parserVersion: null),
      );
      expect(p.printable, isTrue);
      expect(p.optionsState, OptionsState.available);
    });

    test('(d) 标签顺序异常（缺 B）→ 可印 + 标可疑', () {
      final p = assessCPrintability(
        choiceRecord(
          id: 'q1',
          options: {'A': '甲', 'C': '丙', 'D': '丁'},
        ),
      );
      expect(p.printable, isTrue);
      expect(p.optionsState, OptionsState.uncertain);
      expect(p.suspiciousFlags, contains('optionSplitUncertain'));
    });

    test('(d) 个别槽为空 → 可印 + 标可疑', () {
      final p = assessCPrintability(
        choiceRecord(
          id: 'q1',
          options: {'A': '甲', 'B': '', 'C': '丙', 'D': '丁'},
        ),
      );
      expect(p.printable, isTrue);
      expect(p.optionsState, OptionsState.uncertain);
      expect(p.suspiciousFlags, contains('optionSplitUncertain'));
    });
  });

  group('组装：题干 + 选项 → 块序列（§9）', () {
    late Directory tempRoot;
    late Directory figureDir;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('b15-m1b-ocr-');
      figureDir = Directory('${tempRoot.path}/figures');
      await figureDir.create();
    });

    tearDown(() async {
      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('选项按标签顺序重建为行，拼进块序列', () async {
      final record = choiceRecord(id: 'q1');
      final snap = await buildOcrContentSnapshot(
        record: record,
        sliceBytes: null,
        sliceHash: null,
        figureTempDir: figureDir,
      );
      expect(snap.printable, isTrue);
      final text = snap.blocks
          .whereType<TextBlock>()
          .map((b) => b.text)
          .join('\n');
      expect(text, contains('求下列各题的值'));
      expect(text, contains('A. 甲'));
      expect(text, contains('B. 乙'));
      expect(text, contains('C. 丙'));
      expect(text, contains('D. 丁'));
      // 标签顺序：A 在 B 之前。
      expect(
        text.indexOf('A. 甲'),
        lessThan(text.indexOf('B. 乙')),
      );
    });

    test('NULL inline 情形：选项不重复附加', () async {
      final stem = '求值\nA. 选项一\nB. 选项二\nC. 选项三\nD. 选项四';
      final record = choiceRecord(
        id: 'q1',
        ocrStem: stem,
        ocrRaw: mdRaw(choiceMd('求值')),
        optionContentsJson: null,
        options: const {},
      );
      final snap = await buildOcrContentSnapshot(
        record: record,
        sliceBytes: null,
        sliceHash: null,
        figureTempDir: figureDir,
      );
      expect(snap.printable, isTrue);
      final text = snap.blocks
          .whereType<TextBlock>()
          .map((b) => b.text)
          .join('\n');
      expect('A. 选项一'.allMatches(text).length, 1);
    });

    test('公式计数：行内与独立公式分别统计', () async {
      final record = choiceRecord(
        id: 'q1',
        ocrStem: r'设 $a$ 为常数，求 $$b$$ 的值',
        ocrRaw: mdRaw(choiceMd(r'设 $a$ 为常数，求 $$b$$ 的值')),
      );
      final snap = await buildOcrContentSnapshot(
        record: record,
        sliceBytes: null,
        sliceHash: null,
        figureTempDir: figureDir,
      );
      expect(snap.printable, isTrue);
      expect(snap.inlineFormulaCount, 1);
      expect(snap.displayFormulaCount, 1);
      expect(snap.blocks.whereType<FormulaBlock>().length, 2);
    });

    test('不可印题不组装块序列，但保留跳过原因', () async {
      final record = choiceRecord(id: 'q1', ocrRaw: null);
      final snap = await buildOcrContentSnapshot(
        record: record,
        sliceBytes: null,
        sliceHash: null,
        figureTempDir: figureDir,
      );
      expect(snap.printable, isFalse);
      expect(snap.blocks, isEmpty);
      expect(snap.skipReason, '无 OCR 结果');
    });

    test('可追溯性字段：题干来源 / 解析器版本 / 纠错旗 / 内容版本', () async {
      final record = choiceRecord(
        id: 'q1',
        ocrManualEdited: true,
        contentVersion: 3,
      );
      final snap = await buildOcrContentSnapshot(
        record: record,
        sliceBytes: null,
        sliceHash: null,
        figureTempDir: figureDir,
      );
      expect(snap.traceability.stemSource, '库内已存值');
      expect(snap.traceability.optionParserVersion, 2);
      expect(snap.traceability.corrected, isTrue);
      expect(snap.traceability.contentVersion, 3);
      expect(snap.stemText, '求下列各题的值');
      expect(snap.optionContents, {'A': '甲', 'B': '乙', 'C': '丙', 'D': '丁'});
    });
  });

  group('图块：复用 buildContentBlocks + 快照裁剪（§9）', () {
    late Directory tempRoot;
    late Directory figureDir;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('b15-m1b-fig-');
      figureDir = Directory('${tempRoot.path}/figures');
      await figureDir.create();
    });

    tearDown(() async {
      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('当前图块按同一套排序插入序列，并裁到临时目录', () async {
      final sliceBytes = makePng(200, 100);
      final slicePath = 'slices/q1.png';
      final record = choiceRecord(
        id: 'q1',
        slicePath: slicePath,
        sliceWidth: 200,
        sliceHeight: 100,
        ocrFigures: singleFigureJson(
          questionId: 'q1',
          slicePath: slicePath,
          sliceBytes: sliceBytes,
          srcRect: const SrcRect(x: 10, y: 10, width: 50, height: 40),
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
      expect(figureBlocks.first.cropPath, startsWith('figures/'));
      final tempFile = File(
        '${figureDir.path}/${figureBlocks.first.cropPath.split('/').last}',
      );
      expect(tempFile.existsSync(), isTrue);
      // 裁出的图是 50×40。
      final dims = readPngDimensions(tempFile.readAsBytesSync());
      expect(dims!.width, 50);
      expect(dims.height, 40);
      expect(snap.figures.single.cropped, isTrue);
      expect(snap.figures.single.anchorSource, 'fallback');
      expect(snap.traceability.figureSources['figure-q1-0'], 'fallback');
    });

    test('旧图块（与当前切片不一致）不展示、不裁剪', () async {
      final sliceBytes = makePng(200, 100);
      final slicePath = 'slices/q1.png';
      // 旧切片字节与当前不同（尺寸不同 → 哈希必然不同）。
      final staleBytes = makePng(201, 100);
      final record = choiceRecord(
        id: 'q1',
        slicePath: slicePath,
        sliceWidth: 200,
        sliceHeight: 100,
        ocrFigures: singleFigureJson(
          questionId: 'q1',
          slicePath: slicePath,
          sliceBytes: staleBytes,
          srcRect: const SrcRect(x: 10, y: 10, width: 50, height: 40),
        ),
      );
      final snap = await buildOcrContentSnapshot(
        record: record,
        sliceBytes: sliceBytes,
        sliceHash: hashBytes(sliceBytes),
        figureTempDir: figureDir,
      );
      expect(snap.printable, isTrue);
      expect(snap.blocks.whereType<FigureBlock>(), isEmpty);
      expect(snap.figures, isEmpty);
      expect(snap.warnings.any((w) => w.contains('图块与当前切片不一致')), isTrue);
    });

    test('切片缺失：正文仍可印，图块略过记 PARTIAL 降级', () async {
      final sliceBytes = makePng(200, 100);
      final slicePath = 'slices/q1.png';
      final record = choiceRecord(
        id: 'q1',
        slicePath: slicePath,
        sliceWidth: 200,
        sliceHeight: 100,
        ocrFigures: singleFigureJson(
          questionId: 'q1',
          slicePath: slicePath,
          sliceBytes: sliceBytes,
          srcRect: const SrcRect(x: 10, y: 10, width: 50, height: 40),
        ),
      );
      final snap = await buildOcrContentSnapshot(
        record: record,
        sliceBytes: null,
        sliceHash: null,
        figureTempDir: figureDir,
      );
      expect(snap.printable, isTrue);
      expect(snap.blocks.whereType<FigureBlock>(), isEmpty);
      expect(snap.hasFigureMissing, isTrue);
      expect(snap.warnings, contains('图块缺失'));
    });

    test('裁剪失败（越界区域）：图块丢弃，不阻断整题', () async {
      final sliceBytes = makePng(200, 100);
      final slicePath = 'slices/q1.png';
      final record = choiceRecord(
        id: 'q1',
        slicePath: slicePath,
        sliceWidth: 200,
        sliceHeight: 100,
        ocrFigures: singleFigureJson(
          questionId: 'q1',
          slicePath: slicePath,
          sliceBytes: sliceBytes,
          srcRect: const SrcRect(x: 190, y: 90, width: 50, height: 40),
        ),
      );
      final snap = await buildOcrContentSnapshot(
        record: record,
        sliceBytes: sliceBytes,
        sliceHash: hashBytes(sliceBytes),
        figureTempDir: figureDir,
      );
      expect(snap.printable, isTrue);
      expect(snap.blocks.whereType<FigureBlock>(), isEmpty);
      expect(snap.hasFigureMissing, isTrue);
      expect(snap.figures.single.cropped, isFalse);
    });
  });
}
