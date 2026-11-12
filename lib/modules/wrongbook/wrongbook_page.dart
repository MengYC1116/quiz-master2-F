import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:quiz_master2/data/demo_data.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/widgets.dart';

/// 错题本：书架 → 打开一本（本页内切换状态，不跳路由）。
///
/// 定稿口径要点：
/// - 书架默认三本并排、封面朝前；一页最多 6 本，超 6 本分页。
/// - 打开后是纸页列表，搜索 / 筛选 / 重置 / 排序只对当前打开的这一科生效，无学科筛选。
/// - 大卡片默认视图：一道题一行，卡片里只留整题图切片；紧凑列表可切换。
/// - 已掌握默认不显示，用复习状态筛选才可查看；列表不显示答案、试卷来源、
///   复习次数、收集时间，无序号（大卡片序号除外）。
/// - 演示：英语长篇阅读 q-eng-2 设为加载失败，显示学科图标 + 题目类型文字兜底。
enum _WrongbookView { shelf, book, archived }

enum _ListViewMode { largeCards, compact }

enum _SortOption {
  timeDesc('时间新→旧'),
  timeAsc('时间旧→新'),
  subjectAsc('学科首字母升序'),
  subjectDesc('学科首字母降序'),
  reviewStatus('复习状态');

  const _SortOption(this.label);
  final String label;
}

class WrongbookPage extends StatefulWidget {
  const WrongbookPage({
    super.key,
    required this.repo,
    this.initialSubjectId,
    required this.onOpenHome,
  });

  final QuestionRepository repo;
  final String? initialSubjectId;

  /// 空状态按钮用它回首页（本页空状态不设“去收集吧”按钮：
  /// 去收集的入口在首页，这里只提供回首页）。
  final VoidCallback onOpenHome;

  @override
  State<WrongbookPage> createState() => _WrongbookPageState();
}

class _WrongbookPageState extends State<WrongbookPage> {
  List<Question> _questions = [];
  bool _loading = true;

  _WrongbookView _view = _WrongbookView.shelf;
  String? _openedSubjectId;
  int _shelfPage = 0;

  // ---- 书内状态（只对当前打开的一科生效）----
  final _searchController = TextEditingController();
  String _search = '';
  bool _filterOpen = false;
  final Set<String> _folderFilter = {};
  final Set<String> _errorFilter = {};
  final Set<String> _tagFilter = {};
  String? _examFilter; // examId，null = 全部试卷
  String _timeFilter = 'all'; // all / week / month
  String? _reviewFilter; // null = 默认仅复习中；inReview / mastered / all
  bool _onlyFavorite = false;
  bool _onlyOverdue = false;
  bool _archivedOnly = false; // 筛选面板里的“已归档”
  _SortOption _sort = _SortOption.timeDesc;
  _ListViewMode _viewMode = _ListViewMode.largeCards;
  int _page = 0;
  int _pageSize = 10;

  // ---- 按需批量 ----
  bool _batchMode = false;
  final Set<String> _selected = {};

  // ---- 列表滚动条（常驻可见，预览 ::-webkit-scrollbar 口径）----
  final _cardScrollController = ScrollController();
  final _compactScrollController = ScrollController();

  // 试卷 id → 名称（演示数据；仓库暂无试卷查询口径）。
  Map<String, String> get _examNames =>
      {for (final e in demoExams()) e.id: e.name};

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      final value = _searchController.text.trim();
      if (value != _search) {
        setState(() {
          _search = value;
          _page = 0;
        });
      }
    });
    _load();
    // initialSubjectId 不为空时直接打开对应那一本。
    if (widget.initialSubjectId != null &&
        Subject.all.any((s) => s.id == widget.initialSubjectId)) {
      _view = _WrongbookView.book;
      _openedSubjectId = widget.initialSubjectId;
    }
  }

  @override
  void didUpdateWidget(covariant WrongbookPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 从首页点另一科进错题本时，同一 State 复用，要跟上新的 initialSubjectId。
    if (widget.initialSubjectId != null &&
        widget.initialSubjectId != oldWidget.initialSubjectId &&
        Subject.all.any((s) => s.id == widget.initialSubjectId)) {
      _openBook(widget.initialSubjectId!);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _cardScrollController.dispose();
    _compactScrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final list = await widget.repo.all(includeArchived: true);
    if (!mounted) return;
    setState(() {
      _questions = list;
      _loading = false;
    });
  }

  void _openBook(String subjectId) {
    setState(() {
      _view = _WrongbookView.book;
      _openedSubjectId = subjectId;
      _resetBookState();
    });
  }

  void _closeBook() {
    setState(() {
      _view = _WrongbookView.shelf;
      _openedSubjectId = null;
      _exitBatchMode();
    });
  }

  /// 重置：清搜索与全部筛选、排序回时间新→旧、列表回全部题。
  void _resetBookState() {
    // 先把 _search 置空再清输入框，避免监听器在 setState 回调里再触发一次 setState。
    _search = '';
    _searchController.clear();
    _filterOpen = false;
    _folderFilter.clear();
    _errorFilter.clear();
    _tagFilter.clear();
    _examFilter = null;
    _timeFilter = 'all';
    _reviewFilter = null;
    _onlyFavorite = false;
    _onlyOverdue = false;
    _archivedOnly = false;
    _sort = _SortOption.timeDesc;
    _page = 0;
    _exitBatchMode();
  }

  void _exitBatchMode() {
    _batchMode = false;
    _selected.clear();
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _openDetail(Question q) {
    // 本期题目详情页未实现，占位。
    _showSnack('题目详情页尚未实现');
  }

  // ---------- 计数 ----------

  // 错题本只收“整理确认完成”的题（边界文档口径）：未整理（待整理队列里）
  // 的题不进书架计数、不进书内列表、不参与今日到期 / 逾期统计（D-26）。
  List<Question> _subjectQuestions(String subjectId, {bool archived = false}) =>
      _questions
          .where((q) =>
              q.subjectId == subjectId &&
              q.isOrganized &&
              q.isArchived == archived)
          .toList();

  int _dueTodayCount(String subjectId) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return _subjectQuestions(subjectId).where((q) {
      return q.reviewStatus == ReviewStatus.inReview &&
          (q.overdueDays > 0 ||
              q.nextReview == null ||
              !q.nextReview!.isAfter(today));
    }).length;
  }

  // ---------- 书内筛选 / 排序 / 分页 ----------

  bool _matchesSearch(Question q) {
    if (_search.isEmpty) return true;
    final keyword = _search;
    final subjectName = Subject.byId(q.subjectId).name;
    final examName = q.examId == null ? '' : (_examNames[q.examId] ?? q.examId!);
    // 搜文件夹 / 标签 / 学科 / 试卷 / 时间，不搜题干、不搜标题。
    final timeTexts = <String>{
      '${q.createdAt.year}-${q.createdAt.month}-${q.createdAt.day}',
      '${q.createdAt.month}-${q.createdAt.day}',
      if (q.nextReview != null)
        '${q.nextReview!.month}-${q.nextReview!.day}',
    };
    return q.folderIds.any((f) => f.contains(keyword)) ||
        q.tags.any((t) => t.contains(keyword)) ||
        subjectName.contains(keyword) ||
        examName.contains(keyword) ||
        timeTexts.any((t) => t.contains(keyword));
  }

  List<Question> get _filtered {
    final subjectId = _openedSubjectId;
    if (subjectId == null) return const [];
    final now = DateTime.now();
    var list = _questions
        .where((q) => q.subjectId == subjectId && q.isOrganized)
        .toList();
    // 归档：默认只看未归档；筛选面板勾“已归档”则只看已归档。
    list = list.where((q) => q.isArchived == _archivedOnly).toList();
    // 已掌握默认不显示，用复习状态筛选才可查看。
    switch (_reviewFilter) {
      case 'inReview':
        list = list.where((q) => q.reviewStatus == ReviewStatus.inReview).toList();
      case 'mastered':
        list = list.where((q) => q.reviewStatus == ReviewStatus.mastered).toList();
      case 'all':
        break;
      default:
        list = list.where((q) => q.reviewStatus == ReviewStatus.inReview).toList();
    }
    if (_folderFilter.isNotEmpty) {
      list = list
          .where((q) => q.folderIds.any(_folderFilter.contains))
          .toList();
    }
    if (_examFilter != null) {
      list = list.where((q) => q.examId == _examFilter).toList();
    }
    if (_errorFilter.isNotEmpty) {
      list = list
          .where((q) =>
              [...q.errorTypes, ...q.customErrorTypes]
                  .any(_errorFilter.contains))
          .toList();
    }
    if (_tagFilter.isNotEmpty) {
      list = list.where((q) => q.tags.any(_tagFilter.contains)).toList();
    }
    if (_timeFilter == 'week') {
      list = list
          .where((q) => q.createdAt.isAfter(now.subtract(const Duration(days: 7))))
          .toList();
    } else if (_timeFilter == 'month') {
      list = list
          .where((q) => q.createdAt.isAfter(now.subtract(const Duration(days: 30))))
          .toList();
    }
    if (_onlyFavorite) {
      list = list.where((q) => q.isFavorite).toList();
    }
    if (_onlyOverdue) {
      list = list.where((q) => q.overdueDays > 0).toList();
    }
    list = list.where(_matchesSearch).toList();
    switch (_sort) {
      case _SortOption.timeDesc:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case _SortOption.timeAsc:
        list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      case _SortOption.subjectAsc:
      case _SortOption.subjectDesc:
        // 书内只有一科，学科首字母排序无实际区分，保持时间新→旧为稳定顺序。
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case _SortOption.reviewStatus:
        list.sort((a, b) =>
            a.reviewStatus.index.compareTo(b.reviewStatus.index));
    }
    return list;
  }

  int get _totalPages {
    final total = _filtered.length;
    if (total == 0) return 1;
    return (total / _pageSize).ceil();
  }

  List<Question> get _pageItems {
    final list = _filtered;
    final start = (_page * _pageSize).clamp(0, list.length);
    final end = ((_page + 1) * _pageSize).clamp(0, list.length);
    return list.sublist(start, end);
  }

  void _goPage(int page) {
    setState(() => _page = page.clamp(0, _totalPages - 1));
  }

  // ---------- 批量操作 ----------

  Future<void> _batchAddTag() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => _PickDialog(
        title: '批量加标签',
        options: [
          ...presetTags,
          ..._filtered.expand((q) => q.tags),
        ].toSet().toList(),
      ),
    );
    if (picked == null) return;
    final count = _selected.length;
    for (final q in _questions.where((q) => _selected.contains(q.id))) {
      if (!q.tags.contains(picked)) {
        await widget.repo.save(q.copyWith(tags: [...q.tags, picked]));
      }
    }
    await _load();
    setState(_selected.clear);
    _showSnack('已给 $count 道题加标签');
  }

  Future<void> _batchAddFolder() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => _PickDialog(
        title: '加入文件夹',
        options: [
          ...presetFolders,
          ..._filtered.expand((q) => q.folderIds),
        ].toSet().toList(),
      ),
    );
    if (picked == null) return;
    for (final q in _questions.where((q) => _selected.contains(q.id))) {
      if (!q.folderIds.contains(picked)) {
        await widget.repo.save(q.copyWith(folderIds: [...q.folderIds, picked]));
      }
    }
    await _load();
    setState(_selected.clear);
  }

  Future<void> _batchFavorite() async {
    for (final q in _questions.where((q) => _selected.contains(q.id))) {
      if (!q.isFavorite) {
        await widget.repo.save(q.copyWith(isFavorite: true));
      }
    }
    await _load();
    setState(_selected.clear);
    _showSnack('已收藏');
  }

  Future<void> _batchArchive() async {
    for (final q in _questions.where((q) => _selected.contains(q.id))) {
      await widget.repo.archive(q, archived: true);
    }
    await _load();
    setState(_selected.clear);
    _showSnack('已归档');
  }

  Future<void> _batchDelete() async {
    // 删除两步确认：先点批量栏“删除”，再在弹窗里确认一次。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除错题'),
        content: Text('删了就没了，确定删除选中的 ${_selected.length} 道题吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final q in _questions.where((q) => _selected.contains(q.id))) {
      await widget.repo.delete(q);
    }
    await _load();
    setState(() {
      _selected.clear();
      _page = 0;
    });
  }

  // ---------- 放大层（紧凑列表缩略图） ----------

  void _showEnlarged(Question q) {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) => Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          // Esc 关闭放大层。
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            Navigator.of(context).pop();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Dialog(
          child: Padding(
            padding: const EdgeInsets.all(16),
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
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // 演示：q-eng-2 加载失败，显示学科图标 + 题目类型文字兜底。
                QuestionSlice(
                  question: q,
                  maxHeight: 400,
                  failed: q.id == 'q-eng-2',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    switch (_view) {
      case _WrongbookView.shelf:
        return _buildShelf();
      case _WrongbookView.book:
        return _buildBook();
      case _WrongbookView.archived:
        return _buildArchived();
    }
  }

  // ---------- 书架 ----------

  Widget _buildShelf() {
    const booksPerPage = 6; // 一页最多 6 本书
    final totalPages = (Subject.all.length / booksPerPage).ceil();
    final start = _shelfPage * booksPerPage;
    final pageSubjects =
        Subject.all.skip(start).take(booksPerPage).toList();
    final archivedCount =
        _questions.where((q) => q.isArchived).length;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('错题本', style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              // 书架顶的“已归档”入口：跨学科归档列表。
              TextButton.icon(
                onPressed: () => setState(() => _view = _WrongbookView.archived),
                icon: const Icon(Icons.archive_outlined),
                label: Text('已归档（$archivedCount）'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // 三本错题本并排、封面朝前。
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final subject in pageSubjects) ...[
                Expanded(child: _buildBookCover(subject)),
                if (subject != pageSubjects.last) const SizedBox(width: 20),
              ],
            ],
          ),
          const Spacer(),
          // 书架分页：演示只有 3 本，显示第 1/1 页，按钮禁用。
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: _shelfPage > 0
                    ? () => setState(() => _shelfPage--)
                    : null,
                child: const Text('上一页'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text('第 ${_shelfPage + 1}/$totalPages 页'),
              ),
              TextButton(
                onPressed: _shelfPage < totalPages - 1
                    ? () => setState(() => _shelfPage++)
                    : null,
                child: const Text('下一页'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBookCover(Subject subject) {
    final qs = _subjectQuestions(subject.id);
    final due = _dueTodayCount(subject.id);
    final overdue =
        qs.where((q) => q.overdueDays > 0).length;
    // 封面点按开书：只包上半部分（头像 / 标题 / 计数牌），“开始复习”
    // 按钮放在手势区外面——外层 GestureDetector 的 tap 会赢过内层按钮
    // 的手势竞争（先注册先赢），之前按钮包在里面时点按钮会误触开书（D-27）。
    return Container(
      height: 320,
      decoration: BoxDecoration(
        color: subject.color,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 12,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Stack(
        children: [
            // 书脊：左侧 11px 深色脊条 + 白色细边（预览 .nb-book-spine）。
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              child: Container(
                width: 11,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.20),
                  border: Border(
                    right: BorderSide(
                      color: Colors.white.withValues(alpha: 0.25),
                    ),
                  ),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(12),
                    bottomLeft: Radius.circular(12),
                  ),
                ),
              ),
            ),
            // 缝线：白色虚线框（预览 .nb-book::before，inset 9/9/9/15）。
            Positioned(
              top: 9,
              right: 9,
              bottom: 9,
              left: 15,
              child: CustomPaint(painter: _DashedBorderPainter()),
            ),
            // 底部页边：白底纸页边。
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                height: 10,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.85),
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(12),
                    bottomRight: Radius.circular(12),
                  ),
                ),
              ),
            ),
            // 折角效果（Container + 圆角 + 阴影近似）：右上角浅色折角。
            Positioned(
              top: 0,
              right: 0,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.28),
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(12),
                    bottomLeft: Radius.circular(12),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GestureDetector(
                    onTap: () => _openBook(subject.id),
                    behavior: HitTestBehavior.opaque,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        CircleAvatar(
                          backgroundColor:
                              Colors.white.withValues(alpha: 0.25),
                          radius: 24,
                          child: Text(subject.icon,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 22)),
                        ),
                        const SizedBox(height: 12),
                        const Text('错题本',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(height: 16),
                        // 计数牌：题数 / 今日到期 / 逾期。
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              _coverCount('${qs.length}', '题数'),
                              _coverCount('$due', '今日到期'),
                              _coverCount('$overdue', '逾期'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // “开始复习”按钮在开书手势区外面，点按只弹占位提示，不打开书。
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: subject.color,
                    ),
                    onPressed: () => _showSnack('复习模块尚未实现'),
                    child: const Text('开始复习'),
                  ),
                ],
              ),
            ),
          ],
        ),
    );
  }

  Widget _coverCount(String value, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800)),
        Text(label,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85), fontSize: 12)),
      ],
    );
  }

  // ---------- 已归档（跨学科） ----------

  Widget _buildArchived() {
    final archived = _questions.where((q) => q.isArchived).toList();
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TextButton.icon(
                onPressed: () => setState(() => _view = _WrongbookView.shelf),
                icon: const Icon(Icons.chevron_left),
                label: const Text('返回书架'),
              ),
              const SizedBox(width: 8),
              Text('已归档', style: Theme.of(context).textTheme.titleLarge),
            ],
          ),
          const SizedBox(height: 16),
          if (archived.isEmpty)
            const Expanded(
              child: EmptyState(message: '还没有归档的错题'),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: archived.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final q = archived[index];
                  return Card(
                    child: ListTile(
                      leading: SubjectLabel(subjectId: q.subjectId),
                      title: Text(q.title),
                      subtitle: Text(
                          '错误类型：${[...q.errorTypes, ...q.customErrorTypes].join('、')}'),
                      trailing: TextButton(
                        onPressed: () async {
                          await widget.repo.archive(q, archived: false);
                          await _load();
                          _showSnack('已恢复');
                        },
                        child: const Text('恢复'),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  // ---------- 打开的书 ----------

  Widget _buildBook() {
    final subject = Subject.byId(_openedSubjectId ?? 'math');
    final filtered = _filtered;
    final pageItems = _pageItems;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // 打开的书：纸页容器（干净纸面，无横线/网格，预览口径），
    // 纸页左缘不要亮蓝竖条（预览 .nb-paper 无左缘色条），纸页带淡淡的纸边阴影。
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Container(
        decoration: BoxDecoration(
          color: dark ? AppTheme.darkPaper : AppTheme.lightPaper,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: dark
                  ? const Color(0xFF333B47)
                  : AppTheme.lightPaperLine),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _closeBook,
                    icon: const Icon(Icons.chevron_left),
                    label: const Text('合上'),
                  ),
                  const SizedBox(width: 8),
                  Text('${subject.name}错题本',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(width: 12),
                  Text('共 ${filtered.length} 道',
                      style: Theme.of(context).textTheme.bodySmall),
                  const Spacer(),
                  // 书内“开始复习”：按当前筛选出的题开始复习（边界文档“出”口径，
                  // 决定 (19)）；复习模块未实现，先弹占位提示（D-28）。
                  // 放标题行右端，不挤搜索框（放工具栏会把搜索提示挤成“…”）。
                  FilledButton(
                    onPressed: () => _showSnack('复习模块尚未实现'),
                    child: const Text('开始复习'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildToolbar(subject),
              if (_filterOpen) ...[
                const SizedBox(height: 12),
                _buildFilterPanel(subject),
              ],
              if (_batchMode) ...[
                const SizedBox(height: 12),
                _buildBatchBar(),
              ],
              const SizedBox(height: 16),
              if (filtered.isEmpty)
                Expanded(
                  child: EmptyState(
                    message: '这里还没有错题，去收集吧',
                    actionLabel: '回首页',
                    // 空状态按钮回首页；去收集的入口在首页。
                    onAction: widget.onOpenHome,
                  ),
                )
              else if (_viewMode == _ListViewMode.largeCards)
                _buildLargeCardList(pageItems)
              else
                Expanded(child: _buildCompactList(pageItems)),
              const SizedBox(height: 16),
              _buildListPagination(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar(Subject subject) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        // 搜索框：搜文件夹 / 标签 / 学科 / 试卷 / 时间，不搜题干。
        // 提示文字缩短 + 字号 13，保证完整显示不截断成“…”。
        Expanded(
          child: TextField(
            controller: _searchController,
            decoration: const InputDecoration(
              hintText: '搜文件夹、标签、学科、试卷、时间',
              hintStyle: TextStyle(fontSize: 13),
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: () => setState(() => _filterOpen = !_filterOpen),
          icon: const Icon(Icons.filter_list),
          label: const Text('筛选'),
        ),
        const SizedBox(width: 8),
        // 重置：一键清搜索与全部筛选、排序回时间新→旧、列表回全部题。
        OutlinedButton(
          onPressed: () => setState(_resetBookState),
          child: const Text('重置'),
        ),
        const SizedBox(width: 8),
        DropdownButton<_SortOption>(
          value: _sort,
          items: _SortOption.values
              .map((o) => DropdownMenuItem(value: o, child: Text(o.label)))
              .toList(),
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              _sort = value;
              _page = 0;
            });
          },
        ),
        const SizedBox(width: 8),
        // 分段切换选中色按预览：选中是实心强调蓝 + 白字（深色雾蓝 + 深字），
        // 不要默认的青绿色 secondaryContainer。
        SegmentedButton<_ListViewMode>(
          style: SegmentedButton.styleFrom(
            selectedBackgroundColor:
                dark ? AppTheme.darkNavSelected : AppTheme.accent,
            selectedForegroundColor:
                dark ? const Color(0xFF131A24) : Colors.white,
            foregroundColor: Theme.of(context).textTheme.bodySmall?.color,
            backgroundColor:
                dark ? AppTheme.darkSurface : AppTheme.lightSurface,
            side: BorderSide(
                color: dark
                    ? const Color(0xFF485364)
                    : AppTheme.lightLineStrong),
          ),
          segments: const [
            ButtonSegment(
                value: _ListViewMode.largeCards,
                icon: Icon(Icons.crop_landscape),
                label: Text('大卡片')),
            ButtonSegment(
                value: _ListViewMode.compact,
                icon: Icon(Icons.list),
                label: Text('紧凑列表')),
          ],
          selected: {_viewMode},
          onSelectionChanged: (selected) {
            setState(() => _viewMode = selected.first);
          },
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: () {
            setState(() {
              // 再点一次退出批量模式并清掉勾选。
              if (_batchMode) {
                _exitBatchMode();
              } else {
                _batchMode = true;
              }
            });
          },
          child: Text(_batchMode ? '退出批量' : '批量操作'),
        ),
      ],
    );
  }

  Widget _buildFilterPanel(Subject subject) {
    // 无学科筛选：书内只有当前这一科。
    final subjectQs = _subjectQuestions(subject.id);
    final folders = <String>{
      ...presetFolders,
      ...subjectQs.expand((q) => q.folderIds),
    }.toList();
    final errorTypes = <String>{
      ...ErrorTypes.fixed,
      ...subjectQs.expand((q) => q.errorTypes),
      ...subjectQs.expand((q) => q.customErrorTypes),
    }.toList();
    final tags = <String>{
      ...presetTags,
      ...subjectQs.expand((q) => q.tags),
    }.toList();
    final exams = <String>{
      for (final q in subjectQs)
        if (q.examId != null) q.examId!,
    }.toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _filterSection(
              '文件夹',
              Wrap(
                spacing: 8,
                children: folders
                    .map((f) => FilterChip(
                          label: Text(f),
                          selected: _folderFilter.contains(f),
                          onSelected: (selected) {
                            setState(() {
                              if (selected) {
                                _folderFilter.add(f);
                              } else {
                                _folderFilter.remove(f);
                              }
                              _page = 0;
                            });
                          },
                        ))
                    .toList(),
              ),
            ),
            _filterSection(
              '试卷',
              DropdownButton<String?>(
                value: _examFilter,
                hint: const Text('全部试卷'),
                items: [
                  const DropdownMenuItem<String?>(
                      value: null, child: Text('全部试卷')),
                  for (final id in exams)
                    DropdownMenuItem<String?>(
                        value: id, child: Text(_examNames[id] ?? id)),
                ],
                onChanged: (value) {
                  setState(() {
                    _examFilter = value;
                    _page = 0;
                  });
                },
              ),
            ),
            _filterSection(
              '错误类型',
              Wrap(
                spacing: 8,
                children: errorTypes
                    .map((e) => FilterChip(
                          label: Text(e),
                          selected: _errorFilter.contains(e),
                          onSelected: (selected) {
                            setState(() {
                              if (selected) {
                                _errorFilter.add(e);
                              } else {
                                _errorFilter.remove(e);
                              }
                              _page = 0;
                            });
                          },
                        ))
                    .toList(),
              ),
            ),
            _filterSection(
              '时间',
              DropdownButton<String>(
                value: _timeFilter,
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('全部时间')),
                  DropdownMenuItem(value: 'week', child: Text('最近一周')),
                  DropdownMenuItem(value: 'month', child: Text('最近一个月')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _timeFilter = value;
                    _page = 0;
                  });
                },
              ),
            ),
            _filterSection(
              '复习状态',
              DropdownButton<String?>(
                value: _reviewFilter,
                hint: const Text('仅复习中（默认）'),
                items: const [
                  DropdownMenuItem<String?>(
                      value: null, child: Text('仅复习中（默认）')),
                  DropdownMenuItem<String?>(
                      value: 'inReview', child: Text('复习中')),
                  DropdownMenuItem<String?>(
                      value: 'mastered', child: Text('已掌握')),
                  DropdownMenuItem<String?>(
                      value: 'all', child: Text('全部')),
                ],
                onChanged: (value) {
                  setState(() {
                    _reviewFilter = value;
                    _page = 0;
                  });
                },
              ),
            ),
            _filterSection(
              '标签',
              Wrap(
                spacing: 8,
                children: tags
                    .map((t) => FilterChip(
                          label: Text(t),
                          selected: _tagFilter.contains(t),
                          onSelected: (selected) {
                            setState(() {
                              if (selected) {
                                _tagFilter.add(t);
                              } else {
                                _tagFilter.remove(t);
                              }
                              _page = 0;
                            });
                          },
                        ))
                    .toList(),
              ),
            ),
            Wrap(
              spacing: 16,
              children: [
                FilterChip(
                  label: const Text('仅收藏'),
                  selected: _onlyFavorite,
                  onSelected: (v) => setState(() {
                    _onlyFavorite = v;
                    _page = 0;
                  }),
                ),
                FilterChip(
                  label: const Text('仅逾期'),
                  selected: _onlyOverdue,
                  onSelected: (v) => setState(() {
                    _onlyOverdue = v;
                    _page = 0;
                  }),
                ),
                FilterChip(
                  label: const Text('已归档'),
                  selected: _archivedOnly,
                  onSelected: (v) => setState(() {
                    _archivedOnly = v;
                    _page = 0;
                  }),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterSection(String title, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }

  // ---------- 大卡片 ----------

  Widget _buildLargeCardList(List<Question> pageItems) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // 固定高度滚动容器：最多一次性完整展示两道题、第三张露一半提示下面还有。
    // 高度 466 按两张半卡实测；右侧滚动条常驻可见。
    return SizedBox(
      height: 466, // 按两张半卡实测
      child: Scrollbar(
        thumbVisibility: true,
        controller: _cardScrollController,
        child: ListView.separated(
          controller: _cardScrollController,
          itemCount: pageItems.length,
          separatorBuilder: (_, __) => const SizedBox(height: 20),
          itemBuilder: (context, index) {
            final q = pageItems[index];
            // 序号按当前页顺序排，排序 / 筛选 / 翻页后重新编号。
            final number = _page * _pageSize + index + 1;
            return Stack(
              children: [
                // 卡片里只留整题图切片：图片就是卡片，外层无背景。
                // QuestionSlice 自带白底 + 1px 细边框 + 限高 160px。
                QuestionSlice(
                  question: q,
                  maxHeight: 160,
                  fixedHeight: true,
                  failed: q.id == 'q-eng-2',
                  onTap: () => _openDetail(q),
                ),
                Positioned(
                  top: 8,
                  left: 8,
                  child: CircleAvatar(
                    radius: 13,
                    backgroundColor:
                        dark ? AppTheme.darkNavSelected : AppTheme.accent,
                    child: Text('$number',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w700)),
                  ),
                ),
              if (_batchMode)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Checkbox(
                      value: _selected.contains(q.id),
                      onChanged: (checked) {
                        setState(() {
                          if (checked == true) {
                            _selected.add(q.id);
                          } else {
                            _selected.remove(q.id);
                          }
                        });
                      },
                    ),
                  ),
                ),
            ],
          );
          },
        ),
      ),
    );
  }

  // ---------- 紧凑列表 ----------
  //
  // 预览 .nb-prow 口径：一行一道题的扁平列表行，不是白卡：
  // 行内只有 64×48 缩略图 + 题名 + 一行详情（学科 · 错误类型 · 标签 ·
  // 下次复习时间）+ 收藏星 + 右箭头；行间是纸线虚线分隔，悬停淡蓝底。
  Widget _buildCompactList(List<Question> pageItems) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final paperLine =
        dark ? AppTheme.darkPaperLine : AppTheme.lightPaperLine;
    return Scrollbar(
      thumbVisibility: true,
      controller: _compactScrollController,
      child: ListView.separated(
        controller: _compactScrollController,
        itemCount: pageItems.length,
        separatorBuilder: (_, __) => DashedDivider(color: paperLine),
        itemBuilder: (context, index) {
          final q = pageItems[index];
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _openDetail(q),
              hoverColor: const Color(0x122F7CF6),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 10, 6, 10),
                child: Row(
                  children: [
                    if (_batchMode) ...[
                      Checkbox(
                        value: _selected.contains(q.id),
                        onChanged: (checked) {
                          setState(() {
                            if (checked == true) {
                              _selected.add(q.id);
                            } else {
                              _selected.remove(q.id);
                            }
                          });
                        },
                      ),
                      const SizedBox(width: 4),
                    ],
                    // 行首 64×48 整题图小缩略图：题干微缩线 + 配图 + 选项行，
                    // 点缩略图弹出放大层看整题图。
                    GestureDetector(
                      onTap: () => _showEnlarged(q),
                      child: CompactSliceThumb(
                        question: q,
                        failed: q.id == 'q-eng-2',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(q.title,
                              style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          _buildCompactDetail(q),
                        ],
                      ),
                    ),
                    // 收藏星：行内直接切换。
                    IconButton(
                      icon: Icon(
                        q.isFavorite ? Icons.star : Icons.star_border,
                        color: q.isFavorite ? Colors.amber : null,
                      ),
                      tooltip: q.isFavorite ? '取消收藏' : '收藏',
                      onPressed: () async {
                        await widget.repo.toggleFavorite(q);
                        await _load();
                      },
                    ),
                    const Icon(Icons.chevron_right,
                        size: 20, color: Color(0xFF9AA7B8)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 紧凑行详情单行（预览 .nb-prow .d）：
  /// 学科 · 错误类型：X · 标签：Y · 下次复习时间（逾期标红）。
  Widget _buildCompactDetail(Question q) {
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    final errorText = [...q.errorTypes, ...q.customErrorTypes].join('、');
    final tagText = q.tags.join('、');
    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: TextStyle(fontSize: 12.5, color: muted),
        children: [
          TextSpan(
            text: Subject.byId(q.subjectId).name,
            style: TextStyle(
              color: subjectLabelColor(context, q.subjectId),
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(
              text: ' · 错误类型：${errorText.isEmpty ? '—' : errorText}'),
          TextSpan(text: ' · 标签：${tagText.isEmpty ? '—' : tagText}'),
          TextSpan(
            text: ' · ${q.nextReviewLabel}',
            style: TextStyle(
              color: q.overdueDays > 0 ? Colors.red : muted,
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 批量栏 ----------

  Widget _buildBatchBar() {
    final filtered = _filtered;
    final selectedInView =
        filtered.where((q) => _selected.contains(q.id)).length;
    final allSelected =
        filtered.isNotEmpty && selectedInView == filtered.length;
    final someSelected = selectedInView > 0 && !allSelected;
    final hasSelection = _selected.isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            // 全选当前结果，含半选态（tristate）。
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  tristate: true,
                  value: allSelected
                      ? true
                      : (someSelected ? null : false),
                  onChanged: (checked) {
                    setState(() {
                      if (checked == true) {
                        _selected.addAll(filtered.map((q) => q.id));
                      } else {
                        _selected.removeAll(filtered.map((q) => q.id));
                      }
                    });
                  },
                ),
                const Text('全选'),
              ],
            ),
            Text('已选 ${_selected.length} 道'),
            // 未勾选时批量按钮禁用。
            OutlinedButton(
              onPressed: hasSelection ? _batchAddTag : null,
              child: const Text('加标签'),
            ),
            OutlinedButton(
              onPressed: hasSelection ? _batchAddFolder : null,
              child: const Text('加入文件夹'),
            ),
            OutlinedButton(
              onPressed: hasSelection ? _batchFavorite : null,
              child: const Text('收藏'),
            ),
            OutlinedButton(
              onPressed: hasSelection ? _batchArchive : null,
              child: const Text('归档'),
            ),
            OutlinedButton(
              onPressed: hasSelection ? _batchDelete : null,
              child: const Text('删除'),
            ),
            TextButton(
              onPressed: hasSelection
                  ? () => setState(_selected.clear)
                  : null,
              child: const Text('清除选择'),
            ),
            TextButton(
              onPressed: () => setState(_exitBatchMode),
              child: const Text('退出批量'),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 列表分页 ----------

  Widget _buildListPagination() {
    final totalPages = _totalPages;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('每页'),
        const SizedBox(width: 4),
        DropdownButton<int>(
          value: _pageSize,
          items: const [10, 20, 30, 40, 50]
              .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
              .toList(),
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              _pageSize = value;
              _page = 0;
            });
          },
        ),
        const Text('道'),
        const SizedBox(width: 16),
        TextButton(
          onPressed: _page > 0 ? () => _goPage(_page - 1) : null,
          child: const Text('上一页'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text('第 ${_page + 1}/$totalPages 页'),
        ),
        TextButton(
          onPressed:
              _page < totalPages - 1 ? () => _goPage(_page + 1) : null,
          child: const Text('下一页'),
        ),
      ],
    );
  }
}

/// 封面缝线：白色虚线圆角框（预览 .nb-book::before）。
class _DashedBorderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.55)
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width, size.height),
          const Radius.circular(6)));
    const dash = 5.0;
    const gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 批量加标签 / 加入文件夹用的单选弹窗。
class _PickDialog extends StatelessWidget {
  const _PickDialog({required this.title, required this.options});
  final String title;
  final List<String> options;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 280,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: options
              .map((o) => ActionChip(
                    label: Text(o),
                    onPressed: () => Navigator.of(context).pop(o),
                  ))
              .toList(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
