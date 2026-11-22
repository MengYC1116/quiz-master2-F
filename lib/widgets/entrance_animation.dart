import 'package:flutter/material.dart';

/// 入场动效：上移淡入（组合器第六层默认，二十二批 D-247）。
///
/// 主页面（首页 / 错题本列表 / 详情页）挂载时内容轻微上移（8px → 0）
/// + 淡入，250ms、`Curves.easeOut`；列表行可用 [delay] 轻微错开
/// （行号 × 30ms，上限 8 行，调用方算好传进来）。
///
/// - 不做翻卡 / 重铸动画（2026-11-11 已定去掉）。
/// - `MediaQuery.disableAnimations` 为真（系统减弱动效）时直接渲染
///   [child]，不启动动画。
/// - 淡入起点取 0.01 而非 0：`RenderOpacity` 在 alpha == 0 时不参与
///   命中测试，首帧 0.01 视觉上与 0 无异、行仍可点按；动画跑完是 1。
/// - 错开不用 `Future.delayed`：delay 折进一次性的 controller 总时长，
///   用 `Interval` 把动画压到后半段——页面在 delay 内被释放时不会留
///   下待触发的 Timer（否则测试框架在树释放后报 timersPending，
///   见 b19_a_wiring_test 2026-11-22 回归）。
class EntranceFadeSlide extends StatefulWidget {
  const EntranceFadeSlide({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 250),
    this.slideOffset = 8.0,
  });

  final Widget child;

  /// 动画开始前的等待（列表行错开用）。
  final Duration delay;

  /// 动画时长（200–300ms 口径内）。
  final Duration duration;

  /// 入场上移的起始位移（px）。
  final double slideOffset;

  @override
  State<EntranceFadeSlide> createState() => _EntranceFadeSlideState();
}

class _EntranceFadeSlideState extends State<EntranceFadeSlide>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _curve;

  @override
  void initState() {
    super.initState();
    // 总时长 = delay + 动画时长；Interval 把动画压到后半段，
    // 前半段值恒为 0（透明度 0.01、上移满格），与“等 delay 再播”等价。
    final total = widget.delay + widget.duration;
    _controller = AnimationController(duration: total, vsync: this);
    final delayFrac =
        total.inMicroseconds == 0
            ? 0.0
            : widget.delay.inMicroseconds / total.inMicroseconds;
    _curve = CurvedAnimation(
      parent: _controller,
      curve: Interval(delayFrac, 1.0, curve: Curves.easeOut),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 系统减弱动效：不包动画层，直接出内容。
    if (MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }
    return AnimatedBuilder(
      animation: _curve,
      builder: (context, child) {
        final t = _curve.value;
        return Opacity(
          opacity: 0.01 + 0.99 * t,
          child: Transform.translate(
            offset: Offset(0, widget.slideOffset * (1 - t)),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}
