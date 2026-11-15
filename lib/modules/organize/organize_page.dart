import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/database.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/uikit.dart';
import '../../widgets/widgets.dart';

/// 学科首字母：数学 S / 英语 Y / 政治 Z。
/// 父页与队列弹窗共用（SR-P2-35：原来两处各一份，一字相同）。
String _subjectInitial(String subjectId) => switch (subjectId) {
  'english' => 'Y',
  'politics' => 'Z',
  _ => 'S',
};

/// 日期文本：2026-11-14（月、日零补齐）。
/// 父页与队列弹窗共用（SR-P2-35；队列弹窗旧实现不补零，统一用补零版）。
String _dateText(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 右侧表单四区的标识（B8-6 手风琴用）：文件夹 / 来源 / 分类补充 /
/// 答案·解析·笔记。左栏「修框切片」不在其中，它是左栏独立折叠段。
enum _RightSection { folder, source, classify, answer }

/// 整理工作台 H 布局：左图右表，整页滚动，无固定高度容器。
/// 队列藏在左上角「队列」按钮后，点开弹出 D 极简式队列层（Overlay 定位
/// 在按钮正下方，见 [_openQueue]）。
/// 表单里不显示学科（导入时已定，不可改）；只有文件夹是必填。
/// 左栏只显示整题图与修框切片（整题框切片），不再有区域高亮与分框切片。
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
  // 新学科显示成“数学”）。B8-1 扫尾：空表是删光学科后的合法状态，
  // 不再回退预设三科；首帧与读库后都以真实列表为准，空就是空。
  List<Subject> _subjects = const [];
  // 库里找学科：新学科用库里的名与色；找不到才回退 Subject.byId
  //（数学兜底，只发生在数据不一致时）。
  Subject _subjectOf(String id) =>
      _subjects.firstWhere((s) => s.id == id, orElse: () => Subject.byId(id));

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

  // 各段默认开合：文件夹展开，其余折起。
  // B8-6：右侧表单四区是手风琴——一次只展开一个（Meng 2026-11-15
  // 明确改回；与第二批 Bug 4「能同时打开多个」的决定相反，见
  // docs/ui-replication/B8-6-ACCORDION.md）。点开一个就收起其他，
  // 点已展开的区则收起它（允许全收起）；左栏「修框切片」独立，不参与。
  bool _folderOpen = true;
  bool _slicesOpen = true;
  bool _sourceOpen = false;
  bool _classifyOpen = false;
  bool _answerOpen = false;

  /// B8-6 手风琴开关：点 [section] 对应的区——已展开则收起它，
  /// 未展开则只开它、其余全收起。
  void _toggleRightSection(_RightSection section) {
    setState(() {
      _folderOpen = section == _RightSection.folder && !_folderOpen;
      _sourceOpen = section == _RightSection.source && !_sourceOpen;
      _classifyOpen = section == _RightSection.classify && !_classifyOpen;
      _answerOpen = section == _RightSection.answer && !_answerOpen;
    });
  }

  /// B8-6 手风琴：只开 [section] 对应的区、其余全收起。供“待补充”
  /// 跳转与确认校验（文件夹必填未选）跳转到文件夹区用。
  void _openRightSectionOnly(_RightSection section) {
    setState(() {
      _folderOpen = section == _RightSection.folder;
      _sourceOpen = section == _RightSection.source;
      _classifyOpen = section == _RightSection.classify;
      _answerOpen = section == _RightSection.answer;
    });
  }

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
    final pending = all.where((q) => !q.isOrganized && !q.isArchived).toList();
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
      if (_index >= _queue.length) {
        _index = _queue.isEmpty ? 0 : _queue.length - 1;
      }
      _exams = exams;
      _kps = kps;
      _allTags = tags;
      _subjects = subjects;
      _customTypesAll = customs.toList();
      _loading = false;
    });
    await _loadFolders();
    _loadForm();
  }

  Future<void> _loadFolders() async {
    final current = _current;
    if (current == null) return;
    final folders = await widget.repo.folders(subjectId: current.subjectId);
    if (!mounted) return;
    setState(() => _folders = folders);
  }

  void _loadForm() {
    final q = _current;
    if (q == null) {
      return;
    }
    setState(() {
      _folderIds = List.of(q.folderIds);
      _examId = q.examId;
      _kpIds = List.of(q.knowledgePointIds);
      // SR-P2-27：旧数据里与固定枚举同名的自定义错因，在读表单时就
      // 合并进固定项（不丢错因、不在界面上重复出现）；下次保存即写回。
      _errorTypes = {
        ...q.errorTypes,
        ...q.customErrorTypes.where((t) => ErrorTypes.fixed.contains(t)),
      }.toList();
      _customTypes = q.customErrorTypes
          .where((t) => !ErrorTypes.fixed.contains(t))
          .toList();
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
    // SR-P2-27：保存兜底——表单里万一还有与固定枚举同名的自定义项
    //（如别处入口带进来的旧数据），合并进固定项再写库，不丢、不重复。
    final errorTypes = {
      ..._errorTypes,
      ..._customTypes.where((t) => ErrorTypes.fixed.contains(t)),
    }.toList();
    final customTypes = _customTypes
        .where((t) => !ErrorTypes.fixed.contains(t))
        .toList();
    return q.copyWith(
      folderIds: _folderIds,
      examId: _examId,
      knowledgePointIds: _kpIds,
      errorTypes: errorTypes,
      customErrorTypes: customTypes,
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
    // SR2-6 根治：保存成功后把新行写回内存 `_queue`。只写库不同步
    // 内存时，`_loadForm` 切题往返后仍读旧对象，再保存会把已落盘的
    // 改动（文件夹、答案等）整行覆盖回旧值。只在保存成功后写回；
    // 失败时 `_queue` 保持旧行，调用方拦下切题、提示重试。
    // 这里不用 setState：调用方随后都会 setState / `_loadForm` /
    // `_refresh`，且失败路径（未挂载）下直接改列表最安全。
    final i = _queue.indexWhere((x) => x.id == q.id);
    if (i >= 0) _queue[i] = updated;
  }

  /// 切题 / 开队列 / 跳转前的自动保存（SR2-26）：保存失败不抛错，
  /// 弹提示并返回 false，由调用方拦下本次动作——表单改动仍在内存
  /// 里（控制器与 `_queue` 都没动），用户可重试保存。直接放行会
  /// 让 `_loadForm` / `_refresh` 用旧行重建表单，等于静默丢掉未
  /// 保存的改动，所以这里选择拦下而不是放行。
  Future<bool> _trySaveCurrent() async {
    try {
      await _saveCurrent();
      return true;
    } catch (_) {
      if (mounted) _snack('保存失败，请重试');
      return false;
    }
  }

  Future<void> _saveDraft() async {
    if (await _trySaveCurrent()) {
      if (mounted) _snack('草稿已保存');
    }
  }

  Future<void> _goTo(int next) async {
    if (next < 0 || next >= _queue.length || next == _index) return;
    if (!await _trySaveCurrent()) return;
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
      // B8-6：手风琴下只开文件夹区，其余收起。
      _openRightSectionOnly(_RightSection.folder);
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
    // SR2-26 同款：保存失败时拦下、不进详情页，提示重试。
    if (!await _trySaveCurrent()) return;
    await widget.onOpenDetail(q, _orderIds);
    await _refresh();
  }

  // ---------------------------------------------------------- 队列弹出层 --

  /// 打开 D 极简式队列层：Overlay 定位在「队列」按钮正下方（HTML
  /// `.org-queue-pop` 的 `top:54px; left:0`，相对工作区左上角）。
  /// 勾选状态只活在弹出层内，关闭即丢弃（见 [_closeQueue]）。
  /// SR-P1-7：打开前先把当前表单落盘（与 [_jumpToQuestion] /
  /// [_applyQueueSort] 同款），再给弹出层拍快照——批量操作拿快照里
  /// 的旧 `Question` 整行覆盖，不先保存就会把表单里未保存的改动
  /// （文件夹、标签、答案、错因等）静默抹掉；随后 `_closeQueue` →
  /// `_refresh` → `_loadForm` 从库重读，改动就再也回不来了。
  Future<void> _openQueue() async {
    if (_queue.isEmpty || _queueEntry != null) return;
    // SR2-26：保存失败时拦下、不开队列（提示见 `_trySaveCurrent`），
    // 表单改动仍在内存里，用户可重试保存。
    if (!await _trySaveCurrent()) return;
    if (!mounted) return;
    // SR2-6：`_saveCurrent` 成功后已把表单行写回 `_queue`，这里
    // 直接拍快照即可，不再像 B5 那样单点打补丁。
    // 保存是异步的：等的过程中用户可能又点了一次「队列」，上面的
    // 首道 guard 拦不住第二次调用，这里再拦一次，避免插两个层。
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
    final width = (DesignTokens.organizeQueuePopWidth * scale).clamp(
      280.0,
      availableWidth > 280 ? availableWidth : 280.0,
    );
    final maxHeight = (size.height - top - 16).clamp(200.0, 760.0 * scale);
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
    // SR2-26：保存失败时拦下跳转、留在当前题（弹出层已关），提示重试。
    if (!await _trySaveCurrent()) return;
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
    // SR2-26：保存失败时拦下、不改排序（弹出层仍开着），提示重试。
    if (!await _trySaveCurrent()) return;
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
    return parent.id == folder.id
        ? folder.name
        : '${parent.name} / ${folder.name}';
  }

  Future<void> _submitNewFolder() async {
    final q = _current;
    if (q == null) return;
    final name = _newFolderCtrl.text.trim();
    if (name.isEmpty) return;
    // SR-P2-36：整科同名预检（新建不传 excludeId）——旧代码只查顶层
    // 同名，跨层同名会一路写到 upsertFolder 才被 StateError 拦下。
    // 预检命中即提示“已经有了”并中止；仍留 StateError 捕获作兜底
    //（竞态：预检与写入之间别人建了同名）。
    if (await widget.repo.folderNameExistsInSubject(q.subjectId, name)) {
      _snack('已经有了');
      return;
    }
    final folder = Folder(
      // SR-P2-28：id 用 newEntityId（毫秒 + 随机后缀）；纯毫秒在同一
      // 毫秒内连点两次会撞主键、后一次覆盖前一次。
      id: newEntityId('folder'),
      name: name,
      subjectId: q.subjectId,
      sortOrder: _folders.length,
    );
    try {
      await widget.repo.saveFolder(folder);
    } on StateError {
      if (mounted) _snack('已经有了');
      return;
    }
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
      // SR-P2-28：id 用 newEntityId（毫秒 + 随机后缀），防同毫秒连点撞主键。
      id: newEntityId('exam'),
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
    // SR-P2-27：与固定枚举同名时不进自定义集合，直接选中对应固定项
    //（否则 allCauses 里出现两次“其他”，详情页副标题与复习记录的
    // 错因行都会重复；详情页保存还会把它静默滤掉、错因直接消失）。
    if (ErrorTypes.fixed.contains(name)) {
      setState(() {
        if (!_errorTypes.contains(name)) _errorTypes.add(name);
        _customTypeCtrl.clear();
      });
      _snack('“$name”是固定错误类型，已帮你选中');
      return;
    }
    setState(() {
      if (!_customTypes.contains(name)) _customTypes.add(name);
      if (!_customTypesAll.contains(name)) _customTypesAll.add(name);
      _customTypeCtrl.clear();
    });
  }

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
                    height: DesignTokens.organizeTopbarMarginBottom * scale,
                  ),
                  _wideLayout(context)
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: _leftPane(q)),
                            SizedBox(
                              width: DesignTokens.organizeGridGap * scale,
                            ),
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
      MediaQuery.sizeOf(context).width >= DesignTokens.organizeGridBreakpoint;

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
          borderRadius: BorderRadius.circular(
            DesignTokens.buttonRadius * scale,
          ),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: 18 * scale,
              vertical: 9 * scale,
            ),
            decoration: BoxDecoration(
              color: palette.surface,
              border: Border.all(color: palette.lineStrong),
              borderRadius: BorderRadius.circular(
                DesignTokens.buttonRadius * scale,
              ),
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

  /// 整题纸面图（可点放大）。
  Widget _paperImage(Question q) {
    final scale = qmScaleOf(context);
    final slice = QuestionSlice(
      question: q,
      subject: _subjectOf(q.subjectId),
      maxHeight: DesignTokens.organizePaperMaxHeight * scale,
      failed: widget.imageFailed,
      onTap: widget.imageFailed
          ? null
          : () => showQuestionZoomDialog(context, q),
    );
    if (widget.imageFailed) return slice;
    // B2 Bug 2 根因：Column(stretch) 里子组件被拉到左栏整宽，而
    // QuestionSlice 的真图按固有尺寸渲染（cacheWidth 只降采样不放大，
    // 宽条切片固有宽小于容器宽）。Align 让它收成切片实际尺寸；
    // 演示题 / 失败占位是 Center 撑满容器，不受影响。
    return Align(
      alignment: Alignment.topLeft,
      child: slice,
    );
  }

  /// 修框切片：只有「整题框切片」一张卡，只存图不做 OCR。
  /// 整题框有真实切片时显示真图（QuestionSlice 已接 slice_path），
  /// 否则显示题干文字。
  Widget _slicesSection(Question q) {
    // B2 Bug 3：整题框有真实切片时，图按固有尺寸窄于卡宽，卡框伸到
    // 图外面（与 Bug 2 同因）。卡贴图收窄：Align 让卡收成图宽，
    // 卡头 Row 也随之收窄（hugContent，见 _sliceCard）；文字卡
    // （无真图）保持整宽不变。文件缺失时 QuestionSlice 显示缺图
    // 占位（撑满容器），不贴图收窄。
    final sliceAbs = q.slicePath == null
        ? null
        : AppDatabase.resolveDataPath(q.slicePath!);
    final hasRealSlice = sliceAbs != null && File(sliceAbs).existsSync();
    final wholeCard = _sliceCard(
      '整题框切片',
      q.slicePath != null
          ? QuestionSlice(
              question: q,
              maxHeight: 220,
              // SR-P2-29：补传学科对象；不传时缺图占位回退 Subject.byId，
              // 新学科会显示成数学。
              subject: _subjectOf(q.subjectId),
            )
          : _sliceTextBody(q),
      hugContent: hasRealSlice,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasRealSlice)
          Align(alignment: Alignment.centerLeft, child: wholeCard)
        else
          wholeCard,
      ],
    );
  }

  Widget _sliceTextBody(Question q) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Text(
      q.sliceText,
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

  /// 切片卡：纸面底 + 纸线边 + 卡头（标签 + 「切片图」）+ 卡体
  /// （衬线 12.5px，上限 66px，见 `.slice-card`）。
  /// [hugContent] 为 true 时卡头 Row 收成内容宽（不用 Spacer 撑满），
  /// 供外层 Align 把卡收成图宽用（B2 Bug 3）；默认 false，卡整宽。
  Widget _sliceCard(String label, Widget body, {bool hugContent = false}) {
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
            mainAxisSize: hugContent ? MainAxisSize.min : MainAxisSize.max,
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
              if (hugContent) SizedBox(width: 12 * scale) else const Spacer(),
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
          onToggle: () => _toggleRightSection(_RightSection.folder),
          variant: QmFoldVariant.form,
          child: _folderSection(q),
        ),
        SizedBox(height: DesignTokens.organizeSectionGap * scale),
        QmFoldSection(
          title: '来源（可选）',
          subtitle: '试卷（来源）',
          expanded: _sourceOpen,
          onToggle: () => _toggleRightSection(_RightSection.source),
          variant: QmFoldVariant.form,
          child: _sourceSection(),
        ),
        SizedBox(height: DesignTokens.organizeSectionGap * scale),
        QmFoldSection(
          title: '分类补充（可选）',
          subtitle: '知识点 · 错误类型 · 标签',
          expanded: _classifyOpen,
          onToggle: () => _toggleRightSection(_RightSection.classify),
          variant: QmFoldVariant.form,
          child: _classifySection(q),
        ),
        SizedBox(height: DesignTokens.organizeSectionGap * scale),
        QmFoldSection(
          title: '答案 · 解析 · 笔记（可选）',
          subtitle: '答案在上、解析在下，笔记单独一栏',
          expanded: _answerOpen,
          onToggle: () => _toggleRightSection(_RightSection.answer),
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
                        // B8-6：手风琴下只开文件夹区，其余收起。
                        _openRightSectionOnly(_RightSection.folder);
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
                    text: '（点一下跳到那一栏）——只有必填没齐才提示；答案、解析、知识点、错误类型、试卷、标签、笔记都是可选，填不填都不算、不提示',
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
        _fieldLabel('文件夹（归类）', required: true, hint: '可多选 · 一道题可进多个文件夹，题只存一份'),
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
            const DropdownMenuItem(value: '__add__', child: Text('＋ 添加新试卷…')),
            const DropdownMenuItem(value: '__none__', child: Text('未归属试卷')),
            ..._exams.map(
              (e) => DropdownMenuItem(
                value: e.id,
                child: Text(
                  e.date == null ? e.name : '${e.name}（${_dateText(e.date!)}）',
                ),
              ),
            ),
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
                      _newExamDate == null ? '未选日期' : _dateText(_newExamDate!),
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
    final subjectKps = _kps.where((k) => k.subjectId == q.subjectId).toList();
    final chapters = <String>[];
    for (final k in subjectKps) {
      if (!chapters.contains(k.chapter)) chapters.add(k.chapter);
    }
    final customOptions = {..._customTypesAll, ..._customTypes}
        // SR-P2-27：旧数据里与固定枚举同名的自定义项不重复出芯片。
        .where((t) => !ErrorTypes.fixed.contains(t))
        .toList();
    final selectedKpNames = _kpIds
        .map(
          (id) => _kps.firstWhere(
            (k) => k.id == id,
            orElse: () => KnowledgePoint(
              id: id,
              subjectId: q.subjectId,
              chapter: '',
              name: '已删知识点',
            ),
          ),
        )
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
            const Text(
              '已选（点一下取消）：',
              style: TextStyle(fontSize: 13, height: 1.6),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: _errorTypes.isEmpty && _customTypes.isEmpty
                  ? Text(
                      '还没选错误类型',
                      style: TextStyle(
                        fontSize: 13,
                        color: palette.muted,
                        height: 1.6,
                      ),
                    )
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
            ...ErrorTypes.fixed.map(
              (t) => QmChip(
                label: t,
                selected: _errorTypes.contains(t),
                onTap: () => setState(() {
                  if (_errorTypes.contains(t)) {
                    _errorTypes.remove(t);
                  } else {
                    _errorTypes.add(t);
                  }
                }),
              ),
            ),
            ...customOptions.map(
              (t) => QmChip(
                label: '$t（自定义）',
                selected: _customTypes.contains(t),
                onTap: () => setState(() {
                  if (_customTypes.contains(t)) {
                    _customTypes.remove(t);
                  } else {
                    _customTypes.add(t);
                  }
                }),
              ),
            ),
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
              (t) => !QmChip.presetTags.contains(t),
            ))
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
    final points = subjectKps.where((k) => k.chapter == chapter).toList();
    final inChapter = points.where((k) => _kpIds.contains(k.id)).length;
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
        _helperText('笔记只记你自己的话，和上面的答案、解析是三回事：答案是标准答案，解析是解题过程，笔记是你写给自己的'),
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
        top: DesignTokens.organizeWorkActsMarginTop * scale,
      ),
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
                onPressed: _index > 0 ? () => _goTo(_index - 1) : null,
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
        top: DesignTokens.organizeConfirmBarMarginTop * scale,
      ),
      padding: EdgeInsets.only(top: 18 * scale),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.line, width: 2)),
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

/// B9-2：队列弹窗内联下拉的菜单标识（排序 / 文件夹 / 标签）。
/// 根因（SR3-15 探针结论，见 `_toggleMenu`）：队列层是直接插进
/// Overlay 的 OverlayEntry，DropdownButton 的菜单走 Navigator 路由；
/// Navigator 每次 push 后 `OverlayState.rearrange` 都会把直接插入的
/// 条目留在所有路由条目之上，于是菜单被画在队列层下面、点按也被队列层
/// 外框（BoxDecoration）截住——排序、文件夹两个下拉在测试里点按无响应
/// 就是这个原因，是产品问题，不是测试环境问题。弹窗内的下拉因此不用
/// DropdownButton，改用弹窗自己 Stack 顶层渲染的内联菜单（与 B3 删除
/// 确认框同款做法：状态放 `_QueuePopupState`，面板画在弹窗的 Stack 里）。
enum _PopupMenu { sort, folder, tag }

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
  // 以前直接 Subject.byId，新学科显示成“数学”）。B8-1 扫尾：空表是
  // 删光学科后的合法状态，不再回退预设三科；首帧与读库后都以真实
  // 列表为准，空就是空。
  List<Subject> _subjects = const [];
  // 库里找学科：新学科用库里的名与色；找不到才回退 Subject.byId
  //（数学兜底，只发生在数据不一致时）。
  Subject _subjectOf(String id) =>
      _subjects.firstWhere((s) => s.id == id, orElse: () => Subject.byId(id));
  bool _addingBatchFolder = false;
  String? _batchFolderId;
  // B9-2：批量打标签的标签来源（与整理表单一致：预设 + 自定义）。
  // 弹窗自己的 `_loadMeta` 以前只读 exams/folders/subjects，不读标签，
  // 这里补上；下拉选项见 `_tagOptions`。
  List<String> _allTags = [];
  // B9-2：批量打标签当前选中的标签。默认 '需重做'，与旧固定按钮
  // 一次点按的行为一致（不清空选中，只提示，见 `_batchTag`）。
  String? _batchTag = '需重做';
  // B9-2：弹窗内联下拉的菜单状态（见 `_toggleMenu` 的根因注释）。
  _PopupMenu? _openMenu;
  double _menuLeft = 0;
  double _menuTop = 0;
  double _menuWidth = 200;
  final _sortFieldKey = GlobalKey();
  final _folderFieldKey = GlobalKey();
  final _tagFieldKey = GlobalKey();
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
    final folders = await widget.repo.folders(subjectId: _currentSubjectId);
    final subjects = await widget.repo.subjects();
    // B9-2：补读标签（批量打标签下拉用；与整理表单同源 `repo.tags()`）。
    final tags = await widget.repo.tags();
    if (!mounted) return;
    setState(() {
      _examNames = {for (final e in exams) e.id: e.name};
      _folders = folders;
      _subjects = subjects;
      _allTags = tags;
      _batchFolderId ??= folders.isEmpty ? null : folders.first.id;
    });
  }

  void _scrollToCurrent() {
    final filtered = _filtered;
    final idx = filtered.indexWhere((q) => q.id == widget.currentId());
    if (idx < 0 || !_scrollCtrl.hasClients) return;
    _scrollCtrl.jumpTo(
      (idx * 44).toDouble().clamp(0.0, _scrollCtrl.position.maxScrollExtent),
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
          // SR-P2-35：用文件顶部的共用 _subjectInitial，不再各一份。
          final c = _subjectInitial(
            a.subjectId,
          ).compareTo(_subjectInitial(b.subjectId));
          return c != 0 ? c : b.createdAt.compareTo(a.createdAt);
        });
      case 'subjectDesc':
        list.sort((a, b) {
          final c = _subjectInitial(
            b.subjectId,
          ).compareTo(_subjectInitial(a.subjectId));
          return c != 0 ? c : b.createdAt.compareTo(a.createdAt);
        });
      case 'timeDesc':
      default:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return list;
  }

  List<Question> get _selectedQuestions =>
      _questions.where((q) => _selected.contains(q.id)).toList();

  /// B9-2：批量打标签下拉的选项，与整理表单同序——预设在前
  /// （易错 / 常考 / 需重做），自定义在后（去重预设）。
  List<String> get _tagOptions => [
    ...QmChip.presetTags,
    ..._allTags.where((t) => !QmChip.presetTags.contains(t)),
  ];

  /// B9-2：批量加文件夹字段当前显示的文件夹名（未选时是提示文案）。
  String get _batchFolderLabel {
    final id = _batchFolderId;
    if (id == null) return '选文件夹';
    for (final f in _folders) {
      if (f.id == id) return f.name;
    }
    return '选文件夹';
  }

  /// B9-2 全选：范围是当前筛选出的题（`_filtered`），不是全部题——
  /// 用户搜/排之后全选，选中的应是眼前这批，所见即所得；选了看不见
  /// 的题再批量确认/删除会吓人一跳。Checkbox 三态：全选上 / 全没选 /
  /// 部分选（null，显示短横）。
  bool? get _selectAllValue {
    if (_filtered.isEmpty) return false;
    final selectedCount =
        _filtered.where((q) => _selected.contains(q.id)).length;
    if (selectedCount == 0) return false;
    if (selectedCount == _filtered.length) return true;
    return null;
  }

  /// B9-2 全选切换：没全选上就把当前筛选出的题全勾上；已全选上就
  /// 只取消当前筛选出的题——筛选外的已选项保留（比如先搜“函数”全选，
  /// 再搜“导数”全选，两批都在；取消时也只取消眼前这批）。
  void _toggleSelectAll() {
    final ids = _filtered.map((q) => q.id).toList();
    if (ids.isEmpty) return;
    setState(() {
      if (ids.every(_selected.contains)) {
        _selected.removeAll(ids);
      } else {
        _selected.addAll(ids);
      }
    });
  }

  void _closeMenu() {
    if (_openMenu != null) setState(() => _openMenu = null);
  }

  /// B9-2：内联下拉开关。点字段只改 state，选项面板由弹窗自己的
  /// Stack 画在顶层（见 `_menuPanel`），不走 Navigator 路由——这就
  /// 是修掉 SR3-15 共因的关键：路由菜单永远会被 `rearrange` 压到
  /// 队列层之下，内联菜单不会。面板默认向下展开；下方空间不够就向上
  /// 展开，并夹在弹窗上下边之内。
  void _toggleMenu(_PopupMenu menu, GlobalKey fieldKey) {
    if (_openMenu == menu) {
      _closeMenu();
      return;
    }
    final box = fieldKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final scale = qmScaleOf(context);
    final origin = box.localToGlobal(Offset.zero);
    final count = switch (menu) {
      _PopupMenu.sort => 4,
      _PopupMenu.folder => 1 + _folders.length,
      _PopupMenu.tag => _tagOptions.length,
    };
    final menuHeight = (count * 38.0 + 8.0)
        .clamp(0.0, 248.0 * scale)
        .toDouble();
    var top = origin.dy + box.size.height + 4 * scale;
    final popupBottom = widget.top + widget.maxHeight;
    if (top + menuHeight > popupBottom - 8 * scale &&
        origin.dy - 4 * scale - menuHeight >= widget.top + 8 * scale) {
      top = origin.dy - 4 * scale - menuHeight;
    }
    top = top.clamp(
      widget.top + 8 * scale,
      (popupBottom - 8 * scale - menuHeight).clamp(
        widget.top + 8 * scale,
        double.infinity,
      ),
    );
    setState(() {
      _openMenu = menu;
      _menuLeft = origin.dx;
      _menuTop = top;
      _menuWidth = box.size.width.clamp(
        120.0 * scale,
        widget.width - 16 * scale,
      );
    });
  }

  /// B9-2：内联下拉的字段（替代 DropdownButton 的按钮部分）：
  /// 当前值 + 下箭头，底边细线沿用 DropdownButton 的视觉。
  Widget _menuField({
    required GlobalKey fieldKey,
    required String label,
    required _PopupMenu menu,
  }) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final open = _openMenu == menu;
    return InkWell(
      key: fieldKey,
      onTap: () => _toggleMenu(menu, fieldKey),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: 10 * scale,
          vertical: 9 * scale,
        ),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: open ? palette.accent : palette.lineStrong,
              width: open ? 2 : 1,
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13.5, height: 1.2),
              ),
            ),
            SizedBox(width: 6 * scale),
            Text('▾', style: TextStyle(fontSize: 12, color: palette.muted)),
          ],
        ),
      ),
    );
  }

  /// B9-2：内联下拉的选项面板，画在弹窗 Stack 顶层（`build` 末尾），
  /// 全屏透明层点按即关菜单（只关菜单，不关队列）。选项行点后执行
  /// 各自的旧 onChanged 逻辑再关菜单。
  Widget _menuPanel() {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final menu = _openMenu!;
    final List<Widget> options;
    switch (menu) {
      case _PopupMenu.sort:
        const labels = {
          'timeDesc': '时间降序',
          'timeAsc': '时间升序',
          'subjectAsc': '学科首字母升序',
          'subjectDesc': '学科首字母降序',
        };
        options = labels.entries
            .map(
              (e) => _menuOption(
                label: e.value,
                selected: _sort == e.key,
                onTap: () async {
                  _closeMenu();
                  if (e.key == _sort) return;
                  setState(() => _sort = e.key);
                  await widget.onSortChanged(e.key);
                },
              ),
            )
            .toList();
      case _PopupMenu.folder:
        options = [
          _menuOption(
            label: '＋ 添加新文件夹…',
            selected: false,
            onTap: () => setState(() {
              _openMenu = null;
              _addingBatchFolder = true;
            }),
          ),
          ..._folders.map(
            (f) => _menuOption(
              label: f.name,
              selected: _batchFolderId == f.id,
              onTap: () => setState(() {
                _openMenu = null;
                _batchFolderId = f.id;
              }),
            ),
          ),
        ];
      case _PopupMenu.tag:
        options = _tagOptions
            .map(
              (t) => _menuOption(
                label: '#$t',
                selected: _batchTag == t,
                onTap: () => setState(() {
                  _openMenu = null;
                  _batchTag = t;
                }),
              ),
            )
            .toList();
    }
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _closeMenu,
            child: Container(color: Colors.transparent),
          ),
        ),
        Positioned(
          left: _menuLeft,
          top: _menuTop,
          width: _menuWidth,
          child: Material(
            color: palette.surface,
            elevation: 8,
            borderRadius: BorderRadius.circular(10 * scale),
            clipBehavior: Clip.antiAlias,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: palette.lineStrong),
                borderRadius: BorderRadius.circular(10 * scale),
              ),
              constraints: BoxConstraints(maxHeight: 248 * scale),
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.symmetric(vertical: 4 * scale),
                children: options,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _menuOption({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scale = qmScaleOf(context);
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 12 * scale,
          vertical: 10 * scale,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight:
                      selected ? FontWeight.w700 : FontWeight.normal,
                  color: selected ? palette.accent : null,
                  height: 1.2,
                ),
              ),
            ),
            if (selected)
              Text('✓', style: TextStyle(color: palette.accent)),
          ],
        ),
      ),
    );
  }

  String _detailLine(Question q) {
    final exam = q.examId == null ? '未归属' : (_examNames[q.examId] ?? '未知试卷');
    final missing = q.folderIds.isEmpty ? '待补充 1 项：文件夹（归类）' : '必填已齐';
    return '${_subjectOf(q.subjectId).name} · ${sliceKindLabel(q.sliceKind)} · ${_dateText(q.createdAt)} · 试卷（来源）：$exam · $missing';
  }

  // B3：单删 / 批量删除确认都改模态弹窗（见 [_askDeleteOne] /
  // [_askBatchDelete]），不再用行内确认条。
  Future<void> _deleteOne(Question q) async {
    await widget.repo.delete(q);
    if (!mounted) return;
    setState(() {
      _questions.removeWhere((x) => x.id == q.id);
      _selected.remove(q.id);
    });
  }

  /// B3：删除确认的模态弹窗。队列层本身是直接插进 overlay 的
  /// OverlayEntry，新路由（showDialog）会插到它下面、被队列层盖住
  /// 点不到，所以确认框不走 showDialog，改在弹窗自己的 Stack 顶层
  /// 渲染 ModalBarrier + AlertDialog（见 build 末尾）；形式仍是
  /// 模态弹窗，文案与原来行内条一致。
  String? _confirmTitle;
  String? _confirmDetail;
  Completer<bool>? _confirmCompleter;

  Future<bool> _askConfirm({
    required String title,
    required String detail,
  }) {
    final completer = Completer<bool>();
    setState(() {
      _confirmTitle = title;
      _confirmDetail = detail;
      _confirmCompleter = completer;
    });
    return completer.future;
  }

  void _resolveConfirm(bool ok) {
    final completer = _confirmCompleter;
    setState(() {
      _confirmTitle = null;
      _confirmDetail = null;
      _confirmCompleter = null;
    });
    completer?.complete(ok);
  }

  Future<void> _askDeleteOne(Question q) async {
    final ok = await _askConfirm(
      title: '确认删除这道题？',
      detail:
          '「${_subjectOf(q.subjectId).name} · ${sliceKindLabel(q.sliceKind)}｜${q.title}」删了就没了，不可恢复。',
    );
    if (ok && mounted) await _deleteOne(q);
  }

  Future<void> _askBatchDelete() async {
    final ok = await _askConfirm(
      title: '删了就没了，确定吗？',
      detail: '批量删除勾选的 ${_selected.length} 道题，删错了不能恢复。',
    );
    if (ok && mounted) await _batchDelete();
  }

  /// B9-2：批量打标签（下拉选标签；旧 `_batchTagRedo` 只打固定
  /// '需重做'，已改成 `_applyBatchTag` + `_batchTag` 字段，默认仍是
  /// '需重做'）。打完**不清空选中**（与 `_batchAddFolder` 一致：
  /// 那边也只同步 `_questions` + 提示，没有别的收尾动作），只提示；
  /// 已保存子集同步回弹窗内 `_questions`（SR3-15 同款 finally 同步，
  /// 防后续批量操作拿旧行覆盖）。
  Future<void> _applyBatchTag() async {
    final tag = _batchTag;
    if (tag == null || tag.isEmpty) {
      widget.onNotify('先选标签');
      return;
    }
    final selected = _selectedQuestions;
    // SR3-15：循环中途某题写库失败时，已保存的题也必须同步回弹窗内
    // 的 `_questions`，否则后续批量加文件夹 / 批量确认拿旧行整行
    // 覆盖，会把刚落盘的标签抹掉。已保存的 id 记下来，同步放在
    // finally 里保证执行；失败不抛到按钮回调，给“部分保存失败”提示。
    final savedIds = <String>{};
    try {
      for (final q in selected) {
        final tags = {...q.tags, tag}.toList();
        await widget.repo.save(q.copyWith(tags: tags));
        savedIds.add(q.id);
      }
    } catch (_) {
      // 落到 finally 同步已保存子集，再由下面的分支报部分失败。
    } finally {
      // SR2-5：保存后把标签同步回弹窗内的 `_questions`（与
      // `_batchAddFolder` 同款 `setState` map），否则同一次弹窗里
      // 再做批量加文件夹 / 批量确认时，拿的仍是打标签前的旧
      // `Question` 整行覆盖，标签被抹掉。
      if (mounted && savedIds.isNotEmpty) {
        setState(() {
          _questions = _questions.map((q) {
            if (savedIds.contains(q.id) && !q.tags.contains(tag)) {
              return q.copyWith(tags: [...q.tags, tag]);
            }
            return q;
          }).toList();
        });
      }
    }
    if (savedIds.length < selected.length) {
      widget.onNotify(
        '部分保存失败：已给 ${savedIds.length} 道题打上 #$tag，其余请重试',
      );
      return;
    }
    widget.onNotify('已给 ${selected.length} 道题打上 #$tag');
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
        await widget.repo.save(
          q.copyWith(folderIds: [...q.folderIds, folderId]),
        );
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
    widget.onNotify(
      skipped > 0 ? '已加入 $applied 道，$skipped 道不是本科，跳过' : '已加入文件夹',
    );
  }

  Future<void> _submitBatchFolder() async {
    final name = _newBatchFolderCtrl.text.trim();
    if (name.isEmpty) return;
    // SR-P2-36：整科同名预检（新建不传 excludeId；见 _submitNewFolder
    // 注释——旧代码只查顶层同名，跨层同名靠 upsertFolder 的 StateError
    // 兜底，这里同样预检 + 捕获）。
    if (await widget.repo
        .folderNameExistsInSubject(_currentSubjectId, name)) {
      widget.onNotify('已经有了');
      return;
    }
    final folder = Folder(
      // SR-P2-28：id 用 newEntityId（毫秒 + 随机后缀），防同毫秒连点撞主键。
      id: newEntityId('folder'),
      name: name,
      subjectId: _currentSubjectId,
      sortOrder: _folders.length,
    );
    try {
      await widget.repo.saveFolder(folder);
    } on StateError {
      widget.onNotify('已经有了');
      return;
    }
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
    final blocked = _selectedQuestions
        .where((q) => q.folderIds.isEmpty)
        .toList();
    final ok = _selectedQuestions.where((q) => q.folderIds.isNotEmpty).toList();
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
    });
  }

  void _clearSelection() {
    setState(() {
      _selected.clear();
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
          // B9-2：内联下拉菜单开着时 Esc 先关菜单（再是确认框、队列层）。
          if (_openMenu != null) {
            _closeMenu();
            return KeyEventResult.handled;
          }
          // 确认框开着时 Esc 先关确认框（不关队列层）。
          if (_confirmCompleter != null) {
            _resolveConfirm(false);
            return KeyEventResult.handled;
          }
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
                        padding: EdgeInsets.only(
                          top: 2 * scale,
                          bottom: 10 * scale,
                        ),
                        child: Text(
                          '点中一道题，下面展开它的一行详情 · 全选勾上当前列表，底部出现批量条',
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
                                  onChanged: (v) => setState(() => _search = v),
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
                                // B9-2：内联下拉（替代 DropdownButton，见
                                // `_toggleMenu` 的 SR3-15 根因注释——路由菜单在
                                // 队列层里点按无响应，是产品问题）。
                                _menuField(
                                  fieldKey: _sortFieldKey,
                                  label: switch (_sort) {
                                    'timeAsc' => '时间升序',
                                    'subjectAsc' => '学科首字母升序',
                                    'subjectDesc' => '学科首字母降序',
                                    _ => '时间降序',
                                  },
                                  menu: _PopupMenu.sort,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      // B9-2 全选：放在列表顶栏（不勾题也能点到），管当前
                      // 筛选出的题；三态 Checkbox + 计数，点后批量条出现。
                      Padding(
                        padding: EdgeInsets.only(top: 10 * scale),
                        child: Row(
                          children: [
                            Checkbox(
                              value: _selectAllValue,
                              tristate: true,
                              activeColor: palette.accent,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                              onChanged: filtered.isEmpty
                                  ? null
                                  : (_) => _toggleSelectAll(),
                            ),
                            GestureDetector(
                              onTap: filtered.isEmpty
                                  ? null
                                  : _toggleSelectAll,
                              child: const Text(
                                '全选',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  height: 1.2,
                                ),
                              ),
                            ),
                            SizedBox(width: 8 * scale),
                            Text(
                              '已选 ${_selected.length} / 共 ${filtered.length} 道',
                              style: TextStyle(
                                fontSize: 12,
                                color: palette.muted,
                                height: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: 6 * scale),
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
            // B9-2：内联下拉菜单（见 `_toggleMenu` 的 SR3-15 根因注释）：
            // 画在弹窗 Stack 顶层、确认框之下；确认框仍是最上层。
            if (_openMenu != null) _menuPanel(),
            // B3：删除确认的模态弹窗（见 [_askConfirm]）：直接画在队列层
            // 自己的 Stack 顶层，盖在队列层之上；ModalBarrier 挡住底下
            // 的点按，Esc 先关确认框（见上面 onKeyEvent）。
            if (_confirmCompleter != null) ...[
              const Positioned.fill(
                child: ModalBarrier(
                  dismissible: false,
                  color: Color(0x88000000),
                ),
              ),
              Center(
                child: AlertDialog(
                  title: Text(_confirmTitle ?? ''),
                  content: Text(_confirmDetail ?? ''),
                  actions: [
                    TextButton(
                      onPressed: () => _resolveConfirm(false),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () => _resolveConfirm(true),
                      child: const Text('确认删除'),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
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
                    fontWeight: isCurrent ? FontWeight.w800 : FontWeight.normal,
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
              onPressed: () => _askDeleteOne(q),
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
              style: TextStyle(fontSize: 12, color: palette.muted, height: 1.5),
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
    return InkWell(onTap: () => widget.onJump(q.id), child: row);
  }

  /// 底部浮动批量条：只在有勾选时出现。
  /// B9-2 重排：三行——第 1 行标签（下拉 + 打标签按钮）、第 2 行文件夹
  /// （下拉 + 加入按钮）、第 3 行确认 / 删除 / 取消用 Wrap（窄窗口
  /// 时自动换行，不溢出）。两个下拉都是内联下拉（见 `_toggleMenu`，
  /// SR3-15 根因：DropdownButton 的路由菜单在队列层里点按无响应）。
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
              Expanded(
                child: _menuField(
                  fieldKey: _tagFieldKey,
                  label: _batchTag == null ? '选标签' : '#$_batchTag',
                  menu: _PopupMenu.tag,
                ),
              ),
              SizedBox(width: 8 * scale),
              QmButton(
                label: '批量打标签',
                size: QmButtonSize.small,
                onPressed: _applyBatchTag,
              ),
            ],
          ),
          SizedBox(height: 8 * scale),
          Row(
            children: [
              Expanded(
                child: _menuField(
                  fieldKey: _folderFieldKey,
                  label: _batchFolderLabel,
                  menu: _PopupMenu.folder,
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
          Wrap(
            spacing: 8 * scale,
            runSpacing: 8 * scale,
            children: [
              QmButton(
                label: '批量确认整理',
                size: QmButtonSize.small,
                onPressed: _batchConfirm,
              ),
              QmButton(
                label: '批量删除',
                variant: QmButtonVariant.danger,
                size: QmButtonSize.small,
                onPressed: _askBatchDelete,
              ),
              QmButton(
                label: '取消',
                variant: QmButtonVariant.plain,
                size: QmButtonSize.small,
                onPressed: _clearSelection,
              ),
            ],
          ),
          if (_addingBatchFolder) _batchAddFolderForm(),
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
                  decoration: const InputDecoration(hintText: '文件夹名，如：错题精选'),
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
