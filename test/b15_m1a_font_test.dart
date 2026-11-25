// 十五批 M1-A：字体加载 / 子集化测试（M1-DESIGN.md §13 验证项 1–2）。
//
// 覆盖：
// - 实例化产物可被 pdf 3.13.1 加载（`pw.Font.ttf` 不抛错）；
// - 打包 asset 可经 rootBundle 读到（pubspec assets 声明生效）；
// - 常见汉字、生僻字、全角标点、希腊字母、数学符号、中英文混排、
// 用户自定义文件夹名 / 考试名均可生成 PDF（字符均在字体 cmap 内，
// 见 ~/workspace/batch15-work/spikes/M1A-FONT-RECORD.md）；
// - 输出 PDF 的字体占用为子集量级（整份 PDF 远小于 10.6 MB 全字体；
// 精确的 FontFile2 流长度见 M1A-FONT-RECORD.md 的外部核查）。
//
// 注意：
// - 本文件不含任何公式源码；测试串均为普通中文 / 符号文字。
// - 可复制、可搜索与阅读器显示正确性用外部工具核查（pdftotext 抽取，
// 见 M1A-FONT-RECORD.md）；Windows / Android 默认阅读器与打印
// 须真机验证（M1-G / M4 清单，未在本机做）。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:quiz_master2/services/pdf_export/pdf_document_builder.dart';
import 'package:quiz_master2/services/pdf_export/pdf_font.dart';

/// 供外部核查（pdftotext / pdfinfo）留样的 PDF 写到这里。
String get _verifyDir {
final env = Platform.environment['B15_M1A_VERIFY_DIR'];
if (env != null && env.isNotEmpty) return env;
// Win11 上 HOME 未设；用系统临时目录，避免拼出相对路径 null/workspace/…。
return '${Directory.systemTemp.path}/b15-m1a-verify';
}

Future<Uint8List> _pdfWithText(
pw.Font font,
String text, {
String title = 'M1-A 字体验证',
}) async {
final builder = PdfExportDocumentBuilder(font: font);
final doc = builder.createDocument(
metadata: PdfExportMetadata(title: title),
);
doc.addPage(
pw.MultiPage(
maxPages: kPdfExportMaxPages,
pageTheme: builder.pageTheme(),
build: (pw.Context context) => <pw.Widget>[
builder.spanText(text),
],
),
);
return builder.savePdf(doc);
}

void main() {
TestWidgetsFlutterBinding.ensureInitialized();

late Uint8List fontBytes;

setUpAll(() async {
final file = File('assets/fonts/NotoSansSC-Regular.ttf');
expect(
await file.exists(),
isTrue,
reason: '字体文件须在仓库内：assets/fonts/NotoSansSC-Regular.ttf',
);
fontBytes = await file.readAsBytes();
// 实例化产物约 10.1 MiB；明显偏小说明文件损坏或被错换。
expect(fontBytes.length, greaterThan(10000000));
expect(fontBytes.length, lessThan(11000000));
});

group('字体加载', () {
test('fontFromBytes 可加载实例化后的静态 TTF', () {
expect(() => PdfExportFont.fontFromBytes(fontBytes), returnsNormally);
});

test('loadBundledFont 经 rootBundle 读到打包 asset', () async {
PdfExportFont.debugResetCache();
final font = await PdfExportFont.loadBundledFont();
expect(font, isNotNull);
// 同一进程内第二次加载命中缓存。
final again = await PdfExportFont.loadBundledFont();
expect(identical(font, again), isTrue);
});

test('OFL 许可全文随附在 assets/fonts/OFL.txt', () async {
final license = await rootBundle.loadString('assets/fonts/OFL.txt');
expect(license, contains('SIL OPEN FONT LICENSE'));
expect(license, contains('Version 1.1'));
});
});

group('字符覆盖与子集化（§13 验证项 2）', () {
late pw.Font font;

setUpAll(() async {
font = PdfExportFont.fontFromBytes(fontBytes);
});

// 每组：文本 -> PDF 字节须生成、且字体占用为子集量级
// （整份 PDF < 1 MB；完整嵌入 10.6 MB 字体时不可能这么小）。
final cases = <String, String>{
'常见汉字': '错题本 数学 高等数学 线性代数 复习 掌握 整理 收集',
'生僻字': '龘 䶮 靐',
'全角标点': '，。、；：？！（）《》—…·',
'希腊字母': 'α β γ Δ θ π Ω ∑',
'数学符号': '± × ÷ √ ∞ ≠ ≤ ≥ ∑ ∏ ∫ Δ ²',
'中英文混排': '函数 f(x)=x² 的导数是 2x，求 ΔG 与 Kp 的值。',
'自定义文件夹名': '我的高数错题',
'自定义考试名': '2026-考研（数学一）_期末_第1章',
};

for (final entry in cases.entries) {
test('${entry.key}：可生成 PDF 且字体为子集量级', () async {
final bytes = await _pdfWithText(font, entry.value);
expect(bytes.lengthInBytes, greaterThan(0));
expect(bytes.sublist(0, 5), <int>[0x25, 0x50, 0x44, 0x46, 0x2D]);
expect(
bytes.lengthInBytes,
lessThan(1000000),
reason: '子集量级：含该组文字的 PDF 应远小于 10.6 MB 全字体',
);
});
}

test('全部覆盖文本合在一份 PDF 里仍为子集量级', () async {
final all = cases.values.join('\n');
final bytes = await _pdfWithText(font, all);
expect(bytes.lengthInBytes, lessThan(1000000));

// 留样供外部核查（pdftotext 抽取：可复制、可搜索）。
final dir = Directory(_verifyDir);
await dir.create(recursive: true);
final out = File('${dir.path}/m1a-font-verify.pdf');
await out.writeAsBytes(bytes);
});
});
}
