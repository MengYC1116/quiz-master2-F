// R7 题目详情 widget 测试：十九批 D1 相关侧栏式（两栏、返回行带上下文、
// 标题行星标/归档/删除、题目信息与复习记录默认展开、答案默认隐藏）、
// 看答案、待补充进编辑、编辑保存/取消内联确认、收藏/归档/删除
//（模态弹窗确认，删后进下一题）、上一题/下一题顺序、加入/取消加入复习、
// 未整理题无加入按钮、无「开始复习」、图加载失败占位、亮/深 × 三档无溢出、
// 不用图标字体。用 FakeRepo 覆盖 repository 调用（不碰真实数据库）。
// P2 §1.5.1：重新框选入口（同页他题只读、确认重裁切片）——页图是
// setUpAll 生成的真实 560×700 PNG，切片写盘走 testDataDirectory。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/detail/question_detail_page.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';
import 'package:quiz_master2/state/detail_notifier.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';
import 'package:quiz_master2/widgets/widgets.dart';

late final Directory _testTmp;

/// B3-P01：页图放进 testDataDirectory，pageImagePath 用相对路径
///（resolveDataPath 已拒绝绝对路径）。
late final String _pagePngRel;

Question dtq(
  String id,
  String title, {
  String subjectId = 'math',
  String sliceKind = 'limit',
  String sliceText = '题：求极限',
  List<String> folderIds = const [],
  String? examId,
  List<String> knowledgePointIds = const [],
  List<String> errorTypes = const [],
  List<String> tags = const [],
  String? answer,
  String? explanation,
  String? notes,
  DateTime? createdAt,
  bool isOrganized = true,
  bool isArchived = false,
  bool isFavorite = false,
  bool reviewJoined = false,
  String? sourcePath,
  String? pageImagePath,
  String? slicePath,
  int? sliceWidth,
  int? sliceHeight,
  int? sourcePage,
  String? questionType,
  List<String>? optionLabels,
  String? correctOption,
  String? ocrRaw,
}) => Question(
  id: id,
  title: title,
  subjectId: subjectId,
  folderIds: folderIds,
  examId: examId,
  knowledgePointIds: knowledgePointIds,
  errorTypes: errorTypes,
  tags: tags,
  answer: answer,
  explanation: explanation,
  notes: notes,
  createdAt: createdAt ?? DateTime.now().subtract(const Duration(days: 2)),
  isOrganized: isOrganized,
  isArchived: isArchived,
  isFavorite: isFavorite,
  reviewJoined: reviewJoined,
  sliceKind: sliceKind,
  sliceText: sliceText,
  sourcePath: sourcePath,
  sourceKind: sourcePath == null ? null : 'image',
  pageImagePath: pageImagePath,
  slicePath: slicePath,
  sliceWidth: sliceWidth,
  sliceHeight: sliceHeight,
  sourcePage: sourcePage,
  questionType: questionType,
  optionLabels: optionLabels,
  correctOption: correctOption,
  ocrRaw: ocrRaw,
);

class FakeDetailRepo extends QuestionRepository {
  FakeDetailRepo({
    required List<Question> questions,
    List<Folder> folderList = const [],
    List<Exam> examList = const [],
    List<KnowledgePoint> kpList = const [],
    List<String> tagList = const [],
    List<CauseRecord> records = const [],
    List<({String result, DateTime reviewedAt})> history = const [],
    List<Subject>? subjectsValue,
    // FR-09：复查间隔桩（默认 7 天）；`load()` 读它拼“满 N 天”文案。
    AppSettings? settingsValue,
    // FSRS 口径迁移（面 B）：`load()` 经 _refreshReviewStatus 读
    // 全部 attempts 与池 id；不覆写会落到基类读真实库（D-88 同款）。
    List<AttemptData> attemptsValue = const [],
    Set<String> poolIdsValue = const {},
  }) : questions = List.of(questions),
       folderList = List.of(folderList),
       examList = List.of(examList),
       kpList = List.of(kpList),
       tagList = List.of(tagList),
       records = List.of(records),
       history = List.of(history),
       subjectsValue = subjectsValue ?? Subject.all,
       settingsValue = settingsValue ?? AppSettings.defaults,
       attemptsValue = List.of(attemptsValue),
       poolIdsValue = Set.of(poolIdsValue),
       super(AppDatabase.instance);

  List<Question> questions;
  List<Folder> folderList;
  List<Exam> examList;
  List<KnowledgePoint> kpList;
  List<String> tagList;
  List<CauseRecord> records;
  List<({String result, DateTime reviewedAt})> history;
  List<Subject> subjectsValue;

  /// FR-09：复查间隔桩（默认 7 天）。
  AppSettings settingsValue;

  /// FSRS 口径迁移（面 B）：全部 attempts 与池 id 桩。
  List<AttemptData> attemptsValue;
  Set<String> poolIdsValue;

  @override
  Future<List<AttemptData>> loadAllAttempts() async =>
      List.of(attemptsValue);

  @override
  Future<Set<String>> fsrsPoolQuestionIds() async => Set.of(poolIdsValue);

  @override
  Future<AppSettings> settings() async => settingsValue;

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);

  final List<Question> saved = [];
  final List<String> deletedIds = [];

  @override
  Future<Question?> questionById(String id) async =>
      questions.where((q) => q.id == id).firstOrNull;

  @override
  Future<List<CauseRecord>> causeRecordsFor(String questionId) async =>
      records.where((r) => r.questionId == questionId).toList();

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
    String questionId,
  ) async => List.of(history);

  @override
  Future<List<Folder>> folders({String? subjectId}) async => subjectId == null
      ? List.of(folderList)
      : folderList.where((f) => f.subjectId == subjectId).toList();

  @override
  Future<List<Exam>> exams() async => List.of(examList);

  @override
  Future<List<String>> tags() async => List.of(tagList);

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => List.of(kpList);

  @override
  Future<void> save(Question question, {SaveToken? token}) async {
    saved.add(question);
    final i = questions.indexWhere((x) => x.id == question.id);
    if (i >= 0) {
      questions[i] = question;
    } else {
      questions.add(question);
    }
  }

  /// 十二批功能 4（D-91）：记一次查看的桩（不碰真实库；不覆盖会落到
  /// 基类读真实 Drift 库，fake async 里永不完成，见 D-88）。
  @override
  Future<void> recordQuestionViewed(String questionId) async {}

  /// 十三批 M5：OCR 状态是 best-effort 加载（不 await）；返回空任务行
  /// 与“无 key”，不碰真实库（见 D-88）。
  @override
  Future<List<OcrJob>> ocrJobsForQuestion(String questionId) async =>
      const [];

  @override
  Future<bool> hasOcrApiKey() async => false;

  @override
  Future<void> syncCauseRecords(Question q) async {}

  @override
  Future<void> toggleFavorite(Question q) async {
    await save(q.copyWith(isFavorite: !q.isFavorite));
  }

  @override
  Future<void> archive(Question q, {bool archived = true}) async {
    await save(q.copyWith(isArchived: archived));
  }

  @override
  Future<void> delete(Question question) async {
    deletedIds.add(question.id);
    questions.removeWhere((x) => x.id == question.id);
  }

  @override
  Future<bool> setReviewJoined(Question q, bool joined) async {
    if (joined && q.allCauses.isEmpty) return false;
    await save(q.copyWith(reviewJoined: joined));
    return true;
  }

  @override
  Future<void> addTag(String name) async {
    if (!tagList.contains(name)) tagList.add(name);
  }

  @override
  Future<void> saveFolder(Folder folder) async {
    final i = folderList.indexWhere((x) => x.id == folder.id);
    if (i >= 0) {
      folderList[i] = folder;
    } else {
      folderList.add(folder);
    }
  }

  /// SR-P2-36：整科同名预检的内存版（与 upsertFolder 的把关同语义：
  /// 同一学科、同名、id 不是 excludeId 即命中）。
  @override
  Future<bool> folderNameExistsInSubject(
    String subjectId,
    String name, {
    String? excludeId,
  }) async => folderList.any(
    (f) => f.subjectId == subjectId && f.name == name && f.id != excludeId,
  );

  @override
  Future<void> addKnowledgePoint(KnowledgePoint kp) async {
    kpList.add(kp);
  }

  @override
  Future<void> addExam(Exam e) async {
    examList.add(e);
  }

  /// P2 §1.5.1 重框用：同页全部框（目标题 + 他题），测试里预置。
  List<QuestionBox> pageBoxes = [];

  /// 最近一次 replaceQuestionBoxes 收到的框（按题 id）。
  final Map<String, List<QuestionBox>> replacedBoxes = {};

  @override
  Future<List<QuestionBox>> boxesForPageImage(String pageImagePath) async =>
      List.of(pageBoxes);

  @override
  Future<void> replaceQuestionBoxes(
    String questionId,
    List<QuestionBox> boxes,
  ) async {
    replacedBoxes[questionId] = List.of(boxes);
  }

  /// SR2-3：事务失败桩——置真时 replaceQuestionBoxesAndSlice 抛错，
  /// 且不记框、不存题（与真实事务回滚语义对齐）。
  bool replaceShouldThrow = false;

  /// 最近一次 replaceQuestionBoxesAndSlice 是否被调用过。
  bool replaceCalled = false;

  /// B3-P01：详情页重框走单事务入口——Fake 里同样一次记下框与
  /// 切片字段（与真实实现一次事务的语义对齐：框与切片要么一起
  /// 记下，要么都不记）。
  @override
  Future<void> replaceQuestionBoxesAndSlice(
    String questionId,
    List<QuestionBox> boxes, {
    required String slicePath,
    required int sliceWidth,
    required int sliceHeight,
  }) async {
    replaceCalled = true;
    if (replaceShouldThrow) throw StateError('事务失败（测试桩）');
    replacedBoxes[questionId] = List.of(boxes);
    final q = questions.where((x) => x.id == questionId).firstOrNull;
    if (q != null) {
      await save(
        q.copyWith(
          slicePath: slicePath,
          sliceWidth: sliceWidth,
          sliceHeight: sliceHeight,
        ),
      );
    }
  }
}

FakeDetailRepo detailRepo() {
  final now = DateTime.now();
  return FakeDetailRepo(
    questions: [
      dtq(
        'q1',
        '函数极限',
        folderIds: const ['f1'],
        examId: 'e1',
        knowledgePointIds: const ['k1'],
        errorTypes: const ['概念不清'],
        tags: const ['易错', '常考'],
        answer: '1',
        explanation: 'lim(x→0) sin3x/x = 3。',
        createdAt: now.subtract(const Duration(days: 2)),
        isFavorite: true,
        reviewJoined: true,
      ),
      dtq(
        'q2',
        '导数应用综合',
        sliceKind: 'function',
        sliceText: '题：设 f(x) = x³ − 3x² + 2。',
        folderIds: const ['f2'],
        examId: 'e1',
        knowledgePointIds: const ['k2'],
        errorTypes: const ['方法不会'],
        tags: const ['易错'],
        createdAt: now.subtract(const Duration(days: 5)),
      ),
      dtq(
        'q3',
        '定积分阴影面积',
        sliceKind: 'chart',
        sliceText: '题：求阴影面积',
        folderIds: const ['f1'],
        errorTypes: const ['计算错误'],
        tags: const ['需重做'],
        answer: '见解析',
        explanation: '阴影面积 = ∫(1 − x²)dx。',
        createdAt: now.subtract(const Duration(days: 3)),
        isOrganized: false,
      ),
      dtq(
        'q5',
        '无错因题',
        sliceText: '题：还没有填错误类型',
        folderIds: const ['f1'],
        createdAt: now.subtract(const Duration(days: 1)),
      ),
    ],
    folderList: const [
      Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
      Folder(id: 'f2', name: '平时作业', subjectId: 'math', sortOrder: 10),
    ],
    examList: [Exam(id: 'e1', name: '高等数学期末试卷', date: DateTime(2026, 11, 10))],
    kpList: const [
      KnowledgePoint(
        id: 'k1',
        subjectId: 'math',
        chapter: '第一章 函数与极限',
        name: '函数极限',
      ),
      KnowledgePoint(
        id: 'k2',
        subjectId: 'math',
        chapter: '第二章 导数',
        name: '导数概念',
      ),
    ],
    tagList: const ['易错', '常考', '需重做'],
    records: [
      CauseRecord(
        questionId: 'q1',
        cause: '概念不清',
        subjectId: 'math',
        status: CauseStatus.inProgress,
        solvedCount: 1,
        joinedAt: now.subtract(const Duration(days: 2)),
      ),
    ],
    history: [
      (result: 'solved', reviewedAt: now.subtract(const Duration(days: 1))),
      (result: 'unsolved', reviewedAt: now.subtract(const Duration(days: 2))),
    ],
  );
}

/// FSRS 口径迁移（面 B）：确定性调度器（fuzzing 关），经
/// QuestionDetailPage.scheduler 注入；不注入时 DetailNotifier 的
/// FSRS 状态走默认 SQLite 调度器，真实库在 fake async 下永不完成，
/// 「复习状态」行不出（不卡页面，但新口径断言做不了）。
FsrsReviewScheduler _testScheduler() => FsrsReviewScheduler(
  config: const SchedulerConfig(enableFuzzing: false),
  store: InMemoryCardStore(),
);

/// 一条作答夹具：默认正式复习（mode = 到期复习）。
AttemptData _attempt(
  String questionId, {
  String mode = ReviewMode.due,
  int? correct,
  String session = 's1',
}) => AttemptData(
  id: 'att-$questionId-$mode-$correct-$session',
  questionId: questionId,
  sessionId: session,
  mode: mode,
  correct: correct,
  answerVersion: 1,
  contentVersion: 0,
  status: '已提交',
  submissionId: 'sub-$questionId-$mode-$correct-$session',
  createdAt: DateTime.now().millisecondsSinceEpoch,
);

Future<void> pumpDetail(
  WidgetTester tester, {
  FakeDetailRepo? repo,
  String questionId = 'q1',
  List<String> orderIds = const ['q1', 'q2', 'q3'],
  String sourceLabel = '错题本',
  bool imageFailed = false,
  Brightness brightness = Brightness.light,
  double scale = 1.0,
  // 二十三批 2 号方案窄屏测试用：默认 1280×720 宽屏。
  Size viewport = const Size(1280, 720),
  // FSRS 口径迁移（面 B）：预置卡片的调度器（未开始/已开始场景用）；
  // 不传时用空内存调度器（不在池里，「复习状态」行显示未加入复习）。
  ReviewScheduler? scheduler,
}) async {
  tester.view.physicalSize = viewport;
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
              body: QuestionDetailPage(
                // 每次 pump 用新 Key：同一 testWidgets 内循环 pump 时，
                // 旧 State 会被复用（折叠态 / 编辑态残留），须强制重建
                //（R6 pumpWrongbook 的 pageKey ?? UniqueKey() 同款做法）。
                key: UniqueKey(),
                repo: repo ?? detailRepo(),
                questionId: questionId,
                orderIds: orderIds,
                sourceLabel: sourceLabel,
                imageFailed: imageFailed,
                scheduler: scheduler ?? _testScheduler(),
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 点按前先滚到可见（详情页整页滚动，折叠头 / 底部操作行常在 720 高视口外，
/// 直接 tap 会落空——见 R6 截图坐标教训同款问题）。
Future<void> tapText(
  WidgetTester tester,
  String text, {
  bool first = false,
}) async {
  final finder = first ? find.text(text).first : find.text(text);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// SR3-10：读 PNG 的 IHDR 宽/高（与产品侧 pngDimensions 同款解析，
/// 测试里独立实现，避免用被测函数断言被测函数）。
({int width, int height}) pngSize(List<int> bytes) {
  int be32(int at) =>
      (bytes[at] << 24) |
      (bytes[at + 1] << 16) |
      (bytes[at + 2] << 8) |
      bytes[at + 3];
  return (width: be32(16), height: be32(20));
}

void main() {
  setUpAll(() async {
    _testTmp = await Directory.systemTemp.createTemp('qm2-detail-rework');
    // 560×700 真实页图（与编辑器画布同比例）。
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
    final pageDir = Directory('${_testTmp.path}/imports/rework-task');
    await pageDir.create(recursive: true);
    final file = File('${pageDir.path}/page.png');
    await file.writeAsBytes(png!.buffer.asUint8List());
    _pagePngRel = 'imports/rework-task/page.png';
    // P1-2：高图（200×800）真实切片，用于验证大图仍限高 460。
    final tallRecorder = ui.PictureRecorder();
    final tallCanvas = ui.Canvas(tallRecorder);
    tallCanvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 200, 800),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    final tallImg = await tallRecorder.endRecording().toImage(200, 800);
    final tallPng = await tallImg.toByteData(format: ui.ImageByteFormat.png);
    tallImg.dispose();
    final slicesDir = Directory('${_testTmp.path}/slices');
    await slicesDir.create(recursive: true);
    await File('${slicesDir.path}/tall.png')
        .writeAsBytes(tallPng!.buffer.asUint8List());
    // 重框确认时重裁的切片写盘走临时数据目录。
    AppDatabase.testDataDirectory = _testTmp.path;
  });

  tearDownAll(() async {
    // 二十五批：只动 tearDownAll。先清图片缓存（详情页切片经 Image.file
    // 显示后 mmap 占着文件）+ 关掉 _refreshRelated 真开过的库连接，
    // 再删目录；否则 Windows 上删目录报 errno 32。resetForTest 也把
    // testDataDirectory 置 null。
    imageCache.clear();
    await AppDatabase.resetForTest();
    await _testTmp.delete(recursive: true);
  });

  // 十三批 P1-2（任务 b）：重框入队走 DetailNotifier 的可 fake 缝——
  // 真实 Drift 在 widget 测试的 fake async 下永不完成（M5 §七第二条），
  // 用假入队代替；真实入队路径由 b13_stem_correction_test 的真实库
  // 测试覆盖。个别用例（入队失败横幅）会在用例内改写本假实现。
  setUp(() {
    DetailNotifier.enqueueOcrForTest = (db, q) async => OcrJob(
      id: 'fake-job-${q.id}',
      questionId: q.id,
      status: OcrJobStatus.pending,
      createdAt: DateTime(2026, 11, 18),
      updatedAt: DateTime(2026, 11, 18),
    );
  });

  tearDown(() {
    DetailNotifier.enqueueOcrForTest = null;
  });

  group('结构与默认态', () {
    testWidgets('D1 默认态：标题行 + 返回行 + 两 panel 默认展开 + 答案默认隐藏', (tester) async {
      await pumpDetail(tester);
      expect(find.text('函数极限'), findsOneWidget);
      expect(find.text('★'), findsOneWidget); // 已收藏
      expect(find.text('返回错题本'), findsOneWidget); // 只有返回行有
      expect(find.text('第 1 / 3 题 · 按错题本当前的顺序'), findsOneWidget);
      expect(find.text('上一题 ↑'), findsOneWidget);
      expect(find.text('下一题 ↓'), findsOneWidget);
      expect(find.text('题目信息'), findsOneWidget);
      expect(find.text('复习记录'), findsOneWidget);
      expect(find.text('看答案'), findsOneWidget); // 按钮行常驻
      expect(find.text('1'), findsNothing); // 答案藏在看答案后
      expect(find.text('取消加入复习'), findsOneWidget); // q1 已加入
      expect(find.text('开始复习'), findsNothing);
      expect(find.text('编辑'), findsOneWidget); // 题目信息 panel 底部
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('来源标签来自调用页：复习', (tester) async {
      await pumpDetail(tester, sourceLabel: '复习');
      expect(find.text('返回复习'), findsOneWidget);
      expect(find.text('第 1 / 3 题 · 按复习当前的顺序'), findsOneWidget);
    });

    testWidgets('标题行状态 pill 与 panel 里的错因', (tester) async {
      await pumpDetail(tester);
      expect(find.text('概念不清'), findsNWidgets(2)); // 信息错因行 + 复习错因行
      // FSRS 口径：标题 pill + 整体状态 pill 都是「未加入复习」，
      // 复习状态行里还有一处同文案；「解决中」只剩错因自身历史记录的 pill。
      expect(find.text('未加入复习'), findsNWidgets(3));
      expect(find.text('解决中'), findsNWidgets(1)); // 仅错因 pill
    });
  });

  group('答案解析', () {
    testWidgets('看答案在按钮行，点开显示答案与解析，可收起', (tester) async {
      await pumpDetail(tester);
      expect(find.text('看答案'), findsOneWidget);
      await tapText(tester, '看答案');
      expect(find.text('1'), findsOneWidget);
      expect(find.text('lim(x→0) sin3x/x = 3。'), findsOneWidget);
      expect(find.text('收起答案'), findsOneWidget);
      await tapText(tester, '收起答案');
      expect(find.text('看答案'), findsOneWidget);
    });

    testWidgets('空答案显示待补充，点它进编辑模式', (tester) async {
      await pumpDetail(tester, questionId: 'q2');
      await tapText(tester, '看答案');
      // D1：信息 panel 默认展开，q2 的备注也是空 → 答案 + 解析 + 备注共 3 处。
      expect(find.text('待补充 · 点这里补'), findsNWidgets(3));
      await tapText(tester, '待补充 · 点这里补', first: true);
      expect(find.text('保存'), findsOneWidget); // 左列底部（编辑态）
      expect(find.textContaining('正在编辑这道题'), findsOneWidget);
    });

    testWidgets('编辑态答案解析段只留提示，不直接改答案', (tester) async {
      await pumpDetail(tester);
      await tapText(tester, '编辑');
      expect(
        find.text('正在编辑：答案和解析在下方「题目信息」的编辑表单里改，改完点「保存」才生效。'),
        findsOneWidget,
      );
      expect(find.text('看答案'), findsNothing);
    });
  });

  group('题目信息', () {
    testWidgets('查看态七行字段 + 来源行', (tester) async {
      await pumpDetail(tester);
      // 两 panel 默认展开，不用先点标题。
      expect(find.text('学科'), findsOneWidget);
      expect(find.text('文件夹'), findsOneWidget);
      expect(find.text('知识点'), findsOneWidget);
      expect(find.text('错因'), findsOneWidget);
      expect(find.text('标签'), findsOneWidget);
      expect(find.text('备注'), findsOneWidget);
      expect(find.text('来源'), findsOneWidget);
      expect(find.text('来自试卷：高等数学期末试卷'), findsOneWidget);
      expect(find.text('#易错 #常考'), findsOneWidget);
      expect(find.text('数学 › 第一章 函数与极限 · 函数极限'), findsOneWidget);
      expect(find.text('概念不清'), findsNWidgets(2)); // 信息错因行 + 复习错因行
    });

    testWidgets('FR-16：章节为空时知识点只显示“学科 › 知识点名”', (tester) async {
      final repo = detailRepo();
      repo.kpList[0] = const KnowledgePoint(
        id: 'k1',
        subjectId: 'math',
        chapter: '',
        name: '函数极限',
      );
      await pumpDetail(tester, repo: repo);
      expect(find.text('数学 › 函数极限'), findsOneWidget);
    });

    testWidgets('空字段显示待补充', (tester) async {
      await pumpDetail(tester, questionId: 'q2');
      // q2 有文件夹/知识点/错误类型/标签，无备注 → 只有备注是待补充
      expect(find.text('待补充 · 点这里补'), findsOneWidget);
    });
  });

  group('复习记录', () {
    testWidgets('已加入题：取消加入 + 错因状态 + 复习状态 + 全部记录', (tester) async {
      await pumpDetail(tester);
      expect(find.text('取消加入复习'), findsOneWidget);
      // FSRS 口径：默认夹具不在 FSRS 池里，加入 pill 只写「已加入复习」。
      expect(find.text('已加入复习'), findsOneWidget);
      expect(find.text('取消加入不会删复习记录，再加入时接着上次的到期安排，不用从头来'), findsOneWidget);
      expect(find.text('错因状态'), findsOneWidget);
      expect(find.text('概念不清'), findsNWidgets(2)); // 信息错因行 + 复习错因行
      expect(find.text('解决中'), findsNWidgets(1)); // 仅错因 pill
      expect(find.text('未加入复习'), findsNWidgets(3)); // 标题 + 整体状态 + 复习状态行
      // FSRS 口径迁移（面 B）：每行旧口径「解决次数 N」与 kv 行
      // 「解决次数」（自查计数）已删，改为题目级「复习状态」行；
      // 默认夹具不在 FSRS 池里、无正式复习记录。
      expect(find.text('解决次数 1'), findsNothing);
      expect(find.textContaining('共自查 2 次'), findsNothing);
      expect(find.text('复习状态'), findsOneWidget);
      // 「未加入复习」共 3 处：标题 pill + 整体状态 pill + 复习状态行。
      expect(find.text('暂无正式复习记录'), findsOneWidget);
      expect(find.text('解决记录'), findsOneWidget);
      expect(find.textContaining('已解决'), findsWidgets);
      expect(find.textContaining('未解决'), findsWidgets);
    });

    testWidgets('FSRS：在池未开始 → 复习状态行显示未开始', (tester) async {
      final repo = detailRepo()..poolIdsValue = {'q1'};
      final scheduler = _testScheduler();
      await scheduler.initializeQuestion('q1');
      await pumpDetail(tester, repo: repo, scheduler: scheduler);
      expect(find.text('复习状态'), findsOneWidget);
      // 「未开始」共 3 处：标题 pill + 整体状态 pill + 复习状态行。
      expect(find.text('未开始'), findsNWidgets(3));
      expect(find.text('暂无正式复习记录'), findsOneWidget);
    });

    testWidgets('FSRS：已开始 → 复习状态行显示下次到期 M月M日', (tester) async {
      final repo = detailRepo()..poolIdsValue = {'q1'};
      final scheduler = _testScheduler();
      await scheduler.initializeQuestion('q1');
      await scheduler.recordAnswer(
        'q1',
        ReviewResult.good,
        DateTime.now(),
        'evt-q1-good',
      );
      final due = await scheduler.nextDueAt('q1');
      await pumpDetail(tester, repo: repo, scheduler: scheduler);
      expect(find.text('复习状态'), findsOneWidget);
      expect(find.text('下次到期 ${due!.month}月${due.day}日'), findsOneWidget);
    });

    testWidgets('FSRS：正式对错按次计，专项与未判分不计', (tester) async {
      final repo = detailRepo()
        ..attemptsValue = [
          _attempt('q1', correct: 1, session: 's1'),
          _attempt('q1', correct: 1, session: 's2'),
          _attempt('q1', correct: 0, session: 's3'),
          _attempt(
            'q1',
            mode: ReviewMode.practice,
            correct: 1,
            session: 's4',
          ),
          _attempt('q1', session: 's5'),
          _attempt('q2', correct: 1, session: 's6'),
        ];
      await pumpDetail(tester, repo: repo);
      expect(find.text('复习状态'), findsOneWidget);
      expect(find.text('正式复习答对 2 次 · 答错 1 次'), findsOneWidget);
    });

    testWidgets('FSRS：已加入且在池未开始 → 加入 pill 显示“已加入复习 · 未开始”', (tester) async {
      final repo = detailRepo()..poolIdsValue = {'q1'};
      final scheduler = _testScheduler();
      await scheduler.initializeQuestion('q1');
      await pumpDetail(tester, repo: repo, scheduler: scheduler);
      expect(find.text('已加入复习 · 未开始'), findsOneWidget);
    });

    testWidgets('FSRS：已加入且已开始 → 加入 pill 显示“已加入复习 · 下次到期 M月M日”', (tester) async {
      final repo = detailRepo()..poolIdsValue = {'q1'};
      final scheduler = _testScheduler();
      await scheduler.initializeQuestion('q1');
      await scheduler.recordAnswer(
        'q1',
        ReviewResult.good,
        DateTime.now(),
        'evt-q1-good',
      );
      final due = await scheduler.nextDueAt('q1');
      await pumpDetail(tester, repo: repo, scheduler: scheduler);
      expect(find.text('已加入复习 · 下次到期 ${due!.month}月${due.day}日'), findsOneWidget);
    });

    testWidgets('未加入题：加入复习，点后变取消加入复习', (tester) async {
      final repo = detailRepo();
      await pumpDetail(tester, repo: repo, questionId: 'q2');
      expect(find.text('加入复习'), findsOneWidget);
      await tapText(tester, '加入复习');
      expect(find.text('取消加入复习'), findsOneWidget);
      expect(repo.saved.last.reviewJoined, isTrue);
    });

    testWidgets('未整理题没有加入复习按钮', (tester) async {
      await pumpDetail(tester, questionId: 'q3');
      expect(find.text('加入复习'), findsNothing);
      expect(find.text('取消加入复习'), findsNothing);
      expect(find.text('未整理的题不能加入复习'), findsOneWidget);
    });

    testWidgets('无错因题加入时提示先补错误类型', (tester) async {
      await pumpDetail(tester, questionId: 'q5');
      expect(find.text('加入复习'), findsOneWidget);
      await tapText(tester, '加入复习');
      await tester.pump();
      expect(find.text('先补错因'), findsOneWidget);
    });
  });

  group('编辑', () {
    testWidgets('改标题后保存生效', (tester) async {
      final repo = detailRepo();
      await pumpDetail(tester, repo: repo);
      await tapText(tester, '编辑');
      expect(find.textContaining('正在编辑这道题'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '函数极限改');
      await tapText(tester, '保存', first: true);
      expect(find.text('函数极限改'), findsOneWidget);
      expect(repo.saved.last.title, '函数极限改');
      expect(find.text('编辑'), findsOneWidget);
    });

    testWidgets('WP-A #1 收尾：切分检测到的 2 项序列作编辑器初始值（查看态 + 编辑态）', (tester) async {
      const md = '下列说法正确的是\n\nA. 甲\nB. 乙';
      final repo = FakeDetailRepo(
        questions: [
          dtq(
            'q1',
            '下列说法',
            questionType: 'choice_single',
            ocrRaw: GlmOcrRawData(mdResults: md).toJsonString(),
          ),
        ],
      );
      await pumpDetail(tester, repo: repo);
      // 查看态：题目信息 panel 默认展开，编辑器初始位就是检测到的两项。
      expect(find.widgetWithText(QmChip, 'A'), findsOneWidget);
      expect(find.widgetWithText(QmChip, 'B'), findsOneWidget);
      expect(find.widgetWithText(QmChip, 'C'), findsNothing);
      // 编辑态：同款初始值（未接线时兜底 A–D 会多出 C、D）。
      await tapText(tester, '编辑');
      expect(find.widgetWithText(QmChip, 'A'), findsOneWidget);
      expect(find.widgetWithText(QmChip, 'B'), findsOneWidget);
      expect(find.widgetWithText(QmChip, 'C'), findsNothing);
    });

    testWidgets('WP-A #1 收尾：编辑态多选点选选项位后答案字段文本随之更新', (tester) async {
      final repo = FakeDetailRepo(
        questions: [
          dtq(
            'q1',
            '多选函数',
            questionType: 'choice_multi',
            optionLabels: const ['A', 'B', 'C', 'D'],
          ),
        ],
      );
      await pumpDetail(tester, repo: repo);
      await tapText(tester, '编辑');
      // Win11 反馈包 1：选择题不显示文字答案框——多选答案只活在点选
      // 里，保存时拼成字母串落库。
      final answerField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '填答案（可以空着）',
      );
      expect(answerField, findsNothing);
      Future<void> tapChip(String letter) async {
        final chip = find.widgetWithText(QmChip, letter);
        await tester.ensureVisible(chip);
        await tester.pumpAndSettle();
        await tester.tap(chip);
        await tester.pumpAndSettle();
      }

      await tapChip('A');
      await tapChip('C');
      await tapText(tester, '保存', first: true);
      expect(repo.saved.last.answer, 'A,C');
      // 再进编辑：取消点选 A，保存后答案同步回落。
      await tapText(tester, '编辑');
      await tapChip('A');
      await tapChip('C');
      await tapChip('A');
      await tapText(tester, '保存', first: true);
      expect(repo.saved.last.answer, 'C');
    });

    testWidgets('取消无改动直接退出编辑', (tester) async {
      await pumpDetail(tester);
      await tapText(tester, '编辑');
      await tapText(tester, '取消', first: true);
      expect(find.text('编辑'), findsOneWidget);
      expect(find.text('保存'), findsNothing);
    });

    testWidgets('取消有改动弹出内联确认框，三按钮行为正确', (tester) async {
      final repo = detailRepo();
      await pumpDetail(tester, repo: repo);
      await tapText(tester, '编辑');
      await tester.enterText(find.byType(TextField).first, '函数极限改');
      await tapText(tester, '取消', first: true);
      expect(find.text('有还没保存的改动，要保存吗？'), findsOneWidget);
      expect(find.text('保存并退出'), findsOneWidget);
      expect(find.text('不保存，丢弃改动'), findsOneWidget);
      expect(find.text('继续编辑'), findsOneWidget);
      // 继续编辑：仍在编辑态
      await tapText(tester, '继续编辑');
      expect(find.text('保存'), findsOneWidget); // 左列底部（编辑态）
      // 不保存：退出编辑，标题未变
      await tapText(tester, '取消', first: true);
      await tapText(tester, '不保存，丢弃改动');
      expect(find.text('函数极限'), findsOneWidget);
      expect(repo.saved, isEmpty);
      // 保存并退出：保存且退出编辑
      await tapText(tester, '编辑');
      await tester.enterText(find.byType(TextField).first, '函数极限改');
      await tapText(tester, '取消', first: true);
      await tapText(tester, '保存并退出');
      expect(find.text('函数极限改'), findsOneWidget);
      expect(repo.saved.last.title, '函数极限改');
    });

    testWidgets('方案二：左右两栏——左列整理字段、右列属性行、底部取消/保存',
        (tester) async {
      await pumpDetail(tester);
      await tapText(tester, '编辑');
      // 面板头：题目信息 +「编辑中」+「改动保存后才生效」。
      expect(find.text('题目信息'), findsOneWidget);
      expect(find.text('编辑中'), findsOneWidget);
      expect(find.text('改动保存后才生效'), findsOneWidget);
      // 3 号方案的东西全拆掉：分组小标题、「？」、组头新建按钮。
      expect(find.text('归类'), findsNothing);
      expect(find.text('诊断'), findsNothing);
      expect(find.text('来源与内容'), findsNothing);
      expect(find.byKey(const Key('field-help-文件夹')), findsNothing);
      expect(find.text('＋ 新建文件夹'), findsNothing);
      expect(find.text('＋ 新建知识点'), findsNothing);
      expect(find.text('＋ 自定义错因'), findsNothing);
      expect(find.text('＋ 新建标签'), findsNothing);
      expect(find.text('＋ 新建试卷'), findsNothing);
      // 左列：文件夹 * / 知识点 / 答案 / 解析 / 备注。
      expect(find.text('文件夹 *'), findsOneWidget);
      expect(find.text('知识点'), findsOneWidget);
      expect(find.text('答案'), findsOneWidget);
      expect(find.text('解析'), findsOneWidget);
      expect(find.text('备注'), findsOneWidget);
      // 右列：一行一个——学科（数学 不可改）/ 试卷 / 题型（待确认）/
      // 错因 / 标签。'试卷'出现两次：文件夹 chip + 右列标签。
      expect(find.text('学科'), findsOneWidget);
      expect(find.text('数学'), findsOneWidget);
      expect(find.text('不可改'), findsOneWidget);
      expect(find.text('试卷'), findsNWidgets(2));
      expect(find.textContaining('高等数学期末试卷'), findsOneWidget);
      expect(find.text('待确认'), findsOneWidget);
      expect(find.text('错因'), findsOneWidget);
      expect(find.text('标签'), findsOneWidget);
      // 错因 chip（固定五项 +「＋ 自定义」）、标签 chip +「＋ 新建」。
      // 「概念不清」在复习记录里也出现一次，错因行用 panel 限定。
      final infoPanel = find.byKey(const Key('detail-panel-info'));
      for (final t in ['审题失误', '概念不清', '计算错误', '方法不会', '其他']) {
        expect(
          find.descendant(of: infoPanel, matching: find.text(t)),
          findsOneWidget,
        );
      }
      expect(find.text('＋ 自定义'), findsOneWidget);
      for (final t in ['易错', '常考', '需重做']) {
        expect(find.text(t), findsOneWidget);
      }
      // 「＋ 新建」两处：文件夹行与标签行。
      expect(find.text('＋ 新建'), findsNWidgets(2));
      // 知识点：q1 已选 k1，显示已选 chip +「＋ 添加」。
      expect(
        find.text('第一章 函数与极限 · 函数极限'),
        findsOneWidget,
      );
      expect(find.text('＋ 添加'), findsOneWidget);
      // 取消/保存各一个，在左列底部。
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('保存'), findsOneWidget);
      // 几何：右列在左列右面；取消/保存在备注下面、右列左面。
      final folderRect = tester.getRect(find.text('文件夹 *'));
      final attrRect = tester.getRect(find.text('学科'));
      expect(attrRect.left, greaterThan(folderRect.right));
      final notesRect = tester.getRect(find.text('备注'));
      final saveRect = tester.getRect(find.text('保存'));
      expect(saveRect.top, greaterThan(notesRect.bottom));
      expect(saveRect.right, lessThan(attrRect.left));
    });

    testWidgets('方案二：知识点「＋ 添加」展开选择器，点选后选中', (tester) async {
      await pumpDetail(tester);
      await tapText(tester, '编辑');
      const k2 = '第二章 导数 · 导数概念';
      // 选择器关着：k2 不出现，「＋ 新建知识点」也不出现。
      expect(find.text(k2), findsNothing);
      expect(find.text('＋ 新建知识点'), findsNothing);
      await tapText(tester, '＋ 添加');
      expect(find.text('收起'), findsOneWidget);
      expect(find.text(k2), findsOneWidget);
      expect(find.text('＋ 新建知识点'), findsOneWidget);
      // 点选 k2：已选区与选择器里各出现一次。
      await tapText(tester, k2);
      expect(find.text(k2), findsNWidgets(2));
      // 收起：选择器关掉，已选区只剩一次。
      await tapText(tester, '收起');
      expect(find.text('＋ 添加'), findsOneWidget);
      expect(find.text(k2), findsOneWidget);
      expect(find.text('＋ 新建知识点'), findsNothing);
    });

    testWidgets('方案二：窄屏右栏掉到左列下方变一列', (tester) async {
      await pumpDetail(
        tester,
        questionId: 'q3',
        viewport: const Size(500, 800),
      );
      await tapText(tester, '编辑');
      // q3 未关联试卷，下拉显示「未关联试卷」；未选知识点显示「还没选」。
      expect(find.text('未关联试卷'), findsOneWidget);
      expect(find.text('还没选'), findsOneWidget);
      // 几何：右列（学科行）在左列（备注行）下方，且与左列同一起点。
      final folderRect = tester.getRect(find.text('文件夹 *'));
      final notesRect = tester.getRect(find.text('备注'));
      final attrRect = tester.getRect(find.text('学科'));
      expect(attrRect.top, greaterThan(notesRect.bottom));
      expect((attrRect.left - folderRect.left).abs(), lessThan(2.0));
    });
  });

  group('收藏 / 归档 / 删除 / 上一题 / 下一题', () {
    testWidgets('收藏切换：标题行星标 ☆ → ★', (tester) async {
      final repo = detailRepo();
      await pumpDetail(tester, repo: repo, questionId: 'q2');
      expect(find.text('☆'), findsOneWidget);
      await tapText(tester, '☆');
      expect(find.text('★'), findsOneWidget);
      expect(repo.saved.last.isFavorite, isTrue);
    });

    testWidgets('归档切换：归档 → 已归档横幅 + 恢复', (tester) async {
      final repo = detailRepo();
      await pumpDetail(tester, repo: repo);
      await tapText(tester, '归档');
      expect(find.text('恢复'), findsOneWidget);
      expect(find.textContaining('这道题已归档：不在错题本列表里显示。'), findsOneWidget);
      expect(repo.saved.last.isArchived, isTrue);
    });

    testWidgets('删除模态弹窗确认：取消留题，确认删除后进下一题', (tester) async {
      final repo = detailRepo();
      await pumpDetail(tester, repo: repo);
      await tapText(tester, '删除');
      expect(find.textContaining('删了就没了，确定吗？'), findsOneWidget);
      expect(find.textContaining('整题图与全部补充内容一并删除，不可恢复。'), findsOneWidget);
      await tapText(tester, '取消', first: true);
      expect(find.text('函数极限'), findsOneWidget);
      expect(repo.deletedIds, isEmpty);
      await tapText(tester, '删除');
      await tapText(tester, '确认删除');
      expect(repo.deletedIds, ['q1']);
      expect(find.text('导数应用综合'), findsOneWidget);
      // 删掉 q1 后列表剩 2 项，q2 排第 1 位。
      expect(find.text('第 1 / 2 题 · 按错题本当前的顺序'), findsOneWidget);
    });

    testWidgets('上一题 / 下一题按来源列表顺序，首末禁用', (tester) async {
      await pumpDetail(tester);
      // 首题：上一题点按无反应
      await tapText(tester, '上一题 ↑');
      expect(find.text('函数极限'), findsOneWidget);
      await tapText(tester, '下一题 ↓');
      expect(find.text('导数应用综合'), findsOneWidget);
      await tapText(tester, '上一题 ↑');
      expect(find.text('函数极限'), findsOneWidget);
      // 到末题：下一题点按无反应
      await tapText(tester, '下一题 ↓');
      await tapText(tester, '下一题 ↓');
      expect(find.text('定积分阴影面积'), findsOneWidget);
      await tapText(tester, '下一题 ↓');
      expect(find.text('定积分阴影面积'), findsOneWidget);
    });
  });

  group('空态与错误态', () {
    testWidgets('无文字内容题显示空内容横幅', (tester) async {
      await pumpDetail(tester, questionId: 'q2');
      expect(find.textContaining('这道题还没有补充任何文字内容'), findsOneWidget);
    });

    testWidgets('imageFailed 显示学科图标 + 题型占位 + 错误横幅', (tester) async {
      await pumpDetail(tester, imageFailed: true);
      // B8-7：标题旁的学科图标章也是「数」，与占位里的学科图标共 2 个。
      expect(find.text('数'), findsNWidgets(2));
      expect(find.text('数学 · 极限题'), findsOneWidget);
      expect(find.textContaining('这道题的图片读取失败'), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
    });
  });

  group('重新框选 §1.5.1', () {
    testWidgets('有页图的题：入口可用，同页他题只读，确认后切片重裁、框替换', (tester) async {
      final repo = detailRepo();
      repo.questions[0] = repo.questions[0].copyWith(
        pageImagePath: _pagePngRel,
        sourcePath: _pagePngRel,
        slicePath: 'slices/q1.png',
        sliceWidth: 200,
        sliceHeight: 100,
      );
      repo.pageBoxes = [
        QuestionBox(
          id: 'q1-box',
          layer: 1,
          type: 'question',
          x: 0.06,
          y: 0.05,
          w: 0.88,
          h: 0.4,
          page: 1,
          questionId: 'q1',
        ),
        QuestionBox(
          id: 'q2-box',
          layer: 1,
          type: 'question',
          x: 0.1,
          y: 0.55,
          w: 0.5,
          h: 0.35,
          page: 1,
          questionId: 'q2',
        ),
      ];
      await pumpDetail(tester, repo: repo);
      expect(find.text('重新框选'), findsOneWidget);
      await tapText(tester, '重新框选');
      expect(find.textContaining('修框 ·'), findsOneWidget);
      // 同页他题的框只读展示，目标题的框可编辑。
      expect(find.text('其他题 · 只读'), findsOneWidget);
      expect(find.textContaining('题级框 1'), findsWidgets);
      // 确认：重裁切片是真实文件 IO + 图片解码，须在 runAsync 内
      // 反复 pump + 真实延时推进（collect_page_test 的同款做法）。
      await tester.runAsync(() async {
        await tester.tap(find.text('确认重新框选'));
        // 十三批 P1-2：applyReworkBoxes 现在 await 入队（确认任务已持久化
        // 才返回），成功提示要等入队落盘才出现；固定 20×200ms 在连跑
        // 时不够（开库慢），改为轮询等提示出现/编辑器关闭，上限 10 秒。
        for (var i = 0; i < 50; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 200));
          if (find.text('已重新框选，切片已更新').evaluate().isNotEmpty ||
              find.textContaining('修框 ·').evaluate().isEmpty) {
            break;
          }
        }
        await tester.pumpAndSettle();
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('修框 ·'), findsNothing);
      expect(find.text('已重新框选，切片已更新'), findsOneWidget);
      // 只替换了目标题的题级框。
      final replaced = repo.replacedBoxes['q1'];
      expect(replaced, isNotNull);
      expect(replaced!.where((b) => b.layer == 1).length, 1);
      // 切片被重写，题的 sliceWidth/Height 已更新。
      final savedQ = repo.saved.lastWhere((q) => q.id == 'q1');
      expect(savedQ.sliceWidth, greaterThan(0));
      expect(savedQ.sliceHeight, greaterThan(0));
      final sliceAbs = AppDatabase.resolveDataPath(savedQ.slicePath!);
      expect(sliceAbs != null && File(sliceAbs).existsSync(), isTrue);
    });

    testWidgets('十三批 P1-2：重框入队失败显“题目已更新，OCR 未入队”横幅，点“重新入队”后横幅消失', (tester) async {
      // 入队失败：缝改成抛错的假实现（模拟读盘/写库失败）。
      DetailNotifier.enqueueOcrForTest = (db, q) async {
        throw StateError('fake enqueue failure');
      };
      final repo = detailRepo();
      repo.questions[0] = repo.questions[0].copyWith(
        pageImagePath: _pagePngRel,
        sourcePath: _pagePngRel,
        slicePath: 'slices/q1.png',
        sliceWidth: 200,
        sliceHeight: 100,
      );
      repo.pageBoxes = [
        QuestionBox(
          id: 'q1-box',
          layer: 1,
          type: 'question',
          x: 0.06,
          y: 0.05,
          w: 0.88,
          h: 0.4,
          page: 1,
          questionId: 'q1',
        ),
      ];
      await pumpDetail(tester, repo: repo);
      await tapText(tester, '重新框选');
      await tester.runAsync(() async {
        await tester.tap(find.text('确认重新框选'));
        for (var i = 0; i < 50; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 200));
          if (find.text('已重新框选，切片已更新').evaluate().isNotEmpty ||
              find.textContaining('修框 ·').evaluate().isEmpty) {
            break;
          }
        }
        await tester.pumpAndSettle();
      });
      await tester.pumpAndSettle();
      // 框选本身成功（提示照常），但入队失败横幅出现。
      expect(find.text('已重新框选，切片已更新'), findsOneWidget);
      expect(
        find.byKey(const Key('ocr-enqueue-failed-banner')),
        findsOneWidget,
      );
      expect(find.text('题目已更新，OCR 未入队'), findsOneWidget);
      expect(find.text('重新入队'), findsOneWidget);
      // 切片确实换了（失败没把重框拖垮）：replace 已调且只换了目标题的框。
      // 注意不用 repo.saved.lastWhere 断言新切片路径——打开页时的切片自愈
      // （SR3-10）与重框并发跑，旧切片缺失时它会后保存一次旧路径，
      // 切片路径断言会与自愈竞跑；版本化新路径由 P1-1 用例与本批 plain
      // 测试覆盖。
      expect(repo.replaceCalled, isTrue);
      final replaced = repo.replacedBoxes['q1'];
      expect(replaced, isNotNull);
      expect(replaced!.where((b) => b.layer == 1).length, 1);

      // 先等重框成功的 SnackBar 走完 4 秒：它的定时器是在 runAsync 的
      // 真实时间区里建的，假时间 pump 拨不动；重试的提示会排在它后面，
      // 不等它消失就看不到新提示。
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 5));
      });
      await tester.pumpAndSettle();
      expect(find.text('已重新框选，切片已更新'), findsNothing);

      // 重试：缝改回成功实现，点横幅上的“重新入队”。
      DetailNotifier.enqueueOcrForTest = (db, q) async => OcrJob(
        id: 'fake-job-${q.id}',
        questionId: q.id,
        status: OcrJobStatus.pending,
        createdAt: DateTime(2026, 11, 18),
        updatedAt: DateTime(2026, 11, 18),
      );
      await tester.tap(find.text('重新入队'));
      await tester.pumpAndSettle();
      expect(find.text('已重新加入识别队列'), findsOneWidget);
      expect(
        find.byKey(const Key('ocr-enqueue-failed-banner')),
        findsNothing,
      );
      expect(find.text('题目已更新，OCR 未入队'), findsNothing);
      // 收尾：把重试提示的 4 秒定时器走完再结束用例，否则它的
      // hideCurrentSnackBar 在页面已销毁后才触发，测试框架报
      // “after the test had completed”。假时间与真实时间各走 5 秒——
      // 两个 SnackBar 的定时器分属不同时间区（重框的在 runAsync 的
      // 真实区里建），只走一种盖不住。
      await tester.pump(const Duration(seconds: 5));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 5));
      });
      await tester.pumpAndSettle();
    });

    testWidgets('十三批 P1-1：重框写新版本文件，旧切片字节不动', (tester) async {
      // 旧切片事先存在：用真实页图字节当旧切片内容。
      final slicesDir = Directory('${_testTmp.path}/slices');
      slicesDir.createSync(recursive: true);
      final oldSliceFile = File('${slicesDir.path}/q1.png');
      final oldBytes = File('${_testTmp.path}/$_pagePngRel').readAsBytesSync();
      oldSliceFile.writeAsBytesSync(oldBytes);
      final repo = detailRepo();
      repo.questions[0] = repo.questions[0].copyWith(
        pageImagePath: _pagePngRel,
        sourcePath: _pagePngRel,
        slicePath: 'slices/q1.png',
        sliceWidth: 200,
        sliceHeight: 100,
      );
      repo.pageBoxes = [
        QuestionBox(
          id: 'q1-box',
          layer: 1,
          type: 'question',
          x: 0.06,
          y: 0.05,
          w: 0.88,
          h: 0.4,
          page: 1,
          questionId: 'q1',
        ),
      ];
      await pumpDetail(tester, repo: repo);
      await tapText(tester, '重新框选');
      await tester.runAsync(() async {
        await tester.tap(find.text('确认重新框选'));
        // 十三批 P1-2：applyReworkBoxes 现在 await 入队（确认任务已持久化
        // 才返回），成功提示要等入队落盘才出现；固定 20×200ms 在连跑
        // 时不够（开库慢），改为轮询等提示出现/编辑器关闭，上限 10 秒。
        for (var i = 0; i < 50; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 200));
          if (find.text('已重新框选，切片已更新').evaluate().isNotEmpty ||
              find.textContaining('修框 ·').evaluate().isEmpty) {
            break;
          }
        }
        await tester.pumpAndSettle();
      });
      await tester.pumpAndSettle();
      expect(find.text('已重新框选，切片已更新'), findsOneWidget);
      // 旧文件逐字节不动；题指到新版本文件（slices/q1-v<时间戳>-<随机>.png）。
      expect(oldSliceFile.readAsBytesSync(), oldBytes);
      final savedQ = repo.saved.lastWhere((q) => q.id == 'q1');
      expect(savedQ.slicePath, isNot('slices/q1.png'));
      expect(savedQ.slicePath, startsWith('slices/q1-v'));
      expect(savedQ.slicePath, endsWith('.png'));
      final newAbs = AppDatabase.resolveDataPath(savedQ.slicePath!);
      expect(newAbs != null && File(newAbs).existsSync(), isTrue);
      expect(File(newAbs!).readAsBytesSync(), isNot(oldBytes));
    });

    testWidgets('SR2-3：事务失败时旧切片字节完好、框与题不动（有旧切片）', (tester) async {
      // 旧切片事先存在：用真实页图字节当旧切片内容，失败后逐字节比对。
      // B5 的 P2-3 回归测试夹具里 slices/q1.png 事先不存在，没覆盖
      // 此场景——旧写法此时已把旧切片覆盖又删掉。
      final slicesDir = Directory('${_testTmp.path}/slices');
      slicesDir.createSync(recursive: true);
      final oldSliceFile = File('${slicesDir.path}/q1.png');
      final oldBytes = File('${_testTmp.path}/$_pagePngRel').readAsBytesSync();
      oldSliceFile.writeAsBytesSync(oldBytes);
      final repo = detailRepo();
      repo.questions[0] = repo.questions[0].copyWith(
        pageImagePath: _pagePngRel,
        sourcePath: _pagePngRel,
        slicePath: 'slices/q1.png',
        sliceWidth: 200,
        sliceHeight: 100,
      );
      repo.pageBoxes = [
        QuestionBox(
          id: 'q1-box',
          layer: 1,
          type: 'question',
          x: 0.06,
          y: 0.05,
          w: 0.88,
          h: 0.4,
          page: 1,
          questionId: 'q1',
        ),
      ];
      repo.replaceShouldThrow = true;
      await pumpDetail(tester, repo: repo);
      // SR3-10：本用例的夹具（库里记 200×100、磁盘是 560×700 的旧图）
      // 正是自愈要修的“库新图旧”状态——打开详情页时自愈会先按当前
      // 框把它重裁一次。先在 runAsync 内把自愈跑完（生产上用户打开
      // 页到点重框之间自愈早已完成），再以自愈后的切片为基线：
      // 本用例断言的是“事务失败不碰切片”，基线是自愈后的切片。
      // 十三批 P1-1：自愈写新版本文件（旧文件字节不动），等自愈那次
      // repo.save 落袋（slice_path 已指到 slices/q1-v…）才继续。
      // D-38：固定等 6 秒在 1.5 核 VM 全量负载下会抖（原生图片解码
      // 慢于等待），改成按条件轮询——等到新切片宽度变成自愈后的 492
      // 且自愈那次 repo.save 已落袋才继续，断言本身不变。
      // 注意顺序：自愈先写文件、再调 save 改库里尺寸与路径；只等文件会
      // 破得太早，后面的 repo.saved.clear() 就清不到那次保存。
      await tester.runAsync(() async {
        for (var i = 0; i < 75; i++) {
          await tester.pump();
          try {
            Question? healedSaved;
            for (final s in repo.saved) {
              if (s.id == 'q1') healedSaved = s;
            }
            final healedPath = healedSaved?.slicePath;
            if (healedPath != null && healedPath.startsWith('slices/q1-v')) {
              final healedAbs = AppDatabase.resolveDataPath(healedPath);
              if (healedAbs != null &&
                  File(healedAbs).existsSync() &&
                  pngSize(File(healedAbs).readAsBytesSync()).width == 492) {
                break;
              }
            }
          } catch (_) {
            // 文件正被重写、解不出来时继续等。
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        await tester.pumpAndSettle();
      });
      await tester.pumpAndSettle();
      // 自愈写了新版本文件：旧文件字节不动，基线是自愈后的新切片。
      expect(oldSliceFile.readAsBytesSync(), oldBytes);
      final healedPath =
          repo.saved.lastWhere((q) => q.id == 'q1').slicePath!;
      final healedAbs = AppDatabase.resolveDataPath(healedPath)!;
      final healedBytes = File(healedAbs).readAsBytesSync();
      expect(pngSize(healedBytes).width, 492);
      // 自愈会调一次 repo.save（把库里尺寸改成重裁尺寸），清掉它，
      // 后面“事务失败不存题”的断言才只量本次重框。
      repo.saved.clear();
      await tapText(tester, '重新框选');
      expect(find.textContaining('修框 ·'), findsOneWidget);
      // D-38：确认后的失败路径含真实文件 IO + 临时文件异步清理，
      // 固定等 4 秒在全量负载下会抖（失败提示已出、清理还没落定）。
      // 改成按条件轮询——失败提示出现且 .tmp 临时文件清干净才继续，
      // 后面的断言本身不变。
      await tester.runAsync(() async {
        await tester.tap(find.text('确认重新框选'));
        for (var i = 0; i < 50; i++) {
          await tester.pump();
          final failedShown = find
              .text('重新框选失败：保存失败，请重试')
              .evaluate()
              .isNotEmpty;
          final tmpGone = slicesDir
              .listSync()
              .where((f) => f.path.contains('.tmp-'))
              .isEmpty;
          if (failedShown && tmpGone) break;
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        await tester.pumpAndSettle();
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('修框 ·'), findsNothing);
      expect(repo.replaceCalled, isTrue);
      expect(find.text('重新框选失败：保存失败，请重试'), findsOneWidget);
      // 旧切片与自愈后的新切片字节都完好（SR2-3 的核心断言；基线是
      // 打开页时自愈后的切片，见本用例开头的说明——事务失败只保证
      // 不碰当时的切片）。
      expect(oldSliceFile.readAsBytesSync(), equals(oldBytes));
      expect(File(healedAbs).readAsBytesSync(), equals(healedBytes));
      // 临时切片已清干净，不留 .tmp-*.png。
      expect(
        slicesDir.listSync().where((f) => f.path.contains('.tmp-')).isEmpty,
        isTrue,
      );
      // 框与题都没动：事务桩抛错前不记框、不存题。
      expect(repo.replacedBoxes.containsKey('q1'), isFalse);
      expect(repo.saved.where((q) => q.id == 'q1'), isEmpty);
    });

    testWidgets('SR-P1-8：源页 ≥2 的题重框无缩略图条，确认后框不丢失', (tester) async {
      final repo = detailRepo();
      repo.questions[0] = repo.questions[0].copyWith(
        pageImagePath: _pagePngRel,
        sourcePath: _pagePngRel,
        slicePath: 'slices/q1.png',
        sliceWidth: 200,
        sliceHeight: 100,
        sourcePage: 2,
      );
      repo.pageBoxes = [
        QuestionBox(
          id: 'q1-box',
          layer: 1,
          type: 'question',
          x: 0.06,
          y: 0.05,
          w: 0.88,
          h: 0.4,
          page: 2,
          questionId: 'q1',
        ),
      ];
      await pumpDetail(tester, repo: repo);
      await tapText(tester, '重新框选');
      expect(find.textContaining('修框 ·'), findsOneWidget);
      // 标题仍显示真实源页码（第 2 页）。
      expect(find.textContaining('第2页'), findsOneWidget);
      // 重框模式隐藏整条缩略图条：没有“第 1 页”缩略图可点，
      // 也就没有切到不存在的空页、框消失的路径。
      expect(find.byKey(const Key('editor-thumb-1')), findsNothing);
      expect(find.text('第 1 页'), findsNothing);
      expect(find.textContaining('本页修完'), findsNothing);
      // 原页的框仍在画布上。
      expect(find.textContaining('题级框 1'), findsWidgets);
      // 直接确认：框不丢失（仍是源页的 1 个题级框）。
      await tester.runAsync(() async {
        await tester.tap(find.text('确认重新框选'));
        // 十三批 P1-2：applyReworkBoxes 现在 await 入队（确认任务已持久化
        // 才返回），成功提示要等入队落盘才出现；固定 20×200ms 在连跑
        // 时不够（开库慢），改为轮询等提示出现/编辑器关闭，上限 10 秒。
        for (var i = 0; i < 50; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 200));
          if (find.text('已重新框选，切片已更新').evaluate().isNotEmpty ||
              find.textContaining('修框 ·').evaluate().isEmpty) {
            break;
          }
        }
        await tester.pumpAndSettle();
      });
      await tester.pumpAndSettle();
      expect(find.text('已重新框选，切片已更新'), findsOneWidget);
      final replaced = repo.replacedBoxes['q1'];
      expect(replaced, isNotNull);
      expect(replaced!.where((b) => b.layer == 1).length, 1);
      expect(replaced.where((b) => b.layer == 1).first.page, 2);
    });

    testWidgets('无页图的题：不显示重新框选入口', (tester) async {
      await pumpDetail(tester, repo: detailRepo());
      expect(find.text('重新框选'), findsNothing);
    });

    testWidgets('FR-04(a) 重框模式禁画新框：右键/触摸都画不出新框，确认后仍一框', (tester) async {
      final repo = detailRepo();
      repo.questions[0] = repo.questions[0].copyWith(
        pageImagePath: _pagePngRel,
        sourcePath: _pagePngRel,
        slicePath: 'slices/q1.png',
        sliceWidth: 200,
        sliceHeight: 100,
      );
      repo.pageBoxes = [
        QuestionBox(
          id: 'q1-box',
          layer: 1,
          type: 'question',
          x: 0.06,
          y: 0.05,
          w: 0.88,
          h: 0.4,
          page: 1,
          questionId: 'q1',
        ),
        QuestionBox(
          id: 'q2-box',
          layer: 1,
          type: 'question',
          x: 0.1,
          y: 0.55,
          w: 0.5,
          h: 0.35,
          page: 1,
          questionId: 'q2',
        ),
      ];
      await pumpDetail(tester, repo: repo);
      await tapText(tester, '重新框选');
      expect(find.textContaining('修框 ·'), findsOneWidget);
      // 右键画框与相关提示在重框下隐藏：工具条与底部提示不再写右键画框。
      expect(find.textContaining('右键拖出新框'), findsNothing);
      expect(find.textContaining('不能再画新框'), findsWidgets);
      // 页内几何：用目标框矩形反推页原点与页尺寸。
      final box = find.byKey(const Key('editor-box-q1-box'));
      await tester.ensureVisible(box);
      await tester.pumpAndSettle();
      final boxRect = tester.getRect(box);
      final pageW = boxRect.width / 0.88;
      final pageH = boxRect.height / 0.4;
      final origin = Offset(
        boxRect.left - 0.06 * pageW,
        boxRect.top - 0.05 * pageH,
      );
      // 右键在空白处（右下角，避开只读框）拖出新框：应画不出来。
      final gesture = await tester.startGesture(
        origin + Offset(0.7 * pageW, 0.65 * pageH),
        kind: ui.PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.moveBy(Offset(0.15 * pageW, 0.1 * pageH));
      await gesture.moveBy(Offset(0.05 * pageW, 0.05 * pageH));
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.textContaining('题级框 2'), findsNothing);
      expect(find.textContaining('本页 2 道题'), findsNothing);
      // 触摸拖动同样画不出新框。
      await tester.dragFrom(
        origin + Offset(0.7 * pageW, 0.65 * pageH),
        Offset(0.2 * pageW, 0.15 * pageH),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('题级框 2'), findsNothing);
      // 目标框仍可选中（移动/缩放入口未禁）。
      await tester.tap(box);
      await tester.pumpAndSettle();
      expect(find.textContaining('题级框 1 · 已选中'), findsWidgets);
      // 确认：库里仍只有一个题级框（原框未被顶掉）。
      await tester.runAsync(() async {
        await tester.tap(find.text('确认重新框选'));
        // 十三批 P1-2：applyReworkBoxes 现在 await 入队（确认任务已持久化
        // 才返回），成功提示要等入队落盘才出现；固定 20×200ms 在连跑
        // 时不够（开库慢），改为轮询等提示出现/编辑器关闭，上限 10 秒。
        for (var i = 0; i < 50; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 200));
          if (find.text('已重新框选，切片已更新').evaluate().isNotEmpty ||
              find.textContaining('修框 ·').evaluate().isEmpty) {
            break;
          }
        }
        await tester.pumpAndSettle();
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('修框 ·'), findsNothing);
      final replaced = repo.replacedBoxes['q1'];
      expect(replaced, isNotNull);
      expect(replaced!.where((b) => b.layer == 1).length, 1);
    });
  });

  group('SR3-10/SR3-11 重框崩溃窗口与读图失败', () {
    testWidgets('SR3-10：打开详情页时切片实际尺寸与库里不符，按当前框重裁自愈', (tester) async {
      // 旧切片事先存在：用真实页图字节（560×700）当旧切片内容，
      // 库里记的却是 200×100——模拟事务提交后、rename 前被杀的残留。
      final slicesDir = Directory('${_testTmp.path}/slices');
      slicesDir.createSync(recursive: true);
      final sliceFile = File('${slicesDir.path}/q1.png');
      final oldBytes = File('${_testTmp.path}/$_pagePngRel').readAsBytesSync();
      sliceFile.writeAsBytesSync(oldBytes);
      final repo = detailRepo();
      repo.questions[0] = repo.questions[0].copyWith(
        pageImagePath: _pagePngRel,
        sourcePath: _pagePngRel,
        slicePath: 'slices/q1.png',
        sliceWidth: 200,
        sliceHeight: 100,
      );
      repo.pageBoxes = [
        QuestionBox(
          id: 'q1-box',
          layer: 1,
          type: 'question',
          x: 0.06,
          y: 0.05,
          w: 0.88,
          h: 0.4,
          page: 1,
          questionId: 'q1',
        ),
      ];
      await pumpDetail(tester, repo: repo);
      // 自愈是后台文件 IO + 图片解码，须在 runAsync 内反复 pump +
      // 真实延时推进（同组重框测试的同款做法）。
      await tester.runAsync(() async {
        for (var i = 0; i < 30; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        await tester.pumpAndSettle();
      });
      await tester.pumpAndSettle();
      // 切片已按当前框重裁到新版本文件：left=(0.06×560).round()=34、
      // right=(0.94×560).round()=526 → 宽 492；高 0.4×700=280。
      // 十三批 P1-1：旧文件字节不动（不可变切片），题指到新文件。
      expect(sliceFile.readAsBytesSync(), oldBytes);
      final savedQ = repo.saved.lastWhere((q) => q.id == 'q1');
      expect(savedQ.slicePath, isNot('slices/q1.png'));
      expect(savedQ.slicePath, startsWith('slices/q1-v'));
      final newAbs = AppDatabase.resolveDataPath(savedQ.slicePath!);
      expect(newAbs != null && File(newAbs).existsSync(), isTrue);
      final newBytes = File(newAbs!).readAsBytesSync();
      final size = pngSize(newBytes);
      expect(size.width, 492);
      expect(size.height, 280);
      expect(savedQ.sliceWidth, 492);
      expect(savedQ.sliceHeight, 280);
      expect(tester.takeException(), isNull);
    });

    testWidgets('SR3-11：重框确认时页图读不出来/裁不出来，给提示、不抛异常', (tester) async {
      // 本用例单独的页图文件：先是有效页图（编辑器能打开），
      // 编辑器打开后再写坏——_reworkBoxes 确认时重新读盘即读到坏字节。
      // 切片文件先清掉（同目录的 SR2-3 用例会留下 slices/q1.png），
      // 免得后台自愈在本用例里抢先重裁、干扰断言。
      final slicesDir = Directory('${_testTmp.path}/slices');
      final staleSlice = File('${slicesDir.path}/q1.png');
      if (staleSlice.existsSync()) staleSlice.deleteSync();
      final pageDir = Directory('${_testTmp.path}/imports/rework-task');
      final corruptRel = 'imports/rework-task/corrupt-page.png';
      final corruptFile = File('${pageDir.path}/corrupt-page.png');
      corruptFile.writeAsBytesSync(
        File('${_testTmp.path}/$_pagePngRel').readAsBytesSync(),
      );
      final repo = detailRepo();
      repo.questions[0] = repo.questions[0].copyWith(
        pageImagePath: corruptRel,
        sourcePath: corruptRel,
        slicePath: 'slices/q1.png',
        sliceWidth: 200,
        sliceHeight: 100,
      );
      repo.pageBoxes = [
        QuestionBox(
          id: 'q1-box',
          layer: 1,
          type: 'question',
          x: 0.06,
          y: 0.05,
          w: 0.88,
          h: 0.4,
          page: 1,
          questionId: 'q1',
        ),
      ];
      await pumpDetail(tester, repo: repo);
      await tapText(tester, '重新框选');
      expect(find.textContaining('修框 ·'), findsOneWidget);
      // 先让编辑器的页图加载完成并进图片缓存（真实文件 IO + 解码，
      // 须在 runAsync 内推进），再写坏文件——否则编辑器待决的图片
      // 加载会读到坏字节、报一次框架级解码错误，与被测的回调异常混淆。
      await tester.runAsync(() async {
        for (var i = 0; i < 10; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        await tester.pumpAndSettle();
      });
      await tester.pumpAndSettle();
      // 编辑器打开后把页图写坏（同步 IO，不走 fake async）。
      corruptFile.writeAsBytesSync([0, 1, 2, 3, 4, 5, 6, 7]);
      await tester.runAsync(() async {
        await tester.tap(find.text('确认重新框选'));
        // 十三批 P1-2：applyReworkBoxes 现在 await 入队（确认任务已持久化
        // 才返回），成功提示要等入队落盘才出现；固定 20×200ms 在连跑
        // 时不够（开库慢），改为轮询等提示出现/编辑器关闭，上限 10 秒。
        for (var i = 0; i < 50; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 200));
          if (find.text('已重新框选，切片已更新').evaluate().isNotEmpty ||
              find.textContaining('修框 ·').evaluate().isEmpty) {
            break;
          }
        }
        await tester.pumpAndSettle();
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('修框 ·'), findsNothing);
      expect(find.text('重新框选失败：页图读不出来/切片裁不出来，请重试'), findsOneWidget);
      expect(repo.replaceCalled, isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  group('亮/深 × 三档缩放', () {
    testWidgets('详情页亮/深 × 1.00/1.15/1.30 无溢出', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        for (final scale in [1.0, 1.15, 1.3]) {
          await pumpDetail(tester, brightness: brightness, scale: scale);
          // D1：两 panel 默认展开，答案点「看答案」即显。
          await tapText(tester, '看答案');
          expect(find.text('函数极限'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets('编辑态亮/深 × 1.00/1.15/1.30 无溢出', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        for (final scale in [1.0, 1.15, 1.3]) {
          await pumpDetail(tester, brightness: brightness, scale: scale);
          await tapText(tester, '编辑');
          expect(find.textContaining('正在编辑这道题'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      }
    });
  });

  group('B8-7 重新设计', () {
    testWidgets('D1：题目信息 panel 显示文件夹 + 标签，复习 panel 显示已加入', (tester) async {
      await pumpDetail(tester);
      // 两 panel 默认展开：kv 值与加入状态直接可见。
      expect(find.text('试卷'), findsOneWidget);
      expect(find.text('#易错 #常考'), findsOneWidget);
      expect(find.text('已加入复习'), findsOneWidget);
    });

    testWidgets('D1：题目信息与复习记录默认展开，答案默认隐藏', (tester) async {
      await pumpDetail(tester);
      expect(find.text('学科'), findsOneWidget);
      expect(find.text('错因状态'), findsOneWidget);
      expect(find.text('1'), findsNothing); // 答案 '1' 藏在看答案后
      await tapText(tester, '看答案');
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('默认 A：整题图限高 460', (tester) async {
      await pumpDetail(tester);
      final slice = tester.widget<QuestionSlice>(find.byType(QuestionSlice));
      expect(slice.maxHeight, 460);
    });

    testWidgets('P1-2：小图（占位）按内容高度走，不撑满 460', (tester) async {
      await pumpDetail(tester);
      // 默认 q1 无真实切片，走 sliceText 占位：文字 1 行 + 48 高简图 +
      // 上下 padding，内容高约 96。改前 Center 撑满 460 盒子（审计 P1-2）。
      final size = tester.getSize(find.byType(QuestionSlice));
      expect(size.height, lessThan(200));
      expect(size.height, greaterThan(50));
    });

    testWidgets('P1-2：大图（200×800 真实切片）仍限高 460', (tester) async {
      final repo = detailRepo();
      repo.questions[0] = dtq(
        'q1',
        '函数极限',
        folderIds: const ['f1'],
        slicePath: 'slices/tall.png',
      );
      await pumpDetail(tester, repo: repo, orderIds: const ['q1']);
      // QuestionSlice 用 Image.file + cacheWidth（ResizeImage）：目标尺寸
      // 解码是原生异步，fake async 下只等真实时间不够，要像 SR2-3 那样
      // 在 runAsync 里边 pump 边等，图载入后 IntrinsicHeight 才量到固有高。
      await tester.runAsync(() async {
        for (var i = 0; i < 20; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        await tester.pumpAndSettle();
      });
      await tester.pumpAndSettle();
      // 200×800 按内容宽 1160 等比放大后固有高 4640，盒子应卡在 460。
      final size = tester.getSize(find.byType(QuestionSlice));
      expect(size.height, 460);
    });

    testWidgets('D1：编辑态左列底部显示取消/保存，标题行不再显示归档/删除',
        (tester) async {
      await pumpDetail(tester);
      await tapText(tester, '编辑');
      expect(find.text('保存'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('归档'), findsNothing);
      expect(find.text('删除'), findsNothing);
      expect(find.text('编辑'), findsNothing);
      // 取消/保存在左列底部：备注字段下面。
      final notesRect = tester.getRect(find.text('备注'));
      final saveRect = tester.getRect(find.text('保存'));
      expect(saveRect.top, greaterThan(notesRect.bottom));
    });

    testWidgets('A 紧凑：亮/深 × 1.30 无溢出', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        await pumpDetail(tester, brightness: brightness, scale: 1.3);
        // D1：两 panel 默认展开，答案点「看答案」即显。
        await tapText(tester, '看答案');
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('Win11 反馈包 1：答案区', () {
    Finder editAnswerField() => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '填答案（可以空着）',
    );

    Future<void> pickEditType(
      WidgetTester tester,
      String currentLabel,
      String targetLabel,
    ) async {
      await tester.ensureVisible(find.widgetWithText(QmChip, currentLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(QmChip, currentLabel));
      await tester.pumpAndSettle();
      expect(find.text('选择题型'), findsOneWidget);
      await tester.tap(find.text(targetLabel));
      await tester.pumpAndSettle();
    }

    testWidgets('编辑态单选题：不显示文字答案框，只留字母按钮', (tester) async {
      final repo = FakeDetailRepo(
        questions: [
          dtq(
            'q1',
            '单选函数',
            questionType: 'choice_single',
            optionLabels: const ['A', 'B', 'C', 'D'],
            correctOption: 'B',
            answer: '旧文字答案',
          ),
        ],
      );
      await pumpDetail(tester, repo: repo);
      await tapText(tester, '编辑');
      expect(editAnswerField(), findsNothing);
      expect(find.widgetWithText(QmChip, 'A'), findsOneWidget);
      expect(
        tester.widget<QmChip>(find.widgetWithText(QmChip, 'B')).selected,
        isTrue,
      );
      expect(find.textContaining('文字答案“旧文字答案”已保留'), findsOneWidget);
    });

    testWidgets('编辑态填空题：只留文字答案框，无字母按钮', (tester) async {
      final repo = FakeDetailRepo(
        questions: [
          dtq(
            'q1',
            '填空函数',
            questionType: 'fill_blank',
            answer: 'x=1',
          ),
        ],
      );
      await pumpDetail(tester, repo: repo);
      await tapText(tester, '编辑');
      expect(editAnswerField(), findsOneWidget);
      expect(
        tester.widget<TextField>(editAnswerField()).controller?.text,
        'x=1',
      );
      expect(find.widgetWithText(QmChip, 'A'), findsNothing);
    });

    testWidgets('编辑态题型切换保留答案：单选切填空提示保留，切回单选正确答案仍在', (tester) async {
      final repo = FakeDetailRepo(
        questions: [
          dtq(
            'q1',
            '单选函数',
            questionType: 'choice_single',
            optionLabels: const ['A', 'B', 'C', 'D'],
            correctOption: 'B',
          ),
        ],
      );
      await pumpDetail(tester, repo: repo);
      await tapText(tester, '编辑');
      await pickEditType(tester, '单项选择', '填空题');
      expect(find.textContaining('之前选定的正确答案（B）'), findsOneWidget);
      expect(editAnswerField(), findsOneWidget);
      await pickEditType(tester, '填空题', '单项选择');
      expect(
        tester.widget<QmChip>(find.widgetWithText(QmChip, 'B')).selected,
        isTrue,
      );
      await tapText(tester, '保存', first: true);
      expect(repo.saved.last.correctOption, 'B');
    });
  });
}
