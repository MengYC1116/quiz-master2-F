part of 'wrongbook_page.dart';

// 封面绘制器：折角 / 书脊阴影 / 页边 / 虚线等 CustomPainter。
// Batch 2 与书脊修复反复调过的像素级代码，逐字搬移，只改所在文件。

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

/// 书页边（板子 12 号 `.b12::after`：右沿 8px 宽、上下各 inset 4px、
/// 右圆角 2px，米白细纹竖纹重复：#FFFEF8 2px / #DCD4BE 1px 交替，
/// 每 3px 一个循环。竖纹沿 x 方向排布，与旧画笔的横纹不同）。
class _Book12PageEdgePainter extends CustomPainter {
  const _Book12PageEdgePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cream = Paint()..color = const Color(0xFFFFFEF8);
    final tan = Paint()..color = const Color(0xFFDCD4BE);
    var x = 0.0;
    while (x < size.width) {
      final creamW = (2.0).clamp(0.0, size.width - x);
      canvas.drawRect(Rect.fromLTWH(x, 0, creamW, size.height), cream);
      x += 2.0;
      if (x >= size.width) break;
      final tanW = (1.0).clamp(0.0, size.width - x);
      canvas.drawRect(Rect.fromLTWH(x, 0, tanW, size.height), tan);
      x += 1.0;
    }
  }

  @override
  bool shouldRepaint(covariant _Book12PageEdgePainter oldDelegate) => false;
}
