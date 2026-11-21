// 十六批 C：A 路线（WORD-DESIGN.md §4.3，D-199）。
//
// 无 key 整单走 A 路线、增强失败回退原图、低清晰度默认只警告 /
// 勾选排除则跳过、切片缺失印 BROKEN 占位。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/services/pdf_export/export_integrity.dart';
import 'package:quiz_master2/services/pdf_export/image_enhancer.dart';

import 'b16_word_test_helpers.dart';

void main() {
  late Directory tempRoot;
  late FakeExportQuestionSource source;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('b16-word-a-route-');
    source = FakeExportQuestionSource();
    ImageEnhancer.debugForceEnhanceFailure = false;
  });

  tearDown(() async {
    ImageEnhancer.debugForceEnhanceFailure = false;
    if (tempRoot.existsSync()) {
      await tempRoot.delete(recursive: true);
    }
  });

  group('A 路线（D-199）', () {
    test('无 key → 整单走 A 路线（图片增强路线）', () async {
      addChoiceQuestion(source, 'q0', w: 2000, h: 1000);
      final service = makeWordService(source, tempRoot, hasKey: false);
      final result = await generateWord(service, ['q0']);
      expect(result.route.name, 'a');
      final doc = UnpackedDocx(result.docxBytes);
      expect(doc.documentXml, contains('图片增强路线'));
      expect(doc.mediaNames.length, 1);
    });

    test('增强失败 → 回退 300 DPI 上限原图，题面记“增强失败，已用原图”',
        () async {
      addChoiceQuestion(source, 'q0', w: 2000, h: 1000);
      ImageEnhancer.debugForceEnhanceFailure = true;
      final service = makeWordService(source, tempRoot, hasKey: false);
      final result = await generateWord(service, ['q0']);
      final entry = result.report.entries.single;
      expect(entry.status, IntegrityStatus.partial);
      expect(entry.warnings, contains('增强失败，已用原图'));
      expect(UnpackedDocx(result.docxBytes).mediaNames.length, 1);
    });

    test('低清晰度默认只警告（照常印）；勾选排除则跳过', () async {
      // 100×50 切片在内容宽下有效分辨率约 14 DPI（明显偏低）。
      addChoiceQuestion(source, 'qLow', w: 100, h: 50);
      final defaultService = makeWordService(
        source,
        tempRoot,
        hasKey: false,
      );
      final warned = await generateWord(defaultService, ['qLow']);
      final warnedEntry = warned.report.entries.single;
      expect(warnedEntry.status, IntegrityStatus.partial);
      expect(
        warnedEntry.warnings.any((w) => w.contains('清晰度')),
        isTrue,
      );
      expect(UnpackedDocx(warned.docxBytes).mediaNames.length, 1);

      // 勾选排除：低清题跳过，正常题照常印。
      addChoiceQuestion(source, 'q0', w: 2000, h: 1000);
      final excludingService = makeWordService(
        source,
        tempRoot,
        hasKey: false,
        excludeLowDpi: true,
      );
      final excluded = await generateWord(
        excludingService,
        ['q0', 'qLow'],
      );
      expect(excluded.report.completeCount, 1);
      expect(excluded.report.skippedCount, 1);
      expect(
        excluded.report.entries
            .singleWhere((e) => e.questionId == 'qLow')
            .status,
        IntegrityStatus.skipped,
      );
    });

    test('切片缺失 → BROKEN 占位（“本题图片缺失，无法印出”）', () async {
      addChoiceQuestion(source, 'q0', w: 2000, h: 1000);
      addChoiceQuestion(source, 'q1');
      source.unavailableSlices.add('q1');
      final service = makeWordService(source, tempRoot, hasKey: false);
      final result = await generateWord(service, ['q0', 'q1']);
      expect(result.report.brokenCount, 1);
      final doc = UnpackedDocx(result.docxBytes);
      expect(doc.documentXml, contains('本题图片缺失，无法印出'));
      expect(doc.documentXml, contains('第 2 题'));
    });
  });
}
