// 十八批 P1（D-216）：Word 行内公式基线对齐——run 级 w:position 注入。
//
// 背景：Word 行内图（wp:inline）的图底贴文字基线，公式基线在图底
// 上方 (heightPt − baselineOffsetPt) 处；要把公式基线落到文字基线
// 上，须把整张图下移同样的量。落点机制是 run 级 `w:position`
// （OOXML：run 内容相对基线升降，单位半磅，负值 = 下移）。
//
// 为什么是导出后注入，而不是 docx_creator 里配：
// - docx_creator 1.4.0 的 `DocxInlineImage` 不支持垂直偏移——
//   inline 路径（docx_image.dart `_buildInline`）只发 plain
//   `wp:inline`，无任何偏移字段；`x`/`y`/`vAlign` 只在 floating
//   （`wp:anchor`）模式生效；`DocxText` 也没有 position 字段。
// - anchor（浮动图）是唯一库内支持的定位方式，但它会改变换行与
//   绕排（图不再占行内位置），破坏最小的原则下不采用。
// - `DocxRawInline` 能发任意行内 XML，但导出器只给 `DocxInlineImage`
//   节点分配图片关系 ID（docx_collection_manager.dart），手写
//   drawing 拿不到 r:embed，走不通。
// 因此在 `DocxExporter().exportToBytes` 之后、落盘之前改
// `word/document.xml`：给行内公式图的 `<w:r>` 首位注入
// `<w:rPr><w:position w:val="N"/></w:rPr>`。图仍是 wp:inline，
// 换行/绕排不变；只移动该 run（含图）在行内的垂直位置。
//
// 约束（与 word_delivery.dart 同款）：生产库不得 import
// `package:archive`（dev_dependency）与 `package:xml`，故 zip
// 读写全部手写（局部文件头 + 中央目录解析 + raw deflate 编解码
// 用 dart:io 的 ZLibCodec + 手写 CRC32）。只改 `word/document.xml`
// 一个部件，其余部件压缩字节原样复制；结构对不上（非 zip、无
// document.xml、drawing 数与下移表长度不一致、未知压缩方式）一律
// 响亮抛错，不静默放出未对齐的文件。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 行内公式的 `w:position` 值（十八批 P1 D-216）。
///
/// [heightPt] 为公式图显示高，[baselineOffsetPt] 为栅格化器量得的
/// 图片顶到数学基线的距离。Word 图底贴文字基线，公式基线在图底上方
/// (heightPt − baselineOffsetPt) 处，下移该量即对齐。
/// 返回 `w:position` 的 `w:val`（半磅；负值 = 下移，正值 = 上移）。
/// 基线未知（null）或下移量四舍五入到 0 半磅时返回 null（不注入，
/// 保持旧行为）。
int? wordFormulaPositionHalfPoints({
  required double heightPt,
  required double? baselineOffsetPt,
}) {
  if (baselineOffsetPt == null) return null;
  final shiftPt = heightPt - baselineOffsetPt;
  final halfPoints = -(shiftPt * 2).round();
  if (halfPoints == 0) return null;
  return halfPoints;
}

/// 给导出后的 docx 字节注入行内公式基线偏移。
///
/// [positionHalfPoints] 与 `word/document.xml` 内 `<w:r><w:drawing>`
/// 的出现顺序一一对应（文档顺序，含独立图与行内公式图）：有值的
/// 项给对应 run 注入 `w:position`，null 的项原样不动。
/// 长度与 drawing 数不一致、或文档结构不符合预期时抛 [StateError]
/// （调用方按生成失败处理，不放出未对齐的文件）。
/// 无任何非 null 项时原样返回输入字节，不碰 zip；空表不短路
/// （须校验 drawing 数为 0，不符时抛错）。
Uint8List applyWordFormulaBaselineShifts(
  Uint8List docxBytes,
  List<int?> positionHalfPoints,
) {
  if (positionHalfPoints.isNotEmpty &&
      positionHalfPoints.every((v) => v == null)) {
    return docxBytes;
  }
  final entries = _readZipEntries(docxBytes);
  final docIndex = entries.indexWhere((e) => e.name == 'word/document.xml');
  if (docIndex < 0) {
    throw StateError('Word 基线注入失败：docx 内无 word/document.xml');
  }
  final docEntry = entries[docIndex];
  final xml = utf8.decode(_entryData(docxBytes, docEntry));
  final shifted = _injectPositions(xml, positionHalfPoints);
  final newDocBytes = utf8.encode(shifted);
  return _rebuildZip(docxBytes, entries, docIndex, newDocBytes);
}

/// 把 `w:position` 注入 document.xml 文本。
///
/// 逐段落扫描：`<w:p>…</w:p>` 内每个 `<w:r><w:drawing>` 按文档顺序
/// 消费 [positionHalfPoints] 的一项；有值则在 `<w:r>` 后插入
/// `<w:rPr><w:position w:val="N"/></w:rPr>`（rPr 须为 run 的首个
/// 子元素）。drawing 总数与表长不一致时抛错（不得错位注入）。
String _injectPositions(String xml, List<int?> positionHalfPoints) {
  final buffer = StringBuffer();
  var consumed = 0;
  var searchFrom = 0;
  while (true) {
    final pStart = _nextParagraphStart(xml, searchFrom);
    if (pStart < 0) break;
    final pOpenEnd = xml.indexOf('>', pStart);
    if (pOpenEnd < 0) {
      throw StateError('Word 基线注入失败：document.xml 段落标签不完整');
    }
    final pEnd = xml.indexOf('</w:p>', pOpenEnd);
    if (pEnd < 0) {
      throw StateError('Word 基线注入失败：document.xml 段落未闭合');
    }
    final pCloseEnd = pEnd + '</w:p>'.length;
    // 段落前的内容原样保留。
    buffer.write(xml.substring(searchFrom, pStart));
    // 段落内逐个处理 drawing run。
    var inner = xml.substring(pStart, pCloseEnd);
    var innerFrom = 0;
    while (true) {
      final runAt = inner.indexOf('<w:r><w:drawing>', innerFrom);
      if (runAt < 0) break;
      if (consumed >= positionHalfPoints.length) {
        throw StateError(
          'Word 基线注入失败：drawing 数多于下移表长度'
          '（${positionHalfPoints.length}）',
        );
      }
      final value = positionHalfPoints[consumed];
      consumed++;
      if (value != null) {
        const runOpen = '<w:r><w:drawing>';
        final injected =
            '<w:r><w:rPr><w:position w:val="$value"/></w:rPr><w:drawing>';
        inner =
            '${inner.substring(0, runAt)}$injected${inner.substring(runAt + runOpen.length)}';
        innerFrom = runAt + injected.length;
      } else {
        innerFrom = runAt + '<w:r><w:drawing>'.length;
      }
    }
    buffer.write(inner);
    searchFrom = pCloseEnd;
  }
  buffer.write(xml.substring(searchFrom));
  if (consumed != positionHalfPoints.length) {
    throw StateError(
      'Word 基线注入失败：drawing 数（$consumed）少于下移表长度'
      '（${positionHalfPoints.length}）',
    );
  }
  return buffer.toString();
}

/// 找下一个段落开始（`<w:p>` 或带属性的 `<w:p …>`）。
///
/// 不能直接搜 `<w:p` 前缀——`<w:pPr>` 与 `<w:pgSz>`（sectPr 里）
/// 都有此前缀，须校验后一字符为 `>` 或空白。
int _nextParagraphStart(String xml, int from) {
  var at = from;
  while (true) {
    final idx = xml.indexOf('<w:p', at);
    if (idx < 0) return -1;
    final next = idx + 4;
    if (next < xml.length && (xml[next] == '>' || xml[next] == ' ')) {
      return idx;
    }
    at = idx + 4;
  }
}

/// zip 中央目录条目（解析用；只含重建需要的字段）。
class _ZipEntry {
  const _ZipEntry({
    required this.name,
    required this.method,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
    required this.versionMadeBy,
    required this.versionNeeded,
    required this.modTime,
    required this.modDate,
    required this.internalAttrs,
    required this.externalAttrs,
  });

  final String name;
  final int method;
  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;
  final int versionMadeBy;
  final int versionNeeded;
  final int modTime;
  final int modDate;
  final int internalAttrs;
  final int externalAttrs;
}

/// 读 zip 中央目录（EOCD 定位 + 逐条目走访；与 word_delivery.dart
/// 的 `_readZipEntryNames` 同款定位方式，另取各条目的方法/CRC/尺寸
/// 与局部头偏移）。解析失败抛 [StateError]。
List<_ZipEntry> _readZipEntries(Uint8List bytes) {
  if (bytes.length < 22 ||
      bytes[0] != 0x50 ||
      bytes[1] != 0x4B ||
      bytes[2] != 0x03 ||
      bytes[3] != 0x04) {
    throw StateError('Word 基线注入失败：输入不是 zip（无 PK 魔数）');
  }
  final data = ByteData.sublistView(bytes);
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
  if (eocd < 0) {
    throw StateError('Word 基线注入失败：找不到 zip 中央目录结束记录');
  }
  final totalEntries = data.getUint16(eocd + 10, Endian.little);
  final cdOffset = data.getUint32(eocd + 16, Endian.little);
  if (cdOffset >= bytes.length) {
    throw StateError('Word 基线注入失败：中央目录偏移越界');
  }
  final entries = <_ZipEntry>[];
  var offset = cdOffset;
  for (var i = 0; i < totalEntries; i++) {
    if (offset + 46 > bytes.length ||
        data.getUint32(offset, Endian.little) != 0x02014b50) {
      throw StateError('Word 基线注入失败：中央目录条目损坏');
    }
    final nameLen = data.getUint16(offset + 28, Endian.little);
    final extraLen = data.getUint16(offset + 30, Endian.little);
    final commentLen = data.getUint16(offset + 32, Endian.little);
    final nameStart = offset + 46;
    final nameEnd = nameStart + nameLen;
    if (nameEnd > bytes.length) {
      throw StateError('Word 基线注入失败：中央目录条目名越界');
    }
    final name = utf8.decode(bytes.sublist(nameStart, nameEnd));
    entries.add(
      _ZipEntry(
        name: name,
        method: data.getUint16(offset + 10, Endian.little),
        crc32: data.getUint32(offset + 16, Endian.little),
        compressedSize: data.getUint32(offset + 20, Endian.little),
        uncompressedSize: data.getUint32(offset + 24, Endian.little),
        localHeaderOffset: data.getUint32(offset + 42, Endian.little),
        versionMadeBy: data.getUint16(offset + 4, Endian.little),
        versionNeeded: data.getUint16(offset + 6, Endian.little),
        modTime: data.getUint16(offset + 12, Endian.little),
        modDate: data.getUint16(offset + 14, Endian.little),
        internalAttrs: data.getUint16(offset + 36, Endian.little),
        externalAttrs: data.getUint32(offset + 38, Endian.little),
      ),
    );
    offset = nameEnd + extraLen + commentLen;
  }
  return entries;
}

/// 取一条目的解压后字节（method 0 = 原样，8 = raw deflate；其余抛错）。
Uint8List _entryData(Uint8List bytes, _ZipEntry entry) {
  final data = ByteData.sublistView(bytes);
  final local = entry.localHeaderOffset;
  if (local + 30 > bytes.length ||
      data.getUint32(local, Endian.little) != 0x04034b50) {
    throw StateError(
      'Word 基线注入失败：条目 ${entry.name} 的局部文件头损坏',
    );
  }
  final nameLen = data.getUint16(local + 26, Endian.little);
  final extraLen = data.getUint16(local + 28, Endian.little);
  final dataStart = local + 30 + nameLen + extraLen;
  final dataEnd = dataStart + entry.compressedSize;
  if (dataEnd > bytes.length) {
    throw StateError('Word 基线注入失败：条目 ${entry.name} 数据越界');
  }
  final raw = bytes.sublist(dataStart, dataEnd);
  if (entry.method == 0) return Uint8List.fromList(raw);
  if (entry.method == 8) {
    return Uint8List.fromList(ZLibDecoder(raw: true).convert(raw));
  }
  throw StateError(
    'Word 基线注入失败：条目 ${entry.name} 的压缩方式（${entry.method}）'
    '不支持',
  );
}

/// 重建 zip：[replaceIndex] 条目换成 [newUncompressed]（重新 deflate），
/// 其余条目压缩字节原样复制；局部头与中央目录全部重写（无 extra /
/// 注释 / 数据描述符；时间戳与版本字段沿用原中央目录值）。
Uint8List _rebuildZip(
  Uint8List original,
  List<_ZipEntry> entries,
  int replaceIndex,
  Uint8List newUncompressed,
) {
  final out = BytesBuilder();
  final newOffsets = <int>[];
  // 替换条目只压缩一次（局部头与中央目录共用同一份压缩字节）。
  final replacedCompressed = Uint8List.fromList(
    ZLibEncoder(raw: true).convert(newUncompressed),
  );
  final replacedCrc = _crc32(newUncompressed);
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    newOffsets.add(out.length);
    late final Uint8List compressed;
    late final int crc;
    late final int method;
    if (i == replaceIndex) {
      method = 8;
      compressed = replacedCompressed;
      crc = replacedCrc;
    } else {
      method = entry.method;
      compressed = _entryCompressedBytes(original, entry);
      crc = entry.crc32;
    }
    _writeLocalHeader(
      out,
      versionNeeded: entry.versionNeeded,
      method: method,
      modTime: entry.modTime,
      modDate: entry.modDate,
      crc: crc,
      compressedSize: compressed.length,
      uncompressedSize: i == replaceIndex
          ? newUncompressed.length
          : entry.uncompressedSize,
      name: entry.name,
    );
    out.add(compressed);
  }
  final cdOffset = out.length;
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    final isReplaced = i == replaceIndex;
    _writeCentralHeader(
      out,
      versionMadeBy: entry.versionMadeBy,
      versionNeeded: entry.versionNeeded,
      method: isReplaced ? 8 : entry.method,
      modTime: entry.modTime,
      modDate: entry.modDate,
      crc: isReplaced ? replacedCrc : entry.crc32,
      compressedSize: isReplaced
          ? replacedCompressed.length
          : entry.compressedSize,
      uncompressedSize: isReplaced
          ? newUncompressed.length
          : entry.uncompressedSize,
      localHeaderOffset: newOffsets[i],
      internalAttrs: entry.internalAttrs,
      externalAttrs: entry.externalAttrs,
      name: entry.name,
    );
  }
  final cdSize = out.length - cdOffset;
  final eocd = BytesBuilder();
  eocd.addByte(0x50);
  eocd.addByte(0x4B);
  eocd.addByte(0x05);
  eocd.addByte(0x06);
  final eocdData = ByteData(18);
  eocdData.setUint16(0, 0, Endian.little); // 本盘编号
  eocdData.setUint16(2, 0, Endian.little); // 中央目录起始盘
  eocdData.setUint16(4, entries.length, Endian.little);
  eocdData.setUint16(6, entries.length, Endian.little);
  eocdData.setUint32(8, cdSize, Endian.little);
  eocdData.setUint32(12, cdOffset, Endian.little);
  eocdData.setUint16(16, 0, Endian.little); // 注释长度
  eocd.add(eocdData.buffer.asUint8List());
  out.add(eocd.toBytes());
  return out.toBytes();
}

/// 取一条目的压缩后原始字节（原样复制用，不解压）。
Uint8List _entryCompressedBytes(Uint8List bytes, _ZipEntry entry) {
  final data = ByteData.sublistView(bytes);
  final local = entry.localHeaderOffset;
  final nameLen = data.getUint16(local + 26, Endian.little);
  final extraLen = data.getUint16(local + 28, Endian.little);
  final dataStart = local + 30 + nameLen + extraLen;
  return Uint8List.fromList(
    bytes.sublist(dataStart, dataStart + entry.compressedSize),
  );
}

void _writeLocalHeader(
  BytesBuilder out, {
  required int versionNeeded,
  required int method,
  required int modTime,
  required int modDate,
  required int crc,
  required int compressedSize,
  required int uncompressedSize,
  required String name,
}) {
  final nameBytes = utf8.encode(name);
  final header = ByteData(30);
  header.setUint32(0, 0x04034b50, Endian.little);
  header.setUint16(4, versionNeeded, Endian.little);
  header.setUint16(6, 0, Endian.little); // 通用标志：无数据描述符
  header.setUint16(8, method, Endian.little);
  header.setUint16(10, modTime, Endian.little);
  header.setUint16(12, modDate, Endian.little);
  header.setUint32(14, crc, Endian.little);
  header.setUint32(18, compressedSize, Endian.little);
  header.setUint32(22, uncompressedSize, Endian.little);
  header.setUint16(26, nameBytes.length, Endian.little);
  header.setUint16(28, 0, Endian.little); // extra 长度
  out.add(header.buffer.asUint8List());
  out.add(nameBytes);
}

void _writeCentralHeader(
  BytesBuilder out, {
  required int versionMadeBy,
  required int versionNeeded,
  required int method,
  required int modTime,
  required int modDate,
  required int crc,
  required int compressedSize,
  required int uncompressedSize,
  required int localHeaderOffset,
  required int internalAttrs,
  required int externalAttrs,
  required String name,
}) {
  final nameBytes = utf8.encode(name);
  final header = ByteData(46);
  header.setUint32(0, 0x02014b50, Endian.little);
  header.setUint16(4, versionMadeBy, Endian.little);
  header.setUint16(6, versionNeeded, Endian.little);
  header.setUint16(8, 0, Endian.little); // 通用标志
  header.setUint16(10, method, Endian.little);
  header.setUint16(12, modTime, Endian.little);
  header.setUint16(14, modDate, Endian.little);
  header.setUint32(16, crc, Endian.little);
  header.setUint32(20, compressedSize, Endian.little);
  header.setUint32(24, uncompressedSize, Endian.little);
  header.setUint16(28, nameBytes.length, Endian.little);
  header.setUint16(30, 0, Endian.little); // extra 长度
  header.setUint16(32, 0, Endian.little); // 注释长度
  header.setUint16(34, 0, Endian.little); // 起始盘
  header.setUint16(36, internalAttrs, Endian.little);
  header.setUint32(38, externalAttrs, Endian.little);
  header.setUint32(42, localHeaderOffset, Endian.little);
  out.add(header.buffer.asUint8List());
  out.add(nameBytes);
}

/// CRC-32（IEEE 802.3，zip 用款；查表法）。
int _crc32(Uint8List bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

final List<int> _crcTable = _buildCrcTable();

List<int> _buildCrcTable() {
  const poly = 0xEDB88320;
  final table = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var j = 0; j < 8; j++) {
      c = (c & 1) != 0 ? poly ^ (c >> 1) : c >> 1;
    }
    table[i] = c;
  }
  return table;
}
