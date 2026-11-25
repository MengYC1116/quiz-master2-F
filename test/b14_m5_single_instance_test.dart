// 十四批 M5 P1-2：OS 级单实例保护测试（见 docs/decision-log.md D-145）。
//
// 关键点：dart:io 的独占锁在 Linux 上是进程级建议锁（flock），同一
// 进程内两次取锁会成功，所以“第二个实例被挡住”必须用子进程验证：
// 测试以子进程方式跑 test/b14_m5_single_instance_harness.dart
//（纯 Dart 小程序，`dart` 直接跑，不启动 Flutter 引擎）。
//
// 覆盖：
// 1. 第二个进程被挡住（退出码 2 + DENIED + 中文提示）；
// 2. 第一个进程正常退出后，锁释放，新进程能取锁；
// 3. 第一个进程被 kill -9 后，锁释放（OS 自动释放，不永久锁死）；
// 4. 同一进程内取锁—释放—再取 + 锁文件落点 + 不建数据库文件。
// 5. M5 修复轮 2（P1-2 fail-open 修复）：锁文件不可用的非竞争 IO 错误
//    绝不启动主应用——进程内 tryAcquire 抛 FileSystemException（非 11/33），
//    子进程 mainflow 模式退出码 3 + STARTUP_FAILED，不建数据库文件。
//
// 临时目录：Directory.systemTemp（调用方按任务要求把 TMPDIR 指到
// workspace 下的目录，/tmp 是 512M tmpfs 且已满，不要直接用 /tmp）。
// Dart 可执行文件定位：环境变量 SINGLE_INSTANCE_TEST_DART 优先，
// 其次 $FLUTTER_ROOT 内嵌 Dart，再次 ~/workspace/flutter-install 内嵌
// Dart，最后回退 PATH 里的 dart。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/services/single_instance.dart';

String _dartExecutable() {
  final override = Platform.environment['SINGLE_INSTANCE_TEST_DART'];
  if (override != null && override.isNotEmpty) return override;
  // Win11 上可执行文件叫 dart.exe（单写 dart 会 ProcessException
  // “系统找不到指定的文件”）。
  final exe = Platform.isWindows ? 'dart.exe' : 'dart';
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.isNotEmpty) {
    final bundled = p.join(
      flutterRoot,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      exe,
    );
    if (File(bundled).existsSync()) return bundled;
  }
  // Win11 跑 flutter test 时 FLUTTER_ROOT / HOME 都未设，PATH 里只有
  // flutter\bin\dart.bat（CreateProcess 不能直接跑 .bat）。从当前进程
  //（<flutter>/bin/cache/artifacts/engine/<platform>/flutter_tester.exe）
  // 反推 SDK 缓存目录，直接取 dart-sdk/bin/dart.exe。
  final cacheDir = File(Platform.resolvedExecutable)
      .parent
      .parent
      .parent
      .parent;
  if (p.basename(cacheDir.path) == 'cache') {
    final bundled = p.join(cacheDir.path, 'dart-sdk', 'bin', exe);
    if (File(bundled).existsSync()) return bundled;
  }
  final home = Platform.environment['HOME'];
  if (home != null && home.isNotEmpty) {
    final bundled = p.join(
      home,
      'workspace',
      'flutter-install',
      'flutter',
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      exe,
    );
    if (File(bundled).existsSync()) return bundled;
  }
  if (Platform.isWindows) {
    final found = _whereDartExe();
    if (found != null) return found;
  }
  return 'dart';
}

/// Windows：用 where.exe 找 PATH 上真正的 dart.exe（dart.bat 跑不了）。
String? _whereDartExe() {
  try {
    final r = Process.runSync('where.exe', ['dart.exe']);
    if (r.exitCode == 0) {
      for (final line in const LineSplitter().convert('${r.stdout}')) {
        final path = line.trim();
        if (path.toLowerCase().endsWith('dart.exe') &&
            File(path).existsSync()) {
          return path;
        }
      }
    }
  } catch (_) {}
  return null;
}

String get _harnessPath =>
    p.join(Directory.current.path, 'test', 'b14_m5_single_instance_harness.dart');

/// 启动一个子进程跑 harness，返回进程对象；stdout 按行收进 [lines]，
/// 首行到达时完成 [firstLine]（调用方用它等 HELD，避免固定 sleep）。
Future<Process> _startHarness(
  List<String> args, {
  required List<String> lines,
  required Completer<String> firstLine,
}) async {
  final process = await Process.start(
    _dartExecutable(),
    [_harnessPath, ...args],
    workingDirectory: Directory.current.path,
  );
  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        lines.add(line);
        if (!firstLine.isCompleted) firstLine.complete(line);
      });
  // stderr 也要消费掉，否则子进程写满管道会卡住。
  process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(lines.add);
  return process;
}

/// 等 [firstLine] 的首行，最多等 [timeout]；超时则杀掉 [process] 再抛。
Future<String> _waitFirstLine(
  Process process,
  Completer<String> firstLine, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  try {
    return await firstLine.future.timeout(timeout);
  } on TimeoutException {
    process.kill();
    await process.exitCode;
    fail('harness 在 ${timeout.inSeconds}s 内没有输出首行');
  }
}

void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync(
      'b14_m5_single_instance_',
    );
  });

  tearDown(() {
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  test(
    '第二个进程被挡住：退出码 2 + DENIED + 中文提示',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final dataDir = Directory(
        p.join(tempRoot.path, 'data'),
      )..createSync(recursive: true);
      final lines = <String>[];
      final firstLine = Completer<String>();
      final holder = await _startHarness(
        ['hold', dataDir.path, '30'],
        lines: lines,
        firstLine: firstLine,
      );
      // 等持有者确实拿到锁（HELD 行），再启动第二个进程。
      final held = await _waitFirstLine(holder, firstLine);
      expect(held, startsWith('HELD'));

      final second = await Process.run(
        _dartExecutable(),
        [_harnessPath, 'try', dataDir.path],
        workingDirectory: Directory.current.path,
        // Win11：子进程按 UTF-8 输出，Process.run 默认按系统编码
        //（GBK）解码会把中文提示解成乱码，断言必挂。
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      // 证据：第二个进程被拒——退出码 2，输出含 DENIED 与中文提示。
      expect(
        second.exitCode,
        2,
        reason: '第二个实例应被单实例锁挡住，退出码 2；实际输出：${second.stdout}${second.stderr}',
      );
      expect(second.stdout.toString(), contains('DENIED'));
      expect(second.stdout.toString(), contains('已有 quiz-master2 正在运行'));

      holder.kill();
      await holder.exitCode;
    },
  );

  test(
    '第一个进程正常退出后，锁释放，新进程能取锁',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final dataDir = Directory(
        p.join(tempRoot.path, 'data'),
      )..createSync(recursive: true);
      final first = await Process.run(
        _dartExecutable(),
        [_harnessPath, 'hold', dataDir.path, '1'],
        workingDirectory: Directory.current.path,
        // Win11：子进程按 UTF-8 输出，Process.run 默认按系统编码
        //（GBK）解码会把中文提示解成乱码，断言必挂。
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(first.exitCode, 0, reason: '持有者正常退出应为 0；输出：${first.stdout}${first.stderr}');
      expect(first.stdout.toString(), contains('HELD'));
      expect(first.stdout.toString(), contains('RELEASED'));

      final next = await Process.run(
        _dartExecutable(),
        [_harnessPath, 'try', dataDir.path],
        workingDirectory: Directory.current.path,
        // Win11：子进程按 UTF-8 输出，Process.run 默认按系统编码
        //（GBK）解码会把中文提示解成乱码，断言必挂。
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(
        next.exitCode,
        0,
        reason: '前一进程正常退出后新进程应能取锁；实际输出：${next.stdout}${next.stderr}',
      );
      expect(next.stdout.toString(), contains('ACQUIRED'));
    },
  );

  test(
    '第一个进程被 kill -9 后，锁释放，不永久锁死',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final dataDir = Directory(
        p.join(tempRoot.path, 'data'),
      )..createSync(recursive: true);
      final lines = <String>[];
      final firstLine = Completer<String>();
      final holder = await _startHarness(
        ['hold', dataDir.path, '30'],
        lines: lines,
        firstLine: firstLine,
      );
      final held = await _waitFirstLine(holder, firstLine);
      expect(held, startsWith('HELD'));

      // 模拟崩溃/被杀：SIGKILL，不给进程任何清理机会。
      holder.kill(ProcessSignal.sigkill);
      await holder.exitCode;

      final next = await Process.run(
        _dartExecutable(),
        [_harnessPath, 'try', dataDir.path],
        workingDirectory: Directory.current.path,
        // Win11：子进程按 UTF-8 输出，Process.run 默认按系统编码
        //（GBK）解码会把中文提示解成乱码，断言必挂。
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(
        next.exitCode,
        0,
        reason: '持有者被 kill -9 后 OS 应自动释放锁；实际输出：${next.stdout}${next.stderr}',
      );
      expect(next.stdout.toString(), contains('ACQUIRED'));
    },
  );

  test('同一进程内取锁—释放—再取；锁文件在数据目录根下；不建数据库文件', () async {
    final dataDir = Directory(
      p.join(tempRoot.path, 'data'),
    )..createSync(recursive: true);

    final first = await SingleInstanceGuard.tryAcquire(
      dataDirectory: dataDir.path,
    );
    expect(first, isNotNull, reason: '空目录上首次取锁应成功');
    expect(
      first!.lockFilePath,
      p.join(dataDir.path, singleInstanceLockFileName),
    );
    expect(File(first.lockFilePath).existsSync(), isTrue);
    expect(
      File(p.join(dataDir.path, 'quiz-master2.db')).existsSync(),
      isFalse,
      reason: '单实例锁不得顺带建数据库文件',
    );

    await first.release();
    expect(first.isReleased, isTrue);
    // 释放不删锁文件（防 unlink 竞态，见 single_instance.dart 文件头）。
    expect(File(first.lockFilePath).existsSync(), isTrue);

    final second = await SingleInstanceGuard.tryAcquire(
      dataDirectory: dataDir.path,
    );
    expect(second, isNotNull, reason: '释放后同一进程应能再次取锁');
    await second!.release();
  });

  test('锁文件路径被占成目录：tryAcquire 抛非竞争 FileSystemException，不返回 null', () async {
    final dataDir = Directory(
      p.join(tempRoot.path, 'data'),
    )..createSync(recursive: true);
    // 锁文件位置上是个目录：open(mode: append) 失败（EISDIR），
    // 不是锁竞争——必须抛错，不能把它当成“已有实例”返回 null。
    Directory(p.join(dataDir.path, singleInstanceLockFileName))
        .createSync();
    Object? caught;
    try {
      await SingleInstanceGuard.tryAcquire(dataDirectory: dataDir.path);
    } catch (e) {
      caught = e;
    }
    expect(
      caught,
      isA<FileSystemException>(),
      reason: '锁文件打不开是非竞争 IO 错误，应抛 FileSystemException',
    );
    final code = (caught as FileSystemException).osError?.errorCode;
    expect(code, isNot(11), reason: '不是锁竞争（Linux errno 11）');
    expect(code, isNot(33), reason: '不是锁竞争（Windows 错误 33）');
  });

  test('数据目录路径是个文件：tryAcquire 抛非竞争 FileSystemException', () async {
    final dataFile = File(p.join(tempRoot.path, 'data'))
      ..createSync(recursive: true);
    Object? caught;
    try {
      await SingleInstanceGuard.tryAcquire(dataDirectory: dataFile.path);
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<FileSystemException>());
    final code = (caught as FileSystemException).osError?.errorCode;
    expect(code, isNot(11));
    expect(code, isNot(33));
  });

  test(
    '锁文件不可用时绝不启动主应用：子进程 mainflow 退出码 3 + STARTUP_FAILED，不建库',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final dataDir = Directory(
        p.join(tempRoot.path, 'data'),
      )..createSync(recursive: true);
      Directory(p.join(dataDir.path, singleInstanceLockFileName))
          .createSync();
      final before = dataDir.listSync().map((e) => e.path).toSet();

      final proc = await Process.run(
        _dartExecutable(),
        [_harnessPath, 'mainflow', dataDir.path],
        workingDirectory: Directory.current.path,
        // Win11：子进程按 UTF-8 输出，Process.run 默认按系统编码
        //（GBK）解码会把中文提示解成乱码，断言必挂。
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      final out = '${proc.stdout}${proc.stderr}';
      expect(
        proc.exitCode,
        3,
        reason: '锁不可用的非竞争 IO 错误必须终止启动，退出码 3；实际输出：$out',
      );
      expect(out, contains('STARTUP_FAILED'));
      expect(out, contains('单实例锁文件无法创建或打开'));
      expect(out, isNot(contains('ACQUIRED')));
      expect(out, isNot(contains('DENIED')));
      expect(out, isNot(contains('已有 quiz-master2 正在运行')));
      // 不初始化数据库、不做文件操作：除预先建好的目录外无新增文件。
      expect(
        File(p.join(dataDir.path, 'quiz-master2.db')).existsSync(),
        isFalse,
      );
      expect(dataDir.listSync().map((e) => e.path).toSet(), before);
    },
  );

  test(
    '数据目录是个文件时绝不启动主应用：子进程 mainflow 退出码 3',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final dataFile = File(p.join(tempRoot.path, 'data'))
        ..createSync(recursive: true);
      final proc = await Process.run(
        _dartExecutable(),
        [_harnessPath, 'mainflow', dataFile.path],
        workingDirectory: Directory.current.path,
        // Win11：子进程按 UTF-8 输出，Process.run 默认按系统编码
        //（GBK）解码会把中文提示解成乱码，断言必挂。
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      final out = '${proc.stdout}${proc.stderr}';
      expect(proc.exitCode, 3, reason: '实际输出：$out');
      expect(out, contains('STARTUP_FAILED'));
      expect(out, isNot(contains('ACQUIRED')));
    },
  );

  test(
    'mainflow 对照：正常数据目录取锁成功，退出码 0 + ACQUIRED',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final dataDir = Directory(
        p.join(tempRoot.path, 'data'),
      )..createSync(recursive: true);
      final proc = await Process.run(
        _dartExecutable(),
        [_harnessPath, 'mainflow', dataDir.path],
        workingDirectory: Directory.current.path,
        // Win11：子进程按 UTF-8 输出，Process.run 默认按系统编码
        //（GBK）解码会把中文提示解成乱码，断言必挂。
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      final out = '${proc.stdout}${proc.stderr}';
      expect(proc.exitCode, 0, reason: '实际输出：$out');
      expect(out, contains('ACQUIRED'));
      expect(
        File(p.join(dataDir.path, 'quiz-master2.db')).existsSync(),
        isFalse,
      );
    },
  );
}
