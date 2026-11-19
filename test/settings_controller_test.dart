// ARCH-PLAN-A Stage 0 → Stage 1：SettingsNotifier 单测（不启动 widget）。
// Stage 1 迁移：Stage 0 的纯 Dart 类 SettingsController 改为
// AsyncNotifier（见 lib/state/settings_notifier.dart），构造方式
// 从 `SettingsController(repo)` 改为 `ProviderContainer.test` +
// `repositoryProvider.overrideWithValue(repo)` 注入（见
// docs/ui-replication/A-READING-GUIDE.md）；13 个单测的断言原样保留，
// 只改拿 notifier 的方式。另新增 3 个 Provider 行为测试
// （build 读库 / saveSettings 写库并更新 state / reloadSettings 重读）。
// 覆盖问候语校验、考试事件增删改、题数统计、备份恢复解析/分发、
// 缓存清理；FakeRepo 只覆盖 Notifier 实际调的方法，不碰真实库。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/exam_event.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/state/settings_notifier.dart';

class FakeControllerRepo extends QuestionRepository {
  FakeControllerRepo({this.questionCount = 0}) : super(AppDatabase.instance);

  int questionCount;
  List<ExamEvent> events = [];
  bool backupFailedFlag = false;
  List<int>? exportedBytes;
  List<int>? restoredZipBytes;
  Map<String, dynamic>? restoredJson;

  /// Provider 的 build() 读设置：Fake 直接返回内存值，
  /// 绝不碰真实库（单测里只调方法、不读 state 时也一样，
  /// build() 在 notifier 首次被取用时就会跑）。
  AppSettings settingsValue = AppSettings.defaults;

  @override
  Future<AppSettings> settings() async => settingsValue;

  @override
  Future<void> saveSettings(AppSettings s) async {
    settingsValue = s;
  }

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.generate(
        questionCount,
        (i) => Question(
          id: 'q$i',
          title: '题 $i',
          subjectId: 'math',
          createdAt: DateTime.now(),
          isOrganized: true,
          sliceKind: 'material',
          sliceText: '题',
        ),
      );

  @override
  Future<List<ExamEvent>> examEvents() async {
    final list = List<ExamEvent>.from(events);
    list.sort((a, b) => a.date.compareTo(b.date));
    return list;
  }

  @override
  Future<void> saveExamEvent(ExamEvent e) async {
    final i = events.indexWhere((x) => x.id == e.id);
    if (i >= 0) {
      events[i] = e;
    } else {
      events.add(e);
    }
  }

  @override
  Future<void> deleteExamEvent(String id) async {
    events.removeWhere((x) => x.id == id);
  }

  @override
  Future<List<int>> exportBackupZip() async => exportedBytes ?? [1, 2, 3];

  @override
  Future<void> setBackupFailed(bool failed) async {
    backupFailedFlag = failed;
  }

  @override
  Future<void> importBackupJson(Map<String, dynamic> data) async {
    restoredJson = data;
  }

  @override
  Future<List<String>> importBackupZip(List<int> bytes) async {
    restoredZipBytes = bytes;
    return const [];
  }
}

/// 拿一个已注入 FakeRepo 的容器（Stage 1 的标准取法），
/// 测试结束时自动 dispose。
ProviderContainer makeContainer(FakeControllerRepo repo) {
  final container = ProviderContainer.test(
    overrides: [repositoryProvider.overrideWithValue(repo)],
  );
  addTearDown(container.dispose);
  return container;
}

/// 拿 notifier（只调方法、不读 state 的单测用）。
SettingsNotifier makeNotifier(FakeControllerRepo repo) =>
    makeContainer(repo).read(settingsProvider.notifier);

void main() {
  group('SettingsNotifier：问候语', () {
    test('留空保存抛校验异常，文案与原页内提示一致', () {
      final notifier = makeNotifier(FakeControllerRepo());
      expect(
        () => notifier.greetingToSave(AppSettings.defaults, '   '),
        throwsA(
          isA<SettingsValidationException>().having(
            (e) => e.message,
            'message',
            '留空保存不生效',
          ),
        ),
      );
    });

    test('正常保存去首尾空格，其余设置不动', () {
      final notifier = makeNotifier(FakeControllerRepo());
      final next = notifier.greetingToSave(
        AppSettings.defaults.copyWith(themeMode: 'dark'),
        '  早呀  ',
      );
      expect(next.greeting, '早呀');
      expect(next.themeMode, 'dark');
    });

    test('恢复默认问候语', () {
      final notifier = makeNotifier(FakeControllerRepo());
      final next = notifier.defaultGreeting(
        AppSettings.defaults.copyWith(greeting: '自定义'),
      );
      expect(next.greeting, SettingsNotifier.defaultGreetingText);
      expect(next.greeting, '今天也要加油呀');
    });
  });

  group('SettingsNotifier：考试事件', () {
    test('新增成功：写库、id 带 exam-event- 前缀、日期只留年月日', () async {
      final repo = FakeControllerRepo();
      final notifier = makeNotifier(repo);
      final event = await notifier.addExamEvent(
        existing: const [],
        name: ' 期末考试 ',
        date: DateTime(2026, 12, 25, 15, 30),
      );
      expect(event.id.startsWith('exam-event-'), isTrue);
      expect(event.name, '期末考试');
      expect(event.date, DateTime(2026, 12, 25));
      expect((await repo.examEvents()).length, 1);
    });

    test('新增校验：空名 / 未选日期 / 重名各抛对应文案', () async {
      final repo = FakeControllerRepo();
      final notifier = makeNotifier(repo);
      await notifier.addExamEvent(
        existing: const [],
        name: '期中',
        date: DateTime(2026, 11, 20),
      );
      final existing = await repo.examEvents();
      await expectLater(
        notifier.addExamEvent(
          existing: existing,
          name: ' ',
          date: DateTime.now(),
        ),
        throwsA(
          isA<SettingsValidationException>().having(
            (e) => e.message,
            'message',
            '先填一个考试名称',
          ),
        ),
      );
      await expectLater(
        notifier.addExamEvent(existing: existing, name: '月考', date: null),
        throwsA(
          isA<SettingsValidationException>().having(
            (e) => e.message,
            'message',
            '先选一个考试日期',
          ),
        ),
      );
      await expectLater(
        notifier.addExamEvent(
          existing: existing,
          name: '期中',
          date: DateTime(2026, 12, 1),
        ),
        throwsA(
          isA<SettingsValidationException>().having(
            (e) => e.message,
            'message',
            '已经有了这场考试',
          ),
        ),
      );
      expect((await repo.examEvents()).length, 1);
    });

    test('改名：重名抛异常；改名与改日期成功写库', () async {
      final repo = FakeControllerRepo();
      final notifier = makeNotifier(repo);
      final a = await notifier.addExamEvent(
        existing: const [],
        name: '期中',
        date: DateTime(2026, 11, 20),
      );
      // 第二场直接写库给显式 id：addExamEvent 的 id 用毫秒时间戳，
      // 同一毫秒内连加两场会撞 id（原页内方案即如此，见 D-33），
      // 本测试不依赖时钟粒度。
      final b = ExamEvent(
        id: 'exam-event-b',
        name: '期末',
        date: DateTime(2026, 12, 25),
      );
      await repo.saveExamEvent(b);
      var existing = await repo.examEvents();
      await expectLater(
        notifier.renameExamEvent(event: a, newName: '期末', existing: existing),
        throwsA(
          isA<SettingsValidationException>().having(
            (e) => e.message,
            'message',
            '已经有了这场考试',
          ),
        ),
      );
      await notifier.renameExamEvent(
        event: a,
        newName: '期中考试',
        existing: existing,
      );
      await notifier.changeExamEventDate(b, DateTime(2027, 1, 10, 9, 0));
      existing = await repo.examEvents();
      expect(existing.map((e) => e.name), contains('期中考试'));
      expect(
        existing.firstWhere((e) => e.id == b.id).date,
        DateTime(2027, 1, 10),
      );
    });

    test('删除只删该场，不动其他考试', () async {
      final repo = FakeControllerRepo();
      final notifier = makeNotifier(repo);
      final a = await notifier.addExamEvent(
        existing: const [],
        name: '期中',
        date: DateTime(2026, 11, 20),
      );
      // 见上一个测试：第二场直接写库给显式 id，不依赖毫秒时间戳。
      await repo.saveExamEvent(
        ExamEvent(id: 'exam-event-b', name: '期末', date: DateTime(2026, 12, 25)),
      );
      await notifier.deleteExamEvent(a.id);
      final left = await repo.examEvents();
      expect(left.length, 1);
      expect(left.single.name, '期末');
    });
  });

  group('SettingsNotifier：题数统计与备份恢复', () {
    test('题数统计含已归档（与恢复确认文案口径一致）', () async {
      final notifier = makeNotifier(FakeControllerRepo(questionCount: 9));
      expect(await notifier.loadQuestionCount(), 9);
    });

    test('备份失败标志：记失败与清除各调一次写库', () async {
      final repo = FakeControllerRepo();
      final notifier = makeNotifier(repo);
      await notifier.markBackupFailed();
      expect(repo.backupFailedFlag, isTrue);
      await notifier.clearBackupFailedFlag();
      expect(repo.backupFailedFlag, isFalse);
    });

    test('解析备份：不存在的文件抛读失败异常', () async {
      final notifier = makeNotifier(FakeControllerRepo());
      await expectLater(
        notifier.parseRestoreFile('/tmp/不存在的备份.qm2backup'),
        throwsA(isA<RestoreFileReadException>()),
      );
    });

    test('GPT-P1：解析 zip 备份返回文件本身的字节（恢复用这份字节）', () async {
      final notifier = makeNotifier(FakeControllerRepo());
      final dir = await Directory.systemTemp.createTemp('qm2-p1-');
      try {
        final copy = File('${dir.path}/b3-old-backup.zip');
        final original = await File(
          'test/fixtures/b3-old-backup.zip',
        ).readAsBytes();
        await copy.writeAsBytes(original);
        final parsed = await notifier.parseRestoreFile(copy.path);
        expect(parsed.zipBytes, original);
        expect(parsed.data['questions'], isA<List>());
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test(
      '解析备份：非 JSON 文本抛 FormatException；无版本信息的 JSON 抛 BackupRestoreException',
      () async {
        final notifier = makeNotifier(FakeControllerRepo());
        final dir = await Directory.systemTemp.createTemp('qm2-a1-');
        try {
          final bad = File('${dir.path}/bad.qm2backup')
            ..writeAsStringSync('not json at all');
          await expectLater(
            notifier.parseRestoreFile(bad.path),
            throwsA(isA<FormatException>()),
          );
          final v1 = File('${dir.path}/v1.qm2backup')
            ..writeAsStringSync('{"questions": [], "subjects": []}');
          await expectLater(
            notifier.parseRestoreFile(v1.path),
            throwsA(isA<BackupRestoreException>()),
          );
        } finally {
          await dir.delete(recursive: true);
        }
      },
    );

    test('恢复分发：zip 字节走字节恢复，JSON 数据走对象恢复', () async {
      final repo = FakeControllerRepo();
      final notifier = makeNotifier(repo);
      await notifier.restoreBackup(zipBytes: [1, 2, 3]);
      expect(repo.restoredZipBytes, [1, 2, 3]);
      expect(repo.restoredJson, isNull);
      await notifier.restoreBackup(jsonData: {'questions': []});
      expect(repo.restoredJson, {'questions': []});
    });
  });

  group('SettingsNotifier：缓存清理', () {
    test('清理只删预览里的项，返回实际删掉数', () async {
      final notifier = makeNotifier(FakeControllerRepo());
      final dir = await Directory.systemTemp.createTemp('qm2-a1-cache-');
      try {
        final f1 = File('${dir.path}/a.tmp')..writeAsStringSync('x');
        final f2 = File('${dir.path}/b.cache')..writeAsStringSync('yy');
        final preview = CachePreview(
          tempCount: 2,
          thumbCount: 0,
          failedCount: 0,
          bytes: 3,
          items: [f1, f2],
        );
        expect(await notifier.clearCache(preview), 2);
        expect(f1.existsSync(), isFalse);
        expect(f2.existsSync(), isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('SettingsNotifier：Provider 行为（Stage 1 新增）', () {
    test('build 从库里读设置：Provider 初始值就是库里的设置', () async {
      final repo = FakeControllerRepo()
        ..settingsValue = AppSettings.defaults.copyWith(
          themeMode: 'dark',
          pageSize: 20,
        );
      final container = makeContainer(repo);
      final loaded = await container.read(settingsProvider.future);
      expect(loaded.themeMode, 'dark');
      expect(loaded.pageSize, 20);
    });

    test('saveSettings 写库并更新 state：写库失败时 state 不动', () async {
      final repo = FakeControllerRepo();
      final container = makeContainer(repo);
      final notifier = container.read(settingsProvider.notifier);
      await container.read(settingsProvider.future);
      final next = AppSettings.defaults.copyWith(themeMode: 'dark');
      await notifier.saveSettings(next);
      expect(repo.settingsValue.themeMode, 'dark');
      expect(container.read(settingsProvider).value?.themeMode, 'dark');
    });

    test('reloadSettings 从库里重读：库里改了，state 跟着变', () async {
      final repo = FakeControllerRepo();
      final container = makeContainer(repo);
      final notifier = container.read(settingsProvider.notifier);
      await container.read(settingsProvider.future);
      repo.settingsValue = AppSettings.defaults.copyWith(greeting: '恢复后的问候语');
      await notifier.reloadSettings();
      expect(container.read(settingsProvider).value?.greeting, '恢复后的问候语');
    });
  });
}
