// B11-9 考试倒计时：倒计时数学（单元）+ 存储往返（内存库）+
// 设置页考试管理 / 首页倒计时条（widget）。
// 考试事件与试卷完全脱钩（独立数据，见 lib/models/exam_event.dart）。
// 测试一律用内存库 / FakeRepo，不碰真实库。
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/exam_event.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/home/home_page.dart';
import 'package:quiz_master2/modules/settings/settings_page.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/theme/app_theme.dart';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

ExamEvent _event(String id, String name, DateTime date) =>
    ExamEvent(id: id, name: name, date: _day(date));

void main() {
  // ---------- 纯函数：倒计时数学 ----------
  group('B11-9 倒计时数学', () {
    final today = DateTime(2026, 11, 15, 23, 59);

    test('N = 考试日期 - 今天，按日历日，不含时分秒', () {
      expect(daysUntilExam(DateTime(2026, 11, 15), today), 0);
      expect(daysUntilExam(DateTime(2026, 11, 16), today), 1);
      expect(daysUntilExam(DateTime(2026, 11, 14), today), -1);
      expect(daysUntilExam(DateTime(2026, 11, 22), today), 7);
      expect(daysUntilExam(DateTime(2026, 12, 15), today), 30);
    });

    test('同一天内任何时刻结果相同（时分秒不影响）', () {
      expect(
        daysUntilExam(
          DateTime(2026, 11, 16, 0, 1),
          DateTime(2026, 11, 15, 23, 59),
        ),
        1,
      );
      expect(
        daysUntilExam(
          DateTime(2026, 11, 15, 0, 0),
          DateTime(2026, 11, 15, 23, 59),
        ),
        0,
      );
    });

    test('最近一场：未过期的取 N 最小，今天优先于明天', () {
      final events = [
        _event('e30', '月考', DateTime(2026, 12, 15)),
        _event('e1', '小测', DateTime(2026, 11, 16)),
        _event('e0', '期中', DateTime(2026, 11, 15)),
      ];
      expect(nearestExamEvent(events, today)?.id, 'e0');
      expect(nearestExamEvent(events.sublist(0, 2), today)?.id, 'e1');
    });

    test('最近一场：过期不参与竞争（有未来场时）', () {
      final events = [
        _event('past', '上次月考', DateTime(2026, 11, 10)),
        _event('future', '期末', DateTime(2026, 11, 20)),
      ];
      expect(nearestExamEvent(events, today)?.id, 'future');
    });

    test('最近一场：全部过期时取最近过期那场', () {
      final events = [
        _event('old', '期中', DateTime(2026, 11, 1)),
        _event('recent', '月考', DateTime(2026, 11, 14)),
      ];
      expect(nearestExamEvent(events, today)?.id, 'recent');
    });

    test('最近一场：无考试返回 null；同一天两场取列表先出现者', () {
      expect(nearestExamEvent([], today), isNull);
      final events = [
        _event('a', '甲', DateTime(2026, 11, 20)),
        _event('b', '乙', DateTime(2026, 11, 20)),
      ];
      expect(nearestExamEvent(events, today)?.id, 'a');
    });

    test('文案：未来 / 今天 / 已过期', () {
      expect(
        examCountdownText(_event('e', '期末考试', DateTime(2026, 11, 20)), today),
        '距离 期末考试 还有 5 天',
      );
      expect(
        examCountdownText(_event('e', '期末考试', DateTime(2026, 11, 15)), today),
        '今天 期末考试',
      );
      expect(
        examCountdownText(_event('e', '期末考试', DateTime(2026, 11, 10)), today),
        '期末考试 已考完',
      );
    });

    test('标红阈值：0~7 天红，8 天以上与过期不红', () {
      for (var d = 0; d <= 7; d++) {
        expect(isExamCountdownNear(d), isTrue, reason: 'days=$d');
      }
      expect(isExamCountdownNear(8), isFalse);
      expect(isExamCountdownNear(30), isFalse);
      expect(isExamCountdownNear(-1), isFalse);
    });

    test('日期格式补零；toJson/fromJson 往返；坏行返回 null', () {
      expect(formatExamEventDate(DateTime(2026, 1, 5)), '2026-01-05');
      final e = _event('e1', '期末考试', DateTime(2026, 11, 20));
      expect(ExamEvent.fromJson(e.toJson()), isNotNull);
      expect(ExamEvent.fromJson(e.toJson())?.name, '期末考试');
      expect(ExamEvent.fromJson(e.toJson())?.date, DateTime(2026, 11, 20));
      expect(
        ExamEvent.fromJson({'id': '', 'name': 'x', 'date': '2026-11-20'}),
        isNull,
      );
      expect(
        ExamEvent.fromJson({'id': 'e', 'name': 'x', 'date': 'not-a-date'}),
        isNull,
      );
      expect(ExamEvent.fromJson({'id': 'e', 'date': '2026-11-20'}), isNull);
      expect(ExamEvent.fromJson('nope'), isNull);
    });
  });

  // ---------- 存储：settings 表 JSON 往返 ----------
  group('B11-9 存储（内存库）', () {
    Future<QuizDatabase> openTestDb() => AppDatabase.openForTest();

    test('空库读出空列表；写后读回一致；坏 JSON 按空列表', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      expect(await AppDatabase.loadExamEventsFrom(db), isEmpty);

      final events = [
        _event('e1', '期中', DateTime(2026, 11, 20)),
        _event('e2', '期末', DateTime(2026, 12, 25)),
      ];
      await AppDatabase.saveExamEventsInto(db, events);
      final back = await AppDatabase.loadExamEventsFrom(db);
      expect(back.map((e) => e.id).toList(), ['e1', 'e2']);
      expect(back.first.name, '期中');
      expect(back.first.date, DateTime(2026, 11, 20));

      // 坏 JSON / 坏行：不抛错，坏行跳过。
      await db.customInsert(
        'INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)',
        variables: [
          Variable.withString(AppDatabase.examEventsKey),
          Variable.withString('not json'),
        ],
      );
      expect(await AppDatabase.loadExamEventsFrom(db), isEmpty);
      await db.customInsert(
        'INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)',
        variables: [
          Variable.withString(AppDatabase.examEventsKey),
          Variable.withString(
            '[{"id":"ok","name":"期末","date":"2026-12-25"},'
            '{"id":"","name":"坏行","date":"2026-12-25"}]',
          ),
        ],
      );
      final partial = await AppDatabase.loadExamEventsFrom(db);
      expect(partial.map((e) => e.id).toList(), ['ok']);
    });

    test('经 repository 增删改：按日期升序；同 id 覆盖；删只删自己', () async {
      final db = await openTestDb();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => AppDatabase.resetForTest());
      final repo = QuestionRepository(AppDatabase.instance);

      expect(await repo.examEvents(), isEmpty);
      await repo.saveExamEvent(_event('e2', '期末', DateTime(2026, 12, 25)));
      await repo.saveExamEvent(_event('e1', '期中', DateTime(2026, 11, 20)));
      expect((await repo.examEvents()).map((e) => e.id).toList(), ['e1', 'e2']);
      // 改名 + 改日期：同 id 覆盖，顺序按新日期重排。
      await repo.saveExamEvent(_event('e1', '期中考试', DateTime(2026, 12, 1)));
      final renamed = await repo.examEvents();
      expect(renamed.map((e) => e.id).toList(), ['e1', 'e2']);
      expect(renamed.first.name, '期中考试');
      // 删 e1：e2 不动。
      await repo.deleteExamEvent('e1');
      expect((await repo.examEvents()).map((e) => e.id).toList(), ['e2']);
      // 删不存在的 id：不抛错、不动列表。
      await repo.deleteExamEvent('nope');
      expect((await repo.examEvents()).length, 1);
    });
  });

  // ---------- Widget：设置页考试管理 ----------
  group('B11-9 设置页考试管理', () {
    testWidgets('默认全折：六组标题可见，考试内容不可见', (tester) async {
      await _pumpSettings(tester);
      for (final t in ['外观', '复习', '错题本', '考试', '数据', '启动与关于']) {
        expect(find.text(t), findsOneWidget);
      }
      expect(find.text('加一场考试'), findsNothing);
    });

    testWidgets('打开考试组：空态提示；加一场考试后出现在列表', (tester) async {
      final repo = _FakeExamRepo();
      await _pumpSettings(tester, repo: repo);
      await _openGroup(tester, '考试');
      expect(find.text('还没有考试，加一场吧。'), findsOneWidget);

      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('exam-name-field')),
          matching: find.byType(EditableText),
        ),
        '期末考试',
      );
      await tester.tap(find.byKey(const Key('exam-date-button')));
      await tester.pumpAndSettle();
      // 日期选择器出现，OK 选当天。
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('exam-add-button')));
      await tester.pumpAndSettle();

      expect(repo.events.length, 1);
      expect(repo.events.single.name, '期末考试');
      expect(find.text('期末考试'), findsOneWidget);
      expect(find.textContaining('今天 期末考试'), findsOneWidget);
      expect(find.text('还没有考试，加一场吧。'), findsNothing);
    });

    testWidgets('改名：弹窗改名保存后列表更新', (tester) async {
      final repo = _FakeExamRepo()
        ..events = [
          _event('e1', '期中', DateTime.now().add(const Duration(days: 10))),
        ];
      await _pumpSettings(tester, repo: repo);
      await _openGroup(tester, '考试');
      expect(find.text('期中'), findsOneWidget);

      await tester.tap(find.byKey(const Key('exam-rename-e1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('exam-rename-field')),
        '期中考试',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(repo.events.single.name, '期中考试');
      expect(find.text('期中考试'), findsOneWidget);
      expect(find.text('期中'), findsNothing);
    });

    testWidgets('改日期：选日期后列表日期与倒计时更新', (tester) async {
      final now = DateTime.now();
      final repo = _FakeExamRepo()
        ..events = [_event('e1', '期末', DateTime(now.year, now.month, 10))];
      await _pumpSettings(tester, repo: repo);
      await _openGroup(tester, '考试');
      await tester.tap(find.byKey(const Key('exam-change-date-e1')));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      // 点当月 15 号那格（10 号场改到 15 号）。
      await tester.tap(find.text('15').first);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(repo.events.single.date.day, 15);
      expect(find.textContaining('15 ·'), findsOneWidget);
    });

    testWidgets('删除：确认后消失，回到空态', (tester) async {
      final repo = _FakeExamRepo()
        ..events = [
          _event('e1', '期中', DateTime.now().add(const Duration(days: 3))),
        ];
      await _pumpSettings(tester, repo: repo);
      await _openGroup(tester, '考试');
      await tester.tap(find.byKey(const Key('exam-delete-e1')));
      await tester.pumpAndSettle();
      expect(find.text('删除这场考试，确定吗？'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('删除'),
        ),
      );
      await tester.pumpAndSettle();

      expect(repo.events, isEmpty);
      expect(find.text('期中'), findsNothing);
      expect(find.text('还没有考试，加一场吧。'), findsOneWidget);
    });

    testWidgets('initialOpenGroup=exams：进来直接展开考试组', (tester) async {
      await _pumpSettings(tester, initialOpenGroup: 'exams');
      expect(find.text('加一场考试'), findsOneWidget);
      expect(find.text('主题'), findsNothing);
    });
  });

  // ---------- Widget：首页倒计时条 ----------
  group('B11-9 首页倒计时条', () {
    testWidgets('无考试：不显示倒计时条', (tester) async {
      await _pumpHome(tester);
      expect(find.byKey(const Key('home-exam-countdown')), findsNothing);
    });

    testWidgets('5 天后：显示倒计时，标红，点按进设置', (tester) async {
      var settingsTaps = 0;
      final date = _day(DateTime.now().add(const Duration(days: 5)));
      await _pumpHome(
        tester,
        events: [_event('e1', '期末考试', date)],
        onGoSettings: () => settingsTaps++,
      );
      expect(find.text('距离 期末考试 还有 5 天'), findsOneWidget);
      expect(find.byKey(const Key('home-exam-countdown')), findsOneWidget);
      _expectCountdownColor(tester, '距离 期末考试 还有 5 天', isRed: true);

      await tester.tap(find.byKey(const Key('home-exam-countdown')));
      await tester.pumpAndSettle();
      expect(settingsTaps, 1);
    });

    testWidgets('10 天后：显示倒计时，不标红', (tester) async {
      final date = _day(DateTime.now().add(const Duration(days: 10)));
      await _pumpHome(tester, events: [_event('e1', '期末考试', date)]);
      expect(find.text('距离 期末考试 还有 10 天'), findsOneWidget);
      _expectCountdownColor(tester, '距离 期末考试 还有 10 天', isRed: false);
    });

    testWidgets('今天：显示“今天考试”，标红', (tester) async {
      await _pumpHome(tester, events: [_event('e1', '期末考试', DateTime.now())]);
      expect(find.text('今天 期末考试'), findsOneWidget);
      _expectCountdownColor(tester, '今天 期末考试', isRed: true);
    });

    testWidgets('已过期：显示“已考完”，不标红', (tester) async {
      final date = _day(DateTime.now().subtract(const Duration(days: 2)));
      await _pumpHome(tester, events: [_event('e1', '期末考试', date)]);
      expect(find.text('期末考试 已考完'), findsOneWidget);
      _expectCountdownColor(tester, '期末考试 已考完', isRed: false);
    });

    testWidgets('多场：只显示最近一场', (tester) async {
      final now = DateTime.now();
      await _pumpHome(
        tester,
        events: [
          _event('e30', '期末', _day(now.add(const Duration(days: 30)))),
          _event('e1', '小测', _day(now.add(const Duration(days: 1)))),
        ],
      );
      expect(find.text('距离 小测 还有 1 天'), findsOneWidget);
      expect(find.textContaining('期末'), findsNothing);
    });
  });
}

/// 倒计时文字颜色：红 = 亮色主题 errInk，不红 = 常规墨色。
void _expectCountdownColor(
  WidgetTester tester,
  String text, {
  required bool isRed,
}) {
  final widget = tester.widget<Text>(find.text(text));
  final palette = DesignTokens.of(Brightness.light);
  expect(widget.style?.color, isRed ? palette.errInk : palette.ink);
}

// ---------- 测试用 Fake ----------

/// 设置页测试用：考试事件存在内存列表里；其余只覆盖设置页 initState
/// 与考试组会调的方法（all 问候语计数用；数据组扫描不走这里）。
class _FakeExamRepo extends QuestionRepository {
  _FakeExamRepo() : super(AppDatabase.instance);

  List<ExamEvent> events = [];

  /// Stage 1：设置页经 settingsProvider 读设置，Fake 返回默认值
  /// （考试管理本身不改设置；保存如发生也只记在内存里）。
  AppSettings settingsValue = AppSettings.defaults;

  @override
  Future<AppSettings> settings() async => settingsValue;

  @override
  Future<void> saveSettings(AppSettings s) async {
    settingsValue = s;
  }

  @override
  Future<List<ExamEvent>> examEvents() async {
    final list = List<ExamEvent>.of(events);
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
  Future<List<Question>> all({bool includeArchived = false}) async => const [];
}

Future<void> _pumpSettings(
  WidgetTester tester, {
  _FakeExamRepo? repo,
  String? initialOpenGroup,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // Stage 1：设置页经 settingsProvider 读写设置，Fake 用
  // ProviderScope override 注入（原 settings / onSettingsChanged
  // 构造参数已删除）。
  final effectiveRepo = repo ?? _FakeExamRepo();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(effectiveRepo)],
      child: MaterialApp(
        theme: AppTheme.light(scale: 1.0),
        home: Scaffold(body: SettingsPage(initialOpenGroup: initialOpenGroup)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openGroup(WidgetTester tester, String title) async {
  await tester.ensureVisible(find.text(title).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(title).first);
  await tester.pumpAndSettle();
}

/// 首页测试用：考试事件可配，其余全返回空（焦点卡走空状态）。
class _FakeHomeRepo extends QuestionRepository {
  _FakeHomeRepo({this.events = const []}) : super(AppDatabase.instance);

  List<ExamEvent> events;

  @override
  Future<List<ExamEvent>> examEvents() async => events;

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<Map<String, int>> homeRevCounts() async => const {};

  @override
  Future<Map<String, int>> pendingOrganizeBySubject() async => const {};

  @override
  Future<({String kind, String subjectId, String title})?> recentTask() async =>
      null;

  @override
  Future<List<Question>> dueToday({bool includeArchived = false}) async =>
      const [];

  @override
  Future<List<CauseRecord>> causeRecords() async => const [];

  /// 十二批功能 4（D-91）：最近查看列表（默认空；不覆盖会走到真实库，
  /// fake async 里永不完成，见 D-88）。
  @override
  Future<List<({Question question, DateTime viewedAt})>>
  recentlyViewedQuestions() async => const [];
}

Future<void> _pumpHome(
  WidgetTester tester, {
  List<ExamEvent> events = const [],
  void Function()? onGoSettings,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      home: Scaffold(
        body: HomePage(
          repo: _FakeHomeRepo(events: events),
          settings: AppSettings.defaults,
          onGoCollect: () {},
          onGoOrganize: () {},
          onGoWrongbook: (_) {},
          onGoReview: () {},
          onGoSettings: onGoSettings,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
