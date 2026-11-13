// 首页（R3 重建，layout C 焦点大卡片）。
//
// 视觉来源：交互原型 `viewHome` / `viewHomeC` / `homeCBottomHTML`
//（`.main h3.pt` / `.psub` / `.focus-card` / `.fc-continue` /
// `.secttl` / `.c-bottom` / `.c-mini`），只按实际渲染的页面实现：
// - 问候语 24px/800（`DesignTokens.pageTitleFontSize`，不是 34px 的
//   `.ahead h1`）+ 副标题“上次停在：…”；问候语取设置里的 greeting，
//   默认“今天也要加油呀”，设置存储不动。
// - 焦点大卡片：整卡可点去复习；卡内“要复习 N 道”（46px/800）+
//   “待解决 X 道 · 复查 Y 道”；下半部“继续上次”条（小伙伴 +
//   文字 +「继续上次」主按钮，按钮点按不触发整卡去复习）。
// - 下方 4 格：快速收集 + 三科各一格，每格“要复习 N 道 · 待整理 M 道”
//   +「错题本」「去复习」按钮。
// - 空状态：无要复习时卡片变中性样式，文案“今天没有要复习的，明天再来吧”。
// - 错误态：顶部红色横幅（手动备份失败，见 [showBackupError]）。
//
// 业务口径（repository 现有口径，本页不改 repository）：
// - 要复习数与导航速览同一口径（`homeRevCounts` / `dueToday`：手动加入
//   复习且已整理且至少一个错因未解决或已到复查时间，数题不数错因）；
//   待解决 / 复查拆分按 HTML `homeRevCounts`：有未解决错因的题计
//   待解决，只有复查到期的题计复查（本页用 `dueToday` + `causeRecords`
//   现算，不改 repository）。
// - 继续上次 = `recentTask()` 的最近任务（复习 > 整理 > 收集优先级
//   沿用现有逻辑：无记录时默认去复习）；快速收集只做文件导入入口，
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

import '../../data/repository.dart';
import '../../models/models.dart';
import '../../theme/app_theme.dart';
import '../../widgets/uikit.dart';

/// 首页：问候 + 焦点大卡片（要复习的数量）+ 继续上次 + 快速收集 +
/// 各学科要复习 / 待整理概览，学科顺序固定数学 / 英语 / 政治。
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.repo,
    required this.settings,
    required this.onGoCollect,
    required this.onGoOrganize,
    required this.onGoWrongbook,
    required this.onGoReview,
    this.showBackupError = false,
  });

  final QuestionRepository repo;
  final AppSettings settings;
  final VoidCallback onGoCollect;
  final VoidCallback onGoOrganize;
  final void Function(String subjectId) onGoWrongbook;
  final VoidCallback onGoReview;

  /// 手动备份失败时显示顶部红色横幅（HTML 首页错误态文案）。
  /// 基线里没有“设置页备份失败 → 首页横幅”的跨页通道（设置页
  /// `_backup` 失败时无任何状态外传），所以这里只留开关：调用方
  /// 在确认备份失败后传 true 即可触发；平时为 false，不显示。
  /// 接线方式见 R3 报告未解决问题。
  final bool showBackupError;

  /// HTML 首页错误态横幅文案（原型 `viewHome` 的 `errBanner` 原文）。
  static const String backupFailedMessage =
      '本地数据备份失败：磁盘空间不足，新收集的题目已保存在本地库中，'
      '但这次手动备份没有完成。请清理磁盘后在「设置」中重新备份。';

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Map<String, int>? _revCounts;
  Map<String, int>? _pendingCounts;
  int _duePending = 0;
  int _dueRecheck = 0;
  ({String kind, String subjectId, String title})? _recent;
  bool _loading = true;
  bool _errorDismissed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      widget.repo.homeRevCounts(),
      widget.repo.pendingOrganizeBySubject(),
      widget.repo.recentTask(),
      widget.repo.dueToday(),
      widget.repo.causeRecords(),
    ]);
    if (!mounted) return;
    final due = results[3] as List<Question>;
    final records = results[4] as List<CauseRecord>;
    final byQ = <String, List<CauseRecord>>{};
    for (final r in records) {
      (byQ[r.questionId] ??= []).add(r);
    }
    // 待解决 / 复查拆分（HTML homeRevCounts）：有未解决错因的题计
    // 待解决；只有复查到期的题计复查；两者之和 = 要复习总数。
    var pending = 0;
    var recheck = 0;
    for (final q in due) {
      final rs = byQ[q.id] ?? const <CauseRecord>[];
      if (rs.any((r) => r.status != CauseStatus.solved)) {
        pending++;
      } else {
        recheck++;
      }
    }
    setState(() {
      _revCounts = results[0] as Map<String, int>;
      _pendingCounts = results[1] as Map<String, int>;
      _recent = results[2] as ({String kind, String subjectId, String title})?;
      _duePending = pending;
      _dueRecheck = recheck;
      _loading = false;
    });
  }

  int get _totalDue => _duePending + _dueRecheck;

  /// 最近任务的 kind 归一化：线上代码写 'organize' / 'collect'，
  /// 但演示数据种子（`database.dart` 的 `_seedDemo`）写的是中文
  /// '整理'（基线 `_resumeRecent` 的 switch 只认英文，种子行会
  /// 误落到默认“复习”）。本页两边都认，不改 repository 与种子。
  String _normalizedKind(String kind) => switch (kind) {
        'organize' || '整理' => 'organize',
        'collect' || '收集' => 'collect',
        _ => 'review',
      };

  void _resumeRecent() {
    switch (_normalizedKind(_recent?.kind ?? '')) {
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
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    return SingleChildScrollView(
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
            _recent == null
                ? '上次停在：还没有记录'
                : '上次停在：${_kindPageName(_recent!.kind)} · '
                    '${Subject.byId(_recent!.subjectId).name}「${_recent!.title}」',
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
              onDismiss: () => setState(() => _errorDismissed = true),
            ),
          // 焦点大卡片 layout C。
          if (_loading)
            _FocusCardLoading(scale: scale)
          else if (_totalDue == 0)
            _FocusCardEmpty(scale: scale, palette: palette)
          else
            _FocusCard(
              scale: scale,
              palette: palette,
              totalDue: _totalDue,
              duePending: _duePending,
              dueRecheck: _dueRecheck,
              recent: _recent,
              onTapCard: widget.onGoReview,
              onResume: _resumeRecent,
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
          if (!_loading)
            _BottomGrid(
              scale: scale,
              palette: palette,
              revCounts: _revCounts ?? const {},
              pendingCounts: _pendingCounts ?? const {},
              onGoCollect: widget.onGoCollect,
              onGoWrongbook: widget.onGoWrongbook,
              onGoReview: widget.onGoReview,
            ),
        ],
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
            '今天没有要复习的，明天再来吧',
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
            '要复习 0 道 · 没有待解决的错因，也没有到复查时间的题',
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
    required this.duePending,
    required this.dueRecheck,
    required this.recent,
    required this.onTapCard,
    required this.onResume,
    required this.onGoCollect,
  });

  final double scale;
  final AppPalette palette;
  final int totalDue;
  final int duePending;
  final int dueRecheck;
  final ({String kind, String subjectId, String title})? recent;
  final VoidCallback onTapCard;
  final VoidCallback onResume;
  final VoidCallback onGoCollect;

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
              '$totalDue 道要复习',
              style: TextStyle(
                fontSize: DesignTokens.focusNumberFontSize,
                fontWeight: DesignTokens.focusNumberFontWeight,
                height: DesignTokens.focusNumberLineHeight,
                color: palette.ink,
              ),
            ),
            SizedBox(height: 2 * scale),
            Text(
              dueRecheck > 0
                  ? '待解决 $duePending 道 · 复查 $dueRecheck 道'
                  : '待解决 $duePending 道',
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
                                  '${Subject.byId(recent!.subjectId).name}'
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

/// 下方 4 格：快速收集 + 三科各一格（HTML `.c-bottom` 4 列，
/// ≤900px 变 2 列、≤560px 变 1 列）。
class _BottomGrid extends StatelessWidget {
  const _BottomGrid({
    required this.scale,
    required this.palette,
    required this.revCounts,
    required this.pendingCounts,
    required this.onGoCollect,
    required this.onGoWrongbook,
    required this.onGoReview,
  });

  final double scale;
  final AppPalette palette;
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
      for (final s in Subject.all)
        _MiniCell(
          scale: scale,
          palette: palette,
          title: s.name,
          titleColor: DesignTokens.subjectInk(s.id, Theme.of(context).brightness),
          background: DesignTokens.subjectSoft(s.id, Theme.of(context).brightness),
          description:
              '要复习 ${revCounts[s.id] ?? 0} 道 · 待整理 ${pendingCounts[s.id] ?? 0} 道',
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
        if (columns == 4) {
          // IntrinsicHeight：本页在纵向滚动视图里（高无界），Row 不能直接
          // 用 CrossAxisAlignment.stretch，须先由 IntrinsicHeight 定高，
          // 再让四格等高拉伸（HTML .c-bottom align-items:stretch）。
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < minis.length; i++) ...[
                  if (i > 0) SizedBox(width: DesignTokens.miniGap * scale),
                  Expanded(child: minis[i]),
                ],
              ],
            ),
          );
        }
        if (columns == 2) {
          return Column(
            children: [
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: minis[0]),
                    SizedBox(width: DesignTokens.miniGap * scale),
                    Expanded(child: minis[1]),
                  ],
                ),
              ),
              SizedBox(height: DesignTokens.miniGap * scale),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: minis[2]),
                    SizedBox(width: DesignTokens.miniGap * scale),
                    Expanded(child: minis[3]),
                  ],
                ),
              ),
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
