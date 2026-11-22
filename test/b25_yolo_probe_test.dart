// ignore_for_file: avoid_print
// 二十五批 yolo 定位探针：只定位 Win11 上首次碰 FFI 时挂在哪一步。
//
// 背景：Win11 全量里 8 道 yolo 测试全部 `did not complete`（挂起，不是崩
// 溃）：日志无退出码、无超时字样，纯 Dart 组全过，模型缺失那道也挂，
// 与推理无关；应用同机切题正常。加载链（lib/services/yolo_onnx_service.dart
// `_loadOnce`）：loadGate → OrtEnv.instance.init() → rootBundle.load 模型
// → OrtSession.fromBuffer → runAsync。本探针把链上每一步拆开，
// 每步前后都打印 PROBE 标记，Win11 上跑到哪一步停住、最后一条
// start 标记就是挂点。
//
// 单个 test、顺序执行、每步 20 秒 Future.timeout 保护、整个 test
// 2 分钟超时。Linux 上必须全过（yolo 组 28/28 全过）。
// 只写本文件：不动产品代码、不改已有测试。
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:quiz_master2/services/yolo_onnx_service.dart';

/// 每步超时保护：FFI 同步调用卡住时 isolate 被堵住、定时器也触发不了，
/// 此时靠整个 test 的 2 分钟超时兜底，最后一条 start 标记即挂点。
const _stepTimeout = Duration(seconds: 20);

/// 服务里的模型 asset 路径常量（YoloOnnxService 默认构造参数）。
const _modelAsset = 'assets/models/question/yolo11s-question-v1.onnx';

void main() {
  OrtSession? probeSession;
  OrtSessionOptions? probeOptions;

  tearDown(() {
    // 释放本探针建的 session，并把服务静态加载状态复位，
    // 免得影响之后跑在本进程里的测试。
    try {
      probeSession?.release();
    } catch (_) {}
    probeSession = null;
    try {
      probeOptions?.release();
    } catch (_) {}
    probeOptions = null;
    YoloOnnxService.resetLoadStateForTest();
  });

  test(
    'b25 yolo probe：逐步定位首次 FFI 挂点',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      // 与 service 默认值同一路径常量（YoloOnnxService 默认构造参数）。
      expect(YoloOnnxService().questionModelAsset, _modelAsset);

      // —— step 1：DynamicLibrary 加载 onnxruntime 库 ——
      // 与 onnxruntime 包 bindings.dart 顶层 _dylib 同款加载方式
      // （Windows：onnxruntime.dll；Linux：libonnxruntime.so.1.15.1）。
      // 注意：包自己的 _dylib 是懒初始化，要到 step 2 首次碰
      // onnxRuntimeBinding 时才加载；这里先独立 open 一次，测
      // “加载器能不能找到/打开这个库”本身。
      print('PROBE step 1 DynamicLibrary.open start');
      final libName = Platform.isWindows
          ? 'onnxruntime.dll'
          : 'libonnxruntime.so.1.15.1';
      DynamicLibrary lib;
      try {
        lib = await Future(
          () => DynamicLibrary.open(libName),
        ).timeout(_stepTimeout);
      } catch (e) {
        print('PROBE step 1 DynamicLibrary.open fail: $e');
        rethrow;
      }
      print('PROBE step 1 DynamicLibrary.open ok: $libName handle=$lib');

      // —— step 2：OrtEnv.instance 构造（GetApi(14)）——
      // 构造时首次触及包的 onnxRuntimeBinding，触发顶层 _dylib
      // 初始化，并调 OrtGetApiBase().ref.GetApi(14) 取 API 表。
      print('PROBE step 2 OrtEnv.instance start');
      late OrtEnv env;
      try {
        env = await Future(() => OrtEnv.instance).timeout(_stepTimeout);
      } catch (e) {
        print('PROBE step 2 OrtEnv.instance fail: $e');
        rethrow;
      }
      final version = await Future(
        () => OrtEnv.version,
      ).timeout(_stepTimeout);
      print('PROBE step 2 OrtEnv.instance ok: env=$env version=$version');

      // —— step 3：OrtEnv.instance.init()（CreateEnv）——
      print('PROBE step 3 OrtEnv.init start');
      try {
        await Future(() => env.init()).timeout(_stepTimeout);
      } catch (e) {
        print('PROBE step 3 OrtEnv.init fail: $e');
        rethrow;
      }
      print('PROBE step 3 OrtEnv.init ok');

      // —— step 4：rootBundle.load 模型 ——
      print('PROBE step 4 rootBundle.load model start: $_modelAsset');
      late Uint8List modelBytes;
      try {
        final data = await rootBundle.load(_modelAsset).timeout(_stepTimeout);
        modelBytes = data.buffer.asUint8List();
      } catch (e) {
        print('PROBE step 4 rootBundle.load model fail: $e');
        rethrow;
      }
      print(
        'PROBE step 4 rootBundle.load model ok: ${modelBytes.lengthInBytes} bytes',
      );

      // —— step 5：OrtSession.fromBuffer ——
      print('PROBE step 5 OrtSession.fromBuffer start');
      try {
        probeOptions = await Future(
          () => OrtSessionOptions(),
        ).timeout(_stepTimeout);
        probeSession = await Future(
          () => OrtSession.fromBuffer(modelBytes, probeOptions!),
        ).timeout(_stepTimeout);
      } catch (e) {
        print('PROBE step 5 OrtSession.fromBuffer fail: $e');
        rethrow;
      }
      print('PROBE step 5 OrtSession.fromBuffer ok: session=$probeSession');

      // —— step 6：runAsync 推理 ——
      // 小合成图：100×100 白底（抄 test/yolo_onnx_service_test.dart
      // 里 _whitePagePng 的画法），letterbox 到 1280×1280、转 CHW
      // float32（抄 YoloOnnxService._letterboxTensor 的做法），
      // 直接调 session.runAsync，不走服务层。
      print('PROBE step 6 runAsync start');
      final input = await _letterboxWhitePage();
      final inputOrt = OrtValueTensor.createTensorWithDataList(input, [
        1,
        3,
        YoloOnnxService.questionInputSize,
        YoloOnnxService.questionInputSize,
      ]);
      final runOptions = OrtRunOptions();
      try {
        final outputs = await probeSession!
            .runAsync(runOptions, {'images': inputOrt})
            ?.timeout(_stepTimeout);
        if (outputs == null) {
          print('PROBE step 6 runAsync fail: runAsync returned null');
          fail('runAsync returned null');
        }
        final first = outputs.firstOrNull;
        var shapeInfo = 'no outputs';
        if (first != null) {
          final nested = first.value as List;
          final channels = nested.first as List;
          shapeInfo =
              'outputs=${outputs.length} '
              'first=[1][${channels.length}][${(channels.first as List).length}]';
          for (final o in outputs) {
            o?.release();
          }
        }
        print('PROBE step 6 runAsync ok: $shapeInfo');
      } catch (e) {
        print('PROBE step 6 runAsync fail: $e');
        rethrow;
      } finally {
        inputOrt.release();
        runOptions.release();
      }

      print('PROBE all steps ok');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// 100×100 白底图 → letterbox 到 1280×1280（灰边 114）→ CHW float32。
/// 画法抄 test/yolo_onnx_service_test.dart 的 _whitePagePng，
/// 转换抄 YoloOnnxService._letterboxTensor。
Future<Float32List> _letterboxWhitePage() async {
  const size = YoloOnnxService.questionInputSize;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 100, 100),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  final img = await recorder.endRecording().toImage(100, 100);
  try {
    final fit = YoloOnnxService.letterboxFit(100, 100, size);
    final recorder2 = ui.PictureRecorder();
    final canvas2 = ui.Canvas(recorder2);
    canvas2.drawRect(
      ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      ui.Paint()
        ..color = const ui.Color.fromARGB(
          255,
          YoloOnnxService.letterboxPad,
          YoloOnnxService.letterboxPad,
          YoloOnnxService.letterboxPad,
        ),
    );
    canvas2.drawImageRect(
      img,
      ui.Rect.fromLTWH(0, 0, 100, 100),
      ui.Rect.fromLTWH(
        fit.dx,
        fit.dy,
        100 * fit.scale,
        100 * fit.scale,
      ),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final letterboxed = await recorder2.endRecording().toImage(size, size);
    try {
      final bytes = await letterboxed.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
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
      letterboxed.dispose();
    }
  } finally {
    img.dispose();
  }
}
