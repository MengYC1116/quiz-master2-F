// B4：database.dart 拆分——题目 / 错因记录 / 复习状态与队列 / 删题事务。
// 与 database.dart 同一库（part of），共享库私有成员；纯重构，行为不变。
// ARCH-PLAN-B 第 2 阶段（W-questions）：cause_records、review_history、
// review_state、questions 四张表全部走 Drift 类型化查询（db.select /
// db.into / db.update / db.delete + Companion），不再有这四张表的
// customSelect / customInsert / customUpdate SQL 字符串；行映射走本文件
// 底部的 _questionFromDb / _causeRecordFromDb（DbXxx 行类 → 模型类）与
// _questionCompanion / _causeRecordCompanion（模型类 → Companion）。

part of 'database.dart';

/// §8.1：读全部题（可单测版）：直接对传入的库句柄读，不碰单例。
Future<List<Question>> allQuestionsFromImpl(QuizDatabase db) async {
  final rows =
      await (db.select(db.questions)..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
          .get();
  return rows.map(_questionFromDb).toList();
}

/// SR-P2-8：手动加入 / 取消加入复习（可单测版）：题行 + 错因记录
/// 同一个事务。旧写法是仓库里两步：先 upsertQuestion、再
/// ensureCauseRecords（逐条 insert）；中间抛错/被杀，题已标
/// “已加入复习”却没有一条 cause_records，dueToday / subjectCounts
/// 对无记录的题静默跳过——题从复习计数里消失，用户以为已加入、
/// 实际永远排不到。`joined && causes.isEmpty` 时不写库、返回 false
/// （错因是空的题加不进复习，与旧仓库口径一致）。
/// 播种用 [_seedCauseRecordsTyped]（insertOrIgnore，已有记录不动；
/// 再加入时接着治）。
/// SR2-14：题行只按列 UPDATE `review_joined`，不用整行 REPLACE——
/// 旧写法整行写回会把内存旧快照里的 `review_count`（如 5）写回库里，
/// 覆盖自查刚用 SQL `+1` 加出来的 6。`review_count` 只应由 SQL `+1` 改，
/// 任何整行写都不应带它（见 [upsertQuestionIntoImpl]）。题行不存在时才整行
/// INSERT（新题入库，快照值即初始值，无可覆盖的库内值）。
Future<bool> setReviewJoinedIntoImpl(
  QuizDatabase db,
  Question q,
  bool joined,
) async {
  final causes = q.allCauses;
  if (joined && causes.isEmpty) return false;
  await db.transaction(() async {
    final updated =
        await (db.update(db.questions)..where((t) => t.id.equals(q.id))).write(
          QuestionsCompanion(reviewJoined: Value(joined ? 1 : 0)),
        );
    if (updated == 0) {
      await db
          .into(db.questions)
          .insert(
            _questionCompanion(q.copyWith(reviewJoined: joined)),
            mode: InsertMode.insertOrReplace,
          );
    }
    if (joined) {
      await _seedCauseRecordsTyped(db, q, joinedAt: DateTime.now());
    }
  });
  return true;
}

/// SR-P2-8：同步某题的解决记录与它当前的错因（可单测版）：删掉
/// 已不在错因里的记录 + 给新加的错因补一条待解决记录，同事务。
/// 旧写法是仓库里三段分离（全表读 + 逐条删 + ensureCauseRecords），
/// 中间失败会留下“旧错因记录已删、新错因记录未补”的半截状态。
/// 仅已加入复习的题同步；未加入的直接返回（与旧仓库口径一致）。
Future<void> syncCauseRecordsIntoImpl(QuizDatabase db, Question q) async {
  if (!q.reviewJoined) return;
  final causes = q.allCauses.toSet();
  await db.transaction(() async {
    final rows = await (db.select(
      db.causeRecords,
    )..where((t) => t.questionId.equals(q.id))).get();
    for (final row in rows) {
      if (!causes.contains(row.cause)) {
        await (db.delete(db.causeRecords)..where(
              (t) => t.questionId.equals(q.id) & t.cause.equals(row.cause),
            ))
            .go();
      }
    }
    await _seedCauseRecordsTyped(db, q, joinedAt: DateTime.now());
  });
}

/// §4.2：自查事务（可单测版）：直接对传入的库句柄做，不碰单例、不 bump。
/// SR-P2-16：新值按库内当前行重算，不按传入的快照——[updated] 只
/// 提供“这次自查的方向”（result）与无行可读时的回退值。两处自查若
/// 基于同一份旧 CauseRecord 先后提交，旧写法里后提交的会覆盖
/// 先提交的计数（如两次快速点“已解决”，solvedCount 都按旧值 +1，
/// 本应 +2 只 +1）。新写法在事务内先读库内当前行：有行时
/// solvedCount 在当前值上递增、状态/复查日按当前值重算，
/// remedyHistory / joinedAt 也以库内值为准（不拿旧快照覆盖）；
/// 无行时（记录还没入库）才按传入的 [updated] 写。
/// 返回实际写库的记录（调用方用它刷新界面，不再用快照推导值）。
/// `review_count` 的 +1 用 Companion.custom 的列自增表达式（与旧
/// `SET review_count = review_count + 1` 同语义），不在 Dart 侧读改写。
Future<CauseRecord> recordSelfCheckIntoImpl(
  QuizDatabase db, {
  required CauseRecord updated,
  required String questionId,
  required String result,
  int cureChecks = 2,
  int recheckIntervalDays = 7,
  bool isRecheck = false,
}) async {
  late CauseRecord written;
  await db.transaction(() async {
    Future<DbCauseRecord?> readCurrent() =>
        (db.select(db.causeRecords)..where(
              (t) =>
                  t.questionId.equals(updated.questionId) &
                  t.cause.equals(updated.cause),
            ))
            .getSingleOrNull();
    if (result == 'unsure') {
      // “不确定”不算，不写库：返回库内现有行（有）或传入值（无）。
      final row = await readCurrent();
      written = row == null ? updated : _causeRecordFromDb(row);
      return;
    }
    final row = await readCurrent();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (row == null) {
      written = updated;
    } else {
      final current = _causeRecordFromDb(row);
      if (result == 'solved') {
        final count = isRecheck ? current.solvedCount : current.solvedCount + 1;
        if (isRecheck || count >= cureChecks) {
          written = current.copyWith(
            status: CauseStatus.solved,
            solvedCount: count,
            lastCheck: now,
            recheckDate: today.add(Duration(days: recheckIntervalDays)),
          );
        } else {
          written = current.copyWith(
            status: CauseStatus.inProgress,
            solvedCount: count,
            lastCheck: now,
            clearRecheckDate: true,
          );
        }
      } else {
        // 未解决：solvedCount 清 0 → 解决中，复查日清掉
        // （复查不过，回到解决中重新治，旧复查日作废）。
        written = current.copyWith(
          status: CauseStatus.inProgress,
          solvedCount: 0,
          lastCheck: now,
          clearRecheckDate: true,
        );
      }
    }
    await db
        .into(db.causeRecords)
        .insert(
          _causeRecordCompanion(written),
          mode: InsertMode.insertOrReplace,
        );
    await db
        .into(db.reviewHistory)
        .insert(
          ReviewHistoryCompanion.insert(
            questionId: questionId,
            result: result,
            reviewedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
    await (db.update(
      db.questions,
    )..where((t) => t.id.equals(questionId))).write(
      QuestionsCompanion.custom(
        reviewCount: db.questions.reviewCount + const Constant(1),
      ),
    );
  });
  return written;
}

/// §8.1：写题（可单测版）：直接对传入的库句柄写，不碰单例、不 bump。
/// SR2-14：UPDATE-first，且 UPDATE 的列里不含 `review_count`——
/// 它只应由 [recordSelfCheckIntoImpl] 里的 SQL `+1` 改。旧写法是
/// 整行 REPLACE：拿着旧快照（`reviewCount: 5`）的
/// toggleFavorite / archive / save 会把自查刚加到 6 的库内值打回 5。
/// 已存在的行只 UPDATE 其它列（标题、文件夹、标签、收藏/归档等编辑
/// 内容照常写回）；不存在时才整行 INSERT（快照值即新题初始值）。
Future<void> upsertQuestionIntoImpl(QuizDatabase db, Question q) async {
  // B11-10 今日小结计数：先读旧行，判断是不是未整理→已整理的跃迁
  // （读在写之前；写成功后才 +1，写失败不计）。只在旧行存在且未整理
  // 时才计：新行直接以已整理入库（种子/恢复路径）不是一次整理动作，
  // 不计；已整理题的重复保存也不计（旧行已是已整理）。
  var countOrganizedToday = false;
  if (q.isOrganized) {
    final old = await (db.select(
      db.questions,
    )..where((t) => t.id.equals(q.id))).getSingleOrNull();
    countOrganizedToday = old != null && old.isOrganized != 1;
  }
  final updated =
      await (db.update(db.questions)..where((t) => t.id.equals(q.id))).write(
        // UPDATE 的列里不含 review_count（见函数头注释）与 id（WHERE 已定）。
        _questionCompanion(q, includeId: false, includeReviewCount: false),
      );
  if (updated == 0) {
    await db
        .into(db.questions)
        .insert(_questionCompanion(q), mode: InsertMode.insertOrReplace);
  }
  // B9-1：题变为已整理时，同句柄把指向它的收集任务置 done。
  // 这是全部整理路径的汇合点（整理确认、批量整理都走 repo.save →
  // _db.upsertQuestion → 这里；详情/错题本的保存也一样，只是不翻
  // isOrganized）；集中处理一次，任何调用点都不会漏。只改仍是
  // pendingOrganize 的行：已是 done 或其它状态的行不动；题未整理
  // 时不碰任务。条件里不读旧行——已整理题的任何一次保存都会把卡
  // 住的任务顺手治好（自愈），且 UPDATE 本身是幂等的。
  // 与题写同一句柄，不另开事务：调用方若传进来的是 Transaction，
  // 任务改动与题改动同事务；传普通 Database 时与旧写法同口径
  // （本题写本身也不是事务）。
  // 注（B2-W-questions）：这条是 collect_tasks 表的操作，语句本身在
  // 本文件内，顺手改为类型化；collect_tasks 表的其余迁移归 W-collect。
  if (q.isOrganized) {
    await (db.update(db.collectTasks)..where(
          (t) =>
              t.questionId.equals(q.id) &
              t.status.equals(CollectStatus.pendingOrganize.name),
        ))
        .write(CollectTasksCompanion(status: Value(CollectStatus.done.name)));
  }
  // B11-10：跃迁才 +1（见函数开头；settings 键 organizedToday）。
  if (countOrganizedToday) {
    await bumpOrganizedTodayIntoImpl(db);
  }
}

/// §4.5：删题（可单测版）：一次事务，不 bump。事务提交后删该题
/// 独占的切片文件（页图不删，同页多题共享；文件删失败不回滚，
/// 由孤儿清理兜底）。
Future<void> deleteQuestionFromImpl(QuizDatabase db, String id) async {
  final slice = await _slicePathOf(db, id);
  await db.transaction(() => _deleteQuestionTxn(db, id));
  await _deleteDataFileIfUnreferenced(db, slice);
}

Future<String?> _slicePathOf(QuizDatabase db, String id) async {
  final row = await (db.select(
    db.questions,
  )..where((t) => t.id.equals(id))).getSingleOrNull();
  if (row == null) return null;
  return row.slicePath;
}

/// FR-37：批量删题（错题本批量删除，Meng 裁决口径 (b) 数据层加批量
/// 删题事务）：整批一个事务——先收各题切片路径，再一次事务内逐题走
/// `_deleteQuestionTxn`，提交后逐个删独占切片。中途任一题失败，
/// 整批回滚，不出现删一半的状态；切片文件只在事务提交后删
/// （与单题 [deleteQuestionFromImpl] 同顺序）。
Future<void> deleteQuestionsBatchFromImpl(
  QuizDatabase db,
  List<String> ids,
) async {
  final slices = <String?>[];
  for (final id in ids) {
    slices.add(await _slicePathOf(db, id));
  }
  await db.transaction(() async {
    for (final id in ids) {
      await _deleteQuestionTxn(db, id);
    }
  });
  for (final slice in slices) {
    await _deleteDataFileIfUnreferenced(db, slice);
  }
}

/// §4.5/§3.4：从复习队列里去掉该题的项（队列是 ReviewQueueItem
/// 对象数组，按 questionId 匹配，不再拼字符串比对）。
Future<void> _removeFromReviewQueueTxn(
  QuizDatabase db,
  String questionId,
) async {
  final row = await (db.select(
    db.reviewState,
  )..where((t) => t.id.equals(1))).getSingleOrNull();
  if (row == null) return;
  final queue = row.queue;
  final kept = queue.where((e) => e.questionId != questionId).toList();
  if (kept.length == queue.length) return;
  await (db.update(db.reviewState)..where((t) => t.id.equals(1))).write(
    ReviewStateCompanion(queue: Value(kept)),
  );
}

/// §4.2/§4.5：删题的全部写操作（事务内，不 bump、不开新事务）：
/// 解决记录 → 自查历史 → 收集任务的指向置空（任务本身保留）→
/// 复习队列里的项 → §1.2(c) 该题的框（含第 1 层框及其子框，
/// parent_box_id 指向该题整题框的行）→ 题目行。
/// 注意：页图不删（同页多题共享）；切片文件在事务提交后由调用方
/// 处理（P2 落盘后，见 §4.5）。顺序约束（plan 协议）：先删数据库行，
/// 再删切片文件——顺序不变，文件删除在 [deleteQuestionFromImpl] 里
/// 事务提交后才做。
Future<void> _deleteQuestionTxn(QuizDatabase db, String id) async {
  await (db.delete(
    db.causeRecords,
  )..where((t) => t.questionId.equals(id))).go();
  await (db.delete(
    db.reviewHistory,
  )..where((t) => t.questionId.equals(id))).go();
  await (db.update(db.collectTasks)..where((t) => t.questionId.equals(id)))
      .write(const CollectTasksCompanion(questionId: Value(null)));
  await _removeFromReviewQueueTxn(db, id);
  // 先删子框（parent_box_id 指向该题整题框的行），再删该题的框。
  final ownBoxes = await (db.select(
    db.questionBoxes,
  )..where((t) => t.questionId.equals(id))).get();
  for (final box in ownBoxes) {
    await (db.delete(
      db.questionBoxes,
    )..where((t) => t.parentBoxId.equals(box.id))).go();
  }
  await (db.delete(
    db.questionBoxes,
  )..where((t) => t.questionId.equals(id))).go();
  await (db.delete(db.questions)..where((t) => t.id.equals(id))).go();
}

extension AppDatabaseQuestions on AppDatabase {
  Future<List<Question>> allQuestions() async =>
      AppDatabase.allQuestionsFrom(await db);

  Future<Question?> questionById(String id) async {
    final d = await db;
    final row = await (d.select(
      d.questions,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return null;
    return _questionFromDb(row);
  }

  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
    String questionId,
  ) async {
    final d = await db;
    final rows =
        await (d.select(d.reviewHistory)
              ..where((t) => t.questionId.equals(questionId))
              ..orderBy([
                (t) => OrderingTerm(
                  expression: t.reviewedAt,
                  mode: OrderingMode.desc,
                ),
              ]))
            .get();
    return rows
        .map(
          (r) => (
            result: r.result,
            reviewedAt: DateTime.fromMillisecondsSinceEpoch(r.reviewedAt),
          ),
        )
        .toList();
  }

  Future<List<CauseRecord>> allCauseRecords() async {
    final d = await db;
    final rows =
        await (d.select(d.causeRecords)..orderBy([
              (t) => OrderingTerm(expression: t.joinedAt),
              (t) => OrderingTerm(expression: t.id),
            ]))
            .get();
    return rows.map(_causeRecordFromDb).toList();
  }

  Future<List<CauseRecord>> causeRecordsForQuestion(String questionId) async {
    final d = await db;
    final rows =
        await (d.select(d.causeRecords)
              ..where((t) => t.questionId.equals(questionId))
              ..orderBy([(t) => OrderingTerm(expression: t.id)]))
            .get();
    return rows.map(_causeRecordFromDb).toList();
  }

  Future<void> ensureCauseRecords(Question q) async {
    final d = await db;
    await _seedCauseRecordsTyped(d, q, joinedAt: DateTime.now());
  }

  /// SR3-4：方法名即语义——只改 `remedy_history` 列，不整行
  /// REPLACE。唯一生产调用方是 `repository.saveRemedy`（只改补救
  /// 历史）；状态 / 计数 / 复查日 / 上次自查的唯一写路径是
  /// [recordSelfCheckIntoImpl]（事务内先读库内行再重算），
  /// `saveCauseRecord` 只是本方法的仓库层转发（测试播种走 INSERT
  /// 路径时用）。旧名 `upsertCauseRecord` 暗示全量 upsert，但行
  /// 已存在时 `status` / `solvedCount` / `recheckDate` /
  /// `lastCheck` 的改动会被静默丢弃——改名让窄化显性化：经本方法
  /// 改状态是“按设计丢弃”，不是“写入失败”。行不存在时才整行
  /// INSERT（新记录无可覆盖的库内值，全列写无 SR2-14 同类风险）。
  Future<void> updateCauseRemedy(CauseRecord r) async {
    final d = await db;
    final updated =
        await (d.update(d.causeRecords)..where(
              (t) =>
                  t.questionId.equals(r.questionId) & t.cause.equals(r.cause),
            ))
            .write(
              CauseRecordsCompanion(remedyHistory: Value(r.remedyHistory)),
            );
    if (updated == 0) {
      await d
          .into(d.causeRecords)
          .insert(_causeRecordCompanion(r), mode: InsertMode.insertOrReplace);
    }
    // Stage 4：补救历史是复习记录；行不存在时整行 INSERT 可能新建一条
    // 待解决记录，会影响角标——沿用旧 bump 口径，两种 kind 都发。
    DataChangeBus.instance.emit(
      DataChangeEvent(
        kinds: const {DataChangeKind.badges, DataChangeKind.reviewRecords},
        questionId: r.questionId,
      ),
    );
  }

  /// SR-P2-8：手动加入 / 取消加入复习（实例版）：题行 + 错因记录
  /// 同事务（见 [AppDatabase.setReviewJoinedInto]），提交成功后
  /// 才 bump 一次。错因是空的题加不进复习，返回 false。
  Future<bool> setReviewJoined(Question q, bool joined) async {
    final d = await db;
    final ok = await AppDatabase.setReviewJoinedInto(d, q, joined);
    if (ok) {
      DataChangeBus.instance.emit(
        DataChangeEvent(
          kinds: const {DataChangeKind.badges, DataChangeKind.reviewRecords},
          questionId: q.id,
        ),
      );
    }
    return ok;
  }

  /// SR-P2-8：同步某题的解决记录与它当前的错因（实例版）：删旧
  /// + 补新同事务（见 [AppDatabase.syncCauseRecordsInto]）。
  Future<void> syncCauseRecords(Question q) async {
    final d = await db;
    await AppDatabase.syncCauseRecordsInto(d, q);
  }

  /// §4.2：自查三步同事务：改错因记录 → 记自查历史 → 题目自查次数 +1。
  /// 中间失败整体回滚，不留“状态已变、历史没记、次数没加”的半截记录。
  /// 角标在提交成功后才 bump 一次（事务内不调 UI 通知）。
  /// SR-P2-16：新值在事务内按库内当前行重算（见
  /// [AppDatabase.recordSelfCheckInto]），返回实际写库的记录。
  Future<CauseRecord> recordSelfCheckTxn({
    required CauseRecord updated,
    required String questionId,
    required String result,
    int cureChecks = 2,
    int recheckIntervalDays = 7,
    bool isRecheck = false,
  }) async {
    final d = await db;
    final written = await AppDatabase.recordSelfCheckInto(
      d,
      updated: updated,
      questionId: questionId,
      result: result,
      cureChecks: cureChecks,
      recheckIntervalDays: recheckIntervalDays,
      isRecheck: isRecheck,
    );
    // “不确定”不写库，也不发事件。
    if (result != 'unsure') {
      DataChangeBus.instance.emit(
        DataChangeEvent(
          kinds: const {DataChangeKind.badges, DataChangeKind.reviewRecords},
          questionId: questionId,
        ),
      );
    }
    return written;
  }

  Future<void> saveReviewState({
    required List<ReviewQueueItem> queue,
    required int position,
  }) async {
    final d = await db;
    await d
        .into(d.reviewState)
        .insert(
          ReviewStateCompanion.insert(
            id: const Value(1),
            queue: Value(queue),
            position: Value(position),
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
          mode: InsertMode.insertOrReplace,
        );
  }

  Future<ReviewSessionState?> loadReviewState() async {
    final d = await db;
    final row = await (d.select(
      d.reviewState,
    )..where((t) => t.id.equals(1))).getSingleOrNull();
    if (row == null) return null;
    final queue = row.queue;
    if (queue.isEmpty) return null;
    return ReviewSessionState(
      queue: queue,
      position: row.position,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt),
    );
  }

  Future<void> clearReviewState() async {
    final d = await db;
    await (d.delete(d.reviewState)..where((t) => t.id.equals(1))).go();
  }

  Future<void> upsertQuestion(Question q) async {
    final d = await db;
    await AppDatabase.upsertQuestionInto(d, q);
    DataChangeBus.instance.emit(
      DataChangeEvent(
        kinds: const {DataChangeKind.badges, DataChangeKind.questions},
        questionId: q.id,
      ),
    );
  }

  Future<void> deleteQuestion(String id) async {
    final d = await db;
    await AppDatabase.deleteQuestionFrom(d, id);
    // 删题同事务删掉该题的解决记录与自查历史（见 _deleteQuestionTxn），
    // 角标与题目列表之外，复习记录也变了。
    DataChangeBus.instance.emit(
      DataChangeEvent(
        kinds: const {
          DataChangeKind.badges,
          DataChangeKind.questions,
          DataChangeKind.reviewRecords,
        },
        questionId: id,
      ),
    );
  }

  /// FR-37：批量删题（整批一个事务，见 [deleteQuestionsBatchFromImpl]）。
  /// 成功后只发一个事件（多题，questionId 为空）；空批直接返回，不发事件。
  Future<void> deleteQuestionsBatch(List<String> ids) async {
    if (ids.isEmpty) return;
    final d = await db;
    await AppDatabase.deleteQuestionsBatchFrom(d, ids);
    DataChangeBus.instance.emit(
      const DataChangeEvent(
        kinds: {
          DataChangeKind.badges,
          DataChangeKind.questions,
          DataChangeKind.reviewRecords,
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Drift 行映射（本文件私有）：DbXxx 行类 ↔ 模型类。
// 行映射口径：bool ↔ 0/1、DateTime ↔ 毫秒、枚举存 name、
// 多值字段经 StringListConverter 走 JSON 文本、queue 经 QueueConverter
// 走对象数组；读写走类型化列，不再拼 SQL 字符串。
// ---------------------------------------------------------------------------

Question _questionFromDb(DbQuestion r) => Question(
  id: r.id,
  title: r.title,
  subjectId: r.subjectId,
  folderIds: r.folderIds,
  examId: r.examId,
  knowledgePointIds: r.knowledgeIds,
  errorTypes: r.errorTypes,
  customErrorTypes: r.customErrorTypes,
  tags: r.tags,
  answer: r.answer,
  explanation: r.explanation,
  notes: r.notes,
  reviewCount: r.reviewCount,
  isOrganized: r.isOrganized == 1,
  isDemo: r.isDemo == 1,
  isFavorite: r.isFavorite == 1,
  isArchived: r.isArchived == 1,
  reviewJoined: r.reviewJoined == 1,
  createdAt: DateTime.fromMillisecondsSinceEpoch(r.createdAt),
  sliceKind: r.sliceKind,
  sliceText: r.sliceText,
  sourcePath: r.sourcePath,
  sourceKind: r.sourceKind,
  sourcePage: r.sourcePage,
  pageImagePath: r.pageImagePath,
  slicePath: r.slicePath,
  sliceWidth: r.sliceWidth,
  sliceHeight: r.sliceHeight,
);

QuestionsCompanion _questionCompanion(
  Question q, {
  bool includeId = true,
  bool includeReviewCount = true,
}) => QuestionsCompanion(
  id: includeId ? Value(q.id) : const Value.absent(),
  title: Value(q.title),
  subjectId: Value(q.subjectId),
  folderIds: Value(q.folderIds),
  examId: Value(q.examId),
  knowledgeIds: Value(q.knowledgePointIds),
  errorTypes: Value(q.errorTypes),
  customErrorTypes: Value(q.customErrorTypes),
  tags: Value(q.tags),
  answer: Value(q.answer),
  explanation: Value(q.explanation),
  notes: Value(q.notes),
  reviewCount: includeReviewCount ? Value(q.reviewCount) : const Value.absent(),
  isOrganized: Value(q.isOrganized ? 1 : 0),
  isDemo: Value(q.isDemo ? 1 : 0),
  isFavorite: Value(q.isFavorite ? 1 : 0),
  isArchived: Value(q.isArchived ? 1 : 0),
  reviewJoined: Value(q.reviewJoined ? 1 : 0),
  createdAt: Value(q.createdAt.millisecondsSinceEpoch),
  sliceKind: Value(q.sliceKind),
  sliceText: Value(q.sliceText),
  sourcePath: Value(q.sourcePath),
  sourceKind: Value(q.sourceKind),
  sourcePage: Value(q.sourcePage),
  pageImagePath: Value(q.pageImagePath),
  slicePath: Value(q.slicePath),
  sliceWidth: Value(q.sliceWidth),
  sliceHeight: Value(q.sliceHeight),
);

CauseRecord _causeRecordFromDb(DbCauseRecord r) => CauseRecord(
  questionId: r.questionId,
  cause: r.cause,
  subjectId: r.subjectId,
  status: switch (r.status) {
    'inProgress' => CauseStatus.inProgress,
    'solved' => CauseStatus.solved,
    _ => CauseStatus.pending,
  },
  solvedCount: r.solvedCount,
  lastCheck: r.lastCheck == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(r.lastCheck!),
  recheckDate: r.recheckDate == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(r.recheckDate!),
  remedyHistory: r.remedyHistory,
  joinedAt: DateTime.fromMillisecondsSinceEpoch(r.joinedAt),
);

CauseRecordsCompanion _causeRecordCompanion(CauseRecord r) =>
    CauseRecordsCompanion(
      questionId: Value(r.questionId),
      cause: Value(r.cause),
      subjectId: Value(r.subjectId),
      status: Value(r.status.name),
      solvedCount: Value(r.solvedCount),
      lastCheck: Value(r.lastCheck?.millisecondsSinceEpoch),
      recheckDate: Value(r.recheckDate?.millisecondsSinceEpoch),
      remedyHistory: Value(r.remedyHistory),
      joinedAt: Value(r.joinedAt.millisecondsSinceEpoch),
    );

/// 错因记录播种（类型化版）：每个错因一条待解决记录（已存在的不动），
/// 语义等价于 INSERT OR IGNORE。
Future<void> _seedCauseRecordsTyped(
  QuizDatabase db,
  Question q, {
  required DateTime joinedAt,
  int solvedCount = 0,
}) async {
  for (final cause in q.allCauses) {
    await db
        .into(db.causeRecords)
        .insert(
          CauseRecordsCompanion.insert(
            questionId: q.id,
            cause: cause,
            subjectId: q.subjectId,
            solvedCount: Value(solvedCount),
            // remedy_history 必须显式写 '[]'：列默认值是 ''，旧代码显式写
            // '[]'；缺省会让存储表示从 '[]' 漂成 ''（p2_json_fields 回归）。
            remedyHistory: const Value([]),
            joinedAt: joinedAt.millisecondsSinceEpoch,
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }
}
