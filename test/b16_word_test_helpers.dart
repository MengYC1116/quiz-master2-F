// 十六批 C：Word 测试共用助手（解包 docx 查 XML / 服务构造）。
//
// 断言方式（D-204）：解包 docx 查 XML / 断言关键串 / 图片部件存在
// 与 md5，不只断言字节长度。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:quiz_master2/services/pdf_export/export_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/export_versions.dart';
import 'package:quiz_master2/services/word_export/word_export_service.dart';

import 'b15_m1b_fake_source.dart';

export 'b15_m1b_fake_source.dart';

/// 解包后的 docx（archive 解码；断言查 XML / 图片部件 / md5）。
class UnpackedDocx {
  UnpackedDocx(this.bytes) : archive = ZipDecoder().decodeBytes(bytes);

  final Uint8List bytes;
  final Archive archive;

  List<String> get partNames => [for (final f in archive.files) f.name];

  String partText(String name) {
    for (final f in archive.files) {
      if (f.name == name) return utf8.decode(f.content as List<int>);
    }
    return '';
  }

  String get documentXml => partText('word/document.xml');

  /// 全部部件的 XML 文本拼接（查 LaTeX 源码外泄等全文档断言用）。
  String get allXmlText =>
      partNames.where((n) => n.endsWith('.xml')).map(partText).join('\n');

  List<String> get mediaNames =>
      partNames.where((n) => n.startsWith('word/media/')).toList();

  Uint8List? mediaBytes(String name) {
    for (final f in archive.files) {
      if (f.name == name) return Uint8List.fromList(f.content as List<int>);
    }
    return null;
  }

  String mediaMd5(String name) {
    final b = mediaBytes(name);
    if (b == null) return '';
    return md5.convert(b).toString();
  }

  int countInDocument(String needle) =>
      needle.allMatches(documentXml).length;

  bool get hasFontsPart =>
      partNames.any((n) => n.startsWith('word/fonts/'));
}

/// 构造 Word 编排服务（测试用：内存源 + 可控 key 状态 + 临时目录根；
/// 栅格化器为 null，公式走纯裁剪降级链）。
WordExportService makeWordService(
  FakeExportQuestionSource source,
  Directory tempRoot, {
  bool hasKey = true,
  bool excludeLowDpi = false,
}) => WordExportService(
  source: source,
  hasApiKey: () async => hasKey,
  tempRoot: tempRoot,
  excludeLowDpi: excludeLowDpi,
);

/// 生成一次 Word 导出（默认只勾练习版；filter/sort 用固定文案，
/// 便于断言信息区 5 行）。
Future<WordExportResult> generateWord(
  WordExportService service,
  List<String> ids, {
  ExportVersionSelection versions =
      const ExportVersionSelection.practiceOnly(),
  List<ExcludedQuestion> excluded = const [],
  int? circledCount,
}) => service.generateVersions(
  ids: ids,
  excluded: excluded,
  filterText: '全部',
  sortText: '默认排序',
  versions: versions,
  circledCount: circledCount ?? ids.length,
);

/// 加一道普通选择题（切片为真实可解码 PNG）。
void addChoiceQuestion(
  FakeExportQuestionSource source,
  String id, {
  int w = 200,
  int h = 100,
  String stem = '求下列各题的值',
  String? answer,
  String? explanation,
  List<String> folderNames = const [],
  String? questionType = 'choice_single',
}) {
  final bytes = makePng(w, h);
  source.records[id] = choiceRecord(
    id: id,
    sliceWidth: w,
    sliceHeight: h,
    stem: stem,
    answer: answer,
    explanation: explanation,
    folderNames: folderNames,
    questionType: questionType,
  );
  source.slices[id] = bytes;
}

/// 含一个行内公式的 ocrRaw（md + layout_details 公式框与切片同尺寸，
/// 无 transform，裁剪可成功）。
String formulaRaw({
  required String md,
  required int sliceW,
  required int sliceH,
  List<int> bbox = const [10, 5, 60, 30],
}) => jsonEncode({
  'md_results': md,
  'layout_details': [
    [
      {
        'bbox_2d': bbox,
        'label': 'formula',
        'native_label': 'formula',
        'width': sliceW,
        'height': sliceH,
        'index': 0,
      },
    ],
  ],
});

/// md5（十六进制小写）。
String md5Of(Uint8List bytes) => md5.convert(bytes).toString();
