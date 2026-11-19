// 十四批 M5 P1-2 单实例测试专用小程序（不是测试文件本身）。
//
// 用法（在仓库根目录下跑）：
//   dart test/b14_m5_single_instance_harness.dart <hold|try|mainflow> <数据目录> [秒数]
//   - hold：取锁成功打印 HELD，持有 [秒数] 秒（默认 30）后正常退出
//     （退出码 0）；取不到锁打印 DENIED，退出码 2。
//   - try：尝试取锁，成功打印 ACQUIRED 并立即释放，退出码 0；
//     被挡打印 DENIED，退出码 2。
//   - mainflow：复刻 lib/main.dart 的三路启动分支（与 main.dart 共用
//     文案常量，分支结构保持一致）：取锁成功打印 ACQUIRED，退出码 0
//     （表示“继续启动主应用”）；被另一实例挡住打印 DENIED，退出码 2；
//     非竞争 FileSystemException（锁文件不可用）打印 STARTUP_FAILED，
//     退出码 3（表示“展示启动失败提示并终止进程，绝不启动主应用”——
//     M5 修复轮 2，P1-2 fail-open 修复）。本模式不初始化数据库、
//     不做任何文件操作（只取锁本身建锁文件）。
//
// 存在意义：dart:io 的独占锁在 Linux 上是进程级建议锁（flock），
// 同一进程内两次取锁会成功，所以“第二个实例被挡住”只能用子进程
// 验证——测试（test/b14_m5_single_instance_test.dart）以子进程
// 方式跑本文件。退出码约定：0 成功、2 被另一实例挡住、3 锁不可用
// 时启动失败终止、1 用法错误。
// 本文件不 import flutter，只 import package:quiz_master2 的纯 Dart
// 服务，`dart` 命令可直接跑，不启动 Flutter 引擎。

import 'dart:io';

import 'package:quiz_master2/services/single_instance.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2 ||
      (args[0] != 'hold' && args[0] != 'try' && args[0] != 'mainflow')) {
    stderr.writeln(
      '用法：dart test/b14_m5_single_instance_harness.dart <hold|try|mainflow> <数据目录> [秒数]',
    );
    exitCode = 1;
    return;
  }
  final mode = args[0];
  final dataDir = args[1];
  final seconds = args.length > 2 ? int.tryParse(args[2]) ?? 30 : 30;

  SingleInstanceGuard? guard;
  try {
    guard = await SingleInstanceGuard.tryAcquire(dataDirectory: dataDir);
  } on FileSystemException catch (e) {
    // mainflow：锁不可用的非竞争 IO 错误——与 main.dart 同款 fail-closed：
    // 展示启动失败提示并终止进程（退出码 3），绝不继续启动主应用。
    if (mode == 'mainflow') {
      stdout.writeln('STARTUP_FAILED $singleInstanceIoErrorMessage ($e)');
      await stdout.flush();
      exitCode = 3;
      return;
    }
    stderr.writeln('ERROR $e');
    exitCode = 1;
    return;
  }
  if (guard == null) {
    stdout.writeln('DENIED $singleInstanceDuplicateMessage');
    await stdout.flush();
    exitCode = 2;
    return;
  }
  if (mode == 'try' || mode == 'mainflow') {
    stdout.writeln('ACQUIRED ${guard.lockFilePath}');
    await stdout.flush();
    await guard.release();
    return;
  }
  stdout.writeln('HELD ${guard.lockFilePath}');
  await stdout.flush();
  await Future.delayed(Duration(seconds: seconds));
  await guard.release();
  stdout.writeln('RELEASED');
}
