// 十五批 M1-D：图片增强 + DPI 上限测试（M1-DESIGN.md §4/§11）。
//
// 覆盖：
// - DPI 上限：超了压（宽 2400 → 2126）、低了不放大、窄图按实际显示宽度；
// - 增强：默认参数为调参定值（brightness 1.25 / contrast 1.10），
//   灰底提亮且保墨；
// - 增强失败回退：回退图同样守 300 DPI 上限，内部状态区分“源切片原图”
//   与“DPI 限制后未增强图”（D-182）；
// - 无法解码 → undecodable（调用方判 BROKEN）；
// - 清晰度门禁：200/150 两档、排除判定（默认只警告、不排除）；
// - guard 计入值：rasterPixels 恒为上限后像素数，与是否增强成功无关。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:quiz_master2/services/pdf_export/image_enhancer.dart';

/// 生成一张纯色 PNG（[gray] 0–255）。
Uint8List makeGrayPng(int w, int h, int gray) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(gray, gray, gray));
  return img.encodePng(image);
}

/// 读一像素亮度（R 通道，纯色图各通道相同）。
int pixelGray(Uint8List pngBytes) {
  final image = img.decodeImage(pngBytes)!;
  return image.getPixel(0, 0).r.toInt();
}

void main() {
  group('DPI 上限（C-3：300 DPI 是上限不是目标）', () {
    test('超了压：宽 2400 → 2126（内容区宽 510.2pt），高按比例', () {
      final bytes = makeGrayPng(2400, 750, 200);
      final r = ImageEnhancer.enhanceSlice(sliceBytes: bytes);
      expect(r.outcome, EnhanceOutcome.enhanced);
      expect(r.sourceWidthPx, 2400);
      expect(r.cappedWidthPx, 2126);
      // 750 × 2126 / 2400 = 664.375 → 664。
      expect(r.cappedHeightPx, 664);
      expect(r.wasDownsampled, isTrue);
      expect(r.effectiveDpi, closeTo(300, 0.5));
      expect(r.rasterPixels, 2126 * 664);
    });

    test('低了不放大：宽 1000 不变，有效 DPI 按原尺寸算', () {
      final bytes = makeGrayPng(1000, 500, 200);
      final r = ImageEnhancer.enhanceSlice(sliceBytes: bytes);
      expect(r.cappedWidthPx, 1000);
      expect(r.cappedHeightPx, 500);
      expect(r.wasDownsampled, isFalse);
      // 1000 ÷ (510.2 / 72) ≈ 141.1 DPI。
      expect(r.effectiveDpi, closeTo(141.1, 0.5));
      expect(r.rasterPixels, 1000 * 500);
    });

    test('窄图按实际显示宽度：显示宽 255.1pt 时上限 1063px', () {
      final bytes = makeGrayPng(1200, 600, 200);
      final r = ImageEnhancer.enhanceSlice(
        sliceBytes: bytes,
        displayWidthPt: 255.1,
      );
      expect(r.cappedWidthPx, 1063);
      expect(r.cappedHeightPx, 532); // 600 × 1063 / 1200 = 531.5 → 532
      expect(r.wasDownsampled, isTrue);
      expect(r.effectiveDpi, closeTo(300, 0.5));
    });

    test('恰好 2126 宽不压', () {
      final bytes = makeGrayPng(2126, 100, 200);
      final r = ImageEnhancer.enhanceSlice(sliceBytes: bytes);
      expect(r.wasDownsampled, isFalse);
      expect(r.cappedWidthPx, 2126);
      expect(r.effectiveDpi, closeTo(300, 0.5));
    });

    test('cappedDimensions 与 enhanceSlice 同口径', () {
      expect(
        ImageEnhancer.cappedDimensions(widthPx: 2400, heightPx: 750),
        (width: 2126, height: 664),
      );
      expect(
        ImageEnhancer.cappedDimensions(widthPx: 1000, heightPx: 500),
        (width: 1000, height: 500),
      );
      expect(
        ImageEnhancer.cappedDimensions(widthPx: 0, heightPx: 10),
        (width: 0, height: 0),
      );
    });
  });

  group('增强（调参定值 brightness 1.25 / contrast 1.10）', () {
    test('默认参数即调参结论', () {
      const params = ImageEnhanceParams.defaults();
      expect(params.brightness, 1.25);
      expect(params.contrast, 1.10);
    });

    test('灰底提亮：160 灰提亮到约 207，墨不漂白', () {
      final bytes = makeGrayPng(200, 100, 160);
      final r = ImageEnhancer.enhanceSlice(sliceBytes: bytes);
      expect(r.outcome, EnhanceOutcome.enhanced);
      final gray = pixelGray(r.bytes!);
      // 160 × 1.25 = 200，再经对比度 1.10（绕 0.5 中点）≈ 207。
      expect(gray, greaterThan(190));
      expect(gray, lessThan(220));
    });

    test('纯白仍纯白，纯黑仍纯黑（不 clip 到反色）', () {
      final white = ImageEnhancer.enhanceSlice(
        sliceBytes: makeGrayPng(50, 50, 255),
      );
      expect(pixelGray(white.bytes!), 255);
      final black = ImageEnhancer.enhanceSlice(
        sliceBytes: makeGrayPng(50, 50, 0),
      );
      // 黑经对比度：0.5 × (1 − 1.10) + 0 × 1.10 = −0.05 → clamp 0。
      expect(pixelGray(black.bytes!), 0);
    });

    test('增强后字节不是源字节（重编码），解码尺寸与上限后一致', () {
      final bytes = makeGrayPng(300, 150, 180);
      final r = ImageEnhancer.enhanceSlice(sliceBytes: bytes);
      expect(r.bytes, isNot(bytes));
      final decoded = img.decodeImage(r.bytes!)!;
      expect(decoded.width, r.cappedWidthPx);
      expect(decoded.height, r.cappedHeightPx);
      expect(r.decodedImage, isNotNull);
      expect(r.decodedImage!.width, r.cappedWidthPx);
    });
  });

  group('增强失败回退（D-182）', () {
    setUp(() {
      ImageEnhancer.debugForceEnhanceFailure = true;
    });

    tearDown(() {
      ImageEnhancer.debugForceEnhanceFailure = false;
    });

    test('增强步骤抛错 → 回退到 DPI 限制后未增强图，仍守 300 上限', () {
      final bytes = makeGrayPng(2400, 750, 180);
      final r = ImageEnhancer.enhanceSlice(sliceBytes: bytes);
      expect(r.outcome, EnhanceOutcome.fallbackCapped);
      expect(r.isFallback, isTrue);
      expect(r.isEnhanced, isFalse);
      // 回退图同样守上限：宽 2126，不是源 2400。
      expect(r.cappedWidthPx, 2126);
      expect(r.cappedHeightPx, 664);
      expect(r.rasterPixels, 2126 * 664);
      expect(r.bytes, isNotNull);
      final decoded = img.decodeImage(r.bytes!)!;
      expect(decoded.width, 2126);
      expect(decoded.height, 664);
      // 回退图未增强：像素亮度仍为源 180（±1 舍入）。
      expect(pixelGray(r.bytes!), closeTo(180, 1));
    });

    test('回退图不是源切片原图：字节不同，且为重编码', () {
      final bytes = makeGrayPng(2400, 750, 180);
      final r = ImageEnhancer.enhanceSlice(sliceBytes: bytes);
      expect(r.bytes, isNot(bytes));
      // 内部状态区分两种“原图”：fallbackCapped ≠ 源切片原图。
      expect(r.outcome, isNot(EnhanceOutcome.enhanced));
      expect(r.decodedImage, isNotNull);
    });

    test('无需下采样时回退图尺寸仍等于源尺寸（未增强）', () {
      final bytes = makeGrayPng(800, 400, 180);
      final r = ImageEnhancer.enhanceSlice(sliceBytes: bytes);
      expect(r.outcome, EnhanceOutcome.fallbackCapped);
      expect(r.cappedWidthPx, 800);
      expect(r.wasDownsampled, isFalse);
      // 回退图未增强：像素亮度仍为源 180。
      expect(pixelGray(r.bytes!), closeTo(180, 1));
      // 注意：纯色图重编码是确定性的，字节可能与源相同；“DPI 限制后
      // 未增强图”与“源切片原图”的区分在 outcome 枚举，不在字节比较
      // （见 D-182；字节比较见上一测试的下采样情形）。
      expect(r.outcome, isNot(EnhanceOutcome.enhanced));
    });
  });

  group('无法解码 → undecodable（调用方判 BROKEN）', () {
    test('垃圾字节', () {
      final r = ImageEnhancer.enhanceSlice(
        sliceBytes: Uint8List.fromList([1, 2, 3, 4, 5]),
      );
      expect(r.outcome, EnhanceOutcome.undecodable);
      expect(r.isUndecodable, isTrue);
      expect(r.bytes, isNull);
      expect(r.decodedImage, isNull);
      expect(r.rasterPixels, 0);
      expect(r.effectiveDpi, 0);
    });

    test('空字节', () {
      final r = ImageEnhancer.enhanceSlice(sliceBytes: Uint8List(0));
      expect(r.outcome, EnhanceOutcome.undecodable);
    });

    test('截断的 PNG（有效 IHDR、无完整 IDAT）', () {
      final full = makeGrayPng(200, 100, 180);
      final truncated = Uint8List.fromList(full.sublist(0, 100));
      final r = ImageEnhancer.enhanceSlice(sliceBytes: truncated);
      expect(r.outcome, EnhanceOutcome.undecodable);
    });
  });

  group('清晰度门禁（§4/§11：200 警告、150 明显警告）', () {
    test('档位边界', () {
      expect(ImageEnhancer.clarityLevel(300), ClarityLevel.ok);
      expect(ImageEnhancer.clarityLevel(200), ClarityLevel.ok);
      expect(ImageEnhancer.clarityLevel(199.9), ClarityLevel.warning);
      expect(ImageEnhancer.clarityLevel(150), ClarityLevel.warning);
      expect(ImageEnhancer.clarityLevel(149.9), ClarityLevel.severe);
      expect(ImageEnhancer.clarityLevel(40), ClarityLevel.severe);
    });

    test('门禁档位与增强结果一致', () {
      // 1300px 宽 → 183.4 DPI → warning；286px 宽 → 40.4 DPI → severe。
      final w1300 = ImageEnhancer.enhanceSlice(
        sliceBytes: makeGrayPng(1300, 140, 200),
      );
      expect(w1300.effectiveDpi, closeTo(183.4, 0.5));
      expect(w1300.clarity, ClarityLevel.warning);
      final w286 = ImageEnhancer.enhanceSlice(
        sliceBytes: makeGrayPng(286, 70, 200),
      );
      expect(w286.effectiveDpi, closeTo(40.4, 0.5));
      expect(w286.clarity, ClarityLevel.severe);
    });

    test('默认只警告、不排除：excludeLowDpi 为 false 时永不跳过', () {
      expect(
        ImageEnhancer.shouldSkipForClarity(
          effectiveDpi: 40,
          excludeLowDpi: false,
        ),
        isFalse,
      );
    });

    test('勾选排除时低于阈值跳过，等于阈值不跳过', () {
      expect(
        ImageEnhancer.shouldSkipForClarity(
          effectiveDpi: 199.9,
          excludeLowDpi: true,
        ),
        isTrue,
      );
      expect(
        ImageEnhancer.shouldSkipForClarity(
          effectiveDpi: 200,
          excludeLowDpi: true,
        ),
        isFalse,
      );
      expect(
        ImageEnhancer.shouldSkipForClarity(
          effectiveDpi: 149,
          excludeLowDpi: true,
          excludeBelowDpi: 150,
        ),
        isTrue,
      );
      expect(
        ImageEnhancer.shouldSkipForClarity(
          effectiveDpi: 160,
          excludeLowDpi: true,
          excludeBelowDpi: 150,
        ),
        isFalse,
      );
    });
  });

  group('guard 计入值（C-13）', () {
    test('增强成功与回退的 rasterPixels 均为上限后像素数', () {
      final bytes = makeGrayPng(2400, 750, 180);
      final ok = ImageEnhancer.enhanceSlice(sliceBytes: bytes);
      ImageEnhancer.debugForceEnhanceFailure = true;
      try {
        final fallback = ImageEnhancer.enhanceSlice(sliceBytes: bytes);
        expect(ok.rasterPixels, 2126 * 664);
        expect(fallback.rasterPixels, 2126 * 664);
        expect(ok.rasterPixels, fallback.rasterPixels);
      } finally {
        ImageEnhancer.debugForceEnhanceFailure = false;
      }
    });
  });
}
