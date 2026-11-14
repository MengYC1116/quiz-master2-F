// PDF 多页修框 widget 测试：修框编辑器打开 → 点第 2 页缩略图换底图
// 并自动检测 → 确认拆出两页的题（sourceKind pdf、sourcePage 1/2）。
// 页图在 setUpAll 用真实 PdfRenderService（PDFium）从手写最小 PDF
// 渲出（真实 zone）；编辑器流程走 test/collect_page_test.dart 的
// FakeRepo（内存草稿，与既有收集测试同模式），不碰真实数据库。
// 真实导入（enqueue）由 test/pdf_render_service_test.dart 覆盖。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/pdf_render_service.dart';
import 'package:quiz_master2/services/yolo_onnx_service.dart';

import 'collect_page_test.dart' as collect_test;

late final Directory _tmp;

/// 与 test/pdf_render_service_test.dart 里的 buildTestPdf 同算法
/// （手写最小 PDF：每页文字 + 黑色实心矩形）。
Uint8List buildTestPdf({required int pages}) {
  final objs = <(int, List<int>)>[];
  final kids =
      List.generate(pages, (i) => '${4 + i * 2} 0 R').join(' ');
  objs.add((1, '<< /Type /Catalog /Pages 2 0 R >>'.codeUnits));
  objs.add((2,
      '<< /Type /Pages /Kids [$kids] /Count $pages >>'.codeUnits));
  objs.add((3, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
      .codeUnits));
  for (var i = 0; i < pages; i++) {
    final pageNo = i + 1;
    final content =
        'BT /F1 48 Tf 100 700 Td (Page $pageNo - Hello) Tj ET\n'
        '0 0 0 rg 100 500 200 100 re f\n';
    objs.add((
      4 + i * 2,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
              '/Resources << /Font << /F1 3 0 R >> >> '
              '/Contents ${4 + i * 2 + 1} 0 R >>'
          .codeUnits
    ));
    final stream = '<< /Length ${content.length} >>\nstream\n'
        '$content\nendstream';
    objs.add((4 + i * 2 + 1, stream.codeUnits));
  }
  final out = <int>[...'%PDF-1.4\n'.codeUnits];
  final offsets = <int, int>{};
  for (final (num, body) in objs) {
    offsets[num] = out.length;
    out.addAll('$num 0 obj\n'.codeUnits);
    out.addAll(body);
    out.addAll('\nendobj\n'.codeUnits);
  }
  final xrefPos = out.length;
  final maxNum = objs.map((e) => e.$1).reduce((a, b) => a > b ? a : b);
  out.addAll('xref\n0 ${maxNum + 1}\n'.codeUnits);
  out.addAll('0000000000 65535 f \n'.codeUnits);
  for (var n = 1; n <= maxNum; n++) {
    out.addAll(
        '${offsets[n]!.toString().padLeft(10, '0')} 00000 n \n'.codeUnits);
  }
  out.addAll('trailer\n<< /Size ${maxNum + 1} /Root 1 0 R >>\n'
          'startxref\n$xrefPos\n%%EOF\n'
      .codeUnits);
  return Uint8List.fromList(out);
}

/// 桩检测：每页固定返回 1 个题级框，并记录每次调用的图路径与页码
/// （断言切页检测用的是该页的页图）。
class RecordingYolo extends YoloOnnxService {
  final calls = <({String imagePath, int page})>[];

  @override
  Future<DetectionResult> detectPage({
    required String imagePath,
    required int page,
  }) async {
    calls.add((imagePath: imagePath, page: page));
    return DetectionResult(
      boxes: [
        QuestionBox(
          id: 'box-q1',
          layer: 1,
          type: 'question',
          x: 0.06,
          y: 0.05,
          w: 0.88,
          h: 0.85,
          page: page,
        ),
      ],
      usedFallback: false,
    );
  }
}

/// 画布当前底图：Image.file 的 FileImage 路径以 [suffix] 结尾。
Finder canvasImage(String suffix) => find.byWidgetPredicate(
      (w) =>
          w is Image &&
          w.image is FileImage &&
          (w.image as FileImage).file.path.endsWith(suffix),
    );

void main() {
  setUpAll(() async {
    _tmp = await Directory.systemTemp.createTemp('qm2-pdf-collect');
    AppDatabase.testDataDirectory = _tmp.path;
    // 真实渲染 3 页，落到 FakeRepo 任务的页图位置
    // （imports/task-pdf/pages/page-001..003.png）。
    final pdf = File('${_tmp.path}/three.pdf');
    await pdf.writeAsBytes(buildTestPdf(pages: 3));
    await PdfRenderService().renderAllPagesToDir(
      pdf.path,
      '${_tmp.path}/imports/task-pdf/pages',
    );
    await File('${_tmp.path}/imports/task-pdf/original.pdf')
        .writeAsBytes(await pdf.readAsBytes());
  });

  tearDownAll(() async {
    AppDatabase.testDataDirectory = null;
    await _tmp.delete(recursive: true);
  });

  testWidgets('PDF 多页：修框切页换底图、自动检测、确认拆出两页的题',
      (tester) async {
    final repo = collect_test.FakeRepo([
      collect_test.task(
        'task-pdf',
        '卷子.pdf · 第1页 · 第1题',
        status: CollectStatus.needBox,
        pageCount: 3,
        sourcePath: 'imports/task-pdf/original.pdf',
      ),
    ]);
    final yolo = RecordingYolo();
    await collect_test.pumpCollect(
      tester,
      repo: repo,
      yoloService: yolo,
    );
    expect(find.text('修框'), findsOneWidget);

    // 打开编辑器：第 1 页底图是 page-001.png，检测跑在第 1 页图上。
    await collect_test.openEditor(tester, '修框');
    expect(canvasImage('page-001.png'), findsOneWidget);
    expect(
      yolo.calls.any((c) =>
          c.page == 1 && c.imagePath.endsWith('page-001.png')),
      isTrue,
    );

    // 点第 2 页缩略图：底图换成 page-002.png，空页自动检测也用第 2 页图。
    await tester.tap(find.byKey(const Key('editor-thumb-2')));
    await tester.pumpAndSettle();
    expect(find.textContaining('第2页'), findsWidgets);
    expect(canvasImage('page-002.png'), findsOneWidget);
    expect(
      yolo.calls.any((c) =>
          c.page == 2 && c.imagePath.endsWith('page-002.png')),
      isTrue,
    );
    // 第 2 页自动检出的框在画布上。
    expect(
      find.descendant(
        of: find.byKey(const Key('box-editor-canvas')),
        matching: find.textContaining('题级框 1'),
      ),
      findsOneWidget,
    );

    // 确认：第 1、2 页各 1 道题，共 2 个待整理任务。
    // 等待拆题完成：_confirmSplit 在 runAsync 的真实 zone 里跑
    // dart:ui 解码 + 写盘；全量并行时 CPU 争用会让固定 4 秒不够，
    // 改为轮询 savedQuestions（上限 ~30 秒），不等死。
    await tester.runAsync(() async {
      await tester.tap(find.text('确认修框，拆成 2 个待整理任务'));
      for (var i = 0;
          i < 100 && repo.savedQuestions.length < 2;
          i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      await tester.pumpAndSettle();
    });
    await tester.pumpAndSettle();
    expect(find.text('修框 ·'), findsNothing);
    expect(repo.savedQuestions.length, 2);
    expect(
      repo.savedQuestions.map((q) => q.sourcePage).toSet(),
      {1, 2},
    );
    expect(
      repo.savedQuestions.map((q) => q.sourceKind).toSet(),
      {'pdf'},
    );
    for (final q in repo.savedQuestions) {
      expect(q.slicePath, isNotNull);
      final sliceAbs = AppDatabase.resolveDataPath(q.slicePath!);
      expect(sliceAbs, isNotNull);
      expect(File(sliceAbs!).existsSync(), isTrue);
      expect(File(sliceAbs).lengthSync(), greaterThan(0));
    }
    expect(repo.deletedTaskIds, contains('task-pdf'));
  });
}
