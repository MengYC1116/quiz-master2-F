// P3 收尾（§2.3 zip 备份 / §4.5 文件级联 + 孤儿清理 / §4.6 文件迁移 /
// 空间占用显示）：只用合成库（内存库 + 临时数据目录），不碰真实库。
// 迁移整机（关单例库 + 写 db_location.txt 标记）不进单测——单测里写
// 标记会改掉真实应用的库位置，见 S8B4-REPORT；整机迁移走 Xvfb 真机验证。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/import_service.dart';
import 'package:quiz_master2/services/zip_archive.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> openTestDb() async {
  sqfliteFfiInit();
  return databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, version) async => AppDatabase.createTables(db)));
}

Future<void> seedSubject(Database db, String id, String name) async {
  await db.insert('subjects', {
    'id': id,
    'name': name,
    'color': 0xFF2E7CF6,
    'cover_style': 'plain',
    'cover_color': 'blue',
  });
}

Future<void> seedQuestion(Database db,
    {required String id,
    required String subjectId,
    String? sourcePath,
    String? pageImagePath,
    String? slicePath,
    String folderIds = '[]',
    bool isDemo = false}) async {
  await db.insert('questions', {
    'id': id,
    'title': '题 $id',
    'subject_id': subjectId,
    'folder_ids': folderIds,
    'knowledge_ids': '[]',
    'error_types': '[]',
    'custom_error_types': '[]',
    'tags': '[]',
    'created_at': 1700000000000,
    'slice_kind': 'material',
    'slice_text': '',
    'source_path': sourcePath,
    'source_kind': sourcePath == null ? null : 'image',
    'source_page': sourcePath == null ? null : 1,
    'page_image_path': pageImagePath,
    'slice_path': slicePath,
    'is_demo': isDemo ? 1 : 0,
  });
}

Future<void> seedTask(Database db,
    {required String id, required String subjectId, String sourcePath = ''}) async {
  await db.insert('collect_tasks', {
    'id': id,
    'name': '任务 $id',
    'file_name': 'm.png',
    'subject_id': subjectId,
    'status': 'needBox',
    'progress': 100,
    'page_count': 1,
    'page': 1,
    'error': null,
    'question_id': null,
    'created_at': 1700000000000,
    'source_path': sourcePath,
    'page_rotations': '{}',
  });
}

Future<File> writeDataFile(Directory dataDir, String rel, List<int> bytes) async {
  final f = File(p.join(dataDir.path, rel));
  await f.parent.create(recursive: true);
  return f.writeAsBytes(bytes);
}

/// 手工拼一个 stored（method 0）ZIP：buildZip 只写合法名，
//  造“穿越条目”必须手写 local header；同时覆盖读侧 method 0 分支。
List<int> buildStoredZip(List<(String, List<int>)> entries) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  void u16(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(BytesBuilder b, int v) => b.add([
        v & 0xFF,
        (v >> 8) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 24) & 0xFF,
      ]);
  for (final (name, data) in entries) {
    final nameBytes = utf8.encode(name);
    final offset = out.length;
    out.add([0x50, 0x4B, 0x03, 0x04]);
    u16(out, 20);
    u16(out, 0x0800);
    u16(out, 0);
    u16(out, 0);
    u16(out, 0);
    u32(out, crc32(data));
    u32(out, data.length);
    u32(out, data.length);
    u16(out, nameBytes.length);
    u16(out, 0);
    out.add(nameBytes);
    out.add(data);
    central.add([0x50, 0x4B, 0x01, 0x02]);
    u16(central, 20);
    u16(central, 20);
    u16(central, 0x0800);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u32(central, crc32(data));
    u32(central, data.length);
    u32(central, data.length);
    u16(central, nameBytes.length);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u32(central, 0);
    u32(central, offset);
    central.add(nameBytes);
  }
  final centralOffset = out.length;
  final centralBytes = central.takeBytes();
  out.add(centralBytes);
  out.add([0x50, 0x4B, 0x05, 0x06]);
  u16(out, 0);
  u16(out, 0);
  u16(out, entries.length);
  u16(out, entries.length);
  u32(out, centralBytes.length);
  u32(out, centralOffset);
  u16(out, 0);
  return out.takeBytes();
}

void main() {
  group('P3 zip_archive', () {
    test('deflate 往返 + CRC 校验', () {
      final bytes = buildZip([
        ZipEntryData('backup.json', utf8.encode('{"a":1}')),
        ZipEntryData('slices/q1.png', List.filled(1000, 7)),
      ]);
      expect(isZipBytes(bytes), isTrue);
      final entries = readZip(bytes);
      expect(entries.map((e) => e.name),
          ['backup.json', 'slices/q1.png']);
      expect(utf8.decode(entries.first.bytes), '{"a":1}');
      expect(entries.last.bytes, List.filled(1000, 7));
    });

    test('stored（method 0）往返', () {
      final bytes = buildStoredZip([
        ('backup.json', utf8.encode('{"a":1}')),
      ]);
      expect(readZip(bytes).first.name, 'backup.json');
    });

    test('条目名校验：../、绝对路径、盘符拒绝，正常名通过', () {
      expect(validateZipEntryName('imports/t1/original.jpg'), isNull);
      expect(validateZipEntryName('../evil.txt'), isNotNull);
      expect(validateZipEntryName('a/../../evil.txt'), isNotNull);
      expect(validateZipEntryName('/abs/path.txt'), isNotNull);
      expect(validateZipEntryName(r'C:\evil.txt'), isNotNull);
      expect(validateZipEntryName(r'..\evil.txt'), isNotNull);
      expect(validateZipEntryName(''), isNotNull);
    });

    test('含穿越条目的 zip：整个包拒绝', () {
      final bytes = buildStoredZip([
        ('backup.json', utf8.encode('{"a":1}')),
        ('../evil.txt', utf8.encode('x')),
      ]);
      expect(() => readZip(bytes), throwsA(isA<ZipFormatException>()));
    });

    test('不是 zip：isZipBytes false，readZip 抛错', () {
      final json = utf8.encode('{"_meta":{}}');
      expect(isZipBytes(json), isFalse);
      expect(() => readZip(json), throwsA(isA<ZipFormatException>()));
    });
  });

  group('P3 §2.3 zip 备份/恢复', () {
    late Directory tmp;
    late Database db;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('p3-zip-');
      AppDatabase.testDataDirectory = tmp.path;
      db = await openTestDb();
      addTearDown(() async {
        AppDatabase.testDataDirectory = null;
        try {
          await db.close();
        } catch (_) {}
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      await seedSubject(db, 'math', '数学');
      await seedQuestion(db,
          id: 'q1',
          subjectId: 'math',
          sourcePath: 'imports/task-1/original.jpg',
          pageImagePath: 'imports/task-1/original.jpg',
          slicePath: 'slices/q1.png');
      await seedTask(db,
          id: 'task-1',
          subjectId: 'math',
          sourcePath: 'imports/task-1/original.jpg');
      await writeDataFile(
          tmp, 'imports/task-1/original.jpg', [1, 2, 3, 4, 5]);
      await writeDataFile(tmp, 'slices/q1.png', [9, 8, 7]);
      // 孤儿文件：不进备份。
      await writeDataFile(tmp, 'slices/orphan.png', [0]);
    });

    test('导出 zip 含 backup.json + 被引用的图，不含孤儿文件', () async {
      final zip = await AppDatabase.exportBackupZipFrom(db, dataDir: tmp.path);
      expect(isZipBytes(zip), isTrue);
      final names = readZip(zip).map((e) => e.name).toList();
      expect(
          names,
          containsAll([
            'backup.json',
            'imports/task-1/original.jpg',
            'slices/q1.png',
          ]));
      expect(names, isNot(contains('slices/orphan.png')));
      final data = AppDatabase.readBackupJsonFromZip(zip);
      expect((data['questions'] as List).length, 1);
      expect((data['subjects'] as List).length, 1);
    });

    test('zip 备份 → 删图删库 → 恢复 → 图回来（字节一致）', () async {
      final zip = await AppDatabase.exportBackupZipFrom(db, dataDir: tmp.path);
      await File(p.join(tmp.path, 'slices/q1.png')).delete();
      await File(p.join(tmp.path, 'imports/task-1/original.jpg')).delete();
      await db.delete('questions');
      await db.delete('collect_tasks');
      expect(await db.query('questions'), isEmpty);
      await AppDatabase.importBackupZipInto(db, zip, dataDir: tmp.path);
      expect((await db.query('questions')).length, 1);
      expect((await db.query('collect_tasks')).length, 1);
      expect(
          await File(p.join(tmp.path, 'slices/q1.png')).readAsBytes(),
          [9, 8, 7]);
      expect(
          await File(p.join(tmp.path, 'imports/task-1/original.jpg'))
              .readAsBytes(),
          [1, 2, 3, 4, 5]);
    });

    test('zip 路径穿越：拒绝整个包，原库不动、盘外不写文件', () async {
      final goodJson =
          await AppDatabase.exportBackupJsonFrom(db);
      final evil = buildStoredZip([
        ('backup.json', utf8.encode(goodJson)),
        ('../evil-p3.txt', utf8.encode('x')),
      ]);
      await expectLater(
          () => AppDatabase.importBackupZipInto(db, evil, dataDir: tmp.path),
          throwsA(isA<BackupRestoreException>()));
      expect((await db.query('questions')).length, 1);
      expect(File(p.join(tmp.parent.path, 'evil-p3.txt')).existsSync(),
          isFalse);
      expect(File(p.join(tmp.path, 'evil-p3.txt')).existsSync(), isFalse);
    });

    test('zip 缺 backup.json：拒绝，原库不动', () async {
      final zip = buildZip([ZipEntryData('slices/q1.png', [1])]);
      await expectLater(
          () => AppDatabase.importBackupZipInto(db, zip, dataDir: tmp.path),
          throwsA(isA<BackupRestoreException>()));
      expect((await db.query('questions')).length, 1);
    });

    test('zip 里 backup.json 版本 >2：拒绝，原库不动', () async {
      final bad = jsonDecode(await AppDatabase.exportBackupJsonFrom(db))
          as Map<String, dynamic>;
      (bad['_meta'] as Map)['schemaVersion'] = 99;
      final zip = buildZip([
        ZipEntryData('backup.json', utf8.encode(jsonEncode(bad))),
      ]);
      await expectLater(
          () => AppDatabase.importBackupZipInto(db, zip, dataDir: tmp.path),
          throwsA(isA<BackupRestoreException>()));
      expect((await db.query('questions')).length, 1);
    });

    test('zip 恢复失败回滚：DB 插不进去时，已移入的文件恢复原状', () async {
      // 目标已有同名切片（旧内容）；备份里的同名切片是新内容，
      // 但 backup.json 里有行缺 title（校验放行、入库时 NOT NULL
      // 失败）→ DB 导入失败 → 文件须回滚到旧内容。
      final zip = await AppDatabase.exportBackupZipFrom(db, dataDir: tmp.path);
      final entries = readZip(zip);
      final tampered = entries.map((e) {
        if (e.name != 'backup.json') return e;
        final data =
            jsonDecode(utf8.decode(e.bytes)) as Map<String, dynamic>;
        final questions = data['questions'] as List;
        (questions.first as Map).remove('title');
        return ZipEntryData(e.name, utf8.encode(jsonEncode(data)));
      }).toList();
      final badZip = buildZip(tampered);
      await File(p.join(tmp.path, 'slices/q1.png')).writeAsBytes([5, 5, 5]);
      await expectLater(
          () => AppDatabase.importBackupZipInto(db, badZip, dataDir: tmp.path),
          throwsA(isA<BackupRestoreException>()));
      expect(
          await File(p.join(tmp.path, 'slices/q1.png')).readAsBytes(),
          [5, 5, 5]);
      expect((await db.query('questions')).length, 1);
    });

    test('老 JSON 备份（.qm2backup 内容是 JSON）仍能走通', () async {
      final json = await AppDatabase.exportBackupJsonFrom(db);
      expect(isZipBytes(utf8.encode(json)), isFalse);
      await db.delete('questions');
      final data = jsonDecode(json) as Map<String, dynamic>;
      await AppDatabase.importBackupJsonInto(db, data);
      expect((await db.query('questions')).length, 1);
      expect(
          await File(p.join(tmp.path, 'slices/q1.png')).readAsBytes(),
          [9, 8, 7]);
    });
  });

  group('P3 §4.5 文件级联', () {
    late Directory tmp;
    late Database db;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('p3-cascade-');
      AppDatabase.testDataDirectory = tmp.path;
      db = await openTestDb();
      addTearDown(() async {
        AppDatabase.testDataDirectory = null;
        try {
          await db.close();
        } catch (_) {}
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      await seedSubject(db, 'math', '数学');
      await seedSubject(db, 'eng', '英语');
      await seedQuestion(db,
          id: 'q1',
          subjectId: 'math',
          sourcePath: 'imports/task-1/original.jpg',
          pageImagePath: 'imports/task-1/original.jpg',
          slicePath: 'slices/q1.png');
      await seedTask(db,
          id: 'task-1',
          subjectId: 'math',
          sourcePath: 'imports/task-1/original.jpg');
      await seedQuestion(db,
          id: 'q2',
          subjectId: 'eng',
          sourcePath: 'imports/task-2/original.jpg',
          pageImagePath: 'imports/task-2/original.jpg',
          slicePath: 'slices/q2.png');
      await seedTask(db,
          id: 'task-2',
          subjectId: 'eng',
          sourcePath: 'imports/task-2/original.jpg');
      await writeDataFile(tmp, 'imports/task-1/original.jpg', [1]);
      await writeDataFile(tmp, 'slices/q1.png', [2]);
      await writeDataFile(tmp, 'imports/task-2/original.jpg', [3]);
      await writeDataFile(tmp, 'slices/q2.png', [4]);
    });

    test('删题：切片删掉，共享页图保留，任务行保留', () async {
      await AppDatabase.deleteQuestionFrom(db, 'q1');
      expect(await db.query('questions'), hasLength(1));
      expect(File(p.join(tmp.path, 'slices/q1.png')).existsSync(), isFalse);
      expect(File(p.join(tmp.path, 'imports/task-1/original.jpg'))
          .existsSync(), isTrue);
      expect((await db.query('collect_tasks')).length, 2);
    });

    test('删学科：该科切片与任务目录删掉，别科的文件不动', () async {
      await AppDatabase.deleteSubjectFrom(db, 'math');
      expect(File(p.join(tmp.path, 'slices/q1.png')).existsSync(), isFalse);
      expect(Directory(p.join(tmp.path, 'imports/task-1')).existsSync(),
          isFalse);
      expect(File(p.join(tmp.path, 'slices/q2.png')).existsSync(), isTrue);
      expect(Directory(p.join(tmp.path, 'imports/task-2')).existsSync(),
          isTrue);
      expect((await db.query('subjects')).length, 1);
    });

    test('删任务：已确认拆题（页图被题引用）保留目录，无引用删目录', () async {
      await AppDatabase.deleteCollectTaskFrom(db, 'task-1');
      expect(Directory(p.join(tmp.path, 'imports/task-1')).existsSync(),
          isTrue);
      await db.delete('questions', where: 'id = ?', whereArgs: ['q2']);
      await AppDatabase.deleteCollectTaskFrom(db, 'task-2');
      expect(Directory(p.join(tmp.path, 'imports/task-2')).existsSync(),
          isFalse);
    });

    test('删文件夹：单文件夹的题切片删掉，多文件夹的题切片保留', () async {
      await db.insert('folders', {
        'id': 'f1',
        'name': '试卷',
        'subject_id': 'math',
        'parent_id': null,
        'sort_order': 0,
      });
      await db.update('questions', {'folder_ids': '["f1"]'},
          where: 'id = ?', whereArgs: ['q1']);
      await db.update('questions', {'folder_ids': '["f1","f-other"]'},
          where: 'id = ?', whereArgs: ['q2']);
      final deleted = await AppDatabase.deleteFolderFrom(
          db, Folder(id: 'f1', name: '试卷', subjectId: 'math'));
      expect(deleted, 1);
      expect(File(p.join(tmp.path, 'slices/q1.png')).existsSync(), isFalse);
      expect(File(p.join(tmp.path, 'slices/q2.png')).existsSync(), isTrue);
    });
  });

  group('P3 §4.5 孤儿清理', () {
    late Directory tmp;
    late Database db;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('p3-orphan-');
      AppDatabase.testDataDirectory = tmp.path;
      db = await openTestDb();
      addTearDown(() async {
        AppDatabase.testDataDirectory = null;
        try {
          await db.close();
        } catch (_) {}
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      await seedSubject(db, 'math', '数学');
      await seedQuestion(db,
          id: 'q1',
          subjectId: 'math',
          sourcePath: 'imports/task-1/original.jpg',
          pageImagePath: 'imports/task-1/original.jpg',
          slicePath: 'slices/q1.png');
      await seedTask(db,
          id: 'task-1',
          subjectId: 'math',
          sourcePath: 'imports/task-1/original.jpg');
      await writeDataFile(tmp, 'imports/task-1/original.jpg', [1, 2]);
      await writeDataFile(tmp, 'slices/q1.png', [3]);
      await writeDataFile(tmp, 'imports/task-1/extra.png', [4, 5, 6]);
      await writeDataFile(tmp, 'imports/task-9/original.jpg', [7]);
      await writeDataFile(tmp, 'slices/orphan.png', [8, 9]);
    });

    test('扫描：只列无引用文件，带字节数；在用文件不在列', () async {
      final scan =
          await AppDatabase.scanOrphanFilesFrom(db, dataDir: tmp.path);
      expect(
          scan.files.map((f) => f.relativePath).toList(),
          [
            'imports/task-1/extra.png',
            'imports/task-9/original.jpg',
            'slices/orphan.png',
          ]);
      expect(scan.totalBytes, 3 + 1 + 2);
      expect(
          scan.files
              .firstWhere((f) => f.relativePath == 'slices/orphan.png')
              .bytes,
          2);
    });

    test('清理：只删无引用文件，在用文件保留，空任务目录顺带清掉', () async {
      final scan =
          await AppDatabase.scanOrphanFilesFrom(db, dataDir: tmp.path);
      final result = await AppDatabase.deleteOrphanFiles(
          scan.files.map((f) => f.relativePath).toList(),
          dataDir: tmp.path);
      expect(result.deletedCount, 3);
      expect(result.freedBytes, 6);
      expect(File(p.join(tmp.path, 'imports/task-1/original.jpg'))
          .existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'slices/q1.png')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'slices/orphan.png')).existsSync(),
          isFalse);
      expect(Directory(p.join(tmp.path, 'imports/task-9')).existsSync(),
          isFalse);
      expect(Directory(p.join(tmp.path, 'imports/task-1')).existsSync(),
          isTrue);
    });

    test('清理：越界路径与 imports/slices 外路径不删', () async {
      final outside =
          await writeDataFile(tmp, 'evil.txt', [1]);
      final result = await AppDatabase.deleteOrphanFiles(
          ['../evil.txt', 'evil.txt', '/abs.txt'],
          dataDir: tmp.path);
      expect(result.deletedCount, 0);
      expect(outside.existsSync(), isTrue);
    });
  });

  group('P3 §4.6 文件迁移（migrateDataFiles，不碰标记）', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('p3-migrate-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
    });

    Future<Directory> sourceWithFiles() async {
      final src = Directory(p.join(tmp.path, 'src'));
      await writeDataFile(src, 'quiz-master2.db', utf8.encode('db-bytes'));
      await writeDataFile(
          src, 'imports/task-1/original.jpg', [1, 2, 3]);
      await writeDataFile(src, 'imports/task-1/page-normalized.png', [4]);
      await writeDataFile(src, 'slices/q1.png', [5, 6]);
      return src;
    }

    test('搬库后图还在：库 + imports + slices 都在，字节一致，源不动',
        () async {
      final src = await sourceWithFiles();
      final dst = p.join(tmp.path, 'dst');
      final progress = <double>[];
      final outcome = await AppDatabase.migrateDataFiles(src.path, dst,
          onProgress: progress.add);
      expect(outcome, DbMigrationOutcome.migrated);
      expect(progress.last, 1.0);
      expect(File(p.join(dst, 'quiz-master2.db')).readAsStringSync(),
          'db-bytes');
      expect(
          await File(p.join(dst, 'imports/task-1/original.jpg'))
              .readAsBytes(),
          [1, 2, 3]);
      expect(await File(p.join(dst, 'slices/q1.png')).readAsBytes(), [5, 6]);
      // 源不动。
      expect(File(p.join(src.path, 'quiz-master2.db')).existsSync(), isTrue);
      // 无 staging 残留。
      expect(
          tmp
              .listSync()
              .where((e) => p.basename(e.path).contains('staging'))
              .toList(),
          isEmpty);
    });

    test('目标库覆盖失败回滚：悬空链接导致复制失败，目标旧库与旧图不动',
        () async {
      final src = await sourceWithFiles();
      // 悬空符号链接：复制时抛错。
      final badLink = Link(p.join(src.path, 'imports/task-1/broken.jpg'));
      await badLink.create(p.join(src.path, 'no-such-target.jpg'));
      final dst = p.join(tmp.path, 'dst');
      await Directory(dst).create(recursive: true);
      await File(p.join(dst, 'quiz-master2.db')).writeAsString('sentinel-db');
      await writeDataFile(
          Directory(dst), 'slices/q1.png', [9, 9, 9]);
      final outcome = await AppDatabase.migrateDataFiles(src.path, dst,
          overwrite: true);
      expect(outcome, DbMigrationOutcome.failed);
      expect(File(p.join(dst, 'quiz-master2.db')).readAsStringSync(),
          'sentinel-db');
      expect(await File(p.join(dst, 'slices/q1.png')).readAsBytes(),
          [9, 9, 9]);
      // 无 .old 残留、无 staging 残留。
      expect(
          Directory(dst)
              .listSync()
              .where((e) => p.basename(e.path).contains('.old-'))
              .toList(),
          isEmpty);
      expect(
          tmp
              .listSync()
              .where((e) => p.basename(e.path).contains('staging'))
              .toList(),
          isEmpty);
    });

    test('取消：停在当前文件，目标不建库，源不动，无 staging 残留', () async {
      final src = await sourceWithFiles();
      final dst = p.join(tmp.path, 'dst');
      var calls = 0;
      final outcome = await AppDatabase.migrateDataFiles(src.path, dst,
          onProgress: (_) => calls++,
          isCancelled: () => calls >= 1);
      expect(outcome, DbMigrationOutcome.cancelled);
      expect(File(p.join(dst, 'quiz-master2.db')).existsSync(), isFalse);
      expect(File(p.join(src.path, 'quiz-master2.db')).existsSync(), isTrue);
      expect(
          tmp
              .listSync()
              .where((e) => p.basename(e.path).contains('staging'))
              .toList(),
          isEmpty);
    });

    test('目标已有库且不覆盖：返回 targetExists，目标不动', () async {
      final src = await sourceWithFiles();
      final dst = p.join(tmp.path, 'dst');
      await Directory(dst).create(recursive: true);
      await File(p.join(dst, 'quiz-master2.db')).writeAsString('existing');
      expect(await AppDatabase.migrateDataFiles(src.path, dst),
          DbMigrationOutcome.targetExists);
      expect(File(p.join(dst, 'quiz-master2.db')).readAsStringSync(),
          'existing');
    });

    test('同一位置：返回 sameLocation', () async {
      final src = await sourceWithFiles();
      expect(await AppDatabase.migrateDataFiles(src.path, src.path),
          DbMigrationOutcome.sameLocation);
    });
  });

  group('P3 空间占用显示', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('p3-storage-');
      AppDatabase.testDataDirectory = tmp.path;
      addTearDown(() async {
        AppDatabase.testDataDirectory = null;
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
    });

    test('分项统计：imports 与 slices 各算各的', () async {
      await writeDataFile(tmp, 'imports/task-1/original.jpg', [1, 2, 3]);
      await writeDataFile(tmp, 'slices/q1.png', [4, 5]);
      final usage = await ImportService.storageUsageBreakdown();
      expect(usage.importsBytes, 3);
      expect(usage.slicesBytes, 2);
      expect(await ImportService.storageUsageBytes(), 5);
    });

    test('上限提示：超 2GB 才提示，不超返回 null', () {
      expect(
          ImportService.storageLimitMessage(
              ImportService.maxStorageBytes + 1),
          contains('2GB'));
      expect(ImportService.storageLimitMessage(100), isNull);
      expect(ImportService.storageLimitMessage(
          ImportService.maxStorageBytes), isNull);
    });

    test('formatBytes', () {
      expect(ImportService.formatBytes(512), '512 B');
      expect(ImportService.formatBytes(2048), '2.0 KB');
      expect(ImportService.formatBytes(3 * 1024 * 1024), '3.0 MB');
    });
  });
}
