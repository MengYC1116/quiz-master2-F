// Batch 5 第五阶段 P2 服务层 / 组件 / 主题回归测试。
//
// 覆盖（以 docs/ui-replication/SELF-REVIEW.md 为准）：
// - SR-P2-59：_importPdf 存储估算不再把原文件算两次（稀疏填充文件
//   把占用顶到距 2GB 上限 5MB，2MB 的 PDF 旧算法误拒、新算法放行）。
// - SR-P2-60：任务 id 加 6 位随机段，同一毫秒两次导入不撞 id。
// - SR-P2-61：解不开的图片（.txt 改 .jpg）进 failed，不再静默进 needBox。
// - SR-P2-62：复制进度写库节流到每 5 个百分点一次（触发器计数 UPDATE）。
// - SR-P2-63：QmSegmented 禁用态只有一层 0.45 透明度。
// - SR-P2-64：QmChip 可删除 + 可点双区只留一层手势（点片身切换、点 × 删除）。
// - SR-P2-65：AppTheme 主题按钮内边距与 token 的 .btn 9px 20px 同源。
// - SR-P2-66：新学科存色在深色下雾化，不再直接用饱和色。
// - SR-P2-69：Codec 用完 dispose（解码可重复调用、不破坏后续解码）。
// - SR-P2-70：rotateBoxToRotatedPage 钳制时扣掉溢出侧的宽高。
// - SR-P2-74：切片 cacheWidth 乘 devicePixelRatio。
// - SR-P2-75：放大对话框的缩放因子不再在 build 里赋值（点 ＋/－ 仍可用）。
// Batch 6（SELF-REVIEW-2）补项：SR2-13（＋/－ 读 % 徽标断言）、
// SR2-35（QmChip
// 双区点内边距与间隙）、SR2-36（subjectLabelColor 深色雾化）、
// SR2-54（SR-P2-59 拒绝侧）、SR2-55（SR-P2-66 期望写字面色 +
// 第二输入色）、SR2-63（dpr=1.0 对照与封顶）、SR2-77（SR-P2-62
// 回调 0→70 连续）、SR2-78（SR-P2-68 的 ZIP64 / 多盘 / EOCD
// 注释拒绝路径；原 SR-P2-68 组在 test/b5_p2_data_test.dart，
// 本文件只补缺口，不动该文件）。
// 未单测：SR-P2-67（弹框失败路径无法从公开 API 模拟，见报告）、
// SR-P2-72（删死代码 / 标注由 flutter analyze + 既有 yolo/pdf 测试覆盖）、
// SR-P2-73（decision-log 文字补记）、SR-P2-76（维持现状的决定，见报告）、
// SR-P2-77（测试侧超时余量，本文件不覆盖，跑 pdf/yolo 两组验证）。
// 内存库 + 临时数据目录，不碰真实用户库。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/import_service.dart';
import 'package:quiz_master2/services/page_image_pipeline.dart';
import 'package:quiz_master2/services/pdf_render_service.dart';
import 'package:quiz_master2/services/zip_archive.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';
import 'package:quiz_master2/widgets/widgets.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';

late final Directory _tmp;

Future<QuizDatabase> openMemoryDb() async {
  final db = await AppDatabase.openForTest();
  AppDatabase.useDatabaseForTest(db);
  addTearDown(() async => db.close());
  return db;
}

/// 渲染必成的假引擎：1 页，返回 10×10 红色 PNG（不碰 PDFium）。
class _OkDoc implements PdfEngineDocument {
  @override
  int get pageCount => 1;

  @override
  Future<PdfPageRender> renderPage(
    int page, {
    required int targetLongEdge,
  }) async {
    final img = await _pngImage(10, 10, const ui.Color(0xFFFF0000));
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return PdfPageRender(
      png: data!.buffer.asUint8List(),
      width: 10,
      height: 10,
    );
  }

  @override
  Future<void> close() async {}
}

class _OkEngine implements PdfEngine {
  @override
  Future<PdfEngineDocument> open(String path) async => _OkDoc();
}

ImportService _service() => ImportService(
  AppDatabase.instance,
  pdfRenderService: PdfRenderService(engine: _OkEngine()),
);

Future<ui.Image> _pngImage(int w, int h, ui.Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = color,
  );
  return recorder.endRecording().toImage(w, h);
}

Future<Uint8List> _pngBytes({int w = 10, int h = 10}) async {
  final img = await _pngImage(w, h, const ui.Color(0xFF3366CC));
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}

/// Image.file(cacheWidth: n) 在内部包一层 ResizeImage；读它的 width 断言。
int? _imageCacheWidth(WidgetTester tester) {
  final image = tester.widget<Image>(find.byType(Image));
  final provider = image.image;
  if (provider is ResizeImage) return provider.width;
  return null;
}

/// 1×1 透明 PNG（base64）。testWidgets 里不能调 `PictureRecorder
/// .toImage()/toByteData()` 生成图片——它在 FakeAsync 环境下无 pump
/// 时永不完成（探针证实）；widget 测试要写切片文件时用这个常量。
final Uint8List _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Future<void> _pumpDpr(
  WidgetTester tester,
  Widget child, {
  double devicePixelRatio = 1.0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) {
          final data = MediaQuery.of(context);
          return MediaQuery(
            data: data.copyWith(devicePixelRatio: devicePixelRatio),
            child: Scaffold(body: Center(child: child)),
          );
        },
      ),
    ),
  );
  // 不用 pumpAndSettle：Image.file 的异步解码在 FakeAsync 下要靠
  // pump 推进；这里只断言 widget 的 cacheWidth，不等解码完成。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// SR2-78：手工改 zip 字节的帮手（在 buildZip 的合法包上改字段）。
int _zipFind(List<int> bytes, List<int> pattern) {
  for (var i = 0; i + pattern.length <= bytes.length; i++) {
    var match = true;
    for (var j = 0; j < pattern.length; j++) {
      if (bytes[i + j] != pattern[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}

int _zipFindLast(List<int> bytes, List<int> pattern) {
  var found = -1;
  for (var i = 0; i + pattern.length <= bytes.length; i++) {
    var match = true;
    for (var j = 0; j < pattern.length; j++) {
      if (bytes[i + j] != pattern[j]) {
        match = false;
        break;
      }
    }
    if (match) found = i;
  }
  return found;
}

void _zipWriteU16(List<int> bytes, int off, int v) {
  bytes[off] = v & 0xFF;
  bytes[off + 1] = (v >> 8) & 0xFF;
}

void _zipWriteU32(List<int> bytes, int off, int v) {
  bytes[off] = v & 0xFF;
  bytes[off + 1] = (v >> 8) & 0xFF;
  bytes[off + 2] = (v >> 16) & 0xFF;
  bytes[off + 3] = (v >> 24) & 0xFF;
}

void main() {
  setUpAll(() async {
    _tmp = await Directory.systemTemp.createTemp('qm2-b5-p2-services');
    AppDatabase.testDataDirectory = _tmp.path;
  });

  tearDownAll(() async {
    AppDatabase.testDataDirectory = null;
    await _tmp.delete(recursive: true);
  });

  group('SR-P2-59 存储估算不再 double-count 原文件', () {
    test('距上限 5MB + 2MB 的 PDF：旧算法误拒，新算法放行进 needBox', () async {
      await openMemoryDb();
      // 稀疏填充文件：逻辑占用 = 2GB - 5MB（不真占磁盘）。
      final filler = File('${_tmp.path}/imports/filler.bin');
      await filler.parent.create(recursive: true);
      final raf = await filler.open(mode: FileMode.write);
      await raf.truncate(ImportService.maxStorageBytes - 5 * 1024 * 1024);
      await raf.close();
      expect(
        await filler.length(),
        ImportService.maxStorageBytes - 5 * 1024 * 1024,
      );
      // 2MB 的假 PDF（假引擎不读内容，页数恒为 1）。
      final pdf = File('${_tmp.path}/p2-59.pdf');
      await pdf.writeAsBytes(List.filled(2 * 1024 * 1024, 0x25));
      final tasks = await _service().enqueue([pdf.path], subjectId: 'math');
      expect(tasks.length, 1);
      // 旧算法：used(2GB-3MB，复制后) + fileSize(2MB) + 1页×2MB
      //   = 2GB+1MB > 上限 → 误拒；新算法：used + 1页×2MB = 2GB-1MB → 放行。
      expect(tasks.first.status, CollectStatus.needBox);
      expect(tasks.first.pageCount, 1);
      await filler.delete();
    });

    test('SR2-54：占用 2GB−1MB + 2MB 的 PDF：拒绝进 failed，错误含存储上限提示', () async {
      await openMemoryDb();
      final filler = File('${_tmp.path}/imports/filler.bin');
      await filler.parent.create(recursive: true);
      final raf = await filler.open(mode: FileMode.write);
      await raf.truncate(ImportService.maxStorageBytes - 1 * 1024 * 1024);
      await raf.close();
      final pdf = File('${_tmp.path}/p2-59-reject.pdf');
      await pdf.writeAsBytes(List.filled(2 * 1024 * 1024, 0x25));
      final tasks = await _service().enqueue([pdf.path], subjectId: 'math');
      expect(tasks.length, 1);
      expect(tasks.first.status, CollectStatus.failed);
      expect(tasks.first.error, contains('2GB'));
      await filler.delete();
    });
  });

  group('SR-P2-60 任务 id 加随机段', () {
    test('同一毫秒两次导入同一文件：两个任务，id 不同', () async {
      await openMemoryDb();
      final png = File('${_tmp.path}/p2-60.jpg');
      await png.writeAsBytes(await _pngBytes());
      final first = await _service().enqueue([png.path], subjectId: 'math');
      final second = await _service().enqueue([png.path], subjectId: 'math');
      expect(first.length, 1);
      expect(second.length, 1);
      // SR2-12：只断言“两次 id 不同”钉不住随机段——旧“毫秒 + 序号”
      // 方案两次调用落在不同毫秒时同样通过。格式正则才是防线：
      // task-<毫秒>-<批内序号>-<6 位随机段>。
      final idPattern = RegExp(r'^task-\d+-\d+-\d{6}$');
      expect(first.first.id, matches(idPattern));
      expect(second.first.id, matches(idPattern));
      expect(first.first.id, isNot(second.first.id));
      expect(first.first.status, CollectStatus.needBox);
      expect(second.first.status, CollectStatus.needBox);
    });

    test('同一毫秒内连续导入（SR2-12）：20 次快速导入 id 全不同', () async {
      await openMemoryDb();
      // 紧凑循环连续导入同一小文件：20 次调用中很可能有落在同一毫秒
      // 的，随机段是唯一防线。公开 enqueue API 没有可注入的时钟，
      // 同一毫秒无法确定性安排；用 20 次快速调用逼出同毫秒碰撞窗口，
      // 断言全部 id 格式正确且互不相同。
      final png = File('${_tmp.path}/p2-60-burst.jpg');
      await png.writeAsBytes(await _pngBytes());
      final idPattern = RegExp(r'^task-\d+-\d+-\d{6}$');
      final ids = <String>{};
      for (var n = 0; n < 20; n++) {
        final tasks = await _service().enqueue([png.path], subjectId: 'math');
        expect(tasks.length, 1);
        expect(tasks.first.id, matches(idPattern));
        ids.add(tasks.first.id);
      }
      expect(ids.length, 20);
      expect((await AppDatabase.instance.allCollectTasks()).length, 20);
    });

    test('同批两次选同一文件：仍只建一个任务（SR-P1-17 去重不变）', () async {
      await openMemoryDb();
      final png = File('${_tmp.path}/p2-60-dup.jpg');
      await png.writeAsBytes(await _pngBytes());
      final tasks = await _service().enqueue([
        png.path,
        png.path,
      ], subjectId: 'math');
      expect(tasks.length, 1);
    });
  });

  group('SR-P2-61 解不开的图片进 failed', () {
    test('.txt 改 .jpg：failed，提示“这张图片打不开”，原图保留（B-NEW-10）', () async {
      await openMemoryDb();
      final fake = File('${_tmp.path}/p2-61.jpg');
      await fake.writeAsString('这根本不是一张图片，只是一段文字。' * 20);
      final tasks = await _service().enqueue([fake.path], subjectId: 'math');
      expect(tasks.length, 1);
      expect(tasks.first.status, CollectStatus.failed);
      expect(tasks.first.error, contains('打不开'));
      // B2 B-NEW-10/B-NEW-12：解不开图片的失败清理只删派生文件、
      // 保留原图；复制完成时 sourcePath 已立即持久化，失败行可重试。
      expect(
        tasks.first.sourcePath,
        ImportService.originalRelative(tasks.first.id, 'jpg'),
      );
      expect(
        Directory(
          AppDatabase.resolveDataPath(
            ImportService.taskDirRelative(tasks.first.id),
          )!,
        ).existsSync(),
        isTrue,
      );
      expect(
        File(AppDatabase.resolveDataPath(tasks.first.sourcePath)!).existsSync(),
        isTrue,
      );
    });

    test('真 PNG 换 .jpg 后缀：能解码，仍进 needBox', () async {
      await openMemoryDb();
      final png = File('${_tmp.path}/p2-61-ok.jpg');
      await png.writeAsBytes(await _pngBytes());
      final tasks = await _service().enqueue([png.path], subjectId: 'math');
      expect(tasks.first.status, CollectStatus.needBox);
    });
  });

  group('SR-P2-62 复制进度写库节流', () {
    test('5MB 文件复制：进度 UPDATE ≤ 20 次，UI 回调仍逐次', () async {
      final db = await openMemoryDb();
      await db.customStatement(
        'CREATE TABLE _b5_p2_progress_writes (n INTEGER)',
      );
      await db.customStatement('INSERT INTO _b5_p2_progress_writes VALUES (0)');
      await db.customStatement('''
        CREATE TRIGGER trg_b5_p2_count_progress
        AFTER UPDATE OF progress ON collect_tasks
        WHEN NEW.progress != OLD.progress
        BEGIN
          UPDATE _b5_p2_progress_writes SET n = n + 1;
        END
      ''');
      final pdf = File('${_tmp.path}/p2-62.pdf');
      await pdf.writeAsBytes(List.filled(5 * 1024 * 1024, 0x25));
      final reported = <int>[];
      final tasks = await _service().enqueue(
        [pdf.path],
        subjectId: 'math',
        onProgress: (id, pct) => reported.add(pct),
      );
      expect(tasks.first.status, CollectStatus.needBox);
      final rows =
          (await db.customSelect('SELECT n FROM _b5_p2_progress_writes').get())
              .map((r) => r.data)
              .toList();
      final writes = rows.first['n'] as int;
      // 未节流时 0→70% 每 1% 一次约 70 次写库 + 渲染 1 次；
      // 节流后复制约 15 次（0/5/…/70）+ 渲染 1 次。
      expect(writes, lessThanOrEqualTo(20));
      // SR2-77：UI 回调保持逐次——复制过程 0→70% 每个整数百分比
      // 都回调一次（只断言 length > 2 钉不住“每 1% 都回调”，
      // 3 个值也能通过），再加渲染段与收尾 100。
      for (var i = 0; i <= 70; i++) {
        expect(reported, contains(i));
      }
      expect(reported.length, greaterThanOrEqualTo(71));
      expect(reported.last, 100);
    });
  });

  group('SR-P2-65/66 主题 token', () {
    test('SR-P2-65：主题按钮内边距与 token 的 .btn 9px 20px 同源', () {
      final padding = AppTheme.light().filledButtonTheme.style?.padding
          ?.resolve({});
      expect(padding, const EdgeInsets.symmetric(horizontal: 20, vertical: 9));
      final scaled = AppTheme.light(scale: 1.15)
          .filledButtonTheme
          .style
          ?.padding
          ?.resolve({});
      expect(
        scaled,
        const EdgeInsets.symmetric(horizontal: 23, vertical: 10.35),
      );
    });

    test('SR-P2-66：新学科存色深色下雾化，亮色下原样，预设三科不动', () {
      const stored = Color(0xFF2E7CF6);
      final misted = DesignTokens.subjectColor(
        'chemistry',
        Brightness.dark,
        stored,
      );
      // SR2-55：期望值写算好的字面色，不再用与实现相同的
      // Color.lerp 公式算期望（实现改常量仍会失败，但期望不是
      // 独立字面量就钉不住雾化本身）。
      // 0xFF2E7CF6 向 #DCE3EC 混 45%：(124, 170, 242) = #7CAAF2。
      // 注意：Color.lerp 产出的是带小数通道的 Color（如蓝通道
      // 241.5），与字面量 0xFF7CAAF2（蓝 242）按 Color== 不等；
      // 8 位色值才是对外可见的约定，故断言 toARGB32()。
      expect(misted.toARGB32(), 0xFF7CAAF2);
      expect(misted, isNot(stored));
      expect(
        DesignTokens.subjectColor('chemistry', Brightness.light, stored),
        stored,
      );
      expect(
        DesignTokens.subjectInk(
          'chemistry',
          Brightness.dark,
          stored,
        ).toARGB32(),
        0xFF7CAAF2,
      );
      // 第二个输入色：饱和暖红 0xFFEF4444，雾化结果同样是字面值
      // (230, 140, 144) = #E68C90。
      const warm = Color(0xFFEF4444);
      expect(
        DesignTokens.subjectColor(
          'chemistry',
          Brightness.dark,
          warm,
        ).toARGB32(),
        0xFFE68C90,
      );
      expect(
        DesignTokens.subjectInk('chemistry', Brightness.dark, warm).toARGB32(),
        0xFFE68C90,
      );
      expect(
        DesignTokens.subjectColor('chemistry', Brightness.light, warm),
        warm,
      );
      expect(
        DesignTokens.subjectColor('math', Brightness.dark, stored),
        const Color(0xFF87A9CC),
      );
      expect(
        DesignTokens.subjectInk('math', Brightness.dark, stored),
        const Color(0xFFACC8E2),
      );
    });

    testWidgets('SR2-36：subjectLabelColor 深色下雾化，不再直接返回存色', (tester) async {
      const stored = Color(0xFF2E7CF6);
      Color? dark;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: ThemeMode.dark,
          home: Builder(
            builder: (context) {
              dark = subjectLabelColor(context, 'chemistry', stored);
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pump();
      // 深色下走与 subjectColor 同一雾化（#7CAAF2），不是存色原值。
      // 与 SR-P2-66 同理：Color.lerp 产出带小数通道，断言 8 位色值。
      expect(dark?.toARGB32(), 0xFF7CAAF2);
      Color? light;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) {
              light = subjectLabelColor(context, 'chemistry', stored);
              return const SizedBox();
            },
          ),
        ),
      );
      // 注意：换主题要等 AnimatedTheme 走完（默认 200ms），只 pump
      // 一帧的话 Theme.of 仍是旧的深色主题——上面深色断言恰好不受
      // 影响，亮色这里必须 pumpAndSettle。
      await tester.pumpAndSettle();
      expect(light, stored);
    });
  });

  group('SR-P2-69/70 图片管线', () {
    test('SR-P2-69：canDecodeImageBytes 真图 true、假图 false；'
        '反复裁剪/旋转不因 dispose 坏掉', () async {
      final png = await _pngBytes(w: 40, h: 30);
      expect(await canDecodeImageBytes(png), isTrue);
      expect(
        await canDecodeImageBytes(Uint8List.fromList('not an image'.codeUnits)),
        isFalse,
      );
      final box = QuestionBox(
        id: 'b',
        layer: 1,
        type: 'question',
        x: 0.1,
        y: 0.1,
        w: 0.5,
        h: 0.5,
      );
      for (var i = 0; i < 20; i++) {
        final slice = await cropBoxPng(png, box);
        expect(slice.width, 20);
        expect(slice.height, 15);
        expect(slice.png, isNotEmpty);
        final rotated = await rotateImageBytes(png, 90);
        expect(rotated, isNotEmpty);
      }
    });

    test('SR-P2-70：钳制扣掉溢出侧的宽高', () {
      QuestionBox box(double x, double y, double w, double h) => QuestionBox(
        id: 'b',
        layer: 1,
        type: 'question',
        x: x,
        y: y,
        w: w,
        h: h,
      );
      // 左溢出：x 收到 0，宽扣掉溢出的 0.1（旧实现仍为 0.5）。
      final left = rotateBoxToRotatedPage(box(-0.1, 0.2, 0.5, 0.3), 0);
      expect(left.x, 0.0);
      expect(left.w, closeTo(0.4, 1e-9));
      // 右溢出：宽收到剩余空间。
      final right = rotateBoxToRotatedPage(box(0.8, 0.2, 0.5, 0.3), 0);
      expect(right.x, closeTo(0.8, 1e-9));
      expect(right.w, closeTo(0.2, 1e-9));
      // 上 / 下溢出同理。
      final top = rotateBoxToRotatedPage(box(0.2, -0.1, 0.3, 0.5), 0);
      expect(top.y, 0.0);
      expect(top.h, closeTo(0.4, 1e-9));
      final bottom = rotateBoxToRotatedPage(box(0.2, 0.8, 0.3, 0.5), 0);
      expect(bottom.y, closeTo(0.8, 1e-9));
      expect(bottom.h, closeTo(0.2, 1e-9));
      // 完全在页外：宽高为 0。
      final outside = rotateBoxToRotatedPage(box(-0.5, -0.5, 0.2, 0.2), 0);
      expect(outside.x, 0.0);
      expect(outside.y, 0.0);
      expect(outside.w, 0.0);
      expect(outside.h, 0.0);
      // 旋转后溢出：90° 后 x = 1-0.8-0.4 = -0.2，宽扣到 0.2。
      final rotated = rotateBoxToRotatedPage(box(0.1, 0.8, 0.3, 0.4), 90);
      expect(rotated.x, 0.0);
      expect(rotated.y, closeTo(0.1, 1e-9));
      expect(rotated.w, closeTo(0.2, 1e-9));
      expect(rotated.h, closeTo(0.3, 1e-9));
      // 页内框原样不动。
      final inside = rotateBoxToRotatedPage(box(0.1, 0.2, 0.3, 0.4), 90);
      expect(inside.x, closeTo(0.4, 1e-9));
      expect(inside.y, closeTo(0.1, 1e-9));
      expect(inside.w, closeTo(0.4, 1e-9));
      expect(inside.h, closeTo(0.3, 1e-9));
    });
  });

  group('SR-P2-63/64 UI Kit', () {
    testWidgets('SR-P2-63：QmSegmented 禁用态只有一层 0.45 透明度', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Center(
              child: QmSegmented<String>(
                options: [
                  QmSegmentOption(value: 'a', label: '亮色'),
                  QmSegmentOption(value: 'b', label: '深色'),
                ],
                value: 'a',
                onChanged: null,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 每段一个 _QmPressable 的 Opacity(0.45)；旧实现外层还多包一个。
      final opacities = tester.widgetList<Opacity>(find.byType(Opacity));
      expect(opacities.length, 2);
      expect(opacities.map((o) => o.opacity), everyElement(0.45));
    });

    testWidgets('SR-P2-64：QmChip 双区点按只触发对应回调，各一次', (tester) async {
      var tapped = 0;
      var deleted = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: QmChip(
                label: '自定义错因',
                onTap: () => tapped++,
                onDelete: () => deleted++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义错因'));
      await tester.pump();
      expect(tapped, 1);
      expect(deleted, 0);
      await tester.tap(find.text('×'));
      await tester.pump();
      expect(tapped, 1);
      expect(deleted, 1);
    });

    testWidgets('SR2-35：点左内边距与标签/× 间隙也触发标签回调', (tester) async {
      var tapped = 0;
      var deleted = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: QmChip(
                label: '自定义错因',
                onTap: () => tapped++,
                onDelete: () => deleted++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final chipRect = tester.getRect(find.byType(QmChip));
      final labelRect = tester.getRect(find.text('自定义错因'));
      final crossRect = tester.getRect(find.text('×'));
      // 左内边距（SR2-35 探针点位）：芯片左缘 + 3，归属标签区。
      await tester.tapAt(Offset(chipRect.left + 3, chipRect.center.dy));
      await tester.pump();
      expect(tapped, 1);
      expect(deleted, 0);
      // 标签与 × 之间的间隙中点，归属标签区。
      final gapX = (labelRect.right + crossRect.left) / 2;
      await tester.tapAt(Offset(gapX, chipRect.center.dy));
      await tester.pump();
      expect(tapped, 2);
      expect(deleted, 0);
    });
  });

  group('SR-P2-74/75 切片与放大对话框', () {
    testWidgets('SR-P2-74：cacheWidth 乘 devicePixelRatio', (tester) async {
      // 注意：testWidgets 体内不用异步文件 IO（FakeAsync 下无 pump 时
      // 不完成，会挂起；探针证实），这里用同步 IO。
      final sliceDir = Directory('${_tmp.path}/slices');
      sliceDir.createSync(recursive: true);
      File('${sliceDir.path}/q1.png').writeAsBytesSync(_onePixelPng);
      final q = Question(
        id: 'q1',
        title: '第 1 题',
        subjectId: 'math',
        createdAt: DateTime.now(),
        slicePath: 'slices/q1.png',
        sourcePath: 'slices/q1.png',
      );
      await _pumpDpr(
        tester,
        CompactSliceThumb(question: q),
        devicePixelRatio: 3.0,
      );
      expect(_imageCacheWidth(tester), 384);
      await _pumpDpr(tester, QuestionSlice(question: q), devicePixelRatio: 3.0);
      // maxHeight 默认 160：(160×2)×3 = 960，未到 2048 封顶。
      expect(_imageCacheWidth(tester), 960);
    });

    testWidgets('SR2-63：dpr=1.0 对照，dpr 4.0+ 时 cacheWidth 封顶', (tester) async {
      final sliceDir = Directory('${_tmp.path}/slices');
      sliceDir.createSync(recursive: true);
      File('${sliceDir.path}/q1.png').writeAsBytesSync(_onePixelPng);
      final q = Question(
        id: 'q1',
        title: '第 1 题',
        subjectId: 'math',
        createdAt: DateTime.now(),
        slicePath: 'slices/q1.png',
        sourcePath: 'slices/q1.png',
      );
      // dpr=1.0 基准：Compact 128×1 = 128，QuestionSlice (160×2)×1 = 320。
      await _pumpDpr(
        tester,
        CompactSliceThumb(question: q),
        devicePixelRatio: 1.0,
      );
      expect(_imageCacheWidth(tester), 128);
      await _pumpDpr(tester, QuestionSlice(question: q), devicePixelRatio: 1.0);
      expect(_imageCacheWidth(tester), 320);
      // dpr=4.0：Compact 128×4 = 512 → 封顶 384。
      await _pumpDpr(
        tester,
        CompactSliceThumb(question: q),
        devicePixelRatio: 4.0,
      );
      expect(_imageCacheWidth(tester), 384);
      // dpr=4.0 + maxHeight 480：(480×2)×4 = 3840 → 封顶 2048。
      await _pumpDpr(
        tester,
        QuestionSlice(question: q, maxHeight: 480),
        devicePixelRatio: 4.0,
      );
      expect(_imageCacheWidth(tester), 2048);
    });

    testWidgets('SR-P2-75：放大对话框点 ＋/－ 仍可用', (tester) async {
      // 同上：testWidgets 体内用同步文件 IO。
      final sliceDir = Directory('${_tmp.path}/slices');
      sliceDir.createSync(recursive: true);
      File('${sliceDir.path}/q1.png').writeAsBytesSync(_onePixelPng);
      final q = Question(
        id: 'q1',
        title: '第 1 题',
        subjectId: 'math',
        createdAt: DateTime.now(),
        slicePath: 'slices/q1.png',
        sourcePath: 'slices/q1.png',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showQuestionZoomDialog(context, q),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('打开'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('整题图 · 放大查看'), findsOneWidget);
      // SR2-13：只断言对话框还在钉不住缩放——带 bug 时点 ＋ 会
      // 触发重建、缩放被重置回初始值，对话框本身不会消失。
      // 读 % 徽标：点 ＋ 后变大，点 － 后变小。
      int badgePercent() {
        final text = tester.widget<Text>(
          find.textContaining(RegExp(r'^\d+%$')),
        );
        return int.parse(text.data!.replaceAll('%', ''));
      }

      final initial = badgePercent();
      await tester.tap(find.text('＋'));
      await tester.pump();
      final afterPlus = badgePercent();
      expect(afterPlus, greaterThan(initial));
      await tester.tap(find.text('－'));
      await tester.pump();
      final afterMinus = badgePercent();
      expect(afterMinus, lessThan(afterPlus));
      expect(find.text('整题图 · 放大查看'), findsOneWidget);
    });
  });

  group('SR2-78 readZip 拒绝路径（SR-P2-68 补）', () {
    List<int> validZip() => buildZip([
      const ZipEntryData('backup.json', [0x7B, 0x7D]),
    ]);

    test('ZIP64：中央目录尺寸字段为 0xFFFFFFFF 时拒绝', () {
      final bytes = List<int>.of(validZip());
      final cd = _zipFind(bytes, [0x50, 0x4B, 0x01, 0x02]);
      expect(cd, isNot(-1));
      _zipWriteU32(bytes, cd + 24, 0xFFFFFFFF); // 中央目录 rawSize
      expect(
        () => readZip(bytes),
        throwsA(
          isA<ZipFormatException>().having(
            (e) => e.message,
            'message',
            contains('ZIP64'),
          ),
        ),
      );
    });

    test('多盘：EOCD 盘号非 0 时拒绝', () {
      final bytes = List<int>.of(validZip());
      final eocd = _zipFindLast(bytes, [0x50, 0x4B, 0x05, 0x06]);
      expect(eocd, isNot(-1));
      _zipWriteU16(bytes, eocd + 4, 1); // EOCD disk number
      expect(
        () => readZip(bytes),
        throwsA(
          isA<ZipFormatException>().having(
            (e) => e.message,
            'message',
            contains('多盘'),
          ),
        ),
      );
    });

    test('EOCD 带注释但长度与文件末尾对不上：拒绝', () {
      final bytes = List<int>.of(validZip());
      final eocd = _zipFindLast(bytes, [0x50, 0x4B, 0x05, 0x06]);
      expect(eocd, isNot(-1));
      _zipWriteU16(bytes, eocd + 20, 10); // 注释长 10
      bytes.addAll('abc'.codeUnits); // 实际只补 3 字节
      expect(
        () => readZip(bytes),
        throwsA(
          isA<ZipFormatException>().having(
            (e) => e.message,
            'message',
            contains('找不到中央目录'),
          ),
        ),
      );
    });

    test('EOCD 带格式正确的注释：仍可读（对照）', () {
      final bytes = List<int>.of(validZip());
      final eocd = _zipFindLast(bytes, [0x50, 0x4B, 0x05, 0x06]);
      expect(eocd, isNot(-1));
      _zipWriteU16(bytes, eocd + 20, 5);
      bytes.addAll('hello'.codeUnits);
      final entries = readZip(bytes);
      expect(entries.map((e) => e.name), ['backup.json']);
      expect(entries.first.bytes, [0x7B, 0x7D]);
    });

    test('FR-40 backup.json 重名：拒绝，提示“备份里有两份题目数据”', () {
      final bytes = buildZip([
        const ZipEntryData('backup.json', [0x7B, 0x7D]),
        const ZipEntryData('backup.json', [0x7B, 0x7D]),
      ]);
      expect(
        () => readZip(bytes),
        throwsA(
          isA<ZipFormatException>().having(
            (e) => e.message,
            'message',
            contains('备份里有两份题目数据'),
          ),
        ),
      );
    });

    test('FR-40 对照：其他条目重名仍按“重复条目”拒绝（文案不变）', () {
      final bytes = buildZip([
        const ZipEntryData('slices/a.png', [1]),
        const ZipEntryData('slices/a.png', [2]),
      ]);
      expect(
        () => readZip(bytes),
        throwsA(
          isA<ZipFormatException>().having(
            (e) => e.message,
            'message',
            contains('ZIP 里有重复条目'),
          ),
        ),
      );
    });
  });
}
