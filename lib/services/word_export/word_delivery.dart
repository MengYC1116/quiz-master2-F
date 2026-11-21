// 十六批 C（D-195/D-203）：Word 交付
// WordDeliveryService（WORD-DESIGN.md §5.3）。
//
// 薄委托：对话框/下载目录/原子写入/冲突顺延全部复用
// `PdfDeliveryService`（设计 §5.3 抽取条款：不复制落盘逻辑，
// 只在 `PdfDeliveryService.deliver` 族上加可选参数，默认值保持
// PDF 行为不变）。Word 与 PDF 的差别只有三点：
//  - 校验器：`defaultDocxFileValidator`（PK 魔数 + 必需部件 +
//    `word/media/*` 图片数 == 生成时记的 imageCount），
//    不校验页数（页数生成时未知，W-11）；
//  - 对话框标题：'保存 Word 文档'；
//  - 完成结果不带 pageCount（`FileDeliveryResult.pageCount` 为 null）。
//
// [defaultDocxFileValidator] 是纯 Dart zip 中央目录解析（不引
// `archive`——archive 只是 dev_dependency，生产库不得 import；
// 也不引 `package:xml`——设计只要求 PK + 部件 + 图片数三项，
// 不要求 XML 良构性校验）。docx 由 docx_creator 生成，无 zip64、
// 无数据描述符歧义，中央目录解析足够；解析失败一律返回 false
// （不抛错、不留半截文件）。
import 'dart:io';
import 'dart:typed_data';

import 'package:share_plus/share_plus.dart' hide ShareResult;

import '../pdf_export/export_versions.dart';
import '../pdf_export/pdf_delivery.dart';

/// 默认 docx 临时文件验证器：存在、大小 > 0、PK 魔数、含
/// `[Content_Types].xml` 与 `word/document.xml`、图片部件数与预期一致。
///
/// 签名与 [PdfFileValidator] 相同（第二个参数在 PDF 侧是预期页数；
/// Word 侧不用页数——调用方以闭包捕获预期图片数后传此函数，
/// 第二个参数传 0 即可，见 [WordDeliveryService.deliver]）。
Future<bool> defaultDocxFileValidator(
  File file,
  int expectedImageCount,
) async {
  try {
    if (!file.existsSync()) return false;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return false;
    final names = _readZipEntryNames(bytes);
    if (names == null) return false;
    if (!names.contains('[Content_Types].xml')) return false;
    if (!names.contains('word/document.xml')) return false;
    final mediaCount =
        names.where((n) => n.startsWith('word/media/')).length;
    return mediaCount == expectedImageCount;
  } catch (_) {
    return false;
  }
}

/// 读 zip 中央目录，返回全部条目名；解析失败返回 null。
///
/// 只读中央目录（EOCD 定位 + 逐条目走访），不解压任何部件。
/// EOCD 找不到、条目数对不上、任一条目越界 → null。
List<String>? _readZipEntryNames(Uint8List bytes) {
  if (bytes.length < 22) return null;
  // PK 魔数（局部文件头签名）。
  if (bytes[0] != 0x50 || bytes[1] != 0x4B || bytes[2] != 0x03 ||
      bytes[3] != 0x04) {
    return null;
  }
  final data = ByteData.sublistView(bytes);
  // 找 EOCD（PK\x05\x06）：从文件尾向前扫（注释最长 64 KiB）。
  var eocd = -1;
  final scanStart = bytes.length - 22;
  final scanEnd = bytes.length - 65557 > 0 ? bytes.length - 65557 : 0;
  for (var i = scanStart; i >= scanEnd; i--) {
    if (bytes[i] == 0x50 &&
        bytes[i + 1] == 0x4B &&
        bytes[i + 2] == 0x05 &&
        bytes[i + 3] == 0x06) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) return null;
  final totalEntries = data.getUint16(eocd + 10, Endian.little);
  final cdOffset = data.getUint32(eocd + 16, Endian.little);
  if (cdOffset >= bytes.length) return null;
  final names = <String>[];
  var offset = cdOffset;
  for (var i = 0; i < totalEntries; i++) {
    if (offset + 46 > bytes.length) return null;
    if (data.getUint32(offset, Endian.little) != 0x02014b50) {
      return null;
    }
    final nameLen = data.getUint16(offset + 28, Endian.little);
    final extraLen = data.getUint16(offset + 30, Endian.little);
    final commentLen = data.getUint16(offset + 32, Endian.little);
    final nameStart = offset + 46;
    final nameEnd = nameStart + nameLen;
    if (nameEnd > bytes.length) return null;
    names.add(
      String.fromCharCodes(bytes.sublist(nameStart, nameEnd)),
    );
    offset = nameEnd + extraLen + commentLen;
  }
  return names;
}

/// Word 平台交付服务：输入 docx 字节 + 文件名 + 预期图片数，
/// 输出一份文件的交付结果，供 M3 完成界面展示。
///
/// 对话框/下载目录/原子写入/冲突顺延全部委托给 [PdfDeliveryService]
///（只换校验器、对话框标题、不带页数）；外部边界全部可注入
///（测试用假实现，不弹系统对话框、不碰真实下载目录）。
class WordDeliveryService {
  WordDeliveryService({
    SaveFilePicker? pickSavePath,
    Future<Directory?> Function()? downloadsDirectory,
    Future<ShareResultStatus> Function(String path, String subject)?
    shareFile,
    Future<bool> Function(String path)? openFile,
    Future<bool> Function(String path)? openFolder,
    PdfDeliveryPlatform? platformOverride,
  }) : _inner = PdfDeliveryService(
         pickSavePath: pickSavePath,
         downloadsDirectory: downloadsDirectory,
         shareFile: shareFile,
         openFile: openFile,
         openFolder: openFolder,
         platformOverride: platformOverride,
       );

  final PdfDeliveryService _inner;

  /// 按平台分发交付（一份 .docx 文件）：Windows 走另存为对话框，
  /// Android 走公共下载目录，其它平台返回失败（不静默改写别处）。
  ///
  /// [expectedImageCount] 为生成时记的 `word/media/*` 部件数
  /// （交付校验用；与生成时的 imageCount 不一致 → 验证失败，
  /// 不留半截文件）。结果不带 pageCount（页数只有 Word 打开后
  /// 才知道，W-11；完成界面写“以 Word 打开为准”）。
  Future<FileDeliveryResult> deliver({
    required Uint8List docxBytes,
    required String fileName,
    required int expectedImageCount,
  }) {
    return _inner.deliver(
      pdfBytes: docxBytes,
      fileName: fileName,
      version: ExportVersion.practice,
      // expectedPages 仅作占位：Word 用自定义校验器（校验器忽略该参数），
      // 且 includePageCount 为 false，结果不带页数。
      expectedPages: 0,
      validator: (file, _) =>
          defaultDocxFileValidator(file, expectedImageCount),
      dialogTitle: '保存 Word 文档',
      includePageCount: false,
    );
  }

  /// 系统分享（Android「分享」；Windows/Linux 同样可用分享面板）。
  Future<ShareResult> shareWord(String path, {String? subject}) =>
      _inner.sharePdf(path, subject: subject);

  /// 打开 Word 文档（桌面端：系统启动器按默认程序打开；
  /// Android/iOS 无内置通道，返回 false，M3 改出「分享」）。
  Future<bool> openWord(String path) => _inner.openPdf(path);

  /// 打开所在文件夹（桌面端；Android/iOS 返回 false）。
  Future<bool> openContainingFolder(String path) =>
      _inner.openContainingFolder(path);
}
