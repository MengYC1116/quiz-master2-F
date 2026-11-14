// P0B2-3 左导航 + 调色板：
// (a) 学科速览区内部滚动、设置按钮固定在导航底部，不随速览滚动；
//     6 学科时设置在 720px 首屏内可见、可点；矮窗口 + 特大字号亦然。
// (b) _newSubjectColors 加青、粉：第 6、7 科颜色各不相同且不是数学蓝；
//     第 8 科起回落首色（orElse 保留）。
// 导航部分测纯展示组件 AppNavBar（不读库）；调色板部分走 SubjectsPage
// + FakeRepo（不碰真实数据库）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/subjects/subjects_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/app_shell.dart';

const _mathBlue = Color(0xFF2E7CF6);
const _cyan = Color(0xFF06B6D4);
const _pink = Color(0xFFEC4899);

/// 预设三科 + 化学 / 物理 / 生物（速览 take(5)，第 6 科不显示，
//  但学科数本身是触发“设置被顶出”的场景）。
final _sixSubjects = [
  ...Subject.all,
  Subject(id: 's4', name: '化学', color: const Color(0xFF7C5CFC), icon: '化'),
  Subject(id: 's5', name: '物理', color: const Color(0xFFF08A1D), icon: '物'),
  Subject(id: 's6', name: '生物', color: _cyan, icon: '生'),
];

Future<void> _pumpNav(
  WidgetTester tester, {
  double height = 720,
  double scale = 1.0,
  ValueChanged<String>? onNavigate,
}) async {
  tester.view.physicalSize = Size(1280, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: scale),
      home: Builder(
        builder: (context) {
          final data = MediaQuery.of(context);
          return MediaQuery(
            data: data.copyWith(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: SizedBox(
                height: height,
                child: AppNavBar(
                  route: '/home',
                  collapsed: false,
                  onNavigate: onNavigate ?? (_) {},
                  onToggleCollapsed: () {},
                  subjects: _sixSubjects,
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 设置固定在底部 + 学科行在速览滚动区内滚动的共用断言。
/// 注意：测试字体比真实字体宽，品牌字与速览计数行在测试里会换行变高，
/// 所以只断言“设置在视口内、无溢出、拖动滚动区能把首行滚出、末行滚入”，
/// 不断言各段的绝对像素高度（真实字体的几何以真机实测为准）。
Future<void> _expectSettingsPinnedAndScrollable(
  WidgetTester tester, {
  required double height,
}) async {
  const scrollKey = ValueKey('qm-nav-subject-scroll');
  final settings = tester.getRect(find.text('设置'));
  expect(settings.top, greaterThanOrEqualTo(0));
  expect(settings.bottom, lessThanOrEqualTo(height));
  expect(tester.takeException(), isNull);
  // 设置在滚动区之外，学科行在滚动区之内。
  expect(
    find.descendant(of: find.byKey(scrollKey), matching: find.text('设置')),
    findsNothing,
  );
  expect(
    find.descendant(of: find.byKey(scrollKey), matching: find.text('物理')),
    findsOneWidget,
  );
  // 末行（物理）初时在视口外；向上拖动滚动区后首行滚出、末行滚入。
  final scrollTop = tester.getRect(find.byKey(scrollKey)).top;
  expect(tester.getRect(find.text('物理')).bottom, greaterThan(height));
  await tester.drag(find.byKey(scrollKey), const Offset(0, -300));
  await tester.pumpAndSettle();
  expect(tester.getRect(find.text('数学')).bottom,
      lessThanOrEqualTo(scrollTop));
  expect(tester.getRect(find.text('物理')).top, lessThan(height));
  // 滚完设置仍在底部。
  expect(tester.getRect(find.text('设置')).bottom, lessThanOrEqualTo(height));
  expect(tester.takeException(), isNull);
}

void main() {
  group('P0B2-3 左导航：设置固定底部', () {
    testWidgets('6 学科、1280×720：设置按钮完整在首屏内，可点去 /settings',
        (tester) async {
      String? got;
      await _pumpNav(tester, onNavigate: (r) => got = r);
      final rect = tester.getRect(find.text('设置'));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(720));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('设置'));
      expect(got, '/settings');
      // take(5) 上限不动：第 4 科显示，第 6 科不进速览。
      expect(find.text('化学'), findsOneWidget);
      expect(find.text('生物'), findsNothing);
    });

    testWidgets('720 特大字号 1.3：设置仍在底部，学科行可内部滚动', (tester) async {
      await _pumpNav(tester, height: 720, scale: 1.3);
      await _expectSettingsPinnedAndScrollable(tester, height: 720);
    });

    testWidgets('矮窗口 600 标准字号：设置仍在底部，学科行可内部滚动',
        (tester) async {
      await _pumpNav(tester, height: 600, scale: 1.0);
      await _expectSettingsPinnedAndScrollable(tester, height: 600);
    });
  });

  group('P0B2-3 调色板：加青、粉', () {
    testWidgets('加到 7 科颜色各不相同，第 6、7 科不是数学蓝；第 8 科回落首色',
        (tester) async {
      final repo = _FakePaletteRepo();
      await _pumpSubjects(tester, repo: repo);
      await _openSection(tester, '学科');
      for (final name in ['物理', '化学', '生物', '历史', '地理']) {
        await tester.enterText(find.byType(TextField).first, name);
        await tester.tap(find.text('＋ 添加学科'));
        await tester.pumpAndSettle();
        expect(find.text(name), findsOneWidget);
      }
      final colors = repo.subjectsList.map((s) => s.color).toList();
      expect(colors, hasLength(8));
      // 轮换顺序：蓝 / 绿 / 红 / 紫 / 橙 / 青 / 粉。
      expect(colors[3], const Color(0xFF7C5CFC));
      expect(colors[4], const Color(0xFFF08A1D));
      expect(colors[5], _cyan);
      expect(colors[6], _pink);
      // 前 7 科颜色各不相同；第 6、7 科不是数学蓝。
      expect(colors.sublist(0, 7).toSet(), hasLength(7));
      expect(colors[5], isNot(_mathBlue));
      expect(colors[6], isNot(_mathBlue));
      // 第 8 科无新色可用，回落首色（orElse 保留）。
      expect(colors[7], _mathBlue);
    });
  });
}

class _FakePaletteRepo extends QuestionRepository {
  _FakePaletteRepo() : super(AppDatabase.instance);

  List<Subject> subjectsList = List.of(Subject.all);
  final List<Folder> savedFolders = [];

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsList);

  @override
  Future<List<Question>> all({bool includeArchived = false}) async => [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => [];

  @override
  Future<List<String>> tags() async => [];

  @override
  Future<List<Exam>> exams() async => [];

  @override
  Future<void> saveSubject(Subject s) async {
    final i = subjectsList.indexWhere((e) => e.id == s.id);
    if (i >= 0) {
      subjectsList[i] = s;
    } else {
      subjectsList.add(s);
    }
  }

  @override
  Future<void> saveFolder(Folder f) async => savedFolders.add(f);
}

Future<void> _pumpSubjects(
  WidgetTester tester, {
  required _FakePaletteRepo repo,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: SubjectsPage(key: UniqueKey(), repo: repo),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openSection(WidgetTester tester, String title) async {
  await tester.ensureVisible(find.text(title).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(title).first);
  await tester.pumpAndSettle();
}
