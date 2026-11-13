import 'package:flutter/material.dart';

import 'design_tokens.dart';

export 'design_tokens.dart'
    show AppPalette, CoverTokens, DesignTokens, FontScale, ScaledTokens;

/// 主题（R1 重建）。
///
/// 颜色唯一来源是 [DesignTokens]（`design_tokens.dart`，值取自 HTML
/// `:root` / 深色 `@media`）；本文件只负责把 token 组装成 [ThemeData，
/// 并保留页面代码一直在用的 [AppTheme] 公共 API（常量名不变、值按
/// R0 §6-A 修正），页面文件一个字都不用改。
///
/// R0 §6-A 修正点（旧值 → 新值）：
/// - 主色 `0xFF2F7CF6` → `#2E7CF6`（1 位差）；
/// - `lightMuted 0xFF5B6B84` → `#5F718E`；
/// - 深色主色 `darkAccent 0xFF8AB6FF` → `#7FA8D0`，且深色 FilledButton
///   不再用浅色 accent，统一用 `#7FA8D0` + 深色字 `#131A24`；
/// - 深色纸面 `darkPaper 0xFF262B33` → `#D8DCE2`（负责人已确认，
///   深色下打开的书仍是浅灰纸页），纸面字 `#232830`、纸面线 `#AEB6C2`；
/// - 新增 `--ink-2` / `--surface-3` / `--warn/--err/--info` /
///   `--keep/--merge/--cut` / `--stem/--option/--figure` /
///   `--radius-lg` / `--shadow` 等旧代码缺失的 token；
/// - 正文 `bodyMedium 14` → `15px / 行高 1.65`，并指定字体栈（D2）。
///
/// 字号缩放（D4，1.00 / 1.15 / 1.30）：
/// [light]/[dark] 接受可选的 `scale`，只缩放布局类度量（按钮内边距与
/// 最小尺寸、圆角）；`TextTheme` 的字号一律取基准值、不乘 `scale`——
/// 字号由 `app.dart` 的 `MediaQuery TextScaler` 全局乘一次，
/// 两处都乘会造成重复缩放。不要用整页 `Transform.scale`。
class AppTheme {
  // ---------------------------------------------------------- 兼容转发 --
  // 以下常量是页面 / 共享组件一直在用的名字，值已按 HTML 修正。
  // 注意：Dart 的 const 表达式不能跨类取 const 对象的实例字段，所以
  // 这里写字面值；每个值都与 DesignTokens 里同名 token 逐项对应，
  // 改值时两处同步（对照表见 docs/ui-replication/R1-TOKENS.md）。
  // 新代码请直接用 DesignTokens，不要再加 AppTheme 常量。
  static const Color accent = Color(0xFF2E7CF6);
  static const Color accentText = Color(0xFF175CD3);
  static const Color lightBackground = Color(0xFFFDF8EC);
  static const Color lightSurface = Color(0xFFFFFEF9);
  static const Color lightSurface2 = Color(0xFFFDF3D8);
  static const Color lightSurface3 = Color(0xFFF3E9C8);
  static const Color lightInk = Color(0xFF17233B);
  static const Color lightInk2 = Color(0xFF3D4E6B);
  static const Color lightMuted = Color(0xFF5F718E);
  static const Color lightLine = Color(0xFFE8DFC2);
  static const Color lightLineStrong = Color(0xFFCFC39E);
  static const Color lightFocusCard = Color(0xFFE1EDFF);
  static const Color lightAccentSoft = Color(0xFFE1EDFF);
  static const Color lightAccentInk = Color(0xFFFFFFFF);

  static const Color darkBackground = Color(0xFF1E2228);
  static const Color darkSurface = Color(0xFF262B33);
  static const Color darkSurface2 = Color(0xFF21262E);
  static const Color darkElevated = Color(0xFF333A45);
  static const Color darkInk = Color(0xFFE9EDF3);
  static const Color darkInk2 = Color(0xFFC6CEDA);
  static const Color darkMuted = Color(0xFF97A2B2);
  static const Color darkLine = Color(0xFF333B47);
  static const Color darkLineStrong = Color(0xFF485364);
  static const Color darkAccent = Color(0xFF7FA8D0);
  static const Color darkAccentText = Color(0xFFA9C6E4);
  static const Color darkAccentInk = Color(0xFF131A24);
  static const Color darkFocusCard = Color(0xFF2C3949);
  static const Color darkAccentSoft = Color(0xFF2C3949);

  /// 左导航：亮色为暖纸底（预览 .side 用 --surface-2 #FDF3D8），
  /// 当前页是实心蓝块 + 白字（预览口径）；
  /// 深色为冷灰底，当前页是雾蓝块 + 深字。
  static const Color lightNavBackground = Color(0xFFFDF3D8);
  static const Color lightNavSelected = Color(0xFF2E7CF6);
  static const Color lightNavSelectedInk = Color(0xFFFFFFFF);
  static const Color darkNavBackground = Color(0xFF21262E);
  static const Color darkNavSelected = Color(0xFF7FA8D0);
  static const Color darkNavSelectedInk = Color(0xFF131A24);

  /// 打开的书的纸页：亮色暖白纸面，深色浅灰纸面（#D8DCE2，见
  /// DesignTokens 注释；旧代码的冷灰 #262B33 已废弃）。
  static const Color lightPaper = Color(0xFFFFFDF4);
  static const Color lightPaperInk = Color(0xFF22251F);
  static const Color lightPaperLine = Color(0xFFE3D9BE);
  static const Color darkPaper = Color(0xFFD8DCE2);
  static const Color darkPaperInk = Color(0xFF232830);
  static const Color darkPaperLine = Color(0xFFAEB6C2);

  /// 深色模式学科冷雾色（预览 dark --math-ink / --eng-ink / --pol-ink）：
  /// 深色下学科色只以这些颜色出现在圆点 / 数字 / 标签上，
  /// 不出现大块亮色与纸页左缘亮蓝条。
  /// 注意：这是 `--*-ink`（标签文字色）；学科基本色另见
  /// [DesignTokens.subjectColor]（深色 #87A9CC / #8AB5A3 / #C295A5）。
  static const Color darkMathMist = Color(0xFFACC8E2);
  static const Color darkEnglishMist = Color(0xFFAFD2C2);
  static const Color darkPoliticsMist = Color(0xFFD8B4C0);

  static const double radius = DesignTokens.radius;
  static const double radiusLg = DesignTokens.radiusLg;
  static const double buttonRadius = DesignTokens.buttonRadius;

  /// 按亮度取整套 token（R2 页面重构时用）。
  static AppPalette paletteOf(BuildContext context) =>
      DesignTokens.of(Theme.of(context).brightness);

  static ThemeData light({double scale = FontScale.standard}) =>
      _build(DesignTokens.light, false, scale);

  static ThemeData dark({double scale = FontScale.standard}) =>
      _build(DesignTokens.dark, true, scale);

  static ThemeData themeFor(Brightness brightness,
          {double scale = FontScale.standard}) =>
      brightness == Brightness.dark
          ? dark(scale: scale)
          : light(scale: scale);

  static ThemeData _build(AppPalette p, bool dark, double scale) {
    final scaled = DesignTokens.scaled(scale);
    final buttonPadding = EdgeInsets.symmetric(
      horizontal: 20 * scale,
      vertical: 12 * scale,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: dark ? Brightness.dark : Brightness.light,
      fontFamily: DesignTokens.fontFamily,
      fontFamilyFallback: DesignTokens.fontFamilyFallback,
      colorScheme: ColorScheme(
        brightness: dark ? Brightness.dark : Brightness.light,
        primary: p.accent,
        onPrimary: p.accentInk,
        secondary: p.eng,
        onSecondary: p.accentInk,
        error: p.errInk,
        onError: p.accentInk,
        surface: p.surface,
        onSurface: p.ink,
        surfaceContainerHighest: p.surface2,
        outline: p.line,
        outlineVariant: p.lineStrong,
        errorContainer: p.errBg,
        onErrorContainer: p.errInk,
      ),
      scaffoldBackgroundColor: p.background,
      dividerColor: p.line,
      appBarTheme: AppBarTheme(
        backgroundColor: p.background,
        foregroundColor: p.ink,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: p.surface,
        elevation: 0,
        shadowColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(scaled.radius),
          side: BorderSide(color: p.line),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.accent,
          foregroundColor: p.accentInk,
          minimumSize: Size(88 * scale, 40 * scale),
          padding: buttonPadding,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(scaled.buttonRadius),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.accentText,
          minimumSize: Size(88 * scale, 40 * scale),
          padding: buttonPadding,
          side: BorderSide(color: p.accent),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(scaled.buttonRadius),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.accentText,
          padding: buttonPadding,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(scaled.buttonRadius),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(scaled.radiusLg),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(scaled.buttonRadius),
          borderSide: BorderSide(color: p.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(scaled.buttonRadius),
          borderSide: BorderSide(color: p.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(scaled.buttonRadius),
          borderSide: BorderSide(color: p.accent),
        ),
      ),
      textTheme: DesignTokens.textTheme(p).apply(
        fontFamily: DesignTokens.fontFamily,
        fontFamilyFallback: DesignTokens.fontFamilyFallback,
      ),
    );
  }
}

/// 纸纹微点（预览 body 背景）：
/// 亮色暖纸 rgba(180,160,90,.07)、深色 rgba(160,180,205,.030)，
/// 1px 点、22px 间距。只铺在应用底色上，打开的书的纸页本身
/// 按预览是干净纸面（background-image:none），不铺点。
/// R1 只做 token 化（颜色取自 DesignTokens），行为不变。
class PaperDots extends StatelessWidget {
  const PaperDots({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final dots = dark ? DesignTokens.dark.paperDots : DesignTokens.light.paperDots;
    return CustomPaint(
      painter: _PaperDotsPainter(dots),
      size: Size.infinite,
    );
  }
}

class _PaperDotsPainter extends CustomPainter {
  const _PaperDotsPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const step = 22.0;
    for (var y = step / 2; y < size.height; y += step) {
      for (var x = step / 2; x < size.width; x += step) {
        canvas.drawCircle(Offset(x, y), 1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PaperDotsPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 学习小伙伴形象（原创白团子 + 绿芽 + 红铅笔；仅空状态 / 首页继续上次 /
/// 复习完成出现）。白团子身体、头顶两片绿芽、右手一支红铅笔，
/// 用形状绘制（正式版可替换为 SVG 资源）。
/// R1 只做 token 化（颜色取自 DesignTokens / CoverTokens，数值与旧
/// 代码一致），行为与画法不变。
class CompanionWidget extends StatelessWidget {
  const CompanionWidget({super.key, this.size = 72, this.message});
  final double size;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size,
          height: size * 1.12,
          child: CustomPaint(painter: _CompanionPainter()),
        ),
        if (message != null) ...[
          const SizedBox(height: 8),
          Text(message!, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ],
    );
  }
}

class _CompanionPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final bodyR = w * 0.42;
    final bodyCy = h * 0.56;

    // 头顶绿芽：茎 + 两片叶子（封面绿 #1F9D66 / 亮绿 #35B57E）。
    final stemPaint = Paint()
      ..color = CoverTokens.of('green')
      ..strokeWidth = w * 0.045
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(cx, bodyCy - bodyR * 0.82),
        Offset(cx, bodyCy - bodyR * 1.28), stemPaint);
    const leafColor = Color(0xFF35B57E);
    final leafPaint = Paint()..color = leafColor;
    canvas.drawOval(
        Rect.fromCenter(
            center: Offset(cx - w * 0.13, bodyCy - bodyR * 1.22),
            width: w * 0.24,
            height: w * 0.13),
        leafPaint);
    canvas.drawOval(
        Rect.fromCenter(
            center: Offset(cx + w * 0.13, bodyCy - bodyR * 1.22),
            width: w * 0.24,
            height: w * 0.13),
        leafPaint);

    // 白团子身体：白底 + 浅蓝描边 + 淡淡的影。
    final shadowPaint = Paint()
      ..color = const Color(0x14000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawCircle(Offset(cx, bodyCy + h * 0.02), bodyR, shadowPaint);
    final bodyPaint = Paint()..color = Colors.white;
    canvas.drawCircle(Offset(cx, bodyCy), bodyR, bodyPaint);
    final outlinePaint = Paint()
      ..color = const Color(0xFFDCE6F5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(Offset(cx, bodyCy), bodyR, outlinePaint);

    // 眼睛 + 微笑。
    final eyePaint = Paint()..color = DesignTokens.light.ink;
    canvas.drawCircle(
        Offset(cx - bodyR * 0.36, bodyCy - bodyR * 0.08), bodyR * 0.09, eyePaint);
    canvas.drawCircle(
        Offset(cx + bodyR * 0.36, bodyCy - bodyR * 0.08), bodyR * 0.09, eyePaint);
    final smilePaint = Paint()
      ..color = DesignTokens.light.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.035
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
        Rect.fromCircle(
            center: Offset(cx, bodyCy + bodyR * 0.12), radius: bodyR * 0.32),
        0.15 * 3.14159,
        0.7 * 3.14159,
        false,
        smilePaint);

    // 右手边的红铅笔（斜放，封面红 #E0524D）。
    canvas.save();
    canvas.translate(cx + bodyR * 0.78, bodyCy + bodyR * 0.42);
    canvas.rotate(-0.6);
    final pencilPaint = Paint()..color = CoverTokens.of('red');
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: Offset.zero, width: w * 0.09, height: w * 0.42),
            const Radius.circular(3)),
        pencilPaint);
    final tipPaint = Paint()..color = const Color(0xFFF6C89F);
    final tip = Path()
      ..moveTo(-w * 0.045, w * 0.21)
      ..lineTo(w * 0.045, w * 0.21)
      ..lineTo(0, w * 0.32)
      ..close();
    canvas.drawPath(tip, tipPaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
