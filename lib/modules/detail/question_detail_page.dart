import 'package:flutter/material.dart';

import '../../data/repository.dart';
import '../../models/models.dart';
import '../../widgets/widgets.dart';

/// 题目详情（方案 2 分段折叠式）：大图在上，三段折叠
/// 答案解析 / 题目信息 / 复习记录，默认全折起。
class QuestionDetailPage extends StatefulWidget {
  const QuestionDetailPage({
    super.key,
    required this.repo,
    required this.questionId,
    required this.orderIds,
    required this.onChanged,
  });

  final QuestionRepository repo;
  final String questionId;
  final List<String> orderIds;
  final VoidCallback onChanged;

  @override
  State<QuestionDetailPage> createState() => _QuestionDetailPageState();
}

class _QuestionDetailPageState extends State<QuestionDetailPage> {
  bool _loading = true;
  Question? _q;
  late List<String> _orderIds;
  String _currentId = '';
  List<CauseRecord> _records = [];
  List<({String result, DateTime reviewedAt})> _history = [];
  List<Exam> _exams = [];
  List<Folder> _folders = [];
  List<String> _allTags = [];
  List<KnowledgePoint> _kps = [];

  bool _editing = false;
  bool _dirty = false;
  bool _answerVisible = false;
  final Set<String> _expanded = {};

  final _titleCtrl = TextEditingController();
  final _answerCtrl = TextEditingController();
  final _explanationCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  final _titleFocus = FocusNode();
  final _answerFocus = FocusNode();
  final _explanationFocus = FocusNode();
  final _notesFocus = FocusNode();
  Set<String> _editErrorTypes = {};
  Set<String> _editCustomTypes = {};
  Set<String> _editFolders = {};
  Set<String> _editTags = {};
  Set<String> _editKps = {};
  String? _editExamId;
  Question? _editBase;

  @override
  void initState() {
    super.initState();
    _orderIds = List.of(widget.orderIds);
    _currentId = widget.questionId;
    _load();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _answerCtrl.dispose();
    _explanationCtrl.dispose();
    _notesCtrl.dispose();
    _titleFocus.dispose();
    _answerFocus.dispose();
    _explanationFocus.dispose();
    _notesFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final q = await widget.repo.questionById(_currentId);
    final records =
        q == null ? <CauseRecord>[] : await widget.repo.causeRecordsFor(q.id);
    final history =
        q == null ? <({String result, DateTime reviewedAt})>[] : await widget.repo.reviewHistory(q.id);
    final exams = await widget.repo.exams();
    final folders = await widget.repo.folders();
    final tags = await widget.repo.tags();
    final kps = await widget.repo.knowledgePoints();
    if (!mounted) return;
    setState(() {
      _q = q;
      _records = records;
      _history = history;
      _exams = exams;
      _folders = folders;
      _allTags = tags;
      _kps = kps;
      _loading = false;
    });
  }

  String _fmtDate(DateTime d) => '${d.year}年${d.month}月${d.day}日';

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- 编辑 ----------

  void _enterEdit({String? focusField}) {
    final q = _q;
    if (q == null) return;
    _editBase = q;
    _titleCtrl.text = q.title;
    _answerCtrl.text = q.answer ?? '';
    _explanationCtrl.text = q.explanation ?? '';
    _notesCtrl.text = q.notes ?? '';
    _editErrorTypes = q.errorTypes.toSet();
    _editCustomTypes = q.customErrorTypes.toSet();
    _editFolders = q.folderIds.toSet();
    _editTags = q.tags.toSet();
    _editKps = q.knowledgePointIds.toSet();
    _editExamId = q.examId;
    setState(() {
      _editing = true;
      _dirty = false;
      _expanded.addAll(['answer', 'info', 'review']);
    });
    if (focusField != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        switch (focusField) {
          case 'title':
            _titleFocus.requestFocus();
          case 'answer':
            _answerFocus.requestFocus();
          case 'explanation':
            _explanationFocus.requestFocus();
          case 'notes':
            _notesFocus.requestFocus();
        }
      });
    }
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<void> _saveEdit() async {
    final base = _editBase;
    if (base == null) return;
    final customNew = _editCustomTypes
        .where((t) => !ErrorTypes.fixed.contains(t))
        .toList();
    final updated = Question(
      id: base.id,
      title: _titleCtrl.text.trim().isEmpty
          ? base.title
          : _titleCtrl.text.trim(),
      subjectId: base.subjectId,
      folderIds: _editFolders.toList(),
      examId: _editExamId,
      knowledgePointIds: _editKps.toList(),
      errorTypes: _editErrorTypes.toList(),
      customErrorTypes: customNew,
      tags: _editTags.toList(),
      answer: _answerCtrl.text.trim().isEmpty
          ? null
          : _answerCtrl.text.trim(),
      explanation: _explanationCtrl.text.trim().isEmpty
          ? null
          : _explanationCtrl.text.trim(),
      notes:
          _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
      reviewCount: base.reviewCount,
      isOrganized: base.isOrganized,
      isDemo: base.isDemo,
      isFavorite: base.isFavorite,
      isArchived: base.isArchived,
      reviewJoined: base.reviewJoined,
      createdAt: base.createdAt,
      sliceKind: base.sliceKind,
      sliceText: base.sliceText,
    );
    await widget.repo.save(updated);
    await widget.repo.syncCauseRecords(updated);
    setState(() {
      _editing = false;
      _dirty = false;
    });
    widget.onChanged();
    await _load();
  }

  /// 取消 / 返回时的脏检查：有改动提示保存，否则直接退出。
  /// 返回 true 表示可以离开。
  Future<bool> _checkDirtyAndLeave() async {
    if (!_editing || !_dirty) {
      if (_editing) setState(() => _editing = false);
      return true;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改还没保存'),
        content: const Text('保存这次修改吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('discard'),
            child: const Text('不保存'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (choice == 'save') {
      await _saveEdit();
      return true;
    }
    if (choice == 'discard') {
      setState(() {
        _editing = false;
        _dirty = false;
      });
      return true;
    }
    return false;
  }

  Future<bool> _onPop() async {
    if (_editing) return _checkDirtyAndLeave();
    return true;
  }

  // ---------- 操作 ----------

  Future<void> _toggleFavorite() async {
    final q = _q;
    if (q == null) return;
    await widget.repo.toggleFavorite(q);
    widget.onChanged();
    await _load();
  }

  Future<void> _toggleArchive() async {
    final q = _q;
    if (q == null) return;
    await widget.repo.archive(q, archived: !q.isArchived);
    widget.onChanged();
    await _load();
  }

  Future<void> _delete() async {
    final q = _q;
    if (q == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: const Text('删了就没了，确定吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final idx = _orderIds.indexOf(q.id);
    final nextId = idx >= 0 && idx + 1 < _orderIds.length
        ? _orderIds[idx + 1]
        : null;
    await widget.repo.delete(q);
    _orderIds.remove(q.id);
    widget.onChanged();
    if (nextId != null && nextId != q.id) {
      setState(() => _currentId = nextId);
      await _load();
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _goTo(String id) {
    setState(() {
      _currentId = id;
      _editing = false;
      _dirty = false;
      _answerVisible = false;
      _expanded.clear();
    });
    _load();
  }

  Future<void> _toggleReviewJoined() async {
    final q = _q;
    if (q == null) return;
    if (!q.reviewJoined) {
      if (q.allCauses.isEmpty) {
        _snack('先补错误类型');
        return;
      }
      final ok = await widget.repo.setReviewJoined(q, true);
      if (!ok) {
        _snack('先补错误类型');
        return;
      }
    } else {
      await widget.repo.setReviewJoined(q, false);
    }
    widget.onChanged();
    await _load();
  }

  // ---------- inline 新建 ----------

  Future<String?> _askText(String title, {String? hint}) async {
    final ctrl = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: hint ?? '输入名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return (value == null || value.isEmpty) ? null : value;
  }

  Future<void> _newTag() async {
    final name = await _askText('新建标签');
    if (name == null) return;
    await widget.repo.addTag(name);
    setState(() => _editTags.add(name));
    _markDirty();
    await _load();
    setState(() => _editTags.add(name));
  }

  Future<void> _newFolder() async {
    final q = _q;
    if (q == null) return;
    final name = await _askText('新建文件夹');
    if (name == null) return;
    if (!mounted) return;
    final tops = _folders
        .where((f) => f.subjectId == q.subjectId && f.parentId == null)
        .toList();
    String? parentId;
    if (tops.isNotEmpty) {
      parentId = await showDialog<String?>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('放在哪里'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('顶层'),
            ),
            for (final f in tops)
              SimpleDialogOption(
                onPressed: () => Navigator.of(ctx).pop(f.id),
                child: Text('作为「${f.name}」的子文件夹'),
              ),
          ],
        ),
      );
      // 点空白处关闭返回 null 与选“顶层”同义，都当顶层处理。
    }
    final id =
        'folder-${q.subjectId}-${DateTime.now().millisecondsSinceEpoch}';
    await widget.repo.saveFolder(Folder(
      id: id,
      name: name,
      subjectId: q.subjectId,
      parentId: parentId,
      sortOrder: 0,
    ));
    await _load();
    setState(() => _editFolders.add(id));
    _markDirty();
  }

  Future<void> _newKnowledgePoint() async {
    final q = _q;
    if (q == null) return;
    final chapters = _kps
        .where((k) => k.subjectId == q.subjectId)
        .map((k) => k.chapter)
        .toSet()
        .toList();
    String chapter = chapters.isEmpty ? '' : chapters.first;
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          return AlertDialog(
            title: const Text('新建知识点'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButton<String>(
                  value: chapter.isEmpty ? null : chapter,
                  hint: const Text('选择章节'),
                  isExpanded: true,
                  items: chapters
                      .map((c) =>
                          DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: (v) => setDlg(() => chapter = v ?? ''),
                ),
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  decoration:
                      const InputDecoration(hintText: '知识点名称'),
                  onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(ctx).pop(nameCtrl.text.trim()),
                child: const Text('确定'),
              ),
            ],
          );
        },
      ),
    );
    if (name == null || name.isEmpty || chapter.isEmpty) return;
    final id = 'kp-${q.subjectId}-${DateTime.now().millisecondsSinceEpoch}';
    await widget.repo.addKnowledgePoint(KnowledgePoint(
      id: id,
      subjectId: q.subjectId,
      chapter: chapter,
      name: name,
    ));
    await _load();
    setState(() => _editKps.add(id));
    _markDirty();
  }

  Future<void> _newExam() async {
    final name = await _askText('新建试卷');
    if (name == null) return;
    final id = 'exam-${DateTime.now().millisecondsSinceEpoch}';
    await widget.repo.addExam(Exam(id: id, name: name));
    await _load();
    setState(() => _editExamId = id);
    _markDirty();
  }

  Future<void> _newCustomErrorType() async {
    final name = await _askText('自定义错误类型');
    if (name == null) return;
    setState(() => _editCustomTypes.add(name));
    _markDirty();
  }

  // ---------- 放大看图 ----------

  void _showZoom() {
    final q = _q;
    if (q == null) return;
    showQuestionZoomDialog(context, q);
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator()));
    }
    final q = _q;
    if (q == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('题目详情')),
        body: const EmptyState(message: '这道题不存在了'),
      );
    }
    final idx = _orderIds.indexOf(q.id);
    final hasPrev = idx > 0;
    final hasNext = idx >= 0 && idx + 1 < _orderIds.length;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _onPop() && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () async {
              if (await _onPop() && context.mounted) {
                Navigator.of(context).pop();
              }
            },
          ),
          title: Text(_editing ? '编辑题目' : q.title),
          actions: [
            if (!_editing) ...[
              IconButton(
                tooltip: q.isFavorite ? '取消收藏' : '收藏',
                icon: Icon(q.isFavorite ? Icons.star : Icons.star_border,
                    color: q.isFavorite ? Colors.amber : null),
                onPressed: _toggleFavorite,
              ),
              IconButton(
                tooltip: q.isArchived ? '恢复' : '归档',
                icon: Icon(q.isArchived
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined),
                onPressed: _toggleArchive,
              ),
              IconButton(
                tooltip: '删除',
                icon: const Icon(Icons.delete_outline),
                onPressed: _delete,
              ),
              TextButton(
                onPressed: () => _enterEdit(),
                child: const Text('编辑'),
              ),
            ] else ...[
              TextButton(
                onPressed: () async {
                  if (await _checkDirtyAndLeave() && context.mounted) {
                    // 已在 _checkDirtyAndLeave 内处理保存/放弃
                  }
                },
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: _saveEdit,
                child: const Text('保存'),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_editing)
                    TextField(
                      controller: _titleCtrl,
                      focusNode: _titleFocus,
                      decoration:
                          const InputDecoration(labelText: '题名'),
                      onChanged: (_) => _markDirty(),
                    )
                  else
                    Row(
                      children: [
                        SubjectLabel(subjectId: q.subjectId),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(q.title,
                              style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ),
                  const SizedBox(height: 12),
                  QuestionSlice(
                    question: q,
                    maxHeight: 320,
                    onTap: _showZoom,
                  ),
                  const SizedBox(height: 8),
                  Text('点图放大，滚轮缩放',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 16),
                  _buildSection('answer', '答案解析',
                      _buildAnswerSection(q)),
                  _buildSection('info', '题目信息', _buildInfoSection(q)),
                  _buildSection(
                      'review', '复习记录', _buildReviewSection(q)),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: hasPrev
                              ? () => _goTo(_orderIds[idx - 1])
                              : null,
                          icon: const Icon(Icons.chevron_left, size: 18),
                          label: const Text('上一题'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: hasNext
                              ? () => _goTo(_orderIds[idx + 1])
                              : null,
                          icon: const Icon(Icons.chevron_right, size: 18),
                          label: const Text('下一题'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      '复习次数 ${q.reviewCount} 次',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSection(String key, String title, Widget body) {
    final open = _expanded.contains(key);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          ListTile(
            title: Text(title,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            trailing: Icon(open ? Icons.expand_less : Icons.expand_more),
            onTap: () => setState(() {
              if (open) {
                _expanded.remove(key);
              } else {
                _expanded.add(key);
              }
            }),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: body,
            ),
        ],
      ),
    );
  }

  Widget _supplement(String field, {String? label}) {
    return InkWell(
      onTap: () => _enterEdit(focusField: field),
      child: Text(
        label ?? '待补充',
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }

  Widget _buildAnswerSection(Question q) {
    if (_editing) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _answerCtrl,
            focusNode: _answerFocus,
            decoration: const InputDecoration(labelText: '答案'),
            maxLines: 3,
            onChanged: (_) => _markDirty(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _explanationCtrl,
            focusNode: _explanationFocus,
            decoration: const InputDecoration(labelText: '解析'),
            maxLines: 5,
            onChanged: (_) => _markDirty(),
          ),
        ],
      );
    }
    if (!_answerVisible) {
      return FilledButton(
        onPressed: () => setState(() => _answerVisible = true),
        child: const Text('看答案'),
      );
    }
    final hasAnswer = (q.answer ?? '').trim().isNotEmpty;
    final hasExplanation = (q.explanation ?? '').trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('答案', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        hasAnswer
            ? Text(q.answer!)
            : _supplement('answer'),
        const SizedBox(height: 12),
        const Text('解析', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        hasExplanation
            ? Text(q.explanation!)
            : _supplement('explanation'),
      ],
    );
  }

  Widget _infoRow(String label, Widget value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(label,
                style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(child: value),
        ],
      ),
    );
  }

  Widget _buildInfoSection(Question q) {
    final exam = q.examId == null
        ? null
        : _exams.firstWhere((e) => e.id == q.examId!,
            orElse: () => Exam(id: q.examId!, name: ''));
    if (_editing) {
      final subjectKps =
          _kps.where((k) => k.subjectId == q.subjectId).toList();
      final subjectFolders =
          _folders.where((f) => f.subjectId == q.subjectId).toList();
      final customTypes =
          _editCustomTypes.where((t) => !ErrorTypes.fixed.contains(t));
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _infoRow('学科', Text(Subject.byId(q.subjectId).name)),
          _infoRow(
            '试卷',
            Row(
              children: [
                Expanded(
                  child: DropdownButton<String?>(
                    value: _editExamId,
                    isExpanded: true,
                    hint: const Text('未关联试卷'),
                    items: [
                      const DropdownMenuItem<String?>(
                          value: null, child: Text('未关联试卷')),
                      for (final e in _exams)
                        DropdownMenuItem(value: e.id, child: Text(e.name)),
                    ],
                    onChanged: (v) {
                      setState(() => _editExamId = v);
                      _markDirty();
                    },
                  ),
                ),
                TextButton(onPressed: _newExam, child: const Text('新建')),
              ],
            ),
          ),
          _infoRow(
            '错误类型',
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final t in ErrorTypes.fixed)
                  FilterChip(
                    label: Text(t),
                    selected: _editErrorTypes.contains(t),
                    onSelected: (v) {
                      setState(() {
                        if (v) {
                          _editErrorTypes.add(t);
                        } else {
                          _editErrorTypes.remove(t);
                        }
                      });
                      _markDirty();
                    },
                  ),
                for (final t in customTypes)
                  FilterChip(
                    label: Text(t),
                    selected: true,
                    onSelected: (v) {
                      setState(() => _editCustomTypes.remove(t));
                      _markDirty();
                    },
                  ),
                ActionChip(
                  label: const Text('＋自定义'),
                  onPressed: _newCustomErrorType,
                ),
              ],
            ),
          ),
          _infoRow(
            '文件夹',
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final f in subjectFolders)
                  FilterChip(
                    label: Text(f.name),
                    selected: _editFolders.contains(f.id),
                    onSelected: (v) {
                      setState(() {
                        if (v) {
                          _editFolders.add(f.id);
                        } else {
                          _editFolders.remove(f.id);
                        }
                      });
                      _markDirty();
                    },
                  ),
                ActionChip(
                  label: const Text('＋新建'),
                  onPressed: _newFolder,
                ),
              ],
            ),
          ),
          _infoRow(
            '知识点',
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final kp in subjectKps)
                  FilterChip(
                    label: Text('${kp.chapter} · ${kp.name}'),
                    selected: _editKps.contains(kp.id),
                    onSelected: (v) {
                      setState(() {
                        if (v) {
                          _editKps.add(kp.id);
                        } else {
                          _editKps.remove(kp.id);
                        }
                      });
                      _markDirty();
                    },
                  ),
                ActionChip(
                  label: const Text('＋新建'),
                  onPressed: _newKnowledgePoint,
                ),
              ],
            ),
          ),
          _infoRow(
            '标签',
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final t in _allTags)
                  FilterChip(
                    label: Text(t),
                    selected: _editTags.contains(t),
                    onSelected: (v) {
                      setState(() {
                        if (v) {
                          _editTags.add(t);
                        } else {
                          _editTags.remove(t);
                        }
                      });
                      _markDirty();
                    },
                  ),
                ActionChip(
                  label: const Text('＋新建'),
                  onPressed: _newTag,
                ),
              ],
            ),
          ),
          TextField(
            controller: _notesCtrl,
            focusNode: _notesFocus,
            decoration: const InputDecoration(labelText: '备注'),
            maxLines: 3,
            onChanged: (_) => _markDirty(),
          ),
        ],
      );
    }
    final folders =
        _folders.where((f) => q.folderIds.contains(f.id)).toList();
    final kps = _kps.where((k) => q.knowledgePointIds.contains(k.id)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _infoRow('学科', Text(Subject.byId(q.subjectId).name)),
        _infoRow(
          '来源',
          Text(
            exam == null || exam.name.isEmpty
                ? '未关联试卷 · ${_fmtDate(q.createdAt)}'
                : '${exam.name} · ${_fmtDate(q.createdAt)}',
          ),
        ),
        _infoRow(
          '错误类型',
          q.allCauses.isEmpty
              ? _supplement('errorTypes', label: '待补充')
              : Wrap(
                  spacing: 6,
                  children: [
                    for (final t in q.allCauses) InfoChip(label: t),
                  ],
                ),
        ),
        _infoRow(
          '文件夹',
          folders.isEmpty
              ? _supplement('folders', label: '待补充')
              : Wrap(
                  spacing: 6,
                  children: [
                    for (final f in folders) InfoChip(label: f.name),
                  ],
                ),
        ),
        _infoRow(
          '知识点',
          kps.isEmpty
              ? _supplement('knowledgePoints', label: '待补充')
              : Wrap(
                  spacing: 6,
                  children: [
                    for (final kp in kps)
                      InfoChip(label: '${kp.chapter} · ${kp.name}'),
                  ],
                ),
        ),
        _infoRow(
          '标签',
          q.tags.isEmpty
              ? _supplement('tags', label: '待补充')
              : Wrap(
                  spacing: 6,
                  children: [for (final t in q.tags) InfoChip(label: t)],
                ),
        ),
        _infoRow(
          '备注',
          (q.notes ?? '').trim().isEmpty
              ? _supplement('notes', label: '待补充')
              : Text(q.notes!),
        ),
      ],
    );
  }

  Widget _buildReviewSection(Question q) {
    final canJoin = q.isOrganized || q.isArchived;
    String historyLabel(String r) => switch (r) {
          'solved' => '已解决',
          'unsolved' => '未解决',
          _ => '不确定',
        };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (canJoin)
          FilledButton(
            onPressed: _toggleReviewJoined,
            child: Text(q.reviewJoined ? '取消加入复习' : '加入复习'),
          )
        else
          Text('未整理的题不能加入复习',
              style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        if (_records.isEmpty)
          const Text('还没有复习记录')
        else
          for (final r in _records)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      InfoChip(label: r.cause),
                      const SizedBox(width: 8),
                      Text(r.status.label,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700)),
                      const Spacer(),
                      Text('解决次数 ${r.solvedCount}',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    r.recheckDate == null
                        ? '下次复查：—'
                        : '下次复查：${_fmtDate(r.recheckDate!)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (r.remedyHistory.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text('补救：${r.remedyHistory.first}',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ],
              ),
            ),
        if (_history.isNotEmpty) ...[
          const Divider(),
          const Text('自查历史',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          for (final h in _history.take(5))
            Text(
              '${_fmtDate(h.reviewedAt)} · ${historyLabel(h.result)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ],
    );
  }
}
