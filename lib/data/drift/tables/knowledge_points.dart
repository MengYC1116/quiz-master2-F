// ARCH-PLAN-B 第 2 阶段：knowledge_points 表的 Drift 定义。
// 与 lib/data/db_schema.dart 的 DDL 逐字对应（尖峰 B-SPIKE-REPORT.md §1
// 三路对比零差异）。`dontWriteConstraints` + 列内联自定义约束是尖峰确认的
// 唯一可行配方（Drift 原生 primaryKey 会给主键列加 NOT NULL，与基线漂移）。

import 'package:drift/drift.dart';

/// 生成的行类叫 DbKnowledgePoint（不叫 KnowledgePoint）：Drift 默认按表名
/// 生成单数行类，会与 lib/models/models.dart 里的模型类同名，导致 import 歧义。
@DataClassName('DbKnowledgePoint')
class KnowledgePoints extends Table {
  @override
  bool get dontWriteConstraints => true;
  TextColumn get id => text().customConstraint('PRIMARY KEY')();
  TextColumn get subjectId => text()();
  TextColumn get chapter => text()();
  TextColumn get name => text()();
}
