// 十三批 P1-1：OCR 候选来源绑定 + 应用原子性 + 租约 token +
// 不可变切片 + §3.1 超时强关 + §3.3 保存 key 后立即领取。
// 覆盖（GPT §2.3/§2.4/§3.1/§3.3）：候选包身份字段与 stale 标记、
// 接受时 hash 不一致/题目已删/重复接受/已忽略拒绝、自动应用原子性
// （应用中途版本变化不得覆盖人工编辑）、租约 token 不匹配不写库、
// 重框写新文件且旧文件字节不变、超时后底层请求真正 abort、
// 保存 key 后等 key 的任务立即变为可领取。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/ocr/stem_correction.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';
import 'package:quiz_master2/services/import_guess.dart';
import 'package:quiz_master2/services/import_service.dart';
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
  Future<bool> containsKey(String key) async => _map.containsKey(key);

  @override
  Future<void> delete(String key) async {
    _map.remove(key);
  }
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

/// 识别中途回调式假识别器：先跑 [onRecognize]（模拟识别期间用户改题、
// 删题、重框），再返回固定结果。
class _CallbackRecognizer implements OcrRecognizer {
  _CallbackRecognizer(this.result, {required this.onRecognize});

  final GlmOcrResult result;
  final Future<void> Function() onRecognize;

  @override
  Future<GlmOcrResult> recognize(File cropFile) async {
    await onRecognize();
    return result;
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

const _stemMd =
    '2. 双曲线 \$ 4 x^{2}-y^{2}=4 \$的离心率为\nA. 第一项\nB. 第二项\nC. 第三项\nD. 第四项';

String _raw(
  String md, {
  OcrCandidateStatus status = OcrCandidateStatus.none,
  String? inputHash,
  int? claimedContentVersion,
  String? jobId,
}) => GlmOcrRawData(
  mdResults: md,
  inputHash: inputHash,
  claimedContentVersion: claimedContentVersion,
  candidateStatus: status,
  jobId: jobId,
  completedAtMs: 1731000000000,
).toJsonString();

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

  Future<String> sliceHash(String rel) async {
    final abs = AppDatabase.resolveDataPath(rel)!;
    return sha256HexOfFile(File(abs));
  }

  Future<Question> insertQuestion({
    required String id,
    String? slicePath,
    int contentVersion = 0,
    bool ocrManualEdited = false,
    String? ocrStem,
    String? ocrRaw,
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
      contentVersion: contentVersion,
    );
    await AppDatabase.upsertQuestionInto(db, q);
    return q;
  }

  Future<Question?> readQuestion(String id) =>
      AppDatabase.instance.questionById(id);

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
    // FR-45 后续（slices 污染）：D-260 前 tearDown 的 resetForTest()
    // 把 testDataDirectory 置 null；从第 2 个测试起 dataDirectoryPath()
    // 读到真实目录，切片写进真实 slices/（P3 批量 2 实测 acc-del 进真实
    // .trash）；D-260 起 reset 改为重指全新临时目录，该窗口已堵上。
    // setUp 仍先给 testDataDirectory 指全新临时目录，再读路径。
    final tmpDataDir = await Directory.systemTemp.createTemp('qm2-p11-');
    AppDatabase.testDataDirectory = tmpDataDir.path;
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

  group('候选包身份字段（GlmOcrRawData）', () {
    test('往返：input_hash / claimed_content_version / candidate_status / created_at 全对', () {
      final hash = 'a' * 64;
      final raw = GlmOcrRawData(
        mdResults: _stemMd,
        inputHash: hash,
        claimedContentVersion: 7,
        candidateStatus: OcrCandidateStatus.pending,
        jobId: 'ocr-1',
        completedAtMs: 1731000000000,
      );
      final parsed = GlmOcrRawData.tryParse(raw.toJsonString());
      expect(parsed, isNotNull);
      expect(parsed!.inputHash, hash);
      expect(parsed.claimedContentVersion, 7);
      expect(parsed.candidateStatus, OcrCandidateStatus.pending);
      expect(parsed.hasUnseenCandidate, isTrue);
      // created_at 与 completed_at_ms 同值（本包无独立创建时间字段）。
      expect(parsed.createdAtMs, 1731000000000);
      final json = raw.toJson();
      expect(json['created_at'], 1731000000000);
      expect(json['completed_at_ms'], 1731000000000);
      expect(json['has_unseen_candidate'], isTrue);
    });

    test('旧包（只有 has_unseen_candidate）按旧标志换算', () {
      final pending = GlmOcrRawData.tryParse(
        '{"md_results": "x", "has_unseen_candidate": true, "completed_at_ms": 5}',
      );
      expect(pending?.candidateStatus, OcrCandidateStatus.pending);
      expect(pending?.createdAtMs, 5);
      final none = GlmOcrRawData.tryParse(
        '{"md_results": "x", "has_unseen_candidate": false}',
      );
      expect(none?.candidateStatus, OcrCandidateStatus.none);
      // 未知状态值时回退旧标志，不抛。
      final unknown = GlmOcrRawData.tryParse(
        '{"md_results": "x", "candidate_status": "weird", "has_unseen_candidate": true}',
      );
      expect(unknown?.candidateStatus, OcrCandidateStatus.pending);
    });

    test('状态流转：pending → accepted/ignored/stale，hasUnseenCandidate 同步', () {
      final base = GlmOcrRawData(mdResults: 'x');
      expect(base.candidateStatus, OcrCandidateStatus.none);
      expect(base.hasUnseenCandidate, isFalse);
      final pending = base.withCandidate(
        jobId: 'ocr-1',
        completedAtMs: 1,
        inputHash: 'h',
        claimedContentVersion: 3,
      );
      expect(pending.candidateStatus, OcrCandidateStatus.pending);
      expect(pending.hasUnseenCandidate, isTrue);
      expect(pending.inputHash, 'h');
      expect(pending.claimedContentVersion, 3);
      expect(
        pending.withCandidateStatus(OcrCandidateStatus.accepted).hasUnseenCandidate,
        isFalse,
      );
      expect(
        pending.withCandidateStatus(OcrCandidateStatus.ignored).candidateStatus,
        OcrCandidateStatus.ignored,
      );
      expect(
        pending.withCandidateStatus(OcrCandidateStatus.stale).candidateStatus,
        OcrCandidateStatus.stale,
      );
      expect(pending.withoutCandidate().candidateStatus, OcrCandidateStatus.none);
    });
  });

  group('接受候选重验证（acceptCandidateStem）', () {
    test('成功：版本不一致（只改题干、切片没变）仍可接受', () async {
      final slice = await writeSlice('acc-ok');
      final hash = await sliceHash(slice);
      final repo = QuestionRepository(AppDatabase.instance);
      final q = await insertQuestion(
        id: 'acc-ok',
        slicePath: slice,
        contentVersion: 7,
        ocrManualEdited: true,
        ocrStem: '人工题干',
        ocrRaw: _raw(
          _stemMd,
          status: OcrCandidateStatus.pending,
          inputHash: hash,
          claimedContentVersion: 5,
          jobId: 'ocr-1',
        ),
      );
      final updated = (await acceptCandidateStem(repo, q)).question;
      expect(updated.ocrStem, '2. 双曲线 \$ 4 x^{2}-y^{2}=4 \$的离心率为');
      expect(updated.ocrSplitStatus, '自动切分');
      expect(updated.ocrManualEdited, isTrue);
      expect(updated.contentVersion, 8);
      expect(
        GlmOcrRawData.tryParse(updated.ocrRaw)?.candidateStatus,
        OcrCandidateStatus.accepted,
      );
      expect(hasPendingOcrCandidate(updated), isFalse);
    });

    test('hash 不一致拒绝：标 stale，重复接受再拒绝', () async {
      final slice = await writeSlice('acc-stale');
      final repo = QuestionRepository(AppDatabase.instance);
      final q = await insertQuestion(
        id: 'acc-stale',
        slicePath: slice,
        contentVersion: 2,
        ocrManualEdited: true,
        ocrStem: '人工题干',
        ocrRaw: _raw(
          _stemMd,
          status: OcrCandidateStatus.pending,
          inputHash: '0' * 64,
          claimedContentVersion: 1,
          jobId: 'ocr-1',
        ),
      );
      await expectLater(
        acceptCandidateStem(repo, q),
        throwsA(
          isA<CandidateRejection>().having(
            (e) => e.reason,
            'reason',
            'hash_mismatch',
          ),
        ),
      );
      // 库里候选已标 stale。
      final stored = (await readQuestion('acc-stale'))!;
      expect(
        GlmOcrRawData.tryParse(stored.ocrRaw)?.candidateStatus,
        OcrCandidateStatus.stale,
      );
      expect(hasPendingOcrCandidate(stored), isFalse);
      // stale 不能再接受。
      await expectLater(
        acceptCandidateStem(repo, stored),
        throwsA(
          isA<CandidateRejection>().having(
            (e) => e.reason,
            'reason',
            'not_pending',
          ),
        ),
      );
    });

    test('题目已删拒绝', () async {
      final slice = await writeSlice('acc-del');
      final hash = await sliceHash(slice);
      final repo = QuestionRepository(AppDatabase.instance);
      final q = await insertQuestion(
        id: 'acc-del',
        slicePath: slice,
        contentVersion: 0,
        ocrRaw: _raw(
          _stemMd,
          status: OcrCandidateStatus.pending,
          inputHash: hash,
        ),
      );
      await AppDatabase.deleteQuestionFrom(db, 'acc-del');
      await expectLater(
        acceptCandidateStem(repo, q),
        throwsA(
          isA<CandidateRejection>().having(
            (e) => e.reason,
            'reason',
            'question_deleted',
          ),
        ),
      );
    });

    test('重复接受拒绝：已 accepted 再次接受报 not_pending', () async {
      final slice = await writeSlice('acc-twice');
      final hash = await sliceHash(slice);
      final repo = QuestionRepository(AppDatabase.instance);
      final q = await insertQuestion(
        id: 'acc-twice',
        slicePath: slice,
        contentVersion: 1,
        ocrManualEdited: true,
        ocrRaw: _raw(
          _stemMd,
          status: OcrCandidateStatus.pending,
          inputHash: hash,
        ),
      );
      final accepted = (await acceptCandidateStem(repo, q)).question;
      await repo.save(accepted);
      await expectLater(
        acceptCandidateStem(repo, accepted),
        throwsA(
          isA<CandidateRejection>().having(
            (e) => e.reason,
            'reason',
            'not_pending',
          ),
        ),
      );
    });

    test('已忽略候选拒绝接受；无候选报 no_candidate', () async {
      final slice = await writeSlice('acc-ign');
      final hash = await sliceHash(slice);
      final repo = QuestionRepository(AppDatabase.instance);
      final q = await insertQuestion(
        id: 'acc-ign',
        slicePath: slice,
        contentVersion: 1,
        ocrManualEdited: true,
        ocrRaw: _raw(
          _stemMd,
          status: OcrCandidateStatus.pending,
          inputHash: hash,
        ),
      );
      final dismissed = dismissOcrCandidateFlag(q);
      expect(
        GlmOcrRawData.tryParse(dismissed.ocrRaw)?.candidateStatus,
        OcrCandidateStatus.ignored,
      );
      await repo.save(dismissed);
      await expectLater(
        acceptCandidateStem(repo, dismissed),
        throwsA(
          isA<CandidateRejection>().having(
            (e) => e.reason,
            'reason',
            'not_pending',
          ),
        ),
      );
      // 无候选。
      final noCandidate = await insertQuestion(id: 'acc-none');
      await expectLater(
        acceptCandidateStem(repo, noCandidate),
        throwsA(
          isA<CandidateRejection>().having(
            (e) => e.reason,
            'reason',
            'no_candidate',
          ),
        ),
      );
    });

    test('切片文件不存在拒绝 slice_missing', () async {
      final repo = QuestionRepository(AppDatabase.instance);
      final q = await insertQuestion(
        id: 'acc-missing',
        slicePath: 'slices/does-not-exist.png',
        contentVersion: 0,
        ocrRaw: _raw(
          _stemMd,
          status: OcrCandidateStatus.pending,
          inputHash: 'a' * 64,
        ),
      );
      await expectLater(
        acceptCandidateStem(repo, q),
        throwsA(
          isA<CandidateRejection>().having(
            (e) => e.reason,
            'reason',
            'slice_missing',
          ),
        ),
      );
    });

    test('candidateStemForQuestion：hash 不一致返回 null 并标 stale', () async {
      final slice = await writeSlice('acc-preview');
      final repo = QuestionRepository(AppDatabase.instance);
      await insertQuestion(
        id: 'acc-preview',
        slicePath: slice,
        contentVersion: 0,
        ocrRaw: _raw(
          _stemMd,
          status: OcrCandidateStatus.pending,
          inputHash: '0' * 64,
        ),
      );
      expect(await candidateStemForQuestion(repo, 'acc-preview'), isNull);
      final stored = (await readQuestion('acc-preview'))!;
      expect(
        GlmOcrRawData.tryParse(stored.ocrRaw)?.candidateStatus,
        OcrCandidateStatus.stale,
      );
      // hash 一致时正常返回候选题干。
      final slice2 = await writeSlice('acc-preview2');
      final hash2 = await sliceHash(slice2);
      await insertQuestion(
        id: 'acc-preview2',
        slicePath: slice2,
        contentVersion: 0,
        ocrRaw: _raw(
          _stemMd,
          status: OcrCandidateStatus.pending,
          inputHash: hash2,
        ),
      );
      expect(
        await candidateStemForQuestion(repo, 'acc-preview2'),
        '2. 双曲线 \$ 4 x^{2}-y^{2}=4 \$的离心率为',
      );
    });
  });

  group('接受候选原子性（十三批 P1 第二轮）', () {
    test('a. stale 标记不误标新候选：接受读到旧候选期间迟到新候选写回，终态是新候选 pending', () async {
      final slice = await writeSlice('atom2-stale-new');
      final repo = QuestionRepository(AppDatabase.instance);
      final q = await insertQuestion(
        id: 'atom2-stale-new',
        slicePath: slice,
        contentVersion: 2,
        ocrManualEdited: true,
        ocrStem: '人工题干',
        ocrRaw: _raw(
          '旧候选',
          status: OcrCandidateStatus.pending,
          inputHash: '0' * 64,
          jobId: 'ocr-old',
        ),
      );
      // 先启动接受（它在事务内读到旧候选、再算切片 hash），再写回新候选。
      // onError 立即挂上：接受会在等待窗口里先以 hash_mismatch 失败，
      // 不挂就会被测试框架判为未处理异步异常。
      final acceptFuture = acceptCandidateStem(
        repo,
        q,
      ).then<String?>((_) => null, onError: (Object e) {
        if (e is CandidateRejection) return e.reason;
        return 'other:$e';
      });
      // 让接受先跑进事务、读到旧候选行（hash IO 的等待窗口里写回新候选；
      // 即使接受的事务已先提交完、stale 已标，新候选写回仍在后、终态一样）。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final newHash = await sliceHash(slice);
      final newRaw = _raw(
        _stemMd,
        status: OcrCandidateStatus.pending,
        inputHash: newHash,
        jobId: 'ocr-new',
      );
      final current = (await readQuestion('atom2-stale-new'))!;
      await AppDatabase.upsertQuestionInto(
        db,
        current.copyWith(
          ocrRaw: newRaw,
          contentVersion: current.contentVersion + 1,
        ),
      );
      await expectLater(await acceptFuture, 'hash_mismatch');
      final stored = (await readQuestion('atom2-stale-new'))!;
      // 终态必须是新候选的 pending JSON，绝不能是旧候选的 stale JSON。
      expect(stored.ocrRaw, newRaw);
      expect(
        GlmOcrRawData.tryParse(stored.ocrRaw)?.candidateStatus,
        OcrCandidateStatus.pending,
      );
      expect(stored.ocrStem, '人工题干');
    });

    test('b. 并发接受 + 重框循环：终态只允许两种合法结果，四字段一致、无半截写', () async {
      final repo = QuestionRepository(AppDatabase.instance);
      const expectedStem = '2. 双曲线 \$ 4 x^{2}-y^{2}=4 \$的离心率为';
      for (var round = 0; round < 6; round++) {
        final id = 'atom2-race-$round';
        final sliceA = await writeSlice(
          'atom2-race-$round-a',
          seed: 1 + round,
        );
        final hashA = await sliceHash(sliceA);
        final q = await insertQuestion(
          id: id,
          slicePath: sliceA,
          contentVersion: 5,
          ocrManualEdited: true,
          ocrStem: '旧题干',
          ocrRaw: _raw(
            _stemMd,
            status: OcrCandidateStatus.pending,
            inputHash: hashA,
            claimedContentVersion: 4,
            jobId: 'ocr-$round',
          ),
        );
        final acceptFuture = acceptCandidateStem(
          repo,
          q,
        ).then<String?>((_) => null, onError: (Object e) {
          if (e is CandidateRejection) return e.reason;
          return 'other:$e';
        });
        // 重框：新版本切片文件 + slice_path 指过去（只换路径，
        // 不标 stale、不动版本——标 stale 的那条路只由接受的事务走）。
        final reboxFuture = () async {
          final sliceB = await writeSlice(
            'atom2-race-$round-b',
            seed: 50 + round,
          );
          final current = (await readQuestion(id))!;
          await AppDatabase.upsertQuestionInto(
            db,
            current.copyWith(slicePath: sliceB),
          );
        }();
        final results = await Future.wait([acceptFuture, reboxFuture]);
        final reason = results[0];
        final stored = (await readQuestion(id))!;
        final raw = GlmOcrRawData.tryParse(stored.ocrRaw)!;
        // 重框一定提交了：切片路径已换。
        expect(stored.slicePath, endsWith('-b.png'));
        if (reason == null) {
          // 接受先提交：题干为旧候选、状态 accepted，随后重框换切片。
          // 十四批 M2：重框（slice_path 变化）content_version +1，
          // 接受 5→6、重框 6→7，终态 7。
          expect(raw.candidateStatus, OcrCandidateStatus.accepted);
          expect(stored.ocrStem, expectedStem);
          expect(stored.ocrSplitStatus, '自动切分');
          expect(stored.contentVersion, 7);
        } else {
          // 重框先提交：接受被拒 hash_mismatch、候选 stale、题干不动。
          // 十四批 M2：重框 5→6、接受事务标 stale 再 +1，终态 7。
          expect(reason, 'hash_mismatch');
          expect(raw.candidateStatus, OcrCandidateStatus.stale);
          expect(stored.ocrStem, '旧题干');
          expect(stored.ocrSplitStatus, '未切分');
          expect(stored.contentVersion, 7);
        }
      }
    });

    test('c. 接受成功路径仍可用：版本不一致人工改过仍可接受，且已落库', () async {
      final slice = await writeSlice('atom2-ok');
      final hash = await sliceHash(slice);
      final repo = QuestionRepository(AppDatabase.instance);
      final q = await insertQuestion(
        id: 'atom2-ok',
        slicePath: slice,
        contentVersion: 7,
        ocrManualEdited: true,
        ocrStem: '人工题干',
        ocrRaw: _raw(
          _stemMd,
          status: OcrCandidateStatus.pending,
          inputHash: hash,
          claimedContentVersion: 5,
          jobId: 'ocr-1',
        ),
      );
      final updated = (await acceptCandidateStem(repo, q)).question;
      expect(updated.ocrStem, '2. 双曲线 \$ 4 x^{2}-y^{2}=4 \$的离心率为');
      expect(updated.ocrSplitStatus, '自动切分');
      expect(updated.ocrManualEdited, isTrue);
      expect(updated.contentVersion, 8);
      expect(
        GlmOcrRawData.tryParse(updated.ocrRaw)?.candidateStatus,
        OcrCandidateStatus.accepted,
      );
      // 返回的就是已保存的题：重读与返回一致（调用方不再另行保存）。
      final stored = (await readQuestion('atom2-ok'))!;
      expect(stored.ocrStem, updated.ocrStem);
      expect(stored.ocrSplitStatus, updated.ocrSplitStatus);
      expect(stored.ocrRaw, updated.ocrRaw);
      expect(stored.contentVersion, updated.contentVersion);
    });
  });

  group('忽略候选（dismissOcrCandidateFlag）', () {
    test('重复忽略是空操作：第二次原样返回，不动版本', () {
      final q = Question(
        id: 'dis-1',
        title: '题',
        subjectId: 'math',
        createdAt: DateTime(2026, 11, 18),
        ocrStem: '题干',
        ocrRaw: _raw('原文', status: OcrCandidateStatus.pending),
        contentVersion: 2,
      );
      final once = dismissOcrCandidateFlag(q);
      expect(once.contentVersion, 3);
      expect(
        GlmOcrRawData.tryParse(once.ocrRaw)?.candidateStatus,
        OcrCandidateStatus.ignored,
      );
      final twice = dismissOcrCandidateFlag(once);
      expect(identical(twice, once), isTrue);
      expect(twice.contentVersion, 3);
    });

    test('markCandidateStale：只有 pending 且 hash 不同才标', () {
      final pending = Question(
        id: 'stale-1',
        title: '题',
        subjectId: 'math',
        createdAt: DateTime(2026, 11, 18),
        ocrRaw: _raw('原文', status: OcrCandidateStatus.pending, inputHash: 'a' * 64),
        contentVersion: 4,
      );
      final marked = markCandidateStale(pending, 'b' * 64);
      expect(
        GlmOcrRawData.tryParse(marked.ocrRaw)?.candidateStatus,
        OcrCandidateStatus.stale,
      );
      expect(marked.contentVersion, 5);
      // hash 一致不标。
      expect(identical(markCandidateStale(pending, 'a' * 64), pending), isTrue);
      // 非 pending 不标。
      final ignored = Question(
        id: 'stale-2',
        title: '题',
        subjectId: 'math',
        createdAt: DateTime(2026, 11, 18),
        ocrRaw: _raw('原文', status: OcrCandidateStatus.ignored, inputHash: 'a' * 64),
        contentVersion: 4,
      );
      expect(identical(markCandidateStale(ignored, 'b' * 64), ignored), isTrue);
    });
  });

  group('自动应用原子性（worker）', () {
    test('识别期间人工改过：旧结果不得覆盖人工题干，只作候选', () async {
      final slice = await writeSlice('atom-manual');
      final q = await insertQuestion(id: 'atom-manual', slicePath: slice);
      final worker = workerWith(
        _CallbackRecognizer(_okResult(_stemMd), onRecognize: () async {
          // 识别期间用户改了题干：人工标记 + 版本 +1 + 新题干。
          final current = (await readQuestion('atom-manual'))!;
          await AppDatabase.upsertQuestionInto(
            db,
            current.copyWith(
              ocrManualEdited: true,
              ocrStem: '人工题干',
              contentVersion: current.contentVersion + 1,
            ),
          );
        }),
      );
      await worker.enqueueForQuestion(q);
      expect(await worker.processOne(), isTrue);
      final after = (await readQuestion('atom-manual'))!;
      expect(after.ocrStem, '人工题干');
      expect(hasPendingOcrCandidate(after), isTrue);
      expect(
        GlmOcrRawData.tryParse(after.ocrRaw)?.inputHash,
        await sliceHash(slice),
      );
      final jobs = await AppDatabase.instance.ocrJobsForQuestion('atom-manual');
      expect(jobs.single.status, OcrJobStatus.completed);
    });

    test('识别期间版本变了（非人工）：条件更新拒绝，旧结果不得覆盖', () async {
      final slice = await writeSlice('atom-ver');
      final q = await insertQuestion(
        id: 'atom-ver',
        slicePath: slice,
        ocrStem: '旧题干',
        contentVersion: 5,
      );
      final worker = workerWith(
        _CallbackRecognizer(_okResult(_stemMd), onRecognize: () async {
          // 识别期间另一路写回把版本顶到 6（非人工编辑）。
          final current = (await readQuestion('atom-ver'))!;
          await AppDatabase.upsertQuestionInto(
            db,
            current.copyWith(
              ocrStem: '他人已写入的题干',
              contentVersion: current.contentVersion + 1,
            ),
          );
        }),
      );
      await worker.enqueueForQuestion(q);
      expect(await worker.processOne(), isTrue);
      final after = (await readQuestion('atom-ver'))!;
      expect(after.ocrStem, '他人已写入的题干');
      expect(after.contentVersion, 6);
      final jobs = await AppDatabase.instance.ocrJobsForQuestion('atom-ver');
      expect(jobs.single.status, OcrJobStatus.failed);
      expect(jobs.single.lastErrorCode, OcrErrorCode.contentChanged);
    });

    test('识别期间题目被删：丢弃 question_deleted，题干不动', () async {
      final slice = await writeSlice('atom-del');
      final q = await insertQuestion(id: 'atom-del', slicePath: slice);
      final worker = workerWith(
        _CallbackRecognizer(_okResult(_stemMd), onRecognize: () async {
          await AppDatabase.deleteQuestionFrom(db, 'atom-del');
        }),
      );
      await worker.enqueueForQuestion(q);
      expect(await worker.processOne(), isTrue);
      expect(await readQuestion('atom-del'), isNull);
      // C 包 P2-01：删题同事务删 ocr_jobs，作业行随题目一起消失
      //（不再留下 question_deleted 的 failed 行）。
      final jobs = await AppDatabase.instance.ocrJobsForQuestion('atom-del');
      expect(jobs, isEmpty);
    });

    test('识别期间重框（slice_path 换新文件）：旧结果丢弃，旧候选标 stale', () async {
      final sliceA = await writeSlice('atom-rebox-a', seed: 1);
      final hashA = await sliceHash(sliceA);
      // 题目上已有一份旧切片的 pending 候选。
      final q = await insertQuestion(
        id: 'atom-rebox',
        slicePath: sliceA,
        contentVersion: 3,
        ocrManualEdited: true,
        ocrStem: '人工题干',
        ocrRaw: _raw(
          '旧候选',
          status: OcrCandidateStatus.pending,
          inputHash: hashA,
        ),
      );
      final worker = workerWith(
        _CallbackRecognizer(_okResult(_stemMd), onRecognize: () async {
          // 识别期间重框：新版本文件 + slice_path 指过去（旧文件字节不动）。
          final sliceB = await writeSlice('atom-rebox-b', seed: 9);
          final current = (await readQuestion('atom-rebox'))!;
          await AppDatabase.upsertQuestionInto(
            db,
            current.copyWith(slicePath: sliceB),
          );
        }),
      );
      await worker.enqueueForQuestion(q);
      expect(await worker.processOne(), isTrue);
      final after = (await readQuestion('atom-rebox'))!;
      // 迟到结果没写：人工题干还在，旧候选标 stale。
      expect(after.ocrStem, '人工题干');
      expect(
        GlmOcrRawData.tryParse(after.ocrRaw)?.candidateStatus,
        OcrCandidateStatus.stale,
      );
      final jobs = await AppDatabase.instance.ocrJobsForQuestion('atom-rebox');
      expect(jobs.single.status, OcrJobStatus.failed);
      expect(jobs.single.lastErrorCode, OcrErrorCode.hashMismatch);
    });

    test('applyClaimedResult 直测：领取后版本已变，条件更新拒绝', () async {
      final slice = await writeSlice('atom-direct');
      final q = await insertQuestion(
        id: 'atom-direct',
        slicePath: slice,
        ocrStem: '旧题干',
        contentVersion: 5,
      );
      final worker = workerWith(_FakeRecognizer([_okResult(_stemMd)]));
      final job = (await worker.enqueueForQuestion(q))!;
      final claimed = await AppDatabase.instance.claimNextOcrJob(
        leaseDuration: ocrLeaseDuration,
        now: fakeNow,
      );
      expect(claimed, isNotNull);
      expect(claimed!.id, job.id);
      // 领取后版本被顶到 6（模拟检查与写入之间的竞态窗口）。
      final current = (await readQuestion('atom-direct'))!;
      await AppDatabase.upsertQuestionInto(
        db,
        current.copyWith(
          ocrStem: '他人已写入的题干',
          contentVersion: 6,
        ),
      );
      final wrote = await worker.applyClaimedResult(claimed, 5, _okResult(_stemMd));
      expect(wrote, isTrue);
      final after = (await readQuestion('atom-direct'))!;
      expect(after.ocrStem, '他人已写入的题干');
      expect(after.contentVersion, 6);
      final stored = await AppDatabase.instance.ocrJobById(job.id);
      expect(stored?.status, OcrJobStatus.failed);
      expect(stored?.lastErrorCode, OcrErrorCode.contentChanged);
    });

    test('租约丢了：应用整笔回滚，题不动、任务回 pending', () async {
      final slice = await writeSlice('atom-lease');
      final q = await insertQuestion(
        id: 'atom-lease',
        slicePath: slice,
        ocrStem: '旧题干',
        contentVersion: 2,
      );
      final worker = workerWith(
        _CallbackRecognizer(_okResult(_stemMd), onRecognize: () async {
          // 识别期间租约过期被回收重领（旧 worker 的 token 失效）。
          await AppDatabase.instance.reclaimExpiredLeases(
            now: fakeNow.add(const Duration(minutes: 6)),
          );
        }),
      );
      await worker.enqueueForQuestion(q);
      expect(await worker.processOne(), isTrue);
      final after = (await readQuestion('atom-lease'))!;
      expect(after.ocrStem, '旧题干');
      expect(after.contentVersion, 2);
      final stored = await AppDatabase.instance.ocrJobById(
        (await AppDatabase.instance.ocrJobsForQuestion('atom-lease')).single.id,
      );
      expect(stored?.status, OcrJobStatus.pending);
      expect(stored?.leaseToken, isNull);
    });
  });

  group('租约 token（ocr_jobs.lease_token）', () {
    test('claim 生成唯一 token；两次领任务 token 不同', () async {
      final slice = await writeSlice('lease-1');
      final q1 = await insertQuestion(id: 'lease-1', slicePath: slice);
      final q2 = await insertQuestion(id: 'lease-2', slicePath: slice);
      await AppDatabase.instance.enqueueOcrJob(
        OcrJob(
          id: 'job-1',
          questionId: q1.id,
          cropPath: slice,
          createdAt: fakeNow,
          updatedAt: fakeNow,
        ),
      );
      await AppDatabase.instance.enqueueOcrJob(
        OcrJob(
          id: 'job-2',
          questionId: q2.id,
          cropPath: slice,
          createdAt: fakeNow,
          updatedAt: fakeNow,
        ),
      );
      final first = await AppDatabase.instance.claimNextOcrJob(
        leaseDuration: ocrLeaseDuration,
        now: fakeNow,
      );
      final second = await AppDatabase.instance.claimNextOcrJob(
        leaseDuration: ocrLeaseDuration,
        now: fakeNow,
      );
      expect(first?.leaseToken, isNotNull);
      expect(second?.leaseToken, isNotNull);
      expect(first?.leaseToken, isNot(second?.leaseToken));
      expect(first?.status, OcrJobStatus.running);
    });

    test('token 不匹配：complete/fail/retry/markAttempt 都不写库', () async {
      final slice = await writeSlice('lease-2');
      final q = await insertQuestion(id: 'lease-mismatch', slicePath: slice);
      await AppDatabase.instance.enqueueOcrJob(
        OcrJob(
          id: 'job-mismatch',
          questionId: q.id,
          cropPath: slice,
          createdAt: fakeNow,
          updatedAt: fakeNow,
        ),
      );
      final claimed = await AppDatabase.instance.claimNextOcrJob(
        leaseDuration: ocrLeaseDuration,
        now: fakeNow,
      );
      expect(claimed?.leaseToken, isNotNull);
      expect(
        await AppDatabase.instance.completeOcrJob(
          'job-mismatch',
          leaseToken: 'wrong-token',
        ),
        isNull,
      );
      expect(
        await AppDatabase.instance.failOcrJob(
          'job-mismatch',
          errorCode: 'internal',
          leaseToken: 'wrong-token',
        ),
        isNull,
      );
      expect(
        await AppDatabase.instance.retryOcrJob(
          'job-mismatch',
          availableAt: fakeNow,
          errorCode: 'timeout',
          leaseToken: 'wrong-token',
        ),
        isNull,
      );
      expect(
        await AppDatabase.instance.markOcrJobAttempt(
          'job-mismatch',
          leaseToken: 'wrong-token',
        ),
        isNull,
      );
      // 行一点没动：还是 running、attempt 0、token 还是原来的。
      final stored = await AppDatabase.instance.ocrJobById('job-mismatch');
      expect(stored?.status, OcrJobStatus.running);
      expect(stored?.attemptCount, 0);
      expect(stored?.leaseToken, claimed?.leaseToken);
      // 正确 token 能写。
      expect(
        await AppDatabase.instance.markOcrJobAttempt(
          'job-mismatch',
          leaseToken: claimed?.leaseToken,
        ),
        isNotNull,
      );
      expect(
        (await AppDatabase.instance.ocrJobById('job-mismatch'))?.attemptCount,
        1,
      );
    });

    test('租约丢了后失败重试不写库：旧 worker 的 retry 不生效，任务保持回收后的 pending', () async {
      final slice = await writeSlice('lease-stale-retry');
      final q = await insertQuestion(id: 'lease-stale-retry', slicePath: slice);
      final worker = workerWith(
        _CallbackRecognizer(_okResult(_stemMd), onRecognize: () async {
          // 识别期间租约过期被回收（旧 worker 的 token 失效），随后
          // 识别抛可重试错：_handleFailure 的 retryOcrJob 带旧 token，
          // 校验不一致返回 null，不做任何写操作。
          await AppDatabase.instance.reclaimExpiredLeases(
            now: fakeNow.add(const Duration(minutes: 6)),
          );
          throw OcrException(OcrErrorCode.timeout, '识别超时，请重试');
        }),
      );
      await worker.enqueueForQuestion(q);
      expect(await worker.processOne(), isTrue);
      final stored = await AppDatabase.instance.ocrJobById(
        (await AppDatabase.instance.ocrJobsForQuestion('lease-stale-retry'))
            .single
            .id,
      );
      // 回收后的样子原样保留：pending、token 已清、无退避到期点、
      // 错误码没被旧 worker 写上；attempt 已在请求前记过一次。
      expect(stored?.status, OcrJobStatus.pending);
      expect(stored?.leaseToken, isNull);
      expect(stored?.availableAt, isNull);
      expect(stored?.lastErrorCode, isNull);
      expect(stored?.attemptCount, 1);
    });

    test('租约丢了后终态失败不写库：旧 worker 的 fail 不生效，任务保持回收后的 pending', () async {
      final slice = await writeSlice('lease-stale-fail');
      final q = await insertQuestion(id: 'lease-stale-fail', slicePath: slice);
      final worker = workerWith(
        _CallbackRecognizer(_okResult(_stemMd), onRecognize: () async {
          await AppDatabase.instance.reclaimExpiredLeases(
            now: fakeNow.add(const Duration(minutes: 6)),
          );
          throw OcrException(OcrErrorCode.badImage, '图片损坏，无法识别');
        }),
      );
      await worker.enqueueForQuestion(q);
      expect(await worker.processOne(), isTrue);
      final stored = await AppDatabase.instance.ocrJobById(
        (await AppDatabase.instance.ocrJobsForQuestion('lease-stale-fail'))
            .single
            .id,
      );
      expect(stored?.status, OcrJobStatus.pending);
      expect(stored?.leaseToken, isNull);
      expect(stored?.lastErrorCode, isNull);
      expect(stored?.attemptCount, 1);
    });

    test('回收过期租约清 token；终态清 token', () async {
      final slice = await writeSlice('lease-3');
      final q = await insertQuestion(id: 'lease-clear', slicePath: slice);
      await AppDatabase.instance.enqueueOcrJob(
        OcrJob(
          id: 'job-clear',
          questionId: q.id,
          cropPath: slice,
          createdAt: fakeNow,
          updatedAt: fakeNow,
        ),
      );
      final claimed = await AppDatabase.instance.claimNextOcrJob(
        leaseDuration: ocrLeaseDuration,
        now: fakeNow,
      );
      expect(claimed?.leaseToken, isNotNull);
      // 未过期不回收。
      expect(
        await AppDatabase.instance.reclaimExpiredLeases(now: fakeNow),
        0,
      );
      // 过期后回收：回 pending、token 清掉。
      expect(
        await AppDatabase.instance.reclaimExpiredLeases(
          now: fakeNow.add(const Duration(minutes: 6)),
        ),
        1,
      );
      final reclaimed = await AppDatabase.instance.ocrJobById('job-clear');
      expect(reclaimed?.status, OcrJobStatus.pending);
      expect(reclaimed?.leaseToken, isNull);
      // 再领一次拿新 token，完成时清掉。
      final claimed2 = await AppDatabase.instance.claimNextOcrJob(
        leaseDuration: ocrLeaseDuration,
        now: fakeNow.add(const Duration(minutes: 6)),
      );
      expect(claimed2?.leaseToken, isNotNull);
      expect(claimed2?.leaseToken, isNot(claimed?.leaseToken));
      final done = await AppDatabase.instance.completeOcrJob(
        'job-clear',
        leaseToken: claimed2?.leaseToken,
      );
      expect(done?.status, OcrJobStatus.completed);
      expect(done?.leaseToken, isNull);
    });
  });

  group('入队契约（enqueueOcrForQuestion）', () {
    test('无切片返回 null（不是失败）；同一切片去重', () async {
      final noSlice = await insertQuestion(id: 'enq-none');
      expect(await enqueueOcrForQuestion(AppDatabase.instance, noSlice), isNull);
      expect(
        await enqueueOcrForQuestion(AppDatabase.instance, noSlice),
        isNull,
      );
      final slice = await writeSlice('enq-ok');
      final q = await insertQuestion(id: 'enq-ok', slicePath: slice);
      final first = await enqueueOcrForQuestion(AppDatabase.instance, q);
      expect(first, isNotNull);
      final second = await enqueueOcrForQuestion(AppDatabase.instance, q);
      expect(second?.id, first?.id);
    });

    test('写库失败时抛错（不静默吞掉）', () async {
      final slice = await writeSlice('enq-fail');
      final q = await insertQuestion(id: 'enq-fail', slicePath: slice);
      await db.close();
      await expectLater(
        enqueueOcrForQuestion(AppDatabase.instance, q),
        throwsA(anything),
      );
      // 给 tearDown 恢复一个能关的库。
      db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
    });
  });

  group('不可变切片文件名', () {
    test('nextSliceRelative：每次不同，同题同目录，.png 结尾', () {
      final a = ImportService.nextSliceRelative('q1');
      final b = ImportService.nextSliceRelative('q1');
      expect(a, isNot(b));
      expect(a.startsWith('slices/q1-v'), isTrue);
      expect(a.endsWith('.png'), isTrue);
      expect(b.startsWith('slices/q1-v'), isTrue);
      expect(p.dirname(a), 'slices');
    });
  });

  group('GPT §3.3：保存 key 后等 key 的任务立即变为可领取', () {
    test('没 key 只排队 +10 分钟；notifyApiKeySaved 后立即能领', () async {
      // key 先清掉。
      await OcrKeyStore(backend: keyBackend).clearApiKey();
      final slice = await writeSlice('nokey-1');
      final q = await insertQuestion(id: 'nokey-1', slicePath: slice);
      final worker = workerWith(_FakeRecognizer([_okResult(_stemMd)]));
      await worker.enqueueForQuestion(q);
      expect(await worker.processOne(), isTrue);
      var job = (await AppDatabase.instance.ocrJobsForQuestion('nokey-1')).single;
      expect(job.status, OcrJobStatus.pending);
      expect(job.attemptCount, 0);
      expect(job.availableAt, fakeNow.add(ocrNoKeyDelay));
      // 10 分钟内领不到。
      expect(
        await AppDatabase.instance.claimNextOcrJob(
          leaseDuration: ocrLeaseDuration,
          now: fakeNow,
        ),
        isNull,
      );
      // 补 key + 通知：立即变为可领取。
      await OcrKeyStore(backend: keyBackend).setApiKey('fake-test-key');
      await worker.notifyApiKeySaved();
      job = (await AppDatabase.instance.ocrJobsForQuestion('nokey-1')).single;
      expect(job.availableAt, isNull);
      expect(
        await AppDatabase.instance.claimNextOcrJob(
          leaseDuration: ocrLeaseDuration,
          now: fakeNow,
        ),
        isNotNull,
      );
    });
  });

  group('GPT §3.1：请求超时后底层请求真正 abort', () {
    test('本地慢服务器：超时抛 timeout，且服务端观测到连接断开', () async {
      // 原始 TCP 服务端：只收请求字节、永远不回响应。客户端超时强关
      // 后，服务端的 socket 即以 done/error 结束——HTTP 层观测不到
      // （半关闭下写响应仍可成功），TCP 层才能证明 abort 真的发生。
      final aborted = Completer<void>();
      final tcpServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        try {
          await tcpServer.close();
        } catch (_) {}
      });
      tcpServer.listen((socket) {
        socket.listen(
          (_) {},
          onDone: () {
            if (!aborted.isCompleted) aborted.complete();
          },
          onError: (_) {
            if (!aborted.isCompleted) aborted.complete();
          },
          cancelOnError: true,
        );
      });
      final slice = await writeSlice('abort-1');
      final sliceFile = File(AppDatabase.resolveDataPath(slice)!);
      final client = GlmOcrClient(
        keyStore: OcrKeyStore(backend: keyBackend),
        requestTimeout: const Duration(milliseconds: 300),
        endpointOverride: Uri.parse('http://127.0.0.1:${tcpServer.port}/ocr'),
      );
      final stopwatch = Stopwatch()..start();
      await expectLater(
        client.recognize(sliceFile),
        throwsA(
          isA<OcrException>().having(
            (e) => e.code,
            'code',
            OcrErrorCode.timeout,
          ),
        ),
      );
      stopwatch.stop();
      // 超时本身很快（300ms 级），不是等服务端才回。
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      // 服务端在 4 秒内观测到连接断开（force-close 已发）。
      await aborted.future.timeout(const Duration(seconds: 4));
      // abort 后客户端仍能正常用：另起一个立即响应的 HTTP 服务端，
      // 同款客户端第二次请求成功。
      final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        try {
          await httpServer.close(force: true);
        } catch (_) {}
      });
      httpServer.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          '{"md_results": "题干", "layout_details": [], "usage": {}}',
        );
        await request.response.close();
      });
      final ok = await GlmOcrClient(
        keyStore: OcrKeyStore(backend: keyBackend),
        requestTimeout: const Duration(seconds: 5),
        endpointOverride: Uri.parse('http://127.0.0.1:${httpServer.port}/ocr'),
      ).recognize(sliceFile);
      expect(ok.markdown, '题干');
    });
  });
}
