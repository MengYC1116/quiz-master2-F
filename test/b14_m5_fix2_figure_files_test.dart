// 十四批 M5 修复轮 2（GPT fix1 窄审 §3.1）：图块正式路径唯一性（问题 A）
// 与清理失败区分（问题 B）的测试。
//
// 问题 A：figureCropFileName() 旧实现只含时间戳+随机数，不含图块 ID；
// 同一毫秒 + 随机数巧合撞上时 rename 会静默覆盖。修法：文件名含稳定
// 图块 ID + rename 前目标已存在则重算，绝不覆盖旧文件。
// 问题 B：deleteFileLocked() 返回 false 时不区分“不存在”与“删失败”；
// 修法：figure_files 内先判存在再认结果，删失败保留登记、可重试。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/file_lifecycle_guard.dart';
import 'package:quiz_master2/modules/ocr/figure_files.dart';
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';

const _transform = OcrRequestTransform(
  srcW: 100,
  srcH: 50,
  reqW: 100,
  reqH: 50,
  padX: 0,
  padY: 0,
);

OcrFigure figure(String id, SrcRect rect) => OcrFigure(
  id: id,
  slicePath: 'slices/q1.png',
  inputHash: 'h1',
  sequenceIndex: 0,
  anchorSource: 'fallback',
  anchorRef: '',
  bbox2d: const [10, 5, 60, 25],
  spaceWidth: 100,
  spaceHeight: 50,
  transform: _transform,
  srcRect: rect,
  cropPath: '',
);

/// 100×50 双色切片：左半红、右半蓝——不同区域裁出的 PNG 字节必然不同。
Uint8List twoToneSliceBytes() {
  final image = img.Image(width: 100, height: 50);
  for (var y = 0; y < 50; y++) {
    for (var x = 0; x < 100; x++) {
      if (x < 50) {
        image.setPixelRgb(x, y, 200, 30, 40);
      } else {
        image.setPixelRgb(x, y, 30, 60, 200);
      }
    }
  }
  return img.encodePng(image);
}

void main() {
  late Directory dataDir;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('b14_m5_fix2_figures_');
    FileLifecycleGuard.instance.debugClearPendingForTest();
    FileLifecycleGuard.instance.debugClearStagingForTest();
  });

  tearDown(() {
    FileLifecycleGuard.instance.debugClearPendingForTest();
    FileLifecycleGuard.instance.debugClearStagingForTest();
    try {
      dataDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('问题 A：正式路径唯一、不可覆盖', () {
    test('figureCropFileName：同参不同 figureId 路径不同；同 figureId 确定', () {
      final a = figureCropFileName(
        'q1',
        figureId: 'figure-q1-0',
        timestampMs: 123,
        random: 456,
      );
      final b = figureCropFileName(
        'q1',
        figureId: 'figure-q1-1',
        timestampMs: 123,
        random: 456,
      );
      expect(a, isNot(b), reason: '同一题两张图块即使同毫秒同随机数也不能同路径');
      expect(a, contains('figure-q1-0'));
      expect(b, contains('figure-q1-1'));
      expect(
        figureCropFileName(
          'q1',
          figureId: 'figure-q1-0',
          timestampMs: 123,
          random: 456,
        ),
        a,
      );
      // 不传 figureId 保持旧形状（兼容）。
      expect(
        figureCropFileName('q1', timestampMs: 123, random: 456),
        'slices/q1-fig-v123-456.png',
      );
    });

    test('同一题两张图块：路径不同、文件都在、内容不同', () async {
      final guard = FileLifecycleGuard.instance;
      final written = await writeFigureFiles(
        dataDir: dataDir.path,
        questionId: 'q1',
        sliceBytes: twoToneSliceBytes(),
        figures: [
          figure('figure-q1-0', const SrcRect(x: 5, y: 5, width: 20, height: 20)),
          figure('figure-q1-1', const SrcRect(x: 75, y: 5, width: 20, height: 20)),
        ],
      );
      expect(written.figures.length, 2);
      final cropA = written.figures[0].cropPath;
      final cropB = written.figures[1].cropPath;
      expect(cropA, isNot(cropB));
      expect(cropA, contains('figure-q1-0'));
      expect(cropB, contains('figure-q1-1'));
      final bytesA = await File(p.join(dataDir.path, cropA)).readAsBytes();
      final bytesB = await File(p.join(dataDir.path, cropB)).readAsBytes();
      expect(bytesA, isNot(bytesB), reason: '左红右蓝两个区域裁出的内容不同');
      expect(guard.pendingSnapshot, containsAll([cropA, cropB]));
      commitFigureFiles(written.registeredPaths);
      expect(guard.pendingSnapshot, isEmpty);
    });

    test('替换失败后旧图块文件仍完整', () async {
      final guard = FileLifecycleGuard.instance;
      // v1：写并提交（模拟已入库的旧图块）。
      final v1 = await writeFigureFiles(
        dataDir: dataDir.path,
        questionId: 'q1',
        sliceBytes: twoToneSliceBytes(),
        figures: [
          figure('figure-q1-0', const SrcRect(x: 5, y: 5, width: 20, height: 20)),
        ],
      );
      final oldRel = v1.figures.single.cropPath;
      final oldAbs = p.join(dataDir.path, oldRel);
      final oldBytes = await File(oldAbs).readAsBytes();
      commitFigureFiles(v1.registeredPaths);
      // v2：同一图块 ID、不同区域（重识别替换），随后模拟数据库事务失败回滚。
      final v2 = await writeFigureFiles(
        dataDir: dataDir.path,
        questionId: 'q1',
        sliceBytes: twoToneSliceBytes(),
        figures: [
          figure('figure-q1-0', const SrcRect(x: 75, y: 5, width: 20, height: 20)),
        ],
      );
      final newRel = v2.figures.single.cropPath;
      expect(newRel, isNot(oldRel), reason: '新文件不得复用旧记录正在引用的路径');
      expect(File(p.join(dataDir.path, newRel)).existsSync(), isTrue);
      final failed = await rollbackFigureFiles(
        v2.registeredPaths,
        dataDir: dataDir.path,
      );
      expect(failed, isEmpty);
      expect(File(p.join(dataDir.path, newRel)).existsSync(), isFalse);
      // 旧文件字节级完整。
      expect(await File(oldAbs).readAsBytes(), oldBytes);
      expect(guard.pendingSnapshot, isEmpty);
    });
  });

  group('问题 B：区分“不存在”与“删除失败”', () {
    test('回滚不存在的文件：视为清理完成、解除登记、失败列表为空', () async {
      final guard = FileLifecycleGuard.instance;
      const missing = 'slices/q1-fig-missing.png';
      guard.registerPending(missing);
      final failed = await rollbackFigureFiles(
        [missing],
        dataDir: dataDir.path,
      );
      expect(failed, isEmpty);
      expect(guard.isPending(missing), isFalse);
    });

    test('回滚删除失败：文件仍在、登记保留；清除障碍后重试成功', () async {
      final guard = FileLifecycleGuard.instance;
      final written = await writeFigureFiles(
        dataDir: dataDir.path,
        questionId: 'q1',
        sliceBytes: twoToneSliceBytes(),
        figures: [
          figure('figure-q1-0', const SrcRect(x: 5, y: 5, width: 20, height: 20)),
        ],
      );
      final rel = written.figures.single.cropPath;
      final abs = p.join(dataDir.path, rel);
      expect(File(abs).existsSync(), isTrue);
      // 故障注入：把裁图文件替换成同路径目录——File.delete() 对目录
      // 确定性失败（不用 chmod：测试以 root 跑，部分环境 root 能绕过只读目录）。
      File(abs).deleteSync();
      Directory(abs).createSync();
      final failed = await rollbackFigureFiles(
        [rel],
        dataDir: dataDir.path,
      );
      expect(failed, [rel]);
      expect(guard.isPending(rel), isTrue, reason: '删失败必须保留登记');
      expect(Directory(abs).existsSync(), isTrue);
      // 清除障碍后重试：登记解除。
      Directory(abs).deleteSync();
      final failed2 = await rollbackFigureFiles(
        [rel],
        dataDir: dataDir.path,
      );
      expect(failed2, isEmpty);
      expect(guard.isPending(rel), isFalse);
    });

    test('写批次失败清理：删不掉的已写文件保留登记', () async {
      final guard = FileLifecycleGuard.instance;
      var hookCalls = 0;
      String? figAFinalRel;
      await expectLater(
        writeFigureFiles(
          dataDir: dataDir.path,
          questionId: 'q1',
          sliceBytes: twoToneSliceBytes(),
          figures: [
            figure(
              'figure-q1-0',
              const SrcRect(x: 5, y: 5, width: 20, height: 20),
            ),
            figure(
              'figure-q1-1',
              const SrcRect(x: 75, y: 5, width: 20, height: 20),
            ),
          ],
          beforeRename: () async {
            hookCalls++;
            if (hookCalls == 1) {
              // 记下第一张图块的正式路径（非 .tmp 的登记项）。
              figAFinalRel = guard.pendingSnapshot.firstWhere(
                (r) => !r.endsWith('.tmp'),
              );
            } else {
              // 挡住第一张已写好的文件：删文件、原路径上建目录，
              // 使整批失败清理删它时失败；再删第二张图的临时文件，
              // 使它的 rename 失败，触发整批清理。
              final abs = p.join(dataDir.path, figAFinalRel!);
              File(abs).deleteSync();
              Directory(abs).createSync();
              final tmp = guard.pendingSnapshot.firstWhere(
                (r) => r.endsWith('.tmp'),
              );
              await File(p.join(dataDir.path, tmp)).delete();
            }
          },
        ),
        throwsA(isA<FigureWriteException>()),
      );
      expect(hookCalls, 2);
      expect(
        guard.isPending(figAFinalRel!),
        isTrue,
        reason: '失败清理删不掉的文件必须保留登记，不得当成已清理',
      );
      expect(
        Directory(p.join(dataDir.path, figAFinalRel!)).existsSync(),
        isTrue,
      );
      // 清除障碍后重试回滚：登记解除。
      Directory(p.join(dataDir.path, figAFinalRel!)).deleteSync();
      final failed = await rollbackFigureFiles(
        [figAFinalRel!],
        dataDir: dataDir.path,
      );
      expect(failed, isEmpty);
      expect(guard.isPending(figAFinalRel!), isFalse);
    });
  });
}
