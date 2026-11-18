// D-101：备份恢复校验器按每张表的真实主键列校验。
// 根因：_validateBackupRow 默认所有非整数主键表的主键都叫 `id`，但
// recently_viewed_questions 的主键是 question_id，根本没有 id 列——
// 有浏览历史的备份一恢复就报“缺少主键 id”（备份本身没坏）。
// 本文件：(a) 4 条浏览历史的备份往返恢复成功；(b) 缺 question_id
// 的行被拒绝、原库不动；(c) SR2-16 空串/类型错口径落在 question_id
// 上；(d) 只有 id、没有 question_id 的行仍被拒绝。
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

Future<void> _seedWithHistory(QuizDatabase db, {int historyRows = 4}) async {
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
  for (var i = 1; i <= historyRows; i++) {
    await db.customInsert(
      'INSERT INTO questions (id, title, subject_id, folder_ids, '
      'knowledge_ids, error_types, custom_error_types, tags, created_at, '
      'slice_kind, slice_text, source_path, source_kind, source_page, '
      'page_image_path, slice_path, is_demo) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable.withString('q$i'),
        Variable.withString('题 q$i'),
        Variable.withString('math'),
        Variable.withString('["f1"]'),
        Variable.withString('[]'),
        Variable.withString('["计算错误"]'),
        Variable.withString('[]'),
        Variable.withString('[]'),
        Variable.withInt(1700000000000 + i),
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
      'INSERT INTO recently_viewed_questions (question_id, viewed_at) '
      'VALUES (?, ?)',
      variables: [
        Variable.withString('q$i'),
        Variable.withInt(1700000000000 + i * 1000),
      ],
    );
  }
}

/// 导出一份含浏览历史的合法备份。
Future<Map<String, dynamic>> _validBackupWithHistory() async {
  final db = await _openTestDb();
  await _seedWithHistory(db);
  final text = await AppDatabase.exportBackupJsonFrom(db);
  return jsonDecode(text) as Map<String, dynamic>;
}

Future<int> _count(QuizDatabase db, String table) async {
  final rows = await db.customSelect('SELECT COUNT(*) AS n FROM $table').get();
  return rows.single.data['n'] as int;
}

Future<List<Map<String, Object?>>> _historyRows(QuizDatabase db) async {
  final rows = await db
      .customSelect(
        'SELECT question_id, viewed_at FROM recently_viewed_questions '
        'ORDER BY viewed_at',
      )
      .get();
  return rows.map((r) => r.data).toList();
}

void main() {
  group('D-101 备份恢复按真实主键列校验（recently_viewed_questions）', () {
    test('(a) 4 条浏览历史的备份往返恢复成功', () async {
      final data = await _validBackupWithHistory();
      expect((data['recently_viewed_questions'] as List).length, 4);
      AppDatabase.validateBackupData(data); // 不抛
      final target = await _openTestDb();
      await AppDatabase.importBackupJsonInto(target, data);
      expect(await _count(target, 'recently_viewed_questions'), 4);
      final rows = await _historyRows(target);
      expect(
        rows.map((r) => r['question_id']).toList(),
        ['q1', 'q2', 'q3', 'q4'],
      );
      expect(
        rows.map((r) => r['viewed_at']).toList(),
        [1700000001000, 1700000002000, 1700000003000, 1700000004000],
      );
    });

    test('(b) 缺 question_id 的行被拒绝，原库不动', () async {
      final data = await _validBackupWithHistory();
      (data['recently_viewed_questions'] as List)[1].remove('question_id');
      expect(
        () => AppDatabase.validateBackupData(data),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.message,
            'message',
            contains('recently_viewed_questions 表里有行缺少主键 question_id'),
          ),
        ),
      );
      final target = await _openTestDb();
      await _seedWithHistory(target);
      final before = await _count(target, 'recently_viewed_questions');
      await expectLater(
        () => AppDatabase.importBackupJsonInto(target, data),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(await _count(target, 'recently_viewed_questions'), before);
    });

    test('(c) question_id 为空串 / 非字符串被拒绝（SR2-16 落在真实主键列上）', () async {
      for (final bad in ['', 42]) {
        final data = await _validBackupWithHistory();
        (data['recently_viewed_questions'] as List)[0]['question_id'] = bad;
        expect(
          () => AppDatabase.validateBackupData(data),
          throwsA(isA<BackupRestoreException>()),
          reason: 'question_id = $bad 应被拒绝',
        );
      }
    });

    test('(d) 只有 id、没有 question_id 的行仍被拒绝', () async {
      final data = await _validBackupWithHistory();
      final row =
          (data['recently_viewed_questions'] as List)[0] as Map<String, dynamic>;
      row.remove('question_id');
      row['id'] = 'q1';
      expect(
        () => AppDatabase.validateBackupData(data),
        throwsA(isA<BackupRestoreException>()),
      );
    });

    test('(e) 空历史备份仍能恢复（健全性对照：修前唯一能过的情形）', () async {
      final db = await _openTestDb();
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
      final data =
          jsonDecode(await AppDatabase.exportBackupJsonFrom(db))
              as Map<String, dynamic>;
      expect(data['recently_viewed_questions'], isEmpty);
      AppDatabase.validateBackupData(data); // 不抛
      final target = await _openTestDb();
      await AppDatabase.importBackupJsonInto(target, data);
      expect(await _count(target, 'recently_viewed_questions'), 0);
    });
  });
}
