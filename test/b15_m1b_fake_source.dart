// 十五批 M1-B 测试共用桩：内存数据源 + PNG/OCR 测试数据构造。
//
// 注意：本文件不是测试文件（不以 _test.dart 结尾），只被 b15_m1b_*
// 测试 import。测试数据里的公式用最简形式，仅作解析计数用。
import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:quiz_master2/services/glm_ocr_client.dart'
    show OcrRequestTransform;
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/services/pdf_export/export_question_record.dart';
import 'package:quiz_master2/services/pdf_export/slice_snapshot.dart';

/// 生成一张宽 [w] 高 [h] 的真实可解码 PNG（纯色）。
Uint8List makePng(int w, int h) =>
    img.encodePng(img.Image(width: w, height: h));

/// 只含 IHDR 的最小 PNG 头（33 字节，不可解码，只够读尺寸）。
Uint8List makePngHeadOnly(int w, int h) {
  final bytes = Uint8List(33);
  bytes.setAll(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  bytes.setAll(12, const [0x49, 0x48, 0x44, 0x52]); // IHDR
  bytes[16] = (w >> 24) & 0xFF;
  bytes[17] = (w >> 16) & 0xFF;
  bytes[18] = (w >> 8) & 0xFF;
  bytes[19] = w & 0xFF;
  bytes[20] = (h >> 24) & 0xFF;
  bytes[21] = (h >> 16) & 0xFF;
  bytes[22] = (h >> 8) & 0xFF;
  bytes[23] = h & 0xFF;
  bytes[24] = 8; // 位深
  bytes[25] = 2; // 颜色类型 RGB
  return bytes;
}

/// 构造 ocr_raw JSON（只含 md_results）。
String mdRaw(String mdResults) =>
    jsonEncode({'md_results': mdResults});

/// 选择题全文 md：题干 + A–D 选项行（splitStem 能自动切分）。
String choiceMd(String stem, [List<String> options = const ['甲', '乙', '丙', '丁']]) {
  final buf = StringBuffer(stem);
  const labels = ['A', 'B', 'C', 'D', 'E', 'F'];
  for (var i = 0; i < options.length; i++) {
    buf.write('\n${labels[i]}. ${options[i]}');
  }
  return buf.toString();
}

/// 选项内容 JSON（标签映射）。
String optionsJson(Map<String, String> contents) => jsonEncode(contents);

/// 构造一道选择题的记录（默认全部字段齐全、可印）。
///
/// 注意：[ocrRaw] / [ocrStem] / [optionContentsJson] 用哨兵区分
/// “未传（用默认）”与“显式传 null”（NULL 情形测试需要真 null，
/// `??` 无法区分两者）。
const _unspecified = Object();

ExportQuestionRecord choiceRecord({
  required String id,
  String title = '测试题',
  String subjectId = 'math',
  String stem = '求下列各题的值',
  Map<String, String>? options,
  int? parserVersion = 2,
  Object? optionContentsJson = _unspecified,
  String? questionType = 'choice_single',
  Object? ocrRaw = _unspecified,
  Object? ocrStem = _unspecified,
  String ocrFigures = '[]',
  String? slicePath,
  int? sliceWidth,
  int? sliceHeight,
  int contentVersion = 0,
  bool ocrManualEdited = false,
  String? answer,
  String? explanation,
  List<String> folderNames = const [],
  String? examName,
}) {
  final resolvedOptions = options ?? {'A': '甲', 'B': '乙', 'C': '丙', 'D': '丁'};
  return ExportQuestionRecord(
    id: id,
    title: title,
    subjectId: subjectId,
    slicePath: slicePath ?? 'slices/$id.png',
    sliceWidth: sliceWidth,
    sliceHeight: sliceHeight,
    ocrRaw: ocrRaw == _unspecified
        ? mdRaw(choiceMd(stem, resolvedOptions.values.toList()))
        : ocrRaw as String?,
    ocrStem: ocrStem == _unspecified ? stem : ocrStem as String?,
    optionContentsJson: optionContentsJson == _unspecified
        ? optionsJson(resolvedOptions)
        : optionContentsJson as String?,
    optionContentsParserVersion: parserVersion,
    questionType: questionType,
    ocrFigures: ocrFigures,
    contentVersion: contentVersion,
    ocrManualEdited: ocrManualEdited,
    answer: answer,
    explanation: explanation,
    folderNames: folderNames,
    examName: examName,
  );
}

/// 构造一个图块的 ocr_figures JSON（单图）。
///
/// [sliceBytes] 为当前切片字节（inputHash 由它算出）；
/// [srcRect] 为像素坐标裁剪区；锚点用 fallback（放序列末尾的未关联区），
/// 不依赖 md 引用。
String singleFigureJson({
  required String questionId,
  required String slicePath,
  required Uint8List sliceBytes,
  required SrcRect srcRect,
  List<int> bbox2d = const [50, 100, 300, 500],
  int spaceWidth = 200,
  int spaceHeight = 100,
  String anchorSource = 'fallback',
  String anchorRef = '',
}) {
  final figure = OcrFigure(
    id: 'figure-$questionId-0',
    slicePath: slicePath,
    inputHash: hashBytes(sliceBytes),
    sequenceIndex: 0,
    anchorSource: anchorSource,
    anchorRef: anchorRef,
    bbox2d: bbox2d,
    spaceWidth: spaceWidth,
    spaceHeight: spaceHeight,
    transform: OcrRequestTransform(
      srcW: spaceWidth,
      srcH: spaceHeight,
      reqW: spaceWidth,
      reqH: spaceHeight,
      padX: 0,
      padY: 0,
    ),
    srcRect: srcRect,
    cropPath: 'slices/$questionId-fig-v1-0.png',
  );
  return jsonEncode([figure.toJson()]);
}

/// 内存数据源桩（M1-B 逻辑与测试只依赖 ExportQuestionSource 契约）。
class FakeExportQuestionSource implements ExportQuestionSource {
  /// 题目行（按 ID）。
  final Map<String, ExportQuestionRecord> records = {};

  /// 切片字节（按题目 ID）。
  final Map<String, Uint8List> slices = {};

  /// 切片不可用的题目 ID（openSliceBytes 抛 SliceUnavailableException）。
  final Set<String> unavailableSlices = {};

  /// openSliceBytes 被调次数（按调用顺序计）。
  int openCalls = 0;

  /// 每次 openSliceBytes 时调用的钩子（第几次调用、哪道题），供
  /// 一致性测试在“两题之间”改切片、模拟重框/备份恢复/文件替换。
  void Function(int callIndex, ExportQuestionRecord record)? onOpenSlice;

  /// fetchQuestion 的覆盖钩子（M3-F：终态复核测试用——返回与
  /// [records] 不同的记录，模拟快照建成过程中文件夹/考试被改）。
  /// 不设时按 [records] 返回。
  ExportQuestionRecord? Function(String id)? fetchOverride;

  @override
  Future<ExportQuestionRecord?> fetchQuestion(String id) async =>
      fetchOverride?.call(id) ?? records[id];

  // 注意：implements 不继承接口的默认实现，此处显式逐题调
  // fetchQuestion（与接口默认实现同款；生产实现批量读）。
  @override
  Future<List<ExportQuestionRecord?>> fetchQuestions(
    List<String> ids,
  ) async {
    final out = <ExportQuestionRecord?>[];
    for (final id in ids) {
      out.add(await fetchQuestion(id));
    }
    return out;
  }

  @override
  Stream<List<int>> openSliceBytes(ExportQuestionRecord record) {
    openCalls++;
    onOpenSlice?.call(openCalls, record);
    if (unavailableSlices.contains(record.id)) {
      throw SliceUnavailableException('测试桩：切片不可用（${record.id}）');
    }
    final bytes = slices[record.id];
    if (bytes == null) {
      throw SliceUnavailableException('测试桩：无切片（${record.id}）');
    }
    return Stream.value(bytes);
  }

  @override
  Future<Uint8List?> readSliceHead(
    ExportQuestionRecord record, {
    int maxBytes = 64,
  }) async {
    final bytes = slices[record.id];
    if (bytes == null) return null;
    if (unavailableSlices.contains(record.id)) return null;
    return Uint8List.fromList(bytes.take(maxBytes).toList());
  }
}
