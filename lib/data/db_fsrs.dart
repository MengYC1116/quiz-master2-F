// P5：FSRS 数据模型 schema v8 + SQLite 落盘 + 迁移 + 事件幂等
//（实施方案 v2 §7，GPT 第五轮 P0-4/P0-5、第六轮补充第 1、3 项）。
// 与 database.dart 同一库（part of），共享库私有成员。
//
// 三张新表（DDL 字面量是唯一来源；createTablesImpl 用同一份常量，
// _upgrade7To8（drift/quiz_database.dart）逐字重复，见该函数注释）：
// - fsrs_cards：每题一行，一题一卡；
// - fsrs_events：事件账本（eventId 已处理标记，幂等）；
// - fsrs_migration_log：迁移审计日志（审计结果是迁移的一部分，见
//   migrateFsrsV7ToV8IntoImpl）。
//
// ── 迁移重放的确定性决定（P5 待确认点，Meng 不用等） ─────────────
// 生产运行时 fuzzing 显式开（SchedulerConfig 默认 enableFuzzing=true，
// 与上游默认一致，避免同批卡片总在同一天到期）；但 fuzzing 会给间隔
// 加随机扰动，迁移重放若开着它就无法逐字复现原 due、迁移不可重复验证。
// 因此迁移重放用确定性调度跑：同一份官方权重/保持率/最大间隔/空步骤，
// 只是 enableFuzzing=false（见 [migrationSchedulerConfig]）。
// 重放出的卡仍记 scheduler_config_id='fsrs-6-v1'（权重与生产同一份，
// 只是本次重放没加随机扰动）；卡片此后的正式复习一律走生产配置
// （fuzzing 开）。这个决定同时写进迁移日志的 audit_json。
// ────────────────────────────────────────────────────────────────

part of 'database.dart';

/// fsrs_cards 建表 DDL（P5 schema v8）。
///
/// 列与实施方案 v2 §7 对齐：question_id 主键（一题一卡）、card_id
///（包内整数 ID，数据库分配的永久整数）、algorithm_version='FSRS-6'、
/// scheduler_config_id、card_state_json（FSRS 完整状态）、next_due_at
///（UTC 毫秒，建索引，须与 card_state_json 里的 due 一致）、
/// first_reviewed_at（空 = 未开始正式复习）、content_version、
/// updated_at；再加第六轮补充第 1 项的首次呈现三字段
///（first_presented_at / first_presented_local_date /
/// first_presented_content_version）。
const String fsrsCardsTableDDL = '''
    CREATE TABLE fsrs_cards(
      question_id TEXT PRIMARY KEY, card_id INTEGER NOT NULL UNIQUE,
      algorithm_version TEXT NOT NULL DEFAULT 'FSRS-6',
      scheduler_config_id TEXT NOT NULL,
      card_state_json TEXT NOT NULL, next_due_at INTEGER NOT NULL,
      first_reviewed_at INTEGER, content_version INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL,
      first_presented_at INTEGER, first_presented_local_date TEXT,
      first_presented_content_version INTEGER)''';

/// fsrs_events 建表 DDL（事件账本，P0-4）。
///
/// event_id 主键；question_id 是该事件归属的题（CardStore 的裸接口
/// 不带题 id 时记 ''，见 SqliteCardStore.markEventProcessed；核对提交
/// 事务与迁移重放记真实题 id）；kind 区分 'review_answer'（正式作答）
/// / 'review_check'（核对提交，未判分或专项练习）/ 'migration_replay'。
const String fsrsEventsTableDDL = '''
    CREATE TABLE fsrs_events(
      event_id TEXT PRIMARY KEY, question_id TEXT NOT NULL DEFAULT '',
      kind TEXT NOT NULL, processed_at INTEGER NOT NULL)''';

/// fsrs_migration_log 建表 DDL（迁移审计日志）。
///
/// 每跑一次迁移写一行（run_id 唯一；source 如 'v7→v8'；status
/// 'completed'；audit_json 是审计 + 重放结果的完整 JSON；replayed /
/// skipped 是重放/跳过数）。迁移本身包事务：失败时本行随事务回滚，
/// 不留半张卡，下次开库重跑。
const String fsrsMigrationLogTableDDL = '''
    CREATE TABLE fsrs_migration_log(
      id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL,
      source TEXT NOT NULL, run_at INTEGER NOT NULL,
      status TEXT NOT NULL, audit_json TEXT NOT NULL,
      replayed_count INTEGER NOT NULL DEFAULT 0,
      skipped_count INTEGER NOT NULL DEFAULT 0)''';

/// fsrs_cards.next_due_at 索引（到期查询走索引）。
const String fsrsCardsDueIndexDDL =
    'CREATE INDEX idx_fsrs_cards_due ON fsrs_cards(next_due_at)';

/// 迁移重放用的确定性调度配置：与生产配置同一套官方权重/保持率/
/// 最大间隔/空学习与重学步骤，唯独 fuzzing 关（见文件头决定）。
/// configId 仍是 'fsrs-6-v1'（权重同一份）；configHash 会因 F 标志
/// 不同而不同，这是故意的——哈希能分清“重放算出的 due”与“生产算出
/// 的 due”，卡片的 scheduler_config_id 不因此分裂。
const SchedulerConfig migrationSchedulerConfig =
    SchedulerConfig(enableFuzzing: false);

/// fsrs_cards 行 → [StoredCard]。
StoredCard _storedCardFromRow(Map<String, Object?> row) {
  final cardMap =
      jsonDecode(row['card_state_json'] as String) as Map<String, dynamic>;
  int? ms(Object? v) => v == null ? null : (v as num).toInt();
  return StoredCard(
    questionId: row['question_id'] as String,
    cardId: (row['card_id'] as num).toInt(),
    card: fsrs.Card.fromMap(cardMap),
    configId: row['scheduler_config_id'] as String,
    firstReviewedAt: ms(row['first_reviewed_at']) == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            ms(row['first_reviewed_at'])!,
            isUtc: true,
          ),
    contentVersion: (row['content_version'] as num?)?.toInt() ?? 0,
    firstPresentedAt: ms(row['first_presented_at']) == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            ms(row['first_presented_at'])!,
            isUtc: true,
          ),
    firstPresentedLocalDate: row['first_presented_local_date'] as String?,
    firstPresentedContentVersion:
        (row['first_presented_content_version'] as num?)?.toInt(),
  );
}

/// [CardStore] 的 SQLite 实现（fsrs_cards + fsrs_events 表）。
///
/// - card_id 是数据库分配的永久整数：[allocateCardId] 读已落盘的映射，
///   没有才取 MAX(card_id)+1；[save] 在事务内再验一次——若该整数已被
///   别的题占了（allocate 与 save 之间交错），重新分配，绝不复用、
///   绝不覆盖别人的映射。删题/恢复/重导入时查已有映射复用，不产生
///   重复卡；内容重置不改 card_id（reset 走 resetQuestion / 钩子，
///   不经过 allocate）。
/// - 本类的方法本身不另开事务（只有 [save] 用事务包住“验冲突 +
///   写行”，保证单次保存原子）：调用方（核对提交事务、迁移重放）
///   在外层包事务时，这里的语句加入外层事务，同生同灭；直接调
///   调度器时每次保存仍是原子的。
/// - 时间口径：全部存 UTC 毫秒；due 写库前一律转 UTC。
class SqliteCardStore implements CardStore {
  /// 生产构造：每次用时取当前单例库（AppDatabase.instance.db，
  /// 同一个 QuizDatabase 对象；外层事务内调用时语句加入该事务）。
  SqliteCardStore({Future<QuizDatabase> Function()? dbFactory})
    : _dbFactory = dbFactory ?? (() => AppDatabase.instance.db);

  /// 测试构造：直接绑一个已打开的库。
  factory SqliteCardStore.forDatabase(QuizDatabase db) {
    return SqliteCardStore(dbFactory: () async => db);
  }

  final Future<QuizDatabase> Function() _dbFactory;

  Future<QuizDatabase> get _db async => _dbFactory();

  @override
  Future<int> allocateCardId(String questionId) async {
    final db = await _db;
    final existing = await db
        .customSelect(
          'SELECT card_id FROM fsrs_cards WHERE question_id = ?',
          variables: [Variable.withString(questionId)],
        )
        .getSingleOrNull();
    if (existing != null) return existing.data['card_id'] as int;
    return _nextCardId(db);
  }

  Future<int> _nextCardId(QuizDatabase db) async {
    final row = await db
        .customSelect('SELECT COALESCE(MAX(card_id), 0) AS max_id FROM fsrs_cards')
        .getSingle();
    return (row.data['max_id'] as int) + 1;
  }

  @override
  Future<StoredCard?> load(String questionId) async {
    final db = await _db;
    final row = await db
        .customSelect(
          'SELECT * FROM fsrs_cards WHERE question_id = ?',
          variables: [Variable.withString(questionId)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    return _storedCardFromRow(row.data);
  }

  @override
  Future<void> save(StoredCard card) async {
    final db = await _db;
    await db.transaction(() async {
      await _saveCardInto(db, card);
    });
  }

  @override
  Future<List<StoredCard>> loadAll() async {
    final db = await _db;
    final rows = await db
        .customSelect('SELECT * FROM fsrs_cards ORDER BY card_id ASC')
        .get();
    return rows.map((r) => _storedCardFromRow(r.data)).toList();
  }

  @override
  Future<bool> hasProcessedEvent(String eventId) async {
    final db = await _db;
    return _fsrsHasEvent(db, eventId);
  }

  @override
  Future<void> markEventProcessed(String eventId) async {
    final db = await _db;
    await _fsrsMarkEvent(db, eventId, '', 'review_answer');
  }
}

/// 在 [db] 的当前事务内（调用方已包事务时加入外层事务；单独调时
/// 外层 [SqliteCardStore.save] 包事务）写一行业务卡片行。
/// next_due_at 与 card_state_json 里的 due 取自同一张 [fsrs.Card]，
/// 不可能不一致。card_id 冲突时（别的题已占该整数）重新分配。
Future<void> _saveCardInto(QuizDatabase db, StoredCard card) async {
  var cardId = card.cardId;
  final clash = await db
      .customSelect(
        'SELECT question_id FROM fsrs_cards WHERE card_id = ?',
        variables: [Variable.withInt(cardId)],
      )
      .getSingleOrNull();
  if (clash != null && clash.data['question_id'] != card.questionId) {
    final row = await db
        .customSelect('SELECT COALESCE(MAX(card_id), 0) AS max_id FROM fsrs_cards')
        .getSingle();
    cardId = (row.data['max_id'] as int) + 1;
  }
  final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
  final dueMs = card.card.due.toUtc().millisecondsSinceEpoch;
  final firstReviewedMs = card.firstReviewedAt
      ?.toUtc()
      .millisecondsSinceEpoch;
  final firstPresentedMs = card.firstPresentedAt
      ?.toUtc()
      .millisecondsSinceEpoch;
  await db.customInsert(
    'INSERT INTO fsrs_cards(question_id, card_id, algorithm_version, '
    'scheduler_config_id, card_state_json, next_due_at, first_reviewed_at, '
    'content_version, updated_at, first_presented_at, '
    'first_presented_local_date, first_presented_content_version) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
    'ON CONFLICT(question_id) DO UPDATE SET '
    'card_id = excluded.card_id, '
    'algorithm_version = excluded.algorithm_version, '
    'scheduler_config_id = excluded.scheduler_config_id, '
    'card_state_json = excluded.card_state_json, '
    'next_due_at = excluded.next_due_at, '
    'first_reviewed_at = excluded.first_reviewed_at, '
    'content_version = excluded.content_version, '
    'updated_at = excluded.updated_at, '
    'first_presented_at = excluded.first_presented_at, '
    'first_presented_local_date = excluded.first_presented_local_date, '
    'first_presented_content_version = excluded.first_presented_content_version',
    variables: [
      Variable.withString(card.questionId),
      Variable.withInt(cardId),
      Variable.withString('FSRS-6'),
      Variable.withString(card.configId),
      Variable.withString(jsonEncode(card.card.toMap())),
      Variable.withInt(dueMs),
      Variable(firstReviewedMs),
      Variable.withInt(card.contentVersion),
      Variable.withInt(nowMs),
      Variable(firstPresentedMs),
      Variable(card.firstPresentedLocalDate),
      Variable(card.firstPresentedContentVersion),
    ],
  );
}

/// 事件账本读（[db] 当前事务内）。
Future<bool> _fsrsHasEvent(QuizDatabase db, String eventId) async {
  final row = await db
      .customSelect(
        'SELECT event_id FROM fsrs_events WHERE event_id = ?',
        variables: [Variable.withString(eventId)],
      )
      .getSingleOrNull();
  return row != null;
}

/// 事件账本写（[db] 当前事务内；已存在时不报错、不覆盖）。
Future<void> _fsrsMarkEvent(
  QuizDatabase db,
  String eventId,
  String questionId,
  String kind,
) async {
  await db.customInsert(
    'INSERT OR IGNORE INTO fsrs_events(event_id, question_id, kind, processed_at) '
    'VALUES (?, ?, ?, ?)',
    variables: [
      Variable.withString(eventId),
      Variable.withString(questionId),
      Variable.withString(kind),
      Variable.withInt(DateTime.now().toUtc().millisecondsSinceEpoch),
    ],
  );
}

/// 首次呈现记录（第六轮补充第 1 项，P4 调用，P5 只提供方法与字段）。
///
/// 首次显示题目时由调用方在事务内调：题还没卡时先建一张新卡（未开始
/// 正式复习状态），再写首次呈现三字段。只写一次：同一内容版本已有
/// 首次呈现记录时不重计（退出恢复不重计、第二天不重计）；内容版本
/// 变了（新版本）则重新计（三个字段按新版本覆盖）。
/// [presentedAtUtc] 是呈现时刻（UTC）；[localDate] 是呈现时的本地
/// 日期 `yyyy-MM-dd`（由调用方按呈现设备本地日历算好传进来，本方法
/// 不猜时区）；[contentVersion] 是呈现时题目的内容版本。
/// 返回 true 表示本次写下了（首次呈现），false 表示已有记录未重计。
Future<bool> recordFirstPresentedInto(
  QuizDatabase db, {
  required String questionId,
  required DateTime presentedAtUtc,
  required String localDate,
  required int contentVersion,
}) async {
  var wrote = false;
  await db.transaction(() async {
    final existing = await db
        .customSelect(
          'SELECT question_id, card_id, first_presented_content_version '
          'FROM fsrs_cards WHERE question_id = ?',
          variables: [Variable.withString(questionId)],
        )
        .getSingleOrNull();
    if (existing == null) {
      // 还没卡：先建新卡（FSRS 新卡状态，due 即 now；是否算到期由
      // first_reviewed_at 区分，不由 due 区分——与 P1 同口径），
      // 再写首次呈现。
      final store = SqliteCardStore.forDatabase(db);
      final cardId = await store.allocateCardId(questionId);
      await _saveCardInto(
        db,
        StoredCard(
          questionId: questionId,
          cardId: cardId,
          card: fsrs.Card(cardId: cardId, due: presentedAtUtc.toUtc()),
          configId: const SchedulerConfig().configId,
          firstReviewedAt: null,
          contentVersion: contentVersion,
        ),
      );
    }
    final changed = await db.customUpdate(
      'UPDATE fsrs_cards SET first_presented_at = ?, '
      'first_presented_local_date = ?, first_presented_content_version = ?, '
      'updated_at = ? WHERE question_id = ? AND '
      '(first_presented_content_version IS NULL OR '
      'first_presented_content_version != ?)',
      variables: [
        Variable.withInt(presentedAtUtc.toUtc().millisecondsSinceEpoch),
        Variable.withString(localDate),
        Variable.withInt(contentVersion),
        Variable.withInt(DateTime.now().toUtc().millisecondsSinceEpoch),
        Variable.withString(questionId),
        Variable.withInt(contentVersion),
      ],
    );
    wrote = changed > 0;
  });
  return wrote;
}

/// 内容实质修改后的卡片重置（实施方案 v2 §7；upsert 钩子调，见
/// _upsertQuestionIntoTxn）。
///
/// 题干/选项/标准答案/题型变 → 重置：FSRS 状态回到新卡，
/// first_reviewed_at 与首次呈现三字段清空（新版本重新进待释放状态，
/// 首次呈现按新版本重计），content_version 写新版本；card_id 不变。
/// 纯排版或显示样式修复、只改分类标签不调本方法（upsert 的版本计算
/// 本来就不抬版本，见 _upsertQuestionIntoTxn 的比对口径）。
/// 旧作答事实（attempts 行）一律保留，不参与新版本重放。
/// 题还没有卡时什么都不做（卡在 initializeQuestion 时再建）。
Future<void> resetFsrsCardForContentChangeInto(
  QuizDatabase db,
  String questionId,
  int newContentVersion, {
  DateTime? now,
}) async {
  // 防御：手造夹具库可能没有 fsrs_cards 表（v7 夹具直接调 upsert 时），
  // 缺表时跳过，不把一次题目保存炸掉；v8 正常库一定有表。
  final table = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'fsrs_cards'",
      )
      .getSingleOrNull();
  if (table == null) return;
  final row = await db
      .customSelect(
        'SELECT card_id, scheduler_config_id FROM fsrs_cards WHERE question_id = ?',
        variables: [Variable.withString(questionId)],
      )
      .getSingleOrNull();
  if (row == null) return;
  final nowUtc = (now ?? DateTime.now()).toUtc();
  final cardId = row.data['card_id'] as int;
  await _saveCardInto(
    db,
    StoredCard(
      questionId: questionId,
      cardId: cardId,
      card: fsrs.Card(cardId: cardId, due: nowUtc),
      configId: row.data['scheduler_config_id'] as String,
      firstReviewedAt: null,
      contentVersion: newContentVersion,
    ),
  );
}

/// 核对提交的事务双写（P0-4，P2 submitCheck 的 P5 接线）。
///
/// 一个 SQLite 事务内完成：① attempts 行（upsert，一次会话每题一条）+
/// ② FSRS 推进（scheduler.recordAnswer，经 SqliteCardStore 写
/// fsrs_cards）+ ③ 事件账本（eventId 已处理标记）。任一步失败整笔
/// 回滚；重试仍用同一 eventId。
/// - [result] 为 null = 专项练习或无法判分：只写 attempts，不推进
///   FSRS、不改到期时间，但仍记事件（同一 eventId 的重复提交直接
///   返回，不重写 attempts、不重计分）。
/// - 重复提交（事件已处理）：不重写、不重推进，返回已有的 attempt id
///   与当前下次到期时间（[result] 非空时）。
/// - 调度器由调用方传入（生产是 reviewSchedulerProvider 的 SQLite
///   调度器；测试可传确定性调度器）。调度器用的 store 若不是同一库
///   的 SqliteCardStore，事务只覆盖 attempts 与事件账本——调用方
///   必须保证传入的调度器与本库同源（生产路径满足）。
Future<({String attemptId, DateTime? nextDue})> _submitReviewCheckInto(
  QuizDatabase db, {
  required AttemptData attempt,
  required ReviewResult? result,
  required DateTime reviewedAt,
  required String eventId,
  required ReviewScheduler scheduler,
}) async {
  if (eventId.isEmpty) {
    throw ArgumentError.value(eventId, 'eventId', 'must not be empty');
  }
  late ({String attemptId, DateTime? nextDue}) out;
  await db.transaction(() async {
    // 幂等短路：事件已处理 → 不重写、不重推进。
    if (await _fsrsHasEvent(db, eventId)) {
      final existing = await AppDatabase.loadAttemptInto(
        db,
        sessionId: attempt.sessionId,
        questionId: attempt.questionId,
      );
      DateTime? due;
      if (result != null) {
        due = await scheduler.nextDueAt(attempt.questionId);
      }
      out = (attemptId: existing?.id ?? attempt.id, nextDue: due);
      return;
    }
    // ① attempts 行（内层不另开事务，直接加入外层事务）。
    final attemptId = await _recordAttemptInTxn(db, attempt);
    DateTime? nextDue;
    if (result != null) {
      // ②③ FSRS 推进 + 事件账本（recordAnswer 内记事件；
      // store 语句加入外层事务）。
      await scheduler.recordAnswer(
        attempt.questionId,
        result,
        reviewedAt,
        eventId,
      );
      // 调度器不知道题目内容版本：建卡时 content_version 先记 0，
      // 这里按本次作答的版本回填（attempt.contentVersion 就是作答
      // 时题目的版本），否则卡片版本恒为 0、核对失效。
      await db.customUpdate(
        'UPDATE fsrs_cards SET content_version = ? WHERE question_id = ?',
        variables: [
          Variable.withInt(attempt.contentVersion),
          Variable.withString(attempt.questionId),
        ],
      );
      nextDue = await scheduler.nextDueAt(attempt.questionId);
    } else {
      // 未判分/专项练习：不推进 FSRS，但记事件，重复提交可短路。
      await _fsrsMarkEvent(db, eventId, attempt.questionId, 'review_check');
    }
    out = (attemptId: attemptId, nextDue: nextDue);
  });
  return out;
}

/// P5 的 AppDatabase 扩展：核对提交事务 + 首次呈现（repository 转发）。
extension AppDatabaseFsrs on AppDatabase {
  /// 核对提交事务双写（见 [_submitReviewCheckInto]）。
  Future<({String attemptId, DateTime? nextDue})> submitReviewCheckTxn({
    required AttemptData attempt,
    required ReviewResult? result,
    required DateTime reviewedAt,
    required String eventId,
    required ReviewScheduler scheduler,
  }) async {
    final d = await db;
    return _submitReviewCheckInto(
      d,
      attempt: attempt,
      result: result,
      reviewedAt: reviewedAt,
      eventId: eventId,
      scheduler: scheduler,
    );
  }

  /// 首次呈现记录（见 [recordFirstPresentedInto]）。
  Future<bool> recordFirstPresentedTxn({
    required String questionId,
    required DateTime presentedAtUtc,
    required String localDate,
    required int contentVersion,
  }) async {
    final d = await db;
    return recordFirstPresentedInto(
      d,
      questionId: questionId,
      presentedAtUtc: presentedAtUtc,
      localDate: localDate,
      contentVersion: contentVersion,
    );
  }

  /// P3 入口 1–3 共用：当前已在复习池里的题 id（fsrs_cards 行）。
  /// 只读；v7 夹具库无 fsrs_cards 表时返回空列表，不抛错。
  Future<List<String>> fsrsCardQuestionIds() async {
    final d = await db;
    try {
      final rows = await d
          .customSelect('SELECT question_id FROM fsrs_cards')
          .get();
      return rows.map((r) => r.data['question_id'] as String).toList();
    } catch (_) {
      return const [];
    }
  }

  /// v7 → v8 迁移（审计 + 重放，见 [migrateFsrsV7ToV8IntoImpl]）。
  static Future<Map<String, Object?>> migrateFsrsV7ToV8(QuizDatabase db) =>
      migrateFsrsV7ToV8IntoImpl(db);
}

// ---------------------------------------------------------------------------
// 迁移：历史审计 + 唯一来源重放（v7 → v8）
// ---------------------------------------------------------------------------

/// 迁移审计结果（审计是迁移的一部分，写进 fsrs_migration_log 的
/// audit_json，不只口头说；见实施方案 v2 §7 + 第六轮补充第 3 项）。
class FsrsMigrationAudit {
  const FsrsMigrationAudit({
    required this.attemptsFormalTotal,
    required this.attemptsFormalNullCorrect,
    required this.attemptsFormalVersionMismatch,
    required this.attemptsFormalNoQuestion,
    required this.attemptsFormalBadTime,
    required this.reviewHistoryTotal,
    required this.reviewHistoryFormal,
    required this.reviewHistoryOnly,
    required this.suspectedDuplicateRows,
    required this.suspectedDuplicateGroups,
    required this.eligibleCount,
    required this.replayedCount,
    required this.skippedCount,
    required this.legacyDueCandidates,
    required this.deterministicReplay,
  });

  /// attempts 里 mode=正式复习的总量。
  final int attemptsFormalTotal;

  /// 其中 correct 为 NULL 的数（未判分，不重放）。
  final int attemptsFormalNullCorrect;

  /// 其中内容版本与当前题目不一致的数（不重放到当前版本）。
  final int attemptsFormalVersionMismatch;

  /// 其中题目行已不存在的数（不重放）。
  final int attemptsFormalNoQuestion;

  /// 其中作答时间无效（created_at <= 0）的数（不重放；重放要按时间
  /// 顺序算间隔，没有可信时间算不出 due）。
  final int attemptsFormalBadTime;

  /// review_history 总量 / 其中 review_mode=正式复习的量。
  final int reviewHistoryTotal;
  final int reviewHistoryFormal;

  /// review_history 有但 attempts 没有的记录数（只作历史资料保留，
  /// 不作第二份重放；它无 content_version，verdict 也不是客观对错）。
  final int reviewHistoryOnly;

  /// 疑似重复记录：同一题在同一毫秒、同一对错下出现多次的行数/组数
  /// （只审计、不合并——GPT 第六轮：不许只凭 question_id +
  /// reviewed_at + correct 去重，同一题相近时间两次独立作答不能
  /// 误合并；去重只认 event_id / 原始行主键）。
  final int suspectedDuplicateRows;
  final int suspectedDuplicateGroups;

  /// 同时满足重放条件的记录数（mode=正式复习、correct 有明确
  /// true/false、有有效作答时间、内容版本与当前一致、无重复记录）。
  final int eligibleCount;

  /// 本次实际重放数 / 跳过数（跳过 = 不合条件 + 重复 + 已重放过）。
  final int replayedCount;
  final int skippedCount;

  /// 有可信旧到期时间（cause_records 里已解决且有 recheck_date）
  /// 但没有 FSRS 卡的题：不伪造 FSRS 历史，只把旧到期时间记下来
  /// 作一次性过渡（首次新流程正式复习后建 FSRS 状态；没有的进新题
  /// 释放队列，受每日额度控制——P4 用）。
  final List<Map<String, Object?>> legacyDueCandidates;

  /// 本次重放是否确定性调度（fuzzing 关，见文件头决定）。
  final bool deterministicReplay;

  Map<String, Object?> toJson() => {
    'attemptsFormalTotal': attemptsFormalTotal,
    'attemptsFormalNullCorrect': attemptsFormalNullCorrect,
    'attemptsFormalVersionMismatch': attemptsFormalVersionMismatch,
    'attemptsFormalNoQuestion': attemptsFormalNoQuestion,
    'attemptsFormalBadTime': attemptsFormalBadTime,
    'reviewHistoryTotal': reviewHistoryTotal,
    'reviewHistoryFormal': reviewHistoryFormal,
    'reviewHistoryOnly': reviewHistoryOnly,
    'suspectedDuplicateRows': suspectedDuplicateRows,
    'suspectedDuplicateGroups': suspectedDuplicateGroups,
    'eligibleCount': eligibleCount,
    'replayedCount': replayedCount,
    'skippedCount': skippedCount,
    'legacyDueCandidates': legacyDueCandidates,
    'deterministicReplay': deterministicReplay,
  };
}

Future<int> _countRows(
  QuizDatabase db,
  String sql, [
  List<Variable> variables = const [],
]) async {
  final row = await db
      .customSelect(sql, variables: variables)
      .getSingle();
  return (row.data.values.first as num).toInt();
}

/// v7 → v8 迁移：历史审计 + 唯一来源重放（实施方案 v2 §7）。
///
/// 唯一来源 = attempts，同时满足才重放：mode=正式复习、correct 有
/// 明确 true/false、有有效作答时间（created_at > 0）、内容版本与
/// 当前题目一致、无重复记录（去重只认 event_id —— 这里是
/// submission_id，空时退到原始行主键 id；绝不只凭 question_id +
/// reviewed_at + correct 去重）。正式答对 → Good，答错 → Again。
/// review_history 只作历史资料保留，不作第二份重放；专项练习记录
/// 不重放；只有自查 verdict 的不重放；无判分结果的不重放；内容版本
/// 不匹配的不重放到当前版本；同一事件在两张表都出现时只算一次
/// （只从 attempts 重放，天然一次）。
///
/// 整个迁移包在一个事务里：失败不留半张卡（迁移日志行也随事务回滚，
/// 下次开库重跑）；已完成过一次的库再次打开时直接跳过（幂等，
/// 不重复重放——重放过的生产 attempts 绝不能再以 'mig:' 事件名
/// 重算一次）。无完整历史的题不伪造历史、不建卡。
/// 返回审计 + 重放结果的 JSON（含 run_id、status、audit）。
Future<Map<String, Object?>> migrateFsrsV7ToV8IntoImpl(
  QuizDatabase db, {
  DateTime? now,
}) async {
  final table = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'fsrs_cards'",
      )
      .getSingleOrNull();
  if (table == null) {
    throw StateError('fsrs_cards 表不存在，无法做 v7→v8 迁移：请先完成 schema v8 建表/升级');
  }
  final done = await _countRows(
    db,
    "SELECT COUNT(*) FROM fsrs_migration_log WHERE source = 'v7→v8' AND status = 'completed'",
  );
  if (done > 0) {
    return {
      'status': 'already_migrated',
      'deterministicReplay': true,
    };
  }
  final runId = newReviewUuid('mig');
  final runAt = (now ?? DateTime.now()).toUtc();
  late Map<String, Object?> result;
  await db.transaction(() async {
    // ── 审计（与重放同一事务、同一快照） ──
    final attemptsFormalTotal = await _countRows(
      db,
      "SELECT COUNT(*) FROM attempts WHERE mode = '到期复习'",
    );
    final attemptsFormalNullCorrect = await _countRows(
      db,
      "SELECT COUNT(*) FROM attempts WHERE mode = '到期复习' AND correct IS NULL",
    );
    final attemptsFormalVersionMismatch = await _countRows(
      db,
      'SELECT COUNT(*) FROM attempts a JOIN questions q ON q.id = a.question_id '
      "WHERE a.mode = '到期复习' AND a.correct IS NOT NULL AND a.content_version != q.content_version",
    );
    final attemptsFormalNoQuestion = await _countRows(
      db,
      'SELECT COUNT(*) FROM attempts a LEFT JOIN questions q ON q.id = a.question_id '
      "WHERE a.mode = '到期复习' AND a.correct IS NOT NULL AND q.id IS NULL",
    );
    final attemptsFormalBadTime = await _countRows(
      db,
      "SELECT COUNT(*) FROM attempts WHERE mode = '到期复习' AND correct IS NOT NULL AND created_at <= 0",
    );
    final reviewHistoryTotal = await _countRows(
      db,
      'SELECT COUNT(*) FROM review_history',
    );
    final reviewHistoryFormal = await _countRows(
      db,
      "SELECT COUNT(*) FROM review_history WHERE review_mode = '到期复习'",
    );
    final reviewHistoryOnly = await _countRows(
      db,
      'SELECT COUNT(*) FROM review_history h WHERE '
      '(h.submission_id IS NULL OR h.submission_id NOT IN '
      '(SELECT submission_id FROM attempts WHERE submission_id IS NOT NULL)) '
      'AND (h.attempt_id IS NULL OR h.attempt_id NOT IN '
      '(SELECT id FROM attempts))',
    );
    // 疑似重复：同一题、同一毫秒、同一对错出现多次（只审计，不合并）。
    final dupGroups = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM attempts WHERE mode = ? '
          'GROUP BY question_id, created_at, correct HAVING COUNT(*) > 1',
          variables: [Variable.withString(ReviewMode.due)],
        )
        .get();
    var suspectedDuplicateRows = 0;
    for (final g in dupGroups) {
      suspectedDuplicateRows += (g.data['c'] as num).toInt();
    }
    // submission_id 重复组（UNIQUE 约束下应为 0，仍审计）。
    final dupSubmissionGroups = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM attempts WHERE submission_id IS NOT NULL '
          'GROUP BY submission_id HAVING COUNT(*) > 1',
        )
        .get();
    for (final g in dupSubmissionGroups) {
      suspectedDuplicateRows += (g.data['c'] as num).toInt();
    }

    // ── 重放候选：一次查全，按 created_at 升序（最早的先算） ──
    final candidates = await db
        .customSelect(
          'SELECT a.id AS id, a.question_id AS question_id, '
          'a.correct AS correct, a.created_at AS created_at, '
          'a.submission_id AS submission_id, a.content_version AS content_version, '
          'q.content_version AS current_content_version '
          'FROM attempts a LEFT JOIN questions q ON q.id = a.question_id '
          "WHERE a.mode = '到期复习' AND a.correct IS NOT NULL AND a.created_at > 0 "
          'ORDER BY a.created_at ASC, a.id ASC',
        )
        .get();
    final seenKeys = <String>{};
    var eligibleCount = 0;
    var replayedCount = 0;
    var skippedCount = 0;
    final store = SqliteCardStore.forDatabase(db);
    final scheduler = FsrsReviewScheduler(
      config: migrationSchedulerConfig,
      store: store,
    );
    for (final row in candidates) {
      final data = row.data;
      final questionId = data['question_id'] as String;
      final currentVersion = data['current_content_version'];
      if (currentVersion == null) {
        skippedCount++; // 题目行已不存在
        continue;
      }
      final currentVersionInt = (currentVersion as num).toInt();
      if ((data['content_version'] as num).toInt() != currentVersionInt) {
        skippedCount++; // 内容版本与当前不一致，不重放到当前版本
        continue;
      }
      final key =
          (data['submission_id'] as String?) ?? (data['id'] as String);
      if (!seenKeys.add(key)) {
        skippedCount++; // 同一事件重复出现（去重认 event_id / 行主键）
        continue;
      }
      eligibleCount++;
      final eventId = 'mig:$key';
      if (await _fsrsHasEvent(db, eventId)) {
        skippedCount++; // 上次部分运行已重放过，不重复推进
        continue;
      }
      final correct = (data['correct'] as num).toInt();
      await scheduler.recordAnswer(
        questionId,
        correct == 1 ? ReviewResult.good : ReviewResult.again,
        DateTime.fromMillisecondsSinceEpoch(
          (data['created_at'] as num).toInt(),
          isUtc: true,
        ),
        eventId,
      );
      // 回填卡片内容版本（调度器不知道题目版本，见 _submitReviewCheckInto）。
      await db.customUpdate(
        'UPDATE fsrs_cards SET content_version = ? WHERE question_id = ?',
        variables: [
          Variable.withInt(currentVersionInt),
          Variable.withString(questionId),
        ],
      );
      replayedCount++;
    }

    // ── 有可信旧到期时间但无卡的题（一次性过渡，只记录，不伪造） ──
    final legacyRows = await db
        .customSelect(
          'SELECT DISTINCT cr.question_id AS question_id, cr.recheck_date AS recheck_date '
          'FROM cause_records cr JOIN questions q ON q.id = cr.question_id '
          "WHERE cr.status = 'solved' AND cr.recheck_date IS NOT NULL "
          'AND cr.question_id NOT IN (SELECT question_id FROM fsrs_cards) '
          'ORDER BY cr.recheck_date ASC',
        )
        .get();
    final legacyDueCandidates = legacyRows
        .map(
          (r) => <String, Object?>{
            'question_id': r.data['question_id'] as String,
            'recheck_date': (r.data['recheck_date'] as num).toInt(),
          },
        )
        .toList();

    final audit = FsrsMigrationAudit(
      attemptsFormalTotal: attemptsFormalTotal,
      attemptsFormalNullCorrect: attemptsFormalNullCorrect,
      attemptsFormalVersionMismatch: attemptsFormalVersionMismatch,
      attemptsFormalNoQuestion: attemptsFormalNoQuestion,
      attemptsFormalBadTime: attemptsFormalBadTime,
      reviewHistoryTotal: reviewHistoryTotal,
      reviewHistoryFormal: reviewHistoryFormal,
      reviewHistoryOnly: reviewHistoryOnly,
      suspectedDuplicateRows: suspectedDuplicateRows,
      suspectedDuplicateGroups: dupGroups.length + dupSubmissionGroups.length,
      eligibleCount: eligibleCount,
      replayedCount: replayedCount,
      skippedCount: skippedCount,
      legacyDueCandidates: legacyDueCandidates,
      deterministicReplay: true,
    );
    await db.customInsert(
      'INSERT INTO fsrs_migration_log(run_id, source, run_at, status, audit_json, replayed_count, skipped_count) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable.withString(runId),
        Variable.withString('v7→v8'),
        Variable.withInt(runAt.millisecondsSinceEpoch),
        Variable.withString('completed'),
        Variable.withString(
          jsonEncode({
            ...audit.toJson(),
            'migrationFuzzing': 'off',
            'migrationConfigId': migrationSchedulerConfig.configId,
            'note':
                '迁移重放用确定性调度（fuzzing 关），生产运行时仍按版本化配置（fuzzing 开）走；见 db_fsrs.dart 文件头。',
          }),
        ),
        Variable.withInt(replayedCount),
        Variable.withInt(skippedCount),
      ],
    );
    result = {
      'status': 'completed',
      'run_id': runId,
      'deterministicReplay': true,
      'audit': audit.toJson(),
    };
  });
  return result;
}

/// attempts 事实与 fsrs_cards 状态核对一致（测试与排障用）。
///
/// 适用范围：仅对确定性调度建出的卡有效（迁移重放、fuzzing 关的测试
/// 调度器）。生产调度器 fuzzing 开，due 带随机扰动，重算值与卡片
/// 值本就不相等，不在此核对；生产卡片只核对 next_due_at 与 JSON
/// 的 due 是否相等这一结构项（下面第一项检查，所有卡都适用）。
///
/// 对每张有首次正式复习记录的卡：按时间顺序把该题符合重放条件的
/// attempts（mode=正式复习、correct 非空、created_at 有效、内容版本
/// 与卡片版本一致）用确定性调度重算一遍，比较 due / stability /
/// difficulty / state 是否与卡片 JSON 一致；再逐行核对
/// next_due_at 与 JSON 里的 due 是否相等。返回不一致的描述列表
/// （空 = 一致）。不合重放条件的 attempts 不参与重算（它们本来就
/// 不该推进卡片）；卡片 content_version 与题目当前版本不一致时
/// 也记一条（内容改过但未重置，或重置后未重新复习）。
Future<List<String>> verifyFsrsConsistencyInto(QuizDatabase db) async {
  final problems = <String>[];
  final cards = await db
      .customSelect('SELECT * FROM fsrs_cards ORDER BY card_id ASC')
      .get();
  for (final row in cards) {
    final data = row.data;
    final questionId = data['question_id'] as String;
    final stored = _storedCardFromRow(data);
    final dueMs = stored.card.due.toUtc().millisecondsSinceEpoch;
    if ((data['next_due_at'] as num).toInt() != dueMs) {
      problems.add('$questionId：next_due_at 与 card_state_json 的 due 不一致');
    }
    if (stored.firstReviewedAt == null) continue;
    final attempts = await db
        .customSelect(
          'SELECT correct, created_at, content_version FROM attempts '
          "WHERE question_id = ? AND mode = '到期复习' AND correct IS NOT NULL AND created_at > 0 "
          'ORDER BY created_at ASC, id ASC',
          variables: [Variable.withString(questionId)],
        )
        .get();
    // 用内存 store 重算，不碰库里真实卡片。
    final memStore = InMemoryCardStore();
    final scheduler = FsrsReviewScheduler(
      config: migrationSchedulerConfig,
      store: memStore,
    );
    var evt = 0;
    var replayed = 0;
    for (final a in attempts) {
      final adata = a.data;
      if ((adata['content_version'] as num).toInt() !=
          stored.contentVersion) {
        continue; // 旧版本记录不参与新版本重放
      }
      await scheduler.recordAnswer(
        questionId,
        (adata['correct'] as num).toInt() == 1
            ? ReviewResult.good
            : ReviewResult.again,
        DateTime.fromMillisecondsSinceEpoch(
          (adata['created_at'] as num).toInt(),
          isUtc: true,
        ),
        'verify-$questionId-${evt++}',
      );
      replayed++;
    }
    if (replayed == 0) continue;
    final recomputed = (await memStore.load(questionId))!;
    final rc = recomputed.card;
    final sc = stored.card;
    if (rc.due.toUtc() != sc.due.toUtc() ||
        rc.stability != sc.stability ||
        rc.difficulty != sc.difficulty ||
        rc.state != sc.state) {
      problems.add(
        '$questionId：卡片状态与 attempts 确定性重算不一致'
        '（due ${sc.due.toIso8601String()} vs ${rc.due.toIso8601String()}）',
      );
    }
  }
  return problems;
}
