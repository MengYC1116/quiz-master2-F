// Batch 5 第五阶段 P2 数据层回归测试（SR-P2-1/2/4/5/6/7/8/9/10/11/12/
// 14/15/16/17/36/68）。
// 全部用内存库 + 临时目录，不碰真实演示库；SR-P2-3 与 SR-P2-22 的
// 剩余部分在调用方（详情页 / 收集页），见 B5-P2-DATA.md 的转交说明，
// 本文件不覆盖；SR-P2-13 是删除无调用方的 demoQuestions()，
// 以编译 + 全仓 grep 为证，不另立测试。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/zip_archive.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> openTestDb() async {
  sqfliteFfiInit();
  return databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, version) async => AppDatabase.createTables(db),
    ),
  );
}

Future<void> insertQuestion(
  Database db,
  String id, {
  String subjectId = 'math',
  int isDemo = 0,
  int isOrganized = 0,
  int reviewJoined = 0,
  String folderIds = '[]',
  String title = 't',
  int reviewCount = 0,
}) async {
  await db.insert('questions', {
    'id': id,
    'title': title,
    'subject_id': subjectId,
    'folder_ids': folderIds,
    'created_at': 1000,
    'is_demo': isDemo,
    'is_organized': isOrganized,
    'review_joined': reviewJoined,
    'review_count': reviewCount,
  });
}

Future<void> insertCauseRecord(
  Database db,
  String questionId,
  String cause, {
  String subjectId = 'math',
  String status = 'pending',
  int solvedCount = 0,
  int? recheckDate,
}) async {
  await db.insert('cause_records', {
    'question_id': questionId,
    'cause': cause,
    'subject_id': subjectId,
    'status': status,
    'solved_count': solvedCount,
    'recheck_date': recheckDate,
    'joined_at': 1000,
  });
}

QuestionBox box({
  required String id,
  int layer = 1,
  String type = 'question',
  int page = 1,
  String? parentBoxId,
  String? questionId,
  String? collectTaskId,
}) => QuestionBox(
  id: id,
  layer: layer,
  type: type,
  x: 0.1,
  y: 0.1,
  w: 0.5,
  h: 0.3,
  page: page,
  parentBoxId: parentBoxId,
  questionId: questionId,
  collectTaskId: collectTaskId,
);

Future<void> insertTask(
  Database db,
  String id, {
  String subjectId = 'math',
  String sourcePath = '',
}) async {
  await db.insert('collect_tasks', {
    'id': id,
    'name': 't-$id',
    'file_name': 'f.png',
    'subject_id': subjectId,
    'status': 'needBox',
    'source_path': sourcePath,
  });
}

/// 种子一个最小合法库并导出备份 JSON（各组 P2-4/5/6 的变造基线）。
/// 可对同一库重复调（REPLACE 去重）。
Future<Map<String, dynamic>> exportedJson(Database db) async {
  await db.insert('subjects', {
    'id': 'math',
    'name': '数学',
    'color': 0xFF2E7CF6,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
  await db.delete('questions', where: 'id = ?', whereArgs: ['q1']);
  await insertQuestion(db, 'q1', isOrganized: 1);
  return jsonDecode(await AppDatabase.exportBackupJsonFrom(db))
      as Map<String, dynamic>;
}

void main() {
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('b5-p2-data-');
    AppDatabase.testDataDirectory = tmpDir.path;
    addTearDown(() async {
      await AppDatabase.resetForTest();
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    });
  });

  group('SR-P2-1 删学科清草稿框', () {
    test('该科任务的草稿框（含 2 层子框）随学科删干净，他科不动', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await db.insert('subjects', {
        'id': 'math',
        'name': '数学',
        'color': 0xFF000000,
      });
      await db.insert('subjects', {
        'id': 'english',
        'name': '英语',
        'color': 0xFF000000,
      });
      await insertTask(db, 'ct-math', subjectId: 'math');
      await insertTask(db, 'ct-eng', subjectId: 'english');
      await db.insert(
        'question_boxes',
        _boxRow(box(id: 'b1', collectTaskId: 'ct-math')),
      );
      await db.insert(
        'question_boxes',
        _boxRow(
          box(
            id: 'b1-stem',
            layer: 2,
            type: 'stem',
            parentBoxId: 'b1',
            collectTaskId: 'ct-math',
          ),
        ),
      );
      await db.insert(
        'question_boxes',
        _boxRow(box(id: 'b2', collectTaskId: 'ct-eng')),
      );
      await AppDatabase.deleteSubjectFrom(db, 'math');
      final left = await db.query('question_boxes');
      expect(left.map((r) => r['id']).toList(), ['b2']);
      expect(await db.query('collect_tasks'), hasLength(1));
    });
  });

  group('SR-P2-2 清演示数据走删题事务', () {
    test('演示题的框清掉、任务指向置空；recent_tasks 与复习断点不动', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertQuestion(db, 'demo1', isDemo: 1);
      await insertQuestion(db, 'real1', isDemo: 0);
      await insertCauseRecord(db, 'demo1', '计算错误');
      await db.insert(
        'question_boxes',
        _boxRow(box(id: 'b-demo', questionId: 'demo1')),
      );
      await insertTask(db, 'ct-demo', sourcePath: '');
      await db.update(
        'collect_tasks',
        {'question_id': 'demo1'},
        where: 'id = ?',
        whereArgs: ['ct-demo'],
      );
      await db.insert('recent_tasks', {
        'id': 1,
        'kind': '整理',
        'subject_id': 'math',
        'title': 't',
        'updated_at': 1,
      });
      await db.insert('review_state', {
        'id': 1,
        'queue': '[{"q":"demo1","c":"计算错误"}]',
        'position': 0,
        'updated_at': 1,
      });
      final n = await AppDatabase.clearDemoDataFrom(db);
      expect(n, 1);
      expect(await db.query('question_boxes'), isEmpty);
      final task = (await db.query(
        'collect_tasks',
        where: 'id = ?',
        whereArgs: ['ct-demo'],
      )).single;
      expect(task['question_id'], isNull);
      expect(await db.query('recent_tasks'), hasLength(1));
      final state = (await db.query('review_state')).single;
      expect(state['queue'], '[]');
    });
  });

  group('SR-P2-4 备份校验缺口', () {
    test('缺表键拒绝恢复，原库不动', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final data = await exportedJson(db);
      data.remove('cause_records');
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, data),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.message,
            'message',
            contains('cause_records'),
          ),
        ),
      );
      expect(await db.query('questions'), hasLength(1));
    });

    test('主键 null 拒绝恢复', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final data = await exportedJson(db);
      (data['questions'] as List).first['id'] = null;
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, data),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(await db.query('questions'), hasLength(1));
    });

    test('必填列缺失 / 类型不对拒绝恢复', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final noTitle = await exportedJson(db);
      (noTitle['questions'] as List).first.remove('title');
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, noTitle),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.message,
            'message',
            contains('title'),
          ),
        ),
      );
      final badType = await exportedJson(db);
      (badType['questions'] as List).first['title'] = 123;
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, badType),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(await db.query('questions'), hasLength(1));
    });

    test('插库残余异常包成 BackupRestoreException（不露 sqlite 原文）', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final data = await exportedJson(db);
      (data['questions'] as List).first['no_such_col'] = 1;
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, data),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.message,
            'message',
            contains('备份数据有问题'),
          ),
        ),
      );
      expect(await db.query('questions'), hasLength(1));
    });
  });

  group('SR-P2-5 备份恢复 2GB 上限', () {
    Future<List<int>> validZip(Database db) async {
      final json = await AppDatabase.exportBackupJsonFrom(db);
      return buildZip([ZipEntryData('backup.json', utf8.encode(json))]);
    }

    test('现有占用超 2GB 时拒绝整个恢复，原库不动', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await exportedJson(db);
      // 稀疏文件：逻辑 2GB+1 字节，几乎不占真实磁盘。
      final huge = File(p.join(tmpDir.path, 'imports', 'huge.bin'));
      await huge.parent.create(recursive: true);
      final raf = await huge.open(mode: FileMode.write);
      await raf.truncate(2 * 1024 * 1024 * 1024 + 1);
      await raf.close();
      final zip = await validZip(db);
      await expectLater(
        () => AppDatabase.importBackupZipInto(db, zip, dataDir: tmpDir.path),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.message,
            'message',
            contains('2GB'),
          ),
        ),
      );
      expect(await db.query('questions'), hasLength(1));
    });

    test('现有占用 1GB 时恢复放行（对照）', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await exportedJson(db);
      final big = File(p.join(tmpDir.path, 'imports', 'big.bin'));
      await big.parent.create(recursive: true);
      final raf = await big.open(mode: FileMode.write);
      await raf.truncate(1024 * 1024 * 1024);
      await raf.close();
      final zip = await validZip(db);
      await AppDatabase.importBackupZipInto(db, zip, dataDir: tmpDir.path);
      expect(await db.query('questions'), hasLength(1));
    });
  });

  group('SR-P2-7 setCustomDataDirectory', () {
    test('标记写到 testMarkerDirectory，不动默认位置', () async {
      final db = await openTestDb();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => db.close());
      final markerDir = await Directory.systemTemp.createTemp('b5-p2-marker-');
      addTearDown(() async {
        try {
          await markerDir.delete(recursive: true);
        } catch (_) {}
      });
      AppDatabase.testMarkerDirectory = markerDir.path;
      final target = await Directory.systemTemp.createTemp('b5-p2-target-');
      addTearDown(() async {
        try {
          await target.delete(recursive: true);
        } catch (_) {}
      });
      await AppDatabase.instance.setCustomDataDirectory(target.path);
      final marker = File(p.join(markerDir.path, 'db_location.txt'));
      expect(await marker.exists(), isTrue);
      expect(await marker.readAsString(), target.path);
      final rows = await db.query(
        'settings',
        where: 'key = ?',
        whereArgs: ['databaseLocation'],
      );
      expect(rows.single['value'], target.path);
    });

    test('不存在的目录拒绝，不写标记也不写设置', () async {
      final db = await openTestDb();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => db.close());
      final markerDir = await Directory.systemTemp.createTemp('b5-p2-marker-');
      addTearDown(() async {
        try {
          await markerDir.delete(recursive: true);
        } catch (_) {}
      });
      AppDatabase.testMarkerDirectory = markerDir.path;
      await expectLater(
        () => AppDatabase.instance.setCustomDataDirectory(
          p.join(tmpDir.path, 'no-such-dir'),
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        await File(p.join(markerDir.path, 'db_location.txt')).exists(),
        isFalse,
      );
      expect(
        await db.query(
          'settings',
          where: 'key = ?',
          whereArgs: ['databaseLocation'],
        ),
        isEmpty,
      );
    });

    test('标记写失败时设置回滚到旧值', () async {
      final db = await openTestDb();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => db.close());
      final markerDir = await Directory.systemTemp.createTemp('b5-p2-marker-');
      addTearDown(() async {
        try {
          await markerDir.delete(recursive: true);
        } catch (_) {}
      });
      AppDatabase.testMarkerDirectory = markerDir.path;
      // 把标记文件位置占成目录，writeAsString 必失败。
      await Directory(p.join(markerDir.path, 'db_location.txt')).create();
      await AppDatabase.instance.saveSetting('databaseLocation', '/old/dir');
      final target = await Directory.systemTemp.createTemp('b5-p2-target-');
      addTearDown(() async {
        try {
          await target.delete(recursive: true);
        } catch (_) {}
      });
      await expectLater(
        () => AppDatabase.instance.setCustomDataDirectory(target.path),
        throwsA(anything),
      );
      final rows = await db.query(
        'settings',
        where: 'key = ?',
        whereArgs: ['databaseLocation'],
      );
      expect(rows.single['value'], '/old/dir');
    });
  });

  group('SR-P2-8 加入/同步复习同事务', () {
    Question joinedQ() => Question(
      id: 'q1',
      title: 't',
      subjectId: 'math',
      errorTypes: ['计算错误', '概念不清'],
      reviewJoined: true,
      isOrganized: true,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );

    test('setReviewJoinedInto：题行 + 错因记录一次建出', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertQuestion(db, 'q1', isOrganized: 1);
      final ok = await AppDatabase.setReviewJoinedInto(db, joinedQ(), true);
      expect(ok, isTrue);
      final q = (await db.query(
        'questions',
        where: 'id = ?',
        whereArgs: ['q1'],
      )).single;
      expect(q['review_joined'], 1);
      final records = await db.query('cause_records');
      expect(records.map((r) => r['cause']).toList(), [
        '计算错误',
        '概念不清',
      ]);
    });

    test('setReviewJoinedInto 中途失败：题行一起回滚', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await db.execute(
        "CREATE TRIGGER trg_fail_cause BEFORE INSERT ON cause_records "
        "BEGIN SELECT RAISE(ABORT, 'boom'); END;",
      );
      await expectLater(
        () => AppDatabase.setReviewJoinedInto(db, joinedQ(), true),
        throwsA(anything),
      );
      expect(await db.query('questions'), isEmpty);
      expect(await db.query('cause_records'), isEmpty);
    });

    test('错因是空的题加不进复习，返回 false、不写库', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertQuestion(db, 'q1', isOrganized: 1);
      final q = Question(
        id: 'q1',
        title: 't',
        subjectId: 'math',
        isOrganized: true,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      expect(await AppDatabase.setReviewJoinedInto(db, q, true), isFalse);
      expect(
        (await db.query(
          'questions',
          where: 'id = ?',
          whereArgs: ['q1'],
        )).single['review_joined'],
        0,
      );
    });

    test('syncCauseRecordsInto：删旧错因、补新错因同事务', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertQuestion(db, 'q1', isOrganized: 1, reviewJoined: 1);
      await insertCauseRecord(db, 'q1', '计算错误');
      await insertCauseRecord(db, 'q1', '概念不清');
      final q = joinedQ().copyWith(errorTypes: ['计算错误', '审题失误']);
      await AppDatabase.syncCauseRecordsInto(db, q);
      final records = await db.query(
        'cause_records',
        orderBy: 'cause ASC',
      );
      expect(records.map((r) => r['cause']).toList(), ['审题失误', '计算错误']);
    });
  });

  group('SR-P2-9 saveSettings 入事务', () {
    test('中途失败：已写的键一起回滚，不留新旧混杂', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await db.execute(
        "CREATE TRIGGER trg_fail_font BEFORE INSERT ON settings "
        "WHEN NEW.key = 'fontSize' "
        "BEGIN SELECT RAISE(ABORT, 'boom'); END;",
      );
      final s = AppSettings.defaults.copyWith(
        themeMode: 'dark',
        fontSize: 'large',
      );
      await expectLater(
        () => AppDatabase.saveSettingsInto(db, s),
        throwsA(anything),
      );
      expect(await db.query('settings'), isEmpty);
    });

    test('成功：全部键一次写进', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await AppDatabase.saveSettingsInto(
        db,
        AppSettings.defaults.copyWith(themeMode: 'dark'),
      );
      final rows = await db.query(
        'settings',
        where: 'key = ?',
        whereArgs: ['themeMode'],
      );
      expect(rows.single['value'], 'dark');
    });
  });

  group('SR-P2-10 确认拆题防静默覆盖', () {
    Future<CollectTask> origTask(Database db) async {
      final orig = CollectTask(
        id: 'task-orig',
        name: 'orig',
        fileName: 'orig.jpg',
        subjectId: 'math',
        status: CollectStatus.boxing,
      );
      await AppDatabase.upsertCollectTaskInto(db, orig);
      return orig;
    }

    test('同 id 题目已存在：显式失败，旧题原样不动', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final orig = await origTask(db);
      await insertQuestion(db, 'import-1', isOrganized: 1, title: '旧题');
      await expectLater(
        () => AppDatabase.confirmSplitInto(
          db,
          originalTask: orig,
          questions: [
            Question(
              id: 'import-1',
              title: '新题',
              subjectId: 'math',
              createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
            ),
          ],
          splitTasks: [
            CollectTask(
              id: 'task-split-1',
              name: 's',
              fileName: 'orig.jpg',
              subjectId: 'math',
            ),
          ],
          boxesByQuestionId: const {},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('题目已存在'),
          ),
        ),
      );
      final q = (await db.query(
        'questions',
        where: 'id = ?',
        whereArgs: ['import-1'],
      )).single;
      expect(q['title'], '旧题');
      expect(q['is_organized'], 1);
      expect(await db.query('collect_tasks'), hasLength(1));
    });

    test('同 id 拆分任务已存在：显式失败', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final orig = await origTask(db);
      await insertTask(db, 'task-split-1');
      await expectLater(
        () => AppDatabase.confirmSplitInto(
          db,
          originalTask: orig,
          questions: [
            Question(
              id: 'import-1',
              title: '新题',
              subjectId: 'math',
              createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
            ),
          ],
          splitTasks: [
            CollectTask(
              id: 'task-split-1',
              name: 's',
              fileName: 'orig.jpg',
              subjectId: 'math',
            ),
          ],
          boxesByQuestionId: const {},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('拆分任务已存在'),
          ),
        ),
      );
      expect(await db.query('questions'), isEmpty);
    });
  });

  group('SR-P2-11 删老库先清附属', () {
    Future<String> v1DbFile() async {
      final path = p.join(tmpDir.path, 'quiz-master2.db');
      final db = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async => AppDatabase.createTables(db),
        ),
      );
      await db.close();
      return path;
    }

    test('v1 库 + -wal/-shm：全删掉，返回 true', () async {
      final path = await v1DbFile();
      await File('$path-wal').writeAsString('wal');
      await File('$path-shm').writeAsString('shm');
      expect(
        await AppDatabase.deleteLegacyDatabaseIfPresent(path),
        isTrue,
      );
      expect(await File(path).exists(), isFalse);
      expect(await File('$path-wal').exists(), isFalse);
      expect(await File('$path-shm').exists(), isFalse);
    });

    test('-wal 是目录：探针打不开，拒绝删除、文件原样保留', () async {
      // SQLite 只读探针遇到目录 -wal 即打不开库（error 14），
      // 按保守口径拒绝删除、不删老库——附属删失败不抛错的分支
      // 是防 Windows 文件锁定的防御代码，Linux 单测无法直接
      // 模拟（删失败的前置条件会先让探针失败），此处只锁定
      // “探针失败即拒绝、不动文件”的行为。
      final path = await v1DbFile();
      await Directory('$path-wal').create();
      await expectLater(
        () => AppDatabase.deleteLegacyDatabaseIfPresent(path),
        throwsA(isA<LegacyDatabaseException>()),
      );
      expect(await File(path).exists(), isTrue);
    });

    test('v2 库：不动，返回 false', () async {
      final path = p.join(tmpDir.path, 'quiz-master2.db');
      final db = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, version) async => AppDatabase.createTables(db),
        ),
      );
      await db.close();
      expect(
        await AppDatabase.deleteLegacyDatabaseIfPresent(path),
        isFalse,
      );
      expect(await File(path).exists(), isTrue);
    });
  });

  group('SR-P2-12 框 id 熵', () {
    test('随机段 16 位十六进制，1000 个不碰撞', () {
      final ids = {
        for (var i = 0; i < 1000; i++) AppDatabase.newBoxId('task-1', 1),
      };
      expect(ids, hasLength(1000));
      final sample = ids.first;
      expect(sample.startsWith('box-task-1-p1-'), isTrue);
      final rand = sample.split('-').last;
      expect(rand.length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(rand), isTrue);
    });
  });

  group('SR-P2-14 草稿保存的任务行校验与缺页键契约', () {
    test('任务行不存在：抛错回滚，框不写进去', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await expectLater(
        () => AppDatabase.saveDraftBoxesInto(
          db,
          taskId: 'no-such-task',
          boxesByPage: {
            1: [box(id: 'b1', collectTaskId: 'no-such-task')],
          },
          inners: const {},
          standaloneInner: const {},
          rotations: const {1: 90},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('收集任务不存在'),
          ),
        ),
      );
      expect(await db.query('question_boxes'), isEmpty);
    });

    test('被清空的页传空列表键：旧草稿删掉；缺页键的旧草稿保留', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertTask(db, 'task-1');
      await AppDatabase.saveDraftBoxesInto(
        db,
        taskId: 'task-1',
        boxesByPage: {
          1: [box(id: 'b1', collectTaskId: 'task-1')],
          2: [box(id: 'b2', page: 2, collectTaskId: 'task-1')],
        },
        inners: const {},
        standaloneInner: const {},
        rotations: const {},
      );
      // 只传第 1 页为空列表：第 1 页清空，第 2 页缺键、保留。
      await AppDatabase.saveDraftBoxesInto(
        db,
        taskId: 'task-1',
        boxesByPage: {
          1: <QuestionBox>[],
        },
        inners: const {},
        standaloneInner: const {},
        rotations: const {},
      );
      final left = await AppDatabase.boxesForTaskFrom(db, 'task-1');
      expect(left.map((b) => b.id).toList(), ['b2']);
    });
  });

  group('SR-P2-15 删任务目录查 collect_tasks.source_path', () {
    test('拆分任务行还指着原目录：目录保留', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final dir = Directory(p.join(tmpDir.path, 'imports', 'orig'));
      await dir.create(recursive: true);
      await File(p.join(dir.path, 'original.pdf')).writeAsString('pdf');
      await insertTask(
        db,
        'orig',
        sourcePath: 'imports/orig/original.pdf',
      );
      await insertTask(
        db,
        'split-1',
        sourcePath: 'imports/orig/original.pdf',
      );
      await AppDatabase.deleteCollectTaskFrom(db, 'orig');
      expect(await dir.exists(), isTrue);
      expect(
        (await db.query('collect_tasks')).map((r) => r['id']).toList(),
        ['split-1'],
      );
    });

    test('无人引用：目录删掉（对照）', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final dir = Directory(p.join(tmpDir.path, 'imports', 'orig'));
      await dir.create(recursive: true);
      await File(p.join(dir.path, 'original.pdf')).writeAsString('pdf');
      await insertTask(
        db,
        'orig',
        sourcePath: 'imports/orig/original.pdf',
      );
      await AppDatabase.deleteCollectTaskFrom(db, 'orig');
      expect(await dir.exists(), isFalse);
    });
  });

  group('SR-P2-16 自查按库内值重算', () {
    CauseRecord snapshot() => CauseRecord(
      questionId: 'q1',
      cause: '计算错误',
      subjectId: 'math',
      status: CauseStatus.pending,
      solvedCount: 0,
      joinedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );

    test('两次基于同一旧快照的“已解决”：计数 +2，不是 +1', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertQuestion(db, 'q1', reviewCount: 0);
      await insertCauseRecord(db, 'q1', '计算错误');
      final stale = snapshot();
      await AppDatabase.recordSelfCheckInto(
        db,
        updated: stale.copyWith(status: CauseStatus.inProgress, solvedCount: 1),
        questionId: 'q1',
        result: 'solved',
      );
      // 第二次仍拿同一份旧快照（solvedCount 0）：库内值是 1，
      // 重算后应为 2 且已解决，而不是按快照写回 1。
      final written = await AppDatabase.recordSelfCheckInto(
        db,
        updated: stale.copyWith(status: CauseStatus.inProgress, solvedCount: 1),
        questionId: 'q1',
        result: 'solved',
      );
      expect(written.solvedCount, 2);
      expect(written.status, CauseStatus.solved);
      final row = (await db.query('cause_records')).single;
      expect(row['solved_count'], 2);
      expect(row['status'], 'solved');
      expect(await db.query('review_history'), hasLength(2));
      final q = (await db.query('questions')).single;
      expect(q['review_count'], 2);
    });

    test('复查通过不加计数：库内 solvedCount 不动，只顺延复查日', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertQuestion(db, 'q1', reviewCount: 0);
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      await insertCauseRecord(
        db,
        'q1',
        '计算错误',
        status: 'solved',
        solvedCount: 2,
        recheckDate: yesterday.millisecondsSinceEpoch,
      );
      final written = await AppDatabase.recordSelfCheckInto(
        db,
        updated: snapshot(),
        questionId: 'q1',
        result: 'solved',
        isRecheck: true,
      );
      expect(written.solvedCount, 2);
      expect(written.status, CauseStatus.solved);
      expect(written.recheckDate, isNotNull);
      expect(
        written.recheckDate!.isAfter(DateTime.now()),
        isTrue,
      );
    });
  });

  group('SR-P2-17 删文件夹按 folder_ids 粗筛', () {
    test('含 _ 的文件夹 id 不误筛其它文件夹的题', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await db.insert('folders', {
        'id': 'f_1',
        'name': 'A',
        'subject_id': 'math',
        'parent_id': null,
        'sort_order': 0,
      });
      await db.insert('folders', {
        'id': 'fX1',
        'name': 'B',
        'subject_id': 'math',
        'parent_id': null,
        'sort_order': 1,
      });
      await insertQuestion(db, 'q1', folderIds: '["f_1"]');
      await insertQuestion(db, 'q2', folderIds: '["fX1"]');
      await insertQuestion(db, 'q3', folderIds: '["f_1","fX1"]');
      final deleted = await AppDatabase.deleteFolderFrom(
        db,
        const Folder(id: 'f_1', name: 'A', subjectId: 'math'),
      );
      expect(deleted, 1);
      final left = await db.query('questions');
      expect(left.map((r) => r['id']).toList(), ['q2', 'q3']);
      final q3 = left.firstWhere((r) => r['id'] == 'q3');
      expect(q3['folder_ids'], '["fX1"]');
    });
  });

  group('SR-P2-36 文件夹同名判重整科', () {
    test('同科跨层同名拒绝；不同科同名放行；自己原地更新放行', () async {
      final db = await openTestDb();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => db.close());
      await AppDatabase.instance.upsertFolder(
        const Folder(id: 'f1', name: '试卷', subjectId: 'math'),
      );
      // 同科另一父级下同名：拒绝。
      await expectLater(
        () => AppDatabase.instance.upsertFolder(
          const Folder(
            id: 'f2',
            name: '试卷',
            subjectId: 'math',
            parentId: 'f1',
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('已经有了'),
          ),
        ),
      );
      // 不同科同名：放行。
      await AppDatabase.instance.upsertFolder(
        const Folder(id: 'f3', name: '试卷', subjectId: 'english'),
      );
      // 自己原地更新（改排序）：放行。
      await AppDatabase.instance.upsertFolder(
        const Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 5),
      );
      // 改名撞上同科已有名：拒绝。
      await AppDatabase.instance.upsertFolder(
        const Folder(id: 'f4', name: '作业', subjectId: 'math'),
      );
      await expectLater(
        () => AppDatabase.instance.upsertFolder(
          const Folder(id: 'f4', name: '试卷', subjectId: 'math'),
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        await AppDatabase.folderNameExistsInSubjectFrom(db, 'math', '试卷'),
        isTrue,
      );
      expect(
        await AppDatabase.folderNameExistsInSubjectFrom(
          db,
          'math',
          '试卷',
          excludeId: 'f1',
        ),
        isFalse,
      );
      expect(
        await AppDatabase.folderNameExistsInSubjectFrom(
          db,
          'math',
          '不存在',
        ),
        isFalse,
      );
    });
  });

  group('SR-P2-68 readZip 走中央目录', () {
    test('带数据描述符（flag bit 3）的 zip 能读：stored 与 deflate', () {
      final stored = _buildDescriptorZip(
        'backup.json',
        utf8.encode('{"a":1}'),
        method: 0,
      );
      final entries = readZip(stored);
      expect(entries.map((e) => e.name), ['backup.json']);
      expect(utf8.decode(entries.first.bytes), '{"a":1}');
      final deflated = _buildDescriptorZip(
        'slices/q1.png',
        List.filled(5000, 7),
        method: 8,
      );
      final entries2 = readZip(deflated);
      expect(entries2.single.bytes, List.filled(5000, 7));
    });

    test('只含目录条目的 zip 抛错，不静默返回空列表', () {
      final dirOnly = _buildDescriptorZip('imports/', [], method: 0);
      expect(() => readZip(dirOnly), throwsA(isA<ZipFormatException>()));
      final emptyDir = buildZip([const ZipEntryData('imports/', [])]);
      expect(() => readZip(emptyDir), throwsA(isA<ZipFormatException>()));
    });

    test('中央目录与 local header 名不一致：抛错', () {
      final good = buildStoredZipForTest([
        ('backup.json', utf8.encode('{"a":1}')),
      ]);
      // 中央目录在 local 数据之后：把中央目录里的名字首字节改掉。
      final tampered = List<int>.of(good);
      final cd = _findBytes(tampered, [0x50, 0x4B, 0x01, 0x02]);
      tampered[cd + 46] = 'X'.codeUnitAt(0);
      expect(() => readZip(tampered), throwsA(isA<ZipFormatException>()));
    });

    test('超大单条目：解压前按中央目录 rawSize 预判，不先占内存', () {
      // 中央目录谎报 rawSize 10MB，实际只有 3 字节，上限 1KB：
      // 预判必须在解压前触发，而不是解压后。
      final bytes = _buildDescriptorZip('big.bin', [1, 2, 3], method: 0);
      final tampered = List<int>.of(bytes);
      final cd = _findBytes(tampered, [0x50, 0x4B, 0x01, 0x02]);
      // 中央目录 rawSize 在 +24：写成 10MB。
      _writeU32(tampered, cd + 24, 10 * 1024 * 1024);
      expect(
        () => readZip(tampered, maxTotalBytes: 1024),
        throwsA(
          isA<ZipFormatException>().having(
            (e) => e.message,
            'message',
            contains('超过'),
          ),
        ),
      );
    });

    test('空 zip（0 条目）抛错', () {
      final bytes = buildZip([]);
      expect(() => readZip(bytes), throwsA(isA<ZipFormatException>()));
    });
  });
}

Map<String, Object?> _boxRow(QuestionBox b) => {
  'id': b.id,
  'collect_task_id': b.collectTaskId,
  'question_id': b.questionId,
  'parent_box_id': b.parentBoxId,
  'page': b.page,
  'layer': b.layer,
  'type': b.type,
  'x': b.x,
  'y': b.y,
  'w': b.w,
  'h': b.h,
  'confidence': b.confidence,
  'origin': b.origin,
  'updated_at': 1000,
};

void _u16(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
void _u32(BytesBuilder b, int v) => b.add([
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
]);

void _writeU32(List<int> bytes, int off, int v) {
  bytes[off] = v & 0xFF;
  bytes[off + 1] = (v >> 8) & 0xFF;
  bytes[off + 2] = (v >> 16) & 0xFF;
  bytes[off + 3] = (v >> 24) & 0xFF;
}

int _findBytes(List<int> bytes, List<int> pattern) {
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

/// 手工造带数据描述符的 zip（SR-P2-68）：local header 置 flag bit 3、
/// 尺寸写 0，真实尺寸只在数据后的描述符与中央目录里。
List<int> _buildDescriptorZip(
  String name,
  List<int> data, {
  required int method,
}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  final nameBytes = utf8.encode(name);
  final compressed = method == 8
      ? ZLibCodec(raw: true).encode(data)
      : data;
  final crc = crc32(data);
  out.add([0x50, 0x4B, 0x03, 0x04]);
  _u16(out, 20);
  _u16(out, 0x0800 | 0x08); // UTF-8 + bit 3：尺寸在数据描述符里
  _u16(out, method);
  _u16(out, 0);
  _u16(out, 0);
  _u32(out, 0);
  _u32(out, 0);
  _u32(out, 0);
  _u16(out, nameBytes.length);
  _u16(out, 0);
  out.add(nameBytes);
  out.add(compressed);
  out.add([0x50, 0x4B, 0x07, 0x08]); // 描述符签名
  _u32(out, crc);
  _u32(out, compressed.length);
  _u32(out, data.length);
  central.add([0x50, 0x4B, 0x01, 0x02]);
  _u16(central, 20);
  _u16(central, 20);
  _u16(central, 0x0800 | 0x08);
  _u16(central, method);
  _u16(central, 0);
  _u16(central, 0);
  _u32(central, crc);
  _u32(central, compressed.length);
  _u32(central, data.length);
  _u16(central, nameBytes.length);
  _u16(central, 0);
  _u16(central, 0);
  _u16(central, 0);
  _u16(central, 0);
  _u32(central, 0);
  _u32(central, 0);
  central.add(nameBytes);
  final centralOffset = out.length;
  final centralBytes = central.takeBytes();
  out.add(centralBytes);
  out.add([0x50, 0x4B, 0x05, 0x06]);
  _u16(out, 0);
  _u16(out, 0);
  _u16(out, 1);
  _u16(out, 1);
  _u32(out, centralBytes.length);
  _u32(out, centralOffset);
  _u16(out, 0);
  return out.takeBytes();
}

/// stored 方式打包（同 p3 的 buildStoredZip，带中央目录 + EOCD），
/// 供“中央/本地不一致”篡改测试用。
List<int> buildStoredZipForTest(List<(String, List<int>)> entries) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  for (final (name, data) in entries) {
    final nameBytes = utf8.encode(name);
    final offset = out.length;
    out.add([0x50, 0x4B, 0x03, 0x04]);
    _u16(out, 20);
    _u16(out, 0x0800);
    _u16(out, 0);
    _u16(out, 0);
    _u16(out, 0);
    _u32(out, crc32(data));
    _u32(out, data.length);
    _u32(out, data.length);
    _u16(out, nameBytes.length);
    _u16(out, 0);
    out.add(nameBytes);
    out.add(data);
    central.add([0x50, 0x4B, 0x01, 0x02]);
    _u16(central, 20);
    _u16(central, 20);
    _u16(central, 0x0800);
    _u16(central, 0);
    _u16(central, 0);
    _u16(central, 0);
    _u32(central, crc32(data));
    _u32(central, data.length);
    _u32(central, data.length);
    _u16(central, nameBytes.length);
    _u16(central, 0);
    _u16(central, 0);
    _u16(central, 0);
    _u16(central, 0);
    _u32(central, 0);
    _u32(central, offset);
    central.add(nameBytes);
  }
  final centralOffset = out.length;
  final centralBytes = central.takeBytes();
  out.add(centralBytes);
  out.add([0x50, 0x4B, 0x05, 0x06]);
  _u16(out, 0);
  _u16(out, 0);
  _u16(out, entries.length);
  _u16(out, entries.length);
  _u32(out, centralBytes.length);
  _u32(out, centralOffset);
  _u16(out, 0);
  return out.takeBytes();
}
