// 应用外壳 · 左导航（R2 重建，纯展示组件，不读数据库、不改口径）。
//
// HTML 来源（交互原型 `quiz-master2-jiao-hu-yuan-xing.html`）：
// - `.side`：底色 `--surface-2`、右框线 `--line`、内边距 `16px 12px`；
// - `.brand`：`quiz-master2` 17px/800 + 副标题“个人智能错题本”11.5px muted；
// - `.side nav`：主列表 7 项（首页 / 收集中心 / 整理工作台 / 错题本 /
//   复习 / 学习报告 / 学科管理），项内边距 `10px 12px`、圆角 12、
//   字 14.5px/600、未选中字 `--ink-2`、悬停底 `--surface`、选中态
//   `--accent` 底 + `--accent-ink` 字（700）；
// - 角标 `.bdg`：11.5px/700、最小宽 22px、高 20px、999 圆角；未选中态
//   accent 底 + accent-ink 字，收集角标是灰档（`.bdg.grey`：
//   `--surface-3` 底 + `--ink-2` 字）；选中态角标亮色 `#FFFFFF/#175CD3`、
//   深色 `#D5DBE4/#33465A`（见 `DesignTokens.badgeSelectedBg/Fg`）；
// - `.side-foot`：顶部 `--line` 分隔线，`学科速览`（12px/700 muted，
//   字距 .08em）+ 每科一行（圆点 10px + 科名 + `待整理 N · 待复习 M`，
//   13.5px，行内边距 `7px 10px`，悬停 `--surface`）+ `设置`按钮
//   （`.btn.small`，上边距 8px）；设置不在主导航列表里，在左下角——
//   这是与基线代码的最大外壳差异（基线把设置放在主导航列表里）。
// - HTML 原型导航本身没有图标；Flutter 基线有图标位，R2 用文字符号
//   （[QmGlyphs] 的导航符号，D3，不用图标字体）保留图标位。
//
// 与 HTML 不同的两点（均按已确认决策保留，见 R2 报告）：
// - 折叠：HTML 无折叠导航；沿用已确认的折叠行为（折叠 = 仅图标，64px），
//   折叠/展开箭头保留在品牌行（`‹` / `›` 文字符号）；
// - 内容区 padding：HTML `.main` 为 `26px 30px`，外壳按
//   `ScaledTokens.contentPadding` 包裹页面（见 `app.dart`）；九页主体
//   仍带各自的旧内边距（24–28px），过渡期内容总缩进偏大，R3–R10 逐页
//   接 UI Kit 时去掉页内边距后落到准确的 26/30。
//
// 角标口径（沿用基线 / repository 现有口径，不改 repository）：
// - 收集 = 待框选 + 待整理（`CollectPage.countPendingBox` 的
//   待框选 + 修框中任务数 + `pendingOrganizeCount` 未整理题数）；
// - 整理 = 待整理（`pendingOrganizeCount`）；
// - 学科速览待复习与首页焦点卡同一口径（`homeRevCounts`：手动加入复习
//   且已整理且至少一个错因未解决或已到复查时间，数题不数错因）；
//   待整理按学科实时算（`pendingOrganizeBySubject`），不照搬 HTML
//   写死的演示数字。角标由 `app.dart` 的 `_refreshBadges`
//   （`badgeVersion` 监听）刷新后以参数传入本组件。
// - 学科速览行只展示、不跳转（HTML 原型里 `subjrow` 只有悬停态，
//   无跳转行为）；点科名去错题本请走首页学科格 / 错题本入口。
//
// 缩放（D4）：导航宽（216/64）与全部布局尺寸按 `ScaledTokens` 缩放；
// 字号只写基准值，由 app.dart 的 `MediaQuery TextScaler` 全局缩放一次，
// 不重复缩放，不用 `Transform.scale`。亮/深只读 `DesignTokens`。

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/design_tokens.dart';
import 'uikit.dart';

/// 左导航栏：主列表 7 项 + 底部 side-foot（学科速览 + 设置按钮）。
class AppNavBar extends StatelessWidget {
  const AppNavBar({
    super.key,
    required this.route,
    required this.collapsed,
    required this.onNavigate,
    required this.onToggleCollapsed,
    this.collectBadge = 0,
    this.organizeBadge = 0,
    this.navRev = const {},
    this.navPending = const {},
    this.subjects,
  });

  /// 当前路由（`/home` 等 9 路由之一；详情页不进导航，停留在来源页）。
  final String route;

  /// 折叠态：true = 64px 纯图标，false = 216px 图标 + 文字。
  final bool collapsed;
  final ValueChanged<String> onNavigate;
  final VoidCallback onToggleCollapsed;

  /// 收集角标（待框选 + 待整理）、整理角标（待整理）。
  final int collectBadge;
  final int organizeBadge;

  /// 学科速览：每科待复习数（`homeRevCounts` 口径）与待整理数。
  final Map<String, int> navRev;
  final Map<String, int> navPending;

  /// 学科速览的学科来源：库里的 subjects 表（调用方 `app.dart` 从
  /// `repo.subjects()` 读，入库顺序）。B2：速览最多显示前 5 科；
  /// 传入空列表时不显示任何行；null = 未传，沿用预设三科（兼容旧
  /// 调用与纯展示测试）。圆点色已在 S8A2 修为存色回退
  ///（`subjectColor` 的 stored 参数），新学科不落到数学色。
  final List<Subject>? subjects;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scaled = DesignTokens.scaled(scale);
    final width = collapsed ? scaled.navCollapsedWidth : scaled.navWidth;
    return Container(
      key: const ValueKey('qm-nav-bar'),
      width: width,
      decoration: BoxDecoration(
        color: palette.surface2,
        border: Border(right: BorderSide(color: palette.line)),
      ),
      padding: EdgeInsets.fromLTRB(
        DesignTokens.navPaddingH * scale,
        DesignTokens.navPaddingV * scale,
        DesignTokens.navPaddingH * scale,
        DesignTokens.navPaddingV * scale,
      ),
      // 导航列：空间够时 side-foot 贴底（Spacer），不够时（小窗口 /
      // 大字号）整列可滚动，不溢出黄条。SingleChildScrollView +
      // ConstrainedBox(minHeight = 可用高) + IntrinsicHeight 是标准写法：
      // 够高时 Column 被撑满、Spacer 把 foot 顶到底；不够高时内容
      // 超出 minHeight，滚动生效。minHeight 要减掉外壳上下内边距。
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight -
                    DesignTokens.navPaddingV * scale * 2,
              ),
              child: IntrinsicHeight(
                child: Column(
                  crossAxisAlignment: collapsed
                      ? CrossAxisAlignment.center
                      : CrossAxisAlignment.start,
                  children: [
          if (collapsed)
            _NavGlyphButton(
              glyph: QmGlyphs.chevronRight,
              tooltip: '展开导航',
              onPressed: onToggleCollapsed,
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'quiz-master2',
                        style: TextStyle(
                          fontSize: DesignTokens.navBrandFontSize,
                          fontWeight: FontWeight.w800,
                          color: palette.ink,
                          height: DesignTokens.controlLineHeight,
                        ),
                      ),
                      SizedBox(height: 2 * scale),
                      Text(
                        '个人智能错题本',
                        style: TextStyle(
                          fontSize: DesignTokens.navBrandSubFontSize,
                          color: palette.muted,
                          height: DesignTokens.controlLineHeight,
                        ),
                      ),
                    ],
                  ),
                ),
                _NavGlyphButton(
                  glyph: QmGlyphs.chevronLeft,
                  tooltip: '折叠导航',
                  onPressed: onToggleCollapsed,
                ),
              ],
            ),
          SizedBox(height: 12 * scale),
          ..._navItems().map((item) => Padding(
                padding: EdgeInsets.symmetric(vertical: 2 * scale),
                child: collapsed
                    ? _CollapsedNavItem(
                        item: item,
                        selected: route == item.route,
                        onNavigate: onNavigate,
                      )
                    : _NavItem(
                        item: item,
                        selected: route == item.route,
                        onNavigate: onNavigate,
                      ),
              )),
          const Spacer(),
          if (collapsed)
            _CollapsedNavItem(
              item: const _NavItemData(
                route: '/settings',
                label: '设置',
                glyph: QmGlyphs.navSettings,
              ),
              selected: route == '/settings',
              onNavigate: onNavigate,
            )
          else
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: palette.line)),
              ),
              padding: EdgeInsets.only(top: 10 * scale),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      DesignTokens.subjRowPaddingH * scale,
                      4 * scale,
                      DesignTokens.subjRowPaddingH * scale,
                      8 * scale,
                    ),
                    child: Text(
                      '学科速览',
                      style: TextStyle(
                        fontSize: DesignTokens.navSectionFontSize,
                        fontWeight: FontWeight.w700,
                        color: palette.muted,
                        letterSpacing: 0.08 * 12,
                      ),
                    ),
                  ),
                  // B2：学科速览按入库顺序最多显示前 5 科（Meng 定）；
                  // 不足 5 科全显示；超过 5 科只显示前 5，不加“还有 N 科”
                  // 提示（现有设计无此提示）。
                  for (final s in (subjects ?? Subject.all).take(5))
                    _SubjectRow(
                      subject: s,
                      pending: navPending[s.id] ?? 0,
                      rev: navRev[s.id] ?? 0,
                    ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      DesignTokens.subjRowPaddingH * scale,
                      8 * scale,
                      DesignTokens.subjRowPaddingH * scale,
                      2 * scale,
                    ),
                    child: QmButton(
                      label: '设置',
                      leadingGlyph: QmGlyphs.navSettings,
                      variant: route == '/settings'
                          ? QmButtonVariant.primary
                          : QmButtonVariant.plain,
                      size: QmButtonSize.small,
                      block: true,
                      onPressed: () => onNavigate('/settings'),
                    ),
                  ),
                ],
              ),
            ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 主列表 7 项（设置不在其中，在底部 side-foot）。
  List<_NavItemData> _navItems() => [
        _NavItemData(
          route: '/home',
          label: '首页',
          glyph: QmGlyphs.navHome,
        ),
        _NavItemData(
          route: '/collect',
          label: '收集中心',
          glyph: QmGlyphs.navCollect,
          badge: collectBadge,
          badgeGrey: true,
        ),
        _NavItemData(
          route: '/organize',
          label: '整理工作台',
          glyph: QmGlyphs.navOrganize,
          badge: organizeBadge,
        ),
        _NavItemData(
          route: '/wrongbook',
          label: '错题本',
          glyph: QmGlyphs.navWrongbook,
        ),
        _NavItemData(
          route: '/review',
          label: '复习',
          glyph: QmGlyphs.navReview,
        ),
        _NavItemData(
          route: '/report',
          label: '学习报告',
          glyph: QmGlyphs.navReport,
        ),
        _NavItemData(
          route: '/subjects',
          label: '学科管理',
          glyph: QmGlyphs.navSubjects,
        ),
      ];
}

class _NavItemData {
  const _NavItemData({
    required this.route,
    required this.label,
    required this.glyph,
    this.badge = 0,
    this.badgeGrey = false,
  });

  final String route;
  final String label;
  final String glyph;
  final int badge;

  /// 灰档角标（HTML `.bdg.grey`，只有收集角标用）。
  final bool badgeGrey;
}

/// 展开态导航项：图标符号 + 文字 + 角标（HTML `.side nav button`）。
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.item,
    required this.selected,
    required this.onNavigate,
  });

  final _NavItemData item;
  final bool selected;
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scaled = DesignTokens.scaled(scale);
    final fg = selected ? palette.accentInk : palette.ink2;
    // 选中态的四层 InkWell 反馈色全部取 accent 本身：HTML 里选中项的
    // aria-current 规则优先于 :hover，悬停/点按时底色就是 accent 不变。
    // 实测：导航后鼠标停在选中项上时，InkWell 遮罩会被画成不透明（黑 4%
    // → 纯黑、白 10% → 纯白、透明 → 纯黑），只有用 accent 才能保证任何
    // 渲染路径下都是蓝色；未选中项保持 surface 悬停。
    return Material(
      color: selected ? palette.accent : Colors.transparent,
      borderRadius: BorderRadius.circular(scaled.radius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onNavigate(item.route),
        hoverColor: selected ? palette.accent : palette.surface,
        splashColor: selected ? palette.accent : null,
        highlightColor: selected ? palette.accent : null,
        focusColor: selected ? palette.accent : null,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: DesignTokens.navItemPaddingH * scale,
            vertical: DesignTokens.navItemPaddingV * scale,
          ),
          child: Row(
            children: [
              QmGlyph(item.glyph, size: 15, color: fg),
              SizedBox(width: 10 * scale),
              Expanded(
                child: Text(
                  item.label,
                  style: TextStyle(
                    fontSize: DesignTokens.navItemFontSize,
                    fontWeight:
                        selected ? FontWeight.w700 : FontWeight.w600,
                    color: fg,
                    height: DesignTokens.controlLineHeight,
                  ),
                ),
              ),
              if (item.badge > 0) _NavBadge(item: item, selected: selected),
            ],
          ),
        ),
      ),
    );
  }
}

/// 折叠态导航项：48px 纯图标 + 右上角角标（沿用基线折叠行为）。
class _CollapsedNavItem extends StatelessWidget {
  const _CollapsedNavItem({
    required this.item,
    required this.selected,
    required this.onNavigate,
  });

  final _NavItemData item;
  final bool selected;
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scaled = DesignTokens.scaled(scale);
    final fg = selected ? palette.accentInk : palette.ink;
    // 同 _NavItem：选中态四层反馈色全取 accent（见该处注释）。
    return Tooltip(
      message: item.label,
      child: Material(
        color: selected ? palette.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(scaled.buttonRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onNavigate(item.route),
          hoverColor: selected ? palette.accent : palette.surface,
          splashColor: selected ? palette.accent : null,
          highlightColor: selected ? palette.accent : null,
          focusColor: selected ? palette.accent : null,
          child: SizedBox(
            width: 48 * scale,
            height: 48 * scale,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Center(child: QmGlyph(item.glyph, size: 18, color: fg)),
                if (item.badge > 0)
                  Positioned(
                    top: 6 * scale,
                    right: 4 * scale,
                    child: _NavBadge(item: item, selected: selected),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 导航角标（HTML `.bdg`）：未选中 accent 底 / 灰档 surface-3 底，
/// 选中态用 `badgeSelectedBg/Fg` token。
class _NavBadge extends StatelessWidget {
  const _NavBadge({required this.item, required this.selected});

  final _NavItemData item;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final (Color bg, Color fg) = selected
        ? (palette.badgeSelectedBg, palette.badgeSelectedFg)
        : item.badgeGrey
            ? (palette.surface3, palette.ink2)
            : (palette.accent, palette.accentInk);
    return Container(
      constraints: BoxConstraints(
        minWidth: DesignTokens.navBadgeMinWidth * scale,
        minHeight: DesignTokens.navBadgeHeight * scale,
      ),
      padding: EdgeInsets.symmetric(horizontal: 6 * scale),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999 * scale),
      ),
      alignment: Alignment.center,
      child: Text(
        '${item.badge}',
        style: TextStyle(
          color: fg,
          fontSize: DesignTokens.navBadgeFontSize,
          fontWeight: FontWeight.w700,
          height: DesignTokens.controlLineHeight,
        ),
      ),
    );
  }
}

/// 学科速览行（HTML `.subjrow`）：圆点 + 科名 + `待整理 N · 待复习 M`。
/// 只展示、不跳转（HTML 原型无跳转行为）；悬停底 `--surface` 用
/// MouseRegion 实现，不用 InkWell（InkWell 无 onTap 时不响应悬停，
/// 有空 onTap 又会误导为可点）。
class _SubjectRow extends StatefulWidget {
  const _SubjectRow({
    required this.subject,
    required this.pending,
    required this.rev,
  });

  final Subject subject;
  final int pending;
  final int rev;

  @override
  State<_SubjectRow> createState() => _SubjectRowState();
}

class _SubjectRowState extends State<_SubjectRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scaled = DesignTokens.scaled(scale);
    final dotColor = DesignTokens.subjectColor(
      widget.subject.id,
      Theme.of(context).brightness,
      widget.subject.color,
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        decoration: BoxDecoration(
          color: _hovered ? palette.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(scaled.buttonRadius),
        ),
        padding: EdgeInsets.symmetric(
          horizontal: DesignTokens.subjRowPaddingH * scale,
          vertical: DesignTokens.subjRowPaddingV * scale,
        ),
        child: Row(
          children: [
            Container(
              width: DesignTokens.subjDotSize * scale,
              height: DesignTokens.subjDotSize * scale,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
            SizedBox(width: 7 * scale),
            Text(
              widget.subject.name,
              style: TextStyle(
                fontSize: DesignTokens.subjRowFontSize,
                color: palette.ink2,
                height: DesignTokens.controlLineHeight,
              ),
            ),
            const Spacer(),
            // 计数文本包 Flexible：真实字体（中文字宽 ≈ 字号）下一行放得下；
            //  fallback 字体偏宽时自动换行，不横向溢出黄条。
            Flexible(
              child: Text(
                '待整理 ${widget.pending} · 待复习 ${widget.rev}',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: DesignTokens.subjRowFontSize,
                  color: palette.ink2,
                  height: DesignTokens.controlLineHeight,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 折叠/展开箭头按钮（文字符号，无图标字体）。
class _NavGlyphButton extends StatelessWidget {
  const _NavGlyphButton({
    required this.glyph,
    required this.tooltip,
    required this.onPressed,
  });

  final String glyph;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        borderRadius:
            BorderRadius.circular(DesignTokens.scaled(scale).buttonRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          hoverColor: palette.surface,
          child: SizedBox(
            width: 32 * scale,
            height: 32 * scale,
            child: Center(
              child: QmGlyph(glyph, size: 18, color: palette.ink2),
            ),
          ),
        ),
      ),
    );
  }
}
