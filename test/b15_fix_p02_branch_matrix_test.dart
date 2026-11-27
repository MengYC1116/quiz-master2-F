// 十五批修复批 P0-2：分支矩阵测试补齐（D-184）。
//
// 只补测试，不改生产代码。覆盖 GPT 终审 P0-2 指出的 5 处缺口：
// - 快照后公式全失败变 0 可印（T1）；
// - BROKEN + PARTIAL + SKIPPED 混合的计数守恒（T2，两路线）；
// - 清晰度阈值排除（T3，勾选与默认对照）；
// - 50 道中含 SKIPPED：占名额、不回填第 51 道（T4）。
//
// 本文件不含任何公式源码；测试串只用最简占位形式。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/services/pdf_export/export_integrity.dart';
import 'package:quiz_master2/services/pdf_export/export_question_record.dart';
import 'package:quiz_master2/services/pdf_export/export_route.dart';
import 'package:quiz_master2/services/pdf_export/export_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/pdf_export_service.dart';

import 'b15_m1b_fake_source.dart';

Future<Uint8List> _fontBytes() async =>
    File('assets/fonts/NotoSansSC-Regular.ttf').readAsBytes();

/// 任务临时目录下残留的导出临时目录（应为空：任务结束一律清理）。
List<String> _leftoverExportDirs(Directory tempRoot) {
  if (!tempRoot.existsSync()) return const [];
  return tempRoot
      .listSync()
      .whereType<Directory>()
      .map((d) => d.path)
      .where((p) => p.contains('quiz-master2-pdf-export-'))
      .toList();
}

/// 任务临时目录下残留的 PDF 文件（M1 不写盘，应为空：不留半截 PDF）。
List<String> _leftoverPdfs(Directory tempRoot) {
  if (!tempRoot.existsSync()) return const [];
  return tempRoot
      .listSync(recursive: true)
      .whereType<File>()
      .map((f) => f.path)
      .where((p) => p.endsWith('.pdf'))
      .toList();
}

bool _startsWithPdfHeader(Uint8List bytes) =>
    bytes.length >= 5 &&
    bytes[0] == 0x25 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x44 &&
    bytes[3] == 0x46 &&
    bytes[4] == 0x2D;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  var counter = 0;

  setUp(() {
    tempRoot =
        Directory(
          '${Directory.current.path}/../flutter-test-tmp/m1e-fix-p02-t${counter++}',
        )..createSync(recursive: true);
  });

  tearDown(() {
    try {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  PdfExportService service({
    required FakeExportQuestionSource source,
    required bool hasKey,
    bool excludeLowDpi = false,
  }) => PdfExportService(
    source: source,
    hasApiKey: () async => hasKey,
    fontBytesLoader: _fontBytes,
    tempRoot: tempRoot,
    excludeLowDpi: excludeLowDpi,
  );

  /// A 路线记录：切片 + 尺寸（无 OCR 字段）。
  ///
  /// 默认切片 2126×530（内容区宽显示时有效分辨率约 300 DPI → COMPLETE；
  /// 800 px 宽切片在全宽显示时仅约 113 DPI → PARTIAL，勾选排除时
  /// 跳过）。
  void addARecords(
    FakeExportQuestionSource source,
    List<String> ids, {
    int sliceW = 2126,
    int sliceH = 530,
  }) {
    final bytes = makePng(sliceW, sliceH);
    for (final id in ids) {
      source.records[id] = ExportQuestionRecord(
        id: id,
        title: '题 $id',
        subjectId: 'math',
        slicePath: 'slices/$id.png',
        sliceWidth: sliceW,
        sliceHeight: sliceH,
        contentVersion: 0,
      );
      source.slices[id] = bytes;
    }
  }

  /// C 路线记录：默认全部可印的选择题。
  void addCRecords(FakeExportQuestionSource source, List<String> ids) {
    for (final id in ids) {
      source.records[id] = choiceRecord(id: id);
      source.slices[id] = makePng(800, 200);
    }
  }

  /// 含行内公式的选择题记录（无栅格化器时原图裁剪无公式框 → 整题跳过）。
  ExportQuestionRecord formulaRecord(String id) => ExportQuestionRecord(
    id: id,
    title: '题 $id',
    subjectId: 'math',
    slicePath: 'slices/$id.png',
    sliceWidth: 2126,
    sliceHeight: 530,
    ocrRaw: mdRaw('计算 \$x+1\$ 的值\nA. 甲\nB. 乙\nC. 丙\nD. 丁'),
    ocrStem: '计算 \$x+1\$ 的值',
    optionContentsJson: optionsJson({'A': '甲', 'B': '乙', 'C': '丙', 'D': '丁'}),
    optionContentsParserVersion: 2,
    questionType: 'choice_single',
    contentVersion: 0,
  );

  group('P0-2 分支矩阵（D-184）', () {
    test('T1 快照后公式全失败变 0：抛零可印异常，不建快照、不生成 PDF', () async {
      final source = FakeExportQuestionSource();
      source.records['q0'] = formulaRecord('q0');
      source.slices['q0'] = makePng(800, 200);
      source.records['q1'] = formulaRecord('q1');
      source.slices['q1'] = makePng(800, 200);
      // 公式级变零抛点（pdf_export_service.dart:782）：栅格化后可印题变 0。
      await expectLater(
        service(source: source, hasKey: true).generate(
          ids: const ['q0', 'q1'],
          excluded: const [],
          filterText: '全部',
          sortText: '默认',
        ),
        throwsA(
          isA<ExportNoPrintableException>().having(
            (e) => e.message,
            'message',
            '本次没有可导出题目（全部题目因公式无法呈现被跳过）。',
          ),
        ),
      );
      expect(_leftoverExportDirs(tempRoot), isEmpty);
      expect(_leftoverPdfs(tempRoot), isEmpty);
    });

    test('T2-A 计数守恒混合分类 A：2 正常 + 1 PARTIAL + 1 BROKEN + 1 排除', () async {
      final source = FakeExportQuestionSource();
      addARecords(source, const ['q0', 'q1']);
      // q2：800 px 宽切片 → 约 113 DPI → PARTIAL（低清晰度警告）。
      addARecords(source, const ['q2'], sliceW: 800, sliceH: 200);
      addARecords(source, const ['q3']);
      source.unavailableSlices.add('q3'); // q3：切片不可用 → BROKEN。
      final result = await service(source: source, hasKey: false).generate(
        ids: const ['q0', 'q1', 'q2', 'q3', 'q4'],
        excluded: const [
          ExcludedQuestion(id: 'q4', reason: '用户主动排除'),
        ],
        filterText: '全部',
        sortText: '默认',
      );
      expect(result.route, ExportRoute.a);
      expect(_startsWithPdfHeader(result.pdfBytes), isTrue);
      expect(result.report.selectedCount, 5);
      expect(result.report.snapshotCount, 4);
      expect(result.report.excludedCount, 1);
      expect(result.report.completeCount, 2);
      expect(result.report.partialCount, 1);
      expect(result.report.brokenCount, 1);
      expect(result.report.skippedCount, 0);
      expect(result.report.conservationError(), isNull);
      // 守恒两式：选中 = 快照 + 排除；快照 = 印出 + BROKEN + 跳过。
      expect(
        result.report.snapshotCount + result.report.excludedCount,
        result.report.selectedCount,
      );
      expect(
        result.report.completeCount +
            result.report.partialCount +
            result.report.brokenCount +
            result.report.skippedCount,
        result.report.snapshotCount,
      );
      // 印出题（可印 + PARTIAL + BROKEN 占位）题号连续 1–4。
      expect(result.questionPages.length, 4);
      expect(
        result.questionPages.map((q) => q.displayNumber).toList(),
        [1, 2, 3, 4],
      );
      final byId = {
        for (final e in result.report.entries) e.questionId: e.status,
      };
      expect(byId['q2'], IntegrityStatus.partial);
      expect(byId['q3'], IntegrityStatus.broken);
      expect(_leftoverExportDirs(tempRoot), isEmpty);
    });

    test('T2-C 计数守恒混合分类 C：2 正常 + 1 PARTIAL + 1 SKIPPED', () async {
      final source = FakeExportQuestionSource();
      addCRecords(source, const ['q0', 'q1']);
      // q2：只有 1 个非空选项槽 → 可印 + 标可疑 optionSplitUncertain → PARTIAL。
      source.records['q2'] = choiceRecord(
        id: 'q2',
        options: {'A': '甲', 'B': '', 'C': '', 'D': ''},
      );
      source.slices['q2'] = makePng(800, 200);
      // q3：空题干 → SKIPPED。
      source.records['q3'] = choiceRecord(id: 'q3', ocrStem: '');
      source.slices['q3'] = makePng(800, 200);
      final result = await service(source: source, hasKey: true).generate(
        ids: const ['q0', 'q1', 'q2', 'q3'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
      );
      expect(result.route, ExportRoute.c);
      expect(_startsWithPdfHeader(result.pdfBytes), isTrue);
      expect(result.report.selectedCount, 4);
      expect(result.report.snapshotCount, 4);
      expect(result.report.excludedCount, 0);
      expect(result.report.completeCount, 2);
      expect(result.report.partialCount, 1);
      expect(result.report.brokenCount, 0);
      expect(result.report.skippedCount, 1);
      expect(result.report.conservationError(), isNull);
      expect(
        result.report.completeCount +
            result.report.partialCount +
            result.report.brokenCount +
            result.report.skippedCount,
        result.report.snapshotCount,
      );
      // 印出题题号连续 1–3（跳过题不占号）。
      expect(result.questionPages.length, 3);
      expect(
        result.questionPages.map((q) => q.displayNumber).toList(),
        [1, 2, 3],
      );
      final byId = {
        for (final e in result.report.entries) e.questionId: e.status,
      };
      expect(byId['q2'], IntegrityStatus.partial);
      expect(byId['q3'], IntegrityStatus.skipped);
      expect(
        result.report.skippedList.single.skipReason,
        '题干缺失',
      );
      expect(_leftoverExportDirs(tempRoot), isEmpty);
    });

    test('T3 清晰度阈值排除：勾选时低清晰度题跳过，不回退、不静默印', () async {
      final source = FakeExportQuestionSource();
      addARecords(source, const ['q0']);
      addARecords(source, const ['q1'], sliceW: 800, sliceH: 200);
      final result = await service(
        source: source,
        hasKey: false,
        excludeLowDpi: true,
      ).generate(
        ids: const ['q0', 'q1'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
      );
      expect(result.report.selectedCount, 2);
      expect(result.report.snapshotCount, 2);
      expect(result.report.completeCount, 1);
      expect(result.report.partialCount, 0);
      expect(result.report.skippedCount, 1);
      expect(result.report.conservationError(), isNull);
      expect(result.questionPages.length, 1);
      expect(result.questionPages.single.displayNumber, 1);
      expect(
        result.report.skippedList.single.skipReason,
        contains('清晰度低于阈值'),
      );
      expect(_leftoverExportDirs(tempRoot), isEmpty);
    });

    test('T3 对照：默认不勾选时低清晰度题只警告、不排除', () async {
      final source = FakeExportQuestionSource();
      addARecords(source, const ['q0']);
      addARecords(source, const ['q1'], sliceW: 800, sliceH: 200);
      final result = await service(source: source, hasKey: false).generate(
        ids: const ['q0', 'q1'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
      );
      expect(result.report.completeCount, 1);
      expect(result.report.partialCount, 1);
      expect(result.report.skippedCount, 0);
      expect(result.report.conservationError(), isNull);
      expect(result.questionPages.length, 2);
      expect(
        result.questionPages.map((q) => q.displayNumber).toList(),
        [1, 2],
      );
    });

    test('T4 50 道中含 SKIPPED：占名额，不回填源里第 51 道', () async {
      final source = FakeExportQuestionSource();
      final ids51 = List<String>.generate(51, (i) => 'q$i');
      addARecords(source, ids51);
      final ids50 = ids51.sublist(0, 50);
      final result = await service(source: source, hasKey: false).generate(
        ids: ids50,
        excluded: const [
          ExcludedQuestion(id: 'q49', reason: '用户主动排除'),
        ],
        filterText: '全部',
        sortText: '默认',
      );
      expect(result.report.selectedCount, 50);
      expect(result.report.snapshotCount, 49);
      expect(result.report.excludedCount, 1);
      expect(result.report.completeCount, 49);
      expect(result.report.skippedCount, 0);
      expect(result.report.conservationError(), isNull);
      // 印出 49 道，题号连续 1–49；源里第 51 道（q50）未被回填。
      expect(result.questionPages.length, 49);
      expect(
        result.questionPages.map((q) => q.displayNumber).toList(),
        List<int>.generate(49, (i) => i + 1),
      );
      expect(
        result.questionPages.map((q) => q.questionId),
        isNot(contains('q50')),
      );
      expect(_leftoverExportDirs(tempRoot), isEmpty);
    });
  });
}
