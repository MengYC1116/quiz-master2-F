// 十四批 M1：review_history 表的 Drift 定义（新增 8 列）。
// 与 lib/data/db_schema.dart 的 DDL 逐字对应（尖峰 B-SPIKE-REPORT.md §1
// 三路对比零差异）。`dontWriteConstraints` + 列内联自定义约束是尖峰确认的
// 唯一可行配方（Drift 原生 primaryKey 会给主键列加 NOT NULL，与基线漂移）。
//
// 新增列（M3-14）：cause_id（错因稳定身份）、session_id（会话）、
// review_mode（只允许 '到期复习'，DDL 用 CHECK 限定；专项练习不写本表）、
// verdict（已解决/未解决/不确定）、verification_status（已核验/未核验）、
// verification_source（软件标准答案/客观判分/外部资料核对/未核验，与
// verification_status 成对出现，DDL 用 CHECK 限定）、attempt_id（核验依据
// 的 attempt id，客观判分时必填）、submission_id（子级提交 id，UNIQUE）。
// 旧行以上列均为 NULL；新行 result 与 verdict 同值（result 保留兼容）。
// 注意：submission_id 的 UNIQUE 不写在列定义里——SQLite 禁止
// ALTER TABLE ADD COLUMN 带 UNIQUE 约束，唯一性由独立唯一索引
// idx_review_history_submission 保证（见 db_schema.dart）。

import 'package:drift/drift.dart';

/// 生成的行类叫 DbReviewHistory（不叫 ReviewHistory）：Drift 默认按表名生成
/// 单数行类，会与 lib/models/models.dart 里的模型类同名，导致 import 歧义。
@DataClassName('DbReviewHistory')
class ReviewHistory extends Table {
  @override
  bool get dontWriteConstraints => true;
  IntColumn get id => integer().customConstraint('PRIMARY KEY AUTOINCREMENT')();
  TextColumn get questionId => text()();
  TextColumn get result => text()();
  IntColumn get reviewedAt => integer()();
  TextColumn get causeId => text().nullable()();
  TextColumn get sessionId => text().nullable()();
  TextColumn get reviewMode => text().nullable()();
  TextColumn get verdict => text().nullable()();
  TextColumn get verificationStatus => text().nullable()();
  TextColumn get verificationSource => text().nullable()();
  TextColumn get attemptId => text().nullable()();
  TextColumn get submissionId => text().nullable()();
}
