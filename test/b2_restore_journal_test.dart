// ARCH-PLAN-B 第 2 阶段：恢复日志模块测试。
//
// 覆盖 plan v9 的 ⑪（日志原子替换中断，Linux）和 ⑭（三状态故障注入 /
// 启动恢复 / 临时损坏丢弃 / 首次创建），另加校验单测与 fsync 失败不阻断。
//
// 写法铁律（D-45）：播种在测试体内做；只用普通 test（真实异步区），
// 不用 testWidgets，不用 runAsync 包多段调用。kill 测试用 Process.start
// 启动一个由本测试在临时目录内生成的纯 Dart worker 脚本（只 import
// dart:io / dart:convert 与 package:quiz_master2/data/restore_journal.dart，
// 不 import flutter_test，故可用 plain dart 运行），半途 SIGKILL。
// worker 脚本是测试运行时生成的临时文件，不进仓库。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/journal_ffi.dart';
import 'package:quiz_master2/data/restore_journal.dart';

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

RestoreJournal _journal({
  required Directory dir,
  String taskId = 'task-1',
  RestoreStage stage = RestoreStage.preparing,
  RestoreStatus status = RestoreStatus.inProgress,
}) => RestoreJournal(
  taskId: taskId,
  rollbackDir: p.join(dir.path, 'imports-rollback', 'r1'),
  stagingDir: p.join(dir.path, 'restore-staging', 's1'),
  snapshotPath: p.join(dir.path, 'quiz-master2.db.snapshot'),
  stage: stage,
  status: status,
);

Future<Directory> _tempDir() => Directory.systemTemp.createTemp('b2-journal-');

/// 计数型 fake 替换函数：按脚本返回错误码；可附带每次调用时的磁盘动作。
class _FakeReplace {
  _FakeReplace(this.script, {this.onCall});

  /// 每次调用返回的错误码；多于脚本长度时重复最后一个。
  final List<int> script;
  final void Function(int callIndex, RestoreJournalStore store)? onCall;
  int calls = 0;
  RestoreJournalStore? _store;

  Future<int> call({
    required String target,
    required String replacement,
    required String backup,
  }) async {
    final index = calls;
    calls++;
    onCall?.call(index, _store!);
    final code = script[index < script.length ? index : script.length - 1];
    if (code == 0) {
      // 模拟一次“真实成功”的替换：临时文件确实安装为正式日志。
      final tmp = File(replacement);
      if (await tmp.exists()) await tmp.rename(target);
    }
    return code;
  }
}

/// 建一个挂了 fake 替换的 store，并把 fake 绑定到该 store（供 onCall 回调用）。
({RestoreJournalStore store, _FakeReplace fake}) _storeWithFake(
  Directory dir,
  List<int> script, {
  void Function(int callIndex, RestoreJournalStore store)? onCall,
}) {
  late final _FakeReplace fake;
  late final RestoreJournalStore store;
  fake = _FakeReplace(script, onCall: onCall);
  store = RestoreJournalStore(
    dataDir: dir,
    replaceFile: ({
      required String target,
      required String replacement,
      required String backup,
    }) => fake.call(target: target, replacement: replacement, backup: backup),
  );
  fake._store = store;
  return (store: store, fake: fake);
}

Future<void> _writeRaw(File file, String text) async {
  await file.parent.create(recursive: true);
  await file.writeAsString(text);
}

/// 读正式日志并校验；损坏即抛 JournalCorruptException。
Future<RestoreJournal> _readFormal(RestoreJournalStore store) =>
    store.validateFile(store.formalFile);

void main() {
  late Directory dir;
  late RestoreJournalStore store;

  setUp(() async {
    dir = await _tempDir();
    store = RestoreJournalStore(dataDir: dir);
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  group('校验：checksum / 必填字段 / formatVersion', () {
    test('正常日志 round-trip：toJson/fromJson 一致，校验和稳定', () {
      final j = _journal(dir: dir, stage: RestoreStage.snapshotReady);
      final again = RestoreJournal.fromJson(
        jsonDecode(j.toCanonicalJson()) as Map<String, dynamic>,
      );
      expect(again.taskId, 'task-1');
      expect(again.stage, RestoreStage.snapshotReady);
      expect(again.checksum, j.checksum);
      expect(again.toCanonicalJson(), j.toCanonicalJson());
    });

    test('改一个字节即判损坏', () {
      final j = _journal(dir: dir);
      final text = j.toCanonicalJson().replaceFirst('task-1', 'task-2');
      expect(
        () => RestoreJournal.fromJson(jsonDecode(text) as Map<String, dynamic>),
        throwsA(isA<JournalCorruptException>()),
      );
    });

    test('formatVersion 不匹配判损坏', () {
      final map = _journal(dir: dir).toJson()..['formatVersion'] = 99;
      expect(
        () => RestoreJournal.fromJson(map),
        throwsA(isA<JournalCorruptException>()),
      );
    });

    test('必填字段缺失判损坏（taskId / snapshotPath / checksum 各一例）', () {
      for (final key in ['taskId', 'snapshotPath', 'checksum']) {
        final map = _journal(dir: dir).toJson()..remove(key);
        expect(
          () => RestoreJournal.fromJson(map),
          throwsA(isA<JournalCorruptException>()),
          reason: '缺 $key 应判损坏',
        );
      }
      final emptyTask = _journal(dir: dir).toJson()..['taskId'] = '';
      expect(
        () => RestoreJournal.fromJson(emptyTask),
        throwsA(isA<JournalCorruptException>()),
        reason: 'taskId 空串应判损坏',
      );
    });

    test('stage / status 非法值判损坏', () {
      final badStage = _journal(dir: dir).toJson()..['stage'] = 'NOPE';
      expect(
        () => RestoreJournal.fromJson(badStage),
        throwsA(isA<JournalCorruptException>()),
      );
      final badStatus = _journal(dir: dir).toJson()..['status'] = 'NOPE';
      expect(
        () => RestoreJournal.fromJson(badStatus),
        throwsA(isA<JournalCorruptException>()),
      );
    });

    test('JSON 解析失败判损坏（半截 JSON）', () async {
      await _writeRaw(store.formalFile, '{"formatVersion":1,"taskId":"ta');
      await expectLater(
        store.validateFile(store.formalFile),
        throwsA(isA<JournalCorruptException>()),
      );
    });
  });

  group('首次创建 writeInitial', () {
    test('正式日志不存在时用 rename 安装：正式有效，tmp 消失，无备份', () async {
      final written = await store.writeInitial(_journal(dir: dir));
      expect(written.taskId, 'task-1');
      expect(await store.formalFile.exists(), isTrue);
      expect(await store.tmpFile.exists(), isFalse);
      expect(await store.backupFile.exists(), isFalse);
      expect((await _readFormal(store)).checksum, written.checksum);
    });

    test('正式日志已存在时拒绝首次创建（须走 updateStage）', () async {
      await store.writeInitial(_journal(dir: dir));
      await expectLater(
        store.writeInitial(_journal(dir: dir, taskId: 'task-2')),
        throwsA(isA<JournalUpdateException>()),
      );
      expect((await _readFormal(store)).taskId, 'task-1');
    });

    test('残留的损坏 tmp 不阻断首次创建（丢弃后重写）', () async {
      await _writeRaw(store.tmpFile, 'not json{{{');
      final written = await store.writeInitial(_journal(dir: dir));
      expect((await _readFormal(store)).checksum, written.checksum);
      expect(await store.tmpFile.exists(), isFalse);
    });
  });

  group('五步原子更新 updateStage', () {
    test('正常更新：正式变新版，tmp 消失；备份只在 Windows 出现', () async {
      final v1 = await store.writeInitial(_journal(dir: dir));
      final v2 = await store.updateStage(
        _journal(dir: dir, stage: RestoreStage.snapshotReady),
      );
      expect(v2.stage, RestoreStage.snapshotReady);
      expect((await _readFormal(store)).checksum, v2.checksum);
      expect(await store.tmpFile.exists(), isFalse);
      // Linux 用 rename(2) 原子替换，不产生备份文件；Windows 的
      // ReplaceFileW 每次调用都传备份路径，旧日志会留在 .bak 里。
      if (Platform.isWindows) {
        final backup = await store.validateFile(store.backupFile);
        expect(backup.checksum, v1.checksum);
        expect(backup.stage, RestoreStage.preparing);
      } else {
        expect(await store.backupFile.exists(), isFalse);
      }
    });

    test('父目录 fsync 失败不阻断日志更新（注入 fsync 返回错误码 5）', () async {
      await store.writeInitial(_journal(dir: dir));
      final noFsync = RestoreJournalStore(dataDir: dir, fsyncParent: (_) => 5);
      final v2 = await noFsync.updateStage(
        _journal(dir: dir, stage: RestoreStage.snapshotReady),
      );
      expect(v2.stage, RestoreStage.snapshotReady);
      expect((await _readFormal(store)).checksum, v2.checksum);
    });

    test('父目录 fsync 抛异常也不阻断日志更新', () async {
      await store.writeInitial(_journal(dir: dir));
      final throwingFsync = RestoreJournalStore(
        dataDir: dir,
        fsyncParent: (_) => throw StateError('FFI load failed'),
      );
      final v2 = await throwingFsync.updateStage(
        _journal(dir: dir, stage: RestoreStage.filesSwitching),
      );
      expect(v2.stage, RestoreStage.filesSwitching);
    });

    test('替换返回 0 但文件根本没动：不得谎称成功，须抛错且原日志保留', () async {
      await store.writeInitial(_journal(dir: dir));
      // fake 只返回 0 但什么都不做（复现 Win11 实测“错误码 0 但文件没动”）。
      final lying = RestoreJournalStore(
        dataDir: dir,
        replaceFile: ({
          required target,
          required replacement,
          required backup,
        }) async => 0,
      );
      await expectLater(
        lying.updateStage(
          _journal(dir: dir, stage: RestoreStage.snapshotReady),
        ),
        throwsA(isA<JournalUpdateException>()),
      );
      expect((await _readFormal(store)).stage, RestoreStage.preparing);
    });
  });

  group('⑭ 三状态故障注入（B-NEW-17）', () {
    test('1175：正式仍在 + 临时有效 → 重试一次，仍失败则中止、原日志保留', () async {
      final v1 = await store.writeInitial(_journal(dir: dir));
      final injected = _storeWithFake(dir, [1175, 1175]);
      store = injected.store;
      final fake = injected.fake;
      await expectLater(
        store.updateStage(
          _journal(dir: dir, stage: RestoreStage.snapshotReady),
        ),
        throwsA(isA<JournalUpdateException>()),
      );
      // 只重试一次：首次 + 重试 = 2 次调用。
      expect(fake.calls, 2);
      expect((await _readFormal(store)).checksum, v1.checksum);
    });

    test('1175 重试成功：正式变新版', () async {
      await store.writeInitial(_journal(dir: dir));
      // 第一次返回 1175（不动磁盘），第二次真的执行替换并返回 0。
      final injected = _storeWithFake(dir, [1175, 0]);
      store = injected.store;
      final fake = injected.fake;
      final v2 = await store.updateStage(
        _journal(dir: dir, stage: RestoreStage.snapshotReady),
      );
      expect(fake.calls, 2);
      expect(v2.stage, RestoreStage.snapshotReady);
      expect((await _readFormal(store)).checksum, v2.checksum);
    });

    test('1175 且临时已损坏：丢弃临时、保留原日志', () async {
      final v1 = await store.writeInitial(_journal(dir: dir));
      // fake 在调用时把 tmp 写坏，再返回 1175。
      final injected = _storeWithFake(
        dir,
        [1175],
        onCall: (index, s) {
          if (index == 0) {
            s.tmpFile.writeAsStringSync('garbage{{{');
          }
        },
      );
      store = injected.store;
      final fake = injected.fake;
      await expectLater(
        store.updateStage(
          _journal(dir: dir, stage: RestoreStage.snapshotReady),
        ),
        throwsA(isA<JournalUpdateException>()),
      );
      expect(fake.calls, 1, reason: '临时已损坏，不应重试');
      expect(await store.tmpFile.exists(), isFalse);
      expect((await _readFormal(store)).checksum, v1.checksum);
    });

    test('1176 按磁盘状态分派（a）：原日志仍在正式路径 → 按 1175 处理', () async {
      final v1 = await store.writeInitial(_journal(dir: dir));
      final injected = _storeWithFake(dir, [1176, 1176]);
      store = injected.store;
      final fake = injected.fake;
      await expectLater(
        store.updateStage(
          _journal(dir: dir, stage: RestoreStage.snapshotReady),
        ),
        throwsA(isA<JournalUpdateException>()),
      );
      expect(fake.calls, 2, reason: '按 1175 处理：重试一次');
      expect((await _readFormal(store)).checksum, v1.checksum);
    });

    test('1176 按磁盘状态分派（b）：原日志在备份位置 → 按 1177 处理', () async {
      // 预摆 1177 布局：正式缺失、备份有完整原日志、临时待写入。
      final v1 = _journal(dir: dir);
      await _writeRaw(store.backupFile, v1.toCanonicalJson());
      final injected = _storeWithFake(dir, [1176]);
      store = injected.store;
      final fake = injected.fake;
      final v2 = await store.updateStage(
        _journal(dir: dir, stage: RestoreStage.snapshotReady),
      );
      expect(fake.calls, 1, reason: '按 1177 处理：不重试，直接安装临时日志');
      expect(v2.stage, RestoreStage.snapshotReady);
      expect((await _readFormal(store)).checksum, v2.checksum);
      // 备份位置的原日志保留。
      expect(
        (await store.validateFile(store.backupFile)).checksum,
        v1.checksum,
      );
    });

    test('1177：正式缺失 + 备份原日志 + 临时有效 → 安装临时为正式，备份保留', () async {
      final v1 = _journal(dir: dir);
      await _writeRaw(store.backupFile, v1.toCanonicalJson());
      final injected = _storeWithFake(dir, [1177]);
      store = injected.store;
      final fake = injected.fake;
      final v2 = await store.updateStage(
        _journal(dir: dir, stage: RestoreStage.filesSwitching),
      );
      expect(fake.calls, 1);
      expect(v2.stage, RestoreStage.filesSwitching);
      expect((await _readFormal(store)).checksum, v2.checksum);
      expect(
        (await store.validateFile(store.backupFile)).checksum,
        v1.checksum,
      );
    });

    test('1177 且临时损坏：丢弃临时、从备份恢复原日志并校验', () async {
      final v1 = _journal(dir: dir);
      await _writeRaw(store.backupFile, v1.toCanonicalJson());
      final injected = _storeWithFake(
        dir,
        [1177],
        onCall: (index, s) {
          if (index == 0) {
            s.tmpFile.writeAsStringSync('{{{broken');
          }
        },
      );
      store = injected.store;
      final fake = injected.fake;
      await expectLater(
        store.updateStage(
          _journal(dir: dir, stage: RestoreStage.filesSwitching),
        ),
        throwsA(isA<JournalUpdateException>()),
      );
      expect(fake.calls, 1);
      expect(await store.tmpFile.exists(), isFalse);
      // 原日志已从备份恢复到正式路径（备份文件本身被移走）。
      expect((await _readFormal(store)).checksum, v1.checksum);
      expect(await store.backupFile.exists(), isFalse);
    });
  });

  group('⑭ 启动恢复 locateAndRecover', () {
    test('三处均无日志：返回 null（无进行中的恢复，正常启动）', () async {
      expect(await store.locateAndRecover(), isNull);
    });

    test('正式日志缺失但备份有完整原日志：从备份恢复到正式路径并校验', () async {
      final v1 = _journal(dir: dir, stage: RestoreStage.snapshotReady);
      await _writeRaw(store.backupFile, v1.toCanonicalJson());
      final recovered = await store.locateAndRecover();
      expect(recovered, isNotNull);
      expect(recovered!.checksum, v1.checksum);
      expect((await _readFormal(store)).checksum, v1.checksum);
    });

    test('正式缺失 + 备份原日志 + 临时新日志有效：安装临时为正式，备份保留', () async {
      final v1 = _journal(dir: dir, stage: RestoreStage.preparing);
      final v2 = _journal(dir: dir, stage: RestoreStage.snapshotReady);
      await _writeRaw(store.backupFile, v1.toCanonicalJson());
      await _writeRaw(store.tmpFile, v2.toCanonicalJson());
      final recovered = await store.locateAndRecover();
      expect(recovered, isNotNull);
      expect(recovered!.checksum, v2.checksum);
      expect((await _readFormal(store)).checksum, v2.checksum);
      expect(
        (await store.validateFile(store.backupFile)).checksum,
        v1.checksum,
      );
    });

    test('正式缺失 + 临时新日志有效（无备份）：安装临时为正式', () async {
      final v2 = _journal(dir: dir, stage: RestoreStage.snapshotReady);
      await _writeRaw(store.tmpFile, v2.toCanonicalJson());
      final recovered = await store.locateAndRecover();
      expect(recovered, isNotNull);
      expect(recovered!.checksum, v2.checksum);
      expect((await _readFormal(store)).checksum, v2.checksum);
    });

    test('临时新日志损坏：丢弃临时、保留原日志（正式在）', () async {
      final v1 = await store.writeInitial(_journal(dir: dir));
      await _writeRaw(store.tmpFile, '{{{broken');
      final recovered = await store.locateAndRecover();
      expect(recovered, isNotNull);
      expect(recovered!.checksum, v1.checksum);
      expect(await store.tmpFile.exists(), isFalse);
      expect((await _readFormal(store)).checksum, v1.checksum);
    });

    test('临时新日志损坏 + 正式缺失 + 备份有原日志：丢弃临时、从备份恢复', () async {
      final v1 = _journal(dir: dir, stage: RestoreStage.preparing);
      await _writeRaw(store.backupFile, v1.toCanonicalJson());
      await _writeRaw(store.tmpFile, '{{{broken');
      final recovered = await store.locateAndRecover();
      expect(recovered, isNotNull);
      expect(recovered!.checksum, v1.checksum);
      expect(await store.tmpFile.exists(), isFalse);
      expect((await _readFormal(store)).checksum, v1.checksum);
    });

    test('临时损坏且无备份可恢复：抛 JournalCorruptException，不得继续', () async {
      await _writeRaw(store.tmpFile, '{{{broken');
      await expectLater(
        store.locateAndRecover(),
        throwsA(isA<JournalCorruptException>()),
      );
    });

    test('正式日志损坏：抛 JournalCorruptException，不得静默用备份', () async {
      await _writeRaw(store.formalFile, '{"formatVersion":1,"taskId":');
      final v1 = _journal(dir: dir);
      await _writeRaw(store.backupFile, v1.toCanonicalJson());
      await expectLater(
        store.locateAndRecover(),
        throwsA(isA<JournalCorruptException>()),
      );
      // 现场保留：损坏的正式日志与备份都在。
      expect(await store.formalFile.exists(), isTrue);
      expect(await store.backupFile.exists(), isTrue);
    });

    test('启动恢复幂等：重复调用结果一致', () async {
      final v1 = _journal(dir: dir, stage: RestoreStage.filesSwitching);
      await _writeRaw(store.backupFile, v1.toCanonicalJson());
      final first = await store.locateAndRecover();
      final second = await store.locateAndRecover();
      expect(first!.checksum, v1.checksum);
      expect(second!.checksum, v1.checksum);
    });
  });

  group('journal_ffi（Linux 真实路径）', () {
    test('atomicReplaceFile：Linux 上 rename 原子替换，成功返回 0', () async {
      final target = File(p.join(dir.path, 'a.json'));
      final replacement = File(p.join(dir.path, 'a.json.tmp'));
      await target.writeAsString('old');
      await replacement.writeAsString('new');
      final code = await atomicReplaceFile(
        target: target.path,
        replacement: replacement.path,
        backup: p.join(dir.path, 'a.json.bak'),
      );
      expect(code, 0);
      expect(await target.readAsString(), 'new');
      expect(await replacement.exists(), isFalse);
    });

    test('atomicReplaceFile：替换文件不存在时返回非 0', () async {
      final code = await atomicReplaceFile(
        target: p.join(dir.path, 'a.json'),
        replacement: p.join(dir.path, 'missing.tmp'),
        backup: p.join(dir.path, 'a.json.bak'),
      );
      expect(code, isNot(0));
    });

    test('fsyncParentDir：Linux 真实目录返回 null（成功）', () {
      expect(fsyncParentDir(dir), isNull);
    });
  });

  group('⑪ 日志原子替换中断（Linux，子进程 SIGKILL）', () {
    test('循环更新中杀掉：重启后正式日志非旧即新、内容完整、无半截 JSON', () async {
      final workerDir = await _tempDir();
      addTearDown(() async {
        try {
          await workerDir.delete(recursive: true);
        } catch (_) {}
      });
      final proc = await _startWorker(workerDir, 'loop');
      try {
        final reached = await _waitForLine(
          proc,
          (line) => line.startsWith('VERSION='),
          atLeast: 50,
        );
        expect(reached, isTrue, reason: 'worker 未跑到 VERSION=50');
        proc.kill(ProcessSignal.sigkill);
        await proc.exitCode.timeout(const Duration(seconds: 10));
        final formal = File(p.join(workerDir.path, restoreJournalFileName));
        expect(await formal.exists(), isTrue, reason: '日志不得缺失');
        // 内容完整：JSON 可解析、校验和通过、任务号单调可辨。
        final journal = await store.validateFile(formal);
        expect(journal.taskId, matches(RegExp(r'^kill-loop-\d+$')));
        final v = int.parse(journal.taskId.substring('kill-loop-'.length));
        expect(v, greaterThanOrEqualTo(50));
        // 启动恢复同样认出这份有效日志。
        final recovered = await RestoreJournalStore(dataDir: workerDir)
            .locateAndRecover();
        expect(recovered!.checksum, journal.checksum);
      } finally {
        _killQuietly(proc);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('临时已写、替换尚未完成时杀掉：正式日志仍为旧版且完整', () async {
      final workerDir = await _tempDir();
      addTearDown(() async {
        try {
          await workerDir.delete(recursive: true);
        } catch (_) {}
      });
      final proc = await _startWorker(workerDir, 'write-tmp-only');
      try {
        final written = await _waitForLine(
          proc,
          (line) => line == 'TMP_WRITTEN',
          atLeast: 1,
        );
        expect(written, isTrue, reason: 'worker 未写好 tmp');
        proc.kill(ProcessSignal.sigkill);
        await proc.exitCode.timeout(const Duration(seconds: 10));
        final store2 = RestoreJournalStore(dataDir: workerDir);
        final formal = await _readFormal(store2);
        expect(formal.taskId, 'kill-loop-7');
        // 启动恢复：正式仍是旧版，残留 tmp 被丢弃。
        final recovered = await store2.locateAndRecover();
        expect(recovered!.taskId, 'kill-loop-7');
        expect(await store2.tmpFile.exists(), isFalse);
      } finally {
        _killQuietly(proc);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}

// ---------------------------------------------------------------------------
// kill 测试的 worker 生成与进程管理
// ---------------------------------------------------------------------------

const String _workerSource = r'''
import 'dart:io';
import 'package:quiz_master2/data/restore_journal.dart';

RestoreJournal _journalFor(Directory dir, int v) => RestoreJournal(
      taskId: 'kill-loop-$v',
      rollbackDir: '${dir.path}/imports-rollback/r1',
      stagingDir: '${dir.path}/restore-staging/s1',
      snapshotPath: '${dir.path}/quiz-master2.db.snapshot',
      stage: RestoreStage.values[v % RestoreStage.values.length],
      status: RestoreStatus.inProgress,
    );

Future<void> main(List<String> args) async {
  final dir = Directory(args[0]);
  final mode = args[1];
  final store = RestoreJournalStore(dataDir: dir);
  if (mode == 'write-tmp-only') {
    await store.writeInitial(_journalFor(dir, 7));
    await store.writeTemp(_journalFor(dir, 999));
    stdout.writeln('TMP_WRITTEN');
    await stdout.flush();
    await Future.delayed(const Duration(seconds: 60));
    return;
  }
  await store.writeInitial(_journalFor(dir, 0));
  var v = 0;
  while (true) {
    v++;
    await store.updateStage(_journalFor(dir, v));
    if (v % 50 == 0) {
      stdout.writeln('VERSION=$v');
      await stdout.flush();
    }
    await Future.delayed(const Duration(milliseconds: 1));
  }
}
''';

/// 仓库根目录：flutter test 的工作目录即包根；否则从测试文件路径推导。
String _repoRoot() {
  final cwd = Directory.current;
  if (File(p.join(cwd.path, 'pubspec.yaml')).existsSync()) {
    return cwd.path;
  }
  final script = Platform.script;
  if (script.isScheme('file')) {
    final testFile = File.fromUri(script);
    final testDir = testFile.parent;
    if (p.basename(testDir.path) == 'test') return testDir.parent.path;
  }
  return cwd.path;
}

String _dartExecutable() {
  final candidates = <String>[
    if (Platform.environment['FLUTTER_ROOT'] != null)
      p.join(Platform.environment['FLUTTER_ROOT']!, 'bin', 'dart'),
    if (Platform.environment['HOME'] != null)
      p.join(
        Platform.environment['HOME']!,
        'workspace',
        'flutter-install',
        'flutter',
        'bin',
        'dart',
      ),
    'dart',
  ];
  for (final c in candidates) {
    if (c == 'dart') return c;
    if (File(c).existsSync()) return c;
  }
  return 'dart';
}

Future<Process> _startWorker(Directory workerDir, String mode) async {
  final repoRoot = _repoRoot();
  final workerFile = File(p.join(workerDir.path, 'journal_worker.dart'));
  await workerFile.writeAsString(_workerSource);
  final packageConfig = p.join(repoRoot, '.dart_tool', 'package_config.json');
  final dartExe = _dartExecutable();
  final proc = await Process.start(dartExe, [
    '--packages=$packageConfig',
    workerFile.path,
    workerDir.path,
    mode,
  ]);
  // worker 的 stderr 先接住，避免管道阻塞；失败时测试里能看到。
  proc.stderr.transform(const SystemEncoding().decoder).listen((_) {});
  return proc;
}

/// 等待 worker 输出满足 [matches] 的行至少 [atLeast] 次（VERSION 行是
/// 累计输出，atLeast 指解析出的最大版本号；TMP_WRITTEN 只需 1 次）。
/// 超时 60 秒返回 false。
Future<bool> _waitForLine(
  Process proc,
  bool Function(String line) matches, {
  required int atLeast,
}) async {
  final completer = Completer<bool>();
  var best = 0;
  late final StreamSubscription<String> sub;
  sub = proc.stdout
      .transform(const SystemEncoding().decoder)
      .transform(const LineSplitter())
      .listen((line) {
        if (!matches(line)) return;
        if (line.startsWith('VERSION=')) {
          best = int.tryParse(line.substring('VERSION='.length)) ?? best;
          if (best >= atLeast && !completer.isCompleted) {
            completer.complete(true);
          }
        } else if (!completer.isCompleted) {
          completer.complete(true);
        }
      });
  try {
    return await completer.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () => false,
    );
  } finally {
    await sub.cancel();
  }
}

void _killQuietly(Process proc) {
  try {
    proc.kill(ProcessSignal.sigkill);
  } catch (_) {}
}
