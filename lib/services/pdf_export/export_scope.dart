// 十五批 M3：导出向导的范围筛选 + 50 道上限选择状态（PLAN-15-REV3 §6，
// M1-DESIGN.md §2/§5，D-168）。
//
// 本文件为纯逻辑层，不碰数据库、不碰界面、不碰文件系统：
// - [ExportScopeFilter]：向导第 1 步的范围条件（学科 / 文件夹 / 考试 /
//   错因 / 知识点 / 时间），复用错题本现有筛选条件的语义（见
//   WrongbookState.filteredAll：学科、文件夹子树、考试、错因、知识点、
//   时间）；作用对象是打开向导时拍下的当前筛选结果（filteredAll() 的
//   返回值），只做进一步圈定，不另写一套全库筛选。
// - [ExportSelection]：向导第 2 步的挑题状态，50 道硬上限（C-1/C-2）
//   的第 1 处设防：点选第 51 道拒绝 + 提示；全选 = 圈定范围的前 50 道
//   （按传入顺序，即 filteredAll() 顺序）+ 明示提示；不得把其余题目
//   放进隐藏待导出队列。
import '../../models/models.dart';
import 'export_route.dart';

/// 向导第 1 步的范围条件（全部可空 = 不限）。
class ExportScopeFilter {
  const ExportScopeFilter({
    this.subjectId,
    this.folderId,
    this.examId,
    this.causeName,
    this.kpId,
    this.timeRange = 'all',
  });

  /// 学科（null = 全部学科，可跨学科）。
  final String? subjectId;

  /// 文件夹（null = 全部文件夹，可跨文件夹；含子文件夹子树）。
  final String? folderId;

  /// 考试（null = 全部考试）。
  final String? examId;

  /// 错因（null = 全部错因；固定枚举 + 自定义错因名）。
  final String? causeName;

  /// 知识点（null = 全部知识点）。
  final String? kpId;

  /// 时间范围：all / week（最近 7 天含今天）/ month（最近 30 天含今天），
  /// 与 filteredAll() 同口径（age < 7 / age < 30）。
  final String timeRange;

  /// 是否未设任何范围条件（= 默认路径：当前筛选全部题目）。
  bool get isEmpty =>
      subjectId == null &&
      folderId == null &&
      examId == null &&
      causeName == null &&
      kpId == null &&
      timeRange == 'all';

  ExportScopeFilter copyWith({
    Object? subjectId = _unset,
    Object? folderId = _unset,
    Object? examId = _unset,
    Object? causeName = _unset,
    Object? kpId = _unset,
    String? timeRange,
  }) => ExportScopeFilter(
    subjectId: subjectId == _unset ? this.subjectId : subjectId as String?,
    folderId: folderId == _unset ? this.folderId : folderId as String?,
    examId: examId == _unset ? this.examId : examId as String?,
    causeName: causeName == _unset ? this.causeName : causeName as String?,
    kpId: kpId == _unset ? this.kpId : kpId as String?,
    timeRange: timeRange ?? this.timeRange,
  );

  static const _unset = Object();
}

/// 文件夹子树 id（含自己与子文件夹），与 WrongbookState.subtreeIds
/// 同口径（子文件夹只一层，但按递归算，不依赖层数假设）。
Set<String> exportFolderSubtreeIds(List<Folder> folders, String folderId) {
  final ids = {folderId};
  for (final sub in folders.where((f) => f.parentId == folderId)) {
    ids.addAll(exportFolderSubtreeIds(folders, sub.id));
  }
  return ids;
}

/// 对已拍下的当前筛选结果做范围圈定（纯函数；不改传入列表）。
///
/// [base] 为打开向导时的 filteredAll() 结果（已含“已整理、未归档、
// 未掌握默认隐藏”等错题本口径）；本函数只在该集合上再按范围条件过滤。
List<Question> applyExportScopeFilter(
  List<Question> base,
  List<Folder> folders,
  ExportScopeFilter filter, {
  DateTime? now,
}) {
  var list = base;
  if (filter.subjectId != null) {
    list = list.where((q) => q.subjectId == filter.subjectId).toList();
  }
  if (filter.folderId != null) {
    final ids = exportFolderSubtreeIds(folders, filter.folderId!);
    list = list
        .where((q) => q.folderIds.any((id) => ids.contains(id)))
        .toList();
  }
  if (filter.examId != null) {
    list = list.where((q) => q.examId == filter.examId).toList();
  }
  if (filter.causeName != null) {
    list = list.where((q) => q.allCauses.contains(filter.causeName)).toList();
  }
  if (filter.kpId != null) {
    list = list
        .where((q) => q.knowledgePointIds.contains(filter.kpId))
        .toList();
  }
  if (filter.timeRange != 'all') {
    final current = now ?? DateTime.now();
    final today = DateTime(current.year, current.month, current.day);
    final limit = filter.timeRange == 'week' ? 7 : 30;
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
  return list;
}

/// 范围摘要（一行，供向导第 3 步“范围摘要”与 PDF 信息区 filterText 用）。
///
/// 未设条件时返回“全部题目”；其余按“学科：X；文件夹：Y；…”拼接，
// 名称由调用方按 id 查好传入（不得取第一道题的学科 / 文件夹代表范围）。
String exportScopeSummaryText({
  required ExportScopeFilter filter,
  String? subjectName,
  String? folderName,
  String? examName,
  String? kpName,
}) {
  final parts = <String>[];
  if (subjectName != null) parts.add('学科：$subjectName');
  if (folderName != null) parts.add('文件夹：$folderName');
  if (examName != null) parts.add('考试：$examName');
  if (filter.causeName != null) parts.add('错因：${filter.causeName}');
  if (kpName != null) parts.add('知识点：$kpName');
  if (filter.timeRange == 'week') {
    parts.add('时间：最近一周');
  } else if (filter.timeRange == 'month') {
    parts.add('时间：最近 30 天');
  }
  if (parts.isEmpty) return '全部题目';
  return parts.join('；');
}

// ------------------------------------------------------------------
// 50 道上限：向导挑题状态（M1-DESIGN.md §2 第 1 点，M3 实现）。
// ------------------------------------------------------------------

/// 向导第 2 步的挑题状态（范围 + 已选集合）。
///
/// 默认全选圈定范围——不挑即等同筛选即导；范围超过 50 道时默认只选中
/// 前 50 道并给出明示（[initialNotice]，向导打开时即展示）。
/// 翻页 / 换筛选不丢已选：已选集合按题目 ID 持有，与当前页无关。
class ExportSelection {
  ExportSelection({required List<String> rangeIds})
    : _rangeIds = List.of(rangeIds),
      selectedIds = rangeIds.take(kExportMaxQuestions).toSet();

  /// 圈定范围的题目 ID（filteredAll() 顺序）。
  final List<String> _rangeIds;

  /// 已选题目 ID（按 ID 持有，与页无关；最大 50）。
  final Set<String> selectedIds;

  /// 圈定范围题数。
  int get rangeCount => _rangeIds.length;

  /// 已选题数。
  int get selectedCount => selectedIds.length;

  /// 打开向导 / 改范围后的默认全选提示（范围 > 50 时非空；≤ 50 时 null）。
  String? get initialNotice =>
      _rangeIds.length > kExportMaxQuestions
      ? selectFirst50Notice(_rangeIds.length)
      : null;

  /// 计数显示（只保留“已选 N / 50 道”；PLAN §6 的 100/200/500 档
  /// 提示已被 M1-DESIGN REV2 §2 作废，不得做）。
  String get countText => '已选 $selectedCount / $kExportMaxQuestions 道';

  /// 是否已选某题。
  bool isSelected(String id) => selectedIds.contains(id);

  /// 点选 / 取消点选一题。
  ///
  /// 返回 null 表示成功；返回非 null 表示拒绝原因（点选第 51 道时
  /// 返回“单次最多导出 50 道题”，本次选择不变）。
  String? toggle(String id) {
    if (selectedIds.contains(id)) {
      selectedIds.remove(id);
      return null;
    }
    if (selectedIds.length >= kExportMaxQuestions) {
      return '单次最多导出 50 道题';
    }
    selectedIds.add(id);
    return null;
  }

  /// 全选 = 替换为当前范围排序前 50 道（用户已手动选部分题再点全选
  /// 也是替换，不是追加；其余题目不进隐藏待导出队列）。
  ///
  /// 返回明示文案（范围 > 50 时为全选提示，≤ 50 时为 null）。
  String? selectAll() {
    selectedIds
      ..clear()
      ..addAll(_rangeIds.take(kExportMaxQuestions));
    return initialNotice;
  }

  /// 全不选。
  void selectNone() => selectedIds.clear();

  /// 确认前断言（M1-DESIGN §2 第 2 点）：超限则阻断生成并报错
  /// （防御性检查，正常流程下不可达）。
  String? capViolation() {
    if (selectedIds.length > kExportMaxQuestions) {
      return '单次最多导出 50 道题';
    }
    return null;
  }
}
