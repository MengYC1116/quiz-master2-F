// 十三批 M3：OCR 队列 worker 单测（假识别器 + 内存库，不调真实接口）。
// 覆盖：入队/领任务/租约回收/退避/错误分类不重试/hash 不一致丢弃/
// 人工编辑不覆盖/没 key 只排队/内容版本校验/LaTeX 不平衡原图回退。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/data_change_events.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';
import 'package:quiz_master2/services/import_guess.dart';
import 'package:quiz_master2/services/ocr_key_store.dart';
import 'package:quiz_master2/services/ocr_queue.dart';

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

/// 行为可编排的假识别器：按顺序返回结果或抛错。
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

const _stemMd = '2. 双曲线 \$ 4 x^{2}-y^{2}=4 \$的离心率为\nA. 第一项\nB. 第二项\nC. 第三项\nD. 第四项';

void main() {
  late QuizDatabase db;
  late Directory dataDir;
  late _MemoryKeyBackend keyBackend;
  late DateTime fakeNow;

  DateTime clock() => fakeNow;

  /// 写一张 100x50 切片到数据目录 slices/ 下，返回相对路径。
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
  }) async {
    final q = Question(
      id: id,
      title: '题 $id',
      subjectId: 'math',
      createdAt: DateTime(2026, 11, 18),
      slicePath: slicePath,
      ocrManualEdited: ocrManualEdited,
      ocrStem: ocrStem,
      contentVersion: contentVersion,
    );
    await AppDatabase.upsertQuestionInto(db, q);
    return q;
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
    // FR-45 后续（slices 污染）：同 b13_p1_1——tearDown 的 resetForTest()
    // 置 null 后，从第 2 个测试起 dataDirectoryPath() 读到真实目录，
    // 切片写进真实 slices/。setUp 先给 testDataDirectory 指全新临时目录。
    final tmpDataDir = await Directory.systemTemp.createTemp('qm2-ocrq-');
    AppDatabase.testDataDirectory = tmpDataDir.path;
    // flutter_test_config 已把 testDataDirectory 指到全新临时目录；
    // 这里再取一次它的路径当切片落盘目录。
    dataDir = Directory(AppDatabase.dataDirectoryPath());
    await dataDir.create(recursive: true);
    keyBackend = _MemoryKeyBackend();
    await OcrKeyStore(backend: keyBackend).setApiKey('fake-test-key');
    OcrWorker.resetInstanceForTest();
  });

  tearDown(() async {
    OcrWorker.resetInstanceForTest();
    await AppDatabase.resetForTest();
    // setUp 指的临时数据目录用完即删，不留残留。
    try {
      if (await dataDir.exists()) await dataDir.delete(recursive: true);
    } catch (_) {}
  });

  group('入队', () {
    test('确认后入队：crop_path 与 input_hash（磁盘切片 SHA-256）都对', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(_FakeRecognizer([_okResult(_stemMd)]));
      final job = await worker.enqueueForQuestion(q);
      expect(job, isNotNull);
      expect(job!.questionId, 'q1');
      expect(job.cropPath, slice);
      final abs = AppDatabase.resolveDataPath(slice)!;
      expect(job.inputHash, await sha256HexOfFile(File(abs)));
      expect(job.status, OcrJobStatus.pending);
      expect(job.attemptCount, 0);
    });

    test('同一题同一哈希重复入队不建重复行', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(_FakeRecognizer([_okResult(_stemMd)]));
      final first = await worker.enqueueForQuestion(q);
      final second = await worker.enqueueForQuestion(q);
      expect(second!.id, first!.id);
      final jobs = await AppDatabase.instance.ocrJobsForQuestion('q1');
      expect(jobs.length, 1);
    });

    test('切片路径为空或文件不存在时不建任务', () async {
      final worker = workerWith(_FakeRecognizer([_okResult(_stemMd)]));
      final noSlice = await insertQuestion(id: 'q-noslice');
      expect(await worker.enqueueForQuestion(noSlice), isNull);
      final missing = await insertQuestion(id: 'q-missing', slicePath: 'slices/nope.png');
      expect(await worker.enqueueForQuestion(missing), isNull);
      expect(await AppDatabase.instance.ocrJobsForQuestion('q-noslice'), isEmpty);
    });
  });

  group('领任务与租约', () {
    test('processOne 成功：stem 切分 + split 状态 + contentVersion +1 + completed', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(_FakeRecognizer([_okResult(_stemMd)]));
      await worker.enqueueForQuestion(q);
      expect(await worker.processOne(), isTrue);
      final after = await AppDatabase.instance.questionById('q1');
      expect(after!.ocrStem, '2. 双曲线 \$ 4 x^{2}-y^{2}=4 \$的离心率为');
      expect(after.ocrSplitStatus, '自动切分');
      expect(after.contentVersion, 1);
      expect(after.ocrRaw, isNotNull);
      expect(GlmOcrRawData.tryParse(after.ocrRaw)?.mdResults, contains('双曲线'));
      final jobs = await AppDatabase.instance.ocrJobsForQuestion('q1');
      expect(jobs.single.status, OcrJobStatus.completed);
      expect(jobs.single.attemptCount, 1);
      expect(jobs.single.completedAt, isNotNull);
      // 无可领任务时 processOne 返回 false。
      expect(await worker.processOne(), isFalse);
    });

    test('租约回收：未过期不回收，过期后回 pending 且清 started/lease', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(_FakeRecognizer([_okResult(_stemMd)]));
      final job = (await worker.enqueueForQuestion(q))!;
      // 手动领走（模拟旧 worker 崩溃前领走的 running 任务）。
      final claimed = await AppDatabase.claimNextOcrJobInto(
        db,
        leaseDuration: ocrLeaseDuration,
        now: fakeNow,
      );
      expect(claimed!.id, job.id);
      expect(claimed.status, OcrJobStatus.running);
      expect(await AppDatabase.reclaimExpiredLeasesInto(db, now: fakeNow), 0);
      fakeNow = fakeNow.add(const Duration(minutes: 5, seconds: 1));
      expect(await AppDatabase.reclaimExpiredLeasesInto(db, now: fakeNow), 1);
      final back = await AppDatabase.instance.ocrJobById(job.id);
      expect(back!.status, OcrJobStatus.pending);
      expect(back.startedAt, isNull);
      expect(back.leaseUntil, isNull);
    });
  });

  group('没 key 只排队', () {
    test('无 key：保持 pending，attempt 不加，available_at +10 分钟，不写 failed', () async {
      await OcrKeyStore(backend: keyBackend).clearApiKey();
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(_FakeRecognizer([_okResult(_stemMd)]));
      await worker.enqueueForQuestion(q);
      expect(await worker.processOne(), isTrue);
      final job = (await AppDatabase.instance.ocrJobsForQuestion('q1')).single;
      expect(job.status, OcrJobStatus.pending);
      expect(job.attemptCount, 0);
      expect(job.lastErrorCode, OcrErrorCode.apiKeyMissing);
      expect(
        job.availableAt!.difference(fakeNow),
        const Duration(minutes: 10),
      );
      // 10 分钟内不再领走；10 分钟后 key 补上即可跑。
      expect(await worker.processOne(), isFalse);
    });

    test('无效 key 改成有效 key：failed 任务自动回队并完成（P1-03）', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(
        _FakeRecognizer([
          OcrException(OcrErrorCode.apiKeyInvalid, 'key 无效'),
          _okResult(_stemMd),
        ]),
      );
      await worker.enqueueForQuestion(q);
      expect(await worker.processOne(), isTrue);
      var job = (await AppDatabase.instance.ocrJobsForQuestion('q1')).single;
      expect(job.status, OcrJobStatus.failed);
      expect(job.lastErrorCode, OcrErrorCode.apiKeyInvalid);

      await OcrKeyStore(backend: keyBackend).setApiKey('new-valid-key');
      await worker.notifyApiKeySaved();
      job = (await AppDatabase.instance.ocrJobsForQuestion('q1')).single;
      expect(job.status, OcrJobStatus.pending);
      expect(job.lastErrorCode, isNull);

      expect(await worker.processOne(), isTrue);
      job = (await AppDatabase.instance.ocrJobsForQuestion('q1')).single;
      expect(job.status, OcrJobStatus.completed);
      expect(job.attemptCount, 2);
      final after = await AppDatabase.instance.questionById('q1');
      expect(after!.ocrStem, contains('双曲线'));
    });

    test('应用启动不会把 failed + apiKeyInvalid 回队（P1-03）', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final first = workerWith(
        _FakeRecognizer([OcrException(OcrErrorCode.apiKeyInvalid, 'key 无效')]),
      );
      await first.enqueueForQuestion(q);
      expect(await first.processOne(), isTrue);
      var job = (await AppDatabase.instance.ocrJobsForQuestion('q1')).single;
      expect(job.status, OcrJobStatus.failed);
      expect(job.lastErrorCode, OcrErrorCode.apiKeyInvalid);

      // 模拟重启：新 worker.start() 只能回收租约/清 no-key 等待，
      // 不得把 api_key_invalid 的 failed 任务推回 pending。
      final second = workerWith(_FakeRecognizer([_okResult(_stemMd)]));
      await second.start();
      try {
        job = (await AppDatabase.instance.ocrJobsForQuestion('q1')).single;
        expect(job.status, OcrJobStatus.failed);
        expect(job.lastErrorCode, OcrErrorCode.apiKeyInvalid);
        expect(await second.processOne(), isFalse);
      } finally {
        await second.stop();
      }
    });
  });

  group('重试与错误分类', () {
    test('timeout 可重试：退避 30s→60s，第三次成功', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(
        _FakeRecognizer([
          OcrException(OcrErrorCode.timeout, '超时'),
          OcrException(OcrErrorCode.http429, '繁忙', retryAfter: const Duration(seconds: 45)),
          _okResult(_stemMd),
        ]),
      );
      await worker.enqueueForQuestion(q);
      // 第 1 次：timeout → pending，退避 30 秒。
      expect(await worker.processOne(), isTrue);
      var job = (await AppDatabase.instance.ocrJobsForQuestion('q1')).single;
      expect(job.status, OcrJobStatus.pending);
      expect(job.attemptCount, 1);
      expect(job.availableAt!.difference(fakeNow), const Duration(seconds: 30));
      expect(await worker.processOne(), isFalse); // 退避期内不领
      fakeNow = fakeNow.add(const Duration(seconds: 31));
      // 第 2 次：429 带 Retry-After 45 秒 → 退避 45 秒（不是指数值）。
      expect(await worker.processOne(), isTrue);
      job = (await AppDatabase.instance.ocrJobsForQuestion('q1')).single;
      expect(job.attemptCount, 2);
      expect(job.lastErrorCode, OcrErrorCode.http429);
      expect(job.availableAt!.difference(fakeNow), const Duration(seconds: 45));
      fakeNow = fakeNow.add(const Duration(seconds: 46));
      // 第 3 次：成功。
      expect(await worker.processOne(), isTrue);
      job = (await AppDatabase.instance.ocrJobsForQuestion('q1')).single;
      expect(job.status, OcrJobStatus.completed);
      expect(job.attemptCount, 3);
    });

    test('api_key_invalid 不重试：一次即 failed', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(
        _FakeRecognizer([OcrException(OcrErrorCode.apiKeyInvalid, 'key 无效')]),
      );
      await worker.enqueueForQuestion(q);
      expect(await worker.processOne(), isTrue);
      final job = (await AppDatabase.instance.ocrJobsForQuestion('q1')).single;
      expect(job.status, OcrJobStatus.failed);
      expect(job.attemptCount, 1);
      expect(job.lastErrorCode, OcrErrorCode.apiKeyInvalid);
      expect(await worker.processOne(), isFalse);
    });

    test('timeout 连败 4 次后进 failed（首次 + 3 次重试），退避 30/60/120 秒', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(
        _FakeRecognizer([OcrException(OcrErrorCode.timeout, '超时')]),
      );
      await worker.enqueueForQuestion(q);
      const delays = [30, 60, 120];
      for (var i = 0; i < 3; i++) {
        expect(await worker.processOne(), isTrue);
        final job = (await AppDatabase.instance.ocrJobsForQuestion('q1')).single;
        expect(job.status, OcrJobStatus.pending);
        expect(job.attemptCount, i + 1);
        expect(job.availableAt!.difference(fakeNow), Duration(seconds: delays[i]));
        fakeNow = fakeNow.add(Duration(seconds: delays[i] + 1));
      }
      expect(await worker.processOne(), isTrue);
      final job = (await AppDatabase.instance.ocrJobsForQuestion('q1')).single;
      expect(job.status, OcrJobStatus.failed);
      expect(job.attemptCount, 4);
      expect(job.lastErrorCode, OcrErrorCode.timeout);
    });

    test('未预期异常也计入 4 次上限，不会第 5 次请求（P1-02）', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final recognizer = _FakeRecognizer([StateError('识别器内部异常')]);
      final worker = workerWith(recognizer);
      await worker.enqueueForQuestion(q);

      for (var i = 0; i < 4; i++) {
        expect(await worker.processOne(), isTrue);
        fakeNow = fakeNow.add(const Duration(minutes: 5));
      }

      final job = (await AppDatabase.instance.ocrJobsForQuestion('q1')).single;
      expect(job.status, OcrJobStatus.failed);
      expect(job.attemptCount, 4);
      expect(recognizer.calls, 4);
      expect(await worker.processOne(), isFalse);
    });

    test('bad_image 不重试：一次即 failed', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(
        _FakeRecognizer([OcrException(OcrErrorCode.badImage, '图片损坏')]),
      );
      await worker.enqueueForQuestion(q);
      expect(await worker.processOne(), isTrue);
      final job = (await AppDatabase.instance.ocrJobsForQuestion('q1')).single;
      expect(job.status, OcrJobStatus.failed);
      expect(job.lastErrorCode, OcrErrorCode.badImage);
    });
  });

  group('应用结果前必查三项', () {
    test('hash 不一致：切片被换过，旧结果丢弃（failed/hash_mismatch），题不动', () async {
      final slice = await writeSlice('q1', seed: 1);
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(_FakeRecognizer([_okResult(_stemMd)]));
      await worker.enqueueForQuestion(q);
      // 入队后切片被换成另一张图（改框/重导）。
      await writeSlice('q1', seed: 99);
      expect(await worker.processOne(), isTrue);
      final job = (await AppDatabase.instance.ocrJobsForQuestion('q1')).single;
      expect(job.status, OcrJobStatus.failed);
      expect(job.lastErrorCode, OcrErrorCode.hashMismatch);
      final after = await AppDatabase.instance.questionById('q1');
      expect(after!.ocrStem, isNull);
      expect(after.contentVersion, 0);
    });

    test('删题同时清理 OCR 任务与最近查看，worker 不会领到孤儿任务（P2-01）', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(_FakeRecognizer([_okResult(_stemMd)]));
      await worker.enqueueForQuestion(q);
      await AppDatabase.recordQuestionViewedInto(db, 'q1');
      expect(
        (await AppDatabase.instance.recentlyViewedQuestions())
            .any((e) => e.question.id == 'q1'),
        isTrue,
      );

      await AppDatabase.deleteQuestionFrom(db, 'q1');

      expect(await AppDatabase.instance.ocrJobsForQuestion('q1'), isEmpty);
      expect(
        (await AppDatabase.instance.recentlyViewedQuestions())
            .any((e) => e.question.id == 'q1'),
        isFalse,
      );
      expect(await worker.processOne(), isFalse);
    });

    test('识别期间内容版本变了：结果丢弃（failed/content_changed）', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      // 假识别器在“请求期间”模拟用户改了题（contentVersion +1）。
      final worker = workerWith(_FakeRecognizer([_okResult(_stemMd)]));
      await worker.enqueueForQuestion(q);
      final racing = OcrWorker(
        database: AppDatabase.instance,
        keyStore: OcrKeyStore(backend: keyBackend),
        recognizer: _RacingRecognizer(db),
        clock: clock,
      );
      expect(await racing.processOne(), isTrue);
      final job = (await AppDatabase.instance.ocrJobsForQuestion('q1')).single;
      expect(job.status, OcrJobStatus.failed);
      expect(job.lastErrorCode, OcrErrorCode.contentChanged);
      final after = await AppDatabase.instance.questionById('q1');
      expect(after!.ocrStem, isNull);
      expect(after.contentVersion, 1);
    });
  });

  group('人工编辑保护与候选', () {
    test('人工改过：新结果只写 raw（候选标志 true），stem 不覆盖', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(
        id: 'q1',
        slicePath: slice,
        contentVersion: 3,
        ocrManualEdited: true,
        ocrStem: '人工改过的题干',
      );
      final worker = workerWith(_FakeRecognizer([_okResult(_stemMd)]));
      await worker.enqueueForQuestion(q);
      expect(await worker.processOne(), isTrue);
      final after = await AppDatabase.instance.questionById('q1');
      expect(after!.ocrStem, '人工改过的题干');
      expect(after.contentVersion, 4);
      expect(hasPendingOcrCandidate(after), isTrue);
      expect(pendingCandidateStem(after), '2. 双曲线 \$ 4 x^{2}-y^{2}=4 \$的离心率为');
      // M5 清标志后不再提示同一份候选。
      final cleared = clearOcrCandidateFlag(after.ocrRaw);
      expect(hasPendingOcrCandidate(after.copyWith(ocrRaw: cleared)), isFalse);
      final jobs = await AppDatabase.instance.ocrJobsForQuestion('q1');
      expect(jobs.single.status, OcrJobStatus.completed);
    });

    test('LaTeX 不平衡：只写 raw，stem 不写，不是候选（原图回退）', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(
        _FakeRecognizer([_okResult(r'1. 求 $ \frac{1}{2 的值')]),
      );
      await worker.enqueueForQuestion(q);
      expect(await worker.processOne(), isTrue);
      final after = await AppDatabase.instance.questionById('q1');
      expect(after!.ocrRaw, isNotNull);
      expect(after.ocrStem, isNull);
      expect(after.ocrSplitStatus, '未切分');
      expect(after.contentVersion, 1);
      expect(hasPendingOcrCandidate(after), isFalse);
      final jobs = await AppDatabase.instance.ocrJobsForQuestion('q1');
      expect(jobs.single.status, OcrJobStatus.completed);
    });
  });

  group('事件与启停', () {
    test('OCR 完成发 DataChangeBus 事件（questions + questionId）', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(_FakeRecognizer([_okResult(_stemMd)]));
      await worker.enqueueForQuestion(q);
      final events = <DataChangeEvent>[];
      final sub = DataChangeBus.instance.stream.listen(events.add);
      addTearDown(sub.cancel);
      expect(await worker.processOne(), isTrue);
      // 事件是同步发出的（broadcast 流）；等一帧确保送达。
      await Future.delayed(Duration.zero);
      expect(
        events.any(
          (e) =>
              e.questionId == 'q1' && e.kinds.contains(DataChangeKind.questions),
        ),
        isTrue,
      );
    });

    test('start/stop：后台循环自动跑完 pending 任务', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = OcrWorker(
        database: AppDatabase.instance,
        keyStore: OcrKeyStore(backend: keyBackend),
        recognizer: _FakeRecognizer([_okResult(_stemMd)]),
        pollInterval: const Duration(milliseconds: 50),
      );
      await worker.enqueueForQuestion(q);
      await worker.start();
      try {
        OcrJob? job;
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline)) {
          job = await AppDatabase.instance.ocrJobById(
            (await AppDatabase.instance.ocrJobsForQuestion('q1')).single.id,
          );
          if (job?.status == OcrJobStatus.completed) break;
          await Future.delayed(const Duration(milliseconds: 50));
        }
        expect(job?.status, OcrJobStatus.completed);
        final after = await AppDatabase.instance.questionById('q1');
        expect(after!.ocrStem, contains('双曲线'));
      } finally {
        await worker.stop();
      }
    });

    test('重启时 lease 未到期：运行中到期会自动回收，不会整会话卡 running（P1-01）', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = OcrWorker(
        database: AppDatabase.instance,
        keyStore: OcrKeyStore(backend: keyBackend),
        recognizer: _FakeRecognizer([_okResult(_stemMd)]),
        pollInterval: const Duration(milliseconds: 20),
        clock: clock,
      );
      final job = (await worker.enqueueForQuestion(q))!;
      // 模拟旧 worker 在请求中领走后被杀：lease 还没到期。
      final claimed = await AppDatabase.claimNextOcrJobInto(
        db,
        leaseDuration: ocrLeaseDuration,
        now: fakeNow,
      );
      expect(claimed!.id, job.id);
      expect(claimed.status, OcrJobStatus.running);

      await worker.start();
      try {
        // 新会话先启动；启动时 lease 未到期，不能回收。
        // 等 lease 过期后，运行中的周期回收必须把它放回 pending 并跑完。
        fakeNow = fakeNow.add(const Duration(minutes: 6));
        OcrJob? current;
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline)) {
          current = await AppDatabase.instance.ocrJobById(job.id);
          if (current?.status == OcrJobStatus.completed) break;
          await Future.delayed(const Duration(milliseconds: 20));
        }
        expect(current?.status, OcrJobStatus.completed);
      } finally {
        await worker.stop();
      }
    });

    test('start 幂等：调两次只起一个循环', () async {
      final worker = OcrWorker(
        database: AppDatabase.instance,
        keyStore: OcrKeyStore(backend: keyBackend),
        recognizer: _FakeRecognizer([_okResult(_stemMd)]),
        pollInterval: const Duration(milliseconds: 50),
      );
      await worker.start();
      await worker.start();
      expect(worker.isRunning, isTrue);
      await worker.stop();
      expect(worker.isRunning, isFalse);
    });
  });
}

/// 在 recognize 期间把题的 contentVersion +1（模拟识别时用户改了题）。
class _RacingRecognizer implements OcrRecognizer {
  _RacingRecognizer(this._db);

  final QuizDatabase _db;

  @override
  Future<GlmOcrResult> recognize(File cropFile) async {
    final q = await AppDatabase.instance.questionById('q1');
    await AppDatabase.upsertQuestionInto(
      _db,
      q!.copyWith(contentVersion: q.contentVersion + 1),
    );
    return _okResult(_stemMd);
  }
}
