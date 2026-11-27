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

/// FSRS 全量迁移包2（2026-11-27）：只翻 `review_joined` 标志位，
/// 不再播种 cause_records（旧 `setReviewJoinedIntoImpl` 的播种分支
/// 已删除；入池建卡走 `QuestionRepository.joinFsrsPool`）。
/// SR2-14：题行只按列 UPDATE `review_joined`，不用整行 REPLACE——
/// 旧写法整行写回会把内存旧快照里的 `review_count` 写回库里。
/// 题行不存在时才整行 INSERT（新题入库，快照值即初始值）。
/// 空错因的题也可翻标志（FSRS 按题，不按错因；旧“错因为空返回 false”
/// 的限制随播种一起删除）。
Future<bool> setReviewJoinedFlagIntoImpl(
  QuizDatabase db,
  Question q,
  bool joined,
) async {
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
  return true;
}

// ---------------------------------------------------------------------------
// 十四批 M3：attempts / 会话持久化
// ---------------------------------------------------------------------------

/// M3-10/M3-14：attempt 写入（一次会话每题一条）。按
/// UNIQUE(session_id, question_id) 查：已有 → 更新作答字段
/// （保留 id / submission_id / created_at，不重新提交、不新建）；
/// 无 → 新建一行。返回 attempt id。
/// 跳过后重遇、恢复重放都走同一条记录，不产生多条“看起来像独立作答”
/// 的记录。
/// P5：抽出事务内版本 [_recordAttemptInTxn]——核对提交事务
/// （_submitReviewCheckInto）直接调它，不另开事务（Drift 嵌套事务
/// 是 savepoint，但这里不需要嵌套）；本函数保持原行为（自己包事务）。
Future<String> recordAttemptIntoImpl(
  QuizDatabase db, {
  required AttemptData attempt,
}) async {
  late String id;
  await db.transaction(() async {
    id = await _recordAttemptInTxn(db, attempt);
  });
  return id;
}

/// attempt 写入的事务内版本（调用方已包事务时直接调本函数；
/// 单独调时走 [recordAttemptIntoImpl]，它包事务）。
Future<String> _recordAttemptInTxn(QuizDatabase db, AttemptData attempt) async {
  late String id;
  {
    final existing =
        await (db.select(db.attempts)..where(
              (t) =>
                  t.sessionId.equals(attempt.sessionId) &
                  t.questionId.equals(attempt.questionId),
            ))
            .getSingleOrNull();
    if (existing != null) {
      id = existing.id;
      await (db.update(
        db.attempts,
      )..where((t) => t.id.equals(existing.id))).write(
        AttemptsCompanion(
          selected: Value(
            attempt.selected == null ? null : jsonEncode(attempt.selected),
          ),
          correct: Value(attempt.correct),
          confidence: Value(attempt.confidence),
          answerVersion: Value(attempt.answerVersion),
          contentVersion: Value(attempt.contentVersion),
          status: Value(attempt.status),
          causeIds: Value(jsonEncode(attempt.causeIds)),
          durationMs: Value(attempt.durationMs),
        ),
      );
    } else {
      id = attempt.id;
      await db
          .into(db.attempts)
          .insert(
            AttemptsCompanion.insert(
              id: attempt.id,
              questionId: attempt.questionId,
              sessionId: attempt.sessionId,
              mode: attempt.mode,
              selected: Value(
                attempt.selected == null ? null : jsonEncode(attempt.selected),
              ),
              correct: Value(attempt.correct),
              confidence: Value(attempt.confidence),
              answerVersion: Value(attempt.answerVersion),
              contentVersion: Value(attempt.contentVersion),
              status: attempt.status,
              causeIds: Value(jsonEncode(attempt.causeIds)),
              durationMs: Value(attempt.durationMs),
              submissionId: attempt.submissionId,
              createdAt: attempt.createdAt,
            ),
          );
    }
  }
  return id;
}

/// M3-10：读一条 attempt（会话恢复时按原题状态恢复用）。
Future<AttemptData?> loadAttemptIntoImpl(
  QuizDatabase db, {
  required String sessionId,
  required String questionId,
}) async {
  final row =
      await (db.select(db.attempts)..where(
            (t) =>
                t.sessionId.equals(sessionId) & t.questionId.equals(questionId),
          ))
          .getSingleOrNull();
  if (row == null) return null;
  return _attemptFromDb(row);
}

/// M3-10/M3-15：读某会话的全部 attempts（小结汇总用）。
Future<List<AttemptData>> loadAttemptsForSessionIntoImpl(
  QuizDatabase db, {
  required String sessionId,
}) async {
  final rows = await (db.select(
    db.attempts,
  )..where((t) => t.sessionId.equals(sessionId))).get();
  return rows.map(_attemptFromDb).toList();
}

/// 十四批 M3（M3-10 断点恢复重建用）：本会话里该错因是否已有任何
/// verdict 事件（不限 verdict——submittedCauses 是“已提交过”，
/// 不限“已解决”）。供恢复时以 review_history 实际写入为准重建
/// per_question_state：崩溃窗口（数据库已写、review_state 未更新）
/// 下，恢复后不再把已提交的错因当成未提交；重复计数仍由数据层
/// (d) 规则挡，这里只补展示态。
Future<bool> hasSessionVerdictIntoImpl(
  QuizDatabase db, {
  required String causeStableId,
  required String sessionId,
}) async {
  final rows =
      await (db.select(db.reviewHistory)..where(
            (t) =>
                t.causeId.equals(causeStableId) & t.sessionId.equals(sessionId),
          ))
          .get();
  return rows.isNotEmpty;
}

AttemptData _attemptFromDb(DbAttempt r) => AttemptData(
  id: r.id,
  questionId: r.questionId,
  sessionId: r.sessionId,
  mode: r.mode,
  selected: r.selected == null
      ? null
      : (jsonDecode(r.selected!) as List).map((e) => e.toString()).toList(),
  correct: r.correct,
  confidence: r.confidence,
  answerVersion: r.answerVersion,
  contentVersion: r.contentVersion,
  status: r.status,
  causeIds: (jsonDecode(r.causeIds) as List).map((e) => e.toString()).toList(),
  durationMs: r.durationMs,
  submissionId: r.submissionId,
  createdAt: r.createdAt,
);

/// §8.1：写题（可单测版）：直接对传入的库句柄写，不碰单例、不 bump。
/// SR2-14：UPDATE-first，且 UPDATE 的列里不含 `review_count`——
/// 它自 FSRS 迁移包1起不再有 +1 写入（旧自查写入层已退役）。
/// 旧写法是整行 REPLACE：拿着旧快照（`reviewCount: 5`）的
/// toggleFavorite / archive / save 会把库内值打回 5。
/// 已存在的行只 UPDATE 其它列（标题、文件夹、标签、收藏/归档等编辑
/// 内容照常写回）；不存在时才整行 INSERT（快照值即新题初始值）。
/// U1-1 版本令牌（REV5）：一次保存携带的“新鲜度断言”，取自表单加载
/// 时的模型（`contentVersion` 随模型携带，无需新列、无 schema 变化）。
/// 不带令牌时保持原有行为；带令牌时写入前在事务内比对版本。
class SaveToken {
  const SaveToken({
    required this.questionId,
    required this.expectedContentVersion,
  });
  final String questionId;
  final int expectedContentVersion;
}

/// U1-2：令牌版本不符（或行已消失、令牌与题目不符）时拒绝写入的信号。
/// 在事务内、任何写语句之前抛出，事务自动回滚，本次调用零写入。
/// 调用方（整理页保存）接住它即视为“已有更新的保存先落库，本次表单
/// 是旧的”，刷新队列与表单后由用户重新保存；不带令牌的调用方永远
/// 不会见到它（失败通道用异常而不用 bool 返回值，是为了不改
/// `repo.save` 的 `Future<void>` 返回类型——改成 `Future<bool>`
/// 会让全部现有 `save` 覆盖的返回类型失效）。
class SaveTokenMismatch implements Exception {
  const SaveTokenMismatch(
    this.questionId,
    this.expectedContentVersion,
    this.actualContentVersion,
  );
  final String questionId;
  final int expectedContentVersion;

  /// 行内实际版本；null = 行已消失，或令牌与题目不符（未比对行版本）。
  final int? actualContentVersion;

  @override
  String toString() =>
      'SaveTokenMismatch($questionId: expected $expectedContentVersion, '
      'actual $actualContentVersion)';
}

/// U1-2 / T1-2：题目行写入的唯一漏斗。整个“读旧行 → 版本计算 → 写”
/// 包进同一个 `db.transaction`（新增包裹；原代码无此包裹，读与写
/// 之间有 await 间隙，并发写可插进来）。Drift 事务按调用顺序执行、
/// 同一事务内的语句互不交错，校验读与写入之间任何其他数据库写操作
/// 都无法插入。调用方若传进来的是 Transaction 句柄，`db.transaction`
/// 加入外层事务（Drift 嵌套事务语义），不另开事务。
Future<void> upsertQuestionIntoImpl(
  QuizDatabase db,
  Question q, {
  SaveToken? token,
}) async {
  await db.transaction(() => _upsertQuestionIntoTxn(db, q, token: token));
}

Future<void> _upsertQuestionIntoTxn(
  QuizDatabase db,
  Question q, {
  SaveToken? token,
}) async {
  // 十四批 M2：版本权威——全部 UI 保存路径汇合于此，content_version /
  // answer_version 在这里按“实际内容是否变化”统一计算一次（同一逻辑
  // 保存事务无论改几个相关字段只递增一次；实际内容无变化时不因重新
  // 保存而递增）。调用方纯函数里预置的 +1（如 applyManualStemEdit、
  // withManualQuestionType、deleteFigureFromQuestion）在这里被
  // 归一化为恰好一次，不会双计；新行（库里没有旧行）按模型值原样入库。
  // 显式抬高版本时以调用方为准（max(库内旧值, 模型值)）：b13 既有契约
  // 允许调用方只改版本整行写回（_RacingRecognizer 的并发守门模拟、
  // b13_migration 的 copyWith(contentVersion: 4)），那是调用方明确
  // 移动版本号时钟，不是“重新保存”；仅当模型版本未抬高时才按可见
  // 内容变化递增。版本永不回退。
  // 比对口径（P2-2）：用户可见内容字段集合 + 来源身份——题干文本、
  // 切分状态、图块列表与顺序、来源切片身份（slice_path/宽高）、题型、
  // 候选状态（pending/accepted/ignored/stale 是用户可见状态，横幅
  // 显隐随它变，不是技术元数据）；不比较 ocr_raw 的技术元数据
  // （请求记录、时间戳、token 用量、layout 原始 JSON 非内容字段）。
  // question_type 是归类字段之外的例外（P2-1）：其变化 → content_version
  // +1；文件夹/标签/学科/考试等归类字段修改 → 两个版本都不碰。
  // 答案侧（answer/explanation/correct_option/option_labels）修改 →
  // answer_version +1，不碰 content_version。
  final old = await (db.select(
    db.questions,
  )..where((t) => t.id.equals(q.id))).getSingleOrNull();
  // U1-2：带令牌时先比对版本——行已消失、令牌与题目不符或版本不符 →
  // 抛 SaveTokenMismatch、零写入（抛在任何写语句之前）。不带令牌时
  // 本段不执行，保持原有行为（不存在的行按旧口径整行插入）。
  if (token != null) {
    if (token.questionId != q.id) {
      throw SaveTokenMismatch(
        token.questionId,
        token.expectedContentVersion,
        old?.contentVersion,
      );
    }
    if (old == null || old.contentVersion != token.expectedContentVersion) {
      throw SaveTokenMismatch(
        token.questionId,
        token.expectedContentVersion,
        old?.contentVersion,
      );
    }
  }
  // B11-10 今日小结计数：先读旧行，判断是不是未整理→已整理的跃迁
  // （读在写之前；写成功后才 +1，写失败不计）。只在旧行存在且未整理
  // 时才计：新行直接以已整理入库（种子/恢复路径）不是一次整理动作，
  // 不计；已整理题的重复保存也不计（旧行已是已整理）。
  var countOrganizedToday = false;
  if (q.isOrganized) {
    countOrganizedToday = old != null && old.isOrganized != 1;
  }
  var effective = q;
  // P5：内容实质变化的两个信号（供下面的 FSRS 重置钩子用）：
  // visibleChanged = 题干/选项文字/题型变（抬 content_version）；
  // answerSubstantiveChanged = 标准答案变（answer / correct_option /
  // option_labels，抬 answer_version）。只改解析文字（explanation）
  // 或纯排版/分类标签时两者都为 false，不重置。
  var visibleChanged = false;
  var answerSubstantiveChanged = false;
  if (old != null) {
    // 十四批 M3（P1-A）：改标签保存先过集中规则（确认清零、旧答案失效/
    // 待重新核对），再算版本；后续比较一律用调整后的 effective。
    effective = _applyOptionLabelChangeRules(old, effective);
    visibleChanged =
        old.ocrStem != effective.ocrStem ||
        old.ocrSplitStatus != effective.ocrSplitStatus ||
        old.ocrFigures != effective.ocrFigures ||
        old.slicePath != effective.slicePath ||
        old.sliceWidth != effective.sliceWidth ||
        old.sliceHeight != effective.sliceHeight ||
        old.questionType != effective.questionType ||
        // Win11 反馈包 5：选项文字是内容（不是答案）：改文字 →
        // content_version +1；键序不同不算变（按映射比较）。
        !_optionContentsEqual(
          decodeOptionContents(old.optionContents),
          effective.optionContents,
        ) ||
        _candidateStatusOf(old.ocrRaw) != _candidateStatusOf(effective.ocrRaw);
    final answerChanged =
        old.answer != effective.answer ||
        old.explanation != effective.explanation ||
        old.correctOption != effective.correctOption ||
        !_optionLabelsEqual(old.optionLabels, effective.optionLabels) ||
        old.answerPendingRecheck != (effective.answerPendingRecheck ? 1 : 0);
    answerSubstantiveChanged =
        old.answer != effective.answer ||
        old.correctOption != effective.correctOption ||
        !_optionLabelsEqual(old.optionLabels, effective.optionLabels);
    if (visibleChanged || answerChanged) {
      // 内容变了：模型版本已抬高时以模型为准（不双计）；未抬高时 +1。
      effective = effective.copyWith(
        contentVersion:
            math.max(old.contentVersion, effective.contentVersion) +
            (visibleChanged && effective.contentVersion <= old.contentVersion
                ? 1
                : 0),
        answerVersion:
            math.max(old.answerVersion, effective.answerVersion) +
            (answerChanged && effective.answerVersion <= old.answerVersion
                ? 1
                : 0),
      );
    } else {
      // 内容无变化：调用方显式抬高的版本予以保留（max），否则按库内
      // 旧值写回，不因重新保存而递增。
      effective = effective.copyWith(
        contentVersion: math.max(old.contentVersion, effective.contentVersion),
        answerVersion: math.max(old.answerVersion, effective.answerVersion),
      );
    }
  }
  final updated =
      await (db.update(db.questions)..where((t) => t.id.equals(q.id))).write(
        // UPDATE 的列里不含 review_count（见函数头注释）与 id（WHERE 已定）。
        _questionCompanion(
          effective,
          includeId: false,
          includeReviewCount: false,
        ),
      );
  if (updated == 0) {
    await db
        .into(db.questions)
        .insert(
          _questionCompanion(effective),
          mode: InsertMode.insertOrReplace,
        );
  }
  // P5：内容实质修改 → FSRS 卡片重置（实施方案 v2 §7，见
  // resetFsrsCardForContentChangeInto）：题干/选项/标准答案/题型变
  // 才重置；只改解析文字、纯排版或分类标签不重置。旧作答事实保留，
  // 不参与新版本重放；card_id 不变。新行（old == null）没有卡可重置。
  // 与题写同一事务：题保存失败时重置不生效，重置失败时题也不保存。
  if (old != null && (visibleChanged || answerSubstantiveChanged)) {
    await resetFsrsCardForContentChangeInto(db, q.id, effective.contentVersion);
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

/// 十四批 M2（版本权威的比对口径）：从 ocr_raw JSON 里只取候选状态
/// （`candidate_status`；缺键/非法时按 'none' 计，与 GlmOcrRawData
/// 的缺省一致）。只比较候选状态，不比较请求记录、时间戳、token 用量
/// 等技术元数据——那些变了不递增 content_version。
String _candidateStatusOf(String? ocrRaw) {
  if (ocrRaw == null || ocrRaw.isEmpty) return 'none';
  try {
    final decoded = jsonDecode(ocrRaw);
    if (decoded is Map<String, dynamic>) {
      final status = decoded['candidate_status'];
      if (status is String && status.isNotEmpty) return status;
    }
  } catch (_) {
    // 非法 JSON 按无候选计。
  }
  return 'none';
}

/// 十四批 M2（版本权威的比对口径）：option_labels 在库里是 JSON 数组
/// （Drift 类型转换器，行对象里是 `List<String>?`），比较时按列表
/// 内容比较（顺序敏感；写入时由 _questionCompanion 统一编码）。
/// NULL 与 [] 不同义（D-119）：NULL = 未确认，[] = 已确认无选项。
/// 必须做 null-aware 列表比较——旧实现把两者都编码成 ''（join 后
/// null 与 [] 同值），NULL↔[] 变化会漏触发 _applyOptionLabelChangeRules，
/// 导致 option_labels_confirmed 不清零、答案失效处理不执行
/// （M5 修复轮 2，GPT fix1 窄审 §3.3 P1）。
bool _optionLabelsEqual(List<String>? a, List<String>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Win11 反馈包 5：选项内容按标签映射比较（键序不同不算变；
/// Dart 的 Map == 是同一性，不能直接比）。
bool _optionContentsEqual(Map<String, String>? a, Map<String, String>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}

/// 十四批 M3（P1-A + 标签确认清零）：改标签保存的集中处理，在
/// [upsertQuestionIntoImpl] 的版本计算之前跑，返回调整后的模型。
/// 只在旧行存在且标签有序列表确实变化时触发（首次设标签、旧标签为
/// NULL 时无旧答案可失效，不触发；仅改标签显示样式不经过本函数，
/// 调用方不把样式变化写成标签列表变化）。
///
/// - 标签变化且本次不是“确认选项”保存 → option_labels_confirmed 清零，
///   须重新确认才能判分。
/// - 多选/不定项：旧 answer/explanation 非空时，未带 answerReconfirmed
///   信号 → 两者置 NULL、answerPendingRecheck 置 1（同一次保存只 +1
///   answer_version，由调用方版本逻辑按 answerChanged 计）；带信号
///   （原样确认或改写后保存）→ 保留答案、标记清除。
/// - 单选：集合变化且 correct_option 不在新集合 → 置 NULL、标记置 1；
///   只调换顺序、集合不变、correct_option 与旧值相同且未带信号 →
///   同样置 NULL、标记置 1（其指向的选项含义已改变）；带信号重选后保留。
/// - 判断题标签固定，不受本条影响。
/// - 标签未变但旧行待重新核对：本次带 answerReconfirmed 信号、或答案/
///   正确选项文本确实改了 → 视为重新填写，标记清除；否则标记保留。
Question _applyOptionLabelChangeRules(DbQuestion old, Question q) {
  final oldLabels = old.optionLabels;
  final newLabels = q.optionLabels;
  final labelsChanged = !_optionLabelsEqual(oldLabels, newLabels);
  var out = q;
  final hadOldAnswer =
      (old.answer != null && old.answer!.trim().isNotEmpty) ||
      (old.explanation != null && old.explanation!.trim().isNotEmpty);
  if (labelsChanged) {
    // Win11 反馈包 5：标签删/改只动对应键——新标签集之外的选项内容键
    // 删掉，存活键的文字原样保留（标签映射按标签取，删 B 不会让 C
    // 串位）；标签全清时选项内容一并清空。
    if (q.optionContents != null) {
      if (newLabels == null) {
        out = out.copyWith(clearOptionContents: true);
      } else {
        final pruned = Map<String, String>.of(q.optionContents!)
          ..removeWhere((k, _) => !newLabels.contains(k));
        if (pruned.length != q.optionContents!.length) {
          out = out.copyWith(optionContents: pruned);
        }
      }
    }
    // 改标签/数量 → 确认清零（除非本次就是确认保存）。
    if (!q.optionLabelsJustConfirmed) {
      out = out.copyWith(optionLabelsConfirmed: false);
    }
    final type = q.questionType;
    if (type == 'choice_multi' || type == 'choice_variable') {
      if (hadOldAnswer) {
        if (q.answerReconfirmed) {
          out = out.copyWith(answerPendingRecheck: false);
        } else {
          out = out.copyWith(
            clearAnswer: true,
            clearExplanation: true,
            answerPendingRecheck: true,
          );
        }
      }
    } else if (type == 'choice_single') {
      final oldCorrect = old.correctOption;
      final newCorrect = out.correctOption;
      final oldSet = (oldLabels ?? const []).toSet();
      final newSet = (newLabels ?? const []).toSet();
      final setChanged =
          oldSet.length != newSet.length || !oldSet.containsAll(newSet);
      if (oldCorrect != null && oldCorrect.isNotEmpty) {
        if (newCorrect == null || !newSet.contains(newCorrect)) {
          // 集合变化致正确答案失效，或本次未重选（correct 已空）。
          out = out.copyWith(
            clearCorrectOption: true,
            answerPendingRecheck: true,
          );
        } else if (!setChanged &&
            newCorrect == oldCorrect &&
            !q.answerReconfirmed) {
          // 只调换标签顺序、集合不变：正确选项含义已变，未重选即失效。
          out = out.copyWith(
            clearCorrectOption: true,
            answerPendingRecheck: true,
          );
        } else if (q.answerReconfirmed) {
          out = out.copyWith(answerPendingRecheck: false);
        }
      } else if (q.answerReconfirmed) {
        out = out.copyWith(answerPendingRecheck: false);
      }
    }
  } else if (old.answerPendingRecheck == 1) {
    // 标签未变：带重确认信号、或答案/正确选项文本确实改了 → 清除标记。
    if (q.answerReconfirmed ||
        q.answer != old.answer ||
        q.correctOption != old.correctOption) {
      out = out.copyWith(answerPendingRecheck: false);
    }
  }
  return out;
}

/// §4.5：删题（可单测版）：一次事务，不 bump。事务提交后删该题
/// 独占的切片文件（页图不删，同页多题共享；文件删失败不回滚，
/// 由孤儿清理兜底）。十四批 M2：图块裁图同样在提交后逐个重查
/// 引用再删（删前已收好该题的 crop_path 列表；删后若仍被其它题
/// 引用，`_deleteDataFileIfUnreferenced` 的锁内重查会跳过）。
Future<void> deleteQuestionFromImpl(QuizDatabase db, String id) async {
  final slice = await _slicePathOf(db, id);
  final figureCrops = await _figureCropPathsOf(db, id);
  // WP-C #8 U3-2：事务前快照被删题的 ocrFigures 是否未知（行删后
  // 全库扫描已查不到它，见 [_ocrFiguresUnknownOf]）。
  final unknownBefore = await _ocrFiguresUnknownOf(db, id);
  await db.transaction(() => _deleteQuestionTxn(db, id));
  await _deleteDataFileIfUnreferenced(
    db,
    slice,
    unknownFigureRefsBeforeDelete: unknownBefore,
  );
  for (final crop in figureCrops) {
    await _deleteDataFileIfUnreferenced(
      db,
      crop,
      unknownFigureRefsBeforeDelete: unknownBefore,
    );
  }
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
  final figureCrops = <String>[];
  // WP-C #8 U3-2：事务前快照被删题的 ocrFigures 是否未知（行删后查不到）。
  var unknownBefore = false;
  for (final id in ids) {
    slices.add(await _slicePathOf(db, id));
    figureCrops.addAll(await _figureCropPathsOf(db, id));
    if (await _ocrFiguresUnknownOf(db, id)) unknownBefore = true;
  }
  await db.transaction(() async {
    for (final id in ids) {
      await _deleteQuestionTxn(db, id);
    }
  });
  for (final slice in slices) {
    await _deleteDataFileIfUnreferenced(
      db,
      slice,
      unknownFigureRefsBeforeDelete: unknownBefore,
    );
  }
  for (final crop in figureCrops) {
    await _deleteDataFileIfUnreferenced(
      db,
      crop,
      unknownFigureRefsBeforeDelete: unknownBefore,
    );
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
/// 自查历史 → 作答记录 → 解决记录 → 收集任务的指向置空（任务本身保留）→
/// 复习队列里的项 → §1.2(c) 该题的框（含第 1 层框及其子框，
/// parent_box_id 指向该题整题框的行）→ 题目行。
/// 十四批 M1 P1-3：删除顺序写死为 review_history → attempts →
/// cause_records → question_boxes → questions（同事务）；review_history
/// 的 cause_id 与 attempts 的 question_id 不建外键，删除顺序由事务代码
/// 保证，不依赖级联；DDL 中写明本顺序为约定，改顺序须同步改方案。
/// 注意：页图不删（同页多题共享）；切片文件在事务提交后由调用方
/// 处理（P2 落盘后，见 §4.5）。顺序约束（plan 协议）：先删数据库行，
/// 再删切片文件——顺序不变，文件删除在 [deleteQuestionFromImpl] 里
/// 事务提交后才做（文件删除本身走 M2 的统一文件生命周期协调机制，
/// M1 不动 `_deleteDataFileIfUnreferenced` 与孤儿清理）。
Future<void> _deleteQuestionTxn(QuizDatabase db, String id) async {
  await (db.delete(
    db.reviewHistory,
  )..where((t) => t.questionId.equals(id))).go();
  await (db.delete(db.attempts)..where((t) => t.questionId.equals(id))).go();
  // P2-01：这两张表没有外键/级联；不删会留下 ocr_jobs 孤儿（其
  // crop_path 还会让 _isFileReferenced 永久保留切片）与最近查看行。
  await (db.delete(db.ocrJobs)..where((t) => t.questionId.equals(id))).go();
  await (db.delete(
    db.recentlyViewedQuestions,
  )..where((t) => t.questionId.equals(id))).go();
  await (db.delete(
    db.causeRecords,
  )..where((t) => t.questionId.equals(id))).go();
  // P3 系统级边界：永久删除按既有级联删除契约——题删了，它的 FSRS
  // 卡片（fsrs_cards 行）一起删，否则到期队列里会剩一个查无此题的
  // id；事件账本（fsrs_events）是幂等审计记录，保留不动（新提交用
  // 新 eventId，不会与旧事件撞）。fsrs_cards 是原始 SQL 表（无
  // drift 生成表类），用 customUpdate 删；v7 夹具库无此表时忽略错误。
  try {
    await db.customUpdate(
      'DELETE FROM fsrs_cards WHERE question_id = ?',
      variables: [Variable.withString(id)],
    );
  } catch (_) {
    // 无 fsrs_cards 表的旧库夹具：没有卡片可删，忽略。
  }
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

  /// SR3-4：方法名即语义——只改 `remedy_history` 列，不整行
  /// REPLACE。FSRS 全量迁移包 7（R1 冻结规则）：
  /// ① 行已存在时只 UPDATE `remedy_history` 列，状态列（`status` /
  /// `solvedCount` / `recheckDate` / `lastCheck` / 锚点）绝不碰；
  /// ② 行不存在时 INSERT 只允许冻结默认值（`status='pending'`、
  /// `solvedCount=0`、`recheckDate` / `lastCheck` / 锚点全空），
  /// 不信任传入记录的状态字段（`saveRemedy` 传入的记录已无状态
  /// 字段；`saveCauseRecord` 只剩测试调用，同样只写默认值）。
  /// 唯一生产调用方是 `repository.saveRemedy`（只改补救历史）。
  /// 旧名 `upsertCauseRecord` 暗示全量 upsert，但行已存在时状态
  /// 改动会被静默丢弃——改名让窄化显性化：经本方法改状态是
  /// “按设计丢弃”，不是“写入失败”。
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
    // FSRS 全量迁移包 7（R1 复核）：补救历史是复习记录，详情页
    // 订阅 reviewRecords 刷新展示；角标已全量读 FSRS（见
    // badge_counts_provider），补救写入不可能改变任何角标数，
    // 故只发 reviewRecords，不再发 badges。
    DataChangeBus.instance.emit(
      DataChangeEvent(
        kinds: const {DataChangeKind.reviewRecords},
        questionId: r.questionId,
      ),
    );
  }

  /// FSRS 全量迁移包2：只翻 `review_joined` 标志位（实例版，
  /// 见 [AppDatabase.setReviewJoinedFlagInto]），不播种 cause_records。
  /// 提交成功后才 bump 一次。
  Future<bool> setReviewJoinedFlag(Question q, bool joined) async {
    final d = await db;
    final ok = await AppDatabase.setReviewJoinedFlagInto(d, q, joined);
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

  /// 十四批 M3：attempt 写入（见 recordAttemptIntoImpl）。
  Future<String> recordAttemptTxn({required AttemptData attempt}) async {
    final d = await db;
    return AppDatabase.recordAttemptInto(d, attempt: attempt);
  }

  /// 十四批 M3：读一条 attempt / 某会话全部 attempts。
  Future<AttemptData?> loadAttempt({
    required String sessionId,
    required String questionId,
  }) async {
    final d = await db;
    return AppDatabase.loadAttemptInto(
      d,
      sessionId: sessionId,
      questionId: questionId,
    );
  }

  Future<List<AttemptData>> loadAttemptsForSession({
    required String sessionId,
  }) async {
    final d = await db;
    return AppDatabase.loadAttemptsForSessionInto(d, sessionId: sessionId);
  }

  /// P3 入口 3 样本量统计用：全部 attempts（正式 + 专项，不分会话）。
  /// 只读；按 created_at 升序，便于按时间范围截取。
  Future<List<AttemptData>> allAttempts() async {
    final d = await db;
    final rows = await (d.select(
      d.attempts,
    )..orderBy([(t) => OrderingTerm(expression: t.createdAt)])).get();
    return rows.map(_attemptFromDb).toList();
  }

  /// 十四批 M3（M3-10 断点恢复重建用）：本会话里该错因是否已有 verdict 事件。
  Future<bool> hasSessionVerdict({
    required String causeStableId,
    required String sessionId,
  }) async {
    final d = await db;
    return AppDatabase.hasSessionVerdictInto(
      d,
      causeStableId: causeStableId,
      sessionId: sessionId,
    );
  }

  /// 十四批 M3（M3-10 轻量会话持久化）：除队列与位置外，一并保存
  /// session_id、模式、每题跳过次数、各题作答/核对/verdict 状态
  /// （含 question_submission_id 与两版本快照）。旧调用方只传
  /// queue/position 时其余列写 NULL（老行为兼容）。
  Future<void> saveReviewState({
    required List<ReviewQueueItem> queue,
    required int position,
    String? sessionId,
    String? mode,
    Map<String, int>? skips,
    Map<String, Map<String, Object?>>? perQuestionState,
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
            sessionId: Value(sessionId),
            mode: Value(mode),
            skips: Value(skips == null ? null : encodeSkips(skips)),
            perQuestionState: Value(
              perQuestionState == null
                  ? null
                  : encodePerQuestionState(perQuestionState),
            ),
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
      sessionId: row.sessionId,
      mode: row.mode,
      skips: decodeSkips(row.skips),
      perQuestionState: decodePerQuestionState(row.perQuestionState),
    );
  }

  Future<void> clearReviewState() async {
    final d = await db;
    await (d.delete(d.reviewState)..where((t) => t.id.equals(1))).go();
  }

  /// U1-1：可选令牌直通 [upsertQuestionIntoImpl]。直接调 impl 而不经
  /// `AppDatabase.upsertQuestionInto`（后者在 database.dart 里，无令牌
  /// 参数；无令牌调用方仍走它，行为不变）。令牌不符时 impl 抛
  /// [SaveTokenMismatch]，事件不发（什么都没写）。
  Future<void> upsertQuestion(Question q, {SaveToken? token}) async {
    final d = await db;
    await upsertQuestionIntoImpl(d, q, token: token);
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
  // 十三批 M2：OCR 字段（缺了这段，整行写回会把库里的 OCR 值抹掉）。
  ocrRaw: r.ocrRaw,
  ocrStem: r.ocrStem,
  ocrSplitStatus: r.ocrSplitStatus,
  ocrManualEdited: r.ocrManualEdited == 1,
  contentVersion: r.contentVersion,
  // 十四批 M1：题型两维 + 答案版本（缺了这段，整行写回会把库里的题型抹掉）。
  questionType: r.questionType,
  questionTypeSource: r.questionTypeSource,
  questionBackgroundTags: r.questionBackgroundTags,
  questionBackgroundTagsSource: r.questionBackgroundTagsSource,
  ocrFigures: r.ocrFigures,
  correctOption: r.correctOption,
  optionLabels: r.optionLabels,
  optionLabelsConfirmed: r.optionLabelsConfirmed == 1,
  answerVersion: r.answerVersion,
  // Win11 反馈包 5：选项内容（标签映射 JSON；非法 JSON 读侧按 null 计，
  // 备份校验层已拦非法值入库）与解析器版本。
  optionContents: decodeOptionContents(r.optionContents),
  optionContentsParserVersion: r.optionContentsParserVersion,
  // 十四批 M3（P1-A）：答案待重新核对标记。
  answerPendingRecheck: r.answerPendingRecheck == 1,
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
  // 十三批 M2：OCR 字段全列写回（缺了这段，upsert 会把库里的 OCR 值
  // 抹回默认值；SR2-14 的“整行写不带 review_count”是例外，OCR 列
  // 不在例外里——它们只能经模型写回）。
  ocrRaw: Value(q.ocrRaw),
  ocrStem: Value(q.ocrStem),
  ocrSplitStatus: Value(q.ocrSplitStatus),
  ocrManualEdited: Value(q.ocrManualEdited ? 1 : 0),
  contentVersion: Value(q.contentVersion),
  // 十四批 M1：题型两维 + 答案版本全列写回（同款口径：缺了这段，
  // upsert 会把库里的题型抹回默认值）。
  questionType: Value(q.questionType),
  questionTypeSource: Value(q.questionTypeSource),
  questionBackgroundTags: Value(q.questionBackgroundTags),
  questionBackgroundTagsSource: Value(q.questionBackgroundTagsSource),
  ocrFigures: Value(q.ocrFigures),
  correctOption: Value(q.correctOption),
  optionLabels: Value(q.optionLabels),
  optionLabelsConfirmed: Value(q.optionLabelsConfirmed ? 1 : 0),
  answerVersion: Value(q.answerVersion),
  // Win11 反馈包 5：选项内容按标签映射 JSON 原样写回；NULL = 未解析。
  optionContents: Value(encodeOptionContents(q.optionContents)),
  optionContentsParserVersion: Value(q.optionContentsParserVersion),
  // 十四批 M3（P1-A）：答案待重新核对标记（answerReconfirmed 是保存时
  // 信号，不持久化、不进 Companion）。
  answerPendingRecheck: Value(q.answerPendingRecheck ? 1 : 0),
);

/// FSRS 全量迁移包 7：业务读取模型已缩为冻结历史载体——只读行身份
/// 与补救历史；状态列（`status / solvedCount / lastCheck /
/// recheckDate / 锚点`）不进模型。备份链路读写原始行，不经此处。
CauseRecord _causeRecordFromDb(DbCauseRecord r) => CauseRecord(
  // 十四批 M3：行 id 进模型（review_history.cause_id 用它）。
  id: r.id,
  questionId: r.questionId,
  cause: r.cause,
  subjectId: r.subjectId,
  remedyHistory: r.remedyHistory,
  joinedAt: DateTime.fromMillisecondsSinceEpoch(r.joinedAt),
);

/// FSRS 全量迁移包 7（R1 冻结规则）：本函数只供 `updateCauseRemedy`
/// 的缺行 INSERT 用；状态列强制写冻结默认值，绝不取传入记录的值
/// （`CauseRecord` 已无状态字段）。`id` 有值时带上（insertOrReplace
/// 按主键更新同一行）；无 id（内存新造）时缺席，靠
/// UNIQUE(question_id, cause) 去重。
CauseRecordsCompanion _causeRecordCompanion(CauseRecord r) =>
    CauseRecordsCompanion(
      id: r.id == null ? const Value.absent() : Value(r.id!),
      questionId: Value(r.questionId),
      cause: Value(r.cause),
      subjectId: Value(r.subjectId),
      status: const Value('pending'),
      solvedCount: const Value(0),
      lastCheck: const Value.absent(),
      recheckDate: const Value.absent(),
      remedyHistory: Value(r.remedyHistory),
      joinedAt: Value(r.joinedAt.millisecondsSinceEpoch),
      lastCountedSuccessAt: const Value.absent(),
      lastCountedSessionId: const Value.absent(),
    );
