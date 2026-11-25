// 十五批 M1-E：50 道代表性负载生成（M1-DESIGN.md §15 V-内存，S1b 复核）。
//
// 负载复用 S1b 口径（普通/高/极端 × A/C），断言完成且 save 增量在
// S1b 量级；极端组期望行为是盘点 guard 硬拒绝（不生成 PDF、无 OOM，
// 拒绝即通过）——“六组全部完成”的旧口径已作废（S1b 极端组已证实不可接受，
// guard 的职责就是挡住它）。
//
// S1b 实测对照（50 道）：
// - 普通/A save 增量 86–111 MB；普通/C 106–116 MB；
// - 高/A 约 730 MB；高/C 约 1171 MB（边界）；
// - 极端/A 3586 MB、极端/C 1426 MB（不可接受 → guard 硬拒绝）。
//
// 测量方法（与 S1b 一致，Linux /proc/self/status）：
// - 生成期间每 50ms 采样 VmRSS，峰值 − 生成前基线 ≈ save 增量量级
//   （含约 500 MB Dart JIT 基线；AOT 基线低，未实测，判断从严用 JIT 值）。
// - 本文件每个测试跑在独立进程内（flutter test 每文件一个进程），
//   HWM 单调只增，故不用 HWM 差值，改用采样峰值。
// - 断言只设宽松上界（量级对照，不是精确复现）：普通组 < 400 MB，
//   高/A < 1200 MB，高/C < 1800 MB；实测数字写入报告与验证记录。
//
// 合成说明：S1b 同款——普通组为小切片/短题干；高组为 2400 px 宽切片
// （约 1.5 Mpx/题，上限后约 75 Mpx 总量，近 S1b 高组 70.6 Mpx）；
// 极端组为整页 11 MP 手机照片（约 5.9 Mpx/题，上限后约 297 Mpx 总量）。
// 不是 50 道互不相同的真题（与 S1b §7 同款局限）。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/services/pdf_export/export_question_record.dart';
import 'package:quiz_master2/services/pdf_export/pdf_export_service.dart';

import 'b15_m1b_fake_source.dart';

Uint8List? _fontBytesCache;

Future<Uint8List> _fontBytes() async =>
    _fontBytesCache ??= await File(
      'assets/fonts/NotoSansSC-Regular.ttf',
    ).readAsBytes();

/// 读当前进程 VmRSS（kB）。
int _readRssKb() {
  final status = File('/proc/self/status').readAsStringSync();
  for (final line in status.split('\n')) {
    if (line.startsWith('VmRSS:')) {
      return int.parse(line.split(RegExp(r'\s+'))[1]);
    }
  }
  throw StateError('VmRSS 未找到');
}

/// 生成期间采样 RSS 峰值：返回（基线 MB，峰值 MB，峰值增量 MB）。
Future<({double baseMb, double peakMb, double deltaMb})> _sampledGenerate(
  Future<PdfExportResult> Function() generate,
) async {
  final baseKb = _readRssKb();
  var peakKb = baseKb;
  final timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
    try {
      final rss = _readRssKb();
      if (rss > peakKb) peakKb = rss;
    } catch (_) {}
  });
  try {
    await generate();
  } finally {
    timer.cancel();
  }
  final peakAfterKb = _readRssKb();
  if (peakAfterKb > peakKb) peakKb = peakAfterKb;
  return (
    baseMb: baseKb / 1024,
    peakMb: peakKb / 1024,
    deltaMb: (peakKb - baseKb) / 1024,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  var counter = 0;

  setUp(() {
    tempRoot =
        Directory(
          '${Directory.current.path}/../flutter-test-tmp/m1e-load-t${counter++}',
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
  }) => PdfExportService(
    source: source,
    hasApiKey: () async => hasKey,
    fontBytesLoader: _fontBytes,
    tempRoot: tempRoot,
  );

  List<String> ids50() => List<String>.generate(50, (i) => 'q$i');

  /// A 路线 50 道：同一张切片复用 50 次（S1b 同款循环变体口径）。
  void addALoad(
    FakeExportQuestionSource source, {
    required int sliceW,
    required int sliceH,
  }) {
    final bytes = makePng(sliceW, sliceH);
    for (final id in ids50()) {
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

  /// C 路线 50 道：短题干（普通组）或带整幅图块（高/极端组）。
  void addCLoad(
    FakeExportQuestionSource source, {
    String stem = '求下列各题的值',
    int? figureW,
    int? figureH,
  }) {
    Uint8List? sliceBytes;
    if (figureW != null && figureH != null) {
      sliceBytes = makePng(figureW, figureH);
    }
    for (final id in ids50()) {
      final slicePath = 'slices/$id.png';
      source.records[id] = choiceRecord(
        id: id,
        stem: stem,
        sliceWidth: figureW,
        sliceHeight: figureH,
        ocrFigures: sliceBytes == null
            ? '[]'
            : singleFigureJson(
                questionId: id,
                slicePath: slicePath,
                sliceBytes: sliceBytes,
                srcRect: SrcRect(
                  x: 0,
                  y: 0,
                  width: figureW!,
                  height: figureH!,
                ),
                bbox2d: const [0, 0, 1000, 1000],
                spaceWidth: figureW,
                spaceHeight: figureH,
              ),
      );
      if (sliceBytes != null) source.slices[id] = sliceBytes;
    }
  }

  group('50 道负载（S1b 复核）', () {
    test('普通/A：50 道小切片，完成，save 增量在 S1b 量级', () async {
      // 测量类用例读 Linux /proc/self/status；Windows 无 /proc，跳过。
      if (!Platform.isLinux) {
        markTestSkipped('RSS 采样依赖 Linux /proc；产品行为由极端组用例覆盖');
        return;
      }
      final source = FakeExportQuestionSource();
      // 2126 px 宽：内容区宽显示时有效分辨率约 300 DPI → clarity ok →
      // COMPLETE（1300 px 仅约 183 DPI，落在 warning 档，会判 PARTIAL）。
      addALoad(source, sliceW: 2126, sliceH: 140);
      late PdfExportResult result;
      final mem = await _sampledGenerate(
        () async => result = await service(
          source: source,
          hasKey: false,
        ).generate(
          ids: ids50(),
          excluded: const [],
          filterText: '全部',
          sortText: '默认',
        ),
      );
      expect(result.report.completeCount, 50);
      expect(result.report.conservationError(), isNull);
      expect(result.totalPages, greaterThanOrEqualTo(1));
      // S1b 普通/A：86–111 MB；宽松上界 400 MB（JIT 噪声 + 采样误差）。
      expect(mem.deltaMb, lessThan(400));
      // ignore: avoid_print
      print(
        'M1E-LOAD ordinary/A: base=${mem.baseMb.toStringAsFixed(0)}MB '
        'peak=${mem.peakMb.toStringAsFixed(0)}MB '
        'delta=${mem.deltaMb.toStringAsFixed(0)}MB '
        'pdf=${result.pdfBytes.length}B pages=${result.totalPages} '
        '(S1b: 86-111MB)',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('普通/C：50 道短题干，完成，save 增量在 S1b 量级', () async {
      // 测量类用例读 Linux /proc/self/status；Windows 无 /proc，跳过。
      if (!Platform.isLinux) {
        markTestSkipped('RSS 采样依赖 Linux /proc；产品行为由极端组用例覆盖');
        return;
      }
      final source = FakeExportQuestionSource();
      addCLoad(source);
      late PdfExportResult result;
      final mem = await _sampledGenerate(
        () async => result = await service(
          source: source,
          hasKey: true,
        ).generate(
          ids: ids50(),
          excluded: const [],
          filterText: '全部',
          sortText: '默认',
        ),
      );
      expect(result.report.completeCount, 50);
      expect(result.report.conservationError(), isNull);
      expect(mem.deltaMb, lessThan(400));
      // ignore: avoid_print
      print(
        'M1E-LOAD ordinary/C: base=${mem.baseMb.toStringAsFixed(0)}MB '
        'peak=${mem.peakMb.toStringAsFixed(0)}MB '
        'delta=${mem.deltaMb.toStringAsFixed(0)}MB '
        'pdf=${result.pdfBytes.length}B pages=${result.totalPages} '
        '(S1b: 106-116MB)',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('高/A：50 道 2400px 切片，完成，save 增量在 S1b 量级', () async {
      // 测量类用例读 Linux /proc/self/status；Windows 无 /proc，跳过。
      if (!Platform.isLinux) {
        markTestSkipped('RSS 采样依赖 Linux /proc；产品行为由极端组用例覆盖');
        return;
      }
      final source = FakeExportQuestionSource();
      addALoad(source, sliceW: 2400, sliceH: 800);
      late PdfExportResult result;
      final mem = await _sampledGenerate(
        () async => result = await service(
          source: source,
          hasKey: false,
        ).generate(
          ids: ids50(),
          excluded: const [],
          filterText: '全部',
          sortText: '默认',
        ),
      );
      expect(result.report.completeCount, 50);
      expect(result.report.conservationError(), isNull);
      // S1b 高/A：约 730 MB；宽松上界 1200 MB。
      expect(mem.deltaMb, lessThan(1200));
      // ignore: avoid_print
      print(
        'M1E-LOAD high/A: base=${mem.baseMb.toStringAsFixed(0)}MB '
        'peak=${mem.peakMb.toStringAsFixed(0)}MB '
        'delta=${mem.deltaMb.toStringAsFixed(0)}MB '
        'pdf=${result.pdfBytes.length}B pages=${result.totalPages} '
        '(S1b: 730MB)',
      );
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('高/C：50 道 2400px 图块，完成，save 增量在 S1b 量级', () async {
      // 测量类用例读 Linux /proc/self/status；Windows 无 /proc，跳过。
      if (!Platform.isLinux) {
        markTestSkipped('RSS 采样依赖 Linux /proc；产品行为由极端组用例覆盖');
        return;
      }
      final source = FakeExportQuestionSource();
      addCLoad(source, figureW: 2400, figureH: 800);
      late PdfExportResult result;
      final mem = await _sampledGenerate(
        () async => result = await service(
          source: source,
          hasKey: true,
        ).generate(
          ids: ids50(),
          excluded: const [],
          filterText: '全部',
          sortText: '默认',
        ),
      );
      expect(result.report.completeCount, 50);
      expect(result.report.conservationError(), isNull);
      // S1b 高/C：约 1171 MB（边界）；宽松上界 1800 MB。
      expect(mem.deltaMb, lessThan(1800));
      // ignore: avoid_print
      print(
        'M1E-LOAD high/C: base=${mem.baseMb.toStringAsFixed(0)}MB '
        'peak=${mem.peakMb.toStringAsFixed(0)}MB '
        'delta=${mem.deltaMb.toStringAsFixed(0)}MB '
        'pdf=${result.pdfBytes.length}B pages=${result.totalPages} '
        '(S1b: 1171MB)',
      );
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('极端/A：50 道 11MP 切片，guard 硬拒绝，不生成 PDF、无 OOM', () async {
      final source = FakeExportQuestionSource();
      addALoad(source, sliceW: 2892, sliceH: 3800);
      Object? error;
      try {
        await service(source: source, hasKey: false).generate(
          ids: ids50(),
          excluded: const [],
          filterText: '全部',
          sortText: '默认',
        );
      } catch (e) {
        error = e;
      }
      expect(error, isA<ExportGuardRejectException>());
      final reject = error as ExportGuardRejectException;
      expect(reject.guard.totalRasterMpx, greaterThan(150));
      expect(tempRoot.listSync(), isEmpty);
      // ignore: avoid_print
      print(
        'M1E-LOAD extreme/A: guard hard reject at '
        '${reject.guard.totalRasterMpx.toStringAsFixed(1)} Mpx '
        '(S1b: 3586MB save, not acceptable)',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('极端/C：50 道 11MP 图块，guard 硬拒绝，不生成 PDF、无 OOM', () async {
      final source = FakeExportQuestionSource();
      addCLoad(source, figureW: 2892, figureH: 3800);
      Object? error;
      try {
        await service(source: source, hasKey: true).generate(
          ids: ids50(),
          excluded: const [],
          filterText: '全部',
          sortText: '默认',
        );
      } catch (e) {
        error = e;
      }
      expect(error, isA<ExportGuardRejectException>());
      final reject = error as ExportGuardRejectException;
      expect(reject.guard.totalRasterMpx, greaterThan(150));
      expect(tempRoot.listSync(), isEmpty);
      // ignore: avoid_print
      print(
        'M1E-LOAD extreme/C: guard hard reject at '
        '${reject.guard.totalRasterMpx.toStringAsFixed(1)} Mpx '
        '(S1b: 1426MB save, not acceptable)',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
