// ARCH-PLAN-B 第 1 阶段：Drift 数据库对象（驱动切换）。
// 独立 library 文件（不是 part 文件——Dart 规定 part 文件里不能再声明
// part，而 drift_dev 生成的 quiz_database.g.dart 必须作为它的 part）。
// 第 2 阶段：13 张表定义在 lib/data/drift/tables/（每表一个文件，
// 尖峰 B-SPIKE-REPORT.md §1 三路对比零差异的配方），此处注册进 tables；
// 建表仍走 database.dart 的 createTablesImpl（customStatement 原样 DDL），
// onCreate 只调注入的回调，不由 Drift 生成建表——注册表只提供类型化查询，
// 不改变建库行为。
//
// 回调注入的原因：建表 / 播种 / 回填逻辑在 database.dart 的 part 库里，
// 本文件不能反向 import 它（会循环）。因此 onCreate 只调注入的
// onCreateTables 回调，beforeOpen 只调注入的 onBeforeOpen 回调。
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:quiz_master2/models/models.dart'; // 生成文件里 QueueConverter
// 用到 ReviewQueueItem（part 文件只认本文件的 import，不认 converters.dart 的）。
import 'converters.dart'; // 生成文件里用到 StringListConverter 等转换器，同上。

import 'tables/cause_records.dart';
import 'tables/collect_tasks.dart';
import 'tables/exams.dart';
import 'tables/folders.dart';
import 'tables/knowledge_points.dart';
import 'tables/question_boxes.dart';
import 'tables/questions.dart';
import 'tables/recent_tasks.dart';
import 'tables/review_history.dart';
import 'tables/review_state.dart';
import 'tables/settings.dart';
import 'tables/subjects.dart';
import 'tables/tags.dart';

part 'quiz_database.g.dart';

@DriftDatabase(
  tables: [
    Settings,
    Tags,
    Exams,
    KnowledgePoints,
    Folders,
    Subjects,
    RecentTasks,
    ReviewHistory,
    CauseRecords,
    ReviewState,
    CollectTasks,
    QuestionBoxes,
    Questions,
  ],
)
class QuizDatabase extends _$QuizDatabase {
  QuizDatabase.file(
    File file, {
    this.onCreateTables,
    this.onBeforeOpen,
  }) : super(NativeDatabase(file));

  QuizDatabase.memory({
    this.onCreateTables,
    this.onBeforeOpen,
  }) : super(NativeDatabase.memory());

  /// 建库时调：建表 + 播种（database.dart 的 createTablesImpl + _seed）。
  final Future<void> Function(QuizDatabase db)? onCreateTables;

  /// 每次打开库、迁移跑完、其他查询尚未发送时调：B9-1 回填
  ///（database.dart 的 backfillCollectDoneIntoImpl）。
  final Future<void> Function(QuizDatabase db)? onBeforeOpen;

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await onCreateTables?.call(this);
    },
    // Drift 2.35 的 MigrationStrategy 没有独立的 onDowngrade 槽位：
    // 升版与降版都走 onUpgrade（from < to 为升版，from > to 为降版），
    // 因此在这里按 from/to 分流，两种都抛 StateError——任何迁移
    // 触发都是 bug（v2 库无迁移历史，老库由打开前的
    // deleteLegacyDatabaseIfPresent 预检删掉）。
    onUpgrade: (m, from, to) async {
      if (from > to) {
        throw StateError(
          '数据库是新版格式（v$from），请用新版打开（当前要求 v$to）',
        );
      }
      throw StateError('意外的数据库迁移 from=$from to=$to');
    },
    beforeOpen: (details) async {
      await onBeforeOpen?.call(this);
    },
  );
}
