// 收集中心共用小部件（B4 从 collect_page.dart 纯拆分移出，未改行为）。
//
// - [DashedDropPainter]：拖放区虚线框（原 `_DashedDropPainter`，
//   跨文件使用故改为公开；仅改名，画法一字未动）。

import 'package:flutter/material.dart';

/// 拖放区虚线框（HTML `.drop`：2px dashed accent 边）。
class DashedDropPainter extends CustomPainter {
  DashedDropPainter({
    required this.color,
    required this.radius,
    this.strokeWidth = 2,
  });

  final Color color;
  final double radius;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;
    final rect = Rect.fromLTWH(1, 1, size.width - 2, size.height - 2);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    // 沿路径画虚线：8px 实线 + 6px 间隔。
    final metrics = path.computeMetrics().first;
    var distance = 0.0;
    while (distance < metrics.length) {
      final segment = metrics.extractPath(distance, distance + 8);
      canvas.drawPath(segment, paint);
      distance += 14;
    }
  }

  @override
  bool shouldRepaint(DashedDropPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.radius != radius ||
      oldDelegate.strokeWidth != strokeWidth;
}
