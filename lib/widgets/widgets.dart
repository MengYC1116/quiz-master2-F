import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/app_theme.dart';
import 'uikit.dart';

/// 题型文字（HTML `QUESTIONS[].type` 的 Flutter 侧映射：演示数据没有
/// 独立的题型字段，按 `sliceKind` 推导；错题本 / 整理台的失败占位与
/// 队列详情行共用）。
String sliceKindLabel(String kind) => switch (kind) {
      'chart' => '图表题',
      'function' => '函数题',
      'timeline' => '时间轴',
      'limit' => '极限题',
      _ => '材料题',
    };

/// 二层区域（stem / option / figure）：演示数据没有真实框坐标，按题型
/// 与题干文字推导——选择题（题干含填空 `（　）` / `______`）有选项区，
/// 图表 / 时间轴题有配图区，题干区恒有。HTML 演示 9 题中 8 题与此规则
/// 一致（政治 p1 在 HTML 里是选择题，但 Flutter 演示题干无填空标记，
/// 无法推导，记为已知近似，见 R5 报告）。
List<String> regionsOfQuestion(Question q) {
  final regions = <String>['stem'];
  if (q.sliceText.contains('（　）') || q.sliceText.contains('______')) {
    regions.add('option');
  }
  if (q.sliceKind == 'chart' || q.sliceKind == 'timeline') {
    regions.add('figure');
  }
  return regions;
}

/// 二层区域高亮叠加层：按 HTML `paperHTML` 的区域几何（stem 上 34%、
/// option 下 36%、figure 下 42% 居中 48% 宽）画 2px 虚线框 + 区域名。
/// 只画 [visible] 里的区域；本身不吃手势（包一层 IgnorePointer 后
/// 底下的 QuestionSlice 点按仍可达）。
class QuestionRegionOverlays extends StatelessWidget {
  const QuestionRegionOverlays({
    super.key,
    required this.question,
    required this.visible,
  });

  final Question question;
  final Set<String> visible;

  @override
  Widget build(BuildContext context) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        if (w.isInfinite || h.isInfinite || w <= 0 || h <= 0) {
          return const SizedBox.shrink();
        }
        Widget region(
          String key,
          Color color,
          String label,
          double left,
          double top,
          double width,
          double height,
        ) {
          if (!visible.contains(key)) return const SizedBox.shrink();
          return Positioned(
            left: left,
            top: top,
            width: width,
            height: height,
            child: CustomPaint(
              painter: _DashedRegionPainter(color),
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: color,
                      // 行高 1.5：Linux 回退字体（Noto Serif CJK）的
                      // 自然行高大于 1.2em，1.2 会在 RenderParagraph
                      // 默认 clip 下裁掉字形顶部；1.5 留足字形高度。
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        return Stack(
          children: [
            region('stem', palette.stem, 'stem 题干', 10, 10, w - 20, h * 0.34),
            region('option', palette.option, 'option 选项', 10,
                h - 12 - h * 0.36, w - 20, h * 0.36),
            region('figure', palette.figure, 'figure 插图', w * 0.26,
                h - 14 - h * 0.42, w * 0.48, h * 0.42),
          ],
        );
      },
    );
  }
}

/// 虚线圆角框（2px 虚线 + 8% 透明同色填充），供二层区域高亮用。
class _DashedRegionPainter extends CustomPainter {
  _DashedRegionPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = color.withValues(alpha: 0.08);
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(8),
    );
    canvas.drawRRect(rrect, fill);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path()..addRRect(rrect);
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
  bool shouldRepaint(covariant _DashedRegionPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 整题图切片：白色底、1px 细边框、10px 圆角、限高 160px、按比例缩放不裁切、
/// 左右居中不偏移。图片就是卡片（外层无背景），点切片进题目详情。
/// 加载失败时显示学科图标 + 题目类型文字兜底。
/// 切片内容 = 题干文字 + 按题型画的简图（积分阴影、函数曲线、时间轴、
/// 横线材料），近似预览里切片自带的配图；真实数据是图片切片，无 OCR。
class QuestionSlice extends StatelessWidget {
  const QuestionSlice({
    super.key,
    required this.question,
    this.maxHeight = 160,
    this.onTap,
    this.failed = false,
    this.fixedHeight = false,
  });

  final Question question;
  final double maxHeight;
  final VoidCallback? onTap;
  final bool failed;

  /// 大卡片里固定为限高（各张卡片等高，容器“两张整卡 + 第三张露一半”
  /// 才算得准）；放大层与缩略图里按内容走。
  final bool fixedHeight;

  @override
  Widget build(BuildContext context) {
    final subject = Subject.byId(question.subjectId);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    // 图加载失败占位（HTML `imgFailHTML`）：学科图标 + 学科 · 题型文字，
    // 不留空白；切片与表单不受影响。
    final body = failed
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  subject.icon,
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                    color: subjectLabelColor(context, question.subjectId),
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${subject.name} · ${sliceKindLabel(question.sliceKind)}',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  '整题图加载失败，先显示学科图标和题型，不留空白',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          )
        : Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    question.sliceText,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, color: Colors.black87, height: 1.6),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: 230,
                    height: 48,
                    child: CustomPaint(
                      painter: _SliceFigurePainter(question.sliceKind),
                    ),
                  ),
                ],
              ),
            ),
          );
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: fixedHeight ? maxHeight : null,
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: BoxDecoration(
          // 纸面色取 token：亮色 #FFFDF4 / 深色 #D8DCE2（D1，HTML
          // `--paper`），深色下不再是纯白——R7 详情大图与错题本大卡片
          // 同款；纸面字仍是黑字，#D8DCE2 上可读。
          color: palette.paper,
          border: Border.all(color: palette.paperLine),
          borderRadius: BorderRadius.circular(10),
        ),
        child: body,
      ),
    );
  }
}

/// 按题型画的简图（演示用；真实切片是图片）。
class _SliceFigurePainter extends CustomPainter {
  _SliceFigurePainter(this.kind);
  final String kind;

  @override
  void paint(Canvas canvas, Size size) {
    final axisPaint = Paint()
      ..color = const Color(0xFF5B6B84)
      ..strokeWidth = 1.2;
    final linePaint = Paint()
      ..color = const Color(0xFF2F7CF6)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final fillPaint = Paint()..color = const Color(0x332F7CF6);
    final whitePaint = Paint()..color = Colors.white;
    final bluePaint = Paint()..color = const Color(0xFF2F7CF6);
    final redPaint = Paint()
      ..color = const Color(0xFFE0524D)
      ..strokeWidth = 1.2;
    final w = size.width;
    final h = size.height;
    switch (kind) {
      case 'chart': // 积分阴影：坐标轴 + 抛物线 + 阴影区
        canvas.drawLine(Offset(8, h - 8), Offset(w - 8, h - 8), axisPaint);
        canvas.drawLine(Offset(16, 4), Offset(16, h - 4), axisPaint);
        final curve = Path()
          ..moveTo(16, h - 10)
          ..quadraticBezierTo(w * 0.5, h * 0.1, w - 16, h - 34);
        canvas.drawPath(curve, linePaint);
        final shade = Path()
          ..moveTo(w * 0.35, h - 8)
          ..quadraticBezierTo(w * 0.55, h * 0.25, w * 0.8, h - 22)
          ..lineTo(w * 0.8, h - 8)
          ..close();
        canvas.drawPath(shade, fillPaint);
        canvas.drawLine(
            Offset(w * 0.35, h - 8), Offset(w * 0.35, h * 0.1), axisPaint);
        canvas.drawLine(
            Offset(w * 0.8, h - 8), Offset(w * 0.8, h * 0.1), axisPaint);
      case 'function': // 导数综合：坐标轴 + 三次曲线
        canvas.drawLine(Offset(8, h * 0.6), Offset(w - 8, h * 0.6), axisPaint);
        canvas.drawLine(Offset(w * 0.4, 4), Offset(w * 0.4, h - 4), axisPaint);
        final f = Path()
          ..moveTo(16, h * 0.15)
          ..cubicTo(w * 0.35, h * 0.9, w * 0.55, h * 0.9, w * 0.75, h * 0.2)
          ..lineTo(w - 12, h * 0.15);
        canvas.drawPath(f, linePaint);
      case 'timeline': // 史纲时间轴：横线 + 4 个年份点
        canvas.drawLine(
            Offset(8, h / 2), Offset(w - 8, h / 2), axisPaint);
        for (var i = 0; i < 4; i++) {
          final x = 24 + i * (w - 48) / 3;
          canvas.drawCircle(Offset(x, h / 2), 4, linePaint);
          canvas.drawCircle(Offset(x, h / 2), 4, whitePaint);
          canvas.drawCircle(Offset(x, h / 2), 4, bluePaint);
        }
      case 'limit': // 极限：坐标轴 + 趋近于某值的曲线
        canvas.drawLine(Offset(8, h - 8), Offset(w - 8, h - 8), axisPaint);
        canvas.drawLine(Offset(16, 4), Offset(16, h - 4), axisPaint);
        final l = Path()
          ..moveTo(20, h * 0.2)
          ..quadraticBezierTo(w * 0.5, h * 0.75, w - 16, h * 0.55);
        canvas.drawPath(l, linePaint);
        canvas.drawLine(
            Offset(20, h * 0.55), Offset(w - 8, h * 0.55), redPaint);
      default: // 材料 / 阅读：三行横线（文字行）
        final textPaint = Paint()
          ..color = const Color(0xFFB9C4D6)
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round;
        for (var i = 0; i < 3; i++) {
          final y = 10 + i * 14;
          canvas.drawLine(Offset(20, y.toDouble()),
              Offset(w - 20 - (i == 2 ? 60 : 0), y.toDouble()), textPaint);
        }
    }
  }

  @override
  bool shouldRepaint(covariant _SliceFigurePainter oldDelegate) =>
      oldDelegate.kind != kind;
}

/// 64px 紧凑缩略图（预览 .nb-thumb64）：
/// 54×40 内芯里画题干微缩线 + 按题型画的配图 + 选项行微缩条，
/// 不只是题干文字；加载失败显示学科图标 + “加载失败”。
/// 点缩略图放大看整题图（手势由调用处包 GestureDetector）。
class CompactSliceThumb extends StatelessWidget {
  const CompactSliceThumb({super.key, required this.question, this.failed = false});
  final Question question;
  final bool failed;

  bool get _hasOptionRows =>
      question.sliceText.contains('（') ||
      question.sliceText.contains('______');

  @override
  Widget build(BuildContext context) {
    final subject = Subject.byId(question.subjectId);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final barColor = dark ? const Color(0xFF6B7686) : const Color(0xFFC9CFDA);
    final body = failed
        ? Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(subject.icon,
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: subjectLabelColor(context, question.subjectId))),
              const SizedBox(height: 1),
              Text('加载失败',
                  style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).textTheme.bodySmall?.color)),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _miniBar(49, barColor),
              const SizedBox(height: 2),
              _miniBar(38, barColor),
              if (question.sliceKind != 'material') ...[
                const SizedBox(height: 2),
                SizedBox(
                  width: 52,
                  height: 14,
                  child: CustomPaint(
                    painter: _SliceFigurePainter(question.sliceKind),
                  ),
                ),
              ],
              if (_hasOptionRows) ...[
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < 4; i++) ...[
                      if (i > 0) const SizedBox(width: 3),
                      _miniBar(10, barColor),
                    ],
                  ],
                ),
              ],
              const SizedBox(height: 2),
              _miniBar(43, barColor),
            ],
          );
    return Container(
      width: 64,
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white, // 缩略图白底：深色模式下同样保留
        border: Border.all(
            color: dark ? AppTheme.darkPaperLine : AppTheme.lightPaperLine),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: body,
    );
  }

  Widget _miniBar(double width, Color color) {
    return Container(
      width: width,
      height: 3,
      decoration:
          BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
    );
  }
}

/// 虚线分隔线（R2 收口为 UI Kit 的 [QmRowLine]；签名不变，九页调用处不动）。
///
/// 颜色到形态的映射：纸线色（`paperLine`）→ [QmRowLineKind.paper]，
/// 其余 → [QmRowLineKind.line]。注意 `QmRowLine` 按当前主题取 token 色，
/// 旧调用处写死的浅色纸线值在深色下会按 `line` 档取深色线色（见 R2 报告）。
class DashedDivider extends StatelessWidget {
  const DashedDivider({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return QmRowLine(
      kind: color == palette.paperLine
          ? QmRowLineKind.paper
          : QmRowLineKind.line,
    );
  }
}

/// 学科色（标签 / 圆点 / 数字用）：
/// 亮色用学科本色，深色只用冷雾色（预览 dark --math-ink 等），
/// 不出现大块亮色。
Color subjectLabelColor(BuildContext context, String subjectId) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  if (!dark) return Subject.byId(subjectId).color;
  return switch (subjectId) {
    'english' => AppTheme.darkEnglishMist,
    'politics' => AppTheme.darkPoliticsMist,
    _ => AppTheme.darkMathMist,
  };
}

/// 学科小圆点 + 名称。
class SubjectLabel extends StatelessWidget {
  const SubjectLabel({super.key, required this.subjectId});
  final String subjectId;

  @override
  Widget build(BuildContext context) {
    final s = Subject.byId(subjectId);
    final color = subjectLabelColor(context, subjectId);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(s.name, style: TextStyle(color: color)),
      ],
    );
  }
}

/// 错误类型 / 标签小芯片（R2 收口为 UI Kit 的 [QmChip] 展示态；
/// 签名不变，九页调用处不动）。
///
/// `color == null` 时直接转发为 `QmChip(displayOnly: true)`（未选中态：
/// surface 底 / line-strong 边 / ink-2 字，13px）；`color` 非空时只有
/// 一处调用（复习页已解决错因的绿 `0xFF1F9D66`），用同一几何尺寸、
/// 该色 10% 透明底渲染，保留“已解决为绿”的含义（QmChip 没有 color 参数）。
class InfoChip extends StatelessWidget {
  const InfoChip({super.key, required this.label, this.color});
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color;
    if (c == null) return QmChip(label: label, displayOnly: true);
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: DesignTokens.chipPaddingH * scale,
        vertical: DesignTokens.chipPaddingV * scale,
      ),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999 * scale),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: DesignTokens.chipFontSize,
          color: palette.ink2,
          height: DesignTokens.controlLineHeight,
        ),
      ),
    );
  }
}

/// 题目图放大浮层（共享；整理工作台、题目详情都用它）：
/// 点图弹出大居中浮层，1.5× 起始，滚轮缩放，＋/－按钮，点图/点背景/
/// Esc/✕ 关闭。高亮区（若传 [visibleRegions]）跟着图一起缩放。
/// [returnLabel] 是浮层提示里的返回地（默认“整理台”，详情页传“题目详情”）。
/// 文字符号（D3），不用图标字体。InteractiveViewer 居中放图，不会像
/// 旧版固定偏移那样把右边文字截掉。
Future<void> showQuestionZoomDialog(
  BuildContext context,
  Question question, {
  Set<String> visibleRegions = const {},
  String returnLabel = '整理台',
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _ZoomDialog(
      question: question,
      visibleRegions: visibleRegions,
      returnLabel: returnLabel,
    ),
  );
}

class _ZoomDialog extends StatefulWidget {
  const _ZoomDialog({
    required this.question,
    required this.visibleRegions,
    required this.returnLabel,
  });

  final Question question;
  final Set<String> visibleRegions;
  final String returnLabel;

  @override
  State<_ZoomDialog> createState() => _ZoomDialogState();
}

class _ZoomDialogState extends State<_ZoomDialog> {
  late final TransformationController _controller;
  final _paperKey = GlobalKey();
  bool _centered = false;
  double _scale = 1.5;

  @override
  void initState() {
    super.initState();
    _controller = TransformationController()
      ..value = Matrix4.diagonal3Values(1.5, 1.5, 1);
    _controller.addListener(_onTransform);
    // 纯缩放矩阵以纸面左上角为原点，1.5× 会把纸面顶到视口左上、
    // 右边裁掉（HTML 的 paperbox 是 left:50%/top:50% 居中放）。
    // 首帧后按纸面实测尺寸把变换改成绕纸面中心缩放（M = T·S，
    // 平移量 -w/4、-h/4，中心点不动）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _centerInitial());
  }

  void _centerInitial() {
    if (_centered || !mounted) return;
    final size = _paperKey.currentContext?.size;
    if (size == null || size.width <= 0 || size.height <= 0) return;
    _centered = true;
    _controller.value = Matrix4.identity()
      ..translateByDouble(-size.width / 4, -size.height / 4, 0, 1)
      ..scaleByDouble(1.5, 1.5, 1, 1);
  }

  void _onTransform() {
    final s = _controller.value.getMaxScaleOnAxis();
    if ((s - _scale).abs() > 0.005) setState(() => _scale = s);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTransform);
    _controller.dispose();
    super.dispose();
  }

  void _multiply(double factor) {
    _controller.value *= Matrix4.diagonal3Values(factor, factor, 1);
  }

  @override
  Widget build(BuildContext context) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    return Dialog(
      insetPadding: EdgeInsets.all(22 * scale),
      child: SizedBox(
        width: DesignTokens.organizeZoomWidth * scale,
        height: DesignTokens.organizeZoomHeight * scale,
        child: Column(
          children: [
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: 16 * scale,
                vertical: 10 * scale,
              ),
              decoration: BoxDecoration(
                color: palette.surface2,
                border: Border(bottom: BorderSide(color: palette.line)),
              ),
              child: Row(
                children: [
                  const Text(
                    '整题图 · 放大查看',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                  SizedBox(width: 12 * scale),
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 10 * scale,
                      vertical: 2 * scale,
                    ),
                    decoration: BoxDecoration(
                      color: palette.accentSoft,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${(_scale * 100).round()}%',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: palette.accentText,
                      ),
                    ),
                  ),
                  SizedBox(width: 12 * scale),
                  Expanded(
                    child: Text(
                      '滚轮放大 / 缩小 · 按住拖动看图 · 点一下图、点关闭或按 Esc 回到${widget.returnLabel}',
                      style: const TextStyle(fontSize: 12.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  QmButton(
                    label: '＋',
                    variant: QmButtonVariant.plain,
                    size: QmButtonSize.small,
                    onPressed: () => _multiply(1.25),
                  ),
                  SizedBox(width: 6 * scale),
                  QmButton(
                    label: '－',
                    variant: QmButtonVariant.plain,
                    size: QmButtonSize.small,
                    onPressed: () => _multiply(0.8),
                  ),
                  SizedBox(width: 6 * scale),
                  QmButton(
                    label: '关闭 ×',
                    variant: QmButtonVariant.plain,
                    size: QmButtonSize.small,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Container(
                color: palette.surface2,
                child: Listener(
                  onPointerSignal: (e) {
                    if (e is PointerScrollEvent) {
                      final s = e.scrollDelta.dy < 0 ? 1.12 : 0.9;
                      _multiply(s);
                    }
                  },
                  child: InteractiveViewer(
                    transformationController: _controller,
                    minScale: 0.5,
                    maxScale: 5,
                    child: Center(
                      child: GestureDetector(
                        onTap: () => Navigator.of(context).pop(),
                        child: Stack(
                          key: _paperKey,
                          children: [
                            QuestionSlice(
                              question: widget.question,
                              maxHeight: 480,
                            ),
                            Positioned.fill(
                              child: IgnorePointer(
                                child: QuestionRegionOverlays(
                                  question: widget.question,
                                  visible: widget.visibleRegions,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 空状态（R2 收口为 UI Kit 的 [QmEmptyState]；签名不变，九页调用处不动）。
///
/// 旧 `message` 作新组件的 `title`（17px/700）；旧形态是无边框简化版，
/// 新形态是 HTML 忠实形态（1.5px 虚线圆角框 + 小伙伴 + 标题 + 说明 +
/// 主按钮 CTA），各页空状态外观随之统一为原型形态。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
  });
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return QmEmptyState(
      title: message,
      actionLabel: actionLabel,
      onAction: onAction,
    );
  }
}
