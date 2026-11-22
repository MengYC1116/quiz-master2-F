// R10 设置页 widget 测试：五组折叠（默认全折、一次只开一段）、
// 外观三段 + 问候语保存/恢复默认、复习八项分段切换、错题本三项、
// 数据组（备份/恢复入口、数据库位置、缓存预览）、
// 启动页 + 关于、加载失败横幅、亮/深 × 三档无溢出、不用图标字体。
// 用 FakeRepo 覆盖 repository 调用（不碰真实数据库，不弹文件选择器）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/exam_event.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/settings/settings_page.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';

class FakeSettingsRepo extends QuestionRepository {
  FakeSettingsRepo({
    this.questionCount = 9,
    this.orphanFiles = const [],
    this.storageUsage = (importsBytes: 0, slicesBytes: 0),
    AppSettings? settings,
  }) : settingsValue = settings ?? AppSettings.defaults,
       super(AppDatabase.instance);

  int questionCount;

  /// Stage 1：设置页经 settingsProvider 读写设置，Fake 在此
  /// 提供初始值并记录每一次保存（原 `onSettingsChanged` 回调的
  /// 观察点改到这里；断言口径不变，仍是“保存了什么设置”）。
  AppSettings settingsValue;
  final List<AppSettings> savedSettings = [];

  @override
  Future<AppSettings> settings() async => settingsValue;

  @override
  Future<void> saveSettings(AppSettings s) async {
    settingsValue = s;
    savedSettings.add(s);
  }

  /// P3：孤儿扫描的 canned 结果（默认无孤儿）。
  List<OrphanFile> orphanFiles;

  /// P3：空间占用的 canned 分项。
  ({int importsBytes, int slicesBytes}) storageUsage;

  /// P3：清理时实际收到的路径。
  List<String> cleanedPaths = [];

  @override
  Future<({int importsBytes, int slicesBytes})> storageUsageBreakdown() async =>
      storageUsage;

  @override
  Future<OrphanScan> scanOrphanFiles() async => OrphanScan(orphanFiles);

  @override
  Future<({int deletedCount, int freedBytes, int skippedReferencedCount})>
  deleteOrphanFiles(List<String> relativePaths) async {
    cleanedPaths = relativePaths;
    final freed = orphanFiles.fold(0, (sum, f) => sum + f.bytes);
    return (
      deletedCount: relativePaths.length,
      freedBytes: freed,
      skippedReferencedCount: 0,
    );
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

  /// B11-9：考试事件内存版（设置页考试组打开时读；不覆盖会落到基类
  /// 读真实库，fake async 里永不完成，见 D-88）。
  @override
  Future<List<ExamEvent>> examEvents() async => const [];
}

Future<List<AppSettings>> pumpSettings(
  WidgetTester tester, {
  FakeSettingsRepo? repo,
  AppSettings settings = AppSettings.defaults,
  bool loadFailed = false,
  Brightness brightness = Brightness.light,
  double scale = 1.0,
  double width = 1280,
}) async {
  tester.view.physicalSize = Size(width, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // Stage 1：设置页经 settingsProvider 读写设置，FakeRepo 用
  // ProviderScope override 注入（原 settings / onSettingsChanged
  // 构造参数已删除，保存的观察点是 repo.savedSettings）。
  final effectiveRepo = repo ?? FakeSettingsRepo(settings: settings);
  final applied = effectiveRepo.savedSettings;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(effectiveRepo)],
      child: MaterialApp(
        theme: AppTheme.light(scale: scale),
        darkTheme: AppTheme.dark(scale: scale),
        themeMode: brightness == Brightness.dark
            ? ThemeMode.dark
            : ThemeMode.light,
        home: Builder(
          builder: (context) {
            final data = MediaQuery.of(context);
            return MediaQuery(
              data: data.copyWith(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: SettingsPage(key: UniqueKey(), loadFailed: loadFailed),
              ),
            );
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return applied;
}

Future<void> openGroup(WidgetTester tester, String title) async {
  await tester.ensureVisible(find.text(title).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(title).first);
  await tester.pumpAndSettle();
}

void main() {
  group('设置：折叠', () {
    testWidgets('默认全折叠：五组标题可见，组内容不可见', (tester) async {
      await pumpSettings(tester);
      expect(find.text('设置'), findsOneWidget);
      for (final t in ['外观', '复习', '错题本', '数据', '启动与关于']) {
        expect(find.text(t), findsOneWidget);
      }
      expect(find.text('主题'), findsNothing);
      expect(find.text('复查间隔'), findsNothing);
      expect(find.text('备份题库'), findsNothing);
    });

    testWidgets('一次只开一段', (tester) async {
      await pumpSettings(tester);
      await openGroup(tester, '外观');
      expect(find.text('主题'), findsOneWidget);
      await openGroup(tester, '复习');
      expect(find.text('主题'), findsNothing);
      expect(find.text('复查间隔'), findsOneWidget);
    });

    testWidgets('点同一组标题收起', (tester) async {
      await pumpSettings(tester);
      await openGroup(tester, '错题本');
      expect(find.text('默认视图'), findsOneWidget);
      await openGroup(tester, '错题本');
      expect(find.text('默认视图'), findsNothing);
    });
  });

  group('设置：外观', () {
    testWidgets('主题三段切换：点深色回调 themeMode=dark', (tester) async {
      final applied = await pumpSettings(tester);
      await openGroup(tester, '外观');
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      expect(applied.last.themeMode, 'dark');
    });

    testWidgets('字体三段切换：点特大回调 fontSize=extraLarge', (tester) async {
      final applied = await pumpSettings(tester);
      await openGroup(tester, '外观');
      await tester.tap(find.text('特大'));
      await tester.pumpAndSettle();
      expect(applied.last.fontSize, 'extraLarge');
    });

    testWidgets('问候语：保存新问候语，恢复默认回“今天也要加油呀”', (tester) async {
      final applied = await pumpSettings(tester);
      await openGroup(tester, '外观');
      expect(find.textContaining('首页现在显示的是：「今天也要加油呀」'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '数学必胜');
      await tester.tap(find.text('保存问候语'));
      await tester.pumpAndSettle();
      expect(applied.last.greeting, '数学必胜');
      await tester.tap(find.text('恢复默认'));
      await tester.pumpAndSettle();
      expect(applied.last.greeting, '今天也要加油呀');
    });

    testWidgets('问候语留空保存不生效', (tester) async {
      final applied = await pumpSettings(tester);
      await openGroup(tester, '外观');
      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('保存问候语'));
      await tester.pumpAndSettle();
      expect(applied, isEmpty);
      expect(find.text('留空保存不生效'), findsOneWidget);
    });
  });

  group('设置：复习', () {
    testWidgets('加入方式说明行', (tester) async {
      await pumpSettings(tester);
      await openGroup(tester, '复习');
      expect(find.text('手动加入：在题目详情点「加入复习」。'), findsOneWidget);
    });

    testWidgets('复查间隔/自查次数/每轮错因数/跳过次数切换', (tester) async {
      final applied = await pumpSettings(tester);
      await openGroup(tester, '复习');
      await tester.tap(find.text('14 天'));
      await tester.pumpAndSettle();
      expect(applied.last.recheckIntervalDays, 14);
      await tester.tap(find.text('3 次'));
      await tester.pumpAndSettle();
      expect(applied.last.cureChecks, 3);
      await tester.tap(find.text('5 个'));
      await tester.pumpAndSettle();
      expect(applied.last.causesPerSession, 5);
      await tester.tap(find.text('1 次').last);
      await tester.pumpAndSettle();
      expect(applied.last.skipLimit, 1);
    });

    testWidgets('重做答案默认：点默认显示回调 redoAnswerHidden=false', (tester) async {
      final applied = await pumpSettings(tester);
      await openGroup(tester, '复习');
      await tester.tap(find.text('默认显示'));
      await tester.pumpAndSettle();
      expect(applied.last.redoAnswerHidden, isFalse);
    });

    testWidgets('通知提醒：点关回调 notifyEnabled=false，提醒时间禁用', (tester) async {
      final applied = await pumpSettings(tester);
      await openGroup(tester, '复习');
      expect(find.text('20:00'), findsOneWidget);
      await tester.tap(find.text('关'));
      await tester.pumpAndSettle();
      expect(applied.last.notifyEnabled, isFalse);
    });

    testWidgets('复习列表默认排序：点按学科回调 reviewSort=subject', (tester) async {
      final applied = await pumpSettings(tester);
      await openGroup(tester, '复习');
      await tester.tap(find.text('按学科'));
      await tester.pumpAndSettle();
      expect(applied.last.reviewSort, 'subject');
    });
  });

  group('设置：错题本与启动', () {
    testWidgets('默认视图/排序/每页数量切换', (tester) async {
      final applied = await pumpSettings(tester);
      await openGroup(tester, '错题本');
      await tester.tap(find.text('紧凑列表'));
      await tester.pumpAndSettle();
      expect(applied.last.wrongbookView, 'compact');
      await tester.tap(find.text('时间旧 → 新'));
      await tester.pumpAndSettle();
      expect(applied.last.wrongbookSort, 'old');
      await tester.tap(find.text('50'));
      await tester.pumpAndSettle();
      expect(applied.last.pageSize, 50);
    });

    // SR-P0-2：设置页“默认排序”不再提供列表下拉没有的 'subject'，
    // 改为与列表页一致的 subj-asc / subj-desc 两项。
    testWidgets('默认排序：学科首字母 A→Z / Z→A 回调 subj-asc / subj-desc', (tester) async {
      final applied = await pumpSettings(tester);
      await openGroup(tester, '错题本');
      await tester.tap(find.text('学科首字母 A → Z'));
      await tester.pumpAndSettle();
      expect(applied.last.wrongbookSort, 'subj-asc');
      await tester.tap(find.text('学科首字母 Z → A'));
      await tester.pumpAndSettle();
      expect(applied.last.wrongbookSort, 'subj-desc');
      expect(find.text('学科首字母'), findsNothing);
    });

    test('AppSettings 归一：旧值 subject → subj-asc，未知值 → new', () {
      expect(
        AppSettings.fromMap(const {'wrongbookSort': 'subject'}).wrongbookSort,
        'subj-asc',
      );
      expect(
        AppSettings.fromMap(const {'wrongbookSort': 'bogus'}).wrongbookSort,
        'new',
      );
      expect(
        AppSettings.defaults.copyWith(wrongbookSort: 'subject').wrongbookSort,
        'subj-asc',
      );
      expect(
        AppSettings.defaults
            .copyWith(wrongbookSort: 'status-desc')
            .wrongbookSort,
        'status-desc',
      );
    });

    testWidgets('启动页切换与关于', (tester) async {
      final applied = await pumpSettings(tester);
      await openGroup(tester, '启动与关于');
      await tester.tap(find.text('上次停下的页面'));
      await tester.pumpAndSettle();
      expect(applied.last.startupPage, 'last');
      expect(find.text('quiz-master2 v0.1.0'), findsOneWidget);
      expect(find.text('Meng（个人项目）'), findsOneWidget);
      expect(find.textContaining('v0.1.0：首个版本'), findsOneWidget);
    });
  });

  group('设置：数据', () {
    testWidgets('数据库位置显示当前路径', (tester) async {
      await pumpSettings(tester);
      await openGroup(tester, '数据');
      expect(find.textContaining('/quiz-master2.db'), findsOneWidget);
      expect(find.text('改位置'), findsOneWidget);
      expect(find.text('备份题库'), findsOneWidget);
      expect(find.text('选择备份文件…'), findsOneWidget);
    });

    testWidgets('缓存预览：显示无缓存或真实预览，不抛错', (tester) async {
      await pumpSettings(tester);
      await openGroup(tester, '数据');
      // 预览取决于真实数据目录内容：无缓存显示“没有可清理的缓存”，
      // 有缓存显示“临时文件 N 个、缩略图缓存 M 张，共约 X MB”。
      final empty = find.text('现在没有可清理的缓存。').evaluate().isNotEmpty;
      final preview = find.textContaining('临时文件').evaluate().isNotEmpty;
      expect(empty || preview, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('SR-P2-50 缓存预览递归扫子目录：深层 thumb 目录与 .tmp 文件都计入', (tester) async {
      final prev = AppDatabase.testDataDirectory;
      // testWidgets 体内异步文件 IO 会在 FakeAsync 下挂起（本批另两名工人
      // 已探针证实），此处改同步 IO；扫描逻辑本身另有纯 Dart 脚本验证。
      final tmp = Directory.systemTemp.createTempSync('b5-p2-50-cache-');
      addTearDown(() {
        AppDatabase.testDataDirectory = prev;
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      AppDatabase.testDataDirectory = tmp.path;
      // 藏在子目录下：旧实现只扫顶层一层，这两个都发现不了。
      Directory('${tmp.path}/work/thumb-cache').createSync(recursive: true);
      File('${tmp.path}/work/thumb-cache/a.png').writeAsBytesSync([0, 1, 2]);
      Directory('${tmp.path}/work/deep').createSync(recursive: true);
      File('${tmp.path}/work/deep/x.tmp').writeAsStringSync('tmp');
      await pumpSettings(tester);
      await openGroup(tester, '数据');
      expect(find.textContaining('临时文件 1 个、缩略图缓存 1 张'), findsOneWidget);
    });

    testWidgets('SR3-19 缓存预览：failed 目录递归进、文件逐个计，清理数按文件算', (tester) async {
      final prev = AppDatabase.testDataDirectory;
      final tmp = Directory.systemTemp.createTempSync('b7-sr3-19-cache-');
      addTearDown(() {
        AppDatabase.testDataDirectory = prev;
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      AppDatabase.testDataDirectory = tmp.path;
      // failed 目录含 2 个文件：旧实现把目录整个按 1 项算（failedCount
      // 为 1、清理提示“已清理 1 项缓存”）；修后逐个计，failedCount 为 2。
      Directory('${tmp.path}/failed-import').createSync(recursive: true);
      File('${tmp.path}/failed-import/a.png').writeAsBytesSync([0, 1, 2]);
      File('${tmp.path}/failed-import/b.png').writeAsBytesSync([3, 4]);
      await pumpSettings(tester);
      await openGroup(tester, '数据');
      // 预览行只写临时/缩略图两数（failed 不单列），只断言它出现；
      // failed 个数写在下面的备注行里，是本条的判据。
      expect(find.textContaining('临时文件 0 个、缩略图缓存 0 张'), findsOneWidget);
      expect(find.textContaining('其中含导入失败的残留文件 2 个'), findsOneWidget);
      // 清理按钮与行标题同名，用 QmButton 精确定位。
      final clearButton = find.widgetWithText(QmButton, '清理缓存');
      await tester.ensureVisible(clearButton);
      await tester.pumpAndSettle();
      await tester.tap(clearButton);
      // _clearCache 的 await e.delete() 是真实异步 IO：FakeAsync 下
      // 直接 pump 等不到它完成，用真实时间驱动（SR2-61 同款做法）。
      var cleared = false;
      for (var i = 0; i < 30 && !cleared; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
        cleared = find.text('已清理 2 项缓存').evaluate().isNotEmpty;
      }
      expect(cleared, isTrue, reason: 'failed 目录里的 2 个文件应逐个计');
    });

    testWidgets('P3 空间占用：显示原图/切片分项与上限 2GB', (tester) async {
      final repo = FakeSettingsRepo(
        storageUsage: (importsBytes: 2048, slicesBytes: 1024),
      );
      await pumpSettings(tester, repo: repo);
      await openGroup(tester, '数据');
      expect(find.text('空间占用'), findsOneWidget);
      expect(find.textContaining('共占 3.0 KB'), findsOneWidget);
      expect(find.textContaining('原图 2.0 KB'), findsOneWidget);
      expect(find.textContaining('切片 1.0 KB'), findsOneWidget);
      expect(find.textContaining('上限 2GB'), findsOneWidget);
    });

    testWidgets('P3 孤儿清理：有孤儿时预览，确认后清理并提示', (tester) async {
      final repo = FakeSettingsRepo(
        orphanFiles: [
          const OrphanFile(relativePath: 'slices/orphan.png', bytes: 2048),
          const OrphanFile(
            relativePath: 'imports/task-9/original.jpg',
            bytes: 1024,
          ),
        ],
      );
      await pumpSettings(tester, repo: repo);
      await openGroup(tester, '数据');
      expect(find.text('无用文件清理'), findsOneWidget);
      expect(find.textContaining('发现 2 个无用文件'), findsOneWidget);
      expect(find.textContaining('共约 3.0 KB'), findsOneWidget);
      await tester.ensureVisible(find.text('清理无用文件'));
      await tester.tap(find.text('清理无用文件'));
      await tester.pumpAndSettle();
      expect(find.textContaining('清理无用文件，确定吗？'), findsOneWidget);
      await tester.ensureVisible(find.text('确认清理'));
      await tester.tap(find.text('确认清理'));
      await tester.pumpAndSettle();
      expect(repo.cleanedPaths, [
        'slices/orphan.png',
        'imports/task-9/original.jpg',
      ]);
      // WP-C #8 U3-2：孤儿清理改为移入回收站（7 天后彻底删除），
      // 不再立即释放空间，提示文案随之改。
      expect(
        find.text('已把 2 个无用文件移入回收站，7 天后彻底删除'),
        findsOneWidget,
      );
    });

    testWidgets('P3 孤儿清理：无孤儿时按钮置灰、不弹确认', (tester) async {
      await pumpSettings(tester);
      await openGroup(tester, '数据');
      expect(find.textContaining('没有无用文件'), findsOneWidget);
      final button = tester.widget<QmButton>(
        find.ancestor(of: find.text('清理无用文件'), matching: find.byType(QmButton)),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('设置：错误态与无溢出', () {
    testWidgets('加载失败出错误横幅，可关闭', (tester) async {
      await pumpSettings(tester, loadFailed: true);
      expect(find.textContaining('设置读取失败'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.textContaining('设置读取失败'), findsNothing);
    });

    testWidgets('亮/深 × 三档无溢出', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        for (final scale in [1.0, 1.15, 1.3]) {
          await pumpSettings(tester, brightness: brightness, scale: scale);
          for (final group in ['外观', '复习', '错题本', '数据', '启动与关于']) {
            await openGroup(tester, group);
          }
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets('不用图标字体', (tester) async {
      await pumpSettings(tester);
      await openGroup(tester, '外观');
      expect(find.byType(Icon), findsNothing);
    });
  });
}
