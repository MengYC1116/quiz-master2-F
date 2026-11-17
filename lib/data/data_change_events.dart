import 'dart:async';

// ARCH-PLAN-A 第 4 阶段：数据变更事件机制（方案 §四“数据变更事件机制”）。
//
// 纯 Dart 文件，不依赖 `flutter_riverpod`——数据层（`lib/data/`）
// 不 import riverpod（方案 §六-7 白名单），跨层通知只走这条总线。
//
// 事件只描述“什么变了”，不携带新数据——订阅方收到后自己重读 SQLite，
// 事件本身不做数据搬运。发布是“写后”不是“写前”：写入成功、事务提交
// 后才 emit；写入抛异常或事务回滚时不 emit。
//
// FR-31（W2-14）：当前唯一订阅方是 `badgeCountsProvider`，且只消费
// `DataChangeKind.badges`（`lib/state/badge_counts_provider.dart:92`）。
// 其余四种 kind（questions / subjects / reviewRecords / settings）
// 目前没有任何订阅方，是为将来订阅方预留的元数据——各页现靠
// autoDispose“回页重建重读”刷新，不依赖总线。将来给某一 kind 加
// 订阅方时，把该页的刷新时序纳入回归（见 W2-01 角标竞态的教训：
// 发了事件但无人校验时序就是盲区）。
// 一次独立写入或一次批量提交只发一个事件，该事件的 `kinds` 集合必须
// 包含本次写入影响的全部类别；备份恢复只发一个事件，`kinds` 为全部
// 五类。写入方法—事件类别对照表见
// `docs/ui-replication/A-READING-GUIDE.md` §六，新增写入方法时必须
// 同步补表。

/// 数据变更的类别（订阅方按集合交集判断是否重读）。
enum DataChangeKind {
  /// 左导航角标相关（收集/整理/复习角标、学科速览）。
  badges,

  /// 复习记录（错因记录、补救历史、自查历史、复查日）。
  reviewRecords,

  /// 学科 / 文件夹 / 标签 / 试卷 / 知识点（学科管理页与错题本目录）。
  subjects,

  /// 题目行（标题、学科、文件夹归属、标签、归档/收藏、是否已整理）。
  questions,

  /// 设置表（应用设置、考试事件、备份失败标志）。
  settings,
}

/// 一次写入对应的变更事件。
class DataChangeEvent {
  const DataChangeEvent({required this.kinds, this.questionId});

  /// 本次写入影响的全部类别。
  final Set<DataChangeKind> kinds;

  /// 仅当事件只影响单题时提供（整类数据变化、批量写入、备份恢复时为空）。
  final String? questionId;
}

/// 数据变更总线：应用内单例 broadcast 流。
///
/// 批量提交用 [scope] 包起来：作用域内发出的全部事件在作用域结束时
/// 合并成一个事件发出（`kinds` 取并集；只含一个事件时保留它的
/// `questionId`，多个时置空——影响多题）；作用域内一个事件都没发
/// 出时不发。`scope` 可嵌套（只在最外层结束时合并发出一次），body
/// 抛异常时已提交的写入对应的事件仍发出、异常继续外抛。
class DataChangeBus {
  DataChangeBus._();

  static final DataChangeBus instance = DataChangeBus._();

  final _controller = StreamController<DataChangeEvent>.broadcast();

  Stream<DataChangeEvent> get stream => _controller.stream;

  int _scopeDepth = 0;
  final List<DataChangeEvent> _buffered = [];

  void emit(DataChangeEvent event) {
    if (_scopeDepth > 0) {
      _buffered.add(event);
      return;
    }
    if (!_controller.isClosed) _controller.add(event);
  }

  Future<T> scope<T>(Future<T> Function() body) async {
    _scopeDepth++;
    try {
      return await body();
    } finally {
      _scopeDepth--;
      if (_scopeDepth == 0 && _buffered.isNotEmpty) {
        final kinds = <DataChangeKind>{
          for (final e in _buffered) ...e.kinds,
        };
        final questionId =
            _buffered.length == 1 ? _buffered.first.questionId : null;
        _buffered.clear();
        if (!_controller.isClosed) {
          _controller.add(DataChangeEvent(kinds: kinds, questionId: questionId));
        }
      }
    }
  }
}
