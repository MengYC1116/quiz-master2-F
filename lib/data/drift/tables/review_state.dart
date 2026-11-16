// ARCH-PLAN-B 第 2 阶段：review_state 表的 Drift 定义。
// 与 lib/data/db_schema.dart 的 DDL 逐字对应（尖峰 B-SPIKE-REPORT.md §1
// 三路对比零差异）。`dontWriteConstraints` + 列内联自定义约束是尖峰确认的
// 唯一可行配方（Drift 原生 primaryKey 会给主键列加 NOT NULL，与基线漂移）。
//
// 注意：本文件的类名 ReviewState 与 lib/state/review_notifier.dart 里的
// ReviewState（复习页状态）同名，不在同一库，不冲突；但在同时 import 两者
// 的文件里须用 hide / as 处理——数据层文件不 import state 层，无此问题。

import 'package:drift/drift.dart';

import '../converters.dart';

/// 生成的行类叫 DbReviewState（不叫 ReviewState）：Drift 默认按表名生成行类，
/// 会与 lib/models/models.dart / lib/state/review_notifier.dart 里的同名类
/// 冲突，导致 import 歧义。
@DataClassName('DbReviewState')
class ReviewState extends Table {
  @override
  bool get dontWriteConstraints => true;
  IntColumn get id =>
      integer().customConstraint('PRIMARY KEY CHECK (id = 1)')();
  TextColumn get queue =>
      text().map(const QueueConverter()).withDefault(const Constant(''))();
  IntColumn get position => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer()();
}
