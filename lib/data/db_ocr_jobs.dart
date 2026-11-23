// 十三批 M3：ocr_jobs 队列表的 CRUD（worker 用）。
// 与 database.dart 同一库（part of），共享库私有成员。
// 单表 part 模式（仿 db_recently_viewed.dart），不塞进 db_backup.dart /
// db_questions.dart。本文件只管队列表的读写：入队、领任务、租约回收、
// 重试/失败/完成写回；OCR 请求与应用结果的逻辑在 services/ocr_queue.dart。
//
// 约定（M2 §3 + GPT 评审 §2）：
// - 不要给 ocr_jobs 加唯一约束：同一题可有多条任务（重识别、改框后新任务）。
//   去重/幂等由 [enqueueOcrJobIntoImpl] 做：同一题 + 同一切片哈希的
//   未完成任务（pending/running）已存在时直接返回它，不建重复行。
// - attempt_count 是实际发起请求的次数（首次算 1；最多 4 次）；
//   领任务时不加，真正发请求前由 worker 调 [markOcrJobAttemptIntoImpl] 加。
// - 时间统一 INTEGER 毫秒时间戳（项目既有约定）。

part of 'database.dart';

/// [OcrJob] → Drift 行（DbOcrJob → 模型类的反向在文件底部的
/// [_ocrJobFromDb]；status 存 OcrJobStatus 的枚举名）。
OcrJobsCompanion _ocrJobCompanion(OcrJob job) => OcrJobsCompanion.insert(
  id: job.id,
  questionId: job.questionId,
  cropPath: Value(job.cropPath),
  inputHash: Value(job.inputHash),
  status: Value(job.status.name),
  attemptCount: Value(job.attemptCount),
  availableAt: Value(job.availableAt?.millisecondsSinceEpoch),
  startedAt: Value(job.startedAt?.millisecondsSinceEpoch),
  leaseUntil: Value(job.leaseUntil?.millisecondsSinceEpoch),
  leaseToken: Value(job.leaseToken),
  lastErrorCode: Value(job.lastErrorCode),
  lastErrorMessage: Value(job.lastErrorMessage),
  createdAt: job.createdAt.millisecondsSinceEpoch,
  updatedAt: job.updatedAt.millisecondsSinceEpoch,
  completedAt: Value(job.completedAt?.millisecondsSinceEpoch),
);

OcrJob _ocrJobFromDb(DbOcrJob r) => OcrJob(
  id: r.id,
  questionId: r.questionId,
  cropPath: r.cropPath,
  inputHash: r.inputHash,
  status: OcrJobStatus.values.firstWhere(
    (s) => s.name == r.status,
    orElse: () => OcrJobStatus.pending,
  ),
  attemptCount: r.attemptCount,
  availableAt: r.availableAt == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(r.availableAt!),
  startedAt: r.startedAt == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(r.startedAt!),
  leaseUntil: r.leaseUntil == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(r.leaseUntil!),
  leaseToken: r.leaseToken,
  lastErrorCode: r.lastErrorCode,
  lastErrorMessage: r.lastErrorMessage,
  createdAt: DateTime.fromMillisecondsSinceEpoch(r.createdAt),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(r.updatedAt),
  completedAt: r.completedAt == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(r.completedAt!),
);

/// 入队（可单测版）：同一题 + 同一切片哈希的未完成任务已存在时返回它
/// （不建重复行；改框后切片变了、哈希不同时才建新行，旧行由 worker 在
/// 应用结果前用哈希比对丢弃）。[inputHash] 为 null 时不去重（无基线）。
/// 返回最终的任务行（新建或已存在的那条）。
Future<OcrJob> enqueueOcrJobIntoImpl(QuizDatabase db, OcrJob job) async {
  if (job.inputHash != null) {
    final existing =
        await (db.select(db.ocrJobs)..where(
              (t) =>
                  t.questionId.equals(job.questionId) &
                  t.inputHash.equals(job.inputHash!) &
                  t.status.isIn([
                    OcrJobStatus.pending.name,
                    OcrJobStatus.running.name,
                  ]),
            ))
            .getSingleOrNull();
    if (existing != null) return _ocrJobFromDb(existing);
  }
  await db.into(db.ocrJobs).insert(_ocrJobCompanion(job));
  return job;
}

/// 领任务（可单测版）：取最早创建的一条 `pending` 且退避已到期的任务，
/// 同一事务内改成 `running` 并写 started_at + lease_until（租约）+
/// lease_token（十三批 P1-1：claim 时生成唯一 token，见文件头）。
/// 没有可领的任务时返回 null。领走即持有租约——进程崩溃后该任务只在
/// 租约过期后才由 [reclaimExpiredLeasesIntoImpl] 回收。
Future<OcrJob?> claimNextOcrJobIntoImpl(
  QuizDatabase db, {
  required Duration leaseDuration,
  DateTime? now,
}) async {
  final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  return db.transaction(() async {
    final row =
        await (db.select(db.ocrJobs)..where(
              (t) =>
                  t.status.equals(OcrJobStatus.pending.name) &
                  (t.availableAt.isNull() |
                      t.availableAt.isSmallerOrEqualValue(nowMs)),
            )
            ..orderBy([(t) => OrderingTerm(expression: t.createdAt)])
            ..limit(1))
            .getSingleOrNull();
    if (row == null) return null;
    final leaseUntilMs = nowMs + leaseDuration.inMilliseconds;
    // 租约 token：唯一值（newEntityId 含毫秒时间戳 + 8 位安全随机），
    // 与 started_at/lease_until 同一事务写下；旧 worker 凭旧 token
    // 再写库时校验失败，不做任何写操作。
    final leaseToken = newEntityId('lease');
    await (db.update(db.ocrJobs)..where((t) => t.id.equals(row.id))).write(
      OcrJobsCompanion(
        status: Value(OcrJobStatus.running.name),
        startedAt: Value(nowMs),
        leaseUntil: Value(leaseUntilMs),
        leaseToken: Value(leaseToken),
        updatedAt: Value(nowMs),
      ),
    );
    return _ocrJobFromDb(row).copyWith(
      status: OcrJobStatus.running,
      startedAt: DateTime.fromMillisecondsSinceEpoch(nowMs),
      leaseUntil: DateTime.fromMillisecondsSinceEpoch(leaseUntilMs),
      leaseToken: leaseToken,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(nowMs),
    );
  });
}

/// 回收过期租约（可单测版）：`running` 且 lease_until 已过的任务回
/// `pending`（清 started_at/lease_until/lease_token，attempt_count 与
/// 错误信息保留，下次领走时续跑并领新 token）。
/// 应用启动时调一次；worker 运行中不调（在跑的任务租约未过期，不会
/// 被误回收）。返回回收的行数。
/// lease_until 为 null 的 running 行（理论上不存在：领任务必写租约）
/// 不回收——它不是“过期”，是数据异常，留给排障，不静默改状态。
Future<int> reclaimExpiredLeasesIntoImpl(QuizDatabase db, {DateTime? now}) async {
  final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  // Value<int?>(null) 是“写回 NULL”（与 Value.absent() 的“不动”不同，
  // Drift 里可空列就是这么清的，与 _questionCompanion 写可空列同口径）。
  return (db.update(db.ocrJobs)..where(
        (t) =>
            t.status.equals(OcrJobStatus.running.name) &
            t.leaseUntil.isNotNull() &
            t.leaseUntil.isSmallerOrEqualValue(nowMs),
      ))
      .write(
        OcrJobsCompanion(
          status: Value(OcrJobStatus.pending.name),
          startedAt: const Value<int?>(null),
          leaseUntil: const Value<int?>(null),
          leaseToken: const Value<String?>(null),
          updatedAt: Value(nowMs),
        ),
      );
}

/// 十三批 P1-1（GPT §3.3）：等 key 的任务立即变为可领取。
/// 把“因没 key 而等 10 分钟”的 pending 任务的 available_at 清掉
/// （last_error_code = api_key_missing 的行），不改状态、不清错误码
/// （下次领走时 worker 仍会先验 key；key 仍缺时再按 noKeyDelay 等）。
/// 返回清掉的行数。由 [OcrWorker.notifyApiKeySaved] 与 worker 启动时调。
Future<int> clearNoKeyOcrWaitIntoImpl(QuizDatabase db, {DateTime? now}) async {
  final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  return (db.update(db.ocrJobs)..where(
        (t) =>
            t.status.equals(OcrJobStatus.pending.name) &
            // 字面量 'api_key_missing' = OcrErrorCode.apiKeyMissing
            //（glm_ocr_client.dart；data 层不 import services 层，
            // 故此处用字面量，见 M3 错误码表——只增不改）。
            t.lastErrorCode.equals('api_key_missing'),
      ))
      .write(
        OcrJobsCompanion(
          availableAt: const Value<int?>(null),
          updatedAt: Value(nowMs),
        ),
      );
}

/// 保存新 API Key 后，把“因 key 无效而 failed”的任务重新放回 pending。
/// 只恢复 `failed + last_error_code = api_key_invalid`；completed /
/// cancelled / 其它失败的 failed 行不动。清掉租约、错误码与完成时间，
/// available_at 置空让 worker 立即领取；attempt_count 保留（诊断用）。
/// 返回恢复的行数。
Future<int> requeueApiKeyInvalidIntoImpl(
  QuizDatabase db, {
  DateTime? now,
}) async {
  final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  return (db.update(db.ocrJobs)..where(
        (t) =>
            t.status.equals(OcrJobStatus.failed.name) &
            // 字面量 'api_key_invalid' = OcrErrorCode.apiKeyInvalid
            //（与 clearNoKeyOcrWaitIntoImpl 同口径：data 层不 import
            // services 层，错误码表只增不改）。
            t.lastErrorCode.equals('api_key_invalid'),
      ))
      .write(
        OcrJobsCompanion(
          status: Value(OcrJobStatus.pending.name),
          availableAt: const Value<int?>(null),
          startedAt: const Value<int?>(null),
          leaseUntil: const Value<int?>(null),
          leaseToken: const Value<String?>(null),
          lastErrorCode: const Value<String?>(null),
          lastErrorMessage: const Value<String?>(null),
          completedAt: const Value<int?>(null),
          updatedAt: Value(nowMs),
        ),
      );
}

/// 发请求前记一次尝试（可单测版）：attempt_count +1。
/// 返回更新后的行；任务不存在时返回 null。
/// 十三批 P1-1：[leaseToken] 非空时校验当前持有者——与库里 lease_token
/// 不一致（任务已被回收重领）时不做任何写操作，返回 null。
Future<OcrJob?> markOcrJobAttemptIntoImpl(
  QuizDatabase db,
  String id, {
  DateTime? now,
  String? leaseToken,
}) async {
  final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  return db.transaction(() async {
    final row = await (db.select(
      db.ocrJobs,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return null;
    if (leaseToken != null && row.leaseToken != leaseToken) return null;
    await (db.update(db.ocrJobs)..where((t) => t.id.equals(id))).write(
      OcrJobsCompanion(
        attemptCount: Value(row.attemptCount + 1),
        updatedAt: Value(nowMs),
      ),
    );
    return _ocrJobFromDb(row).copyWith(
      attemptCount: row.attemptCount + 1,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(nowMs),
    );
  });
}

/// 可重试的失败（可单测版）：回 `pending`，available_at 写退避到期点，
/// 记最近一次错误码/信息，清 started_at/lease_until/lease_token
/// （租约已交还，下次领走时重写新 token）。attempt_count 不动
/// （已在发请求前记过）。
/// 十三批 P1-1：[leaseToken] 非空时校验持有者，不一致不写库、返回 null。
Future<OcrJob?> retryOcrJobIntoImpl(
  QuizDatabase db,
  String id, {
  required DateTime availableAt,
  required String errorCode,
  String? errorMessage,
  DateTime? now,
  String? leaseToken,
}) async {
  final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  return _updateJobRow(
    db,
    id,
    OcrJobsCompanion(
      status: Value(OcrJobStatus.pending.name),
      availableAt: Value(availableAt.millisecondsSinceEpoch),
      startedAt: const Value<int?>(null),
      leaseUntil: const Value<int?>(null),
      leaseToken: const Value<String?>(null),
      lastErrorCode: Value(errorCode),
      lastErrorMessage: Value(errorMessage),
      updatedAt: Value(nowMs),
    ),
    leaseToken: leaseToken,
  );
}

/// 终态失败（可单测版）：`failed` + completed_at，记错误码/信息，
/// 清 started_at/lease_until/lease_token。
/// 不可重试的错误（key 无效、图片损坏、参数错误、文件不存在）与
/// 应用结果前的丢弃（hash 不一致、题目已删、内容版本已变）都走这里。
/// 十三批 P1-1：[leaseToken] 非空时校验持有者，不一致不写库、返回 null。
Future<OcrJob?> failOcrJobIntoImpl(
  QuizDatabase db,
  String id, {
  required String errorCode,
  String? errorMessage,
  DateTime? now,
  String? leaseToken,
}) async {
  final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  return _updateJobRow(
    db,
    id,
    OcrJobsCompanion(
      status: Value(OcrJobStatus.failed.name),
      startedAt: const Value<int?>(null),
      leaseUntil: const Value<int?>(null),
      leaseToken: const Value<String?>(null),
      lastErrorCode: Value(errorCode),
      lastErrorMessage: Value(errorMessage),
      completedAt: Value(nowMs),
      updatedAt: Value(nowMs),
    ),
    leaseToken: leaseToken,
  );
}

/// 终态完成（可单测版）：`completed` + completed_at，
/// 清 started_at/lease_until/lease_token。
/// 注意：应用结果前丢弃（hash 不一致等）不走这里，走 [failOcrJobIntoImpl]
///（带丢弃原因码，见 ocr_queue.dart）；这里只表示“OCR 结果已处理完”。
/// 十三批 P1-1：[leaseToken] 非空时校验持有者，不一致不写库、返回 null。
Future<OcrJob?> completeOcrJobIntoImpl(
  QuizDatabase db,
  String id, {
  DateTime? now,
  String? leaseToken,
}) async {
  final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  return _updateJobRow(
    db,
    id,
    OcrJobsCompanion(
      status: Value(OcrJobStatus.completed.name),
      startedAt: const Value<int?>(null),
      leaseUntil: const Value<int?>(null),
      leaseToken: const Value<String?>(null),
      completedAt: Value(nowMs),
      updatedAt: Value(nowMs),
    ),
    leaseToken: leaseToken,
  );
}

/// Win11 反馈包 2：取消识别（可单测版）：该题全部未取消的任务行标
/// `cancelled`（终态）+ completed_at，清 started_at/lease_until/
/// lease_token（租约已交还——在途 worker 凭旧 token 再写库时校验失败，
/// 迟到结果进不了库；过期租约回收只认 running，已取消的行不会被复活）。
/// pending / running / completed / failed 都标——completed 行不标的话，
/// 状态推导会把已取消的题仍判成“识别完成”。lastErrorCode 不动
/// （取消不是失败，诊断只看状态）。
/// 返回标掉的行数。调用方（OcrWorker.cancelOcrForQuestion）在同一
/// 事务内接着清题目 OCR 字段；本函数本身不包事务，以便合进那笔事务。
Future<int> cancelOcrJobsForQuestionIntoImpl(
  QuizDatabase db,
  String questionId, {
  DateTime? now,
}) async {
  final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  return (db.update(db.ocrJobs)..where(
        (t) =>
            t.questionId.equals(questionId) &
            t.status.isIn([
              OcrJobStatus.pending.name,
              OcrJobStatus.running.name,
              OcrJobStatus.completed.name,
              OcrJobStatus.failed.name,
            ]),
      ))
      .write(
        OcrJobsCompanion(
          status: Value(OcrJobStatus.cancelled.name),
          startedAt: const Value<int?>(null),
          leaseUntil: const Value<int?>(null),
          leaseToken: const Value<String?>(null),
          completedAt: Value(nowMs),
          updatedAt: Value(nowMs),
        ),
      );
}

/// 按 id 读一条任务（可单测版），不存在返回 null。
Future<OcrJob?> ocrJobByIdIntoImpl(QuizDatabase db, String id) async {
  final row = await (db.select(
    db.ocrJobs,
  )..where((t) => t.id.equals(id))).getSingleOrNull();
  return row == null ? null : _ocrJobFromDb(row);
}

/// 按题读任务（可单测版）：最新在前（M5 看某题的识别状态用）。
Future<List<OcrJob>> ocrJobsForQuestionIntoImpl(
  QuizDatabase db,
  String questionId,
) async {
  final rows =
      await (db.select(db.ocrJobs)..where(
            (t) => t.questionId.equals(questionId),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
          .get();
  return rows.map(_ocrJobFromDb).toList();
}

/// 通用行更新：按 id 写 companion，返回更新后的行（不存在返回 null）。
/// 调用方只传要改的列（Value.absent() = 不动）；要把某列写回 NULL 时
/// 传 `Value<int?>(null)` / `Value<String?>(null)`（不是 absent）。
/// 十三批 P1-1：[leaseToken] 非空时在 WHERE 里再加
/// `lease_token = ?`——持有者不一致时更新行数为 0，不做任何写操作，
/// 返回 null（调用方据此判定“租约已丢”，不得当作写成功）。
Future<OcrJob?> _updateJobRow(
  QuizDatabase db,
  String id,
  OcrJobsCompanion companion, {
  String? leaseToken,
}) async {
  final updated = await (db.update(
    db.ocrJobs,
  )..where(
        (t) => leaseToken == null
            ? t.id.equals(id)
            : t.id.equals(id) & t.leaseToken.equals(leaseToken),
      ))
      .write(companion);
  if (updated == 0) return null;
  final row = await (db.select(
    db.ocrJobs,
  )..where((t) => t.id.equals(id))).getSingleOrNull();
  return row == null ? null : _ocrJobFromDb(row);
}

extension AppDatabaseOcrJobs on AppDatabase {
  /// 入队（实例版）：同一题 + 同一切片哈希的未完成任务已存在时返回它。
  Future<OcrJob> enqueueOcrJob(OcrJob job) async =>
      enqueueOcrJobIntoImpl(await db, job);

  /// 领任务（实例版）：最早创建的一条可跑 pending 任务改 running + 写租约。
  Future<OcrJob?> claimNextOcrJob({
    required Duration leaseDuration,
    DateTime? now,
  }) async => claimNextOcrJobIntoImpl(await db, leaseDuration: leaseDuration, now: now);

  /// 回收过期租约（实例版）：running 且租约已过 → pending。返回行数。
  Future<int> reclaimExpiredLeases({DateTime? now}) async =>
      reclaimExpiredLeasesIntoImpl(await db, now: now);

  /// 等 key 的任务立即变为可领取（实例版）：清掉没 key 等待的
  /// available_at。返回清掉的行数。
  Future<int> clearNoKeyOcrWait({DateTime? now}) async =>
      clearNoKeyOcrWaitIntoImpl(await db, now: now);

  /// 保存新 key 后，把因 key 无效而 failed 的任务重新放回 pending。
  Future<int> requeueApiKeyInvalid({DateTime? now}) async =>
      requeueApiKeyInvalidIntoImpl(await db, now: now);

  /// 发请求前记一次尝试（实例版）：attempt_count +1。
  /// [leaseToken] 非空时校验持有者，不一致返回 null（不写库）。
  Future<OcrJob?> markOcrJobAttempt(
    String id, {
    DateTime? now,
    String? leaseToken,
  }) async => markOcrJobAttemptIntoImpl(
    await db,
    id,
    now: now,
    leaseToken: leaseToken,
  );

  /// 可重试的失败（实例版）：回 pending + 退避到期点 + 记错误。
  /// [leaseToken] 非空时校验持有者，不一致返回 null（不写库）。
  Future<OcrJob?> retryOcrJob(
    String id, {
    required DateTime availableAt,
    required String errorCode,
    String? errorMessage,
    DateTime? now,
    String? leaseToken,
  }) async => retryOcrJobIntoImpl(
    await db,
    id,
    availableAt: availableAt,
    errorCode: errorCode,
    errorMessage: errorMessage,
    now: now,
    leaseToken: leaseToken,
  );

  /// 终态失败（实例版）。
  /// [leaseToken] 非空时校验持有者，不一致返回 null（不写库）。
  Future<OcrJob?> failOcrJob(
    String id, {
    required String errorCode,
    String? errorMessage,
    DateTime? now,
    String? leaseToken,
  }) async => failOcrJobIntoImpl(
    await db,
    id,
    errorCode: errorCode,
    errorMessage: errorMessage,
    now: now,
    leaseToken: leaseToken,
  );

  /// 终态完成（实例版）。
  /// [leaseToken] 非空时校验持有者，不一致返回 null（不写库）。
  Future<OcrJob?> completeOcrJob(
    String id, {
    DateTime? now,
    String? leaseToken,
  }) async => completeOcrJobIntoImpl(
    await db,
    id,
    now: now,
    leaseToken: leaseToken,
  );

  /// 取消识别（实例版）：该题全部未取消的任务行标 cancelled。返回行数。
  Future<int> cancelOcrJobsForQuestion(
    String questionId, {
    DateTime? now,
  }) async => cancelOcrJobsForQuestionIntoImpl(await db, questionId, now: now);

  /// 按 id 读一条任务。
  Future<OcrJob?> ocrJobById(String id) async =>
      ocrJobByIdIntoImpl(await db, id);

  /// 按题读任务（最新在前）。
  Future<List<OcrJob>> ocrJobsForQuestion(String questionId) async =>
      ocrJobsForQuestionIntoImpl(await db, questionId);
}
