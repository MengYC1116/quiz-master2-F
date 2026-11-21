// 十五批 M1-C：公式离屏栅格化测试（M1-DESIGN.md §8/§15）。
//
// 覆盖：300 DPI 映射、超长公式缩小、渲染失败、降级链（一题多公式
// SKIPPED/PARTIAL 裁决）、取消检查点与资源清理、主线程影响统计。
// 注意：本文件不含任何公式源码——测试串只用最简占位形式；异常
// 文本不得含源码（用例 9 单独断言）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:quiz_master2/services/pdf_export/formula_rasterizer.dart';

import 'b15_m1b_fake_source.dart' show makePng;

/// 挂载探针：首帧后把栅格化器挂到 Overlay 上。
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late FormulaRasterizer rasterizer;

  setUp(() {
    tempRoot = Directory(
      '${Platform.environment['HOME']}/workspace/flutter-test-tmp'
      '/b15-m1c-formula',
    )..createSync(recursive: true);
    rasterizer = FormulaRasterizer();
  });

  tearDown(() {
    rasterizer.detach();
    try {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  Directory newTempDir(String name) =>
      Directory('${tempRoot.path}$name')..createSync(recursive: true);

  Future<void> pumpAttached(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: _AttachProbe(rasterizer: rasterizer)),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(rasterizer.isAttached, isTrue);
  }

  /// 驱动一个栅格化 future 直到完成。
  ///
  /// 关键：testWidgets 体跑在 FakeAsync 区，dart:ui 编码与异步 IO 只有在
  /// 真实区内才完成，单纯 pump 永远等不到；而 future 内部的 show() 又需
  /// 要帧来驱动。因此整个 future 必须在 **单个** `tester.runAsync` 内
  /// 启动（真实区），循环里交替 pump（驱动帧）与真实延时（放行引擎异步），
  /// 用 `Future.any` 轮询完成——不用 `.then` 标志（FakeAsync 微任务在
  /// pump 间不一定及时触发）。
  Future<T> drive<T>(WidgetTester tester, Future<T> Function() start) async {
    // 注意：runAsync 会吞掉回调里抛出的异常并以 null 返回（同时经
    // FlutterError 上报），所以在回调内捕获、回调外原样重抛。
    Object? error;
    StackTrace? stack;
    final result = await tester.runAsync<T?>(() async {
      try {
        final future = start();
        var rounds = 0;
        while (rounds < 200) {
          await tester.pump();
          final result = await Future.any<Object?>([
            future,
            Future<void>.delayed(const Duration(milliseconds: 10)),
          ]);
          if (result is T) return result;
          rounds++;
        }
        throw StateError('future 未在 200 轮内完成（疑似挂起）');
      } catch (e, s) {
        error = e;
        stack = s;
        return null;
      }
    });
    if (error != null) Error.throwWithStackTrace(error!, stack!);
    return result as T;
  }

  Future<FormulaRasterResult> render(
    WidgetTester tester,
    FormulaRasterRequest request,
    Directory tempDir,
  ) async {
    return drive(tester, () => rasterizer.rasterize(request, tempDir: tempDir));
  }

  group('300 DPI 映射', () {
    testWidgets('行内公式有效 DPI ≈ 300（±5%），文件可解码', (tester) async {
      await pumpAttached(tester);
      final tempDir = newTempDir('/inline');
      final result = await render(
        tester,
        const FormulaRasterRequest(
          formulaId: 'q0-f0',
          latex: 'x^2+1',
          displayMode: false,
        ),
        tempDir,
      );
      expect(result.effectiveDpi, inInclusiveRange(285, 315));
      expect(result.shrunk, isFalse);
      expect(result.isOriginal, isFalse);
      final file = File('${tempDir.path}/${result.relativePath}');
      expect(file.existsSync(), isTrue);
      // 同步读：testWidgets 的 FakeAsync 区不放行异步 IO。
      final decoded = img.decodeImage(file.readAsBytesSync());
      expect(decoded, isNotNull);
      expect(decoded!.width, result.pixelWidth);
      expect(decoded.height, result.pixelHeight);
    });

    testWidgets('独立公式有效 DPI ≈ 300（±5%）', (tester) async {
      await pumpAttached(tester);
      final tempDir = newTempDir('/display');
      final result = await render(
        tester,
        const FormulaRasterRequest(
          formulaId: 'q0-f0',
          latex: 'x^2+1',
          displayMode: true,
        ),
        tempDir,
      );
      expect(result.effectiveDpi, inInclusiveRange(285, 315));
      expect(result.shrunk, isFalse);
    });

    testWidgets('超长独立公式等比缩小至内容宽并标记 shrunk', (tester) async {
      await pumpAttached(tester);
      final tempDir = newTempDir('/long');
      // 80 项求和，自然宽远超 510.2 pt。
      final longLatex = List.filled(80, 'a').join('+');
      final result = await render(
        tester,
        FormulaRasterRequest(
          formulaId: 'q0-f0',
          latex: longLatex,
          displayMode: true,
        ),
        tempDir,
      );
      expect(result.shrunk, isTrue);
      expect(result.logicalWidthPt, closeTo(510.2, 1.0));
      expect(result.effectiveDpi, inInclusiveRange(285, 315));
    });
  });

  group('渲染失败与降级链', () {
    testWidgets('公式解析失败抛 renderFailed', (tester) async {
      await pumpAttached(tester);
      final tempDir = newTempDir('/fail');
      try {
        await drive(
          tester,
          () => rasterizer.rasterize(
            const FormulaRasterRequest(
              formulaId: 'q0-f0',
              latex: r'\badcommand{',
              displayMode: false,
            ),
            tempDir: tempDir,
          ),
        );
        fail('应抛 renderFailed');
      } on FormulaRasterException catch (e) {
        expect(e.kind, FormulaRasterFailureKind.renderFailed);
      }
      expect(Directory('${tempDir.path}/formulas').existsSync(), isFalse);
    });

    testWidgets('一题多公式：任一原图 → PARTIAL，任一失败 → SKIPPED', (tester) async {
      await pumpAttached(tester);
      final tempDir = newTempDir('/verdict');
      // 情形 A：公式 1 成功，公式 2 渲染失败但裁剪成功 → PARTIAL。
      final verdictA = await drive(
        tester,
        () => rasterizer.rasterizeQuestionFormulas(
          requests: const [
            FormulaRasterRequest(
              formulaId: 'q0-f0',
              latex: 'x^2+1',
              displayMode: false,
            ),
            FormulaRasterRequest(
              formulaId: 'q0-f1',
              latex: r'\badcommand{',
              displayMode: false,
            ),
          ],
          tempDir: tempDir,
          cropOriginal: (index) async => index == 1 ? makePng(200, 50) : null,
        ),
      );
      expect(verdictA.skipQuestion, isFalse);
      expect(verdictA.hasOriginal, isTrue);
      expect(verdictA.outcomes[1].kind, FormulaQuestionOutcomeKind.original);

      // 情形 B：公式 2 渲染失败且裁剪亦失败 → SKIPPED。
      final tempDirB = newTempDir('/verdict-b');
      final verdictB = await drive(
        tester,
        () => rasterizer.rasterizeQuestionFormulas(
          requests: const [
            FormulaRasterRequest(
              formulaId: 'q0-f0',
              latex: 'x^2+1',
              displayMode: false,
            ),
            FormulaRasterRequest(
              formulaId: 'q0-f1',
              latex: r'\badcommand{',
              displayMode: false,
            ),
          ],
          tempDir: tempDirB,
          cropOriginal: (index) async => null,
        ),
      );
      expect(verdictB.skipQuestion, isTrue);
      expect(verdictB.hasOriginal, isFalse);

      // 情形 C：全部成功 → 既非 PARTIAL 也非 SKIPPED。
      final tempDirC = newTempDir('/verdict-c');
      final verdictC = await drive(
        tester,
        () => rasterizer.rasterizeQuestionFormulas(
          requests: const [
            FormulaRasterRequest(
              formulaId: 'q0-f0',
              latex: 'x^2+1',
              displayMode: false,
            ),
            FormulaRasterRequest(
              formulaId: 'q0-f1',
              latex: 'y^2+1',
              displayMode: false,
            ),
          ],
          tempDir: tempDirC,
          cropOriginal: (index) async => null,
        ),
      );
      expect(verdictC.skipQuestion, isFalse);
      expect(verdictC.hasOriginal, isFalse);
    });
  });

  group('300 DPI 上限（裁剪图）', () {
    test('超 300 DPI 的裁剪图被下采样到上限', () {
      final wide = makePng(3000, 100);
      final capped = capPngTo300Dpi(wide, 510.2);
      expect(capped, isNotNull);
      final decoded = img.decodeImage(capped!);
      expect(decoded!.width, 2126);
    });

    test('低于 300 DPI 的裁剪图不放大（原样返回）', () {
      final narrow = makePng(500, 100);
      final capped = capPngTo300Dpi(narrow, 510.2);
      expect(capped, isNotNull);
      expect(capped!.lengthInBytes, narrow.lengthInBytes);
    });

    test('解不出的字节返回 null', () {
      expect(capPngTo300Dpi(Uint8List.fromList([1, 2, 3]), 510.2), isNull);
    });
  });

  group('取消清理', () {
    testWidgets('渲染前取消：0 次渲染，不产生文件', (tester) async {
      await pumpAttached(tester);
      final tempDir = newTempDir('/cancel-before');
      rasterizer.cancel();
      await expectLater(
        rasterizer.rasterize(
          const FormulaRasterRequest(
            formulaId: 'q0-f0',
            latex: 'x^2+1',
            displayMode: false,
          ),
          tempDir: tempDir,
        ),
        throwsA(
          isA<FormulaRasterException>().having(
            (e) => e.kind,
            'kind',
            FormulaRasterFailureKind.cancelled,
          ),
        ),
      );
      expect(rasterizer.stats.renderedCount, 0);
      expect(Directory('${tempDir.path}/formulas').existsSync(), isFalse);
    });

    testWidgets('取消恰在 PNG 编码后：不留文件，资源已释放', (tester) async {
      late final FormulaRasterizer hooked;
      var cancelledOnce = false;
      hooked = FormulaRasterizer(
        hooks: FormulaRasterHooks(
          onCheckpoint: (cp) {
            if (cp == FormulaRasterCheckpoint.afterEncode &&
                !cancelledOnce) {
              cancelledOnce = true;
              hooked.cancel();
            }
          },
        ),
      );
      addTearDown(hooked.detach);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: _AttachProbe(rasterizer: hooked)),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(hooked.isAttached, isTrue);
      final tempDir = newTempDir('/cancel-encode');
      try {
        await drive(
          tester,
          () => hooked.rasterize(
            const FormulaRasterRequest(
              formulaId: 'q0-f0',
              latex: 'x^2+1',
              displayMode: false,
            ),
            tempDir: tempDir,
          ),
        );
        fail('应抛 cancelled');
      } on FormulaRasterException catch (e) {
        expect(e.kind, FormulaRasterFailureKind.cancelled);
      }
      // 编码后取消：临时文件须已清理（.tmp 与目标文件均不存在）。
      final formulasDir = Directory('${tempDir.path}/formulas');
      if (formulasDir.existsSync()) {
        expect(formulasDir.listSync(), isEmpty);
      }
      // 取消后复位仍可继续渲染（资源未泄漏到无法继续）。
      hooked.resetCancellation();
      final ok = await drive(
        tester,
        () => hooked.rasterize(
          const FormulaRasterRequest(
            formulaId: 'q0-f1',
            latex: 'y^2+1',
            displayMode: false,
          ),
          tempDir: tempDir,
        ),
      );
      expect(ok.formulaId, 'q0-f1');
    });

    testWidgets('取消恰在临时文件写入期间：不留半截文件', (tester) async {
      late final FormulaRasterizer hooked;
      hooked = FormulaRasterizer(
        hooks: FormulaRasterHooks(
          onCheckpoint: (cp) {
            if (cp == FormulaRasterCheckpoint.afterWrite) {
              hooked.cancel();
            }
          },
        ),
      );
      addTearDown(hooked.detach);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: _AttachProbe(rasterizer: hooked)),
        ),
      );
      await tester.pump();
      await tester.pump();
      final tempDir = newTempDir('/cancel-write');
      try {
        await drive(
          tester,
          () => hooked.rasterize(
            const FormulaRasterRequest(
              formulaId: 'q0-f0',
              latex: 'x^2+1',
              displayMode: false,
            ),
            tempDir: tempDir,
          ),
        );
        fail('应抛 cancelled');
      } on FormulaRasterException catch (e) {
        expect(e.kind, FormulaRasterFailureKind.cancelled);
      }
      final formulasDir = Directory('${tempDir.path}/formulas');
      if (formulasDir.existsSync()) {
        expect(formulasDir.listSync(), isEmpty);
      }
    });

    testWidgets('队列中途取消：后续公式不再启动，已写文件全部清理', (tester) async {
      late final FormulaRasterizer hooked;
      hooked = FormulaRasterizer(
        hooks: FormulaRasterHooks(
          onCheckpoint: (cp) {
            // 第二个公式渲染前取消：第一个已完成，第二个不得启动。
            if (cp == FormulaRasterCheckpoint.beforeRender &&
                hooked.stats.renderedCount == 1) {
              hooked.cancel();
            }
          },
        ),
      );
      addTearDown(hooked.detach);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: _AttachProbe(rasterizer: hooked)),
        ),
      );
      await tester.pump();
      await tester.pump();
      final tempDir = newTempDir('/cancel-queue');
      try {
        await drive(
          tester,
          () => hooked.rasterizeQuestionFormulas(
            requests: const [
              FormulaRasterRequest(
                formulaId: 'q0-f0',
                latex: 'x^2+1',
                displayMode: false,
              ),
              FormulaRasterRequest(
                formulaId: 'q0-f1',
                latex: 'y^2+1',
                displayMode: false,
              ),
              FormulaRasterRequest(
                formulaId: 'q0-f2',
                latex: 'z^2+1',
                displayMode: false,
              ),
            ],
            tempDir: tempDir,
            cropOriginal: (index) async => null,
          ),
        );
        fail('应抛 cancelled');
      } on FormulaRasterException catch (e) {
        expect(e.kind, FormulaRasterFailureKind.cancelled);
      }
      // 取消时本题已写文件全部清理（不留半截产物）；第二个公式未启动。
      expect(hooked.stats.renderedCount, 1);
      final formulasDir = Directory('${tempDir.path}/formulas');
      if (formulasDir.existsSync()) {
        expect(formulasDir.listSync(), isEmpty);
      }
    });
  });

  group('挂载与统计', () {
    testWidgets('未挂载时渲染抛 notAttached；detach 后同然', (tester) async {
      final tempDir = newTempDir('/not-attached');
      await expectLater(
        rasterizer.rasterize(
          const FormulaRasterRequest(
            formulaId: 'q0-f0',
            latex: 'x^2+1',
            displayMode: false,
          ),
          tempDir: tempDir,
        ),
        throwsA(
          isA<FormulaRasterException>().having(
            (e) => e.kind,
            'kind',
            FormulaRasterFailureKind.notAttached,
          ),
        ),
      );
      await pumpAttached(tester);
      rasterizer.detach();
      expect(rasterizer.isAttached, isFalse);
      await expectLater(
        rasterizer.rasterize(
          const FormulaRasterRequest(
            formulaId: 'q0-f0',
            latex: 'x^2+1',
            displayMode: false,
          ),
          tempDir: tempDir,
        ),
        throwsA(
          isA<FormulaRasterException>().having(
            (e) => e.kind,
            'kind',
            FormulaRasterFailureKind.notAttached,
          ),
        ),
      );
    });

    testWidgets('统计：成功/失败计数与总渲染时间', (tester) async {
      await pumpAttached(tester);
      final tempDir = newTempDir('/stats');
      await render(
        tester,
        const FormulaRasterRequest(
          formulaId: 'q0-f0',
          latex: 'x^2+1',
          displayMode: false,
        ),
        tempDir,
      );
      await render(
        tester,
        const FormulaRasterRequest(
          formulaId: 'q0-f1',
          latex: 'y^2+1',
          displayMode: false,
        ),
        tempDir,
      );
      try {
        await render(
          tester,
          const FormulaRasterRequest(
            formulaId: 'q0-f2',
            latex: r'\badcommand{',
            displayMode: false,
          ),
          tempDir,
        );
        fail('应抛 renderFailed');
      } on FormulaRasterException catch (e) {
        expect(e.kind, FormulaRasterFailureKind.renderFailed);
      }
      final stats = rasterizer.stats;
      expect(stats.renderedCount, 2);
      expect(stats.failedCount, 1);
      expect(stats.totalRenderTime.inMicroseconds, greaterThan(0));
    });

    testWidgets('异常文本不含公式源码（C-11）', (tester) async {
      await pumpAttached(tester);
      const marker = 'ZZZQ';
      final tempDir = newTempDir('/noleak');
      try {
        await render(
          tester,
          FormulaRasterRequest(
            formulaId: 'q0-f0',
            latex: '\\badcommand{$marker}',
            displayMode: false,
          ),
          tempDir,
        );
        fail('应抛 renderFailed');
      } on FormulaRasterException catch (e) {
        expect(e.message.contains(marker), isFalse);
        expect(e.toString().contains(marker), isFalse);
      }
    });
  });
}
