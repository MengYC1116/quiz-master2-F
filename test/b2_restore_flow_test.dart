// ARCH-PLAN-B 第 2 阶段：备份恢复流程测试（W-restore）。
//
// 覆盖 plan v9 协议验收段的 ①③⑤⑥⑦⑧⑨：
// ① 恢复中途失败能回滚到旧库（旧数据完整）；
// ③ 恢复中断后重启能自动恢复（日志非 COMMITTED 时启动钩子回滚）；
// ⑤ 快照互斥：真实阻碍 TRUNCATE 的活动读事务（checkpoint 第一列为 1，
//    恢复等待或拒绝；不得用空闲连接代替）；
// ⑥ 日志原子替换中断（恢复流程层面：临时已写、替换未完成时重启，
//    日志推进不丢；journal 层本身的覆盖见 b2_restore_journal_test.dart）；
// ⑦ 日志先于快照写入（PREPARING 日志落盘发生在任何正式文件改动之前）；
// ⑧ 快照就绪后再中断，恢复仍能回到旧库；
// ⑨ 幂等重启（恢复完成后再次启动，不重复执行恢复、数据不变）。
//
// ⑬ 故障保证范围（B-NEW-16）：本文件的测试只按进程强制终止验收
// （SIGKILL / 异常退出模拟——此处用“手动摆出中断现场 + 启动钩子”
// 模拟崩溃后的磁盘状态，不跑真杀进程；真杀进程的日志中断覆盖见
// b2_restore_journal_test.dart 的 ⑪），不要写断电场景测试。
// 本协议不承诺突然断电后的完整回滚。
//
// 写法铁律（D-45）：建库在测试体内做 + 直接 await；openForTest 已发
// SELECT 1 强制建连；只用普通 test（真实异步区），不用 testWidgets；
// 轮询用 Future.delayed，不用 runAsync 包多段调用。
// 测试用临时测试库 + 临时目录，不碰真实演示库。

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/restore_journal.dart';
import 'package:quiz_master2/services/zip_archive.dart';

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

Future<Directory> _tempDir(String prefix) =>
    Directory.systemTemp.createTemp(prefix);

Future<void> _seedSubject(QuizDatabase db, String id, String name) async {
  await db.customInsert(
    'INSERT INTO subjects (id, name, color, cover_style, cover_color) '
    'VALUES (?, ?, ?, ?, ?)',
    variables: [
      Variable.withString(id),
      Variable.withString(name),
      Variable.withInt(0xFF2E7CF6),
      Variable.withString('plain'),
      Variable.withString('blue'),
    ],
  );
}

Future<void> _seedQuestion(
  QuizDatabase db, {
  required String id,
  required String title,
  String slicePath = 'slices/q1.png',
  String sourcePath = 'imports/task-1/original.jpg',
}) async {
  await db.customInsert(
    'INSERT INTO questions (id, title, subject_id, folder_ids, '
    'knowledge_ids, error_types, custom_error_types, tags, created_at, '
    'slice_kind, slice_text, source_path, source_kind, source_page, '
    'page_image_path, slice_path, is_demo) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    variables: [
      Variable.withString(id),
      Variable.withString(title),
      Variable.withString('math'),
      Variable.withString('[]'),
      Variable.withString('[]'),
      Variable.withString('[]'),
      Variable.withString('[]'),
      Variable.withString('[]'),
      Variable.withInt(1700000000000),
      Variable.withString('material'),
      Variable.withString(''),
      Variable(sourcePath),
      Variable.withString('image'),
      Variable.withInt(1),
      Variable(sourcePath),
      Variable(slicePath),
      Variable.withInt(0),
    ],
  );
}

Future<File> _writeDataFile(
  Directory dataDir,
  String rel,
  List<int> bytes,
) async {
  final f = File(p.join(dataDir.path, rel));
  await f.parent.create(recursive: true);
  return f.writeAsBytes(bytes);
}

/// 旧状态：文件库（dataDir/quiz-master2.db）+ q-old（“旧题”）+
/// slices/q1.png=[1,1,1] + imports/task-1/original.jpg=[2,2,2]。
/// 调用方负责在 tearDown 里关库、删目录。
Future<({Directory dir, QuizDatabase db, String dbPath})>
_makeOldState() async {
  final dir = await _tempDir('b2-restore-old-');
  final dbPath = p.join(dir.path, 'quiz-master2.db');
  final db = await AppDatabase.openForTest(path: dbPath);
  await _seedSubject(db, 'math', '数学');
  await _seedQuestion(db, id: 'q-old', title: '旧题');
  await _writeDataFile(dir, 'slices/q1.png', [1, 1, 1]);
  await _writeDataFile(dir, 'imports/task-1/original.jpg', [2, 2, 2]);
  return (dir: dir, db: db, dbPath: dbPath);
}

/// 新备份 zip：另一份临时库里的 q-new（“新题”）+ 新文件
/// slices/q1.png=[9,9,9] + imports/task-1/original.jpg=[8,8,8]。
Future<List<int>> _makeNewZip() async {
  final dir2 = await _tempDir('b2-restore-new-');
  try {
    final db2 = await AppDatabase.openForTest(
      path: p.join(dir2.path, 'quiz-master2.db'),
    );
    try {
      await _seedSubject(db2, 'math', '数学');
      await _seedQuestion(db2, id: 'q-new', title: '新题');
      await _writeDataFile(dir2, 'slices/q1.png', [9, 9, 9]);
      await _writeDataFile(dir2, 'imports/task-1/original.jpg', [8, 8, 8]);
      return await AppDatabase.exportBackupZipFrom(db2, dataDir: dir2.path);
    } finally {
      await db2.close();
    }
  } finally {
    try {
      await dir2.delete(recursive: true);
    } catch (_) {}
  }
}

/// 新备份 zip，但 backup.json 里 q-new 行多个表里没有的列：
/// 校验放行（必填列齐全），入库时才报“没有这列”——模拟“切换完成、
/// 写库阶段才失败”的中途失败。
Future<List<int>> _makeDbFailingZip() async {
  final zip = await _makeNewZip();
  final entries = readZip(zip).map((e) {
    if (e.name != 'backup.json') return e;
    final data = jsonDecode(utf8.decode(e.bytes)) as Map<String, dynamic>;
    (data['questions'] as List).first['bogus_col'] = 'x';
    return ZipEntryData(e.name, utf8.encode(jsonEncode(data)));
  }).toList();
  return buildZip(entries);
}

Future<Map<String, String>> _questionTitles(QuizDatabase db) async {
  final rows = await db.customSelect('SELECT id, title FROM questions').get();
  return {
    for (final r in rows) r.data['id'] as String: r.data['title'] as String,
  };
}

List<int>? _readBytes(Directory dir, String rel) {
  final f = File(p.join(dir.path, rel));
  if (!f.existsSync()) return null;
  return f.readAsBytesSync();
}

/// 本次恢复的残留材料（日志三处 + staging / rollback / 快照）。
/// 成功或回滚完成后应为空。
List<String> _leftoverRestoreMaterials(Directory dir) {
  final found = <String>[];
  for (final name in [
    'restore-journal.json',
    'restore-journal.json.bak',
    'restore-journal.json.tmp',
  ]) {
    if (File(p.join(dir.path, name)).existsSync()) found.add(name);
  }
  for (final name in ['restore-staging', 'imports-rollback']) {
    if (Directory(p.join(dir.path, name)).existsSync()) found.add(name);
  }
  for (final e in dir.listSync()) {
    if (e is File && p.basename(e.path).startsWith('.restore-snapshot-')) {
      found.add(p.basename(e.path));
    }
  }
  return found;
}

/// 轮询到条件成立（真实异步区，直接 await Future.delayed）。
Future<bool> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  Duration interval = const Duration(milliseconds: 50),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await Future.delayed(interval);
  }
  return condition();
}

/// 切 WAL 并写一帧 WAL 数据（探针行）：wal_checkpoint(TRUNCATE) 只有
/// 在 WAL 里有未 checkpoint 的帧时才会被活动读事务挡住（空 WAL 时
/// busy 恒为 0，见尖峰后实测）；测试先写一帧，再开阻碍连接。
/// 等待路径的恢复成功后整库被覆盖，探针行随之消失；拒绝路径里多一行
/// settings，不影响断言（不断言 settings 表）。
Future<void> _enableWalWithFrame(QuizDatabase db) async {
  final modeRows = await db.customSelect('PRAGMA journal_mode=WAL').get();
  expect(modeRows.first.data.values.first, 'wal');
  await db.customInsert(
    "INSERT INTO settings (key, value) VALUES ('__b2_wal_probe__', '1')",
  );
}

/// 走真实启动链（_openDb：删老库 → 启动恢复钩子 → 开库）。
/// 每次调用前先复位单例（关上次打开的库、清测试目录重定向）。
Future<QuizDatabase> _runStartup(String dirPath) async {
  await AppDatabase.resetForTest();
  AppDatabase.testDataDirectory = dirPath;
  return AppDatabase.instance.db;
}

/// 手动摆出“切换中途崩溃”的磁盘现场（模拟进程强制终止后留下的状态，
/// 不跑真杀进程）：快照是旧库的拷贝；原文件已移到 rollback 目录；
/// 正式位置是新文件；staging 有残留；日志停在 FILES_SWITCHING。
Future<void> _stageFilesSwitchingCrash(
  Directory dir,
  String dbPath, {
  required String taskId,
}) async {
  final snapshotPath = p.join(dir.path, '.restore-snapshot-$taskId.db');
  await File(dbPath).copy(snapshotPath);
  final rollbackDir = Directory(p.join(dir.path, 'imports-rollback', taskId));
  for (final rel in ['slices/q1.png', 'imports/task-1/original.jpg']) {
    final formal = File(p.join(dir.path, rel));
    final backup = File(p.join(rollbackDir.path, rel));
    await backup.parent.create(recursive: true);
    await formal.rename(backup.path);
  }
  await File(p.join(rollbackDir.path, 'manifest.json')).writeAsString(
    jsonEncode({
      'version': 1,
      'files': [
        {'rel': 'slices/q1.png', 'hadOriginal': true},
        {'rel': 'imports/task-1/original.jpg', 'hadOriginal': true},
      ],
    }),
    flush: true,
  );
  await _writeDataFile(dir, 'slices/q1.png', [9, 9, 9]);
  await _writeDataFile(dir, 'imports/task-1/original.jpg', [8, 8, 8]);
  final stagingDir = Directory(p.join(dir.path, 'restore-staging', taskId));
  await _writeDataFile(
    dir,
    p.join('restore-staging', taskId, 'slices', 'q1.png'),
    [9, 9, 9],
  );
  final store = RestoreJournalStore(dataDir: dir);
  await store.writeInitial(
    RestoreJournal(
      taskId: taskId,
      rollbackDir: rollbackDir.path,
      stagingDir: stagingDir.path,
      snapshotPath: snapshotPath,
      stage: RestoreStage.filesSwitching,
      status: RestoreStatus.inProgress,
    ),
  );
}

void main() {
  test('① 恢复中途失败（写库阶段）能回滚到旧库，旧数据完整', () async {
    final old = await _makeOldState();
    addTearDown(() async {
      try {
        await old.db.close();
      } catch (_) {}
      try {
        await old.dir.delete(recursive: true);
      } catch (_) {}
      await AppDatabase.resetForTest();
    });
    final badZip = await _makeDbFailingZip();
    await expectLater(
      () => AppDatabase.importBackupZipInto(
        old.db,
        badZip,
        dataDir: old.dir.path,
      ),
      throwsA(isA<BackupRestoreException>()),
    );
    // 旧库原样：行还在、标题还是旧的。
    expect(await _questionTitles(old.db), {'q-old': '旧题'});
    // 旧文件原样：已装进来的新文件被移回旧内容。
    expect(_readBytes(old.dir, 'slices/q1.png'), [1, 1, 1]);
    expect(_readBytes(old.dir, 'imports/task-1/original.jpg'), [2, 2, 2]);
    // 无残留：日志 / staging / rollback / 快照全清掉。
    expect(_leftoverRestoreMaterials(old.dir), isEmpty);
    expect(AppDatabase.inRestoreMaintenance, isFalse);
  });

  test('③ 恢复中断（FILES_SWITCHING）后重启能自动恢复到旧库', () async {
    final old = await _makeOldState();
    addTearDown(() async {
      await AppDatabase.resetForTest();
      try {
        await old.dir.delete(recursive: true);
      } catch (_) {}
    });
    // 关掉测试连接再摆崩溃现场、再走启动链（启动钩子换库文件时
    // 不能有已打开的连接）。
    await old.db.close();
    await _stageFilesSwitchingCrash(old.dir, old.dbPath, taskId: 'crash-3');
    // 崩溃现场确认：正式位置已是新文件。
    expect(_readBytes(old.dir, 'slices/q1.png'), [9, 9, 9]);
    final reopened = await _runStartup(old.dir.path);
    expect(await _questionTitles(reopened), {'q-old': '旧题'});
    expect(_readBytes(old.dir, 'slices/q1.png'), [1, 1, 1]);
    expect(_readBytes(old.dir, 'imports/task-1/original.jpg'), [2, 2, 2]);
    expect(_leftoverRestoreMaterials(old.dir), isEmpty);
  });

  test('⑤ 快照互斥：活动读事务阻碍 TRUNCATE 时恢复等待，释放后继续', () async {
    final old = await _makeOldState();
    QuizDatabase? blocker;
    addTearDown(() async {
      try {
        await blocker?.close();
      } catch (_) {}
      try {
        await old.db.close();
      } catch (_) {}
      try {
        await old.dir.delete(recursive: true);
      } catch (_) {}
      await AppDatabase.resetForTest();
    });
    // 先切 WAL 并写一帧 WAL 数据，再开阻碍连接（见 [_enableWalWithFrame]）。
    await _enableWalWithFrame(old.db);
    // 另一连接保持一个真实阻碍 TRUNCATE 完成的活动读事务。
    blocker = QuizDatabase.file(File(old.dbPath));
    await blocker.customSelect('SELECT 1').get();
    await blocker.customStatement('BEGIN');
    await blocker.customSelect('SELECT * FROM questions').get();
    final zip = await _makeNewZip();
    final importFuture = AppDatabase.importBackupZipInto(
      old.db,
      zip,
      dataDir: old.dir.path,
    );
    // 恢复被 checkpoint 挡住期间：日志已是 PREPARING、正式文件没动、
    // 快照还没拷、维护状态已进（业务取连接被拒绝）。
    final journalSeen = await _waitUntil(
      () => File(p.join(old.dir.path, 'restore-journal.json')).existsSync(),
    );
    expect(journalSeen, isTrue, reason: '恢复被挡住时日志应已落盘');
    final store = RestoreJournalStore(dataDir: old.dir);
    final journal = await store.validateFile(store.formalFile);
    expect(journal.stage, RestoreStage.preparing);
    expect(_readBytes(old.dir, 'slices/q1.png'), [1, 1, 1]);
    expect(
      old.dir.listSync().where(
        (e) => p.basename(e.path).startsWith('.restore-snapshot-'),
      ),
      isEmpty,
      reason: 'checkpoint 被挡住时不得复制主库文件',
    );
    expect(AppDatabase.inRestoreMaintenance, isTrue);
    expect(
      () => AppDatabase.instance.db,
      throwsStateError,
      reason: '维护状态下业务取连接必须被拒绝',
    );
    // 释放阻碍：重试的 checkpoint 成功，恢复继续走完。
    await blocker.customStatement('ROLLBACK');
    await blocker.close();
    blocker = null;
    await importFuture;
    expect(await _questionTitles(old.db), {'q-new': '新题'});
    expect(_readBytes(old.dir, 'slices/q1.png'), [9, 9, 9]);
    expect(_leftoverRestoreMaterials(old.dir), isEmpty);
    expect(AppDatabase.inRestoreMaintenance, isFalse);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('⑤ 快照互斥：活动读事务一直不释放时恢复拒绝，原库不动', () async {
    final old = await _makeOldState();
    QuizDatabase? blocker;
    addTearDown(() async {
      try {
        await blocker?.close();
      } catch (_) {}
      try {
        await old.db.close();
      } catch (_) {}
      try {
        await old.dir.delete(recursive: true);
      } catch (_) {}
      await AppDatabase.resetForTest();
    });
    // 先切 WAL 并写一帧 WAL 数据，再开阻碍连接（见 [_enableWalWithFrame]）。
    await _enableWalWithFrame(old.db);
    blocker = QuizDatabase.file(File(old.dbPath));
    await blocker.customSelect('SELECT 1').get();
    await blocker.customStatement('BEGIN');
    await blocker.customSelect('SELECT * FROM questions').get();
    final zip = await _makeNewZip();
    await expectLater(
      () => AppDatabase.importBackupZipInto(old.db, zip, dataDir: old.dir.path),
      throwsA(
        isA<BackupRestoreException>().having(
          (e) => e.message,
          'message',
          contains('正被另一处使用'),
        ),
      ),
    );
    await blocker.customStatement('ROLLBACK');
    await blocker.close();
    blocker = null;
    expect(await _questionTitles(old.db), {'q-old': '旧题'});
    expect(_readBytes(old.dir, 'slices/q1.png'), [1, 1, 1]);
    expect(
      old.dir.listSync().where(
        (e) => p.basename(e.path).startsWith('.restore-snapshot-'),
      ),
      isEmpty,
      reason: '拒绝时不得复制主库文件',
    );
    expect(_leftoverRestoreMaterials(old.dir), isEmpty);
    expect(AppDatabase.inRestoreMaintenance, isFalse);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('⑥ 日志原子替换中断：临时已写、替换未完成时重启，日志推进不丢', () async {
    final old = await _makeOldState();
    addTearDown(() async {
      try {
        await old.db.close();
      } catch (_) {}
      try {
        await old.dir.delete(recursive: true);
      } catch (_) {}
      await AppDatabase.resetForTest();
    });
    final store = RestoreJournalStore(dataDir: old.dir);
    final journal = RestoreJournal(
      taskId: 'flow-6',
      rollbackDir: p.join(old.dir.path, 'imports-rollback', 'flow-6'),
      stagingDir: p.join(old.dir.path, 'restore-staging', 'flow-6'),
      snapshotPath: p.join(old.dir.path, '.restore-snapshot-flow-6.db'),
      stage: RestoreStage.preparing,
      status: RestoreStatus.inProgress,
    );
    await store.writeInitial(journal);
    // 模拟“临时新日志已写、正式替换尚未完成时进程退出”：
    // 只写 tmp，不走 updateStage。
    await store.writeTemp(journal.copyWith(stage: RestoreStage.snapshotReady));
    expect(store.tmpFile.existsSync(), isTrue);
    // 重启定位：正式日志仍是旧版 PREPARING 且完整，残留 tmp 被丢弃
    // （不得把未完成替换的下一阶段装成已完成）。
    final recovered = await store.locateAndRecover();
    expect(recovered, isNotNull);
    expect(recovered!.stage, RestoreStage.preparing);
    expect(store.tmpFile.existsSync(), isFalse);
    expect(
      (await store.validateFile(store.formalFile)).stage,
      RestoreStage.preparing,
    );
    // 日志推进能继续：再正常推进到 SNAPSHOT_READY。
    final advanced = await store.updateStage(
      journal.copyWith(stage: RestoreStage.snapshotReady),
    );
    expect(advanced.stage, RestoreStage.snapshotReady);
    // 走一次完整恢复流程（启动钩子先清掉这条 SNAPSHOT_READY 日志，
    // 再正常恢复），证明中断没把流程层面的日志推进弄丢。
    await performStartupRestoreIfNeeded(old.dbPath);
    expect(_leftoverRestoreMaterials(old.dir), isEmpty);
    final zip = await _makeNewZip();
    await AppDatabase.importBackupZipInto(old.db, zip, dataDir: old.dir.path);
    expect(await _questionTitles(old.db), {'q-new': '新题'});
    expect(_readBytes(old.dir, 'slices/q1.png'), [9, 9, 9]);
    expect(_leftoverRestoreMaterials(old.dir), isEmpty);
  });

  test('⑦ 日志先于快照写入：PREPARING 落盘时正式文件未动、快照未拷', () async {
    final old = await _makeOldState();
    QuizDatabase? blocker;
    addTearDown(() async {
      try {
        await blocker?.close();
      } catch (_) {}
      try {
        await old.db.close();
      } catch (_) {}
      try {
        await old.dir.delete(recursive: true);
      } catch (_) {}
      await AppDatabase.resetForTest();
    });
    // 先切 WAL 并写一帧 WAL 数据，再开阻碍连接（见 [_enableWalWithFrame]）。
    await _enableWalWithFrame(old.db);
    blocker = QuizDatabase.file(File(old.dbPath));
    await blocker.customSelect('SELECT 1').get();
    await blocker.customStatement('BEGIN');
    await blocker.customSelect('SELECT * FROM questions').get();
    final zip = await _makeNewZip();
    final importFuture = AppDatabase.importBackupZipInto(
      old.db,
      zip,
      dataDir: old.dir.path,
    );
    // 恢复在快照处被挡住：此时 PREPARING 日志必须已在盘上，
    // 而正式文件与数据库行都还是旧的、快照文件还不存在——
    // 即日志落盘发生在任何正式文件改动之前。
    final journalSeen = await _waitUntil(
      () => File(p.join(old.dir.path, 'restore-journal.json')).existsSync(),
    );
    expect(journalSeen, isTrue);
    final store = RestoreJournalStore(dataDir: old.dir);
    final journal = await store.validateFile(store.formalFile);
    expect(journal.stage, RestoreStage.preparing);
    expect(await _questionTitles(old.db), {'q-old': '旧题'});
    expect(_readBytes(old.dir, 'slices/q1.png'), [1, 1, 1]);
    expect(_readBytes(old.dir, 'imports/task-1/original.jpg'), [2, 2, 2]);
    expect(
      old.dir.listSync().where(
        (e) => p.basename(e.path).startsWith('.restore-snapshot-'),
      ),
      isEmpty,
      reason: 'PREPARING 阶段快照文件不得存在',
    );
    await blocker.customStatement('ROLLBACK');
    await blocker.close();
    blocker = null;
    await importFuture;
    expect(await _questionTitles(old.db), {'q-new': '新题'});
    expect(_leftoverRestoreMaterials(old.dir), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('⑧ 快照就绪（SNAPSHOT_READY）后再中断，恢复仍能回到旧库', () async {
    final old = await _makeOldState();
    addTearDown(() async {
      await AppDatabase.resetForTest();
      try {
        await old.dir.delete(recursive: true);
      } catch (_) {}
    });
    await old.db.close();
    // 崩溃现场：快照已拷好（旧库拷贝），正式文件没动过，
    // rollback 目录不存在（切换没开始），staging 有残留。
    final taskId = 'crash-8';
    final snapshotPath = p.join(old.dir.path, '.restore-snapshot-$taskId.db');
    await File(old.dbPath).copy(snapshotPath);
    final stagingDir = Directory(
      p.join(old.dir.path, 'restore-staging', taskId),
    );
    await _writeDataFile(
      old.dir,
      p.join('restore-staging', taskId, 'slices', 'q1.png'),
      [9, 9, 9],
    );
    final store = RestoreJournalStore(dataDir: old.dir);
    await store.writeInitial(
      RestoreJournal(
        taskId: taskId,
        rollbackDir: p.join(old.dir.path, 'imports-rollback', taskId),
        stagingDir: stagingDir.path,
        snapshotPath: snapshotPath,
        stage: RestoreStage.snapshotReady,
        status: RestoreStatus.inProgress,
      ),
    );
    final reopened = await _runStartup(old.dir.path);
    expect(await _questionTitles(reopened), {'q-old': '旧题'});
    expect(_readBytes(old.dir, 'slices/q1.png'), [1, 1, 1]);
    expect(_readBytes(old.dir, 'imports/task-1/original.jpg'), [2, 2, 2]);
    expect(_leftoverRestoreMaterials(old.dir), isEmpty);
  });

  test('⑨ 幂等重启：中断恢复回滚后再次启动，不重复执行恢复、数据不变', () async {
    final old = await _makeOldState();
    addTearDown(() async {
      await AppDatabase.resetForTest();
      try {
        await old.dir.delete(recursive: true);
      } catch (_) {}
    });
    await old.db.close();
    await _stageFilesSwitchingCrash(old.dir, old.dbPath, taskId: 'crash-9');
    final first = await _runStartup(old.dir.path);
    final firstTitles = await _questionTitles(first);
    final firstSlice = _readBytes(old.dir, 'slices/q1.png');
    final firstSource = _readBytes(old.dir, 'imports/task-1/original.jpg');
    expect(firstTitles, {'q-old': '旧题'});
    expect(firstSlice, [1, 1, 1]);
    expect(firstSource, [2, 2, 2]);
    expect(_leftoverRestoreMaterials(old.dir), isEmpty);
    // 第二次启动：日志已清，不再执行恢复，数据与第一次完全一致。
    final second = await _runStartup(old.dir.path);
    expect(await _questionTitles(second), firstTitles);
    expect(_readBytes(old.dir, 'slices/q1.png'), firstSlice);
    expect(_readBytes(old.dir, 'imports/task-1/original.jpg'), firstSource);
    expect(_leftoverRestoreMaterials(old.dir), isEmpty);
  });
}
