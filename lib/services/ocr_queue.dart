// 十三批 M3：OCR 后台队列 worker。
//
// 单 worker 顺序处理，并发 1，异步，绝不阻塞 UI 线程（Dart 异步网络请求，
// 不引入 Isolate；GPT 评审 §2.3）。持久化队列表 ocr_jobs（见
// lib/data/db_ocr_jobs.dart）；应用启动时 [OcrWorker.ensureStarted]
// 启动 worker 并回收过期租约。
//
// 处理流程（一道题）：领任务 → 读题（记 content_version）→ 有 key 才发
// 请求（无 key 只排队）→ 请求前记 attempt → 调 GLM-OCR → 应用结果前
// 必查三项（hash 一致 / 题目仍存在 / content_version 与领取时一致）→
// 写回题目 + 任务 completed/failed + 发 DataChangeBus 事件。
//
// content_version 递增规则（M3 定稿，M2 建议的落地；M5 的纠错保存
// 也必须遵守，否则 worker 的“领取后内容是否变过”校验失效）：
// - 每次 OCR 自动应用 +1：安全应用、候选只写 raw、LaTeX 不平衡只写 raw，
//   三种写回都 +1（只要 ocr_raw 变了，内容版本就变）。
// - 每次人工编辑保存 +1：M5 纠错编辑器保存 ocr_stem（或改 ocr_raw 的
//   候选标记）时 contentVersion +1。
// - 其他保存（整理、详情改答案/文件夹等）不碰 content_version——它只
//   跟踪 OCR 内容，不跟踪题目全部字段。
//
// 候选结果的存放与判定（v4 schema 已够用，不加 v5 迁移；
// 十三批 P1-1：候选包带来源身份，见 [GlmOcrRawData]）:
// - ocr_raw 恒写最新原始结果（[GlmOcrRawData] JSON 包，含 md_results 与
//   layout_details）；ocr_stem 只在安全时写。包里有 input_hash /
//   claimed_content_version / candidate_status / created_at：
//   候选来自哪个任务、哪张切片、领取时哪个版本，一看便知；
//   hash 不一致的候选标 stale，绝不能作为可接受候选展示。
// - 用户手动改过（ocr_manual_edited=1）时，新结果只作候选：worker 把
//   raw 包写成 candidate_status=pending 再写 ocr_raw，ocr_stem
//   与 ocr_split_status 原样不动；contentVersion 仍 +1（raw 变了）。
// - M5 判定“有新的识别结果”：[hasPendingOcrCandidate]（只读 raw 包的
//   candidate_status == pending，不比较文本、不依赖时间戳）；预览候选
//   题干用 [pendingCandidateStem]（对 raw 里的 md_results 再跑 splitStem）。
// - 接受候选必须重验证（见 stem_correction.dart 的 acceptCandidateStem，
//   P1-1）：题目仍存在、input_hash 与当前切片一致、候选仍 pending；
//   任一不符拒绝接受并给出明确原因；hash 不一致时候选标 stale。
// - M5 在用户保存一次手动编辑、或接受/忽略候选后，须用
//   [clearOcrCandidateFlag] 把 raw 包里的候选状态清掉再保存（否则下次
//   还会提示同一份候选）；清状态不改 md_results，原始结果不丢。
// - LaTeX 不平衡的原图回退：raw 照写（状态 none）、ocr_stem 不动
//   （没有可用题干时 M5 按“ocr_raw 有、ocr_stem 空”走原图回退，
//   不是候选——[hasPendingOcrCandidate] 为 false）。
//
// 自动应用的原子性（十三批 P1-1，GPT §2.4）：状态核验 + 版本比较 +
// 条件写入在同一个 Drift 事务里（[applyClaimedResult]）；安全应用
// 用 `WHERE question_id = ? AND content_version = ? AND
// ocr_manual_edited = 0` 的条件更新并检查实际更新行数，不是 1 行
// 就不能算自动应用成功（走丢弃码，不静默成功）。
//
// 租约 token（十三批 P1-1，GPT §2.4）：claim 时生成唯一 token 存
// ocr_jobs.lease_token；complete / fail / retry / markAttempt 时
// 校验 token 与当前持有者一致，不一致不做任何写操作（任务已被回收
// 重领）。

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../data/data_change_events.dart';
import '../data/database.dart';
import '../data/drift/quiz_database.dart';
import '../models/models.dart';
import 'glm_ocr_client.dart';
import 'import_guess.dart';
import 'ocr_key_store.dart';
import 'stem_splitter.dart';

/// 租约时长：worker 领走任务后 5 分钟内须完成；超时未完成视为旧 worker
/// 已死，启动时（或下次领任务前）回收（GPT 评审 §2.6 的租约机制，
/// 不是固定的“卡 10 分钟再恢复”）。
const Duration ocrLeaseDuration = Duration(minutes: 5);

/// 最多总请求次数：首次 + 3 次重试（GPT 评审 §2.4/§2.5）。
const int ocrMaxAttempts = 4;

/// 退避基数与上限：指数退避 30 秒 → 60 秒 → 120 秒，上限 5 分钟
/// （GPT 评审 §2.4：最大间隔 5 分钟）。429 的 Retry-After 优先，
/// 但同样封顶 5 分钟（服务端让等更久时，5 分钟后重试大概率仍是 429，
/// 再按新的 Retry-After 退避，不会丢任务）。
const Duration ocrBackoffBase = Duration(seconds: 30);
const Duration ocrMaxBackoff = Duration(minutes: 5);

/// 无 key 时任务的下次可跑时间：保持 pending，available_at 置
/// now + 10 分钟（不写 failed、不空转轮询；用户填好 key 后下次领走时
/// 自然跑起来——worker 每轮都会领到期的任务，不用等满 10 分钟也能
/// 被 [OcrWorker.kick] 唤醒后提前检查，但 available_at 未到仍跳过）。
const Duration ocrNoKeyDelay = Duration(minutes: 10);

/// worker 空闲轮询间隔：无可领任务时歇 5 秒再看（整理流程绝不被 OCR
/// 卡住；入队后最迟 5 秒内开跑，[OcrWorker.kick] 可立即唤醒）。
const Duration ocrPollInterval = Duration(seconds: 5);

/// OCR 后台队列 worker：单例 + 单 worker 顺序处理（并发 1）。
///
/// 单测直接 `OcrWorker(database: ..., recognizer: 假实现)` 构造新实例，
/// 不走单例；[processOne] 是单步处理入口（不启循环），[start]/[stop]
/// 只在生产启动路径与启停测试里用。
class OcrWorker {
  OcrWorker({
    required this.database,
    OcrKeyStore? keyStore,
    OcrRecognizer? recognizer,
    this.leaseDuration = ocrLeaseDuration,
    this.pollInterval = ocrPollInterval,
    this.noKeyDelay = ocrNoKeyDelay,
    DateTime Function()? clock,
  }) : _keyStore = keyStore ?? OcrKeyStore(),
       _recognizer = recognizer ?? GlmOcrClient(),
       _clock = clock ?? DateTime.now;

  final AppDatabase database;
  final OcrKeyStore _keyStore;
  final OcrRecognizer _recognizer;
  final Duration leaseDuration;
  final Duration pollInterval;
  final Duration noKeyDelay;
  final DateTime Function() _clock;

  DateTime _now() => _clock();

  static OcrWorker? _instance;

  /// 应用启动入口：建默认单例（未建过才建）并启动；已启动时直接返回。
  /// 启动失败（租约回收读库失败等）不抛——OCR 是锦上添花，绝不能拖垮
  /// 启动；失败时 worker 保持未启动，下次入队/手动重试时再拉起。
  static Future<OcrWorker> ensureStarted({AppDatabase? database}) async {
    final worker =
        _instance ??= OcrWorker(database: database ?? AppDatabase.instance);
    await worker.start();
    return worker;
  }

  /// 已启动的单例（未启动时为 null；入队点用它，worker 没起来也不报错）。
  static OcrWorker? get instanceOrNull => _instance;

  /// 测试用：清掉单例（生产不调）。
  static void resetInstanceForTest() {
    _instance = null;
  }

  bool _running = false;
  Future<void>? _loopFuture;

  bool get isRunning => _running;

  /// 启动 worker（幂等）：先回收过期租约，再起后台循环。
  /// 循环内任何一步抛错都只歇一轮再继续，不让 worker 静默死掉。
  /// 十三批 P1-1（GPT §3.3）：启动时清掉“等 key”的等待——key 已补上
  /// 时任务立即变为可领取，不用等满 10 分钟；key 仍缺时，worker 在
  /// 下一轮 processOne 里仍会按 noKeyDelay 等，不会空转。
  Future<void> start() async {
    if (_running) return;
    _running = true;
    try {
      await database.reclaimExpiredLeases(now: _now());
    } catch (_) {
      // 回收失败不阻启动：过期任务下次领任务前仍是 running 占着，
      // 最多一轮空转；下次启动再回收。
    }
    try {
      await database.clearNoKeyOcrWait(now: _now());
    } catch (_) {
      // 清等待失败不阻启动：等 key 的任务最多再等一轮退避。
    }
    _loopFuture = _runLoop();
  }

  /// 停 worker：等当前在跑的一步走完（不中断正在进行的识别请求）。
  Future<void> stop() async {
    _running = false;
    try {
      await _loopFuture;
    } catch (_) {}
    _loopFuture = null;
  }

  /// 唤醒循环：下次轮询不等满 [pollInterval]（入队后调；循环在
  /// `Future.delayed` 里等时由 [_wakeUp] 提前结束等待）。
  void kick() {
    final wakeUp = _wakeUp;
    if (wakeUp != null && !wakeUp.isCompleted) wakeUp.complete();
  }

  /// 保存 key 后调（十三批 P1-1，GPT §3.3）：先把“等 key”的任务的
  /// available_at 清掉（立即变为可领取，不用等满 10 分钟），再唤醒
  /// 循环。只清 last_error_code = api_key_missing 的 pending 行，
  /// 不碰其他退避中的任务。失败静默（下次轮询仍会领到期的任务）。
  Future<void> notifyApiKeySaved() async {
    try {
      await database.clearNoKeyOcrWait(now: _now());
    } catch (_) {}
    kick();
  }

  Completer<void>? _wakeUp;

  Future<void> _runLoop() async {
    while (_running) {
      bool didWork = false;
      try {
        didWork = await processOne();
      } catch (_) {
        // processOne 内部已兜底；这里只防万一，歇一轮再继续。
        didWork = false;
      }
      if (!_running) break;
      if (didWork) continue;
      final wakeUp = _wakeUp = Completer<void>();
      await Future.any([
        Future.delayed(pollInterval),
        wakeUp.future,
      ]);
      _wakeUp = null;
    }
  }

  /// 入队点（确认分框后调）：给一道已确认的题建一条 OCR 任务。
  /// - crop_path 用题的 slice_path（imports//slices/ 相对路径，M2 口径）；
  /// - input_hash 是磁盘切片文件的 SHA-256（白边在发送时才加，不参与哈希）；
  /// - 同一题 + 同一哈希的未完成任务已存在时不建重复行（返回已存在那条）；
  /// - 切片路径为空或文件不存在时不建任务（返回 null；没切片可识别，
  ///   不是队列的错——调用方不因此报错）。
  /// 返回新建/已存在的任务，null 表示没建。
  /// 失败（读盘/写库）时抛错，不静默吞掉——调用方须按
  /// stem_correction.dart 的 enqueueOcrForQuestion 契约处理。
  Future<OcrJob?> enqueueForQuestion(Question question) async {
    final cropPath = question.slicePath;
    if (cropPath == null || cropPath.isEmpty) return null;
    final absPath = AppDatabase.resolveDataPath(cropPath);
    if (absPath == null) return null;
    final file = File(absPath);
    if (!await file.exists()) return null;
    final hash = await sha256HexOfFile(file);
    final now = _now();
    final job = OcrJob(
      id: newEntityId('ocr'),
      questionId: question.id,
      cropPath: cropPath,
      inputHash: hash,
      createdAt: now,
      updatedAt: now,
    );
    return database.enqueueOcrJob(job);
  }

  /// 批量入队（确认分框一次产多道题时调）：逐道入队，某道失败不拦其余。
  Future<List<OcrJob>> enqueueForQuestions(List<Question> questions) async {
    final jobs = <OcrJob>[];
    for (final q in questions) {
      try {
        final job = await enqueueForQuestion(q);
        if (job != null) jobs.add(job);
      } catch (_) {
        // 单道入队失败（读盘/写库）不拦整批，其余题继续排队。
      }
    }
    return jobs;
  }

  /// 单步处理：领一条可跑任务并走完它。返回 true = 处理了一条任务
  /// （无论成功/失败/丢弃），false = 无可领任务。
  /// 内部兜底一切异常：绝不向循环外抛错。
  Future<bool> processOne() async {
    OcrJob? job;
    try {
      job = await database.claimNextOcrJob(
        leaseDuration: leaseDuration,
        now: _now(),
      );
    } catch (_) {
      return false;
    }
    if (job == null) return false;
    try {
      await _processClaimed(job);
    } catch (e) {
      // 未预期异常：按 internal 码重试（上限 4 次），不让 worker 死掉。
      await _handleFailure(job, OcrException(
        OcrErrorCode.internalError,
        '识别处理异常，请重试',
      ));
    }
    return true;
  }

  /// 领走后的处理（job 已是 running + 已写租约）。
  Future<void> _processClaimed(OcrJob job) async {
    final now = _now();
    final question = await database.questionById(job.questionId);
    if (question == null) {
      await _fail(
        job,
        OcrErrorCode.questionDeleted,
        '题目已被删除，识别结果不再应用',
      );
      return;
    }
    // 领取时记下内容版本：应用结果前比对，变了就丢弃（GPT §2.7 三项之一）。
    final claimedVersion = question.contentVersion;

    // 没 key 只排队不发请求：回 pending + 10 分钟后再看，不记 attempt、
    // 不写 failed（M2 §3 约定 5）。
    if (!await _hasKey()) {
      await database.retryOcrJob(
        job.id,
        availableAt: now.add(noKeyDelay),
        errorCode: OcrErrorCode.apiKeyMissing,
        errorMessage: '未设置 BigModel API Key，等待用户在设置里填写',
        now: now,
        leaseToken: job.leaseToken,
      );
      _emit(job.questionId);
      return;
    }

    // 请求前先验一次哈希：切片已换（改框/重导）就不用浪费一次 API 调用。
    // 十三批 P1-1：以题目当前 slice_path 为准——重框写新版本文件后，
    // 旧任务的 crop_path 即使字节未变也已过期（不可变切片：旧文件
    // 永不覆盖，路径变了就是换了）。真正的校验在应用结果时再做一次
    //（请求期间切片也可能变）。
    if (question.slicePath == null || question.slicePath != job.cropPath) {
      await _fail(
        job,
        OcrErrorCode.hashMismatch,
        '切片已更换，旧识别任务不再应用（请重新识别）',
      );
      return;
    }
    final cropFile = _resolveCropFile(job);
    if (cropFile == null) {
      await _fail(job, OcrErrorCode.fileMissing, '切片文件不存在，请重新导入或恢复图片');
      return;
    }
    final preHash = await _hashOf(cropFile);
    if (preHash == null) {
      await _fail(job, OcrErrorCode.fileMissing, '切片文件读不到，请重新导入或恢复图片');
      return;
    }
    if (job.inputHash != null && preHash != job.inputHash) {
      await _fail(
        job,
        OcrErrorCode.hashMismatch,
        '切片已更换，旧识别任务不再应用（请重新识别）',
      );
      return;
    }

    // 发请求：先记 attempt（实际发起次数；首次算 1）。
    // 十三批 P1-1：带租约 token 记——返回 null 说明租约已丢（任务被
    // 回收重领），旧 worker 不再发请求、不再碰这条任务。
    final marked = await database.markOcrJobAttempt(
      job.id,
      now: now,
      leaseToken: job.leaseToken,
    );
    if (marked == null) return;
    final attemptCount = job.attemptCount + 1;
    final GlmOcrResult result;
    try {
      result = await _recognizer.recognize(cropFile);
    } on OcrException catch (e) {
      await _handleFailure(job, e, attemptCount: attemptCount);
      return;
    }
    await _applyResult(job, claimedVersion, result);
  }

  /// 可重试失败 → 回 pending + 退避；不可重试或次数用完 → failed。
  /// 429 优先尊重 Retry-After（封顶 5 分钟）；其余按指数退避。
  /// 十三批 P1-1：全部写库都带 job 的租约 token——校验不一致时
  /// retry/fail 返回 null，不做任何写操作（任务已被回收重领）。
  Future<void> _handleFailure(
    OcrJob job,
    OcrException e, {
    int? attemptCount,
  }) async {
    final attempts = attemptCount ?? job.attemptCount;
    if (e.code == OcrErrorCode.apiKeyMissing) {
      // 请求中途 key 被清掉：按“没 key 只排队”处理，不记失败。
      await database.retryOcrJob(
        job.id,
        availableAt: _now().add(noKeyDelay),
        errorCode: OcrErrorCode.apiKeyMissing,
        errorMessage: '未设置 BigModel API Key，等待用户在设置里填写',
        now: _now(),
        leaseToken: job.leaseToken,
      );
    } else if (e.retryable && attempts < ocrMaxAttempts) {
      final delay = _backoffDelay(attempts, e);
      await database.retryOcrJob(
        job.id,
        availableAt: _now().add(delay),
        errorCode: e.code,
        errorMessage: e.message,
        now: _now(),
        leaseToken: job.leaseToken,
      );
    } else {
      await _failWithoutEmit(job, e.code, e.message);
    }
    // 写后发（D-94 模式）：写库成功才发事件。
    _emit(job.questionId);
  }

  Future<void> _fail(OcrJob job, String code, String message) async {
    await _failWithoutEmit(job, code, message);
    _emit(job.questionId);
  }

  Future<void> _failWithoutEmit(OcrJob job, String code, String message) async {
    await database.failOcrJob(
      job.id,
      errorCode: code,
      errorMessage: message,
      now: _now(),
      leaseToken: job.leaseToken,
    );
  }

  /// 应用结果（薄壳）：走 [applyClaimedResult] 的事务内原子应用，
  /// 写了库才发事件（D-94 模式）。
  Future<void> _applyResult(
    OcrJob job,
    int claimedVersion,
    GlmOcrResult result,
  ) async {
    final wrote = await applyClaimedResult(job, claimedVersion, result);
    if (wrote) _emit(job.questionId);
  }

  /// 事务内按租约 token 写任务失败（[failOcrJobIntoImpl] 的薄壳）。
  /// 返回 true = 写上了（持有者仍是本 worker），false = 租约已丢
  /// （任务已被回收重领，什么都没写）。
  Future<bool> _failJobInTxn(
    QuizDatabase db,
    OcrJob job,
    String code,
    String message,
    DateTime now,
  ) async {
    final updated = await failOcrJobIntoImpl(
      db,
      job.id,
      errorCode: code,
      errorMessage: message,
      now: now,
      leaseToken: job.leaseToken,
    );
    return updated != null;
  }

  /// 应用一次识别结果（十三批 P1-1，GPT §2.4；单测入口）。
  ///
  /// “重读题目 → 验 hash → 版本比较 → 条件写入 → 任务完成”全在
  /// 同一个 Drift 事务里；检查与写入之间没有 await 敞口——事务内
  /// 重读到的版本就是写入时比较的版本，用户在识别期间的编辑不可能
  /// 被旧检查结果覆盖。
  ///
  /// 应用前必查三项，任一不符不自动覆盖（进 failed 带丢弃码）：
  /// 1. 切片仍是任务那张：题目行 slice_path 与任务 crop_path 一致，
  ///   且文件 hash 与 input_hash 一致（请求前已验过一次，应用时再验；
  ///   重框写新版本文件后路径即变，旧任务直接丢弃）；
  /// 2. 题目仍存在；3. content_version 与领取时一致（未人工改过时）。
  ///
  /// 通过后按三档写回（见文件头“候选结果”节）：
  /// - 安全（LaTeX 平衡、未人工改过、版本与领取时一致）：ocr_raw +
  ///   ocr_stem + ocr_split_status 全写，条件更新
  ///   `WHERE id = ? AND content_version = ? AND ocr_manual_edited = 0`，
  ///   实际更新行数不是 1 行就不能算自动应用成功（走 content_changed
  ///   丢弃，不静默成功）；
  /// - 人工改过：只写 ocr_raw（候选 status pending，带 input_hash 与
  ///   claimed_content_version），stem 不动；content_version 不一致
  ///   时（用户只改了题干、切片没变）候选仍可保留给用户比较；
  /// - LaTeX 不平衡：只写 ocr_raw（状态 none），stem 不动，走原图回退。
  /// 三档都 contentVersion +1（`content_version = content_version + 1`
  /// 在 SQL 里算，不读旧值加）。
  ///
  /// hash 不一致时：题目上如有 pending 候选且它的 input_hash 也不等于
  /// 当前 hash，标 stale（同一事务里写）；迟到结果本身不写 ocr_raw。
  ///
  /// 任务完成也要校验租约 token：complete 返回 null（任务已被回收
  /// 重领）时抛 [_LeaseLostException] 回滚整笔写回。
  ///
  /// 返回 true = 提交了一笔写回（应用或丢弃），false = 租约已丢、
  /// 整笔已回滚、什么都没写。
  @visibleForTesting
  Future<bool> applyClaimedResult(
    OcrJob job,
    int claimedVersion,
    GlmOcrResult result,
  ) async {
    final now = _now();
    final d = await database.db;
    var wrote = false;
    GlmOcrRawData withProvenance(GlmOcrRawData raw) =>
        raw.withProvenance(
          inputHash: job.inputHash,
          claimedContentVersion: claimedVersion,
        );
    try {
      await d.transaction(() async {
        final row = await (d.select(
          d.questions,
        )..where((t) => t.id.equals(job.questionId))).getSingleOrNull();
        if (row == null) {
          wrote = await _failJobInTxn(
            d,
            job,
            OcrErrorCode.questionDeleted,
            '题目已被删除，识别结果不再应用',
            now,
          );
          return;
        }
        // 把题目上已有的 pending 候选标 stale（同一事务里写）：
        // 只当能算出当前 hash、且候选的 input_hash 与之不同时标——
        // content_version 不一致时不同（只改题干、切片没变时候选仍可
        // 保留给用户比较）；新切片的候选（input_hash 等于当前 hash）
        // 更不能误标。
        Future<void> markStaleIfNeeded(String currentHash) async {
          final raw = GlmOcrRawData.tryParse(row.ocrRaw);
          if (raw != null &&
              raw.candidateStatus == OcrCandidateStatus.pending &&
              raw.inputHash != currentHash) {
            final staleJson = raw
                .withCandidateStatus(OcrCandidateStatus.stale)
                .toJsonString();
            final marked = await d.customUpdate(
              'UPDATE questions SET ocr_raw = ?, content_version = content_version + 1 WHERE id = ?',
              variables: [
                Variable<String>(staleJson),
                Variable<String>(job.questionId),
              ],
              updates: {d.questions},
            );
            if (marked == 1) wrote = true;
          }
        }
        // 切片核验以题目行 slice_path 为准（十三批 P1-1 不可变切片）：
        // 重框写了新版本文件后，旧任务的 crop_path 即使字节未变也已
        // 过期——路径变了就是换了，迟到结果丢弃，不写 ocr_raw。
        final sliceChanged =
            row.slicePath == null || row.slicePath != job.cropPath;
        final cropFile = _resolveCropFileForPath(
          row.slicePath ?? job.cropPath,
        );
        final currentHash = cropFile == null ? null : await _hashOf(cropFile);
        if (sliceChanged) {
          if (currentHash != null) await markStaleIfNeeded(currentHash);
          wrote =
              await _failJobInTxn(
                d,
                job,
                OcrErrorCode.hashMismatch,
                '切片已更换，旧识别结果不再应用（请重新识别）',
                now,
              ) ||
              wrote;
          return;
        }
        if (currentHash == null) {
          wrote = await _failJobInTxn(
            d,
            job,
            OcrErrorCode.fileMissing,
            '切片文件不存在，请重新导入或恢复图片',
            now,
          );
          return;
        }
        if (job.inputHash != null && currentHash != job.inputHash) {
          // 同路径但字节变了（旧版原地覆盖的遗留情形）：迟到结果不写
          // ocr_raw；题目上已有的 pending 候选如也来自旧切片，标 stale。
          await markStaleIfNeeded(currentHash);
          wrote =
              await _failJobInTxn(
                d,
                job,
                OcrErrorCode.hashMismatch,
                '切片已更换，旧识别结果不再应用（请重新识别）',
                now,
              ) ||
              wrote;
          return;
        }
        // 版本比较（GPT §2.3 的表）：未人工改过、版本与领取时不一致 →
        // 丢弃；人工改过时版本不一致不丢弃（走候选档，stem 不动）。
        final manualEdited = row.ocrManualEdited == 1;
        if (!manualEdited && row.contentVersion != claimedVersion) {
          wrote = await _failJobInTxn(
            d,
            job,
            OcrErrorCode.contentChanged,
            '题目内容在识别期间被改过，识别结果不再自动覆盖',
            now,
          );
          return;
        }
        final markdown = result.markdown;
        if (!hasBalancedLatex(markdown)) {
          // LaTeX 不平衡：只存 raw（状态 none，供以后重处理），stem 不写。
          final rawJson = withProvenance(
            result.rawData.withoutCandidate(),
          ).toJsonString();
          final rows = await d.customUpdate(
            'UPDATE questions SET ocr_raw = ?, content_version = content_version + 1 WHERE id = ?',
            variables: [Variable<String>(rawJson), Variable<String>(job.questionId)],
            updates: {d.questions},
          );
          if (rows != 1) {
            wrote = await _failJobInTxn(
              d,
              job,
              OcrErrorCode.questionDeleted,
              '题目已被删除，识别结果不再应用',
              now,
            );
            return;
          }
        } else if (manualEdited) {
          // 人工改过：新结果只作候选，不自动覆盖。
          final rawJson = withProvenance(
            result.rawData.withCandidate(
              jobId: job.id,
              completedAtMs: now.millisecondsSinceEpoch,
            ),
          ).toJsonString();
          final rows = await d.customUpdate(
            'UPDATE questions SET ocr_raw = ?, content_version = content_version + 1 WHERE id = ? AND ocr_manual_edited = 1',
            variables: [Variable<String>(rawJson), Variable<String>(job.questionId)],
            updates: {d.questions},
          );
          if (rows != 1) {
            wrote = await _failJobInTxn(
              d,
              job,
              OcrErrorCode.contentChanged,
              '题目内容在识别期间被改过，识别结果不再自动覆盖',
              now,
            );
            return;
          }
        } else {
          final split = splitStem(markdown);
          final rawJson = withProvenance(
            result.rawData.withoutCandidate(),
          ).toJsonString();
          // 条件更新：题目 + 领取时版本 + 未人工改过三者同时满足才写；
          // 行数不是 1 就不能算自动应用成功。
          final rows = await d.customUpdate(
            'UPDATE questions SET ocr_raw = ?, ocr_stem = ?, ocr_split_status = ?, content_version = ? WHERE id = ? AND content_version = ? AND ocr_manual_edited = 0',
            variables: [
              Variable<String>(rawJson),
              Variable<String>(split.stemText),
              Variable<String>(split.status.label),
              Variable<int>(claimedVersion + 1),
              Variable<String>(job.questionId),
              Variable<int>(claimedVersion),
            ],
            updates: {d.questions},
          );
          if (rows != 1) {
            wrote = await _failJobInTxn(
              d,
              job,
              OcrErrorCode.contentChanged,
              '题目内容在识别期间被改过，识别结果不再自动覆盖',
              now,
            );
            return;
          }
        }
        wrote = true;
        final completed = await completeOcrJobIntoImpl(
          d,
          job.id,
          now: now,
          leaseToken: job.leaseToken,
        );
        if (completed == null) throw _LeaseLostException();
      });
    } on _LeaseLostException {
      return false;
    }
    return wrote;
  }

  /// 退避：429 有 Retry-After 就用它（封顶 5 分钟）；其余指数退避
  /// 30s → 60s → 120s（attempts 是已发起次数，1 = 首次失败后）。
  Duration _backoffDelay(int attempts, OcrException e) {
    if (e.retryAfter != null) {
      return e.retryAfter! <= ocrMaxBackoff ? e.retryAfter! : ocrMaxBackoff;
    }
    var seconds = ocrBackoffBase.inSeconds;
    for (var i = 1; i < attempts; i++) {
      seconds *= 2;
    }
    if (seconds > ocrMaxBackoff.inSeconds) seconds = ocrMaxBackoff.inSeconds;
    return Duration(seconds: seconds);
  }

  Future<bool> _hasKey() async {
    try {
      final key = await _keyStore.getApiKey();
      return key != null && key.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  File? _resolveCropFile(OcrJob job) => _resolveCropFileForPath(job.cropPath);

  /// 按相对路径解析切片文件（题目当前 slice_path 与任务 crop_path
  /// 共用；空路径或解析失败时返回 null）。
  File? _resolveCropFileForPath(String? cropPath) {
    if (cropPath == null || cropPath.isEmpty) return null;
    final absPath = AppDatabase.resolveDataPath(cropPath);
    if (absPath == null) return null;
    return File(absPath);
  }

  Future<String?> _hashOf(File file) async {
    try {
      return await sha256HexOfFile(file);
    } catch (_) {
      return null;
    }
  }

  /// OCR 完成/失败/丢弃后发事件（D-94 recentlyViewed 模式：写后发，
  /// 写失败不发；事件只说“这道题的 OCR 状态变了”，订阅方自己重读库）。
  /// 整理页当前靠 autoDispose 回页重读刷新；本事件供将来/其他订阅方
  /// 用（见 M3 报告：直接订阅后调 refresh() 会重置正在编辑的表单，
  /// 订阅方须先守门，勿直连）。
  void _emit(String questionId) {
    DataChangeBus.instance.emit(
      DataChangeEvent(
        kinds: const {DataChangeKind.questions},
        questionId: questionId,
      ),
    );
  }
}

/// 租约已丢：应用事务内抛它回滚整笔写回（任务已被回收重领，
/// 旧 worker 的题目写回与任务完成都不能提交）。
class _LeaseLostException implements Exception {}

/// M5 判定“有新的识别结果”（候选）：只读 ocr_raw 包的
/// candidate_status == pending（worker 在人工改过后跑出新结果时置
/// pending；M5 在用户保存手动编辑 / 接受 / 忽略候选后清掉）。
/// 不比较文本、不依赖时间戳——v4 schema 内唯一可靠的判定。
bool hasPendingOcrCandidate(Question question) =>
    GlmOcrRawData.tryParse(question.ocrRaw)?.hasUnseenCandidate == true;

/// 候选题干（M5 预览用）：对 raw 里的 md_results 再跑 splitStem。
/// 无候选或 raw 解析失败时返回 null。
String? pendingCandidateStem(Question question) {
  if (!hasPendingOcrCandidate(question)) return null;
  final raw = GlmOcrRawData.tryParse(question.ocrRaw);
  if (raw == null) return null;
  return splitStem(raw.mdResults).stemText;
}

/// 清掉 ocr_raw 包里的候选标志（M5 在用户保存手动编辑 / 接受 / 忽略
/// 候选后调，再随题目一起保存；清标志不改 md_results，原始结果不丢）。
/// raw 解析失败时原样返回（不动坏数据）。
String? clearOcrCandidateFlag(String? ocrRaw) {
  final parsed = GlmOcrRawData.tryParse(ocrRaw);
  if (parsed == null) return ocrRaw;
  if (!parsed.hasUnseenCandidate) return ocrRaw;
  return parsed.withoutCandidate().toJsonString();
}
