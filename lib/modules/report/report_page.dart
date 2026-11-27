import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/p3_review_entries.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../state/report_provider.dart';
import '../../state/repository_provider.dart';
import '../../state/review_notifier.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/uikit.dart';
import 'weak_point_list_page.dart';

/// 学习报告：只答三个问题——弱在哪、有没有效果、接下来练什么。
/// 无统计墙、无图表，纯数字与文字；打开即实时更新；无导出。
///
/// 结构与文案以 HTML 原型 `viewReport()` 为准（R0 附录 A）：
/// 标题 → 时间范围条（本周/本月/全部 + 范围说明）→ 有没有效果
/// （三个核心数一排）→ 接下来练什么（一句话）→ 弱在哪（最常错的
/// 5 个原因 / 最常错的 5 个知识点，两列）→ 错在哪个学科（纯文字）。
/// 弱点行按「学科 × 错因 / 学科 × 知识点」分组，点行进错题本打开
/// 对应学科那本并按该错因 / 知识点筛好。
///
/// 口径（FSRS 口径迁移，Meng 2026-11-25 定；D-259：软件不判定掌握，
/// 文案只用 FSRS 的词，不出现“已掌握/已解决”类数字）：
/// - 三个核心数按同一时间范围（本周/本月/全部）过滤，范围按
///   attempts.created_at 截取：正式复习答对按作答次数计（单位“次”）；
///   正式复习答错按题去重计（单位“题”）；正式复习答对率 = 已判分正式
///   作答里答对的占比，未判分不计入分母，无已判分记录时显示 —。
///   这是客观答对率，与旧的自查通过率不是同一回事。
/// - 弱点按错因：范围内正式答错的题按 attempt 的 cause_ids 归因，
///   按题数排；弱点按知识点：题目集合口径（只收已整理未归档的题，
///   不再排除“已掌握”题），按知识点分组、按题数排。
///   弱点计数按题 id，不按题名去重（SR-P1-10：题名不唯一，
///   同名不同题各算 1 道）。
/// - 按学科分布：各科在范围内有正式作答的题数（按题去重）。
/// - 本周 = 本周一到今天（基线口径；HTML 是今天往前 7 天，见报告）。
///
/// ARCH-PLAN-A 第 2 阶段 A 路：时间范围、三个核心数、弱点 Top 5、按学科
/// 分布、“接下来练什么”一句的读库逻辑收进 [reportProvider]
///（`lib/state/report_provider.dart`，口径见该文件）；本页只留 widget
/// 与纯界面临时状态（见 `_ReportPageState`）。`repo` 构造参数保留——
/// `app.dart` 仍按老样子传，本页在 build 里用一层 `ProviderScope` 把它
/// 以 `repositoryProvider.overrideWithValue(widget.repo)` 交进依赖图，
/// 不再直接调 `repo` 的方法。
class ReportPage extends ConsumerStatefulWidget {
  const ReportPage({
    super.key,
    required this.repo,
    required this.onGoReview,
    this.onGoCollect,
    this.onGoWrongbook,
    required this.onOpenWrongbookFiltered,
    this.onStartPracticeWithQuestions,
  });

  final QuestionRepository repo;
  final VoidCallback onGoReview;

  /// 空库空态的“去收集”入口（可空；app.dart 接 `/collect`）。
  /// 有题无正式作答的空态走 [onGoReview]，不需要它。
  final VoidCallback? onGoCollect;

  /// 库里有题但无一可复习的空态的“去错题本”入口（可空；app.dart 接
  /// `/wrongbook`，与复习页的 onGoWrongbook 同款）。只在新分支用；
  /// 不传时不显示按钮。
  final VoidCallback? onGoWrongbook;

  /// 点弱点行进错题本：打开对应学科那本，并按该错因 / 知识点筛好。
  /// P3 入口 3 起弱点行改为先进题目列表页；本回调保留作列表页里的
  /// “在错题本中查看”次入口。
  final void Function({
    String? subjectId,
    String? cause,
    String? knowledgePointId,
  })
  onOpenWrongbookFiltered;

  /// P3 入口 3：薄弱点列表页“开始专项练习”（题 id + 数量；只练不排）。
  /// 可空：不传时回落到去复习页（选题页）。
  final void Function(List<String> questionIds, {int? count})?
  onStartPracticeWithQuestions;

  @override
  ConsumerState<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends ConsumerState<ReportPage> {
  // 纯界面临时状态，留页面本地（不进 Provider）：读库失败横幅的“已关闭”
  // 标志、两组弱点“看更多”的展开/收起（切范围时由分段器 onChanged 重置）。
  bool _errorDismissed = false;
  bool _expandCauses = false;
  bool _expandKps = false;

  @override
  Widget build(BuildContext context) {
    // 构造器接进来的 repo（应用层传的单例库 / 测试传的 FakeRepo）只在
    // 这里交进 Riverpod 依赖图：`reportProvider` 的 Notifier 经
    // `repositoryProvider` 拿库；本页不再直接调 `repo` 的方法。
    // 内层 Consumer 的 ref 才属于这层 scope（外层 `ref` 拿不到 override
    // 后的库），读状态与调 `setRange()` 都用内层 ref。
    return ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(widget.repo)],
      child: Consumer(
        builder: (context, ref, _) {
          final report = ref.watch(reportProvider);
          return _buildBody(context, ref, report);
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref, ReportState report) {
    if (report.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);

    // 空态（四态，V11；包 6 → 跟进批 5 收紧）：零正式作答时才进空态
    // （与范围无关），有正式作答即按有数据展示——题已删的 attempts
    // 孤儿也在此列，核心数照算（见 report_stats.dart 头注）。
    // loadError 时不进空态（旧行为：留住上次内容 + 横幅）。
    // 三支文案与按钮分别定义，不共用：
    // ① 有已整理未归档的题 → 旧文案 + 去复习；
    // ④ 库里有题但无一可复习（全未整理 / 全已归档 / 混合）→ 去错题本
    // （整理 / 取消归档）；② 空库 → 去收集（文案一字不动）。
    if (!report.hasFormalAttempts && !report.loadError) {
      final hasQuestions = report.hasQuestions;
      final hasAnyQuestions = report.hasAnyQuestions;
      final String title;
      final String description;
      final String? actionLabel;
      final VoidCallback? onAction;
      if (hasQuestions) {
        title = '还没有复习记录，先去复习吧';
        description =
            '在复习页按三步（看题、作答、核对）练几道题，回来这里就会告诉你弱在哪、有没有效果、接下来练什么。';
        actionLabel = '去复习';
        onAction = widget.onGoReview;
      } else if (hasAnyQuestions) {
        title = '这些题还不能复习';
        description =
            '库里的题还没有整理、或已经归档了。去错题本把它们整理好、或取消归档，再去复习，回来这里就会告诉你弱在哪、有没有效果、接下来练什么。';
        actionLabel = widget.onGoWrongbook == null ? null : '去错题本';
        onAction = widget.onGoWrongbook;
      } else {
        title = '这里还没有题目，先去收集吧';
        description =
            '去收集中心导入第一道题吧，回来这里就会告诉你弱在哪、有没有效果、接下来练什么。';
        actionLabel = widget.onGoCollect == null ? null : '去收集';
        onAction = widget.onGoCollect;
      }
      return SingleChildScrollView(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('学习报告', style: Theme.of(context).textTheme.titleLarge),
            SizedBox(height: 14 * scale),
            QmEmptyState(
              title: title,
              description: description,
              actionLabel: actionLabel,
              onAction: onAction,
            ),
          ],
        ),
      );
    }

    // 三个核心数、弱点 Top 5、按学科分布、“接下来练什么”一句都在
    // ReportState 里派生（`lib/state/report_provider.dart`，FSRS 口径）；
    // 本页只取数渲染，不再自己算。
    final causeTop = report.causeGroups;
    final kpTop = report.kpGroups;
    final nextSentence = report.nextSentence;

    final wide =
        MediaQuery.sizeOf(context).width > DesignTokens.organizeGridBreakpoint;
    final brightness = Theme.of(context).brightness;

    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('学习报告', style: Theme.of(context).textTheme.titleLarge),
          SizedBox(height: 14 * scale),
          if (report.loadError && !_errorDismissed)
            QmBanner(
              tone: QmBannerTone.error,
              message: '报告数据读取失败，已显示上次成功加载的内容。可重启应用后重试。',
              onDismiss: () => setState(() => _errorDismissed = true),
            ),
          Wrap(
            spacing: DesignTokens.reportRangeBarGap * scale,
            runSpacing: 8 * scale,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              QmSegmented<String>(
                options: const [
                  QmSegmentOption(value: 'week', label: '本周'),
                  QmSegmentOption(value: 'month', label: '本月'),
                  QmSegmentOption(value: 'all', label: '全部'),
                ],
                value: report.range,
                onChanged: (v) {
                  ref.read(reportProvider.notifier).setRange(v);
                  setState(() {
                    _expandCauses = false;
                    _expandKps = false;
                  });
                },
              ),
              Text(
                report.rangeNote,
                style: TextStyle(
                  fontSize: DesignTokens.reportRangeNoteFontSize,
                  color: palette.muted,
                ),
              ),
            ],
          ),
          SizedBox(
            height:
                (DesignTokens.reportRangeBarMarginBottom +
                    DesignTokens.reportSectionMarginTop) *
                scale,
          ),
          _sectionTitle('有没有效果', palette),
          SizedBox(
            height:
                (DesignTokens.reportSectionMarginBottom +
                    DesignTokens.reportCoreMarginTop) *
                scale,
          ),
          _coreStrip(
            palette,
            scale,
            formalCorrectCount: report.formalCorrectCount,
            formalWrongQuestionCount: report.formalWrongQuestionCount,
            passRate: report.passRate,
            gradedTotal: report.gradedFormalCount,
            gradedCorrect: report.gradedFormalCorrectCount,
          ),
          SizedBox(height: DesignTokens.reportSuggestMarginTop * scale),
          _suggestion(palette, scale, nextSentence),
          SizedBox(height: DesignTokens.reportSectionMarginTop * scale),
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _weakList(
                    report: report,
                    palette: palette,
                    brightness: brightness,
                    scale: scale,
                    title: '最常错的 5 个原因',
                    groups: causeTop,
                    expanded: _expandCauses,
                    onToggleExpand: () =>
                        setState(() => _expandCauses = !_expandCauses),
                    onTap: (g) => _openWeakList(context, ref, report, g, false),
                  ),
                ),
                SizedBox(width: DesignTokens.reportTwoColGap * scale),
                Expanded(
                  child: _weakList(
                    report: report,
                    palette: palette,
                    brightness: brightness,
                    scale: scale,
                    title: '最常错的 5 个知识点',
                    groups: kpTop,
                    expanded: _expandKps,
                    onToggleExpand: () =>
                        setState(() => _expandKps = !_expandKps),
                    onTap: (g) => _openWeakList(context, ref, report, g, true),
                    isKp: true,
                  ),
                ),
              ],
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _weakList(
                  report: report,
                  palette: palette,
                  brightness: brightness,
                  scale: scale,
                  title: '最常错的 5 个原因',
                  groups: causeTop,
                  expanded: _expandCauses,
                  onToggleExpand: () =>
                      setState(() => _expandCauses = !_expandCauses),
                  onTap: (g) => _openWeakList(context, ref, report, g, false),
                ),
                SizedBox(height: DesignTokens.reportSectionMarginTop * scale),
                _weakList(
                  report: report,
                  palette: palette,
                  brightness: brightness,
                  scale: scale,
                  title: '最常错的 5 个知识点',
                  groups: kpTop,
                  expanded: _expandKps,
                  onToggleExpand: () =>
                      setState(() => _expandKps = !_expandKps),
                  onTap: (g) => _openWeakList(context, ref, report, g, true),
                  isKp: true,
                ),
              ],
            ),
          SizedBox(height: DesignTokens.reportSectionMarginTop * scale),
          _sectionTitle('各科正式作答（只按学科看）', palette),
          SizedBox(height: DesignTokens.reportSectionMarginBottom * scale),
          for (var i = 0; i < report.subjects.length; i++)
            _distRow(
              palette,
              scale,
              subject: report.subjects[i],
              count: report.answeredBySubject[report.subjects[i].id] ?? 0,
              last: i == report.subjects.length - 1,
            ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title, AppPalette palette) {
    return Text(
      title,
      style: TextStyle(
        fontSize: DesignTokens.homeSectionTitleFontSize,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.08,
        color: palette.muted,
      ),
    );
  }

  /// 三个核心数一排（HTML `.rpt-core` / `.rpt-num`；FSRS 口径，
  /// 单位写清：答对按作答次数计，答错按题计，答对率是客观答对率）。
  Widget _coreStrip(
    AppPalette palette,
    double scale, {
    required int formalCorrectCount,
    required int formalWrongQuestionCount,
    required int? passRate,
    required int gradedTotal,
    required int gradedCorrect,
  }) {
    final rateSmall = gradedTotal == 0
        ? '这段时间还没有已判分的正式复习作答'
        : '正式复习 $gradedTotal 次已判分，答对 $gradedCorrect 次'
              ' · 客观答对率';
    final cells = [
      _CoreCell(
        valueKey: const ValueKey('report-core-formal-correct'),
        value: '$formalCorrectCount',
        label: '正式复习答对',
        small: '按作答次数计',
      ),
      _CoreCell(
        valueKey: const ValueKey('report-core-formal-wrong'),
        value: '$formalWrongQuestionCount',
        label: '正式复习答错',
        small: '按题数计',
      ),
      _CoreCell(
        valueKey: const ValueKey('report-core-formal-rate'),
        value: passRate == null ? '—' : '$passRate%',
        label: '正式复习答对率',
        small: rateSmall,
      ),
    ];
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: palette.line, width: 2),
          bottom: BorderSide(color: palette.line, width: 1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < cells.length; i++)
            Expanded(
              child: Container(
                decoration: i == 0
                    ? null
                    : BoxDecoration(
                        border: Border(
                          left: BorderSide(color: palette.line, width: 1),
                        ),
                      ),
                child: cells[i].build(palette, scale),
              ),
            ),
        ],
      ),
    );
  }

  /// “接下来练什么”一句话，无按钮（HTML `.rpt-sug`）。
  Widget _suggestion(AppPalette palette, double scale, String sentence) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '接下来练什么',
          style: TextStyle(
            fontSize: DesignTokens.reportSuggestFontSize,
            fontWeight: FontWeight.w800,
            color: palette.ink,
            height: DesignTokens.bodyLineHeight,
          ),
        ),
        SizedBox(width: DesignTokens.reportSuggestGap * scale),
        Expanded(
          child: Text(
            sentence,
            style: TextStyle(
              fontSize: DesignTokens.reportSuggestFontSize,
              color: palette.ink,
              height: DesignTokens.bodyLineHeight,
            ),
          ),
        ),
      ],
    );
  }

  /// P3 入口 3：弱点行样本量文案（题目数 / 作答次数 / 答错次数 /
  /// 近期错误率 / 时间范围；样本少标“数据较少”）。
  String _weakSampleText(ReportState report, WeakGroup group) {
    final stats = report.weakStats(group);
    return '${stats.label}${stats.sparse ? ' · 数据较少' : ''}';
  }

  /// P3 入口 3：点弱点行 → 薄弱点题目列表页（不再直接进错题本）。
  void _openWeakList(
    BuildContext context,
    WidgetRef ref,
    ReportState report,
    WeakGroup group,
    bool isKp,
  ) {
    // 同一题多标签按 question_id 去重，保序。
    final seen = <String>{};
    final questions = [
      for (final q in report.questions)
        if (group.questionIds.contains(q.id) && seen.add(q.id)) q,
    ];
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WeakPointListPage(
          group: group,
          report: report,
          questions: questions,
          isKp: isKp,
          onStartPractice: (ids, {count}) {
            final start = widget.onStartPracticeWithQuestions;
            if (start != null) {
              start(ids, count: count);
            } else {
              widget.onGoReview();
            }
          },
          onJoinReview: (ids) async {
            final qs = [
              for (final q in questions)
                if (ids.contains(q.id)) q,
            ];
            final result = await widget.repo.joinFsrsPool(
              questions: qs,
              scheduler: ref.read(reviewSchedulerProvider),
            );
            // 刷新池内标记：重读报告（load 会重读 fsrsPoolIds）。
            await ref.read(reportProvider.notifier).load();
            return fsrsBatchMessage(
              FsrsBatchOutcome(
                added: result.added,
                skipped: result.skipped,
                failed: result.failed,
              ),
            );
          },
          onOpenInWrongbook: () => widget.onOpenWrongbookFiltered(
            subjectId: group.subjectId,
            cause: isKp ? null : group.key,
            knowledgePointId: isKp ? group.key : null,
          ),
        ),
      ),
    );
  }

  Widget _weakList({
    required ReportState report,
    required AppPalette palette,
    required Brightness brightness,
    required double scale,
    required String title,
    required List<WeakGroup> groups,
    required bool expanded,
    required VoidCallback onToggleExpand,
    required void Function(WeakGroup) onTap,
    bool isKp = false,
  }) {
    final shown = expanded ? groups : groups.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(title, palette),
        SizedBox(height: DesignTokens.reportSectionMarginBottom * scale),
        if (groups.isEmpty)
          Text(
            isKp ? '这段时间没有带知识点的错题。' : '这段时间正式复习还没有答错的题。',
            style: TextStyle(
              fontSize: DesignTokens.reportWeakEmptyFontSize,
              color: palette.ink,
            ),
          )
        else ...[
          for (var i = 0; i < shown.length; i++)
            _weakRow(
              palette,
              brightness,
              scale,
              rank: i + 1,
              group: shown[i],
              onTap: () => onTap(shown[i]),
              report: report,
              isKp: isKp,
            ),
          if (groups.length > 5) ...[
            SizedBox(height: DesignTokens.reportMoreMarginTop * scale),
            QmButton(
              label: expanded ? '收起' : '看更多（共 ${groups.length} 个）',
              size: QmButtonSize.small,
              variant: QmButtonVariant.plain,
              onPressed: onToggleExpand,
            ),
          ],
        ],
      ],
    );
  }

  /// 弱点行（HTML `.rpt-row`）：序号圆 + 学科 · 错因/知识点 + 题名 +
  /// 计数 + ›；点行进薄弱点题目列表页（P3 入口 3，D8）。
  ///
  /// 行内同时显示样本量（P3）：题目数 / 作答次数 / 答错次数 /
  /// 近期错误率 / 时间范围，样本少标“数据较少”。
  Widget _weakRow(
    AppPalette palette,
    Brightness brightness,
    double scale, {
    required ReportState report,
    required int rank,
    required WeakGroup group,
    required VoidCallback onTap,
    required bool isKp,
  }) {
    // 弱点行学科名与颜色取库里的学科（B2 补充）：新学科以前走
    // Subject.byId 回退到数学名 + subjectInk 不传存色落到数学色。
    final subject = report.subjectOf(group.subjectId);
    final subjectName = subject.name;
    final subjectColor = DesignTokens.subjectInk(
      group.subjectId,
      brightness,
      subject.color,
    );
    final title = isKp ? report.kpName(group.key) : group.key;
    final detail = isKp
        ? '$subjectName${(report.kpOf(group.key)?.chapter.isNotEmpty ?? false) ? ' › ${report.kpOf(group.key)!.chapter}' : ''} · ${group.titles.join('、')}'
        : group.titles.join('、');
    final countText = '${group.count} 道题';
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.line, width: 1)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          hoverColor: palette.surface2,
          child: Container(
            constraints: BoxConstraints(
              minHeight: DesignTokens.reportRowMinHeight * scale,
            ),
            padding: EdgeInsets.symmetric(
              vertical: DesignTokens.reportRowPaddingV * scale,
              horizontal: DesignTokens.reportRowPaddingH * scale,
            ),
            child: Row(
              children: [
                Container(
                  width: DesignTokens.reportRankSize * scale,
                  height: DesignTokens.reportRankSize * scale,
                  decoration: BoxDecoration(
                    color: palette.accentSoft,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$rank',
                    style: TextStyle(
                      fontSize: DesignTokens.reportRankFontSize,
                      fontWeight: FontWeight.w800,
                      color: palette.accentText,
                      height: DesignTokens.controlLineHeight,
                    ),
                  ),
                ),
                SizedBox(width: 10 * scale),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text.rich(
                        TextSpan(
                          style: TextStyle(
                            fontSize: DesignTokens.reportRowTitleFontSize,
                            fontWeight: FontWeight.w700,
                            color: palette.ink,
                            height: DesignTokens.controlLineHeight,
                          ),
                          children: [
                            TextSpan(
                              text: subjectName,
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: subjectColor,
                              ),
                            ),
                            TextSpan(text: ' · $title'),
                          ],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: DesignTokens.reportRowDetailFontSize,
                          color: palette.muted,
                        ),
                      ),
                      // P3 入口 3：样本量行（口径见 report_provider.WeakSampleStats）。
                      Text(
                        _weakSampleText(report, group),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: DesignTokens.reportRowDetailFontSize,
                          color: palette.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: 10 * scale),
                Text(
                  countText,
                  style: TextStyle(
                    fontSize: DesignTokens.bodyFontSize,
                    fontWeight: FontWeight.w800,
                    color: palette.ink,
                  ),
                ),
                SizedBox(width: 10 * scale),
                Text(
                  QmGlyphs.chevronRight,
                  style: TextStyle(
                    fontSize: DesignTokens.bodyFontSize,
                    color: palette.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 学科分布行（HTML `.rowline`）：纯文字，无图表。
  Widget _distRow(
    AppPalette palette,
    double scale, {
    required Subject subject,
    required int count,
    required bool last,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        vertical: DesignTokens.reportDistRowPaddingV * scale,
        horizontal: DesignTokens.reportDistRowPaddingH * scale,
      ),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(bottom: BorderSide(color: palette.line, width: 1)),
      ),
      child: Text(
        '${subject.name} · 作答 $count 道',
        style: TextStyle(
          fontSize: DesignTokens.bodyFontSize,
          fontWeight: FontWeight.w700,
          color: palette.ink,
        ),
      ),
    );
  }
}

class _CoreCell {
  const _CoreCell({
    required this.valueKey,
    required this.value,
    required this.label,
    required this.small,
  });

  final Key valueKey;
  final String value;
  final String label;
  final String small;

  Widget build(AppPalette palette, double scale) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        DesignTokens.reportCorePaddingH * scale,
        DesignTokens.reportCorePaddingTop * scale,
        DesignTokens.reportCorePaddingH * scale,
        DesignTokens.reportCorePaddingBottom * scale,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            key: valueKey,
            style: TextStyle(
              fontSize: DesignTokens.reportCoreNumberFontSize,
              height: DesignTokens.reportCoreNumberLineHeight,
              fontWeight: FontWeight.w800,
              color: palette.ink,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: DesignTokens.reportCoreLabelFontSize,
              fontWeight: FontWeight.w700,
              color: palette.ink,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            small,
            style: TextStyle(
              fontSize: DesignTokens.reportCoreSmallFontSize,
              height: 1.5,
              color: palette.muted,
            ),
          ),
        ],
      ),
    );
  }
}
