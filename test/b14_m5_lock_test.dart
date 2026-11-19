// 十四批 M5 P1-1：文件锁并发排队修复（GPT 关口审第 1 节）。
// 原实现 withLock 在 _locked 为 true 时直接抛 StateError，独立任务
// 根本到不了 _acquire() 的 _waiters 队列；修法：Zone 标记持锁调用链，
// 同一调用链重入才抛错，独立任务排队等前一个释放。
// 集成测试（真实库 + 真实文件系统）；只测锁本身，不碰 M1–M4 行为。
import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/file_lifecycle_guard.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';

void main() {
  late QuizDatabase db;
  late Directory dataDir;
  late QuestionRepository repo;

  Future<String> writeSlice(String name) async {
    final rel = 'slices/$name.png';
    final abs = p.join(dataDir.path, rel);
    await File(abs).parent.create(recursive: true);
    await File(abs).writeAsBytes([1, 2, 3]);
    return rel;
  }

  Future<Question> insertQuestion({
    required String id,
    String? slicePath,
  }) async {
    final q = Question(
      id: id,
      title: '题 $id',
      subjectId: 'math',
      createdAt: DateTime(2026, 11, 18),
      slicePath: slicePath,
    );
    await AppDatabase.upsertQuestionInto(db, q);
    return q;
  }

  setUp(() async {
    db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(db);
    repo = QuestionRepository(AppDatabase.instance);
    dataDir = Directory(AppDatabase.dataDirectoryPath());
    await dataDir.create(recursive: true);
    FileLifecycleGuard.instance.debugClearPendingForTest();
    FileLifecycleGuard.instance.debugClearStagingForTest();
  });

  tearDown(() async {
    FileLifecycleGuard.instance.debugClearPendingForTest();
    FileLifecycleGuard.instance.debugClearStagingForTest();
  });

  group('M5 P1-1 文件锁：独立任务排队、同一调用链重入才抛错', () {
    test('1 A 持锁时 B 调 withLock：B 等待，不抛异常', () async {
      final guard = FileLifecycleGuard.instance;
      final releaseA = Completer<void>();
      final aFuture = guard.withLock(() => releaseA.future);
      expect(guard.isLocked, isTrue);
      var bDone = false;
      final bFuture = guard.withLock(() async {
        bDone = true;
        return 'b';
      });
      // 给 B 留出到达锁的时间：若 B 抛错或抢到锁，这里就能看出来。
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bDone, isFalse);
      expect(guard.isLocked, isTrue);
      releaseA.complete();
      await expectLater(bFuture, completion('b'));
      expect(bDone, isTrue);
      await aFuture;
      expect(guard.isLocked, isFalse);
    });

    test('2 A 释放后，B 成功获得锁', () async {
      final guard = FileLifecycleGuard.instance;
      final releaseA = Completer<void>();
      final aFuture = guard.withLock(() => releaseA.future);
      final bFuture = guard.withLock(() async => 'b');
      releaseA.complete();
      await aFuture;
      expect(await bFuture, 'b');
      expect(guard.isLocked, isFalse);
    });

    test('3 A 持锁时，A 的内部调用链再次申请锁：抛 StateError', () async {
      final guard = FileLifecycleGuard.instance;
      await guard.withLock(() async {
        // await 之后仍在同一调用链：Zone 随异步调用链传播，
        // 重入必须仍被识别出来。
        await Future<void>.delayed(Duration.zero);
        await expectLater(guard.withLock(() async {}), throwsStateError);
        // 同步直接再调同样抛错。
        expect(() => guard.withLock(() async {}), throwsStateError);
      });
      expect(guard.isLocked, isFalse);
    });

    test('4 A 的 action 抛异常时锁仍释放、B 能获得锁', () async {
      final guard = FileLifecycleGuard.instance;
      await expectLater(
        guard.withLock(() async {
          throw Exception('测试注入：A 失败');
        }),
        throwsException,
      );
      expect(guard.isLocked, isFalse);
      expect(await guard.withLock(() async => 42), 42);
      expect(guard.isLocked, isFalse);
    });

    test('5 三个真实入口并发到达：备份、孤儿清理、物理删除按锁顺序串行执行，不因竞争抛非重入异常',
        () async {
      final guard = FileLifecycleGuard.instance;
      await insertQuestion(id: 'q1', slicePath: await writeSlice('q1'));
      final q2 = await insertQuestion(id: 'q2', slicePath: await writeSlice('q2'));
      const orphanRel = 'slices/orphan.png';
      await File(p.join(dataDir.path, orphanRel)).writeAsBytes([9]);
      final q1SliceAbs = p.join(dataDir.path, 'slices/q1.png');
      final q2SliceAbs = p.join(dataDir.path, 'slices/q2.png');

      // 先由测试人工持锁，制造三入口同时到达排队的确定性窗口：
      // 三个真实入口的 withLock 调用都发生在锁被占用期间。
      final releaseHolder = Completer<void>();
      final holderFuture = guard.withLock(() => releaseHolder.future);
      expect(guard.isLocked, isTrue);

      var backupDone = false;
      var orphanDone = false;
      var deleteDone = false;
      final backupFuture = AppDatabase.exportBackupZipFromWithReport(
        db,
        dataDir: dataDir.path,
      ).then((r) {
        backupDone = true;
        return r;
      });
      final orphanFuture = deleteOrphanFilesImpl([orphanRel], db: db).then((r) {
        orphanDone = true;
        return r;
      });
      final deleteFuture = repo.delete(q2).then((_) {
        deleteDone = true;
      });

      // 给三入口留出到达锁的时间（备份先做导出 JSON、删题先做删记录事务）。
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(guard.isLocked, isTrue);
      expect(backupDone, isFalse);
      expect(orphanDone, isFalse);
      expect(deleteDone, isFalse);

      // 放锁：三入口按等待队列顺序依次获得锁、串行执行。
      // 任一入口抛非重入 StateError 时这里的 await 即失败。
      releaseHolder.complete();
      await holderFuture;
      final report = await backupFuture;
      final orphanResult = await orphanFuture;
      await deleteFuture;

      expect(report.warnings, isEmpty);
      final archive = ZipDecoder().decodeBytes(report.bytes);
      expect(archive.files.map((f) => f.name), contains('slices/q1.png'));
      expect(orphanResult.deletedCount, 1);
      expect(File(p.join(dataDir.path, orphanRel)).existsSync(), isFalse);
      expect(File(q2SliceAbs).existsSync(), isFalse);
      expect(await repo.questionById('q2'), isNull);
      expect(File(q1SliceAbs).existsSync(), isTrue);
      expect(guard.isLocked, isFalse);
    });
  });
}
