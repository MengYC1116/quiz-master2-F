// D-172 备份校验白名单漏了 cancelled：取消识别包 2 给 OcrJobStatus
// 加了 cancelled，但备份校验 _validateBackupRowDomains 仍是手写旧 4 值，
// 含 cancelled 行的备份被误判损坏、恢复与预览都被拦住。修法是白名单
// 直接取 OcrJobStatus.values——这组测试锁住：含 cancelled 行的备份
// 校验通过且完整恢复、枚举全部值逐一过校验、非法值仍拒绝。
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/models/models.dart';

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
  // 包 2 取消识别后留下的行：status cancelled、OCR 字段已清、只留切片。
  await db.customInsert(
    'INSERT INTO ocr_jobs (id, question_id, crop_path, input_hash, '
    'status, attempt_count, available_at, started_at, lease_until, '
    'lease_token, last_error_code, last_error_message, created_at, '
    'updated_at, completed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '
    '?, ?, ?, ?)',
    variables: [
      Variable.withString('ocr-1795139221723-ad9c3bd5'),
      Variable.withString('q1'),
      Variable(null),
      Variable(null),
      Variable.withString('cancelled'),
      Variable.withInt(1),
      Variable(null),
      Variable(null),
      Variable(null),
      Variable(null),
      Variable(null),
      Variable(null),
      Variable.withInt(1700000000000),
      Variable.withInt(1700000001000),
      Variable.withInt(1700000001000),
    ],
  );
}

/// 导出一份含 cancelled 任务行的合法备份。
Future<Map<String, dynamic>> _validBackupWithCancelled() async {
  final db = await _openTestDb();
  await _seedBaseline(db);
  final text = await AppDatabase.exportBackupJsonFrom(db);
  return jsonDecode(text) as Map<String, dynamic>;
}

Future<String?> _jobStatus(QuizDatabase db, String id) async {
  final rows = await db
      .customSelect(
        'SELECT status FROM ocr_jobs WHERE id = ?',
        variables: [Variable.withString(id)],
      )
      .get();
  if (rows.isEmpty) return null;
  return rows.single.data['status'] as String?;
}

void main() {
  group('D-172 备份校验接受 cancelled 任务行', () {
    test('含 cancelled 行的备份：校验通过，恢复后行在库里、status 仍是 cancelled',
        () async {
      final data = await _validBackupWithCancelled();
      // 修前复现：这里抛“不是合法的任务状态 …：cancelled”。
      AppDatabase.validateBackupData(data);

      final target = await _openTestDb();
      await AppDatabase.importBackupJsonInto(target, data);
      expect(
        await _jobStatus(target, 'ocr-1795139221723-ad9c3bd5'),
        'cancelled',
      );
    });

    test('OcrJobStatus.values 每个值都过校验（防以后加枚举值再脱节）',
        () async {
      final data = await _validBackupWithCancelled();
      final jobs = data['ocr_jobs'] as List;
      expect(jobs, hasLength(1));
      for (final s in OcrJobStatus.values) {
        (jobs[0] as Map)['status'] = s.name;
        AppDatabase.validateBackupData(data); // 不抛
      }
    });

    test('非法 status 仍拒绝：校验与导入都抛，文案列出合法值', () async {
      final data = await _validBackupWithCancelled();
      ((data['ocr_jobs'] as List)[0] as Map)['status'] = 'bogus';
      expect(
        () => AppDatabase.validateBackupData(data),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.message,
            'message',
            contains('cancelled'),
          ),
        ),
      );
      final target = await _openTestDb();
      await expectLater(
        () => AppDatabase.importBackupJsonInto(target, data),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(
        await _jobStatus(target, 'ocr-1795139221723-ad9c3bd5'),
        isNull,
      );
    });
  });
}
