// 十五批 M1-B：导出快照的数据源契约（M1-DESIGN.md §5/§6）。
//
// 本文件是路由 / 盘点 / 快照（两路线）/ 完整性之间的共享数据契约：
// 题目行的一份冻结副本（[ExportQuestionRecord]）+ 读题与读切片的
// 抽象（[ExportQuestionSource]）。生产实现由 M1-E 提供（读 Drift
// 行 + 数据目录文件）；M1-B 的逻辑与测试只依赖本契约，不直接碰
// lib/data/（设计 §14：不动 lib/data/）。
//
// 关键点：
// - [optionContentsJson] 保留 `option_contents` 列的原始字符串。
//   `Question` 模型在读库时已用 decodeOptionContents 解码过，损坏
//   的 JSON 会变成 null——与“NULL = 未解析”无法区分。§5 (c) 要求
//   区分“NULL”与“非 NULL 但 JSON 损坏”，因此 M1-E 的数据源实现
//   必须从 Drift 行（DbQuestion.optionContents，原始 String?）
//   取值，不得只传模型里解码后的 Map。
// - 快照冻结的是值本身（题干、选项、顺序），不是 questionId 再查库
//   （§9 REV2）：快照后用户再纠错，当前导出保持快照值。
import 'dart:typed_data';

import '../../models/models.dart' as models;
import '../option_contents.dart';

/// 逐题来源行单行硬约束（D-183）：来源行在 10 pt 下按内容区宽
/// 510.2 pt 排版，全角字约 10 pt/字；超长时截断加省略号，定长单行。
/// 不截断时，长文件夹/考试名换行会把题段推高、推入分页危险带
/// （P0-1 偏差源 (c)）；按 2 行做预算仍兜不住更长的名，故硬截断。
const int kExportSourceLineMaxChars = 45;

/// 逐题来源行格式化（十五批 M3-F；PLAN §1.1：学科 / 文件夹 / 考试名）。
///
/// - 学科恒有（题目导入时学科固定）；文件夹多个时用“、”连接全部
///   文件夹名（逐题印全部是事实，不用“多文件夹”代替）；
/// - 无文件夹时省掉该段；无考试时省掉该段；空白段一律省掉；
/// - 段间用“ / ”连接。整单信息区（页眉/文件名/信息区）仍用
///   “多文件夹”/“多学科”，不得取第一道题的学科/文件夹代表整个
///   导出范围（M1-DESIGN.md §7）——本函数只拼逐题行，不管整单。
/// - D-183：拼完超 [kExportSourceLineMaxChars] 字时截断加省略号，
///   单行硬约束（分页器与构建器均按单行 14.52 pt 计）。
String formatExportSourceText({
  required String subjectName,
  required List<String> folderNames,
  String? examName,
}) {
  final segments = <String>[];
  final subject = subjectName.trim();
  if (subject.isNotEmpty) segments.add(subject);
  final folders = folderNames
      .map((f) => f.trim())
      .where((f) => f.isNotEmpty)
      .join('、');
  if (folders.isNotEmpty) segments.add(folders);
  final exam = examName?.trim() ?? '';
  if (exam.isNotEmpty) segments.add(exam);
  final joined = segments.join(' / ');
  if (joined.length <= kExportSourceLineMaxChars) return joined;
  return '${joined.substring(0, kExportSourceLineMaxChars)}…';
}

/// 导出用题目行冻结副本（一次 Drift 读出的值，快照期间不再重读）。
class ExportQuestionRecord {
  const ExportQuestionRecord({
    required this.id,
    required this.title,
    required this.subjectId,
    this.slicePath,
    this.sliceWidth,
    this.sliceHeight,
    this.ocrRaw,
    this.ocrStem,
    this.optionContentsJson,
    this.optionContentsParserVersion,
    this.questionType,
    this.ocrFigures = '[]',
    this.answer,
    this.explanation,
    this.ocrManualEdited = false,
    this.contentVersion = 0,
    this.answerPendingRecheck = false,
    this.folderNames = const [],
    this.examName,
  });

  /// 从应用模型建记录（M1-E 适配器的便捷入口）。
  ///
  /// [optionContentsJson] 须传列原始字符串（见文件头注释）；不传时
  /// 由模型里已解码的 Map 重新编码——损坏的 JSON 在此路径下无法
  /// 还原（模型层已将其解码为 null），M1-E 必须传原始值。
  /// [folderNames]/[examName] 须传已解析好的展示名（模型只含
  /// folderIds/examId，不含名）；不传时按无文件夹/无考试计。
  factory ExportQuestionRecord.fromQuestion(
    models.Question q, {
    String? optionContentsJson,
    List<String> folderNames = const [],
    String? examName,
  }) =>
      ExportQuestionRecord(
        id: q.id,
        title: q.title,
        subjectId: q.subjectId,
        slicePath: q.slicePath,
        sliceWidth: q.sliceWidth,
        sliceHeight: q.sliceHeight,
        ocrRaw: q.ocrRaw,
        ocrStem: q.ocrStem,
        optionContentsJson:
            optionContentsJson ?? encodeOptionContents(q.optionContents),
        optionContentsParserVersion: q.optionContentsParserVersion,
        questionType: q.questionType,
        ocrFigures: q.ocrFigures,
        answer: q.answer,
        explanation: q.explanation,
        ocrManualEdited: q.ocrManualEdited,
        contentVersion: q.contentVersion,
        answerPendingRecheck: q.answerPendingRecheck,
        folderNames: folderNames,
        examName: examName,
      );

  /// 题目 ID。
  final String id;

  /// 题目标题。
  final String title;

  /// 学科 ID。
  final String subjectId;

  /// 整题切片相对路径（数据目录内；null = 无切片）。
  final String? slicePath;

  /// 切片像素尺寸（建库时记录；盘点以 IHDR 实测为准，本字段只作回退）。
  final int? sliceWidth;
  final int? sliceHeight;

  /// GLM 原始结果 JSON（内部存，绝不外露；含 md_results）。
  final String? ocrRaw;

  /// 切分后题干（库内已存值，C 路线正文权威来源之一）。
  final String? ocrStem;

  /// `option_contents` 列原始字符串（标签映射 JSON；NULL = 未解析）。
  final String? optionContentsJson;

  /// 产出选项内容的解析器版本（NULL = 未经解析器解析，如人工填写）。
  final int? optionContentsParserVersion;

  /// 主题型（NULL = 待确认）。
  final String? questionType;

  /// 图块 JSON（默认 `'[]'`）。
  final String ocrFigures;

  /// 答案 / 解析（答案版用；正文状态不受其缺失影响，§12）。
  final String? answer;
  final String? explanation;

  /// 人工编辑标记（附录 B：stem_correction 无独立 corrected 旗，
  /// 可追溯性的 corrected 取此值）。
  final bool ocrManualEdited;

  /// 内容版本（快照一致性复核用，D-178）。
  final int contentVersion;

  /// 答案待重新核对标记（此期间旧答案/解析无效，M2 答案版用）。
  final bool answerPendingRecheck;

  /// 归属文件夹展示名（M3-F；按 questions.folder_ids 顺序解析，
  /// 已删除的文件夹跳过；空 = 本题未进任何文件夹，来源行省掉该段）。
  ///
  /// 快照冻结值：快照后改文件夹不影响本次导出（与其它冻结字段
  /// 同一口径，快照终态复核比对本字段）。
  final List<String> folderNames;

  /// 考试展示名（M3-F；按 questions.exam_id 解析；null = 无考试，
  /// 来源行省掉该段；考试被删时按无考试计）。
  ///
  /// 快照冻结值（同 [folderNames]）。
  final String? examName;

  /// 解码后的选项内容（损坏的 JSON → null，与 NULL 无法区分；
  /// 需区分时读 [optionContentsJson] 原始值）。
  Map<String, String>? get optionContents =>
      decodeOptionContents(optionContentsJson);
}

/// 源切片不可用：缺失 / 不可读 / 打开失败（题目级处理，见 D-179）。
class SliceUnavailableException implements Exception {
  SliceUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'SliceUnavailableException: $message';
}

/// 导出快照的数据源（M1-E 实现；测试用桩实现）。
///
/// 实现须保证：同一快照构建期间，对同一题的多次 [fetchQuestion]
/// 返回同一逻辑时刻的行（生产实现在一次 Drift transaction 内读齐，
/// §6）；切片读取走数据目录文件，不读演示库本体以外的任何副本。
abstract class ExportQuestionSource {
  /// 读一道题的行（不存在返回 null）。
  Future<ExportQuestionRecord?> fetchQuestion(String id);

  /// 批量读多道题的行（M3-F；一次批量查询口径）。
  ///
  /// 返回与 [ids] 等长、顺序一致的列表，不存在的题对应位置为 null。
  /// 默认实现逐题调 [fetchQuestion]；生产实现（Drift）一次读齐
  /// 题目行 + 文件夹名 + 考试名（各一张表一次查询，不逐题 N+1）。
  Future<List<ExportQuestionRecord?>> fetchQuestions(
    List<String> ids,
  ) async {
    final out = <ExportQuestionRecord?>[];
    for (final id in ids) {
      out.add(await fetchQuestion(id));
    }
    return out;
  }

  /// 打开源切片字节流（流式读，供快照复制/裁剪用）。
  ///
  /// 切片缺失/不可读 → 抛 [SliceUnavailableException]（题目级处理）。
  /// 调用方须在 [SliceWriteGuard] 锁内调用（与写入入口串行化）。
  Stream<List<int>> openSliceBytes(ExportQuestionRecord record);

  /// 读切片文件头（前 [maxBytes] 字节，供盘点读 PNG IHDR 用）。
  ///
  /// 切片缺失/不可读 → 返回 null（不抛；盘点按“切片不可用”记）。
  Future<Uint8List?> readSliceHead(
    ExportQuestionRecord record, {
    int maxBytes = 64,
  });
}
