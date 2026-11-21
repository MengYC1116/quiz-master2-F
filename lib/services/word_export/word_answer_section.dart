// 十六批 C（D-197）：Word 答案版答案区（WORD-DESIGN.md §3.4）。
//
// 答案区在练习内容后另起一页（分页符，非分节符），按题号顺序列答案
// 与解析，只含已印出的题（BROKEN 占位题也有题号，照常列入；被跳过
// 的题两版都不印，答案区也不列）。判定常量与占位文案直接复用
// `answer_section.dart`（`isAnswerRecorded` / `recordedOrPlaceholder` /
// `kAnswerNotRecordedText` / `kExplanationNotRecordedText` /
// `kAnswerSectionTitle` / `buildAnswerEntries`），不得另写一套。
import 'package:docx_creator/docx_creator.dart';

import '../pdf_export/answer_section.dart';
import 'word_document_builder.dart';

/// 答案区标题下方的答案来源说明行（10 pt，WORD-DESIGN.md §3.4）。
///
/// 答案是用户自己录的，不是机器算的，必须明示，不得让用户误以为是
/// 标准答案。
const String kWordAnswerSourceNote =
    '答案与解析由用户在错题本中录入，非 OCR 识别结果。';

/// 把答案区追加到文档末尾（调用方已确认 [versions.answer] 为 true）。
///
/// [entries] 须已按题号排好序、只含已印出的题（由
/// [buildAnswerEntries] 产出）。条目为可跨页断开的纯文本段（与 PDF
/// 答案区同款：不用不可拆分容器包整条，防止超一页抛错）；长答案/
/// 长解析不断页硬锁，Word 自然分页，条目可跨页。
void addWordAnswerSection(
  DocxDocumentBuilder builder,
  List<AnswerEntry> entries,
) {
  // 答案区另起一页（分页符，不是分节符）。
  builder.pageBreak();
  builder.paragraph(
    wordTextParagraph(
      kAnswerSectionTitle,
      fontSize: WordTypography.answerTitlePt,
      bold: true,
      spacingBefore: 240,
      spacingAfter: 120,
    ),
  );
  builder.paragraph(
    wordTextParagraph(
      kWordAnswerSourceNote,
      fontSize: WordTypography.infoPt,
      spacingAfter: 240,
    ),
  );
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    builder.paragraph(
      wordTextParagraph(
        '第 ${entry.displayNumber} 题',
        fontSize: WordTypography.bodyPt,
        bold: true,
        spacingBefore: i == 0 ? null : 120,
        spacingAfter: 60,
      ),
    );
    builder.paragraph(
      wordTextParagraph(
        '答案：${entry.answerDisplay}',
        fontSize: WordTypography.bodyPt,
        spacingAfter: 60,
      ),
    );
    builder.paragraph(
      wordTextParagraph(
        '解析：${entry.explanationDisplay}',
        fontSize: WordTypography.bodyPt,
        spacingAfter: 120,
      ),
    );
    if (i < entries.length - 1) {
      builder.hr();
    }
  }
}

/// 答案区条目是否含缺失占位（测试用：答案/解析未录入时印占位文案，
/// 不留空、不编造）。
bool wordAnswerEntryHasPlaceholder(AnswerEntry entry) =>
    !entry.hasAnswer || !entry.hasExplanation;
