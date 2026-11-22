// 十五批 M1-C：公式离屏栅格化（M1-DESIGN.md §8，D-174）。
//
// 架构：主线程离屏渲染 → 位图进 Isolate。`Math.tex` 只能在主 Isolate 的
// Widget 树中布局绘制；`RepaintBoundary.toImage()` 取位图；PNG 字节写
// 任务临时目录，快照只存文件引用 + 像素尺寸；生成 Isolate 按题读取、
// 用完释放。
//
// 挂载方式（探针结论，见 M1-DESIGN.md 附录 C.3）：屏幕外定位挂载
// （`Positioned(left: -10000)` 的 OverlayEntry 内 RepaintBoundary）。
// `Offstage(offstage: true)` 与 `Opacity(0)` 均不绘制，`toImage()`
// 抛 `!debugNeedsPaint` 断言，不得使用。
//
// 300 DPI 映射口径（§8）：Widget 按 PDF 中的显示尺寸（pt）布局后
// `toImage(pixelRatio: 4.17)`；行内公式按正文字号高度渲染，独立公式
// 按内容宽（≤510.2 pt）渲染。探针实测有效 DPI 301.3（300 ±5% 内）。
// 超长公式：独立公式超内容宽时等比缩小至内容宽并标记可疑“公式已缩小”
// （FittedBox scaleDown，宽高同比）；行内公式不拆分、随行整体移下一行。
//
// 时序与内存：逐题、逐个公式渲染；一次只持有一个公式的 `ui.Image` +
// `ByteData`，编码完立即 `dispose()`，不得缓存全部公式位图。
// 取消检查点：每次渲染前、布局绘制完成、`toImage()` 前、`toImage()`
// 返回后、PNG 编码完成、字节传给 Isolate 前、临时文件写入期间。
// `toImage()` 飞行中不可中断：允许当前渲染完成，丢弃结果、释放资源、
// 不再启动后续渲染。
// 异常分支全覆盖：`toImage()` 成功但 PNG 编码失败、写文件失败、取消恰
// 在编码后，均释放资源、不留半截产物（临时文件先写 `.tmp` 再重命名，
// 失败/取消时删临时文件）。
//
// 降级链（§8）：渲染失败 → 公式原图裁剪（`cropFormulaImageBytes`，调用
// 方在 SliceWriteGuard 锁内执行后以回调传入，见 [rasterizeQuestionFormulas]
// 的 `cropOriginal` 参数）并标记该题“公式为原图”；裁剪也失败或无 bbox
// → 该题跳过并列入警告清单（不得印不完整公式，不得回退整题原图）。
// 一题多公式：任一公式渲染失败且裁剪亦失败 → 整题 SKIPPED；任一公式为
// 原图 → 该题 PARTIAL。裁剪结果执行同一 300 DPI 上限（超了下采样，
// 低于 300 DPI 不放大，见 [capPngTo300Dpi]）。
//
// LaTeX 源码保密（C-11）：异常、日志、统计里一律不含 LaTeX 源码；
// 报错只含题内公式序号与失败种类。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:image/image.dart' as img;

import 'content_guard.dart';
import 'pdf_document_builder.dart';

/// 300 DPI 映射倍率（300/72 = 4.17，§8）。
const double kFormulaRasterPixelRatio = 300 / 72;

/// 有效 DPI 允差（§8 探针：300 ±5%，即 285–315）。
const double kFormulaRasterDpiTolerance = 0.05;

/// 取消检查点（§8：覆盖公式离屏渲染全程）。
enum FormulaRasterCheckpoint {
  /// 每次渲染前。
  beforeRender,

  /// 布局绘制完成。
  afterLayout,

  /// 调用 `toImage()` 前。
  beforeToImage,

  /// `toImage()` 返回后。
  afterToImage,

  /// PNG 编码完成。
  afterEncode,

  /// 字节传给 Isolate 前（写临时文件前）。
  beforeWrite,

  /// 临时文件写入完成。
  afterWrite,
}

/// 栅格化测试钩子（生产传 null；测试用它在检查点触发取消，模拟
/// “取消恰在编码后”等时序）。
class FormulaRasterHooks {
  const FormulaRasterHooks({this.onCheckpoint});

  /// 在每个检查点调用（同步）；测试可在回调内调 `cancel()`。
  final void Function(FormulaRasterCheckpoint checkpoint)? onCheckpoint;
}

/// 栅格化失败种类（不含 LaTeX 源码）。
enum FormulaRasterFailureKind {
  /// 未挂载（未调 `attach` 或已 `detach`）。
  notAttached,

  /// 渲染失败（公式解析失败、布局异常、`toImage()` 失败、空位图）。
  renderFailed,

  /// PNG 编码失败（`toImage()` 成功但 `toByteData()` 失败/为空）。
  encodeFailed,

  /// 临时文件写入失败。
  writeFailed,

  /// 已取消。
  cancelled,
}

/// 栅格化异常（message 只含题内公式序号与失败种类，不含 LaTeX 源码）。
class FormulaRasterException implements Exception {
  FormulaRasterException(this.kind, this.message);

  /// 失败种类。
  final FormulaRasterFailureKind kind;

  /// 原因（不含 LaTeX 源码）。
  final String message;

  @override
  String toString() => 'FormulaRasterException($kind): $message';
}

/// 一次公式栅格化请求。
class FormulaRasterRequest {
  const FormulaRasterRequest({
    required this.formulaId,
    required this.latex,
    required this.displayMode,
    this.fontSizePt = PdfExportTypography.bodyPt,
  });

  /// 公式标识（题内唯一，如 `q0-f0`；只用于文件命名与报错）。
  final String formulaId;

  /// LaTeX 源码（内部数据，绝不外露）。
  final String latex;

  /// 是否独立公式（true = 独立成行，false = 行内）。
  final bool displayMode;

  /// 渲染字号（pt，默认 11 pt 正文）。
  final double fontSizePt;
}

/// 一次公式栅格化结果（文件引用 + 尺寸；位图本身在临时文件里）。
class FormulaRasterResult {
  const FormulaRasterResult({
    required this.formulaId,
    required this.relativePath,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.logicalWidthPt,
    required this.logicalHeightPt,
    required this.effectiveDpi,
    required this.shrunk,
    this.isOriginal = false,
    this.baselineOffsetPt,
  });

  /// 公式标识。
  final String formulaId;

  /// 临时 PNG 相对路径（任务临时目录内，如 `formulas/q0-f0.png`）。
  final String relativePath;

  /// 像素宽 / 高。
  final int pixelWidth;
  final int pixelHeight;

  /// 逻辑宽 / 高（pt，PDF 中的显示尺寸）。
  final double logicalWidthPt;
  final double logicalHeightPt;

  /// 有效 DPI（像素 ÷ 显示英寸，应 ≈ 300）。
  final double effectiveDpi;

  /// 是否被等比缩小（独立公式超内容宽）。
  final bool shrunk;

  /// 是否为原图降级（渲染失败但裁剪成功）。
  final bool isOriginal;

  /// 数学基线偏移（pt，十八批 P1 D-216：图片顶到数学 alphabetic
  /// 基线的距离，离屏渲染时从 Math.tex 的 render 对象量得）。
  ///
  /// PDF 与 Word 的行内公式按此对齐文字基线（见 c_content_builder 与
  /// word_formula_baseline）。为 null = 未知基线：原图降级（裁剪自
  /// 题目照片，无栅格化结果）与量取失败时均为 null，调用方按旧行为
  /// 处理（PDF 用居中启发式、Word 不下移），不得用猜的数。
  final double? baselineOffsetPt;

  /// 像素数（guard 计入用，C-13）。
  int get pixelCount => pixelWidth * pixelHeight;
}

/// 主线程影响记录（§8：公式数量、总渲染时间，记入验证记录）。
class FormulaRasterStats {
  const FormulaRasterStats({
    required this.renderedCount,
    required this.failedCount,
    required this.cancelledCount,
    required this.totalRenderTime,
  });

  /// 成功渲染数。
  final int renderedCount;

  /// 渲染失败数（不含取消）。
  final int failedCount;

  /// 取消数。
  final int cancelledCount;

  /// 总渲染时间（各次渲染耗时之和，含失败尝试）。
  final Duration totalRenderTime;
}

/// 一题多公式的单公式结果。
enum FormulaQuestionOutcomeKind {
  /// 栅格化成功。
  rastered,

  /// 渲染失败但原图裁剪成功（该题 PARTIAL）。
  original,

  /// 渲染失败且裁剪亦失败（该题 SKIPPED 的原因）。
  failed,
}

/// 一题多公式的单公式结果。
class FormulaQuestionOutcome {
  const FormulaQuestionOutcome({
    required this.formulaId,
    required this.kind,
    this.result,
  });

  /// 公式标识。
  final String formulaId;

  /// 结果种类。
  final FormulaQuestionOutcomeKind kind;

  /// 成功/降级时的结果（失败时为 null）。
  final FormulaRasterResult? result;
}

/// 一题多公式的裁决（§8：任一失败 → 整题 SKIPPED；任一原图 → PARTIAL）。
class QuestionFormulaVerdict {
  const QuestionFormulaVerdict({required this.outcomes});

  /// 每公式结果（与请求同顺序）。
  final List<FormulaQuestionOutcome> outcomes;

  /// 是否跳过整题（任一公式渲染失败且裁剪亦失败）。
  bool get skipQuestion =>
      outcomes.any((o) => o.kind == FormulaQuestionOutcomeKind.failed);

  /// 是否有公式为原图（任一公式为原图 → 该题 PARTIAL）。
  bool get hasOriginal =>
      outcomes.any((o) => o.kind == FormulaQuestionOutcomeKind.original);

  /// 本题栅格总量（像素数，guard 计入用，C-13）。
  int get totalRasterPixels =>
      outcomes.fold(0, (sum, o) => sum + (o.result?.pixelCount ?? 0));
}

/// PNG 按 300 DPI 上限处理（§8/D-174：公式原图降级裁剪结果同款）。
///
/// [pngBytes] 为待嵌入的 PNG 字节；[displayWidthPt] 为其在 PDF 中的
/// 显示宽度。超 300 DPI 时等比下采样到上限；低于 300 DPI 时原样返回
/// （不放大）；解不出时返回 null（调用方按裁剪失败处理）。
Uint8List? capPngTo300Dpi(Uint8List pngBytes, double displayWidthPt) {
  final decoded = img.decodeImage(pngBytes);
  if (decoded == null) return null;
  final capW = ContentGuard.dpiCapWidthPx(displayWidthPt);
  if (decoded.width <= capW) return pngBytes;
  final scaledH = (decoded.height * capW / decoded.width).round();
  final resized = img.copyResize(decoded, width: capW, height: scaledH);
  return img.encodePng(resized);
}

/// 公式离屏栅格化器（主 Isolate 用；一次只渲染一个公式）。
class FormulaRasterizer {
  FormulaRasterizer({this.hooks});

  /// 测试钩子（生产为 null）。
  final FormulaRasterHooks? hooks;

  OverlayEntry? _entry;
  GlobalKey<_FormulaRenderHostState>? _hostKey;
  bool _cancelled = false;
  var _renderedCount = 0;
  var _failedCount = 0;
  var _cancelledCount = 0;
  var _totalRenderTime = Duration.zero;

  /// 是否已挂载。
  bool get isAttached => _entry != null;

  /// 是否已取消。
  bool get isCancelled => _cancelled;

  /// 主线程影响统计。
  FormulaRasterStats get stats => FormulaRasterStats(
    renderedCount: _renderedCount,
    failedCount: _failedCount,
    cancelledCount: _cancelledCount,
    totalRenderTime: _totalRenderTime,
  );

  /// 挂载离屏渲染宿主（屏幕外定位的 OverlayEntry）。
  ///
  /// 须在事件处理等非 build 时段调用（build 期间插 OverlayEntry
  /// 会触发 setState 警告）。重复调用无操作。
  void attach(BuildContext context) {
    if (_entry != null) return;
    _hostKey = GlobalKey<_FormulaRenderHostState>();
    final key = _hostKey!;
    _entry = OverlayEntry(
      builder: (_) =>
          Positioned(left: -10000, top: 0, child: _FormulaRenderHost(key: key)),
    );
    Overlay.of(context).insert(_entry!);
  }

  /// 卸载离屏渲染宿主（取消后、任务结束时调；卸载后渲染抛错）。
  void detach() {
    _entry?.remove();
    _entry = null;
    _hostKey = null;
  }

  /// 请求取消（检查点处生效；`toImage()` 飞行中允许当前渲染完成
  /// 后再丢弃结果，不再启动后续渲染）。
  void cancel() {
    _cancelled = true;
  }

  /// 清除取消标志（新导出任务开始时调）。
  void resetCancellation() {
    _cancelled = false;
  }

  void _check(FormulaRasterCheckpoint checkpoint) {
    hooks?.onCheckpoint?.call(checkpoint);
    if (_cancelled) {
      throw FormulaRasterException(
        FormulaRasterFailureKind.cancelled,
        '已取消（检查点：$checkpoint）',
      );
    }
  }

  Future<_FormulaRenderHostState> _hostState() async {
    final key = _hostKey;
    if (key == null) {
      throw FormulaRasterException(
        FormulaRasterFailureKind.notAttached,
        '公式栅格化器未挂载',
      );
    }
    for (var i = 0; i < 10; i++) {
      final state = key.currentState;
      if (state != null) return state;
      await WidgetsBinding.instance.endOfFrame;
    }
    throw FormulaRasterException(
      FormulaRasterFailureKind.notAttached,
      '公式栅格化器未挂载',
    );
  }

  /// 栅格化一个公式，PNG 写任务临时目录（`formulas/<formulaId>.png`）。
  ///
  /// [tempDir] 为任务临时目录（须已存在；其下建 `formulas` 子目录）。
  /// 取消/失败时不留半截文件；`ui.Image` 编码完立即释放。
  Future<FormulaRasterResult> rasterize(
    FormulaRasterRequest request, {
    required Directory tempDir,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      return await _rasterize(request, tempDir: tempDir);
    } on FormulaRasterException catch (e) {
      if (e.kind == FormulaRasterFailureKind.cancelled) {
        _cancelledCount++;
      } else {
        _failedCount++;
      }
      rethrow;
    } finally {
      stopwatch.stop();
      _totalRenderTime += stopwatch.elapsed;
    }
  }

  Future<FormulaRasterResult> _rasterize(
    FormulaRasterRequest request, {
    required Directory tempDir,
  }) async {
    _check(FormulaRasterCheckpoint.beforeRender);
    final host = await _hostState();
    final attempt = await host.show(request);
    _check(FormulaRasterCheckpoint.afterLayout);
    if (attempt.failed || attempt.boundarySize == null) {
      throw FormulaRasterException(
        FormulaRasterFailureKind.renderFailed,
        '公式渲染失败（题内公式 ${request.formulaId}）',
      );
    }
    final boundarySize = attempt.boundarySize!;
    if (boundarySize.width <= 0 || boundarySize.height <= 0) {
      throw FormulaRasterException(
        FormulaRasterFailureKind.renderFailed,
        '公式渲染为空（题内公式 ${request.formulaId}）',
      );
    }
    // 超长公式判定：独立公式自然宽超内容宽即已等比缩小。
    final shrunk =
        request.displayMode &&
        attempt.naturalWidth != null &&
        attempt.naturalWidth! > PdfExportGeometry.contentWidthPt + 0.5;
    // 十八批 P1（D-216）：基线偏移按同一缩小比例换算（行内公式不缩小，
    // 比例恒为 1；独立公式被 FittedBox 等比缩小时基线同比缩放；
    // 量不到基线时为 null，调用方按旧行为处理）。
    final rawBaseline = attempt.baselineOffset;
    double? baselineOffsetPt;
    if (rawBaseline != null) {
      var scale = 1.0;
      if (shrunk && attempt.naturalWidth != null) {
        scale =
            PdfExportGeometry.contentWidthPt / attempt.naturalWidth!;
      }
      baselineOffsetPt = rawBaseline * scale;
    }
    _check(FormulaRasterCheckpoint.beforeToImage);
    final boundary = attempt.boundary;
    if (boundary == null) {
      throw FormulaRasterException(
        FormulaRasterFailureKind.renderFailed,
        '公式渲染宿主未就绪（题内公式 ${request.formulaId}）',
      );
    }
    ui.Image image;
    try {
      image = await boundary.toImage(pixelRatio: kFormulaRasterPixelRatio);
    } catch (_) {
      throw FormulaRasterException(
        FormulaRasterFailureKind.renderFailed,
        '公式位图获取失败（题内公式 ${request.formulaId}）',
      );
    }
    try {
      _check(FormulaRasterCheckpoint.afterToImage);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw FormulaRasterException(
          FormulaRasterFailureKind.encodeFailed,
          '公式 PNG 编码失败（题内公式 ${request.formulaId}）',
        );
      }
      _check(FormulaRasterCheckpoint.afterEncode);
      final bytes = byteData.buffer.asUint8List();
      _check(FormulaRasterCheckpoint.beforeWrite);
      final formulasDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}formulas',
      );
      if (!formulasDir.existsSync()) {
        formulasDir.createSync(recursive: true);
      }
      final safeId = request.formulaId.replaceAll(
        RegExp(r'[^A-Za-z0-9._-]'),
        '_',
      );
      final target = File(
        '${formulasDir.path}${Platform.pathSeparator}$safeId.png',
      );
      final tmp = File('${target.path}.tmp');
      try {
        // 同步写：公式 PNG 很小（通常 < 200 KB），同步写无主线程负担；
        // 且 testWidgets 的 FakeAsync 区不放行异步 IO，异步写在测试里
        // 永远等不到完成（生产真机不受影响，但同步写同样适用）。
        tmp.writeAsBytesSync(bytes);
        _check(FormulaRasterCheckpoint.afterWrite);
        tmp.renameSync(target.path);
      } on FormulaRasterException {
        _deleteQuietly(tmp);
        _deleteQuietly(target);
        rethrow;
      } on FileSystemException catch (e) {
        _deleteQuietly(tmp);
        throw FormulaRasterException(
          FormulaRasterFailureKind.writeFailed,
          '公式临时文件写入失败（题内公式 ${request.formulaId}）：${e.message}',
        );
      }
      _renderedCount++;
      return FormulaRasterResult(
        formulaId: request.formulaId,
        relativePath: 'formulas/$safeId.png',
        pixelWidth: image.width,
        pixelHeight: image.height,
        logicalWidthPt: boundarySize.width,
        logicalHeightPt: boundarySize.height,
        effectiveDpi: image.width / (boundarySize.width / 72),
        shrunk: shrunk,
        baselineOffsetPt: baselineOffsetPt,
      );
    } finally {
      // 编码完立即释放（一次只持有一个公式的 ui.Image）。
      image.dispose();
    }
  }

  /// 一题多公式栅格化 + 降级链（§8）。
  ///
  /// [cropOriginal] 为原图裁剪回调（调用方实现：`cropFormulaImageBytes`
  /// + SliceWriteGuard 锁内执行；返回 null = 裁剪失败/无 bbox）。
  /// 渲染失败的公式走裁剪；裁剪成功（300 DPI 上限处理后）记原图，
  /// 裁剪失败记失败。取消时立即中止，已写文件全部清理后原样抛错。
  Future<QuestionFormulaVerdict> rasterizeQuestionFormulas({
    required List<FormulaRasterRequest> requests,
    required Directory tempDir,
    required Future<Uint8List?> Function(int formulaIndex) cropOriginal,
  }) async {
    final outcomes = <FormulaQuestionOutcome>[];
    try {
      for (var i = 0; i < requests.length; i++) {
        final request = requests[i];
        FormulaRasterResult? result;
        try {
          result = await rasterize(request, tempDir: tempDir);
          outcomes.add(
            FormulaQuestionOutcome(
              formulaId: request.formulaId,
              kind: FormulaQuestionOutcomeKind.rastered,
              result: result,
            ),
          );
          continue;
        } on FormulaRasterException catch (e) {
          if (e.kind == FormulaRasterFailureKind.cancelled) rethrow;
          // 渲染失败 → 原图裁剪降级链。
        }
        Uint8List? cropped;
        try {
          cropped = await cropOriginal(i);
        } catch (_) {
          cropped = null;
        }
        if (cropped == null) {
          outcomes.add(
            FormulaQuestionOutcome(
              formulaId: request.formulaId,
              kind: FormulaQuestionOutcomeKind.failed,
            ),
          );
          continue;
        }
        final displayWidth = request.displayMode
            ? PdfExportGeometry.contentWidthPt
            : _inlineDisplayWidth(request);
        final capped = capPngTo300Dpi(cropped, displayWidth);
        if (capped == null) {
          outcomes.add(
            FormulaQuestionOutcome(
              formulaId: request.formulaId,
              kind: FormulaQuestionOutcomeKind.failed,
            ),
          );
          continue;
        }
        final decoded = img.decodeImage(capped);
        if (decoded == null) {
          outcomes.add(
            FormulaQuestionOutcome(
              formulaId: request.formulaId,
              kind: FormulaQuestionOutcomeKind.failed,
            ),
          );
          continue;
        }
        final safeId = request.formulaId.replaceAll(
          RegExp(r'[^A-Za-z0-9._-]'),
          '_',
        );
        final formulasDir = Directory(
          '${tempDir.path}${Platform.pathSeparator}formulas',
        );
        if (!formulasDir.existsSync()) {
          formulasDir.createSync(recursive: true);
        }
        final target = File(
          '${formulasDir.path}${Platform.pathSeparator}$safeId-orig.png',
        );
        try {
          target.writeAsBytesSync(capped);
        } on FileSystemException {
          outcomes.add(
            FormulaQuestionOutcome(
              formulaId: request.formulaId,
              kind: FormulaQuestionOutcomeKind.failed,
            ),
          );
          continue;
        }
        final logicalWidthPt = displayWidth;
        final logicalHeightPt = decoded.height / decoded.width * displayWidth;
        outcomes.add(
          FormulaQuestionOutcome(
            formulaId: request.formulaId,
            kind: FormulaQuestionOutcomeKind.original,
            result: FormulaRasterResult(
              formulaId: request.formulaId,
              relativePath: 'formulas/$safeId-orig.png',
              pixelWidth: decoded.width,
              pixelHeight: decoded.height,
              logicalWidthPt: logicalWidthPt,
              logicalHeightPt: logicalHeightPt,
              effectiveDpi: ContentGuard.effectiveDpi(
                widthPx: decoded.width,
                displayWidthPt: displayWidth,
              ),
              shrunk: false,
              isOriginal: true,
              // 十八批 P1（D-216）：原图降级无栅格化结果，基线偏移
              // 未知（null）。PDF 按旧居中启发式放、Word 不下移；
              // 不得用猜的数。
            ),
          ),
        );
      }
    } on FormulaRasterException catch (e) {
      if (e.kind == FormulaRasterFailureKind.cancelled) {
        // 取消：清理本题已写文件，不留半截产物。
        for (final outcome in outcomes) {
          final path = outcome.result?.relativePath;
          if (path != null) {
            _deleteQuietly(
              File('${tempDir.path}${Platform.pathSeparator}$path'),
            );
          }
        }
      }
      rethrow;
    }
    return QuestionFormulaVerdict(outcomes: outcomes);
  }

  /// 行内公式降级图的显示宽（pt）：按正文字号高度估算宽高比 4:1
  /// 的典型行内公式（与 content_guard 的盘点估算同口径）。
  double _inlineDisplayWidth(FormulaRasterRequest request) {
    final heightPx = request.fontSizePt / 72 * 300;
    return heightPx * 4 / 300 * 72;
  }

  static void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }
}

/// 一次离屏渲染尝试的结果（宿主内部用）。
class _RenderAttempt {
  const _RenderAttempt({
    required this.failed,
    this.boundary,
    this.boundarySize,
    this.naturalWidth,
    this.baselineOffset,
  });

  /// 公式解析/构建是否失败（onErrorFallback 触发）。
  final bool failed;

  /// 待取图的 RepaintBoundary（失败时为 null，调用方只看 failed）。
  final RenderRepaintBoundary? boundary;

  /// 边界逻辑尺寸（布局后）。
  final ui.Size? boundarySize;

  /// 公式自然宽（pt；独立公式超宽判定时用）。
  final double? naturalWidth;

  /// 数学 alphabetic 基线偏移（pt，Math.tex 顶到基线的距离；
  /// 量不到时为 null，调用方按旧行为处理）。
  final double? baselineOffset;
}

/// layout 期间量取子件 alphabetic 基线的包框（十八批 P1）。
///
/// `RenderBox.getDistanceToBaseline` 只能在 layout/paint 期间调用
/// （帧回调里直接调会触 debug 断言）；本包框在自身 `performLayout`
/// 内合法量取，量到的值存在字段里供帧回调读取。包框紧贴子件
/// （RenderProxyBox，子件位于 (0, 0)），量到的偏移即子件顶到其
/// 基线的距离；量不到（子件无基线）时为 null。
class _BaselineMeasureBox extends SingleChildRenderObjectWidget {
  const _BaselineMeasureBox({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBaselineMeasureBox();
}

class _RenderBaselineMeasureBox extends RenderProxyBox {
  double? baselineOffset;

  @override
  void performLayout() {
    super.performLayout();
    baselineOffset =
        child?.getDistanceToBaseline(TextBaseline.alphabetic);
  }
}

/// 离屏渲染宿主（OverlayEntry 内，屏幕外定位）。
class _FormulaRenderHost extends StatefulWidget {
  const _FormulaRenderHost({super.key});

  @override
  State<_FormulaRenderHost> createState() => _FormulaRenderHostState();
}

class _FormulaRenderHostState extends State<_FormulaRenderHost> {
  final _boundaryKey = GlobalKey();
  final _mathKey = GlobalKey();
  final _baselineKey = GlobalKey();
  FormulaRasterRequest? _request;
  var _failed = false;
  Completer<_RenderAttempt>? _completer;

  /// 渲染一个公式：挂载后等一帧，返回布局结果。
  Future<_RenderAttempt> show(FormulaRasterRequest request) {
    _failed = false;
    _request = request;
    _completer = Completer<_RenderAttempt>();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final completer = _completer;
      if (completer == null || completer.isCompleted) return;
      final context = _boundaryKey.currentContext;
      final boundaryObject = context?.findRenderObject();
      if (boundaryObject is! RenderRepaintBoundary) {
        completer.complete(const _RenderAttempt(failed: true));
        return;
      }
      final mathSize = _mathKey.currentContext?.size;
      final baseline =
          (_baselineKey.currentContext?.findRenderObject()
                  as _RenderBaselineMeasureBox?)
              ?.baselineOffset;
      completer.complete(
        _RenderAttempt(
          failed: _failed,
          boundary: boundaryObject,
          boundarySize: boundaryObject.size,
          naturalWidth: mathSize?.width,
          baselineOffset: baseline,
        ),
      );
    });
    return _completer!.future;
  }

  @override
  Widget build(BuildContext context) {
    final request = _request;
    if (request == null) return const SizedBox.shrink();
    // 十八批 P1：Math.tex 外包一层基线量取框（不改变布局与绘制，
    // 只在 performLayout 内量取 alphabetic 基线偏移）。
    final math = _BaselineMeasureBox(
      key: _baselineKey,
      child: Math.tex(
        request.latex,
        key: _mathKey,
        mathStyle: request.displayMode ? MathStyle.display : MathStyle.text,
        textStyle: TextStyle(
          fontSize: request.fontSizePt,
          // 十七批 P1：离屏渲染无 Material 祖先，Math.tex 会继承
          // MaterialApp 的红色错误兜底样式 0xD0FF0000（w900 超粗）；
          // 写死黑色 + 常规字重，字号仍按请求 pin。
          color: Colors.black,
          fontWeight: FontWeight.normal,
        ),
        // 失败信号只记标志，不含源码；回退 widget 为空盒（调用方按
        // 失败走降级链，不印失败占位）。
        onErrorFallback: (_) {
          _failed = true;
          return const SizedBox.shrink();
        },
      ),
    );
    final Widget child;
    if (request.displayMode) {
      // 独立公式：超内容宽时等比缩小（FittedBox scaleDown），
      // 未超宽时原尺寸；自然宽由 _mathKey 量得，供 shrunk 判定。
      child = SizedBox(
        width: PdfExportGeometry.contentWidthPt,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: math,
        ),
      );
    } else {
      child = math;
    }
    return RepaintBoundary(key: _boundaryKey, child: child);
  }
}
