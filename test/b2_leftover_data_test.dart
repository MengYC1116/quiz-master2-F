// B2 数据层收尾（items 1 / 4 / 5）回归测试。
// 全部用内存库（createTables 建表，不播种演示数据）+ 临时目录文件，
// 不碰真实库；只有 5a 的 migrateToDirectory 端到端测试走单例，
// 且标记目录用 AppDatabase.testMarkerDirectory 重定向到临时目录，
// 不写真实标记文件。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> openTestDb() async {
  sqfliteFfiInit();
  return databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async =>
              AppDatabase.createTables(db)));
}

Future<void> insertQuestionRow(Database db, String id,
    {String tags = '', String knowledgeIds = ''}) async {
  await db.insert('questions', {
    'id': id,
    'title': 't-$id',
    'subject_id': 'math',
    'folder_ids': '',
    'created_at': 1000,
    'tags': tags,
    'knowledge_ids': knowledgeIds,
  });
}

Future<Map<String, int>> _rowids(Database db, String table) async {
  return {
    for (final r in await db.query(table, columns: ['id', 'rowid']))
      r['id'] as String: r['rowid'] as int,
  };
}

void main() {
  group('B2-1 四项多步写的事务原子性（触发器模拟中途失败）', () {
    test('renameTagFrom 中途失败：标签行与题上的标签整体回滚', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await db.insert('tags', {'id': 'tag-易错', 'name': '易错'});
      await db.insert('tags', {'id': 'tag-常考', 'name': '常考'});
      await insertQuestionRow(db, 'q1',
          tags: AppDatabase.encodeStringList(['易错', '常考']));
      // 让第二步（改题上的标签）必失败：标签行已改名，题还没改。
      await db.execute(
          "CREATE TRIGGER trg_fail_qup BEFORE UPDATE ON questions "
          "BEGIN SELECT RAISE(ABORT, 'boom'); END;");
      await expectLater(AppDatabase.renameTagFrom(db, '易错', '常考'),
          throwsA(anything));
      // 回滚：标签行还是旧名，题上的标签没变。
      expect(
          (await db.query('tags')).map((r) => r['name']).toList(),
          ['易错', '常考']);
      final q = await db.query('questions');
      expect(q.single['tags'],
          AppDatabase.encodeStringList(['易错', '常考']));
    });

    test('deleteTagFrom 中途失败：标签行与题上的标签整体回滚', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await db.insert('tags', {'id': 'tag-易错', 'name': '易错'});
      await db.insert('tags', {'id': 'tag-常考', 'name': '常考'});
      await insertQuestionRow(db, 'q1',
          tags: AppDatabase.encodeStringList(['易错', '常考']));
      await db.execute(
          "CREATE TRIGGER trg_fail_qup BEFORE UPDATE ON questions "
          "BEGIN SELECT RAISE(ABORT, 'boom'); END;");
      await expectLater(
          AppDatabase.deleteTagFrom(db, '易错'), throwsA(anything));
      expect(
          (await db.query('tags')).map((r) => r['name']).toList(),
          ['易错', '常考']);
      final q = await db.query('questions');
      expect(q.single['tags'],
          AppDatabase.encodeStringList(['易错', '常考']));
    });

    test('deleteKnowledgePointFrom 中途失败：知识点行与题整体回滚', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await db.insert('knowledge_points', {
        'id': 'kp1',
        'subject_id': 'math',
        'chapter': '第一章',
        'name': '极限'
      });
      await db.insert('knowledge_points', {
        'id': 'kp2',
        'subject_id': 'math',
        'chapter': '第一章',
        'name': '导数'
      });
      await insertQuestionRow(db, 'q1',
          knowledgeIds: AppDatabase.encodeStringList(['kp1', 'kp2']));
      await db.execute(
          "CREATE TRIGGER trg_fail_qup BEFORE UPDATE ON questions "
          "BEGIN SELECT RAISE(ABORT, 'boom'); END;");
      await expectLater(AppDatabase.deleteKnowledgePointFrom(db, 'kp1'),
          throwsA(anything));
      expect(
          (await db.query('knowledge_points')).map((r) => r['id']).toList(),
          ['kp1', 'kp2']);
      final q = await db.query('questions');
      expect(q.single['knowledge_ids'],
          AppDatabase.encodeStringList(['kp1', 'kp2']));
    });

    test('deleteChapterFrom 中途失败：该章知识点行与题整体回滚', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      for (final kp in [
        ('kp1', '第一章', '极限'),
        ('kp2', '第一章', '导数'),
        ('kp3', '第二章', '积分'),
      ]) {
        await db.insert('knowledge_points', {
          'id': kp.$1,
          'subject_id': 'math',
          'chapter': kp.$2,
          'name': kp.$3,
        });
      }
      await insertQuestionRow(db, 'q1',
          knowledgeIds:
              AppDatabase.encodeStringList(['kp1', 'kp2', 'kp3']));
      await db.execute(
          "CREATE TRIGGER trg_fail_qup BEFORE UPDATE ON questions "
          "BEGIN SELECT RAISE(ABORT, 'boom'); END;");
      await expectLater(
          AppDatabase.deleteChapterFrom(db, 'math', '第一章'),
          throwsA(anything));
      expect(
          (await db.query('knowledge_points')).map((r) => r['id']).toList(),
          ['kp1', 'kp2', 'kp3']);
      final q = await db.query('questions');
      expect(q.single['knowledge_ids'],
          AppDatabase.encodeStringList(['kp1', 'kp2', 'kp3']));
    });
  });

  group('B2-4 标签/试卷/知识点：更新不改变顺序', () {
    test('改标签名不改变标签顺序', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      for (final t in ['易错', '常考', '重点']) {
        await db.insert('tags', {'id': 'tag-$t', 'name': t});
      }
      expect(await AppDatabase.allTagsFrom(db), ['易错', '常考', '重点']);
      await AppDatabase.renameTagFrom(db, '易错', '易错题');
      expect(await AppDatabase.allTagsFrom(db), ['易错题', '常考', '重点']);
    });

    test('insertExamInto 更新不改变顺序、不改 rowid；新试卷插到末尾', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await AppDatabase.insertExamInto(
          db, const Exam(id: 'e1', name: '期中'));
      await AppDatabase.insertExamInto(
          db, const Exam(id: 'e2', name: '期末'));
      await AppDatabase.insertExamInto(
          db, const Exam(id: 'e3', name: '模拟'));
      final rowidBefore = await _rowids(db, 'exams');
      expect(
          (await AppDatabase.allExamsFrom(db)).map((e) => e.id).toList(),
          ['e1', 'e2', 'e3']);
      // 同 id 再插一次（改名+改日期）：REPLACE 会把 e1 顶到表尾，
      // UPDATE-first 不会。
      await AppDatabase.insertExamInto(
          db,
          Exam(
              id: 'e1',
              name: '期中考试',
              date: DateTime.fromMillisecondsSinceEpoch(2000)));
      final exams = await AppDatabase.allExamsFrom(db);
      expect(exams.map((e) => e.id).toList(), ['e1', 'e2', 'e3']);
      expect(exams.first.name, '期中考试');
      expect(exams.first.date, DateTime.fromMillisecondsSinceEpoch(2000));
      expect(await _rowids(db, 'exams'), rowidBefore);
      await AppDatabase.insertExamInto(
          db, const Exam(id: 'e4', name: '月考'));
      expect(
          (await AppDatabase.allExamsFrom(db)).map((e) => e.id).toList(),
          ['e1', 'e2', 'e3', 'e4']);
    });

    test('insertKnowledgePointInto 更新不改变顺序、不改 rowid；新知识点插到末尾',
        () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      for (final kp in [
        const KnowledgePoint(
            id: 'kp1', subjectId: 'math', chapter: '第一章', name: '极限'),
        const KnowledgePoint(
            id: 'kp2', subjectId: 'math', chapter: '第一章', name: '导数'),
        const KnowledgePoint(
            id: 'kp3', subjectId: 'math', chapter: '第二章', name: '积分'),
      ]) {
        await AppDatabase.insertKnowledgePointInto(db, kp);
      }
      final rowidBefore = await _rowids(db, 'knowledge_points');
      expect(
          (await AppDatabase.allKnowledgePointsFrom(db))
              .map((k) => k.id)
              .toList(),
          ['kp1', 'kp2', 'kp3']);
      // 同 id 再插一次（改名）：REPLACE 会把 kp1 顶到表尾。
      await AppDatabase.insertKnowledgePointInto(
          db,
          const KnowledgePoint(
              id: 'kp1', subjectId: 'math', chapter: '第一章', name: '极限概念'));
      final kps = await AppDatabase.allKnowledgePointsFrom(db);
      expect(kps.map((k) => k.id).toList(), ['kp1', 'kp2', 'kp3']);
      expect(kps.first.name, '极限概念');
      expect(await _rowids(db, 'knowledge_points'), rowidBefore);
      await AppDatabase.insertKnowledgePointInto(
          db,
          const KnowledgePoint(
              id: 'kp4', subjectId: 'math', chapter: '第二章', name: '定积分'));
      expect(
          (await AppDatabase.allKnowledgePointsFrom(db))
              .map((k) => k.id)
              .toList(),
          ['kp1', 'kp2', 'kp3', 'kp4']);
    });

    test('改知识点名（renameKnowledgePoint，单步 UPDATE）不改变顺序', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      for (final kp in [
        const KnowledgePoint(
            id: 'kp1', subjectId: 'math', chapter: '第一章', name: '极限'),
        const KnowledgePoint(
            id: 'kp2', subjectId: 'math', chapter: '第一章', name: '导数'),
      ]) {
        await AppDatabase.insertKnowledgePointInto(db, kp);
      }
      // renameKnowledgePoint 没有 *Into 版（单步 UPDATE）：走单例测，
      // 先把单例指到本测试库；测完指回一个无害的内存库，避免后续
      // 测试拿到已关闭的库。
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async {
        final mem = await openTestDb();
        AppDatabase.useDatabaseForTest(mem);
      });
      await AppDatabase.instance.renameKnowledgePoint('kp1', '极限概念');
      final kps = await AppDatabase.allKnowledgePointsFrom(db);
      expect(kps.map((k) => k.id).toList(), ['kp1', 'kp2']);
      expect(kps.first.name, '极限概念');
    });
  });

  group('B2-5a 标记写失败的回滚（keepBackups + 回滚）', () {
    ({Directory src, Directory dst}) seedMigrationDirs(Directory tmp) {
      final src = Directory(p.join(tmp.path, 'src'))
        ..createSync(recursive: true);
      final dst = Directory(p.join(tmp.path, 'dst'))
        ..createSync(recursive: true);
      File(p.join(src.path, 'quiz-master2.db')).writeAsStringSync('NEW-DB');
      final newSlice = File(p.join(src.path, 'slices', 'new.png'))
        ..createSync(recursive: true);
      newSlice.writeAsStringSync('NEW-SLICE');
      File(p.join(dst.path, 'quiz-master2.db')).writeAsStringSync('OLD-DB');
      final oldSlice = File(p.join(dst.path, 'slices', 'old.png'))
        ..createSync(recursive: true);
      oldSlice.writeAsStringSync('OLD-SLICE');
      return (src: src, dst: dst);
    }

    test('migrateDataFiles keepBackups：成功后 .old 保留、路径报出', () async {
      final tmp = await Directory.systemTemp.createTemp('qm2-b2-5a-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dirs = seedMigrationDirs(tmp);
      final backups = <({String current, String backup})>[];
      final moved = <String>[];
      final outcome = await AppDatabase.migrateDataFiles(
          dirs.src.path, dirs.dst.path,
          overwrite: true,
          keepBackups: true,
          outBackups: backups,
          outMoved: moved);
      expect(outcome, DbMigrationOutcome.migrated);
      expect(
          File(p.join(dirs.dst.path, 'quiz-master2.db'))
              .readAsStringSync(),
          'NEW-DB');
      expect(
          File(p.join(dirs.dst.path, 'slices', 'new.png'))
              .readAsStringSync(),
          'NEW-SLICE');
      // .old 备份还在（库文件 + slices 目录），等提交点成功后再删。
      expect(backups.length, 2);
      for (final b in backups) {
        expect(
            File(b.backup).existsSync() ||
                Directory(b.backup).existsSync(),
            isTrue);
      }
      expect(moved, contains(p.join(dirs.dst.path, 'quiz-master2.db')));
      expect(moved, contains(p.join(dirs.dst.path, 'slices')));
      expect(
          dirs.dst
              .listSync()
              .where((e) => p.basename(e.path).contains('staging')),
          isEmpty);
    });

    test('rollbackMigrationFiles：新位置复原，旧库旧图回来、新文件没了',
        () async {
      final tmp = await Directory.systemTemp.createTemp('qm2-b2-5a-rb-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dirs = seedMigrationDirs(tmp);
      final backups = <({String current, String backup})>[];
      final moved = <String>[];
      final outcome = await AppDatabase.migrateDataFiles(
          dirs.src.path, dirs.dst.path,
          overwrite: true,
          keepBackups: true,
          outBackups: backups,
          outMoved: moved);
      expect(outcome, DbMigrationOutcome.migrated);
      // 模拟标记写失败后的回滚。
      await AppDatabase.rollbackMigrationFiles(moved, backups);
      expect(
          File(p.join(dirs.dst.path, 'quiz-master2.db'))
              .readAsStringSync(),
          'OLD-DB');
      expect(
          File(p.join(dirs.dst.path, 'slices', 'old.png'))
              .readAsStringSync(),
          'OLD-SLICE');
      expect(
          File(p.join(dirs.dst.path, 'slices', 'new.png')).existsSync(),
          isFalse);
      expect(
          dirs.dst
              .listSync()
              .where((e) => p.basename(e.path).contains('.old-')),
          isEmpty);
    });
  });

  group('B2-5a migrateToDirectory 端到端（标记目录重定向到临时目录）', () {
    // 收尾：关掉单例可能重开过的临时库，把单例指回一个无害的内存库，
    // 再恢复静态覆盖与 dbPathUsed，最后删临时目录。
    Future<void> resetSingletons({
      required String? prevDataDir,
      required String? prevMarkerDir,
      required String? prevDbPath,
      required Directory tmp,
    }) async {
      try {
        final d = await AppDatabase.instance.db;
        await d.close();
      } catch (_) {}
      AppDatabase.testDataDirectory = prevDataDir;
      AppDatabase.testMarkerDirectory = prevMarkerDir;
      final mem = await openTestDb();
      AppDatabase.useDatabaseForTest(mem);
      AppDatabase.instance.dbPathUsed = prevDbPath;
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }

    Future<Directory> setUpE2E({
      required bool targetExists,
      required bool markerIsFile,
    }) async {
      sqfliteFfiInit();
      final tmp =
          await Directory.systemTemp.createTemp('qm2-b2-5a-e2e-');
      final prevDataDir = AppDatabase.testDataDirectory;
      final prevMarkerDir = AppDatabase.testMarkerDirectory;
      final prevDbPath = AppDatabase.instance.dbPathUsed;
      addTearDown(() => resetSingletons(
          prevDataDir: prevDataDir,
          prevMarkerDir: prevMarkerDir,
          prevDbPath: prevDbPath,
          tmp: tmp));
      final srcDir = Directory(p.join(tmp.path, 'src'))
        ..createSync(recursive: true);
      final dstDir = Directory(p.join(tmp.path, 'dst'));
      if (targetExists) dstDir.createSync(recursive: true);
      // 真实源库（openAt 建 v2 库）；迁移本身是字节复制，内容无所谓，
      // 但成功路径的 saveSetting 要重开它，必须是合法库。
      final srcDbPath = p.join(srcDir.path, 'quiz-master2.db');
      final srcDb = await AppDatabase.openAt(srcDbPath);
      await srcDb.close();
      final newSlice = File(p.join(srcDir.path, 'slices', 'new.png'))
        ..createSync(recursive: true);
      newSlice.writeAsStringSync('NEW-SLICE');
      if (targetExists) {
        File(p.join(dstDir.path, 'quiz-master2.db'))
            .writeAsStringSync('OLD-DB');
        final oldSlice = File(p.join(dstDir.path, 'slices', 'old.png'))
          ..createSync(recursive: true);
        oldSlice.writeAsStringSync('OLD-SLICE');
      }
      AppDatabase.testDataDirectory = srcDir.path;
      if (markerIsFile) {
        // 标记目录是个已存在的文件：建目录/写标记必失败。
        final markerFile = File(p.join(tmp.path, 'marker-is-a-file'))
          ..writeAsStringSync('x');
        AppDatabase.testMarkerDirectory = markerFile.path;
      } else {
        AppDatabase.testMarkerDirectory = p.join(tmp.path, 'marker');
      }
      AppDatabase.instance.dbPathUsed = srcDbPath;
      return tmp;
    }

    test('成功：标记写好后 .old 才删', () async {
      final tmp = await setUpE2E(targetExists: true, markerIsFile: false);
      final dstDir = Directory(p.join(tmp.path, 'dst'));
      final markerDir = Directory(p.join(tmp.path, 'marker'));
      final outcome = await AppDatabase.instance
          .migrateToDirectory(dstDir.path, overwrite: true);
      expect(outcome, DbMigrationOutcome.migrated);
      expect(
          File(p.join(markerDir.path, 'db_location.txt'))
              .readAsStringSync(),
          dstDir.path);
      expect(
          File(p.join(dstDir.path, 'slices', 'new.png'))
              .readAsStringSync(),
          'NEW-SLICE');
      expect(
          dstDir
              .listSync()
              .where((e) => p.basename(e.path).contains('.old-')),
          isEmpty);
      expect(
          dstDir
              .listSync()
              .where((e) => p.basename(e.path).contains('staging')),
          isEmpty);
    });

    test('标记写失败：返回 failed，新位置复原、不留重复副本', () async {
      final tmp = await setUpE2E(targetExists: true, markerIsFile: true);
      final dstDir = Directory(p.join(tmp.path, 'dst'));
      final outcome = await AppDatabase.instance
          .migrateToDirectory(dstDir.path, overwrite: true);
      expect(outcome, DbMigrationOutcome.failed);
      expect(
          File(p.join(dstDir.path, 'quiz-master2.db'))
              .readAsStringSync(),
          'OLD-DB');
      expect(
          File(p.join(dstDir.path, 'slices', 'old.png'))
              .readAsStringSync(),
          'OLD-SLICE');
      expect(
          File(p.join(dstDir.path, 'slices', 'new.png')).existsSync(),
          isFalse);
      expect(
          dstDir
              .listSync()
              .where((e) => p.basename(e.path).contains('.old-')),
          isEmpty);
      expect(
          dstDir
              .listSync()
              .where((e) => p.basename(e.path).contains('staging')),
          isEmpty);
    });

    test('标记写失败且目标是本次新建的：回滚后目标目录也删掉', () async {
      final tmp = await setUpE2E(targetExists: false, markerIsFile: true);
      final dstDir = Directory(p.join(tmp.path, 'dst'));
      final outcome = await AppDatabase.instance
          .migrateToDirectory(dstDir.path, overwrite: false);
      expect(outcome, DbMigrationOutcome.failed);
      expect(dstDir.existsSync(), isFalse);
    });
  });

  group('B2-5b 目标只有孤儿文件、没有库（现状锁定，未修）', () {
    test('不覆盖迁移失败，目标原封不动、无数据丢失', () async {
      final tmp = await Directory.systemTemp.createTemp('qm2-b2-5b-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final src = Directory(p.join(tmp.path, 'src'))
        ..createSync(recursive: true);
      File(p.join(src.path, 'quiz-master2.db')).writeAsStringSync('NEW-DB');
      // 源也要有 imports/，staging 里才有 imports 目录可搬——
      // 目标的 imports/ 已存在时 rename 才会撞上（源没有 imports/
      // 时只搬库文件，迁移反而能成功，孤儿目录原地不动）。
      final srcImport =
          File(p.join(src.path, 'imports', 'task1', 'original.jpg'))
            ..createSync(recursive: true);
      srcImport.writeAsStringSync('SRC-IMG');
      final dst = Directory(p.join(tmp.path, 'dst'))
        ..createSync(recursive: true);
      final orphan = File(p.join(dst.path, 'imports', 'orphan', 'x.jpg'))
        ..createSync(recursive: true);
      orphan.writeAsStringSync('ORPHAN');
      final outcome =
          await AppDatabase.migrateDataFiles(src.path, dst.path);
      expect(outcome, DbMigrationOutcome.failed);
      expect(
          File(p.join(dst.path, 'imports', 'orphan', 'x.jpg'))
              .readAsStringSync(),
          'ORPHAN');
      expect(
          File(p.join(dst.path, 'quiz-master2.db')).existsSync(), isFalse);
      expect(
          File(p.join(dst.path, 'imports', 'task1', 'original.jpg'))
              .existsSync(),
          isFalse);
      expect(
          tmp
              .listSync()
              .where((e) => p.basename(e.path).contains('staging')),
          isEmpty);
    });
  });

  group('B2-5c zip 恢复后、备份里没有的旧文件由孤儿清理接住', () {
    test('恢复本身不删旧文件；孤儿扫描列出它们，在用文件不在列', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final tmp = await Directory.systemTemp.createTemp('qm2-b2-5c-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dataDir = tmp.path;
      // 备份时刻：q1 引用 slices/q1.png。
      await db.insert('questions', {
        'id': 'q1',
        'title': 't',
        'subject_id': 'math',
        'folder_ids': '',
        'created_at': 1000,
        'slice_path': 'slices/q1.png',
      });
      final q1File = File(p.join(dataDir, 'slices', 'q1.png'))
        ..createSync(recursive: true);
      q1File.writeAsStringSync('Q1');
      final zipBytes =
          await AppDatabase.exportBackupZipFrom(db, dataDir: dataDir);
      // 恢复前：多了 q2（引用 slices/q2.png）与一个旧孤儿文件。
      await db.insert('questions', {
        'id': 'q2',
        'title': 't',
        'subject_id': 'math',
        'folder_ids': '',
        'created_at': 1000,
        'slice_path': 'slices/q2.png',
      });
      final q2File = File(p.join(dataDir, 'slices', 'q2.png'))
        ..createSync(recursive: true);
      q2File.writeAsStringSync('Q2');
      final oldFile =
          File(p.join(dataDir, 'imports', 'task-old', 'x.jpg'))
            ..createSync(recursive: true);
      oldFile.writeAsStringSync('OLD');
      // 恢复备份：q2 的行没了，但 q2 的图与旧孤儿文件都还在盘上。
      await AppDatabase.importBackupZipInto(db, zipBytes, dataDir: dataDir);
      expect((await db.query('questions')).map((r) => r['id']).toList(),
          ['q1']);
      expect(File(p.join(dataDir, 'slices', 'q2.png')).existsSync(),
          isTrue);
      expect(
          File(p.join(dataDir, 'imports', 'task-old', 'x.jpg'))
              .existsSync(),
          isTrue);
      // 孤儿扫描接住它们，在用文件不在列。
      final scan =
          await AppDatabase.scanOrphanFilesFrom(db, dataDir: dataDir);
      final found = scan.files.map((f) => f.relativePath).toList();
      expect(found, containsAll(['slices/q2.png', 'imports/task-old/x.jpg']));
      expect(found, isNot(contains('slices/q1.png')));
      // 清理只删孤儿。
      final res =
          await AppDatabase.deleteOrphanFiles(found, dataDir: dataDir);
      expect(res.deletedCount, 2);
      expect(File(p.join(dataDir, 'slices', 'q1.png')).existsSync(),
          isTrue);
    });
  });

  group('B2-5d 崩溃残留的 staging 清理', () {
    test('迁移开始时清掉严格匹配的残留 staging，其它一概不动', () async {
      final tmp = await Directory.systemTemp.createTemp('qm2-b2-5d-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final src = Directory(p.join(tmp.path, 'src'))
        ..createSync(recursive: true);
      File(p.join(src.path, 'quiz-master2.db')).writeAsStringSync('NEW-DB');
      final dstPath = p.join(tmp.path, 'dst');
      // 崩溃残留：严格匹配的 staging 目录（含文件）。
      final stale = Directory(p.join(tmp.path, '.dst.staging-1234567890'))
        ..createSync(recursive: true);
      File(p.join(stale.path, 'quiz-master2.db'))
          .writeAsStringSync('STALE');
      // 不匹配的，一概不动：非数字后缀、别的目标名、缺前导点、普通文件。
      final keep1 = Directory(p.join(tmp.path, '.dst.staging-backup'))
        ..createSync(recursive: true);
      final keep2 = Directory(p.join(tmp.path, '.other.staging-123'))
        ..createSync(recursive: true);
      final keep3 = Directory(p.join(tmp.path, 'dst.staging-123'))
        ..createSync(recursive: true);
      final keepFile = File(p.join(tmp.path, '.dst.staging-999'))
        ..writeAsStringSync('x');
      final outcome =
          await AppDatabase.migrateDataFiles(src.path, dstPath);
      expect(outcome, DbMigrationOutcome.migrated);
      expect(stale.existsSync(), isFalse);
      expect(keep1.existsSync(), isTrue);
      expect(keep2.existsSync(), isTrue);
      expect(keep3.existsSync(), isTrue);
      expect(keepFile.existsSync(), isTrue);
      expect(
          File(p.join(dstPath, 'quiz-master2.db')).readAsStringSync(),
          'NEW-DB');
    });

    test('同位置迁移也先清残留 staging（清理在早期返回之前）', () async {
      final tmp = await Directory.systemTemp.createTemp('qm2-b2-5d-same-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final dir = Directory(p.join(tmp.path, 'dst'))
        ..createSync(recursive: true);
      final stale = Directory(p.join(tmp.path, '.dst.staging-123'))
        ..createSync(recursive: true);
      final outcome =
          await AppDatabase.migrateDataFiles(dir.path, dir.path);
      expect(outcome, DbMigrationOutcome.sameLocation);
      expect(stale.existsSync(), isFalse);
    });
  });
}
