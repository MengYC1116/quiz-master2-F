import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repository.dart';
import '../../models/models.dart';
import '../../state/report_provider.dart';
import '../../state/repository_provider.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/uikit.dart';

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
/// 口径（与 HTML 的对照见 R9-REPORT §6）：
/// - 三个核心数按同一时间范围（本周/本月/全部）过滤：已解决按
///   `lastCheck` 在范围内计；待解决同样按 `lastCheck` 在范围内计
///   （S8 B1，Meng 2026-11-13 裁决，原 R0 §6-B-1）；复查通过率按
///   范围内已判定的自查记录计（`review_history` 无复查备注字段，
///   以全部已判定记录为近似）。
/// - `lastCheck` 是近似代理：模型无“治愈日期”/“待解决起始日”字段，
///   `lastCheck` 是最近一次自查时间；从未自查的错因 `lastCheck` 为
///   空，与已解决数同一分支，视为在范围内、计入所有范围。
/// - 弱点与学科分布按所选范围内收集的题目算（HTML `qsIn` / QDATE 口径，
///   以题目 `createdAt` 为收集日期），只收已整理未归档且未掌握的题，与错题本
///   列表默认收录口径一致（SR-P1-11：未整理题、已归档题不算进来；
///   SR2-29：已掌握题不算进来，分布数 = 该科封面总数）：
///   错因行只含未解决的错因，无记录的错因默认待解决；知识点行排除
///   全部错因已解决的题。弱点计数按题 id，不按题名去重（SR-P1-10：
///   题名不唯一，同名不同题各算 1 道）。
///   已掌握的定义与错题本 / 首页同一口径：按该题现存的全部错因记录算
///   `QuestionRepository.reviewBucketOf(records) == ReviewBucket.solved`，
///   不按当前错因逐因查记录——退出复习后改错因会留下陈旧记录（已删错因
///   的记录残留、新错因无记录），逐因查会与错题本双向偏离 1 道（SR3-2）。
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
    required this.onOpenWrongbookFiltered,
  });

  final QuestionRepository repo;
  final VoidCallback onGoReview;

  /// 点弱点行进错题本：打开对应学科那本，并按该错因 / 知识点筛好。
  final void Function({
    String? subjectId,
    String? cause,
    String? knowledgePointId,
  }) onOpenWrongbookFiltered;

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

    // 空态：没有任何复习记录（HTML `state==='empty'` 的形态）。
    if (report.records.isEmpty && !report.loadError) {
      return SingleChildScrollView(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('学习报告', style: Theme.of(context).textTheme.titleLarge),
            SizedBox(height: 14 * scale),
            QmEmptyState(
              title: '还没有复习记录，先去复习吧',
              description:
                  '在复习页按四步解决几个错因，回来这里就会告诉你弱在哪、有没有效果、接下来练什么。',
              actionLabel: '去复习',
              onAction: widget.onGoReview,
            ),
          ],
        ),
      );
    }

    // 三个核心数、弱点 Top 5、按学科分布、“接下来练什么”一句都在
    // ReportState 里派生（`lib/state/report_provider.dart`，S8 B1 口径）；
    // 本页只取数渲染，不再自己算。
    final qsIn = report.questionsInRange;
    final causeTop = report.causeGroups;
    final kpTop = report.kpGroups;
    final nextSentence = report.nextSentence;

    final wide = MediaQuery.sizeOf(context).width >
        DesignTokens.organizeGridBreakpoint;
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
            height: (DesignTokens.reportRangeBarMarginBottom +
                    DesignTokens.reportSectionMarginTop) *
                scale,
          ),
          _sectionTitle('有没有效果', palette),
          SizedBox(
            height: (DesignTokens.reportSectionMarginBottom +
                    DesignTokens.reportCoreMarginTop) *
                scale,
          ),
          _coreStrip(
            palette,
            scale,
            settings: report.settings,
            solvedCount: report.solvedCount,
            pendingCount: report.pendingCount,
            passRate: report.passRate,
            judgedTotal: report.judgedHistory.length,
            judgedPassed: report.judgedPassed,
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
                    title: '最常错的5个原因',
                    groups: causeTop,
                    expanded: _expandCauses,
                    onToggleExpand: () =>
                        setState(() => _expandCauses = !_expandCauses),
                    onTap: (g) => widget.onOpenWrongbookFiltered(
                      subjectId: g.subjectId,
                      cause: g.key,
                    ),
                  ),
                ),
                SizedBox(width: DesignTokens.reportTwoColGap * scale),
                Expanded(
                  child: _weakList(
                    report: report,
                    palette: palette,
                    brightness: brightness,
                    scale: scale,
                    title: '最常错的5个知识点',
                    groups: kpTop,
                    expanded: _expandKps,
                    onToggleExpand: () =>
                        setState(() => _expandKps = !_expandKps),
                    onTap: (g) => widget.onOpenWrongbookFiltered(
                      subjectId: g.subjectId,
                      knowledgePointId: g.key,
                    ),
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
                  title: '最常错的5个原因',
                  groups: causeTop,
                  expanded: _expandCauses,
                  onToggleExpand: () =>
                      setState(() => _expandCauses = !_expandCauses),
                  onTap: (g) => widget.onOpenWrongbookFiltered(
                    subjectId: g.subjectId,
                    cause: g.key,
                  ),
                ),
                SizedBox(height: DesignTokens.reportSectionMarginTop * scale),
                _weakList(
                  report: report,
                  palette: palette,
                  brightness: brightness,
                  scale: scale,
                  title: '最常错的5个知识点',
                  groups: kpTop,
                  expanded: _expandKps,
                  onToggleExpand: () =>
                      setState(() => _expandKps = !_expandKps),
                  onTap: (g) => widget.onOpenWrongbookFiltered(
                    subjectId: g.subjectId,
                    knowledgePointId: g.key,
                  ),
                  isKp: true,
                ),
              ],
            ),
          SizedBox(height: DesignTokens.reportSectionMarginTop * scale),
          _sectionTitle('错在哪个学科（只按学科看）', palette),
          SizedBox(height: DesignTokens.reportSectionMarginBottom * scale),
          for (var i = 0; i < report.subjects.length; i++)
            _distRow(
              palette,
              scale,
              subject: report.subjects[i],
              count: qsIn.where((q) => q.subjectId == report.subjects[i].id).length,
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

  /// 三个核心数一排（HTML `.rpt-core` / `.rpt-num`）。
  Widget _coreStrip(
    AppPalette palette,
    double scale, {
    required AppSettings settings,
    required int solvedCount,
    required int pendingCount,
    required int? passRate,
    required int judgedTotal,
    required int judgedPassed,
  }) {
    final rateSmall = judgedTotal == 0
        ? '这段时间还没有复查记录'
        : '复查 $judgedTotal 次，通过 $judgedPassed 次'
            '（已解决满 ${settings.recheckIntervalDays} 天回来复查）';
    final cells = [
      _CoreCell(
        valueKey: const ValueKey('report-core-solved'),
        value: '$solvedCount',
        label: '已解决错因',
        small: '同一错因 ${settings.cureChecks} 次自查「已解决」才算解决',
      ),
      _CoreCell(
        valueKey: const ValueKey('report-core-pending'),
        value: '$pendingCount',
        label: '待解决错因',
        small: '待解决 + 解决中，还留在复习列表里',
      ),
      _CoreCell(
        valueKey: const ValueKey('report-core-rate'),
        value: passRate == null ? '—' : '$passRate%',
        label: '复查通过率',
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
            isKp ? '这段时间没有还没解决的知识点。' : '这段时间没有待解决的错因。',
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
  /// 计数 + ›；点行进错题本。
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
    final subjectColor =
        DesignTokens.subjectInk(group.subjectId, brightness, subject.color);
    final title = isKp ? report.kpName(group.key) : group.key;
    final detail = isKp
        ? '$subjectName${(report.kpOf(group.key)?.chapter.isNotEmpty ?? false) ? ' › ${report.kpOf(group.key)!.chapter}' : ''} · ${group.titles.join('、')}'
        : group.titles.join('、');
    final countText = isKp ? '还没解决 ${group.count} 道' : '${group.count} 道题';
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
                            fontSize:
                                DesignTokens.reportRowTitleFontSize,
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
        '${subject.name} · $count 道错题',
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
