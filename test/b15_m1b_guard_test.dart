// 十五批 M1-B：内容 guard 预估数学测试（M1-DESIGN.md §3，D-176/D-181）。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/services/pdf_export/content_guard.dart';
import 'package:quiz_master2/services/pdf_export/slice_snapshot.dart';

import 'b15_m1b_fake_source.dart';

void main() {
  group('像素 → MB 模型（S1b：10 MB/Mpx）', () {
    test('总栅格 10 Mpx → 预估 save 增量 100 MB', () {
      final result = ContentGuard.evaluate(
        const [
          GuardRasterItem(
            questionId: 'q1',
            title: '题 1',
            rasterMpx: 10,
          ),
        ],
      );
      expect(result.totalRasterMpx, 10);
      expect(result.estimatedSaveMb, 100);
      expect(result.status, ContentGuardStatus.ok);
    });

    test('S1b High/A 量级：70.6 Mpx → 约 706 MB，未超软阈值', () {
      final result = ContentGuard.evaluate(
        const [
          GuardRasterItem(
            questionId: 'q1',
            title: '题 1',
            rasterMpx: 70.6,
          ),
        ],
      );
      expect(result.estimatedSaveMb, closeTo(706, 0.5));
      expect(result.status, ContentGuardStatus.ok);
    });

    test('S1b High/C 量级：117.1 Mpx → 约 1171 MB，软警告', () {
      final result = ContentGuard.evaluate(
        const [
          GuardRasterItem(
            questionId: 'q1',
            title: '题 1',
            rasterMpx: 117.1,
          ),
        ],
      );
      expect(result.estimatedSaveMb, closeTo(1171, 0.5));
      expect(result.status, ContentGuardStatus.softWarning);
    });
  });

  group('80/150 Mpx 边界', () {
    test('恰好 80 Mpx 不警告（> 80 才警告）', () {
      final result = ContentGuard.evaluate(
        const [
          GuardRasterItem(questionId: 'q1', title: '题 1', rasterMpx: 80),
        ],
      );
      expect(result.status, ContentGuardStatus.ok);
    });

    test('80.01 Mpx 软警告', () {
      final result = ContentGuard.evaluate(
        const [
          GuardRasterItem(questionId: 'q1', title: '题 1', rasterMpx: 80.01),
        ],
      );
      expect(result.status, ContentGuardStatus.softWarning);
      expect(result.isSoftWarning, isTrue);
      expect(result.isHardReject, isFalse);
    });

    test('恰好 150 Mpx 不硬拒绝（> 150 才拒绝）', () {
      final result = ContentGuard.evaluate(
        const [
          GuardRasterItem(questionId: 'q1', title: '题 1', rasterMpx: 150),
        ],
      );
      expect(result.status, ContentGuardStatus.softWarning);
    });

    test('150.01 Mpx 硬拒绝', () {
      final result = ContentGuard.evaluate(
        const [
          GuardRasterItem(questionId: 'q1', title: '题 1', rasterMpx: 150.01),
        ],
      );
      expect(result.status, ContentGuardStatus.hardReject);
      expect(result.isHardReject, isTrue);
    });

    test('多题求和触发阈值', () {
      final result = ContentGuard.evaluate(
        List.generate(
          5,
          (i) => GuardRasterItem(
            questionId: 'q$i',
            title: '题 $i',
            rasterMpx: 20,
          ),
        ),
      );
      expect(result.totalRasterMpx, 100);
      expect(result.status, ContentGuardStatus.softWarning);
    });
  });

  group('单图 12 Mpx 警告', () {
    test('单图恰好 12 Mpx 不警告', () {
      final result = ContentGuard.evaluate(
        const [
          GuardRasterItem(questionId: 'q1', title: '题 1', rasterMpx: 12),
        ],
      );
      expect(result.singleImageWarnings, isEmpty);
    });

    test('单图 12.01 Mpx 逐题警告，不阻断', () {
      final result = ContentGuard.evaluate(
        const [
          GuardRasterItem(questionId: 'q1', title: '题 1', rasterMpx: 12.01),
        ],
      );
      expect(result.singleImageWarnings.map((i) => i.questionId), ['q1']);
      expect(result.status, ContentGuardStatus.ok);
    });

    test('超阈值题清单取单图最大的前 5 道（从大到小）', () {
      final items = List.generate(
        8,
        (i) => GuardRasterItem(
          questionId: 'q$i',
          title: '题 $i',
          rasterMpx: (i + 1).toDouble(),
        ),
      );
      final result = ContentGuard.evaluate(items);
      expect(
        result.oversizeQuestions.map((i) => i.questionId),
        ['q7', 'q6', 'q5', 'q4', 'q3'],
      );
    });
  });

  group('300 DPI 上限数学（§4）', () {
    test('内容区宽 510.2 pt → 上限 2126 px', () {
      expect(ContentGuard.dpiCapWidthPx(510.2), 2126);
    });

    test('超上限下采样：4000×3000 → 2126 宽等比缩', () {
      final capped = ContentGuard.cappedRasterPixels(
        widthPx: 4000,
        heightPx: 3000,
      );
      // 2126 × (3000 × 2126 / 4000) = 2126 × 1594.5 ≈ 3389907
      expect(capped, closeTo(2126 * 1594.5, 1));
      expect(capped, lessThan(4000 * 3000));
    });

    test('低于上限不放大：1000×800 原样计入', () {
      expect(
        ContentGuard.cappedRasterPixels(widthPx: 1000, heightPx: 800),
        800000,
      );
    });

    test('恰好上限宽度不缩放', () {
      expect(
        ContentGuard.cappedRasterPixels(widthPx: 2126, heightPx: 1000),
        2126000,
      );
    });

    test('有效 DPI：2126 px 宽图在内容区宽下约 300 DPI', () {
      expect(
        ContentGuard.effectiveDpi(widthPx: 2126, displayWidthPt: 510.2),
        closeTo(300, 0.5),
      );
    });

    test('A 路线栅格量：2126×1500 图约 3.19 Mpx', () {
      expect(
        ContentGuard.rasterMpxForSlice(widthPx: 2126, heightPx: 1500),
        closeTo(3.189, 0.001),
      );
    });
  });

  group('PNG IHDR 读取（不全图解码）', () {
    test('读出宽高', () {
      final dims = readPngDimensions(makePng(200, 100));
      expect(dims, isNotNull);
      expect(dims!.width, 200);
      expect(dims.height, 100);
    });

    test('只含 IHDR 的头也能读尺寸', () {
      final dims = readPngDimensions(makePngHeadOnly(640, 480));
      expect(dims, isNotNull);
      expect(dims!.width, 640);
      expect(dims.height, 480);
    });

    test('非 PNG 返回 null', () {
      expect(readPngDimensions(Uint8List.fromList([1, 2, 3])), isNull);
      expect(readPngDimensions(Uint8List(64)), isNull);
    });

    test('头不足 33 字节返回 null', () {
      expect(readPngDimensions(makePng(10, 10).sublist(0, 20)), isNull);
    });
  });

  group('估算与实际偏差记录（C-13）', () {
    test('偏差 = 实际 − 估算，相对偏差按估算计', () {
      final dev = ContentGuard.compareEstimateVsActual(
        estimatedMpx: 100,
        actualMpx: 110,
      );
      expect(dev.deltaMpx, 10);
      expect(dev.deltaRatio, closeTo(0.1, 0.0001));
      expect(dev.actualSaveMb, isNull);
    });

    test('估算为 0 时相对偏差为 null（不除零）', () {
      final dev = ContentGuard.compareEstimateVsActual(
        estimatedMpx: 0,
        actualMpx: 5,
      );
      expect(dev.deltaMpx, 5);
      expect(dev.deltaRatio, isNull);
    });

    test('实测 save 增量可补填', () {
      final dev = ContentGuard.compareEstimateVsActual(
        estimatedMpx: 70.6,
        actualMpx: 71.0,
        actualSaveMb: 730,
      );
      expect(dev.actualSaveMb, 730);
    });
  });

  group('盘点估算标注', () {
    test('盘点结果明确标注“估算值”', () {
      final result = ContentGuard.evaluate(
        const [
          GuardRasterItem(questionId: 'q1', title: '题 1', rasterMpx: 5),
        ],
        isEstimate: true,
      );
      expect(result.isEstimate, isTrue);
      expect(result.estimateNote, contains('估算值'));
      expect(result.estimateNote, contains('预计占用约 50 MB'));
      expect(result.estimateNote, isNot(contains('保证成功')));
    });

    test('快照后实际值复核不带“估算值”标注', () {
      final result = ContentGuard.evaluate(
        const [
          GuardRasterItem(
            questionId: 'q1',
            title: '题 1',
            rasterMpx: 5,
            isEstimate: false,
          ),
        ],
        isEstimate: false,
      );
      expect(result.isEstimate, isFalse);
      expect(result.estimateNote, isNot(contains('估算值')));
    });
  });
}
