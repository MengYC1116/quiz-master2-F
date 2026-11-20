// B4：database.dart 拆分——Win11 反馈包 5：ocr_raw 回填选项内容。
// 与 database.dart 同一库（part of），共享库私有成员；纯新增，无旧行为改动。

part of 'database.dart';

/// Win11 反馈包 5：老数据回填（本地算，不调 OCR 接口、不花钱）。
/// 读每道 option_contents 为 NULL 且有 ocr_raw 的题，用统一解析器
/// （[parseOptionContents]，与新 OCR 写回同一份规则）从 ocr_raw 的
/// 全文 md 里重解析出选项内容，写回 option_contents + 解析器版本。
/// 返回回填的题数。
///
/// 守门（缺一不可，少填不错填）：
/// - 判断题（question_type == 'true_false'）不回填：判断题固定
///   “正确/错误”，不走选项解析；
/// - 切分不是 autoSplit 不回填：选项文字已在题干文本里，回填进选项区
///   会造成同一选项出现两遍；
/// - option_contents 已有值（OCR 写回的、人工改过的）一律不动：
///   WHERE 子句再加 `option_contents IS NULL` 守门，回填幂等，
///   第二次跑返回 0；
/// - ocr_raw 原文原样保留，不改；content_version 不抬（回填是迁移时
///   补齐，不是用户可见内容的新变化；OCR 任务的 claimedVersion
///   校验不受影响）。
/// 开库时由 onBeforeOpen 调（db_schema.dart），新库无行可扫是空操作。
Future<int> backfillOptionContentsIntoImpl(QuizDatabase db) async {
  final rows = await db.customSelect(
    'SELECT id, question_type, ocr_raw FROM questions '
    'WHERE option_contents IS NULL AND ocr_raw IS NOT NULL',
  ).get();
  var filled = 0;
  for (final row in rows) {
    final data = row.data;
    final id = data['id'] as String;
    // 判断题固定“正确/错误”，不走选项解析。
    if (data['question_type'] == 'true_false') continue;
    final raw = GlmOcrRawData.tryParse(data['ocr_raw'] as String?);
    if (raw == null) continue;
    final split = splitStem(raw.mdResults);
    if (split.status != StemSplitStatus.autoSplit) continue;
    final parsed = parseOptionContents(raw.mdResults, split);
    final updated = await db.customUpdate(
      'UPDATE questions SET option_contents = ?, '
      'option_contents_parser_version = ? '
      'WHERE id = ? AND option_contents IS NULL',
      variables: [
        Variable<String>(encodeOptionContents(parsed.contents)!),
        Variable<int>(parsed.parserVersion),
        Variable<String>(id),
      ],
      updates: {db.questions},
    );
    if (updated == 1) filled++;
  }
  return filled;
}
