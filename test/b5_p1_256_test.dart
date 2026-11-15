// Batch 5 第二阶段 P1 丢数据类：SR-P1-5 + SR-P1-6 + SR-P1-2 回归测试。
//
// SR-P1-5（详情页重框）：已存 2 层内框按裸 parentBoxId 传进编辑器，
//   编辑器内部键是 '<页>:<框id>'，旧内框不可见、双击造出 3 个默认框，
//   确认后新旧内框重复入库。
// SR-P1-6（收集页继续修框）：草稿里的 2 层框混进 initialBoxesByPage，
//   拖动/删除静默失效，确认拆题时直接丢弃。
//   两项同一根因：入口归一化（normalizeBoxEditorInputs）一次收敛，
//   两处调用方都不改——本文件先单测归一化函数本身，再按两处调用方
//   的原样传参走一遍真编辑器（探针思路转正式测试）。
// SR-P1-2（确认拆题）：保留任务重建收进 confirmSplitInto 同一事务，
//   内存库断言一次调用同时建出拆分题 + 拆分任务 + 保留任务 + 未框页草稿。
//
// 不碰真实演示库：widget 测试只用临时页图；DB 测试用内存库。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/collect/box_editor.dart';
import 'package:quiz_master2/services/yolo_onnx_service.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

late final Directory _testTmp;
late final String _pagePngPath;

/// 最近一次编辑器确认返回的结果（harness 的按钮回调写入）。
BoxEditorResult? _capturedResult;

QuestionBox _box({
  required String id,
  int layer = 1,
  String type = 'question',
  double x = 0.1,
  double y = 0.1,
  double w = 0.5,
  double h = 0.3,
  int page = 1,
  String? parentBoxId,
  String? questionId,
  String? collectTaskId,
}) => QuestionBox(
  id: id,
  layer: layer,
  type: type,
  x: x,
  y: y,
  w: w,
  h: h,
  page: page,
  parentBoxId: parentBoxId,
  questionId: questionId,
  collectTaskId: collectTaskId,
);

/// 桩检测：不跑真实模型，返回空框（不走 fallback，不落占位框）。
class _EmptyYolo extends YoloOnnxService {
  @override
  Future<DetectionResult> detectPage({
    required String imagePath,
    required int page,
  }) async => const DetectionResult(boxes: [], usedFallback: false);
}

/// 画布内的框标签（底部 hint 也含“题级框 N”，必须限定在画布内找）。
Finder _editorBoxLabel(String label) => find.descendant(
  of: find.byKey(const Key('box-editor-canvas')),
  matching: find.textContaining(label),
);

/// 画布内某标签所属的框手柄（GestureDetector，key 是 `editor-box-<id>`）。
Finder _editorBoxHandle(String label) => find.ancestor(
  of: _editorBoxLabel(label),
  matching: find.byWidgetPredicate(
    (w) =>
        w is GestureDetector &&
        w.key is ValueKey<String> &&
        (w.key as ValueKey<String>).value.startsWith('editor-box-'),
  ),
);

/// B2-6b：鼠标左键拖动（主要按键）——拖框用。
Future<TestGesture> _dragMouseLeft(
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

/// 打开修框编辑器的测试宿主：点“打开修框”按钮调 showBoxEditorDialog，
/// 确认结果写进 [_capturedResult]。
Future<void> _openEditorDialog(
  WidgetTester tester, {
  required int page,
  int pageCount = 1,
  required BoxEditorMode mode,
  Map<int, List<QuestionBox>> initialBoxesByPage = const {},
  Map<String, List<QuestionBox>> initialInners = const {},
  Map<int, List<QuestionBox>> initialStandalone = const {},
  String taskId = 'task-test',
  String? reworkQuestionId,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  _capturedResult = null;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              _capturedResult = await showBoxEditorDialog(
                context: context,
                fileName: 'test.pdf',
                pageImagePath: _pagePngPath,
                page: page,
                pageCount: pageCount,
                subjectName: '数学',
                taskId: taskId,
                mode: mode,
                initialBoxesByPage: initialBoxesByPage,
                initialInners: initialInners,
                initialStandalone: initialStandalone,
                reworkQuestionId: reworkQuestionId,
                yoloService: _EmptyYolo(),
              );
            },
            child: const Text('打开修框'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('打开修框'));
  await tester.pumpAndSettle();
  expect(find.text('确认修框，去整理'), findsOneWidget);
}

/// 双击题级框进内框模式（collect_page_test 的同款做法）。
Future<void> _doubleTapBox(WidgetTester tester, Finder box) async {
  await tester.ensureVisible(box);
  await tester.pumpAndSettle();
  await tester.tap(box);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(box);
  await tester.pumpAndSettle();
}

Future<void> _tapConfirm(WidgetTester tester) async {
  await tester.tap(find.text('确认修框，去整理'));
  await tester.pumpAndSettle();
  expect(find.text('确认修框，去整理'), findsNothing);
}

void main() {
  setUpAll(() async {
    _testTmp = await Directory.systemTemp.createTemp('qm2-b5-p1-256');
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 560, 700),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    final img = await recorder.endRecording().toImage(560, 700);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    final file = File('${_testTmp.path}/page.png');
    await file.writeAsBytes(png!.buffer.asUint8List());
    _pagePngPath = file.path;
  });

  tearDownAll(() async {
    await _testTmp.delete(recursive: true);
  });

  group('normalizeBoxEditorInputs（SR-P1-5 / SR-P1-6 同一根因）', () {
    test('详情页口径：inners 裸键按父框所在页补前缀', () {
      final r = normalizeBoxEditorInputs(
        boxesByPage: {
          2: [_box(id: 'q1-box', page: 2, x: 0.06, y: 0.05, w: 0.88, h: 0.4)],
        },
        inners: {
          'q1-box': [
            _box(
              id: 'q1-stem',
              layer: 2,
              type: 'stem',
              page: 2,
              parentBoxId: 'q1-box',
            ),
          ],
        },
        standaloneInner: const {},
        currentPage: 2,
      );
      expect(r.inners.keys, ['2:q1-box']);
      expect(r.inners['2:q1-box']!.map((b) => b.id), ['q1-stem']);
      expect(r.boxesByPage[2]!.length, 1);
    });

    test('已带页前缀的键原样保留，不重复加前缀', () {
      final r = normalizeBoxEditorInputs(
        boxesByPage: {
          1: [_box(id: 'b1', page: 1)],
        },
        inners: {
          '1:b1': [_box(id: 's1', layer: 2, type: 'stem', parentBoxId: 'b1')],
        },
        standaloneInner: const {},
        currentPage: 1,
      );
      expect(r.inners.keys, ['1:b1']);
    });

    test('收集页口径：boxesByPage 里混进来的 2 层框按归属拆出', () {
      final r = normalizeBoxEditorInputs(
        boxesByPage: {
          1: [
            _box(id: 'b1', page: 1, x: 0.06, y: 0.05, w: 0.88, h: 0.85),
            _box(
              id: 'stem-1',
              layer: 2,
              type: 'stem',
              page: 1,
              x: 0.1,
              y: 0.1,
              w: 0.4,
              h: 0.2,
              parentBoxId: 'b1',
            ),
            _box(
              id: 'orphan-1',
              layer: 2,
              type: 'figure',
              page: 1,
              x: 0.6,
              y: 0.6,
              w: 0.2,
              h: 0.2,
            ),
          ],
        },
        inners: const {},
        standaloneInner: const {},
        currentPage: 1,
      );
      // 1 层框只剩 1 个；有父框的 stem 进 inners，无主的进 standalone。
      expect(r.boxesByPage[1]!.map((b) => b.id), ['b1']);
      expect(r.inners.keys, ['1:b1']);
      expect(r.inners['1:b1']!.map((b) => b.id), ['stem-1']);
      expect(r.standaloneInner[1]!.map((b) => b.id), ['orphan-1']);
    });

    test('同一 2 层框在两处出现时只留一份，不重复', () {
      final stem = _box(
        id: 'stem-1',
        layer: 2,
        type: 'stem',
        page: 1,
        parentBoxId: 'b1',
      );
      final r = normalizeBoxEditorInputs(
        boxesByPage: {
          1: [_box(id: 'b1', page: 1), stem],
        },
        inners: {
          'b1': [stem],
        },
        standaloneInner: const {},
        currentPage: 1,
      );
      expect(r.inners['1:b1']!.length, 1);
      expect(r.standaloneInner[1], isNull);
    });

    test('inners 框的 parentBoxId 与键里的父框 id 对齐', () {
      final r = normalizeBoxEditorInputs(
        boxesByPage: {
          1: [_box(id: 'b1', page: 1)],
        },
        inners: {
          'b1': [_box(id: 's1', layer: 2, type: 'stem')],
        },
        standaloneInner: const {},
        currentPage: 1,
      );
      expect(r.inners['1:b1']!.first.parentBoxId, 'b1');
    });
  });

  group('SR-P1-5 详情页重框：已存 2 层内框可见、不造默认框、不重复入库', () {
    testWidgets('裸键内框可见，双击进内框模式只有旧框，确认后不多框', (tester) async {
      // 详情页 _reworkBoxes 的原样传参：裸 parentBoxId 键 + 源页 2。
      await _openEditorDialog(
        tester,
        page: 2,
        mode: BoxEditorMode.rework,
        initialBoxesByPage: {
          2: [_box(id: 'q1-box', page: 2, x: 0.06, y: 0.05, w: 0.88, h: 0.4)],
        },
        initialInners: {
          'q1-box': [
            _box(
              id: 'q1-stem',
              layer: 2,
              type: 'stem',
              page: 2,
              x: 0.1,
              y: 0.1,
              w: 0.4,
              h: 0.2,
              parentBoxId: 'q1-box',
            ),
          ],
        },
        taskId: 'rework-q1',
        reworkQuestionId: 'q1',
      );
      // 不进内框模式：旧内框已在题级框内嵌套显示（修前是看不见的）。
      expect(_editorBoxLabel('stem 题干'), findsOneWidget);
      // 双击题级框进内框模式：旧框沿用，不凭空造 stem/option/figure。
      await _doubleTapBox(tester, _editorBoxHandle('题级框 1'));
      expect(find.textContaining('已进入题级框'), findsOneWidget);
      // 草稿 stem 已归入 inners：进内框模式沿用旧框，不造默认框
      //（修前：旧框找不到，凭空造出 stem/option/figure 三个默认框，
      // 下面两行就会命中，测试失败）。
      expect(_editorBoxLabel('option 选项'), findsNothing);
      expect(_editorBoxLabel('figure 配图'), findsNothing);
      expect(_editorBoxLabel('stem 题干'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await _tapConfirm(tester);
      // 确认结果：1 个题级框 + 1 个内框，键已归一化，不重复。
      final result = _capturedResult!;
      expect(result.boxesByPage[2]!.where((b) => b.layer == 1).length, 1);
      expect(result.inners.keys, ['2:q1-box']);
      expect(result.inners['2:q1-box']!.map((b) => b.id), ['q1-stem']);
      expect(
        result.inners.values.expand((v) => v).where((b) => b.layer == 2),
        hasLength(1),
      );
    });
  });

  group('SR-P1-6 收集页继续修框：草稿 2 层框不混层、可删、确认不丢', () {
    testWidgets('混进 1 层框的 2 层草稿确认后仍在 inners，不丢弃', (tester) async {
      // 收集页 _openBoxEditor 的原样传参：1 层 + 2 层扁平混进
      // initialBoxesByPage，不传 initialInners。
      await _openEditorDialog(
        tester,
        page: 1,
        mode: BoxEditorMode.draft,
        initialBoxesByPage: {
          1: [
            _box(id: 'b1', page: 1, x: 0.06, y: 0.05, w: 0.88, h: 0.85),
            _box(
              id: 'stem-1',
              layer: 2,
              type: 'stem',
              page: 1,
              x: 0.1,
              y: 0.1,
              w: 0.4,
              h: 0.2,
              parentBoxId: 'b1',
            ),
          ],
        },
      );
      // 2 层框可见（题级框内嵌套显示），1 层框仍只有 1 个。
      expect(_editorBoxLabel('stem 题干'), findsOneWidget);
      expect(_editorBoxLabel('题级框 1'), findsOneWidget);
      await _tapConfirm(tester);
      final result = _capturedResult!;
      // 修前：result.boxesByPage[1] 仍有 2 个框、inners 为空，
      // _confirmSplit 只取 inners，stem 随原任务删除一起丢。
      expect(result.boxesByPage[1]!.map((b) => b.id), ['b1']);
      expect(result.inners.keys, ['1:b1']);
      expect(result.inners['1:b1']!.map((b) => b.id), ['stem-1']);
      expect(result.standaloneInner[1], isNull);
    });

    testWidgets('归一化后的 2 层框可拖动、可删除', (tester) async {
      await _openEditorDialog(
        tester,
        page: 1,
        mode: BoxEditorMode.draft,
        initialBoxesByPage: {
          1: [
            _box(id: 'b1', page: 1, x: 0.06, y: 0.05, w: 0.88, h: 0.85),
            _box(
              id: 'stem-1',
              layer: 2,
              type: 'stem',
              page: 1,
              x: 0.1,
              y: 0.1,
              w: 0.4,
              h: 0.2,
              parentBoxId: 'b1',
            ),
          ],
        },
      );
      await _doubleTapBox(tester, _editorBoxHandle('题级框 1'));
      expect(find.textContaining('已进入题级框'), findsOneWidget);
      // 草稿 stem 已归入 inners：进内框模式沿用旧框，不造默认框
      //（修前：旧框找不到，凭空造出 stem/option/figure 三个默认框，
      // 下面两行就会命中，测试失败）。
      expect(_editorBoxLabel('option 选项'), findsNothing);
      expect(_editorBoxLabel('figure 配图'), findsNothing);
      // 拖动：内框模式下点中 stem 框拖 60×40，框跟着走（修前静默不动）。
      final stem = _editorBoxHandle('stem 题干');
      final before = tester.getRect(stem);
      await _dragMouseLeft(tester, before.center, const Offset(60, 40));
      final after = tester.getRect(_editorBoxHandle('stem 题干'));
      expect(after.left - before.left, greaterThan(10));
      expect(after.top - before.top, greaterThan(10));
      // 删除：选中 stem 点“删除选中框”，框消失（修前静默失效、框仍在）。
      await tester.tap(_editorBoxHandle('stem 题干'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除选中框'));
      await tester.pumpAndSettle();
      expect(_editorBoxLabel('stem 题干'), findsNothing);
      // 退出内框模式再确认：inners 里已无该框，题级框还在。
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await _tapConfirm(tester);
      final result = _capturedResult!;
      expect(result.boxesByPage[1]!.where((b) => b.layer == 1).length, 1);
      // 删掉的是草稿 stem 本身：inners 里既无 stem-1，也没有双击
      // 造出的默认 option/figure（修前确认结果里会有那两个默认框）。
      expect(
        result.inners.values.expand((v) => v).where((b) => b.id == 'stem-1'),
        isEmpty,
      );
      expect(result.inners['1:b1'], isEmpty);
    });
  });

  group('SR-P1-2 确认拆题：保留任务重建与拆题同事务', () {
    Future<Database> openMemoryDb() async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, version) async => AppDatabase.createTables(db),
        ),
      );
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => db.close());
      return db;
    }

    test('一次 confirmSplitInto 建出拆分题 + 拆分任务 + 保留任务 + 未框页草稿', () async {
      final db = await openMemoryDb();
      final orig = CollectTask(
        id: 'task-orig',
        name: 'orig.pdf · 第1页 · 第1题',
        fileName: 'orig.pdf',
        subjectId: 'math',
        status: CollectStatus.boxing,
        pageCount: 3,
        page: 1,
        sourcePath: 'imports/task-orig/original.pdf',
      );
      await AppDatabase.instance.upsertCollectTask(orig);
      // 草稿：第 1 页 1 层框（本次确认拆走）+ 第 2 页独立题内框
      //（未框页的草稿，本就没有 1 层框）。
      await AppDatabase.saveDraftBoxesInto(
        db,
        taskId: 'task-orig',
        boxesByPage: {
          1: [_box(id: 'draft-1', collectTaskId: 'task-orig')],
        },
        inners: const {},
        standaloneInner: {
          2: [
            _box(
              id: 'draft-orphan',
              layer: 2,
              type: 'stem',
              page: 2,
              collectTaskId: 'task-orig',
            ),
          ],
        },
        rotations: const {},
      );
      final questions = [
        Question(
          id: 'import-1',
          title: 'orig.pdf · 第1页 · 第1题',
          subjectId: 'math',
          createdAt: DateTime(2026, 11, 14),
          sourcePath: 'imports/task-orig/original.pdf',
          sourceKind: 'pdf',
          sourcePage: 1,
          pageImagePath: 'imports/task-orig/original.pdf',
          slicePath: 'slices/import-1.png',
          sliceWidth: 200,
          sliceHeight: 100,
        ),
      ];
      final splitTasks = [
        CollectTask(
          id: 'task-split-1',
          name: 'orig.pdf · 第1页 · 第1题',
          fileName: 'orig.pdf',
          subjectId: 'math',
          status: CollectStatus.pendingOrganize,
          pageCount: 3,
          page: 1,
          questionId: 'import-1',
          sourcePath: 'imports/task-orig/original.pdf',
        ),
      ];
      // 保留任务：与原任务同 id，回待框选、从首个未框页（第 2 页）继续，
      // 第 2 页带 90° 旋转角。
      final retained = CollectTask(
        id: 'task-orig',
        name: 'orig.pdf · 第1页 · 第1题',
        fileName: 'orig.pdf',
        subjectId: 'math',
        status: CollectStatus.needBox,
        progress: 100,
        pageCount: 3,
        page: 2,
        createdAt: orig.createdAt,
        sourcePath: 'imports/task-orig/original.pdf',
        pageRotations: const {2: 90},
      );
      await AppDatabase.confirmSplitInto(
        db,
        originalTask: orig,
        questions: questions,
        splitTasks: splitTasks,
        boxesByQuestionId: {
          'import-1': [_box(id: 'draft-1', questionId: 'import-1')],
        },
        retainedTask: retained,
        retainedBoxesByPage: const {2: [], 3: []},
        retainedInners: const {},
        retainedStandaloneInner: {
          2: [
            _box(
              id: 'draft-orphan',
              layer: 2,
              type: 'stem',
              page: 2,
              collectTaskId: 'task-orig',
            ),
          ],
        },
      );
      // 拆分结果在。
      expect(
        (await AppDatabase.instance.questionById('import-1'))?.slicePath,
        'slices/import-1.png',
      );
      final tasks = await AppDatabase.instance.allCollectTasks();
      expect(tasks.map((t) => t.id).toSet(), {'task-split-1', 'task-orig'});
      expect(
        tasks.firstWhere((t) => t.id == 'task-split-1').status,
        CollectStatus.pendingOrganize,
      );
      // 保留任务：同 id 还在，回待框选、从第 2 页修、旋转角跟着走。
      final kept = tasks.firstWhere((t) => t.id == 'task-orig');
      expect(kept.status, CollectStatus.needBox);
      expect(kept.page, 2);
      expect(kept.pageCount, 3);
      expect(kept.pageRotations[2], 90);
      // 未框页草稿还在（第 2 页独立题内框），已拆页的草稿已转成题框。
      final drafts = await AppDatabase.boxesForTaskFrom(db, 'task-orig');
      expect(drafts.map((b) => b.id), ['draft-orphan']);
      expect(drafts.first.layer, 2);
      final qBoxes = await AppDatabase.boxesForPageImageFrom(
        db,
        'imports/task-orig/original.pdf',
      );
      expect(qBoxes.map((b) => b.questionId), ['import-1']);
    });

    test('SR2-11 事务中途写框失败：调用抛错，题/任务/框/原任务全部回滚', () async {
      final db = await openMemoryDb();
      final orig = CollectTask(
        id: 'task-orig',
        name: 'orig.pdf · 第1页 · 第1题',
        fileName: 'orig.pdf',
        subjectId: 'math',
        status: CollectStatus.boxing,
        pageCount: 3,
        page: 1,
        sourcePath: 'imports/task-orig/original.pdf',
      );
      await AppDatabase.instance.upsertCollectTask(orig);
      await AppDatabase.saveDraftBoxesInto(
        db,
        taskId: 'task-orig',
        boxesByPage: {
          1: [_box(id: 'draft-1', collectTaskId: 'task-orig')],
        },
        inners: const {},
        standaloneInner: const {},
        rotations: const {},
      );
      // 触发器立在后半段写操作上：confirmSplitInto 插 question_boxes
      // 时炸（草稿已种好，触发器立在种草稿之后，不影响种子数据）。
      await db.execute('''
        CREATE TRIGGER trg_sr2_11_fail_qbox
        BEFORE INSERT ON question_boxes
        BEGIN
          SELECT RAISE(ABORT, 'simulated write failure');
        END
      ''');
      // 调用抛错：insert questions 已跑、insert question_boxes 炸，
      // 事务整体回滚（修前若退化为多步写库，这里会留下半截题/任务）。
      await expectLater(
        AppDatabase.confirmSplitInto(
          db,
          originalTask: orig,
          questions: [
            Question(
              id: 'import-1',
              title: 'orig.pdf · 第1页 · 第1题',
              subjectId: 'math',
              createdAt: DateTime(2026, 11, 14),
              sourcePath: 'imports/task-orig/original.pdf',
              sourceKind: 'pdf',
              sourcePage: 1,
              pageImagePath: 'imports/task-orig/original.pdf',
              slicePath: 'slices/import-1.png',
              sliceWidth: 200,
              sliceHeight: 100,
            ),
          ],
          splitTasks: [
            CollectTask(
              id: 'task-split-1',
              name: 'orig.pdf · 第1页 · 第1题',
              fileName: 'orig.pdf',
              subjectId: 'math',
              status: CollectStatus.pendingOrganize,
              pageCount: 3,
              page: 1,
              questionId: 'import-1',
              sourcePath: 'imports/task-orig/original.pdf',
            ),
          ],
          boxesByQuestionId: {
            'import-1': [_box(id: 'draft-1', questionId: 'import-1')],
          },
          retainedTask: CollectTask(
            id: 'task-orig',
            name: 'orig.pdf · 第1页 · 第1题',
            fileName: 'orig.pdf',
            subjectId: 'math',
            status: CollectStatus.needBox,
            progress: 100,
            pageCount: 3,
            page: 2,
            createdAt: orig.createdAt,
            sourcePath: 'imports/task-orig/original.pdf',
          ),
          retainedBoxesByPage: const {2: [], 3: []},
          retainedInners: const {},
          retainedStandaloneInner: const {},
        ),
        throwsA(isA<Exception>()),
      );
      // 全部回滚：题没建、拆分任务与保留任务都没建、原任务行仍在
      // （仍是修框中，不是回待框选的保留任务）、草稿框还在。
      expect(await AppDatabase.instance.questionById('import-1'), isNull);
      final tasks = await AppDatabase.instance.allCollectTasks();
      expect(tasks.map((t) => t.id), ['task-orig']);
      expect(tasks.first.status, CollectStatus.boxing);
      final drafts = await AppDatabase.boxesForTaskFrom(db, 'task-orig');
      expect(drafts.map((b) => b.id), ['draft-1']);
      expect(drafts.first.questionId, isNull);
    });

    test('无未框页时不传保留任务：行为与原来一致，只剩拆分任务', () async {
      final db = await openMemoryDb();
      final orig = CollectTask(
        id: 'task-orig',
        name: 'orig.jpg · 第1页 · 第1题',
        fileName: 'orig.jpg',
        subjectId: 'math',
        status: CollectStatus.boxing,
      );
      await AppDatabase.instance.upsertCollectTask(orig);
      await AppDatabase.saveDraftBoxesInto(
        db,
        taskId: 'task-orig',
        boxesByPage: {
          1: [_box(id: 'draft-1', collectTaskId: 'task-orig')],
        },
        inners: const {},
        standaloneInner: const {},
        rotations: const {},
      );
      await AppDatabase.confirmSplitInto(
        db,
        originalTask: orig,
        questions: [
          Question(
            id: 'import-1',
            title: '题 import-1',
            subjectId: 'math',
            createdAt: DateTime(2026, 11, 14),
            sourcePath: 'imports/task-orig/original.jpg',
            sourceKind: 'image',
            sourcePage: 1,
            pageImagePath: 'imports/task-orig/original.jpg',
            slicePath: 'slices/import-1.png',
            sliceWidth: 200,
            sliceHeight: 100,
          ),
        ],
        splitTasks: [
          CollectTask(
            id: 'task-split-1',
            name: 'orig.jpg · 第1页 · 第1题',
            fileName: 'orig.jpg',
            subjectId: 'math',
            status: CollectStatus.pendingOrganize,
            questionId: 'import-1',
            sourcePath: 'imports/task-orig/original.jpg',
          ),
        ],
        boxesByQuestionId: {
          'import-1': [_box(id: 'draft-1', questionId: 'import-1')],
        },
      );
      final tasks = await AppDatabase.instance.allCollectTasks();
      expect(tasks.map((t) => t.id), ['task-split-1']);
      expect(await AppDatabase.boxesForTaskFrom(db, 'task-orig'), isEmpty);
    });
  });
}
