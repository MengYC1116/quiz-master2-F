// 十三批 P1-2 + M4 测试。
//
// 覆盖（任务 a/c/d/e）：
// - a：重框入队失败时框选结果保留 + ocrEnqueueFailed 标志置位（load 后仍
//   可见），重试成功后标志清除、任务落盘；入队成功无标志、任务立即落盘；
//   重试时切片已删按入队契约 null 不算失败。
// - e：acceptOcrCandidateOutcome 五种 reason + 成功 + no_question，
//   OrganizeNotifier 子集，candidateRejectionMessage 文案映射。
// - d：M4 歧义横幅——存在歧义时出现、自动切分/未切分时不出现、队列状态
//   chip 不受横幅影响。
// - c：ocrEnqueueMissedCount 纯函数；confirmSplit 批量入队失败（worker
//   未启动 / worker 已启动）时的提示与 kind。
//
// 注意：本文件是 plain test（真实库、真实 async），不用 widget 的 fake
// async；详情页重框的 widget 测试走 DetailNotifier.enqueueOcrForTest
// 缝（见 detail_page_test.dart 的 setUp），真实入队路径由这里覆盖。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/ocr/ocr_stem_section.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';
import 'package:quiz_master2/services/import_guess.dart';
import 'package:quiz_master2/services/ocr_queue.dart';
import 'package:quiz_master2/state/collect_notifier.dart';
import 'package:quiz_master2/state/detail_notifier.dart';
import 'package:quiz_master2/state/organize_notifier.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/theme/app_theme.dart';

Uint8List _solidPng(int width, int height, int r, int g, int b) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return img.encodePng(image);
}

Question _q(
  String id, {
  String subjectId = 'math',
  String? ocrStem,
  String? ocrRaw,
  String ocrSplitStatus = OcrSplitStatus.unsegmented,
  bool ocrManualEdited = false,
  int contentVersion = 0,
  String? slicePath,
  String? pageImagePath,
  int? sliceWidth,
  int? sliceHeight,
  List<String> folderIds = const [],
  String? answer,
  DateTime? createdAt,
}) => Question(
  id: id,
  title: '题 $id',
  subjectId: subjectId,
  folderIds: folderIds,
  answer: answer,
  createdAt: createdAt ?? DateTime(2026, 11, 8),
  slicePath: slicePath,
  pageImagePath: pageImagePath,
  sliceWidth: sliceWidth,
  sliceHeight: sliceHeight,
  ocrStem: ocrStem,
  ocrRaw: ocrRaw,
  ocrSplitStatus: ocrSplitStatus,
  ocrManualEdited: ocrManualEdited,
  contentVersion: contentVersion,
);

String _raw(
  String md, {
  bool candidate = false,
  List<Object?> layout = const [],
  String? inputHash,
  int? claimedContentVersion,
}) => GlmOcrRawData(
  mdResults: md,
  layoutDetails: layout,
  inputHash: inputHash,
  claimedContentVersion: claimedContentVersion,
  candidateStatus: candidate
      ? OcrCandidateStatus.pending
      : OcrCandidateStatus.none,
).toJsonString();

OcrJob _job(
  String id,
  String questionId,
  OcrJobStatus status, {
  String? lastErrorCode,
  DateTime? availableAt,
  DateTime? createdAt,
}) => OcrJob(
  id: id,
  questionId: questionId,
  status: status,
  lastErrorCode: lastErrorCode,
  availableAt: availableAt,
  createdAt: createdAt ?? DateTime(2026, 11, 18, 12, 0),
  updatedAt: DateTime(2026, 11, 18, 12, 0),
);

class _FakeOrganizeRepo extends QuestionRepository {
  _FakeOrganizeRepo({required this.questions}) : super(AppDatabase.instance);

  List<Question> questions;
  Map<String, List<OcrJob>> jobsByQuestion = const {};
  bool hasKey = true;
  final List<Question> saved = [];

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [];

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<List<String>> tags() async => const [];

  @override
  Future<List<Subject>> subjects() async => Subject.all;

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
  Future<Question?> questionById(String id) async =>
      questions.where((x) => x.id == id).firstOrNull;

  @override
  Future<void> syncCauseRecords(Question question) async {}

  @override
  Future<void> saveRecentTask({
    required String kind,
    required String subjectId,
    required String title,
  }) async {}

  @override
  Future<int> organizedTodayCount({DateTime? now}) async => 0;

  @override
  Future<List<Question>> dueToday({bool includeArchived = false}) async =>
      const [];

  @override
  Future<List<OcrJob>> ocrJobsForQuestion(String questionId) async =>
      List.of(jobsByQuestion[questionId] ?? const []);

  @override
  Future<bool> hasOcrApiKey() async => hasKey;
}

class _FakeDetailRepo extends QuestionRepository {
  _FakeDetailRepo({required this.questions}) : super(AppDatabase.instance);

  List<Question> questions;
  final List<Question> saved = [];
  final List<String> recordedViews = [];
  List<QuestionBox> pageBoxes = [];
  bool replaceCalled = false;

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<Question?> questionById(String id) async =>
      questions.where((x) => x.id == id).firstOrNull;

  @override
  Future<List<CauseRecord>> causeRecordsFor(String questionId) async =>
      const [];

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
    String questionId,
  ) async => const [];

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [];

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<String>> tags() async => const [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

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
  Future<void> recordQuestionViewed(String questionId) async {
    recordedViews.add(questionId);
  }

  @override
  Future<void> syncCauseRecords(Question q) async {}

  @override
  Future<List<OcrJob>> ocrJobsForQuestion(String questionId) async =>
      const [];

  @override
  Future<bool> hasOcrApiKey() async => true;

  @override
  Future<List<QuestionBox>> boxesForPageImage(String pageImagePath) async =>
      List.of(pageBoxes);

  @override
  Future<void> replaceQuestionBoxesAndSlice(
    String questionId,
    List<QuestionBox> boxes, {
    String? slicePath,
    int? sliceWidth,
    int? sliceHeight,
  }) async {
    replaceCalled = true;
    final i = questions.indexWhere((x) => x.id == questionId);
    if (i >= 0) {
      questions[i] = questions[i].copyWith(
        slicePath: slicePath,
        sliceWidth: sliceWidth,
        sliceHeight: sliceHeight,
      );
    }
  }
}

ProviderContainer _organizeContainer(_FakeOrganizeRepo repo) {
  final container = ProviderContainer.test(
    overrides: [repositoryProvider.overrideWithValue(repo)],
  );
  addTearDown(container.dispose);
  container.listen(organizeProvider, (_, __) {});
  return container;
}

ProviderContainer _detailContainer(
  _FakeDetailRepo repo, {
  String questionId = 'q1',
}) {
  final container = ProviderContainer.test(
    overrides: [
      repositoryProvider.overrideWithValue(repo),
      detailInitialProvider.overrideWithValue(
        DetailInitial(questionId: questionId, orderIds: const ['q1']),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.listen(detailProvider, (_, __) {});
  return container;
}

void main() {
  group('P1-2 重框入队失败与重试（真实库）', () {
    late QuizDatabase db;
    late Directory dataDir;
    late String pageRel;

    setUp(() async {
      db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      OcrWorker.resetInstanceForTest();
      dataDir = await Directory.systemTemp.createTemp('qm2-p12-reenqueue-');
      AppDatabase.testDataDirectory = dataDir.path;
      await Directory(p.join(dataDir.path, 'slices')).create(recursive: true);
      await Directory(
        p.join(dataDir.path, 'imports', 'rework-task'),
      ).create(recursive: true);
      pageRel = p.join('imports', 'rework-task', 'page.png');
      await File(
        p.join(dataDir.path, pageRel),
      ).writeAsBytes(_solidPng(560, 700, 200, 200, 200));
      await File(
        p.join(dataDir.path, 'slices', 'q1.png'),
      ).writeAsBytes(_solidPng(100, 50, 10, 20, 30));
    });

    tearDown(() async {
      await AppDatabase.resetForTest();
      if (await dataDir.exists()) await dataDir.delete(recursive: true);
    });

    Question reworkQuestion() => _q(
      'q1',
      ocrStem: '题干',
      pageImagePath: pageRel,
      slicePath: 'slices/q1.png',
      sliceWidth: 100,
      sliceHeight: 50,
    );

    const box = QuestionBox(
      id: 'b1',
      layer: 1,
      type: 'question',
      x: 0.1,
      y: 0.1,
      w: 0.5,
      h: 0.5,
      questionId: 'q1',
    );

    test('入队失败：框选结果保留 + 标志置位；重开库后重试成功，标志清除 + 任务落盘', () async {
      final repo = _FakeDetailRepo(questions:  [reworkQuestion()]);
      final container = _detailContainer(repo);
      final notifier = container.read(detailProvider.notifier);
      await notifier.load();

      // 关库模拟入队写库失败：重框本身的裁片 + 换框走假 repo 与磁盘，
      // 不受关库影响；只有入队一步抛错。
      await db.close();
      final outcome = await notifier.applyReworkBoxes(
        [box],
        p.join(dataDir.path, pageRel),
      );
      // 框选结果保留：返回值仍是 success，框已替换、切片已指新版本文件。
      expect(outcome, ReworkOutcome.success);
      expect(repo.replaceCalled, isTrue);
      final state = container.read(detailProvider);
      expect(state.ocrEnqueueFailed, isTrue);
      expect(state.question?.slicePath, startsWith('slices/q1-v'));

      // 重开库：失败那次确实没有任务落盘（0 条），再重试。
      final db2 = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db2);
      expect(
        await AppDatabase.instance.ocrJobsForQuestion('q1'),
        isEmpty,
      );
      expect(await notifier.retryOcrEnqueue(), isTrue);
      expect(container.read(detailProvider).ocrEnqueueFailed, isFalse);
      final jobs = await AppDatabase.instance.ocrJobsForQuestion('q1');
      expect(jobs.length, 1);
      expect(jobs.single.status, OcrJobStatus.pending);
      expect(jobs.single.cropPath, state.question?.slicePath);
      expect(
        jobs.single.inputHash,
        await sha256HexOfFile(
          File(p.join(dataDir.path, jobs.single.cropPath!)),
        ),
      );
    });

    test('入队成功：无提示标志，任务立即落盘（await 已确认，不用等）', () async {
      final repo = _FakeDetailRepo(questions:  [reworkQuestion()]);
      final container = _detailContainer(repo);
      final notifier = container.read(detailProvider.notifier);
      await notifier.load();
      final outcome = await notifier.applyReworkBoxes(
        [box],
        p.join(dataDir.path, pageRel),
      );
      expect(outcome, ReworkOutcome.success);
      expect(container.read(detailProvider).ocrEnqueueFailed, isFalse);
      final jobs = await AppDatabase.instance.ocrJobsForQuestion('q1');
      expect(jobs.length, 1);
      expect(jobs.single.status, OcrJobStatus.pending);
      expect(jobs.single.cropPath, startsWith('slices/q1-v'));
    });

    test('重试时切片已删：按入队契约 null 不算失败，标志清除', () async {
      final repo = _FakeDetailRepo(questions:  [reworkQuestion()]);
      final container = _detailContainer(repo);
      final notifier = container.read(detailProvider.notifier);
      await notifier.load();
      await db.close();
      final outcome = await notifier.applyReworkBoxes(
        [box],
        p.join(dataDir.path, pageRel),
      );
      expect(outcome, ReworkOutcome.success);
      expect(container.read(detailProvider).ocrEnqueueFailed, isTrue);
      // 新切片文件被删：重试入队返回 null（无切片，不是失败）。
      final newSlice = container.read(detailProvider).question!.slicePath!;
      await File(AppDatabase.resolveDataPath(newSlice)!).delete();
      final db2 = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db2);
      expect(await notifier.retryOcrEnqueue(), isTrue);
      expect(container.read(detailProvider).ocrEnqueueFailed, isFalse);
      expect(
        await AppDatabase.instance.ocrJobsForQuestion('q1'),
        isEmpty,
      );
    });
  });

  group('任务 e 接受失败原因透传', () {
    late QuizDatabase db;
    late Directory dataDir;

    setUp(() async {
      db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      OcrWorker.resetInstanceForTest();
      dataDir = await Directory.systemTemp.createTemp('qm2-p12-accept-');
      AppDatabase.testDataDirectory = dataDir.path;
      await Directory(p.join(dataDir.path, 'slices')).create(recursive: true);
    });

    tearDown(() async {
      await AppDatabase.resetForTest();
      if (await dataDir.exists()) await dataDir.delete(recursive: true);
    });

    Future<String> writeSlice(String name, {int seed = 1}) async {
      final rel = 'slices/$name.png';
      await File(
        p.join(dataDir.path, rel),
      ).writeAsBytes(_solidPng(100, 50, 10 + seed, 20, 30));
      return rel;
    }

    Future<String> sliceHash(String rel) async =>
        sha256HexOfFile(File(p.join(dataDir.path, rel)));

    test('DetailNotifier：成功返回 null；五种 reason 各有其值', () async {
      // 成功：inputHash 与切片一致。
      final slice = await writeSlice('acc-ok');
      final hash = await sliceHash(slice);
      var repo = _FakeDetailRepo(
        questions: [
          _q(
            'q1',
            ocrStem: '旧题干',
            slicePath: slice,
            sliceWidth: 100,
            sliceHeight: 50,
            ocrRaw: _raw(
              '候选\nA. 一\nB. 二',
              candidate: true,
              inputHash: hash,
            ),
            ocrManualEdited: true,
            contentVersion: 2,
          ),
        ],
      );
      // 十三批 P1 第二轮：接受走真实库事务——题先插进真实测试库
      //（Notifier 的 load 仍读 fake 列表；以下各 case 同款）。
      await AppDatabase.upsertQuestionInto(db, repo.questions.single);
      var container = _detailContainer(repo);
      var notifier = container.read(detailProvider.notifier);
      await notifier.load();
      expect((await notifier.acceptOcrCandidateOutcome()).reason, isNull);
      expect(
        container.read(detailProvider).question?.ocrStem,
        '候选',
      );
      expect(
        GlmOcrRawData.tryParse(
          (await AppDatabase.instance.questionById('q1'))?.ocrRaw,
        )?.candidateStatus,
        OcrCandidateStatus.accepted,
      );
      container.dispose();

      // question_deleted：load 后把题从 repo 里删掉。
      final slice2 = await writeSlice('acc-del');
      final hash2 = await sliceHash(slice2);
      repo = _FakeDetailRepo(
        questions: [
          _q(
            'q1',
            slicePath: slice2,
            sliceWidth: 100,
            sliceHeight: 50,
            ocrRaw: _raw('候选', candidate: true, inputHash: hash2),
          ),
        ],
      );
      await AppDatabase.upsertQuestionInto(db, repo.questions.single);
      container = _detailContainer(repo);
      notifier = container.read(detailProvider.notifier);
      await notifier.load();
      repo.questions.removeWhere((q) => q.id == 'q1');
      // 接受读的是真实库：题也要从真实库里删掉，才是“题目已删”。
      await AppDatabase.deleteQuestionFrom(db, 'q1');
      expect(
        (await notifier.acceptOcrCandidateOutcome()).reason,
        'question_deleted',
      );
      container.dispose();

      // no_candidate：无 ocrRaw。
      repo = _FakeDetailRepo(questions: [_q('q1')]);
      await AppDatabase.upsertQuestionInto(db, repo.questions.single);
      container = _detailContainer(repo);
      notifier = container.read(detailProvider.notifier);
      await notifier.load();
      expect((await notifier.acceptOcrCandidateOutcome()).reason, 'no_candidate');
      container.dispose();

      // not_pending：候选已 accepted。
      final slice3 = await writeSlice('acc-twice');
      final hash3 = await sliceHash(slice3);
      final rawAccepted = GlmOcrRawData(
        mdResults: '候选',
        inputHash: hash3,
        candidateStatus: OcrCandidateStatus.accepted,
      ).toJsonString();
      repo = _FakeDetailRepo(
        questions: [
          _q(
            'q1',
            slicePath: slice3,
            sliceWidth: 100,
            sliceHeight: 50,
            ocrRaw: rawAccepted,
          ),
        ],
      );
      await AppDatabase.upsertQuestionInto(db, repo.questions.single);
      container = _detailContainer(repo);
      notifier = container.read(detailProvider.notifier);
      await notifier.load();
      expect((await notifier.acceptOcrCandidateOutcome()).reason, 'not_pending');
      container.dispose();

      // hash_mismatch：inputHash 与切片不一致，库里候选被标 stale。
      final slice4 = await writeSlice('acc-stale');
      repo = _FakeDetailRepo(
        questions: [
          _q(
            'q1',
            slicePath: slice4,
            sliceWidth: 100,
            sliceHeight: 50,
            ocrRaw: _raw('候选', candidate: true, inputHash: '0' * 64),
            ocrManualEdited: true,
            contentVersion: 2,
          ),
        ],
      );
      await AppDatabase.upsertQuestionInto(db, repo.questions.single);
      container = _detailContainer(repo);
      notifier = container.read(detailProvider.notifier);
      await notifier.load();
      expect((await notifier.acceptOcrCandidateOutcome()).reason, 'hash_mismatch');
      // 标 stale 写在真实库里（Notifier 不再经 fake repo.save）。
      expect(
        GlmOcrRawData.tryParse(
          (await AppDatabase.instance.questionById('q1'))?.ocrRaw,
        )?.candidateStatus,
        OcrCandidateStatus.stale,
      );
      container.dispose();

      // slice_missing：切片文件不存在。
      repo = _FakeDetailRepo(
        questions: [
          _q(
            'q1',
            slicePath: 'slices/does-not-exist.png',
            sliceWidth: 100,
            sliceHeight: 50,
            ocrRaw: _raw('候选', candidate: true, inputHash: 'a' * 64),
          ),
        ],
      );
      await AppDatabase.upsertQuestionInto(db, repo.questions.single);
      container = _detailContainer(repo);
      notifier = container.read(detailProvider.notifier);
      await notifier.load();
      expect((await notifier.acceptOcrCandidateOutcome()).reason, 'slice_missing');
      container.dispose();
    });

    test('DetailNotifier：无当前题返回 no_question', () async {
      final repo = _FakeDetailRepo(questions: [_q('q1')]);
      final container = _detailContainer(repo, questionId: 'missing');
      final notifier = container.read(detailProvider.notifier);
      await notifier.load();
      expect(container.read(detailProvider).question, isNull);
      expect((await notifier.acceptOcrCandidateOutcome()).reason, 'no_question');
    });

    test('OrganizeNotifier 子集：成功 / hash_mismatch / no_candidate', () async {
      final slice = await writeSlice('org-ok');
      final hash = await sliceHash(slice);
      var repo = _FakeOrganizeRepo(
        questions: [
          _q(
            'q1',
            ocrStem: '旧题干',
            slicePath: slice,
            sliceWidth: 100,
            sliceHeight: 50,
            ocrRaw: _raw('候选\nA. 一\nB. 二', candidate: true, inputHash: hash),
            ocrManualEdited: true,
            contentVersion: 1,
          ),
        ],
      );
      // 十三批 P1 第二轮：接受走真实库事务——题先插进真实测试库。
      await AppDatabase.upsertQuestionInto(db, repo.questions.single);
      var container = _organizeContainer(repo);
      var notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      expect((await notifier.acceptOcrCandidateOutcome()).reason, isNull);
      expect(container.read(organizeProvider).current?.ocrStem, '候选');
      container.dispose();

      final slice2 = await writeSlice('org-stale');
      repo = _FakeOrganizeRepo(
        questions: [
          _q(
            'q1',
            slicePath: slice2,
            sliceWidth: 100,
            sliceHeight: 50,
            ocrRaw: _raw('候选', candidate: true, inputHash: '0' * 64),
          ),
        ],
      );
      await AppDatabase.upsertQuestionInto(db, repo.questions.single);
      container = _organizeContainer(repo);
      notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      expect((await notifier.acceptOcrCandidateOutcome()).reason, 'hash_mismatch');
      container.dispose();

      repo = _FakeOrganizeRepo(questions: [_q('q1', ocrStem: '题干')]);
      await AppDatabase.upsertQuestionInto(db, repo.questions.single);
      container = _organizeContainer(repo);
      notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      expect((await notifier.acceptOcrCandidateOutcome()).reason, 'no_candidate');
    });

    test('candidateRejectionMessage：每个 reason 都有明确文案', () {
      expect(candidateRejectionMessage('question_deleted'), contains('已被删除'));
      expect(candidateRejectionMessage('no_candidate'), contains('没有待处理'));
      expect(candidateRejectionMessage('not_pending'), contains('已经处理过'));
      expect(candidateRejectionMessage('hash_mismatch'), contains('过期'));
      expect(candidateRejectionMessage('slice_missing'), contains('不存在'));
      expect(candidateRejectionMessage('no_question'), contains('已被删除'));
      expect(candidateRejectionMessage('save_failed'), contains('请重试'));
      expect(candidateRejectionMessage('unknown-reason'), contains('请重试'));
      // 各 reason 文案互不相同（不是同一个通用报错）。
      final messages = {
        'question_deleted',
        'no_candidate',
        'not_pending',
        'hash_mismatch',
        'slice_missing',
      }.map(candidateRejectionMessage).toSet();
      expect(messages.length, 5);
    });
  });

  group('M4 歧义横幅（OcrStemSection）', () {
    Future<void> pumpSection(
      WidgetTester tester, {
      required Question question,
      List<OcrJob> jobs = const [],
      bool hasApiKey = true,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: OcrStemSection(
                question: question,
                jobs: jobs,
                hasApiKey: hasApiKey,
                candidateStemOverride: null,
                sliceBytes: null,
                onSaveEdited: (stem) async => true,
                onAcceptCandidate: (stem) async => true,
                onDismissCandidate: () async {},
                onRerecognize: () async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('存在歧义：显示“识别结果待确认”横幅 + GPT 文案，队列 chip 不变', (
      tester,
    ) async {
      await pumpSection(
        tester,
        question: _q(
          'q1',
          ocrStem: '题干内容',
          ocrSplitStatus: OcrSplitStatus.ambiguous,
        ),
        jobs: [_job('j1', 'q1', OcrJobStatus.completed)],
      );
      expect(find.byKey(const Key('ocr-split-ambiguous-banner')), findsOneWidget);
      expect(find.text('识别结果待确认'), findsOneWidget);
      expect(
        find.text('识别内容包含无法确定的选项边界，请检查题干内容。'),
        findsOneWidget,
      );
      // 独立内容状态：队列七态 chip 仍是“识别完成”，不是歧义。
      expect(find.text('识别完成'), findsOneWidget);
      expect(find.text('切分：存在歧义'), findsOneWidget);
    });

    testWidgets('自动切分：无歧义横幅，识别完成 chip 正常', (tester) async {
      await pumpSection(
        tester,
        question: _q(
          'q1',
          ocrStem: '题干内容',
          ocrSplitStatus: OcrSplitStatus.autoSegmented,
        ),
        jobs: [_job('j1', 'q1', OcrJobStatus.completed)],
      );
      expect(find.byKey(const Key('ocr-split-ambiguous-banner')), findsNothing);
      expect(find.text('识别结果待确认'), findsNothing);
      expect(find.text('识别完成'), findsOneWidget);
    });

    testWidgets('未切分：无歧义横幅', (tester) async {
      await pumpSection(
        tester,
        question: _q(
          'q1',
          ocrStem: '题干内容',
          ocrSplitStatus: OcrSplitStatus.unsegmented,
        ),
        jobs: [_job('j1', 'q1', OcrJobStatus.completed)],
      );
      expect(find.byKey(const Key('ocr-split-ambiguous-banner')), findsNothing);
      expect(find.text('识别结果待确认'), findsNothing);
    });

    testWidgets('存在歧义且无任务：横幅仍出现（不依赖队列状态）', (tester) async {
      await pumpSection(
        tester,
        question: _q(
          'q1',
          ocrStem: '题干内容',
          ocrSplitStatus: OcrSplitStatus.ambiguous,
        ),
      );
      expect(find.byKey(const Key('ocr-split-ambiguous-banner')), findsOneWidget);
      expect(find.text('识别结果待确认'), findsOneWidget);
    });
  });

  group('任务 c 批量入队提示', () {
    late QuizDatabase db;
    late Directory dataDir;

    setUp(() async {
      db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      OcrWorker.resetInstanceForTest();
      dataDir = await Directory.systemTemp.createTemp('qm2-p12-batch-');
      AppDatabase.testDataDirectory = dataDir.path;
      await Directory(
        p.join(dataDir.path, 'imports', 'split-task'),
      ).create(recursive: true);
      await File(
        p.join(dataDir.path, 'imports', 'split-task', 'page.png'),
      ).writeAsBytes(_solidPng(560, 700, 200, 200, 200));
    });

    tearDown(() async {
      OcrWorker.resetInstanceForTest();
      await AppDatabase.resetForTest();
      if (await dataDir.exists()) await dataDir.delete(recursive: true);
    });

    test('ocrEnqueueMissedCount：按 questionId 比对，只数没排上的', () {
      final qs = [_q('q1'), _q('q2'), _q('q3')];
      expect(ocrEnqueueMissedCount(qs, [
        _job('j1', 'q1', OcrJobStatus.pending),
        _job('j2', 'q2', OcrJobStatus.pending),
        _job('j3', 'q3', OcrJobStatus.pending),
      ]), 0);
      expect(ocrEnqueueMissedCount(qs, [
        _job('j1', 'q1', OcrJobStatus.pending),
        _job('j3', 'q3', OcrJobStatus.pending),
      ]), 1);
      expect(ocrEnqueueMissedCount(qs, const []), 3);
      expect(ocrEnqueueMissedCount(const [], const []), 0);
      // 同题重复任务行只算排上一次，不多报也不少报。
      expect(ocrEnqueueMissedCount(qs, [
        _job('j1', 'q1', OcrJobStatus.pending),
        _job('j1b', 'q1', OcrJobStatus.pending),
      ]), 2);
    });

    test('confirmSplit：worker 未启动时 2 道题全未入队，提示带数、kind 仍是 done', () async {
      expect(OcrWorker.instanceOrNull, isNull);
      final task = _splitTask();
      final repo = _FakeSplitRepo(tasks: [task]);
      final container = _collectContainer(repo);
      final notifier = container.read(collectProvider.notifier);
      await notifier.load();
      final outcome = await notifier.confirmSplit(task, {
        1: [_splitBox('b1', 0.1, 0.1), _splitBox('b2', 0.1, 0.4)],
      }, {});
      expect(outcome.kind, ConfirmSplitKind.done);
      expect(repo.questions.length, 2);
      expect(outcome.message, contains('已生成 2 道题，去整理吧'));
      expect(
        outcome.message,
        contains('其中 2 道题 OCR 未入队，可在详情页重新识别。'),
      );
    });

    test('confirmSplit：worker 已启动时全入队，成功提示无未入队后缀', () async {
      final worker = await OcrWorker.ensureStarted(
        database: AppDatabase.instance,
      );
      addTearDown(() async {
        worker.kick();
        await worker.stop();
        OcrWorker.resetInstanceForTest();
      });
      final task = _splitTask();
      final repo = _FakeSplitRepo(tasks: [task]);
      final container = _collectContainer(repo);
      final notifier = container.read(collectProvider.notifier);
      await notifier.load();
      final outcome = await notifier.confirmSplit(task, {
        1: [_splitBox('b1', 0.1, 0.1), _splitBox('b2', 0.1, 0.4)],
      }, {});
      expect(outcome.kind, ConfirmSplitKind.done);
      expect(outcome.message, contains('已生成 2 道题，去整理吧'));
      expect(outcome.message, isNot(contains('未入队')));
      var jobCount = 0;
      for (final q in repo.questions) {
        jobCount += (await AppDatabase.instance.ocrJobsForQuestion(q.id)).length;
      }
      expect(jobCount, 2);
    });
  });
}

CollectTask _splitTask() => CollectTask(
  id: 'split-1',
  name: 'x.png · 第1页 · 第1题',
  fileName: 'x.png',
  subjectId: 'math',
  status: CollectStatus.needBox,
  pageCount: 1,
  page: 1,
  sourcePath: 'imports/split-task/page.png',
);

QuestionBox _splitBox(String id, double x, double y) => QuestionBox(
  id: id,
  layer: 1,
  type: 'question',
  x: x,
  y: y,
  w: 0.5,
  h: 0.2,
  page: 1,
);

class _FakeSplitRepo extends QuestionRepository {
  _FakeSplitRepo({required this.tasks}) : super(AppDatabase.instance);

  List<CollectTask> tasks;
  final List<Question> questions = [];
  final List<CollectTask> splitTasks = [];

  @override
  Future<List<CollectTask>> collectTasks() async => List.of(tasks);

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<List<QuestionBox>> boxesForTask(String taskId) async => const [];

  @override
  Future<void> saveRecentTask({
    required String kind,
    required String subjectId,
    required String title,
  }) async {}

  @override
  Future<void> confirmSplit({
    required CollectTask originalTask,
    required List<Question> questions,
    required List<CollectTask> splitTasks,
    required Map<String, List<QuestionBox>> boxesByQuestionId,
    CollectTask? retainedTask,
    Map<int, List<QuestionBox>> retainedBoxesByPage = const {},
  }) async {
    this.questions.addAll(questions);
    this.splitTasks.addAll(splitTasks);
    tasks.removeWhere((t) => t.id == originalTask.id);
    tasks.addAll(splitTasks);
    if (retainedTask != null) tasks.add(retainedTask);
  }
}

ProviderContainer _collectContainer(_FakeSplitRepo repo) {
  final container = ProviderContainer.test(
    overrides: [repositoryProvider.overrideWithValue(repo)],
  );
  addTearDown(container.dispose);
  container.listen(collectProvider, (_, __) {});
  return container;
}
