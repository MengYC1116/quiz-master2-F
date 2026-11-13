import 'package:flutter/material.dart';

/// quiz-master2 设计 Tokens（R1 重建，唯一事实来源）。
///
/// 值全部取自视觉基准 HTML（交互原型与完整预览的 `:root` /
/// `@media (prefers-color-scheme: dark)` 两套 token，两份文件前 70 行
/// 除标题外完全一致，已做 SHA256 交叉核对）：
/// - 交互原型 `quiz-master2-jiao-hu-yuan-xing.html`
///   SHA256 `18c8c43485a7831cec22e3d4fff659d7ea39754219b391874f0c5a88f50135e1`
/// - 完整预览 `quiz-master2-quan-xin-she-ji-yu-lan.html`
///   SHA256 `fe4a8e2630cc122f2587a4f147f6fb00f41b00874356692f1b1da1122a69fe86`
///
/// 约定：
/// - 亮/深各一套 [AppPalette]，颜色只从这里取，不在页面里写死色值。
/// - 学科色与封面色是两套独立取值（D6），不要合并：
///   学科色见 [DesignTokens.subjectColor]（圆点 / 数字 / 标签用），
///   封面色见 [CoverTokens]（错题本封面 7 预设色）。
/// - 字号缩放（D4）：基准字号见 [DesignTokens] 的字体常量；字号本身只在
///   `app.dart` 的 `MediaQuery TextScaler` 处乘一次缩放因子（见
///   [FontScale]），[AppTheme] 的 `TextTheme` 一律取基准值、不再乘，
///   否则同一段文字会被缩放两次。布局类尺寸（圆角 / 间距 / 组件尺寸）
///   由 [ScaledTokens] 按同一因子缩放。
/// - 不打包字体（D2）：只声明字体栈，实际渲染以系统回退为准；
///   Win11 上的 Segoe UI / Microsoft YaHei / Georgia 效果须真机复核，
///   Linux 上不宣称已验证。
/// - 本文件只放 token，不放业务逻辑、不读数据库、不改 Schema。
class AppPalette {
  const AppPalette({
    required this.background,
    required this.surface,
    required this.surface2,
    required this.surface3,
    required this.ink,
    required this.ink2,
    required this.muted,
    required this.line,
    required this.lineStrong,
    required this.accent,
    required this.accentSoft,
    required this.accentInk,
    required this.accentText,
    required this.warnBg,
    required this.warnInk,
    required this.warnLine,
    required this.errBg,
    required this.errInk,
    required this.errLine,
    required this.infoBg,
    required this.infoInk,
    required this.keep,
    required this.merge,
    required this.cut,
    required this.paper,
    required this.paperInk,
    required this.paperLine,
    required this.paperMuted,
    required this.paperBtnBorder,
    required this.paperBtnText,
    required this.paperStar,
    required this.paperStarOn,
    required this.stem,
    required this.option,
    required this.figure,
    required this.math,
    required this.mathSoft,
    required this.mathInk,
    required this.eng,
    required this.engSoft,
    required this.engInk,
    required this.pol,
    required this.polSoft,
    required this.polInk,
    required this.other,
    required this.otherSoft,
    required this.otherInk,
    required this.badgeSelectedBg,
    required this.badgeSelectedFg,
    required this.shadow,
    required this.paperDots,
  });

  final Color background; // --bg
  final Color surface; // --surface
  final Color surface2; // --surface-2（左导航底、次级面）
  final Color surface3; // --surface-3
  final Color ink; // --ink 正文主色
  final Color ink2; // --ink-2 次级正文
  final Color muted; // --muted 说明文字
  final Color line; // --line 细分割线
  final Color lineStrong; // --line-strong 强调分割线
  final Color accent; // --accent 主色
  final Color accentSoft; // --accent-soft 主色浅底（焦点卡）
  final Color accentInk; // --accent-ink 主按钮上的文字
  final Color accentText; // --accent-text 主色文字（浅色深蓝 / 深色浅蓝）
  final Color warnBg; // --warn-bg
  final Color warnInk; // --warn-ink
  final Color warnLine; // --warn-line
  final Color errBg; // --err-bg
  final Color errInk; // --err-ink
  final Color errLine; // --err-line
  final Color infoBg; // --info-bg
  final Color infoInk; // --info-ink（HTML 无 --info-line）
  final Color keep; // --keep 修框：保留
  final Color merge; // --merge 修框：合并
  final Color cut; // --cut 修框：裁掉
  final Color paper; // --paper 打开的书的纸页（深色下仍是浅灰纸）
  final Color paperInk; // --paper-ink 纸面上的字
  final Color paperLine; // --paper-line 纸面线
  // 纸面次级色（HTML 错题本纸面上的固定值；纸在亮/深两套下都是浅色纸，
  // 所以亮/深取同一值）：fcount / nb-paper-empty 说明文字 #5C6675；
  // 目录行内操作按钮 .tbtn 边 #B9AE8E / 字 #3D4438；
  // 紧凑行收藏星 .nb-prow .nb-star #B9C2CE / 已收藏 #E8A13A。
  final Color paperMuted;
  final Color paperBtnBorder;
  final Color paperBtnText;
  final Color paperStar;
  final Color paperStarOn;
  final Color stem; // --stem 题干区
  final Color option; // --option 选项区
  final Color figure; // --figure 配图区
  final Color math; // --math 学科色·数学（圆点 / 数字 / 标签）
  final Color mathSoft; // --math-soft
  final Color mathInk; // --math-ink 深色下标签文字用此色
  final Color eng; // --eng 学科色·英语
  final Color engSoft; // --eng-soft
  final Color engInk; // --eng-ink
  final Color pol; // --pol 学科色·政治
  final Color polSoft; // --pol-soft
  final Color polInk; // --pol-ink
  final Color other; // --other 其他学科（预留，当前三科不用）
  final Color otherSoft; // --other-soft
  final Color otherInk; // --other-ink
  // 导航角标在选中态下的底色 / 字色（HTML `.side nav button[aria-current
  // ="page"] .bdg`）：亮色 #FFFFFF / #175CD3，深色 #D5DBE4 / #33465A。
  final Color badgeSelectedBg;
  final Color badgeSelectedFg;
  final List<BoxShadow> shadow; // --shadow
  final Color paperDots; // 纸纹微点（HTML body 背景点纹的近似色）
}

/// 字体缩放档位（D4）：标准 1.00 / 大 1.15 / 特大 1.30。
/// 唯一映射入口是 [FontScale.factorFor] 与 `AppSettings.fontScale`
///（`lib/models/models.dart`），两处必须保持一致；不要在别处再写
/// 1.12 / 1.25 之类的旧值，也不要用整页 `Transform.scale`。
class FontScale {
  static const double standard = 1.0;
  static const double large = 1.15;
  static const double extraLarge = 1.3;

  /// 设置存储值（`AppSettings.fontSize`：standard / large / extraLarge）
  /// → 缩放因子；未知值回落到标准。
  static double factorFor(String fontSizeKey) => switch (fontSizeKey) {
    'large' => large,
    'extraLarge' => extraLarge,
    _ => standard,
  };
}

/// 按缩放因子换算后的布局类 token（圆角 / 间距 / 组件尺寸 / 布局宽）。
/// 字号不在这里乘——字号由 `app.dart` 的 `MediaQuery TextScaler`
/// 全局乘一次；这里只负责 `TextScaler` 够不到的布局尺寸。
/// 用法：`DesignTokens.scaled(scale).radius`。
class ScaledTokens {
  const ScaledTokens(this.scale);
  final double scale;

  double s(double base) => base * scale;

  double get radius => DesignTokens.radius * scale;
  double get radiusLg => DesignTokens.radiusLg * scale;
  double get buttonRadius => DesignTokens.buttonRadius * scale;
  double get navWidth => DesignTokens.navWidth * scale;
  double get navCollapsedWidth => DesignTokens.navCollapsedWidth * scale;
  EdgeInsets get contentPadding => EdgeInsets.fromLTRB(
    DesignTokens.contentPaddingHorizontal * scale,
    DesignTokens.contentPaddingVertical * scale,
    DesignTokens.contentPaddingHorizontal * scale,
    DesignTokens.contentPaddingVertical * scale,
  );
  double get spaceXs => DesignTokens.spaceXs * scale;
  double get spaceSm => DesignTokens.spaceSm * scale;
  double get spaceMd => DesignTokens.spaceMd * scale;
  double get spaceLg => DesignTokens.spaceLg * scale;
  double get spaceXl => DesignTokens.spaceXl * scale;
}

class DesignTokens {
  // ---------------------------------------------------------------- 亮色 --
  static const AppPalette light = AppPalette(
    background: Color(0xFFFDF8EC),
    surface: Color(0xFFFFFEF9),
    surface2: Color(0xFFFDF3D8),
    surface3: Color(0xFFF3E9C8),
    ink: Color(0xFF17233B),
    ink2: Color(0xFF3D4E6B),
    muted: Color(0xFF5F718E),
    line: Color(0xFFE8DFC2),
    lineStrong: Color(0xFFCFC39E),
    accent: Color(0xFF2E7CF6),
    accentSoft: Color(0xFFE1EDFF),
    accentInk: Color(0xFFFFFFFF),
    accentText: Color(0xFF175CD3),
    warnBg: Color(0xFFFFF3D1),
    warnInk: Color(0xFF8A5A00),
    warnLine: Color(0xFFF0D488),
    errBg: Color(0xFFFFE9E5),
    errInk: Color(0xFFB42318),
    errLine: Color(0xFFF5B8AE),
    infoBg: Color(0xFFE1EDFF),
    infoInk: Color(0xFF175CD3),
    keep: Color(0xFF0E9F6E),
    merge: Color(0xFFB97A0A),
    cut: Color(0xFFD93A2B),
    paper: Color(0xFFFFFDF4),
    paperInk: Color(0xFF22251F),
    paperLine: Color(0xFFE3D9BE),
    paperMuted: Color(0xFF5C6675),
    paperBtnBorder: Color(0xFFB9AE8E),
    paperBtnText: Color(0xFF3D4438),
    paperStar: Color(0xFFB9C2CE),
    paperStarOn: Color(0xFFE8A13A),
    stem: Color(0xFF2E7CF6),
    option: Color(0xFF00A884),
    figure: Color(0xFFF97316),
    math: Color(0xFF2E7CF6),
    mathSoft: Color(0xFFE1EDFF),
    mathInk: Color(0xFF175CD3),
    eng: Color(0xFF00A884),
    engSoft: Color(0xFFD8F5EB),
    engInk: Color(0xFF00755E),
    pol: Color(0xFFEF4444),
    polSoft: Color(0xFFFFE7E2),
    polInk: Color(0xFFC03225),
    other: Color(0xFF64748F),
    otherSoft: Color(0xFFE8EDF5),
    otherInk: Color(0xFF47556B),
    badgeSelectedBg: Color(0xFFFFFFFF),
    badgeSelectedFg: Color(0xFF175CD3),
    shadow: [
      BoxShadow(
        offset: Offset(0, 2),
        blurRadius: 6,
        color: Color.fromRGBO(23, 35, 59, 0.05),
      ),
      BoxShadow(
        offset: Offset(0, 14),
        blurRadius: 34,
        color: Color.fromRGBO(23, 35, 59, 0.09),
      ),
    ],
    paperDots: Color.fromRGBO(180, 160, 90, 0.07),
  );

  // ---------------------------------------------------------------- 深色 --
  // 深色纸面 --paper #D8DCE2（负责人已确认：深色下打开的书仍是浅灰纸页，
  // 不是代码旧值 #262B33）；深色主色 --accent #7FA8D0，主按钮文字
  // --accent-ink #131A24（深字），导航选中与强调元素统一用 #7FA8D0 体系。
  static const AppPalette dark = AppPalette(
    background: Color(0xFF1E2228),
    surface: Color(0xFF262B33),
    surface2: Color(0xFF21262E),
    surface3: Color(0xFF333A45),
    ink: Color(0xFFE9EDF3),
    ink2: Color(0xFFC6CEDA),
    muted: Color(0xFF97A2B2),
    line: Color(0xFF333B47),
    lineStrong: Color(0xFF485364),
    accent: Color(0xFF7FA8D0),
    accentSoft: Color(0xFF2C3949),
    accentInk: Color(0xFF131A24),
    accentText: Color(0xFFA9C6E4),
    warnBg: Color(0xFF32342C),
    warnInk: Color(0xFFCFC488),
    warnLine: Color(0xFF55563F),
    errBg: Color(0xFF352C31),
    errInk: Color(0xFFD2A3AC),
    errLine: Color(0xFF59424A),
    infoBg: Color(0xFF2C3949),
    infoInk: Color(0xFFA9C6E4),
    keep: Color(0xFF8FB8A4),
    merge: Color(0xFFB4AC8E),
    cut: Color(0xFFC08A94),
    paper: Color(0xFFD8DCE2),
    paperInk: Color(0xFF232830),
    paperLine: Color(0xFFAEB6C2),
    paperMuted: Color(0xFF5C6675),
    paperBtnBorder: Color(0xFFB9AE8E),
    paperBtnText: Color(0xFF3D4438),
    paperStar: Color(0xFFB9C2CE),
    paperStarOn: Color(0xFFE8A13A),
    stem: Color(0xFF7FA8D0),
    option: Color(0xFF8FB8A4),
    figure: Color(0xFFA79BC0),
    math: Color(0xFF87A9CC),
    mathSoft: Color(0xFF262B33),
    mathInk: Color(0xFFACC8E2),
    eng: Color(0xFF8AB5A3),
    engSoft: Color(0xFF262B33),
    engInk: Color(0xFFAFD2C2),
    pol: Color(0xFFC295A5),
    polSoft: Color(0xFF262B33),
    polInk: Color(0xFFD8B4C0),
    other: Color(0xFF9AA5B3),
    otherSoft: Color(0xFF262B33),
    otherInk: Color(0xFFC3CBD6),
    badgeSelectedBg: Color(0xFFD5DBE4),
    badgeSelectedFg: Color(0xFF33465A),
    shadow: [
      BoxShadow(
        offset: Offset(0, 2),
        blurRadius: 6,
        color: Color.fromRGBO(0, 0, 0, 0.35),
      ),
      BoxShadow(
        offset: Offset(0, 14),
        blurRadius: 34,
        color: Color.fromRGBO(0, 0, 0, 0.30),
      ),
    ],
    paperDots: Color.fromRGBO(160, 180, 205, 0.03),
  );

  static AppPalette of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  // ------------------------------------------------------------ 学科色 --
  // 只用在圆点 / 数字 / 标签上，不出现大块亮色（深色下尤其如此）。
  // 亮色 = 学科本色；深色 = 冷雾色（--math/--eng/--pol）。
  // 标签文字在深色下用更亮的 --*-ink（见 [subjectInk]），与 HTML
  // `.subj-label` 的深色规则一致。
  //
  // [stored] 是库里存的学科色（`Subject.color`，新学科由
  // `_newSubjectColors` 轮换产生）。预设三科（math/english/
  // politics）忽略它，仍走主题感知的固定色（深色下是雾色版）；
  // 新学科没有预设项，直接用库里存的轮换色——v2 基线圆点就是
  // 直接用 s.color。R1 改成按 id 查表后，新学科永远落到默认分支
  // （数学蓝），轮换表写了库却不显示；2026-11-13 修回（见
  // S8A2-SUBJECT-COLORS-REPORT.md）。
  static Color subjectColor(String subjectId, Brightness brightness,
      [Color? stored]) {
    if (stored != null &&
        subjectId != 'math' &&
        subjectId != 'english' &&
        subjectId != 'politics') {
      return stored;
    }
    final p = of(brightness);
    return switch (subjectId) {
      'english' => p.eng,
      'politics' => p.pol,
      _ => p.math,
    };
  }

  // [stored] 与 [subjectColor] 同理：预设三科忽略它，仍走主题感知的
  // 固定色；新学科没有预设项，直接用库里存的轮换色作标题色
  //（S8A2 圆点已是此做法；B2 把首页的标题色 / 底色一并补上）。
  static Color subjectInk(String subjectId, Brightness brightness,
      [Color? stored]) {
    if (stored != null &&
        subjectId != 'math' &&
        subjectId != 'english' &&
        subjectId != 'politics') {
      return stored;
    }
    final p = of(brightness);
    return switch (subjectId) {
      'english' => p.engInk,
      'politics' => p.polInk,
      _ => p.mathInk,
    };
  }

  // 底色不用存色原值（大块饱和色太刺眼），而用存色调出的淡 tint：
  // 亮色 = 白底混 12% 存色（数学蓝算出约 #E6EFFE，与 --math-soft
  // #E1EDFF 同档）；深色 = 深灰底（#262B33，三科深色 soft 本就是
  // 同一值）混 15% 存色，带一点本科的色调。预设三科仍走固定值。
  static Color subjectSoft(String subjectId, Brightness brightness,
      [Color? stored]) {
    if (stored != null &&
        subjectId != 'math' &&
        subjectId != 'english' &&
        subjectId != 'politics') {
      if (brightness == Brightness.dark) {
        return Color.lerp(const Color(0xFF262B33), stored, 0.15)!;
      }
      return Color.lerp(Colors.white, stored, 0.12)!;
    }
    final p = of(brightness);
    return switch (subjectId) {
      'english' => p.engSoft,
      'politics' => p.polSoft,
      _ => p.mathSoft,
    };
  }

  // ---------------------------------------------------------------- 字体 --
  // HTML 字体栈（D2，不打包字体）：`"Segoe UI", system-ui, -apple-system,
  // "PingFang SC", "Microsoft YaHei", sans-serif`。Flutter 里用
  // fontFamily + fontFamilyFallback 表达；`system-ui` / `-apple-system`
  // 没有对应的 Flutter 字体名，落到系统默认回退。
  static const String fontFamily = 'Segoe UI';
  static const List<String> fontFamilyFallback = [
    'Microsoft YaHei',
    'PingFang SC',
  ];

  // 衬线栈（HTML：`Georgia, "Songti SC", "SimSun", serif`），只用在
  // 纸面 / 数字需要衬线的地方；Flutter 的 fallback 不写泛型 `serif`。
  static const String serifFontFamily = 'Georgia';
  static const List<String> serifFontFamilyFallback = ['Songti SC', 'SimSun'];

  // 正文 15px / 行高 1.65（HTML body 基准）。
  static const double bodyFontSize = 15;
  static const double bodyLineHeight = 1.65;
  // 高频次级字号（HTML 实读高频值，R2 逐页核对后收紧）。
  static const double bodySmallFontSize = 13.5;
  static const double captionFontSize = 12.5;
  // 页标题 24px / 800（HTML `h2.st`、`.main h3.pt`）。
  static const double pageTitleFontSize = 24;
  static const FontWeight pageTitleFontWeight = FontWeight.w800;
  // 问候大标题 34px / 800 / 行高 1.25（HTML `.ahead h1`）。
  static const double greetingFontSize = 34;
  static const double greetingLineHeight = 1.25;
  static const FontWeight greetingFontWeight = FontWeight.w800;
  // 焦点大数字 46px / 800 / 行高 1.15（HTML `.focus-card .fc-num`）。
  static const double focusNumberFontSize = 46;
  static const double focusNumberLineHeight = 1.15;
  static const FontWeight focusNumberFontWeight = FontWeight.w800;
  // 封面竖排学科名 52px / 800 / 行高 1.15（HTML `.nb-book-name`）。
  static const double coverNameFontSize = 52;
  static const double coverNameLineHeight = 1.15;
  static const FontWeight coverNameFontWeight = FontWeight.w800;

  // ------------------------------------------- HTML 实读字号 / 间距 --
  // R2 定夺（R1-UIKIT.md §7 第 1 项）：收入 DesignTokens。理由：这些值
  // 是原型 CSS 的实读值、不是随手写的魔法数，且多组件共用（按钮 / 芯片 /
  // 药丸 / 横幅 / 折叠头 / 导航）；收进 token 后 `uikit.dart` 的私有
  // `_Html` 集中表已删除，改为直接引用此处。字号仍只写基准值，由
  // app.dart 的 MediaQuery TextScaler 全局缩放一次，组件内不乘。
  // 按钮：.btn 14px；.btn.small 13px；.org-confirm-big 17.5px。
  static const double buttonFontSize = 14;
  static const double smallButtonFontSize = 13;
  static const double largeButtonFontSize = 17.5;
  // 芯片：.chip / .fchip 13px；可删除芯片 .err-sel-chip 12.5px
  //（= captionFontSize，不重复定义）。
  static const double chipFontSize = 13;
  // 分段：.seg button 14px；横幅：.banner 14px；药丸：.pill / .status 12px。
  static const double segmentedFontSize = 14;
  static const double bannerFontSize = 14;
  static const double pillFontSize = 12;
  // 空状态标题：.empty .et 17px。
  static const double emptyTitleFontSize = 17;
  // 折叠头：.set-group-head 16.5px；.org-sec-head 14.5px。
  static const double foldGroupTitleFontSize = 16.5;
  static const double foldFormTitleFontSize = 14.5;
  // 大按钮圆角：.org-confirm-big 14px = (radius 12 + radiusLg 16) / 2。
  static const double largeButtonRadius = (radius + radiusLg) / 2;
  // 单行控件（按钮 / 芯片 / 分段段 / 折叠头）行高：HTML 里这些控件不用
  // 正文 1.65 行高，用浏览器默认 normal（≈1.2）；显式写 1.2，否则
  // Flutter 会从 DefaultTextStyle 继承 1.65，按钮比 HTML 高约 6px。
  static const double controlLineHeight = 1.2;
  // 按钮最小高：.btn 默认无 min-height，取主题 FilledButton 的 40px
  //（与 9px 内边距 + 14px 字行的实测高度一致）；小 34px；大 56px。
  static const double buttonMinHeight = 40;
  static const double smallButtonMinHeight = 34;
  static const double largeButtonMinHeight = 56;
  // 内边距：.btn 9px 20px；.btn.small 6px 14px；
  // .org-confirm-big 16px 20px；.chip 5px 14px；
  // .err-sel-chip 4px 12px；.seg button 7px 18px；
  // .banner 12px 16px；.banner button 4px 14px；
  // .pill / .status 横向 9px（纵向 1px）；.empty 52px 30px。
  static const double buttonPaddingV = 9;
  static const double buttonPaddingH = 20;
  static const double smallButtonPaddingV = 6;
  static const double smallButtonPaddingH = 14;
  static const double largeButtonPaddingV = 16;
  static const double largeButtonPaddingH = 20;
  static const double chipPaddingV = 5;
  static const double chipPaddingH = 14;
  static const double deletableChipPaddingV = 4;
  static const double deletableChipPaddingH = 12;
  static const double segmentedPaddingV = 7;
  static const double segmentedPaddingH = 18;
  static const double bannerPaddingV = 12;
  static const double bannerPaddingH = 16;
  static const double bannerButtonPaddingV = 4;
  static const double bannerButtonPaddingH = 14;
  static const double pillPaddingH = 9;
  static const double emptyPaddingV = 52;
  static const double emptyPaddingH = 30;

  // ----------------------------------------------------- 首页实读度量 --
  // R3：HTML 首页（`.main h3.pt` / `.psub` / `.focus-card` /
  // `.fc-continue` / `.secttl` / `.c-mini`）实读值。字号只写基准值，
  // 由 app.dart 的 MediaQuery TextScaler 全局缩放一次；布局尺寸
  // （内边距 / 间距）由调用方按 qmScaleOf 的同一因子乘一次。
  // 焦点卡：`.focus-card` padding 26px 28px、margin-bottom 14px、
  // kicker 13px/800、数字 46px（见 focusNumberFontSize）、
  // 明细 14.5px；继续上次条 margin-top 18px、padding-top 16px、gap 14px。
  static const double focusCardPaddingV = 26;
  static const double focusCardPaddingH = 28;
  static const double focusCardMarginBottom = 14;
  static const double focusKickerFontSize = 13;
  static const double focusDetailFontSize = 14.5;
  static const double focusContinueMarginTop = 18;
  static const double focusContinuePaddingTop = 16;
  static const double focusContinueGap = 14;
  // 空状态焦点卡数字：`.focus-card.no-due .fc-num` 28px。
  static const double noDueNumberFontSize = 28;
  // 问候副标题：`.main .psub` margin 3px 0 20px（上 3 / 下 20）。
  static const double homeSubtitleMarginBottom = 20;
  // 分区小标题：`.secttl` 13px/700。
  static const double homeSectionTitleFontSize = 13;
  // 下方四格：`.c-mini` padding 14px 16px；`.c-bottom` gap 12px。
  static const double miniPaddingV = 14;
  static const double miniPaddingH = 16;
  static const double miniGap = 12;

  // ------------------------------------------------- 收集中心实读度量 --
  // R4：HTML 收集中心（`.drop` / `.task-scroll` / `.secttl` /
  // `.rowline` / `.frameedit.frame-overlay` / `.page-thumb`）实读值。
  // 字号只写基准值，由 app.dart 的 MediaQuery TextScaler 全局缩放一次；
  // 布局尺寸（内边距 / 间距）由调用方按 qmScaleOf 的同一因子乘一次。
  // 拖放区：`.drop` padding 30px、标题 17px/800、虚线框 2px accent。
  static const double collectDropPadding = 30;
  static const double collectDropTitleFontSize = 17;
  // 任务列表：`.task-scroll` 高 408px（桌面宽基准；HTML 另有 900/560
  // 断点下的 380/360px，Flutter 桌面目标取 408px）；行 `.rowline`
  // padding 14px 6px；分区标题 `.secttl` margin 22px 0 4px（与首页
  // homeSectionTitleFontSize 同值 13px/700，不重复定义）。
  static const double collectTaskScrollHeight = 408;
  static const double collectTaskRowPaddingV = 14;
  static const double collectTaskRowPaddingH = 6;
  // 修框编辑器：`.frameedit.frame-overlay` 高 648px；页缩略图
  // `.page-thumb` 宽 62px、图高 34px；画布基准 560×700（题页竖版，
  // 滚轮缩放改的是画布布局尺寸，不用 Transform.scale）。
  static const double collectEditorDialogWidth = 860;
  static const double collectEditorDialogHeight = 648;
  static const double collectEditorThumbWidth = 62;
  static const double collectEditorThumbHeight = 34;
  static const double collectEditorCanvasWidth = 560;
  static const double collectEditorCanvasHeight = 700;

  // ------------------------------------------------- 整理工作台实读度量 --
  // R5：HTML 整理工作台（`.org-grid` / `.org-topbar` / `.org-queue-pop` /
  // `.org-queue-scroll` / `.qitem` / `.slice-card` / `.missing-line` /
  // `.work-acts` / `.org-confirm-bar` / `.org-zoom-stage`）实读值。
  // 字号只写基准值，由 app.dart 的 MediaQuery TextScaler 全局缩放一次；
  // 布局尺寸由调用方按 qmScaleOf 的同一因子乘一次。
  // H 布局：`.org-grid` 两等列、gap 22px；窗口宽 ≤1102px 时单列
  //（`@media (max-width:1102px)`，按窗口宽判断，不按内容区宽）。
  static const double organizeGridGap = 22;
  static const double organizeGridBreakpoint = 1102;
  // 顶栏：`.org-topbar` margin-bottom 14px、gap 12px；队列按钮 15px、
  // padding 9px 18px；计数 pill 12.5px/800、行高 22px。
  static const double organizeTopbarMarginBottom = 14;
  static const double organizeQueueButtonFontSize = 15;
  static const double organizeQueueCountFontSize = 12.5;
  // 队列弹出层：`.org-queue-pop` 宽 min(720px, 100vw-32px)、顶距 54px、
  // padding 14px、radius 16px；列表 `.org-queue-scroll` 高上限
  // min(52vh, 480px)；行 `.qitem` 内边距 3px 10px、标题行最小高 36px。
  static const double organizeQueuePopWidth = 720;
  static const double organizeQueuePopTop = 54;
  static const double organizeQueueScrollMaxHeight = 480;
  // 表单段：`.org-sec` margin-top 14px；待补充行 `.missing-line`
  // 12.5px、padding 7px 11px、radius 10px；字段 label 12.5px/700、
  // 说明 `.ph` 12.5px；操作行 `.work-acts` margin-top 22px、
  // padding-top 18px；确认条 `.org-confirm-bar` margin-top 20px、
  // padding-top 18px、2px 顶边；确认说明 12.5px 居中、margin-top 8px。
  static const double organizeSectionGap = 14;
  static const double organizeFieldFontSize = 12.5;
  static const double organizeWorkActsMarginTop = 22;
  static const double organizeConfirmBarMarginTop = 20;
  // 切片卡：`.slice-card` padding 8px 10px、radius 10px；卡头 11px/700；
  // 卡体 Georgia 衬线 12.5px、行高 1.55、上限 66px；整题图限高 480px。
  static const double organizeSliceBodyMaxHeight = 66;
  static const double organizePaperMaxHeight = 480;
  // 放大浮层：`.org-zoom-stage` 宽 min(940px, 94vw)、高 min(84vh, 780px)；
  // Flutter 桌面目标取 900×600（1280×720 窗口内 84vh ≈ 605px）。
  static const double organizeZoomWidth = 900;
  static const double organizeZoomHeight = 600;

  // --------------------------------------------------- 错题本实读度量 --
  // R6：HTML 错题本（`.nb-shelf` / `.nb-book` / `.nb-open` /
  // `.nb-book-inner` / `.nb-paper` / `.nb-toc-row` / `.nb-cards` /
  // `.nb-cards-scroll` / `.nb-seq` / `.nb-filter-panel` / `.nb-fcell` /
  // `.nb-prow` / `.nb-thumb64` / `.nb-pager` / `.nb-batchbar` /
  // `.nb-toc-selbar`）实读值。字号只写基准值，由 app.dart 的
  // MediaQuery TextScaler 全局缩放一次；布局尺寸由调用方按 qmScaleOf
  // 的同一因子乘一次。
  // 书架：`.nb-shelf` 3 列、gap 22px；书 `.nb-book` 最小高 376px、
  // padding 34px 18px 20px、圆角 6px 12px 12px 6px；书脊宽 11px；
  // 折角 34px；英文名 12px/600、字距 .34em、上边距 26px；
  // 学科名 52px/800（见 coverNameFontSize）、字距 .06em；
  // 「错 题 本」16px、字距 .85em、上边距 8px；
  // 计数牌数字 21px/800、标签 12px、padding 10px 4px、圆角 12px；
  // 封面内「开始复习」15px/800、padding 9px 0、圆角 12px、上边距 10px；
  // 书架分页器上边距 16px。
  static const double shelfGridGap = 22;
  static const double bookMinHeight = 376;
  static const double bookPaddingTop = 34;
  static const double bookPaddingH = 18;
  static const double bookPaddingBottom = 20;
  static const double bookSpineWidth = 11;
  static const double bookFoldSize = 34;
  static const double coverEnFontSize = 12;
  static const double coverSubFontSize = 16;
  static const double coverCountsNumberFontSize = 21;
  static const double coverCountsLabelFontSize = 12;
  static const double coverRevFontSize = 15;
  static const double shelfPagerMarginTop = 16;
  // 打开的书：`.nb-open` padding 12px、圆角 12px；
  // `.nb-book-inner` surface 底、圆角 12px、padding 14px 16px 16px。
  static const double openPadding = 12;
  static const double bookInnerPaddingV = 14;
  static const double bookInnerPaddingH = 16;
  static const double bookInnerPaddingBottom = 16;
  // 目录行：`.nb-toc-row` 最小高 52px、padding 13px 6px 13px 22px；
  // 文件夹名 15.5px/700、题数 13.5px/700；展开块宽 38px；
  // 子文件夹行最小高 46px、名 14.5px/600、左缩进 38px；
  // 拖拽柄宽 30px、最小高 34px。
  static const double tocRowMinHeight = 52;
  static const double tocRowPaddingV = 13;
  static const double tocRowPaddingH = 6;
  static const double tocRowPaddingLeft = 22;
  static const double tocRowNameFontSize = 15.5;
  static const double tocCountFontSize = 13.5;
  static const double tocExpandWidth = 38;
  static const double tocChildRowMinHeight = 46;
  static const double tocChildNameFontSize = 14.5;
  static const double tocKidsIndent = 38;
  static const double tocDragWidth = 30;
  // 大卡片：`.nb-cards` gap 20px；滚动容器 `.nb-cards-scroll`
  // 高 466px、padding 12px、圆角 12px；序号圆盘 `.nb-seq`
  // 最小宽 30px、高 30px、14px/800；批量复选框左偏移 48px。
  static const double cardsGap = 20;
  static const double cardsScrollHeight = 466;
  static const double cardsScrollPadding = 12;
  static const double seqBadgeSize = 30;
  static const double seqBadgeFontSize = 14;
  static const double cardCheckLeft = 48;
  // 筛选面板：`.nb-filter-panel` padding 14px 16px、下边距 14px；
  // `.nb-fgrid` 每格最小宽 168px、gap 10px 14px；
  // `.nb-fcell` 标签 12.5px/700；`.nb-option-row` 标签列宽 38px、
  // 最小高 36px；下拉 `.nb-fsel` 最小高 36px、13.5px。
  static const double filterPanelPaddingV = 14;
  static const double filterPanelPaddingH = 16;
  static const double filterCellMinWidth = 168;
  static const double filterCellLabelFontSize = 12.5;
  static const double filterRowLabelWidth = 38;
  static const double filterRowMinHeight = 36;
  static const double filterSelectFontSize = 13.5;
  // 紧凑行：`.nb-prow` padding 10px 6px 10px 22px、gap 12px；
  // 标题 15px/700、明细 12.5px；缩略图 `.nb-thumb64` 64×48px；
  // 收藏星 `.nb-star` 19px。
  static const double prowPaddingV = 10;
  static const double prowPaddingH = 6;
  static const double prowPaddingLeft = 22;
  static const double prowTitleFontSize = 15;
  static const double prowDetailFontSize = 12.5;
  static const double thumbWidth = 64;
  static const double thumbHeight = 48;
  static const double prowStarFontSize = 19;
  // 分页器：`.nb-pager` 上边距 14px、顶边距 12px、13.5px；
  // 页码钮 `.pgnum` 最小宽 38px、padding 6px 10px。
  static const double pagerMarginTop = 14;
  static const double pagerPaddingTop = 12;
  static const double pagerFontSize = 13.5;
  static const double pageNumMinWidth = 38;

  // ------------------------------------------------- 题目详情实读度量 --
  // R7：HTML 题目详情（`.dt-fold` / `.dt-star` / `.dt-miss` /
  // `.field label` / `.form-grid` / `.work-acts` / `.confirmbox` /
  // `.dt-revlog` / `.flip-hint`）实读值。字号只写基准值，由 app.dart
  // 的 MediaQuery TextScaler 全局缩放一次；布局尺寸由调用方按
  // qmScaleOf 的同一因子乘一次。
  // 内容宽上限：1280 窗口 − 左导航 216 − 内容区左右 padding 30×2
  //（详情页经 Navigator.push 全窗显示，无左导航；上限 1004 使正文宽
  // 与 HTML `.main` 内容宽一致）。
  static const double detailContentMaxWidth = 1004;
  // 收藏星：`.dt-star` 23px；字段 label：`.field label` 12.5px/700；
  // 字段值：`.dtVal` 14.5px。
  static const double detailStarFontSize = 23;
  static const double detailFieldLabelFontSize = 12.5;
  static const double detailFieldValueFontSize = 14.5;
  // 表单两列网格：`.form-grid` gap 14px 20px。
  static const double detailFormGridGapV = 14;
  static const double detailFormGridGapH = 20;
  // 底部操作行：`.work-acts` margin-top 22px、padding-top 18px。
  static const double detailWorkActsMarginTop = 22;
  static const double detailWorkActsPaddingTop = 18;
  // 图下提示：`.flip-hint` 12px；解决记录行：`.dt-revlog` 13px；
  // 折叠段间距：`.dt-fold` margin-top 14px；确认框：
  // `.confirmbox` padding 12px 14px、14px 字（字号复用 bannerFontSize）。
  static const double detailHintFontSize = 12;
  static const double detailRevLogFontSize = 13;
  static const double detailSectionGap = 14;
  static const double detailConfirmPaddingV = 12;
  static const double detailConfirmPaddingH = 14;

  // --------------------------------------------------- 复习实读度量 --
  // R8：HTML 复习页（`.rev-wrap` / `.rev-meta` / `.rev-steps` /
  // `.cause-row` / `.rev-pend-head` / `.duelist` / `.detailbox` /
  // `.kv` / `.rev-acts` / `.flip-hint` / `#r2-remedy`）实读值。字号只
  // 写基准值，由 app.dart 的 MediaQuery TextScaler 全局缩放一次；
  // 布局尺寸由调用方按 qmScaleOf 的同一因子乘一次。
  // 内容宽上限：`.rev-wrap` 行内 `max-width:760px`（CSS 里的 640px
  // 被行内样式覆盖，以行内 760 为准），居中。
  static const double reviewContentMaxWidth = 760;
  // 元信息行：`.rev-meta` 13px muted、gap 8、下边距 12。
  static const double reviewMetaFontSize = 13;
  // 四步指示：`.rev-steps .stp` 12.5px/700、padding 4px 12px、gap 6、
  // 下边距 12。
  static const double reviewStepFontSize = 12.5;
  // 待解决分组头：`.rev-pend-head` 12.5px/700、字距 .06em、padding
  // 2px 14px 4px；分组行 `.cause-row` padding 10px 14px、13.5px。
  static const double reviewPendHeadFontSize = 12.5;
  static const double reviewRowPaddingV = 10;
  static const double reviewRowPaddingH = 14;
  // 已解决分组：`.duelist` 下边距 16；头 `.dh` 12.5px/700、字距 .06em、
  // padding 9px 14px；行 `.due` padding 9px 14px、13.5px。
  static const double reviewCuredMarginBottom = 16;
  static const double reviewCuredHeadPaddingV = 9;
  // 详情盒：`.detailbox` padding 16、下边距 14；键值行 `.kv` 13.5px、
  // padding 5px 0、标签列最小宽 76px。
  static const double reviewDetailPadding = 16;
  static const double reviewKvLabelWidth = 76;
  // 操作行：`.rev-acts` margin-top 16、gap 10、居中。
  static const double reviewActsMarginTop = 16;
  static const double reviewActsGap = 10;
  // 补救输入：`#r2-remedy` 14px、padding 10px 12px、圆角 12。
  static const double reviewRemedyFontSize = 14;

  // ------------------------------------------------- 学习报告实读度量 --
  // R9：HTML 学习报告（`.rpt-bar` / `.rpt-core` / `.rpt-num` /
  // `.rpt-sug` / `.rpt-row` / `.rpt-more` / `.cols2` / `.secttl` /
  // `.rowline`）实读值。字号只写基准值，由 app.dart 的 MediaQuery
  // TextScaler 全局缩放一次；布局尺寸由调用方按 qmScaleOf 的同一因子乘一次。
  // 分区小标题：`.secttl` 13px/700、margin 22px 0 4px（字距沿用 R3/R4
  // 的 `letterSpacing: 0.08` 写法，与首页/收集页一致）。
  static const double reportSectionMarginTop = 22;
  static const double reportSectionMarginBottom = 4;
  // 时间范围条：`.rpt-bar` gap 12、margin-bottom 4；范围说明
  // `.rpt-range-note` 13px muted。
  static const double reportRangeBarGap = 12;
  static const double reportRangeBarMarginBottom = 4;
  static const double reportRangeNoteFontSize = 13;
  // 核心数条：`.rpt-core` margin-top 16、上边 2px line、下边 1px line；
  // `.rpt-num` padding 14px 16px 12px、格间 1px line 左边；
  // 数字 30px/800/行高 1.15、标签 14px/700、小字 12.5px muted/行高 1.5。
  static const double reportCoreMarginTop = 16;
  static const double reportCorePaddingTop = 14;
  static const double reportCorePaddingH = 16;
  static const double reportCorePaddingBottom = 12;
  static const double reportCoreNumberFontSize = 30;
  static const double reportCoreNumberLineHeight = 1.15;
  static const double reportCoreLabelFontSize = 14;
  static const double reportCoreSmallFontSize = 12.5;
  // 建议句：`.rpt-sug` margin-top 18、gap 10、15px；标签 800。
  static const double reportSuggestMarginTop = 18;
  static const double reportSuggestGap = 10;
  static const double reportSuggestFontSize = 15;
  // 弱点行：`.rpt-row` padding 10px 6px、最小高 44、下边 1px line；
  // 序号圆 `.rk` 26px、13px/800、accent-soft 底 / accent-text 字；
  // 标题 `.t` 14.5px/700、明细 `.d` 12.5px muted（单行省略）；
  // 计数 `.cnt` 800；两列 `.cols2` gap 34、窗口宽 ≤1102px 时单列
  //（与整理工作台共用 `organizeGridBreakpoint` 同一断点值）。
  static const double reportRowMinHeight = 44;
  static const double reportRowPaddingV = 10;
  static const double reportRowPaddingH = 6;
  static const double reportRankSize = 26;
  static const double reportRankFontSize = 13;
  static const double reportRowTitleFontSize = 14.5;
  static const double reportRowDetailFontSize = 12.5;
  static const double reportTwoColGap = 34;
  // “看更多”：`.rpt-more` margin-top 10。
  static const double reportMoreMarginTop = 10;
  // 弱点空行：行内 `font-size:14px`。
  static const double reportWeakEmptyFontSize = 14;
  // 学科分布行：`.rowline` padding 14px 6px、下边 1px line（末行无）；
  // `.t` 15px/700（字号复用 bodyFontSize）。
  static const double reportDistRowPaddingV = 14;
  static const double reportDistRowPaddingH = 6;

  // ------------------------------------------------- 左导航实读度量 --
  // HTML `.side` / `.side nav button` / `.side-foot` 实读值。
  // 品牌：.brand 17px/800；副标题 small 11.5px。
  static const double navBrandFontSize = 17;
  static const double navBrandSubFontSize = 11.5;
  // 导航项：14.5px/600（选中 700）；角标 11.5px/700，
  // 最小宽 22px、高 20px；项内边距 10px 12px；外壳内边距 16px 12px。
  static const double navItemFontSize = 14.5;
  static const double navBadgeFontSize = 11.5;
  static const double navBadgeMinWidth = 22;
  static const double navBadgeHeight = 20;
  static const double navItemPaddingV = 10;
  static const double navItemPaddingH = 12;
  static const double navPaddingV = 16;
  static const double navPaddingH = 12;
  // 学科速览：.subj 标题 12px/700；.subjrow 13.5px，内边距 7px 10px；
  // 圆点 .sdot 10px。
  static const double navSectionFontSize = 12;
  static const double subjRowFontSize = 13.5;
  static const double subjRowPaddingV = 7;
  static const double subjRowPaddingH = 10;
  static const double subjDotSize = 10;

  /// 基准 TextTheme（字号一律取基准值，不乘缩放因子；缩放只由
  /// `app.dart` 的 `MediaQuery TextScaler` 全局做一次）。
  static TextTheme textTheme(AppPalette p) => TextTheme(
    displayLarge: TextStyle(
      fontSize: focusNumberFontSize,
      height: focusNumberLineHeight,
      fontWeight: focusNumberFontWeight,
      color: p.ink,
    ),
    headlineMedium: TextStyle(
      fontSize: greetingFontSize,
      height: greetingLineHeight,
      fontWeight: greetingFontWeight,
      color: p.ink,
    ),
    titleLarge: TextStyle(
      fontSize: pageTitleFontSize,
      fontWeight: pageTitleFontWeight,
      color: p.ink,
    ),
    bodyLarge: TextStyle(
      fontSize: bodyFontSize,
      height: bodyLineHeight,
      color: p.ink,
    ),
    bodyMedium: TextStyle(
      fontSize: bodyFontSize,
      height: bodyLineHeight,
      color: p.ink,
    ),
    bodySmall: TextStyle(fontSize: bodySmallFontSize, color: p.muted),
    labelSmall: TextStyle(fontSize: captionFontSize, color: p.muted),
  );

  // ---------------------------------------------------------------- 圆角 --
  static const double radius = 12; // --radius
  static const double radiusLg = 16; // --radius-lg
  static const double buttonRadius = 10; // 代码现有按钮圆角（HTML 无 :root 项）

  // ---------------------------------------------------------------- 间距 --
  // 内容区 padding（HTML 外壳：`padding:26px 30px`）。
  static const double contentPaddingVertical = 26;
  static const double contentPaddingHorizontal = 30;
  static const EdgeInsets contentPadding = EdgeInsets.fromLTRB(
    contentPaddingHorizontal,
    contentPaddingVertical,
    contentPaddingHorizontal,
    contentPaddingVertical,
  );
  static const double spaceXs = 4;
  static const double spaceSm = 8;
  static const double spaceMd = 12;
  static const double spaceLg = 16;
  static const double spaceXl = 24;

  // ---------------------------------------------------------------- 布局 --
  static const double navWidth =
      216; // 左导航宽（HTML `grid-template-columns:216px 1fr`）
  static const double navCollapsedWidth = 64; // 折叠后仅图标

  static ScaledTokens scaled(double scale) => ScaledTokens(scale);
}

/// 错题本封面色（D6，与学科色分离的独立取值）。
///
/// 7 预设色（HTML 附录 A / 学科管理封面块，R0 §4）：
/// 蓝 #2F7CF6 / 绿 #1F9D66 / 红 #E0524D / 紫 #7C4DDB / 橙 #ED7D31 /
/// 黄 #D9A404 / 灰 #64748F。
/// 注意封面蓝 #2F7CF6 与学科蓝 #2E7CF6 不是同一个值，不要合并。
/// 只做表现层取值；存储仍是 subjects 表的 `cover_color` 字段（不改 Schema）。
/// `lib/models/models.dart` 的 `CoverColors.hex` 与此处保持一致。
class CoverTokens {
  static const Map<String, Color> colors = {
    'blue': Color(0xFF2F7CF6),
    'green': Color(0xFF1F9D66),
    'red': Color(0xFFE0524D),
    'purple': Color(0xFF7C4DDB),
    'orange': Color(0xFFED7D31),
    'yellow': Color(0xFFD9A404),
    'grey': Color(0xFF64748F),
  };

  static const List<String> all = [
    'blue',
    'green',
    'red',
    'purple',
    'orange',
    'yellow',
    'grey',
  ];

  static Color of(String key) => colors[key] ?? colors['blue']!;

  /// 封面 6 样式（key 与 `CoverStyles.all` 一致；中文名见 models 层）。
  static const List<String> styles = [
    'plain',
    'lines',
    'dots',
    'grid',
    'diagonal',
    'double',
  ];
}

// ------------------------------------------------- 学科管理 / 设置实读度量 --
// R10：HTML 学科管理（`.subj-list-row` / `.cover-mini` / `.cover-pick` /
// `.cover-swatch` / `.kp-chrow` / `.mgrow`）与设置（`.set-grid` /
// `.set-group-head` / `.seg` / `.kv` / `.confirmbox` / `.toolbar input`）
// 实读值。字号只写基准值，由 app.dart 的 MediaQuery TextScaler 全局缩放
// 一次；布局尺寸由调用方按 qmScaleOf 的同一因子乘一次。
// 注意：HTML 封面样式 key 是 plain/bands/dots/grid/diag/frame，Flutter
// 存储 key 是 plain/lines/dots/grid/diagonal/double（与错题本
// `_CoverPatternPainter` 一致）；标签中文相同，不改存储值。
abstract final class R10Tokens {
  // 学科行：`.subj-list-row .grow b` 15px；色点 `.subj-dot` 14px；
  // 行 `.mgrow` padding 7px 0、虚线底边、gap 8。
  static const double subjectRowPaddingV = 7;
  static const double subjectDotSize = 14;
  static const double subjectNameFontSize = 15;
  static const double subjectCountFontSize = 13.5;
  // 封面小图：`.cover-mini` 52×68、字 19px/800、圆角 4 8 8 4；
  // 样式签 `.cp-label` 12px/700；色块 `.cover-swatch` 20px；
  // 选中签 `.cover-pick[aria-pressed]` 2px accent 边 + accent-soft 底。
  static const double coverMiniWidth = 52;
  static const double coverMiniHeight = 68;
  static const double coverMiniCharFontSize = 19;
  static const double coverPickLabelFontSize = 12;
  static const double coverSwatchSize = 20;
  static const double coverColorDotSize = 28;
  // 知识点树：章节行名 15px/700、知识点行 13.5px、缩进 22px；
  // 学科页签用 QmChip（学科色填充，见 uikit）。
  static const double kpChapterFontSize = 15;
  static const double kpNameFontSize = 13.5;
  static const double kpIndent = 22;
  // 输入框：`.toolbar input` padding 9px 13px、14px、圆角 12、最小高 40。
  static const double inputPaddingV = 9;
  static const double inputPaddingH = 13;
  static const double inputFontSize = 14;
  static const double inputMinHeight = 40;
  // 设置行：标题 15px/700、说明 13.5px muted；组间距 `.set-grid` gap 14。
  static const double settingsRowTitleFontSize = 15;
  static const double settingsRowDescFontSize = 13.5;
  static const double settingsGroupGap = 14;
  // 键值行：`.kv` 13.5px、padding 5px 0、标签列最小宽 76px（与复习页同值）。
  static const double kvFontSize = 13.5;
  static const double kvLabelWidth = 76;
}
