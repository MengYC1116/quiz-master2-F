// 十四批 M2 Linux 模拟用户核验（模块 C）：配图独立图块 #7–#12。
//
// 集成测试：真实内存库 + 真实临时数据目录 + 真实 OCR worker（假识别器喂
// 与既有测试同款的种子包，不调真实 GLM 接口、无 BigModel key）+ 真实
// OcrStemSection / StemEditor widget（详情页与整理页共用的同一套组件）。
// 不改 lib/、不碰真实库（~/.local/share/quiz-master2/）。
// 临时文件一律放在 ~/workspace/batch14-work/sim-tmp-c/ 下（/tmp 已满）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/file_lifecycle_guard.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/modules/ocr/ocr_stem_section.dart';
import 'package:quiz_master2/modules/ocr/question_content_renderer.dart';
import 'package:quiz_master2/modules/ocr/stem_correction.dart';
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

/// layout_details 一页里的一个块（与 b14_m2_figures_test.dart 同款形状）。
Map<String, Object?> _block({
  required List<int> bbox,
  required String label,
  String nativeLabel = 'text',
  required int width,
  required int height,
  int index = 0,
  String content = '',
}) => {
  'bbox_2d': bbox,
  'label': label,
  'native_label': nativeLabel,
  'width': width,
  'height': height,
  'index': index,
  'content': content,
};

/// 带一个题目插图块的 raw 包（图在请求坐标 [10, 5, 60, 25]）。
/// 与 b14_m2_lifecycle_test.dart 的 figureRaw 同款种子。
GlmOcrRawData _figureRaw({
  String? inputHash,
  OcrCandidateStatus status = OcrCandidateStatus.none,
}) => GlmOcrRawData(
  mdResults:
      '看图求值\n\n![](page=0,bbox=[10, 5, 60, 25])\n\nA. 第一项\nB. 第二项\nC. 第三项\nD. 第四项',
  layoutDetails: [
    [
      _block(
        bbox: [10, 5, 60, 25],
        label: 'image',
        nativeLabel: 'image',
        width: 100,
        height: 50,
      ),
      _block(
        bbox: [0, 0, 100, 50],
        label: 'text',
        width: 100,
        height: 50,
        index: 1,
        content: '看图求值',
      ),
    ],
  ],
  transform: _figureTransform,
  inputHash: inputHash,
  candidateStatus: status,
);

GlmOcrResult _figureResult({String? inputHash}) => GlmOcrResult(
  markdown:
      '看图求值\n\n![](page=0,bbox=[10, 5, 60, 25])\n\nA. 第一项\nB. 第二项\nC. 第三项\nD. 第四项',
  rawData: _figureRaw(inputHash: inputHash),
  totalTokens: 10,
);

/// 第二次识别：图块换到另一个位置（不同 bbox → 不同图块）。
GlmOcrResult _figureResult2() {
  const transform = _figureTransform;
  final raw = GlmOcrRawData(
    mdResults:
        '看图求值\n\n![](page=0,bbox=[50, 30, 90, 45])\n\nA. 第一项\nB. 第二项\nC. 第三项\nD. 第四项',
    layoutDetails: [
      [
        _block(
          bbox: [50, 30, 90, 45],
          label: 'image',
          nativeLabel: 'image',
          width: 100,
          height: 50,
        ),
      ],
    ],
    transform: transform,
  );
  return GlmOcrResult(markdown: raw.mdResults, rawData: raw, totalTokens: 10);
}

/// 只有页眉装饰图的 raw 包（政治卷 p01 同款语义：header_image 不成块）。
GlmOcrRawData _headerOnlyRaw() => GlmOcrRawData(
  mdResults: '![](page=0,bbox=[10, 5, 60, 25])\n\n政治选择题题干文字',
  layoutDetails: [
    [
      _block(
        bbox: [10, 5, 60, 25],
        label: 'image',
        nativeLabel: 'header_image',
        width: 100,
        height: 50,
      ),
      _block(
        bbox: [0, 30, 100, 50],
        label: 'text',
        width: 100,
        height: 50,
        index: 1,
        content: '政治选择题题干文字',
      ),
    ],
  ],
  transform: _figureTransform,
);

GlmOcrResult _headerOnlyResult() => GlmOcrResult(
  markdown: '![](page=0,bbox=[10, 5, 60, 25])\n\n政治选择题题干文字',
  rawData: _headerOnlyRaw(),
  totalTokens: 10,
);

/// 锚定失败的图块：md 里无图引用、也无文本块 → fallback、位置未确认。
GlmOcrRawData _unconfirmedRaw() => GlmOcrRawData(
  mdResults: '题干文字',
  layoutDetails: [
    [
      _block(
        bbox: [10, 10, 60, 30],
        label: 'image',
        nativeLabel: 'image',
        width: 200,
        height: 100,
      ),
    ],
  ],
  transform: const OcrRequestTransform(
    srcW: 200,
    srcH: 100,
    reqW: 200,
    reqH: 100,
    padX: 0,
    padY: 0,
  ),
);

GlmOcrResult _unconfirmedResult() => GlmOcrResult(
  markdown: '题干文字',
  rawData: _unconfirmedRaw(),
  totalTokens: 10,
);

/// 多段题干：图块应插在“第二段”文字与 y 公式之间（md 锚定交错）。
GlmOcrResult _multiSegmentResult() {
  final raw = GlmOcrRawData(
    mdResults:
        '第一段\n\n\$\$x^2\$\$\n\n![](page=0,bbox=[10, 5, 60, 25])\n\n第二段\n\n\$\$y\$\$\n\n第三段\n\nA. 1\nB. 2',
    layoutDetails: [
      [
        _block(
          bbox: [10, 5, 60, 25],
          label: 'image',
          nativeLabel: 'image',
          width: 100,
          height: 50,
        ),
      ],
    ],
    transform: _figureTransform,
  );
  return GlmOcrResult(markdown: raw.mdResults, rawData: raw, totalTokens: 10);
}

final _simRoot = p.join(
  Platform.environment['HOME'] ?? '',
  'workspace',
  'batch14-work',
  'sim-tmp-c',
  'b14-sim-c-m2',
);
var _testCounter = 0;
var _initialized = false;

late QuizDatabase _db;
late Directory _dataDir;
late QuestionRepository _repo;
late _MemoryKeyBackend _keyBackend;
late DateTime _fakeNow;

DateTime _clock() => _fakeNow;

/// 每道测试开头调：在 runAsync 里建临时数据目录 + 内存库 + 假 key。
Future<void> _init(WidgetTester tester) async {
  await tester.runAsync(() async {
    _fakeNow = DateTime(2026, 11, 18, 12, 0, 0);
    _testCounter++;
    _dataDir = Directory(p.join(_simRoot, 't$_testCounter'));
    await _dataDir.create(recursive: true);
    AppDatabase.testDataDirectory = _dataDir.path;
    _db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(_db);
    _repo = QuestionRepository(AppDatabase.instance);
    _keyBackend = _MemoryKeyBackend();
    await OcrKeyStore(backend: _keyBackend).setApiKey('fake-test-key');
    FileLifecycleGuard.instance.debugClearPendingForTest();
    FileLifecycleGuard.instance.debugClearStagingForTest();
    _initialized = true;
  });
}

/// 每道测试结尾调：在 runAsync 里关库、清目录重定向、删临时目录。
Future<void> _dispose(WidgetTester tester) async {
  if (!_initialized) return;
  _initialized = false;
  await tester.runAsync(() async {
    FileLifecycleGuard.instance.debugClearPendingForTest();
    FileLifecycleGuard.instance.debugClearStagingForTest();
    try {
      await AppDatabase.resetForTest();
    } catch (_) {}
    AppDatabase.testDataDirectory = null;
    try {
      await _dataDir.delete(recursive: true);
    } catch (_) {}
  });
}

/// 100×50 纯色切片字节。
Uint8List _slicePng({int width = 100, int height = 50, int seed = 1}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(10 + seed, 20, 30));
  return img.encodePng(image);
}

Future<String> _writeSlice(
  String name, {
  int seed = 1,
  Uint8List? bytes,
}) async {
  final data = bytes ?? _slicePng(seed: seed);
  final rel = 'slices/$name.png';
  final abs = p.join(_dataDir.path, rel);
  await File(abs).parent.create(recursive: true);
  await File(abs).writeAsBytes(data);
  return rel;
}

Future<Question> _insertQuestion({
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
  await AppDatabase.upsertQuestionInto(_db, q);
  return q;
}

Future<Question> _reload(String id) async => (await _repo.questionById(id))!;

OcrWorker _workerWith(OcrRecognizer recognizer) => OcrWorker(
  database: AppDatabase.instance,
  keyStore: OcrKeyStore(backend: _keyBackend),
  recognizer: recognizer,
  clock: _clock,
);

OcrJob _completedJob(String questionId) => OcrJob(
  id: 'j1',
  questionId: questionId,
  status: OcrJobStatus.completed,
  createdAt: _fakeNow,
  updatedAt: _fakeNow,
);

Future<void> _pumpSection(
  WidgetTester tester, {
  required Question question,
  required Uint8List sliceBytes,
  Future<bool> Function(String figureId)? onDeleteFigure,
  Future<void> Function()? onRerecognize,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: OcrStemSection(
            question: question,
            jobs: [_completedJob(question.id)],
            hasApiKey: true,
            sliceBytes: sliceBytes,
            onSaveEdited: (_) async => true,
            onAcceptCandidate: (_) async => true,
            onDismissCandidate: () async {},
            onRerecognize: () async => onRerecognize?.call(),
            onDeleteFigure: onDeleteFigure,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// b11_8 同款有界手动 pump：每轮 pump 一帧看条件，再切回真实异步
/// 等一轮、再 pump，直到条件成立或超限失败。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  int maxRounds = 60,
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

/// 渲染器根 Column 的子 widget 列表（题干段按阅读顺序排）。
List<Widget> _rendererChildren(WidgetTester tester) {
  final col = tester.widget<Column>(
    find
        .descendant(
          of: find.byType(QuestionContentRenderer),
          matching: find.byType(Column),
        )
        .first,
  );
  return col.children;
}

void main() {
  setUpAll(() async {
    await Directory(_simRoot).create(recursive: true);
  });

  tearDownAll(() async {
    AppDatabase.testDataDirectory = null;
    try {
      await Directory(_simRoot).delete(recursive: true);
    } catch (_) {}
  });

  group('M2 模拟用户核验 #7–#12', () {
    testWidgets('#7 图块独立成块：worker 自动应用后详情页内容序列里有独立图块', (
      tester,
    ) async {
      await _init(tester);
      late Question stored;
      late Uint8List sliceBytes;
      late String cropPath;
      try {
        await tester.runAsync(() async {
          sliceBytes = _slicePng();
          final slice = await _writeSlice('q1', bytes: sliceBytes);
          final q = await _insertQuestion(id: 'q1', slicePath: slice);
          final worker = _workerWith(_FakeRecognizer([_figureResult()]));
          await worker.enqueueForQuestion(q);
          expect(await worker.processOne(), isTrue);
          stored = await _reload('q1');
          final figures = parseOcrFigures(stored.ocrFigures);
          expect(figures.length, 1);
          cropPath = figures.single.cropPath;
          expect(
            File(AppDatabase.resolveDataPath(cropPath)!).existsSync(),
            isTrue,
          );
          expect(stored.ocrStem, contains('看图求值'));
        });
        await _pumpSection(tester, question: stored, sliceBytes: sliceBytes);
        // 题干文字在，图块以独立 FigureImageView 显示，不是只藏在切片原图里。
        // （题干经 QuestionContentRenderer 渲染成 RichText，textContaining
        // 默认不找 RichText，必须传 findRichText: true。）
        expect(
          find.textContaining('看图求值', findRichText: true),
          findsOneWidget,
        );
        expect(find.byType(FigureImageView), findsOneWidget);
        expect(
          find.byKey(ValueKey('figure-image-$cropPath')),
          findsOneWidget,
        );
        // 顺序：题干文字在上、图块在下（内容序列 [Text, Figure]）。
        final children = _rendererChildren(tester);
        expect(children.length, 2);
        expect(children[0], isA<RichText>());
        expect(children[1], isA<Padding>());
        expect(
          tester.getCenter(find.byType(FigureImageView)).dy,
          greaterThan(tester.getCenter(find.byWidget(children[0])).dy),
        );
        // 题干里不得外露 md 图引用的原文（![](page=0,bbox=...) 是机器
        // 锚点，不是给用户看的文字）。——放最后：先把“图块成块 + 顺序”
        // 的证据跑完，再判这条（当前实现会把引用原文留在题干里显示，
        // 本断言预期失败，见模块报告 FAIL-7-1）。
        expect(
          find.textContaining('page=0', findRichText: true),
          findsNothing,
          reason: '题干不得外露 md 图引用原文',
        );
      } finally {
        await _dispose(tester);
      }
    });

    testWidgets('#7b 图块按阅读顺序插在多段题干之间（公式前/后不串位）', (
      tester,
    ) async {
      await _init(tester);
      late Question stored;
      late Uint8List sliceBytes;
      try {
        await tester.runAsync(() async {
          sliceBytes = _slicePng();
          final slice = await _writeSlice('q1', bytes: sliceBytes);
          final q = await _insertQuestion(id: 'q1', slicePath: slice);
          final worker = _workerWith(_FakeRecognizer([_multiSegmentResult()]));
          await worker.enqueueForQuestion(q);
          expect(await worker.processOne(), isTrue);
          stored = await _reload('q1');
          expect(parseOcrFigures(stored.ocrFigures).length, 1);
        });
        await _pumpSection(tester, question: stored, sliceBytes: sliceBytes);
        expect(find.byType(FigureImageView), findsOneWidget);
        // 内容序列：[文字, 公式 x², 文字(含第二段), 图块, 公式 y, 文字]——
        // 图块在“第二段”文字之后、y 公式之前，不在序列末尾、不在开头。
        final children = _rendererChildren(tester);
        expect(children.length, 6);
        expect(children[0], isA<RichText>());
        expect(children[1], isA<Padding>()); // x² 公式
        expect(children[2], isA<RichText>()); // 第二段文字
        expect(children[3], isA<Padding>()); // 图块
        expect(children[4], isA<Padding>()); // y 公式
        expect(children[5], isA<RichText>());
        final figurePadding = children[3] as Padding;
        expect(figurePadding.child, isA<FigureImageView>());
        // 几何顺序同样成立：图块中心在第二段文字之下、y 公式之上。
        // （用根 Column 直系子 widget 定位：公式内部也有 RichText，
        // 不能按类型全局找下标。）
        final figureDy = tester.getCenter(find.byType(FigureImageView)).dy;
        expect(
          figureDy,
          greaterThan(tester.getCenter(find.byWidget(children[2])).dy),
        );
        expect(
          figureDy,
          lessThan(tester.getCenter(find.byWidget(children[4])).dy),
        );
      } finally {
        await _dispose(tester);
      }
    });

    testWidgets('#8 页眉装饰图不成块：header_image 不进图块区', (tester) async {
      await _init(tester);
      late Question stored;
      late Uint8List sliceBytes;
      try {
        await tester.runAsync(() async {
          sliceBytes = _slicePng();
          final slice = await _writeSlice('q1', bytes: sliceBytes);
          final q = await _insertQuestion(id: 'q1', slicePath: slice);
          final worker = _workerWith(_FakeRecognizer([_headerOnlyResult()]));
          await worker.enqueueForQuestion(q);
          expect(await worker.processOne(), isTrue);
          stored = await _reload('q1');
          expect(stored.ocrFigures, '[]');
          expect(stored.ocrStem, contains('政治选择题题干文字'));
        });
        await _pumpSection(tester, question: stored, sliceBytes: sliceBytes);
        expect(
          find.textContaining('政治选择题题干文字', findRichText: true),
          findsOneWidget,
        );
        expect(find.byType(FigureImageView), findsNothing);
        expect(find.text('位置未确认'), findsNothing);
      } finally {
        await _dispose(tester);
      }
    });

    testWidgets('#8b 页眉装饰图不成块：政治卷 p01 真实样本尺寸与坐标', (
      tester,
    ) async {
      await _init(tester);
      late Question stored;
      late Uint8List sliceBytes;
      try {
        await tester.runAsync(() async {
          // p01 真实样本：页 2400×1737、header_image [57, 50, 177, 170]、
          // 请求图 3840×2779（padX=720、padY=521）。
          sliceBytes = _slicePng(width: 2400, height: 1737, seed: 3);
          final slice = await _writeSlice('p01', bytes: sliceBytes);
          final q = await _insertQuestion(id: 'p01', slicePath: slice);
          final raw = GlmOcrRawData(
            mdResults:
                '![](page=0,bbox=[57, 50, 177, 170])\n\n政治卷第一题题干',
            layoutDetails: [
              [
                _block(
                  bbox: [57, 50, 177, 170],
                  label: 'image',
                  nativeLabel: 'header_image',
                  width: 3840,
                  height: 2779,
                ),
                _block(
                  bbox: [720, 600, 3000, 900],
                  label: 'text',
                  width: 3840,
                  height: 2779,
                  index: 1,
                  content: '政治卷第一题题干',
                ),
              ],
            ],
            transform: const OcrRequestTransform(
              srcW: 2400,
              srcH: 1737,
              reqW: 3840,
              reqH: 2779,
              padX: 720,
              padY: 521,
            ),
          );
          final result = GlmOcrResult(
            markdown: raw.mdResults,
            rawData: raw,
            totalTokens: 10,
          );
          final worker = _workerWith(_FakeRecognizer([result]));
          await worker.enqueueForQuestion(q);
          expect(await worker.processOne(), isTrue);
          stored = await _reload('p01');
          expect(stored.ocrFigures, '[]');
        });
        await _pumpSection(tester, question: stored, sliceBytes: sliceBytes);
        expect(find.byType(FigureImageView), findsNothing);
      } finally {
        await _dispose(tester);
      }
    });

    testWidgets('#9 位置未确认有标注：锚定失败的图块明确标“位置未确认”', (
      tester,
    ) async {
      await _init(tester);
      late Question stored;
      late Uint8List sliceBytes;
      try {
        await tester.runAsync(() async {
          // 切片 200×100，与 _unconfirmedRaw 的坐标空间一致。
          final image = img.Image(width: 200, height: 100);
          img.fill(image, color: img.ColorRgb8(11, 21, 31));
          sliceBytes = img.encodePng(image);
          final slice = await _writeSlice('q1', bytes: sliceBytes);
          final q = await _insertQuestion(id: 'q1', slicePath: slice);
          final worker = _workerWith(_FakeRecognizer([_unconfirmedResult()]));
          await worker.enqueueForQuestion(q);
          expect(await worker.processOne(), isTrue);
          stored = await _reload('q1');
          final figures = parseOcrFigures(stored.ocrFigures);
          expect(figures.length, 1);
          expect(figures.single.unconfirmed, isTrue);
        });
        await _pumpSection(tester, question: stored, sliceBytes: sliceBytes);
        // 图块在，但明确标了位置未确认，不静默当成已确认顺序展示。
        expect(find.byType(FigureImageView), findsOneWidget);
        expect(find.text('位置未确认'), findsOneWidget);
        final children = _rendererChildren(tester);
        expect(children.last, isA<Padding>());
        expect((children.last as Padding).child, isA<FigureImageView>());
      } finally {
        await _dispose(tester);
      }
    });

    testWidgets('#10 重识别与重框：新结果替换图块；重框后旧图不展示、显等待文案', (
      tester,
    ) async {
      await _init(tester);
      late Question stored;
      late Uint8List sliceBytes;
      late String firstCrop;
      var rerecognizeRequested = false;
      try {
        await tester.runAsync(() async {
          sliceBytes = _slicePng();
          final slice = await _writeSlice('q1', bytes: sliceBytes);
          final q = await _insertQuestion(id: 'q1', slicePath: slice);
          final worker = _workerWith(_FakeRecognizer([_figureResult()]));
          await worker.enqueueForQuestion(q);
          expect(await worker.processOne(), isTrue);
          stored = await _reload('q1');
          firstCrop = parseOcrFigures(stored.ocrFigures).single.cropPath;
        });
        // --- (a) 点“重新识别”：先验证按钮调起入队回调；再由测试体走
        // 真入队（与详情页 _notifier.rerecognizeCurrent 调的
        // enqueueOcrForQuestion 同一入队函数）+ 真 worker 跑第二次
        // 识别（假识别器返回新位置的图块；真实 GLM 网络调用需 Win11+key）。
        // 回调里不直接做真实 IO：testWidgets 的 fake async 下回调内
        // 的 runAsync 与测试体后续的 runAsync 会重入（见运行记录），
        // 故回调只记 flag，IO 由测试体在 runAsync 里做。
        await _pumpSection(
          tester,
          question: stored,
          sliceBytes: sliceBytes,
          onRerecognize: () async {
            rerecognizeRequested = true;
          },
        );
        expect(find.text('重新识别'), findsOneWidget);
        expect(find.byType(FigureImageView), findsOneWidget);
        await tester.tap(find.text('重新识别'));
        await tester.pumpAndSettle();
        expect(rerecognizeRequested, isTrue);
        late Question afterRe;
        late String secondCrop;
        await tester.runAsync(() async {
          final current = await _reload('q1');
          final job = await enqueueOcrForQuestion(AppDatabase.instance, current);
          expect(job, isNotNull);
          final worker = _workerWith(_FakeRecognizer([_figureResult2()]));
          expect(await worker.processOne(), isTrue);
          afterRe = await _reload('q1');
          final figures = parseOcrFigures(afterRe.ocrFigures);
          expect(figures.length, 1);
          expect(figures.single.bbox2d, [50, 30, 90, 45]);
          secondCrop = figures.single.cropPath;
          expect(secondCrop, isNot(firstCrop));
          expect(
            File(AppDatabase.resolveDataPath(secondCrop)!).existsSync(),
            isTrue,
          );
        });
        // 新结果回来后界面只剩新图块，旧图块不残留。
        await _pumpSection(
          tester,
          question: afterRe,
          sliceBytes: sliceBytes,
        );
        expect(find.byType(FigureImageView), findsOneWidget);
        expect(
          find.byKey(ValueKey('figure-image-$secondCrop')),
          findsOneWidget,
        );
        expect(
          find.byKey(ValueKey('figure-image-$firstCrop')),
          findsNothing,
        );
        // --- (b) 重框：换框 + 换切片（详情页“重新框选”确认后调的
        // 同一 repo 入口；BoxEditor 点按本身需 Win11 真机）。
        late Question afterRebox;
        late Uint8List sliceBytes2;
        await tester.runAsync(() async {
          sliceBytes2 = _slicePng(seed: 7);
          final slice2 = await _writeSlice('q1-v2', bytes: sliceBytes2);
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
          await _repo.replaceQuestionBoxesAndSlice(
            'q1',
            [box],
            slicePath: slice2,
            sliceWidth: 100,
            sliceHeight: 50,
          );
          afterRebox = await _reload('q1');
          expect(afterRebox.slicePath, slice2);
        });
        await _pumpSection(
          tester,
          question: afterRebox,
          sliceBytes: sliceBytes2,
        );
        // 旧图块立即不展示，图块区显示等待识别。
        expect(find.byType(FigureImageView), findsNothing);
        expect(
          find.byKey(const Key('ocr-figures-stale-banner')),
          findsOneWidget,
        );
        expect(find.text('已重新框选，等待识别'), findsOneWidget);
      } finally {
        await _dispose(tester);
      }
    });

    testWidgets('#11 纠错编辑器删图块：保存后图块消失、该段回退整题原图、题目还在', (
      tester,
    ) async {
      await _init(tester);
      late Question stored;
      late Uint8List sliceBytes;
      late String cropPath;
      var deleteRequested = false;
      String? deletedFigureId;
      try {
        await tester.runAsync(() async {
          sliceBytes = _slicePng();
          final slice = await _writeSlice('q1', bytes: sliceBytes);
          final q = await _insertQuestion(id: 'q1', slicePath: slice);
          final worker = _workerWith(_FakeRecognizer([_figureResult()]));
          await worker.enqueueForQuestion(q);
          expect(await worker.processOne(), isTrue);
          stored = await _reload('q1');
          cropPath = parseOcrFigures(stored.ocrFigures).single.cropPath;
        });
        await _pumpSection(
          tester,
          question: stored,
          sliceBytes: sliceBytes,
          // 回调只记 flag 并返回 true（编辑器据此显示“已删除”段）；
          // 真正的落库由测试体随后在 runAsync 里用与详情页
          // DetailNotifier.deleteFigure 同款逻辑做（deleteFigureFromQuestion
          // + repo.save 即时落库，D-125）。回调内直接做真实 IO 会与
          // 测试体后续的 runAsync 重入（见运行记录）。
          onDeleteFigure: (figureId) async {
            deleteRequested = true;
            deletedFigureId = figureId;
            return true;
          },
        );
        expect(find.byType(FigureImageView), findsOneWidget);
        await tester.tap(find.text('编辑题干'));
        await tester.pumpAndSettle();
        expect(find.text('删除配图'), findsOneWidget);
        await tester.tap(find.text('删除配图'));
        await _pumpUntil(
          tester,
          () => find.text('配图已删除，以下为整题原图').evaluate().isNotEmpty,
          reason: '删除配图后未显示回退文案',
        );
        expect(deleteRequested, isTrue);
        expect(deletedFigureId, isNotNull);
        // 库里图块已消失（即时落库，不等“保存修改”）；题目本身还在，
        // 题干 intact；旧裁图文件不立即删（进孤儿清理，见 D-125）。
        late Question afterDelete;
        await tester.runAsync(() async {
          final current = await _reload('q1');
          final updated = deleteFigureFromQuestion(current, deletedFigureId!);
          expect(identical(updated, current), isFalse);
          await _repo.save(updated);
          afterDelete = await _reload('q1');
          expect(parseOcrFigures(afterDelete.ocrFigures), isEmpty);
          expect(afterDelete.ocrStem, contains('看图求值'));
          expect(
            File(AppDatabase.resolveDataPath(cropPath)!).existsSync(),
            isTrue,
          );
        });
        // 退出编辑器、按新数据重泵：图块区无图，题干仍在。
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        await _pumpSection(
          tester,
          question: afterDelete,
          sliceBytes: sliceBytes,
        );
        expect(find.byType(FigureImageView), findsNothing);
        expect(
          find.textContaining('看图求值', findRichText: true),
          findsOneWidget,
        );
      } finally {
        await _dispose(tester);
      }
    });

    testWidgets('#12 图块不丢题干：裁图失败时题干照常写回显示', (tester) async {
      await _init(tester);
      late Question stored;
      late Uint8List garbageBytes;
      try {
        await tester.runAsync(() async {
          // 切片文件是解不出的垃圾字节 → 裁图失败（FigureWriteException）。
          garbageBytes = Uint8List.fromList(
            List<int>.generate(64, (i) => (i * 7 + 3) % 256),
          );
          final slice = await _writeSlice('q1', bytes: garbageBytes);
          final q = await _insertQuestion(id: 'q1', slicePath: slice);
          final worker = _workerWith(_FakeRecognizer([_figureResult()]));
          await worker.enqueueForQuestion(q);
          expect(await worker.processOne(), isTrue);
          stored = await _reload('q1');
          // D-127 降级：图块整批弃用（ocr_figures='[]'），题干照常写回。
          expect(stored.ocrFigures, '[]');
          expect(stored.ocrStem, contains('看图求值'));
        });
        await _pumpSection(
          tester,
          question: stored,
          sliceBytes: garbageBytes,
        );
        expect(
          find.textContaining('看图求值', findRichText: true),
          findsOneWidget,
        );
        expect(find.byType(FigureImageView), findsNothing);
        // 盘上没有残留的无效图块文件（只有切片本身）。
        await tester.runAsync(() async {
          final slicesDir = Directory(p.join(_dataDir.path, 'slices'));
          final names = slicesDir
              .listSync()
              .map((e) => p.basename(e.path))
              .toList();
          expect(names, ['q1.png']);
        });
      } finally {
        await _dispose(tester);
      }
    });
  });
}
