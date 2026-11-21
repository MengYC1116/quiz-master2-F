// 十五批 M2：PDF 页数计数（纯 Dart，不依赖 pdf 包的写出路径）。
//
// 用途：
// - M2-2 原子写入验证：文件存在、大小 > 0、PDF 可打开、页数与预期一致
//   （“可打开”在 Linux 侧以“%PDF- 头 + 页树可解析”判定；真机上用
//   系统阅读器打开验证，见 M4 清单）。
// - M2-1 答案版：答案区先在一次性文档里排版计数，再按已知总页数
//   渲染正式文档，页脚“第 x / y 页”的分母才正确；保存后再数一次
//   做终态校验，对不上即整单失败、不发布。
//
// 计数依据（pdf 3.13.1 实测输出，见 M2 探针）：文档根页树节点为
// `<< /Type/Pages /Kids[...] /Count N >>`，N 即实际页数；每页对象
// 为 `/Type/Page/`（注意斜杠：`/Type/Pages` 不含该串，不会误数）。
// 优先读 `/Count`（页树权威值），读不到时退化为数 `/Type/Page/`
// 出现次数；两者都读不到返回 null（未知页数 → 验证失败，不发布）。
import 'dart:convert';
import 'dart:typed_data';

/// 是否为 PDF 字节（以 `%PDF-` 开头）。
bool isPdfBytes(Uint8List bytes) {
  if (bytes.length < 5) return false;
  return bytes[0] == 0x25 && // %
      bytes[1] == 0x50 && // P
      bytes[2] == 0x44 && // D
      bytes[3] == 0x46 && // F
      bytes[4] == 0x2D; // -
}

/// 数 PDF 字节的页数；无法确定时返回 null。
///
/// [bytes] 须为完整 PDF 字节（`save()` await 完成后的输出）。
/// 非 PDF 字节返回 null。
int? countPdfPages(Uint8List bytes) {
  if (!isPdfBytes(bytes)) return null;
  // latin1 解码：PDF 对象头为 ASCII，内容流为压缩二进制；
  // allowInvalid 容忍二进制段，对象头仍可被正则命中。
  final text = latin1.decode(bytes, allowInvalid: true);
  // 首选：页树节点 `/Type/Pages/Kids[...]/Count N`。
  final pagesNode = RegExp(
    r'/Type/Pages/Kids\[[^\]]*\]/Count\s+(\d+)',
  ).firstMatch(text);
  if (pagesNode != null) {
    final count = int.tryParse(pagesNode.group(1)!);
    if (count != null && count > 0) return count;
  }
  // 退化：数每页对象 `/Type/Page/` 出现次数。
  final pageObjects = RegExp(r'/Type/Page/').allMatches(text).length;
  if (pageObjects > 0) return pageObjects;
  return null;
}
