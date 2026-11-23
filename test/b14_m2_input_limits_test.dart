// B 包 P1-04：ZIP 的中央目录 rawSize 不可信。
// 构造一个“rawSize 谎报 1 字节、实际解压 2MB”的 zip：
// - 解码前的 rawSize 预判放行；
// - 单条目有界 inflate 必须在实际输出超过 maxTotalBytes 时拒绝，
//   而不是先完整解出 2MB 再按 rawSize 不一致报“校验失败”。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/services/page_image_pipeline.dart';
import 'package:quiz_master2/services/zip_archive.dart';

int _findCentralHeader(List<int> bytes) {
  for (var i = 0; i + 4 <= bytes.length; i++) {
    if (bytes[i] == 0x50 &&
        bytes[i + 1] == 0x4B &&
        bytes[i + 2] == 0x01 &&
        bytes[i + 3] == 0x02) {
      return i;
    }
  }
  throw StateError('测试构造的 zip 找不到中央目录');
}

void _writeLe32(List<int> bytes, int offset, int value) {
  for (var i = 0; i < 4; i++) {
    bytes[offset + i] = (value >> (8 * i)) & 0xFF;
  }
}

void main() {
  test('zip bomb：rawSize 谎报时按实际解压输出拒绝（P1-04）', () {
    final payload = List<int>.filled(2 * 1024 * 1024, 0);
    final bytes = buildZip([
      ZipEntryData('huge.bin', payload),
    ]);
    final central = _findCentralHeader(bytes);
    // 中央目录 rawSize 在签名/版本/flag/method/time/date/crc/comp 之后：
    // +24 起 4 字节。改成 1，让预检放行。
    _writeLe32(bytes, central + 24, 1);

    expect(
      () => readZip(
        Uint8List.fromList(bytes),
        maxTotalBytes: 1024 * 1024,
      ),
      throwsA(
        isA<ZipFormatException>().having(
          (e) => e.message,
          'message',
          contains('超过'),
        ),
      ),
    );
  });

  test('对照：正常 zip 仍可读（不被上限误伤）', () {
    final bytes = buildZip([
      ZipEntryData('backup.json', [1, 2, 3, 4]),
    ]);
    final entries = readZip(Uint8List.fromList(bytes));
    expect(entries.single.name, 'backup.json');
    expect(entries.single.bytes, [1, 2, 3, 4]);
  });

  test('真实大 JPEG（6000×4000，含 progressive SOF2 段）头解析正确', () async {
    final bytes = Uint8List.fromList(
      await File('test/fixtures/progressive-large.jpg').readAsBytes(),
    );
    final dims = readImageDimensions(bytes);
    expect(dims, isNotNull);
    expect(dims!.width, 6000);
    expect(dims.height, 4000);
  });
}
