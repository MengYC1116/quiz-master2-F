import 'package:flutter/material.dart';

import '../../data/repository.dart';
import '../../models/models.dart';
import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';

/// 首页：问候 + 焦点大卡片（要复习的数量）+ 继续上次 + 快速收集 +
/// 各学科三数（要复习 / 待复查 / 已解决），学科顺序固定数学 / 英语 / 政治。
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.repo,
    required this.settings,
    required this.onGoCollect,
    required this.onGoOrganize,
    required this.onGoWrongbook,
    required this.onGoReview,
  });

  final QuestionRepository repo;
  final AppSettings settings;
  final VoidCallback onGoCollect;
  final VoidCallback onGoOrganize;
  final void Function(String subjectId) onGoWrongbook;
  final VoidCallback onGoReview;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Map<String, int>? _revCounts;
  Map<String, (int toReview, int toRecheck, int solved)>? _subjectCounts;
  ({String kind, String subjectId, String title})? _recent;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rev = await widget.repo.homeRevCounts();
    final counts = await widget.repo.subjectCounts();
    final recent = await widget.repo.recentTask();
    if (!mounted) return;
    setState(() {
      _revCounts = rev;
      _subjectCounts = counts;
      _recent = recent;
      _loading = false;
    });
  }

  int get _totalDue =>
      (_revCounts?.values ?? const <int>[]).fold(0, (a, b) => a + b);

  void _resumeRecent() {
    switch (_recent?.kind) {
      case 'organize':
        widget.onGoOrganize();
      case 'collect':
        widget.onGoCollect();
      case 'review':
      default:
        widget.onGoReview();
    }
  }

  String _recentKindLabel(String kind) => switch (kind) {
        'organize' => '整理',
        'collect' => '收集',
        _ => '复习',
      };

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final focusColor =
        dark ? AppTheme.darkFocusCard : AppTheme.lightFocusCard;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.settings.greeting,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 20),
            // 焦点大卡片：要复习的数量，点卡片进复习页。
            InkWell(
              onTap: widget.onGoReview,
              borderRadius: BorderRadius.circular(AppTheme.radius),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: focusColor,
                  borderRadius: BorderRadius.circular(AppTheme.radius),
                ),
                child: _loading
                    ? const SizedBox(
                        height: 96,
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : _totalDue == 0
                        ? Column(
                            children: [
                              const CompanionWidget(size: 64),
                              const SizedBox(height: 12),
                              Text(
                                '今天没有到期复习，明天再来吧',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('要复习', style: TextStyle(fontSize: 15)),
                              const SizedBox(height: 4),
                              Text(
                                '$_totalDue 道',
                                style: const TextStyle(
                                  fontSize: 40,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text('点卡片去复习',
                                  style: TextStyle(fontSize: 13)),
                            ],
                          ),
              ),
            ),
            const SizedBox(height: 16),
            // 继续上次：复习 > 整理 > 收集，按最近任务走。
            if (_recent != null)
              Card(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      const CompanionWidget(size: 44),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '继续上次 · ${_recentKindLabel(_recent!.kind)}',
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _recent!.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      FilledButton(
                        onPressed: _resumeRecent,
                        child: const Text('继续'),
                      ),
                    ],
                  ),
                ),
              ),
            if (_recent != null) const SizedBox(height: 16),
            // 快速收集。
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('快速收集',
                              style: TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w700)),
                          SizedBox(height: 4),
                          Text('支持 PDF、JPG、PNG；PDF 50MB，图片 20MB。',
                              style: TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                    FilledButton(
                      onPressed: widget.onGoCollect,
                      child: const Text('去收集'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text('各学科',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            // 各学科行：只显示三数，不显示总题数。
            for (final s in Subject.all)
              Card(
                child: InkWell(
                  onTap: () => widget.onGoWrongbook(s.id),
                  borderRadius: BorderRadius.circular(AppTheme.radius),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    child: Row(
                      children: [
                        CircleAvatar(
                          backgroundColor:
                              subjectLabelColor(context, s.id),
                          child: Text(s.icon,
                              style: const TextStyle(color: Colors.white)),
                        ),
                        const SizedBox(width: 12),
                        Text(s.name,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700)),
                        const Spacer(),
                        _countCell(
                            context, '要复习', (_subjectCounts?[s.id] ?? (0, 0, 0)).$1),
                        const SizedBox(width: 20),
                        _countCell(
                            context, '待复查', (_subjectCounts?[s.id] ?? (0, 0, 0)).$2),
                        const SizedBox(width: 20),
                        _countCell(
                            context, '已解决', (_subjectCounts?[s.id] ?? (0, 0, 0)).$3),
                        const SizedBox(width: 8),
                        const Icon(Icons.chevron_right, size: 18),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _countCell(BuildContext context, String label, int value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('$value',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
