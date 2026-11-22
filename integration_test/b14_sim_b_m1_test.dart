// 十四批 Linux 模拟用户核验 · 模块 B：M1 区分题型（清单 #2–#6）。
//
// 驱动方式：testWidgets 驱动真实页面（整理页 / 详情页 / 错题本 /
// 学习报告）+ 真实内存库（AppDatabase.openForTest）+ 真实 OCR
// worker 路径（OcrWorker.processOne，识别器换成假实现按顺序返回
// 伪造的 GlmOcrResult，不调网络、不读 BigModel key）。
// 分类触发的两条真实路径都覆盖：worker 自动应用
//（applyClaimedResult）与接受候选（acceptCandidateStem）。
//
// 注意：pubspec 未引入 integration_test 包（且任务铁律不许改
// pubspec），本文件不用 IntegrationTestWidgetsFlutterBinding，
// 以 `flutter test b14_sim_b_m1_test.dart`（项目根目录临时副本，
// 见报告）跑；正式文件留在 integration_test/。
// 数据目录指到 ~/workspace/batch14-work/sim-tmp-b/ 下的全新子目录，
// 内存库 + 临时目录双重隔离，绝不动真实演示库。
// 播种在测试体内做（B9-3 同款教训：setUp 里开库再 await 会挂住）。
//
// testWidgets 异步铁律（本文件探针 probeA–F 实测，见
// ~/workspace/batch14-work/sim-tmp-b/run-probe*.log）：
// - 读/写库一律进 tester.runAsync：直接 await 经 AppDatabase.db
//   getter 的 Drift 读（如 repo.questionById）在 fake async 区里
//   挂住，runAsync 内正常；静态直连 db 的 customSelect /
//   allQuestionsFrom 直接 await 能过，但本文件统一走 runAsync。
// - 绝不直接 await AppDatabase.instance.db（runAsync 区里创建的
//   Future 在 fake 区 await 会让 body 结束后的 asyncBarrier 挂住，
//   tearDown 都进不去；probeF1 对照已证实）。需要 db 对象时用
//   _initDb 里保存的 _db 引用。
// - tearDown 先 tester.pump(1s) 再 resetForTest：关库要等 Drift
//   内部 Timer.run 回调，不推进 fake 时钟就永挂（probeE/F）。
// - 任何 runAsync 读/写库之前，若刚有 UI 操作（点保存/选型/重新识别
//   等），先 _settle(4 轮) 排空 fake 区进行中的 notifier 刷新：
//   否则 Drift 锁链跨 fake/real 两区死锁，runAsync 永挂
//   （run-m1-4a2.log：snack 出现后 _dbQuestion 挂住；run-m1-all2.log：
//   #4 测 3 的 acceptCandidateStem 块挂住）。
// - 详情页三段（答案解析 / 题目信息 / 复习记录）进入默认全部折叠，
//   题型 chip 在“题目信息”区内：等区头、点开、再等 chip。
// - 页面加载不用 pumpAndSettle：Notifier 的读库在 fake async 区
//   里不完成，改用 B9-3 同款有界 _pumpUntil（pump + runAsync 延时
//   交替，等到目标文案出现）。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/detail/question_detail_page.dart';
import 'package:quiz_master2/modules/ocr/stem_correction.dart';
import 'package:quiz_master2/modules/organize/organize_page.dart';
import 'package:quiz_master2/modules/report/report_page.dart';
import 'package:quiz_master2/modules/wrongbook/wrongbook_page.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';
import 'package:quiz_master2/services/ocr_key_store.dart';
import 'package:quiz_master2/services/ocr_queue.dart';
import 'package:quiz_master2/theme/app_theme.dart';

class _MemoryKeyBackend implements OcrKeyStorageBackend {
  final _map = <String, String>{};

  @override
  Future<String?> read(String key) async => _map[key];

  @override
  Future<void> write(String key, String value) async {
    _map[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _map.remove(key);
  }

  @override
  Future<bool> containsKey(String key) async => _map.containsKey(key);
}

/// 行为可编排的假识别器：按顺序返回伪造结果（b13 同款）。
class _FakeRecognizer implements OcrRecognizer {
  _FakeRecognizer(this._steps);

  final List<Object> _steps;
  var calls = 0;

  @override
  Future<GlmOcrResult> recognize(File cropFile) async {
    final step = _steps[calls < _steps.length ? calls : _steps.length - 1];
    calls++;
    if (step is OcrException) throw step;
    if (step is GlmOcrResult) return step;
    throw StateError('假识别器步骤类型错误：$step');
  }
}

GlmOcrResult _okResult(String markdown) => GlmOcrResult(
  markdown: markdown,
  rawData: GlmOcrRawData(
    mdResults: markdown,
    layoutDetails: const [
      {
        'bbox_2d': [0, 0, 100, 50],
        'label': 'text',
        'content': 'x',
        'index': 0,
      },
    ],
  ),
  totalTokens: 10,
);

const _choiceMd = '下列说法正确的是：\nA. 苹果\nB. 香蕉\nC. 橙子\nD. 葡萄';
const _calcMd = '求 2 + 3 × 4 的值。';
const _noSignalMd = '这是一段没有明显特征的文字。';
const _mixedMd =
    '阅读下列材料，回答下列问题：\n'
    '（1）请选择下列说法正确的是：\nA. 苹果\nB. 香蕉\n'
    '（2）请判断下列说法的正误，对的打√，错的打×：地球是圆的。\n'
    '（3）请简述牛顿第一定律的内容。';

int _runSeq = 0;
late Directory _runDir;
late QuizDatabase _db;
late QuestionRepository _repo;
late Directory _dataDir;
late _MemoryKeyBackend _keyBackend;

String _simTmp() => p.join(
  Platform.environment['HOME']!,
  'workspace',
  'batch14-work',
  'sim-tmp-b',
);

/// 有界手动 pump（B9-3 同款）：每轮先 pump 一帧看条件，再切回真实
/// 异步等一轮、再 pump 渲染，直到条件成立或超限失败。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  int maxRounds = 40,
}) async {
  for (var i = 0; i < maxRounds; i++) {
    await tester.pump();
    if (condition()) return;
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    if (condition()) return;
  }
  fail('界面未稳定：$reason');
}

/// 开内存库 + 数据目录指到 sim-tmp-b 全新子目录 + 三科 + 数学文件夹。
/// 必须在测试体内调（不能放 setUp）。
Future<void> _initDb(WidgetTester tester) async {
  await tester.runAsync(() async {
    _runSeq++;
    _runDir = Directory(p.join(_simTmp(), 'b14-sim-b-$_runSeq'));
    if (_runDir.existsSync()) _runDir.deleteSync(recursive: true);
    _runDir.createSync(recursive: true);
    AppDatabase.testDataDirectory = _runDir.path;
    _db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(_db);
    _repo = QuestionRepository(AppDatabase.instance);
    _dataDir = Directory(AppDatabase.dataDirectoryPath());
    _dataDir.createSync(recursive: true);
    _keyBackend = _MemoryKeyBackend();
    await OcrKeyStore(backend: _keyBackend).setApiKey('fake-test-key');
    OcrWorker.resetInstanceForTest();
    for (final s in Subject.all) {
      await _repo.saveSubject(s);
    }
    await _db
        .into(_db.folders)
        .insert(
          FoldersCompanion.insert(
            id: 'f1',
            name: '试卷',
            subjectId: 'math',
          ),
        );
  });
  addTearDown(() async {
    OcrWorker.resetInstanceForTest();
    // 先推进 fake 时钟再关库：Drift close 要等内部 Timer.run 回调，
    // 且关库前须把跨区挂起的微任务排空，否则 resetForTest 永挂。
    await tester.pump(const Duration(seconds: 1));
    await AppDatabase.resetForTest();
    try {
      _runDir.deleteSync(recursive: true);
    } catch (_) {}
  });
}

/// 写一张 100x50 切片到数据目录 slices/ 下，返回相对路径（同步 IO）。
String _writeSliceSync(String name, {int seed = 1}) {
  final image = img.Image(width: 100, height: 50);
  img.fill(image, color: img.ColorRgb8(10 + seed, 20, 30));
  final bytes = img.encodePng(image);
  final rel = 'slices/$name.png';
  final abs = p.join(_dataDir.path, rel);
  File(abs).parent.createSync(recursive: true);
  File(abs).writeAsBytesSync(bytes);
  return rel;
}

OcrWorker _workerWith(OcrRecognizer recognizer, {bool withKey = true}) =>
    OcrWorker(
      database: AppDatabase.instance,
      keyStore: OcrKeyStore(
        backend: withKey ? _keyBackend : _MemoryKeyBackend(),
      ),
      recognizer: recognizer,
      clock: DateTime.now,
    );

/// 种子一道题 + 假识别器走真实 worker 自动应用（入队 → processOne）。
Future<void> _seedAndClassify(
  WidgetTester tester, {
  required String id,
  required String title,
  required String md,
  bool isOrganized = false,
  List<String> errorTypes = const [],
  List<String> folderIds = const [],
  DateTime? createdAt,
  int sliceSeed = 1,
}) async {
  await tester.runAsync(() async {
    final slice = _writeSliceSync(id, seed: sliceSeed);
    final q = Question(
      id: id,
      title: title,
      subjectId: 'math',
      folderIds: folderIds,
      errorTypes: errorTypes,
      createdAt: createdAt ?? DateTime.now(),
      slicePath: slice,
      isOrganized: isOrganized,
    );
    await AppDatabase.upsertQuestionInto(_db, q);
    final worker = _workerWith(_FakeRecognizer([_okResult(md)]));
    final job = await worker.enqueueForQuestion(q);
    expect(job, isNotNull, reason: '入队失败：$id');
    expect(await worker.processOne(), isTrue, reason: 'worker 未处理：$id');
  });
}

/// 对已入库的题再跑一次假识别（新 md），走同一 worker 自动应用路径。
Future<void> _reclassify(
  WidgetTester tester,
  String id,
  String md, {
  bool withKey = true,
}) async {
  // 同 _dbQuestion：先排空 fake 区挂起的刷新，再进 runAsync。
  await _settle(tester, rounds: 10);
  await tester.runAsync(() async {
    final q = await _repo.questionById(id);
    expect(q, isNotNull);
    final worker = _workerWith(
      _FakeRecognizer([_okResult(md)]),
      withKey: withKey,
    );
    final job = await worker.enqueueForQuestion(q!);
    expect(job, isNotNull, reason: '重识别入队失败：$id');
    expect(await worker.processOne(), isTrue, reason: '重识别未处理：$id');
  });
}

/// 读库必须进 runAsync（见文件头铁律）。
/// 先 _settle 排空：UI 操作（保存草稿等）会触发 OrganizeNotifier.refresh()
/// 在 fake 区进行中，若直接进 runAsync 读库，Drift 锁链跨 fake/real
/// 两区死锁（run-m1-4a2.log：snack 出现后 _dbQuestion 永挂）。
Future<Question> _dbQuestion(WidgetTester tester, String id) async {
  await _settle(tester, rounds: 10);
  final q = await tester.runAsync(() => _repo.questionById(id));
  expect(q, isNotNull, reason: '库里找不到 $id');
  return q!;
}

void _setViewSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpOrganize(
  WidgetTester tester, {
  required Finder ready,
  required String readyReason,
}) async {
  _setViewSize(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: Scaffold(
        body: OrganizePage(
          key: UniqueKey(),
          repo: _repo,
          onOpenDetail: (_, __, {String? searchContext}) async {},
          onGoReview: () {},
          onGoCollect: () {},
        ),
      ),
    ),
  );
  await _pumpUntil(
    tester,
    () => ready.evaluate().isNotEmpty,
    reason: readyReason,
  );
}

Future<void> _pumpDetail(
  WidgetTester tester,
  String questionId,
  List<String> orderIds, {
  required Finder ready,
  required String readyReason,
}) async {
  _setViewSize(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: Scaffold(
        body: QuestionDetailPage(
          key: UniqueKey(),
          repo: _repo,
          questionId: questionId,
          orderIds: orderIds,
          sourceLabel: '错题本',
        ),
      ),
    ),
  );
  await _pumpUntil(
    tester,
    () => ready.evaluate().isNotEmpty,
    reason: readyReason,
  );
}

Future<void> _pumpWrongbook(WidgetTester tester) async {
  _setViewSize(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: Scaffold(
        body: WrongbookPage(
          key: UniqueKey(),
          repo: _repo,
          onOpenHome: () {},
          onOpenDetail: (_, __, {String? searchContext}) async {},
          onGoReview: ({String? subjectId}) {},
        ),
      ),
    ),
  );
  await _pumpUntil(
    tester,
    () => find.text('全部题目').evaluate().isNotEmpty,
    reason: '错题本 L1 列表未出现全部题目',
  );
}

Future<void> _openMathList(WidgetTester tester) async {
  // 十九批 L1：错题本默认落点就是列表（板子行，标题为 RichText），
  // 大卡片 / 紧凑行已去掉；种子全是数学题，列表即数学列表。
  await _pumpUntil(
    tester,
    () =>
        find
            .textContaining('单选示例题', findRichText: true)
            .evaluate()
            .isNotEmpty,
    reason: '错题本列表未出现题目',
  );
}

Future<void> _pumpReport(WidgetTester tester) async {
  _setViewSize(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: Scaffold(
        body: ReportPage(
          key: UniqueKey(),
          repo: _repo,
          onGoReview: () {},
          onOpenWrongbookFiltered:
              ({String? subjectId, String? cause, String? knowledgePointId}) {},
        ),
      ),
    ),
  );
  await _pumpUntil(
    tester,
    () => find.text('已解决错因').evaluate().isNotEmpty,
    reason: '学习报告核心数未出现',
  );
}

/// 有界 settle：pumpAndSettle 的替代品。pumpAndSettle 在本文件会永挂
///（见 run-m1-all1.log：#4 首测 300 秒超时；疑似有 widget 持续约帧，
/// 但未定位；本文件一律不用 pumpAndSettle）。
/// 每轮 pump + 真实 100ms 延时，最多 [rounds] 轮，到点即返回。
Future<void> _settle(WidgetTester tester, {int rounds = 20}) async {
  for (var i = 0; i < rounds; i++) {
    // pump 必须带时长：滚动/展开等动画走 fake 时钟，零时长 pump 不推进，
    // chip 会停在视口外（y=734/720）导致 tap 落空——见 run-m1-4group.log。
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 100)),
    );
  }
}

/// 收尾排空：在测试体结束前多 pump 几轮，让 DataChangeBus 触发的
/// OrganizeNotifier.refresh() 等挂起异步工作在 provider 仍挂载时
/// 跑完。否则 refresh() 在 await loadFolders() 之后无 _disposed 复查
/// 就调 loadForm()，页面已卸载时会抛 UnmountedRefException（未捕获
/// 异步异常，测试判失败；lib 侧缺口见模块报告）。
Future<void> _drain(WidgetTester tester) async {
  await _settle(tester, rounds: 8);
}

/// 整理页/详情页题型 chip → 选择器 → 点选 [label]。
/// 选完只改表单/立即保存的 state，不直接断言落盘（落盘另由调用方等）。
Future<void> _pickTypeFromChip(
  WidgetTester tester,
  String currentLabel,
  String label,
) async {
  await tester.ensureVisible(find.text(currentLabel).first);
  await _settle(tester);
  // 二次校正：第一次 ensureVisible 可能按折叠展开动画中的布局算滚动，
  // 动画走完后 chip 位置会变，再滚一次才落到视口内（详情页曾停在 y=734）。
  await tester.ensureVisible(find.text(currentLabel).first);
  await _settle(tester, rounds: 4);
  await tester.tap(find.text(currentLabel).first);
  await _settle(tester);
  expect(find.text('选择题型'), findsOneWidget);
  await tester.tap(find.text(label).last);
  await _settle(tester);
}

void main() {
  group('B-#2 自动定型 spot check（worker 自动应用 → 整理页 chip）', () {
    testWidgets('带 A–D 选项的单选题识别后自动变“单项选择”', (tester) async {
      await _initDb(tester);
      await _seedAndClassify(
        tester,
        id: 'q1',
        title: '单选示例题',
        md: _choiceMd,
      );
      final after = await _dbQuestion(tester, 'q1');
      expect(after.questionType, 'choice_single');
      expect(after.questionTypeSource, 'auto');
      await _pumpOrganize(
        tester,
        ready: find.text('单项选择'),
        readyReason: '整理页 chip 未显示单项选择',
      );
      // 题型行是 Text.rich（“题型 + 点芯片可改…”拼串），不用 find.text。
      expect(find.textContaining('题型'), findsOneWidget);
      expect(find.text('单项选择'), findsOneWidget);
      await _drain(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('纯计算题（求 + 公式）识别后自动变“计算题”', (tester) async {
      await _initDb(tester);
      await _seedAndClassify(
        tester,
        id: 'q1',
        title: '计算示例题',
        md: _calcMd,
      );
      final after = await _dbQuestion(tester, 'q1');
      expect(after.questionType, 'calculation');
      expect(after.questionTypeSource, 'auto');
      await _pumpOrganize(
        tester,
        ready: find.text('计算题'),
        readyReason: '整理页 chip 未显示计算题',
      );
      expect(find.text('计算题'), findsOneWidget);
      await _drain(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('无任何信号的题保持“待确认”，不硬猜', (tester) async {
      await _initDb(tester);
      await _seedAndClassify(
        tester,
        id: 'q1',
        title: '无信号示例题',
        md: _noSignalMd,
      );
      final after = await _dbQuestion(tester, 'q1');
      expect(after.questionType, isNull);
      expect(after.questionTypeSource, 'unclassified');
      await _pumpOrganize(
        tester,
        ready: find.text('待确认'),
        readyReason: '整理页 chip 未显示待确认',
      );
      expect(find.text('待确认'), findsOneWidget);
      await _drain(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('B-#3 材料混合小题记待确认', () {
    testWidgets('同一框单选 + 判断 + 简答 → 待确认 + 拆框提示 + 材料标签',
        (tester) async {
      await _initDb(tester);
      await _seedAndClassify(
        tester,
        id: 'q1',
        title: '材料混合示例题',
        md: _mixedMd,
      );
      final after = await _dbQuestion(tester, 'q1');
      expect(after.questionType, isNull);
      expect(after.questionTypeSource, 'unclassified');
      expect(after.questionBackgroundTags, '材料');
      await _pumpOrganize(
        tester,
        ready: find.text('本题含多种作答形式，请拆框或人工指定'),
        readyReason: '整理页拆框提示未出现',
      );
      expect(find.text('待确认'), findsOneWidget);
      expect(
        find.text('本题含多种作答形式，请拆框或人工指定'),
        findsOneWidget,
      );
      await _drain(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('拆框后各题重新判定：单选框 → 单项选择，简答框 → 简答题',
        (tester) async {
      await _initDb(tester);
      // 拆框模拟：混合题拆成两道独立题，各走一次 worker 自动应用。
      await _seedAndClassify(
        tester,
        id: 'q-split1',
        title: '拆出单选题',
        md: '请选择下列说法正确的是：\nA. 苹果\nB. 香蕉',
        sliceSeed: 11,
      );
      await _seedAndClassify(
        tester,
        id: 'q-split2',
        title: '拆出简答题',
        md: '请简述牛顿第一定律的内容。',
        sliceSeed: 12,
      );
      expect(
        (await _dbQuestion(tester, 'q-split1')).questionType,
        'choice_single',
      );
      expect(
        (await _dbQuestion(tester, 'q-split2')).questionType,
        'short_answer',
      );
      await _drain(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('B-#4 人工改题型后自动不覆盖', () {
    testWidgets('整理页把计算题改成简答题并保存草稿，重跑识别仍是简答题',
        (tester) async {
      await _initDb(tester);
      await _seedAndClassify(
        tester,
        id: 'q1',
        title: '计算示例题',
        md: _calcMd,
      );
      expect((await _dbQuestion(tester, 'q1')).questionType, 'calculation');
      await _pumpOrganize(
        tester,
        ready: find.text('计算题'),
        readyReason: '整理页 chip 未显示计算题',
      );
      await _pickTypeFromChip(tester, '计算题', '简答题');
      await tester.ensureVisible(find.text('保存草稿'));
      await _settle(tester);
      await tester.tap(find.text('保存草稿'));
      await _pumpUntil(
        tester,
        () => find.text('草稿已保存').evaluate().isNotEmpty,
        reason: '保存草稿后未出现“草稿已保存”',
      );
      final manual = await _dbQuestion(tester, 'q1');
      expect(manual.questionType, 'short_answer');
      expect(manual.questionTypeSource, 'manual');
      // 重跑识别：新结果是强单选信号，且题干确实被新结果更新了，
      // 但题型必须仍是人工改的简答题。
      await _reclassify(tester, 'q1', _choiceMd);
      final rerun = await _dbQuestion(tester, 'q1');
      expect(rerun.questionType, 'short_answer');
      expect(rerun.questionTypeSource, 'manual');
      expect(rerun.ocrStem, contains('下列说法正确的是'));
      // 回到整理页复核：chip 仍显示简答题。
      await _pumpOrganize(
        tester,
        ready: find.text('简答题'),
        readyReason: '重跑识别后整理页 chip 未显示简答题',
      );
      expect(find.text('简答题'), findsOneWidget);
      expect(find.text('计算题'), findsNothing);
      await _drain(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('详情页改题型后点重新识别（无 key）：优雅入队、worker 不应用、题型不变',
        (tester) async {
      await _initDb(tester);
      await _seedAndClassify(
        tester,
        id: 'q1',
        title: '计算示例题',
        md: _calcMd,
      );
      expect((await _dbQuestion(tester, 'q1')).questionType, 'calculation');
      // 十九批 D1：题目信息与复习记录 panel 默认展开（点标题会折叠），
      // 题型 chip 在“题目信息”区内，等区头出现后直接等 chip。
      await _pumpDetail(
        tester,
        'q1',
        ['q1'],
        ready: find.text('题目信息'),
        readyReason: '详情页未加载出题目信息区',
      );
      await _pumpUntil(
        tester,
        () => find.text('计算题').evaluate().isNotEmpty,
        reason: '题目信息区未出现计算题 chip',
      );
      await _pickTypeFromChip(tester, '计算题', '简答题');
      // 详情页查看态改题型立即保存：等 chip 变成简答题再断言落盘。
      await _pumpUntil(
        tester,
        () => find.text('简答题').evaluate().isNotEmpty,
        reason: '详情页改题型后 chip 未变成简答题',
      );
      final manual = await _dbQuestion(tester, 'q1');
      expect(manual.questionType, 'short_answer');
      expect(manual.questionTypeSource, 'manual');
      // 点详情页“重新识别”：切片存在，入队成功，弹“已重新识别，稍等片刻”。
      await tester.ensureVisible(find.text('重新识别'));
      await _settle(tester);
      await tester.tap(find.text('重新识别'));
      await _pumpUntil(
        tester,
        () => find.text('已重新识别，稍等片刻').evaluate().isNotEmpty,
        reason: '点重新识别后未出现“已重新识别，稍等片刻”',
      );
      // 无 key 的 worker 跑一次：只排队不发请求，任务回 pending，
      // 不记 attempt、不应用结果，题型纹丝不动。
      await _reclassify(tester, 'q1', _choiceMd, withKey: false);
      // 排空：worker 写库触发的详情页刷新可能在 fake 区进行中。
      await _settle(tester, rounds: 10);
      final jobs = await tester.runAsync(
        () => AppDatabase.instance.ocrJobsForQuestion('q1'),
      );
      expect(jobs, isNotEmpty);
      // ocrJobsForQuestion 按 createdAt DESC：最新任务在 first，
      // 不是 last（last 是种子任务，已 completed）。
      expect(jobs!.first.status, OcrJobStatus.pending);
      expect(jobs.first.attemptCount, 0);
      final kept = await _dbQuestion(tester, 'q1');
      expect(kept.questionType, 'short_answer');
      expect(kept.questionTypeSource, 'manual');
      await _drain(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('人工指定待确认后：重跑识别仍为待确认，接受候选仍为待确认',
        (tester) async {
      await _initDb(tester);
      await _seedAndClassify(
        tester,
        id: 'q1',
        title: '单选示例题',
        md: _choiceMd,
      );
      expect((await _dbQuestion(tester, 'q1')).questionType, 'choice_single');
      await _pumpOrganize(
        tester,
        ready: find.text('单项选择'),
        readyReason: '整理页 chip 未显示单项选择',
      );
      await _pickTypeFromChip(tester, '单项选择', '待确认');
      await tester.ensureVisible(find.text('保存草稿'));
      await _settle(tester);
      await tester.tap(find.text('保存草稿'));
      await _pumpUntil(
        tester,
        () => find.text('草稿已保存').evaluate().isNotEmpty,
        reason: '保存草稿后未出现“草稿已保存”',
      );
      final manual = await _dbQuestion(tester, 'q1');
      expect(manual.questionType, isNull);
      expect(manual.questionTypeSource, 'manual');
      // 触发点一：worker 重跑识别（强单选信号）仍不得自动分类。
      await _reclassify(tester, 'q1', _choiceMd);
      final rerun = await _dbQuestion(tester, 'q1');
      expect(rerun.questionType, isNull);
      expect(rerun.questionTypeSource, 'manual');
      // 触发点二：接受候选（acceptCandidateStem 同一事务内分类）
      // 同样不得覆盖人工待确认。
      // 注意：accept 里的 Drift 事务在整理页仍挂载时，于 runAsync 内
      // 恒挂（H1 探针：不挂页面时同一调用一次通过；挂页面时 10 轮排空
      // 也挂——疑似事务锁与页面刷新跨区死锁，见模块报告）。本步只验
      // 库层行为，与页面无关：先把页面卸掉再跑 accept，卸前先排空，
      // 避免 refresh 进行中卸载触发 UnmountedRefException。
      await _settle(tester, rounds: 10);
      await tester.pumpWidget(Container());
      await _settle(tester, rounds: 4);
      final accepted = await tester.runAsync(() async {
        final current = await _repo.questionById('q1');
        expect(current, isNotNull);
        final pendingRaw = GlmOcrRawData(
          mdResults: _choiceMd,
          candidateStatus: OcrCandidateStatus.pending,
        ).toJsonString();
        await _repo.save(current!.copyWith(ocrRaw: pendingRaw));
        final fresh = await _repo.questionById('q1');
        final out = await acceptCandidateStem(_repo, fresh!);
        return out;
      });
      expect(accepted, isNotNull);
      expect(accepted!.question.questionType, isNull);
      expect(accepted.question.questionTypeSource, 'manual');
      expect(accepted.question.ocrStem, contains('下列说法正确的是'));
      await _drain(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('B-#5 错题本题型筛选', () {
    testWidgets('单项选择只列单选、待确认只列未定型、全部恢复', (tester) async {
      await _initDb(tester);
      final now = DateTime.now();
      await _seedAndClassify(
        tester,
        id: 'q-single',
        title: '单选示例题',
        md: _choiceMd,
        isOrganized: true,
        errorTypes: const ['概念不清'],
        folderIds: const ['f1'],
        createdAt: now.subtract(const Duration(days: 1)),
        sliceSeed: 21,
      );
      await _seedAndClassify(
        tester,
        id: 'q-calc',
        title: '计算示例题',
        md: _calcMd,
        isOrganized: true,
        errorTypes: const ['计算错误'],
        folderIds: const ['f1'],
        createdAt: now.subtract(const Duration(days: 2)),
        sliceSeed: 22,
      );
      await _seedAndClassify(
        tester,
        id: 'q-unconf',
        title: '未定型示例题',
        md: _noSignalMd,
        isOrganized: true,
        errorTypes: const ['方法不会'],
        folderIds: const ['f1'],
        createdAt: now.subtract(const Duration(days: 3)),
        sliceSeed: 23,
      );
      expect(
        (await _dbQuestion(tester, 'q-single')).questionType,
        'choice_single',
      );
      expect(
        (await _dbQuestion(tester, 'q-calc')).questionType,
        'calculation',
      );
      expect((await _dbQuestion(tester, 'q-unconf')).questionType, isNull);
      await _pumpWrongbook(tester);
      await _openMathList(tester);
      // 板子行标题是 RichText，用 findRichText 找题名。
      expect(
        find.textContaining('单选示例题', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('计算示例题', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('未定型示例题', findRichText: true),
        findsOneWidget,
      );
      // 打开筛选面板：题型下拉是面板里最后一个 String 下拉。
      await tester.tap(find.text('筛选 ▾'));
      await _settle(tester);
      expect(find.text('题型'), findsOneWidget);
      Future<void> selectType(String label) async {
        await tester.tap(find.byType(DropdownButton<String>).last);
        await _settle(tester);
        await tester.tap(find.text(label).last);
        await _settle(tester);
      }

      await selectType('单项选择');
      expect(
        find.textContaining('单选示例题', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('计算示例题', findRichText: true),
        findsNothing,
      );
      expect(
        find.textContaining('未定型示例题', findRichText: true),
        findsNothing,
      );
      await selectType('待确认');
      expect(
        find.textContaining('单选示例题', findRichText: true),
        findsNothing,
      );
      expect(
        find.textContaining('计算示例题', findRichText: true),
        findsNothing,
      );
      expect(
        find.textContaining('未定型示例题', findRichText: true),
        findsOneWidget,
      );
      await selectType('全部');
      expect(
        find.textContaining('单选示例题', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('计算示例题', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('未定型示例题', findRichText: true),
        findsOneWidget,
      );
      await _drain(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('B-#6 题型不进报告', () {
    testWidgets('学习报告仍只答三个问题，没有题型维度', (tester) async {
      await _initDb(tester);
      final now = DateTime.now();
      final nowMs = now.millisecondsSinceEpoch;
      await tester.runAsync(() async {
        for (final entry in [
          ('q1', '单选示例题', 'choice_single'),
          ('q2', '计算示例题', 'calculation'),
        ]) {
          final slice = _writeSliceSync(entry.$1, seed: 31);
          await AppDatabase.upsertQuestionInto(
            _db,
            Question(
              id: entry.$1,
              title: entry.$2,
              subjectId: 'math',
              folderIds: const ['f1'],
              errorTypes: const ['概念不清'],
              createdAt: now,
              slicePath: slice,
              isOrganized: true,
              questionType: entry.$3,
              questionTypeSource: 'auto',
            ),
          );
        }
        await _db
            .into(_db.causeRecords)
            .insert(
              CauseRecordsCompanion.insert(
                questionId: 'q1',
                cause: '概念不清',
                subjectId: 'math',
                joinedAt: nowMs,
              ),
            );
        await _db
            .into(_db.causeRecords)
            .insert(
              CauseRecordsCompanion.insert(
                questionId: 'q2',
                cause: '计算错误',
                subjectId: 'math',
                joinedAt: nowMs,
              ),
            );
        await _db.customUpdate(
          'INSERT INTO review_history (question_id, result, reviewed_at) VALUES (?, ?, ?)',
          variables: [
            Variable.withString('q1'),
            Variable.withString('solved'),
            Variable.withInt(nowMs),
          ],
        );
        await _db.customUpdate(
          'INSERT INTO review_history (question_id, result, reviewed_at) VALUES (?, ?, ?)',
          variables: [
            Variable.withString('q2'),
            Variable.withString('unsolved'),
            Variable.withInt(nowMs),
          ],
        );
      });
      await _pumpReport(tester);
      expect(find.text('学习报告'), findsOneWidget);
      // 三个问题都在：核心数 + 接下来练什么。
      expect(find.text('已解决错因'), findsOneWidget);
      expect(find.text('待解决错因'), findsOneWidget);
      expect(find.text('复查通过率'), findsOneWidget);
      expect(find.text('接下来练什么'), findsOneWidget);
      // 没有任何题型维度：全文搜不到“题型”二字。
      expect(find.text('题型'), findsNothing);
      expect(find.textContaining('题型'), findsNothing);
      expect(find.textContaining('题型分布'), findsNothing);
      await _drain(tester);
      expect(tester.takeException(), isNull);
    });
  });
}
