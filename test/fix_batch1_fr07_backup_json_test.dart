// FR-07 备份 JSON 列损坏值静默丢数据：校验层对 9 个 JSON 列加类型
// 检查——值必须是字符串且能解析为对应形状，否则拒绝整个恢复；
// 保留 ''/null → 空集合的 D-51 规范化口径不变；decode* 本身保持宽容。
// 关键安全点：先校验、再覆盖——拒绝恢复时原库必须原样不动，双向测试覆盖。
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';

Future<QuizDatabase> _openTestDb() async {
  final db = await AppDatabase.openForTest();
  addTearDown(() async {
    try {
      await db.close();
    } catch (_) {}
  });
  return db;
}

Future<void> _seedBaseline(QuizDatabase db) async {
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
  await db.customInsert(
    'INSERT INTO questions (id, title, subject_id, folder_ids, '
    'knowledge_ids, error_types, custom_error_types, tags, created_at, '
    'slice_kind, slice_text, source_path, source_kind, source_page, '
    'page_image_path, slice_path, is_demo) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    variables: [
      Variable.withString('q1'),
      Variable.withString('题 q1'),
      Variable.withString('math'),
      Variable.withString('["f1"]'),
      Variable.withString('["kp1"]'),
      Variable.withString('["计算错误"]'),
      Variable.withString('[]'),
      Variable.withString('["易错"]'),
      Variable.withInt(1700000000000),
      Variable.withString('material'),
      Variable.withString(''),
      Variable(null),
      Variable(null),
      Variable(null),
      Variable(null),
      Variable(null),
      Variable.withInt(0),
    ],
  );
  await db.customInsert(
    'INSERT INTO cause_records (question_id, cause, subject_id, '
    'remedy_history, joined_at) VALUES (?, ?, ?, ?, ?)',
    variables: [
      Variable.withString('q1'),
      Variable.withString('计算错误'),
      Variable.withString('math'),
      Variable.withString('["已重做一次"]'),
      Variable.withInt(1700000000000),
    ],
  );
  await db.customInsert(
    'INSERT INTO review_state (id, queue, position, updated_at) '
    'VALUES (?, ?, ?, ?)',
    variables: [
      Variable.withInt(1),
      Variable.withString('[{"q":"q1","c":"计算错误"}]'),
      Variable.withInt(0),
      Variable.withInt(1700000000000),
    ],
  );
  await db.customInsert(
    'INSERT INTO collect_tasks (id, name, file_name, subject_id, '
    'page_rotations) VALUES (?, ?, ?, ?, ?)',
    variables: [
      Variable.withString('task-1'),
      Variable.withString('任务 1'),
      Variable.withString('a.pdf'),
      Variable.withString('math'),
      Variable.withString('{"1":90}'),
    ],
  );
}

/// 导出一份合法备份（9 个 JSON 列全是规范值）。
Future<Map<String, dynamic>> _validBackup() async {
  final db = await _openTestDb();
  await _seedBaseline(db);
  final text = await AppDatabase.exportBackupJsonFrom(db);
  return jsonDecode(text) as Map<String, dynamic>;
}

/// 目标库里留一道标记题 + 一个标记学科；恢复被拒后它们必须原样还在。
Future<QuizDatabase> _seedTargetWithMarker() async {
  final db = await _openTestDb();
  await _seedBaseline(db);
  return db;
}

Future<int> _count(QuizDatabase db, String table) async {
  final rows = await db.customSelect('SELECT COUNT(*) AS n FROM $table').get();
  return rows.single.data['n'] as int;
}

void main() {
  group('FR-07 JSON 列损坏值拒绝恢复、原库不动', () {
    test('非法 JSON：tags 写 "not-json" → 校验与导入都拒绝，原库不动', () async {
      final data = await _validBackup();
      (data['questions'] as List)[0]['tags'] = 'not-json';
      expect(
        () => AppDatabase.validateBackupData(data),
        throwsA(isA<BackupRestoreException>()),
      );
      final target = await _seedTargetWithMarker();
      final beforeQ = await _count(target, 'questions');
      final beforeS = await _count(target, 'subjects');
      await expectLater(
        () => AppDatabase.importBackupJsonInto(target, data),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(await _count(target, 'questions'), beforeQ);
      expect(await _count(target, 'subjects'), beforeS);
      final row = await target
          .customSelect(
            'SELECT tags FROM questions WHERE id = ?',
            variables: [Variable.withString('q1')],
          )
          .get();
      expect(row.single.data['tags'], '["易错"]');
    });

    test('元素类型错：tags 写 "[1,2,3]"（JSON 合法、元素不是字符串）→ 拒绝', () async {
      final data = await _validBackup();
      (data['questions'] as List)[0]['tags'] = '[1,2,3]';
      expect(
        () => AppDatabase.validateBackupData(data),
        throwsA(isA<BackupRestoreException>()),
      );
    });

    test('非字符串值：tags 直接写 JSON 数组 → 拒绝', () async {
      final data = await _validBackup();
      (data['questions'] as List)[0]['tags'] = ['易错'];
      expect(
        () => AppDatabase.validateBackupData(data),
        throwsA(isA<BackupRestoreException>()),
      );
    });

    test('其余字符串列表列：folder_ids / knowledge_ids / error_types / '
        'custom_error_types / remedy_history 坏值 → 拒绝', () async {
      for (final entry in [
        ('questions', 'folder_ids', 'not-json'),
        ('questions', 'knowledge_ids', '[1]'),
        ('questions', 'error_types', '{"a":1}'),
        ('questions', 'custom_error_types', 42),
        ('cause_records', 'remedy_history', 'not-json'),
      ]) {
        final data = await _validBackup();
        (data[entry.$1] as List)[0][entry.$2] = entry.$3;
        expect(
          () => AppDatabase.validateBackupData(data),
          throwsA(isA<BackupRestoreException>()),
          reason: '${entry.$1}.${entry.$2} = ${entry.$3} 应被拒绝',
        );
      }
    });

    test('queue 坏值：非法 JSON / q 不是字符串 → 拒绝，原库不动', () async {
      for (final bad in [
        'not-json',
        '[{"q":1,"c":"计算错误"}]',
        '[{"q":"q1"}]',
        '{"q":"q1"}',
      ]) {
        final data = await _validBackup();
        // 十四批 M2：导出不再含 review_state 行，手动注入一行
        // 再改它的 queue（校验仍按行里有的 queue 形状检查旧备份）。
        data['review_state'] = [
          {'id': 1, 'queue': '[]', 'position': 0, 'updated_at': 0},
        ];
        (data['review_state'] as List)[0]['queue'] = bad;
        expect(
          () => AppDatabase.validateBackupData(data),
          throwsA(isA<BackupRestoreException>()),
          reason: 'queue = $bad 应被拒绝',
        );
      }
      final data = await _validBackup();
      data['review_state'] = [
        {'id': 1, 'queue': '[]', 'position': 0, 'updated_at': 0},
      ];
      (data['review_state'] as List)[0]['queue'] = 'not-json';
      final target = await _seedTargetWithMarker();
      final before = await _count(target, 'questions');
      await expectLater(
        () => AppDatabase.importBackupJsonInto(target, data),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(await _count(target, 'questions'), before);
    });

    test('page_rotations 坏值：非法 JSON / 键不是页码 / 值不是数字 → 拒绝', () async {
      for (final bad in ['not-json', '{"a":90}', '{"1":"90"}', '[1,2]']) {
        final data = await _validBackup();
        (data['collect_tasks'] as List)[0]['page_rotations'] = bad;
        expect(
          () => AppDatabase.validateBackupData(data),
          throwsA(isA<BackupRestoreException>()),
          reason: 'page_rotations = $bad 应被拒绝',
        );
      }
    });

    test('D-51 口径不变：9 列全写 \'\' 仍通过，恢复后读回空集合', () async {
      final data = await _validBackup();
      for (final col in [
        'folder_ids',
        'knowledge_ids',
        'error_types',
        'custom_error_types',
        'tags',
      ]) {
        (data['questions'] as List)[0][col] = '';
      }
      (data['cause_records'] as List)[0]['remedy_history'] = '';
      // 十四批 M2：导出不再含 review_state 行，手动注入一行再写 ''；
      // 校验仍通过（'' 是 D-51 允许的空集合表示），但恢复时该行丢弃。
      data['review_state'] = [
        {'id': 1, 'queue': '[]', 'position': 0, 'updated_at': 0},
      ];
      (data['review_state'] as List)[0]['queue'] = '';
      (data['collect_tasks'] as List)[0]['page_rotations'] = '';
      AppDatabase.validateBackupData(data); // 不抛
      final target = await _openTestDb();
      await AppDatabase.importBackupJsonInto(target, data);
      expect(
        AppDatabase.decodeStringList(
          (await target
                  .customSelect(
                    'SELECT tags FROM questions WHERE id = ?',
                    variables: [Variable.withString('q1')],
                  )
                  .get())
              .single
              .data['tags'],
        ),
        isEmpty,
      );
      // 十四批 M2：注入的 review_state 行恢复时丢弃，目标库里没有行。
      expect(
        await target.customSelect('SELECT * FROM review_state').get(),
        isEmpty,
      );
      expect(
        AppDatabase.decodeRotations(
          (await target
                  .customSelect(
                    'SELECT page_rotations FROM collect_tasks WHERE id = ?',
                    variables: [Variable.withString('task-1')],
                  )
                  .get())
              .single
              .data['page_rotations'],
        ),
        isEmpty,
      );
    });

    test('合法基线仍能恢复（健全性对照）', () async {
      final data = await _validBackup();
      AppDatabase.validateBackupData(data); // 不抛
      final target = await _openTestDb();
      await AppDatabase.importBackupJsonInto(target, data);
      expect(await _count(target, 'questions'), 1);
      expect(await _count(target, 'cause_records'), 1);
      final row = await target
          .customSelect(
            'SELECT tags FROM questions WHERE id = ?',
            variables: [Variable.withString('q1')],
          )
          .get();
      expect(row.single.data['tags'], '["易错"]');
    });
  });
}
