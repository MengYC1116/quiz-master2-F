// ARCH-PLAN-B 第 2 阶段：导入崩溃 / 失败清理 / 原图崩溃窗口 / 孤儿保护验收。
//
// 覆盖 plan v9 协议验收段 ②④⑩⑫（文件系统与数据库协同操作协议第 1 条、
// 第 4 条 + B-NEW-15），另加 collect_tasks / question_boxes 类型化
// 转换的回归（UPDATE-first 不改 created_at、草稿保存与重框 round-trip）。
//
// 写法铁律（D-45）：库在测试体内建、直接 await；不用 testWidgets；
// 不用 runAsync 包多段调用。崩溃用“文件库 + close 后重开同一路径”模拟
// 进程退出（内存库 close 即丢数据，模拟不了重启）。只用临时库 +
// 临时目录，不碰真实演示库。
//
// 注意——本文件只验数据层可验证的部分：
// - ②④⑩ 的“重启后收集页展示失败任务 / 可重试”是 UI 层行为，
//   这里验其数据前提：任务行状态不变成 done、原图可定位、引用不悬空；
// - ⑫ 的“恢复定位无文件 / 多候选异常处理（标失败并提示重供原文件）”
//   在导入/重试入口（ImportService / collect_notifier），不在
//   db_collect / db_orphans 里，本文件只验扫描侧“多候选全保护、不挑选”。
// - 协议第 1 条的缺口见文件头注释：ImportService.enqueue 在原图落盘后
//   没有立即持久化 source_path（只在最终 needBox 时才写），且
//   _failAndClean 会删整个任务目录（含原图），与 plan v6 B-NEW-10
//   “只删派生文件、保留原图”不符——缺口在 import_service.dart，
//   不在本 worker 的文件所有权内，见汇报，不在这里改。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/models/models.dart';

CollectTask _task({
  required String id,
  CollectStatus status = CollectStatus.importing,
  String sourcePath = '',
  int progress = 0,
}) => CollectTask(
  id: id,
  name: 'm.pdf · 第1页 · 第1题',
  fileName: 'm.pdf',
  subjectId: 'math',
  status: status,
  progress: progress,
  pageCount: 1,
  page: 1,
  createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
  sourcePath: sourcePath,
);

QuestionBox _box({
  required String id,
  int page = 1,
  double x = 0.1,
  double y = 0.1,
  double w = 0.5,
  double h = 0.3,
}) => QuestionBox(
  id: id,
  layer: 1,
  type: 'question',
  x: x,
  y: y,
  w: w,
  h: h,
  page: page,
);

File _writeFile(Directory tmp, String rel, List<int> bytes) {
  final f = File(p.join(tmp.path, rel))..createSync(recursive: true);
  f.writeAsBytesSync(bytes);
  return f;
}

/// 按 taskId + 固定命名规则定位原始输入文件（plan 第 1 条的唯一口径，
/// 不依赖 source_path 是否已持久化）。返回匹配到的 original.* 文件。
List<File> _locateOriginals(Directory dataDir, String taskId) {
  final dir = Directory(p.join(dataDir.path, 'imports', taskId));
  if (!dir.existsSync()) return const [];
  return dir
      .listSync()
      .whereType<File>()
      .where(
        (f) =>
            p.basename(f.path) == 'original' ||
            p.basename(f.path).startsWith('original.'),
      )
      .toList();
}

void main() {
  group('② 导入中途崩溃：任务行已建、文件未落完', () {
    test('重启后任务仍是 importing，不是 done，可删除清理', () async {
      final tmp = await Directory.systemTemp.createTemp('b2-import-2a-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = p.join(tmp.path, 'quiz-master2.db');

      // 导入开始：先建 importing 任务行（source_path 尚为空），随后崩溃。
      var db = await AppDatabase.openForTest(path: dbPath);
      await AppDatabase.upsertCollectTaskInto(db, _task(id: 'task-crash-2'));
      await db.close(); // 模拟进程退出：无任何清理、无状态改写。

      // 重启：同一文件库重开。
      db = await AppDatabase.openForTest(path: dbPath);
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
      });
      final tasks = await AppDatabase.allCollectTasksFrom(db);
      expect(tasks, hasLength(1));
      expect(tasks.first.id, 'task-crash-2');
      expect(tasks.first.status, CollectStatus.importing);
      expect(tasks.first.status, isNot(CollectStatus.done));
      expect(tasks.first.sourcePath, isEmpty);

      // 可清理：删任务行（删行在前、删目录在后，见协议第 4 条）。
      AppDatabase.testDataDirectory = tmp.path;
      addTearDown(() async {
        await AppDatabase.resetForTest();
      });
      await AppDatabase.deleteCollectTaskFrom(db, 'task-crash-2');
      expect(await AppDatabase.allCollectTasksFrom(db), isEmpty);
      final scan = await AppDatabase.scanOrphanFilesFrom(db, dataDir: tmp.path);
      expect(scan.files, isEmpty);
    });

    test('崩溃前已存的草稿框不丢，重启后可继续修框', () async {
      final tmp = await Directory.systemTemp.createTemp('b2-import-2b-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = p.join(tmp.path, 'quiz-master2.db');

      var db = await AppDatabase.openForTest(path: dbPath);
      await AppDatabase.upsertCollectTaskInto(db, _task(id: 'task-crash-2b'));
      await AppDatabase.saveDraftBoxesInto(
        db,
        taskId: 'task-crash-2b',
        boxesByPage: {
          1: [_box(id: 'box-task-crash-2b-p1-a')],
        },
        rotations: {1: 90},
      );
      await db.close(); // 模拟崩溃：草稿已入库，未落盘后续文件。

      db = await AppDatabase.openForTest(path: dbPath);
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
      });
      final tasks = await AppDatabase.allCollectTasksFrom(db);
      expect(tasks, hasLength(1));
      expect(tasks.first.status, CollectStatus.importing);
      expect(tasks.first.pageRotations, {1: 90});
      final boxes = await AppDatabase.boxesForTaskFrom(db, 'task-crash-2b');
      expect(boxes, hasLength(1));
      expect(boxes.first.id, 'box-task-crash-2b-p1-a');
    });
  });

  group('④ 导入失败后清理', () {
    test('删失败任务：任务行、草稿框与落盘文件都不残留', () async {
      final tmp = await Directory.systemTemp.createTemp('b2-import-4a-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      AppDatabase.testDataDirectory = tmp.path;
      addTearDown(() async {
        await AppDatabase.resetForTest();
      });
      final db = await AppDatabase.openForTest();
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
      });

      await AppDatabase.upsertCollectTaskInto(
        db,
        _task(
          id: 'task-failed-4',
          status: CollectStatus.failed,
          sourcePath: 'imports/task-failed-4/original.jpg',
        ),
      );
      await AppDatabase.saveDraftBoxesInto(
        db,
        taskId: 'task-failed-4',
        boxesByPage: {
          1: [_box(id: 'box-task-failed-4-p1-a')],
        },
        rotations: const {},
      );
      _writeFile(tmp, 'imports/task-failed-4/original.jpg', [1, 2, 3]);
      _writeFile(tmp, 'imports/task-failed-4/pages/page-001.png', [4, 5, 6]);

      await AppDatabase.deleteCollectTaskFrom(db, 'task-failed-4');
      expect(await AppDatabase.allCollectTasksFrom(db), isEmpty);
      expect(await AppDatabase.boxesForTaskFrom(db, 'task-failed-4'), isEmpty);
      expect(
        Directory(p.join(tmp.path, 'imports', 'task-failed-4')).existsSync(),
        isFalse,
      );
      final scan = await AppDatabase.scanOrphanFilesFrom(db, dataDir: tmp.path);
      expect(scan.files, isEmpty);
    });

    test('失败清理后：原图保留且可重试，派生文件已清，无悬空引用', () async {
      final tmp = await Directory.systemTemp.createTemp('b2-import-4b-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final db = await AppDatabase.openForTest();
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
      });

      // 模拟一次按 plan 清理后的失败任务：原图保留、派生文件已删、
      // source_path 仍指向存在的原图（可重试的输入还在）。
      await AppDatabase.upsertCollectTaskInto(
        db,
        _task(
          id: 'task-failed-4b',
          status: CollectStatus.failed,
          sourcePath: 'imports/task-failed-4b/original.jpg',
        ),
      );
      final original = _writeFile(tmp, 'imports/task-failed-4b/original.jpg', [
        1,
        2,
        3,
      ]);
      expect(original.existsSync(), isTrue);

      final tasks = await AppDatabase.allCollectTasksFrom(db);
      expect(tasks.first.status, CollectStatus.failed);
      expect(
        File(p.join(tmp.path, tasks.first.sourcePath)).existsSync(),
        isTrue,
        reason: '失败任务的 source_path 必须指向真实存在的原图，否则无法重试',
      );
      final scan = await AppDatabase.scanOrphanFilesFrom(db, dataDir: tmp.path);
      expect(scan.files, isEmpty);
    });

    test('行已删、目录残留时，残留文件可被孤儿扫描识别', () async {
      final tmp = await Directory.systemTemp.createTemp('b2-import-4c-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final db = await AppDatabase.openForTest();
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
      });

      // 模拟崩溃在“删行成功、删目录前”：行没了，目录还在，无任务行保护。
      _writeFile(tmp, 'imports/gone-task/original.jpg', [1]);
      final scan = await AppDatabase.scanOrphanFilesFrom(db, dataDir: tmp.path);
      expect(scan.files.map((f) => f.relativePath).toList(), [
        'imports/gone-task/original.jpg',
      ]);
    });
  });

  group('⑩ 原图文件崩溃窗口', () {
    test('落盘后、source_path 持久化前崩溃：重启后凭 taskId 找到原图并恢复引用', () async {
      final tmp = await Directory.systemTemp.createTemp('b2-import-10-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dbPath = p.join(tmp.path, 'quiz-master2.db');

      // 导入：先建 importing 行（source_path 为空），原图落盘，随后崩溃
      // ——source_path 的持久化还没发生，这正是 B-NEW-12 的崩溃窗口。
      var db = await AppDatabase.openForTest(path: dbPath);
      await AppDatabase.upsertCollectTaskInto(db, _task(id: 'task-crash-10'));
      _writeFile(tmp, 'imports/task-crash-10/original.jpg', [9, 9, 9]);
      await db.close(); // 模拟崩溃。

      // 重启：任务行还在 importing，source_path 仍为空——没有“已完成”假象。
      db = await AppDatabase.openForTest(path: dbPath);
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
      });
      var tasks = await AppDatabase.allCollectTasksFrom(db);
      expect(tasks, hasLength(1));
      expect(tasks.first.status, CollectStatus.importing);
      expect(tasks.first.sourcePath, isEmpty);

      // 恢复：凭 taskId + 固定命名规则唯一定位原图（不依赖 source_path）。
      final located = _locateOriginals(tmp, 'task-crash-10');
      expect(located, hasLength(1));
      expect(located.first.existsSync(), isTrue);

      // 恢复后把 source_path 持久化：引用重新指向真实存在的文件。
      await AppDatabase.upsertCollectTaskInto(
        db,
        _task(
          id: 'task-crash-10',
          status: CollectStatus.failed,
          sourcePath: 'imports/task-crash-10/original.jpg',
        ),
      );
      tasks = await AppDatabase.allCollectTasksFrom(db);
      expect(tasks.first.sourcePath, 'imports/task-crash-10/original.jpg');
      expect(
        File(p.join(tmp.path, tasks.first.sourcePath)).existsSync(),
        isTrue,
      );
      final scan = await AppDatabase.scanOrphanFilesFrom(db, dataDir: tmp.path);
      expect(scan.files, isEmpty);
    });
  });

  group('⑫ 孤儿扫描保护 imports/<taskId>/original.*', () {
    test('有任务行、source_path 为空时，original.* 不被列为孤儿', () async {
      final tmp = await Directory.systemTemp.createTemp('b2-import-12a-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final db = await AppDatabase.openForTest();
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
      });

      await AppDatabase.upsertCollectTaskInto(db, _task(id: 'task-12a'));
      _writeFile(tmp, 'imports/task-12a/original.jpg', [1]);
      _writeFile(tmp, 'imports/task-12a/page-normalized.png', [2]);
      _writeFile(tmp, 'imports/task-12a/pages/page-001.png', [3]);
      // 任务目录里的杂文件：仍是孤儿，不受保护。
      _writeFile(tmp, 'imports/task-12a/extra.png', [4]);

      final scan = await AppDatabase.scanOrphanFilesFrom(db, dataDir: tmp.path);
      expect(scan.files.map((f) => f.relativePath).toList(), [
        'imports/task-12a/extra.png',
      ]);
    });

    test('无任务行时，original.* 是孤儿', () async {
      final tmp = await Directory.systemTemp.createTemp('b2-import-12b-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final db = await AppDatabase.openForTest();
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
      });

      _writeFile(tmp, 'imports/gone-task/original.jpg', [1]);
      final scan = await AppDatabase.scanOrphanFilesFrom(db, dataDir: tmp.path);
      expect(scan.files.map((f) => f.relativePath).toList(), [
        'imports/gone-task/original.jpg',
      ]);
    });

    test('多个 original.* 候选全保护，扫描不挑选、不删除', () async {
      final tmp = await Directory.systemTemp.createTemp('b2-import-12c-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final db = await AppDatabase.openForTest();
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
      });

      await AppDatabase.upsertCollectTaskInto(db, _task(id: 'task-12c'));
      _writeFile(tmp, 'imports/task-12c/original.jpg', [1]);
      _writeFile(tmp, 'imports/task-12c/original.pdf', [2]);

      final scan = await AppDatabase.scanOrphanFilesFrom(db, dataDir: tmp.path);
      expect(scan.files, isEmpty);
      // 扫描是只读的：两个候选都在磁盘上，一个没少。
      expect(
        File(p.join(tmp.path, 'imports/task-12c/original.jpg')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(tmp.path, 'imports/task-12c/original.pdf')).existsSync(),
        isTrue,
      );
    });
  });

  group('类型化转换回归', () {
    test('upsert UPDATE-first：进度更新不改 created_at 与列表顺序', () async {
      final db = await AppDatabase.openForTest();
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
      });

      final first = _task(id: 'task-ord-1');
      final second = _task(id: 'task-ord-2');
      await AppDatabase.upsertCollectTaskInto(db, first);
      await AppDatabase.upsertCollectTaskInto(db, second);
      // 高频进度更新：只 UPDATE，不碰 created_at。
      await AppDatabase.upsertCollectTaskInto(
        db,
        _task(id: 'task-ord-1', progress: 70),
      );
      final tasks = await AppDatabase.allCollectTasksFrom(db);
      // 同毫秒建的任务按 rowid 兜底：后建的在前；UPDATE 不改 rowid，
      // 进度更新后顺序不动。
      expect(tasks.map((t) => t.id).toList(), ['task-ord-2', 'task-ord-1']);
      expect(tasks.last.progress, 70);
      expect(tasks.last.createdAt?.millisecondsSinceEpoch, 1700000000000);
    });

    test('question_boxes：插框 / 按页读 / 重框 round-trip', () async {
      final db = await AppDatabase.openForTest();
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
      });

      await AppDatabase.insertQuestionBoxInto(
        db,
        _box(id: 'box-q1', x: 0.2, y: 0.2, w: 0.4, h: 0.2).copyWith(
          questionId: 'q-1',
          confidence: 0.9,
          origin: 'yolo',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000001000),
        ),
      );
      final byQuestion = await AppDatabase.boxesForQuestionFrom(db, 'q-1');
      expect(byQuestion, hasLength(1));
      expect(byQuestion.first.confidence, 0.9);
      expect(byQuestion.first.origin, 'yolo');
      expect(byQuestion.first.updatedAt?.millisecondsSinceEpoch, 1700000001000);

      // 重框：旧框删掉、新框插上（INSERT OR REPLACE 同口径）。
      await AppDatabase.replaceQuestionBoxesInto(db, 'q-1', [
        _box(id: 'box-q1-new', x: 0.1, y: 0.1, w: 0.5, h: 0.3),
      ]);
      final after = await AppDatabase.boxesForQuestionFrom(db, 'q-1');
      expect(after.map((b) => b.id).toList(), ['box-q1-new']);
      expect(after.first.collectTaskId, isNull);
    });
  });
}
