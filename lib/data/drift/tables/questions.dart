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

  /// 十三批 M2：OCR 字段（与 db_schema.dart 的 DDL 逐字对应）。
  /// ocrRaw 是 GLM 原始结果（内部存，绝不外露）；ocrStem 是切分后题干；
  /// ocrSplitStatus 取值见 OcrSplitStatus（未切分 / 自动切分 /
  /// 存在歧义 / 人工调整）；ocrManualEdited 是人工编辑标记（0/1）；
  /// contentVersion 是内容版本（默认 0，递增规则由 M3 定）。
  TextColumn get ocrRaw => text().nullable()();
  TextColumn get ocrStem => text().nullable()();
  TextColumn get ocrSplitStatus =>
      text().withDefault(const Constant('未切分'))();
  IntColumn get ocrManualEdited => integer().withDefault(const Constant(0))();
  IntColumn get contentVersion => integer().withDefault(const Constant(0))();

  /// 十四批 M1：题型两维 + 答案版本（与 db_schema.dart 的 DDL 逐字对应）。
  /// questionType 是主题型（NULL = 待确认）；questionTypeSource 取值
  /// auto/manual/unclassified；questionBackgroundTags 是逗号分隔的背景
  /// 标签（第一版只自动生成“材料”“听力”）；questionBackgroundTagsSource
  /// 只保护背景标签；ocrFigures 是图块 JSON（M2 写，M1 只建列）；
  /// correctOption 只用于单选/判断；optionLabels 是 JSON 选项标签数组
  ///（NULL = 未确认）；optionLabelsConfirmed 须点“确认选项”才置 1；
  /// answerVersion 是答案版本（默认 1）。
  TextColumn get questionType => text().nullable()();
  TextColumn get questionTypeSource =>
      text().withDefault(const Constant('unclassified'))();
  TextColumn get questionBackgroundTags =>
      text().withDefault(const Constant(''))();
  TextColumn get questionBackgroundTagsSource =>
      text().withDefault(const Constant('unclassified'))();
  TextColumn get ocrFigures => text().withDefault(const Constant('[]'))();
  TextColumn get correctOption => text().nullable()();
  TextColumn get optionLabels =>
      text().nullable().map(const NullableStringListConverter())();
  IntColumn get optionLabelsConfirmed =>
      integer().withDefault(const Constant(0))();
  IntColumn get answerVersion => integer().withDefault(const Constant(1))();

  /// 十四批 M3（P1-A）：答案待重新核对标记（改标签后未重新确认时置 1）。
  IntColumn get answerPendingRecheck =>
      integer().withDefault(const Constant(0))();
}
