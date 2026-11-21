// 十五批 M1-B：切片写互斥 SliceWriteGuard（M1-DESIGN.md §6，D-178）。
//
// 本文件不是第二把锁：进程内切片写互斥只有一把，就是十四批 M2 已有的
// [FileLifecycleGuard]——它本身就是手写 Completer 队列的异步互斥
// （约 30 行锁代码，见 lib/data/file_lifecycle_guard.dart），
// 且全部切片写入入口已经共用它：
// - collect 切分 confirmSplit（lib/state/collect_notifier.dart，
//   烘焙页图与切片写盘均持锁）；
// - 详情页重新框选（lib/state/detail_notifier.dart，两处裁图写盘
//   均持锁）；图块裁图（lib/modules/ocr/figure_files.dart，均持锁）；
// - 备份导出读文件与恢复暂存区复制（lib/data/db_backup.dart，
//   持锁 + `_restoreMaintenance` 维护态）。
//
// 若 M1-B 另起一把独立互斥，它与上述写入入口互不串行化——快照读
// 切片与 confirmSplit 写切片仍可交错，互斥名存实亡；两锁嵌套还
// 有死锁风险（FileLifecycleGuard 是非重入锁）。因此 SliceWriteGuard
// 是同一把锁在导出侧的具名门面：快照经它取锁，即与全部既有写入
// 入口串行化；备份恢复期间开始的快照，终态哈希复核会因源文件变化
// 而失效（D-178），恢复无须另改代码。
//
// 附录 B 核对结论（2026-11-20，M1-B 动手前逐项核对代码，不凭记忆）：
// - 详情页渲染器图块合并逻辑：ocr_figures.dart 的 buildContentBlocks
//  （图块按 sequence_index / 锚点 / ε 吸附 / "h:s" 手动锚点插入序列），
//   导出复用同一套，不另写；
// - stem_correction.dart 无“题干被纠错过”的独立标记：可追溯性的
//   corrected 旗取 Question.ocrManualEdited（人工编辑标记）；
// - question_type 为 NULL 时的盘点判定：用 splitStem(md_results)
//   纯函数判定（见 ocr_content_snapshot.dart）。
import '../../data/file_lifecycle_guard.dart';

/// 切片写互斥（导出侧门面，锁本体为 [FileLifecycleGuard] 单例）。
///
/// 与 confirmSplit、详情页重新框选、图块裁图、备份/恢复共用同一把锁。
class SliceWriteGuard {
  const SliceWriteGuard();

  /// 全局唯一门面实例。
  static const SliceWriteGuard instance = SliceWriteGuard();

  /// 当前是否已被某一入口持有（测试与内部断言用）。
  bool get isLocked => FileLifecycleGuard.instance.isLocked;

  /// 对外入口：获取锁后执行 [action]，执行完释放锁。
  ///
  /// 非重入：同一持锁调用链内再次调用抛 [StateError]（FileLifecycleGuard
  /// 的 Zone 标记识别）；独立异步任务在已持锁时调用则进等待队列排队。
  /// action 抛异常时锁同样释放，排队的任务不受影响。
  ///
  /// 快照逐题持锁：单题的“读源切片 + 复制/裁剪 + 验哈希”在一次
  /// [withLock] 内完成；整批 50 道题不全程持锁（不阻塞用户重框选），
  /// 整批一致性由终态哈希复核保障（D-178，见 export_snapshot.dart）。
  Future<T> withLock<T>(Future<T> Function() action) =>
      FileLifecycleGuard.instance.withLock(action);
}
