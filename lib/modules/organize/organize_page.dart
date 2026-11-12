import 'package:flutter/material.dart';

import '../../data/repository.dart';
import '../../models/models.dart';
import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';

/// 整理工作台 H 布局：左图右表，整页滚动，无固定高度容器。
/// 队列藏在左上角“队列”按钮后，点开弹出 D 极简式队列层。
/// 表单里不显示学科（导入时已定，不可改）。
class OrganizePage extends StatefulWidget {
  const OrganizePage({
    super.key,
    required this.repo,
    required this.onOpenDetail,
    required this.onGoReview,
  });

  final QuestionRepository repo;
  final Future<void> Function(Question q, List<String> orderIds) onOpenDetail;
  final VoidCallback onGoReview;

  @override
  State<OrganizePage> createState() => _OrganizePageState();
}

class _OrganizePageState extends State<OrganizePage> {
  List<Question> _queue = [];
  int _index = 0;
  String _sort = 'timeDesc';
  bool _loading = true;

  List<Folder> _folders = [];
  List<Exam> _exams = [];
  List<KnowledgePoint> _kps = [];
  List<String> _allTags = [];
  List<String> _customTypesAll = [];

  // 表单状态（当前题）。
  List<String> _folderIds = [];
  String? _examId;
  List<String> _kpIds = [];
  List<String> _errorTypes = [];
  List<String> _customTypes = [];
  List<String> _tags = [];
  final _answerCtrl = TextEditingController();
  final _explanationCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  final _customTypeCtrl = TextEditingController();
  final _newTagCtrl = TextEditingController();

  // 各段默认开合：文件夹、修框切片展开，其余折起。
  bool _folderOpen = true;
  bool _slicesOpen = true;
  bool _sourceOpen = false;
  bool _classifyOpen = false;
  bool _answerOpen = false;

  Question? get _current =>
      _queue.isEmpty ? null : _queue[_index.clamp(0, _queue.length - 1)];

  List<String> get _orderIds => _queue.map((q) => q.id).toList();

  /// 学科首字母：数学 S / 英语 Y / 政治 Z。
  static String _subjectInitial(String subjectId) => switch (subjectId) {
        'english' => 'Y',
        'politics' => 'Z',
        _ => 'S',
      };

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _answerCtrl.dispose();
    _explanationCtrl.dispose();
    _notesCtrl.dispose();
    _customTypeCtrl.dispose();
    _newTagCtrl.dispose();
    super.dispose();
  }

  void _sortQueue() {
    switch (_sort) {
      case 'timeAsc':
        _queue.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      case 'subjectAsc':
        _queue.sort((a, b) {
          final c = _subjectInitial(a.subjectId)
              .compareTo(_subjectInitial(b.subjectId));
          return c != 0 ? c : b.createdAt.compareTo(a.createdAt);
        });
      case 'subjectDesc':
        _queue.sort((a, b) {
          final c = _subjectInitial(b.subjectId)
              .compareTo(_subjectInitial(a.subjectId));
          return c != 0 ? c : b.createdAt.compareTo(a.createdAt);
        });
      case 'timeDesc':
      default:
        _queue.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
  }

  Future<void> _refresh() async {
    final all = await widget.repo.all();
    final pending =
        all.where((q) => !q.isOrganized && !q.isArchived).toList();
    final exams = await widget.repo.exams();
    final kps = await widget.repo.knowledgePoints();
    final tags = await widget.repo.tags();
    final customs = <String>{};
    for (final q in all) {
      customs.addAll(q.customErrorTypes);
    }
    if (!mounted) return;
    setState(() {
      _queue = pending;
      _sortQueue();
      if (_index >= _queue.length) _index = _queue.isEmpty ? 0 : _queue.length - 1;
      _exams = exams;
      _kps = kps;
      _allTags = tags;
      _customTypesAll = customs.toList();
      _loading = false;
    });
    await _loadFolders();
    _loadForm();
  }

  Future<void> _loadFolders() async {
    final current = _current;
    if (current == null) return;
    final folders =
        await widget.repo.folders(subjectId: current.subjectId);
    if (!mounted) return;
    setState(() => _folders = folders);
  }

  void _loadForm() {
    final q = _current;
    if (q == null) return;
    setState(() {
      _folderIds = List.of(q.folderIds);
      _examId = q.examId;
      _kpIds = List.of(q.knowledgePointIds);
      _errorTypes = List.of(q.errorTypes);
      _customTypes = List.of(q.customErrorTypes);
      _tags = List.of(q.tags);
      _answerCtrl.text = q.answer ?? '';
      _explanationCtrl.text = q.explanation ?? '';
      _notesCtrl.text = q.notes ?? '';
    });
  }

  Question _formQuestion(Question q, {bool organized = false}) {
    final answer = _answerCtrl.text.trim();
    final explanation = _explanationCtrl.text.trim();
    final notes = _notesCtrl.text.trim();
    return q.copyWith(
      folderIds: _folderIds,
      examId: _examId,
      knowledgePointIds: _kpIds,
      errorTypes: _errorTypes,
      customErrorTypes: _customTypes,
      tags: _tags,
      answer: answer.isEmpty ? null : answer,
      explanation: explanation.isEmpty ? null : explanation,
      notes: notes.isEmpty ? null : notes,
      clearAnswer: answer.isEmpty,
      clearExplanation: explanation.isEmpty,
      clearNotes: notes.isEmpty,
      isOrganized: organized ? true : q.isOrganized,
    );
  }

  /// 切题自动保存。
  Future<void> _saveCurrent() async {
    final q = _current;
    if (q == null) return;
    final updated = _formQuestion(q);
    await widget.repo.save(updated);
    await widget.repo.syncCauseRecords(updated);
  }

  Future<void> _goTo(int next) async {
    if (next < 0 || next >= _queue.length || next == _index) return;
    await _saveCurrent();
    final currentId = _current?.id;
    if (!mounted) return;
    setState(() => _index = next);
    await _loadFolders();
    _loadForm();
    // 换题后若学科变了，文件夹列表已重载；表单按新题重填。
    if (currentId == _current?.id) return;
  }

  Future<void> _confirmCurrent() async {
    final q = _current;
    if (q == null) return;
    if (_folderIds.isEmpty) {
      _snack('先选文件夹');
      setState(() => _folderOpen = true);
      return;
    }
    final updated = _formQuestion(q, organized: true);
    await widget.repo.save(updated);
    await widget.repo.syncCauseRecords(updated);
    await widget.repo.saveRecentTask(
      kind: 'organize',
      subjectId: q.subjectId,
      title: q.title,
    );
    await _refresh();
  }

  Future<void> _deleteCurrent() async {
    final q = _current;
    if (q == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这道题'),
        content: const Text('删了就没了，确定吗？'),
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
    if (ok == true) {
      await widget.repo.delete(q);
      await _refresh();
    }
  }

  Future<void> _openDetail() async {
    final q = _current;
    if (q == null) return;
    await _saveCurrent();
    await widget.onOpenDetail(q, _orderIds);
    await _refresh();
  }

  Future<void> _addFolder() async {
    final q = _current;
    if (q == null) return;
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加新文件夹'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '文件夹名'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(ctx).pop(nameCtrl.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    if (_folders.any((f) => f.name == name)) {
      _snack('已经有了');
      return;
    }
    final folder = Folder(
      id: 'folder-${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      subjectId: q.subjectId,
      sortOrder: _folders.length,
    );
    await widget.repo.saveFolder(folder);
    await _loadFolders();
    setState(() {
      if (!_folderIds.contains(folder.id)) _folderIds.add(folder.id);
    });
  }

  Future<void> _addExam() async {
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加试卷'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '试卷名'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(ctx).pop(nameCtrl.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final exam = Exam(
      id: 'exam-${DateTime.now().millisecondsSinceEpoch}',
      name: name,
    );
    await widget.repo.addExam(exam);
    setState(() {
      _exams = [..._exams, exam];
      _examId = exam.id;
    });
  }

  Future<void> _openQueue() async {
    if (_queue.isEmpty) return;
    final jumped = await showDialog<String>(
      context: context,
      builder: (_) => _QueuePopup(
        repo: widget.repo,
        questions: List.of(_queue),
        currentId: _current?.id,
      ),
    );
    // 弹出层关闭即清空勾选（勾选状态只活在弹出层内）。
    await _refresh();
    if (jumped != null) {
      final idx = _queue.indexWhere((q) => q.id == jumped);
      if (idx >= 0 && mounted) {
        await _goTo(idx);
      }
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final q = _current;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : q == null
              ? EmptyState(
                  message: '都整理完了，去复习吧',
                  actionLabel: '去复习',
                  onAction: widget.onGoReview,
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(28, 20, 28, 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 顶栏：队列按钮（左上）+ 排序 + 上一道 / 下一道。
                      Row(
                        children: [
                          FilledButton.icon(
                            onPressed: _openQueue,
                            icon: const Icon(Icons.list_outlined, size: 18),
                            label: Text('队列 · 还剩 ${_queue.length} 道'),
                          ),
                          const Spacer(),
                          DropdownButton<String>(
                            value: _sort,
                            items: const [
                              DropdownMenuItem(
                                  value: 'timeDesc',
                                  child: Text('时间 新→旧')),
                              DropdownMenuItem(
                                  value: 'timeAsc',
                                  child: Text('时间 旧→新')),
                              DropdownMenuItem(
                                  value: 'subjectAsc',
                                  child: Text('学科首字母 A→Z')),
                              DropdownMenuItem(
                                  value: 'subjectDesc',
                                  child: Text('学科首字母 Z→A')),
                            ],
                            onChanged: (v) async {
                              if (v == null) return;
                              await _saveCurrent();
                              setState(() {
                                _sort = v;
                                _sortQueue();
                                _index = 0;
                              });
                              _loadForm();
                            },
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton(
                            onPressed:
                                _index > 0 ? () => _goTo(_index - 1) : null,
                            child: const Text('上一道'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: _index < _queue.length - 1
                                ? () => _goTo(_index + 1)
                                : null,
                            child: const Text('下一道'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '第 ${_index + 1} / ${_queue.length} 道',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      // H 布局：左图右表。
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 5,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                QuestionSlice(
                                  question: q,
                                  maxHeight: 480,
                                  // 预览定稿：点图弹出大居中放大浮层（1.5× 起始、滚轮缩放），
                                  // 不是进详情；进详情走下面的「进详情改」按钮。
                                  onTap: () =>
                                      showQuestionZoomDialog(context, q),
                                ),
                                const SizedBox(height: 8),
                                Text(q.title,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700)),
                                const SizedBox(height: 4),
                                SubjectLabel(subjectId: q.subjectId),
                                const SizedBox(height: 12),
                                OutlinedButton(
                                  onPressed: _openDetail,
                                  child: const Text('进详情改'),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 24),
                          Expanded(
                            flex: 6,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _section(
                                  title: '文件夹（归类）',
                                  requiredMark: true,
                                  open: _folderOpen,
                                  onToggle: () => setState(
                                      () => _folderOpen = !_folderOpen),
                                  child: _folderSection(),
                                ),
                                _section(
                                  title: '修框切片',
                                  open: _slicesOpen,
                                  onToggle: () => setState(
                                      () => _slicesOpen = !_slicesOpen),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      QuestionSlice(
                                          question: q, maxHeight: 200),
                                      const SizedBox(height: 8),
                                      const Text('整题切片 · 1 张',
                                          style: TextStyle(fontSize: 13)),
                                    ],
                                  ),
                                ),
                                _section(
                                  title: '来源（试卷）',
                                  open: _sourceOpen,
                                  onToggle: () => setState(
                                      () => _sourceOpen = !_sourceOpen),
                                  child: _examDropdown(),
                                ),
                                _section(
                                  title: '分类补充',
                                  open: _classifyOpen,
                                  onToggle: () => setState(() =>
                                      _classifyOpen = !_classifyOpen),
                                  child: _classifySection(),
                                ),
                                _section(
                                  title: '答案 · 解析 · 笔记',
                                  open: _answerOpen,
                                  onToggle: () => setState(
                                      () => _answerOpen = !_answerOpen),
                                  child: _answerSection(),
                                ),
                                const SizedBox(height: 16),
                                FilledButton(
                                  onPressed: _confirmCurrent,
                                  child: const Text('确认整理'),
                                ),
                                const SizedBox(height: 8),
                                OutlinedButton(
                                  onPressed: _deleteCurrent,
                                  child: const Text('删除这道题'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _section({
    required String title,
    bool requiredMark = false,
    required bool open,
    required VoidCallback onToggle,
    required Widget child,
  }) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(AppTheme.radius),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                  if (requiredMark) ...[
                    const SizedBox(width: 6),
                    const Text('*',
                        style: TextStyle(color: Colors.red, fontSize: 15)),
                  ],
                  const Spacer(),
                  Icon(open
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down),
                ],
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: child,
            ),
        ],
      ),
    );
  }

  Widget _folderSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_folderIds.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _folderIds.map((id) {
              final folder = _folders.firstWhere(
                (f) => f.id == id,
                orElse: () => Folder(
                    id: id, name: '已删文件夹', subjectId: _current!.subjectId),
              );
              return InputChip(
                label: Text(folder.name),
                onDeleted: () =>
                    setState(() => _folderIds.remove(id)),
              );
            }).toList(),
          ),
        if (_folderIds.isNotEmpty) const SizedBox(height: 8),
        DropdownButton<String>(
          value: null,
          hint: const Text('选择文件夹'),
          isExpanded: true,
          items: [
            ..._folders.map((f) => DropdownMenuItem(
                  value: f.id,
                  child: Text(f.name),
                )),
            const DropdownMenuItem(
              value: '__add__',
              child: Text('＋ 添加新文件夹…'),
            ),
          ],
          onChanged: (v) {
            if (v == null) return;
            if (v == '__add__') {
              _addFolder();
              return;
            }
            setState(() {
              if (!_folderIds.contains(v)) _folderIds.add(v);
            });
          },
        ),
        const SizedBox(height: 4),
        const Text('只列本科的文件夹。', style: TextStyle(fontSize: 12)),
      ],
    );
  }

  Widget _examDropdown() {
    return DropdownButton<String>(
      value: _examId,
      hint: const Text('选择试卷（可选）'),
      isExpanded: true,
      items: [
        ..._exams.map((e) => DropdownMenuItem(
              value: e.id,
              child: Text(e.name),
            )),
        const DropdownMenuItem(
          value: '__add__',
          child: Text('＋ 添加试卷…'),
        ),
      ],
      onChanged: (v) {
        if (v == null) return;
        if (v == '__add__') {
          _addExam();
          return;
        }
        setState(() => _examId = v);
      },
    );
  }

  Widget _classifySection() {
    final subjectKps =
        _kps.where((k) => k.subjectId == _current?.subjectId).toList();
    final chapters = <String>[];
    for (final k in subjectKps) {
      if (!chapters.contains(k.chapter)) chapters.add(k.chapter);
    }
    final customOptions = {..._customTypesAll, ..._customTypes}.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('知识点', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        if (subjectKps.isEmpty)
          const Text('这科还没知识点，去学科管理添加。',
              style: TextStyle(fontSize: 13)),
        for (final chapter in chapters) ...[
          Text(chapter, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: subjectKps
                .where((k) => k.chapter == chapter)
                .map((k) => FilterChip(
                      label: Text(k.name),
                      selected: _kpIds.contains(k.id),
                      onSelected: (on) => setState(() {
                        if (on) {
                          _kpIds.add(k.id);
                        } else {
                          _kpIds.remove(k.id);
                        }
                      }),
                    ))
                .toList(),
          ),
          const SizedBox(height: 8),
        ],
        const Divider(),
        const Text('错误类型', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ...ErrorTypes.fixed.map((t) => FilterChip(
                  label: Text(t),
                  selected: _errorTypes.contains(t),
                  onSelected: (on) => setState(() {
                    if (on) {
                      _errorTypes.add(t);
                    } else {
                      _errorTypes.remove(t);
                    }
                  }),
                )),
            ...customOptions.map((t) => FilterChip(
                  label: Text(t),
                  selected: _customTypes.contains(t),
                  onSelected: (on) => setState(() {
                    if (on) {
                      _customTypes.add(t);
                    } else {
                      _customTypes.remove(t);
                    }
                  }),
                )),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _customTypeCtrl,
                decoration:
                    const InputDecoration(hintText: '自定义错误类型'),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () {
                final name = _customTypeCtrl.text.trim();
                if (name.isEmpty) return;
                setState(() {
                  if (!_customTypes.contains(name)) _customTypes.add(name);
                  if (!_customTypesAll.contains(name)) {
                    _customTypesAll.add(name);
                  }
                  _customTypeCtrl.clear();
                });
              },
              child: const Text('添加'),
            ),
          ],
        ),
        const Divider(),
        const Text('标签', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in ['易错', '常考', '需重做'])
              FilterChip(
                label: Text(t),
                selected: _tags.contains(t),
                onSelected: (on) => setState(() {
                  if (on) {
                    _tags.add(t);
                  } else {
                    _tags.remove(t);
                  }
                }),
              ),
            for (final t in _allTags.where((t) =>
                !['易错', '常考', '需重做'].contains(t)))
              FilterChip(
                label: Text(t),
                selected: _tags.contains(t),
                onSelected: (on) => setState(() {
                  if (on) {
                    _tags.add(t);
                  } else {
                    _tags.remove(t);
                  }
                }),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _newTagCtrl,
                decoration: const InputDecoration(hintText: '新标签'),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () async {
                final name = _newTagCtrl.text.trim();
                if (name.isEmpty) return;
                await widget.repo.addTag(name);
                setState(() {
                  if (!_tags.contains(name)) _tags.add(name);
                  if (!_allTags.contains(name)) _allTags.add(name);
                  _newTagCtrl.clear();
                });
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _answerSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('答案', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        TextField(
          controller: _answerCtrl,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: '待补充',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        const Text('解析', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        TextField(
          controller: _explanationCtrl,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: '待补充',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        const Text('笔记', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        TextField(
          controller: _notesCtrl,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: '待补充',
            border: OutlineInputBorder(),
          ),
        ),
      ],
    );
  }
}

/// D 极简式队列弹出层：一行一道题（勾选框 + 题名 + 删除按钮），
/// 详情只在点中那道题时在下面展开一行；
/// 批量区是底部悬浮条，勾了题才出现。
/// 关闭弹出层即清空勾选（勾选状态只活在本层内）。
class _QueuePopup extends StatefulWidget {
  const _QueuePopup({
    required this.repo,
    required this.questions,
    required this.currentId,
  });

  final QuestionRepository repo;
  final List<Question> questions;
  final String? currentId;

  @override
  State<_QueuePopup> createState() => _QueuePopupState();
}

class _QueuePopupState extends State<_QueuePopup> {
  final _selected = <String>{};
  String? _expandedId;
  List<Question> _questions = [];
  List<Folder> _allFolders = [];
  List<String> _allTags = [];
  String? _batchFolderId;

  @override
  void initState() {
    super.initState();
    _questions = List.of(widget.questions);
    _loadMeta();
  }

  Future<void> _loadMeta() async {
    final folders = await widget.repo.folders();
    final tags = await widget.repo.tags();
    if (!mounted) return;
    setState(() {
      _allFolders = folders;
      _allTags = tags;
    });
  }

  List<Question> get _selectedQuestions =>
      _questions.where((q) => _selected.contains(q.id)).toList();

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _sliceKindLabel(String kind) => switch (kind) {
        'chart' => '图表题',
        'function' => '函数题',
        'timeline' => '时间轴',
        'limit' => '极限题',
        _ => '材料题',
      };

  String _dateText(DateTime d) => '${d.year}-${d.month}-${d.day}';

  Future<String?> _examName(String? examId) async {
    if (examId == null) return null;
    final exams = await widget.repo.exams();
    return exams
        .firstWhere((e) => e.id == examId,
            orElse: () => Exam(id: examId, name: '未知试卷'))
        .name;
  }

  Future<void> _deleteOne(Question q) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这道题'),
        content: const Text('删了就没了，确定吗？'),
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
    if (ok == true) {
      await widget.repo.delete(q);
      setState(() {
        _questions.removeWhere((x) => x.id == q.id);
        _selected.remove(q.id);
      });
    }
  }

  Future<void> _batchAddTags() async {
    final picked = <String>{};
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('批量打标签'),
          content: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in ['易错', '常考', '需重做', ..._allTags])
                FilterChip(
                  label: Text(t),
                  selected: picked.contains(t),
                  onSelected: (on) => setDialogState(() {
                    if (on) {
                      picked.add(t);
                    } else {
                      picked.remove(t);
                    }
                  }),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
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
    if (result == null || result.isEmpty) return;
    for (final q in _selectedQuestions) {
      final tags = {...q.tags, ...result}.toList();
      await widget.repo.save(q.copyWith(tags: tags));
    }
    _snack('已打标签');
  }

  Future<void> _batchAddFolder() async {
    final folderId = _batchFolderId;
    if (folderId == null) {
      _snack('先选文件夹');
      return;
    }
    final folder =
        _allFolders.firstWhere((f) => f.id == folderId);
    var applied = 0;
    var skipped = 0;
    for (final q in _selectedQuestions) {
      if (q.subjectId != folder.subjectId) {
        skipped++;
        continue;
      }
      if (!q.folderIds.contains(folderId)) {
        await widget.repo
            .save(q.copyWith(folderIds: [...q.folderIds, folderId]));
      }
      applied++;
    }
    setState(() {
      _questions = _questions.map((q) {
        if (_selected.contains(q.id) &&
            q.subjectId == folder.subjectId &&
            !q.folderIds.contains(folderId)) {
          return q.copyWith(folderIds: [...q.folderIds, folderId]);
        }
        return q;
      }).toList();
    });
    _snack(skipped > 0 ? '已加入 $applied 道，$skipped 道不是本科，跳过' : '已加入文件夹');
  }

  /// 批量确认：只拦住缺文件夹的题并提示，其余照常确认。
  /// 确认后关闭弹出层，父页刷新并进下一道。
  Future<void> _batchConfirm() async {
    final blocked =
        _selectedQuestions.where((q) => q.folderIds.isEmpty).toList();
    final ok = _selectedQuestions
        .where((q) => q.folderIds.isNotEmpty)
        .toList();
    for (final q in ok) {
      await widget.repo.save(q.copyWith(isOrganized: true));
    }
    if (blocked.isNotEmpty) {
      _snack('有 ${blocked.length} 道题没选文件夹，先补上');
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _batchDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量删除'),
        content: Text('删了就没了，确定吗？（${_selected.length} 道题）'),
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
    if (ok == true) {
      for (final q in _selectedQuestions) {
        await widget.repo.delete(q);
      }
      setState(() {
        _questions.removeWhere((q) => _selected.contains(q.id));
        _selected.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: 620,
        height: 560,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '队列 · 还剩 ${_questions.length} 道',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: _questions.length,
                itemBuilder: (ctx, i) {
                  final q = _questions[i];
                  final expanded = _expandedId == q.id;
                  final isCurrent = q.id == widget.currentId;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Checkbox(
                            value: _selected.contains(q.id),
                            onChanged: (on) => setState(() {
                              if (on == true) {
                                _selected.add(q.id);
                              } else {
                                _selected.remove(q.id);
                              }
                            }),
                          ),
                          Expanded(
                            child: InkWell(
                              onTap: () => setState(() {
                                _expandedId = expanded ? null : q.id;
                              }),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 8),
                                child: Text(
                                  q.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: isCurrent
                                        ? FontWeight.w800
                                        : FontWeight.normal,
                                    color: isCurrent
                                        ? AppTheme.accent
                                        : null,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '删除',
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () => _deleteOne(q),
                          ),
                        ],
                      ),
                      if (expanded)
                        FutureBuilder<String?>(
                          future: _examName(q.examId),
                          builder: (ctx, snap) {
                            final exam = snap.data ?? '未选试卷';
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(48, 0, 8, 8),
                              child: Text(
                                '${Subject.byId(q.subjectId).name} · '
                                '${_sliceKindLabel(q.sliceKind)} · '
                                '${_dateText(q.createdAt)} · $exam · '
                                '${q.folderIds.isEmpty ? '缺文件夹' : '已选文件夹'}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            );
                          },
                        ),
                      if (expanded)
                        Row(
                          children: [
                            const SizedBox(width: 48),
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(context).pop(q.id),
                              child: const Text('去整理这道'),
                            ),
                          ],
                        ),
                      const Divider(height: 1),
                    ],
                  );
                },
              ),
            ),
            // 底部悬浮批量条：勾了题才出现。
            if (_selected.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppTheme.lightFocusCard,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('已选 ${_selected.length} 道',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    OutlinedButton(
                      onPressed: _batchAddTags,
                      child: const Text('批量打标签'),
                    ),
                    DropdownButton<String>(
                      value: _batchFolderId,
                      hint: const Text('选文件夹'),
                      items: _allFolders
                          .map((f) => DropdownMenuItem(
                                value: f.id,
                                child: Text(
                                    '${Subject.byId(f.subjectId).name} · ${f.name}'),
                              ))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => _batchFolderId = v),
                    ),
                    OutlinedButton(
                      onPressed: _batchAddFolder,
                      child: const Text('加入该文件夹'),
                    ),
                    FilledButton(
                      onPressed: _batchConfirm,
                      child: const Text('确认整理'),
                    ),
                    OutlinedButton(
                      onPressed: _batchDelete,
                      child: const Text('删除'),
                    ),
                    TextButton(
                      onPressed: () => setState(() => _selected.clear()),
                      child: const Text('取消'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
