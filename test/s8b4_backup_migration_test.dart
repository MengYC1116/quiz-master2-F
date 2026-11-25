// S8 B4.2 / B4.3：备份补 4 张表（导出 + 恢复往返）、databaseExistsAt。
// 备份往返用 createTables 建的合成库（P1：不再读真实用户库——
// §8.1 禁止新测试依赖真实库，且 P1 删老库后真实库从空开始，
// 旧写法“断言演示库 9 道题”在新库上必挂）；B4.3 的整机迁移
// （关库 + 写标记）不进单测，见 S8B4-REPORT.md 的真机验证——
// 单测里写标记会改掉真实应用的库位置。copyDatabaseFileTo 已在
// B3-P01 删除（生产无调用，迁移走 staging 的 migrateDataFiles），
// 其复制语义由 p3_backup_migration_test §4.6 组覆盖。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';

void main() {
  group('B4.2 backupTables', () {
    test('含补齐的 4 张表 + question_boxes + 最近查看 + OCR 任务 + attempts + fsrs_*，共 19 张', () {
      expect(
        AppDatabase.backupTables,
        containsAll([
          'collect_tasks',
          'review_state',
          'review_history',
          'recent_tasks',
          'question_boxes',
          // 十二批 D-91：v3 新表。
          'recently_viewed_questions',
          // 十三批 M2：v4 新表。
          'ocr_jobs',
          // 十四批 M2：v5 新表。
          'attempts',
          // P5：v8 新表。
          'fsrs_cards',
          'fsrs_events',
          'fsrs_migration_log',
        ]),
      );
      expect(AppDatabase.backupTables.length, 19);
    });
  });

  group('B4.2 备份导出 + 恢复往返（合成库）', () {
    late Directory tmp;
    late QuizDatabase db;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('s8b4-backup-');
      db = await AppDatabase.openForTest();
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      // 合成数据：1 学科、2 道题、4 张表里各一行标记数据。
      await db.customInsert(
        'INSERT INTO subjects (id, name, color, cover_style, cover_color) '
        'VALUES (?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('math'),
          Variable.withString('数学'),
          Variable.withInt(0xFF2E7CF6),
          Variable.withString('plain'),
          Variable.withString('blue'),
        ],
      );
      for (final id in ['q-math-1', 'q-math-2']) {
        await db.customInsert(
          'INSERT INTO questions (id, title, subject_id, folder_ids, '
          'knowledge_ids, error_types, custom_error_types, tags, created_at, '
          'slice_kind, slice_text) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          variables: [
            Variable.withString(id),
            Variable.withString('题 $id'),
            Variable.withString('math'),
            Variable.withString(''),
            Variable.withString(''),
            Variable.withString(''),
            Variable.withString(''),
            Variable.withString(''),
            Variable.withInt(1700000000000),
            Variable.withString('material'),
            Variable.withString(''),
          ],
        );
      }
      await db.customInsert(
        'INSERT INTO collect_tasks (id, name, file_name, subject_id, '
        'status, progress, page_count, page, error, question_id) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('ct-marker'),
          Variable.withString('marker'),
          Variable.withString('m.png'),
          Variable.withString('math'),
          Variable.withString('done'),
          Variable.withInt(100),
          Variable.withInt(1),
          Variable.withInt(1),
          const Variable<String>(null),
          const Variable<String>(null),
        ],
      );
      await db.customInsert(
        'INSERT INTO review_state (id, queue, position, updated_at) '
        'VALUES (?, ?, ?, ?)',
        variables: [
          Variable.withInt(1),
          // FR-07：queue 的规范形状是 q/c 对象数组（encodeQueue 只写
          // 这种形状；B3 黄金夹具同款）。旧种子 '["q-math-1"]' 是字符串
          // 数组，应用从未写过这种形状，decode 也会把它静默丢成空——
          // 校验层按规范形状拒绝它是正确的，这里改种子为规范值。
          Variable.withString('[{"q":"q-math-1","c":"计算错误"}]'),
          Variable.withInt(0),
          Variable.withInt(1),
        ],
      );
      await db.customInsert(
        'INSERT INTO review_history (question_id, result, reviewed_at) '
        'VALUES (?, ?, ?)',
        variables: [
          Variable.withString('q-math-1'),
          Variable.withString('solved'),
          Variable.withInt(1),
        ],
      );
      await db.customInsert(
        'INSERT INTO recent_tasks (id, kind, subject_id, title, updated_at) '
        'VALUES (?, ?, ?, ?, ?)',
        variables: [
          Variable.withInt(1),
          Variable.withString('整理'),
          Variable.withString('math'),
          Variable.withString('marker-task'),
          Variable.withInt(1),
        ],
      );
    });

    test('导出的 JSON 含 4 张表的数据 + _meta', () async {
      final decoded = jsonDecode(
        await AppDatabase.exportBackupJsonFrom(db),
      ) as Map<String, dynamic>;
      expect(
        decoded.keys,
        containsAll([
          'collect_tasks',
          'review_state',
          'review_history',
          'recent_tasks',
        ]),
      );
      final tasks = decoded['collect_tasks'] as List;
      expect(tasks.any((r) => (r as Map)['id'] == 'ct-marker'), isTrue);
      // 十四批 M2：备份不含未完成会话，review_state 导出为 []。
      expect((decoded['review_state'] as List).length, 0);
      expect((decoded['review_history'] as List).length, 1);
      expect((decoded['recent_tasks'] as List).first['title'], 'marker-task');
      // §2.3：_meta 在顶层，表名仍平铺。
      final meta = decoded['_meta'] as Map<String, dynamic>;
      // 十二批 D-91：当前版本已是 v3，用常量跟踪，不写死 2。
      expect(meta['schemaVersion'], AppDatabase.schemaVersion);
      expect(meta['appVersion'], isA<String>());
      expect(meta['exportedAt'], isA<int>());
      expect(decoded['question_boxes'], isA<List>());
    });

    test('备份 → 改动/清空 → 恢复 → 3 张表数据回来，会话不恢复（M2）', () async {
      final exported = jsonDecode(
        await AppDatabase.exportBackupJsonFrom(db),
      ) as Map<String, dynamic>;
      // 改动：清掉 4 张表的标记行。
      await db.customUpdate('DELETE FROM collect_tasks');
      await db.customUpdate('DELETE FROM review_state');
      await db.customUpdate('DELETE FROM review_history');
      await db.customUpdate(
        'UPDATE recent_tasks SET title = ?',
        variables: [Variable.withString('changed')],
      );
      expect(
        await db.customSelect('SELECT * FROM collect_tasks').get(),
        isEmpty,
      );
      // 恢复。
      await AppDatabase.importBackupJsonInto(db, exported);
      final tasks = (await db.customSelect('SELECT * FROM collect_tasks').get())
          .map((r) => r.data)
          .toList();
      expect(tasks.any((r) => r['id'] == 'ct-marker'), isTrue);
      // 十四批 M2：恢复事务清空 review_state、备份里的行不插，
      // 会话不回来。
      expect(
        await db.customSelect('SELECT * FROM review_state').get(),
        hasLength(0),
      );
      expect(
        await db.customSelect('SELECT * FROM review_history').get(),
        hasLength(1),
      );
      expect(
        (await db.customSelect('SELECT * FROM recent_tasks').get())
            .map((r) => r.data)
            .toList()
            .first['title'],
        'marker-task',
      );
      // 其余表也不受影响：合成库仍是 2 道题。
      expect(
        await db.customSelect('SELECT * FROM questions').get(),
        hasLength(2),
      );
    });

    test('SR-P2-4：旧备份（没有 4 张表键）拒绝恢复，原库不动', () async {
      final legacy = jsonDecode(
        await AppDatabase.exportBackupJsonFrom(db),
      ) as Map<String, dynamic>;
      for (final t in [
        'collect_tasks',
        'review_state',
        'review_history',
        'recent_tasks',
      ]) {
        legacy.remove(t);
      }
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, legacy),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(
        (await db.customSelect('SELECT * FROM collect_tasks').get()).any(
          (r) => r.data['id'] == 'ct-marker',
        ),
        isTrue,
      );
      // 本用例恢复被拒绝、原库不动：种子里的 review_state 原行保留
      // （十四批 M2 的“恢复清空 review_state”只发生在恢复成功时）。
      expect(
        await db.customSelect('SELECT * FROM review_state').get(),
        hasLength(1),
      );
      expect(
        await db.customSelect('SELECT * FROM review_history').get(),
        hasLength(1),
      );
      expect(
        await db.customSelect('SELECT * FROM recent_tasks').get(),
        hasLength(1),
      );
      expect(
        await db.customSelect('SELECT * FROM questions').get(),
        hasLength(2),
      );
    });

    test('没有 _meta 的 v1 备份：拒绝恢复，原库不动', () async {
      final legacy = jsonDecode(
        await AppDatabase.exportBackupJsonFrom(db),
      ) as Map<String, dynamic>;
      legacy.remove('_meta');
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, legacy),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(
        await db.customSelect('SELECT * FROM questions').get(),
        hasLength(2),
      );
      expect(
        (await db.customSelect('SELECT * FROM collect_tasks').get()).any(
          (r) => r.data['id'] == 'ct-marker',
        ),
        isTrue,
      );
    });
  });

  group('B4.3 databaseExistsAt', () {
    // B3-P01：copyDatabaseFileTo 已删除（生产无调用；整机迁移走
    // staging 方式的 migrateDataFiles，见 p3_backup_migration_test
    // §4.6 组）。旧的直接覆盖复制在覆盖失败时会留截断的库文件，
    // 不再保留该方法及其测试；这里只留 databaseExistsAt（设置页
    // 覆盖对话框的判断依据）。
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('s8b4-migrate-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
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
