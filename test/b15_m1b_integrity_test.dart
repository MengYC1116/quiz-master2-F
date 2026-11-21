// 十五批 M1-B：完整性状态判定 + 计数守恒测试（M1-DESIGN.md §12，C-14）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/services/pdf_export/export_integrity.dart';
import 'package:quiz_master2/services/pdf_export/export_route.dart';
import 'package:quiz_master2/services/pdf_export/export_snapshot.dart';

import 'b15_m1b_fake_source.dart';

void main() {
  late Directory tempRoot;
  late FakeExportQuestionSource source;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('b15-m1b-int-');
    source = FakeExportQuestionSource();
  });

  tearDown(() async {
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

  void addSliceQuestion(String id, {int w = 200, int h = 100}) {
    final bytes = makePng(w, h);
    source.records[id] = choiceRecord(id: id, sliceWidth: w, sliceHeight: h);
    source.slices[id] = bytes;
  }

  group('C 路线完整性状态表（§12）', () {
    test('COMPLETE：可印且无降级', () {
      expect(
        classifyC(printable: true),
        IntegrityStatus.complete,
      );
    });

    test('PARTIAL：公式为原图', () {
      expect(
        classifyC(printable: true, formulaOriginal: true),
        IntegrityStatus.partial,
      );
    });

    test('PARTIAL：图块缺失', () {
      expect(
        classifyC(printable: true, figureMissing: true),
        IntegrityStatus.partial,
      );
    });

    test('PARTIAL：选项切分不确定但已印', () {
      expect(
        classifyC(printable: true, optionUncertain: true),
        IntegrityStatus.partial,
      );
    });

    test('PARTIAL：内容解析回退为纯文本', () {
      expect(
        classifyC(printable: true, contentParseFallback: true),
        IntegrityStatus.partial,
      );
    });

    test('SKIPPED：无 OCR 结果 / 题干缺失 / 选项无法派生', () {
      expect(
        classifyC(printable: false),
        IntegrityStatus.skipped,
      );
      // 即便有降级标记，不可印仍是 SKIPPED（不印）。
      expect(
        classifyC(printable: false, figureMissing: true),
        IntegrityStatus.skipped,
      );
    });

    test('任一公式渲染失败且裁剪亦失败 → 整题 SKIPPED（§8）', () {
      // 该规则由 M1-C 的公式栅格化定；此处核对分类器口径：
      // 整题不印 → SKIPPED，与正文其余部分完整无关。
      expect(
        classifyC(printable: false, formulaOriginal: false),
        IntegrityStatus.skipped,
      );
    });
  });

  group('A 路线完整性状态表（§12）', () {
    test('COMPLETE：增强后切片正常印出', () {
      expect(
        classifyA(sliceOk: true),
        IntegrityStatus.complete,
      );
    });

    test('PARTIAL：增强失败回退到 300 DPI 限制后图像', () {
      expect(
        classifyA(sliceOk: true, enhanceFailedFallback: true),
        IntegrityStatus.partial,
      );
    });

    test('PARTIAL：低于清晰度阈值（已标记）', () {
      expect(
        classifyA(sliceOk: true, lowDpi: true),
        IntegrityStatus.partial,
      );
    });

    test('BROKEN：源切片缺失/损坏/无法解码', () {
      expect(
        classifyA(sliceOk: false),
        IntegrityStatus.broken,
      );
      expect(
        classifyA(sliceOk: false, lowDpi: true),
        IntegrityStatus.broken,
      );
    });
  });

  group('计数守恒（C-14）：混合分类', () {
    test('50 题混合 COMPLETE、PARTIAL、BROKEN、SKIPPED、排除题，守恒成立',
        () async {
      // 50 道选中：1 道用户排除；其余 49 道进快照——
      // C 路线：40 道正常 + 5 道选项可疑 PARTIAL + 4 道无 OCR 跳过；
      // 再用 A 路线一组验证 BROKEN。
      final ids = List.generate(50, (i) => 'q$i');
      for (var i = 0; i < 50; i++) {
        final id = ids[i];
        if (i < 40) {
          addSliceQuestion(id);
        } else if (i < 45) {
          source.records[id] = choiceRecord(
            id: id,
            options: {'A': '甲', 'C': '丙', 'D': '丁'},
          );
          source.slices[id] = makePng(200, 100);
        } else {
          source.records[id] = choiceRecord(id: id, ocrRaw: null);
          source.slices[id] = makePng(200, 100);
        }
      }
      final snap = await ExportSnapshot.fromSelection(
        ids: ids,
        excluded: const [ExcludedQuestion(id: 'q49', reason: '用户主动排除')],
        route: ExportRoute.c,
        filterText: '全部',
        sortText: '默认排序',
        source: source,
        tempRoot: tempRoot,
      );
      // q49 被排除后快照题数 49；其中 q45–q48 无 OCR → SKIPPED。
      expect(snap.questionCount, 49);
      expect(snap.selectedCount, 50);
      expect(snap.skippedCount, 4);
      expect(snap.printableCount, 45);
      expect(snap.conservationError(), isNull);

      final report = IntegrityReport.fromSnapshot(snap);
      expect(report.completeCount, 40);
      expect(report.partialCount, 5);
      expect(report.brokenCount, 0);
      expect(report.skippedCount, 4);
      expect(report.selectedCount, 50);
      expect(report.snapshotCount, 49);
      expect(report.excludedCount, 1);
      expect(report.conservationError(), isNull);
      report.checkConservationOrThrow();
      expect(report.skippedList.length, 4);
      await snap.dispose();
    });

    test('A 路线混合 COMPLETE、PARTIAL（低 DPI）、BROKEN，守恒成立',
        () async {
      // q0：3000 px 宽 → COMPLETE；q1：200 px 宽 → PARTIAL（低 DPI）；
      // q2：无切片 → BROKEN。
      addSliceQuestion('q0', w: 3000, h: 2000);
      addSliceQuestion('q1', w: 200, h: 100);
      source.records['q2'] = choiceRecord(id: 'q2');
      final snap = await buildA(const ['q0', 'q1', 'q2']);
      final report = IntegrityReport.fromSnapshot(snap);
      expect(report.completeCount, 1);
      expect(report.partialCount, 1);
      expect(report.brokenCount, 1);
      expect(report.skippedCount, 0);
      expect(report.conservationError(), isNull);
      await snap.dispose();
    });

    test('守恒失败能被检出：条目数 ≠ 快照题数', () {
      final report = IntegrityReport(
        route: ExportRoute.c,
        selectedCount: 3,
        snapshotCount: 3,
        excludedCount: 0,
        entries: const [
          IntegrityEntry(
            questionId: 'q1',
            title: '题 1',
            status: IntegrityStatus.complete,
            warnings: [],
          ),
          IntegrityEntry(
            questionId: 'q2',
            title: '题 2',
            status: IntegrityStatus.complete,
            warnings: [],
          ),
        ],
        answersRecorded: null,
        answersTotal: 3,
        explanationsRecorded: null,
        explanationsTotal: 3,
      );
      expect(report.conservationError(), isNotNull);
      expect(report.conservationError(), contains('报告条目 2 ≠ 快照题数 3'));
      expect(() => report.checkConservationOrThrow(), throwsStateError);
    });

    test('守恒失败能被检出：选中 ≠ 快照 + 排除', () {
      final report = IntegrityReport(
        route: ExportRoute.a,
        selectedCount: 5,
        snapshotCount: 3,
        excludedCount: 1,
        entries: const [
          IntegrityEntry(
            questionId: 'q1',
            title: '题 1',
            status: IntegrityStatus.complete,
            warnings: [],
          ),
          IntegrityEntry(
            questionId: 'q2',
            title: '题 2',
            status: IntegrityStatus.complete,
            warnings: [],
          ),
          IntegrityEntry(
            questionId: 'q3',
            title: '题 3',
            status: IntegrityStatus.complete,
            warnings: [],
          ),
        ],
        answersRecorded: null,
        answersTotal: 3,
        explanationsRecorded: null,
        explanationsTotal: 3,
      );
      expect(report.conservationError(), contains('选中 5 ≠ 快照 3 + 排除 1'));
    });

    test('报告为任务内纯数据：答案计数未知时为 null（M1-E 覆盖）', () async {
      addSliceQuestion('q1');
      final snap = await buildA(const ['q1']);
      final report = IntegrityReport.fromSnapshot(snap);
      expect(report.answersRecorded, isNull);
      expect(report.explanationsRecorded, isNull);
      expect(report.answersTotal, 1);
      final withAnswers = IntegrityReport.fromSnapshot(
        snap,
        answersRecorded: 1,
        explanationsRecorded: 0,
      );
      expect(withAnswers.answersRecorded, 1);
      expect(withAnswers.explanationsRecorded, 0);
      await snap.dispose();
    });
  });
}
