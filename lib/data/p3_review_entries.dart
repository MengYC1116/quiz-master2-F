// P3：三个加题入口的纯逻辑（实施方案 v2 §5，D6–D8）。
//
// 本文件只放不碰数据库、不碰 UI 的纯函数与小记录类：
// - FSRS 批量入池的结果计数与文案（入口 1/2/3 共用）；
// - 专项练习抽题（入口 1“立即专项练习”与入口 3“开始专项练习”共用）：
//   随机打乱后按知识点轮流取，同一知识点尽量不连续集中；
// - 归档过滤（系统级边界）：归档题保留 FSRS 卡片，但不进新题/到期队列。
//
// 写库只走 [QuestionRepository.joinFsrsPool]（initializeQuestion 是
// 唯一入池入口）；会话启动只走 ReviewNotifier.startPracticeWithIds。
import 'dart:math';

import '../models/models.dart';

/// FSRS 批量入池的结果计数（三个入口 + 详情页共用口径）。
///
/// - [added]：本次新建卡片的题数；
/// - [skipped]：已在池里、本次跳过的题数（不建第二张卡）；
/// - [failed]：单题写入失败的题数；
/// - [missing]：调用方解析时已不在列表里的题数（仓库层不计，由调用方填）。
class FsrsBatchOutcome {
  const FsrsBatchOutcome({
    this.added = 0,
    this.skipped = 0,
    this.failed = 0,
    this.missing = 0,
  });

  final int added;
  final int skipped;
  final int failed;
  final int missing;

  /// 是否有任何题被处理过（新增或跳过或失败）。
  bool get touched => added + skipped + failed + missing > 0;
}

/// 批量入池的结果文案（D6–D8 要求：报“新增 N 道，M 道已跳过”，
// 不只弹“成功”；失败/不在列表的题也一次说清）。
String fsrsBatchMessage(FsrsBatchOutcome outcome) {
  final parts = <String>[];
  if (outcome.added > 0) parts.add('新增 ${outcome.added} 道');
  if (outcome.skipped > 0) parts.add('${outcome.skipped} 道已在复习，跳过');
  if (outcome.missing > 0) parts.add('${outcome.missing} 道已不在列表里，跳过');
  if (outcome.failed > 0) parts.add('${outcome.failed} 道加入失败，请重试');
  if (parts.isEmpty) return '没有题被加入复习';
  return parts.join('；');
}

/// 专项练习抽题（入口 1 与入口 3 共用；D3：只练不排，不碰 FSRS）。
///
/// - [candidates]：候选题（调用方已去重、已排除归档题）；
// - [count] <= 0 表示全部；> 0 时最多取 [count] 道；
// - 先整体打乱，再按“首个知识点”分组轮流取：同一知识点尽量不连续
//   集中；只有一个知识点（或题无知识点）时无法交错，原样返回。
// - 返回的题数 = min(count 或全部，候选数)；不改候选列表本身。
List<Question> pickPracticeQuestions({
  required List<Question> candidates,
  required int count,
  Random? random,
}) {
  final rng = random ?? Random();
  final shuffled = List<Question>.of(candidates)..shuffle(rng);
  // 按首个知识点分组；组内顺序已打乱，组间轮流取。
  final groups = <String, List<Question>>{};
  final groupOrder = <String>[];
  for (final q in shuffled) {
    final key = q.knowledgePointIds.isEmpty
        ? ''
        : q.knowledgePointIds.first;
    final g = groups.putIfAbsent(key, () => []);
    if (g.isEmpty) groupOrder.add(key);
    g.add(q);
  }
  final picked = <Question>[];
  final limit = count <= 0 ? shuffled.length : count;
  var round = 0;
  while (picked.length < limit) {
    var took = false;
    for (final key in groupOrder) {
      final g = groups[key]!;
      if (round < g.length) {
        picked.add(g[round]);
        took = true;
        if (picked.length >= limit) break;
      }
    }
    if (!took) break;
    round++;
  }
  return picked;
}

/// 归档过滤（系统级边界）：归档 = 暂停进新题和到期队列、保留历史状态。
///
/// FSRS 卡片不删（[poolIds] 原样保留历史）；只在“取当日可练/可释放
/// 的池子”时把归档题滤掉。P4 的释放队列取数时须走这里；P2 的旧队列
/// （buildDueQueue，已随 FSRS 全量迁移包2删除）本来就排除归档题。
Set<String> activePoolIds({
  required Set<String> poolIds,
  required Set<String> archivedIds,
}) {
  if (archivedIds.isEmpty) return Set<String>.of(poolIds);
  return poolIds.difference(archivedIds);
}
