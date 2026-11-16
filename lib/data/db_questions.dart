// B4：database.dart 拆分——题目 / 错因记录 / 复习状态与队列 / 删题事务。
// 与 database.dart 同一库（part of），共享库私有成员；纯重构，行为不变。

part of 'database.dart';

/// §8.1：读全部题（可单测版）：直接对传入的库句柄读，不碰单例。
Future<List<Question>> allQuestionsFromImpl(QuizDatabase db) async {
  final rows = _rows(
    await db
        .customSelect('SELECT * FROM questions ORDER BY created_at DESC')
        .get(),
  );
  return rows.map(_fromRow).toList();
}

/// SR-P2-8：手动加入 / 取消加入复习（可单测版）：题行 + 错因记录
/// 同一个事务。旧写法是仓库里两步：先 upsertQuestion、再
/// ensureCauseRecords（逐条 insert）；中间抛错/被杀，题已标
/// “已加入复习”却没有一条 cause_records，dueToday / subjectCounts
/// 对无记录的题静默跳过——题从复习计数里消失，用户以为已加入、
/// 实际永远排不到。`joined && causes.isEmpty` 时不写库、返回 false
/// （错因是空的题加不进复习，与旧仓库口径一致）。
/// 播种用 [_seedCauseRecordsFor]（ConflictAlgorithm.ignore，
/// 已有记录不动；再加入时接着治）。
/// SR2-14：题行只按列 UPDATE `review_joined`，不用整行 REPLACE——
/// 旧写法 `_toRow(q.copyWith(reviewJoined: joined))` 会把内存旧快照
/// 里的 `review_count`（如 5）写回库里，覆盖自查刚用 SQL `+1` 加
/// 出来的 6。`review_count` 只应由 SQL `+1` 改，任何整行写都不应
/// 带它（见 [upsertQuestionIntoImpl]）。题行不存在时才整行 INSERT
/// （新题入库，快照值即初始值，无可覆盖的库内值）。
Future<bool> setReviewJoinedIntoImpl(
  QuizDatabase db,
  Question q,
  bool joined,
) async {
  final causes = q.allCauses;
  if (joined && causes.isEmpty) return false;
  await db.transaction(() async {
    final updated = await db.customUpdate(
      'UPDATE questions SET review_joined = ? WHERE id = ?',
      variables: [
        Variable.withInt(joined ? 1 : 0),
        Variable.withString(q.id),
      ],
    );
    if (updated == 0) {
      await db.customInsert(
        'INSERT OR REPLACE INTO questions '
        '(id, title, subject_id, folder_ids, exam_id, knowledge_ids, '
        'error_types, custom_error_types, tags, answer, explanation, notes, '
        'review_count, is_organized, is_demo, is_favorite, is_archived, '
        'review_joined, created_at, slice_kind, slice_text, source_path, '
        'source_kind, source_page, page_image_path, slice_path, slice_width, '
        'slice_height) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '
        '?, ?, ?, ?, ?, ?, ?, ?)',
        variables: _variables(_toRow(q.copyWith(reviewJoined: joined))),
      );
    }
    if (joined) {
      await _seedCauseRecordsFor(db, q, joinedAt: DateTime.now());
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
    final rows = _rows(
      await db
          .customSelect(
            'SELECT cause FROM cause_records WHERE question_id = ?',
            variables: [Variable.withString(q.id)],
          )
          .get(),
    );
    for (final row in rows) {
      final cause = row['cause'] as String;
      if (!causes.contains(cause)) {
        await db.customUpdate(
          'DELETE FROM cause_records WHERE question_id = ? AND cause = ?',
          variables: [
            Variable.withString(q.id),
            Variable.withString(cause),
          ],
        );
      }
    }
    await _seedCauseRecordsFor(db, q, joinedAt: DateTime.now());
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
    if (result == 'unsure') {
      // “不确定”不算，不写库：返回库内现有行（有）或传入值（无）。
      final rows = _rows(
        await db
            .customSelect(
              'SELECT * FROM cause_records WHERE question_id = ? AND cause = ? LIMIT 1',
              variables: [
                Variable.withString(updated.questionId),
                Variable.withString(updated.cause),
              ],
            )
            .get(),
      );
      written = rows.isEmpty ? updated : _causeFromRow(rows.first);
      return;
    }
    final rows = _rows(
      await db
          .customSelect(
            'SELECT * FROM cause_records WHERE question_id = ? AND cause = ? LIMIT 1',
            variables: [
              Variable.withString(updated.questionId),
              Variable.withString(updated.cause),
            ],
          )
          .get(),
    );
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (rows.isEmpty) {
      written = updated;
    } else {
      final current = _causeFromRow(rows.first);
      if (result == 'solved') {
        final count = isRecheck
            ? current.solvedCount
            : current.solvedCount + 1;
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
    await db.customInsert(
      'INSERT OR REPLACE INTO cause_records '
      '(question_id, cause, subject_id, status, solved_count, last_check, '
      'recheck_date, remedy_history, joined_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      variables: _variables(_causeRecordToRow(written)),
    );
    await db.customInsert(
      'INSERT INTO review_history (question_id, result, reviewed_at) '
      'VALUES (?, ?, ?)',
      variables: [
        Variable.withString(questionId),
        Variable.withString(result),
        Variable.withInt(DateTime.now().millisecondsSinceEpoch),
      ],
    );
    await db.customUpdate(
      'UPDATE questions SET review_count = review_count + 1 WHERE id = ?',
      variables: [Variable.withString(questionId)],
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
    final old = _rows(
      await db
          .customSelect(
            'SELECT is_organized FROM questions WHERE id = ? LIMIT 1',
            variables: [Variable.withString(q.id)],
          )
          .get(),
    );
    countOrganizedToday =
        old.isNotEmpty && (old.first['is_organized'] as int?) != 1;
  }
  final values = _toRow(q)
    ..remove('review_count')
    ..remove('id');
  final updated = await db.customUpdate(
    // 列顺序与 _toRow 去掉 id / review_count 后一致（26 列）：
    // UPDATE 的列里不含 review_count（见函数头注释）。
    'UPDATE questions SET title = ?, subject_id = ?, folder_ids = ?, '
    'exam_id = ?, knowledge_ids = ?, error_types = ?, '
    'custom_error_types = ?, tags = ?, answer = ?, explanation = ?, '
    'notes = ?, is_organized = ?, is_demo = ?, is_favorite = ?, '
    'is_archived = ?, review_joined = ?, created_at = ?, slice_kind = ?, '
    'slice_text = ?, source_path = ?, source_kind = ?, source_page = ?, '
    'page_image_path = ?, slice_path = ?, slice_width = ?, '
    'slice_height = ? WHERE id = ?',
    variables: [..._variables(values), Variable.withString(q.id)],
  );
  if (updated == 0) {
    await db.customInsert(
      'INSERT OR REPLACE INTO questions '
      '(id, title, subject_id, folder_ids, exam_id, knowledge_ids, '
      'error_types, custom_error_types, tags, answer, explanation, notes, '
      'review_count, is_organized, is_demo, is_favorite, is_archived, '
      'review_joined, created_at, slice_kind, slice_text, source_path, '
      'source_kind, source_page, page_image_path, slice_path, slice_width, '
      'slice_height) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '
      '?, ?, ?, ?, ?, ?, ?, ?)',
      variables: _variables(_toRow(q)),
    );
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
  if (q.isOrganized) {
    await db.customUpdate(
      'UPDATE collect_tasks SET status = ? WHERE question_id = ? AND status = ?',
      variables: [
        Variable.withString(CollectStatus.done.name),
        Variable.withString(q.id),
        Variable.withString(CollectStatus.pendingOrganize.name),
      ],
    );
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
  final row = await db
      .customSelect(
        'SELECT slice_path FROM questions WHERE id = ? LIMIT 1',
        variables: [Variable.withString(id)],
      )
      .getSingleOrNull();
  if (row == null) return null;
  return row.data['slice_path'] as String?;
}

/// §4.5/§3.4：从复习队列里去掉该题的项（队列是 ReviewQueueItem
/// 对象数组，按 questionId 匹配，不再拼字符串比对）。
Future<void> _removeFromReviewQueueTxn(
  QuizDatabase db,
  String questionId,
) async {
  final rows = _rows(
    await db
        .customSelect('SELECT queue FROM review_state WHERE id = 1 LIMIT 1')
        .get(),
  );
  if (rows.isEmpty) return;
  final queue = AppDatabase.decodeQueue(rows.first['queue']);
  final kept = queue.where((e) => e.questionId != questionId).toList();
  if (kept.length == queue.length) return;
  await db.customUpdate(
    'UPDATE review_state SET queue = ? WHERE id = ?',
    variables: [
      Variable.withString(AppDatabase.encodeQueue(kept)),
      Variable.withInt(1),
    ],
  );
}

/// §4.2/§4.5：删题的全部写操作（事务内，不 bump、不开新事务）：
/// 解决记录 → 自查历史 → 收集任务的指向置空（任务本身保留）→
/// 复习队列里的项 → §1.2(c) 该题的框（含第 1 层框及其子框，
/// parent_box_id 指向该题整题框的行）→ 题目行。
/// 注意：页图不删（同页多题共享）；切片文件在事务提交后由调用方
/// 处理（P2 落盘后，见 §4.5）。
Future<void> _deleteQuestionTxn(QuizDatabase db, String id) async {
  await db.customUpdate(
    'DELETE FROM cause_records WHERE question_id = ?',
    variables: [Variable.withString(id)],
  );
  await db.customUpdate(
    'DELETE FROM review_history WHERE question_id = ?',
    variables: [Variable.withString(id)],
  );
  await db.customUpdate(
    'UPDATE collect_tasks SET question_id = NULL WHERE question_id = ?',
    variables: [Variable.withString(id)],
  );
  await _removeFromReviewQueueTxn(db, id);
  // 先删子框（parent_box_id 指向该题整题框的行），再删该题的框。
  final ownBoxes = _rows(
    await db
        .customSelect(
          'SELECT id FROM question_boxes WHERE question_id = ?',
          variables: [Variable.withString(id)],
        )
        .get(),
  );
  for (final row in ownBoxes) {
    await db.customUpdate(
      'DELETE FROM question_boxes WHERE parent_box_id = ?',
      variables: [Variable.withString(row['id'] as String)],
    );
  }
  await db.customUpdate(
    'DELETE FROM question_boxes WHERE question_id = ?',
    variables: [Variable.withString(id)],
  );
  await db.customUpdate(
    'DELETE FROM questions WHERE id = ?',
    variables: [Variable.withString(id)],
  );
}

extension AppDatabaseQuestions on AppDatabase {
  Future<List<Question>> allQuestions() async =>
      AppDatabase.allQuestionsFrom(await db);

  Future<Question?> questionById(String id) async {
    final d = await db;
    final row = await d
        .customSelect(
          'SELECT * FROM questions WHERE id = ? LIMIT 1',
          variables: [Variable.withString(id)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    return _fromRow(row.data);
  }

  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
    String questionId,
  ) async {
    final d = await db;
    final rows = _rows(
      await d
          .customSelect(
            'SELECT * FROM review_history WHERE question_id = ? ORDER BY reviewed_at DESC',
            variables: [Variable.withString(questionId)],
          )
          .get(),
    );
    return rows
        .map(
          (r) => (
            result: r['result'] as String,
            reviewedAt: DateTime.fromMillisecondsSinceEpoch(
              r['reviewed_at'] as int,
            ),
          ),
        )
        .toList();
  }

  Future<void> addCauseCheckHistory({
    required String questionId,
    required String result,
  }) async {
    final d = await db;
    await d.customInsert(
      'INSERT INTO review_history (question_id, result, reviewed_at) '
      'VALUES (?, ?, ?)',
      variables: [
        Variable.withString(questionId),
        Variable.withString(result),
        Variable.withInt(DateTime.now().millisecondsSinceEpoch),
      ],
    );
  }

  Future<List<CauseRecord>> allCauseRecords() async {
    final d = await db;
    final rows = _rows(
      await d
          .customSelect(
            'SELECT * FROM cause_records ORDER BY joined_at ASC, id ASC',
          )
          .get(),
    );
    return rows.map(_causeFromRow).toList();
  }

  Future<List<CauseRecord>> causeRecordsForQuestion(String questionId) async {
    final d = await db;
    final rows = _rows(
      await d
          .customSelect(
            'SELECT * FROM cause_records WHERE question_id = ? ORDER BY id ASC',
            variables: [Variable.withString(questionId)],
          )
          .get(),
    );
    return rows.map(_causeFromRow).toList();
  }

  Future<void> ensureCauseRecords(Question q) async {
    final d = await db;
    await _seedCauseRecordsFor(d, q, joinedAt: DateTime.now());
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
    final updated = await d.customUpdate(
      'UPDATE cause_records SET remedy_history = ? WHERE question_id = ? AND cause = ?',
      variables: [
        Variable.withString(AppDatabase.encodeRemedyList(r.remedyHistory)),
        Variable.withString(r.questionId),
        Variable.withString(r.cause),
      ],
    );
    if (updated == 0) {
      await d.customInsert(
        'INSERT OR REPLACE INTO cause_records '
        '(question_id, cause, subject_id, status, solved_count, last_check, '
        'recheck_date, remedy_history, joined_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        variables: _variables(_causeRecordToRow(r)),
      );
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

  Future<void> deleteCauseRecordsForQuestion(String questionId) async {
    final d = await db;
    await d.customUpdate(
      'DELETE FROM cause_records WHERE question_id = ?',
      variables: [Variable.withString(questionId)],
    );
  }

  Future<void> deleteCauseRecord(String questionId, String cause) async {
    final d = await db;
    await d.customUpdate(
      'DELETE FROM cause_records WHERE question_id = ? AND cause = ?',
      variables: [Variable.withString(questionId), Variable.withString(cause)],
    );
  }

  Future<void> saveReviewState({
    required List<ReviewQueueItem> queue,
    required int position,
  }) async {
    final d = await db;
    await d.customInsert(
      'INSERT OR REPLACE INTO review_state (id, queue, position, updated_at) '
      'VALUES (?, ?, ?, ?)',
      variables: [
        Variable.withInt(1),
        Variable.withString(AppDatabase.encodeQueue(queue)),
        Variable.withInt(position),
        Variable.withInt(DateTime.now().millisecondsSinceEpoch),
      ],
    );
  }

  Future<ReviewSessionState?> loadReviewState() async {
    final d = await db;
    final row = await d
        .customSelect('SELECT * FROM review_state WHERE id = 1 LIMIT 1')
        .getSingleOrNull();
    if (row == null) return null;
    final r = row.data;
    final queue = AppDatabase.decodeQueue(r['queue']);
    if (queue.isEmpty) return null;
    return ReviewSessionState(
      queue: queue,
      position: (r['position'] as int?) ?? 0,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
    );
  }

  Future<void> clearReviewState() async {
    final d = await db;
    await d.customUpdate(
      'DELETE FROM review_state WHERE id = 1',
    );
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
}
