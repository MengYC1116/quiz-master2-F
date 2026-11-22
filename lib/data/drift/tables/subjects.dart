// ARCH-PLAN-B 第 2 阶段：subjects 表的 Drift 定义。
// 与 lib/data/db_schema.dart 的 DDL 逐字对应（尖峰 B-SPIKE-REPORT.md §1
// 三路对比零差异）。`dontWriteConstraints` + 列内联自定义约束是尖峰确认的
// 唯一可行配方（Drift 原生 primaryKey 会给主键列加 NOT NULL，与基线漂移）。

import 'package:drift/drift.dart';

/// 生成的行类叫 DbSubject（不叫 Subject）：Drift 默认按表名生成单数行类，
/// 会与 lib/models/models.dart 里的模型类同名，导致 import 歧义。
@DataClassName('DbSubject')
class Subjects extends Table {
  @override
  bool get dontWriteConstraints => true;
  TextColumn get id => text().customConstraint('PRIMARY KEY')();
  TextColumn get name => text()();
  IntColumn get color => integer()();
  TextColumn get coverStyle => text().withDefault(const Constant('plain'))();
  TextColumn get coverColor => text().withDefault(const Constant('blue'))();
  // D-257：书封英文名（GLM 翻译或手动填；可空，NULL = 没有）与
  // 是否手动填过（0/1，默认 0；手动填过的不再被自动翻译覆盖）。
  TextColumn get englishName => text().nullable()();
  IntColumn get englishNameManual =>
      integer().withDefault(const Constant(0))();
}
