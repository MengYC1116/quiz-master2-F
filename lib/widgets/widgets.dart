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

/// FR-05：切片 Image 的 key——文件路径 + 写盘时间 + 大小。
/// 切片文件被原地重写（重框确认 / 自愈）后，Image 的 provider
/// （同路径 + 同 cacheWidth）与旧图相等，`Image.didUpdateWidget`
/// 不重解码——只清缓存也救不了正在显示的这张图。key 里带写盘时间，
/// 文件一换就强制重建 Image 状态、重新解码（缓存已由
/// evictCachedFileImage 清掉）。stat 失败时回落到纯路径。
String _sliceImageKey(String sliceAbs) {
  try {
    final stat = File(sliceAbs).statSync();
    return '$sliceAbs|${stat.modified.millisecondsSinceEpoch}|${stat.size}';
  } catch (_) {
    return sliceAbs;
  }
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
          // FR-05：key 带写盘时间 + 大小，文件被重写后强制重建 Image
          // 状态、重新解码（provider 相等时 didUpdateWidget 不重解码）。
          key: ValueKey(_sliceImageKey(sliceAbs)),
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
              // FR-05：同 QuestionSlice，key 带写盘时间 + 大小，重框/
              // 自愈后强制重建 Image 状态、重新解码。
              key: ValueKey(_sliceImageKey(sliceAbs!)),
              fit: BoxFit.cover,
              // SR-P2-74：同 QuestionSlice，cacheWidth 乘 devicePixelRatio
              //（64px 逻辑宽 × 2 倍基数 × dpr），封顶 384 防爆内存。
              cacheWidth: math.min(
                (128 * MediaQuery.devicePixelRatioOf(context)).ceil(),
                384,
              ),
              // SR-P1-15：文件存在但解码失败（如损坏 / 非图片内容）
              // 时走与 failed 分支同一口径的失败占位，不留空白框。
              errorBuilder: (context, error, stackTrace) => failedPlaceholder,
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
/// 打开缩放 s0 = min(1.0, fit)，fit 为纸面刚好完整装进视口的缩放
/// （纸面封顶宽 680、内容高度；fit = min(视口宽/纸面布局宽，
/// 视口高/纸面布局高），视口取对话框内容区实测尺寸）。
/// 100% = Flutter 逻辑像素下的纸面自然显示尺寸（纸面布局尺寸 ×1.0），
/// 不是物理像素；放得下就 100%，放不下才按 fit 缩小。
/// InteractiveViewer 的 alignment 保持 null（默认），初始矩阵为绕
/// 视口中心的全变换 T(C)·S(s0)·T(−C)（C 为视口中心），纸面中心
/// 不动、天然居中（旧代码手算平移矩阵且假设中心支点，只在纸面恰为
/// 900×480 时近似成立，见 S8A1-ZOOM-REPORT.md）。不用
/// alignment: Alignment.center：SDK 的手势/边界数学只认控制器矩阵
/// M，alignment 会把有效变换共轭为 T(C)·M·T(−C)，致放大后拖动被
/// 钳制拒绝（定稿 §9.2 步骤 2 与 §9.3 冲突，见定稿附录 REV5 修正）。
/// 两种视图状态（R7-1/S6-2）：初始态（未手动交互）下视口或纸面
/// 尺寸变化时重算 s0 并居中；用户第一次手动缩放/拖动后进入交互态，
/// 此后窗口变化保持当前矩阵；重开对话框回到初始态。
/// 图片就绪（R7-2/S6-3）：QuestionSlice 已布局出非零尺寸且图片
/// 字节已解码（尺寸已知）；未就绪前不应用任何矩阵、不显示错误位置，
/// 滚轮/加减按钮/拖动手势均无动作。
Future<void> showQuestionZoomDialog(
  BuildContext context,
  Question question, {
  String returnLabel = '整理台',
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _ZoomDialog(question: question, returnLabel: returnLabel),
  );
}

class _ZoomDialog extends StatefulWidget {
  const _ZoomDialog({required this.question, required this.returnLabel});

  final Question question;
  final String returnLabel;

  @override
  State<_ZoomDialog> createState() => _ZoomDialogState();
}

class _ZoomDialogState extends State<_ZoomDialog> {
  late final TransformationController _controller;
  final _paperKey = GlobalKey();
  final _viewportKey = GlobalKey();

  /// 用户交互态（R7-1/S6-2）：用户第一次手动缩放（滚轮/按钮）或拖动后
  /// 为 true；交互态下窗口尺寸变化保持当前矩阵，不重算 s0。
  bool _interacted = false;

  /// 图片就绪（R7-2）：QuestionSlice 已布局出非零尺寸且图片字节已解码
  /// （或根本无图片文件可等，如演示题/缺图占位）。未就绪前不应用矩阵、
  /// 禁用缩放与拖动。
  bool _imageSettled = false;

  /// 已为之设过初始矩阵的就绪纸面尺寸（R7-2 守门）：占位尺寸变为真实
  /// 尺寸时触发一次重算；同一尺寸不反复重初始化。
  Size? _readySize;

  /// 加载代次（U4-2）：每个对话框实例一个计数；旧图片的异步回调须先
  /// 核对代次，不符即丢弃，不得污染新实例。
  int _loadGeneration = 0;

  /// 对话框关闭后到达的回调一律忽略（与 mounted 双重校验）。
  bool _disposed = false;

  /// 图片流监听（与 _imageSettled 联动）：只在有真实切片文件时挂接。
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;
  bool _imageListenerAttached = false;

  double _scale = 1.0;
  Size? _viewportSize;

  /// 纸面封顶宽：HTML 规则 min(680px, 86%)，86% 取视口宽。
  static double _paperWidth(double dialogScale) =>
      math.min(680.0, DesignTokens.organizeZoomWidth * dialogScale * 0.86);

  /// fit：纸面刚好完整装进视口的缩放。
  static double _fitFor(Size viewport, Size paper) =>
      math.min(viewport.width / paper.width, viewport.height / paper.height);

  /// 绕视口中心 [center] 的缩放矩阵 T(C)·S(s)·T(−C)（WP-E #9 REV5
  /// 修正：alignment 为 null 时控制器矩阵即有效变换，纸面中心与视口
  /// 中心重合，缩放前后纸面中心不动、天然居中）。
  static Matrix4 _centeredScale(double s, Offset center) =>
      Matrix4.translationValues(center.dx, center.dy, 0.0) *
      Matrix4.diagonal3Values(s, s, 1.0) *
      Matrix4.translationValues(-center.dx, -center.dy, 0.0);

  @override
  void initState() {
    super.initState();
    _controller = TransformationController();
    _controller.addListener(_onTransform);
    // 初始矩阵由 _onReadyFrame 在图片就绪后按实测尺寸设置（见下）。
    // 不预设矩阵：未就绪前不应用任何矩阵、不显示错误位置。
    _scheduleReadyCheck();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureImageListener();
  }

  @override
  void didUpdateWidget(_ZoomDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.question.id != widget.question.id ||
        oldWidget.question.slicePath != widget.question.slicePath) {
      // 同一对话框实例换题（理论上不发生）：全部初始态重置，旧图片的
      // 异步回调凭代次丢弃，不得污染新题。
      _detachImageListener();
      _imageListenerAttached = false;
      _imageSettled = false;
      _readySize = null;
      _interacted = false;
      _loadGeneration++;
      _ensureImageListener();
      _scheduleReadyCheck();
    }
  }

  /// 切片文件（存在才需等解码）：无 slicePath 或文件不存在时显示
  /// 演示文字/缺图占位，布局尺寸首帧即最终尺寸，无需等图片。
  File? _sliceFile() {
    final slicePath = widget.question.slicePath;
    if (slicePath == null) return null;
    // resolveDataPath 为 null（路径不安全）时 QuestionSlice 同样走
    // 缺图占位，无需等图片。
    final abs = AppDatabase.resolveDataPath(slicePath);
    if (abs == null) return null;
    final file = File(abs);
    return file.existsSync() ? file : null;
  }

  /// 与 QuestionSlice._realSliceBody 的 cacheWidth 同式
  /// （maxHeight 480 × 2 × dpr，封顶 2048），使监听的 provider 与
  /// 实际显示的 ResizeImage 同 key、共享同一份解码。
  int _sliceCacheWidth() {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return math.min(((480 * 2) * dpr).ceil(), 2048);
  }

  /// 挂接切片图片的解码监听（U4-2：回调核对实例代次）。
  /// 无图片文件可等时直接记为已就绪。
  void _ensureImageListener() {
    if (_imageListenerAttached || !mounted || _disposed) return;
    final file = _sliceFile();
    if (file == null) {
      _imageSettled = true;
      _imageListenerAttached = true;
      return;
    }
    _imageListenerAttached = true;
    final gen = _loadGeneration;
    _imageListener = ImageStreamListener(
      (ImageInfo info, bool synchronousCall) => _onImageSettled(gen),
      onError: (Object error, StackTrace? stackTrace) =>
          _onImageSettled(gen),
    );
    _imageStream =
        ResizeImage(FileImage(file), width: _sliceCacheWidth()).resolve(
      ImageConfiguration.empty,
    );
    _imageStream!.addListener(_imageListener!);
  }

  void _onImageSettled(int gen) {
    if (!mounted || _disposed || gen != _loadGeneration) return;
    if (_imageSettled) return;
    // 解码成功或解码失败（走缺图占位，尺寸已最终）都算就绪。
    _imageSettled = true;
    _scheduleReadyCheck();
  }

  void _detachImageListener() {
    if (_imageStream != null && _imageListener != null) {
      _imageStream!.removeListener(_imageListener!);
    }
    _imageStream = null;
    _imageListener = null;
  }

  void _scheduleReadyCheck() {
    final gen = _loadGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) => _onReadyFrame(gen));
  }

  /// 就绪检查（每帧后跑一次；仍在初始态时自我续约，以便视口/纸面
  /// 尺寸变化时重算；进入交互态即停）。
  void _onReadyFrame(int gen) {
    if (!mounted || _disposed) return;
    if (gen != _loadGeneration) return;
    if (_interacted) return;
    _ensureImageListener();
    final viewport = _viewportKey.currentContext?.size;
    final size = _paperKey.currentContext?.size;
    if (viewport == null ||
        size == null ||
        viewport.width <= 0 ||
        viewport.height <= 0 ||
        size.width <= 0 ||
        size.height <= 0) {
      // 尺寸未就绪：下一帧重试。
      _scheduleReadyCheck();
      return;
    }
    if (!_imageSettled) {
      // 图片字节未解码（尺寸未知）：不应用任何矩阵、不显示错误位置。
      _scheduleReadyCheck();
      return;
    }
    if (_readySize == size && _viewportSize == viewport) {
      // 已为当前就绪尺寸设过矩阵：不反复重初始化，但继续守望
      // （初始态下视口变化时仍需重算）。
      _scheduleReadyCheck();
      return;
    }
    _loadGeneration++;
    _readySize = size;
    _viewportSize = viewport;
    final s0 = math.min(1.0, _fitFor(viewport, size));
    // 绕视口中心的全变换 T(C)·S(s0)·T(−C)（C 为视口中心；alignment
    // 保持 null，控制器矩阵即有效变换，纸面中心不动、天然居中）。
    // 不用 alignment:center + 纯缩放：SDK 手势/边界数学只认控制器
    // 矩阵 M，alignment 会把有效变换共轭为 T(C)·M·T(−C)，致放大后
    // 拖动被钳制拒绝（见定稿附录 REV5 修正）。_scale 由 _onTransform
    // 监听更新徽标。
    _controller.value =
        _centeredScale(s0, Offset(viewport.width / 2, viewport.height / 2));
    // s0 == 1.0 时矩阵与初值相同、_onTransform 不触发 setState；这里
    // 主动重建一次，让“已就绪”反映到按钮/手势的启用态上。
    // （只在尺寸对变化、真正设矩阵时跑一次，不会每帧重建。）
    setState(() {});
    _scheduleReadyCheck();
  }

  void _onTransform() {
    final s = _controller.value.getMaxScaleOnAxis();
    if ((s - _scale).abs() > 0.005) setState(() => _scale = s);
  }

  @override
  void dispose() {
    _disposed = true;
    _loadGeneration++;
    _detachImageListener();
    _controller.removeListener(_onTransform);
    _controller.dispose();
    super.dispose();
  }

  void _multiply(double factor) {
    // S6-3：图片未就绪时缩放无动作；首次手动缩放进入交互态。
    if (!_imageSettled) return;
    _interacted = true;
    // 绕当前视口中心缩放（alignment 为 null，控制器矩阵即有效变换）：
    // T(C)·S(f)·T(−C)·M（WP-E #9 REV5 修正，改回旧式）。REV5 前本
    // 函数曾为左乘纯缩放 S(f)·M，那是为适配 alignment:center 的共轭
    // （有效变换 T(C)·M·T(−C)）而改的；alignment 回 null 后须改回
    // 本式，否则 ＋/－ 会绕左上角缩放。滚轮/加减按钮仍走本函数。
    final viewport = _viewportKey.currentContext?.size ?? _viewportSize;
    if (viewport == null || viewport.width <= 0 || viewport.height <= 0) {
      // 视口尺寸未知时退回纯缩放（不应发生：就绪门已保证量过视口）。
      _controller.value =
          Matrix4.diagonal3Values(factor, factor, 1.0) * _controller.value;
      return;
    }
    _controller.value = _centeredScale(
            factor, Offset(viewport.width / 2, viewport.height / 2)) *
        _controller.value;
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
                    // S6-3：图片未就绪时按钮禁用（无动作）。
                    onPressed:
                        _imageSettled ? () => _multiply(1.25) : null,
                  ),
                  SizedBox(width: 6 * scale),
                  QmButton(
                    label: '－',
                    variant: QmButtonVariant.plain,
                    size: QmButtonSize.small,
                    onPressed:
                        _imageSettled ? () => _multiply(0.8) : null,
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
                      // S6-3：图片未就绪时滚轮无动作。
                      if (!_imageSettled) return;
                      final s = e.scrollDelta.dy < 0 ? 1.12 : 0.9;
                      _multiply(s);
                    }
                  },
                  child: InteractiveViewer(
                    transformationController: _controller,
                    // WP-E #9 REV5 修正：alignment 保持 null（默认），
                    // 居中由初始矩阵 T(C)·S(s0)·T(−C) 实现；不用
                    // alignment:center——SDK 手势/边界数学只认控制器
                    // 矩阵 M，alignment 会共轭有效变换致放大后拖动
                    // 被钳制拒绝（见定稿附录 REV5 修正）。
                    minScale: 0.5,
                    maxScale: 5,
                    // S6-3：图片未就绪时禁用手势缩放与拖动。
                    panEnabled: _imageSettled,
                    scaleEnabled: _imageSettled,
                    // R7-1：第一次手动缩放/拖动即进入交互态，此后窗口
                    // 尺寸变化保持当前矩阵。
                    onInteractionStart: (_) {
                      if (_imageSettled) _interacted = true;
                    },
                    child: Center(
                      child: GestureDetector(
                        onTap: () => Navigator.of(context).pop(),
                        child: SizedBox(
                          width: _paperWidth(scale),
                          child: IntrinsicHeight(
                            // B2 Bug 2：与整理页 _paperImage 同因——SizedBox
                            // 680 宽、真图按固有尺寸窄于它。Align 让 Stack 收成切片
                            // 实际尺寸（_paperKey 量测仍是切片实际尺寸）；WP-E #9：
                            // 对话框内纸面须在 680 盒内居中。取 center 而非
                            // topCenter：IntrinsicHeight 按盒宽算内在高，窄纸面
                            // 的盒比纸面高（如 200×100 图盒高 340、纸面高 102），
                            // topCenter 会让纸面贴盒顶、垂直偏 119.5px；
                            // center 使纸面在盒内真正居中（§9.3“完整居中”/
                            // §9.4“纸面在正中央”）；全宽纸面盒高即纸面高，
                            // 两者无差别。
                            child: Align(
                              alignment: Alignment.center,
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
