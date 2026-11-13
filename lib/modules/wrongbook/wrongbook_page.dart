import 'package:flutter/material.dart';

import '../../data/repository.dart';
import '../../models/models.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/uikit.dart';
import '../../widgets/widgets.dart';

/// 错题本：书架 → 目录页 → 题目列表（同一路由 /wrongbook）。
/// 已归档经书架顶部入口进跨学科列表；打开的书里另有本学科的已归档视图。
///
/// 视觉来源：HTML 原型 `viewNotebook` / `nbShelfHTML` / `nbTocHTML` /
/// `nbFiltered`（R6 重建）。页内无边距（外壳 26/30 为唯一内边距）；
/// 全部取 DesignTokens 与 UI Kit，文字符号，不用图标字体。
/// 业务口径沿用 repository 现有口径，不改动。
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

/// 拖拽落点（目录页）：拖到行上 = 移进去；拖到「全部题目」上 = 移回顶层。
/// 行间调顺序由缝隙目标直接调 [_reorderFolder]，不走这里。
enum _DropKind { into, promote }

class _WrongbookPageState extends State<WrongbookPage> {
  bool _loading = true;
  List<Subject> _subjects = Subject.all;
  // 库里找学科：新学科用库里的名与色；找不到才回退 Subject.byId
  //（数学兜底，只发生在数据不一致时）。
  Subject _subjectOf(String id) => _subjects.firstWhere(
        (s) => s.id == id,
        orElse: () => Subject.byId(id),
      );
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
  String _defaultSort = 'new';

  // 目录页
  final Set<String> _expandedFolders = {};
  String _folderSearch = '';
  bool _selectingMove = false;
  final Set<String> _moveSelection = {};
  String _moveTargetId = '__top__';
  String? _renamingId;
  Folder? _deleteConfirmFolder;
  String? _draggingId;
  String? _dragOverKey;

  // 列表页
  String _search = '';
  String? _filterExamId;
  String? _filterErrorType;
  String _filterTimeRange = 'all'; // all / week / month
  String _filterCauseStatus =
      'all'; // all / pending / inProgress / solved / recheck
  String? _filterCauseName;
  bool _filterFavorite = false;
  bool _filterOverdue = false;
  final Set<String> _filterTags = {};
  final Set<String> _filterKpIds = {};
  bool _filterOpen = false;
  String _sort =
      'new'; // new / old / subj-asc / subj-desc / status-asc / status-desc
  int _pageSize = 10;
  int _page = 0;
  String _viewMode = 'large'; // large / compact
  bool _batchMode = false;
  final Set<String> _selected = {};
  bool _batchDeleteConfirm = false;
  String? _batchFolderId;
  bool _inBookArchived = false;

  final _searchCtrl = TextEditingController();
  final _folderSearchCtrl = TextEditingController();
  final _newFolderCtrl = TextEditingController();
  final _renameCtrl = TextEditingController();

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
    _newFolderCtrl.dispose();
    _renameCtrl.dispose();
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
      _defaultSort = settings.wrongbookSort;
      _loading = false;
    });
  }

  // ---------- 派生数据 ----------

  List<Folder> _subjectFolders(String subjectId) =>
      _folders.where((f) => f.subjectId == subjectId).toList();

  List<Folder> _topFolders(String subjectId) =>
      _subjectFolders(subjectId).where((f) => f.parentId == null).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  List<Folder> _subFolders(String parentId) =>
      _folders.where((f) => f.parentId == parentId).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  /// 文件夹子树 id（含自己与子文件夹）。
  Set<String> _subtreeIds(String folderId) {
    final ids = {folderId};
    for (final sub in _subFolders(folderId)) {
      ids.addAll(_subtreeIds(sub.id));
    }
    return ids;
  }

  /// 目录文件夹行计数：与题目列表同一收录口径（R0 §5.5），只收已整理
  /// 且未归档的题；否则行上写着“1 道题”，点进去列表却是空的（真实库
  /// q-math-2 未整理但已挂文件夹就曾这样）。基线 _folderCount 只排
  /// 除已归档，这里补上 isOrganized；删文件夹的计数另有
  /// [_folderDeleteCount]（删的是题本身，不跟这条口径）。
  int _folderCount(String folderId) {
    final ids = _subtreeIds(folderId);
    return _questions
        .where(
          (q) =>
              q.isOrganized &&
              !q.isArchived &&
              q.folderIds.any((id) => ids.contains(id)),
        )
        .length;
  }

  /// 删文件夹时会跟着删的题数：全部文件夹都在该子树里的题。
  int _folderDeleteCount(String folderId) {
    final ids = _subtreeIds(folderId);
    return _questions
        .where(
          (q) =>
              q.folderIds.isNotEmpty &&
              q.folderIds.every((id) => ids.contains(id)),
        )
        .length;
  }

  /// 删文件夹时只解除关联的题数：在该子树里、同时也在别的题夹里的题。
  int _folderDeleteMultiCount(String folderId) {
    final ids = _subtreeIds(folderId);
    return _questions
        .where(
          (q) =>
              q.folderIds.any((id) => ids.contains(id)) &&
              q.folderIds.any((id) => !ids.contains(id)),
        )
        .length;
  }

  bool _isMastered(Question q) {
    final rs = _recordsByQ[q.id];
    if (rs == null || rs.isEmpty) return false;
    return rs.every((r) => r.status == CauseStatus.solved) &&
        !rs.any((r) => r.isRecheckDue);
  }

  /// 一题的错因汇总状态（HTML `nbCauseStatus`）：有错因到了复查时间 →
  /// 复查；全部已解决 → 已解决；有解决中或已有自查进展 → 解决中；
  /// 否则待解决；无错因 → 待解决。
  String _causeStatusOf(Question q) {
    final rs = _recordsByQ[q.id];
    if (rs == null || rs.isEmpty) return 'pending';
    if (rs.any((r) => r.isRecheckDue)) return 'recheck';
    if (rs.every((r) => r.status == CauseStatus.solved)) return 'solved';
    if (rs.any(
      (r) => r.status == CauseStatus.inProgress || r.solvedCount > 0,
    )) {
      return 'inProgress';
    }
    return 'pending';
  }

  /// 各错因的状态（紧凑行按错因出 pill 用）：(错因名, 状态)。
  List<(String, String)> _causeStatusesOf(Question q) {
    final rs = _recordsByQ[q.id];
    if (rs == null || rs.isEmpty) {
      return [for (final c in q.allCauses) (c, 'pending')];
    }
    return [
      for (final r in rs) (r.cause, r.isRecheckDue ? 'recheck' : r.status.name),
    ];
  }

  bool _isOverdue(Question q) {
    final rs = _recordsByQ[q.id];
    if (rs == null) return false;
    return rs.any((r) => r.isRecheckDue);
  }

  DateTime? _nextRecheckOf(Question q) {
    final rs = _recordsByQ[q.id];
    if (rs == null) return null;
    DateTime? next;
    for (final r in rs) {
      if (r.recheckDate == null) continue;
      if (next == null || r.recheckDate!.isBefore(next)) {
        next = r.recheckDate;
      }
    }
    return next;
  }

  /// 搜索只查元数据，永不搜题干（HTML `nbFiltered` 的 haystack）：
  /// 题名 / 学科 / 文件夹 / 标签 / 试卷 / 收集日期 / 知识点 / 错误类型。
  String _searchHaystack(Question q) {
    final subject = _subjectOf(q.subjectId).name;
    final folderNames = q.folderIds
        .map(
          (id) => _folders
              .firstWhere(
                (f) => f.id == id,
                orElse: () => Folder(id: id, name: '', subjectId: ''),
              )
              .name,
        )
        .where((n) => n.isNotEmpty);
    final examName = _exams
        .firstWhere(
          (e) => e.id == q.examId,
          orElse: () => Exam(id: '', name: ''),
        )
        .name;
    final kpNames = q.knowledgePointIds.map(
      (id) => _kps
          .firstWhere(
            (k) => k.id == id,
            orElse: () => const KnowledgePoint(
              id: '',
              subjectId: '',
              chapter: '',
              name: '',
            ),
          )
          .name,
    );
    final date = '${q.createdAt.year}-${q.createdAt.month}-${q.createdAt.day}';
    return [
      q.title,
      subject,
      ...folderNames,
      ...q.tags,
      examName,
      date,
      ...kpNames,
      ...q.allCauses,
    ].join(' ').toLowerCase();
  }

  List<Question> _filteredAll() {
    var list = _questions;
    if (_view == _View.archived) {
      // 书架顶部入口：跨学科归档列表。
      list = list.where((q) => q.isArchived).toList();
    } else if (_inBookArchived) {
      // 打开的书里的已归档视图：本学科已归档的题。
      list = list
          .where((q) => q.isArchived && q.subjectId == _subjectId)
          .toList();
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
      // 错因全部已解决的题默认不显示（错因状态筛到已解决时才显示）。
      if (_filterCauseStatus != 'solved') {
        list = list.where((q) => !_isMastered(q)).toList();
      }
    }
    if (_search.trim().isNotEmpty) {
      final kw = _search.trim().toLowerCase();
      list = list.where((q) => _searchHaystack(q).contains(kw)).toList();
    }
    if (_filterExamId != null) {
      list = list.where((q) => q.examId == _filterExamId).toList();
    }
    if (_filterErrorType != null) {
      list = list.where((q) => q.allCauses.contains(_filterErrorType)).toList();
    }
    if (_filterCauseName != null) {
      list = list.where((q) => q.allCauses.contains(_filterCauseName)).toList();
    }
    if (_filterKpIds.isNotEmpty) {
      list = list
          .where(
            (q) => q.knowledgePointIds.any((id) => _filterKpIds.contains(id)),
          )
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
    if (_filterOverdue) {
      list = list.where((q) => _isOverdue(q)).toList();
    }
    if (_filterTimeRange != 'all') {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final limit = _filterTimeRange == 'week' ? 7 : 30;
      list = list.where((q) {
        final d = DateTime(
          q.createdAt.year,
          q.createdAt.month,
          q.createdAt.day,
        );
        final age = today.difference(d).inDays;
        return age >= 0 && age <= limit;
      }).toList();
    }
    if (_view != _View.archived && !_inBookArchived) {
      switch (_filterCauseStatus) {
        case 'pending':
          list = list.where((q) => _causeStatusOf(q) == 'pending').toList();
        case 'inProgress':
          list = list.where((q) => _causeStatusOf(q) == 'inProgress').toList();
        case 'solved':
          list = list.where((q) => _causeStatusOf(q) == 'solved').toList();
        case 'recheck':
          list = list.where((q) => _causeStatusOf(q) == 'recheck').toList();
      }
    }
    // 学科首字母（HTML `SUBJ_INITIAL`）：数学 S / 英语 Y / 政治 Z；
    // 未知学科取首字母大写。错因状态排序：待解决 0 / 解决中 1 /
    // 复查 2 / 已解决 3（HTML `NB_STATUS_RANK`）。
    int subjectRank(Question q) => switch (q.subjectId) {
      'math' => 0,
      'english' => 1,
      _ => 2,
    };
    int statusRank(Question q) => switch (_causeStatusOf(q)) {
      'pending' => 0,
      'inProgress' => 1,
      'recheck' => 2,
      _ => 3,
    };
    switch (_sort) {
      case 'old':
        list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      case 'subj-asc':
        list.sort((a, b) {
          final c = subjectRank(a).compareTo(subjectRank(b));
          return c != 0 ? c : b.createdAt.compareTo(a.createdAt);
        });
      case 'subj-desc':
        list.sort((a, b) {
          final c = subjectRank(b).compareTo(subjectRank(a));
          return c != 0 ? c : b.createdAt.compareTo(a.createdAt);
        });
      case 'status-asc':
        list.sort((a, b) {
          final c = statusRank(a).compareTo(statusRank(b));
          return c != 0 ? c : b.createdAt.compareTo(a.createdAt);
        });
      case 'status-desc':
        list.sort((a, b) {
          final c = statusRank(b).compareTo(statusRank(a));
          return c != 0 ? c : b.createdAt.compareTo(a.createdAt);
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
    if (_filterTimeRange != 'all') n++;
    if (_filterCauseStatus != 'all') n++;
    if (_filterCauseName != null) n++;
    if (_filterFavorite) n++;
    if (_filterOverdue) n++;
    n += _filterTags.length;
    n += _filterKpIds.length;
    return n;
  }

  /// 筛选变化后：回第 1 页，勾选只保留仍在当前结果里的题
  ///（HTML `viewNotebook` 的 fkey 逻辑）。
  void _applyFilterChange(List<Question> current) {
    final ids = current.map((q) => q.id).toSet();
    _selected.retainAll(ids);
    _page = 0;
    _batchDeleteConfirm = false;
  }

  void _resetFilters() {
    setState(() {
      _search = '';
      _searchCtrl.clear();
      _filterExamId = null;
      _filterErrorType = null;
      _filterTimeRange = 'all';
      _filterCauseStatus = 'all';
      _filterCauseName = null;
      _filterFavorite = false;
      _filterOverdue = false;
      _filterTags.clear();
      _filterKpIds.clear();
      // 排序回到设置里的错题本默认排序；文件夹 / 学科是列表的
      // 归属范围，不是筛选，不清。
      _sort = _defaultSort;
      _page = 0;
      _selected.clear();
      _batchDeleteConfirm = false;
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
      _batchDeleteConfirm = false;
      _inBookArchived = false;
    });
  }

  void _openDirectory(String subjectId) {
    setState(() {
      _subjectId = subjectId;
      _view = _View.directory;
      // 展开状态不记住：每次进目录都先收起。
      _expandedFolders.clear();
      _folderSearch = '';
      _folderSearchCtrl.clear();
      _newFolderCtrl.clear();
      _selectingMove = false;
      _moveSelection.clear();
      _renamingId = null;
      _deleteConfirmFolder = null;
      _draggingId = null;
      _dragOverKey = null;
    });
  }

  void _openShelf() {
    setState(() {
      _view = _View.shelf;
      _subjectId = null;
      _folderId = null;
      _shelfPage = 0;
      _inBookArchived = false;
    });
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- 文件夹操作 ----------

  Future<void> _addFolder({String? parentId}) async {
    final subjectId = _subjectId;
    if (subjectId == null) return;
    final name = _newFolderCtrl.text.trim();
    if (name.isEmpty) {
      _snack('先写文件夹名称');
      return;
    }
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
    await widget.repo.saveFolder(
      Folder(
        id: 'folder-$subjectId-${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        subjectId: subjectId,
        parentId: parentId,
        sortOrder: maxOrder + 10,
      ),
    );
    _newFolderCtrl.clear();
    await _load();
  }

  Future<void> _saveRename(Folder f) async {
    final name = _renameCtrl.text.trim();
    if (name.isEmpty || name == f.name) {
      setState(() => _renamingId = null);
      return;
    }
    final siblings = f.parentId == null
        ? _topFolders(f.subjectId)
        : _subFolders(f.parentId!);
    if (siblings.any((x) => x.id != f.id && x.name == name)) {
      _snack('已经有了');
      return;
    }
    await widget.repo.saveFolder(
      Folder(
        id: f.id,
        name: name,
        subjectId: f.subjectId,
        parentId: f.parentId,
        sortOrder: f.sortOrder,
      ),
    );
    setState(() => _renamingId = null);
    await _load();
  }

  Future<void> _deleteFolderConfirmed(Folder f) async {
    await widget.repo.deleteFolder(f);
    setState(() => _deleteConfirmFolder = null);
    await _load();
  }

  /// 移动文件夹（HTML `tocMoveFolder` 的禁则）：
  /// 已在目标处；不能移到自己 / 自己子文件夹下面；
  /// 带子文件夹的一级文件夹不能再放进别的文件夹（只留一层）；
  /// 目标下面已有同名文件夹。
  /// 返回 null 表示成功，否则返回拦下的原因。
  Future<String?> _moveOneFolder(Folder f, String? targetParentId) async {
    if (f.parentId == targetParentId) return '已经在那里了';
    if (targetParentId != null) {
      if (targetParentId == f.id ||
          _subtreeIds(f.id).contains(targetParentId)) {
        return '不能移到自己下面';
      }
      final target = _folders.firstWhere((x) => x.id == targetParentId);
      if (target.parentId != null) return '子文件夹只能有一层';
      if (_subFolders(f.id).isNotEmpty) {
        return '「${f.name}」下面还有子文件夹，只留一层，不能再放进别的文件夹里';
      }
      if (_subFolders(targetParentId).any((x) => x.name == f.name)) {
        return '目标下面已经有同名的「${f.name}」了';
      }
    } else {
      if (_topFolders(f.subjectId).any((x) => x.name == f.name)) {
        return '顶层已经有同名的「${f.name}」了';
      }
    }
    final siblings = targetParentId == null
        ? _topFolders(f.subjectId)
        : _subFolders(targetParentId);
    final maxOrder = siblings.isEmpty
        ? 0
        : siblings.map((x) => x.sortOrder).reduce((a, b) => a > b ? a : b);
    await widget.repo.saveFolder(
      Folder(
        id: f.id,
        name: f.name,
        subjectId: f.subjectId,
        parentId: targetParentId,
        sortOrder: maxOrder + 10,
      ),
    );
    return null;
  }

  /// 勾选移动：父级也被勾选时，子文件夹跟着父级一起走、不重复处理
  ///（HTML `data-nb-toc-move` 的处理）。
  Future<void> _moveSelected() async {
    final subjectId = _subjectId;
    if (subjectId == null) return;
    final picked = _folders
        .where((f) => _moveSelection.contains(f.id))
        .toList();
    if (picked.isEmpty) {
      _snack('先勾选要移动的文件夹');
      return;
    }
    final effective = picked
        .where(
          (f) => f.parentId == null || !_moveSelection.contains(f.parentId),
        )
        .toList();
    final targetParentId = _moveTargetId == '__top__' ? null : _moveTargetId;
    var okN = 0;
    final fails = <String>[];
    for (final f in effective) {
      final msg = await _moveOneFolder(f, targetParentId);
      if (msg == null) {
        okN++;
      } else {
        fails.add('「${f.name}」：$msg');
      }
    }
    setState(() {
      _selectingMove = false;
      _moveSelection.clear();
      if (targetParentId != null && okN > 0) {
        _expandedFolders.add(targetParentId);
      }
    });
    await _load();
    if (mounted) {
      _snack(
        '${okN > 0 ? '已移动 $okN 个文件夹（里面的题跟着一起走）' : '没有文件夹被移动'}${fails.isEmpty ? '' : '；${fails.join('；')}'}',
      );
    }
  }

  /// 同层调顺序（拖到两行之间；HTML `tocReorderFolder` 的等效做法）。
  Future<void> _reorderFolder(
    Folder dragged,
    String? parentId,
    int toIndex,
  ) async {
    final subjectId = _subjectId;
    if (subjectId == null) return;
    if (dragged.parentId != parentId) return;
    final siblings = parentId == null
        ? _topFolders(subjectId)
        : _subFolders(parentId);
    siblings.removeWhere((f) => f.id == dragged.id);
    final idx = toIndex.clamp(0, siblings.length);
    siblings.insert(idx, dragged);
    for (var i = 0; i < siblings.length; i++) {
      await widget.repo.saveFolder(
        Folder(
          id: siblings[i].id,
          name: siblings[i].name,
          subjectId: siblings[i].subjectId,
          parentId: siblings[i].parentId,
          sortOrder: i * 10,
        ),
      );
    }
    await _load();
  }

  /// 拖放落点处理（HTML `tocDropMode` / `tocApplyDrop`）：
  /// - 拖到「全部题目」上：子文件夹移回顶层；顶层文件夹排到最前面。
  /// - 拖到文件夹行上：移进去当它的子文件夹（拖到子文件夹行上时，
  ///   落在其父文件夹下面）；已在里面时不动。
  /// - 拖到两行之间：同层调顺序；子文件夹拖到顶层行之间 = 移进该顶层。
  Future<void> _applyDrop(
    Folder dragged,
    Folder? target,
    _DropKind kind,
  ) async {
    if (kind == _DropKind.promote) {
      if (dragged.parentId != null) {
        final msg = await _moveOneFolder(dragged, null);
        await _load();
        if (mounted) {
          _snack(msg ?? '已把「${dragged.name}」移回顶层（里面的题跟着一起走）');
        }
      } else {
        await _reorderFolder(dragged, null, 0);
      }
      return;
    }
    if (target == null) return;
    if (kind == _DropKind.into) {
      final targetParent = target.parentId ?? target.id;
      if (dragged.parentId == targetParent) return;
      final msg = await _moveOneFolder(dragged, targetParent);
      if (msg == null) {
        setState(() => _expandedFolders.add(targetParent));
      }
      await _load();
      if (mounted && msg != null) _snack(msg);
      return;
    }
  }

  // ---------- 批量操作 ----------

  /// 批量全选 / 全不选（复选框与「全选当前结果」文案共用：点文案也切换）。
  void _toggleSelectAll(List<Question> all) {
    setState(() {
      final selInList = all.where((q) => _selected.contains(q.id)).length;
      if (all.isNotEmpty && selInList == all.length) {
        _selected.clear();
      } else {
        _selected.addAll(all.map((q) => q.id));
      }
      _batchDeleteConfirm = false;
    });
  }

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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final t in tags)
                      QmChip(
                        label: t,
                        selected: picked.contains(t),
                        onTap: () => setDlg(() {
                          if (picked.contains(t)) {
                            picked.remove(t);
                          } else {
                            picked.add(t);
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
            QmButton(
              label: '取消',
              variant: QmButtonVariant.ghost,
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            QmButton(label: '确定', onPressed: () => Navigator.of(ctx).pop(true)),
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

  List<Folder> _batchFolderOptions() {
    if (_subjectId == null) return [];
    return _subjectFolders(_subjectId!)
        .where((f) => f.id != _folderId)
        .toList();
  }

  String _folderLabel(Folder f) {
    if (f.parentId == null) return f.name;
    final parent = _folders.firstWhere(
      (x) => x.id == f.parentId!,
      orElse: () => Folder(id: '', name: '', subjectId: ''),
    );
    return '${parent.name} / ${f.name}';
  }

  Future<void> _batchMoveToFolder([String? targetId]) async {
    final resolved = targetId ?? _batchFolderId;
    if (resolved == null) return;
    final target = _folders.firstWhere((f) => f.id == resolved);
    for (final id in _selected) {
      final q = _questions.firstWhere((x) => x.id == id);
      if (q.subjectId != target.subjectId) continue;
      var ids = q.folderIds.toList();
      // 在文件夹里进来时是“移入”（离开当前文件夹）；
      // 在「全部题目」进来时是“加入”（保留原有文件夹）。
      if (_folderId != null) ids.remove(_folderId);
      if (!ids.contains(target.id)) ids.add(target.id);
      await widget.repo.save(q.copyWith(folderIds: ids));
    }
    setState(() => _selected.clear());
    await _load();
  }

  Future<void> _batchMoveOut() async {
    if (_folderId == null) return;
    for (final id in _selected) {
      final q = _questions.firstWhere((x) => x.id == id);
      if (!q.folderIds.contains(_folderId)) continue;
      await widget.repo.save(
        q.copyWith(
          folderIds: q.folderIds.where((x) => x != _folderId).toList(),
        ),
      );
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

  Future<void> _batchDeleteConfirmed() async {
    for (final id in _selected.toList()) {
      final q = _questions.firstWhere((x) => x.id == id);
      await widget.repo.delete(q);
    }
    setState(() {
      _selected.clear();
      _batchDeleteConfirm = false;
    });
    await _load();
  }

  Future<void> _toggleFavorite(Question q) async {
    await widget.repo.toggleFavorite(q);
    await _load();
  }

  Future<void> _restoreArchived(Question q) async {
    await widget.repo.archive(q, archived: false);
    await _load();
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return switch (_view) {
      _View.shelf => _buildShelf(),
      _View.directory => _buildDirectory(),
      _View.list => _buildList(),
      _View.archived => _buildArchived(),
    };
  }

  /// 页标题（24px/800，HTML `h3.pt`）。
  Widget _pageTitle(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: DesignTokens.pageTitleFontSize,
        fontWeight: DesignTokens.pageTitleFontWeight,
      ),
    );
  }

  /// 副标题（13.5px muted，HTML `.psub`）。
  Widget _pageSubtitle(String text) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Padding(
      padding: const EdgeInsets.only(top: 3, bottom: 20),
      child: Text(
        text,
        style: TextStyle(
          fontSize: DesignTokens.bodySmallFontSize,
          color: palette.muted,
        ),
      ),
    );
  }

  /// 打开的书的外框（HTML `.nb-open`）：封面色底 + 内层 surface。
  /// 深色下打开的书仍是浅色纸页（见纸面容器）。
  Widget _openBookFrame({required String subjectId, required Widget child}) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final subject = _subjectOf(subjectId);
    final cover = CoverTokens.of(subject.coverColor);
    return Container(
      padding: EdgeInsets.all(DesignTokens.openPadding * scale),
      decoration: BoxDecoration(
        color: cover,
        borderRadius: BorderRadius.circular(DesignTokens.radius * scale),
        boxShadow: palette.shadow,
      ),
      child: Container(
        padding: EdgeInsets.fromLTRB(
          DesignTokens.bookInnerPaddingH * scale,
          DesignTokens.bookInnerPaddingV * scale,
          DesignTokens.bookInnerPaddingH * scale,
          DesignTokens.bookInnerPaddingBottom * scale,
        ),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(DesignTokens.radius * scale),
        ),
        child: child,
      ),
    );
  }

  /// 纸面容器（HTML `.nb-paper`）：纸色底 + 纸线边 + 纸面字。
  /// 深色下也是浅灰纸（`--paper` #D8DCE2）。
  Widget _paperBox({required Widget child, bool cards = false}) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Container(
      padding: cards
          ? EdgeInsets.all(14 * scale)
          : EdgeInsets.fromLTRB(20 * scale, 6 * scale, 14 * scale, 8 * scale),
      decoration: BoxDecoration(
        color: palette.paper,
        border: Border.all(color: palette.paperLine),
        borderRadius: BorderRadius.circular(8 * scale),
      ),
      child: child,
    );
  }

  /// 下拉框（HTML `.nb-fsel` / `.toolbar select`：line-strong 边、
  /// 圆角 10、13.5px、最小高 36px）。
  Widget _styledDropdown<T>({
    required T? value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
    Key? key,
  }) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Container(
      key: key,
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
          // 下拉箭头用文字符号（D3，不用图标字体）。
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

  /// 目录页行内操作按钮（HTML `.tbtn`：纸面上的小按钮）。
  Widget _paperActionButton({
    required String label,
    required VoidCallback onPressed,
    bool danger = false,
  }) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return _QmPaperButton(
      label: label,
      onPressed: onPressed,
      danger: danger,
      scale: scale,
      palette: palette,
    );
  }

  // ----- 书架 -----

  Widget _buildShelf() {
    const perPage = 6;
    final pages = (_subjects.length / perPage).ceil().clamp(1, 99);
    final page = _shelfPage.clamp(0, pages - 1);
    final books = _subjects.skip(page * perPage).take(perPage).toList();
    final archivedCount = _questions.where((q) => q.isArchived).length;
    final scale = qmScaleOf(context);
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _pageTitle('错题本'),
          _pageSubtitle('一科一本错题本，点一本打开看这一科的错题。'),
          _buildShelfTop(archivedCount),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth > 760;
              final gap = DesignTokens.shelfGridGap * scale;
              if (!wide) {
                return Column(
                  children: [
                    for (var i = 0; i < books.length; i++) ...[
                      if (i > 0) SizedBox(height: gap),
                      _buildBook(books[i]),
                    ],
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < books.length; i++) ...[
                    if (i > 0) SizedBox(width: gap),
                    Expanded(child: _buildBook(books[i])),
                  ],
                ],
              );
            },
          ),
          SizedBox(height: DesignTokens.shelfPagerMarginTop * scale),
          _buildShelfPager(page, pages),
        ],
      ),
    );
  }

  Widget _buildShelfTop(int archivedCount) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Padding(
      padding: EdgeInsets.only(bottom: 14 * scale),
      child: Row(
        children: [
          QmChip(
            label: '已归档（$archivedCount）',
            onTap: () => setState(() => _view = _View.archived),
          ),
          SizedBox(width: 10 * scale),
          Expanded(
            child: Text(
              '归档的题不在书里，点这里看归档列表、能恢复回错题本',
              style: TextStyle(fontSize: 13, color: palette.muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShelfPager(int page, int pages) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        QmButton(
          label: '← 上一页',
          variant: QmButtonVariant.plain,
          size: QmButtonSize.small,
          onPressed: page > 0
              ? () => setState(() => _shelfPage = page - 1)
              : null,
        ),
        SizedBox(width: 6 * scale),
        for (var i = 0; i < pages; i++) ...[
          if (i > 0) SizedBox(width: 6 * scale),
          _pageNumButton(
            i + 1,
            selected: i == page,
            onTap: () {
              setState(() => _shelfPage = i);
            },
          ),
        ],
        SizedBox(width: 6 * scale),
        QmButton(
          label: '下一页 →',
          variant: QmButtonVariant.plain,
          size: QmButtonSize.small,
          onPressed: page < pages - 1
              ? () => setState(() => _shelfPage = page + 1)
              : null,
        ),
        SizedBox(width: 12 * scale),
        Text(
          '第 ${page + 1} / $pages 页 · 共 ${_subjects.length} 本（每页最多 6 本）',
          style: TextStyle(
            fontSize: DesignTokens.pagerFontSize,
            color: palette.muted,
          ),
        ),
      ],
    );
  }

  Widget _pageNumButton(
    int number, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: BoxConstraints(
          minWidth: DesignTokens.pageNumMinWidth * scale,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: 10 * scale,
          vertical: 6 * scale,
        ),
        decoration: BoxDecoration(
          color: selected ? palette.accent : palette.surface,
          border: Border.all(
            color: selected ? palette.accent : palette.lineStrong,
          ),
          borderRadius: BorderRadius.circular(10 * scale),
        ),
        child: Text(
          '$number',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: DesignTokens.pagerFontSize,
            fontWeight: FontWeight.w700,
            color: selected ? palette.accentInk : palette.ink2,
            height: DesignTokens.controlLineHeight,
          ),
        ),
      ),
    );
  }

  Widget _buildBook(Subject s) {
    final scale = qmScaleOf(context);
    final counts = _counts[s.id] ?? (0, 0, 0);
    final total = _questions
        .where((q) => q.subjectId == s.id && q.isOrganized && !q.isArchived)
        .length;
    final coverColor = CoverTokens.of(s.coverColor);
    final enName = switch (s.id) {
      'english' => 'ENGLISH',
      'politics' => 'POLITICS',
      _ => 'MATHEMATICS',
    };
    return InkWell(
      onTap: () => _openDirectory(s.id),
      borderRadius: BorderRadius.only(
        topLeft: Radius.circular(6 * scale),
        topRight: Radius.circular(12 * scale),
        bottomLeft: Radius.circular(12 * scale),
        bottomRight: Radius.circular(12 * scale),
      ),
      child: Container(
        // 固定高（HTML `.nb-book` min-height 376px；内容按同一因子
        // 缩放后恒小于该高，固定高与最小高视觉等价，且让内层
        // Column + Spacer 有定界高度）。
        height: DesignTokens.bookMinHeight * scale,
        padding: EdgeInsets.fromLTRB(
          DesignTokens.bookPaddingH * scale,
          DesignTokens.bookPaddingTop * scale,
          DesignTokens.bookPaddingH * scale,
          DesignTokens.bookPaddingBottom * scale,
        ),
        decoration: BoxDecoration(
          color: coverColor,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(6 * scale),
            topRight: Radius.circular(12 * scale),
            bottomLeft: Radius.circular(12 * scale),
            bottomRight: Radius.circular(12 * scale),
          ),
          boxShadow: const [
            BoxShadow(
              offset: Offset(0, 10),
              blurRadius: 22,
              color: Color.fromRGBO(23, 35, 59, 0.20),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(6 * scale),
            topRight: Radius.circular(12 * scale),
            bottomLeft: Radius.circular(12 * scale),
            bottomRight: Radius.circular(12 * scale),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(painter: _CoverPatternPainter(s.coverStyle)),
              ),
              // 书脊（HTML `.nb-book-spine`：左侧 11px 暗条）。
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: DesignTokens.bookSpineWidth * scale,
                child: Container(
                  decoration: const BoxDecoration(
                    color: Color.fromRGBO(0, 0, 0, 0.20),
                    border: Border(
                      right: BorderSide(
                        color: Color.fromRGBO(255, 255, 255, 0.25),
                      ),
                    ),
                  ),
                ),
              ),
              // 折角（HTML `.nb-book-fold`：右上角 34px 纸色折角）。
              Positioned(
                right: 0,
                top: 0,
                width: DesignTokens.bookFoldSize * scale,
                height: DesignTokens.bookFoldSize * scale,
                child: CustomPaint(painter: _CoverFoldPainter(scale)),
              ),
              // 虚线内框（HTML `.nb-book::before`）。
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    15 * scale,
                    9 * scale,
                    9 * scale,
                    9 * scale,
                  ),
                  child: CustomPaint(
                    painter: _DashedBorderPainter(
                      color: const Color.fromRGBO(255, 255, 255, 0.55),
                      radius: 9 * scale,
                      strokeWidth: 1.6 * scale,
                    ),
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // 英文名（HTML `.nb-book-en`）。
                  Padding(
                    padding: EdgeInsets.only(left: 2 * scale, top: 26 * scale),
                    child: Text(
                      enName,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 4.08,
                        color: Colors.white,
                        height: 1.2,
                      ),
                    ),
                  ),
                  // 学科名（HTML `.nb-book-name`：52px/800）。
                  // 注：原型封面实际渲染为横排 52px 学科名 + 横排
                  // 「错 题 本」，无 `writing-mode: vertical-rl`；
                  // 任务书说的“竖排”与实际渲染不符，按实际渲染实现。
                  Text(
                    s.name,
                    style: const TextStyle(
                      fontSize: 52,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 3.12,
                      color: Colors.white,
                      height: 1.15,
                      shadows: [
                        Shadow(
                          offset: Offset(0, 2),
                          blurRadius: 5,
                          color: Color.fromRGBO(0, 0, 0, 0.22),
                        ),
                      ],
                    ),
                  ),
                  // 「错 题 本」（HTML `.nb-book-sub`：16px、字距 .85em）。
                  Padding(
                    padding: EdgeInsets.only(left: 6.8 * scale, top: 8 * scale),
                    child: const Text(
                      '错 题 本',
                      style: TextStyle(
                        fontSize: 16,
                        letterSpacing: 13.6,
                        color: Colors.white,
                        height: 1.2,
                      ),
                    ),
                  ),
                  const Spacer(),
                  // 计数牌（HTML `.nb-book-counts`）。
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 4 * scale,
                      vertical: 10 * scale,
                    ),
                    decoration: BoxDecoration(
                      color: const Color.fromRGBO(0, 0, 0, 0.20),
                      border: Border.all(
                        color: const Color.fromRGBO(255, 255, 255, 0.35),
                      ),
                      borderRadius: BorderRadius.circular(12 * scale),
                    ),
                    child: Row(
                      children: [
                        _bookStat('道题', total),
                        _bookStat('要复习', counts.$1),
                        _bookStat('待复查', counts.$2),
                      ],
                    ),
                  ),
                  SizedBox(height: 10 * scale),
                  // 封面内「开始复习」（HTML `.nb-cover-rev`）。
                  _CoverReviewButton(
                    label: '开始复习',
                    onPressed: () => widget.onGoReview(subjectId: s.id),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bookStat(String label, int value) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$value',
            style: const TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1.25,
            ),
          ),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.white,
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }

  // ----- 目录页 -----

  Widget _buildDirectory() {
    final subjectId = _subjectId!;
    final subject = _subjectOf(subjectId);
    final tops = _topFolders(subjectId);
    final kw = _folderSearch.trim().toLowerCase();
    final visibleTops = kw.isEmpty
        ? tops
        : tops.where((f) {
            if (f.name.toLowerCase().contains(kw)) return true;
            return _subFolders(f.id)
                .any((s) => s.name.toLowerCase().contains(kw));
          }).toList();
    // 搜到子文件夹时，它的父文件夹自动展开（不写回 _expandedFolders，
    // 展开状态不记住）。
    final effectiveExpanded = {..._expandedFolders};
    if (kw.isNotEmpty) {
      for (final f in visibleTops) {
        if (_subFolders(f.id).any((s) => s.name.toLowerCase().contains(kw))) {
          effectiveExpanded.add(f.id);
        }
      }
    }
    final scale = qmScaleOf(context);
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _pageTitle('${subject.name} · 错题本')),
              QmButton(
                label: '返回书架',
                variant: QmButtonVariant.plain,
                onPressed: _openShelf,
              ),
            ],
          ),
          SizedBox(height: 14 * scale),
          _buildDirectoryTools(),
          if (_selectingMove) _buildMoveSelBar(),
          if (_deleteConfirmFolder != null)
            _buildDeleteConfirm(_deleteConfirmFolder!),
          SizedBox(height: 12 * scale),
          _openBookFrame(
            subjectId: subjectId,
            child: _paperBox(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildAllRow(),
                  for (var i = 0; i < visibleTops.length; i++) ...[
                    _buildGapTarget(null, i),
                    _buildFolderRow(visibleTops[i], 0, effectiveExpanded),
                    if (effectiveExpanded.contains(visibleTops[i].id))
                      _buildKids(visibleTops[i], kw, effectiveExpanded),
                  ],
                  _buildGapTarget(null, visibleTops.length),
                  if (visibleTops.isEmpty)
                    Padding(
                      padding: EdgeInsets.only(
                        top: 28 * scale,
                        bottom: 24 * scale,
                      ),
                      child: Center(
                        child: Text(
                          kw.isEmpty ? '还没有文件夹，新建一个吧' : '没找到这个文件夹，换个词试试',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: DesignTokens.of(Theme.of(context).brightness)
                                .paperMuted,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDirectoryTools() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 40 * scale,
            child: TextField(
              controller: _folderSearchCtrl,
              decoration: InputDecoration(
                hintText: '搜索文件夹',
                hintStyle: TextStyle(color: palette.muted),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12 * scale,
                  vertical: 9 * scale,
                ),
              ),
              onChanged: (v) => setState(() => _folderSearch = v),
            ),
          ),
        ),
        SizedBox(width: 8 * scale),
        SizedBox(
          width: 200 * scale,
          height: 40 * scale,
          child: TextField(
            controller: _newFolderCtrl,
            decoration: InputDecoration(
              hintText: '新文件夹名称',
              hintStyle: TextStyle(color: palette.muted),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: 12 * scale,
                vertical: 9 * scale,
              ),
            ),
            onSubmitted: (_) => _addFolder(),
          ),
        ),
        SizedBox(width: 8 * scale),
        QmButton(
          label: '加文件夹',
          size: QmButtonSize.small,
          onPressed: () => _addFolder(),
        ),
        SizedBox(width: 8 * scale),
        QmButton(
          label: _selectingMove ? '退出选择' : '选择文件夹',
          variant: QmButtonVariant.plain,
          size: QmButtonSize.small,
          onPressed: () => setState(() {
            _selectingMove = !_selectingMove;
            if (!_selectingMove) _moveSelection.clear();
          }),
        ),
      ],
    );
  }

  Widget _buildMoveSelBar() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final subjectId = _subjectId!;
    final tops = _topFolders(subjectId);
    final selN = _moveSelection.length;
    return Container(
      margin: EdgeInsets.only(top: 12 * scale),
      padding: EdgeInsets.symmetric(
        horizontal: 12 * scale,
        vertical: 10 * scale,
      ),
      decoration: BoxDecoration(
        color: palette.surface2,
        border: Border.all(color: palette.line),
        borderRadius: BorderRadius.circular(DesignTokens.radius * scale),
      ),
      child: Wrap(
        spacing: 8 * scale,
        runSpacing: 8 * scale,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('已选 $selN 个文件夹', style: const TextStyle(fontSize: 13.5)),
          SizedBox(
            width: 220 * scale,
            child: _styledDropdown<String>(
              value: _moveTargetId,
              items: [
                const DropdownMenuItem(
                  value: '__top__',
                  child: Text('移到顶层（成为一级文件夹）'),
                ),
                for (final f in tops)
                  DropdownMenuItem(value: f.id, child: Text('移到「${f.name}」下面')),
              ],
              onChanged: (v) => setState(() {
                if (v != null) _moveTargetId = v;
              }),
            ),
          ),
          QmButton(
            label: '移动',
            size: QmButtonSize.small,
            onPressed: selN > 0 ? _moveSelected : null,
          ),
          QmButton(
            label: '退出选择',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: () => setState(() {
              _selectingMove = false;
              _moveSelection.clear();
            }),
          ),
          Text(
            '移动时里面的题跟着一起走；不能移到自己下面；带子文件夹的一级文件夹不能再放进别的文件夹（只留一层）',
            style: TextStyle(fontSize: 12.5, color: palette.muted),
          ),
        ],
      ),
    );
  }

  Widget _buildDeleteConfirm(Folder f) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final only = _folderDeleteCount(f.id);
    final multi = _folderDeleteMultiCount(f.id);
    final kidN = _subFolders(f.id).length;
    final subject = _subjectOf(f.subjectId);
    return Container(
      margin: EdgeInsets.only(top: 12 * scale),
      padding: EdgeInsets.all(14 * scale),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(color: palette.lineStrong),
        borderRadius: BorderRadius.circular(DesignTokens.radius * scale),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '删除这个文件夹会删掉其中 $only 道题（只在这个文件夹里的）'
            '${multi > 0 ? '，另外 $multi 道题还在别的文件夹里、只是从这个文件夹移走' : ''}'
            '${kidN > 0 ? '，它下面的 $kidN 个子文件夹也会一起删掉' : ''}，确定吗？',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          SizedBox(height: 6 * scale),
          Text(
            '要删的是${subject.name}的文件夹「${f.name}」，只删这一科的，其他科目的同名文件夹不受影响。',
            style: TextStyle(fontSize: 13.5, color: palette.muted),
          ),
          SizedBox(height: 10 * scale),
          Row(
            children: [
              QmButton(
                label: '确认删除',
                size: QmButtonSize.small,
                onPressed: () => _deleteFolderConfirmed(f),
              ),
              SizedBox(width: 8 * scale),
              QmButton(
                label: '取消',
                variant: QmButtonVariant.plain,
                size: QmButtonSize.small,
                onPressed: () => setState(() => _deleteConfirmFolder = null),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 「全部题目」行（目录最上面一行；拖到它上面 = 移回顶层）。
  Widget _buildAllRow() {
    final subjectId = _subjectId!;
    final total = _questions
        .where(
          (q) => q.subjectId == subjectId && q.isOrganized && !q.isArchived,
        )
        .length;
    return DragTarget<Folder>(
      onWillAcceptWithDetails: (_) {
        setState(() => _dragOverKey = 'promote');
        return true;
      },
      onLeave: (_) => setState(() => _dragOverKey = null),
      onAcceptWithDetails: (d) {
        setState(() => _dragOverKey = null);
        _applyDrop(d.data, null, _DropKind.promote);
      },
      builder: (context, candidate, rejected) {
        final highlight = _dragOverKey == 'promote';
        return Container(
          decoration: highlight
              ? BoxDecoration(
                  border: Border.all(
                    color: DesignTokens.of(Theme.of(context).brightness).accent,
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(6),
                  color: DesignTokens.of(Theme.of(context).brightness).accent
                      .withValues(alpha: 0.08),
                )
              : null,
          child: _tocRowContent(
            name: '全部题目',
            count: total,
            strong: true,
            onTap: () => _openList(folderId: null),
          ),
        );
      },
    );
  }

  /// 两行之间的拖放缝隙（调顺序用；平时只有 10px 高的透明条）。
  Widget _buildGapTarget(String? parentId, int index) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final key = 'gap:${parentId ?? 'top'}:$index';
    return DragTarget<Folder>(
      onWillAcceptWithDetails: (d) {
        final dragged = d.data;
        if (dragged.parentId != parentId) return false;
        setState(() => _dragOverKey = key);
        return true;
      },
      onLeave: (_) => setState(() => _dragOverKey = null),
      onAcceptWithDetails: (d) {
        setState(() => _dragOverKey = null);
        _reorderFolder(d.data, parentId, index);
      },
      builder: (context, candidate, rejected) {
        final highlight = _dragOverKey == key;
        return Container(
          height: 10 * scale,
          decoration: BoxDecoration(
            border: highlight
                ? Border(top: BorderSide(color: palette.accent, width: 3))
                : null,
          ),
        );
      },
    );
  }

  Widget _buildKids(Folder parent, String kw, Set<String> effectiveExpanded) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final kids = _subFolders(parent.id)
        .where((s) => kw.isEmpty || s.name.toLowerCase().contains(kw))
        .toList();
    return Container(
      margin: EdgeInsets.only(left: DesignTokens.tocKidsIndent * scale),
      // Row 用 stretch 拉满虚线左缘时需要有限高度：包 IntrinsicHeight
      //（目录树很小，量测开销可忽略）。
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
          // 子文件夹区左缘虚线（HTML `.nb-toc-kids`）。
          SizedBox(
            width: 2 * scale,
            child: CustomPaint(
              painter: _VerticalDashedPainter(color: palette.paperLine),
            ),
          ),
          Expanded(
            child: Column(
              children: [
                for (var i = 0; i < kids.length; i++) ...[
                  _buildGapTarget(parent.id, i),
                  _buildFolderRow(kids[i], 1, effectiveExpanded),
                ],
                _buildGapTarget(parent.id, kids.length),
              ],
            ),
          ),
          ],
        ),
      ),
    );
  }

  Widget _buildFolderRow(Folder f, int depth, Set<String> effectiveExpanded) {
    final isTop = depth == 0;
    final expanded = effectiveExpanded.contains(f.id);
    final kids = isTop ? _subFolders(f.id) : const <Folder>[];
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final rowKey = 'row:${f.id}';

    Widget rowContent;
    if (_renamingId == f.id) {
      rowContent = Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 36 * scale,
              child: TextField(
                controller: _renameCtrl,
                autofocus: true,
                decoration: const InputDecoration(isDense: true),
                onSubmitted: (_) => _saveRename(f),
              ),
            ),
          ),
          SizedBox(width: 8 * scale),
          _paperActionButton(label: '保存', onPressed: () => _saveRename(f)),
          SizedBox(width: 6 * scale),
          _paperActionButton(
            label: '取消',
            onPressed: () => setState(() => _renamingId = null),
          ),
        ],
      );
    } else {
      rowContent = Row(
        children: [
          if (isTop)
            SizedBox(
              width: DesignTokens.tocExpandWidth * scale,
              child: kids.isEmpty
                  ? const SizedBox.shrink()
                  : InkWell(
                      onTap: () => setState(() {
                        if (_expandedFolders.contains(f.id)) {
                          _expandedFolders.remove(f.id);
                        } else {
                          _expandedFolders.add(f.id);
                        }
                      }),
                      borderRadius: BorderRadius.circular(6 * scale),
                      child: Container(
                        constraints: BoxConstraints(
                          minHeight: DesignTokens.tocRowMinHeight * scale,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          expanded ? '▾' : '▸',
                          style: TextStyle(
                            fontSize: 14,
                            color: palette.paperMuted,
                          ),
                        ),
                      ),
                    ),
            ),
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
            child: _tocRowContent(
              name: f.name,
              count: _folderCount(f.id),
              sub: kids.isNotEmpty ? '${kids.length} 个子文件夹' : null,
              leftPadding: isTop ? 22 : 12,
              onTap: () {
                // 选择模式下点行 = 勾选 / 取消勾选（HTML bind）。
                if (_selectingMove) {
                  setState(() {
                    if (_moveSelection.contains(f.id)) {
                      _moveSelection.remove(f.id);
                    } else {
                      _moveSelection.add(f.id);
                    }
                  });
                } else {
                  _openList(folderId: f.id);
                }
              },
            ),
          ),
          Draggable<Folder>(
            data: f,
            onDragStarted: () => setState(() => _draggingId = f.id),
            onDragEnd: (_) => setState(() {
              _draggingId = null;
              _dragOverKey = null;
            }),
            feedback: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(8 * scale),
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 12 * scale,
                  vertical: 8 * scale,
                ),
                decoration: BoxDecoration(
                  color: palette.surface,
                  border: Border.all(color: palette.lineStrong),
                  borderRadius: BorderRadius.circular(8 * scale),
                ),
                child: Text(f.name),
              ),
            ),
            childWhenDragging: Opacity(
              opacity: 0.4,
              child: QmGlyph(
                QmGlyphs.drag,
                size: 15,
                color: palette.paperMuted,
              ),
            ),
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 8 * scale,
                  vertical: 8 * scale,
                ),
                child: QmGlyph(
                  QmGlyphs.drag,
                  size: 15,
                  color: palette.paperMuted,
                ),
              ),
            ),
          ),
          _paperActionButton(
            label: '改名',
            onPressed: () {
              _renameCtrl.text = f.name;
              setState(() => _renamingId = f.id);
            },
          ),
          SizedBox(width: 6 * scale),
          _paperActionButton(
            label: '删除',
            danger: true,
            onPressed: () => setState(() => _deleteConfirmFolder = f),
          ),
        ],
      );
    }

    final body = Container(
      constraints: BoxConstraints(
        minHeight:
            (isTop
                ? DesignTokens.tocRowMinHeight
                : DesignTokens.tocChildRowMinHeight) *
            scale,
      ),
      padding: EdgeInsets.only(right: 4 * scale),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.paperLine)),
      ),
      child: rowContent,
    );

    // 拖到行上 = 移进去（拖到子文件夹行上时落在其父文件夹下面）。
    return DragTarget<Folder>(
      onWillAcceptWithDetails: (d) {
        if (d.data.id == f.id) return false;
        setState(() => _dragOverKey = rowKey);
        return true;
      },
      onLeave: (_) => setState(() => _dragOverKey = null),
      onAcceptWithDetails: (d) {
        setState(() => _dragOverKey = null);
        _applyDrop(d.data, f, _DropKind.into);
      },
      builder: (context, candidate, rejected) {
        final highlight = _dragOverKey == rowKey;
        final dragging = _draggingId == f.id;
        return Opacity(
          opacity: dragging ? 0.45 : 1,
          child: Container(
            decoration: highlight
                ? BoxDecoration(
                    border: Border.all(color: palette.accent, width: 2),
                    borderRadius: BorderRadius.circular(6),
                    color: palette.accent.withValues(alpha: 0.08),
                  )
                : null,
            child: body,
          ),
        );
      },
    );
  }

  /// 目录行主体（纸面上的行：名 + 子文件夹数 + 题数 + ›）。
  /// 左缩进：顶层行 /「全部题目」22px（HTML `.nb-toc-row`），
  /// 子文件夹行 12px（HTML `.nb-toc-kids .nb-toc-row`）。
  Widget _tocRowContent({
    required String name,
    required int count,
    String? sub,
    bool strong = false,
    double leftPadding = 22,
    required VoidCallback onTap,
  }) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6 * scale),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          leftPadding * scale,
          DesignTokens.tocRowPaddingV * scale,
          DesignTokens.tocRowPaddingH * scale,
          DesignTokens.tocRowPaddingV * scale,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  fontSize: DesignTokens.tocRowNameFontSize,
                  fontWeight: strong ? FontWeight.w800 : FontWeight.w700,
                  color: palette.paperInk,
                  height: DesignTokens.controlLineHeight,
                ),
              ),
            ),
            if (sub != null) ...[
              Text(
                sub,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: palette.paperMuted,
                ),
              ),
              SizedBox(width: 8 * scale),
            ],
            Text(
              '$count 道题',
              style: TextStyle(
                fontSize: DesignTokens.tocCountFontSize,
                fontWeight: FontWeight.w700,
                color: palette.paperMuted,
              ),
            ),
            SizedBox(width: 8 * scale),
            Text(
              '›',
              style: TextStyle(
                fontSize: 18,
                color: palette.paperMuted,
                height: 1,
              ),
            ),
          ],
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
    final subject = _subjectId == null ? null : _subjectOf(_subjectId!);
    final folder = _folderId == null
        ? null
        : _folders.firstWhere(
            (f) => f.id == _folderId!,
            orElse: () =>
                Folder(id: _folderId!, name: '', subjectId: _subjectId ?? ''),
          );
    final title = _inBookArchived
        ? '${subject?.name ?? ''} · 错题本'
        : folder != null && folder.name.isNotEmpty
        ? '${subject?.name ?? ''} · 错题本'
        : subject != null
        ? '${subject.name} · 错题本'
        : '错题本';
    final scale = qmScaleOf(context);
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _pageTitle(title)),
              QmButton(
                label: '← 目录',
                variant: QmButtonVariant.plain,
                onPressed: () {
                  if (_subjectId != null) {
                    _openDirectory(_subjectId!);
                  } else {
                    _openShelf();
                  }
                },
              ),
              SizedBox(width: 8 * scale),
              QmButton(
                label: '合上 ✕',
                variant: QmButtonVariant.plain,
                onPressed: _openShelf,
              ),
            ],
          ),
          _pageSubtitle('这一科的题目列表，点一道题进题目详情；筛选里没有文件夹，文件夹在目录页选。'),
          _openBookFrame(
            subjectId: _subjectId ?? 'math',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildListToolbar(),
                if (_filterOpen) _buildFilterPanel(),
                if (!_inBookArchived) _buildMasteredNote(),
                if (_inBookArchived) _buildArchBar(all.length),
                if (_batchMode && !_inBookArchived) _buildBatchBar(all),
                _paperBox(
                  cards:
                      _viewMode == 'large' &&
                      !_inBookArchived &&
                      items.isNotEmpty,
                  child: _inBookArchived
                      ? _buildArchivedRows(items, orderIds)
                      : items.isEmpty
                      ? _buildPaperEmpty()
                      : _viewMode == 'large'
                      ? _buildLargeCards(items, orderIds)
                      : _buildCompactRows(items, orderIds),
                ),
                if (all.isNotEmpty)
                  _buildPagination(all.length, totalPages, page),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildListToolbar() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final filterCount = _activeFilterCount();
    // HTML `.toolbar` 是 flex-wrap：窄窗 / 大字号时换行，不溢出。
    return Padding(
      padding: EdgeInsets.only(bottom: 12 * scale),
      child: Wrap(
        spacing: 8 * scale,
        runSpacing: 8 * scale,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 280 * scale,
            height: 40 * scale,
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: '按题名 / 文件夹 / 标签 / 学科 / 试卷 / 日期查找',
                hintStyle: TextStyle(color: palette.muted),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 13 * scale,
                  vertical: 9 * scale,
                ),
              ),
              onChanged: (v) => setState(() {
                _search = v;
                _page = 0;
                _batchDeleteConfirm = false;
              }),
            ),
          ),
          QmChip(
            label: filterCount > 0
                ? '筛选（已选 $filterCount）${_filterOpen ? ' ▴' : ' ▾'}'
                : '筛选${_filterOpen ? ' ▴' : ' ▾'}',
            selected: _filterOpen,
            onTap: () => setState(() => _filterOpen = !_filterOpen),
          ),
          QmChip(label: '重置', onTap: _resetFilters),
          SizedBox(
            width: 200 * scale,
            child: _styledDropdown<String>(
              value: _sort,
              items: const [
                DropdownMenuItem(value: 'new', child: Text('排序：时间 新 → 旧')),
                DropdownMenuItem(value: 'old', child: Text('排序：时间 旧 → 新')),
                DropdownMenuItem(
                  value: 'subj-asc',
                  child: Text('排序：学科首字母 A → Z'),
                ),
                DropdownMenuItem(
                  value: 'subj-desc',
                  child: Text('排序：学科首字母 Z → A'),
                ),
                DropdownMenuItem(
                  value: 'status-asc',
                  child: Text('排序：错因状态 待解决 → 已解决'),
                ),
                DropdownMenuItem(
                  value: 'status-desc',
                  child: Text('排序：错因状态 已解决 → 待解决'),
                ),
              ],
              onChanged: (v) => setState(() {
                if (v != null) {
                  _sort = v;
                  _page = 0;
                }
              }),
            ),
          ),
          QmChip(
            label: '大卡片',
            selected: _viewMode == 'large',
            onTap: () => setState(() => _viewMode = 'large'),
          ),
          QmChip(
            label: '紧凑列表',
            selected: _viewMode == 'compact',
            onTap: () => setState(() => _viewMode = 'compact'),
          ),
          if (!_inBookArchived)
            QmChip(
              label: '批量操作',
              selected: _batchMode,
              onTap: () => setState(() {
                _batchMode = !_batchMode;
                _selected.clear();
                _batchDeleteConfirm = false;
              }),
            ),
        ],
      ),
    );
  }

  Widget _buildFilterPanel() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final errorTypes = <String>{...ErrorTypes.fixed};
    for (final q in _questions) {
      errorTypes.addAll(q.allCauses);
    }
    Widget cell(String label, Widget control) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: 4 * scale),
            child: Text(
              label,
              style: TextStyle(
                fontSize: DesignTokens.filterCellLabelFontSize,
                fontWeight: FontWeight.w700,
                color: palette.muted,
              ),
            ),
          ),
          control,
        ],
      );
    }

    return Container(
      margin: EdgeInsets.only(bottom: 14 * scale),
      padding: EdgeInsets.symmetric(
        horizontal: DesignTokens.filterPanelPaddingH * scale,
        vertical: DesignTokens.filterPanelPaddingV * scale,
      ),
      decoration: BoxDecoration(
        color: palette.surface2,
        border: Border.all(color: palette.lineStrong),
        borderRadius: BorderRadius.circular(DesignTokens.radiusLg * scale),
      ),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final cols = constraints.maxWidth > 700 ? 4 : 2;
              final rows = <Widget>[];
              final cells = [
                cell(
                  '试卷（来源）',
                  _styledDropdown<String>(
                    value: _filterExamId,
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('全部'),
                      ),
                      for (final e in _exams)
                        DropdownMenuItem(value: e.id, child: Text(e.name)),
                    ],
                    onChanged: (v) => setState(() {
                      _filterExamId = v;
                      _applyFilterChange(_filteredAll());
                    }),
                  ),
                ),
                cell(
                  '错误类型',
                  _styledDropdown<String>(
                    value: _filterErrorType,
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('全部'),
                      ),
                      for (final t in errorTypes)
                        DropdownMenuItem(value: t, child: Text(t)),
                    ],
                    onChanged: (v) => setState(() {
                      _filterErrorType = v;
                      _applyFilterChange(_filteredAll());
                    }),
                  ),
                ),
                cell(
                  '收集时间',
                  _styledDropdown<String>(
                    value: _filterTimeRange,
                    items: const [
                      DropdownMenuItem(value: 'all', child: Text('收集时间：全部')),
                      DropdownMenuItem(value: 'week', child: Text('最近一周')),
                      DropdownMenuItem(value: 'month', child: Text('最近一月')),
                    ],
                    onChanged: (v) => setState(() {
                      if (v != null) {
                        _filterTimeRange = v;
                        _applyFilterChange(_filteredAll());
                      }
                    }),
                  ),
                ),
                cell(
                  '错因状态',
                  _styledDropdown<String>(
                    value: _filterCauseStatus,
                    items: const [
                      DropdownMenuItem(value: 'all', child: Text('全部')),
                      DropdownMenuItem(value: 'pending', child: Text('待解决')),
                      DropdownMenuItem(value: 'inProgress', child: Text('解决中')),
                      DropdownMenuItem(value: 'solved', child: Text('已解决')),
                      DropdownMenuItem(value: 'recheck', child: Text('复查')),
                    ],
                    onChanged: (v) => setState(() {
                      if (v != null) {
                        _filterCauseStatus = v;
                        _applyFilterChange(_filteredAll());
                      }
                    }),
                  ),
                ),
              ];
              for (var i = 0; i < cells.length; i += cols) {
                rows.add(
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (
                        var j = i;
                        j < i + cols && j < cells.length;
                        j++
                      ) ...[
                        if (j > i) SizedBox(width: 14 * scale),
                        Expanded(child: cells[j]),
                      ],
                    ],
                  ),
                );
                if (i + cols < cells.length) {
                  rows.add(SizedBox(height: 10 * scale));
                }
              }
              return Column(children: rows);
            },
          ),
          SizedBox(height: 10 * scale),
          _filterOptionRow(
            label: '标签',
            children: [
              for (final t in _allTags)
                QmChip(
                  label: '#$t',
                  selected: _filterTags.contains(t),
                  onTap: () => setState(() {
                    if (_filterTags.contains(t)) {
                      _filterTags.remove(t);
                    } else {
                      _filterTags.add(t);
                    }
                    _applyFilterChange(_filteredAll());
                  }),
                ),
              for (final kpId in _filterKpIds)
                QmChip(
                  label:
                      '知识点：${_kps.firstWhere(
                        (k) => k.id == kpId,
                        orElse: () => const KnowledgePoint(id: '', subjectId: '', chapter: '', name: ''),
                      ).name}',
                  selected: true,
                  onDelete: () => setState(() {
                    _filterKpIds.remove(kpId);
                    _applyFilterChange(_filteredAll());
                  }),
                ),
              if (_filterCauseName != null)
                QmChip(
                  label: '错因：$_filterCauseName',
                  selected: true,
                  onDelete: () => setState(() {
                    _filterCauseName = null;
                    _applyFilterChange(_filteredAll());
                  }),
                ),
            ],
          ),
          _filterOptionRow(
            label: '只看',
            trailing: QmButton(
              label: '收起筛选',
              variant: QmButtonVariant.plain,
              size: QmButtonSize.small,
              onPressed: () => setState(() => _filterOpen = false),
            ),
            children: [
              QmChip(
                label: '仅收藏',
                selected: _filterFavorite,
                onTap: () => setState(() {
                  _filterFavorite = !_filterFavorite;
                  _applyFilterChange(_filteredAll());
                }),
              ),
              QmChip(
                label: '仅逾期',
                selected: _filterOverdue,
                onTap: () => setState(() {
                  _filterOverdue = !_filterOverdue;
                  _applyFilterChange(_filteredAll());
                }),
              ),
              QmChip(
                label: '已归档',
                selected: _inBookArchived,
                onTap: () => setState(() {
                  _inBookArchived = !_inBookArchived;
                  _page = 0;
                  _selected.clear();
                  _batchMode = false;
                  _batchDeleteConfirm = false;
                }),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _filterOptionRow({
    required String label,
    required List<Widget> children,
    Widget? trailing,
  }) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Container(
      constraints: BoxConstraints(
        minHeight: DesignTokens.filterRowMinHeight * scale,
      ),
      padding: EdgeInsets.symmetric(vertical: 4 * scale),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: DesignTokens.filterRowLabelWidth * scale,
            child: Padding(
              padding: EdgeInsets.only(top: 7 * scale),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: palette.muted,
                  height: 1,
                ),
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 8 * scale,
              runSpacing: 4 * scale,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: children,
            ),
          ),
          if (trailing != null) ...[SizedBox(width: 8 * scale), trailing],
        ],
      ),
    );
  }

  /// “错因全部已解决的题默认不显示”的提示（HTML `viewNotebook`）。
  Widget _buildMasteredNote() {
    if (_filterCauseStatus == 'solved') return const SizedBox.shrink();
    final hidden = _questions
        .where(
          (q) =>
              q.isOrganized &&
              !q.isArchived &&
              (_subjectId == null || q.subjectId == _subjectId) &&
              _isMastered(q),
        )
        .length;
    if (hidden == 0) return const SizedBox.shrink();
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Padding(
      padding: EdgeInsets.only(bottom: 10 * scale),
      child: Text(
        '这科错因已全部解决 $hidden 道默认不显示（在「筛选」里把错因状态选成「已解决」可看）',
        style: TextStyle(fontSize: 12.5, color: palette.muted),
      ),
    );
  }

  Widget _buildArchBar(int count) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Container(
      margin: EdgeInsets.only(bottom: 12 * scale),
      padding: EdgeInsets.symmetric(
        horizontal: 14 * scale,
        vertical: 10 * scale,
      ),
      decoration: BoxDecoration(
        color: palette.surface2,
        border: Border.all(color: palette.line),
        borderRadius: BorderRadius.circular(DesignTokens.radius * scale),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '已归档 · 共 $count 道 — 归档的题不在题目列表里，在这里能找回、能恢复',
              style: const TextStyle(fontSize: 14),
            ),
          ),
          QmButton(
            label: '← 返回题目列表',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: () => setState(() {
              _inBookArchived = false;
              _page = 0;
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildBatchBar(List<Question> all) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final selInList = all.where((q) => _selected.contains(q.id)).length;
    final allChecked = all.isNotEmpty && selInList == all.length;
    final someChecked = selInList > 0 && selInList < all.length;
    final options = _batchFolderOptions();
    // 下拉的当前值必须在选项里：存量值失效（文件夹被删）时回落到首项，
    // 不在 build 里写回状态。
    final batchFolderId = options.any((f) => f.id == _batchFolderId)
        ? _batchFolderId
        : (options.isNotEmpty ? options.first.id : null);
    final hasSelection = _selected.isNotEmpty;
    return Container(
      margin: EdgeInsets.only(bottom: 12 * scale),
      padding: EdgeInsets.symmetric(
        horizontal: 12 * scale,
        vertical: 10 * scale,
      ),
      decoration: BoxDecoration(
        color: palette.surface2,
        border: Border.all(color: palette.line),
        borderRadius: BorderRadius.circular(DesignTokens.radius * scale),
      ),
      child: Wrap(
        spacing: 8 * scale,
        runSpacing: 8 * scale,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                tristate: true,
                value: allChecked ? true : (someChecked ? null : false),
                onChanged: (_) => _toggleSelectAll(all),
              ),
              GestureDetector(
                onTap: () => _toggleSelectAll(all),
                child: const Text(
                  '全选当前结果',
                  style:
                      TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          Text(
            '已选 ${_selected.length} 道',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          QmButton(
            label: '批量加标签',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: hasSelection ? _batchAddTag : null,
          ),
          if (options.isNotEmpty)
            SizedBox(
              width: 200 * scale,
              child: _styledDropdown<String>(
                value: batchFolderId,
                items: [
                  for (final f in options)
                    DropdownMenuItem(value: f.id, child: Text(_folderLabel(f))),
                ],
                onChanged: (v) => setState(() {
                  if (v != null) _batchFolderId = v;
                }),
              ),
            ),
          QmButton(
            label: _folderId != null ? '批量移入文件夹' : '批量加入文件夹',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: hasSelection && options.isNotEmpty
                ? () => _batchMoveToFolder(batchFolderId)
                : null,
          ),
          if (_folderId != null)
            QmButton(
              label: '批量移出当前文件夹',
              variant: QmButtonVariant.plain,
              size: QmButtonSize.small,
              onPressed: hasSelection ? _batchMoveOut : null,
            ),
          QmButton(
            label: '批量收藏',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: hasSelection ? _batchFavorite : null,
          ),
          QmButton(
            label: '批量归档',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: hasSelection ? _batchArchive : null,
          ),
          if (_batchDeleteConfirm) ...[
            Text(
              '删了就没了，确定吗？',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: palette.errInk,
              ),
            ),
            QmButton(
              label: '确认删除',
              variant: QmButtonVariant.danger,
              size: QmButtonSize.small,
              onPressed: _batchDeleteConfirmed,
            ),
            QmButton(
              label: '取消',
              variant: QmButtonVariant.plain,
              size: QmButtonSize.small,
              onPressed: () => setState(() => _batchDeleteConfirm = false),
            ),
          ] else
            QmButton(
              label: '批量删除',
              variant: QmButtonVariant.plain,
              size: QmButtonSize.small,
              onPressed: hasSelection
                  ? () => setState(() => _batchDeleteConfirm = true)
                  : null,
            ),
          QmButton(
            label: '清除选择',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: hasSelection
                ? () => setState(() {
                    _selected.clear();
                    _batchDeleteConfirm = false;
                  })
                : null,
          ),
          QmButton(
            label: '退出批量',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: () => setState(() {
              _batchMode = false;
              _selected.clear();
              _batchDeleteConfirm = false;
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildPaperEmpty() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 12 * scale,
        vertical: 28 * scale,
      ),
      child: Column(
        children: [
          Text(
            _inBookArchived ? '这一本里还没有归档的题' : '没找到这道题，换个词试试',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: palette.paperInk,
            ),
          ),
          SizedBox(height: 4 * scale),
          Text(
            _inBookArchived ? '归档的题会放在这里，随时能恢复回错题本。' : '这一科里没有符合当前搜索与筛选的题。',
            style: TextStyle(fontSize: 13.5, color: palette.paperMuted),
          ),
          SizedBox(height: 12 * scale),
          QmButton(
            label: _inBookArchived ? '返回题目列表' : '清除全部筛选',
            size: QmButtonSize.small,
            onPressed: () {
              if (_inBookArchived) {
                setState(() => _inBookArchived = false);
              } else {
                _resetFilters();
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLargeCards(List<Question> items, List<String> orderIds) {
    final scale = qmScaleOf(context);
    final gap = DesignTokens.cardsGap * scale;
    final cards = <Widget>[
      for (var i = 0; i < items.length; i++)
        // 序号 = 本页内的位置（1, 2, 3…），随排序 / 筛选 / 分页重编号。
        _buildLargeCard(items[i], i + 1, orderIds),
    ];
    if (items.length > 2) {
      // >2 张卡：固定高度内部滚动容器（约 2.5 张卡，第三张露一半）。
      final palette = DesignTokens.of(Theme.of(context).brightness);
      return Container(
        height: DesignTokens.cardsScrollHeight * scale,
        padding: EdgeInsets.all(DesignTokens.cardsScrollPadding * scale),
        decoration: BoxDecoration(
          border: Border.all(color: palette.lineStrong),
          borderRadius: BorderRadius.circular(DesignTokens.radius * scale),
        ),
        child: ListView.separated(
          itemCount: cards.length,
          separatorBuilder: (_, __) => SizedBox(height: gap),
          itemBuilder: (context, i) => cards[i],
        ),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          cards[i],
        ],
      ],
    );
  }

  /// 大卡片一题一行：卡片本身就是整题切片（外层无背景 / 无边框 /
  /// 无阴影 / 无内边距；切片白底 + 细边框，封顶 160px、按比例缩放
  /// 绝不裁切）；左上角蓝色序号圆盘；卡片上不显示题名 / 学科 /
  /// 错误类型 / 标签 / 下次复习时间 / 收藏星。
  Widget _buildLargeCard(Question q, int number, List<String> orderIds) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Stack(
      children: [
        QuestionSlice(
          question: q,
          maxHeight: 160 * scale,
          fixedHeight: true,
          onTap: () => widget.onOpenDetail(q, orderIds),
        ),
        Positioned(
          top: 7 * scale,
          left: 7 * scale,
          child: IgnorePointer(
            child: Container(
              constraints: BoxConstraints(
                minWidth: DesignTokens.seqBadgeSize * scale,
              ),
              height: DesignTokens.seqBadgeSize * scale,
              padding: EdgeInsets.symmetric(horizontal: 7 * scale),
              decoration: BoxDecoration(
                color: palette.accent,
                borderRadius: BorderRadius.circular(999 * scale),
                border: Border.all(color: palette.surface, width: 2 * scale),
                boxShadow: const [
                  BoxShadow(
                    offset: Offset(0, 2),
                    blurRadius: 6,
                    color: Color.fromRGBO(23, 35, 59, 0.28),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: Text(
                '$number',
                style: TextStyle(
                  fontSize: DesignTokens.seqBadgeFontSize,
                  fontWeight: FontWeight.w800,
                  color: palette.accentInk,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
        if (_batchMode)
          Positioned(
            top: 9 * scale,
            left: DesignTokens.cardCheckLeft * scale,
            child: Container(
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(5 * scale),
              ),
              child: Checkbox(
                value: _selected.contains(q.id),
                onChanged: (v) => setState(() {
                  if (v == true) {
                    _selected.add(q.id);
                  } else {
                    _selected.remove(q.id);
                  }
                  _batchDeleteConfirm = false;
                }),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCompactRows(List<Question> items, List<String> orderIds) {
    final scale = qmScaleOf(context);
    return Column(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) QmRowLine(kind: QmRowLineKind.paper),
          _buildCompactRow(items[i], orderIds),
        ],
        SizedBox(height: 4 * scale),
      ],
    );
  }

  Widget _buildCompactRow(Question q, List<String> orderIds) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final nextRecheck = _nextRecheckOf(q);
    return InkWell(
      onTap: () => widget.onOpenDetail(q, orderIds),
      borderRadius: BorderRadius.circular(6 * scale),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          DesignTokens.prowPaddingLeft * scale,
          DesignTokens.prowPaddingV * scale,
          DesignTokens.prowPaddingH * scale,
          DesignTokens.prowPaddingV * scale,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_batchMode)
              Padding(
                padding: EdgeInsets.only(right: 8 * scale),
                child: Checkbox(
                  value: _selected.contains(q.id),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selected.add(q.id);
                    } else {
                      _selected.remove(q.id);
                    }
                    _batchDeleteConfirm = false;
                  }),
                ),
              ),
            GestureDetector(
              onTap: () => showQuestionZoomDialog(context, q),
              child: CompactSliceThumb(question: q),
            ),
            SizedBox(width: 12 * scale),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    q.title,
                    style: TextStyle(
                      fontSize: DesignTokens.prowTitleFontSize,
                      fontWeight: FontWeight.w700,
                      color: palette.paperInk,
                    ),
                  ),
                  SizedBox(height: 2 * scale),
                  _prowMetaLine(q),
                  SizedBox(height: 4 * scale),
                  Wrap(
                    spacing: 6 * scale,
                    runSpacing: 4 * scale,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final (cause, status) in _causeStatusesOf(q))
                        _causePill(cause, status),
                      Text(
                        '下次复查 ${nextRecheck == null ? '—' : '${nextRecheck.month}月${nextRecheck.day}日'}',
                        style: TextStyle(
                          fontSize: DesignTokens.prowDetailFontSize,
                          color: palette.paperMuted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(width: 8 * scale),
            _PaperStarButton(
              favorite: q.isFavorite,
              onPressed: () => _toggleFavorite(q),
            ),
            SizedBox(width: 4 * scale),
            Text(
              '›',
              style: TextStyle(
                fontSize: 18,
                color: palette.paperMuted,
                height: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 紧凑行 / 归档行明细行（HTML `.nb-prow .d`）：学科名着学科色
  ///（纸面取浅色档），其余取纸面次级色。学科取库里的 `_subjects`
  ///（B2 补充；以前 `Subject.byId` 未知 id 回退到数学名 +
  /// `subjectInk` 不传存色落到数学色）。
  Widget _prowMetaLine(Question q) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final subject = _subjects.firstWhere(
      (s) => s.id == q.subjectId,
      orElse: () => Subject.byId(q.subjectId),
    );
    final subjectInk =
        DesignTokens.subjectInk(q.subjectId, Brightness.light, subject.color);
    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: TextStyle(
          fontSize: DesignTokens.prowDetailFontSize,
          color: palette.paperMuted,
        ),
        children: [
          TextSpan(
            text: subject.name,
            style: TextStyle(color: subjectInk),
          ),
          TextSpan(
            text:
                ' · 错误类型：${q.allCauses.isEmpty ? '—' : q.allCauses.join('、')} · 标签：${q.tags.isEmpty ? '—' : q.tags.join('、')}',
          ),
        ],
      ),
    );
  }

  /// 紧凑行里的错因 pill：「错因·状态」，颜色与错因四态一致。
  Widget _causePill(String cause, String status) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final (bg, fg) = switch (status) {
      'pending' => (palette.warnBg, palette.warnInk),
      'inProgress' => (palette.infoBg, palette.infoInk),
      'solved' => (palette.accentSoft, palette.accentText),
      _ => (palette.errBg, palette.errInk),
    };
    final label = switch (status) {
      'pending' => '待解决',
      'inProgress' => '解决中',
      'solved' => '已解决',
      _ => '复查',
    };
    return QmStatusPill(label: '$cause·$label', background: bg, foreground: fg);
  }

  Widget _buildArchivedRows(List<Question> items, List<String> orderIds) {
    final scale = qmScaleOf(context);
    return Column(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) QmRowLine(kind: QmRowLineKind.paper),
          _buildArchivedRow(items[i], orderIds),
        ],
        SizedBox(height: 4 * scale),
      ],
    );
  }

  Widget _buildArchivedRow(Question q, List<String> orderIds) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return InkWell(
      onTap: () => widget.onOpenDetail(q, orderIds),
      borderRadius: BorderRadius.circular(6 * scale),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          DesignTokens.prowPaddingLeft * scale,
          DesignTokens.prowPaddingV * scale,
          DesignTokens.prowPaddingH * scale,
          DesignTokens.prowPaddingV * scale,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => showQuestionZoomDialog(context, q),
              child: CompactSliceThumb(question: q),
            ),
            SizedBox(width: 12 * scale),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          q.title,
                          style: TextStyle(
                            fontSize: DesignTokens.prowTitleFontSize,
                            fontWeight: FontWeight.w700,
                            color: palette.paperInk,
                          ),
                        ),
                      ),
                      SizedBox(width: 8 * scale),
                      QmStatusPill.tone(label: '已归档', tone: QmTone.warn),
                    ],
                  ),
                  SizedBox(height: 2 * scale),
                  _prowMetaLine(q),
                ],
              ),
            ),
            SizedBox(width: 8 * scale),
            QmButton(
              label: '恢复到错题本',
              variant: QmButtonVariant.plain,
              size: QmButtonSize.small,
              onPressed: () => _restoreArchived(q),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPagination(int total, int totalPages, int page) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Container(
      margin: EdgeInsets.only(top: DesignTokens.pagerMarginTop * scale),
      padding: EdgeInsets.only(top: DesignTokens.pagerPaddingTop * scale),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.line)),
      ),
      child: Row(
        children: [
          Text(
            '共 $total 道 · 第 ${page + 1} / $totalPages 页',
            style: TextStyle(
              fontSize: DesignTokens.pagerFontSize,
              color: palette.muted,
            ),
          ),
          SizedBox(width: 10 * scale),
          const Text('每页', style: TextStyle(fontSize: 13.5)),
          SizedBox(width: 4 * scale),
          SizedBox(
            width: 76 * scale,
            child: _styledDropdown<int>(
              value: _pageSize,
              items: [10, 20, 30, 40, 50]
                  .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
                  .toList(),
              onChanged: (v) => setState(() {
                if (v != null) {
                  _pageSize = v;
                  _page = 0;
                }
              }),
            ),
          ),
          SizedBox(width: 4 * scale),
          const Text('道', style: TextStyle(fontSize: 13.5)),
          const Spacer(),
          QmButton(
            label: '上一页',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: page > 0 ? () => setState(() => _page = page - 1) : null,
          ),
          SizedBox(width: 6 * scale),
          if (totalPages > 1)
            for (var i = 0; i < totalPages; i++) ...[
              if (i > 0) SizedBox(width: 6 * scale),
              _pageNumButton(
                i + 1,
                selected: i == page,
                onTap: () {
                  setState(() => _page = i);
                },
              ),
            ],
          if (totalPages > 1) SizedBox(width: 6 * scale),
          QmButton(
            label: '下一页',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: page < totalPages - 1
                ? () => setState(() => _page = page + 1)
                : null,
          ),
        ],
      ),
    );
  }

  // ----- 已归档（书架顶部入口，跨学科） -----

  Widget _buildArchived() {
    final archived = _questions.where((q) => q.isArchived).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final orderIds = archived.map((q) => q.id).toList();
    final scale = qmScaleOf(context);
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _pageTitle('已归档')),
              QmButton(
                label: '← 返回书架',
                variant: QmButtonVariant.plain,
                onPressed: _openShelf,
              ),
            ],
          ),
          SizedBox(height: 6 * scale),
          Text(
            '${archived.length} 道题',
            style: TextStyle(
              fontSize: 13.5,
              color: DesignTokens.of(Theme.of(context).brightness).muted,
            ),
          ),
          SizedBox(height: 14 * scale),
          if (archived.isEmpty)
            QmEmptyState(
              title: '还没有归档的题',
              description: '在打开的书里批量归档、或在题目详情里归档的题，会放在这里，随时能恢复回错题本。',
            )
          else
            _paperBox(child: _buildArchivedRows(archived, orderIds)),
        ],
      ),
    );
  }
}

/// 封面内「开始复习」按钮（HTML `.nb-cover-rev`：白底 95%、
/// #22304A 字、15px/800、圆角 12、全宽；点按不触发封面打开）。
class _CoverReviewButton extends StatelessWidget {
  const _CoverReviewButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12 * scale),
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(vertical: 9 * scale),
          decoration: BoxDecoration(
            color: const Color.fromRGBO(255, 255, 255, 0.95),
            borderRadius: BorderRadius.circular(12 * scale),
            boxShadow: const [
              BoxShadow(
                offset: Offset(0, 2),
                blurRadius: 6,
                color: Color.fromRGBO(0, 0, 0, 0.18),
              ),
            ],
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Color(0xFF22304A),
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}

/// 目录页行内操作按钮（HTML `.tbtn` 的 Flutter 实现：
/// 纸面上的小按钮，1px #B9AE8E 边、白底 65%、#3D4438 字、
/// 13px/700、圆角 10、最小高 34px；危险态为红字红边）。
class _QmPaperButton extends StatelessWidget {
  const _QmPaperButton({
    required this.label,
    required this.onPressed,
    required this.danger,
    required this.scale,
    required this.palette,
  });
  final String label;
  final VoidCallback onPressed;
  final bool danger;
  final double scale;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final border = danger ? palette.errLine : palette.paperBtnBorder;
    final fg = danger ? palette.errInk : palette.paperBtnText;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10 * scale),
        child: Container(
          constraints: BoxConstraints(minHeight: 34 * scale),
          padding: EdgeInsets.symmetric(
            horizontal: 12 * scale,
            vertical: 5 * scale,
          ),
          decoration: BoxDecoration(
            color: const Color.fromRGBO(255, 255, 255, 0.65),
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(10 * scale),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: fg,
              height: DesignTokens.controlLineHeight,
            ),
          ),
        ),
      ),
    );
  }
}

/// 折角（HTML `.nb-book-fold`：右上角纸色折角 + 斜边暗线）。
class _CoverFoldPainter extends CustomPainter {
  _CoverFoldPainter(this.scale);
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final fold = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(fold, Paint()..color = const Color(0xFFFFFDF4));
    final edge = Paint()
      ..color = const Color.fromRGBO(0, 0, 0, 0.16)
      ..strokeWidth = 1.5 * scale
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(0, size.height), Offset(size.width, 0), edge);
  }

  @override
  bool shouldRepaint(covariant _CoverFoldPainter oldDelegate) =>
      oldDelegate.scale != scale;
}

/// 竖向虚线（子文件夹区左缘，HTML `.nb-toc-kids` 的 `border-left`
/// 1px dashed）。
class _VerticalDashedPainter extends CustomPainter {
  _VerticalDashedPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const dash = 7.0;
    const gap = 4.0;
    var y = 0.0;
    while (y < size.height) {
      canvas.drawLine(
        Offset(size.width / 2, y),
        Offset(size.width / 2, (y + dash).clamp(0, size.height)),
        paint,
      );
      y += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _VerticalDashedPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 虚线圆角框（封面虚线内框用）。
class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({
    required this.color,
    required this.radius,
    required this.strokeWidth,
  });
  final Color color;
  final double radius;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      );
    const dash = 7.0;
    const gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var drawn = 0.0;
      final total = metric.length;
      while (drawn < total) {
        final segment = metric.extractPath(drawn, drawn + dash);
        canvas.drawPath(segment, paint);
        drawn += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.radius != radius ||
      oldDelegate.strokeWidth != strokeWidth;
}

/// 紧凑行里的收藏星（HTML `.nb-prow .nb-star`：
/// 未收藏 #B9C2CE、已收藏 #E8A13A，19px）。
class _PaperStarButton extends StatelessWidget {
  const _PaperStarButton({required this.favorite, required this.onPressed});
  final bool favorite;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return GestureDetector(
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(
          favorite ? '★' : '☆',
          style: TextStyle(
            fontSize: DesignTokens.prowStarFontSize,
            color: favorite ? palette.paperStarOn : palette.paperStar,
            height: 1,
          ),
        ),
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
            Offset(x, size.height),
            Offset(x + size.height, 0),
            paint,
          );
        }
      case 'double':
        final rect = Rect.fromLTWH(10, 10, size.width - 20, size.height - 20);
        canvas.drawRect(rect, paint);
        final inner = Rect.fromLTWH(16, 16, size.width - 32, size.height - 32);
        canvas.drawRect(inner, paint);
      case 'plain':
        // 折角（与右上角的 _CoverFoldPainter 叠加，保留基线形态）。
        final fold = Path()
          ..moveTo(size.width - 28, 0)
          ..lineTo(size.width, 28)
          ..lineTo(size.width, 0)
          ..close();
        canvas.drawPath(
          fold,
          Paint()..color = Colors.white.withValues(alpha: 0.28),
        );
    }
  }

  @override
  bool shouldRepaint(covariant _CoverPatternPainter oldDelegate) =>
      oldDelegate.style != style;
}
