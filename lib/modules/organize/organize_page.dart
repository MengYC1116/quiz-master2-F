import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:quiz_master2/data/demo_data.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/widgets/widgets.dart';

/// 整理工作台（F 分段折叠式）
///
/// 定稿口径：
/// - 整个工作台是一个固定高度盒子（880，窄屏 720），盒内滚动，
///   队列 + 整题图 + 表单都在盒内，滚动条在盒子右边缘；外层页面不滚动。
/// - 待整理队列：左列固定高度滚动容器（>3 道时出容器边框 + 滚动条），
///   行显示标题 / 学科 / 试卷来源 / 待补充数量；当前题蓝色左边框；
///   上方搜索框只搜标题 / 学科 / 试卷；排序下拉默认时间降序。
/// - 上一题 / 下一题按当前排序循环切换，切换后队列自动滚动定位；
///   切换题目先自动保存当前表单，不丢已填内容；确认整理后按当前排序进下一题。
/// - 整题图点击弹出居中大图覆盖层（点图 / 遮罩 / Esc 关闭，滚轮缩放从 1.5 倍起，
///   支持拖动平移）；二层框高亮以文字标注保持可见。
/// - 表单字段顺序固定：学科（只读）→ 文件夹 → 试卷 → 知识点 → 错误类型
///   → 标签 → 答案 → 解析 → 备注；只有学科 + 文件夹必填，其余选填，未填显示“待补充”。
/// - 底部大按钮“确认整理，去下一道”；缺文件夹只拦下该题；确认后首次复习为
///   确认后 1 天（nextReview = 明天，reviewCount = 0），间隔 1/3/7/14 由复习模块推进。
/// - 批量整理：队列行复选框，勾选状态切换题目时保留；批量栏支持批量加标签、
///   批量加入文件夹、批量确认、批量删除（删除先确认“删了就没了，确定吗”）。
/// - 整理中可删题（先确认再删）；不能回修框（无“回修框”按钮）。
/// - 初始待整理队列取 repo.all() 中 isOrganized == false 且未归档的题。
class OrganizePage extends StatefulWidget {
  const OrganizePage({super.key, required this.repo});

  final QuestionRepository repo;

  @override
  State<OrganizePage> createState() => _OrganizePageState();
}

/// 排序方式：短名，无括号说明，默认时间降序。
enum _SortMode { timeDesc, timeAsc, subjectAsc, subjectDesc }

extension on _SortMode {
  String get label => switch (this) {
        _SortMode.timeDesc => '时间降序',
        _SortMode.timeAsc => '时间升序',
        _SortMode.subjectAsc => '学科首字母升序',
        _SortMode.subjectDesc => '学科首字母降序',
      };
}

/// 学科首字母（拼音首字母，用于学科排序）：数学 S / 英语 Y / 政治 Z。
const _subjectInitials = {'math': 'S', 'english': 'Y', 'politics': 'Z'};

class _OrganizePageState extends State<OrganizePage> {
  bool _loading = true;

  /// 待整理队列（主列表，未排序、未过滤）。
  List<Question> _queue = [];

  /// 当前正在整理的题 id。
  String? _currentId;

  /// 批量勾选的题 id：切换题目时保留。
  final Set<String> _selectedIds = {};

  _SortMode _sortMode = _SortMode.timeDesc;
  String _search = '';

  /// 本地可扩充的预置数据（新建文件夹 / 试卷 / 标签只存在本次会话的内存里，
  /// 题目本身的挂载关系随题目保存进库）。
  List<String> _folders = [...presetFolders];
  List<Exam> _exams = demoExams();
  List<String> _allTags = [...presetTags];
  List<KnowledgePoint> _knowledgePoints = demoKnowledgePoints();

  // ---- 当前题的表单状态 ----
  Set<String> _selectedFolders = {};
  String? _selectedExamId;
  Set<String> _selectedKpIds = {};
  Set<String> _selectedErrorTypes = {};
  List<String> _customErrorTypes = [];
  Set<String> _selectedTags = {};
  final _answerCtrl = TextEditingController();
  final _explanationCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  final _customErrorCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();

  final _boxScrollController = ScrollController();
  final _queueScrollController = ScrollController();

  /// 待补充清单点击定位用：文件夹字段的锚点。
  final _folderFieldKey = GlobalKey();
  final _knowledgeFieldKey = GlobalKey();
  final _errorFieldKey = GlobalKey();
  final _tagFieldKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _answerCtrl.dispose();
    _explanationCtrl.dispose();
    _notesCtrl.dispose();
    _customErrorCtrl.dispose();
    _searchCtrl.dispose();
    _boxScrollController.dispose();
    _queueScrollController.dispose();
    super.dispose();
  }

  // ---------- 数据加载 ----------

  Future<void> _load() async {
    // 待整理 = 未确认整理且未归档。确认整理会把 isOrganized 置 true，
    // 复习次数不动（首次复习为确认后 1 天），所以队列不能用 reviewCount 区分。
    final all = await widget.repo.all();
    final queue =
        all.where((q) => !q.isOrganized && !q.isArchived).toList();
    if (!mounted) return;
    setState(() {
      _queue = queue;
      _loading = false;
      // 题目上已有的文件夹若不在预置里，也收进可选列表，避免 chips 丢项。
      for (final q in queue) {
        for (final f in q.folderIds) {
          if (!_folders.contains(f)) _folders.add(f);
        }
        for (final t in q.tags) {
          if (!_allTags.contains(t)) _allTags.add(t);
        }
      }
    });
    if (_queue.isNotEmpty) _switchTo(_orderedQueue.first.id);
  }

  // ---------- 派生列表 ----------

  Question? get _current {
    if (_currentId == null) return null;
    for (final q in _queue) {
      if (q.id == _currentId) return q;
    }
    return null;
  }

  /// 按当前排序排好的队列（不过滤搜索）。
  List<Question> get _orderedQueue {
    final list = [..._queue];
    switch (_sortMode) {
      case _SortMode.timeDesc:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case _SortMode.timeAsc:
        list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      case _SortMode.subjectAsc:
        list.sort(_bySubjectAsc);
      case _SortMode.subjectDesc:
        list.sort((a, b) => _bySubjectAsc(b, a));
    }
    return list;
  }

  int _bySubjectAsc(Question a, Question b) {
    final ia = _subjectInitials[a.subjectId] ?? Subject.byId(a.subjectId).name;
    final ib = _subjectInitials[b.subjectId] ?? Subject.byId(b.subjectId).name;
    final c = ia.compareTo(ib);
    if (c != 0) return c;
    // 同学科内按时间降序，保持稳定。
    return b.createdAt.compareTo(a.createdAt);
  }

  /// 搜索过滤后的队列：只搜标题 / 学科 / 试卷，不搜题干。
  List<Question> get _displayedQueue {
    final ordered = _orderedQueue;
    final q = _search.trim();
    if (q.isEmpty) return ordered;
    return ordered.where((question) {
      final examName = _examName(question.examId);
      return question.title.contains(q) ||
          Subject.byId(question.subjectId).name.contains(q) ||
          examName.contains(q);
    }).toList();
  }

  String _examName(String? examId) {
    if (examId == null) return '';
    for (final e in _exams) {
      if (e.id == examId) return e.name;
    }
    return '';
  }

  /// 待补充数量：只统计必填项（学科 + 文件夹）。学科导入时已定，恒为已填，
  /// 所以实际只看文件夹：缺文件夹计 1 项。
  int _pendingCount(Question q) => q.folderIds.isEmpty ? 1 : 0;

  String _pendingLabel(Question q) =>
      _pendingCount(q) == 0 ? '必填已齐' : '待补充 1 项：文件夹';

  // ---------- 表单保存 / 载入 ----------

  /// 把当前表单状态拼成一道完整题目（直接构造，不用 copyWith，
  /// 以便试卷可从“已选”改回“不选”）。
  Question _buildUpdatedQuestion(Question base) {
    final fixedSelected =
        _selectedErrorTypes.where(ErrorTypes.fixed.contains).toList();
    final customSelected =
        _selectedErrorTypes.where(_customErrorTypes.contains).toList();
    return Question(
      id: base.id,
      title: base.title,
      subjectId: base.subjectId, // 学科只读：导入时选错自担，不可改。
      folderIds: _selectedFolders.toList(),
      examId: _selectedExamId,
      knowledgePointIds: _selectedKpIds.toList(),
      errorTypes: fixedSelected,
      customErrorTypes: [..._customErrorTypes, ...customSelected]
          .toSet()
          .toList(),
      tags: _selectedTags.toList(),
      answer: _answerCtrl.text.trim().isEmpty ? null : _answerCtrl.text.trim(),
      explanation: _explanationCtrl.text.trim().isEmpty
          ? null
          : _explanationCtrl.text.trim(),
      notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
      reviewStatus: base.reviewStatus,
      reviewCount: base.reviewCount,
      isOrganized: base.isOrganized,
      // 演示标记必须带上：直接构造时漏掉会默认 false，整理保存后
      // 该题就不再算演示题，“清空演示数据”删不掉它（D-23）。
      isDemo: base.isDemo,
      nextReview: base.nextReview,
      overdueDays: base.overdueDays,
      isFavorite: base.isFavorite,
      isArchived: base.isArchived,
      createdAt: base.createdAt,
      sliceKind: base.sliceKind,
      sliceText: base.sliceText,
    );
  }

  /// 保存当前表单到库，并同步回队列（不改变复习状态与下次复习时间）。
  Future<void> _saveCurrentForm() async {
    final current = _current;
    if (current == null) return;
    final updated = _buildUpdatedQuestion(current);
    await widget.repo.save(updated);
    if (!mounted) return;
    setState(() {
      final i = _queue.indexWhere((q) => q.id == current.id);
      if (i >= 0) _queue[i] = updated;
    });
  }

  void _loadForm(Question q) {
    _selectedFolders = q.folderIds.toSet();
    _selectedExamId = q.examId;
    _selectedKpIds = q.knowledgePointIds.toSet();
    _customErrorTypes = [...q.customErrorTypes];
    _selectedErrorTypes = {...q.errorTypes, ...q.customErrorTypes};
    _selectedTags = q.tags.toSet();
    _answerCtrl.text = q.answer ?? '';
    _explanationCtrl.text = q.explanation ?? '';
    _notesCtrl.text = q.notes ?? '';
    _customErrorCtrl.clear();
  }

  // ---------- 切换题目 ----------

  Future<void> _switchTo(String id) async {
    if (id == _currentId) return;
    // 切换题目先保存当前表单，不丢已填内容。
    await _saveCurrentForm();
    if (!mounted) return;
    final target = _queue.firstWhere((q) => q.id == id);
    setState(() {
      _currentId = id;
      _loadForm(target);
    });
    _scrollQueueToCurrent();
  }

  /// 切换后队列自动滚动定位当前题（行高约 64，jumpTo 近似实现）。
  void _scrollQueueToCurrent() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_queueScrollController.hasClients || _currentId == null) return;
      final list = _displayedQueue;
      final index = list.indexWhere((q) => q.id == _currentId);
      if (index < 0) return;
      const rowHeight = 64.0;
      final offset = index * rowHeight;
      final max = _queueScrollController.position.maxScrollExtent;
      _queueScrollController.jumpTo(offset.clamp(0.0, max));
    });
  }

  /// 上一题 / 下一题：按当前排序顺序切换，循环。
  Future<void> _move(int delta) async {
    final list =
        _displayedQueue.any((q) => q.id == _currentId) ? _displayedQueue : _orderedQueue;
    if (list.isEmpty) return;
    var index = list.indexWhere((q) => q.id == _currentId);
    if (index < 0) index = 0;
    final next = list[(index + delta) % list.length];
    await _switchTo(next.id);
  }

  // ---------- 确认整理 ----------

  DateTime _tomorrow() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day + 1);
  }

  /// 确认整理当前题：缺文件夹只拦下该题；确认后首次复习为确认后 1 天，
  /// reviewCount = 0，间隔 1/3/7/14 由复习模块推进。
  Future<void> _confirmCurrent() async {
    final current = _current;
    if (current == null) return;
    if (_selectedFolders.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先选个文件夹再确认吧，这道题还留在队列里')),
      );
      _scrollToField(_folderFieldKey);
      return;
    }
    final updated = _buildUpdatedQuestion(current).copyWith(
      reviewCount: 0,
      isOrganized: true,
      nextReview: _tomorrow(),
      reviewStatus: ReviewStatus.inReview,
      overdueDays: 0,
    );
    await widget.repo.save(updated);
    if (!mounted) return;
    // 按当前排序进下一题：取确认前排序里当前题的下一道。
    final ordered = _orderedQueue;
    final index = ordered.indexWhere((q) => q.id == current.id);
    final rest = ordered.where((q) => q.id != current.id).toList();
    String? nextId;
    if (rest.isNotEmpty) {
      nextId = index >= 0 && index < rest.length
          ? rest[index].id
          : rest.first.id;
    }
    setState(() {
      _queue.removeWhere((q) => q.id == current.id);
      _selectedIds.remove(current.id);
      _currentId = null;
    });
    if (nextId != null) {
      final next = _queue.firstWhere((q) => q.id == nextId);
      setState(() {
        _currentId = nextId;
        _loadForm(next);
      });
      _scrollQueueToCurrent();
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('「${current.title}」已整理，去下一道')),
      );
    }
  }

  // ---------- 删除 ----------

  Future<void> _deleteQuestion(Question q) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这道题？'),
        content: const Text('删了就没了，确定吗'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final wasCurrent = q.id == _currentId;
    final ordered = _orderedQueue;
    final index = ordered.indexWhere((e) => e.id == q.id);
    await widget.repo.delete(q);
    if (!mounted) return;
    final rest = ordered.where((e) => e.id != q.id).toList();
    setState(() {
      _queue.removeWhere((e) => e.id == q.id);
      _selectedIds.remove(q.id);
      if (wasCurrent) _currentId = null;
    });
    if (wasCurrent && rest.isNotEmpty) {
      final next = rest[index < rest.length ? index : 0];
      setState(() {
        _currentId = next.id;
        _loadForm(next);
      });
      _scrollQueueToCurrent();
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除「${q.title}」')),
      );
    }
  }

  // ---------- 批量整理 ----------

  Future<void> _batchAddTags() async {
    if (_selectedIds.isEmpty) return;
    final picked = await _pickChipsDialog(
      title: '批量加标签',
      options: _allTags,
      initial: const {},
      allowCreateLabel: '＋ 新建标签',
      onCreate: (name) async {
        setState(() => _allTags.add(name));
      },
    );
    if (picked == null || picked.isEmpty) return;
    await _saveCurrentForm();
    if (!mounted) return;
    for (final id in _selectedIds.toList()) {
      final q = _queue.firstWhere((e) => e.id == id);
      final merged = {...q.tags, ...picked}.toList();
      final updated = q.copyWith(tags: merged);
      await widget.repo.save(updated);
      final i = _queue.indexWhere((e) => e.id == id);
      if (i >= 0) _queue[i] = updated;
    }
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已给 ${_selectedIds.length} 道题加上标签')),
    );
  }

  Future<void> _batchAddFolders() async {
    if (_selectedIds.isEmpty) return;
    final picked = await _pickChipsDialog(
      title: '批量加入文件夹',
      options: _folders,
      initial: const {},
      allowCreateLabel: '＋ 添加新文件夹…',
      onCreate: (name) async {
        setState(() => _folders.add(name));
      },
    );
    if (picked == null || picked.isEmpty) return;
    await _saveCurrentForm();
    if (!mounted) return;
    for (final id in _selectedIds.toList()) {
      final q = _queue.firstWhere((e) => e.id == id);
      final merged = {...q.folderIds, ...picked}.toList();
      final updated = q.copyWith(folderIds: merged);
      await widget.repo.save(updated);
      final i = _queue.indexWhere((e) => e.id == id);
      if (i >= 0) _queue[i] = updated;
      // 若正在整理的那道在其中，同步表单状态。
      if (id == _currentId) {
        setState(() => _selectedFolders = merged.toSet());
      }
    }
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已把 ${_selectedIds.length} 道题加入文件夹')),
    );
  }

  /// 批量确认：缺文件夹的题跳过并提示，留在队列里。
  Future<void> _batchConfirm() async {
    if (_selectedIds.isEmpty) return;
    await _saveCurrentForm();
    if (!mounted) return;
    var skipped = 0;
    var done = 0;
    final confirmedIds = <String>[];
    for (final id in _selectedIds.toList()) {
      final q = _queue.firstWhere((e) => e.id == id);
      if (q.folderIds.isEmpty) {
        skipped++;
        continue;
      }
      final updated = q.copyWith(
        reviewCount: 0,
        nextReview: _tomorrow(),
        reviewStatus: ReviewStatus.inReview,
        overdueDays: 0,
      );
      await widget.repo.save(updated);
      confirmedIds.add(id);
      done++;
    }
    if (!mounted) return;
    setState(() {
      _queue.removeWhere((q) => confirmedIds.contains(q.id));
      _selectedIds.removeAll(confirmedIds);
      if (_currentId != null && confirmedIds.contains(_currentId)) {
        _currentId = null;
        if (_queue.isNotEmpty) {
          final next = _orderedQueue.first;
          _currentId = next.id;
          _loadForm(next);
        }
      }
    });
    _scrollQueueToCurrent();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(skipped > 0
            ? '已确认 $done 道；有 $skipped 道没选文件夹，已跳过，留在队列里'
            : '已批量确认 $done 道'),
      ),
    );
  }

  Future<void> _batchDelete() async {
    if (_selectedIds.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除选中的 ${_selectedIds.length} 道题？'),
        content: const Text('删了就没了，确定吗'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final ids = _selectedIds.toList();
    final wasCurrentDeleted = _currentId != null && ids.contains(_currentId);
    for (final id in ids) {
      final q = _queue.firstWhere((e) => e.id == id);
      await widget.repo.delete(q);
    }
    if (!mounted) return;
    setState(() {
      _queue.removeWhere((q) => ids.contains(q.id));
      _selectedIds.clear();
      if (wasCurrentDeleted) {
        _currentId = null;
        if (_queue.isNotEmpty) {
          final next = _orderedQueue.first;
          _currentId = next.id;
          _loadForm(next);
        }
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已删除 ${ids.length} 道题')),
    );
  }

  // ---------- 通用选择弹窗 ----------

  /// 多选 chips 弹窗（批量加标签 / 批量加入文件夹共用），可现场新建一项。
  Future<Set<String>?> _pickChipsDialog({
    required String title,
    required List<String> options,
    required Set<String> initial,
    required String allowCreateLabel,
    required Future<void> Function(String name) onCreate,
  }) async {
    final picked = {...initial};
    final nameCtrl = TextEditingController();
    var localOptions = [...options];
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final opt in localOptions)
                      FilterChip(
                        label: Text(opt),
                        selected: picked.contains(opt),
                        onSelected: (v) => setDialogState(() {
                          if (v) {
                            picked.add(opt);
                          } else {
                            picked.remove(opt);
                          }
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: nameCtrl,
                        decoration:
                            InputDecoration(labelText: allowCreateLabel),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () async {
                        final name = nameCtrl.text.trim();
                        if (name.isEmpty) return;
                        await onCreate(name);
                        setDialogState(() {
                          if (!localOptions.contains(name)) {
                            localOptions.add(name);
                          }
                          picked.add(name);
                          nameCtrl.clear();
                        });
                      },
                      child: const Text('新建'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(picked),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    nameCtrl.dispose();
    return result;
  }

  // ---------- 新建文件夹 / 试卷 / 标签 ----------

  Future<void> _addFolder() async {
    final name = await _askText(title: '添加新文件夹', label: '文件夹名');
    if (name == null || name.isEmpty) return;
    setState(() {
      if (!_folders.contains(name)) _folders.add(name);
      _selectedFolders = {..._selectedFolders, name};
    });
  }

  Future<void> _addExam() async {
    final nameCtrl = TextEditingController();
    DateTime? date;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('添加新试卷'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: '试卷名'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(date == null
                      ? '日期：未选'
                      : '日期：${date!.year}-${date!.month}-${date!.day}'),
                  const Spacer(),
                  TextButton(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) {
                        setDialogState(() => date = picked);
                      }
                    },
                    child: const Text('选择日期'),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(nameCtrl.text.trim()),
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    nameCtrl.dispose();
    if (name == null || name.isEmpty) return;
    final exam = Exam(
      id: 'exam-${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      date: date,
    );
    setState(() {
      _exams = [..._exams, exam];
      _selectedExamId = exam.id;
    });
  }

  Future<void> _addTag() async {
    final name = await _askText(title: '新建标签', label: '标签名');
    if (name == null || name.isEmpty) return;
    setState(() {
      if (!_allTags.contains(name)) _allTags.add(name);
      _selectedTags = {..._selectedTags, name};
    });
  }

  Future<String?> _askText({required String title, required String label}) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    ).whenComplete(ctrl.dispose);
  }

  // ---------- 大图覆盖层 ----------

  /// 整题图大图覆盖层：Dialog，点图 / 遮罩 / Esc 关闭；
  /// 滚轮缩放从 1.5 倍起，支持拖动平移；二层框高亮以文字标注保持可见。
  void _showZoomDialog(Question q) {
    final controller = TransformationController()
      ..value = Matrix4.diagonal3Values(1.5, 1.5, 1.0);
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            Navigator.of(ctx).pop();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Dialog(
          insetPadding: const EdgeInsets.all(32),
          child: GestureDetector(
            onTap: () => Navigator.of(ctx).pop(),
            child: Container(
              padding: const EdgeInsets.all(16),
              constraints: const BoxConstraints(maxWidth: 860),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(q.title,
                            style: Theme.of(context).textTheme.titleMedium),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 520,
                    child: InteractiveViewer(
                      transformationController: controller,
                      minScale: 1.5,
                      maxScale: 4.0,
                      panEnabled: true,
                      scaleEnabled: true,
                      child: QuestionSlice(question: q, maxHeight: 520),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Wrap(
                    spacing: 8,
                    children: [
                      InfoChip(label: '题干高亮'),
                      InfoChip(label: '选项高亮'),
                      InfoChip(label: '配图高亮'),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '滚轮缩放（1.5 倍起），拖动平移；点图 / 遮罩 / Esc 关闭',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ).whenComplete(controller.dispose);
  }

  void _scrollToField(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 300));
    }
  }

  void _goReview() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('复习模块尚未实现')),
    );
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    final isNarrow = MediaQuery.of(context).size.width < 900;
    // 盒子默认 880（窄屏 720），窗口矮时按可用高度收小，保证确认按钮
    // 在窗口内可达（默认 1280×720 窗口约剩 636 高）；不低于 320。
    final availableHeight = MediaQuery.of(context).size.height - 84;
    final boxHeight = math.min(
        isNarrow ? 720.0 : 880.0, math.max(320.0, availableHeight));
    final current = _current;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('整理工作台',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(width: 12),
              if (!_loading) Text('待整理 ${_queue.length} 道'),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.chevron_left),
                tooltip: '上一题',
                onPressed: _queue.length > 1 ? () => _move(-1) : null,
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                tooltip: '下一题',
                onPressed: _queue.length > 1 ? () => _move(1) : null,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: '删除这道题',
                onPressed:
                    current == null ? null : () => _deleteQuestion(current),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 固定高度盒子：盒内滚动，滚动条在盒子右边缘；外层页面不滚动。
          SizedBox(
            height: boxHeight,
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border.all(
                    color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Scrollbar(
                controller: _boxScrollController,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _boxScrollController,
                  padding: const EdgeInsets.all(16),
                  child: _loading
                      ? const SizedBox(
                          height: 400,
                          child: Center(child: CircularProgressIndicator()),
                        )
                      : _queue.isEmpty
                          ? SizedBox(
                              height: boxHeight - 64,
                              child: EmptyState(
                                message: '都整理完了，去复习吧',
                                actionLabel: '去复习',
                                onAction: _goReview,
                              ),
                            )
                          : isNarrow
                              ? Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    _buildQueuePanel(),
                                    const SizedBox(height: 16),
                                    _buildDetailColumn(current),
                                  ],
                                )
                              : Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(
                                      width: 320,
                                      child: _buildQueuePanel(),
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: _buildDetailColumn(current),
                                    ),
                                  ],
                                ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 队列面板（左列） ----------

  Widget _buildQueuePanel() {
    final displayed = _displayedQueue;
    final showBorder = displayed.length > 3;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _searchCtrl,
          decoration: const InputDecoration(
            hintText: '搜索标题 / 学科 / 试卷',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (v) => setState(() => _search = v),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text('待整理队列（${displayed.length}）'),
            const Spacer(),
            // 排序下拉：短名无括号说明，宽度不超过队列列宽。
            SizedBox(
              width: 168,
              child: DropdownButton<_SortMode>(
                value: _sortMode,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                items: [
                  for (final m in _SortMode.values)
                    DropdownMenuItem(value: m, child: Text(m.label)),
                ],
                onChanged: (m) {
                  if (m == null) return;
                  setState(() => _sortMode = m);
                  _scrollQueueToCurrent();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // 固定高度滚动容器：>3 道时出容器边框 + 滚动条。
        Container(
          height: 264,
          decoration: showBorder
              ? BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(8),
                )
              : null,
          child: displayed.isEmpty
              ? const Center(child: Text('没找到这道题，换个词试试'))
              : Scrollbar(
                  controller: _queueScrollController,
                  thumbVisibility: displayed.length > 3,
                  child: ListView.builder(
                    controller: _queueScrollController,
                    itemCount: displayed.length,
                    itemBuilder: (ctx, i) {
                      final q = displayed[i];
                      final isCurrent = q.id == _currentId;
                      final checked = _selectedIds.contains(q.id);
                      return InkWell(
                        onTap: () => _switchTo(q.id),
                        child: Container(
                          height: 64,
                          decoration: BoxDecoration(
                            border: Border(
                              left: BorderSide(
                                color: isCurrent
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.transparent,
                                width: 3,
                              ),
                            ),
                            color: isCurrent
                                ? Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withValues(alpha: 0.08)
                                : null,
                          ),
                          padding:
                              const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            children: [
                              Checkbox(
                                value: checked,
                                onChanged: (v) => setState(() {
                                  if (v == true) {
                                    _selectedIds.add(q.id);
                                  } else {
                                    _selectedIds.remove(q.id);
                                  }
                                }),
                              ),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      q.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontWeight: isCurrent
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${Subject.byId(q.subjectId).name} · ${_examName(q.examId).isEmpty ? '未指定试卷' : _examName(q.examId)} · ${_pendingLabel(q)}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
        // 批量栏：有勾选时出现；勾选状态切换题目时保留。
        if (_selectedIds.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _batchAddTags,
                child: Text('批量加标签（${_selectedIds.length}）'),
              ),
              OutlinedButton(
                onPressed: _batchAddFolders,
                child: const Text('批量加入文件夹'),
              ),
              FilledButton(
                onPressed: _batchConfirm,
                child: const Text('批量确认'),
              ),
              OutlinedButton(
                onPressed: _batchDelete,
                child: const Text('批量删除'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  // ---------- 右侧：整题图 + 表单 ----------

  Widget _buildDetailColumn(Question? current) {
    if (current == null) {
      return EmptyState(
        message: '都整理完了，去复习吧',
        actionLabel: '去复习',
        onAction: _goReview,
      );
    }
    final pendingFolder = _selectedFolders.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 待补充清单：可点击定位到对应字段。
        if (pendingFolder)
          Align(
            alignment: Alignment.centerLeft,
            child: ActionChip(
              label: const Text('待补充 1 项：文件夹（点我定位）'),
              onPressed: () => _scrollToField(_folderFieldKey),
            ),
          ),
        if (pendingFolder) const SizedBox(height: 12),
        // 整题图。
        QuestionSlice(
          question: current,
          maxHeight: 260,
          onTap: () => _showZoomDialog(current),
        ),
        const SizedBox(height: 4),
        const Row(
          children: [
            InfoChip(label: '题干高亮'),
            SizedBox(width: 6),
            InfoChip(label: '选项高亮'),
            SizedBox(width: 6),
            InfoChip(label: '配图高亮'),
            SizedBox(width: 8),
            Expanded(
              child: Text('点图放大查看，二层框高亮保持可见',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _buildForm(current),
        const SizedBox(height: 16),
        // 底部大按钮。
        FilledButton(
          onPressed: _confirmCurrent,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
            textStyle:
                const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          child: const Text('确认整理，去下一道'),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton.icon(
              onPressed: () => _move(-1),
              icon: const Icon(Icons.chevron_left),
              label: const Text('上一题'),
            ),
            TextButton.icon(
              onPressed: () => _move(1),
              icon: const Icon(Icons.chevron_right),
              label: const Text('下一题'),
            ),
          ],
        ),
      ],
    );
  }

  // ---------- 整理表单 ----------

  Widget _buildForm(Question q) {
    final subject = Subject.byId(q.subjectId);
    final kps = _knowledgePoints
        .where((kp) => kp.subjectId == q.subjectId)
        .toList();
    final chapters = <String>[];
    for (final kp in kps) {
      if (!chapters.contains(kp.chapter)) chapters.add(kp.chapter);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. 学科（只读显示，不可改，导入时选错自担）。
        _sectionTitle('学科'),
        Row(
          children: [
            SubjectLabel(subjectId: q.subjectId),
            const SizedBox(width: 8),
            Text(subject.name,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('导入时已选定，不可更改',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // 2. 文件夹（归类，多选）。
        _sectionTitle('文件夹（归类）', key: _folderFieldKey),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final f in _folders)
              FilterChip(
                label: Text(f),
                selected: _selectedFolders.contains(f),
                onSelected: (v) => setState(() {
                  if (v) {
                    _selectedFolders.add(f);
                  } else {
                    _selectedFolders.remove(f);
                  }
                }),
              ),
            ActionChip(
              label: const Text('＋ 添加新文件夹…'),
              onPressed: _addFolder,
            ),
          ],
        ),
        if (_selectedFolders.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('待补充：必填，请选个文件夹',
                style: TextStyle(fontSize: 12, color: Colors.red)),
          ),
        const SizedBox(height: 16),

        // 3. 试卷（来源，下拉）。
        _sectionTitle('试卷（来源）'),
        DropdownButtonFormField<String?>(
          value: _selectedExamId,
          isExpanded: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('不选试卷'),
            ),
            for (final e in _exams)
              DropdownMenuItem<String?>(
                value: e.id,
                child: Text(e.name),
              ),
            const DropdownMenuItem<String?>(
              value: '__add__',
              child: Text('＋ 添加新试卷…'),
            ),
          ],
          onChanged: (v) async {
            if (v == '__add__') {
              await _addExam();
              return;
            }
            setState(() => _selectedExamId = v);
          },
        ),
        if (_selectedExamId == null)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('待补充：选填，可不选',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        const SizedBox(height: 16),

        // 4. 知识点（学科 → 章节 → 知识点预置树，展开式多选）。
        _sectionTitle('知识点（已选 ${_selectedKpIds.length} 个）',
            key: _knowledgeFieldKey),
        if (kps.isEmpty)
          const Text('该学科暂无预置知识点，去学科管理添加',
              style: TextStyle(fontSize: 12, color: Colors.grey))
        else
          for (final chapter in chapters)
            ExpansionTile(
              title: Text(chapter),
              subtitle: Text(
                  '已选 ${kps.where((kp) => kp.chapter == chapter && _selectedKpIds.contains(kp.id)).length} 个'),
              children: [
                for (final kp
                    in kps.where((e) => e.chapter == chapter))
                  CheckboxListTile(
                    dense: true,
                    title: Text(kp.name),
                    value: _selectedKpIds.contains(kp.id),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _selectedKpIds.add(kp.id);
                      } else {
                        _selectedKpIds.remove(kp.id);
                      }
                    }),
                  ),
              ],
            ),
        const Text('树里没有的知识点不能在这里新建，去学科管理添加',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
        if (_selectedKpIds.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('待补充：选填，可不选',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        const SizedBox(height: 16),

        // 5. 错误类型（固定枚举 + 自定义，多选；选中显示为可点叉移除的 chips）。
        _sectionTitle('错误类型', key: _errorFieldKey),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in ErrorTypes.fixed)
              FilterChip(
                label: Text(t),
                selected: _selectedErrorTypes.contains(t),
                onSelected: (v) => setState(() {
                  if (v) {
                    _selectedErrorTypes.add(t);
                  } else {
                    _selectedErrorTypes.remove(t);
                  }
                }),
              ),
            for (final t in _customErrorTypes)
              InputChip(
                label: Text(t),
                selected: _selectedErrorTypes.contains(t),
                onSelected: (v) => setState(() {
                  if (v) {
                    _selectedErrorTypes.add(t);
                  } else {
                    _selectedErrorTypes.remove(t);
                  }
                }),
                onDeleted: () => setState(() {
                  _customErrorTypes.remove(t);
                  _selectedErrorTypes.remove(t);
                }),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _customErrorCtrl,
                decoration: const InputDecoration(
                  labelText: '自定义错误类型（只跟本题）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _addCustomErrorType(),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _addCustomErrorType,
              child: const Text('添加'),
            ),
          ],
        ),
        if (_selectedErrorTypes.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('待补充：选填，可不选',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        const SizedBox(height: 16),

        // 6. 标签（不限量，预置可点选，新建即选中）。
        _sectionTitle('标签', key: _tagFieldKey),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in _allTags)
              FilterChip(
                label: Text(t),
                selected: _selectedTags.contains(t),
                onSelected: (v) => setState(() {
                  if (v) {
                    _selectedTags.add(t);
                  } else {
                    _selectedTags.remove(t);
                  }
                }),
              ),
            ActionChip(
              label: const Text('＋ 新建标签'),
              onPressed: _addTag,
            ),
          ],
        ),
        if (_selectedTags.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('待补充：选填，可不选',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        const SizedBox(height: 16),

        // 7. 答案。
        _sectionTitle('答案'),
        TextField(
          controller: _answerCtrl,
          decoration: const InputDecoration(
            hintText: '待补充',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),

        // 8. 解析（可空）。
        _sectionTitle('解析'),
        TextField(
          controller: _explanationCtrl,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: '待补充（可空）',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),

        // 9. 备注（与答案 / 解析分开，多行，可空）。
        _sectionTitle('备注'),
        TextField(
          controller: _notesCtrl,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: '待补充（可空）',
            border: OutlineInputBorder(),
          ),
        ),
      ],
    );
  }

  void _addCustomErrorType() {
    final name = _customErrorCtrl.text.trim();
    if (name.isEmpty) return;
    setState(() {
      if (!_customErrorTypes.contains(name)) {
        _customErrorTypes.add(name);
      }
      _selectedErrorTypes.add(name);
      _customErrorCtrl.clear();
    });
  }

  Widget _sectionTitle(String text, {Key? key}) {
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
    );
  }
}
