// ARCH-PLAN-A 第 2 阶段（B 路）：错题本页的状态层。
//
// 状态是 [WrongbookState]（书架 / 目录 / 列表三个子页共用；
// 唯一真源仍是 SQLite；本 Provider 只做“响应式读取 + 写回”，
// 不另存一份）。读：`ref.watch(wrongbookProvider)`；
// 写：`ref.read(wrongbookProvider.notifier).openDirectory(...)` 等。
//
// 页面本地 State（不进 Provider）：四个输入框的控制器
// （搜索 / 目录搜索 / 新文件夹 / 改名）与弹窗、SnackBar、
// 路由回调（`onOpenDetail` / `onGoReview` / `onGoCollect` /
// `onGoOrganize` / `onGoSubjects` / `onOpenHome`）——
// 见 `wrongbook_page.dart`。分页与筛选状态按方案 §四第 2 阶段
// 收进 Provider（与 D-34 注意 ① 的一般划分不同，本页以方案
// 第 2 阶段的明确要求为准）。
//
// 约定：
// - 纯界面字段改动走 [WrongbookNotifier.update]（`copyWith` 描述
//   新状态）；业务动作（读库、写库、多步编排）走具名方法。
// - 写库方法返回要弹的提示文案（`String?`，null 表示静默成功）；
//   批量加入复习返回 `({String message, bool showReviewAction})`，
//   页面据此决定 SnackBar 是否带“开始复习”入口。
//   方法只返回结果，不碰 BuildContext、不弹 Dialog、不调导航。
// - 角标走 `badgeCountsProvider`（第 4 阶段：订阅 `DataChangeBus`，
//   见 `badge_counts_provider.dart`）。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/data_change_events.dart';
import '../data/repository.dart';
import '../models/models.dart';
import 'repository_provider.dart';
import 'subject_sort.dart';

/// 错题本页的状态 Provider（ARCH-PLAN-A 第 2 阶段）。
/// 书架 / 目录 / 列表三个子页共用一个 Provider。
///
/// D-49：声明 `dependencies`（与 detailProvider 同一缺陷：不声明时
/// Riverpod 3.x 把 Provider 挂到根容器，`build()` 里读到的
/// `wrongbookInitialProvider` 是默认值而非页面嵌套 Scope 的 override）。
final wrongbookProvider =
    NotifierProvider.autoDispose<WrongbookNotifier, WrongbookState>(
      WrongbookNotifier.new,
      dependencies: [wrongbookInitialProvider, repositoryProvider],
    );

/// 错题本页的构造参数（初始落点）：带错因 / 知识点筛选进来 → 列表页
///（学科只定列表的范围）；只带学科进来 → 目录页；都不带 → 书架。
/// 页面外壳经 `ProviderScope` 注入；Notifier 的 `build()` 里读它，
/// 不在 `initState` 里改 Provider（Riverpod 禁止在 build /
/// initState 等生命周期里同步改 Provider）。
class WrongbookInitial {
  const WrongbookInitial({
    this.subjectId,
    this.filterCause,
    this.filterKnowledgePointId,
  });

  final String? subjectId;
  final String? filterCause;
  final String? filterKnowledgePointId;

  // D-50：外壳每次 build 都新建一个实例；补 `==` / `hashCode` 使
  // 值相等的实例比较相等（同款见 `DetailInitial` / `ReviewInitial`）。
  // 注意：实测证实 Riverpod 3.5.0 里 `dependencies` 只决定挂载容器，
  // `ref.read` 不订阅——挂载后 override 再变，已挂载的 notifier
  // 不重建、initial 只在挂载时读一次（D-50 回归测试锁定此语义）。
  @override
  bool operator ==(Object other) =>
      other is WrongbookInitial &&
      other.subjectId == subjectId &&
      other.filterCause == filterCause &&
      other.filterKnowledgePointId == filterKnowledgePointId;

  @override
  int get hashCode =>
      Object.hash(subjectId, filterCause, filterKnowledgePointId);
}

/// 初始落点 Provider：默认空（书架）；页面外壳按构造参数 override。
final wrongbookInitialProvider = Provider<WrongbookInitial>(
  (ref) => const WrongbookInitial(),
);

/// 错题本的视图（同一路由 /wrongbook 内的四层）。
enum WrongbookView { shelf, directory, list, archived }

/// 拖拽落点（目录页）：拖到行上 = 移进去；拖到「全部题目」上 = 移回顶层。
enum FolderDropKind { into, promote }

/// `copyWith` 里“显式置 null”与“不改”的区分标记。
const _unset = Object();

/// 错题本页的全部业务数据 + 分页 / 筛选 / 选择等会话状态。
class WrongbookState {
  const WrongbookState({
    this.loading = true,
    this.loadError = false,
    this.errorDismissed = false,
    this.hasLoaded = false,
    this.subjects = const [],
    this.questions = const [],
    this.folders = const [],
    this.exams = const [],
    this.allTags = const [],
    this.kps = const [],
    this.counts = const {},
    this.recordsByQ = const {},
    this.view = WrongbookView.shelf,
    this.subjectId,
    this.folderId,
    this.shelfPage = 0,
    this.expandedFolders = const {},
    this.folderSearch = '',
    this.selectingMove = false,
    this.moveSelection = const {},
    this.moveTargetId = '__top__',
    this.renamingId,
    this.draggingId,
    this.dragOverKey,
    this.search = '',
    this.filterExamId,
    this.filterErrorType,
    // 十四批 M1：题型筛选。null = 全部；'' = 只看待确认；其余 = 该题型值。
    this.filterQuestionType,
    this.filterTimeRange = 'all',
    this.filterCauseStatus = 'all',
    this.filterCauseName,
    this.filterFavorite = false,
    this.filterOverdue = false,
    this.filterTags = const {},
    this.filterKpIds = const {},
    this.filterOpen = false,
    this.sort = 'new',
    this.pageSize = 10,
    this.page = 0,
    this.viewMode = 'large',
    this.viewModeInitialized = false,
    this.sortInitialized = false,
    this.pageSizeInitialized = false,
    this.hoverBookId,
    this.batchMode = false,
    this.selected = const {},
    this.batchFolderId,
    this.inBookArchived = false,
  });

  final bool loading;

  /// _load() 读库失败态（SR-P2-48）：失败不一直转圈，出错误横幅 + 重试。
  final bool loadError;
  final bool errorDismissed;
  final bool hasLoaded;

  // B8-1：空表是删光学科后的合法状态，不再回退预设三科。
  final List<Subject> subjects;
  final List<Question> questions;
  final List<Folder> folders;
  final List<Exam> exams;
  final List<String> allTags;
  final List<KnowledgePoint> kps;
  final Map<String, (int, int, int)> counts;
  final Map<String, List<CauseRecord>> recordsByQ;

  final WrongbookView view;
  final String? subjectId;
  final String? folderId;
  final int shelfPage;

  // 目录页
  final Set<String> expandedFolders;
  final String folderSearch;
  final bool selectingMove;
  final Set<String> moveSelection;
  final String moveTargetId;
  final String? renamingId;
  final String? draggingId;
  final String? dragOverKey;

  // 列表页
  final String search;
  final String? filterExamId;
  final String? filterErrorType;

  /// 十四批 M1：题型筛选。null = 全部；'' = 只看待确认；其余 = 该题型值。
  final String? filterQuestionType;
  final String filterTimeRange; // all / week / month
  final String
  filterCauseStatus; // all / pending / inProgress / solved / recheck
  final String? filterCauseName;
  final bool filterFavorite;
  final bool filterOverdue;
  final Set<String> filterTags;
  final Set<String> filterKpIds;
  final bool filterOpen;
  final String
  sort; // new / old / subj-asc / subj-desc / status-asc / status-desc
  final int pageSize;
  final int page;
  final String viewMode; // large / compact
  final bool viewModeInitialized;
  final bool sortInitialized;
  final bool pageSizeInitialized;

  /// 书架悬停的书（HTML `.nb-book:hover`：上移 4px、阴影加深）。
  final String? hoverBookId;
  final bool batchMode;
  final Set<String> selected;
  final String? batchFolderId;
  final bool inBookArchived;

  WrongbookState copyWith({
    bool? loading,
    bool? loadError,
    bool? errorDismissed,
    bool? hasLoaded,
    List<Subject>? subjects,
    List<Question>? questions,
    List<Folder>? folders,
    List<Exam>? exams,
    List<String>? allTags,
    List<KnowledgePoint>? kps,
    Map<String, (int, int, int)>? counts,
    Map<String, List<CauseRecord>>? recordsByQ,
    WrongbookView? view,
    Object? subjectId = _unset,
    Object? folderId = _unset,
    int? shelfPage,
    Set<String>? expandedFolders,
    String? folderSearch,
    bool? selectingMove,
    Set<String>? moveSelection,
    String? moveTargetId,
    Object? renamingId = _unset,
    Object? draggingId = _unset,
    Object? dragOverKey = _unset,
    String? search,
    Object? filterExamId = _unset,
    Object? filterErrorType = _unset,
    Object? filterQuestionType = _unset,
    String? filterTimeRange,
    String? filterCauseStatus,
    Object? filterCauseName = _unset,
    bool? filterFavorite,
    bool? filterOverdue,
    Set<String>? filterTags,
    Set<String>? filterKpIds,
    bool? filterOpen,
    String? sort,
    int? pageSize,
    int? page,
    String? viewMode,
    bool? viewModeInitialized,
    bool? sortInitialized,
    bool? pageSizeInitialized,
    Object? hoverBookId = _unset,
    bool? batchMode,
    Set<String>? selected,
    Object? batchFolderId = _unset,
    bool? inBookArchived,
  }) {
    return WrongbookState(
      loading: loading ?? this.loading,
      loadError: loadError ?? this.loadError,
      errorDismissed: errorDismissed ?? this.errorDismissed,
      hasLoaded: hasLoaded ?? this.hasLoaded,
      subjects: subjects ?? this.subjects,
      questions: questions ?? this.questions,
      folders: folders ?? this.folders,
      exams: exams ?? this.exams,
      allTags: allTags ?? this.allTags,
      kps: kps ?? this.kps,
      counts: counts ?? this.counts,
      recordsByQ: recordsByQ ?? this.recordsByQ,
      view: view ?? this.view,
      subjectId: subjectId == _unset ? this.subjectId : subjectId as String?,
      folderId: folderId == _unset ? this.folderId : folderId as String?,
      shelfPage: shelfPage ?? this.shelfPage,
      expandedFolders: expandedFolders ?? this.expandedFolders,
      folderSearch: folderSearch ?? this.folderSearch,
      selectingMove: selectingMove ?? this.selectingMove,
      moveSelection: moveSelection ?? this.moveSelection,
      moveTargetId: moveTargetId ?? this.moveTargetId,
      renamingId: renamingId == _unset
          ? this.renamingId
          : renamingId as String?,
      draggingId: draggingId == _unset
          ? this.draggingId
          : draggingId as String?,
      dragOverKey: dragOverKey == _unset
          ? this.dragOverKey
          : dragOverKey as String?,
      search: search ?? this.search,
      filterExamId: filterExamId == _unset
          ? this.filterExamId
          : filterExamId as String?,
      filterErrorType: filterErrorType == _unset
          ? this.filterErrorType
          : filterErrorType as String?,
      filterQuestionType: filterQuestionType == _unset
          ? this.filterQuestionType
          : filterQuestionType as String?,
      filterTimeRange: filterTimeRange ?? this.filterTimeRange,
      filterCauseStatus: filterCauseStatus ?? this.filterCauseStatus,
      filterCauseName: filterCauseName == _unset
          ? this.filterCauseName
          : filterCauseName as String?,
      filterFavorite: filterFavorite ?? this.filterFavorite,
      filterOverdue: filterOverdue ?? this.filterOverdue,
      filterTags: filterTags ?? this.filterTags,
      filterKpIds: filterKpIds ?? this.filterKpIds,
      filterOpen: filterOpen ?? this.filterOpen,
      sort: sort ?? this.sort,
      pageSize: pageSize ?? this.pageSize,
      page: page ?? this.page,
      viewMode: viewMode ?? this.viewMode,
      viewModeInitialized: viewModeInitialized ?? this.viewModeInitialized,
      sortInitialized: sortInitialized ?? this.sortInitialized,
      pageSizeInitialized: pageSizeInitialized ?? this.pageSizeInitialized,
      hoverBookId: hoverBookId == _unset
          ? this.hoverBookId
          : hoverBookId as String?,
      batchMode: batchMode ?? this.batchMode,
      selected: selected ?? this.selected,
      batchFolderId: batchFolderId == _unset
          ? this.batchFolderId
          : batchFolderId as String?,
      inBookArchived: inBookArchived ?? this.inBookArchived,
    );
  }

  // ---------- 派生数据（纯函数，原页面同名方法原样迁移） ----------

  /// 库里找学科：新学科用库里的名与色；找不到才回退 Subject.byId
  ///（数学兜底，只发生在数据不一致时）。
  Subject subjectOf(String id) =>
      subjects.firstWhere((s) => s.id == id, orElse: () => Subject.byId(id));

  List<Folder> subjectFolders(String subjectId) =>
      folders.where((f) => f.subjectId == subjectId).toList();

  List<Folder> topFolders(String subjectId) =>
      subjectFolders(subjectId).where((f) => f.parentId == null).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  List<Folder> subFolders(String parentId) =>
      folders.where((f) => f.parentId == parentId).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  /// 文件夹子树 id（含自己与子文件夹）。
  Set<String> subtreeIds(String folderId) {
    final ids = {folderId};
    for (final sub in subFolders(folderId)) {
      ids.addAll(subtreeIds(sub.id));
    }
    return ids;
  }

  /// 目录文件夹行计数：与题目列表默认视图同一收录口径（SR-P2-38
  /// 决定 (a)）：只收已整理、未归档、未掌握的题。
  int folderCount(String folderId) {
    final ids = subtreeIds(folderId);
    return questions
        .where(
          (q) =>
              q.isOrganized &&
              !q.isArchived &&
              !isMastered(q) &&
              q.folderIds.any((id) => ids.contains(id)),
        )
        .length;
  }

  /// 删文件夹时会跟着删的题数：全部文件夹都在该子树里的题。
  int folderDeleteCount(String folderId) {
    final ids = subtreeIds(folderId);
    return questions
        .where(
          (q) =>
              q.folderIds.isNotEmpty &&
              q.folderIds.every((id) => ids.contains(id)),
        )
        .length;
  }

  /// 删文件夹时只解除关联的题数：在该子树里、同时也在别的题夹里的题。
  int folderDeleteMultiCount(String folderId) {
    final ids = subtreeIds(folderId);
    return questions
        .where(
          (q) =>
              q.folderIds.any((id) => ids.contains(id)) &&
              q.folderIds.any((id) => !ids.contains(id)),
        )
        .length;
  }

  bool isMastered(Question q) {
    final rs = recordsByQ[q.id];
    if (rs == null || rs.isEmpty) return false;
    return rs.every((r) => r.status == CauseStatus.solved) &&
        !rs.any((r) => r.isRecheckDue);
  }

  /// 一题的错因汇总状态（HTML `nbCauseStatus`）：有错因到了复查时间 →
  /// 复查；全部已解决 → 已解决；有解决中或已有自查进展 → 解决中；
  /// 否则待解决；无错因 → 待解决。
  String causeStatusOf(Question q) {
    final rs = recordsByQ[q.id];
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
  List<(String, String)> causeStatusesOf(Question q) {
    final rs = recordsByQ[q.id];
    if (rs == null || rs.isEmpty) {
      return [for (final c in q.allCauses) (c, 'pending')];
    }
    return [
      for (final r in rs) (r.cause, r.isRecheckDue ? 'recheck' : r.status.name),
    ];
  }

  bool isOverdue(Question q) {
    final rs = recordsByQ[q.id];
    if (rs == null) return false;
    return rs.any((r) => r.isRecheckDue);
  }

  DateTime? nextRecheckOf(Question q) {
    final rs = recordsByQ[q.id];
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
  String searchHaystack(Question q) {
    final subject = subjectOf(q.subjectId).name;
    final folderNames = q.folderIds
        .map(
          (id) => folders
              .firstWhere(
                (f) => f.id == id,
                orElse: () => Folder(id: id, name: '', subjectId: ''),
              )
              .name,
        )
        .where((n) => n.isNotEmpty);
    final examName = exams
        .firstWhere(
          (e) => e.id == q.examId,
          orElse: () => Exam(id: '', name: ''),
        )
        .name;
    final kpNames = q.knowledgePointIds.map(
      (id) => kps
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

  List<Question> filteredAll() {
    var list = questions;
    if (view == WrongbookView.archived) {
      // 书架顶部入口：跨学科归档列表。
      list = list.where((q) => q.isArchived).toList();
    } else if (inBookArchived) {
      // 打开的书里的已归档视图：本学科已归档的题。
      list = list
          .where((q) => q.isArchived && q.subjectId == subjectId)
          .toList();
    } else {
      // 错题本只收已整理过的题；未整理的题在整理工作台排队，不进错题本。
      list = list.where((q) => q.isOrganized && !q.isArchived).toList();
      if (subjectId != null) {
        list = list.where((q) => q.subjectId == subjectId).toList();
      }
      if (folderId != null) {
        final ids = subtreeIds(folderId!);
        list = list
            .where((q) => q.folderIds.any((id) => ids.contains(id)))
            .toList();
      }
      // 错因全部已解决的题默认不显示（错因状态筛到已解决时才显示）。
      if (filterCauseStatus != 'solved') {
        list = list.where((q) => !isMastered(q)).toList();
      }
    }
    if (search.trim().isNotEmpty) {
      final kw = search.trim().toLowerCase();
      list = list.where((q) => searchHaystack(q).contains(kw)).toList();
    }
    if (filterExamId != null) {
      list = list.where((q) => q.examId == filterExamId).toList();
    }
    if (filterErrorType != null) {
      list = list.where((q) => q.allCauses.contains(filterErrorType)).toList();
    }
    // 十四批 M1：题型筛选（'' = 待确认 → questionType == null）。
    if (filterQuestionType != null) {
      if (filterQuestionType!.isEmpty) {
        list = list.where((q) => q.questionType == null).toList();
      } else {
        list = list.where((q) => q.questionType == filterQuestionType).toList();
      }
    }
    if (filterCauseName != null) {
      list = list.where((q) => q.allCauses.contains(filterCauseName)).toList();
    }
    if (filterKpIds.isNotEmpty) {
      list = list
          .where(
            (q) => q.knowledgePointIds.any((id) => filterKpIds.contains(id)),
          )
          .toList();
    }
    if (filterTags.isNotEmpty) {
      list = list
          .where((q) => q.tags.any((t) => filterTags.contains(t)))
          .toList();
    }
    if (filterFavorite) {
      list = list.where((q) => q.isFavorite).toList();
    }
    if (filterOverdue) {
      list = list.where((q) => isOverdue(q)).toList();
    }
    if (filterTimeRange != 'all') {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      // “最近一周”= 7 天含今天（SR-P2-45 决定）：age < 7，
      // 不是 age <= 7（那是 8 天）。
      // “最近 30 天”= 30 天含今天（Meng 2026-11-15 决定，与周口径一致）：
      // age < 30，不是 age <= 30（那是 31 天）；报告页“本月”是自然月，不动。
      final limit = filterTimeRange == 'week' ? 7 : 30;
      list = list.where((q) {
        final d = DateTime(
          q.createdAt.year,
          q.createdAt.month,
          q.createdAt.day,
        );
        final age = today.difference(d).inDays;
        return age >= 0 && age < limit;
      }).toList();
    }
    if (view != WrongbookView.archived && !inBookArchived) {
      switch (filterCauseStatus) {
        case 'pending':
          list = list.where((q) => causeStatusOf(q) == 'pending').toList();
        case 'inProgress':
          list = list.where((q) => causeStatusOf(q) == 'inProgress').toList();
        case 'solved':
          list = list.where((q) => causeStatusOf(q) == 'solved').toList();
        case 'recheck':
          list = list.where((q) => causeStatusOf(q) == 'recheck').toList();
      }
    }
    // 学科首字母（SR-P2-37：按学科名首字算，见 [subjectInitial]，
    // 不再写死数学/英语/其他三档）。错因状态排序：待解决 0 / 解决中 1 /
    // 复查 2 / 已解决 3（HTML `NB_STATUS_RANK`）。
    int statusRank(Question q) => switch (causeStatusOf(q)) {
      'pending' => 0,
      'inProgress' => 1,
      'recheck' => 2,
      _ => 3,
    };
    switch (sort) {
      case 'old':
        list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      case 'subj-asc':
      // 旧值 'subject' 的防御分支：_load 已归一，正常走不到这里；
      // 万一某处直接置了 sort，仍按原意排，不静默回落到时间排序。
      case 'subject':
        list.sort((a, b) {
          final c = subjectKeyCompare(a, b);
          return c != 0 ? c : b.createdAt.compareTo(a.createdAt);
        });
      case 'subj-desc':
        list.sort((a, b) {
          final c = subjectKeyCompare(b, a);
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

  int activeFilterCount() {
    var n = 0;
    if (filterExamId != null) n++;
    if (filterErrorType != null) n++;
    if (filterQuestionType != null) n++;
    if (filterTimeRange != 'all') n++;
    if (filterCauseStatus != 'all') n++;
    if (filterCauseName != null) n++;
    if (filterFavorite) n++;
    if (filterOverdue) n++;
    n += filterTags.length;
    n += filterKpIds.length;
    return n;
  }

  /// 当前范围（学科 / 文件夹子树）里已整理、未归档的题数——不含
  /// 搜索 / 筛选与“已掌握默认隐藏”的影响：为 0 才说明范围本身是空的。
  int scopeQuestionCount() {
    final folderIds = folderId == null ? null : subtreeIds(folderId!);
    return questions
        .where(
          (q) =>
              q.isOrganized &&
              !q.isArchived &&
              (subjectId == null || q.subjectId == subjectId) &&
              (folderIds == null ||
                  q.folderIds.any((id) => folderIds.contains(id))),
        )
        .length;
  }

  bool hasSearchOrFilter() =>
      search.trim().isNotEmpty || activeFilterCount() > 0;

  List<Folder> batchFolderOptions() {
    if (subjectId == null) return [];
    return subjectFolders(subjectId!).where((f) => f.id != folderId).toList();
  }

  String folderLabel(Folder f) {
    if (f.parentId == null) return f.name;
    final parent = folders.firstWhere(
      (x) => x.id == f.parentId!,
      orElse: () => Folder(id: '', name: '', subjectId: ''),
    );
    return '${parent.name} / ${f.name}';
  }

  /// 批量操作的安全查找（SR-P2-41）：勾选题可能在两次 load() 间
  /// 被别处删掉/归档过滤掉，`firstWhere` 会抛 StateError 中断整批；
  /// 这里找不到返回 null，调用方计入“已不在列表里，跳过”。
  Question? questionById(String id) {
    for (final q in questions) {
      if (q.id == id) return q;
    }
    return null;
  }

  Folder? folderById(String id) {
    for (final f in folders) {
      if (f.id == id) return f;
    }
    return null;
  }

  // ---------- 学科首字母（SR-P2-37 / SR2-32，原页面同款） ----------
  // FR-08：实现在 `subject_sort.dart`，与整理页共用一份（拼音表 +
  // 首字母 + 拼音串 + 比较）；此处只按学科 id 取名后委托。

  String subjectInitial(String subjectId) =>
      subjectInitialForName(subjectOf(subjectId).name);

  String subjectPinyinKey(String subjectId) =>
      subjectPinyinKeyForName(subjectOf(subjectId).name);

  /// 学科首字母 + 全名拼音首字母串比较（时间平局由调用方另行处理）。
  int subjectKeyCompare(Question a, Question b) => compareSubjectNames(
    subjectOf(a.subjectId).name,
    subjectOf(b.subjectId).name,
  );
}

/// 批量结果汇总提示（SR-P2-41）：成功 / 跨科跳过 / 已不在列表 /
/// 保存失败各计一次，操作完一次说清，不再静默。
String batchResultMessage(
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
  return parts.isEmpty ? '没有题被$action' : parts.join('；');
}

/// 加入复习的结果反馈（B11-6）：加入 N 道、跳过 M 道；M > 0 时
/// 写明原因是一题已无未解决错因。`showReviewAction` 为真时页面给
/// “开始复习”入口，点它跳复习页 /review。
({String message, bool showReviewAction}) joinReviewResultMessage(
  int joined,
  int skipped,
  int missing,
  int failed,
) {
  final parts = <String>[];
  if (joined > 0) parts.add('已加入复习 $joined 道');
  if (skipped > 0) parts.add('$skipped 道已无未解决错因，跳过');
  if (missing > 0) parts.add('$missing 道已不在列表里，跳过');
  if (failed > 0) parts.add('$failed 道保存失败，请重试');
  return (
    message: parts.isEmpty ? '没有题被加入复习' : parts.join('；'),
    showReviewAction: joined > 0,
  );
}

/// 取消加入复习的结果反馈（B11-6）：取消 N 道、未加入的跳过 M 道。
String cancelReviewResultMessage(
  int cancelled,
  int skipped,
  int missing,
  int failed,
) {
  final parts = <String>[];
  if (cancelled > 0) parts.add('已取消加入复习 $cancelled 道');
  if (skipped > 0) parts.add('$skipped 道未加入复习，跳过');
  if (missing > 0) parts.add('$missing 道已不在列表里，跳过');
  if (failed > 0) parts.add('$failed 道保存失败，请重试');
  return parts.isEmpty ? '没有题被取消加入复习' : parts.join('；');
}

/// 错题本页业务逻辑 + 业务数据（ARCH-PLAN-A 第 2 阶段：原
/// `wrongbook_page.dart` 的 `_WrongbookPageState` 里调 `repo` 的部分
/// 原样迁入；页面只留 widget 与本地交互状态）。
///
/// 拿库的方式与 `SettingsNotifier` 一致：经
/// `ref.read(repositoryProvider)` 拿——测试注入见
/// `docs/ui-replication/A-READING-GUIDE.md`（`ProviderContainer.test`
/// + `repositoryProvider.overrideWithValue`）。
class WrongbookNotifier extends Notifier<WrongbookState> {
  QuestionRepository get _repo => ref.read(repositoryProvider);

  bool _disposed = false;

  @override
  WrongbookState build() {
    ref.onDispose(() => _disposed = true);
    unawaited(load());
    // 初始落点（原 `initState` 的一部分）：带错因 / 知识点筛选进来 →
    // 列表页（D-50：筛选优先于学科——报告深链路带学科 + 错因 / 知识点
    // 进来时直达已筛选列表，学科只定列表的范围，不把落点拉回目录页）；
    // 只带学科进来 → 目录页；都不带 → 书架。
    // `load()` 只写数据字段，不动视图 / 范围 / 筛选字段，
    // 所以先读后读不影响最终状态。
    final initial = ref.read(wrongbookInitialProvider);
    var view = WrongbookView.shelf;
    if (initial.filterCause != null || initial.filterKnowledgePointId != null) {
      view = WrongbookView.list;
    } else if (initial.subjectId != null) {
      view = WrongbookView.directory;
    }
    return WrongbookState(
      view: view,
      subjectId: initial.subjectId,
      filterCauseName: initial.filterCause,
      filterKpIds: initial.filterKnowledgePointId == null
          ? const {}
          : {initial.filterKnowledgePointId!},
    );
  }

  /// 纯界面字段改动（悬停、展开、分页、搜索词等）：调用方用
  /// `copyWith` 描述新状态；业务动作走具名方法。
  void update(WrongbookState Function(WrongbookState current) f) {
    state = f(state);
  }

  /// 首读与每次写库后重读（与原来页面的 `_load` 同口径）：
  /// 读库失败不一直转圈（SR-P2-48），出错误横幅 + 重试入口，
  /// 已加载过内容时留住旧内容（`loadError` 态由页面按 `hasLoaded`
  /// 分两种画法）。视图 / 范围 / 筛选 / 选择等会话字段只在
  /// 首次读到设置默认值时初始化一次，之后重读不再覆盖
  ///（B2 leftover：从详情返回、批量操作、点星等刷新后不弹回默认视图）。
  Future<void> load() async {
    // D-42：build() 的 microtask 首查可能在页面已离开、Provider 已销毁后
    // 才跑——先判 _disposed 再碰 ref；repo 入口处捕获一次，之后不再 ref.read。
    if (_disposed) return;
    final repo = _repo;
    try {
      final subjects = await repo.subjects();
      final questions = await repo.all(includeArchived: true);
      final folders = await repo.folders();
      final exams = await repo.exams();
      final tags = await repo.tags();
      final kps = await repo.knowledgePoints();
      final counts = await repo.subjectCounts();
      final records = await repo.causeRecords();
      final settings = await repo.settings();
      final byQ = <String, List<CauseRecord>>{};
      for (final r in records) {
        (byQ[r.questionId] ??= []).add(r);
      }
      if (_disposed) return;
      // SR2-34：错误类型筛选的当前值可能在详情页删题后失效——选项 =
      // 固定错因 + 现存题的全部错因；唯一带某自定义错因的题被删后，
      // 旧值不在选项里，直接喂给 DropdownButton 会断言。无效时回落
      // 到 null（“全部”）。
      String? filterErrorType = state.filterErrorType;
      if (filterErrorType != null) {
        final validTypes = <String>{...ErrorTypes.fixed};
        for (final q in questions) {
          validTypes.addAll(q.allCauses);
        }
        if (!validTypes.contains(filterErrorType)) {
          filterErrorType = null;
        }
      }
      // 设置值先归一再用：旧库里可能存着 SR-P0-2 之前的 'subject'，
      // 列表下拉没有这一项，直接喂给 DropdownButton 会在 debug 下断言。
      final sort = AppSettings.normalizeWrongbookSort(settings.wrongbookSort);
      state = state.copyWith(
        subjects: subjects,
        questions: questions,
        folders: folders,
        exams: exams,
        allTags: tags,
        kps: kps,
        counts: counts,
        recordsByQ: byQ,
        filterErrorType: filterErrorType,
        pageSize: state.pageSizeInitialized
            ? state.pageSize
            : settings.pageSize,
        pageSizeInitialized: true,
        viewMode: state.viewModeInitialized
            ? state.viewMode
            : settings.wrongbookView,
        viewModeInitialized: true,
        sort: state.sortInitialized ? state.sort : sort,
        sortInitialized: true,
        loading: false,
        loadError: false,
        hasLoaded: true,
      );
    } catch (_) {
      if (_disposed) return;
      state = state.copyWith(
        loading: false,
        loadError: true,
        errorDismissed: false,
      );
    }
  }

  Future<void> retryLoad() async {
    state = state.copyWith(loading: true, loadError: false);
    await load();
  }

  void dismissLoadError() {
    state = state.copyWith(errorDismissed: true);
  }

  // ---------- 导航与范围 ----------

  /// 清搜索与筛选（不包排序：进另一科 / 文件夹只清搜索与筛选，
  /// 排序保留当前值；文件夹 / 学科是列表的归属范围，不是筛选，不清）。
  /// 输入框控制器由页面自己清（见页面 `_clearFilters`）。
  void clearFilters() {
    state = state.copyWith(
      search: '',
      filterExamId: null,
      filterErrorType: null,
      filterQuestionType: null,
      filterTimeRange: 'all',
      filterCauseStatus: 'all',
      filterCauseName: null,
      filterFavorite: false,
      filterOverdue: false,
      filterTags: const {},
      filterKpIds: const {},
      page: 0,
      selected: const {},
    );
  }

  /// “重置”按钮：清搜索与筛选，排序固定回时间新→旧
  ///（SR-P2-58 决定 (a)），不是设置默认值。
  void resetFilters() {
    clearFilters();
    state = state.copyWith(sort: 'new');
  }

  void openList({String? subjectId, required String? folderId}) {
    // 进另一科 / 另一文件夹时，上一范围的搜索与筛选不清零会带过来
    //（SR-P2-44），所以范围变化时清掉；同科同文件夹重进也清。
    clearFilters();
    state = state.copyWith(
      subjectId: subjectId ?? state.subjectId,
      folderId: folderId,
      view: WrongbookView.list,
      page: 0,
      selected: const {},
      batchMode: false,
      inBookArchived: false,
    );
  }

  void openDirectory(String subjectId) {
    clearFilters();
    state = state.copyWith(
      subjectId: subjectId,
      view: WrongbookView.directory,
      // 展开状态不记住：每次进目录都先收起。
      expandedFolders: const {},
      folderSearch: '',
      selectingMove: false,
      moveSelection: const {},
      // SR2-7：换科时移动目标一并复位，不带上一科文件夹的 id 进新科。
      moveTargetId: '__top__',
      renamingId: null,
      draggingId: null,
      dragOverKey: null,
    );
  }

  void openShelf() {
    clearFilters();
    state = state.copyWith(
      view: WrongbookView.shelf,
      subjectId: null,
      folderId: null,
      shelfPage: 0,
      inBookArchived: false,
      // SR2-7：回书架时移动目标一并复位。
      moveTargetId: '__top__',
    );
  }

  // ---------- 筛选（改筛选后：回第 1 页，勾选只保留仍在当前结果里的题） ----------

  /// 筛选变化后：回第 1 页，勾选只保留仍在当前结果里的题
  ///（HTML `viewNotebook` 的 fkey 逻辑）。
  void applyFilterChange() {
    final ids = state.filteredAll().map((q) => q.id).toSet();
    state = state.copyWith(selected: state.selected.intersection(ids), page: 0);
  }

  void setSearch(String v) {
    state = state.copyWith(search: v, page: 0);
  }

  void setFolderSearch(String v) {
    state = state.copyWith(folderSearch: v);
  }

  void setFilterExamId(String? v) {
    state = state.copyWith(filterExamId: v);
    applyFilterChange();
  }

  void setFilterErrorType(String? v) {
    state = state.copyWith(filterErrorType: v);
    applyFilterChange();
  }

  /// 十四批 M1：题型筛选（null = 全部；'' = 只看待确认）。
  void setFilterQuestionType(String? v) {
    state = state.copyWith(filterQuestionType: v);
    applyFilterChange();
  }

  void setFilterTimeRange(String v) {
    state = state.copyWith(filterTimeRange: v);
    applyFilterChange();
  }

  void setFilterCauseStatus(String v) {
    state = state.copyWith(filterCauseStatus: v);
    applyFilterChange();
  }

  void setFilterCauseName(String? v) {
    state = state.copyWith(filterCauseName: v);
    applyFilterChange();
  }

  void toggleFilterTag(String t) {
    final tags = {...state.filterTags};
    if (tags.contains(t)) {
      tags.remove(t);
    } else {
      tags.add(t);
    }
    state = state.copyWith(filterTags: tags);
    applyFilterChange();
  }

  void removeFilterKpId(String kpId) {
    state = state.copyWith(filterKpIds: {...state.filterKpIds}..remove(kpId));
    applyFilterChange();
  }

  void clearFilterCauseName() {
    state = state.copyWith(filterCauseName: null);
    applyFilterChange();
  }

  void toggleFilterFavorite() {
    state = state.copyWith(filterFavorite: !state.filterFavorite);
    applyFilterChange();
  }

  void toggleFilterOverdue() {
    state = state.copyWith(filterOverdue: !state.filterOverdue);
    applyFilterChange();
  }

  void toggleInBookArchived() {
    state = state.copyWith(
      inBookArchived: !state.inBookArchived,
      page: 0,
      selected: const {},
      batchMode: false,
    );
  }

  void setSort(String v) {
    state = state.copyWith(sort: v, page: 0);
  }

  void setPageSize(int v) {
    state = state.copyWith(pageSize: v, page: 0);
  }

  void setViewMode(String v) {
    state = state.copyWith(viewMode: v);
  }

  // ---------- 选择与批量模式 ----------

  /// 批量全选 / 全不选（复选框与「全选当前结果」文案共用）。
  void toggleSelectAll(List<Question> all) {
    final selInList = all.where((q) => state.selected.contains(q.id)).length;
    if (all.isNotEmpty && selInList == all.length) {
      state = state.copyWith(selected: const {});
    } else {
      state = state.copyWith(
        selected: {...state.selected, ...all.map((q) => q.id)},
      );
    }
  }

  void toggleSelected(String id, bool selected) {
    final next = {...state.selected};
    if (selected) {
      next.add(id);
    } else {
      next.remove(id);
    }
    state = state.copyWith(selected: next);
  }

  // ---------- 文件夹操作 ----------

  /// 新增文件夹。调用方传输入框里的名字；空名、重名只返回提示，
  /// 不写库、不重读。成功返回 null，页面清输入框。
  Future<String?> addFolder({String? parentId, required String name}) async {
    final subjectId = state.subjectId;
    if (subjectId == null) return null;
    if (name.isEmpty) return '先写文件夹名称';
    // D-42：repo 入口处捕获一次（预检与保存跨多次 await，`on StateError`
    // 接不住 UnmountedRefException——中途切页销毁 Provider 后再
    // ref.read 会抛到调用方）。
    final repo = _repo;
    final siblings = parentId == null
        ? state.topFolders(subjectId)
        : state.subFolders(parentId);
    // SR-P2-36：整科判重——同一学科下任何层级已有同名文件夹都拦下，
    // 不只同层兄弟。
    if (await repo.folderNameExistsInSubject(subjectId, name)) {
      return '已经有了';
    }
    final maxOrder = siblings.isEmpty
        ? 0
        : siblings.map((f) => f.sortOrder).reduce((a, b) => a > b ? a : b);
    try {
      await repo.saveFolder(
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
      return '已经有了';
    }
    await load();
    return null;
  }

  /// 文件夹改名。调用方先做“空名或同名则关框、无提示”的检查；
  /// 这里只做整科判重 + 写库。成功返回 null，页面关改名框；
  /// 重名返回提示，改名框保持打开、让用户换个名字。
  Future<String?> saveRename(Folder f, String name) async {
    // D-42：repo 入口处捕获一次（见 addFolder）。
    final repo = _repo;
    // SR-P2-36：整科判重——改名后同一学科下任何层级都不能有同名
    // （自身除外）。
    if (await repo.folderNameExistsInSubject(
      f.subjectId,
      name,
      excludeId: f.id,
    )) {
      return '已经有了';
    }
    try {
      await repo.saveFolder(
        Folder(
          id: f.id,
          name: name,
          subjectId: f.subjectId,
          parentId: f.parentId,
          sortOrder: f.sortOrder,
        ),
      );
    } on StateError {
      return '已经有了';
    }
    await load();
    return null;
  }

  Future<void> deleteFolderConfirmed(Folder f) async {
    await _repo.deleteFolder(f);
    // SR2-7：删掉的可能是移动条正选中的目标；复位，下次开移动条不再
    // 拿已删的 id 当下拉值。
    state = state.copyWith(moveTargetId: '__top__');
    await load();
  }

  /// 移动文件夹（HTML `tocMoveFolder` 的禁则）：
  /// 已在目标处；不能移到自己 / 自己子文件夹下面；
  /// 带子文件夹的一级文件夹不能再放进别的文件夹（只留一层）；
  /// SR-P2-36：同一学科下已有同名文件夹（不论层级，自身除外）。
  /// 返回 null 表示成功，否则返回拦下的原因。
  Future<String?> moveOneFolder(Folder f, String? targetParentId) async {
    if (f.parentId == targetParentId) return '已经在那里了';
    // D-42：repo 入口处捕获一次（见 addFolder）。
    final repo = _repo;
    if (targetParentId != null) {
      if (targetParentId == f.id ||
          state.subtreeIds(f.id).contains(targetParentId)) {
        return '不能移到自己下面';
      }
      // SR2-7：目标可能在选定后被删（或来自已换走的学科），无 orElse 的
      // firstWhere 会抛 StateError 中断整批；找不到按“目标不存在”返回。
      final target = state.folderById(targetParentId);
      if (target == null || target.subjectId != f.subjectId) {
        return '目标文件夹已经不存在了';
      }
      if (target.parentId != null) return '子文件夹只能有一层';
      if (state.subFolders(f.id).isNotEmpty) {
        return '「${f.name}」下面还有子文件夹，只留一层，不能再放进别的文件夹里';
      }
    }
    // SR-P2-36：整科判重——移入/移回时，同一学科下任何层级已有同名
    // 文件夹（自身除外）都拦下，不只看目标那一层。
    if (await repo.folderNameExistsInSubject(
      f.subjectId,
      f.name,
      excludeId: f.id,
    )) {
      return '同一学科下已经有同名文件夹「${f.name}」了';
    }
    final siblings = targetParentId == null
        ? state.topFolders(f.subjectId)
        : state.subFolders(targetParentId);
    final maxOrder = siblings.isEmpty
        ? 0
        : siblings.map((x) => x.sortOrder).reduce((a, b) => a > b ? a : b);
    try {
      await repo.saveFolder(
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
  ///（HTML `data-nb-toc-move` 的处理）。返回汇总提示，页面弹出。
  Future<String> moveSelected() async {
    final subjectId = state.subjectId;
    if (subjectId == null) return '先勾选要移动的文件夹';
    final picked = state.folders
        .where((f) => state.moveSelection.contains(f.id))
        .toList();
    if (picked.isEmpty) return '先勾选要移动的文件夹';
    final effective = picked
        .where(
          (f) =>
              f.parentId == null || !state.moveSelection.contains(f.parentId),
        )
        .toList();
    // SR2-7：下拉显示的值与实际移动的目标取同一口径——_moveTargetId
    // 陈旧（换科 / 删目标后）时按下拉回落到顶层，不按旧 id 移动。
    final effectiveTargetId =
        state.moveTargetId == '__top__' ||
            state.topFolders(subjectId).any((f) => f.id == state.moveTargetId)
        ? state.moveTargetId
        : '__top__';
    final targetParentId = effectiveTargetId == '__top__'
        ? null
        : effectiveTargetId;
    var okN = 0;
    final fails = <String>[];
    for (final f in effective) {
      final msg = await moveOneFolder(f, targetParentId);
      if (msg == null) {
        okN++;
      } else {
        fails.add('「${f.name}」：$msg');
      }
    }
    state = state.copyWith(
      selectingMove: false,
      moveSelection: const {},
      expandedFolders: targetParentId != null && okN > 0
          ? {...state.expandedFolders, targetParentId}
          : state.expandedFolders,
    );
    await load();
    return '${okN > 0 ? '已移动 $okN 个文件夹（里面的题跟着一起走）' : '没有文件夹被移动'}${fails.isEmpty ? '' : '；${fails.join('；')}'}';
  }

  /// 同层调顺序（拖到两行之间；HTML `tocReorderFolder` 的等效做法）。
  /// 缝隙下标是“删除前”的位置（SR-P2-42）：往下拖时先删被拖行再插，
  /// 目标下标须减 1，否则多移一位。失败返回提示，成功返回 null。
  Future<String?> reorderFolder(
    Folder dragged,
    String? parentId,
    int toIndex,
  ) async {
    final subjectId = state.subjectId;
    if (subjectId == null) return null;
    if (dragged.parentId != parentId) return null;
    final siblings = parentId == null
        ? state.topFolders(subjectId)
        : state.subFolders(parentId);
    final fromIndex = siblings.indexWhere((f) => f.id == dragged.id);
    if (fromIndex < 0) return null;
    siblings.removeAt(fromIndex);
    var idx = toIndex;
    if (idx > fromIndex) idx -= 1;
    idx = idx.clamp(0, siblings.length);
    siblings.insert(idx, dragged);
    // D-42：repo 入口处捕获一次（`on StateError` 接不住
    // UnmountedRefException）；一次调顺序只发一个事件（scope 合并）。
    final repo = _repo;
    // SR-P2-36 防线：调顺序不改名，正常情况下不会触发 upsertFolder 的
    // 整科同名把关；若库里已有遗留重名，只提示、不崩页。
    try {
      await DataChangeBus.instance.scope(() async {
        for (var i = 0; i < siblings.length; i++) {
          await repo.saveFolder(
            Folder(
              id: siblings[i].id,
              name: siblings[i].name,
              subjectId: siblings[i].subjectId,
              parentId: siblings[i].parentId,
              sortOrder: i * 10,
            ),
          );
        }
      });
    } on StateError {
      return '已经有了';
    }
    await load();
    return null;
  }

  /// 拖放落点处理（HTML `tocDropMode` / `tocApplyDrop`）：
  /// - 拖到「全部题目」上：子文件夹移回顶层；顶层文件夹排到最前面。
  /// - 拖到文件夹行上：移进去当它的子文件夹（拖到子文件夹行上时，
  ///   落在其父文件夹下面）；已在里面时不动。
  /// - 拖到两行之间：同层调顺序；缝隙只接受同层拖拽。
  /// 返回要弹的提示（null 表示静默成功）。
  Future<String?> applyDrop(
    Folder dragged,
    Folder? target,
    FolderDropKind kind,
  ) async {
    if (kind == FolderDropKind.promote) {
      if (dragged.parentId != null) {
        final msg = await moveOneFolder(dragged, null);
        await load();
        return msg ?? '已把「${dragged.name}」移回顶层（里面的题跟着一起走）';
      } else {
        return reorderFolder(dragged, null, 0);
      }
    }
    if (target == null) return null;
    if (kind == FolderDropKind.into) {
      final targetParent = target.parentId ?? target.id;
      if (dragged.parentId == targetParent) return null;
      final msg = await moveOneFolder(dragged, targetParent);
      if (msg == null) {
        state = state.copyWith(
          expandedFolders: {...state.expandedFolders, targetParent},
        );
      }
      await load();
      return msg;
    }
    return null;
  }

  // ---------- 批量操作（返回汇总提示，页面弹出；成功后清选择并重读） ----------

  /// 批量加标签：`newName` 非空时先新建标签（与学科管理页同一禁令：
  /// 含 , 或 | 的标签名直接拦截，不入库）。`picked` 为空且无新建
  /// 时静默返回 null（不重读、不提示，与原来一致）。
  Future<String?> batchAddTag({
    required Set<String> picked,
    String? newName,
  }) async {
    // D-42 + Stage 4：repo 入口处捕获一次；批量提交只发一个事件
    //（scope 把新建标签与逐题保存的事件合并成一个）。
    final repo = _repo;
    final allPicked = {...picked};
    if (newName != null && newName.isNotEmpty) {
      if (hasBannedNameSeparator(newName)) return '不能含逗号或竖线';
      allPicked.add(newName);
    }
    if (allPicked.isEmpty) return null;
    var okN = 0;
    var missing = 0;
    var failed = 0;
    await DataChangeBus.instance.scope(() async {
      if (newName != null && newName.isNotEmpty) {
        await repo.addTag(newName);
      }
      for (final id in state.selected.toList()) {
        final q = state.questionById(id);
        if (q == null) {
          missing++;
          continue;
        }
        try {
          final merged = {...q.tags, ...allPicked}.toList();
          await repo.save(q.copyWith(tags: merged));
          okN++;
        } catch (_) {
          failed++;
        }
      }
    });
    state = state.copyWith(selected: const {});
    await load();
    return batchResultMessage('加标签', okN, missing, failed);
  }

  /// 批量移入文件夹。`targetId` 由页面解析（下拉当前值）；
  /// 在文件夹里进来时是“移入”（离开当前文件夹），
  /// 在「全部题目」进来时是“加入”（保留原有文件夹）。
  Future<String> batchMoveToFolder(String targetId) async {
    final target = state.folderById(targetId);
    if (target == null) return '目标文件夹找不到了';
    // D-42 + Stage 4：repo 入口处捕获一次；批量提交只发一个事件。
    final repo = _repo;
    var okN = 0;
    var missing = 0;
    var failed = 0;
    var skipped = 0;
    await DataChangeBus.instance.scope(() async {
      for (final id in state.selected.toList()) {
        final q = state.questionById(id);
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
          if (state.folderId != null) ids.remove(state.folderId);
          if (!ids.contains(target.id)) ids.add(target.id);
          await repo.save(q.copyWith(folderIds: ids));
          okN++;
        } catch (_) {
          failed++;
        }
      }
    });
    state = state.copyWith(selected: const {});
    await load();
    return batchResultMessage('移入文件夹', okN, missing, failed, skipped: skipped);
  }

  Future<String?> batchMoveOut() async {
    if (state.folderId == null) return null;
    // D-42 + Stage 4：repo 入口处捕获一次；批量提交只发一个事件。
    final repo = _repo;
    var okN = 0;
    var missing = 0;
    var failed = 0;
    await DataChangeBus.instance.scope(() async {
      for (final id in state.selected.toList()) {
        final q = state.questionById(id);
        if (q == null) {
          missing++;
          continue;
        }
        if (!q.folderIds.contains(state.folderId)) {
          okN++;
          continue;
        }
        try {
          await repo.save(
            q.copyWith(
              folderIds: q.folderIds.where((x) => x != state.folderId).toList(),
            ),
          );
          okN++;
        } catch (_) {
          failed++;
        }
      }
    });
    state = state.copyWith(selected: const {});
    await load();
    return batchResultMessage('移出文件夹', okN, missing, failed);
  }

  Future<String> batchFavorite() async {
    // D-42 + Stage 4：repo 入口处捕获一次；批量提交只发一个事件。
    final repo = _repo;
    var okN = 0;
    var missing = 0;
    var failed = 0;
    await DataChangeBus.instance.scope(() async {
      for (final id in state.selected.toList()) {
        final q = state.questionById(id);
        if (q == null) {
          missing++;
          continue;
        }
        if (q.isFavorite) {
          okN++;
          continue;
        }
        try {
          await repo.toggleFavorite(q);
          okN++;
        } catch (_) {
          failed++;
        }
      }
    });
    state = state.copyWith(selected: const {});
    await load();
    return batchResultMessage('收藏', okN, missing, failed);
  }

  Future<String> batchArchive() async {
    // D-42 + Stage 4：repo 入口处捕获一次；批量提交只发一个事件。
    final repo = _repo;
    var okN = 0;
    var missing = 0;
    var failed = 0;
    await DataChangeBus.instance.scope(() async {
      for (final id in state.selected.toList()) {
        final q = state.questionById(id);
        if (q == null) {
          missing++;
          continue;
        }
        try {
          await repo.archive(q);
          okN++;
        } catch (_) {
          failed++;
        }
      }
    });
    state = state.copyWith(selected: const {});
    await load();
    return batchResultMessage('归档', okN, missing, failed);
  }

  /// 批量加入复习（B11-6，勾选版）：只加未解决的错因——判定与计数
  /// 在 [QuestionRepository.joinReviewBatch] 里（无未解决错因的题
  /// 跳过）；加完给“开始复习”入口，点它跳复习页 /review。
  Future<({String message, bool showReviewAction})>
  batchJoinReviewSelected() async {
    final qs = <Question>[];
    var missing = 0;
    for (final id in state.selected.toList()) {
      final q = state.questionById(id);
      if (q == null) {
        missing++;
      } else {
        qs.add(q);
      }
    }
    final result = await _repo.joinReviewBatch(qs);
    state = state.copyWith(selected: const {});
    await load();
    return joinReviewResultMessage(
      result.joined,
      result.skipped,
      missing,
      result.failed,
    );
  }

  /// 全部加入（B11-6）：作用域 = 当前筛选出的全部题（`all` 是
  /// [WrongbookState.filteredAll] 的结果，与“全选当前结果”同口径），
  /// 不是全库，也不限当前页；不用先勾选。
  Future<({String message, bool showReviewAction})> batchJoinReviewAll(
    List<Question> all,
  ) async {
    final result = await _repo.joinReviewBatch(all);
    state = state.copyWith(selected: const {});
    await load();
    return joinReviewResultMessage(
      result.joined,
      result.skipped,
      0,
      result.failed,
    );
  }

  /// 批量取消加入复习（B11-6，勾选版）：与详情页单个取消同语义——
  /// 只把 review_joined 置回 false，错因记录保留，重加入可恢复；
  /// 本来就没加入的题计入跳过。
  Future<String> batchCancelReviewSelected() async {
    final qs = <Question>[];
    var missing = 0;
    for (final id in state.selected.toList()) {
      final q = state.questionById(id);
      if (q == null) {
        missing++;
      } else {
        qs.add(q);
      }
    }
    final result = await _repo.cancelReviewBatch(qs);
    state = state.copyWith(selected: const {});
    await load();
    return cancelReviewResultMessage(
      result.cancelled,
      result.skipped,
      missing,
      result.failed,
    );
  }

  /// FR-37（Meng 裁决口径 (b)）：批量删除整批一个事务——先在 state 里
  /// 分出已不在列表的题（missing），其余一次调 `repo.deleteQuestions`
  /// （数据层整批事务）；整体成功则 okN 全计，整体失败则 failed 全计、
  /// 库里一道都不删（中途失败整批回滚，不再是逐题事务 + 部分删除）。
  Future<String> batchDeleteConfirmed() async {
    // D-42 + Stage 4：repo 入口处捕获一次；批量提交只发一个事件
    // （deleteQuestionsBatch 成功后自发一次合并事件，不再另包 scope）。
    final repo = _repo;
    final qs = <Question>[];
    var missing = 0;
    for (final id in state.selected.toList()) {
      final q = state.questionById(id);
      if (q == null) {
        missing++;
      } else {
        qs.add(q);
      }
    }
    var okN = 0;
    var failed = 0;
    try {
      await repo.deleteQuestions(qs);
      okN = qs.length;
    } catch (_) {
      failed = qs.length;
    }
    state = state.copyWith(selected: const {});
    await load();
    return batchResultMessage('删除', okN, missing, failed);
  }

  Future<void> toggleFavorite(Question q) async {
    await _repo.toggleFavorite(q);
    await load();
  }

  Future<void> restoreArchived(Question q) async {
    await _repo.archive(q, archived: false);
    await load();
  }
}
