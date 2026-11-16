// B11-1 + B11-2：拖放导入与批量导入 widget 测试。
//
// 拖放用 desktop_drop 的 `desktop_drop` 通道模拟（entered /
// performOperation，与真机上插件发来的调用同格式）；导入走真实
// ImportService + 内存库 + 临时数据目录，不碰真实库。
// FakeRepo 只覆盖 repository 读调用；写库走 AppDatabase 单例（测试库）。
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/collect/collect_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';

import 'test_fixtures.dart';

class _FakeRepo extends QuestionRepository {
  _FakeRepo(this.tasks) : super(AppDatabase.instance);

  List<CollectTask> tasks;

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<List<CollectTask>> collectTasks() async => List.of(tasks);

  @override
  Future<List<QuestionBox>> boxesForTask(String taskId) async => [];

  @override
  Future<void> saveCollectTask(CollectTask t) async {
    final i = tasks.indexWhere((x) => x.id == t.id);
    if (i >= 0) {
      tasks[i] = t;
    } else {
      tasks.add(t);
    }
  }

  @override
  Future<void> deleteCollectTask(String id) async {
    tasks.removeWhere((x) => x.id == id);
  }

  @override
  Future<void> saveRecentTask({
    required String kind,
    required String subjectId,
    required String title,
  }) async {}
}

Future<void> _pumpCollect(WidgetTester tester, {_FakeRepo? repo}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      home: Scaffold(
        body: CollectPage(repo: repo ?? _FakeRepo([]), onOpenOrganize: () {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 模拟 desktop_drop 插件发来的通道调用（与真机同格式）。
Future<void> _sendDrop(String method, Object args) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        'desktop_drop',
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );
}

Future<void> _dropFiles(
  WidgetTester tester,
  List<String> paths, {
  Future<bool> Function()? until,
}) async {
  final center = tester.getCenter(find.byKey(const Key('collect-drop')));
  // 关键（probe3）：拖放回调里的导入订阅文件流——订阅必须发生在
  // 真实异步区里；在 fake 区订阅了再进 runAsync 也读不到。
  // 所以 entered + performOperation 都在 runAsync 内发，再在同一
  // 个 runAsync 里等调用方给的完成条件，最后回 fake 区刷新。
  await tester.runAsync(() async {
    await _sendDrop('entered', [center.dx, center.dy]);
    await _sendDrop('performOperation', paths);
    if (until != null) {
      for (var i = 0; i < 400; i++) {
        if (await until()) return;
        await Future.delayed(const Duration(milliseconds: 25));
      }
    } else {
      await Future.delayed(const Duration(milliseconds: 1000));
    }
  });
  await tester.pumpAndSettle();
}

/// 库里收集任务数（sqflite ffi 的查询包进 runAsync，与上面同理）。
Future<int> _dbTaskCount(WidgetTester tester) async {
  final count = await tester.runAsync(() async {
    final repo = QuestionRepository(AppDatabase.instance);
    return (await repo.collectTasks()).length;
  });
  return count!;
}

/// 库里全部收集任务（包进 runAsync，与上面同理）。
Future<List<CollectTask>> _dbTasks(WidgetTester tester) async {
  final tasks = await tester.runAsync(
    () => QuestionRepository(AppDatabase.instance).collectTasks(),
  );
  return tasks!;
}

void main() {
  late final Directory tmp;
  late final String goodMathPhoto; // 数学错题.jpg：真实照片（单张测试用）
  late final String batchGoodPhoto; // 数学期中.jpg：方向 3 照片（批量测试用）
  late final String corruptMathPhoto; // 数学作业.jpg：随机字节，解不开
  late final String unguessablePhoto; // photo123.jpg：方向 6 照片，猜不出学科
  late final String txtFile; // notes.txt：不支持的类型

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('qm2-b11-dragdrop');
    AppDatabase.testDataDirectory = tmp.path;
    final db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(db);
    goodMathPhoto = (await writeFixtureFile(
      tmp,
      '数学错题.jpg',
      photoFixtureBytes(),
    )).path;
    // B11-2：同一文件内测试共用内存库，内容去重会跨测试生效——
    // 每个测试用不同内容的照片固件，避免互相判重复。
    batchGoodPhoto = (await writeFixtureFile(
      tmp,
      '数学期中.jpg',
      exifFixtureBytes(3),
    )).path;
    corruptMathPhoto = (await writeFixtureFile(
      tmp,
      '数学作业.jpg',
      Uint8List.fromList(List<int>.generate(64, (i) => (i * 7 + 3) % 256)),
    )).path;
    unguessablePhoto = (await writeFixtureFile(
      tmp,
      'photo123.jpg',
      exifFixtureBytes(6),
    )).path;
    txtFile = (await writeFixtureFile(
      tmp,
      'notes.txt',
      Uint8List.fromList([104, 105]),
    )).path;
  });

  tearDownAll(() async {
    await AppDatabase.resetForTest();
    await tmp.delete(recursive: true);
  });

  testWidgets('落点是 DropTarget，占位文案已去掉', (tester) async {
    await _pumpCollect(tester);
    expect(find.byType(DropTarget), findsOneWidget);
    expect(find.text('拖放导入还没接好，先点「选择文件」导入'), findsNothing);
    expect(find.text('把文件拖到这里，或点击选择'), findsOneWidget);
  });

  testWidgets('悬停落点标题变“松开就导入”，移开恢复', (tester) async {
    await _pumpCollect(tester);
    final center = tester.getCenter(find.byKey(const Key('collect-drop')));
    await _sendDrop('entered', [center.dx, center.dy]);
    await tester.pump();
    expect(find.text('松开就导入'), findsOneWidget);
    await _sendDrop('exited', [center.dx, center.dy]);
    await tester.pump();
    expect(find.text('把文件拖到这里，或点击选择'), findsOneWidget);
  });

  testWidgets('拖入单张“数学错题.jpg”：猜学科预填数学，直接导入', (tester) async {
    final before = await _dbTaskCount(tester);
    await _pumpCollect(tester);
    await _dropFiles(
      tester,
      [goodMathPhoto],
      // 等终态再返回：任务行是先建 importing 行再处理，只数行数会早退。
      until: () async {
        final repo = QuestionRepository(AppDatabase.instance);
        final tasks = await repo.collectTasks();
        return tasks.any(
          (t) =>
              t.fileName == '数学错题.jpg' &&
              t.status != CollectStatus.importing,
        );
      },
    );
    // 猜测提示只建议、不强制：文案在，下拉可改。
    expect(find.text('按文件名猜是「数学」，不对可以改'), findsOneWidget);
    // 单文件不建批量队列。
    expect(find.byKey(const Key('batch-import-card')), findsNothing);
    // 真实导入完成：库里多一个待框选任务。
    expect(await _dbTaskCount(tester), before + 1);
    final tasks = await _dbTasks(tester);
    final task = tasks.firstWhere((t) => t.fileName == '数学错题.jpg');
    expect(task.status, CollectStatus.needBox);
    expect(task.subjectId, 'math');
  });

  testWidgets('拖入猜不出学科的文件：暂存，选好学科点“开始导入”才导', (tester) async {
    final before = await _dbTaskCount(tester);
    await _pumpCollect(tester);
    await _dropFiles(tester, [unguessablePhoto]);
    // 没猜出学科：文件暂存，不直接导入。
    expect(find.byKey(const Key('staged-import-card')), findsOneWidget);
    expect(find.textContaining('已选 1 个文件，等选学科'), findsOneWidget);
    expect(await _dbTaskCount(tester), before);
    // 手动选数学，再点“开始导入”（点按也要在 runAsync 内：它触发的
    // 导入同样订阅文件流，见 _dropFiles 的 probe3 注释）。
    await tester.tap(find.byKey(const Key('collect-subject-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('数学'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('staged-import-start')));
      for (var i = 0; i < 400; i++) {
        final repo = QuestionRepository(AppDatabase.instance);
        final tasks = await repo.collectTasks();
        if (tasks.any(
          (t) =>
              t.fileName == 'photo123.jpg' &&
              t.status != CollectStatus.importing,
        )) {
          return;
        }
        await Future.delayed(const Duration(milliseconds: 25));
      }
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('staged-import-card')), findsNothing);
    expect(await _dbTaskCount(tester), before + 1);
  });

  testWidgets('一次拖两张（同猜数学）：批量队列逐个导，失败行可重试', (tester) async {
    final before = await _dbTaskCount(tester);
    await _pumpCollect(tester);
    await _dropFiles(
      tester,
      [batchGoodPhoto, corruptMathPhoto],
      // 等两行都到终态再返回（同上，只数行数会在 importing 行上早退）。
      until: () async {
        final repo = QuestionRepository(AppDatabase.instance);
        final tasks = await repo.collectTasks();
        final good = tasks.any(
          (t) =>
              t.fileName == '数学期中.jpg' &&
              t.status != CollectStatus.importing,
        );
        final bad = tasks.any(
          (t) =>
              t.fileName == '数学作业.jpg' &&
              t.status != CollectStatus.importing,
        );
        return good && bad;
      },
    );
    // 批量卡片：1 完成 1 失败；建议试卷名只显示在行上。
    expect(find.byKey(const Key('batch-import-card')), findsOneWidget);
    expect(find.text('批量导入 · 已完成 1 / 2 · 1 个失败'), findsOneWidget);
    expect(find.text('数学期中.jpg'), findsOneWidget);
    expect(find.byKey(const Key('batch-retry-1')), findsOneWidget);
    expect(find.byKey(const Key('batch-retry-all')), findsOneWidget);
    // 库里：好文件待框选 + 坏文件失败任务；好文件不受坏文件影响。
    expect(await _dbTaskCount(tester), before + 2);
    final tasks = await _dbTasks(tester);
    expect(
      tasks.where((t) => t.fileName == '数学期中.jpg').single.status,
      CollectStatus.needBox,
    );
    expect(
      tasks.where((t) => t.fileName == '数学作业.jpg').single.status,
      CollectStatus.failed,
    );
    // 重试失败项：坏文件仍失败，队列状态不变，不多建成功任务。
    // 点按在 runAsync 内（同上：重试触发的导入订阅文件流）。
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('batch-retry-all')));
      for (var i = 0; i < 400; i++) {
        final repo = QuestionRepository(AppDatabase.instance);
        final tasks = await repo.collectTasks();
        // 重试又建一个“数学作业.jpg”任务：等两个同名任务都到终态。
        final bad = tasks.where((t) => t.fileName == '数学作业.jpg');
        if (bad.length == 2 &&
            bad.every((t) => t.status != CollectStatus.importing)) {
          return;
        }
        await Future.delayed(const Duration(milliseconds: 25));
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('批量导入 · 已完成 1 / 2 · 1 个失败'), findsOneWidget);
    expect(await _dbTaskCount(tester), before + 3);
  });

  testWidgets('拖入不支持的文件类型：跳过并提示，不建任务', (tester) async {
    final before = await _dbTaskCount(tester);
    await _pumpCollect(tester);
    await _dropFiles(tester, [txtFile]);
    expect(find.textContaining('只收 PDF / JPG / PNG'), findsOneWidget);
    expect(await _dbTaskCount(tester), before);
  });

  testWidgets('拖入文件夹：跳过并提示，不建任务', (tester) async {
    final before = await _dbTaskCount(tester);
    await _pumpCollect(tester);
    await _dropFiles(tester, [tmp.path]);
    expect(find.textContaining('只收 PDF / JPG / PNG'), findsOneWidget);
    expect(find.textContaining('1 个文件夹'), findsOneWidget);
    expect(await _dbTaskCount(tester), before);
  });
}
