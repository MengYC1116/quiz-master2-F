// 十六批 C：docx_creator 库级断言（WORD-DESIGN.md §1/§3，D-191/D-193/D-195/D-196）。
//
// 直接对 DocxDocumentBuilder + DocxExporter().exportToBytes 断言，
// 不经过快照/服务层：东亚字体、A4、15 mm 边距、页码字段、
// 不嵌入字体、图片 extent 与指定 pt 一致。
import 'package:docx_creator/docx_creator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/services/word_export/word_document_builder.dart';

import 'b16_word_test_helpers.dart';

Future<UnpackedDocx> exportDoc(
  void Function(DocxDocumentBuilder builder) build,
) async {
  final builder = DocxDocumentBuilder();
  applyWordSection(
    builder,
    header: wordHeader(subjectName: '数学', exportDateText: '2026-11-21'),
    footer: wordFooter(),
  );
  build(builder);
  final bytes = await DocxExporter().exportToBytes(builder.build());
  return UnpackedDocx(bytes);
}

void main() {
  group('docx_creator 库级（D-191/D-193/D-195/D-196）', () {
    test('run 级三槽同名：eastAsia 写 Noto Sans SC', () async {
      final doc = await exportDoc((b) {
        b.paragraph(wordTextParagraph('中文测试', fontSize: 11));
      });
      expect(doc.documentXml, contains('w:eastAsia="Noto Sans SC"'));
      expect(doc.documentXml, contains('w:ascii="Noto Sans SC"'));
      expect(doc.documentXml, contains('w:hAnsi="Noto Sans SC"'));
      // 字体只指名：fontTable 里也不应出现 Noto 条目（无 addFont 调用）。
      expect(doc.partText('word/fontTable.xml'), isNot(contains('Noto')));
    });

    test('A4 纵向：sectPr pgSz 11906×16838', () async {
      final doc = await exportDoc((b) {
        b.paragraph(wordTextParagraph('x', fontSize: 11));
      });
      expect(doc.documentXml, contains('w:pgSz'));
      expect(doc.documentXml, contains('w:w="11906"'));
      expect(doc.documentXml, contains('w:h="16838"'));
    });

    test('页边距 15 mm：四边均为 850 twips', () async {
      final doc = await exportDoc((b) {
        b.paragraph(wordTextParagraph('x', fontSize: 11));
      });
      expect(doc.documentXml, contains('w:pgMar'));
      expect(doc.documentXml, contains('w:top="850"'));
      expect(doc.documentXml, contains('w:right="850"'));
      expect(doc.documentXml, contains('w:bottom="850"'));
      expect(doc.documentXml, contains('w:left="850"'));
    });

    test('页脚 PAGE + NUMPAGES 字段（无缓存值，D-196）', () async {
      final doc = await exportDoc((b) {
        b.paragraph(wordTextParagraph('x', fontSize: 11));
      });
      expect(
        doc.partNames.any((n) => n.startsWith('word/footer')),
        isTrue,
      );
      final footerXml = doc.partNames
          .where((n) => n.startsWith('word/footer'))
          .map(doc.partText)
          .join();
      expect(footerXml, contains('instrText'));
      expect(footerXml, contains('PAGE'));
      expect(footerXml, contains('NUMPAGES'));
      expect(footerXml, contains('第 '));
      // 无缓存值：字段后不跟已算好的页码文本（不补 1/1 占位）。
      expect(footerXml, isNot(contains('<w:t>1</w:t>')));
    });

    test('不嵌入字体：无 word/fonts 部件', () async {
      final doc = await exportDoc((b) {
        b.paragraph(wordTextParagraph('中文测试', fontSize: 11));
      });
      expect(doc.hasFontsPart, isFalse);
      expect(doc.partText('word/fontTable.xml'), isNot(contains('Noto')));
    });

    test('图片 extent 与指定 pt 一致（100 pt × 50 pt → EMU）', () async {
      final doc = await exportDoc((b) {
        b.image(
          wordImageBlock(makePng(200, 100), widthPt: 100, heightPt: 50),
        );
      });
      expect(doc.mediaNames.length, 1);
      // 1 pt = 12700 EMU：100 pt → 1270000，50 pt → 635000。
      expect(doc.documentXml, contains('cx="1270000"'));
      expect(doc.documentXml, contains('cy="635000"'));
      expect(
        doc.mediaMd5(doc.mediaNames.single),
        md5Of(makePng(200, 100)),
      );
    });
  });
}
