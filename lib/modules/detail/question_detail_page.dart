// 题目详情（十九批 D1 相关侧栏式，板子 §2 一比一复刻）。
//
// 布局（板子 §2.1）：返回行 → 标题行 → 两栏（左栏自适应＋右栏固定
// 302px、间距 14px、右栏 sticky；≤900px 变单栏，右栏落左栏下方）。
// 左栏：题目纸面（整题图＋原图兜底行）→ 识别题干区 → 按钮行（看答案／
// 纠错／重新框选）→ 答案区（默认隐藏）→ 题目信息 panel → 复习记录
// panel → 底部操作卡片（复制图片／保存图片／导出带答案版）。
// 右栏：同错因／同知识点／同文件夹三组（取数见 DetailNotifier 的
// _refreshRelated：现有 repo.all()＋内存筛选，不新开取数口）。
//
// 保留清单（板子 §4.1，8 条全在）：题目渲染（公式走现版切片渲染、
// 原图兜底行保留）、纠错入口、答案解析（默认隐藏）、题目信息
// （学科固定、文件夹必填、知识点、错因、标签、备注、来源）、
// 复习记录（按错因的状态、自查记录、复查时间）、加入/取消加入复习、
// 收藏/归档/删除、上一题/下一题（已移页顶返回行）。
//
// 行为沿用现版，不改流程：编辑表单与底稿过期保护（stale＋SaveToken）、
// 脏检查、纠错流程、重新框选流程、DataChangeBus 守门（R12：纠错编辑器
// 开着时绝不 load()）、删除后切题／退出（B24）、最近查看只记一次
// （B29）。题目信息与复习记录 panel 默认展开，仍可点标题折叠；
// 编辑入口在题目信息 panel 底部，编辑态时标题行右侧显示保存／取消
// 代替归档／删除。
//
// 颜色只取 DesignTokens；D1 板子色值（页面背景 #F7FAFD、卡片白底、
// 纸面 #FFFFFF、答案区 #F2F8F0 等）浅色下按板子 §3，深色下回落
// 到 DesignTokens；文字符号（D3），不用图标字体；
// 三档缩放 1.00/1.15/1.30 由 app.dart TextScaler + qmScaleOf 统一做。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../data/data_change_events.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../modules/ocr/ocr_stem_section.dart';
import '../../modules/ocr/option_labels_editor.dart';
import '../../modules/ocr/question_classifier.dart';
import '../../modules/ocr/question_type_picker.dart';
import '../../services/glm_ocr_client.dart';
import '../../services/option_contents.dart';
import '../../services/question_export_service.dart';
import '../../services/stem_splitter.dart';
import '../../services/yolo_onnx_service.dart';
import '../../state/detail_notifier.dart';
import '../../state/repository_provider.dart';
import '../../theme/design_tokens.dart';
import '../../widgets/entrance_animation.dart';
import '../../widgets/question_share_card.dart';
import '../../widgets/uikit.dart';
import '../../widgets/widgets.dart';
import '../collect/collect_page.dart';

/// B8-7：题目详情页重新设计——Meng 2026-11-15 定稿 A 紧凑信息卡
///（三方向截图见 docs/ui-replication/shots/b8-detail/01~03；
/// B 学科色带、C 宽屏双栏已废弃，分支与本注释随定稿删除，仅截图留档）。
/// A 的做法：收紧间距、标题旁学科图标章、文件夹/标签/复习状态信息条、
/// 三段头上各加一行摘要、底部操作收进卡片。
/// 不改行为：三段默认折叠、答案藏在「看答案」后、学科不可改、
/// 编辑/收藏/归档/删除/上下题与加入复习逻辑原样。
/// 十九批 D1：A 的单栏布局已由两栏相关侧栏式取代（见文件头注释）；
/// 标题旁学科图标章、底部操作卡片保留，信息条与三段摘要已随 D1 撤下
///（内容进题目信息 / 复习记录 panel）。

/// 表单字段（HTML `.form-grid` 的一格）：label 12.5px/700 ink-2，
/// 值 14.5px；[hint] 是字段下的补充说明（`.ph` 12.5px muted）。
/// [help] 是收进标题旁「？」里的说明（二十三批 3 号方案）：标题括号
/// 里的补充说明太长时收进「？」，点「？」在标题下展开、悬停也可见；
/// 不传时不画「？」。
/// 编辑表单字段格数据：标题 + 控件（二十三批 2 号方案不留说明文字，
/// 3 号方案的 hint/help 已拆掉）。
class _Field {
  const _Field(
    this.label,
    this.child, {
    this.full = false,
  });

  final String label;
  final Widget child;
  final bool full;
}

/// 十九批 D1：右栏「全部 ›」/「打开列表 ›」跳搜索结果的回调
///（与 app.dart `_goWrongbookFiltered` 同款具名参数，另加 `folderId`：
/// 同文件夹入口用）。可选：不传时点跳转入口退回底层搜索结果
///（见 `_openCauseSearch` / `_openFolderSearch` 的回落）；
/// app.dart 接线后走带筛选的搜索结果。
typedef OpenWrongbookFiltered =
    void Function({
      String? subjectId,
      String? cause,
      String? knowledgePointId,
      String? folderId,
    });

class QuestionDetailPage extends StatefulWidget {
  const QuestionDetailPage({
    super.key,
    required this.repo,
    required this.questionId,
    required this.orderIds,
    this.sourceLabel = '错题本',
    this.searchContext,
    this.imageFailed = false,
    this.exportService,
    this.onGoReview,
    this.onOpenWrongbookFiltered,
  });

  final QuestionRepository repo;
  final String questionId;
  final List<String> orderIds;

  /// 进入来源（HTML `detailFromName`）：错题本 / 整理工作台 / 复习。
  /// 返回按钮与「第 N / M 题 · 按{来源}当前的顺序」用它；app.dart
  /// 按调用页传入，默认错题本。
  final String sourceLabel;

  /// 十九批 D1（A/B 工人契约）：从哪条查询来的描述（A 工人在列表行
  /// 点按处按当前筛选拼出，非空部分用 ` · ` 连接，全空则为 `全部题目`），
  /// 如 `数学 · 概念不清 · 未解决`。非 null 时返回行显示
  /// `‹ 返回搜索结果（{searchContext}，第 N/M 道）`；为 null 时沿用
  /// 现版 `返回{sourceLabel}` 文案。
  final String? searchContext;

  /// 图加载失败占位开关：应用内暂无真实图片通道，默认 false；
  /// 只供 widget 测试与截图对照验证失败占位（与 R5/R6 同款做法）。
  final bool imageFailed;

  /// B11-8：导出服务（复制 / 保存 / 带答案版共用）。生产默认 new
  /// 一个真实服务；测试注入假实现（不弹系统对话框、不碰真实剪贴板）。
  final QuestionExportService? exportService;

  /// B11-11 顺手活：复习记录空状态的“去复习”按钮回调（app.dart 接
  /// _goReview，与首页/整理/报告页同款 onGoReview）。可选：不传时
  /// 不显示按钮（旧测试构造不传，保持兼容）。
  final VoidCallback? onGoReview;

  /// 十九批 D1：右栏「全部 ›」/「打开列表 ›」跳搜索结果的回调
  ///（app.dart 接 _goWrongbookFiltered；见 [OpenWrongbookFiltered]）。
  final OpenWrongbookFiltered? onOpenWrongbookFiltered;

  @override
  @override
  State<QuestionDetailPage> createState() => _QuestionDetailPageState();
}

/// 详情页外壳：只把构造器接进来的 `repo` 与初始落点（题目 id /
/// 来源列表）交进 Riverpod 依赖图（D-35 的 `wrongbookInitialProvider`
/// 模式），其余什么都不做；内层 `_DetailView` 的 ref 才属于这层 scope。
class _QuestionDetailPageState extends State<QuestionDetailPage> {
  /// B11-8：导出服务（构造注入的优先），外壳持有、内层共用。
  late final QuestionExportService _exportService;

  @override
  void initState() {
    super.initState();
    _exportService = widget.exportService ?? QuestionExportService();
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(widget.repo),
        detailInitialProvider.overrideWithValue(
          DetailInitial(
            questionId: widget.questionId,
            orderIds: widget.orderIds,
          ),
        ),
      ],
      child: _DetailView(
        sourceLabel: widget.sourceLabel,
        searchContext: widget.searchContext,
        imageFailed: widget.imageFailed,
        exportService: _exportService,
        onGoReview: widget.onGoReview,
        onOpenWrongbookFiltered: widget.onOpenWrongbookFiltered,
      ),
    );
  }
}

/// 详情页内层：持有文本控制器与纯界面状态，业务走 `detailProvider`。
class _DetailView extends ConsumerStatefulWidget {
  const _DetailView({
    required this.sourceLabel,
    this.searchContext,
    required this.imageFailed,
    required this.exportService,
    this.onGoReview,
    this.onOpenWrongbookFiltered,
  });

  final String sourceLabel;
  final String? searchContext;
  final bool imageFailed;
  final QuestionExportService exportService;
  final VoidCallback? onGoReview;
  final OpenWrongbookFiltered? onOpenWrongbookFiltered;

  @override
  ConsumerState<_DetailView> createState() => _DetailViewState();
}

class _DetailViewState extends ConsumerState<_DetailView> {
  /// 上次见过的 `formResetKey`：变了说明 Notifier 重建了编辑表单
  /// （进编辑），控制器文本按当前题重建一次（D-40①）。
  int _seenFormKey = -1;

  bool _editing = false;

  /// 二十三批 2 号方案：知识点「＋ 添加」展开的内联选择器是否正开着
  ///（开着时列出本学科全部知识点 chip 点选；关着时只显示已选）。
  bool _kpPickerOpen = false;

  bool _dirty = false;
  bool _answerVisible = false;

  /// Win11 反馈包 5：查看态编辑器上报的选项文字暂存（只存值不落盘，
  /// 随下一次 [_saveViewOptionBlock] 一并保存）。[_pendingContentsQuestionId]
  /// 守门：只对上报时的那道题有效，串题不用（切题后旧值不带过去）。
  Map<String, String>? _pendingViewOptionContents;
  String? _pendingContentsQuestionId;

  /// B11-8：导出服务（构造注入的优先）与分享卡片的 RepaintBoundary key。
  final _shareCardKey = GlobalKey();

  /// 取消编辑时的内联确认框（HTML `.confirmbox`）是否显示；
  /// [_cancelAskPop] 表示它是由返回触发的（选“保存并退出 / 不保存”
  /// 后要离开本页），否则只是退出编辑模式。
  bool _cancelAsk = false;
  bool _cancelAskPop = false;

  // B3：删除确认已改模态弹窗（见 [_askDelete]），不再用内联确认框。

  /// 十九批 D1：题目信息与复习记录 panel 默认展开（板子直接展示内容），
  /// 仍可点标题折叠；答案区不走折叠段，由按钮行「看答案」控制显隐。
  final Set<String> _expanded = {'info', 'review'};

  /// 十九批 D1：纠错区（OcrStemSection）的定位键——按钮行「纠错
  /// （改识别文字）」点后把纠错区滚到可见（OcrStemSection 自带
  /// 「编辑题干」入口，本页不另开编辑器，只换位置）。
  final _stemSectionKey = GlobalKey();

  final _titleCtrl = TextEditingController();
  final _answerCtrl = TextEditingController();
  final _explanationCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  final _titleFocus = FocusNode();
  final _answerFocus = FocusNode();
  final _explanationFocus = FocusNode();
  final _notesFocus = FocusNode();

  /// FR-15：弹窗内建的控制器改字段持有——不能在 `showDialog` await
  /// 返回后立即 dispose：弹窗退出动画仍在重建 TextField，立即释放
  /// 会抛 “A TextEditingController was used after being disposed”
  /// （实测，见批报告）。字段持有后：下次打开同种弹窗时先释放上一个
  /// （此时上一个弹窗早已完全关闭——弹窗是模态的，函数 await 返回后
  /// 页面按钮要等退出动画结束才能再点到），页面 dispose 时释放最后一个。
  TextEditingController? _askTextCtrl;
  TextEditingController? _newKpNameCtrl;

  DetailNotifier get _notifier => ref.read(detailProvider.notifier);

  /// 当前业务状态（build 里 `ref.watch` 订阅后，构建方法内用它读值）。
  DetailState get _st => ref.read(detailProvider);

  /// 十三批 M5：活页内 OCR 事件订阅（见 [_onDataChange] 的守门规则）。
  StreamSubscription<DataChangeEvent>? _ocrSub;

  /// 纠错编辑器是否正开着、正在编哪道题（守门用：编辑中的题不刷新）。
  bool _stemEditorOpen = false;
  String? _stemEditorQuestionId;

  /// 编辑中 OCR 回来了：只取到的候选题干（不碰 Notifier 状态，
  /// 只传给 [OcrStemSection] 显示“有新的识别结果”横幅）。
  String? _candidateWhileEditing;

  @override
  void initState() {
    super.initState();
    _ocrSub = DataChangeBus.instance.stream.listen(_onDataChange);
  }

  /// 十三批 M5：活页内刷新守门（M3 报告的警告，必守）。
  ///
  /// 收到 questions 事件后：
  /// - 事件不是当前题：忽略（详情页一次只看一道题）。
  /// - 事件是当前题、且纠错编辑器正开着：绝不调 `load()`
  ///   （会重建题目对象；主编辑表单虽不受影响，但纠错编辑器
  ///   拿到的 question 对象会被换掉）；只另行取一次候选题干
  ///   （[DetailNotifier.candidateStemFor]，不改任何状态），
  ///   有候选就在编辑器里显“有新的识别结果”横幅，草稿一个字不动。
  /// - 事件是当前题、编辑器没开：调 `refreshStemStatus()` 只重读
  ///   当前题 + 任务行，不碰编辑表单值与 formResetKey。
  Future<void> _onDataChange(DataChangeEvent event) async {
    if (!event.kinds.contains(DataChangeKind.questions)) return;
    if (!mounted) return;
    final id = event.questionId;
    final currentId = ref.read(detailProvider).currentId;
    if (id != null && id != currentId) return;
    if (_stemEditorOpen && (id == null || id == _stemEditorQuestionId)) {
      final candidate = await _notifier.candidateStemFor(currentId);
      if (!mounted) return;
      if (candidate != null) {
        setState(() => _candidateWhileEditing = candidate);
      }
      return;
    }
    await _notifier.refreshStemStatus();
  }

  // ---------- 十三批 M5：纠错保存（失败时提示，编辑器不收起） ----------

  Future<bool> _saveStemEdit(String newStem) async {
    final ok = await _notifier.saveStemEdit(newStem);
    if (!mounted) return ok;
    _snack(ok ? '题干已保存' : '保存失败，请重试');
    return ok;
  }

  // 十三批 P1-1：接受的题干一律从库里 ocr_raw 包取（接受时重验证），
  // 这里收到的 candidateStem 只是预览字符串，不再传给 Notifier。
  // 十三批 P1-2 任务 e：失败时按 CandidateRejection.reason 给明确文案
  //（见 ocr_stem_section.dart 的 candidateRejectionMessage），
  // 不再一律显示通用“保存失败，请重试”。
  // Win11 反馈尾巴 1：接受时有手动图块没匹配上（已保留在末尾），只弹
  // 一句提示，不再另弹“已用新的识别结果替换”（一次接受只提示一次，
  // 不刷屏）；全部匹配上时仍是原来的成功提示。
  Future<bool> _acceptOcrCandidate(String candidateStem) async {
    final outcome = await _notifier.acceptOcrCandidateOutcome();
    if (!mounted) return outcome.accepted;
    if (outcome.reason != null) {
      _snack(candidateRejectionMessage(outcome.reason!));
    } else if (outcome.unmatchedManualIds.isNotEmpty) {
      _snack(
        '有 ${outcome.unmatchedManualIds.length} 张手动放置的图块未匹配上，已保留在末尾',
      );
    } else {
      _snack('已用新的识别结果替换');
    }
    return outcome.accepted;
  }

  /// 十三批 P1-2 任务 a：重框入队失败横幅上的“重新入队”——走同一入队
  /// 路径重试（DetailNotifier.retryOcrEnqueue）。成功后横幅消失
  ///（Notifier 清掉失败标志）；失败时横幅保留，可再点重试。
  Future<void> _retryOcrEnqueue() async {
    final ok = await _notifier.retryOcrEnqueue();
    if (!mounted) return;
    _snack(ok ? '已重新加入识别队列' : '重新入队失败，请重试');
  }

  Future<void> _dismissOcrCandidate() async {
    final ok = await _notifier.dismissOcrCandidate();
    if (!mounted) return;
    if (!ok) _snack('保存失败，请重试');
  }

  /// 十四批 M2：删除单个图块（编辑器里“删除配图”）。
  Future<bool> _deleteFigure(String figureId) async {
    final ok = await _notifier.deleteFigure(figureId);
    if (!mounted) return ok;
    _snack(ok ? '配图已删除' : '删除失败，请重试');
    return ok;
  }

  /// Win11 反馈包 3：图块换位（编辑器里拖图块落下即保存）。
  /// 成功不弹提示（每次落下都弹会刷屏）；失败时提示，编辑器回滚。
  Future<bool> _reorderFigure(
    List<String> orderedFigureIds,
    String movedFigureId,
    String movedTextAt,
  ) async {
    final ok = await _notifier.reorderFigure(
      orderedFigureIds,
      movedFigureId,
      movedTextAt,
    );
    if (!mounted) return ok;
    if (!ok) _snack('保存失败，请重试');
    return ok;
  }

  Future<void> _rerecognizeStem() async {
    final ok = await _notifier.rerecognizeCurrent();
    if (!mounted) return;
    if (ok) {
      _snack('已重新识别，稍等片刻');
    } else {
      _snack('重新识别失败：没有可识别的切片');
    }
  }

  /// Win11 反馈包 2：取消识别（同整理页 _cancelOcr）。
  Future<bool> _cancelOcr() async {
    final code = await _notifier.cancelOcrCurrent();
    if (!mounted) return code == 'cancelled' || code == 'nothing_to_cancel';
    if (code == 'cancelled') {
      _snack('已取消识别，只保留题目图片');
      return true;
    }
    if (code == 'nothing_to_cancel') return true;
    _snack('取消失败，请重试');
    return false;
  }

  @override
  void dispose() {
    _ocrSub?.cancel();
    _titleCtrl.dispose();
    _answerCtrl.dispose();
    _explanationCtrl.dispose();
    _notesCtrl.dispose();
    _askTextCtrl?.dispose();
    _newKpNameCtrl?.dispose();
    _titleFocus.dispose();
    _answerFocus.dispose();
    _explanationFocus.dispose();
    _notesFocus.dispose();
    super.dispose();
  }

  /// Notifier 重建编辑表单后（`formResetKey` 变了），把控制器文本按
  /// 当前题重建——原 `_enterEdit` 里设控制器文本的部分。
  void _syncFormFromState(DetailState st) {
    final q = st.question;
    if (q == null) return;
    if (_titleCtrl.text != q.title) _titleCtrl.text = q.title;
    if (_answerCtrl.text != (q.answer ?? '')) {
      _answerCtrl.text = q.answer ?? '';
    }
    if (_explanationCtrl.text != (q.explanation ?? '')) {
      _explanationCtrl.text = q.explanation ?? '';
    }
    if (_notesCtrl.text != (q.notes ?? '')) _notesCtrl.text = q.notes ?? '';
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
    final q = _st.question;
    if (q == null) return;
    _notifier.enterEdit();
    setState(() {
      _editing = true;
      _dirty = false;
      _cancelAsk = false;
      _kpPickerOpen = false;
      _expanded.addAll(['info', 'review']);
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

  /// Win11 反馈尾巴 2：保存时底稿过期（进编辑后自动重算 / 取消识别
  /// 改了底下内容）不直接保存，弹框让用户选：保留我的编辑（按旧底稿
  /// 强制保存）或用新内容（丢弃表单编辑、重新加载新内容）。
  /// 返回编辑是否已结束（false 时留在编辑态：框被点掉或保存失败）。
  Future<bool> _saveEdit() async {
    if (_st.editBase == null) return false;
    final outcome = await _notifier.saveEdit(
      title: _titleCtrl.text,
      answer: _answerCtrl.text,
      explanation: _explanationCtrl.text,
      notes: _notesCtrl.text,
    );
    if (!mounted) return false;
    // Stage 4：保存已发变更事件，角标由 badgeCountsProvider 刷新，
    // 本页不再回调外壳手动刷角标（onChanged 已删）。
    switch (outcome) {
      case SaveEditOutcome.saved:
        _exitEdit();
        return true;
      case SaveEditOutcome.stale:
        return _askStaleSave();
      case SaveEditOutcome.noQuestion:
        _snack('这道题不存在了');
        _exitEdit();
        return true;
      case SaveEditOutcome.failed:
        _snack('保存失败，请重试');
        return false;
      case SaveEditOutcome.noBase:
        return false;
    }
  }

  void _exitEdit() {
    setState(() {
      _editing = false;
      _dirty = false;
      _cancelAsk = false;
    });
  }

  /// 底稿过期确认框。返回编辑是否已结束：选“保留我的编辑”且强制保存
  /// 成功、或选“用新内容”时为 true；框外点掉或强制保存失败时为 false。
  Future<bool> _askStaleSave() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('内容已更新'),
        content: const Text(
          '这道题在你编辑期间变了，可能是自动重新分类或取消了识别。保留你的编辑会覆盖新内容。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('new'),
            child: const Text('用新内容'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('keep'),
            child: const Text('保留我的编辑'),
          ),
        ],
      ),
    );
    if (!mounted) return false;
    if (choice == 'keep') {
      final outcome = await _notifier.saveEdit(
        title: _titleCtrl.text,
        answer: _answerCtrl.text,
        explanation: _explanationCtrl.text,
        notes: _notesCtrl.text,
        force: true,
      );
      if (!mounted) return false;
      if (outcome == SaveEditOutcome.saved) {
        _exitEdit();
        return true;
      }
      if (outcome == SaveEditOutcome.noQuestion) {
        _snack('这道题不存在了');
        _exitEdit();
        return true;
      }
      _snack('保存失败，请重试');
      return false;
    }
    if (choice == 'new') {
      // 丢弃表单编辑：退出编辑态并重读新行；题型归属按新行原样保留。
      _exitEdit();
      await _notifier.load();
      return true;
    }
    // choice == null（框外点掉）：留在编辑态，什么都不做。
    return false;
  }

  /// 十四批 M3：查看态直接改选项标签块（「确认选项」或正确选项即时保存
  /// 时调；与题型 chip 的即时保存口径一致）。
  /// Win11 反馈包 5：选项文字随本次保存一起落盘——取编辑器上报的
  /// 最新文字（[_pendingViewOptionContents]，按题 id 守门，串题不用）；
  /// 没改过文字时取库里值，不动它。
  Future<void> _saveViewOptionBlock({
    required List<String>? labels,
    required String? correctOption,
    required bool answerReconfirmed,
    required bool confirmLabels,
  }) async {
    try {
      final q = _st.question;
      final contents = _pendingContentsQuestionId == q?.id
          ? _pendingViewOptionContents
          : q?.optionContents;
      await _notifier.saveOptionBlock(
        labels: labels,
        correctOption: correctOption,
        confirmLabels: confirmLabels,
        answerReconfirmed: answerReconfirmed,
        optionContents: contents,
      );
      if (mounted) {
        _snack(confirmLabels ? '选项已确认，可客观判分' : '已保存');
      }
    } catch (_) {
      if (mounted) _snack('保存失败，请重试');
    }
  }

  /// 十四批 M3：待重新核对 pill（点进编辑补确认；与 _supplement 同款交互）。
  Widget _pendingPill(String field, String label) {
    return GestureDetector(
      onTap: () => _enterEdit(focusField: field),
      child: QmStatusPill.tone(label: label, tone: QmTone.warn),
    );
  }

  /// §1.5.1 重新框选：加载同页全部 1 层框——目标题的框可编辑，
  /// 同页其他题的框只读（重叠校验对所有框生效）；取消丢弃本次修改。
  /// 页图缺失时不开编辑器（§6 第 6 条）。编辑器弹窗在页面开，
  /// 确认后的重裁 / 事务 / rename 在 Notifier 里（见
  /// `DetailNotifier.applyReworkBoxes`）。
  /// 十四批 M1：查看态直接改题型（点 chip → 选择器 → 立即保存）。
  Future<void> _pickQuestionType() async {
    final q = _st.question;
    if (q == null) return;
    final picked = await showQuestionTypePicker(context, q.questionType);
    if (picked == null) return; // 取消未选
    await _notifier.setQuestionType(picked.isEmpty ? null : picked);
  }

  /// 十四批 M1：编辑态改题型（只改表单值，点「保存」才落盘）。
  Future<void> _pickEditQuestionType() async {
    final picked = await showQuestionTypePicker(
      context,
      _st.editQuestionType,
    );
    if (picked == null) return; // 取消未选
    _notifier.setEditQuestionType(picked.isEmpty ? null : picked);
    _markDirty();
  }

  /// Win11 包 4：切分诊断——题型待确认时，把 splitStem 的 reason
  /// 以小字显示（为什么没自动定型）。纯函数，不持久化。
  String? _splitReason(Question q) {
    final raw = GlmOcrRawData.tryParse(q.ocrRaw);
    if (raw == null) return null;
    return '切分：${splitStem(raw.mdResults).reason}';
  }

  /// Win11 包 4：题型字段内容——芯片行（芯片 + 重新分类按钮）+
  /// 切分诊断小字。查看态与编辑态共用；[displayedType] 为当前显示
  /// 的题型值（查看态用库里题型，编辑态用编辑表单值），null 时显示
  /// 切分诊断。人工指定的题不显示重新分类按钮。
  Widget _typeFieldChild(Question q, Widget chip, String? displayedType) {
    final reason = displayedType == null ? _splitReason(q) : null;
    final showReclassify =
        q.questionTypeSource != 'manual' &&
        GlmOcrRawData.tryParse(q.ocrRaw) != null;
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            chip,
            if (showReclassify) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: _onReclassify,
                child: const Text('重新分类'),
              ),
            ],
          ],
        ),
        if (reason != null) ...[
          SizedBox(height: 4 * scale),
          Text(
            reason,
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

  /// Win11 包 4：点“重新分类”——强制重算当前题的题型，按返回码
  /// 提示结果。查看态与编辑态共用（编辑态重算后同步编辑表单的题型值）。
  Future<void> _onReclassify() async {
    final code = await _notifier.reclassifyCurrent(force: true);
    if (!mounted) return;
    final st = _st;
    final newType =
        st.editBase != null ? st.editQuestionType : st.question?.questionType;
    final message = switch (code) {
      'updated' => '已重新分类为${questionTypeDisplay(newType)}',
      'unchanged' => '仍无法自动分类，请人工指定',
      'manual' => '题型为人工指定，不自动分类',
      'no_raw' => '本题还没有识别结果，无法分类',
      'save_failed' => '保存失败，请重试',
      _ => '仍无法自动分类，请人工指定',
    };
    _snack(message);
  }

  Future<void> _reworkBoxes() async {
    final q = _st.question;
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
    final allBoxes = await _notifier.boxesForPageImage(q.pageImagePath!);
    final targets = allBoxes
        .where((b) => b.questionId == q.id && b.layer == 1)
        .toList();
    final readOnly = allBoxes
        .where((b) => b.questionId != q.id && b.layer == 1)
        .toList();
    if (!mounted) return;
    final result = await showBoxEditorDialog(
      context: context,
      fileName: q.sourcePath?.split('/').last ?? '页图',
      pageImagePath: pageAbs,
      page: page,
      pageCount: 1,
      subjectName: _st.subjectOf(q.subjectId).name,
      taskId: 'rework-${q.id}',
      mode: BoxEditorMode.rework,
      initialBoxesByPage: {page: targets},
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
    final outcome = await _notifier.applyReworkBoxes(newLayer1, pageAbs);
    if (!mounted) return;
    switch (outcome) {
      case ReworkOutcome.success:
        _snack('已重新框选，切片已更新');
      case ReworkOutcome.cropFailed:
        _snack('重新框选失败：页图读不出来/切片裁不出来，请重试');
      case ReworkOutcome.sliceUnavailable:
        _snack('切片写不进去：数据目录不可用');
      case ReworkOutcome.tmpWriteFailed:
        _snack('重新框选失败：切片写不进去，请重试，请重试，请重试，请重试');
      case ReworkOutcome.saveFailed:
        _snack('重新框选失败：保存失败，请重试');
      case ReworkOutcome.renameFailed:
        _snack('重新框选失败：切片保存失败，框已更新，请重试');
    }
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
      // 底稿过期框被点掉 / 保存失败时留在编辑态，不清确认框、不退页。
      if (!await _saveEdit()) return;
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
    if (_st.question == null) return;
    await _notifier.toggleFavorite();
  }

  Future<void> _toggleArchive() async {
    if (_st.question == null) return;
    await _notifier.toggleArchive();
  }

  /// B3：删除确认改用模态弹窗（与全项目统一）；取消编辑的确认仍是
  /// 下面的内联确认框（不是删除确认，不改）。
  Future<void> _askDelete() async {
    final q = _st.question;
    if (q == null) return;
    final subject = _st.subjectOf(q.subjectId);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删了就没了，确定吗？'),
        content: Text(
          '「${subject.name} · ${sliceKindLabel(q.sliceKind)}｜${q.title}」整题图与全部补充内容一并删除，不可恢复。',
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
    if (ok == true && mounted) await _doDelete();
  }

  Future<void> _doDelete() async {
    if (_st.question == null) return;
    final nextId = await _notifier.deleteCurrent();
    if (nextId != null) {
      if (!mounted) return;
      setState(() {
        _answerVisible = false;
        _expanded
          ..clear()
          ..addAll(['info', 'review']);
        _editing = false;
        _dirty = false;
      });
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _goTo(String id) {
    setState(() {
      _editing = false;
      _dirty = false;
      _answerVisible = false;
      _cancelAsk = false;
      _expanded
        ..clear()
        ..addAll(['info', 'review']);
    });
    _notifier.goTo(id);
  }

  Future<void> _toggleReviewJoined() async {
    if (_st.question == null) return;
    final ok = await _notifier.toggleReviewJoined();
    if (!ok) {
      _snack('先补错因');
      return;
    }
  }

  // ---------- B11-8 导出图片 ----------

  /// (a) 复制图片到剪贴板：读切片 PNG 字节，走 super_clipboard 写
  /// PNG（Windows 上按需转 DIB/DIBv5，原生应用可直接粘贴）。
  /// 无图（v1 演示题、切片文件缺失）给提示，不弹对话框。
  Future<void> _copyImage() async {
    final q = _st.question;
    if (q == null) return;
    final bytes = await widget.exportService.sliceBytes(q);
    if (bytes == null) {
      _snack('这道题没有图片可导出');
      return;
    }
    final ok = await widget.exportService.copyImageToClipboard(bytes);
    if (mounted) {
      _snack(ok ? '图片已复制到剪贴板' : '复制失败：当前环境不支持复制图片');
    }
  }

  /// (b) 保存图片为文件：file_picker 另存为对话框（PNG），取消不做
  /// 任何事；写盘失败给提示（桌面端 file_picker 只返回路径，文件
  /// 由服务自己写，与设置页备份同款做法）。
  Future<void> _saveImage() async {
    final q = _st.question;
    if (q == null) return;
    final bytes = await widget.exportService.sliceBytes(q);
    if (bytes == null) {
      _snack('这道题没有图片可导出');
      return;
    }
    final path = await widget.exportService.pickSavePath(
      dialogTitle: '保存题目图片',
      fileName: '${QuestionExportService.safeFileName(q.title)}.png',
    );
    if (path == null) return;
    final ok = await widget.exportService.saveBytesTo(path, bytes);
    if (mounted) _snack(ok ? '题目图片已保存' : '图片没存上，换个位置再试一次');
  }

  /// (c) 导出带答案版：先读切片字节，再弹预览框（题目图在上、
  /// 答案/解析在下，带学科/文件夹/错因小字）；用户在框里点“保存”，
  /// 卡片经 RepaintBoundary 转 PNG 后走同一套另存为（PNG）。
  /// 答案/解析为空时卡片显示“待补充”，不编造内容。
  Future<void> _exportShareCard() async {
    final q = _st.question;
    if (q == null) return;
    final bytes = await widget.exportService.sliceBytes(q);
    if (bytes == null) {
      _snack('这道题没有图片可导出');
      return;
    }
    if (!mounted) return;
    final subject = _st.subjectOf(q.subjectId);
    final folders = _st.folders
        .where((f) => q.folderIds.contains(f.id))
        .map((f) => f.name)
        .toList();
    final png = await showDialog<Uint8List>(
      context: context,
      builder: (ctx) => _ShareCardExportDialog(
        service: widget.exportService,
        boundaryKey: _shareCardKey,
        sliceBytes: bytes,
        title: q.title,
        subjectName: subject.name,
        folderNames: folders,
        errorTypes: q.allCauses,
        answer: q.answer,
        explanation: q.explanation,
      ),
    );
    if (png == null || !mounted) return;
    final path = await widget.exportService.pickSavePath(
      dialogTitle: '保存带答案版图片',
      fileName: '${QuestionExportService.safeFileName(q.title)}-带答案.png',
    );
    if (path == null) return;
    final ok = await widget.exportService.saveBytesTo(path, png);
    if (mounted) {
      _snack(ok ? '带答案版已保存' : '带答案版没存上，换个位置再试一次');
    }
  }

  // ---------- inline 新建 ----------

  Future<String?> _askText(String title, {String? hint}) async {
    // FR-15：字段持有（见字段注释）；开新弹窗前释放上一个。
    _askTextCtrl?.dispose();
    final ctrl = _askTextCtrl = TextEditingController();
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
    await _notifier.submitNewTag(name);
    _markDirty();
  }

  Future<void> _newFolder() async {
    final q = _st.question;
    if (q == null) return;
    final name = await _askText('新建文件夹');
    if (name == null) return;
    if (!mounted) return;
    final tops = _st.folders
        .where((f) => f.subjectId == q.subjectId && f.parentId == null)
        .toList();
    String? parentId;
    if (tops.isNotEmpty) {
      // SR-P2-26：旧代码点对话框外关闭返回 null，与选“顶层”同义，
      // 想取消却建了一个顶层文件夹。现在用可区分的返回值：'top' =
      // 顶层，'' = 点“取消”，null = 点框外关闭；后两者都是取消，不建。
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('放在哪里'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop('top'),
              child: const Text('顶层'),
            ),
            for (final f in tops)
              SimpleDialogOption(
                onPressed: () => Navigator.of(ctx).pop(f.id),
                child: Text('作为「${f.name}」的子文件夹'),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(''),
              child: const Text('取消'),
            ),
          ],
        ),
      );
      if (choice == null || choice.isEmpty) return;
      parentId = choice == 'top' ? null : choice;
    }
    final id = await _notifier.submitNewFolder(name, parentId);
    if (id == null) {
      if (mounted) _snack('已经有了这个文件夹');
      return;
    }
    _markDirty();
  }

  Future<void> _newKnowledgePoint() async {
    final q = _st.question;
    if (q == null) return;
    final chapters = _st.kps
        .where((k) => k.subjectId == q.subjectId)
        .map((k) => k.chapter)
        .toSet()
        .toList();
    String chapter = chapters.isEmpty ? '' : chapters.first;
    // FR-15：字段持有（见字段注释）；开新弹窗前释放上一个。
    _newKpNameCtrl?.dispose();
    final nameCtrl = _newKpNameCtrl = TextEditingController();
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
                      .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: (v) => setDlg(() => chapter = v ?? ''),
                ),
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: '知识点名称'),
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
                onPressed: () => Navigator.of(ctx).pop(nameCtrl.text.trim()),
              ),
            ],
          );
        },
      ),
    );
    if (name == null || name.isEmpty || chapter.isEmpty) return;
    await _notifier.submitNewKnowledgePoint(chapter, name);
    _markDirty();
  }

  Future<void> _newCustomErrorType() async {
    final name = await _askText('自定义错因');
    if (name == null) return;
    // §6 第 4 条：自定义错因名禁逗号与竖线。
    if (hasBannedNameSeparator(name)) {
      _snack('不能含逗号或竖线');
      return;
    }
    // SR-P2-27：与固定枚举同名时直接选中对应固定项，不进自定义集合
    //（否则保存时被 customNew 滤掉、错因静默消失；整理页还会造成
    // allCauses 重复）。
    final wasFixed = _notifier.addCustomType(name);
    if (wasFixed) _snack('“$name”是固定错因，已帮你选中');
    _markDirty();
  }

  // ---------- 放大看图 ----------

  void _showZoom() {
    final q = _st.question;
    if (q == null) return;
    showQuestionZoomDialog(context, q, returnLabel: '题目详情');
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(detailProvider);
    if (st.formResetKey != _seenFormKey) {
      _seenFormKey = st.formResetKey;
      // build 里不直接改控制器（会触 TextField 的监听重建），
      // 下一帧再按当前题重建；测试里 `pumpAndSettle` 后已是重建后的状态。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncFormFromState(ref.read(detailProvider));
      });
    }
    final scale = qmScaleOf(context);
    if (st.loading) {
      return Scaffold(
        backgroundColor: _d1PageBg(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final q = st.question;
    if (q == null) {
      return Scaffold(
        backgroundColor: _d1PageBg(),
        body: SingleChildScrollView(
          padding: DesignTokens.scaled(scale).contentPadding,
          child: const EmptyState(message: '这道题不存在了'),
        ),
      );
    }
    final idx = st.orderIds.indexOf(q.id);
    final hasPrev = idx > 0;
    final hasNext = idx >= 0 && idx + 1 < _st.orderIds.length;
    final subject = st.subjectOf(q.subjectId);
    // 十九批 D1：内容宽 1160；P1-2：整题图按内容高度自适应、上限 460。
    const contentMaxWidth = 1160.0;
    const imageMaxHeight = 460.0;
    // 二十二批 D-247：详情页入场上移淡入。
    return EntranceFadeSlide(
        child: PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _onPop() && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: _d1PageBg(),
        body: LayoutBuilder(
          builder: (context, constraints) {
            // 板子 §2.1：≤900px 变单栏，右栏落左栏下方；宽屏右栏固定
            // 302px、间距 14px；右栏自带滚动，滚动时不跟左栏走
            //（sticky top 12px 的同款效果：右栏常驻可见）。
            final wide = constraints.maxWidth > 900;
            final leftChildren = _buildLeftColumn(st, q, imageMaxHeight);
            final relatedPanels = _buildRelatedPanels(st);
            final Widget body;
            if (wide) {
              body = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildReturnRow(
                    q,
                    idx,
                    hasPrev: hasPrev,
                    hasNext: hasNext,
                  ),
                  SizedBox(height: 10 * scale),
                  _buildTitleRow(q, subject),
                  SizedBox(height: 12 * scale),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: leftChildren,
                            ),
                          ),
                        ),
                        if (relatedPanels.isNotEmpty) ...[
                          SizedBox(width: 14 * scale),
                          SizedBox(
                            key: const Key('detail-right-302'),
                            width: 302,
                            child: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.stretch,
                                children: relatedPanels,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              );
            } else {
              body = SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildReturnRow(
                      q,
                      idx,
                      hasPrev: hasPrev,
                      hasNext: hasNext,
                    ),
                    SizedBox(height: 10 * scale),
                    _buildTitleRow(q, subject),
                    SizedBox(height: 12 * scale),
                    ...leftChildren,
                    if (relatedPanels.isNotEmpty) ...[
                      SizedBox(height: 12 * scale),
                      ...relatedPanels,
                    ],
                  ],
                ),
              );
            }
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: contentMaxWidth * scale,
                ),
                child: Padding(
                  padding: DesignTokens.scaled(scale).contentPadding,
                  child: body,
                ),
              ),
            );
          },
        ),
      ),
    ));
  }

  /// 十九批 D1 左栏（自上而下）：横幅 → 题目纸面 → 重框入队失败横幅 →
  /// 识别题干区 → 按钮行 → 答案区 → 题目信息 panel → 复习记录 panel →
  /// 底部操作卡片。
  List<Widget> _buildLeftColumn(
    DetailState st,
    Question q,
    double imageMaxHeight,
  ) {
    final scale = qmScaleOf(context);
    return [
      if (q.isArchived) ...[
        const QmBanner(
          tone: QmBannerTone.warning,
          message: '这道题已归档：不在错题本列表里显示。点标题行「恢复」可以回到错题本。',
        ),
        SizedBox(height: 12 * scale),
      ],
      if (!_editing && _isEmptyText(q)) ...[
        const QmBanner(
          tone: QmBannerTone.warning,
          message:
              '这道题还没有补充任何文字内容：答案、解析均显示「待补充」，点「待补充」或题目信息里的「编辑」就能补。',
        ),
        SizedBox(height: 12 * scale),
      ],
      if (widget.imageFailed) ...[
        QmBanner(
          tone: QmBannerTone.error,
          message:
              '这道题的图片读取失败，下面按学科图标 + 题型显示占位，题目信息仍可查看与编辑。可返回${widget.sourceLabel}后重试，或重启应用。',
        ),
        SizedBox(height: 12 * scale),
      ],
      _buildPaper(q, imageMaxHeight),
      // 十三批 P1-2 任务 a：重框成功但 OCR 未入队时的横幅——
      // 框选结果已保留（题图与切片都是新的），只说明 OCR
      // 没排上，并给“重新入队”重试入口。不要让页面把
      // “已重新框选，切片已更新”等同于“OCR 已排队”。
      if (st.ocrEnqueueFailed) ...[
        SizedBox(height: 12 * scale),
        _ocrEnqueueFailedBanner(scale),
      ],
      SizedBox(height: 12 * scale),
      // 十三批 M5：识别题干区——在题目纸面正下方（按钮行之上），
      // 长期可用，与整理工作台共用同一套 [OcrStemSection]。
      // Key 按题 id：换题时编辑器收起、草稿不跨题。
      Container(
        key: _stemSectionKey,
        child: OcrStemSection(
          key: ValueKey('ocr-stem-${q.id}'),
          question: q,
          jobs: st.ocrJobs,
          hasApiKey: st.hasOcrApiKey,
          candidateStemOverride: _stemEditorQuestionId == q.id
              ? _candidateWhileEditing
              : null,
          onSaveEdited: _saveStemEdit,
          onAcceptCandidate: _acceptOcrCandidate,
          onDismissCandidate: _dismissOcrCandidate,
          onRerecognize: _rerecognizeStem,
          onCancelOcr: _cancelOcr,
          onDeleteFigure: _deleteFigure,
          onReorderFigure: _reorderFigure,
          onEditingChanged: (open) {
            setState(() {
              _stemEditorOpen = open;
              _stemEditorQuestionId = open ? q.id : null;
              if (!open) _candidateWhileEditing = null;
            });
          },
        ),
      ),
      if (!_editing) ...[
        SizedBox(height: 10 * scale),
        _buildButtonRow(q),
      ],
      ..._answerArea(q),
      SizedBox(height: 12 * scale),
      _buildPanel(
        'info',
        '题目信息',
        _buildInfoSection(q),
        showEditingBadge: _editing,
      ),
      SizedBox(height: 12 * scale),
      _buildPanel('review', '复习记录', _buildReviewSection(q)),
      _buildWorkActs(q),
      SizedBox(height: 8 * scale),
    ];
  }

  /// 十三批 P1-2 任务 a：重框入队失败横幅——“题目已更新，OCR 未入队”
  /// + “重新入队”按钮（调 [_retryOcrEnqueue]，成功后横幅消失）。
  /// 只有重框入队失败时才出现（[DetailState.ocrEnqueueFailed]），
  /// 入队成功 / 切到别的题时不出现。
  Widget _ocrEnqueueFailedBanner(double scale) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Container(
      key: const Key('ocr-enqueue-failed-banner'),
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: 12 * scale,
        vertical: 10 * scale,
      ),
      decoration: BoxDecoration(
        color: palette.surface2,
        border: Border.all(color: palette.errInk),
        borderRadius: BorderRadius.circular(8 * scale),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '题目已更新，OCR 未入队',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: palette.ink,
              ),
            ),
          ),
          QmButton(
            label: '重新入队',
            size: QmButtonSize.small,
            onPressed: _retryOcrEnqueue,
          ),
        ],
      ),
    );
  }

  // ---------- 十九批 D1：板子色值（浅色按板子 §3，深色回落到
  // DesignTokens，避免浅色卡片在深色下不可读） ----------

  AppPalette get _d1Palette =>
      DesignTokens.of(Theme.of(context).brightness);

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  /// 页面背景：板子 `--bg` #F7FAFD。
  Color _d1PageBg() =>
      _isDark ? _d1Palette.background : const Color(0xFFF7FAFD);

  /// 卡片白底（板子 `--card` #FFFFFE）。
  Color _d1CardBg() => _isDark ? _d1Palette.surface : Colors.white;

  /// 卡片边框（板子 `--line` #E3E8F0）。
  Color _d1CardLine() =>
      _isDark ? _d1Palette.line : const Color(0xFFE3E8F0);

  /// 题目纸面底：板子 `--paper` #FFFFFF（与 DesignTokens.paper
  /// 浅色值一致）。
  Color _d1PaperBg() => _d1Palette.paper;

  /// 纸面边框（token paperLine）。
  Color _d1PaperLine() => _d1Palette.paperLine;

  /// 答案区底 #F2F8F0 / 边 #CBE5C4。
  Color _d1AnswerBg() =>
      _isDark ? _d1Palette.surface2 : const Color(0xFFF2F8F0);
  Color _d1AnswerLine() =>
      _isDark ? _d1Palette.line : const Color(0xFFCBE5C4);

  /// 原图兜底行：底 #EFF4FA / 边 #DCE4EF / 字 #5F718E。
  Color _d1FigNoteBg() =>
      _isDark ? _d1Palette.surface2 : const Color(0xFFEFF4FA);
  Color _d1FigNoteLine() =>
      _isDark ? _d1Palette.line : const Color(0xFFDCE4EF);
  Color _d1FigNoteInk() =>
      _isDark ? _d1Palette.muted : const Color(0xFF5F718E);

  /// 板子主色 #2E7CF6（链接 / 跳转文字）。
  Color _d1Link() => _isDark ? _d1Palette.accent : const Color(0xFF2E7CF6);

  /// 相关行悬停 #F1F5FA / 分隔线 #EEF2F7。
  Color _d1HoverBg() =>
      _isDark ? _d1Palette.surface2 : const Color(0xFFF1F5FA);
  Color _d1RelDivider() =>
      _isDark ? _d1Palette.line : const Color(0xFFEEF2F7);

  /// 题目整体错因状态（与 Notifier 的 [overallCauseStatusLabel]
  /// 同口径，转现版 [QmStatusPill.cause] 显示）。
  QmCauseStatus _overallStatus(Question q) {
    return switch (overallCauseStatusLabel(q, _st.records)) {
      '待复查' => QmCauseStatus.recheck,
      '已解决' => QmCauseStatus.solved,
      '解决中' => QmCauseStatus.inProgress,
      _ => QmCauseStatus.pending,
    };
  }

  /// D1 panel（题目信息 / 复习记录 / 右栏三组共用样式）：
  /// 白底、#E3E8F0 边、圆角 10px、内边距 14px；标题 14.5px 700。
  /// [foldKey] 非空时标题可点折叠（左栏两 panel 用，右栏不用）。
  Widget _buildPanelCard({
    required Widget header,
    required Widget body,
    Key? key,
  }) {
    final scale = qmScaleOf(context);
    return Container(
      key: key,
      width: double.infinity,
      decoration: BoxDecoration(
        color: _d1CardBg(),
        border: Border.all(color: _d1CardLine()),
        borderRadius: BorderRadius.circular(10 * scale),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [header, body],
      ),
    );
  }

  /// 左栏 panel：标题行可点折叠，默认展开（见 [_expanded]）。
  /// [showEditingBadge]：编辑态时标题后挂「编辑中」pill +「改动保存后
  /// 才生效」（二十三批 2 号方案板子同款；只有题目信息 panel 用）。
  Widget _buildPanel(
    String key,
    String title,
    Widget body, {
    bool showEditingBadge = false,
  }) {
    final open = _expanded.contains(key);
    final scale = qmScaleOf(context);
    final palette = _d1Palette;
    return _buildPanelCard(
      key: Key('detail-panel-$key'),
      header: InkWell(
        onTap: () => setState(() {
          if (open) {
            _expanded.remove(key);
          } else {
            _expanded.add(key);
          }
        }),
        borderRadius: BorderRadius.circular(10 * scale),
        child: Padding(
          padding: EdgeInsets.all(14 * scale),
          child: Row(
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: palette.ink,
                ),
              ),
              if (showEditingBadge) ...[
                SizedBox(width: 8 * scale),
                QmStatusPill.tone(label: '编辑中', tone: QmTone.info),
                SizedBox(width: 8 * scale),
                Text(
                  '改动保存后才生效',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: palette.muted,
                    height: DesignTokens.bodyLineHeight,
                  ),
                ),
              ],
              const Spacer(),
              Text(
                open ? '▾' : '▸',
                style: TextStyle(fontSize: 13, color: palette.muted),
              ),
            ],
          ),
        ),
      ),
      body: open
          ? Padding(
              padding: EdgeInsets.fromLTRB(
                14 * scale,
                0,
                14 * scale,
                14 * scale,
              ),
              child: body,
            )
          : const SizedBox.shrink(),
    );
  }

  /// 板子 kv 行（`.kv`：64px 标签列 + 1fr 值列，13.5px，间距 5px）。
  Widget _kvRow(String label, Widget value) {
    final palette = _d1Palette;
    final scale = qmScaleOf(context);
    return Padding(
      padding: EdgeInsets.only(bottom: 5 * scale),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                color: palette.muted,
                height: DesignTokens.bodyLineHeight,
              ),
            ),
          ),
          SizedBox(width: 10 * scale),
          Expanded(child: value),
        ],
      ),
    );
  }

  /// kv 值文字（13.5px）。
  Widget _kvText(String text) {
    final palette = _d1Palette;
    return Text(
      text,
      style: TextStyle(
        fontSize: 13.5,
        color: palette.ink,
        height: DesignTokens.bodyLineHeight,
      ),
    );
  }

  /// 十九批 D1：题目纸面（板子 §2.4.1）——纸面底、paperLine 边、圆角
  /// 8px、内边距 14×16；里面是现版整题图（题干＋选项行、公式走现版
  /// 切片渲染）＋原图兜底行。
  /// P1-2：题图区按内容高度自适应、上限 460 不变。QuestionSlice 的占位
  /// Center 会撑满有界高度约束（演示题小图只占 460 盒子约 15%，首屏近半
  /// 米色空白），包一层 IntrinsicHeight 让盒子高度取内容固有高度；大图
  /// 仍由 QuestionSlice 自身的 maxHeight 460 限高。
  Widget _buildPaper(Question q, double imageMaxHeight) {
    final scale = qmScaleOf(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: 16 * scale,
        vertical: 14 * scale,
      ),
      decoration: BoxDecoration(
        color: _d1PaperBg(),
        border: Border.all(color: _d1PaperLine()),
        borderRadius: BorderRadius.circular(8 * scale),
        boxShadow: const [
          BoxShadow(
            offset: Offset(0, 1),
            blurRadius: 3,
            color: Color.fromRGBO(23, 35, 59, 0.08),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IntrinsicHeight(
            child: widget.imageFailed
                ? QuestionSlice(
                    question: q,
                    subject: _st.subjectOf(q.subjectId),
                    failed: true,
                    maxHeight: imageMaxHeight,
                    onTap: _showZoom,
                  )
                : QuestionSlice(
                    question: q,
                    subject: _st.subjectOf(q.subjectId),
                    maxHeight: imageMaxHeight,
                    onTap: _showZoom,
                  ),
          ),
          SizedBox(height: 10 * scale),
          _buildFigNote(),
        ],
      ),
    );
  }

  /// 原图兜底行（板子 §2.4.1 `.fig-note`）：「点此查看原图」走现版
  /// 放大查看（[_showZoom]）；「识别纠错入口 ›」滚到纸面正下方的
  /// 纠错区（OcrStemSection 自带「编辑题干」入口）。
  /// 注：Flutter 边框画不出虚线，这里用同色实线边（与板子色值一致，
  /// 线型有出入）。
  Widget _buildFigNote() {
    final scale = qmScaleOf(context);
    final style = TextStyle(
      fontSize: 12.5,
      color: _d1FigNoteInk(),
      height: DesignTokens.bodyLineHeight,
    );
    final linkStyle = style.copyWith(
      color: _d1Link(),
      fontWeight: FontWeight.w600,
    );
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: 12 * scale,
        vertical: 8 * scale,
      ),
      decoration: BoxDecoration(
        color: _d1FigNoteBg(),
        border: Border.all(color: _d1FigNoteLine()),
        borderRadius: BorderRadius.circular(8 * scale),
      ),
      child: Wrap(
        children: [
          Text('原图兜底：这道题有拍照原图，', style: style),
          GestureDetector(
            onTap: _showZoom,
            child: Text('点此查看原图', style: linkStyle),
          ),
          Text('（识别有误时以原图为准）· ', style: style),
          GestureDetector(
            onTap: _scrollToStemSection,
            child: Text('识别纠错入口 ›', style: linkStyle),
          ),
        ],
      ),
    );
  }

  /// 按钮行「纠错（改识别文字）」：把纠错区滚到可见（纠错编辑器
  /// 本身由 OcrStemSection 自带的「编辑题干」打开）。
  void _scrollToStemSection() {
    final ctx = _stemSectionKey.currentContext;
    if (ctx != null) {
      unawaited(
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 300),
        ),
      );
    }
  }

  /// 纸面下方按钮行（板子 §2.4.2）：看答案／纠错（改识别文字）／
  /// 重新框选，ghost 样式；编辑态不显示（编辑时答案在题目信息表单里改）。
  /// 重新框选只在有页图的题上出现（现版口径）。
  Widget _buildButtonRow(Question q) {
    final scale = qmScaleOf(context);
    return Wrap(
      spacing: 8 * scale,
      runSpacing: 8 * scale,
      children: [
        QmButton(
          label: _answerVisible ? '收起答案' : '看答案',
          variant: QmButtonVariant.plain,
          size: QmButtonSize.small,
          onPressed: () => setState(() => _answerVisible = !_answerVisible),
        ),
        QmButton(
          label: '纠错（改识别文字）',
          variant: QmButtonVariant.plain,
          size: QmButtonSize.small,
          onPressed: _scrollToStemSection,
        ),
        if (q.pageImagePath != null)
          QmButton(
            label: '重新框选',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: _reworkBoxes,
          ),
      ],
    );
  }

  /// 答案区：编辑态只留提示（答案在题目信息表单里改）；查看态默认
  /// 隐藏，点「看答案」后出现（#F2F8F0 底、#CBE5C4 边、圆角 8px）。
  List<Widget> _answerArea(Question q) {
    final scale = qmScaleOf(context);
    if (_editing) {
      return [
        SizedBox(height: 10 * scale),
        _buildAnswerSection(q),
      ];
    }
    if (!_answerVisible) return const [];
    return [
      SizedBox(height: 10 * scale),
      Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          horizontal: 12 * scale,
          vertical: 10 * scale,
        ),
        decoration: BoxDecoration(
          color: _d1AnswerBg(),
          border: Border.all(color: _d1AnswerLine()),
          borderRadius: BorderRadius.circular(8 * scale),
        ),
        child: _buildAnswerSection(q),
      ),
    ];
  }

  /// 十九批 D1 返回行（板子 §2.2）：左为返回链接，右为上一题 / 下一题。
  ///
  /// searchContext 非 null（从列表查询进来，A 工人拼好传进来）：
  /// `‹ 返回搜索结果（{searchContext}，第 N/M 道）`；
  /// 为 null 时沿用现版 `返回{sourceLabel}`＋`第 N / M 题 ·
  /// 按{来源}当前的顺序`。上一题 / 下一题按 orderIds 走（现版
  /// _goTo 逻辑不变），首末禁用。
  Widget _buildReturnRow(
    Question q,
    int idx, {
    required bool hasPrev,
    required bool hasNext,
  }) {
    final palette = _d1Palette;
    final scale = qmScaleOf(context);
    final ctx = widget.searchContext;
    Future<void> pop() async {
      if (await _onPop() && mounted) Navigator.of(context).pop();
    }

    return Row(
      children: [
        if (ctx != null)
          Flexible(
            child: GestureDetector(
              key: const Key('detail-back'),
              onTap: pop,
              child: Text(
                idx >= 0
                    ? '‹ 返回搜索结果（$ctx，第 ${idx + 1}/${_st.orderIds.length} 道）'
                    : '‹ 返回搜索结果（$ctx）',
                style: TextStyle(
                  fontSize: 13.5,
                  color: _d1Link(),
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
        else ...[
          QmButton(
            label: '返回${widget.sourceLabel}',
            leadingGlyph: QmGlyphs.back,
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: pop,
          ),
          if (idx >= 0) ...[
            SizedBox(width: 12 * scale),
            Flexible(
              child: Text(
                '第 ${idx + 1} / ${_st.orderIds.length} 题 · 按${widget.sourceLabel}当前的顺序',
                style: TextStyle(fontSize: 13, color: palette.muted),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
        const Spacer(),
        _posButton(
          '上一题 ↑',
          const Key('detail-prev'),
          hasPrev,
          hasPrev
              ? () {
                  final i = _st.orderIds.indexOf(q.id);
                  _goTo(_st.orderIds[i - 1]);
                }
              : null,
        ),
        Text(' · ', style: TextStyle(fontSize: 13, color: palette.muted)),
        _posButton(
          '下一题 ↓',
          const Key('detail-next'),
          hasNext,
          hasNext
              ? () {
                  final i = _st.orderIds.indexOf(q.id);
                  _goTo(_st.orderIds[i + 1]);
                }
              : null,
        ),
      ],
    );
  }

  /// 返回行右侧的上一题 / 下一题（板子 `.pos`：13px 灰字，无按钮样式；
  /// 禁用时半透明、点按无反应）。
  Widget _posButton(
    String label,
    Key key,
    bool enabled,
    VoidCallback? onTap,
  ) {
    final palette = _d1Palette;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: GestureDetector(
        key: key,
        onTap: onTap,
        child: Text(
          label,
          style: TextStyle(fontSize: 13, color: palette.muted),
        ),
      ),
    );
  }

  /// B8-7：学科图标章（学科色底 + 白字单字图标，如「数」），放标题前，
  /// 让学科色在标题行就出现；[size] 是章的边长（A/C 34、B 48）。
  Widget _subjectBadge(Subject subject, double size) {
    final scale = qmScaleOf(context);
    return Container(
      width: size * scale,
      height: size * scale,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: subject.color,
        borderRadius: BorderRadius.circular(10 * scale),
      ),
      child: Text(
        subject.icon,
        style: TextStyle(
          fontSize: size * 0.55 * scale,
          fontWeight: FontWeight.w800,
          color: Colors.white,
          height: 1,
        ),
      ),
    );
  }

  /// 十九批 D1 标题行（板子 §2.3 `.dtitle`）：学科 chip（34×34）＋
  /// 标题（18px 700）＋状态 pill（现版状态口径）＋收藏星 ★＋
  /// 右侧归档／删除（红字）；编辑态时右侧显示保存／取消代替归档／
  /// 删除，标题换成题名输入框（基线行为保留）。
  Widget _buildTitleRow(Question q, Subject subject) {
    final palette = _d1Palette;
    final scale = qmScaleOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _subjectBadge(subject, 34),
        SizedBox(width: 10 * scale),
        if (_editing)
          Expanded(
            child: TextField(
              controller: _titleCtrl,
              focusNode: _titleFocus,
              decoration: const InputDecoration(labelText: '题名'),
              style: TextStyle(
                fontSize: DesignTokens.pageTitleFontSize,
                fontWeight: DesignTokens.pageTitleFontWeight,
                color: palette.ink,
              ),
              onChanged: (_) => _markDirty(),
            ),
          )
        else ...[
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: 5 * scale),
              child: Text(
                q.title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: palette.ink,
                  height: 1.3,
                ),
              ),
            ),
          ),
          SizedBox(width: 8 * scale),
          Padding(
            padding: EdgeInsets.only(top: 6 * scale),
            child: QmStatusPill.cause(_overallStatus(q)),
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
        SizedBox(width: 8 * scale),
        // 二十三批 2 号方案：编辑态的保存/取消不在标题行，改放左主列
        // 底部（板子同款位置）；标题行编辑态只留标题 + 星标。
        if (!_editing) ...[
          QmButton(
            label: q.isArchived ? '恢复' : '归档',
            variant: QmButtonVariant.plain,
            size: QmButtonSize.small,
            onPressed: _toggleArchive,
          ),
          SizedBox(width: 8 * scale),
          QmButton(
            label: '删除',
            variant: QmButtonVariant.danger,
            size: QmButtonSize.small,
            onPressed: _askDelete,
          ),
        ],
      ],
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

  /// 未填字段的可点「待补充」（HTML `.status.todo.dt-miss`）：
  /// 点一下进编辑模式并聚焦对应字段。
  Widget _supplement(String field) {
    return GestureDetector(
      onTap: () => _enterEdit(focusField: field),
      child: QmStatusPill.tone(label: '待补充 · 点这里补', tone: QmTone.warn),
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
            rows.add(SizedBox(height: DesignTokens.detailFormGridGapV * scale));
          }
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        );
      },
    );
  }

  /// 编辑表单字段格（二十三批 2 号方案）：标题 + 控件，不留说明文字
  ///（3 号方案的「？」展开与长 hint 已拆掉；_formGrid 的查看态答案
  /// 区也走这里，同样只有标题 + 控件）。
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
      ],
    );
  }

  /// 答案区内容：编辑态只留提示（答案和解析在题目信息表单里改）；
  /// 查看态由按钮行「看答案／收起答案」控制显隐（[_answerArea] 包
  /// 绿底容器、[_answerVisible] 为 false 时不渲染本段）。
  Widget _buildAnswerSection(Question q) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
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
    if (!_answerVisible) return const SizedBox.shrink();
    // 十四批 M3：答案与解析分别展示、分别标状态——待重新核对时显示
    // “标准答案待重新核对”/“解析待重新核对”，不显示旧文本为有效答案
    //（effective* 在待核对时一律返回 null）。
    final hasAnswer = (q.effectiveAnswer ?? '').trim().isNotEmpty;
    final hasExplanation = (q.effectiveExplanation ?? '').trim().isNotEmpty;
    return _formGrid([
      _Field(
        '答案',
        q.answerPendingRecheck
            ? _pendingPill('answer', '标准答案待重新核对 · 点这里确认')
            : (hasAnswer
                ? _valueText(q.effectiveAnswer!)
                : _supplement('answer')),
      ),
      _Field(
        '解析',
        q.answerPendingRecheck
            ? _pendingPill('explanation', '解析待重新核对 · 点这里确认')
            : (hasExplanation
                ? _valueText(q.effectiveExplanation!)
                : _supplement('explanation')),
      ),
    ]);
  }

  /// WP-A #1 收尾：切分器检测到的选项字母序列（见
  /// [StemSplitResult.optionLabels]），只作 [AnswerOptionEditor]
  /// 的初始值；无 OCR 原文或未切出序列时返回 null（编辑器走 A–D
  /// 兜底）。纯函数，不持久化。
  List<String>? _detectedOptionLabels(Question q) {
    final raw = GlmOcrRawData.tryParse(q.ocrRaw);
    if (raw == null) return null;
    return splitStem(raw.mdResults).optionLabels;
  }

  /// Win11 反馈包 5：切分器检测到的选项文字（统一解析器，与回填
  /// 同一份规则），只作 [AnswerOptionEditor] 的初始值。切分失败、
  /// 判断题、无 OCR 原文时返回 null（不显示、不硬猜）。纯函数，
  /// 不持久化。
  Map<String, String>? _detectedOptionContents(Question q) {
    if (q.questionType == 'true_false') return null;
    final raw = GlmOcrRawData.tryParse(q.ocrRaw);
    if (raw == null) return null;
    final split = splitStem(raw.mdResults);
    if (split.status != StemSplitStatus.autoSplit) return null;
    final parsed = parseOptionContents(raw.mdResults, split);
    return parsed.contents.isEmpty ? null : parsed.contents;
  }

  /// Win11 反馈包 5：选项文字显示门——只有切分成功（自动切分）时
  /// 才显示已存的选项文字；切分失败时传 null（选项文字已在题干里，
  /// 选项区不重复显示）；判断题不显示。
  Map<String, String>? _optionContentsForDisplay(
    Question q,
    Map<String, String>? formContents,
  ) {
    if (q.questionType == 'true_false') return null;
    if (q.ocrSplitStatus != OcrSplitStatus.autoSegmented) return null;
    return formContents;
  }

  Widget _buildInfoSection(Question q) {
    if (_editing) return _buildInfoEdit(q);
    final exam = q.examId == null
        ? null
        : _st.exams.firstWhere(
            (e) => e.id == q.examId!,
            orElse: () => Exam(id: q.examId!, name: ''),
          );
    final folders = _st.folders
        .where((f) => q.folderIds.contains(f.id))
        .toList();
    final kps = _st.kps
        .where((k) => q.knowledgePointIds.contains(k.id))
        .toList();
    final subject = _st.subjectOf(q.subjectId);
    // 十九批 D1：查看态按板子 kv 表排（学科／文件夹／题型／知识点／
    // 错因／标签／来源／备注；题型是现版行为，插在文件夹后）。
    final kv = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _kvRow(
          '学科',
          Row(
            children: [
              Flexible(child: _kvText(subject.name)),
              Text(
                '（导入时已选定，不可更改）',
                style: TextStyle(
                  fontSize: 12.5,
                  color: _d1Palette.muted,
                  height: DesignTokens.bodyLineHeight,
                ),
              ),
            ],
          ),
        ),
        _kvRow(
          '文件夹',
          folders.isEmpty
              ? _supplement('folders')
              : _kvText(folders.map((f) => f.name).join('、')),
        ),
        // 十四批 M1：题型 chip（查看态点开直接改，立即保存）。
        // Win11 包 4：芯片行 + 重新分类按钮 + 切分诊断小字。
        _kvRow(
          '题型',
          _typeFieldChild(
            q,
            questionTypeChip(type: q.questionType, onTap: _pickQuestionType),
            q.questionType,
          ),
        ),
        _kvRow(
          '知识点',
          kps.isEmpty
              ? _supplement('knowledgePoints')
              : _kvText(
                  // FR-16：信息区与编辑芯片同款，补章节（学科 › 章节 · 知识点名）；
                  // 章节为空时回落到只有知识点名，不留悬空的“·”。
                  kps
                      .map(
                        (k) => k.chapter.isEmpty
                            ? '${subject.name} › ${k.name}'
                            : '${subject.name} › ${k.chapter} · ${k.name}',
                      )
                      .join('；'),
                ),
        ),
        _kvRow(
          '错因',
          q.allCauses.isEmpty
              ? _supplement('errorTypes')
              : _kvText(q.allCauses.join('、')),
        ),
        _kvRow(
          '标签',
          q.tags.isEmpty
              ? _supplement('tags')
              : _kvText(q.tags.map((t) => '#$t').join(' ')),
        ),
        _kvRow(
          '来源',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kvText(
                '来自试卷：${exam == null || exam.name.isEmpty ? '未归属试卷' : exam.name}',
              ),
              _kvText('收集时间：${_fmtDate(q.createdAt)}'),
            ],
          ),
        ),
        _kvRow(
          '备注',
          (q.notes ?? '').trim().isEmpty
              ? _supplement('notes')
              : _kvText(q.notes!),
        ),
      ],
    );
    // 十四批 M3：选项标签确认编辑器（查看态，题型区；正确选项点选
    // 立即保存，标签改动点「确认选项」保存——与题型 chip 的即时保存
    // 口径一致；复习页“补全标签”跳转落在这里）。
    // WP-A #1 收尾：detectedOptionLabels 把切分器检测到的选项序列
    // 作初始值（optionLabels 为空时才算）。查看态无答案文本框，
    // 不接 onMultiSelectionChanged（多选点选只活在编辑器内）。
    final scale = qmScaleOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        kv,
        SizedBox(height: 12 * scale),
        AnswerOptionEditor(
          key: ValueKey(q.id),
          questionId: q.id,
          questionType: q.questionType,
          optionLabels: q.optionLabels,
          storedOptionLabels: q.optionLabels,
          detectedOptionLabels: q.optionLabels == null
              ? _detectedOptionLabels(q)
              : null,
          correctOption: q.correctOption,
          storedCorrectOption: q.correctOption,
          answerPendingRecheck: q.answerPendingRecheck,
          hadOldAnswer:
              (q.answer ?? '').trim().isNotEmpty ||
              (q.explanation ?? '').trim().isNotEmpty,
          answerReconfirmed: false,
          // Win11 反馈包 5：选项文字（仅切分成功时显示；切分失败时
          // 传 null，选项文字已在题干里，不重复显示）。上报的文字
          // 只暂存，随下一次即时保存一并落盘。
          optionContents: _optionContentsForDisplay(q, q.optionContents),
          detectedOptionContents: q.optionContents == null
              ? _detectedOptionContents(q)
              : null,
          onOptionContentsChanged: (contents) {
            _pendingViewOptionContents = contents;
            _pendingContentsQuestionId = q.id;
          },
          onLabelsChanged: (_) {},
          onCorrectOptionChanged: (_) {},
          onAnswerReconfirmedChanged: (_) {},
          onConfirm: ({
            required List<String>? labels,
            required String? correctOption,
            required bool answerReconfirmed,
            required bool confirmLabels,
          }) =>
              _saveViewOptionBlock(
            labels: labels,
            correctOption: correctOption,
            answerReconfirmed: answerReconfirmed,
            confirmLabels: confirmLabels,
          ),
          correctOptionSavesImmediately: true,
        ),
        // 十九批 D1：编辑入口在题目信息 panel 底部（同一表单、同一
        // 保存／取消与脏检查；编辑态时标题行右侧显示保存／取消）。
        SizedBox(height: 12 * scale),
        QmButton(
          label: '编辑',
          variant: QmButtonVariant.plain,
          size: QmButtonSize.small,
          onPressed: () => _enterEdit(),
        ),
      ],
    );
  }

  Widget _buildInfoEdit(Question q) {
    final scale = qmScaleOf(context);
    // Win11 反馈包 1：编辑态答案区与整理页同套分流（见下「答案」字段
    // 与答案区编辑器）：选择/判断题只留字母按钮，其他题型与待确认
    // 只留文字答案框；题型切换不删已有答案，只提示。
    final isChoiceEditType = isChoiceQuestionType(_st.editQuestionType);
    final subjectKps = _st.kps
        .where((k) => k.subjectId == q.subjectId)
        .toList();
    final subjectFolders = _st.folders
        .where((f) => f.subjectId == q.subjectId)
        .toList();
    final customTypes = _st.editCustomTypes.where(
      (t) => !ErrorTypes.fixed.contains(t),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const QmBanner(
          tone: QmBannerTone.warning,
          message: '正在编辑这道题：改动先不生效，点「保存」才保存；点「取消」时，有改动会先问你存不存。学科不在编辑范围里。',
        ),
        // 二十三批 2 号方案（Meng 2026-11-22 15:53 改定：3 号分组
        // 精简式作废，改左主右属性）：左主列是「整理」（文件夹 /
        // 知识点 / 答案 / 解析 / 备注，底部取消/保存），右列是
        // 「贴标签」（学科 / 试卷 / 题型 / 错因 / 标签，一行一个、
        // 值靠右对齐）；窄屏右栏掉到左列下方变一列。3 号方案的
        // 分组小标题、分隔线、「？」展开、组头新建按钮全拆掉。
        SizedBox(height: 12 * scale),
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth > 640;
            final main = _buildEditMainColumn(
              q,
              isChoiceEditType: isChoiceEditType,
              subjectFolders: subjectFolders,
              subjectKps: subjectKps,
            );
            final attrs = _buildEditAttrColumn(
              q,
              customTypes: customTypes,
            );
            if (!wide) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  main,
                  SizedBox(height: 18 * scale),
                  attrs,
                ],
              );
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: main),
                  SizedBox(width: 20 * scale),
                  Container(
                    width: 1,
                    color: DesignTokens.of(
                      Theme.of(context).brightness,
                    ).line,
                  ),
                  SizedBox(width: 20 * scale),
                  Expanded(flex: 2, child: attrs),
                ],
              ),
            );
          },
        ),
        // 十四批 M3：选项标签确认编辑器（编辑态；随「保存」落盘——
        // 「确认选项」只改编辑态确认值，不单独写库）。
        // Win11 反馈包 1：选择/判断题时它是答案区的唯一答案入口
        // （文字答案框已隐藏）；其他题型与待确认时不渲染。
        // WP-A #1 收尾：detectedOptionLabels 同查看态；多选点选结果
        // 经 onMultiSelectionChanged 写进答案文本框。
        SizedBox(height: 12 * scale),
        AnswerOptionEditor(
          key: ValueKey('edit-${q.id}'),
          questionId: q.id,
          questionType: _st.editQuestionType,
          optionLabels: _st.editOptionLabels,
          storedOptionLabels: q.optionLabels,
          detectedOptionLabels: _st.editOptionLabels == null
              ? _detectedOptionLabels(q)
              : null,
          correctOption: _st.editCorrectOption,
          storedCorrectOption: q.correctOption,
          answerPendingRecheck: q.answerPendingRecheck,
          hadOldAnswer:
              (q.answer ?? '').trim().isNotEmpty ||
              (q.explanation ?? '').trim().isNotEmpty,
          answerReconfirmed: _st.editAnswerReconfirmed,
          // Win11 反馈包 5：选项文字走编辑表单值（保存时落盘）。
          optionContents:
              _optionContentsForDisplay(q, _st.editOptionContents),
          detectedOptionContents: _st.editOptionContents == null
              ? _detectedOptionContents(q)
              : null,
          onOptionContentsChanged: (contents) {
            _notifier.setEditOptionContents(contents);
            _markDirty();
          },
          onLabelsChanged: (labels) {
            _notifier.setEditOptionLabels(labels);
            _markDirty();
          },
          onCorrectOptionChanged: (value) {
            _notifier.setEditCorrectOption(value);
            _markDirty();
          },
          onAnswerReconfirmedChanged: (v) {
            _notifier.setEditAnswerReconfirmed(v);
            _markDirty();
          },
          onMultiSelectionChanged: (value) {
            _answerCtrl.text = value;
            _markDirty();
          },
          onConfirm: ({
            required List<String>? labels,
            required String? correctOption,
            required bool answerReconfirmed,
            required bool confirmLabels,
          }) {
            _notifier.confirmEditOptionLabels(
              labels: labels,
              correctOption: correctOption,
              answerReconfirmed: answerReconfirmed,
            );
            _markDirty();
          },
        ),
        if (_cancelAsk) ...[
          SizedBox(height: 10 * scale),
          _buildConfirmBox(q, '有还没保存的改动，要保存吗？', '', [
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
          ]),
        ],
      ],
    );
  }

  /// 二十三批 2 号方案左主列「整理」：文件夹 / 知识点 / 答案 /
  /// 解析 / 备注（备注放解析下面，内容类字段跟答案/解析一起），
  /// 底部取消/保存右对齐。全部单栏上下叠放。
  Widget _buildEditMainColumn(
    Question q, {
    required bool isChoiceEditType,
    required List<Folder> subjectFolders,
    required List<KnowledgePoint> subjectKps,
  }) {
    final scale = qmScaleOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldCell(
          _Field(
            '文件夹 *',
            Wrap(
              spacing: 8 * scale,
              runSpacing: 8 * scale,
              children: [
                for (final f in subjectFolders)
                  QmChip(
                    label: f.name,
                    selected: _st.editFolders.contains(f.id),
                    onTap: () {
                      _notifier.toggleEditFolder(f.id);
                      _markDirty();
                    },
                  ),
                QmChip(
                  label: '＋ 新建',
                  selected: false,
                  onTap: _newFolder,
                ),
              ],
            ),
            full: true,
          ),
        ),
        SizedBox(height: 14 * scale),
        _fieldCell(
          _Field('知识点', _buildKpPickerBox(subjectKps), full: true),
        ),
        if (!isChoiceEditType) ...[
          SizedBox(height: 14 * scale),
          _fieldCell(
            _Field(
              '答案',
              TextField(
                controller: _answerCtrl,
                focusNode: _answerFocus,
                decoration: const InputDecoration(
                  hintText: '填答案（可以空着）',
                ),
                maxLines: 3,
                onChanged: (_) => _markDirty(),
              ),
              full: true,
            ),
          ),
        ],
        if (isChoiceEditType &&
            (_st.editQuestionType == 'choice_single' ||
                _st.editQuestionType == 'true_false') &&
            (q.answer ?? '').trim().isNotEmpty) ...[
          SizedBox(height: 14 * scale),
          _fieldCell(
            _Field(
              '答案（已保留）',
              _valueText(
                '文字答案“${q.answer!.trim()}”已保留：当前题型答案以字母按钮为准，改回其他题型可继续用。',
              ),
              full: true,
            ),
          ),
        ],
        if (!isChoiceEditType &&
            _st.editCorrectOption != null &&
            _st.editCorrectOption!.isNotEmpty) ...[
          SizedBox(height: 14 * scale),
          _fieldCell(
            _Field(
              '答案（已保留）',
              _valueText(
                '题型已改：之前选定的正确答案（${_st.editCorrectOption}）已保留在本次编辑中，改回单选/判断可恢复；保存后按新题型处理。',
              ),
              full: true,
            ),
          ),
        ],
        SizedBox(height: 14 * scale),
        _fieldCell(
          _Field(
            '解析',
            TextField(
              controller: _explanationCtrl,
              focusNode: _explanationFocus,
              decoration: const InputDecoration(
                hintText: '填解析（可以空着）',
              ),
              maxLines: 5,
              onChanged: (_) => _markDirty(),
            ),
            full: true,
          ),
        ),
        SizedBox(height: 14 * scale),
        _fieldCell(
          _Field(
            '备注',
            TextField(
              controller: _notesCtrl,
              focusNode: _notesFocus,
              decoration: const InputDecoration(
                hintText: '填备注（可以空着）',
              ),
              maxLines: 3,
              onChanged: (_) => _markDirty(),
            ),
            full: true,
          ),
        ),
        SizedBox(height: 16 * scale),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            QmButton(
              label: '取消',
              variant: QmButtonVariant.plain,
              size: QmButtonSize.small,
              onPressed: _requestCancelEdit,
            ),
            SizedBox(width: 8 * scale),
            QmButton(
              label: '保存',
              size: QmButtonSize.small,
              onPressed: _saveEdit,
            ),
          ],
        ),
      ],
    );
  }

  /// 二十三批 2 号方案知识点行：虚线框；未选时显示「还没选」+
  /// 「＋ 添加」；点「＋ 添加」展开内联选择器（本学科全部知识点
  /// chip 点选，末尾「＋ 新建知识点」新建并选上）；已选的 chip
  /// 点一下取消选。选择器开着时按钮变「收起」。
  Widget _buildKpPickerBox(List<KnowledgePoint> subjectKps) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    final selected = subjectKps
        .where((k) => _st.editKps.contains(k.id))
        .toList();
    return _DashedBox(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: selected.isEmpty
                    ? Text(
                        '还没选',
                        style: TextStyle(
                          fontSize: DesignTokens.detailFieldValueFontSize,
                          color: palette.muted,
                          height: DesignTokens.bodyLineHeight,
                        ),
                      )
                    : Wrap(
                        spacing: 8 * scale,
                        runSpacing: 8 * scale,
                        children: [
                          for (final kp in selected)
                            QmChip(
                              label: '${kp.chapter} · ${kp.name}',
                              selected: true,
                              onTap: () {
                                _notifier.toggleEditKp(kp.id);
                                _markDirty();
                              },
                            ),
                        ],
                      ),
              ),
              SizedBox(width: 8 * scale),
              QmButton(
                label: _kpPickerOpen ? '收起' : '＋ 添加',
                variant: QmButtonVariant.plain,
                size: QmButtonSize.small,
                onPressed: () {
                  setState(() {
                    _kpPickerOpen = !_kpPickerOpen;
                  });
                },
              ),
            ],
          ),
          if (_kpPickerOpen) ...[
            SizedBox(height: 10 * scale),
            Wrap(
              spacing: 8 * scale,
              runSpacing: 8 * scale,
              children: [
                for (final kp in subjectKps)
                  QmChip(
                    label: '${kp.chapter} · ${kp.name}',
                    selected: _st.editKps.contains(kp.id),
                    onTap: () {
                      _notifier.toggleEditKp(kp.id);
                      _markDirty();
                    },
                  ),
                QmChip(
                  label: '＋ 新建知识点',
                  selected: false,
                  onTap: _newKnowledgePoint,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 二十三批 2 号方案右属性列：一行一个、值靠右对齐——学科 /
  /// 试卷 / 题型；错因 / 标签是标题在上、chip 在下。
  Widget _buildEditAttrColumn(
    Question q, {
    required Iterable<String> customTypes,
  }) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    // 题型「重新分类」与查看态同款条件（_typeFieldChild）：
    // 非手动题型且有 OCR 原文时才可重算。
    final showReclassify =
        q.questionTypeSource != 'manual' &&
        GlmOcrRawData.tryParse(q.ocrRaw) != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _attrRow(
          '学科',
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _st.subjectOf(q.subjectId).name,
                style: TextStyle(
                  fontSize: DesignTokens.detailFieldValueFontSize,
                  fontWeight: FontWeight.w700,
                  color: palette.ink,
                  height: DesignTokens.bodyLineHeight,
                ),
              ),
              SizedBox(width: 6 * scale),
              Text(
                '不可改',
                style: TextStyle(
                  fontSize: 12.5,
                  color: palette.muted,
                  height: DesignTokens.bodyLineHeight,
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: 14 * scale),
        _attrRow(
          '试卷',
          DropdownButton<String?>(
            value: _st.editExamId,
            isExpanded: true,
            hint: const Text(
              '未关联试卷',
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
            ),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text(
                  '未关联试卷',
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              for (final e in _st.exams)
                DropdownMenuItem(
                  value: e.id,
                  child: Text(
                    e.date == null
                        ? e.name
                        : '${e.name}（${_fmtDate(e.date!)}）',
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) {
              _notifier.setEditExamId(v);
              _markDirty();
            },
          ),
        ),
        SizedBox(height: 14 * scale),
        _attrRow(
          '题型',
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              questionTypeChip(
                type: _st.editQuestionType,
                onTap: _pickEditQuestionType,
              ),
              if (showReclassify) ...[
                SizedBox(width: 4 * scale),
                TextButton(
                  onPressed: _onReclassify,
                  child: const Text('重新分类'),
                ),
              ],
            ],
          ),
        ),
        SizedBox(height: 16 * scale),
        _attrSection(
          '错因',
          Wrap(
            spacing: 8 * scale,
            runSpacing: 8 * scale,
            children: [
              for (final t in ErrorTypes.fixed)
                QmChip(
                  label: t,
                  selected: _st.editErrorTypes.contains(t),
                  onTap: () {
                    _notifier.toggleEditErrorType(t);
                    _markDirty();
                  },
                ),
              for (final t in customTypes)
                QmChip(
                  label: t,
                  selected: true,
                  onTap: () {
                    _notifier.removeEditCustomType(t);
                    _markDirty();
                  },
                  onDelete: () {
                    _notifier.removeEditCustomType(t);
                    _markDirty();
                  },
                ),
              QmChip(
                label: '＋ 自定义',
                selected: false,
                onTap: _newCustomErrorType,
              ),
            ],
          ),
        ),
        SizedBox(height: 16 * scale),
        _attrSection(
          '标签',
          Wrap(
            spacing: 8 * scale,
            runSpacing: 8 * scale,
            children: [
              for (final t in _st.allTags)
                QmChip(
                  label: t,
                  selected: _st.editTags.contains(t),
                  onTap: () {
                    _notifier.toggleEditTag(t);
                    _markDirty();
                  },
                ),
              QmChip(
                label: '＋ 新建',
                selected: false,
                onTap: _newTag,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 右属性列单行：标签在左、值靠右对齐。
  Widget _attrRow(String label, Widget value) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13.5,
            color: palette.muted,
            height: DesignTokens.bodyLineHeight,
          ),
        ),
        SizedBox(width: 10),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: value,
          ),
        ),
      ],
    );
  }

  /// 右属性列小节：标题在上、内容在下（错因 / 标签 chip 组）。
  Widget _attrSection(String label, Widget child) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13.5,
            color: palette.muted,
            height: DesignTokens.bodyLineHeight,
          ),
        ),
        SizedBox(height: 6 * scale),
        child,
      ],
    );
  }

  Widget _buildReviewSection(Question q) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    // 未整理题没有加入/取消按钮（基线口径：已整理或已归档才有）；
    // 已归档的题也有按钮（归档期间不出现在复习列表里，恢复后按加入状态回来）。
    final canJoin = q.isOrganized || q.isArchived;
    final nOk = _st.history.where((h) => h.result == 'solved').length;
    final nBad = _st.history.length - nOk;
    final causeRows = <Widget>[];
    if (q.allCauses.isEmpty) {
      causeRows.add(
        Text(
          '还没填错因，先在上面的编辑里补上',
          style: TextStyle(
            fontSize: DesignTokens.detailFieldValueFontSize,
            color: palette.ink,
            height: DesignTokens.bodyLineHeight,
          ),
        ),
      );
    } else {
      for (final cause in q.allCauses) {
        final record = _st.records.where((r) => r.cause == cause).firstOrNull;
        final status = _causePillStatus(record);
        final recheck =
            record != null &&
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
    // 十九批 D1：复习记录 panel 按板子 kv 排（整体状态／错因状态／
    // 解决次数／复查时间／解决记录）＋底部加入／取消加入复习蓝按钮。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _kvRow('整体状态', QmStatusPill.cause(_overallStatus(q))),
        _kvRow(
          '错因状态',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: causeRows,
          ),
        ),
        _kvRow(
          '解决次数',
          _kvText(
            '共自查 ${_st.history.length} 次 · 自查「已解决」$nOk 次 · 「未解决 / 不确定」$nBad 次（自查「已解决」达到设置次数才算已解决）',
          ),
        ),
        _kvRow(
          '复查时间',
          _kvText('治愈后 +${_st.recheckIntervalDays} 天（按设置）'),
        ),
        _kvRow(
          '解决记录',
          _st.history.isEmpty
              ? _buildEmptyHistory()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final h in _st.history)
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
        SizedBox(height: 12 * scale),
        // 未整理题没有加入/取消按钮（基线口径：已整理或已归档才有）；
        // 已归档的题也有按钮（归档期间不出现在复习列表里，恢复后按加入状态回来）。
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
      ],
    );
  }

  /// B11-11 顺手活：复习记录空状态——文字说明不变，有 onGoReview
  /// 回调时下面再给一个“去复习”按钮（去 /review）；没回调时只有文字。
  Widget _buildEmptyHistory() {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '暂无复习记录，去复习页练一次会出现在这里',
          style: TextStyle(
            fontSize: DesignTokens.detailRevLogFontSize,
            color: palette.muted,
            height: DesignTokens.bodyLineHeight,
          ),
        ),
        if (widget.onGoReview != null) ...[
          SizedBox(height: 8 * scale),
          QmButton(
            label: '去复习',
            size: QmButtonSize.small,
            onPressed: widget.onGoReview,
          ),
        ],
      ],
    );
  }

  String _historyLabel(String r) => switch (r) {
    'solved' => '已解决',
    'unsolved' => '未解决',
    _ => '不确定',
  };

  /// 加入 / 取消加入复习（HTML `detailJoinRevHTML`）。
  /// 十九批 D1：蓝底主按钮（板子 `.abtn`），放在复习记录 panel 底部。
  Widget _buildJoinReview(Question q) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    if (q.reviewJoined) {
      final pending = q.allCauses.where((c) {
        final r = _st.records.where((x) => x.cause == c).firstOrNull;
        return r == null || r.status != CauseStatus.solved;
      }).length;
      final stTxt = pending > 0
          ? '已加入复习 · 还有 $pending 个错因未解决'
          : '已加入复习 · 错因已全部解决，满 ${_st.recheckIntervalDays} 天自动回来复查';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          QmStatusPill.tone(label: stTxt, tone: QmTone.info),
          SizedBox(height: 8 * scale),
          QmButton(
            label: '取消加入复习',
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
              ? '加入后，这道题的错因会按加入顺序出现在复习页的待解决列表里，按错因解决；这道题还没填错因，先在上面的编辑里补上错因，加入后才有可解决的错因'
              : '加入后，这道题的错因会按加入顺序出现在复习页的待解决列表里，按错因解决',
          style: TextStyle(fontSize: 12.5, color: palette.muted),
        ),
      ],
    );
  }

  // ---------- 十九批 D1：右栏三组 ----------

  /// 右栏三组面板（板子 §2.5）：同错因／同知识点／同文件夹。
  /// 空组不显示；三组都空时右栏不占位。取数在 DetailNotifier
  ///（_refreshRelated），计数以后端真实计数为准。
  List<Widget> _buildRelatedPanels(DetailState st) {
    final q = st.question;
    if (q == null) return const [];
    final scale = qmScaleOf(context);
    final panels = <Widget>[];
    if (st.related.sameCause.isNotEmpty) {
      panels.add(_buildSameCausePanel(st, q));
    }
    if (st.related.sameKp.isNotEmpty) {
      panels.add(_buildSameKpPanel(st, q));
    }
    if (st.related.folder != null) {
      panels.add(_buildSameFolderPanel(st, q, st.related.folder!));
    }
    final out = <Widget>[];
    for (var i = 0; i < panels.length; i++) {
      if (i > 0) out.add(SizedBox(height: 12 * scale));
      out.add(panels[i]);
    }
    return out;
  }

  /// 右栏 panel（不折叠）：白底卡片＋14.5px 700 标题＋内容。
  Widget _buildRelatedPanel({
    required Key key,
    required String title,
    required List<Widget> children,
  }) {
    final scale = qmScaleOf(context);
    final palette = _d1Palette;
    return _buildPanelCard(
      key: key,
      header: Padding(
        padding: EdgeInsets.fromLTRB(
          14 * scale,
          14 * scale,
          14 * scale,
          8 * scale,
        ),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w700,
            color: palette.ink,
          ),
        ),
      ),
      body: Padding(
        padding: EdgeInsets.fromLTRB(14 * scale, 0, 14 * scale, 14 * scale),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _withDividers(children),
        ),
      ),
    );
  }

  /// 相关行通用结构（板子 §2.5.4 `.rel-row`）：标题 13.5px 600＋
  /// 副行 12px 灰＋右侧蓝字跳转，悬停 #F1F5FA，行间分隔线。
  Widget _buildRelRow({
    Key? key,
    Color? dotColor,
    required String title,
    required String subtitle,
    required String goLabel,
    required VoidCallback onTap,
  }) {
    final scale = qmScaleOf(context);
    final palette = _d1Palette;
    return InkWell(
      key: key,
      onTap: onTap,
      hoverColor: _d1HoverBg(),
      borderRadius: BorderRadius.circular(8 * scale),
      child: Padding(
        padding: EdgeInsets.all(8 * scale),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (dotColor != null) ...[
              Container(
                width: 9,
                height: 9,
                margin: EdgeInsets.only(top: 5 * scale),
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                ),
              ),
              SizedBox(width: 6 * scale),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: palette.ink,
                      height: 1.45,
                    ),
                  ),
                  SizedBox(height: 2 * scale),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: palette.muted),
                  ),
                ],
              ),
            ),
            SizedBox(width: 9 * scale),
            Padding(
              padding: EdgeInsets.only(top: 2 * scale),
              child: Text(
                goLabel,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: _d1Link(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 行间分隔线（板子 `.rel-row + .rel-row` 上边框 #EEF2F7）。
  List<Widget> _withDividers(List<Widget> rows) {
    final out = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) {
        out.add(Divider(height: 1, thickness: 1, color: _d1RelDivider()));
      }
      out.add(rows[i]);
    }
    return out;
  }

  /// 同错因 panel（板子 §2.5.1）：1 道具体题＋「还有 N 道」汇总行
  ///（N 含已展示的那道，协调员决策第 13 项；只有 1 道时不显示汇总行）。
  Widget _buildSameCausePanel(DetailState st, Question q) {
    final cause = q.allCauses.first;
    final items = st.related.sameCause;
    final first = items.first;
    final firstSubject = st.subjectOf(first.question.subjectId);
    final rows = <Widget>[
      _buildRelRow(
        key: Key('related-row-${first.question.id}'),
        dotColor: firstSubject.color,
        title: first.question.title,
        subtitle:
            '${firstSubject.name} · ${first.statusLabel} · 也栽在「$cause」上，可对照着看',
        goLabel: '跳过去 ›',
        onTap: () => _openRelated(
          first.question,
          items.map((e) => e.question.id).toList(),
          '同错因 · $cause',
        ),
      ),
    ];
    if (items.length > 1) {
      rows.add(
        _buildRelRow(
          key: const Key('related-same-cause-more'),
          title: '还有 ${items.length} 道同错因的题',
          subtitle: _subjectBreakdown(st, items),
          goLabel: '全部 ›',
          onTap: () => _openCauseSearch(cause),
        ),
      );
    }
    return _buildRelatedPanel(
      key: const Key('related-same-cause'),
      title: '同错因的其他题 · $cause',
      children: rows,
    );
  }

  /// 同知识点 panel（板子 §2.5.2）：最多 2 道具体题。
  Widget _buildSameKpPanel(DetailState st, Question q) {
    final kpNames = _st.kps
        .where((k) => q.knowledgePointIds.contains(k.id))
        .map((k) => k.name)
        .toList();
    final kpLabel = kpNames.join(' / ');
    final items = st.related.sameKp.take(2).toList();
    final rows = items.map((item) {
      final subject = st.subjectOf(item.question.subjectId);
      final cause = item.question.allCauses.isEmpty
          ? ''
          : item.question.allCauses.first;
      return _buildRelRow(
        key: Key('related-row-${item.question.id}'),
        dotColor: subject.color,
        title: item.question.title,
        subtitle: cause.isEmpty
            ? '${subject.name} · ${item.statusLabel}'
            : '${subject.name} · ${item.statusLabel} · 错因 $cause',
        goLabel: '跳过去 ›',
        onTap: () => _openRelated(
          item.question,
          st.related.sameKp.map((e) => e.question.id).toList(),
          '同知识点 · $kpLabel',
        ),
      );
    }).toList();
    return _buildRelatedPanel(
      key: const Key('related-same-kp'),
      title: '同知识点的题 · $kpLabel',
      children: rows,
    );
  }

  /// 同文件夹 panel（板子 §2.5.3）：标题含计数＋1 条入口行。
  Widget _buildSameFolderPanel(
    DetailState st,
    Question q,
    RelatedFolderInfo folder,
  ) {
    return _buildRelatedPanel(
      key: const Key('related-same-folder'),
      title: '同文件夹 · ${folder.name}（${folder.totalCount} 道）',
      children: [
        _buildRelRow(
          key: const Key('related-folder-open'),
          title: '按收集顺序继续看这个文件夹',
          subtitle: '当前第 ${folder.currentPosition} 道 · 共 ${folder.totalCount} 道',
          goLabel: '打开列表 ›',
          onTap: () => _openFolderSearch(folder, q.subjectId),
        ),
      ],
    );
  }

  /// 同错因汇总行的按学科计数（如 `数学 3 · 英语 1 · 政治 1`）：
  /// 按题数从多到少，相同题数按学科名排序。
  String _subjectBreakdown(DetailState st, List<RelatedItem> items) {
    final counts = <String, int>{};
    for (final item in items) {
      final name = st.subjectOf(item.question.subjectId).name;
      counts[name] = (counts[name] ?? 0) + 1;
    }
    final entries = counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
    return entries.map((e) => '${e.key} ${e.value}').join(' · ');
  }

  /// 相关题行 → 该题详情：新详情页的 orderIds 按来源分组全量
  ///（R7：同错因行走同错因组全量，同知识点行走同知识点组全量），
  ///返回行带分组上下文（见 [QuestionDetailPage.searchContext]）。
  void _openRelated(
    Question target,
    List<String> groupOrderIds,
    String searchContext,
  ) {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => QuestionDetailPage(
            key: UniqueKey(),
            repo: ref.read(repositoryProvider),
            questionId: target.id,
            orderIds: groupOrderIds,
            sourceLabel: widget.sourceLabel,
            searchContext: searchContext,
            exportService: widget.exportService,
            onGoReview: widget.onGoReview,
            onOpenWrongbookFiltered: widget.onOpenWrongbookFiltered,
          ),
        ),
      ),
    );
  }

  /// 「全部 ›」→ 同错因的搜索结果（走 app.dart 接线的回调；
  /// 未接线时退回底层搜索结果——见 [OpenWrongbookFiltered]）。
  void _openCauseSearch(String cause) {
    final cb = widget.onOpenWrongbookFiltered;
    if (cb != null) {
      cb(cause: cause);
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  /// 「打开列表 ›」→ 该文件夹的搜索结果（同上）。
  void _openFolderSearch(RelatedFolderInfo folder, String subjectId) {
    final cb = widget.onOpenWrongbookFiltered;
    if (cb != null) {
      cb(folderId: folder.folderId, subjectId: subjectId);
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  /// 底部操作卡片（十九批 D1，B27）：只留复制图片／保存图片／
  /// 导出带答案版（B11-8，现版逻辑不变）；上一题／下一题已移页顶
  /// 返回行，返回／收藏／归档／删除已移标题行（收藏是标题行星标），
  /// 这里不再重复。本页无「开始复习」按钮。
  Widget _buildWorkActs(Question q) {
    final scale = qmScaleOf(context);
    return SizedBox(
      width: double.infinity,
      child: Container(
        margin: EdgeInsets.only(
          top: DesignTokens.detailWorkActsMarginTop * scale,
        ),
        padding: EdgeInsets.all(14 * scale),
        decoration: BoxDecoration(
          color: _d1CardBg(),
          border: Border.all(color: _d1CardLine()),
          borderRadius: BorderRadius.circular(10 * scale),
        ),
        child: Wrap(
          spacing: 10 * scale,
          runSpacing: 10 * scale,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // B11-8：导出图片三动作。
            QmButton(
              label: '复制图片',
              variant: QmButtonVariant.plain,
              onPressed: _copyImage,
            ),
            QmButton(
              label: '保存图片',
              variant: QmButtonVariant.plain,
              onPressed: _saveImage,
            ),
            QmButton(
              label: '导出带答案版',
              variant: QmButtonVariant.plain,
              onPressed: _exportShareCard,
            ),
          ],
        ),
      ),
    );
  }

  /// 内联确认框（HTML `.confirmbox`：err-line 边 / err-bg 底 /
  /// err-ink 字，radius 12，padding 12×14，14px 字）。
  /// B3：删除确认已改模态弹窗，此框只剩取消编辑（“有还没保存的改动，
  /// 要保存吗？”三选一）一个用途，不是删除确认，不改。
  Widget _buildConfirmBox(
    Question q,
    String title,
    String detail,
    List<Widget> actions,
  ) {
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
        borderRadius: BorderRadius.circular(DesignTokens.scaled(scale).radius),
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
          Wrap(spacing: 8 * scale, runSpacing: 8 * scale, children: actions),
        ],
      ),
    );
  }
}

/// B11-8：带答案版分享卡片的预览弹窗。
///
/// 卡片包在 RepaintBoundary 里（key 由详情页持有）；点“保存图片”时
/// 先把 boundary 转 PNG 再 pop 回字节，详情页接着走另存为对话框。
/// 生成失败时留在弹窗里给提示，不关弹窗、不丢预览。
class _ShareCardExportDialog extends StatefulWidget {
  const _ShareCardExportDialog({
    required this.service,
    required this.boundaryKey,
    required this.sliceBytes,
    required this.title,
    required this.subjectName,
    required this.folderNames,
    required this.errorTypes,
    required this.answer,
    required this.explanation,
  });

  final QuestionExportService service;
  final GlobalKey boundaryKey;
  final Uint8List sliceBytes;
  final String title;
  final String subjectName;
  final List<String> folderNames;
  final List<String> errorTypes;
  final String? answer;
  final String? explanation;

  @override
  State<_ShareCardExportDialog> createState() => _ShareCardExportDialogState();
}

class _ShareCardExportDialogState extends State<_ShareCardExportDialog> {
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final scale = qmScaleOf(context);
    return AlertDialog(
      title: const Text('导出带答案版'),
      content: SizedBox(
        width: 720 * scale,
        child: SingleChildScrollView(
          child: RepaintBoundary(
            key: widget.boundaryKey,
            child: QuestionShareCard(
              sliceBytes: widget.sliceBytes,
              title: widget.title,
              subjectName: widget.subjectName,
              folderNames: widget.folderNames,
              errorTypes: widget.errorTypes,
              answer: widget.answer,
              explanation: widget.explanation,
            ),
          ),
        ),
      ),
      actions: [
        QmButton(
          label: '关闭',
          variant: QmButtonVariant.plain,
          size: QmButtonSize.small,
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        QmButton(
          label: _saving ? '正在生成…' : '保存图片',
          size: QmButtonSize.small,
          onPressed: _saving
              ? null
              : () async {
                  setState(() => _saving = true);
                  try {
                    final png = await widget.service.captureBoundary(
                      widget.boundaryKey,
                    );
                    if (context.mounted) Navigator.of(context).pop(png);
                  } catch (_) {
                    if (!context.mounted) return;
                    setState(() => _saving = false);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('分享卡片生成失败，请重试')),
                    );
                  }
                },
        ),
      ],
    );
  }
}

/// 虚线圆角框（二十三批 2 号方案知识点行：板子同款虚线框）。
/// Flutter 没有内置虚线边框，用 PathMetric 沿圆角矩形描虚线。
class _DashedBox extends StatelessWidget {
  const _DashedBox({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    return CustomPaint(
      painter: _DashedRectPainter(
        color: palette.lineStrong,
        strokeWidth: 1,
        radius: 8 * scale,
      ),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          horizontal: 12 * scale,
          vertical: 10 * scale,
        ),
        child: child,
      ),
    );
  }
}

class _DashedRectPainter extends CustomPainter {
  const _DashedRectPainter({
    required this.color,
    required this.strokeWidth,
    required this.radius,
  });

  final Color color;
  final double strokeWidth;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;
    final rect = Rect.fromLTWH(
      strokeWidth / 2,
      strokeWidth / 2,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(radius)),
      );
    const dash = 5.0;
    const gap = 4.0;
    final dashed = Path();
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + dash).clamp(0.0, metric.length);
        dashed.addPath(metric.extractPath(distance, end), Offset.zero);
        distance += dash + gap;
      }
    }
    canvas.drawPath(dashed, paint);
  }

  @override
  bool shouldRepaint(_DashedRectPainter old) =>
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      old.radius != radius;
}

