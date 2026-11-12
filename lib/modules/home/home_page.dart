import 'package:flutter/material.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/widgets.dart';

/// 首页（C 焦点大卡片）。
///
/// 定稿口径：
/// - 页头问候语按时间段变化（早上好 / 下午好 / 晚上好），有未完成任务时
///   标题是“{问候}，继续{复习/整理/收集}你的错题”，副行是
///   “上次停在：{地点} · {学科}「{题名}」”（预览口径）。
/// - 焦点大卡片是浅蓝卡面（亮色 #E1EDFF、2px 强调色边；深色 #2C3949），
///   卡头“今日到期复习 · 点这张卡片直接开始”，大数字“{N} 道待复习”；
///   逾期题一并计入并标注“逾期 N 天”；整张卡片点击进入复习
///   （本期复习页未实现，点按弹 SnackBar 提示）。
/// - 卡片内“继续上次”按钮点按进整理工作台；按钮是独立的点按目标，
///   不触发整张卡片的 onTap（内层按钮赢得手势竞争，见 _buildFocusCard）。
/// - “继续上次”= 最近一次未完成的任务，优先级 复习 > 整理 > 收集。
///   演示数据用写死的最近任务（整理工作台 · 数学“函数极限”），
///   未造假数据层；没有可继续任务时大卡片只显示今日到期。
/// - “快速收集”只有一个文件导入入口（按钮“去收集中心”），
///   无手机照片按钮，无手动录入。
/// - 各学科待复习概览按数学 / 英语 / 政治固定顺序，每科只显示
///   今日到期 / 复习中 / 已掌握三个数，不显示总题数；
///   点某学科行进错题本对应学科。
/// - 无顶部全局搜索、无底部状态栏、无待整理提醒、无最近打开列表、
///   无今日进度、无明日预告、无首次引导、无键盘快捷键。
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.repo,
    required this.onGoCollect,
    required this.onGoOrganize,
    required this.onGoWrongbook,
  });

  final QuestionRepository repo;
  final VoidCallback onGoCollect;
  final VoidCallback onGoOrganize;
  final void Function(String subjectId) onGoWrongbook;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomeData {
  const _HomeData({required this.due, required this.counts, this.lastTask});
  final List<Question> due;
  final Map<String, (int due, int inReview, int mastered)> counts;

  /// 最近一次未完成的任务（D-01 已确认：读 recent_tasks 表）。
  final ({String kind, String subjectId, String title})? lastTask;
}

/// 最近任务：复习 / 整理 / 收集，优先级 复习 > 整理 > 收集；
///
/// 演示数据用 recent_tasks 表里的种子——整理工作台 · 数学“函数极限”。
/// 为 null 时大卡片只显示今日到期（无“继续上次”区）。

class _HomePageState extends State<HomePage> {
  late Future<_HomeData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_HomeData> _load() async {
    final due = await widget.repo.dueToday();
    final counts = await widget.repo.subjectCounts();
    final lastTask = await widget.repo.recentTask();
    final demoCount = await widget.repo.demoQuestionCount();
    _demoCount = demoCount;
    return _HomeData(due: due, counts: counts, lastTask: lastTask);
  }

  // D-11：演示题数量（>0 时首页底部显示“清空演示数据”）。
  int _demoCount = 0;

  /// 问候语按时间段变化：5–11 点早上好，12–17 点下午好，其余晚上好。
  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour >= 5 && hour < 12) return '早上好';
    if (hour >= 12 && hour < 18) return '下午好';
    return '晚上好';
  }

  /// 最近任务的发生地点：复习 / 整理工作台 / 收集中心。
  String _taskPlace(String kind) => switch (kind) {
        '复习' => '复习',
        '收集' => '收集中心',
        _ => '整理工作台',
      };

  /// 页头标题：有未完成任务时“{问候}，继续{任务}你的错题”，
  /// 如“下午好，继续整理你的错题”；没有时只显示问候语。
  String _greetingTitle(_HomeData data) {
    final greet = _greeting();
    final last = data.lastTask;
    if (last == null) return greet;
    return '$greet，继续${last.kind}你的错题';
  }

  void _onFocusCardTap() {
    // 本期复习页未实现：整卡点按只提示，不跳转。
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('复习模块尚未实现')),
    );
  }

  void _onContinueLastTap(_HomeData data) {
    // 演示最近任务是整理任务；按优先级，复习任务在前时应先进复习。
    switch (data.lastTask?.kind) {
      case '复习':
        _onFocusCardTap();
      case '收集':
        widget.onGoCollect();
      case '整理':
      default:
        widget.onGoOrganize();
    }
  }

  Future<void> _clearDemoData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空演示数据'),
        content: Text('将删除 $_demoCount 道演示题，真实导入的题不受影响。确定吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final n = await widget.repo.clearDemoData();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已清空 $n 道演示题')),
    );
    setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_HomeData>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('加载失败，请重试'),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => setState(() => _future = _load()),
                  child: const Text('重试'),
                ),
              ],
            ),
          );
        }
        final data = snapshot.data!;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 页头问候语（预览口径）+ 副行“上次停在：…”。
              Text(_greetingTitle(data),
                  style: const TextStyle(
                      fontSize: 24, fontWeight: FontWeight.w700)),
              if (data.lastTask != null) ...[
                const SizedBox(height: 4),
                Text(
                  '上次停在：${_taskPlace(data.lastTask!.kind)} · '
                  '${Subject.byId(data.lastTask!.subjectId).name} '
                  '「${data.lastTask!.title}」',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 16),
              _buildFocusCard(data),
              const SizedBox(height: 16),
              _buildQuickCollect(),
              const SizedBox(height: 16),
              _buildSubjectOverview(data.counts),
              if (_demoCount > 0) ...[
                const SizedBox(height: 16),
                Center(
                  child: TextButton(
                    onPressed: _clearDemoData,
                    child: Text('清空演示数据（$_demoCount 道）'),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// C 焦点大卡片：浅蓝卡面（亮色 #E1EDFF、2px 强调色边；深色 #2C3949），
  /// 整卡点按进复习（未实现，弹 SnackBar）；
  /// 卡片内的“继续上次”按钮是独立的 FilledButton，
  /// 其点按只触发自身 onPressed，不触发外层卡片的 onTap。
  /// 今日无到期时用默认卡面 + 小伙伴空状态（预览 .no-due）。
  Widget _buildFocusCard(_HomeData data) {
    final due = data.due;
    final overdue = due.where((q) => q.overdueDays > 0).toList();
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Card(
      color: due.isEmpty
          ? null
          : (dark ? AppTheme.darkFocusCard : AppTheme.lightFocusCard),
      shape: due.isEmpty
          ? null
          : RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radius),
              side: BorderSide(
                  color:
                      dark ? AppTheme.darkNavSelected : AppTheme.accent,
                  width: 2),
            ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        onTap: _onFocusCardTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (due.isEmpty) ...[
                // 空状态：今日没有到期复习。
                const Center(
                  child: CompanionWidget(
                    message: '今天没有到期复习，明天再来吧',
                  ),
                ),
              ] else ...[
                // 今日到期 + 小伙伴：小伙伴只在焦点大卡片里出现一次（预览口径）。
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('今日到期复习 · 点这张卡片直接开始',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: dark
                                      ? AppTheme.darkAccentText
                                      : AppTheme.accentText)),
                          const SizedBox(height: 4),
                          Text(
                            '${due.length} 道待复习',
                            style: const TextStyle(
                                fontSize: 46, fontWeight: FontWeight.w800),
                          ),
                          if (overdue.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              '其中逾期 ${overdue.length} 道',
                              style: TextStyle(
                                color:
                                    Theme.of(context).colorScheme.error,
                              ),
                            ),
                            const SizedBox(height: 4),
                            for (final q in overdue)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  // nextReviewLabel 如“逾期 8 天”。
                                  '${q.nextReviewLabel} · ${q.title}',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall,
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    const CompanionWidget(size: 72),
                  ],
                ),
              ],
              if (data.lastTask != null) ...[
                const SizedBox(height: 20),
                const Divider(height: 1),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '继续上次：${_taskPlace(data.lastTask!.kind)} · '
                            '${Subject.byId(data.lastTask!.subjectId).name} '
                            '「${data.lastTask!.title}」',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '点「继续上次」回到那道题，不会触发整卡的开始复习',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    // 内层按钮：点按只进整理工作台，不触发整卡 onTap。
                    FilledButton(
                      onPressed: () => _onContinueLastTap(data),
                      child: const Text('继续上次'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 快速收集：只文件导入一个入口，无手机照片按钮，无手动录入。
  Widget _buildQuickCollect() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('快速收集',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        const Text('把试卷或作业导入进来，框出题目就能收集。'),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: widget.onGoCollect,
          child: const Text('去收集中心'),
        ),
      ],
    );
  }

  /// 各学科待复习概览：数学 / 英语 / 政治固定顺序，
  /// 每科只显示 今日到期 / 复习中 / 已掌握，不显示总题数。
  /// 点某学科行进错题本对应学科。
  Widget _buildSubjectOverview(
    Map<String, (int due, int inReview, int mastered)> counts,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('各学科待复习',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              for (var i = 0; i < Subject.all.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _buildSubjectRow(
                  Subject.all[i],
                  counts[Subject.all[i].id] ?? (0, 0, 0),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSubjectRow(
    Subject subject,
    (int due, int inReview, int mastered) c,
  ) {
    return InkWell(
      onTap: () => widget.onGoWrongbook(subject.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            SubjectLabel(subjectId: subject.id),
            const SizedBox(width: 16),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _countCell('今日到期', c.$1),
                  _countCell('复习中', c.$2),
                  _countCell('已掌握', c.$3),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _countCell(String label, int value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$value',
            style:
                const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
