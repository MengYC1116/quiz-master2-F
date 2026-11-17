// FR-06 孤儿清理信任过期扫描：
// (a) 删除前用当前库重算引用，仍被引用的跳过并计入返回；
// (b) 设置页恢复成功后把旧扫描置空并重扫（(b) 是页面行为，
//     本文件只锁 (a) 的数据层防线；(b) 的置空+重扫与 _clearOrphans
//     同款写法，见 settings_page_test 的恢复组）。
//
// 探针场景（W5-01）：题行引用 slices/q1.png 时清理不得删它；
// 恢复后旧扫描不再误删——先扫描（q1.png 是孤儿），再插入引用
// 它的题行（模拟恢复），拿旧列表去清理，q1.png 必须被跳过。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';

Future<QuizDatabase> _openTestDb() => AppDatabase.openForTest();

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
  required String subjectId,
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
      Variable(null),
      Variable(null),
      Variable(null),
      Variable(null),
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

void main() {
  group('FR-06(a) 删除前重算引用', () {
    late Directory tmp;
    late QuizDatabase db;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fr06-orphan-');
      AppDatabase.testDataDirectory = tmp.path;
      db = await _openTestDb();
      addTearDown(() async {
        AppDatabase.testDataDirectory = null;
        try {
          await db.close();
        } catch (_) {}
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      await _seedSubject(db, 'math', '数学');
      await _writeDataFile(tmp, 'slices/q1.png', [3]);
      await _writeDataFile(tmp, 'slices/orphan.png', [8, 9]);
    });

    test('题行引用 slices/q1.png 时清理不得删它，真孤儿照常删', () async {
      await _seedQuestion(
        db,
        id: 'q1',
        subjectId: 'math',
        slicePath: 'slices/q1.png',
      );
      final result = await AppDatabase.deleteOrphanFiles(
        ['slices/q1.png', 'slices/orphan.png'],
        dataDir: tmp.path,
        db: db,
      );
      expect(result.deletedCount, 1);
      expect(result.freedBytes, 2);
      expect(result.skippedReferencedCount, 1);
      expect(File(p.join(tmp.path, 'slices/q1.png')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'slices/orphan.png')).existsSync(), isFalse);
    });

    test('恢复后旧扫描不再误删：扫描时是孤儿，恢复后被引用，拿旧列表清理被跳过', () async {
      // 扫描时库里没有引用 q1.png 的题行——它是孤儿。
      final scan = await AppDatabase.scanOrphanFilesFrom(db, dataDir: tmp.path);
      expect(scan.files.map((f) => f.relativePath), contains('slices/q1.png'));
      // 模拟恢复：恢复后的库里多了一道引用 q1.png 的题。
      await _seedQuestion(
        db,
        id: 'q1',
        subjectId: 'math',
        slicePath: 'slices/q1.png',
      );
      // 拿恢复前的旧扫描列表去清理——q1.png 必须被跳过。
      final result = await AppDatabase.deleteOrphanFiles(
        scan.files.map((f) => f.relativePath).toList(),
        dataDir: tmp.path,
        db: db,
      );
      expect(result.skippedReferencedCount, 1);
      expect(result.deletedCount, 1); // 只有真孤儿 orphan.png 被删
      expect(File(p.join(tmp.path, 'slices/q1.png')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'slices/orphan.png')).existsSync(), isFalse);
    });

    test('不传 db 时保持旧行为（既有调用方不受影响）', () async {
      await _seedQuestion(
        db,
        id: 'q1',
        subjectId: 'math',
        slicePath: 'slices/q1.png',
      );
      final result = await AppDatabase.deleteOrphanFiles([
        'slices/q1.png',
      ], dataDir: tmp.path);
      expect(result.deletedCount, 1);
      expect(result.skippedReferencedCount, 0);
      expect(File(p.join(tmp.path, 'slices/q1.png')).existsSync(), isFalse);
    });
  });
}
