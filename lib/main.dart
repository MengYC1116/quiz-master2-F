import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'data/database.dart';
import 'services/single_instance.dart';

/// 第一个实例持有的单实例锁（D-145）：顶层变量强引用，进程生命周期内
/// 不释放。锁随 RandomAccessFile 句柄存在，句柄关闭即释放；这里绝不
/// 主动释放，进程退出（含崩溃/被杀）时由 OS 自动释放。
SingleInstanceGuard? _singleInstanceGuard;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 二十四批 D-253：安卓数据目录须先解析——path_provider 是异步的，
  // 而 AppDatabase.dataDirectoryPath() 是同步的；不解析就直接算，
  // 安卓上会得到相对路径 .local/share/quiz-master2，再在只读的
  // 根目录 / 下建目录（errno 30），启动第一步就失败。
  // 解析失败直接进启动失败窗口，不继续走单实例锁/开库。
  if (Platform.isAndroid) {
    try {
      final docs = await getApplicationDocumentsDirectory();
      AppDatabase.startupDataDirectory = docs.path;
    } catch (e) {
      stderr.writeln('quiz-master2：安卓数据目录解析失败（$e）');
      runApp(
        _StartupFailureApp(
          detail: e.toString(),
          title: _androidDataDirTitle,
          message: _androidDataDirMessage,
        ),
      );
      return;
    }
  }
  // 十四批 M5 P1-2（D-145）：OS 级单实例保护。检查点必须在 runApp
  // 之前、数据库初始化与任何文件操作之前——AppDatabase 是懒打开的
  // （首次 await db 时才建目录/开库），OcrWorker 也在 QuizMasterApp
  // 的 initState 里才启动，所以这里取锁时应用还没碰过任何数据文件。
  // 数据目录口径与数据库层完全一致：AppDatabase.dataDirectoryPath()
  //（默认 %LOCALAPPDATA%\quiz-master2 / ~/.local/share/quiz-master2 /
  // 安卓应用内部存储目录，见 D-253；有 db_location.txt 自定义位置时
  // 用自定义位置；只读标记文件，不建目录、不开库）。
  final dataDir = AppDatabase.dataDirectoryPath();
  try {
    _singleInstanceGuard =
        await SingleInstanceGuard.tryAcquire(dataDirectory: dataDir);
  } on FileSystemException catch (e) {
    // 非竞争 IO 错误（锁文件建不出来/打不开/加锁失败等）：不能证明
    // 没有其他实例，绝不继续启动主应用（M5 修复轮 2，P1-2 fail-open
    // 修复：D-145 原文的 fail-open 口径已被推翻）。给用户一个看得懂
    // 的中文窗口并终止进程；不得初始化数据库、不得做任何文件操作。
    stderr.writeln('quiz-master2：$singleInstanceIoErrorMessage（$e）');
    runApp(_StartupFailureApp(detail: e.toString()));
    return;
  }
  if (_singleInstanceGuard == null) {
    // 第二个实例：已有实例在运行。不得初始化数据库、不得做任何文件
    // 操作；给用户一个看得懂的中文窗口（双击启动时只打日志用户根本
    // 看不到，所以不用“打日志就退出”），点“知道了，退出”或关窗口
    // 即退出进程。不做“把请求转交给第一个实例”（D-145 的选择）。
    // 注意：本窗口只用于 tryAcquire() == null 的情况，锁不可用的
    // IO 错误走上面的 _StartupFailureApp，两者不得混用。
    stderr.writeln('quiz-master2：$singleInstanceDuplicateMessage');
    runApp(const _DuplicateInstanceApp());
    return;
  }
  // ARCH-PLAN-A 第 1 阶段：整应用包一层 ProviderScope，
  // 设置状态（settingsProvider，见 lib/state/）由此进入 widget 树。
  runApp(const ProviderScope(child: QuizMasterApp()));
}

/// 二十四批 D-253：安卓数据目录解析失败的启动失败提示（与单实例
/// 锁失败的文案分开，复用同一窗口骨架，只换标题与正文）。
const String _androidDataDirTitle = 'quiz-master2 无法启动';

const String _androidDataDirMessage =
    '安卓数据目录解析失败，程序已停止启动。\n请检查存储权限，然后重试。';

/// 单实例锁不可用的启动失败窗口：只展示中文提示，不碰数据库、不启动
/// 任何后台 worker、不读设置。点按钮即以退出码 1 终止进程。
/// [title]/[message] 不传时用单实例锁失败的文案；安卓数据目录解析
/// 失败时由 main() 传入 D-253 的文案。
class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp({required this.detail, this.title, this.message});

  final String detail;
  final String? title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'quiz-master2',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title ?? singleInstanceIoErrorTitle,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text(message ?? singleInstanceIoErrorMessage),
                const SizedBox(height: 12),
                Text(detail),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => exit(1),
                  child: const Text('知道了，退出'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 第二个实例的提示窗口：只展示中文提示，不碰数据库、不启动任何
/// 后台 worker、不读设置。点按钮或关窗口即退出进程。
class _DuplicateInstanceApp extends StatelessWidget {
  const _DuplicateInstanceApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'quiz-master2',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  singleInstanceDuplicateTitle,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                const Text(singleInstanceDuplicateMessage),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => exit(0),
                  child: const Text('知道了，退出'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
