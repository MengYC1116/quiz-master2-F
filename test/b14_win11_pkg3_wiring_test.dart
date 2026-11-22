// Win11 反馈包 3 接线：notifier reorderFigure + 两页传入
// onReorderFigure + ocr_queue 自动应用与 acceptCandidateStem 调
// mergeManualFigures（只把 cropPath 为空的图块传给 writeFigureFiles，
// unmatchedManualIds 不静默丢——匹配不上的 manual 图块保留在末尾）。
//
// TDD：先写失败测试，再写实现。基建照抄 b14_m2_lifecycle_test.dart
//（真实库 + 真实文件系统，不调真实接口）。
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'package:quiz_master2/modules/ocr/stem_correction.dart';
import 'package:quiz_master2/modules/organize/organize_page.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';
import 'package:quiz_master2/services/ocr_key_store.dart';
import 'package:quiz_master2/services/ocr_queue.dart';
import 'package:quiz_master2/state/detail_notifier.dart';
import 'package:quiz_master2/state/organize_notifier.dart';
import 'package:quiz_master2/state/repository_provider.dart';
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

/// 带题目插图块的 raw 包（默认一个图块，请求坐标 [10, 5, 60, 25]；
/// [imageBboxes] 可给多个图块，md 引用与 layout 块同步改）。
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

OcrFigure _fig(
  String id,
  int seq, {
  String anchorSource = 'fallback',
  String anchorRef = '',
  String cropPath = '',
  String slicePath = 'slices/q1.png',
  String inputHash = 'h1',
  int x = 0,
  int y = 0,
  int w = 10,
  int h = 10,
  String? optionLabel,
}) => OcrFigure(
  id: id,
  slicePath: slicePath,
  inputHash: inputHash,
  sequenceIndex: seq,
  anchorSource: anchorSource,
  anchorRef: anchorRef,
  bbox2d: [x, y, x + w, y + h],
  spaceWidth: 100,
  spaceHeight: 50,
  transform: _figureTransform,
  srcRect: SrcRect(x: x, y: y, width: w, height: h),
  cropPath: cropPath,
  optionLabel: optionLabel,
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

  /// 写一小段裁图文件（manual 图块的旧裁图用）。
  Future<String> writeCropFile(String rel, {int seed = 2}) async {
    final image = img.Image(width: 10, height: 10);
    img.fill(image, color: img.ColorRgb8(30 + seed, 40, 50));
    final bytes = img.encodePng(image);
    final abs = p.join(dataDir.path, rel);
    await File(abs).parent.create(recursive: true);
    await File(abs).writeAsBytes(bytes);
    return rel;
  }

  /// 写不可解码的切片字节（裁图必失败，降级分支用）。
  Future<String> writeGarbageSlice(String name) async {
    final rel = 'slices/$name.png';
    final abs = p.join(dataDir.path, rel);
    await File(abs).parent.create(recursive: true);
    await File(abs).writeAsBytes([0, 1, 2, 3, 4, 5, 6, 7]);
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
    List<OcrFigure> figures = const [],
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
      ocrFigures: encodeOcrFigures(figures),
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

  ProviderContainer organizeContainer() {
    final container = ProviderContainer.test(
      overrides: [repositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    // autoDispose 保活（D-36）：像页面 ref.watch 那样持一个监听。
    container.listen(organizeProvider, (_, __) {});
    return container;
  }

  ProviderContainer detailContainer({String questionId = 'q1'}) {
    final container = ProviderContainer.test(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        detailInitialProvider.overrideWithValue(
          DetailInitial(questionId: questionId, orderIds: [questionId]),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(detailProvider, (_, __) {});
    return container;
  }

  setUp(() async {
    fakeNow = DateTime(2026, 11, 18, 12, 0, 0);
    db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(db);
    repo = QuestionRepository(AppDatabase.instance);
    // FR-45 后续（slices 污染）：同 b13_p1_1——tearDown 的 resetForTest()
    // 置 null 后，从第 2 个测试起 dataDirectoryPath() 读到真实目录，
    // 图块版本切片写进真实 slices/（P3 批量 2 实测本文件 +3）。setUp 先给
    // testDataDirectory 指全新临时目录，再读路径。
    final tmpDataDir = await Directory.systemTemp.createTemp('qm2-pkg3-');
    AppDatabase.testDataDirectory = tmpDataDir.path;
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
    await AppDatabase.resetForTest();
    // setUp 指的临时数据目录用完即删，不留残留。
    try {
      if (await dataDir.exists()) await dataDir.delete(recursive: true);
    } catch (_) {}
  });

  group('reorderFiguresInQuestion（纯函数，notifier 共用）', () {
    test('重排三图块：顺序/序号/被拖者 manual+落点/裁图路径都不动', () {
      final q = Question(
        id: 'q1',
        title: '题 q1',
        subjectId: 'math',
        createdAt: DateTime(2026, 11, 8),
        ocrFigures: encodeOcrFigures([
          _fig('figure-q1-0', 0, anchorSource: 'md', cropPath: 'slices/a.png'),
          _fig('figure-q1-1', 1, anchorSource: 'text', cropPath: 'slices/b.png'),
          _fig('figure-q1-2', 2, anchorSource: 'fallback', cropPath: 'slices/c.png'),
        ]),
      );
      final reordered = reorderFiguresInQuestion(
        q,
        ['figure-q1-2', 'figure-q1-0', 'figure-q1-1'],
        'figure-q1-2',
        '2',
      );
      final figs = parseOcrFigures(reordered.ocrFigures);
      expect(figs.map((f) => f.id).toList(), [
        'figure-q1-2',
        'figure-q1-0',
        'figure-q1-1',
      ]);
      expect(figs.map((f) => f.sequenceIndex).toList(), [0, 1, 2]);
      expect(figs[0].anchorSource, 'manual');
      expect(figs[0].anchorRef, '2');
      expect(figs[1].anchorSource, 'md');
      expect(
        figs.map((f) => f.cropPath).toList(),
        ['slices/c.png', 'slices/a.png', 'slices/b.png'],
      );
      // 版本 +1；原题不动。
      expect(reordered.contentVersion, q.contentVersion + 1);
      expect(parseOcrFigures(q.ocrFigures).first.id, 'figure-q1-0');
    });

    test('非法顺序抛 ArgumentError（缺图块 / 未知 ID）', () {
      final q = Question(
        id: 'q1',
        title: '题 q1',
        subjectId: 'math',
        createdAt: DateTime(2026, 11, 8),
        ocrFigures: encodeOcrFigures([
          _fig('figure-q1-0', 0),
          _fig('figure-q1-1', 1),
        ]),
      );
      expect(
        () => reorderFiguresInQuestion(
          q,
          ['figure-q1-0'],
          'figure-q1-0',
          '0',
        ),
        throwsArgumentError,
      );
      expect(
        () => reorderFiguresInQuestion(
          q,
          ['figure-q1-0', 'figure-q1-9'],
          'figure-q1-0',
          '0',
        ),
        throwsArgumentError,
      );
    });
  });

  group('OrganizeNotifier.reorderFigure', () {
    test('换位落库：顺序写进 ocr_figures，被拖者记 manual+落点，版本 +1', () async {
      final slice = await writeSlice('q1');
      final hash = await sliceHash(slice);
      await insertQuestion(
        id: 'q1',
        slicePath: slice,
        ocrStem: '第一段\n\n第二段',
        contentVersion: 3,
        figures: [
          _fig('figure-q1-0', 0, slicePath: slice, inputHash: hash),
          _fig('figure-q1-1', 1, slicePath: slice, inputHash: hash),
          _fig('figure-q1-2', 2, slicePath: slice, inputHash: hash),
        ],
      );
      final container = organizeContainer();
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      expect(container.read(organizeProvider).current?.id, 'q1');
      final ok = await notifier.reorderFigure(
        ['figure-q1-2', 'figure-q1-0', 'figure-q1-1'],
        'figure-q1-2',
        '1',
      );
      expect(ok, isTrue);
      final stored = await reload('q1');
      final storedFigs = parseOcrFigures(stored.ocrFigures);
      expect(storedFigs.map((f) => f.id).toList(), [
        'figure-q1-2',
        'figure-q1-0',
        'figure-q1-1',
      ]);
      expect(storedFigs.first.anchorSource, 'manual');
      expect(storedFigs.first.anchorRef, '1');
      expect(stored.contentVersion, 4);
      // 队列里的行也同步更新。
      final curFigs = parseOcrFigures(
        container.read(organizeProvider).current!.ocrFigures,
      );
      expect(curFigs.map((f) => f.id).toList(), [
        'figure-q1-2',
        'figure-q1-0',
        'figure-q1-1',
      ]);
    });

    test('非法顺序返回 false，库里顺序不变', () async {
      final slice = await writeSlice('q1');
      final hash = await sliceHash(slice);
      await insertQuestion(
        id: 'q1',
        slicePath: slice,
        ocrStem: '题干文字',
        figures: [
          _fig('figure-q1-0', 0, slicePath: slice, inputHash: hash),
          _fig('figure-q1-1', 1, slicePath: slice, inputHash: hash),
        ],
      );
      final container = organizeContainer();
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      final ok = await notifier.reorderFigure(
        ['figure-q1-0'],
        'figure-q1-0',
        '0',
      );
      expect(ok, isFalse);
      final stored = await reload('q1');
      expect(
        parseOcrFigures(stored.ocrFigures).map((f) => f.id).toList(),
        ['figure-q1-0', 'figure-q1-1'],
      );
      expect(stored.contentVersion, 0);
    });

    test('无当前题返回 false', () async {
      final container = organizeContainer();
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      expect(container.read(organizeProvider).current, isNull);
      final ok = await notifier.reorderFigure(
        ['figure-q1-0'],
        'figure-q1-0',
        '0',
      );
      expect(ok, isFalse);
    });
  });

  group('DetailNotifier.reorderFigure', () {
    test('换位落库：顺序写进 ocr_figures，被拖者记 manual+落点，版本 +1', () async {
      final slice = await writeSlice('q1');
      final hash = await sliceHash(slice);
      await insertQuestion(
        id: 'q1',
        slicePath: slice,
        ocrStem: '第一段\n\n第二段',
        contentVersion: 3,
        sliceWidth: 100,
        sliceHeight: 50,
        figures: [
          _fig('figure-q1-0', 0, slicePath: slice, inputHash: hash),
          _fig('figure-q1-1', 1, slicePath: slice, inputHash: hash),
          _fig('figure-q1-2', 2, slicePath: slice, inputHash: hash),
        ],
      );
      final container = detailContainer();
      final notifier = container.read(detailProvider.notifier);
      await notifier.load();
      expect(container.read(detailProvider).question?.id, 'q1');
      final ok = await notifier.reorderFigure(
        ['figure-q1-2', 'figure-q1-0', 'figure-q1-1'],
        'figure-q1-2',
        '1',
      );
      expect(ok, isTrue);
      final stored = await reload('q1');
      final storedFigs = parseOcrFigures(stored.ocrFigures);
      expect(storedFigs.map((f) => f.id).toList(), [
        'figure-q1-2',
        'figure-q1-0',
        'figure-q1-1',
      ]);
      expect(storedFigs.first.anchorSource, 'manual');
      expect(storedFigs.first.anchorRef, '1');
      expect(stored.contentVersion, 4);
      final curFigs = parseOcrFigures(
        container.read(detailProvider).question!.ocrFigures,
      );
      expect(curFigs.map((f) => f.id).toList(), [
        'figure-q1-2',
        'figure-q1-0',
        'figure-q1-1',
      ]);
    });

    test('非法顺序返回 false，库里顺序不变', () async {
      final slice = await writeSlice('q1');
      final hash = await sliceHash(slice);
      await insertQuestion(
        id: 'q1',
        slicePath: slice,
        ocrStem: '题干文字',
        sliceWidth: 100,
        sliceHeight: 50,
        figures: [
          _fig('figure-q1-0', 0, slicePath: slice, inputHash: hash),
          _fig('figure-q1-1', 1, slicePath: slice, inputHash: hash),
        ],
      );
      final container = detailContainer();
      final notifier = container.read(detailProvider.notifier);
      await notifier.load();
      final ok = await notifier.reorderFigure(
        ['figure-q1-0', 'figure-q1-9'],
        'figure-q1-0',
        '0',
      );
      expect(ok, isFalse);
      final stored = await reload('q1');
      expect(
        parseOcrFigures(stored.ocrFigures).map((f) => f.id).toList(),
        ['figure-q1-0', 'figure-q1-1'],
      );
      expect(stored.contentVersion, 0);
    });
  });

  group('acceptCandidateStem 调 mergeManualFigures', () {
    test('匹配上的 manual 图块保留旧裁图与落点，不重裁；新图块才裁', () async {
      final slice = await writeSlice('q1');
      final hash = await sliceHash(slice);
      await writeCropFile('slices/old-a.png', seed: 2);
      await writeCropFile('slices/old-u.png', seed: 3);
      final oldABytes = await File(
        p.join(dataDir.path, 'slices/old-a.png'),
      ).readAsBytes();
      final raw = figureRaw(
        inputHash: hash,
        status: OcrCandidateStatus.pending,
        imageBboxes: const [
          [10, 5, 60, 25],
          [70, 30, 95, 45],
        ],
      );
      final derived = buildOcrFigures(
        questionId: 'q1',
        raw: raw,
        transform: raw.transform,
        slicePath: slice,
        inputHash: hash,
      );
      expect(derived.length, 2);
      final oldFigs = [
        derived[0].copyWith(
          anchorSource: 'manual',
          anchorRef: '1',
          cropPath: 'slices/old-a.png',
        ),
        _fig(
          'figure-q1-9',
          1,
          anchorSource: 'manual',
          anchorRef: '2',
          cropPath: 'slices/old-u.png',
          slicePath: slice,
          inputHash: hash,
          x: 40,
          y: 30,
          w: 10,
          h: 10,
        ),
        _fig(
          'figure-q1-8',
          2,
          anchorSource: 'md',
          cropPath: 'slices/old-b.png',
          slicePath: slice,
          inputHash: hash,
          x: 5,
          y: 5,
          w: 8,
          h: 8,
        ),
      ];
      final filesBefore = sliceFiles();
      final q = await insertQuestion(
        id: 'q1',
        slicePath: slice,
        contentVersion: 5,
        ocrManualEdited: true,
        ocrStem: '旧题干',
        ocrRaw: raw.toJsonString(),
        figures: oldFigs,
      );
      final accepted = (await acceptCandidateStem(repo, q)).question;
      expect(accepted.contentVersion, 6);
      final figs = parseOcrFigures(accepted.ocrFigures);
      expect(figs.length, 3);
      // S：匹配上的 manual 图块——取新派生 ID，旧裁图与落点都保留。
      expect(figs[0].id, 'figure-q1-0');
      expect(figs[0].anchorSource, 'manual');
      expect(figs[0].anchorRef, '1');
      expect(figs[0].cropPath, 'slices/old-a.png');
      // T：新派生图块——刚裁的新文件。
      expect(figs[1].id, 'figure-q1-1');
      final newCropAbs = AppDatabase.resolveDataPath(figs[1].cropPath);
      expect(newCropAbs, isNotNull);
      expect(File(newCropAbs!).existsSync(), isTrue);
      // U：匹配不上的 manual 图块——保留在末尾，ID 加 -manual 后缀。
      expect(figs[2].id, 'figure-q1-9-manual');
      expect(figs[2].anchorSource, 'manual');
      expect(figs[2].anchorRef, '2');
      expect(figs[2].cropPath, 'slices/old-u.png');
      // 只写了一个新裁图文件；旧裁图文件字节未动。
      final newFiles = sliceFiles().difference(filesBefore);
      expect(newFiles.length, 1);
      expect(newFiles.single, figs[1].cropPath);
      expect(
        await File(p.join(dataDir.path, 'slices/old-a.png')).readAsBytes(),
        oldABytes,
      );
      final stored = await reload('q1');
      expect(parseOcrFigures(stored.ocrFigures).length, 3);
      expect(FileLifecycleGuard.instance.pendingSnapshot, isEmpty);
    });

    test('匹配不上的 manual 图块保留在末尾，不静默丢弃', () async {
      final slice = await writeSlice('q1');
      final hash = await sliceHash(slice);
      await writeCropFile('slices/old-u.png', seed: 3);
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
        figures: [
          _fig(
            'figure-q1-9',
            0,
            anchorSource: 'manual',
            anchorRef: '2',
            cropPath: 'slices/old-u.png',
            slicePath: slice,
            inputHash: hash,
            x: 40,
            y: 30,
            w: 10,
            h: 10,
          ),
        ],
      );
      final accepted = (await acceptCandidateStem(repo, q)).question;
      final figs = parseOcrFigures(accepted.ocrFigures);
      expect(figs.length, 2);
      expect(figs[0].id, 'figure-q1-0');
      expect(figs[1].id, 'figure-q1-9-manual');
      expect(figs[1].anchorSource, 'manual');
      expect(figs[1].anchorRef, '2');
      expect(figs[1].cropPath, 'slices/old-u.png');
      expect(
        File(p.join(dataDir.path, 'slices/old-u.png')).existsSync(),
        isTrue,
      );
    });

    test('裁图写失败：题干仍写回，manual 图块不丢，新图块丢弃', () async {
      final slice = await writeGarbageSlice('q1-garbage');
      final hash = await sliceHash(slice);
      await writeCropFile('slices/old-u.png', seed: 3);
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
        figures: [
          _fig(
            'figure-q1-9',
            0,
            anchorSource: 'manual',
            anchorRef: '2',
            cropPath: 'slices/old-u.png',
            slicePath: slice,
            inputHash: hash,
            x: 40,
            y: 30,
            w: 10,
            h: 10,
          ),
        ],
      );
      final filesBefore = sliceFiles();
      final accepted = (await acceptCandidateStem(repo, q)).question;
      // 候选接受本身成功（题干写回、版本 +1）。
      expect(accepted.contentVersion, 6);
      expect(accepted.ocrStem, contains('看图求值'));
      // 新图块裁不出来被丢弃；manual 图块仍在，不被连带丢掉。
      final figs = parseOcrFigures(accepted.ocrFigures);
      expect(figs.length, 1);
      expect(figs.single.id, 'figure-q1-9-manual');
      expect(figs.single.cropPath, 'slices/old-u.png');
      expect(sliceFiles(), filesBefore);
      expect(FileLifecycleGuard.instance.pendingSnapshot, isEmpty);
    });
  });

  group('worker 自动应用调 mergeManualFigures', () {
    test('匹配上的 manual 不重裁、匹配不上的保留在末尾', () async {
      final slice = await writeSlice('q1');
      final hash = await sliceHash(slice);
      await writeCropFile('slices/old-a.png', seed: 2);
      await writeCropFile('slices/old-u.png', seed: 3);
      final bboxes = const [
        [10, 5, 60, 25],
        [70, 30, 95, 45],
      ];
      final raw = figureRaw(inputHash: hash, imageBboxes: bboxes);
      final derived = buildOcrFigures(
        questionId: 'q1',
        raw: raw,
        transform: raw.transform,
        slicePath: slice,
        inputHash: hash,
      );
      expect(derived.length, 2);
      final oldFigs = [
        derived[0].copyWith(
          anchorSource: 'manual',
          anchorRef: '1',
          cropPath: 'slices/old-a.png',
        ),
        _fig(
          'figure-q1-9',
          1,
          anchorSource: 'manual',
          anchorRef: '2',
          cropPath: 'slices/old-u.png',
          slicePath: slice,
          inputHash: hash,
          x: 40,
          y: 30,
          w: 10,
          h: 10,
        ),
        _fig(
          'figure-q1-8',
          2,
          anchorSource: 'md',
          cropPath: 'slices/old-b.png',
          slicePath: slice,
          inputHash: hash,
          x: 5,
          y: 5,
          w: 8,
          h: 8,
        ),
      ];
      final filesBefore = sliceFiles();
      final q = await insertQuestion(
        id: 'q1',
        slicePath: slice,
        contentVersion: 5,
        ocrStem: '旧题干',
        figures: oldFigs,
      );
      final worker = workerWith(
        _FakeRecognizer([figureResult(inputHash: hash, imageBboxes: bboxes)]),
      );
      final job = (await worker.enqueueForQuestion(q))!;
      final claimed = await AppDatabase.instance.claimNextOcrJob(
        leaseDuration: ocrLeaseDuration,
        now: fakeNow,
      );
      expect(claimed, isNotNull);
      expect(claimed!.id, job.id);
      final wrote = await worker.applyClaimedResult(
        claimed,
        5,
        figureResult(inputHash: hash, imageBboxes: bboxes),
      );
      expect(wrote, isTrue);
      final stored = await reload('q1');
      expect(stored.contentVersion, 6);
      final figs = parseOcrFigures(stored.ocrFigures);
      expect(figs.length, 3);
      expect(figs[0].id, 'figure-q1-0');
      expect(figs[0].anchorSource, 'manual');
      expect(figs[0].cropPath, 'slices/old-a.png');
      expect(figs[1].id, 'figure-q1-1');
      final newCropAbs = AppDatabase.resolveDataPath(figs[1].cropPath);
      expect(File(newCropAbs!).existsSync(), isTrue);
      expect(figs[2].id, 'figure-q1-9-manual');
      expect(figs[2].cropPath, 'slices/old-u.png');
      final newFiles = sliceFiles().difference(filesBefore);
      expect(newFiles.length, 1);
      expect(newFiles.single, figs[1].cropPath);
      final storedJob = await AppDatabase.instance.ocrJobById(job.id);
      expect(storedJob?.status, OcrJobStatus.completed);
      expect(FileLifecycleGuard.instance.pendingSnapshot, isEmpty);
    });

    test('裁图写失败：自动应用仍成功，manual 图块不丢', () async {
      final slice = await writeGarbageSlice('q1-garbage');
      final hash = await sliceHash(slice);
      await writeCropFile('slices/old-u.png', seed: 3);
      final q = await insertQuestion(
        id: 'q1',
        slicePath: slice,
        contentVersion: 5,
        ocrStem: '旧题干',
        figures: [
          _fig(
            'figure-q1-9',
            0,
            anchorSource: 'manual',
            anchorRef: '2',
            cropPath: 'slices/old-u.png',
            slicePath: slice,
            inputHash: hash,
            x: 40,
            y: 30,
            w: 10,
            h: 10,
          ),
        ],
      );
      final filesBefore = sliceFiles();
      final worker = workerWith(
        _FakeRecognizer([figureResult(inputHash: hash)]),
      );
      final job = (await worker.enqueueForQuestion(q))!;
      final claimed = await AppDatabase.instance.claimNextOcrJob(
        leaseDuration: ocrLeaseDuration,
        now: fakeNow,
      );
      expect(claimed, isNotNull);
      final wrote = await worker.applyClaimedResult(
        claimed!,
        5,
        figureResult(inputHash: hash),
      );
      expect(wrote, isTrue);
      final stored = await reload('q1');
      expect(stored.contentVersion, 6);
      final figs = parseOcrFigures(stored.ocrFigures);
      expect(figs.length, 1);
      expect(figs.single.id, 'figure-q1-9-manual');
      expect(figs.single.cropPath, 'slices/old-u.png');
      expect(sliceFiles(), filesBefore);
      final storedJob = await AppDatabase.instance.ocrJobById(job.id);
      expect(storedJob?.status, OcrJobStatus.completed);
      expect(FileLifecycleGuard.instance.pendingSnapshot, isEmpty);
    });
  });

  group('两页传入 onReorderFigure（端到端落库）', () {
    // 假异步区里等真实异步落定：notifier 首查 / 落库都是 Drift
    // 真实异步——假时钟步进（冲微任务/定时器）+ 真实区短暂等待
    // （让完成回调投递）交替进行。直接 pumpAndSettle 在这里
    // 永远等不到：加载圈一直转（包 3 接线实测）。每轮都很便宜。
    Future<void> flushRounds(
      WidgetTester tester, {
      int rounds = 10,
    }) async {
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

    /// 等“编辑题干”出现（整页首查落定）；超时由调用方的
    /// findsOneWidget 明确报失败。
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

    Future<void> seedTwoFigureQuestion() async {
      final slice = await writeSlice('q1');
      final hash = await sliceHash(slice);
      await writeCropFile('slices/q1-fig-0.png', seed: 5);
      await writeCropFile('slices/q1-fig-1.png', seed: 6);
      await insertQuestion(
        id: 'q1',
        slicePath: slice,
        ocrStem: '第一段\n\n第二段',
        sliceWidth: 100,
        sliceHeight: 50,
        figures: [
          _fig(
            'figure-q1-0',
            0,
            slicePath: slice,
            inputHash: hash,
            cropPath: 'slices/q1-fig-0.png',
            x: 10,
            y: 5,
            w: 50,
            h: 20,
          ),
          _fig(
            'figure-q1-1',
            1,
            slicePath: slice,
            inputHash: hash,
            cropPath: 'slices/q1-fig-1.png',
            x: 70,
            y: 30,
            w: 25,
            h: 15,
          ),
        ],
      );
    }

    Future<void> dragFirstFigureToEnd(WidgetTester tester) async {
      await tester.ensureVisible(find.text('编辑题干'));
      await tester.tap(find.text('编辑题干'));
      // 点开编辑器：编辑器打开可能触发 notifier 单题刷新（Drift
      // 真实异步），不用 pumpAndSettle（同首查原因），有界 flush。
      await flushRounds(tester);
      // 详情页比整理页长，柄可能在首屏外（实测 y=891 > 720，
      // drag 起点命中失败、拖动没发生）：先把柄滚到视口顶部，
      // 再取两点坐标，落点（柄下约一屏内）随之进视口。
      await tester.ensureVisible(
        find.byKey(const Key('figure-drag-handle-figure-q1-0')),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('figure-drag-handle-figure-q1-0')),
        findsOneWidget,
      );
      final handleCenter = tester.getCenter(
        find.byKey(const Key('figure-drag-handle-figure-q1-0')),
      );
      final gapCenter = tester.getCenter(
        find.byKey(const Key('figure-drop-gap-3')),
      );
      await tester.drag(
        find.byKey(const Key('figure-drag-handle-figure-q1-0')),
        gapCenter - handleCenter,
      );
      // 落下即触发保存：repo.save 是 Drift 写库，假异步区里完成
      // 回调投递不到——先给真实区时间落库，再 pump 重建。
      await flushRounds(tester);
    }

    testWidgets('整理页拖图块：落下即落库，不再回滚', (tester) async {
      // testWidgets 体跑在假异步区：真实文件/库 I/O（写切片、写裁图、
      // upsert）必须包在 runAsync 里走真实事件循环，否则 Future
      // 永远等不到完成回调、测试挂住（包 3 接线实测：seed 卡在
      // writeSlice，0 CPU、无 I/O 在途、--timeout 也不触发）。
      // pump/tap/drag 留在假异步区（它们要 binding 的 pump 驱动）。
      await tester.runAsync(seedTwoFigureQuestion);
      await pumpOrganizePage(tester);
      await dragFirstFigureToEnd(tester);
      final stored = (await tester.runAsync(() => reload('q1')))!; // runAsync 返回可空类型；reload 内部已 row!，绝不返回 null
      final figs = parseOcrFigures(stored.ocrFigures);
      expect(figs.map((f) => f.id).toList(), ['figure-q1-1', 'figure-q1-0']);
      expect(figs.last.anchorSource, 'manual');
      expect(figs.last.anchorRef, '1');
      expect(stored.contentVersion, 1);
    });

    testWidgets('详情页拖图块：落下即落库，不再回滚', (tester) async {
      await tester.runAsync(seedTwoFigureQuestion);
      await pumpDetailPage(tester);
      await dragFirstFigureToEnd(tester);
      final stored = (await tester.runAsync(() => reload('q1')))!; // runAsync 返回可空类型；reload 内部已 row!，绝不返回 null
      final figs = parseOcrFigures(stored.ocrFigures);
      expect(figs.map((f) => f.id).toList(), ['figure-q1-1', 'figure-q1-0']);
      expect(figs.last.anchorSource, 'manual');
      expect(figs.last.anchorRef, '1');
      expect(stored.contentVersion, 1);
    });
  });
}
