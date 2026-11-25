// 十五批 M2-2：原子写入与目标冲突测试（PLAN-15-REV3 §5 M2-2/M2-4）。
//
// 覆盖：PDF 页数计数（1 页 / 多页 / 非 PDF / 空字节）；原子写入成功
// （正式位置有完整文件、无临时文件残留）；验证失败 → 正式位置无半截
// 文件、原有文件未被破坏；写失败（模拟磁盘满）→ 整单失败、临时文件
// 清理干净、原有文件未被破坏；目标冲突顺延命名（（1）、（2）……）；
// 用户主动覆盖时先验证后覆盖（验证失败则旧文件原样保留）；页数与
// 预期不一致时验证失败。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:quiz_master2/services/pdf_export/atomic_file_writer.dart';
import 'package:quiz_master2/services/pdf_export/pdf_page_counter.dart';

Future<Uint8List> _makePdf({required int pages}) async {
  final fontBytes = await File(
    'assets/fonts/NotoSansSC-Regular.ttf',
  ).readAsBytes();
  final font = pw.Font.ttf(fontBytes.buffer.asByteData());
  final doc = pw.Document(title: 'atomic-test', author: 'test');
  doc.addPage(
    pw.MultiPage(
      maxPages: 500,
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.all(42.5),
        theme: pw.ThemeData.withFont(base: font, bold: font),
      ),
      build: (_) => [
        for (var i = 0; i < pages * 45; i++)
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

/// 目录内残留的临时文件（应为空：成功时已移走，失败时已清理）。
List<String> _leftoverTmpFiles(Directory dir) {
  if (!dir.existsSync()) return const [];
  return dir
      .listSync()
      .whereType<File>()
      .map((f) => f.path)
      .where((p) => p.contains('.tmp-'))
      .toList();
}

void main() {
  group('PDF 页数计数', () {
    test('1 页与多页 PDF 计数正确', () async {
      final one = await _makePdf(pages: 1);
      final three = await _makePdf(pages: 3);
      expect(isPdfBytes(one), isTrue);
      expect(countPdfPages(one), 1);
      expect(countPdfPages(three), 3);
    });

    test('非 PDF 与空字节返回 null', () {
      expect(isPdfBytes(Uint8List(0)), isFalse);
      expect(countPdfPages(Uint8List(0)), isNull);
      expect(countPdfPages(Uint8List.fromList([1, 2, 3, 4, 5])), isNull);
      expect(
        countPdfPages(
          Uint8List.fromList('hello world, not a pdf'.codeUnits),
        ),
        isNull,
      );
    });

    test('只有 %PDF- 头、无线页树时返回 null', () {
      final bytes = Uint8List.fromList('%PDF-1.5\n'.codeUnits);
      expect(isPdfBytes(bytes), isTrue);
      expect(countPdfPages(bytes), isNull);
    });
  });

  group('原子写入', () {
    late Directory tempRoot;
    late Uint8List pdfBytes;
    late int pdfPages;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('b15-m2-atomic-');
      pdfBytes = await _makePdf(pages: 2);
      // 实际页数以字节计数为准（行高取整可能使页数浮动一页）。
      pdfPages = countPdfPages(pdfBytes)!;
      expect(pdfPages, greaterThanOrEqualTo(1));
    });

    tearDown(() async {
      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('成功：正式位置有完整文件，无临时文件残留', () async {
      final target = File('${tempRoot.path}/out.pdf');
      final written = await writePdfAtomically(
        target: target,
        bytes: pdfBytes,
        expectedPages: pdfPages,
      );
      expect(written.path, target.path);
      expect(await written.readAsBytes(), pdfBytes);
      expect(countPdfPages(await written.readAsBytes()), pdfPages);
      expect(_leftoverTmpFiles(tempRoot), isEmpty);
    });

    test('目标目录不存在时自动创建', () async {
      final target = File('${tempRoot.path}/sub/dir/out.pdf');
      final written = await writePdfAtomically(
        target: target,
        bytes: pdfBytes,
        expectedPages: pdfPages,
      );
      expect(written.existsSync(), isTrue);
      expect(_leftoverTmpFiles(tempRoot), isEmpty);
    });

    test('验证失败：正式位置无半截文件，临时文件清理干净', () async {
      final target = File('${tempRoot.path}/out.pdf');
      await expectLater(
        writePdfAtomically(
          target: target,
          bytes: pdfBytes,
          expectedPages: pdfPages,
          validate: (_, _) async => false,
        ),
        throwsA(isA<AtomicWriteException>()),
      );
      expect(target.existsSync(), isFalse);
      expect(_leftoverTmpFiles(tempRoot), isEmpty);
    });

    test('页数与预期不一致：验证失败，不留文件', () async {
      final target = File('${tempRoot.path}/out.pdf');
      await expectLater(
        writePdfAtomically(
          target: target,
          bytes: pdfBytes,
          expectedPages: pdfPages + 3,
        ),
        throwsA(isA<AtomicWriteException>()),
      );
      expect(target.existsSync(), isFalse);
      expect(_leftoverTmpFiles(tempRoot), isEmpty);
    });

    test('写失败（模拟磁盘满）：整单失败、原有文件未被破坏', () async {
      final target = File('${tempRoot.path}/out.pdf');
      final oldBytes = Uint8List.fromList('old file'.codeUnits);
      await target.writeAsBytes(oldBytes);
      await expectLater(
        writePdfAtomically(
          target: target,
          bytes: pdfBytes,
          expectedPages: pdfPages,
          overwrite: true,
          writeStep: (_, _) async {
            throw const FileSystemException('模拟磁盘满', 'out.pdf');
          },
        ),
        throwsA(isA<AtomicWriteException>()),
      );
      // 旧文件原样保留；顺延目标（1）也不应出现。
      expect(await target.readAsBytes(), oldBytes);
      expect(File('${tempRoot.path}/out（1）.pdf').existsSync(), isFalse);
      expect(_leftoverTmpFiles(tempRoot), isEmpty);
    });

    test('目标冲突：已存在时顺延命名，不静默覆盖', () async {
      final target = File('${tempRoot.path}/错题本_数学_20261121.pdf');
      final oldBytes = Uint8List.fromList('old'.codeUnits);
      await target.writeAsBytes(oldBytes);
      final first = await writePdfAtomically(
        target: target,
        bytes: pdfBytes,
        expectedPages: pdfPages,
      );
      expect(
        first.path,
        p.join(tempRoot.path, '错题本_数学_20261121（1）.pdf'),
      );
      expect(await first.readAsBytes(), pdfBytes);
      // 原文件未被破坏。
      expect(await target.readAsBytes(), oldBytes);
      final second = await writePdfAtomically(
        target: target,
        bytes: pdfBytes,
        expectedPages: pdfPages,
      );
      expect(
        second.path,
        p.join(tempRoot.path, '错题本_数学_20261121（2）.pdf'),
      );
      expect(_leftoverTmpFiles(tempRoot), isEmpty);
    });

    test('用户主动覆盖：先验证后覆盖，验证失败旧文件原样保留', () async {
      final target = File('${tempRoot.path}/out.pdf');
      final oldBytes = Uint8List.fromList('old file'.codeUnits);
      await target.writeAsBytes(oldBytes);
      // 验证失败 → 不覆盖。
      await expectLater(
        writePdfAtomically(
          target: target,
          bytes: pdfBytes,
          expectedPages: pdfPages,
          overwrite: true,
          validate: (_, _) async => false,
        ),
        throwsA(isA<AtomicWriteException>()),
      );
      expect(await target.readAsBytes(), oldBytes);
      expect(_leftoverTmpFiles(tempRoot), isEmpty);
      // 验证通过 → 覆盖。
      final written = await writePdfAtomically(
        target: target,
        bytes: pdfBytes,
        expectedPages: pdfPages,
        overwrite: true,
      );
      expect(written.path, target.path);
      expect(await written.readAsBytes(), pdfBytes);
    });

    test('目标父路径是文件时整单失败并明确报错', () async {
      final blocker = File('${tempRoot.path}/blocker');
      await blocker.writeAsString('not a dir');
      final target = File('${tempRoot.path}/blocker/out.pdf');
      await expectLater(
        writePdfAtomically(
          target: target,
          bytes: pdfBytes,
          expectedPages: pdfPages,
        ),
        throwsA(isA<AtomicWriteException>()),
      );
      expect(_leftoverTmpFiles(tempRoot), isEmpty);
    });
  });
}
