import 'package:flutter/material.dart';

import '../../data/repository.dart';
import '../../models/models.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/uikit.dart';
import '../../widgets/widgets.dart';

part 'wrongbook_cover.dart';
part 'wrongbook_directory.dart';
part 'wrongbook_list.dart';
part 'wrongbook_shelf.dart';
part 'wrongbook_widgets.dart';

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
  // _load() 读库失败态（SR-P2-48）：报告 / 学科页同款——失败不一直
  // 转圈，出错误横幅 + 重试；已加载过内容时留住旧内容。
  bool _loadError = false;
  bool _errorDismissed = false;
  bool _hasLoaded = false;
  // 学科首字母（SR-P2-37）：按学科名首字算，不按 id 写死。
  // 常见学科首字有拼音首字母表（数学 S / 英语 Y / 政治 Z / 化学 H /
  // 物理 W ……）；拉丁字母开头直接取大写；表外汉字回退为该字本身
  //（仍可区分排序，不再统一落到同一档）。
  static const _pinyinInitials = {
    '数': 'S',
    '英': 'Y',
    '政': 'Z',
    '语': 'Y',
    '文': 'W',
    '化': 'H',
    '物': 'W',
    '生': 'S',
    '地': 'D',
    '历': 'L',
    '史': 'S',
    '外': 'W',
    '体': 'T',
    '音': 'Y',
    '美': 'M',
    '计': 'J',
    '高': 'G',
    '大': 'D',
    '普': 'P',
    '专': 'Z',
    '马': 'M',
    '思': 'S',
    '法': 'F',
    '经': 'J',
    '管': 'G',
    '工': 'G',
    '农': 'N',
    '医': 'Y',
    '药': 'Y',
    '心': 'X',
    '教': 'J',
    '育': 'Y',
    '科': 'K',
    '技': 'J',
    '信': 'X',
    '电': 'D',
    '机': 'J',
    '土': 'T',
    '建': 'J',
    '交': 'J',
    '商': 'S',
    '金': 'J',
    '财': 'C',
    '会': 'K',
    '审': 'S',
    '统': 'T',
    '概': 'G',
    '率': 'L',
    '线': 'X',
    '代': 'D',
    '微': 'W',
    '积': 'J',
    '分': 'F',
    '函': 'H',
    '导': 'D',
    '极': 'J',
    '限': 'X',
    '复': 'F',
    '变': 'B',
    '常': 'C',
    '偏': 'P',
    '军': 'J',
    '哲': 'Z',
    '逻': 'L',
    '伦': 'L',
    '日': 'R',
    '德': 'D',
    '毛': 'M',
    '中': 'Z',
    '形': 'X',
    '操': 'C',
    '离': 'L',
    '网': 'W',
    '据': 'J',
    '云': 'Y',
    '智': 'Z',
    '能': 'N',
    '自': 'Z',
    '动': 'D',
    '控': 'K',
    '仪': 'Y',
    '传': 'C',
    '感': 'G',
    '环': 'H',
    '资': 'Z',
    '源': 'Y',
    '矿': 'K',
    '测': 'C',
    '汽': 'Q',
    '航': 'H',
    '天': 'T',
    '海': 'H',
    '护': 'H',
    '临': 'L',
    '影': 'Y',
    '营': 'Y',
    '材': 'C',
  };

  String _subjectInitial(String subjectId) {
    final name = _subjectOf(subjectId).name.trim();
    if (name.isEmpty) return '';
    final first = name[0];
    if (first.codeUnitAt(0) < 128) return first.toUpperCase();
    return _pinyinInitials[first] ?? first;
  }

  /// 学科首字母 + 学科名比较（时间平局由调用方另行处理）。
  int _subjectKeyCompare(Question a, Question b) {
    final c = _subjectInitial(a.subjectId)
        .compareTo(_subjectInitial(b.subjectId));
    if (c != 0) return c;
    return _subjectOf(a.subjectId).name.compareTo(_subjectOf(b.subjectId).name);
  }

  List<Subject> _subjects = Subject.all;
  // 库里找学科：新学科用库里的名与色；找不到才回退 Subject.byId
  //（数学兜底，只发生在数据不一致时）。
  Subject _subjectOf(String id) =>
      _subjects.firstWhere((s) => s.id == id, orElse: () => Subject.byId(id));
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
  String _moveTargetId = '__top__';
  String? _renamingId;
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
  // 视图模式只在首次 _load() 时取设置默认值；之后用户在页内切换
  // （大卡片 / 紧凑列表）后，_load() 不再覆盖，避免从详情返回、
  // 批量操作、点星等刷新后被弹回默认视图（B2 leftover）。
  // 新进错题本（新 State 实例）时该标志为 false，仍读设置默认值。
  bool _viewModeInitialized = false;
  // 排序与每页条数同款（SR-P1-12）：只在首次 _load() 时取设置
  // 默认值，之后保留页内选择；“重置”固定回时间新→旧（SR-P2-58），
  // 不再回到设置默认值。
  bool _sortInitialized = false;
  bool _pageSizeInitialized = false;
  // 书架悬停的书（HTML `.nb-book:hover`：上移 4px、阴影加深）。
  // 只影响书架封面，不影响其它视图；未悬停时为 null。
  String? _hoverBookId;
  bool _batchMode = false;
  final Set<String> _selected = {};
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
    try {
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
        if (!_pageSizeInitialized) {
          _pageSize = settings.pageSize;
          _pageSizeInitialized = true;
        }
        // 只在首次加载时应用设置的默认视图；后续 _load()（详情返回、
        // 文件夹/批量操作、点星、恢复归档等触发的刷新）保留用户已切换
        // 的视图，不再弹回默认。
        if (!_viewModeInitialized) {
          _viewMode = settings.wrongbookView;
          _viewModeInitialized = true;
        }
        // 设置值先归一再用：旧库里可能存着 SR-P0-2 之前的 'subject'，
        // 列表下拉没有这一项，直接喂给 DropdownButton 会在 debug 下断言
        //（There should be exactly one item with [DropdownButton]'s value）。
        // 归一规则见 AppSettings.normalizeWrongbookSort：'subject' →
        // 'subj-asc'，未知值 → 'new'。
        final sort = AppSettings.normalizeWrongbookSort(settings.wrongbookSort);
        if (!_sortInitialized) {
          _sort = sort;
          _sortInitialized = true;
        }
        _loading = false;
        _loadError = false;
        _hasLoaded = true;
      });
    } catch (_) {
      // 读库失败：不一直转圈（SR-P2-48），出错误横幅 + 重试入口。
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = true;
        _errorDismissed = false;
      });
    }
  }

  Future<void> _retryLoad() async {
    setState(() {
      _loading = true;
      _loadError = false;
    });
    await _load();
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

  /// 目录文件夹行计数：与题目列表默认视图同一收录口径（SR-P2-38
  /// 决定 (a)）：只收已整理、未归档、未掌握的题；已掌握的题默认
  /// 不显示在列表里，行上写着的数就不再含它们（否则行写 5 道、
  /// 点进去只剩 3 道）。删文件夹的计数另有 [_folderDeleteCount]
  ///（删的是题本身，不跟这条口径）。
  int _folderCount(String folderId) {
    final ids = _subtreeIds(folderId);
    return _questions
        .where(
          (q) =>
              q.isOrganized &&
              !q.isArchived &&
              !_isMastered(q) &&
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
    final datePadded =
        '${q.createdAt.year}-${q.createdAt.month.toString().padLeft(2, '0')}-${q.createdAt.day.toString().padLeft(2, '0')}';
    // 两种写法都收（SR-P2-45）：搜 2026-11-05 与 2026-11-5 都命中。
    final datePlain =
        '${q.createdAt.year}-${q.createdAt.month}-${q.createdAt.day}';
    return [
      q.title,
      subject,
      ...folderNames,
      ...q.tags,
      examName,
      datePadded,
      datePlain,
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
      // “最近一周”= 7 天含今天（SR-P2-45 决定）：age < 7，
      // 不是 age <= 7（那是 8 天）。
      final limit = _filterTimeRange == 'week' ? 7 : 30;
      list = list.where((q) {
        final d = DateTime(
          q.createdAt.year,
          q.createdAt.month,
          q.createdAt.day,
        );
        final age = today.difference(d).inDays;
        return age >= 0 &&
            (_filterTimeRange == 'week' ? age < limit : age <= limit);
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
    // 学科首字母（SR-P2-37：按学科名首字算，见 [_subjectInitial]，
    // 不再写死数学/英语/其他三档）。错因状态排序：待解决 0 / 解决中 1 /
    // 复查 2 / 已解决 3（HTML `NB_STATUS_RANK`）。
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
      // 旧值 'subject' 的防御分支：_load 已归一，正常走不到这里；
      // 万一某处直接置了 _sort，仍按原意排，不静默回落到时间排序。
      case 'subject':
        list.sort((a, b) {
          final c = _subjectKeyCompare(a, b);
          return c != 0 ? c : b.createdAt.compareTo(a.createdAt);
        });
      case 'subj-desc':
        list.sort((a, b) {
          final c = _subjectKeyCompare(b, a);
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
  }

  /// 清搜索与筛选（不包 setState，供 _openList / _openDirectory 等
  /// 在自己的 setState 里调用；文件夹 / 学科是列表的归属范围，
  /// 不是筛选，不清）。
  /// 排序不在这里动：进另一科 / 文件夹只清搜索与筛选，排序保留
  /// 当前值（首次 _load() 应用的设置默认值、或用户页内改过的）。
  /// 之前这里把 _sort 也钉回 'new'，导致设置里的默认排序（如旧→新）
  /// 一进书就被抹掉、形同虚设——那是 SR-P2-58 决定 (a) 的适用范围
  /// 被扩错了地方，它只管“重置”按钮，见 _resetFilters。
  void _clearFilters() {
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
    _page = 0;
    _selected.clear();
  }

  /// “重置”按钮：清搜索与筛选，排序固定回时间新→旧
  ///（SR-P2-58 决定 (a)），不是设置默认值。
  void _resetFilters() {
    setState(() {
      _clearFilters();
      _sort = 'new';
    });
  }

  void _openList({String? subjectId, String? folderId}) {
    // 进另一科 / 另一文件夹时，上一范围的搜索与筛选不清零会带过来
    //（SR-P2-44），所以范围变化时清掉；同科同文件夹重进也清。
    // 排序不重置（见 _clearFilters）：用户在 A 书改的排序，进 B 书保留。
    setState(() {
      _clearFilters();
      _subjectId = subjectId ?? _subjectId;
      _folderId = folderId;
      _view = _View.list;
      _page = 0;
      _selected.clear();
      _batchMode = false;
      _inBookArchived = false;
    });
  }

  void _openDirectory(String subjectId) {
    setState(() {
      _clearFilters();
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
      _draggingId = null;
      _dragOverKey = null;
    });
  }

  void _openShelf() {
    setState(() {
      _clearFilters();
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
    // SR-P2-36：整科判重——同一学科下任何层级已有同名文件夹都拦下，
    // 不只同层兄弟（例如顶层新建“期中试卷”，子文件夹里已有同名也不行）。
    if (await widget.repo.folderNameExistsInSubject(subjectId, name)) {
      _snack('已经有了');
      return;
    }
    final maxOrder = siblings.isEmpty
        ? 0
        : siblings.map((f) => f.sortOrder).reduce((a, b) => a > b ? a : b);
    try {
      await widget.repo.saveFolder(
        Folder(
          id: 'folder-$subjectId-${DateTime.now().millisecondsSinceEpoch}',
          name: name,
          subjectId: subjectId,
          parentId: parentId,
          sortOrder: maxOrder + 10,
        ),
      );
    } on StateError {
      // upsertFolder 的最后一道防线：预检与保存之间被别处抢建同名时
      // 也只提示“已经有了”，不当未知错误报。
      _snack('已经有了');
      return;
    }
    _newFolderCtrl.clear();
    await _load();
  }

  Future<void> _saveRename(Folder f) async {
    final name = _renameCtrl.text.trim();
    if (name.isEmpty || name == f.name) {
      setState(() => _renamingId = null);
      return;
    }
    // SR-P2-36：整科判重——改名后同一学科下任何层级都不能有同名
    // （自身除外；例如把顶层“平时作业”改成子文件夹已有的“期中试卷”）。
    if (await widget.repo.folderNameExistsInSubject(
      f.subjectId,
      name,
      excludeId: f.id,
    )) {
      _snack('已经有了');
      return;
    }
    try {
      await widget.repo.saveFolder(
        Folder(
          id: f.id,
          name: name,
          subjectId: f.subjectId,
          parentId: f.parentId,
          sortOrder: f.sortOrder,
        ),
      );
    } on StateError {
      // upsertFolder 的最后一道防线：只提示“已经有了”，改名框保持
      // 打开、让用户换个名字，不当未知错误报。
      _snack('已经有了');
      return;
    }
    setState(() => _renamingId = null);
    await _load();
  }

  Future<void> _deleteFolderConfirmed(Folder f) async {
    await widget.repo.deleteFolder(f);
    await _load();
  }

  /// B3：文件夹删除确认（模态 AlertDialog；标题/说明文案与原来行内
  /// 确认条一致：只在该文件夹的题数、多文件夹的题数、子文件夹数）。
  Future<void> _askDeleteFolder(Folder f) async {
    final only = _folderDeleteCount(f.id);
    final multi = _folderDeleteMultiCount(f.id);
    final kidN = _subFolders(f.id).length;
    final subject = _subjectOf(f.subjectId);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          '删除这个文件夹会删掉其中 $only 道题（只在这个文件夹里的）'
          '${multi > 0 ? '，另外 $multi 道题还在别的文件夹里、只是从这个文件夹移走' : ''}'
          '${kidN > 0 ? '，它下面的 $kidN 个子文件夹也会一起删掉' : ''}，确定吗？',
        ),
        content: Text(
          '要删的是${subject.name}的文件夹「${f.name}」，只删这一科的，其他科目的同名文件夹不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) await _deleteFolderConfirmed(f);
  }

  /// B3：批量删除确认（模态 AlertDialog；原来行内条只有标题一句，
  /// 无补充文案，原样保留，不另加题数）。
  Future<void> _askBatchDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删了就没了，确定吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) await _batchDeleteConfirmed();
  }

  /// 移动文件夹（HTML `tocMoveFolder` 的禁则）：
  /// 已在目标处；不能移到自己 / 自己子文件夹下面；
  /// 带子文件夹的一级文件夹不能再放进别的文件夹（只留一层）；
  /// SR-P2-36：同一学科下已有同名文件夹（不论层级，自身除外）。
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
    }
    // SR-P2-36：整科判重——移入/移回时，同一学科下任何层级已有同名
    // 文件夹（自身除外）都拦下，不只看目标那一层。例如把顶层“期中试卷”
    // 移进“平时作业”下面，目标层是空的，但另一层级已有同名子文件夹，
    // 旧的只查目标层会放行，新规则拦下。
    if (await widget.repo.folderNameExistsInSubject(
      f.subjectId,
      f.name,
      excludeId: f.id,
    )) {
      return '同一学科下已经有同名文件夹「${f.name}」了';
    }
    final siblings = targetParentId == null
        ? _topFolders(f.subjectId)
        : _subFolders(targetParentId);
    final maxOrder = siblings.isEmpty
        ? 0
        : siblings.map((x) => x.sortOrder).reduce((a, b) => a > b ? a : b);
    try {
      await widget.repo.saveFolder(
        Folder(
          id: f.id,
          name: f.name,
          subjectId: f.subjectId,
          parentId: targetParentId,
          sortOrder: maxOrder + 10,
        ),
      );
    } on StateError {
      // upsertFolder 的最后一道防线：返回拦下原因，不当未知错误报。
      return '同一学科下已经有同名文件夹「${f.name}」了';
    }
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
  /// 缝隙下标是“删除前”的位置（SR-P2-42）：往下拖时先删被拖行再插，
  /// 目标下标须减 1，否则多移一位（A 拖到 A 与 B 之间的缝隙会落到 B 之后）。
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
    final fromIndex = siblings.indexWhere((f) => f.id == dragged.id);
    if (fromIndex < 0) return;
    siblings.removeAt(fromIndex);
    var idx = toIndex;
    if (idx > fromIndex) idx -= 1;
    idx = idx.clamp(0, siblings.length);
    siblings.insert(idx, dragged);
    // SR-P2-36 防线：调顺序不改名，正常情况下不会触发 upsertFolder 的
    // 整科同名把关；若库里已有遗留重名，只提示、不崩页。
    try {
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
    } on StateError {
      _snack('已经有了');
      return;
    }
    await _load();
  }

  /// 拖放落点处理（HTML `tocDropMode` / `tocApplyDrop`）：
  /// - 拖到「全部题目」上：子文件夹移回顶层；顶层文件夹排到最前面。
  /// - 拖到文件夹行上：移进去当它的子文件夹（拖到子文件夹行上时，
  ///   落在其父文件夹下面）；已在里面时不动。
  /// - 拖到两行之间：同层调顺序；缝隙只接受同层拖拽（SR-P2-43：
  ///   子文件夹拖到顶层行之间会被缝隙拒收，移回顶层请拖到
  ///   「全部题目」行）。
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
    });
  }

  /// 批量操作的安全查找（SR-P2-41）：勾选题可能在两次 _load() 间
  /// 被别处删掉/归档过滤掉，`firstWhere` 会抛 StateError 中断整批；
  /// 这里找不到返回 null，调用方计入“已不在列表里，跳过”。
  Question? _questionById(String id) {
    for (final q in _questions) {
      if (q.id == id) return q;
    }
    return null;
  }

  Folder? _folderById(String id) {
    for (final f in _folders) {
      if (f.id == id) return f;
    }
    return null;
  }

  /// 批量结果汇总提示（SR-P2-41）：成功 / 跨科跳过 / 已不在列表 /
  /// 保存失败各计一次，操作完一次说清，不再静默。
  void _snackBatchResult(
    String action,
    int ok,
    int missing,
    int failed, {
    int skipped = 0,
  }) {
    final parts = <String>[];
    if (ok > 0) parts.add('已$action $ok 道');
    if (skipped > 0) parts.add('跳过 $skipped 道其他学科的题');
    if (missing > 0) parts.add('$missing 道已不在列表里，跳过');
    if (failed > 0) parts.add('$failed 道保存失败，请重试');
    _snack(parts.isEmpty ? '没有题被$action' : parts.join('；'));
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
      // 新建标签与学科管理页同一禁令（SR-P2-40，§6 第 4 条）：
      // 含 , 或 | 的标签名直接拦截，不入库。
      final newName = newCtrl.text.trim();
      if (hasBannedNameSeparator(newName)) {
        _snack('不能含逗号或竖线');
        return;
      }
      await widget.repo.addTag(newName);
      picked.add(newName);
    }
    if (picked.isEmpty) return;
    var okN = 0;
    var missing = 0;
    var failed = 0;
    for (final id in _selected.toList()) {
      final q = _questionById(id);
      if (q == null) {
        missing++;
        continue;
      }
      try {
        final merged = {...q.tags, ...picked}.toList();
        await widget.repo.save(q.copyWith(tags: merged));
        okN++;
      } catch (_) {
        failed++;
      }
    }
    setState(() => _selected.clear());
    await _load();
    if (mounted) _snackBatchResult('加标签', okN, missing, failed);
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
    final target = _folderById(resolved);
    if (target == null) {
      _snack('目标文件夹找不到了');
      return;
    }
    var okN = 0;
    var missing = 0;
    var failed = 0;
    var skipped = 0;
    for (final id in _selected.toList()) {
      final q = _questionById(id);
      if (q == null) {
        missing++;
        continue;
      }
      // 跨学科勾选（从错因/知识点筛选进的跨学科列表）：目标文件夹
      // 是当前科的，其他科的题移不进去，计入跳过并提示（SR-P2-41），
      // 不再静默清空选择。
      if (q.subjectId != target.subjectId) {
        skipped++;
        continue;
      }
      try {
        var ids = q.folderIds.toList();
        // 在文件夹里进来时是“移入”（离开当前文件夹）；
        // 在「全部题目」进来时是“加入”（保留原有文件夹）。
        if (_folderId != null) ids.remove(_folderId);
        if (!ids.contains(target.id)) ids.add(target.id);
        await widget.repo.save(q.copyWith(folderIds: ids));
        okN++;
      } catch (_) {
        failed++;
      }
    }
    setState(() => _selected.clear());
    await _load();
    if (mounted) {
      _snackBatchResult('移入文件夹', okN, missing, failed, skipped: skipped);
    }
  }

  Future<void> _batchMoveOut() async {
    if (_folderId == null) return;
    var okN = 0;
    var missing = 0;
    var failed = 0;
    for (final id in _selected.toList()) {
      final q = _questionById(id);
      if (q == null) {
        missing++;
        continue;
      }
      if (!q.folderIds.contains(_folderId)) {
        okN++;
        continue;
      }
      try {
        await widget.repo.save(
          q.copyWith(
            folderIds: q.folderIds.where((x) => x != _folderId).toList(),
          ),
        );
        okN++;
      } catch (_) {
        failed++;
      }
    }
    setState(() => _selected.clear());
    await _load();
    if (mounted) _snackBatchResult('移出文件夹', okN, missing, failed);
  }

  Future<void> _batchFavorite() async {
    var okN = 0;
    var missing = 0;
    var failed = 0;
    for (final id in _selected.toList()) {
      final q = _questionById(id);
      if (q == null) {
        missing++;
        continue;
      }
      if (q.isFavorite) {
        okN++;
        continue;
      }
      try {
        await widget.repo.toggleFavorite(q);
        okN++;
      } catch (_) {
        failed++;
      }
    }
    setState(() => _selected.clear());
    await _load();
    if (mounted) _snackBatchResult('收藏', okN, missing, failed);
  }

  Future<void> _batchArchive() async {
    var okN = 0;
    var missing = 0;
    var failed = 0;
    for (final id in _selected.toList()) {
      final q = _questionById(id);
      if (q == null) {
        missing++;
        continue;
      }
      try {
        await widget.repo.archive(q);
        okN++;
      } catch (_) {
        failed++;
      }
    }
    setState(() => _selected.clear());
    await _load();
    if (mounted) _snackBatchResult('归档', okN, missing, failed);
  }

  Future<void> _batchDeleteConfirmed() async {
    var okN = 0;
    var missing = 0;
    var failed = 0;
    for (final id in _selected.toList()) {
      final q = _questionById(id);
      if (q == null) {
        missing++;
        continue;
      }
      try {
        await widget.repo.delete(q);
        okN++;
      } catch (_) {
        failed++;
      }
    }
    setState(() {
      _selected.clear();
    });
    await _load();
    if (mounted) _snackBatchResult('删除', okN, missing, failed);
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

  /// 同库视图 extension（书架 / 目录 / 列表）触发重建的入口，与 setState 等价。
  /// setState 是 @protected，只能在 State 子类的实例成员里直接调用，
  /// extension 方法里调用会触发 invalid_use_of_protected_member，
  /// 故由本方法转发；行为与调用点均不变。
  void _update(VoidCallback fn) => setState(fn);

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final view = switch (_view) {
      _View.shelf => _buildShelf(),
      _View.directory => _buildDirectory(),
      _View.list => _buildList(),
      _View.archived => _buildArchived(),
    };
    // 读库失败（SR-P2-48）：首次加载即失败时出错误页（横幅 + 重试）；
    // 已有内容时在内容上方出横幅，留住旧内容。
    if (_loadError && !_errorDismissed) {
      final banner = QmBanner(
        tone: QmBannerTone.error,
        message: '错题本数据读取失败，已显示上次成功加载的内容。',
        actions: [QmBannerAction(label: '重试', onPressed: _retryLoad)],
        onDismiss: () => setState(() => _errorDismissed = true),
      );
      if (!_hasLoaded) {
        return SingleChildScrollView(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _pageTitle('错题本'),
              SizedBox(height: 14 * qmScaleOf(context)),
              banner,
            ],
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          banner,
          Expanded(child: view),
        ],
      );
    }
    return view;
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
  /// 跨学科列表（`_subjectId == null`）时用中性灰外框（SR-P2-54），
  /// 不再回退成数学封面色。
  Widget _openBookFrame({
    required String subjectId,
    required Widget child,
    bool neutral = false,
  }) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final subject = _subjectOf(subjectId);
    final cover = neutral
        ? CoverTokens.of('grey')
        : CoverTokens.of(subject.coverColor);
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
}
