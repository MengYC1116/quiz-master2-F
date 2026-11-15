// B3-P01 路径删除安全 + _openDb fallback 收窄 + copyDatabaseFileTo
// 删除 + 测试钩子 + 详情页重框单事务 回归测试。
//
// 除 `_openDb fallback 收窄` 组外全部用 AppDatabase.openForTest()
// 打开的内存库（只建表，不播种演示数据），不碰真实库；文件级
// 断言用的数据目录是 testDataDirectory 指向的临时目录。
// `_openDb` 组用单例 + testDataDirectory 指向的临时目录，
// setUp/tearDown 调 resetForTest() 复位单例。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/zip_archive.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> insertQuestion(
  Database db,
  String id, {
  String subjectId = 'math',
  String? sourcePath,
  String? pageImagePath,
  String? slicePath,
  int? sliceWidth,
  int? sliceHeight,
}) async {
  await db.insert('questions', {
    'id': id,
    'title': 't-$id',
    'subject_id': subjectId,
    'folder_ids': '',
    'created_at': 1000,
    'source_path': sourcePath,
    'page_image_path': pageImagePath,
    'slice_path': slicePath,
    'slice_width': sliceWidth,
    'slice_height': sliceHeight,
  });
}

QuestionBox layer1Box(String id, {String? questionId}) => QuestionBox(
  id: id,
  layer: 1,
  type: 'question',
  x: 0.1,
  y: 0.1,
  w: 0.5,
  h: 0.3,
  questionId: questionId,
);

void main() {
  group('B3-P01 resolveDataPath：生产路径禁绝对路径', () {
    late Directory tmp;
    late String? prevDataDir;

    setUp(() async {
      prevDataDir = AppDatabase.testDataDirectory;
      tmp = await Directory.systemTemp.createTemp('b3-p01-resolve-');
      AppDatabase.testDataDirectory = tmp.path;
      addTearDown(() async {
        AppDatabase.testDataDirectory = prevDataDir;
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
    });

    test('绝对路径默认拒绝（返回 null）', () {
      final abs = p.join(tmp.path, 'slices', 'q1.png');
      expect(AppDatabase.resolveDataPath(abs), isNull);
    });

    test('绝对路径显式 allowAbsolute 才放行（测试例外通道）', () {
      final abs = p.join(tmp.path, 'slices', 'q1.png');
      expect(
        AppDatabase.resolveDataPath(abs, allowAbsolute: true),
        p.normalize(abs),
      );
    });

    test('相对路径拼上 testDataDirectory', () {
      expect(
        AppDatabase.resolveDataPath('slices/q1.png'),
        p.join(tmp.path, 'slices', 'q1.png'),
      );
    });

    test('`..` 越出数据目录返回 null', () {
      expect(AppDatabase.resolveDataPath('../evil.png'), isNull);
      expect(AppDatabase.resolveDataPath('slices/../../evil.png'), isNull);
      expect(AppDatabase.resolveDataPath('/etc/passwd'), isNull);
    });
  });

  group('B3-P01 _deleteDataFileIfUnreferenced：只删 slices/ 下文件', () {
    late Directory tmp;
    late Directory dataDir;
    late Database db;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('b3-p01-delfile-');
      dataDir = Directory(p.join(tmp.path, 'data'));
      await Directory(p.join(dataDir.path, 'slices')).create(recursive: true);
      await Directory(p.join(dataDir.path, 'imports')).create(recursive: true);
      AppDatabase.testDataDirectory = dataDir.path;
      db = await AppDatabase.openForTest();
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
        AppDatabase.testDataDirectory = null;
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
    });

    test('绝对路径切片：删题也不删盘上文件（旧实现会删）', () async {
      final evil = File(p.join(tmp.path, 'evil.png'));
      await evil.writeAsBytes([1, 2, 3]);
      await insertQuestion(db, 'q1', slicePath: evil.path);
      await AppDatabase.deleteQuestionFrom(db, 'q1');
      expect(await db.query('questions'), isEmpty);
      expect(evil.existsSync(), isTrue, reason: '绝对路径绝不能删');
    });

    test('imports/ 下的“切片”：删题也不删（只接受 slices/ 前缀）', () async {
      final evil = File(p.join(dataDir.path, 'imports', 'evil.png'));
      await evil.writeAsBytes([1, 2, 3]);
      await insertQuestion(db, 'q1', slicePath: 'imports/evil.png');
      await AppDatabase.deleteQuestionFrom(db, 'q1');
      expect(evil.existsSync(), isTrue, reason: '非 slices/ 前缀拒绝删除');
    });

    test('`..` 越界的切片路径：不删', () async {
      final evil = File(p.join(tmp.path, 'evil2.png'));
      await evil.writeAsBytes([1, 2, 3]);
      await insertQuestion(db, 'q1', slicePath: '../evil2.png');
      await AppDatabase.deleteQuestionFrom(db, 'q1');
      expect(evil.existsSync(), isTrue);
    });

    test('合法 slices/ 切片无引用时照常删除', () async {
      final slice = File(p.join(dataDir.path, 'slices', 'q1.png'));
      await slice.writeAsBytes([1, 2, 3]);
      await insertQuestion(db, 'q1', slicePath: 'slices/q1.png');
      await AppDatabase.deleteQuestionFrom(db, 'q1');
      expect(slice.existsSync(), isFalse);
    });

    test('仍被他题引用的切片不删', () async {
      final slice = File(p.join(dataDir.path, 'slices', 'shared.png'));
      await slice.writeAsBytes([1, 2, 3]);
      await insertQuestion(db, 'q1', slicePath: 'slices/shared.png');
      await insertQuestion(db, 'q2', slicePath: 'slices/shared.png');
      await AppDatabase.deleteQuestionFrom(db, 'q1');
      expect(slice.existsSync(), isTrue);
      expect((await db.query('questions')).single['id'], 'q2');
    });
  });

  group('B3-P01 _deleteTaskDirIfUnreferenced：taskId 安全字符校验', () {
    late Directory tmp;
    late Directory dataDir;
    late Database db;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('b3-p01-deltask-');
      dataDir = Directory(p.join(tmp.path, 'data'));
      await Directory(p.join(dataDir.path, 'slices')).create(recursive: true);
      await Directory(p.join(dataDir.path, 'imports')).create(recursive: true);
      AppDatabase.testDataDirectory = dataDir.path;
      db = await AppDatabase.openForTest();
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
        AppDatabase.testDataDirectory = null;
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
    });

    Future<void> insertTask(String id) async {
      await AppDatabase.upsertCollectTaskInto(
        db,
        CollectTask(id: id, name: id, fileName: '$id.png', subjectId: 'math'),
      );
    }

    test('`../slices` taskId：不删 slices 目录（旧实现会整目录删掉）', () async {
      final keep = File(p.join(dataDir.path, 'slices', 'keep.png'));
      await keep.writeAsBytes([1, 2, 3]);
      await insertTask('../slices');
      await AppDatabase.deleteCollectTaskFrom(db, '../slices');
      expect(keep.existsSync(), isTrue, reason: '恶意 taskId 必须被拦下');
      expect(await db.query('collect_tasks'), isEmpty);
    });

    test('含 `/`、`%` 的 taskId 同样被拦', () async {
      final keep = File(p.join(dataDir.path, 'slices', 'keep2.png'));
      await keep.writeAsBytes([1, 2, 3]);
      for (final badId in ['a/b', 'a%b', '..', '', 'a b']) {
        await insertTask(badId);
        await AppDatabase.deleteCollectTaskFrom(db, badId);
        expect(keep.existsSync(), isTrue, reason: 'taskId=$badId 应被拦');
      }
    });

    test('合法 taskId 的无引用目录照常删除', () async {
      final dir = Directory(p.join(dataDir.path, 'imports', 'task1'));
      await dir.create(recursive: true);
      await File(p.join(dir.path, 'original.png')).writeAsBytes([1]);
      await insertTask('task1');
      await AppDatabase.deleteCollectTaskFrom(db, 'task1');
      expect(dir.existsSync(), isFalse);
    });

    test('仍被题引用的任务目录不删', () async {
      final dir = Directory(p.join(dataDir.path, 'imports', 'task2'));
      await dir.create(recursive: true);
      await File(p.join(dir.path, 'original.png')).writeAsBytes([1]);
      await insertTask('task2');
      await insertQuestion(
        db,
        'q1',
        sourcePath: 'imports/task2/original.png',
      );
      await AppDatabase.deleteCollectTaskFrom(db, 'task2');
      expect(dir.existsSync(), isTrue);
    });
  });

  group('B3-P01 备份恢复：非法文件路径拒绝整个恢复', () {
    late Directory tmp;
    late Database db;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('b3-p01-backup-');
      db = await AppDatabase.openForTest();
      await db.insert('subjects', {
        'id': 'math',
        'name': '数学',
        'color': 0xFF000000,
      });
      await insertQuestion(
        db,
        'q1',
        sourcePath: 'imports/task1/original.png',
        pageImagePath: 'imports/task1/pages/page-001.png',
        slicePath: 'slices/q1.png',
      );
      await AppDatabase.upsertCollectTaskInto(
        db,
        CollectTask(
          id: 'task1',
          name: 'task1',
          fileName: 'original.png',
          subjectId: 'math',
          sourcePath: 'imports/task1/original.png',
        ),
      );
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
    });

    Future<Map<String, dynamic>> exported() async =>
        jsonDecode(await AppDatabase.exportBackupJsonFrom(db))
            as Map<String, dynamic>;

    Future<void> expectRejected(
      Map<String, dynamic> data,
      String reason,
    ) async {
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, data),
        throwsA(isA<BackupRestoreException>()),
        reason: reason,
      );
      // 原库不动。
      expect(await db.query('questions'), hasLength(1));
      expect(
        (await db.query('questions')).single['slice_path'],
        'slices/q1.png',
      );
    }

    test('slice_path 是绝对路径：拒绝恢复', () async {
      final data = await exported();
      (data['questions'] as List).first['slice_path'] = '/tmp/evil.png';
      await expectRejected(data, '绝对路径备份必须拒绝');
    });

    test('source_path 含 `..` 穿越：拒绝恢复', () async {
      final data = await exported();
      (data['questions'] as List).first['source_path'] =
          'imports/../../etc/passwd';
      await expectRejected(data, '穿越路径备份必须拒绝');
    });

    test('page_image_path 在其它目录：拒绝恢复', () async {
      final data = await exported();
      (data['questions'] as List).first['page_image_path'] = 'data/q.png';
      await expectRejected(data, '非 imports//slices/ 路径必须拒绝');
    });

    test('collect_tasks source_path 是 Windows 绝对路径：拒绝恢复', () async {
      final data = await exported();
      (data['collect_tasks'] as List).first['source_path'] =
          r'C:\Users\evil\secret.png';
      await expectRejected(data, '盘符绝对路径备份必须拒绝');
    });

    test('合法相对路径：恢复成功', () async {
      final data = await exported();
      await db.delete('questions');
      expect(await db.query('questions'), isEmpty);
      await AppDatabase.importBackupJsonInto(db, data);
      final rows = await db.query('questions');
      expect(rows, hasLength(1));
      expect(rows.single['slice_path'], 'slices/q1.png');
    });

    test('zip 备份：JSON 里路径非法，文件一步都不进位', () async {
      final data = await exported();
      (data['questions'] as List).first['slice_path'] = '/tmp/evil.png';
      final zip = buildZip([
        ZipEntryData('backup.json', utf8.encode(jsonEncode(data))),
        ZipEntryData('slices/q1.png', [1, 2, 3]),
      ]);
      await expectLater(
        () => AppDatabase.importBackupZipInto(db, zip, dataDir: tmp.path),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(await db.query('questions'), hasLength(1));
      expect(
        File(p.join(tmp.path, 'slices', 'q1.png')).existsSync(),
        isFalse,
        reason: '校验不过时 zip 文件条目不许进位',
      );
    });
  });

  group('B3-P01 详情页重框：换框 + 保存切片一个事务', () {
    late Database db;

    setUp(() async {
      db = await AppDatabase.openForTest();
      await insertQuestion(
        db,
        'q1',
        slicePath: 'slices/old.png',
        sliceWidth: 100,
        sliceHeight: 50,
      );
      await db.insert('question_boxes', {
        'id': 'box-old-p1-aaaa0001',
        'collect_task_id': null,
        'question_id': 'q1',
        'parent_box_id': null,
        'page': 1,
        'layer': 1,
        'type': 'question',
        'x': 0.0,
        'y': 0.0,
        'w': 0.4,
        'h': 0.2,
        'confidence': null,
        'origin': 'manual',
        'updated_at': 1000,
      });
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
      });
    });

    test('成功：旧框被换掉，切片字段一起更新', () async {
      await AppDatabase.replaceQuestionBoxesAndSliceInto(
        db,
        questionId: 'q1',
        boxes: [layer1Box('box-new-p1-aaaa0002', questionId: 'q1')],
        slicePath: 'slices/q1.png',
        sliceWidth: 200,
        sliceHeight: 80,
      );
      final boxes = await AppDatabase.boxesForQuestionFrom(db, 'q1');
      expect(boxes.map((b) => b.id).toList(), ['box-new-p1-aaaa0002']);
      final q = (await db.query('questions')).single;
      expect(q['slice_path'], 'slices/q1.png');
      expect(q['slice_width'], 200);
      expect(q['slice_height'], 80);
    });

    test('写切片中途失败：旧框与旧切片整体回滚', () async {
      await db.execute(
        "CREATE TRIGGER trg_fail_qup BEFORE UPDATE ON questions "
        "BEGIN SELECT RAISE(ABORT, 'boom'); END;",
      );
      await expectLater(
        () => AppDatabase.replaceQuestionBoxesAndSliceInto(
          db,
          questionId: 'q1',
          boxes: [layer1Box('box-new-p1-aaaa0002', questionId: 'q1')],
          slicePath: 'slices/q1.png',
          sliceWidth: 200,
          sliceHeight: 80,
        ),
        throwsA(anything),
      );
      // 回滚：旧框还在、新框没进、切片字段没变。
      final boxes = await AppDatabase.boxesForQuestionFrom(db, 'q1');
      expect(boxes.map((b) => b.id).toList(), ['box-old-p1-aaaa0001']);
      final q = (await db.query('questions')).single;
      expect(q['slice_path'], 'slices/old.png');
      expect(q['slice_width'], 100);
      expect(q['slice_height'], 50);
    });

    test('题不存在：抛错，旧框不动', () async {
      await expectLater(
        () => AppDatabase.replaceQuestionBoxesAndSliceInto(
          db,
          questionId: 'no-such',
          boxes: [layer1Box('box-new-p1-aaaa0002', questionId: 'no-such')],
          slicePath: 'slices/no-such.png',
          sliceWidth: 200,
          sliceHeight: 80,
        ),
        throwsA(isA<StateError>()),
      );
      final boxes = await AppDatabase.boxesForQuestionFrom(db, 'q1');
      expect(boxes.map((b) => b.id).toList(), ['box-old-p1-aaaa0001']);
      expect(await AppDatabase.boxesForQuestionFrom(db, 'no-such'), isEmpty);
    });
  });

  group('B3-P01 测试钩子 openForTest', () {
    test('内存库：建表可用、无演示数据', () async {
      final db = await AppDatabase.openForTest();
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
      });
      expect(await db.query('questions'), isEmpty);
      await insertQuestion(db, 'q1');
      expect((await db.query('questions')).single['id'], 'q1');
    });

    test('文件库：写到指定路径，关闭重开数据还在', () async {
      final tmp = await Directory.systemTemp.createTemp('b3-p01-open-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final path = p.join(tmp.path, 'test.db');
      final db = await AppDatabase.openForTest(path: path);
      await insertQuestion(db, 'q1');
      await db.close();
      expect(File(path).existsSync(), isTrue);
      final reopened = await AppDatabase.openForTest(path: path);
      addTearDown(() async {
        try {
          await reopened.close();
        } catch (_) {}
      });
      expect((await reopened.query('questions')).single['id'], 'q1');
    });
  });

  group('B3-P01 _openDb fallback 收窄', () {
    late Directory tmp;
    late String? prevDataDir;

    setUp(() async {
      prevDataDir = AppDatabase.testDataDirectory;
      await AppDatabase.resetForTest();
      tmp = await Directory.systemTemp.createTemp('b3-p01-opendb-');
      AppDatabase.testDataDirectory = tmp.path;
    });

    tearDown(() async {
      await AppDatabase.resetForTest();
      AppDatabase.testDataDirectory = prevDataDir;
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('损坏的库文件：明确报错，不静默建空库', () async {
      await File(
        p.join(tmp.path, 'quiz-master2.db'),
      ).writeAsBytes(utf8.encode('this is not a sqlite database'));
      final fallbackDir = Directory(
        p.join(p.dirname(Platform.resolvedExecutable), 'data'),
      );
      final fallbackExisted = fallbackDir.existsSync();
      await expectLater(
        () => AppDatabase.instance.db,
        throwsA(isA<LegacyDatabaseException>()),
      );
      // 没采用任何库：dbPathUsed 仍是 null（没滑入 fallback）。
      expect(AppDatabase.instance.dbPathUsed, isNull);
      // 失败的 Future 不被缓存：再调一次仍报错（不是静默成功的空库）。
      await expectLater(
        () => AppDatabase.instance.db,
        throwsA(isA<LegacyDatabaseException>()),
      );
      if (!fallbackExisted) {
        expect(fallbackDir.existsSync(), isFalse);
      }
    });

    test('shouldFallbackAfterOpenFailure：有库文件不回退、无库文件才回退', () {
      final dbPath = p.join(tmp.path, 'quiz-master2.db');
      expect(AppDatabase.shouldFallbackAfterOpenFailure(dbPath), isTrue);
      File(dbPath).writeAsStringSync('x');
      expect(AppDatabase.shouldFallbackAfterOpenFailure(dbPath), isFalse);
    });
  });
}
