part of 'wrongbook_page.dart';

// 书架视图：书架页、书架顶栏、分页器、封面书本与封面统计。

// D-256：板子 12 号外形 218×304（旧封面是 300×376，见 B8-8）。
// 尺寸与板子一致，不再走 DesignTokens.bookWidth/bookMinHeight。
const double _kBook12Width = 218;
const double _kBook12Height = 304;

// D-256：板子渐变 160°（CSS 角度：0° 朝上、顺时针；160° 即向下
// 偏右 20°）。方向向量 (sin160°, cos160°)（y 向下）= (0.342, 0.940)。
// CSS 的渐变线过中心、端点落在盒子上下两边（218×304：x=53.7/164.3），
// Flutter 的 begin/end 直接取这两个端点对应的 Alignment，
// 这样 58% 的接缝位置与 CSS 完全一致（只取 ±(sin,cos) 会让渐变线
// 短一截，接缝偏上约 16px）。
const _kBook12GradientBegin = Alignment(-0.5076, -1.0);
const _kBook12GradientEnd = Alignment(0.5076, 1.0);

/// 板子 12 号配色（B26-SPEC；与 app 学科 token 略有不同，按板子值来）。
/// 预设三科按 id 查表；其他学科按自身学科色推导（c 取学科色，
/// cd/cdd 按明度加深）。
/// D-257：英文名读学科存好的 englishName（GLM 翻译或手动填）；没有
/// 就不画英文行。预设三科的存值与板子预设值一致；万一存值缺失（如从
/// v6 备份恢复的老行），回退到板子预设值。
/// 板子上的 `--cl`（浅色）12 号没用到（渐变只用 c/cd，按钮字用 cdd），
/// 这里不带它。
class _Book12Palette {
  const _Book12Palette({
    required this.c,
    required this.cd,
    required this.cdd,
    required this.englishName,
  });
  final Color c;
  final Color cd;
  final Color cdd;

  /// 书封英文名（渲染时统一大写）；null = 没有，不画英文行。
  final String? englishName;

  static const _bySubjectId = <String, (Color, Color, Color, String)>{
    'math': (
      Color(0xFF2B6BEB),
      Color(0xFF1743A6),
      Color(0xFF102F75),
      'MATHEMATICS',
    ),
    'english': (
      Color(0xFF0E9F6E),
      Color(0xFF066E4B),
      Color(0xFF044A33),
      'ENGLISH',
    ),
    'politics': (
      Color(0xFFDE5148),
      Color(0xFFA92E28),
      Color(0xFF7C1F1B),
      'POLITICS',
    ),
  };

  factory _Book12Palette.of(Subject s) {
    final preset = _bySubjectId[s.id];
    // 预设三科：存值优先（用户手动改过英文名时以存值为准），缺失时
    // 回退板子预设值；其他学科：只读存值，没有就不画英文行。
    final englishName = s.englishName ?? preset?.$4;
    if (preset != null) {
      return _Book12Palette(
        c: preset.$1,
        cd: preset.$2,
        cdd: preset.$3,
        englishName: englishName,
      );
    }
    return _Book12Palette(
      c: s.color,
      cd: _shade(s.color, 0.62),
      cdd: _shade(s.color, 0.45),
      englishName: englishName,
    );
  }

  static Color _shade(Color color, double factor) {
    final hsl = HSLColor.fromColor(color);
    final lightness = (hsl.lightness * factor).clamp(0.0, 1.0);
    return hsl.withLightness(lightness).toColor();
  }
}

extension _WrongbookShelfBuild on _WrongbookViewState {
  Widget _buildShelf() {
    const perPage = 6;
    final pages = (_s.subjects.length / perPage).ceil().clamp(1, 99);
    final page = _s.shelfPage.clamp(0, pages - 1);
    final books = _s.subjects.skip(page * perPage).take(perPage).toList();
    final archivedCount = _s.questions.where((q) => q.isArchived).length;
    final scale = qmScaleOf(context);
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _pageTitle('错题本'),
          _pageSubtitle('一科一本错题本，点一本打开看这一科的错题。'),
          _buildShelfTop(archivedCount),
          // B8-1：学科删空时书架不再摆三本 0 道题的幽灵书，
          // 给空状态（文案与学科管理页“还没有学科，先添加一个吧。”
          // 同款）；有去学科管理的回调时才画按钮。
          if (_s.subjects.isEmpty)
            QmEmptyState(
              title: '还没有学科',
              description: '先去学科管理添加一个吧。',
              actionLabel:
                  widget.onGoSubjects == null ? null : '去学科管理',
              onAction: widget.onGoSubjects,
            )
          else ...[
            // D-256：封面固定尺寸（宽 _kBook12Width 218、高 _kBook12Height 304，
            // 均 × 字号缩放因子），不再随窗口缩放；
            // Wrap 响应式换行：窗口变宽/变窄只改变每行本数。
            // 窄到放不下一本时才把宽压到可用宽（安全阀，桌面窗口
            // 正常尺寸下不触发），避免极窄窗口溢出。
            LayoutBuilder(
              builder: (context, constraints) {
                final gap = DesignTokens.shelfGridGap * scale;
                final fixedW = _kBook12Width * scale;
                final bookW = fixedW < constraints.maxWidth
                    ? fixedW
                    : constraints.maxWidth;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final book in books) _buildBook(book, width: bookW),
                  ],
                );
              },
            ),
            SizedBox(height: DesignTokens.shelfPagerMarginTop * scale),
            _buildShelfPager(page, pages),
          ],
        ],
      ),
    );
  }

  Widget _buildShelfTop(int archivedCount) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    // 十六批 B（D-190）：书架页顶栏「新建导出单」入口已废（D-169 作废，
    // 导出改到错题本列表页直接勾选）；这里只留已归档入口与提示。
    return Padding(
      padding: EdgeInsets.only(bottom: 14 * scale),
      child: Row(
        children: [
          QmChip(
            label: '已归档（$archivedCount）',
            onTap: () => _n.update(
              (st) => st.copyWith(view: WrongbookView.archived, page: 0),
            ),
          ),
          SizedBox(width: 10 * scale),
          Expanded(
            child: Text(
              '归档的题不在书里，点这里看归档列表、能恢复回错题本',
              style: TextStyle(fontSize: 13, color: palette.muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShelfPager(int page, int pages) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        QmButton(
          label: '← 上一页',
          variant: QmButtonVariant.plain,
          size: QmButtonSize.small,
          onPressed: page > 0
              ? () => _n.update((st) => st.copyWith(shelfPage: page - 1))
              : null,
        ),
        SizedBox(width: 6 * scale),
        for (var i = 0; i < pages; i++) ...[
          if (i > 0) SizedBox(width: 6 * scale),
          _pageNumButton(
            i + 1,
            selected: i == page,
            onTap: () {
              _n.update((st) => st.copyWith(shelfPage: i));
            },
          ),
        ],
        SizedBox(width: 6 * scale),
        QmButton(
          label: '下一页 →',
          variant: QmButtonVariant.plain,
          size: QmButtonSize.small,
          onPressed: page < pages - 1
              ? () => _n.update((st) => st.copyWith(shelfPage: page + 1))
              : null,
        ),
        SizedBox(width: 12 * scale),
        Text(
          '第 ${page + 1} / $pages 页 · 共 ${_s.subjects.length} 本（每页最多 6 本）',
          style: TextStyle(
            fontSize: DesignTokens.pagerFontSize,
            color: palette.muted,
          ),
        ),
      ],
    );
  }

  Widget _pageNumButton(
    int number, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: BoxConstraints(
          minWidth: DesignTokens.pageNumMinWidth * scale,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: 10 * scale,
          vertical: 6 * scale,
        ),
        decoration: BoxDecoration(
          color: selected ? palette.accent : palette.surface,
          border: Border.all(
            color: selected ? palette.accent : palette.lineStrong,
          ),
          borderRadius: BorderRadius.circular(10 * scale),
        ),
        child: Text(
          '$number',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: DesignTokens.pagerFontSize,
            fontWeight: FontWeight.w700,
            color: selected ? palette.accentInk : palette.ink2,
            height: DesignTokens.controlLineHeight,
          ),
        ),
      ),
    );
  }

  // D-256：[width] 由书架按固定尺寸传入（_kBook12Width × 字号缩放因子），
  // 封面不再由 Expanded/Column 撑满可用宽——单本也不拉满全宽，
  // 窗口变化只改变 Wrap 每行本数。
  Widget _buildBook(Subject s, {required double width}) {
    final scale = qmScaleOf(context);
    // 2026-11-25 口径迁移 §2.1/§4 第 1 项：封面两段与首页学科行
    // 同一口径——到期 N 道 · 待整理 M 道；旧三数（道题/要复习/待复查）
    // 已撤下（“道题”总数按已掌握排除，不再符合 D-259“软件不判定掌握”）。
    final due = _s.dueCounts[s.id] ?? 0;
    final pendingOrganize = _s.pendingOrganizeCounts[s.id] ?? 0;
    final palette = _Book12Palette.of(s);
    // 悬停（板子无悬停态；沿用旧书架的上移 4px，阴影不变）：
    // 未悬停与悬停都是板子阴影 14/18/28/.30，150ms 与旧版一致。
    final hovered = _s.hoverBookId == s.id;
    return MouseRegion(
      onEnter: (_) => _n.update((st) => st.copyWith(hoverBookId: s.id)),
      onExit: (_) => _n.update(
        (st) => st.hoverBookId == s.id ? st.copyWith(hoverBookId: null) : st,
      ),
      child: InkWell(
        onTap: () => _openDirectory(s.id),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(3 * scale),
          topRight: Radius.circular(9 * scale),
          bottomLeft: Radius.circular(3 * scale),
          bottomRight: Radius.circular(9 * scale),
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.ease,
          transform: hovered
              ? Matrix4.translationValues(0, -4 * scale, 0)
              : Matrix4.identity(),
          width: width,
          height: _kBook12Height * scale,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: _kBook12GradientBegin,
              end: _kBook12GradientEnd,
              colors: [palette.c, palette.cd],
              stops: const [0.58, 0.582],
            ),
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(3 * scale),
              topRight: Radius.circular(9 * scale),
              bottomLeft: Radius.circular(3 * scale),
              bottomRight: Radius.circular(9 * scale),
            ),
            boxShadow: const [
              BoxShadow(
                offset: Offset(14, 18),
                blurRadius: 28,
                color: Color.fromRGBO(15, 18, 25, 0.30),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(3 * scale),
              topRight: Radius.circular(9 * scale),
              bottomLeft: Radius.circular(3 * scale),
              bottomRight: Radius.circular(9 * scale),
            ),
            child: Stack(
              children: [
                // 书脊侧内侧高光：板子是 inset 4px 0 10px 白 15%，Flutter
                // 没有 inset shadow，用左沿 4px 白 15% 渐隐条近似（D-256）。
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: 4 * scale,
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Color.fromRGBO(255, 255, 255, 0.15),
                          Color.fromRGBO(255, 255, 255, 0),
                        ],
                      ),
                    ),
                  ),
                ),
                // 书脊槽：2px 宽竖线，距左 12px，上下顶满，黑 26%。
                Positioned(
                  left: 12 * scale,
                  top: 0,
                  bottom: 0,
                  width: 2 * scale,
                  child: Container(
                    color: const Color.fromRGBO(0, 0, 0, 0.26),
                  ),
                ),
                // 书页边：右沿 8px，上下各 inset 4px（D-256 画笔）。
                Positioned(
                  right: 0,
                  top: 4 * scale,
                  bottom: 4 * scale,
                  width: 8 * scale,
                  child: const CustomPaint(
                    painter: _Book12PageEdgePainter(),
                  ),
                ),
                // 内容：上半区（左 32/上 30/右 22）+ 下半区（左 32/右 22/下 18）。
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          32 * scale,
                          30 * scale,
                          22 * scale,
                          0,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 学科名（板子 38px / Noto Serif SC 900 / 字距 .14em）。
                            // 字号不乘 scale（D4 约定：字号只由 TextScaler
                            // 全局乘一次；字距不被 TextScaler 缩放，所以
                            // 字距乘 scale——与旧封面同款做法）。
                            Text(
                              s.name,
                              style: TextStyle(
                                fontFamily: 'Noto Serif SC',
                                fontSize: 38,
                                fontWeight: FontWeight.w900,
                                fontVariations: const [
                                  FontVariation('wght', 900),
                                ],
                                letterSpacing: 5.32 * scale,
                                color: Colors.white,
                                height: 1.2,
                              ),
                            ),
                            // 「错 题 本」（板子 12px / 字距 .62em / 白 .92）。
                            Padding(
                              padding: EdgeInsets.only(top: 8 * scale),
                              child: Text(
                                '错 题 本',
                                style: TextStyle(
                                  fontSize: 12,
                                  letterSpacing: 7.44 * scale,
                                  color: const Color.fromRGBO(
                                    255,
                                    255,
                                    255,
                                    0.92,
                                  ),
                                  height: 1.2,
                                ),
                              ),
                            ),
                            // 英文名（板子 10px / 字距 .34em / 白 .75 / 700）。
                            // D-257：读学科存好的 englishName，渲染时统一大写；
                            // 没有就不画英文行（翻译失败/无 key 时的回退）。
                            if (palette.englishName != null &&
                                palette.englishName!.isNotEmpty)
                              Padding(
                                padding: EdgeInsets.only(top: 12 * scale),
                                child: Text(
                                  palette.englishName!.toUpperCase(),
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 3.4 * scale,
                                  color: const Color.fromRGBO(
                                    255,
                                    255,
                                    255,
                                    0.75,
                                  ),
                                  height: 1.2,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        32 * scale,
                        0,
                        22 * scale,
                        18 * scale,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // 两数字行：顶部分隔线 1px 白 40%，padding-top 11。
                          Container(
                            decoration: const BoxDecoration(
                              border: Border(
                                top: BorderSide(
                                  color: Color.fromRGBO(255, 255, 255, 0.4),
                                ),
                              ),
                            ),
                            padding: EdgeInsets.only(top: 11 * scale),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                _bookStat('到期', due),
                                _bookStat('待整理', pendingOrganize),
                              ],
                            ),
                          ),
                          SizedBox(height: 12 * scale),
                          // 「开始复习」（板子：白底、字色 cdd、13.5px/700、
                          // 字距 .22em、上下 padding 9px、圆角 3px）。
                          _Book12ReviewButton(
                            label: '开始复习',
                            textColor: palette.cdd,
                            onPressed: () =>
                                widget.onGoReview(subjectId: s.id),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bookStat(String label, int value) {
    // 板子 12 号两数字：数字 21px/900（等宽数字），标签 10.5px/白 .85/
    // 字距 .08em；每格内容居中，Row 用 spaceBetween 左右分散。
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$value',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w900,
            color: Colors.white,
            height: 1.1,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 10.5,
            letterSpacing: 0.84 * qmScaleOf(context),
            color: const Color.fromRGBO(255, 255, 255, 0.85),
            height: 1.25,
          ),
        ),
      ],
    );
  }
}

/// 封面内「开始复习」按钮（板子 12 号 `.bk-cta`：白底、字色 cdd、
/// 13.5px/700、字距 .22em、上下 padding 9px、圆角 3px、全宽；
/// 点按不触发封面打开——内层 InkWell 抢先接住手势，与旧版同款）。
class _Book12ReviewButton extends StatelessWidget {
  const _Book12ReviewButton({
    required this.label,
    required this.textColor,
    required this.onPressed,
  });
  final String label;
  final Color textColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(3 * scale),
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(vertical: 9 * scale),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(3 * scale),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 2.97 * scale,
              color: textColor,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}
