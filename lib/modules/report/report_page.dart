import 'package:flutter/material.dart';

import '../../data/repository.dart';
import '../../models/models.dart';
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
/// - 三个核心数沿用基线 `report_page.dart` 的算式，不动：已解决按
///   `lastCheck` 在范围内计；待解决不按范围过滤（R0 §6-B-1，待裁决）；
///   复查通过率按范围内已判定的自查记录计（`review_history` 无复查
///   备注字段，以全部已判定记录为近似）。
/// - 弱点与学科分布按所选范围内收集的题目算（HTML `qsIn` / QDATE 口径，
///   以题目 `createdAt` 为收集日期）：错因行只含未解决的错因，无记录
///   的错因默认待解决；知识点行排除全部错因已解决的题。
/// - 本周 = 本周一到今天（基线口径；HTML 是今天往前 7 天，见报告）。
class ReportPage extends StatefulWidget {
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
  State<ReportPage> createState() => _ReportPageState();
}

/// 一组弱点（学科 × 错因，或学科 × 知识点）。
class _WeakGroup {
  _WeakGroup({
    required this.subjectId,
    required this.key,
    required this.titles,
  });

  final String subjectId;

  /// 错因文本，或知识点 id。
  final String key;
  final List<String> titles;

  int get count => titles.length;
}

class _ReportPageState extends State<ReportPage> {
  String _range = 'week'; // week / month / all
  bool _loading = true;
  bool _loadError = false;
  bool _errorDismissed = false;
  bool _expandCauses = false;
  bool _expandKps = false;

  List<CauseRecord> _records = [];
  List<Question> _questions = [];
  List<KnowledgePoint> _knowledgePoints = [];
  List<({String result, DateTime reviewedAt})> _history = [];
  AppSettings _settings = AppSettings.defaults;

  @override
  void initState() {
    super.initState();
    _load();
  }

  DateTime? get _rangeStart {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return switch (_range) {
      'month' => DateTime(now.year, now.month, 1),
      'week' => today.subtract(Duration(days: today.weekday - 1)),
      _ => null,
    };
  }

  bool _inRange(DateTime d) {
    final start = _rangeStart;
    return start == null || !d.isBefore(start);
  }

  String _md(DateTime d) => '${d.month}-${d.day}';

  /// 范围说明（HTML `rptRange().label` + ` · 数字按这个时间段算`）。
  String get _rangeNote {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final label = switch (_range) {
      'month' => '本月 · ${_md(_rangeStart!)} ~ ${_md(today)}',
      'week' => '本周 · ${_md(_rangeStart!)} ~ ${_md(today)}',
      _ => '全部时间',
    };
    return '$label · 数字按这个时间段算';
  }

  Future<void> _load() async {
    try {
      final records = await widget.repo.causeRecords();
      final questions = await widget.repo.all(includeArchived: true);
      final kps = await widget.repo.knowledgePoints();
      final settings = await widget.repo.settings();
      final history = <({String result, DateTime reviewedAt})>[];
      for (final q in questions) {
        history.addAll(await widget.repo.reviewHistory(q.id));
      }
      if (!mounted) return;
      setState(() {
        _records = records;
        _questions = questions;
        _knowledgePoints = kps;
        _settings = settings;
        _history = history;
        _loading = false;
        _loadError = false;
      });
    } catch (_) {
      // 加载失败：留住上次成功加载的内容（HTML 错误横幅口径），只出横幅。
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = true;
        _errorDismissed = false;
      });
    }
  }

  /// （题 id|错因）→ 解决记录；无记录的错因默认待解决（HTML `causeRec`
  /// 未建记录时默认 `待解决`）。
  Map<String, CauseRecord> get _recordByKey => {
    for (final r in _records) '${r.questionId}|${r.cause}': r,
  };

  /// 所选范围内收集的题目（HTML `qsIn`，以 `createdAt` 为收集日期）。
  List<Question> get _questionsInRange {
    if (_range == 'all') return _questions;
    return _questions.where((q) => _inRange(q.createdAt)).toList();
  }

  int _subjectOrder(String subjectId) {
    final i = Subject.all.indexWhere((s) => s.id == subjectId);
    return i < 0 ? 99 : i;
  }

  List<_WeakGroup> _causeGroups(List<Question> qsIn) {
    final byKey = _recordByKey;
    final groups = <String, _WeakGroup>{};
    final order = <String>[];
    for (final q in qsIn) {
      for (final cause in q.allCauses) {
        final record = byKey['${q.id}|$cause'];
        if (record?.status == CauseStatus.solved) continue;
        final key = '${q.subjectId}|$cause';
        var g = groups[key];
        if (g == null) {
          g = _WeakGroup(subjectId: q.subjectId, key: cause, titles: []);
          groups[key] = g;
          order.add(key);
        }
        if (!g.titles.contains(q.title)) g.titles.add(q.title);
      }
    }
    final list = order.map((k) => groups[k]!).toList();
    list.sort((a, b) {
      final c = b.count.compareTo(a.count);
      if (c != 0) return c;
      final s = _subjectOrder(a.subjectId) - _subjectOrder(b.subjectId);
      return s != 0 ? s : a.key.compareTo(b.key);
    });
    return list;
  }

  List<_WeakGroup> _kpGroups(List<Question> qsIn) {
    final byKey = _recordByKey;
    final groups = <String, _WeakGroup>{};
    final order = <String>[];
    for (final q in qsIn) {
      if (q.allCauses.isEmpty) continue;
      final allSolved = q.allCauses.every(
        (c) => byKey['${q.id}|$c']?.status == CauseStatus.solved,
      );
      if (allSolved) continue;
      for (final kpId in q.knowledgePointIds) {
        if (_kpOf(kpId) == null) continue;
        final key = '${q.subjectId}|$kpId';
        var g = groups[key];
        if (g == null) {
          g = _WeakGroup(subjectId: q.subjectId, key: kpId, titles: []);
          groups[key] = g;
          order.add(key);
        }
        if (!g.titles.contains(q.title)) g.titles.add(q.title);
      }
    }
    final list = order.map((k) => groups[k]!).toList();
    list.sort((a, b) {
      final c = b.count.compareTo(a.count);
      if (c != 0) return c;
      final s = _subjectOrder(a.subjectId) - _subjectOrder(b.subjectId);
      if (s != 0) return s;
      return _kpName(a.key).compareTo(_kpName(b.key));
    });
    return list;
  }

  KnowledgePoint? _kpOf(String id) {
    for (final kp in _knowledgePoints) {
      if (kp.id == id) return kp;
    }
    return null;
  }

  String _kpName(String id) => _kpOf(id)?.name ?? '待补充';

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);

    // 空态：没有任何复习记录（HTML `state==='empty'` 的形态）。
    if (_records.isEmpty && !_loadError) {
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

    // 三个核心数（沿用基线算式，见类注释）。
    final solvedCount = _records
        .where(
          (r) =>
              r.status == CauseStatus.solved &&
              (r.lastCheck == null || _inRange(r.lastCheck!)),
        )
        .length;
    final pendingCount =
        _records.where((r) => r.status != CauseStatus.solved).length;
    final rangedHistory =
        _history.where((h) => _inRange(h.reviewedAt)).toList();
    final judged =
        rangedHistory.where((h) => h.result != 'unsure').toList();
    final passed = judged.where((h) => h.result == 'solved').length;
    final passRate =
        judged.isEmpty ? null : (passed * 100 / judged.length).round();

    final qsIn = _questionsInRange;
    final causeTop = _causeGroups(qsIn);
    final kpTop = _kpGroups(qsIn);
    final nextSentence = causeTop.isEmpty
        ? '这段时间没有待解决的错因，先去复习页把到期的复查做完。'
        : '先解决${Subject.byId(causeTop.first.subjectId).name}的${causeTop.first.key}。';

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
          if (_loadError && !_errorDismissed)
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
                value: _range,
                onChanged: (v) => setState(() {
                  _range = v;
                  _expandCauses = false;
                  _expandKps = false;
                }),
              ),
              Text(
                _rangeNote,
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
            solvedCount: solvedCount,
            pendingCount: pendingCount,
            passRate: passRate,
            judgedTotal: judged.length,
            judgedPassed: passed,
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
          for (var i = 0; i < Subject.all.length; i++)
            _distRow(
              palette,
              scale,
              subject: Subject.all[i],
              count: qsIn.where((q) => q.subjectId == Subject.all[i].id).length,
              last: i == Subject.all.length - 1,
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
    required int solvedCount,
    required int pendingCount,
    required int? passRate,
    required int judgedTotal,
    required int judgedPassed,
  }) {
    final rateSmall = judgedTotal == 0
        ? '这段时间还没有复查记录'
        : '复查 $judgedTotal 次，通过 $judgedPassed 次'
            '（已解决满 ${_settings.recheckIntervalDays} 天回来复查）';
    final cells = [
      _CoreCell(
        valueKey: const ValueKey('report-core-solved'),
        value: '$solvedCount',
        label: '已解决错因',
        small: '同一错因 ${_settings.cureChecks} 次自查「已解决」才算解决',
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
    required AppPalette palette,
    required Brightness brightness,
    required double scale,
    required String title,
    required List<_WeakGroup> groups,
    required bool expanded,
    required VoidCallback onToggleExpand,
    required void Function(_WeakGroup) onTap,
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
    required int rank,
    required _WeakGroup group,
    required VoidCallback onTap,
    required bool isKp,
  }) {
    final subjectName = Subject.byId(group.subjectId).name;
    final subjectColor =
        DesignTokens.subjectInk(group.subjectId, brightness);
    final title = isKp ? _kpName(group.key) : group.key;
    final detail = isKp
        ? '$subjectName${(_kpOf(group.key)?.chapter.isNotEmpty ?? false) ? ' › ${_kpOf(group.key)!.chapter}' : ''} · ${group.titles.join('、')}'
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
