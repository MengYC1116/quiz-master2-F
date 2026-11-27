// 十三批 M5：纠错 UI 测试——状态推导 / 拼回 / 保存规则 / 公式裁图 /
// 编辑器组件 / 候选预览与接受忽略 / 编辑中 OCR 返回不刷掉 /
// 活页内刷新守门 / 重框自动入队。
// 只跑本模块 + 邻近回归，不跑全量（全量是 M7 的事）。
// 测试名不含 LaTeX 源码（M1 同款约定：源码只存在测试数据里，不进名字）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/data_change_events.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/ocr/formula_crop.dart';
import 'package:quiz_master2/modules/ocr/ocr_stem_section.dart';
import 'package:quiz_master2/modules/ocr/ocr_stem_status.dart';
import 'package:quiz_master2/modules/ocr/question_content.dart';
import 'package:quiz_master2/modules/ocr/question_content_renderer.dart';
import 'package:quiz_master2/modules/ocr/stem_correction.dart';
import 'package:quiz_master2/modules/organize/organize_page.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';
import 'package:quiz_master2/services/import_guess.dart';
import 'package:quiz_master2/services/ocr_queue.dart';
import 'package:quiz_master2/state/detail_notifier.dart';
import 'package:quiz_master2/state/organize_notifier.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/theme/app_theme.dart';

// ---------------------------------------------------------------------------
// 共用构造器
// ---------------------------------------------------------------------------

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

/// 段摘要（类型 + 文本/公式/代码），供拼回往返断言用。
List<(String, String)> _blocksSummary(List<QuestionContentBlock> blocks) =>
    blocks
        .map(
          (b) => switch (b) {
            TextBlock(:final text) => ('text', text),
            FormulaBlock(:final latex, :final displayMode) =>
              ('formula${displayMode ? ':display' : ''}', latex),
            CodeBlock(:final code, :final language) =>
              ('code:${language ?? ''}', code),
            ImageFallbackBlock() => ('image', ''),
            FigureBlock(:final figureId) => ('figure', figureId),
            // WP-C #6 新增块类型（穷举开关配套分支，不改旧断言口径）。
            TableBlock(:final rows) => ('table', rows.length.toString()),
            HeadingBlock(:final text, :final level) =>
              ('heading$level', text),
          },
        )
        .toList();

void main() {
  group('状态推导', () {
    final now = DateTime(2026, 11, 18, 12, 0);
    test('无任务无 key：等待设置 API Key（绝不显示识别中）', () {
      expect(
        deriveOcrStemStatus(
          _q('q1'),
          jobs: const [],
          hasApiKey: false,
          now: now,
        ).label,
        '等待设置 API Key',
      );
    });

    test('无任务有 key：等待识别', () {
      expect(
        deriveOcrStemStatus(
          _q('q1'),
          jobs: const [],
          hasApiKey: true,
          now: now,
        ).label,
        '等待识别',
      );
    });

    test('pending 有 key：等待识别；退避未到：稍后自动重试', () {
      final pending = _job('j1', 'q1', OcrJobStatus.pending);
      expect(
        deriveOcrStemStatus(
          _q('q1'),
          jobs: [pending],
          hasApiKey: true,
          now: now,
        ).label,
        '等待识别',
      );
      final retrying = _job(
        'j1',
        'q1',
        OcrJobStatus.pending,
        availableAt: now.add(const Duration(minutes: 2)),
      );
      expect(
        deriveOcrStemStatus(
          _q('q1'),
          jobs: [retrying],
          hasApiKey: true,
          now: now,
        ).label,
        '稍后自动重试',
      );
    });

    test('pending 无 key：等待设置 API Key（退避也一样）', () {
      final pending = _job(
        'j1',
        'q1',
        OcrJobStatus.pending,
        availableAt: now.add(const Duration(minutes: 10)),
      );
      expect(
        deriveOcrStemStatus(
          _q('q1'),
          jobs: [pending],
          hasApiKey: false,
          now: now,
        ).label,
        '等待设置 API Key',
      );
    });

    test('running 有 key：识别中；running 无 key：等待设置 API Key', () {
      final running = _job('j1', 'q1', OcrJobStatus.running);
      expect(
        deriveOcrStemStatus(
          _q('q1'),
          jobs: [running],
          hasApiKey: true,
          now: now,
        ).label,
        '识别中',
      );
      expect(
        deriveOcrStemStatus(
          _q('q1'),
          jobs: [running],
          hasApiKey: false,
          now: now,
        ).label,
        '等待设置 API Key',
      );
    });

    test('failed 超时：识别失败；failed key 无效：等待设置 API Key', () {
      final timeout = _job(
        'j1',
        'q1',
        OcrJobStatus.failed,
        lastErrorCode: OcrErrorCode.timeout,
      );
      expect(
        deriveOcrStemStatus(
          _q('q1'),
          jobs: [timeout],
          hasApiKey: true,
          now: now,
        ).label,
        '识别失败',
      );
      final badKey = _job(
        'j1',
        'q1',
        OcrJobStatus.failed,
        lastErrorCode: OcrErrorCode.apiKeyInvalid,
      );
      expect(
        deriveOcrStemStatus(
          _q('q1'),
          jobs: [badKey],
          hasApiKey: true,
          now: now,
        ).label,
        '等待设置 API Key',
      );
    });

    test('completed 有题干：识别完成；只有原始结果也是完成（原图回退）', () {
      final done = _job('j1', 'q1', OcrJobStatus.completed);
      expect(
        deriveOcrStemStatus(
          _q('q1', ocrStem: '题干'),
          jobs: [done],
          hasApiKey: true,
          now: now,
        ).label,
        '识别完成',
      );
      expect(
        deriveOcrStemStatus(
          _q('q1', ocrRaw: _raw('原文')),
          jobs: [done],
          hasApiKey: true,
          now: now,
        ).label,
        '识别完成',
      );
    });

    test('无任务但有题干：识别完成', () {
      expect(
        deriveOcrStemStatus(
          _q('q1', ocrStem: '题干'),
          jobs: const [],
          hasApiKey: true,
          now: now,
        ).label,
        '识别完成',
      );
    });

    test('人工改过：已手动修改（哪怕另有任务在跑）', () {
      final running = _job('j1', 'q1', OcrJobStatus.running);
      expect(
        deriveOcrStemStatus(
          _q('q1', ocrStem: '改过的题干', ocrManualEdited: true),
          jobs: [running],
          hasApiKey: true,
          now: now,
        ).label,
        '已手动修改',
      );
    });

    test('多条任务时只看最新一条（按 createdAt）', () {
      final old = _job(
        'j1',
        'q1',
        OcrJobStatus.failed,
        lastErrorCode: OcrErrorCode.timeout,
        createdAt: DateTime(2026, 11, 18, 11, 0),
      );
      final latest = _job(
        'j2',
        'q1',
        OcrJobStatus.running,
        createdAt: DateTime(2026, 11, 18, 12, 0),
      );
      expect(
        deriveOcrStemStatus(
          _q('q1'),
          jobs: [old, latest],
          hasApiKey: true,
          now: now,
        ).label,
        '识别中',
      );
    });
  });

  group('拼回往返', () {
    test('真实题干：解析→拼回→再解析，段序列不变', () {
      const stem =
          '2. 双曲线 \$ 4 x^{2}-y^{2}=4 \$的离心率为\nA. 第一项\nB. 第二项';
      final first = parseQuestionContent(stem);
      final rebuilt = blocksToMarkdown(first);
      expect(_blocksSummary(parseQuestionContent(rebuilt)), _blocksSummary(first));
    });

    test('独立公式：解析→拼回→再解析，段序列不变', () {
      const stem = '求根公式：\$\$x=1\$\$结束';
      final first = parseQuestionContent(stem);
      expect(first.whereType<FormulaBlock>().single.displayMode, isTrue);
      final rebuilt = blocksToMarkdown(first);
      expect(_blocksSummary(parseQuestionContent(rebuilt)), _blocksSummary(first));
    });

    test('代码块：围栏与缩进都在，拼回后仍是代码段', () {
      const stem = '程序如下：\n```python\n    indented()\n```\n结束';
      final first = parseQuestionContent(stem);
      final code = first.whereType<CodeBlock>().single;
      expect(code.code.startsWith('    indented()'), isTrue);
      final rebuilt = blocksToMarkdown(first);
      expect(_blocksSummary(parseQuestionContent(rebuilt)), _blocksSummary(first));
    });

    test('圈号：解析后是文本，拼回不再进公式', () {
      const stem = '选出正确的一项 \$①③\$';
      final first = parseQuestionContent(stem);
      expect(first.length, 1);
      expect(first.single, isA<TextBlock>());
      final rebuilt = blocksToMarkdown(first);
      expect(_blocksSummary(parseQuestionContent(rebuilt)), _blocksSummary(first));
    });
  });

  group('纠错保存规则', () {
    test('人工编辑：版本+1、人工标记、人工调整、候选标志清掉', () {
      final q = _q(
        'q1',
        ocrStem: '旧题干',
        ocrRaw: _raw('旧原文', candidate: true),
        contentVersion: 3,
      );
      expect(hasPendingOcrCandidate(q), isTrue);
      final updated = applyManualStemEdit(q, '新题干');
      expect(updated.ocrStem, '新题干');
      expect(updated.ocrSplitStatus, '人工调整');
      expect(updated.ocrManualEdited, isTrue);
      expect(updated.contentVersion, 4);
      expect(hasPendingOcrCandidate(updated), isFalse);
      // 原始结果不丢：md 还在。
      expect(
        GlmOcrRawData.tryParse(updated.ocrRaw)?.mdResults,
        '旧原文',
      );
    });

    test('接受候选：题干写进、切分状态写回、人工标记保持 1、版本+1', () async {
      // 十三批 P1 第二轮：接受走真实库事务（repo.db.db），不用 fake
      // repo——题先插进真实测试库，返回的就是已保存的题。
      final db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => AppDatabase.resetForTest());
      final q = _q(
        'q1',
        ocrStem: '旧题干',
        ocrRaw: _raw('新题\nA. 一\nB. 二', candidate: true),
        ocrManualEdited: true,
        contentVersion: 5,
      );
      await AppDatabase.upsertQuestionInto(db, q);
      final repo = QuestionRepository(AppDatabase.instance);
      final updated = (await acceptCandidateStem(repo, q)).question;
      // 接受的题干从 raw 包里经 splitStem 取（与预览一致），选项不进题干。
      expect(updated.ocrStem, '新题');
      expect(updated.ocrSplitStatus, '自动切分');
      expect(updated.ocrManualEdited, isTrue);
      expect(updated.contentVersion, 6);
      expect(hasPendingOcrCandidate(updated), isFalse);
      expect(
        GlmOcrRawData.tryParse(updated.ocrRaw)?.candidateStatus,
        OcrCandidateStatus.accepted,
      );
      // 已落库：重读与返回一致。
      final stored = await AppDatabase.instance.questionById('q1');
      expect(stored?.ocrStem, '新题');
      expect(stored?.contentVersion, 6);
      expect(
        GlmOcrRawData.tryParse(stored?.ocrRaw)?.candidateStatus,
        OcrCandidateStatus.accepted,
      );
    });

    test('接受候选：候选未切分时状态写回未切分', () async {
      // 同上：接受走真实库事务，题先插进真实测试库。
      final db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => AppDatabase.resetForTest());
      final q = _q(
        'q1',
        ocrStem: '旧题干',
        ocrRaw: _raw('填空题题干', candidate: true),
        ocrManualEdited: true,
        contentVersion: 1,
      );
      await AppDatabase.upsertQuestionInto(db, q);
      final repo = QuestionRepository(AppDatabase.instance);
      final updated = (await acceptCandidateStem(repo, q)).question;
      expect(updated.ocrSplitStatus, '未切分');
      final stored = await AppDatabase.instance.questionById('q1');
      expect(stored?.ocrSplitStatus, '未切分');
      expect(stored?.contentVersion, 2);
    });

    test('忽略候选：只清标志、版本+1、题干不动；无候选时原样返回', () {
      final q = _q(
        'q1',
        ocrStem: '旧题干',
        ocrRaw: _raw('旧原文', candidate: true),
        contentVersion: 2,
      );
      final updated = dismissOcrCandidateFlag(q);
      expect(updated.ocrStem, '旧题干');
      expect(updated.contentVersion, 3);
      expect(hasPendingOcrCandidate(updated), isFalse);
      expect(
        GlmOcrRawData.tryParse(updated.ocrRaw)?.mdResults,
        '旧原文',
      );
      final noCandidate = _q('q2', ocrStem: '题干', contentVersion: 7);
      final untouched = dismissOcrCandidateFlag(noCandidate);
      expect(untouched.contentVersion, 7);
      expect(untouched.ocrStem, '题干');
    });
  });

  group('公式裁图', () {
    late Uint8List sliceBytes;

    setUp(() {
      final image = img.Image(width: 100, height: 50);
      img.fill(image, color: img.ColorRgb8(255, 255, 255));
      img.fillRect(
        image,
        x1: 0,
        y1: 0,
        x2: 49,
        y2: 49,
        color: img.ColorRgb8(255, 0, 0),
      );
      img.fillRect(
        image,
        x1: 50,
        y1: 0,
        x2: 99,
        y2: 49,
        color: img.ColorRgb8(0, 0, 255),
      );
      sliceBytes = img.encodePng(image);
    });

    test('有 formula 块：按 bbox 裁出小图，尺寸与颜色都对', () {
      final raw = _raw(
        '题干',
        layout: [
          [
            {
              'label': 'formula',
              'bbox_2d': [0, 0, 50, 50],
              'width': 100,
              'height': 50,
              'content': 'x',
              'index': 0,
            },
          ],
        ],
      );
      final cropped = cropFormulaImageBytes(
        sliceBytes: sliceBytes,
        ocrRaw: raw,
        formulaIndex: 0,
      );
      expect(cropped, isNotNull);
      final decoded = img.decodeImage(cropped!)!;
      expect(decoded.width, 50);
      expect(decoded.height, 50);
      final pixel = decoded.getPixel(0, 0);
      expect(pixel.r, 255);
      expect(pixel.g, 0);
      expect(pixel.b, 0);
    });

    test('实测样本只有 text 块：裁不到，返回 null（调用方用整张切片）', () {
      final raw = _raw(
        '题干',
        layout: [
          [
            {
              'label': 'text',
              'bbox_2d': [370, 45, 1605, 187],
              'width': 1975,
              'height': 232,
              'content': '题',
              'index': 0,
            },
          ],
        ],
      );
      expect(
        cropFormulaImageBytes(
          sliceBytes: sliceBytes,
          ocrRaw: raw,
          formulaIndex: 0,
        ),
        isNull,
      );
    });

    test('bbox 越界 / 下标越界 / 坏图：都返回 null，不抛', () {
      final outOfRange = _raw(
        '题干',
        layout: [
          [
            {
              'label': 'formula',
              'bbox_2d': [200, 0, 300, 50],
              'width': 100,
              'height': 50,
              'content': 'x',
              'index': 0,
            },
          ],
        ],
      );
      expect(
        cropFormulaImageBytes(
          sliceBytes: sliceBytes,
          ocrRaw: outOfRange,
          formulaIndex: 0,
        ),
        isNull,
      );
      final oneBox = _raw(
        '题干',
        layout: [
          [
            {
              'label': 'formula',
              'bbox_2d': [0, 0, 50, 50],
              'width': 100,
              'height': 50,
              'content': 'x',
              'index': 0,
            },
          ],
        ],
      );
      expect(
        cropFormulaImageBytes(
          sliceBytes: sliceBytes,
          ocrRaw: oneBox,
          formulaIndex: 1,
        ),
        isNull,
      );
      expect(
        cropFormulaImageBytes(
          sliceBytes: Uint8List.fromList([1, 2, 3]),
          ocrRaw: oneBox,
          formulaIndex: 0,
        ),
        isNull,
      );
    });
  });

  _sectionTests();
  _guardAndNotifierTests();
}

// ---------------------------------------------------------------------------
// 编辑器组件（OcrStemSection + StemEditor）widget 测试
// ---------------------------------------------------------------------------

Future<void> _pumpSection(
  WidgetTester tester, {
  required Question question,
  List<OcrJob> jobs = const [],
  bool hasApiKey = true,
  String? candidateStemOverride,
  Uint8List? sliceBytes,
  void Function()? onSaveEdited,
  void Function()? onAcceptCandidate,
  VoidCallback? onDismissCandidate,
  VoidCallback? onRerecognize,
  Key? sectionKey,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: OcrStemSection(
            key: sectionKey,
            question: question,
            jobs: jobs,
            hasApiKey: hasApiKey,
            candidateStemOverride: candidateStemOverride,
            sliceBytes: sliceBytes,
            onSaveEdited: (stem) async {
              // 直接写全局捕获（不用局部变量中转：局部变量在
              // pumpAndSettle 后才抄给全局会丢掉保存时的值）。
              _lastSavedStem = stem;
              onSaveEdited?.call();
              return true;
            },
            onAcceptCandidate: (stem) async {
              _lastAcceptedStem = stem;
              onAcceptCandidate?.call();
              return true;
            },
            onDismissCandidate: () async => onDismissCandidate?.call(),
            onRerecognize: () async => onRerecognize?.call(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

String _lastSavedStem = '';
String _lastAcceptedStem = '';

Finder _textFieldWithText(String text) => find.byWidgetPredicate(
  (w) => w is TextField && (w.controller?.text ?? '') == text,
);

Uint8List _tinyPng() {
  final image = img.Image(width: 10, height: 10);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  return img.encodePng(image);
}

void _sectionTests() {
  group('识别题干区', () {
    testWidgets('无 key：显示等待设置 API Key，绝不显示识别中', (tester) async {
      await _pumpSection(tester, question: _q('q1'), hasApiKey: false);
      expect(find.text('等待设置 API Key'), findsOneWidget);
      expect(find.text('识别中'), findsNothing);
    });

    testWidgets('识别失败：显示识别失败 + 重试按钮，点重试调入队回调', (tester) async {
      var rereconized = false;
      await _pumpSection(
        tester,
        question: _q('q1'),
        jobs: [_job('j1', 'q1', OcrJobStatus.failed, lastErrorCode: 'timeout')],
        onRerecognize: () => rereconized = true,
      );
      expect(find.text('识别失败'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(rereconized, isTrue);
    });

    testWidgets('识别完成：渲染题干公式 + 显示切分状态，不外露源码', (tester) async {
      await _pumpSection(
        tester,
        question: _q(
          'q1',
          ocrStem: '双曲线 \$ 4 x^{2}-y^{2}=4 \$的离心率',
          ocrSplitStatus: '自动切分',
        ),
        jobs: [_job('j1', 'q1', OcrJobStatus.completed)],
      );
      expect(find.text('识别完成'), findsOneWidget);
      expect(find.text('切分：自动切分'), findsOneWidget);
      expect(find.byType(FormulaView), findsOneWidget);
      expect(find.textContaining('frac'), findsNothing);
      expect(find.textContaining('x^{2}'), findsNothing);
    });

    testWidgets('编辑题干：改文字后保存，公式原样保留', (tester) async {
      await _pumpSection(
        tester,
        question: _q('q1', ocrStem: '甲题干 \$x\$ 结束'),
        jobs: [_job('j1', 'q1', OcrJobStatus.completed)],
      );
      await tester.tap(find.text('编辑题干'));
      await tester.pumpAndSettle();
      expect(find.text('保存修改'), findsOneWidget);
      await tester.enterText(_textFieldWithText('甲题干 '), '甲题干改');
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();
      expect(_lastSavedStem.contains('甲题干改'), isTrue);
      expect(_lastSavedStem.contains('\$x\$'), isTrue);
      expect(find.text('保存修改'), findsNothing);
    });

    testWidgets('公式可删：删后保存，题干里不再有公式', (tester) async {
      await _pumpSection(
        tester,
        question: _q('q1', ocrStem: '已知 \$x\$ 求解'),
        jobs: [_job('j1', 'q1', OcrJobStatus.completed)],
      );
      await tester.tap(find.text('编辑题干'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();
      expect(_lastSavedStem.contains('\$'), isFalse);
      expect(_lastSavedStem.contains('已知'), isTrue);
    });

    testWidgets('公式恢复为原图：显示原图，保存后题干里拿掉该公式', (tester) async {
      await _pumpSection(
        tester,
        question: _q('q1', ocrStem: '已知 \$x\$ 求解'),
        jobs: [_job('j1', 'q1', OcrJobStatus.completed)],
        sliceBytes: _tinyPng(),
      );
      await tester.tap(find.text('编辑题干'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('恢复为原图'));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsWidgets);
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();
      expect(_lastSavedStem.contains('\$'), isFalse);
    });

    testWidgets('代码段：等宽显示，缩进保留', (tester) async {
      await _pumpSection(
        tester,
        question: _q('q1', ocrStem: '```python\n    indented()\n```'),
        jobs: [_job('j1', 'q1', OcrJobStatus.completed)],
      );
      await tester.tap(find.text('编辑题干'));
      await tester.pumpAndSettle();
      final codeField = find.byWidgetPredicate(
        (w) =>
            w is TextField && (w.controller?.text ?? '').startsWith('    indented'),
      );
      expect(codeField, findsOneWidget);
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();
      expect(_lastSavedStem.contains('    indented()'), isTrue);
    });

    testWidgets('候选：查看新旧对比后接受替换', (tester) async {
      await _pumpSection(
        tester,
        question: _q(
          'q1',
          ocrStem: '旧题干',
          ocrRaw: _raw('新题干', candidate: true),
          ocrManualEdited: true,
        ),
        jobs: [_job('j1', 'q1', OcrJobStatus.completed)],
      );
      expect(find.text('有新的识别结果'), findsOneWidget);
      await tester.tap(find.text('查看新旧对比'));
      await tester.pumpAndSettle();
      expect(find.text('新的识别结果'), findsOneWidget);
      expect(find.text('用新结果替换'), findsOneWidget);
      await tester.tap(find.text('用新结果替换'));
      await tester.pumpAndSettle();
      expect(_lastAcceptedStem, '新题干');
    });

    testWidgets('候选：点忽略调忽略回调', (tester) async {
      var dismissed = false;
      await _pumpSection(
        tester,
        question: _q(
          'q1',
          ocrStem: '旧题干',
          ocrRaw: _raw('新题干', candidate: true),
          ocrManualEdited: true,
        ),
        jobs: [_job('j1', 'q1', OcrJobStatus.completed)],
        onDismissCandidate: () => dismissed = true,
      );
      await tester.tap(find.text('忽略'));
      await tester.pumpAndSettle();
      expect(dismissed, isTrue);
    });

    testWidgets('编辑中 OCR 回来了：草稿不刷掉，只显横幅', (tester) async {
      const key = ValueKey('sec-q1');
      await _pumpSection(
        tester,
        question: _q('q1', ocrStem: '旧题干'),
        jobs: [_job('j1', 'q1', OcrJobStatus.completed)],
        sectionKey: key,
      );
      await tester.tap(find.text('编辑题干'));
      await tester.pumpAndSettle();
      await tester.enterText(_textFieldWithText('旧题干'), '用户改的');
      // 同题的新候选到了（worker 只写了 raw，题干未变）：重建同一组件。
      await _pumpSection(
        tester,
        question: _q(
          'q1',
          ocrStem: '旧题干',
          ocrRaw: _raw('新题干', candidate: true),
          ocrManualEdited: true,
        ),
        jobs: [_job('j2', 'q1', OcrJobStatus.completed)],
        sectionKey: key,
      );
      expect(_textFieldWithText('用户改的'), findsOneWidget);
      expect(find.text('有新的识别结果'), findsOneWidget);
      expect(find.text('保存修改'), findsOneWidget);
    });

    testWidgets('编辑器里也不外露源码', (tester) async {
      await _pumpSection(
        tester,
        question: _q('q1', ocrStem: '双曲线 \$ 4 x^{2}-y^{2}=4 \$的离心率'),
        jobs: [_job('j1', 'q1', OcrJobStatus.completed)],
      );
      await tester.tap(find.text('编辑题干'));
      await tester.pumpAndSettle();
      expect(find.textContaining('frac'), findsNothing);
      expect(find.textContaining('x^{2}'), findsNothing);
    });
  });
}

// ---------------------------------------------------------------------------
// 活页内刷新守门 + Notifier 纠错方法 + 详情页保存保留 OCR + 重框入队
// ---------------------------------------------------------------------------

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
  Future<void> saveRecentTask({
    required String kind,
    required String subjectId,
    required String title,
  }) async {}

  @override
  Future<int> organizedTodayCount({DateTime? now}) async => 0;

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

  // FR-45：_refreshRelated（十九批 D1，DetailNotifier.load 内 unawaited）
  // 调 repo.all() + repo.causeRecords()；未覆写时走真实 QuestionRepository
  // → 单例 db getter → 旧 resetForTest 置 null 的窗口里会打开真实演示库
  // 并跑 v2→v8 迁移（本文件 36 号测试“saveEdit 保留 OCR 字段”触发，见
  // batch20-work/p3-fr45/STATUS.md；D-260 起 reset 改为重指全新临时目录，
  // 该窗口已堵上，桩仍保留作纵深防护）。与 _FakeOrganizeRepo
  // 的 all() 同款：直接读内存列表，不碰单例。
  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<CauseRecord>> causeRecords() async => const [];

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

Future<void> _pumpOrganizeGuard(
  WidgetTester tester,
  _FakeOrganizeRepo repo,
) async {
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
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Uint8List _solidPng(int width, int height, int r, int g, int b) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return img.encodePng(image);
}

void _guardAndNotifierTests() {
  group('活页内刷新守门（整理页）', () {
    testWidgets('编辑中 OCR 事件到了：草稿不刷掉，只显横幅；关编辑器后再来才刷新', (
      tester,
    ) async {
      final repo = _FakeOrganizeRepo(
        questions: [
          _q('q1', ocrStem: '甲题干', ocrSplitStatus: '自动切分', contentVersion: 1),
          _q(
            'q2',
            ocrStem: '乙题',
            createdAt: DateTime(2026, 11, 5),
          ),
        ],
      );
      await _pumpOrganizeGuard(tester, repo);
      // 题干是 QuestionContentRenderer 画的 RichText（不是 Text），
      // 用 textContaining 找；状态 chip 是 Text，用 find.text。
      expect(find.textContaining('甲题干', findRichText: true), findsOneWidget);
      expect(find.text('识别完成'), findsOneWidget);

      await tester.ensureVisible(find.text('编辑题干'));
      await tester.tap(find.text('编辑题干'));
      await tester.pumpAndSettle();
      expect(find.text('保存修改'), findsOneWidget);
      await tester.enterText(_textFieldWithText('甲题干'), '用户改的题干');

      // 模拟 OCR 完成写库：新题干 + 候选标志 + completed 任务。
      repo.questions[0] = _q(
        'q1',
        ocrStem: '乙题干',
        ocrRaw: _raw('新题干', candidate: true),
        ocrSplitStatus: '自动切分',
        ocrManualEdited: true,
        contentVersion: 2,
      );
      repo.jobsByQuestion = {
        'q1': [_job('j2', 'q1', OcrJobStatus.completed)],
      };
      DataChangeBus.instance.emit(
        const DataChangeEvent(
          kinds: {DataChangeKind.questions},
          questionId: 'q1',
        ),
      );
      await tester.pumpAndSettle();
      // 草稿一个字没动，编辑器还开着；新题干没刷进来。
      expect(_textFieldWithText('用户改的题干'), findsOneWidget);
      expect(find.text('有新的识别结果'), findsOneWidget);
      expect(find.textContaining('乙题干', findRichText: true), findsNothing);

      // 关编辑器，再来一次事件：这次刷新，显示新题干。
      await tester.ensureVisible(find.text('取消'));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      DataChangeBus.instance.emit(
        const DataChangeEvent(
          kinds: {DataChangeKind.questions},
          questionId: 'q1',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('乙题干', findRichText: true), findsOneWidget);
    });
  });

  group('整理页 Notifier 纠错方法', () {
    test('saveStemEdit：落库规则对，且不重置表单（formResetKey 不动）', () async {
      final repo = _FakeOrganizeRepo(
        questions: [_q('q1', ocrStem: '旧题干', contentVersion: 2)],
      );
      final container = _organizeContainer(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      // build() 里还有一个 microtask 首查 refresh 在竞跑（它也调
      // loadForm、涨 formResetKey）：先沉淀微任务，等两路 refresh
      // 都跑完再读 formResetKey，否则读数靠运气。
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final formKeyBefore = container.read(organizeProvider).formResetKey;
      expect(await notifier.saveStemEdit('新题干'), isTrue);
      final saved = repo.saved.last;
      expect(saved.ocrStem, '新题干');
      expect(saved.ocrSplitStatus, '人工调整');
      expect(saved.ocrManualEdited, isTrue);
      expect(saved.contentVersion, 3);
      expect(container.read(organizeProvider).current?.ocrStem, '新题干');
      expect(container.read(organizeProvider).formResetKey, formKeyBefore);
    });

    test('acceptOcrCandidate / dismissOcrCandidate：落库规则对', () async {
      // 十三批 P1 第二轮：接受走真实库事务（repo.db.db）——q1 同时插进
      // 真实测试库（接受读/写它）与 fake 列表（Notifier 的队列读它）；
      // 忽略仍走 fake repo.save，断言不变。
      final db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => AppDatabase.resetForTest());
      final q1 = _q(
        'q1',
        ocrStem: '旧题干',
        ocrRaw: _raw('候选题\nA. 一\nB. 二', candidate: true),
        ocrManualEdited: true,
        contentVersion: 5,
      );
      await AppDatabase.upsertQuestionInto(db, q1);
      final repo = _FakeOrganizeRepo(questions: [q1]);
      final container = _organizeContainer(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      expect(await notifier.acceptOcrCandidate(), isTrue);
      // 接受已在事务内落库（Notifier 不再另行 repo.save）：读真实库验。
      final accepted = await AppDatabase.instance.questionById('q1');
      expect(accepted?.ocrStem, '候选题');
      expect(accepted?.ocrSplitStatus, '自动切分');
      expect(accepted?.contentVersion, 6);
      expect(hasPendingOcrCandidate(accepted!), isFalse);
      expect(container.read(organizeProvider).current?.ocrStem, '候选题');

      // 换一道带候选的题，忽略只清标志。
      repo.questions.add(
        _q(
          'q2',
          ocrStem: '题干二',
          ocrRaw: _raw('候选二', candidate: true),
          ocrManualEdited: true,
          contentVersion: 1,
          createdAt: DateTime(2026, 11, 9),
        ),
      );
      await notifier.refresh();
      await notifier.jumpTo('q2');
      expect(await notifier.dismissOcrCandidate(), isTrue);
      final dismissed = repo.saved.last;
      expect(dismissed.ocrStem, '题干二');
      expect(dismissed.contentVersion, 2);
      expect(hasPendingOcrCandidate(dismissed), isFalse);
    });

    test('refreshOcrForQuestion：只换队列行，不碰表单值与 formResetKey', () async {
      final repo = _FakeOrganizeRepo(
        questions: [_q('q1', ocrStem: '旧题干', folderIds: const ['f1'])],
      );
      final container = _organizeContainer(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      // 同上：等 build() 的 microtask 首查 refresh 跑完再读数。
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final formKeyBefore = container.read(organizeProvider).formResetKey;
      final foldersBefore = container.read(organizeProvider).folderIds;
      repo.questions[0] = _q(
        'q1',
        ocrStem: '新题干',
        folderIds: const ['f1'],
      );
      await notifier.refreshOcrForQuestion('q1');
      final state = container.read(organizeProvider);
      expect(state.current?.ocrStem, '新题干');
      expect(state.formResetKey, formKeyBefore);
      expect(state.folderIds, foldersBefore);
    });
  });

  group('详情页 Notifier 纠错方法', () {
    test('saveEdit 保留 OCR 字段（不抹题干/原始结果/人工标记/版本）', () async {
      final repo = _FakeDetailRepo(
        questions: [
          _q(
            'q1',
            ocrStem: '题干',
            ocrRaw: _raw('原文'),
            ocrSplitStatus: '人工调整',
            ocrManualEdited: true,
            contentVersion: 4,
            answer: '旧答案',
          ),
        ],
      );
      final container = _detailContainer(repo);
      final notifier = container.read(detailProvider.notifier);
      await notifier.load();
      notifier.enterEdit();
      await notifier.saveEdit(
        title: '题 q1',
        answer: '新答案',
        explanation: '',
        notes: '',
      );
      final saved = repo.saved.last;
      expect(saved.answer, '新答案');
      expect(saved.ocrStem, '题干');
      expect(saved.ocrRaw, contains('原文'));
      expect(saved.ocrSplitStatus, '人工调整');
      expect(saved.ocrManualEdited, isTrue);
      expect(saved.contentVersion, 4);
    });

    test('saveStemEdit / accept / dismiss：落库规则对，state.question 同步', () async {
      // 十三批 P1 第二轮：接受走真实库事务（repo.db.db）——接受前把
      // 当前题插进真实测试库；saveStemEdit 仍走 fake repo.save，断言不变。
      final db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => AppDatabase.resetForTest());
      final repo = _FakeDetailRepo(
        questions: [_q('q1', ocrStem: '旧题干', contentVersion: 2)],
      );
      final container = _detailContainer(repo);
      final notifier = container.read(detailProvider.notifier);
      await notifier.load();
      expect(await notifier.saveStemEdit('新题干'), isTrue);
      expect(repo.saved.last.ocrStem, '新题干');
      expect(repo.saved.last.contentVersion, 3);
      expect(container.read(detailProvider).question?.ocrStem, '新题干');

      repo.questions[0] = _q(
        'q1',
        ocrStem: '新题干',
        ocrRaw: _raw('候选\nA. 一\nB. 二', candidate: true),
        ocrManualEdited: true,
        contentVersion: 3,
      );
      await AppDatabase.upsertQuestionInto(db, repo.questions[0]);
      await notifier.refreshStemStatus();
      expect(await notifier.acceptOcrCandidate(), isTrue);
      // 接受已在事务内落库（Notifier 不再另行 repo.save）：读真实库验，
      // state.question 也同步成接受后的题。
      final accepted = await AppDatabase.instance.questionById('q1');
      expect(accepted?.ocrSplitStatus, '自动切分');
      expect(accepted?.ocrStem, '候选');
      expect(hasPendingOcrCandidate(accepted!), isFalse);
      expect(container.read(detailProvider).question?.ocrStem, '候选');
    });
  });

  group('重新识别与重框入队（真实库）', () {
    late QuizDatabase db;
    late Directory dataDir;

    setUp(() async {
      db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      // FR-45 后续（slices 污染）：D-260 前 tearDown 的 resetForTest()
      // 置 null，从第 2 个测试起 dataDirectoryPath() 读到真实目录，切片
      // 写进真实 slices/（P3 批量 2 实测本组 +2）；D-260 起 reset 改为
      // 重指全新临时目录，该窗口已堵上。setUp 仍先给 testDataDirectory
      // 指全新临时目录，再读路径。
      final tmpDataDir = await Directory.systemTemp.createTemp(
        'qm2-stem1310-',
      );
      AppDatabase.testDataDirectory = tmpDataDir.path;
      dataDir = Directory(AppDatabase.dataDirectoryPath());
      await dataDir.create(recursive: true);
      await Directory(p.join(dataDir.path, 'slices')).create(recursive: true);
      await Directory(
        p.join(dataDir.path, 'imports', 'rework-task'),
      ).create(recursive: true);
    });

    tearDown(() async {
      await AppDatabase.resetForTest();
      // setUp 指的临时数据目录用完即删，不留残留。
      try {
        if (await dataDir.exists()) await dataDir.delete(recursive: true);
      } catch (_) {}
    });

    test('整理页重新识别：为当前题建 pending 任务，哈希对得上切片', () async {
      final sliceBytes = _solidPng(100, 50, 10, 20, 30);
      await File(
        p.join(dataDir.path, 'slices', 'q1.png'),
      ).writeAsBytes(sliceBytes);
      final repo = _FakeOrganizeRepo(
        questions: [_q('q1', ocrStem: '题干', slicePath: 'slices/q1.png')],
      );
      final container = _organizeContainer(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      expect(await notifier.rerecognizeCurrent(), isTrue);
      final jobs = await AppDatabase.instance.ocrJobsForQuestion('q1');
      expect(jobs.length, 1);
      expect(jobs.single.status, OcrJobStatus.pending);
      expect(jobs.single.cropPath, 'slices/q1.png');
      expect(
        jobs.single.inputHash,
        await sha256HexOfFile(File(p.join(dataDir.path, 'slices', 'q1.png'))),
      );
    });

    test('详情页重新框选成功：自动为新切片建 OCR 任务', () async {
      final pageBytes = _solidPng(560, 700, 200, 200, 200);
      final pageRel = p.join('imports', 'rework-task', 'page.png');
      await File(p.join(dataDir.path, pageRel)).writeAsBytes(pageBytes);
      final oldSlice = _solidPng(100, 50, 10, 20, 30);
      await File(p.join(dataDir.path, 'slices', 'q1.png')).writeAsBytes(oldSlice);
      final q = _q(
        'q1',
        ocrStem: '题干',
        pageImagePath: pageRel,
        slicePath: 'slices/q1.png',
        sliceWidth: 100,
        sliceHeight: 50,
      );
      await AppDatabase.upsertQuestionInto(db, q);
      final repo = _FakeDetailRepo(questions: [q]);
      final container = _detailContainer(repo);
      final notifier = container.read(detailProvider.notifier);
      await notifier.load();
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
      final outcome = await notifier.applyReworkBoxes(
        [box],
        p.join(dataDir.path, pageRel),
      );
      expect(outcome, ReworkOutcome.success);
      expect(repo.replaceCalled, isTrue);
      // 十三批 P1-2：重框入队已是 await（确认任务持久化才返回），
      // 200ms 延时只是兜底沉淀微任务，不是等入队落盘。
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final jobs = await AppDatabase.instance.ocrJobsForQuestion('q1');
      expect(jobs.length, 1);
      expect(jobs.single.status, OcrJobStatus.pending);
      // 十三批 P1-1：重框写新版本文件，任务 crop_path 是新路径。
      expect(jobs.single.cropPath, startsWith('slices/q1-v'));
      expect(
        jobs.single.inputHash,
        await sha256HexOfFile(
          File(
            p.join(
              dataDir.path,
              jobs.single.cropPath!,
            ),
          ),
        ),
      );
    });

    test('详情页重新框选：旧切片文件缺失时重框仍成功，新切片照常入队', () async {
      final pageBytes = _solidPng(560, 700, 200, 200, 200);
      final pageRel = p.join('imports', 'rework-task', 'page.png');
      await File(p.join(dataDir.path, pageRel)).writeAsBytes(pageBytes);
      // 旧切片文件不存在（只记了路径）：重框不依赖旧切片，
      // 从页图重裁后 rename 出新切片，照常入队。
      final q = _q(
        'q1',
        ocrStem: '题干',
        pageImagePath: pageRel,
        slicePath: 'slices/missing.png',
        sliceWidth: 100,
        sliceHeight: 50,
      );
      await AppDatabase.upsertQuestionInto(db, q);
      final repo = _FakeDetailRepo(questions: [q]);
      final container = _detailContainer(repo);
      final notifier = container.read(detailProvider.notifier);
      await notifier.load();
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
      final outcome = await notifier.applyReworkBoxes(
        [box],
        p.join(dataDir.path, pageRel),
      );
      expect(outcome, ReworkOutcome.success);
      // 入队读的是新切片路径（版本化新文件，由 nextSliceRelative 定，
      // 与题的旧 slicePath 无关）：新切片已落盘，任务应已建。
      // 十三批 P1-2：重框入队已是 await，200ms 延时只是兜底沉淀微任务。
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final jobs = await AppDatabase.instance.ocrJobsForQuestion('q1');
      expect(jobs.length, 1);
      expect(jobs.single.cropPath, startsWith('slices/q1-v'));
    });
  });
}
