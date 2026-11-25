// B11-2：批量队列状态模型 + 内容哈希去重（ImportService
// .checkContentDuplicates）测试。内存库 + 临时数据目录，不碰真实库。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/collect/batch_import.dart';
import 'package:quiz_master2/services/import_guess.dart';
import 'package:quiz_master2/services/import_service.dart';

import 'test_fixtures.dart';

void main() {
  group('BatchImportState', () {
    BatchImportState state() => BatchImportState(
      subjectId: 'math',
      files: [
        BatchImportFile(path: '/tmp/a.jpg', name: 'a.jpg'),
        BatchImportFile(path: '/tmp/b.jpg', name: 'b.jpg', guessedExam: '期中考试'),
        BatchImportFile(path: '/tmp/c.jpg', name: 'c.jpg'),
      ],
    );

    test('初始全是排队中，未完成、无失败', () {
      final s = state();
      expect(s.total, 3);
      expect(s.doneCount, 0);
      expect(s.failedCount, 0);
      expect(s.isFinished, isFalse);
      expect(s.hasFailures, isFalse);
      expect(s.failedPaths, isEmpty);
      expect(s.summary, '已完成 0 / 3');
    });

    test('逐行标记：完成 / 失败计数与 summary', () {
      final s = state();
      s.markImporting(0);
      expect(s.files[0].status, BatchFileStatus.importing);
      s.markProgress(0, 42);
      expect(s.files[0].progress, 42);
      s.markDone(0);
      expect(s.files[0].progress, 100);
      s.markFailed(1, '这张图片打不开');
      expect(s.files[1].error, '这张图片打不开');
      expect(s.doneCount, 1);
      expect(s.failedCount, 1);
      expect(s.isFinished, isFalse);
      expect(s.summary, '已完成 1 / 3 · 1 个失败');
      expect(s.failedPaths, ['/tmp/b.jpg']);
      s.markDone(2);
      expect(s.isFinished, isTrue);
      expect(s.hasFailures, isTrue);
    });

    test('resetForRetry 把失败行打回排队中', () {
      final s = state();
      s.markFailed(1, '这张图片打不开');
      s.resetForRetry(1);
      expect(s.files[1].status, BatchFileStatus.queued);
      expect(s.files[1].progress, 0);
      expect(s.files[1].error, isNull);
      expect(s.failedCount, 0);
    });

    test('indexOfPath 找不到返回 -1', () {
      expect(state().indexOfPath('/tmp/nope.jpg'), -1);
    });
  });

  group('ImportService.checkContentDuplicates', () {
    late final Directory tmp;
    late final String photoA; // 数学错题.jpg（照片固件）
    late final String photoB; // 数学错题-副本.jpg（同内容，不同名）
    late final String photoC; // 英语作业.jpg（不同内容）
    late List<CollectTask> imported;

    ImportService service() => ImportService(AppDatabase.instance);

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('qm2-b11-batch');
      AppDatabase.testDataDirectory = tmp.path;
      final db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      photoA = (await writeFixtureFile(
        tmp,
        '数学错题.jpg',
        photoFixtureBytes(),
      )).path;
      photoB = (await writeFixtureFile(
        tmp,
        '数学错题-副本.jpg',
        photoFixtureBytes(),
      )).path;
      photoC = (await writeFixtureFile(
        tmp,
        '英语作业.jpg',
        exifFixtureBytes(3),
      )).path;
      // 先导一份 A 进库（needBox），作为“已入库”的对照。
      imported = await service().enqueue([photoA], subjectId: 'math');
      expect(imported.length, 1);
      expect(imported.first.status, CollectStatus.needBox);
    });

    tearDownAll(() async {
      await AppDatabase.resetForTest();
      // Windows 上删目录时可能仍有句柄未释放（errno 32）：重试 5 次。
      for (var i = 0; i < 5; i++) {
        try {
          await tmp.delete(recursive: true);
          break;
        } catch (_) {
          if (i == 4) break;
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }
    });

    test('已入库原文件的哈希等于源文件内容的哈希', () async {
      final hashes = await service().contentHashesForTasks(imported);
      expect(hashes[imported.first.id], sha256HexOfBytes(photoFixtureBytes()));
    });

    test('同内容不同名 → 库内重复；不同内容 → 不重复', () async {
      final result = await service().checkContentDuplicates([
        photoB,
        photoC,
      ], imported);
      expect(result.libraryDuplicates, ['数学错题-副本.jpg']);
      expect(result.withinBatchDropped, isEmpty);
    });

    test('同批内后出现的相同内容 → 丢掉后一份', () async {
      final result = await service().checkContentDuplicates([
        photoA,
        photoB,
      ], []);
      expect(result.libraryDuplicates, isEmpty);
      expect(result.withinBatchDropped, [photoB]);
    });

    test('原文件缺失的任务跳过，不抛错、不误判', () async {
      final ghost = CollectTask(
        id: 'task-ghost',
        name: '不存在.jpg · 第1页 · 第1题',
        fileName: '不存在.jpg',
        subjectId: 'math',
        status: CollectStatus.needBox,
        sourcePath: 'imports/nope/original.jpg',
      );
      final hashes = await service().contentHashesForTasks([
        ghost,
        ...imported,
      ]);
      expect(hashes.containsKey('task-ghost'), isFalse);
      expect(hashes.containsKey(imported.first.id), isTrue);
    });
  });
}
