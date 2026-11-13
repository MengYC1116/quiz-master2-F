// quiz-master2 UI Kit（R1）。
//
// 公共组件库：全部形态取自视觉基准 HTML（交互原型
// `quiz-master2-jiao-hu-yuan-xing.html`，SHA256
// `18c8c43485a7831cec22e3d4fff659d7ea39754219b391874f0c5a88f50135e1`）。
// 每个组件头的注释都注明 HTML 来源（选择器 / 类名）。
//
// 约定：
// - 颜色一律取自 [DesignTokens]（亮 / 深两套），组件里不写死色值。
//   学科色只用于圆点 / 数字 / 标签（[DesignTokens.subjectColor]），
//   封面色（[CoverTokens]）只用于错题本封面——本文件不碰封面色。
// - 缩放（D4）：字号不在这里乘——[qmScaleOf] 从 `MediaQuery.textScaler`
//   读出 app.dart 全局乘过的同一因子（标准 1.00 / 大 1.15 / 特大 1.30），
//   布局尺寸（内边距 / 最小高 / 圆角 / 间距）用 [ScaledTokens] 按该因子
//   乘一次；字号只写基准值，由 TextScaler 全局缩放一次。
//   不用 Transform.scale，不重复缩放。
// - 图标（D3）：不用图标字体；符号一律用 [QmGlyphs] 的文字符号
//   （←、＋、×、✓、›、▾、▸）或 CustomPaint 自绘。本文件无 Icon。
// - 交互状态：[_QmPressable] 统一提供 Hover / Focus / Pressed /
//   Disabled；Focus 用 2px accent 描边（HTML `:focus-visible`），
//   未聚焦时描边透明（不占布局、不抖动）；Disabled 一律 opacity .45
//   （HTML `.btn:disabled`），且不可点、不可聚焦。
// - HTML 实读字号 / 间距已在 R2 收入 [DesignTokens]（R1-UIKIT.md §7
//   第 1 项定夺：收入），本文件直接引用 token，不再另设集中表。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/design_tokens.dart';
import '../theme/app_theme.dart' show CompanionWidget;

// ------------------------------------------------------------------ 缩放 --

/// 当前缩放因子：与 app.dart 的 `MediaQuery TextScaler` 同一来源
///（`AppSettings.fontScale`：标准 1.00 / 大 1.15 / 特大 1.30）。
/// 组件用它缩放布局尺寸；字号不乘它（TextScaler 已全局乘过一次）。
double qmScaleOf(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(1.0);

// ------------------------------------------------------- HTML 实读度量 --

// --------------------------------------------------------------- 颜色工具 --

Color _lighten(Color c, double amount) =>
    Color.lerp(c, Colors.white, amount)!;
Color _darken(Color c, double amount) =>
    Color.lerp(c, Colors.black, amount)!;
Color _mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;

// ----------------------------------------------------------- 文字符号 (D3) --

/// 文字符号常量（D3：不用图标字体）。取值全部来自 HTML 原型实际用到的
/// 符号：`←` 返回、`＋` 添加、`×` 关闭/删除、`✓` 选中、`›` 前进箭头、
/// `▾`/`▸` 折叠箭头、`▴` 展开箭头、`⚠` 警告、`ℹ` 信息、`★` 收藏、
/// `⠿` 拖拽柄（错题本目录页 `.nb-toc-drag`）。
abstract final class QmGlyphs {
  static const String back = '←';
  static const String plus = '＋';
  static const String minus = '－';
  static const String close = '×';
  static const String check = '✓';
  static const String chevronRight = '›';
  static const String chevronLeft = '‹';
  static const String chevronDown = '▾';
  static const String chevronRightSmall = '▸';
  static const String chevronUp = '▴';
  static const String dot = '·';
  static const String warning = '⚠';
  static const String info = 'ℹ';
  static const String star = '★';
  static const String drag = '⠿';
  // 左导航文字符号（D3，不用图标字体；HTML 原型导航本身无图标，
  // Flutter 基线有图标，R2 用文字符号保留图标位）：
  // 首页 ⌂ / 收集 ⇪ / 整理 ✎ / 错题本 ▤ / 复习 ↺ / 学习报告 ▦ /
  // 学科管理 ☰ / 设置 ⚙。
  static const String navHome = '⌂';
  static const String navCollect = '⇪';
  static const String navOrganize = '✎';
  static const String navWrongbook = '▤';
  static const String navReview = '↺';
  static const String navReport = '▦';
  static const String navSubjects = '☰';
  static const String navSettings = '⚙';
}

/// 文字符号图标：一个 [Text]，字号取基准值（由 TextScaler 全局缩放）。
class QmGlyph extends StatelessWidget {
  const QmGlyph(
    this.glyph, {
    super.key,
    this.size = 14,
    this.color,
    this.fontWeight,
  });

  final String glyph;
  final double size;
  final Color? color;
  final FontWeight? fontWeight;

  @override
  Widget build(BuildContext context) {
    return Text(
      glyph,
      style: TextStyle(
        fontSize: size,
        color: color ?? Theme.of(context).colorScheme.onSurface,
        fontWeight: fontWeight,
        height: 1,
      ),
    );
  }
}

// ------------------------------------------------------- 交互状态（四态） --

/// [_QmPressable] 回调收到的交互状态。
class QmPressState {
  const QmPressState({
    required this.hovered,
    required this.focused,
    required this.pressed,
    required this.enabled,
  });

  final bool hovered;
  final bool focused;
  final bool pressed;
  final bool enabled;
}

/// 统一的 Hover / Focus / Pressed / Disabled 处理。
///
/// - Hover：MouseRegion（仅 enabled 时响应）。
/// - Focus：Focus 节点；Enter / Space 键触发 onTap；聚焦时外圈画
///   2px accent 描边（HTML `:focus-visible{outline:2px solid
///   var(--accent);outline-offset:2px}`），未聚焦时描边透明，不占布局。
/// - Pressed：GestureDetector 的 onTapDown / onTapUp / onTapCancel。
/// - Disabled（onTap == null）：外包 Opacity .45（HTML
///   `.btn:disabled{opacity:.45}`），不响应悬停/按压/聚焦，鼠标为默认箭头。
class _QmPressable extends StatefulWidget {
  const _QmPressable({
    required this.builder,
    required this.ringRadius,
    this.onTap,
    this.focusNode,
    this.autofocus = false,
    this.semanticLabel,
    this.expanded,
  });

  final Widget Function(BuildContext context, QmPressState state) builder;

  /// 焦点描边圆角（基准值，未缩放；内部按当前缩放因子乘一次）。
  final double ringRadius;
  final VoidCallback? onTap;
  final FocusNode? focusNode;
  final bool autofocus;
  final String? semanticLabel;
  final bool? expanded;

  @override
  State<_QmPressable> createState() => _QmPressableState();
}

class _QmPressableState extends State<_QmPressable> {
  FocusNode? _ownNode;
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  FocusNode get _node => widget.focusNode ?? (_ownNode ??= FocusNode());
  bool get _enabled => widget.onTap != null;

  @override
  void dispose() {
    _ownNode?.dispose();
    super.dispose();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!_enabled) return KeyEventResult.ignored;
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.space)) {
      widget.onTap!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final state = QmPressState(
      hovered: _hovered,
      focused: _focused,
      pressed: _pressed,
      enabled: _enabled,
    );
    final body = MouseRegion(
      cursor: _enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: _enabled ? (_) => setState(() => _hovered = true) : null,
      onExit: _enabled ? (_) => setState(() => _hovered = false) : null,
      child: Focus(
        focusNode: _node,
        autofocus: widget.autofocus,
        canRequestFocus: _enabled,
        onFocusChange: (v) => setState(() => _focused = v),
        onKeyEvent: _onKeyEvent,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: _enabled
              ? (_) {
                  setState(() => _pressed = false);
                  widget.onTap!();
                }
              : null,
          onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: _focused ? palette.accent : Colors.transparent,
                width: 2,
              ),
              borderRadius: BorderRadius.circular(widget.ringRadius * scale),
            ),
            child: widget.builder(context, state),
          ),
        ),
      ),
    );
    final withSemantics = Semantics(
      button: true,
      enabled: _enabled,
      label: widget.semanticLabel,
      expanded: widget.expanded,
      onTap: _enabled ? widget.onTap : null,
      child: body,
    );
    if (!_enabled) {
      return Opacity(opacity: 0.45, child: withSemantics);
    }
    return withSemantics;
  }
}

// ------------------------------------------------------------------ 按钮 --

/// 按钮形态（HTML `.btn` / `.btn.primary` / `.btn.small` /
/// `.org-confirm-big` / `.rev-wrap .btn:not(.primary)`）。
enum QmButtonVariant {
  /// 主按钮：accent 底 + accent-ink 字；深色下是 #7FA8D0 底 + #131A24 深字。
  primary,
  /// 次按钮：白底（surface）蓝字（accent-text）细蓝边（accent 1px），
  /// 悬停 accent-soft 底（HTML `.rev-wrap .btn:not(.primary)`）。
  secondary,
  /// 普通按钮：surface 底 + ink 字 + line-strong 边，悬停 surface-2
  ///（HTML `.btn` 默认态；如「返回书架」「取消」）。
  plain,
  /// 危险按钮：surface 底 + err-ink 字 + err-line 边，悬停 err-bg 底
  ///（HTML 整理台批量删除按钮的行内样式
  /// `color:var(--err-ink);border-color:var(--err-line)`）。
  danger,
  /// 幽灵 / 文字按钮：无底无边 + accent-text 字，悬停 accent-soft 底。
  ghost,
}

/// 按钮尺寸（HTML `.btn` / `.btn.small` / `.org-confirm-big`）。
enum QmButtonSize {
  /// 小按钮：13px 字、6×14 内边距、最小高 34、圆角 10。
  small,
  /// 默认按钮：14px 字、9×20 内边距、最小高 40、圆角 10。
  regular,
  /// 大按钮（整理台底部全宽确认）：17.5px/800 字、16×20 内边距、
  /// 最小高 56、圆角 14。
  large,
}

/// UI Kit 按钮。
///
/// 四种交互状态（HTML `.btn:hover` / `:focus-visible` /
/// `.btn:disabled{opacity:.45}`，Pressed 为 HTML `filter:brightness`
/// 的同等加深）：
/// - Hover：主按钮提亮 7%（HTML `.btn.primary:hover` 的
///   `filter:brightness(1.07)`）；次/普通/危险/幽灵按钮换悬停底色。
/// - Focus：2px accent 外圈描边。
/// - Pressed：主按钮加深 10%，其余换更深的悬停底色。
/// - Disabled（[onPressed] == null）：整体 opacity .45，不可点。
class QmButton extends StatelessWidget {
  const QmButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = QmButtonVariant.primary,
    this.size = QmButtonSize.regular,
    this.leadingGlyph,
    this.trailingGlyph,
    this.block = false,
    this.focusNode,
    this.autofocus = false,
    this.semanticLabel,
  });

  /// 按钮文字。
  final String label;

  /// null 表示 Disabled。
  final VoidCallback? onPressed;
  final QmButtonVariant variant;
  final QmButtonSize size;

  /// 前置 / 后置文字符号（见 [QmGlyphs]），如 `QmGlyphs.back`。
  final String? leadingGlyph;
  final String? trailingGlyph;

  /// true 时占满父级宽度（整理台底部全宽确认按钮形态）。
  final bool block;
  final FocusNode? focusNode;
  final bool autofocus;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scaled = DesignTokens.scaled(scale);

    final double fontSize;
    final double paddingV;
    final double paddingH;
    final double minHeight;
    final double radius;
    final double radiusBase;
    final FontWeight fontWeight;
    switch (size) {
      case QmButtonSize.small:
        fontSize = DesignTokens.smallButtonFontSize;
        paddingV = DesignTokens.smallButtonPaddingV;
        paddingH = DesignTokens.smallButtonPaddingH;
        minHeight = DesignTokens.smallButtonMinHeight;
        radius = scaled.buttonRadius;
        radiusBase = DesignTokens.buttonRadius;
        fontWeight = FontWeight.w700;
      case QmButtonSize.regular:
        fontSize = DesignTokens.buttonFontSize;
        paddingV = DesignTokens.buttonPaddingV;
        paddingH = DesignTokens.buttonPaddingH;
        minHeight = DesignTokens.buttonMinHeight;
        radius = scaled.buttonRadius;
        radiusBase = DesignTokens.buttonRadius;
        fontWeight = FontWeight.w700;
      case QmButtonSize.large:
        fontSize = DesignTokens.largeButtonFontSize;
        paddingV = DesignTokens.largeButtonPaddingV;
        paddingH = DesignTokens.largeButtonPaddingH;
        minHeight = DesignTokens.largeButtonMinHeight;
        radius = DesignTokens.largeButtonRadius * scale;
        radiusBase = DesignTokens.largeButtonRadius;
        fontWeight = FontWeight.w800;
    }

    final button = _QmPressable(
      ringRadius: radiusBase + 2,
      onTap: onPressed,
      focusNode: focusNode,
      autofocus: autofocus,
      semanticLabel: semanticLabel ?? label,
      builder: (context, state) {
        final (Color bg, Color fg, Color? border) =
            _resolve(palette, state, variant);
        return Container(
          constraints: BoxConstraints(
            minHeight: minHeight * scale,
            minWidth: size == QmButtonSize.small ? 0 : 88 * scale,
          ),
          padding: EdgeInsets.symmetric(
            horizontal: paddingH * scale,
            vertical: paddingV * scale,
          ),
          decoration: BoxDecoration(
            color: bg,
            border: border == null
                ? null
                : Border.all(color: border, width: 1),
            borderRadius: BorderRadius.circular(radius),
          ),
          child: Row(
            mainAxisSize: block ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (leadingGlyph != null) ...[
                QmGlyph(leadingGlyph!, size: fontSize, color: fg),
                SizedBox(width: 8 * scale),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: fontWeight,
                  color: fg,
                  height: DesignTokens.controlLineHeight,
                ),
              ),
              if (trailingGlyph != null) ...[
                SizedBox(width: 8 * scale),
                QmGlyph(trailingGlyph!, size: fontSize, color: fg),
              ],
            ],
          ),
        );
      },
    );
    if (block) {
      return SizedBox(width: double.infinity, child: button);
    }
    return button;
  }

  /// 按形态与交互状态解出（底色，字色，边框色）。
  static (Color, Color, Color?) _resolve(
    AppPalette p,
    QmPressState s,
    QmButtonVariant v,
  ) {
    switch (v) {
      case QmButtonVariant.primary:
        final bg = s.pressed
            ? _darken(p.accent, 0.10)
            : s.hovered
                ? _lighten(p.accent, 0.07)
                : p.accent;
        return (bg, p.accentInk, null);
      case QmButtonVariant.secondary:
        final bg = s.pressed
            ? _mix(p.accentSoft, p.accent, 0.12)
            : s.hovered
                ? p.accentSoft
                : p.surface;
        return (bg, p.accentText, p.accent);
      case QmButtonVariant.plain:
        final bg = s.pressed
            ? p.surface3
            : s.hovered
                ? p.surface2
                : p.surface;
        return (bg, p.ink, p.lineStrong);
      case QmButtonVariant.danger:
        final bg = s.pressed
            ? _mix(p.errBg, p.errInk, 0.18)
            : s.hovered
                ? p.errBg
                : p.surface;
        return (bg, p.errInk, p.errLine);
      case QmButtonVariant.ghost:
        final bg = s.pressed
            ? _mix(p.accentSoft, p.accent, 0.12)
            : s.hovered
                ? p.accentSoft
                : Colors.transparent;
        return (bg, p.accentText, null);
    }
  }
}

// ------------------------------------------------------------------ 芯片 --

/// 芯片（HTML `.chip` / `.fchip`）。
///
/// - 未选中：surface 底 + line-strong 边 + ink-2 字。
/// - 选中：accent 填充 + accent-ink 字（HTML
///   `.chip[aria-pressed="true"]`）；传 [subjectId] 时选中填充改用
///   学科色（HTML `.fchip.subj-math[aria-pressed="true"]` 等，
///   深色下选中字色为 #1E2228，即深色底色）。传 [storedColor] 时
///   新学科用库里存的色，预设三科仍走主题固定色。
/// - 可删除（[onDelete] 非空）：`.err-sel-chip` 形态——accent-soft 底 +
///   accent 边 + accent-text 字，尾部带 ` ✕`；悬停变 err-bg / err-line /
///   err-ink。只传 [onDelete] 不传 [onTap] 时整片点按即删除；两者都传
///   时点片身切换、点 `×` 删除。
/// - 预置标签：[presetTags]（易错 / 常考 / 需重做，HTML 整理台标签栏）。
class QmChip extends StatelessWidget {
  const QmChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.onDelete,
    this.subjectId,
    this.storedColor,
    this.focusNode,
    this.semanticLabel,
    this.displayOnly = false,
  });

  /// 预置标签（HTML 整理台标签栏：易错 / 常考 / 需重做）。
  static const List<String> presetTags = ['易错', '常考', '需重做'];

  final String label;
  final bool selected;

  /// null 表示不可点（纯展示）。
  final VoidCallback? onTap;

  /// 非空表示可删除芯片（`.err-sel-chip` 形态）。
  final VoidCallback? onDelete;

  /// 学科 id（`math` / `english` / `politics`）：选中态用学科色填充。
  /// 不传则选中态用 accent 填充。
  final String? subjectId;

  /// 库里存的学科色（`Subject.color`，S8A2 的 stored 思路）：
  /// 预设三科忽略它，仍走主题固定色；新学科用它填充，选中态不再
  /// 落到数学色。不传则按 id 查表（旧行为）。
  final Color? storedColor;
  final FocusNode? focusNode;
  final String? semanticLabel;

  /// 展示态（R2 收口 `widgets.dart` 的 `InfoChip` 用）：只展示、不交互，
  /// 不包 `_QmPressable`——否则 `onTap == null` 会被当成 Disabled
  ///（opacity .45）。交互芯片不要传此参数。
  final bool displayOnly;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final brightness = Theme.of(context).brightness;
    final palette = DesignTokens.of(brightness);
    final deletable = onDelete != null;
    final bool bothZones = deletable && onTap != null;

    final fill = subjectId == null
        ? palette.accent
        : DesignTokens.subjectColor(subjectId!, brightness, storedColor);
    // HTML 深色下学科选中芯片的字色是 #1E2228（深色底色），见
    // `:root[data-theme="dark"] .fchip.subj-*[aria-pressed="true"]`。
    final selectedFg = subjectId == null
        ? palette.accentInk
        : brightness == Brightness.dark
            ? DesignTokens.dark.background
            : Colors.white;

    Widget labelText(Color fg) => Text(
          deletable && !bothZones ? '$label ✕' : label,
          style: TextStyle(
            fontSize: DesignTokens.chipFontSize,
            fontWeight: FontWeight.w700,
            color: fg,
            height: DesignTokens.controlLineHeight,
          ),
        );

    // 展示态（R2 收口 InfoChip 用）：与未选中芯片同一视觉（surface 底 /
    // line-strong 边 / ink-2 字），不包 _QmPressable，不响应交互。
    if (displayOnly) {
      final fill = subjectId == null
          ? palette.accent
          : DesignTokens.subjectColor(subjectId!, brightness, storedColor);
      final bg = selected ? fill : palette.surface;
      final fg = selected ? selectedFg : palette.ink2;
      final border = selected ? fill : palette.lineStrong;
      return Container(
        padding: EdgeInsets.symmetric(
          horizontal: DesignTokens.chipPaddingH * scale,
          vertical: DesignTokens.chipPaddingV * scale,
        ),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border, width: 1),
          borderRadius: BorderRadius.circular(999 * scale),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              QmGlyph(QmGlyphs.check,
                  size: DesignTokens.chipFontSize, color: fg),
              SizedBox(width: 4 * scale),
            ],
            labelText(fg),
          ],
        ),
      );
    }

    // 可删除芯片：.err-sel-chip 形态（accent-soft 底 / accent 边 /
    // accent-text 字，悬停 err 系）。
    if (deletable) {
      final chip = _QmPressable(
        ringRadius: 999,
        onTap: onTap ?? onDelete,
        focusNode: focusNode,
        semanticLabel: semanticLabel ?? label,
        builder: (context, state) {
          final bg = state.pressed
              ? _mix(palette.errBg, palette.errInk, 0.18)
              : state.hovered
                  ? palette.errBg
                  : palette.accentSoft;
          final fg =
              state.hovered || state.pressed ? palette.errInk : palette.accentText;
          final border =
              state.hovered || state.pressed ? palette.errLine : palette.accent;
          return Container(
            padding: EdgeInsets.symmetric(
              horizontal: DesignTokens.deletableChipPaddingH * scale,
              vertical: DesignTokens.deletableChipPaddingV * scale,
            ),
            decoration: BoxDecoration(
              color: bg,
              border: Border.all(color: border, width: 1),
              borderRadius: BorderRadius.circular(999 * scale),
            ),
            child: bothZones
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onTap,
                        child: labelText(fg),
                      ),
                      SizedBox(width: 4 * scale),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onDelete,
                        child: QmGlyph(
                          QmGlyphs.close,
                          size: DesignTokens.captionFontSize,
                          color: fg,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  )
                : labelText(fg),
          );
        },
      );
      return chip;
    }

    return _QmPressable(
      ringRadius: 999,
      onTap: onTap,
      focusNode: focusNode,
      semanticLabel: semanticLabel ?? label,
      builder: (context, state) {
        final Color bg;
        final Color fg;
        final Color border;
        if (selected) {
          bg = state.pressed ? _darken(fill, 0.10) : fill;
          fg = selectedFg;
          border = fill;
        } else {
          bg = state.pressed
              ? palette.surface3
              : state.hovered
                  ? palette.surface2
                  : palette.surface;
          fg = palette.ink2;
          border = palette.lineStrong;
        }
        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: DesignTokens.chipPaddingH * scale,
            vertical: DesignTokens.chipPaddingV * scale,
          ),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border, width: 1),
            borderRadius: BorderRadius.circular(999 * scale),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                QmGlyph(QmGlyphs.check,
                    size: DesignTokens.chipFontSize, color: fg),
                SizedBox(width: 4 * scale),
              ],
              labelText(fg),
            ],
          ),
        );
      },
    );
  }
}

// --------------------------------------------------------------- 输入框 --

/// 文本输入框（HTML `.toolbar input[type="text"]` / `[type="search"]`：
/// surface 底、line-strong 边、圆角 12、padding 9×13、14px、最小高 40）。
/// 聚焦时 2px accent 描边（与 [_QmPressable] 的 focus 形态一致，
// [TextField] 自带 focus 边框已关掉，改由外层容器画）。
class QmTextField extends StatefulWidget {
  const QmTextField({
    super.key,
    required this.controller,
    this.hintText,
    this.onSubmitted,
    this.onChanged,
    this.autofocus = false,
    this.maxLength,
    this.enabled = true,
    this.focusNode,
    this.semanticLabel,
  });

  final TextEditingController controller;
  final String? hintText;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final bool autofocus;
  final int? maxLength;
  final bool enabled;
  final FocusNode? focusNode;
  final String? semanticLabel;

  @override
  State<QmTextField> createState() => _QmTextFieldState();
}

class _QmTextFieldState extends State<QmTextField> {
  late final FocusNode _innerFocus;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _innerFocus = widget.focusNode ?? FocusNode();
    _innerFocus.addListener(_onFocus);
  }

  void _onFocus() {
    if (!mounted) return;
    setState(() => _focused = _innerFocus.hasFocus);
  }

  @override
  void dispose() {
    _innerFocus.removeListener(_onFocus);
    if (widget.focusNode == null) _innerFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Opacity(
      opacity: widget.enabled ? 1 : 0.45,
      child: Container(
        constraints:
            BoxConstraints(minHeight: R10Tokens.inputMinHeight * scale),
        padding: EdgeInsets.symmetric(
          horizontal: R10Tokens.inputPaddingH * scale,
          vertical: R10Tokens.inputPaddingV * scale,
        ),
        decoration: BoxDecoration(
          color: palette.surface,
          border: Border.all(
            color: _focused ? palette.accent : palette.lineStrong,
            width: _focused ? 2 : 1,
          ),
          borderRadius:
              BorderRadius.circular(DesignTokens.scaled(scale).radiusLg),
        ),
        alignment: Alignment.centerLeft,
        child: TextField(
          controller: widget.controller,
          focusNode: _innerFocus,
          autofocus: widget.autofocus,
          enabled: widget.enabled,
          maxLength: widget.maxLength,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
          onSubmitted: widget.onSubmitted,
          onChanged: widget.onChanged,
          style: TextStyle(
            fontSize: R10Tokens.inputFontSize,
            color: palette.ink,
            height: DesignTokens.controlLineHeight,
          ),
          decoration: InputDecoration(
            hintText: widget.hintText,
            hintStyle: TextStyle(
              fontSize: R10Tokens.inputFontSize,
              color: palette.muted,
            ),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            isDense: true,
            contentPadding: EdgeInsets.zero,
            counterText: '',
          ),
        ),
      ),
    );
  }
}

// --------------------------------------------------------- 封面样式小图 --

/// 错题本封面样式小图（HTML `.cover-mini`：52×68、书脊在左、
// 圆角 4 8 8 4、中间是学科首字 19px/800 白字）。
/// 纹路由 [_QmCoverMiniPainter] 自绘（与错题本 `_CoverPatternPainter`
/// 同一套 Flutter 样式 key：plain / lines / dots / grid / diagonal /
/// double；HTML key bands/diag/frame 不用，存储值不变）。
class QmCoverMini extends StatelessWidget {
  const QmCoverMini({
    super.key,
    required this.style,
    required this.color,
    required this.character,
    this.selected = false,
    this.onTap,
  });

  /// 封面样式 key（`CoverStyles.all` 之一）。
  final String style;

  /// 封面底色（`CoverTokens.of(colorKey)` 的解出值）。
  final Color color;

  /// 中间显示的首字（如学科名首字）。
  final String character;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final mini = Container(
      width: R10Tokens.coverMiniWidth * scale,
      height: R10Tokens.coverMiniHeight * scale,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(4 * scale),
          topRight: Radius.circular(8 * scale),
          bottomRight: Radius.circular(8 * scale),
          bottomLeft: Radius.circular(4 * scale),
        ),
        boxShadow: [
          BoxShadow(
            offset: const Offset(3, 0),
            blurRadius: 5,
            color: Colors.black.withValues(alpha: 0.20),
          ),
          BoxShadow(
            offset: const Offset(0, 3),
            blurRadius: 8,
            color: Colors.black.withValues(alpha: 0.18),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(4 * scale),
          topRight: Radius.circular(8 * scale),
          bottomRight: Radius.circular(8 * scale),
          bottomLeft: Radius.circular(4 * scale),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(painter: _QmCoverMiniPainter(style)),
            ),
            Center(
              child: Text(
                character,
                style: const TextStyle(
                  fontSize: R10Tokens.coverMiniCharFontSize,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  shadows: [
                    Shadow(
                      offset: Offset(0, 1),
                      blurRadius: 3,
                      color: Color.fromRGBO(0, 0, 0, 0.25),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    final wrapped = Container(
      padding: EdgeInsets.all(5 * scale),
      decoration: BoxDecoration(
        color: selected ? palette.accentSoft : Colors.transparent,
        border: Border.all(
          color: selected ? palette.accent : Colors.transparent,
          width: 2,
        ),
        borderRadius:
            BorderRadius.circular(DesignTokens.scaled(scale).radius),
      ),
      child: mini,
    );
    if (onTap == null) return wrapped;
    return _QmPressable(
      ringRadius: DesignTokens.radius,
      onTap: onTap,
      semanticLabel: character,
      builder: (context, state) => wrapped,
    );
  }
}

class _QmCoverMiniPainter extends CustomPainter {
  _QmCoverMiniPainter(this.style);
  final String style;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..strokeWidth = 1.5;
    switch (style) {
      case 'lines':
        for (var y = 14.0; y < size.height; y += 14) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        }
      case 'dots':
        for (var y = 10.0; y < size.height; y += 13) {
          for (var x = 9.0; x < size.width; x += 13) {
            canvas.drawCircle(Offset(x, y), 1.3, paint);
          }
        }
      case 'grid':
        for (var x = 14.0; x < size.width; x += 14) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
        }
        for (var y = 14.0; y < size.height; y += 14) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        }
      case 'diagonal':
        for (var i = -4; i < 8; i++) {
          final x = i * 14.0;
          canvas.drawLine(
            Offset(x, size.height),
            Offset(x + size.height, 0),
            paint,
          );
        }
      case 'double':
        canvas.drawRect(
          Rect.fromLTWH(5, 5, size.width - 10, size.height - 10),
          paint,
        );
        canvas.drawRect(
          Rect.fromLTWH(9, 9, size.width - 18, size.height - 18),
          paint,
        );
      case 'plain':
        final fold = Path()
          ..moveTo(size.width - 14, 0)
          ..lineTo(size.width, 14)
          ..lineTo(size.width, 0)
          ..close();
        canvas.drawPath(
          fold,
          Paint()..color = Colors.white.withValues(alpha: 0.28),
        );
    }
  }

  @override
  bool shouldRepaint(covariant _QmCoverMiniPainter oldDelegate) =>
      oldDelegate.style != style;
}

// --------------------------------------------------------------- 分段控件 --

/// 分段控件的一个选项。
class QmSegmentOption<T> {
  const QmSegmentOption({required this.value, required this.label});

  final T value;
  final String label;
}

/// 分段控件（HTML `.seg`）。
///
/// 外框 line-strong 边 + 999 圆角 + surface 底；未选中段 muted 字，
/// 悬停 surface-2；选中段 accent 填充 + accent-ink 字
///（HTML `.seg button[aria-pressed="true"]`）。
/// 用于主题三段、字体三段、视图切换（大卡片 / 紧凑列表）等。
class QmSegmented<T> extends StatelessWidget {
  const QmSegmented({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<QmSegmentOption<T>> options;
  final T value;

  /// null 表示整体 Disabled（opacity .45，不可点）。
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final enabled = onChanged != null;
    final body = Container(
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(color: palette.lineStrong, width: 1),
        borderRadius: BorderRadius.circular(999 * scale),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999 * scale),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in options)
              _QmPressable(
                ringRadius: 999,
                onTap: enabled ? () => onChanged!(option.value) : null,
                semanticLabel: option.label,
                builder: (context, state) {
                  final selected = option.value == value;
                  final bg = selected
                      ? (state.pressed
                          ? _darken(palette.accent, 0.10)
                          : palette.accent)
                      : state.pressed
                          ? palette.surface3
                          : state.hovered
                              ? palette.surface2
                              : Colors.transparent;
                  final fg = selected ? palette.accentInk : palette.muted;
                  return Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: DesignTokens.segmentedPaddingH * scale,
                      vertical: DesignTokens.segmentedPaddingV * scale,
                    ),
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: BorderRadius.circular(999 * scale),
                    ),
                    child: Text(
                      option.label,
                      style: TextStyle(
                        fontSize: DesignTokens.segmentedFontSize,
                        fontWeight: FontWeight.w600,
                        color: fg,
                        height: DesignTokens.controlLineHeight,
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
    if (!enabled) {
      return Opacity(opacity: 0.45, child: body);
    }
    return body;
  }
}

// --------------------------------------------------------------- 状态药丸 --

/// 错因状态（HTML 复习 / 错题本 `.status` 四档，见 [QmStatusPill.cause]）。
enum QmCauseStatus {
  /// 待解决：warn 系（HTML `.status.todo`）。
  pending,

  /// 解决中：info 系（HTML `.status.doing`）。
  inProgress,

  /// 已解决：accent-soft 系（HTML `.status.done`）。
  solved,

  /// 复查：err 系（HTML `.status.fail`）。
  recheck,
}

extension QmCauseStatusLabel on QmCauseStatus {
  String get label => switch (this) {
        QmCauseStatus.pending => '待解决',
        QmCauseStatus.inProgress => '解决中',
        QmCauseStatus.solved => '已解决',
        QmCauseStatus.recheck => '复查',
      };
}

/// 通用提示色调（HTML `.banner` / `.pill` 三档）。
enum QmTone {
  /// warn 系（warn-bg / warn-ink）。
  warn,

  /// err 系（err-bg / err-ink）。
  error,

  /// info 系（info-bg / info-ink）。
  info,
}

/// 状态药丸（HTML `.pill` / `.status`：999 圆角、12px/700 字、
/// `padding:1px 9px`）。
///
/// - [QmStatusPill.cause]：错因四态（待解决 / 解决中 / 已解决 / 复查），
///   颜色映射与 HTML `causePill()` / `detailCauseStatus()` 一致。
/// - [QmStatusPill.tone]：warn / err / info 三色提示形态。
class QmStatusPill extends StatelessWidget {
  const QmStatusPill({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
  }) : _resolve = null;

  const QmStatusPill._resolved({
    super.key,
    required this.label,
    required this._resolve,
  })  : background = null,
        foreground = null;

  /// 错因状态药丸。
  factory QmStatusPill.cause(QmCauseStatus status, {Key? key}) {
    return QmStatusPill._resolved(
      key: key,
      label: status.label,
      resolve: (p) => switch (status) {
        QmCauseStatus.pending => (p.warnBg, p.warnInk),
        QmCauseStatus.inProgress => (p.infoBg, p.infoInk),
        QmCauseStatus.solved => (p.accentSoft, p.accentText),
        QmCauseStatus.recheck => (p.errBg, p.errInk),
      },
    );
  }

  /// 三色提示药丸。
  factory QmStatusPill.tone({
    required String label,
    required QmTone tone,
    Key? key,
  }) {
    return QmStatusPill._resolved(
      key: key,
      label: label,
      resolve: (p) => switch (tone) {
        QmTone.warn => (p.warnBg, p.warnInk),
        QmTone.error => (p.errBg, p.errInk),
        QmTone.info => (p.infoBg, p.infoInk),
      },
    );
  }

  final String label;
  final Color? background;
  final Color? foreground;
  final (Color, Color) Function(AppPalette palette)? _resolve;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final (Color bg, Color fg) = _resolve != null
        ? _resolve(DesignTokens.of(Theme.of(context).brightness))
        : (background!, foreground!);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: DesignTokens.pillPaddingH * scale,
        vertical: 1 * scale,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999 * scale),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: DesignTokens.pillFontSize,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------- 横幅 --

/// 横幅色调（HTML `.banner.err` / `.banner.warn`；info 档取
/// `.mode-banner` 的 info-bg / info-ink + accent 边）。
enum QmBannerTone { error, warning, info }

/// 横幅内嵌的操作按钮。
class QmBannerAction {
  const QmBannerAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;
}

/// 顶部提示横幅（HTML `.banner`：radius 12、padding 12×16、14px 字、
/// 下边距 18px；err 红 / warn 黄 / info 蓝三档；右侧按钮
/// `border:1px solid currentColor`、radius 10、padding 4×14、13px/700）。
///
/// - err：错误态横幅（HTML 首页备份失败 `.banner err`）。
/// - warning：重复文件 / 超限 / 已归档提示（HTML `.banner warn`）。
/// - info：信息提示（HTML `.mode-banner` 形态）。
/// [onDismiss] 非空时右端显示「知道了」关闭按钮（默认文案可改）；
/// [actions] 用于「仍然再导一份 / 不导了」这类并排操作。
class QmBanner extends StatelessWidget {
  const QmBanner({
    super.key,
    required this.tone,
    required this.message,
    this.title,
    this.actions = const [],
    this.onDismiss,
    this.dismissLabel = '知道了',
    this.margin,
  });

  final QmBannerTone tone;

  /// 正文；[title] 非空时以粗体显示在正文之前（HTML 横幅里的 `<b>` 前导句）。
  final String message;
  final String? title;
  final List<QmBannerAction> actions;
  final VoidCallback? onDismiss;
  final String dismissLabel;

  /// 默认下边距 18（HTML `.banner{margin-bottom:18px}`）。
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final (Color bg, Color fg, Color line, double lineWidth, String glyph) =
        switch (tone) {
      QmBannerTone.error => (
          palette.errBg,
          palette.errInk,
          palette.errLine,
          1.0,
          QmGlyphs.warning,
        ),
      QmBannerTone.warning => (
          palette.warnBg,
          palette.warnInk,
          palette.warnLine,
          1.0,
          QmGlyphs.warning,
        ),
      QmBannerTone.info => (
          palette.infoBg,
          palette.infoInk,
          palette.accent,
          1.5,
          QmGlyphs.info,
        ),
    };
    final glyphWidget = Padding(
      padding: EdgeInsets.only(top: 1 * scale),
      child: QmGlyph(glyph, size: 15, color: fg),
    );
    final textWidget = Text.rich(
      TextSpan(
        style: TextStyle(
          fontSize: DesignTokens.bannerFontSize,
          color: fg,
          height: DesignTokens.bodyLineHeight,
        ),
        children: [
          if (title != null)
            TextSpan(
              text: title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          TextSpan(text: message),
        ],
      ),
    );
    final buttonWidgets = <Widget>[
      for (final action in actions)
        _BannerButton(
          label: action.label,
          onPressed: action.onPressed,
          color: fg,
        ),
      if (onDismiss != null)
        _BannerButton(
          label: dismissLabel,
          onPressed: onDismiss!,
          color: fg,
        ),
    ];
    return Container(
      margin: margin ?? EdgeInsets.only(bottom: 18 * scale),
      padding: EdgeInsets.symmetric(
        horizontal: DesignTokens.bannerPaddingH * scale,
        vertical: DesignTokens.bannerPaddingV * scale,
      ),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: line, width: lineWidth),
        borderRadius: BorderRadius.circular(
          DesignTokens.scaled(scale).radius,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 一行能否放下整条横幅（图标 + 按钮 + 至少 48px 正文）：
          // Row 给非 flex 子节点无限宽约束，按钮区的 Wrap 在 Row 里永远
          // 不换行，窄宽下会直接溢出；放不下时改走上下两行（正文在上、
          // 按钮另起一行右对齐），Column 给子节点紧宽度约束，Wrap 在
          // 那里才能正常换行。按钮文本宽用 TextPainter 实测，不估算。
          final fits = _bannerFitsOneLine(
            context,
            constraints.maxWidth,
            scale,
            buttonWidgets.length,
            [
              for (final action in actions) action.label,
              if (onDismiss != null) dismissLabel,
            ],
          );
          if (fits) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                glyphWidget,
                SizedBox(width: 10 * scale),
                Expanded(child: textWidget),
                SizedBox(width: 10 * scale),
                Wrap(
                  spacing: 6 * scale,
                  runSpacing: 6 * scale,
                  alignment: WrapAlignment.end,
                  children: buttonWidgets,
                ),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  glyphWidget,
                  SizedBox(width: 10 * scale),
                  Expanded(child: textWidget),
                ],
              ),
              if (buttonWidgets.isNotEmpty) ...[
                SizedBox(height: 8 * scale),
                Wrap(
                  spacing: 6 * scale,
                  runSpacing: 6 * scale,
                  alignment: WrapAlignment.end,
                  children: buttonWidgets,
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// 横幅一行布局是否放得下：图标 + 间隙 + 按钮区 + 内边距 + 至少 48px 正文。
bool _bannerFitsOneLine(
  BuildContext context,
  double maxWidth,
  double scale,
  int buttonCount,
  List<String> labels,
) {
  if (!maxWidth.isFinite) return true;
  final scaler = MediaQuery.textScalerOf(context);
  final dir = Directionality.of(context);
  double textWidth(String text, double fontSize, FontWeight weight) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: fontSize, fontWeight: weight),
      ),
      textScaler: scaler,
      textDirection: dir,
    )..layout();
    return painter.width;
  }

  var buttonsWidth = 0.0;
  for (final label in labels) {
    // 文本宽 + 横向内边距 + 8px 余量（按钮外圈 2px 焦点边框等实测占位）。
    buttonsWidth += textWidth(
          label,
          DesignTokens.captionFontSize,
          FontWeight.w700,
        ) +
        2 * DesignTokens.bannerButtonPaddingH * scale +
        8;
  }
  if (buttonCount > 1) {
    buttonsWidth += (buttonCount - 1) * 6 * scale;
  }
  final needed = 2 * DesignTokens.bannerPaddingH * scale +
      textWidth('⚠', 15, FontWeight.w400) +
      2 * 10 * scale +
      buttonsWidth +
      48;
  return needed <= maxWidth;
}

/// 横幅内的小按钮（HTML `.banner button`：currentColor 细边、radius 10）。
class _BannerButton extends StatelessWidget {
  const _BannerButton({
    required this.label,
    required this.onPressed,
    required this.color,
  });

  final String label;
  final VoidCallback onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    return _QmPressable(
      ringRadius: DesignTokens.buttonRadius,
      onTap: onPressed,
      semanticLabel: label,
      builder: (context, state) {
        final bg = state.pressed
            ? color.withValues(alpha: 0.18)
            : state.hovered
                ? color.withValues(alpha: 0.08)
                : Colors.transparent;
        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: DesignTokens.bannerButtonPaddingH * scale,
            vertical: DesignTokens.bannerButtonPaddingV * scale,
          ),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: color, width: 1),
            borderRadius: BorderRadius.circular(
              DesignTokens.scaled(scale).buttonRadius,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: DesignTokens.captionFontSize,
              fontWeight: FontWeight.w700,
              color: color,
              height: DesignTokens.controlLineHeight,
            ),
          ),
        );
      },
    );
  }
}

// --------------------------------------------------------------- 空状态 --

/// 空状态（HTML `.empty`：1.5px 虚线 line-strong 边、radius-lg 16、
/// padding 52×30、居中；标题 17px/700 ink-2；说明 14px muted；
/// 小伙伴在上）。
///
/// 复用 [CompanionWidget]（不重画小伙伴）。与 `widgets.dart` 的
/// `EmptyState`（无边框简化版）不同，本组件是 HTML 忠实形态，
/// 供 R2 各页替换使用。
class QmEmptyState extends StatelessWidget {
  const QmEmptyState({
    super.key,
    required this.title,
    this.description,
    this.actionLabel,
    this.onAction,
    this.companionSize = 72,
    this.actionVariant = QmButtonVariant.primary,
  });

  final String title;
  final String? description;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 小伙伴尺寸（基准值，按缩放换算）。
  final double companionSize;
  final QmButtonVariant actionVariant;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return CustomPaint(
      painter: _DashedRoundedRectPainter(
        color: palette.lineStrong,
        radius: DesignTokens.scaled(scale).radiusLg,
        strokeWidth: 1.5,
      ),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          horizontal: DesignTokens.emptyPaddingH * scale,
          vertical: DesignTokens.emptyPaddingV * scale,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CompanionWidget(size: companionSize * scale),
            SizedBox(height: 10 * scale),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: DesignTokens.emptyTitleFontSize,
                fontWeight: FontWeight.w700,
                color: palette.ink2,
              ),
            ),
            if (description != null) ...[
              SizedBox(height: 6 * scale),
              Text(
                description!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: DesignTokens.bannerFontSize,
                  color: palette.muted,
                  height: DesignTokens.bodyLineHeight,
                ),
              ),
            ],
            if (actionLabel != null) ...[
              SizedBox(height: 18 * scale),
              QmButton(
                label: actionLabel!,
                onPressed: onAction,
                variant: actionVariant,
                size: QmButtonSize.regular,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 虚线圆角矩形描边（HTML `.empty` 的 `1.5px dashed` 边框）。
class _DashedRoundedRectPainter extends CustomPainter {
  const _DashedRoundedRectPainter({
    required this.color,
    required this.radius,
    this.strokeWidth = 1.5,
  });

  final Color color;
  final double radius;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      strokeWidth / 2,
      strokeWidth / 2,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        const dashWidth = 6.0;
        const dashGap = 4.0;
        final length = math.min(dashWidth, metric.length - distance);
        canvas.drawPath(metric.extractPath(distance, distance + length), paint);
        distance += dashWidth + dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRoundedRectPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.radius != radius ||
      oldDelegate.strokeWidth != strokeWidth;
}

// --------------------------------------------------------------- 行分隔线 --

/// 行分隔线形态。
enum QmRowLineKind {
  /// 普通列表虚线（HTML `.kv` / `.mgrow` 的 `1px dashed var(--line)`）。
  line,

  /// 纸面虚线（HTML 目录页 `.nb-toc-row` / `.nb-prow` 的
  /// `1px dashed var(--paper-line)`，用在纸面背景的行上）。
  paper,
}

/// 列表行分隔线（HTML 目录页 / 列表页的虚线分隔形态）。
///
/// 虚线画法与 `widgets.dart` 的 `DashedDivider` 一致（4px 实线 + 3px
/// 间隔），颜色取 token（line / paper-line）。
class QmRowLine extends StatelessWidget {
  const QmRowLine({super.key, this.kind = QmRowLineKind.line});

  final QmRowLineKind kind;

  @override
  Widget build(BuildContext context) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final color =
        kind == QmRowLineKind.paper ? palette.paperLine : palette.line;
    return SizedBox(
      height: 1,
      width: double.infinity,
      child: CustomPaint(painter: _QmDashedLinePainter(color)),
    );
  }
}

class _QmDashedLinePainter extends CustomPainter {
  const _QmDashedLinePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(Offset(x, 0.5), Offset(x + 4, 0.5), paint);
      x += 7;
    }
  }

  @override
  bool shouldRepaint(covariant _QmDashedLinePainter oldDelegate) =>
      oldDelegate.color != color;
}

// --------------------------------------------------------------- 折叠段 --

/// 折叠段形态（HTML 三种折叠头共用一个组件，差异只在头样式）：
/// - [QmFoldVariant.group]：设置五组 / 学科管理四组（HTML
///   `.set-group` / `.set-group-head`：surface-2 头底、16.5px/800 标题、
///   13×18 内边距、最小高 48、悬停 surface-3、箭头 `▾ 收起` / `▸ 展开`）。
/// - [QmFoldVariant.form]：整理表单五段（HTML `.org-sec` /
///   `.org-sec-head`：14.5px/800 标题、11×16 内边距、最小高 44）。
/// - [QmFoldVariant.detail]：详情三段（HTML `.dt-fold` /
///   `.dt-fold-head`：无头底、15px/800 标题、箭头只有 `▾` / `▸`）。
enum QmFoldVariant { group, form, detail }

/// 折叠段。
///
/// 一次只开一段的互斥逻辑由调用方控制：调用方持有各段的展开态，
/// 本组件只提供展开态展示与 [onToggle] 回调（点头部时调用，
/// 调用方翻转该段的展开态并收起其他段）。
class QmFoldSection extends StatelessWidget {
  const QmFoldSection({
    super.key,
    required this.title,
    this.subtitle,
    required this.expanded,
    required this.onToggle,
    required this.child,
    this.variant = QmFoldVariant.group,
    this.focusNode,
  });

  final String title;

  /// 副标题（HTML `.org-sec-head .os-sub`，12.5px/600 muted），
  /// 如整理表单的「知识点 · 错误类型 · 标签」。
  final String? subtitle;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;
  final QmFoldVariant variant;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scaled = DesignTokens.scaled(scale);

    final double titleFontSize;
    final double headPaddingV;
    final double headPaddingH;
    final double minHeight;
    final double radius;
    final double radiusBase;
    final bool headFilled;
    final bool hoverable;
    final EdgeInsets bodyPadding;
    switch (variant) {
      case QmFoldVariant.group:
        titleFontSize = DesignTokens.foldGroupTitleFontSize;
        headPaddingV = 13;
        headPaddingH = 18;
        minHeight = 48;
        radius = scaled.radiusLg;
        radiusBase = DesignTokens.radiusLg;
        headFilled = true;
        hoverable = true;
        bodyPadding = EdgeInsets.fromLTRB(
          18 * scale,
          2 * scale,
          18 * scale,
          18 * scale,
        );
      case QmFoldVariant.form:
        titleFontSize = DesignTokens.foldFormTitleFontSize;
        headPaddingV = 11;
        headPaddingH = 16;
        minHeight = 44;
        radius = scaled.radiusLg;
        radiusBase = DesignTokens.radiusLg;
        headFilled = true;
        hoverable = false;
        bodyPadding = EdgeInsets.fromLTRB(
          18 * scale,
          2 * scale,
          18 * scale,
          16 * scale,
        );
      case QmFoldVariant.detail:
        titleFontSize = DesignTokens.bodyFontSize;
        headPaddingV = 10;
        headPaddingH = 0;
        minHeight = 0;
        radius = scaled.radius;
        radiusBase = DesignTokens.radius;
        headFilled = false;
        hoverable = false;
        bodyPadding = EdgeInsets.only(bottom: 10 * scale);
    }

    final arrowLabel = variant == QmFoldVariant.detail
        ? (expanded ? QmGlyphs.chevronDown : QmGlyphs.chevronRightSmall)
        : (expanded
            ? '${QmGlyphs.chevronDown} 收起'
            : '${QmGlyphs.chevronRightSmall} 展开');

    final head = _QmPressable(
      ringRadius: radiusBase,
      onTap: onToggle,
      focusNode: focusNode,
      semanticLabel: title,
      expanded: expanded,
      builder: (context, state) {
        final bg = !headFilled
            ? Colors.transparent
            : state.pressed
                ? palette.surface3
                : (hoverable && state.hovered)
                    ? palette.surface3
                    : palette.surface2;
        return Container(
          constraints: BoxConstraints(minHeight: minHeight * scale),
          padding: EdgeInsets.symmetric(
            horizontal: headPaddingH * scale,
            vertical: headPaddingV * scale,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: variant == QmFoldVariant.detail
                ? null
                : BorderRadius.vertical(top: Radius.circular(radius)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: titleFontSize,
                          fontWeight: FontWeight.w800,
                          color: palette.ink,
                          height: DesignTokens.controlLineHeight,
                        ),
                      ),
                    ),
                    if (subtitle != null) ...[
                      SizedBox(width: 8 * scale),
                      Flexible(
                        child: Text(
                          subtitle!,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: DesignTokens.captionFontSize,
                            fontWeight: FontWeight.w600,
                            color: palette.muted,
                            height: DesignTokens.controlLineHeight,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(width: 8 * scale),
              Text(
                arrowLabel,
                style: TextStyle(
                  fontSize: DesignTokens.captionFontSize,
                  fontWeight: FontWeight.w700,
                  color: palette.muted,
                  height: DesignTokens.controlLineHeight,
                ),
              ),
            ],
          ),
        );
      },
    );

    final body = expanded
        ? Padding(padding: bodyPadding, child: child)
        : const SizedBox.shrink();

    if (variant == QmFoldVariant.detail) {
      return Container(
        decoration: BoxDecoration(
          color: palette.surface,
          border: Border.all(color: palette.line, width: 1),
          borderRadius: BorderRadius.circular(radius),
        ),
        padding: EdgeInsets.symmetric(horizontal: 16 * scale),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [head, body],
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(color: palette.line, width: 1),
        borderRadius: BorderRadius.circular(radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [head, body],
      ),
    );
  }
}
