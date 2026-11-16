// ARCH-PLAN-A 第 2 阶段（B 路）：学科管理页的状态层。
//
// 状态是 [SubjectsState]（学科 / 题目计数 / 知识点树 / 标签 / 试卷，
// 唯一真源仍是 SQLite；本 Provider 只做“响应式读取 + 写回”，
// 不另存一份）。读：`ref.watch(subjectsProvider)`；
// 写：`ref.read(subjectsProvider.notifier).addSubject(...)` 等。
//
// 页面本地 State（不进 Provider）：四段折叠展开、封面块展开、
// 章节展开、新增/改名输入框与目标、新试卷日期、试卷搜索词、
// 加载失败横幅的关闭——见 `subjects_page.dart`。
//
// 约定：改动方法返回 `({bool saved, String? message})`——
// `saved` 为真表示已写库并重读（页面做成功侧本地收尾，如清输入框）；
// `saved` 为假且 `message` 非空表示被拦下，页面只弹 SnackBar；
// `saved` 为假且 `message` 为空表示静默无操作（同名改名等）。
// 空名检查由调用方（页面）在调用前做，与原来页面内的检查同一位置。
// 方法只返回结果，不碰 BuildContext、不弹 Dialog、不调导航。
import 'dart:async';

import 'package:flutter/painting.dart' show Color, HSVColor;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/data_change_events.dart';
import '../data/repository.dart';
import '../models/models.dart';
import 'repository_provider.dart';

/// 学科管理页的状态 Provider（ARCH-PLAN-A 第 2 阶段）。
final subjectsProvider =
    NotifierProvider.autoDispose<SubjectsNotifier, SubjectsState>(
        SubjectsNotifier.new);

/// 学科管理页的全部业务数据（不含页面本地交互状态）。
class SubjectsState {
  const SubjectsState({
    this.subjects = const [],
    this.questionCounts = const {},
    this.tagCounts = const {},
    this.examCounts = const {},
    this.kps = const [],
    this.tags = const [],
    this.exams = const [],
    this.kpSubjectId,
    this.loading = true,
    this.loadError = false,
  });

  final List<Subject> subjects;

  /// 每科题数（key 学科 id）。
  final Map<String, int> questionCounts;

  /// 每个标签被多少道题用（key 标签名）。
  final Map<String, int> tagCounts;

  /// 每张试卷的题数（key 试卷 id）。
  final Map<String, int> examCounts;

  final List<KnowledgePoint> kps;
  final List<String> tags;
  final List<Exam> exams;

  /// 知识点树当前看哪一科（页签）；null 表示还没定，首读时取首科。
  final String? kpSubjectId;
  final bool loading;
  final bool loadError;

  SubjectsState copyWith({
    List<Subject>? subjects,
    Map<String, int>? questionCounts,
    Map<String, int>? tagCounts,
    Map<String, int>? examCounts,
    List<KnowledgePoint>? kps,
    List<String>? tags,
    List<Exam>? exams,
    String? kpSubjectId,
    bool? loading,
    bool? loadError,
  }) {
    return SubjectsState(
      subjects: subjects ?? this.subjects,
      questionCounts: questionCounts ?? this.questionCounts,
      tagCounts: tagCounts ?? this.tagCounts,
      examCounts: examCounts ?? this.examCounts,
      kps: kps ?? this.kps,
      tags: tags ?? this.tags,
      exams: exams ?? this.exams,
      kpSubjectId: kpSubjectId ?? this.kpSubjectId,
      loading: loading ?? this.loading,
      loadError: loadError ?? this.loadError,
    );
  }

  /// 某科的章节列表（按知识点首次出现顺序去重，与原来页面一致）。
  List<String> chaptersFor(String subjectId) {
    final chapters = <String>[];
    for (final kp in kps) {
      if (kp.subjectId == subjectId && !chapters.contains(kp.chapter)) {
        chapters.add(kp.chapter);
      }
    }
    return chapters;
  }

  String subjectName(String id) => subjects
      .where((s) => s.id == id)
      .map((s) => s.name)
      .firstOrNull ?? '数学';
}

/// 新学科的候选色（与 Subject.all 的 R1 新值同步，见原页面注释）。
/// 前 12 色按表取，12 色用完后按金角轮转生成，不回落第一色。
const _newSubjectColors = [
  Color(0xFF2E7CF6),
  Color(0xFF00A884),
  Color(0xFFEF4444),
  Color(0xFF7C5CFC),
  Color(0xFFF08A1D),
  Color(0xFF06B6D4),
  Color(0xFFEC4899),
  Color(0xFF14B8A6),
  Color(0xFF84CC16),
  Color(0xFFF59E0B),
  Color(0xFF6366F1),
  Color(0xFFF43F5E),
];

/// 环形色相距离（0..180°）：SR2-31——金角生成色与任一已用色 hue 差
/// 小于 25° 即视为撞色，继续步进直到拉开。
double _hueDistance(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

/// 学科管理页业务逻辑 + 业务数据（ARCH-PLAN-A 第 2 阶段：原
/// `subjects_page.dart` 的 `_SubjectsPageState` 里调 `repo` 的部分
/// 原样迁入；页面只留 widget 与本地交互状态）。
///
/// 拿库的方式与 `SettingsNotifier` 一致：经
/// `ref.read(repositoryProvider)` 拿——测试注入见
/// `docs/ui-replication/A-READING-GUIDE.md`（`ProviderContainer.test`
/// + `repositoryProvider.overrideWithValue`）。
class SubjectsNotifier extends Notifier<SubjectsState> {
  QuestionRepository get _repo => ref.read(repositoryProvider);

  bool _disposed = false;

  @override
  SubjectsState build() {
    ref.onDispose(() => _disposed = true);
    unawaited(load());
    return const SubjectsState();
  }

  /// 首读与每次写库后重读（与原来页面的 `_load` 同口径）：
  /// 学科、全部题（含已归档，计题数用）、知识点、标签、试卷；
  /// 读失败只置 `loadError`，不一直转圈。
  /// `kpSubjectId` 只在还没定时取首科（无科时回落 'math'），
  /// 已定时不随重读改变。
  Future<void> load() async {
    // D-42：build() 的 microtask 首查可能在页面已离开、Provider 已销毁后
    // 才跑——先判 _disposed 再碰 ref；repo 入口处捕获一次，之后不再 ref.read。
    if (_disposed) return;
    final repo = _repo;
    try {
      final subjects = await repo.subjects();
      final questions = await repo.all(includeArchived: true);
      final counts = <String, int>{};
      final tagCounts = <String, int>{};
      final examCounts = <String, int>{};
      for (final q in questions) {
        counts[q.subjectId] = (counts[q.subjectId] ?? 0) + 1;
        for (final t in q.tags) {
          tagCounts[t] = (tagCounts[t] ?? 0) + 1;
        }
        if (q.examId != null) {
          examCounts[q.examId!] = (examCounts[q.examId!] ?? 0) + 1;
        }
      }
      final kps = await repo.knowledgePoints();
      final tags = await repo.tags();
      final exams = await repo.exams();
      if (_disposed) return;
      state = state.copyWith(
        subjects: subjects,
        questionCounts: counts,
        tagCounts: tagCounts,
        examCounts: examCounts,
        kps: kps,
        tags: tags,
        exams: exams,
        kpSubjectId: state.kpSubjectId ??
            (subjects.isNotEmpty ? subjects.first.id : 'math'),
        loading: false,
        loadError: false,
      );
    } catch (_) {
      if (_disposed) return;
      state = state.copyWith(loading: false, loadError: true);
    }
  }

  /// 知识点树页签：换一科看（页面本地展开状态由页面自己清）。
  void selectKpSubject(String subjectId) {
    state = state.copyWith(kpSubjectId: subjectId);
  }

  // ---------- 学科 ----------

  /// 新增学科：重名拦下；新学科自动获得预置文件夹（试卷/平时作业/
  /// 模拟卷）。调用方先做空名检查。
  Future<({bool saved, String? message})> addSubject(String name) async {
    if (state.subjects.any((s) => s.name == name)) {
      return (saved: false, message: '已经有了这个学科');
    }
    final subject = Subject(
      id: 'subject-${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      color: _pickNewSubjectColor(),
      icon: name.isEmpty ? '学' : name[0],
      // 新学科封面默认灰色（Meng 2026-11-12 定）。模型默认值仍是蓝，
      // 只在这里显式传 grey，不动模型默认值，避免影响其他构造点。
      coverColor: 'grey',
    );
    // D-42：repo 入口处捕获一次（1 学科 + 3 预置文件夹跨多次 await，
    // 中途切页销毁 Provider 后再 ref.read 会抛 UnmountedRefException）。
    // 一次新增只发一个事件：scope 把 4 次写入的事件合并成一个。
    final repo = _repo;
    return DataChangeBus.instance.scope(() async {
      await repo.saveSubject(subject);
      // 新学科自动获得预置文件夹。
      const presetFolders = ['试卷', '平时作业', '模拟卷'];
      for (var i = 0; i < presetFolders.length; i++) {
        await repo.saveFolder(
          Folder(
            id: 'folder-${subject.id}-${presetFolders[i]}',
            name: presetFolders[i],
            subjectId: subject.id,
            sortOrder: i,
          ),
        );
      }
      await load();
      return (saved: true, message: null);
    });
  }

  Color _pickNewSubjectColor() {
    final usedColors = state.subjects.map((s) => s.color).toSet();
    return _newSubjectColors.firstWhere(
      (c) => !usedColors.contains(c),
      // 12 色用完后按金角（137.5°）轮转生成新色（SR-P2-51），
      // 不再回落到第一色（数学蓝）；撞色时再步进 37° 避开。
      // SR2-31：只防精确相等不够——金角起点恰好落在既有色旁边
      //（第 13 科 210° 距数学蓝仅 6.6°）；生成色与全部已用色算
      // 环形 hue 距离，小于 25° 时继续步进 37° 直到拉开。
      orElse: () {
        var hue = (usedColors.length * 137.5) % 360;
        var candidate = HSVColor.fromAHSV(1, hue, 0.65, 0.85).toColor();
        bool tooClose(double h) => usedColors.any(
          (c) => _hueDistance(HSVColor.fromColor(c).hue, h) < 25,
        );
        var guard = 0;
        while ((usedColors.contains(candidate) || tooClose(hue)) &&
            guard < 36) {
          hue = (hue + 37) % 360;
          candidate = HSVColor.fromAHSV(1, hue, 0.65, 0.85).toColor();
          guard++;
        }
        // SR3-21（Meng 定口径 (a)）：第 15 科起 37° 步进的 36 个格点
        // 全部落在 25° 禁区内，耗尽后不再原样返回违规色；改在 1°
        // 细粒度上扫描，取“与全部已用色最小色相距最大”的色相
        //（15 科时仍可达约 25°，16 科约 23°，之后随科数递减，
        // 但恒为当前最优而非任意色；第 23 科旧值只差 0.7° 的
        // 撞色不再出现）。
        if (usedColors.contains(candidate) || tooClose(hue)) {
          var bestHue = 0.0;
          var bestMin = -1.0;
          for (var h = 0; h < 360; h++) {
            var minDist = 180.0;
            for (final c in usedColors) {
              final d = _hueDistance(HSVColor.fromColor(c).hue, h.toDouble());
              if (d < minDist) minDist = d;
            }
            if (minDist > bestMin) {
              bestMin = minDist;
              bestHue = h.toDouble();
            }
          }
          hue = bestHue;
          candidate = HSVColor.fromAHSV(1, hue, 0.65, 0.85).toColor();
        }
        return candidate;
      },
    );
  }

  /// 学科改名：不存在或同名静默无操作；重名拦下。
  Future<({bool saved, String? message})> renameSubject(
    String id,
    String name,
  ) async {
    final s = state.subjects.where((e) => e.id == id).firstOrNull;
    if (s == null || s.name == name) return (saved: false, message: null);
    if (state.subjects.any((e) => e.name == name)) {
      return (saved: false, message: '已经有了这个学科');
    }
    await _repo.saveSubject(s.copyWith(name: name));
    await load();
    return (saved: true, message: null);
  }

  Future<void> deleteSubject(String id) async {
    await _repo.deleteSubject(id);
    await load();
  }

  /// 封面样式 / 颜色：点即生效（样式与颜色可任意搭配）。
  Future<void> setCover(Subject s, {String? style, String? color}) async {
    await _repo.saveSubject(
      s.copyWith(
        coverStyle: style ?? s.coverStyle,
        coverColor: color ?? s.coverColor,
      ),
    );
    await load();
  }

  // ---------- 知识点 ----------

  /// 新增章节（章节只随知识点存在：加章节须同时给第一个知识点）。
  /// 调用方先做“章节名和第一个知识点都要填”的空值检查。
  Future<({bool saved, String? message})> addChapter({
    required String subjectId,
    required String chapter,
    required String kpName,
  }) async {
    if (state.chaptersFor(subjectId).contains(chapter)) {
      return (saved: false, message: '已经有了这个章节');
    }
    await _repo.addKnowledgePoint(
      KnowledgePoint(
        id: 'kp-${DateTime.now().millisecondsSinceEpoch}',
        subjectId: subjectId,
        chapter: chapter,
        name: kpName,
      ),
    );
    await load();
    return (saved: true, message: null);
  }

  /// 章节内新增知识点。调用方先做空名检查。
  Future<({bool saved, String? message})> addKnowledgePoint({
    required String subjectId,
    required String chapter,
    required String name,
  }) async {
    await _repo.addKnowledgePoint(
      KnowledgePoint(
        id: 'kp-${DateTime.now().millisecondsSinceEpoch}',
        subjectId: subjectId,
        chapter: chapter,
        name: name,
      ),
    );
    await load();
    return (saved: true, message: null);
  }

  /// 章节改名：不存在或同名静默无操作；同科已有该章节名拦下。
  /// 成功时页面把本地展开状态里的旧章节名换成新名（见页面）。
  Future<({bool saved, String? message})> renameChapter(
    String subjectId,
    String oldChapter,
    String newChapter,
  ) async {
    if (oldChapter == newChapter) return (saved: false, message: null);
    if (state.chaptersFor(subjectId).contains(newChapter)) {
      return (saved: false, message: '已经有了这个章节');
    }
    await _repo.renameChapter(subjectId, oldChapter, newChapter);
    await load();
    return (saved: true, message: null);
  }

  Future<void> deleteChapter(String subjectId, String chapter) async {
    await _repo.deleteChapter(subjectId, chapter);
    await load();
  }

  /// 知识点改名：不存在或同名静默无操作（原来页面无重名检查）。
  Future<({bool saved, String? message})> renameKnowledgePoint(
    String id,
    String name,
  ) async {
    final kp = state.kps.where((e) => e.id == id).firstOrNull;
    if (kp == null || kp.name == name) return (saved: false, message: null);
    await _repo.renameKnowledgePoint(kp.id, name);
    await load();
    return (saved: true, message: null);
  }

  Future<void> deleteKnowledgePoint(String id) async {
    await _repo.deleteKnowledgePoint(id);
    await load();
  }

  // ---------- 标签 ----------

  /// 新增标签：禁逗号与竖线（§6 第 4 条）；重名拦下。
  /// 调用方先做空名检查。
  Future<({bool saved, String? message})> addTag(String name) async {
    if (hasBannedNameSeparator(name)) {
      return (saved: false, message: '不能含逗号或竖线');
    }
    if (state.tags.contains(name)) {
      return (saved: false, message: '已经有了这个标签');
    }
    await _repo.addTag(name);
    await load();
    return (saved: true, message: null);
  }

  /// 标签改名：同名静默无操作；禁逗号与竖线；重名拦下。
  Future<({bool saved, String? message})> renameTag(
    String oldName,
    String newName,
  ) async {
    if (oldName == newName) return (saved: false, message: null);
    if (hasBannedNameSeparator(newName)) {
      return (saved: false, message: '不能含逗号或竖线');
    }
    if (state.tags.contains(newName)) {
      return (saved: false, message: '已经有了这个标签');
    }
    await _repo.renameTag(oldName, newName);
    await load();
    return (saved: true, message: null);
  }

  Future<void> deleteTag(String name) async {
    await _repo.deleteTag(name);
    await load();
  }

  // ---------- 试卷 ----------

  /// 新增试卷。调用方先做空名检查。
  Future<({bool saved, String? message})> addExam(
    String name,
    DateTime date,
  ) async {
    if (state.exams.any((e) => e.name == name)) {
      return (saved: false, message: '已经有了这张试卷');
    }
    await _repo.addExam(
      Exam(
        id: 'exam-${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        date: date,
      ),
    );
    await load();
    return (saved: true, message: null);
  }

  /// 试卷改名：不存在或同名静默无操作；重名拦下。
  Future<({bool saved, String? message})> renameExam(
    String id,
    String name,
  ) async {
    final e = state.exams.where((e) => e.id == id).firstOrNull;
    if (e == null || e.name == name) return (saved: false, message: null);
    if (state.exams.any((e) => e.name == name)) {
      return (saved: false, message: '已经有了这张试卷');
    }
    await _repo.renameExam(e.id, name);
    await load();
    return (saved: true, message: null);
  }

  Future<void> deleteExam(String id) async {
    await _repo.deleteExam(id);
    await load();
  }
}
