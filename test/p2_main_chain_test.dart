// P2 主链（图片链）：导入复制 §1.4、修框三种作用域 §1.5、
// 确认拆题四步同事务 §1.5/§1.6、各页读图 §1.2(a)。
// 内存库 + 临时数据目录，不碰真实用户库；导入/裁剪是真实文件 IO，
// 用普通 test()（真实异步可用），只有 QuestionSlice 一组是 widget 测试。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/import_service.dart';
import 'package:quiz_master2/services/page_image_pipeline.dart';
import 'package:quiz_master2/widgets/widgets.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

late final Directory _tmp;

Future<Database> openMemoryDb() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, version) async => AppDatabase.createTables(db)));
  AppDatabase.useDatabaseForTest(db);
  addTearDown(() async => db.close());
  return db;
}

QuestionBox box({
  required String id,
  int layer = 1,
  String type = 'question',
  double x = 0.1,
  double y = 0.1,
  double w = 0.5,
  double h = 0.3,
  int page = 1,
  String? collectTaskId,
  String? questionId,
  String? parentBoxId,
}) =>
    QuestionBox(
      id: id,
      layer: layer,
      type: type,
      x: x,
      y: y,
      w: w,
      h: h,
      page: page,
      collectTaskId: collectTaskId,
      questionId: questionId,
      parentBoxId: parentBoxId,
    );

Question realQ({
  required String id,
  String? slicePath,
  String? sourcePath,
  bool isDemo = false,
}) =>
    Question(
      id: id,
      title: '题 $id',
      subjectId: 'math',
      isDemo: isDemo,
      createdAt: DateTime(2026, 11, 14),
      sliceText: '演示题干占位文字',
      sourcePath: sourcePath,
      sourceKind: sourcePath == null ? null : 'image',
      pageImagePath: sourcePath == null ? null : 'imports/t1/original.jpg',
      slicePath: slicePath,
      sliceWidth: slicePath == null ? null : 200,
      sliceHeight: slicePath == null ? null : 100,
    );

Future<String> makePng(Directory dir, String name) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 200, 100),
    ui.Paint()..color = const ui.Color(0xFFCC3333),
  );
  final img = await recorder.endRecording().toImage(200, 100);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(png!.buffer.asUint8List());
  return file.path;
}

void main() {
  setUpAll(() async {
    _tmp = await Directory.systemTemp.createTemp('qm2-p2-chain');
    AppDatabase.testDataDirectory = _tmp.path;
    // 切片 PNG 在 setUpAll（真实 zone）里生成：testWidgets 体内调
    // dart:ui 的 toImage/toByteData 会在 fake zone 里等不到完成而挂起。
    final slicesDir = Directory('${_tmp.path}/slices')
      ..createSync(recursive: true);
    await makePng(slicesDir, 'q1.png');
  });

  tearDownAll(() async {
    AppDatabase.testDataDirectory = null;
    await _tmp.delete(recursive: true);
  });

  group('C 导入复制 §1.4', () {
    test('图片导入：复制进 imports/，source_path 是相对路径，进度走到 100', () async {
      await openMemoryDb();
      final service = ImportService(AppDatabase.instance);
      final src = File('test/fixtures/photo.jpg');
      final progress = <int>[];
      final tasks = await service.enqueue(
        [src.path],
        subjectId: 'math',
        onProgress: (_, p) => progress.add(p),
      );
      expect(tasks.length, 1);
      final t = tasks.first;
      expect(t.status, CollectStatus.needBox);
      expect(t.progress, 100);
      expect(t.sourcePath, startsWith('imports/${t.id}/original.'));
      expect(t.sourcePath, isNot(contains('/tmp')));
      final copied = File(AppDatabase.resolveDataPath(t.sourcePath)!);
      expect(copied.existsSync(), isTrue);
      expect(copied.readAsBytesSync(), src.readAsBytesSync());
      expect(progress, isNotEmpty);
      expect(progress.last, 100);
    });

    test('PDF 导入：损坏的 PDF（只有文件头）显式失败，不留任务目录', () async {
      await openMemoryDb();
      final service = ImportService(AppDatabase.instance);
      final pdf = File('${_tmp.path}/x.pdf');
      await pdf.writeAsBytes([0x25, 0x50, 0x44, 0x46]);
      final tasks = await service.enqueue([pdf.path], subjectId: 'math');
      expect(tasks.first.status, CollectStatus.failed);
      expect(tasks.first.error, startsWith('文件损坏：'));
      expect(tasks.first.sourcePath, isEmpty);
      expect(
        Directory(AppDatabase.resolveDataPath(
                ImportService.taskDirRelative(tasks.first.id))!)
            .existsSync(),
        isFalse,
      );
    });

    test('EXIF 方向 6：生成 page-normalized.png 副本', () async {
      await openMemoryDb();
      final service = ImportService(AppDatabase.instance);
      final tasks = await service.enqueue(
        ['test/fixtures/exif-orientation-6.jpg'],
        subjectId: 'math',
      );
      final t = tasks.first;
      expect(t.status, CollectStatus.needBox);
      final norm = File(AppDatabase.resolveDataPath(
          ImportService.normalizedPageRelative(t.id))!);
      expect(norm.existsSync(), isTrue);
    });

    test('EXIF 方向 1 的照片：不生成归一化副本', () async {
      await openMemoryDb();
      final service = ImportService(AppDatabase.instance);
      final tasks = await service.enqueue(
        ['test/fixtures/photo.jpg'],
        subjectId: 'math',
      );
      final t = tasks.first;
      expect(t.status, CollectStatus.needBox);
      final norm = File(AppDatabase.resolveDataPath(
          ImportService.normalizedPageRelative(t.id))!);
      expect(norm.existsSync(), isFalse);
    });

    test('EXIF 镜像方向 2：显式失败，提示镜像方向，导入目录已删', () async {
      await openMemoryDb();
      // 把方向 6 的 fixture 改成方向 2：大端 TIFF，orientation
      // tag 在偏移 40，值 SHORT 在偏移 48..49（00 06 → 00 02）。
      final bytes = await File('test/fixtures/exif-orientation-6.jpg')
          .readAsBytes();
      expect(readJpegExifOrientation(bytes), 6);
      final patched = Uint8List.fromList(bytes);
      patched[48] = 0x00;
      patched[49] = 0x02;
      expect(readJpegExifOrientation(patched), 2);
      final mirror = File('${_tmp.path}/mirror.jpg');
      await mirror.writeAsBytes(patched);
      final service = ImportService(AppDatabase.instance);
      final tasks = await service.enqueue([mirror.path], subjectId: 'math');
      final t = tasks.first;
      expect(t.status, CollectStatus.failed);
      expect(t.error, contains('镜像方向（EXIF 2）'));
      expect(
        Directory(AppDatabase.resolveDataPath(
                ImportService.taskDirRelative(t.id))!)
            .existsSync(),
        isFalse,
      );
    });
  });

  group('D §1.5 三种作用域', () {
    test('草稿作用域：按任务+页替换，含 2 层子框与按页旋转往返', () async {
      final db = await openMemoryDb();
      await AppDatabase.instance.upsertCollectTask(CollectTask(
        id: 'task-1',
        name: 't',
        fileName: 't.jpg',
        subjectId: 'math',
      ));
      final first = box(id: 'b1', collectTaskId: 'task-1');
      final inner = box(
        id: 'b1-stem',
        layer: 2,
        type: 'stem',
        x: 0.12,
        y: 0.12,
        w: 0.2,
        h: 0.1,
        collectTaskId: 'task-1',
        parentBoxId: 'b1',
      );
      await AppDatabase.saveDraftBoxesInto(
        db,
        taskId: 'task-1',
        boxesByPage: {
          1: [first],
        },
        inners: {
          '1:b1': [inner],
        },
        standaloneInner: const {},
        rotations: const {1: 90},
      );
      var back = await AppDatabase.boxesForTaskPageFrom(db, 'task-1', 1);
      expect(back.map((b) => b.id), containsAll(['b1', 'b1-stem']));
      // 重检测按页替换：再存一次，本页旧框被删干净，不追加。
      final second = box(id: 'b2', x: 0.2, collectTaskId: 'task-1');
      await AppDatabase.saveDraftBoxesInto(
        db,
        taskId: 'task-1',
        boxesByPage: {
          1: [second],
        },
        inners: const {},
        standaloneInner: const {},
        rotations: const {1: 0},
      );
      back = await AppDatabase.boxesForTaskPageFrom(db, 'task-1', 1);
      expect(back.map((b) => b.id), ['b2']);
      // 旋转角度跟着草稿一起写进 collect_tasks.page_rotations。
      final row = (await db.query('collect_tasks',
          where: 'id = ?', whereArgs: ['task-1'])).first;
      expect(row['page_rotations'], '{"1":0}');
    });

    test('多题页面重框：只换目标题，同页他题的框与切片不动', () async {
      final db = await openMemoryDb();
      const pageImage = 'imports/t1/original.jpg';
      final q1 = realQ(id: 'q1', slicePath: 'slices/q1.png',
          sourcePath: 'imports/t1/original.jpg');
      final q2 = realQ(id: 'q2', slicePath: 'slices/q2.png',
          sourcePath: 'imports/t1/original.jpg');
      // 两题同页：pageImagePath 相同（重框分组键）。
      final q1b = q1.copyWith(pageImagePath: pageImage);
      final q2b = q2.copyWith(pageImagePath: pageImage);
      await AppDatabase.instance.upsertQuestion(q1b);
      await AppDatabase.instance.upsertQuestion(q2b);
      await AppDatabase.replaceQuestionBoxesInto(db, 'q1', [
        box(id: 'q1-box', questionId: 'q1'),
        box(id: 'q1-stem', layer: 2, type: 'stem', questionId: 'q1',
            parentBoxId: 'q1-box'),
      ]);
      await AppDatabase.replaceQuestionBoxesInto(db, 'q2', [
        box(id: 'q2-box', x: 0.6, questionId: 'q2'),
      ]);
      var all = await AppDatabase.boxesForPageImageFrom(db, pageImage);
      expect(all.map((b) => b.id),
          containsAll(['q1-box', 'q1-stem', 'q2-box']));
      // 重框 q1：只动 q1 的框。
      await AppDatabase.replaceQuestionBoxesInto(db, 'q1', [
        box(id: 'q1-box-new', x: 0.05, y: 0.05, w: 0.7, h: 0.4,
            questionId: 'q1'),
      ]);
      all = await AppDatabase.boxesForPageImageFrom(db, pageImage);
      // 行顺序不保证，只断言集合（q1 的旧框已删、q2 的框原样）。
      expect(all.map((b) => b.id).toSet(), {'q2-box', 'q1-box-new'});
      expect(all.firstWhere((b) => b.id == 'q2-box').x, 0.6);
    });

    test('确认拆题四步同事务：建题 + 回填框 + 建拆分任务 + 删原任务', () async {
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
          1: [box(id: 'draft-1', collectTaskId: 'task-orig')],
        },
        inners: const {},
        standaloneInner: const {},
        rotations: const {},
      );
      final questions = [
        realQ(id: 'import-1', slicePath: 'slices/import-1.png',
            sourcePath: 'imports/task-orig/original.jpg'),
      ];
      final splitTasks = [
        CollectTask(
          id: 'task-split-1',
          name: 'orig.jpg · 第1页 · 第1题',
          fileName: 'orig.jpg',
          subjectId: 'math',
          status: CollectStatus.pendingOrganize,
          questionId: 'import-1',
        ),
      ];
      await AppDatabase.confirmSplitInto(
        db,
        originalTask: orig,
        questions: questions,
        splitTasks: splitTasks,
        boxesByQuestionId: {
          'import-1': [box(id: 'draft-1', questionId: 'import-1')],
        },
      );
      expect(
        (await AppDatabase.instance.questionById('import-1'))?.slicePath,
        'slices/import-1.png',
      );
      final boxes =
          await AppDatabase.boxesForPageImageFrom(db, 'imports/t1/original.jpg');
      expect(boxes.map((b) => b.questionId), ['import-1']);
      final tasks = await AppDatabase.instance.allCollectTasks();
      expect(tasks.map((t) => t.id), ['task-split-1']);
      expect(tasks.first.status, CollectStatus.pendingOrganize);
      // 原任务的残留草稿框一起被删。
      expect(
        await AppDatabase.boxesForTaskFrom(db, 'task-orig'), isEmpty);
    });
  });

  group('F 各页读图 §1.2(a)', () {
    testWidgets('真实切片存在：显示真图', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuestionSlice(
              question: realQ(id: 'q1', slicePath: 'slices/q1.png',
                  sourcePath: 'imports/t1/original.jpg'),
            ),
          ),
        ),
      );
      // 只 pump 一次：Image.file 的真实解码在 fake zone 里等不到完成，
      // pumpAndSettle 会挂起；widget 结构一次 pump 就已建成。
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(find.textContaining('图片缺失'), findsNothing);
    });

    testWidgets('真实题缺图：显示“图片缺失，可重新导入/重新框选”', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuestionSlice(
              question: realQ(id: 'q1', slicePath: 'slices/gone.png',
                  sourcePath: 'imports/t1/original.jpg'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('图片缺失，可重新导入/重新框选'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('真实题有来源无切片：同样显示图片缺失', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuestionSlice(
              question: realQ(id: 'q1',
                  sourcePath: 'imports/t1/original.jpg'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('图片缺失，可重新导入/重新框选'), findsOneWidget);
    });

    testWidgets('演示题/老题：仍走 sliceText 占位，不报缺图', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuestionSlice(question: realQ(id: 'q1', isDemo: true)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('演示题干占位文字'), findsOneWidget);
      expect(find.textContaining('图片缺失'), findsNothing);
    });

    testWidgets('CompactSliceThumb：有图显示图，缺图显示“图片缺失”', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                CompactSliceThumb(
                  question: realQ(id: 'q1', slicePath: 'slices/q1.png',
                      sourcePath: 'imports/t1/original.jpg'),
                ),
                CompactSliceThumb(
                  question: realQ(id: 'q2', slicePath: 'slices/gone.png',
                      sourcePath: 'imports/t1/original.jpg'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('图片缺失'), findsOneWidget);
    });
  });
}
