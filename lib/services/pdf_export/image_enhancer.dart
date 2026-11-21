// 十五批 M1-D：A 路线图片增强（M1-DESIGN.md §4/§11，D-182）。
//
// 执行顺序（§4）：解码 → 下采样到 300 DPI 上限 → 增强 → 编码 PNG
// （先压后增强，削 S1b §4 的下采样 transient：全尺寸解码图 + 缩放后
// 图瞬时并存）。增强只作用于任务临时副本（快照临时目录里的切片副本），
// 库里原切片不动。
//
// 增强算子（M1-D 实测调参，见 spikes/M1D-ENHANCE-RECORD.md）：
// 背景提亮 / 去阴影 / 对比度增强，起点为 S1 的 brightness 1.08 /
// contrast 1.05；参数以 Win11 备份 + XY-cut 验证集的手拍样本实测为准，
// 不在设计里硬编 API 名——[ImageEnhanceParams] 的默认值即实测结论。
//
// 回退口径（D-182）：增强失败 → 回退到增强前的 300 DPI 限制后图像
// （解码 → 下采样到上限后的临时图），不是原始完整分辨率切片；回退图
// 同样受 C-3 约束并计入 guard（[EnhanceResult.rasterPixels] 恒为
// 300 DPI 限制后像素数，与是否增强成功无关）。
//
// 内部状态区分（D-182）：[EnhanceOutcome] 区分“源切片原图”与
// “DPI 限制后未增强图”——本文件永不原样返回源切片字节：
// - [EnhanceOutcome.enhanced]：增强后 PNG；
// - [EnhanceOutcome.fallbackCapped]：解码 → 下采样到上限 → 重编码的
//   PNG（即使无需下采样，也是重编码过的临时图，不是源字节）；
// - [EnhanceOutcome.undecodable]：无法解码，无可嵌字节（A 路线判 BROKEN）。
// 不得只靠 UI 文案（“增强失败，已用原图”）区分两者。
//
// 清晰度门禁（§4/§11，初值）：有效 DPI < 200 警告、< 150 明显警告；
// 默认只警告、不排除；面板勾选排除（M3）时才跳过——是否跳过由
// [ImageEnhancer.shouldSkipForClarity] 判定，门禁不通过 ≠ 增强失败
// （增强成功但门禁不通过 → 跳过，不回退，D-167 边界）。
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'content_guard.dart';

/// A 路线清晰度警告阈值（有效 DPI，§4/§11 初值；修正须有实测依据，
/// 调阈值走决策日志，不静默改）。
const double kClarityWarnDpi = 200;

/// A 路线清晰度明显警告阈值（有效 DPI，§4/§11 初值）。
const double kClaritySevereDpi = 150;

/// 增强结果（内部状态，见文件头 D-182 说明）。
enum EnhanceOutcome {
  /// 增强成功，[EnhanceResult.bytes] 为增强后 PNG。
  enhanced,

  /// 增强失败回退：[EnhanceResult.bytes] 为 DPI 限制后未增强图
  /// （解码 → 下采样到上限 → 重编码，不是源切片原图）。
  fallbackCapped,

  /// 无法解码（源切片损坏），无可嵌字节，A 路线判 BROKEN。
  undecodable;
}

/// 清晰度门禁档位（§4/§11：只警告、不排除，除非面板勾选排除）。
enum ClarityLevel {
  /// 有效 DPI ≥ 200：正常。
  ok,

  /// 150 ≤ 有效 DPI < 200：警告。
  warning,

  /// 有效 DPI < 150：明显警告。
  severe;
}

/// 增强参数（M1-D 实测调参；默认值见 [ImageEnhanceParams.defaults]，
/// 以 spikes/M1D-ENHANCE-RECORD.md 的实测结论为准）。
///
/// 调参结论（2026-11-20，7 个真实样本 × 多轮候选）：
/// - 默认值 brightness 1.25 / contrast 1.10：困难手拍（D-03/D-04，
///   灰底 mean 146–173）近白占比 0% → 31–44%，墨量（<80 占比）仅
///   掉 0.6–0.8pp；干净扫描件墨损 < 0.5pp，细线/根号/小字号完整。
/// - gamma < 1 已否决：干净扫描件墨量掉 1/3–2/3（细线被吃掉），
///   故不提供 gamma 参数。
/// - adjustColor 的 whites 白场已否决：image 4.13.1 里 whites 是
///   ≤1 的增益（只会压暗，不是白点），且 mids 为 null 时指数项
///   变无穷大使全图变黑；亮度增益与白点提升等价（同为线性拉伸），
///   故不提供 whitesLevel 参数。
class ImageEnhanceParams {
  const ImageEnhanceParams({
    this.brightness = 1.25,
    this.contrast = 1.10,
  });

  /// 实测调参后的默认值（brightness 1.25 / contrast 1.10）。
  const ImageEnhanceParams.defaults() : this();

  /// 亮度乘子（> 1 提亮；实测定值 1.25）。
  final double brightness;

  /// 对比度（> 1 增强；实测定值 1.10）。
  final double contrast;
}

/// 一道题的增强结果（纯数据；[bytes] 永不是源切片原样字节，见文件头）。
class EnhanceResult {
  const EnhanceResult({
    required this.outcome,
    required this.sourceWidthPx,
    required this.sourceHeightPx,
    required this.cappedWidthPx,
    required this.cappedHeightPx,
    required this.effectiveDpi,
    required this.wasDownsampled,
    required this.rasterPixels,
    required this.clarity,
    this.bytes,
    this.decodedImage,
  });

  /// 增强结果种类（内部状态，区分“源切片原图”与“DPI 限制后未增强图”）。
  final EnhanceOutcome outcome;

  /// 增强成功时为增强后 PNG；回退时为 DPI 限制后未增强图 PNG；
  /// 无法解码时为 null。
  final Uint8List? bytes;

  /// 与 [bytes] 对应的解码图像（增强后或 DPI 限制后未增强图）：
  /// 供 A 构建器硬切分页时裁剪分段用，避免对同一题重复解码；
  /// 无法解码时为 null。用完即释，不得跨题缓存。
  final img.Image? decodedImage;

  /// 源切片像素尺寸（解码后实测）。
  final int sourceWidthPx;
  final int sourceHeightPx;

  /// 300 DPI 上限应用后的像素尺寸（未超上限时与源尺寸相同）。
  final int cappedWidthPx;
  final int cappedHeightPx;

  /// 有效分辨率（DPI）= 上限后像素数 ÷ PDF 物理显示尺寸（英寸）。
  final double effectiveDpi;

  /// 是否因超 300 DPI 上限而下采样。
  final bool wasDownsampled;

  /// 300 DPI 限制后像素数（guard 计入值，C-13：与是否增强成功无关）。
  final int rasterPixels;

  /// 清晰度门禁档位（按 [effectiveDpi] 判定）。
  final ClarityLevel clarity;

  /// 是否增强成功。
  bool get isEnhanced => outcome == EnhanceOutcome.enhanced;

  /// 是否增强失败回退（题面标“增强失败，已用原图”，报告计“回退原图”）。
  bool get isFallback => outcome == EnhanceOutcome.fallbackCapped;

  /// 是否无法解码（A 路线判 BROKEN）。
  bool get isUndecodable => outcome == EnhanceOutcome.undecodable;
}

/// A 路线图片增强器（纯 Dart，`image` 包已有 `^4.13.1`，不新增依赖）。
class ImageEnhancer {
  ImageEnhancer._();

  /// 测试缝：为 true 时增强步骤主动抛错，走回退分支（D-182）。
  /// 仅测试用（M1-B 的 SliceSnapshot.debugOnTempCopied 同款做法）；
  /// 生产代码永不设置；测试用完须置回 false。
  static bool debugForceEnhanceFailure = false;

  /// 300 DPI 上限应用后的像素尺寸（§4，与 [ContentGuard] 同口径）：
  /// 超了按显示宽度等比下采样，低了不得放大。
  static ({int width, int height}) cappedDimensions({
    required int widthPx,
    required int heightPx,
    double displayWidthPt = 510.2,
  }) {
    if (widthPx <= 0 || heightPx <= 0) return (width: 0, height: 0);
    final capW = ContentGuard.dpiCapWidthPx(displayWidthPt);
    if (widthPx <= capW) return (width: widthPx, height: heightPx);
    final scaledH = (heightPx * capW / widthPx).round();
    return (width: capW, height: scaledH);
  }

  /// 清晰度门禁档位（§4/§11 初值 200/150）。
  static ClarityLevel clarityLevel(double effectiveDpi) {
    if (effectiveDpi < kClaritySevereDpi) return ClarityLevel.severe;
    if (effectiveDpi < kClarityWarnDpi) return ClarityLevel.warning;
    return ClarityLevel.ok;
  }

  /// 门禁排除判定（§11：增强成功但门禁不通过 → 该题跳过，不回退）：
  /// 仅当面板勾选排除（[excludeLowDpi]，M3）且有效 DPI 低于排除阈值
  /// （默认 200 DPI）时返回 true；默认只警告、不排除。
  static bool shouldSkipForClarity({
    required double effectiveDpi,
    required bool excludeLowDpi,
    double excludeBelowDpi = kClarityWarnDpi,
  }) =>
      excludeLowDpi && effectiveDpi < excludeBelowDpi;

  /// A 路线单题增强（§4 执行顺序：解码 → 下采样到上限 → 增强 → 编码）。
  ///
  /// - [sliceBytes]：快照临时副本的切片字节（永不直接读库里原切片，
  ///   也不改写它；增强只作用于解码后的内存图像）；
  /// - [displayWidthPt]：图片在 PDF 中的物理显示宽度（A 路线整题图
  ///   取内容区宽 510.2 pt；窄图按实际显示宽度算）。
  ///
  /// 增强失败 → 回退到增强前的 300 DPI 限制后图像（D-182），不抛错；
  /// 只有“无法解码”与“回退图也编不出来”才返回 [EnhanceOutcome.undecodable]
  /// （调用方按 BROKEN 处理）。本函数不抛错（解码/增强/编码的异常
  /// 一律在内部分类），调用方只看 [EnhanceResult.outcome]。
  static EnhanceResult enhanceSlice({
    required Uint8List sliceBytes,
    double displayWidthPt = 510.2,
    ImageEnhanceParams params = const ImageEnhanceParams.defaults(),
  }) {
    // 1. 解码：失败 = 源切片损坏（BROKEN），不继续。
    late final img.Image decoded;
    try {
      final image = img.decodeImage(sliceBytes);
      if (image == null) {
        return _undecodable();
      }
      decoded = image;
    } catch (_) {
      return _undecodable();
    }
    final sourceW = decoded.width;
    final sourceH = decoded.height;
    if (sourceW <= 0 || sourceH <= 0) {
      return _undecodable();
    }

    // 2. 下采样到 300 DPI 上限（超了压，低了不放大；先压后增强，
    // 削 S1b §4 的下采样 transient：全尺寸解码图只在下采样这一步
    // 与缩放后图短暂并存，之后立即释放引用）。
    final capped = cappedDimensions(
      widthPx: sourceW,
      heightPx: sourceH,
      displayWidthPt: displayWidthPt,
    );
    img.Image cappedImage = decoded;
    var wasDownsampled = false;
    if (capped.width != sourceW || capped.height != sourceH) {
      try {
        cappedImage = img.copyResize(
          decoded,
          width: capped.width,
          height: capped.height,
          interpolation: img.Interpolation.average,
        );
        wasDownsampled = true;
      } catch (_) {
        // 下采样失败（如内存不足）→ 按无法解码处理（BROKEN），
        // 不回退全分辨率图（回退图同样受 C-3 约束）。
        return _undecodable(
          sourceWidthPx: sourceW,
          sourceHeightPx: sourceH,
        );
      }
    }
    // 全尺寸解码图不再需要（已下采样或本就未超上限）：释放引用，
    // 使下采样 transient 尽快回收（Dart GC，下采样后不再持有）。
    // 注意：未下采样时 cappedImage 即 decoded 本身，不得提前释放。
    final effectiveDpi = ContentGuard.effectiveDpi(
      widthPx: capped.width,
      displayWidthPt: displayWidthPt,
    );
    final rasterPixels = capped.width * capped.height;
    final clarity = clarityLevel(effectiveDpi);

    // 3. 增强（在下采样后图的深拷贝上做：adjustColor 原地修改，
    // 失败时 cappedImage 必须保持干净，供回退编码用）。
    try {
      // 测试缝：强制增强失败（验证回退分支用）。
      if (debugForceEnhanceFailure) {
        throw StateError('测试缝：强制增强失败');
      }
      final toEnhance = img.Image.from(cappedImage);
      img.adjustColor(
        toEnhance,
        brightness: params.brightness,
        contrast: params.contrast,
      );
      final encoded = img.encodePng(toEnhance);
      return EnhanceResult(
        outcome: EnhanceOutcome.enhanced,
        bytes: encoded,
        decodedImage: toEnhance,
        sourceWidthPx: sourceW,
        sourceHeightPx: sourceH,
        cappedWidthPx: capped.width,
        cappedHeightPx: capped.height,
        effectiveDpi: effectiveDpi,
        wasDownsampled: wasDownsampled,
        rasterPixels: rasterPixels,
        clarity: clarity,
      );
    } catch (_) {
      // 4. 增强失败 → 回退到增强前的 300 DPI 限制后图像（D-182）：
      // 编码 cappedImage（未被增强动过的干净图）。
      try {
        final fallbackBytes = img.encodePng(cappedImage);
        return EnhanceResult(
          outcome: EnhanceOutcome.fallbackCapped,
          bytes: fallbackBytes,
          decodedImage: cappedImage,
          sourceWidthPx: sourceW,
          sourceHeightPx: sourceH,
          cappedWidthPx: capped.width,
          cappedHeightPx: capped.height,
          effectiveDpi: effectiveDpi,
          wasDownsampled: wasDownsampled,
          rasterPixels: rasterPixels,
          clarity: clarity,
        );
      } catch (_) {
        return _undecodable(
          sourceWidthPx: sourceW,
          sourceHeightPx: sourceH,
        );
      }
    }
  }

  static EnhanceResult _undecodable({
    int sourceWidthPx = 0,
    int sourceHeightPx = 0,
  }) =>
      EnhanceResult(
        outcome: EnhanceOutcome.undecodable,
        sourceWidthPx: sourceWidthPx,
        sourceHeightPx: sourceHeightPx,
        cappedWidthPx: 0,
        cappedHeightPx: 0,
        effectiveDpi: 0,
        wasDownsampled: false,
        rasterPixels: 0,
        clarity: ClarityLevel.severe,
      );
}
