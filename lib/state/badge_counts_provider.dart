import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/data_change_events.dart';
import '../models/models.dart';
import 'repository_provider.dart';

// ARCH-PLAN-A 第 4 阶段：左导航角标（方案 §四第 4 阶段）。
//
// `badgeCountsProvider` 是根节点常驻监听的 Provider，绝不 autoDispose
//（D-36 结论 ②：页面独占的 Provider 随页生死、回页重读；常驻监听的
// 不用 autoDispose——`settingsProvider` 同款）。根组件 `app.dart`
// `ref.watch` 它，角标数字与旧 `_refreshBadges` 同口径。
//
// 刷新只走 [DataChangeBus]：Repository 写成功、事务提交后发含 `badges`
// 的事件，本 Provider 收到后失效重算；无交集类别的事件忽略。旧
// `badgeVersion` 手动通知链（监听 + 7 处 `_refreshBadges` 调用）
// 已随本阶段删除。

/// 左导航角标计数的聚合值（与旧 `app.dart` `_refreshBadges` 的 5 次
/// 查询同口径，见 [BadgeCountsNotifier._readCounts]）。
class BadgeCounts {
  const BadgeCounts({
    this.collectBadge = 0,
    this.organizeBadge = 0,
    this.reviewBadge = 0,
    this.navRev = const {},
    this.navPending = const {},
    this.subjects = const [],
  });

  /// 收集角标（待框选 + 待整理）。
  final int collectBadge;

  /// 整理角标（待整理）。
  final int organizeBadge;

  /// 复习角标（要复习题数，`homeRevCounts` 各科之和，数题不数错因）。
  final int reviewBadge;

  /// 学科速览：每科待复习数。
  final Map<String, int> navRev;

  /// 学科速览：每科待整理数。
  final Map<String, int> navPending;

  /// 学科速览的学科列表（库里的 subjects 表，入库顺序；空表是合法状态）。
  final List<Subject> subjects;

  /// 待框选 + 修框中任务数（左导航收集角标用；沿用基线口径，未改——
  /// 原 `CollectPage.countPendingBox`，随角标收进本 Provider 后移入此处，
  /// 全项目只此一份，改口径只改这里）。
  static int countPendingBox(List<CollectTask> tasks) => tasks
      .where(
        (t) =>
            t.status == CollectStatus.needBox ||
            t.status == CollectStatus.boxing,
      )
      .length;

  static const BadgeCounts zero = BadgeCounts();

  @override
  bool operator ==(Object other) =>
      other is BadgeCounts &&
      collectBadge == other.collectBadge &&
      organizeBadge == other.organizeBadge &&
      reviewBadge == other.reviewBadge &&
      mapEquals(navRev, other.navRev) &&
      mapEquals(navPending, other.navPending) &&
      listEquals(subjects, other.subjects);

  @override
  int get hashCode => Object.hash(
        collectBadge,
        organizeBadge,
        reviewBadge,
        Object.hashAll(navRev.entries.map((e) => Object.hash(e.key, e.value))),
        Object.hashAll(
          navPending.entries.map((e) => Object.hash(e.key, e.value)),
        ),
        Object.hashAll(subjects),
      );
}

class BadgeCountsNotifier extends AsyncNotifier<BadgeCounts> {
  @override
  Future<BadgeCounts> build() async {
    // 先订阅、后首查（方案 §四数据变更事件机制第 3 条）：订阅建立后
    // 再读库，首查期间的写入不会漏刷新；Provider 销毁时取消订阅，
    // 销毁后不再接收事件。
    final subscription = DataChangeBus.instance.stream.listen((event) {
      if (event.kinds.contains(DataChangeKind.badges)) {
        ref.invalidateSelf();
      }
    });
    ref.onDispose(subscription.cancel);
    return _readCounts();
  }

  /// 旧 `_refreshBadges` 的 5 次串行查询改一次 `Future.wait`
  ///（行为不变，只是少等几轮），结果进 Provider 状态。
  Future<BadgeCounts> _readCounts() async {
    final repo = ref.read(repositoryProvider);
    final results = await Future.wait([
      repo.collectTasks(),
      repo.pendingOrganizeCount(),
      repo.homeRevCounts(),
      repo.pendingOrganizeBySubject(),
      repo.subjects(),
    ]);
    final tasks = results[0] as List<CollectTask>;
    final pendingOrganize = results[1] as int;
    final rev = results[2] as Map<String, int>;
    final pending = results[3] as Map<String, int>;
    final subjects = results[4] as List<Subject>;
    return BadgeCounts(
      collectBadge: BadgeCounts.countPendingBox(tasks) + pendingOrganize,
      organizeBadge: pendingOrganize,
      // B9-3：复习角标取 homeRevCounts 各科之和——每科已是
      // dueToday() 的题数（数题不数错因），和 = 要复习总数，
      // 与首页焦点卡“要复习的数量”同一数字。
      reviewBadge: rev.values.fold(0, (a, b) => a + b),
      navRev: rev,
      navPending: pending,
      // B8-1：空表不回退 Subject.all——新库建表时已预置三科
      //（db_schema `_seed`），表空只发生在用户删光学科后，
      // 此时速览必须为空，摆预设三科就是截图里的幽灵行。
      subjects: subjects,
    );
  }
}

/// 左导航角标 Provider：根组件常驻监听，不 autoDispose（D-36 结论 ②）。
final badgeCountsProvider =
    AsyncNotifierProvider<BadgeCountsNotifier, BadgeCounts>(
  BadgeCountsNotifier.new,
);
