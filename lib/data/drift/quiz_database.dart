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
import 'tables/recently_viewed_questions.dart';
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
    RecentlyViewedQuestions,
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
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await onCreateTables?.call(this);
    },
    // Drift 2.35 的 MigrationStrategy 没有独立的 onDowngrade 槽位：
    // 升版与降版都走 onUpgrade（from < to 为升版，from > to 为降版）。
    // 十二批 D-91：v2 → v3 是本项目第一次真正的迁移——建
    // recently_viewed_questions 表 + collect_tasks 加 source_hash 列，
    // 数据全保留。其它 from/to 一律抛错：v1 及更老由打开前的
    // deleteLegacyDatabaseIfPresent 预检删掉；from > to（新版库用旧版
    // 打开）请用新版打开。
    onUpgrade: (m, from, to) async {
      if (from == 2 && to == 3) {
        // DDL 必须与 createTablesImpl 的手写字面量一字不差（B1 纪律：
        // 迁移后的库与全新 v3 库在 sqlite_master 里逐字一致）。Drift 的
        // m.createTable / m.addColumn 生成的 DDL 带引号（"source_hash"
        // TEXT NULL），与手写文本不一致，故此处走 customStatement，
        // 用同一份字面量；语义与 Drift 生成的 DDL 等价。
        await m.database.customStatement(
          'CREATE TABLE recently_viewed_questions(\n'
          '  question_id TEXT PRIMARY KEY, viewed_at INTEGER NOT NULL)',
        );
        await m.database.customStatement(
          'ALTER TABLE collect_tasks ADD COLUMN source_hash TEXT',
        );
        // settings 里的 schemaVersion 也写回 3，与 user_version 一致
        // （真实 v2 库的 settings 本来就有这行；手造夹具库若缺这行，
        // insertOrReplace 会补一行）。本文件是独立 library，不能调
        // database.dart 库私有的 _upsertSettingInto；attachedDatabase
        // 的静态类型是 GeneratedDatabase，cast 后走 Drift 类型化写入。
        final db = attachedDatabase as QuizDatabase;
        await db.into(db.settings).insert(
          SettingsCompanion.insert(key: 'schemaVersion', value: '3'),
          mode: InsertMode.insertOrReplace,
        );
        return;
      }
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
