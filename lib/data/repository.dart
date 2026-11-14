import '../data/database.dart';
import '../models/models.dart';
import '../services/import_service.dart';

/// 仓库：各页面模块共用的查询口径（首页计数、错题本筛选、整理队列、复习）。
/// 不直接读其他模块的状态，只读数据层。
/// v2：旧翻卡 + 1/3/7/14 天间隔已废弃；复习是治错因模型。
class QuestionRepository {
  QuestionRepository(this._db);
  final AppDatabase _db;

  AppDatabase get db => _db;

  Future<List<Question>> all({bool includeArchived = false}) async {
    final list = await _db.allQuestions();
    return list.where((q) => includeArchived || !q.isArchived).toList();
  }

  Future<Question?> questionById(String id) => _db.questionById(id);

  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
          String questionId) =>
      _db.reviewHistory(questionId);

  // ---------- 错因复习模型 ----------

  Future<List<CauseRecord>> causeRecords() => _db.allCauseRecords();

  Future<List<CauseRecord>> causeRecordsFor(String questionId) =>
      _db.causeRecordsForQuestion(questionId);

  Future<void> saveCauseRecord(CauseRecord r) => _db.upsertCauseRecord(r);

  /// 手动加入 / 取消加入复习：加入时给这道题建解决记录（每个错因一条）；
  /// 取消后记录保留，再加入时接着治。错因是空的题加不进复习，返回 false。
  Future<bool> setReviewJoined(Question q, bool joined) async {
    final causes = q.allCauses;
    if (joined && causes.isEmpty) return false;
    await _db.upsertQuestion(q.copyWith(reviewJoined: joined));
    if (joined) await _db.ensureCauseRecords(q);
    return true;
  }

  /// 同步某题的解决记录与它当前的错因：删掉已不在错因里的记录，
  /// 给新加的错因补一条待解决记录（仅已加入复习的题）。
  Future<void> syncCauseRecords(Question q) async {
    if (!q.reviewJoined) return;
    final causes = q.allCauses.toSet();
    final records = await _db.allCauseRecords();
    for (final r in records) {
      if (r.questionId == q.id && !causes.contains(r.cause)) {
        await _db.deleteCauseRecord(r.questionId, r.cause);
      }
    }
    await _db.ensureCauseRecords(q);
  }

  /// 要复习的题：手动加入复习、已整理、至少一个错因还没解决
  /// （待解决 / 解决中）或到了复查时间。数题不数错因。
  /// 已归档的题不算（与复习页 B6 主列表同口径；记录保留在库里，
  /// 取消归档后重新计入）。`includeArchived: true` 仅供显式
  /// 需要时用，默认排除。
  Future<List<Question>> dueToday({bool includeArchived = false}) async {
    final questions = await all(includeArchived: includeArchived);
    // 记录走仓库方法 causeRecords()（与 _db.allCauseRecords() 同义，
    // 便于单测覆盖；subjectCounts 同款做法）。
    final records = await causeRecords();
    final byQ = <String, List<CauseRecord>>{};
    for (final r in records) {
      (byQ[r.questionId] ??= []).add(r);
    }
    return questions.where((q) {
      if (!q.reviewJoined || !q.isOrganized) return false;
      final rs = byQ[q.id] ?? const <CauseRecord>[];
      return rs.any(
          (r) => r.status != CauseStatus.solved || r.isRecheckDue);
    }).toList();
  }

  /// 首页焦点卡与导航速览同一口径（homeRevCounts）：每科要复习的题数
  /// （手动加入、未解决，含到复查时间的题；数题不数错因）。
  ///
  /// 键按库里的 subjects 表取（B2：新增学科也要有计数键；以前按
  /// `Subject.all` 初始化，新学科的键缺失，首页 `?? 0` 会把有题
  /// 的新学科显示成 0）。口径本身不变，只改键的来源。
  Future<Map<String, int>> homeRevCounts() async {
    final due = await dueToday();
    final subjects = await this.subjects();
    final map = <String, int>{};
    for (final s in subjects) {
      map[s.id] = due.where((q) => q.subjectId == s.id).length;
    }
    return map;
  }

  /// 各科三数：要复习 / 待复查 / 已解决（不显示总题数）。
  /// 一道题可同时计入要复习与待复查（不同错因状态不同）。
  /// 已归档的题不算（与 dueToday / 复习页同口径；取消归档后
  /// 重新计入）。
  ///
  /// 键按库里的 subjects 表取（B2 补充：新增学科也要有计数键；以前按
  /// `Subject.all` 初始化，新学科的键缺失，错题本封面三数会显示 0）。
  /// 口径本身不变，只改键的来源。记录走仓库方法 `causeRecords()`
  ///（与 `_db.allCauseRecords()` 同义），便于单测覆盖。
  Future<Map<String, (int toReview, int toRecheck, int solved)>>
      subjectCounts({bool includeArchived = false}) async {
    final questions = await all(includeArchived: includeArchived);
    final records = await causeRecords();
    final byQ = <String, List<CauseRecord>>{};
    for (final r in records) {
      (byQ[r.questionId] ??= []).add(r);
    }
    final subjects = await this.subjects();
    final map = <String, (int, int, int)>{};
    for (final s in subjects) {
      var toReview = 0;
      var toRecheck = 0;
      var solved = 0;
      for (final q in questions) {
        if (q.subjectId != s.id || !q.reviewJoined || !q.isOrganized) {
          continue;
        }
        final rs = byQ[q.id] ?? const <CauseRecord>[];
        if (rs.isEmpty) continue;
        if (rs.any((r) => r.status != CauseStatus.solved)) toReview++;
        if (rs.any((r) => r.isRecheckDue)) toRecheck++;
        if (rs.every((r) => r.status == CauseStatus.solved) &&
            !rs.any((r) => r.isRecheckDue)) {
          solved++;
        }
      }
      map[s.id] = (toReview, toRecheck, solved);
    }
    return map;
  }

  /// 自查一个错因：result 是 'solved' / 'unsolved' / 'unsure'。
  /// - 已解决：solvedCount + 1；满 cureChecks 次 → 已解决，复查日 =
  ///   今天 + recheckIntervalDays 天；不满 → 解决中（复查日清掉）。
  /// - 未解决：solvedCount 清 0 → 解决中，复查日清掉（复查不过，
  ///   回到解决中重新治，旧复查日作废）。
  /// - 不确定：不算，不改记录。
  /// - 复查（[isRecheck] 为 true，即这条记录已是已解决且到了复查
  ///   时间）：复查通过不加计数（HTML 口径）——solvedCount 已满
  ///   治愈次数，只顺延复查日；否则一次复查通过会把它加到
  ///   cureChecks + 1。复查不过仍按“未解决”走（清 0 打回解决中）。
  /// 报告的复查通过率另外按 review_history 算，不读 solvedCount，
  ///   不受影响。
  Future<CauseRecord> recordSelfCheck(
    CauseRecord r,
    String result, {
    int cureChecks = 2,
    int recheckIntervalDays = 7,
    bool isRecheck = false,
  }) async {
    if (result == 'unsure') return r;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    late CauseRecord updated;
    if (result == 'solved') {
      final count = isRecheck ? r.solvedCount : r.solvedCount + 1;
      if (isRecheck || count >= cureChecks) {
        updated = r.copyWith(
          status: CauseStatus.solved,
          solvedCount: count,
          lastCheck: now,
          recheckDate: today.add(Duration(days: recheckIntervalDays)),
        );
      } else {
        updated = r.copyWith(
          status: CauseStatus.inProgress,
          solvedCount: count,
          lastCheck: now,
          clearRecheckDate: true,
        );
      }
    } else {
      updated = r.copyWith(
        status: CauseStatus.inProgress,
        solvedCount: 0,
        lastCheck: now,
        clearRecheckDate: true,
      );
    }
    // §4.2：三步同事务（改错因记录 → 记自查历史 → 题目自查次数 +1），
    // 中间失败整体回滚，不留半截记录。
    await _db.recordSelfCheckTxn(
        updated: updated, questionId: r.questionId, result: result);
    return updated;
  }

  /// 写补救：内容保存进该错因的补救历史（带日期），下次复习可见。
  /// 空内容不保存。
  Future<CauseRecord> saveRemedy(CauseRecord r, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return r;
    final now = DateTime.now();
    final entry = '${now.year}-${now.month}-${now.day}：$trimmed';
    final updated = r.copyWith(remedyHistory: [entry, ...r.remedyHistory]);
    await _db.upsertCauseRecord(updated);
    return updated;
  }

  Future<ReviewSessionState?> reviewState() => _db.loadReviewState();

  Future<void> saveReviewState(
          {required List<ReviewQueueItem> queue, required int position}) =>
      _db.saveReviewState(queue: queue, position: position);

  Future<void> clearReviewState() => _db.clearReviewState();

  Future<void> toggleFavorite(Question q) async =>
      _db.upsertQuestion(q.copyWith(isFavorite: !q.isFavorite));

  /// 待整理题数（左导航整理角标）：未确认整理且未归档。
  Future<int> pendingOrganizeCount() async {
    final list = await all();
    return list.where((q) => !q.isOrganized && !q.isArchived).length;
  }

  /// 待整理题数（按学科）。键按库里的 subjects 表取（B2：与
  /// [homeRevCounts] 同理，新学科也要有计数键；口径本身不变）。
  Future<Map<String, int>> pendingOrganizeBySubject() async {
    final list = await all();
    final subjects = await this.subjects();
    final map = <String, int>{};
    for (final s in subjects) {
      map[s.id] = list
          .where((q) =>
              q.subjectId == s.id && !q.isOrganized && !q.isArchived)
          .length;
    }
    return map;
  }

  Future<({String kind, String subjectId, String title})?> recentTask() =>
      _db.recentTask();

  Future<void> saveRecentTask(
          {required String kind,
          required String subjectId,
          required String title}) =>
      _db.saveRecentTask(kind: kind, subjectId: subjectId, title: title);

  Future<int> clearDemoData() => _db.clearDemoData();

  Future<int> demoQuestionCount() => _db.demoQuestionCount();

  Future<void> archive(Question q, {bool archived = true}) async =>
      _db.upsertQuestion(q.copyWith(isArchived: archived));

  Future<void> save(Question q) async => _db.upsertQuestion(q);

  Future<void> delete(Question q) async => _db.deleteQuestion(q.id);

  // ---------- 学科 / 文件夹 / 标签 / 试卷 / 知识点 / 设置 ----------

  Future<List<Subject>> subjects() => _db.allSubjects();

  Future<void> saveSubject(Subject s) => _db.upsertSubject(s);

  Future<void> deleteSubject(String id) => _db.deleteSubject(id);

  Future<List<Folder>> folders({String? subjectId}) =>
      _db.allFolders(subjectId: subjectId);

  Future<void> saveFolder(Folder f) => _db.upsertFolder(f);

  Future<int> deleteFolder(Folder f) => _db.deleteFolder(f);

  Future<List<String>> tags() => _db.allTags();

  Future<void> addTag(String name) => _db.insertTag(name);

  Future<void> renameTag(String oldName, String newName) =>
      _db.renameTag(oldName, newName);

  Future<void> deleteTag(String name) => _db.deleteTag(name);

  Future<List<Exam>> exams() => _db.allExams();

  Future<void> addExam(Exam e) => _db.insertExam(e);

  Future<void> renameExam(String id, String newName) =>
      _db.renameExam(id, newName);

  Future<void> deleteExam(String id) => _db.deleteExam(id);

  Future<List<KnowledgePoint>> knowledgePoints() =>
      _db.allKnowledgePoints();

  Future<void> addKnowledgePoint(KnowledgePoint kp) =>
      _db.insertKnowledgePoint(kp);

  Future<void> renameKnowledgePoint(String id, String newName) =>
      _db.renameKnowledgePoint(id, newName);

  Future<void> deleteKnowledgePoint(String id) =>
      _db.deleteKnowledgePoint(id);

  /// 章节改名 / 删除章节（R10 学科管理知识点树：章节行也有改名/删除，
  /// 与 HTML `viewSubjects` 一致）。章节只随知识点存在，加章节须同时
  /// 给第一个知识点——空章节没有可存的行（不改 Schema）。
  Future<void> renameChapter(
          String subjectId, String oldChapter, String newChapter) =>
      _db.renameChapter(subjectId, oldChapter, newChapter);

  Future<void> deleteChapter(String subjectId, String chapter) =>
      _db.deleteChapter(subjectId, chapter);

  Future<AppSettings> settings() => _db.loadSettings();

  Future<void> saveSettings(AppSettings s) => _db.saveSettings(s);

  /// B3：上次停留的路由（复用 settings 表 key `lastRoute`，见 database.dart）。
  Future<String?> lastRoute() => _db.loadLastRoute();

  Future<void> saveLastRoute(String route) => _db.saveLastRoute(route);

  Future<List<CollectTask>> collectTasks() => _db.allCollectTasks();

  Future<void> saveCollectTask(CollectTask t) => _db.upsertCollectTask(t);

  Future<void> deleteCollectTask(String id) => _db.deleteCollectTask(id);

  // ---------- 框（question_boxes，§1.5；P2） ----------

  /// 读某任务的全部草稿框（“继续修框”恢复用）。
  Future<List<QuestionBox>> boxesForTask(String taskId) =>
      _db.boxesForTask(taskId);

  /// 读同一页图上全部已确认题的框（重框同页上下文）。
  Future<List<QuestionBox>> boxesForPageImage(String pageImagePath) =>
      _db.boxesForPageImage(pageImagePath);

  /// 草稿保存：修框关闭 / 取消 / 切页时批量保存（拖拽只改内存）。
  Future<void> saveDraftBoxes({
    required String taskId,
    required Map<int, List<QuestionBox>> boxesByPage,
    required Map<String, List<QuestionBox>> inners,
    required Map<int, List<QuestionBox>> standaloneInner,
    required Map<int, int> rotations,
  }) =>
      _db.saveDraftBoxes(
        taskId: taskId,
        boxesByPage: boxesByPage,
        inners: inners,
        standaloneInner: standaloneInner,
        rotations: rotations,
      );

  /// 详情页重框：只替换这一题的框（同页其他题不动）。
  Future<void> replaceQuestionBoxes(
          String questionId, List<QuestionBox> boxes) =>
      _db.replaceQuestionBoxes(questionId, boxes);

  /// 确认拆题四步同事务（切片须由调用方先写盘）。
  Future<void> confirmSplit({
    required CollectTask originalTask,
    required List<Question> questions,
    required List<CollectTask> splitTasks,
    required Map<String, List<QuestionBox>> boxesByQuestionId,
  }) =>
      _db.confirmSplit(
        originalTask: originalTask,
        questions: questions,
        splitTasks: splitTasks,
        boxesByQuestionId: boxesByQuestionId,
      );

  Future<String> exportBackupJson() => _db.exportBackupJson();

  /// B4.2：恢复备份（整体覆盖，见 database.dart）。
  Future<void> importBackupJson(Map<String, dynamic> data) =>
      _db.importBackupJson(data);

  /// §2.3/P3：zip 文件级备份（JSON + imports/ + slices/）。
  Future<List<int>> exportBackupZip() => _db.exportBackupZip();

  /// §2.3/P3：zip 备份恢复（JSON + 文件一起恢复）。
  Future<void> importBackupZip(List<int> bytes) =>
      _db.importBackupZip(bytes);

  /// §2.3/P3：zip 备份恢复（按文件路径读）。
  Future<void> importBackupZipFile(String path) =>
      _db.importBackupZipFile(path);

  /// §4.5/P3：孤儿扫描（imports/ + slices/ 里无引用的文件）。
  Future<OrphanScan> scanOrphanFiles() => _db.scanOrphans();

  /// §4.5/P3：孤儿清理（只删传入的无引用文件）。
  Future<({int deletedCount, int freedBytes})> deleteOrphanFiles(
          List<String> relativePaths) =>
      _db.cleanOrphans(relativePaths);

  /// §4.5/P3：空间占用分项（设置页“空间占用”显示用）。
  Future<({int importsBytes, int slicesBytes})> storageUsageBreakdown() =>
      ImportService.storageUsageBreakdown();

  /// B4.1：到了复查时间的错因数（已解决且复查日 ≤ 今天，数错因
  /// 不数题）。口径与 dueToday 一致：只算已加入复习、已整理的题，
  /// 已归档的题不算（取消归档后重新计入）。
  Future<int> recheckDueCauseCount({bool includeArchived = false}) async {
    final questions = await all(includeArchived: includeArchived);
    final joined = {
      for (final q in questions)
        if (q.reviewJoined && q.isOrganized) q.id
    };
    final records = await causeRecords();
    return records
        .where((r) => joined.contains(r.questionId) && r.isRecheckDue)
        .length;
  }

  /// B4.1：今天是否已弹过复查提醒（settings 表 key，见 database.dart）。
  Future<String?> lastRecheckReminderDate() =>
      _db.loadLastRecheckReminderDate();

  Future<void> saveLastRecheckReminderDate(String date) =>
      _db.saveLastRecheckReminderDate(date);

  /// 待定3：首页备份失败横幅的标志（settings 表 key，见 database.dart）。
  Future<bool> backupFailed() => _db.loadBackupFailed();

  Future<void> setBackupFailed(bool failed) =>
      _db.saveBackupFailed(failed);

  /// B4.3：切换数据库位置并迁移旧库与文件目录（见 database.dart）。
  /// 目标已有库时先问用户，`overwrite` 按用户选择传（覆盖 / 保留 /
  /// 取消；文件目录沿用同一选择）。`onProgress` / `isCancelled`
  /// 见 [AppDatabase.migrateDataFiles]（大目录复制进度 / 取消）。
  Future<DbMigrationOutcome> migrateToDirectory(String dir,
          {bool overwrite = false,
          void Function(double progress)? onProgress,
          bool Function()? isCancelled}) =>
      _db.migrateToDirectory(dir,
          overwrite: overwrite,
          onProgress: onProgress,
          isCancelled: isCancelled);

  Future<void> setCustomDataDirectory(String dir) =>
      _db.setCustomDataDirectory(dir);
}
