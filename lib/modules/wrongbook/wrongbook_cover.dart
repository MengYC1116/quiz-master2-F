part of 'wrongbook_page.dart';

// 封面绘制器：折角 / 书脊阴影 / 页边 / 虚线等 CustomPainter。
// Batch 2 与书脊修复反复调过的像素级代码，逐字搬移，只改所在文件。

/// 折角（HTML `.nb-book-fold`：右上角 34px 纸色折角）。
/// 渐变 linear-gradient(225deg, transparent 49%, rgba(0,0,0,.16) 50%,
/// #FFFFFF 52%, #DCE8F5 100%)，左下角圆角 8px，阴影 -2px 2px 4px / .18。
/// 注意纸色区的形状：渐变只在 t>0.52 的区域显纸色，即 34×34 方块内
/// 对角线 y=x 左下方的三角（顶点左上、左下、右下），不是旧代码的
/// 右上三角——旧三角把纸色画在了渐变透明的那一半，看着像小三角旗。
/// 阴影按 CSS box-shadow 的做法取方块（左下圆角）的影，而不是三角的影，
/// 透明区上方的淡淡暗角才能出来。
class _CoverFoldPainter extends CustomPainter {
  _CoverFoldPainter(this.scale);
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // 纸色三角：顶点 (0,0)、(0,h)、(w,h)，斜边即对角线 y=x（渐变 t=0.50
    // 的暗线正好落在斜边上）。左下角圆角 8px：圆角点在左缘 (0, h-r)
    // 与底缘 (r, h)，控制点为角 (0, h)。
    final r = 8 * scale;
    final fold = Path()
      ..moveTo(0, 0)
      ..lineTo(0, h - r)
      ..quadraticBezierTo(0, h, r, h)
      ..lineTo(w, h)
      ..close();
    // 阴影：方块（左下圆角 8px）的影。canvas.drawShadow 按 CSS box-shadow
    // 的做法只把影落在方块之外（方块内不染暗，纸面与右上角底色都干净）；
    // elevation 4 对应模糊约 4、下移约 2，HTML 的 -2 横向偏移在此
    // 模糊下不可见，取 0。
    final square = Path()
      ..addRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(0, 0, w, h),
          bottomLeft: Radius.circular(r),
        ),
      );
    canvas.drawShadow(
      square,
      const Color.fromRGBO(0, 0, 0, 0.18),
      4 * scale,
      false,
    );
    const gradient = LinearGradient(
      begin: Alignment.topRight,
      end: Alignment.bottomLeft,
      colors: [
        Color.fromRGBO(0, 0, 0, 0),
        Color.fromRGBO(0, 0, 0, 0.16),
        Color(0xFFFFFFFF),
        Color(0xFFDCE8F5),
      ],
      stops: [0.49, 0.50, 0.52, 1.0],
    );
    canvas.drawPath(
      fold,
      Paint()..shader = gradient.createShader(Rect.fromLTWH(0, 0, w, h)),
    );
  }

  @override
  bool shouldRepaint(covariant _CoverFoldPainter oldDelegate) =>
      oldDelegate.scale != scale;
}

/// 封面内阴影（HTML `.nb-book` box-shadow 的两层 inset，
/// 画在纹样之上、书脊之下，与 HTML 的绘制顺序一致）：
/// 左 inset 4px 0 8px rgba(0,0,0,.18)——12px 内渐隐的暗带；
/// 右 inset -2px 0 4px rgba(255,255,255,.14)——6px 内渐隐的亮带。
class _CoverInsetShadowPainter extends CustomPainter {
  /// 两带可单独开关：左暗带与书脊一起移到封面边缘画（见 `_buildBook`
  /// 外层 Stack），内层只留右亮带——否则书脊移走后，左暗带会留在
  /// 原位置（封面左缘内 18px）形成一条多余的暗带。
  const _CoverInsetShadowPainter({this.drawLeft = true, this.drawRight = true});
  final bool drawLeft;
  final bool drawRight;

  @override
  void paint(Canvas canvas, Size size) {
    if (drawLeft) {
      final left = LinearGradient(
        colors: const [
          Color.fromRGBO(0, 0, 0, 0.18),
          Color.fromRGBO(0, 0, 0, 0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, 12, size.height));
      canvas.drawRect(
        Rect.fromLTWH(0, 0, 12, size.height),
        Paint()..shader = left,
      );
    }
    if (drawRight) {
      final right = LinearGradient(
        colors: const [
          Color.fromRGBO(255, 255, 255, 0),
          Color.fromRGBO(255, 255, 255, 0.14),
        ],
      ).createShader(Rect.fromLTWH(size.width - 6, 0, 6, size.height));
      canvas.drawRect(
        Rect.fromLTWH(size.width - 6, 0, 6, size.height),
        Paint()..shader = right,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CoverInsetShadowPainter oldDelegate) =>
      oldDelegate.drawLeft != drawLeft || oldDelegate.drawRight != drawRight;
}

/// 书页边（HTML `.nb-book::after`：4px 宽，3px 米白 #F5EFDD +
/// 1px #D9D2BC 循环，整体 opacity .85；每条按 .85 画在封面色上，
/// 与整层 .85 叠加等价）。
class _CoverPageEdgePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    var y = 0.0;
    var light = true;
    while (y < size.height) {
      final h = light ? 3.0 : 1.0;
      paint.color = (light ? const Color(0xFFF5EFDD) : const Color(0xFFD9D2BC))
          .withValues(alpha: 0.85);
      canvas.drawRect(
        Rect.fromLTWH(0, y, size.width, h.clamp(0, size.height - y)),
        paint,
      );
      y += h;
      light = !light;
    }
  }

  @override
  bool shouldRepaint(covariant _CoverPageEdgePainter oldDelegate) => false;
}

/// 竖向虚线（子文件夹区左缘，HTML `.nb-toc-kids` 的 `border-left`
/// 1px dashed）。
class _VerticalDashedPainter extends CustomPainter {
  _VerticalDashedPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const dash = 7.0;
    const gap = 4.0;
    var y = 0.0;
    while (y < size.height) {
      canvas.drawLine(
        Offset(size.width / 2, y),
        Offset(size.width / 2, (y + dash).clamp(0, size.height)),
        paint,
      );
      y += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _VerticalDashedPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 虚线圆角框（封面虚线内框用；HTML `.nb-book::before`
/// 圆角 4px 9px 9px 4px：左上 4、右上 9、右下 9、左下 4）。
class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({
    required this.color,
    required this.borderRadius,
    required this.strokeWidth,
  });
  final Color color;
  final BorderRadius borderRadius;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndCorners(
          Offset.zero & size,
          topLeft: borderRadius.topLeft,
          topRight: borderRadius.topRight,
          bottomRight: borderRadius.bottomRight,
          bottomLeft: borderRadius.bottomLeft,
        ),
      );
    const dash = 7.0;
    const gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var drawn = 0.0;
      final total = metric.length;
      while (drawn < total) {
        final segment = metric.extractPath(drawn, drawn + dash);
        canvas.drawPath(segment, paint);
        drawn += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.strokeWidth != strokeWidth;
}

/// 封面纹理（6 种样式）：纯色折角 / 横线纹 / 圆点 / 方格纹 / 斜纹 / 双线框。
class _CoverPatternPainter extends CustomPainter {
  _CoverPatternPainter(this.style);
  final String style;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..strokeWidth = 1.5;
    switch (style) {
      case 'lines':
        for (var y = 28.0; y < size.height; y += 22) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        }
      case 'dots':
        for (var y = 20.0; y < size.height; y += 24) {
          for (var x = 18.0; x < size.width; x += 24) {
            canvas.drawCircle(Offset(x, y), 2.5, paint);
          }
        }
      case 'grid':
        for (var x = 20.0; x < size.width; x += 22) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
        }
        for (var y = 20.0; y < size.height; y += 22) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        }
      case 'diagonal':
        for (var i = -8; i < 16; i++) {
          final x = i * 24.0;
          canvas.drawLine(
            Offset(x, size.height),
            Offset(x + size.height, 0),
            paint,
          );
        }
      case 'double':
        final rect = Rect.fromLTWH(10, 10, size.width - 20, size.height - 20);
        canvas.drawRect(rect, paint);
        final inner = Rect.fromLTWH(16, 16, size.width - 32, size.height - 32);
        canvas.drawRect(inner, paint);
      case 'plain':
      // 纯色折角：无纹样，角落只由 _CoverFoldPainter 按 HTML
      // `.nb-book-fold` 画（旧代码这里还叠了一个 28px 白色三角，
      // 与折角重叠后在角落留一块洗白的半透明区，HTML plain 样式
      // 没有它，B2 随折角重画一并去掉）。
    }
  }

  @override
  bool shouldRepaint(covariant _CoverPatternPainter oldDelegate) =>
      oldDelegate.style != style;
}
