// P3（§2.3/§4.6）：纯 Dart 的最小 ZIP 读写，不引新依赖。
//
// 为什么手写：pubspec 不动依赖（方案 §7 P3 不动依赖），Dart 标准库
// 没有 ZIP。只实现备份/恢复需要的子集：
// - 写：deflate（`ZLibCodec(raw: true)`，ZIP 的 method 8）+ CRC32；
// - 读：method 0（stored）与 8（deflate），按 local header 顺序解析；
// - 校验：条目名只允许数据目录内的相对路径（见 [validateZipEntryName]）。
// 不支持：加密、多盘、ZIP64、大于 4GB 的单个条目（备份上限 2GB，不会触及）。
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

/// 校验一个 ZIP 条目名是否可安全解压到数据目录内。
/// 返回 null 表示通过；否则返回拒绝原因（调用方拒绝整个恢复包，
/// 不许跳过坏条目继续解——跳过会让恢复结果不可预期，见 §4.6）。
/// 拒绝：绝对路径（含盘符 `C:` / 以 `/` 开头）、`..` 段（含 `..\`）、
/// 空名、反斜杠分隔的穿越（Windows 上 `\` 也是分隔符）。
String? validateZipEntryName(String name) {
  if (name.isEmpty) return '条目名为空';
  final normalized = name.replaceAll('\\', '/');
  if (normalized.startsWith('/')) return '条目是绝对路径：$name';
  if (normalized.contains(':')) return '条目含盘符：$name';
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

int _dosTime(DateTime t) =>
    (t.hour << 11) | (t.minute << 5) | (t.second ~/ 2);
int _dosDate(DateTime t) =>
    ((t.year - 1980) << 9) | (t.month << 5) | t.day;

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
  void u32(int v) => out.add([
        v & 0xFF,
        (v >> 8) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 24) & 0xFF,
      ]);
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

/// 解包：按 local header 顺序读出全部文件条目（目录条目跳过）。
/// 任一条目名非法（见 [validateZipEntryName]）或结构损坏 → 抛
/// [ZipFormatException]，调用方拒绝整个包。另设解压后总大小上限
/// （默认 4GB，防 zip 炸弹；合法备份上限 2GB，不会触及）。
List<ZipEntryData> readZip(List<int> bytes, {int maxTotalBytes = 4 * 1024 * 1024 * 1024}) {
  if (!isZipBytes(bytes)) {
    throw ZipFormatException('不是 ZIP 文件');
  }
  final entries = <ZipEntryData>[];
  var off = 0;
  var total = 0;
  final inflate = ZLibCodec(raw: true);
  while (off + 4 <= bytes.length) {
    final sig = _readU32(bytes, off);
    if (sig == 0x02014B50 || sig == 0x06054B50) break; // 中央目录 / 结束
    if (sig != 0x04034B50) {
      throw ZipFormatException('ZIP 结构损坏：偏移 $off 处不是文件头');
    }
    if (off + 30 > bytes.length) {
      throw ZipFormatException('ZIP 结构损坏：文件头不完整');
    }
    final flags = _readU16(bytes, off + 6);
    final method = _readU16(bytes, off + 8);
    final crc = _readU32(bytes, off + 14);
    final compSize = _readU32(bytes, off + 18);
    final rawSize = _readU32(bytes, off + 22);
    final nameLen = _readU16(bytes, off + 26);
    final extraLen = _readU16(bytes, off + 28);
    final nameStart = off + 30;
    final dataStart = nameStart + nameLen + extraLen;
    if (dataStart + compSize > bytes.length) {
      throw ZipFormatException('ZIP 结构损坏：文件数据超出文件末尾');
    }
    if ((flags & 0x01) != 0) {
      throw ZipFormatException('不支持加密的 ZIP 备份');
    }
    final name = utf8.decode(bytes.sublist(nameStart, nameStart + nameLen));
    final bad = validateZipEntryName(name);
    if (bad != null) throw ZipFormatException('备份里有非法路径：$bad');
    final compressed = bytes.sublist(dataStart, dataStart + compSize);
    List<int> data;
    if (method == 0) {
      data = compressed;
    } else if (method == 8) {
      try {
        data = inflate.decode(compressed);
      } catch (_) {
        throw ZipFormatException('ZIP 解压失败：$name');
      }
    } else {
      throw ZipFormatException('不支持的压缩方式（$method）：$name');
    }
    if (data.length != rawSize || crc32(data) != crc) {
      throw ZipFormatException('ZIP 校验失败：$name 已损坏');
    }
    total += data.length;
    if (total > maxTotalBytes) {
      throw ZipFormatException('备份解压后超过 4GB，拒绝恢复');
    }
    if (!name.endsWith('/')) entries.add(ZipEntryData(name, data));
    off = dataStart + compSize;
  }
  if (entries.isEmpty && off == 0) {
    throw ZipFormatException('ZIP 里没有文件');
  }
  return entries;
}
