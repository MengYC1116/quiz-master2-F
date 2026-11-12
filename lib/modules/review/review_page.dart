import 'package:flutter/material.dart';

import '../../data/repository.dart';
import '../../models/models.dart';
import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';

/// 复习页：错因治疗模型。
/// 列表一题一行（多错因的题只出现一次，题内错因按顺序一起解决），
/// 按加入时间排（默认，可按学科排），无外框、整页滚动、分页。
/// 点“开始解决”进全屏会话：一题四步（看错因 → 写补救 → 重做 → 自查），
/// 跑完才回列表；暂停存断点，下次续接。
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

class _ReviewGroup {
  _ReviewGroup({required this.question, required this.records});

  final Question question;
  final List<CauseRecord> records;

  DateTime get joinedAt => records
      .map((r) => r.joinedAt)
      .reduce((a, b) => a.isBefore(b) ? a : b);

  /// 本轮要治的错因：没解决的，或已解决但到了复查时间。
  List<CauseRecord> get pending => records
      .where((r) => r.status != CauseStatus.solved || r.isRecheckDue)
      .toList();

  bool get hasRecheck => records.any((r) => r.isRecheckDue);
}

class _SessionItem {
  _SessionItem({required this.questionId, required this.cause});

  final String questionId;
  final String cause;

  String get key => '$questionId|$cause';
}

class _Change {
  _Change({
    required this.questionTitle,
    required this.cause,
    required this.before,
    required this.after,
    this.recheckDate,
  });

  final String questionTitle;
  final String cause;
  final String before;
  final String after;
  final DateTime? recheckDate;
}

const _stepLabels = ['看错因', '写补救', '重做', '自查'];

class _ReviewPageState extends State<ReviewPage> {
  AppSettings _settings = AppSettings.defaults;
  List<_ReviewGroup> _groups = [];
  bool _loading = true;

  String? _subjectFilter;
  String _causeFilter = '全部';
  String _sort = 'joinTime';
  int _page = 1;

  // ---- 会话状态 ----
  bool _inSession = false;
  bool _showSummary = false;
  List<_SessionItem> _queue = [];
  int _pos = 0;
  int _step = 0;
  final _remedyController = TextEditingController();
  bool _answerShown = false;
  final Map<String, int> _skips = {};
  int _treatedCount = 0;
  final List<_Change> _changes = [];
  int _summaryRemaining = 0;

  @override
  void initState() {
    super.initState();
    _subjectFilter = widget.initialSubjectId;
    _load();
  }

  @override
  void dispose() {
    _remedyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final settings = await widget.repo.settings();
    final questions = await widget.repo.all(includeArchived: true);
    final records = await widget.repo.causeRecords();
    final byQ = <String, List<CauseRecord>>{};
    for (final r in records) {
      (byQ[r.questionId] ??= []).add(r);
    }
    final groups = <_ReviewGroup>[];
    for (final q in questions) {
      if (!q.reviewJoined || !q.isOrganized) continue;
      final rs = byQ[q.id];
      if (rs == null || rs.isEmpty) continue;
      // 题内错因按题目本身的错因顺序排。
      final order = q.allCauses;
      final sorted = [...rs]
        ..sort((a, b) =>
            order.indexOf(a.cause).compareTo(order.indexOf(b.cause)));
      groups.add(_ReviewGroup(question: q, records: sorted));
    }
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _groups = groups;
      _sort = settings.reviewSort;
      _loading = false;
    });
  }

  List<_ReviewGroup> get _filtered {
    var list = _groups;
    if (_subjectFilter != null) {
      list = list.where((g) => g.question.subjectId == _subjectFilter).toList();
    }
    if (_causeFilter != '全部') {
      list = list
          .where((g) => g.records.any((r) => r.cause == _causeFilter))
          .toList();
    }
    list = [...list];
    if (_sort == 'subject') {
      final order = {for (var i = 0; i < Subject.all.length; i++) Subject.all[i].id: i};
      list.sort((a, b) {
        final c = (order[a.question.subjectId] ?? 99)
            .compareTo(order[b.question.subjectId] ?? 99);
        return c != 0 ? c : a.joinedAt.compareTo(b.joinedAt);
      });
    } else {
      list.sort((a, b) => a.joinedAt.compareTo(b.joinedAt));
    }
    return list;
  }

  int get _pageSize => _settings.pageSize;

  int get _totalPages {
    final n = (_filtered.length / _pageSize).ceil();
    return n < 1 ? 1 : n;
  }

  List<_ReviewGroup> get _pageGroups {
    final list = _filtered;
    final page = _page.clamp(1, _totalPages);
    final start = (page - 1) * _pageSize;
    final end = (start + _pageSize).clamp(0, list.length);
    if (start >= list.length) return const [];
    return list.sublist(start, end);
  }

  void _resetPage() => _page = 1;

  List<String> get _allCauses {
    final set = <String>{};
    for (final g in _groups) {
      for (final r in g.records) {
        set.add(r.cause);
      }
    }
    final fixed = ErrorTypes.fixed.where(set.contains).toList();
    final rest = set.where((c) => !ErrorTypes.fixed.contains(c)).toList()
      ..sort();
    return [...fixed, ...rest];
  }

  List<String> get _orderIds => _filtered.map((g) => g.question.id).toList();

  // ---------- 会话 ----------

  List<_SessionItem> _buildQueue(List<_ReviewGroup> groups) {
    final queue = <_SessionItem>[];
    for (final g in groups) {
      for (final r in g.pending) {
        queue.add(_SessionItem(questionId: g.question.id, cause: r.cause));
      }
    }
    return queue;
  }

  Future<void> _startSession({_ReviewGroup? fromGroup}) async {
    final groups = fromGroup == null
        ? _filtered
        : _filtered.skipWhile((g) => g.question.id != fromGroup.question.id).toList();
    var queue = _buildQueue(groups);
    var pos = 0;
    if (fromGroup == null) {
      // 有断点就续接。
      final state = await widget.repo.reviewState();
      if (state != null) {
        final valid = <String>{
          for (final g in _groups)
            for (final r in g.pending) '${g.question.id}|${r.cause}',
        };
        final saved = state.queue.where(valid.contains).toList();
        if (saved.isNotEmpty) {
          queue = saved
              .map((s) {
                final parts = s.split('|');
                return _SessionItem(questionId: parts[0], cause: parts[1]);
              })
              .toList();
          pos = state.position.clamp(0, queue.length - 1);
        }
      }
    }
    if (queue.isEmpty) return;
    setState(() {
      _queue = queue;
      _pos = pos;
      _step = 0;
      _skips.clear();
      _treatedCount = 0;
      _changes.clear();
      _answerShown = !_settings.redoAnswerHidden;
      _remedyController.clear();
      _inSession = true;
      _showSummary = false;
    });
  }

  _SessionItem get _currentItem => _queue[_pos];

  _ReviewGroup? _groupOf(String questionId) {
    for (final g in _groups) {
      if (g.question.id == questionId) return g;
    }
    return null;
  }

  CauseRecord? _recordOf(_SessionItem item) {
    final g = _groupOf(item.questionId);
    if (g == null) return null;
    for (final r in g.records) {
      if (r.cause == item.cause) return r;
    }
    return null;
  }

  void _beginCause() {
    _remedyController.clear();
    _answerShown = !_settings.redoAnswerHidden;
    _step = 0;
  }

  void _advance() {
    _pos++;
    if (_settings.causesPerSession > 0 &&
        _treatedCount >= _settings.causesPerSession) {
      _finishSession();
      return;
    }
    if (_pos >= _queue.length) {
      _finishSession();
      return;
    }
    setState(_beginCause);
  }

  Future<void> _finishSession() async {
    await widget.repo.clearReviewState();
    // 剩余数：列表里还没解决的错因（含到复查时间的）。
    final records = await widget.repo.causeRecords();
    final questions = await widget.repo.all(includeArchived: true);
    final joinedIds = {
      for (final q in questions)
        if (q.reviewJoined && q.isOrganized) q.id,
    };
    final remaining = records
        .where((r) =>
            joinedIds.contains(r.questionId) &&
            (r.status != CauseStatus.solved || r.isRecheckDue))
        .length;
    if (!mounted) return;
    setState(() {
      _summaryRemaining = remaining;
      _showSummary = true;
    });
    await _load();
  }

  Future<void> _pauseSession() async {
    await widget.repo.saveReviewState(
      queue: _queue.map((e) => e.key).toList(),
      position: _pos,
    );
    if (!mounted) return;
    setState(() => _inSession = false);
    await _load();
  }

  Future<void> _backToList() async {
    await widget.repo.clearReviewState();
    if (!mounted) return;
    setState(() {
      _inSession = false;
      _showSummary = false;
    });
    await _load();
  }

  void _skipCurrent() {
    final key = _currentItem.key;
    final count = (_skips[key] ?? 0) + 1;
    _skips[key] = count;
    setState(() {
      if (count >= _settings.skipLimit) {
        // 第二次跳过：留到下次，从本轮队列里拿掉。
        _queue.removeAt(_pos);
      } else {
        // 第一次跳过：移到队尾。
        final item = _queue.removeAt(_pos);
        _queue.add(item);
      }
      _beginCause();
    });
    if (_queue.isEmpty || _pos >= _queue.length) {
      _finishSession();
    }
  }

  Future<void> _submitSelfCheck(String result) async {
    final item = _currentItem;
    final record = _recordOf(item);
    if (record == null) {
      _advance();
      return;
    }
    if (result == 'unsure') {
      // 不确定不算，下次重做：不记分，直接进下一个。
      _advance();
      return;
    }
    final before = record.status.label;
    final updated = await widget.repo.recordSelfCheck(
      record,
      result,
      cureChecks: _settings.cureChecks,
      recheckIntervalDays: _settings.recheckIntervalDays,
    );
    final group = _groupOf(item.questionId);
    _changes.add(_Change(
      questionTitle: group?.question.title ?? '',
      cause: item.cause,
      before: before,
      after: updated.status.label,
      recheckDate:
          updated.status == CauseStatus.solved ? updated.recheckDate : null,
    ));
    _treatedCount++;
    await _load();
    if (!mounted) return;
    _advance();
  }

  Future<void> _nextFromRemedy() async {
    final item = _currentItem;
    final record = _recordOf(item);
    if (record != null && _remedyController.text.trim().isNotEmpty) {
      await widget.repo.saveRemedy(record, _remedyController.text);
    }
    if (!mounted) return;
    setState(() => _step = 2);
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_inSession) {
      return _showSummary ? _buildSummary() : _buildSession();
    }
    return _buildList();
  }

  Widget _buildList() {
    final groups = _pageGroups;
    final totalPending =
        _groups.fold<int>(0, (sum, g) => sum + g.pending.length);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('复习',
                  style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(width: 12),
              Text('待解决 $totalPending 个错因',
                  style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
              FilledButton(
                onPressed: totalPending == 0
                    ? null
                    : () => _startSession(),
                child: const Text('开始解决'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 筛选行
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('学科'),
              for (final s in [null, ...Subject.all])
                ChoiceChip(
                  label: Text(s == null ? '全部' : s.name),
                  selected: _subjectFilter == s?.id,
                  onSelected: (_) => setState(() {
                    _subjectFilter = s?.id;
                    _resetPage();
                  }),
                ),
              const SizedBox(width: 8),
              const Text('错因'),
              DropdownButton<String>(
                value: _causeFilter,
                items: [
                  const DropdownMenuItem(value: '全部', child: Text('全部')),
                  for (final c in _allCauses)
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: (v) => setState(() {
                  _causeFilter = v ?? '全部';
                  _resetPage();
                }),
              ),
              const SizedBox(width: 8),
              const Text('排序'),
              DropdownButton<String>(
                value: _sort,
                items: const [
                  DropdownMenuItem(
                      value: 'joinTime', child: Text('按加入时间')),
                  DropdownMenuItem(value: 'subject', child: Text('按学科')),
                ],
                onChanged: (v) => setState(() {
                  _sort = v ?? 'joinTime';
                  _resetPage();
                }),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_groups.isEmpty)
            SizedBox(
              height: 360,
              child: EmptyState(
                message: '还没有加入复习的题，先去题目详情加入吧',
                actionLabel: '去错题本',
                onAction: widget.onGoWrongbook,
              ),
            )
          else if (groups.isEmpty)
            const SizedBox(
              height: 360,
              child: EmptyState(message: '没有符合条件的题'),
            )
          else ...[
            for (var i = 0; i < groups.length; i++) ...[
              _buildGroupRow(groups[i]),
              if (i != groups.length - 1)
                DashedDivider(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? AppTheme.darkPaperLine
                      : AppTheme.lightPaperLine,
                ),
            ],
            const SizedBox(height: 16),
            _buildPagination(),
          ],
        ],
      ),
    );
  }

  Widget _buildGroupRow(_ReviewGroup g) {
    final q = g.question;
    return InkWell(
      onTap: () => widget.onOpenDetail(q, _orderIds),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CompactSliceThumb(question: q),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(q.title,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700)),
                      ),
                      if (g.hasRecheck)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text('复查',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.accentText,
                                  fontWeight: FontWeight.w700)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SubjectLabel(subjectId: q.subjectId),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final r in g.records)
                        InfoChip(
                          label:
                              '${r.cause} · ${r.status.label}${r.status == CauseStatus.inProgress && r.solvedCount > 0 ? ' ${r.solvedCount}/${_settings.cureChecks}' : ''}',
                          color: r.status == CauseStatus.solved
                              ? const Color(0xFF1F9D66)
                              : null,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (g.pending.isNotEmpty)
              OutlinedButton(
                onPressed: () => _startSession(fromGroup: g),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.accent,
                  side: const BorderSide(color: AppTheme.accent),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('开始解决'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPagination() {
    return Row(
      children: [
        const Text('每页'),
        const SizedBox(width: 6),
        DropdownButton<int>(
          value: _pageSize,
          items: const [10, 20, 30, 40, 50]
              .map((n) =>
                  DropdownMenuItem(value: n, child: Text('$n')))
              .toList(),
          onChanged: (v) async {
            if (v == null) return;
            final s = _settings.copyWith(pageSize: v);
            await widget.repo.saveSettings(s);
            setState(() {
              _settings = s;
              _resetPage();
            });
          },
        ),
        const Spacer(),
        TextButton(
          onPressed: _page > 1 ? () => setState(() => _page--) : null,
          child: const Text('上一页'),
        ),
        Text('第 $_page / $_totalPages 页'),
        TextButton(
          onPressed: _page < _totalPages ? () => setState(() => _page++) : null,
          child: const Text('下一页'),
        ),
      ],
    );
  }

  // ---------- 会话 ----------

  Widget _buildSession() {
    if (_queue.isEmpty) return _buildSummary();
    final item = _currentItem;
    final group = _groupOf(item.questionId);
    final record = _recordOf(item);
    if (group == null || record == null) {
      return _buildSummary();
    }
    final q = group.question;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('复习中 · 第 ${_pos + 1} / ${_queue.length} 个错因',
                  style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              OutlinedButton(
                onPressed: _pauseSession,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.accent,
                  side: const BorderSide(color: AppTheme.accent),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('暂停'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildStepIndicator(),
          const SizedBox(height: 16),
          Text(q.title,
              style:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Row(
            children: [
              SubjectLabel(subjectId: q.subjectId),
              const SizedBox(width: 12),
              InfoChip(label: '错因：${record.cause}'),
              const SizedBox(width: 8),
              InfoChip(label: record.status.label),
              if (record.isRecheckDue) ...[
                const SizedBox(width: 8),
                const InfoChip(label: '复查'),
              ],
            ],
          ),
          const SizedBox(height: 12),
          if (_step == 0) _buildStepCause(q, record),
          if (_step == 1) _buildStepRemedy(record),
          if (_step == 2) _buildStepRedo(q),
          if (_step == 3) _buildStepCheck(record),
        ],
      ),
    );
  }

  Widget _buildStepIndicator() {
    return Row(
      children: [
        for (var i = 0; i < _stepLabels.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: i == _step
                        ? AppTheme.accent
                        : (i < _step
                            ? AppTheme.accent.withValues(alpha: 0.25)
                            : Theme.of(context).colorScheme.surface),
                    border: Border.all(
                        color: i == _step
                            ? AppTheme.accent
                            : AppTheme.lightLine),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${i + 1} · ${_stepLabels[i]}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight:
                          i == _step ? FontWeight.w700 : FontWeight.normal,
                      color: i == _step
                          ? Colors.white
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSessionActions(
      {required String primaryLabel,
      required VoidCallback onPrimary,
      String? secondaryLabel,
      VoidCallback? onSecondary}) {
    return Row(
      children: [
        FilledButton(onPressed: onPrimary, child: Text(primaryLabel)),
        if (secondaryLabel != null) ...[
          const SizedBox(width: 12),
          OutlinedButton(
            onPressed: onSecondary,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.accent,
              side: const BorderSide(color: AppTheme.accent),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(secondaryLabel),
          ),
        ],
      ],
    );
  }

  Widget _buildStepCause(Question q, CauseRecord record) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        QuestionSlice(question: q, maxHeight: 220),
        const SizedBox(height: 12),
        Text('这次错在：${record.cause}',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        if (record.remedyHistory.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('上次写的补救：${record.remedyHistory.first}',
              style: Theme.of(context).textTheme.bodySmall),
        ],
        if (record.solvedCount > 0) ...[
          const SizedBox(height: 8),
          Text('已经自查“已解决” ${record.solvedCount} 次，还差 ${_settings.cureChecks - record.solvedCount} 次',
              style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: 12),
        TextButton(
          onPressed: () async {
            await widget.onOpenDetail(q, _orderIds);
            await _load();
          },
          child: const Text('查看题目详情'),
        ),
        const SizedBox(height: 12),
        _buildSessionActions(
          primaryLabel: '下一步：写补救',
          onPrimary: () => setState(() => _step = 1),
          secondaryLabel: '跳过该题',
          onSecondary: _skipCurrent,
        ),
      ],
    );
  }

  Widget _buildStepRemedy(CauseRecord record) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('错因：${record.cause}',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        const Text('写一句自己的补救，下次复习还能看到。'),
        const SizedBox(height: 8),
        TextField(
          controller: _remedyController,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: '比如：先看清题目问的是什么，再动手算',
            border: OutlineInputBorder(),
          ),
        ),
        if (record.remedyHistory.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('以前写过的补救',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          for (final h in record.remedyHistory)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('· $h',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
        const SizedBox(height: 16),
        _buildSessionActions(
          primaryLabel: '下一步：重做',
          onPrimary: _nextFromRemedy,
          secondaryLabel: '跳过',
          onSecondary: _skipCurrent,
        ),
      ],
    );
  }

  Widget _buildStepRedo(Question q) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        QuestionSlice(question: q, maxHeight: 220),
        const SizedBox(height: 12),
        if (_answerShown) ...[
          Text('答案：${q.answer ?? '待补充'}',
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          if (q.explanation != null && q.explanation!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(q.explanation!),
          ],
        ] else ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border.all(color: AppTheme.lightLine),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text('答案藏着，先自己做一遍，再对照。'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => setState(() => _answerShown = true),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.accent,
              side: const BorderSide(color: AppTheme.accent),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('看答案'),
          ),
        ],
        const SizedBox(height: 16),
        _buildSessionActions(
          primaryLabel: '下一步：自查',
          onPrimary: () => setState(() => _step = 3),
        ),
      ],
    );
  }

  Widget _buildStepCheck(CauseRecord record) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('错因：${record.cause}',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        const Text('这次做对了吗？错因还在不在？按实际情况选。'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          children: [
            FilledButton(
              onPressed: () => _submitSelfCheck('solved'),
              child: const Text('已解决'),
            ),
            OutlinedButton(
              onPressed: () => _submitSelfCheck('unsolved'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.accent,
                side: const BorderSide(color: AppTheme.accent),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('未解决'),
            ),
            OutlinedButton(
              onPressed: () => _submitSelfCheck('unsure'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.accent,
                side: const BorderSide(color: AppTheme.accent),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('不确定'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('选“不确定”不算数，下次还要重做这道题。',
            style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _buildSummary() {
    final solvedThisRound =
        _changes.where((c) => c.after == '已解决').length;
    DateTime? nextRecheck;
    for (final c in _changes) {
      if (c.recheckDate != null) {
        nextRecheck = nextRecheck == null || c.recheckDate!.isBefore(nextRecheck)
            ? c.recheckDate
            : nextRecheck;
      }
    }
    String fmt(DateTime d) => '${d.year}-${d.month}-${d.day}';
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const CompanionWidget(size: 56),
              const SizedBox(width: 12),
              Text('本轮复习总结',
                  style: Theme.of(context).textTheme.headlineMedium),
            ],
          ),
          const SizedBox(height: 16),
          Text('本轮解决 $solvedThisRound 个错因，还剩 $_summaryRemaining 个错因待解决。',
              style: const TextStyle(fontSize: 15)),
          if (nextRecheck != null) ...[
            const SizedBox(height: 8),
            Text('下次复查：${fmt(nextRecheck)}',
                style: Theme.of(context).textTheme.bodyMedium),
          ],
          const SizedBox(height: 16),
          const Text('每错因状态变化',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (_changes.isEmpty)
            const Text('本轮没有完成自查的错因。')
          else
            for (final c in _changes)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                    '· ${c.questionTitle} · ${c.cause}：${c.before} → ${c.after}'),
              ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _backToList,
            child: const Text('回列表'),
          ),
        ],
      ),
    );
  }
}
