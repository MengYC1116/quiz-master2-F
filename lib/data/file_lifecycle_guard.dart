// 十四批 M2 P1-B：文件生命周期协调机制——进程内统一文件操作锁 +
// 待提交文件登记集合 + 备份暂存区占用。
//
// 前提（GPT 裁定条件，M2 代码审计结论，见本文件末尾注释与 M2 汇报）：
// 应用为单进程、单 isolate 文件操作——全部文件操作（OCR worker、
// 备份导出、删题、孤儿清理、导入、恢复）都发生在主 isolate 的异步
// 任务里；代码库里没有任何 `Isolate.spawn` / `compute` 调用，
// 也没有后台进程或独立应用实例操作同一批数据文件（数据目录由
// AppDatabase 单例持有，同一时间只允许一个应用实例打开同一数据库；
// M5 P1-2 起该前提由 main.dart + services/single_instance.dart 的
// OS 级单实例锁执行，见 docs/decision-log.md D-145）。
// 满足该前提，一把进程内异步互斥锁足以串行化三个入口，不做跨进程
// 文件锁、不引入文件租约。
//
// 锁的管辖范围（写死）：
// - 锁只保护“删文件 / 读文件”动作本身，不保护数据库事务。数据库
//   事务（删记录、写引用）不持锁，避免长事务持锁阻塞其他入口；
//   物理删文件与读文件（备份导出读文件）动作必须持锁。
// - 三个入口全部经该锁协调：物理删除、孤儿清理扫描+删除、
//   备份导出读文件（备份只读暂存区副本，见 db_backup.dart）。
//
// P2 约束 1（锁不嵌套死锁）：锁是非重入互斥锁。区分对外入口
// （负责获取锁：[withLock] / [deleteFile] / [deleteDirectory]）与
// 内部实现（明确要求调用者已经持锁：[requireLocked] +
// [deleteFileLocked] / [deleteDirectoryLocked]）。已持有锁时内部
// 调用的物理删除函数不得再次申请同一把锁——同一持锁调用链再次调
// [withLock] 抛 [StateError]（Zone 标记识别，不静默排队死锁）；
// 独立异步任务在已持锁时调 [withLock] 进等待队列排队，不抛错。
// 任何“内部函数再取锁”的写法都是缺陷，代码审计时按调用图逐条核对。
// （十四批 M5 P1-1 修复：原实现“已持锁即抛错”使排队不可达，
// 独立任务并发到达时抛错而非串行化；修法见 [withLock]。）
//
// P2 约束 2（全部物理删除集中接入）：包括异常处理、失败回滚、
// 整题删除、图块替换、孤儿清理在内的全部物理删除入口都必须经过
// 本协调机制（取锁 → 重查引用 + 待提交集合 + 暂存占用 → 再删）。
// 审计出的全部 `File.delete()` 调用点清单与处理结果见
// batch14-work/STATUS.md 的 M2 收尾审计记录（2026-11-19）与
// PLAN-14-REV4.3 的 P2-2 审计项；decision-log 里没有单条决策
// 覆盖该清单（D-120 是版本比对口径，不是调用点审计）。
//
// 待提交文件登记集合 [pendingFiles]：内存中的相对路径集合，随应用
// 进程存在，不进数据库、不进备份。登记时机为 rename 前双路径预登记
// （见 figure_files.dart）：临时文件创建前登记临时路径，rename 执行
// 前再登记正式目标路径；rename 成功后移除临时路径登记、保留正式
// 路径登记；数据库引用提交成功后移除正式路径登记；提交失败/回滚
// 确认后，在锁内删除该文件、确认清理完成后再移除登记；rename 失败
// 时按实际文件存在状态清理、两条路径的登记最终正确解除。孤儿清理
// 在锁内重算引用时，必须把待提交集合中的路径一并视为“被占用”，
// 跳过不删。
//
// 备份暂存区占用 [stagingPaths]：备份导出在锁内快照文件清单、复制
// 到独立暂存区 `.backup-staging-<时间戳>` 后释锁，再从暂存区读文件
// 建 ZIP；暂存区占用期间（复制完成 → 暂存区删除），清单里的相对路径
// 一律视为被占用，物理删除与孤儿清理都跳过。成功/失败后都删暂存区
// 并解除占用登记。

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 进程内统一文件操作锁（全局单例）。
class FileLifecycleGuard {
  FileLifecycleGuard._();

  static final FileLifecycleGuard instance = FileLifecycleGuard._();

  bool _locked = false;
  final Queue<Completer<void>> _waiters = Queue();

  /// 持锁调用链的 Zone 标记键。[withLock] 把本 guard 实例放进
  /// action 所在 Zone 的 zoneValues；Zone 随异步调用链传播，
  /// action 内部 await 之后再次调 [withLock] 仍能被识别为同一
  /// 调用链（重入 → 抛错），而独立任务的 Zone 里没有该标记，
  /// 走正常排队。
  static final Object _lockZoneKey = Object();

  /// 当前是否已被某一入口持有（测试与内部断言用）。
  bool get isLocked => _locked;

  Future<void> _acquire() async {
    if (!_locked) {
      _locked = true;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    // 在此 await 挂起：恢复时仍在调用方自己的 Zone 里继续
    // （Future 的监听在注册时捕获 Zone），Zone 上下文不丢失。
    await waiter.future;
  }

  void _release() {
    if (_waiters.isEmpty) {
      _locked = false;
      return;
    }
    // 唤醒队首：锁仍归它持有（_locked 保持 true），直到它释放。
    _waiters.removeFirst().complete();
  }

  /// 对外入口：获取锁后执行 [action]，执行完释放锁。
  /// 非重入：同一持锁调用链（[action] 内部，含 await 之后的调用）
  /// 再次调用直接抛 [StateError]（不排队、不死锁）；独立异步任务
  /// 在已持锁时调用则进等待队列，待前一个释放后按序获得锁。
  /// action 抛异常时锁同样释放（finally），排队的任务不受影响。
  Future<T> withLock<T>(Future<T> Function() action) async {
    if (identical(Zone.current[_lockZoneKey], this)) {
      throw StateError(
        'FileLifecycleGuard 不可重入：同一持锁调用链不得再次取锁。'
        '内部路径请走 requireLocked + *Locked，不要再调 withLock。',
      );
    }
    await _acquire();
    try {
      return await runZoned(action, zoneValues: {_lockZoneKey: this});
    } finally {
      _release();
    }
  }

  /// 内部实现用：调用者必须已经持锁，否则抛 [StateError]。
  void requireLocked() {
    if (!_locked) {
      throw StateError(
        'FileLifecycleGuard：内部文件操作要求调用者已持锁。'
        '请从对外入口（withLock）进入，不要直接调内部函数。',
      );
    }
  }

  // ------------------------------------------------------------------
  // 待提交文件登记集合（内存相对路径集合，不进数据库、不进备份）。
  // ------------------------------------------------------------------

  final Set<String> _pending = {};

  static String _norm(String rel) => rel.replaceAll('\\', '/');

  /// 登记一条待提交路径（写文件协议：临时路径创建前、正式路径
  /// rename 前各登记一次）。
  void registerPending(String relativePath) {
    _pending.add(_norm(relativePath));
  }

  /// 解除一条待提交路径的登记（rename 成功后解除临时路径；
  /// 数据库引用提交成功 / 清理确认完成后解除正式路径）。
  void unregisterPending(String relativePath) {
    _pending.remove(_norm(relativePath));
  }

  /// 该路径是否在待提交集合中（孤儿清理与删文件前重查用）。
  bool isPending(String relativePath) => _pending.contains(_norm(relativePath));

  /// 待提交集合快照（测试与审计用，不可变副本）。
  Set<String> get pendingSnapshot => Set.unmodifiable(_pending);

  /// 测试用：清空登记集合（只在测试里调，生产不调）。
  void debugClearPendingForTest() => _pending.clear();

  // ------------------------------------------------------------------
  // 备份暂存区占用（暂存区复制完成 → 暂存区删除期间的相对路径集合）。
  // ------------------------------------------------------------------

  final Set<String> _staging = {};

  /// 备份导出把文件复制进暂存区后登记占用。
  void registerStaging(Iterable<String> relativePaths) {
    for (final rel in relativePaths) {
      _staging.add(_norm(rel));
    }
  }

  /// 暂存区删除后解除占用登记。
  void unregisterStaging(Iterable<String> relativePaths) {
    for (final rel in relativePaths) {
      _staging.remove(_norm(rel));
    }
  }

  /// 该路径是否正被备份暂存区占用（删文件与孤儿清理前重查用）。
  bool isStaged(String relativePath) => _staging.contains(_norm(relativePath));

  /// 暂存占用快照（测试与审计用，不可变副本）。
  Set<String> get stagingSnapshot => Set.unmodifiable(_staging);

  /// 测试用：清空暂存占用登记（只在测试里调，生产不调）。
  void debugClearStagingForTest() => _staging.clear();

  // ------------------------------------------------------------------
  // 物理删除（全部经本机制；内部版要求调用者已持锁）。
  // ------------------------------------------------------------------

  /// 内部删除：删除单个文件（要求调用者已持锁）。
  /// 返回 true = 文件存在且已删除；false = 文件本来就不存在或删失败
  /// （删失败静默返回 false，由孤儿清理兜底，不抛错、不回滚数据库）。
  Future<bool> deleteFileLocked(File file) async {
    requireLocked();
    try {
      if (file.existsSync()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 内部删除：递归删除一个目录（要求调用者已持锁）。
  Future<void> deleteDirectoryLocked(Directory dir) async {
    requireLocked();
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// 内部删除：删除一个空目录（要求调用者已持锁；非空时删不掉，
  /// 静默跳过——迁移回滚与恢复收尾的“顺手删空父目录”用，不强求）。
  Future<void> deleteEmptyDirectoryLocked(Directory dir) async {
    requireLocked();
    try {
      if (dir.existsSync()) await dir.delete();
    } catch (_) {}
  }

  /// 对外删除入口：取锁后删除单个文件（内部不再取锁）。
  Future<bool> deleteFile(File file) =>
      withLock(() => deleteFileLocked(file));

  /// 对外删除入口：取锁后递归删除一个目录（内部不再取锁）。
  Future<void> deleteDirectory(Directory dir) =>
      withLock(() => deleteDirectoryLocked(dir));

  /// 对外删除入口：取锁后删除一个空目录（内部不再取锁）。
  Future<void> deleteEmptyDirectory(Directory dir) =>
      withLock(() => deleteEmptyDirectoryLocked(dir));

  // ------------------------------------------------------------------
  // 备份暂存区命名与启动清理。
  // ------------------------------------------------------------------

  /// 备份暂存区目录名：`.backup-staging-<毫秒时间戳>`。
  static String backupStagingDirName(int timestampMs) =>
      '.backup-staging-$timestampMs';

  /// 严格匹配规则（与恢复 staging 的 `.restore-staging-<纯数字时间戳>`
  /// 同口径）：名字必须是 `.backup-staging-<纯数字时间戳>`，其他同名
  /// 目录一概不动。
  static bool isBackupStagingDirName(String name) {
    const prefix = '.backup-staging-';
    if (!name.startsWith(prefix)) return false;
    return RegExp(r'^\d+$').hasMatch(name.substring(prefix.length));
  }

  /// 启动时清理崩溃残留的 `.backup-staging-<时间戳>` 目录（严格匹配，
  /// 其他同名目录不动）。失败静默——残留暂存区只是占磁盘，不影响开库，
  /// 下次启动再清。
  Future<void> cleanupStaleBackupStagingDirs(String dataDir) async {
    final dir = Directory(dataDir);
    if (!dir.existsSync()) return;
    try {
      for (final e in dir.listSync()) {
        if (e is Directory &&
            isBackupStagingDirName(p.basename(e.path))) {
          await deleteDirectory(e);
        }
      }
    } catch (_) {}
  }
}
