import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../data/database.dart';
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
    // 库里读到的学科对象（调用方从 `_subjects` 里找）：传了就用它的
    // 名 / 图标 / 存色，新学科不再显示成“数学”+数学色；
    // 不传则走 `Subject.byId` 回退（预设三科旧行为不变，
    // SubjectLabel 同款做法）。
    this.subject,
  });

  final Question question;
  final double maxHeight;
  final VoidCallback? onTap;
  final bool failed;
  final Subject? subject;

  /// 大卡片里固定为限高（各张卡片等高，容器“两张整卡 + 第三张露一半”
  /// 才算得准）；放大层与缩略图里按内容走。
  final bool fixedHeight;

  @override
  Widget build(BuildContext context) {
    // 传了库里的学科对象就用它；没传才回退 Subject.byId（未知 id
    // 回退数学，只发生在数据不一致或调用方没传时）。
    final subject = this.subject ?? Subject.byId(question.subjectId);
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
                    color: subjectLabelColor(
                      context,
                      question.subjectId,
                      subject.color,
                    ),
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${subject.name} · ${sliceKindLabel(question.sliceKind)}',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
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
        : _realSliceBody(context, subject, palette);
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

  /// 真实题缺图占位（学科图标 + 学科 · 题型 + 「图片缺失，可重新导入/
  /// 重新框选」）：文件缺失与图片解码失败共用（后者走 [Image.errorBuilder]），
  /// 与详情页图片加载失败「学科图标 + 题型文字」的处理同口径。
  /// SR-P2-29 附带：占位 Column（图标 34 + 两行文字）自然高约 100px，
  /// 整理页修框切片卡只给 66px（`organizeSliceBodyMaxHeight`），旧写法
  /// 直接溢出 35px；包一层 scaleDown 的 FittedBox，空间够时原样显示、
  /// 空间紧时等比缩小，不再溢出（大图处 480px 不受影响）。
  Widget _missingImagePlaceholder(BuildContext context, Subject subject) {
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              subject.icon,
              style: TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w800,
                color: subjectLabelColor(
                  context,
                  question.subjectId,
                  subject.color,
                ),
                height: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${subject.name} · ${sliceKindLabel(question.sliceKind)}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const Text(
              '图片缺失，可重新导入/重新框选',
              style: TextStyle(fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// §1.2(a)/§1.4：真实切片优先——`slice_path` 指向的 PNG 存在就
  /// 显示真图（按显示尺寸解码，`cacheWidth` 不解全分辨率大图）；
  /// `slice_path` 有值但文件缺失、或真实题有来源却无切片时显示
  /// “图片缺失，可重新导入/重新框选”，不回退空白纸面；
  /// `sliceText` 回退只适用于演示题与老题
  /// （老题判定：`sourcePath == null && slicePath == null`）。
  Widget _realSliceBody(
    BuildContext context,
    Subject subject,
    AppPalette palette,
  ) {
    final sliceAbs = question.slicePath == null
        ? null
        : AppDatabase.resolveDataPath(question.slicePath!);
    if (sliceAbs != null && File(sliceAbs).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.file(
          File(sliceAbs),
          fit: BoxFit.contain,
          // SR-P2-74：cacheWidth 按显示尺寸 × devicePixelRatio 解码——
          // 旧值只有逻辑尺寸的 2 倍，高分屏上文字偏糊；封顶 2048 防爆内存。
          cacheWidth: math.min(
            ((maxHeight * 2) * MediaQuery.devicePixelRatioOf(context)).ceil(),
            2048,
          ),
          // 文件存在但解码失败（如损坏 / 非图片内容）：不显示 Flutter
          // 的报错占位，走与文件缺失同一口径的缺图占位。
          errorBuilder: (context, error, stackTrace) =>
              _missingImagePlaceholder(context, subject),
        ),
      );
    }
    final isLegacy = question.sourcePath == null && question.slicePath == null;
    if (question.slicePath != null || !question.isDemo && !isLegacy) {
      // 真实题缺图：明确提示，不画空白纸面。
      return _missingImagePlaceholder(context, subject);
    }
    // 演示题 / 老题：沿用 sliceText 占位绘制。
    return Center(
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
                fontSize: 14,
                color: Colors.black87,
                height: 1.6,
              ),
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
          Offset(w * 0.35, h - 8),
          Offset(w * 0.35, h * 0.1),
          axisPaint,
        );
        canvas.drawLine(
          Offset(w * 0.8, h - 8),
          Offset(w * 0.8, h * 0.1),
          axisPaint,
        );
      case 'function': // 导数综合：坐标轴 + 三次曲线
        canvas.drawLine(Offset(8, h * 0.6), Offset(w - 8, h * 0.6), axisPaint);
        canvas.drawLine(Offset(w * 0.4, 4), Offset(w * 0.4, h - 4), axisPaint);
        final f = Path()
          ..moveTo(16, h * 0.15)
          ..cubicTo(w * 0.35, h * 0.9, w * 0.55, h * 0.9, w * 0.75, h * 0.2)
          ..lineTo(w - 12, h * 0.15);
        canvas.drawPath(f, linePaint);
      case 'timeline': // 史纲时间轴：横线 + 4 个年份点
        canvas.drawLine(Offset(8, h / 2), Offset(w - 8, h / 2), axisPaint);
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
          Offset(20, h * 0.55),
          Offset(w - 8, h * 0.55),
          redPaint,
        );
      default: // 材料 / 阅读：三行横线（文字行）
        final textPaint = Paint()
          ..color = const Color(0xFFB9C4D6)
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round;
        for (var i = 0; i < 3; i++) {
          final y = 10 + i * 14;
          canvas.drawLine(
            Offset(20, y.toDouble()),
            Offset(w - 20 - (i == 2 ? 60 : 0), y.toDouble()),
            textPaint,
          );
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
  const CompactSliceThumb({
    super.key,
    required this.question,
    this.failed = false,
    // 同 QuestionSlice：库里读到的学科对象；不传走 Subject.byId 回退。
    this.subject,
  });
  final Question question;
  final bool failed;
  final Subject? subject;

  bool get _hasOptionRows =>
      question.sliceText.contains('（') || question.sliceText.contains('______');

  @override
  Widget build(BuildContext context) {
    final subject = this.subject ?? Subject.byId(question.subjectId);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final barColor = dark ? const Color(0xFF6B7686) : const Color(0xFFC9CFDA);
    // §1.2(a)：真实切片存在就显示真图（128px 解码）；真实题缺图
    // 显示“图片缺失”，不画空白迷你条；演示题/老题沿用原迷你条绘制。
    final sliceAbs = question.slicePath == null
        ? null
        : AppDatabase.resolveDataPath(question.slicePath!);
    final sliceFile = sliceAbs == null ? null : File(sliceAbs);
    final sliceExists = sliceFile != null && sliceFile.existsSync();
    final missingRealImage =
        (question.slicePath != null && !sliceExists) ||
        (question.slicePath == null &&
            question.sourcePath != null &&
            !question.isDemo);
    // 失败占位（学科图标 + “加载失败”/“图片缺失”，与 QuestionSlice 的
    // _missingImagePlaceholder 同款口径、紧凑尺寸）：failed / 缺图分支
    // 与 Image.file 解码失败（errorBuilder，SR-P1-15）共用，不另造样式。
    // 图标 14px（P0B1 顺带修：以前 17px 时图标 +“加载失败”
    // 两行共 44px，超出 64×48 容器内高 38px、底部溢出 6px；
    // 数学题同样溢出，与学科无关，新回归测试发现）。
    final failedPlaceholder = Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          subject.icon,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            height: 1.0,
            color: subjectLabelColor(
              context,
              question.subjectId,
              subject.color,
            ),
          ),
        ),
        const SizedBox(height: 1),
        Text(
          missingRealImage && !failed ? '图片缺失' : '加载失败',
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            height: 1.2,
            color: Theme.of(context).textTheme.bodySmall?.color,
          ),
        ),
      ],
    );
    final body = failed || missingRealImage
        ? failedPlaceholder
        : sliceFile != null && sliceFile.existsSync()
        ? ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              sliceFile,
              fit: BoxFit.cover,
              // SR-P2-74：同 QuestionSlice，cacheWidth 乘 devicePixelRatio
              //（64px 逻辑宽 × 2 倍基数 × dpr），封顶 384 防爆内存。
              cacheWidth: math.min(
                (128 * MediaQuery.devicePixelRatioOf(context)).ceil(),
                384,
              ),
              // SR-P1-15：文件存在但解码失败（如损坏 / 非图片内容）
              // 时走与 failed 分支同一口径的失败占位，不留空白框。
              errorBuilder: (context, error, stackTrace) =>
                  failedPlaceholder,
            ),
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
        // 纸面色取 token，与 QuestionSlice 一致：亮色 #FFFDF4 /
        // 深色 #D8DCE2（D1，HTML `--paper`）。旧代码写死 Colors.white，
        // 深色下仍是纯白（R11 §8.3），2026-11-13 修。
        color: DesignTokens.of(Theme.of(context).brightness).paper,
        border: Border.all(
          color: dark ? AppTheme.darkPaperLine : AppTheme.lightPaperLine,
        ),
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
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

/// 学科色（标签 / 圆点 / 数字用）：
/// 亮色用学科本色，深色只用冷雾色（预览 dark --math-ink 等），
/// 不出现大块亮色。
///
/// [stored] 是库里存的学科色（`Subject.color`，S8A2 的 stored 思路）：
/// 预设三科忽略它，仍走主题感知的固定色；新学科没有预设项，亮色下
/// 直接用库里存的轮换色，深色下走 [DesignTokens.subjectColor] 的
/// 同一雾化（SR2-36：不再直接返回存色，不再另造第三份“存色深色
/// 怎么处理”的规则）。不传则按 id 查表（旧行为）。
Color subjectLabelColor(
  BuildContext context,
  String subjectId, [
  Color? stored,
]) {
  final brightness = Theme.of(context).brightness;
  if (stored != null &&
      subjectId != 'math' &&
      subjectId != 'english' &&
      subjectId != 'politics') {
    // SR2-36：委托 DesignTokens.subjectColor——亮色返回存色原值，
    // 深色走与 subjectColor / subjectInk 同一雾化（45% 混 #DCE3EC）。
    return DesignTokens.subjectColor(subjectId, brightness, stored);
  }
  // 没传存色时按 id 查表回退（未知 id 落到数学色）：调用方有库里的
  // Subject 时应传 stored（QuestionSlice / CompactSliceThumb /
  // SubjectLabel 都已传），新学科才不会落到数学色。
  if (brightness != Brightness.dark) return Subject.byId(subjectId).color;
  return switch (subjectId) {
    'english' => AppTheme.darkEnglishMist,
    'politics' => AppTheme.darkPoliticsMist,
    _ => AppTheme.darkMathMist,
  };
}

/// 学科小圆点 + 名称。
///
/// [subject] 是库里读到的学科对象（调用方从 `_subjects` 里找）：
/// 传了就用它的名与存色，新学科不再显示成“数学”+数学色；
/// 不传则走 `Subject.byId` 回退（预设三科旧行为不变）。
class SubjectLabel extends StatelessWidget {
  const SubjectLabel({super.key, required this.subjectId, this.subject});
  final String subjectId;
  final Subject? subject;

  @override
  Widget build(BuildContext context) {
    final s = subject ?? Subject.byId(subjectId);
    final color = subjectLabelColor(context, subjectId, subject?.color);
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

/// 题目图放大浮层（共享；整理工作台、题目详情、复习都用它）：
/// 点图弹出大居中浮层，滚轮缩放，＋/－按钮，点图/点背景/
/// Esc/✕ 关闭。
/// [returnLabel] 是浮层提示里的返回地（默认“整理台”，详情页传“题目详情”）。
/// 文字符号（D3），不用图标字体。
///
/// 打开缩放 = min(1.5, fit)，fit 为纸面刚好完整装进视口的缩放
/// （纸面封顶宽 680、内容高度；标准档 1280×720 下视口 900×~541，
/// fit ≈ 1.32，徽标 132%）。HTML 原型是 fit×1.5、徽标恒 150%，但
/// fit×1.5 在约束维度上必然溢出 50%（打开即裁切），故这里取
/// min(1.5, fit)，保证打开即居中、无裁切——对 HTML 公式的有意偏离。
/// 初始矩阵按视口尺寸算（M = T((1−s)·Vw/2,(1−s)·Vh/2)·S(s)）：
/// InteractiveViewer 的 alignment 默认为 null，矩阵绕 child 原点
/// (0,0) 应用，不是绕视口中心；旧代码用纸面尺寸算平移且假设中心
/// 支点，只在纸面恰为 900×480 时近似成立（垂直 +15px、左右对称
/// 裁切被误读为左移 60–80px）。见 S8A1-ZOOM-REPORT.md。
Future<void> showQuestionZoomDialog(
  BuildContext context,
  Question question, {
  String returnLabel = '整理台',
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _ZoomDialog(
      question: question,
      returnLabel: returnLabel,
    ),
  );
}

class _ZoomDialog extends StatefulWidget {
  const _ZoomDialog({
    required this.question,
    required this.returnLabel,
  });

  final Question question;
  final String returnLabel;

  @override
  State<_ZoomDialog> createState() => _ZoomDialogState();
}

class _ZoomDialogState extends State<_ZoomDialog> {
  late final TransformationController _controller;
  final _paperKey = GlobalKey();
  final _viewportKey = GlobalKey();
  bool _centered = false;
  double _scale = 1.0;
  Size? _viewportSize;

  /// 纸面封顶宽：HTML 规则 min(680px, 86%)，86% 取视口宽。
  static double _paperWidth(double dialogScale) =>
      math.min(680.0, DesignTokens.organizeZoomWidth * dialogScale * 0.86);

  /// fit：纸面刚好完整装进视口的缩放。
  static double _fitFor(Size viewport, Size paper) =>
      math.min(viewport.width / paper.width, viewport.height / paper.height);

  @override
  void initState() {
    super.initState();
    _controller = TransformationController();
    _controller.addListener(_onTransform);
    // 初始矩阵由 _centerInitial 在首帧后按实测尺寸设置（见下）。
    // 不预设 1.5×：InteractiveViewer 的 alignment 默认为 null，
    // 矩阵绕 child 原点 (0,0) 应用；纯缩放矩阵会把纸面顶到左上、
    // 右边裁掉（HTML 的 paperbox 是 left:50%/top:50% 居中放）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _centerInitial());
  }

  void _centerInitial() {
    if (_centered || !mounted) return;
    final viewport = _viewportKey.currentContext?.size;
    final size = _paperKey.currentContext?.size;
    if (viewport == null ||
        size == null ||
        viewport.width <= 0 ||
        viewport.height <= 0 ||
        size.width <= 0 ||
        size.height <= 0) {
      // 尺寸未就绪：下一帧重试。
      WidgetsBinding.instance.addPostFrameCallback((_) => _centerInitial());
      return;
    }
    _centered = true;
    _viewportSize = viewport;
    final s0 = math.min(1.5, _fitFor(viewport, size));
    // 绕视口中心缩放：M = T((1−s0)·Vw/2,(1−s0)·Vh/2)·S(s0)，
    // 平移量用视口尺寸（旧代码用纸面尺寸 −W/4、−H/4，只在纸面
    // 恰为 900×480 时近似成立）。_scale 不预赋值，由 _onTransform
    // 监听到矩阵变化后 setState 更新徽标。
    _controller.value = Matrix4.identity()
      ..translateByDouble(
        (1 - s0) * viewport.width / 2,
        (1 - s0) * viewport.height / 2,
        0,
        1,
      )
      ..scaleByDouble(s0, s0, 1, 1);
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
    // 绕视口中心缩放：M' = T(C)·S(f)·T(−C)·M。
    // 旧代码右乘缩放矩阵，绕视口左上原点缩放，纸面往右下漂移。
    // SR-P2-75：回退视口尺寸用的缩放因子在这里局部取，不要在 build
    // 里给字段赋值（build 内改状态，后续若有人在 build 流程里读它
    // 会拿到上一帧的值）；_multiply 只在按钮/滚轮回调里触发，
    // build 之后，读当前 context 的缩放因子是安全的。
    final dialogScale = qmScaleOf(context);
    final viewport =
        _viewportSize ??
        Size(
          DesignTokens.organizeZoomWidth * dialogScale,
          DesignTokens.organizeZoomHeight * dialogScale - 50 * dialogScale,
        );
    final c = Offset(viewport.width / 2, viewport.height / 2);
    final m = Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..scaleByDouble(factor, factor, 1, 1)
      ..translateByDouble(-c.dx, -c.dy, 0, 1);
    _controller.value = m * _controller.value;
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
                key: _viewportKey,
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
                        child: SizedBox(
                          width: _paperWidth(scale),
                          child: IntrinsicHeight(
                            // B2 Bug 2：与整理页 _paperImage 同因——SizedBox
                            // 680 宽、真图按固有尺寸窄于它。Align 让 Stack 收成切片
                            // 实际尺寸；纸面本身已是左对齐，外观不变。
                            child: Align(
                              alignment: Alignment.topLeft,
                              child: Stack(
                                key: _paperKey,
                                children: [
                                  QuestionSlice(
                                    question: widget.question,
                                    maxHeight: 480,
                                  ),
                                ],
                              ),
                            ),
                          ),
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
