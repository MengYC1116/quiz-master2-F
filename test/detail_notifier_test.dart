// ARCH-PLAN-A 第 3 阶段：DetailNotifier 单测（不启动 widget）。
// 注入方式与 review_notifier_test.dart / organize_notifier_test.dart
// 一致：ProviderContainer.test + repositoryProvider.overrideWithValue。
// autoDispose 下单测要像页面 ref.watch 那样持一个监听保活（D-36：
// 只 read 不监听时 build 里的 microtask 首查还没写回就被销毁），
// 见 `_container`。首查直接调 `await notifier.load()`（与 review /
// organize 单测同款），不等 build 里的 microtask。
// 重框与自愈用例用真实 PNG + 磁盘临时目录（与 detail_page_test.dart
// 的 SR2-3 / SR3-10 同款夹具），只测 Notifier 的业务返回值与落盘结果。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/detail_notifier.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/state/review_notifier.dart';

Question _dq(
  String id,
  String title, {
  String subjectId = 'math',
  List<String> folderIds = const [],
  String? examId,
  List<String> knowledgePointIds = const [],
  List<String> errorTypes = const [],
  List<String> customErrorTypes = const [],
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
}) => Question(
  id: id,
  title: title,
  subjectId: subjectId,
  folderIds: folderIds,
  examId: examId,
  knowledgePointIds: knowledgePointIds,
  errorTypes: errorTypes,
  customErrorTypes: customErrorTypes,
  tags: tags,
  answer: answer,
  explanation: explanation,
  notes: notes,
  createdAt: createdAt ?? DateTime(2026, 11, 8),
  isOrganized: isOrganized,
  isArchived: isArchived,
  isFavorite: isFavorite,
  reviewJoined: reviewJoined,
  sliceKind: 'limit',
  sliceText: '题：$title',
  sourcePath: sourcePath,
  sourceKind: sourcePath == null ? null : 'image',
  pageImagePath: pageImagePath,
  slicePath: slicePath,
  sliceWidth: sliceWidth,
  sliceHeight: sliceHeight,
  sourcePage: sourcePage,
);

class FakeDetailNotifierRepo extends QuestionRepository {
  FakeDetailNotifierRepo({
    required List<Question> questions,
    List<Folder> folderList = const [],
    List<Exam> examList = const [],
    List<KnowledgePoint> kpList = const [],
    List<String> tagList = const [],
    List<CauseRecord> records = const [],
    List<({String result, DateTime reviewedAt})> history = const [],
    List<Subject>? subjectsValue,
    // FR-09：复查间隔桩（默认 7 天）；`load()` 读它。
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

  /// 十二批功能 4（D-91）：记一次查看的桩——只记 id，不碰真实库
  ///（不覆盖会落到基类读真实 Drift 库，fake async 里永不完成，
  /// 见 D-88；`load()` 里 await 它，挂住会拖死测试）。
  final List<String> recordedViews = [];

  @override
  Future<void> recordQuestionViewed(String questionId) async {
    recordedViews.add(questionId);
  }

  /// 十三批 M5：OCR 状态是 best-effort 加载（不 await）；返回空任务行
  /// 与“无 key”，不碰真实库（见 D-88）。
  @override
  Future<List<OcrJob>> ocrJobsForQuestion(String questionId) async =>
      const [];

  @override
  Future<bool> hasOcrApiKey() async => false;

  final List<Question> saved = [];
  final List<String> deletedIds = [];
  int syncCauseRecordsCalls = 0;

  /// 最近一次 replaceQuestionBoxesAndSlice 收到的框（按题 id）。
  final Map<String, List<QuestionBox>> replacedBoxes = {};

  /// SR2-3：事务失败桩——置真时 replaceQuestionBoxesAndSlice 抛错，
  /// 且不记框、不存题（与真实事务回滚语义对齐）。
  bool replaceShouldThrow = false;
  bool replaceCalled = false;

  /// P2 §1.5.1 重框 / SR3-10 自愈用：同页全部框（目标题 + 他题），测试里预置。
  List<QuestionBox> pageBoxes = [];

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);

  @override
  Future<Question?> questionById(String id) async =>
      questions.where((q) => q.id == id).firstOrNull;

  // 二十五批：DetailNotifier.load() 经 _refreshRelated 调 all() +
  // causeRecords()；不覆写会落到基类在 _testTmp 里真开库、连接一直
  // 占着，Windows 上 tearDownAll 删目录报 errno 32。直接读内存列表。
  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

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

  @override
  Future<void> syncCauseRecords(Question q) async {
    syncCauseRecordsCalls++;
  }

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

  @override
  Future<List<QuestionBox>> boxesForPageImage(String pageImagePath) async =>
      List.of(pageBoxes);

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

FakeDetailNotifierRepo _repo() {
  final now = DateTime.now();
  return FakeDetailNotifierRepo(
    questions: [
      _dq(
        'q1',
        '函数极限',
        folderIds: const ['f1'],
        examId: 'e1',
        knowledgePointIds: const ['k1'],
        errorTypes: const ['概念不清'],
        customErrorTypes: const ['审题失误'],
        tags: const ['易错'],
        answer: '1',
        explanation: 'lim(x→0) sin3x/x = 3。',
        isFavorite: true,
        reviewJoined: true,
      ),
      _dq('q2', '导数应用综合', errorTypes: const ['方法不会']),
      _dq('q3', '定积分阴影面积', isOrganized: false),
      _dq('q5', '无错因题'),
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
    ],
    tagList: const ['易错', '常考'],
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
/// reviewSchedulerProvider 注入；`load()` 的 FSRS 状态是 best-effort
/// 异步读，不注入会走默认 SQLite 调度器（真实库，D-88 同款）。
FsrsReviewScheduler _testScheduler() => FsrsReviewScheduler(
  config: const SchedulerConfig(enableFuzzing: false),
  store: InMemoryCardStore(),
);

ProviderContainer _container(
  FakeDetailNotifierRepo repo, {
  String questionId = 'q1',
  List<String> orderIds = const ['q1', 'q2', 'q3'],
  // FSRS 口径迁移（面 B）：预置卡片的调度器（未开始/已开始场景用）；
  // 不传时用空内存调度器（不在池里）。
  FsrsReviewScheduler? scheduler,
}) {
  final container = ProviderContainer.test(
    overrides: [
      repositoryProvider.overrideWithValue(repo),
      reviewSchedulerProvider.overrideWithValue(
        scheduler ?? _testScheduler(),
      ),
      detailInitialProvider.overrideWithValue(
        DetailInitial(questionId: questionId, orderIds: orderIds),
      ),
    ],
  );
  addTearDown(container.dispose);
  // autoDispose 保活（D-36）：像页面 ref.watch 那样持一个监听，
  // 否则 build 里的 microtask 首查还没写回就被销毁。
  container.listen(detailProvider, (_, __) {});
  return container;
}

DetailNotifier _notifier(ProviderContainer container) =>
    container.read(detailProvider.notifier);

/// 重框 / 自愈夹具：560×700 真实页图（与 detail_page_test.dart 同款）。
late final Directory _testTmp;
late final String _pagePngRel;

({int width, int height}) _pngSize(List<int> bytes) {
  int be32(int at) =>
      (bytes[at] << 24) |
      (bytes[at + 1] << 16) |
      (bytes[at + 2] << 8) |
      bytes[at + 3];
  return (width: be32(16), height: be32(20));
}

void main() {
  // 重框 / 自愈要走 `evictCachedFileImage`（PaintingBinding.imageCache），
  // 纯 `test()` 里须先初始化 binding（widget 测试里本就已初始化）。
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    _testTmp = await Directory.systemTemp.createTemp('qm2-detail-notifier');
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
    await File('${pageDir.path}/page.png')
        .writeAsBytes(png!.buffer.asUint8List());
    _pagePngRel = 'imports/rework-task/page.png';
    AppDatabase.testDataDirectory = _testTmp.path;
  });

  tearDownAll(() async {
    // 二十五批：先清图片缓存（重框/自愈走 evictCachedFileImage，
    // FileImage mmap 占着页图/切片）+ 关掉 _refreshRelated 真开过
    // 的库连接，再删目录；否则 Windows 上删目录报 errno 32。
    // resetForTest 把 testDataDirectory 重指全新临时目录（D-260，不再置 null）。
    TestWidgetsFlutterBinding.instance.imageCache.clear();
    await AppDatabase.resetForTest();
    // Windows 上删目录时可能仍有句柄未释放（errno 32）：重试 5 次。
    for (var i = 0; i < 5; i++) {
      try {
        await _testTmp.delete(recursive: true);
        break;
      } catch (_) {
        if (i == 4) break;
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  });

  group('load', () {
    test('读库进 state：当前题 + 错因记录 + 解决记录 + 元数据', () async {
      final repo = _repo();
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      final st = container.read(detailProvider);
      expect(st.loading, isFalse);
      expect(st.question?.id, 'q1');
      expect(st.question?.title, '函数极限');
      expect(st.records.length, 1);
      expect(st.records.first.cause, '概念不清');
      expect(st.history.length, 2);
      expect(st.exams.length, 1);
      expect(st.folders.length, 2);
      expect(st.allTags, ['易错', '常考']);
      expect(st.kps.length, 1);
      expect(st.subjects, isNotEmpty);
      expect(st.orderIds, ['q1', 'q2', 'q3']);
      expect(st.currentId, 'q1');
    });

    test('题不存在：question 为 null，loading 照常结束', () async {
      final repo = _repo();
      final container = _container(repo, questionId: 'no-such');
      final notifier = _notifier(container);
      await notifier.load();
      final st = container.read(detailProvider);
      expect(st.loading, isFalse);
      expect(st.question, isNull);
      expect(st.records, isEmpty);
      expect(st.history, isEmpty);
    });

    test('subjectOf：库里学科用库里的名与色，找不到回退 Subject.byId', () async {
      final repo = _repo();
      final container = _container(repo);
      await _notifier(container).load();
      final st = container.read(detailProvider);
      expect(st.subjectOf('math').name, '数学');
      expect(st.subjectOf('no-such').name, '数学');
    });
  });

  group('FSRS 口径复习状态（面 B）', () {
    // 一条作答夹具：默认正式复习（mode = 到期复习）。
    AttemptData attempt(
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

    // load() 的 FSRS 状态是 best-effort 异步读（不 await）：等它填入
    // 再断言；1s 内未填入即失败，不静默跳过。
    Future<DetailReviewStatus> waitReviewStatus(
      DetailNotifier notifier,
    ) async {
      for (var i = 0; i < 100; i++) {
        final s = notifier.state.reviewStatus;
        if (s != null) return s;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      throw StateError('reviewStatus 未在 1s 内填入');
    }

    test('文案纯函数：未加入 / 未开始 / 下次到期 + 有无正式记录', () {
      const notInPool = DetailReviewStatus(
        inPool: false,
        formalCorrect: 0,
        formalWrong: 0,
      );
      expect(reviewDueLabel(notInPool), '未加入复习');
      expect(reviewFormalLabel(notInPool), '暂无正式复习记录');
      const notStarted = DetailReviewStatus(
        inPool: true,
        formalCorrect: 0,
        formalWrong: 0,
      );
      expect(reviewDueLabel(notStarted), '未开始');
      const due = DetailReviewStatus(
        inPool: true,
        nextDueAt: null,
        formalCorrect: 2,
        formalWrong: 1,
      );
      // nextDueAt 为空时仍按在池未开始显示，与正式对错无关。
      expect(reviewDueLabel(due), '未开始');
      expect(reviewFormalLabel(due), '正式复习答对 2 次 · 答错 1 次');
    });

    test('不在池里、无正式记录 → 未加入复习 + 暂无正式复习记录', () async {
      final repo = _repo();
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      final s = await waitReviewStatus(notifier);
      expect(s.inPool, isFalse);
      expect(s.nextDueAt, isNull);
      expect(s.formalCorrect, 0);
      expect(s.formalWrong, 0);
      expect(reviewDueLabel(s), '未加入复习');
      expect(reviewFormalLabel(s), '暂无正式复习记录');
    });

    test('在池里、未开始正式复习 → 未开始', () async {
      final repo = _repo()..poolIdsValue = {'q1'};
      final scheduler = _testScheduler();
      await scheduler.initializeQuestion('q1');
      final container = _container(repo, scheduler: scheduler);
      final notifier = _notifier(container);
      await notifier.load();
      final s = await waitReviewStatus(notifier);
      expect(s.inPool, isTrue);
      expect(s.nextDueAt, isNull);
      expect(reviewDueLabel(s), '未开始');
    });

    test('已开始正式复习 → 下次到期 M月M日（与调度器同一值）', () async {
      final repo = _repo()..poolIdsValue = {'q1'};
      final scheduler = _testScheduler();
      await scheduler.initializeQuestion('q1');
      await scheduler.recordAnswer(
        'q1',
        ReviewResult.good,
        DateTime.now(),
        'evt-q1-good',
      );
      final container = _container(repo, scheduler: scheduler);
      final notifier = _notifier(container);
      await notifier.load();
      final s = await waitReviewStatus(notifier);
      final due = await scheduler.nextDueAt('q1');
      expect(due, isNotNull);
      expect(s.nextDueAt, due);
      expect(reviewDueLabel(s), '下次到期 ${due!.month}月${due.day}日');
    });

    test('正式对错按作答次数计：专项与未判分不计，他题不计', () async {
      final repo = _repo()
        ..poolIdsValue = {'q1'}
        ..attemptsValue = [
          attempt('q1', correct: 1, session: 's1'),
          attempt('q1', correct: 1, session: 's2'),
          attempt('q1', correct: 0, session: 's3'),
          // 专项练习不计。
          attempt('q1', mode: ReviewMode.practice, correct: 1, session: 's4'),
          // 未判分（correct 为空）不计。
          attempt('q1', session: 's5'),
          // 他题不计。
          attempt('q2', correct: 1, session: 's6'),
        ];
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      final s = await waitReviewStatus(notifier);
      expect(s.formalCorrect, 2);
      expect(s.formalWrong, 1);
      expect(reviewFormalLabel(s), '正式复习答对 2 次 · 答错 1 次');
    });
  });

  group('编辑表单', () {
    test('enterEdit：按当前题重建表单值，formResetKey 加一', () async {
      final repo = _repo();
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      final before = container.read(detailProvider).formResetKey;
      notifier.enterEdit();
      final st = container.read(detailProvider);
      expect(st.formResetKey, before + 1);
      expect(st.editBase?.id, 'q1');
      expect(st.editErrorTypes, {'概念不清', '审题失误'});
      expect(st.editCustomTypes, isEmpty);
      expect(st.editFolders, {'f1'});
      expect(st.editTags, {'易错'});
      expect(st.editKps, {'k1'});
      expect(st.editExamId, 'e1');
    });

    test('enterEdit：SR-P2-27 与固定枚举同名的自定义错因合并进固定项', () async {
      final repo = _repo();
      repo.questions[0] = repo.questions[0].copyWith(
        errorTypes: const [],
        customErrorTypes: const ['概念不清', '自己总结的'],
      );
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      notifier.enterEdit();
      final st = container.read(detailProvider);
      expect(st.editErrorTypes, {'概念不清'});
      expect(st.editCustomTypes, {'自己总结的'});
    });

    test('saveEdit：标题/答案/解析/备注写库，同步错因记录，图片字段不抹', () async {
      final repo = _repo();
      repo.questions[0] = repo.questions[0].copyWith(
        sourcePath: 'imports/x/page.png',
        pageImagePath: _pagePngRel,
        slicePath: 'slices/q1.png',
        sliceWidth: 100,
        sliceHeight: 50,
      );
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      notifier.enterEdit();
      notifier.toggleEditFolder('f2');
      await notifier.saveEdit(
        title: '函数极限（改）',
        answer: '3',
        explanation: '新解析',
        notes: '笔记',
      );
      final savedQ = repo.saved.lastWhere((q) => q.id == 'q1');
      expect(savedQ.title, '函数极限（改）');
      expect(savedQ.answer, '3');
      expect(savedQ.explanation, '新解析');
      expect(savedQ.notes, '笔记');
      expect(savedQ.folderIds, containsAll(['f1', 'f2']));
      expect(savedQ.sourcePath, 'imports/x/page.png');
      expect(savedQ.pageImagePath, _pagePngRel);
      expect(savedQ.slicePath, 'slices/q1.png');
      expect(savedQ.sliceWidth, 100);
      expect(repo.syncCauseRecordsCalls, 1);
      expect(container.read(detailProvider).question?.title, '函数极限（改）');
    });

    test('saveEdit：空标题保留原标题，空答案/解析/备注存 null', () async {
      final repo = _repo();
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      notifier.enterEdit();
      await notifier.saveEdit(
        title: '   ',
        answer: '',
        explanation: '  ',
        notes: '',
      );
      final savedQ = repo.saved.lastWhere((q) => q.id == 'q1');
      expect(savedQ.title, '函数极限');
      expect(savedQ.answer, isNull);
      expect(savedQ.explanation, isNull);
      expect(savedQ.notes, isNull);
    });

    test('saveEdit：无 editBase 时直接返回，不写库', () async {
      final repo = _repo();
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      await notifier.saveEdit(
        title: 'x',
        answer: '',
        explanation: '',
        notes: '',
      );
      expect(repo.saved, isEmpty);
    });
  });

  group('收藏 / 归档 / 加入复习 / 切题 / 删除', () {
    test('toggleFavorite：收藏翻转后重读', () async {
      final repo = _repo();
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      expect(container.read(detailProvider).question?.isFavorite, isTrue);
      await notifier.toggleFavorite();
      expect(container.read(detailProvider).question?.isFavorite, isFalse);
    });

    test('toggleArchive：归档后重读', () async {
      final repo = _repo();
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      await notifier.toggleArchive();
      expect(container.read(detailProvider).question?.isArchived, isTrue);
    });

    test('toggleReviewJoined：无错因题返回 false，不写库', () async {
      final repo = _repo();
      final container = _container(repo, questionId: 'q5');
      final notifier = _notifier(container);
      await notifier.load();
      expect(await notifier.toggleReviewJoined(), isFalse);
      expect(repo.saved, isEmpty);
    });

    test('toggleReviewJoined：有错因题加入成功，再点取消加入', () async {
      final repo = _repo();
      final container = _container(repo, questionId: 'q2');
      final notifier = _notifier(container);
      await notifier.load();
      expect(await notifier.toggleReviewJoined(), isTrue);
      expect(container.read(detailProvider).question?.reviewJoined, isTrue);
      expect(await notifier.toggleReviewJoined(), isTrue);
      expect(container.read(detailProvider).question?.reviewJoined, isFalse);
    });

    test('goTo：切到 q2 并重读', () async {
      final repo = _repo();
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      await notifier.goTo('q2');
      final st = container.read(detailProvider);
      expect(st.currentId, 'q2');
      expect(st.question?.title, '导数应用综合');
    });

    test('deleteCurrent：有下一题时返回下一题 id，来源列表去掉已删题', () async {
      final repo = _repo();
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      expect(await notifier.deleteCurrent(), 'q2');
      expect(repo.deletedIds, ['q1']);
      final st = container.read(detailProvider);
      expect(st.orderIds, ['q2', 'q3']);
      expect(st.currentId, 'q2');
      expect(st.question?.id, 'q2');
    });

    test('deleteCurrent：末题返回 null', () async {
      final repo = _repo();
      final container = _container(
        repo,
        questionId: 'q3',
        orderIds: const ['q1', 'q2', 'q3'],
      );
      final notifier = _notifier(container);
      await notifier.load();
      expect(await notifier.deleteCurrent(), isNull);
      expect(repo.deletedIds, ['q3']);
      expect(container.read(detailProvider).orderIds, ['q1', 'q2']);
    });
  });

  group('内联新建', () {
    test('submitNewTag：写库后重读并选进编辑表单', () async {
      final repo = _repo();
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      notifier.enterEdit();
      await notifier.submitNewTag('高频');
      final st = container.read(detailProvider);
      expect(repo.tagList, contains('高频'));
      expect(st.allTags, contains('高频'));
      expect(st.editTags, contains('高频'));
    });

    test('submitNewFolder：新建进库并选进编辑表单；整科同名返回 null', () async {
      final repo = _repo();
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      notifier.enterEdit();
      final id = await notifier.submitNewFolder('模拟卷', null);
      expect(id, isNotNull);
      expect(repo.folderList.any((f) => f.id == id), isTrue);
      expect(container.read(detailProvider).editFolders, contains(id));
      expect(await notifier.submitNewFolder('试卷', null), isNull);
    });

    test('submitNewKnowledgePoint / submitNewExam：新建并选进编辑表单', () async {
      final repo = _repo();
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      notifier.enterEdit();
      final kpId = await notifier.submitNewKnowledgePoint(
        '第一章 函数与极限',
        '极限运算法则',
      );
      expect(repo.kpList.any((k) => k.id == kpId), isTrue);
      expect(container.read(detailProvider).editKps, contains(kpId));
      final examId = await notifier.submitNewExam('期中试卷');
      expect(repo.examList.any((e) => e.id == examId), isTrue);
      expect(container.read(detailProvider).editExamId, examId);
    });

    test('addCustomType：固定同名返回 true 并选中固定项；自定义返回 false', () async {
      final repo = _repo();
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      notifier.enterEdit();
      expect(notifier.addCustomType('概念不清'), isTrue);
      expect(
        container.read(detailProvider).editCustomTypes,
        isNot(contains('概念不清')),
      );
      expect(notifier.addCustomType('粗心大意'), isFalse);
      expect(container.read(detailProvider).editCustomTypes, contains('粗心大意'));
    });
  });

  group('重新框选 §1.5.1', () {
    QuestionBox box(String id, String qid) => QuestionBox(
      id: id,
      layer: 1,
      type: 'question',
      x: 0.06,
      y: 0.05,
      w: 0.88,
      h: 0.4,
      page: 1,
      questionId: qid,
    );

    test('applyReworkBoxes 成功：框替换、切片重裁落盘', () async {
      final repo = _repo();
      repo.questions[0] = repo.questions[0].copyWith(
        pageImagePath: _pagePngRel,
        sourcePath: _pagePngRel,
        slicePath: 'slices/q1.png',
        sliceWidth: 200,
        sliceHeight: 100,
      );
      repo.pageBoxes = [box('q1-box', 'q1'), box('q2-box', 'q2')];
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      final pageAbs = AppDatabase.resolveDataPath(_pagePngRel)!;
      final outcome = await notifier.applyReworkBoxes([
        box('q1-box', 'q1'),
      ], pageAbs);
      expect(outcome, ReworkOutcome.success);
      expect(repo.replacedBoxes['q1']?.length, 1);
      final savedQ = repo.saved.lastWhere((q) => q.id == 'q1');
      expect(savedQ.sliceWidth, 492);
      expect(savedQ.sliceHeight, 280);
      final sliceAbs = AppDatabase.resolveDataPath(savedQ.slicePath!);
      expect(sliceAbs != null && File(sliceAbs).existsSync(), isTrue);
    });

    test('SR2-3：事务失败返回 saveFailed，旧切片字节完好、框与题不动', () async {
      final slicesDir = Directory('${_testTmp.path}/slices');
      await slicesDir.create(recursive: true);
      final oldSliceFile = File('${slicesDir.path}/q1.png');
      final oldBytes = File('${_testTmp.path}/$_pagePngRel').readAsBytesSync();
      await oldSliceFile.writeAsBytes(oldBytes);
      final repo = _repo();
      repo.questions[0] = repo.questions[0].copyWith(
        pageImagePath: _pagePngRel,
        sourcePath: _pagePngRel,
        slicePath: 'slices/q1.png',
        sliceWidth: 560,
        sliceHeight: 700,
      );
      repo.pageBoxes = [box('q1-box', 'q1')];
      repo.replaceShouldThrow = true;
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      repo.saved.clear();
      final pageAbs = AppDatabase.resolveDataPath(_pagePngRel)!;
      final outcome = await notifier.applyReworkBoxes([
        box('q1-box', 'q1'),
      ], pageAbs);
      expect(outcome, ReworkOutcome.saveFailed);
      expect(repo.replaceCalled, isTrue);
      expect(oldSliceFile.readAsBytesSync(), equals(oldBytes));
      expect(
        slicesDir.listSync().where((f) => f.path.contains('.tmp-')).isEmpty,
        isTrue,
      );
      expect(repo.replacedBoxes.containsKey('q1'), isFalse);
      expect(repo.saved.where((q) => q.id == 'q1'), isEmpty);
    });

    test('SR3-11：页图损坏返回 cropFailed，不调事务', () async {
      final corruptFile = File('${_testTmp.path}/imports/rework-task/bad.png');
      await corruptFile.writeAsBytes([0, 1, 2, 3, 4, 5, 6, 7]);
      final repo = _repo();
      repo.questions[0] = repo.questions[0].copyWith(
        pageImagePath: 'imports/rework-task/bad.png',
        sourcePath: 'imports/rework-task/bad.png',
        slicePath: 'slices/q1.png',
        sliceWidth: 200,
        sliceHeight: 100,
      );
      repo.pageBoxes = [box('q1-box', 'q1')];
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      final outcome = await notifier.applyReworkBoxes([
        box('q1-box', 'q1'),
      ], corruptFile.path);
      expect(outcome, ReworkOutcome.cropFailed);
      expect(repo.replaceCalled, isFalse);
    });
  });

  group('SR3-10 切片自愈', () {
    test('打开页时切片尺寸与库里不符，按当前框重裁自愈', () async {
      final slicesDir = Directory('${_testTmp.path}/slices');
      await slicesDir.create(recursive: true);
      final sliceFile = File('${slicesDir.path}/q1.png');
      final oldBytes = File('${_testTmp.path}/$_pagePngRel').readAsBytesSync();
      await sliceFile.writeAsBytes(oldBytes);
      final repo = _repo();
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
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      // 自愈是后台异步修复：轮询等它把库里尺寸改成重裁尺寸。
      var healed = false;
      for (var i = 0; i < 50 && !healed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        healed = repo.saved.any((q) => q.id == 'q1' && q.sliceWidth == 492);
      }
      expect(healed, isTrue);
      final savedQ = repo.saved.lastWhere((q) => q.id == 'q1');
      // 十三批 P1-1 不可变切片：自愈写版本化新文件，库里 slice_path
      // 指过去；旧文件字节永不动，不再是原地覆盖后的 492×280。
      expect(savedQ.slicePath, isNot('slices/q1.png'));
      expect(savedQ.slicePath?.startsWith('slices/q1-v'), isTrue);
      expect(savedQ.sliceWidth, 492);
      expect(savedQ.sliceHeight, 280);
      final newSliceFile = File('${_testTmp.path}/${savedQ.slicePath}');
      expect(_pngSize(newSliceFile.readAsBytesSync()).width, 492);
      expect(_pngSize(newSliceFile.readAsBytesSync()).height, 280);
      // 旧文件仍是原来的页图字节（560×700），一个字节都没变。
      expect(sliceFile.readAsBytesSync(), equals(oldBytes));
      expect(_pngSize(sliceFile.readAsBytesSync()).width, 560);
      expect(_pngSize(sliceFile.readAsBytesSync()).height, 700);
    });
  });
}
