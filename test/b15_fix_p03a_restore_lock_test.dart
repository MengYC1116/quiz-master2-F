// 十五批修复批 P0-3a：备份恢复切换段持锁（D-185）。
//
// 覆盖：恢复逐文件进位段包进一次 guard.withLock——锁被占时切换段
// 排队等待（不重入抛错、不静默越过），锁放后恢复继续并完成，
// 文件字节一致。只测切换段持锁，不包整个恢复流程。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/file_lifecycle_guard.dart';
import 'package:quiz_master2/data/restore_journal.dart';

Future<QuizDatabase> openTestDb() => AppDatabase.openForTest();

Future<void> seedSubject(QuizDatabase db, String id, String name) async {
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

Future<void> seedQuestion(
  QuizDatabase db, {
  required String id,
  required String subjectId,
  String? sourcePath,
  String? pageImagePath,
  String? slicePath,
}) async {
  await db.customInsert(
    'INSERT INTO questions (id, title, subject_id, folder_ids, '
    'knowledge_ids, error_types, custom_error_types, tags, created_at, '
    'slice_kind, slice_text, source_path, source_kind, source_page, '
    'page_image_path, slice_path, is_demo) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    variables: [
      Variable.withString(id),
      Variable.withString('题 $id'),
      Variable.withString(subjectId),
      Variable.withString('[]'),
      Variable.withString('[]'),
      Variable.withString('[]'),
      Variable.withString('[]'),
      Variable.withString('[]'),
      Variable.withInt(1700000000000),
      Variable.withString('material'),
      Variable.withString(''),
      Variable(sourcePath),
      Variable(sourcePath == null ? null : 'image'),
      Variable(sourcePath == null ? null : 1),
      Variable(pageImagePath),
      Variable(slicePath),
      Variable.withInt(0),
    ],
  );
}

Future<void> seedTask(
  QuizDatabase db, {
  required String id,
  required String subjectId,
  String sourcePath = '',
}) async {
  await db.customInsert(
    'INSERT INTO collect_tasks (id, name, file_name, subject_id, status, '
    'progress, page_count, page, error, question_id, created_at, '
    'source_path, page_rotations) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    variables: [
      Variable.withString(id),
      Variable.withString('任务 $id'),
      Variable.withString('m.png'),
      Variable.withString(subjectId),
      Variable.withString('needBox'),
      Variable.withInt(100),
      Variable.withInt(1),
      Variable.withInt(1),
      const Variable<String>(null),
      const Variable<String>(null),
      Variable.withInt(1700000000000),
      Variable.withString(sourcePath),
      Variable.withString('{}'),
    ],
  );
}

Future<File> writeDataFile(
  Directory dataDir,
  String rel,
  List<int> bytes,
) async {
  final f = File(p.join(dataDir.path, rel));
  await f.parent.create(recursive: true);
  return f.writeAsBytes(bytes);
}

void main() {
  test('D-185：恢复切换段持锁——锁被占时切换段等待，锁放后完成', () async {
    final tmp =
        Directory(
          '${Directory.current.path}/../flutter-test-tmp/fix-p03a-t0',
        )..createSync(recursive: true);
    AppDatabase.testDataDirectory = tmp.path;
    final db = await openTestDb();
    addTearDown(() async {
      AppDatabase.testDataDirectory = null;
      try {
        await db.close();
      } catch (_) {}
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    await seedSubject(db, 'math', '数学');
    await seedQuestion(
      db,
      id: 'q1',
      subjectId: 'math',
      sourcePath: 'imports/task-1/original.jpg',
      pageImagePath: 'imports/task-1/original.jpg',
      slicePath: 'slices/q1.png',
    );
    await seedTask(
      db,
      id: 'task-1',
      subjectId: 'math',
      sourcePath: 'imports/task-1/original.jpg',
    );
    await writeDataFile(tmp, 'imports/task-1/original.jpg', [1, 2, 3, 4, 5]);
    await writeDataFile(tmp, 'slices/q1.png', [9, 8, 7]);
    final zip = await AppDatabase.exportBackupZipFrom(db, dataDir: tmp.path);
    await File(p.join(tmp.path, 'slices/q1.png')).delete();
    await File(p.join(tmp.path, 'imports/task-1/original.jpg')).delete();
    await db.customUpdate('DELETE FROM questions');
    await db.customUpdate('DELETE FROM collect_tasks');
    expect(await db.customSelect('SELECT * FROM questions').get(), isEmpty);

    // 1. 测试侧占住锁（独立任务，与恢复任务不在同一 Zone 调用链，
    //    恢复的 withLock 应排队等待，不是重入抛错）。
    final guard = FileLifecycleGuard.instance;
    final lockAcquired = Completer<void>();
    final releaseLock = Completer<void>();
    unawaited(
      guard.withLock(() async {
        lockAcquired.complete();
        await releaseLock.future;
      }),
    );
    await lockAcquired.future;

    // 2. 启动恢复；轮询日志直到 filesSwitching（日志推进在取锁之前，
    //    故该阶段出现即证明恢复已到切换段门口）。
    final restoreFuture = AppDatabase.importBackupZipInto(
      db,
      zip,
      dataDir: tmp.path,
    );
    var restoreDone = false;
    unawaited(
      restoreFuture.then((_) {
        restoreDone = true;
      }),
    );
    final store = RestoreJournalStore(dataDir: tmp);
    var sawSwitching = false;
    for (var i = 0; i < 100; i++) {
      if (store.formalFile.existsSync()) {
        try {
          final journal = await store.validateFile(store.formalFile);
          if (journal.stage == RestoreStage.filesSwitching) {
            sawSwitching = true;
            break;
          }
        } on JournalCorruptException {
          // 日志正在原子替换的间隙，忽略、继续轮询。
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(sawSwitching, isTrue, reason: '恢复应推进到 filesSwitching 阶段');

    // 3. 锁未放：切换段不得执行——恢复未完成、目标文件仍未装进正式位置。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(restoreDone, isFalse, reason: '锁被占时恢复不得越过切换段');
    expect(File(p.join(tmp.path, 'slices/q1.png')).existsSync(), isFalse);
    expect(
      File(p.join(tmp.path, 'imports/task-1/original.jpg')).existsSync(),
      isFalse,
    );

    // 4. 放锁：恢复继续并完成，文件字节一致、库行回来。
    releaseLock.complete();
    await restoreFuture;
    expect(restoreDone, isTrue);
    expect(await File(p.join(tmp.path, 'slices/q1.png')).readAsBytes(), [
      9,
      8,
      7,
    ]);
    expect(
      await File(
        p.join(tmp.path, 'imports/task-1/original.jpg'),
      ).readAsBytes(),
      [1, 2, 3, 4, 5],
    );
    expect(
      (await db.customSelect('SELECT * FROM questions').get()).length,
      1,
    );
    expect(
      (await db.customSelect('SELECT * FROM collect_tasks').get()).length,
      1,
    );
  });
}
