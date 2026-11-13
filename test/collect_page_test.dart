// R4 收集中心 widget 测试：6 态渲染、只按导入时间排、筛选不重排、
// 取消导入 / 删除失败任务无二次确认、修框编辑器（双击进内框、
// 画新框选类型、确认拆分替换原任务、取消留修框中、重叠拦确认、
// 无框提示、旋转整页）、亮/深、三档缩放无溢出、不用图标字体。
// 用 FakeRepo 覆盖 repository 调用（不碰真实数据库，不改口径）。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/collect/collect_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';

CollectTask task(
  String id,
  String name, {
  CollectStatus status = CollectStatus.queued,
  int progress = 0,
  String? error,
  int pageCount = 1,
}) => CollectTask(
  id: id,
  name: name,
  fileName: name.split(' · ').first,
  subjectId: 'math',
  status: status,
  progress: progress,
  pageCount: pageCount,
  page: 1,
  error: error,
);

class FakeRepo extends QuestionRepository {
  FakeRepo(this.tasks, {List<Subject>? subjects})
      : subjectsValue = subjects ?? Subject.all,
        super(AppDatabase.instance);

  List<CollectTask> tasks;
  List<Subject> subjectsValue;
  final List<Question> savedQuestions = [];
  final List<CollectTask> savedTasks = [];
  final List<String> deletedTaskIds = [];
  var organizeCalls = 0;

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);

  @override
  Future<List<CollectTask>> collectTasks() async => List.of(tasks);

  @override
  Future<void> saveCollectTask(CollectTask t) async {
    savedTasks.add(t);
    final i = tasks.indexWhere((x) => x.id == t.id);
    if (i >= 0) {
      tasks[i] = t;
    } else {
      tasks.add(t);
    }
  }

  @override
  Future<void> deleteCollectTask(String id) async {
    deletedTaskIds.add(id);
    tasks.removeWhere((x) => x.id == id);
  }

  @override
  Future<void> save(Question q) async => savedQuestions.add(q);

  @override
  Future<void> saveRecentTask({
    required String kind,
    required String subjectId,
    required String title,
  }) async {}
}

List<CollectTask> sixStateTasks() => [
  task('t-queued', '排队文件.pdf · 第1页 · 第1题', status: CollectStatus.queued),
  task(
    't-importing',
    '导入中文件.pdf · 第1页 · 第1题',
    status: CollectStatus.importing,
    progress: 50,
  ),
  task('t-needbox', '待框选文件.pdf · 第1页 · 第1题', status: CollectStatus.needBox),
  task('t-boxing', '修框中文件.pdf · 第1页 · 第1题', status: CollectStatus.boxing),
  task(
    't-ready',
    '待整理文件.pdf · 第1页 · 第1题',
    status: CollectStatus.pendingOrganize,
  ),
  task(
    't-failed',
    '损坏文件.pdf · 第1页 · 第1题',
    status: CollectStatus.failed,
    error: 'PDF 损坏打不开：无法读取任何页面',
  ),
];

Future<void> pumpCollect(
  WidgetTester tester, {
  FakeRepo? repo,
  Brightness brightness = Brightness.light,
  double scale = 1.0,
  Key? pageKey,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
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
              body: CollectPage(
                key: pageKey,
                repo: repo ?? FakeRepo([]),
                onOpenOrganize: () {},
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> openEditor(WidgetTester tester, String buttonLabel) async {
  final button = find.text(buttonLabel).first;
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
  expect(find.textContaining('修框 ·'), findsOneWidget);
}

void main() {
  group('收集中心正常态', () {
    testWidgets('6 态渲染：药丸、按钮、进度条、失败原因', (tester) async {
      await pumpCollect(tester, repo: FakeRepo(sixStateTasks()));
      expect(find.text('收集中心'), findsOneWidget);
      expect(find.text('请选择学科'), findsOneWidget);
      expect(find.text('把文件拖到这里，或点击选择'), findsOneWidget);
      expect(
        find.text('手机拍完用微信 / QQ / 局域网传到电脑，再选文件导入即可——传过来的就是文件，不用单独的拍照入口。'),
        findsOneWidget,
      );
      expect(find.textContaining('按导入时间排，新的在上面，不按状态排'), findsOneWidget);
      // 首屏行（ListView 懒构建 + 滚动后丢弃屏外行，只能按位置分段断言）。
      expect(find.text('排队中'), findsWidgets);
      expect(find.text('导入中 · 检测 50%'), findsOneWidget);
      expect(find.text('待框选'), findsWidgets);
      expect(find.text('导入中 50%'), findsOneWidget);
      expect(find.text('取消排队'), findsOneWidget);
      expect(find.text('取消导入'), findsOneWidget);
      expect(find.text('修框'), findsOneWidget);
      await tester.ensureVisible(find.text('修框中文件.pdf · 第1页 · 第1题'));
      await tester.pumpAndSettle();
      expect(find.text('修框中'), findsWidgets);
      expect(find.text('继续修框'), findsOneWidget);
      await tester.ensureVisible(find.text('待整理文件.pdf · 第1页 · 第1题'));
      await tester.pumpAndSettle();
      expect(find.text('待整理'), findsWidgets);
      expect(find.text('去整理'), findsWidgets);
      await tester.ensureVisible(find.text('导入失败'));
      await tester.pumpAndSettle();
      expect(find.text('导入失败'), findsOneWidget);
      expect(find.text('PDF 损坏打不开：无法读取任何页面'), findsOneWidget);
      expect(find.textContaining('有 1 个任务导入失败'), findsOneWidget);
      expect(find.text('删除任务'), findsOneWidget);
    });

    testWidgets('只按导入时间排：列表顺序与仓库顺序一致，不按状态重排', (tester) async {
      final repo = FakeRepo([
        task(
          't-failed',
          '旧失败.pdf · 第1页 · 第1题',
          status: CollectStatus.failed,
          error: '文件损坏：文件为空，无法导入',
        ),
        task(
          't-importing',
          '新导入中.pdf · 第1页 · 第1题',
          status: CollectStatus.importing,
          progress: 20,
        ),
        task('t-queued', '中排队.pdf · 第1页 · 第1题', status: CollectStatus.queued),
      ]);
      await pumpCollect(tester, repo: repo);
      final failedY = tester.getTopLeft(find.text('旧失败.pdf · 第1页 · 第1题')).dy;
      final importingY = tester
          .getTopLeft(find.text('新导入中.pdf · 第1页 · 第1题'))
          .dy;
      final queuedY = tester.getTopLeft(find.text('中排队.pdf · 第1页 · 第1题')).dy;
      expect(failedY < importingY, isTrue);
      expect(importingY < queuedY, isTrue);
    });

    testWidgets('状态筛选只过滤、不改变时间顺序', (tester) async {
      await pumpCollect(tester, repo: FakeRepo(sixStateTasks()));
      await tester.tap(find.byKey(const Key('collect-filter-needBox')));
      await tester.pumpAndSettle();
      expect(find.text('待框选文件.pdf · 第1页 · 第1题'), findsOneWidget);
      expect(find.text('排队文件.pdf · 第1页 · 第1题'), findsNothing);
      await tester.tap(find.byKey(const Key('collect-filter-all')));
      await tester.pumpAndSettle();
      expect(find.text('排队文件.pdf · 第1页 · 第1题'), findsOneWidget);
    });

    testWidgets('超过 3 个任务时列表变内部滚动区', (tester) async {
      await pumpCollect(tester, repo: FakeRepo(sixStateTasks()));
      expect(find.byKey(const Key('collect-task-list')), findsOneWidget);
      expect(find.byType(ListView), findsOneWidget);
    });

    testWidgets('不超过 3 个任务时列表不包滚动区', (tester) async {
      await pumpCollect(
        tester,
        repo: FakeRepo([
          task('t-a', '甲.pdf · 第1页 · 第1题', status: CollectStatus.needBox),
          task('t-b', '乙.pdf · 第1页 · 第1题', status: CollectStatus.needBox),
        ]),
      );
      expect(find.byType(ListView), findsNothing);
    });

    testWidgets('没选学科不能导入：点选择文件出黄色提示', (tester) async {
      await pumpCollect(tester, repo: FakeRepo([]));
      await tester.ensureVisible(find.text('选择文件导入'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择文件导入'));
      await tester.pumpAndSettle();
      expect(find.textContaining('先选学科'), findsOneWidget);
    });

    testWidgets('取消导入直接删任务，无二次确认', (tester) async {
      final repo = FakeRepo([
        task(
          't-importing',
          '导入中文件.pdf · 第1页 · 第1题',
          status: CollectStatus.importing,
          progress: 50,
        ),
      ]);
      await pumpCollect(tester, repo: repo);
      await tester.tap(find.text('取消导入'));
      await tester.pumpAndSettle();
      expect(find.text('导入中文件.pdf · 第1页 · 第1题'), findsNothing);
      expect(repo.deletedTaskIds, contains('t-importing'));
      expect(find.text('删了就没了，确定吗？'), findsNothing);
    });

    testWidgets('失败任务点删除任务直接删，无二次确认', (tester) async {
      final repo = FakeRepo([
        task(
          't-failed',
          '损坏文件.pdf · 第1页 · 第1题',
          status: CollectStatus.failed,
          error: 'PDF 损坏打不开：无法读取任何页面',
        ),
      ]);
      await pumpCollect(tester, repo: repo);
      await tester.tap(find.text('删除任务'));
      await tester.pumpAndSettle();
      expect(find.text('损坏文件.pdf · 第1页 · 第1题'), findsNothing);
      expect(repo.deletedTaskIds, contains('t-failed'));
      expect(find.text('删了就没了，确定吗？'), findsNothing);
    });

    testWidgets('点去整理走 onOpenOrganize', (tester) async {
      var calls = 0;
      final repo = FakeRepo([
        task(
          't-ready',
          '待整理文件.pdf · 第1页 · 第1题',
          status: CollectStatus.pendingOrganize,
        ),
      ]);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: CollectPage(repo: repo, onOpenOrganize: () => calls++),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('去整理'));
      await tester.pumpAndSettle();
      expect(calls, 1);
    });
  });

  group('收集中心空状态', () {
    testWidgets('无任务时空状态 + 选择文件导入', (tester) async {
      await pumpCollect(tester, repo: FakeRepo([]));
      expect(find.text('还没有收集任务，拖一个文件进来吧'), findsOneWidget);
      expect(
        find.text('把一份卷子（PDF）或错题照片（JPG / PNG）放进来，系统会先框出每一道完整的题，再请你确认框得对不对。'),
        findsOneWidget,
      );
      expect(find.text('选择文件导入'), findsOneWidget);
      expect(find.byType(ListView), findsNothing);
    });
  });

  group('修框编辑器', () {
    testWidgets('取消中途退出：任务留修框中，不回待框选', (tester) async {
      final repo = FakeRepo([
        task(
          't-needbox',
          '待框选文件.pdf · 第1页 · 第1题',
          status: CollectStatus.needBox,
        ),
      ]);
      await pumpCollect(tester, repo: repo);
      await openEditor(tester, '修框');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.textContaining('修框 ·'), findsNothing);
      expect(
        repo.tasks.firstWhere((t) => t.id == 't-needbox').status,
        CollectStatus.boxing,
      );
      expect(find.text('继续修框'), findsOneWidget);
    });

    testWidgets('双击题级框进内框模式，Esc 退出', (tester) async {
      final repo = FakeRepo([
        task(
          't-needbox',
          '待框选文件.pdf · 第1页 · 第1题',
          status: CollectStatus.needBox,
        ),
      ]);
      await pumpCollect(tester, repo: repo);
      await openEditor(tester, '修框');
      final box = find.byKey(const Key('editor-box-box-q1'));
      expect(box, findsOneWidget);
      await tester.ensureVisible(box);
      await tester.pumpAndSettle();
      await tester.tap(box);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(box);
      await tester.pumpAndSettle();
      expect(find.textContaining('已进入题级框'), findsOneWidget);
      expect(find.text('stem 题干'), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.textContaining('已进入题级框'), findsNothing);
    });

    testWidgets('内框模式三个默认内框全部落在画布可视区内（画布按页 fit）', (tester) async {
      final repo = FakeRepo([
        task(
          't-needbox',
          '待框选文件.pdf · 第1页 · 第1题',
          status: CollectStatus.needBox,
        ),
      ]);
      await pumpCollect(tester, repo: repo);
      await openEditor(tester, '修框');
      final box = find.byKey(const Key('editor-box-box-q1'));
      expect(box, findsOneWidget);
      await tester.ensureVisible(box);
      await tester.pumpAndSettle();
      await tester.tap(box);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(box);
      await tester.pumpAndSettle();
      expect(find.textContaining('已进入题级框'), findsOneWidget);
      // 画布可视区 = 外层 Listener 的矩形；三个内框都应完整落在里面，
      // 不能像固定 560×700 那样把 option / figure 顶到可视区之外。
      final canvas = tester.getRect(find.byKey(const Key('box-editor-canvas')));
      for (final id in ['box-q1-stem', 'box-q1-option', 'box-q1-figure']) {
        final rect = tester.getRect(find.byKey(Key('editor-box-$id')));
        expect(canvas.contains(rect.topLeft), isTrue, reason: '$id topLeft');
        expect(
          canvas.contains(rect.bottomRight),
          isTrue,
          reason: '$id bottomRight',
        );
      }
    });

    testWidgets('有框未选中时底部提示不是“没框到题”，删空后才是', (tester) async {
      final repo = FakeRepo([
        task(
          't-needbox',
          '待框选文件.pdf · 第1页 · 第1题',
          status: CollectStatus.needBox,
        ),
      ]);
      await pumpCollect(tester, repo: repo);
      await openEditor(tester, '修框');
      expect(find.textContaining('本页已框 1 道题'), findsOneWidget);
      expect(find.textContaining('没框到题'), findsNothing);
      final box = find.byKey(const Key('editor-box-box-q1'));
      await tester.ensureVisible(box);
      await tester.pumpAndSettle();
      await tester.tap(box);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除选中框'));
      await tester.pumpAndSettle();
      // 删空后：warn 横幅标题 + 底部提示都含“没框到题”。
      expect(find.textContaining('没框到题'), findsWidgets);
      expect(find.textContaining('本页已框'), findsNothing);
    });

    testWidgets('空白处画新框、选题级框、确认拆成 2 个待整理任务并替换原任务', (tester) async {
      final repo = FakeRepo([
        task(
          't-needbox',
          '待框选文件.pdf · 第1页 · 第1题',
          status: CollectStatus.needBox,
        ),
      ]);
      await pumpCollect(tester, repo: repo);
      await openEditor(tester, '修框');
      // 先删掉占位框：它几乎盖满整页，新框画在哪都会和它重叠。
      // 页在画布里居中 fit；删框会出“没框到题”横幅把画布顶下去，
      // 所以每次拖动前都按当前画布矩形重算页原点与页尺寸。
      final box = find.byKey(const Key('editor-box-box-q1'));
      await tester.ensureVisible(box);
      await tester.pumpAndSettle();
      await tester.tap(box);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除选中框'));
      await tester.pumpAndSettle();
      final canvas = find.byKey(const Key('box-editor-canvas'));
      (Offset, double, double) pageMetrics() {
        final r = tester.getRect(canvas);
        final fit = math.min(
          r.width / DesignTokens.collectEditorCanvasWidth,
          r.height / DesignTokens.collectEditorCanvasHeight,
        );
        final pw = DesignTokens.collectEditorCanvasWidth * fit;
        final ph = DesignTokens.collectEditorCanvasHeight * fit;
        return (
          Offset(r.left + (r.width - pw) / 2, r.top + (r.height - ph) / 2),
          pw,
          ph,
        );
      }

      var (origin, pageW, pageH) = pageMetrics();
      await tester.dragFrom(
        origin + Offset(0.05 * pageW, 0.05 * pageH),
        Offset(0.4 * pageW, 0.4 * pageH),
      );
      await tester.pumpAndSettle();
      expect(find.text('这个框是？'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('pending-type-question')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pending-type-question')));
      await tester.pumpAndSettle();
      (origin, pageW, pageH) = pageMetrics();
      await tester.dragFrom(
        origin + Offset(0.55 * pageW, 0.55 * pageH),
        Offset(0.35 * pageW, 0.35 * pageH),
      );
      await tester.pumpAndSettle();
      expect(find.text('这个框是？'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('pending-type-question')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pending-type-question')));
      await tester.pumpAndSettle();
      expect(find.text('确认修框，拆成 2 个待整理任务'), findsOneWidget);
      await tester.tap(find.text('确认修框，拆成 2 个待整理任务'));
      await tester.pumpAndSettle();
      expect(find.textContaining('修框 ·'), findsNothing);
      expect(repo.deletedTaskIds, contains('t-needbox'));
      final split = repo.tasks.where(
        (t) => t.status == CollectStatus.pendingOrganize,
      );
      expect(split.length, 2);
      expect(
        split.map((t) => t.name),
        containsAll(['待框选文件.pdf · 第1页 · 第1题', '待框选文件.pdf · 第1页 · 第2题']),
      );
      expect(repo.savedQuestions.length, 2);
    });

    testWidgets('画出的框与原框重叠时确认被拦下', (tester) async {
      final repo = FakeRepo([
        task(
          't-needbox',
          '待框选文件.pdf · 第1页 · 第1题',
          status: CollectStatus.needBox,
        ),
      ]);
      await pumpCollect(tester, repo: repo);
      await openEditor(tester, '修框');
      // 页在画布里居中 fit：用占位框矩形反推页原点再画框。
      final box = find.byKey(const Key('editor-box-box-q1'));
      await tester.ensureVisible(box);
      await tester.pumpAndSettle();
      final boxRect = tester.getRect(box);
      final pageW = boxRect.width / 0.88;
      final pageH = boxRect.height / 0.85;
      final origin = Offset(
        boxRect.left - 0.06 * pageW,
        boxRect.top - 0.05 * pageH,
      );
      await tester.dragFrom(
        origin + Offset(0.05 * pageW, 0.05 * pageH),
        Offset(0.6 * pageW, 0.6 * pageH),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pending-type-question')));
      await tester.pumpAndSettle();
      expect(find.textContaining('框重叠'), findsOneWidget);
      await tester.tap(find.text('确认修框，拆成 2 个待整理任务'));
      await tester.pumpAndSettle();
      expect(find.textContaining('修框 ·'), findsOneWidget);
      expect(repo.deletedTaskIds, isEmpty);
    });

    testWidgets('删掉全部框后出无框提示，确认不可点', (tester) async {
      final repo = FakeRepo([
        task(
          't-needbox',
          '待框选文件.pdf · 第1页 · 第1题',
          status: CollectStatus.needBox,
        ),
      ]);
      await pumpCollect(tester, repo: repo);
      await openEditor(tester, '修框');
      final box = find.byKey(const Key('editor-box-box-q1'));
      await tester.ensureVisible(box);
      await tester.pumpAndSettle();
      await tester.tap(box);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除选中框'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('没框到题，请用鼠标拖一个框：在画布空白处按住拖出一个框'),
        findsOneWidget,
      );
      await tester.tap(find.text('确认修框，去整理'));
      await tester.pumpAndSettle();
      expect(find.textContaining('修框 ·'), findsOneWidget);
      expect(repo.deletedTaskIds, isEmpty);
    });

    testWidgets('旋转整页每次 90°，框跟着转', (tester) async {
      final repo = FakeRepo([
        task(
          't-needbox',
          '待框选文件.pdf · 第1页 · 第1题',
          status: CollectStatus.needBox,
        ),
      ]);
      await pumpCollect(tester, repo: repo);
      await openEditor(tester, '修框');
      await tester.tap(find.text('旋转整页'));
      await tester.pumpAndSettle();
      expect(find.text('整页已旋转 90°（图片和框一起转的）'), findsOneWidget);
      await tester.tap(find.text('旋转整页'));
      await tester.pumpAndSettle();
      expect(find.text('整页已旋转 180°（图片和框一起转的）'), findsOneWidget);
    });

    testWidgets('页缩略图条 + 旋转圆柄存在，拖动圆柄不报错', (tester) async {
      final repo = FakeRepo([
        task(
          't-needbox',
          '待框选文件.pdf · 第1页 · 第1题',
          status: CollectStatus.needBox,
          pageCount: 3,
        ),
      ]);
      await pumpCollect(tester, repo: repo);
      await openEditor(tester, '修框');
      expect(find.byKey(const Key('editor-thumb-1')), findsOneWidget);
      expect(find.byKey(const Key('editor-thumb-2')), findsOneWidget);
      expect(find.byKey(const Key('editor-thumb-3')), findsOneWidget);
      expect(find.text('第 1 页'), findsOneWidget);
      final box = find.byKey(const Key('editor-box-box-q1'));
      await tester.ensureVisible(box);
      await tester.pumpAndSettle();
      await tester.tap(box);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      final handle = find.byKey(const Key('editor-rotate-box-q1'));
      expect(handle, findsOneWidget);
      await tester.ensureVisible(handle);
      await tester.pumpAndSettle();
      await tester.timedDrag(
        handle,
        const Offset(20, -20),
        const Duration(milliseconds: 200),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('editor-box-box-q1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('单框确认：确认修框，去整理', (tester) async {
      final repo = FakeRepo([
        task(
          't-needbox',
          '待框选文件.pdf · 第1页 · 第1题',
          status: CollectStatus.needBox,
        ),
      ]);
      await pumpCollect(tester, repo: repo);
      await openEditor(tester, '修框');
      expect(find.text('确认修框，去整理'), findsOneWidget);
      await tester.tap(find.text('确认修框，去整理'));
      await tester.pumpAndSettle();
      expect(repo.deletedTaskIds, contains('t-needbox'));
      expect(
        repo.tasks
            .where((t) => t.status == CollectStatus.pendingOrganize)
            .length,
        1,
      );
    });
  });

  group('亮/深与三档缩放', () {
    testWidgets('亮/深 × 三档缩放无溢出、无异常', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        for (final scale in [1.0, 1.15, 1.3]) {
          await pumpCollect(
            tester,
            repo: FakeRepo(sixStateTasks()),
            brightness: brightness,
            scale: scale,
            pageKey: ValueKey('collect-$brightness-$scale'),
          );
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets('修框编辑器三档缩放无溢出', (tester) async {
      for (final scale in [1.0, 1.15, 1.3]) {
        final repo = FakeRepo([
          task(
            't-needbox',
            '待框选文件.pdf · 第1页 · 第1题',
            status: CollectStatus.needBox,
          ),
        ]);
        await pumpCollect(
          tester,
          repo: repo,
          scale: scale,
          pageKey: ValueKey('editor-$scale'),
        );
        await openEditor(tester, '修框');
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('空状态三档缩放无溢出', (tester) async {
      for (final scale in [1.0, 1.15, 1.3]) {
        await pumpCollect(
          tester,
          repo: FakeRepo([]),
          scale: scale,
          pageKey: ValueKey('empty-$scale'),
        );
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('收集页与修框编辑器不用图标字体', (tester) async {
      await pumpCollect(tester, repo: FakeRepo(sixStateTasks()));
      expect(find.byType(Icon), findsNothing);
      await openEditor(tester, '修框');
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('页内无边距：内容从外壳 padding 处开始', (tester) async {
      await pumpCollect(tester, repo: FakeRepo([]));
      final scrollView = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView).first,
      );
      expect(scrollView.padding, EdgeInsets.zero);
    });
  });
}
