// 复习页：错因治疗模型（R8 按 HTML 交互原型重建）。
//
// 列表：按学科 × 错因分组，每组一行（错因状态 待解决/解决中/已解决 +
// 复查标记），按加入时间排（默认，可在设置里改按学科），按学科和错因
// 筛选；已治愈错因仍显示（点开看解决记录）；列表无外层卡片框、无固定
// 高度内滚容器（整页滚动）；分页默认 10（10/20/30/40/50 可选），
// 筛选变化回第 1 页。
// 会话：点“开始解决”进全屏四步（①看错因 → ②写补救 → ③重做 →
// ④自查），①② 按错因逐个走，③④ 按题走（一题的全部错因同屏自查）；
// 同一错因同一题自查“已解决”满 2 次（设置可改）算已解决；跳过按
// “题 × 错因”计次，第 1 次追加到队尾，第 2 次留到下次；暂停存断点，
// 列表顶部出“上次解决到一半”恢复条（继续解决 / 从头开始）；结束出
// 总结页，总结后回复习列表。
// 业务口径沿用基线（repository.recordSelfCheck / saveRemedy /
// reviewState；不改 Schema、不改状态机）；旧翻卡模型不复活，
// 不出现 1/3/7/14 天旧复习状态。
import 'package:flutter/material.dart';

import '../../data/repository.dart';
import '../../models/models.dart';
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
    this.onSettingsChanged,
  });

  final QuestionRepository repo;
  final Future<void> Function(Question q, List<String> orderIds) onOpenDetail;
  final String? initialSubjectId;
  final VoidCallback onGoWrongbook;

  /// 设置单 owner（P0B1-4）的遗留参数：P0B2 起复习页“每页”下拉改成
  /// 本地行为（见 _buildPager），不再经由此回调改设置，也不再写库；
  /// 参数保留只为兼容既有调用点（app / 测试仍传 `_updateSettings`），
  /// 当前页内已无使用。后续清理可连同 app.dart 的传入一并删掉。
  final Future<void> Function(AppSettings s)? onSettingsChanged;

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

/// 一条“题 × 错因”解决记录（列表分组里的一项）。
class _CauseItem {
  _CauseItem({required this.question, required this.record});

  final Question question;
  final CauseRecord record;
}

/// 列表分组：学科 × 错因（HTML `causeGroups()` / `curedGroups()`）。
class _CauseGroup {
  _CauseGroup({
    required this.subjectId,
    required this.cause,
    required this.firstJoined,
  });

  final String subjectId;
  final String cause;
  final List<_CauseItem> items = [];
  DateTime firstJoined;

  /// 组状态（HTML `revListHTML` 的 stTxt 口径）：全已解决 → 已解决；
  /// 有待解决 → 待解决；其余 → 解决中。
  CauseStatus get status {
    if (items.every((it) => it.record.status == CauseStatus.solved)) {
      return CauseStatus.solved;
    }
    if (items.any((it) => it.record.status == CauseStatus.pending)) {
      return CauseStatus.pending;
    }
    return CauseStatus.inProgress;
  }

  bool get hasRecheck => items.any((it) => it.record.isRecheckDue);
}

/// 会话块：一道题 + 它本轮要治的错因（HTML `REV2.blocks`）。
class _CauseBlock {
  _CauseBlock({required this.questionId, required this.causes});

  final String questionId;
  final List<String> causes;
}

/// 本轮一条状态变化（总结页每行）。
class _SessionChange {
  _SessionChange({
    required this.questionTitle,
    required this.subjectName,
    required this.cause,
    required this.before,
    required this.after,
    this.recheckDate,
    required this.note,
  });

  final String questionTitle;
  final String subjectName;
  final String cause;
  final String before;
  final String after;
  final DateTime? recheckDate;
  final String note;
}

/// 已保存的断点（解析后的“上次解决到一半”）。
class _ResumeInfo {
  _ResumeInfo({
    required this.blocks,
    required this.blockIndex,
    required this.causeIndex,
  });

  final List<_CauseBlock> blocks;
  final int blockIndex;
  final int causeIndex;
}

enum _Phase { recall, remedy, redo, check }

const _stepLabels = ['① 看错因', '② 写补救', '③ 重做', '④ 自查'];

class _ReviewPageState extends State<ReviewPage> {
  AppSettings _settings = AppSettings.defaults;
  // 学科顺序表：读库 subjects（B2 补充；以前写死 Subject.all，
  // 新学科在排序里无索引位、筛选下拉里也没有）。空库回退预设三科。
  List<Subject> _subjects = Subject.all;
  // 库里找学科：新学科用库里的名与色；找不到才回退 Subject.byId
  //（数学兜底，只发生在数据不一致时）。
  Subject _subjectOf(String id) => _subjects.firstWhere(
        (s) => s.id == id,
        orElse: () => Subject.byId(id),
      );
  List<_CauseGroup> _groups = [];
  List<_CauseGroup> _curedGroups = [];
  List<Question> _notJoined = [];
  // 每题待治的错因记录（按题内错因顺序），会话建块用。
  Map<String, List<CauseRecord>> _pendingByQ = {};
  bool _loading = true;

  String? _subjectFilter;
  String _causeFilter = '全部';
  int _page = 1;
  // P0B2：每页条数是本页本地状态（与错题本一致），只在打开时从设置
  // 默认值读一次初值；下拉改动不写库、不调 onSettingsChanged。
  int _pageSize = AppSettings.defaults.pageSize;
  String? _openCuredKey;
  _ResumeInfo? _resume;

  // ---- 会话状态 ----
  bool _inSession = false;
  bool _showSummary = false;
  List<_CauseBlock> _blocks = [];
  int _bi = 0;
  int _ci = 0;
  _Phase _phase = _Phase.recall;
  final _remedyController = TextEditingController();
  bool _answerShown = false;
  final Map<String, String> _checks = {};
  final Map<String, int> _skips = {};
  int _curedNow = 0;
  final List<_SessionChange> _changes = [];
  int _summaryRemaining = 0;
  String _scopeLabel = '全部待解决错因';
  bool _saveError = false;
  Map<String, List<({String result, DateTime reviewedAt})>> _historyByQ = {};

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
    final subjects = await widget.repo.subjects();
    final subjectList = subjects.isEmpty ? Subject.all : subjects;
    final questions = await widget.repo.all(includeArchived: true);
    final records = await widget.repo.causeRecords();
    final byQ = <String, List<CauseRecord>>{};
    for (final r in records) {
      (byQ[r.questionId] ??= []).add(r);
    }
    final pendingByQ = <String, List<CauseRecord>>{};
    final pendingGroups = <String, _CauseGroup>{};
    final curedGroups = <String, _CauseGroup>{};
    final notJoined = <Question>[];
    for (final q in questions) {
      if (!q.reviewJoined && !q.isArchived) notJoined.add(q);
      // B6：复习主列表排除已归档题（与 HTML `qInReview` 口径一致；
      // 未加入列表上面一行已排除了归档）。归档题的解决记录保留在
      // 库里（不删），取消归档后重新出现。
      if (!q.reviewJoined || !q.isOrganized || q.isArchived) continue;
      final rs = byQ[q.id];
      if (rs == null || rs.isEmpty) continue;
      // 题内错因按题目本身的错因顺序排。
      final order = q.allCauses;
      final sorted = [...rs]
        ..sort((a, b) =>
            order.indexOf(a.cause).compareTo(order.indexOf(b.cause)));
      final pending = sorted
          .where((r) => r.status != CauseStatus.solved || r.isRecheckDue)
          .toList();
      if (pending.isNotEmpty) pendingByQ[q.id] = pending;
      for (final r in sorted) {
        final key = '${q.subjectId}|${r.cause}';
        final isPending =
            r.status != CauseStatus.solved || r.isRecheckDue;
        final target = isPending ? pendingGroups : curedGroups;
        final g = target.putIfAbsent(
          key,
          () => _CauseGroup(
            subjectId: q.subjectId,
            cause: r.cause,
            firstJoined: r.joinedAt,
          ),
        );
        g.items.add(_CauseItem(question: q, record: r));
        if (r.joinedAt.isBefore(g.firstJoined)) {
          g.firstJoined = r.joinedAt;
        }
      }
    }
    int groupCompare(_CauseGroup a, _CauseGroup b) {
      if (settings.reviewSort == 'subject') {
        final order = {
          for (var i = 0; i < subjectList.length; i++)
            subjectList[i].id: i,
        };
        final c = (order[a.subjectId] ?? 99)
            .compareTo(order[b.subjectId] ?? 99);
        if (c != 0) return c;
      }
      return a.firstJoined.compareTo(b.firstJoined);
    }

    final sortedPending = pendingGroups.values.toList()..sort(groupCompare);
    final sortedCured = curedGroups.values.toList()..sort(groupCompare);

    // 断点：校验保存的队列是否还有待治项，无效则清掉（陈旧断点回收）。
    _ResumeInfo? resume;
    final state = await widget.repo.reviewState();
    if (state != null) {
      final pendingKeys = <ReviewQueueItem>{
        for (final rs in pendingByQ.values)
          for (final r in rs)
            ReviewQueueItem(questionId: r.questionId, cause: r.cause),
      };
      final valid =
          state.queue.where(pendingKeys.contains).toList();
      if (valid.isEmpty) {
        await widget.repo.clearReviewState();
      } else {
        final blocks = _blocksFromFlat(valid);
        final pos = state.position.clamp(0, valid.length - 1);
        var seen = 0;
        var bi = 0;
        var ci = 0;
        for (var i = 0; i < blocks.length; i++) {
          if (pos < seen + blocks[i].causes.length) {
            bi = i;
            ci = pos - seen;
            break;
          }
          seen += blocks[i].causes.length;
        }
        resume = _ResumeInfo(blocks: blocks, blockIndex: bi, causeIndex: ci);
      }
    }
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _pageSize = settings.pageSize;
      _subjects = subjectList;
      _groups = sortedPending;
      _curedGroups = sortedCured;
      _notJoined = notJoined;
      _pendingByQ = pendingByQ;
      _resume = resume;
      _loading = false;
    });
  }

  /// 扁平队列（ReviewQueueItem 顺序）→ 按题分块（连续同题合并）。
  List<_CauseBlock> _blocksFromFlat(List<ReviewQueueItem> flat) {
    final blocks = <_CauseBlock>[];
    for (final entry in flat) {
      if (blocks.isNotEmpty &&
          blocks.last.questionId == entry.questionId) {
        blocks.last.causes.add(entry.cause);
      } else {
        blocks.add(
            _CauseBlock(questionId: entry.questionId, causes: [entry.cause]));
      }
    }
    return blocks;
  }

  List<_CauseGroup> _filterGroups(List<_CauseGroup> groups) {
    var list = groups;
    if (_subjectFilter != null) {
      list =
          list.where((g) => g.subjectId == _subjectFilter).toList();
    }
    if (_causeFilter != '全部') {
      list = list.where((g) => g.cause == _causeFilter).toList();
    }
    return list;
  }

  List<_CauseGroup> get _filtered => _filterGroups(_groups);
  List<_CauseGroup> get _filteredCured => _filterGroups(_curedGroups);

  int get _totalPages {
    final n = (_filtered.length / _pageSize).ceil();
    return n < 1 ? 1 : n;
  }

  List<_CauseGroup> get _pageGroups {
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
    for (final g in [..._groups, ..._curedGroups]) {
      set.add(g.cause);
    }
    final fixed = ErrorTypes.fixed.where(set.contains).toList();
    final rest = set.where((c) => !ErrorTypes.fixed.contains(c)).toList()
      ..sort();
    return [...fixed, ...rest];
  }

  /// 元信息行计数（不过滤，HTML `revListHTML` 口径）。
  (int pend, int check, int cured) get _metaCounts {
    var pend = 0;
    var check = 0;
    for (final g in _groups) {
      for (final it in g.items) {
        if (it.record.isRecheckDue) {
          check++;
        } else {
          pend++;
        }
      }
    }
    var cured = 0;
    for (final g in _curedGroups) {
      cured += g.items.length;
    }
    return (pend, check, cured);
  }

  // ---------- 会话 ----------

  /// 从筛选后的分组建会话块：分组选中的题（按分组顺序首次出现），
  /// 每题带它全部待治错因（按题内错因顺序），一块题走完再走下一块。
  List<_CauseBlock> _buildBlocks(List<_CauseGroup> groups) {
    final seen = <String>{};
    final blocks = <_CauseBlock>[];
    for (final g in groups) {
      for (final it in g.items) {
        final qid = it.question.id;
        if (seen.contains(qid)) continue;
        seen.add(qid);
        final causes = _pendingByQ[qid];
        if (causes == null || causes.isEmpty) continue;
        blocks.add(_CauseBlock(
          questionId: qid,
          causes: causes.map((r) => r.cause).toList(),
        ));
      }
    }
    // 每会话错因数（设置 5/10/不限）：按列表顺序只取前 N 个错因。
    final limit = _settings.causesPerSession;
    if (limit > 0) {
      var left = limit;
      final limited = <_CauseBlock>[];
      for (final b in blocks) {
        if (left <= 0) break;
        final take = b.causes.take(left).toList();
        if (take.isNotEmpty) {
          limited.add(_CauseBlock(questionId: b.questionId, causes: take));
          left -= take.length;
        }
      }
      return limited;
    }
    return blocks;
  }

  Future<void> _loadHistoryForSession() async {
    final map = <String, List<({String result, DateTime reviewedAt})>>{};
    for (final b in _blocks) {
      map[b.questionId] ??= await widget.repo.reviewHistory(b.questionId);
    }
    if (!mounted) return;
    setState(() => _historyByQ = map);
  }

  Future<void> _startSession({_CauseGroup? fromGroup, bool resume = false}) async {
    List<_CauseBlock> blocks;
    var bi = 0;
    var ci = 0;
    String scopeLabel;
    if (resume && _resume != null) {
      blocks = _resume!.blocks;
      bi = _resume!.blockIndex;
      ci = _resume!.causeIndex;
      scopeLabel = '全部待解决错因';
    } else {
      blocks = _buildBlocks(_filtered);
      if (blocks.isEmpty) return;
      if (fromGroup != null) {
        // 跳到首个含该组错因的块（HTML `data-r2-start-group` 口径）。
        for (var i = 0; i < blocks.length; i++) {
          final qid = blocks[i].questionId;
          final q = _questionOf(qid);
          if (q != null &&
              q.subjectId == fromGroup.subjectId &&
              blocks[i].causes.contains(fromGroup.cause)) {
            bi = i;
            break;
          }
        }
      }
      scopeLabel = _subjectFilter == null
          ? '全部待解决错因'
          : '${_subjectOf(_subjectFilter!).name}这一科';
    }
    if (blocks.isEmpty) return;
    setState(() {
      _blocks = blocks;
      _bi = bi;
      _ci = ci;
      _phase = _Phase.recall;
      _checks.clear();
      _skips.clear();
      _curedNow = 0;
      _changes.clear();
      _answerShown = !_settings.redoAnswerHidden;
      _scopeLabel = scopeLabel;
      _saveError = false;
      _inSession = true;
      _showSummary = false;
    });
    _beginCause();
    await _loadHistoryForSession();
  }

  Question? _questionOf(String questionId) {
    for (final g in [..._groups, ..._curedGroups]) {
      for (final it in g.items) {
        if (it.question.id == questionId) return it.question;
      }
    }
    return null;
  }

  _CauseBlock get _currentBlock => _blocks[_bi];

  Question? get _currentQuestion => _questionOf(_currentBlock.questionId);

  String get _currentCause => _currentBlock.causes[_ci];

  CauseRecord? _recordOf(String questionId, String cause) {
    final rs = _pendingByQ[questionId];
    if (rs != null) {
      for (final r in rs) {
        if (r.cause == cause) return r;
      }
    }
    for (final g in _curedGroups) {
      for (final it in g.items) {
        if (it.question.id == questionId && it.record.cause == cause) {
          return it.record;
        }
      }
    }
    return null;
  }

  void _beginCause() {
    _remedyController.clear();
    _answerShown = !_settings.redoAnswerHidden;
    _phase = _Phase.recall;
  }

  /// 扁平队列 + 当前位置（暂停保存用，与基线 `review_state` 同格式）。
  (List<ReviewQueueItem>, int) _flatQueue() {
    final flat = <ReviewQueueItem>[];
    var pos = 0;
    for (var i = 0; i < _blocks.length; i++) {
      for (var j = 0; j < _blocks[i].causes.length; j++) {
        if (i == _bi && j == _ci) pos = flat.length;
        flat.add(ReviewQueueItem(
            questionId: _blocks[i].questionId, cause: _blocks[i].causes[j]));
      }
    }
    return (flat, pos);
  }

  Future<void> _pauseSession() async {
    final (queue, position) = _flatQueue();
    await widget.repo.saveReviewState(queue: queue, position: position);
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

  void _advanceBlock() {
    _bi++;
    if (_bi >= _blocks.length) {
      _finishSession();
      return;
    }
    _ci = 0;
    _checks.clear();
    setState(_beginCause);
  }

  Future<void> _finishSession() async {
    await widget.repo.clearReviewState();
    final records = await widget.repo.causeRecords();
    final questions = await widget.repo.all(includeArchived: true);
    final joinedIds = {
      for (final q in questions)
        // B6：与主列表同口径，已归档题不计入剩余（记录保留，取消归档回来）。
        if (q.reviewJoined && q.isOrganized && !q.isArchived) q.id,
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

  void _skipCurrent() {
    final qid = _currentBlock.questionId;
    final cause = _currentCause;
    final key = '$qid|$cause';
    final count = (_skips[key] ?? 0) + 1;
    _skips[key] = count;
    setState(() {
      _currentBlock.causes.removeAt(_ci);
      if (count < _settings.skipLimit) {
        // 第 1 次跳过：追加单错因块到队尾。
        _blocks.add(_CauseBlock(questionId: qid, causes: [cause]));
      }
      // 第 2 次跳过：留到下次（本轮不再出现）。
      if (_currentBlock.causes.isEmpty) {
        _blocks.removeAt(_bi);
        _ci = 0;
        _phase = _Phase.recall;
        if (_bi >= _blocks.length) {
          _finishSession();
          return;
        }
      } else {
        if (_ci >= _currentBlock.causes.length) {
          _ci = _currentBlock.causes.length - 1;
        }
        _phase = _Phase.recall;
      }
      _remedyController.clear();
      _answerShown = !_settings.redoAnswerHidden;
    });
  }

  Future<void> _nextFromRemedy() async {
    final record = _recordOf(_currentBlock.questionId, _currentCause);
    if (record != null && _remedyController.text.trim().isNotEmpty) {
      await widget.repo.saveRemedy(record, _remedyController.text);
    }
    if (!mounted) return;
    setState(() {
      if (_ci < _currentBlock.causes.length - 1) {
        _ci++;
        _beginCause();
      } else {
        _phase = _Phase.redo;
        _answerShown = !_settings.redoAnswerHidden;
      }
    });
  }

  Future<void> _finishQuestion() async {
    final block = _currentBlock;
    final q = _currentQuestion;
    if (q == null) {
      _advanceBlock();
      return;
    }
    for (final cause in block.causes) {
      final choiceLabel = _checks[cause];
      if (choiceLabel == null) continue;
      // 自查按钮存的是中文文案，仓库要 solved / unsolved / unsure 编码。
      final choice = switch (choiceLabel) {
        '已解决' => 'solved',
        '未解决' => 'unsolved',
        _ => 'unsure',
      };
      final record = _recordOf(block.questionId, cause);
      if (record == null) continue;
      final before = record.status.label;
      final wasRecheck = record.isRecheckDue;
      if (choice == 'unsure') {
        // 不确定不算，不改记录；总结里留一行说明。
        _changes.add(_SessionChange(
          questionTitle: q.title,
          subjectName: _subjectOf(q.subjectId).name,
          cause: cause,
          before: before,
          after: before,
          note: '选了不确定，不算，下次重新练这道题再自查一次',
        ));
        continue;
      }
      late CauseRecord updated;
      try {
        updated = await widget.repo.recordSelfCheck(
          record,
          choice,
          cureChecks: _settings.cureChecks,
          recheckIntervalDays: _settings.recheckIntervalDays,
          // 待定1：复查通过不加计数（HTML 口径）。
          isRecheck: wasRecheck,
        );
      } catch (_) {
        if (!mounted) return;
        setState(() => _saveError = true);
        return;
      }
      final after = updated.status.label;
      String note;
      if (wasRecheck) {
        note = choice == 'solved'
            ? '复查通过，下次复查 ${_fmtDate(updated.recheckDate!)}'
            : '复查没过，打回解决中';
      } else if (choice == 'solved') {
        note = updated.status == CauseStatus.solved
            ? '已解决，下次复查 ${_fmtDate(updated.recheckDate!)}'
            : '还差 ${_settings.cureChecks - updated.solvedCount} 次「已解决」解决';
      } else {
        note = '错因未解决，继续解决（答对了题也不算掌握）';
      }
      if (before != '已解决' && after == '已解决') _curedNow++;
      _changes.add(_SessionChange(
        questionTitle: q.title,
        subjectName: _subjectOf(q.subjectId).name,
        cause: cause,
        before: before,
        after: after,
        recheckDate:
            updated.status == CauseStatus.solved ? updated.recheckDate : null,
        note: note,
      ));
    }
    if (!mounted) return;
    _advanceBlock();
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _fmtMd(DateTime d) => '${d.month}-${d.day}';

  String _historyLabel(String r) => switch (r) {
        'solved' => '已解决',
        'unsolved' => '未解决',
        _ => '不确定',
      };

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

  Widget _centered(Widget child) {
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

  Widget _buildList() {
    final scale = qmScaleOf(context);
    final pageGroups = _pageGroups;
    final (pendCount, checkCount, curedCount) = _metaCounts;
    final hasData = _groups.isNotEmpty || _curedGroups.isNotEmpty;
    return _centered(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('复习', style: Theme.of(context).textTheme.titleLarge),
          SizedBox(height: 14 * scale),
          if (_resume != null && _groups.isNotEmpty) _buildResumeBar(),
          if (_resume == null && _groups.isNotEmpty) ...[
            QmButton(
              label: '开始解决',
              onPressed: () => _startSession(),
            ),
            SizedBox(height: 14 * scale),
          ],
          if (!hasData) ...[
            QmEmptyState(
              title: '复习列表还是空的',
              description:
                  '在题目详情的「复习记录」里点「加入复习」，这道题的错因才会到这里来解决。',
              actionLabel: '去错题本选题',
              onAction: widget.onGoWrongbook,
            ),
          ] else ...[
            _buildMetaRow(pendCount, checkCount, curedCount),
            _buildToolbar(),
            if (pageGroups.isNotEmpty) ...[
              _buildPendHead(),
              ..._pageGroups.map(_buildGroupRow),
              _buildPager(),
            ] else if (_groups.isNotEmpty) ...[
              _DetailBox(
                child: const Text('当前筛选下没有待解决错因，换个学科 / 错因试试。'),
              ),
            ],
            if (_filteredCured.isNotEmpty) ...[
              SizedBox(height: 14 * scale),
              _buildCuredSection(),
            ],
          ],
          if (_notJoined.isNotEmpty) ...[
            SizedBox(height: 14 * scale),
            _buildNotJoinedBox(),
          ],
        ],
      ),
    );
  }

  /// “上次解决到一半”恢复条（HTML `revListHTML` 的 detailbox）。
  Widget _buildResumeBar() {
    final scale = qmScaleOf(context);
    final resume = _resume!;
    final block = resume.blocks[resume.blockIndex];
    final q = _questionOf(block.questionId);
    final cause = block.causes[resume.causeIndex];
    final subjectName =
        q == null ? '' : _subjectOf(q.subjectId).name;
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
                    text: '上次解决到一半',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(
                    text:
                        ' · $subjectName「$cause」（${q?.title ?? ''}），第 ${resume.blockIndex + 1} / ${resume.blocks.length} 道题',
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
                  label: '继续解决',
                  onPressed: () => _startSession(resume: true),
                ),
                QmButton(
                  label: '从头开始',
                  variant: QmButtonVariant.secondary,
                  onPressed: () async {
                    await widget.repo.clearReviewState();
                    _resume = null;
                    await _startSession();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetaRow(int pend, int check, int cured) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final metaStyle = TextStyle(
      fontSize: DesignTokens.reviewMetaFontSize,
      color: palette.muted,
    );
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
                const TextSpan(text: ' 条解决记录'),
              ],
            ),
          ),
          if (check > 0)
            QmStatusPill.tone(label: '复查 $check 条', tone: QmTone.error),
          Text('已解决 $cured 条', style: metaStyle),
          Text(
            _settings.reviewSort == 'subject'
                ? '列表按学科排（数学 / 英语 / 政治），同一科里先加入的先解决'
                : '列表按加入时间排，先加入的先解决',
            style: metaStyle,
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
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
              value: _subjectFilter ?? '全部',
              items: [
                const DropdownMenuItem(value: '全部', child: Text('全部')),
                for (final s in _subjects)
                  DropdownMenuItem(value: s.id, child: Text(s.name)),
              ],
              onChanged: (v) => setState(() {
                _subjectFilter = v == '全部' ? null : v;
                _resetPage();
              }),
            ),
          ),
          Text('错因', style: labelStyle),
          SizedBox(
            width: 160 * scale,
            child: _styledDropdown<String>(
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
          ),
        ],
      ),
    );
  }

  Widget _buildPendHead() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        DesignTokens.reviewRowPaddingH * scale,
        2 * scale,
        DesignTokens.reviewRowPaddingH * scale,
        4 * scale,
      ),
      child: Text(
        '待解决错因 · 一道题有多个错因时在列表里只出现一次，一道题里挨着解决完',
        style: TextStyle(
          fontSize: DesignTokens.reviewPendHeadFontSize,
          fontWeight: FontWeight.w700,
          color: palette.muted,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget _buildGroupRow(_CauseGroup g) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final subject = _subjectOf(g.subjectId);
    final subjectName = subject.name;
    final titles = g.items.map((it) => it.question.title).join('、');
    return Container(
      padding: EdgeInsets.symmetric(
        vertical: DesignTokens.reviewRowPaddingV * scale,
        horizontal: DesignTokens.reviewRowPaddingH * scale,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: palette.line),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  g.cause,
                  style: TextStyle(
                    fontSize: DesignTokens.bodySmallFontSize,
                    fontWeight: FontWeight.w700,
                    color: palette.ink,
                  ),
                ),
                Text(
                  '关联 ${g.items.length} 道题：$titles',
                  style: TextStyle(
                    fontSize: DesignTokens.captionFontSize,
                    color: palette.muted,
                  ),
                ),
              ],
            ),
          ),
          if (g.hasRecheck) ...[
            QmStatusPill.cause(QmCauseStatus.recheck),
            SizedBox(width: 6 * scale),
          ],
          QmStatusPill.cause(switch (g.status) {
            CauseStatus.pending => QmCauseStatus.pending,
            CauseStatus.inProgress => QmCauseStatus.inProgress,
            CauseStatus.solved => QmCauseStatus.solved,
          }),
          SizedBox(width: 10 * scale),
          QmButton(
            label: '开始解决',
            size: QmButtonSize.small,
            variant: QmButtonVariant.secondary,
            onPressed: () => _startSession(fromGroup: g),
          ),
        ],
      ),
    );
  }

  Widget _buildPager() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final totalPages = _totalPages;
    final page = _page.clamp(1, totalPages);
    return Container(
      margin: EdgeInsets.only(top: DesignTokens.pagerMarginTop * scale),
      padding: EdgeInsets.only(top: DesignTokens.pagerPaddingTop * scale),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.line)),
      ),
      child: Wrap(
        spacing: 10 * scale,
        runSpacing: 8 * scale,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '共 ${_filtered.length} 条 · 第 $page / $totalPages 页',
            style: TextStyle(
              fontSize: DesignTokens.pagerFontSize,
              color: palette.muted,
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '每页',
                style: TextStyle(
                  fontSize: DesignTokens.pagerFontSize,
                  color: palette.muted,
                ),
              ),
              SizedBox(width: 6 * scale),
              SizedBox(
                width: 84 * scale,
                child: _styledDropdown<int>(
                  value: _pageSize,
                  // 当前值恒在选项里：设置只会存 10/20/30/40/50，
                  // 但容错——万一库里是别的值也别让下拉断言。
                  items: () {
                    final sizes = {10, 20, 30, 40, 50, _pageSize}.toList()
                      ..sort();
                    return sizes
                        .map((n) =>
                            DropdownMenuItem(value: n, child: Text('$n')))
                        .toList();
                  }(),
                  onChanged: (v) {
                    if (v == null) return;
                    // P0B2：本地行为（与错题本一致）——只改本页 _pageSize
                    // 并回第 1 页，不调 onSettingsChanged、不写库；
                    // 初值仍在 _load 里从设置默认值读。
                    setState(() {
                      _pageSize = v;
                      _resetPage();
                    });
                  },
                ),
              ),
              SizedBox(width: 6 * scale),
              Text(
                '条',
                style: TextStyle(
                  fontSize: DesignTokens.pagerFontSize,
                  color: palette.muted,
                ),
              ),
            ],
          ),
          SizedBox(width: 10 * scale),
          Wrap(
            spacing: 6 * scale,
            runSpacing: 6 * scale,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              QmButton(
                label: '上一页',
                size: QmButtonSize.small,
                variant: QmButtonVariant.secondary,
                onPressed:
                    page > 1 ? () => setState(() => _page = page - 1) : null,
              ),
              if (totalPages > 1)
                for (var p = 1; p <= totalPages; p++)
                  QmButton(
                    label: '$p',
                    size: QmButtonSize.small,
                    variant: p == page
                        ? QmButtonVariant.primary
                        : QmButtonVariant.plain,
                    onPressed:
                        p == page ? null : () => setState(() => _page = p),
                  ),
              QmButton(
                label: '下一页',
                size: QmButtonSize.small,
                variant: QmButtonVariant.secondary,
                onPressed: page < totalPages
                    ? () => setState(() => _page = page + 1)
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCuredSection() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Container(
      margin:
          EdgeInsets.only(bottom: DesignTokens.reviewCuredMarginBottom * scale),
      decoration: BoxDecoration(
        border: Border.all(color: palette.line),
        borderRadius:
            BorderRadius.circular(DesignTokens.radiusLg * scale),
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
              '已解决的错因（点一行看解决记录 · 已解决满 ${_settings.recheckIntervalDays} 天会自动回到上面的列表复查）',
              style: TextStyle(
                fontSize: DesignTokens.reviewPendHeadFontSize,
                fontWeight: FontWeight.w700,
                color: palette.muted,
                letterSpacing: 0.8,
              ),
            ),
          ),
          for (final g in _filteredCured) _buildCuredRow(g),
        ],
      ),
    );
  }

  Widget _buildCuredRow(_CauseGroup g) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final key = '${g.subjectId}|${g.cause}';
    final open = _openCuredKey == key;
    final subject = _subjectOf(g.subjectId);
    final subjectName = subject.name;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () =>
              setState(() => _openCuredKey = open ? null : key),
          child: Container(
            padding: EdgeInsets.symmetric(
              vertical: DesignTokens.reviewCuredHeadPaddingV * scale,
              horizontal: DesignTokens.reviewRowPaddingH * scale,
            ),
            decoration: BoxDecoration(
              color: open ? palette.accentSoft : null,
              border: Border(
                bottom: BorderSide(color: palette.line),
              ),
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
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                          ),
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
              border: Border(
                bottom: BorderSide(color: palette.line),
              ),
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
    if (r.lastCheck != null) parts.add('解决于 ${_fmtDate(r.lastCheck!)}');
    if (r.recheckDate != null) {
      parts.add('下次复查 ${_fmtDate(r.recheckDate!)}（${_fmtMd(r.recheckDate!)}）');
    }
    var text = parts.join(' · ');
    if (r.remedyHistory.isNotEmpty) {
      text += '\n补救记录：${r.remedyHistory.join('\n')}';
    }
    return text;
  }

  Widget _buildNotJoinedBox() {
    final titles = _notJoined
        .map((q) => '${_subjectOf(q.subjectId).name}「${q.title}」')
        .join('、');
    return _DetailBox(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '还没加入复习的题',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 6 * qmScaleOf(context)),
          Text(titles),
          SizedBox(height: 6 * qmScaleOf(context)),
          Text(
            '到这些题的题目详情「复习记录」里点「加入复习」才会进来；归档的题不出现在复习列表里；错因全部解决的题会自动离开列表，${_settings.recheckIntervalDays} 天后回来复查。',
            style: TextStyle(
              fontSize: DesignTokens.bodySmallFontSize,
              color: DesignTokens.of(Theme.of(context).brightness).muted,
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 会话 ----------

  Widget _buildSession() {
    final q = _currentQuestion;
    if (_blocks.isEmpty || q == null) return _buildSummary();
    final block = _currentBlock;
    final record = _recordOf(block.questionId, _currentCause);
    final subjectName = _subjectOf(q.subjectId).name;
    return _centered(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_saveError)
            QmBanner(
              tone: QmBannerTone.error,
              message: '复习记录保存失败，本次自查还没有存下。请重试，或重启应用后再复习。',
              onDismiss: () => setState(() => _saveError = false),
            ),
          _buildSessionMeta(q, subjectName),
          SizedBox(height: 12 * qmScaleOf(context)),
          _buildStepIndicator(),
          SizedBox(height: 12 * qmScaleOf(context)),
          if (_phase == _Phase.recall || _phase == _Phase.remedy)
            _buildCauseMeta(record),
          if (_phase == _Phase.recall) _buildStepCause(q),
          if (_phase == _Phase.remedy) _buildStepRemedy(record),
          if (_phase == _Phase.redo) _buildStepRedo(q),
          if (_phase == _Phase.check) _buildStepCheck(block),
        ],
      ),
    );
  }

  Widget _buildSessionMeta(Question q, String subjectName) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final metaStyle = TextStyle(
      fontSize: DesignTokens.reviewMetaFontSize,
      color: palette.muted,
    );
    return Wrap(
      spacing: 8 * scale,
      runSpacing: 8 * scale,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '第 ${_bi + 1} / ${_blocks.length} 道题 · $_scopeLabel',
          style: metaStyle,
        ),
        Text(
          '$subjectName · ${sliceKindLabel(q.sliceKind)}｜${q.title}',
          style: metaStyle,
        ),
        QmButton(
          label: '查看题目详情',
          size: QmButtonSize.small,
          variant: QmButtonVariant.secondary,
          onPressed: () async {
            final orderIds =
                _blocks.map((b) => b.questionId).toList();
            await widget.onOpenDetail(q, orderIds);
            await _load();
          },
        ),
        QmButton(
          label: '暂停',
          size: QmButtonSize.small,
          variant: QmButtonVariant.secondary,
          onPressed: _pauseSession,
        ),
      ],
    );
  }

  Widget _buildStepIndicator() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final stepIdx = _phase.index;
    return Wrap(
      spacing: 6 * scale,
      runSpacing: 6 * scale,
      children: [
        for (var i = 0; i < _stepLabels.length; i++)
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
              _stepLabels[i],
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

  Widget _buildCauseMeta(CauseRecord? record) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final block = _currentBlock;
    return Padding(
      padding: EdgeInsets.only(bottom: 12 * scale),
      child: Wrap(
        spacing: 8 * scale,
        runSpacing: 6 * scale,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '本题错因 ${_ci + 1} / ${block.causes.length}',
            style: TextStyle(
              fontSize: DesignTokens.reviewMetaFontSize,
              color: palette.muted,
            ),
          ),
          Text(
            _currentCause,
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
          if (record != null && record.isRecheckDue)
            QmStatusPill.tone(label: '复查 · 用原来这道题', tone: QmTone.error),
          if (record != null)
            Text(
              '自查「已解决」${record.solvedCount} / ${_settings.cureChecks} 次',
              style: TextStyle(
                fontSize: DesignTokens.reviewMetaFontSize,
                color: palette.muted,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStepCause(Question q) {
    final scale = qmScaleOf(context);
    final history = _historyByQ[q.id];
    final lastCheck = history == null || history.isEmpty ? null : history.last;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        QuestionSlice(
          question: q,
          subject: _subjectOf(q.subjectId),
          maxHeight: 220,
          onTap: () => showQuestionZoomDialog(context, q, returnLabel: '复习'),
        ),
        SizedBox(height: 12 * scale),
        _DetailBox(
          child: Column(
            children: [
              _KvRow(
                label: '备注',
                value: (q.notes == null || q.notes!.isEmpty)
                    ? '待补充'
                    : q.notes!,
              ),
              if (lastCheck != null)
                _KvRow(
                  label: '上次自查',
                  value:
                      '${_fmtDate(lastCheck.reviewedAt)} · 「${_historyLabel(lastCheck.result)}」',
                ),
            ],
          ),
        ),
        SizedBox(height: DesignTokens.reviewActsMarginTop * scale),
        _SessionActions(
          primaryLabel: '下一步：写补救',
          onPrimary: () => setState(() => _phase = _Phase.remedy),
          secondaryLabel: '跳过该题',
          onSecondary: _skipCurrent,
        ),
      ],
    );
  }

  Widget _buildStepRemedy(CauseRecord? record) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final lastRemedy =
        record == null || record.remedyHistory.isEmpty
            ? null
            : record.remedyHistory.first;
    final isLastCause = _ci >= _currentBlock.causes.length - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (lastRemedy != null) ...[
          _DetailBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _KvRow(label: '上次补救', value: lastRemedy),
                SizedBox(height: 4 * scale),
                Text(
                  '上次是这么补的，这次可以接着用，也可以换个补法',
                  style: TextStyle(
                    fontSize: DesignTokens.captionFontSize,
                    color: palette.muted,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 12 * scale),
        ],
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '这次怎么补「$_currentCause」',
                style: TextStyle(
                  fontSize: DesignTokens.detailFieldLabelFontSize,
                  fontWeight: FontWeight.w700,
                  color: palette.ink2,
                ),
              ),
              TextSpan(
                text: '  自己写，不套模板 · 写的内容会存下来，下次复习能看到上次是怎么补的',
                style: TextStyle(
                  fontSize: DesignTokens.detailFieldLabelFontSize,
                  color: palette.muted,
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: 5 * scale),
        TextField(
          controller: _remedyController,
          maxLines: 4,
          style: TextStyle(
            fontSize: DesignTokens.reviewRemedyFontSize,
            color: palette.ink,
          ),
          decoration: InputDecoration(
            hintText: '比如：把记错的公式推导一遍 / 把概念用自己的话复述一遍 / 只重算当时算错的那一步……',
            hintStyle: TextStyle(color: palette.muted),
            contentPadding: EdgeInsets.symmetric(
              horizontal: 12 * scale,
              vertical: 10 * scale,
            ),
            border: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(DesignTokens.radius * scale),
              borderSide: BorderSide(color: palette.lineStrong),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(DesignTokens.radius * scale),
              borderSide: BorderSide(color: palette.lineStrong),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(DesignTokens.radius * scale),
              borderSide: BorderSide(color: palette.accent, width: 2),
            ),
            filled: true,
            fillColor: palette.surface,
          ),
        ),
        SizedBox(height: DesignTokens.reviewActsMarginTop * scale),
        _SessionActions(
          primaryLabel: isLastCause ? '下一步：重做' : '下一步：下个错因',
          onPrimary: _nextFromRemedy,
          secondaryLabel: '跳过',
          onSecondary: _skipCurrent,
        ),
      ],
    );
  }

  Widget _buildStepRedo(Question q) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        QuestionSlice(
          question: q,
          subject: _subjectOf(q.subjectId),
          maxHeight: 220,
          onTap: () => showQuestionZoomDialog(context, q, returnLabel: '复习'),
        ),
        SizedBox(height: 6 * scale),
        Center(
          child: Text(
            _answerShown
                ? '答案显示着（设置里选的默认显示）：对照答案把这道题重做一遍'
                : '答案遮着：自己把这道题重做一遍，再点开答案对照',
            style: TextStyle(
              fontSize: DesignTokens.detailHintFontSize,
              color: palette.muted,
            ),
          ),
        ),
        if (_answerShown) ...[
          SizedBox(height: 12 * scale),
          _DetailBox(
            child: Column(
              children: [
                _KvRow(
                  label: '答案',
                  value: (q.answer == null || q.answer!.isEmpty)
                      ? '待补充（未填写，如实显示）'
                      : q.answer!,
                ),
                _KvRow(
                  label: '解析',
                  value: (q.explanation == null || q.explanation!.isEmpty)
                      ? '待补充（未填写，如实显示）'
                      : q.explanation!,
                ),
              ],
            ),
          ),
        ],
        SizedBox(height: DesignTokens.reviewActsMarginTop * scale),
        _SessionActions(
          primaryLabel: _answerShown ? '下一步：自查' : '看答案',
          onPrimary: () => setState(() {
            if (_answerShown) {
              _phase = _Phase.check;
              _checks.clear();
            } else {
              _answerShown = true;
            }
          }),
          secondaryLabel: _answerShown ? '遮住答案' : null,
          onSecondary:
              _answerShown ? () => setState(() => _answerShown = false) : null,
        ),
      ],
    );
  }

  Widget _buildStepCheck(_CauseBlock block) {
    final scale = qmScaleOf(context);
    final allChecked =
        block.causes.every((c) => _checks.containsKey(c));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '这道题的 ${block.causes.length} 个错因挨着自查：这次做对，是因为错因已解决，还是只是记住了这道题的答案？',
          style: const TextStyle(fontSize: 14),
        ),
        SizedBox(height: 10 * scale),
        for (final cause in block.causes) _buildCheckBox(cause),
        SizedBox(height: DesignTokens.reviewActsMarginTop * scale),
        _SessionActions(
          primaryLabel: _bi < _blocks.length - 1 ? '下一题' : '看总结',
          onPrimary: allChecked ? _finishQuestion : () {},
          primaryEnabled: allChecked,
        ),
      ],
    );
  }

  Widget _buildCheckBox(String cause) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final record = _recordOf(_currentBlock.questionId, cause);
    final selected = _checks[cause];
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
                    '「已解决」${record.solvedCount} / ${_settings.cureChecks} 次',
                    style: TextStyle(
                      fontSize: DesignTokens.reviewMetaFontSize,
                      color: palette.muted,
                    ),
                  ),
                if (record != null && record.isRecheckDue)
                  QmStatusPill.cause(QmCauseStatus.recheck),
              ],
            ),
            SizedBox(height: 8 * scale),
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
                    onPressed: () => setState(() => _checks[cause] = op),
                  ),
              ],
            ),
            if (selected == '不确定') ...[
              SizedBox(height: 6 * scale),
              Text(
                '选「不确定」不算：下次还要重新练这道题，再自查一次这个错因',
                style: TextStyle(
                  fontSize: DesignTokens.captionFontSize,
                  color: palette.muted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSummary() {
    final scale = qmScaleOf(context);
    return _centered(
      Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CompanionWidget(size: 72 * scale, message: '这一轮辛苦啦'),
          SizedBox(height: 10 * scale),
          _DetailBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '本轮复习总结',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 6 * scale),
                Text.rich(
                  TextSpan(
                    style: const TextStyle(fontSize: 14),
                    children: [
                      const TextSpan(text: '今天解决了 '),
                      TextSpan(
                        text: '$_curedNow',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const TextSpan(text: ' 个错因 · 还有 '),
                      TextSpan(
                        text: '$_summaryRemaining',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const TextSpan(text: ' 个未解决，留在列表里接着解决'),
                    ],
                  ),
                ),
                SizedBox(height: 8 * scale),
                if (_changes.isEmpty)
                  Text(
                    '这一轮还没有自查记录。',
                    style: TextStyle(
                      fontSize: DesignTokens.bodySmallFontSize,
                      color: DesignTokens.of(Theme.of(context).brightness)
                          .muted,
                    ),
                  )
                else
                  for (final c in _changes)
                    _KvRow(
                      label: '${c.subjectName} · ${c.cause}',
                      value:
                          '「${c.questionTitle}」：${c.before} → ${c.after}'
                          '${c.recheckDate != null ? ' · 下次复查 ${_fmtDate(c.recheckDate!)}（${_fmtMd(c.recheckDate!)}）' : ''}'
                          ' · ${c.note}',
                    ),
                SizedBox(height: 12 * scale),
                QmButton(
                  label: '回复习列表',
                  onPressed: _backToList,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 下拉（HTML `.nb-fsel`：36 高、13.5px、line-strong 边、圆角 10；
  /// 与错题本 `_styledDropdown` 同款）。
  Widget _styledDropdown<T>({
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
        borderRadius:
            BorderRadius.circular(DesignTokens.radiusLg * scale),
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
            constraints:
                BoxConstraints(minWidth: DesignTokens.reviewKvLabelWidth * scale),
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
