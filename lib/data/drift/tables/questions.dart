// ARCH-PLAN-B 第 2 阶段：questions 表的 Drift 定义。
// 与 lib/data/db_schema.dart 的 DDL 逐字对应（尖峰 B-SPIKE-REPORT.md §1
// 三路对比零差异）。`dontWriteConstraints` + 列内联自定义约束是尖峰确认的
// 唯一可行配方（Drift 原生 primaryKey 会给主键列加 NOT NULL，与基线漂移）。

import 'package:drift/drift.dart';

import '../converters.dart';

/// 生成的行类叫 DbQuestion（不叫 Question）：Drift 默认按表名生成单数行类，
/// 会与 lib/models/models.dart 里的模型类同名，导致 import 歧义。
@DataClassName('DbQuestion')
class Questions extends Table {
  @override
  bool get dontWriteConstraints => true;
  TextColumn get id => text().customConstraint('PRIMARY KEY')();
  TextColumn get title => text()();
  TextColumn get subjectId => text()();
  TextColumn get folderIds =>
      text().map(const StringListConverter()).withDefault(const Constant(''))();
  TextColumn get examId => text().nullable()();
  TextColumn get knowledgeIds =>
      text().map(const StringListConverter()).withDefault(const Constant(''))();
  TextColumn get errorTypes =>
      text().map(const StringListConverter()).withDefault(const Constant(''))();
  TextColumn get customErrorTypes =>
      text().map(const StringListConverter()).withDefault(const Constant(''))();
  TextColumn get tags =>
      text().map(const StringListConverter()).withDefault(const Constant(''))();
  TextColumn get answer => text().nullable()();
  TextColumn get explanation => text().nullable()();
  TextColumn get notes => text().nullable()();
  IntColumn get reviewCount => integer().withDefault(const Constant(0))();
  IntColumn get isOrganized => integer().withDefault(const Constant(0))();
  IntColumn get isDemo => integer().withDefault(const Constant(0))();
  IntColumn get isFavorite => integer().withDefault(const Constant(0))();
  IntColumn get isArchived => integer().withDefault(const Constant(0))();
  IntColumn get reviewJoined => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer()();
  TextColumn get sliceKind => text().withDefault(const Constant('material'))();
  TextColumn get sliceText => text().withDefault(const Constant(''))();
  TextColumn get sourcePath => text().nullable()();
  TextColumn get sourceKind => text().nullable()();
  IntColumn get sourcePage => integer().nullable()();
  TextColumn get pageImagePath => text().nullable()();
  TextColumn get slicePath => text().nullable()();
  IntColumn get sliceWidth => integer().nullable()();
  IntColumn get sliceHeight => integer().nullable()();
}
