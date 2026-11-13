// S8 B4.2 / B4.3：备份补 4 张表（导出 + 恢复往返）、库文件迁移复制。
// 备份往返用演示库的临时副本做（只读复制，不碰真实库）；迁移复制
// 只用临时目录里的文件。B4.3 的整机迁移（关库 + 写标记）不进单测，
// 见 S8B4-REPORT.md 的真机验证——单测里写标记会改掉真实应用的库位置。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('B4.2 backupTables', () {
    test('含补齐的 4 张表，共 12 张', () {
      expect(AppDatabase.backupTables, containsAll([
        'collect_tasks',
        'review_state',
        'review_history',
        'recent_tasks',
      ]));
      expect(AppDatabase.backupTables.length, 12);
    });
  });

  group('B4.2 备份导出 + 恢复往返（演示库临时副本）', () {
    late Directory tmp;
    late Database db;
    late String copyPath;

    setUp(() async {
      sqfliteFfiInit();
      tmp = await Directory.systemTemp.createTemp('s8b4-backup-');
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final realDb = File(p.join(
          AppDatabase.dataDirectoryPath(), 'quiz-master2.db'));
      expect(realDb.existsSync(), isTrue,
          reason: '演示库不存在，无法做备份往返测试：${realDb.path}');
      copyPath = p.join(tmp.path, 'copy.db');
      await realDb.copy(copyPath);
      db = await databaseFactoryFfi.openDatabase(copyPath);
      // 4 张表里各放一行标记数据（演示库里这 4 张表本来是空的，
      // recent_tasks 除外：先清掉再放标记行）。
      await db.delete('recent_tasks');
      await db.insert('collect_tasks', {
        'id': 'ct-marker',
        'name': 'marker',
        'file_name': 'm.png',
        'subject_id': 'math',
        'status': 'done',
        'progress': 100,
        'page_count': 1,
        'page': 1,
        'error': null,
        'question_id': null,
      });
      await db.insert('review_state', {
        'id': 1,
        'queue': '["q-math-1"]',
        'position': 0,
        'updated_at': 1,
      });
      await db.insert('review_history', {
        'question_id': 'q-math-1',
        'result': 'solved',
        'reviewed_at': 1,
      });
      await db.insert('recent_tasks', {
        'id': 1,
        'kind': '整理',
        'subject_id': 'math',
        'title': 'marker-task',
        'updated_at': 1,
      });
    });

    test('导出的 JSON 含 4 张表的数据', () async {
      final decoded = jsonDecode(await AppDatabase.exportBackupJsonFrom(db))
          as Map<String, dynamic>;
      expect(decoded.keys, containsAll([
        'collect_tasks',
        'review_state',
        'review_history',
        'recent_tasks',
      ]));
      final tasks = decoded['collect_tasks'] as List;
      expect(tasks.any((r) => (r as Map)['id'] == 'ct-marker'), isTrue);
      expect((decoded['review_state'] as List).length, 1);
      expect((decoded['review_history'] as List).length, 1);
      expect((decoded['recent_tasks'] as List).first['title'],
          'marker-task');
    });

    test('备份 → 改动/清空 → 恢复 → 4 张表数据回来', () async {
      final exported = jsonDecode(await AppDatabase.exportBackupJsonFrom(db))
          as Map<String, dynamic>;
      // 改动：清掉 4 张表的标记行。
      await db.delete('collect_tasks');
      await db.delete('review_state');
      await db.delete('review_history');
      await db.update('recent_tasks', {'title': 'changed'});
      expect(await db.query('collect_tasks'), isEmpty);
      // 恢复。
      await AppDatabase.importBackupJsonInto(db, exported);
      final tasks = await db.query('collect_tasks');
      expect(tasks.any((r) => r['id'] == 'ct-marker'), isTrue);
      expect(await db.query('review_state'), hasLength(1));
      expect(await db.query('review_history'), hasLength(1));
      expect((await db.query('recent_tasks')).first['title'], 'marker-task');
      // 其余表也不受影响：演示库仍是 9 道题。
      expect(await db.query('questions'), hasLength(9));
    });

    test('旧备份（没有 4 张表键）恢复不崩，4 张表被清空', () async {
      final legacy = jsonDecode(await AppDatabase.exportBackupJsonFrom(db))
          as Map<String, dynamic>;
      for (final t in [
        'collect_tasks',
        'review_state',
        'review_history',
        'recent_tasks',
      ]) {
        legacy.remove(t);
      }
      await AppDatabase.importBackupJsonInto(db, legacy);
      expect(await db.query('collect_tasks'), isEmpty);
      expect(await db.query('review_state'), isEmpty);
      expect(await db.query('review_history'), isEmpty);
      expect(await db.query('recent_tasks'), isEmpty);
      expect(await db.query('questions'), hasLength(9));
    });
  });

  group('B4.3 copyDatabaseFileTo', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('s8b4-migrate-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
    });

    Future<File> sourceWith(String content) async {
      final f = File(p.join(tmp.path, 'src', 'quiz-master2.db'));
      await f.parent.create(recursive: true);
      return f.writeAsString(content);
    }

    test('复制到新位置：文件在、内容一致', () async {
      final src = await sourceWith('old-db-bytes');
      final targetDir = p.join(tmp.path, 'dst');
      expect(await AppDatabase.copyDatabaseFileTo(src.path, targetDir),
          isTrue);
      expect(File(p.join(targetDir, 'quiz-master2.db')).readAsStringSync(),
          'old-db-bytes');
    });

    test('目标已有库且不覆盖：返回 false，目标原文件不动', () async {
      final src = await sourceWith('new-bytes');
      final targetDir = p.join(tmp.path, 'dst');
      await Directory(targetDir).create(recursive: true);
      final target = File(p.join(targetDir, 'quiz-master2.db'));
      await target.writeAsString('existing-bytes');
      expect(await AppDatabase.copyDatabaseFileTo(src.path, targetDir),
          isFalse);
      expect(target.readAsStringSync(), 'existing-bytes');
    });

    test('目标已有库且指定覆盖：返回 true，内容被替换', () async {
      final src = await sourceWith('new-bytes');
      final targetDir = p.join(tmp.path, 'dst');
      await Directory(targetDir).create(recursive: true);
      await File(p.join(targetDir, 'quiz-master2.db'))
          .writeAsString('existing-bytes');
      expect(
          await AppDatabase.copyDatabaseFileTo(src.path, targetDir,
              overwrite: true),
          isTrue);
      expect(
          File(p.join(targetDir, 'quiz-master2.db')).readAsStringSync(),
          'new-bytes');
    });

    test('旧库不存在：无可迁移，返回 true，只由调用方写标记', () async {
      final targetDir = p.join(tmp.path, 'dst');
      expect(
          await AppDatabase.copyDatabaseFileTo(
              p.join(tmp.path, 'no-such.db'), targetDir),
          isTrue);
      expect(File(p.join(targetDir, 'quiz-master2.db')).existsSync(),
          isFalse);
    });

    test('databaseExistsAt 按文件在不在返回', () async {
      final dir = p.join(tmp.path, 'dst');
      expect(AppDatabase.databaseExistsAt(dir), isFalse);
      await Directory(dir).create(recursive: true);
      await File(p.join(dir, 'quiz-master2.db')).writeAsString('x');
      expect(AppDatabase.databaseExistsAt(dir), isTrue);
    });
  });
}
