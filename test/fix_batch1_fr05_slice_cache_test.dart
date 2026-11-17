// FR-05 重框后旧切片滞留：evict 要覆盖 ResizeImage 缓存键，
// 已显示的切片 Image 要靠 ValueKey（写盘时间）强制重建。
//
// 选型（D-61）：evictCachedFileImage = 裸 FileImage evict +
// imageCache.clear()（ResizeImageKey 是私有的、构造不出来，且各渲染点
// 的 cacheWidth 随 maxHeight × dpr 变化、无法逐个枚举）；
// QuestionSlice / CompactSliceThumb 的 Image.file 加 ValueKey
// （文件写盘时间毫秒 + 字节大小），文件重写后 widget 重建、重新解码。
// 覆盖写同一路径后：(a) ResizeImage 侧 evict 再读到新图；
// (b) 同一 QuestionSlice 在同一进程内即时变色。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/page_image_pipeline.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/widgets.dart';

/// 生成纯色 PNG。
Future<Uint8List> _solidPng(int color, int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = ui.Color(color),
  );
  final img = await recorder.endRecording().toImage(w, h);
  try {
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    img.dispose();
  }
}

/// 通过指定 provider 读文件当前内容的第一帧（走 imageCache）。
/// 只在普通 test()（真异步）里用：testWidgets 的 FakeAsync 下
/// ImageStream 完成不了，会一直挂住（p05 同款做法）。
Future<ui.Image> _loadVia(ImageProvider provider) async {
  final completer = Completer<ui.Image>();
  final stream = provider.resolve(const ImageConfiguration());
  late ImageStreamListener listener;
  listener = ImageStreamListener((info, _) {
    if (!completer.isCompleted) completer.complete(info.image);
    stream.removeListener(listener);
  });
  stream.addListener(listener);
  return completer.future.timeout(const Duration(seconds: 15));
}

/// 取 ui.Image 中心像素的 RGB。
Future<(int, int, int)> _centerPixel(ui.Image img) async {
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final rgba = data!.buffer.asUint8List();
  final o = ((img.height ~/ 2) * img.width + (img.width ~/ 2)) * 4;
  return (rgba[o], rgba[o + 1], rgba[o + 2]);
}

void main() {
  group('FR-05 evict 覆盖 ResizeImage 缓存键', () {
    test('带 cacheWidth 的渲染：不 evict 读到旧图；evict 后读到新图', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final dir = await Directory.systemTemp.createTemp('fr05-resize');
      try {
        final file = File('${dir.path}/slice.png');
        await file.writeAsBytes(await _solidPng(0xFFFF0000, 64, 48));
        // QuestionSlice 的 cacheWidth 口径：逻辑宽 × dpr（测试里 dpr=1）。
        final red = await _loadVia(ResizeImage(FileImage(file), width: 64));
        expect(await _centerPixel(red), (255, 0, 0));
        red.dispose();

        // 覆盖写蓝图：不 evict 再读，仍是 ResizeImage 缓存里的红图。
        await file.writeAsBytes(await _solidPng(0xFF0000FF, 64, 48));
        final cached = await _loadVia(ResizeImage(FileImage(file), width: 64));
        expect(await _centerPixel(cached), (255, 0, 0));
        cached.dispose();

        // evict 后再读，是新写的蓝图。（裸键未被 ResizeImage 加载填充，
        // 返回值不一定 true——isTrue 语义由 p05 旧测试覆盖。）
        await evictCachedFileImage(file.path);
        final fresh = await _loadVia(ResizeImage(FileImage(file), width: 64));
        expect(await _centerPixel(fresh), (0, 0, 255));
        fresh.dispose();
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('FR-05 同一 QuestionSlice 在同一进程内即时更新', () {
    // 仓库既有惯例（collect_page_test.dart 的 tapConfirmAndWait）：
    // 测试体在 fake async zone 里，真实 IO 的 Future 等不到完成；
    // 须在 runAsync 内反复 pump + 真实延时推进。
    Future<void> pumpWithRealIo(WidgetTester tester) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 20; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        await tester.pumpAndSettle();
      });
      await tester.pumpAndSettle();
    }

    testWidgets('覆盖写切片 + evict 后，同一题的切片即时变色', (tester) async {
      // PNG 编解码也是真实异步，先在 runAsync 里生成好。
      late Uint8List redBytes;
      late Uint8List blueBytes;
      await tester.runAsync(() async {
        redBytes = await _solidPng(0xFFFF0000, 200, 100);
        blueBytes = await _solidPng(0xFF0000FF, 200, 100);
      });
      final dir = Directory.systemTemp.createTempSync('fr05-widget');
      AppDatabase.testDataDirectory = dir.path;
      addTearDown(() {
        AppDatabase.testDataDirectory = null;
      });
      final slicesDir = Directory('${dir.path}/slices');
      slicesDir.createSync(recursive: true);
      final sliceFile = File('${slicesDir.path}/q1.png');
      sliceFile.writeAsBytesSync(redBytes);

      final question = Question(
        id: 'q1',
        title: '题 1',
        subjectId: 'math',
        createdAt: DateTime(2026, 11, 17),
        slicePath: 'slices/q1.png',
        sliceWidth: 200,
        sliceHeight: 100,
      );
      final boundaryKey = GlobalKey();
      Widget tree() => MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 220,
              height: 120,
              child: RepaintBoundary(
                key: boundaryKey,
                child: QuestionSlice(question: question, maxHeight: 120),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(tree());
      await pumpWithRealIo(tester);

      Future<(int, int, int)> boundaryCenterPixel() async {
        late (int, int, int) px;
        await tester.runAsync(() async {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final rgba = data!.buffer.asUint8List();
          final o =
              ((image.height ~/ 2) * image.width + (image.width ~/ 2)) * 4;
          px = (rgba[o], rgba[o + 1], rgba[o + 2]);
          image.dispose();
        });
        return px;
      }

      expect(await boundaryCenterPixel(), (255, 0, 0));

      // 重框确认的真实顺序：覆盖写切片 → evict → 同一题重建。
      // 写盘时间显式 +2 秒，避免同毫秒写两次导致 ValueKey 不变。
      sliceFile.writeAsBytesSync(blueBytes);
      sliceFile.setLastModifiedSync(
        DateTime.now().add(const Duration(seconds: 2)),
      );
      await tester.runAsync(() async {
        await evictCachedFileImage(sliceFile.path);
      });
      await tester.pumpWidget(tree());
      await pumpWithRealIo(tester);
      expect(await boundaryCenterPixel(), (0, 0, 255));
      dir.deleteSync(recursive: true);
    });
  });
}
