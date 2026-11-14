import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/repository.dart';
import '../../models/models.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/uikit.dart';
import '../../widgets/widgets.dart';

/// 整理工作台 H 布局：左图右表，整页滚动，无固定高度容器。
/// 队列藏在左上角「队列」按钮后，点开弹出 D 极简式队列层（Overlay 定位
/// 在按钮正下方，见 [_openQueue]）。
/// 表单里不显示学科（导入时已定，不可改）；只有文件夹是必填。
/// 区域高亮 / 修框切片按题型与题干文字推导（见 widgets.dart 的
/// [regionsOfQuestion]；演示数据没有真实框坐标）。
class OrganizePage extends StatefulWidget {
  const OrganizePage({
    super.key,
    required this.repo,
    required this.onOpenDetail,
    required this.onGoReview,
    required this.onGoCollect,
    this.imageFailed = false,
  });

  final QuestionRepository repo;
  final Future<void> Function(Question q, List<String> orderIds) onOpenDetail;
  final VoidCallback onGoReview;
  final VoidCallback onGoCollect;

  /// 图加载失败展示开关（R3 首页 `showBackupError` 同款做法）：真实
  /// 切片目前是绘制占位图、没有真实图片加载通道，失败态平时不出现；
  /// 传 true 时按 HTML `imgFailHTML` 显示学科图标 + 题型文字占位。
  final bool imageFailed;

  @override
  State<OrganizePage> createState() => _OrganizePageState();
}

class _OrganizePageState extends State<OrganizePage> {
  List<Question> _queue = [];
  int _index = 0;
  String _sort = 'timeDesc';
  bool _loading = true;
  bool _hasAnyQuestion = false;

  List<Folder> _folders = [];
  List<Exam> _exams = [];
  List<KnowledgePoint> _kps = [];
  List<String> _allTags = [];
  List<String> _customTypesAll = [];
  // 学科表：读库 subjects（P0B1 扫尾；以前直接 Subject.byId，
  // 新学科显示成“数学”）。空库回退预设三科。
  List<Subject> _subjects = Subject.all;
  // 库里找学科：新学科用库里的名与色；找不到才回退 Subject.byId
  //（数学兜底，只发生在数据不一致时）。
  Subject _subjectOf(String id) => _subjects.firstWhere(
        (s) => s.id == id,
        orElse: () => Subject.byId(id),
      );

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
  final _newFolderCtrl = TextEditingController();
  final _newExamNameCtrl = TextEditingController();
  DateTime? _newExamDate;

  // 各段默认开合：文件夹、修框切片展开，其余折起。
  bool _folderOpen = true;
  bool _slicesOpen = true;
  bool _sourceOpen = false;
  bool _classifyOpen = false;
  bool _answerOpen = false;

  // 二层区域高亮开关（默认全开）。
  bool _showStem = true;
  bool _showOption = true;
  bool _showFigure = true;

  // 内联新建表单的展开态。
  bool _addingFolder = false;
  bool _addingTag = false;
  bool _addingExam = false;

  // 知识点树：章节展开态（key 为「学科|章节」）。
  final Map<String, bool> _kpOpen = {};

  final _folderSectionKey = GlobalKey();
  final _queueButtonKey = GlobalKey();
  OverlayEntry? _queueEntry;

  Question? get _current =>
      _queue.isEmpty ? null : _queue[_index.clamp(0, _queue.length - 1)];

  List<String> get _orderIds => _queue.map((q) => q.id).toList();

  /// 学科首字母：数学 S / 英语 Y / 政治 Z。
  static String _subjectInitial(String subjectId) => switch (subjectId) {
        'english' => 'Y',
        'politics' => 'Z',
        _ => 'S',
      };

  Set<String> get _visibleRegions {
    final regions = regionsOfQuestion(_current!);
    final visible = <String>{};
    if (_showStem && regions.contains('stem')) visible.add('stem');
    if (_showOption && regions.contains('option')) visible.add('option');
    if (_showFigure && regions.contains('figure')) visible.add('figure');
    return visible;
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _queueEntry?.remove();
    _queueEntry = null;
    _answerCtrl.dispose();
    _explanationCtrl.dispose();
    _notesCtrl.dispose();
    _customTypeCtrl.dispose();
    _newTagCtrl.dispose();
    _newFolderCtrl.dispose();
    _newExamNameCtrl.dispose();
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
    final subjects = await widget.repo.subjects();
    final customs = <String>{};
    for (final q in all) {
      customs.addAll(q.customErrorTypes);
    }
    if (!mounted) return;
    setState(() {
      _hasAnyQuestion = all.isNotEmpty;
      _queue = pending;
      _sortQueue();
      if (_index >= _queue.length) _index = _queue.isEmpty ? 0 : _queue.length - 1;
      _exams = exams;
      _kps = kps;
      _allTags = tags;
      _subjects = subjects.isEmpty ? Subject.all : subjects;
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
      _addingFolder = false;
      _addingTag = false;
      _addingExam = false;
      _newFolderCtrl.clear();
      _newTagCtrl.clear();
      _newExamNameCtrl.clear();
      _newExamDate = null;
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
      // 选了「未归属试卷」且原题有试卷时才真正清空（基线 copyWith
      // 里 examId 传 null 表示“保持原值”，不处理就清不掉）。
      clearExamId: _examId == null && q.examId != null,
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

  Future<void> _saveDraft() async {
    await _saveCurrent();
    if (mounted) _snack('草稿已保存');
  }

  Future<void> _goTo(int next) async {
    if (next < 0 || next >= _queue.length || next == _index) return;
    await _saveCurrent();
    if (!mounted) return;
    setState(() => _index = next);
    await _loadFolders();
    _loadForm();
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
      kind: '整理',
      subjectId: q.subjectId,
      title: q.title,
    );
    await _refresh();
  }

  Future<void> _openDetail() async {
    final q = _current;
    if (q == null) return;
    await _saveCurrent();
    await widget.onOpenDetail(q, _orderIds);
    await _refresh();
  }

  // ---------------------------------------------------------- 队列弹出层 --

  /// 打开 D 极简式队列层：Overlay 定位在「队列」按钮正下方（HTML
  /// `.org-queue-pop` 的 `top:54px; left:0`，相对工作区左上角）。
  /// 勾选状态只活在弹出层内，关闭即丢弃（见 [_closeQueue]）。
  void _openQueue() {
    if (_queue.isEmpty || _queueEntry != null) return;
    final box =
        _queueButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final offset = box.localToGlobal(Offset.zero);
    final size = MediaQuery.sizeOf(context);
    final scale = qmScaleOf(context);
    final left = offset.dx;
    final top = offset.dy + box.size.height + 8 * scale;
    final availableWidth = size.width - left - 16;
    final width = (DesignTokens.organizeQueuePopWidth * scale)
        .clamp(280.0, availableWidth > 280 ? availableWidth : 280.0);
    final maxHeight =
        (size.height - top - 16).clamp(200.0, 760.0 * scale);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (overlayContext) => _QueuePopup(
        repo: widget.repo,
        questions: List.of(_queue),
        currentId: () => _current?.id,
        sortKey: _sort,
        left: left,
        top: top,
        width: width,
        maxHeight: maxHeight,
        onClose: _closeQueue,
        onJump: _jumpToQuestion,
        onSortChanged: _applyQueueSort,
        onNotify: _snack,
      ),
    );
    _queueEntry = entry;
    Overlay.of(context).insert(entry);
  }

  /// 关闭队列层并刷新（批量 / 删除等改动经此刷新进主队列）。
  /// 勾选状态随弹出层 State 一起销毁，下次打开为已选 0 道。
  Future<void> _closeQueue() async {
    final entry = _queueEntry;
    if (entry == null) return;
    _queueEntry = null;
    entry.remove();
    await _refresh();
  }

  /// 队列里点中一道题：先保存当前题，再切过去（弹出层已关，不刷新）。
  Future<void> _jumpToQuestion(String id) async {
    final entry = _queueEntry;
    if (entry == null) return;
    _queueEntry = null;
    entry.remove();
    await _saveCurrent();
    if (!mounted) return;
    final idx = _queue.indexWhere((q) => q.id == id);
    if (idx < 0) {
      await _refresh();
      return;
    }
    setState(() => _index = idx);
    await _loadFolders();
    _loadForm();
  }

  /// 队列里改排序：先保存当前题，按新排序重排并回到第 1 道（与基线
  /// 顶栏排序下拉的行为一致），再让弹出层按新 currentId 重绘。
  Future<void> _applyQueueSort(String sort) async {
    await _saveCurrent();
    if (!mounted) return;
    setState(() {
      _sort = sort;
      _sortQueue();
      _index = 0;
    });
    _loadForm();
    _queueEntry?.markNeedsBuild();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------- 内联新建 --

  String _folderDisplayName(Folder folder) {
    if (folder.parentId == null) return folder.name;
    final parent = _folders.firstWhere(
      (f) => f.id == folder.parentId,
      orElse: () => folder,
    );
    return parent.id == folder.id ? folder.name : '${parent.name} / ${folder.name}';
  }

  Future<void> _submitNewFolder() async {
    final q = _current;
    if (q == null) return;
    final name = _newFolderCtrl.text.trim();
    if (name.isEmpty) return;
    if (_folders.any((f) => f.name == name && f.parentId == null)) {
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
    if (!mounted) return;
    setState(() {
      if (!_folderIds.contains(folder.id)) _folderIds.add(folder.id);
      _addingFolder = false;
      _newFolderCtrl.clear();
    });
  }

  Future<void> _submitNewExam() async {
    final name = _newExamNameCtrl.text.trim();
    if (name.isEmpty) return;
    final exam = Exam(
      id: 'exam-${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      date: _newExamDate,
    );
    await widget.repo.addExam(exam);
    if (!mounted) return;
    setState(() {
      _exams = [..._exams, exam];
      _examId = exam.id;
      _addingExam = false;
      _newExamNameCtrl.clear();
      _newExamDate = null;
    });
  }

  Future<void> _submitNewTag() async {
    final name = _newTagCtrl.text.trim();
    if (name.isEmpty) return;
    // §6 第 4 条：标签名禁逗号与竖线。
    if (hasBannedNameSeparator(name)) {
      _snack('不能含逗号或竖线');
      return;
    }
    await widget.repo.addTag(name);
    if (!mounted) return;
    setState(() {
      if (!_tags.contains(name)) _tags.add(name);
      if (!_allTags.contains(name)) _allTags.add(name);
      _addingTag = false;
      _newTagCtrl.clear();
    });
  }

  void _addCustomType() {
    final name = _customTypeCtrl.text.trim();
    if (name.isEmpty) return;
    // §6 第 4 条：自定义错因名禁逗号与竖线。
    if (hasBannedNameSeparator(name)) {
      _snack('不能含逗号或竖线');
      return;
    }
    setState(() {
      if (!_customTypes.contains(name)) _customTypes.add(name);
      if (!_customTypesAll.contains(name)) _customTypesAll.add(name);
      _customTypeCtrl.clear();
    });
  }

  String _dateText(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ---------------------------------------------------------- 页面结构 --

  @override
  Widget build(BuildContext context) {
    final q = _current;
    final scale = qmScaleOf(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : q == null
              ? _emptyPage()
              : SingleChildScrollView(
                  padding: EdgeInsets.zero,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _pageHeader(),
                      SizedBox(height: 20 * scale),
                      _topbar(q),
                      SizedBox(
                          height:
                              DesignTokens.organizeTopbarMarginBottom * scale),
                      _wideLayout(context)
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: _leftPane(q)),
                                SizedBox(
                                    width:
                                        DesignTokens.organizeGridGap * scale),
                                Expanded(child: _rightPane(q)),
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _leftPane(q),
                                SizedBox(height: 24 * scale),
                                _rightPane(q),
                              ],
                            ),
                    ],
                  ),
                ),
    );
  }

  /// H 布局断点：HTML `@media (max-width:1102px)` 按窗口宽判断，
  /// 窗口 ≥1102px 时左右两列，以下时上下堆叠。
  bool _wideLayout(BuildContext context) =>
      MediaQuery.sizeOf(context).width >=
      DesignTokens.organizeGridBreakpoint;

  Widget _pageHeader() {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '整理工作台',
          style: TextStyle(
            fontSize: DesignTokens.pageTitleFontSize,
            fontWeight: FontWeight.w800,
            color: palette.ink,
            height: 1.25,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          '一道题一道题补完整，再归档进错题本',
          style: TextStyle(
            fontSize: DesignTokens.bodySmallFontSize,
            color: palette.muted,
            height: 1.65,
          ),
        ),
      ],
    );
  }

  /// 空状态分两种：从未有题（库里一道题也没有）/ 队列已空（题都在，
  /// 但都已整理完）。
  Widget _emptyPage() {
    if (_hasAnyQuestion) {
      return SingleChildScrollView(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _pageHeader(),
            const SizedBox(height: 20),
            QmEmptyState(
              title: '都整理完了，去复习吧',
              description: '这一批题都确认整理并归档到错题本了。收集中心有新题进来时，这里会重新出现队列。',
              actionLabel: '去复习',
              onAction: widget.onGoReview,
            ),
          ],
        ),
      );
    }
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _pageHeader(),
          const SizedBox(height: 20),
          QmEmptyState(
            title: '没有待整理的题目',
            description: '收集中心框好的题会出现在这里。整理就是给每道题补上答案、解析和错因，选好文件夹、打上标签，再确认归档。',
            actionLabel: '先去收集题目',
            onAction: widget.onGoCollect,
          ),
        ],
      ),
    );
  }

  /// 顶栏：左上角「队列」按钮（带“还剩 N 道”计数 pill）+
  /// “当前整理：学科 · 题名”。
  Widget _topbar(Question q) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final subject = _subjectOf(q.subjectId);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // QmButton 表达不了按钮里的计数 pill，这里按 HTML
        // `.org-queue-btn` / `.org-queue-count` 用 token 手工拼
        // （surface 底 + line-strong 边 + accent pill）。
        InkWell(
          key: _queueButtonKey,
          onTap: _openQueue,
          borderRadius:
              BorderRadius.circular(DesignTokens.buttonRadius * scale),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: 18 * scale,
              vertical: 9 * scale,
            ),
            decoration: BoxDecoration(
              color: palette.surface,
              border: Border.all(color: palette.lineStrong),
              borderRadius:
                  BorderRadius.circular(DesignTokens.buttonRadius * scale),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '队列',
                  style: TextStyle(
                    fontSize: DesignTokens.organizeQueueButtonFontSize,
                    fontWeight: FontWeight.w700,
                    color: palette.ink,
                    height: DesignTokens.controlLineHeight,
                  ),
                ),
                SizedBox(width: 9 * scale),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 10 * scale),
                  constraints: BoxConstraints(minHeight: 22 * scale),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: palette.accent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '还剩 ${_queue.length} 道',
                    style: TextStyle(
                      fontSize: DesignTokens.organizeQueueCountFontSize,
                      fontWeight: FontWeight.w800,
                      color: palette.accentInk,
                      height: DesignTokens.controlLineHeight,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(width: 12 * scale),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '当前整理：',
                  style: TextStyle(
                    fontSize: 14,
                    color: palette.muted,
                    height: 1.65,
                  ),
                ),
                TextSpan(
                  text: '${subject.name} · ${q.title}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: palette.ink,
                    height: 1.65,
                  ),
                ),
                TextSpan(
                  text: '  平时只看左边的题图和右边的表单，要换题点「队列」',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: palette.muted,
                    height: 1.65,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------- 左：图 --

  Widget _leftPane(Question q) {
    final scale = qmScaleOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _paperImage(q),
        if (!widget.imageFailed) ...[
          SizedBox(height: 10 * scale),
          _regionToggles(q),
          SizedBox(height: DesignTokens.organizeSectionGap * scale),
          QmFoldSection(
            title: '修框切片',
            expanded: _slicesOpen,
            onToggle: () => setState(() => _slicesOpen = !_slicesOpen),
            variant: QmFoldVariant.form,
            child: _slicesSection(q),
          ),
        ],
      ],
    );
  }

  /// 整题纸面图（可点放大）+ 三色高亮开关叠加层。
  Widget _paperImage(Question q) {
    final scale = qmScaleOf(context);
    final slice = QuestionSlice(
      question: q,
      subject: _subjectOf(q.subjectId),
      maxHeight: DesignTokens.organizePaperMaxHeight * scale,
      failed: widget.imageFailed,
      onTap: widget.imageFailed
          ? null
          : () => showQuestionZoomDialog(
                context,
                q,
                visibleRegions: _visibleRegions,
              ),
    );
    if (widget.imageFailed) return slice;
    return Stack(
      children: [
        slice,
        Positioned.fill(
          child: IgnorePointer(
            child: QuestionRegionOverlays(
              question: q,
              visible: _visibleRegions,
            ),
          ),
        ),
      ],
    );
  }

  /// stem / option / figure 三色高亮开关（默认全开；只显示本题有的区）。
  Widget _regionToggles(Question q) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    const labels = {
      'stem': 'stem 题干',
      'option': 'option 选项',
      'figure': 'figure 插图',
    };
    final regions = regionsOfQuestion(q);
    return Wrap(
      spacing: 16,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final region in regions)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                value: switch (region) {
                  'stem' => _showStem,
                  'option' => _showOption,
                  _ => _showFigure,
                },
                activeColor: switch (region) {
                  'stem' => palette.stem,
                  'option' => palette.option,
                  _ => palette.figure,
                },
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                onChanged: (on) => setState(() {
                  switch (region) {
                    case 'stem':
                      _showStem = on ?? true;
                    case 'option':
                      _showOption = on ?? true;
                    default:
                      _showFigure = on ?? true;
                  }
                }),
              ),
              Text(
                labels[region]!,
                style: const TextStyle(fontSize: 13.5, height: 1.2),
              ),
            ],
          ),
        Text(
          '区域仅作辅助定位，整题图始终是主体',
          style: TextStyle(fontSize: 12.5, color: palette.muted),
        ),
      ],
    );
  }

  /// 修框切片：每框一张切片卡（整题框 + 各二层框），只存图不做 OCR。
  /// 整题框有真实切片时显示真图（QuestionSlice 已接 slice_path）；
  /// 题干/选项/配图卡只在 sliceText 非空时显示——真实题没有
  /// sliceText，不显示空白卡。
  Widget _slicesSection(Question q) {
    final regions = regionsOfQuestion(q);
    final hasText = q.sliceText.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sliceCard(
          '整题框切片',
          q.slicePath != null
              ? QuestionSlice(question: q, maxHeight: 220)
              : _sliceTextBody(q, withFigureNote: true),
        ),
        if (hasText) ...[
          const SizedBox(height: 10),
          _sliceCard('题干框切片', _sliceTextBody(q)),
          if (regions.contains('option')) ...[
            const SizedBox(height: 10),
            _sliceCard('选项框切片', _optionBody()),
          ],
          if (regions.contains('figure')) ...[
            const SizedBox(height: 10),
            _sliceCard('配图框切片', _figureBody(q)),
          ],
        ],
      ],
    );
  }

  Widget _sliceTextBody(Question q, {bool withFigureNote = false}) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final text = withFigureNote &&
            regionsOfQuestion(q).contains('figure')
        ? '${q.sliceText}\n（含配图）'
        : q.sliceText;
    return Text(
      text,
      maxLines: 4,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: 'Georgia',
        fontFamilyFallback: const ['Songti SC', 'SimSun'],
        fontSize: 12.5,
        height: 1.55,
        color: palette.paperInk,
      ),
    );
  }

  /// 选项框切片体：A–D 四行迷你选项条（演示数据没有真实选项文本，
  /// 不编造选项内容）。
  Widget _optionBody() {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final letter in ['A', 'B', 'C', 'D'])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(
              children: [
                Text(
                  '$letter ',
                  style: TextStyle(
                    fontFamily: 'Georgia',
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: palette.paperInk,
                    height: 1.0,
                  ),
                ),
                Expanded(
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: palette.line,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _figureBody(Question q) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return SizedBox(
      height: 48,
      child: CustomPaint(
        painter: _FigureMiniPainter(q.sliceKind, palette.figure),
      ),
    );
  }

  /// 切片卡：纸面底 + 纸线边 + 卡头（标签 + 「切片图」）+ 卡体
  /// （衬线 12.5px，上限 66px，见 `.slice-card`）。
  Widget _sliceCard(String label, Widget body) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 10 * scale,
        vertical: 8 * scale,
      ),
      decoration: BoxDecoration(
        color: palette.paper,
        border: Border.all(color: palette.paperLine),
        borderRadius: BorderRadius.circular(10 * scale),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: palette.muted,
                  height: 1.2,
                ),
              ),
              const Spacer(),
              Text(
                '切片图',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: palette.accentText,
                  height: 1.2,
                ),
              ),
            ],
          ),
          SizedBox(height: 4 * scale),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: DesignTokens.organizeSliceBodyMaxHeight * scale,
            ),
            child: ClipRect(child: body),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------- 右：表单 --

  Widget _rightPane(Question q) {
    final scale = qmScaleOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _missingLine(),
        SizedBox(height: DesignTokens.organizeSectionGap * scale),
        QmFoldSection(
          key: _folderSectionKey,
          title: '文件夹（归类）',
          expanded: _folderOpen,
          onToggle: () => setState(() => _folderOpen = !_folderOpen),
          variant: QmFoldVariant.form,
          child: _folderSection(q),
        ),
        SizedBox(height: DesignTokens.organizeSectionGap * scale),
        QmFoldSection(
          title: '来源（可选）',
          subtitle: '试卷（来源）',
          expanded: _sourceOpen,
          onToggle: () => setState(() => _sourceOpen = !_sourceOpen),
          variant: QmFoldVariant.form,
          child: _sourceSection(),
        ),
        SizedBox(height: DesignTokens.organizeSectionGap * scale),
        QmFoldSection(
          title: '分类补充（可选）',
          subtitle: '知识点 · 错误类型 · 标签',
          expanded: _classifyOpen,
          onToggle: () => setState(() => _classifyOpen = !_classifyOpen),
          variant: QmFoldVariant.form,
          child: _classifySection(q),
        ),
        SizedBox(height: DesignTokens.organizeSectionGap * scale),
        QmFoldSection(
          title: '答案 · 解析 · 笔记（可选）',
          subtitle: '答案在上、解析在下，笔记单独一栏',
          expanded: _answerOpen,
          onToggle: () => setState(() => _answerOpen = !_answerOpen),
          variant: QmFoldVariant.form,
          child: _answerSection(),
        ),
        _workActs(),
        _confirmBar(),
      ],
    );
  }

  /// 待补充行：只数必填项（只有文件夹是必填，表单里无学科字段）。
  /// 点「文件夹（归类）」跳到文件夹那一栏。
  Widget _missingLine() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final missing = _folderIds.isEmpty;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 11 * scale,
        vertical: 7 * scale,
      ),
      decoration: BoxDecoration(
        color: palette.warnBg,
        border: Border.all(color: palette.warnLine),
        borderRadius: BorderRadius.circular(10 * scale),
      ),
      child: missing
          ? Text.rich(
              TextSpan(
                style: TextStyle(
                  fontSize: DesignTokens.organizeFieldFontSize,
                  color: palette.warnInk,
                  height: 1.55,
                ),
                children: [
                  const TextSpan(text: '本题待补充 1 项（只数必填）：'),
                  TextSpan(
                    text: '文件夹（归类）',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: palette.accentText,
                      decoration: TextDecoration.underline,
                    ),
                    recognizer: TapGestureRecognizer()
                      ..onTap = () {
                        setState(() => _folderOpen = true);
                        final ctx = _folderSectionKey.currentContext;
                        if (ctx != null) {
                          Scrollable.ensureVisible(
                            ctx,
                            duration: const Duration(milliseconds: 300),
                          );
                        }
                      },
                  ),
                  const TextSpan(
                    text:
                        '（点一下跳到那一栏）——只有必填没齐才提示；答案、解析、知识点、错误类型、试卷、标签、笔记都是可选，填不填都不算、不提示',
                  ),
                ],
              ),
            )
          : Text(
              '本题必填已齐：文件夹（归类）已选好，可以确认整理；可选内容填不填都不提示',
              style: TextStyle(
                fontSize: DesignTokens.organizeFieldFontSize,
                color: palette.warnInk,
                height: 1.55,
              ),
            ),
    );
  }

  Widget _fieldLabel(String label, {bool required = false, String? hint}) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: label,
              style: TextStyle(
                fontSize: DesignTokens.organizeFieldFontSize,
                fontWeight: FontWeight.w700,
                color: palette.ink2,
                height: 1.2,
              ),
            ),
            if (required)
              TextSpan(
                text: ' *必填',
                style: TextStyle(
                  fontSize: DesignTokens.organizeFieldFontSize,
                  fontWeight: FontWeight.w700,
                  color: palette.errInk,
                  height: 1.2,
                ),
              ),
            if (hint != null)
              TextSpan(
                text: ' $hint',
                style: TextStyle(
                  fontSize: DesignTokens.organizeFieldFontSize,
                  fontWeight: FontWeight.w600,
                  color: palette.muted,
                  height: 1.2,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _helperText(String text) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: DesignTokens.organizeFieldFontSize,
          color: palette.muted,
          height: 1.55,
        ),
      ),
    );
  }

  Widget _inlineAddBox({required Widget child}) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Container(
      margin: EdgeInsets.only(top: 8 * scale),
      padding: EdgeInsets.all(10 * scale),
      decoration: BoxDecoration(
        color: palette.surface2,
        border: Border.all(color: palette.line),
        borderRadius: BorderRadius.circular(12 * scale),
      ),
      child: child,
    );
  }

  Widget _folderSection(Question q) {
    final subject = _subjectOf(q.subjectId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel('文件夹（归类）',
            required: true, hint: '可多选 · 一道题可进多个文件夹，题只存一份'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final folder in _folders)
              QmChip(
                label: _folderDisplayName(folder),
                selected: _folderIds.contains(folder.id),
                onTap: () => setState(() {
                  if (_folderIds.contains(folder.id)) {
                    _folderIds.remove(folder.id);
                  } else {
                    _folderIds.add(folder.id);
                  }
                }),
              ),
            QmButton(
              label: '添加新文件夹…',
              leadingGlyph: QmGlyphs.plus,
              variant: QmButtonVariant.plain,
              size: QmButtonSize.small,
              onPressed: () => setState(() => _addingFolder = true),
            ),
          ],
        ),
        if (_addingFolder)
          _inlineAddBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '添加新文件夹',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _newFolderCtrl,
                        decoration: const InputDecoration(
                          hintText: '文件夹名，如：错题精选',
                        ),
                        onSubmitted: (_) => _submitNewFolder(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    QmButton(
                      label: '添加',
                      size: QmButtonSize.small,
                      onPressed: _submitNewFolder,
                    ),
                    const SizedBox(width: 8),
                    QmButton(
                      label: '取消',
                      variant: QmButtonVariant.plain,
                      size: QmButtonSize.small,
                      onPressed: () => setState(() {
                        _addingFolder = false;
                        _newFolderCtrl.clear();
                      }),
                    ),
                  ],
                ),
                _helperText('填文件夹名就能新建，建完直接选上这道题'),
              ],
            ),
          ),
        _helperText(
          '只列「${subject.name}」自己的文件夹（预置：试卷 / 平时作业 / 模拟卷），在这一科新建的文件夹只出现在这一科，不会出现在其他科目；改名 / 建子文件夹在错题本目录页里做。',
        ),
      ],
    );
  }

  Widget _sourceSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel('试卷（来源）', hint: '可选 · 独立试卷实体'),
        DropdownButton<String>(
          value: _examId,
          hint: const Text('选择试卷（可选）'),
          isExpanded: true,
          items: [
            const DropdownMenuItem(
              value: '__add__',
              child: Text('＋ 添加新试卷…'),
            ),
            const DropdownMenuItem(
              value: '__none__',
              child: Text('未归属试卷'),
            ),
            ..._exams.map((e) => DropdownMenuItem(
                  value: e.id,
                  child: Text(
                    e.date == null ? e.name : '${e.name}（${_dateText(e.date!)}）',
                  ),
                )),
          ],
          onChanged: (v) {
            if (v == null) return;
            if (v == '__add__') {
              setState(() => _addingExam = true);
              return;
            }
            setState(() => _examId = v == '__none__' ? null : v);
          },
        ),
        if (_addingExam)
          _inlineAddBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '添加新试卷',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _newExamNameCtrl,
                        decoration: const InputDecoration(
                          hintText: '试卷名，如：高等数学期末试卷',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _newExamDate == null
                          ? '未选日期'
                          : _dateText(_newExamDate!),
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(width: 8),
                    QmButton(
                      label: '选日期',
                      variant: QmButtonVariant.plain,
                      size: QmButtonSize.small,
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _newExamDate ?? DateTime.now(),
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) {
                          setState(() => _newExamDate = picked);
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    QmButton(
                      label: '添加',
                      size: QmButtonSize.small,
                      onPressed: _submitNewExam,
                    ),
                    const SizedBox(width: 8),
                    QmButton(
                      label: '取消',
                      variant: QmButtonVariant.plain,
                      size: QmButtonSize.small,
                      onPressed: () => setState(() {
                        _addingExam = false;
                        _newExamNameCtrl.clear();
                        _newExamDate = null;
                      }),
                    ),
                  ],
                ),
                _helperText('填试卷名 + 日期就行，添加后自动归属到这道题，之后也能在下拉里选到它'),
              ],
            ),
          ),
        if (!_addingExam)
          _helperText(
            '这是来源：这道题出自哪份卷子。点开选已有试卷，或在下拉最上面点「＋ 添加新试卷…」填试卷名 + 日期添加；来源也由你自定义，一份试卷可归属多道题。和上面的「文件夹（归类）」不是一回事',
          ),
      ],
    );
  }

  Widget _classifySection(Question q) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final subjectKps =
        _kps.where((k) => k.subjectId == q.subjectId).toList();
    final chapters = <String>[];
    for (final k in subjectKps) {
      if (!chapters.contains(k.chapter)) chapters.add(k.chapter);
    }
    final customOptions = {..._customTypesAll, ..._customTypes}.toList();
    final selectedKpNames = _kpIds
        .map((id) => _kps.firstWhere(
              (k) => k.id == id,
              orElse: () => KnowledgePoint(
                  id: id, subjectId: q.subjectId, chapter: '', name: '已删知识点'),
            ))
        .map((k) => k.name)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel('知识点', hint: '可选 · 多选不限个数'),
        _kpTree(q, subjectKps, chapters, selectedKpNames),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: QmRowLine(kind: QmRowLineKind.line),
        ),
        _fieldLabel('错误类型', hint: '可选 · 多选，想选几个选几个'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('已选（点一下取消）：',
                style: TextStyle(fontSize: 13, height: 1.6)),
            const SizedBox(width: 4),
            Expanded(
              child: _errorTypes.isEmpty && _customTypes.isEmpty
                  ? Text('还没选错误类型',
                      style: TextStyle(
                          fontSize: 13, color: palette.muted, height: 1.6))
                  : Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final t in _errorTypes)
                          QmChip(
                            label: t,
                            onDelete: () =>
                                setState(() => _errorTypes.remove(t)),
                          ),
                        for (final t in _customTypes)
                          QmChip(
                            label: '$t（自定义）',
                            onDelete: () =>
                                setState(() => _customTypes.remove(t)),
                          ),
                      ],
                    ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ...ErrorTypes.fixed.map((t) => QmChip(
                  label: t,
                  selected: _errorTypes.contains(t),
                  onTap: () => setState(() {
                    if (_errorTypes.contains(t)) {
                      _errorTypes.remove(t);
                    } else {
                      _errorTypes.add(t);
                    }
                  }),
                )),
            ...customOptions.map((t) => QmChip(
                  label: '$t（自定义）',
                  selected: _customTypes.contains(t),
                  onTap: () => setState(() {
                    if (_customTypes.contains(t)) {
                      _customTypes.remove(t);
                    } else {
                      _customTypes.add(t);
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
                decoration: const InputDecoration(
                  hintText: '自定义错误类型…（枚举之外的情况）',
                ),
                onSubmitted: (_) => _addCustomType(),
              ),
            ),
            const SizedBox(width: 8),
            QmButton(
              label: '添加并选上',
              variant: QmButtonVariant.plain,
              size: QmButtonSize.small,
              onPressed: _addCustomType,
            ),
          ],
        ),
        _helperText(
          '固定枚举：审题失误 / 概念不清 / 计算错误 / 方法不会 / 其他。自定义类型只跟这道题留着，下次整理还能再选到它，不进全局枚举；报告仍按固定枚举归因',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: QmRowLine(kind: QmRowLineKind.line),
        ),
        _fieldLabel('标签', hint: '可选 · 不限个数'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final t in QmChip.presetTags)
              QmChip(
                label: t,
                selected: _tags.contains(t),
                onTap: () => setState(() {
                  if (_tags.contains(t)) {
                    _tags.remove(t);
                  } else {
                    _tags.add(t);
                  }
                }),
              ),
            for (final t in _allTags.where(
                (t) => !QmChip.presetTags.contains(t)))
              QmChip(
                label: t,
                selected: _tags.contains(t),
                onTap: () => setState(() {
                  if (_tags.contains(t)) {
                    _tags.remove(t);
                  } else {
                    _tags.add(t);
                  }
                }),
              ),
            QmButton(
              label: '新建标签',
              leadingGlyph: QmGlyphs.plus,
              variant: QmButtonVariant.plain,
              size: QmButtonSize.small,
              onPressed: () => setState(() => _addingTag = true),
            ),
          ],
        ),
        if (_addingTag)
          _inlineAddBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '新建标签',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _newTagCtrl,
                        decoration: const InputDecoration(
                          hintText: '标签名，如：期末重点',
                        ),
                        onSubmitted: (_) => _submitNewTag(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    QmButton(
                      label: '新建并选上',
                      size: QmButtonSize.small,
                      onPressed: _submitNewTag,
                    ),
                    const SizedBox(width: 8),
                    QmButton(
                      label: '取消',
                      variant: QmButtonVariant.plain,
                      size: QmButtonSize.small,
                      onPressed: () => setState(() {
                        _addingTag = false;
                        _newTagCtrl.clear();
                      }),
                    ),
                  ],
                ),
                _helperText('填个名就能建，建完直接选上这道题'),
              ],
            ),
          ),
        if (!_addingTag)
          _helperText(
            '预置标签易错 / 常考 / 需重做直接点就能打，想打几个打几个；点标签栏最后的「＋ 新建标签」填个名就能新建，建完直接选上',
          ),
      ],
    );
  }

  /// 知识点树：学科 → 章节 → 知识点（HTML `.kptree`）；树里没有的点
  /// 不能在这里新建，去学科管理里加。
  Widget _kpTree(
    Question q,
    List<KnowledgePoint> subjectKps,
    List<String> chapters,
    List<String> selectedKpNames,
  ) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final subject = _subjectOf(q.subjectId);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 14 * scale,
        vertical: 12 * scale,
      ),
      decoration: BoxDecoration(
        color: palette.surface2,
        border: Border.all(color: palette.line),
        borderRadius: BorderRadius.circular(12 * scale),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            selectedKpNames.isEmpty
                ? '已选 0 个'
                : '已选 ${selectedKpNames.length} 个：${selectedKpNames.map((n) => '✓ $n').join('、')}',
            style: const TextStyle(fontSize: 13.5, height: 1.55),
          ),
          if (subjectKps.isEmpty)
            Padding(
              padding: EdgeInsets.only(top: 8 * scale),
              child: const Text(
                '这科还没知识点，去学科管理添加。',
                style: TextStyle(fontSize: 13),
              ),
            ),
          for (var ci = 0; ci < chapters.length; ci++) ...[
            Padding(
              padding: EdgeInsets.only(top: 6 * scale),
              child: QmRowLine(kind: QmRowLineKind.line),
            ),
            _kpChapterRow(q, subject, chapters[ci], subjectKps),
          ],
          Padding(
            padding: EdgeInsets.only(top: 8 * scale),
            child: Text(
              '三级树：学科 → 章节 → 知识点。点章节名展开，再点知识点选上（选中的打 ✓），多选、不限个数。树里没有的知识点不能在这里新建——去学科管理里加进树，回来再选。',
              style: TextStyle(
                fontSize: 12.5,
                color: palette.muted,
                height: 1.55,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kpChapterRow(
    Question q,
    Subject subject,
    String chapter,
    List<KnowledgePoint> subjectKps,
  ) {
    final key = '${q.subjectId}|$chapter';
    final open = _kpOpen[key] ?? false;
    final points =
        subjectKps.where((k) => k.chapter == chapter).toList();
    final inChapter =
        points.where((k) => _kpIds.contains(k.id)).length;
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _kpOpen[key] = !open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Text(
                  open ? QmGlyphs.chevronDown : QmGlyphs.chevronRightSmall,
                  style: TextStyle(color: palette.muted, height: 1.2),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${subject.name} › $chapter',
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                    ),
                  ),
                ),
                if (inChapter > 0)
                  Text(
                    '已选 $inChapter 个',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: palette.accentText,
                      height: 1.2,
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final kp in points)
                  QmChip(
                    label: kp.name,
                    selected: _kpIds.contains(kp.id),
                    onTap: () => setState(() {
                      if (_kpIds.contains(kp.id)) {
                        _kpIds.remove(kp.id);
                      } else {
                        _kpIds.add(kp.id);
                      }
                    }),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _answerSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel('答案', hint: '可选 · 与解析分开 · 固定在上'),
        TextField(
          controller: _answerCtrl,
          maxLines: 1,
          decoration: const InputDecoration(hintText: '还没想好可留空'),
        ),
        _optionalEmptyNote(_answerCtrl),
        const SizedBox(height: 12),
        _fieldLabel('解析', hint: '可选 · 可以空，与答案分开 · 固定在答案下方'),
        TextField(
          controller: _explanationCtrl,
          maxLines: 3,
          decoration: const InputDecoration(hintText: '还没补可留空'),
        ),
        _optionalEmptyNote(_explanationCtrl),
        const SizedBox(height: 12),
        _fieldLabel('笔记', hint: '可选 · 单独一栏，与答案、解析分开'),
        TextField(
          controller: _notesCtrl,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: '自己的错因、心得、提醒都写这里，写多少都行，不必填',
          ),
        ),
        _helperText(
          '笔记只记你自己的话，和上面的答案、解析是三回事：答案是标准答案，解析是解题过程，笔记是你写给自己的',
        ),
      ],
    );
  }

  /// 空字段下的「（可选，还没填）」提示（跟随输入实时变）。
  Widget _optionalEmptyNote(TextEditingController controller) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.text.trim().isNotEmpty) {
          return const SizedBox.shrink();
        }
        return _helperText('（可选，还没填）');
      },
    );
  }

  Widget _workActs() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Container(
      margin: EdgeInsets.only(
          top: DesignTokens.organizeWorkActsMarginTop * scale),
      padding: EdgeInsets.only(top: 18 * scale),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              QmButton(
                label: '保存草稿',
                variant: QmButtonVariant.plain,
                onPressed: _saveDraft,
              ),
              SizedBox(width: 10 * scale),
              Expanded(
                child: Text(
                  '整理到一半切到别的题，这里填的全都自动保存、不会丢，切回来接着填 · 确认整理后这道题进错题本，在题目详情里点「加入复习」才会进复习列表，按错因四步',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: palette.muted,
                    height: 1.55,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 10 * scale),
          Row(
            children: [
              const Spacer(),
              QmButton(
                label: '上一道',
                variant: QmButtonVariant.plain,
                onPressed:
                    _index > 0 ? () => _goTo(_index - 1) : null,
              ),
              SizedBox(width: 8 * scale),
              QmButton(
                label: '下一道',
                variant: QmButtonVariant.plain,
                onPressed: _index < _queue.length - 1
                    ? () => _goTo(_index + 1)
                    : null,
              ),
              SizedBox(width: 8 * scale),
              QmButton(
                label: '查看题目详情',
                variant: QmButtonVariant.plain,
                onPressed: _openDetail,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _confirmBar() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Container(
      margin: EdgeInsets.only(
          top: DesignTokens.organizeConfirmBarMarginTop * scale),
      padding: EdgeInsets.only(top: 18 * scale),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: palette.line, width: 2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          QmButton(
            label: '确认整理，去下一道',
            size: QmButtonSize.large,
            block: true,
            onPressed: _confirmCurrent,
          ),
          SizedBox(height: 8 * scale),
          Text(
            '点完自动跳下一道待整理题，这道题归档到错题本；在题目详情里点「加入复习」后，按错因四步这道题',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              color: palette.muted,
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }
}

/// 配图框切片迷你图（演示用；真实切片是图片）：坐标轴 + 趋近曲线，
/// 按题型微调（时间轴画横线 + 4 个点）。
class _FigureMiniPainter extends CustomPainter {
  _FigureMiniPainter(this.kind, this.color);
  final String kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final axis = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..strokeWidth = 1.2;
    final line = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    if (kind == 'timeline') {
      canvas.drawLine(Offset(8, h / 2), Offset(w - 8, h / 2), axis);
      for (var i = 0; i < 4; i++) {
        final x = 24 + i * (w - 48) / 3;
        canvas.drawCircle(Offset(x, h / 2), 4, line);
      }
      return;
    }
    canvas.drawLine(Offset(8, h - 8), Offset(w - 8, h - 8), axis);
    canvas.drawLine(Offset(16, 4), Offset(16, h - 4), axis);
    final curve = Path()
      ..moveTo(16, h - 10)
      ..quadraticBezierTo(w * 0.5, h * 0.1, w - 16, h - 20);
    canvas.drawPath(curve, line);
  }

  @override
  bool shouldRepaint(covariant _FigureMiniPainter oldDelegate) =>
      oldDelegate.kind != kind || oldDelegate.color != color;
}


/// D 极简式队列弹出层：每题一行（复选框 + 标题 + 删除按钮），详情行只在
/// 当前题下方展开一行，当前题蓝框（2px accent 边框 + 左侧 4px 蓝条 +
/// accent-soft 底）；搜索只匹配题名 / 学科 / 试卷，不搜题干；排序默认
/// 时间降序；底部浮动批量条只在有勾选时出现。
/// 勾选状态只活在本层内：关闭（关闭按钮 / 遮罩 / Esc）即销毁，下次
/// 打开为已选 0 道。本层不直接改主队列的排序与下标，改动经回调交父页。
class _QueuePopup extends StatefulWidget {
  const _QueuePopup({
    required this.repo,
    required this.questions,
    required this.currentId,
    required this.sortKey,
    required this.left,
    required this.top,
    required this.width,
    required this.maxHeight,
    required this.onClose,
    required this.onJump,
    required this.onSortChanged,
    required this.onNotify,
  });

  final QuestionRepository repo;
  final List<Question> questions;

  /// 当前题 id（函数形式：父页切题后弹出层重绘时读最新值）。
  final String? Function() currentId;
  final String sortKey;
  final double left;
  final double top;
  final double width;
  final double maxHeight;
  final VoidCallback onClose;
  final Future<void> Function(String questionId) onJump;
  final Future<void> Function(String sortKey) onSortChanged;
  final void Function(String message) onNotify;

  @override
  State<_QueuePopup> createState() => _QueuePopupState();
}

class _QueuePopupState extends State<_QueuePopup> {
  final _selected = <String>{};
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _newBatchFolderCtrl = TextEditingController();
  final _focusNode = FocusNode(debugLabel: 'organize-queue-popup');
  String _search = '';
  late String _sort;
  List<Question> _questions = [];
  Map<String, String> _examNames = {};
  List<Folder> _folders = [];
  // 学科表：读库 subjects（P0B1 扫尾；队列搜索 / 详情行 / 删除确认
  // 以前直接 Subject.byId，新学科显示成“数学”）。空库回退预设三科。
  List<Subject> _subjects = Subject.all;
  // 库里找学科：新学科用库里的名与色；找不到才回退 Subject.byId
  //（数学兜底，只发生在数据不一致时）。
  Subject _subjectOf(String id) => _subjects.firstWhere(
        (s) => s.id == id,
        orElse: () => Subject.byId(id),
      );
  String? _pendingDeleteId;
  bool _batchDel = false;
  bool _addingBatchFolder = false;
  String? _batchFolderId;
  final _currentRowKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _questions = List.of(widget.questions);
    _sort = widget.sortKey;
    _loadMeta();
    // autofocus 在 OverlayEntry 里不可靠（首帧后焦点仍在路由级
    // FocusScope），显式要一次焦点，保证 Esc 能关弹窗。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
      _scrollToCurrent();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    _newBatchFolderCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  String get _currentSubjectId {
    final currentId = widget.currentId();
    final current = _questions.firstWhere(
      (q) => q.id == currentId,
      orElse: () => _questions.first,
    );
    return current.subjectId;
  }

  Future<void> _loadMeta() async {
    final exams = await widget.repo.exams();
    final folders =
        await widget.repo.folders(subjectId: _currentSubjectId);
    final subjects = await widget.repo.subjects();
    if (!mounted) return;
    setState(() {
      _examNames = {for (final e in exams) e.id: e.name};
      _folders = folders;
      _subjects = subjects.isEmpty ? Subject.all : subjects;
      _batchFolderId ??=
          folders.isEmpty ? null : folders.first.id;
    });
  }

  void _scrollToCurrent() {
    final filtered = _filtered;
    final idx =
        filtered.indexWhere((q) => q.id == widget.currentId());
    if (idx < 0 || !_scrollCtrl.hasClients) return;
    _scrollCtrl.jumpTo(
      (idx * 44).toDouble().clamp(
            0.0,
            _scrollCtrl.position.maxScrollExtent,
          ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _currentRowKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx, alignment: 0.1);
      }
    });
  }

  List<Question> get _filtered {
    final query = _search.trim().toLowerCase();
    var list = _questions.where((q) {
      if (query.isEmpty) return true;
      final haystack =
          '${q.title} ${_subjectOf(q.subjectId).name} ${_examNames[q.examId] ?? ''}'
              .toLowerCase();
      return haystack.contains(query);
    }).toList();
    switch (_sort) {
      case 'timeAsc':
        list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      case 'subjectAsc':
        list.sort((a, b) {
          final c = _QueuePopupState._subjectInitial(a.subjectId)
              .compareTo(_QueuePopupState._subjectInitial(b.subjectId));
          return c != 0 ? c : b.createdAt.compareTo(a.createdAt);
        });
      case 'subjectDesc':
        list.sort((a, b) {
          final c = _QueuePopupState._subjectInitial(b.subjectId)
              .compareTo(_QueuePopupState._subjectInitial(a.subjectId));
          return c != 0 ? c : b.createdAt.compareTo(a.createdAt);
        });
      case 'timeDesc':
      default:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return list;
  }

  static String _subjectInitial(String subjectId) => switch (subjectId) {
        'english' => 'Y',
        'politics' => 'Z',
        _ => 'S',
      };

  List<Question> get _selectedQuestions =>
      _questions.where((q) => _selected.contains(q.id)).toList();

  String _dateText(DateTime d) => '${d.year}-${d.month}-${d.day}';

  String _detailLine(Question q) {
    final exam = q.examId == null
        ? '未归属'
        : (_examNames[q.examId] ?? '未知试卷');
    final missing = q.folderIds.isEmpty
        ? '待补充 1 项：文件夹（归类）'
        : '必填已齐';
    return '${_subjectOf(q.subjectId).name} · ${sliceKindLabel(q.sliceKind)} · ${_dateText(q.createdAt)} · 试卷（来源）：$exam · $missing';
  }

  Future<void> _confirmDeleteOne(Question q) async {
    await widget.repo.delete(q);
    if (!mounted) return;
    setState(() {
      _questions.removeWhere((x) => x.id == q.id);
      _selected.remove(q.id);
      _pendingDeleteId = null;
    });
  }

  Future<void> _batchTagRedo() async {
    final selected = _selectedQuestions;
    for (final q in selected) {
      final tags = {...q.tags, '需重做'}.toList();
      await widget.repo.save(q.copyWith(tags: tags));
    }
    widget.onNotify('已给 ${selected.length} 道题打上 #需重做');
  }

  Future<void> _batchAddFolder() async {
    final folderId = _batchFolderId;
    if (folderId == null) {
      widget.onNotify('先选文件夹');
      return;
    }
    final folder = _folders.firstWhere((f) => f.id == folderId);
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
    if (!mounted) return;
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
    widget.onNotify(skipped > 0
        ? '已加入 $applied 道，$skipped 道不是本科，跳过'
        : '已加入文件夹');
  }

  Future<void> _submitBatchFolder() async {
    final name = _newBatchFolderCtrl.text.trim();
    if (name.isEmpty) return;
    if (_folders.any((f) => f.name == name && f.parentId == null)) {
      widget.onNotify('已经有了');
      return;
    }
    final folder = Folder(
      id: 'folder-${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      subjectId: _currentSubjectId,
      sortOrder: _folders.length,
    );
    await widget.repo.saveFolder(folder);
    if (!mounted) return;
    setState(() {
      _folders = [..._folders, folder];
      _batchFolderId = folder.id;
      _addingBatchFolder = false;
      _newBatchFolderCtrl.clear();
    });
  }

  /// 批量确认：只确认已选文件夹的题，缺文件夹的题拦下提示；
  /// 确认后关闭弹出层，父页刷新并按当前排序进下一道。
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
      widget.onNotify('有 ${blocked.length} 道题没选文件夹，先补上');
    }
    widget.onClose();
  }

  Future<void> _batchDelete() async {
    final selected = _selectedQuestions;
    for (final q in selected) {
      await widget.repo.delete(q);
    }
    if (!mounted) return;
    setState(() {
      _questions.removeWhere((q) => _selected.contains(q.id));
      _selected.clear();
      _batchDel = false;
    });
  }

  void _clearSelection() {
    setState(() {
      _selected.clear();
      _batchDel = false;
      _addingBatchFolder = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final filtered = _filtered;
    final currentId = widget.currentId();
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          widget.onClose();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      // Overlay 内容在 Scaffold / Material 之外，TextField /
      // DropdownButton / InkWell 需要一个 Material 祖先。
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: widget.onClose,
                child: Container(color: const Color(0x470D1118)),
              ),
            ),
          Positioned(
            left: widget.left,
            top: widget.top,
            width: widget.width,
            // 定高（Overlay 内容在 Material/Scaffold 之外，Column 用
            // min 高 + Flexible 时 ListView 会拿到无限高而溢出）。
            child: SizedBox(
              height: widget.maxHeight,
              child: Container(
                key: const Key('organize-queue-popup'),
                padding: EdgeInsets.all(14 * scale),
                decoration: BoxDecoration(
                  color: palette.surface,
                  border: Border.all(color: palette.lineStrong),
                  borderRadius: BorderRadius.circular(16 * scale),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x470A0E16),
                      blurRadius: 50,
                      offset: Offset(0, 18),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '待整理队列 · ${_questions.length} 道',
                            style: const TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w800,
                              height: 1.2,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        QmButton(
                          label: '关闭 ×',
                          variant: QmButtonVariant.plain,
                          size: QmButtonSize.small,
                          onPressed: widget.onClose,
                        ),
                      ],
                    ),
                    Padding(
                      padding: EdgeInsets.only(top: 2 * scale, bottom: 10 * scale),
                      child: Text(
                        '点中一道题，下面展开它的一行详情 · 勾了题底部才出现批量条',
                        style: TextStyle(
                          fontSize: 12,
                          color: palette.muted,
                          height: 1.5,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              TextField(
                                controller: _searchCtrl,
                                decoration: const InputDecoration(
                                  hintText: '搜题名、学科、试卷',
                                ),
                                onChanged: (v) =>
                                    setState(() => _search = v),
                              ),
                              Padding(
                                padding: EdgeInsets.only(top: 3 * scale),
                                child: Text(
                                  _search.isEmpty
                                      ? '搜题名、学科、试卷（来源），不搜题干'
                                      : '搜题名、学科、试卷（来源），不搜题干 · 搜到 ${filtered.length} 道',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: palette.muted,
                                    height: 1.4,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: 10 * scale),
                        SizedBox(
                          width: 168 * scale,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '排序',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: palette.muted,
                                  height: 1.2,
                                ),
                              ),
                              const SizedBox(height: 4),
                              DropdownButton<String>(
                                value: _sort,
                                isExpanded: true,
                                items: const [
                                  DropdownMenuItem(
                                    value: 'timeDesc',
                                    child: Text('时间降序'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'timeAsc',
                                    child: Text('时间升序'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'subjectAsc',
                                    child: Text('学科首字母升序'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'subjectDesc',
                                    child: Text('学科首字母降序'),
                                  ),
                                ],
                                onChanged: (v) async {
                                  if (v == null) return;
                                  setState(() => _sort = v);
                                  await widget.onSortChanged(v);
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 10 * scale),
                    if (_pendingDeleteId != null)
                      _singleDeleteConfirm(),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: palette.surface,
                          border: Border.all(color: palette.line),
                          borderRadius: BorderRadius.circular(12 * scale),
                        ),
                        padding: EdgeInsets.all(6 * scale),
                        child: filtered.isEmpty
                            ? const Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 12,
                                ),
                                child: Text(
                                  '没找到这道题，换个词试试',
                                  style: TextStyle(fontSize: 13.5),
                                ),
                              )
                            : ListView.builder(
                                controller: _scrollCtrl,
                                itemCount: filtered.length,
                                itemBuilder: (ctx, i) =>
                                    _queueRow(filtered[i], currentId),
                              ),
                      ),
                    ),
                    if (_selected.isNotEmpty) _batchBar(),
                  ],
                ),
              ),
            ),
          ),
          ],
        ),
      ),
    );
  }

  Widget _singleDeleteConfirm() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final matches =
        _questions.where((q) => q.id == _pendingDeleteId).toList();
    if (matches.isEmpty) return const SizedBox.shrink();
    final target = matches.first;
    return Container(
      margin: EdgeInsets.only(left: 8 * scale, right: 8 * scale, bottom: 10 * scale),
      padding: EdgeInsets.all(12 * scale),
      decoration: BoxDecoration(
        color: palette.errBg,
        border: Border.all(color: palette.errLine),
        borderRadius: BorderRadius.circular(12 * scale),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('确认删除这道题？',
              style: TextStyle(fontWeight: FontWeight.w700)),
          SizedBox(height: 4 * scale),
          Text(
            '「${_subjectOf(target.subjectId).name} · ${sliceKindLabel(target.sliceKind)}｜${target.title}」删了就没了，不可恢复。',
            style: const TextStyle(fontSize: 13, height: 1.55),
          ),
          SizedBox(height: 8 * scale),
          Row(
            children: [
              QmButton(
                label: '确认删除',
                size: QmButtonSize.small,
                onPressed: () => _confirmDeleteOne(target),
              ),
              SizedBox(width: 8 * scale),
              QmButton(
                label: '取消',
                variant: QmButtonVariant.plain,
                size: QmButtonSize.small,
                onPressed: () => setState(() => _pendingDeleteId = null),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _queueRow(Question q, String? currentId) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final isCurrent = q.id == currentId;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Checkbox(
              value: _selected.contains(q.id),
              activeColor: palette.accent,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              onChanged: (on) => setState(() {
                if (on == true) {
                  _selected.add(q.id);
                } else {
                  _selected.remove(q.id);
                }
              }),
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8 * scale),
                child: Text(
                  q.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight:
                        isCurrent ? FontWeight.w800 : FontWeight.normal,
                    color: isCurrent ? palette.accent : null,
                    height: 1.2,
                  ),
                ),
              ),
            ),
            QmButton(
              label: '删除',
              variant: QmButtonVariant.danger,
              size: QmButtonSize.small,
              onPressed: () => setState(() => _pendingDeleteId = q.id),
            ),
          ],
        ),
        if (isCurrent)
          Padding(
            padding: EdgeInsets.only(
              left: 24 * scale,
              right: 8 * scale,
              bottom: 6 * scale,
            ),
            child: Text(
              _detailLine(q),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: palette.muted,
                height: 1.5,
              ),
            ),
          ),
      ],
    );
    final row = Padding(
      key: isCurrent ? _currentRowKey : null,
      padding: EdgeInsets.symmetric(
        horizontal: 10 * scale,
        vertical: 3 * scale,
      ),
      child: isCurrent
          ? Container(
              decoration: BoxDecoration(
                color: palette.accentSoft,
                border: Border.all(color: palette.accent, width: 2),
                borderRadius: BorderRadius.circular(12 * scale),
              ),
              clipBehavior: Clip.antiAlias,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(width: 4, color: palette.accent),
                    Expanded(child: content),
                  ],
                ),
              ),
            )
          : content,
    );
    return InkWell(
      onTap: () => widget.onJump(q.id),
      child: row,
    );
  }

  /// 底部浮动批量条：只在有勾选时出现。
  Widget _batchBar() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Container(
      margin: EdgeInsets.only(top: 10 * scale),
      padding: EdgeInsets.symmetric(
        horizontal: 12 * scale,
        vertical: 10 * scale,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(color: palette.lineStrong),
        borderRadius: BorderRadius.circular(14 * scale),
        boxShadow: const [
          BoxShadow(
            color: Color(0x2E0A0E16),
            blurRadius: 28,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '批量操作 · 已选 ${_selected.length} 道',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: palette.ink2,
              height: 1.2,
            ),
          ),
          SizedBox(height: 8 * scale),
          Row(
            children: [
              QmButton(
                label: '批量打标签 #需重做',
                size: QmButtonSize.small,
                onPressed: _batchTagRedo,
              ),
              SizedBox(width: 8 * scale),
              Expanded(
                child: DropdownButton<String>(
                  value: _batchFolderId,
                  hint: const Text('选文件夹'),
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(
                      value: '__add__',
                      child: Text('＋ 添加新文件夹…'),
                    ),
                    ..._folders.map((f) => DropdownMenuItem(
                          value: f.id,
                          child: Text(f.name),
                        )),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    if (v == '__add__') {
                      setState(() => _addingBatchFolder = true);
                      return;
                    }
                    setState(() => _batchFolderId = v);
                  },
                ),
              ),
              SizedBox(width: 8 * scale),
              QmButton(
                label: '批量加入该文件夹',
                size: QmButtonSize.small,
                onPressed: _batchAddFolder,
              ),
            ],
          ),
          SizedBox(height: 8 * scale),
          Row(
            children: [
              QmButton(
                label: '批量确认整理',
                size: QmButtonSize.small,
                onPressed: _batchConfirm,
              ),
              SizedBox(width: 8 * scale),
              QmButton(
                label: '批量删除',
                variant: QmButtonVariant.danger,
                size: QmButtonSize.small,
                onPressed: () => setState(() => _batchDel = true),
              ),
              SizedBox(width: 8 * scale),
              QmButton(
                label: '取消',
                variant: QmButtonVariant.plain,
                size: QmButtonSize.small,
                onPressed: _clearSelection,
              ),
            ],
          ),
          if (_batchDel) _batchDeleteConfirm(),
          if (_addingBatchFolder) _batchAddFolderForm(),
        ],
      ),
    );
  }

  Widget _batchDeleteConfirm() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Container(
      margin: EdgeInsets.only(top: 10 * scale),
      padding: EdgeInsets.all(12 * scale),
      decoration: BoxDecoration(
        color: palette.errBg,
        border: Border.all(color: palette.errLine),
        borderRadius: BorderRadius.circular(12 * scale),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('删了就没了，确定吗？',
              style: TextStyle(fontWeight: FontWeight.w700)),
          SizedBox(height: 4 * scale),
          Text(
            '批量删除勾选的 ${_selected.length} 道题，删错了不能恢复。',
            style: const TextStyle(fontSize: 13, height: 1.55),
          ),
          SizedBox(height: 8 * scale),
          Row(
            children: [
              QmButton(
                label: '确认删除',
                size: QmButtonSize.small,
                onPressed: _batchDelete,
              ),
              SizedBox(width: 8 * scale),
              QmButton(
                label: '取消',
                variant: QmButtonVariant.plain,
                size: QmButtonSize.small,
                onPressed: () => setState(() => _batchDel = false),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _batchAddFolderForm() {
    final scale = qmScaleOf(context);
    return Container(
      margin: EdgeInsets.only(top: 10 * scale),
      padding: EdgeInsets.all(10 * scale),
      decoration: BoxDecoration(
        color: DesignTokens.of(Theme.of(context).brightness).surface2,
        border: Border.all(
          color: DesignTokens.of(Theme.of(context).brightness).line,
        ),
        borderRadius: BorderRadius.circular(12 * scale),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '添加新文件夹',
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 8 * scale),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _newBatchFolderCtrl,
                  decoration: const InputDecoration(
                    hintText: '文件夹名，如：错题精选',
                  ),
                  onSubmitted: (_) => _submitBatchFolder(),
                ),
              ),
              SizedBox(width: 8 * scale),
              QmButton(
                label: '添加',
                size: QmButtonSize.small,
                onPressed: _submitBatchFolder,
              ),
              SizedBox(width: 8 * scale),
              QmButton(
                label: '取消',
                variant: QmButtonVariant.plain,
                size: QmButtonSize.small,
                onPressed: () => setState(() {
                  _addingBatchFolder = false;
                  _newBatchFolderCtrl.clear();
                }),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
