import '../data/database.dart';
import '../models/models.dart';

/// 仓库：各页面模块共用的查询口径（首页计数、错题本筛选、整理队列）。
/// 不直接读其他模块的状态，只读数据层。
class QuestionRepository {
  QuestionRepository(this._db);
  final AppDatabase _db;

  Future<List<Question>> all({bool includeArchived = false}) async {
    final list = await _db.allQuestions();
    return list.where((q) => includeArchived || !q.isArchived).toList();
  }

  /// 今日到期（含逾期）：复习中且下次复习 <= 今天。
  /// D-27 已确认（2026-11-12，用户决定）：首页只数已整理完的题
  /// （isOrganized），没整理完的题不计入首页今日到期 / 逾期 / 各科三数，
  /// 与错题本封面（只数已整理题）统一口径。
  Future<List<Question>> dueToday() async {
    final list = await all();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // 今日到期 = 已整理 + 未归档 + 复习中 + 有明确复习排程
    // （nextReview 非空且已到期，或已逾期）。刚导入、还没整理确认的题
    // nextReview 为空、无排程，不算到期（D-26）；演示数据里待整理题
    // 自带排程日期，D-27 起也不再计入——干净演示数据下首页今日到期
    // 由 7 道变为 3 道（数学 2→1、英语 3→2、政治 2→0，逾期仍 2 道），
    // 这是按用户决定统一口径的结果，不是 bug。
    return list
        .where((q) =>
            q.isOrganized &&
            !q.isArchived &&
            q.reviewStatus == ReviewStatus.inReview &&
            (q.overdueDays > 0 ||
                (q.nextReview != null && !q.nextReview!.isAfter(today))))
        .toList();
  }

  /// 各科三数：今日到期 / 复习中 / 已掌握（不显示总题数）。
  /// D-27 已确认：三数都只数已整理完的题（isOrganized）。
  Future<Map<String, (int due, int inReview, int mastered)>> subjectCounts() async {
    final list = await all();
    final due = await dueToday();
    final map = <String, (int, int, int)>{};
    for (final s in Subject.all) {
      final qs =
          list.where((q) => q.subjectId == s.id && q.isOrganized);
      map[s.id] = (
        due.where((q) => q.subjectId == s.id).length,
        qs.where((q) => q.reviewStatus == ReviewStatus.inReview).length,
        qs.where((q) => q.reviewStatus == ReviewStatus.mastered).length,
      );
    }
    return map;
  }

  Future<void> toggleFavorite(Question q) async =>
      _db.upsertQuestion(q.copyWith(isFavorite: !q.isFavorite));

  /// 待整理题数（左导航整理角标，D-04）：未确认整理且未归档。
  Future<int> pendingOrganizeCount() async {
    final list = await all();
    return list.where((q) => !q.isOrganized && !q.isArchived).length;
  }

  /// D-01：最近任务读写（表 recent_tasks，单行）。
  Future<({String kind, String subjectId, String title})?> recentTask() =>
      _db.recentTask();

  Future<void> saveRecentTask(
          {required String kind,
          required String subjectId,
          required String title}) =>
      _db.saveRecentTask(kind: kind, subjectId: subjectId, title: title);

  /// D-11：一键清空演示数据，返回删掉的题数。
  Future<int> clearDemoData() => _db.clearDemoData();

  Future<int> demoQuestionCount() => _db.demoQuestionCount();

  Future<void> archive(Question q, {bool archived = true}) async =>
      _db.upsertQuestion(q.copyWith(isArchived: archived));

  Future<void> save(Question q) async => _db.upsertQuestion(q);

  Future<void> delete(Question q) async => _db.deleteQuestion(q.id);

  /// 复习自评：会 / 不会。两次答对 → 已掌握，答错 → 回到复习中；
  /// 间隔 1 / 3 / 7 / 14 天（按复习次数推进）。
  Future<Question> applyReviewResult(Question q, bool correct) async {
    const intervals = [1, 3, 7, 14];
    final count = correct ? q.reviewCount + 1 : 0;
    final status =
        count >= 2 ? ReviewStatus.mastered : ReviewStatus.inReview;
    final next = status == ReviewStatus.mastered
        ? null
        : DateTime.now().add(
            Duration(days: intervals[count.clamp(0, intervals.length - 1)]));
    final updated = q.copyWith(
      reviewCount: count,
      reviewStatus: status,
      nextReview: next,
      overdueDays: 0,
    );
    await _db.upsertQuestion(updated);
    return updated;
  }
}
