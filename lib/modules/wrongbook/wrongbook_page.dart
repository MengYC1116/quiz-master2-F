import 'package:flutter/material.dart';

import '../../data/repository.dart';
import '../../models/models.dart';
import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';

/// 错题本：书架 → 目录页 → 题目列表（同一路由 /wrongbook）。
/// 已归档经顶部入口进跨学科列表。
class WrongbookPage extends StatefulWidget {
  const WrongbookPage({
    super.key,
    required this.repo,
    this.initialSubjectId,
    this.filterCause,
    this.filterKnowledgePointId,
    required this.onOpenHome,
    required this.onOpenDetail,
    required this.onGoReview,
  });

  final QuestionRepository repo;
  final String? initialSubjectId;
  final String? filterCause;
  final String? filterKnowledgePointId;
  final VoidCallback onOpenHome;
  final Future<void> Function(Question q, List<String> orderIds) onOpenDetail;
  final void Function({String? subjectId}) onGoReview;

  @override
  State<WrongbookPage> createState() => _WrongbookPageState();
}

enum _View { shelf, directory, list, archived }

class _WrongbookPageState extends State<WrongbookPage> {
  bool _loading = true;
  List<Subject> _subjects = Subject.all;
  List<Question> _questions = [];
  List<Folder> _folders = [];
  List<Exam> _exams = [];
  List<String> _allTags = [];
  List<KnowledgePoint> _kps = [];
  Map<String, (int, int, int)> _counts = {};
  Map<String, List<CauseRecord>> _recordsByQ = {};

  _View _view = _View.shelf;
  String? _subjectId;
  String? _folderId;
  int _shelfPage = 0;

  // 目录页
  final Set<String> _expandedFolders = {};
  String _folderSearch = '';
  bool _selectingMove = false;
  final Set<String> _moveSelection = {};

  // 列表页
  String _search = '';
  String? _filterExamId;
  String? _filterErrorType;
  String _filterCauseStatus = 'all'; // all / pending / inProgress / solved / recheck
  String? _filterCauseName;
  bool _filterFavorite = false;
  final Set<String> _filterTags = {};
  final Set<String> _filterKpIds = {};
  bool _filterOpen = false;
  String _sort = 'new'; // new / old / subject
  int _pageSize = 10;
  int _page = 0;
  String _viewMode = 'large'; // large / compact
  bool _batchMode = false;
  final Set<String> _selected = {};

  final _searchCtrl = TextEditingController();
  final _folderSearchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _filterCauseName = widget.filterCause;
    if (widget.filterKnowledgePointId != null) {
      _filterKpIds.add(widget.filterKnowledgePointId!);
    }
    if (widget.initialSubjectId != null) {
      _subjectId = widget.initialSubjectId;
      _view = _View.directory;
    } else if (widget.filterCause != null ||
        widget.filterKnowledgePointId != null) {
      _view = _View.list;
    }
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _folderSearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final subjects = await widget.repo.subjects();
    final questions = await widget.repo.all(includeArchived: true);
    final folders = await widget.repo.folders();
    final exams = await widget.repo.exams();
    final tags = await widget.repo.tags();
    final kps = await widget.repo.knowledgePoints();
    final counts = await widget.repo.subjectCounts();
    final records = await widget.repo.causeRecords();
    final settings = await widget.repo.settings();
    final byQ = <String, List<CauseRecord>>{};
    for (final r in records) {
      (byQ[r.questionId] ??= []).add(r);
    }
    if (!mounted) return;
    setState(() {
      _subjects = subjects.isEmpty ? Subject.all : subjects;
      _questions = questions;
      _folders = folders;
      _exams = exams;
      _allTags = tags;
      _kps = kps;
      _counts = counts;
      _recordsByQ = byQ;
      _pageSize = settings.pageSize;
      _viewMode = settings.wrongbookView;
      _sort = settings.wrongbookSort;
      _loading = false;
    });
  }

  // ---------- 派生数据 ----------

  List<Folder> _subjectFolders(String subjectId) =>
      _folders.where((f) => f.subjectId == subjectId).toList();

  List<Folder> _topFolders(String subjectId) => _subjectFolders(subjectId)
      .where((f) => f.parentId == null)
      .toList();

  List<Folder> _subFolders(String parentId) =>
      _folders.where((f) => f.parentId == parentId).toList();

  /// 文件夹子树 id（含自己与子文件夹）。
  Set<String> _subtreeIds(String folderId) {
    final ids = {folderId};
    for (final sub in _subFolders(folderId)) {
      ids.addAll(_subtreeIds(sub.id));
    }
    return ids;
  }

  int _folderCount(String folderId) {
    final ids = _subtreeIds(folderId);
    return _questions
        .where((q) =>
            !q.isArchived && q.folderIds.any((id) => ids.contains(id)))
        .length;
  }

  /// 删文件夹时会跟着删的题数：全部文件夹都在该子树里的题。
  int _folderDeleteCount(String folderId) {
    final ids = _subtreeIds(folderId);
    return _questions
        .where((q) =>
            q.folderIds.isNotEmpty &&
            q.folderIds.every((id) => ids.contains(id)))
        .length;
  }

  bool _isMastered(Question q) {
    final rs = _recordsByQ[q.id];
    if (rs == null || rs.isEmpty) return false;
    return rs.every((r) => r.status == CauseStatus.solved) &&
        !rs.any((r) => r.isRecheckDue);
  }

  String? _causeStatusOf(Question q) {
    final rs = _recordsByQ[q.id];
    if (rs == null || rs.isEmpty) return 'pending';
    if (rs.any((r) => r.isRecheckDue)) return 'recheck';
    if (rs.any((r) => r.status == CauseStatus.pending)) return 'pending';
    if (rs.any((r) => r.status == CauseStatus.inProgress)) {
      return 'inProgress';
    }
    return 'solved';
  }

  String? _nextRecheckOf(Question q) {
    final rs = _recordsByQ[q.id];
    if (rs == null) return null;
    DateTime? next;
    for (final r in rs) {
      if (r.recheckDate == null) continue;
      if (next == null || r.recheckDate!.isBefore(next)) {
        next = r.recheckDate;
      }
    }
    if (next == null) return null;
    return '${next.month}月${next.day}日';
  }

  List<Question> _filteredAll() {
    var list = _questions;
    if (_view == _View.archived) {
      list = list.where((q) => q.isArchived).toList();
    } else {
      // 错题本只收已整理过的题；未整理的题在整理工作台排队，不进错题本。
      // （封面题数也是这个口径，两边必须一致。）
      list = list.where((q) => q.isOrganized && !q.isArchived).toList();
      if (_subjectId != null) {
        list = list.where((q) => q.subjectId == _subjectId).toList();
      }
      if (_folderId != null) {
        final ids = _subtreeIds(_folderId!);
        list = list
            .where((q) => q.folderIds.any((id) => ids.contains(id)))
            .toList();
      }
      // 已掌握默认不显示（错因状态筛到已解决 / 复查时才显示）。
      if (_filterCauseStatus == 'all') {
        list = list.where((q) => !_isMastered(q)).toList();
      }
    }
    if (_search.trim().isNotEmpty) {
      final kw = _search.trim();
      list = list
          .where((q) =>
              q.title.contains(kw) || q.tags.any((t) => t.contains(kw)))
          .toList();
    }
    if (_filterExamId != null) {
      list = list.where((q) => q.examId == _filterExamId).toList();
    }
    if (_filterErrorType != null) {
      list = list
          .where((q) => q.allCauses.contains(_filterErrorType))
          .toList();
    }
    if (_filterCauseName != null) {
      list =
          list.where((q) => q.allCauses.contains(_filterCauseName)).toList();
    }
    if (_filterKpIds.isNotEmpty) {
      list = list
          .where((q) =>
              q.knowledgePointIds.any((id) => _filterKpIds.contains(id)))
          .toList();
    }
    if (_filterTags.isNotEmpty) {
      list = list
          .where((q) => q.tags.any((t) => _filterTags.contains(t)))
          .toList();
    }
    if (_filterFavorite) {
      list = list.where((q) => q.isFavorite).toList();
    }
    if (_view != _View.archived) {
      switch (_filterCauseStatus) {
        case 'pending':
          list = list
              .where((q) => _causeStatusOf(q) == 'pending')
              .toList();
        case 'inProgress':
          list = list
              .where((q) => _causeStatusOf(q) == 'inProgress')
              .toList();
        case 'solved':
          list = list
              .where((q) =>
                  _causeStatusOf(q) == 'solved' ||
                  _causeStatusOf(q) == 'recheck')
              .toList();
        case 'recheck':
          list = list
              .where((q) => _causeStatusOf(q) == 'recheck')
              .toList();
      }
    }
    switch (_sort) {
      case 'old':
        list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      case 'subject':
        list.sort((a, b) {
          final ia = Subject.all.indexWhere((s) => s.id == a.subjectId);
          final ib = Subject.all.indexWhere((s) => s.id == b.subjectId);
          if (ia != ib) return ia.compareTo(ib);
          return b.createdAt.compareTo(a.createdAt);
        });
      default:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return list;
  }

  int _activeFilterCount() {
    var n = 0;
    if (_filterExamId != null) n++;
    if (_filterErrorType != null) n++;
    if (_filterCauseStatus != 'all') n++;
    if (_filterCauseName != null) n++;
    if (_filterFavorite) n++;
    if (_filterTags.isNotEmpty) n++;
    if (_filterKpIds.isNotEmpty) n++;
    return n;
  }

  void _resetFilters() {
    setState(() {
      _search = '';
      _searchCtrl.clear();
      _filterExamId = null;
      _filterErrorType = null;
      _filterCauseStatus = 'all';
      _filterCauseName = null;
      _filterFavorite = false;
      _filterTags.clear();
      _filterKpIds.clear();
      _sort = 'new';
      _folderId = null;
      _page = 0;
      _selected.clear();
    });
  }

  void _openList({String? subjectId, String? folderId}) {
    setState(() {
      _subjectId = subjectId ?? _subjectId;
      _folderId = folderId;
      _view = _View.list;
      _page = 0;
      _selected.clear();
      _batchMode = false;
    });
  }

  void _openDirectory(String subjectId) {
    setState(() {
      _subjectId = subjectId;
      _view = _View.directory;
      _expandedFolders.clear();
      _folderSearch = '';
      _folderSearchCtrl.clear();
      _selectingMove = false;
      _moveSelection.clear();
    });
  }

  void _openShelf() {
    setState(() {
      _view = _View.shelf;
      _subjectId = null;
      _folderId = null;
      _shelfPage = 0;
    });
  }

  // ---------- 通用小组件 ----------

  Future<bool> _confirm(String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(message),
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
    return ok ?? false;
  }

  Future<String?> _askText(String title, {String? initial}) async {
    final ctrl = TextEditingController(text: initial ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入名称'),
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

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- 文件夹操作 ----------

  Future<void> _addFolder({String? parentId}) async {
    final subjectId = _subjectId;
    if (subjectId == null) return;
    final name = await _askText(parentId == null ? '新建文件夹' : '新建子文件夹');
    if (name == null) return;
    final siblings = parentId == null
        ? _topFolders(subjectId)
        : _subFolders(parentId);
    if (siblings.any((f) => f.name == name)) {
      _snack('已经有了');
      return;
    }
    final maxOrder = siblings.isEmpty
        ? 0
        : siblings.map((f) => f.sortOrder).reduce((a, b) => a > b ? a : b);
    await widget.repo.saveFolder(Folder(
      id: 'folder-$subjectId-${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      subjectId: subjectId,
      parentId: parentId,
      sortOrder: maxOrder + 10,
    ));
    await _load();
  }

  Future<void> _renameFolder(Folder f) async {
    final name = await _askText('重命名文件夹', initial: f.name);
    if (name == null || name == f.name) return;
    final siblings = f.parentId == null
        ? _topFolders(f.subjectId)
        : _subFolders(f.parentId!);
    if (siblings.any((x) => x.id != f.id && x.name == name)) {
      _snack('已经有了');
      return;
    }
    await widget.repo.saveFolder(Folder(
      id: f.id,
      name: name,
      subjectId: f.subjectId,
      parentId: f.parentId,
      sortOrder: f.sortOrder,
    ));
    await _load();
  }

  Future<void> _deleteFolder(Folder f) async {
    final n = _folderDeleteCount(f.id);
    final ok = await _confirm(
        '删除这个文件夹会删掉其中 $n 道题（只在这个文件夹里的），确定吗？');
    if (!ok) return;
    await widget.repo.deleteFolder(f);
    await _load();
  }

  Future<void> _moveFoldersToTarget(
      List<Folder> folders, String? targetParentId) async {
    for (final f in folders) {
      if (targetParentId != null) {
        // 不能移到自己或自己子文件夹下面。
        if (targetParentId == f.id ||
            _subtreeIds(f.id).contains(targetParentId)) {
          _snack('不能移到自己下面');
          continue;
        }
        // 只一层子文件夹：目标必须是顶层文件夹。
        final target =
            _folders.firstWhere((x) => x.id == targetParentId);
        if (target.parentId != null) {
          _snack('子文件夹只能有一层');
          continue;
        }
      }
      final siblings = targetParentId == null
          ? _topFolders(f.subjectId)
          : _subFolders(targetParentId);
      final maxOrder = siblings.isEmpty
          ? 0
          : siblings.map((x) => x.sortOrder).reduce((a, b) => a > b ? a : b);
      await widget.repo.saveFolder(Folder(
        id: f.id,
        name: f.name,
        subjectId: f.subjectId,
        parentId: targetParentId,
        sortOrder: maxOrder + 10,
      ));
    }
    setState(() {
      _selectingMove = false;
      _moveSelection.clear();
    });
    await _load();
  }

  Future<void> _pickMoveTarget(List<Folder> folders) async {
    final subjectId = _subjectId;
    if (subjectId == null) return;
    final tops = _topFolders(subjectId);
    final target = await showDialog<String?>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('移到'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('__top__'),
            child: const Text('顶层'),
          ),
          for (final f in tops)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(f.id),
              child: Text(f.name),
            ),
        ],
      ),
    );
    if (target == null) return;
    await _moveFoldersToTarget(
        folders, target == '__top__' ? null : target);
  }

  Future<void> _reorderTopFolder(Folder dragged, int toIndex) async {
    final subjectId = _subjectId;
    if (subjectId == null) return;
    final tops = _topFolders(subjectId);
    if (dragged.parentId != null) return;
    tops.removeWhere((f) => f.id == dragged.id);
    final idx = toIndex.clamp(0, tops.length);
    tops.insert(idx, dragged);
    for (var i = 0; i < tops.length; i++) {
      await widget.repo.saveFolder(Folder(
        id: tops[i].id,
        name: tops[i].name,
        subjectId: tops[i].subjectId,
        parentId: tops[i].parentId,
        sortOrder: i * 10,
      ));
    }
    await _load();
  }

  // ---------- 批量操作 ----------

  Future<void> _batchAddTag() async {
    final tags = _allTags.toSet();
    final picked = <String>{};
    final newCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('加标签'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    for (final t in tags)
                      FilterChip(
                        label: Text(t),
                        selected: picked.contains(t),
                        onSelected: (v) => setDlg(() {
                          if (v) {
                            picked.add(t);
                          } else {
                            picked.remove(t);
                          }
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: newCtrl,
                  decoration: const InputDecoration(hintText: '新建标签'),
                ),
              ],
            ),
          ),
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
      ),
    );
    if (ok != true) return;
    if (newCtrl.text.trim().isNotEmpty) {
      await widget.repo.addTag(newCtrl.text.trim());
      picked.add(newCtrl.text.trim());
    }
    if (picked.isEmpty) return;
    for (final id in _selected) {
      final q = _questions.firstWhere((x) => x.id == id);
      final merged = {...q.tags, ...picked}.toList();
      await widget.repo.save(q.copyWith(tags: merged));
    }
    setState(() => _selected.clear());
    await _load();
  }

  Future<Folder?> _pickFolderDialog(String title) async {
    final subjectIds =
        _selected.map((id) => _questions.firstWhere((q) => q.id == id).subjectId).toSet();
    final options =
        _folders.where((f) => subjectIds.contains(f.subjectId)).toList();
    return showDialog<Folder>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          for (final f in options)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(f),
              child: Text(
                  '${Subject.byId(f.subjectId).name} / ${f.parentId == null ? '' : '${_folders.firstWhere((x) => x.id == f.parentId!).name} / '}${f.name}'),
            ),
        ],
      ),
    );
  }

  Future<void> _batchAddToFolder() async {
    final f = await _pickFolderDialog('加入文件夹');
    if (f == null) return;
    for (final id in _selected) {
      final q = _questions.firstWhere((x) => x.id == id);
      if (q.subjectId != f.subjectId) continue;
      if (q.folderIds.contains(f.id)) continue;
      await widget.repo.save(q.copyWith(folderIds: [...q.folderIds, f.id]));
    }
    setState(() => _selected.clear());
    await _load();
  }

  Future<void> _batchMoveToFolder() async {
    final f = await _pickFolderDialog('移入文件夹');
    if (f == null) return;
    for (final id in _selected) {
      final q = _questions.firstWhere((x) => x.id == id);
      if (q.subjectId != f.subjectId) continue;
      var ids = q.folderIds.toList();
      if (_folderId != null) ids.remove(_folderId);
      if (!ids.contains(f.id)) ids.add(f.id);
      await widget.repo.save(q.copyWith(folderIds: ids));
    }
    setState(() => _selected.clear());
    await _load();
  }

  Future<void> _batchRemoveFromFolder() async {
    if (_folderId == null) return;
    for (final id in _selected) {
      final q = _questions.firstWhere((x) => x.id == id);
      if (!q.folderIds.contains(_folderId)) continue;
      await widget.repo.save(q.copyWith(
          folderIds: q.folderIds.where((x) => x != _folderId).toList()));
    }
    setState(() => _selected.clear());
    await _load();
  }

  Future<void> _batchFavorite() async {
    for (final id in _selected) {
      final q = _questions.firstWhere((x) => x.id == id);
      if (!q.isFavorite) await widget.repo.toggleFavorite(q);
    }
    setState(() => _selected.clear());
    await _load();
  }

  Future<void> _batchArchive() async {
    for (final id in _selected) {
      final q = _questions.firstWhere((x) => x.id == id);
      await widget.repo.archive(q);
    }
    setState(() => _selected.clear());
    await _load();
  }

  Future<void> _batchDelete() async {
    final ok = await _confirm('删了就没了，确定吗？');
    if (!ok) return;
    for (final id in _selected.toList()) {
      final q = _questions.firstWhere((x) => x.id == id);
      await widget.repo.delete(q);
    }
    setState(() => _selected.clear());
    await _load();
  }

  Future<void> _deleteOne(Question q) async {
    final ok = await _confirm('删了就没了，确定吗？');
    if (!ok) return;
    await widget.repo.delete(q);
    await _load();
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator()));
    }
    return switch (_view) {
      _View.shelf => _buildShelf(),
      _View.directory => _buildDirectory(),
      _View.list => _buildList(),
      _View.archived => _buildArchived(),
    };
  }

  Widget _pageShell({required String title, required Widget body, List<Widget>? actions}) {
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: body,
    );
  }

  // ----- 书架 -----

  Widget _buildShelf() {
    const perPage = 6;
    final pages = (_subjects.length / perPage).ceil().clamp(1, 99);
    final page = _shelfPage.clamp(0, pages - 1);
    final books = _subjects.skip(page * perPage).take(perPage).toList();
    return _pageShell(
      title: '错题本',
      actions: [
        TextButton.icon(
          onPressed: () => setState(() => _view = _View.archived),
          icon: const Icon(Icons.archive_outlined, size: 18),
          label: const Text('已归档'),
        ),
      ],
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < books.length; i++) ...[
                    if (i > 0) const SizedBox(width: 20),
                    Expanded(child: _buildBook(books[i])),
                  ],
                ],
              ),
            ),
            if (pages > 1)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: page > 0
                        ? () => setState(() => _shelfPage = page - 1)
                        : null,
                  ),
                  Text('${page + 1} / $pages'),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: page < pages - 1
                        ? () => setState(() => _shelfPage = page + 1)
                        : null,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBook(Subject s) {
    final counts = _counts[s.id] ?? (0, 0, 0);
    final total = _questions
        .where((q) =>
            q.subjectId == s.id && q.isOrganized && !q.isArchived)
        .length;
    final coverColor = CoverColors.of(s.coverColor);
    return Column(
      children: [
        GestureDetector(
          onTap: () => _openDirectory(s.id),
          child: Container(
            width: 168,
            height: 224,
            decoration: BoxDecoration(
              color: coverColor,
              borderRadius: BorderRadius.circular(6),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x22000000),
                    blurRadius: 8,
                    offset: Offset(0, 4)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                        painter: _CoverPatternPainter(s.coverStyle)),
                  ),
                  Positioned(
                    left: 14,
                    right: 14,
                    top: 18,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          backgroundColor: Colors.white.withValues(alpha: 0.25),
                          child: Text(s.icon,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800)),
                        ),
                        const SizedBox(height: 10),
                        Text(s.name,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        const Text('错题本',
                            style: TextStyle(
                                color: Colors.white, fontSize: 13)),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 14,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _bookStat('题数', total),
                          _bookStat('要复习', counts.$1),
                          _bookStat('待复查', counts.$2),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => widget.onGoReview(subjectId: s.id),
          child: const Text('开始复习'),
        ),
      ],
    );
  }

  Widget _bookStat(String label, int value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$value',
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w800)),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }

  // ----- 目录页 -----

  Widget _buildDirectory() {
    final subjectId = _subjectId!;
    final subject = Subject.byId(subjectId);
    final tops = _topFolders(subjectId);
    final kw = _folderSearch.trim();
    final visibleTops = kw.isEmpty
        ? tops
        : tops.where((f) {
            if (f.name.contains(kw)) return true;
            return _subFolders(f.id).any((s) => s.name.contains(kw));
          }).toList();
    // 搜到子文件夹自动展开其父文件夹。
    if (kw.isNotEmpty) {
      for (final f in visibleTops) {
        if (_subFolders(f.id).any((s) => s.name.contains(kw))) {
          _expandedFolders.add(f.id);
        }
      }
    }
    return _pageShell(
      title: '${subject.name}错题本',
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _openShelf,
                  icon: const Icon(Icons.chevron_left, size: 18),
                  label: const Text('返回书架'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => _openList(folderId: null),
                  child: const Text('全部题目'),
                ),
                const Spacer(),
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _folderSearchCtrl,
                    decoration: const InputDecoration(
                      hintText: '搜索文件夹',
                      prefixIcon: Icon(Icons.search, size: 18),
                      isDense: true,
                    ),
                    onChanged: (v) => setState(() => _folderSearch = v),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => setState(
                      () => _selectingMove = !_selectingMove),
                  icon: const Icon(Icons.drive_file_move_outlined, size: 18),
                  label: Text(_selectingMove ? '取消选择' : '移动'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => _addFolder(),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新建文件夹'),
                ),
              ],
            ),
            if (_selectingMove && _moveSelection.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: FilledButton(
                  onPressed: () => _pickMoveTarget(_folders
                      .where((f) => _moveSelection.contains(f.id))
                      .toList()),
                  child: Text('移动 ${_moveSelection.length} 个文件夹到…'),
                ),
              ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                children: [
                  // 拖到顶层区域：移回顶层。
                  DragTarget<Folder>(
                    onAcceptWithDetails: (d) =>
                        _moveFoldersToTarget([d.data], null),
                    builder: (ctx, candidate, rejected) => Container(
                      height: 8,
                      color: candidate.isNotEmpty
                          ? AppTheme.accent.withValues(alpha: 0.15)
                          : Colors.transparent,
                    ),
                  ),
                  for (var i = 0; i < visibleTops.length; i++) ...[
                    _buildFolderRow(visibleTops[i], 0),
                    for (final sub in _expandedFolders.contains(visibleTops[i].id)
                        ? _subFolders(visibleTops[i].id)
                        : const <Folder>[])
                      _buildFolderRow(sub, 1),
                    // 两个文件夹之间的拖放区：调顺序。
                    DragTarget<Folder>(
                      onAcceptWithDetails: (d) =>
                          _reorderTopFolder(d.data, i + 1),
                      builder: (ctx, candidate, rejected) => Container(
                        height: 10,
                        color: candidate.isNotEmpty
                            ? AppTheme.accent.withValues(alpha: 0.25)
                            : Colors.transparent,
                      ),
                    ),
                  ],
                  if (visibleTops.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 40),
                      child: EmptyState(message: '还没有文件夹，新建一个吧'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFolderRow(Folder f, int depth) {
    final isTop = depth == 0;
    final expanded = _expandedFolders.contains(f.id);
    final count = _folderCount(f.id);
    final row = Container(
      margin: EdgeInsets.only(left: depth * 28, bottom: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border.all(
            color: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF333B47)
                : AppTheme.lightLine),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          if (isTop)
            IconButton(
              tooltip: expanded ? '折起' : '展开',
              icon: Icon(
                  expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 20),
              onPressed: () => setState(() {
                if (expanded) {
                  _expandedFolders.remove(f.id);
                } else {
                  _expandedFolders.add(f.id);
                }
              }),
            )
          else
            const SizedBox(width: 12),
          if (_selectingMove)
            Checkbox(
              value: _moveSelection.contains(f.id),
              onChanged: (v) => setState(() {
                if (v == true) {
                  _moveSelection.add(f.id);
                } else {
                  _moveSelection.remove(f.id);
                }
              }),
            ),
          Expanded(
            child: InkWell(
              onTap: () => _openList(folderId: f.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.folder_outlined, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(f.name,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                    Text('$count 道题',
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
          ),
          if (isTop)
            IconButton(
              tooltip: '新建子文件夹',
              icon: const Icon(Icons.create_new_folder_outlined, size: 20),
              onPressed: () => _addFolder(parentId: f.id),
            ),
          IconButton(
            tooltip: '重命名',
            icon: const Icon(Icons.edit_outlined, size: 18),
            onPressed: () => _renameFolder(f),
          ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: () => _deleteFolder(f),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
    // 子文件夹搜索过滤后仍显示父行；子行本身按搜索过滤在父行展开处处理。
    final kw = _folderSearch.trim();
    if (!isTop && kw.isNotEmpty && !f.name.contains(kw)) {
      return const SizedBox.shrink();
    }
    return Draggable<Folder>(
      data: f,
      feedback: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(f.name),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: row),
      child: DragTarget<Folder>(
        // 拖到文件夹上 = 移进去（顶层文件夹作父级；子文件夹作其父级）。
        onAcceptWithDetails: (d) {
          if (d.data.id == f.id) return;
          final targetParent = isTop ? f.id : f.parentId;
          _moveFoldersToTarget([d.data], targetParent);
        },
        builder: (ctx, candidate, rejected) => Container(
          decoration: candidate.isNotEmpty
              ? BoxDecoration(
                  border: Border.all(color: AppTheme.accent, width: 2),
                  borderRadius: BorderRadius.circular(10),
                )
              : null,
          child: row,
        ),
      ),
    );
  }

  // ----- 题目列表 -----

  Widget _buildList() {
    final all = _filteredAll();
    final totalPages = (all.length / _pageSize).ceil().clamp(1, 9999);
    final page = _page.clamp(0, totalPages - 1);
    final start = page * _pageSize;
    final items = all.skip(start).take(_pageSize).toList();
    final orderIds = all.map((q) => q.id).toList();
    final subject = _subjectId == null ? null : Subject.byId(_subjectId!);
    final folder = _folderId == null
        ? null
        : _folders.firstWhere((f) => f.id == _folderId!,
            orElse: () => Folder(
                id: _folderId!, name: '', subjectId: _subjectId ?? ''));
    final title = _view == _View.archived
        ? '已归档'
        : folder != null
            ? folder.name
            : subject != null
                ? '${subject.name} · 全部题目'
                : '全部题目';
    return _pageShell(
      title: title,
      body: Column(
        children: [
          _buildListToolbar(),
          if (_filterOpen) _buildFilterPanel(),
          Expanded(
            child: items.isEmpty
                ? EmptyState(
                    message: '这里还没有错题，去收集吧',
                    actionLabel: '去收集',
                    onAction: widget.onOpenHome,
                  )
                : _viewMode == 'large'
                    ? ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: items.length,
                        itemBuilder: (ctx, i) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _buildLargeCard(items[i], start + i + 1,
                              orderIds),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const DashedDivider(
                            color: AppTheme.lightPaperLine),
                        itemBuilder: (ctx, i) =>
                            _buildCompactRow(items[i], orderIds),
                      ),
          ),
          _buildPagination(all.length, totalPages, page),
          if (_batchMode && _selected.isNotEmpty) _buildBatchBar(),
        ],
      ),
    );
  }

  Widget _buildListToolbar() {
    final filterCount = _activeFilterCount();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: '返回',
                icon: const Icon(Icons.chevron_left),
                onPressed: () {
                  if (_subjectId != null) {
                    _openDirectory(_subjectId!);
                  } else {
                    _openShelf();
                  }
                },
              ),
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  decoration: const InputDecoration(
                    hintText: '搜索题名 / 标签',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() {
                    _search = v;
                    _page = 0;
                  }),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () =>
                    setState(() => _filterOpen = !_filterOpen),
                icon: const Icon(Icons.filter_list, size: 18),
                label: Text(
                    filterCount > 0 ? '筛选（$filterCount）' : '筛选'),
              ),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: _sort,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 'new', child: Text('时间新→旧')),
                  DropdownMenuItem(value: 'old', child: Text('时间旧→新')),
                  DropdownMenuItem(value: 'subject', child: Text('按学科')),
                ],
                onChanged: (v) =>
                    setState(() => _sort = v ?? 'new'),
              ),
              const SizedBox(width: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: 'large',
                      icon: Icon(Icons.grid_view, size: 16),
                      label: Text('大卡片')),
                  ButtonSegment(
                      value: 'compact',
                      icon: Icon(Icons.list, size: 16),
                      label: Text('紧凑')),
                ],
                selected: {_viewMode},
                onSelectionChanged: (s) =>
                    setState(() => _viewMode = s.first),
              ),
              const SizedBox(width: 8),
              TextButton(onPressed: _resetFilters, child: const Text('重置')),
              const SizedBox(width: 4),
              FilledButton(
                onPressed: () => setState(() {
                  _batchMode = !_batchMode;
                  _selected.clear();
                }),
                child: Text(_batchMode ? '退出批量' : '批量操作'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilterPanel() {
    final errorTypes = <String>{...ErrorTypes.fixed};
    for (final q in _questions) {
      errorTypes.addAll(q.allCauses);
    }
    final kpByChapter = <String, List<KnowledgePoint>>{};
    for (final kp in _kps) {
      if (_subjectId != null && kp.subjectId != _subjectId) continue;
      (kpByChapter[kp.chapter] ??= []).add(kp);
    }
    Widget chipRow(String label, List<Widget> chips) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 72,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(label,
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            ),
            Expanded(
              child: Wrap(spacing: 8, runSpacing: 4, children: chips),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border.all(
            color: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF333B47)
                : AppTheme.lightLine),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          chipRow('试卷', [
            ChoiceChip(
              label: const Text('全部'),
              selected: _filterExamId == null,
              onSelected: (_) => setState(() {
                _filterExamId = null;
                _page = 0;
              }),
            ),
            for (final e in _exams)
              ChoiceChip(
                label: Text(e.name),
                selected: _filterExamId == e.id,
                onSelected: (_) => setState(() {
                  _filterExamId = e.id;
                  _page = 0;
                }),
              ),
          ]),
          chipRow('错误类型', [
            ChoiceChip(
              label: const Text('全部'),
              selected: _filterErrorType == null,
              onSelected: (_) => setState(() {
                _filterErrorType = null;
                _page = 0;
              }),
            ),
            for (final t in errorTypes)
              ChoiceChip(
                label: Text(t),
                selected: _filterErrorType == t,
                onSelected: (_) => setState(() {
                  _filterErrorType = t;
                  _page = 0;
                }),
              ),
          ]),
          chipRow('错因状态', [
            for (final (v, label) in [
              ('all', '全部'),
              ('pending', '待解决'),
              ('inProgress', '解决中'),
              ('solved', '已解决'),
              ('recheck', '复查'),
            ])
              ChoiceChip(
                label: Text(label),
                selected: _filterCauseStatus == v,
                onSelected: (_) => setState(() {
                  _filterCauseStatus = v;
                  _page = 0;
                }),
              ),
          ]),
          chipRow('收藏', [
            FilterChip(
              label: const Text('仅收藏'),
              selected: _filterFavorite,
              onSelected: (v) => setState(() {
                _filterFavorite = v;
                _page = 0;
              }),
            ),
          ]),
          if (_allTags.isNotEmpty)
            chipRow('标签', [
              for (final t in _allTags)
                FilterChip(
                  label: Text(t),
                  selected: _filterTags.contains(t),
                  onSelected: (v) => setState(() {
                    if (v) {
                      _filterTags.add(t);
                    } else {
                      _filterTags.remove(t);
                    }
                    _page = 0;
                  }),
                ),
            ]),
          for (final chapter in kpByChapter.keys)
            chipRow('知识点·$chapter', [
              for (final kp in kpByChapter[chapter]!)
                FilterChip(
                  label: Text(kp.name),
                  selected: _filterKpIds.contains(kp.id),
                  onSelected: (v) => setState(() {
                    if (v) {
                      _filterKpIds.add(kp.id);
                    } else {
                      _filterKpIds.remove(kp.id);
                    }
                    _page = 0;
                  }),
                ),
            ]),
          if (_filterCauseName != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Chip(
                label: Text('错因：$_filterCauseName'),
                onDeleted: () => setState(() => _filterCauseName = null),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPagination(int total, int totalPages, int page) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: page > 0
                ? () => setState(() => _page = page - 1)
                : null,
          ),
          Text('$total 道题 · 第 ${page + 1} / $totalPages 页'),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: page < totalPages - 1
                ? () => setState(() => _page = page + 1)
                : null,
          ),
          const SizedBox(width: 12),
          const Text('每页'),
          const SizedBox(width: 4),
          DropdownButton<int>(
            value: _pageSize,
            underline: const SizedBox.shrink(),
            items: [10, 20, 30, 40, 50]
                .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
                .toList(),
            onChanged: (v) => setState(() {
              _pageSize = v ?? 10;
              _page = 0;
            }),
          ),
          const Text('道'),
        ],
      ),
    );
  }

  Widget _buildBatchBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border.all(color: AppTheme.accent),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('已选 ${_selected.length} 道'),
          TextButton(onPressed: _batchAddTag, child: const Text('加标签')),
          TextButton(
              onPressed: _batchAddToFolder, child: const Text('加入文件夹')),
          TextButton(
              onPressed: _batchMoveToFolder, child: const Text('移入其他文件夹')),
          if (_folderId != null)
            TextButton(
                onPressed: _batchRemoveFromFolder,
                child: const Text('移出当前文件夹')),
          TextButton(onPressed: _batchFavorite, child: const Text('收藏')),
          TextButton(onPressed: _batchArchive, child: const Text('归档')),
          TextButton(onPressed: _batchDelete, child: const Text('删除')),
          TextButton(
            onPressed: () => setState(() => _selected.clear()),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Widget _causeStatusLabel(Question q) {
    final status = _causeStatusOf(q);
    final label = switch (status) {
      'recheck' => '复查',
      'pending' => '待解决',
      'inProgress' => '解决中',
      _ => '已解决',
    };
    final next = _nextRecheckOf(q);
    return Text(
      next == null ? label : '$label · 下次复查 $next',
      style: Theme.of(context).textTheme.bodySmall,
    );
  }

  Widget _buildLargeCard(Question q, int number, List<String> orderIds) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 13,
                  backgroundColor: AppTheme.accent,
                  child: Text('$number',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(q.title,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                ),
                if (_batchMode)
                  Checkbox(
                    value: _selected.contains(q.id),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _selected.add(q.id);
                      } else {
                        _selected.remove(q.id);
                      }
                    }),
                  ),
                IconButton(
                  icon: Icon(
                    q.isFavorite ? Icons.star : Icons.star_border,
                    color: q.isFavorite ? Colors.amber : null,
                  ),
                  onPressed: () async {
                    await widget.repo.toggleFavorite(q);
                    await _load();
                  },
                ),
                IconButton(
                  tooltip: '删除',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () => _deleteOne(q),
                ),
              ],
            ),
            const SizedBox(height: 8),
            QuestionSlice(
              question: q,
              maxHeight: 160,
              fixedHeight: true,
              onTap: () => widget.onOpenDetail(q, orderIds),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SubjectLabel(subjectId: q.subjectId),
                for (final t in q.allCauses) InfoChip(label: t),
                for (final t in q.tags) InfoChip(label: t),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                _causeStatusLabel(q),
                const Spacer(),
                if (_view == _View.archived)
                  TextButton(
                    onPressed: () async {
                      await widget.repo.archive(q, archived: false);
                      await _load();
                    },
                    child: const Text('恢复'),
                  )
                else
                  TextButton(
                    onPressed: () => widget.onOpenDetail(q, orderIds),
                    child: const Text('查看详情'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactRow(Question q, List<String> orderIds) {
    return InkWell(
      onTap: () => widget.onOpenDetail(q, orderIds),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            if (_batchMode)
              Checkbox(
                value: _selected.contains(q.id),
                onChanged: (v) => setState(() {
                  if (v == true) {
                    _selected.add(q.id);
                  } else {
                    _selected.remove(q.id);
                  }
                }),
              ),
            CompactSliceThumb(question: q),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(q.title,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Wrap(
                    spacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SubjectLabel(subjectId: q.subjectId),
                      for (final t in q.allCauses) InfoChip(label: t),
                      for (final t in q.tags) InfoChip(label: t),
                      _causeStatusLabel(q),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(
                q.isFavorite ? Icons.star : Icons.star_border,
                color: q.isFavorite ? Colors.amber : null,
              ),
              onPressed: () async {
                await widget.repo.toggleFavorite(q);
                await _load();
              },
            ),
          ],
        ),
      ),
    );
  }

  // ----- 已归档 -----

  Widget _buildArchived() {
    final archived =
        _questions.where((q) => q.isArchived).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final orderIds = archived.map((q) => q.id).toList();
    return _pageShell(
      title: '已归档',
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _openShelf,
                  icon: const Icon(Icons.chevron_left, size: 18),
                  label: const Text('返回书架'),
                ),
                const SizedBox(width: 12),
                Text('${archived.length} 道题',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          Expanded(
            child: archived.isEmpty
                ? const EmptyState(message: '没有已归档的题')
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: archived.length,
                    itemBuilder: (ctx, i) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _buildLargeCard(archived[i], i + 1, orderIds),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 封面纹理（6 种样式）：纯色折角 / 横线纹 / 圆点 / 方格纹 / 斜纹 / 双线框。
class _CoverPatternPainter extends CustomPainter {
  _CoverPatternPainter(this.style);
  final String style;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..strokeWidth = 1.5;
    switch (style) {
      case 'lines':
        for (var y = 28.0; y < size.height; y += 22) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        }
      case 'dots':
        for (var y = 20.0; y < size.height; y += 24) {
          for (var x = 18.0; x < size.width; x += 24) {
            canvas.drawCircle(Offset(x, y), 2.5, paint);
          }
        }
      case 'grid':
        for (var x = 20.0; x < size.width; x += 22) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
        }
        for (var y = 20.0; y < size.height; y += 22) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        }
      case 'diagonal':
        for (var i = -8; i < 16; i++) {
          final x = i * 24.0;
          canvas.drawLine(
              Offset(x, size.height), Offset(x + size.height, 0), paint);
        }
      case 'double':
        final rect = Rect.fromLTWH(10, 10, size.width - 20, size.height - 20);
        canvas.drawRect(rect, paint);
        final inner =
            Rect.fromLTWH(16, 16, size.width - 32, size.height - 32);
        canvas.drawRect(inner, paint);
      case 'plain':
        // 折角
        final fold = Path()
          ..moveTo(size.width - 28, 0)
          ..lineTo(size.width, 28)
          ..lineTo(size.width, 0)
          ..close();
        canvas.drawPath(
            fold, Paint()..color = Colors.white.withValues(alpha: 0.28));
    }
  }

  @override
  bool shouldRepaint(covariant _CoverPatternPainter oldDelegate) =>
      oldDelegate.style != style;
}
