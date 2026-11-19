import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repository.dart';
import '../../models/models.dart';
import '../../modules/ocr/question_classifier.dart';
import '../../state/repository_provider.dart';
import '../../state/wrongbook_notifier.dart';
import '../../theme/app_theme.dart'; // 转出 design_tokens，本文件不再单引它。
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
    required this.onOpenHome,
    this.onGoSubjects,
    this.onGoCollect,
    this.onGoOrganize,
    required this.onOpenDetail,
    required this.onGoReview,
  });

  final QuestionRepository repo;
  final String? initialSubjectId;
  final String? filterCause;
  final String? filterKnowledgePointId;
  final VoidCallback onOpenHome;

  /// B8-1：学科删空时书架空状态给出去学科管理的入口（可空；
  /// 测试里不传时只显示提示文字，不画按钮）。
  final VoidCallback? onGoSubjects;

  /// D-32：列表范围为空时空状态的“去收集 / 去整理”入口（可空；
  /// 测试里不传时回落到旧的单按钮“返回目录 / 返回书架”）。
  final VoidCallback? onGoCollect;
  final VoidCallback? onGoOrganize;
  final Future<void> Function(Question q, List<String> orderIds) onOpenDetail;
  final void Function({String? subjectId}) onGoReview;

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
  });

  final VoidCallback onOpenHome;
  final VoidCallback? onGoSubjects;
  final VoidCallback? onGoCollect;
  final VoidCallback? onGoOrganize;
  final Future<void> Function(Question q, List<String> orderIds) onOpenDetail;
  final void Function({String? subjectId}) onGoReview;

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

  /// FR-15：批量加标签弹窗的控制器改字段持有（与详情页同款原因：
  /// showDialog await 返回后立即 dispose，退出动画重建 TextField 时
  /// 会抛 “used after being disposed”）。下次打开弹窗时先释放上一个，
  /// 页面 dispose 时释放最后一个。
  TextEditingController? _batchAddTagCtrl;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _folderSearchCtrl.dispose();
    _newFolderCtrl.dispose();
    _renameCtrl.dispose();
    _batchAddTagCtrl?.dispose();
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

  /// 批量全选 / 全不选（复选框与「全选当前结果」文案共用：点文案也切换）。
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

  /// 批量加入复习（B11-6，勾选版）：只加未解决的错因。
  Future<void> _batchJoinReviewSelected() async {
    final r = await _n.batchJoinReviewSelected();
    if (mounted) {
      _snack(
        r.message,
        actionLabel: r.showReviewAction ? '开始复习' : null,
        onAction: r.showReviewAction ? () => widget.onGoReview() : null,
      );
    }
  }

  /// 全部加入（B11-6）：作用域 = 当前筛选出的全部题，不是全库，
  /// 也不限当前页；不用先勾选。
  Future<void> _batchJoinReviewAll(List<Question> all) async {
    final r = await _n.batchJoinReviewAll(all);
    if (mounted) {
      _snack(
        r.message,
        actionLabel: r.showReviewAction ? '开始复习' : null,
        onAction: r.showReviewAction ? () => widget.onGoReview() : null,
      );
    }
  }

  /// 批量取消加入复习（B11-6，勾选版）。
  Future<void> _batchCancelReviewSelected() async {
    final msg = await _n.batchCancelReviewSelected();
    if (mounted) _snack(msg);
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
    if (ok == true && mounted) {
      final msg = await _n.batchDeleteConfirmed();
      if (mounted) _snack(msg);
    }
  }

  Future<void> _toggleFavorite(Question q) async {
    await _n.toggleFavorite(q);
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
