// Win11 反馈包 2：取消识别（TDD，先写失败测试，再写实现）。
//
// 覆盖：
// - 服务层 cancelOcrForQuestion：排队中 / 识别中（迟到结果丢弃）/
//   已完成（OCR 字段清掉、裁图进回收站、切片保留）/ 失败·重试中
//   （任务行清掉）；人工改过题干的确认后清除；manual 题型与文件夹/
//   标签/错因/答案保留、auto 题型清除；幂等；不存在的题；取消后重
//   新识别（新代次，旧结果不再写回）。
// - applyClaimedResult 迟到写回守门：任务已取消 / 租约已丢时不写题目。
// - deriveOcrStemStatus：最新任务 cancelled → “未识别，仅保留图片”。
// - OcrStemSection：取消识别按钮的显隐、人工改过时先弹确认。
// - 两页端到端：整理页 / 详情页点取消识别 → 落库 + 状态切换。
//
// 基建照抄 b14_win11_pkg3_wiring_test.dart（真实库 + 真实文件系统，
// 不调真实接口）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/file_lifecycle_guard.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/detail/question_detail_page.dart';
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/modules/ocr/ocr_stem_section.dart';
import 'package:quiz_master2/modules/ocr/ocr_stem_status.dart';
import 'package:quiz_master2/modules/organize/organize_page.dart';
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

const _figureTransform = OcrRequestTransform(
  srcW: 100,
  srcH: 50,
  reqW: 100,
  reqH: 50,
  padX: 0,
  padY: 0,
);

/// 带题目插图块的 raw 包（默认一个图块，请求坐标 [10, 5, 60, 25]）。
GlmOcrRawData figureRaw({
  String? inputHash,
  OcrCandidateStatus status = OcrCandidateStatus.none,
  List<List<int>> imageBboxes = const [
    [10, 5, 60, 25],
  ],
}) {
  final mdRefs = imageBboxes
      .map((b) => '![](page=0,bbox=[${b.join(', ')}])')
      .join('\n\n');
  return GlmOcrRawData(
    mdResults:
        '看图求值\n\n$mdRefs\n\nA. 第一项\nB. 第二项\nC. 第三项\nD. 第四项',
    layoutDetails: [
      [
        for (var i = 0; i < imageBboxes.length; i++)
          {
            'bbox_2d': imageBboxes[i],
            'label': 'image',
            'native_label': 'image',
            'width': 100,
            'height': 50,
            'index': i,
          },
        {
          'bbox_2d': [0, 0, 100, 50],
          'label': 'text',
          'native_label': 'text',
          'width': 100,
          'height': 50,
          'index': imageBboxes.length,
          'content': '看图求值',
        },
      ],
    ],
    transform: _figureTransform,
    inputHash: inputHash,
    candidateStatus: status,
  );
}

GlmOcrResult figureResult({
  String? inputHash,
  List<List<int>> imageBboxes = const [
    [10, 5, 60, 25],
  ],
}) => GlmOcrResult(
  markdown:
      '看图求值\n\n${imageBboxes.map((b) => '![](page=0,bbox=[${b.join(', ')}])').join('\n\n')}\n\nA. 第一项\nB. 第二项\nC. 第三项\nD. 第四项',
  rawData: figureRaw(
    inputHash: inputHash,
    imageBboxes: imageBboxes,
  ),
  totalTokens: 10,
);

void main() {
  late QuizDatabase db;
  late Directory dataDir;
  late QuestionRepository repo;
  late _MemoryKeyBackend keyBackend;
  late DateTime fakeNow;

  DateTime clock() => fakeNow;

  Future<String> writeSlice(String name, {int seed = 1}) async {
    final image = img.Image(width: 100, height: 50);
    img.fill(image, color: img.ColorRgb8(10 + seed, 20, 30));
    final bytes = img.encodePng(image);
    final rel = 'slices/$name.png';
    final abs = p.join(dataDir.path, rel);
    await File(abs).parent.create(recursive: true);
    await File(abs).writeAsBytes(bytes);
    return rel;
  }

  Future<Question> insertQuestion({
    required String id,
    String? slicePath,
    int contentVersion = 0,
    bool ocrManualEdited = false,
    String? ocrStem,
    String? ocrRaw,
    String ocrSplitStatus = OcrSplitStatus.unsegmented,
    List<OcrFigure> figures = const [],
    String? questionType,
    String questionTypeSource = 'unclassified',
    String questionBackgroundTags = '',
    String questionBackgroundTagsSource = 'unclassified',
    Map<String, String>? optionContents,
    int? optionContentsParserVersion,
    List<String> folderIds = const [],
    List<String> tags = const [],
    List<String> errorTypes = const [],
    String? answer,
    int? sliceWidth,
    int? sliceHeight,
  }) async {
    final q = Question(
      id: id,
      title: '题 $id',
      subjectId: 'math',
      createdAt: DateTime(2026, 11, 18),
      slicePath: slicePath,
      ocrManualEdited: ocrManualEdited,
      ocrStem: ocrStem,
      ocrRaw: ocrRaw,
      ocrSplitStatus: ocrSplitStatus,
      ocrFigures: encodeOcrFigures(figures),
      questionType: questionType,
      questionTypeSource: questionTypeSource,
      questionBackgroundTags: questionBackgroundTags,
      questionBackgroundTagsSource: questionBackgroundTagsSource,
      optionContents: optionContents,
      optionContentsParserVersion: optionContentsParserVersion,
      folderIds: folderIds,
      tags: tags,
      errorTypes: errorTypes,
      answer: answer,
      sliceWidth: sliceWidth,
      sliceHeight: sliceHeight,
      contentVersion: contentVersion,
    );
    await AppDatabase.upsertQuestionInto(db, q);
    return q;
  }

  Future<Question> reload(String id) async {
    final row = await repo.questionById(id);
    return row!;
  }

  OcrWorker workerWith(OcrRecognizer recognizer) => OcrWorker(
    database: AppDatabase.instance,
    keyStore: OcrKeyStore(backend: keyBackend),
    recognizer: recognizer,
    clock: clock,
  );

  setUp(() async {
    fakeNow = DateTime(2026, 11, 18, 12, 0, 0);
    db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(db);
    repo = QuestionRepository(AppDatabase.instance);
    // FR-45 后续（slices 污染）：同 b13_p1_1——D-260 前 tearDown 的
    // resetForTest() 置 null，从第 2 个测试起 dataDirectoryPath() 读到
    // 真实目录，切片写进真实 slices/（P3 批量 2 实测本文件 +3、.trash
    // +4）；D-260 起 reset 改为重指全新临时目录，该窗口已堵上。setUp
    // 仍先给 testDataDirectory 指全新临时目录，再读路径。
    final tmpDataDir = await Directory.systemTemp.createTemp('qm2-pkg2-');
    AppDatabase.testDataDirectory = tmpDataDir.path;
    dataDir = Directory(AppDatabase.dataDirectoryPath());
    await dataDir.create(recursive: true);
    keyBackend = _MemoryKeyBackend();
    await OcrKeyStore(backend: keyBackend).setApiKey('fake-test-key');
    FileLifecycleGuard.instance.debugClearPendingForTest();
    FileLifecycleGuard.instance.debugClearStagingForTest();
    OcrWorker.resetInstanceForTest();
  });

  tearDown(() async {
    OcrWorker.resetInstanceForTest();
    FileLifecycleGuard.instance.debugClearPendingForTest();
    FileLifecycleGuard.instance.debugClearStagingForTest();
    await AppDatabase.resetForTest();
    // setUp 指的临时数据目录用完即删，不留残留。
    try {
      if (await dataDir.exists()) await dataDir.delete(recursive: true);
    } catch (_) {}
  });

  group('cancelOcrForQuestion 服务层', () {
    test('取消排队中的任务：任务标 cancelled，不再被领走，可重新入队', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(_FakeRecognizer([figureResult()]));
      final job = (await worker.enqueueForQuestion(q))!;
      expect(job.status, OcrJobStatus.pending);

      final code = await cancelOcrForQuestion(AppDatabase.instance, 'q1');
      expect(code, 'cancelled');
      final jobs = await AppDatabase.instance.ocrJobsForQuestion('q1');
      expect(jobs.single.status, OcrJobStatus.cancelled);
      expect(jobs.single.leaseToken, isNull);
      expect(jobs.single.completedAt, isNotNull);
      // 取消后无可领任务；重新入队建新行（不与已取消的行去重冲突）。
      expect(
        await AppDatabase.instance.claimNextOcrJob(
          leaseDuration: ocrLeaseDuration,
          now: fakeNow,
        ),
        isNull,
      );
      final again = (await worker.enqueueForQuestion(q))!;
      expect(again.id, isNot(job.id));
      expect(again.status, OcrJobStatus.pending);
    });

    test('取消已完成的任务：OCR 字段清掉，裁图进回收站，切片保留', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(_FakeRecognizer([figureResult()]));
      await worker.enqueueForQuestion(q);
      expect(await worker.processOne(), isTrue);
      final done = await reload('q1');
      expect(done.ocrStem, isNotNull);
      expect(done.ocrStem, isNotEmpty);
      expect(done.questionType, 'choice_single');
      expect(done.questionTypeSource, 'auto');
      expect(done.optionContents, isNotNull);
      final figsBefore = parseOcrFigures(done.ocrFigures);
      expect(figsBefore, isNotEmpty);
      final cropPaths = [
        for (final f in figsBefore)
          if (f.cropPath.isNotEmpty) f.cropPath,
      ];
      expect(cropPaths, isNotEmpty);
      for (final c in cropPaths) {
        expect(File(AppDatabase.resolveDataPath(c)!).existsSync(), isTrue);
      }
      final versionBefore = done.contentVersion;

      final code = await cancelOcrForQuestion(AppDatabase.instance, 'q1');
      expect(code, 'cancelled');
      final after = await reload('q1');
      expect(after.ocrRaw, isNull);
      expect(after.ocrStem, isNull);
      expect(after.ocrFigures, '[]');
      expect(after.ocrSplitStatus, OcrSplitStatus.unsegmented);
      expect(after.optionContents, isNull);
      expect(after.optionContentsParserVersion, isNull);
      expect(after.questionType, isNull);
      expect(after.questionTypeSource, 'unclassified');
      expect(after.ocrManualEdited, isFalse);
      expect(after.contentVersion, versionBefore + 1);
      // 切片保留，裁图文件已清（移入回收站，原路径不存在）。
      expect(File(AppDatabase.resolveDataPath(slice)!).existsSync(), isTrue);
      for (final c in cropPaths) {
        expect(File(AppDatabase.resolveDataPath(c)!).existsSync(), isFalse);
      }
      final jobs = await AppDatabase.instance.ocrJobsForQuestion('q1');
      expect(jobs.single.status, OcrJobStatus.cancelled);
      // 状态推导为“未识别，仅保留图片”。
      expect(
        deriveOcrStemStatus(after, jobs: jobs, hasApiKey: true),
        OcrStemStatus.notRecognized,
      );
    });

    test('取消识别中的任务：迟到结果丢弃，不写库', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(_FakeRecognizer([figureResult()]));
      await worker.enqueueForQuestion(q);
      final claimed = await AppDatabase.instance.claimNextOcrJob(
        leaseDuration: ocrLeaseDuration,
        now: fakeNow,
      );
      expect(claimed, isNotNull);
      expect(claimed!.status, OcrJobStatus.running);

      final code = await cancelOcrForQuestion(AppDatabase.instance, 'q1');
      expect(code, 'cancelled');
      // 旧 worker 拿着已取消任务的结果回来：同一事务内守门丢弃。
      final wrote = await worker.applyClaimedResult(claimed, 0, figureResult());
      expect(wrote, isFalse);
      final after = await reload('q1');
      expect(after.ocrStem, isNull);
      expect(after.ocrRaw, isNull);
      expect(after.contentVersion, 0);
      final jobs = await AppDatabase.instance.ocrJobsForQuestion('q1');
      expect(jobs.single.status, OcrJobStatus.cancelled);
      // 取消后 worker 再无可领任务。
      expect(await worker.processOne(), isFalse);
    });

    test('取消失败/重试中的任务：任务行清掉，不再被领走', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(_FakeRecognizer([figureResult()]));
      final job = (await worker.enqueueForQuestion(q))!;
      await AppDatabase.instance.failOcrJob(
        job.id,
        errorCode: OcrErrorCode.timeout,
        errorMessage: '超时',
        now: fakeNow,
      );
      var stored = (await AppDatabase.instance.ocrJobById(job.id))!;
      expect(stored.status, OcrJobStatus.failed);

      expect(await cancelOcrForQuestion(AppDatabase.instance, 'q1'), 'cancelled');
      stored = (await AppDatabase.instance.ocrJobById(job.id))!;
      expect(stored.status, OcrJobStatus.cancelled);
      expect(
        await AppDatabase.instance.claimNextOcrJob(
          leaseDuration: ocrLeaseDuration,
          now: fakeNow,
        ),
        isNull,
      );

      // 退避中的重试任务同样可取消。
      final job2 = (await worker.enqueueForQuestion(q))!;
      await AppDatabase.instance.retryOcrJob(
        job2.id,
        availableAt: fakeNow.add(const Duration(minutes: 5)),
        errorCode: OcrErrorCode.timeout,
        errorMessage: '超时',
        now: fakeNow,
      );
      expect(await cancelOcrForQuestion(AppDatabase.instance, 'q1'), 'cancelled');
      stored = (await AppDatabase.instance.ocrJobById(job2.id))!;
      expect(stored.status, OcrJobStatus.cancelled);
    });

    test('人工改过题干也可取消：确认后清掉，manual 标记归零', () async {
      final slice = await writeSlice('q1');
      final raw = GlmOcrRawData(
        mdResults: '人工改的题干',
        layoutDetails: const [],
      ).toJsonString();
      await insertQuestion(
        id: 'q1',
        slicePath: slice,
        ocrManualEdited: true,
        ocrStem: '人工改的题干',
        ocrRaw: raw,
      );
      final worker = workerWith(_FakeRecognizer([figureResult()]));
      await worker.enqueueForQuestion(await reload('q1'));

      expect(await cancelOcrForQuestion(AppDatabase.instance, 'q1'), 'cancelled');
      final after = await reload('q1');
      expect(after.ocrStem, isNull);
      expect(after.ocrRaw, isNull);
      expect(after.ocrManualEdited, isFalse);
      final jobs = await AppDatabase.instance.ocrJobsForQuestion('q1');
      expect(
        deriveOcrStemStatus(after, jobs: jobs, hasApiKey: true),
        OcrStemStatus.notRecognized,
      );
    });

    test('manual 题型与文件夹/标签/错因/答案保留，auto 题型清除', () async {
      final slice = await writeSlice('q1');
      final raw = GlmOcrRawData(
        mdResults: '题干',
        layoutDetails: const [],
      ).toJsonString();
      await insertQuestion(
        id: 'q1',
        slicePath: slice,
        ocrStem: '题干',
        ocrRaw: raw,
        questionType: 'choice_single',
        questionTypeSource: 'manual',
        questionBackgroundTags: '材料',
        questionBackgroundTagsSource: 'manual',
        folderIds: const ['f1'],
        tags: const ['易错'],
        errorTypes: const ['计算错误'],
        answer: 'A',
      );
      expect(await cancelOcrForQuestion(AppDatabase.instance, 'q1'), 'cancelled');
      var after = await reload('q1');
      expect(after.questionType, 'choice_single');
      expect(after.questionTypeSource, 'manual');
      expect(after.questionBackgroundTags, '材料');
      expect(after.questionBackgroundTagsSource, 'manual');
      expect(after.folderIds, ['f1']);
      expect(after.tags, ['易错']);
      expect(after.errorTypes, ['计算错误']);
      expect(after.answer, 'A');
      expect(after.ocrStem, isNull);

      // auto 题型与 auto 背景标签随 OCR 结果一起清掉。
      final slice2 = await writeSlice('q2');
      await insertQuestion(
        id: 'q2',
        slicePath: slice2,
        ocrStem: '题干',
        ocrRaw: raw,
        questionType: 'choice_single',
        questionTypeSource: 'auto',
        questionBackgroundTags: '材料',
        questionBackgroundTagsSource: 'auto',
      );
      expect(await cancelOcrForQuestion(AppDatabase.instance, 'q2'), 'cancelled');
      after = await reload('q2');
      expect(after.questionType, isNull);
      expect(after.questionTypeSource, 'unclassified');
      expect(after.questionBackgroundTags, '');
      expect(after.questionBackgroundTagsSource, 'unclassified');
    });

    test('重复取消幂等：第二次返回 nothing_to_cancel，版本不动', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(_FakeRecognizer([figureResult()]));
      await worker.enqueueForQuestion(q);
      expect(await cancelOcrForQuestion(AppDatabase.instance, 'q1'), 'cancelled');
      final versionAfterFirst = (await reload('q1')).contentVersion;
      expect(
        await cancelOcrForQuestion(AppDatabase.instance, 'q1'),
        'nothing_to_cancel',
      );
      expect((await reload('q1')).contentVersion, versionAfterFirst);
    });

    test('不存在的题返回 no_question，无内容无任务返回 nothing_to_cancel', () async {
      expect(
        await cancelOcrForQuestion(AppDatabase.instance, 'nope'),
        'no_question',
      );
      final slice = await writeSlice('q1');
      await insertQuestion(id: 'q1', slicePath: slice);
      expect(
        await cancelOcrForQuestion(AppDatabase.instance, 'q1'),
        'nothing_to_cancel',
      );
    });

    test('取消后重新识别：新任务新代次，旧结果不再写回', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(_FakeRecognizer([figureResult()]));
      final first = (await worker.enqueueForQuestion(q))!;
      expect(await worker.processOne(), isTrue);
      expect((await reload('q1')).ocrStem, isNotNull);
      expect(await cancelOcrForQuestion(AppDatabase.instance, 'q1'), 'cancelled');
      expect((await reload('q1')).ocrStem, isNull);

      final second = (await worker.enqueueForQuestion(await reload('q1')))!;
      expect(second.id, isNot(first.id));
      expect(await worker.processOne(), isTrue);
      final after = await reload('q1');
      expect(after.ocrStem, contains('看图求值'));
      final jobs = await AppDatabase.instance.ocrJobsForQuestion('q1');
      expect(jobs.length, 2);
      final byId = {for (final j in jobs) j.id: j};
      expect(byId[first.id]?.status, OcrJobStatus.cancelled);
      expect(byId[second.id]?.status, OcrJobStatus.completed);
    });
  });

  group('applyClaimedResult 迟到写回守门', () {
    test('租约被回收重领后，旧 worker 的结果丢弃', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(_FakeRecognizer([figureResult()]));
      await worker.enqueueForQuestion(q);
      final claimed = await AppDatabase.instance.claimNextOcrJob(
        leaseDuration: ocrLeaseDuration,
        now: fakeNow,
      );
      expect(claimed, isNotNull);
      // 租约过期 → 回收 → 另一轮领走（新 token）。
      fakeNow = fakeNow.add(const Duration(minutes: 6));
      expect(
        await AppDatabase.instance.reclaimExpiredLeases(now: fakeNow),
        1,
      );
      final reclaimed = await AppDatabase.instance.claimNextOcrJob(
        leaseDuration: ocrLeaseDuration,
        now: fakeNow,
      );
      expect(reclaimed, isNotNull);
      expect(reclaimed!.leaseToken, isNot(claimed!.leaseToken));

      final wrote = await worker.applyClaimedResult(claimed, 0, figureResult());
      expect(wrote, isFalse);
      final after = await reload('q1');
      expect(after.ocrStem, isNull);
      expect(after.contentVersion, 0);
    });
  });

  group('deriveOcrStemStatus 取消态', () {
    test('最新任务 cancelled → 未识别，仅保留图片', () {
      final q = Question(
        id: 'q1',
        title: '题',
        subjectId: 'math',
        createdAt: DateTime(2026, 11, 18),
      );
      final jobs = [
        OcrJob(
          id: 'j1',
          questionId: 'q1',
          status: OcrJobStatus.cancelled,
          createdAt: DateTime(2026, 11, 18, 12, 0),
          updatedAt: DateTime(2026, 11, 18, 12, 0),
        ),
      ];
      final status = deriveOcrStemStatus(q, jobs: jobs, hasApiKey: true);
      expect(status, OcrStemStatus.notRecognized);
      expect(status.label, '未识别，仅保留图片');
    });

    test('cancelled 旧任务 + 新 pending 任务 → 最新任务说了算', () {
      final q = Question(
        id: 'q1',
        title: '题',
        subjectId: 'math',
        createdAt: DateTime(2026, 11, 18),
      );
      final jobs = [
        OcrJob(
          id: 'j2',
          questionId: 'q1',
          status: OcrJobStatus.pending,
          createdAt: DateTime(2026, 11, 18, 12, 5),
          updatedAt: DateTime(2026, 11, 18, 12, 5),
        ),
        OcrJob(
          id: 'j1',
          questionId: 'q1',
          status: OcrJobStatus.cancelled,
          createdAt: DateTime(2026, 11, 18, 12, 0),
          updatedAt: DateTime(2026, 11, 18, 12, 0),
        ),
      ];
      expect(
        deriveOcrStemStatus(q, jobs: jobs, hasApiKey: true),
        OcrStemStatus.pending,
      );
    });
  });

  group('OcrStemSection 取消识别按钮', () {
    Question sectionQuestion({
      String? ocrStem,
      String? ocrRaw,
      bool ocrManualEdited = false,
    }) => Question(
      id: 'q1',
      title: '题',
      subjectId: 'math',
      createdAt: DateTime(2026, 11, 18),
      slicePath: '',
      ocrStem: ocrStem,
      ocrRaw: ocrRaw,
      ocrManualEdited: ocrManualEdited,
    );

    OcrJob sectionJob(OcrJobStatus status) => OcrJob(
      id: 'j1',
      questionId: 'q1',
      status: status,
      createdAt: DateTime(2026, 11, 18, 12, 0),
      updatedAt: DateTime(2026, 11, 18, 12, 0),
    );

    Future<void> pumpSection(
      WidgetTester tester, {
      required Question question,
      required List<OcrJob> jobs,
      Future<bool> Function()? onCancelOcr,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: OcrStemSection(
                question: question,
                jobs: jobs,
                hasApiKey: true,
                onSaveEdited: (_) async => true,
                onAcceptCandidate: (_) async => true,
                onDismissCandidate: () async {},
                onRerecognize: () async {},
                onCancelOcr: onCancelOcr,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('有任务时显示取消识别，点后调 onCancelOcr', (tester) async {
      var called = false;
      await pumpSection(
        tester,
        question: sectionQuestion(ocrStem: '题干文字'),
        jobs: [sectionJob(OcrJobStatus.completed)],
        onCancelOcr: () async {
          called = true;
          return true;
        },
      );
      expect(find.text('取消识别'), findsOneWidget);
      await tester.tap(find.text('取消识别'));
      await tester.pumpAndSettle();
      expect(called, isTrue);
    });

    testWidgets('无任务无结果时不显示取消识别', (tester) async {
      await pumpSection(
        tester,
        question: sectionQuestion(),
        jobs: const [],
        onCancelOcr: () async => true,
      );
      expect(find.text('取消识别'), findsNothing);
    });

    testWidgets('已取消的任务不显示取消识别，状态 chip 显示未识别', (tester) async {
      await pumpSection(
        tester,
        question: sectionQuestion(),
        jobs: [sectionJob(OcrJobStatus.cancelled)],
        onCancelOcr: () async => true,
      );
      expect(find.text('取消识别'), findsNothing);
      expect(find.text('未识别，仅保留图片'), findsOneWidget);
    });

    testWidgets('人工改过时先弹确认：点取消不调回调，点确认才调', (tester) async {
      var called = false;
      await pumpSection(
        tester,
        question: sectionQuestion(
          ocrStem: '人工改的题干',
          ocrManualEdited: true,
        ),
        jobs: [sectionJob(OcrJobStatus.completed)],
        onCancelOcr: () async {
          called = true;
          return true;
        },
      );
      await tester.tap(find.text('取消识别'));
      await tester.pumpAndSettle();
      expect(
        find.text('这道题干已手动修改过。取消识别会清除题干、图块与识别结果，只保留题目切片图。'),
        findsOneWidget,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(called, isFalse);
      await tester.tap(find.text('取消识别'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cancel-ocr-confirm')));
      await tester.pumpAndSettle();
      expect(called, isTrue);
    });
  });

  group('两页端到端取消', () {
    // 假异步区里等真实异步落定：notifier 首查 / 落库都是 Drift
    // 真实异步——假时钟步进 + 真实区短暂等待交替进行（照抄包 3 接线）。
    Future<void> flushRounds(WidgetTester tester, {int rounds = 10}) async {
      for (var i = 0; i < rounds; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () async => await Future<void>.delayed(
            const Duration(milliseconds: 20),
          ),
        );
      }
      await tester.pump();
    }

    Future<void> waitForEditButton(WidgetTester tester) async {
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () async => await Future<void>.delayed(
            const Duration(milliseconds: 20),
          ),
        );
        if (find.text('编辑题干').evaluate().isNotEmpty) return;
      }
      await tester.pump();
    }

    Future<void> pumpOrganizePage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: OrganizePage(
              repo: repo,
              onOpenDetail: (_, __, {String? searchContext}) async {},
              onGoReview: () {},
              onGoCollect: () {},
              imageFailed: false,
            ),
          ),
        ),
      );
      await waitForEditButton(tester);
      expect(find.text('编辑题干'), findsOneWidget);
    }

    Future<void> pumpDetailPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: QuestionDetailPage(
              repo: repo,
              questionId: 'q1',
              orderIds: const ['q1'],
            ),
          ),
        ),
      );
      await waitForEditButton(tester);
      expect(find.text('编辑题干'), findsOneWidget);
    }

    /// 种子一道已完成识别的题（真 worker + 假识别器跑完一轮）。
    Future<void> seedCompletedQuestion() async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(_FakeRecognizer([figureResult()]));
      await worker.enqueueForQuestion(q);
      expect(await worker.processOne(), isTrue);
    }

    testWidgets('整理页取消识别：落库清掉，状态切到未识别', (tester) async {
      await tester.runAsync(seedCompletedQuestion);
      await pumpOrganizePage(tester);
      expect(find.text('取消识别'), findsOneWidget);
      await tester.ensureVisible(find.text('取消识别'));
      await tester.tap(find.text('取消识别'));
      await flushRounds(tester);
      expect(find.text('未识别，仅保留图片'), findsOneWidget);
      expect(find.text('重新识别'), findsOneWidget);
      expect(find.text('取消识别'), findsNothing);
      final stored = (await tester.runAsync(() => reload('q1')))!;
      expect(stored.ocrStem, isNull);
      expect(stored.ocrRaw, isNull);
      final jobs = (await tester.runAsync(
        () => AppDatabase.instance.ocrJobsForQuestion('q1'),
      ))!;
      expect(jobs.single.status, OcrJobStatus.cancelled);
    });

    testWidgets('详情页取消识别：落库清掉，状态切到未识别', (tester) async {
      await tester.runAsync(seedCompletedQuestion);
      await pumpDetailPage(tester);
      expect(find.text('取消识别'), findsOneWidget);
      await tester.ensureVisible(find.text('取消识别'));
      await tester.tap(find.text('取消识别'));
      await flushRounds(tester);
      expect(find.text('未识别，仅保留图片'), findsOneWidget);
      expect(find.text('重新识别'), findsOneWidget);
      expect(find.text('取消识别'), findsNothing);
      final stored = (await tester.runAsync(() => reload('q1')))!;
      expect(stored.ocrStem, isNull);
      expect(stored.ocrRaw, isNull);
      final jobs = (await tester.runAsync(
        () => AppDatabase.instance.ocrJobsForQuestion('q1'),
      ))!;
      expect(jobs.single.status, OcrJobStatus.cancelled);
    });
  });
}
