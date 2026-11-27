// 复习页（P2 简化基线，D2）。
//
// 列表：按 FSRS 卡片状态分组（①已逾期 → ②今日到期 → ③未到期 →
// ④未开始 → ⑤未加入复习），一题一行（错因名与 FSRS 状态）；页顶
// 到期 / 今日新题（与首页焦点卡同一口径）+ “开始复习”主按钮 +
// “专项练习”次按钮；学科/题型/错因筛选保留；未加入盒保留。
// 会话：三步统一流程（看题 → 作答 → 核对 → 下一题 → 小结），一道题
// 内部的状态变化，不是每段翻一页；一题多错因时题目只展示一次、用户
// 只需重做一次、答案只需揭示一次；核对页一次提交：写 attempts 正式
// 记录 + 调 FSRS（到期复习且可判分时），专项练习不调 FSRS、不改到期
// 时间。全部操作点按（鼠标/触屏），不设键盘快捷键。
// 业务口径沿用基线（repository.recordAttempt / reviewState /
// reviewScheduler；客观判分见 lib/data/review_engine.dart）。
// 旧翻卡模型不复活，不出现 1/3/7/14 天旧复习状态。
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

import '../../data/p4_new_release.dart';
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
    this.initialPracticeQuestionIds,
    this.initialPracticeCount,
    required this.onGoWrongbook,
  });

  final QuestionRepository repo;
  final Future<void> Function(Question q, List<String> orderIds) onOpenDetail;
  final String? initialSubjectId;

  /// P3 入口 1/3：带一批题 id 进来直接开专项练习（见 [ReviewInitial]）。
  final List<String>? initialPracticeQuestionIds;
  final int? initialPracticeCount;
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
          ReviewInitial(
            subjectId: widget.initialSubjectId,
            practiceQuestionIds: widget.initialPracticeQuestionIds,
            practiceCount: widget.initialPracticeCount,
          ),
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
    // 只订阅模式切换要的字段：会话内点选不让整页重建，只有当前步重建。
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

/// 小结用时：不足 1 分钟按秒计，否则按“X 分 Y 秒”计。
String _formatDuration(int seconds) {
  if (seconds < 60) return '$seconds 秒';
  return '${seconds ~/ 60} 分 ${seconds % 60} 秒';
}

/// 小结弱点：按答错题数从多到少，取前 5 个知识点。
List<MapEntry<String, int>> _weakKpEntries(ReviewState st) {
  final entries = st.sumWeakKp.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return entries.take(5).toList();
}

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

/// 按 FSRS 卡片状态分组的列表行（一题一行）。
class _QuestionRowData {
  _QuestionRowData({
    required this.question,
    required this.records,
    required this.fsrsCard,
  });

  final Question question;
  final List<CauseRecord> records;

  /// 本题的 FSRS 卡片状态（null = 无卡，按「未开始」处理）。
  final FsrsCardStatus? fsrsCard;

  /// 是否已逾期（行内复查角标用）。
  bool get isOverdue =>
      fsrsListBucketFor(fsrsCard) == FsrsListBucket.overdue;

  /// 行状态文案（FSRS 口径，与分组同源）：
  /// 已逾期 N 天 / 今日到期 / 未到期 · M月M日 / 未开始。
  String get statusText {
    final card = fsrsCard;
    if (card == null) return '未开始';
    switch (fsrsListBucketFor(card)) {
      case FsrsListBucket.notStarted:
        return '未开始';
      case FsrsListBucket.overdue:
        final now = DateTime.now();
        final todayDay = DateTime(now.year, now.month, now.day);
        final dueLocal = card.nextDueAt.toLocal();
        final dueDay = DateTime(dueLocal.year, dueLocal.month, dueLocal.day);
        return '已逾期 ${todayDay.difference(dueDay).inDays} 天';
      case FsrsListBucket.dueToday:
        return '今日到期';
      case FsrsListBucket.notDue:
        final dueLocal = card.nextDueAt.toLocal();
        return '未到期 · ${dueLocal.month}月${dueLocal.day}日';
    }
  }
}

/// 列表按 FSRS 卡片状态分组（面 A）：①已逾期 ②今日到期
/// ③未到期 ④未开始 ⑤未加入复习（未加入盒另行渲染，不在这里）。
/// 分组只看卡片状态（`st.fsrsCardStatus`），不看错因记录；
/// 已加入复习但无卡的题归入「未开始」，不丢题。
/// 学科/题型/错因三维筛选保留（错因只作筛选维度，不作分组依据）。
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
  final notDue = <_QuestionRowData>[];
  final notStarted = <_QuestionRowData>[];
  for (final entry in byQ.entries) {
    final q = st.questionOf(entry.key);
    if (q == null) continue;
    final rs = entry.value;
    if (!keep(q, rs)) continue;
    final row = _QuestionRowData(
      question: q,
      records: rs,
      fsrsCard: st.fsrsCardStatus[q.id],
    );
    switch (fsrsListBucketFor(st.fsrsCardStatus[q.id])) {
      case FsrsListBucket.overdue:
        overdue.add(row);
      case FsrsListBucket.dueToday:
        dueToday.add(row);
      case FsrsListBucket.notDue:
        notDue.add(row);
      case FsrsListBucket.notStarted:
        notStarted.add(row);
    }
  }
  return (overdue, dueToday, notDue, notStarted);
}

// ---------- 列表 ----------

/// 复习列表（页顶到期 / 今日新题 + 开始复习/专项练习、FSRS 状态
/// 分组、筛选、未加入盒、恢复条、空状态）。
class _ListView extends ConsumerStatefulWidget {
  const _ListView({required this.onOpenDetail, required this.onGoWrongbook});

  final Future<void> Function(Question q, List<String> orderIds) onOpenDetail;
  final VoidCallback onGoWrongbook;

  @override
  ConsumerState<_ListView> createState() => _ListViewState();
}

class _ListViewState extends ConsumerState<_ListView> {
  @override
  Widget build(BuildContext context) {
    final st = ref.watch(reviewProvider);
    final notifier = ref.read(reviewProvider.notifier);
    final scale = qmScaleOf(context);
    // 页顶数（面 A：与首页焦点卡同一 FSRS 口径）：到期 X 道 ·
    // 今日新题 Y 道（Y=0 时只显示到期）；旧三数已取消。
    final dueCount = st.fsrsDueIds.length;
    final todayNewCount = st.fsrsTodaysNewIds.length;
    final (notDueCount, notStartedCount) = st.fsrsFutureCounts;
    final hasData = st.groups.isNotEmpty || st.curedGroups.isNotEmpty;
    final (overdue, dueToday, notDue, notStarted) =
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
          // P4：FSRS 当日清单——到期题与新题区分显示，未释放的标
          // “待开始”，不混入到期题（池里有卡时才显示；老数据无卡时
          // 不出这块）。
          if (st.fsrsPoolIds.isNotEmpty) ...[
            _buildFsrsBox(context, st),
            SizedBox(height: 14 * scale),
          ],
          // 页顶：到期 / 今日新题 + 开始复习（主）+ 专项练习（次）。
          // “开始复习”按会话实际能否开队决定（见 canStartDueSession：
          // 池空的老数据走旧错因队列，不只看 FSRS 数）。
          _DetailBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    style: const TextStyle(fontSize: 14),
                    children: [
                      const TextSpan(text: '到期 '),
                      TextSpan(
                        text: '$dueCount',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const TextSpan(text: ' 道'),
                      if (todayNewCount > 0) ...[
                        const TextSpan(text: ' · 今日新题 '),
                        TextSpan(
                          text: '$todayNewCount',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const TextSpan(text: ' 道'),
                      ],
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
                      onPressed: st.canStartDueSession
                          ? () => _startDue(context, st)
                          : null,
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
          ] else ...[
            // 今天开不了到期复习时，提示条只作提醒（面 A：未到期/
            // 未开始的题仍在下面分组里列出，不再像旧口径那样整段
            // 藏起列表）。
            if (!st.canStartDueSession && st.resume == null) ...[
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
                      '未到期的题有 $notDueCount 道，未开始的题有 $notStartedCount 道。',
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
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(height: 14 * scale),
            ],
            _buildMetaRow(context, st),
            _buildToolbar(context, st),
            _buildPagedRows(context, st, overdue, dueToday, notDue, notStarted),
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

  /// P4：FSRS 当日清单盒（到期 / 今日新题 / 待开始区分显示）。
  ///
  /// 数字来自 load() 时的预览（不写库）：到期是真正到期的 FSRS 卡，
  /// 今日新题是已释放可练的新题（含昨日遗留续接），待开始是未释放、
  /// 排队中的新题。括号里一行写清当日规则：每天最多呈现几道新题
  /// （设置里的每日新增）、待完成新题满 10 道暂停释放。
  Widget _buildFsrsBox(BuildContext context, ReviewState st) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return _DetailBox(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              style: const TextStyle(fontSize: 14),
              children: [
                const TextSpan(text: '今日到期 '),
                TextSpan(
                  text: '${st.fsrsDueIds.length}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const TextSpan(text: ' 道 · 今日新题 '),
                TextSpan(
                  text: '${st.fsrsTodaysNewIds.length}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const TextSpan(text: ' 道 · 待开始 '),
                TextSpan(
                  text: '${st.fsrsWaitingIds.length}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const TextSpan(text: ' 道'),
              ],
            ),
          ),
          SizedBox(height: 6 * scale),
          Text(
            '新题每天最多呈现 ${st.settings.dailyNewQuestions} 道（设置里可改）；'
            '已释放未完成的先续接，待完成新题满 10 道暂停释放；'
            '待开始的题今天不进复习队列。',
            style: TextStyle(
              fontSize: DesignTokens.bodySmallFontSize,
              color: palette.muted,
            ),
          ),
        ],
      ),
    );
  }

  /// 列表排序说明行（面 A：旧三数已取消，只留排序文案）。
  Widget _buildMetaRow(BuildContext context, ReviewState st) {
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
          Text(
            st.settings.reviewSort == 'subject'
                ? '列表按学科排$subjectHint'
                : '列表按加入时间排',
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
  /// ①已逾期 → ②今日到期 → ③未到期 → ④未开始
  /// 的顺序拼成一列，一题一行，按每页条数切片；分组头只在该页
  /// 首次出现该组时画一次。筛选改动后回第 1 页（notifier 侧已复位）。
  Widget _buildPagedRows(
    BuildContext context,
    ReviewState st,
    List<_QuestionRowData> overdue,
    List<_QuestionRowData> dueToday,
    List<_QuestionRowData> notDue,
    List<_QuestionRowData> notStarted,
  ) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final flat = <(String, _QuestionRowData)>[
      for (final r in overdue) ('已逾期', r),
      for (final r in dueToday) ('今日到期', r),
      for (final r in notDue) ('未到期', r),
      for (final r in notStarted) ('未开始', r),
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
    // P4：行内 FSRS 状态标——到期 / 今日新题 / 待开始三者取其一，
    // 未开始且未释放的题明确标“待开始”，不混入到期题；已开始未到期的
    // 题不标（状态文案里已有“未到期 · M月M日”）。
    final fsrsLabel = fsrsListLabel(
      questionId: q.id,
      dueIds: st.fsrsDueIds,
      todaysNewIds: st.fsrsTodaysNewIds,
      waitingIds: st.fsrsWaitingIds,
    );
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
                  if (fsrsLabel != null)
                    Text(
                      'FSRS：$fsrsLabel',
                      style: TextStyle(
                        fontSize: DesignTokens.captionFontSize,
                        color: palette.muted,
                      ),
                    ),
                ],
              ),
            ),
            if (row.isOverdue) ...[
              QmStatusPill.cause(QmCauseStatus.recheck),
              SizedBox(width: 6 * scale),
            ],
          ],
        ),
      ),
    );
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
            '到这些题的题目详情「复习记录」里点「加入复习」才会进来；归档的题不出现在复习列表里；加入复习后按 FSRS 间隔安排，到期了会回到上面的到期列表里。',
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
            '只练，不排：本次练习不改变到期时间、不参与 FSRS 调度。',
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
/// 与“当前题是否还在”。
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
          if (stage == SessionStage.done) const _StepDone(),
        ],
      ),
    );
  }
}

/// 核对保存失败横幅（只订阅 `saveError`）。
class _SessionSaveErrorBanner extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saveError = ref.watch(reviewProvider.select((s) => s.saveError));
    if (!saveError) return const SizedBox.shrink();
    return QmBanner(
      tone: QmBannerTone.error,
      message: '复习记录保存失败，本次核对还没有存下。请重试，或重启应用后再复习。',
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
            '专项练习：本次练习不改变到期时间。',
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
      SessionStage.done => 2,
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
          s.subjectOf(q.subjectId),
          s.isPracticeSession,
        );
      }),
    );
    if (m == null) return const SizedBox.shrink();
    final (question, sq, subject, isPractice) = m;
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
    if (record.isRecheckDue) return '待复查';
    return record.status.label;
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
          SizedBox(height: DesignTokens.reviewActsMarginTop * scale),
          _SessionActions(
            primaryLabel: '提交答案',
            primaryEnabled:
                sq.selected != null && sq.selected!.isNotEmpty,
            onPrimary: () =>
                ref.read(reviewProvider.notifier).submitObjectiveAnswer(),
            secondaryLabel: '跳过',
            onSecondary: () =>
                ref.read(reviewProvider.notifier).skipCurrent(),
          ),
          if (sq.selected == null)
            Padding(
              padding: EdgeInsets.only(top: 8 * scale),
              child: Text(
                '先点选一个选项，才能提交答案。',
                style: TextStyle(
                  fontSize: DesignTokens.captionFontSize,
                  color: palette.muted,
                ),
              ),
            ),
        ] else if (isTF) ...[
          _TrueFalseButtons(sq: sq),
          SizedBox(height: DesignTokens.reviewActsMarginTop * scale),
          _SessionActions(
            primaryLabel: '提交答案',
            primaryEnabled:
                sq.selected != null && sq.selected!.isNotEmpty,
            onPrimary: () =>
                ref.read(reviewProvider.notifier).submitObjectiveAnswer(),
            secondaryLabel: '跳过',
            onSecondary: () =>
                ref.read(reviewProvider.notifier).skipCurrent(),
          ),
          if (sq.selected == null)
            Padding(
              padding: EdgeInsets.only(top: 8 * scale),
              child: Text(
                '先点选“正确/错误”，才能提交答案。',
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

/// ③ 核对：答案 + 解析分别展示、分别标状态；客观题同时显示对错；
/// 点“确认核对”一次提交（写 attempts + 调 FSRS，如适用），再进下一题。
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
            child: const Text('本次作答不判分：只记录了你的选择。'),
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
            '对照标准答案和解析核对一下，确认后进入下一题。',
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
            '暂无标准答案/解析，可用手边教材、讲义自行核对。',
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
                ref.read(reviewProvider.notifier).submitCheck(),
            secondaryLabel: '跳过',
            onSecondary: () =>
                ref.read(reviewProvider.notifier).skipCurrent(),
          ),
          SizedBox(height: 12 * scale),
          _PracticeRejoinRow(question: question, sq: sq),
        ] else
          _SessionActions(
            primaryLabel: '确认核对，下一题',
            onPrimary: () =>
                ref.read(reviewProvider.notifier).submitCheck(),
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

/// 已核对提交后的过渡态（正常情况下 submitCheck 直接进下一题；
/// 本态只在恢复后遇到已提交的题时出现）。
class _StepDone extends ConsumerWidget {
  const _StepDone();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('这道题已核对完成。'),
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
///
/// P3 入口 2：专项练习小结末尾加“本次答错的题”收题块（见
/// [_SummaryCollectSection]）。中途退出（暂停/返回列表）不产生小结、
/// 不自动收题；已核对过的前几道练习事实已在 submitCheck 里写进
/// attempts，不自动改正式复习日期；恢复完成后再出完整小结。
class _SummaryView extends ConsumerStatefulWidget {
  const _SummaryView();

  @override
  ConsumerState<_SummaryView> createState() => _SummaryViewState();
}

class _SummaryViewState extends ConsumerState<_SummaryView> {
  @override
  void initState() {
    super.initState();
    // 小结首次展示时定一次默认勾选（答错默认全勾、已在池的不勾、
    // 未判分默认不勾）；同一轮重复进小结不重置（按 sessionId 隔离）。
    // initState 里直接改 provider 会在 build 阶段抛错（Riverpod 禁止
    // build 期改 provider），所以推迟到首帧后。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(reviewProvider.notifier).initSummaryCollect();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
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
                    '练习 ${st.sumCompleted} 道题 · 答对 ${st.sumObjCorrect} 道 · 答错 ${st.sumObjWrong} 道 · 未判分 ${st.sumUngraded} 道',
                  ),
                  SizedBox(height: 6 * scale),
                  Text('用时 ${_formatDuration(st.sumElapsedSeconds)}'),
                  SizedBox(height: 6 * scale),
                  const Text('本次练习不改变到期时间。'),
                ] else ...[
                  Text(
                    '完成 ${st.sumCompleted} 道题 · 答对 ${st.sumObjCorrect} 道 · 答错 ${st.sumObjWrong} 道 · 未判分 ${st.sumUngraded} 道',
                  ),
                  SizedBox(height: 6 * scale),
                  Text('用时 ${_formatDuration(st.sumElapsedSeconds)}'),
                  SizedBox(height: 6 * scale),
                  Text(
                    '跳过 ${st.sumSkipped} 道 · 留待下次 ${st.sumDeferred} 道',
                  ),
                  if (st.sumNextDueDate != null) ...[
                    SizedBox(height: 6 * scale),
                    Text(
                      '下次复习最早 ${formatReviewDate(st.sumNextDueDate!)}',
                    ),
                  ],
                ],
                SizedBox(height: 8 * scale),
                if (st.sumWeakKp.isEmpty)
                  Text(
                    '本次没有按知识点排出的薄弱点。',
                    style: TextStyle(
                      fontSize: DesignTokens.bodySmallFontSize,
                      color: DesignTokens.of(Theme.of(context).brightness)
                          .muted,
                    ),
                  )
                else ...[
                  const Text(
                    '薄弱点（按答错题数排）：',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  for (final entry in _weakKpEntries(st))
                    _KvRow(
                      label: st.kpNames[entry.key] ?? '待补充',
                      value: '答错 ${entry.value} 道',
                    ),
                ],
                if (isPractice) ...[
                  SizedBox(height: 12 * scale),
                  const _SummaryCollectSection(),
                ],
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

/// P3 入口 2：专项练习小结末尾的“本次答错的题”收题块。
///
/// - 系统确认答错的题默认全勾、可取消；未判分的题另列一行、可勾；
/// - 已在复习的题标“已在复习”并默认不勾（不可勾）；
/// - 一点“加入复习”批量进池：只建新卡，不把本次专项练习的错当作
///   正式 FSRS 历史事件；同一轮重复进小结不重复建卡（已在池的跳过）。
class _SummaryCollectSection extends ConsumerWidget {
  const _SummaryCollectSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(reviewProvider);
    final notifier = ref.read(reviewProvider.notifier);
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final wrongIds = st.sumWrongQuestionIds;
    final ungradedIds = st.sumUngradedQuestionIds;
    final hasAny = wrongIds.isNotEmpty || ungradedIds.isNotEmpty;
    final canCollect = st.sumCollectSelected.isNotEmpty;
    Widget row(String questionId, {required bool isWrong}) {
      final q = st.questionOf(questionId);
      final title = q?.title ?? questionId;
      final inPool = st.fsrsPoolIds.contains(questionId);
      final applied = st.sumCollectApplied.contains(questionId);
      final checked = st.sumCollectSelected.contains(questionId);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            key: ValueKey('summary-collect-$questionId'),
            value: checked,
            // 已在池的题默认不勾、不可勾；已加入的不用再勾。
            onChanged: (inPool || applied)
                ? null
                : (v) => notifier.toggleSummaryCollect(questionId, v == true),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: 12 * scale),
              child: Text(
                title,
                style: TextStyle(
                  fontSize: DesignTokens.bodySmallFontSize,
                  color: palette.ink,
                ),
              ),
            ),
          ),
          if (inPool)
            Padding(
              padding: EdgeInsets.only(top: 12 * scale),
              child: const Text(
                '已在复习',
                style: TextStyle(
                  fontSize: 12,
                  color: Color(0xFF0B7A55),
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          else if (applied)
            Padding(
              padding: EdgeInsets.only(top: 12 * scale),
              child: const Text(
                '已加入',
                style: TextStyle(
                  fontSize: 12,
                  color: Color(0xFF0B7A55),
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          else if (!isWrong)
            Padding(
              padding: EdgeInsets.only(top: 12 * scale),
              child: Text(
                '未判分',
                style: TextStyle(
                  fontSize: 12,
                  color: palette.muted,
                ),
              ),
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '本次答错的题',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        SizedBox(height: 4 * scale),
        if (!hasAny)
          Text(
            '本次没有答错或未判分的题。',
            style: TextStyle(
              fontSize: DesignTokens.bodySmallFontSize,
              color: palette.muted,
            ),
          )
        else ...[
          for (final id in wrongIds) row(id, isWrong: true),
          if (ungradedIds.isNotEmpty) ...[
            SizedBox(height: 8 * scale),
            Text(
              '未判分的题（可勾选加入）',
              style: TextStyle(
                fontSize: DesignTokens.bodySmallFontSize,
                fontWeight: FontWeight.w700,
                color: palette.muted,
              ),
            ),
            for (final id in ungradedIds) row(id, isWrong: false),
          ],
          SizedBox(height: 8 * scale),
          Text(
            '只建新卡，不把本次练习的错当作正式复习记录；下次正式复习才产生第一次 Again/Good。',
            style: TextStyle(
              fontSize: DesignTokens.captionFontSize,
              color: palette.muted,
            ),
          ),
          SizedBox(height: 8 * scale),
          QmButton(
            label: '加入复习',
            onPressed: canCollect
                ? () => notifier.collectSummaryWrong()
                : null,
          ),
          if (st.sumCollectMessage != null) ...[
            SizedBox(height: 6 * scale),
            Text(
              st.sumCollectMessage!,
              key: const Key('summary-collect-message'),
              style: TextStyle(
                fontSize: DesignTokens.bodySmallFontSize,
                color: palette.ink,
              ),
            ),
          ],
        ],
      ],
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
