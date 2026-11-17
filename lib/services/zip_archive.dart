// P3（§2.3/§4.6）：纯 Dart 的最小 ZIP 读写，不引新依赖。
//
// 为什么手写：pubspec 不动依赖（方案 §7 P3 不动依赖），Dart 标准库
// 没有 ZIP。只实现备份/恢复需要的子集：
// - 写：deflate（`ZLibCodec(raw: true)`，ZIP 的 method 8）+ CRC32；
// - 读：method 0（stored）与 8（deflate），按中央目录解析；
// - 校验：条目名只允许数据目录内的相对路径（见 [validateZipEntryName]）。
// 不支持：加密、多盘、ZIP64、大于 4GB 的单个条目（备份上限 2GB，不会触及）。
// SR-P2-68：读改走中央目录（以前按 local header 顺序读）：流式写出
// 的 zip（local header 里 flag bit 3 置位、尺寸在数据后的描述符里）
// 以前会被误读（尺寸取 0）；只含目录条目的空 zip 以前静默返回 []；
// 单条目解压在累计 total 检查之前完成，超大单条目会先占满内存再
// 触发上限。新读法以中央目录为准：条目数/偏移/尺寸都以中央目录
// 为准，local header 只用来定位数据起点，bit 3 的描述符直接跳过
// （按中央目录的 compSize 切数据）；解压前先用中央目录的 rawSize
// 做上限预判；无文件条目直接抛错。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// ZIP 条目：名字一律用 `/` 分隔的相对路径（如 `imports/<task>/original.jpg`）。
class ZipEntryData {
  const ZipEntryData(this.name, this.bytes);
  final String name;
  final List<int> bytes;
}

/// ZIP 格式错误（不是 ZIP / 结构损坏 / 条目非法）：调用方按
/// BackupRestoreException 的口径向用户报错，不要静默跳过坏条目。
class ZipFormatException implements Exception {
  ZipFormatException(this.message);
  final String message;
  @override
  String toString() => 'ZipFormatException: $message';
}

/// ZIP 魔数 `PK\x03\x04`：备份文件是 zip 还是老 JSON，靠它识别
/// （不靠扩展名——用户可能改后缀；见 §2.3 老 .qm2backup JSON 口径）。
bool isZipBytes(List<int> bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x50 &&
    bytes[1] == 0x4B &&
    bytes[2] == 0x03 &&
    bytes[3] == 0x04;

/// 归一化 ZIP 条目名：`\`→`/`、折叠连续 `/`、消解 `.` 段。
/// 只用于比较与校验，不改存名与落盘路径；`..` 段保留，由
/// [validateZipEntryName] 拒绝（消解 `..` 会掩盖穿越）。
/// SR3-1：[readZip] 的判重键用它（再小写折叠），与 [validateZipEntryName]
/// 共用同一函数——`slices//q1.png` / `slices/./q1.png` / `slices\q1.png` /
/// `Slices/Q1.png` 在文件系统上与 `slices/q1.png` 是同一文件，原始字符
/// 串判重会放行，恢复进位时第二遍 rename 因源文件已被第一遍 rename 走
/// 而抛错，又被误报为“文件写不进去”（SR2-17 的误报回归）。
String normalizeZipEntryName(String name) {
  final kept = <String>[];
  for (final part in name.replaceAll('\\', '/').split('/')) {
    if (part.isEmpty || part == '.') continue;
    kept.add(part);
  }
  return kept.join('/');
}

/// 校验一个 ZIP 条目名是否可安全解压到数据目录内。
/// 返回 null 表示通过；否则返回拒绝原因（调用方拒绝整个恢复包，
/// 不许跳过坏条目继续解——跳过会让恢复结果不可预期，见 §4.6）。
/// 拒绝：绝对路径（含盘符 `C:` / 以 `/` 开头）、`..` 段（含 `..\`）、
/// 空名、反斜杠分隔的穿越（Windows 上 `\` 也是分隔符）。
/// 空段（`//`）与 `.` 段不拒绝：归一化后它们与规范写法同一文件，
/// 重名时由 [readZip] 的判重拒绝，单条时落盘由路径解析折叠（SR3-1）。
String? validateZipEntryName(String name) {
  if (name.isEmpty) return '条目名为空';
  // 绝对路径与盘符在归一化前判（归一化会折叠掉开头的空段，
  // `//slices/q1.png` 归一化后不再以 `/` 开头）。
  final slashified = name.replaceAll('\\', '/');
  if (slashified.startsWith('/')) return '条目是绝对路径：$name';
  if (slashified.contains(':')) return '条目含盘符：$name';
  final normalized = normalizeZipEntryName(name);
  if (normalized.isEmpty) return '条目名为空：$name';
  for (final part in normalized.split('/')) {
    if (part == '..') return '条目穿越出数据目录：$name';
  }
  return null;
}

// ---------- CRC32（IEEE 802.3，ZIP 用的就是它） ----------

final _crcTable = _buildCrcTable();

List<int> _buildCrcTable() {
  final table = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}

int crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}

// ---------- 写 ----------

int _dosTime(DateTime t) => (t.hour << 11) | (t.minute << 5) | (t.second ~/ 2);
int _dosDate(DateTime t) => ((t.year - 1980) << 9) | (t.month << 5) | t.day;

/// 把若干条目打包成一个 ZIP（deflate 压缩）。条目名须已通过
/// [validateZipEntryName]（否则抛 [ZipFormatException]）。
List<int> buildZip(List<ZipEntryData> entries, {DateTime? modified}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  final now = modified ?? DateTime.now();
  final time = _dosTime(now);
  final date = _dosDate(now);
  final deflate = ZLibCodec(raw: true);

  for (final entry in entries) {
    final bad = validateZipEntryName(entry.name);
    if (bad != null) throw ZipFormatException('不能打包非法条目名：$bad');
    final nameBytes = utf8.encode(entry.name);
    final compressed = deflate.encode(entry.bytes);
    final crc = crc32(entry.bytes);
    final localOffset = out.length;

    void u16(int v) => out.add([v & 0xFF, (v >> 8) & 0xFF]);
    void u32(int v) => out.add([
      v & 0xFF,
      (v >> 8) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 24) & 0xFF,
    ]);
    // Local file header.
    out.add([0x50, 0x4B, 0x03, 0x04]);
    u16(20); // version needed (deflate)
    u16(0x0800); // flags: UTF-8 文件名
    u16(8); // method: deflate
    u16(time);
    u16(date);
    u32(crc);
    u32(compressed.length);
    u32(entry.bytes.length);
    u16(nameBytes.length);
    u16(0); // extra length
    out.add(nameBytes);
    out.add(compressed);

    void cu16(int v) => central.add([v & 0xFF, (v >> 8) & 0xFF]);
    void cu32(int v) => central.add([
      v & 0xFF,
      (v >> 8) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 24) & 0xFF,
    ]);
    // Central directory header.
    central.add([0x50, 0x4B, 0x01, 0x02]);
    cu16(20); // version made by
    cu16(20); // version needed
    cu16(0x0800);
    cu16(8);
    cu16(time);
    cu16(date);
    cu32(crc);
    cu32(compressed.length);
    cu32(entry.bytes.length);
    cu16(nameBytes.length);
    cu16(0); // extra
    cu16(0); // comment
    cu16(0); // disk
    cu16(0); // internal attrs
    cu32(0); // external attrs
    cu32(localOffset);
    central.add(nameBytes);
  }

  final centralOffset = out.length;
  final centralBytes = central.takeBytes();
  out.add(centralBytes);
  void u16(int v) => out.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(int v) =>
      out.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  // End of central directory.
  out.add([0x50, 0x4B, 0x05, 0x06]);
  u16(0);
  u16(0);
  u16(entries.length);
  u16(entries.length);
  u32(centralBytes.length);
  u32(centralOffset);
  u16(0);
  return out.takeBytes();
}

// ---------- 读 ----------

int _readU16(List<int> b, int off) => b[off] | (b[off + 1] << 8);
int _readU32(List<int> b, int off) =>
    b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

/// 解包：按中央目录读出全部文件条目（目录条目跳过）。
/// 任一条目名非法（见 [validateZipEntryName]）或结构损坏 → 抛
/// [ZipFormatException]，调用方拒绝整个包。另设解压后总大小上限
/// （默认 4GB，防 zip 炸弹；合法备份上限 2GB，不会触及）。
/// SR2-17：重名文件条目即结构损坏（FR-40：`backup.json` 重名也一样，
/// 不再放行——之前放行、调用方取最后一个，两份内容不同的题目数据会静默
/// 按后一份恢复、无任何提示；现在直接拒绝并提示“备份里有两份题目数据”）。
/// SR3-1：判重键是归一化 + 小写折叠后的条目名——`//` / `/.` /
/// `\` / 大小写变体在文件系统上是同一文件，原始字符串判重会
/// 放行，恢复进位时第二遍 rename 因源文件已被第一遍 rename 走
/// 而抛错，又被误报为“文件写不进去”（SR2-17 的误报回归）。
/// SR3-1：判重键是归一化后的条目名再小写折叠（见 [normalizeZipEntryName]），
/// 仅用于比较，不改存名与落盘路径；单条变体（如单独一个 `slices//q1.png`）
/// 不重名，照常读出，落盘由路径解析折叠。
/// SR-P2-68：中央目录是唯一可信的条目清单——
/// - 流式写出的 zip（local header flag bit 3 置位、尺寸为 0、真实
///   尺寸在数据后的描述符里）按中央目录的尺寸读，不再误读；
/// - 中央目录的条目数与偏移逐项校验，local header 名与中央目录名
///   不一致即结构损坏；
/// - 解压前先用中央目录的 rawSize 做上限预判（超大单条目不再先
///   占满内存再触发上限）；
/// - 无文件条目（空 zip / 只含目录条目）直接抛错，不再静默返回 []。
/// 不支持 ZIP64（尺寸字段为 0xFFFFFFFF 时抛错）与多盘。
List<ZipEntryData> readZip(
  List<int> bytes, {
  int maxTotalBytes = 4 * 1024 * 1024 * 1024,
}) {
  if (!isZipBytes(bytes)) {
    throw ZipFormatException('不是 ZIP 文件');
  }
  final central = _parseCentralDirectory(bytes);
  final entries = <ZipEntryData>[];
  final seenNames = <String>{};
  var total = 0;
  final inflate = ZLibCodec(raw: true);
  for (final entry in central) {
    if (entry.name.endsWith('/')) continue; // 目录条目跳过
    final bad = validateZipEntryName(entry.name);
    if (bad != null) throw ZipFormatException('备份里有非法路径：$bad');
    // SR2-17：重名文件条目即结构损坏（FR-40：backup.json 重名也拒绝）。
    // SR3-1：判重键是归一化 + 小写折叠后的条目名——`//` / `/.` /
    // `\` / 大小写变体在文件系统上是同一文件，原始字符串判重会
    // 放行，恢复进位时第二遍 rename 抛错又被误报为“文件写不进去”。
    if (!seenNames.add(normalizeZipEntryName(entry.name).toLowerCase())) {
      if (normalizeZipEntryName(entry.name).toLowerCase() == 'backup.json') {
        throw ZipFormatException('备份里有两份题目数据（backup.json 重复）');
      }
      throw ZipFormatException('ZIP 里有重复条目：${entry.name}');
    }
    if ((entry.flags & 0x01) != 0) {
      throw ZipFormatException('不支持加密的 ZIP 备份');
    }
    // 解压前预判：累计 rawSize 超上限即拒绝，不先解压占内存。
    if (total + entry.rawSize > maxTotalBytes) {
      throw ZipFormatException('备份解压后超过 ${_formatLimit(maxTotalBytes)}，拒绝恢复');
    }
    final dataStart = _localDataStart(bytes, entry);
    if (dataStart + entry.compSize > bytes.length) {
      throw ZipFormatException('ZIP 结构损坏：文件数据超出文件末尾');
    }
    final compressed = bytes.sublist(dataStart, dataStart + entry.compSize);
    List<int> data;
    if (entry.method == 0) {
      data = compressed;
    } else if (entry.method == 8) {
      try {
        data = inflate.decode(compressed);
      } catch (_) {
        throw ZipFormatException('ZIP 解压失败：${entry.name}');
      }
    } else {
      throw ZipFormatException('不支持的压缩方式（${entry.method}）：${entry.name}');
    }
    if (data.length != entry.rawSize || crc32(data) != entry.crc) {
      throw ZipFormatException('ZIP 校验失败：${entry.name} 已损坏');
    }
    total += data.length;
    entries.add(ZipEntryData(entry.name, data));
  }
  if (entries.isEmpty) {
    throw ZipFormatException('ZIP 里没有文件');
  }
  return entries;
}

String _formatLimit(int bytes) {
  if (bytes % (1024 * 1024 * 1024) == 0) {
    return '${bytes ~/ (1024 * 1024 * 1024)}GB';
  }
  if (bytes % (1024 * 1024) == 0) return '${bytes ~/ (1024 * 1024)}MB';
  return '$bytes B';
}

/// 中央目录里的一条记录（读 zip 时唯一可信的条目清单）。
class _CentralEntry {
  const _CentralEntry({
    required this.name,
    required this.flags,
    required this.method,
    required this.crc,
    required this.compSize,
    required this.rawSize,
    required this.localOffset,
  });
  final String name;
  final int flags;
  final int method;
  final int crc;
  final int compSize;
  final int rawSize;
  final int localOffset;
}

/// 找 End of Central Directory（EOCD，`PK\x05\x06`），解析中央目录。
/// EOCD 必须在文件末尾（后面只跟注释）；找不到、多盘、偏移越界、
/// 条目头签名不对、ZIP64 一律抛 [ZipFormatException]。
List<_CentralEntry> _parseCentralDirectory(List<int> bytes) {
  // EOCD 记录 22 字节 + 最长 64KB 注释：从末尾往前找，取最后一个
  // “记录恰好到文件末尾”的位置（注释里可能恰好含 PK\x05\x06）。
  var eocd = -1;
  final searchStart = bytes.length - 22;
  final searchEnd = bytes.length - 22 - 65535 < 0
      ? 0
      : bytes.length - 22 - 65535;
  for (var i = searchStart; i >= searchEnd; i--) {
    if (_readU32(bytes, i) != 0x06054B50) continue;
    final commentLen = _readU16(bytes, i + 20);
    if (i + 22 + commentLen == bytes.length) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) {
    throw ZipFormatException('ZIP 结构损坏：找不到中央目录');
  }
  final disk = _readU16(bytes, eocd + 4);
  final cdDisk = _readU16(bytes, eocd + 6);
  final entriesThisDisk = _readU16(bytes, eocd + 8);
  final totalEntries = _readU16(bytes, eocd + 10);
  final cdSize = _readU32(bytes, eocd + 12);
  final cdOffset = _readU32(bytes, eocd + 16);
  if (disk != 0 || cdDisk != 0 || entriesThisDisk != totalEntries) {
    throw ZipFormatException('不支持多盘的 ZIP 备份');
  }
  if (cdOffset + cdSize > bytes.length) {
    throw ZipFormatException('ZIP 结构损坏：中央目录超出文件末尾');
  }
  final out = <_CentralEntry>[];
  var off = cdOffset;
  final cdEnd = cdOffset + cdSize;
  for (var n = 0; n < totalEntries; n++) {
    if (off + 46 > cdEnd) {
      throw ZipFormatException('ZIP 结构损坏：中央目录不完整');
    }
    if (_readU32(bytes, off) != 0x02014B50) {
      throw ZipFormatException('ZIP 结构损坏：偏移 $off 处不是中央目录头');
    }
    final diskStart = _readU16(bytes, off + 34);
    if (diskStart != 0) {
      throw ZipFormatException('不支持多盘的 ZIP 备份');
    }
    final flags = _readU16(bytes, off + 8);
    final method = _readU16(bytes, off + 10);
    final crc = _readU32(bytes, off + 16);
    final compSize = _readU32(bytes, off + 20);
    final rawSize = _readU32(bytes, off + 24);
    final localOffset = _readU32(bytes, off + 42);
    if (compSize == 0xFFFFFFFF ||
        rawSize == 0xFFFFFFFF ||
        localOffset == 0xFFFFFFFF) {
      throw ZipFormatException('不支持 ZIP64 的 ZIP 备份');
    }
    final nameLen = _readU16(bytes, off + 28);
    final extraLen = _readU16(bytes, off + 30);
    final commentLen = _readU16(bytes, off + 32);
    final nameStart = off + 46;
    if (nameStart + nameLen > cdEnd) {
      throw ZipFormatException('ZIP 结构损坏：中央目录条目名不完整');
    }
    final name = utf8.decode(bytes.sublist(nameStart, nameStart + nameLen));
    out.add(
      _CentralEntry(
        name: name,
        flags: flags,
        method: method,
        crc: crc,
        compSize: compSize,
        rawSize: rawSize,
        localOffset: localOffset,
      ),
    );
    off = nameStart + nameLen + extraLen + commentLen;
  }
  return out;
}

/// 给定中央目录条目，解析其 local header，返回文件数据的起点。
/// local header 的尺寸字段不可信（flag bit 3 置位时为 0，真实尺寸在
/// 数据后的描述符里），只用它跳过文件名与 extra 段；名/方法与
/// 中央目录不一致即结构损坏。
int _localDataStart(List<int> bytes, _CentralEntry entry) {
  final off = entry.localOffset;
  if (off + 30 > bytes.length) {
    throw ZipFormatException('ZIP 结构损坏：文件头不完整');
  }
  if (_readU32(bytes, off) != 0x04034B50) {
    throw ZipFormatException('ZIP 结构损坏：偏移 $off 处不是文件头');
  }
  final method = _readU16(bytes, off + 8);
  final nameLen = _readU16(bytes, off + 26);
  final extraLen = _readU16(bytes, off + 28);
  final nameStart = off + 30;
  final dataStart = nameStart + nameLen + extraLen;
  if (dataStart > bytes.length) {
    throw ZipFormatException('ZIP 结构损坏：文件头不完整');
  }
  final localName = utf8.decode(bytes.sublist(nameStart, nameStart + nameLen));
  if (localName != entry.name || method != entry.method) {
    throw ZipFormatException('ZIP 结构损坏：文件头与中央目录不一致：${entry.name}');
  }
  return dataStart;
}
