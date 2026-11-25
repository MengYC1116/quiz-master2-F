// P1：复习调度器接口 + FSRS-6 接入（shuati-implementation-plan-v2 §3）。
//
// 业务代码只认 [ReviewScheduler] 接口，不认 FSRS 包；FSRS 只活在
// [FsrsReviewScheduler] 封装层里。持久化（fsrs_cards 表）是 P5 的活，
// 这里只定义 [CardStore] 抽象 + 内存实现，P5 直接插 SQLite 实现进来。
//
// ── fsrs 2.0.1 源码审计结论（2026-11-25，P1 门禁第 1 项） ──────────────
// 审的是本地 pub 缓存 ~/.pub-cache/hosted/pub.dev/fsrs-2.0.1：
//  - 单文件 lib/fsrs.dart，只 import dart:math 和 package:meta；
//    无 dart:io、无网络、无平台通道、无任何权限声明；pubspec 只有
//    meta 一个直接依赖；LICENSE 为 MIT（Copyright (c) 2022 Open Spaced
//    Repetition）。
//  - 是 FSRS-6：21 个权重；遗忘曲线用 w20 做衰减指数
//    R(t,S) = (1 + factor·t/S)^(-w20)；成功后稳定性用
//    S·(1 + e^w8·(11-D)·S^-w9·(e^((1-R)·w10)-1))；遗忘后稳定性取
//    min(w11·D^-w12·((S+1)^w13-1)·e^((1-R)·w14), S/e^(w17·w18))；
//    同日复查走短期稳定性 e^(w17·(G-3+w18))·S^-w19，且 Good/Easy
//    不降稳定性；难度按 -w6·(G-3) 线性阻尼 + w7 向 Easy 初值回归。
//    以上公式与 FSRS-6 规范（fsrs-rs / py-fsrs 6.x）逐项对过。
//  - 陷阱：包自带的 defaultParameters 是旧版权重
//    （0.2172、1.1771、3.2602、16.1507……），不是 FSRS-6 官方权重。
//    本文件禁止用 Scheduler() 默认值，一律显式传入
//    [SchedulerConfig.fsrs6Weights]（见下方）。
//  - 参考向量验证：见 test/p1_review_scheduler_test.dart。官方权重 +
//    保持率 0.9 + 空学习/重学步骤 + 关闭 fuzzing 时，全 Good 链间隔
//    为 2/11/46/90（90 天封顶）/90 天，稳定性 2.3065/10.96/46.26/
//    162.68，与 py-fsrs 6.3.1 独立算出的 FSRS-6 参考值一致；
//    Good、Good 后在到期日答 Again，稳定性 1.54、难度 7.40，
//    随后 Good 爬回间隔 2/5/12/28 天，与参考值一致。
// ────────────────────────────────────────────────────────────────────

import 'dart:convert';

import 'package:fsrs/fsrs.dart' as fsrs;

/// 正式复习的一次作答结果。只收 Again / Good（D3）。
///
/// Hard / Easy 不采集，不收置信度、不收自评难度——类型层面就只给
/// 两个值，调包时不可能误传。
enum ReviewResult {
  /// 答错：映射为 FSRS Rating.again。
  again,

  /// 答对：映射为 FSRS Rating.good。
  good,
}

extension _ReviewResultRating on ReviewResult {
  fsrs.Rating get rating => switch (this) {
        ReviewResult.again => fsrs.Rating.again,
        ReviewResult.good => fsrs.Rating.good,
      };
}

/// 一份统一的调度配置，带版本号与参数哈希（P0-1 / 第六轮补充）。
///
/// 权重 + 保持率 + 最大间隔 + 学习/重学步骤 + fuzzing 开关全部收在
/// 这里；每张卡只记自己用的 [configId]（见 [StoredCard.configId]）。
/// 以后升级权重或升 FSRS-7 必须新建一个配置版本走独立迁移，
/// 不得静默改变已有卡片的调度结果。
class SchedulerConfig {
  /// 官方 FSRS-6 默认权重（21 个，fsrs-rs / Anki 官方值）。
  ///
  /// 与 fsrs 2.0.1 包自带的默认值不同，禁止混用。
  static const List<double> fsrs6Weights = [
    0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722,
    0.1666, 0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425,
    0.0912, 0.0658, 0.1542,
  ];

  /// 当前唯一生效的配置版本：FSRS-6 官方权重 + 保持率 0.9 +
  /// 最大间隔 90 天 + 空学习/重学步骤 + fuzzing 开。
  const SchedulerConfig({
    this.configId = 'fsrs-6-v1',
    this.algorithmVersion = 'FSRS-6',
    this.version = 1,
    this.parameters = fsrs6Weights,
    this.desiredRetention = 0.9,
    this.maximumInterval = 90,
    this.learningSteps = const <Duration>[],
    this.relearningSteps = const <Duration>[],
    this.enableFuzzing = true,
  });

  /// 配置版本标识，写进每张卡；升级时换新值，旧卡不动。
  final String configId;

  /// 算法版本，本次锁定 'FSRS-6'。
  final String algorithmVersion;

  /// 配置版本号（同算法内调参时递增）。
  final int version;

  /// 21 个 FSRS 权重，必须显式传入，禁止用包默认值。
  final List<double> parameters;

  /// 目标保持率 0.9（D4）。
  final double desiredRetention;

  /// 最大间隔 90 天（D4；有考试日期取较小值是 P4 的应用层逻辑）。
  final int maximumInterval;

  /// 学习步骤：空。答对直接进 Review 状态算下次间隔（P0-2）。
  final List<Duration> learningSteps;

  /// 重学步骤：空。答错留在 Review 状态算下次间隔，不进短期重学（P0-2）。
  final List<Duration> relearningSteps;

  /// 是否给间隔加随机扰动。生产显式开（与上游默认一致，避免同批
  /// 卡片总在同一天到期）；测试用固定随机源或关：固定随机源经
  /// [FsrsReviewScheduler] 的 schedulerFactory 传入
  /// （包的 Scheduler.customRandom 是 @visibleForTesting，
  /// 只能在测试代码里调，不能写进 lib）。
  final bool enableFuzzing;

  /// 全部调度参数的稳定哈希（FNV-1a 64 位，纯 Dart 实现，不依赖
  /// hashCode，跨运行稳定）。用于核对“这张卡用的配置是不是
  /// 当前这份参数”，升级权重后哈希必变。
  String get configHash {
    final canonical = <String>[
      algorithmVersion,
      parameters.map((w) => w.toString()).join(','),
      desiredRetention.toString(),
      maximumInterval.toString(),
      'L:${learningSteps.map((d) => d.inSeconds).join(',')}',
      'R:${relearningSteps.map((d) => d.inSeconds).join(',')}',
      'F:$enableFuzzing',
    ].join('|');
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(canonical)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  /// 建一个按本配置配好的包内 Scheduler（生产路径）。
  /// 测试要固定随机源时不走这里，改走 [FsrsReviewScheduler]
  /// 的 schedulerFactory（包的 customRandom 只能在测试代码里调）。
  fsrs.Scheduler buildScheduler() {
    return fsrs.Scheduler(
      parameters: parameters,
      desiredRetention: desiredRetention,
      learningSteps: learningSteps,
      relearningSteps: relearningSteps,
      maximumInterval: maximumInterval,
      enableFuzzing: enableFuzzing,
    );
  }

  Map<String, dynamic> toMap() => {
        'configId': configId,
        'algorithmVersion': algorithmVersion,
        'version': version,
        'parameters': List<double>.from(parameters),
        'desiredRetention': desiredRetention,
        'maximumInterval': maximumInterval,
        'learningSteps': learningSteps.map((d) => d.inSeconds).toList(),
        'relearningSteps': relearningSteps.map((d) => d.inSeconds).toList(),
        'enableFuzzing': enableFuzzing,
      };

  static SchedulerConfig fromMap(Map<String, dynamic> map) {
    return SchedulerConfig(
      configId: map['configId'] as String,
      algorithmVersion: map['algorithmVersion'] as String,
      version: map['version'] as int,
      parameters: (map['parameters'] as List)
          .map((w) => (w as num).toDouble())
          .toList(),
      desiredRetention: (map['desiredRetention'] as num).toDouble(),
      maximumInterval: map['maximumInterval'] as int,
      learningSteps: (map['learningSteps'] as List)
          .map((s) => Duration(seconds: s as int))
          .toList(),
      relearningSteps: (map['relearningSteps'] as List)
          .map((s) => Duration(seconds: s as int))
          .toList(),
      enableFuzzing: map['enableFuzzing'] as bool,
    );
  }
}

/// 一张卡的持久化形态（P5 的 fsrs_cards 行对应物）。
///
/// 字段与实施方案 v2 §7 对齐：question_id 主键、card_id 包内整数 ID、
/// algorithm_version 记在配置里、scheduler_config_id、card_state_json
/// （这里是 [card]）、next_due_at（[card].due，须与 JSON 里的 due 一致）、
/// first_reviewed_at、updated_at 由 P5 落盘时写。
/// P1 先用 JSON（[toMap]/[fromMap]）跑通，P5 原样落表。
class StoredCard {
  StoredCard({
    required this.questionId,
    required this.cardId,
    required this.card,
    required this.configId,
    required this.firstReviewedAt,
  });

  /// 题目 ID（TEXT 主键，一题一卡）。
  final String questionId;

  /// 包内整数卡 ID，见 [CardStore.allocateCardId] 的映射规则。
  final int cardId;

  /// FSRS 完整状态（state/step/stability/difficulty/due/lastReview）。
  final fsrs.Card card;

  /// 建卡 / 最近一次调度用的配置版本（[SchedulerConfig.configId]）。
  final String configId;

  /// 首次完成正式作答的 UTC 时间；空 = 未开始正式复习。
  ///
  /// 这是区分“新卡”与“真正到期卡”的唯一依据：FSRS 新卡默认立即
  /// 到期，[ReviewScheduler.getDueQuestions] 只认
  /// firstReviewedAt 非空且 due 已到的卡。P5 落盘为
  /// fsrs_cards.first_reviewed_at（可空）。
  final DateTime? firstReviewedAt;

  StoredCard copyWithCard(fsrs.Card newCard, {DateTime? firstReviewedAt}) {
    return StoredCard(
      questionId: questionId,
      cardId: cardId,
      card: newCard,
      configId: configId,
      firstReviewedAt: firstReviewedAt ?? this.firstReviewedAt,
    );
  }

  Map<String, dynamic> toMap() => {
        'questionId': questionId,
        'cardId': cardId,
        'card': card.toMap(),
        'configId': configId,
        'firstReviewedAt': firstReviewedAt?.toIso8601String(),
      };

  static StoredCard fromMap(Map<String, dynamic> map) {
    return StoredCard(
      questionId: map['questionId'] as String,
      cardId: map['cardId'] as int,
      card: fsrs.Card.fromMap(
        (map['card'] as Map).cast<String, dynamic>(),
      ),
      configId: map['configId'] as String,
      firstReviewedAt: map['firstReviewedAt'] != null
          ? DateTime.parse(map['firstReviewedAt'] as String)
          : null,
    );
  }
}

/// 卡片持久化存储抽象。P1 给内存实现，P5 给 SQLite 实现
/// （fsrs_cards 表），调度器代码不改。
abstract class CardStore {
  /// 给 [questionId] 分配包内整数 cardId，同一题永远同一整数。
  ///
  /// 映射规则（P0-3 / 第六轮补充）：
  /// - 不用 Card.create() 的毫秒时间 ID（有碰撞风险）；
  /// - 不用 Dart hashCode（可能碰撞、跨运行不稳定）；
  /// - P1 内存实现：首次见到时按顺序分配 1、2、3……，一次运行内
  ///   稳定且可重建（按首次出现顺序重放即得同一映射）；
  /// - P5 SQLite 实现：必须用数据库分配的永久整数 ID（例如
  ///   fsrs_cards.card_id 由数据库序列分配并持久保存），删题 /
  ///   恢复 / 重导入时查已有的映射复用，不产生重复卡；
  /// - 内容修改重置状态时不改 cardId（见
  ///   [ReviewScheduler.resetQuestion]）。
  Future<int> allocateCardId(String questionId);

  Future<StoredCard?> load(String questionId);

  Future<void> save(StoredCard card);

  Future<List<StoredCard>> loadAll();

  /// 事件账本：[eventId] 是否已处理过（幂等，P0-4）。
  Future<bool> hasProcessedEvent(String eventId);

  /// 记下 [eventId] 已处理。只在卡片状态成功保存后调用，
  /// 保存失败时不记，调用方可重试。
  Future<void> markEventProcessed(String eventId);
}

/// [CardStore] 的内存实现，只给 P1 门禁测试与开发调试用。
///
/// 映射只活在进程内；P5 的 SQLite 实现接管后，同一接口、
/// 同一映射语义（永久整数 ID），调度器不用改。
class InMemoryCardStore implements CardStore {
  final Map<String, StoredCard> _cards = {};
  final Map<String, int> _cardIds = {};
  final Set<String> _processedEvents = {};
  int _nextCardId = 1;

  @override
  Future<int> allocateCardId(String questionId) async {
    return _cardIds.putIfAbsent(questionId, () => _nextCardId++);
  }

  @override
  Future<StoredCard?> load(String questionId) async => _cards[questionId];

  @override
  Future<void> save(StoredCard card) async {
    _cards[card.questionId] = card;
    _cardIds.putIfAbsent(card.questionId, () => card.cardId);
    if (card.cardId >= _nextCardId) {
      _nextCardId = card.cardId + 1;
    }
  }

  @override
  Future<List<StoredCard>> loadAll() async => _cards.values.toList();

  @override
  Future<bool> hasProcessedEvent(String eventId) async {
    return _processedEvents.contains(eventId);
  }

  @override
  Future<void> markEventProcessed(String eventId) async {
    _processedEvents.add(eventId);
  }
}

/// 复习调度器接口。业务代码只认这个接口，不直接碰 FSRS 包。
///
/// 时间口径：所有时间戳一律 UTC。传入的 [DateTime] 在入口处
/// 一律转 [.toUtc()] 再算；存出去的 due / lastReview / firstReviewedAt
/// 全是 UTC。每日按 Windows 本地日历日期切是 P4 应用层的事，
/// 不进这个接口。
///
/// 每日 50 道上限是应用层策略（D5），不写进接口；[getNewQuestions]
/// 的 [limit] 只是“这次最多取几道”，由调用方按当天额度传。
abstract class ReviewScheduler {
  /// 建新卡（未开始状态，不算到期）。
  ///
  /// 幂等：题已在池里时直接返回现有卡片，不建第二张（去重，
  /// 三个入口 + 详情页共用这一个入口）。
  Future<void> initializeQuestion(String questionId);

  /// 当前真正到期的题（due <= [now]），按 due 从早到晚排。
  ///
  /// 不含未释放新卡：firstReviewedAt 为空的卡即使 due 已到
  /// （FSRS 新卡默认立即到期）也不算到期。
  Future<List<String>> getDueQuestions(DateTime now);

  /// 当天可释放的新题（firstReviewedAt 为空、尚未开始正式复习），
  /// 按加入顺序排，最多 [limit] 道。[limit] <= 0 返回空。
  ///
  /// “释放”是 P4 的事：本接口只按加入顺序给候选，额度、跨日续接、
  /// 积压上限由调用方按 P4 规则决定取几道、何时取。
  Future<List<String>> getNewQuestions(int limit);

  /// 记一次正式作答，推进 FSRS 状态。
  ///
  /// - [result] 只有 Again / Good；专项练习不调这个方法，
  ///   不参与调度、不改到期时间（D3）。
  /// - [reviewedAt] 会先转 UTC 再算。
  /// - [eventId] 幂等：同一 eventId 重复提交只推进一次，
  ///   第二次直接返回、不改卡片状态。调用方（P2 核对页）须做到
  ///   重复点击 / 返回重进 / 崩溃恢复时复用同一个 eventId，
  ///   不能每次点击重生成。
  /// - 题尚未 initialize 时自动建卡再记（不抛错），
  ///   首次作答同时填 firstReviewedAt。
  /// - eventId 只在状态成功保存后才记；保存失败时调用方可重试。
  Future<void> recordAnswer(
    String questionId,
    ReviewResult result,
    DateTime reviewedAt,
    String eventId,
  );

  /// 内容实质修改后的重置钩子（P5 用，见实施方案 v2 §7）。
  ///
  /// 题干 / 选项 / 标准答案 / 题型变 → 调这个方法：FSRS 状态
  /// 重置为新卡，firstReviewedAt 清空，但 cardId 不变；
  /// 纯排版或分类标签改动不调。旧的作答事实记录保留在 attempts
  /// 里，不参与新版本重放。
  Future<void> resetQuestion(String questionId);
}

/// [ReviewScheduler] 的 FSRS-6 实现，封装层唯一认识 FSRS 包的地方。
class FsrsReviewScheduler implements ReviewScheduler {
  /// [schedulerFactory] 只给测试用：传入一个按 [config] 建 Scheduler
  /// 的工厂（例如用包的 Scheduler.customRandom 接固定种子 Random，
  /// 使 fuzzing 结果可重复）。生产调用不传，走 [config] 默认构造。
  FsrsReviewScheduler({
    required this.config,
    required this.store,
    fsrs.Scheduler Function(SchedulerConfig config)? schedulerFactory,
  }) : _scheduler =
            schedulerFactory?.call(config) ?? config.buildScheduler();

  final SchedulerConfig config;
  final CardStore store;
  final fsrs.Scheduler _scheduler;

  @override
  Future<void> initializeQuestion(String questionId) async {
    _requireQuestionId(questionId);
    if (await store.load(questionId) != null) return;
    final cardId = await store.allocateCardId(questionId);
    final nowUtc = DateTime.now().toUtc();
    await store.save(
      StoredCard(
        questionId: questionId,
        cardId: cardId,
        // 不用 Card.create()：毫秒时间 ID 有碰撞风险，见 CardStore 文档。
        // 新卡 due 即 now，属 FSRS 包行为；是否算到期由
        // firstReviewedAt 区分，不由 due 区分。
        card: fsrs.Card(cardId: cardId, due: nowUtc),
        configId: config.configId,
        firstReviewedAt: null,
      ),
    );
  }

  @override
  Future<List<String>> getDueQuestions(DateTime now) async {
    final nowUtc = now.toUtc();
    final all = await store.loadAll();
    final due = all
        .where(
          (c) => c.firstReviewedAt != null && !c.card.due.isAfter(nowUtc),
        )
        .toList()
      ..sort((a, b) {
        final byDue = a.card.due.compareTo(b.card.due);
        return byDue != 0 ? byDue : a.cardId.compareTo(b.cardId);
      });
    return due.map((c) => c.questionId).toList();
  }

  @override
  Future<List<String>> getNewQuestions(int limit) async {
    if (limit <= 0) return <String>[];
    final all = await store.loadAll();
    final fresh = all.where((c) => c.firstReviewedAt == null).toList()
      ..sort((a, b) => a.cardId.compareTo(b.cardId));
    return fresh.take(limit).map((c) => c.questionId).toList();
  }

  @override
  Future<void> recordAnswer(
    String questionId,
    ReviewResult result,
    DateTime reviewedAt,
    String eventId,
  ) async {
    _requireQuestionId(questionId);
    if (eventId.isEmpty) {
      throw ArgumentError.value(eventId, 'eventId', 'must not be empty');
    }
    // 幂等：重复提交直接返回，卡片状态不动。
    if (await store.hasProcessedEvent(eventId)) return;
    final reviewedUtc = reviewedAt.toUtc();
    var stored = await store.load(questionId);
    stored ??= await _initializeAndLoad(questionId);
    final reviewed = _scheduler.reviewCard(
      stored.card,
      result.rating,
      reviewDateTime: reviewedUtc,
    );
    await store.save(
      stored.copyWithCard(
        reviewed.card,
        firstReviewedAt: stored.firstReviewedAt ?? reviewedUtc,
      ),
    );
    // 只在保存成功后记事件；保存抛错时事件未记，调用方可重试。
    await store.markEventProcessed(eventId);
  }

  @override
  Future<void> resetQuestion(String questionId) async {
    _requireQuestionId(questionId);
    final stored = await store.load(questionId);
    if (stored == null) {
      await initializeQuestion(questionId);
      return;
    }
    // 新卡状态 + 清空 firstReviewedAt，但 cardId 保持不变。
    await store.save(
      StoredCard(
        questionId: questionId,
        cardId: stored.cardId,
        card: fsrs.Card(cardId: stored.cardId, due: DateTime.now().toUtc()),
        configId: config.configId,
        firstReviewedAt: null,
      ),
    );
  }

  Future<StoredCard> _initializeAndLoad(String questionId) async {
    await initializeQuestion(questionId);
    final stored = await store.load(questionId);
    if (stored == null) {
      throw StateError('failed to initialize card for $questionId');
    }
    return stored;
  }

  void _requireQuestionId(String questionId) {
    if (questionId.isEmpty) {
      throw ArgumentError.value(questionId, 'questionId', 'must not be empty');
    }
  }
}
