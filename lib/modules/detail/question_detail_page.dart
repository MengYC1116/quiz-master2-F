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
// - 底部操作：返回 / 收藏 / 归档（已归档时变「恢复」）/ 复制图片 /
//   保存图片 / 导出带答案版（B11-8，与收藏/归档/删除并列）/ 上一题 /
//   下一题 / 删除；删除用模态弹窗确认（B3：`删了就没了，确定吗？`），
// - 本页没有任何「开始复习」按钮；复习记录区只留「加入复习 /
//   取消加入复习」（未整理题没有）、各错因状态、解决次数与全部解决记录；
//   旧的复习状态下拉与下次复习日期输入已删，不复活翻卡模型。
//
// 颜色只取 DesignTokens；文字符号（D3），不用图标字体；
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
import '../../modules/ocr/question_type_picker.dart';
import '../../services/glm_ocr_client.dart';
import '../../services/question_export_service.dart';
import '../../services/stem_splitter.dart';
import '../../services/yolo_onnx_service.dart';
import '../../state/detail_notifier.dart';
import '../../state/repository_provider.dart';
import '../../theme/design_tokens.dart';
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
    this.sourceLabel = '错题本',
    this.imageFailed = false,
    this.exportService,
    this.onGoReview,
  });

  final QuestionRepository repo;
  final String questionId;
  final List<String> orderIds;

  /// 进入来源（HTML `detailFromName`）：错题本 / 整理工作台 / 复习。
  /// 返回按钮与「第 N / M 题 · 按{来源}当前的顺序」用它；app.dart
  /// 按调用页传入，默认错题本。
  final String sourceLabel;

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
        imageFailed: widget.imageFailed,
        exportService: _exportService,
        onGoReview: widget.onGoReview,
      ),
    );
  }
}

/// 详情页内层：持有文本控制器与纯界面状态，业务走 `detailProvider`。
class _DetailView extends ConsumerStatefulWidget {
  const _DetailView({
    required this.sourceLabel,
    required this.imageFailed,
    required this.exportService,
    this.onGoReview,
  });

  final String sourceLabel;
  final bool imageFailed;
  final QuestionExportService exportService;
  final VoidCallback? onGoReview;

  @override
  ConsumerState<_DetailView> createState() => _DetailViewState();
}

class _DetailViewState extends ConsumerState<_DetailView> {
  /// 上次见过的 `formResetKey`：变了说明 Notifier 重建了编辑表单
  /// （进编辑），控制器文本按当前题重建一次（D-40①）。
  int _seenFormKey = -1;

  bool _editing = false;
  bool _dirty = false;
  bool _answerVisible = false;

  /// B11-8：导出服务（构造注入的优先）与分享卡片的 RepaintBoundary key。
  final _shareCardKey = GlobalKey();

  /// 取消编辑时的内联确认框（HTML `.confirmbox`）是否显示；
  /// [_cancelAskPop] 表示它是由返回触发的（选“保存并退出 / 不保存”
  /// 后要离开本页），否则只是退出编辑模式。
  bool _cancelAsk = false;
  bool _cancelAskPop = false;

  // B3：删除确认已改模态弹窗（见 [_askDelete]），不再用内联确认框。

  final Set<String> _expanded = {};

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
  Future<bool> _acceptOcrCandidate(String candidateStem) async {
    final reason = await _notifier.acceptOcrCandidateWithReason();
    if (!mounted) return reason == null;
    _snack(reason == null ? '已用新的识别结果替换' : candidateRejectionMessage(reason));
    return reason == null;
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

  Future<void> _rerecognizeStem() async {
    final ok = await _notifier.rerecognizeCurrent();
    if (!mounted) return;
    if (ok) {
      _snack('已重新识别，稍等片刻');
    } else {
      _snack('重新识别失败：没有可识别的切片');
    }
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
    if (_st.editBase == null) return;
    await _notifier.saveEdit(
      title: _titleCtrl.text,
      answer: _answerCtrl.text,
      explanation: _explanationCtrl.text,
      notes: _notesCtrl.text,
    );
    if (!mounted) return;
    setState(() {
      _editing = false;
      _dirty = false;
      _cancelAsk = false;
    });
    // Stage 4：保存已发变更事件，角标由 badgeCountsProvider 刷新，
    // 本页不再回调外壳手动刷角标（onChanged 已删）。
  }

  /// 十四批 M3：查看态直接改选项标签块（「确认选项」或正确选项即时保存
  /// 时调；与题型 chip 的即时保存口径一致）。
  Future<void> _saveViewOptionBlock({
    required List<String>? labels,
    required String? correctOption,
    required bool answerReconfirmed,
    required bool confirmLabels,
  }) async {
    try {
      await _notifier.saveOptionBlock(
        labels: labels,
        correctOption: correctOption,
        confirmLabels: confirmLabels,
        answerReconfirmed: answerReconfirmed,
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
        _snack('重新框选失败：切片写不进去');
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
        _expanded.clear();
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
      _expanded.clear();
    });
    _notifier.goTo(id);
  }

  Future<void> _toggleReviewJoined() async {
    if (_st.question == null) return;
    final ok = await _notifier.toggleReviewJoined();
    if (!ok) {
      _snack('先补错误类型');
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
      if (mounted) _snack('已经有了');
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

  Future<void> _newExam() async {
    final name = await _askText('新建试卷');
    if (name == null) return;
    await _notifier.submitNewExam(name);
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
    // SR-P2-27：与固定枚举同名时直接选中对应固定项，不进自定义集合
    //（否则保存时被 customNew 滤掉、错因静默消失；整理页还会造成
    // allCauses 重复）。
    final wasFixed = _notifier.addCustomType(name);
    if (wasFixed) _snack('“$name”是固定错误类型，已帮你选中');
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
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    if (st.loading) {
      return Scaffold(
        backgroundColor: palette.surface,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final q = st.question;
    if (q == null) {
      return Scaffold(
        backgroundColor: palette.surface,
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
    // B8-7（A 紧凑）：内容宽 1160；P1-2：整题图按内容高度自适应、上限 460。
    const contentMaxWidth = 1160.0;
    const imageMaxHeight = 460.0;
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
              constraints: BoxConstraints(maxWidth: contentMaxWidth * scale),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildToolbar(q, idx),
                  SizedBox(height: 10 * scale),
                  // B8-7（A 紧凑）：标题 + 两行副标题 + 信息条。
                  _buildTitle(q, subject),
                  SizedBox(height: 6 * scale),
                  _buildSubtitle(q),
                  // B8-7：信息条只读展示编辑前的值；编辑态不显示
                  //（编辑中改文件夹/标签时条会过期，编辑表单里自有芯片）。
                  if (!_editing) ...[
                    SizedBox(height: 10 * scale),
                    _buildMetaStrip(q),
                  ],
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
                  SizedBox(height: 12 * scale),
                  _buildImageBlock(q, imageMaxHeight),
                  // 十三批 P1-2 任务 a：重框成功但 OCR 未入队时的横幅——
                  // 框选结果已保留（题图与切片都是新的），只说明 OCR
                  // 没排上，并给“重新入队”重试入口。不要让页面把
                  // “已重新框选，切片已更新”等同于“OCR 已排队”。
                  if (st.ocrEnqueueFailed) ...[
                    SizedBox(height: 12 * scale),
                    _ocrEnqueueFailedBanner(scale),
                  ],
                  SizedBox(height: 12 * scale),
                  // 十三批 M5：识别题干区——在题目图下方，长期可用，
                  // 与整理工作台共用同一套 [OcrStemSection]。
                  // Key 按题 id：换题时编辑器收起、草稿不跨题。
                  OcrStemSection(
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
                    onDeleteFigure: _deleteFigure,
                    onEditingChanged: (open) {
                      setState(() {
                        _stemEditorOpen = open;
                        _stemEditorQuestionId = open ? q.id : null;
                        if (!open) _candidateWhileEditing = null;
                      });
                    },
                  ),
                  SizedBox(height: 12 * scale),
                  _buildSection('answer', '答案解析', _buildAnswerSection(q)),
                  SizedBox(height: 12 * scale),
                  _buildSection('info', '题目信息', _buildInfoSection(q)),
                  SizedBox(height: 12 * scale),
                  _buildSection('review', '复习记录', _buildReviewSection(q)),
                  _buildWorkActs(q, hasPrev: hasPrev, hasNext: hasNext),
                  SizedBox(height: 8 * scale),
                ],
              ),
            ),
          ),
        ),
      ),
    );
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

  /// B8-7：整题图 + 图下提示。
  /// P1-2：题图区按内容高度自适应、上限 460 不变。QuestionSlice 的占位
  /// Center 会撑满有界高度约束（演示题小图只占 460 盒子约 15%，首屏近半
  /// 米色空白），包一层 IntrinsicHeight 让盒子高度取内容固有高度；大图
  /// 仍由 QuestionSlice 自身的 maxHeight 460 限高。
  Widget _buildImageBlock(Question q, double imageMaxHeight) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    return Column(
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
        SizedBox(height: 6 * scale),
        Text(
          '整题图（完整题目就是最小单位）：点一下弹出大图浮层，浮层里滚轮放大 / 缩小、按住拖动看图，点图、点关闭或按 Esc 回来',
          style: TextStyle(
            fontSize: DesignTokens.detailHintFontSize,
            color: palette.muted,
            height: DesignTokens.bodyLineHeight,
          ),
        ),
      ],
    );
  }

  /// 工具栏：`← 返回{来源}` + `第 N / M 题 · 按{来源}当前的顺序` +
  /// 右上角 编辑 / 保存 / 取消（HTML `.toolbar`）。
  Widget _buildToolbar(Question q, int idx) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    final posTxt = idx >= 0
        ? '第 ${idx + 1} / ${_st.orderIds.length} 题 · 按${widget.sourceLabel}当前的顺序'
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
          QmButton(label: '保存', size: QmButtonSize.small, onPressed: _saveEdit),
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

  /// 标题：`学科 · 题型｜题名 ★`（HTML `h3.pt` 24px/800 + `.dt-star`）。
  /// B8-7：标题前加学科图标章；编辑态时标题换成题名输入框（基线行为保留）。
  Widget _buildTitle(Question q, Subject subject, {double badgeSize = 34}) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    if (_editing) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _subjectBadge(subject, badgeSize),
          SizedBox(width: 10 * scale),
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
          ),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _subjectBadge(subject, badgeSize),
        SizedBox(width: 10 * scale),
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

  /// 副标题第一行（HTML `.psub`，中性表述——原型里的“选错自己承担”不抄）：
  /// 学科只读说明 + 错因汇总（每错因一个状态 pill）+ 已归档 pill。
  /// B8-7：从旧 _buildSubtitle 拆出来，文字与顺序原样，只拆行，
  /// 让标题下先看到学科与错因状态，补充说明另起一行小字。
  Widget _buildSubtitleCauseLine(Question q) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    final subject = _st.subjectOf(q.subjectId);
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
        final record = _st.records.where((r) => r.cause == cause).firstOrNull;
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

  /// 副标题第二行：只读说明的补充句（旧副标题里的两段文字，原样），
  /// 小字 muted，不跟第一行抢层级。
  Widget _buildSubtitleNote() {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final style = TextStyle(
      fontSize: DesignTokens.captionFontSize,
      color: palette.muted,
      height: DesignTokens.bodyLineHeight,
    );
    return Wrap(
      children: [
        Text('（只显示，不能改——导入时选定，详情和整理台都不能改）', style: style),
        Text(' · 其他字段点右上角「编辑」改，点「保存」才生效', style: style),
      ],
    );
  }

  /// 副标题（两行）：第一行学科 + 错因 pill，第二行补充说明小字。
  Widget _buildSubtitle(Question q) {
    final scale = qmScaleOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSubtitleCauseLine(q),
        SizedBox(height: 4 * scale),
        _buildSubtitleNote(),
      ],
    );
  }

  /// B8-7 信息条：文件夹 chip（学科 tint）+ 标签 chip + 加入复习状态
  /// pill；只读展示。错因名不进信息条（副标题 pill 已有，测试按
  /// 错因名计数，重复会出现两个同名文本）。
  Widget _buildMetaStrip(Question q) {
    final scale = qmScaleOf(context);
    final subject = _st.subjectOf(q.subjectId);
    final folders = _st.folders
        .where((f) => q.folderIds.contains(f.id))
        .toList();
    final chips = <Widget>[
      for (final f in folders)
        _metaChip(f.name, tinted: true, subject: subject),
      for (final t in q.tags) _metaChip('#$t', tinted: false),
    ];
    final canJoin = q.isOrganized || q.isArchived;
    final reviewPill = q.reviewJoined
        ? QmStatusPill.tone(label: '已加入复习', tone: QmTone.info)
        : canJoin
        ? QmStatusPill.tone(label: '未加入复习', tone: QmTone.warn)
        : null;
    if (chips.isEmpty && reviewPill == null) return const SizedBox.shrink();
    return Wrap(
      spacing: 8 * scale,
      runSpacing: 8 * scale,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [...chips, if (reviewPill != null) reviewPill],
    );
  }

  /// 信息条里的小 chip：圆角 pill，文件夹用学科 tint，标签用中性底。
  Widget _metaChip(String label, {required bool tinted, Subject? subject}) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    final color = subject?.color;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 10 * scale,
        vertical: 5 * scale,
      ),
      decoration: BoxDecoration(
        color: tinted
            ? (color?.withValues(alpha: 0.10) ?? palette.surface2)
            : palette.surface2,
        border: Border.all(
          color: tinted
              ? (color?.withValues(alpha: 0.35) ?? palette.line)
              : palette.line,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: palette.ink2,
          height: 1.2,
        ),
      ),
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

  /// B8-7：三段头上的摘要行（折叠态也能看到段内概况；文案特意避开
  /// 测试按精确文本计数的词——「看答案」「加入复习」「概念不清」
  /// 「解决中」等都不出现在摘要里）。
  String? _sectionSubtitle(String key, Question q) {
    if (_editing) return null;
    switch (key) {
      case 'answer':
        final hasAnswer = (q.answer ?? '').trim().isNotEmpty;
        final hasExplanation = (q.explanation ?? '').trim().isNotEmpty;
        return hasAnswer || hasExplanation ? '已填答案与解析' : '答案与解析待填写';
      case 'info':
        final nFolders = q.folderIds.length;
        final nKps = q.knowledgePointIds.length;
        final nTags = q.tags.length;
        if (nFolders == 0 && nKps == 0 && nTags == 0) return '信息待补充';
        return '文件夹 $nFolders · 知识点 $nKps · 标签 $nTags';
      case 'review':
        final canJoin = q.isOrganized || q.isArchived;
        if (!q.reviewJoined) {
          return canJoin ? '未加入复习' : '未整理，不能加入复习';
        }
        final pending = q.allCauses.where((c) {
          final r = _st.records.where((x) => x.cause == c).firstOrNull;
          return r == null || r.status != CauseStatus.solved;
        }).length;
        return '已加入复习 · 待解决 $pending 个错因';
    }
    return null;
  }

  Widget _buildSection(String key, String title, Widget body) {
    final open = _expanded.contains(key);
    final q = _st.question;
    return QmFoldSection(
      variant: QmFoldVariant.detail,
      title: title,
      subtitle: q == null ? null : _sectionSubtitle(key, q),
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
    // 十四批 M3：答案与解析分别展示、分别标状态——待重新核对时显示
    // “标准答案待重新核对”/“解析待重新核对”，不显示旧文本为有效答案
    //（effective* 在待核对时一律返回 null）。
    final hasAnswer = (q.effectiveAnswer ?? '').trim().isNotEmpty;
    final hasExplanation = (q.effectiveExplanation ?? '').trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _formGrid([
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

  /// WP-A #1 收尾：切分器检测到的选项字母序列（见
  /// [StemSplitResult.optionLabels]），只作 [AnswerOptionEditor]
  /// 的初始值；无 OCR 原文或未切出序列时返回 null（编辑器走 A–D
  /// 兜底）。纯函数，不持久化。
  List<String>? _detectedOptionLabels(Question q) {
    final raw = GlmOcrRawData.tryParse(q.ocrRaw);
    if (raw == null) return null;
    return splitStem(raw.mdResults).optionLabels;
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
    final grid = _formGrid([
      _Field('学科（不能改）', _valueText(subject.name), hint: '导入时选定，详情和整理台都不能改'),
      _Field(
        '文件夹（归类）',
        folders.isEmpty
            ? _supplement('folders')
            : _valueText(folders.map((f) => f.name).join('、')),
      ),
      // 十四批 M1：题型 chip（查看态点开直接改，立即保存）。
      _Field(
        '题型',
        questionTypeChip(type: q.questionType, onTap: _pickQuestionType),
        hint: '点芯片可改 · 改后不再自动分类',
      ),
      _Field(
        '知识点',
        kps.isEmpty
            ? _supplement('knowledgePoints')
            : _valueText(
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
        grid,
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
      ],
    );
  }

  Widget _buildInfoEdit(Question q) {
    final scale = qmScaleOf(context);
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
        _formGrid([
          _Field(
            '学科（不能改）',
            _valueText(_st.subjectOf(q.subjectId).name),
            hint: '导入时选定，详情和整理台都不能改',
          ),
          _Field(
            '试卷（来源）',
            Row(
              children: [
                Expanded(
                  child: DropdownButton<String?>(
                    value: _st.editExamId,
                    isExpanded: true,
                    hint: const Text('未关联试卷'),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('未关联试卷'),
                      ),
                      for (final e in _st.exams)
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
                      _notifier.setEditExamId(v);
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
          // 十四批 M1：题型 chip（编辑态改表单值，点「保存」才落盘）。
          _Field(
            '题型',
            questionTypeChip(
              type: _st.editQuestionType,
              onTap: _pickEditQuestionType,
            ),
            hint: '点芯片可改 · 改后不再自动分类',
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
                        selected: _st.editFolders.contains(f.id),
                        onTap: () {
                          _notifier.toggleEditFolder(f.id);
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
                        selected: _st.editKps.contains(kp.id),
                        onTap: () {
                          _notifier.toggleEditKp(kp.id);
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
                '在这里新建的知识点会加进「${_st.subjectOf(q.subjectId).name}」的知识点树（自定义一类），之后整理和筛选都能选，不用去学科管理',
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
                    for (final t in _st.allTags)
                      QmChip(
                        label: t,
                        selected: _st.editTags.contains(t),
                        onTap: () {
                          _notifier.toggleEditTag(t);
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
        // 十四批 M3：选项标签确认编辑器（编辑态；随「保存」落盘——
        // 「确认选项」只改编辑态确认值，不单独写库）。
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
      _Field(
        '错因状态',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: causeRows,
        ),
      ),
      _Field(
        '解决次数',
        _valueText(
          '共自查 ${_st.history.length} 次 · 自查「已解决」$nOk 次 · 「未解决 / 不确定」$nBad 次（同一错因在同一道题上两次「已解决」算已解决）',
        ),
      ),
      _Field(
        '解决记录（全部）',
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
    ]);
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

  /// 底部操作行（HTML `.work-acts`）：返回 / 收藏 / 归档 / 复制图片 /
  /// 保存图片 / 导出带答案版（B11-8）/ 上一题 / 下一题 /
  ///（编辑态：保存 / 取消）/ 删除。本页无「开始复习」按钮。
  /// B8-7：收进一张卡片（中性底），不再是白底上一条分隔线 + 漂浮按钮，
  /// 页面收尾有落点；按钮与文案原样。
  Widget _buildWorkActs(
    Question q, {
    required bool hasPrev,
    required bool hasNext,
  }) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    return SizedBox(
      width: double.infinity,
      child: Container(
        margin: EdgeInsets.only(
          top: DesignTokens.detailWorkActsMarginTop * scale,
        ),
        padding: EdgeInsets.all(14 * scale),
        decoration: BoxDecoration(
          color: palette.surface2,
          border: Border.all(color: palette.line),
          borderRadius: BorderRadius.circular(12 * scale),
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
            // B11-8：导出图片三动作，与收藏/归档/删除并列。
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
            SizedBox(width: 24 * scale),
            QmButton(
              label: '上一题',
              leadingGlyph: QmGlyphs.back,
              variant: QmButtonVariant.plain,
              onPressed: hasPrev
                  ? () {
                      final idx = _st.orderIds.indexOf(q.id);
                      _goTo(_st.orderIds[idx - 1]);
                    }
                  : null,
            ),
            QmButton(
              label: '下一题',
              trailingGlyph: '→',
              variant: QmButtonVariant.plain,
              onPressed: hasNext
                  ? () {
                      final idx = _st.orderIds.indexOf(q.id);
                      _goTo(_st.orderIds[idx + 1]);
                    }
                  : null,
            ),
            if (_editing) ...[
              QmButton(label: '保存', onPressed: _saveEdit),
              QmButton(
                label: '取消',
                variant: QmButtonVariant.plain,
                onPressed: _requestCancelEdit,
              ),
            ],
            QmButton(
              label: '删除',
              variant: QmButtonVariant.plain,
              onPressed: _askDelete,
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
