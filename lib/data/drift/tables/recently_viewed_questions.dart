// 十二批功能 4（D-91）：最近查看的题。
// 与 lib/data/db_schema.dart 的 DDL 逐字对应（尖峰 B-SPIKE-REPORT.md §1
// 三路对比零差异的配方）：`dontWriteConstraints` + 列内联自定义约束。
// question_id 主键——同一题只留一条，viewed_at 更新为最后一次浏览时间；
// viewed_at 为毫秒时间戳。

import 'package:drift/drift.dart';

class RecentlyViewedQuestions extends Table {
  @override
  bool get dontWriteConstraints => true;
  TextColumn get questionId => text().customConstraint('PRIMARY KEY')();
  IntColumn get viewedAt => integer()();
}
