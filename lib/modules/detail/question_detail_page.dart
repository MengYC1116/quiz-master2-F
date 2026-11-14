// 题目详情（R7 重建，方案 2 分段折叠式）。
//
// HTML 视觉基准 `viewDetail`（交互原型，SHA256 18c8c434…35e1）：
// - 工具栏：`← 返回{来源}` + `第 N / M 题 · 按{来源}当前的顺序` +
//   右上角 编辑 / 保存 / 取消；标题 `学科 · 题型｜题名 ★`，星可点；
// - 副标题：学科只读说明 + 错因汇总（每错因一个状态 pill）；已归档黄色横幅；
// - 整题大图在上（点图放大、滚轮缩放，无第 2 层高亮框）；图加载失败时
//   显示学科图标 + 题型文字占位 + 错误横幅；
// - 三段折叠 答案解析 / 题目信息 / 复习记录，每次进入默认全部折叠；
// - 答案解析默认藏在「看答案」后，空显示可点「待补充 · 点这里补」；
// - 编辑模式保存才生效，取消有改动时内联问是否保存；学科不可改；
//   答案/解析在「题目信息」的编辑表单里改；
// - 底部操作：返回 / 收藏 / 归档（已归档时变「恢复」）/ 上一题 / 下一题 /
//   删除；删除用内联确认框（`删了就没了，确定吗？`），删后自动进下一题；
// - 本页没有任何「开始复习」按钮；复习记录区只留「加入复习 /
//   取消加入复习」（未整理题没有）、各错因状态、解决次数与全部解决记录；
//   旧的复习状态下拉与下次复习日期输入已删，不复活翻卡模型。
//
// 颜色只取 DesignTokens；文字符号（D3），不用图标字体；
// 三档缩放 1.00/1.15/1.30 由 app.dart TextScaler + qmScaleOf 统一做。
import 'dart:io';

import 'package:flutter/material.dart';

import '../../data/database.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../services/import_service.dart';
import '../../services/page_image_pipeline.dart';
import '../../services/yolo_onnx_service.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/uikit.dart';
import '../../widgets/widgets.dart';
import '../collect/collect_page.dart';

/// 表单字段（HTML `.form-grid` 的一格）：label 12.5px/700 ink-2，
/// 值 14.5px；[hint] 是字段下的补充说明（`.ph` 12.5px muted）。
class _Field {
  const _Field(this.label, this.child, {this.full = false, this.hint});

  final String label;
  final Widget child;
  final bool full;
  final String? hint;
}

class QuestionDetailPage extends StatefulWidget {
  const QuestionDetailPage({
    super.key,
    required this.repo,
    required this.questionId,
    required this.orderIds,
    required this.onChanged,
    this.sourceLabel = '错题本',
    this.imageFailed = false,
  });

  final QuestionRepository repo;
  final String questionId;
  final List<String> orderIds;
  final VoidCallback onChanged;

  /// 进入来源（HTML `detailFromName`）：错题本 / 整理工作台 / 复习。
  /// 返回按钮与「第 N / M 题 · 按{来源}当前的顺序」用它；app.dart
  /// 按调用页传入，默认错题本。
  final String sourceLabel;

  /// 图加载失败占位开关：应用内暂无真实图片通道，默认 false；
  /// 只供 widget 测试与截图对照验证失败占位（与 R5/R6 同款做法）。
  final bool imageFailed;

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
  // 学科表：读库 subjects（P0B1 扫尾；以前直接 Subject.byId，
  // 新学科显示成“数学”）。空库回退预设三科。
  List<Subject> _subjects = Subject.all;
  // 库里找学科：新学科用库里的名与色；找不到才回退 Subject.byId
  //（数学兜底，只发生在数据不一致时）。
  Subject _subjectOf(String id) => _subjects.firstWhere(
        (s) => s.id == id,
        orElse: () => Subject.byId(id),
      );

  bool _editing = false;
  bool _dirty = false;
  bool _answerVisible = false;

  /// 取消编辑时的内联确认框（HTML `.confirmbox`）是否显示；
  /// [_cancelAskPop] 表示它是由返回触发的（选“保存并退出 / 不保存”
  /// 后要离开本页），否则只是退出编辑模式。
  bool _cancelAsk = false;
  bool _cancelAskPop = false;

  /// 删除内联确认框（HTML `.confirmbox`）是否显示。
  bool _confirmDelete = false;

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
    final subjects = await widget.repo.subjects();
    if (!mounted) return;
    setState(() {
      _q = q;
      _records = records;
      _history = history;
      _exams = exams;
      _folders = folders;
      _allTags = tags;
      _kps = kps;
      _subjects = subjects.isEmpty ? Subject.all : subjects;
      _loading = false;
    });
  }

  String _fmtDate(DateTime d) => '${d.year}年${d.month}月${d.day}日';

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 答案、解析、备注三处文字内容是否全空（HTML `state==='empty'`：
  /// “这道题还没有补充任何文字内容”）。
  bool _isEmptyText(Question q) =>
      (q.answer ?? '').trim().isEmpty &&
      (q.explanation ?? '').trim().isEmpty &&
      (q.notes ?? '').trim().isEmpty;

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
      _cancelAsk = false;
      _confirmDelete = false;
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
      // P2 §1.2：图片字段是本题的身份，编辑表单不改它们——
      // 全新构造时必须从 base 带上，否则编辑一次就把
      // sourcePath/slicePath 等抹掉，题变成“无图题”。
      sourcePath: base.sourcePath,
      sourceKind: base.sourceKind,
      sourcePage: base.sourcePage,
      pageImagePath: base.pageImagePath,
      slicePath: base.slicePath,
      sliceWidth: base.sliceWidth,
      sliceHeight: base.sliceHeight,
    );
    await widget.repo.save(updated);
    await widget.repo.syncCauseRecords(updated);
    setState(() {
      _editing = false;
      _dirty = false;
      _cancelAsk = false;
    });
    widget.onChanged();
    await _load();
  }

  /// §1.5.1 重新框选：加载同页全部 1 层框——目标题的框可编辑，
  /// 同页其他题的框只读（重叠校验对所有框生效）；取消丢弃本次修改。
  /// 页图缺失时不开编辑器（§6 第 6 条）。
  Future<void> _reworkBoxes() async {
    final q = _q;
    if (q == null) return;
    if (q.pageImagePath == null) {
      _snack('这道题没有页图，无法重新框选');
      return;
    }
    final pageAbs = AppDatabase.resolveDataPath(q.pageImagePath!);
    if (pageAbs == null || !File(pageAbs).existsSync()) {
      _snack('页图缺失：找不到这页的图片，请重新导入');
      return;
    }
    final page = q.sourcePage ?? 1;
    final allBoxes = await widget.repo.boxesForPageImage(q.pageImagePath!);
    final targets = allBoxes
        .where((b) => b.questionId == q.id && b.layer == 1)
        .toList();
    final readOnly = allBoxes
        .where((b) => b.questionId != q.id && b.layer == 1)
        .toList();
    final targetIds = targets.map((b) => b.id).toSet();
    final inners = <String, List<QuestionBox>>{};
    final standalone = <QuestionBox>[];
    for (final b in allBoxes) {
      if (b.questionId != q.id || b.layer != 2) continue;
      if (b.parentBoxId != null && targetIds.contains(b.parentBoxId)) {
        (inners[b.parentBoxId!] ??= []).add(b);
      } else {
        standalone.add(b);
      }
    }
    if (!mounted) return;
    final result = await showBoxEditorDialog(
      context: context,
      fileName: q.sourcePath?.split('/').last ?? '页图',
      pageImagePath: pageAbs,
      page: page,
      pageCount: 1,
      subjectName: _subjectOf(q.subjectId).name,
      taskId: 'rework-${q.id}',
      mode: BoxEditorMode.rework,
      initialBoxesByPage: {page: targets},
      initialInners: inners,
      initialStandalone: {page: standalone},
      reworkQuestionId: q.id,
      readOnlyBoxes: readOnly,
      yoloService: YoloOnnxService(),
    );
    if (result == null) return;
    final newLayer1 = result.boxesByPage[page] ?? const <QuestionBox>[];
    if (newLayer1.isEmpty) {
      _snack('至少保留一个题级框');
      return;
    }
    // 重裁切片：先写盘再落库（切片写不进去不改库）。
    final pageBytes = await File(pageAbs).readAsBytes();
    final first = newLayer1.first;
    final crop = await cropBoxPng(pageBytes, first);
    final sliceRel = ImportService.sliceRelative(q.id);
    final sliceAbs = AppDatabase.resolveDataPath(sliceRel);
    if (sliceAbs == null) {
      _snack('切片写不进去：数据目录不可用');
      return;
    }
    try {
      await File(sliceAbs).parent.create(recursive: true);
      await File(sliceAbs).writeAsBytes(crop.png);
    } catch (_) {
      _snack('重新框选失败：切片写不进去');
      return;
    }
    await evictCachedFileImage(sliceAbs);
    final innersFlat = <QuestionBox>[
      for (final e in result.inners.entries) ...e.value,
      ...result.standaloneInner.values.expand((v) => v),
    ];
    await widget.repo.replaceQuestionBoxes(q.id, [...newLayer1, ...innersFlat]);
    await widget.repo.save(q.copyWith(
      slicePath: sliceRel,
      sliceWidth: crop.width,
      sliceHeight: crop.height,
    ));
    widget.onChanged();
    await _load();
    _snack('已重新框选，切片已更新');
  }

  /// 取消编辑：无改动直接退出编辑；有改动显示内联确认框
  ///（HTML `.confirmbox`，在题目信息编辑表单末尾），由用户选
  /// 保存并退出 / 不保存，丢弃改动 / 继续编辑。
  void _requestCancelEdit() {
    if (!_dirty) {
      setState(() {
        _editing = false;
        _cancelAsk = false;
      });
      return;
    }
    setState(() {
      _cancelAsk = true;
      _cancelAskPop = false;
      _expanded.add('info');
    });
  }

  Future<void> _resolveCancelAsk(String choice) async {
    if (choice == 'save') {
      await _saveEdit();
    } else if (choice == 'discard') {
      setState(() {
        _editing = false;
        _dirty = false;
      });
    } else {
      setState(() => _cancelAsk = false);
      return;
    }
    final pop = _cancelAskPop;
    if (mounted) setState(() => _cancelAsk = false);
    if (pop && mounted) Navigator.of(context).pop();
  }

  /// 返回时的脏检查：编辑中且有改动 → 显示内联确认框并留在本页；
  /// 编辑中且无改动 → 先退出编辑模式，再按基线行为离开本页；
  /// 非编辑态直接离开。
  Future<bool> _onPop() async {
    if (!_editing) return true;
    if (!_dirty) {
      setState(() => _editing = false);
      return true;
    }
    setState(() {
      _cancelAsk = true;
      _cancelAskPop = true;
      _expanded.add('info');
    });
    return false;
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

  Future<void> _doDelete() async {
    final q = _q;
    if (q == null) return;
    final idx = _orderIds.indexOf(q.id);
    final nextId = idx >= 0 && idx + 1 < _orderIds.length
        ? _orderIds[idx + 1]
        : null;
    await widget.repo.delete(q);
    _orderIds.remove(q.id);
    widget.onChanged();
    if (nextId != null && nextId != q.id) {
      setState(() {
        _currentId = nextId;
        _answerVisible = false;
        _expanded.clear();
        _confirmDelete = false;
        _editing = false;
        _dirty = false;
      });
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
      _cancelAsk = false;
      _confirmDelete = false;
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
          QmButton(
            label: '取消',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: () => Navigator.of(ctx).pop(),
          ),
          QmButton(
            label: '确定',
            size: QmButtonSize.small,
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
          ),
        ],
      ),
    );
    return (value == null || value.isEmpty) ? null : value;
  }

  Future<void> _newTag() async {
    final name = await _askText('新建标签');
    if (name == null) return;
    // §6 第 4 条：标签名禁逗号与竖线。
    if (hasBannedNameSeparator(name)) {
      _snack('不能含逗号或竖线');
      return;
    }
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
              QmButton(
                label: '取消',
                variant: QmButtonVariant.plain,
                size: QmButtonSize.small,
                onPressed: () => Navigator.of(ctx).pop(),
              ),
              QmButton(
                label: '确定',
                size: QmButtonSize.small,
                onPressed: () =>
                    Navigator.of(ctx).pop(nameCtrl.text.trim()),
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
    // §6 第 4 条：自定义错因名禁逗号与竖线。
    if (hasBannedNameSeparator(name)) {
      _snack('不能含逗号或竖线');
      return;
    }
    setState(() => _editCustomTypes.add(name));
    _markDirty();
  }

  // ---------- 放大看图 ----------

  void _showZoom() {
    final q = _q;
    if (q == null) return;
    showQuestionZoomDialog(context, q, returnLabel: '题目详情');
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    if (_loading) {
      return Scaffold(
        backgroundColor: palette.surface,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final q = _q;
    if (q == null) {
      return Scaffold(
        backgroundColor: palette.surface,
        body: SingleChildScrollView(
          padding: DesignTokens.scaled(scale).contentPadding,
          child: const EmptyState(message: '这道题不存在了'),
        ),
      );
    }
    final idx = _orderIds.indexOf(q.id);
    final hasPrev = idx > 0;
    final hasNext = idx >= 0 && idx + 1 < _orderIds.length;
    final subject = _subjectOf(q.subjectId);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _onPop() && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: palette.surface,
        body: SingleChildScrollView(
          padding: DesignTokens.scaled(scale).contentPadding,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: DesignTokens.detailContentMaxWidth * scale,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildToolbar(q, idx),
                  SizedBox(height: 14 * scale),
                  _buildTitle(q, subject),
                  SizedBox(height: 8 * scale),
                  _buildSubtitle(q),
                  if (q.isArchived) ...[
                    SizedBox(height: 12 * scale),
                    const QmBanner(
                      tone: QmBannerTone.warning,
                      message: '这道题已归档：不在错题本列表里显示。点下方「恢复」可以回到错题本。',
                    ),
                  ],
                  if (!_editing && _isEmptyText(q)) ...[
                    SizedBox(height: 12 * scale),
                    const QmBanner(
                      tone: QmBannerTone.warning,
                      message:
                          '这道题还没有补充任何文字内容：答案、解析均显示「待补充」，点「待补充」或右上角「编辑」就能补。',
                    ),
                  ],
                  if (widget.imageFailed) ...[
                    SizedBox(height: 12 * scale),
                    QmBanner(
                      tone: QmBannerTone.error,
                      message:
                          '这道题的图片读取失败，下面按学科图标 + 题型显示占位，题目信息仍可查看与编辑。可返回${widget.sourceLabel}后重试，或重启应用。',
                    ),
                  ],
                  SizedBox(height: 14 * scale),
                  if (widget.imageFailed)
                    QuestionSlice(
                      question: q,
                      subject: _subjectOf(q.subjectId),
                      failed: true,
                      maxHeight: 320,
                      onTap: _showZoom,
                    )
                  else
                    QuestionSlice(
                      question: q,
                      subject: _subjectOf(q.subjectId),
                      maxHeight: 320,
                      onTap: _showZoom,
                    ),
                  SizedBox(height: 6 * scale),
                  Text(
                    '整题图（完整题目就是最小单位，二层小框不在图上标）：点一下弹出大图浮层，浮层里滚轮放大 / 缩小、按住拖动看图，点图、点关闭或按 Esc 回来',
                    style: TextStyle(
                      fontSize: DesignTokens.detailHintFontSize,
                      color: palette.muted,
                      height: DesignTokens.bodyLineHeight,
                    ),
                  ),
                  SizedBox(height: DesignTokens.detailSectionGap * scale),
                  _buildSection('answer', '答案解析', _buildAnswerSection(q)),
                  SizedBox(height: DesignTokens.detailSectionGap * scale),
                  _buildSection('info', '题目信息', _buildInfoSection(q)),
                  SizedBox(height: DesignTokens.detailSectionGap * scale),
                  _buildSection('review', '复习记录', _buildReviewSection(q)),
                  _buildWorkActs(q, hasPrev: hasPrev, hasNext: hasNext),
                  if (_confirmDelete) ...[
                    SizedBox(height: 10 * scale),
                    _buildConfirmBox(
                      q,
                      '删了就没了，确定吗？',
                      '「${subject.name} · ${sliceKindLabel(q.sliceKind)}｜${q.title}」整题图与全部补充内容一并删除，不可恢复。',
                      [
                        QmButton(
                          label: '确认删除',
                          size: QmButtonSize.small,
                          onPressed: _doDelete,
                        ),
                        QmButton(
                          label: '取消',
                          variant: QmButtonVariant.plain,
                          size: QmButtonSize.small,
                          onPressed: () =>
                              setState(() => _confirmDelete = false),
                        ),
                      ],
                    ),
                  ],
                  SizedBox(height: 8 * scale),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 工具栏：`← 返回{来源}` + `第 N / M 题 · 按{来源}当前的顺序` +
  /// 右上角 编辑 / 保存 / 取消（HTML `.toolbar`）。
  Widget _buildToolbar(Question q, int idx) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    final posTxt = idx >= 0
        ? '第 ${idx + 1} / ${_orderIds.length} 题 · 按${widget.sourceLabel}当前的顺序'
        : '';
    return Row(
      children: [
        QmButton(
          label: '返回${widget.sourceLabel}',
          leadingGlyph: QmGlyphs.back,
          variant: QmButtonVariant.plain,
          size: QmButtonSize.small,
          onPressed: () async {
            if (await _onPop() && mounted) {
              Navigator.of(context).pop();
            }
          },
        ),
        if (posTxt.isNotEmpty) ...[
          SizedBox(width: 12 * scale),
          Flexible(
            child: Text(
              posTxt,
              style: TextStyle(fontSize: 13, color: palette.muted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        const Spacer(),
        if (!_editing)
          QmButton(
            label: '编辑',
            size: QmButtonSize.small,
            onPressed: () => _enterEdit(),
          )
        else ...[
          QmButton(
            label: '保存',
            size: QmButtonSize.small,
            onPressed: _saveEdit,
          ),
          SizedBox(width: 8 * scale),
          QmButton(
            label: '取消',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: _requestCancelEdit,
          ),
        ],
      ],
    );
  }

  /// 标题：`学科 · 题型｜题名 ★`（HTML `h3.pt` 24px/800 + `.dt-star`）。
  /// 编辑态时标题换成题名输入框（基线行为保留）。
  Widget _buildTitle(Question q, Subject subject) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    if (_editing) {
      return TextField(
        controller: _titleCtrl,
        focusNode: _titleFocus,
        decoration: const InputDecoration(labelText: '题名'),
        style: TextStyle(
          fontSize: DesignTokens.pageTitleFontSize,
          fontWeight: DesignTokens.pageTitleFontWeight,
          color: palette.ink,
        ),
        onChanged: (_) => _markDirty(),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            '${subject.name} · ${sliceKindLabel(q.sliceKind)}｜${q.title}',
            style: TextStyle(
              fontSize: DesignTokens.pageTitleFontSize,
              fontWeight: DesignTokens.pageTitleFontWeight,
              color: palette.ink,
              height: 1.3,
            ),
          ),
        ),
        SizedBox(width: 8 * scale),
        Tooltip(
          message: q.isFavorite ? '已收藏（点击取消）' : '收藏',
          child: GestureDetector(
            onTap: _toggleFavorite,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 6 * scale,
                vertical: 4 * scale,
              ),
              child: Text(
                q.isFavorite ? '★' : '☆',
                style: TextStyle(
                  fontSize: DesignTokens.detailStarFontSize,
                  color: q.isFavorite
                      ? palette.paperStarOn
                      : palette.lineStrong,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 副标题（HTML `.psub`，中性表述——原型里的“选错自己承担”不抄）：
  /// 学科只读说明 + 错因汇总（每错因一个状态 pill）+ 已归档 pill。
  Widget _buildSubtitle(Question q) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    final subject = _subjectOf(q.subjectId);
    final style = TextStyle(
      fontSize: DesignTokens.bodyFontSize,
      color: palette.muted,
      height: DesignTokens.bodyLineHeight,
    );
    final bold = TextStyle(
      fontSize: DesignTokens.bodyFontSize,
      fontWeight: FontWeight.w700,
      color: palette.ink2,
      height: DesignTokens.bodyLineHeight,
    );
    final children = <Widget>[
      Text('学科：', style: style),
      Text(subject.name, style: bold),
      Text('（只显示，不能改——导入时选定，详情和整理台都不能改）', style: style),
      Text(' · 其他字段点右上角「编辑」改，点「保存」才生效', style: style),
    ];
    if (q.isArchived) {
      children.addAll([
        Text(' · ', style: style),
        QmStatusPill.tone(label: '已归档', tone: QmTone.warn),
      ]);
    }
    children.add(Text(' · ', style: style));
    if (q.allCauses.isEmpty) {
      children.add(Text('错因：还没填错误类型', style: style));
    } else {
      children.add(Text('错因：', style: style));
      for (var i = 0; i < q.allCauses.length; i++) {
        final cause = q.allCauses[i];
        final record = _records
            .where((r) => r.cause == cause)
            .firstOrNull;
        if (i > 0) children.add(Text('、', style: style));
        children.add(Text(cause, style: bold));
        children.add(Text(' · ', style: style));
        children.add(QmStatusPill.cause(_causePillStatus(record)));
      }
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 4 * scale,
      children: children,
    );
  }

  /// 错因 pill 状态：已解决且到了复查时间 → 复查；否则按记录状态，
  /// 无记录 → 待解决（HTML `detailCauseStatus`）。
  QmCauseStatus _causePillStatus(CauseRecord? record) {
    if (record == null) return QmCauseStatus.pending;
    if (record.isRecheckDue) return QmCauseStatus.recheck;
    return switch (record.status) {
      CauseStatus.pending => QmCauseStatus.pending,
      CauseStatus.inProgress => QmCauseStatus.inProgress,
      CauseStatus.solved => QmCauseStatus.solved,
    };
  }

  Widget _buildSection(String key, String title, Widget body) {
    final open = _expanded.contains(key);
    return QmFoldSection(
      variant: QmFoldVariant.detail,
      title: title,
      expanded: open,
      onToggle: () => setState(() {
        if (open) {
          _expanded.remove(key);
        } else {
          _expanded.add(key);
        }
      }),
      child: body,
    );
  }

  /// 未填字段的可点「待补充」（HTML `.status.todo.dt-miss`）：
  /// 点一下进编辑模式并聚焦对应字段。
  Widget _supplement(String field) {
    return GestureDetector(
      onTap: () => _enterEdit(focusField: field),
      child: QmStatusPill.tone(
        label: '待补充 · 点这里补',
        tone: QmTone.warn,
      ),
    );
  }

  Widget _valueText(String text) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Text(
      text,
      style: TextStyle(
        fontSize: DesignTokens.detailFieldValueFontSize,
        color: palette.ink,
        height: DesignTokens.bodyLineHeight,
      ),
    );
  }

  /// 两列表单（HTML `.form-grid`：1fr 1fr，gap 14px 20px；窄屏单列）。
  Widget _formGrid(List<_Field> fields) {
    final scale = qmScaleOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoCol = constraints.maxWidth > 560;
        final rows = <Widget>[];
        var i = 0;
        while (i < fields.length) {
          final f = fields[i];
          if (!twoCol || f.full) {
            rows.add(_fieldCell(f));
            i++;
          } else {
            final next = i + 1 < fields.length && !fields[i + 1].full
                ? fields[i + 1]
                : null;
            if (next == null) {
              rows.add(_fieldCell(f));
              i++;
            } else {
              rows.add(
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _fieldCell(f)),
                    SizedBox(width: DesignTokens.detailFormGridGapH * scale),
                    Expanded(child: _fieldCell(next)),
                  ],
                ),
              );
              i += 2;
            }
          }
          if (i < fields.length) {
            rows.add(
              SizedBox(height: DesignTokens.detailFormGridGapV * scale),
            );
          }
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        );
      },
    );
  }

  Widget _fieldCell(_Field f) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          f.label,
          style: TextStyle(
            fontSize: DesignTokens.detailFieldLabelFontSize,
            fontWeight: FontWeight.w700,
            color: palette.ink2,
            height: DesignTokens.controlLineHeight,
          ),
        ),
        SizedBox(height: 5 * scale),
        f.child,
        if (f.hint != null) ...[
          SizedBox(height: 4 * scale),
          Text(
            f.hint!,
            style: TextStyle(
              fontSize: DesignTokens.detailFieldLabelFontSize,
              color: palette.muted,
              height: DesignTokens.bodyLineHeight,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAnswerSection(Question q) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    if (_editing) {
      // HTML：编辑态答案和解析在「题目信息」的编辑表单里改，这里只留提示。
      return Text(
        '正在编辑：答案和解析在下方「题目信息」的编辑表单里改，改完点「保存」才生效。',
        style: TextStyle(
          fontSize: DesignTokens.bodySmallFontSize,
          color: palette.muted,
          height: DesignTokens.bodyLineHeight,
        ),
      );
    }
    if (!_answerVisible) {
      return Row(
        children: [
          QmButton(
            label: '看答案',
            onPressed: () => setState(() => _answerVisible = true),
          ),
          SizedBox(width: 10 * scale),
          Flexible(
            child: Text(
              '答案和解析默认藏起来，先自己想，再点开看',
              style: TextStyle(fontSize: 13, color: palette.muted),
            ),
          ),
        ],
      );
    }
    final hasAnswer = (q.answer ?? '').trim().isNotEmpty;
    final hasExplanation = (q.explanation ?? '').trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _formGrid([
          _Field('答案', hasAnswer ? _valueText(q.answer!) : _supplement('answer')),
          _Field('解析', hasExplanation ? _valueText(q.explanation!) : _supplement('explanation')),
        ]),
        SizedBox(height: 8 * scale),
        QmButton(
          label: '收起答案',
          variant: QmButtonVariant.plain,
          size: QmButtonSize.small,
          onPressed: () => setState(() => _answerVisible = false),
        ),
      ],
    );
  }

  Widget _buildInfoSection(Question q) {
    if (_editing) return _buildInfoEdit(q);
    final exam = q.examId == null
        ? null
        : _exams.firstWhere((e) => e.id == q.examId!,
            orElse: () => Exam(id: q.examId!, name: ''));
    final folders =
        _folders.where((f) => q.folderIds.contains(f.id)).toList();
    final kps = _kps.where((k) => q.knowledgePointIds.contains(k.id)).toList();
    final subject = _subjectOf(q.subjectId);
    return _formGrid([
      _Field(
        '学科（不能改）',
        _valueText(subject.name),
        hint: '导入时选定，详情和整理台都不能改',
      ),
      _Field(
        '文件夹（归类）',
        folders.isEmpty
            ? _supplement('folders')
            : _valueText(folders.map((f) => f.name).join('、')),
      ),
      _Field(
        '知识点',
        kps.isEmpty
            ? _supplement('knowledgePoints')
            : _valueText(
                kps.map((k) => '${subject.name} › ${k.name}').join('；')),
      ),
      _Field(
        '错误类型',
        q.allCauses.isEmpty
            ? _supplement('errorTypes')
            : _valueText(q.allCauses.join('、')),
      ),
      _Field(
        '标签',
        q.tags.isEmpty
            ? _supplement('tags')
            : _valueText(q.tags.map((t) => '#$t').join(' ')),
      ),
      _Field(
        '备注（笔记）',
        (q.notes ?? '').trim().isEmpty
            ? _supplement('notes')
            : _valueText(q.notes!),
      ),
      _Field(
        '来源',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _valueText(
              '来自试卷：${exam == null || exam.name.isEmpty ? '未归属试卷' : exam.name}',
            ),
            _valueText('收集时间：${_fmtDate(q.createdAt)}'),
          ],
        ),
        full: true,
      ),
      // §1.5.1：真实题可重新框选（同页其他题的框只读展示）；
      // 演示题/老题没有页图，不显示。
      if (q.pageImagePath != null)
        _Field(
          '重新框选',
          QmButton(
            label: '重新框选这道题',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: _reworkBoxes,
          ),
          hint: '框错了可以重框：同页其他题的框只读，取消不改动',
        ),
    ]);
  }

  Widget _buildInfoEdit(Question q) {
    final scale = qmScaleOf(context);
    final subjectKps =
        _kps.where((k) => k.subjectId == q.subjectId).toList();
    final subjectFolders =
        _folders.where((f) => f.subjectId == q.subjectId).toList();
    final customTypes =
        _editCustomTypes.where((t) => !ErrorTypes.fixed.contains(t));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const QmBanner(
          tone: QmBannerTone.warning,
          message:
              '正在编辑这道题：改动先不生效，点「保存」才保存；点「取消」时，有改动会先问你存不存。学科不在编辑范围里。',
        ),
        _formGrid([
          _Field(
            '学科（不能改）',
            _valueText(_subjectOf(q.subjectId).name),
            hint: '导入时选定，详情和整理台都不能改',
          ),
          _Field(
            '试卷（来源）',
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
                        DropdownMenuItem(
                          value: e.id,
                          child: Text(
                            e.date == null
                                ? e.name
                                : '${e.name}（${_fmtDate(e.date!)}）',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      setState(() => _editExamId = v);
                      _markDirty();
                    },
                  ),
                ),
                SizedBox(width: 8 * scale),
                QmButton(
                  label: '新建',
                  variant: QmButtonVariant.plain,
                  size: QmButtonSize.small,
                  onPressed: _newExam,
                ),
              ],
            ),
          ),
          _Field(
            '文件夹（归类 · 可多选，题只存一份 · 只列本题科目自己的文件夹）',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8 * scale,
                  runSpacing: 8 * scale,
                  children: [
                    for (final f in subjectFolders)
                      QmChip(
                        label: f.name,
                        selected: _editFolders.contains(f.id),
                        onTap: () {
                          setState(() {
                            if (_editFolders.contains(f.id)) {
                              _editFolders.remove(f.id);
                            } else {
                              _editFolders.add(f.id);
                            }
                          });
                          _markDirty();
                        },
                      ),
                  ],
                ),
                SizedBox(height: 8 * scale),
                QmButton(
                  label: '＋ 新建文件夹',
                  variant: QmButtonVariant.plain,
                  size: QmButtonSize.small,
                  onPressed: _newFolder,
                ),
              ],
            ),
            full: true,
            hint: '新建的文件夹只加进本题科目自己的文件夹列表、只在这一科出现，建完直接选上',
          ),
          _Field(
            '知识点（可多选、不限个数）',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8 * scale,
                  runSpacing: 8 * scale,
                  children: [
                    for (final kp in subjectKps)
                      QmChip(
                        label: '${kp.chapter} · ${kp.name}',
                        selected: _editKps.contains(kp.id),
                        onTap: () {
                          setState(() {
                            if (_editKps.contains(kp.id)) {
                              _editKps.remove(kp.id);
                            } else {
                              _editKps.add(kp.id);
                            }
                          });
                          _markDirty();
                        },
                      ),
                  ],
                ),
                SizedBox(height: 8 * scale),
                QmButton(
                  label: '＋ 新建知识点',
                  variant: QmButtonVariant.plain,
                  size: QmButtonSize.small,
                  onPressed: _newKnowledgePoint,
                ),
              ],
            ),
            full: true,
            hint:
                '在这里新建的知识点会加进「${_subjectOf(q.subjectId).name}」的知识点树（自定义一类），之后整理和筛选都能选，不用去学科管理',
          ),
          _Field(
            '错误类型（固定枚举多选 + 自定义）',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8 * scale,
                  runSpacing: 8 * scale,
                  children: [
                    for (final t in ErrorTypes.fixed)
                      QmChip(
                        label: t,
                        selected: _editErrorTypes.contains(t),
                        onTap: () {
                          setState(() {
                            if (_editErrorTypes.contains(t)) {
                              _editErrorTypes.remove(t);
                            } else {
                              _editErrorTypes.add(t);
                            }
                          });
                          _markDirty();
                        },
                      ),
                    for (final t in customTypes)
                      QmChip(
                        label: t,
                        selected: true,
                        onTap: () {
                          setState(() => _editCustomTypes.remove(t));
                          _markDirty();
                        },
                        onDelete: () {
                          setState(() => _editCustomTypes.remove(t));
                          _markDirty();
                        },
                      ),
                  ],
                ),
                SizedBox(height: 8 * scale),
                QmButton(
                  label: '＋ 新建错误类型',
                  variant: QmButtonVariant.plain,
                  size: QmButtonSize.small,
                  onPressed: _newCustomErrorType,
                ),
              ],
            ),
            full: true,
            hint: '自定义类型只跟这道题，下次编辑时还能再选',
          ),
          _Field(
            '标签（不限个数）',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8 * scale,
                  runSpacing: 8 * scale,
                  children: [
                    for (final t in _allTags)
                      QmChip(
                        label: t,
                        selected: _editTags.contains(t),
                        onTap: () {
                          setState(() {
                            if (_editTags.contains(t)) {
                              _editTags.remove(t);
                            } else {
                              _editTags.add(t);
                            }
                          });
                          _markDirty();
                        },
                      ),
                  ],
                ),
                SizedBox(height: 8 * scale),
                QmButton(
                  label: '＋ 新建标签',
                  variant: QmButtonVariant.plain,
                  size: QmButtonSize.small,
                  onPressed: _newTag,
                ),
              ],
            ),
            full: true,
          ),
          _Field(
            '答案（与解析分开）',
            TextField(
              controller: _answerCtrl,
              focusNode: _answerFocus,
              decoration: const InputDecoration(
                labelText: '答案',
                hintText: '留空保存后显示“待补充”',
              ),
              maxLines: 3,
              onChanged: (_) => _markDirty(),
            ),
          ),
          _Field(
            '解析（可以空）',
            TextField(
              controller: _explanationCtrl,
              focusNode: _explanationFocus,
              decoration: const InputDecoration(
                labelText: '解析',
                hintText: '留空保存后显示“待补充”',
              ),
              maxLines: 5,
              onChanged: (_) => _markDirty(),
            ),
          ),
          _Field(
            '备注（笔记 · 与答案、解析分开）',
            TextField(
              controller: _notesCtrl,
              focusNode: _notesFocus,
              decoration: const InputDecoration(
                labelText: '备注',
                hintText: '留空保存后显示“待补充”',
              ),
              maxLines: 3,
              onChanged: (_) => _markDirty(),
            ),
            full: true,
          ),
        ]),
        if (_cancelAsk) ...[
          SizedBox(height: 10 * scale),
          _buildConfirmBox(
            q,
            '有还没保存的改动，要保存吗？',
            '',
            [
              QmButton(
                label: '保存并退出',
                size: QmButtonSize.small,
                onPressed: () => _resolveCancelAsk('save'),
              ),
              QmButton(
                label: '不保存，丢弃改动',
                variant: QmButtonVariant.plain,
                size: QmButtonSize.small,
                onPressed: () => _resolveCancelAsk('discard'),
              ),
              QmButton(
                label: '继续编辑',
                variant: QmButtonVariant.plain,
                size: QmButtonSize.small,
                onPressed: () => _resolveCancelAsk('continue'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildReviewSection(Question q) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    // 未整理题没有加入/取消按钮（基线口径：已整理或已归档才有）；
    // 已归档的题也有按钮（归档期间不出现在复习列表里，恢复后按加入状态回来）。
    final canJoin = q.isOrganized || q.isArchived;
    final nOk = _history.where((h) => h.result == 'solved').length;
    final nBad = _history.length - nOk;
    final causeRows = <Widget>[];
    if (q.allCauses.isEmpty) {
      causeRows.add(
        Text(
          '还没填错误类型，先在上面的编辑里补上',
          style: TextStyle(
            fontSize: DesignTokens.detailFieldValueFontSize,
            color: palette.ink,
            height: DesignTokens.bodyLineHeight,
          ),
        ),
      );
    } else {
      for (final cause in q.allCauses) {
        final record =
            _records.where((r) => r.cause == cause).firstOrNull;
        final status = _causePillStatus(record);
        final recheck = record != null &&
                record.status == CauseStatus.solved &&
                record.recheckDate != null &&
                !record.isRecheckDue
            ? ' · 下次复查 ${_fmtDate(record.recheckDate!)}'
            : '';
        causeRows.add(
          Padding(
            padding: EdgeInsets.only(bottom: 4 * scale),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6 * scale,
              children: [
                Text(
                  cause,
                  style: TextStyle(
                    fontSize: DesignTokens.detailFieldValueFontSize,
                    fontWeight: FontWeight.w700,
                    color: palette.ink,
                  ),
                ),
                QmStatusPill.cause(status),
                if (recheck.isNotEmpty)
                  Text(
                    recheck,
                    style: TextStyle(
                      fontSize: DesignTokens.detailFieldValueFontSize,
                      color: palette.muted,
                    ),
                  ),
                if (record != null)
                  Text(
                    '解决次数 ${record.solvedCount}',
                    style: TextStyle(
                      fontSize: DesignTokens.bodySmallFontSize,
                      color: palette.muted,
                    ),
                  ),
              ],
            ),
          ),
        );
        if (record != null && record.remedyHistory.isNotEmpty) {
          causeRows.add(
            Padding(
              padding: EdgeInsets.only(bottom: 4 * scale),
              child: Text(
                '上次是这么补的：${record.remedyHistory.first}',
                style: TextStyle(
                  fontSize: DesignTokens.bodySmallFontSize,
                  color: palette.muted,
                  height: DesignTokens.bodyLineHeight,
                ),
              ),
            ),
          );
        }
      }
    }
    return _formGrid([
      _Field(
        '复习',
        canJoin
            ? _buildJoinReview(q)
            : Text(
                '未整理的题不能加入复习',
                style: TextStyle(
                  fontSize: DesignTokens.detailFieldValueFontSize,
                  color: palette.muted,
                  height: DesignTokens.bodyLineHeight,
                ),
              ),
      ),
      _Field('错因状态', Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: causeRows,
      )),
      _Field(
        '解决次数',
        _valueText(
          '共解决错因 ${_history.length} 次 · 自查「已解决」$nOk 次 · 「未解决 / 不确定」$nBad 次（同一错因在同一道题上两次「已解决」算已解决）',
        ),
      ),
      _Field(
        '解决记录（全部）',
        _history.isEmpty
            ? Text(
                '暂无复习记录，去复习页练一次会出现在这里',
                style: TextStyle(
                  fontSize: DesignTokens.detailRevLogFontSize,
                  color: palette.muted,
                  height: DesignTokens.bodyLineHeight,
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final h in _history)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 2 * scale),
                      child: Text(
                        '${_fmtDate(h.reviewedAt)} · ${_historyLabel(h.result)}',
                        style: TextStyle(
                          fontSize: DesignTokens.detailRevLogFontSize,
                          color: palette.muted,
                          height: DesignTokens.bodyLineHeight,
                        ),
                      ),
                    ),
                ],
              ),
      ),
    ]);
  }

  String _historyLabel(String r) => switch (r) {
        'solved' => '已解决',
        'unsolved' => '未解决',
        _ => '不确定',
      };

  /// 加入 / 取消加入复习（HTML `detailJoinRevHTML`）。
  Widget _buildJoinReview(Question q) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    if (q.reviewJoined) {
      final pending = q.allCauses.where((c) {
        final r = _records.where((x) => x.cause == c).firstOrNull;
        return r == null || r.status != CauseStatus.solved;
      }).length;
      final stTxt = pending > 0
          ? '已加入复习 · 还有 $pending 个错因未解决'
          : '已加入复习 · 错因已全部解决，满 7 天自动回来复查';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          QmStatusPill.tone(label: stTxt, tone: QmTone.info),
          SizedBox(height: 8 * scale),
          QmButton(
            label: '取消加入复习',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: _toggleReviewJoined,
          ),
          SizedBox(height: 4 * scale),
          Text(
            '取消加入不会删解决记录，再加入时接着上次解决，不用从头来',
            style: TextStyle(fontSize: 12.5, color: palette.muted),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        QmButton(
          label: '加入复习',
          size: QmButtonSize.small,
          onPressed: _toggleReviewJoined,
        ),
        SizedBox(height: 4 * scale),
        Text(
          q.allCauses.isEmpty
              ? '加入后，这道题的错因会按加入顺序出现在复习页的待解决列表里，按错因解决；这道题还没填错误类型，先在上面的编辑里补上错误类型，加入后才有可解决的错因'
              : '加入后，这道题的错因会按加入顺序出现在复习页的待解决列表里，按错因解决',
          style: TextStyle(fontSize: 12.5, color: palette.muted),
        ),
      ],
    );
  }

  /// 底部操作行（HTML `.work-acts`）：返回 / 收藏 / 归档 / 上一题 /
  /// 下一题 /（编辑态：保存 / 取消）/ 删除。本页无「开始复习」按钮。
  Widget _buildWorkActs(Question q,
      {required bool hasPrev, required bool hasNext}) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    return Container(
      margin: EdgeInsets.only(top: DesignTokens.detailWorkActsMarginTop * scale),
      padding: EdgeInsets.only(top: DesignTokens.detailWorkActsPaddingTop * scale),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.line)),
      ),
      child: Wrap(
        spacing: 10 * scale,
        runSpacing: 10 * scale,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          QmButton(
            label: '返回${widget.sourceLabel}',
            variant: QmButtonVariant.plain,
            onPressed: () async {
              if (await _onPop() && mounted) {
                Navigator.of(context).pop();
              }
            },
          ),
          QmButton(
            label: q.isFavorite ? '★ 已收藏（点击取消）' : '☆ 收藏',
            variant: QmButtonVariant.plain,
            onPressed: _toggleFavorite,
          ),
          QmButton(
            label: q.isArchived ? '恢复（取消归档）' : '归档',
            variant: QmButtonVariant.plain,
            onPressed: _toggleArchive,
          ),
          SizedBox(width: 24 * scale),
          QmButton(
            label: '上一题',
            leadingGlyph: QmGlyphs.back,
            variant: QmButtonVariant.plain,
            onPressed: hasPrev
                ? () {
                    final idx = _orderIds.indexOf(q.id);
                    _goTo(_orderIds[idx - 1]);
                  }
                : null,
          ),
          QmButton(
            label: '下一题',
            trailingGlyph: '→',
            variant: QmButtonVariant.plain,
            onPressed: hasNext
                ? () {
                    final idx = _orderIds.indexOf(q.id);
                    _goTo(_orderIds[idx + 1]);
                  }
                : null,
          ),
          if (_editing) ...[
            QmButton(
              label: '保存',
              onPressed: _saveEdit,
            ),
            QmButton(
              label: '取消',
              variant: QmButtonVariant.plain,
              onPressed: _requestCancelEdit,
            ),
          ],
          QmButton(
            label: '删除',
            variant: QmButtonVariant.plain,
            onPressed: () => setState(() => _confirmDelete = true),
          ),
        ],
      ),
    );
  }

  /// 内联确认框（HTML `.confirmbox`：err-line 边 / err-bg 底 /
  /// err-ink 字，radius 12，padding 12×14，14px 字）。
  Widget _buildConfirmBox(
      Question q, String title, String detail, List<Widget> actions) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: DesignTokens.detailConfirmPaddingH * scale,
        vertical: DesignTokens.detailConfirmPaddingV * scale,
      ),
      decoration: BoxDecoration(
        color: palette.errBg,
        border: Border.all(color: palette.errLine),
        borderRadius: BorderRadius.circular(
          DesignTokens.scaled(scale).radius,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              style: TextStyle(
                fontSize: DesignTokens.bannerFontSize,
                color: palette.errInk,
                height: DesignTokens.bodyLineHeight,
              ),
              children: [
                TextSpan(
                  text: title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (detail.isNotEmpty) TextSpan(text: detail),
              ],
            ),
          ),
          SizedBox(height: 8 * scale),
          Wrap(
            spacing: 8 * scale,
            runSpacing: 8 * scale,
            children: actions,
          ),
        ],
      ),
    );
  }
}
