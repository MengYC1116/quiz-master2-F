// ARCH-PLAN-A 第 3 阶段：详情页的状态层。
//
// 状态是 [DetailState]（当前题 + 元数据 + 编辑表单值），唯一真源仍是
// SQLite；本 Provider 只做“响应式读取 + 写回”，不另存一份。
// 读：`ref.watch(detailProvider)`；
// 写：`ref.read(detailProvider.notifier).saveEdit(...)` 等。
//
// 详情页有初始入参（题目 id 与来源列表），按 D-35 的
// `wrongbookInitialProvider` 模式用 [detailInitialProvider]
// （[DetailInitial]：`questionId` / `orderIds`）注入，
// Notifier 的 `build()` 里读它定初始题与顺序，不在页面 `initState`
// 里同步改 Provider（Riverpod 禁止在 build / initState 等生命周期
// 里同步改 Provider）。
//
// 文本控制器是页面本地 UI 状态，留在页面里；进编辑时 Notifier 把
// 编辑表单值按当前题重建并把 `formResetKey` 加一，页面按它变化、
// 下一帧把控制器文本按当前题重建（D-40①，见 `question_detail_page.dart`
// 的 `_syncFormFromState`）。折叠区开合、答案可见、编辑/脏态、
// 取消确认框是纯界面状态，留页面本地 setState，不进 Provider。
//
// 重新框选（§1.5.1）的业务在 [DetailNotifier.applyReworkBoxes] 里：
// 裁切片 → 写临时文件 → 单事务换框 + 保存切片 → rename → 清缓存，
// 事务失败只删临时文件、旧切片字节完好（SR2-3）；页图读不出来 /
// 裁不出来、临时文件写不进去、rename 失败各有自己的返回值，
// 页面按返回值弹对应提示。编辑器弹窗本身（`showBoxEditorDialog`）
// 要 `BuildContext`，留在页面里开，结果交进来。
// 切片自愈（SR3-10）也在本 Notifier 里：打开页时校验磁盘切片尺寸与
// 库里是否一致，不一致按当前第一个 1 层框重裁、原子替换，
// 尺寸变了再把库里尺寸改成重裁尺寸；失败静默，下次打开再试。
//
// Provider 是 autoDispose（D-36 结论）：页面独占、随页生死，
// 回页重建并重读库。`build()` 里 `Future.microtask(load)` 首查
// + `_disposed` 守门（沿用 Stage 2/3 模式）。
//
// 构造器接进来的 `repo` 怎么进依赖图：`QuestionDetailPage` 在 build
// 里包一层 `ProviderScope(overrides: [repositoryProvider
// .overrideWithValue(widget.repo), detailInitialProvider
// .overrideWithValue(...)])`——`app.dart` 仍按老样子传，
// 不用改；测试里构造器传 FakeRepo 同样经这一层注入，不用再包
// 一层 ProviderScope。本文件不认识任何 widget，不碰 `BuildContext`、
// 不弹 Dialog、不调导航。角标走 `badgeCountsProvider`（第 4 阶段：
// 订阅 `DataChangeBus`，见 `badge_counts_provider.dart`）。
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/repository.dart';
import '../models/models.dart';
import '../services/import_service.dart';
import '../services/page_image_pipeline.dart';
import 'repository_provider.dart';

/// 详情页业务状态的 Provider：页面出现即读库（见 [DetailNotifier.build]）。
final detailProvider =
    NotifierProvider.autoDispose<DetailNotifier, DetailState>(
      DetailNotifier.new,
    );

/// 详情页的构造参数（初始落点）：题目 id 与来源列表（上一题 / 下一题
/// 按它走）。页面外壳经 `ProviderScope` 注入；Notifier 的 `build()`
/// 里读它，不在 `initState` 里改 Provider（D-35 的
/// `wrongbookInitialProvider` 模式）。
class DetailInitial {
  const DetailInitial({required this.questionId, required this.orderIds});

  final String questionId;
  final List<String> orderIds;

  @override
  bool operator ==(Object other) =>
      other is DetailInitial &&
      other.questionId == questionId &&
      other.orderIds.length == orderIds.length &&
      other.orderIds.asMap().entries.every((e) => e.value == orderIds[e.key]);

  @override
  int get hashCode => Object.hash(questionId, Object.hashAll(orderIds));
}

/// 初始落点 Provider：默认空（无题）；页面外壳按构造参数 override。
final detailInitialProvider = Provider<DetailInitial>(
  (ref) => const DetailInitial(questionId: '', orderIds: []),
);

/// 重新框选确认的结果（原 `_reworkBoxes` 里各失败分支的提示一一对应，
/// 页面按返回值弹提示；成功时 Notifier 已重读，写库已发变更事件）。
enum ReworkOutcome {
  /// 成功：框已换、切片已重裁并落盘、已重读。
  success,

  /// 页图读不出来 / 切片裁不出来。
  cropFailed,

  /// 切片写不进去：数据目录不可用。
  sliceUnavailable,

  /// 重新框选失败：切片写不进去（临时文件写盘失败）。
  tmpWriteFailed,

  /// 重新框选失败：保存失败，请重试（事务失败，只删临时文件）。
  saveFailed,

  /// 重新框选失败：切片保存失败，框已更新，请重试（rename 失败）。
  renameFailed,
}

/// `copyWith` 里“显式置 null”与“不改”的区分标记。
const _unset = Object();

/// 详情页的全部业务数据 + 编辑表单值（原 `_QuestionDetailPageState`
/// 里调 `repo` 的字段与编辑表单值原样搬移；文本控制器、折叠区开合、
/// 答案可见、编辑/脏态、取消确认框仍在页面本地，不在这里）。
class DetailState {
  const DetailState({
    this.loading = true,
    this.question,
    this.orderIds = const [],
    this.currentId = '',
    this.records = const [],
    this.history = const [],
    this.exams = const [],
    this.folders = const [],
    this.allTags = const [],
    this.kps = const [],
    this.subjects = const [],
    this.editErrorTypes = const {},
    this.editCustomTypes = const {},
    this.editFolders = const {},
    this.editTags = const {},
    this.editKps = const {},
    this.editExamId,
    this.editBase,
    this.formResetKey = 0,
  });

  /// 首查进行中（原 `_loading`；初始 true，首帧先出加载圈）。
  final bool loading;

  /// 当前题（原 `_q`；null 表示题不存在了）。
  final Question? question;

  /// 来源列表（原 `_orderIds`；上一题 / 下一题按它走，删题时去掉已删题）。
  final List<String> orderIds;

  /// 当前题 id（原 `_currentId`）。
  final String currentId;

  /// 当前题的错因记录与全部解决记录。
  final List<CauseRecord> records;
  final List<({String result, DateTime reviewedAt})> history;

  /// 元数据：试卷 / 文件夹（全部学科，原 `_load` 读 `folders()` 不带
  /// 学科过滤——D-40③：不要顺手改成按学科读）/ 标签 / 知识点 / 学科表。
  final List<Exam> exams;
  final List<Folder> folders;
  final List<String> allTags;
  final List<KnowledgePoint> kps;

  /// 学科表：读库 subjects（P0B1 扫尾；以前直接 Subject.byId，
  /// 新学科显示成“数学”）。B8-1 扫尾：空表是删光学科后的合法状态，
  /// 不再回退预设三科；首帧与读库后都以真实列表为准，空就是空。
  final List<Subject> subjects;

  // ---- 编辑表单值（当前题；文本框内容在页面控制器里，不在这里） ----

  final Set<String> editErrorTypes;
  final Set<String> editCustomTypes;
  final Set<String> editFolders;
  final Set<String> editTags;
  final Set<String> editKps;
  final String? editExamId;

  /// 进编辑时的题快照（原 `_editBase`；保存时以它为底构造新题，
  /// 学科与图片字段都从它带上，编辑一次不抹图）。
  final Question? editBase;

  /// 表单重置代次：每次进编辑（`enterEdit`）加一，页面按它变化、
  /// 下一帧把控制器文本按当前题重建（原 `_enterEdit` 里设控制器
  /// 文本的部分）。
  final int formResetKey;

  /// 库里找学科：新学科用库里的名与色；找不到才回退 Subject.byId
  ///（数学兜底，只发生在数据不一致时）。
  Subject subjectOf(String id) =>
      subjects.firstWhere((s) => s.id == id, orElse: () => Subject.byId(id));

  DetailState copyWith({
    bool? loading,
    Object? question = _unset,
    List<String>? orderIds,
    String? currentId,
    List<CauseRecord>? records,
    List<({String result, DateTime reviewedAt})>? history,
    List<Exam>? exams,
    List<Folder>? folders,
    List<String>? allTags,
    List<KnowledgePoint>? kps,
    List<Subject>? subjects,
    Set<String>? editErrorTypes,
    Set<String>? editCustomTypes,
    Set<String>? editFolders,
    Set<String>? editTags,
    Set<String>? editKps,
    Object? editExamId = _unset,
    Object? editBase = _unset,
    int? formResetKey,
  }) {
    return DetailState(
      loading: loading ?? this.loading,
      question: question == _unset ? this.question : question as Question?,
      orderIds: orderIds ?? this.orderIds,
      currentId: currentId ?? this.currentId,
      records: records ?? this.records,
      history: history ?? this.history,
      exams: exams ?? this.exams,
      folders: folders ?? this.folders,
      allTags: allTags ?? this.allTags,
      kps: kps ?? this.kps,
      subjects: subjects ?? this.subjects,
      editErrorTypes: editErrorTypes ?? this.editErrorTypes,
      editCustomTypes: editCustomTypes ?? this.editCustomTypes,
      editFolders: editFolders ?? this.editFolders,
      editTags: editTags ?? this.editTags,
      editKps: editKps ?? this.editKps,
      editExamId: editExamId == _unset
          ? this.editExamId
          : editExamId as String?,
      editBase: editBase == _unset ? this.editBase : editBase as Question?,
      formResetKey: formResetKey ?? this.formResetKey,
    );
  }
}

/// 详情页业务逻辑（ARCH-PLAN-A 第 3 阶段：原 `question_detail_page.dart`
/// 的 `_QuestionDetailPageState` 里调 `repo` 的部分原样迁入；
/// 页面只留 widget 与本地交互状态——文本控制器、折叠区开合、
/// 答案可见、编辑/脏态、取消确认框、弹窗与 SnackBar）。
///
/// 拿库的方式与 `ReviewNotifier` / `OrganizeNotifier` 一致：经
/// `ref.read(repositoryProvider)` 拿——测试注入见
/// `docs/ui-replication/A-READING-GUIDE.md`（`ProviderContainer.test`
/// + `repositoryProvider.overrideWithValue`）。
class DetailNotifier extends Notifier<DetailState> {
  QuestionRepository get _repo => ref.read(repositoryProvider);

  bool _disposed = false;

  /// SR3-10：切片自愈的去重键（题 id + 切片路径 + 库里记的尺寸）与
  /// 进行中标志。只对同一组合校验一次：尺寸相符或自愈成功后不再
  /// 重复读盘；自愈失败时不记键，下次 load 再试（用户仍可手动重框）。
  String? _sliceHealCheckedKey;
  bool _sliceHealRunning = false;

  @override
  DetailState build() {
    ref.onDispose(() => _disposed = true);
    // 页面出现即读库（原 `initState` 的 `_load`）：不 await，
    // 读完后 state 一次性赋值，首帧先出加载圈。
    Future.microtask(load);
    final initial = ref.read(detailInitialProvider);
    return DetailState(
      orderIds: List.of(initial.orderIds),
      currentId: initial.questionId,
    );
  }

  /// 首读与每次写库后重读（与原来页面的 `_load` 同口径）：
  /// 读当前题 → 错因记录 → 解决记录 → 试卷 / 文件夹（全部学科，
  /// 不带学科过滤，见 `DetailState` 注释）/ 标签 / 知识点 / 学科表。
  /// 读完把当前题交给切片自愈（后台修复，不挡页面渲染，见
  /// `_healSliceIfNeeded`）。
  Future<void> load() async {
    // D-42：build() 的 microtask 首查可能在页面已离开、Provider 已销毁后
    // 才跑——先判 _disposed 再碰 ref；repo 入口处捕获一次，之后不再 ref.read。
    if (_disposed) return;
    final repo = _repo;
    final q = await repo.questionById(state.currentId);
    final records = q == null
        ? <CauseRecord>[]
        : await repo.causeRecordsFor(q.id);
    final history = q == null
        ? <({String result, DateTime reviewedAt})>[]
        : await repo.reviewHistory(q.id);
    final exams = await repo.exams();
    final folders = await repo.folders();
    final tags = await repo.tags();
    final kps = await repo.knowledgePoints();
    final subjects = await repo.subjects();
    if (_disposed) return;
    state = state.copyWith(
      question: q,
      records: records,
      history: history,
      exams: exams,
      folders: folders,
      allTags: tags,
      kps: kps,
      subjects: subjects,
      loading: false,
    );
    // SR3-10：打开详情页时自愈“库新图旧”的崩溃窗口（事务提交后、
    // rename 前被杀）。不 await：自愈是后台修复，不挡页面渲染；
    // 失败静默（见方法内注释），下次打开再试。
    if (q != null) unawaited(_healSliceIfNeeded(q));
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
    // D-42：repo 入口处捕获一次（读框与改尺寸跨多次 await）。
    final repo = _repo;
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
      final boxes = await repo.boxesForPageImage(q.pageImagePath!);
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
        await repo.save(
          q.copyWith(sliceWidth: crop.width, sliceHeight: crop.height),
        );
      }
      _sliceHealCheckedKey =
          '${q.id}|${q.slicePath}|${crop.width}x${crop.height}';
      if (!_disposed) await load();
    } catch (e) {
      // 自愈是后台兜底：任何一步失败都不打扰用户、不抛到界面，
      // 只记日志；下次打开详情页（load）会再试一次。
      // 页面已离开（Provider 已销毁）时尾部的重读会因 ref 已销毁而抛错，
      // 那不是自愈本身失败，不记日志。
      if (_disposed) return;
      debugPrint('SR3-10：切片自愈失败（${q.id}）：$e');
    } finally {
      _sliceHealRunning = false;
    }
  }

  // ---------- 编辑 ----------

  /// 进编辑模式（原 `_enterEdit` 里表单值的部分）：按当前题重建
  /// 编辑表单值，`formResetKey` 加一，页面按它变化、下一帧把控制器
  /// 文本按当前题重建。无当前题时直接返回。折叠区展开、焦点字段
  /// 由页面本地处理，不进这里。
  void enterEdit() {
    final q = state.question;
    if (q == null) return;
    state = state.copyWith(
      editBase: q,
      // SR-P2-27：旧数据里与固定枚举同名的自定义错因，读入编辑表单时
      // 就合并进固定项（不丢错因、不重复显示）；保存时写回即完成迁移。
      editErrorTypes: {
        ...q.errorTypes,
        ...q.customErrorTypes.where((t) => ErrorTypes.fixed.contains(t)),
      },
      editCustomTypes: q.customErrorTypes
          .where((t) => !ErrorTypes.fixed.contains(t))
          .toSet(),
      editFolders: q.folderIds.toSet(),
      editTags: q.tags.toSet(),
      editKps: q.knowledgePointIds.toSet(),
      editExamId: q.examId,
      formResetKey: state.formResetKey + 1,
    );
  }

  // ---------- 编辑表单值：具名改动口（D-35：优先用命名方法，少用泛型 update） ----------

  void toggleEditFolder(String id) {
    final ids = {...state.editFolders};
    if (ids.contains(id)) {
      ids.remove(id);
    } else {
      ids.add(id);
    }
    state = state.copyWith(editFolders: ids);
  }

  void toggleEditKp(String id) {
    final ids = {...state.editKps};
    if (ids.contains(id)) {
      ids.remove(id);
    } else {
      ids.add(id);
    }
    state = state.copyWith(editKps: ids);
  }

  void toggleEditErrorType(String t) {
    final list = {...state.editErrorTypes};
    if (list.contains(t)) {
      list.remove(t);
    } else {
      list.add(t);
    }
    state = state.copyWith(editErrorTypes: list);
  }

  void toggleEditTag(String t) {
    final list = {...state.editTags};
    if (list.contains(t)) {
      list.remove(t);
    } else {
      list.add(t);
    }
    state = state.copyWith(editTags: list);
  }

  void removeEditCustomType(String t) {
    state = state.copyWith(
      editCustomTypes: state.editCustomTypes.where((x) => x != t).toSet(),
    );
  }

  void setEditExamId(String? id) {
    state = state.copyWith(editExamId: id);
  }

  /// 保存编辑（原 `_saveEdit`）：文本框内容由页面从控制器读了传进来。
  /// SR-P2-27：与固定枚举同名的自定义错因合并进固定项再保存（旧代码
  /// 在这里直接滤掉，错因静默消失；新建入口已拦同名，这里是兜底，
  /// 覆盖旧数据里已有的同名自定义项）。保存后重读（原 `_saveEdit`
  /// 末尾的 `_load`）。无进编辑的快照时直接返回。
  Future<void> saveEdit({
    required String title,
    required String answer,
    required String explanation,
    required String notes,
  }) async {
    final base = state.editBase;
    if (base == null) return;
    // D-42：repo 入口处捕获一次（保存 + 同步错因记录跨两次 await）。
    final repo = _repo;
    final fixedFromCustom = state.editCustomTypes
        .where((t) => ErrorTypes.fixed.contains(t))
        .toList();
    final customNew = state.editCustomTypes
        .where((t) => !ErrorTypes.fixed.contains(t))
        .toList();
    final errorTypes = {...state.editErrorTypes, ...fixedFromCustom}.toList();
    final updated = Question(
      id: base.id,
      title: title.trim().isEmpty ? base.title : title.trim(),
      subjectId: base.subjectId,
      folderIds: state.editFolders.toList(),
      examId: state.editExamId,
      knowledgePointIds: state.editKps.toList(),
      errorTypes: errorTypes,
      customErrorTypes: customNew,
      tags: state.editTags.toList(),
      answer: answer.trim().isEmpty ? null : answer.trim(),
      explanation: explanation.trim().isEmpty ? null : explanation.trim(),
      notes: notes.trim().isEmpty ? null : notes.trim(),
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
    await repo.save(updated);
    await repo.syncCauseRecords(updated);
    await load();
  }

  // ---------- 上一题 / 下一题 / 删除 ----------

  /// 切到 [id] 对应的题（原 `_goTo` 里改下标 + `_load` 的部分）：
  /// 改当前题 id 并重读。编辑态等纯界面状态由页面先复位，不进这里。
  Future<void> goTo(String id) async {
    state = state.copyWith(currentId: id);
    await load();
  }

  /// 删除当前题（原 `_doDelete` 里删库 + 定下一题的部分）：
  /// 返回下一题 id；没有下一题时返回 null（页面离开本页）。
  /// 删后把已删题从来源列表里去掉；有下一题时切过去并重读。
  Future<String?> deleteCurrent() async {
    final q = state.question;
    if (q == null) return null;
    final idx = state.orderIds.indexOf(q.id);
    final nextId = idx >= 0 && idx + 1 < state.orderIds.length
        ? state.orderIds[idx + 1]
        : null;
    await _repo.delete(q);
    final orderIds = [...state.orderIds]..remove(q.id);
    state = state.copyWith(orderIds: orderIds);
    if (nextId != null && nextId != q.id) {
      state = state.copyWith(currentId: nextId);
      await load();
      return nextId;
    }
    return null;
  }

  // ---------- 收藏 / 归档 / 加入复习 ----------

  /// 收藏切换（原 `_toggleFavorite`）：写库后重读。
  Future<void> toggleFavorite() async {
    final q = state.question;
    if (q == null) return;
    await _repo.toggleFavorite(q);
    await load();
  }

  /// 归档切换（原 `_toggleArchive`）：写库后重读。
  Future<void> toggleArchive() async {
    final q = state.question;
    if (q == null) return;
    await _repo.archive(q, archived: !q.isArchived);
    await load();
  }

  /// 加入 / 取消加入复习（原 `_toggleReviewJoined`）：
  /// 返回 false 时页面弹“先补错误类型”（未加入且无错因，或写库
  /// 返回 false）。成功后重读；写库已发变更事件。
  Future<bool> toggleReviewJoined() async {
    final q = state.question;
    if (q == null) return false;
    if (!q.reviewJoined) {
      if (q.allCauses.isEmpty) return false;
      final ok = await _repo.setReviewJoined(q, true);
      if (!ok) return false;
    } else {
      await _repo.setReviewJoined(q, false);
    }
    await load();
    return true;
  }

  // ---------- 重新框选 §1.5.1 ----------

  /// 读同页全部 1 层框（原 `_reworkBoxes` 开头的读框；页面按题 id
  /// 分目标题 / 只读他题，再开编辑器弹窗）。
  Future<List<QuestionBox>> boxesForPageImage(String pageImagePath) =>
      _repo.boxesForPageImage(pageImagePath);

  /// 重新框选确认后的业务（原 `_reworkBoxes` 里编辑器返回之后的部分）：
  /// 重裁切片 → 先写临时文件再落库（SR2-3：旧写法先原地覆盖正式
  /// 切片，事务失败时 catch 删掉的是刚覆盖掉旧图的唯一一份切片，
  /// 题从此无图。改成临时文件 + 事务成功后 rename，失败只删临时
  /// 文件，旧切片字节完好、框与题不动）。
  /// SR3-11：读页图 + 裁切片同样可能失败（页图损坏截断、框落在图外），
  /// 与写临时文件/事务/rename 三处同款包 try/catch，失败给返回值、
  /// 不抛到按钮回调。
  /// 成功时清 FileImage 缓存并重读（原 `_reworkBoxes` 末尾的
  /// `_load`）；页面弹“已重新框选，切片已更新”。写库已发变更事件。
  /// [pageAbs] 是页图的绝对路径（页面已校验文件存在才调进来）；
  /// [newLayer1] 非空（页面已校验“至少保留一个题级框”才调进来）。
  Future<ReworkOutcome> applyReworkBoxes(
    List<QuestionBox> newLayer1,
    String pageAbs,
  ) async {
    final q = state.question;
    if (q == null) return ReworkOutcome.cropFailed;
    // D-42：repo 入口处捕获一次（裁切片与写库之间有多次 await）。
    final repo = _repo;
    final ({Uint8List png, int width, int height}) crop;
    try {
      final pageBytes = await File(pageAbs).readAsBytes();
      final first = newLayer1.first;
      crop = await cropBoxPng(pageBytes, first);
    } catch (_) {
      return ReworkOutcome.cropFailed;
    }
    final sliceRel = ImportService.sliceRelative(q.id);
    final sliceAbs = AppDatabase.resolveDataPath(sliceRel);
    if (sliceAbs == null) return ReworkOutcome.sliceUnavailable;
    // 临时切片与正式切片同目录，rename 是同文件系统内的原子替换；
    // 随机后缀防两次重框撞名，也防失败残留被误删成他人的文件。
    // 进程在写临时文件与 rename 之间被杀会留一个孤儿临时文件，
    // 由 §4.5 孤儿扫描兜底（slices/ 下无引用文件）。
    // SR3-10：进程在事务提交后、rename 前被杀是另一个崩溃窗口——
    // 库里已是新切片尺寸、磁盘仍是旧图；孤儿扫描扫不到它（旧图仍被
    // slice_path 引用）。自愈在打开详情页时做（见 `_healSliceIfNeeded`）：
    // 切片实际尺寸与库里 sliceWidth/sliceHeight 不符就按当前框重裁。
    final tmpRel =
        'slices/${q.id}.tmp-${DateTime.now().millisecondsSinceEpoch}-${math.Random().nextInt(1 << 32)}.png';
    final tmpAbs = AppDatabase.resolveDataPath(tmpRel);
    if (tmpAbs == null) return ReworkOutcome.sliceUnavailable;
    try {
      await File(tmpAbs).parent.create(recursive: true);
      await File(tmpAbs).writeAsBytes(crop.png);
    } catch (_) {
      return ReworkOutcome.tmpWriteFailed;
    }
    // B3-P01：换框 + 保存切片一个事务（任一步失败一起回滚，
    // 不留“框换了、切片还是旧的”的不一致）。
    // SR2-3：事务失败时只删临时文件——正式路径上的旧切片从未被
    // 动过；B5 的旧写法此时删的是刚覆盖掉旧图的正式文件。
    try {
      await repo.replaceQuestionBoxesAndSlice(
        q.id,
        newLayer1,
        slicePath: sliceRel,
        sliceWidth: crop.width,
        sliceHeight: crop.height,
      );
    } catch (_) {
      try {
        final file = File(tmpAbs);
        if (file.existsSync()) await file.delete();
      } catch (_) {}
      return ReworkOutcome.saveFailed;
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
      return ReworkOutcome.renameFailed;
    }
    await evictCachedFileImage(sliceAbs);
    await load();
    return ReworkOutcome.success;
  }

  // ---------- 内联新建（原 `_newTag` / `_newFolder` /
  // `_newKnowledgePoint` / `_newExam` / `_newCustomErrorType`
  // 里调 `repo` 的部分；弹窗与文案校验留在页面） ----------

  /// 新建标签（原 `_newTag`）：写库后重读（原 `_load`），再把新建的
  /// 选进编辑表单（原 `_load` 前后两次 `setState` 都是加同一个名，
  /// 合并为重读后加一次）。标签名禁逗号与竖线由页面先校验，不进这里。
  Future<void> submitNewTag(String name) async {
    await _repo.addTag(name);
    await load();
    if (_disposed) return;
    state = state.copyWith(
      editTags: state.editTags.contains(name)
          ? state.editTags
          : {...state.editTags, name},
    );
  }

  /// 新建文件夹（原 `_newFolder` 里写库的部分）：返回新建的文件夹 id；
  /// 整科同名（预检命中，或写入时 StateError 兜底）返回 null，
  /// 页面弹“已经有了”。成功后重读并把新建的选进编辑表单。
  /// 父文件夹由页面先在对话框里定好传进来（SR-P2-26 的返回值区分
  /// 仍在页面）。
  Future<String?> submitNewFolder(String name, String? parentId) async {
    final q = state.question;
    if (q == null) return null;
    // D-42：repo 入口处捕获一次（预检与保存跨多次 await，`on StateError`
    // 接不住 UnmountedRefException）。
    final repo = _repo;
    // SR-P2-36：整科同名预检（新建不传 excludeId），命中返回 null；
    // 仍留 StateError 捕获作兜底（预检与写入之间的竞态）。
    if (await repo.folderNameExistsInSubject(q.subjectId, name)) {
      return null;
    }
    final id = newEntityId('folder-${q.subjectId}');
    try {
      await repo.saveFolder(
        Folder(
          id: id,
          name: name,
          subjectId: q.subjectId,
          parentId: parentId,
          sortOrder: 0,
        ),
      );
    } on StateError {
      return null;
    }
    await load();
    if (_disposed) return id;
    state = state.copyWith(
      editFolders: state.editFolders.contains(id)
          ? state.editFolders
          : {...state.editFolders, id},
    );
    return id;
  }

  /// 新建知识点（原 `_newKnowledgePoint`）：返回新建的知识点 id；
  /// 成功后重读并把新建的选进编辑表单。章节由页面先在对话框里定好。
  Future<String> submitNewKnowledgePoint(String chapter, String name) async {
    final q = state.question;
    // 无当前题时仍按原代码走不到这里；防御性返回空串，页面不依赖它。
    if (q == null) return '';
    final id = newEntityId('kp-${q.subjectId}');
    await _repo.addKnowledgePoint(
      KnowledgePoint(id: id, subjectId: q.subjectId, chapter: chapter, name: name),
    );
    await load();
    if (_disposed) return id;
    state = state.copyWith(
      editKps: state.editKps.contains(id) ? state.editKps : {...state.editKps, id},
    );
    return id;
  }

  /// 新建试卷（原 `_newExam`）：返回新建的试卷 id；成功后重读并把
  /// 新建的归属到这道题。
  Future<String> submitNewExam(String name) async {
    final id = newEntityId('exam');
    await _repo.addExam(Exam(id: id, name: name));
    await load();
    if (_disposed) return id;
    state = state.copyWith(editExamId: id);
    return id;
  }

  /// 自定义错误类型（原 `_newCustomErrorType` 里改编辑表单的部分，
  /// 与整理页 `addCustomType` 同款）：
  /// 与固定枚举同名时不进自定义集合，直接选中对应固定项，
  /// 返回 true（页面提示“是固定错误类型，已帮你选中”）；
  /// 否则进自定义集合，返回 false。
  /// 空名与禁逗号竖线由页面先校验，不进这里。
  bool addCustomType(String name) {
    // SR-P2-27：与固定枚举同名时不进自定义集合，直接选中对应固定项
    //（否则 allCauses 里出现两次“其他”，详情页副标题与复习记录的
    // 错因行都会重复；详情页保存还会把它静默滤掉、错因直接消失）。
    if (ErrorTypes.fixed.contains(name)) {
      state = state.copyWith(
        editErrorTypes: state.editErrorTypes.contains(name)
            ? state.editErrorTypes
            : {...state.editErrorTypes, name},
      );
      return true;
    }
    state = state.copyWith(
      editCustomTypes: state.editCustomTypes.contains(name)
          ? state.editCustomTypes
          : {...state.editCustomTypes, name},
    );
    return false;
  }
}
