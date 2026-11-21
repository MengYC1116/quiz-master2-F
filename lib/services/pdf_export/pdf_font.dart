// 十五批 M1-A：PDF 导出字体加载与子集化封装（M1-DESIGN.md §13）。
//
// 字体：Noto Sans SC Regular（静态 TTF），由上游 GitHub google/fonts 的
// 可变字体 NotoSansSC[wght].ttf 固定 wght=400 实例化得到；SIL OFL 1.1
// 免费许可，许可全文随附在 assets/fonts/OFL.txt。来源、转换工具版本与
// 参数、原始文件与产物的 SHA-256 见
// ~/workspace/batch15-work/spikes/M1A-FONT-RECORD.md。
//
// 使用方式：pdf 包直接读字体字节（`pw.Font.ttf`），不注册为 Flutter 字体。
// 子集化是 pdf 3.13.1 的内置行为（save() 时只嵌入用到的字形，见 pdf 包
// ttf_writer.dart），调用方无须手动子集。
// 回退 R1（M1-DESIGN.md §13）：子集化不稳 → 完整嵌入，不得回退系统字体。
// pdf 3.13.1 没有公开的“关闭子集化”开关，完整嵌入须届时另议实现方式，
// 不得静默降级为系统字体；本文件不提供假的回退开关。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pdf/widgets.dart' as pw;

/// 打包进应用的导出字体 asset 路径（pubspec.yaml assets 声明）。
const String kExportFontAssetPath = 'assets/fonts/NotoSansSC-Regular.ttf';

/// PDF 导出字体的唯一加载入口。
class PdfExportFont {
  PdfExportFont._();

  static pw.Font? _cached;

  /// 从字体字节建 pdf 字体（不依赖 asset bundle，测试与探针用）。
  static pw.Font fontFromBytes(Uint8List bytes) {
    return pw.Font.ttf(
      ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes),
    );
  }

  /// 读打包 asset 字节并建字体；结果缓存，全进程只加载一次。
  static Future<pw.Font> loadBundledFont() async {
    final cached = _cached;
    if (cached != null) return cached;
    final data = await rootBundle.load(kExportFontAssetPath);
    final font = fontFromBytes(data.buffer.asUint8List());
    _cached = font;
    return font;
  }

  static Uint8List? _cachedBytes;

  /// 读打包 asset 的原始字节（M1-E：传给生成 Isolate 建字体用；
  /// Isolate 内不能用 rootBundle，字节须由主 Isolate 传入）。
  /// 结果缓存，全进程只加载一次。
  static Future<Uint8List> loadBundledFontBytes() async {
    final cached = _cachedBytes;
    if (cached != null) return cached;
    final data = await rootBundle.load(kExportFontAssetPath);
    final bytes = data.buffer.asUint8List();
    _cachedBytes = bytes;
    return bytes;
  }

  /// 测试用：清除缓存（生产代码不调）。
  @visibleForTesting
  static void debugResetCache() {
    _cached = null;
  }
}
