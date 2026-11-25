// P1 门禁测试：调度器接口 + FSRS-6 接入（shuati-implementation-plan-v2 §3、§8）。
//
// 参考向量来源：py-fsrs 6.3.1（FSRS-6 官方 Python 实现）算出的值，
// 见 https://www.taalhammer.com/how-fsrs-works/ “What happens after
// each review”一节：全 Good 链稳定性 2.3/11.0/46.3/162.9 天、
// 间隔 2/11/46/163 天；Good、Good 后到期日答 Again，稳定性 11→1.5、
// 难度 2.1→7.4，随后 Good 爬回间隔 2/5/12/28 天。
// 本测试用官方权重 + 保持率 0.9 + 空学习/重学步骤 + 关闭 fuzzing
// 复现同一条链：若包实现与参考实现不一致，这里会立刻失败。
// 注意：包自带测试 test_review_card 的向量 [0,4,14,45,135,372…] 是
// 用包默认旧权重算的，不能拿来当 FSRS-6 参考向量。
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' as fsrs;
import 'package:quiz_master2/data/review_scheduler.dart';

/// 官方 FSRS-6 权重（与 SchedulerConfig.fsrs6Weights 逐项对照用）。
const fsrs6Weights = [
  0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722,
  0.1666, 0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425,
  0.0912, 0.0658, 0.1542,
];

/// 门禁测试专用配置：与生产配置同一套参数，但 fuzzing 关，
/// 保证间隔可重复比对。
const testConfig = SchedulerConfig(enableFuzzing: false);

final _t0 = DateTime.utc(2022, 11, 29, 12, 30);

FsrsReviewScheduler newScheduler({InMemoryCardStore? store}) {
  return FsrsReviewScheduler(
    config: testConfig,
    store: store ?? InMemoryCardStore(),
  );
}

/// 在 due 日作答 [ratings]，返回每一步的间隔天数与稳定性。
/// eventId 全局递增，保证同一调度器上两次调用也不会撞幂等账本。
int _evtCounter = 0;

Future<({List<int> intervals, List<double> stabilities})> reviewChain(
  FsrsReviewScheduler scheduler,
  InMemoryCardStore store,
  String questionId,
  List<ReviewResult> ratings, {
  DateTime? startAt,
}) async {
  final intervals = <int>[];
  final stabilities = <double>[];
  var at = startAt ?? _t0;
  for (final result in ratings) {
    await scheduler.recordAnswer(
      questionId,
      result,
      at,
      'evt-$questionId-${_evtCounter++}',
    );
    final stored = (await store.load(questionId))!;
    intervals.add(
      stored.card.due.difference(stored.card.lastReview!).inDays,
    );
    stabilities.add(stored.card.stability!);
    at = stored.card.due;
  }
  return (intervals: intervals, stabilities: stabilities);
}

void main() {
  group('P1 配置', () {
    test('显式传入官方 FSRS-6 21 个权重，禁止用包默认值', () {
      expect(SchedulerConfig.fsrs6Weights, fsrs6Weights);
      expect(SchedulerConfig.fsrs6Weights.length, 21);
      // 包默认值是旧版权重（0.2172、1.1771、3.2602……），必须不同。
      expect(fsrs.defaultParameters, isNot(SchedulerConfig.fsrs6Weights));
      expect(fsrs.defaultParameters.first, 0.2172);
      expect(SchedulerConfig.fsrs6Weights.first, 0.212);
    });

    test('保持率 0.9、最大间隔 90 天、学习/重学步骤都空、fuzzing 显式设置', () {
      const config = SchedulerConfig();
      expect(config.algorithmVersion, 'FSRS-6');
      expect(config.desiredRetention, 0.9);
      expect(config.maximumInterval, 90);
      expect(config.learningSteps, isEmpty);
      expect(config.relearningSteps, isEmpty);
      // fuzzing 开关必须显式出现在配置里（生产开，测试关/固定随机源）。
      expect(config.toMap()['enableFuzzing'], isTrue);
      expect(testConfig.enableFuzzing, isFalse);
    });

    test('配置带版本号与参数哈希，改权重哈希必变', () {
      const config = SchedulerConfig();
      expect(config.configId, 'fsrs-6-v1');
      expect(config.version, 1);
      expect(config.configHash, isNotEmpty);
      expect(config.configHash, SchedulerConfig().configHash);
      final changed = SchedulerConfig(
        parameters: [...SchedulerConfig.fsrs6Weights]..[0] = 0.213,
      );
      expect(changed.configHash, isNot(config.configHash));
      final noFuzz = SchedulerConfig(enableFuzzing: false);
      expect(noFuzz.configHash, isNot(config.configHash));
    });

    test('配置 JSON 往返一致', () {
      const config = SchedulerConfig();
      final restored = SchedulerConfig.fromMap(
        json.decode(json.encode(config.toMap())) as Map<String, dynamic>,
      );
      expect(restored.toMap(), config.toMap());
      expect(restored.configHash, config.configHash);
    });
  });

  group('P1 官方 FSRS-6 参考向量', () {
    test('全 Good 链：间隔 2/11/46/90/90（封顶），稳定性与参考实现一致', () async {
      final store = InMemoryCardStore();
      final scheduler = newScheduler(store: store);
      await scheduler.initializeQuestion('q1');
      final chain = await reviewChain(
        scheduler,
        store,
        'q1',
        List.filled(5, ReviewResult.good),
      );
      expect(chain.intervals, [2, 11, 46, 90, 90]);
      expect(chain.stabilities[0], closeTo(2.3065, 0.0001));
      expect(chain.stabilities[1], closeTo(10.96, 0.05));
      expect(chain.stabilities[2], closeTo(46.26, 0.1));
      expect(chain.stabilities[3], closeTo(162.68, 0.5));
      final stored = (await store.load('q1'))!;
      expect(stored.card.state, fsrs.State.review);
      expect(stored.card.step, isNull);
    });

    test('Again 后 Good：稳定性 11→1.5、难度 2.1→7.4，爬回 2/5/12/28', () async {
      final store = InMemoryCardStore();
      final scheduler = newScheduler(store: store);
      await scheduler.initializeQuestion('q1');
      await reviewChain(
        scheduler,
        store,
        'q1',
        [ReviewResult.good, ReviewResult.good],
      );
      final before = (await store.load('q1'))!;
      expect(before.card.stability!, closeTo(10.96, 0.05));
      expect(before.card.difficulty!, closeTo(2.12, 0.05));
      // 在到期日答 Again。
      await scheduler.recordAnswer(
        'q1',
        ReviewResult.again,
        before.card.due,
        'evt-q1-lapse',
      );
      final lapsed = (await store.load('q1'))!;
      expect(lapsed.card.stability!, closeTo(1.54, 0.1));
      expect(lapsed.card.difficulty!, closeTo(7.40, 0.05));
      expect(
        lapsed.card.due.difference(lapsed.card.lastReview!).inDays,
        2,
      );
      // 答错不进重学：空重学步骤，仍留在 Review 状态。
      expect(lapsed.card.state, fsrs.State.review);
      final climb = await reviewChain(
        scheduler,
        store,
        'q1',
        List.filled(3, ReviewResult.good),
        startAt: lapsed.card.due,
      );
      expect(climb.intervals, [5, 12, 28]);
    });

    test('初始化：新卡状态正确，稳定性/难度为空', () async {
      final store = InMemoryCardStore();
      final scheduler = newScheduler(store: store);
      await scheduler.initializeQuestion('q1');
      final stored = (await store.load('q1'))!;
      expect(stored.card.state, fsrs.State.learning);
      expect(stored.card.stability, isNull);
      expect(stored.card.difficulty, isNull);
      expect(stored.firstReviewedAt, isNull);
      expect(stored.configId, 'fsrs-6-v1');
      expect(stored.card.due.isUtc, isTrue);
    });
  });

  group('P1 场景覆盖', () {
    test('连续 Again：间隔恒为 1 天，状态 stays Review，稳定性不为负', () async {
      final store = InMemoryCardStore();
      final scheduler = newScheduler(store: store);
      await scheduler.initializeQuestion('q1');
      final chain = await reviewChain(
        scheduler,
        store,
        'q1',
        List.filled(5, ReviewResult.again),
      );
      expect(chain.intervals, [1, 1, 1, 1, 1]);
      expect(chain.stabilities.first, closeTo(0.212, 0.0001));
      for (final s in chain.stabilities) {
        expect(s, greaterThanOrEqualTo(0.001));
      }
      final stored = (await store.load('q1'))!;
      expect(stored.card.state, fsrs.State.review);
      expect(stored.card.difficulty!, lessThanOrEqualTo(10.0));
    });

    test('连续 Good：间隔单调递增', () async {
      final store = InMemoryCardStore();
      final scheduler = newScheduler(store: store);
      await scheduler.initializeQuestion('q1');
      final chain = await reviewChain(
        scheduler,
        store,
        'q1',
        List.filled(4, ReviewResult.good),
      );
      expect(chain.intervals, [2, 11, 46, 90]);
      for (var i = 1; i < chain.stabilities.length; i++) {
        expect(chain.stabilities[i], greaterThan(chain.stabilities[i - 1]));
      }
    });

    test('Again 后 Good：间隔回升，不重置为新卡', () async {
      final store = InMemoryCardStore();
      final scheduler = newScheduler(store: store);
      await scheduler.initializeQuestion('q1');
      final chain = await reviewChain(
        scheduler,
        store,
        'q1',
        [ReviewResult.again, ReviewResult.good, ReviewResult.good],
      );
      // 注意：第三个间隔是 6 不是 5——首答 Again 时稳定性只有 0.212，
      // 与“Good、Good 后 Again”（稳定性 1.54 起步）的爬回链不同，
      // 两者起点不同，FSRS-6 公式算出的值本来就不同。
      expect(chain.intervals, [1, 2, 6]);
      final stored = (await store.load('q1'))!;
      expect(stored.card.state, fsrs.State.review);
      expect(stored.firstReviewedAt, _t0);
    });

    test('逾期多日：Good 与 Again 都算出合法间隔', () async {
      final store = InMemoryCardStore();
      final scheduler = newScheduler(store: store);
      await scheduler.initializeQuestion('q1');
      await reviewChain(
        scheduler,
        store,
        'q1',
        [ReviewResult.good, ReviewResult.good, ReviewResult.good],
      );
      final due = (await store.load('q1'))!.card.due;
      final overdueAt = due.add(const Duration(days: 30));
      await scheduler.recordAnswer(
        'q1',
        ReviewResult.good,
        overdueAt,
        'evt-q1-overdue-good',
      );
      final good = (await store.load('q1'))!;
      final goodIvl = good.card.due.difference(good.card.lastReview!).inDays;
      expect(goodIvl, inInclusiveRange(1, 90));
      expect(good.card.stability!, greaterThan(0));

      final store2 = InMemoryCardStore();
      final scheduler2 = newScheduler(store: store2);
      await scheduler2.initializeQuestion('q2');
      await reviewChain(
        scheduler2,
        store2,
        'q2',
        [ReviewResult.good, ReviewResult.good, ReviewResult.good],
      );
      final due2 = (await store2.load('q2'))!.card.due;
      await scheduler2.recordAnswer(
        'q2',
        ReviewResult.again,
        due2.add(const Duration(days: 30)),
        'evt-q2-overdue-again',
      );
      final again = (await store2.load('q2'))!;
      final againIvl =
          again.card.due.difference(again.card.lastReview!).inDays;
      expect(againIvl, inInclusiveRange(1, 90));
      expect(againIvl, lessThan(goodIvl));
    });

    test('当天重复作答：同日再答不崩，间隔不为负、不越界', () async {
      final store = InMemoryCardStore();
      final scheduler = newScheduler(store: store);
      await scheduler.initializeQuestion('q1');
      await scheduler.recordAnswer(
        'q1',
        ReviewResult.good,
        _t0,
        'evt-q1-first',
      );
      // 同一天内再答一次（不同事件）：走短期稳定性分支。
      await scheduler.recordAnswer(
        'q1',
        ReviewResult.good,
        _t0.add(const Duration(hours: 2)),
        'evt-q1-sameday',
      );
      final stored = (await store.load('q1'))!;
      final ivl = stored.card.due.difference(stored.card.lastReview!).inDays;
      expect(ivl, inInclusiveRange(1, 90));
      expect(stored.card.due.isAfter(stored.card.lastReview!), isTrue);
      expect(stored.card.stability!, greaterThanOrEqualTo(0.001));
    });

    test('同一 event_id 重复提交只推进一次', () async {
      final store = InMemoryCardStore();
      final scheduler = newScheduler(store: store);
      await scheduler.initializeQuestion('q1');
      await scheduler.recordAnswer(
        'q1',
        ReviewResult.good,
        _t0,
        'evt-dup',
      );
      final first = (await store.load('q1'))!;
      // 同一 eventId、换结果、换时间重提：必须原样不动。
      await scheduler.recordAnswer(
        'q1',
        ReviewResult.again,
        _t0.add(const Duration(days: 1)),
        'evt-dup',
      );
      final second = (await store.load('q1'))!;
      expect(second.card.toMap(), first.card.toMap());
      expect(second.firstReviewedAt, first.firstReviewedAt);
      // 不同 eventId 则正常推进。
      await scheduler.recordAnswer(
        'q1',
        ReviewResult.good,
        first.card.due,
        'evt-next',
      );
      final third = (await store.load('q1'))!;
      expect(third.card.toMap(), isNot(first.card.toMap()));
    });

    test('100 次连续 Good：间隔恒在 [1, 90]，due 永不早于 lastReview', () async {
      final store = InMemoryCardStore();
      final scheduler = newScheduler(store: store);
      await scheduler.initializeQuestion('q1');
      var at = _t0;
      for (var i = 0; i < 100; i++) {
        await scheduler.recordAnswer(
          'q1',
          ReviewResult.good,
          at,
          'evt-q1-$i',
        );
        final stored = (await store.load('q1'))!;
        final ivl =
            stored.card.due.difference(stored.card.lastReview!).inDays;
        expect(ivl, inInclusiveRange(1, 90), reason: '第 $i 次作答间隔越界');
        expect(
          stored.card.due.isAfter(stored.card.lastReview!) ||
              stored.card.due.isAtSameMomentAs(stored.card.lastReview!),
          isTrue,
        );
        expect(stored.card.stability!, greaterThan(0));
        expect(stored.card.difficulty, inInclusiveRange(1.0, 10.0));
        at = stored.card.due;
      }
    });
  });

  group('P1 新卡隔离 / 到期 / 释放', () {
    test('新卡不算到期：initialize 后 getDueQuestions 为空，getNewQuestions 有', () async {
      final store = InMemoryCardStore();
      final scheduler = newScheduler(store: store);
      await scheduler.initializeQuestion('q1');
      await scheduler.initializeQuestion('q2');
      expect(await scheduler.getDueQuestions(_t0), isEmpty);
      // 即使 now 远在 due 之后，新卡仍不算到期。
      expect(
        await scheduler.getDueQuestions(_t0.add(const Duration(days: 365))),
        isEmpty,
      );
      expect(await scheduler.getNewQuestions(10), ['q1', 'q2']);
    });

    test('首次正式作答后离开新题列，到期后进入到期列', () async {
      final store = InMemoryCardStore();
      final scheduler = newScheduler(store: store);
      await scheduler.initializeQuestion('q1');
      await scheduler.recordAnswer('q1', ReviewResult.good, _t0, 'evt-q1');
      expect(await scheduler.getNewQuestions(10), isEmpty);
      final stored = (await store.load('q1'))!;
      expect(stored.firstReviewedAt, _t0);
      // due 前不算到期，due 当日算到期。
      expect(
        await scheduler.getDueQuestions(stored.card.due.subtract(
          const Duration(days: 1),
        )),
        isEmpty,
      );
      expect(await scheduler.getDueQuestions(stored.card.due), ['q1']);
    });

    test('getNewQuestions 按加入顺序、受 limit 限制；limit<=0 为空', () async {
      final store = InMemoryCardStore();
      final scheduler = newScheduler(store: store);
      for (final id in ['q1', 'q2', 'q3']) {
        await scheduler.initializeQuestion(id);
      }
      expect(await scheduler.getNewQuestions(2), ['q1', 'q2']);
      expect(await scheduler.getNewQuestions(0), isEmpty);
      expect(await scheduler.getNewQuestions(-5), isEmpty);
    });

    test('getDueQuestions 按 due 从早到晚排', () async {
      final store = InMemoryCardStore();
      final scheduler = newScheduler(store: store);
      await scheduler.initializeQuestion('qLate');
      await scheduler.initializeQuestion('qEarly');
      await scheduler.recordAnswer(
        'qLate',
        ReviewResult.good,
        _t0,
        'evt-late',
      );
      await scheduler.recordAnswer(
        'qEarly',
        ReviewResult.again,
        _t0,
        'evt-early',
      );
      // Again 间隔 1 天，Good 间隔 2 天。
      expect(
        await scheduler.getDueQuestions(_t0.add(const Duration(days: 3))),
        ['qEarly', 'qLate'],
      );
    });

    test('initializeQuestion 幂等：重复初始化不重置已有状态', () async {
      final store = InMemoryCardStore();
      final scheduler = newScheduler(store: store);
      await scheduler.initializeQuestion('q1');
      await scheduler.recordAnswer('q1', ReviewResult.good, _t0, 'evt-q1');
      final before = (await store.load('q1'))!;
      await scheduler.initializeQuestion('q1');
      final after = (await store.load('q1'))!;
      expect(after.card.toMap(), before.card.toMap());
      expect(after.cardId, before.cardId);
    });

    test('recordAnswer 未初始化时自动建卡再记', () async {
      final store = InMemoryCardStore();
      final scheduler = newScheduler(store: store);
      await scheduler.recordAnswer('q9', ReviewResult.good, _t0, 'evt-q9');
      final stored = (await store.load('q9'))!;
      expect(stored.firstReviewedAt, _t0);
      expect(stored.card.state, fsrs.State.review);
    });
  });

  group('P1 Card ID 映射', () {
    test('同一题永远同一整数，不同题不同整数；不用毫秒时间 ID 与 hashCode', () async {
      final store = InMemoryCardStore();
      final scheduler = newScheduler(store: store);
      await scheduler.initializeQuestion('q1');
      await scheduler.initializeQuestion('q2');
      await scheduler.recordAnswer('q1', ReviewResult.good, _t0, 'evt-q1');
      final c1 = (await store.load('q1'))!;
      final c2 = (await store.load('q2'))!;
      expect(c1.cardId, greaterThan(0));
      expect(c2.cardId, greaterThan(0));
      expect(c1.cardId, isNot(c2.cardId));
      // 不是毫秒时间戳量级。
      expect(c1.cardId, lessThan(1000000));
      expect(c2.cardId, lessThan(1000000));
      // 多次读取、多次作答后仍同一 ID。
      await scheduler.recordAnswer(
        'q1',
        ReviewResult.good,
        c1.card.due,
        'evt-q1-2',
      );
      expect((await store.load('q1'))!.cardId, c1.cardId);
      // 内存实现按首次出现顺序分配：q1=1、q2=2。
      expect(c1.cardId, 1);
      expect(c2.cardId, 2);
    });

    test('resetQuestion 重置状态但不改 cardId', () async {
      final store = InMemoryCardStore();
      final scheduler = newScheduler(store: store);
      await scheduler.initializeQuestion('q1');
      await scheduler.recordAnswer('q1', ReviewResult.good, _t0, 'evt-q1');
      final before = (await store.load('q1'))!;
      await scheduler.resetQuestion('q1');
      final after = (await store.load('q1'))!;
      expect(after.cardId, before.cardId);
      expect(after.card.state, fsrs.State.learning);
      expect(after.card.stability, isNull);
      expect(after.firstReviewedAt, isNull);
      expect(await scheduler.getNewQuestions(10), ['q1']);
      expect(await scheduler.getDueQuestions(_t0), isEmpty);
    });
  });

  group('P1 时区 / UTC / 序列化', () {
    test('reviewedAt 非 UTC 也先转 UTC 再算，存出去全是 UTC', () async {
      final store = InMemoryCardStore();
      final scheduler = newScheduler(store: store);
      await scheduler.initializeQuestion('q1');
      // 本地时间（非 UTC）传入。
      final local = DateTime(2022, 11, 29, 20, 30);
      expect(local.isUtc, isFalse);
      await scheduler.recordAnswer('q1', ReviewResult.good, local, 'evt-q1');
      final stored = (await store.load('q1'))!;
      expect(stored.card.lastReview!.isUtc, isTrue);
      expect(stored.card.due.isUtc, isTrue);
      expect(stored.firstReviewedAt!.isUtc, isTrue);
      expect(stored.card.lastReview, local.toUtc());
    });

    test('getDueQuestions 接受本地时间，内部转 UTC 比较', () async {
      final store = InMemoryCardStore();
      final scheduler = newScheduler(store: store);
      await scheduler.initializeQuestion('q1');
      await scheduler.recordAnswer('q1', ReviewResult.good, _t0, 'evt-q1');
      final stored = (await store.load('q1'))!;
      // due 是 UTC 2022-12-01 12:30；本地时间写同一时刻。
      final localDue = stored.card.due.toLocal();
      expect(await scheduler.getDueQuestions(localDue), ['q1']);
    });

    test('StoredCard JSON 往返一致，恢复后调度结果一致', () async {
      final store = InMemoryCardStore();
      final scheduler = newScheduler(store: store);
      await scheduler.initializeQuestion('q1');
      await reviewChain(
        scheduler,
        store,
        'q1',
        [ReviewResult.good, ReviewResult.good, ReviewResult.again],
      );
      final original = (await store.load('q1'))!;
      final jsonText = json.encode(original.toMap());
      final restored = StoredCard.fromMap(
        json.decode(jsonText) as Map<String, dynamic>,
      );
      expect(restored.toMap(), original.toMap());
      expect(restored.card, original.card);
      expect(restored.cardId, original.cardId);
      expect(restored.firstReviewedAt, original.firstReviewedAt);
      // 恢复出的卡继续调度，与原卡同一时刻同一作答结果一致。
      final store2 = InMemoryCardStore();
      await store2.save(restored);
      final scheduler2 = newScheduler(store: store2);
      final at = original.card.due;
      await scheduler2.recordAnswer(
        'q1',
        ReviewResult.good,
        at,
        'evt-restore',
      );
      final resumed = (await store2.load('q1'))!;
      final store3 = InMemoryCardStore();
      await store3.save(original);
      final scheduler3 = newScheduler(store: store3);
      await scheduler3.recordAnswer(
        'q1',
        ReviewResult.good,
        at,
        'evt-restore',
      );
      final direct = (await store3.load('q1'))!;
      expect(resumed.card.toMap(), direct.card.toMap());
    });

    test('Scheduler JSON 往返一致（包内序列化能力）', () {
      final scheduler = testConfig.buildScheduler();
      final restored = fsrs.Scheduler.fromMap(
        json.decode(json.encode(scheduler.toMap())) as Map<String, dynamic>,
      );
      expect(restored, scheduler);
      expect(restored.toMap(), scheduler.toMap());
    });
  });

  group('P1 Fuzzing', () {
    test('固定随机源：同一 seed 两次跑结果完全一致', () async {
      Future<List<int>> runWithSeed(int seed) async {
        final store = InMemoryCardStore();
        final scheduler = FsrsReviewScheduler(
          config: const SchedulerConfig(enableFuzzing: true),
          store: store,
          // customRandom 是 @visibleForTesting，只能在测试代码里调。
          schedulerFactory: (c) => fsrs.Scheduler.customRandom(
            Random(seed),
            parameters: c.parameters,
            desiredRetention: c.desiredRetention,
            learningSteps: c.learningSteps,
            relearningSteps: c.relearningSteps,
            maximumInterval: c.maximumInterval,
            enableFuzzing: c.enableFuzzing,
          ),
        );
        await scheduler.initializeQuestion('q1');
        final chain = await reviewChain(
          scheduler,
          store,
          'q1',
          List.filled(6, ReviewResult.good),
        );
        return chain.intervals;
      }

      final first = await runWithSeed(42);
      final second = await runWithSeed(42);
      expect(second, first);
      // fuzzing 只扰动 >= 2.5 天的间隔，首个 2 天间隔不受影响。
      expect(first.first, 2);
    });

    test('关闭 fuzzing：多次跑结果完全一致', () async {
      Future<List<int>> run() async {
        final store = InMemoryCardStore();
        final scheduler = newScheduler(store: store);
        await scheduler.initializeQuestion('q1');
        final chain = await reviewChain(
          scheduler,
          store,
          'q1',
          List.filled(6, ReviewResult.good),
        );
        return chain.intervals;
      }

      expect(await run(), await run());
    });
  });

  group('P1 参数校验', () {
    test('空 questionId / 空 eventId 抛错', () async {
      final scheduler = newScheduler();
      expect(
        () => scheduler.initializeQuestion(''),
        throwsArgumentError,
      );
      expect(
        () => scheduler.recordAnswer('q1', ReviewResult.good, _t0, ''),
        throwsArgumentError,
      );
    });
  });
}
