// 十五批 M2-3：平台交付与文件名测试（PLAN-15-REV3 §5 M2-2/M2-3/M2-4）。
//
// 覆盖：文件名默认规则（学科/文件夹/日期/答案后缀/多学科/多文件夹/
// 禁用字符/过长截断保留日期）与校验 API；Windows 另存为对话框流程
// （取消不留文件、已确认覆盖时先验证后覆盖）；Android 下载目录流程
// （目录缺失整单失败、目标冲突顺延）；双文件部分成功（deliverAll
// 逐份记状态，一份失败不影响已交付的另一份）；分享与打开（注入假实现）。
//
// 平台分发在 Linux 测试机上用 platformOverride 模拟（见
// PdfDeliveryService）；Windows/Android 真机行为列入 M4 真机清单，
// 不在本文件内臆断。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:quiz_master2/services/pdf_export/export_filename.dart';
import 'package:quiz_master2/services/pdf_export/export_versions.dart';
import 'package:quiz_master2/services/pdf_export/pdf_delivery.dart';
import 'package:quiz_master2/services/pdf_export/pdf_page_counter.dart';
import 'package:share_plus/share_plus.dart';

Future<Uint8List> _makePdf({int lines = 10}) async {
  final fontBytes = await File(
    'assets/fonts/NotoSansSC-Regular.ttf',
  ).readAsBytes();
  final font = pw.Font.ttf(fontBytes.buffer.asByteData());
  final doc = pw.Document(title: 'delivery-test', author: 'test');
  doc.addPage(
    pw.MultiPage(
      maxPages: 500,
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.all(42.5),
        theme: pw.ThemeData.withFont(base: font, bold: font),
      ),
      build: (_) => [
        for (var i = 0; i < lines; i++)
          pw.Text(
            '第 $i 行测试文字',
            style: pw.TextStyle(font: font, fontSize: 11),
            overflow: pw.TextOverflow.span,
          ),
      ],
    ),
  );
  return doc.save();
}

void main() {
  group('文件名默认规则', () {
    final date = DateTime(2026, 11, 21);

    test('基本规则：错题本_学科_文件夹_日期.pdf', () {
      expect(
        buildExportFileName(
          subjectName: '数学',
          folderName: '高数',
          date: date,
          version: ExportVersion.practice,
        ),
        '错题本_数学_高数_20261121.pdf',
      );
    });

    test('无文件夹时省掉该段；答案版后缀 _答案', () {
      expect(
        buildExportFileName(
          subjectName: '英语',
          date: date,
          version: ExportVersion.practice,
        ),
        '错题本_英语_20261121.pdf',
      );
      expect(
        buildExportFileName(
          subjectName: '英语',
          folderName: '阅读',
          date: date,
          version: ExportVersion.answer,
        ),
        '错题本_英语_阅读_20261121_答案.pdf',
      );
    });

    test('多学科/多文件夹用展示名，不取第一道题的代表', () {
      expect(
        buildExportFileName(
          subjectName: '多学科',
          folderName: '多文件夹',
          date: date,
          version: ExportVersion.practice,
        ),
        '错题本_多学科_多文件夹_20261121.pdf',
      );
    });

    test('Windows 禁用字符换成下划线（全角冒号不在禁用集里，保留）', () {
      expect(
        buildExportFileName(
          subjectName: '数/学：必修',
          folderName: '第一章*习题?',
          date: date,
          version: ExportVersion.practice,
        ),
        '错题本_数_学：必修_第一章_习题__20261121.pdf',
      );
    });

    test('过长截断并保留日期', () {
      final longSubject = '数' * 60;
      final longFolder = '文' * 60;
      final name = buildExportFileName(
        subjectName: longSubject,
        folderName: longFolder,
        date: date,
        version: ExportVersion.answer,
      );
      expect(name.endsWith('_20261121_答案.pdf'), isTrue);
      expect(name.contains('20261121'), isTrue);
      final stem = name.substring(0, name.length - 4);
      expect(
        stem.runes.length,
        lessThanOrEqualTo(kMaxExportFileNameStemLength + 3),
      );
    });

    test('sanitize 与 validate', () {
      expect(sanitizeExportFileName('a/b:c'), 'a_b_c');
      expect(sanitizeExportFileName('  '), '错题本导出');
      expect(validateExportFileName('错题本_数学_20261121.pdf'), isNull);
      expect(validateExportFileName(''), isNotNull);
      expect(validateExportFileName('a.txt'), contains('.pdf'));
      expect(validateExportFileName('a/b.pdf'), isNotNull);
      expect(validateExportFileName('a.pdf '), isNotNull);
      expect(
        validateExportFileName('${'长' * 101}.pdf'),
        isNotNull,
      );
    });
  });

  group('平台交付', () {
    late Directory tempRoot;
    late Uint8List pdfBytes;
    late int pdfPages;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('b15-m2-delivery-');
      pdfBytes = await _makePdf();
      pdfPages = countPdfPages(pdfBytes)!;
    });

    tearDown(() async {
      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('deliverToPath：成功落盘，返回实际文件名与页数', () async {
      final service = PdfDeliveryService();
      final result = await service.deliverToPath(
        pdfBytes: pdfBytes,
        targetPath: '${tempRoot.path}/out.pdf',
        version: ExportVersion.practice,
        expectedPages: pdfPages,
      );
      expect(result.status, FileDeliveryStatus.delivered);
      expect(result.filePath, '${tempRoot.path}/out.pdf');
      expect(result.fileName, 'out.pdf');
      expect(result.pageCount, pdfPages);
      expect(await File(result.filePath!).readAsBytes(), pdfBytes);
    });

    test('deliverToPath：页数不符时失败、不留文件', () async {
      final service = PdfDeliveryService();
      final result = await service.deliverToPath(
        pdfBytes: pdfBytes,
        targetPath: '${tempRoot.path}/out.pdf',
        version: ExportVersion.practice,
        expectedPages: pdfPages + 1,
      );
      expect(result.status, FileDeliveryStatus.failed);
      expect(result.error, isNotNull);
      expect(File('${tempRoot.path}/out.pdf').existsSync(), isFalse);
    });

    test('Windows：对话框取消即整单取消，不留文件', () async {
      final service = PdfDeliveryService(
        platformOverride: PdfDeliveryPlatform.windows,
        pickSavePath: ({required dialogTitle, required fileName}) async =>
            null,
      );
      final result = await service.deliver(
        pdfBytes: pdfBytes,
        fileName: 'out.pdf',
        version: ExportVersion.practice,
        expectedPages: pdfPages,
      );
      expect(result.status, FileDeliveryStatus.cancelled);
      expect(result.filePath, isNull);
      expect(tempRoot.listSync(), isEmpty);
    });

    test('Windows：对话框返回已有路径时先验证后覆盖', () async {
      final target = File('${tempRoot.path}/old.pdf');
      final oldBytes = Uint8List.fromList('old'.codeUnits);
      await target.writeAsBytes(oldBytes);
      final service = PdfDeliveryService(
        platformOverride: PdfDeliveryPlatform.windows,
        pickSavePath: ({required dialogTitle, required fileName}) async =>
            target.path,
      );
      final result = await service.deliver(
        pdfBytes: pdfBytes,
        fileName: 'old.pdf',
        version: ExportVersion.practice,
        expectedPages: pdfPages,
      );
      expect(result.status, FileDeliveryStatus.delivered);
      expect(result.filePath, target.path);
      expect(await target.readAsBytes(), pdfBytes);
    });

    test('Android：下载目录缺失时整单失败，不静默改写私有目录', () async {
      final service = PdfDeliveryService(
        platformOverride: PdfDeliveryPlatform.android,
        downloadsDirectory: () async => null,
      );
      final result = await service.deliver(
        pdfBytes: pdfBytes,
        fileName: 'out.pdf',
        version: ExportVersion.answer,
        expectedPages: pdfPages,
      );
      expect(result.status, FileDeliveryStatus.failed);
      expect(result.error, contains('下载目录'));
      expect(tempRoot.listSync(), isEmpty);
    });

    test('Android：保存到下载目录，目标冲突顺延命名', () async {
      final downloads = Directory('${tempRoot.path}/Downloads')
        ..createSync();
      await File(
        '${downloads.path}/错题本_数学_20261121.pdf',
      ).writeAsBytes(Uint8List.fromList('old'.codeUnits));
      final service = PdfDeliveryService(
        platformOverride: PdfDeliveryPlatform.android,
        downloadsDirectory: () async => downloads,
      );
      final result = await service.deliver(
        pdfBytes: pdfBytes,
        fileName: '错题本_数学_20261121.pdf',
        version: ExportVersion.practice,
        expectedPages: pdfPages,
      );
      expect(result.status, FileDeliveryStatus.delivered);
      expect(result.fileName, '错题本_数学_20261121（1）.pdf');
      expect(
        await File(result.filePath!).readAsBytes(),
        pdfBytes,
      );
      // 原文件未被破坏。
      expect(
        await File(
          '${downloads.path}/错题本_数学_20261121.pdf',
        ).readAsBytes(),
        Uint8List.fromList('old'.codeUnits),
      );
    });

    test('deliverAll 双文件部分成功：一份失败不影响已交付的另一份', () async {
      final picked = <String?>[];
      final service = PdfDeliveryService(
        platformOverride: PdfDeliveryPlatform.windows,
        pickSavePath: ({required dialogTitle, required fileName}) async {
          // 第一份返回正常路径，第二份返回父路径是文件的非法路径。
          if (picked.isEmpty) {
            picked.add('${tempRoot.path}/practice.pdf');
            return picked.first;
          }
          picked.add('${tempRoot.path}/blocker/answer.pdf');
          return picked.last;
        },
      );
      await File('${tempRoot.path}/blocker').writeAsString('not a dir');
      final results = await service.deliverAll(
        requests: [
          VersionDeliveryRequest(
            pdfBytes: pdfBytes,
            fileName: 'practice.pdf',
            version: ExportVersion.practice,
            expectedPages: pdfPages,
          ),
          VersionDeliveryRequest(
            pdfBytes: pdfBytes,
            fileName: 'answer.pdf',
            version: ExportVersion.answer,
            expectedPages: pdfPages,
          ),
        ],
      );
      expect(results, hasLength(2));
      // 第一份已完整验证并发布、保留；第二份失败、有原因、无半成品。
      expect(results[0].status, FileDeliveryStatus.delivered);
      expect(results[0].version, ExportVersion.practice);
      expect(
        await File(results[0].filePath!).readAsBytes(),
        pdfBytes,
      );
      expect(results[1].status, FileDeliveryStatus.failed);
      expect(results[1].version, ExportVersion.answer);
      expect(results[1].error, isNotNull);
      expect(results[1].filePath, isNull);
      expect(File('${tempRoot.path}/blocker/answer.pdf').existsSync(), isFalse);
    });

    test('deliverAll：第二份取消时第一份保留', () async {
      var calls = 0;
      final service = PdfDeliveryService(
        platformOverride: PdfDeliveryPlatform.windows,
        pickSavePath: ({required dialogTitle, required fileName}) async {
          calls++;
          if (calls == 1) return '${tempRoot.path}/practice.pdf';
          return null;
        },
      );
      final results = await service.deliverAll(
        requests: [
          VersionDeliveryRequest(
            pdfBytes: pdfBytes,
            fileName: 'practice.pdf',
            version: ExportVersion.practice,
            expectedPages: pdfPages,
          ),
          VersionDeliveryRequest(
            pdfBytes: pdfBytes,
            fileName: 'answer.pdf',
            version: ExportVersion.answer,
            expectedPages: pdfPages,
          ),
        ],
      );
      expect(results[0].status, FileDeliveryStatus.delivered);
      expect(results[1].status, FileDeliveryStatus.cancelled);
      expect(File('${tempRoot.path}/practice.pdf').existsSync(), isTrue);
    });

    test('其它平台 deliver 返回失败（不静默改写别处）', () async {
      final service = PdfDeliveryService(
        platformOverride: PdfDeliveryPlatform.other,
      );
      final result = await service.deliver(
        pdfBytes: pdfBytes,
        fileName: 'out.pdf',
        version: ExportVersion.practice,
        expectedPages: pdfPages,
      );
      expect(result.status, FileDeliveryStatus.failed);
      expect(tempRoot.listSync(), isEmpty);
    });

    test('分享：成功/关闭/文件不存在分别记状态', () async {
      final target = File('${tempRoot.path}/share.pdf');
      await target.writeAsBytes(pdfBytes);
      final sharedService = PdfDeliveryService(
        shareFile: (_, _) async => ShareResultStatus.success,
      );
      expect(
        (await sharedService.sharePdf(target.path)).outcome,
        ShareOutcome.shared,
      );
      final dismissedService = PdfDeliveryService(
        shareFile: (_, _) async => ShareResultStatus.dismissed,
      );
      expect(
        (await dismissedService.sharePdf(target.path)).outcome,
        ShareOutcome.dismissed,
      );
      final missing = await sharedService.sharePdf(
        '${tempRoot.path}/no-such.pdf',
      );
      expect(missing.outcome, ShareOutcome.failed);
    });

    test('打开：注入启动器成功/失败，文件不存在返回 false', () async {
      final target = File('${tempRoot.path}/open.pdf');
      await target.writeAsBytes(pdfBytes);
      final openedPaths = <String>[];
      final service = PdfDeliveryService(
        openFile: (path) async {
          openedPaths.add(path);
          return true;
        },
        openFolder: (path) async {
          openedPaths.add('folder:$path');
          return true;
        },
      );
      expect(await service.openPdf(target.path), isTrue);
      expect(
        await service.openContainingFolder(target.path),
        isTrue,
      );
      expect(openedPaths, [target.path, 'folder:${target.path}']);
      expect(
        await service.openPdf('${tempRoot.path}/no-such.pdf'),
        isFalse,
      );
      final failingService = PdfDeliveryService(
        openFile: (_) async => false,
      );
      expect(await failingService.openPdf(target.path), isFalse);
    });
  });
}
