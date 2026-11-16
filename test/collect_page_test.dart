// R4 收集中心 widget 测试：6 态渲染、只按导入时间排、筛选不重排、
// 取消导入 / 删除失败任务无二次确认、修框编辑器（画新框直接成题级框、
// 确认拆分替换原任务、取消留修框中、重叠拦确认、
// 无框提示、旋转整页）、亮/深、三档缩放无溢出、不用图标字体。
// 用 FakeRepo 覆盖 repository 调用（不碰真实数据库，不改口径）。
// P2：编辑器改走真实页图 + DetectionResult——setUpAll 生成一张
// 560×700 真实页图（与 DesignTokens.collectEditorCanvasWidth/Height
// 同比例，页内几何计算不变），放在 testDataDirectory 的
// imports/collect-task/page.png，任务默认 sourcePath 用相对路径
// 指向它（B3-P01：resolveDataPath 已拒绝绝对路径）；检测用
// 桩服务（固定 1 个框），不跑真实推理；切片/烘焙写盘走
// AppDatabase.testDataDirectory 指向的临时目录，不污染真实数据目录。
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/collect/collect_page.dart';
import 'package:quiz_master2/services/import_service.dart';
import 'package:quiz_master2/services/yolo_onnx_service.dart';
import 'package:quiz_master2/theme/app_theme.dart';

late final Directory _testTmp;
late final String _pagePngPath;

/// B3-P01：页图放进 testDataDirectory，任务默认 sourcePath 用相对路径
///（resolveDataPath 已拒绝绝对路径）；_pagePngPath 只留给
/// _seedPdfPageImages 的 File 复制用，不再进 sourcePath。
late final String _pagePngRel;

/// 桩检测：固定返回 1 个题级框（0.06/0.05/0.88/0.85，与旧占位框同几何，
/// 旧几何断言不用改）；detectError 非空时模拟模型失败——返回空框 +
/// usedFallback，不落占位框。
class _StubYolo extends YoloOnnxService {
  _StubYolo({this.detectError});

  final String? detectError;

  @override
  Future<DetectionResult> detectPage({
    required String imagePath,
    required int page,
  }) async {
    if (detectError != null) {
      return DetectionResult(
        boxes: const [],
        usedFallback: true,
        error: detectError,
      );
    }
    return DetectionResult(
      boxes: [
        QuestionBox(
          id: 'box-q1',
          layer: 1,
          type: 'question',
          x: 0.06,
          y: 0.05,
          w: 0.88,
          h: 0.85,
          page: page,
        ),
      ],
      usedFallback: false,
    );
  }
}

/// B11-2：假文件选择器——返回调用方给定的路径，不碰系统选择器。
/// `FilePicker.platform` 在测试里默认未初始化（插件注册不跑），
/// 直接调 pickFiles 会抛 LateInitializationError。
class _FakeFilePicker extends FilePicker {
  _FakeFilePicker(this.paths);

  final List<String> paths;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    return FilePickerResult([
      for (final p in paths)
        PlatformFile(name: p.split('/').last, path: p, size: 3),
    ]);
  }
}

/// P1-2：只在第 1 页返回 1 个题级框，其余页返回空框
///（不走 fallback）；[origin] 可指定（恢复自动框测试用：'yolo'
///框不算手动，'manual' 框算手动）。
class _SelectiveYolo extends YoloOnnxService {
  _SelectiveYolo({this.origin = 'manual'});

  final String origin;

  @override
  Future<DetectionResult> detectPage({
    required String imagePath,
    required int page,
  }) async {
    if (page != 1) {
      return const DetectionResult(boxes: [], usedFallback: false);
    }
    return DetectionResult(
      boxes: [
        QuestionBox(
          id: 'box-q1',
          layer: 1,
          type: 'question',
          x: 0.06,
          y: 0.05,
          w: 0.88,
          h: 0.85,
          page: page,
          origin: origin,
        ),
      ],
      usedFallback: false,
    );
  }
}

/// P1-2：给多页 PDF 任务在临时数据目录里种每页的页图
///（`imports/<id>/pages/page-00N.png`，都用同一张真实页图），
///否则 _openBoxEditor 会因页图缺失拒绝开编辑器。
/// 注意：用同步 IO——testWidgets 体跑在 fake async 里，真实 IO 的
/// Future 等不到完成（见 tapConfirmAndWait 的注释），会直接卡死。
void _seedPdfPageImages(String taskId, int pages) {
  for (var p = 1; p <= pages; p++) {
    final abs = AppDatabase.resolveDataPath(
      ImportService.renderedPageRelative(taskId, p),
    )!;
    File(abs).parent.createSync(recursive: true);
    File(_pagePngPath).copySync(abs);
  }
}

/// P1-2：点确认拆题对话框里的「确认拆题」，并等 _confirmSplit 的
/// 真实文件 IO 跑完（与 tapConfirmAndWait 同款跑法）。
Future<void> tapDialogConfirmAndWait(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.tap(find.text('确认拆题'));
    for (var i = 0; i < 20; i++) {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle();
  });
  await tester.pumpAndSettle();
}

/// 画布内的框标签（题级框的文字在画布里；底部 hint 也含
/// “题级框 N”字样，必须限定在画布内找，否则会命中 hint）。
Finder editorBoxLabel(String label) => find.descendant(
  of: find.byKey(const Key('box-editor-canvas')),
  matching: find.textContaining(label),
);

/// 画布内某标签所属的框手柄（GestureDetector，key 是
/// `editor-box-<持久化 id>`，id 含随机 uuid8，不能按 key 找）。
Finder editorBoxHandle(String label) => find.ancestor(
  of: editorBoxLabel(label),
  matching: find.byWidgetPredicate(
    (w) =>
        w is GestureDetector &&
        w.key is ValueKey<String> &&
        (w.key as ValueKey<String>).value.startsWith('editor-box-'),
  ),
);

CollectTask task(
  String id,
  String name, {
  CollectStatus status = CollectStatus.queued,
  int progress = 0,
  String? error,
  int pageCount = 1,
  String? sourcePath,
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
  // 默认指向 setUpAll 生成的真实页图（P2：编辑器要读真实页图）。
  sourcePath: sourcePath ?? _pagePngRel,
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

  /// 草稿框（按任务 id 存，saveDraftBoxes 写入、boxesForTask 读出）。
  final Map<String, List<QuestionBox>> draftBoxes = {};

  @override
  Future<List<QuestionBox>> boxesForTask(String taskId) async =>
      List.of(draftBoxes[taskId] ?? const []);

  @override
  Future<void> saveDraftBoxes({
    required String taskId,
    required Map<int, List<QuestionBox>> boxesByPage,
    required Map<int, int> rotations,
  }) async {
    draftBoxes[taskId] = [for (final e in boxesByPage.entries) ...e.value];
  }

  /// SR-P1-2：同一次 confirmSplit 调用里传进来的保留任务与未框页草稿
  ///（与拆题同事务提交，见 lib 的 confirmSplitIntoImpl）。
  CollectTask? lastRetainedTask;
  final Map<int, List<QuestionBox>> lastRetainedBoxesByPage = {};

  /// 最近一次 confirmSplit 收到的每题框。
  final Map<String, List<QuestionBox>> lastBoxesByQuestionId = {};

  /// SR2-25：为真时 saveRecentTask 抛错（注入确认尾部写库失败）。
  var failSaveRecentTask = false;

  @override
  Future<void> confirmSplit({
    required CollectTask originalTask,
    required List<Question> questions,
    required List<CollectTask> splitTasks,
    required Map<String, List<QuestionBox>> boxesByQuestionId,
    CollectTask? retainedTask,
    Map<int, List<QuestionBox>> retainedBoxesByPage = const {},
  }) async {
    lastBoxesByQuestionId
      ..clear()
      ..addAll(boxesByQuestionId);
    savedQuestions.addAll(questions);
    tasks.addAll(splitTasks);
    tasks.removeWhere((t) => t.id == originalTask.id);
    deletedTaskIds.add(originalTask.id);
    lastRetainedTask = retainedTask;
    lastRetainedBoxesByPage
      ..clear()
      ..addAll(retainedBoxesByPage);
    if (retainedTask != null) {
      // 保留任务与原任务同 id：事务内先删后插，等价于原地重建。
      final i = tasks.indexWhere((x) => x.id == retainedTask.id);
      if (i >= 0) {
        tasks[i] = retainedTask;
      } else {
        tasks.add(retainedTask);
      }
      draftBoxes[retainedTask.id] = [
        for (final e in retainedBoxesByPage.entries) ...e.value,
      ];
    }
  }

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
  }) async {
    if (failSaveRecentTask) throw StateError('最近任务写库失败（测试注入）');
  }
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
  YoloOnnxService? yoloService,
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
                yoloService: yoloService ?? _StubYolo(),
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

/// B2-6b：鼠标右键拖动（次要按键）——画框用。
Future<TestGesture> dragMouseRight(
  WidgetTester tester,
  Offset start,
  Offset offset,
) async {
  final gesture = await tester.startGesture(
    start,
    kind: ui.PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.moveBy(offset / 2);
  await gesture.moveBy(offset / 2);
  await tester.pumpAndSettle();
  await gesture.up();
  await tester.pumpAndSettle();
  return gesture;
}

/// B2-6b：鼠标左键拖动（主要按键）——平移图片 / 拖框用。
Future<TestGesture> dragMouseLeft(
  WidgetTester tester,
  Offset start,
  Offset offset,
) async {
  final gesture = await tester.startGesture(
    start,
    kind: ui.PointerDeviceKind.mouse,
    buttons: kPrimaryMouseButton,
  );
  await gesture.moveBy(offset / 2);
  await gesture.moveBy(offset / 2);
  await tester.pumpAndSettle();
  await gesture.up();
  await tester.pumpAndSettle();
  return gesture;
}

/// B2-6b：鼠标右键单击（按下即抬起，不拖动）——取消用。
Future<void> clickMouseRight(WidgetTester tester, Offset at) async {
  final gesture = await tester.startGesture(
    at,
    kind: ui.PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await tester.pumpAndSettle();
  await gesture.up();
  await tester.pumpAndSettle();
}

/// B2-6b：指定位置发一次滚轮事件（dy < 0 上滚、dy > 0 下滚）。
Future<void> scrollWheel(
  WidgetTester tester,
  Offset location,
  Offset delta,
) async {
  await tester.sendEventToBinding(
    PointerScrollEvent(position: location, scrollDelta: delta),
  );
  await tester.pumpAndSettle();
}

/// B2-6b：修框画布里竖向滚动视图的当前偏移（平移/滚动是否发生的标尺）。
double editorVerticalPixels(WidgetTester tester) {
  final state = tester.state<ScrollableState>(
    find
        .descendant(
          of: find.byKey(const Key('box-editor-canvas')),
          matching: find.byWidgetPredicate(
            (w) => w is Scrollable && w.axis == Axis.vertical,
          ),
        )
        .first,
  );
  return state.position.pixels;
}

/// B2-6b：当前页在画布里的原点与尺寸（页按 560×700 fit 居中放）。
(Offset, double, double) editorPageMetrics(WidgetTester tester) {
  final canvas = find.byKey(const Key('box-editor-canvas'));
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

/// 点确认并等 _confirmSplit 的真实文件 IO + 图片解码跑完：
/// 测试体在 fake async zone 里，真实 IO 的 Future 等不到完成；
/// 须在 runAsync 内反复 pump + 真实延时推进（每步 IO 各需一次
/// pump 刷 microtask + 一次真实延时让事件循环跑完）。
Future<void> tapConfirmAndWait(WidgetTester tester, String label) async {
  await tester.runAsync(() async {
    await tester.tap(find.text(label));
    for (var i = 0; i < 20; i++) {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle();
  });
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    _testTmp = await Directory.systemTemp.createTemp('qm2-collect-test');
    // 560×700 真实页图：白底 + 8 条黑横线（与编辑器画布同比例）。
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 560, 700),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    final bar = ui.Paint()..color = const ui.Color(0xFF111111);
    for (var i = 0; i < 8; i++) {
      canvas.drawRect(ui.Rect.fromLTWH(40, 40 + i * 80, 480, 8), bar);
    }
    final img = await recorder.endRecording().toImage(560, 700);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    final pageDir = Directory('${_testTmp.path}/imports/collect-task');
    await pageDir.create(recursive: true);
    final file = File('${pageDir.path}/page.png');
    await file.writeAsBytes(png!.buffer.asUint8List());
    _pagePngPath = file.path;
    _pagePngRel = 'imports/collect-task/page.png';
    // 切片/烘焙写盘走临时数据目录，不污染真实数据目录。
    AppDatabase.testDataDirectory = _testTmp.path;
  });

  tearDownAll(() async {
    AppDatabase.testDataDirectory = null;
    await _testTmp.delete(recursive: true);
  });

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

    testWidgets('没选学科也能选文件：选完暂存，等选好学科再导', (tester) async {
      // B11-2：没选学科也能先选文件（猜学科要先拿到文件名）；文件
      // 暂存，不直接导入。“先选学科”只在点暂存卡片的“开始导入”
      // 时才出。文件选择器用假实现（返回不存在的路径：暂存路径上
      // 只算哈希与超限，不读文件），不碰系统选择器与数据库。
      FilePicker.platform = _FakeFilePicker(['/tmp/b11-no-such-photo123.jpg']);
      await pumpCollect(tester, repo: FakeRepo([]));
      await tester.ensureVisible(find.text('选择文件导入'));
      await tester.pumpAndSettle();
      // 点按在 runAsync 内：它触发的 _handleIncomingPaths 要算文件
      // 内容哈希（流式读），订阅必须发生在真实异步区里，否则在
      // fake 区等不到完成（见 b11_dragdrop_test 的 probe3 注释）。
      await tester.runAsync(() async {
        await tester.tap(find.text('选择文件导入'));
        await Future.delayed(const Duration(milliseconds: 500));
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('staged-import-card')), findsOneWidget);
      expect(find.textContaining('已选 1 个文件，等选学科'), findsOneWidget);
      expect(find.textContaining('先选学科'), findsNothing);
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

    testWidgets('B3 失败任务点删除任务弹确认框，取消不删、确认删除', (tester) async {
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
      expect(find.text('删了就没了，确定吗？'), findsOneWidget);
      expect(repo.deletedTaskIds, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('损坏文件.pdf · 第1页 · 第1题'), findsOneWidget);
      expect(repo.deletedTaskIds, isEmpty);
      await tester.tap(find.text('删除任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(find.text('损坏文件.pdf · 第1页 · 第1题'), findsNothing);
      expect(repo.deletedTaskIds, contains('t-failed'));
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
      final box = editorBoxHandle('题级框 1');
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

    testWidgets('空白处画新框、直接成题级框、确认拆成 2 个待整理任务并替换原任务', (tester) async {
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
      final box = editorBoxHandle('题级框 1');
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
      // 画框直接成题级框，不再弹“这个框是？”选类型。
      expect(find.text('这个框是？'), findsNothing);
      expect(editorBoxLabel('题级框 1'), findsOneWidget);
      (origin, pageW, pageH) = pageMetrics();
      await tester.dragFrom(
        origin + Offset(0.55 * pageW, 0.55 * pageH),
        Offset(0.35 * pageW, 0.35 * pageH),
      );
      await tester.pumpAndSettle();
      expect(find.text('这个框是？'), findsNothing);
      expect(editorBoxLabel('题级框 2'), findsOneWidget);
      expect(find.text('确认修框，拆成 2 个待整理任务'), findsOneWidget);
      await tapConfirmAndWait(tester, '确认修框，拆成 2 个待整理任务');
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
      // 页在画布里居中 fit：用检测框矩形反推页原点再画框。
      final box = editorBoxHandle('题级框 1');
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
      // 新框直接落下，与原框重叠出警告。
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
      final box = editorBoxHandle('题级框 1');
      await tester.ensureVisible(box);
      await tester.pumpAndSettle();
      await tester.tap(box);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除选中框'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('没框到题，请用鼠标右键拖一个框：在画布空白处按住拖出一个框'),
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

    testWidgets('单框旋转圆柄不存在：选中框后无 editor-rotate-* 句柄（§6 第 10 条）', (
      tester,
    ) async {
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
      final box = editorBoxHandle('题级框 1');
      await tester.ensureVisible(box);
      await tester.pumpAndSettle();
      await tester.tap(box);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      // 单框旋转已禁用：框上不再有旋转圆柄（以前是 editor-rotate-<id>）。
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key as ValueKey<String>).value.startsWith('editor-rotate-'),
        ),
        findsNothing,
      );
      expect(editorBoxHandle('题级框 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('模型失败：不落占位框，显式提示手动框选', (tester) async {
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
        yoloService: _StubYolo(detectError: '自动检测不可用，请手动框选'),
      );
      await openEditor(tester, '修框');
      expect(find.textContaining('自动检测不可用，请手动框选'), findsOneWidget);
      expect(editorBoxLabel('题级框 1'), findsNothing);
      expect(find.textContaining('没框到题'), findsWidgets);
    });

    testWidgets('取消保存草稿：重进“继续修框”恢复上次的框', (tester) async {
      final repo = FakeRepo([
        task(
          't-needbox',
          '待框选文件.pdf · 第1页 · 第1题',
          status: CollectStatus.needBox,
        ),
      ]);
      await pumpCollect(tester, repo: repo);
      await openEditor(tester, '修框');
      expect(editorBoxLabel('题级框 1'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.textContaining('修框 ·'), findsNothing);
      // 取消时草稿已保存（不是丢弃）。
      expect(repo.draftBoxes['t-needbox']?.length, 1);
      // 重进：草稿优先，不再检测，框还在。
      await openEditor(tester, '继续修框');
      expect(editorBoxLabel('题级框 1'), findsOneWidget);
    });

    testWidgets('旋转后确认：页图烘焙 -r90，切片落盘', (tester) async {
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
      await tapConfirmAndWait(tester, '确认修框，去整理');
      expect(find.textContaining('修框 ·'), findsNothing);
      expect(repo.savedQuestions.length, 1);
      final q = repo.savedQuestions.first;
      // 烘焙进页图：pageImagePath 含 -r90。
      expect(q.pageImagePath, contains('-r90'));
      final bakedAbs = AppDatabase.resolveDataPath(q.pageImagePath!);
      expect(bakedAbs != null && File(bakedAbs).existsSync(), isTrue);
      // 切片落盘且有尺寸。
      final sliceAbs = AppDatabase.resolveDataPath(q.slicePath!);
      expect(sliceAbs != null && File(sliceAbs).existsSync(), isTrue);
      expect(q.sliceWidth, greaterThan(0));
      expect(q.sliceHeight, greaterThan(0));
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
      await tapConfirmAndWait(tester, '确认修框，去整理');
      expect(repo.deletedTaskIds, contains('t-needbox'));
      expect(
        repo.tasks
            .where((t) => t.status == CollectStatus.pendingOrganize)
            .length,
        1,
      );
    });
  });

  group('P1-2 多页 PDF 未框页不丢', () {
    Future<FakeRepo> pumpPdf3(
      WidgetTester tester, {
      YoloOnnxService? yoloService,
    }) async {
      _seedPdfPageImages('t-pdf', 3);
      final repo = FakeRepo([
        task(
          't-pdf',
          '多页卷.pdf · 第1页 · 第1题',
          status: CollectStatus.needBox,
          pageCount: 3,
          sourcePath: 'imports/t-pdf/original.pdf',
        ),
      ]);
      await pumpCollect(
        tester,
        repo: repo,
        yoloService: yoloService ?? _SelectiveYolo(),
      );
      return repo;
    }

    testWidgets('确认前报未框页数，确认后只拆有框页、未框页留任务可继续修框', (tester) async {
      final repo = await pumpPdf3(tester);
      await openEditor(tester, '修框');
      // 第 1 页有检测框；切到第 2、3 页（桩检测返回空框）。
      await tester.tap(find.byKey(const Key('editor-thumb-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('editor-thumb-3')));
      await tester.pumpAndSettle();
      expect(find.text('确认修框，去整理'), findsOneWidget);
      await tapConfirmAndWait(tester, '确认修框，去整理');
      // 确认前提示：明确写出未框页数与页码。
      expect(find.text('还有 2 页没有框'), findsOneWidget);
      expect(find.textContaining('第 2、3 页还没有框'), findsOneWidget);
      await tapDialogConfirmAndWait(tester);
      expect(find.textContaining('修框 ·'), findsNothing);
      // 只拆了第 1 页的 1 道题。
      expect(repo.savedQuestions.length, 1);
      expect(repo.savedQuestions.first.sourcePage, 1);
      expect(
        repo.tasks
            .where((t) => t.status == CollectStatus.pendingOrganize)
            .length,
        1,
      );
      // 原任务没删干净：同 id 留在任务里，带修框中状态（SR2-22：保留
      // 任务只可能由编辑器确认产生，必定打开过，直接写 boxing，不
      // 再重置回 needBox）、从首个未框页修。
      final retained = repo.tasks.firstWhere((t) => t.id == 't-pdf');
      expect(retained.status, CollectStatus.boxing);
      expect(retained.page, 2);
      expect(retained.pageCount, 3);
      // SR-P1-2：保留任务与确认拆题是同一次 confirmSplit 调用提交的，
      // 不是事务外两步重建（崩溃窗口已关掉）。
      expect(repo.lastRetainedTask, isNotNull);
      expect(repo.lastRetainedTask!.id, 't-pdf');
      expect(repo.lastRetainedTask!.status, CollectStatus.boxing);
      expect(repo.lastRetainedTask!.page, 2);
      // 列表行上出红色警告（修框中筛选下也一样；保留任务现在是
      // boxing，不再出现在待框选筛选里）。
      expect(find.text('还有 2 页没有框：第 2、3 页'), findsOneWidget);
      await tester.tap(find.byKey(const Key('collect-filter-boxing')));
      await tester.pumpAndSettle();
      expect(find.text('还有 2 页没有框：第 2、3 页'), findsOneWidget);
      await tester.tap(find.byKey(const Key('collect-filter-all')));
      await tester.pumpAndSettle();
      // 重进修框：从第 2 页开始，该页没框。保留任务现在是 boxing，
      // 行上按钮是「继续修框」而不是「修框」。
      await openEditor(tester, '继续修框');
      expect(find.textContaining('没框到题'), findsWidgets);
      // 切回已拆的第 1 页：自动检测又框出题，但确认不重复拆。
      await tester.tap(find.byKey(const Key('editor-thumb-1')));
      await tester.pumpAndSettle();
      expect(editorBoxLabel('题级框 1'), findsOneWidget);
      await tapConfirmAndWait(tester, '确认修框，去整理');
      expect(find.textContaining('修框 ·'), findsNothing);
      expect(repo.savedQuestions.length, 1);
      expect(
        repo.tasks
            .where((t) => t.status == CollectStatus.pendingOrganize)
            .length,
        1,
      );
      expect(find.text('还有 2 页没有框：第 2、3 页'), findsOneWidget);
    });

    testWidgets('确认前对话框点取消：什么都不拆，任务留修框中', (tester) async {
      final repo = await pumpPdf3(tester);
      await openEditor(tester, '修框');
      await tester.tap(find.byKey(const Key('editor-thumb-2')));
      await tester.pumpAndSettle();
      await tapConfirmAndWait(tester, '确认修框，去整理');
      expect(find.text('还有 2 页没有框'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.textContaining('修框 ·'), findsNothing);
      expect(repo.savedQuestions, isEmpty);
      expect(
        repo.tasks.where((t) => t.status == CollectStatus.pendingOrganize),
        isEmpty,
      );
      expect(repo.tasks.any((t) => t.id == 't-pdf'), isTrue);
      expect(find.text('多页卷.pdf · 第1页 · 第1题'), findsOneWidget);
      expect(find.text('继续修框'), findsOneWidget);
    });

    // SR-P2-25（Meng 已定）：红色无框警告只对“打开过修框或已有任意
    // 草稿框”的任务显示。单张图任务从未打开、没有草稿框，不再警告；
    // 多页卷第 1 页有草稿框，仍警告未框的第 2、3 页；全框了的不警告。
    testWidgets('无框警告：有草稿的任务出警告，从未打开的单张图不出，全框了不出', (tester) async {
      final repo = FakeRepo([
        task('t-img', '单张图.pdf · 第1页 · 第1题', status: CollectStatus.needBox),
        task(
          't-pdf',
          '多页卷.pdf · 第1页 · 第1题',
          status: CollectStatus.needBox,
          pageCount: 3,
        ),
        task(
          't-full',
          '全框了.pdf · 第1页 · 第1题',
          status: CollectStatus.needBox,
          pageCount: 2,
        ),
      ]);
      // 草稿框：多页卷只有第 1 页有框；全框了的 2 页都有框。
      QuestionBox box(String id, int page) => QuestionBox(
        id: id,
        layer: 1,
        type: 'question',
        x: 0.1,
        y: 0.1,
        w: 0.5,
        h: 0.5,
        page: page,
      );
      repo.draftBoxes['t-pdf'] = [box('box-p1', 1)];
      repo.draftBoxes['t-full'] = [box('box-f1', 1), box('box-f2', 2)];
      await pumpCollect(tester, repo: repo);
      expect(find.text('这张图还没有框'), findsNothing);
      expect(find.text('还有 2 页没有框：第 2、3 页'), findsOneWidget);
      // 警告是红色（errInk），不是普通 muted 文案。
      final warning = tester.widget<Text>(find.text('还有 2 页没有框：第 2、3 页'));
      expect(warning.style?.color, DesignTokens.light.errInk);
    });
  });

  group('SR2-25 确认拆题后 saveRecentTask 失败不影响成功提示与刷新', () {
    testWidgets('最近任务写库失败：仍拆题成功，列表刷新到待整理', (tester) async {
      final repo = FakeRepo([
        task(
          't-needbox',
          '待框选文件.pdf · 第1页 · 第1题',
          status: CollectStatus.needBox,
        ),
      ]);
      await pumpCollect(tester, repo: repo);
      await openEditor(tester, '修框');
      expect(editorBoxLabel('题级框 1'), findsOneWidget);
      // 确认尾部的 saveRecentTask 注入失败。
      repo.failSaveRecentTask = true;
      await tapConfirmAndWait(tester, '确认修框，去整理');
      expect(find.textContaining('修框 ·'), findsNothing);
      // 拆题已提交；修前：异常逃出 _confirmSplit，_load() 不执行，
      // 列表仍停在修框中的旧行（「继续修框」还在）。
      expect(repo.savedQuestions.length, 1);
      expect(find.text('去整理'), findsOneWidget);
      expect(find.text('继续修框'), findsNothing);
      expect(find.text('修框'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('恢复自动框 hasManual', () {
    testWidgets('只有 YOLO 框时不弹确认，直接重检替换', (tester) async {
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
        yoloService: _SelectiveYolo(origin: 'yolo'),
      );
      await openEditor(tester, '修框');
      expect(editorBoxLabel('题级框 1'), findsOneWidget);
      await tester.tap(find.text('恢复自动框'));
      await tester.pumpAndSettle();
      // 没弹“替换手动框”确认，直接重检，框还在。
      expect(find.text('用自动框替换当前页的手动框？'), findsNothing);
      expect(editorBoxLabel('题级框 1'), findsOneWidget);
    });

    testWidgets('有手动框时先弹确认，点取消保留原框', (tester) async {
      final repo = FakeRepo([
        task(
          't-needbox',
          '待框选文件.pdf · 第1页 · 第1题',
          status: CollectStatus.needBox,
        ),
      ]);
      await pumpCollect(tester, repo: repo);
      await openEditor(tester, '修框');
      expect(editorBoxLabel('题级框 1'), findsOneWidget);
      await tester.tap(find.text('恢复自动框'));
      await tester.pumpAndSettle();
      expect(find.text('用自动框替换当前页的手动框？'), findsOneWidget);
      // 「取消」有两个：确认框里的和编辑器自身的，只点确认框里的。
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('取消'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('用自动框替换当前页的手动框？'), findsNothing);
      expect(editorBoxLabel('题级框 1'), findsOneWidget);
    });
  });

  group('B2 Win11 bug 批 · 收集中心', () {
    testWidgets('B2-1 选中学科后下拉框是正常底色，不是禁用灰', (tester) async {
      await pumpCollect(tester, repo: FakeRepo([]));
      expect(find.text('请选择学科'), findsOneWidget);
      // 占位态：字段底色就是 surface，hint 是 muted 色。
      var field = tester.widget<Container>(
        find.byKey(const Key('collect-subject-select-field')),
      );
      expect(
        (field.decoration as BoxDecoration?)?.color,
        DesignTokens.light.surface,
      );
      await tester.tap(find.byKey(const Key('collect-subject-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('数学'));
      await tester.pumpAndSettle();
      expect(find.text('数学'), findsOneWidget);
      expect(find.text('请选择学科'), findsNothing);
      // 选中后：字段底色仍是 surface（不是禁用灰），
      // DropdownButton 的 focusColor 置透明（Win11 桌面 traditional
      // 高亮模式下，获焦的 12% 黑 focus 洗就是截图里的灰底）。
      field = tester.widget<Container>(
        find.byKey(const Key('collect-subject-select-field')),
      );
      expect(
        (field.decoration as BoxDecoration?)?.color,
        DesignTokens.light.surface,
      );
      final dropdown = tester.widget<DropdownButton<String>>(
        find.byKey(const Key('collect-subject-select')),
      );
      expect(dropdown.value, 'math');
      expect(dropdown.focusColor, Colors.transparent);
    });

    testWidgets('B2-1 深色下选中学科后下拉框也是正常底色', (tester) async {
      await pumpCollect(
        tester,
        repo: FakeRepo([]),
        brightness: Brightness.dark,
      );
      await tester.tap(find.byKey(const Key('collect-subject-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('英语'));
      await tester.pumpAndSettle();
      final field = tester.widget<Container>(
        find.byKey(const Key('collect-subject-select-field')),
      );
      expect(
        (field.decoration as BoxDecoration?)?.color,
        DesignTokens.dark.surface,
      );
      expect(find.text('英语'), findsOneWidget);
    });

    testWidgets('B2-6a 待框选/修框中/待整理/已整理行都有删除入口', (tester) async {
      await pumpCollect(
        tester,
        repo: FakeRepo([
          task(
            't-needbox',
            '待框选文件.pdf · 第1页 · 第1题',
            status: CollectStatus.needBox,
          ),
          task(
            't-ready',
            '待整理文件.pdf · 第1页 · 第1题',
            status: CollectStatus.pendingOrganize,
          ),
          task('t-done', '已整理文件.pdf · 第1页 · 第1题', status: CollectStatus.done),
        ]),
      );
      // 3 个任务不包 ListView，全行都在树上。
      expect(find.text('删除'), findsNWidgets(3));
      expect(find.text('修框'), findsOneWidget);
      expect(find.text('去整理'), findsNWidgets(2));
    });

    testWidgets('B2-6a 点删除先弹确认框，取消不删、确认删除', (tester) async {
      final repo = FakeRepo([
        task(
          't-ready',
          '待整理文件.pdf · 第1页 · 第1题',
          status: CollectStatus.pendingOrganize,
        ),
      ]);
      await pumpCollect(tester, repo: repo);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('删了就没了，确定吗？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.textContaining('修框 ·'), findsNothing);
      expect(find.text('待整理文件.pdf · 第1页 · 第1题'), findsOneWidget);
      expect(repo.deletedTaskIds, isEmpty);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(find.text('待整理文件.pdf · 第1页 · 第1题'), findsNothing);
      expect(repo.deletedTaskIds, contains('t-ready'));
    });

    testWidgets('B2-6b 修框 overlay 高度接近视口高，画布随之变大', (tester) async {
      final repo = FakeRepo([
        task(
          't-needbox',
          '待框选文件.pdf · 第1页 · 第1题',
          status: CollectStatus.needBox,
        ),
      ]);
      await pumpCollect(tester, repo: repo);
      // 用 1000 高的视口：旧的 648 封顶在这里会卡住，新的高度跟视口走。
      tester.view.physicalSize = const Size(1280, 1000);
      await tester.pumpAndSettle();
      await openEditor(tester, '修框');
      // 对话框高 = 视口高 - 48（只留 insetPadding 的上下边距），
      // 不再是旧的 648 封顶。
      final dialog = tester.widget<Dialog>(find.byType(Dialog).first);
      expect((dialog.child as SizedBox).height, 1000 - 48);
      // 画布随之变大：旧的 648 高对话框里画布只有约 480px 高。
      final canvasHeight = tester
          .getRect(find.byKey(const Key('box-editor-canvas')))
          .height;
      expect(canvasHeight, greaterThan(480));
    });

    testWidgets('B2-6b 滚轮在图上缩放、在图外滚动', (tester) async {
      final repo = FakeRepo([
        task(
          't-needbox',
          '待框选文件.pdf · 第1页 · 第1题',
          status: CollectStatus.needBox,
        ),
      ]);
      await pumpCollect(tester, repo: repo);
      await openEditor(tester, '修框');
      expect(find.text('100%'), findsOneWidget);
      final (origin, pageW, pageH) = editorPageMetrics(tester);
      final center = origin + Offset(pageW / 2, pageH / 2);
      // 滚轮在图上：缩放 100% → 110%。
      await scrollWheel(tester, center, const Offset(0, -120));
      expect(find.text('110%'), findsOneWidget);
      // 放大到 200%：内容超出视口，才有东西可滚。
      for (var i = 0; i < 9; i++) {
        await scrollWheel(tester, center, const Offset(0, -120));
      }
      expect(find.text('200%'), findsOneWidget);
      // 图外边距滚轮：不缩放，页面上下滚动。
      final canvasRect = tester.getRect(
        find.byKey(const Key('box-editor-canvas')),
      );
      final marginPoint = Offset(canvasRect.left + 10, canvasRect.center.dy);
      // 保护：边距点必须确实落在图外，否则测试本身站不住
      //（放大后页变大了，用检测框矩形反推当前页左缘）。
      final zoomedBoxRect = tester.getRect(editorBoxHandle('题级框 1'));
      final pageLeft = zoomedBoxRect.left - 0.06 * (zoomedBoxRect.width / 0.88);
      expect(marginPoint.dx < pageLeft, isTrue);
      final before = editorVerticalPixels(tester);
      await scrollWheel(tester, marginPoint, const Offset(0, 120));
      expect(find.text('200%'), findsOneWidget);
      expect(editorVerticalPixels(tester), greaterThan(before));
    });

    testWidgets('B2-6b 左键拖动平移图片、不画框', (tester) async {
      final repo = FakeRepo([
        task(
          't-needbox',
          '待框选文件.pdf · 第1页 · 第1题',
          status: CollectStatus.needBox,
        ),
      ]);
      await pumpCollect(tester, repo: repo);
      await openEditor(tester, '修框');
      final (origin, pageW, pageH) = editorPageMetrics(tester);
      // 图内框外空白（页左缘，检测框从 x=0.06 开始）：左键拖动不画框。
      final emptyInPage = origin + Offset(0.02 * pageW, 0.5 * pageH);
      await dragMouseLeft(tester, emptyInPage, const Offset(20, 20));
      expect(find.text('这个框是？'), findsNothing);
      // 放大到 200% 再左键拖动图外边距：图片平移（竖向滚动偏移变大）。
      final center = origin + Offset(pageW / 2, pageH / 2);
      for (var i = 0; i < 10; i++) {
        await scrollWheel(tester, center, const Offset(0, -120));
      }
      expect(find.text('200%'), findsOneWidget);
      final canvasRect = tester.getRect(
        find.byKey(const Key('box-editor-canvas')),
      );
      final marginPoint = Offset(canvasRect.left + 10, canvasRect.center.dy);
      final zoomedBoxRect = tester.getRect(editorBoxHandle('题级框 1'));
      final pageLeft = zoomedBoxRect.left - 0.06 * (zoomedBoxRect.width / 0.88);
      expect(marginPoint.dx < pageLeft, isTrue);
      final before = editorVerticalPixels(tester);
      await dragMouseLeft(tester, marginPoint, const Offset(0, -60));
      expect(editorVerticalPixels(tester), greaterThan(before));
      expect(find.text('这个框是？'), findsNothing);
    });

    testWidgets('B2-6b 左键拖框仍移动框', (tester) async {
      final repo = FakeRepo([
        task(
          't-needbox',
          '待框选文件.pdf · 第1页 · 第1题',
          status: CollectStatus.needBox,
        ),
      ]);
      await pumpCollect(tester, repo: repo);
      await openEditor(tester, '修框');
      // 占位框几乎盖满整页、没多少移动空间；先删掉，右键画一个小框再拖。
      final stub = editorBoxHandle('题级框 1');
      await tester.ensureVisible(stub);
      await tester.pumpAndSettle();
      await tester.tap(stub);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除选中框'));
      await tester.pumpAndSettle();
      var (origin, pageW, pageH) = editorPageMetrics(tester);
      await dragMouseRight(
        tester,
        origin + Offset(0.05 * pageW, 0.05 * pageH),
        Offset(0.4 * pageW, 0.4 * pageH),
      );
      // 右键画框直接成题级框，不再弹选类型菜单。
      expect(find.text('这个框是？'), findsNothing);
      expect(editorBoxLabel('题级框 1'), findsOneWidget);
      final box = editorBoxHandle('题级框 1');
      await tester.ensureVisible(box);
      await tester.pumpAndSettle();
      final before = tester.getRect(box);
      await dragMouseLeft(tester, before.center, const Offset(60, 40));
      final after = tester.getRect(editorBoxHandle('题级框 1'));
      // 拖动方向对、位移明显即可：第一段位移会被手势 slop 吃掉一部分，
      // 不按精确像素断言。
      expect(after.left - before.left, greaterThan(10));
      expect(after.top - before.top, greaterThan(10));
      expect(find.text('这个框是？'), findsNothing);
    });

    testWidgets('B2-6b 右键拖动画框、右键单击取消', (tester) async {
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
      final box = editorBoxHandle('题级框 1');
      await tester.ensureVisible(box);
      await tester.pumpAndSettle();
      await tester.tap(box);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除选中框'));
      await tester.pumpAndSettle();
      // 右键拖动：画出新框，直接成题级框，不弹选类型菜单。
      var (origin, pageW, pageH) = editorPageMetrics(tester);
      await dragMouseRight(
        tester,
        origin + Offset(0.05 * pageW, 0.05 * pageH),
        Offset(0.4 * pageW, 0.4 * pageH),
      );
      expect(find.text('这个框是？'), findsNothing);
      expect(editorBoxLabel('题级框 1'), findsOneWidget);
      // 页左缘空白（题级框外、图内）：右键单击 = 取消，什么都不发生。
      (origin, pageW, pageH) = editorPageMetrics(tester);
      await clickMouseRight(tester, origin + Offset(0.02 * pageW, 0.5 * pageH));
      expect(find.text('这个框是？'), findsNothing);
      expect(editorBoxLabel('题级框 1'), findsOneWidget);
    });
    testWidgets('B3 右键起点在框上画新框、左键在框上仍拖动', (tester) async {
      final repo = FakeRepo([
        task(
          't-needbox',
          '待框选文件.pdf · 第1页 · 第1题',
          status: CollectStatus.needBox,
        ),
      ]);
      await pumpCollect(tester, repo: repo);
      await openEditor(tester, '修框');
      var (origin, pageW, pageH) = editorPageMetrics(tester);
      final before = tester.getRect(editorBoxHandle('题级框 1'));
      // 原框页内归一化坐标（左/上/宽/高）：重叠警告横幅出现后画布会重排，
      // 像素坐标会变，用归一化坐标比才稳。
      (double, double, double, double) norm(
        Rect r,
        Offset o,
        double pw,
        double ph,
      ) => (
        (r.left - o.dx) / pw,
        (r.top - o.dy) / ph,
        r.width / pw,
        r.height / ph,
      );
      final beforeNorm = norm(before, origin, pageW, pageH);
      // 右键从占位框中心起拖：画出新框，直接成题级框 2，原框不动
      //（不被拖走）。
      await dragMouseRight(
        tester,
        before.center,
        Offset(0.3 * pageW, 0.25 * pageH),
      );
      expect(find.text('这个框是？'), findsNothing);
      expect(editorBoxLabel('题级框 2'), findsOneWidget);
      // 两框重叠会出警告横幅：按页内归一化坐标比，原框位置不变。
      (origin, pageW, pageH) = editorPageMetrics(tester);
      final afterNorm = norm(
        tester.getRect(editorBoxHandle('题级框 1')),
        origin,
        pageW,
        pageH,
      );
      expect(afterNorm.$1, closeTo(beforeNorm.$1, 0.005));
      expect(afterNorm.$2, closeTo(beforeNorm.$2, 0.005));
      expect(afterNorm.$3, closeTo(beforeNorm.$3, 0.005));
      expect(afterNorm.$4, closeTo(beforeNorm.$4, 0.005));
      // 左键在原框上（新框盖不到的左上角）拖动：原框仍移动。
      (origin, pageW, pageH) = editorPageMetrics(tester);
      final boxBefore = tester.getRect(editorBoxHandle('题级框 1'));
      await dragMouseLeft(
        tester,
        origin + Offset(0.1 * pageW, 0.1 * pageH),
        const Offset(60, 40),
      );
      final boxAfter = tester.getRect(editorBoxHandle('题级框 1'));
      expect(boxAfter.left - boxBefore.left, greaterThan(10));
      expect(boxAfter.top - boxBefore.top, greaterThan(10));
      expect(find.text('这个框是？'), findsNothing);
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
