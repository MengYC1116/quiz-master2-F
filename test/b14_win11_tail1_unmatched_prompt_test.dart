// Win11 反馈尾巴 1：手动图块未匹配时给用户可见提示。
// acceptCandidateStem 返回 AcceptedCandidate（题 + 未匹配 ID），
// 两 Notifier 的 acceptOcrCandidateOutcome 把它带到页面；接受成功且
// 有未匹配时页面弹一句“有 N 张手动放置的图块未匹配上，已保留在末尾”，
// 全部匹配上时仍是原来的“已用新的识别结果替换”，一次接受只提示一次。
//
// 基建照抄 b14_win11_pkg3_wiring_test.dart（真实库 + 真实文件系统）。
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
import 'package:quiz_master2/modules/organize/organize_page.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';
import 'package:quiz_master2/state/detail_notifier.dart';
import 'package:quiz_master2/state/organize_notifier.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/theme/app_theme.dart';

const _figureTransform = OcrRequestTransform(
  srcW: 100,
  srcH: 50,
  reqW: 100,
  reqH: 50,
  padX: 0,
  padY: 0,
);

/// 带题目插图块的待接受 raw 包（两个图块，请求坐标 [10, 5, 60, 25]
/// 与 [70, 30, 95, 45]）。
GlmOcrRawData figureRaw({
  String? inputHash,
  OcrCandidateStatus status = OcrCandidateStatus.none,
  List<List<int>> imageBboxes = const [
    [10, 5, 60, 25],
    [70, 30, 95, 45],
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

  Future<String> writeCropFile(String rel, {int seed = 2}) async {
    final image = img.Image(width: 10, height: 10);
    img.fill(image, color: img.ColorRgb8(30 + seed, 40, 50));
    final bytes = img.encodePng(image);
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
    List<OcrFigure> figures = const [],
    int? sliceWidth,
    int? sliceHeight,
    String? questionType,
    String? questionTypeSource,
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
      questionType: questionType,
      questionTypeSource: questionTypeSource ?? 'unclassified',
    );
    await AppDatabase.upsertQuestionInto(db, q);
    return q;
  }

  Future<Question> reload(String id) async {
    final row = await repo.questionById(id);
    return row!;
  }

  ProviderContainer organizeContainer() {
    final container = ProviderContainer.test(
      overrides: [repositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
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

  /// 待接受的题：一张能匹配上的 manual 图块（旧裁图保留）+ 可选一张
  /// 匹配不上的 manual 图块（裁图区域不在新派生结果里，接受后保留
  /// 在末尾、ID 加 -manual 后缀）。
  Future<Question> seedAcceptQuestion({required bool unmatched}) async {
    final slice = await writeSlice('q1');
    final hash = await sliceHash(slice);
    await writeCropFile('slices/old-a.png', seed: 2);
    final raw = figureRaw(
      inputHash: hash,
      status: OcrCandidateStatus.pending,
    );
    final derived = buildOcrFigures(
      questionId: 'q1',
      raw: raw,
      transform: raw.transform,
      slicePath: slice,
      inputHash: hash,
    );
    expect(derived.length, 2);
    final oldFigs = <OcrFigure>[
      derived[0].copyWith(
        anchorSource: 'manual',
        anchorRef: '1',
        cropPath: 'slices/old-a.png',
      ),
    ];
    if (unmatched) {
      await writeCropFile('slices/old-u.png', seed: 3);
      oldFigs.add(
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
      );
    }
    return insertQuestion(
      id: 'q1',
      slicePath: slice,
      contentVersion: 5,
      ocrManualEdited: true,
      ocrStem: '旧题干',
      ocrRaw: raw.toJsonString(),
      figures: oldFigs,
      // 题型人工指定：包 4 的 refresh 末尾自动重算只算“待确认且非人工”
      // 的题，人工指定跳过——否则重算写库会让版本在接受前先 +1，
      // 接受后的绝对版本断言变竞态。
      questionType: 'choice_single',
      questionTypeSource: 'manual',
    );
  }

  setUp(() async {
    db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(db);
    repo = QuestionRepository(AppDatabase.instance);
    // FR-45 后续（slices 污染）：同 b13_p1_1——tearDown 的 resetForTest()
    // 置 null 后，从第 2 个测试起 dataDirectoryPath() 读到真实目录，
    // 图块版本切片写进真实 slices/（P3 批量 2 实测本文件 +7）。setUp 先给
    // testDataDirectory 指全新临时目录，再读路径。
    final tmpDataDir = await Directory.systemTemp.createTemp('qm2-tail1-');
    AppDatabase.testDataDirectory = tmpDataDir.path;
    dataDir = Directory(AppDatabase.dataDirectoryPath());
    await dataDir.create(recursive: true);
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

  group('acceptOcrCandidateOutcome 回传未匹配图块', () {
    test('整理页：有未匹配时 outcome 带 ID，题已落库、图块保留在末尾', () async {
      await seedAcceptQuestion(unmatched: true);
      final container = organizeContainer();
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      final outcome = await notifier.acceptOcrCandidateOutcome();
      expect(outcome.accepted, isTrue);
      expect(outcome.reason, isNull);
      expect(outcome.unmatchedManualIds, ['figure-q1-9-manual']);
      final stored = await reload('q1');
      expect(stored.contentVersion, 6);
      final figs = parseOcrFigures(stored.ocrFigures);
      expect(figs.last.id, 'figure-q1-9-manual');
      expect(figs.last.anchorSource, 'manual');
    });

    test('整理页：全部匹配上时 unmatched 为空', () async {
      await seedAcceptQuestion(unmatched: false);
      final container = organizeContainer();
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      final outcome = await notifier.acceptOcrCandidateOutcome();
      expect(outcome.accepted, isTrue);
      expect(outcome.reason, isNull);
      expect(outcome.unmatchedManualIds, isEmpty);
    });

    test('详情页：有未匹配时 outcome 带 ID', () async {
      await seedAcceptQuestion(unmatched: true);
      final container = detailContainer();
      final notifier = container.read(detailProvider.notifier);
      await notifier.load();
      final outcome = await notifier.acceptOcrCandidateOutcome();
      expect(outcome.accepted, isTrue);
      expect(outcome.reason, isNull);
      expect(outcome.unmatchedManualIds, ['figure-q1-9-manual']);
    });
  });

  group('两页接受候选：未匹配提示（端到端）', () {
    // 假异步区里等真实异步落定：与接线测试同款有界 flush（不用
    // pumpAndSettle，加载圈一直转）；真实文件/库 I/O 包在 runAsync 里。
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

    /// 等指定文字出现（整页首查 / 切片 hash / 接受落库都是真实异步）；
    /// 超时由调用方的 findsOneWidget 明确报失败。
    Future<void> waitForText(WidgetTester tester, String text) async {
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () async => await Future<void>.delayed(
            const Duration(milliseconds: 20),
          ),
        );
        if (find.text(text).evaluate().isNotEmpty) return;
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
      await waitForText(tester, '编辑题干');
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
      await waitForText(tester, '编辑题干');
      expect(find.text('编辑题干'), findsOneWidget);
    }

    /// 非编辑态横幅“查看新旧对比” → 编辑器里“用新结果替换” → 等提示出现。
    Future<void> acceptCandidate(WidgetTester tester) async {
      await waitForText(tester, '有新的识别结果');
      await tester.ensureVisible(find.text('查看新旧对比'));
      await tester.pump();
      await tester.tap(find.text('查看新旧对比'));
      await flushRounds(tester);
      await tester.ensureVisible(find.text('用新结果替换'));
      await tester.pump();
      await tester.tap(find.text('用新结果替换'));
      await flushRounds(tester, rounds: 15);
    }

    testWidgets('整理页：有未匹配时弹提示，不弹成功提示', (tester) async {
      await tester.runAsync(() => seedAcceptQuestion(unmatched: true));
      await pumpOrganizePage(tester);
      await acceptCandidate(tester);
      await waitForText(tester, '有 1 张手动放置的图块未匹配上，已保留在末尾');
      expect(
        find.text('有 1 张手动放置的图块未匹配上，已保留在末尾'),
        findsOneWidget,
      );
      expect(find.text('已用新的识别结果替换'), findsNothing);
      // 图块确实保留在末尾（提示不是空话）。
      final stored = (await tester.runAsync(() => reload('q1')))!;
      expect(parseOcrFigures(stored.ocrFigures).last.id, 'figure-q1-9-manual');
    });

    testWidgets('详情页：有未匹配时弹提示，不弹成功提示', (tester) async {
      await tester.runAsync(() => seedAcceptQuestion(unmatched: true));
      await pumpDetailPage(tester);
      await acceptCandidate(tester);
      await waitForText(tester, '有 1 张手动放置的图块未匹配上，已保留在末尾');
      expect(
        find.text('有 1 张手动放置的图块未匹配上，已保留在末尾'),
        findsOneWidget,
      );
      expect(find.text('已用新的识别结果替换'), findsNothing);
      final stored = (await tester.runAsync(() => reload('q1')))!;
      expect(parseOcrFigures(stored.ocrFigures).last.id, 'figure-q1-9-manual');
    });

    testWidgets('整理页：全部匹配上时只弹成功提示', (tester) async {
      await tester.runAsync(() => seedAcceptQuestion(unmatched: false));
      await pumpOrganizePage(tester);
      await acceptCandidate(tester);
      await waitForText(tester, '已用新的识别结果替换');
      expect(find.text('已用新的识别结果替换'), findsOneWidget);
      expect(find.textContaining('未匹配上'), findsNothing);
      // 接受后查库：候选已接受、版本 +1、图块无 -manual 后缀。
      // runAsync 还顺手排空接受后的真实异步收尾，否则 tearDown 的
      // db.close() 会等它等到挂住（包 3 接线实测的假异步区教训）。
      final stored = (await tester.runAsync(() => reload('q1')))!;
      expect(
        GlmOcrRawData.tryParse(stored.ocrRaw)?.candidateStatus,
        OcrCandidateStatus.accepted,
      );
      expect(stored.contentVersion, 6);
      final figs = parseOcrFigures(stored.ocrFigures);
      expect(figs.map((f) => f.id).toList(), ['figure-q1-0', 'figure-q1-1']);
      expect(figs.any((f) => f.id.contains('-manual')), isFalse);
    });

    testWidgets('详情页：全部匹配上时只弹成功提示', (tester) async {
      await tester.runAsync(() => seedAcceptQuestion(unmatched: false));
      await pumpDetailPage(tester);
      await acceptCandidate(tester);
      await waitForText(tester, '已用新的识别结果替换');
      expect(find.text('已用新的识别结果替换'), findsOneWidget);
      expect(find.textContaining('未匹配上'), findsNothing);
      final stored = (await tester.runAsync(() => reload('q1')))!;
      expect(
        GlmOcrRawData.tryParse(stored.ocrRaw)?.candidateStatus,
        OcrCandidateStatus.accepted,
      );
      expect(stored.contentVersion, 6);
      final figs = parseOcrFigures(stored.ocrFigures);
      expect(figs.map((f) => f.id).toList(), ['figure-q1-0', 'figure-q1-1']);
      expect(figs.any((f) => f.id.contains('-manual')), isFalse);
    });
  });
}
