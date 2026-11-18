// Stage A 离线验证：对 39 页样本跑生产 YOLO 第 1 层检测，出框 JSON。
// 一次性离线工具，不进应用、不进全量套件。
// 用法：
//   TMPDIR=$HOME/workspace/flutter-test-tmp \
//   LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux \
//   ~/workspace/flutter-install/flutter/bin/flutter test tool/stage_a_detect.dart --concurrency=1 --timeout 120m
// 输出：~/workspace/batch12-work/stage-a/detect/<page>.json
// 注意：单次推理超时用 detectTimeoutForTest 放到 10 分钟（VM 只有 1.5 核，
// YOLO11s 1280 推理可能超过生产默认的 60 秒超时）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/services/yolo_onnx_service.dart';

void main() {
  test(
    'stage-a detect all pages',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      // 离线工具故意用测试钩子放宽超时（VM 上 YOLO11s 推理可能超 60 秒）；
      // 不进应用、不进全量套件。
      // ignore: invalid_use_of_visible_for_testing_member
      YoloOnnxService.detectTimeoutForTest = const Duration(minutes: 10);
      final pagesDir = Directory(
        '/home/hatch/workspace/batch12-work/stage-a/pages',
      );
      final outDir = Directory(
        '/home/hatch/workspace/batch12-work/stage-a/detect',
      );
      await outDir.create(recursive: true);
      final service = YoloOnnxService();
      final files = pagesDir.listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      // 只跑传入的页（环境变量 STAGE_A_PAGES，逗号分隔，如 single-01,double-03），
      // 不传则跑全部 39 页。
      final only = Platform.environment['STAGE_A_PAGES']
          ?.split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet();
      var detected = 0;
      var fallback = 0;
      for (final f in files) {
        final pageId = f.uri.pathSegments.last.split('.').first;
        if (only != null && !only.contains(pageId)) continue;
        final sw = Stopwatch()..start();
        final result = await service.detectPage(imagePath: f.path, page: 1);
        sw.stop();
        if (!service.hasRealModel) {
          fail('onnxruntime 原生库未加载，无法跑真实检测');
        }
        final data = {
          'page': pageId,
          'file': f.path,
          'usedFallback': result.usedFallback,
          'error': result.error,
          'detectMs': sw.elapsedMilliseconds,
          'boxes': result.boxes
              .map(
                (b) => {
                  'id': b.id,
                  'x': b.x,
                  'y': b.y,
                  'w': b.w,
                  'h': b.h,
                  'confidence': b.confidence,
                },
              )
              .toList(),
        };
        await File('${outDir.path}/$pageId.json')
            .writeAsString(jsonEncode(data));
        // ignore: avoid_print
        print(
          '$pageId: fallback=${result.usedFallback} '
          'boxes=${result.boxes.length} ms=${sw.elapsedMilliseconds}',
        );
        if (result.usedFallback) {
          fallback++;
        } else {
          detected++;
        }
      }
      // ignore: avoid_print
      print('DONE detected=$detected fallback=$fallback');
    },
    timeout: const Timeout(Duration(minutes: 120)),
  );
}
