import 'package:flutter/material.dart';

import '../../data/repository.dart';
import '../../models/models.dart';
import '../../widgets/widgets.dart';

/// 学习报告：只答三个问题——弱在哪、有没有效果、接下来练什么。
/// 无统计墙、无图表，纯数字与文字；打开即实时更新；无导出。
class ReportPage extends StatefulWidget {
  const ReportPage({
    super.key,
    required this.repo,
    required this.onGoReview,
    required this.onOpenWrongbookFiltered,
  });

  final QuestionRepository repo;
  final VoidCallback onGoReview;
  final void Function({String? cause, String? knowledgePointId})
      onOpenWrongbookFiltered;

  @override
  State<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<ReportPage> {
  String _range = 'week'; // week / month / all
  bool _loading = true;
  bool _expandCauses = false;
  bool _expandKps = false;

  List<CauseRecord> _records = [];
  List<Question> _questions = [];
  List<KnowledgePoint> _knowledgePoints = [];
  List<({String result, DateTime reviewedAt})> _history = [];

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

  Future<void> _load() async {
    final records = await widget.repo.causeRecords();
    final questions = await widget.repo.all(includeArchived: true);
    final kps = await widget.repo.knowledgePoints();
    final history = <({String result, DateTime reviewedAt})>[];
    for (final q in questions) {
      history.addAll(await widget.repo.reviewHistory(q.id));
    }
    if (!mounted) return;
    setState(() {
      _records = records;
      _questions = questions;
      _knowledgePoints = kps;
      _history = history;
      _loading = false;
    });
  }

  /// 弱点统计用的记录：本范围里加入的，或本范围里有自查的。
  bool _recordInRange(CauseRecord r) {
    if (_range == 'all') return true;
    if (_inRange(r.joinedAt)) return true;
    return r.lastCheck != null && _inRange(r.lastCheck!);
  }

  Question? _questionOf(String id) {
    for (final q in _questions) {
      if (q.id == id) return q;
    }
    return null;
  }

  String _kpName(String id) {
    for (final kp in _knowledgePoints) {
      if (kp.id == id) return kp.name;
    }
    return '待补充';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_records.isEmpty) {
      return Center(
        child: EmptyState(
          message: '还没有复习记录，先去复习吧',
          actionLabel: '去复习',
          onAction: widget.onGoReview,
        ),
      );
    }

    final inRangeRecords = _records.where(_recordInRange).toList();
    final solvedCount = _records
        .where((r) =>
            r.status == CauseStatus.solved &&
            (r.lastCheck == null || _inRange(r.lastCheck!)))
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

    // 弱点 Top 5：按错因，按关联题数排。
    final causeCounts = <String, Set<String>>{};
    for (final r in inRangeRecords) {
      (causeCounts[r.cause] ??= {}).add(r.questionId);
    }
    final causeTop = causeCounts.entries.toList()
      ..sort((a, b) {
        final c = b.value.length.compareTo(a.value.length);
        return c != 0 ? c : a.key.compareTo(b.key);
      });

    // 弱点 Top 5：按知识点，按关联题数排。
    final kpCounts = <String, Set<String>>{};
    for (final r in inRangeRecords) {
      final q = _questionOf(r.questionId);
      if (q == null) continue;
      for (final kpId in q.knowledgePointIds) {
        (kpCounts[kpId] ??= {}).add(q.id);
      }
    }
    final kpTop = kpCounts.entries.toList()
      ..sort((a, b) {
        final c = b.value.length.compareTo(a.value.length);
        return c != 0 ? c : _kpName(a.key).compareTo(_kpName(b.key));
      });

    // 分布只按学科：纯数字与文字。
    final subjectRows = <({String subjectId, int questions, int solved, int pending})>[];
    for (final s in Subject.all) {
      final rs =
          _records.where((r) => r.subjectId == s.id).toList();
      final qIds = {for (final r in rs) r.questionId};
      subjectRows.add((
        subjectId: s.id,
        questions: qIds.length,
        solved: rs.where((r) => r.status == CauseStatus.solved).length,
        pending: rs.where((r) => r.status != CauseStatus.solved).length,
      ));
    }

    final nextSentence = _nextSentence(causeTop);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('学习报告',
                  style: Theme.of(context).textTheme.headlineMedium),
              const Spacer(),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'week', label: Text('本周')),
                  ButtonSegment(value: 'month', label: Text('本月')),
                  ButtonSegment(value: 'all', label: Text('全部')),
                ],
                selected: {_range},
                onSelectionChanged: (v) => setState(() {
                  _range = v.first;
                  _expandCauses = false;
                  _expandKps = false;
                }),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _sectionTitle('核心数'),
          const SizedBox(height: 8),
          Text('已解决错因 $solvedCount 个',
              style: const TextStyle(fontSize: 15)),
          const SizedBox(height: 4),
          Text('待解决错因 $pendingCount 个',
              style: const TextStyle(fontSize: 15)),
          const SizedBox(height: 4),
          Text(
              '复查通过率 ${passRate == null ? '暂无复查记录' : '$passRate%'}',
              style: const TextStyle(fontSize: 15)),
          const SizedBox(height: 20),
          _sectionTitle('弱在哪'),
          const SizedBox(height: 8),
          _weakList(
            title: '最常错的5个原因',
            entries: causeTop,
            label: (e) => e.key,
            count: (e) => e.value.length,
            expanded: _expandCauses,
            onToggleExpand: () =>
                setState(() => _expandCauses = !_expandCauses),
            onTap: (e) =>
                widget.onOpenWrongbookFiltered(cause: e.key),
          ),
          const SizedBox(height: 16),
          _weakList(
            title: '最常错的5个知识点',
            entries: kpTop,
            label: (e) => _kpName(e.key),
            count: (e) => e.value.length,
            expanded: _expandKps,
            onToggleExpand: () =>
                setState(() => _expandKps = !_expandKps),
            onTap: (e) => widget.onOpenWrongbookFiltered(
                knowledgePointId: e.key),
          ),
          const SizedBox(height: 20),
          _sectionTitle('按学科分布'),
          const SizedBox(height: 8),
          for (final row in subjectRows)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  SubjectLabel(subjectId: row.subjectId),
                  const SizedBox(width: 12),
                  Text(
                      '${row.questions} 道题 · 已解决 ${row.solved} 个错因 · 待解决 ${row.pending} 个错因'),
                ],
              ),
            ),
          const SizedBox(height: 20),
          _sectionTitle('接下来练什么'),
          const SizedBox(height: 8),
          Text(nextSentence, style: const TextStyle(fontSize: 15)),
        ],
      ),
    );
  }

  String _nextSentence(List<MapEntry<String, Set<String>>> causeTop) {
    if (causeTop.isEmpty) return '先去复习，练完就有建议了。';
    final top = causeTop.first;
    // 该错因最多的学科。
    final bySubject = <String, int>{};
    for (final r in _records.where((r) => r.cause == top.key)) {
      bySubject[r.subjectId] = (bySubject[r.subjectId] ?? 0) + 1;
    }
    var subjectId = '';
    var max = 0;
    bySubject.forEach((k, v) {
      if (v > max) {
        max = v;
        subjectId = k;
      }
    });
    final subjectName =
        subjectId.isEmpty ? '' : '${Subject.byId(subjectId).name}的';
    return '先练「${top.key}」的题，$subjectName这类错最多，共 ${top.value.length} 道题。';
  }

  Widget _sectionTitle(String title) {
    return Text(title,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700));
  }

  Widget _weakList({
    required String title,
    required List<MapEntry<String, Set<String>>> entries,
    required String Function(MapEntry<String, Set<String>>) label,
    required int Function(MapEntry<String, Set<String>>) count,
    required bool expanded,
    required VoidCallback onToggleExpand,
    required void Function(MapEntry<String, Set<String>>) onTap,
  }) {
    final shown = expanded ? entries : entries.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        if (entries.isEmpty)
          Text('暂无',
              style: Theme.of(context).textTheme.bodySmall)
        else ...[
          for (final e in shown)
            InkWell(
              onTap: () => onTap(e),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(child: Text(label(e))),
                    Text('${count(e)} 道题',
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right, size: 16),
                  ],
                ),
              ),
            ),
          if (entries.length > 5)
            TextButton(
              onPressed: onToggleExpand,
              child: Text(expanded ? '收起' : '看更多'),
            ),
        ],
      ],
    );
  }
}
