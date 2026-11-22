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
      // resetForTest 同时清掉了 testDataDirectory，恢复它，
      // 免得同文件后续测试失去 flutter_test_config 的隔离。
      AppDatabase.testDataDirectory = tmp;
    });
  });

  group('当前平台委托', () {
    test('Linux 默认路径与环境一致（不依赖私有 wrapper）', () {
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
