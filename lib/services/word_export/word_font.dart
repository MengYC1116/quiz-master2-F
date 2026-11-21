// 十六批 C（D-193）：Word 导出字体常量与策略（WORD-DESIGN.md §3.2）。
//
// - 字体名全文统一 `Noto Sans SC`（SIL OFL 1.1 免费许可，与 M1 §13
//   同款字体文件 `assets/fonts/NotoSansSC-Regular.ttf`）。
// - 指定方式：每个 run 写 `w:rFonts w:ascii="Noto Sans SC"
//   w:hAnsi="Noto Sans SC" w:eastAsia="Noto Sans SC"`（三槽同名；
//   docx_creator 的 `DocxText(fontFamily:)` 即如此写出，见
//   `DocxFont.family`）。标题、题号、选项、来源行、页眉、页脚、答案区
//   全部走同一指定，不得有任何 run 漏掉 eastAsia（漏掉即中文回退到
//   衬线体，spike §2 的 docs_gee 教训）。
// - 默认只指名，不嵌入（D-193）：不调 `addFont()`，不生成
//   `word/fonts/*.odttf`，单文件不因此 +6.6 MB。用户机器无此字体时
//   由 Word 自身回退，文档侧不指定回退字体、不埋第二字体名。
// - 嵌入开关 v1 不做：[embedFont] 恒为 false，只留常量与注释，不接
//   UI、不读字体字节；开关打开前，`addFont` 不得被调用。
import 'package:docx_creator/docx_creator.dart';
import 'package:flutter/services.dart';

/// Word 导出全文统一字体名（Noto Sans SC，SIL OFL 1.1）。
const String kWordFontFamily = 'Noto Sans SC';

/// 字体嵌入开关（D-193：v1 不做开关、不嵌入，恒关）。
///
/// 只留常量与注释，不接 UI。以后若 Meng 批准嵌入，另立项：先解决
/// 子集化（两家库都不支持子集化，需另找工具；不子集化则每份 +6.6 MB），
/// 再由 Meng 定是否接受体积。
const bool kWordEmbedFont = false;

/// 打包的 Noto Sans SC Regular 字体 asset（只读入口，见下）。
const String kWordFontAssetPath = 'assets/fonts/NotoSansSC-Regular.ttf';

/// 读 assets 字体字节的唯一入口。
///
/// 仅当以后 Meng 批准嵌入（[kWordEmbedFont] 打开）时才走；v1 不调用。
/// 调用方须把读到的字节传给 `DocxDocumentBuilder.addFont`。
Future<Uint8List> loadWordFontBytes() =>
    rootBundle.load(kWordFontAssetPath).then((d) => d.buffer.asUint8List());

/// 一个 Word 正文 run：字体一律 [kWordFontFamily]（三槽同名由
/// docx_creator 的 `DocxFont.family` 写出），字号/加粗/颜色按需。
DocxText wordRun(
  String text, {
  required double fontSize,
  bool bold = false,
  bool italic = false,
  DocxColor? color,
}) => DocxText(
  text,
  fontSize: fontSize,
  fontFamily: kWordFontFamily,
  fontWeight: bold ? DocxFontWeight.bold : DocxFontWeight.normal,
  fontStyle: italic ? DocxFontStyle.italic : DocxFontStyle.normal,
  color: color,
);
