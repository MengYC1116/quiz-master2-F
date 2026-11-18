// ARCH-PLAN-B 第 2 阶段：collect_tasks 表的 Drift 定义。
// 与 lib/data/db_schema.dart 的 DDL 逐字对应（尖峰 B-SPIKE-REPORT.md §1
// 三路对比零差异）。`dontWriteConstraints` + 列内联自定义约束是尖峰确认的
// 唯一可行配方（Drift 原生 primaryKey 会给主键列加 NOT NULL，与基线漂移）。

import 'package:drift/drift.dart';

import '../converters.dart';

/// 生成的行类叫 DbCollectTask（不叫 CollectTask）：Drift 默认按表名生成单数行类，
/// 会与 lib/models/models.dart 里的模型类同名，导致 import 歧义。
@DataClassName('DbCollectTask')
class CollectTasks extends Table {
  @override
  bool get dontWriteConstraints => true;
  TextColumn get id => text().customConstraint('PRIMARY KEY')();
  TextColumn get name => text()();
  TextColumn get fileName => text()();
  TextColumn get subjectId => text()();
  TextColumn get status => text().withDefault(const Constant('queued'))();
  IntColumn get progress => integer().withDefault(const Constant(0))();
  IntColumn get pageCount => integer().withDefault(const Constant(1))();
  IntColumn get page => integer().withDefault(const Constant(1))();
  TextColumn get error => text().nullable()();
  TextColumn get questionId => text().nullable()();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  TextColumn get sourcePath => text().withDefault(const Constant(''))();
  TextColumn get pageRotations =>
      text().map(const RotationsConverter()).withDefault(const Constant('{}'))();

  /// 十二批 D-91：导入时存进来的原文件 SHA-256（contentHashOfFile）。
  /// 重试时重算库内原图的哈希比对，内容被换过即拒绝重试。旧行（v2
  /// 备份恢复、v2 库迁移而来）为 NULL——无基线可比，重试时跳过指纹
  /// 校验（仍受单候选 + 任务目录口径约束）。
  TextColumn get sourceHash => text().nullable()();
}
