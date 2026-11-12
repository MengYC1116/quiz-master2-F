import 'package:flutter/material.dart';

/// 年轻学习伙伴感（亮色默认，深色冷灰），适配极简 × 专业约束：
/// 无卡片堆叠、无数据墙、无渐变、无玻璃拟态。
/// 颜色取值对照预览定稿（:root / [data-theme="dark"]）：
/// 亮色底 #FDF8EC、纸面 #FFFDF4、焦点卡 #E1EDFF；
/// 深色底 #1E2228、纸面 #262B33、焦点卡 #2C3949。
class AppTheme {
  static const Color accent = Color(0xFF2F7CF6);
  static const Color accentText = Color(0xFF175CD3);
  static const Color lightBackground = Color(0xFFFDF8EC);
  static const Color lightSurface = Color(0xFFFFFEF9);
  static const Color lightInk = Color(0xFF17233B);
  static const Color lightMuted = Color(0xFF5B6B84);
  static const Color lightLine = Color(0xFFE8DFC2);
  static const Color lightLineStrong = Color(0xFFCFC39E);
  static const Color lightFocusCard = Color(0xFFE1EDFF);

  static const Color darkBackground = Color(0xFF1E2228);
  static const Color darkSurface = Color(0xFF262B33);
  static const Color darkElevated = Color(0xFF333A45);
  static const Color darkInk = Color(0xFFE9EDF3);
  static const Color darkMuted = Color(0xFF97A2B2);
  static const Color darkAccent = Color(0xFF8AB6FF);
  static const Color darkAccentText = Color(0xFFA9C6E4);
  static const Color darkFocusCard = Color(0xFF2C3949);

  /// 左导航：亮色为暖纸底（预览 .side 用 --surface-2 #FDF3D8），
  /// 当前页是实心蓝块 + 白字（预览口径）；
  /// 深色为冷灰底，当前页是雾蓝块 + 深字。
  static const Color lightNavBackground = Color(0xFFFDF3D8);
  static const Color lightNavSelected = accent;
  static const Color darkNavBackground = Color(0xFF21262E);
  static const Color darkNavSelected = Color(0xFF7FA8D0);

  /// 打开的书的纸页：亮色暖白纸面（横线/网格已按定稿去掉，只留干净纸面），
  /// 深色为冷灰纸面。
  static const Color lightPaper = Color(0xFFFFFDF4);
  static const Color lightPaperLine = Color(0xFFE3D9BE);
  static const Color darkPaper = Color(0xFF262B33);
  static const Color darkPaperLine = Color(0xFFAEB6C2);

  /// 深色模式学科冷雾色（预览 dark --math-ink / --eng-ink / --pol-ink）：
  /// 深色下学科色只以这些颜色出现在圆点 / 数字 / 标签上，
  /// 不出现大块亮色与纸页左缘亮蓝条。
  static const Color darkMathMist = Color(0xFFACC8E2);
  static const Color darkEnglishMist = Color(0xFFAFD2C2);
  static const Color darkPoliticsMist = Color(0xFFD8B4C0);

  static const double radius = 12;

  static ThemeData light() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: const ColorScheme.light(
        primary: accent,
        surface: lightSurface,
        onSurface: lightInk,
      ),
      scaffoldBackgroundColor: lightBackground,
      appBarTheme: const AppBarTheme(
        backgroundColor: lightBackground,
        foregroundColor: lightInk,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: lightSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: lightLine),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      textTheme: const TextTheme(
        headlineMedium: TextStyle(
            fontSize: 34, fontWeight: FontWeight.w800, color: lightInk),
        titleLarge: TextStyle(
            fontSize: 24, fontWeight: FontWeight.w700, color: lightInk),
        bodyMedium: TextStyle(fontSize: 14, color: lightInk),
        bodySmall: TextStyle(fontSize: 12, color: lightMuted),
      ),
    );
  }

  static ThemeData dark() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: darkAccent,
        surface: darkSurface,
        onSurface: darkInk,
      ),
      scaffoldBackgroundColor: darkBackground,
      appBarTheme: const AppBarTheme(
        backgroundColor: darkBackground,
        foregroundColor: darkInk,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: darkSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: Color(0xFF333B47)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      textTheme: const TextTheme(
        headlineMedium: TextStyle(
            fontSize: 34, fontWeight: FontWeight.w800, color: darkInk),
        titleLarge: TextStyle(
            fontSize: 24, fontWeight: FontWeight.w700, color: darkInk),
        bodyMedium: TextStyle(fontSize: 14, color: darkInk),
        bodySmall: TextStyle(fontSize: 12, color: darkMuted),
      ),
    );
  }
}

/// 纸纹微点（预览 body 背景）：
/// 亮色暖纸 rgba(180,160,90,.07)、深色 rgba(160,180,205,.030)，
/// 1px 点、22px 间距。只铺在应用底色上，打开的书的纸页本身
/// 按预览是干净纸面（background-image:none），不铺点。
class PaperDots extends StatelessWidget {
  const PaperDots({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return CustomPaint(
      painter: _PaperDotsPainter(
        dark
            ? const Color.fromRGBO(160, 180, 205, 0.03)
            : const Color.fromRGBO(180, 160, 90, 0.07),
      ),
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

    // 头顶绿芽：茎 + 两片叶子。
    final stemPaint = Paint()
      ..color = const Color(0xFF1F9D66)
      ..strokeWidth = w * 0.045
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(cx, bodyCy - bodyR * 0.82),
        Offset(cx, bodyCy - bodyR * 1.28), stemPaint);
    final leafPaint = Paint()..color = const Color(0xFF35B57E);
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
    final eyePaint = Paint()..color = const Color(0xFF17233B);
    canvas.drawCircle(
        Offset(cx - bodyR * 0.36, bodyCy - bodyR * 0.08), bodyR * 0.09, eyePaint);
    canvas.drawCircle(
        Offset(cx + bodyR * 0.36, bodyCy - bodyR * 0.08), bodyR * 0.09, eyePaint);
    final smilePaint = Paint()
      ..color = const Color(0xFF17233B)
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

    // 右手边的红铅笔（斜放）。
    canvas.save();
    canvas.translate(cx + bodyR * 0.78, bodyCy + bodyR * 0.42);
    canvas.rotate(-0.6);
    final pencilPaint = Paint()..color = const Color(0xFFE0524D);
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
