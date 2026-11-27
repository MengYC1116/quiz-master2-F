import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repository.dart';
import '../../models/models.dart';
import '../../modules/ocr/question_classifier.dart';
import '../../services/ocr_key_store.dart';
import '../../services/pdf_export/drift_export_source.dart';
import '../../services/pdf_export/export_flow.dart';
import '../../services/pdf_export/export_inventory.dart';
import '../../services/pdf_export/export_question_record.dart';
import '../../services/pdf_export/export_route.dart';
import '../../services/pdf_export/export_snapshot.dart';
import '../../services/pdf_export/export_versions.dart';
import '../../services/pdf_export/formula_rasterizer.dart';
import '../../services/pdf_export/pdf_delivery.dart';
import '../../services/pdf_export/pdf_export_service.dart';
import '../../services/word_export/word_delivery.dart';
import '../../services/word_export/word_export_service.dart';
import '../../state/detail_notifier.dart';
import '../../state/repository_provider.dart';
import '../../state/wrongbook_notifier.dart';
import '../../theme/app_theme.dart'; // 转出 design_tokens，本文件不再单引它。
import '../../widgets/entrance_animation.dart';
import '../../widgets/uikit.dart';
import '../../widgets/widgets.dart';
import 'export_confirm.dart';

part 'wrongbook_cover.dart';
part 'wrongbook_directory.dart';
part 'wrongbook_list.dart';
part 'wrongbook_shelf.dart';
part 'wrongbook_widgets.dart';

/// 导出 PDF 信息区用的排序文案（纯函数，可单测）：与结果头
/// sortLabel 同组排序值、不同措辞（这里是“时间新 → 旧”短式）。
/// FSRS 全量迁移包 4：错因状态两项改成到期时间两项，旧文案不得
/// 再印进 PDF。
String wrongbookExportSortText(String sort) => switch (sort) {
  'old' => '时间旧 → 新',
  'subj-asc' || 'subject' => '学科首字母 A → Z',
  'subj-desc' => '学科首字母 Z → A',
  'due-asc' => '到期时间 最近到期 → 最晚到期',
  'due-desc' => '到期时间 最晚到期 → 最近到期',
  _ => '时间新 → 旧',
};

/// 错题本：书架 → 目录页 → 题目列表（同一路由 /wrongbook）。
/// 已归档经书架顶部入口进跨学科列表；打开的书里另有本学科的已归档视图。
///
/// 视觉来源：HTML 原型 `viewNotebook` / `nbShelfHTML` / `nbTocHTML` /
/// `nbFiltered`（R6 重建）。页内无边距（外壳 26/30 为唯一内边距）；
/// 全部取 DesignTokens 与 UI Kit，文字符号，不用图标字体。
/// 业务口径沿用 repository 现有口径，不改动。
///
/// ARCH-PLAN-A 第 2 阶段（B 路）：外壳只负责把构造器接到的 `repo`
/// 注入 `repositoryProvider`（`app.dart` 仍传 `repo:` 进来，本阶段
/// 不碰 `app.dart`，故保留该参数；Provider 的默认值与根组件是
/// 同一单例库）。书架 / 目录 / 列表三个子页共用一个
/// `wrongbookProvider`（`lib/state/wrongbook_notifier.dart`），
/// 分页与筛选状态收进 Provider；内层 `_WrongbookView` 是
/// `ConsumerStatefulWidget`，只留 widget、输入框控制器与
/// 弹窗 / SnackBar 编排。D-32 的空状态双按钮（“去收集”进 /collect、
/// “去整理”进 /organize）行为不变，见 `_emptyCopy`
///（`wrongbook_list.dart`）。
class WrongbookPage extends StatefulWidget {
  const WrongbookPage({
    super.key,
    required this.repo,
    this.initialSubjectId,
    this.filterCause,
    this.filterKnowledgePointId,
    this.folderId,
    required this.onOpenHome,
    this.onGoSubjects,
    this.onGoCollect,
    this.onGoOrganize,
    required this.onOpenDetail,
    required this.onGoReview,
    this.onStartPracticeWithQuestions,
    this.exportControllerFactory,
    this.pendingSearch,
    this.onPendingSearchApplied,
  });

  final QuestionRepository repo;
  final String? initialSubjectId;
  final String? filterCause;
  final String? filterKnowledgePointId;

  /// 十九批 A：详情页右栏「打开列表 ›」跳进来时按该文件夹筛选
  ///（经 app.dart `_goWrongbookFiltered(folderId:)` 传入）。
  final String? folderId;
  final VoidCallback onOpenHome;

  /// B8-1：学科删空时书架空状态给出去学科管理的入口（可空；
  /// 测试里不传时只显示提示文字，不画按钮）。
  final VoidCallback? onGoSubjects;

  /// D-32：列表范围为空时空状态的“去收集 / 去整理”入口（可空；
  /// 测试里不传时回落到旧的单按钮“返回目录 / 返回书架”）。
  final VoidCallback? onGoCollect;
  final VoidCallback? onGoOrganize;
  final Future<void> Function(
    Question q,
    List<String> orderIds, {
    String? searchContext,
  })
  onOpenDetail;
  final void Function({String? subjectId}) onGoReview;

  /// P3 入口 1/3：带一批题 id 去复习页开专项练习（只练不排，不建
  /// FSRS 卡）。可空：不传时“立即专项练习”回落到去复习页（选题页）。
  final void Function(List<String> questionIds, {int? count})?
  onStartPracticeWithQuestions;

  /// 十六批 B（D-190）：导出流程控制器的测试注入口（widget 测试传
  /// 桩控制器，避免碰真实数据库；生产传 null，走下面的真实构建）。
  final ExportFlowController Function()? exportControllerFactory;

  /// 十九批 A4：命令面板在别的页面呼出时，app 把待应用的查找条
  /// 件放在这里（({conditions, label})；页面已挂载时直接应用、
  /// 未挂载时挂载后在 initState 里应用，见 _WrongbookViewState）。
  final ({Map<String, dynamic> conditions, String label})? pendingSearch;

  /// pendingSearch 应用完的回调（app 收到后清掉自己的待应用字段，
  /// 防止重建时重复应用；只在真正应用了一次后调一次）。
  final VoidCallback? onPendingSearchApplied;

  @override
  State<WrongbookPage> createState() => _WrongbookPageState();
}

class _WrongbookPageState extends State<WrongbookPage> {
  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(widget.repo),
        wrongbookInitialProvider.overrideWithValue(
          WrongbookInitial(
            subjectId: widget.initialSubjectId,
            filterCause: widget.filterCause,
            filterKnowledgePointId: widget.filterKnowledgePointId,
            filterFolderId: widget.folderId,
          ),
        ),
      ],
      child: _WrongbookView(
        onOpenHome: widget.onOpenHome,
        onGoSubjects: widget.onGoSubjects,
        onGoCollect: widget.onGoCollect,
        onGoOrganize: widget.onGoOrganize,
        onOpenDetail: widget.onOpenDetail,
        onGoReview: widget.onGoReview,
        onStartPracticeWithQuestions: widget.onStartPracticeWithQuestions,
        exportControllerFactory: widget.exportControllerFactory,
        pendingSearch: widget.pendingSearch,
        onPendingSearchApplied: widget.onPendingSearchApplied,
      ),
    );
  }
}

class _WrongbookView extends ConsumerStatefulWidget {
  const _WrongbookView({
    required this.onOpenHome,
    this.onGoSubjects,
    this.onGoCollect,
    this.onGoOrganize,
    required this.onOpenDetail,
    required this.onGoReview,
    this.onStartPracticeWithQuestions,
    this.exportControllerFactory,
    this.pendingSearch,
    this.onPendingSearchApplied,
  });

  final VoidCallback onOpenHome;
  final VoidCallback? onGoSubjects;
  final VoidCallback? onGoCollect;
  final VoidCallback? onGoOrganize;
  final Future<void> Function(
    Question q,
    List<String> orderIds, {
    String? searchContext,
  })
  onOpenDetail;
  final void Function({String? subjectId}) onGoReview;
  final void Function(List<String> questionIds, {int? count})?
  onStartPracticeWithQuestions;
  final ExportFlowController Function()? exportControllerFactory;
  final ({Map<String, dynamic> conditions, String label})? pendingSearch;
  final VoidCallback? onPendingSearchApplied;

  @override
  ConsumerState<_WrongbookView> createState() => _WrongbookViewState();
}

class _WrongbookViewState extends ConsumerState<_WrongbookView> {
  /// 业务数据（读）：只在 build 里用（`ref.watch` 只能在 build 里调）。
  WrongbookState get _s => ref.watch(wrongbookProvider);

  /// 业务数据（读）：事件回调里用（`ref.read`，不订阅重建）。
  WrongbookState get _sr => ref.read(wrongbookProvider);

  /// 业务逻辑（写）：事件回调里用。
  WrongbookNotifier get _n => ref.read(wrongbookProvider.notifier);

  final _searchCtrl = TextEditingController();
  final _folderSearchCtrl = TextEditingController();
  final _newFolderCtrl = TextEditingController();
  final _renameCtrl = TextEditingController();

  /// 十九批 A3：「＋ 存当前条件」命名对话框的控制器（FR-15 同款
  /// 字段持有：showDialog await 返回后立即 dispose，退出动画重建
  /// TextField 时会抛 “used after being disposed”）。
  final _saveSearchNameCtrl = TextEditingController();

  /// FR-15：批量加标签弹窗的控制器改字段持有（与详情页同款原因：
  /// showDialog await 返回后立即 dispose，退出动画重建 TextField 时
  /// 会抛 “used after being disposed”）。下次打开弹窗时先释放上一个，
  /// 页面 dispose 时释放最后一个。
  TextEditingController? _batchAddTagCtrl;

  // ---------- 十六批 B：错题本直接勾选导出（D-190） ----------

  /// 导出流程控制器（懒建；测试注入口优先，见
  /// [WrongbookPage.exportControllerFactory]）。
  ExportFlowController? _exportController;

  /// 公式栅格化器（打开确认步时创建 + 挂载，收尾时卸载；只在
  /// 生成时用到，后台盘点不需要它）。
  FormulaRasterizer? _exportRasterizer;

  /// 十七批 P2（D-208）：导出模式（页面本地状态，不进 Provider；
  /// 选择仍在 Notifier 的 exportSelected 里，不动其语义）。
  /// 模式里点一行即切换导出选中、不进详情；模式外点行照常进详情。
  bool _exportMode = false;

  /// 方案 A 批量栏：批量删除两段确认的待确认态（第一下只改文案
  /// 「再点一次确认删除 N 道」，第二下才真正执行）。点别处（删除
  /// 按钮外的 TapRegion）/ 进出批量 / 退出批量 / 清除选择 / 执行
  /// 后都复位；文案里的 N 始终取当前已选数。
  bool _deleteArmed = false;

  /// 进入导出模式：与批量模式互斥——进导出模式时退出批量模式
  ///（批量勾选一并清空，与“退出批量”同款语义）；导出已选保留。
  /// P3：加题选择（reviewSelected）与批量选择同进同出，一并清空。
  void _enterExportMode() {
    if (_sr.batchMode) {
      _deleteArmed = false;
      _n.update(
        (st) => st.copyWith(
          batchMode: false,
          selected: const <String>{},
          reviewSelected: const <String>{},
          reviewSelectAllFiltered: false,
          reviewFilterKey: null,
        ),
      );
    }
    setState(() {
      _exportMode = true;
    });
    _snack('已进入导出模式：点题行选中，再点一次取消选中');
  }

  /// 退出导出模式：已选保留，再进模式还能看到（D-208 定）。
  void _exitExportMode() {
    setState(() {
      _exportMode = false;
    });
  }

  /// 批量模式开关（D-217：与导出模式彻底互斥）：进批量时退出
  /// 导出模式，导出已选也清空——D-209 的「取消保留已选」只适用
  /// 于点「取消」退出导出模式，不适用于进批量模式；开关本身的
  /// 语义（切换 batchMode 并清空批量勾选）与原来工具栏芯片一致。
  void _toggleBatchMode() {
    _deleteArmed = false;
    final entering = !_sr.batchMode;
    if (entering && _exportMode) {
      setState(() {
        _exportMode = false;
      });
    }
    _n.update(
      (st) => st.copyWith(
        batchMode: !st.batchMode,
        selected: const <String>{},
        // P3：加题选择与批量选择同进同出，进/出批量都清空。
        reviewSelected: const <String>{},
        reviewSelectAllFiltered: false,
        reviewFilterKey: null,
      ),
    );
    if (entering) {
      // D-217：进批量清空导出已选（走 Notifier 的 clearExportSelected，
      // 不绕开它改状态）。
      _n.clearExportSelected();
    }
  }

  @override
  void initState() {
    super.initState();
    _maybeApplyPendingSearch();
  }

  @override
  void didUpdateWidget(covariant _WrongbookView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pendingSearch != null &&
        !identical(widget.pendingSearch, oldWidget.pendingSearch)) {
      _maybeApplyPendingSearch();
    }
  }

  /// 十九批 A4：应用 app 传来的待应用查找（命令面板在别的页面
  /// 呼出时）。挂载后（initState）或已挂载收到新值时
  ///（didUpdateWidget，identity 守门防重建重复应用）各应用一次；
  /// 应用完调 onPendingSearchApplied，让 app 清掉自己的字段。
  /// 找到的题不在当前筛选里时 Notifier 会按条件重算列表；搜索框
  /// 文字由 _applySearchConditions 同步。
  ///
  /// 跟进批第 8 项：initState / didUpdateWidget 里同步写 provider，
  /// Riverpod 3.5 只在 debug 下拦 build 期写 provider，widget
  /// 测试里写操作被拒、查找不应用、toast 不出。整个应用一步
  ///（写 provider + 同步搜索框 + toast）延后到首帧后，内容与
  /// 顺序不变；清字段的回调与应用放进同一帧回调，先应用、再清。
  void _maybeApplyPendingSearch() {
    final pending = widget.pendingSearch;
    if (pending == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applySearchConditions(
        pending.conditions,
        label: pending.label,
        toast: '已用命令面板打开查找：${pending.label}',
      );
      widget.onPendingSearchApplied?.call();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _folderSearchCtrl.dispose();
    _newFolderCtrl.dispose();
    _renameCtrl.dispose();
    _saveSearchNameCtrl.dispose();
    _batchAddTagCtrl?.dispose();
    _exportRasterizer?.detach();
    super.dispose();
  }

  // ---------- 导航与范围（输入框控制器由这里清，字段由 Notifier 清） ----------

  /// 清搜索与筛选（不包 setState，供 _openList / _openDirectory 等
  /// 调用；文件夹 / 学科是列表的归属范围，不是筛选，不清）。
  void _clearFilters() {
    _searchCtrl.clear();
    _n.clearFilters();
  }

  /// “重置”按钮：清搜索与筛选，排序固定回时间新→旧
  ///（SR-P2-58 决定 (a)），不是设置默认值。
  void _resetFilters() {
    _searchCtrl.clear();
    _n.resetFilters();
  }

  void _openList({String? subjectId, String? folderId}) {
    _clearFilters();
    _n.openList(subjectId: subjectId, folderId: folderId);
  }

  void _openDirectory(String subjectId) {
    _clearFilters();
    _folderSearchCtrl.clear();
    _newFolderCtrl.clear();
    _n.openDirectory(subjectId);
  }

  void _openShelf() {
    _clearFilters();
    _n.openShelf();
  }

  // ---------- 十六批 B：错题本直接勾选导出（D-190） ----------

  /// 勾选的题目（filteredAll() 顺序在前，其余——换筛选后不在当前
  /// 结果里的已勾选题——按 createdAt 降序、id 升序排在后面；
  /// 题号按此顺序编）。
  List<Question> _exportSelectedQuestions(WrongbookState st) {
    final order = st.filteredAll().map((q) => q.id).toList();
    final qs = st.questions
        .where((q) => st.exportSelected.contains(q.id))
        .toList();
    qs.sort((a, b) {
      final ia = order.indexOf(a.id);
      final ib = order.indexOf(b.id);
      final c =
          (ia < 0 ? 1 << 20 : ia).compareTo(ib < 0 ? 1 << 20 : ib);
      if (c != 0) return c;
      // 确定性次键：Dart List.sort 不保证等键稳定，筛选外已选题
      // 共用键 1 << 20，相对顺序可能变化；按 createdAt 降序、
      // 再按 id 升序，保证全序（题号顺序可复现）。
      final byTime = b.createdAt.compareTo(a.createdAt);
      if (byTime != 0) return byTime;
      return a.id.compareTo(b.id);
    });
    return qs;
  }

  /// 列表行点选 / 汇总条「全选本页」共用：点选第 51 道时返回
  /// 拒绝（页面弹 SnackBar，「全选本页」收到拒绝就停）；其余
  /// 情况返回 null 表示成功。
  String? _toggleExportSelected(String id) {
    final msg = _n.toggleExportSelected(id);
    if (msg != null) _snack(msg);
    return msg;
  }

  /// 导出流程控制器（懒建；测试注入口优先，生产走真实构建）。
  ExportFlowController _ensureExportController() {
    final existing = _exportController;
    if (existing != null) return existing;
    final factory = widget.exportControllerFactory;
    if (factory != null) {
      return _exportController = factory();
    }
    const source = DriftExportQuestionSource();
    final delivery = PdfDeliveryService();
    final wordDelivery = WordDeliveryService();
    final controller = ExportFlowController(
      computeInventory:
          ({
            required List<String> ids,
            required List<ExcludedQuestion> excluded,
            required int circledCount,
          }) async {
            final decision = await resolveExportRouteFromStore(
              OcrKeyStore(),
            );
            final records = <ExportQuestionRecord>[];
            for (final id in ids) {
              final record = await source.fetchQuestion(id);
              records.add(
                record ??
                    ExportQuestionRecord(
                      id: id,
                      title: '',
                      subjectId: '',
                      contentVersion: 0,
                    ),
              );
            }
            return runInventory(
              decision: decision,
              circledCount: circledCount,
              selected: records,
              excluded: excluded,
              source: source,
            );
          },
      generateVersions:
          ({
            required List<String> ids,
            required List<ExcludedQuestion> excluded,
            required String filterText,
            required String sortText,
            required ExportVersionSelection versions,
            required int circledCount,
            required ExportCancellationToken token,
            void Function(int done, int total, String label)? onProgress,
            String subjectName = '多学科',
            String? folderName,
            bool excludeLowDpi = false,
          }) {
            final rasterizer = _exportRasterizer;
            if (rasterizer == null) {
              throw StateError('公式栅格化器未挂载');
            }
            final subjectsById = {
              for (final s in _sr.subjects) s.id: s,
            };
            final service = PdfExportService(
              source: source,
              rasterizer: rasterizer,
              subjectName: subjectName,
              excludeLowDpi: excludeLowDpi,
              sourceTextFor: (record) => formatExportSourceText(
                subjectName:
                    subjectsById[record.subjectId]?.name ?? '',
                folderNames: record.folderNames,
                examName: record.examName,
              ),
            );
            return service.generateVersions(
              ids: ids,
              excluded: excluded,
              filterText: filterText,
              sortText: sortText,
              versions: versions,
              circledCount: circledCount,
              token: token,
              onProgress: onProgress,
            );
          },
      deliverAll: ({required List<VersionDeliveryRequest> requests}) =>
          delivery.deliverAll(requests: requests),
      // 十六批 C（D-194）：Word 生成 + 交付，与 PDF 同一套
      // source / rasterizer / sourceTextFor / subjectName /
      // excludeLowDpi（只换服务类与交付类）。
      generateWord:
          ({
            required List<String> ids,
            required List<ExcludedQuestion> excluded,
            required String filterText,
            required String sortText,
            required ExportVersionSelection versions,
            required int circledCount,
            required ExportCancellationToken token,
            void Function(int done, int total, String label)? onProgress,
            String subjectName = '多学科',
            String? folderName,
            bool excludeLowDpi = false,
          }) {
            final rasterizer = _exportRasterizer;
            if (rasterizer == null) {
              throw StateError('公式栅格化器未挂载');
            }
            final subjectsById = {
              for (final s in _sr.subjects) s.id: s,
            };
            final service = WordExportService(
              source: source,
              rasterizer: rasterizer,
              subjectName: subjectName,
              excludeLowDpi: excludeLowDpi,
              sourceTextFor: (record) => formatExportSourceText(
                subjectName:
                    subjectsById[record.subjectId]?.name ?? '',
                folderNames: record.folderNames,
                examName: record.examName,
              ),
            );
            return service.generateVersions(
              ids: ids,
              excluded: excluded,
              filterText: filterText,
              sortText: sortText,
              versions: versions,
              circledCount: circledCount,
              token: token,
              onProgress: onProgress,
            );
          },
      deliverWord:
          ({
            required Uint8List docxBytes,
            required String fileName,
            required int expectedImageCount,
          }) => wordDelivery.deliver(
            docxBytes: docxBytes,
            fileName: fileName,
            expectedImageCount: expectedImageCount,
          ),
      openFile: delivery.openPdf,
      // 二十批 P7：Android 独立「打开 PDF」按钮的详细结果通道
      //（失败原因带回完成界面 SnackBar；桌面端不用它）。
      openPdfDetailed: delivery.openPdfWithResult,
      openFolder: delivery.openContainingFolder,
      shareFile: (path) => delivery.sharePdf(path),
    );
    return _exportController = controller;
  }

  /// 打开导出确认步（列表页工具栏「导出」与汇总条「导出」共用入口）。
  ///
  /// 打开瞬间拍一份按 filteredAll() 顺序排的全集快照（快照取自
  /// exportSelected 全集，filteredAll() 只定顺序）；确认步内的
  /// 盘点 / 生成只用这份快照，生成过程中用户改筛选 / 改题均不影
  /// 响本次导出。公式栅格化器在打开时挂载、收尾时卸载；生成在后
  /// 台跑，面板关闭不取消（会话终态时再次弹出完成界面）。生成
  /// 完成（done，含部分成功）后清空本次勾选与汇总盘点。
  void _openExportConfirm() {
    final st = _sr;
    final selectedQs = _exportSelectedQuestions(st);
    if (selectedQs.isEmpty) {
      _snack('先选要导出的题目');
      return;
    }
    _exportRasterizer ??= FormulaRasterizer()..resetCancellation();
    _exportRasterizer!.attach(context);
    final controller = _ensureExportController();
    final subject = st.subjectId == null
        ? null
        : st.subjectOf(st.subjectId!);
    final folder = st.folderId == null
        ? null
        : st.folders.firstWhere(
            (f) => f.id == st.folderId!,
            orElse: () => Folder(
              id: st.folderId!,
              name: '',
              subjectId: st.subjectId ?? '',
            ),
          );
    final subjectName = subject?.name ?? '多学科';
    final folderName = folder != null && folder.name.isNotEmpty
        ? folder.name
        : null;
    final filterParts = <String>[];
    if (subject != null) filterParts.add('学科：${subject.name}');
    if (folderName != null) filterParts.add('文件夹：$folderName');
    final sortText = wrongbookExportSortText(st.sort);
    final session = ExportConfirmSession(
      controller: controller,
      input: ExportConfirmInput(
        questions: selectedQs,
        subjects: st.subjects,
        folders: st.folders,
        sortText: sortText,
        filterText: filterParts.isEmpty ? '全部题目' : filterParts.join('；'),
        subjectName: subjectName,
        folderName: folderName,
        circledCount: st.filteredAll().length,
      ),
      onOpenQuestion: (questionId) {
        final q = st.questions
            .where((x) => x.id == questionId)
            .firstOrNull;
        if (q == null) return;
        Navigator.of(context).pop();
        unawaited(
          widget.onOpenDetail(q, selectedQs.map((e) => e.id).toList()),
        );
      },
      onFinished: () {
        if (controller.phase == ExportFlowPhase.done) {
          _n.clearExportSelected();
          // 十七批 P2（D-208）：导出成功后退出导出模式（现行清空
          // 行为保留，另加退模式；确认步取消回来则留在模式里）。
          if (_exportMode && mounted) {
            setState(() {
              _exportMode = false;
            });
          }
        }
        _exportRasterizer?.detach();
        _exportRasterizer = null;
      },
    );
    session.show(context);
  }


  void _snack(String msg, {String? actionLabel, VoidCallback? onAction}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        action: actionLabel == null
            ? null
            : SnackBarAction(
                label: actionLabel,
                onPressed: onAction ?? () {},
              ),
      ),
    );
  }

  // ---------- 文件夹操作（弹窗留页面，写库走 Notifier） ----------

  Future<void> _addFolder({String? parentId}) async {
    final msg = await _n.addFolder(
      parentId: parentId,
      name: _newFolderCtrl.text.trim(),
    );
    if (msg != null) {
      _snack(msg);
      return;
    }
    _newFolderCtrl.clear();
  }

  Future<void> _saveRename(Folder f) async {
    final name = _renameCtrl.text.trim();
    if (name.isEmpty || name == f.name) {
      _n.update((st) => st.copyWith(renamingId: null));
      return;
    }
    final msg = await _n.saveRename(f, name);
    if (msg != null) {
      // 整科判重拦下：改名框保持打开、让用户换个名字，不当未知错误报。
      _snack(msg);
      return;
    }
    _n.update((st) => st.copyWith(renamingId: null));
  }

  /// B3：文件夹删除确认（模态 AlertDialog；标题/说明文案与原来行内
  /// 确认条一致：只在该文件夹的题数、多文件夹的题数、子文件夹数）。
  Future<void> _askDeleteFolder(Folder f) async {
    final only = _sr.folderDeleteCount(f.id);
    final multi = _sr.folderDeleteMultiCount(f.id);
    final kidN = _sr.subFolders(f.id).length;
    final subject = _sr.subjectOf(f.subjectId);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          '删除这个文件夹会删掉其中 $only 道题（只在这个文件夹里的）'
          '${multi > 0 ? '，另外 $multi 道题还在别的文件夹里、只是从这个文件夹移走' : ''}'
          '${kidN > 0 ? '，它下面的 $kidN 个子文件夹也会一起删掉' : ''}，删了就没了，确定吗？',
        ),
        content: Text(
          '要删的是${subject.name}的文件夹「${f.name}」，只删这一科的，其他学科的同名文件夹不受影响。',
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
    if (ok == true && mounted) await _n.deleteFolderConfirmed(f);
  }

  Future<void> _moveSelected() async {
    final msg = await _n.moveSelected();
    if (mounted) _snack(msg);
  }

  Future<void> _reorderFolder(
    Folder dragged,
    String? parentId,
    int toIndex,
  ) async {
    final msg = await _n.reorderFolder(dragged, parentId, toIndex);
    if (msg != null && mounted) _snack(msg);
  }

  Future<void> _applyDrop(
    Folder dragged,
    Folder? target,
    FolderDropKind kind,
  ) async {
    final msg = await _n.applyDrop(dragged, target, kind);
    if (msg != null && mounted) _snack(msg);
  }

  // ---------- 批量操作（弹窗留页面，写库与汇总走 Notifier） ----------

  /// 批量全选 / 全不选（复选框与「全选（整理、复习、删除）」文案共用：点文案也切换）。
  void _toggleSelectAll(List<Question> all) {
    _n.toggleSelectAll(all);
  }

  Future<void> _batchAddTag() async {
    final tags = _sr.allTags.toSet();
    final picked = <String>{};
    // FR-15：字段持有（见字段注释）；开新弹窗前释放上一个。
    _batchAddTagCtrl?.dispose();
    final newCtrl = _batchAddTagCtrl = TextEditingController();
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
            QmButton(
              label: '确定',
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final msg = await _n.batchAddTag(
      picked: picked,
      newName: newCtrl.text.trim().isEmpty ? null : newCtrl.text.trim(),
    );
    if (msg != null && mounted) _snack(msg);
  }

  Future<void> _batchMoveToFolder([String? targetId]) async {
    final resolved = targetId ?? _sr.batchFolderId;
    if (resolved == null) return;
    final msg = await _n.batchMoveToFolder(resolved);
    if (mounted) _snack(msg);
  }

  Future<void> _batchMoveOut() async {
    final msg = await _n.batchMoveOut();
    if (msg != null && mounted) _snack(msg);
  }

  Future<void> _batchFavorite() async {
    final msg = await _n.batchFavorite();
    if (mounted) _snack(msg);
  }

  Future<void> _batchArchive() async {
    final msg = await _n.batchArchive();
    if (mounted) _snack(msg);
  }

  /// P3 入口 1“加入复习”：批量入池（FSRS 卡片 + 错因记录播种），
  /// 已在池的自动跳过，结果报“新增 N 道，M 道已跳过”。
  Future<void> _batchJoinReviewFsrs() async {
    final r = await _n.joinReviewFsrs();
    if (mounted) {
      _snack(
        r.message,
        actionLabel: r.showReviewAction ? '开始复习' : null,
        onAction: r.showReviewAction ? () => widget.onGoReview() : null,
      );
    }
  }

  /// P3 入口 1“全部加入复习”（2026-11-25 Meng 定：两按钮都加）：
  /// 作用域 = 当前筛选出的全部题，不限当前页、不用先勾选；
  /// 已在池的自动跳过，结果文案与“加入复习”同口径。
  Future<void> _batchJoinReviewFsrsAll() async {
    final r = await _n.joinReviewFsrsAll();
    if (mounted) {
      _snack(
        r.message,
        actionLabel: r.showReviewAction ? '开始复习' : null,
        onAction: r.showReviewAction ? () => widget.onGoReview() : null,
      );
    }
  }

  /// P3 入口 1“立即专项练习”：只练不排，不建 FSRS 卡；带题 id 去
  /// 复习页开专项练习（已有未完成正式复习会话时由复习页按单行表
  /// review_state 判定：暂停保留或提示先处理，不丢断点）。
  void _startPracticeFromReview() {
    final ids = _n.practiceIdsFromReviewSelection();
    if (ids.isEmpty) return;
    final start = widget.onStartPracticeWithQuestions;
    if (start != null) {
      start(ids);
    } else {
      widget.onGoReview();
    }
  }

  /// 批量取消加入复习（B11-6，勾选版）。
  Future<void> _batchCancelReviewSelected() async {
    final msg = await _n.batchCancelReviewSelected();
    if (mounted) _snack(msg);
  }

  /// 方案 A 批量栏：复位批量删除待确认态（供列表 part 的 TapRegion
  /// 用；extension 里调不了受保护的 setState，复位走这里）。
  void _disarmBatchDelete() {
    if (_deleteArmed) {
      setState(() {
        _deleteArmed = false;
      });
    }
  }

  /// 方案 A 批量栏：批量删除两段确认（替代旧 B3 模态弹窗）。第一下
  /// 只把按钮文案改成「再点一次确认删除 N 道」（N 取当前已选数）；
  /// 第二下真正执行（Notifier 的 batchDeleteConfirmed 执行并清空
  /// 通用选择）并复位待确认态。
  Future<void> _onBatchDeleteTap() async {
    if (!_deleteArmed) {
      setState(() {
        _deleteArmed = true;
      });
      return;
    }
    setState(() {
      _deleteArmed = false;
    });
    final msg = await _n.batchDeleteConfirmed();
    if (mounted) _snack(msg);
  }

  /// 方案 A 批量栏「清除选择」：通用选择与加题选择一并清空（与旧栏
  /// 同款语义），并复位删除待确认态。
  void _clearBatchSelection() {
    _deleteArmed = false;
    _n.update(
      (st) => st.copyWith(
        selected: const <String>{},
        reviewSelected: const <String>{},
        reviewSelectAllFiltered: false,
        reviewFilterKey: null,
      ),
    );
  }

  /// 方案 A 批量栏「退出批量」：退批量模式并清空两套选择（与旧栏
  /// 同款语义），并复位删除待确认态。
  void _exitBatchMode() {
    _deleteArmed = false;
    _n.update(
      (st) => st.copyWith(
        batchMode: false,
        selected: const <String>{},
        reviewSelected: const <String>{},
        reviewSelectAllFiltered: false,
        reviewFilterKey: null,
      ),
    );
  }

  Future<void> _restoreArchived(Question q) async {
    await _n.restoreArchived(q);
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    if (_s.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final view = switch (_s.view) {
      WrongbookView.shelf => _buildShelf(),
      WrongbookView.directory => _buildDirectory(),
      WrongbookView.list => _buildList(),
      WrongbookView.archived => _buildArchived(),
    };
    // 读库失败（SR-P2-48）：首次加载即失败时出错误页（横幅 + 重试）；
    // 已有内容时在内容上方出横幅，留住旧内容。
    if (_s.loadError && !_s.errorDismissed) {
      final banner = QmBanner(
        tone: QmBannerTone.error,
        message: '错题本数据读取失败，已显示上次成功加载的内容。',
        actions: [
          QmBannerAction(label: '重试', onPressed: () => _n.retryLoad()),
        ],
        onDismiss: () => _n.dismissLoadError(),
      );
      if (!_s.hasLoaded) {
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
    // 二十二批 D-247：错题本入场上移淡入（列表/归档/书架/目录共用）。
    return EntranceFadeSlide(child: view);
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
    final subject = _s.subjectOf(subjectId);
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
