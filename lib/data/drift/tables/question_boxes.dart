// ARCH-PLAN-B 第 2 阶段：question_boxes 表的 Drift 定义。
// 与 lib/data/db_schema.dart 的 DDL 逐字对应（尖峰 B-SPIKE-REPORT.md §1
// 三路对比零差异，含 4 个索引与全部 8 个 CHECK 约束；部分唯一索引
// idx_boxes_one_layer1_per_question 走 @TableIndex.sql 原生 SQL）。
// `dontWriteConstraints` + 列内联自定义约束是尖峰确认的唯一可行配方
// （Drift 原生 primaryKey 会给主键列加 NOT NULL，与基线漂移）。

import 'package:drift/drift.dart';

@TableIndex.sql(
  'CREATE INDEX idx_boxes_task_page ON question_boxes(collect_task_id, page)',
)
@TableIndex.sql(
  'CREATE INDEX idx_boxes_question ON question_boxes(question_id)',
)
@TableIndex.sql(
  'CREATE INDEX idx_boxes_parent ON question_boxes(parent_box_id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX idx_boxes_one_layer1_per_question '
  'ON question_boxes(question_id) WHERE layer = 1 AND question_id IS NOT NULL',
)
/// 生成的行类叫 DbQuestionBox（不叫 QuestionBox）：Drift 默认按表名生成单数行类，
/// 会与 lib/models/models.dart 里的模型类同名，导致 import 歧义。
@DataClassName('DbQuestionBox')
class QuestionBoxes extends Table {
  @override
  bool get dontWriteConstraints => true;
  TextColumn get id => text().customConstraint('PRIMARY KEY')();
  TextColumn get collectTaskId => text().nullable()();
  TextColumn get questionId => text().nullable()();
  TextColumn get parentBoxId => text().nullable()();
  IntColumn get page =>
      integer().customConstraint('NOT NULL DEFAULT 1 CHECK (page >= 1)')();
  IntColumn get layer =>
      integer().customConstraint('NOT NULL CHECK (layer IN (1, 2))')();
  TextColumn get type => text().customConstraint(
    "NOT NULL CHECK (type IN ('question', 'stem', 'option', 'figure'))",
  )();
  RealColumn get x =>
      real().customConstraint('NOT NULL CHECK (x >= 0 AND x <= 1)')();
  RealColumn get y =>
      real().customConstraint('NOT NULL CHECK (y >= 0 AND y <= 1)')();
  RealColumn get w =>
      real().customConstraint('NOT NULL CHECK (w >= 0 AND w <= 1)')();
  RealColumn get h =>
      real().customConstraint('NOT NULL CHECK (h >= 0 AND h <= 1)')();
  RealColumn get confidence => real().nullable().customConstraint(
    'CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1))',
  )();
  TextColumn get origin => text().customConstraint(
    "NOT NULL DEFAULT 'manual' CHECK (origin IN ('yolo', 'manual'))",
  )();
  IntColumn get updatedAt => integer()();
}
