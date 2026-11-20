// 十四批 M2：图块跟随 OCR 候选状态 + 文件生命周期协调机制（P1-B ①–⑧）。
// 集成测试（真实库 + 真实文件系统，不调真实接口；假识别器）。
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/file_lifecycle_guard.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/ocr/figure_files.dart';
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/modules/ocr/stem_correction.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';
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

class _MutatingRecognizer implements OcrRecognizer {
  _MutatingRecognizer(this._repo, this._question);

  final QuestionRepository _repo;
  final Question _question;

  @override
  Future<GlmOcrResult> recognize(File cropFile) async {
    // 识别期间用户改了题干 → 版本移动，worker 应用结果时应丢弃。
    await _repo.save(_question.copyWith(ocrStem: '用户改过的题干'));
    return figureResult();
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

/// 带一个题目插图块的 raw 包（图在请求坐标 [10, 5, 60, 25]）。
GlmOcrRawData figureRaw({
  String? inputHash,
  OcrCandidateStatus status = OcrCandidateStatus.none,
}) =>
    GlmOcrRawData(
      mdResults:
          '看图求值\n\n![](page=0,bbox=[10, 5, 60, 25])\n\nA. 第一项\nB. 第二项\nC. 第三项\nD. 第四项',
      layoutDetails: [
        [
          {
            'bbox_2d': [10, 5, 60, 25],
            'label': 'image',
            'native_label': 'image',
            'width': 100,
            'height': 50,
            'index': 0,
          },
          {
            'bbox_2d': [0, 0, 100, 50],
            'label': 'text',
            'native_label': 'text',
            'width': 100,
            'height': 50,
            'index': 1,
            'content': '看图求值',
          },
        ],
      ],
      transform: _figureTransform,
      inputHash: inputHash,
      candidateStatus: status,
    );

GlmOcrResult figureResult({String? inputHash}) => GlmOcrResult(
  markdown:
      '看图求值\n\n![](page=0,bbox=[10, 5, 60, 25])\n\nA. 第一项\nB. 第二项\nC. 第三项\nD. 第四项',
  rawData: figureRaw(inputHash: inputHash),
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

  Future<String> sliceHash(String rel) async {
    final bytes = await File(p.join(dataDir.path, rel)).readAsBytes();
    return sha256.convert(bytes).toString();
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

  /// 数据目录下 slices/ 里当前的文件相对路径集合。
  Set<String> sliceFiles() {
    final root = Directory(p.join(dataDir.path, 'slices'));
    if (!root.existsSync()) return {};
    return root
        .listSync()
        .whereType<File>()
        .map((f) => 'slices/${p.basename(f.path)}')
        .toSet();
  }

  setUp(() async {
    fakeNow = DateTime(2026, 11, 18, 12, 0, 0);
    db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(db);
    repo = QuestionRepository(AppDatabase.instance);
    dataDir = Directory(AppDatabase.dataDirectoryPath());
    await dataDir.create(recursive: true);
    keyBackend = _MemoryKeyBackend();
    await OcrKeyStore(backend: keyBackend).setApiKey('fake-test-key');
    FileLifecycleGuard.instance.debugClearPendingForTest();
    FileLifecycleGuard.instance.debugClearStagingForTest();
  });

  tearDown(() async {
    FileLifecycleGuard.instance.debugClearPendingForTest();
    FileLifecycleGuard.instance.debugClearStagingForTest();
  });

  group('P2 锁约束：非重入、无嵌套', () {
    test('已持锁时 withLock 抛 StateError（非重入）', () async {
      final guard = FileLifecycleGuard.instance;
      await guard.withLock(() async {
        expect(
          () => guard.withLock(() async {}),
          throwsStateError,
        );
      });
    });

    test('未持锁时内部删除函数抛 StateError', () async {
      final guard = FileLifecycleGuard.instance;
      expect(
        () => guard.deleteFileLocked(File(p.join(dataDir.path, 'x.png'))),
        throwsStateError,
      );
      expect(
        () =>
            guard.deleteDirectoryLocked(Directory(p.join(dataDir.path, 'x'))),
        throwsStateError,
      );
    });

    test('对外入口可独立取锁删文件/删目录', () async {
      final guard = FileLifecycleGuard.instance;
      final file = File(p.join(dataDir.path, 'slices', 'del.png'));
      await file.parent.create(recursive: true);
      await file.writeAsBytes([1, 2, 3]);
      expect(await guard.deleteFile(file), isTrue);
      expect(file.existsSync(), isFalse);
      final dir = Directory(p.join(dataDir.path, 'slices', 'sub'));
      await dir.create(recursive: true);
      await guard.deleteDirectory(dir);
      expect(dir.existsSync(), isFalse);
    });

    test('备份暂存区命名：严格纯数字时间戳才被启动清理认领', () async {
      expect(
        FileLifecycleGuard.isBackupStagingDirName(
          '.backup-staging-123456789',
        ),
        isTrue,
      );
      expect(
        FileLifecycleGuard.isBackupStagingDirName('.backup-staging-abc'),
        isFalse,
      );
      expect(FileLifecycleGuard.isBackupStagingDirName('123456789'), isFalse);
      final guard = FileLifecycleGuard.instance;
      final good = Directory(
        p.join(dataDir.path, '.backup-staging-123456789'),
      );
      final bad = Directory(p.join(dataDir.path, '.backup-staging-abc'));
      await good.create(recursive: true);
      await bad.create(recursive: true);
      await File(p.join(good.path, 'x.png')).writeAsBytes([1]);
      await File(p.join(bad.path, 'x.png')).writeAsBytes([1]);
      await guard.cleanupStaleBackupStagingDirs(dataDir.path);
      expect(good.existsSync(), isFalse);
      expect(bad.existsSync(), isTrue);
      // 收尾：删掉本用例留下的“坏名”目录，不干扰同文件后续用例
      // 对暂存区的断言（生产代码永远不动它，这里是测试自己清理）。
      await guard.deleteDirectory(bad);
    });
  });

  group('候选状态四路', () {
    test('接受候选：图块随候选包写回，版本 +1，裁图落盘，登记解除', () async {
      final slice = await writeSlice('q1');
      final hash = await sliceHash(slice);
      final raw = figureRaw(
        inputHash: hash,
        status: OcrCandidateStatus.pending,
      );
      final q = await insertQuestion(
        id: 'q1',
        slicePath: slice,
        contentVersion: 5,
        ocrManualEdited: true,
        ocrStem: '旧题干',
        ocrRaw: raw.toJsonString(),
      );
      final accepted = (await acceptCandidateStem(repo, q)).question;
      expect(accepted.contentVersion, 6);
      final figures = parseOcrFigures(accepted.ocrFigures);
      expect(figures.length, 1);
      expect(figures.single.id, 'figure-q1-0');
      expect(figures.single.slicePath, slice);
      expect(figures.single.inputHash, hash);
      final cropAbs = AppDatabase.resolveDataPath(figures.single.cropPath);
      expect(cropAbs, isNotNull);
      expect(File(cropAbs!).existsSync(), isTrue);
      expect(FileLifecycleGuard.instance.pendingSnapshot, isEmpty);
      final stored = await reload('q1');
      expect(parseOcrFigures(stored.ocrFigures).length, 1);
      expect(stored.contentVersion, 6);
    });

    test('忽略候选：只标 ignored，不写图块，不留裁图', () async {
      final slice = await writeSlice('q1');
      final hash = await sliceHash(slice);
      final raw = figureRaw(
        inputHash: hash,
        status: OcrCandidateStatus.pending,
      );
      final q = await insertQuestion(
        id: 'q1',
        slicePath: slice,
        contentVersion: 2,
        ocrManualEdited: true,
        ocrStem: '旧题干',
        ocrRaw: raw.toJsonString(),
      );
      final beforeFiles = sliceFiles();
      final dismissed = dismissOcrCandidateFlag(q);
      await repo.save(dismissed);
      final stored = await reload('q1');
      final storedRaw = GlmOcrRawData.tryParse(stored.ocrRaw)!;
      expect(storedRaw.candidateStatus, OcrCandidateStatus.ignored);
      expect(stored.ocrFigures, '[]');
      expect(stored.contentVersion, 3);
      // 本用例不产生新文件（同一文件内其他用例的裁图已在盘上，
      // 用快照比对而非精确集合）。
      expect(sliceFiles(), beforeFiles);
    });

    test('候选过期：hash 不一致标 stale，不写图块', () async {
      final slice = await writeSlice('q1');
      final hash = await sliceHash(slice);
      final raw = figureRaw(
        inputHash: 'deadbeef',
        status: OcrCandidateStatus.pending,
      );
      final q = await insertQuestion(
        id: 'q1',
        slicePath: slice,
        contentVersion: 2,
        ocrManualEdited: true,
        ocrStem: '旧题干',
        ocrRaw: raw.toJsonString(),
      );
      final beforeFiles = sliceFiles();
      final stale = markCandidateStale(q, hash);
      await repo.save(stale);
      final stored = await reload('q1');
      final storedRaw = GlmOcrRawData.tryParse(stored.ocrRaw)!;
      expect(storedRaw.candidateStatus, OcrCandidateStatus.stale);
      expect(stored.ocrFigures, '[]');
      expect(sliceFiles(), beforeFiles);
    });

    test('重框：旧图块不展示，显示“已重新框选，等待识别”', () async {
      final slice = await writeSlice('q1');
      final hash = await sliceHash(slice);
      final raw = figureRaw(
        inputHash: hash,
        status: OcrCandidateStatus.pending,
      );
      final q = await insertQuestion(
        id: 'q1',
        slicePath: slice,
        contentVersion: 5,
        ocrManualEdited: true,
        ocrStem: '旧题干',
        ocrRaw: raw.toJsonString(),
      );
      final accepted = (await acceptCandidateStem(repo, q)).question;
      final figures = parseOcrFigures(accepted.ocrFigures);
      expect(figures.length, 1);
      // 重框：换框 + 换切片（版本化新路径）。
      final slice2 = await writeSlice('q1-v2', seed: 7);
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
      await repo.replaceQuestionBoxesAndSlice(
        'q1',
        [box],
        slicePath: slice2,
        sliceWidth: 100,
        sliceHeight: 50,
      );
      final after = await reload('q1');
      expect(after.slicePath, slice2);
      expect(after.contentVersion, 7);
      final display = currentFiguresForDisplay(
        parseOcrFigures(after.ocrFigures),
        slicePath: after.slicePath,
        inputHash: await sliceHash(slice2),
      );
      expect(display.figures, isEmpty);
      expect(display.hasStale, isTrue);
    });
  });

  group('自动应用路径走同一套写文件协议', () {
    test('worker 自动应用：图块写回 + 裁图落盘 + 版本 +1', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(_FakeRecognizer([figureResult()]));
      await worker.enqueueForQuestion(q);
      expect(await worker.processOne(), isTrue);
      final stored = await reload('q1');
      final figures = parseOcrFigures(stored.ocrFigures);
      expect(figures.length, 1);
      final cropAbs = AppDatabase.resolveDataPath(figures.single.cropPath);
      expect(File(cropAbs!).existsSync(), isTrue);
      expect(stored.contentVersion, 1);
      expect(FileLifecycleGuard.instance.pendingSnapshot, isEmpty);
    });

    test('worker 丢弃（识别期间版本变了）：不写图块，不留裁图', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      // 版本在 processOne 内领取时记下；识别回调里改题干 →
      // 应用时版本已移动，worker 应丢弃结果。
      final beforeFiles = sliceFiles();
      final worker = workerWith(_MutatingRecognizer(repo, q));
      await worker.enqueueForQuestion(q);
      expect(await worker.processOne(), isTrue);
      final stored = await reload('q1');
      expect(stored.ocrFigures, '[]');
      expect(sliceFiles(), beforeFiles);
    });
  });

  group('P1-B 协调机制 ①–⑧', () {
    test('① 待提交保护：新图块已写入、库未提交时清理不删', () async {
      final guard = FileLifecycleGuard.instance;
      final figures = buildOcrFigures(
        questionId: 'q1',
        raw: figureRaw(),
        transform: _figureTransform,
        slicePath: 'slices/q1.png',
        inputHash: 'h1',
      );
      final slice = await writeSlice('q1');
      final sliceBytes = await File(p.join(dataDir.path, slice)).readAsBytes();
      final written = await writeFigureFiles(
        dataDir: dataDir.path,
        questionId: 'q1',
        sliceBytes: sliceBytes,
        figures: figures,
      );
      // 模拟“已写入、未提交”：正式路径仍登记在 pending 里。
      final cropRel = written.figures.single.cropPath;
      expect(guard.isPending(cropRel), isTrue);
      final result = await deleteOrphanFilesImpl([cropRel], db: db);
      expect(result.deletedCount, 0);
      expect(result.skippedReferencedCount, 1);
      expect(
        File(AppDatabase.resolveDataPath(cropRel)!).existsSync(),
        isTrue,
      );
      // 提交后解除登记，清理才能删。
      commitFigureFiles(written.registeredPaths);
      final result2 = await deleteOrphanFilesImpl([cropRel], db: db);
      expect(result2.deletedCount, 1);
      expect(
        File(AppDatabase.resolveDataPath(cropRel)!).existsSync(),
        isFalse,
      );
    });

    test('③ 提交失败清理：回滚删新图块、解登记，不留无效引用', () async {
      final guard = FileLifecycleGuard.instance;
      final figures = buildOcrFigures(
        questionId: 'q1',
        raw: figureRaw(),
        transform: _figureTransform,
        slicePath: 'slices/q1.png',
        inputHash: 'h1',
      );
      final slice = await writeSlice('q1');
      final sliceBytes = await File(p.join(dataDir.path, slice)).readAsBytes();
      final written = await writeFigureFiles(
        dataDir: dataDir.path,
        questionId: 'q1',
        sliceBytes: sliceBytes,
        figures: figures,
      );
      final cropRel = written.figures.single.cropPath;
      expect(File(AppDatabase.resolveDataPath(cropRel)!).existsSync(), isTrue);
      await rollbackFigureFiles(written.registeredPaths, dataDir: dataDir.path);
      expect(File(AppDatabase.resolveDataPath(cropRel)!).existsSync(), isFalse);
      expect(guard.pendingSnapshot, isEmpty);
    });

    test('③ 接受候选 hash 不一致：拒绝、不写图块、不留裁图', () async {
      final slice = await writeSlice('q1');
      final raw = figureRaw(
        inputHash: 'deadbeef',
        status: OcrCandidateStatus.pending,
      );
      final q = await insertQuestion(
        id: 'q1',
        slicePath: slice,
        contentVersion: 5,
        ocrManualEdited: true,
        ocrStem: '旧题干',
        ocrRaw: raw.toJsonString(),
      );
      final beforeFiles = sliceFiles();
      expect(
        () => acceptCandidateStem(repo, q),
        throwsA(isA<CandidateRejection>()),
      );
      final stored = await reload('q1');
      expect(stored.ocrFigures, '[]');
      expect(sliceFiles(), beforeFiles);
      expect(FileLifecycleGuard.instance.pendingSnapshot, isEmpty);
    });

    test('④ OCR 替换：新图块提交后旧文件进孤儿清理，新文件保留', () async {
      final slice = await writeSlice('q1');
      final q = await insertQuestion(id: 'q1', slicePath: slice);
      final worker = workerWith(_FakeRecognizer([figureResult()]));
      await worker.enqueueForQuestion(q);
      await worker.processOne();
      final first = await reload('q1');
      final firstCrop = parseOcrFigures(first.ocrFigures).single.cropPath;
      expect(File(AppDatabase.resolveDataPath(firstCrop)!).existsSync(), isTrue);
      // 第二次识别：图块换到另一个位置（不同 bbox → 不同图块）。
      final raw2 = GlmOcrRawData(
        mdResults:
            '看图求值\n\n![](page=0,bbox=[50, 30, 90, 45])\n\nA. 第一项\nB. 第二项\nC. 第三项\nD. 第四项',
        layoutDetails: [
          [
            {
              'bbox_2d': [50, 30, 90, 45],
              'label': 'image',
              'native_label': 'image',
              'width': 100,
              'height': 50,
              'index': 0,
            },
          ],
        ],
        transform: _figureTransform,
      );
      final result2 = GlmOcrResult(
        markdown: raw2.mdResults,
        rawData: raw2,
        totalTokens: 10,
      );
      final worker2 = workerWith(_FakeRecognizer([result2]));
      await worker2.enqueueForQuestion(await reload('q1'));
      await worker2.processOne();
      final second = await reload('q1');
      final secondCrop = parseOcrFigures(second.ocrFigures).single.cropPath;
      expect(secondCrop, isNot(firstCrop));
      expect(File(AppDatabase.resolveDataPath(secondCrop)!).existsSync(), isTrue);
      // 旧文件还在盘上（未立即删），孤儿清理删它、不删新文件。
      expect(File(AppDatabase.resolveDataPath(firstCrop)!).existsSync(), isTrue);
      final scan = await scanOrphanFilesFromImpl(db, dataDir: dataDir.path);
      expect(
        scan.files.map((f) => f.relativePath),
        contains(firstCrop),
      );
      expect(scan.files.map((f) => f.relativePath), isNot(contains(secondCrop)));
      final deleted = await deleteOrphanFilesImpl([firstCrop], db: db);
      expect(deleted.deletedCount, 1);
      expect(File(AppDatabase.resolveDataPath(firstCrop)!).existsSync(), isFalse);
      expect(File(AppDatabase.resolveDataPath(secondCrop)!).existsSync(), isTrue);
    });

    test('⑤ 删单个图块：旧文件不立即删，进孤儿清理；清理不删被引用文件', () async {
      final slice = await writeSlice('q1');
      final hash = await sliceHash(slice);
      final raw = figureRaw(
        inputHash: hash,
        status: OcrCandidateStatus.pending,
      );
      final q = await insertQuestion(
        id: 'q1',
        slicePath: slice,
        contentVersion: 5,
        ocrManualEdited: true,
        ocrStem: '旧题干',
        ocrRaw: raw.toJsonString(),
      );
      final accepted = (await acceptCandidateStem(repo, q)).question;
      final figure = parseOcrFigures(accepted.ocrFigures).single;
      final cropRel = figure.cropPath;
      final cropAbs = AppDatabase.resolveDataPath(cropRel)!;
      // 删除图块引用（repo.save 落库）：文件不立即删。
      final without = deleteFigureFromQuestion(accepted, figure.id);
      await repo.save(without);
      expect(parseOcrFigures((await reload('q1')).ocrFigures), isEmpty);
      expect(File(cropAbs).existsSync(), isTrue);
      // 孤儿清理在锁内执行：删旧文件，同时不删仍被引用的切片。
      final deleted = await deleteOrphanFilesImpl(
        [cropRel, slice],
        db: db,
      );
      expect(deleted.deletedCount, 1);
      expect(deleted.skippedReferencedCount, 1);
      expect(File(cropAbs).existsSync(), isFalse);
      expect(File(p.join(dataDir.path, slice)).existsSync(), isTrue);
    });

    test('⑥ 备份导出期间删题：暂存占用使物理删除推迟到孤儿清理', () async {
      final slice = await writeSlice('q1');
      final hash = await sliceHash(slice);
      final raw = figureRaw(
        inputHash: hash,
        status: OcrCandidateStatus.pending,
      );
      final q = await insertQuestion(
        id: 'q1',
        slicePath: slice,
        contentVersion: 5,
        ocrManualEdited: true,
        ocrStem: '旧题干',
        ocrRaw: raw.toJsonString(),
      );
      final accepted = (await acceptCandidateStem(repo, q)).question;
      final cropRel = parseOcrFigures(accepted.ocrFigures).single.cropPath;
      final cropAbs = AppDatabase.resolveDataPath(cropRel)!;
      // 模拟进行中的备份导出：暂存区占用图块文件。
      FileLifecycleGuard.instance.registerStaging([cropRel]);
      // 删整题：记录照常删，物理文件因暂存占用被跳过。
      await repo.delete(accepted);
      expect(File(cropAbs).existsSync(), isTrue);
      final skipped = await deleteOrphanFilesImpl([cropRel], db: db);
      expect(skipped.deletedCount, 0);
      // 导出结束解除占用，下次清理删掉。
      FileLifecycleGuard.instance.unregisterStaging([cropRel]);
      final deleted = await deleteOrphanFilesImpl([cropRel], db: db);
      expect(deleted.deletedCount, 1);
      expect(File(cropAbs).existsSync(), isFalse);
    });

    test('⑦ rename 执行期间触发孤儿清理：正式目标文件不得被删', () async {
      final guard = FileLifecycleGuard.instance;
      final figures = buildOcrFigures(
        questionId: 'q1',
        raw: figureRaw(),
        transform: _figureTransform,
        slicePath: 'slices/q1.png',
        inputHash: 'h1',
      );
      final slice = await writeSlice('q1');
      final sliceBytes = await File(p.join(dataDir.path, slice)).readAsBytes();
      var hookRan = false;
      final written = await writeFigureFiles(
        dataDir: dataDir.path,
        questionId: 'q1',
        sliceBytes: sliceBytes,
        figures: figures,
        beforeRename: () async {
          // 在“登记已更新、rename 未执行”的窗口里触发孤儿清理：
          // 正式目标路径已登记 pending，必须被跳过。
          hookRan = true;
          final formal = guard.pendingSnapshot.firstWhere(
            (r) => !r.endsWith('.tmp'),
          );
          final result = await deleteOrphanFilesImpl([formal], db: db);
          expect(result.deletedCount, 0);
          expect(result.skippedReferencedCount, 1);
        },
      );
      expect(hookRan, isTrue);
      final cropRel = written.figures.single.cropPath;
      expect(File(AppDatabase.resolveDataPath(cropRel)!).existsSync(), isTrue);
      commitFigureFiles(written.registeredPaths);
    });

    test('⑧ rename 失败：两条路径登记最终正确解除，不留悬空登记', () async {
      final guard = FileLifecycleGuard.instance;
      final figures = buildOcrFigures(
        questionId: 'q1',
        raw: figureRaw(),
        transform: _figureTransform,
        slicePath: 'slices/q1.png',
        inputHash: 'h1',
      );
      final slice = await writeSlice('q1');
      final sliceBytes = await File(p.join(dataDir.path, slice)).readAsBytes();
      // beforeRename 里删掉临时文件 → rename 因源文件不存在而失败。
      final beforeFiles = sliceFiles();
      await expectLater(
        writeFigureFiles(
          dataDir: dataDir.path,
          questionId: 'q1',
          sliceBytes: sliceBytes,
          figures: figures,
          beforeRename: () async {
            final tmp = guard.pendingSnapshot.firstWhere(
              (r) => r.endsWith('.tmp'),
            );
            await File(AppDatabase.resolveDataPath(tmp)!).delete();
          },
        ),
        throwsA(isA<FigureWriteException>()),
      );
      expect(guard.pendingSnapshot, isEmpty);
      // 正式目标不存在，失败写入不留新文件。
      expect(sliceFiles(), beforeFiles);
    });

    test('.tmp 临时文件永不被孤儿清理删除', () async {
      final tmpRel = 'slices/leftover.tmp';
      await File(p.join(dataDir.path, tmpRel)).writeAsBytes([1, 2, 3]);
      final orphanRel = 'slices/orphan.png';
      await File(p.join(dataDir.path, orphanRel)).writeAsBytes([4, 5]);
      final scan = await scanOrphanFilesFromImpl(db, dataDir: dataDir.path);
      expect(scan.files.map((f) => f.relativePath), contains(orphanRel));
      expect(scan.files.map((f) => f.relativePath), isNot(contains(tmpRel)));
      // 纵使调用方把 .tmp 传进来也跳过。
      final result = await deleteOrphanFilesImpl([tmpRel, orphanRel], db: db);
      expect(result.deletedCount, 1);
      expect(File(p.join(dataDir.path, tmpRel)).existsSync(), isTrue);
      expect(File(p.join(dataDir.path, orphanRel)).existsSync(), isFalse);
    });

    test('② 备份读暂存区副本：导出后删题，ZIP 里的图块仍完整', () async {
      final slice = await writeSlice('q1');
      final hash = await sliceHash(slice);
      final raw = figureRaw(
        inputHash: hash,
        status: OcrCandidateStatus.pending,
      );
      final q = await insertQuestion(
        id: 'q1',
        slicePath: slice,
        contentVersion: 5,
        ocrManualEdited: true,
        ocrStem: '旧题干',
        ocrRaw: raw.toJsonString(),
      );
      final accepted = (await acceptCandidateStem(repo, q)).question;
      final cropRel = parseOcrFigures(accepted.ocrFigures).single.cropPath;
      final report = await AppDatabase.exportBackupZipFromWithReport(
        db,
        dataDir: dataDir.path,
      );
      expect(report.warnings, isEmpty);
      final archive = ZipDecoder().decodeBytes(report.bytes);
      expect(
        archive.files.map((f) => f.name),
        contains(cropRel),
      );
      // 导出完成后再删题：原文件可以删，ZIP 已是独立副本。
      await repo.delete(accepted);
      expect(
        File(AppDatabase.resolveDataPath(cropRel)!).existsSync(),
        isFalse,
      );
      final again = ZipDecoder().decodeBytes(report.bytes);
      final entry = again.files.firstWhere((f) => f.name == cropRel);
      expect(entry.content, isNotEmpty);
      // 暂存区已清理干净。
      expect(
        Directory(dataDir.path)
            .listSync()
            .where((e) => p.basename(e.path).startsWith('.backup-staging-'))
            .isEmpty,
        isTrue,
      );
    });
  });

  group('备份/恢复链路 P1-6', () {
    test('导出缺失图块给可见警告，列出题目；单个图块失败不阻断备份', () async {
      final slice = await writeSlice('q1');
      final hash = await sliceHash(slice);
      final raw = figureRaw(
        inputHash: hash,
        status: OcrCandidateStatus.pending,
      );
      final q = await insertQuestion(
        id: 'q1',
        slicePath: slice,
        contentVersion: 5,
        ocrManualEdited: true,
        ocrStem: '旧题干',
        ocrRaw: raw.toJsonString(),
      );
      final accepted = (await acceptCandidateStem(repo, q)).question;
      final cropRel = parseOcrFigures(accepted.ocrFigures).single.cropPath;
      // 删掉图块文件再导出。
      await File(AppDatabase.resolveDataPath(cropRel)!).delete();
      final report = await AppDatabase.exportBackupZipFromWithReport(
        db,
        dataDir: dataDir.path,
      );
      expect(report.warnings, isNotEmpty);
      expect(report.warnings.join('\n'), contains('题 q1'));
      final archive = ZipDecoder().decodeBytes(report.bytes);
      expect(archive.files.map((f) => f.name), isNot(contains(cropRel)));
    });

    test('恢复：先还原文件再校验引用，坏图块去掉并记警告，不阻断', () async {
      final slice = await writeSlice('q1');
      final hash = await sliceHash(slice);
      final raw = figureRaw(
        inputHash: hash,
        status: OcrCandidateStatus.pending,
      );
      final q = await insertQuestion(
        id: 'q1',
        slicePath: slice,
        contentVersion: 5,
        ocrManualEdited: true,
        ocrStem: '旧题干',
        ocrRaw: raw.toJsonString(),
      );
      final accepted = (await acceptCandidateStem(repo, q)).question;
      final cropRel = parseOcrFigures(accepted.ocrFigures).single.cropPath;
      final report = await AppDatabase.exportBackupZipFromWithReport(
        db,
        dataDir: dataDir.path,
      );
      // 模拟备份缺图：把 ZIP 里的图块条目去掉再恢复——
      // 引用仍在 JSON 里，文件不在包里。
      final archive = ZipDecoder().decodeBytes(report.bytes);
      final strippedArchive = Archive();
      for (final f in archive.files) {
        if (f.name != cropRel) strippedArchive.addFile(f);
      }
      final stripped = ZipEncoder().encode(strippedArchive);
      // 目标库：删掉题目，再恢复。
      await repo.delete(accepted);
      final warnings = await AppDatabase.importBackupZipInto(
        db,
        stripped,
        dataDir: dataDir.path,
      );
      expect(warnings, isNotEmpty);
      final restored = await reload('q1');
      expect(parseOcrFigures(restored.ocrFigures), isEmpty);
      expect(restored.contentVersion, 6);
    });

    test('恢复清空 review_state：暂停会话消失，不创建活动会话', () async {
      final slice = await writeSlice('q1');
      await insertQuestion(id: 'q1', slicePath: slice);
      final report = await AppDatabase.exportBackupZipFromWithReport(
        db,
        dataDir: dataDir.path,
      );
      // 目标库里放一个暂停会话。
      await db.customStatement(
        "INSERT INTO review_state (id, queue, position, updated_at, "
        "session_id, mode) VALUES (1, '[\"q1\"]', 0, 0, 's1', '专项练习')",
      );
      final before = await db.select(db.reviewState).get();
      expect(before.length, 1);
      await AppDatabase.importBackupZipInto(db, report.bytes, dataDir: dataDir.path);
      final after = await db.select(db.reviewState).get();
      expect(after, isEmpty);
    });
  });
}
