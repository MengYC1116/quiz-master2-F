// 十四批 M1：attempts 表的 Drift 定义（v5 新表，M3-14）。
// 与 lib/data/db_schema.dart 的 DDL 逐字对应。`dontWriteConstraints` +
// 列内联自定义约束是尖峰确认的唯一可行配方。
//
// 一条 attempt 是一次实际作答（只在用户真正作答时创建；只跳过、从未作答
// 的题不建 attempt）。一次会话每题一条：UNIQUE(session_id, question_id)，
// 跳过后重遇更新/继续同一条记录。submission_id 是该 attempt 的稳定 uuid
//（TEXT UNIQUE，幂等去重；不与多条 cause history 的子级 submission_id
// 共用）。status 只取 已提交/已完成作答/跳过（“未作答”不在枚举内）。
// correct：1/0/NULL（无标准答案或不判分时为 NULL）；confidence：
// 确定/不太确定/猜的，填空/解答为 NULL；answer_version 与 content_version
// 一起固定作答时的版本，历史 attempts 永不按新答案重新判分；cause_ids
// 是 JSON（本次作答关联的本轮错因 id 列表，仅作上下文，绝不把题目级对错
// 统计成各错因的对错）；duration_ms 是粗略耗时，可空，不作掌握证据。

import 'package:drift/drift.dart';

/// 生成的行类叫 DbAttempt。
@DataClassName('DbAttempt')
class Attempts extends Table {
  @override
  bool get dontWriteConstraints => true;
  TextColumn get id => text().customConstraint('PRIMARY KEY')();
  TextColumn get questionId => text()();
  TextColumn get sessionId => text()();
  TextColumn get mode => text()();
  TextColumn get selected => text().nullable()();
  IntColumn get correct => integer().nullable()();
  TextColumn get confidence => text().nullable()();
  IntColumn get answerVersion => integer().withDefault(const Constant(1))();
  IntColumn get contentVersion => integer().withDefault(const Constant(0))();
  TextColumn get status => text()();
  TextColumn get causeIds => text().withDefault(const Constant('[]'))();
  IntColumn get durationMs => integer().nullable()();
  TextColumn get submissionId => text().customConstraint('UNIQUE')();
  IntColumn get createdAt => integer()();

  @override
  List<String> get customConstraints => [
    'UNIQUE ("session_id", "question_id")',
  ];
}
