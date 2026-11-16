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
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/database.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../services/import_service.dart';
import '../../services/page_image_pipeline.dart';
import '../../services/question_export_service.dart';
import '../../services/yolo_onnx_service.dart';
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
    required this.onChanged,
    this.sourceLabel = '错题本',
    this.imageFailed = false,
    this.exportService,
    this.onGoReview,
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

  /// B11-8：导出服务（复制 / 保存 / 带答案版共用）。生产默认 new
  /// 一个真实服务；测试注入假实现（不弹系统对话框、不碰真实剪贴板）。
  final QuestionExportService? exportService;

  /// B11-11 顺手活：复习记录空状态的“去复习”按钮回调（app.dart 接
  /// _goReview，与首页/整理/报告页同款 onGoReview）。可选：不传时
  /// 不显示按钮（旧测试构造不传，保持兼容）。
  final VoidCallback? onGoReview;

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
  // 新学科显示成“数学”）。B8-1 扫尾：空表是删光学科后的合法状态，
  // 不再回退预设三科；首帧与读库后都以真实列表为准，空就是空。
  List<Subject> _subjects = const [];
  // 库里找学科：新学科用库里的名与色；找不到才回退 Subject.byId
  //（数学兜底，只发生在数据不一致时）。
  Subject _subjectOf(String id) =>
      _subjects.firstWhere((s) => s.id == id, orElse: () => Subject.byId(id));

  /// SR3-10：切片自愈的去重键（题 id + 切片路径 + 库里记的尺寸）与
  /// 进行中标志。只对同一组合校验一次：尺寸相符或自愈成功后不再
  /// 重复读盘；自愈失败时不记键，下次 _load 再试（用户仍可手动重框）。
  String? _sliceHealCheckedKey;
  bool _sliceHealRunning = false;

  bool _editing = false;
  bool _dirty = false;
  bool _answerVisible = false;

  /// B11-8：导出服务（构造注入的优先）与分享卡片的 RepaintBoundary key。
  late final QuestionExportService _exportService;
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
    _exportService = widget.exportService ?? QuestionExportService();
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
    final records = q == null
        ? <CauseRecord>[]
        : await widget.repo.causeRecordsFor(q.id);
    final history = q == null
        ? <({String result, DateTime reviewedAt})>[]
        : await widget.repo.reviewHistory(q.id);
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
      _subjects = subjects;
      _loading = false;
    });
    // SR3-10：打开详情页时自愈“库新图旧”的崩溃窗口（事务提交后、
    // rename 前被杀）。不 await：自愈是后台修复，不挡页面渲染；
    // 失败静默（见方法内注释），下次打开再试。
    if (q != null) _healSliceIfNeeded(q);
  }

  /// SR3-10（a）：校验磁盘切片的实际尺寸与库里 [sliceWidth] /
  /// [sliceHeight] 是否一致。不一致时按当前第一个 1 层框重裁一次、
  /// 原子替换切片文件；重裁尺寸与库里记的不一样时再把库里尺寸改成
  /// 重裁尺寸（框可能在崩溃后又被改过）。切片文件不存在时不处理
  /// （仍走原有的图加载失败占位）；页图缺失/损坏、框缺失时同样
  /// 静默放弃——用户仍可手动“重新框选”，打开页时不弹提示打扰。
  Future<void> _healSliceIfNeeded(Question q) async {
    if (q.slicePath == null || q.sliceWidth == null || q.sliceHeight == null) {
      return;
    }
    final key = '${q.id}|${q.slicePath}|${q.sliceWidth}x${q.sliceHeight}';
    if (key == _sliceHealCheckedKey || _sliceHealRunning) return;
    _sliceHealRunning = true;
    try {
      final sliceAbs = AppDatabase.resolveDataPath(q.slicePath!);
      if (sliceAbs == null) return;
      final sliceFile = File(sliceAbs);
      if (!sliceFile.existsSync()) return;
      final dims = pngDimensions(await sliceFile.readAsBytes());
      if (dims != null &&
          dims.width == q.sliceWidth &&
          dims.height == q.sliceHeight) {
        _sliceHealCheckedKey = key;
        return;
      }
      // 尺寸不符（或切片已不是合法 PNG）：按当前框重裁。
      if (q.pageImagePath == null) return;
      final pageAbs = AppDatabase.resolveDataPath(q.pageImagePath!);
      if (pageAbs == null || !File(pageAbs).existsSync()) return;
      final pageBytes = await File(pageAbs).readAsBytes();
      final boxes = await widget.repo.boxesForPageImage(q.pageImagePath!);
      final first = boxes
          .where((b) => b.questionId == q.id && b.layer == 1)
          .firstOrNull;
      if (first == null) return;
      final crop = await cropBoxPng(pageBytes, first);
      final tmpRel =
          'slices/${q.id}.tmp-heal-${DateTime.now().millisecondsSinceEpoch}-${math.Random().nextInt(1 << 32)}.png';
      final tmpAbs = AppDatabase.resolveDataPath(tmpRel);
      if (tmpAbs == null) return;
      await File(tmpAbs).parent.create(recursive: true);
      await File(tmpAbs).writeAsBytes(crop.png);
      try {
        await File(tmpAbs).rename(sliceAbs);
      } catch (_) {
        try {
          if (File(tmpAbs).existsSync()) await File(tmpAbs).delete();
        } catch (_) {}
        return;
      }
      await evictCachedFileImage(sliceAbs);
      if (crop.width != q.sliceWidth || crop.height != q.sliceHeight) {
        await widget.repo.save(
          q.copyWith(sliceWidth: crop.width, sliceHeight: crop.height),
        );
      }
      _sliceHealCheckedKey =
          '${q.id}|${q.slicePath}|${crop.width}x${crop.height}';
      if (mounted) await _load();
    } catch (e) {
      // 自愈是后台兜底：任何一步失败都不打扰用户、不抛到界面，
      // 只记日志；下次打开详情页（_load）会再试一次。
      debugPrint('SR3-10：切片自愈失败（${q.id}）：$e');
    } finally {
      _sliceHealRunning = false;
    }
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
    // SR-P2-27：旧数据里与固定枚举同名的自定义错因，读入编辑表单时
    // 就合并进固定项（不丢错因、不重复显示）；保存时写回即完成迁移。
    _editErrorTypes = {
      ...q.errorTypes,
      ...q.customErrorTypes.where((t) => ErrorTypes.fixed.contains(t)),
    };
    _editCustomTypes = q.customErrorTypes
        .where((t) => !ErrorTypes.fixed.contains(t))
        .toSet();
    _editFolders = q.folderIds.toSet();
    _editTags = q.tags.toSet();
    _editKps = q.knowledgePointIds.toSet();
    _editExamId = q.examId;
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
    final base = _editBase;
    if (base == null) return;
    // SR-P2-27：与固定枚举同名的自定义错因合并进固定项再保存（旧代码
    // 在这里直接滤掉，错因静默消失；新建入口已拦同名，这里是兜底，
    // 覆盖旧数据里已有的同名自定义项）。
    final fixedFromCustom = _editCustomTypes
        .where((t) => ErrorTypes.fixed.contains(t))
        .toList();
    final customNew = _editCustomTypes
        .where((t) => !ErrorTypes.fixed.contains(t))
        .toList();
    final errorTypes = {..._editErrorTypes, ...fixedFromCustom}.toList();
    final updated = Question(
      id: base.id,
      title: _titleCtrl.text.trim().isEmpty
          ? base.title
          : _titleCtrl.text.trim(),
      subjectId: base.subjectId,
      folderIds: _editFolders.toList(),
      examId: _editExamId,
      knowledgePointIds: _editKps.toList(),
      errorTypes: errorTypes,
      customErrorTypes: customNew,
      tags: _editTags.toList(),
      answer: _answerCtrl.text.trim().isEmpty ? null : _answerCtrl.text.trim(),
      explanation: _explanationCtrl.text.trim().isEmpty
          ? null
          : _explanationCtrl.text.trim(),
      notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
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
    // 重裁切片：先写临时文件再落库（SR2-3：旧写法先原地覆盖正式
    // 切片，事务失败时 catch 删掉的是刚覆盖掉旧图的唯一一份切片，
    // 题从此无图。改成临时文件 + 事务成功后 rename，失败只删临时
    // 文件，旧切片字节完好、框与题不动）。
    // SR3-11：读页图 + 裁切片同样可能失败（页图损坏截断、框落在图外），
    // 与写临时文件/事务/rename 三处同款包 try/catch，失败给提示并
    // return——旧代码这两步在 try 外，异常直接抛到按钮回调、无反馈。
    final ({Uint8List png, int width, int height}) crop;
    try {
      final pageBytes = await File(pageAbs).readAsBytes();
      final first = newLayer1.first;
      crop = await cropBoxPng(pageBytes, first);
    } catch (_) {
      if (mounted) _snack('重新框选失败：页图读不出来/切片裁不出来，请重试');
      return;
    }
    final sliceRel = ImportService.sliceRelative(q.id);
    final sliceAbs = AppDatabase.resolveDataPath(sliceRel);
    if (sliceAbs == null) {
      _snack('切片写不进去：数据目录不可用');
      return;
    }
    // 临时切片与正式切片同目录，rename 是同文件系统内的原子替换；
    // 随机后缀防两次重框撞名，也防失败残留被误删成他人的文件。
    // 进程在写临时文件与 rename 之间被杀会留一个孤儿临时文件，
    // 由 §4.5 孤儿扫描兜底（slices/ 下无引用文件）。
    // SR3-10：进程在事务提交后、rename 前被杀是另一个崩溃窗口——
    // 库里已是新切片尺寸、磁盘仍是旧图；孤儿扫描扫不到它（旧图仍被
    // slice_path 引用）。自愈在打开详情页时做（见 _healSliceIfNeeded）：
    // 切片实际尺寸与库里 sliceWidth/sliceHeight 不符就按当前框重裁。
    final tmpRel =
        'slices/${q.id}.tmp-${DateTime.now().millisecondsSinceEpoch}-${math.Random().nextInt(1 << 32)}.png';
    final tmpAbs = AppDatabase.resolveDataPath(tmpRel);
    if (tmpAbs == null) {
      _snack('切片写不进去：数据目录不可用');
      return;
    }
    try {
      await File(tmpAbs).parent.create(recursive: true);
      await File(tmpAbs).writeAsBytes(crop.png);
    } catch (_) {
      _snack('重新框选失败：切片写不进去');
      return;
    }
    // B3-P01：换框 + 保存切片一个事务（任一步失败一起回滚，
    // 不留“框换了、切片还是旧的”的不一致）。
    // SR2-3：事务失败时只删临时文件——正式路径上的旧切片从未被
    // 动过；B5 的旧写法此时删的是刚覆盖掉旧图的正式文件。
    try {
      await widget.repo.replaceQuestionBoxesAndSlice(
        q.id,
        newLayer1,
        slicePath: sliceRel,
        sliceWidth: crop.width,
        sliceHeight: crop.height,
      );
    } catch (e) {
      try {
        final file = File(tmpAbs);
        if (file.existsSync()) await file.delete();
      } catch (_) {}
      if (mounted) _snack('重新框选失败：保存失败，请重试');
      return;
    }
    // 事务成功后再把临时切片 rename 到正式路径（同目录原子替换），
    // 然后清 FileImage 缓存——缓存失效点随 rename 后移到此处
    // （旧写法在事务前清缓存，事务失败后详情页会把仍是旧图的正式
    // 文件当成新图重新解码，虽无数据丢失但缓存语义是错的）。
    try {
      await File(tmpAbs).rename(sliceAbs);
    } catch (_) {
      try {
        final file = File(tmpAbs);
        if (file.existsSync()) await file.delete();
      } catch (_) {}
      // 框与切片字段已提交，正式文件仍是旧切片：只报切片保存失败，
      // 不谎称全失败；重试重框即可恢复一致。
      if (mounted) _snack('重新框选失败：切片保存失败，框已更新，请重试');
      return;
    }
    await evictCachedFileImage(sliceAbs);
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

  /// B3：删除确认改用模态弹窗（与全项目统一）；取消编辑的确认仍是
  /// 下面的内联确认框（不是删除确认，不改）。
  Future<void> _askDelete() async {
    final q = _q;
    if (q == null) return;
    final subject = _subjectOf(q.subjectId);
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

  // ---------- B11-8 导出图片 ----------

  /// (a) 复制图片到剪贴板：读切片 PNG 字节，走 super_clipboard 写
  /// PNG（Windows 上按需转 DIB/DIBv5，原生应用可直接粘贴）。
  /// 无图（v1 演示题、切片文件缺失）给提示，不弹对话框。
  Future<void> _copyImage() async {
    final q = _q;
    if (q == null) return;
    final bytes = await _exportService.sliceBytes(q);
    if (bytes == null) {
      _snack('这道题没有图片可导出');
      return;
    }
    final ok = await _exportService.copyImageToClipboard(bytes);
    if (mounted) {
      _snack(ok ? '图片已复制到剪贴板' : '复制失败：当前环境不支持复制图片');
    }
  }

  /// (b) 保存图片为文件：file_picker 另存为对话框（PNG），取消不做
  /// 任何事；写盘失败给提示（桌面端 file_picker 只返回路径，文件
  /// 由服务自己写，与设置页备份同款做法）。
  Future<void> _saveImage() async {
    final q = _q;
    if (q == null) return;
    final bytes = await _exportService.sliceBytes(q);
    if (bytes == null) {
      _snack('这道题没有图片可导出');
      return;
    }
    final path = await _exportService.pickSavePath(
      dialogTitle: '保存题目图片',
      fileName: '${QuestionExportService.safeFileName(q.title)}.png',
    );
    if (path == null) return;
    final ok = await _exportService.saveBytesTo(path, bytes);
    if (mounted) _snack(ok ? '题目图片已保存' : '图片没存上，换个位置再试一次');
  }

  /// (c) 导出带答案版：先读切片字节，再弹预览框（题目图在上、
  /// 答案/解析在下，带学科/文件夹/错因小字）；用户在框里点“保存”，
  /// 卡片经 RepaintBoundary 转 PNG 后走同一套另存为（PNG）。
  /// 答案/解析为空时卡片显示“待补充”，不编造内容。
  Future<void> _exportShareCard() async {
    final q = _q;
    if (q == null) return;
    final bytes = await _exportService.sliceBytes(q);
    if (bytes == null) {
      _snack('这道题没有图片可导出');
      return;
    }
    if (!mounted) return;
    final subject = _subjectOf(q.subjectId);
    final folders = _folders
        .where((f) => q.folderIds.contains(f.id))
        .map((f) => f.name)
        .toList();
    final png = await showDialog<Uint8List>(
      context: context,
      builder: (ctx) => _ShareCardExportDialog(
        service: _exportService,
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
    final path = await _exportService.pickSavePath(
      dialogTitle: '保存带答案版图片',
      fileName: '${QuestionExportService.safeFileName(q.title)}-带答案.png',
    );
    if (path == null) return;
    final ok = await _exportService.saveBytesTo(path, png);
    if (mounted) {
      _snack(ok ? '带答案版已保存' : '带答案版没存上，换个位置再试一次');
    }
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
    // SR-P2-36：整科同名预检（新建不传 excludeId），命中提示“已经有了”
    // 并中止；仍留 StateError 捕获作兜底（预检与写入之间的竞态）。
    if (await widget.repo.folderNameExistsInSubject(q.subjectId, name)) {
      _snack('已经有了');
      return;
    }
    final id = newEntityId('folder-${q.subjectId}');
    try {
      await widget.repo.saveFolder(
        Folder(
          id: id,
          name: name,
          subjectId: q.subjectId,
          parentId: parentId,
          sortOrder: 0,
        ),
      );
    } on StateError {
      if (mounted) _snack('已经有了');
      return;
    }
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
    final id = newEntityId('kp-${q.subjectId}');
    await widget.repo.addKnowledgePoint(
      KnowledgePoint(
        id: id,
        subjectId: q.subjectId,
        chapter: chapter,
        name: name,
      ),
    );
    await _load();
    setState(() => _editKps.add(id));
    _markDirty();
  }

  Future<void> _newExam() async {
    final name = await _askText('新建试卷');
    if (name == null) return;
    final id = newEntityId('exam');
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
    // SR-P2-27：与固定枚举同名时直接选中对应固定项，不进自定义集合
    //（否则保存时被 customNew 滤掉、错因静默消失；整理页还会造成
    // allCauses 重复）。
    if (ErrorTypes.fixed.contains(name)) {
      setState(() => _editErrorTypes.add(name));
      _snack('“$name”是固定错误类型，已帮你选中');
      _markDirty();
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
                  subject: _subjectOf(q.subjectId),
                  failed: true,
                  maxHeight: imageMaxHeight,
                  onTap: _showZoom,
                )
              : QuestionSlice(
                  question: q,
                  subject: _subjectOf(q.subjectId),
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
        final record = _records.where((r) => r.cause == cause).firstOrNull;
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
    final subject = _subjectOf(q.subjectId);
    final folders = _folders.where((f) => q.folderIds.contains(f.id)).toList();
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
          final r = _records.where((x) => x.cause == c).firstOrNull;
          return r == null || r.status != CauseStatus.solved;
        }).length;
        return '已加入复习 · 待解决 $pending 个错因';
    }
    return null;
  }

  Widget _buildSection(String key, String title, Widget body) {
    final open = _expanded.contains(key);
    final q = _q;
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
    final hasAnswer = (q.answer ?? '').trim().isNotEmpty;
    final hasExplanation = (q.explanation ?? '').trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _formGrid([
          _Field(
            '答案',
            hasAnswer ? _valueText(q.answer!) : _supplement('answer'),
          ),
          _Field(
            '解析',
            hasExplanation
                ? _valueText(q.explanation!)
                : _supplement('explanation'),
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

  Widget _buildInfoSection(Question q) {
    if (_editing) return _buildInfoEdit(q);
    final exam = q.examId == null
        ? null
        : _exams.firstWhere(
            (e) => e.id == q.examId!,
            orElse: () => Exam(id: q.examId!, name: ''),
          );
    final folders = _folders.where((f) => q.folderIds.contains(f.id)).toList();
    final kps = _kps.where((k) => q.knowledgePointIds.contains(k.id)).toList();
    final subject = _subjectOf(q.subjectId);
    return _formGrid([
      _Field('学科（不能改）', _valueText(subject.name), hint: '导入时选定，详情和整理台都不能改'),
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
                kps.map((k) => '${subject.name} › ${k.name}').join('；'),
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
  }

  Widget _buildInfoEdit(Question q) {
    final scale = qmScaleOf(context);
    final subjectKps = _kps.where((k) => k.subjectId == q.subjectId).toList();
    final subjectFolders = _folders
        .where((f) => f.subjectId == q.subjectId)
        .toList();
    final customTypes = _editCustomTypes.where(
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
                        value: null,
                        child: Text('未关联试卷'),
                      ),
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
        final record = _records.where((r) => r.cause == cause).firstOrNull;
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
          '共解决错因 ${_history.length} 次 · 自查「已解决」$nOk 次 · 「未解决 / 不确定」$nBad 次（同一错因在同一道题上两次「已解决」算已解决）',
        ),
      ),
      _Field(
        '解决记录（全部）',
        _history.isEmpty ? _buildEmptyHistory() : Column(
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
