// 十五批 M2-3：导出文件名默认规则与校验（PLAN-15-REV3 §2）。
//
// 默认 `错题本_<学科>_<文件夹>_<yyyyMMdd>.pdf`（Word 时扩展名为
// `.docx`，干规则与 PDF 完全相同，见十六批 C D-195）：
// - 无文件夹时省掉该段；
// - 多文件夹时用“多文件夹”或省略文件夹段，多学科时用“多学科”
//   （不得取第一道题的学科/文件夹代表整个导出范围——调用方传入
//   已按此规则算好的展示名，本文件不从题目里取）；
// - 答案版后缀 `_答案`（加在日期后、扩展名之前）；
// - Windows 文件名禁用字符按 `QuestionExportService.safeFileName`
//   同款规则换成下划线（直接复用该方法，不另写一套）；
// - 筛选信息过长时截断并保留日期（文件名干过长会在 Windows 上
//   写盘失败；干截断以 rune 计，保留日期与答案后缀）；
// - 默认不加路线标记 `_OCR`/`_增强`，路线只在面板与报告中明示，
//   不污染文件名。
import '../question_export_service.dart';
import 'export_versions.dart';

/// 文件名干（不含扩展名）的 rune 上限（Windows 单文件名上限 255，
/// 留足路径余量；超限时先缩文件夹段、再缩学科段，日期与后缀保留）。
const int kMaxExportFileNameStemLength = 100;

/// 学科名缺失时的回退展示名（不得取第一道题的学科作代表）。
const String kExportMultiSubjectName = '多学科';

/// 多文件夹时的展示名（或由调用方传 null 省略文件夹段）。
const String kExportMultiFolderName = '多文件夹';

/// 文件名清理：与 `QuestionExportService.safeFileName` 同款规则
/// （Windows 禁用字符 `\/:*?"<>|` 换 `_`，空白修整；空串回退）。
///
/// 另去尾部圆点/空格（Windows 不接受以圆点或空格结尾的文件名）。
String sanitizeExportFileName(String raw) {
  if (raw.trim().isEmpty) return '错题本导出';
  var cleaned = QuestionExportService.safeFileName(raw);
  cleaned = cleaned.replaceAll(RegExp(r'[. ]+$'), '');
  if (cleaned.isEmpty || cleaned == 'question') return '错题本导出';
  return cleaned;
}

/// 校验用户改后的文件名（M3 面板用；返回 null 表示通过）。
///
/// 校验的是完整文件名（含扩展名）。[format] 为 null 时按 PDF 校验
///（默认行为不变，现有测试与调用方不受影响）；Word 格式时要求
/// 以 `.docx` 结尾。与 [sanitizeExportFileName] 的关系：校验不过时
/// 面板应提示原因，由用户改或点“自动修正”（修正即走 sanitize）；
/// 生成流程内部一律用 sanitize 后的名字，不直接用未经校验的用户
/// 输入写盘。
String? validateExportFileName(String fileName, {ExportFormat? format}) {
  if (fileName.trim().isEmpty) return '文件名不能为空';
  final extension = (format ?? ExportFormat.pdf).extension;
  if (!fileName.toLowerCase().endsWith(extension)) {
    return '文件名须以 $extension 结尾';
  }
  final stem = fileName.substring(
    0,
    fileName.length - extension.length,
  );
  if (stem.trim().isEmpty) return '文件名不能为空';
  if (RegExp(r'[\\/:*?"<>|]').hasMatch(fileName)) {
    return '文件名不能包含 \\ / : * ? " < > |';
  }
  if (stem.endsWith('.') || stem.endsWith(' ')) {
    return '文件名不能以圆点或空格结尾';
  }
  if (stem == '.' || stem == '..') return '文件名无效';
  if (stem.runes.length > kMaxExportFileNameStemLength) {
    return '文件名过长（已超过 $kMaxExportFileNameStemLength 字）';
  }
  return null;
}

/// 生成默认导出文件名（含扩展名；默认 `.pdf`）。
///
/// [subjectName] 为展示用学科名（多学科时传“多学科”，不得取第一道题
/// 的学科作代表）；[folderName] 为展示用文件夹名（null/空白 = 省掉
/// 该段；多文件夹时传“多文件夹”或 null）；[date] 为导出日期；
/// [version] 决定是否加 `_答案` 后缀；[format] 决定扩展名
///（默认 PDF；Word 时为 `.docx`，干规则与 PDF 完全相同，D-195）。
String buildExportFileName({
  required String subjectName,
  String? folderName,
  required DateTime date,
  required ExportVersion version,
  ExportFormat format = ExportFormat.pdf,
}) {
  final dateText = _dateText(date);
  var subject = subjectName.trim().isEmpty
      ? kExportMultiSubjectName
      : sanitizeExportFileName(subjectName);
  String? folder;
  if (folderName != null && folderName.trim().isNotEmpty) {
    folder = sanitizeExportFileName(folderName);
  }
  final suffix = version.fileSuffix;
  final stem = _truncateStem(
    subject: subject,
    folder: folder,
    dateText: dateText,
  );
  return '$stem$suffix${format.extension}';
}

/// 过长干截断：保留日期与后缀，先缩文件夹段、再缩学科段。
/// （分段直接传入，不按 `_` 反切——学科/文件夹名本身可含下划线。）
String _truncateStem({
  required String subject,
  required String? folder,
  required String dateText,
}) {
  const prefix = '错题本_';
  String stemOf(String subjectValue, String? folderValue) =>
      folderValue == null || folderValue.isEmpty
      ? '$prefix${subjectValue}_$dateText'
      : '$prefix${subjectValue}_${folderValue}_$dateText';
  var subjectValue = subject;
  var folderValue = folder;
  while (folderValue != null &&
      folderValue.isNotEmpty &&
      stemOf(subjectValue, folderValue).runes.length >
          kMaxExportFileNameStemLength) {
    folderValue = String.fromCharCodes(
      folderValue.runes.take(folderValue.runes.length - 1),
    );
  }
  if (folderValue != null && folderValue.isEmpty) folderValue = null;
  while (subjectValue.runes.length > 2 &&
      stemOf(subjectValue, folderValue).runes.length >
          kMaxExportFileNameStemLength) {
    subjectValue = String.fromCharCodes(
      subjectValue.runes.take(subjectValue.runes.length - 1),
    );
  }
  return stemOf(subjectValue, folderValue);
}

String _dateText(DateTime date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '$y$m$d';
}
