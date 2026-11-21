// 十五批 M2-1：答案版答案区（PLAN-15-REV3 §5 M2-1）。
//
// 答案区只印文字：答案与解析为文本字段；若文本含 `$...$`，默认纯文本，
// 不得静默解析（当前模型无公式字段，不得临时用 OCR 生成答案）。
// 答案与解析分别判断：空字符串 / 纯空白统一视为未录入；缺失时印
// 「本题未录入答案」/「本题未录入解析」，不留空、不编造。
// `answerPendingRecheck` 置位期间旧答案/解析无效（入库时两者已同时
// 置 NULL，见 db_questions.dart），此处再防御一层：置位即视为未录入。
//
// 答案区条目与练习版题号一一对应：只含已印出的题（BROKEN 占位题也
// 有题号，照常列入）；被跳过的题两版都不印，答案区也不列。
// 条目按题号顺序；每条为可跨页断开的纯文本（不用 Inseparable 包整条，
// 长答案/长解析不断页会超一页抛错，见 M1-G 安全发现）。
// LaTeX 源码绝不外露：本文件只见答案/解析文本本身（它们就是要印的
// 内容），不处理、不记录公式源码。
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'export_question_record.dart';
import 'pdf_document_builder.dart';

/// 答案未录入时的占位文案（PLAN §1.1）。
const String kAnswerNotRecordedText = '本题未录入答案';

/// 解析未录入时的占位文案（PLAN §1.1）。
const String kExplanationNotRecordedText = '本题未录入解析';

/// 答案区标题。
const String kAnswerSectionTitle = '答案与解析';

/// 一条答案/解析是否已录入（分别判断；空字符串/纯空白视为未录入；
/// `answerPendingRecheck` 置位期间旧值无效）。
bool isAnswerRecorded(String? value, {bool pendingRecheck = false}) {
  if (pendingRecheck) return false;
  return value != null && value.trim().isNotEmpty;
}

/// 已录入返回原文，未录入返回占位文案（不留空、不编造）。
String recordedOrPlaceholder(
  String? value, {
  required String placeholder,
  bool pendingRecheck = false,
}) {
  if (isAnswerRecorded(value, pendingRecheck: pendingRecheck)) {
    return value!;
  }
  return placeholder;
}

/// 答案区的一条输入（跨 Isolate 传递的纯数据：只含 String? / bool）。
class AnswerSourceData {
  const AnswerSourceData({
    required this.questionId,
    this.answer,
    this.explanation,
    this.answerPendingRecheck = false,
  });

  /// 题目 ID。
  final String questionId;

  /// 答案（冻结的快照值；null/空白 = 未录入）。
  final String? answer;

  /// 解析（冻结的快照值；null/空白 = 未录入）。
  final String? explanation;

  /// 答案待重新核对标记（置位期间旧答案/解析无效）。
  final bool answerPendingRecheck;
}

/// 答案区的一条（已按题号排好序，只含已印出的题）。
class AnswerEntry {
  const AnswerEntry({
    required this.displayNumber,
    required this.questionId,
    this.answer,
    this.explanation,
    this.answerPendingRecheck = false,
  });

  /// 导出内题号（与练习版同一题的题号一致）。
  final int displayNumber;

  /// 题目 ID。
  final String questionId;

  /// 答案原文（未录入为 null/空白）。
  final String? answer;

  /// 解析原文（未录入为 null/空白）。
  final String? explanation;

  /// 答案待重新核对标记。
  final bool answerPendingRecheck;

  /// 答案是否已录入。
  bool get hasAnswer =>
      isAnswerRecorded(answer, pendingRecheck: answerPendingRecheck);

  /// 解析是否已录入。
  bool get hasExplanation => isAnswerRecorded(
        explanation,
        pendingRecheck: answerPendingRecheck,
      );

  /// 印出的答案行文字（未录入印占位）。
  String get answerDisplay => recordedOrPlaceholder(
        answer,
        placeholder: kAnswerNotRecordedText,
        pendingRecheck: answerPendingRecheck,
      );

  /// 印出的解析行文字（未录入印占位）。
  String get explanationDisplay => recordedOrPlaceholder(
        explanation,
        placeholder: kExplanationNotRecordedText,
        pendingRecheck: answerPendingRecheck,
      );
}

/// 从冻结记录建答案区条目（不重新查询题目：输入全是快照冻结值）。
///
/// [displayNumbersById] 为已印出题的题号表（题目 ID → 导出内题号，
/// 取自本次生成的题目结果）；不在表里的题（跳过题）不列入。
/// 返回按题号升序的条目。
List<AnswerEntry> buildAnswerEntries({
  required Map<String, int> displayNumbersById,
  required List<AnswerSourceData> sources,
}) {
  final entries = <AnswerEntry>[];
  for (final source in sources) {
    final number = displayNumbersById[source.questionId];
    if (number == null) continue;
    entries.add(
      AnswerEntry(
        displayNumber: number,
        questionId: source.questionId,
        answer: source.answer,
        explanation: source.explanation,
        answerPendingRecheck: source.answerPendingRecheck,
      ),
    );
  }
  entries.sort((a, b) => a.displayNumber.compareTo(b.displayNumber));
  return entries;
}

/// 从快照行记录建答案区输入（[ExportQuestionRecord] → 纯数据）。
List<AnswerSourceData> answerSourcesFromRecords(
  Iterable<ExportQuestionRecord> records,
) => [
  for (final record in records)
    AnswerSourceData(
      questionId: record.id,
      answer: record.answer,
      explanation: record.explanation,
      answerPendingRecheck: record.answerPendingRecheck,
    ),
];

/// 答案区 widgets（标题 + 每题一条；全部为可跨页断开的纯文本）。
///
/// 调用方把返回的 widgets 放进独立的 MultiPage（答案区自新页起，
/// 页眉页脚与题目区同一套，页码全局连续，见 M2 探针结论）；
/// 标题与每题的题号行用短文本，答案/解析行走 spanText
/// （TextOverflow.span，长文本可跨页断行，C-6 同规则）。
List<pw.Widget> answerSectionWidgets(
  List<AnswerEntry> entries,
  PdfExportDocumentBuilder documentBuilder,
) {
  final widgets = <pw.Widget>[
    pw.Text(kAnswerSectionTitle, style: documentBuilder.questionNumberStyle),
  ];
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    widgets.add(
      pw.Text(
        '第 ${entry.displayNumber} 题',
        style: documentBuilder.questionNumberStyle,
      ),
    );
    widgets.add(
      documentBuilder.spanText('答案：${entry.answerDisplay}'),
    );
    widgets.add(
      documentBuilder.spanText('解析：${entry.explanationDisplay}'),
    );
    if (i < entries.length - 1) {
      widgets.add(_separatorWidget());
    }
  }
  return widgets;
}

/// 条间分隔线（8.5 pt = 上 4 pt + 0.5 pt 细灰线 + 下 4 pt，
/// 与题目区分隔线同值，见 CContentBuilder）。
pw.Widget _separatorWidget() => pw.Column(
  children: [
    pw.SizedBox(height: 4),
    pw.Container(
      height: 0.5,
      width: PdfExportGeometry.contentWidthPt,
      color: PdfColors.grey300,
    ),
    pw.SizedBox(height: 4),
  ],
);
