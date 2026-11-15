import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';

import '../models/models.dart';

/// 检测结果（§1.3，P1-3 定稿）：模型失败不回占位框。
/// - 成功：`boxes` 是检出的框，`usedFallback` 为 false；
/// - 页图缺失 / 模型缺失 / 加载失败 / 推理异常：`boxes` 为空，
///   `usedFallback` 为 true，`error` 是给用户看的原因；
///   调用方显示“自动检测不可用，请手动框选”，原有框保持不动，
///   绝不自动写入占位框（只有用户明确手动画框时才落库）。
class DetectionResult {
  const DetectionResult({
    required this.boxes,
    required this.usedFallback,
    this.error,
  });

  final List<QuestionBox> boxes;
  final bool usedFallback;
  final String? error;
}

/// YOLO 检测（ONNX），当前只接第 1 层：整题框 → 整题切片。
///
/// 模型（见 docs/decision-log.md D-07 / D-23）：
/// - 第 1 层 `assets/models/question/yolo11s-question-v1.onnx`
///   （YOLO11s，输入 1×3×1280×1280，输出 1×5×33600，1 类 question）。
///
/// 第 2 层（题干 / 选项 / 配图）暂缓：模型还需再训练，见 D-23 与
/// docs/ui-replication/YOLO-INTEGRATION-REPORT.md 的再训练反馈。
/// 再接入点见 [intraEnabled] 与 [_detectIntra]：训好的模型放回
/// `assets/models/intra/yolo11s-intra-v1.onnx`、把开关打开即可，
/// 后处理（[decodeYoloOutput]）与归属（[groupInners]）都已留好。
/// 第 2 层的数据模型与界面不动：`QuestionBox.layer`、修框内框模式、
/// 三色高亮、切片区都保留，没有模型时用户仍可手动框 stem / option /
/// figure（收集页“先画框后选类型”本来就支持手画），只是不再自动检出。
///
/// 模型文件缺失、加载失败、或图片文件不存在时返回 [DetectionResult]
///（usedFallback 为 true），不抛错、不回占位框、不卡住收集流程。
/// `hasRealModel` 为真当且仅当第 1 层模型已成功加载。
class YoloOnnxService {
  YoloOnnxService({
    this.questionModelAsset = 'assets/models/question/yolo11s-question-v1.onnx',
  });

  /// 第 1 层模型（整题检测）。
  final String questionModelAsset;

  /// 第 1 层输入边长（模型定死 1280，见模型元数据 imgsz）。
  static const int questionInputSize = 1280;

  /// 第 2 层总开关：false = 不加载、不推理第 2 层模型。
  /// 再接入时把模型放回 `assets/models/intra/`、改 true，
  /// 并恢复 [_detectIntra] 里的实现（见该方法的注释）。
  static const bool intraEnabled = false;

  // —— 第 2 层常量（SR-P2-72）：以下 5 个常量都是“暂缓、再接入时启用”
  // 的记录，当前第 1 层检测不用它们（`intraEnabled` 关着，模型文件
  // 也不在仓库里）。不要删：再接入时按 [_detectIntra] 的注释恢复；
  // 也不要误读为生效参数——尤其 [crossClassIouThreshold] 在第 1 层
  // 调用里只是传参，单类时跨类去重是空操作（见 _detect 的传参注释）。
  /// 第 2 层模型路径（开关关着时不加载，仅作再接入记录）。
  static const String intraModelAsset =
      'assets/models/intra/yolo11s-intra-v1.onnx';

  /// 第 2 层输入边长（模型 imgsz 1024；输入动态，推理时统一 1024）。
  static const int intraInputSize = 1024;

  /// 置信度阈值：第 1 层 0.45（0.25 时会多出页眉条带等低分假框；
  /// 3 张实测页上真题最低 0.50）。
  static const double questionConfThreshold = 0.45;

  /// 第 2 层置信度阈值（再接入时用；Ultralytics 默认值 0.25）。
  static const double intraConfThreshold = 0.25;

  /// NMS IoU 阈值（同类去重）：0.5。
  static const double nmsIouThreshold = 0.5;

  /// 跨类去重 IoU 阈值：第 2 层里 stem 与 figure 偶有同框重复
  /// （同一区域两个标签），IoU > 0.8 时只留置信度高的一个。
  /// 第 1 层只有 1 类，此值不生效（单类时 [_crossClassNms] 是空操作，
  /// 只是把值原样传给第 2 层再接入时用），留给第 2 层再接入时用。
  static const double crossClassIouThreshold = 0.8;

  /// 第 2 层类别下标 → [QuestionBox.type]（模型元数据 names：
  /// {0: stem, 1: option, 2: figure}，再接入时用）。
  static const List<String> intraClassTypes = ['stem', 'option', 'figure'];

  /// letterbox 填充灰（Ultralytics 默认 114）。
  static const int letterboxPad = 114;

  /// 是否已加载真模型（只看第 1 层）。
  bool get hasRealModel => _loadOk;

  /// 测试用：重置模型加载状态（让下一个测试重新走 `_ensureLoaded`）。
  /// 模型缺失测试需要它：真实推理测试跑过后 `_loadOk` 已缓存为真，
  /// 不重置就测不到“模型缺失”的分支。仅测试调用。
  @visibleForTesting
  static void resetLoadStateForTest() {
    _loadOk = false;
    _loadFuture = null;
    // SR2-73：计数与屏障一并复位，免得漏到下一个测试。
    _loadAttempts = 0;
    loadGateForTest = null;
    _detectTimeout = detectTimeout;
    try {
      _questionSession?.release();
    } catch (_) {}
    _questionSession = null;
  }

  /// 最近一次真实推理的耗时与计数（占位回退时为 null）。
  YoloDetectStats? lastDetectStats;

  static OrtSession? _questionSession;
  static bool _envInitialized = false;
  // SR-P1-16：加载失败不锁死。旧实现用 `_loadAttempted` 在尝试前先置真，
  // 失败一次后 `_ensureLoaded` 永远直接返回 false，运行中补放模型也须
  // 重启才生效；现在失败不留任何“已尝试”标记，下次检测重新尝试加载，
  // 成功后由 `_loadOk` 缓存复用（该字段已删除，不再保留）。
  static bool _loadOk = false;

  /// 正在进行的加载（SR-P1-16）：并发检测共用一次加载，避免 38MB
  /// 模型被重复加载；加载失败后清空，下次检测重新尝试。
  static Future<bool>? _loadFuture;

  /// SR2-73 测试用：累计 `_loadOnce` 被调用的次数（只增，
  /// [resetLoadStateForTest] 时清零）。两次并发检测共用 `_loadFuture`
  /// 时只触发一次加载，计数为 1；各调各的加载时为 2。
  static int _loadAttempts = 0;

  /// SR2-73 测试用：读 [_loadAttempts]。
  @visibleForTesting
  static int get loadAttemptsForTest => _loadAttempts;

  /// SR2-73 测试用：并发加载的屏障，只在测试里设置。`_loadOnce`
  /// 进入后先等这个 gate，测试借此让第一次加载停在“进行中”，
  /// 再发起第二次检测，确定性地验证它加入同一个 `_loadFuture`
  /// 而不是另起一次加载。生产恒为 null，不影响加载时序。
  /// 不设屏障时无原生库的加载在 `OrtEnv.instance.init()` 处同步
  /// 失败，两次检测几乎不可能在同一次加载内重叠，计数断言会抖动。
  @visibleForTesting
  static Completer<void>? loadGateForTest;

  /// 推理串行化（SR2-73）：同一 OrtSession 上的两次并发 runAsync
  /// 会让原生库段错误（flutter_tester 实测 SIGSEGV：单次推理正常，
  /// 两次并发推理崩）。生产里检测本就是逐页串行，这里用一条 Future
  /// 链把推理排成队；加载共享不受影响（并发检测仍共用一个 _loadFuture，
  /// 只是推理依次执行）。链不断：某次抛错也不堵住后面的检测。
  ///
  /// SR3-24（Meng 定口径 (a)）：单次推理加 60 秒超时——超时按推理
  /// 异常走 fallback 并放行队列，之后的检测不再被一次卡死的推理
  /// 堵住。超时只放行队列，不取消原生推理（onnxruntime 无取消语义）：
  /// 超时的那次推理仍在后台跑完，只是调用方不再等它、也不假装它
  /// 已结束（其 `lastDetectStats` 可能晚到覆盖，不作为成功依据）。
  static const Duration detectTimeout = Duration(seconds: 60);

  /// SR3-24 测试用：覆盖 [detectTimeout]（默认 60 秒）。仅测试调用，
  /// [resetLoadStateForTest] 时恢复 60 秒。
  @visibleForTesting
  static Duration get detectTimeoutForTest => _detectTimeout;

  /// SR3-24 测试用：见 [detectTimeoutForTest]。
  @visibleForTesting
  static set detectTimeoutForTest(Duration value) => _detectTimeout = value;

  static Duration _detectTimeout = detectTimeout;

  static Future<void> _detectQueue = Future.value();

  Future<T> _serializedDetect<T>(Future<T> Function() fn) {
    final run = _detectQueue.then((_) => fn().timeout(_detectTimeout));
    _detectQueue = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  /// 对一页做检测，只返回第 1 层整题框。图片文件不存在、模型缺失
  /// 或推理中途出错时返回 `usedFallback: true` 的空结果（不回占位框，
  /// 见 [DetectionResult]），调用方流程不受影响。
  ///
  /// 文件读写用同步 IO（`existsSync` / `readAsBytesSync`）：
  /// `testWidgets` 的 FakeAsync 环境下异步文件 IO 永不完成，
  /// 会导致修框编辑器打不开（见 YOLO 报告）；同步读一张
  /// 1653×2200 PNG 约几毫秒，UI 上无感。
  Future<DetectionResult> detectPage({
    required String imagePath,
    required int page,
  }) async {
    lastDetectStats = null;
    final file = File(imagePath);
    if (!file.existsSync()) {
      return const DetectionResult(
        boxes: [],
        usedFallback: true,
        error: '页图缺失：找不到这页的图片，请重新导入',
      );
    }
    try {
      final bytes = file.readAsBytesSync();
      // SR-P2-69：Codec 用完即 dispose（与 page_image_pipeline._decode
      // 同款），否则每次检测漏一份 native 资源。
      final codec = await ui.instantiateImageCodec(bytes);
      final ui.Image pageImage;
      try {
        pageImage = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
      try {
        if (!await _ensureLoaded()) {
          return const DetectionResult(
            boxes: [],
            usedFallback: true,
            error: '自动检测不可用，请手动框选',
          );
        }
        final sw = Stopwatch()..start();
        final boxes = await _serializedDetect(() => _detect(pageImage, page));
        sw.stop();
        return DetectionResult(boxes: boxes, usedFallback: false);
      } finally {
        pageImage.dispose();
      }
    } catch (_) {
      return const DetectionResult(
        boxes: [],
        usedFallback: true,
        error: '自动检测不可用，请手动框选',
      );
    }
  }

  /// 加载失败不锁死（SR-P1-16）：成功后缓存复用，不再重复加载模型；
  /// 失败时下次检测重新尝试加载（例如运行中补放模型文件后无需重启
  /// 即可恢复）。模型确实缺失时每次检测只走一次廉价的 asset 加载
  /// 失败并返回同一个 fallback 结果——自动检测路径失败时静默，
  /// 仅用户主动点“恢复自动框”时才弹一次提示，不反复打扰用户。
  Future<bool> _ensureLoaded() async {
    if (_loadOk) return true;
    final inFlight = _loadFuture;
    if (inFlight != null) return inFlight;
    final future = _loadOnce();
    _loadFuture = future;
    final ok = await future;
    if (!ok) _loadFuture = null;
    return ok;
  }

  Future<bool> _loadOnce() async {
    // SR2-73：先计数再等屏障——测试据此确认第一次加载已进入
    // _loadOnce 并停在屏障处，再发起第二次检测。
    _loadAttempts++;
    try {
      // SR3-23：屏障等待须在 try 内——gate 以 error 完成时旧代码
      // 在 try 外抛错，`_ensureLoaded` 的清 future 一行被跳过，
      // 失败的 `_loadFuture` 永远留在原地、加载永不重试。
      // 移进 try 后 gate 报错走与加载失败同一路径：返回 false，
      // `_ensureLoaded` 清掉 `_loadFuture`，下次检测重新加载。
      final gate = loadGateForTest;
      if (gate != null) await gate.future;
      if (!_envInitialized) {
        OrtEnv.instance.init();
        _envInitialized = true;
      }
      final questionBytes = (await rootBundle.load(questionModelAsset)).buffer
          .asUint8List();
      _questionSession = OrtSession.fromBuffer(
        questionBytes,
        OrtSessionOptions(),
      );
      _loadOk = true;
    } catch (_) {
      _loadOk = false;
      _questionSession = null;
    }
    return _loadOk;
  }

  Future<List<QuestionBox>> _detect(ui.Image pageImage, int page) async {
    final pageW = pageImage.width.toDouble();
    final pageH = pageImage.height.toDouble();

    // —— 第 1 层：整页 → 整题框 ——
    final sw1 = Stopwatch()..start();
    final input1 = await _letterboxTensor(pageImage, null, questionInputSize);
    final out1 = await _run(_questionSession!, input1, questionInputSize);
    sw1.stop();
    final dets1 = decodeYoloOutput(
      out1,
      numClasses: 1,
      confThreshold: questionConfThreshold,
      nmsIou: nmsIouThreshold,
      // SR-P2-72：单类时跨类去重是空操作，此值只是传给第 2 层再接入时用。
      crossClassIou: crossClassIouThreshold,
    );
    final fit1 = letterboxFit(pageW, pageH, questionInputSize);
    final questions = <QuestionBox>[];
    for (final d in dets1) {
      questions.add(
        _toPageBox(
          d,
          fit: fit1,
          pageW: pageW,
          pageH: pageH,
          id: '', // 先占位，按阅读顺序排好后再编号
          layer: 1,
          type: 'question',
        ),
      );
    }
    // 阅读顺序：先上后下、同行先左后右，再按顺序编号 box-q1…。
    // 编号只换 id，置信度 / 来源 / 页码原样保留（§1.2(c) 小项-1：
    // 检测服务须填 confidence 与 origin='yolo'，否则两列永远为空）。
    questions.sort((a, b) {
      final dy = a.y.compareTo(b.y);
      return dy != 0 ? dy : a.x.compareTo(b.x);
    });
    final numbered = <QuestionBox>[];
    for (var i = 0; i < questions.length; i++) {
      final q = questions[i];
      numbered.add(
        QuestionBox(
          id: 'box-q${i + 1}',
          layer: 1,
          type: 'question',
          x: q.x,
          y: q.y,
          w: q.w,
          h: q.h,
          confidence: q.confidence,
          origin: q.origin,
          page: page,
        ),
      );
    }

    // —— 第 2 层：暂缓（见 intraEnabled）。再接入时在这里调
    // [_detectIntra]，把返回的题内框拼在整题框后面返回。
    final inners = await _detectIntra(pageImage, numbered);

    lastDetectStats = YoloDetectStats(
      layer1Ms: sw1.elapsedMilliseconds,
      layer1Count: numbered.length,
      layer2Count: inners.length,
    );
    return [...numbered, ...inners];
  }

  /// 第 2 层再接入点（当前恒返回空）。
  ///
  /// 恢复步骤：把训好的模型放回 `assets/models/intra/`、
  /// `pubspec.yaml` 里把 `assets/models/intra/` 声明加回来、
  /// `intraEnabled` 改 true、按下面注释实现本方法：
  /// 对每个第 1 层框裁剪后单独跑第 2 层（letterbox 1024，
  /// 绝不在整页上跑——整页跑时题干框会横跨整页），再把框映射回
  /// 页面坐标；每个选项 A/B/C/D 各为独立框，不合并；
  /// 类别下标见 [intraClassTypes]；返回前用 [groupInners]
  /// 按中心点归属到所属整题框（落不到任何题里的进 orphans，
  /// 编辑器里作独立题内框展示）。
  /// 上一版双模型实现曾跑通过程供参考：第 2 层在 3 张实测页上
  /// 题干/选项基本准，但 figure 误报多（无图的题也被框成图），
  /// 详见 YOLO 报告的再训练反馈。
  Future<List<QuestionBox>> _detectIntra(
    ui.Image pageImage,
    List<QuestionBox> questions,
  ) async {
    if (!intraEnabled) return const [];
    // TODO(D-23): 按上方注释恢复第 2 层逐题裁剪推理。
    return const [];
  }

  /// 在 worker isolate 里跑一次推理，返回输出通道
  /// `[通道][anchor]`（YOLO11 输出形状 [1, 4+nc, anchors]）。
  Future<List<List<num>>> _run(
    OrtSession session,
    Float32List input,
    int size,
  ) async {
    final inputOrt = OrtValueTensor.createTensorWithDataList(input, [
      1,
      3,
      size,
      size,
    ]);
    final runOptions = OrtRunOptions();
    try {
      final outputs =
          await session.runAsync(runOptions, {'images': inputOrt}) ??
          session.run(runOptions, {'images': inputOrt});
      final first = outputs.firstOrNull;
      if (first == null) return const [];
      // .value 是按输出形状 reshape 后的嵌套 List：[1][4+nc][anchors]。
      final nested = first.value as List;
      final channels = (nested.first as List)
          .map((c) => (c as List).cast<num>())
          .toList();
      for (final o in outputs) {
        o?.release();
      }
      return channels;
    } finally {
      inputOrt.release();
      runOptions.release();
    }
  }

  /// 把页图（或其裁剪）做 letterbox（等比缩放 + 灰边）后转成
  /// CHW float32 输入张量（像素 /255，通道顺序 RGB）。
  static Future<Float32List> _letterboxTensor(
    ui.Image src,
    ui.Rect? srcRect,
    int size,
  ) async {
    final srcR =
        srcRect ??
        ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble());
    final fit = letterboxFit(srcR.width, srcR.height, size);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      ui.Paint()
        ..color = const ui.Color.fromARGB(
          255,
          letterboxPad,
          letterboxPad,
          letterboxPad,
        ),
    );
    final dst = ui.Rect.fromLTWH(
      fit.dx,
      fit.dy,
      srcR.width * fit.scale,
      srcR.height * fit.scale,
    );
    canvas.drawImageRect(
      src,
      srcR,
      dst,
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final img = await recorder.endRecording().toImage(size, size);
    try {
      final bytes = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null) return Float32List(3 * size * size);
      final rgba = bytes.buffer.asUint8List();
      final out = Float32List(3 * size * size);
      final plane = size * size;
      for (var i = 0; i < plane; i++) {
        final o = i * 4;
        out[i] = rgba[o] / 255.0;
        out[plane + i] = rgba[o + 1] / 255.0;
        out[2 * plane + i] = rgba[o + 2] / 255.0;
      }
      return out;
    } finally {
      img.dispose();
    }
  }

  /// letterbox 等比缩放参数：缩放比 + 在方形画布上的偏移。
  static ({double scale, double dx, double dy}) letterboxFit(
    double srcW,
    double srcH,
    int size,
  ) {
    final scale = math.min(size / srcW, size / srcH);
    return (
      scale: scale,
      dx: (size - srcW * scale) / 2,
      dy: (size - srcH * scale) / 2,
    );
  }

  /// letterbox 坐标系下的框 → 它在源图（整页或裁剪）中的像素框。
  static ({double x1, double y1, double x2, double y2}) _letterboxToSource(
    YoloRawDet d,
    ({double scale, double dx, double dy}) fit,
  ) {
    return (
      x1: (d.x1 - fit.dx) / fit.scale,
      y1: (d.y1 - fit.dy) / fit.scale,
      x2: (d.x2 - fit.dx) / fit.scale,
      y2: (d.y2 - fit.dy) / fit.scale,
    );
  }

  /// letterbox 坐标系下的框 → 页面 0..1 坐标的 [QuestionBox]（已钳制）。
  static QuestionBox _toPageBox(
    YoloRawDet d, {
    required ({double scale, double dx, double dy}) fit,
    required double pageW,
    required double pageH,
    required String id,
    required int layer,
    required String type,
  }) {
    final src = _letterboxToSource(d, fit);
    return clampToPage(
      QuestionBox(
        id: id,
        layer: layer,
        type: type,
        x: src.x1 / pageW,
        y: src.y1 / pageH,
        w: (src.x2 - src.x1) / pageW,
        h: (src.y2 - src.y1) / pageH,
        // §1.2(c) 小项-1：检测框填置信度与来源；手画框为 NULL/'manual'。
        confidence: d.score,
        origin: 'yolo',
      ),
      minSize: false,
    );
  }

  /// YOLO11 输出后处理（纯函数，可单测）：输入为输出张量的通道
  /// `[通道][anchor]`，通道顺序是 cx、cy、w、h、类别分数…；
  /// 输出为 letterbox 输入坐标系下的框（xyxy 像素），已做逐类 NMS
  /// 与跨类去重，按置信度从高到低排。
  static List<YoloRawDet> decodeYoloOutput(
    List<List<num>> channels, {
    required int numClasses,
    required double confThreshold,
    required double nmsIou,
    required double crossClassIou,
  }) {
    if (channels.length < 4 + numClasses || channels.isEmpty) {
      return const [];
    }
    final anchors = channels[0].length;
    final kept = <YoloRawDet>[];
    for (var c = 0; c < numClasses; c++) {
      final clsScores = channels[4 + c];
      final dets = <YoloRawDet>[];
      for (var a = 0; a < anchors; a++) {
        final score = clsScores[a].toDouble();
        if (score < confThreshold) continue;
        dets.add(
          YoloRawDet(
            cx: channels[0][a].toDouble(),
            cy: channels[1][a].toDouble(),
            w: channels[2][a].toDouble(),
            h: channels[3][a].toDouble(),
            cls: c,
            score: score,
          ),
        );
      }
      kept.addAll(_nms(dets, nmsIou));
    }
    return _crossClassNms(kept, crossClassIou);
  }

  /// 同类 NMS：置信度从高到低，IoU 超阈值的后者去掉。
  static List<YoloRawDet> _nms(List<YoloRawDet> dets, double iouThreshold) {
    final sorted = [...dets]..sort((a, b) => b.score.compareTo(a.score));
    final kept = <YoloRawDet>[];
    for (final d in sorted) {
      var suppressed = false;
      for (final k in kept) {
        if (_iou(d, k) > iouThreshold) {
          suppressed = true;
          break;
        }
      }
      if (!suppressed) kept.add(d);
    }
    return kept;
  }

  /// 跨类去重：不同类别框几乎重合时（IoU 超阈值）只留置信度高的。
  /// 典型是第 2 层把同一段文字同时标成 stem 和 figure。
  /// SR-P2-72：与 [_nms] 同一段实现（按置信度排序后 IoU 压制），
  /// 直接复用，不再各写一份；第 2 层再接入时若需“只压不同类”
  /// 的语义，再在这里加类别判断（当前行为与旧实现逐字一致）。
  static List<YoloRawDet> _crossClassNms(
    List<YoloRawDet> dets,
    double iouThreshold,
  ) => _nms(dets, iouThreshold);

  static double _iou(YoloRawDet a, YoloRawDet b) {
    final interX1 = math.max(a.x1, b.x1);
    final interY1 = math.max(a.y1, b.y1);
    final interX2 = math.min(a.x2, b.x2);
    final interY2 = math.min(a.y2, b.y2);
    final interW = interX2 - interX1;
    final interH = interY2 - interY1;
    if (interW <= 0 || interH <= 0) return 0.0;
    final inter = interW * interH;
    final union = a.w * a.h + b.w * b.h - inter;
    return union <= 0 ? 0.0 : inter / union;
  }

  /// 把一页的混合框按中心点归属：第 2 层框分到中心点所在的第 1 层
  /// 框名下；中心点落不到任何整题框里的，归入 `orphans`（编辑器里
  /// 作独立题内框展示）。返回 `({inners, orphans})`。
  /// 当前检测只出第 1 层框，本函数返回空归属，供第 2 层再接入
  /// 与修框编辑器复用。
  static ({Map<String, List<QuestionBox>> inners, List<QuestionBox> orphans})
  groupInners(List<QuestionBox> boxes) {
    final questions = boxes.where((b) => b.layer == 1).toList();
    final inners = <String, List<QuestionBox>>{};
    final orphans = <QuestionBox>[];
    for (final b in boxes.where((b) => b.layer == 2)) {
      final cx = b.x + b.w / 2;
      final cy = b.y + b.h / 2;
      QuestionBox? owner;
      for (final q in questions) {
        if (cx >= q.x && cx <= q.x + q.w && cy >= q.y && cy <= q.y + q.h) {
          owner = q;
          break;
        }
      }
      if (owner == null) {
        orphans.add(b);
      } else {
        (inners[owner.id] ??= []).add(b);
      }
    }
    return (inners: inners, orphans: orphans);
  }

  /// 框钳制：框不得超出页面（0..1），新画的框同样钳制；尺寸随图片实际大小走。
  ///
  /// 对任何输入都不抛错。贴边语义：允许宽/高小于 0.08，不把左上角收进来——
  /// 编辑器里框的位置由用户拖动决定，静默移位会让框从光标处跳走；且
  /// `1.0 - 0.92` 的浮点值是 `0.07999…`，用 0.92 做下限会重蹈覆辙。
  /// 实现上先把宽/高钳制到剩余空间（下限 0.0，剩余空间恒 ≥ 0，`clamp`
  /// 的下限永不大于上限），空间足够时再把过小的宽/高补回 0.08，
  /// 保留原最小尺寸意图。x == 1.0 时剩余空间为 0，宽只能是 0。
  ///
  /// `minSize`（默认 true）是该“最小尺寸意图”的开关：用户手画 /
  /// 拖动 / 缩放的框要能被选中操作，沿用 0.08 下限；检测输出的框
  /// 是量出来的尺寸，必须原样保留（`minSize: false`），否则题行
  /// （实测高 0.018~0.10，多在 0.08 以下）与选项框（约 0.04×0.03）
  /// 全被撑成 0.08，相邻题行互相重叠、确认被拦，真实推理没法用。
  /// 默认行为与 A3 的回归测试完全一致，只给检测管线多一个选择。
  ///
  /// SR2-38：`minSize: false` 的检测路径改成交集语义——框与页面
  /// 求交，左/上溢出扣掉溢出的宽/高（`x=-0.1, w=0.5 → x=0,
  /// w=0.4`），与 `rotateBoxToRotatedPage` 同一语义；编辑器路径
  /// （默认 `minSize: true`）保持现状：左上角收到 0、尺寸不变，
  /// 框被拖出页边时不静默缩小、保持可抓取。
  static QuestionBox clampToPage(QuestionBox box, {bool minSize = true}) {
    if (!minSize) {
      // 交集语义：框与 [0, 1] 页面求交，溢出侧扣宽/高。
      final x1 = box.x.clamp(0.0, 1.0);
      final y1 = box.y.clamp(0.0, 1.0);
      final x2 = (box.x + box.w).clamp(0.0, 1.0);
      final y2 = (box.y + box.h).clamp(0.0, 1.0);
      return _rebuildClamped(
        box,
        x1,
        y1,
        math.max(0.0, x2 - x1),
        math.max(0.0, y2 - y1),
      );
    }
    final x = box.x.clamp(0.0, 1.0);
    final y = box.y.clamp(0.0, 1.0);
    final maxW = 1.0 - x;
    final maxH = 1.0 - y;
    final w = box.w.clamp(0.0, maxW);
    final h = box.h.clamp(0.0, maxH);
    final w2 = (minSize && maxW >= 0.08 && w < 0.08) ? 0.08 : w;
    final h2 = (minSize && maxH >= 0.08 && h < 0.08) ? 0.08 : h;
    return _rebuildClamped(box, x, y, w2, h2);
  }

  /// 钳制只改坐标与尺寸，其余字段（置信度 / 来源 / 归属 / 页码）
  /// 原样保留——以前这里重建框会丢掉 confidence 与 origin。
  static QuestionBox _rebuildClamped(
    QuestionBox box,
    double x,
    double y,
    double w,
    double h,
  ) {
    return QuestionBox(
      id: box.id,
      layer: box.layer,
      type: box.type,
      x: x,
      y: y,
      w: w,
      h: h,
      confidence: box.confidence,
      origin: box.origin,
      parentBoxId: box.parentBoxId,
      page: box.page,
      collectTaskId: box.collectTaskId,
      questionId: box.questionId,
      updatedAt: box.updatedAt,
    );
  }
}

/// 一次真实推理的耗时与计数（见 [YoloOnnxService.lastDetectStats]）。
/// 第 2 层暂缓：`layer2Count` 恒为 0，再接入后恢复统计。
class YoloDetectStats {
  const YoloDetectStats({
    required this.layer1Ms,
    required this.layer1Count,
    this.layer2Count = 0,
  });

  final int layer1Ms;
  final int layer1Count;
  final int layer2Count;

  int get totalMs => layer1Ms;
}

/// YOLO 输出解码后的单个框（letterbox 输入坐标系，xyxy 像素）。
/// 公开仅为让 [YoloOnnxService.decodeYoloOutput] 的返回类型可被测试引用。
class YoloRawDet {
  const YoloRawDet({
    required this.cx,
    required this.cy,
    required this.w,
    required this.h,
    required this.cls,
    required this.score,
  });

  final double cx, cy, w, h;
  final int cls;
  final double score;

  double get x1 => cx - w / 2;
  double get y1 => cy - h / 2;
  double get x2 => cx + w / 2;
  double get y2 => cy + h / 2;
}
