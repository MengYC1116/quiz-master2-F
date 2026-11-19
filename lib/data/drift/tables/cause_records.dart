// ARCH-PLAN-B 第 2 阶段：cause_records 表的 Drift 定义。
// 与 lib/data/db_schema.dart 的 DDL 逐字对应（尖峰 B-SPIKE-REPORT.md §1
// 三路对比零差异）。`dontWriteConstraints` + 列内联自定义约束是尖峰确认的
// 唯一可行配方（Drift 原生 primaryKey 会给主键列加 NOT NULL，与基线漂移）。

import 'package:drift/drift.dart';

import '../converters.dart';

/// 生成的行类叫 DbCauseRecord（不叫 CauseRecord）：Drift 默认按表名生成单数行类，
/// 会与 lib/models/models.dart 里的模型类同名，导致 import 歧义。
@DataClassName('DbCauseRecord')
class CauseRecords extends Table {
  @override
  bool get dontWriteConstraints => true;
  IntColumn get id => integer().customConstraint('PRIMARY KEY AUTOINCREMENT')();
  TextColumn get questionId => text()();
  TextColumn get cause => text()();
  TextColumn get subjectId => text()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  IntColumn get solvedCount => integer().withDefault(const Constant(0))();
  IntColumn get lastCheck => integer().nullable()();
  IntColumn get recheckDate => integer().nullable()();
  TextColumn get remedyHistory =>
      text().map(const StringListConverter()).withDefault(const Constant(''))();
  IntColumn get joinedAt => integer()();

  /// 十四批 M1（M3-7 的 24 小时锚点链）：上一次计入治愈次数的成功
  /// 时间（毫秒时间戳，可空）与所在会话（可空）；“未解决”重置时两者清空。
  IntColumn get lastCountedSuccessAt => integer().nullable()();
  TextColumn get lastCountedSessionId => text().nullable()();

  @override
  List<String> get customConstraints => ['UNIQUE ("question_id", "cause")'];
}
