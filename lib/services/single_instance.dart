// 十四批 M5 P1-2：OS 级单实例保护（见 docs/decision-log.md D-145）。
//
// 背景：file_lifecycle_guard.dart 文件头的前提是“同一时间只允许一个
// 应用实例打开同一数据库”，但此前没有任何执行保障——进程内锁对另一
// 个进程不可见，SQLite 写锁也保护不了数据目录下的图块文件；Linux
// 原生入口还显式用了 G_APPLICATION_NON_UNIQUE，Windows 入口则完全
// 没有互斥量。GPT 关口审（M5 回复第 2 节）因此判 P1-2 FAIL。
//
// 机制：启动时在数据目录下对锁文件取独占锁（dart:io
// RandomAccessFile.lock(FileLock.exclusive)，非阻塞：拿不到立即抛
// FileSystemException，不等待）。第一个实例持有锁直至进程结束；
// 第二个实例在初始化数据库和任何文件操作之前退出并给出中文提示。
// 不做“把请求转交给第一个实例”（D-145 的选择）。
//
// 平台依据（Windows 未在本机实测，见 D-145）：
// - Linux：dart:io 的 exclusive 锁底层是 flock(2) + LOCK_NB；
//   拿不到时 errno 为 EWOULDBLOCK（11），本机子进程探针已验证
//   （第二个进程退出码 2；kill -9 持有者后新进程可正常取锁）。
// - Windows：同一 dart:io API 底层是 LockFileEx（非阻塞独占，
//   拿不到时 Win32 错误 33 ERROR_LOCK_VIOLATION）；锁随句柄存在，
//   进程退出（含崩溃/被杀）时 OS 自动释放。
// - 同一进程内两次取锁在 Linux 上会成功（flock 是进程级建议锁，
//   见 dart:io 文档），所以“第二个实例被挡住”只能用子进程验证，
//   不能只测进程内——测试见 test/b14_m5_single_instance_test.dart。
//
// 注意点：
// - 锁文件只留着，不删除：释放时只 unlock + 关闭句柄。删除锁文件
//   有 unlink 竞态（A 释放并删文件、B 随后建了同名新文件，两进程
//   各锁不同的 inode，互不知晓），所以锁文件永久留在数据目录里，
//   它的存在本身没有任何含义，只有 OS 锁才算数。
// - 锁文件以 FileMode.append 打开：只建不存在的文件，不截断——
//   另一进程可能正持有同一文件的锁，截断无意义且没必要。
// - 本文件是纯 Dart（dart:io + package:path），不 import flutter /
//   drift / AppDatabase：测试专用小程序（test 目录下的 harness）
//   用 `dart run` 直接跑它，不启动 Flutter 引擎。数据目录由调用方
//   （main.dart 经 AppDatabase.dataDirectoryPath()，含
//   db_location.txt 自定义位置口径）算好传进来。
// - 锁只按数据目录区分：两个实例指向同一数据目录才互斥；指向不同
//   数据目录是两个独立的库，本来就互不干扰。

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 锁文件名（D-145）：放在数据目录根下，与 `quiz-master2.db` 同级。
const String singleInstanceLockFileName = 'instance.lock';

/// 第二个实例的窗口标题（中文，用户看得懂）。
const String singleInstanceDuplicateTitle = 'quiz-master2 已在运行';

/// 第二个实例的提示正文（中文，D-145 定稿；main.dart 的重复实例
/// 窗口与 stderr 日志共用同一份文案，不各写一套）。
const String singleInstanceDuplicateMessage =
    '已有 quiz-master2 正在运行，请勿重复打开。\n请先关闭正在运行的 quiz-master2 窗口，再重新打开本程序。';

/// 单实例锁不可用时的启动失败提示（中文，M5 修复轮 2，P1-2 fail-open
/// 修复）：锁文件无法创建/打开/加锁的非竞争 IO 错误，不能证明没有
/// 其他实例，main.dart 必须展示本提示并终止进程，不得继续启动主应用。
/// main.dart 的失败窗口、stderr 日志与测试 harness 共用同一份文案。
const String singleInstanceIoErrorTitle = 'quiz-master2 无法启动';

const String singleInstanceIoErrorMessage =
    '单实例锁文件无法创建或打开，为防止多个实例同时操作同一数据目录，程序已停止启动。\n请检查数据目录是否可写，然后重试。';

/// OS 级单实例锁：持有数据目录下锁文件的独占锁。
///
/// 实例必须在进程整个生命周期内被强引用（main.dart 用顶层变量持有），
/// 句柄一旦关闭锁即释放。生产启动不调 [release]——进程退出时 OS
/// 自动释放（含正常退出与 kill）；[release] 只供测试/harness 用。
class SingleInstanceGuard {
  SingleInstanceGuard._(this._file, this.lockFilePath);

  final RandomAccessFile _file;

  /// 锁文件的绝对路径（测试断言锁落点用）。
  final String lockFilePath;

  bool _released = false;

  /// 是否已释放（测试用）。
  bool get isReleased => _released;

  /// 释放锁：unlock 后关闭句柄。幂等；锁文件本身不删除（见文件头注释）。
  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await _file.unlock();
    } catch (_) {
      // 已持有锁时 unlock 不应失败；即使失败，紧接着的 close 也会
      // 让 OS 释放锁，不阻断释放流程。
    }
    await _file.close();
  }

  /// 在 [dataDirectory] 下取单实例锁。
  ///
  /// - 成功：返回持有的 [SingleInstanceGuard]（调用方必须一直持有，
  ///   直到进程结束）。
  /// - 已有另一实例持有锁：返回 null（调用方应展示
  ///   [singleInstanceDuplicateMessage] 后退出，不得初始化数据库、
  ///   不得做任何文件操作）。
  /// - 其他 IO 错误（数据目录建不出来、锁文件打不开等）：抛
  ///   [FileSystemException]。调用方不得把这种情况当成“已有实例”，
  ///   更不得继续启动主应用（M5 修复轮 2：fail-closed——锁不可用
  ///   时无法证明没有其他实例，继续启动会重开 P1-2 要封堵的跨进程
  ///   风险；调用方应展示 [singleInstanceIoErrorMessage] 并终止
  ///   进程）。D-145 原文的 fail-open 口径已被本轮修复推翻。
  static Future<SingleInstanceGuard?> tryAcquire({
    required String dataDirectory,
  }) async {
    final dir = Directory(dataDirectory);
    await dir.create(recursive: true);
    final lockFile = File(p.join(dir.path, singleInstanceLockFileName));
    final raf = await lockFile.open(mode: FileMode.append);
    try {
      // FileLock.exclusive 是非阻塞独占：拿不到立即抛
      // FileSystemException，不等待（blocking 语义是
      // FileLock.blockingExclusive，那个会等到天荒地老，绝不能用）。
      await raf.lock(FileLock.exclusive);
    } on FileSystemException catch (e) {
      await raf.close();
      if (_isContention(e)) return null;
      rethrow;
    }
    return SingleInstanceGuard._(raf, lockFile.path);
  }

  /// 判断一次 lock() 失败是不是“已有实例持有锁”（与“锁文件打不开”
  /// 等其他 IO 错误区分）。
  ///
  /// - Linux：flock(2) + LOCK_NB 拿不到时 errno 为 EWOULDBLOCK（11）。
  /// - Windows：LockFileEx 非阻塞拿不到时 Win32 错误为 33
  ///  （ERROR_LOCK_VIOLATION）。
  /// - 兜底：错误文本含对应描述时也认（不同 Dart 版本/平台的
  ///   message 措辞可能有出入，错误码优先）。
  static bool _isContention(FileSystemException e) {
    final code = e.osError?.errorCode;
    if (code == 11 || code == 33) return true;
    final text = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
    return text.contains('temporarily unavailable') ||
        text.contains('lock violation');
  }
}
