// 复习页：错因治疗模型（M3 重写）。
//
// 列表：按学习状态分组（①已逾期复查 → ②今日到期复查 → ③未解决错因 →
// ④已掌握未到期 → ⑤未加入复习），一题一行（错因数与状态）；页顶
// 今日待复习（X 道题 / Y 个错因）+ “开始复习”主按钮 + “专项练习”
// 次按钮；学科/题型/错因筛选保留；已治愈区与未加入盒保留。
// 会话：五段统一流程（看题 → 作答 → 核对 → 错因自查（仅到期复习）→
// 下一题 → 小结），一道题内部的状态变化，不是每段翻一页；一题多错因
// 时题目只展示一次、用户只需重做一次、答案只需揭示一次，各错因分别
// 记录 verdict；全部操作点按（鼠标/触屏），不设键盘快捷键。
// 业务口径沿用基线（repository.submitCauseVerdict / recordAttempt /
// reviewState；判定表与治愈规则见 lib/data/review_engine.dart）。
// 旧翻卡模型不复活，不出现 1/3/7/14 天旧复习状态；旧四步
// （看错因/写补救/重做/自查）已废止，补救改为自查区的对策回顾。
//
// ARCH-PLAN-A 第 3 阶段：业务数据 + 会话状态收进 [reviewProvider]
// （`lib/state/review_notifier.dart`）；本页只留 widget 与纯界面
// 临时状态。`repo` 构造参数保留——`app.dart` 仍按老样子传，本页在
// build 里包一层 `ProviderScope` 把它以
// `repositoryProvider.overrideWithValue(widget.repo)` 交进依赖图，
// 页内不再直接调 `repo` 的方法；内层 Consumer 的 ref 才属于这层
// scope。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repository.dart';
import '../../data/review_engine.dart';
import '../../models/models.dart';
import '../../modules/ocr/question_classifier.dart';
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

/// 复习页内层：按模式切换列表 / 选题页 / 会话 / 总结。
class _ReviewView extends ConsumerWidget {
  const _ReviewView({required this.onOpenDetail, required this.onGoWrongbook});

  final Future<void> Function(Question q, List<String> orderIds) onOpenDetail;
  final VoidCallback onGoWrongbook;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 只订阅模式切换要的字段：自查点选（只改 verdicts）不会
    // 让整页重建，只有自查步自己重建。
    final (loading, inSession, showSummary, showPicker) = ref.watch(
      reviewProvider.select(
        (s) => (s.loading, s.inSession, s.showSummary, s.showPracticePicker),
      ),
    );
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (inSession) {
      // 会话中先判总结（会话结束出总结页时 `inSession` 仍为真，
      // 不能先按 `inSession` 直接回会话视图）。
      if (showSummary) return const _SummaryView();
      return _SessionView(onOpenDetail: onOpenDetail);
    }
    if (showSummary) return const _SummaryView();
    if (showPicker) return const _PracticePickerView();
    return _ListView(
      onOpenDetail: onOpenDetail,
      onGoWrongbook: onGoWrongbook,
    );
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

/// 按学习状态分组的列表行（一题一行）。
class _QuestionRowData {
  _QuestionRowData({
    required this.question,
    required this.records,
  });

  final Question question;
  final List<CauseRecord> records;

  int get overdueCount => records
      .where(
        (r) =>
            r.status == CauseStatus.solved &&
            r.recheckDate != null &&
            r.isRecheckDue,
      )
      .length;

  String get statusText {
    final pending = records
        .where((r) => r.status != CauseStatus.solved)
        .length;
    final due = records.where((r) => r.isRecheckDue).length;
    if (pending > 0) return '$pending 项未解决';
    if (due > 0) return '$due 项待复查';
    return '已掌握';
  }
}

/// 列表按学习状态分组（M3-11）：①已逾期复查 ②今日到期复查
/// ③未解决错因 ④已掌握未到期 ⑤未加入复习。
(List<_QuestionRowData>, List<_QuestionRowData>, List<_QuestionRowData>,
    List<_QuestionRowData>) groupQuestionsByStatus(ReviewState st) {
  final byQ = <String, List<CauseRecord>>{};
  for (final g in [...st.groups, ...st.curedGroups]) {
    for (final it in g.items) {
      (byQ[it.question.id] ??= []).add(it.record);
    }
  }
  // 筛选：学科/题型/错因三维度（同维 OR、不同维 AND）。
  bool keep(Question q, List<CauseRecord> rs) {
    if (st.subjectFilter != null && q.subjectId != st.subjectFilter) {
      return false;
    }
    if (st.typeFilter != null && q.questionType != st.typeFilter) {
      return false;
    }
    if (st.causeFilter != '全部' &&
        !rs.any((r) => r.cause == st.causeFilter)) {
      return false;
    }
    return true;
  }

  final overdue = <_QuestionRowData>[];
  final dueToday = <_QuestionRowData>[];
  final unsolved = <_QuestionRowData>[];
  final mastered = <_QuestionRowData>[];
  final today = DateTime.now();
  final todayDay = DateTime(today.year, today.month, today.day);
  for (final entry in byQ.entries) {
    final q = st.questionOf(entry.key);
    if (q == null) continue;
    final rs = entry.value;
    if (!keep(q, rs)) continue;
    final row = _QuestionRowData(question: q, records: rs);
    final hasOverdue = rs.any(
      (r) =>
          r.status == CauseStatus.solved &&
          r.recheckDate != null &&
          DateTime(
            r.recheckDate!.year,
            r.recheckDate!.month,
            r.recheckDate!.day,
          ).isBefore(todayDay),
    );
    final hasDueToday = rs.any(
      (r) =>
          r.status == CauseStatus.solved &&
          r.recheckDate != null &&
          !DateTime(
            r.recheckDate!.year,
            r.recheckDate!.month,
            r.recheckDate!.day,
          ).isBefore(todayDay) &&
          r.isRecheckDue,
    );
    final hasUnsolved = rs.any((r) => r.status != CauseStatus.solved);
    if (hasOverdue) {
      overdue.add(row);
    } else if (hasDueToday) {
      dueToday.add(row);
    } else if (hasUnsolved) {
      unsolved.add(row);
    } else {
      mastered.add(row);
    }
  }
  return (overdue, dueToday, unsolved, mastered);
}

// ---------- 列表 ----------

/// 复习列表（页顶今日待复习 + 开始复习/专项练习、状态分组、筛选、
/// 已解决区、未加入盒、恢复条、空状态）。
class _ListView extends ConsumerStatefulWidget {
  const _ListView({required this.onOpenDetail, required this.onGoWrongbook});

  final Future<void> Function(Question q, List<String> orderIds) onOpenDetail;
  final VoidCallback onGoWrongbook;

  @override
  ConsumerState<_ListView> createState() => _ListViewState();
}

class _ListViewState extends ConsumerState<_ListView> {
  /// 空状态里“查看已掌握题目/查看复习历史”点开后就地展开已解决区。
  bool _showMastered = false;

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(reviewProvider);
    final notifier = ref.read(reviewProvider.notifier);
    final scale = qmScaleOf(context);
    final (dueQuestions, dueCauses) = st.dueTodayCounts;
    final (pendCount, checkCount, curedCount) = st.metaCounts;
    final hasData = st.groups.isNotEmpty || st.curedGroups.isNotEmpty;
    final (overdue, dueToday, unsolved, mastered) =
        groupQuestionsByStatus(st);
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
                  QmBannerAction(label: '重试', onPressed: notifier.retryLoad),
                ],
                onDismiss: notifier.dismissLoadError,
              ),
            ),
          // 首次加载即失败（从未成功加载过）：横幅之外再给一个显眼的
          // 重试按钮，不只留空列表。
          if (st.loadError && !st.hasLoaded)
            Padding(
              padding: EdgeInsets.only(bottom: 14 * scale),
              child: QmButton(label: '重新加载', onPressed: notifier.retryLoad),
            ),
          // 快照整体失效：按最新状态重筛并提示（M3-10）。
          if (st.resumeExpired)
            Padding(
              padding: EdgeInsets.only(bottom: 14 * scale),
              child: QmBanner(
                tone: QmBannerTone.warning,
                message: '上次会话已失效，已按最新状态重新生成。',
                onDismiss: notifier.dismissResumeExpired,
              ),
            ),
          // 暂停会话优先显示（M3-11 空状态优先级：有未完成会话时先处理
          // 会话，再谈空状态）。
          if (st.resume != null) _buildResumeBar(context, st),
          // 页顶：今日待复习 + 开始复习（主）+ 专项练习（次）。
          _DetailBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    style: const TextStyle(fontSize: 14),
                    children: [
                      const TextSpan(text: '今日待复习 '),
                      TextSpan(
                        text: '$dueQuestions',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const TextSpan(text: ' 道题 / '),
                      TextSpan(
                        text: '$dueCauses',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const TextSpan(text: ' 个错因'),
                    ],
                  ),
                ),
                SizedBox(height: 10 * scale),
                Wrap(
                  spacing: 8 * scale,
                  runSpacing: 8 * scale,
                  children: [
                    QmButton(
                      label: '开始复习',
                      onPressed: dueQuestions == 0
                          ? null
                          : () => _startDue(context, st),
                    ),
                    QmButton(
                      label: '专项练习',
                      variant: QmButtonVariant.secondary,
                      onPressed: () => _startPractice(context, st),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(height: 14 * scale),
          if (!hasData && st.resume == null) ...[
            QmEmptyState(
              title: '复习列表还是空的',
              description: '在题目详情的「复习记录」里点「加入复习」，这道题的错因才会到这里来解决。',
              actionLabel: '去错题本选题',
              onAction: widget.onGoWrongbook,
            ),
          ] else if (dueQuestions == 0 && st.resume == null) ...[
            // 空状态（M3-11 用户流程第 10 节）：今天没有到期/逾期错因。
            _DetailBox(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CompanionWidget(
                    size: 72 * scale,
                    message: '今天没有到期复习',
                  ),
                  SizedBox(height: 8 * scale),
                  Text(
                    '正在等待未来复查的错因有 ${st.futureRecheckCount} 个，到了复查日会自动回来。',
                    style: TextStyle(
                      fontSize: DesignTokens.bodySmallFontSize,
                      color: DesignTokens.of(Theme.of(context).brightness)
                          .muted,
                    ),
                  ),
                  SizedBox(height: 10 * scale),
                  Wrap(
                    spacing: 8 * scale,
                    runSpacing: 8 * scale,
                    children: [
                      QmButton(
                        label: '去专项练习',
                        variant: QmButtonVariant.secondary,
                        onPressed: () => _startPractice(context, st),
                      ),
                      QmButton(
                        label: '查看已掌握题目',
                        variant: QmButtonVariant.secondary,
                        onPressed: () =>
                            setState(() => _showMastered = true),
                      ),
                      QmButton(
                        label: '查看复习历史',
                        variant: QmButtonVariant.secondary,
                        onPressed: () =>
                            setState(() => _showMastered = true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(height: 14 * scale),
            if (_showMastered && st.filteredCured.isNotEmpty)
              _buildCuredSection(context, st),
          ] else ...[
            _buildMetaRow(context, st, pendCount, checkCount, curedCount),
            _buildToolbar(context, st),
            _buildPagedRows(context, st, overdue, dueToday, unsolved, mastered),
            if (st.filteredCured.isNotEmpty) ...[
              SizedBox(height: 14 * scale),
              _buildCuredSection(context, st),
            ],
          ],
          if (st.notJoined.isNotEmpty) ...[
            SizedBox(height: 14 * scale),
            _buildNotJoinedBox(context, st),
          ],
        ],
      ),
    );
  }

  /// 开始到期复习：如存在暂停会话，先二选一（M3-10 单活动会话）。
  Future<void> _startDue(BuildContext context, ReviewState st) async {
    final notifier = ref.read(reviewProvider.notifier);
    if (st.resume != null) {
      final choice = await _confirmAbandonPrevious(context);
      if (choice == null) return;
      if (choice) {
        await notifier.abandonResumeAndStartDue();
      } else {
        await notifier.startSession(resume: true);
      }
      return;
    }
    await notifier.startSession();
  }

  /// 开始专项练习：如存在暂停会话，先二选一（M3-10 单活动会话）。
  Future<void> _startPractice(BuildContext context, ReviewState st) async {
    final notifier = ref.read(reviewProvider.notifier);
    if (st.resume != null) {
      final choice = await _confirmAbandonPrevious(context);
      if (choice == null) return;
      if (choice) {
        await notifier.abandonResumeAndStartPractice();
      } else {
        await notifier.startSession(resume: true);
      }
      return;
    }
    notifier.openPracticePicker();
  }

  /// 单活动会话二选一：返回 true = 放弃上次会话再开始新模式，
  /// false = 继续上次会话，null = 取消。
  Future<bool?> _confirmAbandonPrevious(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('上次会话还没完成', style: TextStyle(fontSize: 16)),
        content: const Text('有一个暂停的学习会话。继续上次会话，还是放弃它再开始新的？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('继续上次会话'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('放弃上次会话'),
          ),
        ],
      ),
    );
  }

  /// “继续上次会话（第 X/Y 题）”+“放弃重开”恢复条。
  Widget _buildResumeBar(BuildContext context, ReviewState st) {
    final scale = qmScaleOf(context);
    final notifier = ref.read(reviewProvider.notifier);
    final resume = st.resume!;
    final total = resume.sessionQuestions.length;
    final index = resume.sessionIndex.clamp(0, total - 1);
    final q = st.questionOf(resume.sessionQuestions[index].questionId);
    final modeLabel = resume.mode == ReviewMode.practice ? '专项练习' : '到期复习';
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
                    text: '继续上次会话',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(
                    text:
                        ' · $modeLabel，第 ${index + 1} / $total 道题${q == null ? '' : '（${q.title}）'}',
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
                  label: '继续上次会话',
                  onPressed: () => notifier.startSession(resume: true),
                ),
                QmButton(
                  label: '放弃重开',
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
    // FR-10：括号里的学科名由 `st.subjects` 现拼（前 3 科，多了加“等”），
    // 不再写死“数学 / 英语 / 政治”；无学科时不带括号。
    final subjectNames = st.subjects.map((s) => s.name).toList();
    final subjectHint = subjectNames.isEmpty
        ? ''
        : '（${subjectNames.take(3).join('、')}${subjectNames.length > 3 ? '等' : ''}）';
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
                ? '列表按学科排$subjectHint，同一科里先加入的先解决'
                : '列表按加入时间排，先加入的先解决',
            style: metaStyle,
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(BuildContext context, ReviewState st) {
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
          Text('题型', style: labelStyle),
          SizedBox(
            width: 140 * scale,
            child: _styledDropdown<String>(
              context,
              value: st.typeFilter == null
                  ? '全部'
                  : questionTypeDisplay(st.typeFilter),
              items: [
                const DropdownMenuItem(value: '全部', child: Text('全部')),
                for (final t in st.allQuestionTypes)
                  DropdownMenuItem(
                    value: questionTypeDisplay(t),
                    child: Text(questionTypeDisplay(t)),
                  ),
              ],
              onChanged: (v) {
                if (v == null || v == '全部') {
                  notifier.setTypeFilter(null);
                  return;
                }
                final type = st.allQuestionTypes.firstWhere(
                  (t) => questionTypeDisplay(t) == v,
                  orElse: () => v,
                );
                notifier.setTypeFilter(type);
              },
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

  /// 状态分组列表 + 分页（M3-11 分组 + 旧分页行为保留）：四组按
  /// ①已逾期复查 → ②今日到期复查 → ③未解决错因 → ④已掌握未到期
  /// 的顺序拼成一列，一题一行，按每页条数切片；分组头只在该页
  /// 首次出现该组时画一次。筛选改动后回第 1 页（notifier 侧已复位）。
  Widget _buildPagedRows(
    BuildContext context,
    ReviewState st,
    List<_QuestionRowData> overdue,
    List<_QuestionRowData> dueToday,
    List<_QuestionRowData> unsolved,
    List<_QuestionRowData> mastered,
  ) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final flat = <(String, _QuestionRowData)>[
      for (final r in overdue) ('已逾期复查', r),
      for (final r in dueToday) ('今日到期复查', r),
      for (final r in unsolved) ('未解决错因', r),
      for (final r in mastered) ('已掌握未到期', r),
    ];
    if (flat.isEmpty) {
      return _DetailBox(
        child: const Text('当前筛选下没有题目，换个学科 / 题型 / 错因试试。'),
      );
    }
    final totalPages = (flat.length / st.pageSize).ceil().clamp(1, 9999);
    final page = st.page.clamp(1, totalPages);
    final rows =
        flat.skip((page - 1) * st.pageSize).take(st.pageSize).toList();
    final children = <Widget>[];
    var lastLabel = '';
    for (final (label, row) in rows) {
      if (label != lastLabel) {
        children.add(_buildSectionHead(context, label));
        lastLabel = label;
      }
      children.add(_buildQuestionRow(context, st, row));
    }
    // 分页器（与错题本同款文案）：页数 + 上一页/下一页 + 每页条数。
    // 当前每页条数不在标准档里时（如测试用 2）也放进选项，否则
    // DropdownButton 会因 value 不在 items 里断言。
    final sizeOptions = <int>{st.pageSize, 10, 20, 30, 40, 50}.toList()
      ..sort();
    children.add(
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
              '共 ${flat.length} 条 · 第 $page / $totalPages 页',
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
              onPressed: page > 1
                  ? () => ref.read(reviewProvider.notifier).setPage(page - 1)
                  : null,
            ),
            SizedBox(width: 6 * scale),
            QmButton(
              label: '下一页',
              size: QmButtonSize.small,
              variant: QmButtonVariant.secondary,
              onPressed: page < totalPages
                  ? () => ref.read(reviewProvider.notifier).setPage(page + 1)
                  : null,
            ),
            SizedBox(width: 10 * scale),
            Text(
              '每页',
              style: TextStyle(
                fontSize: DesignTokens.pagerFontSize,
                color: palette.muted,
              ),
            ),
            SizedBox(width: 4 * scale),
            SizedBox(
              width: 72 * scale,
              child: _styledDropdown<int>(
                context,
                value: st.pageSize,
                items: [
                  for (final n in sizeOptions)
                    DropdownMenuItem(value: n, child: Text('$n')),
                ],
                onChanged: (v) {
                  if (v != null) {
                    ref.read(reviewProvider.notifier).setPageSize(v);
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _buildSectionHead(BuildContext context, String title) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        DesignTokens.reviewRowPaddingH * scale,
        10 * scale,
        DesignTokens.reviewRowPaddingH * scale,
        4 * scale,
      ),
      child: Text(
        title,
        style: TextStyle(
          fontSize: DesignTokens.reviewPendHeadFontSize,
          fontWeight: FontWeight.w700,
          color: palette.muted,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget _buildQuestionRow(
    BuildContext context,
    ReviewState st,
    _QuestionRowData row,
  ) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final q = row.question;
    final subject = st.subjectOf(q.subjectId);
    final orderIds = st.allQuestions.map((e) => e.id).toList();
    return InkWell(
      onTap: () => widget.onOpenDetail(q, orderIds),
      child: Container(
        padding: EdgeInsets.symmetric(
          vertical: DesignTokens.reviewRowPaddingV * scale,
          horizontal: DesignTokens.reviewRowPaddingH * scale,
        ),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: palette.line)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              subject.name,
              style: TextStyle(
                fontSize: DesignTokens.bodySmallFontSize,
                fontWeight: FontWeight.w800,
                color: DesignTokens.subjectInk(
                  q.subjectId,
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
                    q.title,
                    style: TextStyle(
                      fontSize: DesignTokens.bodySmallFontSize,
                      fontWeight: FontWeight.w700,
                      color: palette.ink,
                    ),
                  ),
                  Text(
                    '${questionTypeDisplay(q.questionType)} · ${row.records.map((r) => r.cause).join('、')} · ${row.statusText}',
                    style: TextStyle(
                      fontSize: DesignTokens.captionFontSize,
                      color: palette.muted,
                    ),
                  ),
                ],
              ),
            ),
            if (row.overdueCount > 0) ...[
              QmStatusPill.cause(QmCauseStatus.recheck),
              SizedBox(width: 6 * scale),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCuredSection(BuildContext context, ReviewState st) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    // 已解决区也分页（SR-P2-47）：与待解决列表同一每页条数，
    // 不再全量渲染到底。
    final groups = st.filteredCured;
    final totalPages = (groups.length / st.pageSize).ceil().clamp(1, 9999);
    final page = st.curedPage.clamp(0, totalPages - 1);
    final items = groups.skip(page * st.pageSize).take(st.pageSize).toList();
    return Container(
      margin: EdgeInsets.only(
        bottom: DesignTokens.reviewCuredMarginBottom * scale,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: palette.line),
        borderRadius: BorderRadius.circular(DesignTokens.radiusLg * scale),
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
          for (final g in items) _buildCuredRow(context, st, g),
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

  Widget _buildCuredRow(BuildContext context, ReviewState st, CauseGroup g) {
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
          onTap: () => ref.read(reviewProvider.notifier).toggleCured(key),
          child: Container(
            padding: EdgeInsets.symmetric(
              vertical: DesignTokens.reviewCuredHeadPaddingV * scale,
              horizontal: DesignTokens.reviewRowPaddingH * scale,
            ),
            decoration: BoxDecoration(
              color: open ? palette.accentSoft : null,
              border: Border(bottom: BorderSide(color: palette.line)),
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
                          style: const TextStyle(fontWeight: FontWeight.w700),
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
              border: Border(bottom: BorderSide(color: palette.line)),
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
        '下次复查 ${formatReviewDate(r.recheckDate!)}（${formatReviewMd(r.recheckDate!)}）',
      );
    }
    var text = parts.join(' · ');
    if (r.remedyHistory.isNotEmpty) {
      text += '\n补救记录：${r.remedyHistory.join('\n')}';
    }
    return text;
  }

  Widget _buildNotJoinedBox(BuildContext context, ReviewState st) {
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
          const Text('还没加入复习的题', style: TextStyle(fontWeight: FontWeight.w700)),
          SizedBox(height: 6 * qmScaleOf(context)),
          ...lines,
          if (total > shownLimit) ...[
            SizedBox(height: 6 * qmScaleOf(context)),
            QmButton(
              label: st.notJoinedExpanded ? '收起' : '展开全部（共 $total 道）',
              size: QmButtonSize.small,
              variant: QmButtonVariant.secondary,
              onPressed: () =>
                  ref.read(reviewProvider.notifier).toggleNotJoinedExpanded(),
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

// ---------- 专项练习选题页 ----------

/// 专项练习选题页（M3-2）：学科 / 题型 / 错因（默认全部）、数量
/// （全部/10/20，默认 10 道）、顺序（随机/加入时间，默认随机）。
class _PracticePickerView extends ConsumerWidget {
  const _PracticePickerView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(reviewProvider);
    final notifier = ref.read(reviewProvider.notifier);
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final labelStyle = TextStyle(
      fontSize: DesignTokens.filterCellLabelFontSize,
      fontWeight: FontWeight.w700,
      color: palette.muted,
    );
    return _centered(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('专项练习', style: Theme.of(context).textTheme.titleLarge),
          SizedBox(height: 6 * scale),
          Text(
            '只练，不治：本次练习不改变治疗进度、不写正式自查记录。',
            style: TextStyle(
              fontSize: DesignTokens.bodySmallFontSize,
              color: palette.muted,
            ),
          ),
          SizedBox(height: 14 * scale),
          if (st.practiceEmpty) ...[
            _DetailBox(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CompanionWidget(size: 72 * scale, message: '该范围内没有可练的题'),
                  SizedBox(height: 8 * scale),
                  const Text('该范围内没有可练的题，换个范围试试。'),
                  SizedBox(height: 10 * scale),
                  QmButton(
                    label: '返回选题页',
                    variant: QmButtonVariant.secondary,
                    onPressed: () =>
                        ref.read(reviewProvider.notifier).dismissPracticeEmpty(),
                  ),
                ],
              ),
            ),
            SizedBox(height: 14 * scale),
          ],
          _DetailBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('学科', style: labelStyle),
                SizedBox(height: 5 * scale),
                SizedBox(
                  width: 200 * scale,
                  child: _styledDropdown<String>(
                    context,
                    value: st.practiceSubjectFilter ?? '全部',
                    items: [
                      const DropdownMenuItem(
                        value: '全部',
                        child: Text('全部'),
                      ),
                      for (final s in st.subjects)
                        DropdownMenuItem(value: s.id, child: Text(s.name)),
                    ],
                    onChanged: (v) => notifier.setPracticeSubjectFilter(
                      v == '全部' ? null : v,
                    ),
                  ),
                ),
                SizedBox(height: 12 * scale),
                Text('题型', style: labelStyle),
                SizedBox(height: 5 * scale),
                SizedBox(
                  width: 200 * scale,
                  child: _styledDropdown<String>(
                    context,
                    value: st.practiceTypeFilter == null
                        ? '全部'
                        : questionTypeDisplay(st.practiceTypeFilter),
                    items: [
                      const DropdownMenuItem(
                        value: '全部',
                        child: Text('全部'),
                      ),
                      for (final t in st.allQuestionTypes)
                        DropdownMenuItem(
                          value: questionTypeDisplay(t),
                          child: Text(questionTypeDisplay(t)),
                        ),
                    ],
                    onChanged: (v) {
                      if (v == null || v == '全部') {
                        notifier.setPracticeTypeFilter(null);
                        return;
                      }
                      final type = st.allQuestionTypes.firstWhere(
                        (t) => questionTypeDisplay(t) == v,
                        orElse: () => v,
                      );
                      notifier.setPracticeTypeFilter(type);
                    },
                  ),
                ),
                SizedBox(height: 12 * scale),
                Text('错因', style: labelStyle),
                SizedBox(height: 5 * scale),
                SizedBox(
                  width: 200 * scale,
                  child: _styledDropdown<String>(
                    context,
                    value: st.practiceCauseFilter == '全部' ||
                            st.allCauses.contains(st.practiceCauseFilter)
                        ? st.practiceCauseFilter
                        : '全部',
                    items: [
                      const DropdownMenuItem(
                        value: '全部',
                        child: Text('全部'),
                      ),
                      for (final c in st.allCauses)
                        DropdownMenuItem(value: c, child: Text(c)),
                    ],
                    onChanged: (v) =>
                        notifier.setPracticeCauseFilter(v ?? '全部'),
                  ),
                ),
                SizedBox(height: 12 * scale),
                Text('数量', style: labelStyle),
                SizedBox(height: 5 * scale),
                Wrap(
                  spacing: 10 * scale,
                  children: [
                    for (final n in [0, 10, 20])
                      QmButton(
                        label: n == 0 ? '全部' : '$n 道',
                        size: QmButtonSize.small,
                        variant: st.practiceCount == n
                            ? QmButtonVariant.primary
                            : QmButtonVariant.secondary,
                        onPressed: () => notifier.setPracticeCount(n),
                      ),
                  ],
                ),
                SizedBox(height: 12 * scale),
                Text('顺序', style: labelStyle),
                SizedBox(height: 5 * scale),
                Wrap(
                  spacing: 10 * scale,
                  children: [
                    QmButton(
                      label: '随机',
                      size: QmButtonSize.small,
                      variant: st.practiceRandom
                          ? QmButtonVariant.primary
                          : QmButtonVariant.secondary,
                      onPressed: () => notifier.setPracticeRandom(true),
                    ),
                    QmButton(
                      label: '加入时间',
                      size: QmButtonSize.small,
                      variant: !st.practiceRandom
                          ? QmButtonVariant.primary
                          : QmButtonVariant.secondary,
                      onPressed: () => notifier.setPracticeRandom(false),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(height: DesignTokens.reviewActsMarginTop * scale),
          _SessionActions(
            primaryLabel: '开始练习',
            onPrimary: () => notifier.startPracticeSession(),
            secondaryLabel: '返回复习页',
            onSecondary: () => notifier.closePracticePicker(),
          ),
        ],
      ),
    );
  }
}

// ---------- 会话 ----------

/// 会话视图：头信息 + 步骤指示 + 当前段。只订阅 `stage`（段切换）
/// 与“当前题是否还在”；自查点选只改 `verdicts`，这里不订阅、不重建。
class _SessionView extends ConsumerWidget {
  const _SessionView({required this.onOpenDetail});

  final Future<void> Function(Question q, List<String> orderIds) onOpenDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 题没了（会话里进详情删题）：切到总结页。
    final gone = ref.watch(
      reviewProvider.select(
        (s) => !s.hasCurrentQuestion || s.currentQuestion == null,
      ),
    );
    if (gone) return const _SummaryView();
    // 选择器必须空安全：跳过把末题拿掉、_finishSession 尚未完成
    // 的瞬间，会话队列已空但 showSummary 还没置位；select 在
    // build 短路前就会求值，直接取 currentSessionQuestion 会抛
    // RangeError——先判 hasCurrentQuestion。
    final stage = ref.watch(
      reviewProvider.select(
        (s) => s.hasCurrentQuestion
            ? s.currentSessionQuestion.stage
            : null,
      ),
    );
    if (stage == null) return const _SummaryView();
    return _centered(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SessionSaveErrorBanner(),
          _RejoinNoticeBanner(),
          _SessionMeta(onOpenDetail: onOpenDetail),
          SizedBox(height: 12 * qmScaleOf(context)),
          _StepIndicator(stage: stage),
          SizedBox(height: 12 * qmScaleOf(context)),
          if (stage == SessionStage.view) _StepView(onOpenDetail: onOpenDetail),
          if (stage == SessionStage.answer)
            _StepAnswer(onOpenDetail: onOpenDetail),
          if (stage == SessionStage.check) const _StepCheck(),
          if (stage == SessionStage.selfCheck) const _StepSelfCheck(),
          if (stage == SessionStage.done) const _StepDone(),
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
      onDismiss: () => ref.read(reviewProvider.notifier).dismissSaveError(),
    );
  }
}

/// “已重新加入复习”反馈横幅（只订阅 `rejoinNotice`）。
class _RejoinNoticeBanner extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notice = ref.watch(reviewProvider.select((s) => s.rejoinNotice));
    if (notice == null) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: 10 * qmScaleOf(context)),
      child: QmBanner(
        tone: QmBannerTone.info,
        message: notice,
        onDismiss: () =>
            ref.read(reviewProvider.notifier).dismissRejoinNotice(),
      ),
    );
  }
}

/// 会话头：第几道题 · 本轮题数/错因数 · 范围文案、题名、详情入口、暂停、跳过。
class _SessionMeta extends ConsumerWidget {
  const _SessionMeta({required this.onOpenDetail});

  final Future<void> Function(Question q, List<String> orderIds) onOpenDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 选择器必须空安全：跳过把末题拿掉的瞬时态里当前题已为空，
    // 但父级切总结页的重建还没跑，选择器会先被求值——抛错会污染通知。
    final meta = ref.watch(
      reviewProvider.select((s) {
        final q = s.currentQuestion;
        if (q == null) return null;
        return (
          s.sessionIndex,
          s.sessionQuestions.length,
          s.sessionTotals.$1,
          s.sessionTotals.$2,
          s.scopeLabel,
          q,
          s.subjectOf(q.subjectId).name,
          s.settings.causesPerSession,
          s.sessionMode,
        );
      }),
    );
    if (meta == null) return const SizedBox.shrink();
    final (
      index,
      total,
      totalQuestions,
      totalCauses,
      scopeLabel,
      question,
      subjectName,
      causesPerSession,
      mode,
    ) = meta;
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final metaStyle = TextStyle(
      fontSize: DesignTokens.reviewMetaFontSize,
      color: palette.muted,
    );
    final overLimit =
        causesPerSession > 0 && totalCauses > causesPerSession;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8 * scale,
          runSpacing: 8 * scale,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '第 ${index + 1} / $total 道题 · 本轮共 $totalQuestions 道题、$totalCauses 个错因 · $scopeLabel',
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
                    st.sessionQuestions.map((e) => e.questionId).toList();
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
            QmButton(
              label: '跳过',
              size: QmButtonSize.small,
              variant: QmButtonVariant.secondary,
              onPressed: () => ref.read(reviewProvider.notifier).skipCurrent(),
            ),
          ],
        ),
        if (overLimit) ...[
          SizedBox(height: 6 * scale),
          Text(
            '本轮共 $totalCauses 个错因，超出了每会话 $causesPerSession 个的设置（同一题的错因不拆散），是否仍继续？',
            style: TextStyle(
              fontSize: DesignTokens.reviewMetaFontSize,
              color: palette.muted,
            ),
          ),
        ],
        if (mode == ReviewMode.practice) ...[
          SizedBox(height: 6 * scale),
          Text(
            '专项练习：本次练习不改变治疗进度。',
            style: TextStyle(
              fontSize: DesignTokens.reviewMetaFontSize,
              color: palette.muted,
            ),
          ),
        ],
      ],
    );
  }
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.stage});

  final SessionStage stage;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final stepIdx = switch (stage) {
      SessionStage.view => 0,
      SessionStage.answer => 1,
      SessionStage.check => 2,
      SessionStage.selfCheck => 3,
      SessionStage.done => 3,
    };
    return Wrap(
      spacing: 6 * scale,
      runSpacing: 6 * scale,
      children: [
        for (var i = 0; i < stageLabels.length; i++)
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
              stageLabels[i],
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

/// ① 看题：题干（题图）+ 本轮错因 + 非本轮错因折叠 + 批注开关。
class _StepView extends ConsumerWidget {
  const _StepView({required this.onOpenDetail});

  final Future<void> Function(Question q, List<String> orderIds) onOpenDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 选择器必须空安全（见 `_SessionMeta`）。
    final m = ref.watch(
      reviewProvider.select((s) {
        final q = s.currentQuestion;
        if (q == null) return null;
        final sq = s.currentSessionQuestion;
        return (
          q,
          sq,
          s.historyByQ[q.id],
          s.subjectOf(q.subjectId),
          s.isPracticeSession,
        );
      }),
    );
    if (m == null) return const SizedBox.shrink();
    final (question, sq, history, subject, isPractice) = m;
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final lastCheck = history == null || history.isEmpty ? null : history.first;
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isPractice
                    ? '本轮练习本题'
                    : '本轮 ${sq.causes.length} 项错因',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              SizedBox(height: 6 * scale),
              for (final cause in sq.causes)
                _KvRow(
                  label: cause,
                  value: _causeStatusText(ref, sq.questionId, cause),
                ),
              if (sq.nonRoundCauses.isNotEmpty) ...[
                SizedBox(height: 6 * scale),
                for (final cause in sq.nonRoundCauses)
                  Text(
                    '$cause：${_nonRoundNote(ref, sq.questionId, cause)}',
                    style: TextStyle(
                      fontSize: DesignTokens.captionFontSize,
                      color: palette.muted,
                    ),
                  ),
              ],
              if (lastCheck != null)
                _KvRow(
                  label: '上次自查',
                  value:
                      '${formatReviewDate(lastCheck.reviewedAt)} · 「${_historyLabel(lastCheck.result)}」',
                ),
            ],
          ),
        ),
        SizedBox(height: 12 * scale),
        // 批注笔记（M3-16）：默认隐藏；显示后给视觉提示。
        Row(
          children: [
            QmButton(
              label: sq.notesShown ? '隐藏笔记' : '显示笔记',
              size: QmButtonSize.small,
              variant: QmButtonVariant.secondary,
              onPressed: () =>
                  ref.read(reviewProvider.notifier).toggleNotesShown(),
            ),
          ],
        ),
        if (sq.notesShown) ...[
          SizedBox(height: 8 * scale),
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(12 * scale),
            decoration: BoxDecoration(
              color: palette.accentSoft,
              border: Border.all(color: palette.accent),
              borderRadius: BorderRadius.circular(10 * scale),
            ),
            child: Text(
              '已显示笔记（含你自己的提示）',
              style: TextStyle(
                fontSize: DesignTokens.bodySmallFontSize,
                fontWeight: FontWeight.w700,
                color: palette.ink,
              ),
            ),
          ),
        ],
        SizedBox(height: DesignTokens.reviewActsMarginTop * scale),
        _SessionActions(
          primaryLabel: '开始作答',
          onPrimary: () {
            // 看题 → 作答：只切段，不创建 attempt（作答时才建）。
            ref.read(reviewProvider.notifier).beginAnswer();
          },
          secondaryLabel: '跳过',
          onSecondary: () => ref.read(reviewProvider.notifier).skipCurrent(),
        ),
      ],
    );
  }

  String _causeStatusText(WidgetRef ref, String qid, String cause) {
    final st = ref.read(reviewProvider);
    final record = st.recordOf(qid, cause);
    if (record == null) return '待补充';
    final count = '「已解决」${record.solvedCount} / ${st.settings.cureChecks} 次';
    if (record.isRecheckDue) return '复查 · $count';
    return '${record.status.label} · $count';
  }

  String _nonRoundNote(WidgetRef ref, String qid, String cause) {
    final st = ref.read(reviewProvider);
    final record = st.recordOf(qid, cause);
    if (record == null) return '不在本次范围';
    if (record.status == CauseStatus.solved && record.recheckDate != null) {
      return '未到期，下次复查 ${formatReviewDate(record.recheckDate!)}';
    }
    return '不在本次范围';
  }
}

/// ② 作答：按题型分流（单选点选 / 判断点选 / 多选点选 /
/// 纸上作答）。提交后锁定，不可改选。
class _StepAnswer extends ConsumerWidget {
  const _StepAnswer({required this.onOpenDetail});

  final Future<void> Function(Question q, List<String> orderIds) onOpenDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 选择器必须空安全（见 `_SessionMeta`）。
    final m = ref.watch(
      reviewProvider.select((s) {
        final q = s.currentQuestion;
        if (q == null) return null;
        return (q, s.currentSessionQuestion, s.subjectOf(q.subjectId));
      }),
    );
    if (m == null) return const SizedBox.shrink();
    final (question, sq, subject) = m;
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final type = question.questionType;
    final isSingle = type == 'choice_single';
    final isTF = type == 'true_false';
    final isMulti =
        type == 'choice_multi' || type == 'choice_variable';
    // WP-A #1 收尾：门禁不再读 optionLabelsConfirmed 列（REV5 R1-3，
    // 该列保留但停止读写）。单选按 objectiveGradingAvailable（配置
    // 有效且未待重新核对才可判分）；多选永不判分，只需标签齐全
    // （≥2 位）即可点选记录。
    final canGrade = objectiveGradingAvailable(question);
    final hasMultiLabels =
        (question.optionLabels ?? const []).length >= 2;
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
        if (isSingle && canGrade) ...[
          _OptionButtons(question: question, sq: sq),
          SizedBox(height: 12 * scale),
          _ConfidencePicker(sq: sq),
          SizedBox(height: DesignTokens.reviewActsMarginTop * scale),
          _SessionActions(
            primaryLabel: '提交答案',
            primaryEnabled:
                sq.selected != null &&
                sq.selected!.isNotEmpty &&
                sq.confidence != null,
            onPrimary: () =>
                ref.read(reviewProvider.notifier).submitObjectiveAnswer(),
            secondaryLabel: '跳过',
            onSecondary: () =>
                ref.read(reviewProvider.notifier).skipCurrent(),
          ),
          if (sq.selected == null || sq.confidence == null)
            Padding(
              padding: EdgeInsets.only(top: 8 * scale),
              child: Text(
                '先点选一个选项，再选置信度，才能提交答案。',
                style: TextStyle(
                  fontSize: DesignTokens.captionFontSize,
                  color: palette.muted,
                ),
              ),
            ),
        ] else if (isTF) ...[
          _TrueFalseButtons(sq: sq),
          SizedBox(height: 12 * scale),
          _ConfidencePicker(sq: sq),
          SizedBox(height: DesignTokens.reviewActsMarginTop * scale),
          _SessionActions(
            primaryLabel: '提交答案',
            primaryEnabled:
                sq.selected != null &&
                sq.selected!.isNotEmpty &&
                sq.confidence != null,
            onPrimary: () =>
                ref.read(reviewProvider.notifier).submitObjectiveAnswer(),
            secondaryLabel: '跳过',
            onSecondary: () =>
                ref.read(reviewProvider.notifier).skipCurrent(),
          ),
          if (sq.selected == null || sq.confidence == null)
            Padding(
              padding: EdgeInsets.only(top: 8 * scale),
              child: Text(
                '先点选“正确/错误”，再选置信度，才能提交答案。',
                style: TextStyle(
                  fontSize: DesignTokens.captionFontSize,
                  color: palette.muted,
                ),
              ),
            ),
        ] else if (isMulti && hasMultiLabels) ...[
          _OptionButtons(question: question, sq: sq, multi: true),
          SizedBox(height: 12 * scale),
          Text(
            '多选/不定项本批不自动判分，只记录你的选择；正确答案在核对区对照。',
            style: TextStyle(
              fontSize: DesignTokens.captionFontSize,
              color: palette.muted,
            ),
          ),
          SizedBox(height: DesignTokens.reviewActsMarginTop * scale),
          _SessionActions(
            primaryLabel: '提交答案',
            primaryEnabled: sq.selected != null && sq.selected!.isNotEmpty,
            onPrimary: () =>
                ref.read(reviewProvider.notifier).submitMultiAnswer(),
            secondaryLabel: '跳过',
            onSecondary: () =>
                ref.read(reviewProvider.notifier).skipCurrent(),
          ),
        ] else ...[
          // 纸上作答：判分不可用的单选题 / 选项不足的多选题 / 填空/计算/证明等。
          _DetailBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isSingle
                      ? '未配置有效答案，不显示选项按钮。请在纸上作答，或先补全答案。'
                      : isMulti
                      ? '选项不足两个，不显示选项按钮。请在纸上作答，或先补全答案。'
                      : '请在纸上演算/作答，完成后点“我已完成作答”。',
                  style: TextStyle(
                    fontSize: DesignTokens.bodySmallFontSize,
                    color: palette.ink2,
                  ),
                ),
                if (question.answerPendingRecheck) ...[
                  SizedBox(height: 6 * scale),
                  Text(
                    '标准答案待重新核对',
                    style: TextStyle(
                      fontSize: DesignTokens.captionFontSize,
                      color: palette.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(height: DesignTokens.reviewActsMarginTop * scale),
          _SessionActions(
            primaryLabel: '我已完成作答',
            onPrimary: () =>
                ref.read(reviewProvider.notifier).completePaperAnswer(),
            secondaryLabel: (isSingle || isMulti) ? '补全答案' : '跳过',
            onSecondary: (isSingle || isMulti)
                ? () async {
                    final st = ref.read(reviewProvider);
                    final q = st.currentQuestion!;
                    final orderIds = st.sessionQuestions
                        .map((e) => e.questionId)
                        .toList();
                    await onOpenDetail(q, orderIds);
                    await ref
                        .read(reviewProvider.notifier)
                        .refreshAfterDetailVisit();
                  }
                : () => ref.read(reviewProvider.notifier).skipCurrent(),
          ),
          if (isSingle || isMulti) ...[
            SizedBox(height: 10 * scale),
            Center(
              child: QmButton(
                label: '跳过',
                size: QmButtonSize.small,
                variant: QmButtonVariant.secondary,
                onPressed: () =>
                    ref.read(reviewProvider.notifier).skipCurrent(),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

/// 选项按钮（按 option_labels 渲染；多选可多选）。
class _OptionButtons extends ConsumerWidget {
  const _OptionButtons({
    required this.question,
    required this.sq,
    this.multi = false,
  });

  final Question question;
  final SessionQuestionState sq;
  final bool multi;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final labels = question.optionLabels ?? const [];
    final selected = sq.selected ?? const [];
    return Wrap(
      spacing: 10 * contextScale(context),
      runSpacing: 8 * contextScale(context),
      children: [
        for (final label in labels)
          QmButton(
            label: label,
            size: QmButtonSize.small,
            variant: selected.contains(label)
                ? QmButtonVariant.primary
                : QmButtonVariant.secondary,
            onPressed: () =>
                ref.read(reviewProvider.notifier).selectOption(label),
          ),
      ],
    );
  }
}

/// 判断题固定按钮（正确/错误，不依赖 option_labels）。
class _TrueFalseButtons extends ConsumerWidget {
  const _TrueFalseButtons({required this.sq});

  final SessionQuestionState sq;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = sq.selected ?? const [];
    return Wrap(
      spacing: 10 * contextScale(context),
      runSpacing: 8 * contextScale(context),
      children: [
        for (final label in ['正确', '错误'])
          QmButton(
            label: label,
            size: QmButtonSize.small,
            variant: selected.contains(label)
                ? QmButtonVariant.primary
                : QmButtonVariant.secondary,
            onPressed: () =>
                ref.read(reviewProvider.notifier).selectOption(label),
          ),
      ],
    );
  }
}

double contextScale(BuildContext context) => qmScaleOf(context);

/// 作答前置信度三选（仅选择/判断，提交前必选）。
class _ConfidencePicker extends ConsumerWidget {
  const _ConfidencePicker({required this.sq});

  final SessionQuestionState sq;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '这次作答有多大把握？',
          style: TextStyle(
            fontSize: DesignTokens.detailFieldLabelFontSize,
            fontWeight: FontWeight.w700,
            color: palette.ink2,
          ),
        ),
        SizedBox(height: 5 * scale),
        Wrap(
          spacing: 10 * scale,
          runSpacing: 8 * scale,
          children: [
            for (final c in ['确定', '不太确定', '猜的'])
              QmButton(
                label: c,
                size: QmButtonSize.small,
                variant: sq.confidence == c
                    ? QmButtonVariant.primary
                    : QmButtonVariant.secondary,
                onPressed: () =>
                    ref.read(reviewProvider.notifier).setConfidence(c),
              ),
          ],
        ),
      ],
    );
  }
}

/// ③ 核对：答案 + 解析分别展示、分别标状态；客观题同时显示对错；
/// 主观题须做核对确认（P1-6）。
class _StepCheck extends ConsumerWidget {
  const _StepCheck();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 选择器必须空安全（见 `_SessionMeta`）。
    final m = ref.watch(
      reviewProvider.select((s) {
        final q = s.currentQuestion;
        if (q == null) return null;
        return (q, s.currentSessionQuestion, s.isPracticeSession);
      }),
    );
    if (m == null) return const SizedBox.shrink();
    final (question, sq, isPractice) = m;
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final graded = objectiveGradingAvailable(question);
    final hasAnswer = question.hasValidStandardAnswer;
    final showCheckConfirm = !graded && hasAnswer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (sq.correct != null) ...[
          _DetailBox(
            child: Text(
              sq.correct == 1 ? '回答正确' : '回答错误',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          SizedBox(height: 12 * scale),
        ] else if (graded == false &&
            (question.questionType == 'choice_single' ||
                question.questionType == 'true_false') &&
            sq.selected != null) ...[
          _DetailBox(
            child: const Text('本次作答不判分：只记录了你的选择与置信度。'),
          ),
          SizedBox(height: 12 * scale),
        ],
        _DetailBox(
          child: Column(
            children: [
              _KvRow(
                label: '标准答案',
                value: _answerDisplay(question),
              ),
              _KvRow(
                label: '解析',
                value: _explanationDisplay(question),
              ),
            ],
          ),
        ),
        if (showCheckConfirm) ...[
          SizedBox(height: 12 * scale),
          Text(
            '对照答案核对一下：',
            style: TextStyle(
              fontSize: DesignTokens.detailFieldLabelFontSize,
              fontWeight: FontWeight.w700,
              color: palette.ink2,
            ),
          ),
          SizedBox(height: 5 * scale),
          Wrap(
            spacing: 10 * scale,
            runSpacing: 8 * scale,
            children: [
              for (final c in [
                '已对照，关键答案/步骤符合',
                '已对照，有错误或明显遗漏',
                '无法判断',
                '尚未核对',
              ])
                QmButton(
                  label: c,
                  size: QmButtonSize.small,
                  variant: sq.checkConfirm == c
                      ? QmButtonVariant.primary
                      : QmButtonVariant.secondary,
                  onPressed: () =>
                      ref.read(reviewProvider.notifier).setCheckConfirm(c),
                ),
            ],
          ),
          SizedBox(height: 6 * scale),
          Text(
            '只有选“符合”才具备软件标准答案核验资格；“显示过答案”不等于“已经核对”。',
            style: TextStyle(
              fontSize: DesignTokens.captionFontSize,
              color: palette.muted,
            ),
          ),
        ],
        // 待重新核对时 KvRow 已显示“标准答案待重新核对”，这里不再
        // 说“暂无标准答案/解析”，避免两处文案互相矛盾。
        if (!hasAnswer && !graded && !question.answerPendingRecheck) ...[
          SizedBox(height: 12 * scale),
          Text(
            '暂无标准答案/解析，可用手边教材、讲义自行核对；自查时可勾选外部核对。',
            style: TextStyle(
              fontSize: DesignTokens.captionFontSize,
              color: palette.muted,
            ),
          ),
        ],
        SizedBox(height: DesignTokens.reviewActsMarginTop * scale),
        if (isPractice) ...[
          _SessionActions(
            primaryLabel: '下一题',
            onPrimary: () =>
                ref.read(reviewProvider.notifier).nextPracticeQuestion(),
            secondaryLabel: '跳过',
            onSecondary: () =>
                ref.read(reviewProvider.notifier).skipCurrent(),
          ),
          SizedBox(height: 12 * scale),
          _PracticeRejoinRow(question: question, sq: sq),
        ] else
          _SessionActions(
            primaryLabel: '下一步：自查',
            onPrimary: () =>
                ref.read(reviewProvider.notifier).enterSelfCheck(),
            secondaryLabel: '跳过',
            onSecondary: () =>
                ref.read(reviewProvider.notifier).skipCurrent(),
          ),
      ],
    );
  }

  /// 答案与解析分别展示、分别标状态（M3-14/用户流程第 13 节）：
  /// 待重新核对时显示“标准答案待重新核对”，不显示旧文本。
  String _answerDisplay(Question q) {
    if (q.answerPendingRecheck) return '标准答案待重新核对';
    if (q.questionType == 'choice_single' ||
        q.questionType == 'true_false') {
      final correct = q.effectiveCorrectOption;
      if (correct == null || correct.isEmpty) return '标准答案：待补充';
      return correct;
    }
    final answer = q.effectiveAnswer;
    if (answer == null || answer.trim().isEmpty) return '标准答案：待补充';
    return answer;
  }

  String _explanationDisplay(Question q) {
    if (q.answerPendingRecheck) return '解析待重新核对';
    final explanation = q.effectiveExplanation;
    if (explanation == null || explanation.trim().isEmpty) {
      return '解析：待补充';
    }
    return explanation;
  }
}

/// 专项练习核对页的“重新加入复习”行（M3-2）。
class _PracticeRejoinRow extends ConsumerWidget {
  const _PracticeRejoinRow({required this.question, required this.sq});

  final Question question;
  final SessionQuestionState sq;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final causes = question.allCauses;
    if (causes.isEmpty) return const SizedBox.shrink();
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return _DetailBox(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '发现自己又不会了？',
            style: TextStyle(
              fontSize: DesignTokens.bodySmallFontSize,
              fontWeight: FontWeight.w700,
              color: palette.ink,
            ),
          ),
          SizedBox(height: 6 * scale),
          for (final cause in causes)
            Padding(
              padding: EdgeInsets.only(top: 4 * scale),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      cause,
                      style: TextStyle(
                        fontSize: DesignTokens.bodySmallFontSize,
                        color: palette.ink2,
                      ),
                    ),
                  ),
                  QmButton(
                    label: '将此错因重新加入复习',
                    size: QmButtonSize.small,
                    variant: QmButtonVariant.secondary,
                    onPressed: () => ref
                        .read(reviewProvider.notifier)
                        .rejoinCauseFromPractice(cause),
                  ),
                ],
              ),
            ),
          SizedBox(height: 4 * scale),
          Text(
            '只影响后续会话，不改变本次练习记录。',
            style: TextStyle(
              fontSize: DesignTokens.captionFontSize,
              color: palette.muted,
            ),
          ),
        ],
      ),
    );
  }
}

/// ④ 错因自查（仅到期复习）：逐错因选 verdict；客观题答对且信心确定
/// 时逐错因做证据关联判断；无软件答案时选“已解决”出现外部核对勾选；
/// 对策默认收起、可展开查看、可编辑。
class _StepSelfCheck extends ConsumerWidget {
  const _StepSelfCheck();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 选择器必须空安全（见 `_SessionMeta`）。
    final sel = ref.watch(
      reviewProvider.select(
        (s) => (
          s.hasCurrentQuestion ? s.currentSessionQuestion : null,
          s.currentQuestion,
          s.sessionIndex,
          s.sessionQuestions.length,
          s.settings.cureChecks,
          s.submitting,
        ),
      ),
    );
    final (sq, question, index, total, cureChecks, submitting) = sel;
    if (sq == null || question == null) return const SizedBox.shrink();
    final scale = qmScaleOf(context);
    final st = ref.read(reviewProvider);
    final allChecked = sq.causes.every(
      (c) => sq.verdicts.containsKey(c) || sq.submittedCauses.contains(c),
    );
    final showEvidence =
        sq.correct == 1 && sq.confidence == '确定' &&
        objectiveGradingAvailable(question);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '这道题的 ${sq.causes.length} 个错因挨着自查：这次做对，是因为错因已解决，还是只是记住了这道题的答案？',
          style: const TextStyle(fontSize: 14),
        ),
        SizedBox(height: 10 * scale),
        for (final cause in sq.causes)
          _buildCheckBox(
            context,
            ref,
            st,
            sq,
            question,
            cause,
            cureChecks,
            showEvidence,
          ),
        SizedBox(height: DesignTokens.reviewActsMarginTop * scale),
        _SessionActions(
          primaryLabel: submitting
              ? '提交中…'
              : (index < total - 1 ? '下一题' : '看总结'),
          primaryEnabled: allChecked && !submitting,
          onPrimary: () => ref.read(reviewProvider.notifier).finishQuestion(),
          secondaryLabel: '跳过',
          onSecondary: () => ref.read(reviewProvider.notifier).skipCurrent(),
        ),
      ],
    );
  }

  Widget _buildCheckBox(
    BuildContext context,
    WidgetRef ref,
    ReviewState st,
    SessionQuestionState sq,
    Question question,
    String cause,
    int cureChecks,
    bool showEvidence,
  ) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final notifier = ref.read(reviewProvider.notifier);
    final record = st.recordOf(sq.questionId, cause);
    final selected = sq.verdicts[cause];
    final submitted = sq.submittedCauses.contains(cause);
    final invalid = sq.invalidCauses.contains(cause);
    final evidence = sq.evidenceLinks[cause];
    final externalChecked = sq.externalChecked[cause] ?? false;
    final needsExternal =
        selected == '已解决' &&
        !question.hasValidStandardAnswer &&
        !objectiveGradingAvailable(question);
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
                    '「已解决」${record.solvedCount} / $cureChecks 次',
                    style: TextStyle(
                      fontSize: DesignTokens.reviewMetaFontSize,
                      color: palette.muted,
                    ),
                  ),
                if (record != null && record.isRecheckDue)
                  QmStatusPill.cause(QmCauseStatus.recheck),
                if (record != null &&
                    record.lastCountedSuccessAt != null)
                  Text(
                    '下次可计入治愈的最早时间：${formatReviewDate(DateTime.fromMillisecondsSinceEpoch(record.lastCountedSuccessAt! + cureMinIntervalMs))}',
                    style: TextStyle(
                      fontSize: DesignTokens.captionFontSize,
                      color: palette.muted,
                    ),
                  ),
                if (submitted)
                  Text(
                    '已提交',
                    style: TextStyle(
                      fontSize: DesignTokens.captionFontSize,
                      color: palette.muted,
                    ),
                  ),
              ],
            ),
            if (invalid) ...[
              SizedBox(height: 6 * scale),
              Text(
                '该错因已失效',
                style: TextStyle(
                  fontSize: DesignTokens.captionFontSize,
                  color: palette.muted,
                ),
              ),
            ],
            SizedBox(height: 8 * scale),
            _RemedyViewer(
              record: record,
              cause: cause,
            ),
            SizedBox(height: 8 * scale),
            if (!submitted) ...[
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
                      onPressed: () => notifier.setVerdict(cause, op),
                    ),
                ],
              ),
              if (selected == '不确定') ...[
                SizedBox(height: 6 * scale),
                Text(
                  '选「不确定」记为一次中性复习事件，不推进治愈、不改治疗状态，下次还要重新练这道题。',
                  style: TextStyle(
                    fontSize: DesignTokens.captionFontSize,
                    color: palette.muted,
                  ),
                ),
              ],
              if (showEvidence) ...[
                SizedBox(height: 10 * scale),
                Text(
                  '本次作答是否直接检验了这个错因？',
                  style: TextStyle(
                    fontSize: DesignTokens.detailFieldLabelFontSize,
                    fontWeight: FontWeight.w700,
                    color: palette.ink2,
                  ),
                ),
                SizedBox(height: 5 * scale),
                Wrap(
                  spacing: 10 * scale,
                  runSpacing: 8 * scale,
                  children: [
                    for (final op in ['是', '否', '不确定'])
                      QmButton(
                        label: op,
                        size: QmButtonSize.small,
                        variant: evidence == op
                            ? QmButtonVariant.primary
                            : QmButtonVariant.secondary,
                        onPressed: () =>
                            notifier.setEvidenceLink(cause, op),
                      ),
                  ],
                ),
                if (evidence == null)
                  Padding(
                    padding: EdgeInsets.only(top: 4 * scale),
                    child: Text(
                      '不选则该错因按未核验处理。',
                      style: TextStyle(
                        fontSize: DesignTokens.captionFontSize,
                        color: palette.muted,
                      ),
                    ),
                  ),
              ],
              if (needsExternal) ...[
                SizedBox(height: 10 * scale),
                InkWell(
                  onTap: () => notifier.setExternalChecked(
                    cause,
                    !externalChecked,
                  ),
                  child: Row(
                    children: [
                      Checkbox(
                        value: externalChecked,
                        onChanged: (v) => notifier.setExternalChecked(
                          cause,
                          v ?? false,
                        ),
                      ),
                      const Expanded(
                        child: Text('我已对照课本/讲义等可靠外部资料核对'),
                      ),
                    ],
                  ),
                ),
                Text(
                  '不勾选即按未核验处理，不推进治愈。',
                  style: TextStyle(
                    fontSize: DesignTokens.captionFontSize,
                    color: palette.muted,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// 对策回顾（M3-12）：默认先让用户尝试回忆，可展开查看上次对策，
/// 不强制每次重新填写；觉得不适用时可编辑，保存后覆盖当前对策。
class _RemedyViewer extends ConsumerStatefulWidget {
  const _RemedyViewer({required this.record, required this.cause});

  final CauseRecord? record;
  final String cause;

  @override
  ConsumerState<_RemedyViewer> createState() => _RemedyViewerState();
}

class _RemedyViewerState extends ConsumerState<_RemedyViewer> {
  bool _expanded = false;
  bool _editing = false;
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final lastRemedy =
        record == null || record.remedyHistory.isEmpty
            ? null
            : record.remedyHistory.first;
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    if (lastRemedy == null && !_editing) {
      return Row(
        children: [
          Expanded(
            child: Text(
              '还没有保存过对策，先自己想一想这次该怎么补。',
              style: TextStyle(
                fontSize: DesignTokens.captionFontSize,
                color: palette.muted,
              ),
            ),
          ),
          QmButton(
            label: '写对策',
            size: QmButtonSize.small,
            variant: QmButtonVariant.secondary,
            onPressed: () => setState(() => _editing = true),
          ),
        ],
      );
    }
    if (_editing) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            maxLines: 3,
            style: TextStyle(
              fontSize: DesignTokens.reviewRemedyFontSize,
              color: palette.ink,
            ),
            decoration: InputDecoration(
              hintText: '这次怎么补「${widget.cause}」：自己写，不套模板',
              hintStyle: TextStyle(color: palette.muted),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 12 * scale,
                vertical: 10 * scale,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(
                  DesignTokens.radius * scale,
                ),
                borderSide: BorderSide(color: palette.lineStrong),
              ),
              filled: true,
              fillColor: palette.surface,
            ),
          ),
          SizedBox(height: 6 * scale),
          Row(
            children: [
              QmButton(
                label: '保存对策',
                size: QmButtonSize.small,
                onPressed: () async {
                  await ref
                      .read(reviewProvider.notifier)
                      .saveRemedyDraft(widget.cause, _controller.text);
                  if (mounted) {
                    setState(() {
                      _editing = false;
                      _controller.clear();
                    });
                  }
                },
              ),
              SizedBox(width: 8 * scale),
              QmButton(
                label: '取消',
                size: QmButtonSize.small,
                variant: QmButtonVariant.secondary,
                onPressed: () => setState(() {
                  _editing = false;
                  _controller.clear();
                }),
              ),
            ],
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '上次对策（先自己回忆，可展开查看）',
                style: TextStyle(
                  fontSize: DesignTokens.captionFontSize,
                  color: palette.muted,
                ),
              ),
            ),
            QmButton(
              label: _expanded ? '收起' : '展开查看',
              size: QmButtonSize.small,
              variant: QmButtonVariant.secondary,
              onPressed: () => setState(() => _expanded = !_expanded),
            ),
            SizedBox(width: 8 * scale),
            QmButton(
              label: '编辑',
              size: QmButtonSize.small,
              variant: QmButtonVariant.secondary,
              onPressed: () => setState(() {
                _editing = true;
                _controller.text = '';
              }),
            ),
          ],
        ),
        if (_expanded) ...[
          SizedBox(height: 4 * scale),
          Text(
            lastRemedy!,
            style: TextStyle(
              fontSize: DesignTokens.bodySmallFontSize,
              color: palette.ink2,
            ),
          ),
        ],
      ],
    );
  }
}

/// 已提交全部错因 verdict 后的过渡态（正常情况下 finishQuestion
/// 直接进下一题；本态只在恢复后遇到已提交的题时出现）。
class _StepDone extends ConsumerWidget {
  const _StepDone();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('这道题的错因已全部提交。'),
        SizedBox(height: DesignTokens.reviewActsMarginTop * qmScaleOf(context)),
        _SessionActions(
          primaryLabel: '下一题',
          onPrimary: () =>
              ref.read(reviewProvider.notifier).advanceToNextQuestion(),
        ),
      ],
    );
  }
}

// ---------- 总结 ----------

/// 本轮复习总结（M3-15；只订阅总结要的数）。
class _SummaryView extends ConsumerWidget {
  const _SummaryView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(reviewProvider);
    final scale = qmScaleOf(context);
    final isPractice = st.sessionMode == ReviewMode.practice;
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
                Text(
                  isPractice ? '本次专项练习小结' : '本轮复习总结',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 6 * scale),
                if (isPractice) ...[
                  Text(
                    '练习 ${st.sumCompleted} 道题 · 答对 ${st.sumObjCorrect} 道 · 答错 ${st.sumObjWrong} 道 · 猜对 ${st.sumObjGuessed} 道（猜的答对不计入掌握）',
                  ),
                  SizedBox(height: 6 * scale),
                  const Text('本次练习不改变治疗进度。'),
                ] else ...[
                  Text.rich(
                    TextSpan(
                      style: const TextStyle(fontSize: 14),
                      children: [
                        const TextSpan(text: '完成 '),
                        TextSpan(
                          text: '${st.sumCompleted}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const TextSpan(text: ' 道题 · 处理 '),
                        TextSpan(
                          text: '${st.sumHandled}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const TextSpan(text: ' 个错因 · 新治愈 '),
                        TextSpan(
                          text: '${st.curedNow}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const TextSpan(text: ' 个错因'),
                      ],
                    ),
                  ),
                  SizedBox(height: 6 * scale),
                  Text(
                    '复查通过 ${st.sumRecheckPassed} 个 · 打回 ${st.sumRecheckFailed} 个 · 未核验自评 ${st.sumUnverified} 个 · 未判分/无标准答案 ${st.sumUngraded} 道',
                  ),
                  SizedBox(height: 6 * scale),
                  Text(
                    '跳过 ${st.sumSkipped} 道 · 留待下次 ${st.sumDeferred} 道 · 本次客观作答答对 ${st.sumObjCorrect} 道 / 答错 ${st.sumObjWrong} 道（仅有答案的题）',
                  ),
                  if (st.sumNextRecheckDate != null) ...[
                    SizedBox(height: 6 * scale),
                    Text(
                      '下次复查 ${formatReviewDate(st.sumNextRecheckDate!)}',
                    ),
                  ],
                  SizedBox(height: 6 * scale),
                  Text(
                    '今天解决了 ${st.curedNow} 个错因 · 还有 ${st.summaryRemaining} 个未解决，留在列表里接着解决',
                  ),
                ],
                SizedBox(height: 8 * scale),
                if (st.changes.isEmpty)
                  Text(
                    '这一轮还没有自查记录。',
                    style: TextStyle(
                      fontSize: DesignTokens.bodySmallFontSize,
                      color: DesignTokens.of(Theme.of(context).brightness)
                          .muted,
                    ),
                  )
                else
                  for (final c in st.changes)
                    _KvRow(
                      label: '${c.subjectName} · ${c.cause}',
                      value:
                          '「${c.questionTitle}」：${c.before} → ${c.after}'
                          '${c.recheckDate != null ? ' · 下次复查 ${formatReviewDate(c.recheckDate!)}（${formatReviewMd(c.recheckDate!)}）' : ''}'
                          ' · ${c.note}',
                    ),
                SizedBox(height: 12 * scale),
                Wrap(
                  spacing: 8 * scale,
                  runSpacing: 8 * scale,
                  children: [
                    QmButton(
                      label: '回复习列表',
                      onPressed: () =>
                          ref.read(reviewProvider.notifier).backToList(),
                    ),
                    if (!isPractice)
                      QmButton(
                        label: '再练一次',
                        variant: QmButtonVariant.secondary,
                        onPressed: () =>
                            ref.read(reviewProvider.notifier).startSession(),
                      ),
                  ],
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
        borderRadius: BorderRadius.circular(DesignTokens.radiusLg * scale),
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
            constraints: BoxConstraints(
              minWidth: DesignTokens.reviewKvLabelWidth * scale,
            ),
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
