// 十五批 M1-D：A 路线内容构建器 + 硬切分页测试
// （M1-DESIGN.md §7/§10/§11/§12）。
//
// 覆盖：
// - 硬切断点：固定缩放比例、片段无遗漏无重叠、续页标占位、题号唯一性；
// - 边界：恰好放得下 / 差 1px 就切、首段不足 40pt 整题移页；
// - BROKEN 占位块；
// - 端到端：增强后印出、门禁警告（PARTIAL）、门禁排除跳过、
//   源缺失 BROKEN、无法解码 BROKEN、快照副本哈希不一致整单中止、
//   全跳过不生成；
// - 完整性状态判定（classifyA 口径）与计数覆盖（C-14）；
// - 页数断言：规划总页数 == 实际生成 PDF 的 /Count（MultiPage
//   页眉/页脚预留 40pt 的实证兜底，D-183）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:quiz_master2/services/pdf_export/a_content_builder.dart';
import 'package:quiz_master2/services/pdf_export/export_integrity.dart';
import 'package:quiz_master2/services/pdf_export/export_route.dart';
import 'package:quiz_master2/services/pdf_export/export_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/image_enhancer.dart';
import 'package:quiz_master2/services/pdf_export/pdf_document_builder.dart';
import 'package:quiz_master2/services/pdf_export/pdf_font.dart';
import 'package:quiz_master2/services/pdf_export/slice_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/snapshot_exceptions.dart';

import 'b15_m1b_fake_source.dart';

/// 从 PDF 字节里读 /Type /Pages 的 /Count（pdf 3.13.1 写出的页树）。
int pdfPageCount(Uint8List bytes) {
  final text = String.fromCharCodes(bytes);
  final match = RegExp(r'/Type\s*/Pages[\s\S]{0,400}?/Count\s+(\d+)')
      .firstMatch(text);
  if (match == null) throw StateError('PDF 里找不到 /Count');
  return int.parse(match.group(1)!);
}

/// 规划断言：各段首尾相接覆盖整图（无遗漏无重叠）。
void expectTilesExactly(AContentPlan plan, String questionId, int heightPx) {
  final segments = [
    for (final page in plan.pages)
      for (final item in page.items)
        if (item is APlannedSegment && item.questionId == questionId) item,
  ];
  expect(segments, isNotEmpty);
  var cursor = 0;
  for (final seg in segments) {
    expect(seg.yStartPx, cursor, reason: '段间遗漏或重叠');
    cursor += seg.heightPx;
  }
  expect(cursor, heightPx, reason: '未覆盖整图');
}

/// 规划断言：全题同一缩放比例（段显示高 ÷ 段像素高恒定）。
void expectFixedScale(AContentPlan plan, String questionId, double scale) {
  for (final page in plan.pages) {
    for (final item in page.items) {
      if (item is APlannedSegment && item.questionId == questionId) {
        expect(
          item.displayHeightPt / item.heightPx,
          closeTo(scale, 1e-9),
          reason: '每页重算缩放比例（比例漂移）',
        );
      }
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempRoot;
  late FakeExportQuestionSource source;
  late pw.Font font;
  late PdfExportDocumentBuilder docBuilder;

  setUpAll(() async {
    font = await PdfExportFont.loadBundledFont();
    docBuilder = PdfExportDocumentBuilder(font: font);
  });

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('b15-m1d-');
    source = FakeExportQuestionSource();
    SliceSnapshot.debugOnTempCopied = null;
  });

  tearDown(() async {
    SliceSnapshot.debugOnTempCopied = null;
    if (tempRoot.existsSync()) {
      await tempRoot.delete(recursive: true);
    }
  });

  Future<ExportSnapshot> buildA(
    List<String> ids, {
    List<ExcludedQuestion> excluded = const [],
  }) {
    return ExportSnapshot.fromSelection(
      ids: ids,
      excluded: excluded,
      route: ExportRoute.a,
      filterText: '全部',
      sortText: '默认排序',
      source: source,
      tempRoot: tempRoot,
    );
  }

  void addSliceQuestion(String id, {required int w, required int h}) {
    source.records[id] = choiceRecord(id: id, sliceWidth: w, sliceHeight: h);
    source.slices[id] = makePng(w, h);
  }

  PdfExportMetadata metadata() => const PdfExportMetadata(title: '错题本导出 · 数学');
  PdfExportHeaderInfo header() =>
      const PdfExportHeaderInfo(subjectName: '数学', exportDateText: '2026-11-20');
  PdfExportInfo info(int count) => PdfExportInfo(
        filterText: '数学 · 全部文件夹',
        questionCount: count,
        exportDateText: '2026-11-20',
        sortText: '按加入时间',
        routeText: '图片增强路线（未配置 OCR key）',
      );

  Future<ABuildResult> buildDoc(
    ExportSnapshot snapshot, {
    bool excludeLowDpi = false,
    double excludeBelowDpi = kClarityWarnDpi,
  }) {
    return AContentBuilder.buildDocument(
      snapshot: snapshot,
      documentBuilder: docBuilder,
      metadata: metadata(),
      headerInfo: header(),
      info: info(snapshot.questionCount),
      excludeLowDpi: excludeLowDpi,
      excludeBelowDpi: excludeBelowDpi,
    );
  }

  // ------------------------------------------------------------------
  // 纯规划：硬切断点（不解码、不读文件）。
  // ------------------------------------------------------------------
  group('硬切分页规划（§10：固定缩放比例 + 无遗漏无重叠）', () {
    test('短题单段单页，无续页标', () {
      final plan = AContentBuilder.planQuestions(
        questions: const [
          APlanQuestion(
            questionId: 'q1',
            questionNumber: 1,
            cappedWidthPx: 1300,
            cappedHeightPx: 140,
          ),
        ],
      );
      expect(plan.totalPages, 1);
      expect(plan.segmentsByQuestion['q1'], 1);
      final seg = plan.pages.single.items.single as APlannedSegment;
      expect(seg.isFirst, isTrue);
      expect(seg.isLast, isTrue);
      expect(seg.segmentCount, 1);
      expect(seg.gapBeforePt, 0);
      expectTilesExactly(plan, 'q1', 140);
      expectFixedScale(
        plan,
        'q1',
        PdfExportGeometry.contentWidthPt / 1300,
      );
    });

    test('长题 1300×4000 切 3 段：边界与续页标占位精确', () {
      const w = 1300;
      const h = 4000;
      final scale = PdfExportGeometry.contentWidthPt / w;
      final firstAvail = AContentBuilder.firstPageAvailableHeightPt;
      final otherAvail = AContentBuilder.otherPageAvailableHeightPt;
      final plan = AContentBuilder.planQuestions(
        questions: const [
          APlanQuestion(
            questionId: 'q1',
            questionNumber: 1,
            cappedWidthPx: w,
            cappedHeightPx: h,
          ),
        ],
      );
      // 第一页可用 firstAvail，扣题号 25.5 → 首段 1570px；
      // 续页可用 otherAvail − 22.5 − 22.5 → 1711px；余 719px。
      // （D-183：页眉/页脚预留 32pt → 40pt，容器 724.85 → 716.85。）
      expect(plan.totalPages, 3);
      expect(plan.segmentsByQuestion['q1'], 3);
      final segments = [
        for (final page in plan.pages)
          for (final item in page.items)
            if (item is APlannedSegment) item,
      ];
      expect(
        segments.map((s) => s.heightPx).toList(),
        [
          ((firstAvail - 25.5) / scale).floor(),
          ((otherAvail - 22.5 - 22.5) / scale).floor(),
          719,
        ],
      );
      expect(
        segments.map((s) => s.yStartPx).toList(),
        [0, 1570, 3281],
      );
      expect(segments[0].isFirst, isTrue);
      expect(segments[2].isLast, isTrue);
      expect(segments[1].gapBeforePt, 0, reason: '续段不加题间分隔');
      expectTilesExactly(plan, 'q1', h);
      expectFixedScale(plan, 'q1', scale);
      // 续页标占用的空间已从该页图片可用高度中扣除：第二段高 1711px
      // 恰为 (otherAvail − 45) / scale 的下取整，不是 otherAvail / scale。
      expect(
        segments[1].heightPx,
        ((otherAvail - 22.5 - 22.5) / scale).floor(),
      );
    });

    test('恰好放得下不切，差 1px 就切', () {
      const w = 1300;
      final scale = PdfExportGeometry.contentWidthPt / w;
      final firstAvail = AContentBuilder.firstPageAvailableHeightPt;
      // 第一页可用 firstAvail，扣题号 25.5 → 图高上限。
      final fitH = ((firstAvail - 25.5) / scale).floor();
      final fitPlan = AContentBuilder.planQuestions(
        questions: [
          APlanQuestion(
            questionId: 'q1',
            questionNumber: 1,
            cappedWidthPx: w,
            cappedHeightPx: fitH,
          ),
        ],
      );
      expect(fitPlan.segmentsByQuestion['q1'], 1);
      final overPlan = AContentBuilder.planQuestions(
        questions: [
          APlanQuestion(
            questionId: 'q1',
            questionNumber: 1,
            cappedWidthPx: w,
            cappedHeightPx: fitH + 1,
          ),
        ],
      );
      expect(overPlan.segmentsByQuestion['q1'], 2);
      expect(overPlan.totalPages, 2);
      expectTilesExactly(overPlan, 'q1', fitH + 1);
    });

    test('首段不足 40pt 时整题移下一页（不在页底留细缝）', () {
      const w = 1300;
      final scale = PdfExportGeometry.contentWidthPt / w;
      final firstAvail = AContentBuilder.firstPageAvailableHeightPt;
      // 第一题占满第一页到只剩 30pt：图高 = firstAvail − 25.5 − 30。
      final firstH = ((firstAvail - 25.5 - 30) / scale).floor();
      final plan = AContentBuilder.planQuestions(
        questions: [
          APlanQuestion(
            questionId: 'q1',
            questionNumber: 1,
            cappedWidthPx: w,
            cappedHeightPx: firstH,
          ),
          APlanQuestion(
            questionId: 'q2',
            questionNumber: 2,
            cappedWidthPx: w,
            cappedHeightPx: 2000,
          ),
        ],
      );
      // q2 首段若留在第一页只剩 30 − 10（分隔）− 25.5（题号）< 40，
      // 应整题移到第二页：第二页首项为 q2 首段。
      final page2First = plan.pages[1].items.first;
      expect(page2First, isA<APlannedSegment>());
      expect((page2First as APlannedSegment).questionId, 'q2');
      expect(page2First.segmentIndex, 0);
      expectTilesExactly(plan, 'q2', 2000);
    });

    test('两短题同页：第二题前有 10pt 题间分隔', () {
      final plan = AContentBuilder.planQuestions(
        questions: const [
          APlanQuestion(
            questionId: 'q1',
            questionNumber: 1,
            cappedWidthPx: 1300,
            cappedHeightPx: 140,
          ),
          APlanQuestion(
            questionId: 'q2',
            questionNumber: 2,
            cappedWidthPx: 1300,
            cappedHeightPx: 140,
          ),
        ],
      );
      expect(plan.totalPages, 1);
      final items = plan.pages.single.items;
      expect(items.length, 2);
      expect((items[1] as APlannedSegment).gapBeforePt, kAQuestionGapPt);
      expect((items[0] as APlannedSegment).gapBeforePt, 0);
    });

    test('题号唯一性：每题题号只出现在首段', () {
      final plan = AContentBuilder.planQuestions(
        questions: const [
          APlanQuestion(
            questionId: 'q1',
            questionNumber: 1,
            cappedWidthPx: 1300,
            cappedHeightPx: 4000,
          ),
          APlanQuestion(
            questionId: 'q2',
            questionNumber: 2,
            cappedWidthPx: 1300,
            cappedHeightPx: 140,
          ),
        ],
      );
      final firstSegments = [
        for (final page in plan.pages)
          for (final item in page.items)
            if (item is APlannedSegment && item.isFirst) item,
      ];
      expect(
        firstSegments.map((s) => s.questionNumber).toList(),
        [1, 2],
      );
      final continuationSegments = [
        for (final page in plan.pages)
          for (final item in page.items)
            if (item is APlannedSegment && !item.isFirst) item,
      ];
      // 续段只有“第 N 题（接上页）”标，不重复题号行：续段数 2（q1 两续段）。
      expect(continuationSegments.length, 2);
      expect(
        continuationSegments.map((s) => s.questionNumber).toList(),
        [1, 1],
      );
    });

    test('BROKEN 占位块：固定 58.5pt，不切分', () {
      final plan = AContentBuilder.planQuestions(
        questions: const [
          APlanQuestion(
            questionId: 'q1',
            questionNumber: 1,
            cappedWidthPx: 1300,
            cappedHeightPx: 140,
          ),
          APlanQuestion(
            questionId: 'q2',
            questionNumber: 2,
            cappedWidthPx: 0,
            cappedHeightPx: 0,
            isBroken: true,
            brokenReason: '源切片缺失',
          ),
        ],
      );
      expect(plan.totalPages, 1);
      expect(plan.segmentsByQuestion['q2'], 0);
      final block = plan.pages.single.items[1] as APlannedBroken;
      expect(block.questionNumber, 2);
      expect(block.reason, '源切片缺失');
      expect(block.gapBeforePt, kAQuestionGapPt);
    });

    test('非法尺寸抛错', () {
      expect(
        () => AContentBuilder.planQuestions(
          questions: const [
            APlanQuestion(
              questionId: 'q1',
              questionNumber: 1,
              cappedWidthPx: 0,
              cappedHeightPx: 100,
            ),
          ],
        ),
        throwsArgumentError,
      );
    });
  });

  // ------------------------------------------------------------------
  // 端到端：快照 → 构建文档 → 保存字节。
  // ------------------------------------------------------------------
  group('端到端构建（快照 → 文档）', () {
    test('两短题一页：增强后印出，页数与规划一致', () async {
      // 2000px 宽 → 282 DPI → COMPLETE（1300px 宽为 183 DPI，会判 PARTIAL）。
      addSliceQuestion('q1', w: 2000, h: 140);
      addSliceQuestion('q2', w: 2000, h: 140);
      final snapshot = await buildA(['q1', 'q2']);
      final result = await buildDoc(snapshot);
      expect(result.plan.totalPages, 1);
      expect(result.questions.map((q) => q.status).toList(), [
        IntegrityStatus.complete,
        IntegrityStatus.complete,
      ]);
      expect(result.enhancedCount, 2);
      expect(result.fallbackCount, 0);
      expect(result.questions[0].questionNumber, 1);
      expect(result.questions[1].questionNumber, 2);
      expect(result.questions[0].enhanceOutcome, EnhanceOutcome.enhanced);
      final bytes = await docBuilder.savePdf(result.document);
      expect(bytes.sublist(0, 5), [0x25, 0x50, 0x44, 0x46, 0x2D]);
      // 页数实证：实际 PDF /Count == 规划总页数（页眉/页脚预留兜底）。
      expect(pdfPageCount(bytes), result.plan.totalPages);
    });

    test('长题 1300×4000：3 页，段边界与规划一致，PDF 页数一致', () async {
      addSliceQuestion('q1', w: 1300, h: 4000);
      final snapshot = await buildA(['q1']);
      final result = await buildDoc(snapshot);
      expect(result.plan.totalPages, 3);
      expect(result.questions.single.segmentCount, 3);
      // 1300px 宽 → 183 DPI → 低清晰度警告（PARTIAL），不影响分页。
      expect(result.questions.single.status, IntegrityStatus.partial);
      expect(result.questions.single.clarity, ClarityLevel.warning);
      final bytes = await docBuilder.savePdf(result.document);
      expect(pdfPageCount(bytes), 3);
    });

    test('低清晰度题：默认只警告（PARTIAL），不排除', () async {
      // 500px 宽 → 70.6 DPI → severe。
      addSliceQuestion('q1', w: 500, h: 100);
      addSliceQuestion('q2', w: 2000, h: 100);
      final snapshot = await buildA(['q1', 'q2']);
      final result = await buildDoc(snapshot);
      final low = result.questions[0];
      expect(low.status, IntegrityStatus.partial);
      expect(low.clarity, ClarityLevel.severe);
      expect(low.effectiveDpi, closeTo(70.6, 0.5));
      expect(low.warnings.join(), contains('明显偏低'));
      expect(result.lowDpiCount, 1);
      expect(result.questions[1].status, IntegrityStatus.complete);
      expect(result.plan.totalPages, 1);
    });

    test('门禁排除勾选：低 DPI 题跳过（不回退），不占页', () async {
      addSliceQuestion('q1', w: 500, h: 100); // 70.6 DPI，低于 200。
      addSliceQuestion('q2', w: 2000, h: 100); // 282 DPI。
      final snapshot = await buildA(['q1', 'q2']);
      final result = await buildDoc(snapshot, excludeLowDpi: true);
      expect(result.questions[0].status, IntegrityStatus.skipped);
      expect(result.questions[0].questionNumber, 0);
      expect(result.questions[0].segmentCount, 0);
      expect(result.questions[0].skipReason, contains('清晰度低于阈值'));
      expect(result.questions[1].status, IntegrityStatus.complete);
      expect(result.questions[1].questionNumber, 1);
      expect(result.skippedCount, 1);
      // 计数覆盖（C-14）：快照 2 题 = 印出 1 + 跳过 1。
      expect(result.questions.length, snapshot.questionCount);
    });

    test('门禁不通过 ≠ 增强失败：跳过题仍有增强结果，但不回退印出', () async {
      addSliceQuestion('q1', w: 500, h: 100);
      addSliceQuestion('q2', w: 2000, h: 100);
      final snapshot = await buildA(['q1', 'q2']);
      final result = await buildDoc(snapshot, excludeLowDpi: true);
      final q = result.questions[0];
      expect(q.status, IntegrityStatus.skipped);
      // 增强本身成功（不是回退），只是门禁排除不印。
      expect(q.enhanceOutcome, EnhanceOutcome.enhanced);
      expect(result.questions[1].status, IntegrityStatus.complete);
    });

    test('源切片缺失 → BROKEN 占位，继续其余题', () async {
      addSliceQuestion('q1', w: 2000, h: 140);
      source.records['q2'] = choiceRecord(id: 'q2', sliceWidth: 100, sliceHeight: 100);
      source.unavailableSlices.add('q2');
      final snapshot = await buildA(['q1', 'q2']);
      expect(snapshot.entries[1].outcome, SnapshotOutcome.broken);
      final result = await buildDoc(snapshot);
      expect(result.questions[1].status, IntegrityStatus.broken);
      expect(result.questions[1].questionNumber, 2);
      expect(result.brokenCount, 1);
      expect(result.questions[0].status, IntegrityStatus.complete);
      final bytes = await docBuilder.savePdf(result.document);
      expect(pdfPageCount(bytes), 1);
    });

    test('无法解码（有效 IHDR、无完整 IDAT）→ 生成时 BROKEN', () async {
      addSliceQuestion('q1', w: 2000, h: 140);
      // 只有 IHDR 的 PNG 头：快照放行（头合法），生成时解码失败。
      source.records['q2'] = choiceRecord(id: 'q2', sliceWidth: 200, sliceHeight: 100);
      source.slices['q2'] = makePngHeadOnly(200, 100);
      final snapshot = await buildA(['q1', 'q2']);
      expect(snapshot.entries[1].outcome, SnapshotOutcome.ready);
      final result = await buildDoc(snapshot);
      expect(result.questions[1].status, IntegrityStatus.broken);
      expect(result.questions[1].warnings.join(), contains('无法解码'));
      expect(result.brokenCount, 1);
      expect(result.questions[0].status, IntegrityStatus.complete);
    });

    test('快照副本哈希不一致 → 整单中止（D-179）', () async {
      addSliceQuestion('q1', w: 1300, h: 140);
      final snapshot = await buildA(['q1']);
      // 快照建成后改写临时副本（写与源不同的垃圾字节）：生成时验哈希失败。
      final copy = snapshot.entries.single.sliceCopy!;
      final tempFile = File(
        '${snapshot.tempDir.path}${Platform.pathSeparator}'
        '${copy.tempRelativePath}',
      );
      await tempFile.writeAsBytes(Uint8List.fromList([9, 9, 9, 9]));
      await expectLater(
        () => buildDoc(snapshot),
        throwsA(isA<SnapshotIntegrityException>()),
      );
    });

    test('全跳过 → 不生成（StateError）', () async {
      addSliceQuestion('q1', w: 500, h: 100); // 70.6 DPI。
      final snapshot = await buildA(['q1']);
      await expectLater(
        () => buildDoc(snapshot, excludeLowDpi: true),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('本次没有可导出题目'),
          ),
        ),
      );
    });

    test('C 路线快照拒绝', () async {
      addSliceQuestion('q1', w: 1300, h: 140);
      final snapshot = await ExportSnapshot.fromSelection(
        ids: const ['q1'],
        excluded: const [],
        route: ExportRoute.c,
        filterText: '全部',
        sortText: '默认排序',
        source: source,
        tempRoot: tempRoot,
      );
      await expectLater(() => buildDoc(snapshot), throwsArgumentError);
    });

    test('完整性报告条目覆盖全部快照题（C-14）', () async {
      addSliceQuestion('q1', w: 2000, h: 140);
      addSliceQuestion('q2', w: 500, h: 100); // 低 DPI → PARTIAL。
      source.records['q3'] = choiceRecord(id: 'q3', sliceWidth: 100, sliceHeight: 100);
      source.unavailableSlices.add('q3'); // BROKEN。
      final snapshot = await buildA(['q1', 'q2', 'q3']);
      final result = await buildDoc(snapshot);
      final entries = result.toIntegrityEntries();
      expect(entries.length, 3);
      expect(
        entries.map((e) => e.status).toList(),
        [
          IntegrityStatus.complete,
          IntegrityStatus.partial,
          IntegrityStatus.broken,
        ],
      );
      final report = IntegrityReport.fromSnapshot(snapshot);
      // 报告层计数守恒：快照 3 = 印出 2 + BROKEN 1（M1-B 口径复核）。
      expect(report.conservationError(), isNull);
      // 本包计数守恒：3 = 正常 1 + 降级 1 + BROKEN 1 + 跳过 0。
      final sum = result.questions
              .where((q) => q.status == IntegrityStatus.complete)
              .length +
          result.questions
              .where((q) => q.status == IntegrityStatus.partial)
              .length +
          result.brokenCount +
          result.skippedCount;
      expect(sum, snapshot.questionCount);
    });

    test('增强后 PNG 写任务临时目录 enhanced/（快照 dispose 清理）', () async {
      addSliceQuestion('q1', w: 1300, h: 140);
      final snapshot = await buildA(['q1']);
      await buildDoc(snapshot);
      final enhancedDir = Directory(
        '${snapshot.tempDir.path}${Platform.pathSeparator}enhanced',
      );
      expect(enhancedDir.existsSync(), isTrue);
      expect(enhancedDir.listSync().length, 1);
      await snapshot.dispose();
      expect(snapshot.tempDir.existsSync(), isFalse);
    });
  });
}
