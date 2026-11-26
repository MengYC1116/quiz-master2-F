// 二十四批 D-253：安卓数据目录解析回归测试。
//
// 只测纯函数 resolveDefaultDataDirectory（平台、环境与路径风格
// 均可注入，Linux 测试机上覆盖 Windows/Android 分支），不碰真实
// 库、不调 main()（main() 的安卓分支在 Linux 测试机上跑不到，
// 真机验证留给 APK 重打后的小米 14）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';

void main() {
  group('resolveDefaultDataDirectory — Android', () {
    test('启动时解析好的目录被采用', () {
      expect(
        resolveDefaultDataDirectory(
          isWindows: false,
          isAndroid: true,
          startupDataDirectory: '/data/data/com.example.quiz_master2/files',
          environment: const {},
          pathContext: p.posix,
        ),
        '/data/data/com.example.quiz_master2/files/quiz-master2',
      );
    });

    test('未初始化就抛错，不回退到相对路径', () {
      expect(
        () => resolveDefaultDataDirectory(
          isWindows: false,
          isAndroid: true,
          startupDataDirectory: null,
          environment: const {},
          pathContext: p.posix,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('未初始化'),
          ),
        ),
      );
    });

    test('空串启动目录同样抛错', () {
      expect(
        () => resolveDefaultDataDirectory(
          isWindows: false,
          isAndroid: true,
          startupDataDirectory: '',
          environment: const {},
          pathContext: p.posix,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('相对路径的启动目录被 guard 拦下', () {
      expect(
        () => resolveDefaultDataDirectory(
          isWindows: false,
          isAndroid: true,
          startupDataDirectory: '.local/share',
          environment: const {},
          pathContext: p.posix,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('相对路径'),
          ),
        ),
      );
    });
  });

  group('resolveDefaultDataDirectory — Windows', () {
    test('LOCALAPPDATA 优先', () {
      expect(
        resolveDefaultDataDirectory(
          isWindows: true,
          isAndroid: false,
          startupDataDirectory: null,
          environment: const {
            'LOCALAPPDATA': r'C:\Users\test\AppData\Local',
          },
          pathContext: p.windows,
        ),
        r'C:\Users\test\AppData\Local\quiz-master2',
      );
    });

    test('无 LOCALAPPDATA 时回退 USERPROFILE', () {
      expect(
        resolveDefaultDataDirectory(
          isWindows: true,
          isAndroid: false,
          startupDataDirectory: null,
          environment: const {'USERPROFILE': r'C:\Users\test'},
          pathContext: p.windows,
        ),
        r'C:\Users\test\AppData\Local\quiz-master2',
      );
    });

    test('USERPROFILE 也为空时 guard 抛错（不是相对路径）', () {
      expect(
        () => resolveDefaultDataDirectory(
          isWindows: true,
          isAndroid: false,
          startupDataDirectory: null,
          environment: const {},
          pathContext: p.windows,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('相对路径'),
          ),
        ),
      );
    });
  });

  group('resolveDefaultDataDirectory — Linux', () {
    test('XDG_DATA_HOME 优先', () {
      expect(
        resolveDefaultDataDirectory(
          isWindows: false,
          isAndroid: false,
          startupDataDirectory: null,
          environment: const {'XDG_DATA_HOME': '/home/test/.local/share'},
          pathContext: p.posix,
        ),
        '/home/test/.local/share/quiz-master2',
      );
    });

    test('无 XDG 时回退 HOME/.local/share', () {
      expect(
        resolveDefaultDataDirectory(
          isWindows: false,
          isAndroid: false,
          startupDataDirectory: null,
          environment: const {'HOME': '/home/test'},
          pathContext: p.posix,
        ),
        '/home/test/.local/share/quiz-master2',
      );
    });

    test('HOME 为空时 guard 抛错（本次安卓故障的同款形状）', () {
      expect(
        () => resolveDefaultDataDirectory(
          isWindows: false,
          isAndroid: false,
          startupDataDirectory: null,
          environment: const {},
          pathContext: p.posix,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('相对路径'),
          ),
        ),
      );
    });
  });

  group('优先级与复位', () {
    test('测试钩子优先于生产启动目录', () {
      // flutter_test_config 已把 testDataDirectory 指到临时目录；
      // 即使设了 startupDataDirectory，dataDirectoryPath() 仍走测试钩子。
      final tmp = AppDatabase.testDataDirectory;
      expect(tmp, isNotNull);
      AppDatabase.startupDataDirectory = '/data/data/com.example/files';
      try {
        expect(AppDatabase.dataDirectoryPath(), tmp);
      } finally {
        AppDatabase.startupDataDirectory = null;
      }
    });

    test('resetForTest 清掉 startupDataDirectory', () async {
      final tmp = AppDatabase.testDataDirectory;
      AppDatabase.startupDataDirectory = '/data/data/com.example/files';
      await AppDatabase.resetForTest();
      expect(AppDatabase.startupDataDirectory, isNull);
      // D-260：resetForTest 不再把 testDataDirectory 置 null，而是重指
      // 全新临时目录；恢复 flutter_test_config 的隔离目录，免得同文件
      // 后续测试受影响。
      expect(AppDatabase.testDataDirectory, isNotNull);
      expect(AppDatabase.testDataDirectory, isNot(tmp));
      AppDatabase.testDataDirectory = tmp;
      AppDatabase.testMarkerDirectory = null;
    });
  });

  group('resetForTest 重指全新临时目录（D-88 残留，D-260）', () {
    test('reset 后两个测试目录非空、指向新建的不同目录', () async {
      final prevData = AppDatabase.testDataDirectory;
      final prevMarker = AppDatabase.testMarkerDirectory;
      expect(prevData, isNotNull);
      try {
        await AppDatabase.resetForTest();
        final after = AppDatabase.testDataDirectory;
        expect(after, isNotNull);
        expect(after, isNot(prevData));
        expect(Directory(after!).existsSync(), isTrue);
        expect(AppDatabase.testMarkerDirectory, after);
        expect(AppDatabase.dataDirectoryPath(), after);
        expect(AppDatabase.startupDataDirectory, isNull);
        expect(AppDatabase.instance.dbPathUsed, isNull);
      } finally {
        AppDatabase.testDataDirectory = prevData;
        AppDatabase.testMarkerDirectory = prevMarker;
      }
    });

    test('连续两次 reset 得到两个不同目录', () async {
      final prevData = AppDatabase.testDataDirectory;
      final prevMarker = AppDatabase.testMarkerDirectory;
      try {
        await AppDatabase.resetForTest();
        final first = AppDatabase.testDataDirectory;
        await AppDatabase.resetForTest();
        final second = AppDatabase.testDataDirectory;
        expect(first, isNotNull);
        expect(second, isNotNull);
        expect(second, isNot(first));
        expect(Directory(second!).existsSync(), isTrue);
      } finally {
        AppDatabase.testDataDirectory = prevData;
        AppDatabase.testMarkerDirectory = prevMarker;
      }
    });

    test('reset 后写盘仍落在新临时目录，不碰真实数据目录', () async {
      final prevData = AppDatabase.testDataDirectory;
      final prevMarker = AppDatabase.testMarkerDirectory;
      try {
        await AppDatabase.resetForTest();
        final dir = AppDatabase.dataDirectoryPath();
        final realDefault = resolveDefaultDataDirectory(
          isWindows: Platform.isWindows,
          isAndroid: false,
          startupDataDirectory: null,
          environment: Platform.environment,
        );
        expect(dir, isNot(realDefault));
        final probe = File(p.join(dir, 'qm2-reset-probe.txt'));
        await probe.writeAsString('probe');
        try {
          expect(await probe.exists(), isTrue);
          expect(
            File(p.join(realDefault, 'qm2-reset-probe.txt')).existsSync(),
            isFalse,
          );
        } finally {
          try {
            await probe.delete();
          } catch (_) {}
        }
      } finally {
        AppDatabase.testDataDirectory = prevData;
        AppDatabase.testMarkerDirectory = prevMarker;
      }
    });
  });

  group('当前平台委托', () {
    test(
      'Linux 默认路径与环境一致（不依赖私有 wrapper）',
      skip: Platform.isLinux
          ? false
          : '该用例校验 Linux 默认路径；Windows/Android 的默认路径分支已由上方平台专属用例覆盖',
      () {
      final home = Platform.environment['HOME'] ?? '';
      final xdg = Platform.environment['XDG_DATA_HOME'];
      final expected = (xdg != null && xdg.isNotEmpty)
          ? '$xdg/quiz-master2'
          : '$home/.local/share/quiz-master2';
      expect(
        resolveDefaultDataDirectory(
          isWindows: Platform.isWindows,
          isAndroid: Platform.isAndroid,
          startupDataDirectory: AppDatabase.startupDataDirectory,
          environment: Platform.environment,
        ),
        expected,
      );
    });
  });
}
