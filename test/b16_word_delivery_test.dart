// 十六批 C：文件名与交付（WORD-DESIGN.md §5，D-195/D-201/D-203）。
//
// 默认名与 PDF 同干只改扩展名、校验 .docx、原子写入 +
// defaultDocxFileValidator、冲突顺延、校验失败不留文件。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/services/pdf_export/export_filename.dart';
import 'package:quiz_master2/services/pdf_export/export_versions.dart';
import 'package:quiz_master2/services/pdf_export/pdf_delivery.dart';
import 'package:quiz_master2/services/word_export/word_delivery.dart';

import 'b16_word_test_helpers.dart';

void main() {
  late Directory tempRoot;
  late FakeExportQuestionSource source;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('b16-word-deliver-');
    source = FakeExportQuestionSource();
  });

  tearDown(() async {
    if (tempRoot.existsSync()) {
      await tempRoot.delete(recursive: true);
    }
  });

  /// 生成一份无图 docx 字节（imageCount 0）。
  Future<Uint8List> makeDocxBytes() async {
    addChoiceQuestion(source, 'q0');
    final service = makeWordService(source, tempRoot, hasKey: true);
    final result = await generateWord(service, ['q0']);
    expect(result.imageCount, 0);
    return result.docxBytes;
  }

  group('文件名与交付（D-195/D-201）', () {
    test('默认名与 PDF 同干只改扩展名（多学科/多文件夹/_答案/100 字截断）',
        () {
      final date = DateTime(2026, 11, 21);
      expect(
        buildExportFileName(
          subjectName: '数学',
          folderName: '试卷',
          date: date,
          version: ExportVersion.practice,
          format: ExportFormat.word,
        ),
        '错题本_数学_试卷_20261121.docx',
      );
      expect(
        buildExportFileName(
          subjectName: '数学',
          folderName: '试卷',
          date: date,
          version: ExportVersion.answer,
          format: ExportFormat.word,
        ),
        '错题本_数学_试卷_20261121_答案.docx',
      );
      // 同输入换格式只改扩展名。
      expect(
        buildExportFileName(
          subjectName: '数学',
          folderName: '试卷',
          date: date,
          version: ExportVersion.practice,
          format: ExportFormat.word,
        ).replaceAll('.docx', '.pdf'),
        buildExportFileName(
          subjectName: '数学',
          folderName: '试卷',
          date: date,
          version: ExportVersion.practice,
        ),
      );
      // 超长干截断到 100 rune（含日期与后缀空间）。
      final long = buildExportFileName(
        subjectName: '数学' * 60,
        folderName: '试卷' * 60,
        date: date,
        version: ExportVersion.practice,
        format: ExportFormat.word,
      );
      final stem = long.substring(0, long.length - '.docx'.length);
      expect(stem.runes.length, lessThanOrEqualTo(kMaxExportFileNameStemLength));
      expect(long.endsWith('20261121.docx'), isTrue);
    });

    test('validateExportFileName：Word 格式认 .docx、拒 .pdf；默认仍认 .pdf',
        () {
      expect(
        validateExportFileName('a.docx', format: ExportFormat.word),
        isNull,
      );
      expect(
        validateExportFileName('a.pdf', format: ExportFormat.word),
        contains('.docx'),
      );
      expect(validateExportFileName('a.txt'), contains('.pdf'));
      expect(
        validateExportFileName('a.docx'),
        contains('.pdf'),
      );
    });

    test('safeFileName 同款清理（Windows 禁用字符换下划线）', () {
      expect(sanitizeExportFileName('数/学:试卷?'), '数_学_试卷_');
      expect(sanitizeExportFileName('  '), '错题本导出');
    });

    test('原子写入 + defaultDocxFileValidator（PK + 部件 + 图片数）',
        () async {
      final bytes = await makeDocxBytes();
      final file = File('${tempRoot.path}/out.docx');
      await file.writeAsBytes(bytes);
      expect(await defaultDocxFileValidator(file, 0), isTrue);
      expect(await defaultDocxFileValidator(file, 1), isFalse);
      // 非 docx 字节（无 PK 魔数）→ false。
      final garbage = File('${tempRoot.path}/garbage.docx');
      await garbage.writeAsBytes(Uint8List.fromList([1, 2, 3, 4]));
      expect(await defaultDocxFileValidator(garbage, 0), isFalse);
      // ZIP 结构但缺 word/document.xml → false。
      final emptyZip = File('${tempRoot.path}/empty.docx');
      await emptyZip.writeAsBytes(
        Uint8List.fromList('PK\x03\x04'.codeUnits),
      );
      expect(await defaultDocxFileValidator(emptyZip, 0), isFalse);
    });

    test('Windows 交付：对话框选位 → 落盘成功，结果不带页数', () async {
      final bytes = await makeDocxBytes();
      final target = '${tempRoot.path}/save.docx';
      final service = WordDeliveryService(
        platformOverride: PdfDeliveryPlatform.windows,
        pickSavePath: ({required dialogTitle, required fileName}) async {
          expect(dialogTitle, '保存 Word 文档');
          expect(fileName, '错题本_数学_20261121.docx');
          return target;
        },
      );
      final result = await service.deliver(
        docxBytes: bytes,
        fileName: '错题本_数学_20261121.docx',
        expectedImageCount: 0,
      );
      expect(result.status, FileDeliveryStatus.delivered);
      expect(result.pageCount, isNull);
      expect(File(target).existsSync(), isTrue);
      expect(
        await defaultDocxFileValidator(File(target), 0),
        isTrue,
      );
    });

    test('Android 交付：同名顺延（1）/（2），校验失败不留文件', () async {
      final bytes = await makeDocxBytes();
      final downloads = Directory('${tempRoot.path}/dl')..createSync();
      final service = WordDeliveryService(
        platformOverride: PdfDeliveryPlatform.android,
        downloadsDirectory: () async => downloads,
      );
      final first = await service.deliver(
        docxBytes: bytes,
        fileName: 'out.docx',
        expectedImageCount: 0,
      );
      expect(first.status, FileDeliveryStatus.delivered);
      expect(first.fileName, 'out.docx');
      final second = await service.deliver(
        docxBytes: bytes,
        fileName: 'out.docx',
        expectedImageCount: 0,
      );
      expect(second.status, FileDeliveryStatus.delivered);
      expect(second.fileName, 'out（1）.docx');
      expect(File('${downloads.path}/out.docx').existsSync(), isTrue);
      expect(File('${downloads.path}/out（1）.docx').existsSync(), isTrue);
      // 图片数不符 → 验证失败，不留文件。
      final bad = await service.deliver(
        docxBytes: bytes,
        fileName: 'bad.docx',
        expectedImageCount: 3,
      );
      expect(bad.status, FileDeliveryStatus.failed);
      expect(File('${downloads.path}/bad.docx').existsSync(), isFalse);
    });
  });
}
