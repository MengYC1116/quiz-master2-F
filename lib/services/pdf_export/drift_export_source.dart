// 十五批 M1-E：生产数据源 DriftExportQuestionSource（M1-DESIGN.md §6，
// M1-B 待办）。
//
// 读 Drift 行 + 数据目录文件：
// - [fetchQuestions]：批量读（M3-F）：一次读齐题目行（`id.isIn(ids)`）
//   + 文件夹名（`folders` 表一次查询，按 `questions.folder_ids`
//   收集的 ID）+ 考试名（`exams` 表一次查询，按 `exam_id` 收集的 ID）。
//   文件夹归属不是连接表——`folder_ids` 是 questions 表上的 JSON
//   文本列（StringListConverter），一题可进多个文件夹；考试是
//   `exam_id` 列（可空单个）。已删除的文件夹/考试按“无”计（跳过该
//   名 / 考试名取 null，与错题本列表的字幕口径一致）。
//   整个导出最多 50 道题，三次查询即够，不逐题 N+1。
// - [fetchQuestion]：单题入口，走同一批量路径。
// - [optionContentsJson] 取 Drift 行原始字符串（`DbQuestion.optionContents`），
//   不走 `Question` 模型已解码的 Map——损坏的 JSON 在模型层会变成 null，
//   与 NULL（未解析）无法区分（§5 情形 (c) 要求区分两者）。
// - [openSliceBytes] / [readSliceHead]：经 `AppDatabase.resolveDataPath`
//   把库内相对路径解析到数据目录文件；缺失/不可读按契约报告
//   （openSliceBytes 抛 [SliceUnavailableException]，readSliceHead 返回 null）。
//   调用方须在 [SliceWriteGuard] 锁内调 openSliceBytes（与写入入口串行化）。
//
// 注意：快照“一次 Drift transaction 内读齐”在本实现里是批量顺序读
// （ExportQuestionSource 的 fetchQuestions 是批量接口）；跨题的同一时刻性
// 由快照终态复核（D-178：内容版本 + 源切片哈希 + 文件夹/考试名）兜底，
// 发现变化整单失效。
// 不动 lib/data/（只读已有公开接口），schema v6 不动。
import 'dart:io';
import 'dart:typed_data';

import '../../data/database.dart';
import '../../data/drift/quiz_database.dart';
import 'export_question_record.dart';

/// 生产数据源：Drift 行 + 数据目录文件。
class DriftExportQuestionSource implements ExportQuestionSource {
  const DriftExportQuestionSource();

  @override
  Future<ExportQuestionRecord?> fetchQuestion(String id) async =>
      (await fetchQuestions([id])).first;

  @override
  Future<List<ExportQuestionRecord?>> fetchQuestions(
    List<String> ids,
  ) async {
    final db = await AppDatabase.instance.db;
    final rows = ids.isEmpty
        ? const <DbQuestion>[]
        : await (db.select(
            db.questions,
          )..where((t) => t.id.isIn(ids))).get();
    final byId = {for (final r in rows) r.id: r};
    // 文件夹名：按全部题的 folder_ids 一次查 folders 表。
    final folderNames = <String, String>{};
    final folderIds = rows.expand((r) => r.folderIds).toSet();
    if (folderIds.isNotEmpty) {
      final folderRows = await (db.select(
        db.folders,
      )..where((t) => t.id.isIn(folderIds))).get();
      for (final f in folderRows) {
        folderNames[f.id] = f.name;
      }
    }
    // 考试名：按全部题的 exam_id 一次查 exams 表。
    final examNames = <String, String>{};
    final examIds = rows
        .map((r) => r.examId)
        .whereType<String>()
        .toSet();
    if (examIds.isNotEmpty) {
      final examRows = await (db.select(
        db.exams,
      )..where((t) => t.id.isIn(examIds))).get();
      for (final e in examRows) {
        examNames[e.id] = e.name;
      }
    }
    return [
      for (final id in ids)
        byId[id] == null
            ? null
            : _recordFromRow(byId[id]!, folderNames, examNames),
    ];
  }

  ExportQuestionRecord _recordFromRow(
    DbQuestion row,
    Map<String, String> folderNames,
    Map<String, String> examNames,
  ) {
    return ExportQuestionRecord(
      id: row.id,
      title: row.title,
      subjectId: row.subjectId,
      slicePath: row.slicePath,
      sliceWidth: row.sliceWidth,
      sliceHeight: row.sliceHeight,
      ocrRaw: row.ocrRaw,
      ocrStem: row.ocrStem,
      // 关键：取行原始字符串，不走模型解码（见文件头）。
      optionContentsJson: row.optionContents,
      optionContentsParserVersion: row.optionContentsParserVersion,
      questionType: row.questionType,
      ocrFigures: row.ocrFigures,
      answer: row.answer,
      explanation: row.explanation,
      ocrManualEdited: row.ocrManualEdited == 1,
      contentVersion: row.contentVersion,
      answerPendingRecheck: row.answerPendingRecheck == 1,
      // M3-F：文件夹按 folder_ids 顺序取展示名（已删的跳过），
      // 考试按 exam_id 取展示名（无考试 / 已删的考试取 null）。
      folderNames: [
        for (final folderId in row.folderIds)
          if (folderNames.containsKey(folderId)) folderNames[folderId]!,
      ],
      examName: row.examId == null ? null : examNames[row.examId],
    );
  }

  @override
  Stream<List<int>> openSliceBytes(ExportQuestionRecord record) {
    final abs = _resolveSlicePath(record);
    if (abs == null) {
      throw SliceUnavailableException('题目 ${record.id} 切片不可用');
    }
    final file = File(abs);
    if (!file.existsSync()) {
      throw SliceUnavailableException('题目 ${record.id} 切片文件缺失');
    }
    return file.openRead();
  }

  @override
  Future<Uint8List?> readSliceHead(
    ExportQuestionRecord record, {
    int maxBytes = 64,
  }) async {
    try {
      final abs = _resolveSlicePath(record);
      if (abs == null) return null;
      final file = File(abs);
      if (!file.existsSync()) return null;
      final builder = BytesBuilder();
      await for (final chunk in file.openRead(0, maxBytes)) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } catch (_) {
      return null;
    }
  }

  /// 库内相对路径 → 绝对路径（越出数据目录 / 非法路径返回 null，
  /// 按“切片不可用”处理，不抛错）。
  String? _resolveSlicePath(ExportQuestionRecord record) {
    final path = record.slicePath;
    if (path == null) return null;
    return AppDatabase.resolveDataPath(path);
  }
}
