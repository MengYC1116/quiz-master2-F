// 十三批 M2：ocr_jobs 表的 Drift 定义（OCR 持久化队列，GPT 评审 §2.2）。
// 与 lib/data/db_schema.dart 的 DDL 逐字对应（尖峰 B-SPIKE-REPORT.md §1
// 三路对比零差异的配方）：`dontWriteConstraints` + 列内联自定义约束。
// 时间全是 INTEGER 毫秒时间戳（与项目既有约定一致）；status 存
// OcrJobStatus 的枚举名（见 lib/models/models.dart，D-172）。
// 本文件只定义表结构，不含队列 worker 逻辑（那是 M3 的事）。

import 'package:drift/drift.dart';

/// 生成的行类叫 DbOcrJob（不叫 OcrJob）：Drift 默认按表名生成单数行类，
/// 会与 lib/models/models.dart 里的模型类同名，导致 import 歧义。
@DataClassName('DbOcrJob')
class OcrJobs extends Table {
  @override
  bool get dontWriteConstraints => true;
  TextColumn get id => text().customConstraint('PRIMARY KEY')();
  TextColumn get questionId => text()();
  TextColumn get cropPath => text().nullable()();
  TextColumn get inputHash => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  IntColumn get availableAt => integer().nullable()();
  IntColumn get startedAt => integer().nullable()();
  IntColumn get leaseUntil => integer().nullable()();
  // 十三批 P1-1：租约 token（claim 时生成，complete/fail/retry/
  // markAttempt 时校验持有者；回收/终态时清掉）。
  TextColumn get leaseToken => text().nullable()();
  TextColumn get lastErrorCode => text().nullable()();
  TextColumn get lastErrorMessage => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get completedAt => integer().nullable()();
}
