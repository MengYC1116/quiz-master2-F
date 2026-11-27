// 十五批 M1-E：编排服务测试（M1-DESIGN.md §1/§7/§12/§15）。
//
// 覆盖：路由 → 盘点 → 快照 → 生成（Isolate）→ 报告端到端（两路线）；
// 路由切换；零可印；计数守恒（混合分类）；空题干处理；50 道上限；
// 同一快照两次生成分页一致；取消中途清理（栅格化期间 / Isolate 生成期间）；
// guard 实际值复核拒绝（D-181）；含公式题目生成；无栅格化器时的纯裁剪
// 降级链；生产数据源 DriftExportQuestionSource（原始选项 JSON 透传）。
//
// 本文件不含任何公式源码；测试串只用最简占位形式；异常文本与测试名
// 不得含公式源码。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/services/pdf_export/drift_export_source.dart';
import 'package:quiz_master2/services/pdf_export/export_question_record.dart';
import 'package:quiz_master2/services/pdf_export/export_route.dart';
import 'package:quiz_master2/services/pdf_export/export_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/formula_rasterizer.dart';
import 'package:quiz_master2/services/pdf_export/pdf_export_service.dart';

import 'b15_m1b_fake_source.dart';

/// 挂载探针：首帧后把栅格化器挂到 Overlay 上（M1-C 公式测试同款）。
class _AttachProbe extends StatefulWidget {
  const _AttachProbe({required this.rasterizer});

  final FormulaRasterizer rasterizer;

  @override
  State<_AttachProbe> createState() => _AttachProbeState();
}

class _AttachProbeState extends State<_AttachProbe> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.rasterizer.attach(context);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Uint8List? _fontBytesCache;

Future<Uint8List> _fontBytes() async =>
    _fontBytesCache ??= await File(
      'assets/fonts/NotoSansSC-Regular.ttf',
    ).readAsBytes();

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
          '${Directory.current.path}/../flutter-test-tmp/m1e-service-t${counter++}',
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
    FormulaRasterizer? rasterizer,
  }) => PdfExportService(
    source: source,
    hasApiKey: () async => hasKey,
    fontBytesLoader: _fontBytes,
    tempRoot: tempRoot,
    rasterizer: rasterizer,
  );

  /// A 路线记录：切片 + 尺寸（无 OCR 字段）。
  ///
  /// 默认切片 2126×530（内容区宽显示时有效分辨率约 300 DPI，清晰度
  /// 正常 → COMPLETE；800 px 宽切片在全宽显示时仅约 113 DPI，
  /// 会判 PARTIAL，不适合当“正常印出”的测试数据）。
  void addARecords(
    FakeExportQuestionSource source,
    List<String> ids, {
    int sliceW = 2126,
    int sliceH = 530,
    String? answer,
    String? explanation,
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
        answer: answer,
        explanation: explanation,
      );
      source.slices[id] = bytes;
    }
  }

  /// C 路线记录：默认全部可印的选择题。
  void addCRecords(
    FakeExportQuestionSource source,
    List<String> ids, {
    String stem = '求下列各题的值',
  }) {
    for (final id in ids) {
      source.records[id] = choiceRecord(id: id, stem: stem);
      source.slices[id] = makePng(800, 200);
    }
  }

  Future<void> pumpAttached(
    WidgetTester tester,
    FormulaRasterizer rasterizer,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: _AttachProbe(rasterizer: rasterizer))),
    );
    await tester.pump();
    await tester.pump();
    expect(rasterizer.isAttached, isTrue);
  }

  /// 驱动一个 future 直到完成（M1-C 公式测试同款：runAsync 真实区 +
  /// pump 驱动帧；runAsync 会吞异常，回调内捕获、回调外原样重抛）。
  Future<T> drive<T>(WidgetTester tester, Future<T> Function() start) async {
    Object? error;
    StackTrace? stack;
    final result = await tester.runAsync<T?>(() async {
      try {
        final future = start();
        var rounds = 0;
        while (rounds < 300) {
          await tester.pump();
          final value = await Future.any<Object?>([
            future,
            Future<void>.delayed(const Duration(milliseconds: 10)),
          ]);
          if (value is T) return value;
          rounds++;
        }
        throw StateError('future 未在 300 轮内完成（疑似挂起）');
      } catch (e, s) {
        error = e;
        stack = s;
        return null;
      }
    });
    if (error != null) Error.throwWithStackTrace(error!, stack!);
    return result as T;
  }

  group('路由与端到端', () {
    test('A 路由端到端生成：字节有效，答案/解析计数分别判空', () async {
      final source = FakeExportQuestionSource();
      addARecords(source, const ['q0', 'q1', 'q2']);
      source.records['q0'] = ExportQuestionRecord(
        id: 'q0',
        title: '题 q0',
        subjectId: 'math',
        slicePath: 'slices/q0.png',
        sliceWidth: 2126,
        sliceHeight: 530,
        contentVersion: 0,
        answer: '甲',
        explanation: '解析一',
      );
      source.records['q1'] = ExportQuestionRecord(
        id: 'q1',
        title: '题 q1',
        subjectId: 'math',
        slicePath: 'slices/q1.png',
        sliceWidth: 2126,
        sliceHeight: 530,
        contentVersion: 0,
        answer: '乙',
      );
      source.records['q2'] = ExportQuestionRecord(
        id: 'q2',
        title: '题 q2',
        subjectId: 'math',
        slicePath: 'slices/q2.png',
        sliceWidth: 2126,
        sliceHeight: 530,
        contentVersion: 0,
        answer: '   ',
        explanation: '  ',
      );
      final result = await service(source: source, hasKey: false).generate(
        ids: const ['q0', 'q1', 'q2'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
      );
      expect(result.route, ExportRoute.a);
      expect(_startsWithPdfHeader(result.pdfBytes), isTrue);
      expect(result.pdfBytes.length, greaterThan(1000));
      expect(result.totalPages, greaterThanOrEqualTo(1));
      expect(result.report.selectedCount, 3);
      expect(result.report.snapshotCount, 3);
      expect(result.report.completeCount, 3);
      expect(result.report.partialCount, 0);
      expect(result.report.brokenCount, 0);
      expect(result.report.skippedCount, 0);
      expect(result.report.conservationError(), isNull);
      // 答案/解析分别判空：纯空白视为未录入。
      expect(result.report.answersRecorded, 2);
      expect(result.report.answersTotal, 3);
      expect(result.report.explanationsRecorded, 1);
      expect(result.report.explanationsTotal, 3);
      expect(
        result.questionPages.map((q) => q.displayNumber).toList(),
        [1, 2, 3],
      );
      expect(result.actualGuard.isEstimate, isFalse);
      expect(result.guardDeviation.estimatedMpx, greaterThan(0));
      expect(_leftoverExportDirs(tempRoot), isEmpty);
      expect(_leftoverPdfs(tempRoot), isEmpty);
    });

    test('C 路由端到端生成：无公式三题，字节有效', () async {
      final source = FakeExportQuestionSource();
      addCRecords(source, const ['q0', 'q1', 'q2']);
      final result = await service(source: source, hasKey: true).generate(
        ids: const ['q0', 'q1', 'q2'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
      );
      expect(result.route, ExportRoute.c);
      expect(_startsWithPdfHeader(result.pdfBytes), isTrue);
      expect(result.report.completeCount, 3);
      expect(result.report.conservationError(), isNull);
      expect(result.questionPages.length, 3);
      expect(_leftoverExportDirs(tempRoot), isEmpty);
    });

    test('路由切换：有 key 走 C，无 key 走 A（同一批题）', () async {
      final source = FakeExportQuestionSource();
      addCRecords(source, const ['q0', 'q1']);
      final withKey = await service(source: source, hasKey: true).generate(
        ids: const ['q0', 'q1'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
      );
      expect(withKey.route, ExportRoute.c);
      final withoutKey = await service(
        source: source,
        hasKey: false,
      ).generate(
        ids: const ['q0', 'q1'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
      );
      expect(withoutKey.route, ExportRoute.a);
    });

    test('零可印题数：C 路由无 OCR 结果，不建快照、不生成 PDF', () async {
      final source = FakeExportQuestionSource();
      for (final id in ['q0', 'q1']) {
        source.records[id] = choiceRecord(id: id, ocrRaw: null);
        source.slices[id] = makePng(800, 200);
      }
      await expectLater(
        service(source: source, hasKey: true).generate(
          ids: const ['q0', 'q1'],
          excluded: const [],
          filterText: '全部',
          sortText: '默认',
        ),
        throwsA(isA<ExportNoPrintableException>()),
      );
      expect(_leftoverExportDirs(tempRoot), isEmpty);
      expect(_leftoverPdfs(tempRoot), isEmpty);
    });

    test('计数守恒混合分类 C：2 正常 + 空题干 + 无 OCR', () async {
      final source = FakeExportQuestionSource();
      addCRecords(source, const ['q0', 'q1']);
      source.records['q2'] = choiceRecord(id: 'q2', ocrStem: '');
      source.slices['q2'] = makePng(800, 200);
      source.records['q3'] = choiceRecord(id: 'q3', ocrRaw: null);
      source.slices['q3'] = makePng(800, 200);
      final result = await service(source: source, hasKey: true).generate(
        ids: const ['q0', 'q1', 'q2', 'q3'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
      );
      expect(result.report.selectedCount, 4);
      expect(result.report.snapshotCount, 4);
      expect(result.report.completeCount, 2);
      expect(result.report.skippedCount, 2);
      expect(result.report.conservationError(), isNull);
      expect(result.questionPages.length, 2);
      expect(
        result.questionPages.map((q) => q.displayNumber).toList(),
        [1, 2],
      );
      final reasons = result.report.skippedList
          .map((e) => e.skipReason)
          .toSet();
      expect(reasons, contains('题干缺失'));
      expect(reasons, contains('无 OCR 结果'));
    });

    test('计数守恒混合分类 A：3 正常 + 1 BROKEN + 1 排除', () async {
      final source = FakeExportQuestionSource();
      addARecords(source, const ['q0', 'q1', 'q2', 'q3']);
      source.unavailableSlices.add('q3');
      final result = await service(source: source, hasKey: false).generate(
        ids: const ['q0', 'q1', 'q2', 'q3', 'q4'],
        excluded: const [
          ExcludedQuestion(id: 'q4', reason: '用户主动排除'),
        ],
        filterText: '全部',
        sortText: '默认',
      );
      expect(result.report.selectedCount, 5);
      expect(result.report.snapshotCount, 4);
      expect(result.report.excludedCount, 1);
      expect(result.report.completeCount, 3);
      expect(result.report.brokenCount, 1);
      expect(result.report.conservationError(), isNull);
    });

    test('空题干处理：纯空白题干判不可印，不静默印无题干的题', () async {
      final source = FakeExportQuestionSource();
      source.records['q0'] = choiceRecord(id: 'q0', ocrStem: '   ');
      source.slices['q0'] = makePng(800, 200);
      source.records['q1'] = choiceRecord(id: 'q1');
      source.slices['q1'] = makePng(800, 200);
      final result = await service(source: source, hasKey: true).generate(
        ids: const ['q0', 'q1'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
      );
      expect(result.report.completeCount, 1);
      expect(result.report.skippedCount, 1);
      expect(result.report.skippedList.single.skipReason, '题干缺失');
      expect(result.questionPages.length, 1);
    });

    test('50 道上限：51 道拒，50 道成', () async {
      final source = FakeExportQuestionSource();
      final ids51 = List<String>.generate(51, (i) => 'q$i');
      addARecords(source, ids51);
      await expectLater(
        service(source: source, hasKey: false).generate(
          ids: ids51,
          excluded: const [],
          filterText: '全部',
          sortText: '默认',
        ),
        throwsA(isA<ArgumentError>()),
      );
      final ids50 = List<String>.generate(50, (i) => 'q$i');
      final result = await service(source: source, hasKey: false).generate(
        ids: ids50,
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
      );
      expect(result.report.selectedCount, 50);
      expect(result.report.completeCount, 50);
      expect(result.report.conservationError(), isNull);
    });
  });

  group('同一快照两次生成', () {
    test('A 路线：同一快照两次生成，题号序列与总页数一致', () async {
      final source = FakeExportQuestionSource();
      addARecords(source, const ['q0', 'q1', 'q2', 'q3', 'q4']);
      // q4 用高图（800×3000），迫使多页，分页须两次一致。
      source.slices['q4'] = makePng(800, 3000);
      final snapshot = await ExportSnapshot.fromSelection(
        ids: const ['q0', 'q1', 'q2', 'q3', 'q4'],
        excluded: const [],
        route: ExportRoute.a,
        filterText: '全部',
        sortText: '默认',
        source: source,
        tempRoot: tempRoot,
      );
      try {
        final svc = service(source: source, hasKey: false);
        final first = await svc.generateFromSnapshot(snapshot: snapshot);
        final second = await svc.generateFromSnapshot(snapshot: snapshot);
        expect(second.totalPages, first.totalPages);
        expect(
          second.questionPages
              .map(
                (q) =>
                    '${q.questionId}:${q.displayNumber}:${q.pages.join(',')}',
              )
              .toList(),
          first.questionPages
              .map(
                (q) =>
                    '${q.questionId}:${q.displayNumber}:${q.pages.join(',')}',
              )
              .toList(),
        );
        expect(first.totalPages, greaterThan(1));
      } finally {
        await snapshot.dispose();
      }
      expect(_leftoverExportDirs(tempRoot), isEmpty);
    });

    test('C 路线：同一快照两次生成，题号序列与总页数一致', () async {
      final source = FakeExportQuestionSource();
      final longStem = List.filled(40, '这是一道很长的题目题干，用于跨页验证。').join();
      addCRecords(source, const ['q0', 'q1', 'q2'], stem: longStem);
      final snapshot = await ExportSnapshot.fromSelection(
        ids: const ['q0', 'q1', 'q2'],
        excluded: const [],
        route: ExportRoute.c,
        filterText: '全部',
        sortText: '默认',
        source: source,
        tempRoot: tempRoot,
      );
      try {
        final svc = service(source: source, hasKey: true);
        final first = await svc.generateFromSnapshot(snapshot: snapshot);
        final second = await svc.generateFromSnapshot(snapshot: snapshot);
        expect(second.totalPages, first.totalPages);
        expect(
          second.questionPages
              .map(
                (q) =>
                    '${q.questionId}:${q.displayNumber}:${q.pages.join(',')}',
              )
              .toList(),
          first.questionPages
              .map(
                (q) =>
                    '${q.questionId}:${q.displayNumber}:${q.pages.join(',')}',
              )
              .toList(),
        );
        expect(first.totalPages, greaterThan(1));
      } finally {
        await snapshot.dispose();
      }
      expect(_leftoverExportDirs(tempRoot), isEmpty);
    });
  });

  group('取消清理', () {
    test('预取消令牌：抛取消，不建快照、不留残留', () async {
      final source = FakeExportQuestionSource();
      addARecords(source, const ['q0', 'q1']);
      final token = ExportCancellationToken()..cancel();
      await expectLater(
        service(source: source, hasKey: false).generate(
          ids: const ['q0', 'q1'],
          excluded: const [],
          filterText: '全部',
          sortText: '默认',
          token: token,
        ),
        throwsA(isA<ExportCancelledException>()),
      );
      expect(_leftoverExportDirs(tempRoot), isEmpty);
      expect(_leftoverPdfs(tempRoot), isEmpty);
    });

    testWidgets('取消发生在公式栅格化期间：抛取消，临时目录清理', (tester) async {
      final token = ExportCancellationToken();
      final rasterizer = FormulaRasterizer(
        hooks: FormulaRasterHooks(
          onCheckpoint: (_) => token.cancel(),
        ),
      );
      addTearDown(rasterizer.detach);
      await pumpAttached(tester, rasterizer);
      final source = FakeExportQuestionSource();
      // 题干含行内公式（最简占位形式）：栅格化在首个检查点即被取消。
      source.records['q0'] = ExportQuestionRecord(
        id: 'q0',
        title: '题 q0',
        subjectId: 'math',
        slicePath: 'slices/q0.png',
        sliceWidth: 2126,
        sliceHeight: 530,
        ocrRaw: mdRaw('计算 \$x+1\$ 的值\nA. 甲\nB. 乙\nC. 丙\nD. 丁'),
        ocrStem: '计算 \$x+1\$ 的值',
        optionContentsJson: optionsJson({
          'A': '甲',
          'B': '乙',
          'C': '丙',
          'D': '丁',
        }),
        optionContentsParserVersion: 2,
        questionType: 'choice_single',
        contentVersion: 0,
      );
      final svc = service(source: source, hasKey: true, rasterizer: rasterizer);
      // drive() 内调 tester.pump()（guarded API），不能再包 expectLater
      //（M1-C 同款：直接 await + try/catch 断言）。
      Object? error;
      try {
        await drive(
          tester,
          () => svc.generate(
            ids: const ['q0'],
            excluded: const [],
            filterText: '全部',
            sortText: '默认',
            token: token,
          ),
        );
      } catch (e) {
        error = e;
      }
      expect(error, isA<ExportCancelledException>());
      expect(_leftoverExportDirs(tempRoot), isEmpty);
      expect(_leftoverPdfs(tempRoot), isEmpty);
    });

    test('取消发生在 Isolate 生成期间：kill 后抛取消，不留半截 PDF', () async {
      final source = FakeExportQuestionSource();
      final ids = List<String>.generate(50, (i) => 'q$i');
      addARecords(source, ids, sliceW: 2400, sliceH: 800);
      final token = ExportCancellationToken();
      // 300ms 后取消：50 张高图在 Isolate 内增强 + 保存远未完成。
      unawaited(
        Future<void>.delayed(
          const Duration(milliseconds: 300),
          token.cancel,
        ),
      );
      await expectLater(
        service(source: source, hasKey: false).generate(
          ids: ids,
          excluded: const [],
          filterText: '全部',
          sortText: '默认',
          token: token,
        ),
        throwsA(isA<ExportCancelledException>()),
      );
      expect(_leftoverExportDirs(tempRoot), isEmpty);
      expect(_leftoverPdfs(tempRoot), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('guard 实际值复核', () {
    test('D-181：盘点估算很小、快照后实际值超硬阈值 → 中止生成', () async {
      final source = FakeExportQuestionSource();
      // 每题图块实际 2126×7500（约 15.9 Mpx），10 题约 159 Mpx；
      // 但记录里的切片尺寸写 200×100，盘点按 bbox 估算仅约 0.0002 Mpx，
      // 盘点放行，快照后实际值复核必须拦住。
      final sliceBytes = makePng(2126, 7500);
      for (var i = 0; i < 10; i++) {
        final id = 'q$i';
        final slicePath = 'slices/$id.png';
        source.records[id] = choiceRecord(
          id: id,
          sliceWidth: 200,
          sliceHeight: 100,
          ocrFigures: singleFigureJson(
            questionId: id,
            slicePath: slicePath,
            sliceBytes: sliceBytes,
            srcRect: const SrcRect(x: 0, y: 0, width: 2126, height: 7500),
            bbox2d: const [0, 0, 1000, 1000],
            spaceWidth: 200,
            spaceHeight: 100,
          ),
        );
        source.slices[id] = sliceBytes;
      }
      final ids = List<String>.generate(10, (i) => 'q$i');
      Object? error;
      try {
        await service(source: source, hasKey: true).generate(
          ids: ids,
          excluded: const [],
          filterText: '全部',
          sortText: '默认',
        );
      } catch (e) {
        error = e;
      }
      expect(error, isA<ExportGuardRejectException>());
      final reject = error as ExportGuardRejectException;
      expect(reject.guard.isEstimate, isFalse);
      expect(reject.guard.totalRasterMpx, greaterThan(150));
      expect(_leftoverExportDirs(tempRoot), isEmpty);
      expect(_leftoverPdfs(tempRoot), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('公式', () {
    testWidgets('C 路线含公式题目可生成：行内 + 独立公式均印出', (tester) async {
      final rasterizer = FormulaRasterizer();
      addTearDown(rasterizer.detach);
      await pumpAttached(tester, rasterizer);
      final source = FakeExportQuestionSource();
      source.records['q0'] = ExportQuestionRecord(
        id: 'q0',
        title: '题 q0',
        subjectId: 'math',
        slicePath: 'slices/q0.png',
        sliceWidth: 2126,
        sliceHeight: 530,
        ocrRaw: mdRaw(
          '计算 \$x+1\$ 的值\n\$\$y+2\$\$\nA. 甲\nB. 乙\nC. 丙\nD. 丁',
        ),
        ocrStem: '计算 \$x+1\$ 的值\n\$\$y+2\$\$',
        optionContentsJson: optionsJson({
          'A': '甲',
          'B': '乙',
          'C': '丙',
          'D': '丁',
        }),
        optionContentsParserVersion: 2,
        questionType: 'choice_single',
        contentVersion: 0,
      );
      source.slices['q0'] = makePng(800, 200);
      final svc = service(source: source, hasKey: true, rasterizer: rasterizer);
      final result = await drive(
        tester,
        () => svc.generate(
          ids: const ['q0'],
          excluded: const [],
          filterText: '全部',
          sortText: '默认',
        ),
      );
      expect(result.route, ExportRoute.c);
      expect(_startsWithPdfHeader(result.pdfBytes), isTrue);
      expect(result.report.completeCount, 1);
      expect(result.report.conservationError(), isNull);
      expect(result.actualGuard.totalRasterMpx, greaterThan(0));
      expect(result.actualGuard.isEstimate, isFalse);
      expect(_leftoverExportDirs(tempRoot), isEmpty);
    });

    test('无栅格化器时公式走纯裁剪降级：裁剪失败 → 整题跳过', () async {
      final source = FakeExportQuestionSource();
      source.records['q0'] = ExportQuestionRecord(
        id: 'q0',
        title: '题 q0',
        subjectId: 'math',
        slicePath: 'slices/q0.png',
        sliceWidth: 2126,
        sliceHeight: 530,
        ocrRaw: mdRaw('计算 \$x+1\$ 的值\nA. 甲\nB. 乙\nC. 丙\nD. 丁'),
        ocrStem: '计算 \$x+1\$ 的值',
        optionContentsJson: optionsJson({
          'A': '甲',
          'B': '乙',
          'C': '丙',
          'D': '丁',
        }),
        optionContentsParserVersion: 2,
        questionType: 'choice_single',
        contentVersion: 0,
      );
      source.slices['q0'] = makePng(800, 200);
      source.records['q1'] = choiceRecord(id: 'q1');
      source.slices['q1'] = makePng(800, 200);
      final result = await service(source: source, hasKey: true).generate(
        ids: const ['q0', 'q1'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
      );
      expect(result.report.completeCount, 1);
      expect(result.report.skippedCount, 1);
      expect(
        result.report.skippedList.single.skipReason,
        '公式无法呈现',
      );
      expect(result.questionPages.length, 1);
    });
  });

  group('生产数据源', () {
    test('DriftExportQuestionSource：不存在的题返回 null；切片缺失按契约报告',
        () async {
      final source = const DriftExportQuestionSource();
      expect(await source.fetchQuestion('no-such-id'), isNull);
      final record = ExportQuestionRecord(
        id: 'no-such-id',
        title: '',
        subjectId: '',
        contentVersion: 0,
      );
      expect(
        () => source.openSliceBytes(record),
        throwsA(isA<SliceUnavailableException>()),
      );
      expect(await source.readSliceHead(record), isNull);
    });

    test('DriftExportQuestionSource：损坏的选项 JSON 透传原始字符串', () async {
      final db = await AppDatabase.instance.db;
      await db
          .into(db.questions)
          .insert(
            QuestionsCompanion.insert(
              id: 'm1e-raw-json',
              title: '原始 JSON 透传题',
              subjectId: 'math',
              createdAt: 0,
              optionContents: const Value('{bad json'),
              optionContentsParserVersion: const Value(2),
            ),
          );
      addTearDown(() async {
        await (db.delete(
          db.questions,
        )..where((t) => t.id.equals('m1e-raw-json'))).go();
      });
      const source = DriftExportQuestionSource();
      final record = await source.fetchQuestion('m1e-raw-json');
      expect(record, isNotNull);
      // 原始字符串透传（损坏 JSON 不得在模型层被吞成 null）。
      expect(record!.optionContentsJson, '{bad json');
      // 模型解码后为 null（与 NULL 无法区分——这正是必须读原始值的原因）。
      expect(record.optionContents, isNull);
    });
  });
}
