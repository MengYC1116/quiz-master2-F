// SR-P0-1 回归：孤儿扫描不得把存续收集任务的派生文件当孤儿。
// 未拆分的 PDF 任务只有 source_path（imports/<id>/original.pdf），
// 渲染出的页图在 imports/<id>/pages/；图片任务的 EXIF 归一化副本在
// imports/<id>/page-normalized.png。两者都没有任何行引用，旧口径
// 会把它们列为孤儿，设置页一键清理即删掉任务页图。
// 只用合成库（内存库 + 临时数据目录），不碰真实库。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> openTestDb() async {
  sqfliteFfiInit();
  return databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, version) async => AppDatabase.createTables(db)));
}

Future<void> seedTask(Database db,
    {required String id, required String sourcePath}) async {
  await db.insert('collect_tasks', {
    'id': id,
    'name': '任务 $id',
    'file_name': 'm.pdf',
    'subject_id': 'math',
    'status': 'needBox',
    'progress': 100,
    'page_count': 2,
    'page': 1,
    'error': null,
    'question_id': null,
    'created_at': 1700000000000,
    'source_path': sourcePath,
    'page_rotations': '{}',
  });
}

File writeDataFile(Directory tmp, String rel, List<int> bytes) {
  final f = File(p.join(tmp.path, rel))..createSync(recursive: true);
  f.writeAsBytesSync(bytes);
  return f;
}

void main() {
  late Directory tmp;
  late Database db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('b5-p0-1-orphan-');
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
    await db.insert('subjects', {
      'id': 'math',
      'name': '数学',
      'color': 0xFF2E7CF6,
      'cover_style': 'plain',
      'cover_color': 'blue',
    });
  });

  test('SR-P0-1：needBox 的 PDF 任务，页图不在孤儿列表里', () async {
    await seedTask(db,
        id: 'pdf-task', sourcePath: 'imports/pdf-task/original.pdf');
    writeDataFile(tmp, 'imports/pdf-task/original.pdf', [1]);
    writeDataFile(tmp, 'imports/pdf-task/pages/page-001.png', [2]);
    writeDataFile(tmp, 'imports/pdf-task/pages/page-002.png', [3]);
    final scan = await AppDatabase.scanOrphanFilesFrom(db, dataDir: tmp.path);
    expect(scan.files, isEmpty);
  });

  test('SR-P0-1：图片任务的 page-normalized.png 不在孤儿列表里', () async {
    await seedTask(db,
        id: 'img-task', sourcePath: 'imports/img-task/original.jpg');
    writeDataFile(tmp, 'imports/img-task/original.jpg', [1]);
    writeDataFile(tmp, 'imports/img-task/page-normalized.png', [2]);
    final scan = await AppDatabase.scanOrphanFilesFrom(db, dataDir: tmp.path);
    expect(scan.files, isEmpty);
  });

  test('SR-P0-1：真孤儿仍被列出，存续任务目录里的杂文件仍是孤儿', () async {
    await seedTask(db,
        id: 'pdf-task', sourcePath: 'imports/pdf-task/original.pdf');
    writeDataFile(tmp, 'imports/pdf-task/original.pdf', [1]);
    writeDataFile(tmp, 'imports/pdf-task/pages/page-001.png', [2]);
    // 任务目录里的杂文件：不在 pages/，不是 page-normalized.png。
    writeDataFile(tmp, 'imports/pdf-task/extra.png', [3]);
    // 已删任务残留的目录：没有任何任务行。
    writeDataFile(tmp, 'imports/gone-task/original.jpg', [4]);
    writeDataFile(tmp, 'slices/orphan.png', [5]);
    final scan = await AppDatabase.scanOrphanFilesFrom(db, dataDir: tmp.path);
    expect(
        scan.files.map((f) => f.relativePath).toList(),
        [
          'imports/gone-task/original.jpg',
          'imports/pdf-task/extra.png',
          'slices/orphan.png',
        ]);
  });
}
