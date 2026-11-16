// 复习页：错因治疗模型（R8 按 HTML 交互原型重建）。
//
// 列表：按学科 × 错因分组，每组一行（错因状态 待解决/解决中/已解决 +
// 复查标记），按加入时间排（默认，可在设置里改按学科），按学科和错因
// 筛选；已治愈错因仍显示（点开看解决记录）；列表无外层卡片框、无固定
// 高度内滚容器（整页滚动）；分页默认 10（10/20/30/40/50 可选），
// 筛选变化回第 1 页。
// 会话：点“开始解决”进全屏四步（①看错因 → ②写补救 → ③重做 →
// ④自查），①② 按错因逐个走，③④ 按题走（一题的全部错因同屏自查）；
// 同一错因同一题自查“已解决”满 2 次（设置可改）算已解决；跳过按
// “题 × 错因”计次，第 1 次追加到队尾，第 2 次留到下次；暂停存断点，
// 列表顶部出“上次解决到一半”恢复条（继续解决 / 从头开始）；结束出
// 总结页，总结后回复习列表。
// 业务口径沿用基线（repository.recordSelfCheck / saveRemedy /
// reviewState；不改 Schema、不改状态机）；旧翻卡模型不复活，
// 不出现 1/3/7/14 天旧复习状态。
//
// ARCH-PLAN-A 第 3 阶段：业务数据 + 会话状态收进 [reviewProvider]
// （`lib/state/review_notifier.dart`）；本页只留 widget 与纯界面
// 临时状态——补救输入框的控制器。`repo` 构造参数保留——`app.dart`
// 仍按老样子传，本页在 build 里包一层 `ProviderScope` 把它以
// `repositoryProvider.overrideWithValue(widget.repo)` 交进依赖图，
// 页内不再直接调 `repo` 的方法；内层 Consumer 的 ref 才属于这层
// scope。补救输入框的清空：原 `_beginCause` / `_skipCurrent` 里
// 的 `_remedyController.clear()` 改由 `_ReviewView` 按
// `ReviewState.sessionCauseKey` 变化清一次（新错因开始的信号）。
// 会话细粒度重建：列表 / 会话头 / 步骤指示 / 四步各只订阅自己
// 要的字段（`ref.watch(reviewProvider.select(...))`）——自查点选
// 只重建自查步，不重建整个会话。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repository.dart';
import '../../models/models.dart';
import '../../state/repository_provider.dart';
import '../../state/review_notifier.dart';
import '../../theme/app_theme.dart';
import '../../widgets/uikit.dart';
import '../../widgets/widgets.dart';

/// 复习页。
class ReviewPage extends StatefulWidget {
  const ReviewPage({
    super.key,
    required this.repo,
    required this.onOpenDetail,
    this.initialSubjectId,
    required this.onGoWrongbook,
  });

  final QuestionRepository repo;
  final Future<void> Function(Question q, List<String> orderIds) onOpenDetail;
  final String? initialSubjectId;
  final VoidCallback onGoWrongbook;

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  @override
  Widget build(BuildContext context) {
    // 构造器接进来的 repo（应用层传的单例库 / 测试传的 FakeRepo）只在
    // 这里交进 Riverpod 依赖图：`reviewProvider` 的 Notifier 经
    // `repositoryProvider` 拿库；本页不再直接调 `repo` 的方法。
    // 初始学科筛选同样经 `reviewInitialProvider` 注入（见 D-35 的
    // `wrongbookInitialProvider` 模式）；内层 Consumer 的 ref 才
    // 属于这层 scope。
    return ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(widget.repo),
        reviewInitialProvider.overrideWithValue(
          ReviewInitial(subjectId: widget.initialSubjectId),
        ),
      ],
      child: _ReviewView(
        onOpenDetail: widget.onOpenDetail,
        onGoWrongbook: widget.onGoWrongbook,
      ),
    );
  }
}

/// 复习页内层：持有补救输入框控制器，按会话模式切换列表 / 会话 / 总结。
class _ReviewView extends ConsumerStatefulWidget {
  const _ReviewView({
    required this.onOpenDetail,
    required this.onGoWrongbook,
  });

  final Future<void> Function(Question q, List<String> orderIds) onOpenDetail;
  final VoidCallback onGoWrongbook;

  @override
  ConsumerState<_ReviewView> createState() => _ReviewViewState();
}

class _ReviewViewState extends ConsumerState<_ReviewView> {
  final _remedyController = TextEditingController();

  /// 上次见过的 `sessionCauseKey`：变了说明新错因开始（或会话进出），
  /// 补救输入框清一次（原 `_beginCause` / `_skipCurrent` 里的 clear）。
  String _seenCauseKey = '';

  @override
  void dispose() {
    _remedyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 只订阅模式切换要的四个字段：自查点选（只改 `checks`）不会
    // 让整页重建，只有自查步自己重建。
    final (loading, inSession, showSummary, causeKey) =
        ref.watch(reviewProvider.select(
      (s) => (s.loading, s.inSession, s.showSummary, s.sessionCauseKey),
    ));
    if (causeKey != _seenCauseKey) {
      _seenCauseKey = causeKey;
      // build 里不直接改控制器（会触 TextField 的监听重建），
      // 下一帧再清；测试里 `pumpAndSettle` 后已是清空后的状态。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _remedyController.clear();
      });
    }
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (inSession) {
      // 原 build 的口径：会话中先判总结（`_showSummary ? _buildSummary()
      // : _buildSession()`），会话结束出总结页时 `inSession` 仍为真，
      // 不能先按 `inSession` 直接回会话视图。
      if (showSummary) return const _SummaryView();
      return _SessionView(
        remedyController: _remedyController,
        onOpenDetail: widget.onOpenDetail,
      );
    }
    if (showSummary) return const _SummaryView();
    return _ListView(onGoWrongbook: widget.onGoWrongbook);
  }
}

Widget _centered(BuildContext context, Widget child) {
  final scale = qmScaleOf(context);
  return SingleChildScrollView(
    padding: DesignTokens.scaled(scale).contentPadding,
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: DesignTokens.reviewContentMaxWidth * scale,
        ),
        child: child,
      ),
    ),
  );
}

String _historyLabel(String r) => switch (r) {
      'solved' => '已解决',
      'unsolved' => '未解决',
      _ => '不确定',
    };

/// 下拉（HTML `.nb-fsel`：36 高、13.5px、line-strong 边、圆角 10；
/// 与错题本 `_styledDropdown` 同款）。
Widget _styledDropdown<T>(
  BuildContext context, {
  required T? value,
  required List<DropdownMenuItem<T>> items,
  required ValueChanged<T?> onChanged,
}) {
  final scale = qmScaleOf(context);
  final palette = DesignTokens.of(Theme.of(context).brightness);
  return Container(
    height: 36 * scale,
    padding: EdgeInsets.symmetric(horizontal: 10 * scale),
    decoration: BoxDecoration(
      color: palette.surface,
      border: Border.all(color: palette.lineStrong),
      borderRadius: BorderRadius.circular(10 * scale),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        value: value,
        isExpanded: true,
        icon: const QmGlyph(QmGlyphs.chevronDown, size: 14),
        style: TextStyle(
          fontSize: DesignTokens.filterSelectFontSize,
          color: palette.ink,
        ),
        items: items,
        onChanged: onChanged,
      ),
    ),
  );
}

// ---------- 列表 ----------

/// 复习列表（分组、筛选、分页、已解决区、未加入盒、恢复条）。
class _ListView extends ConsumerWidget {
  const _ListView({required this.onGoWrongbook});

  final VoidCallback onGoWrongbook;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(reviewProvider);
    final notifier = ref.read(reviewProvider.notifier);
    final scale = qmScaleOf(context);
    final pageGroups = st.pageGroups;
    final (pendCount, checkCount, curedCount) = st.metaCounts;
    final hasData = st.groups.isNotEmpty || st.curedGroups.isNotEmpty;
    return _centered(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('复习', style: Theme.of(context).textTheme.titleLarge),
          SizedBox(height: 14 * scale),
          // 读库失败（SR-P2-48）：出错误横幅 + 重试，已有内容留住。
          if (st.loadError && !st.errorDismissed)
            Padding(
              padding: EdgeInsets.only(bottom: 14 * scale),
              child: QmBanner(
                tone: QmBannerTone.error,
                message: '复习数据读取失败，已显示上次成功加载的内容。',
                actions: [
                  QmBannerAction(
                    label: '重试',
                    onPressed: notifier.retryLoad,
                  ),
                ],
                onDismiss: notifier.dismissLoadError,
              ),
            ),
          // 首次加载即失败（从未成功加载过）：横幅之外再给一个显眼的
          // 重试按钮，不只留空列表。
          if (st.loadError && !st.hasLoaded)
            Padding(
              padding: EdgeInsets.only(bottom: 14 * scale),
              child: QmButton(
                label: '重新加载',
                onPressed: notifier.retryLoad,
              ),
            ),
          if (st.resume != null && st.groups.isNotEmpty)
            _buildResumeBar(context, ref, st),
          if (st.resume == null && st.groups.isNotEmpty) ...[
            QmButton(
              label: '开始解决',
              onPressed: () => notifier.startSession(),
            ),
            SizedBox(height: 14 * scale),
          ],
          if (!hasData) ...[
            QmEmptyState(
              title: '复习列表还是空的',
              description:
                  '在题目详情的「复习记录」里点「加入复习」，这道题的错因才会到这里来解决。',
              actionLabel: '去错题本选题',
              onAction: onGoWrongbook,
            ),
          ] else ...[
            _buildMetaRow(context, st, pendCount, checkCount, curedCount),
            _buildToolbar(context, ref, st),
            if (pageGroups.isNotEmpty) ...[
              _buildPendHead(context),
              ...pageGroups.map((g) => _buildGroupRow(context, ref, g)),
              _buildPager(context, ref, st),
            ] else if (st.groups.isNotEmpty) ...[
              _DetailBox(
                child: const Text('当前筛选下没有待解决错因，换个学科 / 错因试试。'),
              ),
            ],
            if (st.filteredCured.isNotEmpty) ...[
              SizedBox(height: 14 * scale),
              _buildCuredSection(context, ref, st),
            ],
          ],
          if (st.notJoined.isNotEmpty) ...[
            SizedBox(height: 14 * scale),
            _buildNotJoinedBox(context, ref, st),
          ],
        ],
      ),
    );
  }

  /// “上次解决到一半”恢复条（HTML `revListHTML` 的 detailbox）。
  Widget _buildResumeBar(BuildContext context, WidgetRef ref, ReviewState st) {
    final scale = qmScaleOf(context);
    final notifier = ref.read(reviewProvider.notifier);
    final resume = st.resume!;
    final block = resume.blocks[resume.blockIndex];
    final q = st.questionOf(block.questionId);
    final cause = block.causes[resume.causeIndex];
    final subjectName = q == null ? '' : st.subjectOf(q.subjectId).name;
    return Padding(
      padding: EdgeInsets.only(bottom: 14 * scale),
      child: _DetailBox(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(
                    text: '上次解决到一半',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(
                    text:
                        ' · $subjectName「$cause」（${q?.title ?? ''}），第 ${resume.blockIndex + 1} / ${resume.blocks.length} 道题',
                  ),
                ],
              ),
            ),
            SizedBox(height: 10 * scale),
            Wrap(
              spacing: 8 * scale,
              runSpacing: 8 * scale,
              children: [
                QmButton(
                  label: '继续解决',
                  onPressed: () => notifier.startSession(resume: true),
                ),
                QmButton(
                  label: '从头开始',
                  variant: QmButtonVariant.secondary,
                  onPressed: notifier.startOver,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetaRow(
    BuildContext context,
    ReviewState st,
    int pend,
    int check,
    int cured,
  ) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final metaStyle = TextStyle(
      fontSize: DesignTokens.reviewMetaFontSize,
      color: palette.muted,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: 12 * scale),
      child: Wrap(
        spacing: 8 * scale,
        runSpacing: 4 * scale,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text.rich(
            TextSpan(
              style: metaStyle,
              children: [
                const TextSpan(text: '待解决 / 解决中 '),
                TextSpan(
                  text: '$pend',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const TextSpan(text: ' 道题'),
              ],
            ),
          ),
          if (check > 0)
            QmStatusPill.tone(label: '复查 $check 道', tone: QmTone.error),
          Text('已解决 $cured 道', style: metaStyle),
          Text(
            st.settings.reviewSort == 'subject'
                ? '列表按学科排（数学 / 英语 / 政治），同一科里先加入的先解决'
                : '列表按加入时间排，先加入的先解决',
            style: metaStyle,
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(BuildContext context, WidgetRef ref, ReviewState st) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final notifier = ref.read(reviewProvider.notifier);
    final labelStyle = TextStyle(
      fontSize: DesignTokens.filterCellLabelFontSize,
      fontWeight: FontWeight.w700,
      color: palette.muted,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: 14 * scale),
      child: Wrap(
        spacing: 8 * scale,
        runSpacing: 8 * scale,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('学科', style: labelStyle),
          SizedBox(
            width: 120 * scale,
            child: _styledDropdown<String>(
              context,
              value: st.subjectFilter ?? '全部',
              items: [
                const DropdownMenuItem(value: '全部', child: Text('全部')),
                for (final s in st.subjects)
                  DropdownMenuItem(value: s.id, child: Text(s.name)),
              ],
              onChanged: (v) =>
                  notifier.setSubjectFilter(v == '全部' ? null : v),
            ),
          ),
          Text('错因', style: labelStyle),
          SizedBox(
            width: 160 * scale,
            child: _styledDropdown<String>(
              context,
              // SR2-34：就地 effectiveValue——与 load 里的复位双防线；
              // _causeFilter 失效时显示“全部”，不在 build 里写回状态。
              value: st.causeFilter == '全部' ||
                      st.allCauses.contains(st.causeFilter)
                  ? st.causeFilter
                  : '全部',
              items: [
                const DropdownMenuItem(value: '全部', child: Text('全部')),
                for (final c in st.allCauses)
                  DropdownMenuItem(value: c, child: Text(c)),
              ],
              onChanged: (v) => notifier.setCauseFilter(v ?? '全部'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPendHead(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        DesignTokens.reviewRowPaddingH * scale,
        2 * scale,
        DesignTokens.reviewRowPaddingH * scale,
        4 * scale,
      ),
      child: Text(
        '待解决错因 · 一道题有多个错因时在列表里只出现一次，一道题里挨着解决完',
        style: TextStyle(
          fontSize: DesignTokens.reviewPendHeadFontSize,
          fontWeight: FontWeight.w700,
          color: palette.muted,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget _buildGroupRow(BuildContext context, WidgetRef ref, CauseGroup g) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final notifier = ref.read(reviewProvider.notifier);
    // 组所在学科名与色取自当前 state（build 时 ref.watch 已订阅整份
    // state，列表重建与原来整页 setState 同范围）。
    final st = ref.read(reviewProvider);
    final subject = st.subjectOf(g.subjectId);
    final subjectName = subject.name;
    final titles = g.items.map((it) => it.question.title).join('、');
    return Container(
      padding: EdgeInsets.symmetric(
        vertical: DesignTokens.reviewRowPaddingV * scale,
        horizontal: DesignTokens.reviewRowPaddingH * scale,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: palette.line),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            subjectName,
            style: TextStyle(
              fontSize: DesignTokens.bodySmallFontSize,
              fontWeight: FontWeight.w800,
              color: DesignTokens.subjectInk(
                g.subjectId,
                Theme.of(context).brightness,
                subject.color,
              ),
            ),
          ),
          SizedBox(width: 10 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  g.cause,
                  style: TextStyle(
                    fontSize: DesignTokens.bodySmallFontSize,
                    fontWeight: FontWeight.w700,
                    color: palette.ink,
                  ),
                ),
                Text(
                  '关联 ${g.items.length} 道题：$titles',
                  style: TextStyle(
                    fontSize: DesignTokens.captionFontSize,
                    color: palette.muted,
                  ),
                ),
              ],
            ),
          ),
          if (g.hasRecheck) ...[
            QmStatusPill.cause(QmCauseStatus.recheck),
            SizedBox(width: 6 * scale),
          ],
          QmStatusPill.cause(switch (g.status) {
            CauseStatus.pending => QmCauseStatus.pending,
            CauseStatus.inProgress => QmCauseStatus.inProgress,
            CauseStatus.solved => QmCauseStatus.solved,
          }),
          SizedBox(width: 10 * scale),
          QmButton(
            label: '开始解决',
            size: QmButtonSize.small,
            variant: QmButtonVariant.secondary,
            onPressed: () => notifier.startSession(fromGroup: g),
          ),
        ],
      ),
    );
  }

  Widget _buildPager(BuildContext context, WidgetRef ref, ReviewState st) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final notifier = ref.read(reviewProvider.notifier);
    final totalPages = st.totalPages;
    final page = st.page.clamp(1, totalPages);
    return Container(
      margin: EdgeInsets.only(top: DesignTokens.pagerMarginTop * scale),
      padding: EdgeInsets.only(top: DesignTokens.pagerPaddingTop * scale),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.line)),
      ),
      child: Wrap(
        spacing: 10 * scale,
        runSpacing: 8 * scale,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '共 ${st.filtered.length} 条 · 第 $page / $totalPages 页',
            style: TextStyle(
              fontSize: DesignTokens.pagerFontSize,
              color: palette.muted,
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '每页',
                style: TextStyle(
                  fontSize: DesignTokens.pagerFontSize,
                  color: palette.muted,
                ),
              ),
              SizedBox(width: 6 * scale),
              SizedBox(
                width: 84 * scale,
                child: _styledDropdown<int>(
                  context,
                  value: st.pageSize,
                  // 当前值恒在选项里：设置只会存 10/20/30/40/50，
                  // 但容错——万一库里是别的值也别让下拉断言。
                  items: () {
                    final sizes = {10, 20, 30, 40, 50, st.pageSize}.toList()
                      ..sort();
                    return sizes
                        .map((n) =>
                            DropdownMenuItem(value: n, child: Text('$n')))
                        .toList();
                  }(),
                  onChanged: (v) {
                    if (v == null) return;
                    // P0B2：本地行为（与错题本一致）——只改本页 _pageSize
                    // 并回第 1 页，不写库、不改设置默认值；
                    // 初值只在首次 load 里从设置默认值读（SR-P1-12）。
                    notifier.setPageSize(v);
                  },
                ),
              ),
              SizedBox(width: 6 * scale),
              Text(
                '条',
                style: TextStyle(
                  fontSize: DesignTokens.pagerFontSize,
                  color: palette.muted,
                ),
              ),
            ],
          ),
          SizedBox(width: 10 * scale),
          Wrap(
            spacing: 6 * scale,
            runSpacing: 6 * scale,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              QmButton(
                label: '上一页',
                size: QmButtonSize.small,
                variant: QmButtonVariant.secondary,
                onPressed:
                    page > 1 ? () => notifier.setPage(page - 1) : null,
              ),
              if (totalPages > 1)
                for (var p = 1; p <= totalPages; p++)
                  QmButton(
                    label: '$p',
                    size: QmButtonSize.small,
                    variant: p == page
                        ? QmButtonVariant.primary
                        : QmButtonVariant.plain,
                    onPressed:
                        p == page ? null : () => notifier.setPage(p),
                  ),
              QmButton(
                label: '下一页',
                size: QmButtonSize.small,
                variant: QmButtonVariant.secondary,
                onPressed: page < totalPages
                    ? () => notifier.setPage(page + 1)
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCuredSection(
      BuildContext context, WidgetRef ref, ReviewState st) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    // 已解决区也分页（SR-P2-47）：与待解决列表同一每页条数，
    // 不再全量渲染到底。
    final groups = st.filteredCured;
    final totalPages = (groups.length / st.pageSize).ceil().clamp(1, 9999);
    final page = st.curedPage.clamp(0, totalPages - 1);
    final items =
        groups.skip(page * st.pageSize).take(st.pageSize).toList();
    return Container(
      margin:
          EdgeInsets.only(bottom: DesignTokens.reviewCuredMarginBottom * scale),
      decoration: BoxDecoration(
        border: Border.all(color: palette.line),
        borderRadius:
            BorderRadius.circular(DesignTokens.radiusLg * scale),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(
              horizontal: DesignTokens.reviewRowPaddingH * scale,
              vertical: DesignTokens.reviewCuredHeadPaddingV * scale,
            ),
            decoration: BoxDecoration(
              color: palette.surface2,
              border: Border(bottom: BorderSide(color: palette.line)),
            ),
            child: Text(
              '已解决的错因（点一行看解决记录 · 已解决满 ${st.settings.recheckIntervalDays} 天会自动回到上面的列表复查）',
              style: TextStyle(
                fontSize: DesignTokens.reviewPendHeadFontSize,
                fontWeight: FontWeight.w700,
                color: palette.muted,
                letterSpacing: 0.8,
              ),
            ),
          ),
          for (final g in items) _buildCuredRow(context, ref, st, g),
          if (totalPages > 1)
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: DesignTokens.reviewRowPaddingH * scale,
                vertical: 10 * scale,
              ),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: palette.line)),
              ),
              child: Row(
                children: [
                  Text(
                    '共 ${groups.length} 组 · 第 ${page + 1} / $totalPages 页',
                    style: TextStyle(
                      fontSize: DesignTokens.pagerFontSize,
                      color: palette.muted,
                    ),
                  ),
                  const Spacer(),
                  QmButton(
                    label: '上一页',
                    size: QmButtonSize.small,
                    variant: QmButtonVariant.secondary,
                    onPressed: page > 0
                        ? () => ref
                            .read(reviewProvider.notifier)
                            .setCuredPage(page - 1)
                        : null,
                  ),
                  SizedBox(width: 6 * scale),
                  QmButton(
                    label: '下一页',
                    size: QmButtonSize.small,
                    variant: QmButtonVariant.secondary,
                    onPressed: page < totalPages - 1
                        ? () => ref
                            .read(reviewProvider.notifier)
                            .setCuredPage(page + 1)
                        : null,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCuredRow(
      BuildContext context, WidgetRef ref, ReviewState st, CauseGroup g) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final key = '${g.subjectId}|${g.cause}';
    final open = st.openCuredKey == key;
    final subject = st.subjectOf(g.subjectId);
    final subjectName = subject.name;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () =>
              ref.read(reviewProvider.notifier).toggleCured(key),
          child: Container(
            padding: EdgeInsets.symmetric(
              vertical: DesignTokens.reviewCuredHeadPaddingV * scale,
              horizontal: DesignTokens.reviewRowPaddingH * scale,
            ),
            decoration: BoxDecoration(
              color: open ? palette.accentSoft : null,
              border: Border(
                bottom: BorderSide(color: palette.line),
              ),
            ),
            child: Row(
              children: [
                Text(
                  subjectName,
                  style: TextStyle(
                    fontSize: DesignTokens.bodySmallFontSize,
                    fontWeight: FontWeight.w800,
                    color: DesignTokens.subjectInk(
                      g.subjectId,
                      Theme.of(context).brightness,
                      subject.color,
                    ),
                  ),
                ),
                SizedBox(width: 10 * scale),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      style: TextStyle(
                        fontSize: DesignTokens.bodySmallFontSize,
                        color: palette.ink2,
                      ),
                      children: [
                        TextSpan(
                          text: g.cause,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        TextSpan(text: ' · 关联 ${g.items.length} 道题'),
                      ],
                    ),
                  ),
                ),
                QmStatusPill.cause(QmCauseStatus.solved),
                SizedBox(width: 10 * scale),
                Text(
                  open ? '收起' : '解决记录',
                  style: TextStyle(
                    fontSize: DesignTokens.captionFontSize,
                    color: palette.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (open)
          Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(
              DesignTokens.reviewRowPaddingH * scale,
              6 * scale,
              DesignTokens.reviewRowPaddingH * scale,
              10 * scale,
            ),
            decoration: BoxDecoration(
              color: palette.surface2,
              border: Border(
                bottom: BorderSide(color: palette.line),
              ),
            ),
            child: Column(
              children: [
                for (final it in g.items)
                  _KvRow(
                    label: it.question.title,
                    value: _curedDetail(it.record),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  String _curedDetail(CauseRecord r) {
    final parts = <String>[];
    if (r.lastCheck != null) {
      parts.add('解决于 ${formatReviewDate(r.lastCheck!)}');
    }
    if (r.recheckDate != null) {
      parts.add(
          '下次复查 ${formatReviewDate(r.recheckDate!)}（${formatReviewMd(r.recheckDate!)}）');
    }
    var text = parts.join(' · ');
    if (r.remedyHistory.isNotEmpty) {
      text += '\n补救记录：${r.remedyHistory.join('\n')}';
    }
    return text;
  }

  Widget _buildNotJoinedBox(
      BuildContext context, WidgetRef ref, ReviewState st) {
    // 按学科分行；超过 10 道默认只列前 10 道，可展开看全部（SR-P2-47）。
    // 列出来的都是真能加入复习的题（见 load 的 notJoined 过滤）。
    final bySubject = <String, List<Question>>{};
    for (final q in st.notJoined) {
      (bySubject[q.subjectId] ??= []).add(q);
    }
    final ordered = <String>[
      for (final s in st.subjects)
        if (bySubject.containsKey(s.id)) s.id,
      for (final id in bySubject.keys)
        if (!st.subjects.any((s) => s.id == id)) id,
    ];
    const shownLimit = 10;
    var shown = 0;
    final lines = <Widget>[];
    for (final sid in ordered) {
      final names = <String>[];
      for (final q in bySubject[sid]!) {
        if (!st.notJoinedExpanded && shown >= shownLimit) break;
        names.add('「${q.title}」');
        shown++;
      }
      if (names.isEmpty) continue;
      lines.add(Text('${st.subjectOf(sid).name}${names.join('、')}'));
      if (!st.notJoinedExpanded && shown >= shownLimit) break;
    }
    final total = st.notJoined.length;
    return _DetailBox(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '还没加入复习的题',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 6 * qmScaleOf(context)),
          ...lines,
          if (total > shownLimit) ...[
            SizedBox(height: 6 * qmScaleOf(context)),
            QmButton(
              label: st.notJoinedExpanded ? '收起' : '展开全部（共 $total 道）',
              size: QmButtonSize.small,
              variant: QmButtonVariant.secondary,
              onPressed: () => ref
                  .read(reviewProvider.notifier)
                  .toggleNotJoinedExpanded(),
            ),
          ],
          SizedBox(height: 6 * qmScaleOf(context)),
          Text(
            '到这些题的题目详情「复习记录」里点「加入复习」才会进来；归档的题不出现在复习列表里；错因全部解决的题会自动离开列表，${st.settings.recheckIntervalDays} 天后回来复查。',
            style: TextStyle(
              fontSize: DesignTokens.bodySmallFontSize,
              color: DesignTokens.of(Theme.of(context).brightness).muted,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- 会话 ----------

/// 会话视图：头信息 + 步骤指示 + 当前步。只订阅 `phase`（步切换）
/// 与“当前题是否还在”（详情里删题后切总结页）；自查点选只改
/// `checks`，这里不订阅、不重建。
class _SessionView extends ConsumerWidget {
  const _SessionView({
    required this.remedyController,
    required this.onOpenDetail,
  });

  final TextEditingController remedyController;
  final Future<void> Function(Question q, List<String> orderIds) onOpenDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 题没了（会话里进详情删题）：切到总结页（原 `_buildSession`
    // 开头的 `if (_blocks.isEmpty || q == null) return _buildSummary()`）。
    final gone = ref.watch(reviewProvider.select(
      (s) => !s.hasCurrentBlock || s.currentQuestion == null,
    ));
    if (gone) return const _SummaryView();
    final phase = ref.watch(reviewProvider.select((s) => s.phase));
    return _centered(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SessionSaveErrorBanner(),
          _SessionMeta(onOpenDetail: onOpenDetail),
          SizedBox(height: 12 * qmScaleOf(context)),
          _StepIndicator(phase: phase),
          SizedBox(height: 12 * qmScaleOf(context)),
          if (phase == ReviewPhase.recall || phase == ReviewPhase.remedy)
            const _CauseMeta(),
          if (phase == ReviewPhase.recall) const _StepCause(),
          if (phase == ReviewPhase.remedy)
            _StepRemedy(controller: remedyController),
          if (phase == ReviewPhase.redo) const _StepRedo(),
          if (phase == ReviewPhase.check) const _StepCheck(),
        ],
      ),
    );
  }
}

/// 自查保存失败横幅（只订阅 `saveError`）。
class _SessionSaveErrorBanner extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saveError = ref.watch(reviewProvider.select((s) => s.saveError));
    if (!saveError) return const SizedBox.shrink();
    return QmBanner(
      tone: QmBannerTone.error,
      message: '复习记录保存失败，本次自查还没有存下。请重试，或重启应用后再复习。',
      onDismiss: () =>
          ref.read(reviewProvider.notifier).dismissSaveError(),
    );
  }
}

/// 会话头：第几道题 · 范围文案、题名、详情入口、暂停。
class _SessionMeta extends ConsumerWidget {
  const _SessionMeta({required this.onOpenDetail});

  final Future<void> Function(Question q, List<String> orderIds) onOpenDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 选择器必须空安全：跳过把末块拿掉的瞬时态里当前题已为空，
    // 但父级切总结页的重建还没跑，选择器会先被求值——抛错会污染通知。
    final meta = ref.watch(reviewProvider.select((s) {
      final q = s.currentQuestion;
      if (q == null) return null;
      return (
        s.bi,
        s.blocks.length,
        s.scopeLabel,
        q,
        s.subjectOf(q.subjectId).name,
      );
    }));
    if (meta == null) return const SizedBox.shrink();
    final (bi, total, scopeLabel, question, subjectName) = meta;
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final metaStyle = TextStyle(
      fontSize: DesignTokens.reviewMetaFontSize,
      color: palette.muted,
    );
    return Wrap(
      spacing: 8 * scale,
      runSpacing: 8 * scale,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '第 ${bi + 1} / $total 道题 · $scopeLabel',
          style: metaStyle,
        ),
        Text(
          '$subjectName · ${sliceKindLabel(question.sliceKind)}｜${question.title}',
          style: metaStyle,
        ),
        QmButton(
          label: '查看题目详情',
          size: QmButtonSize.small,
          variant: QmButtonVariant.secondary,
          onPressed: () async {
            final st = ref.read(reviewProvider);
            final q = st.currentQuestion!;
            final orderIds =
                st.blocks.map((b) => b.questionId).toList();
            await onOpenDetail(q, orderIds);
            await ref.read(reviewProvider.notifier).load();
          },
        ),
        QmButton(
          label: '暂停',
          size: QmButtonSize.small,
          variant: QmButtonVariant.secondary,
          onPressed: () =>
              ref.read(reviewProvider.notifier).pauseSession(),
        ),
      ],
    );
  }
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.phase});

  final ReviewPhase phase;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final stepIdx = phase.index;
    return Wrap(
      spacing: 6 * scale,
      runSpacing: 6 * scale,
      children: [
        for (var i = 0; i < stepLabels.length; i++)
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: 12 * scale,
              vertical: 4 * scale,
            ),
            decoration: BoxDecoration(
              color: i == stepIdx ? palette.accent : palette.surface,
              border: Border.all(
                color: i == stepIdx ? palette.accent : palette.line,
              ),
              borderRadius: BorderRadius.circular(999 * scale),
            ),
            child: Text(
              stepLabels[i],
              style: TextStyle(
                fontSize: DesignTokens.reviewStepFontSize,
                fontWeight: FontWeight.w700,
                color: i == stepIdx ? palette.accentInk : palette.muted,
              ),
            ),
          ),
      ],
    );
  }
}

/// ①② 步的错因头：本题第几个错因、错因名、状态、复查标记、自查进度。
class _CauseMeta extends ConsumerWidget {
  const _CauseMeta();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 选择器必须空安全（见 `_SessionMeta`）：块被跳空的瞬时态里
    // `currentBlock` 会越界，父级切总结页的重建还没跑。
    final m = ref.watch(reviewProvider.select((s) {
      if (!s.hasCurrentBlock) return null;
      final block = s.currentBlock;
      final cause = block.causes[s.ci];
      final record = s.recordOf(block.questionId, cause);
      return (
        s.ci,
        block.causes.length,
        cause,
        record?.status,
        record?.solvedCount,
        record?.isRecheckDue,
        s.settings.cureChecks,
      );
    }));
    if (m == null) return const SizedBox.shrink();
    final (ci, total, cause, status, solvedCount, isRecheckDue, cureChecks) =
        m;
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Padding(
      padding: EdgeInsets.only(bottom: 12 * scale),
      child: Wrap(
        spacing: 8 * scale,
        runSpacing: 6 * scale,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '本题错因 ${ci + 1} / $total',
            style: TextStyle(
              fontSize: DesignTokens.reviewMetaFontSize,
              color: palette.muted,
            ),
          ),
          Text(
            cause,
            style: TextStyle(
              fontSize: DesignTokens.bodySmallFontSize,
              fontWeight: FontWeight.w700,
              color: palette.ink,
            ),
          ),
          if (status != null)
            QmStatusPill.cause(switch (status) {
              CauseStatus.pending => QmCauseStatus.pending,
              CauseStatus.inProgress => QmCauseStatus.inProgress,
              CauseStatus.solved => QmCauseStatus.solved,
            }),
          if (isRecheckDue == true)
            QmStatusPill.tone(label: '复查 · 用原来这道题', tone: QmTone.error),
          if (solvedCount != null)
            Text(
              '自查「已解决」$solvedCount / $cureChecks 次',
              style: TextStyle(
                fontSize: DesignTokens.reviewMetaFontSize,
                color: palette.muted,
              ),
            ),
        ],
      ),
    );
  }
}

/// ① 看错因：题图 + 备注 + 上次自查。
class _StepCause extends ConsumerWidget {
  const _StepCause();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 选择器必须空安全（见 `_SessionMeta`）。
    final m = ref.watch(reviewProvider.select((s) {
      final q = s.currentQuestion;
      if (q == null) return null;
      final history = s.historyByQ[q.id];
      return (
        q,
        history == null || history.isEmpty ? null : history.first,
        s.subjectOf(q.subjectId),
      );
    }));
    if (m == null) return const SizedBox.shrink();
    final (question, lastCheck, subject) = m;
    final scale = qmScaleOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        QuestionSlice(
          question: question,
          subject: subject,
          maxHeight: 220,
          onTap: () =>
              showQuestionZoomDialog(context, question, returnLabel: '复习'),
        ),
        SizedBox(height: 12 * scale),
        _DetailBox(
          child: Column(
            children: [
              _KvRow(
                label: '备注',
                value: (question.notes == null || question.notes!.isEmpty)
                    ? '待补充'
                    : question.notes!,
              ),
              if (lastCheck != null)
                _KvRow(
                  label: '上次自查',
                  value:
                      '${formatReviewDate(lastCheck.reviewedAt)} · 「${_historyLabel(lastCheck.result)}」',
                ),
            ],
          ),
        ),
        SizedBox(height: DesignTokens.reviewActsMarginTop * scale),
        _SessionActions(
          primaryLabel: '下一步：写补救',
          onPrimary: () => ref
              .read(reviewProvider.notifier)
              .setPhase(ReviewPhase.remedy),
          secondaryLabel: '跳过该题',
          onSecondary: () =>
              ref.read(reviewProvider.notifier).skipCurrent(),
        ),
      ],
    );
  }
}

/// ② 写补救：上次补救 + 输入框。输入框控制器在 `_ReviewView`，
/// 新错因开始时由它按 `sessionCauseKey` 变化清空。
class _StepRemedy extends ConsumerWidget {
  const _StepRemedy({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 选择器必须空安全（见 `_SessionMeta`）。
    final m = ref.watch(reviewProvider.select((s) {
      if (!s.hasCurrentBlock) return null;
      final block = s.currentBlock;
      final cause = block.causes[s.ci];
      final record = s.recordOf(block.questionId, cause);
      return (
        cause,
        record == null || record.remedyHistory.isEmpty
            ? null
            : record.remedyHistory.first,
        s.ci >= block.causes.length - 1,
      );
    }));
    if (m == null) return const SizedBox.shrink();
    final (cause, lastRemedy, isLastCause) = m;
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (lastRemedy != null) ...[
          _DetailBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _KvRow(label: '上次补救', value: lastRemedy),
                SizedBox(height: 4 * scale),
                Text(
                  '上次是这么补的，这次可以接着用，也可以换个补法',
                  style: TextStyle(
                    fontSize: DesignTokens.captionFontSize,
                    color: palette.muted,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 12 * scale),
        ],
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '这次怎么补「$cause」',
                style: TextStyle(
                  fontSize: DesignTokens.detailFieldLabelFontSize,
                  fontWeight: FontWeight.w700,
                  color: palette.ink2,
                ),
              ),
              TextSpan(
                text: '  自己写，不套模板 · 写的内容会存下来，下次复习能看到上次是怎么补的',
                style: TextStyle(
                  fontSize: DesignTokens.detailFieldLabelFontSize,
                  color: palette.muted,
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: 5 * scale),
        TextField(
          controller: controller,
          maxLines: 4,
          style: TextStyle(
            fontSize: DesignTokens.reviewRemedyFontSize,
            color: palette.ink,
          ),
          decoration: InputDecoration(
            hintText: '比如：把记错的公式推导一遍 / 把概念用自己的话复述一遍 / 只重算当时算错的那一步……',
            hintStyle: TextStyle(color: palette.muted),
            contentPadding: EdgeInsets.symmetric(
              horizontal: 12 * scale,
              vertical: 10 * scale,
            ),
            border: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(DesignTokens.radius * scale),
              borderSide: BorderSide(color: palette.lineStrong),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(DesignTokens.radius * scale),
              borderSide: BorderSide(color: palette.lineStrong),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(DesignTokens.radius * scale),
              borderSide: BorderSide(color: palette.accent, width: 2),
            ),
            filled: true,
            fillColor: palette.surface,
          ),
        ),
        SizedBox(height: DesignTokens.reviewActsMarginTop * scale),
        _SessionActions(
          primaryLabel: isLastCause ? '下一步：重做' : '下一步：下个错因',
          onPrimary: () => ref
              .read(reviewProvider.notifier)
              .nextFromRemedy(controller.text),
          secondaryLabel: '跳过',
          onSecondary: () =>
              ref.read(reviewProvider.notifier).skipCurrent(),
        ),
      ],
    );
  }
}

/// ③ 重做：题图 + 答案显隐。
class _StepRedo extends ConsumerWidget {
  const _StepRedo();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 选择器必须空安全（见 `_SessionMeta`）。
    final m = ref.watch(reviewProvider.select((s) {
      final q = s.currentQuestion;
      if (q == null) return null;
      return (q, s.answerShown, s.subjectOf(q.subjectId));
    }));
    if (m == null) return const SizedBox.shrink();
    final (question, answerShown, subject) = m;
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        QuestionSlice(
          question: question,
          subject: subject,
          maxHeight: 220,
          onTap: () =>
              showQuestionZoomDialog(context, question, returnLabel: '复习'),
        ),
        SizedBox(height: 6 * scale),
        Center(
          child: Text(
            answerShown
                ? '答案显示着（设置里选的默认显示）：对照答案把这道题重做一遍'
                : '答案遮着：自己把这道题重做一遍，再点开答案对照',
            style: TextStyle(
              fontSize: DesignTokens.detailHintFontSize,
              color: palette.muted,
            ),
          ),
        ),
        if (answerShown) ...[
          SizedBox(height: 12 * scale),
          _DetailBox(
            child: Column(
              children: [
                _KvRow(
                  label: '答案',
                  value: (question.answer == null || question.answer!.isEmpty)
                      ? '待补充（未填写，如实显示）'
                      : question.answer!,
                ),
                _KvRow(
                  label: '解析',
                  value: (question.explanation == null ||
                          question.explanation!.isEmpty)
                      ? '待补充（未填写，如实显示）'
                      : question.explanation!,
                ),
              ],
            ),
          ),
        ],
        SizedBox(height: DesignTokens.reviewActsMarginTop * scale),
        _SessionActions(
          primaryLabel: answerShown ? '下一步：自查' : '看答案',
          onPrimary: () {
            final notifier = ref.read(reviewProvider.notifier);
            if (answerShown) {
              notifier.enterCheck();
            } else {
              notifier.setAnswerShown(true);
            }
          },
          secondaryLabel: answerShown ? '遮住答案' : null,
          onSecondary: answerShown
              ? () =>
                  ref.read(reviewProvider.notifier).setAnswerShown(false)
              : null,
        ),
      ],
    );
  }
}

/// ④ 自查：本块全部错因同屏自查。只订阅当前块 + 自查选择 +
/// 块下标 / 块数——点选只重建本步，不重建整个会话；每错因的
/// 状态 / 次数用 `ref.read` 的当前快照渲染（自查步内记录不变，
/// 记录变化时块一定跟着变，已在订阅里）。
class _StepCheck extends ConsumerWidget {
  const _StepCheck();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 选择器必须空安全（见 `_SessionMeta`）：块被跳空的瞬时态里
    // `currentBlock` 会越界，父级切总结页的重建还没跑。
    final sel = ref.watch(reviewProvider.select((s) => (
          s.hasCurrentBlock ? s.currentBlock : null,
          s.checks,
          s.bi,
          s.blocks.length,
        )));
    final (block, checks, bi, total) = sel;
    if (block == null) return const SizedBox.shrink();
    final st = ref.read(reviewProvider);
    final scale = qmScaleOf(context);
    final allChecked =
        block.causes.every((c) => checks.containsKey(c));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '这道题的 ${block.causes.length} 个错因挨着自查：这次做对，是因为错因已解决，还是只是记住了这道题的答案？',
          style: const TextStyle(fontSize: 14),
        ),
        SizedBox(height: 10 * scale),
        for (final cause in block.causes)
          _buildCheckBox(context, ref, st, block, checks, cause),
        SizedBox(height: DesignTokens.reviewActsMarginTop * scale),
        _SessionActions(
          primaryLabel: bi < total - 1 ? '下一题' : '看总结',
          onPrimary: () =>
              ref.read(reviewProvider.notifier).finishQuestion(),
          primaryEnabled: allChecked,
        ),
      ],
    );
  }

  Widget _buildCheckBox(
    BuildContext context,
    WidgetRef ref,
    ReviewState st,
    CauseBlock block,
    Map<String, String> checks,
    String cause,
  ) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final record = st.recordOf(block.questionId, cause);
    final selected = checks[cause];
    return Padding(
      padding: EdgeInsets.only(top: 10 * scale),
      child: _DetailBox(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8 * scale,
              runSpacing: 6 * scale,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  cause,
                  style: TextStyle(
                    fontSize: DesignTokens.bodySmallFontSize,
                    fontWeight: FontWeight.w700,
                    color: palette.ink,
                  ),
                ),
                if (record != null)
                  QmStatusPill.cause(switch (record.status) {
                    CauseStatus.pending => QmCauseStatus.pending,
                    CauseStatus.inProgress => QmCauseStatus.inProgress,
                    CauseStatus.solved => QmCauseStatus.solved,
                  }),
                if (record != null)
                  Text(
                    '「已解决」${record.solvedCount} / ${st.settings.cureChecks} 次',
                    style: TextStyle(
                      fontSize: DesignTokens.reviewMetaFontSize,
                      color: palette.muted,
                    ),
                  ),
                if (record != null && record.isRecheckDue)
                  QmStatusPill.cause(QmCauseStatus.recheck),
              ],
            ),
            SizedBox(height: 8 * scale),
            Wrap(
              spacing: 10 * scale,
              runSpacing: 8 * scale,
              children: [
                for (final op in const ['已解决', '未解决', '不确定'])
                  QmButton(
                    label: op,
                    size: QmButtonSize.small,
                    variant: selected == op
                        ? QmButtonVariant.primary
                        : QmButtonVariant.secondary,
                    onPressed: () => ref
                        .read(reviewProvider.notifier)
                        .setCheck(cause, op),
                  ),
              ],
            ),
            if (selected == '不确定') ...[
              SizedBox(height: 6 * scale),
              Text(
                '选「不确定」不算：下次还要重新练这道题，再自查一次这个错因',
                style: TextStyle(
                  fontSize: DesignTokens.captionFontSize,
                  color: palette.muted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------- 总结 ----------

/// 本轮复习总结（只订阅总结要的三个数）。
class _SummaryView extends ConsumerWidget {
  const _SummaryView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (curedNow, summaryRemaining, changes) =
        ref.watch(reviewProvider.select(
      (s) => (s.curedNow, s.summaryRemaining, s.changes),
    ));
    final scale = qmScaleOf(context);
    return _centered(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CompanionWidget(size: 72 * scale, message: '这一轮辛苦啦'),
          SizedBox(height: 10 * scale),
          _DetailBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '本轮复习总结',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 6 * scale),
                Text.rich(
                  TextSpan(
                    style: const TextStyle(fontSize: 14),
                    children: [
                      const TextSpan(text: '今天解决了 '),
                      TextSpan(
                        text: '$curedNow',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const TextSpan(text: ' 个错因 · 还有 '),
                      TextSpan(
                        text: '$summaryRemaining',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const TextSpan(text: ' 个未解决，留在列表里接着解决'),
                    ],
                  ),
                ),
                SizedBox(height: 8 * scale),
                if (changes.isEmpty)
                  Text(
                    '这一轮还没有自查记录。',
                    style: TextStyle(
                      fontSize: DesignTokens.bodySmallFontSize,
                      color: DesignTokens.of(Theme.of(context).brightness)
                          .muted,
                    ),
                  )
                else
                  for (final c in changes)
                    _KvRow(
                      label: '${c.subjectName} · ${c.cause}',
                      value:
                          '「${c.questionTitle}」：${c.before} → ${c.after}'
                          '${c.recheckDate != null ? ' · 下次复查 ${formatReviewDate(c.recheckDate!)}（${formatReviewMd(c.recheckDate!)}）' : ''}'
                          ' · ${c.note}',
                    ),
                SizedBox(height: 12 * scale),
                QmButton(
                  label: '回复习列表',
                  onPressed: () =>
                      ref.read(reviewProvider.notifier).backToList(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 详情盒（HTML `.detailbox`：surface-2 底、line-strong 边、圆角 16、
/// padding 16、上边距 14 由调用方控制）。
class _DetailBox extends StatelessWidget {
  const _DetailBox({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(DesignTokens.reviewDetailPadding * scale),
      decoration: BoxDecoration(
        color: palette.surface2,
        border: Border.all(color: palette.lineStrong),
        borderRadius:
            BorderRadius.circular(DesignTokens.radiusLg * scale),
      ),
      child: child,
    );
  }
}

/// 键值行（HTML `.kv`：13.5px、标签列最小宽 76、行间虚线分隔由
/// 调用方用 Column 顺序自然形成——本组件只负责单行形态）。
class _KvRow extends StatelessWidget {
  const _KvRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 5 * scale),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints:
                BoxConstraints(minWidth: DesignTokens.reviewKvLabelWidth * scale),
            child: Text(
              label,
              style: TextStyle(
                fontSize: DesignTokens.bodySmallFontSize,
                fontWeight: FontWeight.w700,
                color: palette.ink,
              ),
            ),
          ),
          SizedBox(width: 8 * scale),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: DesignTokens.bodySmallFontSize,
                color: palette.ink2,
                height: DesignTokens.bodyLineHeight,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 会话操作行（HTML `.rev-acts`：居中、gap 10、上边距 16）。
class _SessionActions extends StatelessWidget {
  const _SessionActions({
    required this.primaryLabel,
    required this.onPrimary,
    this.primaryEnabled = true,
    this.secondaryLabel,
    this.onSecondary,
  });

  final String primaryLabel;
  final VoidCallback onPrimary;
  final bool primaryEnabled;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        QmButton(
          label: primaryLabel,
          onPressed: primaryEnabled ? onPrimary : null,
        ),
        if (secondaryLabel != null) ...[
          SizedBox(width: DesignTokens.reviewActsGap * scale),
          QmButton(
            label: secondaryLabel!,
            variant: QmButtonVariant.secondary,
            onPressed: onSecondary,
          ),
        ],
      ],
    );
  }
}
