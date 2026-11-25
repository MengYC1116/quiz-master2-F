// 首页（R3 重建，layout C 焦点大卡片）。
//
// 视觉来源：交互原型 `viewHome` / `viewHomeC` / `homeCBottomHTML`
//（`.main h3.pt` / `.psub` / `.focus-card` / `.fc-continue` /
// `.secttl` / `.c-bottom` / `.c-mini`），只按实际渲染的页面实现：
// - 问候语 24px/800（`DesignTokens.pageTitleFontSize`，不是 34px 的
//   `.ahead h1`）+ 副标题“上次停在：…”；问候语取设置里的 greeting，
//   默认“今天也要加油呀”，设置存储不动。
// - 焦点大卡片：整卡可点去复习；卡内“到期 N 道”（46px/800）+
//   “到期 X 道 · 今日新题 Y 道”；下半部“继续上次”条（小伙伴 +
//   文字 +「继续上次」主按钮，按钮点按不触发整卡去复习）。
// - 下方格子：快速收集 + 每个学科各一格，每格“到期 N 道 · 待整理 M 道”
//   +「错题本」「去复习」按钮；学科按库里的 subjects 表全部显示
//   （B2，入库顺序），超过一行按列数分行。
// - 空状态：到期与今日新题都为 0 时卡片变中性样式，文案“今天没有到期的题，明天再来吧”。
// - 错误态：顶部红色横幅（手动备份失败，见 [showBackupError]）。
// - B11-9 考试倒计时：焦点卡上方一条倒计时（最近一场考试），临近
//   7 天内标红，点按进设置页的考试管理；无考试时不显示、不占位。
//
// 业务口径（FSRS 口径，2026-11-25 口径迁移 §2.1，本页不改 repository）：
// - 到期数与导航速览同一口径（`fsrsDueCountsBySubject` /
//   `fsrsDueQuestionIds`：池里已开始正式复习且 `next_due_at <= now`
//   的题；未开始的新卡不算到期，算今日新题 / 待开始）；
// - 今日新题数复用 `previewNewRelease().todaysNewIds`；
// - 继续上次 = `recentTask()` 的最近一条活动记录（2026-11-14 起
//   取消优先级，按最后活动；无记录时默认去复习）；快速收集只做文件导入入口，
//   不加手动录入。
// - 待整理按学科实时算（`pendingOrganizeBySubject`），不照搬 HTML
//   写死的演示数字“待整理 3”。
// - 焦点卡 kicker 不抄原型里的自指说明（“点这张卡片去复习页……”）。
//
// 页内无边距：外壳（R2）已给内容区 padding 26/30，本页
// `SingleChildScrollView` 不再加页内边距，总缩进落到准确的 26/30。
// HTML `.main` 底部是 34px，token 仍按任务书口径取上下对称 26px，
// 见 R2 报告 §7（R3 复核：首页先按外壳 token 走，差异记入报告）。
//
// 全部颜色 / 字号 / 圆角 / 间距取自 [DesignTokens]，按钮 / 横幅 /
// 小伙伴用 UI Kit 与 [CompanionWidget]；亮 / 深两套、三档缩放
// 1.00/1.15/1.30 全覆盖（字号只由全局 TextScaler 缩放一次，布局尺寸
// 按 [qmScaleOf] 乘一次），不用 `Transform.scale`，不用图标字体。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repository.dart';
import '../../models/exam_event.dart';
import '../../models/models.dart';
import '../../state/home_provider.dart';
import '../../state/repository_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/entrance_animation.dart';
import '../../widgets/uikit.dart';

/// 首页：问候 + 焦点大卡片（到期的数量）+ 继续上次 + 快速收集 +
/// 各学科到期 / 待整理概览，学科按库里的 subjects 表显示（入库顺序）。
///
/// ARCH-PLAN-A 第 2 阶段 A 路：业务数据（继续上次、每学科到期数、最近考试倒计时）收进 [homeProvider]（`lib/state/
/// home_provider.dart`）；本页只留 widget 与纯界面临时状态（两条横幅
/// 的“已关闭”标志）。`repo` 构造参数保留——`app.dart` 仍按老样子传，
/// 本页在 build 里用一层 `ProviderScope` 把它以
/// `repositoryProvider.overrideWithValue(widget.repo)` 交进依赖图，
/// 不再直接调 `repo` 的方法；问候语仍由应用层经构造器传 `settings` 进来。
class HomePage extends ConsumerStatefulWidget {
  const HomePage({
    super.key,
    required this.repo,
    required this.settings,
    required this.onGoCollect,
    required this.onGoOrganize,
    required this.onGoWrongbook,
    required this.onGoReview,
    this.onOpenDetail,
    this.showBackupError = false,
    this.onBackupErrorDismissed,
    this.onGoSettings,
  });

  final QuestionRepository repo;
  final AppSettings settings;
  final VoidCallback onGoCollect;
  final VoidCallback onGoOrganize;
  final void Function(String subjectId) onGoWrongbook;
  final VoidCallback onGoReview;

  /// 十二批功能 4：点“最近查看”里的一道题时调用——应用层进题目详情。
  /// 为空时行仍显示、点按无动作（老调用方不传也不影响显示）。
  final void Function(Question question, List<String> orderIds)? onOpenDetail;

  /// B11-9：点首页考试倒计时时调用——应用层进设置页并展开考试组。
  /// 为空时倒计时条仍显示、点按无动作（老调用方不传也不影响显示）。
  final VoidCallback? onGoSettings;

  /// 手动备份失败时显示顶部红色横幅（HTML 首页错误态文案）。
  /// 待定3 已接线：设置页 `_backup` 失败时把标志写进库（settings 表
  /// `backupFailed` 键），应用启动时读标志、经 `app.dart` 传进来；
  /// 点“知道了”时除本地隐藏外，还经 [onBackupErrorDismissed] 回
  /// 到应用层清除标志（只靠本地 `_errorDismissed` 的话，切页回来
  /// 状态重建、横幅会再出现）。
  final bool showBackupError;

  /// 点横幅“知道了”时调用：应用层清除库里的备份失败标志。
  final VoidCallback? onBackupErrorDismissed;

  /// HTML 首页错误态横幅文案（原型 `viewHome` 的 `errBanner` 原文）。
  static const String backupFailedMessage =
      '本地数据备份失败：磁盘空间不足，新收集的题目已保存在本地库中，'
      '但这次手动备份没有完成。请清理磁盘后在「设置」中重新备份。';

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  // 纯界面临时状态，留页面本地（不进 Provider）：两条横幅的“已关闭”标志。
  bool _errorDismissed = false;
  // _load() 读库失败态（SR-P2-48）：报告 / 学科页同款——失败不一直
  // 转圈，出错误横幅 + 重试；已加载过内容时留住旧内容。
  bool _loadErrorDismissed = false;

  /// 最近任务的 kind 归一化：线上代码写 'organize' / 'collect'，
  /// 但演示数据种子（`database.dart` 的 `_seedDemo`）写的是中文
  /// '整理'（基线 `_resumeRecent` 的 switch 只认英文，种子行会
  /// 误落到默认“复习”）。本页两边都认，不改 repository 与种子。
  String _normalizedKind(String kind) => switch (kind) {
        'organize' || '整理' => 'organize',
        'collect' || '收集' => 'collect',
        _ => 'review',
      };

  void _resumeRecent(({String kind, String subjectId, String title})? recent) {
    switch (_normalizedKind(recent?.kind ?? '')) {
      case 'organize':
        widget.onGoOrganize();
      case 'collect':
        widget.onGoCollect();
      case 'review':
      default:
        widget.onGoReview();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 构造器接进来的 repo（应用层传的单例库 / 测试传的 FakeRepo）只在
    // 这里交进 Riverpod 依赖图：`homeProvider` 的 Notifier 经
    // `repositoryProvider` 拿库；本页不再直接调 `repo` 的方法。
    // 内层 Consumer 的 ref 才属于这层 scope（外层 `ref` 拿不到 override
    // 后的库），读状态与调 `retry()` 都用内层 ref。
    return ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(widget.repo)],
      child: Consumer(
        builder: (context, ref, _) {
          final home = ref.watch(homeProvider);
          return _buildBody(context, ref, home);
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref, HomeState home) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    // 二十二批 D-247：首页入场上移淡入。
    return EntranceFadeSlide(
        child: SingleChildScrollView(
      // 无页内边距：外壳已给 26/30（R2），本页不再叠加。
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 问候语（24px/800）+ 副标题“上次停在：…”。
          Text(
            widget.settings.greeting,
            style: TextStyle(
              fontSize: DesignTokens.pageTitleFontSize,
              fontWeight: DesignTokens.pageTitleFontWeight,
              color: palette.ink,
            ),
          ),
          SizedBox(height: 3 * scale),
          Text(
            home.recent == null
                ? '上次停在：还没有记录'
                : '上次停在：${_kindPageName(home.recent!.kind)} · '
                    '${home.subjectOf(home.recent!.subjectId).name}「${home.recent!.title}」',
            style: TextStyle(
              fontSize: DesignTokens.bodySmallFontSize,
              color: palette.muted,
            ),
          ),
          SizedBox(height: DesignTokens.homeSubtitleMarginBottom * scale),
          // 错误态：顶部红色横幅（手动备份失败），可点「知道了」关闭。
          if (widget.showBackupError && !_errorDismissed)
            QmBanner(
              tone: QmBannerTone.error,
              message: HomePage.backupFailedMessage,
              onDismiss: () {
                setState(() => _errorDismissed = true);
                widget.onBackupErrorDismissed?.call();
              },
            ),
          // 读库失败（SR-P2-48）：不一直转圈，出错误横幅 + 重试。
          if (home.loadError && !_loadErrorDismissed)
            QmBanner(
              tone: QmBannerTone.error,
              message: '首页数据读取失败，已显示上次成功加载的内容。',
              actions: [
                QmBannerAction(
                  label: '重试',
                  onPressed: () =>
                      ref.read(homeProvider.notifier).retry(),
                ),
              ],
              onDismiss: () => setState(() => _loadErrorDismissed = true),
            ),
          // B11-9 考试倒计时：最近一场考试，点按进设置页的考试管理。
          // 无考试时不显示，不占位置、不破坏布局 C。
          if (home.nearestExam != null && !home.loading) ...[
            _ExamCountdownStrip(
              scale: scale,
              palette: palette,
              event: home.nearestExam!,
              onTap: widget.onGoSettings,
            ),
            SizedBox(height: DesignTokens.focusCardMarginBottom * scale),
          ],
          // 焦点大卡片 layout C：到期与今日新题都为 0 时才走空状态；
          // 只有今日新题时也出正常卡（大数字 0 道到期 + 今日新题数）。
          if (home.loading)
            _FocusCardLoading(scale: scale)
          else if (home.totalDue == 0 && home.todayNewCount == 0)
            _FocusCardEmpty(scale: scale, palette: palette)
          else
            _FocusCard(
              scale: scale,
              palette: palette,
              totalDue: home.totalDue,
              dueCount: home.dueCount,
              todayNewCount: home.todayNewCount,
              recent: home.recent,
              subjects: home.subjects,
              onTapCard: widget.onGoReview,
              onResume: () => _resumeRecent(home.recent),
              onGoCollect: widget.onGoCollect,
            ),
          SizedBox(height: DesignTokens.focusCardMarginBottom * scale),
          // 分区小标题 + 下方 4 格。
          Text(
            '快速收集与各学科待复习概览',
            style: TextStyle(
              fontSize: DesignTokens.homeSectionTitleFontSize,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.08,
              color: palette.muted,
            ),
          ),
          SizedBox(height: 4 * scale),
          // 首次加载即失败时不显示全 0 的学科格（_hasLoaded 守门），
          // 只留问候 + 错误横幅 + 重试。
          if (!home.loading && home.hasLoaded)
            _BottomGrid(
              scale: scale,
              palette: palette,
              subjects: home.subjects,
              revCounts: home.revCounts,
              pendingCounts: home.pendingCounts,
              onGoCollect: widget.onGoCollect,
              onGoWrongbook: widget.onGoWrongbook,
              onGoReview: widget.onGoReview,
            ),
          // 十二批功能 4：最近查看——学科行下方，最多 30 行紧凑行
          //（标题、学科名、最后查看时间）；空时整区隐藏，首页不放
          // 空状态提示；已归档 / 已掌握的题照常显示（详情页自己处理
          // 归档显示）。点行进题目详情（与别处相同的导航方式）。
          if (!home.loading && home.hasLoaded && home.history.isNotEmpty) ...[
            SizedBox(height: DesignTokens.focusCardMarginBottom * scale),
            Text(
              '最近查看',
              style: TextStyle(
                fontSize: DesignTokens.homeSectionTitleFontSize,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.08,
                color: palette.muted,
              ),
            ),
            SizedBox(height: 4 * scale),
            _RecentlyViewedList(
              scale: scale,
              palette: palette,
              history: home.history,
              subjects: home.subjects,
              onOpenDetail: widget.onOpenDetail,
            ),
          ],
        ],
      ),
    ));
  }
}

/// B11-9 考试倒计时条：最近一场考试的倒计时，整条可点进设置页考试管理。
/// 文案见 [examCountdownText]（“距离 X 还有 N 天” / “今天 X” /
/// “X 已考完”）；临近 7 天内（0 <= N <= 7）文字标红（[DesignTokens]
/// 的 errInk，不新增颜色），过期与 8 天以上用常规墨色。
class _ExamCountdownStrip extends StatelessWidget {
  const _ExamCountdownStrip({
    required this.scale,
    required this.palette,
    required this.event,
    required this.onTap,
  });

  final double scale;
  final AppPalette palette;
  final ExamEvent event;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final days = daysUntilExam(event.date);
    final near = isExamCountdownNear(days);
    return InkWell(
      key: const Key('home-exam-countdown'),
      onTap: onTap,
      borderRadius:
          BorderRadius.circular(DesignTokens.scaled(scale).radius),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          vertical: 10 * scale,
          horizontal: 14 * scale,
        ),
        decoration: BoxDecoration(
          color: palette.surface2,
          border: Border.all(color: palette.line),
          borderRadius:
              BorderRadius.circular(DesignTokens.scaled(scale).radius),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                examCountdownText(event),
                style: TextStyle(
                  fontSize: DesignTokens.bodyFontSize,
                  fontWeight: FontWeight.w700,
                  color: near ? palette.errInk : palette.ink,
                ),
              ),
            ),
            SizedBox(width: 8 * scale),
            Text(
              '设置 ›',
              style: TextStyle(
                fontSize: DesignTokens.captionFontSize,
                color: palette.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 焦点卡加载态：与卡片同形，占位转圈。
class _FocusCardLoading extends StatelessWidget {
  const _FocusCardLoading({required this.scale});
  final double scale;

  @override
  Widget build(BuildContext context) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        vertical: DesignTokens.focusCardPaddingV * scale,
        horizontal: DesignTokens.focusCardPaddingH * scale,
      ),
      decoration: BoxDecoration(
        color: palette.accentSoft,
        border: Border.all(color: palette.accent, width: 2),
        borderRadius:
            BorderRadius.circular(DesignTokens.scaled(scale).radiusLg),
      ),
      child: const SizedBox(
        height: 96,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

/// 空状态焦点卡：中性样式（细线边框 + surface-2 底，不可点），居中。
class _FocusCardEmpty extends StatelessWidget {
  const _FocusCardEmpty({required this.scale, required this.palette});
  final double scale;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        vertical: DesignTokens.focusCardPaddingV * scale,
        horizontal: DesignTokens.focusCardPaddingH * scale,
      ),
      decoration: BoxDecoration(
        color: palette.surface2,
        border: Border.all(color: palette.lineStrong, width: 1),
        borderRadius:
            BorderRadius.circular(DesignTokens.scaled(scale).radiusLg),
      ),
      child: Column(
        children: [
          _BuddyWithSay(say: '今天休息一下', size: 54 * scale),
          SizedBox(height: 8 * scale),
          Text(
            '今天没有到期的题，明天再来吧',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: DesignTokens.noDueNumberFontSize,
              fontWeight: FontWeight.w800,
              height: DesignTokens.focusNumberLineHeight,
              color: palette.ink,
            ),
          ),
          SizedBox(height: 2 * scale),
          Text(
            '到期 0 道 · 今日新题 0 道',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: DesignTokens.focusDetailFontSize,
              color: palette.ink2,
            ),
          ),
        ],
      ),
    );
  }
}

/// 正常态焦点卡：整卡可点去复习；下半部“继续上次”条里
/// 「继续上次」按钮的点按不触发整卡去复习（内层手势优先于
/// 外层 InkWell，见 home_page_test 的 stopPropagation 测试）。
class _FocusCard extends StatelessWidget {
  const _FocusCard({
    required this.scale,
    required this.palette,
    required this.totalDue,
    required this.dueCount,
    required this.todayNewCount,
    required this.recent,
    required this.subjects,
    required this.onTapCard,
    required this.onResume,
    required this.onGoCollect,
  });

  final double scale;
  final AppPalette palette;
  final int totalDue;
  final int dueCount;
  final int todayNewCount;
  final ({String kind, String subjectId, String title})? recent;
  // 库里的全部学科（P0B1 扫尾：焦点卡“继续上次”里的学科名以前
  // 直接 Subject.byId，新学科显示成“数学”）。
  final List<Subject> subjects;
  final VoidCallback onTapCard;
  final VoidCallback onResume;
  final VoidCallback onGoCollect;

  /// 库里找学科名；找不到才回退 Subject.byId（数学兜底）。
  String _subjectName(String id) => subjects
      .firstWhere((s) => s.id == id, orElse: () => Subject.byId(id))
      .name;

  @override
  Widget build(BuildContext context) {
    final hasRecent = recent != null;
    return InkWell(
      key: const Key('home-focus-card'),
      onTap: onTapCard,
      borderRadius:
          BorderRadius.circular(DesignTokens.scaled(scale).radiusLg),
      child: Container(
        key: const Key('home-focus-card-body'),
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          vertical: DesignTokens.focusCardPaddingV * scale,
          horizontal: DesignTokens.focusCardPaddingH * scale,
        ),
        decoration: BoxDecoration(
          color: palette.accentSoft,
          border: Border.all(color: palette.accent, width: 2),
          borderRadius:
              BorderRadius.circular(DesignTokens.scaled(scale).radiusLg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '要复习的题',
              style: TextStyle(
                fontSize: DesignTokens.focusKickerFontSize,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.08,
                color: palette.accentText,
              ),
            ),
            SizedBox(height: 4 * scale),
            Text(
              '$totalDue 道到期',
              style: TextStyle(
                fontSize: DesignTokens.focusNumberFontSize,
                fontWeight: DesignTokens.focusNumberFontWeight,
                height: DesignTokens.focusNumberLineHeight,
                color: palette.ink,
              ),
            ),
            SizedBox(height: 2 * scale),
            Text(
              todayNewCount > 0
                  ? '到期 $dueCount 道 · 今日新题 $todayNewCount 道'
                  : '到期 $dueCount 道',
              style: TextStyle(
                fontSize: DesignTokens.focusDetailFontSize,
                color: palette.ink2,
              ),
            ),
            // “继续上次”条：小伙伴 + 文字 + 主按钮。
            Container(
              margin: EdgeInsets.only(
                  top: DesignTokens.focusContinueMarginTop * scale),
              padding: EdgeInsets.only(
                  top: DesignTokens.focusContinuePaddingTop * scale),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: palette.lineStrong)),
              ),
              child: Row(
                children: [
                  _BuddyWithSay(
                    say: hasRecent ? '上次到这里' : '先去收集吧',
                    size: 48 * scale,
                  ),
                  SizedBox(width: DesignTokens.focusContinueGap * scale),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          hasRecent
                              ? '继续上次：${_kindPageName(recent!.kind)} · '
                                  '${_subjectName(recent!.subjectId)}'
                                  '「${recent!.title}」'
                              : '继续上次：还没有记录',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: DesignTokens.bodyFontSize,
                            fontWeight: FontWeight.w700,
                            color: palette.ink,
                          ),
                        ),
                        SizedBox(height: 2 * scale),
                        Text(
                          hasRecent
                              ? _recentDescription(recent!.kind)
                              : '先去收集第一道题吧',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: DesignTokens.captionFontSize,
                            color: palette.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: DesignTokens.focusContinueGap * scale),
                  if (hasRecent)
                    QmButton(
                      label: '继续上次',
                      variant: QmButtonVariant.primary,
                      onPressed: onResume,
                    )
                  else
                    QmButton(
                      label: '去收集',
                      variant: QmButtonVariant.primary,
                      onPressed: onGoCollect,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 小伙伴 + 气泡语（HTML `.buddy`：54×48 左右的白团子 SVG +
/// 11.5px 气泡；Flutter 用 [CompanionWidget] 的 CustomPaint 画法，
/// 气泡按 HTML 样式单画：surface 底 + line 细边 + 999 圆角）。
class _BuddyWithSay extends StatelessWidget {
  const _BuddyWithSay({required this.say, required this.size});
  final String say;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CompanionWidget(size: size),
        SizedBox(height: 2 * qmScaleOf(context)),
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: 8 * qmScaleOf(context),
            vertical: 2 * qmScaleOf(context),
          ),
          decoration: BoxDecoration(
            color: palette.surface,
            border: Border.all(color: palette.line),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            say,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: palette.muted,
            ),
          ),
        ),
      ],
    );
  }
}

/// 十二批功能 4：最近查看列表——学科行下方，最多 30 行紧凑行。
/// 每行：标题（单行省略）+ 学科名 · 最后查看时间（今天 / 昨天 HH:mm，
/// 其余 MM-dd HH:mm，跨年带年，见 [formatRecentlyViewedTime]）。
/// 点行进题目详情：上一题 / 下一题按本列表的顺序走（orderIds 即
/// 列表顺序，与错题本 / 复习页的来源列表同款做法）。
class _RecentlyViewedList extends StatelessWidget {
  const _RecentlyViewedList({
    required this.scale,
    required this.palette,
    required this.history,
    required this.subjects,
    required this.onOpenDetail,
  });

  final double scale;
  final AppPalette palette;
  final List<({Question question, DateTime viewedAt})> history;
  final List<Subject> subjects;
  final void Function(Question question, List<String> orderIds)? onOpenDetail;

  /// 库里找学科名；找不到才回退 Subject.byId（数学兜底）。
  String _subjectName(String id) => subjects
      .firstWhere((s) => s.id == id, orElse: () => Subject.byId(id))
      .name;

  @override
  Widget build(BuildContext context) {
    final orderIds = history.map((e) => e.question.id).toList();
    return Column(
      children: [
        for (var i = 0; i < history.length; i++) ...[
          if (i > 0) SizedBox(height: 8 * scale),
          InkWell(
            key: Key('home-history-${history[i].question.id}'),
            onTap: onOpenDetail == null
                ? null
                : () => onOpenDetail!(history[i].question, orderIds),
            borderRadius:
                BorderRadius.circular(DesignTokens.scaled(scale).radius),
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(
                vertical: 10 * scale,
                horizontal: 14 * scale,
              ),
              decoration: BoxDecoration(
                color: palette.surface,
                border: Border.all(color: palette.line),
                borderRadius:
                    BorderRadius.circular(DesignTokens.scaled(scale).radius),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          history[i].question.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: DesignTokens.bodyFontSize,
                            fontWeight: FontWeight.w700,
                            color: palette.ink,
                          ),
                        ),
                        SizedBox(height: 2 * scale),
                        Text(
                          '${_subjectName(history[i].question.subjectId)} · '
                          '${formatRecentlyViewedTime(history[i].viewedAt)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: DesignTokens.captionFontSize,
                            color: palette.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: 8 * scale),
                  Text(
                    '›',
                    style: TextStyle(
                      fontSize: DesignTokens.bodyFontSize,
                      color: palette.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 下方格子：快速收集 + 每个学科各一格（HTML `.c-bottom` 4 列，
/// ≤900px 变 2 列、≤560px 变 1 列）。学科按库里的 subjects 表全部显示
///（B2，入库顺序）；格子超过一列能放的个数时按列数分行，不挤在一行、
/// 不丢（以前写死 4 格：4 列单行、2 列固定取前 4 格）。
class _BottomGrid extends StatelessWidget {
  const _BottomGrid({
    required this.scale,
    required this.palette,
    required this.subjects,
    required this.revCounts,
    required this.pendingCounts,
    required this.onGoCollect,
    required this.onGoWrongbook,
    required this.onGoReview,
  });

  final double scale;
  final AppPalette palette;

  /// 库里的全部学科（入库顺序）；为空时只显示快速收集格。
  final List<Subject> subjects;
  final Map<String, int> revCounts;
  final Map<String, int> pendingCounts;
  final VoidCallback onGoCollect;
  final void Function(String subjectId) onGoWrongbook;
  final VoidCallback onGoReview;

  @override
  Widget build(BuildContext context) {
    final minis = <Widget>[
      _MiniCell(
        scale: scale,
        palette: palette,
        title: '快速收集',
        titleColor: palette.ink,
        description:
            '只有一个入口：导入文件 PDF / JPG / PNG，导入后自动框出整题'
            '（手机拍的照片先传到电脑，再当普通文件导入）',
        actions: [
          QmButton(
            label: '去收集中心',
            variant: QmButtonVariant.primary,
            size: QmButtonSize.small,
            onPressed: onGoCollect,
          ),
        ],
      ),
      for (final s in subjects)
        _MiniCell(
          scale: scale,
          palette: palette,
          title: s.name,
          // B2：新学科的标题色 / 底色走库里存的 Subject.color
          //（subjectInk / subjectSoft 的 stored 回退），不落到数学色；
          // 预设三科传了存色也仍走主题固定色。
          titleColor: DesignTokens.subjectInk(
              s.id, Theme.of(context).brightness, s.color),
          background: DesignTokens.subjectSoft(
              s.id, Theme.of(context).brightness, s.color),
          description:
              '到期 ${revCounts[s.id] ?? 0} 道 · 待整理 ${pendingCounts[s.id] ?? 0} 道',
          actions: [
            QmButton(
              label: '错题本',
              variant: QmButtonVariant.plain,
              size: QmButtonSize.small,
              onPressed: () => onGoWrongbook(s.id),
            ),
            QmButton(
              label: '去复习',
              variant: QmButtonVariant.plain,
              size: QmButtonSize.small,
              onPressed: onGoReview,
            ),
          ],
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width > 900 ? 4 : (width > 560 ? 2 : 1);
        if (columns > 1) {
          // IntrinsicHeight：本页在纵向滚动视图里（高无界），Row 不能直接
          // 用 CrossAxisAlignment.stretch，须先由 IntrinsicHeight 定高，
          // 再让同行各格等高拉伸（HTML .c-bottom align-items:stretch）。
          // 格子按列数分行：4 格时与以前完全一致（4 列一行 / 2 列两行）；
          // 学科多了（B2：1 + N 格）就多出一行，不挤、不丢。
          final rows = <List<Widget>>[];
          for (var start = 0; start < minis.length; start += columns) {
            rows.add(minis.sublist(
                start,
                start + columns > minis.length
                    ? minis.length
                    : start + columns));
          }
          return Column(
            children: [
              for (var r = 0; r < rows.length; r++) ...[
                if (r > 0) SizedBox(height: DesignTokens.miniGap * scale),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < rows[r].length; i++) ...[
                        if (i > 0)
                          SizedBox(width: DesignTokens.miniGap * scale),
                        Expanded(child: rows[r][i]),
                      ],
                      // 末行不满时用空白 Expanded 补齐列数，保持各格同宽。
                      for (var i = rows[r].length; i < columns; i++) ...[
                        SizedBox(width: DesignTokens.miniGap * scale),
                        const Expanded(child: SizedBox()),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          );
        }
        return Column(
          children: [
            for (var i = 0; i < minis.length; i++) ...[
              if (i > 0) SizedBox(height: DesignTokens.miniGap * scale),
              minis[i],
            ],
          ],
        );
      },
    );
  }
}

/// 下方格子（HTML `.c-mini`：1px line 边、radius 12、padding 14×16、
/// surface 底；学科格用学科 soft 底 + 学科 ink 色标题）。
class _MiniCell extends StatelessWidget {
  const _MiniCell({
    required this.scale,
    required this.palette,
    required this.title,
    required this.titleColor,
    required this.description,
    required this.actions,
    this.background,
  });

  final double scale;
  final AppPalette palette;
  final String title;
  final Color titleColor;
  final String description;
  final List<Widget> actions;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        vertical: DesignTokens.miniPaddingV * scale,
        horizontal: DesignTokens.miniPaddingH * scale,
      ),
      decoration: BoxDecoration(
        color: background ?? palette.surface,
        border: Border.all(color: palette.line),
        borderRadius:
            BorderRadius.circular(DesignTokens.scaled(scale).radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: DesignTokens.bodyFontSize,
              fontWeight: FontWeight.w800,
              color: titleColor,
            ),
          ),
          SizedBox(height: 2 * scale),
          Text(
            description,
            style: TextStyle(
              fontSize: DesignTokens.captionFontSize,
              color: palette.muted,
            ),
          ),
          SizedBox(height: 10 * scale),
          Wrap(
            spacing: 8 * scale,
            runSpacing: 8 * scale,
            children: actions,
          ),
        ],
      ),
    );
  }
}

/// 最近任务 kind → 页面名（线上代码写 'organize' / 'collect'，演示数据
/// 种子写中文 '整理' / '收集'，两边都认；见 [_HomePageState] 的说明）。
String _kindPageName(String kind) => switch (kind) {
      'organize' || '整理' => '整理工作台',
      'collect' || '收集' => '收集中心',
      _ => '复习',
    };

/// 最近任务 kind → 继续条说明。
String _recentDescription(String kind) => switch (kind) {
      'organize' || '整理' => '上次停在待整理队列的这道题',
      'collect' || '收集' => '上次在这里导入了文件',
      _ => '上次复习到这里',
    };
