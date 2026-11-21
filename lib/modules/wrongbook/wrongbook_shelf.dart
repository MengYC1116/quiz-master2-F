part of 'wrongbook_page.dart';

// 书架视图：书架页、书架顶栏、分页器、封面书本与封面统计。

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
            // B8-8：封面固定尺寸（宽 DesignTokens.bookWidth、高
            // bookMinHeight，均 × 字号缩放因子），不再随窗口缩放；
            // Wrap 响应式换行：窗口变宽/变窄只改变每行本数。
            // 窄到放不下一本时才把宽压到可用宽（安全阀，桌面窗口
            // 正常尺寸下不触发），避免极窄窗口溢出。
            LayoutBuilder(
              builder: (context, constraints) {
                final gap = DesignTokens.shelfGridGap * scale;
                final fixedW = DesignTokens.bookWidth * scale;
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
    // 十五批 M3（D-169）：书架页顶栏「新建导出单」入口；筛选结果为 0 题
    // 时按钮置灰 + 提示「先筛选出题目」（不得让用户对着空结果导出）。
    final exportableCount = _s.filteredAll().length;
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
              exportableCount == 0
                  ? '先筛选出题目'
                  : '归档的题不在书里，点这里看归档列表、能恢复回错题本',
              style: TextStyle(fontSize: 13, color: palette.muted),
            ),
          ),
          SizedBox(width: 10 * scale),
          QmButton(
            key: const Key('new-export-order'),
            label: '新建导出单',
            variant: QmButtonVariant.secondary,
            size: QmButtonSize.small,
            onPressed: exportableCount == 0 ? null : _openExportWizard,
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

  // B8-8：[width] 由书架按固定尺寸传入（DesignTokens.bookWidth ×
  // 字号缩放因子），封面不再由 Expanded/Column 撑满可用宽——
  // 单本也不拉满全宽，窗口变化只改变 Wrap 每行本数。
  Widget _buildBook(Subject s, {required double width}) {
    final scale = qmScaleOf(context);
    final counts = _s.counts[s.id] ?? (0, 0, 0);
    // 封面“道题”与列表默认视图同口径（SR-P2-38 决定 (a)）：
    // 已掌握的题默认不显示在列表里，封面也不计入。
    final total = _s.questions
        .where(
          (q) =>
              q.subjectId == s.id &&
              q.isOrganized &&
              !q.isArchived &&
              !_s.isMastered(q),
        )
        .length;
    final coverColor = CoverTokens.of(s.coverColor);
    // 悬停（HTML `.nb-book:hover`）：上移 4px，阴影 0 16px 30px / .24；
    // 未悬停：阴影 0 10px 22px / .20。150ms 与 HTML transition 一致。
    final hovered = _s.hoverBookId == s.id;
    return MouseRegion(
      onEnter: (_) => _n.update((st) => st.copyWith(hoverBookId: s.id)),
      onExit: (_) => _n.update(
        (st) => st.hoverBookId == s.id ? st.copyWith(hoverBookId: null) : st,
      ),
      child: InkWell(
        onTap: () => _openDirectory(s.id),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(6 * scale),
          topRight: Radius.circular(12 * scale),
          bottomLeft: Radius.circular(12 * scale),
          bottomRight: Radius.circular(12 * scale),
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.ease,
          transform: hovered
              ? Matrix4.translationValues(0, -4 * scale, 0)
              : Matrix4.identity(),
          // 固定高（HTML `.nb-book` min-height 376px；内容按同一因子
          // 缩放后恒小于该高，固定高与最小高视觉等价，且让内层
          // Column + Spacer 有定界高度）。宽同为固定值（B8-8），
          // 由调用方按 DesignTokens.bookWidth 传入。
          width: width,
          height: DesignTokens.bookMinHeight * scale,
          padding: EdgeInsets.fromLTRB(
            DesignTokens.bookPaddingH * scale,
            DesignTokens.bookPaddingTop * scale,
            DesignTokens.bookPaddingH * scale,
            DesignTokens.bookPaddingBottom * scale,
          ),
          decoration: BoxDecoration(
            color: coverColor,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(6 * scale),
              topRight: Radius.circular(12 * scale),
              bottomLeft: Radius.circular(12 * scale),
              bottomRight: Radius.circular(12 * scale),
            ),
            boxShadow: [
              BoxShadow(
                offset: Offset(0, hovered ? 16 : 10),
                blurRadius: hovered ? 30 : 22,
                color: Color.fromRGBO(23, 35, 59, hovered ? 0.24 : 0.20),
              ),
            ],
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(6 * scale),
                  topRight: Radius.circular(12 * scale),
                  bottomLeft: Radius.circular(12 * scale),
                  bottomRight: Radius.circular(12 * scale),
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _CoverPatternPainter(s.coverStyle),
                      ),
                    ),
                    // 内阴影（HTML `.nb-book` box-shadow 的两层 inset：
                    // 左暗 rgba(0,0,0,.18) / 右亮 rgba(255,255,255,.14)；
                    // 封面“上下深浅变化、底部略深”就是它 + 计数条叠加的视觉效果，
                    // 两版 HTML 的封面底色都是纯色，无纵向渐变）。
                    Positioned.fill(
                      child: CustomPaint(
                        // 只画右亮带：左暗带已移到封面边缘单独画（见外层
                        // Stack 的左暗带）；留在这里会在书脊原位置
                        // （封面左缘内 18px）留下一条暗带。
                        painter: const _CoverInsetShadowPainter(
                          drawLeft: false,
                        ),
                      ),
                    ),
                    // 虚线内框（HTML `.nb-book::before`：1.6px、rgba 白 .55、
                    // inset 9/9/9/15、圆角 4 9 9 4）。
                    Positioned.fill(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          15 * scale,
                          9 * scale,
                          9 * scale,
                          9 * scale,
                        ),
                        child: CustomPaint(
                          painter: _DashedBorderPainter(
                            color: const Color.fromRGBO(255, 255, 255, 0.55),
                            borderRadius: BorderRadius.only(
                              topLeft: Radius.circular(4 * scale),
                              topRight: Radius.circular(9 * scale),
                              bottomRight: Radius.circular(9 * scale),
                              bottomLeft: Radius.circular(4 * scale),
                            ),
                            strokeWidth: 1.6 * scale,
                          ),
                        ),
                      ),
                    ),
                    // 书页边（HTML `.nb-book::after`：右缘 5px 处、4px 宽，
                    // 3px 米白 #F5EFDD + 1px #D9D2BC 循环，opacity .85）。
                    Positioned(
                      right: 5 * scale,
                      top: 0,
                      bottom: 0,
                      width: 4 * scale,
                      child: CustomPaint(painter: _CoverPageEdgePainter()),
                    ),
                    // 折角（HTML `.nb-book-fold`：右上角 34px 纸色折角，
                    // z-index 2，盖住书页边顶部）。
                    Positioned(
                      right: 0,
                      top: 0,
                      width: DesignTokens.bookFoldSize * scale,
                      height: DesignTokens.bookFoldSize * scale,
                      child: CustomPaint(painter: _CoverFoldPainter(scale)),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // 顶部不留英文行（Meng 2026-11-14 决定，预览里的英文是
                        // 有意的不同点，不恢复）。但学科名纵向位置仍按预览排布：
                        // 预览里英文行占 margin-top 26px + 12px×1.2 行高 = 40.4px，
                        // 去掉英文后用等高占位顶住，学科名不顶上去，
                        // 仍在距封面顶 34 + 40.4 = 74.4px 处。
                        SizedBox(height: 40.4 * scale),
                        // 学科名（HTML `.nb-book-name`：52px/800）。
                        // 注：原型封面实际渲染为横排 52px 学科名 + 横排
                        // 「错 题 本」，无 `writing-mode: vertical-rl`；
                        // 任务书说的“竖排”与实际渲染不符，按实际渲染实现。
                        // 字号不乘 scale：D4 约定字号只由 TextScaler 全局
                        // 乘一次（实测 52 在特大档渲染为 67.6）；字距不被
                        // TextScaler 缩放（实测 13.6 在特大档仍是 13.6），
                        // 所以只有字距乘 scale（SR-P2-52；若字号也乘会
                        // 双倍缩放）。
                        Text(
                          s.name,
                          style: TextStyle(
                            fontSize: 52,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 3.12 * scale,
                            color: Colors.white,
                            height: 1.15,
                            shadows: const [
                              Shadow(
                                offset: Offset(0, 2),
                                blurRadius: 5,
                                color: Color.fromRGBO(0, 0, 0, 0.22),
                              ),
                            ],
                          ),
                        ),
                        // 「错 题 本」（HTML `.nb-book-sub`：16px、字距 .85em、
                        // margin-top 8px、opacity .95）。注意 padding-left 不取
                        // HTML 的 .85em（13.6px）：HTML 那样写是为了抵消 CSS
                        // 字距在末字后多出的一格；Flutter 的 Text 不把末字后的
                        // 字距算进宽度，照搬 13.6 反而会右偏。实测：改前 padding
                        // 6.8 时字墨中心比书中心右偏约 5px，学科名（无 padding）
                        // 居中无偏；故 Flutter 侧 padding-left 取 0，
                        // 与预览“居中”的视觉结果一致。
                        Padding(
                          padding: EdgeInsets.only(top: 8 * scale),
                          child: Text(
                            '错 题 本',
                            style: TextStyle(
                              fontSize: 16,
                              // 字距同乘 scale（SR-P2-52）：字号由 TextScaler
                              // 全局缩放，字距不被它缩放，大字号下不乘会
                              // 显得越来越挤。
                              letterSpacing: 13.6 * scale,
                              color: const Color.fromRGBO(255, 255, 255, 0.95),
                              height: 1.2,
                            ),
                          ),
                        ),
                        const Spacer(),
                        // 计数牌（HTML `.nb-book-counts`）。
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 4 * scale,
                            vertical: 10 * scale,
                          ),
                          decoration: BoxDecoration(
                            color: const Color.fromRGBO(0, 0, 0, 0.20),
                            border: Border.all(
                              color: const Color.fromRGBO(255, 255, 255, 0.35),
                            ),
                            borderRadius: BorderRadius.circular(12 * scale),
                          ),
                          child: Row(
                            children: [
                              _bookStat('道题', total),
                              _bookStat('要复习', counts.$1),
                              _bookStat('待复查', counts.$2),
                            ],
                          ),
                        ),
                        SizedBox(height: 10 * scale),
                        // 封面内「开始复习」（HTML `.nb-cover-rev`）。
                        _CoverReviewButton(
                          label: '开始复习',
                          onPressed: () => widget.onGoReview(subjectId: s.id),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // 左暗带：内阴影的左暗带必须画在封面左缘、被书脊盖住
              // （与 HTML 一致：inset 阴影画在整本书上，书脊盖住它）。
              // 它不能留在内层 Stack 里——那里是内容内边距，左暗带会
              // 落在封面左缘内 18px；书脊移走后，原位置会留下一条暗带。
              // 宽 12 与画笔里的渐变宽一致（画笔的 12 是固定值，不跟 scale）。
              Positioned(
                left: -DesignTokens.bookPaddingH * scale,
                top: -DesignTokens.bookPaddingTop * scale,
                bottom: -DesignTokens.bookPaddingBottom * scale,
                width: 12,
                child: const CustomPaint(
                  painter: _CoverInsetShadowPainter(drawRight: false),
                ),
              ),
              // 书脊：贴着封面左边缘、通顶通底（HTML `.nb-book-spine`
              // 是相对整本书定位的 left:0/top:0/bottom:0）。
              // 根因：书脊原来在内层 Stack 里，而内层 Stack 在
              // AnimatedContainer 的内容内边距（左右 18、上 34、
              // 下 20）之内，left:0 实际落在封面左缘内 18px，且上下
              // 各短 34px/20px（实测截图：书脊离左缘 18px、顶上短
              // 34px）。这里用负偏移把它顶回封面边缘；外层 Stack 用
              // Clip.none（AnimatedContainer 本身不裁剪），书脊自己的
              // ClipRRect 按封面左上角 6 / 左下角 12 的圆角裁剪。
              // 折角/书页边/虚线内框/内容列一律不动（Meng 只让改书脊）。
              Positioned(
                left: -DesignTokens.bookPaddingH * scale,
                top: -DesignTokens.bookPaddingTop * scale,
                bottom: -DesignTokens.bookPaddingBottom * scale,
                width: DesignTokens.bookSpineWidth * scale,
                child: ClipRRect(
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(6 * scale),
                    bottomLeft: Radius.circular(12 * scale),
                  ),
                  child: Container(
                    decoration: const BoxDecoration(
                      color: Color.fromRGBO(0, 0, 0, 0.20),
                      border: Border(
                        right: BorderSide(
                          color: Color.fromRGBO(255, 255, 255, 0.25),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bookStat(String label, int value) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$value',
            style: const TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1.25,
            ),
          ),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: Color.fromRGBO(255, 255, 255, 0.92),
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }
}

/// 封面内「开始复习」按钮（HTML `.nb-cover-rev`：白底 95%、
/// #22304A 字、15px/800、圆角 12、全宽；点按不触发封面打开）。
class _CoverReviewButton extends StatelessWidget {
  const _CoverReviewButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12 * scale),
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(vertical: 9 * scale),
          decoration: BoxDecoration(
            color: const Color.fromRGBO(255, 255, 255, 0.95),
            borderRadius: BorderRadius.circular(12 * scale),
            boxShadow: const [
              BoxShadow(
                offset: Offset(0, 2),
                blurRadius: 6,
                color: Color.fromRGBO(0, 0, 0, 0.18),
              ),
            ],
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Color(0xFF22304A),
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}
